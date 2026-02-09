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
    uint256 public flashLoanCallCount;
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
        flashLoanCallCount += 1;
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

contract TamperedDataFlashLender is IERC3156FlashLender {
    IERC20 public immutable loanToken;
    uint256 public immutable feeBps;
    uint256 public flashLoanCallCount;

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
        bytes calldata
    ) external returns (bool) {
        require(token == address(loanToken), "unsupported token");
        flashLoanCallCount += 1;
        uint256 fee = (amount * feeBps) / 10_000;
        require(loanToken.transfer(receiver, amount), "loan transfer failed");

        // Deliberately forge callback payload to fail context-hash validation.
        bytes memory forgedData = abi.encode(address(0xDEAD));
        IERC3156FlashBorrower(receiver).onFlashLoan(
            msg.sender,
            token,
            amount,
            fee,
            forgedData
        );
        return true;
    }
}

contract ArbHookFlashLoanE2ETest is Test {
    bytes32 private constant ARBITRAGE_ATTEMPTED_TOPIC =
        keccak256(
            "ArbitrageAttempted(address,address,address,address,uint256,int256,uint256)"
        );
    bytes32 private constant FLASH_LOAN_SETTLED_TOPIC =
        keccak256(
            "FlashLoanSettled(address,address,uint256,uint256,int256,address)"
        );
    bytes32 private constant FLASH_LOAN_FAILED_TOPIC =
        keccak256("FlashLoanFailed(address,address,bytes)");

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
        uint256 tradesBefore = dataStorage.getTradeCount();
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
        assertEq(
            dataStorage.getTradeCount(),
            tradesBefore,
            "non-profitable run must not store trade data"
        );
    }

    function testFlashLoanSkipsWhenFeeExceedsCap() public {
        uint256 principal = 200_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 50); // 0.50%

        token.mint(address(lender), principal);
        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 20); // 0.20% cap

        uint256 tradesBefore = dataStorage.getTradeCount();
        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            address(0xA5),
            address(0xB6),
            address(token),
            address(0xCAFE),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertFalse(success, "fee cap should block flash request");
        assertEq(profit, 0, "blocked flash request should not report profit");
        assertEq(iterations, 0, "blocked flash request should not run iterations");
        assertEq(lender.flashLoanCallCount(), 0, "flashLoan should not be called");
        assertEq(
            dataStorage.getTradeCount(),
            tradesBefore,
            "blocked flash request must not store trade data"
        );
    }

    function testFlashLoanSkipsWhenLenderCapacityIsTooLow() public {
        uint256 principal = 200_000e18;
        uint256 available = principal / 2;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 5);

        token.mint(address(lender), available);
        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 20);

        uint256 tradesBefore = dataStorage.getTradeCount();
        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            address(0xA7),
            address(0xB8),
            address(token),
            address(0xCAFE),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertFalse(success, "insufficient lender capacity should block flash request");
        assertEq(profit, 0, "blocked flash request should not report profit");
        assertEq(iterations, 0, "blocked flash request should not run iterations");
        assertEq(lender.flashLoanCallCount(), 0, "flashLoan should not be called");
        assertEq(
            dataStorage.getTradeCount(),
            tradesBefore,
            "blocked flash request must not store trade data"
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

    function testFlashLoanCallbackRejectsForgedContextData() public {
        uint256 principal = 80_000e18;
        TamperedDataFlashLender lender = new TamperedDataFlashLender(
            IERC20(address(token)),
            5
        );
        token.mint(address(lender), principal);

        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 20);

        uint256 tradesBefore = dataStorage.getTradeCount();
        vm.recordLogs();
        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            address(0xE1),
            address(0xE2),
            address(token),
            address(0xE3),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertFalse(success, "forged callback context should fail safely");
        assertEq(profit, 0, "forged callback should not report profit");
        assertEq(iterations, 0, "forged callback should not run iterations");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool sawFlashLoanFailed = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == address(hook) &&
                entries[i].topics.length > 0 &&
                entries[i].topics[0] == FLASH_LOAN_FAILED_TOPIC
            ) {
                sawFlashLoanFailed = true;
                break;
            }
        }
        assertTrue(sawFlashLoanFailed, "expected FlashLoanFailed event");
        assertEq(
            dataStorage.getTradeCount(),
            tradesBefore,
            "forged callback must not store trade data"
        );
    }

    function testFlashLoanNetNegativeRunDoesNotPayBeneficiaryOrStoreTrade() public {
        uint256 principal = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 50); // 0.50%
        token.mint(address(lender), principal);

        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 100); // allow 1%
        hook.setMinProfitToEmit(1);
        hook.setTestProfitBps(10); // +0.10% gross

        uint256 fee = lender.flashFee(address(token), principal);
        // External reserve to ensure repayment succeeds even when net is negative.
        token.mint(address(hook), fee);
        // Harness computes synthetic gross profit from current hook balance
        // (principal + this preloaded reserve).
        uint256 gross = ((principal + fee) * 10) / 10_000;
        uint256 expectedNetLoss = fee - gross;
        assertGt(expectedNetLoss, 0, "test should force net loss");

        address beneficiary = makeAddr("netNegativeBeneficiary");
        hook.setDefaultProfitRecipient(beneficiary);

        uint256 lenderBefore = token.balanceOf(address(lender));
        uint256 beneficiaryBefore = token.balanceOf(beneficiary);
        uint256 tradesBefore = dataStorage.getTradeCount();

        (bool success, int256 profit, uint256 iterations) = hook.runFlashArbForTest(
            address(0xF1),
            address(0xF2),
            address(token),
            address(0xF3),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertFalse(success, "net-negative run should not be marked successful");
        assertEq(profit, -int256(expectedNetLoss), "reported net loss mismatch");
        assertEq(iterations, 1, "test harness should report one synthetic iteration");
        assertEq(
            token.balanceOf(beneficiary),
            beneficiaryBefore,
            "beneficiary must not be paid on net-negative result"
        );
        assertEq(
            dataStorage.getTradeCount(),
            tradesBefore,
            "net-negative run must not store trade data"
        );
        assertEq(
            token.balanceOf(address(lender)),
            lenderBefore + fee,
            "lender should still be repaid principal+fee"
        );
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

        vm.recordLogs();
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

        uint256[] memory stored = dataStorage.fetchTradeData(tradesBefore);
        assertEq(stored[0], uint256(uint160(address(0xD2))), "stored buy pool mismatch");
        assertEq(stored[1], uint256(uint160(address(0xD1))), "stored sell pool mismatch");
        assertEq(stored[5], expectedNet, "stored trade profit should be net");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool sawFlashSettled = false;
        bool sawArbAttempted = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == address(hook) &&
                entries[i].topics.length > 0
            ) {
                if (entries[i].topics[0] == FLASH_LOAN_SETTLED_TOPIC) {
                    sawFlashSettled = true;
                }
                if (entries[i].topics[0] == ARBITRAGE_ATTEMPTED_TOPIC) {
                    sawArbAttempted = true;
                }
            }
        }
        assertTrue(sawFlashSettled, "flash settlement event missing");
        assertFalse(
            sawArbAttempted,
            "legacy gross ArbitrageAttempted event should be suppressed in flash flow"
        );
    }

    function testRecipientRoutingUsesSenderWhenHookDataIsEmpty() public {
        uint256 principal = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 5);
        token.mint(address(lender), principal);

        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 20);
        hook.setMinProfitToEmit(1);
        hook.setTestProfitBps(100);

        address defaultRecipient = makeAddr("defaultRecipient");
        address senderRecipient = makeAddr("senderRecipient");
        hook.setDefaultProfitRecipient(defaultRecipient);

        uint256 fee = lender.flashFee(address(token), principal);
        uint256 expectedNet = (principal / 100) - fee;

        uint256 senderBefore = token.balanceOf(senderRecipient);
        uint256 defaultBefore = token.balanceOf(defaultRecipient);

        (bool success, int256 profit, ) = hook.runFlashArbWithContextForTest(
            senderRecipient,
            bytes(""),
            address(0x71),
            address(0x72),
            address(token),
            address(0x73),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertTrue(success, "sender recipient route should succeed");
        assertEq(uint256(profit), expectedNet, "sender route net profit mismatch");
        assertEq(
            token.balanceOf(senderRecipient),
            senderBefore + expectedNet,
            "sender should receive profit when hookData is empty"
        );
        assertEq(
            token.balanceOf(defaultRecipient),
            defaultBefore,
            "default recipient should not receive payout when sender is set"
        );
    }

    function testRecipientRoutingUsesHookDataOverrideOverSender() public {
        uint256 principal = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 5);
        token.mint(address(lender), principal);

        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 20);
        hook.setMinProfitToEmit(1);
        hook.setTestProfitBps(100);

        address defaultRecipient = makeAddr("defaultRecipient2");
        address sender = makeAddr("routerSender");
        address overrideRecipient = makeAddr("hookDataRecipient");
        hook.setDefaultProfitRecipient(defaultRecipient);

        uint256 fee = lender.flashFee(address(token), principal);
        uint256 expectedNet = (principal / 100) - fee;

        uint256 senderBefore = token.balanceOf(sender);
        uint256 overrideBefore = token.balanceOf(overrideRecipient);
        uint256 defaultBefore = token.balanceOf(defaultRecipient);

        (bool success, int256 profit, ) = hook.runFlashArbWithContextForTest(
            sender,
            abi.encode(overrideRecipient),
            address(0x81),
            address(0x82),
            address(token),
            address(0x83),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertTrue(success, "hookData override route should succeed");
        assertEq(uint256(profit), expectedNet, "hookData route net profit mismatch");
        assertEq(
            token.balanceOf(overrideRecipient),
            overrideBefore + expectedNet,
            "hookData override recipient should receive payout"
        );
        assertEq(
            token.balanceOf(sender),
            senderBefore,
            "sender should not receive payout when hookData override is set"
        );
        assertEq(
            token.balanceOf(defaultRecipient),
            defaultBefore,
            "default recipient should not receive payout when hookData override is set"
        );
    }

    function testRecipientRoutingFallsBackToDefaultWhenSenderIsZero() public {
        uint256 principal = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 5);
        token.mint(address(lender), principal);

        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 20);
        hook.setMinProfitToEmit(1);
        hook.setTestProfitBps(100);

        address defaultRecipient = makeAddr("defaultRecipient3");
        hook.setDefaultProfitRecipient(defaultRecipient);

        uint256 fee = lender.flashFee(address(token), principal);
        uint256 expectedNet = (principal / 100) - fee;
        uint256 defaultBefore = token.balanceOf(defaultRecipient);

        (bool success, int256 profit, ) = hook.runFlashArbWithContextForTest(
            address(0),
            bytes(""),
            address(0x91),
            address(0x92),
            address(token),
            address(0x93),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertTrue(success, "default fallback route should succeed");
        assertEq(uint256(profit), expectedNet, "default route net profit mismatch");
        assertEq(
            token.balanceOf(defaultRecipient),
            defaultBefore + expectedNet,
            "default recipient should receive payout when sender is zero"
        );
    }

    function testRecipientRoutingZeroHookDataAddressFallsBackToSender() public {
        uint256 principal = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 5);
        token.mint(address(lender), principal);

        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 20);
        hook.setMinProfitToEmit(1);
        hook.setTestProfitBps(100);

        address defaultRecipient = makeAddr("defaultRecipient4");
        address senderRecipient = makeAddr("senderRecipient4");
        hook.setDefaultProfitRecipient(defaultRecipient);

        uint256 fee = lender.flashFee(address(token), principal);
        uint256 expectedNet = (principal / 100) - fee;

        uint256 senderBefore = token.balanceOf(senderRecipient);
        uint256 defaultBefore = token.balanceOf(defaultRecipient);

        (bool success, int256 profit, ) = hook.runFlashArbWithContextForTest(
            senderRecipient,
            abi.encode(address(0)),
            address(0xA1),
            address(0xA2),
            address(token),
            address(0xA3),
            0,
            ArbUtils.PoolType.V3,
            ArbUtils.PoolType.V3
        );

        assertTrue(success, "zero hookData override should still succeed");
        assertEq(
            uint256(profit),
            expectedNet,
            "zero hookData override route net profit mismatch"
        );
        assertEq(
            token.balanceOf(senderRecipient),
            senderBefore + expectedNet,
            "sender should receive payout when hookData decodes to zero address"
        );
        assertEq(
            token.balanceOf(defaultRecipient),
            defaultBefore,
            "default recipient should not receive payout when sender is set"
        );
    }
}
