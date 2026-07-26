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
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract MockERC3156Lender is IERC3156FlashLender {
    IERC20 public immutable loanToken;
    uint256 public immutable feeBps;
    uint256 public flashLoanCallCount;
    bytes32 private constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    constructor(IERC20 token, uint256 fee) {
        loanToken = token;
        feeBps = fee;
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        return token == address(loanToken)
            ? loanToken.balanceOf(address(this))
            : 0;
    }

    function flashFee(
        address token,
        uint256 amount
    ) external view returns (uint256) {
        require(token == address(loanToken), "unsupported token");
        return (amount * feeBps) / 10_000;
    }

    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external virtual returns (bool) {
        require(token == address(loanToken), "unsupported token");
        ++flashLoanCallCount;
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

contract BadInitiatorFlashLender is MockERC3156Lender {
    constructor(IERC20 token, uint256 fee) MockERC3156Lender(token, fee) {}

    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        require(token == address(loanToken), "unsupported token");
        uint256 fee = (amount * feeBps) / 10_000;
        require(loanToken.transfer(receiver, amount), "loan transfer failed");
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

contract TamperedDataFlashLender is MockERC3156Lender {
    constructor(IERC20 token, uint256 fee) MockERC3156Lender(token, fee) {}

    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata
    ) external override returns (bool) {
        require(token == address(loanToken), "unsupported token");
        uint256 fee = (amount * feeBps) / 10_000;
        require(loanToken.transfer(receiver, amount), "loan transfer failed");
        IERC3156FlashBorrower(receiver).onFlashLoan(
            msg.sender,
            token,
            amount,
            fee,
            abi.encode(address(0xDEAD))
        );
        return true;
    }
}

contract MockV2PricePair is IUniswapV2Pair {
    address private immutable _token0;
    address private immutable _token1;
    uint112 private immutable _reserve0;
    uint112 private immutable _reserve1;

    constructor(
        address token0_,
        address token1_,
        uint112 reserve0_,
        uint112 reserve1_
    ) {
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
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        )
    {
        return (_reserve0, _reserve1, uint32(block.timestamp));
    }

    function swap(uint256, uint256, address, bytes calldata) external pure {}

    function skim(address) external pure {}

    function sync() external pure {}
}

contract ArbHookFlashLoanE2ETest is Test {
    bytes32 private constant FLASH_LOAN_SETTLED_TOPIC =
        keccak256(
            "FlashLoanSettled(address,address,address,address,address,uint256,uint256,uint256,int256,uint256,address)"
        );

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
            address(logic)
        );
        token = new TestToken("Flash Loan Token", "FLT", 0);
        counterToken = new TestToken("Counter Token", "CTR", 0);
    }

    function _configureLender(
        IERC3156FlashLender lender,
        uint256 principal,
        uint256 maxFeeBps,
        uint256 minNetProfit
    ) private {
        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setFlashPrincipalForToken(address(token), principal);
        hook.setMaxFlashFeeBpsForToken(address(token), maxFeeBps);
        hook.setMinNetProfitForToken(address(token), minNetProfit);
    }

    function _configureAfterSwapRoute(
        IERC3156FlashLender lender,
        uint256 principal
    ) private {
        address[] memory pools = new address[](2);
        uint24[] memory fees = new uint24[](2);
        ArbUtils.PoolType[] memory types = new ArbUtils.PoolType[](2);
        pools[0] = address(
            new MockV2PricePair(
                address(token),
                address(counterToken),
                1_000_000e18,
                1_000_000e18
            )
        );
        pools[1] = address(
            new MockV2PricePair(
                address(token),
                address(counterToken),
                1_000_000e18,
                1_100_000e18
            )
        );
        types[0] = ArbUtils.PoolType.V2;
        types[1] = ArbUtils.PoolType.V2;

        hook.addPools(address(token), pools, fees, types);
        _configureLender(lender, principal, 20, 1);
        hook.setHookMaxIterations(1);
        hook.setTestProfitBps(100);
        hook.setTestInjectProfitAnyIterations(true);
    }

    function testEconomicConfigIsFailClosed() public {
        uint256 principal = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(
            IERC20(address(token)),
            5
        );
        token.mint(address(lender), principal);
        hook.setTrustedFlashLender(address(lender), true);
        hook.setLenderForToken(address(token), address(lender));
        hook.setTestProfitBps(100);

        _runDirect();
        hook.setFlashPrincipalForToken(address(token), principal);
        _runDirect();
        hook.setMaxFlashFeeBpsForToken(address(token), 20);
        _runDirect();
        assertEq(lender.flashLoanCallCount(), 0, "incomplete config borrowed");

        hook.setMinNetProfitForToken(address(token), 1);
        (bool success, , ) = _runDirect();
        assertTrue(success, "complete config should borrow");
        assertEq(lender.flashLoanCallCount(), 1, "expected one flash loan");
    }

    function testRunPairUsesAdaptivePrincipalHint() public {
        uint256 principalCap = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(
            IERC20(address(token)),
            5
        );
        token.mint(address(lender), principalCap);
        _configureAfterSwapRoute(lender, principalCap);

        vm.recordLogs();
        (int256 profit, uint256 iterations) = hook.runPairForTest(
            address(token),
            address(counterToken),
            1
        );
        (bool found, Settlement memory settled) = _findLastSettlement(
            vm.getRecordedLogs()
        );

        assertTrue(found, "settlement missing");
        assertEq(
            settled.principal,
            (principalCap * 2000) / 10_000,
            "adaptive principal changed"
        );
        assertGt(profit, 0, "route should profit");
        assertEq(iterations, 1, "expected one iteration");
    }

    function testFeeAboveCapSkipsLoan() public {
        uint256 principal = 200_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(
            IERC20(address(token)),
            50
        );
        token.mint(address(lender), principal);
        _configureLender(lender, principal, 20, 1);

        (bool success, int256 profit, uint256 iterations) = _runDirect();
        assertFalse(success);
        assertEq(profit, 0);
        assertEq(iterations, 0);
        assertEq(lender.flashLoanCallCount(), 0);
    }

    function testCallbackRejectsWrongInitiator() public {
        uint256 principal = 50_000e18;
        BadInitiatorFlashLender lender = new BadInitiatorFlashLender(
            IERC20(address(token)),
            5
        );
        token.mint(address(lender), principal);
        _configureLender(lender, principal, 20, 1);
        hook.setTestProfitBps(100);

        (bool success, , ) = _runDirect();
        assertFalse(success, "forged initiator must fail");
    }

    function testCallbackRejectsTamperedData() public {
        uint256 principal = 50_000e18;
        TamperedDataFlashLender lender = new TamperedDataFlashLender(
            IERC20(address(token)),
            5
        );
        token.mint(address(lender), principal);
        _configureLender(lender, principal, 20, 1);
        hook.setTestProfitBps(100);

        (bool success, , ) = _runDirect();
        assertFalse(success, "tampered callback data must fail");
    }

    function testSubThresholdTradeCannotSpendHookBalance() public {
        uint256 principal = 100_000;
        MockERC3156Lender lender = new MockERC3156Lender(
            IERC20(address(token)),
            5
        );
        token.mint(address(lender), principal);
        uint256 fee = lender.flashFee(address(token), principal);
        uint256 grossProfit = fee + 10;
        _configureLender(lender, principal, 20, 11);

        token.mint(address(hook), 777);
        token.mint(address(this), grossProfit);
        token.approve(address(hook), grossProfit);
        hook.setTestProfitBps(1);
        hook.setTestProfitTransfer(address(this), grossProfit);

        uint256 lenderBefore = token.balanceOf(address(lender));
        uint256 hookBefore = token.balanceOf(address(hook));
        vm.recordLogs();
        (bool success, int256 profit, uint256 iterations) = _runDirect();

        assertFalse(success);
        assertEq(profit, 0);
        assertEq(iterations, 0);
        assertEq(token.balanceOf(address(lender)), lenderBefore);
        assertEq(token.balanceOf(address(hook)), hookBefore);
        (bool found, ) = _findLastSettlement(vm.getRecordedLogs());
        assertFalse(found, "reverted loan must not emit settlement");
    }

    function testProfitableLoanPaysBeneficiaryAndEmitsSettlement() public {
        uint256 principal = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(
            IERC20(address(token)),
            5
        );
        token.mint(address(lender), principal);
        _configureLender(lender, principal, 20, 1);
        hook.setTestProfitBps(100);

        uint256 fee = lender.flashFee(address(token), principal);
        uint256 expectedNet = principal / 100 - fee;
        uint256 beneficiaryBefore = token.balanceOf(address(this));
        vm.recordLogs();
        (bool success, int256 profit, uint256 iterations) = _runDirect();
        (bool found, Settlement memory settled) = _findLastSettlement(
            vm.getRecordedLogs()
        );

        assertTrue(success);
        assertEq(uint256(profit), expectedNet);
        assertEq(iterations, 1);
        assertEq(
            token.balanceOf(address(this)),
            beneficiaryBefore + expectedNet
        );
        assertTrue(found, "settlement missing");
        assertEq(settled.principal, principal);
        assertEq(settled.fee, fee);
        assertEq(settled.netProfit, int256(expectedNet));
        assertEq(settled.beneficiary, address(this));
    }

    function testAfterSwapPaysPackedBeneficiary() public {
        uint256 principal = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(
            IERC20(address(token)),
            5
        );
        token.mint(address(lender), principal);
        _configureAfterSwapRoute(lender, principal);
        address beneficiary = makeAddr("beneficiary");

        vm.recordLogs();
        (bytes4 selector, int128 delta) = poolManager.callAfterSwap(
            IHooks(address(hook)),
            makeAddr("router"),
            abi.encodePacked(beneficiary)
        );
        (bool found, Settlement memory settled) = _findLastSettlement(
            vm.getRecordedLogs()
        );

        assertEq(selector, hook.afterSwap.selector);
        assertEq(delta, 0);
        assertTrue(found, "callback did not execute");
        assertEq(settled.beneficiary, beneficiary);
        assertEq(
            token.balanceOf(beneficiary),
            uint256(settled.netProfit)
        );
    }

    function testAfterSwapSkipsMissingOrMalformedBeneficiary() public {
        uint256 principal = 100_000e18;
        MockERC3156Lender lender = new MockERC3156Lender(
            IERC20(address(token)),
            5
        );
        token.mint(address(lender), principal);
        _configureAfterSwapRoute(lender, principal);

        poolManager.callAfterSwap(
            IHooks(address(hook)),
            makeAddr("router"),
            bytes("")
        );
        poolManager.callAfterSwap(
            IHooks(address(hook)),
            makeAddr("router"),
            abi.encode(makeAddr("wrongLength"))
        );
        assertEq(lender.flashLoanCallCount(), 0, "invalid hook data borrowed");
    }

    function testAfterSwapContainsFlashFailure() public {
        uint256 principal = 100_000e18;
        BadInitiatorFlashLender lender = new BadInitiatorFlashLender(
            IERC20(address(token)),
            5
        );
        token.mint(address(lender), principal);
        _configureAfterSwapRoute(lender, principal);

        (bytes4 selector, int128 delta) = poolManager.callAfterSwap(
            IHooks(address(hook)),
            makeAddr("router"),
            abi.encodePacked(makeAddr("beneficiary"))
        );
        assertEq(selector, hook.afterSwap.selector);
        assertEq(delta, 0);
    }

    function _runDirect()
        private
        returns (bool success, int256 profit, uint256 iterations)
    {
        return
            hook.runFlashArbForTest(
                address(0xA1),
                address(0xB2),
                address(token),
                address(counterToken),
                0,
                ArbUtils.PoolType.V3,
                ArbUtils.PoolType.V3
            );
    }

    function _findLastSettlement(
        Vm.Log[] memory entries
    ) private view returns (bool found, Settlement memory settled) {
        for (uint256 i; i < entries.length; ++i) {
            if (
                entries[i].emitter == address(hook) &&
                entries[i].topics.length > 0 &&
                entries[i].topics[0] == FLASH_LOAN_SETTLED_TOPIC
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
                ) = abi.decode(
                    entries[i].data,
                    (
                        address,
                        address,
                        uint256,
                        uint256,
                        uint256,
                        int256,
                        uint256,
                        address
                    )
                );
                found = true;
            }
        }
    }
}
