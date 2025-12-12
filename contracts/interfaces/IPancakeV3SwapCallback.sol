// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PancakeSwap V3 Swap Callback Interface
/// @notice For contracts that call PancakeV3Pool#swap
interface IPancakeV3SwapCallback {
    /// @notice Called to `msg.sender` after executing a swap via PancakeV3Pool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    /// The caller of this method must be checked to be a PancakeV3Pool deployed by the canonical PancakeV3Factory.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by the end of the swap.
    /// If positive, the callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by the end of the swap.
    /// If positive, the callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the PancakeV3Pool#swap call.
    function pancakeV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}
