// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {MorphoERC3156Adapter} from "../../contracts/MorphoERC3156Adapter.sol";
import {IERC3156FlashBorrower} from "../../contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Borrower that mirrors how ArbHook settles: approve exactly the repayment.
contract MorphoBorrower is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    MorphoERC3156Adapter public immutable adapter;
    uint256 public observedFee;
    bool public sawCallback;

    constructor(MorphoERC3156Adapter adapter_) {
        adapter = adapter_;
    }

    function borrow(address token, uint256 amount) external returns (bool) {
        return adapter.flashLoan(address(this), token, amount, bytes("ctx"));
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        require(msg.sender == address(adapter), "unexpected adapter");
        require(initiator == address(this), "unexpected initiator");
        require(keccak256(data) == keccak256(bytes("ctx")), "context not forwarded");
        require(IERC20(token).balanceOf(address(this)) >= amount, "principal not received");

        observedFee = fee;
        sawCallback = true;
        IERC20(token).forceApprove(address(adapter), amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @notice Current-head Base fork coverage for the zero-fee Morpho Blue lender path.
/// @dev Skips unless RUN_FLASH_FORK_INTEGRATION=true and BASE_RPC_URL are set, matching
///      the other fork suites so an absent environment cannot report a false green.
contract MorphoERC3156AdapterForkTest is Test {
    address internal constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    MorphoERC3156Adapter internal adapter;
    MorphoBorrower internal borrower;
    bool internal enabled;

    function setUp() public {
        if (!vm.envOr("RUN_FLASH_FORK_INTEGRATION", false)) return;
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);
        enabled = true;

        adapter = new MorphoERC3156Adapter(MORPHO, USDC);
        borrower = new MorphoBorrower(adapter);
    }

    modifier requiresFork() {
        if (!enabled) {
            vm.skip(true);
            return;
        }
        _;
    }

    function testMorphoFlashLoanIsFreeAndRepaysExactly() public requiresFork {
        uint256 principal = 11_000e6; // the canary's intended USDC principal cap

        assertEq(adapter.flashFee(USDC, principal), 0, "morpho flash loan should be free");
        assertGt(adapter.maxFlashLoan(USDC), principal, "insufficient morpho liquidity");

        uint256 morphoBefore = IERC20(USDC).balanceOf(MORPHO);

        assertTrue(borrower.borrow(USDC, principal), "flash loan failed");

        assertTrue(borrower.sawCallback(), "borrower callback never ran");
        assertEq(borrower.observedFee(), 0, "callback fee should be zero");
        assertEq(IERC20(USDC).balanceOf(MORPHO), morphoBefore, "morpho balance changed");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "adapter retained funds");
        assertEq(IERC20(USDC).balanceOf(address(borrower)), 0, "borrower retained funds");
    }

    function testCallbackRejectsEntryOutsideActiveLoan() public requiresFork {
        vm.prank(MORPHO);
        vm.expectRevert(MorphoERC3156Adapter.InvalidCallback.selector);
        adapter.onMorphoFlashLoan(1, abi.encode(address(borrower), address(this), bytes("")));
    }

    function testCallbackRejectsNonMorphoCaller() public requiresFork {
        vm.expectRevert(MorphoERC3156Adapter.InvalidCallback.selector);
        adapter.onMorphoFlashLoan(1, abi.encode(address(borrower), address(this), bytes("")));
    }

    function testRejectsUnsupportedToken() public requiresFork {
        address weth = 0x4200000000000000000000000000000000000006;
        assertEq(adapter.maxFlashLoan(weth), 0);
        vm.expectRevert(MorphoERC3156Adapter.UnsupportedToken.selector);
        adapter.flashFee(weth, 1);
    }
}
