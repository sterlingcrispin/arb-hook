// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./lib/ArbMath.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol"; // For pool interactions
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol"; // For decimals
import "./ArbUtils.sol"; // For PoolInfo struct
import "./Errors.sol"; // For ArbErrors
import "@openzeppelin/contracts/utils/math/Math.sol"; // Import Math
import "./interfaces/IUniswapV2Pair.sol"; // Added for V2
import "@uniswap/v3-core/contracts/libraries/SwapMath.sol"; // Added for SwapMath
import "./interfaces/IPancakeV3Pool.sol"; // NEW: Add PancakeV3 Pool interface

/**
 * @title ArbitrageLogic
 * @notice A stateless contract providing pure functions for arbitrage calculations.
 */
contract ArbitrageLogic {
    using Math for uint256; // Add using directive for Math

    uint24 private constant UNISWAP_V2_FEE_PPM = 3000;
    uint24 private constant PANCAKESWAP_V2_FEE_PPM = 2500;

    /// @notice Read and validate immutable pool metadata during hook setup.
    /// @dev Keeping cold registration introspection here leaves the hook focused
    ///      on runtime discovery and execution without changing stored PoolInfo.
    function getValidatedPoolInfo(
        address baseToken,
        address poolAddress,
        uint24 providedFee,
        ArbUtils.PoolType poolType
    ) external view returns (ArbUtils.PoolInfo memory info) {
        address token0;
        address token1;
        uint24 actualFee = providedFee;
        int24 tickSpacing;
        bool feeMustMatch;

        if (
            poolType == ArbUtils.PoolType.V3 ||
            poolType == ArbUtils.PoolType.PANCAKESWAP_V3
        ) {
            if (poolType == ArbUtils.PoolType.V3) {
                IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
                token0 = pool.token0();
                token1 = pool.token1();
                actualFee = pool.fee();
                tickSpacing = pool.tickSpacing();
            } else {
                IPancakeV3Pool pool = IPancakeV3Pool(poolAddress);
                token0 = pool.token0();
                token1 = pool.token1();
                actualFee = pool.fee();
                tickSpacing = IUniswapV3Factory(
                    0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865
                ).feeAmountTickSpacing(actualFee);
            }
            feeMustMatch = true;
        } else if (poolType == ArbUtils.PoolType.V2) {
            actualFee = UNISWAP_V2_FEE_PPM;
            IUniswapV2Pair pair = IUniswapV2Pair(poolAddress);
            token0 = pair.token0();
            token1 = pair.token1();
        } else if (poolType == ArbUtils.PoolType.PANCAKESWAP_V2) {
            actualFee = PANCAKESWAP_V2_FEE_PPM;
            IUniswapV2Pair pair = IUniswapV2Pair(poolAddress);
            token0 = pair.token0();
            token1 = pair.token1();
        } else {
            revert ArbErrors.UnsupportedPoolType();
        }

        if (
            !((baseToken == token0 && token1 != address(0)) ||
                (baseToken == token1 && token0 != address(0)))
        ) revert ArbErrors.AddPoolsInputTokenNotInPool();
        if (feeMustMatch && actualFee != providedFee)
            revert ArbErrors.AddPoolsProvidedFeeMismatch();

        info = ArbUtils.PoolInfo({
            poolAddress: poolAddress,
            fee: actualFee,
            poolType: poolType,
            token0: token0,
            token1: token1,
            token0Decimals: IERC20Metadata(token0).decimals(),
            token1Decimals: IERC20Metadata(token1).decimals(),
            tickSpacing: tickSpacing
        });
    }

    /**
     * @notice Corrected calculation of tokenA price in terms of tokenB, scaled to 1e18.
     * @dev Avoids overflow by using FullMath.mulDiv for intermediate calculations.
     * @param sqrtP_uint160 The current sqrt price ratio from the pool.
     * @param aIsT0 True if tokenA is token0 in the pool, false otherwise.
     * @param dec0_uint8 Decimals of token0.
     * @param dec1_uint8 Decimals of token1.
     * @return price1e18 The price of tokenA in terms of tokenB, scaled by 1e18.
     */
    function _calculatePrice1e18_corrected(
        uint160 sqrtP_uint160,
        bool aIsT0,
        uint8 dec0_uint8,
        uint8 dec1_uint8
    ) private pure returns (uint256 price1e18) {

        uint256 sqrtP = uint256(sqrtP_uint160);
        if (sqrtP == 0) return 0;

        uint256 Q192 = uint256(1) << 192;

        if (aIsT0) {
            // price(token0 in token1) = sqrtP^2 / 2^192 * 10^dec0 / 10^dec1
            uint256 numeratorDecimals = uint256(dec0_uint8) + 18;
            uint256 quotient = FullMath.mulDiv(sqrtP, sqrtP, Q192);
            if (numeratorDecimals < dec1_uint8) {
                return quotient / (10 ** (uint256(dec1_uint8) - numeratorDecimals));
            }

            uint256 scale = 10 ** (numeratorDecimals - uint256(dec1_uint8));
            // Preserve the part below Q192 before decimal scaling. Scaling only
            // `quotient` is what previously rounded valid small prices to zero.
            uint256 remainder = mulmod(sqrtP, sqrtP, Q192);
            return quotient * scale + FullMath.mulDiv(remainder, scale, Q192);
        } else {
            // price(token1 in token0) = 2^192 / sqrtP^2 * 10^dec1 / 10^dec0
            uint256 numeratorDecimals = uint256(dec1_uint8) + 18;
            if (numeratorDecimals < dec0_uint8) {
                uint256 divisor = 10 ** (uint256(dec0_uint8) - numeratorDecimals);
                return ((Q192 / sqrtP) / sqrtP) / divisor;
            }

            uint256 scale = 10 ** (numeratorDecimals - uint256(dec0_uint8));
            uint256 quotient = Q192 / sqrtP;
            uint256 remainder = Q192 % sqrtP;
            uint256 result = FullMath.mulDiv(quotient, scale, sqrtP);
            uint256 scaledRemainder = FullMath.mulDiv(remainder, scale, sqrtP);
            uint256 carry = scaledRemainder / sqrtP;
            if (scaledRemainder % sqrtP + mulmod(quotient, scale, sqrtP) >= sqrtP) {
                ++carry;
            }
            return result + carry;
        }
    }

    /**
     * @notice Calculates the raw price of tokenA in terms of tokenB, scaled to 1e18.
     * @param sqrtPriceX96 The current sqrt price ratio from the pool.
     * @param aIsToken0 True if tokenA is token0 in the pool, false otherwise.
     * @param dec0 Decimals of token0.
     * @param dec1 Decimals of token1.
     * @return rawPriceScaled The price of tokenA in terms of tokenB, scaled by 1e18.
     */
    function getRawPriceScaled(
        uint160 sqrtPriceX96,
        bool aIsToken0,
        uint8 dec0,
        uint8 dec1
    ) private pure returns (uint256 rawPriceScaled) {
        // Calls the corrected internal function instead of ArbMath._price1e18
        return
            _calculatePrice1e18_corrected(sqrtPriceX96, aIsToken0, dec0, dec1);
    }

    /**
     * @notice Calculates the effective buy price, including fees.
     * @param rawPriceScaled The raw price (tokenB per tokenA, 1e18).
     * @param poolFee The pool fee in parts per million (ppm).
     * @return effectiveBuyPrice The fee-adjusted price for buying tokenA.
     */
    function getEffectiveBuyPrice(
        uint256 rawPriceScaled,
        uint24 poolFee
    ) private pure returns (uint256 effectiveBuyPrice) {
        // buy-leg pays the fee -> price increases
        return
            FullMath.mulDiv(
                rawPriceScaled,
                1_000_000 + poolFee, // +fee (ppm)
                1_000_000
            );
    }

    /**
     * @notice Calculates the effective sell price, including fees.
     * @param rawPriceScaled The raw price (tokenB per tokenA, 1e18).
     * @param poolFee The pool fee in parts per million (ppm).
     * @return effectiveSellPrice The fee-adjusted price for selling tokenA.
     */
    function getEffectiveSellPrice(
        uint256 rawPriceScaled,
        uint24 poolFee
    ) private pure returns (uint256 effectiveSellPrice) {
        // sell-leg receives less -> price decreases
        return
            FullMath.mulDiv(
                rawPriceScaled,
                1_000_000 - poolFee, // -fee (ppm)
                1_000_000
            );
    }

    // [NEW] Lightweight price fetch for a single pool
    function _getSinglePoolPrices(
        address tokenA,
        address tokenB,
        ArbUtils.PoolInfo memory poolInfo
    )
        public
        view
        returns (uint256 effBuyPrice, uint256 effSellPrice, bool success)
    {
        address poolAddr = poolInfo.poolAddress;
        ArbUtils.PoolType poolType = poolInfo.poolType;
        uint24 poolFee = poolInfo.fee;
        uint256 rawPriceScaled;


        if (poolType == ArbUtils.PoolType.V3) {
            IUniswapV3Pool v3Pool = IUniswapV3Pool(poolAddr);
            uint160 sqrtPriceX96;
            try v3Pool.slot0() returns (
                uint160 sp,
                int24,
                uint16,
                uint16,
                uint16,
                uint8,
                bool
            ) {
                sqrtPriceX96 = sp;
            } catch {
                return (0, 0, false);
            }
            if (sqrtPriceX96 == 0) {
                return (0, 0, false);
            }

            rawPriceScaled = getRawPriceScaled(
                sqrtPriceX96,
                poolInfo.token0 == tokenA,
                poolInfo.token0Decimals,
                poolInfo.token1Decimals
            );
        } else if (poolType == ArbUtils.PoolType.PANCAKESWAP_V3) {
            IPancakeV3Pool v3Pool = IPancakeV3Pool(poolAddr);
            uint160 sqrtPriceX96;
            try v3Pool.slot0() returns (
                uint160 sp,
                int24,
                uint16,
                uint16,
                uint16,
                uint32,
                bool
            ) {
                sqrtPriceX96 = sp;
            } catch {
                return (0, 0, false);
            }
            if (sqrtPriceX96 == 0) {
                return (0, 0, false);
            }

            rawPriceScaled = getRawPriceScaled(
                sqrtPriceX96,
                poolInfo.token0 == tokenA,
                poolInfo.token0Decimals,
                poolInfo.token1Decimals
            );
        } else if (
            poolType == ArbUtils.PoolType.V2 ||
            poolType == ArbUtils.PoolType.PANCAKESWAP_V2
        ) {
            IUniswapV2Pair v2Pool = IUniswapV2Pair(poolAddr);
            (uint112 r0, uint112 r1, ) = v2Pool.getReserves();
            if (r0 == 0 || r1 == 0) {
                return (0, 0, false);
            }

            rawPriceScaled = getV2RawPriceScaled(
                tokenA,
                tokenB,
                r0,
                r1,
                poolInfo.token0,
                poolInfo.token1,
                poolInfo.token0Decimals,
                poolInfo.token1Decimals
            );
        } else {
            return (0, 0, false);
        }

        if (rawPriceScaled == 0) {
            return (0, 0, false);
        }

        if (
            poolType == ArbUtils.PoolType.V3 ||
            poolType == ArbUtils.PoolType.PANCAKESWAP_V3
        ) {
            effBuyPrice = getEffectiveBuyPrice(rawPriceScaled, poolFee);
            effSellPrice = getEffectiveSellPrice(rawPriceScaled, poolFee);
        } else {
            // V2 pools
            effBuyPrice = getV2EffectiveBuyPrice(rawPriceScaled, poolFee);
            effSellPrice = getV2EffectiveSellPrice(rawPriceScaled, poolFee);
        }

        return (effBuyPrice, effSellPrice, true);
    }

    // Snapshot fields reused across sizing/simulation in one iteration.
    struct PoolStatesForIteration {
        uint160 sqrtPrice;
        int24 tick;
        uint128 liquidity;
        address token0;
    }

    struct V3SwapParams {
        bool shouldContinue; // True if all pre-checks pass and iteration can proceed.
        uint256 chunkToSwap; // Coarse upper bound; refined by findBestV3Chunk.
        uint160 sqrtPriceLimitA; // Price limit for swap in pool A
        uint160 sqrtPriceLimitB; // Price limit for swap in pool B
        uint256 intermediateAmountPotentiallyFromA; // intermOutA before pool-B capacity clamp
        uint256 intermediateCapacityOfB; // max intermediate token pool B can absorb in-window
        PoolStatesForIteration poolAState;
        PoolStatesForIteration poolBState;
        bool zeroForOneA; // Swap direction for pool A
        bool zeroForOneB; // Swap direction for pool B
        uint24 feeB; // Pool-B fee used in simulation
    }

    struct IterationConfig {
        uint16 minSpreadBps; // Minimum spread required to continue iteration
        uint16 chunkSpreadConsumptionBps; // CHUNK_SPREAD_CONSUMPTION_BPS
        uint256 bpsDivisor; // BPS_DIVISOR
        uint256 maxImpactBps; // _MAX_IMPACT_BPS
        uint256 minChunkForStartToken; // _minChunk(startToken)
        uint256 currentStartTokenBalance; // For balance cap
        int24 initialAbsSpread; // For dynamic move calculation
    }

    struct V4V3RouteParams {
        uint256 principal;
        uint160 sqrtPriceLimitX96;
        int24 spread;
    }

    /// @notice Size the counter-swap that restores a just-traded v4 pool toward an external V3 price.
    /// @dev The v4 leg sells the triggering swap's output token, so only a directional spread is valid.
    function getV4V3RouteParams(
        PoolStatesForIteration memory v4State,
        uint24 v4Fee,
        address startToken,
        address intermediateToken,
        ArbUtils.PoolInfo memory externalPool,
        IterationConfig memory config
    ) external view returns (V4V3RouteParams memory route) {
        if (
            (externalPool.poolType != ArbUtils.PoolType.V3 &&
                externalPool.poolType != ArbUtils.PoolType.PANCAKESWAP_V3) ||
            externalPool.token0 != v4State.token0 ||
            !((externalPool.token0 == startToken && externalPool.token1 == intermediateToken) ||
                (externalPool.token1 == startToken && externalPool.token0 == intermediateToken))
        ) return route;

        uint160 externalSqrtPriceX96;
        int24 externalTick;
        if (externalPool.poolType == ArbUtils.PoolType.V3) {
            try IUniswapV3Pool(externalPool.poolAddress).slot0() returns (
                uint160 sqrtPriceX96,
                int24 tick,
                uint16,
                uint16,
                uint16,
                uint8,
                bool
            ) {
                externalSqrtPriceX96 = sqrtPriceX96;
                externalTick = tick;
            } catch {
                return route;
            }
        } else {
            try IPancakeV3Pool(externalPool.poolAddress).slot0() returns (
                uint160 sqrtPriceX96,
                int24 tick,
                uint16,
                uint16,
                uint16,
                uint32,
                bool
            ) {
                externalSqrtPriceX96 = sqrtPriceX96;
                externalTick = tick;
            } catch {
                return route;
            }
        }

        uint128 externalLiquidity;
        try IUniswapV3Pool(externalPool.poolAddress).liquidity() returns (uint128 liquidity) {
            externalLiquidity = liquidity;
        } catch {
            return route;
        }
        if (v4State.liquidity == 0 || externalLiquidity == 0 || externalSqrtPriceX96 == 0) return route;

        bool zeroForOneV4 = v4State.token0 == startToken;
        route.spread = zeroForOneV4 ? v4State.tick - externalTick : externalTick - v4State.tick;
        if (route.spread < int24(uint24(config.minSpreadBps))) return route;

        bool startIsToken0 = externalPool.token0 == startToken;
        uint256 v4RawPrice = getRawPriceScaled(
            v4State.sqrtPrice,
            startIsToken0,
            externalPool.token0Decimals,
            externalPool.token1Decimals
        );
        uint256 externalRawPrice = getRawPriceScaled(
            externalSqrtPriceX96,
            startIsToken0,
            externalPool.token0Decimals,
            externalPool.token1Decimals
        );
        if (
            getEffectiveSellPrice(v4RawPrice, v4Fee) <=
            getEffectiveBuyPrice(externalRawPrice, externalPool.fee)
        ) return route;

        uint256 initialSpread = uint24(config.initialAbsSpread);
        if (initialSpread == 0 || config.maxImpactBps == 0) return route;
        uint256 move =
            (uint24(route.spread) *
                (uint256(config.chunkSpreadConsumptionBps) +
                    (2000 * uint24(route.spread)) /
                    initialSpread)) /
            (2 * config.bpsDivisor);
        if (move == 0) move = 1;
        if (move > config.maxImpactBps) move = config.maxImpactBps;

        int256 targetV4Tick = int256(v4State.tick) + (zeroForOneV4 ? -int256(move) : int256(move));
        if (targetV4Tick < TickMath.MIN_TICK) targetV4Tick = TickMath.MIN_TICK;
        if (targetV4Tick > TickMath.MAX_TICK) targetV4Tick = TickMath.MAX_TICK;
        route.sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(int24(targetV4Tick));

        bool zeroForOneExternal = externalPool.token0 == intermediateToken;
        int256 targetExternalTick =
            int256(externalTick) + (zeroForOneExternal ? -int256(move) : int256(move));
        if (targetExternalTick < TickMath.MIN_TICK) targetExternalTick = TickMath.MIN_TICK;
        if (targetExternalTick > TickMath.MAX_TICK) targetExternalTick = TickMath.MAX_TICK;

        (uint256 startIn, uint256 intermediateOut) = ArbMath._deltaAmounts(
            zeroForOneV4,
            v4State.sqrtPrice,
            route.sqrtPriceLimitX96,
            v4State.liquidity
        );
        (uint256 externalCapacity, ) = ArbMath._deltaAmounts(
            zeroForOneExternal,
            externalSqrtPriceX96,
            TickMath.getSqrtRatioAtTick(int24(targetExternalTick)),
            externalLiquidity
        );
        if (startIn == 0 || intermediateOut == 0 || externalCapacity == 0) return route;

        route.principal = intermediateOut > externalCapacity
            ? FullMath.mulDiv(startIn, externalCapacity, intermediateOut)
            : startIn;
        if (route.principal > config.currentStartTokenBalance) {
            route.principal = config.currentStartTokenBalance;
        }
        if (route.principal < config.minChunkForStartToken) route.principal = 0;
    }

    /*───────────────────────────────────────────────────────────────────────────
     *  Internal: profit-maximising binary search for V3↔V3 chunk sizing
     *─────────────────────────────────────────────────────────────────────────*/
    function _binarySearchBestChunk(
        uint256 hi, // upper bound (already ≤ balance, ≤ capacity-derived)
        uint256 lo, // lower bound (= _minChunk)
        uint256 intermOut_full, // intermOutA produced by `hi`
        uint256 intermCapB, // exactCapacity of pool B
        uint256 poolB_maxIn, // ΔB.in to reach sqrtPriceLimitB
        uint256 poolB_maxStartOut, // ΔA.out obtainable at sqrtPriceLimitB
        uint24 feeB // pool B fee
    ) private pure returns (uint256 bestChunk, int256 bestScore) {
        if (hi < lo) return (0, 0);

        uint256 fullChunk = hi;
        bestScore = -type(int256).max;
        bestChunk = 0;

        for (uint8 iter; iter < 16 && lo <= hi; ++iter) {
            // Bounded binary search keeps execution predictable inside hook callbacks.
            // 16 rounds is enough once `hi` is already a narrow, liquidity-derived bound.
            uint256 mid = (lo + hi) >> 1; // mid = (lo+hi)/2

            // Approximate scaling in the local execution window.
            // This is intentionally heuristic; exact tick-by-tick simulation is too costly here.
            uint256 intermOut_mid = FullMath.mulDiv(
                intermOut_full,
                mid,
                fullChunk
            );
            uint256 intermInB_mid = intermOut_mid > intermCapB
                ? intermCapB
                : intermOut_mid;
            if (intermInB_mid == 0) {
                if (mid > 0) {
                    hi = mid - 1;
                } else {
                    break;
                }
                continue;
            }

            uint256 startOut_mid = FullMath.mulDiv(
                poolB_maxStartOut,
                intermInB_mid,
                poolB_maxIn
            );
            int256 scoreMid = ArbMath._edgeScore(
                mid,
                intermOut_mid,
                intermCapB,
                feeB,
                intermInB_mid,
                startOut_mid
            );

            if (scoreMid > bestScore) {
                // strictly better ranking?
                bestScore = scoreMid;
                bestChunk = mid;
            }

            // classic binary-search – keep searching toward the profitable side
            if (scoreMid > 0) {
                lo = mid + 1;
            } else {
                if (mid == 0) break;
                hi = mid - 1;
            }
        }

        if (bestScore <= 0) bestChunk = 0; // no edge detected after search
    }

    // Part 1 of V3 sizing:
    // gather live pool state, compute a coarse chunk and swap limits, then
    // hand off to findBestV3Chunk for bounded profit search.
    function getV3SwapParameters(
        address poolA_address,
        address poolB_address,
        address startToken,
        address intermediateToken,
        IterationConfig memory config,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType
    ) public view returns (V3SwapParams memory params) {
        // Keep this function read-heavy and deterministic; avoid deep search loops here.
        params.shouldContinue = false; // Default to not continuing

        IUniswapV3Pool pA = IUniswapV3Pool(poolA_address);
        IUniswapV3Pool pB = IUniswapV3Pool(poolB_address);

        // --- Fetch FRESH State Inside Loop (as it was in IterativeArbBot) ---
        if (poolAType == ArbUtils.PoolType.V3) {
            try pA.slot0() returns (
                uint160 spA,
                int24 tA,
                uint16,
                uint16,
                uint16,
                uint8,
                bool
            ) {
                params.poolAState.sqrtPrice = spA;
                params.poolAState.tick = tA;
            } catch {
                revert ArbErrors.IIAELoopSlot0FailedPoolA();
            }
        } else {
            // PANCAKESWAP_V3
            try IPancakeV3Pool(poolA_address).slot0() returns (
                uint160 spA,
                int24 tA,
                uint16,
                uint16,
                uint16,
                uint32,
                bool
            ) {
                params.poolAState.sqrtPrice = spA;
                params.poolAState.tick = tA;
            } catch {
                revert ArbErrors.IIAELoopSlot0FailedPoolA();
            }
        }

        if (poolBType == ArbUtils.PoolType.V3) {
            try pB.slot0() returns (
                uint160 spB,
                int24 tB,
                uint16,
                uint16,
                uint16,
                uint8,
                bool
            ) {
                params.poolBState.sqrtPrice = spB;
                params.poolBState.tick = tB;
            } catch {
                revert ArbErrors.IIAELoopSlot0FailedPoolB();
            }
        } else {
            // PANCAKESWAP_V3
            try IPancakeV3Pool(poolB_address).slot0() returns (
                uint160 spB,
                int24 tB,
                uint16,
                uint16,
                uint16,
                uint32,
                bool
            ) {
                params.poolBState.sqrtPrice = spB;
                params.poolBState.tick = tB;
            } catch {
                revert ArbErrors.IIAELoopSlot0FailedPoolB();
            }
        }

        try pA.liquidity() returns (uint128 lA) {
            params.poolAState.liquidity = lA;
        } catch {
            revert ArbErrors.IIAELoopLiquidityFailedPoolA();
        }

        try pB.liquidity() returns (uint128 lB) {
            params.poolBState.liquidity = lB;
        } catch {
            revert ArbErrors.IIAELoopLiquidityFailedPoolB();
        }

        try pA.token0() returns (address t0A) {
            params.poolAState.token0 = t0A;
        } catch {
            revert ArbErrors.IIAELoopToken0FailedPoolA();
        }
        // Token0 for B is fetched when needed for zeroForOneB

        // --- Check Spread for stopping condition ---
        params.zeroForOneA = (params.poolAState.token0 == startToken);
        int24 currentSignedSpread;
        if (params.zeroForOneA) {
            currentSignedSpread =
                params.poolAState.tick -
                params.poolBState.tick;
        } else {
            currentSignedSpread =
                params.poolBState.tick -
                params.poolAState.tick;
        }
        int24 currentAbsSpread = currentSignedSpread >= 0
            ? currentSignedSpread
            : -currentSignedSpread;

        if (
            currentAbsSpread < int24(uint24(config.minSpreadBps)) ||
            params.poolAState.liquidity == 0 ||
            params.poolBState.liquidity == 0
        ) {
            return params; // shouldContinue is false, stop here
        }

        // Convert spread into a target move window.
        // Larger remaining spread -> larger step; tighter spread -> smaller step.
        int24 move;
        uint16 moveBpsAdaptive;
        unchecked {
            uint32 curSpreadAbs = uint32(uint24(currentAbsSpread));
            uint32 initSpreadAbs = uint32(uint24(config.initialAbsSpread));
            if (initSpreadAbs == 0) {
                return params; // shouldContinue remains false
            }
            uint32 pctOfInitialSpread = (curSpreadAbs * 100) / initSpreadAbs;
            moveBpsAdaptive = uint16(
                config.chunkSpreadConsumptionBps + // 1500 (15%)
                    (2000 * pctOfInitialSpread) / // up to 2000 (20%)
                    100
            ); // Total: 15% to 35% of current spread
            uint256 tmpMove = (uint256(curSpreadAbs) * moveBpsAdaptive) /
                (2 * config.bpsDivisor); // Reverted to original divisor
            move = int24(int256(tmpMove));
        }
        if (move == 0) move = 1;
        if (config.maxImpactBps == 0) return params;
        if (uint256(uint24(move)) > config.maxImpactBps) {
            move = int24(uint24(config.maxImpactBps));
        }

        // --- Price limits --------------------------------------------------------
        params.zeroForOneB = (IUniswapV3Pool(poolB_address).token0() ==
            intermediateToken); // Fetch token0 for B here

        int24 targetTickA = params.zeroForOneA
            ? params.poolAState.tick - move
            : params.poolAState.tick + move;
        if (targetTickA < TickMath.MIN_TICK) targetTickA = TickMath.MIN_TICK;
        if (targetTickA > TickMath.MAX_TICK) targetTickA = TickMath.MAX_TICK;
        params.sqrtPriceLimitA = TickMath.getSqrtRatioAtTick(targetTickA);

        int24 targetTickB = params.zeroForOneB
            ? params.poolBState.tick - move
            : params.poolBState.tick + move;
        if (targetTickB < TickMath.MIN_TICK) targetTickB = TickMath.MIN_TICK;
        if (targetTickB > TickMath.MAX_TICK) targetTickB = TickMath.MAX_TICK;
        params.sqrtPriceLimitB = TickMath.getSqrtRatioAtTick(targetTickB);

        // Coarse upper bound:
        // amount needed to move pool A by `move`, then clamped to what pool B can absorb.
        (uint256 startInA, uint256 intermOutA) = ArbMath._deltaAmounts(
            params.zeroForOneA,
            params.poolAState.sqrtPrice,
            params.sqrtPriceLimitA, // Target sqrtPrice for pool A based on move
            params.poolAState.liquidity
        );
        params.intermediateAmountPotentiallyFromA = intermOutA;

        params.intermediateCapacityOfB = ArbMath._exactCapacity(
            address(pB), // Pass address instead of interface
            params.zeroForOneB,
            params.poolBState.sqrtPrice,
            params.sqrtPriceLimitB,
            params.poolBState.tick,
            params.poolBState.liquidity
        );

        uint256 chunkBalanced = (intermOutA > 0 &&
            intermOutA > params.intermediateCapacityOfB)
            ? FullMath.mulDiv(
                startInA,
                params.intermediateCapacityOfB * 102,
                intermOutA * 100
            ) // +2% flexibility
            : startInA;

        // --- Apply Balance Cap ---
        uint256 currentChunkPreImpact = Math.min(
            chunkBalanced,
            config.currentStartTokenBalance
        );
        if (currentChunkPreImpact == 0) {
            return params; // shouldContinue is false
        }

        uint256 roughChunk = currentChunkPreImpact;

        if (roughChunk < config.minChunkForStartToken) {
            return params; // still false
        }

        // Binary-search refinement happens in findBestV3Chunk.

        try IUniswapV3Pool(poolB_address).fee() returns (uint24 fB) {
            params.feeB = fB;
        } catch {
            return params;
        }

        params.chunkToSwap = roughChunk; // This is now the rough chunk upper bound
        params.shouldContinue = true; // success – calculation may proceed

        params.poolBState.token0 = IUniswapV3Pool(poolB_address).token0(); // Ensure it's stored

        return params;
    }

    // Part 2 of V3 sizing:
    // use coarse parameters from getV3SwapParameters and select the best executable chunk.
    /// @return bestChunk Chunk size to execute, or zero when no edge was detected.
    /// @return edgeScore Relative ranking score for `bestChunk`. See `ArbMath._edgeScore`:
    ///         this is not a token amount and must not be compared against currency.
    function findBestV3Chunk(
        V3SwapParams memory params,
        uint256 minChunkForStartToken
    ) public pure returns (uint256 bestChunk, int256 edgeScore) {
        (uint256 poolB_maxIn, uint256 poolB_maxStartOut) = ArbMath
            ._deltaAmounts(
                params.zeroForOneB,
                params.poolBState.sqrtPrice,
                params.sqrtPriceLimitB,
                params.poolBState.liquidity
            );

        (bestChunk, edgeScore) = _binarySearchBestChunk(
            params.chunkToSwap, // This is the roughChunk (upper bound)
            minChunkForStartToken,
            params.intermediateAmountPotentiallyFromA,
            params.intermediateCapacityOfB,
            poolB_maxIn,
            poolB_maxStartOut,
            params.feeB
        );

        if (bestChunk == 0) {
            edgeScore = 0;
        }
    }

    function estimateImpactBps(
        address pool,
        address tokenIn,
        uint256 amountIn
    ) public view returns (uint256) {
        return ArbMath._estImpactBps(pool, tokenIn, amountIn);
    }

    // --- Uniswap V2 Price Calculation Functions ---

    /**
     * @notice Calculates the raw price of tokenA in terms of tokenB for a V2 pool, scaled to 1e18.
     * @param tokenA Address of tokenA (the token whose price is being measured).
     * @param tokenB Address of tokenB (the token in which the price is expressed).
     * @return rawPriceScaled The price of tokenA in terms of tokenB, scaled by 1e18. Returns 0 if liquidity is 0.
     */
    function getV2RawPriceScaled(
        address tokenA,
        address tokenB,
        uint112 reserve0,
        uint112 reserve1,
        address pairToken0,
        address pairToken1,
        uint8 decimalsA,
        uint8 decimalsB
    ) private pure returns (uint256 rawPriceScaled) {
        if (reserve0 == 0 || reserve1 == 0) {
            return 0; // No liquidity or one-sided liquidity, no valid price
        }

        uint256 rA;
        uint256 rB;

        if (tokenA == pairToken0) {
            // tokenA is token0, tokenB is token1
            rA = reserve0;
            rB = reserve1;
        } else {
            // tokenA is token1, tokenB is token0
            if (tokenA != pairToken1 || tokenB != pairToken0)
                revert ArbErrors.SwapInputTokenNotInPool(); // Or a more specific V2 error
            rA = reserve1;
            rB = reserve0;
        }

        if (rA == 0) return 0; // Avoid division by zero, though covered by initial reserve check

        // Price of A in terms of B = (Reserve B / Reserve A)
        // Scaled: (rB * 10^decA / rA) * (1e18 / 10^decB)
        // More robust: (rB * 10^decA * 1e18) / (rA * 10^decB)
        // To avoid overflow with 1e18 first, use FullMath.mulDiv
        // (rB / rA) * (10^decimalsA / 10^decimalsB) * 1e18
        // P = (reserveB / reserveA) * (10^decimalsA / 10^decimalsB)
        // priceScaled = P * 1e18 = (reserveB * 10^decimalsA * 1e18) / (reserveA * 10^decimalsB)

        uint256 tenPowDecA = 10 ** decimalsA;
        uint256 tenPowDecB = 10 ** decimalsB;

        // Intermediate for precision: (rB * tenPowDecA)
        uint256 numeratorPart = FullMath.mulDiv(rB, tenPowDecA, 1);
        // Denominator: (rA * tenPowDecB)
        uint256 denominatorPart = FullMath.mulDiv(rA, tenPowDecB, 1);

        if (denominatorPart == 0) return 0; // Should be caught by rA == 0

        rawPriceScaled = FullMath.mulDiv(numeratorPart, 1e18, denominatorPart);
        return rawPriceScaled;
    }

    /**
     * @notice Calculates the effective V2 buy price for tokenA with tokenB, including fees.
     * @param rawV2PriceScaled The raw V2 price (tokenB per tokenA, 1e18).
     * @param v2FeePPM The V2 pool fee in parts per million (e.g., 3000 for 0.3%).
     * @return effectiveBuyPrice The fee-adjusted price for buying tokenA in a V2 pool.
     */
    function getV2EffectiveBuyPrice(
        uint256 rawV2PriceScaled,
        uint24 v2FeePPM
    ) private pure returns (uint256 effectiveBuyPrice) {
        // To buy tokenA, you pay more of tokenB. Price B/A increases.
        // The amount of tokenB needed is rawV2PriceScaled / (1 - feeRate)
        // Example: Fee 0.3% (3000 PPM). Rate = 0.003. 1 - feeRate = 0.997
        // effectivePrice = rawPrice / 0.997 = rawPrice * 1000 / 997 (if fee is exactly 0.3%)
        // Using PPM: effectivePrice = rawPrice * 1_000_000 / (1_000_000 - v2FeePPM)
        if (1_000_000 - v2FeePPM == 0) return type(uint256).max; // Avoid div by zero if fee is 100%
        return
            FullMath.mulDiv(rawV2PriceScaled, 1_000_000, 1_000_000 - v2FeePPM);
    }

    /**
     * @notice Calculates the effective V2 sell price for tokenA for tokenB, including fees.
     * @param rawV2PriceScaled The raw V2 price (tokenB per tokenA, 1e18).
     * @param v2FeePPM The V2 pool fee in parts per million (e.g., 3000 for 0.3%).
     * @return effectiveSellPrice The fee-adjusted price for selling tokenA in a V2 pool.
     */
    function getV2EffectiveSellPrice(
        uint256 rawV2PriceScaled,
        uint24 v2FeePPM
    ) private pure returns (uint256 effectiveSellPrice) {
        // To sell tokenA, you receive less of tokenB. Price B/A decreases.
        // The amount of tokenB received is rawV2PriceScaled * (1 - feeRate)
        // Example: Fee 0.3%. Rate = 0.003. 1 - feeRate = 0.997
        // effectivePrice = rawPrice * 0.997 = rawPrice * 997 / 1000 (if fee is exactly 0.3%)
        // Using PPM: effectivePrice = rawPrice * (1_000_000 - v2FeePPM) / 1_000_000
        return
            FullMath.mulDiv(rawV2PriceScaled, 1_000_000 - v2FeePPM, 1_000_000);
    }

    struct V2TradeParams {
        bool opportunityExists;
        uint256 estimatedChunkToSwap; // Amount of startToken
        int256 expectedProfitFromChunk; // Estimated profit in startToken
    }

    /**
     * @notice Calculates an estimated trade chunk and expected profit for a V2-V2 arbitrage opportunity.
     * @dev This is a heuristic approach. True optimal amount can be complex to calculate on-chain.
     * @param poolA_addr Address of the first V2 pool (where startToken is sold for intermediateToken).
     * @param poolB_addr Address of the second V2 pool (where intermediateToken is sold for startToken).
     * @param startToken Address of the initial token (and token profit is measured in).
     * @param intermediateToken Address of the token swapped between pools.
     * @param startTokenBalance Current balance of startToken held by the caller (for capping).
     * @param minChunkStartToken Minimum meaningful chunk size for startToken.
     * @return params A V2TradeParams struct.
     */
    function calculateV2TradeParams(
        address poolA_addr,
        address poolB_addr,
        address startToken,
        address intermediateToken,
        uint256 startTokenBalance,
        uint256 minChunkStartToken,
        uint24 poolAFeePPM,
        uint24 poolBFeePPM
    ) public view returns (V2TradeParams memory params) {
        params.opportunityExists = false; // Default to no opportunity

        IUniswapV2Pair poolA = IUniswapV2Pair(poolA_addr);
        IUniswapV2Pair poolB = IUniswapV2Pair(poolB_addr);

        // Ensure tokens are correct for the pools
        // Pool A: startToken -> intermediateToken
        // Pool B: intermediateToken -> startToken
        // (Simplified checks here, more robust checks can be added)
        if (
            !((poolA.token0() == startToken &&
                poolA.token1() == intermediateToken) ||
                (poolA.token1() == startToken &&
                    poolA.token0() == intermediateToken)) ||
            !((poolB.token0() == intermediateToken &&
                poolB.token1() == startToken) ||
                (poolB.token1() == intermediateToken &&
                    poolB.token0() == startToken))
        ) {
            // This basic check might not be sufficient if token order within pair matters for general logic
            return params;
        }

        (
            uint112 reserveA_start,
            uint112 reserveA_interm,

        ) = _getV2ReservesForTokens(poolA, startToken, intermediateToken);
        (
            uint112 reserveB_interm,
            uint112 reserveB_start,

        ) = _getV2ReservesForTokens(poolB, intermediateToken, startToken);

        if (
            reserveA_start == 0 ||
            reserveA_interm == 0 ||
            reserveB_interm == 0 ||
            reserveB_start == 0
        ) {
            return params; // Not enough liquidity in one of the pools
        }

        uint256 minimumChunk = minChunkStartToken == 0
            ? 1
            : minChunkStartToken;
        if (startTokenBalance < minimumChunk) return params;

        // Heuristic probe ladder.
        // Exact optimal V2-V2 size is possible off-chain but expensive on-chain,
        // so we probe representative sizes and pick the best simulated outcome.
        // The largest probe (50% balance) is intentional: slippage usually makes
        // oversizing fail fast, and smaller candidates are then cheap to test.
        uint256[4] memory testChunkSizes;
        testChunkSizes[0] = minimumChunk;
        testChunkSizes[1] = startTokenBalance / 100; // 1% of balance
        testChunkSizes[2] = startTokenBalance / 10; // 10% of balance
        testChunkSizes[3] = startTokenBalance / 2; // 50% of balance

        int256 bestSimulatedProfit = -type(int256).max; // Initialize with very small number
        uint256 bestChunk = 0;

        for (uint i = 0; i < testChunkSizes.length; i++) {
            uint256 currentTestChunk = testChunkSizes[i];
            if (currentTestChunk == 0) continue;
            if (currentTestChunk < minimumChunk)
                currentTestChunk = minimumChunk;

            // Skip duplicate probes when balance is small and ratios collapse to same value.
            if (
                i > 0 &&
                currentTestChunk == testChunkSizes[i - 1] &&
                currentTestChunk != minimumChunk
            ) continue;
            if (i > 0 && currentTestChunk == bestChunk) continue; // Already found as best or tested

            int256 simulatedProfit = simulateV2V2Profit(
                currentTestChunk,
                reserveA_start,
                reserveA_interm,
                reserveB_interm,
                reserveB_start,
                poolAFeePPM,
                poolBFeePPM
            );

            if (simulatedProfit > bestSimulatedProfit) {
                bestSimulatedProfit = simulatedProfit;
                bestChunk = currentTestChunk;
            }
        }

        if (bestSimulatedProfit > 0) {
            params.opportunityExists = true;
            params.estimatedChunkToSwap = bestChunk;
            params.expectedProfitFromChunk = bestSimulatedProfit;
        }

        return params;
    }

    /**
     * @notice Simulates the profit/loss from a V2-V2 arbitrage trade for a given chunk.
     * @param chunkToSwapStartToken Amount of startToken to swap in the first pool.
     * @param rA_start Reserve of startToken in Pool A.
     * @param rA_interm Reserve of intermediateToken in Pool A.
     * @param rB_interm Reserve of intermediateToken in Pool B.
     * @param rB_start Reserve of startToken in Pool B.
     * @return profitInStartToken The net profit or loss in startToken units.
     */
    function simulateV2V2Profit(
        uint256 chunkToSwapStartToken,
        uint112 rA_start,
        uint112 rA_interm,
        uint112 rB_interm,
        uint112 rB_start,
        uint24 poolAFeePPM,
        uint24 poolBFeePPM
    ) public pure returns (int256 profitInStartToken) {
        if (chunkToSwapStartToken == 0) return 0;


        // Trade 1 (Pool A): startToken -> intermediateToken
        uint256 intermediateAmountOut = getAmountOut(
            chunkToSwapStartToken,
            rA_start,
            rA_interm,
            poolAFeePPM
        );


        if (intermediateAmountOut == 0) {
            return -int256(chunkToSwapStartToken); // Full loss if no intermediate token received
        }


        // Trade 2 (Pool B): intermediateToken -> startToken
        uint256 startTokenReceivedBack = getAmountOut(
            intermediateAmountOut,
            rB_interm,
            rB_start,
            poolBFeePPM
        );


        if (startTokenReceivedBack > chunkToSwapStartToken) {
            return int256(startTokenReceivedBack - chunkToSwapStartToken);
        } else {
            return -int256(chunkToSwapStartToken - startTokenReceivedBack);
        }
    }

    /**
     * @notice Helper to get V2 reserves for a specific pair of tokens.
     * @param pair The IUniswapV2Pair contract.
     * @param token0Addr Address of the first token.
     * @param token1Addr Address of the second token.
     * @return reserve0 Reserve of token0Addr in the pair.
     * @return reserve1 Reserve of token1Addr in the pair.
     * @return lastBlockTimestamp The last block timestamp (not used here but part of getReserves).
     */
    function _getV2ReservesForTokens(
        IUniswapV2Pair pair,
        address token0Addr,
        address token1Addr
    )
        public
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 lastBlockTimestamp)
    {
        (uint112 r0, uint112 r1, uint32 ts) = pair.getReserves();
        address pairToken0 = pair.token0();

        if (token0Addr == pairToken0) {
            // token0Addr is pair.token0, token1Addr must be pair.token1
            if (token1Addr != pair.token1())
                revert("Token mismatch in _getV2ReservesForTokens");
            return (r0, r1, ts);
        } else {
            // token0Addr is pair.token1, token1Addr must be pair.token0
            if (token0Addr != pair.token1() || token1Addr != pairToken0)
                revert("Token mismatch in _getV2ReservesForTokens");
            return (r1, r0, ts);
        }
    }

    /**
     * @notice Pure function to calculate Uniswap V2 getAmountOut.
     * @param amountIn Amount of input tokens.
     * @param reserveIn Reserve of input tokens in the pool.
     * @param reserveOut Reserve of output tokens in the pool.
     * @return amountOut Amount of output tokens received.
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint24 feePPM
    ) public pure returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        if (reserveIn == 0 || reserveOut == 0) return 0;
        if (feePPM >= 1_000_000) return 0;

        uint256 amountInWithFee = FullMath.mulDiv(
            amountIn,
            1_000_000 - feePPM,
            1_000_000
        );
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn + amountInWithFee;
        amountOut = numerator / denominator;
        return amountOut;
    }

    // [NEW] Improve multi-step simulation for better accuracy (reduce partials)
    function calculateV3SqrtPriceLimitForAmountIn(
        IUniswapV3Pool pool,
        address tokenIn,
        uint256 amountIn,
        uint16 slippageBps
    ) public view returns (uint160 sqrtPriceLimitX96) {
        if (amountIn == 0) return 0;

        // [OPT] Cache slot0 and liquidity once
        (uint160 sqrtP, int24 currentTick, , , , , ) = pool.slot0(); // Cache feeProtocol if needed, but unused
        uint24 fee = pool.fee(); // Cache fee
        uint128 liquidity = pool.liquidity();
        address token0 = pool.token0();

        bool zeroForOne = tokenIn == token0;
        int256 amountRemaining = int256(amountIn);

        // Approximate multi-step fill to derive a conservative price limit.
        // This deliberately trades perfect precision for bounded gas.
        uint8 maxSteps = 5; // Cap to avoid high gas on deep liquidity
        for (uint8 step = 0; step < maxSteps && amountRemaining > 0; step++) {
            (uint160 sqrtQ, uint256 stepAmountIn, , ) = SwapMath
                .computeSwapStep(
                    sqrtP,
                    zeroForOne
                        ? TickMath.MIN_SQRT_RATIO + 1
                        : TickMath.MAX_SQRT_RATIO - 1,
                    liquidity,
                    amountRemaining,
                    fee
                );

            sqrtP = sqrtQ;
            amountRemaining -= int256(stepAmountIn);
            if (stepAmountIn == 0) break; // Early break if no progres

            // Simulate tick cross (simplified: assume next tick has same liquidity; real would query tick data)
            if (amountRemaining > 0) {
                currentTick += zeroForOne ? -1 : int8(1); // Approximate next tick
                // In real, update liquidity from pool.liquidity() but it's constant; for accuracy, would need tick data
            }
        }

        // Apply slippage to final simulated sqrtP
        uint256 slippageFactor = zeroForOne
            ? (10000 - slippageBps)
            : (10000 + slippageBps);
        sqrtPriceLimitX96 = uint160(
            FullMath.mulDiv(sqrtP, slippageFactor, 10000)
        );
        // Clamp to min/max
        if (zeroForOne && sqrtPriceLimitX96 < TickMath.MIN_SQRT_RATIO + 1)
            return TickMath.MIN_SQRT_RATIO + 1;
        if (!zeroForOne && sqrtPriceLimitX96 > TickMath.MAX_SQRT_RATIO - 1)
            return TickMath.MAX_SQRT_RATIO - 1;


        return sqrtPriceLimitX96;
    }

    /**
     * @notice Simulates the profit/loss from a V2 -> V3 arbitrage trade.
     * @dev Uses a simplified model for V3 output estimation based on current price.
     * @param chunkToSwapStartToken Amount of startToken to swap in the first pool (V2).
     * @param poolA The first V2 pair.
     * @param poolB The second V3 pool.
     * @param startToken The token being arbitraged.
     * @param intermediateToken The token swapped between pools.
     * @return profitInStartToken The net profit or loss in startToken units.
     */
    function simulateV2V3Profit(
        uint256 chunkToSwapStartToken,
        IUniswapV2Pair poolA,
        IUniswapV3Pool poolB,
        address startToken,
        address intermediateToken,
        uint24 poolAFeePPM
    ) private view returns (int256 profitInStartToken) {
        if (chunkToSwapStartToken == 0) return 0;


        // Step 1: Simulate V2 swap (startToken -> intermediateToken)
        (uint112 rA_start, uint112 rA_interm, ) = _getV2ReservesForTokens(
            poolA,
            startToken,
            intermediateToken
        );
        if (rA_start == 0 || rA_interm == 0)
            return -int256(chunkToSwapStartToken);


        uint256 intermediateAmountOut = getAmountOut(
            chunkToSwapStartToken,
            rA_start,
            rA_interm,
            poolAFeePPM
        );

        if (intermediateAmountOut == 0) return -int256(chunkToSwapStartToken);

        // Step 2: Accurately simulate V3 swap (intermediateToken -> startToken) using SwapMath
        (uint160 sqrtP, , , , , , ) = poolB.slot0();
        uint128 liquidity = poolB.liquidity();
        address v3_token0 = poolB.token0();
        bool zeroForOne = (intermediateToken == v3_token0);


        if (liquidity == 0) return -int256(chunkToSwapStartToken);

        (
            ,
            ,
            // sqrtRatioNextX96
            // amountIn
            uint256 startTokenReceivedBack, // feeAmount is the 4th value, this is amountOut

        ) = SwapMath.computeSwapStep(
                sqrtP,
                zeroForOne
                    ? TickMath.MIN_SQRT_RATIO + 1
                    : TickMath.MAX_SQRT_RATIO - 1,
                liquidity,
                int256(intermediateAmountOut),
                poolB.fee()
            );



        if (startTokenReceivedBack > chunkToSwapStartToken) {
            return int256(startTokenReceivedBack - chunkToSwapStartToken);
        } else {
            return -int256(chunkToSwapStartToken - startTokenReceivedBack);
        }
    }

    /**
     * @notice Simulates the profit/loss from a V3 -> V2 arbitrage trade.
     * @dev Uses a simplified model for V3 output estimation based on current price.
     * @param chunkToSwapStartToken Amount of startToken to swap in the first pool (V3).
     * @param poolA The first V3 pool.
     * @param poolB The second V2 pair.
     * @param startToken The token being arbitraged.
     * @param intermediateToken The token swapped between pools.
     * @return profitInStartToken The net profit or loss in startToken units.
     */
    function simulateV3V2Profit(
        uint256 chunkToSwapStartToken,
        IUniswapV3Pool poolA,
        IUniswapV2Pair poolB,
        address startToken,
        address intermediateToken,
        uint24 poolBFeePPM
    ) private view returns (int256 profitInStartToken) {
        if (chunkToSwapStartToken == 0) return 0;


        // Step 1: Accurately simulate V3 swap (startToken -> intermediateToken) using SwapMath
        (uint160 sqrtP, , , , , , ) = poolA.slot0();
        uint128 liquidity = poolA.liquidity();
        address v3_token0 = poolA.token0();
        bool zeroForOne = (startToken == v3_token0);


        if (liquidity == 0) return -int256(chunkToSwapStartToken);

        (
            ,
            ,
            // sqrtRatioNextX96, not needed for this simulation
            // amountIn, will be <= chunkToSwapStartToken
            uint256 intermediateAmountOut, // feeAmount

        ) = SwapMath.computeSwapStep(
                sqrtP,
                zeroForOne
                    ? TickMath.MIN_SQRT_RATIO + 1
                    : TickMath.MAX_SQRT_RATIO - 1,
                liquidity,
                int256(chunkToSwapStartToken),
                poolA.fee()
            );


        if (intermediateAmountOut == 0) return -int256(chunkToSwapStartToken);

        // Step 2: Simulate V2 swap (intermediateToken -> startToken)
        (uint112 rB_interm, uint112 rB_start, ) = _getV2ReservesForTokens(
            poolB,
            intermediateToken,
            startToken
        );
        if (rB_start == 0 || rB_interm == 0)
            return -int256(chunkToSwapStartToken);


        uint256 startTokenReceivedBack = getAmountOut(
            intermediateAmountOut,
            rB_interm,
            rB_start,
            poolBFeePPM
        );


        if (startTokenReceivedBack > chunkToSwapStartToken) {
            profitInStartToken = int256(
                startTokenReceivedBack - chunkToSwapStartToken
            );
        } else {
            profitInStartToken = -int256(
                chunkToSwapStartToken - startTokenReceivedBack
            );
        }
        return profitInStartToken;
    }

    function findBestMixedPairChunk(
        address poolA_addr,
        address poolB_addr,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType,
        address startToken,
        address intermediateToken,
        uint256 initialTestChunk,
        uint256 minChunk,
        int256 cumulativeProfit,
        int256 minCumulativeProfit
    ) public view returns (uint256 bestChunk, int256 expectedProfit) {
        // Mixed-path sizing uses monotonic backoff.
        // Start from a large probe and halve until a profitable/safe chunk is found.
        // This minimizes quote simulations while still quickly adapting to impact.
        uint8 halvings = 0;
        uint256 testChunk = initialTestChunk;

        while (true) {
            int256 simulatedProfit;
            if (
                poolAType == ArbUtils.PoolType.V2 ||
                poolAType == ArbUtils.PoolType.PANCAKESWAP_V2
            ) {
                // V2 -> V3 path
                simulatedProfit = simulateV2V3Profit(
                    testChunk,
                    IUniswapV2Pair(poolA_addr),
                    IUniswapV3Pool(poolB_addr),
                    startToken,
                    intermediateToken,
                    poolAType == ArbUtils.PoolType.PANCAKESWAP_V2
                        ? 2500
                        : 3000
                );
            } else {
                // V3 -> V2 path
                simulatedProfit = simulateV3V2Profit(
                    testChunk,
                    IUniswapV3Pool(poolA_addr),
                    IUniswapV2Pair(poolB_addr),
                    startToken,
                    intermediateToken,
                    poolBType == ArbUtils.PoolType.PANCAKESWAP_V2
                        ? 2500
                        : 3000
                );
            }

            if (
                simulatedProfit > 0 &&
                cumulativeProfit + simulatedProfit >= minCumulativeProfit
            ) {
                return (testChunk, simulatedProfit);
            }

            if (halvings >= 9) break; // Max iterations
            testChunk >>= 1; // Use bitwise shift for gas efficiency
            if (testChunk < minChunk) break;
            unchecked {
                halvings++;
            }
        }
    }
}
