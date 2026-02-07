// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// A streamlined arbitrage bot that inlines the worker logic.
// It avoids the CREATE/SELFDESTRUCT pattern to reduce gas.

import "./ArbUtils.sol";
import "./ArbitrageLogic.sol";
import {ArbErrors} from "./Errors.sol";

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    IUniswapV3Pool
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IPancakeV3Pool} from "./interfaces/IPancakeV3Pool.sol";
import {IDataStorage} from "./interfaces/IDataStorage.sol";

/// @title ArbHook
/// @notice Single-contract version that embeds the iterative worker logic and skips
///         dynamic worker deployment. Uses the same pool-book, pricing and swap logic
///         from the previous WorkerLogic implementation.
contract ArbHook is BaseHook, ArbUtils, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct PoolMeta {
        address token0;
        address token1;
        uint24 fee;
        PoolType poolType;
        bool exists;
    }

    // Quick lookup for callbacks and validation without extra external calls
    mapping(address => PoolMeta) private poolMetaByAddr;

    // Cache last “best” selection to bias discovery and reduce recompute
    mapping(bytes32 => address) private lastBestBuyPoolForPair;
    mapping(bytes32 => address) private lastBestSellPoolForPair;

    // Cache token decimals to make _minChunk cheaper
    mapping(address => uint8) private cachedTokenDecimals;
    // Only emit/store trades when profit ≥ this (in tokenA units)
    uint256 public minProfitToEmit;
    // Default max iterations when attempting arb via hook callbacks (0 disables hook execution)
    uint256 public hookMaxIterations;

    // Well-known tokens used by unwind heuristics
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant WETH = 0x4200000000000000000000000000000000000006;

    // Trusted factories for callback validation
    IUniswapV2Factory private constant V2_FACTORY =
        IUniswapV2Factory(0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6);
    IUniswapV2Factory private constant PANCAKESWAP_V2_FACTORY =
        IUniswapV2Factory(0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E);

    event ArbitrageAttempted(
        address indexed tokenA,
        address indexed tokenB,
        address indexed buyPool,
        address sellPool,
        uint256 totalAmountSwapped,
        int256 cumulativeProfit,
        uint256 iterations
    );

    event AttemptAllFailed(bytes revertData);
    event PairExecutionFailed(
        address tokenA,
        address tokenB,
        address buyPool,
        address sellPool,
        bytes revertData
    );

    event PriceDiscoveryResult(
        address indexed tokenA,
        address indexed tokenB,
        address indexed bestBuyPool,
        address bestSellPool,
        uint256 buyPrice,
        uint256 sellPrice
    );

    event HookAttemptAll(
        uint256 iterations,
        bool callSuccess,
        bool tradeProfitable
    );

    function _afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        uint256 iterations = hookMaxIterations;
        if (iterations > 0) {
            _attemptAllViaSelfCall(iterations);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function _attemptAllViaSelfCall(
        uint256 iterations
    ) internal returns (bool) {
        (bool successCall, bytes memory returndata) = address(this).call(
            abi.encodeWithSelector(this.attemptAllInternal.selector, iterations)
        );

        bool tradeSuccess = false;
        if (!successCall) {
            emit AttemptAllFailed(returndata);
        } else {
            tradeSuccess = abi.decode(returndata, (bool));
        }

        emit HookAttemptAll(iterations, successCall, tradeSuccess);
        return successCall && tradeSuccess;
    }

    function attemptAll(uint256 iterations) external onlyOwner returns (bool) {
        return _attemptAllViaSelfCall(iterations);
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function validateHookAddress(BaseHook) internal pure override {}

    constructor(
        IPoolManager _poolManager,
        address initialOwner,
        address _arbLib,
        address _dataStorage
    ) BaseHook(_poolManager) Ownable(initialOwner) {
        require(address(_poolManager) != address(0), "poolManager=0");
        require(_arbLib != address(0), "arbLib=0");
        require(_dataStorage != address(0), "dataStorage=0");
        arbLib = ArbitrageLogic(_arbLib);
        dataStorage = IDataStorage(_dataStorage);
        hookMaxIterations = 2;
    }

    // ------------------------------- Admin ---------------------------------
    function setDataStorage(address _dataStorage) external onlyOwner {
        require(_dataStorage != address(0), "dataStorage=0");
        dataStorage = IDataStorage(_dataStorage);
    }

    function setMinSpreadBps(uint16 _minSpreadBps) external onlyOwner {
        minSpreadBps = _minSpreadBps;
    }

    function setChunkSpreadConsumptionBps(
        uint16 _chunkSpreadConsumptionBps
    ) external onlyOwner {
        CHUNK_SPREAD_CONSUMPTION_BPS = _chunkSpreadConsumptionBps;
    }

    function setMaxImpactBps(uint256 _maxImpactBps) external onlyOwner {
        _MAX_IMPACT_BPS = _maxImpactBps;
    }

    function setMinProfitToEmit(uint256 newMinProfit) external onlyOwner {
        minProfitToEmit = newMinProfit;
    }

    function setHookMaxIterations(uint256 newMaxIterations) external onlyOwner {
        hookMaxIterations = newMaxIterations;
    }

    // ------------------------- Pool-book API -------------------------------
    function addPools(
        address token,
        address[] memory poolAddresses,
        uint24[] memory fees,
        ArbUtils.PoolType[] memory poolTypes
    ) external onlyOwner nonReentrant {
        _addPools(token, poolAddresses, fees, poolTypes);
        // Populate pool meta for callbacks and cheaper checks
        for (uint256 i = 0; i < poolAddresses.length; i++) {
            address p = poolAddresses[i];
            PoolMeta storage m = poolMetaByAddr[p];
            if (poolTypes[i] == ArbUtils.PoolType.V3) {
                IUniswapV3Pool vp = IUniswapV3Pool(p);
                m.token0 = vp.token0();
                m.token1 = vp.token1();
                m.fee = vp.fee();
                m.poolType = ArbUtils.PoolType.V3;
                m.exists = true;
            } else if (poolTypes[i] == ArbUtils.PoolType.PANCAKESWAP_V3) {
                IPancakeV3Pool vp = IPancakeV3Pool(p);
                m.token0 = vp.token0();
                m.token1 = vp.token1();
                m.fee = vp.fee();
                m.poolType = ArbUtils.PoolType.PANCAKESWAP_V3;
                m.exists = true;
            } else if (poolTypes[i] == ArbUtils.PoolType.V2) {
                IUniswapV2Pair vp = IUniswapV2Pair(p);
                m.token0 = vp.token0();
                m.token1 = vp.token1();
                m.fee = fees[i];
                m.poolType = ArbUtils.PoolType.V2;
                m.exists = true;
            } else if (poolTypes[i] == ArbUtils.PoolType.PANCAKESWAP_V2) {
                IUniswapV2Pair vp = IUniswapV2Pair(p);
                m.token0 = vp.token0();
                m.token1 = vp.token1();
                m.fee = fees[i];
                m.poolType = ArbUtils.PoolType.PANCAKESWAP_V2;
                m.exists = true;
            }

            // Cache decimals for both tokens to make _minChunk cheaper later
            if (m.token0 != address(0) && cachedTokenDecimals[m.token0] == 0) {
                try IERC20Metadata(m.token0).decimals() returns (uint8 d0) {
                    cachedTokenDecimals[m.token0] = d0 == 0 ? 18 : d0;
                } catch {
                    cachedTokenDecimals[m.token0] = 18;
                }
            }
            if (m.token1 != address(0) && cachedTokenDecimals[m.token1] == 0) {
                try IERC20Metadata(m.token1).decimals() returns (uint8 d1) {
                    cachedTokenDecimals[m.token1] = d1 == 0 ? 18 : d1;
                } catch {
                    cachedTokenDecimals[m.token1] = 18;
                }
            }
        }
    }

    function removePool(
        address token,
        uint256 idx
    ) external onlyOwner nonReentrant {
        // Clear meta before removal
        if (idx < tokenPools[token].length) {
            address p = tokenPools[token][idx].poolAddress;
            delete poolMetaByAddr[p];
        }
        _removePool(token, idx);
    }

    function resetTokenPools(address token) external onlyOwner nonReentrant {
        // Clear metas for this token
        ArbUtils.PoolInfo[] storage pools = tokenPools[token];
        for (uint256 i = 0; i < pools.length; i++) {
            delete poolMetaByAddr[pools[i].poolAddress];
        }
        _resetTokenPools(token);
    }

    function resetAllPools() external onlyOwner nonReentrant {
        // Clear metas for all tokens
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address t = supportedTokens[i];
            ArbUtils.PoolInfo[] storage pools = tokenPools[t];
            for (uint256 j = 0; j < pools.length; j++) {
                delete poolMetaByAddr[pools[j].poolAddress];
            }
        }
        _resetAllPools();
    }

    // Override to use cached decimals instead of external call each time
    function _minChunk(address token) internal view override returns (uint256) {
        uint8 d = cachedTokenDecimals[token];
        if (d == 0) {
            // Not cached yet: fallback read (view) – tests will warm this on first add
            try IERC20Metadata(token).decimals() returns (uint8 dx) {
                d = dx;
            } catch {
                d = 18; // assume 18 if unknown
            }
        }
        return d > 4 ? 10 ** (d - 4) : 1;
    }

    function getPoolsForToken(
        address token
    ) external view returns (ArbUtils.PoolInfo[] memory) {
        return tokenPools[token];
    }

    function getSupportedTokenCount() external view returns (uint256) {
        return supportedTokens.length;
    }

    function getAllSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    function approvePools(
        address tokenAddress,
        address[] calldata poolAddresses,
        uint256 amount
    ) external onlyOwner nonReentrant {
        for (uint256 i = 0; i < poolAddresses.length; i++) {
            IERC20(tokenAddress).approve(poolAddresses[i], 0);
            IERC20(tokenAddress).approve(poolAddresses[i], amount);
        }
    }

    // -------------------------- Core entrypoint ----------------------------
    /// @notice Attempt arbitrage across all configured base/counter pairs.
    ///         Streamlined to avoid blob decode and worker deployment.
    ///         Uses low-level call to prevent external transaction reverts.
    /// @notice Internal implementation of attemptAll that can revert
    function attemptAllInternal(
        uint256 maxIterations
    ) external returns (bool success) {
        require(msg.sender == address(this), "Only self");
        lastExecutionProfit = 0; // reset mailbox

        int256 totalProfit = 0;
        uint256 baseCount = supportedTokens.length;
        for (uint256 i = 0; i < baseCount; ++i) {
            address baseToken = supportedTokens[i];
            address[] storage counterTokens = baseCounterList[baseToken];
            uint256 counterCount = counterTokens.length;

            for (uint256 j = 0; j < counterCount; ++j) {
                address counterToken = counterTokens[j];
                (int256 profit, ) = _runPair(
                    baseToken,
                    counterToken,
                    maxIterations
                );
                if (profit > 0) {
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
        if (tradeWasProfitable && address(dataStorage) != address(0)) {
            dataStorage.storeTradeData(lastTradeData);
        }
        return tradeWasProfitable;
    }

    // ---------------------------- Pair runner ------------------------------
    struct LoopState {
        bytes32[10] tried;
        uint8 triedCount;
        uint8 attempts;
        uint8 sellFailsForBuy;
        address skipSellPool;
        address skipBuyPool;
        address lastBuyPool;
    }

    function _runPair(
        address tokenA,
        address tokenB,
        uint256 maxIter
    ) internal returns (int256 cumulativeProfit, uint256 iterations) {
        LoopState memory state;
        state.triedCount = 0;
        state.attempts = 0;
        state.sellFailsForBuy = 0;
        state.skipSellPool = address(0);
        state.skipBuyPool = address(0);
        state.lastBuyPool = address(0);

        bytes32 pairKey = _getPairKey(tokenA, tokenB);
        FailedAttempt memory lastFail = lastFailedAttemptForPair[pairKey];

        if (lastFail.buyPool != address(0)) {
            (
                ArbUtils.PoolInfo memory buyPoolInfo,
                bool buyPoolFound
            ) = _findPoolInBook(tokenA, lastFail.buyPool);
            (
                ArbUtils.PoolInfo memory sellPoolInfo,
                bool sellPoolFound
            ) = _findPoolInBook(tokenA, lastFail.sellPool);

            if (buyPoolFound && sellPoolFound) {
                (uint256 currentBuyPrice, , bool buyPriceSuccess) = arbLib
                    ._getSinglePoolPrices(tokenA, tokenB, buyPoolInfo);
                (, uint256 currentSellPrice, bool sellPriceSuccess) = arbLib
                    ._getSinglePoolPrices(tokenA, tokenB, sellPoolInfo);

                if (buyPriceSuccess && sellPriceSuccess) {
                    uint128 qBuyNow = arbLib.quantise(currentBuyPrice);
                    uint128 qSellNow = arbLib.quantise(currentSellPrice);
                    if (
                        qBuyNow == lastFail.qBuy && qSellNow == lastFail.qSell
                    ) {
                        return (0, 0); // Prices unchanged, skip
                    }
                }
            }
        }

        while (state.attempts < 2) {
            (
                address buyPool,
                address sellPool,
                uint256 buyPrice,
                uint256 sellPrice,
                ArbUtils.PoolType buyPoolType,
                ArbUtils.PoolType sellPoolType
            ) = findBestPools(
                    tokenA,
                    tokenB,
                    state.skipBuyPool,
                    state.skipSellPool
                );

            if (buyPool == address(0)) return (0, 0);
            if (buyPool == sellPool) {
                ++state.attempts;
                state.skipSellPool = sellPool;
                continue;
            }

            uint128 qBuy = arbLib.quantise(buyPrice);
            uint128 qSell = arbLib.quantise(sellPrice);
            bytes32 quoteKey = arbLib.quoteKey(tokenA, tokenB, qBuy, qSell);

            bool alreadyTried = false;
            for (uint8 k = 0; k < state.triedCount; ) {
                if (state.tried[k] == quoteKey) {
                    alreadyTried = true;
                    break;
                }
                unchecked {
                    ++k;
                }
            }
            if (alreadyTried) {
                unchecked {
                    ++state.attempts;
                }
                state.skipSellPool = sellPool;
                continue;
            }

            FailedQuote memory fq = lastFailedQuote[quoteKey];
            if (fq.qBuy == qBuy && fq.qSell == qSell) {
                ++state.attempts;
                state.skipSellPool = sellPool;
                if (buyPool == state.lastBuyPool) {
                    if (++state.sellFailsForBuy >= 2) {
                        state.skipBuyPool = buyPool;
                        state.sellFailsForBuy = 0;
                        state.lastBuyPool = address(0);
                    }
                } else {
                    state.lastBuyPool = buyPool;
                    state.sellFailsForBuy = 1;
                }
                continue;
            }

            // Use low-level call to prevent pair execution from reverting the entire attemptAll
            (bool successCall, bytes memory returndata) = address(this).call(
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
                emit PairExecutionFailed(
                    tokenA,
                    tokenB,
                    buyPool,
                    sellPool,
                    returndata
                );
                // Mark as tried to avoid infinite loops
                if (state.triedCount < 5) {
                    state.tried[state.triedCount] = quoteKey;
                    state.triedCount++;
                }
                state.attempts++;
                continue;
            }

            (bool tradeSuccess, int256 profit, uint256 iters) = abi.decode(
                returndata,
                (bool, int256, uint256)
            );

            cumulativeProfit += profit;
            iterations += iters;

            if (tradeSuccess && profit > 0) {
                delete lastFailedQuote[quoteKey];
                return (cumulativeProfit, iterations);
            }

            lastFailedQuote[quoteKey] = FailedQuote(qBuy, qSell);
            lastFailedAttemptForPair[pairKey] = FailedAttempt(
                buyPool,
                sellPool,
                qBuy,
                qSell
            );

            if (state.triedCount < 5) {
                state.tried[state.triedCount] = quoteKey;
                unchecked {
                    ++state.triedCount;
                }
            }
            unchecked {
                ++state.attempts;
            }
            state.skipSellPool = sellPool;
            if (buyPool == state.lastBuyPool) {
                if (++state.sellFailsForBuy >= 2) {
                    state.skipBuyPool = buyPool;
                    state.sellFailsForBuy = 0;
                    state.lastBuyPool = address(0);
                }
            } else {
                state.lastBuyPool = buyPool;
                state.sellFailsForBuy = 1;
            }
        }
        return (cumulativeProfit, iterations);
    }

    // ------------------------- Pool discovery helper -----------------------
    function findBestPools(
        address tokenA,
        address tokenB,
        address skipBuyPool,
        address skipSellPool
    )
        internal
        returns (
            address bestBuyPool,
            address bestSellPool,
            uint256 bestBuyPrice,
            uint256 bestSellPrice,
            ArbUtils.PoolType bestBuyPoolType,
            ArbUtils.PoolType bestSellPoolType
        )
    {
        // Iterate storage directly to avoid copying the entire pool array to memory
        ArbUtils.PoolInfo[] storage pools = tokenPools[tokenA];
        uint256 n = pools.length;
        if (n == 0) {
            return (
                address(0),
                address(0),
                0,
                0,
                ArbUtils.PoolType.V3,
                ArbUtils.PoolType.V3
            );
        }

        bestBuyPrice = type(uint256).max;
        bestSellPrice = 0;

        for (uint256 i = 0; i < n; ) {
            ArbUtils.PoolInfo storage ps = pools[i];
            address pa = ps.poolAddress;
            // Skip invalid or skipped pools
            if (pa != address(0) && pa != skipBuyPool && pa != skipSellPool) {
                // Check pair matches
                if (
                    (ps.token0 == tokenA && ps.token1 == tokenB) ||
                    (ps.token0 == tokenB && ps.token1 == tokenA)
                ) {
                    // Single-pool price fetch (includes slot0/reserves checks)
                    ArbUtils.PoolInfo memory pm = ps; // copy one struct to memory
                    (uint256 bPrice, uint256 sPrice, bool ok) = arbLib
                        ._getSinglePoolPrices(tokenA, tokenB, pm);
                    if (ok) {
                        if (bPrice < bestBuyPrice) {
                            bestBuyPrice = bPrice;
                            bestBuyPool = pa;
                            bestBuyPoolType = ps.poolType;
                        }
                        if (sPrice > bestSellPrice) {
                            bestSellPrice = sPrice;
                            bestSellPool = pa;
                            bestSellPoolType = ps.poolType;
                        }
                    }
                }
            }
            unchecked {
                ++i;
            }
        }

        if (
            bestBuyPool == address(0) ||
            bestSellPool == address(0) ||
            bestBuyPool == bestSellPool ||
            bestSellPrice <= bestBuyPrice
        ) {
            return (
                address(0),
                address(0),
                0,
                0,
                ArbUtils.PoolType.V3,
                ArbUtils.PoolType.V3
            );
        }

        // Cache winners for the pair to bias subsequent discovery
        bytes32 pKeyStore = _getPairKey(tokenA, tokenB);
        lastBestBuyPoolForPair[pKeyStore] = bestBuyPool;
        lastBestSellPoolForPair[pKeyStore] = bestSellPool;
        return (
            bestBuyPool,
            bestSellPool,
            bestBuyPrice,
            bestSellPrice,
            bestBuyPoolType,
            bestSellPoolType
        );
    }

    // ---------------------------- Core executor ----------------------------
    function executeIterativeArb(
        address poolA_addr,
        address poolB_addr,
        address startToken,
        address intermediateToken,
        uint256 maxIterations,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType
    )
        public
        returns (bool success, int256 cumulativeProfit, uint256 iterations)
    {
        if (msg.sender != address(this)) revert ArbErrors.WrapperOnlySelf();
        if (maxIterations == 0) return (false, 0, 0);
        if (poolA_addr == poolB_addr) return (false, 0, 0);

        IERC20 startTokenContract = IERC20(startToken);
        IERC20 intermediateTokenContract = IERC20(intermediateToken);
        uint256 minChunkStartToken = _minChunk(startToken);
        int256 minCumulativeProfit = int256(minChunkStartToken) / 10;

        bool isPoolAV3 = (poolAType == ArbUtils.PoolType.V3 ||
            poolAType == ArbUtils.PoolType.PANCAKESWAP_V3);
        bool isPoolBV3 = (poolBType == ArbUtils.PoolType.V3 ||
            poolBType == ArbUtils.PoolType.PANCAKESWAP_V3);

        int24 initialAbsSpreadForThisArbOpportunity = 0;

        if (isPoolAV3 && isPoolBV3) {
            IUniswapV3Pool pA_v3_check = IUniswapV3Pool(poolA_addr);
            IUniswapV3Pool pB_v3_check = IUniswapV3Pool(poolB_addr);
            int24 initialTickA_check;
            int24 initialTickB_check;
            address initialTokenA0_check;
            if (poolAType == ArbUtils.PoolType.V3) {
                try pA_v3_check.slot0() returns (
                    uint160,
                    int24 tA,
                    uint16,
                    uint16,
                    uint16,
                    uint8,
                    bool
                ) {
                    initialTickA_check = tA;
                } catch {
                    return (false, 0, 0);
                }
            } else {
                try IPancakeV3Pool(poolA_addr).slot0() returns (
                    uint160,
                    int24 tA,
                    uint16,
                    uint16,
                    uint16,
                    uint32,
                    bool
                ) {
                    initialTickA_check = tA;
                } catch {
                    return (false, 0, 0);
                }
            }

            if (poolBType == ArbUtils.PoolType.V3) {
                try pB_v3_check.slot0() returns (
                    uint160,
                    int24 tB,
                    uint16,
                    uint16,
                    uint16,
                    uint8,
                    bool
                ) {
                    initialTickB_check = tB;
                } catch {
                    return (false, 0, 0);
                }
            } else {
                try IPancakeV3Pool(poolB_addr).slot0() returns (
                    uint160,
                    int24 tB,
                    uint16,
                    uint16,
                    uint16,
                    uint32,
                    bool
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
            int24 initialSignedSpread_check = (initialTokenA0_check ==
                startToken)
                ? (initialTickA_check - initialTickB_check)
                : (initialTickB_check - initialTickA_check);
            initialAbsSpreadForThisArbOpportunity = initialSignedSpread_check >=
                0
                ? initialSignedSpread_check
                : -initialSignedSpread_check;

            if (
                initialAbsSpreadForThisArbOpportunity <
                int24(uint24(minSpreadBps))
            ) {
                return (true, 0, 0);
            }
        }

        uint256 totalAmountSwapped = 0;
        for (uint256 i = 0; i < maxIterations; ) {
            uint256 balanceBeforeIteration = startTokenContract.balanceOf(
                address(this)
            );

            uint256 chunkToSwap = 0;
            uint160 sqrtPriceLimitA_v3 = 0;
            uint160 sqrtPriceLimitB_v3 = 0;

            if (isPoolAV3 && isPoolBV3) {
                ArbitrageLogic.IterationConfig memory iterConfig;
                iterConfig.minSpreadBps = minSpreadBps;
                iterConfig
                    .chunkSpreadConsumptionBps = CHUNK_SPREAD_CONSUMPTION_BPS;
                iterConfig.bpsDivisor = BPS_DIVISOR;
                iterConfig.maxImpactBps = _MAX_IMPACT_BPS;
                iterConfig.minChunkForStartToken = minChunkStartToken;
                iterConfig.currentStartTokenBalance = balanceBeforeIteration;
                iterConfig
                    .initialAbsSpread = initialAbsSpreadForThisArbOpportunity;

                ArbitrageLogic.V3SwapParams memory v3Params = arbLib
                    .getV3SwapParameters(
                        poolA_addr,
                        poolB_addr,
                        startToken,
                        intermediateToken,
                        iterConfig,
                        poolAType,
                        poolBType
                    );

                if (!v3Params.shouldContinue) {
                    break;
                }

                chunkToSwap = arbLib.findBestV3Chunk(
                    v3Params,
                    iterConfig.minChunkForStartToken
                );

                if (chunkToSwap == 0) {
                    break;
                }

                sqrtPriceLimitA_v3 = v3Params.sqrtPriceLimitA;
                sqrtPriceLimitB_v3 = v3Params.sqrtPriceLimitB;
            } else if (!isPoolAV3 && !isPoolBV3) {
                ArbitrageLogic.V2TradeParams memory v2Params = arbLib
                    .calculateV2TradeParams(
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
                    uint8 v2Halvings = 0;
                    uint256 testV2Chunk = initialChunkForV2Halving;
                    bool profitableV2ChunkFound = false;
                    int256 lastEstPLFullV2Halving = 0;

                    (uint112 rA_s, uint112 rA_i, ) = arbLib
                        ._getV2ReservesForTokens(
                            IUniswapV2Pair(poolA_addr),
                            startToken,
                            intermediateToken
                        );
                    (uint112 rB_i, uint112 rB_s, ) = arbLib
                        ._getV2ReservesForTokens(
                            IUniswapV2Pair(poolB_addr),
                            intermediateToken,
                            startToken
                        );

                    if (rA_s > 0 && rA_i > 0 && rB_i > 0 && rB_s > 0) {
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
                                lastEstPLFullV2Halving > 0 &&
                                cumulativeProfit + lastEstPLFullV2Halving >=
                                minCumulativeProfit
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
                uint256 currentBal = balanceBeforeIteration;
                if (currentBal == 0) break;

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

                if (
                    poolAType == ArbUtils.PoolType.V3 ||
                    poolAType == ArbUtils.PoolType.PANCAKESWAP_V3
                ) {
                    address cachedT0A = poolMetaByAddr[poolA_addr].token0;
                    bool zeroForOne_V3A = cachedT0A == startToken;
                    sqrtPriceLimitA_v3 = zeroForOne_V3A
                        ? uint160(4295128739) /* TickMath.MIN_SQRT_RATIO */ + 1
                        : uint160(
                            1461446703485210103287273052203988822378723970342
                        ) /* MAX */ - 1;
                }
            }

            if (chunkToSwap == 0) break;

            uint256 intermediateBalanceBefore = intermediateTokenContract
                .balanceOf(address(this));
            uint256 intermediateReceived = 0;

            bool swap1Success = false;
            if (
                poolAType == ArbUtils.PoolType.V3 ||
                poolAType == ArbUtils.PoolType.PANCAKESWAP_V3
            ) {
                swap1Success = _executeSwapInternal_noBalanceCheck(
                    poolA_addr,
                    poolAType,
                    startToken,
                    intermediateToken,
                    chunkToSwap,
                    sqrtPriceLimitA_v3
                );
            } else {
                (uint112 rA_start, uint112 rA_interm, ) = arbLib
                    ._getV2ReservesForTokens(
                        IUniswapV2Pair(poolA_addr),
                        startToken,
                        intermediateToken
                    );
                uint256 amountToReceive = arbLib.getAmountOut(
                    chunkToSwap,
                    rA_start,
                    rA_interm,
                    _v2FeeForPoolType(poolAType)
                );
                if (
                    poolBType == ArbUtils.PoolType.V3 ||
                    poolBType == ArbUtils.PoolType.PANCAKESWAP_V3
                ) {
                    uint256 estimatedImpactB = arbLib.estimateImpactBps(
                        poolB_addr,
                        intermediateToken,
                        amountToReceive
                    );
                    if (estimatedImpactB > _MAX_IMPACT_BPS) break;
                }
                swap1Success = _executeV2FlashSwap(
                    IUniswapV2Pair(poolA_addr),
                    intermediateToken,
                    amountToReceive,
                    startToken,
                    chunkToSwap
                );
            }
            if (!swap1Success) {
                break;
            }

            uint256 intermediateBalanceAfter = intermediateTokenContract
                .balanceOf(address(this));
            if (intermediateBalanceAfter > intermediateBalanceBefore) {
                intermediateReceived =
                    intermediateBalanceAfter -
                    intermediateBalanceBefore;
            } else {
                intermediateReceived = 0;
            }

            bool swap2Success = false;
            if (
                poolBType == ArbUtils.PoolType.V3 ||
                poolBType == ArbUtils.PoolType.PANCAKESWAP_V3
            ) {
                uint160 actualSqrtPriceLimitB_v3 = sqrtPriceLimitB_v3; // V3-V3 default
                if (
                    (poolAType == ArbUtils.PoolType.V2 ||
                        poolAType == ArbUtils.PoolType.PANCAKESWAP_V2) &&
                    (poolBType == ArbUtils.PoolType.V3 ||
                        poolBType == ArbUtils.PoolType.PANCAKESWAP_V3)
                ) {
                    actualSqrtPriceLimitB_v3 = arbLib
                        .calculateV3SqrtPriceLimitForAmountIn(
                            IUniswapV3Pool(poolB_addr),
                            intermediateToken,
                            intermediateReceived,
                            50
                        );
                }
                swap2Success = _executeSwapInternal_noBalanceCheck(
                    poolB_addr,
                    poolBType,
                    intermediateToken,
                    startToken,
                    intermediateReceived,
                    actualSqrtPriceLimitB_v3
                );
            } else {
                (uint112 rB_interm, uint112 rB_start, ) = arbLib
                    ._getV2ReservesForTokens(
                        IUniswapV2Pair(poolB_addr),
                        intermediateToken,
                        startToken
                    );
                uint256 amountToReceive2 = arbLib.getAmountOut(
                    intermediateReceived,
                    rB_interm,
                    rB_start,
                    _v2FeeForPoolType(poolBType)
                );
                swap2Success = _executeV2FlashSwap(
                    IUniswapV2Pair(poolB_addr),
                    startToken,
                    amountToReceive2,
                    intermediateToken,
                    intermediateReceived
                );
            }
            if (!swap2Success) {
                break;
            }

            uint256 balanceAfterIteration = startTokenContract.balanceOf(
                address(this)
            );
            int256 currentIterationProfit = int256(balanceAfterIteration) -
                int256(balanceBeforeIteration);

            cumulativeProfit += currentIterationProfit;
            totalAmountSwapped += chunkToSwap;

            unchecked {
                iterations++;
            }

            if (currentIterationProfit <= 0) break;
            unchecked {
                ++i;
            }
        }
        uint256 balanceBeforeUnwind = IERC20(startToken).balanceOf(
            address(this)
        );

        uint256 remainingInterm = IERC20(intermediateToken).balanceOf(
            address(this)
        );
        if (
            remainingInterm > 0 &&
            intermediateToken != USDC &&
            intermediateToken != WETH &&
            cumulativeProfit > 0
        ) {
            uint160 unwindLimitB = 0;
            if (
                poolBType == ArbUtils.PoolType.V3 ||
                poolBType == ArbUtils.PoolType.PANCAKESWAP_V3
            ) {
                address cachedT0B = poolMetaByAddr[poolB_addr].token0;
                bool zeroForOneUnwind = cachedT0B == intermediateToken;
                unwindLimitB = zeroForOneUnwind
                    ? uint160(4295128739) + 1
                    : uint160(
                        1461446703485210103287273052203988822378723970342
                    ) - 1;
            }
            _executeSwapInternal_noBalanceCheck(
                poolB_addr,
                poolBType,
                intermediateToken,
                startToken,
                remainingInterm,
                unwindLimitB
            );

            remainingInterm = IERC20(intermediateToken).balanceOf(
                address(this)
            );
            if (remainingInterm > 0) {
                uint160 unwindLimitA = 0;
                if (
                    poolAType == ArbUtils.PoolType.V3 ||
                    poolAType == ArbUtils.PoolType.PANCAKESWAP_V3
                ) {
                    address cachedT0A2 = poolMetaByAddr[poolA_addr].token0;
                    bool zeroForOneUnwindA = cachedT0A2 == intermediateToken;
                    unwindLimitA = zeroForOneUnwindA
                        ? uint160(4295128739) + 1
                        : uint160(
                            1461446703485210103287273052203988822378723970342
                        ) - 1;
                }
                _executeSwapInternal_noBalanceCheck(
                    poolA_addr,
                    poolAType,
                    intermediateToken,
                    startToken,
                    remainingInterm,
                    unwindLimitA
                );
            }

            remainingInterm = IERC20(intermediateToken).balanceOf(
                address(this)
            );
            if (remainingInterm > 0) {
                revert("Unwind failed, tokens stuck");
            }
        }

        uint256 balanceAfterUnwind = IERC20(startToken).balanceOf(
            address(this)
        );
        if (balanceAfterUnwind != balanceBeforeUnwind) {
            int256 unwindProfit = int256(balanceAfterUnwind) -
                int256(balanceBeforeUnwind);
            cumulativeProfit += unwindProfit;
        }

        if (
            iterations > 0 &&
            cumulativeProfit > 0 &&
            uint256(cumulativeProfit) >= minProfitToEmit
        ) {
            emit ArbitrageAttempted(
                startToken,
                intermediateToken,
                poolB_addr,
                poolA_addr,
                totalAmountSwapped,
                cumulativeProfit,
                iterations
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

    // Inlined version of executeIterativeArb to avoid external call overhead
    function _executeIterativeArbInline(
        address poolA_addr,
        address poolB_addr,
        address startToken,
        address intermediateToken,
        uint256 maxIterations,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType
    )
        internal
        returns (bool success, int256 cumulativeProfit, uint256 iterations)
    {
        (success, cumulativeProfit, iterations) = executeIterativeArb(
            poolA_addr,
            poolB_addr,
            startToken,
            intermediateToken,
            maxIterations,
            poolAType,
            poolBType
        );
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

        bool zeroForOne;
        address poolToken0;
        address poolToken1;
        {
            PoolMeta storage pm = poolMetaByAddr[poolAddress];
            if (pm.exists) {
                poolToken0 = pm.token0;
                poolToken1 = pm.token1;
            } else {
                IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
                poolToken0 = pool.token0();
                poolToken1 = pool.token1();
            }
        }

        if (tokenIn == poolToken0) {
            if (tokenOut != poolToken1)
                revert ArbErrors.SwapMismatchedTokens0To1();
            zeroForOne = true;
        } else if (tokenIn == poolToken1) {
            if (tokenOut != poolToken0)
                revert ArbErrors.SwapMismatchedTokens1To0();
            zeroForOne = false;
        } else {
            revert ArbErrors.SwapInputTokenNotInPool();
        }

        bytes memory data = abi.encode(
            tokenIn,
            address(this),
            amountIn,
            poolAddress
        );

        // Assume approvals are set up front; avoid allowance SLOAD and branch

        if (poolType == ArbUtils.PoolType.V3) {
            try
                IUniswapV3Pool(poolAddress).swap(
                    address(this),
                    zeroForOne,
                    int256(amountIn),
                    sqrtPriceLimitX96,
                    data
                )
            returns (int256 amount0, int256 amount1) {
                emit SwapExecuted(
                    poolAddress,
                    tokenIn,
                    tokenOut,
                    amountIn,
                    uint256(zeroForOne ? -amount1 : -amount0)
                );
                success = true;
            } catch {
                success = false;
            }
        } else if (poolType == ArbUtils.PoolType.PANCAKESWAP_V3) {
            try
                IPancakeV3Pool(poolAddress).swap(
                    address(this),
                    zeroForOne,
                    int256(amountIn),
                    sqrtPriceLimitX96,
                    data
                )
            returns (int256 amount0, int256 amount1) {
                emit SwapExecuted(
                    poolAddress,
                    tokenIn,
                    tokenOut,
                    amountIn,
                    uint256(zeroForOne ? -amount1 : -amount0)
                );
                success = true;
            } catch {
                success = false;
            }
        }
    }

    // ----------------------------- Callbacks -------------------------------
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        _v3SwapCallbackLogic(amount0Delta, amount1Delta, data);
    }

    function pancakeV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        _v3SwapCallbackLogic(amount0Delta, amount1Delta, data);
    }

    function _v3SwapCallbackLogic(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) internal {
        (
            address decodedTokenIn,
            address decodedCaller,
            ,
            address expectedPool
        ) = abi.decode(data, (address, address, uint256, address));

        if (decodedCaller != address(this)) {
            revert ArbErrors.CallbackCallerMismatch(
                decodedCaller,
                address(this)
            );
        }
        if (msg.sender == tx.origin) {
            revert ArbErrors.CallbackCallerIsEOA();
        }
        if (msg.sender != expectedPool) {
            revert ArbErrors.CallbackUnexpectedPool(msg.sender, expectedPool);
        }

        address pool = msg.sender;
        address token0;
        address token1;

        // Use cached meta instead of external calls and factory checks
        PoolMeta storage pm = poolMetaByAddr[pool];
        if (!pm.exists)
            revert ArbErrors.CallbackUnexpectedPool(pool, expectedPool);
        token0 = pm.token0;
        token1 = pm.token1;

        if (decodedTokenIn != token0 && decodedTokenIn != token1) {
            revert ArbErrors.CallbackDecodedTokenNotInPool(
                decodedTokenIn,
                token0,
                token1
            );
        }

        uint256 amountToPay;
        address tokenToPay;
        if (decodedTokenIn == token0) {
            if (amount0Delta <= 0) revert ArbErrors.CallbackInvalidDelta0Sign();
            amountToPay = uint256(amount0Delta);
            tokenToPay = token0;
        } else {
            if (amount1Delta <= 0) revert ArbErrors.CallbackInvalidDelta1Sign();
            amountToPay = uint256(amount1Delta);
            tokenToPay = token1;
        }

        if (amountToPay > 0) {
            bool ok = IERC20(tokenToPay).transfer(pool, amountToPay);
            if (!ok) revert("ERC20 transfer failed");
        }
    }

    function uniswapV2Call(
        address /*sender*/,
        uint256 /*amount0*/,
        uint256 /*amount1*/,
        bytes calldata data
    ) external {
        (address tokenToPay, uint256 amountToPay) = abi.decode(
            data,
            (address, uint256)
        );

        IUniswapV2Pair pair = IUniswapV2Pair(msg.sender);
        address t0 = pair.token0();
        address t1 = pair.token1();
        address uniPair = V2_FACTORY.getPair(t0, t1);
        address pcsPair = PANCAKESWAP_V2_FACTORY.getPair(t0, t1);
        if (msg.sender != uniPair && msg.sender != pcsPair) {
            revert ArbErrors.CallbackUnexpectedPool(msg.sender, address(0));
        }
        _requireRegisteredV2CallbackPool(msg.sender, t0, t1);
        if (tokenToPay != t0 && tokenToPay != t1) {
            revert ArbErrors.CallbackDecodedTokenNotInPool(tokenToPay, t0, t1);
        }
        if (amountToPay > 0) {
            bool ok = IERC20(tokenToPay).transfer(msg.sender, amountToPay);
            if (!ok) revert("ERC20 transfer failed");
        }
    }

    function pancakeCall(
        address /*sender*/,
        uint256 /*amount0*/,
        uint256 /*amount1*/,
        bytes calldata data
    ) external {
        (address tokenToPay, uint256 amountToPay) = abi.decode(
            data,
            (address, uint256)
        );

        IUniswapV2Pair pair = IUniswapV2Pair(msg.sender);
        address t0 = pair.token0();
        address t1 = pair.token1();
        address uniPair = V2_FACTORY.getPair(t0, t1);
        address pcsPair = PANCAKESWAP_V2_FACTORY.getPair(t0, t1);
        if (msg.sender != uniPair && msg.sender != pcsPair) {
            revert ArbErrors.CallbackUnexpectedPool(msg.sender, address(0));
        }
        _requireRegisteredV2CallbackPool(msg.sender, t0, t1);
        if (tokenToPay != t0 && tokenToPay != t1) {
            revert ArbErrors.CallbackDecodedTokenNotInPool(tokenToPay, t0, t1);
        }
        if (amountToPay > 0) {
            IERC20(tokenToPay).safeTransfer(msg.sender, amountToPay);
        }
    }

    // ----------------------- Internal helpers ------------------------------
    function _findPoolInBook(
        address token,
        address poolAddr
    ) internal view returns (ArbUtils.PoolInfo memory poolInfo, bool found) {
        ArbUtils.PoolInfo[] storage pools = tokenPools[token];
        uint256 numPools = pools.length;
        for (uint256 i = 0; i < numPools; i++) {
            if (pools[i].poolAddress == poolAddr) {
                return (pools[i], true);
            }
        }
        return (poolInfo, false);
    }

    function _getPoolIndex(
        address token,
        address poolAddr
    ) internal view returns (uint256) {
        ArbUtils.PoolInfo[] storage pools = tokenPools[token];
        uint256 numPools = pools.length;
        for (uint256 i = 0; i < numPools; i++) {
            if (pools[i].poolAddress == poolAddr) {
                return i;
            }
        }
        return type(uint256).max;
    }

    function _v2FeeForPoolType(
        ArbUtils.PoolType poolType
    ) private pure returns (uint24) {
        return
            poolType == ArbUtils.PoolType.PANCAKESWAP_V2
                ? PANCAKESWAP_V2_POOL_FEE_PPM
                : V2_POOL_FEE_PPM;
    }

    function _requireRegisteredV2CallbackPool(
        address pool,
        address token0,
        address token1
    ) private view {
        PoolMeta storage pm = poolMetaByAddr[pool];
        if (
            !pm.exists ||
            (pm.poolType != ArbUtils.PoolType.V2 &&
                pm.poolType != ArbUtils.PoolType.PANCAKESWAP_V2) ||
            pm.token0 != token0 ||
            pm.token1 != token1
        ) {
            revert ArbErrors.CallbackUnexpectedPool(pool, address(0));
        }
    }

    // ---------------------------- Treasury ---------------------------------
    receive() external payable {}

    function removeEth() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    function removeTokens(address token) external onlyOwner {
        IERC20(token).transfer(
            msg.sender,
            IERC20(token).balanceOf(address(this))
        );
    }
}
