# Base WETH Canary Manifest

This is the exact first-stage Base canary market. Registration is append-only and order-sensitive. Do not add another reference pool before the initial deployment has been observed and stopped cleanly.

## Route Architecture

The two venues have different roles in one WETH/USDC round trip:

1. A user swaps USDC to WETH in the hooked Uniswap v4 pool.
2. That swap raises the WETH price in the v4 pool relative to the external reference.
3. `afterSwap` borrows WETH and counter-trades the same v4 pool from WETH to USDC.
4. The hook trades the received USDC back to WETH in canonical Uniswap v3.
5. The hook repays WETH and sends net profit to the original caller reported by the canonical Universal Router. No custom hook data is required.

The v4 pool is therefore both the trigger and the first arbitrage leg. The external V3 pool supplies the comparison price and second leg. No unrelated market and no pre-existing external/external spread is required.

## Hooked V4 Pool

| Field | Value |
|---|---|
| Network | Base, chain ID `8453` |
| `currency0` | WETH `0x4200000000000000000000000000000000000006` |
| `currency1` | USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| LP fee | `500` hundredths of a basis point, or 0.05% |
| Tick spacing | `10` |
| Hook permissions | `afterSwap` only |
| Opening price source | Canonical Uniswap V3 WETH/USDC 0.05% |
| First position | Full range, bounded by explicit wallet-supplied WETH and USDC caps |

`script/InitializeArbHookCanaryPool.s.sol` reads the live reference price, initializes this PoolKey, and mints the first position through Base's canonical PositionManager. The pool ID depends on the final mined hook address.

## External Reference

Register exactly one pool under WETH:

| Order | Venue | Pool | Fee | `PoolType` | token0 | token1 |
|---|---|---|---:|---|---|---|
| 1 | Uniswap V3 | `0xd0b53D9277642d899DF5C87A3966A349A798F224` | `500` | `V3` | WETH | USDC |

The production route selects the first registered matching Uniswap V3 or PancakeSwap V3 pool for the triggering pair. Registration order is therefore the operator's reference-venue choice, not a runtime cheapest-pool auction.

`script/RegisterArbHookCanaryPools.s.sol` rejects the transaction unless this address has code and reports:

- factory `0x33128a8fC17869897dcE68Ed026d694621f6FDfD`;
- token0 WETH;
- token1 USDC; and
- fee `500`.

## Enabled Direction

The initial canary registers and configures WETH only. It supports:

```text
user: USDC -> WETH in v4
arb:  WETH -> USDC in v4 -> WETH in v3
profit token: WETH
```

A WETH-to-USDC user swap has USDC as its output and potential flash principal. It will not attempt arbitrage until USDC has its own reviewed lender, cap, fee ceiling, profit floor, and matching reference registration under USDC.

## Lender And Limits

Use the WETH-bound Morpho adapter:

| Field | Value |
|---|---|
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
| Supported asset | WETH |
| Flash fee | 0 in the tested adapter path |
| Initial principal ceiling | `1 WETH` |
| Fee ceiling | `1` bp, the smallest nonzero enabled value |
| Provisional minimum net profit | `0.0001 WETH` |
| Minimum triggering input | `49 USDC` (`49,000,000` raw), USDC-to-WETH only |

The 1 WETH value is only a ceiling. Live route math chooses the amount from post-swap spread and active liquidity. The current-head 100 USDC fork rehearsal selected about `0.0089 WETH`, more than 100 times below the cap.

The 49 USDC value is an early gas-saving gate for this exact PoolId and direction. It uses the actual USDC input reported by v4's `BalanceDelta`, not caller-supplied calldata. Smaller swaps skip before route discovery and borrowing; eligible swaps must still clear spread, fee, and realized-profit checks.

Recheck lender liquidity, fee behavior, gas, the input floor, and the profit floor immediately before broadcast.

## Trigger Size Simulation

`testSweepSwapSizeAgainstLiveReference` replays each amount from the same Base
fork snapshot with the canary's full-range position capped at 2 WETH and 5,000
USDC. It compares identical disabled and enabled swaps, so the reported cost is
the hook's incremental execution gas rather than the gas for a swap the user was
already making.

At block `50018808`, that position consumed `1.999999999999990607 WETH` and
`3,762.610635 USDC`; the USDC cap was not the limiting side.

At block `50018808`, with a `0.006 gwei` execution gas price and a one-wei
test-only profit floor:

| Trigger | Net WETH profit | Incremental gas cost | Result |
|---:|---:|---:|---|
| 2.00 USDC | none | n/a | no profitable settlement |
| 2.25 USDC | 0.000000013519074440 | 0.000002513694 | positive before gas only |
| 8.50 USDC | 0.000002504145206845 | 0.000002510400 | just below execution cost |
| 9.00 USDC | 0.000002908310467143 | 0.000002509566 | positive after incremental execution cost |
| 48.00 USDC | 0.000098104596253525 | 0.000002505456 | below the canary profit floor |
| 49.00 USDC | 0.000102966132333892 | 0.000002505282 | clears the canary profit floor |
| 100.00 USDC | 0.000427855387719440 | 0.000002504700 | clears both thresholds |

