// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ArbHookHarness} from "../../contracts/test/ArbHookHarness.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbExecutor} from "../../contracts/ArbExecutor.sol";
import {DataStorage} from "../../contracts/DataStorage.sol";
import {ArbErrors} from "../../contracts/Errors.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {IUniswapV2Pair} from "../../contracts/interfaces/IUniswapV2Pair.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

/// @dev Deliberately minimal pair used only to exercise ArbHook's registration
///      and callback boundary. It does not need to implement swap semantics:
///      the regression tests enter the callback as the pair directly.
contract SecurityRegressionV2Pair {
    address public immutable token0;
    address public immutable token1;
    uint112 private reserve0;
    uint112 private reserve1;

    constructor(address token0_, address token1_, uint112 reserve0_, uint112 reserve1_) {
        token0 = token0_;
        token1 = token1_;
        reserve0 = reserve0_;
        reserve1 = reserve1_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function swap(uint256, uint256, address, bytes calldata) external {}

    function skim(address) external {}

    function sync() external {}
}

contract SecurityRegressionToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Models the ABI distinction that matters for Pancake V3: feeProtocol
/// is uint32, and a value above 255 must not be decoded as Uniswap V3's uint8.
contract SecurityRegressionPancakeV3Pool {
    address public immutable token0;
    address public immutable token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (TickMath.getSqrtRatioAtTick(60), 60, 0, 0, 0, 256, true);
    }

    function liquidity() external pure returns (uint128) {
        return 1e18;
    }

    function tickSpacing() external pure returns (int24) {
        return 60;
    }

    function tickBitmap(int16 wordPosition) external pure returns (uint256) {
        return wordPosition == 0 ? 1 : 0;
    }
}

/// @dev Starts exactly at an initialized tick. A zero-for-one estimate must
/// cross the zero-width boundary before measuring usable range capacity.
contract SecurityRegressionInitializedBoundaryV3Pool {
    address public immutable token0;
    address public immutable token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (TickMath.getSqrtRatioAtTick(0), 0, 0, 0, 0, 0, true);
    }

    function liquidity() external pure returns (uint128) {
        return 1e18;
    }

    function tickSpacing() external pure returns (int24) {
        return 1;
    }

    function tickBitmap(int16 wordPosition) external pure returns (uint256) {
        return wordPosition == 0 ? 1 : 0;
    }

    function ticks(int24 queriedTick)
        external
        pure
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool)
    {
        if (queriedTick == 0) {
            return (1e18, 0, 0, 0, 0, 0, 0, true);
        }
        return (0, 0, 0, 0, 0, 0, 0, false);
    }
}

