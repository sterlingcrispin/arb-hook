# ArbHook Logic Deep Dive

This document describes the current production callback path and the preserved legacy parity engine. The production strategy uses the triggering Uniswap v4 pool as the first arbitrage leg and a registered V3-compatible pool for the return leg. It performs repeated live-repriced rounds inside one flash loan.

Relevant files:

- `contracts/ArbHook.sol`
- `contracts/V4ArbExecutor.sol`
- `contracts/ArbitrageLogic.sol`
- `contracts/ArbUtils.sol`
- `contracts/lib/ArbMath.sol`
- `contracts/test/ArbHookHarness.sol`

## 1. Why The Triggering Pool Is The Opportunity

A user swap moves the v4 pool before `afterSwap` runs. If the swap buys token X from v4, token X becomes more expensive in that pool relative to an external reference. The correcting route is therefore:

```text
borrow X
  -> sell X back into the triggering v4 pool
  -> receive Y
  -> spend Y in the external reference pool to buy X
  -> repay borrowed X
```

The hook runs in the same transaction as the dislocating swap. It does not need an unrelated external opportunity to happen at the same time, and it does not race a searcher to observe published post-block state.

The user's original swap has already settled its own v4 balance delta. The hook's nested counter-swap accrues separate deltas to the hook. Its profit is paid as a separate token transfer; it does not alter the router's quoted output accounting.

## 2. `afterSwap`, Recipient Resolution, And Failure Isolation

`afterSwap` performs a small amount of orchestration:

1. `onlyPoolManager` requires the immutable v4 `PoolManager`.
2. Read `hookMaxIterations`; zero means execution is disabled.
3. Resolve the beneficiary from exact 20-byte hook data or `IMsgSender.msgSender()` on the router.
4. Store the beneficiary in EIP-1153 transient storage.
5. Call `attemptTriggerPoolInternal` through a bounded external self-call.
6. Clear the transient beneficiary.
7. Return the `afterSwap` selector and zero hook delta.

The self-call is a failure boundary. Route discovery, lender calls, nested swaps, callback repayment, unwind, and profit checks can revert without reverting the user's swap.

`_attemptGasBudget` runs before the failure boundary. With the default nonzero `hookGasLimit`, the transaction must provide more than:

```text
hookGasReserve + hookGasLimit
200,000       + 3,000,000 by default
```

This is deliberate. It prevents RPC estimation from selecting a cheaper successful path where the arbitrage subcall simply runs out of gas and is skipped. A zero limit removes the floor and gives the attempt all gas above the reserve.

## 3. Direction And Token Selection

`SwapParams.zeroForOne` identifies what the triggering swap sold and bought.

```text
trigger zeroForOne = true:
    user sold currency0 and bought currency1
    startToken        = currency1
    intermediateToken = currency0

trigger zeroForOne = false:
    user sold currency1 and bought currency0
    startToken        = currency0
    intermediateToken = currency1
```

`startToken` is the token the hook borrows, profits in, and pays to the beneficiary. It is also the token that the user just made more expensive in v4.

Native currency is rejected because the current flash, transfer, and callback paths operate on ERC20 balances. ERC20/ERC20 v4 pairs are supported.

## 4. External Reference Selection

Pools are registered under a base token with `addPools(base, pools, fees, types)`. Production scans only `tokenPools[startToken]` for the current callback.

`_findReferencePool`:

1. filters to Uniswap V3 or PancakeSwap V3;
2. requires the candidate to contain `intermediateToken` (registration validation already guarantees it contains `startToken`);
3. reads the current pool price;
4. computes the fee-adjusted price to buy `startToken`; and
5. retains the lowest price.

A strict `<` comparison preserves first-registration order when two candidates quote equally.

Reference selection happens once before the flash loan. Every execution round rereads that selected pool's current state, but it does not switch external venues mid-loan. This keeps callback gas and state complexity bounded.

For both directions of a pair to execute, the same reference may need registration under both tokens, and both output tokens need lender/economic configuration.

## 5. Initial Spread, Fees, And Principal

`ArbitrageLogic.getLiveV4V3RouteParams` reads:

- v4 `sqrtPriceX96`, tick, active liquidity, LP fee, and directional protocol fee;
- external V3/Pancake V3 `sqrtPriceX96`, tick, active liquidity, and pool fee; and
- token decimals captured at registration.

The effective v4 fee combines LP and directional protocol fees using the v4 core fee library.