A second replay with the actual `0.0001 WETH` floor established the input gate:
48 USDC produced no settlement while 49 USDC settled. With the resulting
49 USDC gate enabled, every smaller sample skipped the arbitrage path for only
about 2,500 to 3,100 incremental gas; 49 USDC remained inclusive and used about
419,500 incremental gas for the full attempt.

For this exact state and LP depth, the observed thresholds are therefore:

- pool-level positive result: between 2.00 and 2.25 USDC;
- positive after incremental L2 execution cost: between 8.50 and 9.00 USDC; and
- settlement with `minNetProfit = 0.0001 WETH`: between 48 and 49 USDC.

The disabled and enabled transactions have identical calldata, so their L1 data
fee is the same and cancels in the differential comparison. These thresholds are
not constants: v4 liquidity, range concentration, both pool states, pool fees,
gas price, and the configured profit floor can move them.

Reproduce the sweep with:

```bash
RUN_WETH_CANARY_FORK=true \
RUN_WETH_CANARY_SWEEP=true \
WETH_CANARY_FORK_BLOCK=50018808 \
WETH_CANARY_SIM_GAS_PRICE_WEI=6000000 \
BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookWethCanaryForkTest \
  --match-test testSweepSwapSizeAgainstLiveReference -vv
```

Set `WETH_CANARY_SWEEP_MIN_PROFIT_WEI=100000000000000` to replay the actual
canary profit floor instead of observing smaller positive results. Also set
`WETH_CANARY_SWEEP_MIN_TRIGGER_AMOUNT_RAW=49000000` to replay the production
input gate and its 48/49 USDC boundary assertion.

## MEV Redistribution Comparison

`testHookRedistributesExternalBackrunnerValue` replays a 100 USDC user swap from
one snapshot with separate LP, swapper, beneficiary, and searcher accounts:

1. Leave the post-swap v4 price movement open.
2. Disable the hook and let an external searcher counter-trade v4, then exit through v3.
3. Enable the hook and pay the same capture to the beneficiary.

The external searcher uses owned WETH and exactly the hook's realized v4 input.
Morpho charges zero in the hook case, so this isolates execution and recipient
routing without introducing a lender-fee difference.

At Base block `50018808`, valued at the same 1881.305317 USDC/WETH reference:

| Case | LP value | Beneficiary gain | Searcher gain | Combined tracked value |
|---|---:|---:|---:|---:|
| No backrun | 424,282.414448 USDC | 0 | 0 | 426,261.083397 USDC |
| External backrun | 424,281.600721 USDC | 0 | 0.804926 USDC | 426,261.074596 USDC |
| Hook rebate | 424,281.600721 USDC | 0.804926 USDC | 0 | 426,261.074596 USDC |

The swapper receives the same ordinary WETH output in every case. The hook and
external backrunner leave the LP and combined tracked parties in the same state
within 10 raw USDC units. The `0.008801 USDC` difference from no backrun is value
paid to the external v3 venue. Gas is separate: no-backrun trigger `187,559`,
hook trigger `609,700`, and external backrun `164,430` gas.

This proves that the hook redirects a matched backrunner's capture to the named
beneficiary. It does not prove a new thin pool would actually be backrun without
the hook. If no backrun is the realistic baseline, the LP funds a rebate that it
would otherwise have retained.

Reproduce the deterministic comparison with:

```bash
RUN_WETH_CANARY_FORK=true \
WETH_CANARY_FORK_BLOCK=50018808 \
BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookWethCanaryForkTest \
  --match-test testHookRedistributesExternalBackrunnerValue -vv
```

## Canonical Base Contracts

| Contract | Address |
|---|---|
| Uniswap V4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Uniswap V4 PositionManager | `0x7C5f5A4bBd8fD63184577525326123B519429bDc` |
| Uniswap Universal Router | `0x6fF5693b99212Da76ad316178A184AB56D299b43` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Uniswap V3 factory | `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |

Recheck these against current official deployment sources and confirm runtime code on the deployment RPC before broadcast.

## Current Evidence

`foundry/test/ArbHookWethCanaryFork.t.sol` runs against an unpinned Base fork and proves:

- CREATE2 mining of an after-swap-only hook;
- canonical PoolManager, PositionManager, Permit2, and Universal Router integration;
- canonical WETH/USDC V3 reference registration;
- WETH-bound Morpho borrowing and exact zero-fee repayment;
- full-range v4 LP mint and withdrawal;
- a normal 100 USDC-to-WETH trigger with an optional packed recipient override;
- a normal 100 USDC-to-WETH trigger with empty data that pays the Universal Router's original caller;
- a pool-and-direction-specific 49 USDC actual-input gate before discovery;
- adaptive direction and principal selection without a supplied hint;
- bounded execution price limits on both swap legs;
- a counter-swap against the same v4 pool that triggered the hook;
- a Uniswap V3 WETH exit leg;
- positive WETH beneficiary payout;
- exact redistribution parity against a matched external V4/V3 backrunner; and
- zero residual WETH and USDC after payout.

At Base block `50018535`, the proof borrowed `0.008907102809547629 WETH`, paid `0.000427463494774361 WETH`, paid zero lender fee, and measured about `419546` incremental gas. The test did not manufacture an external-pool dislocation. Its own v4 swap created the captured edge.

These values are a settlement proof, not expected production yield.
