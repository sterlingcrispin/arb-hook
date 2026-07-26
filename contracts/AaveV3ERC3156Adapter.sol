// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC3156FlashBorrower} from "./interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "./interfaces/IERC3156FlashLender.sol";

interface IAaveV3Pool {
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IAaveFlashLoanSimpleReceiver {
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool);
}

/// @title Aave V3 ERC-3156 Adapter
/// @notice Exposes one configured Aave V3 reserve through the ERC-3156 lender interface.
contract AaveV3ERC3156Adapter is IERC3156FlashLender, IAaveFlashLoanSimpleReceiver {
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error UnsupportedToken();
    error InvalidReceiver();
    error InvalidCallback();

    IAaveV3Pool public immutable pool;
    address public immutable supportedToken;
    address public immutable liquidityToken;

    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    constructor(address pool_, address token_, address liquidityToken_) {
        if (pool_ == address(0) || token_ == address(0) || liquidityToken_ == address(0)) {
            revert InvalidConfiguration();
        }

        pool = IAaveV3Pool(pool_);
        supportedToken = token_;
        liquidityToken = liquidityToken_;
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        if (token != supportedToken) return 0;
        return IERC20(token).balanceOf(liquidityToken);
    }

    function flashFee(address token, uint256 amount) external view returns (uint256) {
        if (token != supportedToken) revert UnsupportedToken();
        uint256 premiumBps = uint256(pool.FLASHLOAN_PREMIUM_TOTAL());
        uint256 product = amount * premiumBps;
        return product / 10_000 + (product % 10_000 == 0 ? 0 : 1);
    }

    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool) {
        if (receiver == address(0)) revert InvalidReceiver();
        if (token != supportedToken) revert UnsupportedToken();

        bytes memory params = abi.encode(receiver, msg.sender, data);
        pool.flashLoanSimple(address(this), token, amount, params, 0);
        return true;
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        if (msg.sender != address(pool) || initiator != address(this) || asset != supportedToken) {
            revert InvalidCallback();
        }

        (address receiver, address flashInitiator, bytes memory data) = abi.decode(params, (address, address, bytes));

        IERC20(asset).safeTransfer(receiver, amount);
        bytes32 response = IERC3156FlashBorrower(receiver).onFlashLoan(flashInitiator, asset, amount, premium, data);
        if (response != CALLBACK_SUCCESS) revert InvalidCallback();

        uint256 repayment = amount + premium;
        IERC20(asset).safeTransferFrom(receiver, address(this), repayment);
        IERC20(asset).forceApprove(address(pool), repayment);
        return true;
    }
}
