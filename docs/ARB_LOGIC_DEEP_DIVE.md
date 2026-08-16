# ArbHook Logic Deep Dive

This document describes the current production path. The temporary one-round route that counter-traded the triggering v4 pool has been removed. Production now calls the original registered-pool scanner and iterative executor through a flash-loan wrapper.

Relevant files:

- `contracts/ArbHook.sol`
- `contracts/ArbitrageLogic.sol`
- `contracts/ArbUtils.sol`
- `contracts/lib/ArbMath.sol`
- `contracts/test/ArbHookHarness.sol`

## 1. What The V4 Hook Does

The v4 pool is an execution trigger, not an arbitrage venue.

`afterSwap` ignores the triggering `PoolKey`, direction, amount, and balance delta for route selection. Once execution is enabled, it scans the owner-registered external pool book. This preserves the original arbitrage engine's model:

```text
registered base token
  -> registered counter token
  -> cheapest external pool to buy base
  -> richest external pool to sell base
  -> bounded iterative round trip
```

The hook callback supplies two things:

- a point in time at which the scanner runs; and
- the address that receives any realized net profit.

This means the triggering swap need not involve the arbitrage pair. It also means the trigger does not create the external spread. Opportunity and trigger timing are independent.

## 2. `afterSwap` And Failure Isolation

The callback performs only recipient resolution and dispatch:

1. `onlyPoolManager` requires the immutable v4 `PoolManager`.
2. Read `hookMaxIterations`; zero returns immediately.
3. Resolve the beneficiary from `IMsgSender.msgSender()` or exact 20-byte hook data.
4. Store the beneficiary in transient storage.
5. call `_attemptAllViaSelfCall(iterations)`.
6. Clear the transient beneficiary.
7. Return the `afterSwap` selector and zero hook delta.

The self-call is the failure boundary. Route discovery, lender calls, swaps, callback repayment, unwind, and profit checks can revert without reverting the user's swap because `_attemptAllViaSelfCall` captures the call result.

There is one explicit exception: `_attemptGasBudget` can revert before that self-call. With a nonzero `hookGasLimit`, the transaction must provide more than:

```text
hookGasReserve + hookGasLimit
```

The defaults are `200,000 + 3,000,000`. This prevents RPC estimation from selecting a lower-gas successful branch that silently skips arbitrage. Setting `hookGasLimit` to zero removes the floor and uses all gas above the reserve.

There is no trigger-amount gate. An enabled callback with a valid beneficiary always enters scanner discovery.

## 3. Registration Graph And Outer Loops

`ArbUtils._addPools(base, pools, fees, types)` builds three ordered structures:

- `tokenPools[base]`: all venues registered under a base token;
- `supportedTokens`: each distinct base token in first-registration order; and
- `baseCounterList[base]`: each distinct counter token in first-seen order.

For every registered pool, the counter is whichever token is not the supplied base token.

`_attemptAllInternal(maxIterations)` contains two nested loops:

```text
for each base in supportedTokens:
    for each counter in baseCounterList[base]:
        runPair(base, counter, maxIterations)
        if profit > 0: stop both loops
```

The first profitable pair wins. This is deliberate gas bounding, not global optimization across every simultaneous opportunity. Registration order therefore affects behavior whenever multiple pairs are profitable.

The scanner runs through an external self-call even though it is part of the same contract. `_attemptAllInternal` verifies `msg.sender == address(this)`, preventing arbitrary callers from invoking the expensive production cycle directly.

## 4. Pair Discovery And Fallback Loop

`_runPair(tokenA, tokenB, maxIter)` has a separate bounded loop with at most two attempts.

### First attempt

`findBestPools` scans `tokenPools[tokenA]` once. It ignores pools that do not contain exactly `tokenA/tokenB`, asks `ArbitrageLogic._getSinglePoolPrices` for fee-adjusted buy and sell prices, then records:

- the pool with the lowest effective cost to buy `tokenA`; and
- the pool with the highest effective proceeds from selling `tokenA`.

If either side is missing, both sides are the same pool, or the best sell price is not above the best buy price, there is no candidate.

The returned orientation is important:

