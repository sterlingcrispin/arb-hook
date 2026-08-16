# Arb Hook

`ArbHook` is a Uniswap v4 `afterSwap` hook that captures the arbitrage edge created by a swap and sends the realized WETH profit to the swap initiator exposed by the router.

The production route is not a generic background scanner. It uses the triggering v4 pool as the first arbitrage leg and one registered concentrated-liquidity pool for the same token pair as the reference and exit venue. Flash-loaned principal means the hook does not need to hold trading inventory.

## Production Mechanism

For a USDC-to-WETH swap on the Base canary:

1. The user's swap moves the hooked v4 WETH/USDC pool away from the external WETH/USDC reference price.
2. `afterSwap` runs after that price movement while the v4 `PoolManager` is still unlocked.
3. The hook compares the swap's actual input with the configured minimum for this PoolId and direction. Smaller swaps return immediately without route discovery or borrowing.
4. The hook treats the user's output token, WETH, as the flash-loan and profit token. The user's input token, USDC, is the intermediate token.
5. `ArbitrageLogic` reads the post-swap v4 price, active liquidity, directional v4 fee, and the first registered matching V3 reference pool.
6. If the directional spread clears both pool fees and `minSpreadBps`, the hook derives a bounded principal from the same liquidity-and-spread math used by the older arbitrage engine.
7. The hook borrows WETH, swaps WETH to USDC against its own v4 pool in the direction opposite the user's swap, and swaps that USDC back to WETH on the external V3 pool.
8. Realized balances must cover the loan, lender fee, and configured minimum profit. The loan is repaid atomically, then the original router caller receives all remaining WETH directly. An exact 20-byte recipient remains available as an optional override.
9. Any discovery, loan, swap, repayment, or profitability failure reverts only the isolated arbitrage attempt. The user's original swap continues.

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

The initial principal is therefore not a fixed amount and is not the full cap. On Base block `50029886`, a 10 USDC swap against the proposed $100-per-side position selected about `0.000812887664977685 WETH` from a `0.005 WETH` ceiling.

## Current Canary

The first Base canary is deliberately narrow:

| Role | Market |
|---|---|
| Hooked pool and first arb leg | Uniswap v4 WETH/USDC, fee `500`, tick spacing `10` |
| External reference and second leg | Uniswap v3 WETH/USDC 0.05% at `0xd0b53D9277642d899DF5C87A3966A349A798F224` |
| Flash lender | WETH-bound Morpho Blue ERC-3156 adapter |
| Enabled direction | USDC to WETH trigger swaps, with profit paid in WETH |
| Initial LP target | approximately `$100 WETH + $100 USDC` in one full-range position |
| Minimum eligible trigger | `10 USDC` of actual input for the USDC-to-WETH direction |

Only WETH is configured as a flash-loan token in this canary. A WETH-to-USDC trigger therefore does not attempt arbitrage. Supporting that direction requires a reviewed USDC lender configuration, minimum-profit floor, and registration under USDC.

The current-head fork gate initializes and funds the v4 pool and does not manufacture a separate external-pool dislocation. At block `50029886`, the shallow-canary replay deposited `0.053140792207665807 WETH` and `99.973139 USDC`. A 10 USDC swap then:

- borrowed `0.000812887664977685 WETH`;
- paid `0.000153429487453379 WETH` to the beneficiary;
- paid zero Morpho fee;
- added about `420,105` gas versus the disabled swap;
- repaid Morpho exactly;
- left no WETH or USDC in the hook; and
- burned the test LP position successfully.

At the replay's `0.006 gwei` L2 gas price, the route profit exceeded incremental execution gas by `0.000150908857453379 WETH`. A 100 USDC swap is inappropriate for this shallow position and correctly produced no arbitrage settlement; it is not the first controlled swap.

Those values prove integration and settlement, not future yield. Profit depends on the hooked pool's depth, the triggering swap size, both pool fees, the external reference state, and gas.

See [`docs/BASE_WETH_CANARY_MANIFEST.md`](docs/BASE_WETH_CANARY_MANIFEST.md) and [`docs/MAINNET_CANARY_RUNBOOK.md`](docs/MAINNET_CANARY_RUNBOOK.md).

## Economic Interpretation

The settlement event reports route profit, not value created from nothing. The hook counter-trades the v4 LP position. A pinned three-way replay separates the relevant baselines:

- With no backrun, the LP keeps the swap-created price impact.
- A matched external backrunner reduces LP value by `0.813727 USDC`, earns `0.804926 USDC`, and sends `0.008801 USDC` to the external V3 venue.
- The hook produces the same LP and combined outcomes within 10 raw USDC units, but pays the `0.804926 USDC` to the beneficiary instead of the searcher.

The swapper's ordinary output is identical in all cases; hook profit is an additional transfer. This establishes the MEV-redistribution mechanism, conditional on an external backrun being the correct counterfactual. On a thin pool nobody would otherwise backrun, the hook gives away value the LP would have retained. If the LP, swapper, and beneficiary are one wallet, the transfer cancels internally and external fees plus gas make that wallet net negative.

