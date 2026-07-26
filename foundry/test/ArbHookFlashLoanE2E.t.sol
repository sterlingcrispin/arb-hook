// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ArbHookHarness} from "../../contracts/test/ArbHookHarness.sol";
import {PoolManagerHarness} from "../../contracts/test/PoolManagerHarness.sol";
import {ArbitrageLogic} from "../../contracts/ArbitrageLogic.sol";
import {ArbUtils} from "../../contracts/ArbUtils.sol";
import {TestToken} from "../../contracts/test/TestToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "../../contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "../../contracts/interfaces/IERC3156FlashLender.sol";
import {IUniswapV2Pair} from "../../contracts/interfaces/IUniswapV2Pair.sol";
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

contract MockV2PricePair is IUniswapV2Pair {
    address private immutable _token0;
    address private immutable _token1;
    uint112 private _reserve0;
    uint112 private _reserve1;

    constructor(address token0_, address token1_, uint112 reserve0_, uint112 reserve1_) {
        _token0 = token0_;
        _token1 = token1_;
        _reserve0 = reserve0_;
        _reserve1 = reserve1_;
    }

    function token0() external view returns (address) {
        return _token0;
    }

    function token1() external view returns (address) {
        return _token1;
    }

    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)
    {
        return (_reserve0, _reserve1, uint32(block.timestamp));
    }

    function swap(uint, uint, address, bytes calldata) external pure {}

    function skim(address) external pure {}

    function sync() external pure {}
}

