// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../ArbUtils.sol";

/// @notice ABI shared by the hook's self-only wrappers and the delegatecalled
///         execution implementation. These selectors intentionally remain
///         stable on ArbHook for existing integrations.
interface IArbExecutor {
    function attemptAllInternal(uint256 maxIterations) external returns (bool success);

    function executeIterativeArb(
        address poolA,
        address poolB,
        address startToken,
        address intermediateToken,
        uint256 maxIterations,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType
    ) external returns (bool success, int256 cumulativeProfit, uint256 iterations);
}