## Profit Recipient

Normal swaps require no custom hook data. The `afterSwap` callback identifies the router through its `sender` argument, then calls the standard v4 periphery `IMsgSender.msgSender()` interface. Base's canonical Universal Router returns the address that initiated its active execution lock. For a wallet calling the router directly, that is the wallet; for a smart account, it is the smart account.

The hook caps this external lookup at 10,000 gas. If empty hook data arrives from a custom router that does not implement `IMsgSender`, returns zero, or fails the lookup, the hook skips arbitrage rather than guessing with `tx.origin` or paying the wrong address. An intermediary that calls the Universal Router is the router initiator; it must forward its full WETH output or pass the end user through the optional packed recipient override.

Exactly 20 packed bytes remain an optional explicit-recipient override:

```solidity
abi.encodePacked(beneficiary)
```

Malformed nonempty data and a packed zero address skip the attempt.

Normal swap output is delivered by the router and is not changed by `afterSwap`. Arbitrage profit is an additional WETH transfer to the resolved recipient. The repository's controlled Universal Router script deliberately sends empty hook data, and the Base fork gate proves that the canonical router resolves its caller without a custom frontend.

## Runtime Boundary

The production `afterSwap` path:

- trades only the triggering v4 token pair;
- supports ERC20 currencies, not native currency;
- skips swaps below the configured actual-input floor for that PoolId and direction;
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
- flash repayment and profit payout are checked from realized balances;
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

- `setMinTriggerAmount(poolId, zeroForOne, amount)`
  - Sets the minimum actual swap input before route discovery. `amount` uses currency0 raw units when `zeroForOne` is true and currency1 raw units otherwise; zero disables the gate.
  - The $100-per-side canary uses `10,000,000` raw USDC for its WETH/USDC PoolId with `zeroForOne = false`. The value is pool-specific because liquidity and pool state determine how large a swap must be to create the required edge.
  - This avoids spending full arbitrage gas on known-undersized swaps. The spread and realized-profit checks still decide whether an eligible swap can settle.

Per output token:

- `setLenderForToken(token, lender)` selects the ERC-3156 adapter.
- `setFlashPrincipalForToken(token, cap)` sets an upper bound, not a fixed borrow amount. Zero disables borrowing.
- `setMaxFlashFeeBpsForToken(token, cap)` rejects quoted or realized fees above the cap. Zero disables borrowing.
- `setMinNetProfitForToken(token, floor)` requires realized profit after lender fee in raw token units. Zero disables borrowing.

The $100-per-side Base WETH canary uses a 10 USDC trigger floor, a `0.005 WETH` principal ceiling, a 1 bp fee ceiling, and a provisional `0.0001 WETH` minimum profit. Recalibrate the input and profit floors against the intended liquidity and current fork state immediately before broadcast.

## Tests

Fast local gate:

```bash
forge test --summary
npm run size
```

Current result:

- 36 local tests pass;
- `ArbHook` runtime is `22,202` bytes;
- project-budget margin is `1,798` bytes; and
- EIP-170 margin is `2,374` bytes.

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
3. Configure the WETH Morpho adapter, economic ceilings, and 10 USDC trigger floor with `script/ConfigureArbHookCanary.s.sol`.
4. Initialize and fund the hooked v4 WETH/USDC pool with `script/InitializeArbHookCanaryPool.s.sol`.
5. Simulate a protected swap while disabled, but do not broadcast it and move the freshly initialized pool before the calibrated canary.
6. Set `hookMaxIterations` to `1` and run a protected USDC-to-WETH canary swap.
7. Disable execution and burn the LP position if settlement or economics are not acceptable.

If any swap reaches the new pool between initialization and the controlled canary, rerun the current-state sweep before enabling. The trigger math depends on the pool state left by every prior swap.

Disable execution before adding capital to an existing position. Use `script/AddArbHookCanaryLiquidity.s.sol`, rerun the current-state sweep at the proposed total depth, and recalibrate the trigger, principal, and profit limits before enabling again.

Always simulate Forge scripts before adding `--broadcast`. Full commands and read-back checks are in the runbook.

The live Base research canary is `0xC537EDE696EAC0014A30a51706fb5E95C2734040`.
Addresses, receipts, configuration, the successful flash settlement, and the
current gas-estimation limitation are recorded in
`docs/BASE_WETH_CANARY_DEPLOYMENT.md`.

## Legacy Parity Context

The parity suite compares against a previous non-hook, inventory-funded arbitrage implementation, not another hook design. Its golden artifacts are:

- `ParityTest/ArbLightweight.sol`
- `ParityTest/ArbLightweight.attemptAll.js`
- `ParityTest/attemptAllOutput.txt`

The exact reference total is `18,679,602` raw USDC across ten rounds. This remains a regression oracle for route math and ordering. It is not the production callback architecture and it is not a forecast of the WETH/USDC canary's returns.
