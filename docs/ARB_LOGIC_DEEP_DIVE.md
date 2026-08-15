# ArbHook Logic Deep Dive

This note separates the production V4/V3 hook route from the legacy external/external engine retained in `ArbHookHarness` for parity.

Relevant files:

- `contracts/ArbHook.sol`
- `contracts/ArbitrageLogic.sol`
- `contracts/ArbUtils.sol`
- `contracts/test/ArbHookHarness.sol`

## 1. Production Route Model

The triggering v4 pool is both the execution trigger and the first arbitrage leg.

For a trigger direction:

- `startToken` is the user's output token. It is also the flash-loan, repayment, and profit token.
- `intermediateToken` is the user's input token.
- the hook's V4 swap runs opposite the user's swap;
- the external V3 swap converts the intermediate token back to the start token; and
- the first registered matching concentrated pool under `startToken` is the reference venue.

For the WETH/USDC canary:

```text
user: USDC -> WETH in hooked v4
hook: WETH -> USDC in the same v4 pool
hook: USDC -> WETH in canonical v3
```

The production path does not traverse `supportedTokens` or compare unrelated external pools. Those data structures remain because the parity harness still exercises the historical scanner.

## 2. `afterSwap` Failure Boundary

`afterSwap` performs only cheap gating before the speculative self-call:

1. Require the immutable PoolManager as caller.
2. Require `hookMaxIterations != 0`.
3. Decode exactly 20 bytes of beneficiary hook data.
4. Store the beneficiary in transient storage.
5. Call `attemptHookPoolInternal` with an explicit gas budget.
6. Clear the transient beneficiary and return zero hook delta.

The self-call is important. Any deep revert from pool lookup, lender quoting, V4 settlement, V3 execution, repayment, or profit enforcement is caught by the low-level call and does not bubble into the user's swap.

`hookGasReserve` is withheld for the caller's remaining settlement. `hookGasLimit` caps the speculative attempt. The production route does not use the legacy scanner's geometric per-pair gas subdivision.

## 3. Reference Pool Selection

`attemptHookPoolInternal` derives the exact pair from the triggering `PoolKey` and direction. It walks `tokenPools[startToken]` until it finds the first entry that:

- is Uniswap V3 or PancakeSwap V3; and
- contains exactly `startToken` and `intermediateToken`.

The first match is intentional. External liquid venues should already track the wider market closely, and the hooked pool's own swap creates the edge. Runtime cheapest-pool discovery would reread every candidate on every user swap without changing the product thesis.

Registration order is therefore configuration. The operator registers the desired deep canonical reference first.

## 4. Directional Fee And Spread Check

`ArbitrageLogic.getLiveV4V3RouteParams` reads:

- post-swap v4 `sqrtPriceX96` and tick;
- active v4 liquidity;
- active LP fee;
- directional v4 protocol fee;
- external V3 price, tick, and active liquidity; and
- registered token decimals and fee.

The direction is fixed by the triggering swap. The hook cannot reverse it merely because the opposite direction looks profitable; doing so would amplify rather than counter the user's price impact.

The route is rejected when:

- either venue has zero active liquidity;
- the registered pair or token ordering is inconsistent;
- the external venue type is unsupported;
- the directional tick spread is below `minSpreadBps`; or
- the effective V4 sell price does not exceed the effective external buy price after both fees.

The tick threshold is a cheap gate. Realized balance accounting is the final profitability test.

## 5. Why The First Size Starts Where It Does

An exact concentrated-liquidity optimum would require following initialized ticks on both venues while accounting for two changing price curves. That is too expensive in a hook callback.

The production route instead chooses a local target movement:

```text
move = spread * (chunkSpreadConsumptionBps + 2000 * spread / initialSpread)
       / (2 * 10000)
```

On the first V4/V3 attempt, `initialSpread == spread`. With the defaults:

```text
move = spread * (1500 + 2000) / 20000
     = spread * 17.5%
```

The division by two approximates sharing convergence between two legs rather than asking one venue to consume the whole target. `maxImpactBps`, currently 500, caps the movement. A zero rounded movement becomes one tick.

The logic then:

1. Converts the target v4 tick into a pool-enforced square-root price limit.
2. Calculates the start-token input and intermediate output needed to reach that limit at current active liquidity.
3. Calculates how much intermediate input the external pool can absorb over the same bounded movement and retains that target as the external leg's enforced price limit.
4. Scales the v4 input down if its output would exceed external capacity.
5. Caps the result by configured principal and lender availability.
6. Rejects values below `_minChunk(startToken)`.

This is intentionally a bounded local estimate. It does not claim that liquidity remains constant across every crossed initialized tick. Pool price limits, atomic revert behavior, and realized profit checks are authoritative when the estimate is imperfect.

## 6. Principal Retries

The first flash request uses the adaptive principal. If the lender or route reverts for a retryable reason, the hook tries one-half and then one-quarter of that amount.

It does not retry when:

- the lender fee quote fails;
- the quoted fee exceeds its cap;
- the lender returns false without reverting;
- profit was positive but below `minNetProfit`; or
- the next size is below the token's minimum chunk.

The below-minimum distinction matters because retrying a smaller version of an already positive but insufficient result cannot reasonably clear a fixed minimum-profit floor, while it can consume the user's gas budget.

## 7. Nested V4 Execution And Settlement

The ERC-3156 callback recognizes the production route because `sellPool` is the immutable PoolManager address. It decodes the authenticated PoolKey and both price limits, then calls `PoolManager.swap` while the original unlock is still active.

The nested swap does not recursively execute the same hook attempt because Uniswap v4 skips a hook callback when the hook itself is the PoolManager caller.

After the nested swap, `_executeV4Swap`:

1. Verifies the input delta is owed and the output delta is receivable.
2. Calls `sync` for the input currency.
3. Transfers the exact input to PoolManager.
4. Calls `settle`.
5. Calls `take` for the exact output.

The hook then executes the external concentrated-liquidity leg with its computed
price limit and the existing single-use V3 callback context.

## 8. Realized Flash Accounting

`onFlashLoan` snapshots:

- start-token balance after receiving principal; and
- intermediate-token balance before route execution.

After both legs:

- intermediate balance must equal its snapshot exactly;
- `netProfit = balanceAfter - balanceBefore - fee`;
- net profit must be positive and meet `minNetProfit`;
- net profit is transferred to the authenticated beneficiary;
- repayment approval is set to exactly principal plus fee; and
- `FlashLoanSettled` records the completed route.

Pre-existing or donated balances are not part of adaptive principal sizing and cannot be treated as route profit.

## 9. Legacy Scanner And Loops

The historical engine remains intact for regression testing but its scanner and flash entrypoints are exposed only by `ArbHookHarness`.

### `_attemptAllInternal(maxIterations)`

- Iterates `supportedTokens` in registration order.
- Iterates each base token's `baseCounterList` in registration order.
- Calls `_runPair` for each pair.
- Stops at the first profitable pair.

### `_runPair(tokenA, tokenB, maxIter)`

- Finds the best external buy and sell pools.
- Executes through an isolated self-call.
- On a failed first route, excludes its sell pool and tries one fallback.
- Gives each route half of the scanner's remaining gas.

### `executeIterativeArb`

For each bounded legacy iteration:

1. Recompute a chunk from current pool state.
2. Execute start to intermediate and intermediate back to start.
3. Measure realized marginal profit.
4. Stop when marginal profit is non-positive.
5. Restore any residual intermediate-token delta before returning.

This engine supports Uniswap V2/V3 and PancakeSwap V2/V3 combinations. It exists to preserve the exact non-hook reference sequence and flash-migration regressions. It is not called by production `afterSwap`.

## 10. Callback Safety

V3 callbacks require:

- the exact active `(pool, callback data)` hash;
- a single-use transient context;
- `msg.sender` equal to the expected registered pool;
- the decoded input token in that pool; and
- the expected positive repayment delta.

V2 callbacks retained for the legacy harness additionally require:

- the canonical factory-derived pair address;
- local V2 registration with matching token ordering; and
- the exact active callback context.

Flash callbacks require the configured active lender, this contract as initiator, exact token and amount, and the hash of the complete loan calldata.
