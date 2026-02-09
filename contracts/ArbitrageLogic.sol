// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./lib/ArbMath.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol"; // For pool interactions
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
        // console.log("_calculatePrice1e18_corrected");
        // console.log("sqrtP_uint160:", sqrtP_uint160);
        // console.log("aIsT0:", aIsT0);
        // console.log("dec0_uint8:", dec0_uint8);
        // console.log("dec1_uint8:", dec1_uint8);

        uint256 sqrtP = uint256(sqrtP_uint160);
        uint256 dec0 = uint256(dec0_uint8); // Cast to uint256 for 10**dec0
        uint256 dec1 = uint256(dec1_uint8); // Cast to uint256 for 10**dec1
        // console.log("dec0:", dec0);
        // console.log("dec1:", dec1);

        uint256 num;
        uint256 den;

        uint256 Q192 = uint256(1) << 192;
        uint256 tenPowDec0 = 10 ** dec0;
        uint256 tenPowDec1 = 10 ** dec1;

        uint256 sqrtPSquared = FullMath.mulDiv(sqrtP, sqrtP, 1);

        // console.log("Q192:", Q192);
        // console.log("tenPowDec0:", tenPowDec0);
        // console.log("tenPowDec1:", tenPowDec1);
        // console.log("sqrtPSquared:", sqrtPSquared);
        // console.log("isT0:", aIsT0);

        if (aIsT0) {
            // Price of tokenA (token0) in terms of tokenB (token1)
            // Formula: (sqrtP^2 / Q192) * (10^dec1 / 10^dec0) effectively, then scaled by 1e18
            // Numerator term: sqrtP^2 * 10^dec1
            // Denominator term: Q192 * 10^dec0
            num = FullMath.mulDiv(sqrtPSquared, tenPowDec1, 1); // sqrtP^2 * 10^dec1
            den = FullMath.mulDiv(Q192, tenPowDec0, 1); // Q192 * 10^dec0
        } else {
            // Price of tokenA (token1) in terms of tokenB (token0)
            // Formula: (Q192 / sqrtP^2) * (10^dec0 / 10^dec1) effectively, then scaled by 1e18
            // Numerator term: Q192 * 10^dec0
            // Denominator term: sqrtP^2 * 10^dec1
            num = FullMath.mulDiv(Q192, tenPowDec0, 1); // Q192 * 10^dec0
            den = FullMath.mulDiv(sqrtPSquared, tenPowDec1, 1); // sqrtP^2 * 10^dec1
        }

        // console.log("num:", num);
        // console.log("den:", den);
        if (den == 0) return 0; // Should not happen with Uniswap V3 properties
        price1e18 = FullMath.mulDiv(num, 1e18, den);
        // console.log("price1e18:", price1e18);
        return price1e18;
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
    ) public pure returns (uint256 rawPriceScaled) {
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
    ) public pure returns (uint256 effectiveBuyPrice) {
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
    ) public pure returns (uint256 effectiveSellPrice) {
        // sell-leg receives less -> price decreases
        return
            FullMath.mulDiv(
                rawPriceScaled,
                1_000_000 - poolFee, // -fee (ppm)
                1_000_000
            );
    }

    /**
     * @notice Checks if a pool is too thin for arbitrage (a "dust pool").
     * @dev A pool is considered dust if moving its price by one tick spacing requires less than `minChunkIn` of the input token.
     * @param sqrtPriceX96 Current sqrt price of the pool.
     * @param tick Current tick of the pool.
     * @param liquidity Current liquidity of the pool.
     * @param tickSpacing The tick spacing of the pool.
     * @param zeroForOne True if swapping token0 for token1, false otherwise.
     * @param minChunkIn The minimum amount of input token considered significant for an arbitrage chunk.
     * @return isDust True if the pool is considered a dust pool, false otherwise.
     */
    function isPoolDust(
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity,
        int24 tickSpacing,
        bool zeroForOne,
        uint256 minChunkIn
    ) public pure returns (bool isDust) {
        if (liquidity == 0) return true; // Definitely dust if no liquidity

        int24 nextTick = zeroForOne ? tick - tickSpacing : tick + tickSpacing;
        if (nextTick < TickMath.MIN_TICK) nextTick = TickMath.MIN_TICK;
        if (nextTick > TickMath.MAX_TICK) nextTick = TickMath.MAX_TICK;

        uint160 sqrtPriceNextTick = TickMath.getSqrtRatioAtTick(nextTick);
        (uint256 probeIn, ) = ArbMath._deltaAmounts(
            zeroForOne,
            sqrtPriceX96,
            sqrtPriceNextTick,
            liquidity
        );

        return probeIn < minChunkIn;
    }

    function findBestPoolsLogic(
        address tokenA,
        address tokenB,
        address skipBuyPool,
        address skipSellPool,
        ArbUtils.PoolInfo[] memory poolsForTokenA,
        uint256 minChunkIn,
        uint16 minSpreadBpsRequired
    )
        public
        view
        returns (
            address bestBuyPool,
            address bestSellPool,
            uint256 bestBuyPrice,
            uint256 bestSellPrice,
            ArbUtils.PoolType bestBuyPoolType,
            ArbUtils.PoolType bestSellPoolType
        )
    {
        // Given a base-token pool list, select the best executable buy/sell quote pair.
        // Caller controls `skip*Pool` to force exploration of alternates after a failure.
        uint256 poolCount = poolsForTokenA.length;
        bestBuyPrice = type(uint256).max;
        bestSellPrice = 0;
        bestBuyPoolType = ArbUtils.PoolType.V3;
        bestSellPoolType = ArbUtils.PoolType.V3;

        // console.log("--- Finding Best Pools ---");
        for (uint256 i = 0; i < poolCount; ++i) {
            // console.log("poolCount:", poolCount, " i:", i);
            ArbUtils.PoolInfo memory currentPoolInfo = poolsForTokenA[i];
            address currentPoolAddr = currentPoolInfo.poolAddress;
            ArbUtils.PoolType currentPoolType = currentPoolInfo.poolType;
            uint24 currentPoolFee = currentPoolInfo.fee; // This will be V3 fee or V2_POOL_FEE_PPM

            if (currentPoolAddr == address(0)) continue;

            // Basic skip logic (applies to both V2 and V3)
            if (
                currentPoolAddr == skipBuyPool ||
                currentPoolAddr == skipSellPool
            ) {
                // console.log("Skipping pool:", currentPoolAddr);
                // console.log(
                // "skipBuy:",
                // skipBuyPool,
                // " skipSell:",
                // skipSellPool
                // );
                continue;
            }

            uint256 rawPriceScaled;
            uint256 effBuyPrice;
            uint256 effSellPrice;
            // console.log("currentPoolType:", uint256(currentPoolType));
            // console.log("currentPoolAddr:", currentPoolAddr);
            // console.log("currentPoolFee:", currentPoolFee);
            if (
                currentPoolType == ArbUtils.PoolType.V3 ||
                currentPoolType == ArbUtils.PoolType.PANCAKESWAP_V3
            ) {
                // console.log("I think pool is V3");
                IUniswapV3Pool currentV3Pool = IUniswapV3Pool(currentPoolAddr);

                /* ---------- 1.  very cheap checks first ---------- */
                address poolToken0 = currentPoolInfo.token0;
                address poolToken1 = currentPoolInfo.token1;

                bool isWantedPair = (poolToken0 == tokenA &&
                    poolToken1 == tokenB) ||
                    (poolToken0 == tokenB && poolToken1 == tokenA);
                if (!isWantedPair) continue; // skip unrelated pool

                /* ---------- 2.  pay the costly liquidity() read only now ---------- */
                uint128 L;
                try currentV3Pool.liquidity() returns (uint128 l) {
                    L = l;
                } catch {
                    continue; // cannot price pool without liquidity
                }

                // console.log("L:", L);

                uint160 sqrtPriceX96;
                int24 tick;

                if (currentPoolType == ArbUtils.PoolType.V3) {
                    // console.log("I think pool is V3");
                    try currentV3Pool.slot0() returns (
                        uint160 sp,
                        int24 tk,
                        uint16,
                        uint16,
                        uint16,
                        uint8,
                        bool
                    ) {
                        if (sp == 0) {
                            // console.log(
                            // "Pool has zero sqrtPriceX96, skipping:",
                            // currentPoolAddr
                            // );
                            continue;
                        }
                        sqrtPriceX96 = sp;
                        tick = tk;
                    } catch {
                        // console.log("Gas in slot0 CATCH:", gasleft());
                        // console.log(
                        // "Failed to get slot0 for V3 pool, skipping:",
                        // currentPoolAddr
                        // );
                        continue;
                    }
                } else {
                    // console.log("I think pool is PANCAKESWAP_V3");
                    // PANCAKESWAP_V3
                    IPancakeV3Pool pcsv3Pool = IPancakeV3Pool(currentPoolAddr);
                    try pcsv3Pool.slot0() returns (
                        uint160 sp,
                        int24 tk,
                        uint16,
                        uint16,
                        uint16,
                        uint32,
                        bool
                    ) {
                        // console.log(
                        // "got pancakeswap slot0. Gas after slot0:",
                        // gasleft()
                        // );
                        if (sp == 0) {
                            // console.log(
                            // "Pool has zero sqrtPriceX96, skipping:",
                            // currentPoolAddr
                            // );
                            continue;
                        }
                        // console.log("sp:", sp);
                        // console.log("tk:");
                        // console.logInt(tk);
                        sqrtPriceX96 = sp;
                        tick = tk;
                    } catch {
                        // console.log(
                        // "Gas in pancakeswap slot0 CATCH:",
                        // gasleft()
                        // );
                        // console.log(
                        // "Failed to get slot0 for pancakeswap pool, skipping:",
                        // currentPoolAddr
                        // );
                        continue;
                    }
                }

                if (
                    this.isPoolDust(
                        sqrtPriceX96,
                        tick,
                        L,
                        currentPoolInfo.tickSpacing,
                        poolToken0 == tokenA,
                        minChunkIn
                    )
                ) {
                    // console.log(
                    // "isPoolDust: true. Skipping pool:",
                    // currentPoolAddr
                    // );
                    continue;
                }

                uint8 dec0 = currentPoolInfo.token0Decimals;
                uint8 dec1 = currentPoolInfo.token1Decimals;
                // console.log("dec0:", dec0);
                // console.log("dec1:", dec1);

                rawPriceScaled = this.getRawPriceScaled(
                    sqrtPriceX96,
                    poolToken0 == tokenA,
                    dec0,
                    dec1
                );
                effBuyPrice = this.getEffectiveBuyPrice(
                    rawPriceScaled,
                    currentPoolFee
                ); // currentPoolFee is V3 fee
                effSellPrice = this.getEffectiveSellPrice(
                    rawPriceScaled,
                    currentPoolFee
                ); // currentPoolFee is V3 fee
                // console.log("rawPriceScaled:", rawPriceScaled);
                // console.log("effBuyPrice:", effBuyPrice);
                // console.log("effSellPrice:", effSellPrice);
            } else if (
                currentPoolType == ArbUtils.PoolType.V2 ||
                currentPoolType == ArbUtils.PoolType.PANCAKESWAP_V2
            ) {
                // console.log("I think pool is V2");
                IUniswapV2Pair currentV2Pool = IUniswapV2Pair(currentPoolAddr);
                (uint112 r0, uint112 r1, ) = currentV2Pool.getReserves();

                address poolToken0 = currentPoolInfo.token0;
                address poolToken1 = currentPoolInfo.token1;

                bool isWantedPair = (poolToken0 == tokenA &&
                    poolToken1 == tokenB) ||
                    (poolToken0 == tokenB && poolToken1 == tokenA);
                if (!isWantedPair) continue;

                // minChunkIn is for tokenA. isV2PoolDust needs tokenIn, which is tokenA here.
                if (
                    this.isV2PoolDust(
                        currentV2Pool,
                        tokenA,
                        minChunkIn,
                        currentPoolFee,
                        r0,
                        r1,
                        poolToken0,
                        poolToken1
                    )
                ) {
                    continue;
                }
                // For V2, tokenA vs tokenB for pricing is handled inside getV2RawPriceScaled
                rawPriceScaled = this.getV2RawPriceScaled(
                    currentV2Pool,
                    tokenA,
                    tokenB,
                    r0,
                    r1,
                    poolToken0,
                    poolToken1,
                    currentPoolInfo.token0Decimals,
                    currentPoolInfo.token1Decimals
                );
                if (rawPriceScaled == 0) continue; // V2 price is 0 if no liquidity

                // currentPoolFee for V2 pools should be V2_POOL_FEE_PPM (e.g. 3000)
                effBuyPrice = this.getV2EffectiveBuyPrice(
                    rawPriceScaled,
                    currentPoolFee
                );
                effSellPrice = this.getV2EffectiveSellPrice(
                    rawPriceScaled,
                    currentPoolFee
                );
            } else {
                // console.log(
                // "Pool type not supported, skipping pool:",
                // currentPoolAddr
                // );
                // Should not happen with enum
                continue;
            }

            if (effBuyPrice < bestBuyPrice) {
                // console.log("effBuyPrice < bestBuyPrice");
                // console.log("effBuyPrice:", effBuyPrice);
                // console.log("bestBuyPrice:", bestBuyPrice);
                bestBuyPrice = effBuyPrice;
                bestBuyPool = currentPoolAddr;
                bestBuyPoolType = currentPoolType;
            }
            if (effSellPrice > bestSellPrice) {
                // console.log("effSellPrice > bestSellPrice");
                // console.log("effSellPrice:", effSellPrice);
                // console.log("bestSellPrice:", bestSellPrice);
                bestSellPrice = effSellPrice;
                bestSellPool = currentPoolAddr;
                bestSellPoolType = currentPoolType;
            }
            // console.log("... end of find best pools loop");
            // console.log("... Best Buy Pool:", bestBuyPool);
            // console.log("... Best Sell Pool:", bestSellPool);
        }
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
                v2Pool,
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
    function quoteKey(
        address tokenA,
        address tokenB,
        uint128 qBuy,
        uint128 qSell
    ) public pure returns (bytes32 key) {
        return
            tokenA < tokenB
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
    ) public pure returns (uint256 bestChunk, int256 bestPL) {
        if (hi < lo) return (0, 0);

        bestPL = -type(int256).max;
        bestChunk = 0;

        for (uint8 iter; iter < 16 && lo <= hi; ++iter) {
            // Bounded binary search keeps execution predictable inside hook callbacks.
            // 16 rounds is enough once `hi` is already a narrow, liquidity-derived bound.
            uint256 mid = (lo + hi) >> 1; // mid = (lo+hi)/2

            // Approximate scaling in the local execution window.
            // This is intentionally heuristic; exact tick-by-tick simulation is too costly here.
            uint256 intermOut_mid = FullMath.mulDiv(intermOut_full, mid, hi);
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
            int256 plMid = ArbMath._simulatedPL(
                mid,
                intermOut_mid,
                intermCapB,
                feeB,
                intermInB_mid,
                startOut_mid
            );

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

        // Track estimated impact for observability/guardrails; refinement happens in part 2.
        uint256 impactOnA_forChunkPreImpact = ArbMath._estImpactBps(
            poolA_address,
            startToken,
            currentChunkPreImpact
        );
        uint256 roughChunk = currentChunkPreImpact;
        params.calculatedSellImpactBps = impactOnA_forChunkPreImpact;

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
    function findBestV3Chunk(
        V3SwapParams memory params,
        uint256 minChunkForStartToken
    ) public pure returns (uint256 bestChunk) {
        (uint256 poolB_maxIn, uint256 poolB_maxStartOut) = ArbMath
            ._deltaAmounts(
                params.zeroForOneB,
                params.poolBState.sqrtPrice,
                params.sqrtPriceLimitB,
                params.poolBState.liquidity
            );

        (bestChunk, ) = _binarySearchBestChunk(
            params.chunkToSwap, // This is the roughChunk (upper bound)
            minChunkForStartToken,
            params.intermediateAmountPotentiallyFromA,
            params.intermediateCapacityOfB,
            poolB_maxIn,
            poolB_maxStartOut,
            params.feeB
        );

        if (bestChunk == 0) {
            return 0;
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
    ) public view returns (uint256 rawPriceScaled) {
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
    ) public pure returns (uint256 effectiveBuyPrice) {
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
    ) public pure returns (uint256 effectiveSellPrice) {
        // To sell tokenA, you receive less of tokenB. Price B/A decreases.
        // The amount of tokenB received is rawV2PriceScaled * (1 - feeRate)
        // Example: Fee 0.3%. Rate = 0.003. 1 - feeRate = 0.997
        // effectivePrice = rawPrice * 0.997 = rawPrice * 997 / 1000 (if fee is exactly 0.3%)
        // Using PPM: effectivePrice = rawPrice * (1_000_000 - v2FeePPM) / 1_000_000
        return
            FullMath.mulDiv(rawV2PriceScaled, 1_000_000 - v2FeePPM, 1_000_000);
    }

    /**
     * @notice Checks if a V2 pool is too thin for arbitrage (a "dust pool").
     * @dev A pool is considered dust if its reserves are zero, or if swapping
     *      `minChunkIn` of `tokenIn` yields less than 1 wei of `tokenOut`.
     * @param pair The IUniswapV2Pair contract instance.
     * @param tokenIn The address of the input token for the hypothetical swap.
     * @param minChunkIn The minimum amount of input token considered significant.
     * @return isDust True if the pool is considered a dust pool, false otherwise.
     */
    function isV2PoolDust(
        IUniswapV2Pair pair,
        address tokenIn,
        uint256 minChunkIn, // minChunkIn is for tokenIn
        uint24 v2FeePPM,
        uint112 reserve0,
        uint112 reserve1,
        address pairToken0,
        address pairToken1
    ) public view returns (bool isDust) {
        if (reserve0 == 0 || reserve1 == 0) {
            return true; // No liquidity or one-sided liquidity is dust
        }

        uint256 reserveIn;
        uint256 reserveOut;

        if (tokenIn == pairToken0) {
            reserveIn = reserve0;
            reserveOut = reserve1;
        } else if (tokenIn == pairToken1) {
            reserveIn = reserve1;
            reserveOut = reserve0;
        } else {
            revert ArbErrors.SwapInputTokenNotInPool(); // tokenIn must be one of the pair's tokens
        }

        if (minChunkIn == 0) {
            return true; // Swapping zero input is not meaningful for a dust check
        }

        if (v2FeePPM >= 1_000_000) {
            return true;
        }
        uint256 amountInWithFee = FullMath.mulDiv(
            minChunkIn,
            1_000_000 - v2FeePPM,
            1_000_000
        );
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn + amountInWithFee;

        if (denominator == 0) {
            return true; // Should not happen if reserves are non-zero and minChunkIn > 0
        }

        uint256 amountOut = numerator / denominator;

        // If the calculated output is less than 1 wei, consider it dust.
        // A more sophisticated check might use _minChunk for tokenOut.
        return amountOut < 1;
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

        // Heuristic probe ladder.
        // Exact optimal V2-V2 size is possible off-chain but expensive on-chain,
        // so we probe representative sizes and pick the best simulated outcome.
        // The largest probe (50% balance) is intentional: slippage usually makes
        // oversizing fail fast, and smaller candidates are then cheap to test.
        uint256[] memory testChunkSizes = new uint256[](4);
        testChunkSizes[0] = minChunkStartToken;
        if (testChunkSizes[0] == 0 && startTokenBalance > 0)
            testChunkSizes[0] = 1; // Min 1 wei

        testChunkSizes[1] = startTokenBalance / 100; // 1% of balance
        testChunkSizes[2] = startTokenBalance / 10; // 10% of balance
        testChunkSizes[3] = startTokenBalance / 2; // 50% of balance

        int256 bestSimulatedProfit = -type(int256).max; // Initialize with very small number
        uint256 bestChunk = 0;

        for (uint i = 0; i < testChunkSizes.length; i++) {
            uint256 currentTestChunk = testChunkSizes[i];
            if (currentTestChunk == 0) continue;
            if (currentTestChunk < minChunkStartToken && minChunkStartToken > 0)
                currentTestChunk = minChunkStartToken; // Ensure at least minChunk if possible
            if (currentTestChunk > startTokenBalance)
                currentTestChunk = startTokenBalance;
            if (currentTestChunk == 0) continue;

            // Skip duplicate probes when balance is small and ratios collapse to same value.
            if (
                i > 0 &&
                currentTestChunk == testChunkSizes[i - 1] &&
                currentTestChunk != minChunkStartToken
            ) continue;
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
            if (
                minChunkStartToken > 0 &&
                minChunkStartToken <= startTokenBalance &&
                minChunkStartToken != bestChunk
            ) {
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
                if (params.expectedProfitFromChunk <= 0)
                    params.opportunityExists = false;
            }
            // Ensure it's not below minChunk if it was profitable, unless it IS minChunk
            if (
                params.estimatedChunkToSwap < minChunkStartToken &&
                params.estimatedChunkToSwap > 0 &&
                params.opportunityExists
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

        // console.log("simulateV2V2Profit");

        // Trade 1 (Pool A): startToken -> intermediateToken
        uint256 intermediateAmountOut = getAmountOut(
            chunkToSwapStartToken,
            rA_start,
            rA_interm,
            poolAFeePPM
        );

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
        uint256 startTokenReceivedBack = getAmountOut(
            intermediateAmountOut,
            rB_interm,
            rB_start,
            poolBFeePPM
        );

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
        uint256 reserveOut
    ) public pure returns (uint256 amountOut) {
        return getAmountOut(amountIn, reserveIn, reserveOut, 3000);
    }

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

    /// @dev Calculates the required input amount for a given output amount for a V2 swap.
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountIn) {
        return getAmountIn(amountOut, reserveIn, reserveOut, 3000);
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint24 feePPM
    ) public pure returns (uint256 amountIn) {
        if (amountOut == 0) return 0;
        if (reserveIn == 0 || reserveOut == 0) return type(uint256).max;
        if (amountOut >= reserveOut) return type(uint256).max; // Not enough liquidity
        if (feePPM >= 1_000_000) return type(uint256).max;
        uint256 numerator = reserveIn * amountOut * 1_000_000;
        uint256 denominator = (reserveOut - amountOut) * (1_000_000 - feePPM);
        amountIn = (numerator / denominator) + 1;
        return amountIn;
    }

    // [NEW] Improve multi-step simulation for better accuracy (reduce partials)
    function calculateV3SqrtPriceLimitForAmountIn(
        IUniswapV3Pool pool,
        address tokenIn,
        uint256 amountIn,
        uint16 slippageBps
    ) public view returns (uint160 sqrtPriceLimitX96) {
        // console.log(
        //     "calculateV3SqrtPriceLimitForAmountIn - amountIn:",
        //     amountIn
        // );
        // console.log(
        //     "calculateV3SqrtPriceLimitForAmountIn - slippageBps:",
        //     slippageBps
        // );
        // console.log("calculateV3SqrtPriceLimitForAmountIn - tokenIn:", tokenIn);
        // console.log(
        //     "calculateV3SqrtPriceLimitForAmountIn - pool:",
        //     address(pool)
        // );
        // console.log(
        //     "calculateV3SqrtPriceLimitForAmountIn - token0:",
        //     pool.token0()
        // );
        // console.log("calculateV3SqrtPriceLimitForAmountIn - fee:", pool.fee());
        // console.log(
        //     "calculateV3SqrtPriceLimitForAmountIn - zeroForOne:",
        //     tokenIn == pool.token0()
        // );
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

        // console.log(
        //     "calculateV3SqrtPriceLimitForAmountIn - sqrtPriceLimitX96:",
        //     sqrtPriceLimitX96
        // );

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
    ) public view returns (int256 profitInStartToken) {
        if (chunkToSwapStartToken == 0) return 0;

        // console.log("simulateV2V3Profit");

        // Step 1: Simulate V2 swap (startToken -> intermediateToken)
        (uint112 rA_start, uint112 rA_interm, ) = _getV2ReservesForTokens(
            poolA,
            startToken,
            intermediateToken
        );
        if (rA_start == 0 || rA_interm == 0)
            return -int256(chunkToSwapStartToken);

        // console.log("rA_start", rA_start);
        // console.log("rA_interm", rA_interm);
        // console.log("chunkToSwapStartToken", chunkToSwapStartToken);
        // console.log("poolA", address(poolA));
        // console.log("poolB", address(poolB));
        // console.log("startToken", startToken);
        // console.log("intermediateToken", intermediateToken);

        uint256 intermediateAmountOut = getAmountOut(
            chunkToSwapStartToken,
            rA_start,
            rA_interm,
            poolAFeePPM
        );

        // console.log("intermediateAmountOut", intermediateAmountOut);
        if (intermediateAmountOut == 0) return -int256(chunkToSwapStartToken);

        // Step 2: Accurately simulate V3 swap (intermediateToken -> startToken) using SwapMath
        (uint160 sqrtP, , , , , , ) = poolB.slot0();
        uint128 liquidity = poolB.liquidity();
        address v3_token0 = poolB.token0();
        bool zeroForOne = (intermediateToken == v3_token0);

        // console.log("liquidity", liquidity);
        // console.log("sqrtP", sqrtP);
        // console.log("zeroForOne", zeroForOne);
        // console.log("startToken", startToken);

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

        // console.log("startTokenReceivedBack", startTokenReceivedBack);

        // console.log("chunkToSwapStartToken", chunkToSwapStartToken);

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
    ) public view returns (int256 profitInStartToken) {
        if (chunkToSwapStartToken == 0) return 0;

        // console.log("simulateV3V2Profit");

        // Step 1: Accurately simulate V3 swap (startToken -> intermediateToken) using SwapMath
        (uint160 sqrtP, , , , , uint8 feeProtocol, ) = poolA.slot0();
        uint128 liquidity = poolA.liquidity();
        address v3_token0 = poolA.token0();
        bool zeroForOne = (startToken == v3_token0);

        // console.log("liquidity", liquidity);
        // console.log("sqrtP", sqrtP);
        // console.log("zeroForOne", zeroForOne);
        // console.log("startToken", startToken);
        // console.log("intermediateToken", intermediateToken);
        // console.log("chunkToSwapStartToken", chunkToSwapStartToken);
        // console.log("poolA", address(poolA));
        // console.log("poolB", address(poolB));

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

        // console.log("intermediateAmountOut", intermediateAmountOut);

        if (intermediateAmountOut == 0) return -int256(chunkToSwapStartToken);

        // Step 2: Simulate V2 swap (intermediateToken -> startToken)
        (uint112 rB_interm, uint112 rB_start, ) = _getV2ReservesForTokens(
            poolB,
            intermediateToken,
            startToken
        );
        if (rB_start == 0 || rB_interm == 0)
            return -int256(chunkToSwapStartToken);

        // console.log("rB_interm", rB_interm);
        // console.log("rB_start", rB_start);

        uint256 startTokenReceivedBack = getAmountOut(
            intermediateAmountOut,
            rB_interm,
            rB_start,
            poolBFeePPM
        );

        // console.log("startTokenReceivedBack", startTokenReceivedBack);

        if (startTokenReceivedBack > chunkToSwapStartToken) {
            profitInStartToken = int256(
                startTokenReceivedBack - chunkToSwapStartToken
            );
        } else {
            profitInStartToken = -int256(
                chunkToSwapStartToken - startTokenReceivedBack
            );
        }
        // console.log("profitInStartToken", uint256(profitInStartToken));
        return profitInStartToken;
    }

    function deltaAmounts(
        bool zeroForOne,
        uint160 sqrtP0, // Current price
        uint160 sqrtP1, // Target price
        uint128 L
    ) public pure returns (uint256 inAmt, uint256 outAmt) {
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
        return
            ArbMath._simulatedPL(
                startInA,
                intermOutA,
                intermCapB,
                feeB,
                intermInB,
                startOutB
            );
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