The directional spread is oriented around selling `startToken` into v4:

```text
startToken is token0: v4Tick - externalTick
startToken is token1: externalTick - v4Tick
```

A negative spread means the user's swap did not create the expected direction of edge. A positive spread still must reach `minSpreadBps` and clear both venues' fee-adjusted prices:

```text
effective v4 sell price > effective external buy price
```

This second check matters because tick distance alone does not prove a profitable round trip after fees.

### Adaptive movement

The first calculation uses the current spread as `initialSpread`. Later rounds retain that original anchor:

```text
move = remainingSpread
     * (chunkSpreadConsumptionBps + 2000 * remainingSpread / initialSpread)
     / (2 * 10000)
```

At defaults:

- `chunkSpreadConsumptionBps = 1500`;
- the adaptive term begins at `2000` and shrinks with the remaining spread;
- division by two allocates movement across both venues; and
- `_MAX_IMPACT_BPS = 500` caps one venue's modeled tick movement.

The names retain the original contract terminology, but the result is used as a bounded tick movement when constructing both sqrt-price limits.

### Capacity-derived principal

`ArbMath._deltaAmounts` calculates:

- how much `startToken` moves v4 from its current price to the v4 limit;
- how much `intermediateToken` that v4 movement can produce; and
- how much `intermediateToken` the external venue can absorb before its own limit.

If the v4 output exceeds external capacity, principal is reduced proportionally:

```text
principal = v4StartInput * externalCapacity / v4IntermediateOutput
```

It is then clamped to:

```text
min(configured principal cap, lender availability)
```

and rejected below `_minChunk(startToken)`.

This is the amount borrowed once for the whole attempt. There is no arbitrary fixed principal and no tick-by-tick traversal.

## 6. Flash Context And The Execution Module

`attemptTriggerPoolInternal` requires nonzero:

- lender availability and configured principal cap;
- `maxFlashFeeBps`; and
- `minNetProfit`.

It encodes the selected v4 key, reference metadata, initial spread anchor, execution parameters, and beneficiary-independent route data. `_requestFlashLoan` binds lender, token, amount, and the exact data hash in transient storage before calling ERC-3156.

`onFlashLoan` authenticates:

- lender;
- initiator;
- loan token and amount; and
- the full context hash.

It then delegate-calls the immutable `V4ArbExecutor`.

Delegatecall is load-bearing here:

- PoolManager sees `ArbHook` as the nested swap caller;
- v4 therefore suppresses recursive hook callbacks for the hook's own swap;
- V3 pools call their repayment callback on `ArbHook`;
- the executor can install the same transient swap-context hash that `ArbHook` validates; and
- token balances remain on `ArbHook`, where flash repayment is measured.

The executor address is created in the hook constructor and cannot be replaced.

The module also dispatches preserved legacy external/external flash routes back to `ArbHook.executeIterativeArb`. This keeps the historical engine available without embedding another dispatch branch in the size-constrained hook.

## 7. The Multi-Round Loop

The executor snapshots the pre-attempt intermediate-token balance and initializes cumulative state:

```text
profit = 0
iterations = 0
amountSwapped = 0
```

For each `i < maxIterations`:

1. Set sizing balance to borrowed principal plus positive cumulative profit.
2. Call `getLiveV4V3RouteParams` again.
3. Stop if the live route now returns zero principal.
4. Snapshot `startToken` balance.
5. Execute the bounded exact-input v4 counter-swap.
6. Settle the v4 input delta with `sync -> transfer -> settle`.
7. Take the v4 output delta to the hook.
8. Execute all received `intermediateToken` through the selected V3-compatible reference with its newly computed price limit.
9. Measure marginal `startToken` profit from actual balances.
10. Accumulate v4 input, profit, and completed iteration count.
11. Stop if marginal profit is non-positive; otherwise repeat from fresh state.

The sizing balance is not `balanceOf(hook)`. Donated or pre-existing `startToken` cannot enlarge the route:

```text
currentStartTokenBalance = initial loan principal + positive prior-round profit
```

Each round can be smaller than the available balance because v4 movement, external capacity, spread, and minimum chunk are recomputed.

At fixed Base block `50018808`, an identical 100 USDC trigger produced:

| Bound | Completed rounds | WETH traded | Net WETH profit | Residual gap |
|---:|---:|---:|---:|---:|
| 1 | 1 | `0.008916275255831863` | `0.000427855387719440` | 434 ticks |
| 10 | 10 | `0.038512027703384331` | `0.001247055334869567` | 134 ticks |

