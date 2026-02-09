// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArbHook} from "../ArbHook.sol";
import {ArbUtils} from "../ArbUtils.sol";
import {IDataStorage} from "../interfaces/IDataStorage.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Simple harness that exposes internal entrypoints for testing.
contract ArbHookHarness is ArbHook {
    using SafeERC20 for IERC20;

    uint256 public testProfitBps;
    bool public testInjectProfitAnyIterations;
    address public testProfitPayer;
    uint256 public testFixedProfitAmount;

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

    function runFlashArbWithContextForTest(
        address sender,
        bytes calldata hookData,
        address poolA,
        address poolB,
        address tokenA,
        address tokenB,
        uint256 maxIter,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType
    ) external onlyOwner returns (bool success, int256 profit, uint256 iterations) {
        // Mirrors _afterSwap recipient resolution for routing-focused tests.
        activeAttemptProfitRecipient = _resolveProfitRecipient(sender, hookData);
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
        activeAttemptProfitRecipient = address(0);
        if (!callOk) return (false, 0, 0);
        return abi.decode(returndata, (bool, int256, uint256));
    }

    function setTestProfitBps(uint256 bps) external onlyOwner {
        testProfitBps = bps;
    }

    function setTestInjectProfitAnyIterations(bool enabled) external onlyOwner {
        testInjectProfitAnyIterations = enabled;
    }

    function setTestProfitTransfer(address payer, uint256 amount) external onlyOwner {
        testProfitPayer = payer;
        testFixedProfitAmount = amount;
    }

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
        override
        returns (bool success, int256 cumulativeProfit, uint256 iterations)
    {
        if (
            testProfitBps > 0 &&
            (maxIterations == 0 || testInjectProfitAnyIterations)
        ) {
            uint256 bal = IERC20(startToken).balanceOf(address(this));
            uint256 realizedProfit;

            if (testFixedProfitAmount > 0) {
                require(testProfitPayer != address(0), "test profit payer=0");
                IERC20(startToken).safeTransferFrom(
                    testProfitPayer,
                    address(this),
                    testFixedProfitAmount
                );
                realizedProfit = testFixedProfitAmount;
            } else {
                uint256 mintAmount = (bal * testProfitBps) / 10_000;
                if (mintAmount > 0) {
                    // Test token only; used in flash-loan E2E tests to simulate profitable execution.
                    (bool ok, ) = startToken.call(
                        abi.encodeWithSignature(
                            "mint(address,uint256)",
                            address(this),
                            mintAmount
                        )
                    );
                    require(ok, "test mint failed");
                }
                realizedProfit = mintAmount;
            }

            lastTradeData = IDataStorage.TradeData({
                tokenA: startToken,
                tokenB: intermediateToken,
                buyPool: poolB_addr,
                sellPool: poolA_addr,
                buyPoolIndex: _getPoolIndex(startToken, poolB_addr),
                sellPoolIndex: _getPoolIndex(startToken, poolA_addr),
                totalAmountSwapped: bal,
                profit: realizedProfit,
                iterations: 1,
                timestamp: block.timestamp
            });
            return (true, int256(realizedProfit), 1);
        }

        return
            super.executeIterativeArb(
                poolA_addr,
                poolB_addr,
                startToken,
                intermediateToken,
                maxIterations,
                poolAType,
                poolBType
            );
    }
}
