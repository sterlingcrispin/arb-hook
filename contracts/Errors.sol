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
    error CallbackCallerMismatch();
    error CallbackUnexpectedPool();
    error CallbackDecodedTokenNotInPool();
    error CallbackInvalidDelta0Sign();
    error CallbackInvalidDelta1Sign();
    error WrapperOnlySelf();
    error InvalidArbitrageLogicAddress();
    error InvalidPoolManagerAddress();
    error InvalidLenderAddress();
    error InvalidTokenAddress();
    error FlashFeeBpsTooHigh();
    error InvalidFlashLender();
    error InvalidFlashInitiator();
    error FlashLoanMismatch();
    error FlashContextMismatch();
    error FlashTokenMismatch();
    error InvalidFlashBeneficiary();
    error FlashFeeExceedsCap();
    error FlashProfitBelowMinimum();
    error FlashArbitrageExecutionFailed();
    error InsufficientFlashRepaymentBalance();
    error UnwindFailed();
    error ERC20TransferFailed();
    error UnsupportedPoolType();
    error InvalidV2FlashSwapParams();
    error InvalidGasReserve();
}
