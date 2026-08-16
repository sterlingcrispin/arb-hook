// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArbitrageLogic} from "./ArbitrageLogic.sol";
import {ArbUtils} from "./ArbUtils.sol";
import {ArbErrors} from "./Errors.sol";
import {IPancakeV3Pool} from "./interfaces/IPancakeV3Pool.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IArbHookExecutorHost {
    function executeIterativeArb(
        address poolA,
        address poolB,
        address startToken,
        address intermediateToken,
        uint256 maxIterations,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType
    ) external returns (bool, int256, uint256, uint256);
}

/// @notice Stateless V4/V3 execution module invoked in ArbHook's context.
contract V4ArbExecutor {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    struct ExecutionParams {
        address pricingEngine;
        IPoolManager manager;
        PoolKey key;
        address startToken;
        address intermediateToken;
        ArbUtils.PoolInfo externalPool;
        ArbitrageLogic.IterationConfig config;
        uint256 maxIterations;
    }

    struct LoopState {
        int256 profit;
        uint256 iterations;
        uint256 amountSwapped;
    }

    /// @dev Must run through delegatecall so PoolManager and V3 pools see ArbHook.
    function execute(address pricingEngine, IPoolManager manager, bytes calldata flashData, uint256 principal)
        external
        returns (bool, int256, uint256, uint256)
    {
        ArbUtils.FlashLoanExecutionParams memory flashParams;
        PoolKey memory key;
        ArbUtils.PoolInfo memory externalPool;
        ArbitrageLogic.IterationConfig memory config;
        flashParams = abi.decode(flashData, (ArbUtils.FlashLoanExecutionParams));

        if (flashParams.sellPool != address(manager)) {
            (bool successCall, bytes memory returndata) = address(this)
                .call(
                    abi.encodeCall(
                        IArbHookExecutorHost.executeIterativeArb,
                        (
                            flashParams.sellPool,
                            flashParams.buyPool,
                            flashParams.tokenA,
                            flashParams.tokenB,
                            flashParams.maxIterations,
                            flashParams.sellPoolType,
                            flashParams.buyPoolType
                        )
                    )
                );
            if (!successCall) {
                revert ArbErrors.FlashArbitrageExecutionFailed();
            }
            return abi.decode(returndata, (bool, int256, uint256, uint256));
        }

        (flashParams, key, externalPool, config) = abi.decode(
            flashData, (ArbUtils.FlashLoanExecutionParams, PoolKey, ArbUtils.PoolInfo, ArbitrageLogic.IterationConfig)
        );

        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (
            address(key.hooks) != address(this)
                || !((currency0 == flashParams.tokenA && currency1 == flashParams.tokenB)
                    || (currency1 == flashParams.tokenA && currency0 == flashParams.tokenB))
                || externalPool.poolAddress != flashParams.buyPool || externalPool.poolType != flashParams.buyPoolType
        ) revert ArbErrors.FlashTokenMismatch();

        config.currentStartTokenBalance = principal;
        ExecutionParams memory execution = ExecutionParams({
            pricingEngine: pricingEngine,
            manager: manager,
            key: key,
            startToken: flashParams.tokenA,
            intermediateToken: flashParams.tokenB,
            externalPool: externalPool,
            config: config,
            maxIterations: flashParams.maxIterations
        });
        return _execute(execution);
    }

    function _execute(ExecutionParams memory execution) private returns (bool, int256, uint256, uint256) {
        IERC20 intermediate = IERC20(execution.intermediateToken);
        uint256 intermediateAtEntry = intermediate.balanceOf(address(this));
        ArbitrageLogic.IterationConfig memory config = execution.config;
        LoopState memory state;

        for (uint256 i; i < execution.maxIterations;) {
            config.currentStartTokenBalance = execution.config.currentStartTokenBalance;
            if (state.profit > 0) {
                config.currentStartTokenBalance += uint256(state.profit);
            }

            (bool completed, int256 profit, uint256 paid) = _executeIteration(execution, config);
            state.amountSwapped += paid;
            if (!completed) break;
            state.profit += profit;
            unchecked {
                ++state.iterations;
            }
            if (profit <= 0) break;
            unchecked {
                ++i;
            }
        }

        state.profit += _unwind(execution, intermediateAtEntry);
        return (state.iterations > 0, state.profit, state.iterations, state.amountSwapped);
    }

    function _executeIteration(ExecutionParams memory execution, ArbitrageLogic.IterationConfig memory config)
        private
        returns (bool completed, int256 profit, uint256 paid)
    {
        ArbitrageLogic.V4V3RouteParams memory route = ArbitrageLogic(execution.pricingEngine)
            .getLiveV4V3RouteParams(
                execution.manager,
                execution.key.toId(),
                Currency.unwrap(execution.key.currency0),
                execution.startToken,
                execution.intermediateToken,
                execution.externalPool,
                config
            );
        if (route.principal == 0) return (false, 0, 0);

        IERC20 start = IERC20(execution.startToken);
        uint256 balanceBefore = start.balanceOf(address(this));
        uint256 intermediateReceived;
        (paid, intermediateReceived) = _swapV4(
            execution.manager,
            execution.key,
            Currency.unwrap(execution.key.currency0) == execution.startToken,
            route.principal,
            route.sqrtPriceLimitX96
        );
        if (!_swapV3(
                execution.externalPool,
                execution.intermediateToken,
                execution.startToken,
                intermediateReceived,
                route.externalSqrtPriceLimitX96
            )) return (false, 0, paid);

        profit = int256(start.balanceOf(address(this))) - int256(balanceBefore);
        completed = true;
    }

    function _unwind(ExecutionParams memory execution, uint256 intermediateAtEntry) private returns (int256 profit) {
        IERC20 start = IERC20(execution.startToken);
        IERC20 intermediate = IERC20(execution.intermediateToken);
        uint256 balanceBefore = start.balanceOf(address(this));
        uint256 intermediateBalance = intermediate.balanceOf(address(this));
        if (intermediateBalance > intermediateAtEntry) {
            uint256 residue;
            unchecked {
                residue = intermediateBalance - intermediateAtEntry;
            }
            _swapV3(
                execution.externalPool,
                execution.intermediateToken,
                execution.startToken,
                residue,
                execution.externalPool.token0 == execution.intermediateToken
                    ? TickMath.MIN_SQRT_RATIO + 1
                    : TickMath.MAX_SQRT_RATIO - 1
            );
            if (intermediate.balanceOf(address(this)) != intermediateAtEntry) {
                revert ArbErrors.UnwindFailed();
            }
        }

        uint256 balanceAfter = start.balanceOf(address(this));
        if (balanceAfter != balanceBefore) {
            profit = int256(balanceAfter) - int256(balanceBefore);
        }
    }

    function _swapV4(
        IPoolManager manager,
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) private returns (uint256 paid, uint256 received) {
        if (amountIn > uint256(type(int256).max)) {
            revert ArbErrors.FlashArbitrageExecutionFailed();
        }

        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            bytes("")
        );
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) {
            revert ArbErrors.FlashArbitrageExecutionFailed();
        }

        paid = uint256(-int256(inputDelta));
        received = uint256(uint128(outputDelta));
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        manager.sync(inputCurrency);
        IERC20(Currency.unwrap(inputCurrency)).safeTransfer(address(manager), paid);
        manager.settle();
        manager.take(outputCurrency, address(this), received);
    }

    function _swapV3(
        ArbUtils.PoolInfo memory pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) private returns (bool success) {
        bool zeroForOne;
        if (pool.token0 == tokenIn && pool.token1 == tokenOut) {
            zeroForOne = true;
        } else if (pool.token1 == tokenIn && pool.token0 == tokenOut) {
            zeroForOne = false;
        } else {
            revert ArbErrors.SwapInputTokenNotInPool();
        }

        bytes memory data = abi.encode(tokenIn, address(this), amountIn, pool.poolAddress);
        _setSwapContext(keccak256(abi.encode(pool.poolAddress, data)));
        if (pool.poolType == ArbUtils.PoolType.V3) {
            try IUniswapV3Pool(pool.poolAddress)
                .swap(address(this), zeroForOne, int256(amountIn), sqrtPriceLimitX96, data) returns (
                int256, int256
            ) {
                success = true;
            } catch {}
        } else if (pool.poolType == ArbUtils.PoolType.PANCAKESWAP_V3) {
            try IPancakeV3Pool(pool.poolAddress)
                .swap(address(this), zeroForOne, int256(amountIn), sqrtPriceLimitX96, data) returns (
                int256, int256
            ) {
                success = true;
            } catch {}
        }
        _setSwapContext(bytes32(0));
    }

    /// @dev ArbUtils reserves transient slot zero for the active swap context.
    function _setSwapContext(bytes32 context) private {
        assembly ("memory-safe") {
            tstore(0, context)
        }
    }
}
