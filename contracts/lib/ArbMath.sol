// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {V3LiquidityAmounts} from "./V3LiquidityAmounts.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IPancakeV3Pool} from "../interfaces/IPancakeV3Pool.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v3-core/contracts/libraries/SwapMath.sol";

library ArbMath {
    error FailedPoolTicks();
    error FailedTickSpacing();

    uint8 private constant MAX_SAFE_TOKEN_DECIMALS = 77;
    uint8 private constant MAX_CAPACITY_STEPS = 64;

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
    function _price1e18(uint160 sqrtPriceX96, bool aIsToken0, uint8 dec0, uint8 dec1)
        internal
        pure
        returns (uint256 price)
    {
        if (sqrtPriceX96 == 0) return 0;

        // Keep 128 fractional bits until after decimal normalization. Quoting
        // one whole token in raw units first loses every price below one raw
        // output unit (for example, a sub-micro-USDC token).
        uint256 q128 = uint256(1) << 128;
        uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, uint256(1) << 64);
        if (ratioX128 == 0) return 0;

        return aIsToken0
            ? _rawRatioToPrice1e18(ratioX128, q128, dec0, dec1)
            : _rawRatioToPrice1e18(q128, ratioX128, dec1, dec0);
    }

    /// @dev Converts a raw-unit ratio (numerator / denominator) to whole-token
    ///      price scaled by 1e18 without first rounding to a raw output unit.
    function _rawRatioToPrice1e18(
        uint256 numerator,
        uint256 denominator,
        uint8 inputTokenDecimals,
        uint8 outputTokenDecimals
    ) internal pure returns (uint256) {
        if (
            numerator == 0 || denominator == 0 || inputTokenDecimals > MAX_SAFE_TOKEN_DECIMALS
                || outputTokenDecimals > MAX_SAFE_TOKEN_DECIMALS
        ) return 0;

        int256 decimalExponent = int256(uint256(inputTokenDecimals)) + 18 - int256(uint256(outputTokenDecimals));
        if (decimalExponent >= 0) {
            uint256 exponent = uint256(decimalExponent);
            if (exponent > MAX_SAFE_TOKEN_DECIMALS) return 0;
            return _mulDivOrZero(numerator, _pow10(uint8(exponent)), denominator);
        }

        uint256 divisorExponent = uint256(-decimalExponent);
        if (divisorExponent > MAX_SAFE_TOKEN_DECIMALS) return 0;
        uint256 decimalDivisor = _pow10(uint8(divisorExponent));
        // If the combined denominator is not representable, it is larger than
        // the numerator and the correctly floored uint256 quote is zero.
        if (denominator > type(uint256).max / decimalDivisor) return 0;
        return numerator / (denominator * decimalDivisor);
    }

    function _pow10(uint8 decimals) internal pure returns (uint256) {
        if (decimals > MAX_SAFE_TOKEN_DECIMALS) return 0;
        return 10 ** uint256(decimals);
    }

    function _mulDivOrZero(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        if (a == 0 || b == 0 || denominator == 0) return 0;
        uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            let prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        if (denominator <= prod1) return 0;
        return FullMath.mulDiv(a, b, denominator);
    }

    function _mulDivRoundingUpOrMax(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) return type(uint256).max;
        if (a == 0 || b == 0) return 0;
        uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            let prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        if (denominator <= prod1) return type(uint256).max;
        uint256 result = FullMath.mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) == 0) return result;
        if (result == type(uint256).max) return type(uint256).max;
        return result + 1;
    }

    function _scaleRawAmountTo1e18(uint256 rawAmount, uint8 decimals) internal pure returns (uint256) {
        if (rawAmount == 0) return 0;
        if (decimals == 18) return rawAmount;
        if (decimals < 18) {
            uint256 factor = _pow10(uint8(18 - decimals));
            if (factor == 0 || rawAmount > type(uint256).max / factor) {
                return 0;
            }
            return rawAmount * factor;
        }
        uint256 divisor = _pow10(uint8(decimals - 18));
        if (divisor == 0) return 0;
        return rawAmount / divisor;
    }

    /// @dev Returns the exact amounts that will flow **if** price moves from
    ///      `sqrtP0` to `sqrtP1` in a pool with liquidity `L`.
    function _deltaAmounts(
        bool zeroForOne,
        uint160 sqrtP0, // Current price
        uint160 sqrtP1, // Target price
        uint128 L
    )
        internal
        pure
        returns (uint256 inAmt, uint256 outAmt)
    {
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
            inAmt = V3LiquidityAmounts.getAmount0ForLiquidity(sqrtLower, sqrtUpper, L);
            outAmt = V3LiquidityAmounts.getAmount1ForLiquidity(sqrtLower, sqrtUpper, L);
        } else {
            // token1 in, token0 out (Price increases: sqrtP1 > sqrtP0)
            inAmt = V3LiquidityAmounts.getAmount1ForLiquidity(sqrtLower, sqrtUpper, L);
            outAmt = V3LiquidityAmounts.getAmount0ForLiquidity(sqrtLower, sqrtUpper, L);
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
        uint256 intermSentToB = intermOutA > intermCapB ? intermCapB : intermOutA;

        uint256 startBack = FullMath.mulDiv(startOutB, intermSentToB, intermInB);

        startBack = FullMath.mulDiv(startBack, 1e6 - feeB, 1e6);
        return int256(startBack) - int256(startInA);
    }

    /// @dev Returns the exact amounts that will flow **if** price moves from
    ///      `sqrtP0` to `sqrtP1` in a pool with liquidity `L`.
    function _expectedPL18(
        uint256 amtARaw,
        uint8 decA,
        uint8 decB,
        uint24 feeSell,
        uint24 feeBuy,
        uint256 priceSell,
        uint256 priceBuy,
        uint256 halfImpactBps
    ) external pure returns (int256) {
        // This legacy estimator is externally callable, so do not permit an
        // exotic decimal value or oversized raw amount to turn a quote into a
        // wraparound profit. A zero estimate is the conservative no-trade
        // result for an unsupported representation.
        if (
            decA > MAX_SAFE_TOKEN_DECIMALS || decB > MAX_SAFE_TOKEN_DECIMALS || feeSell >= 1_000_000
                || feeBuy >= 1_000_000 || priceBuy == 0
        ) return 0;

        uint256 amtA18 = _scaleRawAmountTo1e18(amtARaw, decA);
        if (amtARaw != 0 && amtA18 == 0) return 0;

        uint256 amtB18 = _mulDivOrZero(amtA18, priceSell, 1e18);
        amtB18 = _mulDivOrZero(amtB18, 1_000_000 - feeSell, 1_000_000);

        if (halfImpactBps != 0) {
            uint256 slipB18 = _mulDivOrZero(amtB18, halfImpactBps, 10_000);
            if (slipB18 >= amtB18) {
                amtB18 = 0;
            } else {
                amtB18 -= slipB18;
            }
        }

        uint256 amtABack18 = _mulDivOrZero(amtB18, 1e18, priceBuy);
        amtABack18 = _mulDivOrZero(amtABack18, 1_000_000 - feeBuy, 1_000_000);
        uint256 amtARawBack = _scale1e18ToRawAmount(amtABack18, decA);

        if (amtARaw > uint256(type(int256).max) || amtARawBack > uint256(type(int256).max)) return 0;
        return int256(amtARawBack) - int256(amtARaw);
    }

    function _scale1e18ToRawAmount(uint256 amount18, uint8 decimals) private pure returns (uint256) {
        if (amount18 == 0 || decimals == 18) return amount18;
        if (decimals < 18) {
            uint256 divisor = _pow10(uint8(18 - decimals));
            return divisor == 0 ? 0 : amount18 / divisor;
        }

        uint256 factor = _pow10(uint8(decimals - 18));
        if (factor == 0 || amount18 > type(uint256).max / factor) return 0;
        return amount18 * factor;
    }

    function _nextUsableTick(int24 tick, int24 tickSpacing, bool zeroForOne) internal pure returns (int24) {
        if (tickSpacing <= 0) return tick;
        int256 spacing = int256(tickSpacing);
        int256 compressed = int256(tick) / spacing;
        if (tick < 0 && int256(tick) % spacing != 0) --compressed;
        int256 next = zeroForOne ? compressed * spacing : (compressed + 1) * spacing;
        if (zeroForOne && next == int256(tick)) next -= spacing;
        return _clampTick(next);
    }

    function _clampTick(int256 tick) private pure returns (int24) {
        if (tick < int256(TickMath.MIN_TICK)) return TickMath.MIN_TICK;
        if (tick > int256(TickMath.MAX_TICK)) return TickMath.MAX_TICK;
        return int24(tick);
    }

    function _nextInitializedTickWithinOneWord(IUniswapV3Pool pool, int24 tick, int24 tickSpacing, bool lte)
        external
        view
        returns (int24 next, bool initialized)
    {
        return _nextInitializedTickWithinOneWordInternal(pool, tick, tickSpacing, lte);
    }

    function _nextInitializedTickWithinOneWordInternal(IUniswapV3Pool pool, int24 tick, int24 tickSpacing, bool lte)
        private
        view
        returns (int24 next, bool initialized)
    {
        if (tickSpacing <= 0) return (tick, false);
        int256 spacing = int256(tickSpacing);
        int256 compressed = int256(tick) / spacing;
        if (tick < 0 && int256(tick) % spacing != 0) --compressed;

        if (lte) {
            (int16 wordPos, uint8 bitPos) = _bitmapPosition(compressed);
            uint256 bitmap;
            try pool.tickBitmap(wordPos) returns (uint256 value) {
                bitmap = value;
            } catch {
                return (_nextUsableTick(tick, tickSpacing, true), false);
            }
            uint256 bit = uint256(bitPos);
            uint256 mask = (uint256(1) << bit) - 1 + (uint256(1) << bit);
            uint256 masked = bitmap & mask;
            if (masked == 0) {
                return (_clampTick((compressed - int256(bit)) * spacing), false);
            }
            uint8 msb = _mostSignificantBit(masked);
            return (_clampTick((compressed - int256(uint256(bitPos - msb))) * spacing), true);
        }

        ++compressed;
        (int16 wordPosGt, uint8 bitPosGt) = _bitmapPosition(compressed);
        uint256 bitmapGt;
        try pool.tickBitmap(wordPosGt) returns (uint256 value) {
            bitmapGt = value;
        } catch {
            return (_nextUsableTick(tick, tickSpacing, false), false);
        }
        uint256 bitGt = uint256(bitPosGt);
        uint256 maskGt = ~((uint256(1) << bitGt) - 1);
        uint256 maskedGt = bitmapGt & maskGt;
        if (maskedGt == 0) {
            return (_clampTick((compressed + int256(uint256(type(uint8).max - bitPosGt))) * spacing), false);
        }
        uint8 lsb = _leastSignificantBit(maskedGt);
        return (_clampTick((compressed + int256(uint256(lsb - bitPosGt))) * spacing), true);
    }

    function _bitmapPosition(int256 compressed) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(compressed >> 8);
        int256 remainder = compressed % 256;
        if (remainder < 0) remainder += 256;
        bitPos = uint8(uint256(remainder));
    }

    function _mostSignificantBit(uint256 x) private pure returns (uint8 r) {
        if (x >= (uint256(1) << 128)) {
            x >>= 128;
            r += 128;
        }
        if (x >= (uint256(1) << 64)) {
            x >>= 64;
            r += 64;
        }
        if (x >= (uint256(1) << 32)) {
            x >>= 32;
            r += 32;
        }
        if (x >= (uint256(1) << 16)) {
            x >>= 16;
            r += 16;
        }
        if (x >= (uint256(1) << 8)) {
            x >>= 8;
            r += 8;
        }
        if (x >= (uint256(1) << 4)) {
            x >>= 4;
            r += 4;
        }
        if (x >= (uint256(1) << 2)) {
            x >>= 2;
            r += 2;
        }
        if (x >= 2) r += 1;
    }

    function _leastSignificantBit(uint256 x) private pure returns (uint8 r) {
        if ((x & uint256(type(uint128).max)) == 0) {
            x >>= 128;
            r += 128;
        }
        if ((x & uint256(type(uint64).max)) == 0) {
            x >>= 64;
            r += 64;
        }
        if ((x & uint256(type(uint32).max)) == 0) {
            x >>= 32;
            r += 32;
        }
        if ((x & uint256(type(uint16).max)) == 0) {
            x >>= 16;
            r += 16;
        }
        if ((x & uint256(type(uint8).max)) == 0) {
            x >>= 8;
            r += 8;
        }
        if ((x & 0x0f) == 0) {
            x >>= 4;
            r += 4;
        }
        if ((x & 0x03) == 0) {
            x >>= 2;
            r += 2;
        }
        if ((x & 0x01) == 0) r += 1;
    }

    function _crossInitializedTick(IUniswapV3Pool pool, int24 tick, uint128 liquidity, bool zeroForOne)
        private
        view
        returns (uint128 nextLiquidity, bool success)
    {
        int128 liquidityNet;
        bool initialized;
        try pool.ticks(tick) returns (
            uint128, int128 _liquidityNet, uint256, uint256, int56, uint160, uint32, bool _initialized
        ) {
            liquidityNet = _liquidityNet;
            initialized = _initialized;
        } catch {
            return (0, false);
        }
        if (!initialized) return (liquidity, true);
        int256 liquidityAfter = int256(uint256(liquidity));
        if (zeroForOne) liquidityAfter -= int256(liquidityNet);
        else liquidityAfter += int256(liquidityNet);
        if (liquidityAfter <= 0) return (0, true);
        if (liquidityAfter > int256(uint256(type(uint128).max))) {
            return (0, false);
        }
        return (uint128(uint256(liquidityAfter)), true);
    }

    function _tickAfterCrossing(int24 crossedTick, bool zeroForOne) private pure returns (int24) {
        if (!zeroForOne) return crossedTick;
        if (crossedTick <= TickMath.MIN_TICK) return TickMath.MIN_TICK;
        return crossedTick - 1;
    }

    function _estImpactBps(address pool, address tokenIn, uint256 dx, bool isPancakeV3)
        external
        view
        returns (uint256)
    {
        if (dx == 0) return 0;
        if (dx > uint256(type(int256).max)) return type(uint256).max;
        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);
        uint160 sqrtP;
        int24 currentTick;
        if (isPancakeV3) {
            try IPancakeV3Pool(pool).slot0() returns (uint160 sp, int24 tk, uint16, uint16, uint16, uint32, bool) {
                sqrtP = sp;
                currentTick = tk;
            } catch {
                return type(uint256).max;
            }
        } else {
            try v3Pool.slot0() returns (uint160 sp, int24 tk, uint16, uint16, uint16, uint8, bool) {
                sqrtP = sp;
                currentTick = tk;
            } catch {
                return type(uint256).max;
            }
        }
        if (sqrtP < TickMath.MIN_SQRT_RATIO || sqrtP >= TickMath.MAX_SQRT_RATIO) {
            return type(uint256).max;
        }
        address t0;
        address t1;
        try v3Pool.token0() returns (address token0) {
            t0 = token0;
        } catch {
            return type(uint256).max;
        }
        try v3Pool.token1() returns (address token1) {
            t1 = token1;
        } catch {
            return type(uint256).max;
        }
        if (tokenIn != t0 && tokenIn != t1) return type(uint256).max;
        uint128 liquidity;
        try v3Pool.liquidity() returns (uint128 l) {
            liquidity = l;
        } catch {
            return type(uint256).max;
        }
        if (liquidity == 0) return type(uint256).max;
        int24 tickSpacing;
        try v3Pool.tickSpacing() returns (int24 ts) {
            tickSpacing = ts;
        } catch {
            return type(uint256).max;
        }
        if (tickSpacing <= 0 || currentTick < TickMath.MIN_TICK || currentTick > TickMath.MAX_TICK) {
            return type(uint256).max;
        }
        uint24 feePips;
        try v3Pool.fee() returns (uint24 fee) {
            feePips = fee;
        } catch {
            return type(uint256).max;
        }
        if (feePips >= 1_000_000) return type(uint256).max;
        bool zeroForOne = tokenIn == t0;
        if ((zeroForOne && currentTick <= TickMath.MIN_TICK) || (!zeroForOne && currentTick >= TickMath.MAX_TICK)) {
            return type(uint256).max;
        }

        uint160 sqrtStart = sqrtP;
        uint256 amountRemaining = dx;
        for (uint8 step; step < MAX_CAPACITY_STEPS && amountRemaining != 0; ++step) {
            int24 tickBefore = currentTick;
            uint160 sqrtBefore = sqrtP;
            (int24 nextTick, bool initialized) =
                _nextInitializedTickWithinOneWordInternal(v3Pool, currentTick, tickSpacing, zeroForOne);
            uint160 sqrtNextTick = TickMath.getSqrtRatioAtTick(nextTick);

            (uint160 sqrtAfter, uint256 amountIn,, uint256 feeAmount) =
                SwapMath.computeSwapStep(sqrtP, sqrtNextTick, liquidity, int256(amountRemaining), feePips);
            if (amountIn > type(uint256).max - feeAmount) return type(uint256).max;
            uint256 consumed = amountIn + feeAmount;
            if (consumed > amountRemaining) return type(uint256).max;
            amountRemaining -= consumed;
            sqrtP = sqrtAfter;

            if (sqrtP == sqrtNextTick) {
                if (initialized) {
                    bool crossed;
                    (liquidity, crossed) = _crossInitializedTick(v3Pool, nextTick, liquidity, zeroForOne);
                    if (!crossed || liquidity == 0) return type(uint256).max;
                }
                currentTick = _tickAfterCrossing(nextTick, zeroForOne);
            } else if (sqrtP != sqrtBefore) {
                currentTick = TickMath.getTickAtSqrtRatio(sqrtP);
            }

            // A malformed/nonstandard pool must not make the bounded quote
            // loop spin and return an understated policy value.
            if (consumed == 0 && sqrtP == sqrtBefore && currentTick == tickBefore) {
                return type(uint256).max;
            }
        }
        if (amountRemaining != 0) return type(uint256).max;
        return _priceMovementBps(sqrtStart, sqrtP, zeroForOne);
    }

    function _priceMovementBps(uint160 sqrtBefore, uint160 sqrtAfter, bool zeroForOne) private pure returns (uint256) {
        uint256 q128 = uint256(1) << 128;
        if (zeroForOne) {
            if (sqrtAfter >= sqrtBefore) return 0;
            uint256 decreasingSqrtX128 = FullMath.mulDiv(sqrtAfter, q128, sqrtBefore);
            uint256 decreasingPriceX128 = FullMath.mulDiv(decreasingSqrtX128, decreasingSqrtX128, q128);
            return _mulDivRoundingUpOrMax(q128 - decreasingPriceX128, 10_000, q128);
        }

        if (sqrtAfter <= sqrtBefore) return 0;
        uint256 relativeSqrtX128 = _mulDivRoundingUpOrMax(sqrtAfter, q128, sqrtBefore);
        if (relativeSqrtX128 == type(uint256).max) return type(uint256).max;
        uint256 relativePriceX128 = _mulDivRoundingUpOrMax(relativeSqrtX128, relativeSqrtX128, q128);
        if (relativePriceX128 == type(uint256).max) return type(uint256).max;
        return _mulDivRoundingUpOrMax(relativePriceX128 - q128, 10_000, q128);
    }

    /// @dev Uses SwapMath.computeSwapStep and initialized tick liquidity.
    function _exactCapacity(
        address poolAddr,
        bool zeroForOne,
        uint160 sqrtP,
        uint160 sqrtLimit,
        int24 tick,
        uint128 liquidity
    ) external view returns (uint256 inCap) {
        if (
            liquidity == 0 || sqrtP < TickMath.MIN_SQRT_RATIO || sqrtP >= TickMath.MAX_SQRT_RATIO
                || sqrtLimit < TickMath.MIN_SQRT_RATIO || sqrtLimit > TickMath.MAX_SQRT_RATIO
                || tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK
        ) return 0;
        if ((zeroForOne && sqrtLimit >= sqrtP) || (!zeroForOne && sqrtLimit <= sqrtP)) return 0;
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);
        uint24 feePips;
        try pool.fee() returns (uint24 fee) {
            feePips = fee;
        } catch {
            return 0;
        }
        if (feePips >= 1_000_000) return 0;
        int24 tickSpacing;
        try pool.tickSpacing() returns (int24 ts) {
            tickSpacing = ts;
        } catch {
            return 0;
        }
        if (tickSpacing <= 0) return 0;

        // A zero-for-one swap whose slot0 price is exactly an initialized
        // current tick crosses that boundary before consuming any input. The
        // strict-next-tick cadence below would otherwise size the first range
        // using the pre-cross liquidity.
        if (zeroForOne && sqrtP == TickMath.getSqrtRatioAtTick(tick)) {
            (int24 boundaryTick, bool initialized) =
                _nextInitializedTickWithinOneWordInternal(pool, tick, tickSpacing, true);
            if (initialized && boundaryTick == tick) {
                bool crossed;
                (liquidity, crossed) = _crossInitializedTick(pool, tick, liquidity, true);
                if (!crossed || liquidity == 0) return 0;
            }
        }

        for (uint8 step; step < MAX_CAPACITY_STEPS && sqrtP != sqrtLimit; ++step) {
            // Preserve the sizing cadence used by the reference executor:
            // advance one usable tick-spacing interval at a time, applying
            // liquidity changes only at initialized boundaries. This is a
            // sizing upper bound; the swap's sqrt-price limit remains the
            // execution-time authority.
            int24 nextTick = _nextUsableTick(tick, tickSpacing, zeroForOne);
            uint160 sqrtNextTick = TickMath.getSqrtRatioAtTick(nextTick);
            uint160 sqrtTarget = zeroForOne
                ? (sqrtNextTick > sqrtLimit ? sqrtNextTick : sqrtLimit)
                : (sqrtNextTick < sqrtLimit ? sqrtNextTick : sqrtLimit);
            if (sqrtTarget == sqrtP) return inCap;

            (uint160 sqrtAfter, uint256 amountIn,, uint256 feeAmount) =
                SwapMath.computeSwapStep(sqrtP, sqrtTarget, liquidity, type(int256).max, feePips);
            if (amountIn > type(uint256).max - feeAmount) {
                return type(uint256).max;
            }
            uint256 stepInput = amountIn + feeAmount;
            if (inCap > type(uint256).max - stepInput) {
                return type(uint256).max;
            }
            inCap += stepInput;
            sqrtP = sqrtAfter;
            if (sqrtP != sqrtTarget) return inCap;
            if (sqrtP == sqrtLimit) return inCap;
            if (sqrtP != sqrtNextTick) return inCap;
            bool crossed;
            (liquidity, crossed) = _crossInitializedTick(pool, nextTick, liquidity, zeroForOne);
            if (!crossed || liquidity == 0) return inCap;
            tick = nextTick;
        }
    }
}
