// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {AaveV3ERC3156Adapter, IAaveFlashLoanSimpleReceiver} from "../../contracts/AaveV3ERC3156Adapter.sol";
import {IERC3156FlashBorrower} from "../../contracts/interfaces/IERC3156FlashBorrower.sol";
import {TestToken} from "../../contracts/test/TestToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockAaveV3Pool {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    uint128 public immutable premiumBps;

    constructor(IERC20 token_, uint128 premiumBps_) {
        token = token_;
        premiumBps = premiumBps_;
    }

    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128) {
        return premiumBps;
    }

    function flashLoanSimple(address receiverAddress, address asset, uint256 amount, bytes calldata params, uint16)
        external
    {
        require(asset == address(token), "unsupported asset");

        uint256 product = amount * premiumBps;
        uint256 premium =
            product / 10_000 + (product % 10_000 == 0 ? 0 : 1);
        token.safeTransfer(receiverAddress, amount);
        bool callbackOk =
            IAaveFlashLoanSimpleReceiver(receiverAddress).executeOperation(asset, amount, premium, msg.sender, params);
        require(callbackOk, "receiver callback failed");
        token.safeTransferFrom(receiverAddress, address(this), amount + premium);
    }
}

contract MockERC3156Borrower is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    AaveV3ERC3156Adapter public immutable adapter;

    constructor(AaveV3ERC3156Adapter adapter_) {
        adapter = adapter_;
    }

    function borrow(address token, uint256 amount) external returns (bool) {
        return adapter.flashLoan(address(this), token, amount, bytes(""));
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        require(msg.sender == address(adapter), "unexpected adapter");
        require(initiator == address(this), "unexpected initiator");

        IERC20(token).forceApprove(address(adapter), amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

contract AaveV3ERC3156AdapterTest is Test {
    uint128 private constant PREMIUM_BPS = 5;

    TestToken internal token;
    MockAaveV3Pool internal pool;
    AaveV3ERC3156Adapter internal adapter;
    MockERC3156Borrower internal borrower;

    function setUp() public {
        token = new TestToken("Loan Token", "LOAN", 0);
        pool = new MockAaveV3Pool(IERC20(address(token)), PREMIUM_BPS);
        adapter = new AaveV3ERC3156Adapter(address(pool), address(token), address(pool));
        borrower = new MockERC3156Borrower(adapter);
    }

    function testFlashLoanRoundTripUsesProductionAdapter() public {
        uint256 liquidity = 1_000_000e18;
        uint256 principal = 100_000e18;
        token.mint(address(pool), liquidity);

        uint256 fee = adapter.flashFee(address(token), principal);
        token.mint(address(borrower), fee);

        assertEq(adapter.maxFlashLoan(address(token)), liquidity);
        assertTrue(borrower.borrow(address(token), principal));
        assertEq(token.balanceOf(address(pool)), liquidity + fee);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(address(borrower)), 0);
    }

    function testRejectsUnsupportedToken() public {
        TestToken otherToken = new TestToken("Other Token", "OTHER", 0);

        assertEq(adapter.maxFlashLoan(address(otherToken)), 0);
        vm.expectRevert(AaveV3ERC3156Adapter.UnsupportedToken.selector);
        adapter.flashFee(address(otherToken), 1);
    }

    function testRejectsNonAaveCallbackCaller() public {
        vm.expectRevert(AaveV3ERC3156Adapter.InvalidCallback.selector);
        adapter.executeOperation(address(token), 1, 0, address(adapter), bytes(""));
    }

    function testFeeUsesAaveCeilingRounding() public view {
        assertEq(adapter.flashFee(address(token), 187_018), 94);
    }
}
