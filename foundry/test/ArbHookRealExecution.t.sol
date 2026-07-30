// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ArbHookHarness} from "../../contracts/test/ArbHookHarness.sol";
import {PoolManagerHarness} from "../../contracts/test/PoolManagerHarness.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {ArbErrors} from "../../contracts/Errors.sol";
import {TestToken} from "../../contracts/test/TestToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "../../contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "../../contracts/interfaces/IERC3156FlashLender.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Faithful constant-product V2 pair: real balances, real flash-swap callback,
///         real K invariant. Unlike the read-only price mocks this actually executes,
///         so route math, repayment callbacks and residue handling are all exercised.
contract FunctionalV2Pair {
    address public immutable token0;
    address public immutable token1;
    uint256 public immutable feePpm;
    uint112 private reserve0;
    uint112 private reserve1;

    constructor(address tokenA, address tokenB, uint112 reserveA, uint112 reserveB, uint256 feePpm_) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        (reserve0, reserve1) = tokenA < tokenB ? (reserveA, reserveB) : (reserveB, reserveA);
        feePpm = feePpm_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external {
        require(amount0Out > 0 || amount1Out > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        require(amount0Out < reserve0 && amount1Out < reserve1, "INSUFFICIENT_LIQUIDITY");

        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);
        if (data.length > 0) IUniswapV2CalleeLike(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "INSUFFICIENT_INPUT_AMOUNT");

        // Fee-adjusted constant-product check, in the pool's own fee units.
        uint256 fee = feePpm;
        uint256 balance0Adjusted = balance0 * 1_000_000 - amount0In * fee;
        uint256 balance1Adjusted = balance1 * 1_000_000 - amount1In * fee;
        require(
            balance0Adjusted * balance1Adjusted >= uint256(reserve0) * uint256(reserve1) * 1_000_000 ** 2,
            "K"
        );

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
    }
}

interface IUniswapV2CalleeLike {
    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract RealLender is IERC3156FlashLender {
    IERC20 public immutable loanToken;
    uint256 public immutable feeBps;
    uint256 public flashLoanCallCount;

    constructor(IERC20 token, uint256 fee) {
        loanToken = token;
        feeBps = fee;
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        return token == address(loanToken) ? loanToken.balanceOf(address(this)) : 0;
    }

    function flashFee(address token, uint256 amount) external view returns (uint256) {
        require(token == address(loanToken), "unsupported token");
        return (amount * feeBps) / 10_000;
    }

    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data)
        external
        returns (bool)
    {
        require(token == address(loanToken), "unsupported token");
        ++flashLoanCallCount;
        uint256 fee = (amount * feeBps) / 10_000;
        require(loanToken.transfer(receiver, amount), "loan transfer failed");
        require(
            IERC3156FlashBorrower(receiver).onFlashLoan(msg.sender, token, amount, fee, data)
                == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "bad callback response"
        );
        require(loanToken.transferFrom(receiver, address(this), amount + fee), "repay failed");
        return true;
    }
}

