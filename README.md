# Arb Hook

`ArbHook` is a Uniswap v4 `afterSwap` hook that returns a swap-created arbitrage edge to the swapper who created it.

The production route is not a generic background scanner. It uses the triggering v4 pool as the first arbitrage leg and one registered concentrated-liquidity pool for the same token pair as the reference and exit venue. Flash-loaned principal means the hook does not need to hold trading inventory.

## Production Mechanism

For a USDC-to-WETH swap on the Base canary:

1. The user's swap moves the hooked v4 WETH/USDC pool away from the external WETH/USDC reference price.
2. `afterSwap` runs after that price movement while the v4 `PoolManager` is still unlocked.
3. The hook treats the user's output token, WETH, as the flash-loan and profit token. The user's input token, USDC, is the intermediate token.
4. `ArbitrageLogic` reads the post-swap v4 price, active liquidity, directional v4 fee, and the first registered matching V3 reference pool.
5. If the directional spread clears both pool fees and `minSpreadBps`, the hook derives a bounded principal from the same liquidity-and-spread math used by the older arbitrage engine.
6. The hook borrows WETH, swaps WETH to USDC against its own v4 pool in the direction opposite the user's swap, and swaps that USDC back to WETH on the external V3 pool.
7. Realized balances must cover the loan, lender fee, and configured minimum profit. The loan is repaid atomically and all remaining WETH profit is transferred to the beneficiary supplied with the triggering swap.
8. Any discovery, loan, swap, repayment, or profitability failure reverts only the isolated arbitrage attempt. The user's original swap continues.

This changes the source of the edge. The hook is no longer waiting for two unrelated external pools to disagree at the exact moment an unrelated v4 swap arrives. The triggering swap itself creates the price movement, and the hook counter-trades it in the same transaction.

## Adaptive Borrow Sizing

The production V4/V3 route does not traverse initialized ticks or solve an exact global optimum. That would be too expensive inside a hook. It uses a bounded local estimate:

1. Compute the directional tick spread between the post-swap v4 pool and the external reference.
2. Reject the route if the spread is in the wrong direction, below `minSpreadBps`, or does not clear the combined effective pool fees.
3. With the defaults, target roughly 17.5% of the observed spread on each leg. This comes from `(1500 + 2000) / (2 * 10000)` because the first attempt uses the current spread as its initial spread.
4. Cap that target movement at `maxImpactBps`, currently `500` ticks.
5. Use current active liquidity and the target square-root prices to calculate the v4 input and external-pool capacity without walking the full tick map.
6. Cap principal by the external leg's capacity, the configured per-token principal ceiling, and lender liquidity.
7. If execution reverts for a retryable reason, try one-half and then one-quarter of the original principal. A positive result below `minNetProfit` is final and is not retried smaller.
8. Treat realized post-swap balances as authoritative. Estimates can reject or size a candidate, but they cannot make an unprofitable loan settle.

The initial principal is therefore not a fixed amount and is not the full cap. On Base block `50018535`, a 100 USDC canary swap selected about `0.008907102809547629 WETH` from a 1 WETH ceiling.

## Current Canary

The first Base canary is deliberately narrow:

| Role | Market |
|---|---|
| Hooked pool and first arb leg | Uniswap v4 WETH/USDC, fee `500`, tick spacing `10` |
| External reference and second leg | Uniswap v3 WETH/USDC 0.05% at `0xd0b53D9277642d899DF5C87A3966A349A798F224` |
| Flash lender | WETH-bound Morpho Blue ERC-3156 adapter |
| Enabled direction | USDC to WETH trigger swaps, with profit paid in WETH |

Only WETH is configured as a flash-loan token in this canary. A WETH-to-USDC trigger therefore does not attempt arbitrage. Supporting that direction requires a reviewed USDC lender configuration, minimum-profit floor, and registration under USDC.

The current-head fork gate initializes and funds the v4 pool, performs an ordinary 100 USDC swap, and does not manufacture a separate external-pool dislocation. At block `50018535` it:

- borrowed `0.008907102809547629 WETH`;
- paid `0.000427463494774361 WETH` to the beneficiary;
- paid zero Morpho fee;
- added about `419,546` gas versus the disabled swap;
- repaid Morpho exactly;
- left no WETH or USDC in the hook; and
- burned the test LP position successfully.

Those values prove integration and settlement, not future yield. Profit depends on the hooked pool's depth, the triggering swap size, both pool fees, the external reference state, and gas.

See [`docs/BASE_WETH_CANARY_MANIFEST.md`](docs/BASE_WETH_CANARY_MANIFEST.md) and [`docs/MAINNET_CANARY_RUNBOOK.md`](docs/MAINNET_CANARY_RUNBOOK.md).

## Profit Recipient

The router must pass exactly 20 packed bytes in v4 `hookData`:

```solidity
abi.encodePacked(beneficiary)
```

Missing, malformed, or zero-address data disables the arbitrage attempt for that swap. The hook does not use `tx.origin` and does not pay the router-facing `sender` by default.

Normal swap output is delivered by the router. Arbitrage profit is a separate transfer from the hook to the beneficiary, recorded in `FlashLoanSettled`. If payer and beneficiary are the same address, their final WETH increase combines both amounts.

A public frontend or aggregator will not automatically provide this custom hook data. Until one explicitly supports the hook, the repository's controlled Universal Router script is the validated traffic path.

## Runtime Boundary

The production `afterSwap` path:

- trades only the triggering v4 token pair;
- supports ERC20 currencies, not native currency;
- chooses the first registered matching Uniswap V3 or PancakeSwap V3 pool as its reference venue;
- performs one bounded V4/V3 counter-trade per trigger; and
- uses `hookMaxIterations` as an enable switch, not as a production chunk count.

