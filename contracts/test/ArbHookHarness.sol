// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArbHook} from "../ArbHook.sol";
import {ArbUtils} from "../ArbUtils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Simple harness that exposes internal entrypoints for testing.
contract ArbHookHarness is ArbHook {
    constructor(
        IPoolManager poolManager,
        address owner,
        address arbLib,
        address dataStorage
    ) ArbHook(poolManager, owner, arbLib, dataStorage) {}

    function attemptAllForTest(uint256 iterations) external onlyOwner returns (bool) {
        return _attemptAllViaSelfCall(iterations);
    }

    function runPairForTest(
        address tokenA,
        address tokenB,
        uint256 maxIter
    ) external onlyOwner returns (int256 profit, uint256 iterations) {
        return _runPair(tokenA, tokenB, maxIter);
    }

    function runFlashArbForTest(
        address poolA,
        address poolB,
        address tokenA,
        address tokenB,
        uint256 maxIter,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType
    ) external onlyOwner returns (bool success, int256 profit, uint256 iterations) {
        (bool callOk, bytes memory returndata) = address(this).call(
            abi.encodeWithSelector(
                this.executeIterativeArbViaFlash.selector,
                poolA,
                poolB,
                tokenA,
                tokenB,
                maxIter,
                poolAType,
                poolBType
            )
        );
        if (!callOk) return (false, 0, 0);
        return abi.decode(returndata, (bool, int256, uint256));
    }
}
