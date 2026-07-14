// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ArbExecutionStorage} from "../../contracts/ArbExecutionStorage.sol";
import {ArbExecutor} from "../../contracts/ArbExecutor.sol";
import {ArbHookHarness} from "../../contracts/test/ArbHookHarness.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {DataStorage} from "../../contracts/DataStorage.sol";
import {IUniswapV2Factory} from "../../contracts/interfaces/IUniswapV2Factory.sol";
import {TestToken} from "../../contracts/test/TestToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

interface IUniswapV2FlashCallee {
    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IPancakeV2FlashCallee {
    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

/// @dev Minimal functional V2 pair. It sends output before collecting input,
///      invokes the selected callback family, and requires the exact repayment
///      encoded by the executor. `outputBps` lets one test model a pair that
///      reports the requested output to the callback but transfers less; the
///      post-first-swap setting exercises a reverted later iteration.
contract FlashSettlementV2Pair {
    address public immutable token0;
    address public immutable token1;
    bool public immutable pancake;
    uint16 public immutable outputBps;
    uint16 public outputBpsAfterFirstSwap;

    uint112 private reserve0;
    uint112 private reserve1;
    uint256 public swapCalls;

    constructor(address token0_, address token1_, bool pancake_, uint16 outputBps_) {
        require(outputBps_ <= 10_000, "invalid output bps");
        token0 = token0_;
        token1 = token1_;
        pancake = pancake_;
        outputBps = outputBps_;
        outputBpsAfterFirstSwap = outputBps_;
    }

    function setOutputBpsAfterFirstSwap(uint16 newOutputBps) external {
        require(newOutputBps <= 10_000, "invalid output bps");
        outputBpsAfterFirstSwap = newOutputBps;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external {
        require((amount0Out == 0) != (amount1Out == 0), "one output required");
        require(amount0Out <= reserve0 && amount1Out <= reserve1, "insufficient liquidity");

        (address tokenToPay, uint256 amountToPay,) =
            abi.decode(data, (address, uint256, ArbExecutionStorage.FlashSecondLeg));
        address expectedTokenToPay = amount0Out == 0 ? token0 : token1;
        require(tokenToPay == expectedTokenToPay, "wrong repayment token");

        uint256 repaymentBalanceBefore = IERC20(tokenToPay).balanceOf(address(this));
        uint256 appliedOutputBps = swapCalls == 0 ? outputBps : outputBpsAfterFirstSwap;
        uint256 actualAmount0Out = amount0Out * appliedOutputBps / 10_000;
        uint256 actualAmount1Out = amount1Out * appliedOutputBps / 10_000;
        if (actualAmount0Out != 0) require(IERC20(token0).transfer(to, actualAmount0Out), "token0 transfer failed");
        if (actualAmount1Out != 0) require(IERC20(token1).transfer(to, actualAmount1Out), "token1 transfer failed");

        ++swapCalls;
        if (pancake) {
            IPancakeV2FlashCallee(to).pancakeCall(msg.sender, amount0Out, amount1Out, data);
        } else {
            IUniswapV2FlashCallee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        }

        require(
            IERC20(tokenToPay).balanceOf(address(this)) == repaymentBalanceBefore + amountToPay, "incorrect repayment"
        );
        _sync();
    }

    function skim(address to) external {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        if (balance0 > reserve0) require(IERC20(token0).transfer(to, balance0 - reserve0), "token0 skim failed");
        if (balance1 > reserve1) require(IERC20(token1).transfer(to, balance1 - reserve1), "token1 skim failed");
    }

    function sync() external {
        _sync();
    }

    function _sync() private {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "reserve overflow");
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
    }
}

contract ArbHookFlashSettlementTest is Test {
    address private constant UNISWAP_V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address private constant PANCAKESWAP_V2_FACTORY = 0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E;

    struct Fixture {
        ArbHookHarness hook;
        DataStorage dataStorage;
        TestToken startToken;
        TestToken intermediateToken;
        FlashSettlementV2Pair outerPair;
        FlashSettlementV2Pair innerPair;
    }

    struct PairSnapshot {
        uint256 startBalance;
        uint256 intermediateBalance;
        uint112 reserve0;
        uint112 reserve1;
        uint256 swapCalls;
    }

    function testNativeFlashSettlementNeedsNoPrefundingAndPaysOwner() public {
        Fixture memory fixture = _deployFixture(10_000);

        uint256 hookStartAtEntry = fixture.startToken.balanceOf(address(fixture.hook));
        uint256 hookIntermediateAtEntry = fixture.intermediateToken.balanceOf(address(fixture.hook));
        uint256 ownerStartBefore = fixture.startToken.balanceOf(address(this));

        assertEq(hookStartAtEntry, 0, "fixture must not prefund start token");
        assertEq(hookIntermediateAtEntry, 0, "fixture must not prefund intermediate token");
        assertTrue(fixture.hook.attemptAllForTest(1), "flash-funded arbitrage should succeed");

        uint256 ownerProfit = fixture.startToken.balanceOf(address(this)) - ownerStartBefore;
        assertGt(ownerProfit, 0, "owner must receive realized profit");
        assertEq(fixture.startToken.balanceOf(address(fixture.hook)), hookStartAtEntry);
        assertEq(fixture.intermediateToken.balanceOf(address(fixture.hook)), hookIntermediateAtEntry);
        assertEq(fixture.outerPair.swapCalls(), 1, "Uniswap V2 pair must initiate the flash swap");
        assertEq(fixture.innerPair.swapCalls(), 1, "Pancake V2 pair must execute inside the outer callback");
        assertEq(fixture.dataStorage.getTradeCount(), 1, "successful trade must be recorded");
    }

    function testUnderDeliveringSecondLegCannotConsumePreexistingDust() public {
        Fixture memory fixture = _deployFixture(4_000);

        fixture.startToken.transfer(address(fixture.hook), 100 ether);
        fixture.intermediateToken.transfer(address(fixture.hook), 7 ether);

        uint256 hookStartAtEntry = fixture.startToken.balanceOf(address(fixture.hook));
        uint256 hookIntermediateAtEntry = fixture.intermediateToken.balanceOf(address(fixture.hook));
        uint256 ownerStartBefore = fixture.startToken.balanceOf(address(this));
        PairSnapshot memory outerBefore = _snapshotPair(fixture, fixture.outerPair);
        PairSnapshot memory innerBefore = _snapshotPair(fixture, fixture.innerPair);

        assertFalse(fixture.hook.attemptAllForTest(1), "under-delivering reverse leg must fail atomically");

        assertEq(fixture.startToken.balanceOf(address(fixture.hook)), hookStartAtEntry, "start-token dust changed");
        assertEq(
            fixture.intermediateToken.balanceOf(address(fixture.hook)),
            hookIntermediateAtEntry,
            "intermediate-token dust changed"
        );
        assertEq(fixture.startToken.balanceOf(address(this)), ownerStartBefore, "failed route paid the owner");
        _assertPairUnchanged(fixture, fixture.outerPair, outerBefore);
        _assertPairUnchanged(fixture, fixture.innerPair, innerBefore);
        assertEq(fixture.dataStorage.getTradeCount(), 0, "failed route must not be recorded");
    }

    function testLaterFailedFlashIterationKeepsFirstIterationProfitAndState() public {
        Fixture memory baseline = _deployFixture(10_000);
        uint256 baselineOwnerStartBefore = baseline.startToken.balanceOf(address(this));
        assertTrue(baseline.hook.attemptAllForTest(1), "baseline iteration must succeed");

        uint256 baselineProfit = baseline.startToken.balanceOf(address(this)) - baselineOwnerStartBefore;
        PairSnapshot memory baselineOuter = _snapshotPair(baseline, baseline.outerPair);
        PairSnapshot memory baselineInner = _snapshotPair(baseline, baseline.innerPair);
        uint256[] memory baselineTrade = baseline.dataStorage.fetchTradeData(0);
        assertGt(baselineProfit, 0, "baseline must pay profit");
        assertEq(baselineTrade[5], baselineProfit, "baseline payout and recorded profit differ");
        assertEq(baselineTrade[6], 1, "baseline must record one iteration");

        Fixture memory laterFailure = _deployFixture(10_000);
        laterFailure.innerPair.setOutputBpsAfterFirstSwap(4_000);
        uint256 partialOwnerStartBefore = laterFailure.startToken.balanceOf(address(this));

        // The persisted counters remain one because the second nested swap
        // reverts, so call expectations prove that the failed iteration was
        // actually attempted rather than skipped by sizing.
        vm.expectCall(address(laterFailure.outerPair), abi.encodeWithSelector(FlashSettlementV2Pair.swap.selector), 2);
        vm.expectCall(address(laterFailure.innerPair), abi.encodeWithSelector(FlashSettlementV2Pair.swap.selector), 2);
        assertTrue(
            laterFailure.hook.attemptAllForTest(2), "first profitable iteration must survive later flash failure"
        );

        uint256 partialProfit = laterFailure.startToken.balanceOf(address(this)) - partialOwnerStartBefore;
        uint256[] memory partialTrade = laterFailure.dataStorage.fetchTradeData(0);
        assertEq(partialProfit, baselineProfit, "failed second iteration changed owner payout");
        assertEq(partialTrade[4], baselineTrade[4], "failed second iteration changed committed volume");
        assertEq(partialTrade[5], baselineTrade[5], "failed second iteration changed committed profit");
        assertEq(partialTrade[6], baselineTrade[6], "failed second iteration changed committed iteration count");
        assertEq(laterFailure.dataStorage.getTradeCount(), 1, "partial success must record exactly one trade");
        assertEq(laterFailure.startToken.balanceOf(address(laterFailure.hook)), 0, "profit was not fully paid out");
        assertEq(
            laterFailure.intermediateToken.balanceOf(address(laterFailure.hook)), 0, "temporary inventory remained"
        );
        _assertPairUnchanged(laterFailure, laterFailure.outerPair, baselineOuter);
        _assertPairUnchanged(laterFailure, laterFailure.innerPair, baselineInner);
    }

    function _deployFixture(uint16 innerOutputBps) private returns (Fixture memory fixture) {
        fixture.startToken = new TestToken("Start Token", "START", 1_000_000 ether);
        fixture.intermediateToken = new TestToken("Intermediate Token", "MID", 1_000_000 ether);
        fixture.outerPair =
            new FlashSettlementV2Pair(address(fixture.startToken), address(fixture.intermediateToken), false, 10_000);
        fixture.innerPair = new FlashSettlementV2Pair(
            address(fixture.startToken), address(fixture.intermediateToken), true, innerOutputBps
        );

        // Pool A sells START at roughly 2 MID; pool B buys START at roughly
        // 1 MID. The executor therefore chooses Uniswap as the outer first leg
        // and Pancake as the nested repayment leg.
        fixture.startToken.transfer(address(fixture.outerPair), 1_000 ether);
        fixture.intermediateToken.transfer(address(fixture.outerPair), 2_000 ether);
        fixture.startToken.transfer(address(fixture.innerPair), 1_000 ether);
        fixture.intermediateToken.transfer(address(fixture.innerPair), 1_000 ether);
        fixture.outerPair.sync();
        fixture.innerPair.sync();

        vm.mockCall(
            UNISWAP_V2_FACTORY,
            abi.encodeWithSelector(
                IUniswapV2Factory.getPair.selector, address(fixture.startToken), address(fixture.intermediateToken)
            ),
            abi.encode(address(fixture.outerPair))
        );
        vm.mockCall(
            PANCAKESWAP_V2_FACTORY,
            abi.encodeWithSelector(
                IUniswapV2Factory.getPair.selector, address(fixture.startToken), address(fixture.intermediateToken)
            ),
            abi.encode(address(fixture.innerPair))
        );

        ArbitrageLogic logic = new ArbitrageLogic();
        ArbExecutor executor = new ArbExecutor();
        fixture.dataStorage = new DataStorage(address(this));
        fixture.hook = new ArbHookHarness(
            IPoolManager(address(1)), address(this), address(logic), address(fixture.dataStorage), address(executor)
        );
        fixture.dataStorage.setWriter(address(fixture.hook));

        address[] memory pools = new address[](2);
        pools[0] = address(fixture.outerPair);
        pools[1] = address(fixture.innerPair);
        uint24[] memory fees = new uint24[](2);
        fees[0] = 3_000;
        fees[1] = 2_500;
        ArbUtils.PoolType[] memory poolTypes = new ArbUtils.PoolType[](2);
        poolTypes[0] = ArbUtils.PoolType.V2;
        poolTypes[1] = ArbUtils.PoolType.PANCAKESWAP_V2;
        fixture.hook.addPools(address(fixture.startToken), pools, fees, poolTypes);
        fixture.hook.setMaxFlashTradeAmount(address(fixture.startToken), 10 ether);
    }

    function _snapshotPair(Fixture memory fixture, FlashSettlementV2Pair pair)
        private
        view
        returns (PairSnapshot memory snapshot)
    {
        snapshot.startBalance = fixture.startToken.balanceOf(address(pair));
        snapshot.intermediateBalance = fixture.intermediateToken.balanceOf(address(pair));
        (snapshot.reserve0, snapshot.reserve1,) = pair.getReserves();
        snapshot.swapCalls = pair.swapCalls();
    }

    function _assertPairUnchanged(Fixture memory fixture, FlashSettlementV2Pair pair, PairSnapshot memory beforeState)
        private
        view
    {
        PairSnapshot memory afterState = _snapshotPair(fixture, pair);
        assertEq(afterState.startBalance, beforeState.startBalance, "pair start balance changed");
        assertEq(afterState.intermediateBalance, beforeState.intermediateBalance, "pair intermediate balance changed");
        assertEq(afterState.reserve0, beforeState.reserve0, "pair reserve0 changed");
        assertEq(afterState.reserve1, beforeState.reserve1, "pair reserve1 changed");
        assertEq(afterState.swapCalls, beforeState.swapCalls, "failed pair call persisted");
    }
}
