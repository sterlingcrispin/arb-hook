# Arb Hook

`ArbHook` is a Uniswap v4 `afterSwap` hook that uses swap callbacks as permissionless execution triggers for a deterministic multi-pool arbitrage scanner. It compares registered external pools, borrows the selected route's base token, runs the existing bounded iterative executor, repays atomically, and pays realized net profit to the swap initiator resolved through the router.

The hook does not trade the v4 pool that triggered it. The trigger and the arbitrage market are independent. No trading inventory or v4 liquidity owned by this project is required.

## Execution Flow

When `hookMaxIterations` is nonzero, every supported `afterSwap` callback follows this path:

1. Verify that the immutable Uniswap v4 `PoolManager` called the hook.
2. Resolve a profit recipient from the router or exact packed hook data.
3. Enter a gas-bounded self-call so route failures do not revert the triggering swap.
4. Walk registered base tokens in first-registration order.
5. Walk each base token's registered counter tokens in first-registration order.
6. For each pair, quote all pools registered under that base token and select the lowest effective buy price and highest effective sell price after fees.
7. Try the best route. If it fails, exclude that sell pool and make one fallback discovery attempt.
8. Derive flash principal from the existing route-specific sizing math, bounded by the configured cap and lender liquidity.
9. Borrow the base token and run `executeIterativeArb` with the configured iteration limit.
10. Recompute a candidate chunk from live pool state before every iteration, execute both legs, and stop at the configured bound or when the marginal result is no longer useful.
11. Require the intermediate-token balance to return exactly to its entry value.
12. Measure realized base-token profit, deduct the lender fee, enforce `minNetProfit`, pay the beneficiary, and approve exact repayment.
13. Stop scanning after the first profitable pair.

The triggering v4 swap only supplies timing and a beneficiary. It does not determine the token pair, route direction, principal, or profit token. The user's normal swap output is unchanged; successful arbitrage pays a separate transfer in the registered route's base token.

## Route Ordering

Pool registration is part of strategy configuration:

- `supportedTokens` records base tokens in first-seen order.
- `baseCounterList[base]` records unique counterpart tokens in first-seen order.
- `tokenPools[base]` contains every venue considered for that base.
- The scanner stops after the first profitable base/counter pair.

Changing registration order can therefore change which opportunity executes when more than one is profitable. Registration is append-only, so a bad pre-launch pool book should be corrected with a new hook deployment.

Current executable pool types are:

- Uniswap V3
- Uniswap V2
- PancakeSwap V3
- PancakeSwap V2

## Iterative Sizing

`hookMaxIterations` is a real execution bound, not an enable flag disguised as one. The same value travels through:

```text
afterSwap
  -> attemptAllInternal(maxIterations)
  -> _runPair(..., maxIterations)
  -> executeIterativeArbViaFlash(..., maxIterations)
  -> onFlashLoan
  -> executeIterativeArb(..., maxIterations)
```

The executor preserves the original route-specific sizing behavior:

- V3/V3 uses current ticks, active liquidity, fee-aware prices, bounded impact, and the existing V3 chunk refinement.
- V2/V2 uses reserves and fee-aware probe/simulation logic.
- Mixed V2/V3 routes use the existing bounded mixed-route search.
- Every execution iteration rereads live state and recalculates its chunk.
- The loop exits early when spread, size, swap success, or marginal-profit guardrails say to stop.

Flash borrowing wraps this engine rather than replacing it. The configured principal is a ceiling. Route math chooses a smaller amount when appropriate, lender availability applies another cap, and V3/V3 can retry a refined smaller principal after a retryable coarse failure.

An exact concentrated-liquidity optimum would require substantially more on-chain state traversal. The existing bounded search intentionally seeks profitable steps rather than claiming a global optimum.

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

## Flash Accounting

For each configured base token:

- `setLenderForToken(token, lender)` binds one ERC-3156 lender or adapter.
- `setFlashPrincipalForToken(token, cap)` sets the maximum principal. Zero disables borrowing.
- `setMaxFlashFeeBpsForToken(token, cap)` sets the maximum accepted lender fee. Zero disables borrowing.
- `setMinNetProfitForToken(token, floor)` sets the minimum realized profit after the lender fee. Zero disables borrowing.

A successful callback must satisfy all of the following:

- lender, initiator, token, principal, and calldata hash match the active transient context;
- the route restores the intermediate-token balance exactly;
- the base-token result covers principal and fee;
- realized net profit is positive and reaches `minNetProfit`; and
- the lender can pull exactly principal plus fee.

Pre-existing or donated hook balances are excluded from route sizing and cannot be counted as profit. The owner can recover unrelated balances with `removeTokens` or `removeEth`.

