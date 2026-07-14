// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ArbHook} from "../../contracts/ArbHook.sol";
import {ArbExecutionStorage} from "../../contracts/ArbExecutionStorage.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbExecutor} from "../../contracts/ArbExecutor.sol";
import {DataStorage} from "../../contracts/DataStorage.sol";
import {ArbErrors} from "../../contracts/Errors.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract V3CallbackSecurityToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A pool-ABI impersonator. Factory authentication must reject it unless
///      the test explicitly models a canonical factory mapping to this address.
contract V3CallbackSecurityPool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    constructor(address token0_, address token1_, uint24 fee_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
    }

    function tickSpacing() external pure returns (int24) {
        return 60;
    }
}

/// @dev Exposes only the callback capability setup needed to unit-test the
///      synchronous callback boundary without weakening the production hook.
contract V3CallbackSecurityHarness is ArbHook {
    constructor(IPoolManager poolManager, address owner, address arbLib, address dataStorage, address arbExecutor)
        ArbHook(poolManager, owner, arbLib, dataStorage, arbExecutor)
    {}

    function validateHookAddress(BaseHook) internal pure override {}

    function armV3CallbackForTest(
        address pool,
        ArbUtils.PoolType poolType,
        address tokenIn,
        uint256 maximumAmountIn,
        bytes32 callbackDataHash
    ) external onlyOwner {
        PoolMeta storage meta = poolMetaByAddr[pool];
        require(meta.exists && meta.poolType == poolType, "pool not registered");
        require(tokenIn == meta.token0 || tokenIn == meta.token1, "token not in pool");

        bool zeroForOne = tokenIn == meta.token0;
        bytes4 selector = poolType == ArbUtils.PoolType.V3
            ? UNISWAP_V3_SWAP_CALLBACK_SELECTOR
            : PANCAKESWAP_V3_SWAP_CALLBACK_SELECTOR;
        activeV3SwapContext =
            _v3SwapContextHash(pool, poolType, selector, tokenIn, zeroForOne, maximumAmountIn, callbackDataHash);
    }

    function activeV3CallbackForTest() external view returns (bytes32) {
        return activeV3SwapContext;
    }
}

