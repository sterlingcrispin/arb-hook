// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ArbHookHarness} from "../../contracts/test/ArbHookHarness.sol";
import {PoolManagerHarness} from "../../contracts/test/PoolManagerHarness.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {TestToken} from "../../contracts/test/TestToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "../../contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "../../contracts/interfaces/IERC3156FlashLender.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Minimal constant-product pair that executes real swaps and enforces K.
contract HeadroomV2Pair {
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
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);
        if (data.length > 0) IV2CalleeLike(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "INSUFFICIENT_INPUT_AMOUNT");

        uint256 fee = feePpm;
        require(
            (balance0 * 1_000_000 - amount0In * fee) * (balance1 * 1_000_000 - amount1In * fee)
                >= uint256(reserve0) * uint256(reserve1) * 1_000_000 ** 2,
            "K"
        );
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
    }
}

interface IV2CalleeLike {
    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract HeadroomLender is IERC3156FlashLender {
    IERC20 public immutable loanToken;
    uint256 public flashLoanCallCount;

    constructor(IERC20 token) {
        loanToken = token;
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        return token == address(loanToken) ? loanToken.balanceOf(address(this)) : 0;
    }

    function flashFee(address token, uint256) external view returns (uint256) {
        require(token == address(loanToken), "unsupported token");
        return 0;
    }

    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data)
        external
        returns (bool)
    {
        require(token == address(loanToken), "unsupported token");
        ++flashLoanCallCount;
        require(loanToken.transfer(receiver, amount), "loan transfer failed");
        require(
            IERC3156FlashBorrower(receiver).onFlashLoan(msg.sender, token, amount, 0, data)
                == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "bad callback response"
        );
        require(loanToken.transferFrom(receiver, address(this), amount), "repay failed");
        return true;
    }
}

