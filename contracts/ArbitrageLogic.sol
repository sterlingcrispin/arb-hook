// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./lib/ArbMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol"; // For pool interactions
import "./ArbUtils.sol"; // For PoolInfo struct
import "./Errors.sol"; // For ArbErrors
import "@openzeppelin/contracts/utils/math/Math.sol"; // Import Math
import "./interfaces/IUniswapV2Pair.sol"; // Added for V2
import {SwapMath} from "@uniswap/v3-core/contracts/libraries/SwapMath.sol";
import "./interfaces/IPancakeV3Pool.sol"; // NEW: Add PancakeV3 Pool interface

/**
 * @title ArbitrageLogic
 * @notice A stateless contract providing pure functions for arbitrage calculations.
 */
contract ArbitrageLogic {
    /**
     * @notice Corrected calculation of tokenA price in terms of tokenB, scaled to 1e18.
     * @dev Avoids overflow by using FullMath.mulDiv for intermediate calculations.
     * @param sqrtP_uint160 The current sqrt price ratio from the pool.
     * @param aIsT0 True if tokenA is token0 in the pool, false otherwise.
     * @param dec0_uint8 Decimals of token0.
     * @param dec1_uint8 Decimals of token1.
     * @return price1e18 The price of tokenA in terms of tokenB, scaled by 1e18.
     */
    function _calculatePrice1e18_corrected(uint160 sqrtP_uint160, bool aIsT0, uint8 dec0_uint8, uint8 dec1_uint8)
        private
        pure
        returns (uint256 price1e18)
    {
        return ArbMath._price1e18(sqrtP_uint160, aIsT0, dec0_uint8, dec1_uint8);
    }

    /**
     * @notice Calculates the raw price of tokenA in terms of tokenB, scaled to 1e18.
     * @param sqrtPriceX96 The current sqrt price ratio from the pool.
     * @param aIsToken0 True if tokenA is token0 in the pool, false otherwise.
     * @param dec0 Decimals of token0.
     * @param dec1 Decimals of token1.
     * @return rawPriceScaled The price of tokenA in terms of tokenB, scaled by 1e18.
     */
    function getRawPriceScaled(uint160 sqrtPriceX96, bool aIsToken0, uint8 dec0, uint8 dec1)
        public
        pure
        returns (uint256 rawPriceScaled)
    {
        // Calls the corrected internal function instead of ArbMath._price1e18
        return _calculatePrice1e18_corrected(sqrtPriceX96, aIsToken0, dec0, dec1);
    }

    /**
     * @notice Calculates the effective buy price, including fees.
     * @param rawPriceScaled The raw price (tokenB per tokenA, 1e18).
     * @param poolFee The pool fee in parts per million (ppm).
     * @return effectiveBuyPrice The fee-adjusted price for buying tokenA.
     */
    function getEffectiveBuyPrice(uint256 rawPriceScaled, uint24 poolFee)
        public
        pure
        returns (uint256 effectiveBuyPrice)
    {
        // buy-leg pays the fee -> price increases
        return _effectiveBuyPrice(rawPriceScaled, poolFee);
    }

    /**
     * @notice Calculates the effective sell price, including fees.
     * @param rawPriceScaled The raw price (tokenB per tokenA, 1e18).
     * @param poolFee The pool fee in parts per million (ppm).
     * @return effectiveSellPrice The fee-adjusted price for selling tokenA.
     */
    function getEffectiveSellPrice(uint256 rawPriceScaled, uint24 poolFee)
        public
        pure
        returns (uint256 effectiveSellPrice)
    {
        // sell-leg receives less -> price decreases
        if (poolFee >= 1_000_000) return 0;
        return FullMath.mulDiv(
            rawPriceScaled,
            1_000_000 - poolFee, // -fee (ppm)
            1_000_000
        );
    }

    /// @notice Bitmap-aware V3 dust check for pool discovery.
    /// @dev Uses the nearest initialized tick when supported by the pool, and
    ///      falls back to the next usable tick if a non-standard pool rejects
    ///      the bitmap call.
    function isPoolDustWithBitmap(
        address pool,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity,
        int24 tickSpacing,
        bool zeroForOne,
        uint256 minChunkIn
    ) public view returns (bool isDust) {
        if (liquidity == 0 || tickSpacing <= 0 || sqrtPriceX96 == 0) {
            return true;
        }

        (int24 nextTick,) =
            ArbMath._nextInitializedTickWithinOneWord(IUniswapV3Pool(pool), tick, tickSpacing, zeroForOne);
        // At an initialized zero-for-one boundary the pool can cross the
        // current tick without consuming input. The impact estimator performs
        // the post-cross liquidity check, so this is not dust by itself.
        if (nextTick == tick) return false;

        uint160 sqrtPriceNextTick = TickMath.getSqrtRatioAtTick(nextTick);
        if ((zeroForOne && sqrtPriceNextTick >= sqrtPriceX96) || (!zeroForOne && sqrtPriceNextTick <= sqrtPriceX96)) {
            return true;
        }
        (uint256 probeIn,) = ArbMath._deltaAmounts(zeroForOne, sqrtPriceX96, sqrtPriceNextTick, liquidity);
        return probeIn < minChunkIn;
    }

    // [NEW] Lightweight price fetch for a single pool
    function _getSinglePoolPrices(address tokenA, address tokenB, ArbUtils.PoolInfo memory poolInfo)
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
            try v3Pool.slot0() returns (uint160 sp, int24, uint16, uint16, uint16, uint8, bool) {
                sqrtPriceX96 = sp;
            } catch {
                return (0, 0, false);
            }
            if (sqrtPriceX96 == 0) {
                return (0, 0, false);
            }

            rawPriceScaled = getRawPriceScaled(
                sqrtPriceX96, poolInfo.token0 == tokenA, poolInfo.token0Decimals, poolInfo.token1Decimals
            );
        } else if (poolType == ArbUtils.PoolType.PANCAKESWAP_V3) {
            IPancakeV3Pool v3Pool = IPancakeV3Pool(poolAddr);
            uint160 sqrtPriceX96;
            try v3Pool.slot0() returns (uint160 sp, int24, uint16, uint16, uint16, uint32, bool) {
                sqrtPriceX96 = sp;
            } catch {
                return (0, 0, false);
            }
            if (sqrtPriceX96 == 0) {
                return (0, 0, false);
            }

            rawPriceScaled = getRawPriceScaled(
                sqrtPriceX96, poolInfo.token0 == tokenA, poolInfo.token0Decimals, poolInfo.token1Decimals
            );
        } else if (poolType == ArbUtils.PoolType.V2 || poolType == ArbUtils.PoolType.PANCAKESWAP_V2) {
            IUniswapV2Pair v2Pool = IUniswapV2Pair(poolAddr);
            (uint112 r0, uint112 r1,) = v2Pool.getReserves();
            if (r0 == 0 || r1 == 0) {
                return (0, 0, false);
            }

            if (!((poolInfo.token0 == tokenA && poolInfo.token1 == tokenB)
                        || (poolInfo.token1 == tokenA && poolInfo.token0 == tokenB))) {
                return (0, 0, false);
            }
            bool tokenAIsToken0 = poolInfo.token0 == tokenA;

            rawPriceScaled = getV2RawPriceScaled(
                v2Pool,
                tokenA,
                tokenB,
                r0,
                r1,
                poolInfo.token0,
                poolInfo.token1,
                tokenAIsToken0 ? poolInfo.token0Decimals : poolInfo.token1Decimals,
                tokenAIsToken0 ? poolInfo.token1Decimals : poolInfo.token0Decimals
            );
        } else {
            return (0, 0, false);
        }

        if (rawPriceScaled == 0) {
            return (0, 0, false);
        }

        if (poolType == ArbUtils.PoolType.V3 || poolType == ArbUtils.PoolType.PANCAKESWAP_V3) {
            effBuyPrice = getEffectiveBuyPrice(rawPriceScaled, poolFee);
            effSellPrice = getEffectiveSellPrice(rawPriceScaled, poolFee);
        } else {
            // V2 pools
            effBuyPrice = getV2EffectiveBuyPrice(rawPriceScaled, poolFee);
            effSellPrice = getV2EffectiveSellPrice(rawPriceScaled, poolFee);
        }

        return (effBuyPrice, effSellPrice, true);
    }

    // --- Constants --- (Moved from ArbUtils)
    /// @dev 0.0001 % granularity – keeps price hashes compact (uint128)
    uint256 public constant PRICE_GRANULARITY = 1e10;

    // --- Quote Helpers --- (Moved from ArbUtils & made public)
    /**
     * @notice Compresses a 256-bit price into uint128 using PRICE_GRANULARITY.
     * @param price The full 256-bit price.
     * @return qPrice The quantized 128-bit price.
     */
    function quantise(uint256 price) public pure returns (uint128 qPrice) {
        return uint128(price / PRICE_GRANULARITY);
    }

    /**
     * @notice Generates a quote-normalised cache key.
     * @dev Ensures the key is identical for (A,B) and (B,A) pairs.
     * @param tokenA Address of the first token.
     * @param tokenB Address of the second token.
     * @param qBuy Quantized buy price.
     * @param qSell Quantized sell price.
     * @return key The keccak256 hash representing the quote key.
     */
    function quoteKey(address tokenA, address tokenB, uint128 qBuy, uint128 qSell) public pure returns (bytes32 key) {
        return tokenA < tokenB
            ? keccak256(abi.encodePacked(tokenA, tokenB, qBuy, qSell))
            : keccak256(abi.encodePacked(tokenB, tokenA, qBuy, qSell));
    }

    // Snapshot fields reused across sizing/simulation in one iteration.
    struct PoolStatesForIteration {
        uint160 sqrtPrice;
        int24 tick;
        uint128 liquidity;
        address token0;
    }

    struct V3PoolSnapshot {
        uint160 sqrtPrice;
        uint128 liquidity;
        address token0;
        address token1;
        uint24 fee;
        bool success;
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
        uint24 feeA; // Pool-A fee validated against the live pool state
        uint24 feeB; // Pool-B fee used in simulation
        uint256 calculatedSellImpactBps; // Estimated impact on pool A for coarse chunk
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

    function _boundedTickMove(int24 tick, int24 move, bool zeroForOne) private pure returns (int24) {
        int256 target = int256(tick);
        if (zeroForOne) target -= int256(move);
        else target += int256(move);
        if (target < int256(TickMath.MIN_TICK)) return TickMath.MIN_TICK;
        if (target > int256(TickMath.MAX_TICK)) return TickMath.MAX_TICK;
        return int24(target);
    }

    function _readV3PoolSnapshot(address pool, ArbUtils.PoolType poolType)
        private
        view
        returns (V3PoolSnapshot memory snapshot)
    {
        if (poolType == ArbUtils.PoolType.V3) {
            try IUniswapV3Pool(pool).slot0() returns (
                uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool
            ) {
                snapshot.sqrtPrice = sqrtPriceX96;
            } catch {
                return snapshot;
            }
            try IUniswapV3Pool(pool).liquidity() returns (uint128 liquidity) {
                snapshot.liquidity = liquidity;
            } catch {
                return snapshot;
            }
            try IUniswapV3Pool(pool).token0() returns (address token0) {
                snapshot.token0 = token0;
            } catch {
                return snapshot;
            }
            try IUniswapV3Pool(pool).token1() returns (address token1) {
                snapshot.token1 = token1;
            } catch {
                return snapshot;
            }
            try IUniswapV3Pool(pool).fee() returns (uint24 fee) {
                snapshot.fee = fee;
            } catch {
                return snapshot;
            }
        } else if (poolType == ArbUtils.PoolType.PANCAKESWAP_V3) {
            try IPancakeV3Pool(pool).slot0() returns (
                uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint32, bool
            ) {
                snapshot.sqrtPrice = sqrtPriceX96;
            } catch {
                return snapshot;
            }
            try IPancakeV3Pool(pool).liquidity() returns (uint128 liquidity) {
                snapshot.liquidity = liquidity;
            } catch {
                return snapshot;
            }
            try IPancakeV3Pool(pool).token0() returns (address token0) {
                snapshot.token0 = token0;
            } catch {
                return snapshot;
            }
            try IPancakeV3Pool(pool).token1() returns (address token1) {
                snapshot.token1 = token1;
            } catch {
                return snapshot;
            }
            try IPancakeV3Pool(pool).fee() returns (uint24 fee) {
                snapshot.fee = fee;
            } catch {
                return snapshot;
            }
        } else {
            return snapshot;
        }

        if (
            snapshot.sqrtPrice == 0 || snapshot.liquidity == 0 || snapshot.token0 == address(0)
                || snapshot.token1 == address(0) || snapshot.fee >= 1_000_000
        ) {
            return V3PoolSnapshot({
                sqrtPrice: 0, liquidity: 0, token0: address(0), token1: address(0), fee: 0, success: false
            });
        }
        snapshot.success = true;
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
        uint24 feeA,
        uint24 feeB // pool B fee
    ) public pure returns (uint256 bestChunk, int256 bestPL) {
        if (hi == 0 || hi < lo || poolB_maxIn == 0 || feeA >= 1_000_000 || feeB >= 1_000_000) return (0, 0);

        bestPL = -type(int256).max;
        bestChunk = 0;

        for (uint8 iter; iter < 16 && lo <= hi; ++iter) {
            // Bounded binary search keeps execution predictable inside hook callbacks.
            // 16 rounds is enough once `hi` is already a narrow, liquidity-derived bound.
            uint256 mid = (lo + hi) >> 1; // mid = (lo+hi)/2

            // Approximate scaling in the local execution window.
            // This is intentionally heuristic; exact tick-by-tick simulation is too costly here.
            uint256 intermOut_mid = FullMath.mulDiv(intermOut_full, mid, hi);
            uint256 intermInB_mid = intermOut_mid > intermCapB ? intermCapB : intermOut_mid;
            if (intermInB_mid == 0) {
                if (mid > 0) {
                    hi = mid - 1;
                } else {
                    break;
                }
                continue;
            }

            uint256 startOut_mid = FullMath.mulDiv(poolB_maxStartOut, intermInB_mid, poolB_maxIn);
            int256 plMid = ArbMath._simulatedPL(mid, intermOut_mid, intermCapB, feeB, intermInB_mid, startOut_mid);

            if (plMid > bestPL) {
                // strictly better profit?
                bestPL = plMid;
                bestChunk = mid;
            }

            // classic binary-search – keep searching toward the profitable side
            if (plMid > 0) {
                lo = mid + 1;
            } else {
                if (mid == 0) break;
                hi = mid - 1;
            }
        }

        if (bestPL <= 0) bestChunk = 0; // nothing profitable after search
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
            try pA.slot0() returns (uint160 spA, int24 tA, uint16, uint16, uint16, uint8, bool) {
                params.poolAState.sqrtPrice = spA;
                params.poolAState.tick = tA;
            } catch {
                revert ArbErrors.IIAELoopSlot0FailedPoolA();
            }
        } else {
            // PANCAKESWAP_V3
            try IPancakeV3Pool(poolA_address).slot0() returns (
                uint160 spA, int24 tA, uint16, uint16, uint16, uint32, bool
            ) {
                params.poolAState.sqrtPrice = spA;
                params.poolAState.tick = tA;
            } catch {
                revert ArbErrors.IIAELoopSlot0FailedPoolA();
            }
        }

        if (poolBType == ArbUtils.PoolType.V3) {
            try pB.slot0() returns (uint160 spB, int24 tB, uint16, uint16, uint16, uint8, bool) {
                params.poolBState.sqrtPrice = spB;
                params.poolBState.tick = tB;
            } catch {
                revert ArbErrors.IIAELoopSlot0FailedPoolB();
            }
        } else {
            // PANCAKESWAP_V3
            try IPancakeV3Pool(poolB_address).slot0() returns (
                uint160 spB, int24 tB, uint16, uint16, uint16, uint32, bool
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
            currentSignedSpread = params.poolAState.tick - params.poolBState.tick;
        } else {
            currentSignedSpread = params.poolBState.tick - params.poolAState.tick;
        }
        int24 currentAbsSpread = currentSignedSpread >= 0 ? currentSignedSpread : -currentSignedSpread;

        if (
            currentAbsSpread < int24(uint24(config.minSpreadBps)) || params.poolAState.liquidity == 0
                || params.poolBState.liquidity == 0
        ) {
            return params; // shouldContinue is false, stop here
        }

        // Convert spread into a target move window.
        // Larger remaining spread -> larger step; tighter spread -> smaller step.
        int24 move;
        uint256 curSpreadAbs = uint256(uint24(currentAbsSpread));
        uint256 initSpreadAbs = uint256(uint24(config.initialAbsSpread));
        if (initSpreadAbs == 0 || config.bpsDivisor == 0 || config.bpsDivisor > type(uint256).max / 2) {
            return params;
        }
        uint256 pctOfInitialSpread = (curSpreadAbs * 100) / initSpreadAbs;
        uint256 moveBpsAdaptive = uint256(config.chunkSpreadConsumptionBps) + (2_000 * pctOfInitialSpread) / 100;
        uint256 tmpMove = (curSpreadAbs * moveBpsAdaptive) / (2 * config.bpsDivisor);
        if (tmpMove >= uint256(uint24(TickMath.MAX_TICK))) {
            move = TickMath.MAX_TICK;
        } else {
            move = int24(int256(tmpMove));
        }
        if (move == 0) move = 1;

        // --- Price limits --------------------------------------------------------
        params.zeroForOneB = (IUniswapV3Pool(poolB_address).token0() == intermediateToken); // Fetch token0 for B here

        int24 targetTickA = _boundedTickMove(params.poolAState.tick, move, params.zeroForOneA);
        params.sqrtPriceLimitA = TickMath.getSqrtRatioAtTick(targetTickA);

        int24 targetTickB = _boundedTickMove(params.poolBState.tick, move, params.zeroForOneB);
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
        if (startInA == 0 || intermOutA == 0) return params;

        params.intermediateCapacityOfB = ArbMath._exactCapacity(
            address(pB), // Pass address instead of interface
            params.zeroForOneB,
            params.poolBState.sqrtPrice,
            params.sqrtPriceLimitB,
            params.poolBState.tick,
            params.poolBState.liquidity
        );

        uint256 chunkBalanced = startInA;
        if (intermOutA > params.intermediateCapacityOfB) {
            // Preserve the reference executor's small capacity margin while
            // keeping its intermediate arithmetic bounded. The swap price
            // limit remains authoritative if the second leg cannot use all
            // of the margin.
            if (params.intermediateCapacityOfB > type(uint256).max / 102 || intermOutA > type(uint256).max / 100) {
                return params;
            }
            chunkBalanced = FullMath.mulDiv(startInA, params.intermediateCapacityOfB * 102, intermOutA * 100);
        }

        // --- Apply Balance Cap ---
        uint256 currentChunkPreImpact = Math.min(chunkBalanced, config.currentStartTokenBalance);
        if (currentChunkPreImpact == 0) {
            return params; // shouldContinue is false
        }

        // Nearest-range utilization is diagnostic only: it is not price
        // impact, and a valid swap can cross an initialized tick.
        uint256 impactOnA_forChunkPreImpact = ArbMath._estImpactBps(
            poolA_address, startToken, currentChunkPreImpact, poolAType == ArbUtils.PoolType.PANCAKESWAP_V3
        );
        uint256 roughChunk = currentChunkPreImpact;
        params.calculatedSellImpactBps = impactOnA_forChunkPreImpact;

        if (roughChunk < config.minChunkForStartToken) {
            return params; // still false
        }

        // Binary-search refinement happens in findBestV3Chunk.

        try IUniswapV3Pool(poolA_address).fee() returns (uint24 fA) {
            params.feeA = fA;
        } catch {
            return params;
        }
        try IUniswapV3Pool(poolB_address).fee() returns (uint24 fB) {
            params.feeB = fB;
        } catch {
            return params;
        }
        if (params.feeA >= 1_000_000 || params.feeB >= 1_000_000) {
            return params;
        }

        params.chunkToSwap = roughChunk; // This is now the rough chunk upper bound
        params.shouldContinue = true; // success – calculation may proceed

        params.poolBState.token0 = IUniswapV3Pool(poolB_address).token0(); // Ensure it's stored

        return params;
    }

    // Part 2 of V3 sizing:
    // use coarse parameters from getV3SwapParameters and select the best executable chunk.
    function findBestV3Chunk(V3SwapParams memory params, uint256 minChunkForStartToken)
        public
        pure
        returns (uint256 bestChunk)
    {
        (uint256 poolB_maxIn, uint256 poolB_maxStartOut) = ArbMath._deltaAmounts(
            params.zeroForOneB, params.poolBState.sqrtPrice, params.sqrtPriceLimitB, params.poolBState.liquidity
        );

        (bestChunk,) = _binarySearchBestChunk(
            params.chunkToSwap, // This is the roughChunk (upper bound)
            minChunkForStartToken,
            params.intermediateAmountPotentiallyFromA,
            params.intermediateCapacityOfB,
            poolB_maxIn,
            poolB_maxStartOut,
            params.feeA,
            params.feeB
        );

        if (bestChunk == 0) {
            return 0;
        }
    }

    function estimateImpactBps(address pool, address tokenIn, uint256 amountIn) public view returns (uint256) {
        return ArbMath._estImpactBps(pool, tokenIn, amountIn, false);
    }

    /// @notice Estimates V3 price impact using the pool's actual slot0 ABI.
    /// @dev Pancake V3 uses a uint32 feeProtocol field where Uniswap V3 uses
    ///      uint8, so it must not be decoded through the Uniswap slot0 tuple.
    function estimateImpactBps(address pool, ArbUtils.PoolType poolType, address tokenIn, uint256 amountIn)
        public
        view
        returns (uint256)
    {
        if (poolType != ArbUtils.PoolType.V3 && poolType != ArbUtils.PoolType.PANCAKESWAP_V3) {
            return type(uint256).max;
        }
        return ArbMath._estImpactBps(pool, tokenIn, amountIn, poolType == ArbUtils.PoolType.PANCAKESWAP_V3);
    }

    // --- Uniswap V2 Price Calculation Functions ---

    /**
     * @notice Calculates the raw price of tokenA in terms of tokenB for a V2 pool, scaled to 1e18.
     * @param pair The IUniswapV2Pair contract instance.
     * @param tokenA Address of tokenA (the token whose price is being measured).
     * @param tokenB Address of tokenB (the token in which the price is expressed).
     * @return rawPriceScaled The price of tokenA in terms of tokenB, scaled by 1e18. Returns 0 if liquidity is 0.
     */
    function getV2RawPriceScaled(
        IUniswapV2Pair pair,
        address tokenA,
        address tokenB,
        uint112 reserve0,
        uint112 reserve1,
        address pairToken0,
        address pairToken1,
        uint8 decimalsA,
        uint8 decimalsB
    ) public pure returns (uint256 rawPriceScaled) {
        if (reserve0 == 0 || reserve1 == 0) {
            return 0; // No liquidity or one-sided liquidity, no valid price
        }

        uint256 rA;
        uint256 rB;

        if (tokenA == pairToken0) {
            // tokenA is token0, tokenB is token1
            if (tokenB != pairToken1) {
                revert ArbErrors.SwapInputTokenNotInPool();
            }
            rA = reserve0;
            rB = reserve1;
        } else {
            // tokenA is token1, tokenB is token0
            if (tokenA != pairToken1 || tokenB != pairToken0) {
                revert ArbErrors.SwapInputTokenNotInPool(); // Or a more specific V2 error
            }
            rA = reserve1;
            rB = reserve0;
        }

        if (rA == 0) return 0; // Avoid division by zero, though covered by initial reserve check

        uint256 oneTokenA = ArbMath._pow10(decimalsA);
        if (oneTokenA == 0) return 0;
        uint256 rawTokenB = ArbMath._mulDivOrZero(rB, oneTokenA, rA);
        return ArbMath._scaleRawAmountTo1e18(rawTokenB, decimalsB);
    }

    /**
     * @notice Calculates the effective V2 buy price for tokenA with tokenB, including fees.
     * @param rawV2PriceScaled The raw V2 price (tokenB per tokenA, 1e18).
     * @param v2FeePPM The V2 pool fee in parts per million (e.g., 3000 for 0.3%).
     * @return effectiveBuyPrice The fee-adjusted price for buying tokenA in a V2 pool.
     */
    function getV2EffectiveBuyPrice(uint256 rawV2PriceScaled, uint24 v2FeePPM)
        public
        pure
        returns (uint256 effectiveBuyPrice)
    {
        // To buy tokenA, you pay more of tokenB. Price B/A increases.
        // The amount of tokenB needed is rawV2PriceScaled / (1 - feeRate)
        // Example: Fee 0.3% (3000 PPM). Rate = 0.003. 1 - feeRate = 0.997
        // effectivePrice = rawPrice / 0.997 = rawPrice * 1000 / 997 (if fee is exactly 0.3%)
        // Using PPM: effectivePrice = rawPrice * 1_000_000 / (1_000_000 - v2FeePPM)
        return _effectiveBuyPrice(rawV2PriceScaled, v2FeePPM);
    }

    /// @dev A fee-adjusted buy quote must round up, but a pathological pool
    ///      price must not make the quoting path revert through FullMath.
    function _effectiveBuyPrice(uint256 rawPriceScaled, uint24 feePpm) private pure returns (uint256) {
        if (feePpm >= 1_000_000) return type(uint256).max;

        uint256 denominator = 1_000_000 - feePpm;
        uint256 largestRepresentableInput = FullMath.mulDiv(type(uint256).max, denominator, 1_000_000);
        if (
            rawPriceScaled > largestRepresentableInput
                || (rawPriceScaled == largestRepresentableInput && mulmod(rawPriceScaled, 1_000_000, denominator) != 0)
        ) return type(uint256).max;

        return FullMath.mulDivRoundingUp(rawPriceScaled, 1_000_000, denominator);
    }

    /**
     * @notice Calculates the effective V2 sell price for tokenA for tokenB, including fees.
     * @param rawV2PriceScaled The raw V2 price (tokenB per tokenA, 1e18).
     * @param v2FeePPM The V2 pool fee in parts per million (e.g., 3000 for 0.3%).
     * @return effectiveSellPrice The fee-adjusted price for selling tokenA in a V2 pool.
     */
    function getV2EffectiveSellPrice(uint256 rawV2PriceScaled, uint24 v2FeePPM)
        public
        pure
        returns (uint256 effectiveSellPrice)
    {
        // To sell tokenA, you receive less of tokenB. Price B/A decreases.
        // The amount of tokenB received is rawV2PriceScaled * (1 - feeRate)
        // Example: Fee 0.3%. Rate = 0.003. 1 - feeRate = 0.997
        // effectivePrice = rawPrice * 0.997 = rawPrice * 997 / 1000 (if fee is exactly 0.3%)
        // Using PPM: effectivePrice = rawPrice * (1_000_000 - v2FeePPM) / 1_000_000
        if (v2FeePPM >= 1_000_000) return 0;
        return FullMath.mulDiv(rawV2PriceScaled, 1_000_000 - v2FeePPM, 1_000_000);
    }

    // --- NEW V2-V2 Arbitrage Calculation Logic ---

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
            !((poolA.token0() == startToken && poolA.token1() == intermediateToken)
                    || (poolA.token1() == startToken && poolA.token0() == intermediateToken))
                || !((poolB.token0() == intermediateToken && poolB.token1() == startToken)
                    || (poolB.token1() == intermediateToken && poolB.token0() == startToken))
        ) {
            // This basic check might not be sufficient if token order within pair matters for general logic
            return params;
        }

        (uint112 reserveA_start, uint112 reserveA_interm,) =
            _getV2ReservesForTokens(poolA, startToken, intermediateToken);
        (uint112 reserveB_interm, uint112 reserveB_start,) =
            _getV2ReservesForTokens(poolB, intermediateToken, startToken);

        if (reserveA_start == 0 || reserveA_interm == 0 || reserveB_interm == 0 || reserveB_start == 0) {
            return params; // Not enough liquidity in one of the pools
        }

        // Heuristic probe ladder.
        // Exact optimal V2-V2 size is possible off-chain but expensive on-chain,
        // so we probe representative sizes and pick the best simulated outcome.
        // The largest probe (50% balance) is intentional: slippage usually makes
        // oversizing fail fast, and smaller candidates are then cheap to test.
        uint256[] memory testChunkSizes = new uint256[](4);
        testChunkSizes[0] = minChunkStartToken;
        if (testChunkSizes[0] == 0 && startTokenBalance > 0) {
            testChunkSizes[0] = 1; // Min 1 wei
        }

        testChunkSizes[1] = startTokenBalance / 100; // 1% of balance
        testChunkSizes[2] = startTokenBalance / 10; // 10% of balance
        testChunkSizes[3] = startTokenBalance / 2; // 50% of balance

        int256 bestSimulatedProfit = -type(int256).max; // Initialize with very small number
        uint256 bestChunk = 0;

        for (uint256 i = 0; i < testChunkSizes.length; i++) {
            uint256 currentTestChunk = testChunkSizes[i];
            if (currentTestChunk == 0) continue;
            if (currentTestChunk < minChunkStartToken && minChunkStartToken > 0) {
                currentTestChunk = minChunkStartToken; // Ensure at least minChunk if possible
            }
            if (currentTestChunk > startTokenBalance) {
                currentTestChunk = startTokenBalance;
            }
            if (currentTestChunk == 0) continue;

            // Skip duplicate probes when balance is small and ratios collapse to same value.
            if (i > 0 && currentTestChunk == testChunkSizes[i - 1] && currentTestChunk != minChunkStartToken) continue;
            if (i > 0 && currentTestChunk == bestChunk) continue; // Already found as best or tested

            int256 simulatedProfit = simulateV2V2Profit(
                currentTestChunk,
                poolA,
                poolB,
                startToken,
                intermediateToken,
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
        } else {
            // Fallback: if no heuristic chunk was profitable, explicitly check minChunk one last time IF it wasn't bestChunk.
            // This path is less likely if minChunk was already in testChunkSizes[0] and resulted in profit <=0.
            if (minChunkStartToken > 0 && minChunkStartToken <= startTokenBalance && minChunkStartToken != bestChunk) {
                int256 minChunkProfit = simulateV2V2Profit(
                    minChunkStartToken,
                    poolA,
                    poolB,
                    startToken,
                    intermediateToken,
                    reserveA_start,
                    reserveA_interm,
                    reserveB_interm,
                    reserveB_start,
                    poolAFeePPM,
                    poolBFeePPM
                );
                if (minChunkProfit > 0) {
                    params.opportunityExists = true;
                    params.estimatedChunkToSwap = minChunkStartToken;
                    params.expectedProfitFromChunk = minChunkProfit;
                }
            }
        }

        // Final cap and minChunk check if opportunity was found by heuristics
        if (params.opportunityExists) {
            if (params.estimatedChunkToSwap > startTokenBalance) {
                params.estimatedChunkToSwap = startTokenBalance;
                // Re-simulate profit if chunk was capped
                params.expectedProfitFromChunk = simulateV2V2Profit(
                    params.estimatedChunkToSwap,
                    poolA,
                    poolB,
                    startToken,
                    intermediateToken,
                    reserveA_start,
                    reserveA_interm,
                    reserveB_interm,
                    reserveB_start,
                    poolAFeePPM,
                    poolBFeePPM
                );
                if (params.expectedProfitFromChunk <= 0) {
                    params.opportunityExists = false;
                }
            }
            // Ensure it's not below minChunk if it was profitable, unless it IS minChunk
            if (
                params.estimatedChunkToSwap < minChunkStartToken && params.estimatedChunkToSwap > 0
                    && params.opportunityExists
            ) {
                if (minChunkStartToken > params.estimatedChunkToSwap) {
                    // This case implies that a chunk smaller than minChunk was found profitable somehow, then opportunity should be false.
                    // Or, if it was capped to be less than minChunk. Generally, don't proceed if less than minChunk.
                    params.opportunityExists = false;
                }
            }
        }

        return params;
    }

    /**
     * @notice Simulates the profit/loss from a V2-V2 arbitrage trade for a given chunk.
     * @param chunkToSwapStartToken Amount of startToken to swap in the first pool.
     * @param poolA The first V2 pair (startToken -> intermediateToken).
     * @param poolB The second V2 pair (intermediateToken -> startToken).
     * @param startToken Address of the start token.
     * @param intermediateToken Address of the intermediate token.
     * @param rA_start Reserve of startToken in Pool A.
     * @param rA_interm Reserve of intermediateToken in Pool A.
     * @param rB_interm Reserve of intermediateToken in Pool B.
     * @param rB_start Reserve of startToken in Pool B.
     * @return profitInStartToken The net profit or loss in startToken units.
     */
    function simulateV2V2Profit(
        uint256 chunkToSwapStartToken,
        IUniswapV2Pair poolA,
        IUniswapV2Pair poolB,
        address startToken,
        address intermediateToken,
        uint112 rA_start,
        uint112 rA_interm,
        uint112 rB_interm,
        uint112 rB_start,
        uint24 poolAFeePPM,
        uint24 poolBFeePPM
    ) public pure returns (int256 profitInStartToken) {
        if (chunkToSwapStartToken == 0) return 0;
        if (chunkToSwapStartToken > uint256(type(int256).max)) {
            return -type(int256).max;
        }

        // console.log("simulateV2V2Profit");

        // Trade 1 (Pool A): startToken -> intermediateToken
        uint256 intermediateAmountOut = getAmountOut(chunkToSwapStartToken, rA_start, rA_interm, poolAFeePPM);

        // console.log("intermediateAmountOut", intermediateAmountOut);

        if (intermediateAmountOut == 0) {
            return -int256(chunkToSwapStartToken); // Full loss if no intermediate token received
        }

        // console.log("chunkToSwapStartToken", chunkToSwapStartToken);
        // console.log("poolA", address(poolA));
        // console.log("poolB", address(poolB));
        // console.log("startToken", startToken);
        // console.log("intermediateToken", intermediateToken);
        // console.log("rA_start", rA_start);

        // Trade 2 (Pool B): intermediateToken -> startToken
        uint256 startTokenReceivedBack = getAmountOut(intermediateAmountOut, rB_interm, rB_start, poolBFeePPM);

        // console.log("startTokenReceivedBack", startTokenReceivedBack);

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
    function _getV2ReservesForTokens(IUniswapV2Pair pair, address token0Addr, address token1Addr)
        public
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 lastBlockTimestamp)
    {
        (uint112 r0, uint112 r1, uint32 ts) = pair.getReserves();
        address pairToken0 = pair.token0();

        if (token0Addr == pairToken0) {
            // token0Addr is pair.token0, token1Addr must be pair.token1
            if (token1Addr != pair.token1()) {
                revert("Token mismatch in _getV2ReservesForTokens");
            }
            return (r0, r1, ts);
        } else {
            // token0Addr is pair.token1, token1Addr must be pair.token0
            if (token0Addr != pair.token1() || token1Addr != pairToken0) {
                revert("Token mismatch in _getV2ReservesForTokens");
            }
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
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        return getAmountOut(amountIn, reserveIn, reserveOut, 3000);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint24 feePPM)
        public
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;
        if (reserveIn == 0 || reserveOut == 0) return 0;
        if (feePPM >= 1_000_000) return 0;

        uint256 amountInWithFee = FullMath.mulDiv(amountIn, 1_000_000 - feePPM, 1_000_000);
        if (amountInWithFee > type(uint256).max - reserveIn) return 0;
        uint256 denominator = reserveIn + amountInWithFee;
        return FullMath.mulDiv(amountInWithFee, reserveOut, denominator);
    }

    /// @dev Calculates the required input amount for a given output amount for a V2 swap.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountIn)
    {
        return getAmountIn(amountOut, reserveIn, reserveOut, 3000);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint24 feePPM)
        public
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) return 0;
        if (reserveIn == 0 || reserveOut == 0) return type(uint256).max;
        if (amountOut >= reserveOut) return type(uint256).max; // Not enough liquidity
        if (feePPM >= 1_000_000) return type(uint256).max;
        uint256 numerator = reserveIn * amountOut * 1_000_000;
        uint256 denominator = (reserveOut - amountOut) * (1_000_000 - feePPM);
        amountIn = (numerator / denominator) + 1;
        return amountIn;
    }

    // Legacy V3-only entrypoint. Pancake callers must use the PoolType-aware overload.
    function calculateV3SqrtPriceLimitForAmountIn(
        IUniswapV3Pool pool,
        address tokenIn,
        uint256 amountIn,
        uint16 slippageBps
    ) public view returns (uint160 sqrtPriceLimitX96) {
        return _calculateV3SqrtPriceLimitForAmountIn(
            address(pool), ArbUtils.PoolType.V3, tokenIn, amountIn, slippageBps
        );
    }

    /// @notice Calculates a bounded V3-style price limit using the pool's ABI.
    function calculateV3SqrtPriceLimitForAmountIn(
        address pool,
        ArbUtils.PoolType poolType,
        address tokenIn,
        uint256 amountIn,
        uint16 slippageBps
    ) public view returns (uint160 sqrtPriceLimitX96) {
        return _calculateV3SqrtPriceLimitForAmountIn(pool, poolType, tokenIn, amountIn, slippageBps);
    }

    function _calculateV3SqrtPriceLimitForAmountIn(
        address pool,
        ArbUtils.PoolType poolType,
        address tokenIn,
        uint256 amountIn,
        uint16 slippageBps
    ) private view returns (uint160 sqrtPriceLimitX96) {
        if (amountIn == 0 || amountIn > uint256(type(int256).max) || slippageBps > 10_000) {
            return 0;
        }

        V3PoolSnapshot memory snapshot = _readV3PoolSnapshot(pool, poolType);
        if (!snapshot.success) return 0;

        if (tokenIn != snapshot.token0 && tokenIn != snapshot.token1) return 0;
        bool zeroForOne = tokenIn == snapshot.token0;
        int256 amountRemaining = int256(amountIn);
        uint160 sqrtP = snapshot.sqrtPrice;
        for (uint8 step; step < 5 && amountRemaining > 0; ++step) {
            (uint160 sqrtQ, uint256 stepAmountIn,,) = SwapMath.computeSwapStep(
                sqrtP,
                zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
                snapshot.liquidity,
                amountRemaining,
                snapshot.fee
            );
            sqrtP = sqrtQ;
            if (stepAmountIn == 0) break;
            if (stepAmountIn > uint256(amountRemaining)) return 0;
            amountRemaining -= int256(stepAmountIn);
        }

        uint256 slippageFactor = zeroForOne ? 10_000 - slippageBps : 10_000 + slippageBps;
        uint256 calculatedLimit = FullMath.mulDiv(sqrtP, slippageFactor, 10_000);
        if (zeroForOne) {
            if (calculatedLimit < TickMath.MIN_SQRT_RATIO + 1) {
                return TickMath.MIN_SQRT_RATIO + 1;
            }
        } else if (calculatedLimit > TickMath.MAX_SQRT_RATIO - 1) {
            return TickMath.MAX_SQRT_RATIO - 1;
        }
        if (calculatedLimit > type(uint160).max) return 0;
        return uint160(calculatedLimit);
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
    ) public view returns (int256 profitInStartToken) {
        return _simulateV2V3Profit(
            chunkToSwapStartToken,
            poolA,
            address(poolB),
            ArbUtils.PoolType.V3,
            startToken,
            intermediateToken,
            poolAFeePPM
        );
    }

    function _simulateV2V3Profit(
        uint256 chunkToSwapStartToken,
        IUniswapV2Pair poolA,
        address poolB,
        ArbUtils.PoolType poolBType,
        address startToken,
        address intermediateToken,
        uint24 poolAFeePPM
    ) private view returns (int256 profitInStartToken) {
        if (chunkToSwapStartToken == 0) return 0;
        if (chunkToSwapStartToken > uint256(type(int256).max)) {
            return -type(int256).max;
        }

        (uint112 rA_start, uint112 rA_interm,) = _getV2ReservesForTokens(poolA, startToken, intermediateToken);
        if (rA_start == 0 || rA_interm == 0) {
            return -int256(chunkToSwapStartToken);
        }

        uint256 intermediateAmountOut = getAmountOut(chunkToSwapStartToken, rA_start, rA_interm, poolAFeePPM);
        if (intermediateAmountOut == 0) return -int256(chunkToSwapStartToken);

        V3PoolSnapshot memory snapshot = _readV3PoolSnapshot(poolB, poolBType);
        if (
            !snapshot.success || intermediateToken != snapshot.token0 && intermediateToken != snapshot.token1
                || intermediateAmountOut > uint256(type(int256).max)
        ) return -int256(chunkToSwapStartToken);
        bool zeroForOne = intermediateToken == snapshot.token0;

        (,, uint256 startTokenReceivedBack,) = SwapMath.computeSwapStep(
            snapshot.sqrtPrice,
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            snapshot.liquidity,
            int256(intermediateAmountOut),
            snapshot.fee
        );

        if (startTokenReceivedBack > chunkToSwapStartToken) {
            uint256 gain = startTokenReceivedBack - chunkToSwapStartToken;
            return gain > uint256(type(int256).max) ? int256(0) : int256(gain);
        }
        uint256 loss = chunkToSwapStartToken - startTokenReceivedBack;
        return loss > uint256(type(int256).max) ? -type(int256).max : -int256(loss);
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
    ) public view returns (int256 profitInStartToken) {
        return _simulateV3V2Profit(
            chunkToSwapStartToken,
            address(poolA),
            ArbUtils.PoolType.V3,
            poolB,
            startToken,
            intermediateToken,
            poolBFeePPM
        );
    }

    function _simulateV3V2Profit(
        uint256 chunkToSwapStartToken,
        address poolA,
        ArbUtils.PoolType poolAType,
        IUniswapV2Pair poolB,
        address startToken,
        address intermediateToken,
        uint24 poolBFeePPM
    ) private view returns (int256 profitInStartToken) {
        if (chunkToSwapStartToken == 0) return 0;
        if (chunkToSwapStartToken > uint256(type(int256).max)) {
            return -type(int256).max;
        }

        V3PoolSnapshot memory snapshot = _readV3PoolSnapshot(poolA, poolAType);
        if (!snapshot.success || startToken != snapshot.token0 && startToken != snapshot.token1) {
            return -int256(chunkToSwapStartToken);
        }
        bool zeroForOne = startToken == snapshot.token0;

        (,, uint256 intermediateAmountOut,) = SwapMath.computeSwapStep(
            snapshot.sqrtPrice,
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            snapshot.liquidity,
            int256(chunkToSwapStartToken),
            snapshot.fee
        );

        if (intermediateAmountOut == 0) return -int256(chunkToSwapStartToken);

        (uint112 rB_interm, uint112 rB_start,) = _getV2ReservesForTokens(poolB, intermediateToken, startToken);
        if (rB_start == 0 || rB_interm == 0) {
            return -int256(chunkToSwapStartToken);
        }

        uint256 startTokenReceivedBack = getAmountOut(intermediateAmountOut, rB_interm, rB_start, poolBFeePPM);

        if (startTokenReceivedBack > chunkToSwapStartToken) {
            uint256 gain = startTokenReceivedBack - chunkToSwapStartToken;
            profitInStartToken = gain > uint256(type(int256).max) ? int256(0) : int256(gain);
        } else {
            uint256 loss = chunkToSwapStartToken - startTokenReceivedBack;
            profitInStartToken = loss > uint256(type(int256).max) ? -type(int256).max : -int256(loss);
        }
        return profitInStartToken;
    }

    function deltaAmounts(
        bool zeroForOne,
        uint160 sqrtP0, // Current price
        uint160 sqrtP1, // Target price
        uint128 L
    )
        public
        pure
        returns (uint256 inAmt, uint256 outAmt)
    {
        return ArbMath._deltaAmounts(zeroForOne, sqrtP0, sqrtP1, L);
    }

    function simulatedPL(
        uint256 startInA, // token-A sent to pool A   (raw units)
        uint256 intermOutA, // token-B received from A  (raw units)
        uint256 intermCapB, // clamp you applied
        uint24 feeB,
        uint256 intermInB, // token-B you *would* push into B at limit
        uint256 startOutB // token-A you *would* get back at limit
    ) public pure returns (int256) {
        return ArbMath._simulatedPL(startInA, intermOutA, intermCapB, feeB, intermInB, startOutB);
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
    ) public view returns (uint256 bestChunk) {
        // Mixed-path sizing uses monotonic backoff.
        // Start from a large probe and halve until a profitable/safe chunk is found.
        // This minimizes quote simulations while still quickly adapting to impact.
        uint8 halvings = 0;
        uint256 testChunk = initialTestChunk;

        while (true) {
            int256 simulatedProfit;
            if (poolAType == ArbUtils.PoolType.V2 || poolAType == ArbUtils.PoolType.PANCAKESWAP_V2) {
                // V2 -> V3 path
                simulatedProfit = _simulateV2V3Profit(
                    testChunk,
                    IUniswapV2Pair(poolA_addr),
                    poolB_addr,
                    poolBType,
                    startToken,
                    intermediateToken,
                    poolAType == ArbUtils.PoolType.PANCAKESWAP_V2 ? 2500 : 3000
                );
            } else {
                // V3 -> V2 path
                simulatedProfit = _simulateV3V2Profit(
                    testChunk,
                    poolA_addr,
                    poolAType,
                    IUniswapV2Pair(poolB_addr),
                    startToken,
                    intermediateToken,
                    poolBType == ArbUtils.PoolType.PANCAKESWAP_V2 ? 2500 : 3000
                );
            }

            if (simulatedProfit > 0 && cumulativeProfit + simulatedProfit >= minCumulativeProfit) {
                bestChunk = testChunk;
                break; // Found the first profitable chunk, exit.
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
