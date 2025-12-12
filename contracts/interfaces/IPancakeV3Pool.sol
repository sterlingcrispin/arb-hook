// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// This interface is needed because PancakeSwap V3's `slot0` function
// has a different return signature than Uniswap V3's.
// Specifically, `feeProtocol` is a `uint32` instead of a `uint8`.
interface IPancakeV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );

    function fee() external view returns (uint24);

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    function token0() external view returns (address);
    function token1() external view returns (address);
}
