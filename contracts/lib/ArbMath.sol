// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import "@uniswap/v3-core/contracts/libraries/SwapMath.sol";

library ArbMath {
    error FailedPoolTicks();
    error FailedTickSpacing();

    /// @dev Returns the exact amounts that will flow **if** price moves from
    ///      `sqrtP0` to `sqrtP1` in a pool with liquidity `L`.
    function _deltaAmounts(
        bool zeroForOne,
        uint160 sqrtP0, // Current price
        uint160 sqrtP1, // Target price
        uint128 L
    ) internal pure returns (uint256 inAmt, uint256 outAmt) {
        // Ensure prices are ordered correctly for LiquidityAmounts functions
        uint160 sqrtLower;
        uint160 sqrtUpper;
        if (sqrtP0 < sqrtP1) {
            sqrtLower = sqrtP0;
            sqrtUpper = sqrtP1;
        } else {
            sqrtLower = sqrtP1;
            sqrtUpper = sqrtP0;
        }

        // Handle edge case where prices are the same
        if (sqrtLower == sqrtUpper) return (0, 0);

        if (zeroForOne) {
            // token0 in, token1 out (Price decreases: sqrtP1 < sqrtP0)
            inAmt = LiquidityAmounts.getAmount0ForLiquidity(
                sqrtLower,
                sqrtUpper,
                L
            );
            outAmt = LiquidityAmounts.getAmount1ForLiquidity(
                sqrtLower,
                sqrtUpper,
                L
            );
        } else {
            // token1 in, token0 out (Price increases: sqrtP1 > sqrtP0)
            inAmt = LiquidityAmounts.getAmount1ForLiquidity(
                sqrtLower,
                sqrtUpper,
                L
            );
            outAmt = LiquidityAmounts.getAmount0ForLiquidity(
                sqrtLower,
                sqrtUpper,
                L
            );
        }
    }

    function _simulatedPL(
        uint256 startInA, // token-A sent to pool A   (raw units)
        uint256 intermOutA, // token-B received from A  (raw units)
        uint256 intermCapB, // clamp you applied
        uint24 feeB,
        uint256 intermInB, // token-B you *would* push into B at limit
        uint256 startOutB // token-A you *would* get back at limit
    ) external pure returns (int256) {
        uint256 intermSentToB = intermOutA > intermCapB
            ? intermCapB
            : intermOutA;

        uint256 startBack = FullMath.mulDiv(
            startOutB,
            intermSentToB,
            intermInB
        );

        startBack = FullMath.mulDiv(startBack, 1e6 - feeB, 1e6);
        return int256(startBack) - int256(startInA);
    }

    function _estImpactBps(
        address pool,
        address tokenIn,
        uint256 dx
    ) external view returns (uint256) {
        (uint160 sqrtP, int24 currentTick, , , , , ) = IUniswapV3Pool(pool)
            .slot0();

        address t0 = IUniswapV3Pool(pool).token0();
        address t1 = IUniswapV3Pool(pool).token1();
        require(tokenIn == t0 || tokenIn == t1, "estImpact: bad token");

        uint128 L;
        try IUniswapV3Pool(pool).liquidity() returns (uint128 l) {
            L = l;
        } catch {
            return type(uint256).max;
        }

        if (L == 0) return type(uint256).max;

        int24 tickSpacing;
        try IUniswapV3Pool(pool).tickSpacing() returns (int24 ts) {
            tickSpacing = ts;
        } catch {
            return type(uint256).max;
        }
        if (tickSpacing <= 0) return type(uint256).max;

        uint160 sqrtP_nextTick;
        if (tokenIn == t0) {
            if (currentTick < TickMath.MIN_TICK + tickSpacing)
                return type(uint256).max;
            sqrtP_nextTick = TickMath.getSqrtRatioAtTick(
                currentTick - tickSpacing
            );
        } else {
            if (currentTick > TickMath.MAX_TICK - tickSpacing)
                return type(uint256).max;
            sqrtP_nextTick = TickMath.getSqrtRatioAtTick(
                currentTick + tickSpacing
            );
        }

        (uint256 amountInForOneTick, ) = _deltaAmounts(
            tokenIn == t0,
            sqrtP,
            sqrtP_nextTick,
            L
        );

        if (amountInForOneTick == 0) {
            return type(uint256).max;
        }

        // One tick is approximately one basis point; scale the local
        // tick-spacing capacity into the same units as maxImpactBps.
        return
            FullMath.mulDivRoundingUp(
                dx,
                uint24(tickSpacing),
                amountInForOneTick
            );
    }

    /// @dev Uses SwapMath.computeSwapStep and handles tick crossings.
    function _exactCapacity(
        address poolAddr, // Changed from IUniswapV3Pool to address
        bool zeroForOne, // direction of swap B
        uint160 sqrtP, // current √P
        uint160 sqrtLimit, // √P at `targetTickB`
        int24 tick, // current tick
        uint128 L // current liquidity
    ) external view returns (uint256 inCap) {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddr); // Cast to interface internally
        uint24 feePips = pool.fee();
        int256 amountRemaining = type(int256).max;
        int24 tickSpacing;
        try pool.tickSpacing() returns (int24 ts) {
            tickSpacing = ts;
        } catch {
            revert FailedTickSpacing();
        }

        while (sqrtP != sqrtLimit && uint256(amountRemaining) > 0) {
            int24 nextTickBoundary;
            if (zeroForOne) {
                if (tick < TickMath.MIN_TICK + tickSpacing) {
                    nextTickBoundary = TickMath.MIN_TICK;
                } else {
                    nextTickBoundary = tick - tickSpacing;
                }
            } else {
                if (tick > TickMath.MAX_TICK - tickSpacing) {
                    nextTickBoundary = TickMath.MAX_TICK;
                } else {
                    nextTickBoundary = tick + tickSpacing;
                }
            }
            if (nextTickBoundary < TickMath.MIN_TICK)
                nextTickBoundary = TickMath.MIN_TICK;
            if (nextTickBoundary > TickMath.MAX_TICK)
                nextTickBoundary = TickMath.MAX_TICK;

            uint160 sqrtNextTickPrice = TickMath.getSqrtRatioAtTick(
                nextTickBoundary
            );

            uint160 sqrtTarget;
            if (zeroForOne) {
                sqrtTarget = sqrtNextTickPrice > sqrtLimit
                    ? sqrtNextTickPrice
                    : sqrtLimit;
                if (sqrtTarget >= sqrtP && sqrtP > sqrtNextTickPrice)
                    sqrtTarget = sqrtNextTickPrice;
                if (sqrtTarget > sqrtP) sqrtTarget = sqrtP;
                if (sqrtTarget == sqrtP && sqrtP != sqrtLimit) {
                    if (sqrtNextTickPrice < sqrtP)
                        sqrtTarget = sqrtNextTickPrice;
                    else break;
                }
            } else {
                sqrtTarget = sqrtNextTickPrice < sqrtLimit
                    ? sqrtNextTickPrice
                    : sqrtLimit;
                if (sqrtTarget <= sqrtP && sqrtP < sqrtNextTickPrice)
                    sqrtTarget = sqrtNextTickPrice;
                if (sqrtTarget < sqrtP) sqrtTarget = sqrtP;
                if (sqrtTarget == sqrtP && sqrtP != sqrtLimit) {
                    if (sqrtNextTickPrice > sqrtP)
                        sqrtTarget = sqrtNextTickPrice;
                    else break;
                }
            }

            if (sqrtTarget == sqrtP && sqrtP != sqrtLimit) break;

            (uint160 sqrtAfter, uint256 inStep, , uint256 feeAmt) = SwapMath
                .computeSwapStep(
                    sqrtP,
                    sqrtTarget,
                    L,
                    amountRemaining,
                    feePips
                );

            inCap += inStep + feeAmt;
            sqrtP = sqrtAfter;

            if (sqrtP == sqrtTarget && sqrtP == sqrtNextTickPrice) {
                tick = nextTickBoundary;

                int128 liquidityNet;
                bool initialized;

                try pool.ticks(tick) returns (
                    uint128 /* liquidityGross */,
                    int128 _liquidityNet,
                    uint256 /* feeGrowthOutside0X128 */,
                    uint256 /* feeGrowthOutside1X128 */,
                    int56 /* tickCumulativeOutside */,
                    uint160 /* secondsPerLiquidityOutsideX128 */,
                    uint32 /* secondsOutside */,
                    bool _initialized
                ) {
                    liquidityNet = _liquidityNet;
                    initialized = _initialized;
                } catch {
                    revert FailedPoolTicks();
                }

                if (initialized) {
                    if (zeroForOne) liquidityNet = -liquidityNet;
                    L = LiquidityMath.addDelta(L, liquidityNet);
                }
            } else if (sqrtP == sqrtTarget && sqrtP != sqrtLimit) {
                // Intermediate target reached, continue
            } else {
                break;
            }

            if (L == 0) break;
        }
        return inCap;
    }
}