/// @notice Exercises the production route executor with no profit injection. The
///         E2E suite stubs executeIterativeArb to isolate flash plumbing; these
///         tests deliberately leave it intact so the two swap legs, the V2
///         repayment callbacks, residue handling and net-profit accounting all run
///         for real against pools that enforce their own K invariant.
contract ArbHookRealExecutionTest is Test {
    // A token pair has exactly one canonical pool per V2 factory, so a real V2/V2
    // route necessarily spans two DEXes. The sell leg is Uniswap, the buy leg Pancake.
    address private constant BASE_UNISWAP_V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address private constant BASE_PANCAKE_V2_FACTORY = 0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E;
    uint256 private constant UNISWAP_V2_FEE_PPM = 3000;
    uint256 private constant PANCAKE_V2_FEE_PPM = 2500;

    PoolManagerHarness internal poolManager;
    ArbHookHarness internal hook;
    TestToken internal startToken;
    TestToken internal intermediateToken;
    FunctionalV2Pair internal sellPool;
    FunctionalV2Pair internal buyPool;
    RealLender internal lender;

    uint256 internal constant PRINCIPAL_CAP = 100_000e18;

    function setUp() public {
        poolManager = new PoolManagerHarness(address(this));
        hook = new ArbHookHarness(IPoolManager(address(poolManager)), address(this), address(new ArbitrageLogic()));

        startToken = new TestToken("Start", "STA", 0);
        intermediateToken = new TestToken("Intermediate", "INT", 0);

        // Selling START here yields 1.1 INT per START...
        sellPool = new FunctionalV2Pair(
            address(startToken), address(intermediateToken), 1_000_000e18, 1_100_000e18, UNISWAP_V2_FEE_PPM
        );
        // ...and buying it back here costs 1.0 INT per START, so the round trip wins.
        buyPool = new FunctionalV2Pair(
            address(startToken), address(intermediateToken), 1_000_000e18, 1_000_000e18, PANCAKE_V2_FEE_PPM
        );

        startToken.mint(address(sellPool), 1_000_000e18);
        intermediateToken.mint(address(sellPool), 1_100_000e18);
        startToken.mint(address(buyPool), 1_000_000e18);
        intermediateToken.mint(address(buyPool), 1_000_000e18);

        address[] memory pools = new address[](2);
        uint24[] memory fees = new uint24[](2);
        ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](2);
        pools[0] = address(sellPool);
        pools[1] = address(buyPool);
        types[0] = ArbUtils.PoolType.V2;
        types[1] = ArbUtils.PoolType.PANCAKESWAP_V2;
        hook.addPools(address(startToken), pools, fees, types);

        _mockFactoryPair(BASE_UNISWAP_V2_FACTORY, address(sellPool));
        _mockFactoryPair(BASE_PANCAKE_V2_FACTORY, address(buyPool));

        lender = new RealLender(IERC20(address(startToken)), 5);
        startToken.mint(address(lender), PRINCIPAL_CAP);
        hook.setLenderForToken(address(startToken), address(lender));
        hook.setFlashPrincipalForToken(address(startToken), PRINCIPAL_CAP);
        hook.setMaxFlashFeeBpsForToken(address(startToken), 20);
        hook.setMinNetProfitForToken(address(startToken), 1);
        hook.setHookMaxIterations(2);
        // No setTestProfitBps: the real executor runs.
    }

    function _mockFactoryPair(address factory, address pair) private {
        vm.mockCall(
            factory,
            abi.encodeWithSignature(
                "getPair(address,address)",
                FunctionalV2Pair(pair).token0(),
                FunctionalV2Pair(pair).token1()
            ),
            abi.encode(pair)
        );
    }

    function testRealV2RouteProducesGenuineProfit() public {
        uint256 beneficiaryBefore = startToken.balanceOf(address(this));
        uint256 lenderBefore = startToken.balanceOf(address(lender));

        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            address(sellPool),
            address(buyPool),
            address(startToken),
            address(intermediateToken),
            2,
            ArbUtils.PoolType.V2,
            ArbUtils.PoolType.PANCAKESWAP_V2
        );

        assertTrue(success, "real route should succeed");
        assertGt(profit, 0, "real route should profit");
        assertGt(iterations, 0, "expected at least one executed iteration");
        assertEq(lender.flashLoanCallCount(), 1, "expected exactly one loan");

        // Profit is real value moved out of the pools, not minted.
        assertEq(
            startToken.balanceOf(address(this)) - beneficiaryBefore,
            uint256(profit),
            "beneficiary payout must equal reported profit"
        );
        assertGt(startToken.balanceOf(address(lender)), lenderBefore, "lender must be repaid with fee");
        assertEq(startToken.balanceOf(address(hook)), 0, "hook retained start token");
        assertEq(intermediateToken.balanceOf(address(hook)), 0, "hook retained intermediate token");
    }

    function testRealRouteViaDiscoveryAndAfterSwap() public {
        address beneficiary = makeAddr("beneficiary");

        (bytes4 selector,) = poolManager.callAfterSwap(
            IHooks(address(hook)), makeAddr("router"), abi.encodePacked(beneficiary)
        );

        assertEq(selector, hook.afterSwap.selector);
        assertEq(lender.flashLoanCallCount(), 1, "discovery should have found the route");
        assertGt(startToken.balanceOf(beneficiary), 0, "beneficiary should receive real profit");
        assertEq(intermediateToken.balanceOf(address(hook)), 0, "residue left behind");
    }

    function testUnprofitableRealRouteRevertsLoanAndKeepsHookWhole() public {
        // Route the buy leg back through the same pool the sell leg used: after fees
        // the round trip cannot clear, so the loan must revert rather than settle.
        startToken.mint(address(hook), 777);
        uint256 hookBefore = startToken.balanceOf(address(hook));

        (bool success, int256 profit,) = hook.runFlashArbForTest(
            address(buyPool),
            address(sellPool),
            address(startToken),
            address(intermediateToken),
            2,
            ArbUtils.PoolType.PANCAKESWAP_V2,
            ArbUtils.PoolType.V2
        );

        assertFalse(success, "flat route must not report success");
        assertEq(profit, 0, "flat route must not report profit");
        assertEq(startToken.balanceOf(address(hook)), hookBefore, "hook balance must be untouched");
    }

    /// @dev The hook must never consume the gas its caller needs to settle the swap.
    ///      Without an explicit budget the 63/64 rule leaves only 1/64 behind, which
    ///      is not enough on a swap submitted with a modest gas limit.
    function testTightGasBudgetSkipsArbAndLeavesCallerGas() public {
        uint256 tightGas = 400_000;

        uint256 before = gasleft();
        (bool ok, bytes memory ret) = address(poolManager).call{gas: tightGas}(
            abi.encodeWithSelector(
                poolManager.callAfterSwap.selector,
                IHooks(address(hook)),
                makeAddr("router"),
                abi.encodePacked(makeAddr("beneficiary"))
            )
        );
        uint256 consumed = before - gasleft();

        assertTrue(ok, "afterSwap must not revert under a tight gas limit");
        (bytes4 selector,) = abi.decode(ret, (bytes4, int128));
        assertEq(selector, hook.afterSwap.selector, "hook must still acknowledge the swap");

        (uint32 reserve,) = hook.getGasBounds();
        assertLt(consumed, tightGas - reserve / 2, "hook consumed the caller's reserve");
        assertEq(lender.flashLoanCallCount(), 0, "no loan should fit in the tight budget");
    }

    function testGasCeilingBoundsASuccessfulAttempt() public {
        hook.setHookGasBounds(200_000, 250_000);

        (bytes4 selector,) = poolManager.callAfterSwap(
            IHooks(address(hook)), makeAddr("router"), abi.encodePacked(makeAddr("beneficiary"))
        );

        assertEq(selector, hook.afterSwap.selector);
        assertEq(lender.flashLoanCallCount(), 0, "250k ceiling must not fit a full route");

        // Lifting the ceiling lets the same opportunity through.
        hook.setHookGasBounds(200_000, 3_000_000);
        poolManager.callAfterSwap(
            IHooks(address(hook)), makeAddr("router"), abi.encodePacked(makeAddr("beneficiary"))
        );
        assertEq(lender.flashLoanCallCount(), 1, "raised ceiling should allow the route");
    }

    function testHookBalanceSurvivesRealExecution() public {
        // A pre-existing balance may be used as trading capital but never lost.
        startToken.mint(address(hook), 500e18);
        intermediateToken.mint(address(hook), 250e18);
        uint256 startBefore = startToken.balanceOf(address(hook));
        uint256 intermBefore = intermediateToken.balanceOf(address(hook));

        (bool success,,) = hook.runFlashArbForTest(
            address(sellPool),
            address(buyPool),
            address(startToken),
            address(intermediateToken),
            2,
            ArbUtils.PoolType.V2,
            ArbUtils.PoolType.PANCAKESWAP_V2
        );

        assertTrue(success, "route should still execute with pre-existing balance");
        assertGe(startToken.balanceOf(address(hook)), startBefore, "pre-existing start balance was spent");
        assertEq(
            intermediateToken.balanceOf(address(hook)),
            intermBefore,
            "pre-existing intermediate balance must be exactly restored"
        );
    }
}
