// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {ArbMath} from "../../contracts/lib/ArbMath.sol";
import {IUniswapV2Pair} from "../../contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapMath} from "@uniswap/v3-core/contracts/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

contract ArbMathEdgeV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint160 private immutable currentSqrtPriceX96;
    int24 private immutable currentTick;
    uint128 public immutable liquidity;
    int24 public immutable tickSpacing;
    uint24 public immutable fee;
    int128 private immutable liquidityNetAtZero;
    bool private immutable zeroTickInitialized;

    constructor(
        address token0_,
        address token1_,
        uint160 sqrtPriceX96_,
        int24 tick_,
        uint128 liquidity_,
        int24 tickSpacing_,
        uint24 fee_,
        int128 liquidityNetAtZero_,
        bool zeroTickInitialized_
    ) {
        token0 = token0_;
        token1 = token1_;
        currentSqrtPriceX96 = sqrtPriceX96_;
        currentTick = tick_;
        liquidity = liquidity_;
        tickSpacing = tickSpacing_;
        fee = fee_;
        liquidityNetAtZero = liquidityNetAtZero_;
        zeroTickInitialized = zeroTickInitialized_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (currentSqrtPriceX96, currentTick, 0, 0, 0, 0, true);
    }

    function tickBitmap(int16 wordPosition) external view returns (uint256) {
        return zeroTickInitialized && wordPosition == 0 ? 1 : 0;
    }

    function ticks(int24 queriedTick)
        external
        view
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool)
    {
        if (queriedTick == 0 && zeroTickInitialized) {
            return (liquidity, liquidityNetAtZero, 0, 0, 0, 0, 0, true);
        }
        return (0, 0, 0, 0, 0, 0, 0, false);
    }
}