contract ArbHookV3CallbackSecurityTest is Test {
    address private constant UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address private constant PANCAKESWAP_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    uint24 private constant FEE = 500;

    V3CallbackSecurityHarness private hook;
    V3CallbackSecurityToken private token0;
    V3CallbackSecurityToken private token1;
    V3CallbackSecurityPool private pool;

    function setUp() public {
        ArbitrageLogic logic = new ArbitrageLogic();
        ArbExecutor executor = new ArbExecutor();
        DataStorage dataStorage = new DataStorage(address(this));
        hook = new V3CallbackSecurityHarness(
            IPoolManager(address(1)), address(this), address(logic), address(dataStorage), address(executor)
        );

        token0 = new V3CallbackSecurityToken("Token Zero", "TK0");
        token1 = new V3CallbackSecurityToken("Token One", "TK1");
        pool = new V3CallbackSecurityPool(address(token0), address(token1), FEE);
    }

    function testRejectsSpoofedUniswapV3PoolAtRegistration() public {
        _mockFactoryPool(ArbUtils.PoolType.V3, address(0));

        vm.expectRevert(ArbErrors.AddPoolsPoolVerificationFailed.selector);
        _register(ArbUtils.PoolType.V3);
    }

    function testRejectsSpoofedPancakeV3PoolAtRegistration() public {
        _mockFactoryPool(ArbUtils.PoolType.PANCAKESWAP_V3, address(0));

        vm.expectRevert(ArbErrors.AddPoolsPoolVerificationFailed.selector);
        _register(ArbUtils.PoolType.PANCAKESWAP_V3);
    }

    function testUnsolicitedAuthenticatedV3CallbackCannotDrainTreasury() public {
        _mockFactoryPool(ArbUtils.PoolType.V3, address(pool));
        _register(ArbUtils.PoolType.V3);

        uint256 treasuryBalance = 100 ether;
        token0.mint(address(hook), treasuryBalance);

        bytes memory callbackData = _callbackData(address(token0), treasuryBalance);
        vm.expectRevert(ArbErrors.V3CallbackContextMismatch.selector);
        vm.prank(address(pool));
        hook.uniswapV3SwapCallback(int256(treasuryBalance), -1, callbackData);

        assertEq(token0.balanceOf(address(hook)), treasuryBalance);
        assertEq(token0.balanceOf(address(pool)), 0);
    }

    function testLegitimateUniswapV3CallbackPaysWithinCeilingExactlyOnce() public {
        _mockFactoryPool(ArbUtils.PoolType.V3, address(pool));
        _register(ArbUtils.PoolType.V3);

        uint256 maximumAmountIn = 100 ether;
        uint256 amountToPay = 80 ether;
        token0.mint(address(hook), maximumAmountIn);

        bytes memory callbackData = _callbackData(address(token0), maximumAmountIn);
        hook.armV3CallbackForTest(
            address(pool), ArbUtils.PoolType.V3, address(token0), maximumAmountIn, keccak256(callbackData)
        );
        vm.prank(address(pool));
        hook.uniswapV3SwapCallback(int256(amountToPay), -1, callbackData);

        assertEq(token0.balanceOf(address(hook)), maximumAmountIn - amountToPay);
        assertEq(token0.balanceOf(address(pool)), amountToPay);
        assertEq(hook.activeV3CallbackForTest(), bytes32(0), "callback capability must be consumed");

        vm.expectRevert(ArbErrors.V3CallbackContextMismatch.selector);
        vm.prank(address(pool));
        hook.uniswapV3SwapCallback(int256(amountToPay), -1, callbackData);
    }

    function testLegitimatePancakeV3CallbackUsesItsDedicatedCapability() public {
        _mockFactoryPool(ArbUtils.PoolType.PANCAKESWAP_V3, address(pool));
        _register(ArbUtils.PoolType.PANCAKESWAP_V3);

        uint256 maximumAmountIn = 50 ether;
        uint256 amountToPay = 20 ether;
        token1.mint(address(hook), maximumAmountIn);

        bytes memory callbackData = _callbackData(address(token1), maximumAmountIn);
        hook.armV3CallbackForTest(
            address(pool), ArbUtils.PoolType.PANCAKESWAP_V3, address(token1), maximumAmountIn, keccak256(callbackData)
        );
        vm.prank(address(pool));
        hook.pancakeV3SwapCallback(-1, int256(amountToPay), callbackData);

        assertEq(token1.balanceOf(address(hook)), maximumAmountIn - amountToPay);
        assertEq(token1.balanceOf(address(pool)), amountToPay);
        assertEq(hook.activeV3CallbackForTest(), bytes32(0));
    }

    function testActiveV3CallbackCannotDebitAboveCeiling() public {
        _mockFactoryPool(ArbUtils.PoolType.V3, address(pool));
        _register(ArbUtils.PoolType.V3);

        uint256 maximumAmountIn = 10 ether;
        uint256 amountToPay = maximumAmountIn + 1;
        token0.mint(address(hook), amountToPay);
        bytes memory callbackData = _callbackData(address(token0), maximumAmountIn);
        hook.armV3CallbackForTest(
            address(pool), ArbUtils.PoolType.V3, address(token0), maximumAmountIn, keccak256(callbackData)
        );

        vm.expectRevert(
            abi.encodeWithSelector(ArbErrors.V3CallbackAmountExceedsMaximum.selector, amountToPay, maximumAmountIn)
        );
        vm.prank(address(pool));
        hook.uniswapV3SwapCallback(int256(amountToPay), -1, callbackData);

        assertEq(token0.balanceOf(address(hook)), amountToPay);
        assertEq(token0.balanceOf(address(pool)), 0);
    }

    function testActiveV3CallbackRejectsTamperedSecondLegPayload() public {
        _mockFactoryPool(ArbUtils.PoolType.V3, address(pool));
        _register(ArbUtils.PoolType.V3);

        uint256 maximumAmountIn = 10 ether;
        ArbExecutionStorage.FlashSecondLeg memory intendedSecondLeg = ArbExecutionStorage.FlashSecondLeg({
            pool: address(0xBEEF), poolType: ArbUtils.PoolType.V2, sqrtPriceLimitX96: 1
        });
        bytes memory intendedData = _callbackData(address(token0), maximumAmountIn, intendedSecondLeg);
        hook.armV3CallbackForTest(
            address(pool), ArbUtils.PoolType.V3, address(token0), maximumAmountIn, keccak256(intendedData)
        );

        ArbExecutionStorage.FlashSecondLeg memory tamperedSecondLeg = intendedSecondLeg;
        tamperedSecondLeg.sqrtPriceLimitX96 = 2;
        bytes memory tamperedData = _callbackData(address(token0), maximumAmountIn, tamperedSecondLeg);

        vm.expectRevert(ArbErrors.V3CallbackContextMismatch.selector);
        vm.prank(address(pool));
        hook.uniswapV3SwapCallback(int256(maximumAmountIn), -1, tamperedData);
    }

    function _callbackData(address tokenIn, uint256 maximumAmountIn) private view returns (bytes memory) {
        ArbExecutionStorage.FlashSecondLeg memory noSecondLeg;
        return _callbackData(tokenIn, maximumAmountIn, noSecondLeg);
    }

    function _callbackData(
        address tokenIn,
        uint256 maximumAmountIn,
        ArbExecutionStorage.FlashSecondLeg memory secondLeg
    ) private view returns (bytes memory) {
        return abi.encode(tokenIn, address(hook), maximumAmountIn, address(pool), secondLeg);
    }

    function _mockFactoryPool(ArbUtils.PoolType poolType, address canonicalPool) private {
        address factory = poolType == ArbUtils.PoolType.V3 ? UNISWAP_V3_FACTORY : PANCAKESWAP_V3_FACTORY;
        if (poolType == ArbUtils.PoolType.PANCAKESWAP_V3) {
            vm.mockCall(
                factory,
                abi.encodeWithSelector(IUniswapV3Factory.feeAmountTickSpacing.selector, FEE),
                abi.encode(int24(60))
            );
        }
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IUniswapV3Factory.getPool.selector, address(token0), address(token1), FEE),
            abi.encode(canonicalPool)
        );
    }

    function _register(ArbUtils.PoolType poolType) private {
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        uint24[] memory fees = new uint24[](1);
        fees[0] = FEE;
        ArbUtils.PoolType[] memory poolTypes = new ArbUtils.PoolType[](1);
        poolTypes[0] = poolType;
        hook.addPools(address(token0), pools, fees, poolTypes);
    }
}
