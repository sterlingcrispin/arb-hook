// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library ArbErrors {
    // --- Custom Errors ---
    error InputArrayLengthMismatch();
    error PoolToken0FetchFailed();
    error PoolToken1FetchFailed();
    error AddPoolsInputTokenNotInPool();
    error PoolFeeFetchFailed();
    error AddPoolsProvidedFeeMismatch();
    error AddPoolsPoolVerificationFailed();
    error TokenHasNoPools();
    error PoolIndexOutOfBounds();
    error Slot0FetchFailed(string reason);
    error Slot0FetchFailedUnknown();
    error IIAEMustAllowOneIteration();
    error IIAEPoolsMustBeDifferent();
    error IIAESetupSlot0FailedPoolA();
    error IIAESetupSlot0FailedPoolB();
    error IIAESetupToken0FailedPoolA();
    error IIAEInitialSpreadTooLow(int24 initialAbsSpread, uint16 minSpreadBps);
    error IIAELoopSlot0FailedPoolA();
    error IIAELoopSlot0FailedPoolB();
    error IIAELoopLiquidityFailedPoolA();
    error IIAELoopToken0FailedPoolA();
    error IIAELoopLiquidityFailedPoolB();
    error IIAELoopToken0FailedPoolBPLCheck();
    error FeeFetchAFailed();
    error FeeFetchBFailed();
    error IIAEUnprofitableSequence(
        int256 cumulativeProfit,
        int256 minCumulativeProfit
    );
    error SwapTokensMustBeDifferent();
    error SwapMismatchedTokens0To1();
    error SwapMismatchedTokens1To0();
    error SwapInputTokenNotInPool();
    error SwapInsufficientAllowance(uint256 allowance, uint256 amountIn);
    error SwapInsufficientBalance(uint256 balance, uint256 amountIn);
    error SwapAmountMustBePositive();
    error CallbackCallerMismatch(
        address decodedCaller,
        address contractAddress
    );
    error CallbackCallerIsEOA();
    error CallbackUnexpectedPool(address caller, address expectedPool);
    error CallbackFailedToken0Fetch(address pool);
    error CallbackFailedToken1Fetch(address pool);
    error CallbackPoolTokensZeroAddress();
    error CallbackDecodedTokenNotInPool(
        address decodedTokenIn,
        address token0,
        address token1
    );
    error CallbackInvalidDelta0Sign();
    error CallbackInvalidDelta1Sign();
    error CallbackTransferFailed(
        address token,
        address recipient,
        uint256 amount
    );
    error WithdrawToZeroAddress();
    error WithdrawZeroAddressToken();
    error WithdrawAmountExceedsBalance(uint256 amount, uint256 balance);
    error WithdrawETHToZeroAddress();
    error WithdrawETHAmountExceedsBalance(uint256 amount, uint256 balance);
    error ETHWithdrawalFailed(address to, uint256 amount);
    error FailedTickSpacing();

    /* ───────────── generic modifiers ───────────── */
    error OnlyOwnerOrSelf(); // replaces revert-string in modifier
    error WrapperOnlySelf(); // replaces "wrapper-only-self"

    error HelperToken0Failed();
    error HelperToken1Failed();
    error InvalidArbitrageLogicAddress();
    error SwapOutputTokenNotInV2Pair();
}
