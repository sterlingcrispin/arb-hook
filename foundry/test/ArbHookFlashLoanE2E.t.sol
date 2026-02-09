// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ArbHookHarness} from "../../contracts/test/ArbHookHarness.sol";
import {PoolManagerHarness} from "../../contracts/test/PoolManagerHarness.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {DataStorage} from "../../contracts/DataStorage.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {TestToken} from "../../contracts/test/TestToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "../../contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "../../contracts/interfaces/IERC3156FlashLender.sol";
import {IDataStorage} from "../../contracts/interfaces/IDataStorage.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract MockERC3156Lender is IERC3156FlashLender {
    IERC20 public immutable loanToken;
    uint256 public immutable feeBps;
    bytes32 private constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    constructor(IERC20 _loanToken, uint256 _feeBps) {
        loanToken = _loanToken;
        feeBps = _feeBps;
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        if (token != address(loanToken)) return 0;
        return loanToken.balanceOf(address(this));
    }

    function flashFee(address token, uint256 amount) external view returns (uint256) {
        require(token == address(loanToken), "unsupported token");
        return (amount * feeBps) / 10_000;
    }

    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool) {
        require(token == address(loanToken), "unsupported token");
        uint256 fee = (amount * feeBps) / 10_000;

        require(loanToken.transfer(receiver, amount), "loan transfer failed");
        bytes32 response = IERC3156FlashBorrower(receiver).onFlashLoan(
            msg.sender,
            token,
            amount,
            fee,
            data
        );
        require(response == CALLBACK_SUCCESS, "bad callback response");
        require(
            loanToken.transferFrom(receiver, address(this), amount + fee),
            "repay transfer failed"
        );
        return true;
    }
}

contract BadInitiatorFlashLender is IERC3156FlashLender {
    IERC20 public immutable loanToken;
    uint256 public immutable feeBps;

    constructor(IERC20 _loanToken, uint256 _feeBps) {
        loanToken = _loanToken;
        feeBps = _feeBps;
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        if (token != address(loanToken)) return 0;
        return loanToken.balanceOf(address(this));
    }

    function flashFee(address token, uint256 amount) external view returns (uint256) {
        require(token == address(loanToken), "unsupported token");
        return (amount * feeBps) / 10_000;
    }

    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool) {
        require(token == address(loanToken), "unsupported token");
        uint256 fee = (amount * feeBps) / 10_000;
        require(loanToken.transfer(receiver, amount), "loan transfer failed");

        // Deliberately wrong initiator to exercise callback auth hardening.
        IERC3156FlashBorrower(receiver).onFlashLoan(
            address(0xBEEF),
            token,
            amount,
            fee,
            data
        );
        return true;
    }
}

contract ArbHookFlashLoanE2ETest is Test {
    ArbHookHarness internal hook;
    TestToken internal token;
    DataStorage internal dataStorage;

    function setUp() public {
        PoolManagerHarness poolManager = new PoolManagerHarness(address(this));
        ArbitrageLogic logic = new ArbitrageLogic();
        dataStorage = new DataStorage(address(this));
        hook = new ArbHookHarness(
            IPoolManager(address(poolManager)),
            address(this),
            address(logic),
            address(dataStorage)
        );
        dataStorage.setWriter(address(hook));

        token = new TestToken("Flash Loan Token", "FLT", 0);
    }

    function testFlashLoanRoundTripRepaysPrincipalAndFee() public {
        uint256 principal = 1_000_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 5); // 0.05%

        token.mint(address(lender), principal);
        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 20); // 0.20%

        uint256 fee = lender.flashFee(address(token), principal);
        token.mint(address(hook), fee); // cover flash fee when no arb profit

        uint256 lenderBefore = token.balanceOf(address(lender));
        assertEq(lenderBefore, principal);

        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            address(0xA1),
            address(0xB2),
            address(token),
            address(0xCAFE),
            0, // avoid pool interactions in this plumbing test
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertFalse(success, "maxIterations=0 path should not report profitable trade");
        assertEq(profit, -int256(fee), "net profit should equal paid flash fee");
        assertEq(iterations, 0, "no iterations expected");

        assertEq(
            token.balanceOf(address(lender)),
            lenderBefore + fee,
            "lender should end with principal+fee"
        );
        assertEq(
            token.balanceOf(address(hook)),
            0,
            "hook should not retain principal/fee after repayment"
        );
    }

    function testFlashLoanCallbackRejectsWrongInitiator() public {
        uint256 principal = 50_000e18;
        BadInitiatorFlashLender lender = new BadInitiatorFlashLender(
            IERC20(address(token)),
            5
        );
        token.mint(address(lender), principal);

        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 20);

        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            address(0xA3),
            address(0xB4),
            address(token),
            address(0xCAFE),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertFalse(success, "bad initiator callback should fail safely");
        assertEq(profit, 0, "failed flash request should not report profit");
        assertEq(iterations, 0, "failed flash request should not run iterations");
    }

    function testFlashLoanProfitablePathPaysBeneficiaryAndStoresTrade() public {
        uint256 principal = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 5); // 0.05%
        token.mint(address(lender), principal);

        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 20);
        hook.setMinProfitToEmit(1);

        // Configure harness-only deterministic profit injection for maxIterations=0.
        hook.setTestProfitBps(100); // +1.00% over current balance

        address beneficiary = makeAddr("beneficiary");
        hook.setDefaultProfitRecipient(beneficiary);

        uint256 fee = lender.flashFee(address(token), principal);
        uint256 expectedGross = principal / 100; // 1%
        uint256 expectedNet = expectedGross - fee;
        assertGt(expectedNet, 0, "expectedNet should be positive");

        uint256 lenderBefore = token.balanceOf(address(lender));
        uint256 beneficiaryBefore = token.balanceOf(beneficiary);
        uint256 tradesBefore = dataStorage.getTradeCount();

        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            address(0xD1),
            address(0xD2),
            address(token),
            address(0xD3),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertTrue(success, "profitable flash test path should succeed");
        assertEq(uint256(profit), expectedNet, "reported net profit mismatch");
        assertEq(iterations, 1, "injected profitable path should report one iteration");

        assertEq(
            token.balanceOf(beneficiary),
            beneficiaryBefore + expectedNet,
            "beneficiary did not receive net profit"
        );
        assertEq(
            token.balanceOf(address(lender)),
            lenderBefore + fee,
            "lender should only gain fee"
        );
        assertEq(
            dataStorage.getTradeCount(),
            tradesBefore + 1,
            "successful net-profit flash trade should be stored"
        );
    }
}
