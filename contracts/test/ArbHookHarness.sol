// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArbHook} from "../ArbHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// @notice Simple harness that exposes internal entrypoints for testing.
contract ArbHookHarness is ArbHook {
    constructor(IPoolManager poolManager, address owner, address arbLib, address dataStorage, address arbExecutor)
        ArbHook(poolManager, owner, arbLib, dataStorage, arbExecutor)
    {}

    /// @dev Tests deploy the harness at an arbitrary address rather than a
    ///      CREATE2-mined hook-permission address.
    function validateHookAddress(BaseHook) internal pure override {}

    function attemptAllForTest(uint256 iterations) external onlyOwner returns (bool) {
        return _attemptAllViaSelfCall(iterations);
    }

    function failedQuoteForTest(bytes32 quoteKey) external view returns (uint128 qBuy, uint128 qSell) {
        FailedQuote storage quote = lastFailedQuote[quoteKey];
        return (quote.qBuy, quote.qSell);
    }

    function failedAttemptForTest(bytes32 pairKey)
        external
        view
        returns (address buyPool, address sellPool, uint128 qBuy, uint128 qSell)
    {
        FailedAttempt storage attempt = lastFailedAttemptForPair[pairKey];
        return (attempt.buyPool, attempt.sellPool, attempt.qBuy, attempt.qSell);
    }
}