contract ArbMathEdgeCasesTest is Test {
    ArbitrageLogic private logic;
    address private constant TOKEN0 = address(0x1000);
    address private constant TOKEN1 = address(0x2000);

    function setUp() public {
        logic = new ArbitrageLogic();
    }

    function testV3QuoteKeepsSubRawUnitPricePrecision() public view {
        // raw token1/token0 is 2^-64. With 18-decimal token0 and
        // 6-decimal token1, one token0 is worth less than one raw token1.
        uint160 sqrtPriceX96 = uint160(1) << 64;
        uint256 expectedPrice1e18 = 1e30 / (uint256(1) << 64);

        assertEq(logic.getRawPriceScaled(sqrtPriceX96, true, 18, 6), expectedPrice1e18);
        assertGt(expectedPrice1e18, 0, "the normalized quote must not floor to zero");
    }

    function testV2QuoteKeepsSubRawUnitPricePrecision() public view {
        // One whole 18-decimal tokenA maps to 0.001 raw units of the
        // 6-decimal tokenB, i.e. 1e-9 tokenB and a 1e9 normalized quote.
        uint112 reserveA = uint112(1_000 ether);
        uint112 reserveB = 1;
        uint256 quote = logic.getV2RawPriceScaled(
            IUniswapV2Pair(address(1)), TOKEN0, TOKEN1, reserveA, reserveB, TOKEN0, TOKEN1, 18, 6
        );

        assertEq(quote, 1e9);
    }

    function testV3V3ChunkModelChargesFirstLegFee() public view {
        (uint256 noFeeChunk,) = logic._binarySearchBestChunk(100, 100, 100, 100, 100, 105, 0, 0);
        (uint256 feeAdjustedChunk,) = logic._binarySearchBestChunk(100, 100, 100, 100, 100, 105, 100_000, 0);

        assertEq(noFeeChunk, 100, "the nominal five-percent spread is profitable without fees");
        assertEq(feeAdjustedChunk, 0, "the first-leg fee must eliminate the false profit");
    }

    function testFeeAwareFallbackRecoversProfitableWholeRawUnitChunk() public view {
        (uint256 chunk, int256 profit) = logic._binarySearchBestChunk(2, 1, 2, 1, 1, 8, 100_000, 3_000);

        assertEq(chunk, 2, "fee-aware fallback must probe beyond a rounded-to-zero dust candidate");
        assertGt(profit, 0);
    }

    function testFeeAwareFallbackAlwaysProbesLargeUpperEndpoint() public view {
        uint256 upperBound = 1e18;
        (uint256 chunk, int256 profit) = logic._binarySearchBestChunk(
            upperBound, 1, upperBound, upperBound, upperBound, 2 * upperBound + 2, 500_000, 0
        );

        assertEq(chunk, upperBound, "the only profitable endpoint must be evaluated");
        assertEq(profit, 1);
    }

    function testFeeAwareFallbackProbesCapacityBreakpoint() public view {
        uint256 capacity = 1e6;
        uint256 upperBound = 100 * capacity;
        (uint256 chunk, int256 profit) =
            logic._binarySearchBestChunk(upperBound, 1, upperBound, capacity, capacity, 2 * capacity + 1, 500_000, 0);

        assertEq(chunk, 2 * capacity, "the fee-adjusted capacity breakpoint must be evaluated");
        assertEq(profit, 1);
    }

    function testChunkSearchRejectsUnrepresentableSignedInputs() public view {
        (uint256 oversizedChunk, int256 oversizedProfit) =
            logic._binarySearchBestChunk(type(uint256).max, 1, 1, 1, 1, 1, 0, 0);
        assertEq(oversizedChunk, 0);
        assertEq(oversizedProfit, 0);

        (uint256 overflowingOutputChunk,) = logic._binarySearchBestChunk(1, 1, 1, 1, 1, type(uint256).max, 0, 0);
        assertEq(overflowingOutputChunk, 0, "an unrepresentable simulated output must fail closed");
    }

    function testQuantiseSaturatesInsteadOfWrapping() public view {
        uint256 firstUnrepresentableBucket = (uint256(type(uint128).max) + 1) * logic.PRICE_GRANULARITY();

        assertEq(logic.quantise(firstUnrepresentableBucket), type(uint128).max);
        assertEq(logic.quantise(type(uint256).max), type(uint128).max);
    }

    function testExactCapacityCrossesInitializedCurrentTickBeforeInput() public {
        uint128 liquidityBefore = 1e24;
        int128 liquidityNet = 9e23;
        uint128 liquidityAfter = 1e23;
        uint160 sqrtStart = TickMath.getSqrtRatioAtTick(0);
        uint160 sqrtLimit = TickMath.getSqrtRatioAtTick(-1);
        ArbMathEdgeV3Pool pool =
            new ArbMathEdgeV3Pool(TOKEN0, TOKEN1, sqrtStart, 0, liquidityBefore, 1, 0, liquidityNet, true);

        uint256 capacity = ArbMath._exactCapacity(address(pool), true, sqrtStart, sqrtLimit, 0, liquidityBefore);
        (, uint256 expectedAmountIn,, uint256 expectedFee) =
            SwapMath.computeSwapStep(sqrtStart, sqrtLimit, liquidityAfter, type(int256).max, 0);

        assertEq(capacity, expectedAmountIn + expectedFee);
        assertGt(capacity, 0);
    }

    function testImpactEstimatorReportsPriceMovementBps() public {
        uint160 sqrtStart = TickMath.getSqrtRatioAtTick(0);
        ArbMathEdgeV3Pool pool = new ArbMathEdgeV3Pool(TOKEN0, TOKEN1, sqrtStart, 0, 1e18, 1, 0, 0, true);

        uint256 impact = logic.estimateImpactBps(address(pool), TOKEN0, 1e14);

        assertEq(impact, 2, "a 0.01% reserve-sized input moves price by about two bps");
    }

    function testV3ParametersClampPoolAChunkToConfiguredImpact() public {
        uint128 liquidity = 1e24;
        ArbMathEdgeV3Pool poolA =
            new ArbMathEdgeV3Pool(TOKEN0, TOKEN1, TickMath.getSqrtRatioAtTick(100), 100, liquidity, 1, 0, 0, false);
        ArbMathEdgeV3Pool poolB =
            new ArbMathEdgeV3Pool(TOKEN1, TOKEN0, TickMath.getSqrtRatioAtTick(0), 0, liquidity, 1, 0, 0, false);
        ArbitrageLogic.IterationConfig memory config = ArbitrageLogic.IterationConfig({
            minSpreadBps: 1,
            chunkSpreadConsumptionBps: 1_500,
            bpsDivisor: 10_000,
            maxImpactBps: 1,
            minChunkForStartToken: 1,
            currentStartTokenBalance: 1e22,
            initialAbsSpread: 100
        });

        ArbitrageLogic.V3SwapParams memory params = logic.getV3SwapParameters(
            address(poolA), address(poolB), TOKEN0, TOKEN1, config, ArbUtils.PoolType.V3, ArbUtils.PoolType.V3
        );

        assertTrue(params.shouldContinue);
        assertGt(params.chunkToSwap, 0);
        assertLe(params.calculatedSellImpactBps, config.maxImpactBps);
        assertLe(logic.estimateImpactBps(address(poolA), TOKEN0, params.chunkToSwap), config.maxImpactBps);

        (uint256 fullInput, uint256 fullOutput) = ArbMath._deltaAmounts(
            params.zeroForOneA, TickMath.getSqrtRatioAtTick(100), params.sqrtPriceLimitA, liquidity
        );
        assertLe(params.chunkToSwap, fullInput, "the coarse input must remain inside pool A's price limit");
        assertEq(params.intermediateAmountPotentiallyFromA, fullOutput, "reference full-window heuristic must remain");
    }

    function testCapacityMarginCannotExceedPoolAPriceLimitInput() public {
        uint128 liquidity = 1e24;
        ArbMathEdgeV3Pool poolA =
            new ArbMathEdgeV3Pool(TOKEN0, TOKEN1, TickMath.getSqrtRatioAtTick(100), 100, liquidity, 1, 0, 0, false);
        ArbMathEdgeV3Pool poolB =
            new ArbMathEdgeV3Pool(TOKEN1, TOKEN0, TickMath.getSqrtRatioAtTick(0), 0, liquidity, 1, 0, 0, false);
        ArbitrageLogic.IterationConfig memory config = ArbitrageLogic.IterationConfig({
            minSpreadBps: 1,
            chunkSpreadConsumptionBps: 1_500,
            bpsDivisor: 10_000,
            maxImpactBps: 10_000,
            minChunkForStartToken: 1,
            currentStartTokenBalance: type(uint256).max,
            initialAbsSpread: 100
        });

        ArbitrageLogic.V3SwapParams memory params = logic.getV3SwapParameters(
            address(poolA), address(poolB), TOKEN0, TOKEN1, config, ArbUtils.PoolType.V3, ArbUtils.PoolType.V3
        );
        (uint256 fullInput, uint256 fullOutput) = ArbMath._deltaAmounts(
            params.zeroForOneA, TickMath.getSqrtRatioAtTick(100), params.sqrtPriceLimitA, liquidity
        );
        uint256 uncappedMarginChunk = FullMath.mulDiv(fullInput, params.intermediateCapacityOfB * 102, fullOutput * 100);

        assertLt(params.intermediateCapacityOfB, fullOutput, "fixture must activate the capacity-margin branch");
        assertGt(uncappedMarginChunk, fullInput, "fixture must reproduce the prior extrapolation");
        assertEq(params.chunkToSwap, fullInput, "coarse input must stop at pool A's price limit");
        assertEq(params.intermediateAmountPotentiallyFromA, fullOutput, "full-window heuristic remains unchanged");
    }

    function testImpactCapFindsSafeChunkBelowOldBinaryResolution() public {
        uint128 poolALiquidity = 1e24;
        ArbMathEdgeV3Pool poolA = new ArbMathEdgeV3Pool(
            TOKEN0, TOKEN1, TickMath.getSqrtRatioAtTick(500_000), 500_000, poolALiquidity, 10_000, 0, 0, false
        );
        ArbMathEdgeV3Pool poolB =
            new ArbMathEdgeV3Pool(TOKEN1, TOKEN0, TickMath.getSqrtRatioAtTick(0), 0, 1e30, 10_000, 0, 0, false);
        ArbitrageLogic.IterationConfig memory config = ArbitrageLogic.IterationConfig({
            minSpreadBps: 1,
            chunkSpreadConsumptionBps: 1_500,
            bpsDivisor: 10_000,
            maxImpactBps: 1,
            minChunkForStartToken: 1,
            currentStartTokenBalance: type(uint256).max,
            initialAbsSpread: 500_000
        });

        ArbitrageLogic.V3SwapParams memory params = logic.getV3SwapParameters(
            address(poolA), address(poolB), TOKEN0, TOKEN1, config, ArbUtils.PoolType.V3, ArbUtils.PoolType.V3
        );

        assertTrue(params.shouldContinue, "halving must find the nonzero safe bracket");
        assertGt(params.chunkToSwap, 0);
        assertLe(logic.estimateImpactBps(address(poolA), TOKEN0, params.chunkToSwap), 1);
    }

    function testSqrtPriceLimitConsumesFeeFromRemainingInput() public {
        uint160 sqrtStart = TickMath.getSqrtRatioAtTick(0);
        uint128 liquidity = 1e18;
        uint24 fee = 100_000;
        uint256 amountIn = 1e14;
        ArbMathEdgeV3Pool pool = new ArbMathEdgeV3Pool(TOKEN0, TOKEN1, sqrtStart, 0, liquidity, 1, fee, 0, false);

        (uint160 expectedSqrtPrice,,,) =
            SwapMath.computeSwapStep(sqrtStart, TickMath.MIN_SQRT_RATIO + 1, liquidity, int256(amountIn), fee);
        uint160 calculated =
            logic.calculateV3SqrtPriceLimitForAmountIn(IUniswapV3Pool(address(pool)), TOKEN0, amountIn, 0);

        assertEq(calculated, expectedSqrtPrice);
    }
}