The result demonstrates why the one-round stopgap was incomplete: later rounds remained profitable after live repricing.

## 8. V4 Settlement Details

The v4 leg uses exact input:

```text
amountSpecified = -int256(route.principal)
```

After `PoolManager.swap`, the executor requires:

- a negative input delta; and
- a positive output delta.

It pays exactly the actual input delta, not the requested maximum, and takes exactly the actual output. Any failure reverts the nested swap and its transient deltas.

The hook passes empty nested hook data, but recursion safety does not depend on that emptiness. v4's hook library skips callbacks when `msg.sender` is the hook itself.

## 9. External V3 Swap And Callback Authentication

Before the external swap, the executor stores a transient hash of:

```text
external pool + callback data(tokenIn, payer, amountIn, pool)
```

Uniswap V3 and PancakeSwap V3 callbacks on `ArbHook` require that exact single-use context and exact calling pool before transferring owed input. The callback consumes the context; the executor clears it when no callback ran.

A merely registered pool cannot call later and spend hook balances.

## 10. Failed Later Leg And Residue Unwind

A V3 call can fail after the v4 leg succeeded. The executor then stops normal iteration and tries to convert only attempt-created intermediate residue through the same external pool with the broad protocol sqrt-price boundary.

Pre-existing intermediate balance is never spent. After unwind, the intermediate balance must equal its entry snapshot exactly. Otherwise the flash callback reverts, rolling back every prior round.

Any start-token gain or loss from unwind is included in the executor result. Final settlement does not trust that reported result; it measures balances independently.

## 11. Authoritative Settlement

`onFlashLoan` snapshots `startToken` after receiving principal and snapshots `intermediateToken` before execution.

After the module returns:

```text
netProfit = startBalanceAfter - startBalanceBefore - lenderFee
```

Settlement requires:

- at least one successful round;
- exact intermediate-balance restoration;
- positive net profit;
- net profit at least `minNetProfit`; and
- enough remaining start token for principal plus fee after beneficiary payment.

The beneficiary comes from transient callback context. Profit is transferred first, leaving exactly the principal and fee available for the authenticated lender to pull. Any failure reverts the loan, all nested swaps, and the payout atomically.

## 12. Why This Is Bounded Rather Than Exact

An exact concentrated-liquidity optimum would need detailed initialized-tick traversal across both venues and would still need to account for fees, changing active liquidity, rounding, and gas. That is inappropriate inside a general user swap callback.

The implemented model instead:

- uses current active liquidity;
- bounds each venue with a sqrt-price limit;
- caps movement;
- respects the shallower venue's capacity;
- checks fee-adjusted edge before trading;
- measures real marginal profit after each round; and
- stops under an operator-configured iteration and gas ceiling.

It seeks repeated safe profitable steps. It does not claim to close every last unit of spread.

## 13. Preserved Legacy Scanner

The original non-hook strategy remains in `ArbHook` and `ArbitrageLogic` for regression and research:

```text
supportedTokens outer loop
  -> baseCounterList inner loop
  -> find cheapest external buy and richest external sell
  -> one fallback route
  -> V3/V3, V2/V2, or mixed iterative executor
```

Production `afterSwap` does not call this scanner. `ArbHookHarness.attemptAllForTest` invokes it through a test-only self-call so the fixed historical oracle remains exact.

`ArbHookParity.t.sol` asserts the prior inventory-funded sequence and `18,679,602` raw USDC total. `ArbHookFlashForkAave.t.sol` exercises the same natural external route sequence with lender adapters. Those tests protect legacy logic during the self-pool refactor; they do not describe the current production callback route.

## 14. Current Limits

- Only ERC20/ERC20 triggering pools are eligible.
- The production return leg supports Uniswap V3 and PancakeSwap V3, not V2.
- The external reference is selected once per callback, not once per round.
- A direction without reference registration and flash configuration safely skips.
- Ten rounds at the pinned test block still left 134 ticks; the bound is a risk/gas control, not a guarantee of full convergence.
- At that snapshot, 20 rounds settled under the default 3,000,000-gas attempt
  budget and captured about 99% of the 31-round high-gas diagnostic profit. A
  25-round cap exhausted the default attempt budget and settled nothing. The
  iteration cap and gas budget must therefore be calibrated as one setting.
- The current hook is close to its project runtime budget, so new onchain features should be justified by measurable execution value.