- `sellPool` becomes pool A, where `startToken` is sold for `intermediateToken`;
- `buyPool` becomes pool B, where `intermediateToken` buys back `startToken`.

### Isolated execution

The candidate is passed to `executeIterativeArbViaFlash` through another self-call with `gasleft() >> 1`. A route failure cannot consume all scanner gas or revert the outer scan.

### Fallback attempt

If execution reverts or returns no profitable trade, `_runPair` excludes the first route's sell pool and performs one more discovery pass. This can select a different sell venue. After that second attempt, the pair is finished.

The fallback does not exhaustively enumerate all pool combinations. Its purpose is to avoid getting stuck on one failing best quote while keeping callback gas bounded.

## 5. Flash Principal Selection

`executeIterativeArbViaFlash` validates the route's base-token configuration before borrowing:

- a lender must be bound;
- `maxFlashFeeBps` must be nonzero;
- `minNetProfit` must be nonzero;
- the configured principal cap must be nonzero; and
- lender availability must be nonzero.

The effective cap is:

```text
min(configured principal cap, lender maxFlashLoan)
```

The borrowed amount is then derived by pool type.

### V3/V3

`_deriveV3Principal` reuses the executor's V3 state and sizing model:

1. Read both current ticks.
2. Orient the signed spread by `startToken` and reject a spread below `minSpreadBps`.
3. Build the same `IterationConfig` used during execution.
4. Call `getV3SwapParameters` for the coarse liquidity/spread-bounded chunk and price limits.
5. Call `findBestV3Chunk` for the refined binary-search candidate.
6. Borrow the coarse chunk so the executor retains the same search range it had under inventory funding.

The refined result is retained as a retry principal. If the coarse flash attempt reverts for a retryable reason, the wrapper can try the refined amount and then one half of that amount. A positive route below `minNetProfit` is final and is not retried smaller.

The V3 `edgeScore` is only a sign that modeled edge exists. It is not compared numerically with `minNetProfit` because its linear approximation is not denominated like authoritative realized profit.

### V2/V2

`calculateV2TradeParams` reads both reserve pairs, simulates the real two-fee round trip at four representative chunks, and chooses the most profitable of:

```text
minimum chunk
1% of available balance
10% of available balance
50% of available balance
```

The unchanged executor starts its own V2 search from at most half its available balance. The flash wrapper therefore borrows twice the selected chunk, capped at the effective principal ceiling, so the executor sees the same candidate it would have seen with inventory.

### Mixed V2/V3

`findBestMixedPairChunk` starts at half the cap and uses fee-aware route simulation. It accepts the first profitable candidate or halves up to nine times. As with V2/V2, the wrapper funds twice the selected chunk so the executor's original half-balance starting point is preserved.

These are bounded heuristics. They avoid replacing the original executor with a new optimal-sizing system.

## 6. Flash Request And Retry Semantics

Before each request, the wrapper quotes `flashFee` and rejects a fee above `maxFlashFeeBps`. It stores the lender, token, amount, and full loan-data hash in transient storage, then calls ERC-3156 `flashLoan`.

The request result distinguishes three cases:

- success: return the trade result recorded by `onFlashLoan`;
- positive profit below `minNetProfit`: stop, because smaller principal is not expected to clear a fixed floor; and
- other V3/V3 revert: retry only with the precomputed smaller candidate described above.

The bundled Morpho and Aave adapters bubble callback revert data unchanged. Retry selection relies on that behavior, while repayment safety does not.

## 7. The Iterative Executor

`onFlashLoan` authenticates the flash context and self-calls:

```text
executeIterativeArb(
    sellPool,
    buyPool,
    startToken,
    intermediateToken,
    maxIterations,
    sellPoolType,
    buyPoolType
)
```

The executor rejects zero iterations and identical pools. It snapshots the intermediate-token balance so only residue created by this attempt can be unwound.

For V3/V3, it also snapshots the initial absolute spread. Later chunk aggressiveness is measured relative to this starting spread rather than resetting the baseline every round.

The main loop is:

