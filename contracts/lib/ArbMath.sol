// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/SwapMath.sol";

library ArbMath {
    error FailedPoolTicks();
    error FailedTickSpacing();

    /*  returns: tokenB‑units per 1 tokenA‑unit, scaled by 1e18                     */
    /**
     * @dev Return token-B units per **1 token-A** (scaled by **1e18**),
     *      correctly adjusting for token decimals.
     *      This is the price orientation expected by `_expectedPL18`.
     *
     * @param sqrtPriceX96 The current sqrt price ratio (sqrt(token1/token0) * 2^96) from the pool.
     * @param aIsToken0 True if tokenA (the token for which the price is being quoted) is pool.token0.
     * @param dec0 Decimals of pool.token0.
     * @param dec1 Decimals of pool.token1.
     * @return price The price of tokenA in terms of tokenB, scaled by 1e18.
     *               (e.g., if tokenA is WETH and tokenB is USDC, it's USDC per WETH).
     */
    function _price1e18(
        uint160 sqrtPriceX96,
        bool aIsToken0,
        uint8 dec0,
        uint8 dec1
    ) internal pure returns (uint256 price) {
        uint256 sqrtP = uint256(sqrtPriceX96);
        uint256 tenPowDec0 = 10 ** uint256(dec0);
        uint256 tenPowDec1 = 10 ** uint256(dec1);

        // sqrtPSquared = sqrtPriceX96^2. Q192 = 2^192.
        // The raw price of token1 in terms of token0 (unadjusted for decimals) is P_1/0_raw = sqrtP^2 / Q192.
        uint256 sqrtPSquared = FullMath.mulDiv(sqrtP, sqrtP, 1);
        uint256 Q192 = uint256(1) << 192;

        uint256 num;
        uint256 den;

        if (aIsToken0) {
            // tokenA is pool.token0. We want the price of token0 in terms of token1 (token1/token0).
            // Formula: (P_1/0_raw) * (10^dec1 / 10^dec0)
            // price = (sqrtP^2 / Q192) * (10^dec1 / 10^dec0)
            num = FullMath.mulDiv(sqrtPSquared, tenPowDec1, Q192); // (sqrtP^2 / Q192) * 10^dec1 handles Q192 correctly
            den = tenPowDec0;
        } else {
            // tokenA is pool.token1. We want the price of token1 in terms of token0 (token0/token1).
            // Formula: (1 / P_1/0_raw) * (10^dec0 / 10^dec1)
            // price = (Q192 / sqrtP^2) * (10^dec0 / 10^dec1)
            num = FullMath.mulDiv(Q192, tenPowDec0, sqrtPSquared); // (Q192 / sqrtP^2) * 10^dec0 handles sqrtPSquared correctly
            den = tenPowDec1;
        }

        if (den == 0) return 0; // Should generally not happen with valid pool data and decimals.
        price = FullMath.mulDiv(num, 1e18, den); // Scale the final result by 1e18.
    }

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

    /// @dev Returns the exact amounts that will flow **if** price moves from
    ///      `sqrtP0` to `sqrtP1` in a pool with liquidity `L`.
    function _expectedPL18(
        uint256 amtARaw,
        uint8 decA,
        uint8 decB, // Unused parameter
        uint24 feeSell,
        uint24 feeBuy,
        uint256 priceSell,
        uint256 priceBuy,
        uint256 halfImpactBps
    ) external pure returns (int256) {
        unchecked {
            uint256 amtA_18dec;
            if (decA < 18) {
                amtA_18dec = amtARaw * (10 ** (18 - decA));
            } else if (decA > 18) {
                amtA_18dec = amtARaw / (10 ** (decA - 18));
            } else {
                amtA_18dec = amtARaw;
            }

            uint256 amtB_18dec = FullMath.mulDiv(amtA_18dec, priceSell, 1e18);
            amtB_18dec = FullMath.mulDiv(amtB_18dec, 1e6 - feeSell, 1e6);

            if (halfImpactBps != 0) {
                uint256 slipB_18dec = FullMath.mulDiv(
                    amtB_18dec,
                    halfImpactBps,
                    10_000
                );
                if (slipB_18dec >= amtB_18dec) {
                    amtB_18dec = 0;
                } else {
                    amtB_18dec -= slipB_18dec;
                }
            }

            uint256 amtA_18dec_Back = FullMath.mulDiv(
                amtB_18dec,
                1e18,
                priceBuy
            );
            amtA_18dec_Back = FullMath.mulDiv(
                amtA_18dec_Back,
                1e6 - feeBuy,
                1e6
            );

            uint256 amtARawBack;
            if (decA < 18) {
                amtARawBack = amtA_18dec_Back / (10 ** (18 - decA));
            } else if (decA > 18) {
                amtARawBack = amtA_18dec_Back * (10 ** (decA - 18));
            } else {
                amtARawBack = amtA_18dec_Back;
            }
            return int256(amtARawBack) - int256(amtARaw);
        }
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

        uint160 sqrtP_nextTick;
        if (tokenIn == t0) {
            if (currentTick == TickMath.MIN_TICK) return type(uint256).max;
            sqrtP_nextTick = TickMath.getSqrtRatioAtTick(
                currentTick - tickSpacing
            );
        } else {
            if (currentTick == TickMath.MAX_TICK) return type(uint256).max;
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

        return FullMath.mulDivRoundingUp(dx, 10000, amountInForOneTick);
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
                    int128 L_int = int128(L);
                    if (zeroForOne) {
                        L_int = L_int - liquidityNet;
                    } else {
                        L_int = L_int + liquidityNet;
                    }

                    if (L_int < 0) L = 0;
                    else if (L_int > type(int128).max) L = type(uint128).max;
                    else L = uint128(L_int);
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
