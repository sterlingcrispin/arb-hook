// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Executes bounded on-chain arbitrage attempts from Uniswap v4 swap callbacks.
import "./ArbUtils.sol";
import "./ArbitrageLogic.sol";
import {ArbErrors} from "./Errors.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    BalanceDelta,
    BalanceDeltaLibrary
} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
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
import {IERC3156FlashBorrower} from "./interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "./interfaces/IERC3156FlashLender.sol";

/// @title ArbHook
/// @notice Uniswap v4 hook that counter-trades its triggering pool against a
///         registered concentrated-liquidity reference venue, repays flash
///         principal, and returns realized profit to the triggering swapper.
contract ArbHook is
    ArbUtils,
    Ownable2Step,
    IERC3156FlashBorrower
{
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    error NotPoolManager();

    IPoolManager public immutable poolManager;

    struct PoolMeta {
        address token0;
        address token1;
        PoolType poolType;
        bool exists;
    }

    // Quick lookup for callbacks and validation without extra external calls
    mapping(address => PoolMeta) private poolMetaByAddr;

    // Cache token decimals to make _minChunk cheaper
    mapping(address => uint8) private cachedTokenDecimals;
    // Default max iterations when attempting arb via hook callbacks (0 disables hook execution)
    uint256 internal hookMaxIterations;

    /// @notice Gas withheld from the arbitrage attempt so the triggering swap can
    ///         always finish settling after the hook returns.
    /// @dev The 63/64 call rule alone does not guarantee enough remains on a
    ///      low-gas-limit swap, so the attempt is given an explicit budget.
    uint32 internal hookGasReserve = 200_000;
    /// @notice Hard ceiling on gas one arbitrage attempt may consume (0 = no ceiling).
    uint32 internal hookGasLimit = 3_000_000;

    uint256 private constant FEE_BPS_DIVISOR = 10_000;
    bytes32 private constant ERC3156_CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");
    bytes4 private constant ATTEMPT_ALL_INTERNAL_SELECTOR =
        bytes4(keccak256("attemptAllInternal(uint256)"));
    bytes4 private constant EXECUTE_ITERATIVE_ARB_VIA_FLASH_SELECTOR =
        bytes4(
            keccak256(
                "executeIterativeArbViaFlash(address,address,address,address,uint256,uint8,uint8)"
            )
        );

    // Trusted factories for callback validation
    IUniswapV2Factory private constant V2_FACTORY =
        IUniswapV2Factory(0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6);
    IUniswapV2Factory private constant PANCAKESWAP_V2_FACTORY =
        IUniswapV2Factory(0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E);

    event FlashLoanSettled(
        address indexed lender,
        address indexed tokenA,
        address indexed tokenB,
        address buyPool,
        address sellPool,
        uint256 principal,
        uint256 totalAmountSwapped,
        uint256 fee,
        int256 netProfit,
        uint256 iterations,
        address beneficiary
    );

    // Flash-loan config and runtime context.
    mapping(address => address) internal lenderByToken;
    mapping(address => uint256) internal flashPrincipalByToken;
    mapping(address => uint256) internal maxFlashFeeBpsByToken;
    mapping(address => uint256) internal minNetProfitByToken;
    mapping(PoolId => uint256[2]) private minTriggerAmountByPool;

    // Flash-loan runtime context. All of it is single-transaction state and lives
    // in transient storage; see ArbUtils for the slot assignments.
    function _activeLender() private view returns (address) {
        return address(uint160(_tload(_T_LENDER)));
    }

    function _activeLoanToken() private view returns (address) {
        return address(uint160(_tload(_T_LOAN_TOKEN)));
    }

    function _activeLoanAmount() private view returns (uint256) {
        return _tload(_T_LOAN_AMOUNT);
    }

    function _activeFlashContextHash() private view returns (bytes32) {
        return bytes32(_tload(_T_FLASH_CONTEXT));
    }

    function _flashLastTradeSuccess() private view returns (bool) {
        return _tload(_T_LAST_SUCCESS) != 0;
    }

    function _flashLastProfit() private view returns (int256) {
        return int256(_tload(_T_LAST_PROFIT));
    }

    function _flashLastIterations() private view returns (uint256) {
        return _tload(_T_LAST_ITERATIONS);
    }

    struct FlashLoanExecutionParams {
        address sellPool;
        address buyPool;
        address tokenA;
        address tokenB;
        uint256 maxIterations;
        ArbUtils.PoolType sellPoolType;
        ArbUtils.PoolType buyPoolType;
        address beneficiary;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        return _afterSwap(key, params, delta, hookData);
    }

    function _afterSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal returns (bytes4, int128) {
        // Hook path is best-effort only: trade failure must never block user swap settlement.
        uint256 iterations = hookMaxIterations;
        if (iterations > 0) {
            // Avoid route discovery and borrowing for calibrated-small swaps.
            uint256 minimumInput = minTriggerAmountByPool[key.toId()][
                params.zeroForOne ? 1 : 0
            ];
            if (minimumInput != 0) {
                int128 inputDelta = params.zeroForOne
                    ? delta.amount0()
                    : delta.amount1();
                if (
                    inputDelta >= 0 ||
                    uint256(-int256(inputDelta)) < minimumInput
                ) return (IHooks.afterSwap.selector, 0);
            }

            address beneficiary = _resolveProfitRecipient(hookData);
            if (beneficiary != address(0)) {
                _setActiveProfitRecipient(beneficiary);
                _attemptHookPoolViaSelfCall(key, params.zeroForOne);
                _setActiveProfitRecipient(address(0));
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev Gas available to an arbitrage attempt, or zero when the triggering swap
    ///      cannot spare any. Reserving before the call is what keeps a costly
    ///      discovery pass from consuming the user's whole gas limit: the 63/64
    ///      rule leaves only 1/64 behind, which is not enough to settle a swap
    ///      when the caller set a modest limit.
    function _attemptGasBudget() private view returns (uint256) {
        uint256 available = gasleft();
        uint256 reserve = hookGasReserve;
        if (available <= reserve) return 0;

        unchecked {
            available -= reserve;
        }
        uint256 ceiling = hookGasLimit;
        if (ceiling != 0 && available > ceiling) available = ceiling;
        return available;
    }

    function _attemptAllViaSelfCall(
        uint256 iterations
    ) internal returns (bool) {
        uint256 gasBudget = _attemptGasBudget();
        if (gasBudget == 0) return false;

        // Self-call gives us a hard failure boundary:
        // any revert in deep execution is captured as bytes and does not bubble,
        // and the explicit budget bounds what a failure can cost the user.
        (bool successCall, bytes memory returndata) = address(this).call{
            gas: gasBudget
        }(abi.encodeWithSelector(ATTEMPT_ALL_INTERNAL_SELECTOR, iterations));

        bool tradeSuccess = successCall && abi.decode(returndata, (bool));
        return successCall && tradeSuccess;
    }

    function _attemptHookPoolViaSelfCall(
        PoolKey calldata key,
        bool triggerZeroForOne
    ) private returns (bool) {
        uint256 gasBudget = _attemptGasBudget();
        if (gasBudget == 0) return false;

        (bool successCall, bytes memory returndata) = address(this).call{
            gas: gasBudget
        }(
            abi.encodeWithSelector(
                this.attemptHookPoolInternal.selector,
                key,
                triggerZeroForOne
            )
        );
        return successCall && abi.decode(returndata, (bool));
    }

    function getHookPermissions()
        public
        pure
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

    function validateHookAddress(ArbHook self) internal pure virtual {
        Hooks.validateHookPermissions(
            IHooks(address(self)),
            getHookPermissions()
        );
    }

    constructor(
        IPoolManager _poolManager,
        address initialOwner,
        address _arbLib
    ) Ownable(initialOwner) {
        poolManager = _poolManager;
        validateHookAddress(this);
        if (address(_poolManager) == address(0))
            revert ArbErrors.InvalidPoolManagerAddress();
        if (_arbLib == address(0))
            revert ArbErrors.InvalidArbitrageLogicAddress();
        arbLib = ArbitrageLogic(_arbLib);
    }

    // ------------------------------- Admin ---------------------------------

    /// @dev A live v4 hook cannot be detached, so its shutdown controls must
    ///      always retain an owner. Ownership transfers remain two-step.
    function renounceOwnership() public pure override {
        revert ArbErrors.OwnershipRenunciationDisabled();
    }

    function getExecutionConfig()
        external
        view
        returns (
            uint256 maxIterations,
            uint16 minimumSpreadBps,
            uint16 chunkSpreadConsumptionBps,
            uint256 maxImpactBps
        )
    {
        return (
            hookMaxIterations,
            minSpreadBps,
            CHUNK_SPREAD_CONSUMPTION_BPS,
            _MAX_IMPACT_BPS
        );
    }

    function getFlashConfig(
        address token
    )
        external
        view
        returns (
            address lender,
            uint256 principalCap,
            uint256 maxFeeBps,
            uint256 minNetProfit
        )
    {
        lender = lenderByToken[token];
        return (
            lender,
            flashPrincipalByToken[token],
            maxFlashFeeBpsByToken[token],
            minNetProfitByToken[token]
        );
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

    function setHookMaxIterations(uint256 newMaxIterations) external onlyOwner {
        hookMaxIterations = newMaxIterations;
    }

    /// @notice Set the gas withheld for swap settlement and the ceiling on one attempt.
    /// @param gasReserve Gas guaranteed to remain for the caller after the attempt.
    /// @param gasLimit Maximum gas one attempt may consume; zero removes the ceiling.
    function setHookGasBounds(
        uint32 gasReserve,
        uint32 gasLimit
    ) external onlyOwner {
        if (gasReserve == 0) revert ArbErrors.InvalidGasReserve();
        hookGasReserve = gasReserve;
        hookGasLimit = gasLimit;
    }

    function getGasBounds()
        external
        view
        returns (uint32 gasReserve, uint32 gasLimit)
    {
        return (hookGasReserve, hookGasLimit);
    }

    /// @notice Set the actual input required before one pool direction attempts arbitrage.
    /// @dev Amount uses currency0 units for zeroForOne, otherwise currency1; zero disables.
    function setMinTriggerAmount(
        PoolId poolId,
        bool zeroForOne,
        uint256 amount
    ) external onlyOwner {
        minTriggerAmountByPool[poolId][zeroForOne ? 1 : 0] = amount;
    }

    function getMinTriggerAmount(
        PoolId poolId,
        bool zeroForOne
    ) external view returns (uint256) {
        return minTriggerAmountByPool[poolId][zeroForOne ? 1 : 0];
    }

    function setLenderForToken(
        address token,
        address lender
    ) external onlyOwner {
        if (token == address(0)) revert ArbErrors.InvalidTokenAddress();
        if (lender == address(0)) revert ArbErrors.InvalidLenderAddress();
        lenderByToken[token] = lender;
    }

    function setFlashPrincipalForToken(
        address token,
        uint256 principal
    ) external onlyOwner {
        if (token == address(0)) revert ArbErrors.InvalidTokenAddress();
        flashPrincipalByToken[token] = principal;
    }

    function setMaxFlashFeeBpsForToken(
        address token,
        uint256 maxFeeBps
    ) external onlyOwner {
        if (token == address(0)) revert ArbErrors.InvalidTokenAddress();
        if (maxFeeBps > FEE_BPS_DIVISOR)
            revert ArbErrors.FlashFeeBpsTooHigh();
        maxFlashFeeBpsByToken[token] = maxFeeBps;
    }

    function setMinNetProfitForToken(
        address token,
        uint256 minNetProfit
    ) external onlyOwner {
        if (token == address(0)) revert ArbErrors.InvalidTokenAddress();
        minNetProfitByToken[token] = minNetProfit;
    }

    // ------------------------- Pool-book API -------------------------------
    /// @notice Append owner-verified pools to the canary registry.
    /// @dev Registration is intentionally append-only. Correct a bad canary
    ///      configuration by deploying a fresh hook before routing traffic.
    function addPools(
        address token,
        address[] memory poolAddresses,
        uint24[] memory fees,
        ArbUtils.PoolType[] memory poolTypes
    ) external onlyOwner {
        // Registration order matters: it affects supportedTokens/baseCounterList traversal order.
        uint256 firstAddedPool = tokenPools[token].length;
        _addPools(token, poolAddresses, fees, poolTypes);

        // _addPools already fetched and validated this metadata. Reuse its stored
        // PoolInfo instead of repeating external calls to every pool and token.
        for (uint256 i = 0; i < poolAddresses.length; i++) {
            ArbUtils.PoolInfo storage info = tokenPools[token][
                firstAddedPool + i
            ];
            PoolMeta storage m = poolMetaByAddr[info.poolAddress];
            m.token0 = info.token0;
            m.token1 = info.token1;
            m.poolType = info.poolType;
            m.exists = true;

            // Cache decimals for both tokens to make _minChunk cheaper later
            if (m.token0 != address(0) && cachedTokenDecimals[m.token0] == 0) {
                cachedTokenDecimals[m.token0] = info.token0Decimals == 0
                    ? 18
                    : info.token0Decimals;
            }
            if (m.token1 != address(0) && cachedTokenDecimals[m.token1] == 0) {
                cachedTokenDecimals[m.token1] = info.token1Decimals == 0
                    ? 18
                    : info.token1Decimals;
            }
        }
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

    /// @notice Counter-trade the triggering v4 pool against its registered V3 reference venue.
    /// @dev This self-call is the failure boundary used by afterSwap. The triggering swap's
    ///      output token is the flash principal and the first leg runs in the opposite direction.
    function attemptHookPoolInternal(
        PoolKey calldata key,
        bool triggerZeroForOne
    ) external returns (bool) {
        if (msg.sender != address(this)) revert ArbErrors.WrapperOnlySelf();

        address startToken = Currency.unwrap(
            triggerZeroForOne ? key.currency1 : key.currency0
        );
        address intermediateToken = Currency.unwrap(
            triggerZeroForOne ? key.currency0 : key.currency1
        );
        if (startToken == address(0) || intermediateToken == address(0)) return false;

        address lender = lenderByToken[startToken];
        uint256 principalCap = _resolvePrincipalCap(startToken, lender);
        uint256 maxFeeBps = maxFlashFeeBpsByToken[startToken];
        if (
            principalCap == 0 ||
            maxFeeBps == 0 ||
            minNetProfitByToken[startToken] == 0
        ) return false;

        ArbUtils.PoolInfo memory externalPool;
        ArbUtils.PoolInfo[] storage pools = tokenPools[startToken];
        for (uint256 i; i < pools.length; ) {
            ArbUtils.PoolInfo storage candidate = pools[i];
            if (
                (candidate.poolType == ArbUtils.PoolType.V3 ||
                    candidate.poolType == ArbUtils.PoolType.PANCAKESWAP_V3) &&
                ((candidate.token0 == startToken &&
                    candidate.token1 == intermediateToken) ||
                    (candidate.token1 == startToken &&
                        candidate.token0 == intermediateToken))
            ) {
                externalPool = candidate;
                break;
            }
            unchecked {
                ++i;
            }
        }
        if (externalPool.poolAddress == address(0)) return false;

        ArbitrageLogic.IterationConfig memory config;
        config.minSpreadBps = minSpreadBps;
        config.chunkSpreadConsumptionBps = CHUNK_SPREAD_CONSUMPTION_BPS;
        config.bpsDivisor = BPS_DIVISOR;
        config.maxImpactBps = _MAX_IMPACT_BPS;
        config.minChunkForStartToken = _minChunk(startToken);
        config.currentStartTokenBalance = principalCap;

        ArbitrageLogic.V4V3RouteParams memory route = arbLib
            .getLiveV4V3RouteParams(
                poolManager,
                key.toId(),
                Currency.unwrap(key.currency0),
                startToken,
                intermediateToken,
                externalPool,
                config
            );
        if (route.principal == 0) return false;

        FlashLoanExecutionParams memory params = FlashLoanExecutionParams({
            sellPool: address(poolManager),
            buyPool: externalPool.poolAddress,
            tokenA: startToken,
            tokenB: intermediateToken,
            maxIterations: 1,
            sellPoolType: ArbUtils.PoolType.V3,
            buyPoolType: externalPool.poolType,
            beneficiary: _activeProfitRecipient()
        });
        bytes memory loanData = abi.encode(
            params,
            key,
            route.sqrtPriceLimitX96,
            route.externalSqrtPriceLimitX96
        );
        uint256 principal = route.principal;
        for (uint8 attempt; attempt < 3; ) {
            uint256 fee;
            try IERC3156FlashLender(lender).flashFee(startToken, principal) returns (
                uint256 quotedFee
            ) {
                fee = quotedFee;
            } catch {
                return false;
            }
            if (_feeExceedsCap(principal, fee, maxFeeBps)) return false;

            (bool requested, bool reverted, bool belowMinimum) =
                _requestFlashLoan(lender, startToken, principal, loanData);
            if (requested) return _flashLastTradeSuccess();
            if (!reverted || belowMinimum) return false;

            principal >>= 1;
            if (principal < config.minChunkForStartToken) return false;
            unchecked {
                ++attempt;
            }
        }
        return false;
    }

    // -------------------------- Core entrypoint ----------------------------
    /// @notice Legacy parity scanner for configured external base/counter pairs.
    /// @dev Must be executed via self-call. Individual pair attempts are isolated with
    ///      low-level calls so a failing path does not revert the full cycle.
    ///      This internal execution path may still revert on invariant or auth failures.
    function _attemptAllInternal(
        uint256 maxIterations
    ) internal returns (bool success) {
        if (msg.sender != address(this)) revert ArbErrors.WrapperOnlySelf();

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
                (int256 profit, ) = _runPair(
                    baseToken,
                    counterToken,
                    maxIterations
                );
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

        bool tradeWasProfitable = totalProfit > 0;
        return tradeWasProfitable;
    }

    // ---------------------------- Pair runner ------------------------------
    struct LoopState {
        // Bounded retry count for alternative pool combinations.
        uint8 attempts;
        // Pool excluded in the fallback discovery pass after a failed attempt.
        address skipSellPool;
    }

    function _runPair(
        address tokenA,
        address tokenB,
        uint256 maxIter
    ) internal returns (int256 cumulativeProfit, uint256 iterations) {
        LoopState memory state;

        // Up to two discovery/execute attempts:
        // first on the best route, then one fallback excluding its sell pool.
        while (state.attempts < 2) {
            (
                address buyPool,
                address sellPool,
                ,
                ,
                ArbUtils.PoolType buyPoolType,
                ArbUtils.PoolType sellPoolType
            ) = findBestPools(
                    tokenA,
                    tokenB,
                    address(0),
                    state.skipSellPool
                );

            if (buyPool == address(0)) return (0, 0);
            if (buyPool == sellPool) {
                ++state.attempts;
                state.skipSellPool = sellPool;
                continue;
            }

            // Isolate pair execution failure from the outer scanner.
            // A route receives at most half the remaining scanner gas. Its self-call
            // can fail independently without starving the fallback or later pairs.
            (bool successCall, bytes memory returndata) = address(this).call{
                gas: gasleft() >> 1
            }(
                abi.encodeWithSelector(
                    EXECUTE_ITERATIVE_ARB_VIA_FLASH_SELECTOR,
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
                state.attempts++;
                state.skipSellPool = sellPool;
                continue;
            }

            (bool tradeSuccess, int256 profit, uint256 iters) = abi.decode(
                returndata,
                (bool, int256, uint256)
            );

            cumulativeProfit += profit;
            iterations += iters;

            if (tradeSuccess && profit > 0) {
                return (cumulativeProfit, iterations);
            }

            unchecked {
                ++state.attempts;
            }
            state.skipSellPool = sellPool;
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
        // Iterate storage directly to avoid copying the entire pool array to memory
        // Pool universe is "all pools registered under tokenA as base".
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

        // One pass picks:
        // - cheapest pool to buy tokenA (lowest effective buy price),
        // - richest pool to sell tokenA (highest effective sell price).
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
            // No executable spread after fees, or only one usable pool.
            return (
                address(0),
                address(0),
                0,
                0,
                ArbUtils.PoolType.V3,
                ArbUtils.PoolType.V3
            );
        }
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
    /// @notice Execute one arbitrage attempt using flash-loaned startToken capital.
    /// @dev Preserves existing iterative execution logic by invoking executeIterativeArb
    ///      inside the flash-loan callback.
    function _executeIterativeArbViaFlash(
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
        if (msg.sender != address(this)) revert ArbErrors.WrapperOnlySelf();
        if (maxIterations == 0) return (false, 0, 0);

        address lender = lenderByToken[startToken];
        if (lender == address(0)) {
            return (false, 0, 0);
        }

        uint256 maxFeeBps = maxFlashFeeBpsByToken[startToken];
        uint256 minNetProfit = minNetProfitByToken[startToken];
        if (maxFeeBps == 0 || minNetProfit == 0) {
            return (false, 0, 0);
        }

        uint256 principalCap = _resolvePrincipalCap(startToken, lender);
        uint256 principal;
        bool isPoolAV3 = poolAType == ArbUtils.PoolType.V3 || poolAType == ArbUtils.PoolType.PANCAKESWAP_V3;
        bool isPoolBV3 = poolBType == ArbUtils.PoolType.V3 || poolBType == ArbUtils.PoolType.PANCAKESWAP_V3;
        uint256 refinedV3Principal;
        // Raw-token profit estimate for the pre-loan economic screen. Only the
        // V2/V2 and mixed sizing paths produce a figure that is comparable to
        // currency: both simulate each leg with real reserves or swap math and
        // deduct both pool fees. The V3/V3 path deliberately leaves this zero.
        uint256 expectedNetProfit;
        if (isPoolAV3 && isPoolBV3) {
            // Reuse the executor's existing V3 sizing model for the first loan.
            // This reads current pool state but does not add tick traversal.
            uint256 edgeScore;
            (principal, refinedV3Principal, edgeScore) = _deriveV3Principal(
                poolA_addr, poolB_addr, startToken, intermediateToken, poolAType, poolBType, principalCap
            );
            // `edgeScore` only answers "does some edge exist here". The V3/V3
            // search ranks candidate chunks with a linearly scaled model that
            // omits pool A's fee, so its magnitude can differ from realized
            // profit by orders of magnitude in either direction. Screening it
            // against minNetProfit rejects genuinely profitable routes at random;
            // minNetProfit is enforced exactly against realized balances in
            // onFlashLoan, which is authoritative for every route type.
            if (principal == 0 || edgeScore == 0) return (false, 0, 0);
        } else if (!isPoolAV3 && !isPoolBV3) {
            (principal, expectedNetProfit) = _deriveV2Principal(
                poolA_addr, poolB_addr, startToken, intermediateToken, poolAType, poolBType, principalCap
            );
            if (principal == 0) return (false, 0, 0);
        } else {
            (principal, expectedNetProfit) = _deriveMixedPrincipal(
                poolA_addr, poolB_addr, startToken, intermediateToken, poolAType, poolBType, principalCap
            );
            if (principal == 0) return (false, 0, 0);
        }
        uint256 fee;
        try
            IERC3156FlashLender(lender).flashFee(startToken, principal)
        returns (uint256 quotedFee) {
            fee = quotedFee;
        } catch {
            return (false, 0, 0);
        }

        if (_feeExceedsCap(principal, fee, maxFeeBps))
            return (false, 0, 0);
        if (
            expectedNetProfit > 0 &&
            (expectedNetProfit <= fee ||
                expectedNetProfit - fee < minNetProfit)
        ) return (false, 0, 0);

        address beneficiary = _activeProfitRecipient();
        if (beneficiary == address(0)) return (false, 0, 0);

        FlashLoanExecutionParams memory params = FlashLoanExecutionParams({
            sellPool: poolA_addr,
            buyPool: poolB_addr,
            tokenA: startToken,
            tokenB: intermediateToken,
            maxIterations: maxIterations,
            sellPoolType: poolAType,
            buyPoolType: poolBType,
            beneficiary: beneficiary
        });
        bytes memory loanData = abi.encode(params);

        (bool loanRequested, bool loanReverted, bool belowMinimum) =
            _requestFlashLoan(lender, startToken, principal, loanData);
        if (loanRequested || !loanReverted) {
            return (_flashLastTradeSuccess(), _flashLastProfit(), _flashLastIterations());
        }
        if (belowMinimum) return (false, 0, 0);

        // A retryable coarse V3 failure leaves pool state unchanged. Economic
        // rejection is final; other failures may retry with a smaller chunk.
        if (!isPoolAV3 || !isPoolBV3 || refinedV3Principal == 0 || refinedV3Principal >= principal) {
            return (false, 0, 0);
        }
        uint256 retryPrincipal = refinedV3Principal;
        uint256 minPrincipal = _minChunk(startToken);
        // Match the existing two-attempt route bound: try the refined chunk and,
        // only after another reverted loan, one smaller half-size candidate.
        for (uint8 retry; retry < 2;) {
            try IERC3156FlashLender(lender).flashFee(startToken, retryPrincipal) returns (uint256 quotedRefinedFee) {
                fee = quotedRefinedFee;
            } catch {
                return (false, 0, 0);
            }
            if (_feeExceedsCap(retryPrincipal, fee, maxFeeBps))
                return (false, 0, 0);

            (loanRequested, loanReverted, belowMinimum) =
                _requestFlashLoan(lender, startToken, retryPrincipal, loanData);
            if (loanRequested) {
                return (_flashLastTradeSuccess(), _flashLastProfit(), _flashLastIterations());
            }
            if (belowMinimum) break;
            if (!loanReverted) break;

            retryPrincipal >>= 1;
            if (retryPrincipal < minPrincipal) break;
            unchecked {
                ++retry;
            }
        }
        return (false, 0, 0);
    }

    function _requestFlashLoan(address lender, address token, uint256 principal, bytes memory loanData)
        private
        returns (bool loanRequested, bool loanReverted, bool belowMinimum)
    {

        _tstore(_T_LENDER, uint256(uint160(lender)));
        _tstore(_T_LOAN_TOKEN, uint256(uint160(token)));
        _tstore(_T_LOAN_AMOUNT, principal);
        _tstore(
            _T_FLASH_CONTEXT,
            uint256(_flashContextHash(lender, token, principal, loanData))
        );

        _tstore(_T_LAST_SUCCESS, 0);
        _tstore(_T_LAST_PROFIT, 0);
        _tstore(_T_LAST_ITERATIONS, 0);

        try
            IERC3156FlashLender(lender).flashLoan(
                address(this),
                token,
                principal,
                loanData
            )
        returns (bool ok) {
            loanRequested = ok;
        } catch (bytes memory reason) {
            loanReverted = true;
            // The bundled adapters bubble callback revert data unchanged. A future
            // lender that rewrites it can alter retry selection, not settlement safety.
            belowMinimum = _revertSelector(reason) == ArbErrors.FlashProfitBelowMinimum.selector;
        }

        _clearActiveFlashContext();
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        if (msg.sender != _activeLender()) {
            revert ArbErrors.InvalidFlashLender();
        }
        if (initiator != address(this))
            revert ArbErrors.InvalidFlashInitiator();
        if (token != _activeLoanToken() || amount != _activeLoanAmount()) {
            revert ArbErrors.FlashLoanMismatch();
        }
        if (
            _activeFlashContextHash() !=
            _flashContextHash(msg.sender, token, amount, data)
        ) {
            revert ArbErrors.FlashContextMismatch();
        }

        FlashLoanExecutionParams memory params = abi.decode(
            data,
            (FlashLoanExecutionParams)
        );
        if (params.tokenA != token) revert ArbErrors.FlashTokenMismatch();
        if (params.beneficiary == address(0))
            revert ArbErrors.InvalidFlashBeneficiary();
        if (
            _feeExceedsCap(amount, fee, maxFlashFeeBpsByToken[token])
        ) revert ArbErrors.FlashFeeExceedsCap();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        uint256 intermediateBalanceBefore = IERC20(params.tokenB).balanceOf(
            address(this)
        );

        bool tradeSuccess;
        uint256 iters;
        uint256 totalAmountSwapped;
        if (params.sellPool == address(poolManager)) {
            PoolKey memory key;
            uint160 sqrtPriceLimitX96;
            uint160 externalSqrtPriceLimitX96;
            (, key, sqrtPriceLimitX96, externalSqrtPriceLimitX96) = abi.decode(
                data,
                (FlashLoanExecutionParams, PoolKey, uint160, uint160)
            );
            bool zeroForOne = Currency.unwrap(key.currency0) == token;
            if (
                address(key.hooks) != address(this) ||
                Currency.unwrap(zeroForOne ? key.currency1 : key.currency0) !=
                params.tokenB
            ) revert ArbErrors.FlashTokenMismatch();

            uint256 intermediateReceived;
            (totalAmountSwapped, intermediateReceived) = _executeV4Swap(
                key,
                zeroForOne,
                amount,
                sqrtPriceLimitX96
            );
            bool externalSuccess = _executeSwapInternal_noBalanceCheck(
                params.buyPool,
                params.buyPoolType,
                params.tokenB,
                token,
                intermediateReceived,
                externalSqrtPriceLimitX96
            );
            if (!externalSuccess)
                revert ArbErrors.FlashArbitrageExecutionFailed();
            tradeSuccess = true;
            iters = 1;
        } else {
            (bool successCall, bytes memory returndata) = address(this).call(
                abi.encodeWithSelector(
                    this.executeIterativeArb.selector,
                    params.sellPool,
                    params.buyPool,
                    params.tokenA,
                    params.tokenB,
                    params.maxIterations,
                    params.sellPoolType,
                    params.buyPoolType
                )
            );
            if (!successCall)
                revert ArbErrors.FlashArbitrageExecutionFailed();
            (tradeSuccess, , iters, totalAmountSwapped) = abi.decode(
                returndata,
                (bool, int256, uint256, uint256)
            );
        }
        if (
            IERC20(params.tokenB).balanceOf(address(this)) !=
            intermediateBalanceBefore
        ) revert ArbErrors.UnwindFailed();

        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        int256 netProfit = int256(balanceAfter) -
            int256(balanceBefore) -
            int256(fee);

        uint256 minNetProfit = minNetProfitByToken[token];
        if (!tradeSuccess || netProfit <= 0) {
            revert ArbErrors.FlashArbitrageUnprofitable();
        }
        if (uint256(netProfit) < minNetProfit) {
            revert ArbErrors.FlashProfitBelowMinimum();
        }

        _tstore(_T_LAST_SUCCESS, 1);
        _tstore(_T_LAST_PROFIT, uint256(netProfit));
        _tstore(_T_LAST_ITERATIONS, iters);

        IERC20(token).safeTransfer(params.beneficiary, uint256(netProfit));

        uint256 repayAmount = amount + fee;
        uint256 repaymentBalance = IERC20(token).balanceOf(address(this));
        if (repaymentBalance < repayAmount) {
            revert ArbErrors.InsufficientFlashRepaymentBalance();
        }
        IERC20(token).approve(msg.sender, 0);
        IERC20(token).approve(msg.sender, repayAmount);

        emit FlashLoanSettled(
            msg.sender,
            token,
            params.tokenB,
            params.buyPool,
            params.sellPool,
            amount,
            totalAmountSwapped,
            fee,
            netProfit,
            iters,
            params.beneficiary
        );

        return ERC3156_CALLBACK_SUCCESS;
    }

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
    )
        public
        virtual
        returns (bool success, int256 cumulativeProfit, uint256 iterations, uint256 totalAmountSwapped)
    {
        if (msg.sender != address(this)) revert ArbErrors.WrapperOnlySelf();
        if (maxIterations == 0) return (false, 0, 0, 0);
        if (poolA_addr == poolB_addr) return (false, 0, 0, 0);

        IERC20 startTokenContract = IERC20(startToken);
        IERC20 intermediateTokenContract = IERC20(intermediateToken);
        uint256 activePrincipal = _activeLoanAmount();
        // Any intermediate balance held before this route runs belongs to the hook,
        // not to this attempt. Unwinding is measured against it so a pre-existing
        // balance is never spent and never counted as residue.
        uint256 intermediateAtEntry = intermediateTokenContract.balanceOf(
            address(this)
        );
        // Minimum practical trade size for this token precision (e.g. 1e14 for 18-dec tokens).
        uint256 minChunkStartToken = _minChunk(startToken);
        // Guardrail to avoid "winning tiny amount after prior losses" situations.
        int256 minCumulativeProfit = int256(minChunkStartToken) / 10;

        bool isPoolAV3 = (poolAType == ArbUtils.PoolType.V3 ||
            poolAType == ArbUtils.PoolType.PANCAKESWAP_V3);
        bool isPoolBV3 = (poolBType == ArbUtils.PoolType.V3 ||
            poolBType == ArbUtils.PoolType.PANCAKESWAP_V3);

        int24 initialAbsSpreadForThisArbOpportunity = 0;

        if (isPoolAV3 && isPoolBV3) {
            // For V3/V3 paths we anchor dynamic sizing to the initial tick spread.
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
                    return (false, 0, 0, 0);
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
                    return (false, 0, 0, 0);
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
                    return (false, 0, 0, 0);
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
                    return (false, 0, 0, 0);
                }
            }

            try pA_v3_check.token0() returns (address t0A) {
                initialTokenA0_check = t0A;
            } catch {
                return (false, 0, 0, 0);
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
                // Spread already too tight; treat as clean no-op success.
                return (true, 0, 0, 0);
            }
        }
        // Outer execution loop: each pass recomputes a fresh chunk from live state.
        for (uint256 i = 0; i < maxIterations; ) {
            uint256 balanceBeforeIteration = startTokenContract.balanceOf(
                address(this)
            );
            // Flash sizing uses only the loan plus profit earned by earlier
            // iterations. Inventory mode is retained only by the legacy harness.
            uint256 sizingBalance = activePrincipal == 0
                ? balanceBeforeIteration
                : activePrincipal + uint256(cumulativeProfit);

            uint256 chunkToSwap = 0;
            uint160 sqrtPriceLimitA_v3 = 0;
            uint160 sqrtPriceLimitB_v3 = 0;

            if (isPoolAV3 && isPoolBV3) {
                // V3/V3 path:
                // - derive a rough chunk from spread/liquidity,
                // - refine with profit search.
                ArbitrageLogic.IterationConfig memory iterConfig;
                iterConfig.minSpreadBps = minSpreadBps;
                iterConfig
                    .chunkSpreadConsumptionBps = CHUNK_SPREAD_CONSUMPTION_BPS;
                iterConfig.bpsDivisor = BPS_DIVISOR;
                iterConfig.maxImpactBps = _MAX_IMPACT_BPS;
                iterConfig.minChunkForStartToken = minChunkStartToken;
                iterConfig.currentStartTokenBalance = sizingBalance;
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

                (chunkToSwap, ) = arbLib.findBestV3Chunk(
                    v3Params,
                    iterConfig.minChunkForStartToken
                );

                if (chunkToSwap == 0) {
                    break;
                }

                sqrtPriceLimitA_v3 = v3Params.sqrtPriceLimitA;
                sqrtPriceLimitB_v3 = v3Params.sqrtPriceLimitB;
            } else if (!isPoolAV3 && !isPoolBV3) {
                // V2/V2 path:
                // start from heuristic candidate, then halve until a profitable chunk survives.
                ArbitrageLogic.V2TradeParams memory v2Params = arbLib
                    .calculateV2TradeParams(
                        poolA_addr,
                        poolB_addr,
                        startToken,
                        intermediateToken,
                        sizingBalance,
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
                        // Monotonic backoff: the first chunk that clears profit thresholds wins.
                        while (true) {
                            lastEstPLFullV2Halving = arbLib.simulateV2V2Profit(
                                testV2Chunk,
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
                // Mixed V2/V3 path:
                // exact optimum is expensive on-chain, so probe from half-balance downward.
                uint256 currentBal = sizingBalance;
                if (currentBal == 0) break;

                // Half-balance is a practical "large first probe":
                // it converges quickly with halving while avoiding full-balance over-commit.
                uint256 initialTestChunk = currentBal / 2;
                if (initialTestChunk > 0) {
                    (chunkToSwap, ) = arbLib.findBestMixedPairChunk(
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
                    if (
                        arbLib.estimateImpactBps(
                            poolA_addr,
                            startToken,
                            chunkToSwap
                        ) > _MAX_IMPACT_BPS
                    ) break;
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

            // Leg 1: startToken -> intermediateToken on pool A.
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
                // Stop cleanly rather than reverting the whole loan: an empty quote
                // here would otherwise discard profit already realized this call.
                if (amountToReceive == 0) break;
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

            // A price-limited leg 1 can legitimately fill for nothing. Leg 2 has no
            // input in that case, so stop here instead of quoting or swapping zero.
            if (intermediateReceived == 0) break;

            bool swap2Success = false;
            // Leg 2: intermediateToken -> startToken on pool B.
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
                if (amountToReceive2 == 0) break;
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

            // Greedy stop: once marginal iteration profit turns non-positive,
            // additional size usually worsens execution due to local curve impact.
            if (currentIterationProfit <= 0) break;
            unchecked {
                ++i;
            }
        }
        uint256 balanceBeforeUnwind = IERC20(startToken).balanceOf(
            address(this)
        );

        uint256 remainingInterm = _intermediateResidue(
            intermediateTokenContract,
            intermediateAtEntry
        );
        if (remainingInterm > 0) {
            // Residue must be cleared for the flash callback's exact-restoration
            // check to pass, so this runs for every intermediate token and
            // regardless of running profit. A partially filled leg 2 is the common
            // cause; leaving it unwound would abort an otherwise viable route.
            // Pool B is where leg 2 already sells the intermediate, so try it
            // first and fall back to pool A.
            _unwindResidue(
                poolB_addr,
                poolBType,
                intermediateToken,
                startToken,
                remainingInterm
            );

            remainingInterm = _intermediateResidue(
                intermediateTokenContract,
                intermediateAtEntry
            );
            if (remainingInterm > 0) {
                _unwindResidue(
                    poolA_addr,
                    poolAType,
                    intermediateToken,
                    startToken,
                    remainingInterm
                );
            }

            if (
                _intermediateResidue(
                    intermediateTokenContract,
                    intermediateAtEntry
                ) > 0
            ) {
                revert ArbErrors.UnwindFailed();
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

        return (true, cumulativeProfit, iterations, totalAmountSwapped);
    }

    /// @dev Intermediate tokens acquired by the in-flight route, excluding any
    ///      balance the hook already held when the route started.
    function _intermediateResidue(
        IERC20 intermediateTokenContract,
        uint256 intermediateAtEntry
    ) private view returns (uint256) {
        uint256 balance = intermediateTokenContract.balanceOf(address(this));
        unchecked {
            return balance > intermediateAtEntry
                ? balance - intermediateAtEntry
                : 0;
        }
    }

    /// @dev Best-effort conversion of leftover intermediate tokens back to the start
    ///      token. Handles V2 pools as well as V3 so a V2/V2 route can also unwind.
    function _unwindResidue(
        address poolAddress,
        ArbUtils.PoolType poolType,
        address intermediateToken,
        address startToken,
        uint256 amount
    ) private {
        if (
            poolType == ArbUtils.PoolType.V3 ||
            poolType == ArbUtils.PoolType.PANCAKESWAP_V3
        ) {
            bool zeroForOne = poolMetaByAddr[poolAddress].token0 ==
                intermediateToken;
            _executeSwapInternal_noBalanceCheck(
                poolAddress,
                poolType,
                intermediateToken,
                startToken,
                amount,
                zeroForOne
                    ? uint160(4295128739) + 1
                    : uint160(
                        1461446703485210103287273052203988822378723970342
                    ) - 1
            );
            return;
        }

        (uint112 reserveInterm, uint112 reserveStart, ) = arbLib
            ._getV2ReservesForTokens(
                IUniswapV2Pair(poolAddress),
                intermediateToken,
                startToken
            );
        uint256 amountOut = arbLib.getAmountOut(
            amount,
            reserveInterm,
            reserveStart,
            _v2FeeForPoolType(poolType)
        );
        if (amountOut == 0) return;
        _executeV2FlashSwap(
            IUniswapV2Pair(poolAddress),
            startToken,
            amountOut,
            intermediateToken,
            amount
        );
    }

    // ----------------------- Swap helpers (V3/V2) --------------------------
    function _executeV4Swap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) private returns (uint256 paid, uint256 received) {
        if (amountIn > uint256(type(int256).max))
            revert ArbErrors.FlashArbitrageExecutionFailed();

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            bytes("")
        );
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0)
            revert ArbErrors.FlashArbitrageExecutionFailed();

        paid = uint256(-int256(inputDelta));
        received = uint256(uint128(outputDelta));
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;

        poolManager.sync(inputCurrency);
        IERC20(Currency.unwrap(inputCurrency)).safeTransfer(
            address(poolManager),
            paid
        );
        poolManager.settle();
        poolManager.take(outputCurrency, address(this), received);
    }

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

        _setActiveSwapContextHash(keccak256(abi.encode(poolAddress, data)));
        if (poolType == ArbUtils.PoolType.V3) {
            try
                IUniswapV3Pool(poolAddress).swap(
                    address(this),
                    zeroForOne,
                    int256(amountIn),
                    sqrtPriceLimitX96,
                    data
                )
            returns (int256, int256) {
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
            returns (int256, int256) {
                success = true;
            } catch {
                success = false;
            }
        }
        // The callback consumes the context; this clears it when no callback ran.
        _setActiveSwapContextHash(bytes32(0));
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
        _consumeActiveSwapCallback(data);
        (
            address decodedTokenIn,
            address decodedCaller,
            ,
            address expectedPool
        ) = abi.decode(data, (address, address, uint256, address));

        // Callback hardening:
        // - call must originate from this contract's initiated swap payload,
        // - caller must be the exact pool we encoded,
        // - pool must be registered in our pool book.
        if (decodedCaller != address(this)) {
            revert ArbErrors.CallbackCallerMismatch();
        }
        if (msg.sender != expectedPool) {
            revert ArbErrors.CallbackUnexpectedPool();
        }

        address pool = msg.sender;
        address token0;
        address token1;

        // Use cached pool metadata instead of fresh external reads.
        PoolMeta storage pm = poolMetaByAddr[pool];
        if (!pm.exists)
            revert ArbErrors.CallbackUnexpectedPool();
        token0 = pm.token0;
        token1 = pm.token1;

        if (decodedTokenIn != token0 && decodedTokenIn != token1) {
            revert ArbErrors.CallbackDecodedTokenNotInPool();
        }

        uint256 amountToPay;
        address tokenToPay;
        if (decodedTokenIn == token0) {
            // Positive amount0Delta means pool expects token0 repayment from this callback.
            if (amount0Delta <= 0) revert ArbErrors.CallbackInvalidDelta0Sign();
            amountToPay = uint256(amount0Delta);
            tokenToPay = token0;
        } else {
            // Positive amount1Delta means pool expects token1 repayment from this callback.
            if (amount1Delta <= 0) revert ArbErrors.CallbackInvalidDelta1Sign();
            amountToPay = uint256(amount1Delta);
            tokenToPay = token1;
        }

        if (amountToPay > 0) {
            bool ok = IERC20(tokenToPay).transfer(pool, amountToPay);
            if (!ok) revert ArbErrors.ERC20TransferFailed();
        }
    }

    function uniswapV2Call(
        address /*sender*/,
        uint256 /*amount0*/,
        uint256 /*amount1*/,
        bytes calldata data
    ) external {
        _v2SwapCallback(data);
    }

    function pancakeCall(
        address /*sender*/,
        uint256 /*amount0*/,
        uint256 /*amount1*/,
        bytes calldata data
    ) external {
        _v2SwapCallback(data);
    }

    function _v2SwapCallback(bytes calldata data) private {
        _consumeActiveSwapCallback(data);
        (address tokenToPay, uint256 amountToPay) = abi.decode(
            data,
            (address, uint256)
        );

        IUniswapV2Pair pair = IUniswapV2Pair(msg.sender);
        address t0 = pair.token0();
        address t1 = pair.token1();
        // Verify msg.sender is a canonical pair from one of the trusted factories.
        if (
            msg.sender != V2_FACTORY.getPair(t0, t1) &&
            msg.sender != PANCAKESWAP_V2_FACTORY.getPair(t0, t1)
        ) {
            revert ArbErrors.CallbackUnexpectedPool();
        }
        _requireRegisteredV2CallbackPool(msg.sender, t0, t1);
        if (tokenToPay != t0 && tokenToPay != t1) {
            revert ArbErrors.CallbackDecodedTokenNotInPool();
        }
        if (amountToPay > 0) {
            IERC20(tokenToPay).safeTransfer(msg.sender, amountToPay);
        }
    }

    /// @dev Validates and immediately consumes the installed swap context. Each
    ///      pool swap this hook initiates expects exactly one repayment callback,
    ///      so a single-use context stops a pool from being paid more than once
    ///      inside its own swap.
    function _consumeActiveSwapCallback(bytes calldata data) private {
        bytes32 context = _activeSwapContextHash();
        if (
            context == bytes32(0) ||
            context != keccak256(abi.encode(msg.sender, data))
        ) revert ArbErrors.CallbackUnexpectedPool();
        _setActiveSwapContextHash(bytes32(0));
    }

    // ----------------------- Internal helpers ------------------------------
    function _revertSelector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
    }

    function _resolveProfitRecipient(
        bytes calldata hookData
    ) internal pure returns (address recipient) {
        if (hookData.length != 20) return address(0);
        assembly ("memory-safe") {
            recipient := shr(96, calldataload(hookData.offset))
        }
    }

    function _flashContextHash(
        address lender,
        address token,
        uint256 amount,
        bytes memory data
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(lender, token, amount, data));
    }

    function _clearActiveFlashContext() private {
        _tstore(_T_LENDER, 0);
        _tstore(_T_LOAN_TOKEN, 0);
        _tstore(_T_LOAN_AMOUNT, 0);
        _tstore(_T_FLASH_CONTEXT, 0);
    }

    function _deriveV2Principal(
        address poolA,
        address poolB,
        address startToken,
        address intermediateToken,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType,
        uint256 principalCap
    ) internal view returns (uint256 principal, uint256 expectedProfit) {
        ArbitrageLogic.V2TradeParams memory params = arbLib.calculateV2TradeParams(
            poolA,
            poolB,
            startToken,
            intermediateToken,
            principalCap,
            _minChunk(startToken),
            _v2FeeForPoolType(poolAType),
            _v2FeeForPoolType(poolBType)
        );
        if (!params.opportunityExists || params.expectedProfitFromChunk <= 0) return (0, 0);

        // The unchanged V2 executor starts at no more than half its balance.
        // Fund twice its selected chunk so that exact candidate is available.
        uint256 chunk = params.estimatedChunkToSwap;
        principal = chunk > principalCap / 2 ? principalCap : chunk * 2;
        expectedProfit = uint256(params.expectedProfitFromChunk);
    }

    function _deriveMixedPrincipal(
        address poolA,
        address poolB,
        address startToken,
        address intermediateToken,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType,
        uint256 principalCap
    ) internal view returns (uint256 principal, uint256 expectedProfit) {
        (uint256 chunk, int256 estimatedProfit) = arbLib.findBestMixedPairChunk(
            poolA,
            poolB,
            poolAType,
            poolBType,
            startToken,
            intermediateToken,
            principalCap / 2,
            _minChunk(startToken),
            0,
            int256(_minChunk(startToken)) / 10
        );
        if (chunk == 0 || estimatedProfit <= 0) return (0, 0);

        principal = chunk > principalCap / 2 ? principalCap : chunk * 2;
        expectedProfit = uint256(estimatedProfit);
    }

    /// @dev Determines the V3/V3 flash principal with the same bounded liquidity,
    ///      spread, and impact calculation used by execution. The coarse upper bound
    ///      is borrowed so executeIterativeArb retains its original binary-search range.
    ///      Funding only the refined chunk was measured against the fixed-block gate
    ///      and is wrong: the executor re-derives its range from its own balance, so a
    ///      tighter loan collapses the search window and the selected chunk with it.
    ///      Any fee paid on unused principal is the cost of that two-phase sizing; a
    ///      zero-fee lender makes it free without touching route selection.
    function _deriveV3Principal(
        address poolA,
        address poolB,
        address startToken,
        address intermediateToken,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType,
        uint256 principalCap
    ) internal view returns (uint256 principal, uint256 refinedPrincipal, uint256 edgeScore) {
        if (principalCap == 0) return (0, 0, 0);

        (bool tickAOk, int24 tickA) = _tryReadV3Tick(poolA, poolAType);
        (bool tickBOk, int24 tickB) = _tryReadV3Tick(poolB, poolBType);
        if (!tickAOk || !tickBOk) return (0, 0, 0);

        address poolAToken0 = poolMetaByAddr[poolA].token0;
        if (poolAToken0 == address(0)) return (0, 0, 0);

        int24 signedSpread = poolAToken0 == startToken ? tickA - tickB : tickB - tickA;
        int24 initialAbsSpread = signedSpread >= 0 ? signedSpread : -signedSpread;
        if (initialAbsSpread < int24(uint24(minSpreadBps))) return (0, 0, 0);

        ArbitrageLogic.IterationConfig memory config;
        config.minSpreadBps = minSpreadBps;
        config.chunkSpreadConsumptionBps = CHUNK_SPREAD_CONSUMPTION_BPS;
        config.bpsDivisor = BPS_DIVISOR;
        config.maxImpactBps = _MAX_IMPACT_BPS;
        config.minChunkForStartToken = _minChunk(startToken);
        config.currentStartTokenBalance = principalCap;
        config.initialAbsSpread = initialAbsSpread;

        ArbitrageLogic.V3SwapParams memory params =
            arbLib.getV3SwapParameters(poolA, poolB, startToken, intermediateToken, config, poolAType, poolBType);
        if (!params.shouldContinue) return (0, 0, 0);

        int256 score;
        (refinedPrincipal, score) = arbLib.findBestV3Chunk(params, config.minChunkForStartToken);
        if (refinedPrincipal == 0) return (0, 0, 0);

        return (params.chunkToSwap, refinedPrincipal, uint256(score));
    }

    function _tryReadV3Tick(address pool, ArbUtils.PoolType poolType) private view returns (bool ok, int24 tick) {
        if (poolType == ArbUtils.PoolType.V3) {
            try IUniswapV3Pool(pool).slot0() returns (uint160, int24 poolTick, uint16, uint16, uint16, uint8, bool) {
                return (true, poolTick);
            } catch {
                return (false, 0);
            }
        }

        try IPancakeV3Pool(pool).slot0() returns (uint160, int24 poolTick, uint16, uint16, uint16, uint32, bool) {
            return (true, poolTick);
        } catch {
            return (false, 0);
        }
    }

    function _resolvePrincipalCap(address token) private view returns (uint256) {
        return _resolvePrincipalCap(token, lenderByToken[token]);
    }

    function _resolvePrincipalCap(
        address token,
        address lender
    ) private view returns (uint256) {
        uint256 configuredCap = flashPrincipalByToken[token];
        if (configuredCap == 0 || lender == address(0)) return 0;

        try IERC3156FlashLender(lender).maxFlashLoan(token) returns (
            uint256 available
        ) {
            return configuredCap < available ? configuredCap : available;
        } catch {
            return 0;
        }
    }

    function _feeExceedsCap(
        uint256 amount,
        uint256 fee,
        uint256 maxFeeBps
    ) private pure returns (bool) {
        uint256 product = amount * maxFeeBps;
        uint256 maxFee = product / FEE_BPS_DIVISOR;
        if (product % FEE_BPS_DIVISOR != 0) ++maxFee;
        return fee > maxFee;
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
            revert ArbErrors.CallbackUnexpectedPool();
        }
    }

    // ---------------------------- Treasury ---------------------------------
    receive() external payable {}

    function removeEth() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    function removeTokens(address token) external onlyOwner {
        IERC20(token).safeTransfer(
            msg.sender,
            IERC20(token).balanceOf(address(this))
        );
    }
}