```text
for i < maxIterations:
    calculate sizing balance
    calculate a fresh route-specific chunk from current state
    execute start -> intermediate on pool A
    measure intermediate actually received
    execute intermediate -> start on pool B
    measure realized marginal start-token profit
    accumulate profit and swapped amount
    stop if marginal profit <= 0
```

Under flash funding, sizing balance is:

```text
active flash principal + cumulative profit from prior iterations
```

It is not `balanceOf(hook)`. That prevents donated or pre-existing tokens from enlarging the trade.

### V3/V3 iteration

Each pass rereads slot0 and active liquidity, recomputes the remaining spread, derives bounded target price movement, calculates a coarse chunk, and runs the V3 refinement. If spread, liquidity, impact, or chunk size fails a guard, the loop ends.

The adaptive movement starts from `CHUNK_SPREAD_CONSUMPTION_BPS = 1500` plus a term based on current spread as a percentage of initial spread. It is divided between the two legs and capped by `_MAX_IMPACT_BPS = 500`. This makes early rounds larger while allowing later rounds to shrink as the pools converge.

### V2/V2 iteration

Each pass recomputes the four-probe heuristic from current reserves. It then starts at the selected candidate and halves up to nine times until simulated two-leg profit is positive and cumulative profit reaches the small route guardrail.

### Mixed iteration

Each pass starts at half the current sizing balance and uses the bounded mixed-route simulator. It halves until it finds a positive candidate or reaches the minimum chunk/halving bound. V3-side impact is checked before execution.

## 8. Why More Than One Round Matters

One round only moves each pool by one bounded step. It is intentionally not expected to consume the entire spread. After that step:

- pool prices have changed;
- available liquidity and reserves may have changed;
- the safest/profitable next chunk is different; and
- another round can still be profitable.

That is why the original executor recalculates inside the loop. Reusing its first chunk repeatedly would be unsafe; stopping after one chunk leaves edge behind. `hookMaxIterations` now reaches this loop unchanged, and the callback regression test pins that behavior.

The configured bound still may not close the entire opportunity. The loop can also stop because a price limit partially fills, a quote becomes zero, a callback swap fails, impact is too high, chunk size is too small, or marginal profit becomes non-positive. Closing every possible last unit is not the goal; realizing bounded positive steps is.

## 9. Swap Execution And Callback Authentication

V3 and Pancake V3 swaps install a transient hash of the expected pool and callback data immediately before calling the pool. The callback must match that single-use context and owe a positive amount of the expected token.

V2 and Pancake V2 flash swaps additionally verify:

- the pool is registered with matching token metadata;
- its address matches the canonical factory pair; and
- callback data matches the active transient context.

Every context is consumed or cleared synchronously. A merely registered pool cannot call later and spend hook balances.

## 10. Residue Unwind

A partial first or second leg can leave intermediate tokens. After the iteration loop, the executor computes only the amount above its entry snapshot.

It tries to sell residue through pool B first because pool B is already the route's intermediate-to-start venue. If residue remains, it tries pool A. V2 and V3 unwind paths are both supported.

If any attempt-created intermediate balance remains, the executor reverts. Profit or loss caused by the unwind is included in cumulative route profit.

## 11. Authoritative Settlement

`onFlashLoan` snapshots:

- base-token balance after receiving principal; and
- intermediate-token balance before execution.

After execution:

```text
netProfit = baseBalanceAfter - baseBalanceBefore - lenderFee
```

Settlement requires:

- exact intermediate-balance restoration;
- a successful route;
- positive net profit;
- net profit at least `minNetProfit`; and
- enough remaining base token for principal plus fee after beneficiary payment.

The profit transfer and lender repayment are in the same transaction. Any failure reverts the full loan and every underlying swap.

## 12. What The Parity Tests Prove

`ArbHookParity.t.sol` retains a test-only inventory mode in `ArbHookHarness`. That mode runs the same scanner and executor against the historical fixed-block setup and asserts exact pool selection and exact gross profit for all ten rounds.

The flash fork suite uses the same pool registration order and natural route sequence, but wraps execution in real lender adapters. It demonstrates that flash funding did not replace route planning or chunk logic.

The parity oracle does not prove that a profitable external spread will coincide with a real v4 callback. That is a market/trigger question, not an executor-correctness question.
