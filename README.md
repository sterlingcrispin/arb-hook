# Arb Hook

`ArbHook` is a Uniswap v4 `afterSwap` hook that counter-trades the pool that just moved. A triggering swap can dislocate the v4 pool from a registered V3-compatible reference venue; the hook borrows the triggering swap's output token, sells it back into v4, buys it back externally, repays atomically, and pays realized net profit to the resolved swap initiator.

The production callback uses the triggering pool and one external reference for the same token pair. It does not wait for an unrelated opportunity in two external pools. The original multi-pool scanner and V2/V3 iterative executor remain in the codebase as the historical parity engine, but `afterSwap` no longer dispatches that scanner.

## Production Flow

When `hookMaxIterations` is nonzero, an eligible `afterSwap` callback follows this path:

1. Require the immutable Uniswap v4 `PoolManager` as caller.
2. Resolve the profit recipient from the router or exact packed hook data.
3. Enter a gas-bounded self-call so a failed arbitrage attempt does not revert the user's swap.
4. Derive `startToken` from the triggering swap's output and `intermediateToken` from its input.
5. Reject native-currency pairs. The current route supports ERC20/ERC20 v4 pools only.
6. Find the cheapest registered Uniswap V3 or PancakeSwap V3 reference for that exact pair under `tokenPools[startToken]`.
7. Read current v4 and external ticks, active liquidity, and directional fees.
8. Require the directional spread and fee-adjusted prices to support selling `startToken` into v4 and buying it back externally.
9. Derive an initial principal from the bounded price movement and both venues' active-liquidity capacity, then clamp it to the configured cap and lender availability.
10. Take one flash loan for that principal.
11. Inside the callback, repeatedly reread both pools and recompute the next chunk before each round.
12. For each profitable round, sell `startToken` into the triggering v4 pool and buy it back in the external reference pool.
13. Stop at `hookMaxIterations` or earlier when spread, liquidity, minimum chunk, swap success, or marginal profit says to stop.
14. Require exact intermediate-token restoration, deduct the lender fee, enforce `minNetProfit`, pay the beneficiary, and approve exact repayment.

The user's ordinary v4 swap output is not modified. A successful arbitrage produces a separate transfer in the triggering swap's output token.

A nested v4 counter-swap does not recursively invoke this hook. Uniswap v4 skips hook callbacks when the hook itself calls `PoolManager.swap` for that pool.

## Reference Registration

Production reference selection is directional:

- `tokenPools[startToken]` is scanned in registration order.
- Only pools containing the exact v4 token pair are eligible.
- Only Uniswap V3 and PancakeSwap V3 references are eligible for the self-pool route.
- The lowest current fee-adjusted buy price for `startToken` wins.
- Equal prices preserve first-registration order.

Registration and flash configuration must exist for every output-token direction intended to execute. For a WETH/USDC v4 pool:

- a USDC-to-WETH trigger needs the reference registered under WETH and a WETH lender/config;
- a WETH-to-USDC trigger needs the reference registered under USDC and a USDC lender/config.

A missing direction safely skips arbitrage without reverting the user's swap.

The registry is append-only. Correct a bad pre-traffic registration with a fresh hook deployment.

## Adaptive Loop

`hookMaxIterations` is the actual number of permitted counter-trade rounds:

```text
afterSwap
  -> attemptTriggerPoolInternal(key, triggerDirection, maxIterations)
  -> one ERC-3156 flash loan
  -> onFlashLoan
  -> V4ArbExecutor
       -> read live v4 and V3 state
       -> derive bounded chunk and both price limits
       -> v4: startToken -> intermediateToken
       -> V3: intermediateToken -> startToken
       -> measure marginal profit
       -> repeat from new live state
```

The first route calculation chooses the amount to borrow. Later rounds do not take additional loans. Their sizing balance is:

```text
borrowed principal + positive profit from completed prior rounds
```

Pre-existing or donated hook balances do not expand trade size.

The movement window preserves the original adaptive stepping model:

```text
move = remainingSpread
     * (chunkSpreadConsumptionBps + 2000 * remainingSpread / initialSpread)
     / (2 * 10000)
```

With defaults, early rounds move each venue by up to roughly 17.5% of the initial gap, later rounds shrink toward 7.5% of the remaining gap, and `_MAX_IMPACT_BPS = 500` caps one venue's modeled tick movement. Each round derives token amounts from current active liquidity and clamps the v4 input to what the external venue can absorb within its own price limit.

This is intentionally a bounded profitable-step solver, not an exact tick-by-tick optimum. Exact optimization would require substantially more onchain traversal. Repricing after every round is what safely captures more edge than the retired one-shot implementation.

