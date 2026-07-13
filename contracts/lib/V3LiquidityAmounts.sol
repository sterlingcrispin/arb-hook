// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Minimal liquidity-delta helpers needed by the arbitrage sizing path.
/// @dev Derived from the corresponding Uniswap V3 periphery formulas, retained
///      locally to avoid pulling an entire periphery dependency into production.
library V3LiquidityAmounts {
    uint256 private constant Q96 = uint256(1) << 96;

    function getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }

        return FullMath.mulDiv(uint256(liquidity) << 96, uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96), sqrtRatioBX96)
            / sqrtRatioAX96;
    }

    function getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }

        return FullMath.mulDiv(liquidity, uint256(sqrtRatioBX96) - uint256(sqrtRatioAX96), Q96);
    }
}
