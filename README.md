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
