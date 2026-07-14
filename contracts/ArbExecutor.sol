// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ArbExecutionStorage.sol";
import "./ArbitrageLogic.sol";
import {ArbErrors} from "./Errors.sol";
import {IArbExecutor} from "./interfaces/IArbExecutor.sol";
import {IDataStorage} from "./interfaces/IDataStorage.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IPancakeV3Pool} from "./interfaces/IPancakeV3Pool.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/// @title ArbExecutor
/// @notice Delegatecalled execution implementation for ArbHook.
/// @dev It has the same leading storage layout as ArbHook through
///      ArbExecutionStorage. Direct calls are rejected so its own empty storage
///      can never be mistaken for hook state.
contract ArbExecutor is ArbExecutionStorage, IArbExecutor {
    address private immutable SELF;
    uint8 private constant MAX_ROUTE_ATTEMPTS = 5;

    constructor() {
        SELF = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == SELF) revert ArbErrors.ExecutorOnlyDelegateCall();
        _;
    }

    // -------------------------- Core entrypoint ----------------------------
    /// @notice Evaluate arbitrage opportunities across all configured base/counter pairs.
    /// @dev Must be executed via self-call. Individual pair attempts are isolated with
    ///      low-level calls so a failing path does not revert the full cycle.
    ///      This internal execution path may still revert on invariant or auth failures.
    function attemptAllInternal(uint256 maxIterations) external override onlyDelegateCall returns (bool success) {
        lastExecutionProfit = 0;
        // Never let a positive-but-unpersisted execution reuse stale trade data
        // from a prior callback.
        delete lastTradeData;

        int256 totalProfit = 0;
        uint256 baseCount = supportedTokens.length;
        // Outer loop walks base tokens in registration order.
        for (uint256 i = 0; i < baseCount; ++i) {
            address baseToken = supportedTokens[i];
            address[] storage counterTokens = baseCounterList[baseToken];
            uint256 counterCount = counterTokens.length;

            // Inner loop walks all counterpart tokens registered for this base.
            for (uint256 j = 0; j < counterCount; ++j) {
                address counterToken = counterTokens[j];
                (int256 profit,) = _runPair(baseToken, counterToken, maxIterations);
                if (profit > 0) {
                    // Deliberately stop at the first profitable path to keep callback gas bounded.
                    totalProfit = profit;
                    break; // exit inner loop
                }
            }
            if (totalProfit > 0) {
                break; // exit outer loop
            }
        }

        lastExecutionProfit = totalProfit;
        bool tradeWasProfitable = totalProfit > 0;
        bool shouldStore = tradeWasProfitable && uint256(totalProfit) >= minProfitToEmit;
        if (shouldStore && address(dataStorage) != address(0)) {
            dataStorage.storeTradeData(lastTradeData);
        }
        return tradeWasProfitable;
    }

    // ---------------------------- Pair runner ------------------------------
    struct LoopState {
        // Pool-bound route keys attempted during this _runPair invocation.
        bytes32[5] tried;
        uint8 triedCount;
        // Bounded retry count for alternative pool combinations.
        uint8 attempts;
    }

    struct PoolQuote {
        address pool;
        uint256 buyPrice;
        uint256 sellPrice;
        ArbUtils.PoolType poolType;
    }

    function _runPair(address tokenA, address tokenB, uint256 maxIter)
        internal
        returns (int256 cumulativeProfit, uint256 iterations)
    {
        LoopState memory state;

        // Failure is execution-context dependent: unchanged prices do not mean
        // unchanged balances, approvals, liquidity, or owner configuration.
        // Keep retries local to this invocation and never persist a price-only
        // failure cache across callbacks.
        while (state.attempts < MAX_ROUTE_ATTEMPTS) {
            (
                address buyPool,
                address sellPool,
                uint256 buyPrice,
                uint256 sellPrice,
                ArbUtils.PoolType buyPoolType,
                ArbUtils.PoolType sellPoolType
            ) = findBestPools(tokenA, tokenB, state.tried, state.triedCount);

            if (buyPool == address(0)) return (cumulativeProfit, iterations);
            bytes32 routeKey = _routeKey(tokenA, tokenB, buyPool, sellPool, buyPrice, sellPrice);

            state.tried[state.triedCount] = routeKey;
            unchecked {
                ++state.triedCount;
                ++state.attempts;
            }

            // Isolate pair execution failure from the outer scanner.
            (bool successCall, bytes memory returndata) = address(this)
                .call(
                    abi.encodeWithSelector(
                        this.executeIterativeArb.selector,
                        sellPool,
                        buyPool,
                        tokenA,
                        tokenB,
                        maxIter,
                        sellPoolType,
                        buyPoolType
                    )
                );

            if (!successCall) {
                emit PairExecutionFailed(tokenA, tokenB, buyPool, sellPool, returndata);
                continue;
            }

            (bool tradeSuccess, int256 profit, uint256 iters) = abi.decode(returndata, (bool, int256, uint256));

            cumulativeProfit += profit;
            iterations += iters;

            if (tradeSuccess && profit > 0) {
                return (cumulativeProfit, iterations);
            }
        }
        return (cumulativeProfit, iterations);
    }

    // ------------------------- Pool discovery helper -----------------------
    /// @dev Ranks all matching, untried buy/sell combinations by executable
    ///      spread. Quoting each physical pool once avoids a quadratic number
    ///      of external reads while allowing several failed pools on either
    ///      side to rotate within one bounded invocation.
    function findBestPools(address tokenA, address tokenB, bytes32[5] memory tried, uint8 triedCount)
        internal
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
        ArbUtils.PoolInfo[] storage pools = tokenPools[tokenA];
        uint256 poolCount = pools.length;
        if (poolCount == 0) {
            return _emptyBestPools();
        }

        PoolQuote[] memory quotes = new PoolQuote[](poolCount);
        uint256 quoteCount;

        for (uint256 i; i < poolCount;) {
            ArbUtils.PoolInfo storage pool = pools[i];
            address poolAddress = pool.poolAddress;
            if (
                poolAddress != address(0) && _isMatchingPair(pool, tokenA, tokenB)
                    && _hasCurrentExecutableLiquidity(pool)
            ) {
                ArbUtils.PoolInfo memory poolInfo = pool;
                (uint256 buyPrice, uint256 sellPrice, bool priceOk) =
                    arbLib._getSinglePoolPrices(tokenA, tokenB, poolInfo);

                // Selection is quote-based after excluding state the executor
                // cannot enter. Directional capacity, impact, and profit remain
                // sizing/execution concerns.
                if (priceOk && buyPrice > 0 && sellPrice > 0) {
                    quotes[quoteCount] = PoolQuote(poolAddress, buyPrice, sellPrice, pool.poolType);
                    unchecked {
                        ++quoteCount;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }

        uint256 bestSpread;
        for (uint256 i; i < quoteCount; ++i) {
            PoolQuote memory buy = quotes[i];
            for (uint256 j; j < quoteCount; ++j) {
                PoolQuote memory sell = quotes[j];
                if (buy.pool == sell.pool || sell.sellPrice <= buy.buyPrice) continue;

                bytes32 candidateKey = _routeKey(tokenA, tokenB, buy.pool, sell.pool, buy.buyPrice, sell.sellPrice);
                if (_wasRouteTried(candidateKey, tried, triedCount)) continue;

                uint256 spread = sell.sellPrice - buy.buyPrice;
                if (bestBuyPool == address(0) || spread > bestSpread) {
                    bestSpread = spread;
                    bestBuyPool = buy.pool;
                    bestSellPool = sell.pool;
                    bestBuyPrice = buy.buyPrice;
                    bestSellPrice = sell.sellPrice;
                    bestBuyPoolType = buy.poolType;
                    bestSellPoolType = sell.poolType;
                }
            }
        }

        if (bestBuyPool == address(0)) return _emptyBestPools();
    }

    function _routeKey(
        address tokenA,
        address tokenB,
        address buyPool,
        address sellPool,
        uint256 buyPrice,
        uint256 sellPrice
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(tokenA, tokenB, buyPool, sellPool, buyPrice, sellPrice));
    }

    function _wasRouteTried(bytes32 candidate, bytes32[5] memory tried, uint8 triedCount) private pure returns (bool) {
        for (uint8 i; i < triedCount; ++i) {
            if (tried[i] == candidate) return true;
        }
        return false;
    }

    function _emptyBestPools()
        private
        pure
        returns (address, address, uint256, uint256, ArbUtils.PoolType, ArbUtils.PoolType)
    {
        return (address(0), address(0), 0, 0, ArbUtils.PoolType.V3, ArbUtils.PoolType.V3);
    }

    function _isMatchingPair(ArbUtils.PoolInfo storage pool, address tokenA, address tokenB)
        private
        view
        returns (bool)
    {
        return (pool.token0 == tokenA && pool.token1 == tokenB) || (pool.token0 == tokenB && pool.token1 == tokenA);
    }

    function _hasCurrentExecutableLiquidity(ArbUtils.PoolInfo storage pool) private view returns (bool) {
        if (pool.poolType != ArbUtils.PoolType.V3 && pool.poolType != ArbUtils.PoolType.PANCAKESWAP_V3) {
            return true;
        }

        // Current execution and impact simulation both fail closed at zero
        // active liquidity; do not let an attractive but unreachable gap quote
        // consume one of the bounded route attempts.
        try IUniswapV3Pool(pool.poolAddress).liquidity() returns (uint128 liquidity) {
            return liquidity != 0;
        } catch {
            return false;
        }
    }

    // ---------------------------- Core executor ----------------------------
    /// @notice Execute bounded iterative arbitrage for one chosen buy/sell pool pair.
    /// @dev Loop shape:
    ///      1) choose chunk size for current pool types (V3-V3, V2-V2, or mixed),
    ///      2) execute startToken->intermediateToken then reverse leg,
    ///      3) stop as soon as marginal iteration profit is non-positive.
    ///      This greedy early-stop avoids paying gas to chase diminishing edge.
    function executeIterativeArb(
        address poolA_addr,
        address poolB_addr,
        address startToken,
        address intermediateToken,
        uint256 maxIterations,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType
    ) external override onlyDelegateCall returns (bool success, int256 cumulativeProfit, uint256 iterations) {
        if (maxIterations == 0) return (false, 0, 0);
        if (poolA_addr == poolB_addr) return (false, 0, 0);

        IERC20 startTokenContract = IERC20(startToken);
        IERC20 intermediateTokenContract = IERC20(intermediateToken);
        // These snapshots define this execution's inventory boundary. In
        // particular, residual cleanup must never liquidate inventory that was
        // already held by the hook before this isolated attempt began.
        uint256 startTokenBalanceAtEntry = startTokenContract.balanceOf(address(this));
        uint256 intermediateTokenBalanceAtEntry = intermediateTokenContract.balanceOf(address(this));
        // Minimum practical trade size for this token precision (e.g. 1e14 for 18-dec tokens).
        uint256 minChunkStartToken = _minChunk(startToken);
        if (minChunkStartToken > uint256(type(int256).max)) {
            return (false, 0, 0);
        }
        // Guardrail to avoid "winning tiny amount after prior losses" situations.
        int256 minCumulativeProfit = int256(minChunkStartToken) / 10;

        bool isPoolAV3 = (poolAType == ArbUtils.PoolType.V3 || poolAType == ArbUtils.PoolType.PANCAKESWAP_V3);
        bool isPoolBV3 = (poolBType == ArbUtils.PoolType.V3 || poolBType == ArbUtils.PoolType.PANCAKESWAP_V3);

        int24 initialAbsSpreadForThisArbOpportunity = 0;

        if (isPoolAV3 && isPoolBV3) {
            // For V3/V3 paths we anchor dynamic sizing to the initial tick spread.
            IUniswapV3Pool pA_v3_check = IUniswapV3Pool(poolA_addr);
            IUniswapV3Pool pB_v3_check = IUniswapV3Pool(poolB_addr);
            int24 initialTickA_check;
            int24 initialTickB_check;
            address initialTokenA0_check;
            if (poolAType == ArbUtils.PoolType.V3) {
                try pA_v3_check.slot0() returns (uint160, int24 tA, uint16, uint16, uint16, uint8, bool) {
                    initialTickA_check = tA;
                } catch {
                    return (false, 0, 0);
                }
            } else {
                try IPancakeV3Pool(poolA_addr).slot0() returns (
                    uint160, int24 tA, uint16, uint16, uint16, uint32, bool
                ) {
                    initialTickA_check = tA;
                } catch {
                    return (false, 0, 0);
                }
            }

            if (poolBType == ArbUtils.PoolType.V3) {
                try pB_v3_check.slot0() returns (uint160, int24 tB, uint16, uint16, uint16, uint8, bool) {
                    initialTickB_check = tB;
                } catch {
                    return (false, 0, 0);
                }
            } else {
                try IPancakeV3Pool(poolB_addr).slot0() returns (
                    uint160, int24 tB, uint16, uint16, uint16, uint32, bool
                ) {
                    initialTickB_check = tB;
                } catch {
                    return (false, 0, 0);
                }
            }

            try pA_v3_check.token0() returns (address t0A) {
                initialTokenA0_check = t0A;
            } catch {
                return (false, 0, 0);
            }
            int24 initialSignedSpread_check = (initialTokenA0_check == startToken)
                ? (initialTickA_check - initialTickB_check)
                : (initialTickB_check - initialTickA_check);
            initialAbsSpreadForThisArbOpportunity =
                initialSignedSpread_check >= 0 ? initialSignedSpread_check : -initialSignedSpread_check;

            if (initialAbsSpreadForThisArbOpportunity < int24(uint24(minSpreadBps))) {
                // Spread already too tight; treat as clean no-op success.
                return (true, 0, 0);
            }
        }

        uint256 totalAmountSwapped = 0;
        // Outer execution loop: each pass recomputes a fresh chunk from live state.
        for (uint256 i = 0; i < maxIterations;) {
            uint256 balanceBeforeIteration = startTokenContract.balanceOf(address(this));

            uint256 chunkToSwap = 0;
            uint160 sqrtPriceLimitA_v3 = 0;
            uint160 sqrtPriceLimitB_v3 = 0;

            if (isPoolAV3 && isPoolBV3) {
                // V3/V3 path:
                // - derive a rough chunk from spread/liquidity,
                // - refine with profit search.
                ArbitrageLogic.IterationConfig memory iterConfig;
                iterConfig.minSpreadBps = minSpreadBps;
                iterConfig.chunkSpreadConsumptionBps = CHUNK_SPREAD_CONSUMPTION_BPS;
                iterConfig.bpsDivisor = BPS_DIVISOR;
                iterConfig.maxImpactBps = _MAX_IMPACT_BPS;
                iterConfig.minChunkForStartToken = minChunkStartToken;
                iterConfig.currentStartTokenBalance = balanceBeforeIteration;
                iterConfig.initialAbsSpread = initialAbsSpreadForThisArbOpportunity;

                ArbitrageLogic.V3SwapParams memory v3Params = arbLib.getV3SwapParameters(
                    poolA_addr, poolB_addr, startToken, intermediateToken, iterConfig, poolAType, poolBType
                );

                if (!v3Params.shouldContinue) {
                    break;
                }

                chunkToSwap = arbLib.findBestV3Chunk(v3Params, iterConfig.minChunkForStartToken);

                if (chunkToSwap == 0) {
                    break;
                }

                sqrtPriceLimitA_v3 = v3Params.sqrtPriceLimitA;
                sqrtPriceLimitB_v3 = v3Params.sqrtPriceLimitB;
            } else if (!isPoolAV3 && !isPoolBV3) {
                // V2/V2 path:
                // start from heuristic candidate, then halve until a profitable chunk survives.
                ArbitrageLogic.V2TradeParams memory v2Params = arbLib.calculateV2TradeParams(
                    poolA_addr,
                    poolB_addr,
                    startToken,
                    intermediateToken,
                    balanceBeforeIteration,
                    minChunkStartToken,
                    _v2FeeForPoolType(poolAType),
                    _v2FeeForPoolType(poolBType)
                );

                if (!v2Params.opportunityExists) break;
                chunkToSwap = v2Params.estimatedChunkToSwap;

                uint256 initialChunkForV2Halving = chunkToSwap;
                if (initialChunkForV2Halving > 0) {
                    // Start from the largest heuristic chunk first.
                    // If too aggressive, halve quickly instead of doing many tiny upward probes.
                    uint8 v2Halvings = 0;
                    uint256 testV2Chunk = initialChunkForV2Halving;
                    bool profitableV2ChunkFound = false;
                    int256 lastEstPLFullV2Halving = 0;

                    (uint112 rA_s, uint112 rA_i,) =
                        arbLib._getV2ReservesForTokens(IUniswapV2Pair(poolA_addr), startToken, intermediateToken);
                    (uint112 rB_i, uint112 rB_s,) =
                        arbLib._getV2ReservesForTokens(IUniswapV2Pair(poolB_addr), intermediateToken, startToken);

                    if (rA_s > 0 && rA_i > 0 && rB_i > 0 && rB_s > 0) {
                        // Monotonic backoff: the first chunk that clears profit thresholds wins.
                        while (true) {
                            lastEstPLFullV2Halving = arbLib.simulateV2V2Profit(
                                testV2Chunk,
                                IUniswapV2Pair(poolA_addr),
                                IUniswapV2Pair(poolB_addr),
                                startToken,
                                intermediateToken,
                                rA_s,
                                rA_i,
                                rB_i,
                                rB_s,
                                _v2FeeForPoolType(poolAType),
                                _v2FeeForPoolType(poolBType)
                            );

                            if (
                                lastEstPLFullV2Halving > 0
                                    && cumulativeProfit + lastEstPLFullV2Halving >= minCumulativeProfit
                            ) {
                                chunkToSwap = testV2Chunk;
                                profitableV2ChunkFound = true;
                                break;
                            }
                            if (v2Halvings >= 9) break;
                            testV2Chunk >>= 1;
                            if (testV2Chunk < minChunkStartToken) break;
                            unchecked {
                                v2Halvings++;
                            }
                        }
                        if (!profitableV2ChunkFound) break;
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else {
                // Mixed V2/V3 path:
                // exact optimum is expensive on-chain, so probe from half-balance downward.
                uint256 currentBal = balanceBeforeIteration;
                if (currentBal == 0) break;

                // Half-balance is a practical "large first probe":
                // it converges quickly with halving while avoiding full-balance over-commit.
                uint256 initialTestChunk = currentBal / 2;
                if (initialTestChunk > 0) {
                    chunkToSwap = arbLib.findBestMixedPairChunk(
                        poolA_addr,
                        poolB_addr,
                        poolAType,
                        poolBType,
                        startToken,
                        intermediateToken,
                        initialTestChunk,
                        minChunkStartToken,
                        cumulativeProfit,
                        int256(minChunkStartToken) / 10
                    );
                }
                if (chunkToSwap == 0) break;
            }

            if (chunkToSwap == 0) break;

            if (isPoolAV3) {
                uint256 estimatedImpactA = arbLib.estimateImpactBps(poolA_addr, poolAType, startToken, chunkToSwap);
                if (estimatedImpactA > _MAX_IMPACT_BPS) break;

                // Mixed V3->V2 routes previously used an effectively unbounded
                // protocol limit. Bind the swap to the amount-specific limit;
                // the tick-aware impact check above remains the policy guard.
                if (!isPoolBV3) {
                    sqrtPriceLimitA_v3 =
                        arbLib.calculateV3SqrtPriceLimitForAmountIn(poolA_addr, poolAType, startToken, chunkToSwap, 0);
                    if (sqrtPriceLimitA_v3 == 0) break;
                }
            }

            uint256 intermediateBalanceBefore = intermediateTokenContract.balanceOf(address(this));
            uint256 intermediateReceived = 0;

            // Leg 1: startToken -> intermediateToken on pool A.
            bool swap1Success = false;
            if (poolAType == ArbUtils.PoolType.V3 || poolAType == ArbUtils.PoolType.PANCAKESWAP_V3) {
                swap1Success = _executeSwapInternal_noBalanceCheck(
                    poolA_addr, poolAType, startToken, intermediateToken, chunkToSwap, sqrtPriceLimitA_v3
                );
            } else {
                (uint112 rA_start, uint112 rA_interm,) =
                    arbLib._getV2ReservesForTokens(IUniswapV2Pair(poolA_addr), startToken, intermediateToken);
                uint256 amountToReceive =
                    arbLib.getAmountOut(chunkToSwap, rA_start, rA_interm, _v2FeeForPoolType(poolAType));
                if (poolBType == ArbUtils.PoolType.V3 || poolBType == ArbUtils.PoolType.PANCAKESWAP_V3) {
                    uint256 estimatedImpactB =
                        arbLib.estimateImpactBps(poolB_addr, poolBType, intermediateToken, amountToReceive);
                    if (estimatedImpactB > _MAX_IMPACT_BPS) break;
                }
                swap1Success = _executeV2FlashSwap(
                    IUniswapV2Pair(poolA_addr), intermediateToken, amountToReceive, startToken, chunkToSwap
                );
            }
            if (!swap1Success) {
                // A first leg may already have changed state for a nonstandard
                // pool implementation. Revert the isolated self-call rather
                // than returning a partial execution to the caller.
                revert ArbErrors.AtomicArbitrageExecutionFailed();
            }

            uint256 intermediateBalanceAfter = intermediateTokenContract.balanceOf(address(this));
            if (intermediateBalanceAfter > intermediateBalanceBefore) {
                intermediateReceived = intermediateBalanceAfter - intermediateBalanceBefore;
            } else {
                intermediateReceived = 0;
            }
            if (intermediateReceived == 0) {
                revert ArbErrors.AtomicArbitrageExecutionFailed();
            }

            // Use the realized first-leg output for the second-leg policy
            // check. This protects V3/V3 routes and nonstandard V2 pools whose
            // actual output differs from the reserve quote; reverting here
            // atomically rolls back the already-completed first leg.
            if (isPoolBV3) {
                uint256 estimatedImpactB =
                    arbLib.estimateImpactBps(poolB_addr, poolBType, intermediateToken, intermediateReceived);
                if (estimatedImpactB > _MAX_IMPACT_BPS) {
                    revert ArbErrors.AtomicArbitrageExecutionFailed();
                }
            }

            bool swap2Success = false;
            // Leg 2: intermediateToken -> startToken on pool B.
            if (poolBType == ArbUtils.PoolType.V3 || poolBType == ArbUtils.PoolType.PANCAKESWAP_V3) {
                uint160 actualSqrtPriceLimitB_v3 = sqrtPriceLimitB_v3; // V3-V3 default
                if (
                    (poolAType == ArbUtils.PoolType.V2 || poolAType == ArbUtils.PoolType.PANCAKESWAP_V2)
                        && (poolBType == ArbUtils.PoolType.V3 || poolBType == ArbUtils.PoolType.PANCAKESWAP_V3)
                ) {
                    actualSqrtPriceLimitB_v3 = arbLib.calculateV3SqrtPriceLimitForAmountIn(
                        poolB_addr, poolBType, intermediateToken, intermediateReceived, 0
                    );
                }
                swap2Success = _executeSwapInternal_noBalanceCheck(
                    poolB_addr, poolBType, intermediateToken, startToken, intermediateReceived, actualSqrtPriceLimitB_v3
                );
            } else {
                (uint112 rB_interm, uint112 rB_start,) =
                    arbLib._getV2ReservesForTokens(IUniswapV2Pair(poolB_addr), intermediateToken, startToken);
                uint256 amountToReceive2 =
                    arbLib.getAmountOut(intermediateReceived, rB_interm, rB_start, _v2FeeForPoolType(poolBType));
                swap2Success = _executeV2FlashSwap(
                    IUniswapV2Pair(poolB_addr), startToken, amountToReceive2, intermediateToken, intermediateReceived
                );
            }
            if (!swap2Success) {
                // The first leg has completed, so a failed reverse leg must
                // roll back the entire isolated pair attempt.
                revert ArbErrors.AtomicArbitrageExecutionFailed();
            }

            uint256 balanceAfterIteration = startTokenContract.balanceOf(address(this));
            int256 currentIterationProfit;
            if (balanceAfterIteration >= balanceBeforeIteration) {
                uint256 gain = balanceAfterIteration - balanceBeforeIteration;
                if (gain > uint256(type(int256).max)) {
                    revert ArbErrors.AtomicArbitrageExecutionFailed();
                }
                currentIterationProfit = int256(gain);
            } else {
                uint256 loss = balanceBeforeIteration - balanceAfterIteration;
                if (loss > uint256(type(int256).max)) {
                    revert ArbErrors.AtomicArbitrageExecutionFailed();
                }
                currentIterationProfit = -int256(loss);
            }

            cumulativeProfit += currentIterationProfit;
            totalAmountSwapped += chunkToSwap;

            unchecked {
                iterations++;
            }

            // Greedy stop: once marginal iteration profit turns non-positive,
            // additional size usually worsens execution due to local curve impact.
            // The final balance check below is the authoritative net-P&L
            // guard for the whole isolated attempt.
            if (currentIterationProfit <= 0) break;
            unchecked {
                ++i;
            }
        }
        if (iterations == 0) return (false, 0, 0);

        // Only unwind intermediate balance created by this attempt. This is
        // intentionally token-agnostic: USDC and WETH are treated exactly
        // like every other asset, while pre-existing treasury inventory is
        // preserved by the entry snapshot.
        uint256 intermediateBalanceAfterExecution = intermediateTokenContract.balanceOf(address(this));
        if (intermediateBalanceAfterExecution < intermediateTokenBalanceAtEntry) {
            revert ArbErrors.AtomicArbitrageExecutionFailed();
        }

        uint256 residualCreated = intermediateBalanceAfterExecution - intermediateTokenBalanceAtEntry;
        if (residualCreated > 0) {
            _unwindCreatedIntermediate(poolB_addr, poolBType, intermediateToken, startToken, residualCreated);

            uint256 intermediateBalanceAfterFirstUnwind = intermediateTokenContract.balanceOf(address(this));
            if (intermediateBalanceAfterFirstUnwind < intermediateTokenBalanceAtEntry) {
                revert ArbErrors.AtomicArbitrageExecutionFailed();
            }
            residualCreated = intermediateBalanceAfterFirstUnwind - intermediateTokenBalanceAtEntry;

            if (residualCreated > 0) {
                _unwindCreatedIntermediate(poolA_addr, poolAType, intermediateToken, startToken, residualCreated);
            }
        }

        // A successful path must leave the intermediate-token treasury exactly
        // as it found it. Any residual or use of pre-existing inventory is a
        // failed atomic attempt, not a reason to retain a partial trade.
        if (intermediateTokenContract.balanceOf(address(this)) != intermediateTokenBalanceAtEntry) {
            revert ArbErrors.AtomicArbitrageExecutionFailed();
        }

        uint256 finalStartTokenBalance = startTokenContract.balanceOf(address(this));
        if (finalStartTokenBalance <= startTokenBalanceAtEntry) {
            revert ArbErrors.AtomicArbitrageExecutionFailed();
        }

        uint256 realizedProfit = finalStartTokenBalance - startTokenBalanceAtEntry;
        if (realizedProfit > uint256(type(int256).max)) {
            revert ArbErrors.AtomicArbitrageExecutionFailed();
        }
        cumulativeProfit = int256(realizedProfit);

        if (iterations > 0 && cumulativeProfit > 0 && uint256(cumulativeProfit) >= minProfitToEmit) {
            emit ArbitrageAttempted(
                startToken, intermediateToken, poolB_addr, poolA_addr, totalAmountSwapped, cumulativeProfit, iterations
            );

            uint256 buyPoolIndex = _getPoolIndex(startToken, poolB_addr);
            uint256 sellPoolIndex = _getPoolIndex(startToken, poolA_addr);

            lastTradeData = IDataStorage.TradeData({
                tokenA: startToken,
                tokenB: intermediateToken,
                buyPool: poolB_addr,
                sellPool: poolA_addr,
                buyPoolIndex: buyPoolIndex,
                sellPoolIndex: sellPoolIndex,
                totalAmountSwapped: totalAmountSwapped,
                profit: uint256(cumulativeProfit),
                iterations: iterations,
                timestamp: block.timestamp
            });
        }
        return (true, cumulativeProfit, iterations);
    }

    /// @dev Attempts to convert only an attempt-created intermediate residue
    ///      back into the start token. The caller verifies the exact entry
    ///      balance afterwards and reverts the isolated execution if this does
    ///      not fully clear the residue.
    function _unwindCreatedIntermediate(
        address poolAddress,
        ArbUtils.PoolType poolType,
        address intermediateToken,
        address startToken,
        uint256 amountIn
    ) private returns (bool success) {
        if (amountIn == 0) return true;

        if (poolType == ArbUtils.PoolType.V3 || poolType == ArbUtils.PoolType.PANCAKESWAP_V3) {
            uint256 estimatedImpact = arbLib.estimateImpactBps(poolAddress, poolType, intermediateToken, amountIn);
            if (estimatedImpact > _MAX_IMPACT_BPS) return false;
            uint160 sqrtPriceLimitX96 =
                arbLib.calculateV3SqrtPriceLimitForAmountIn(poolAddress, poolType, intermediateToken, amountIn, 0);
            if (sqrtPriceLimitX96 == 0) return false;
            return _executeSwapInternal_noBalanceCheck(
                poolAddress, poolType, intermediateToken, startToken, amountIn, sqrtPriceLimitX96
            );
        }

        (uint112 reserveIn, uint112 reserveOut,) =
            arbLib._getV2ReservesForTokens(IUniswapV2Pair(poolAddress), intermediateToken, startToken);
        uint256 amountOut = arbLib.getAmountOut(amountIn, reserveIn, reserveOut, _v2FeeForPoolType(poolType));
        if (amountOut == 0) return false;

        return _executeV2FlashSwap(IUniswapV2Pair(poolAddress), startToken, amountOut, intermediateToken, amountIn);
    }

    /// @dev Overrides the shared V2 helper to bind the synchronous callback to
    ///      one exact, registered flash swap. V2 callbacks are delivered to
    ///      the `to` address, so factory validation alone is insufficient.
    function _executeV2FlashSwap(
        IUniswapV2Pair pair,
        address tokenToReceive,
        uint256 amountToReceive,
        address tokenToPay,
        uint256 amountToPay
    ) internal override returns (bool success) {
        address pool = address(pair);
        PoolMeta storage pm = poolMetaByAddr[pool];
        if (
            !pm.exists || (pm.poolType != ArbUtils.PoolType.V2 && pm.poolType != ArbUtils.PoolType.PANCAKESWAP_V2)
                || amountToReceive == 0 || amountToPay == 0
        ) {
            revert ArbErrors.AtomicArbitrageExecutionFailed();
        }

        uint256 amount0Out;
        uint256 amount1Out;
        if (tokenToReceive == pm.token0 && tokenToPay == pm.token1) {
            amount0Out = amountToReceive;
        } else if (tokenToReceive == pm.token1 && tokenToPay == pm.token0) {
            amount1Out = amountToReceive;
        } else {
            revert ArbErrors.AtomicArbitrageExecutionFailed();
        }

        if (activeV2SwapContext != bytes32(0)) {
            revert ArbErrors.V2CallbackContextMismatch();
        }

        activeV2SwapContext = _v2SwapContextHash(pool, pm.poolType, tokenToPay, amountToPay, amount0Out, amount1Out);

        bytes memory data = abi.encode(tokenToPay, amountToPay);
        try pair.swap(amount0Out, amount1Out, address(this), data) {
            success = true;
        } catch {
            success = false;
        }

        // The callback consumes this before making its token transfer. Clear
        // it here too when the pair reverted before invoking its callback.
        delete activeV2SwapContext;
    }

    // ----------------------- Swap helpers (V3/V2) --------------------------
    function _executeSwapInternal_noBalanceCheck(
        address poolAddress,
        ArbUtils.PoolType poolType,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) private returns (bool success) {
        if (tokenIn == tokenOut) revert ArbErrors.SwapTokensMustBeDifferent();
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) {
            return false;
        }

        bool zeroForOne;
        address poolToken0;
        address poolToken1;
        bytes4 callbackSelector;
        {
            PoolMeta storage pm = poolMetaByAddr[poolAddress];
            if (
                !pm.exists || pm.poolType != poolType
                    || (poolType != ArbUtils.PoolType.V3 && poolType != ArbUtils.PoolType.PANCAKESWAP_V3)
            ) {
                revert ArbErrors.AtomicArbitrageExecutionFailed();
            }
            poolToken0 = pm.token0;
            poolToken1 = pm.token1;
            callbackSelector = poolType == ArbUtils.PoolType.V3
                ? UNISWAP_V3_SWAP_CALLBACK_SELECTOR
                : PANCAKESWAP_V3_SWAP_CALLBACK_SELECTOR;
        }

        if (tokenIn == poolToken0) {
            if (tokenOut != poolToken1) {
                revert ArbErrors.SwapMismatchedTokens0To1();
            }
            zeroForOne = true;
        } else if (tokenIn == poolToken1) {
            if (tokenOut != poolToken0) {
                revert ArbErrors.SwapMismatchedTokens1To0();
            }
            zeroForOne = false;
        } else {
            revert ArbErrors.SwapInputTokenNotInPool();
        }

        if (activeV3SwapContext != bytes32(0)) {
            revert ArbErrors.V3CallbackContextMismatch();
        }
        activeV3SwapContext = _v3SwapContextHash(poolAddress, poolType, callbackSelector, tokenIn, zeroForOne, amountIn);

        bytes memory data = abi.encode(tokenIn, address(this), amountIn, poolAddress);

        // Assume approvals are set up front; avoid allowance SLOAD and branch

        if (poolType == ArbUtils.PoolType.V3) {
            try IUniswapV3Pool(poolAddress)
                .swap(address(this), zeroForOne, int256(amountIn), sqrtPriceLimitX96, data) returns (
                int256 amount0, int256 amount1
            ) {
                // A successful canonical exact-input swap must have consumed
                // the one-shot capability through its synchronous callback.
                if (activeV3SwapContext == bytes32(0)) {
                    emit SwapExecuted(
                        poolAddress, tokenIn, tokenOut, amountIn, uint256(zeroForOne ? -amount1 : -amount0)
                    );
                    success = true;
                }
            } catch {
                success = false;
            }
        } else if (poolType == ArbUtils.PoolType.PANCAKESWAP_V3) {
            try IPancakeV3Pool(poolAddress)
                .swap(address(this), zeroForOne, int256(amountIn), sqrtPriceLimitX96, data) returns (
                int256 amount0, int256 amount1
            ) {
                if (activeV3SwapContext == bytes32(0)) {
                    emit SwapExecuted(
                        poolAddress, tokenIn, tokenOut, amountIn, uint256(zeroForOne ? -amount1 : -amount0)
                    );
                    success = true;
                }
            } catch {
                success = false;
            }
        }

        // The callback consumes this on success. Clear it after a pool revert
        // or a non-callback return so no stale capability survives the attempt.
        delete activeV3SwapContext;
    }

    function _getPoolIndex(address token, address poolAddr) private view returns (uint256) {
        ArbUtils.PoolInfo[] storage pools = tokenPools[token];
        uint256 poolCount = pools.length;
        for (uint256 i; i < poolCount;) {
            if (pools[i].poolAddress == poolAddr) return i;
            unchecked {
                ++i;
            }
        }
        return type(uint256).max;
    }

    function _v2FeeForPoolType(ArbUtils.PoolType poolType) private pure returns (uint24) {
        return poolType == ArbUtils.PoolType.PANCAKESWAP_V2 ? PANCAKESWAP_V2_POOL_FEE_PPM : V2_POOL_FEE_PPM;
    }
}