contract ArbHookSecurityRegressionTest is Test {
    ArbHookHarness private hook;
    ArbitrageLogic private logic;
    ArbExecutor private executor;
    SecurityRegressionToken private token0;
    SecurityRegressionToken private token1;

    function setUp() public {
        logic = new ArbitrageLogic();
        executor = new ArbExecutor();
        DataStorage dataStorage = new DataStorage(address(this));
        hook = new ArbHookHarness(
            IPoolManager(address(1)), address(this), address(logic), address(dataStorage), address(executor)
        );
        token0 = new SecurityRegressionToken("Token Zero", "TK0");
        token1 = new SecurityRegressionToken("Token One", "TK1");
    }

    function testUniswapV2CallbackCannotDrainTreasuryWithoutActiveContext() public {
        SecurityRegressionV2Pair pair = _deployAndRegisterPair(ArbUtils.PoolType.V2, address(token0));
        uint256 theftAmount = 123 ether;
        token0.mint(address(hook), theftAmount);

        vm.expectRevert(ArbErrors.V2CallbackContextMismatch.selector);
        vm.prank(address(pair));
        hook.uniswapV2Call(address(hook), 1, 0, abi.encode(address(token0), theftAmount));

        assertEq(
            token0.balanceOf(address(hook)), theftAmount, "an unsolicited V2 callback must not transfer treasury funds"
        );
        assertEq(token0.balanceOf(address(pair)), 0, "pair must receive nothing");
    }

    function testPancakeV2CallbackCannotDrainTreasuryWithoutActiveContext() public {
        SecurityRegressionV2Pair pair = _deployAndRegisterPair(ArbUtils.PoolType.PANCAKESWAP_V2, address(token0));
        uint256 theftAmount = 456 ether;
        token1.mint(address(hook), theftAmount);

        vm.expectRevert(ArbErrors.V2CallbackContextMismatch.selector);
        vm.prank(address(pair));
        hook.pancakeCall(address(hook), 0, 1, abi.encode(address(token1), theftAmount));

        assertEq(
            token1.balanceOf(address(hook)),
            theftAmount,
            "an unsolicited Pancake V2 callback must not transfer treasury funds"
        );
        assertEq(token1.balanceOf(address(pair)), 0, "pair must receive nothing");
    }

    function testDualBaseRegistrationKeepsCallbackMetadataUntilFinalRemoval() public {
        SecurityRegressionV2Pair pair = _deployAndRegisterPair(ArbUtils.PoolType.V2, address(token0));
        _registerPair(address(pair), ArbUtils.PoolType.V2, address(token1));

        // Removing one base registration must not make the physical pool look
        // unregistered to the callback guard.
        hook.removePool(address(token0), 0);

        vm.expectRevert(ArbErrors.V2CallbackContextMismatch.selector);
        vm.prank(address(pair));
        hook.uniswapV2Call(address(hook), 0, 0, abi.encode(address(token0), uint256(1)));

        // Once the final registration is removed, the pair is no longer a
        // recognized callback source at all.
        hook.removePool(address(token1), 0);
        vm.expectRevert(abi.encodeWithSelector(ArbErrors.CallbackUnexpectedPool.selector, address(pair), address(0)));
        vm.prank(address(pair));
        hook.uniswapV2Call(address(hook), 0, 0, abi.encode(address(token0), uint256(1)));
    }

    function testV3PriceUsesWholeTokenDecimalsAndCorrectOrientation() public view {
        uint160 twoQ96 = uint160(2) << 96;

        // token1/token0 raw ratio is four. With 18-decimal token0 and
        // 6-decimal token1, one whole token0 is worth 4e12 whole token1.
        assertEq(logic.getRawPriceScaled(twoQ96, true, 18, 6), 4e30);
        // Conversely, one whole token1 is worth 0.25e-12 whole token0.
        assertEq(logic.getRawPriceScaled(twoQ96, false, 18, 6), 250_000);
    }

    function testPriceMathFailsClosedForUnsupportedDecimalExponents() public view {
        uint160 q96 = uint160(1) << 96;

        // 10**78 cannot be represented safely in uint256. Pricing must return
        // no quote instead of overflowing or producing a distorted one.
        assertEq(logic.getRawPriceScaled(q96, true, 78, 18), 0);
        assertEq(logic.getRawPriceScaled(q96, true, 18, 96), 0);
    }

    function testBuyPriceRoundsUpForV3AndV2Fees() public view {
        // ceil(1 * 1_000_000 / 999_999) is 2; rounding down undercharges the
        // buy leg and can manufacture a false-positive spread.
        assertEq(logic.getEffectiveBuyPrice(1, 1), 2);
        assertEq(logic.getV2EffectiveBuyPrice(1, 1), 2);

        // A non-unit input catches accidental truncation at a more realistic
        // magnitude as well.
        assertEq(logic.getEffectiveBuyPrice(1_000_001, 1), 1_000_003);
        assertEq(logic.getV2EffectiveBuyPrice(1_000_001, 1), 1_000_003);
    }

    function testV2PriceOrientationIsTokenBPerWholeTokenA() public {
        SecurityRegressionV2Pair pair =
            new SecurityRegressionV2Pair(address(token0), address(token1), uint112(2 ether), uint112(10 ether));

        uint256 token1PerToken0 = logic.getV2RawPriceScaled(
            IUniswapV2Pair(address(pair)),
            address(token0),
            address(token1),
            2 ether,
            10 ether,
            address(token0),
            address(token1),
            18,
            18
        );
        uint256 token0PerToken1 = logic.getV2RawPriceScaled(
            IUniswapV2Pair(address(pair)),
            address(token1),
            address(token0),
            2 ether,
            10 ether,
            address(token0),
            address(token1),
            18,
            18
        );

        assertEq(token1PerToken0, 5 ether);
        assertEq(token0PerToken1, 0.2 ether);
    }

    function testV2QuoteFailsClosedForAnUnrepresentableInputAmount() public view {
        // The old numerator multiplication could overflow for an externally
        // supplied amount even though a real V2 output is bounded by reserveOut.
        assertEq(logic.getAmountOut(type(uint256).max, 1, 1, 3_000), 0);
    }

    function testZeroQuantizedQuoteIsNotCachedAsAFailure() public {
        SecurityRegressionV2Pair buyPair =
            new SecurityRegressionV2Pair(address(token0), address(token1), uint112(100 ether), uint112(1_000_000_000));
        SecurityRegressionV2Pair sellPair =
            new SecurityRegressionV2Pair(address(token0), address(token1), uint112(100 ether), uint112(1_006_100_000));
        _registerPair(address(buyPair), ArbUtils.PoolType.V2, address(token0));
        _registerPair(address(sellPair), ArbUtils.PoolType.V2, address(token0));

        ArbUtils.PoolInfo[] memory pools = hook.getPoolsForToken(address(token0));
        (uint256 buyPrice,, bool buyPriceOk) = logic._getSinglePoolPrices(address(token0), address(token1), pools[0]);
        (, uint256 sellPrice, bool sellPriceOk) = logic._getSinglePoolPrices(address(token0), address(token1), pools[1]);
        assertTrue(buyPriceOk && sellPriceOk, "low-price V2 quotes must remain valid");
        assertEq(logic.quantise(buyPrice), 0, "buy quote must use the ambiguous zero bucket");
        assertEq(logic.quantise(sellPrice), 0, "sell quote must use the ambiguous zero bucket");

        assertFalse(hook.attemptAllForTest(1), "unfunded route should not execute");

        bytes32 quoteKey = logic.quoteKey(address(token0), address(token1), 0, 0);
        (uint128 cachedBuy, uint128 cachedSell) = hook.failedQuoteForTest(quoteKey);
        assertEq(cachedBuy, 0, "zero-bucket quote must not be cached");
        assertEq(cachedSell, 0, "zero-bucket quote must not be cached");

        bytes32 pairKey = address(token0) < address(token1)
            ? keccak256(abi.encodePacked(address(token0), address(token1)))
            : keccak256(abi.encodePacked(address(token1), address(token0)));
        (address cachedBuyPool, address cachedSellPool,,) = hook.failedAttemptForTest(pairKey);
        assertEq(cachedBuyPool, address(0), "zero-bucket pair failure must not be cached");
        assertEq(cachedSellPool, address(0), "zero-bucket pair failure must not be cached");
    }

    function testPancakeV3ImpactUsesItsSlot0Abi() public {
        SecurityRegressionPancakeV3Pool pool = new SecurityRegressionPancakeV3Pool(address(token0), address(token1));

        uint256 impact = logic.estimateImpactBps(address(pool), ArbUtils.PoolType.PANCAKESWAP_V3, address(token0), 1);

        assertLt(impact, type(uint256).max, "Pancake slot0 must not be decoded as Uniswap slot0");
    }

    function testImpactCrossesAnInitializedZeroForOneBoundary() public {
        SecurityRegressionInitializedBoundaryV3Pool pool =
            new SecurityRegressionInitializedBoundaryV3Pool(address(token0), address(token1));

        uint256 impact = logic.estimateImpactBps(address(pool), ArbUtils.PoolType.V3, address(token0), 1);

        assertLt(impact, type(uint256).max, "initialized tick boundaries must not report infinite impact");
    }

    function testExecutorRejectsEveryDirectExecutionEntrypoint() public {
        vm.expectRevert(ArbErrors.ExecutorOnlyDelegateCall.selector);
        executor.executeIterativeArb(
            address(0), address(0), address(0), address(0), 1, ArbUtils.PoolType.V3, ArbUtils.PoolType.V3
        );
    }

    function _deployAndRegisterPair(ArbUtils.PoolType poolType, address base)
        private
        returns (SecurityRegressionV2Pair pair)
    {
        pair = new SecurityRegressionV2Pair(address(token0), address(token1), uint112(100 ether), uint112(100 ether));
        _registerPair(address(pair), poolType, base);
    }

    function _registerPair(address pair, ArbUtils.PoolType poolType, address base) private {
        address[] memory pools = new address[](1);
        pools[0] = pair;
        uint24[] memory fees = new uint24[](1);
        fees[0] = poolType == ArbUtils.PoolType.PANCAKESWAP_V2 ? 2_500 : 3_000;
        ArbUtils.PoolType[] memory poolTypes = new ArbUtils.PoolType[](1);
        poolTypes[0] = poolType;
        hook.addPools(base, pools, fees, poolTypes);
    }
}