The older external/external scanner, V2 routes, mixed routes, and exact `attemptAll` sequence remain in `ArbHookHarness` as regression oracles. Their scanner and legacy flash entrypoints are intentionally absent from the production ABI so unreachable test logic does not consume deployment bytecode.

## Safety Model

The canary assumes a trusted owner registers a small set of manually verified canonical tokens, pools, and lenders. Protecting the owner from intentionally registering a malicious asset is out of scope.

Runtime boundaries remain strict:

- only the immutable v4 `PoolManager` can call `afterSwap`;
- flash callbacks must match the active lender, initiator, token, amount, and calldata hash;
- V3 callbacks are single-use and bound to the exact initiated pool swap;
- both swap legs enforce the bounded square-root price limits produced by sizing;
- the V4 nested swap must settle all `PoolManager` deltas before returning;
- intermediate-token balance must be restored exactly;
- flash repayment and beneficiary profit are checked from realized balances;
- donated hook balances are excluded from principal sizing and cannot be consumed by the route; and
- owner renunciation is disabled so the kill switch cannot be destroyed.

Pool registration is append-only. If pre-launch registration is wrong, deploy a fresh hook rather than mutating traversal and callback metadata in place.

## Configuration

Hook execution starts disabled.

- `setHookMaxIterations(value)`
  - `0` disables production attempts.
  - Any nonzero value enables one production V4/V3 attempt. Use `1` for the canary.
  - The historical name remains because the test-only legacy engine still has iterative semantics.

- `setMinSpreadBps(value)`
  - Requires at least this many directional ticks before sizing continues. The default and canary value is `10`.
  - This is a cheap prefilter, not the final economic test. Realized `minNetProfit` remains authoritative.

- `setChunkSpreadConsumptionBps(value)`
  - Controls how aggressively the local sizing estimate consumes the observed spread.
  - The default `1500`, together with the existing adaptive term, targets about 17.5% of the initial spread per leg on the production route.

- `setMaxImpactBps(value)`
  - Caps the local tick movement used to derive both price limits. The default is `500`.

- `setHookGasBounds(reserve, limit)`
  - `reserve`, default `200000`, is withheld so the triggering swap can finish after a failed attempt.
  - `limit`, default `3000000`, caps the self-called attempt. Zero removes the ceiling.

Per output token:

- `setLenderForToken(token, lender)` selects the ERC-3156 adapter.
- `setFlashPrincipalForToken(token, cap)` sets an upper bound, not a fixed borrow amount. Zero disables borrowing.
- `setMaxFlashFeeBpsForToken(token, cap)` rejects quoted or realized fees above the cap. Zero disables borrowing.
- `setMinNetProfitForToken(token, floor)` requires realized profit after lender fee in raw token units. Zero disables borrowing.

The Base WETH canary uses a 1 WETH principal ceiling, a 1 bp fee ceiling, and a provisional `0.0001 WETH` minimum profit. Recalibrate the profit floor against current incremental gas immediately before broadcast.

## Tests

Fast local gate:

```bash
forge test --summary
npm run size
```

Current result:

- 35 local tests pass;
- `ArbHook` runtime is `21,621` bytes;
- project-budget margin is `2,379` bytes; and
- EIP-170 margin is `2,955` bytes.

Current-head production path:

```bash
RUN_WETH_CANARY_FORK=true BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookWethCanaryForkTest -vv
```

Historical exact inventory oracle:

```bash
RUN_LEGACY_INVENTORY_PARITY=true BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookParityTest \
  --match-test testAttemptAllOnForkMatchesArbLightweightFlow -vv
```

Morpho-funded historical sequence:

```bash
RUN_FLASH_FORK_INTEGRATION=true BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookFlashForkAaveTest \
  --match-test testForkMorphoAttemptAllTracksLegacyRoundSequenceFull -vv
```

The inventory oracle still matches all ten legacy rounds exactly for `18.679602 USDC`. The Morpho-funded replay keeps every round profitable and currently totals `18.543625 USDC` with zero lender fees.

## Deployment

`script/DeployArbHook.s.sol` deploys `ArbMath`, `ArbitrageLogic`, WETH-bound Aave and Morpho adapters, and a CREATE2-mined after-swap-only hook. It does not register a market, configure risk limits, or enable execution.

The canary sequence is:

1. Deploy and verify all artifacts while disabled.
2. Register the canonical Uniswap V3 WETH/USDC reference with `script/RegisterArbHookCanaryPools.s.sol`.
3. Configure the WETH Morpho adapter and economic ceilings with `script/ConfigureArbHookCanary.s.sol`.
4. Initialize and fund the hooked v4 WETH/USDC pool with `script/InitializeArbHookCanaryPool.s.sol`.
5. Prove a protected swap while disabled.
6. Set `hookMaxIterations` to `1` and run a protected USDC-to-WETH canary swap.
7. Disable execution and burn the LP position if settlement or economics are not acceptable.

Always simulate Forge scripts before adding `--broadcast`. Full commands and read-back checks are in the runbook.

## Legacy Parity Context

The parity suite compares against a previous non-hook, inventory-funded arbitrage implementation, not another hook design. Its golden artifacts are:

- `ParityTest/ArbLightweight.sol`
- `ParityTest/ArbLightweight.attemptAll.js`
- `ParityTest/attemptAllOutput.txt`

The exact reference total is `18,679,602` raw USDC across ten rounds. This remains a regression oracle for route math and ordering. It is not the production callback architecture and it is not a forecast of the WETH/USDC canary's returns.