## Profit Recipient

With empty `hookData`, the hook calls `IMsgSender.msgSender()` on the callback's router address. Base's canonical Universal Router exposes the caller holding its execution lock:

- a wallet calling Universal Router directly receives the profit;
- a user-owned smart account receives the profit;
- an intermediary calling Universal Router is the immediate recipient and is responsible for forwarding any extra token balance.

The lookup is capped at 10,000 gas. If the router does not support `IMsgSender`, returns zero, or reverts, the hook skips arbitrage rather than using `tx.origin` or guessing.

Exactly 20 packed bytes remain an optional explicit-recipient override:

```solidity
abi.encodePacked(beneficiary)
```

Malformed nonempty data and a packed zero address skip execution.

The selected recipient is held in transaction-scoped transient storage through the synchronous flash callback. It is not redundantly serialized into the loan payload.

## Flash Accounting

For each possible `startToken`:

- `setLenderForToken(token, lender)` binds one ERC-3156 lender or adapter.
- `setFlashPrincipalForToken(token, cap)` sets the maximum borrowed principal. Zero disables the token.
- `setMaxFlashFeeBpsForToken(token, cap)` sets the maximum accepted lender fee. Zero disables the token.
- `setMinNetProfitForToken(token, floor)` sets the minimum realized profit after the lender fee. Zero disables the token.

A successful callback requires:

- lender, initiator, token, principal, and calldata hash to match the active transient context;
- the registered external pool and triggering v4 key to match the encoded route;
- the intermediate-token balance to return exactly to its entry value;
- realized `startToken` profit to be positive and at least `minNetProfit` after the lender fee; and
- enough remaining `startToken` for exact principal-plus-fee repayment after beneficiary payment.

Any failure reverts the loan, both arbitrage legs, and payout atomically. The outer self-call contains that failure so the original user swap can still settle.

## Gas Boundary

- `hookGasReserve`, default `200000`, is withheld for the triggering swap's remaining settlement.
- `hookGasLimit`, default `3000000`, is the arbitrage attempt budget and ceiling.
- A nonzero limit is also a floor: an eligible swap without more than `reserve + limit` gas reverts with `InsufficientHookGas` instead of silently estimating a cheaper no-arbitrage branch.
- A zero limit uses all gas above the reserve and does not enforce that floor.

At Base block `50018808`, the fixed fork test completed ten adaptive rounds under the default attempt budget. Router estimation and realistic pool liquidity must still be tested for each deployment configuration.

Diagnostic sweeps at that same snapshot show why iteration and gas settings must
be calibrated together. Twenty rounds settled under the default attempt budget
and captured `0.001313458837594588 WETH`; 25 exhausted that budget and the
contained attempt produced no settlement. With an 8,000,000-gas diagnostic
budget, the route stopped naturally after 31 rounds at
`0.001321853496019977 WETH`. Higher iteration caps are not automatically better.

## Configuration

Execution starts disabled.

- `setHookMaxIterations(value)`
  - `0` disables callback execution.
  - A positive value bounds live sizing-and-swap rounds inside one loan.
- `setMinSpreadBps(value)`
  - Default `10`.
  - Minimum directional v4/reference tick spread before a round can execute.
- `setChunkSpreadConsumptionBps(value)`
  - Default `1500`.
  - Base component of the adaptive movement formula.
- `setMaxImpactBps(value)`
  - Default `500`.
  - Caps the modeled tick movement used to form each venue's price limit.
- `setHookGasBounds(reserve, limit)`
  - Defaults to `200000` and `3000000`.

There is no hardcoded trigger-size threshold. Every callback with a valid recipient enters route screening; no loan is requested when the live spread, fee-adjusted edge, or minimum chunk is insufficient.

## Safety Model

The research deployment assumes a trusted owner registers a small set of manually reviewed canonical tokens, pools, and lenders. Permissionless registry hardening is out of scope.

Runtime boundaries remain strict:

- only the immutable v4 `PoolManager` can call `afterSwap`;
- the speculative path is gas-bounded and revert-contained;
- flash callbacks are bound to one active lender request;
- V3 swap callbacks are single-use and bound to the exact active pool and calldata;
- both route legs and repayment are atomic;
- intermediate-token residue cannot settle;
- realized balances, not estimates, decide final profitability;
- donated balances do not expand principal sizing; and
- ownership renunciation is disabled so the owner cannot permanently destroy the kill switch.

## Tests

Fast local gate:

```bash
forge test --summary
npm run size
```

Fixed-block one-round versus looping proof:

```bash
RUN_V4_LOOP_FORK=true BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookV4LoopForkTest -vv
```