contract ArbHookFlashLoanE2ETest is Test {
    bytes32 private constant ARBITRAGE_ATTEMPTED_TOPIC =
        keccak256(
            "ArbitrageAttempted(address,address,address,address,uint256,int256,uint256)"
        );
    bytes32 private constant FLASH_LOAN_REQUESTED_TOPIC =
        keccak256("FlashLoanRequested(address,address,uint256,address)");
    bytes32 private constant FLASH_LOAN_SETTLED_TOPIC =
        keccak256(
            "FlashLoanSettled(address,address,address,address,address,uint256,uint256,uint256,int256,uint256,address)"
        );
    bytes32 private constant FLASH_LOAN_FAILED_TOPIC =
        keccak256("FlashLoanFailed(address,address,bytes)");
    bytes32 private constant HOOK_ATTEMPT_ALL_TOPIC =
        keccak256("HookAttemptAll(uint256,bool,bool)");

    struct Settlement {
        address buyPool;
        address sellPool;
        uint256 principal;
        uint256 totalAmountSwapped;
        uint256 fee;
        int256 netProfit;
        uint256 iterations;
        address beneficiary;
    }

    PoolManagerHarness internal poolManager;
    ArbHookHarness internal hook;
    TestToken internal token;
    TestToken internal counterToken;

    function setUp() public {
        poolManager = new PoolManagerHarness(address(this));
        ArbitrageLogic logic = new ArbitrageLogic();
        hook = new ArbHookHarness(
            IPoolManager(address(poolManager)),
            address(this),
            address(logic));

        token = new TestToken("Flash Loan Token", "FLT", 0);
        counterToken = new TestToken("Counter Token", "CTR", 0);
    }

    function _configureAfterSwapV2Route(
        IERC3156FlashLender lender,
        uint256 principal,
        uint256 maxFeeBps,
        uint256 testProfitBps
    ) internal {
        address[] memory pools = new address[](2);
        uint24[] memory fees = new uint24[](2);
        ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](2);

        // Lower ratio -> preferred buy pool.
        pools[0] = address(
            new MockV2PricePair(
                address(token),
                address(counterToken),
                1_000_000,
                1_000_000
            )
        );
        // Higher ratio -> preferred sell pool.
        pools[1] = address(
            new MockV2PricePair(
                address(token),
                address(counterToken),
                1_000_000,
                2_000_000
            )
        );
        fees[0] = 0;
        fees[1] = 0;
        types[0] = ArbUtils.PoolType.V2;
        types[1] = ArbUtils.PoolType.V2;

        hook.addPools(address(token), pools, fees, types);
        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), maxFeeBps);
        hook.setHookMaxIterations(1);
        hook.setTestProfitBps(testProfitBps);
        hook.setTestInjectProfitAnyIterations(true);
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

        vm.recordLogs();

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

        (bool sawSettlement, Settlement memory settled) = _findLastSettlement(vm.getRecordedLogs());
        assertTrue(sawSettlement, "completed loan should emit settlement");
        assertEq(
            settled.principal, principal, "settled principal mismatch");
        assertEq(settled.totalAmountSwapped, 0, "unexpected swapped amount");
        assertEq(settled.fee, fee, "settled fee mismatch");
        assertEq(settled.netProfit, -int256(fee),
            "settled net mismatch");
        assertEq(settled.iterations,
            0, "settled iterations mismatch"
        );
    }

    function testRunPairUsesQuoteBasedFlashPrincipalHint() public {
        uint256 principalCap = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 5);
        token.mint(address(lender), principalCap);

        address[] memory pools = new address[](2);
        uint24[] memory fees = new uint24[](2);
        ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](2);
        pools[0] = address(
            new MockV2PricePair(
                address(token),
                address(counterToken),
                1_000_000,
                1_000_000
            )
        );
        pools[1] = address(
            new MockV2PricePair(
                address(token),
                address(counterToken),
                1_000_000,
                2_000_000
            )
        );
        types[0] = ArbUtils.PoolType.V2;
        types[1] = ArbUtils.PoolType.V2;
        hook.addPools(address(token), pools, fees, types);

        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principalCap);
        hook.setMaxFlashFeeBpsForToken(address(token), 20);
        hook.setTestProfitBps(100); // 1% gross in harness shortcut
        hook.setTestInjectProfitAnyIterations(true);

        vm.recordLogs();
        (int256 cumulativeProfit, uint256 iterations) = hook.runPairForTest(
            address(token),
            address(counterToken),
            1
        );

        uint256 requestedPrincipal = _extractRequestedPrincipal(vm.getRecordedLogs());
        uint256 expectedPrincipal = (principalCap * 3500) / 10_000; // spread > 80 bps => 35%
        assertEq(
            requestedPrincipal,
            expectedPrincipal,
            "principal hint should be quote-tiered utilization"
        );
        assertEq(iterations, 1, "harness injected path should report one iteration");

        uint256 fee = lender.flashFee(address(token), expectedPrincipal);
        uint256 expectedNet = (expectedPrincipal / 100) - fee;
        assertEq(
            cumulativeProfit,
            int256(expectedNet),
            "net should be computed from hinted principal amount"
        );
    }

    function testLenderCapacityRecoveryRetriesUnchangedQuote() public {
        uint256 principalCap = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 5);
        _configureAfterSwapV2Route(lender, principalCap, 20, 100);

        (int256 firstProfit, uint256 firstIterations) = hook.runPairForTest(address(token), address(counterToken), 1);
        assertEq(firstProfit, 0, "capacity failure should not report profit");
        assertEq(firstIterations, 0, "capacity failure should not execute");
        assertEq(lender.flashLoanCallCount(), 0, "insufficient capacity should block the lender call");

        token.mint(address(lender), principalCap);
        (int256 recoveredProfit, uint256 recoveredIterations) =
            hook.runPairForTest(address(token), address(counterToken), 1);

        assertGt(recoveredProfit, 0, "unchanged quote should retry after lender capacity recovers");
        assertEq(recoveredIterations, 1, "recovered route should execute once");
        assertEq(lender.flashLoanCallCount(), 1, "recovered route should borrow");
    }

    function testFlashLoanSkipsWhenFeeExceedsCap() public {
        uint256 principal = 200_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 50); // 0.50%

        token.mint(address(lender), principal);
        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 20); // 0.20% cap

        vm.recordLogs();
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
        assertEq(lender.flashLoanCallCount(), 0, "flashLoan should not be called");(
            bool sawSettlement,) = _findLastSettlement(vm.getRecordedLogs());
        assertFalse(sawSettlement,
            "blocked request must not emit settlement"
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

        vm.recordLogs();
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
        assertEq(lender.flashLoanCallCount(), 0, "flashLoan should not be called");(
            bool sawSettlement,) = _findLastSettlement(vm.getRecordedLogs());
        assertFalse(sawSettlement,
            "blocked request must not emit settlement"
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
        assertTrue(sawFlashLoanFailed, "expected FlashLoanFailed event");(
            bool sawSettlement,) = _findLastSettlement(entries);
        assertFalse(sawSettlement,
            "forged callback must not emit settlement"
        );
    }

    function testFlashLoanNetNegativeRunDoesNotPayBeneficiaryAndEmitsSettlement() public {
        uint256 principal = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 50); // 0.50%
        token.mint(address(lender), principal);

        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 100); // allow 1%
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
        vm.recordLogs();

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
            token.balanceOf(address(lender)),
            lenderBefore + fee,
            "lender should still be repaid principal+fee"
        );

        (bool sawSettlement, Settlement memory settled) = _findLastSettlement(vm.getRecordedLogs());
        assertTrue(sawSettlement, "net-negative loan should emit settlement");
        assertEq(settled.buyPool, address(0xF2), "settled buy pool mismatch");
        assertEq(settled.sellPool, address(0xF1), "settled sell pool mismatch");
        assertEq(settled.netProfit, profit, "settled net loss mismatch");
        assertEq(settled.iterations, iterations, "settled iterations mismatch");
        assertEq(settled.beneficiary, beneficiary, "settled beneficiary mismatch");
    }

    function testFlashLoanProfitablePathPaysBeneficiaryAndEmitsSettlement() public {
        uint256 principal = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 5); // 0.05%
        token.mint(address(lender), principal);

        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), 20);

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

        Vm.Log[] memory entries = vm.getRecordedLogs();
        (
        bool sawFlashSettled, Settlement memory settled) = _findLastSettlement(entries);
        bool sawArbAttempted = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == address(hook) &&
                entries[i].topics.length > 0
            ) {
                if (entries[i].topics[0] == ARBITRAGE_ATTEMPTED_TOPIC) {
                    sawArbAttempted = true;
                }
            }
        }
        assertTrue(sawFlashSettled, "flash settlement event missing");
        assertEq(settled.buyPool, address(0xD2), "settled buy pool mismatch");
        assertEq(settled.sellPool, address(0xD1), "settled sell pool mismatch");
        assertEq(settled.principal, principal, "settled principal mismatch");
        assertEq(settled.totalAmountSwapped, principal, "settled amount mismatch");
        assertEq(settled.fee, fee, "settled fee mismatch");
        assertEq(settled.netProfit, int256(expectedNet), "settled net mismatch");
        assertEq(settled.iterations, iterations, "settled iterations mismatch");
        assertEq(settled.beneficiary, beneficiary, "settled beneficiary mismatch");
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

    function testAfterSwapCallbackPathPaysSenderWhenNoHookDataOverride() public {
        uint256 principal = 100_000;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 5);
        token.mint(address(lender), principal);
        _configureAfterSwapV2Route(lender, principal, 20, 100);

        address defaultRecipient = makeAddr("afterSwapDefault");
        address senderRecipient = makeAddr("afterSwapSender");
        hook.setDefaultProfitRecipient(defaultRecipient);

        uint256 senderBefore = token.balanceOf(senderRecipient);
        uint256 defaultBefore = token.balanceOf(defaultRecipient);

        vm.recordLogs();
        (bytes4 selector, int128 delta) = poolManager.callAfterSwap(
            hook,
            senderRecipient,
            bytes("")
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 borrowedPrincipal = _extractRequestedPrincipal(entries);
        assertGt(borrowedPrincipal, 0, "callback path should request flash principal");

        uint256 fee = lender.flashFee(address(token), borrowedPrincipal);
        uint256 expectedGross = (borrowedPrincipal * 100) / 10_000;
        uint256 expectedNet = expectedGross - fee;

        assertEq(selector, hook.afterSwap.selector, "afterSwap selector mismatch");
        assertEq(delta, int128(0), "afterSwap delta should be zero");
        assertEq(
            token.balanceOf(senderRecipient),
            senderBefore + expectedNet,
            "sender should receive net profit in callback path"
        );
        assertEq(
            token.balanceOf(defaultRecipient),
            defaultBefore,
            "default recipient should not receive payout when sender is present"
        );

        (bool sawSettlement, Settlement memory settled) = _findLastSettlement(entries);
        assertTrue(sawSettlement, "callback path should emit settlement");
        assertEq(
            settled.principal, borrowedPrincipal, "settled principal mismatch");
        assertEq(settled.netProfit, int256(expectedNet),
            "settled net mismatch");
        assertEq(settled.beneficiary,
            senderRecipient, "settled recipient mismatch"
        );
    }

    function testAfterSwapCallbackPathUsesHookDataRecipientOverride() public {
        uint256 principal = 100_000;
        MockERC3156Lender lender = new MockERC3156Lender(IERC20(address(token)), 5);
        token.mint(address(lender), principal);
        _configureAfterSwapV2Route(lender, principal, 20, 100);

        address defaultRecipient = makeAddr("afterSwapDefault2");
        address sender = makeAddr("afterSwapSender2");
        address overrideRecipient = makeAddr("afterSwapOverride");
        hook.setDefaultProfitRecipient(defaultRecipient);

        uint256 senderBefore = token.balanceOf(sender);
        uint256 overrideBefore = token.balanceOf(overrideRecipient);
        uint256 defaultBefore = token.balanceOf(defaultRecipient);

        vm.recordLogs();
        (bytes4 selector, int128 delta) = poolManager.callAfterSwap(
            hook,
            sender,
            abi.encode(overrideRecipient)
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 borrowedPrincipal = _extractRequestedPrincipal(entries);
        assertGt(borrowedPrincipal, 0, "callback path should request flash principal");

        uint256 fee = lender.flashFee(address(token), borrowedPrincipal);
        uint256 expectedGross = (borrowedPrincipal * 100) / 10_000;
        uint256 expectedNet = expectedGross - fee;

        assertEq(selector, hook.afterSwap.selector, "afterSwap selector mismatch");
        assertEq(delta, int128(0), "afterSwap delta should be zero");
        assertEq(
            token.balanceOf(overrideRecipient),
            overrideBefore + expectedNet,
            "hookData override recipient should receive net profit"
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

        (bool sawSettlement, Settlement memory settled) = _findLastSettlement(entries);
        assertTrue(sawSettlement, "callback path should emit settlement");
        assertEq(settled.netProfit, int256(expectedNet), "settled net mismatch");
        assertEq(settled.beneficiary, overrideRecipient, "settled recipient mismatch");
    }

    function testAfterSwapCallbackPathContainsFlashFailure() public {
        uint256 principal = 100_000;
        BadInitiatorFlashLender lender = new BadInitiatorFlashLender(
            IERC20(address(token)),
            5
        );
        token.mint(address(lender), principal);
        _configureAfterSwapV2Route(lender, principal, 20, 100);

        address defaultRecipient = makeAddr("afterSwapDefault3");
        address sender = makeAddr("afterSwapSender3");
        hook.setDefaultProfitRecipient(defaultRecipient);

        uint256 senderBefore = token.balanceOf(sender);
        uint256 defaultBefore = token.balanceOf(defaultRecipient);

        vm.recordLogs();
        (bytes4 selector, int128 delta) = poolManager.callAfterSwap(
            hook,
            sender,
            bytes("")
        );

        assertEq(selector, hook.afterSwap.selector, "afterSwap selector mismatch");
        assertEq(delta, int128(0), "afterSwap delta should be zero");
        assertEq(
            token.balanceOf(sender),
            senderBefore,
            "sender should not receive payout when flash execution fails"
        );
        assertEq(
            token.balanceOf(defaultRecipient),
            defaultBefore,
            "default recipient should not receive payout when flash execution fails"
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool sawHookAttemptAll = false;
        bool sawFlashLoanFailed = false;
        bool hookCallSuccess = false;
        bool hookTradeProfitable = true;

        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == address(hook) &&
                entries[i].topics.length > 0
            ) {
                if (entries[i].topics[0] == HOOK_ATTEMPT_ALL_TOPIC) {
                    (, hookCallSuccess, hookTradeProfitable) = abi.decode(
                        entries[i].data,
                        (uint256, bool, bool)
                    );
                    sawHookAttemptAll = true;
                }
                if (entries[i].topics[0] == FLASH_LOAN_FAILED_TOPIC) {
                    sawFlashLoanFailed = true;
                }
            }
        }

        assertTrue(sawHookAttemptAll, "expected HookAttemptAll event");
        assertTrue(hookCallSuccess, "attemptAll self-call should remain isolated");
        assertFalse(
            hookTradeProfitable,
            "failed flash callback should not report profitable hook execution"
        );
        assertTrue(sawFlashLoanFailed, "expected FlashLoanFailed event");
        (bool sawSettlement,) = _findLastSettlement(entries);
        assertFalse(sawSettlement, "failed flash callback must not emit settlement");
    }

    function _findLastSettlement(Vm.Log[] memory entries) private view returns (bool found, Settlement memory settled) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == address(hook) && entries[i].topics.length > 0
                    && entries[i].topics[0] == FLASH_LOAN_SETTLED_TOPIC
            ) {
                (
                    settled.buyPool,
                    settled.sellPool,
                    settled.principal,
                    settled.totalAmountSwapped,
                    settled.fee,
                    settled.netProfit,
                    settled.iterations,
                    settled.beneficiary
                ) = abi.decode(entries[i].data, (address, address, uint256, uint256, uint256, int256, uint256, address));
                found = true;
            }
        }
    }

    function _extractRequestedPrincipal(
        Vm.Log[] memory entries
    ) private view returns (uint256 principal) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == address(hook) &&
                entries[i].topics.length > 0 &&
                entries[i].topics[0] == FLASH_LOAN_REQUESTED_TOPIC
            ) {
                (principal, ) = abi.decode(entries[i].data, (uint256, address));
                return principal;
            }
        }
        return 0;
    }
}
