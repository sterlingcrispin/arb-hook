// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// --- External deps ──────────────────────────────────────────────────────
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IPancakeV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ArbErrors} from "./Errors.sol";
import {ArbitrageLogic} from "./ArbitrageLogic.sol";
import {IDataStorage} from "./interfaces/IDataStorage.sol";

/// @title ArbUtils
/// @notice Shared state and helper routines for pool registration, route discovery,
///         pricing support, and treasury operations used by ArbHook.
/// @dev Route planning is intentionally simple and deterministic:
///      `supportedTokens` (outer loop) -> `baseCounterList[base]` (inner loop).
///      Registration order therefore determines evaluation order in `attemptAllInternal`.
abstract contract ArbUtils {
    uint8 internal constant MAX_SAFE_TOKEN_DECIMALS = 77;

    /// @dev Canonical concentrated-liquidity factories on Base. V3 callback
    ///      authentication relies on pools being immutable factory deployments,
    ///      so registration must reject contracts that merely mimic the pool ABI.
    IUniswapV3Factory internal constant UNISWAP_V3_FACTORY =
        IUniswapV3Factory(0x33128a8fC17869897dcE68Ed026d694621f6FDfD);
    IUniswapV3Factory internal constant PANCAKESWAP_V3_FACTORY =
        IUniswapV3Factory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865);

    IDataStorage public dataStorage;

    /// @notice Minimum tick‑spread (in basis points) required to start an iteration.
    uint16 public minSpreadBps = 10; // 0.10 %

    uint256 public BPS_DIVISOR = 10000;
    uint16 public CHUNK_SPREAD_CONSUMPTION_BPS = 1500;
    uint256 public _MAX_IMPACT_BPS = 500;
    uint24 public constant V2_POOL_FEE_PPM = 3000;
    uint24 public constant PANCAKESWAP_V2_POOL_FEE_PPM = 2500;

    enum PoolType {
        V3,
        V2,
        PANCAKESWAP_V2,
        PANCAKESWAP_V3
    }

    struct PoolInfo {
        address poolAddress;
        uint24 fee;
        PoolType poolType;
        address token0;
        address token1;
        uint8 token0Decimals;
        uint8 token1Decimals;
        int24 tickSpacing; // Only for V3 pools, 0 for V2
    }

    // Base token -> all pools registered under that base token.
    mapping(address => PoolInfo[]) internal tokenPools;
    // Distinct base tokens in insertion order. This order drives attemptAll traversal.
    address[] internal supportedTokens;

    // Base token -> unique counterpart tokens seen in registered pools.
    mapping(address => address[]) internal baseCounterList;
    // Dedupe guard for baseCounterList.
    mapping(address => mapping(address => bool)) internal isCounterKnown;

    // Stateless pricing/sizing engine shared by the hook execution paths.
    ArbitrageLogic internal arbLib;

    IDataStorage.TradeData public lastTradeData;

    // Mailbox written by inner execution and consumed by wrapper callsites.
    // Keeping this on storage avoids pushing richer structs through low-level return data.
    int256 public lastExecutionProfit;

    struct FailedQuote {
        uint128 qBuy;
        uint128 qSell;
    }
    // Deprecated price-only failure state retained to preserve the shared
    // Hook/Executor storage layout. Execution deliberately ignores it because
    // balances, approvals, liquidity, and policy can change without a price move.
    mapping(bytes32 => FailedQuote) internal lastFailedQuote;

    // Deprecated alongside lastFailedQuote; retained for storage compatibility.
    struct FailedAttempt {
        address buyPool;
        address sellPool;
        uint128 qBuy;
        uint128 qSell;
    }
    mapping(bytes32 => FailedAttempt) internal lastFailedAttemptForPair;

    /* ---------------- Pool-list helpers ---------------- */
    function _clearCountersForBase(address base) internal {
        address[] storage ctrs = baseCounterList[base];
        uint256 n = ctrs.length;
        for (uint256 i; i < n; ++i) {
            isCounterKnown[base][ctrs[i]] = false;
        }
        delete baseCounterList[base];
    }

    function _removeTokenFromSupported(address token) internal {
        uint256 n = supportedTokens.length;
        for (uint256 i; i < n; ++i) {
            if (supportedTokens[i] == token) {
                // Registration order defines route traversal order. Preserve it
                // when a base token is removed instead of using swap-and-pop.
                for (uint256 j = i; j + 1 < n; ++j) {
                    supportedTokens[j] = supportedTokens[j + 1];
                }
                supportedTokens.pop();
                break;
            }
        }
        _clearCountersForBase(token); // idempotent
    }

    /* ---------------- add / remove pools ---------------- */
    function _addPools(
        address token,
        address[] memory poolAddresses,
        uint24[] memory fees,
        ArbUtils.PoolType[] memory poolTypes
    ) internal {
        if (poolAddresses.length != fees.length || poolAddresses.length != poolTypes.length) {
            revert ArbErrors.InputArrayLengthMismatch();
        }
        // An empty registration is a no-op. Adding the base to
        // `supportedTokens` here would create a route with no pools that can
        // survive until an explicit reset.
        if (poolAddresses.length == 0) return;

        // Preserve first-seen ordering for deterministic traversal in attemptAll.
        bool tokenIsNew = true;
        for (uint256 j; j < supportedTokens.length; ++j) {
            if (supportedTokens[j] == token) {
                tokenIsNew = false;
                break;
            }
        }
        if (tokenIsNew) supportedTokens.push(token);

        for (uint256 i; i < poolAddresses.length; ++i) {
            _getAndValidateAndAddPool(token, poolAddresses[i], fees[i], poolTypes[i]);
        }
    }

    function _getAndValidateAndAddPool(address token, address poolAddr, uint24 providedFee, PoolType poolType)
        internal
    {
        address t0;
        address t1;
        uint8 dec0;
        uint8 dec1;
        int24 tickSpacing = 0;
        uint24 actualFee = providedFee;

        if (poolType == PoolType.V3 || poolType == PoolType.PANCAKESWAP_V3) {
            if (poolType == PoolType.V3) {
                IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);
                t0 = pool.token0();
                t1 = pool.token1();
                actualFee = pool.fee();
                tickSpacing = pool.tickSpacing();
            } else {
                // PANCAKESWAP_V3
                IPancakeV3Pool pool = IPancakeV3Pool(poolAddr);
                t0 = pool.token0();
                t1 = pool.token1();
                actualFee = pool.fee();
                tickSpacing = PANCAKESWAP_V3_FACTORY.feeAmountTickSpacing(actualFee);
            }

            if (!((token == t0 && t1 != address(0)) || (token == t1 && t0 != address(0)))) {
                revert ArbErrors.AddPoolsInputTokenNotInPool();
            }

            if (actualFee != providedFee) {
                revert ArbErrors.AddPoolsProvidedFeeMismatch();
            }

            IUniswapV3Factory expectedFactory = poolType == PoolType.V3 ? UNISWAP_V3_FACTORY : PANCAKESWAP_V3_FACTORY;
            if (expectedFactory.getPool(t0, t1, actualFee) != poolAddr) {
                revert ArbErrors.AddPoolsPoolVerificationFailed();
            }
        } else if (poolType == PoolType.V2) {
            actualFee = V2_POOL_FEE_PPM;
            IUniswapV2Pair pair = IUniswapV2Pair(poolAddr);
            t0 = pair.token0();
            t1 = pair.token1();

            if (!((token == t0 && t1 != address(0)) || (token == t1 && t0 != address(0)))) {
                revert ArbErrors.AddPoolsInputTokenNotInPool();
            }
        } else if (poolType == PoolType.PANCAKESWAP_V2) {
            actualFee = PANCAKESWAP_V2_POOL_FEE_PPM;
            IUniswapV2Pair pair = IUniswapV2Pair(poolAddr);
            t0 = pair.token0();
            t1 = pair.token1();

            if (!((token == t0 && t1 != address(0)) || (token == t1 && t0 != address(0)))) {
                revert ArbErrors.AddPoolsInputTokenNotInPool();
            }
        } else {
            revert("Unsupported Pool Type");
        }

        dec0 = IERC20Metadata(t0).decimals();
        dec1 = IERC20Metadata(t1).decimals();

        tokenPools[token].push(PoolInfo(poolAddr, actualFee, poolType, t0, t1, dec0, dec1, tickSpacing));

        // Build the base -> counter adjacency list used by attemptAll route scanning.
        address counter = (t0 == token) ? t1 : t0;
        if (!isCounterKnown[token][counter]) {
            isCounterKnown[token][counter] = true;
            baseCounterList[token].push(counter);
        }
    }

    function _removePool(address token, uint256 poolIndex) internal {
        PoolInfo[] storage pools = tokenPools[token];
        uint256 numPools = pools.length;
        if (numPools == 0) revert ArbErrors.TokenHasNoPools();
        if (poolIndex >= numPools) revert ArbErrors.PoolIndexOutOfBounds();

        PoolInfo memory removedPool = pools[poolIndex];
        address removedCounter = removedPool.token0 == token ? removedPool.token1 : removedPool.token0;

        // Pool registration order is a deterministic tie-breaker during route
        // discovery, so admin removal must not reorder the surviving pools.
        for (uint256 i = poolIndex; i + 1 < numPools; ++i) {
            pools[i] = pools[i + 1];
        }
        pools.pop();

        if (pools.length == 0) {
            _removeTokenFromSupported(token);
        } else {
            _pruneCounterIfOrphaned(token, removedCounter);
        }
    }

    function _resetTokenPools(address token) internal {
        delete tokenPools[token];
        // Also removes legacy/accidental ghost entries whose pool array is
        // already empty.
        _removeTokenFromSupported(token);
    }

    function _pruneCounterIfOrphaned(address base, address counter) private {
        PoolInfo[] storage pools = tokenPools[base];
        uint256 poolCount = pools.length;
        for (uint256 i; i < poolCount; ++i) {
            PoolInfo storage pool = pools[i];
            address poolCounter = pool.token0 == base ? pool.token1 : pool.token0;
            if (poolCounter == counter) return;
        }

        if (!isCounterKnown[base][counter]) return;
        isCounterKnown[base][counter] = false;

        address[] storage counters = baseCounterList[base];
        uint256 counterCount = counters.length;
        for (uint256 i; i < counterCount; ++i) {
            if (counters[i] != counter) continue;
            // Counter traversal is insertion ordered for the same reason as
            // supported-token traversal.
            for (uint256 j = i; j + 1 < counterCount; ++j) {
                counters[j] = counters[j + 1];
            }
            counters.pop();
            return;
        }
    }

    function _resetAllPools() internal {
        uint256 s = supportedTokens.length;
        for (uint256 i; i < s; ++i) {
            address token = supportedTokens[i];
            _clearCountersForBase(token);
            delete tokenPools[token];
        }
        delete supportedTokens;
    }

    // -------------------------------------------------------------------
    //  Constants
    // -------------------------------------------------------------------
    /// @dev Minimum meaningful trade size: 1 × 10⁻⁴ of one whole token.
    function _minChunk(address token) internal view virtual returns (uint256) {
        uint8 d = IERC20Metadata(token).decimals();
        // 10**78 no longer fits in uint256. Returning an unexecutable chunk
        // makes discovery fail closed for unsupported token representations.
        if (d > MAX_SAFE_TOKEN_DECIMALS) return type(uint256).max;
        return d > 4 ? 10 ** (d - 4) : 1; // never below 1 wei
    }

    // -------------------------------------------------------------------
    //  Step 3 – swap helpers
    // -------------------------------------------------------------------

    // mirror of IterativeArbBot's event so the compiler can emit it here too
    event SwapExecuted(
        address indexed pool, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    // -------------------------------------------------------------------
    //  Step 3.1 – swap helpers (V2)
    // -------------------------------------------------------------------

    /**
     * @dev Executes a single flash swap on a Uniswap V2 pool.
     * @param pair The IUniswapV2Pair contract instance.
     * @param tokenToReceive The token address we want to receive from the pool.
     * @param amountToReceive The amount of `tokenToReceive` we want to get.
     * @param tokenToPay The token address we will pay back in the callback.
     * @param amountToPay The amount of `tokenToPay` we will pay back.
     */
    function _executeV2FlashSwap(
        IUniswapV2Pair pair,
        address tokenToReceive,
        uint256 amountToReceive,
        address tokenToPay,
        uint256 amountToPay
    ) internal virtual returns (bool success) {
        if (tokenToReceive == tokenToPay || amountToReceive == 0) {
            revert("Invalid V2 flash swap params");
        }

        //console.log("... Executing V2 Flash Swap ...");
        //console.log("tokenToReceive:", tokenToReceive);
        //console.log("amountToReceive:", amountToReceive);
        //console.log("tokenToPay:", tokenToPay);
        //console.log("amountToPay:", amountToPay);

        // Encode the required input amount and the input token address into `data` for the callback
        bytes memory data = abi.encode(tokenToPay, amountToPay);

        uint256 amount0Out = 0;
        uint256 amount1Out = 0;

        if (tokenToReceive == pair.token0()) {
            amount0Out = amountToReceive;
        } else {
            amount1Out = amountToReceive;
        }
        //console.log("trying to swap");
        try pair.swap(amount0Out, amount1Out, address(this), data) {
            success = true;
        } catch {
            //console.log("!!! V2 FLASH SWAP FAILED !!!");
            // console.logBytes(reason);
            success = false;
        }
    }
}