At Base block `50018808`, the identical 100 USDC trigger produced:

| Bound | Completed rounds | WETH traded | Net WETH profit | Residual gap |
|---:|---:|---:|---:|---:|
| 1 | 1 | `0.008916275255831863` | `0.000427855387719440` | 434 ticks |
| 10 | 10 | `0.038512027703384331` | `0.001247055334869567` | 134 ticks |

The test also proves exact Morpho repayment and zero WETH/USDC residue in the hook.

The ten-round result captures roughly 94% of the 31-round high-gas diagnostic's
profit at this one snapshot. That percentage is not portable to another pool,
liquidity profile, trigger size, or block.

Pinned v4 liquidity, fee, trigger-size, iteration, and principal-cap sweeps:

```bash
BASE_RPC_URL="$BASE_RPC_URL" python3 scripts/sweep_v4_pool.py \
  --fork-block 50052773
```

The standard 140-scenario grid and a 144-scenario low-fee/depth frontier showed:

- the deep Uniswap v3 WETH/USDC pool was consistently a better reference and execution venue than the shallow pool;
- with ordinary `1 bp` and `5 bp` v4 fees, no tested route beat the deep `5 bp` v3 route after execution gas, even after paying the hook profit to the swapper;
- the closest standard row used roughly `$2,000` per side in a `+/-2.5%` range, a `1 bp` fee, and a `$100` trigger; it completed three rounds and remained `1.31 bp` worse after the rebate;
- a frontier row with roughly `$4,000` per side, a `+/-2.5%` range, a `0.01 bp` fee, and a `$150` trigger beat the benchmark by `0.08 bp` before and `0.60 bp` after its rebate, but captured only `52.3%` of the backrun opportunity; and
- increasing the tested principal cap above `5%` did not change tuned results. Ten rounds generally balanced capture and gas better than fifteen.

The frontier margin is small enough that costs omitted by the harness, including Base L1 data and priority fees, may erase it, so it is not a deployment recommendation. Results are per triggering swap, not a daily-profit forecast. The ignored JSON and CSV artifacts preserve every measured balance, gas value, backrun, and derived metric locally.

Observed Base WETH/USDC swap-flow model:

```bash
BASE_RPC_URL="$BASE_RPC_URL" python3 scripts/model_swap_flow.py \
  --days 7 --end-block 50054168 \
  --sweep-results artifacts/flow-frontier-low
```

The fixed sample covers Base blocks `49751768..50054168`, or exactly seven days from `2026-08-09 16:28:03 UTC` through `2026-08-16 16:28:03 UTC`. The script decodes the exact USDC leg from `654,320` swap events across seven WETH/USDC pools:

| Pool | Swaps/day | USDC volume/day | Median | p90 | p99 | Swaps >= $100/day |
|---|---:|---:|---:|---:|---:|---:|
| Uniswap v3 1 bp | 31,645 | $2.09m | $8.25 | $218 | $583 | 6,668 |
| Uniswap v3 5 bp | 10,841 | $5.49m | $9.31 | $1,428 | $5,707 | 3,990 |
| Uniswap v3 30 bp | 3,756 | $23.24m | $37.09 | $11,826 | $123,665 | 1,684 |
| Pancake v3 1 bp | 28,368 | $23.91m | $355 | $2,322 | $5,462 | 19,257 |
| Aerodrome Slipstream 5 bp A | 8,482 | $40.77m | $2,422 | $10,679 | $37,401 | 7,831 |
| Aerodrome Slipstream 5 bp B | 8,316 | $17.24m | $749 | $5,414 | $17,301 | 6,445 |
| Uniswap v4 5 bp comparison pool | 2,067 | $46,418 | $2.37 | $58.46 | $137 | 52.4 |

The model uses empirical size quantiles and threshold rates rather than forcing the multimodal flow into one distribution. It records descriptive log-space moments and a Pareto tail above each pool's p90, but those fits are secondary. Hourly arrivals are modeled by a method-of-moments negative binomial when variance exceeds the mean. The deep Uniswap v3 5 bp pool has a Fano factor of `91.06`, so swaps arrive in bursts; a constant-rate or Poisson simulation would materially understate quiet and busy periods.

The deep 5 bp pool is an upper-flow reference, not a forecast for a new pool. Randomly receiving `0.1%`, `1%`, or `5%` of its observed flow would imply about `10.8`, `108.4`, or `542.0` swaps/day, with `4.0`, `39.9`, or `199.5` swaps of at least `$100`. The live v4 comparison is a more conservative empirical reference: it saw `52.4` swaps of at least `$100` per day, `5.4` of at least `$250`, `0.9` of at least `$500`, and none of at least `$1,000` during the sample.