/// @notice Pins two operational properties an auditor should be able to check by
///         running the suite: what the owner surface allows, and how much caller
///         gas an arbitrage actually needs before it can succeed.
contract ArbHookOwnershipAndHeadroomTest is Test {
    address private constant BASE_UNISWAP_V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address private constant BASE_PANCAKE_V2_FACTORY = 0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E;

    PoolManagerHarness internal poolManager;
    ArbHookHarness internal hook;
    TestToken internal startToken;
    TestToken internal intermediateToken;
    HeadroomV2Pair internal sellPool;
    HeadroomV2Pair internal buyPool;
    HeadroomLender internal lender;

    function setUp() public {
        poolManager = new PoolManagerHarness(address(this));
        hook = new ArbHookHarness(IPoolManager(address(poolManager)), address(this), address(new ArbitrageLogic()));

        startToken = new TestToken("Start", "STA", 0);
        intermediateToken = new TestToken("Intermediate", "INT", 0);

        sellPool = new HeadroomV2Pair(
            address(startToken), address(intermediateToken), 1_000_000e18, 1_100_000e18, 3000
        );
        buyPool = new HeadroomV2Pair(
            address(startToken), address(intermediateToken), 1_000_000e18, 1_000_000e18, 2500
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

        _mockPair(BASE_UNISWAP_V2_FACTORY, address(sellPool));
        _mockPair(BASE_PANCAKE_V2_FACTORY, address(buyPool));

        lender = new HeadroomLender(IERC20(address(startToken)));
        startToken.mint(address(lender), 100_000e18);
        hook.setLenderForToken(address(startToken), address(lender));
        hook.setFlashPrincipalForToken(address(startToken), 100_000e18);
        hook.setMaxFlashFeeBpsForToken(address(startToken), 20);
        hook.setMinNetProfitForToken(address(startToken), 1);
        hook.setHookMaxIterations(2);
    }

    function _mockPair(address factory, address pair) private {
        vm.mockCall(
            factory,
            abi.encodeWithSignature(
                "getPair(address,address)", HeadroomV2Pair(pair).token0(), HeadroomV2Pair(pair).token1()
            ),
            abi.encode(pair)
        );
    }

    // ------------------------- Owner surface -------------------------------

    /// @dev `renounceOwnership` is inherited from Ownable and is NOT two-step. It
    ///      permanently removes the only mechanism the runbook documents for
    ///      stopping the hook, and the hook cannot be detached from a live v4 pool.
    function testRenounceOwnershipPermanentlyDestroysTheKillSwitch() public {
        hook.renounceOwnership();
        assertEq(hook.owner(), address(0), "ownership renounced in one step");

        // Every stop lever is now unreachable, forever.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setHookMaxIterations(0);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setFlashPrincipalForToken(address(startToken), 0);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.removeTokens(address(startToken));

        // And the hook keeps executing arbitrage on every swap.
        poolManager.callAfterSwap(IHooks(address(hook)), makeAddr("router"), abi.encodePacked(makeAddr("ben")));
        assertEq(lender.flashLoanCallCount(), 1, "hook still trades after renounce");
    }

    /// @dev `transferOwnership` is two-step, so a handover that omits
    ///      `acceptOwnership` silently leaves control with the original key.
    function testTransferOwnershipRequiresAcceptanceToTakeEffect() public {
        address multisig = makeAddr("multisig");

        hook.transferOwnership(multisig);
        assertEq(hook.owner(), address(this), "transfer must not apply until accepted");
        assertEq(hook.pendingOwner(), multisig, "pending owner should be recorded");

        // The intended new owner cannot act yet.
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, multisig));
        hook.setHookMaxIterations(0);

        vm.prank(multisig);
        hook.acceptOwnership();
        assertEq(hook.owner(), multisig, "acceptance completes the handover");

        vm.prank(multisig);
        hook.setHookMaxIterations(0);
        (uint256 iterations,,,) = hook.getExecutionConfig();
        assertEq(iterations, 0, "new owner controls the kill switch");
    }

    // ------------------------- Gas headroom --------------------------------

    /// @dev Each route receives half the scanner's remaining gas, so a swap must
    ///      carry roughly twice an arbitrage's true execution cost before one can
    ///      land. This measures the real threshold rather than assuming it.
    function testArbitrageNeedsRoughlyDoubleItsExecutionCostInCallerGas() public {
        uint256 succeedsAt = type(uint256).max;
        uint256 failsAt;

        // Walk the caller's gas limit upward and find where an arb first lands.
        for (uint256 limit = 400_000; limit <= 6_000_000; limit += 100_000) {
            uint256 snapshot = vm.snapshotState();
            (bool ok,) = address(poolManager).call{gas: limit}(
                abi.encodeWithSelector(
                    poolManager.callAfterSwap.selector,
                    IHooks(address(hook)),
                    makeAddr("router"),
                    abi.encodePacked(makeAddr("beneficiary"))
                )
            );
            bool traded = ok && lender.flashLoanCallCount() > 0;
            if (traded && limit < succeedsAt) succeedsAt = limit;
            if (!traded) failsAt = limit;
            vm.revertToState(snapshot);
        }

        emit log_named_uint("lowest caller gas that lands an arb", succeedsAt);
        emit log_named_uint("highest caller gas that still misses", failsAt);

        assertLt(succeedsAt, type(uint256).max, "no gas limit in range produced a trade");

        // Measure the same successful path with unconstrained gas.
        uint256 before = gasleft();
        poolManager.callAfterSwap(IHooks(address(hook)), makeAddr("router"), abi.encodePacked(makeAddr("ben")));
        uint256 actualCost = before - gasleft();
        emit log_named_uint("actual cost of the successful path", actualCost);
        emit log_named_uint("headroom multiple (x100)", (succeedsAt * 100) / actualCost);

        // The halving means the requirement is a multiple of true cost, not a small margin.
        assertGt(succeedsAt, actualCost, "threshold should exceed the path's own cost");
    }
}
