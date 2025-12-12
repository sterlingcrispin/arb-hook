// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @title Router token swapping functionality for Uniswap V4
/// @notice Functions for swapping tokens via Uniswap V4
/// @dev This is a simplified placeholder interface as V4 is still evolving
interface IV4SwapRouter {
    /// @notice Performs a swap using Uniswap V4 hooks
    /// @param poolKey The key identifying the pool
    /// @param recipient The address that will receive the output tokens
    /// @param amountIn The amount of the input token
    /// @param amountOutMinimum The minimum amount of the output token to receive
    /// @param sqrtPriceLimitX96 The price limit. If zero, no price limit
    /// @return amountOut The amount of output token received
    function exactInputSingle(
        bytes32 poolKey,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint160 sqrtPriceLimitX96
    ) external payable returns (uint256 amountOut);

    /// @notice Gets a quote for a swap without executing it
    /// @param poolKey The key identifying the pool
    /// @param recipient The address that would receive the output tokens
    /// @param amountIn The amount of the input token
    /// @return amountOut The amount of output token that would be received
    function quoteExactInputSingle(
        bytes32 poolKey,
        address recipient,
        uint256 amountIn
    ) external view returns (uint256 amountOut);
}
