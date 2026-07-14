// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Executes bounded on-chain arbitrage attempts from Uniswap v4 swap callbacks.
import "./ArbUtils.sol";
import "./ArbExecutionStorage.sol";
import "./ArbitrageLogic.sol";
import {ArbErrors} from "./Errors.sol";
import {IArbExecutor} from "./interfaces/IArbExecutor.sol";

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IPancakeV3Pool} from "./interfaces/IPancakeV3Pool.sol";
import {IDataStorage} from "./interfaces/IDataStorage.sol";

/// @title ArbHook
/// @notice Uniswap v4 hook that performs bounded, on-chain arbitrage across
///         registered external pools during swap callbacks. It owns pool
///         registration, price discovery, sizing, execution, and callback safety
///         checks in one contract.
contract ArbHook is BaseHook, ArbExecutionStorage, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Immutable implementation used only through delegatecall by the
    ///         self-only execution wrappers below.
    IArbExecutor public immutable arbExecutor;

    /// @notice Pool keys for which afterSwap may trigger best-effort routing.
    ///         Unlisted V4 pools always receive a no-op hook response.
    mapping(bytes32 => bool) public hookPoolEnabled;

    // Default max iterations when attempting arb via hook callbacks (0 disables hook execution)
    uint256 public hookMaxIterations;
    uint256 public constant MAX_HOOK_ITERATIONS = 10;

    // Trusted factories for callback validation
    IUniswapV2Factory private constant V2_FACTORY = IUniswapV2Factory(0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6);
    IUniswapV2Factory private constant PANCAKESWAP_V2_FACTORY =
        IUniswapV2Factory(0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E);

    event AttemptAllFailed(bytes revertData);
    event HookAttemptAll(uint256 iterations, bool callSuccess, bool tradeProfitable);
    event HookPoolEnabled(bytes32 indexed poolKeyHash, bool enabled);
    event MaxFlashTradeAmountSet(address indexed token, uint256 amount);

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (!hookPoolEnabled[_poolKeyHash(key)]) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // Hook path is best-effort only: trade failure must never block user swap settlement.
        uint256 iterations = hookMaxIterations;
        if (iterations > 0) {
            _attemptAllViaSelfCall(iterations);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function _attemptAllViaSelfCall(uint256 iterations) internal returns (bool) {
        // Self-call gives us a hard failure boundary:
        // any revert in deep execution is captured as bytes and does not bubble.
        (bool successCall, bytes memory returndata) =
            address(this).call(abi.encodeWithSelector(this.attemptAllInternal.selector, iterations));

        bool tradeSuccess = false;
        if (!successCall) {
            emit AttemptAllFailed(returndata);
        } else {
            tradeSuccess = abi.decode(returndata, (bool));
        }

        emit HookAttemptAll(iterations, successCall, tradeSuccess);
        return successCall && tradeSuccess;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
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

    /// @dev Production deployments must use a CREATE2 address whose low bits
    ///      encode this hook's permissions. Test harnesses may override this.
    function validateHookAddress(BaseHook _this) internal pure virtual override {
        super.validateHookAddress(_this);
    }

    constructor(
        IPoolManager _poolManager,
        address initialOwner,
        address _arbLib,
        address _dataStorage,
        address _arbExecutor
    ) BaseHook(_poolManager) Ownable(initialOwner) {
        require(address(_poolManager) != address(0), "poolManager=0");
        if (_arbLib == address(0) || _arbLib.code.length == 0) {
            revert ArbErrors.InvalidArbitrageLogicAddress();
        }
        if (_dataStorage == address(0) || _dataStorage.code.length == 0) {
            revert ArbErrors.InvalidDataStorageAddress();
        }
        if (_arbExecutor == address(0) || _arbExecutor.code.length == 0) {
            revert ArbErrors.ExecutorAddressInvalid();
        }
        arbLib = ArbitrageLogic(_arbLib);
        dataStorage = IDataStorage(_dataStorage);
        arbExecutor = IArbExecutor(_arbExecutor);
        hookMaxIterations = 2;
    }

    // ------------------------------- Admin ---------------------------------
    function setDataStorage(address _dataStorage) external onlyOwner {
        if (_dataStorage == address(0) || _dataStorage.code.length == 0) {
            revert ArbErrors.InvalidDataStorageAddress();
        }
        dataStorage = IDataStorage(_dataStorage);
    }

    function setMinSpreadBps(uint16 _minSpreadBps) external onlyOwner {
        minSpreadBps = _minSpreadBps;
    }

    function setChunkSpreadConsumptionBps(uint16 _chunkSpreadConsumptionBps) external onlyOwner {
        CHUNK_SPREAD_CONSUMPTION_BPS = _chunkSpreadConsumptionBps;
    }

    function setMaxImpactBps(uint256 _maxImpactBps) external onlyOwner {
        _MAX_IMPACT_BPS = _maxImpactBps;
    }

    function setMinProfitToEmit(uint256 newMinProfit) external onlyOwner {
        minProfitToEmit = newMinProfit;
    }

    /// @notice Enables pool-native flash settlement for a start token and caps
    ///         the virtual inventory used by the sizing logic. Set to zero to
    ///         retain the legacy treasury-funded path.
    function setMaxFlashTradeAmount(address token, uint256 amount) external onlyOwner {
        maxFlashTradeAmount[token] = amount;
        emit MaxFlashTradeAmountSet(token, amount);
    }

    function setHookMaxIterations(uint256 newMaxIterations) external onlyOwner {
        if (newMaxIterations > MAX_HOOK_ITERATIONS) {
            revert ArbErrors.HookMaxIterationsExceeded(newMaxIterations, MAX_HOOK_ITERATIONS);
        }
        hookMaxIterations = newMaxIterations;
    }

    function setHookPoolEnabled(PoolKey calldata key, bool enabled) external onlyOwner {
        bytes32 keyHash = _poolKeyHash(key);
        hookPoolEnabled[keyHash] = enabled;
        emit HookPoolEnabled(keyHash, enabled);
    }

    // ------------------------- Pool-book API -------------------------------
    function addPools(
        address token,
        address[] memory poolAddresses,
        uint24[] memory fees,
        ArbUtils.PoolType[] memory poolTypes
    ) external onlyOwner nonReentrant {
        // Registration order matters: it affects supportedTokens/baseCounterList traversal order.
        _addPools(token, poolAddresses, fees, poolTypes);
        // Populate pool meta for callbacks and cheaper checks
        for (uint256 i = 0; i < poolAddresses.length; i++) {
            address p = poolAddresses[i];
            address token0;
            address token1;
            uint24 actualFee;
            if (poolTypes[i] == ArbUtils.PoolType.V3) {
                IUniswapV3Pool vp = IUniswapV3Pool(p);
                token0 = vp.token0();
                token1 = vp.token1();
                actualFee = vp.fee();
            } else if (poolTypes[i] == ArbUtils.PoolType.PANCAKESWAP_V3) {
                IPancakeV3Pool vp = IPancakeV3Pool(p);
                token0 = vp.token0();
                token1 = vp.token1();
                actualFee = vp.fee();
            } else {
                IUniswapV2Pair vp = IUniswapV2Pair(p);
                token0 = vp.token0();
                token1 = vp.token1();
                actualFee = poolTypes[i] == ArbUtils.PoolType.V2 ? V2_POOL_FEE_PPM : PANCAKESWAP_V2_POOL_FEE_PPM;
            }

            PoolMeta storage m = poolMetaByAddr[p];
            if (poolRegistrationCount[p] == 0) {
                m.token0 = token0;
                m.token1 = token1;
                m.fee = actualFee;
                m.poolType = poolTypes[i];
                m.exists = true;
            } else if (
                !m.exists || m.token0 != token0 || m.token1 != token1 || m.fee != actualFee
                    || m.poolType != poolTypes[i]
            ) {
                // One physical pool has one immutable callback ABI. Allowing a
                // second registration to overwrite its type would corrupt the
                // metadata still required by the first registration.
                revert ArbErrors.PoolRegistrationMetadataConflict(p);
            }

            ++poolRegistrationCount[p];

            // Cache decimals for both tokens to make _minChunk cheaper later
            if (m.token0 != address(0) && cachedTokenDecimals[m.token0] == 0) {
                try IERC20Metadata(m.token0).decimals() returns (uint8 d0) {
                    // Preserve genuine zero-decimal tokens. `_minChunk` treats
                    // an uncached/zero entry defensively and still returns 1.
                    cachedTokenDecimals[m.token0] = d0;
                } catch {
                    cachedTokenDecimals[m.token0] = 18;
                }
            }
            if (m.token1 != address(0) && cachedTokenDecimals[m.token1] == 0) {
                try IERC20Metadata(m.token1).decimals() returns (uint8 d1) {
                    cachedTokenDecimals[m.token1] = d1;
                } catch {
                    cachedTokenDecimals[m.token1] = 18;
                }
            }
        }
    }

    function removePool(address token, uint256 idx) external onlyOwner nonReentrant {
        // Keep metadata while the pool remains registered under another base.
        if (idx < tokenPools[token].length) {
            address p = tokenPools[token][idx].poolAddress;
            _releasePoolMeta(p);
        }
        _removePool(token, idx);
    }

    function resetTokenPools(address token) external onlyOwner nonReentrant {
        // Release only this base token's registrations.
        ArbUtils.PoolInfo[] storage pools = tokenPools[token];
        for (uint256 i = 0; i < pools.length; i++) {
            _releasePoolMeta(pools[i].poolAddress);
        }
        _resetTokenPools(token);
    }

    function resetAllPools() external onlyOwner nonReentrant {
        // Release every registration before clearing the pool book.
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address t = supportedTokens[i];
            ArbUtils.PoolInfo[] storage pools = tokenPools[t];
            for (uint256 j = 0; j < pools.length; j++) {
                _releasePoolMeta(pools[j].poolAddress);
            }
        }
        _resetAllPools();
    }

    function getPoolsForToken(address token) external view returns (ArbUtils.PoolInfo[] memory) {
        return tokenPools[token];
    }

    function getSupportedTokenCount() external view returns (uint256) {
        return supportedTokens.length;
    }

    function getAllSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    function approvePools(address tokenAddress, address[] calldata poolAddresses, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        for (uint256 i = 0; i < poolAddresses.length; i++) {
            // Support USDT-style tokens that require a zero reset and reject
            // false-returning approvals instead of silently leaving a route
            // unusable.
            IERC20(tokenAddress).forceApprove(poolAddresses[i], amount);
        }
    }

    // -------------------------- Execution wrappers -------------------------
    /// @notice Evaluates configured pairs through the immutable execution
    ///         implementation. Only a self-call may enter this boundary.
    function attemptAllInternal(uint256 maxIterations) external returns (bool success) {
        if (msg.sender != address(this)) revert ArbErrors.WrapperOnlySelf();
        return abi.decode(
            _delegateToExecutor(abi.encodeWithSelector(IArbExecutor.attemptAllInternal.selector, maxIterations)), (bool)
        );
    }

    /// @notice Preserves the legacy hook ABI while routing the heavy execution
    ///         code through the delegatecalled executor.
    function executeIterativeArb(
        address poolA,
        address poolB,
        address startToken,
        address intermediateToken,
        uint256 maxIterations,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType
    ) external returns (bool success, int256 cumulativeProfit, uint256 iterations) {
        if (msg.sender != address(this)) revert ArbErrors.WrapperOnlySelf();
        return abi.decode(
            _delegateToExecutor(
                abi.encodeWithSelector(
                    IArbExecutor.executeIterativeArb.selector,
                    poolA,
                    poolB,
                    startToken,
                    intermediateToken,
                    maxIterations,
                    poolAType,
                    poolBType
                )
            ),
            (bool, int256, uint256)
        );
    }

    function _delegateToExecutor(bytes memory callData) private returns (bytes memory result) {
        (bool ok, bytes memory returndata) = address(arbExecutor).delegatecall(callData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        return returndata;
    }

    // ----------------------------- Callbacks -------------------------------
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _v3SwapCallbackLogic(amount0Delta, amount1Delta, data, ArbUtils.PoolType.V3, UNISWAP_V3_SWAP_CALLBACK_SELECTOR);
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _v3SwapCallbackLogic(
            amount0Delta, amount1Delta, data, ArbUtils.PoolType.PANCAKESWAP_V3, PANCAKESWAP_V3_SWAP_CALLBACK_SELECTOR
        );
    }

    function _v3SwapCallbackLogic(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data,
        ArbUtils.PoolType expectedPoolType,
        bytes4 expectedCallbackSelector
    ) internal {
        (
            address decodedTokenIn,
            address decodedCaller,
            uint256 maximumAmountIn,
            address expectedPool,
            FlashSecondLeg memory secondLeg
        ) = abi.decode(data, (address, address, uint256, address, FlashSecondLeg));

        // Callback hardening:
        // - call must originate from this contract's initiated swap payload,
        // - caller must be the exact pool we encoded,
        // - pool must be registered in our pool book.
        if (decodedCaller != address(this)) {
            revert ArbErrors.CallbackCallerMismatch(decodedCaller, address(this));
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

        // Use cached pool metadata instead of fresh external reads.
        PoolMeta storage pm = poolMetaByAddr[pool];
        if (!pm.exists || pm.poolType != expectedPoolType) {
            revert ArbErrors.CallbackUnexpectedPool(pool, expectedPool);
        }
        token0 = pm.token0;
        token1 = pm.token1;

        if (decodedTokenIn != token0 && decodedTokenIn != token1) {
            revert ArbErrors.CallbackDecodedTokenNotInPool(decodedTokenIn, token0, token1);
        }

        bool zeroForOne = decodedTokenIn == token0;
        bytes32 expectedContext = _v3SwapContextHash(
            pool,
            expectedPoolType,
            expectedCallbackSelector,
            decodedTokenIn,
            zeroForOne,
            maximumAmountIn,
            keccak256(data)
        );
        if (activeV3SwapContext == bytes32(0) || activeV3SwapContext != expectedContext) {
            revert ArbErrors.V3CallbackContextMismatch();
        }

        uint256 amountToPay;
        address tokenToPay;
        if (zeroForOne) {
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

        if (amountToPay > maximumAmountIn) {
            revert ArbErrors.V3CallbackAmountExceedsMaximum(amountToPay, maximumAmountIn);
        }

        // Consume before the external token call. A reentrant token or pool
        // cannot replay the capability while repayment is in progress.
        delete activeV3SwapContext;

        if (secondLeg.pool != address(0)) {
            int256 outputDelta = zeroForOne ? amount1Delta : amount0Delta;
            if (outputDelta >= 0 || outputDelta == type(int256).min) {
                revert ArbErrors.AtomicArbitrageExecutionFailed();
            }
            _settleFlashSecondLeg(
                secondLeg, pool, zeroForOne ? token1 : token0, tokenToPay, uint256(-outputDelta), amountToPay
            );
        }

        if (!IERC20(tokenToPay).trySafeTransfer(pool, amountToPay)) {
            revert ArbErrors.CallbackTransferFailed(tokenToPay, pool, amountToPay);
        }
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        _v2SwapCallbackLogic(sender, amount0, amount1, data, ArbUtils.PoolType.V2);
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        _v2SwapCallbackLogic(sender, amount0, amount1, data, ArbUtils.PoolType.PANCAKESWAP_V2);
    }

    /// @dev Canonical V2 pairs call a user-selected `to` address. Verify both
    ///      the pair's original caller and the one-shot context created by
    ///      _executeV2FlashSwap before settling the initiating pool.
    function _v2SwapCallbackLogic(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data,
        ArbUtils.PoolType expectedPoolType
    ) private {
        if (sender != address(this)) {
            revert ArbErrors.CallbackCallerMismatch(sender, address(this));
        }

        PoolMeta storage pm = poolMetaByAddr[msg.sender];
        if (!pm.exists || pm.poolType != expectedPoolType) {
            revert ArbErrors.CallbackUnexpectedPool(msg.sender, address(0));
        }

        (address tokenToPay, uint256 amountToPay, FlashSecondLeg memory secondLeg) =
            abi.decode(data, (address, uint256, FlashSecondLeg));

        bytes32 expectedContext = _v2SwapContextHash(
            msg.sender, expectedPoolType, tokenToPay, amountToPay, amount0, amount1, keccak256(data)
        );
        if (activeV2SwapContext == bytes32(0) || activeV2SwapContext != expectedContext) {
            revert ArbErrors.V2CallbackContextMismatch();
        }

        address canonicalPair = expectedPoolType == ArbUtils.PoolType.V2
            ? V2_FACTORY.getPair(pm.token0, pm.token1)
            : PANCAKESWAP_V2_FACTORY.getPair(pm.token0, pm.token1);
        if (msg.sender != canonicalPair) {
            revert ArbErrors.CallbackUnexpectedPool(msg.sender, canonicalPair);
        }

        // Consume before the external token call. A malicious token cannot
        // replay the still-active context during transfer reentrancy.
        delete activeV2SwapContext;

        if (secondLeg.pool != address(0)) {
            address tokenReceived;
            uint256 amountReceived;
            if (tokenToPay == pm.token0 && amount0 == 0) {
                tokenReceived = pm.token1;
                amountReceived = amount1;
            } else if (tokenToPay == pm.token1 && amount1 == 0) {
                tokenReceived = pm.token0;
                amountReceived = amount0;
            } else {
                revert ArbErrors.AtomicArbitrageExecutionFailed();
            }
            _settleFlashSecondLeg(secondLeg, msg.sender, tokenReceived, tokenToPay, amountReceived, amountToPay);
        }

        IERC20(tokenToPay).safeTransfer(msg.sender, amountToPay);
    }

    /// @dev Execute the reverse swap while the first pool is waiting for
    ///      payment, then prove that leg alone returned enough to repay it.
    function _settleFlashSecondLeg(
        FlashSecondLeg memory secondLeg,
        address firstPool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOwed
    ) private {
        if (secondLeg.pool == firstPool) revert ArbErrors.AtomicArbitrageExecutionFailed();

        uint256 amountOut = abi.decode(
            _delegateToExecutor(
                abi.encodeWithSelector(
                    IArbExecutor.executeFlashSecondLeg.selector,
                    secondLeg.pool,
                    secondLeg.poolType,
                    tokenIn,
                    tokenOut,
                    amountIn,
                    secondLeg.sqrtPriceLimitX96
                )
            ),
            (uint256)
        );
        if (amountOut <= amountOwed) revert ArbErrors.FlashSecondLegUnprofitable(amountOut, amountOwed);
    }

    // ----------------------- Internal helpers ------------------------------
    function _poolKeyHash(PoolKey calldata key) private pure returns (bytes32) {
        return keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
    }

    function _releasePoolMeta(address pool) private {
        uint256 registrations = poolRegistrationCount[pool];
        if (registrations <= 1) {
            // `registrations == 0` is retained as a safe fallback for state
            // created before reference counts existed.
            delete poolRegistrationCount[pool];
            delete poolMetaByAddr[pool];
            return;
        }

        unchecked {
            poolRegistrationCount[pool] = registrations - 1;
        }
    }

    // ---------------------------- Treasury ---------------------------------
    receive() external payable {}

    function removeEth() external onlyOwner {
        uint256 amount = address(this).balance;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert ArbErrors.ETHWithdrawalFailed(msg.sender, amount);
    }

    function removeTokens(address token) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, IERC20(token).balanceOf(address(this)));
    }
}
