// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArbHook} from "../ArbHook.sol";
import {ArbUtils} from "../ArbUtils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Simple harness that exposes internal entrypoints for testing.
contract ArbHookHarness is ArbHook {
    using SafeERC20 for IERC20;

    uint256 public testProfitBps;
    bool public testInjectProfitAnyIterations;
    bool public testLegacyInventoryParityEnabled;
    address public testProfitPayer;
    uint256 public testFixedProfitAmount;
    mapping(address => uint256) public testProfitByIntermediateToken;

    event ArbitrageAttempted(
        address indexed tokenA,
        address indexed tokenB,
        address indexed buyPool,
        address sellPool,
        uint256 totalAmountSwapped,
        int256 cumulativeProfit,
        uint256 iterations
    );

    constructor(
        IPoolManager poolManager,
        address owner,
        address arbLib
    ) ArbHook(poolManager, owner, arbLib) {}

    // Production ArbHook validates V4 permission bits. Tests deploy the harness
    // at arbitrary addresses and exercise callback behavior directly.
    function validateHookAddress(ArbHook) internal pure override {}

    function attemptAllForTest(uint256 iterations) external onlyOwner returns (bool) {
        _setActiveProfitRecipient(owner());
        bool success = _attemptAllViaSelfCall(iterations);
        _setActiveProfitRecipient(address(0));
        return success;
    }

    function getPoolsForToken(
        address token
    ) external view returns (ArbUtils.PoolInfo[] memory) {
        return tokenPools[token];
    }

    function getSupportedTokenCount() external view returns (uint256) {
        return supportedTokens.length;
    }

    function getAllSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    // Legacy inventory tests reproduce the reference harness's pool approvals.
    function approvePools(
        address tokenAddress,
        address[] calldata poolAddresses,
        uint256 amount
    ) external onlyOwner {
        for (uint256 i = 0; i < poolAddresses.length; i++) {
            IERC20(tokenAddress).approve(poolAddresses[i], 0);
            IERC20(tokenAddress).approve(poolAddresses[i], amount);
        }
    }

    function runPairForTest(
        address tokenA,
        address tokenB,
        uint256 maxIter
    ) external onlyOwner returns (int256 profit, uint256 iterations) {
        _setActiveProfitRecipient(owner());
        (profit, iterations) = _runPair(tokenA, tokenB, maxIter);
        _setActiveProfitRecipient(address(0));
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
        _setActiveProfitRecipient(owner());
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
        _setActiveProfitRecipient(address(0));
        if (!callOk) return (false, 0, 0);
        return abi.decode(returndata, (bool, int256, uint256));
    }

    /// @notice Exposes the V3/V3 sizing outputs, including the edge score.
    /// @dev Used to document how far the score diverges from realized profit, which
    ///      is why it screens for the presence of edge only and never for a minimum
    ///      profit amount. See `ArbMath._edgeScore`.
    function previewV3RouteEstimate(
        address poolA,
        address poolB,
        address startToken,
        address intermediateToken,
        ArbUtils.PoolType poolAType,
        ArbUtils.PoolType poolBType,
        uint256 principalCap
    ) external view returns (uint256 principal, uint256 refined, uint256 edgeScore) {
        return _deriveV3Principal(
            poolA, poolB, startToken, intermediateToken, poolAType, poolBType, principalCap
        );
    }

    function setTestProfitBps(uint256 bps) external onlyOwner {
        testProfitBps = bps;
    }

    function setTestInjectProfitAnyIterations(bool enabled) external onlyOwner {
        testInjectProfitAnyIterations = enabled;
    }

    function setTestLegacyInventoryParityEnabled(
        bool enabled
    ) external onlyOwner {
        testLegacyInventoryParityEnabled = enabled;
    }

    function setTestProfitTransfer(address payer, uint256 amount) external onlyOwner {
        testProfitPayer = payer;
        testFixedProfitAmount = amount;
    }

    function setTestProfitForIntermediateToken(
        address token,
        uint256 amount
    ) external onlyOwner {
        testProfitByIntermediateToken[token] = amount;
    }

    // The production hook is flash-only. This test-only branch keeps the
    // historical prefunded executor available as an exact regression oracle.
    function executeIterativeArbViaFlash(
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
        if (!testLegacyInventoryParityEnabled) {
            return
                super.executeIterativeArbViaFlash(
                    poolA_addr,
                    poolB_addr,
                    startToken,
                    intermediateToken,
                    maxIterations,
                    poolAType,
                    poolBType
                );
        }

        (success, cumulativeProfit, iterations, ) = executeIterativeArb(
            poolA_addr,
            poolB_addr,
            startToken,
            intermediateToken,
            maxIterations,
            poolAType,
            poolBType
        );
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
        returns (bool success, int256 cumulativeProfit, uint256 iterations, uint256 totalAmountSwapped)
    {
        uint256 routeProfit = testProfitByIntermediateToken[intermediateToken];
        if (
            (testProfitBps > 0 || routeProfit > 0) &&
            (maxIterations == 0 || testInjectProfitAnyIterations)
        ) {
            uint256 bal = IERC20(startToken).balanceOf(address(this));
            uint256 realizedProfit;

            if (routeProfit > 0) {
                (bool ok, ) = startToken.call(
                    abi.encodeWithSignature(
                        "mint(address,uint256)",
                        address(this),
                        routeProfit
                    )
                );
                require(ok, "test mint failed");
                realizedProfit = routeProfit;
            } else if (testFixedProfitAmount > 0) {
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
            return (true, int256(realizedProfit), 1, bal);
        }

        (success, cumulativeProfit, iterations, totalAmountSwapped) = super
            .executeIterativeArb(
                poolA_addr,
                poolB_addr,
                startToken,
                intermediateToken,
                maxIterations,
                poolAType,
                poolBType
            );
        if (
            testLegacyInventoryParityEnabled &&
            iterations > 0 &&
            cumulativeProfit > 0
        ) {
            emit ArbitrageAttempted(
                startToken,
                intermediateToken,
                poolB_addr,
                poolA_addr,
                totalAmountSwapped,
                cumulativeProfit,
                iterations
            );
        }
    }
}