## Gas Boundary

`afterSwap` isolates speculative execution behind a low-level self-call.

- `hookGasReserve`, default `200000`, is withheld for the triggering swap's remaining settlement.
- `hookGasLimit`, default `3000000`, is the attempt budget and ceiling.
- A nonzero gas limit is also a floor: an enabled swap without more than `reserve + limit` gas reverts with `InsufficientHookGas` instead of silently succeeding without the arbitrage attempt.
- A zero gas limit uses all gas above the reserve and does not enforce that floor.
- `_runPair` gives each route self-call half of the scanner's remaining gas, so later pairs receive geometrically less gas.

The gas floor is deliberate but operationally significant. Router gas estimation and the size/order of the registered pool book must be tested before enabling a deployment.

## Configuration

Execution starts disabled.

- `setHookMaxIterations(value)`
  - `0` disables callback execution.
  - A positive value is the maximum number of sizing-and-swap rounds inside the selected flash loan.
  - The historical parity configuration uses `2`.
- `setMinSpreadBps(value)`
  - Default `10`.
  - Applies to V3/V3 directional tick spread before sizing.
- `setChunkSpreadConsumptionBps(value)`
  - Default `1500`.
  - Controls how aggressively V3/V3 sizing consumes the remaining spread.
- `setMaxImpactBps(value)`
  - Default `500`.
  - Caps modeled V3 impact used to derive price limits.
- `setHookGasBounds(reserve, limit)`
  - Defaults to `200000` and `3000000`.

There is no trigger-swap-size threshold. Once enabled and given a valid recipient, the scanner runs on every callback and lets route discovery and economic checks decide whether to borrow.

## Safety Model

The research deployment model assumes a trusted owner registers a small set of manually reviewed canonical tokens, pools, and lenders. Protecting the owner from intentionally registering a malicious asset is out of scope.

Runtime boundaries remain strict:

- only the immutable v4 `PoolManager` can call `afterSwap`;
- flash callbacks are bound to one active lender request;
- V2 and V3 swap callbacks are single-use and bound to the exact active pool and calldata;
- both route legs are atomic with flash repayment;
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

Historical exact inventory oracle:

```bash
RUN_LEGACY_INVENTORY_PARITY=true BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookParityTest \
  --match-test testAttemptAllOnForkMatchesArbLightweightFlow -vv
```

Morpho-funded sequence on the same fixed block and pool order:

```bash
RUN_FLASH_FORK_INTEGRATION=true BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookFlashForkAaveTest \
  --match-test testForkMorphoAttemptAllTracksLegacyRoundSequenceFull -vv
```

The inventory oracle's exact reference is `18,679,602` raw USDC across ten rounds. The flash suite uses the same natural route sequence and validates positive net settlement without prefunding the hook.

`foundry/test/ArbHookFlashLoanE2E.t.sol` includes a callback-level regression proving that an `afterSwap` configured with two iterations reaches the registered-pool scanner and passes `2` into the iterative executor. This test exists specifically to prevent a one-shot callback path from bypassing the original engine again.

## Deployment Status

There is no active production canary or current market-specific launch runbook.

The former Base WETH/USDC self-pool canary has been retired. It used a temporary one-round implementation that traded the hook's own v4 pool, did not consume the full edge, and was followed by an external backrun. The hook was disabled, its principal cap was set to zero, and its LP position was burned. Receipts and final balances remain in [`docs/BASE_WETH_CANARY_DEPLOYMENT.md`](docs/BASE_WETH_CANARY_DEPLOYMENT.md) as historical evidence only.

The retired manifest and runbook are preserved as warnings, not instructions. The associated LP, one-pool registration, and controlled-swap scripts have been removed. A future deployment needs a new external pool book with at least two viable venues for each base/counter pair, current fork validation, gas calibration, and an explicit decision about the weak causal relationship between an arbitrary v4 trigger and an external-pool opportunity.

`script/DeployArbHook.s.sol` deploys the linked logic, lender adapters, and CREATE2-mined after-swap hook. `script/ConfigureArbHook.s.sol` configures flash economics for one token but does not register pools or enable execution.

## Legacy Parity Context

The parity suite compares against the previous non-hook, inventory-funded arbitrage system. Its golden artifacts are:

- `ParityTest/ArbLightweight.sol`
- `ParityTest/ArbLightweight.attemptAll.js`
- `ParityTest/attemptAllOutput.txt`

The exact route order and `18.679602 USDC` total remain regression oracles for the original route planner and iterative math. `ParityTest/ArbLightweight.attemptAll.js` is reference-only and must not be rerun.
