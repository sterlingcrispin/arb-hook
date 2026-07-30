// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC3156FlashBorrower} from "./interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "./interfaces/IERC3156FlashLender.sol";

interface IMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

/// @title Morpho Blue ERC-3156 Adapter
/// @notice Exposes one Morpho Blue reserve through the ERC-3156 lender interface.
/// @dev Morpho Blue charges no flash-loan premium: it transfers `assets`, invokes
///      `onMorphoFlashLoan`, then pulls back exactly `assets`. `flashFee` therefore
///      returns zero for the supported token. The hook still enforces its own
///      per-token fee cap and realized minimum-profit checks, so a lender that
///      later began charging would be rejected rather than silently absorbed.
contract MorphoERC3156Adapter is IERC3156FlashLender, IMorphoFlashLoanCallback {
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error UnsupportedToken();
    error InvalidReceiver();
    error InvalidCallback();

    IMorpho public immutable morpho;
    address public immutable supportedToken;

    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @dev Guards the callback against entry outside an in-flight flashLoan call.
    ///      Transient because it is only meaningful for one transaction.
    uint256 private constant _T_ACTIVE = 0;

    constructor(address morpho_, address token_) {
        if (morpho_ == address(0) || token_ == address(0)) revert InvalidConfiguration();

        morpho = IMorpho(morpho_);
        supportedToken = token_;
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        if (token != supportedToken) return 0;
        return IERC20(token).balanceOf(address(morpho));
    }

    function flashFee(address token, uint256) external view returns (uint256) {
        if (token != supportedToken) revert UnsupportedToken();
        return 0;
    }

    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data)
        external
        returns (bool)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        if (token != supportedToken) revert UnsupportedToken();

        bytes memory params = abi.encode(receiver, msg.sender, data);
        assembly ("memory-safe") {
            tstore(_T_ACTIVE, 1)
        }
        morpho.flashLoan(token, amount, params);
        assembly ("memory-safe") {
            tstore(_T_ACTIVE, 0)
        }
        return true;
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata params) external {
        uint256 active;
        assembly ("memory-safe") {
            active := tload(_T_ACTIVE)
        }
        if (msg.sender != address(morpho) || active == 0) revert InvalidCallback();

        (address receiver, address flashInitiator, bytes memory data) =
            abi.decode(params, (address, address, bytes));

        address asset = supportedToken;
        IERC20(asset).safeTransfer(receiver, assets);
        bytes32 response = IERC3156FlashBorrower(receiver).onFlashLoan(flashInitiator, asset, assets, 0, data);
        if (response != CALLBACK_SUCCESS) revert InvalidCallback();

        // The hook approves this adapter for exactly the repayment amount.
        IERC20(asset).safeTransferFrom(receiver, address(this), assets);
        IERC20(asset).forceApprove(address(morpho), assets);
    }
}
