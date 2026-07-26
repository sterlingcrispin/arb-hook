// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library ArbErrors {
    // --- Custom Errors ---
    error InputArrayLengthMismatch();
    error AddPoolsInputTokenNotInPool();
    error AddPoolsProvidedFeeMismatch();
    error IIAELoopSlot0FailedPoolA();
    error IIAELoopSlot0FailedPoolB();
    error IIAELoopLiquidityFailedPoolA();
    error IIAELoopToken0FailedPoolA();
    error IIAELoopLiquidityFailedPoolB();
    error SwapTokensMustBeDifferent();
    error SwapMismatchedTokens0To1();
    error SwapMismatchedTokens1To0();
    error SwapInputTokenNotInPool();
    error CallbackCallerMismatch(
        address decodedCaller,
        address contractAddress
    );
    error CallbackCallerIsEOA();
    error CallbackUnexpectedPool(address caller, address expectedPool);
    error CallbackDecodedTokenNotInPool(
        address decodedTokenIn,
        address token0,
        address token1
    );
    error CallbackInvalidDelta0Sign();
    error CallbackInvalidDelta1Sign();
    error WrapperOnlySelf();
    error InvalidArbitrageLogicAddress();
    error InvalidPoolManagerAddress();
    error InvalidLenderAddress();
    error InvalidTokenAddress();
    error UntrustedFlashLender();
    error FlashFeeBpsTooHigh();
    error InvalidProfitRecipient();
    error InvalidFlashLender();
    error InvalidFlashInitiator();
    error FlashLoanMismatch();
    error FlashContextMismatch();
    error FlashTokenMismatch();
    error InvalidFlashBeneficiary();
    error FlashArbitrageExecutionFailed();
    error InsufficientFlashRepaymentBalance();
    error UnwindFailed();
    error ERC20TransferFailed();
    error UnsupportedPoolType();
    error InvalidV2FlashSwapParams();
}