The reset-per-trigger projection produced by that first flow model is superseded
by the persistent, bidirectional replay:

```bash
python3 scripts/replay_v4_strategy.py \
  --capitals 250,500,2000,10000 \
  --ranges 300 --fees 1500 \
  --hook-modes on --principal-caps 100 \
  --max-iterations 10 --min-profits 0.05 \
  --discovery-shares 0.1,1,10,100
```

The replay keeps candidate liquidity, inventory, and fees across all 622,266
transaction-level orders; compares candidate output with observed source output;
and mirrors the production adaptive v4/V3 loop. In the full-flow optimization
ceiling, the return-efficient region was roughly `$2,000` per side, `+/-300`
ticks, and a `15 bp` fee. A small-capital canary favored roughly `$250..$500`
per side, `+/-300` ticks, and `10 bp`.

Those are configuration rankings, not revenue forecasts. Uniswap's production
routing API filters non-allowlisted hooks, so canonical UI/API flow is
conditional on allowlisting the exact deployed hook. Route discovery is swept
explicitly rather than assumed, and low-discovery results are near break-even.
See [`docs/BASE_WETH_USDC_STRATEGY_REPLAY.md`](docs/BASE_WETH_USDC_STRATEGY_REPLAY.md)
for methodology, reference-pool results, sensitivity tables, and the canary
decision sequence.

Robinhood Chain WETH/USDG research used a separate three-day, 693,667-event
sample and USDG-only Morpho execution. The optimized full-discovery ceiling was
about `$10.40/day` at `$500` per side, `+/-50` ticks, and `10 bp`; the known-router
subset was `$4.31/day`. Most of that result is LP fee income, while modeled hook
profit of about `$1.03/day` is paid to swap callers. Base remains the stronger
modeled first target, but Robinhood has enough positive evidence for a separate
`$250..$500`-per-side canary after its deployment path, fixed-block integration
test, hook allowlisting, and live quote verification are complete. See
[`docs/ROBINHOOD_WETH_USDG_STRATEGY_REPLAY.md`](docs/ROBINHOOD_WETH_USDG_STRATEGY_REPLAY.md).

Historical exact inventory oracle:

```bash
RUN_LEGACY_INVENTORY_PARITY=true BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookParityTest \
  --match-test testAttemptAllOnForkMatchesArbLightweightFlow -vv
```

Morpho-funded legacy route sequence:

```bash
RUN_FLASH_FORK_INTEGRATION=true BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookFlashForkAaveTest \
  --match-test testForkMorphoAttemptAllTracksLegacyRoundSequenceFull -vv
```

The inventory oracle's exact reference is `18,679,602` raw USDC across ten rounds. These legacy gates protect the original external route planner and executor; they are not the production self-pool callback model.

## Deployment Status

There is no active production canary or current market-specific launch runbook.

The former Base WETH/USDC canary was retired because its temporary one-round implementation left a large profitable gap for an external backrunner. Its hook was disabled, its principal cap was zeroed, and its LP position was burned. Receipts remain in [`docs/BASE_WETH_CANARY_DEPLOYMENT.md`](docs/BASE_WETH_CANARY_DEPLOYMENT.md) as historical evidence.

The current source fixes that specific implementation failure by performing repeated live-repriced rounds. It has not redeployed the retired canary. A new deployment still needs current-head simulation, a reviewed reference venue and lender configuration for each enabled direction, gas calibration, a calibrated `minNetProfit`, and a new runbook from the reviewed release commit.

Current optimized runtime sizes are enforced by `npm run size`. `ArbHook` is `23,818` bytes, below the repository's `24,000`-byte budget and EIP-170; `V4ArbExecutor` is a separate immutable delegate-called execution module so the original route logic does not have to be deleted for deployability.

`script/DeployArbHook.s.sol` deploys the pricing logic, lender adapters, CREATE2-mined hook, and its immutable executor. `script/ConfigureArbHook.s.sol` configures flash economics for one token but does not register reference pools, initialize v4 liquidity, or enable execution.

## Legacy Parity Context

The parity suite compares against the previous non-hook, inventory-funded arbitrage system. Its golden artifacts are:

- `ParityTest/ArbLightweight.sol`
- `ParityTest/ArbLightweight.attemptAll.js`
- `ParityTest/attemptAllOutput.txt`

The exact route order and `18.679602 USDC` total remain regression oracles for the original route planner and iterative math. `ParityTest/ArbLightweight.attemptAll.js` is reference-only and must not be rerun.
