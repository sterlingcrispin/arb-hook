# Base WETH/USDC Strategy Replay

## Purpose

This report ranks candidate WETH/USDC v4 liquidity configurations against a
fixed seven-day sample of Base swaps. It answers a narrower question than
"what will this earn?": if a candidate hooked pool had been considered for a
known fraction of this historical flow, which fee, range, capital level, and
reference venues produced the strongest LP outcome?

It does not prove that a new pool will receive that flow. Uniswap's production
routing API filters pools with non-allowlisted hooks. Hook registration in the
[Uniswap hooklist](https://github.com/Uniswap/hooklist) does not automatically
grant routing allowlisting; the routing repository maintains a separate
[hook-address allowlist](https://github.com/Uniswap/routing-api/blob/main/lib/util/hooksAddressesAllowlist.ts).

## Fixed Sample

- Base blocks: `49751768..50054168`
- UTC window: `2026-08-09 16:28:03` through `2026-08-16 16:28:03`
- Raw swap events: `654,320`
- Transaction-level orders after grouping split legs: `622,266`
- Markets: seven Base WETH/USDC V3, V4, PancakeSwap, and Aerodrome venues
- Candidate pair: WETH/USDC only

The event cache retains exact block, transaction, and log order plus each
V3-compatible venue's post-swap tick, square-root price, and active liquidity.

## Replay Mechanics

`scripts/replay_v4_strategy.py` creates one concentrated-liquidity v4 position
at the sample's opening price and keeps its inventory and earned fees across the
entire replay. For each historical transaction it:

1. Uses the largest observed WETH/USDC leg as the order proxy.
2. Quotes the persistent candidate pool without mutating it.
3. Routes the order to the candidate only when its output exceeds the observed
   source output after a configurable incremental-gas penalty.
4. Mutates the candidate position when it wins.
5. Runs the production-style iterative v4/V3 hook route against the best
   enabled reference snapshot.
6. Tracks LP inventory, fees, routed volume, flash principal, iterations,
   residual ticks, and user rebate.
7. Values the final LP position and fees at the closing external price and
   compares it with simply holding the deposited WETH and USDC.

The candidate state is persistent. External venue state follows the historical
tape and is not permanently changed by counterfactual hook trades. A
deterministic transaction-hash sample supplies the `--discovery-shares`
scenarios, so repeated runs select the same flow.

Every invocation first checks an analytical scenario against the fixed-fork EVM
oracle used by `scripts/sweep_v4_pool.py`. The modeled user output matches the
fork result, the loop completes the same two rounds, it leaves the same nine
ticks, and modeled hook profit is within `0.1%`.

## Current Ranking

All figures below are seven-day replay averages. "LP excess" includes v4 fees
and values the final inventory against holding the same opening assets. "User
rebate" is hook profit paid to swap beneficiaries, not owner revenue.

| Profile | Nominal capital | Range | v4 fee | LP excess/day | User rebate/day | Routes/day | Arbs/day |
|---|---:|---:|---:|---:|---:|---:|---:|
| Small canary | $500/side | +/-300 ticks | 10 bp | $12.31 | $4.45 | 505 | 36 |
| Return-efficient | $2,000/side | +/-300 ticks | 15 bp | $119.24 | $18.52 | 874 | 104 |
| Higher absolute return | $10,000/side | +/-300 ticks | 15 bp | $309.45 | $25.54 | 1,206 | 76 |

These rows assume the candidate is discoverable for all sampled flow. That is
an optimization ceiling, not an earnings forecast. A `+/-300`-tick range is
approximately `+/-3%` around the opening price.

The tested capital surface shows diminishing percentage returns after roughly
`$2,000` per side, while absolute modeled dollars continue increasing through
the largest tested positions. The preferred fee also rises with depth: the
small-capital surface favored `10 bp`, the `$2,000..$10,000` region favored
roughly `15 bp`, and the deepest tested positions moved toward `18 bp`.

## Discovery Sensitivity

The following table uses `15 bp`, `+/-300` ticks, ten hook rounds, a principal
cap equal to `1%` of each deposited side, a `$0.05`-equivalent minimum profit,
and a `$0.005` routing-gas penalty. Discovery is an explicit assumption, not an
estimate of a new pool's market share.

| Discovery share | $250/side LP excess/day | $2,000/side | $10,000/side |
|---:|---:|---:|---:|
| 0.1% | -$0.06 | $0.41 | -$0.01 |
| 1% | $0.20 | $2.96 | $14.94 |
| 10% | $0.62 | $13.96 | $48.59 |
| 100% | $3.72 | $119.24 | $309.45 |

Low discovery does not scale linearly. A pool that receives little flow can
remain stale relative to the market and then receive adverse flow. That makes
traffic acquisition and arbitrage discovery at least as important as capital.

Restricting the tape to historically observed canonical-router calls gives a
second, narrower ceiling, conditional on the hook being allowlisted:

| Profile | Canonical flow assumption | LP excess/day | User rebate/day |
|---|---:|---:|---:|
| $250/side, 10 bp | 100% | $2.46 | $0.49 |
| $500/side, 10 bp | 100% | $7.41 | $2.76 |
| $2,000/side, 15 bp | 100% | $99.04 | $15.63 |
| $10,000/side, 15 bp | 100% | $251.54 | $24.74 |

This does not mean the canonical router will send those swaps to a new pool.
It means those historical calls would have been considered by the replay after
the flow filter. Actual quote inclusion and route wins must be measured after
allowlisting.

## Reference Venues

At `$10,000` per side, `15 bp`, and `+/-300` ticks, single-reference results
were close:

| Registered references | LP excess/day | User rebate/day |
|---|---:|---:|
| PancakeSwap v3 1 bp | $316.34 | $27.09 |
| Uniswap v3 1 bp | $313.78 | $24.74 |
| Uniswap v3 5 bp | $306.42 | $15.67 |
| PancakeSwap 1 bp + Uniswap 1 bp | $315.25 | $26.25 |

PancakeSwap v3 `1 bp` was marginally best as a single venue in this sample.
Registering both `1 bp` references is the more robust initial configuration:
the production selector chooses the cheaper live venue, and the modeled result
was within one dollar per day of the best single-reference row. Keep the list
small because production selection scans it linearly.

## Execution Controls

The replay supports the existing adaptive loop rather than introducing a new
onchain sizing system. The current starting point is:

- `hookMaxIterations = 10`;
- flash principal cap near `1%` of the deposited amount for each output-token
  direction;
- `minNetProfit` near `$0.05` equivalent, converted separately to raw WETH and
  USDC at deployment;
- existing `minSpreadBps = 10` and adaptive movement parameters; and
- a small reference list containing the two `1 bp` WETH/USDC pools.

Ten rounds materially outperformed one or two and was close to the tested
optimum. Increasing the principal cap beyond `5%` did not improve the measured
surface. A `$0.05` floor roughly halved low-value hook settlements in the
control sweep while preserving most modeled LP value and rebate.

These are offchain starting values, not production constants. Onchain caps are
absolute token amounts, and `minNetProfit` is denominated in the borrowed token.
Both directions require current-head fork calibration before enabling the hook.

## Robustness Checks

- The `$10,000`/side, `15 bp`, `+/-300` profile produced `$159.09/day` in the
  first 3.5 days and `$468.33/day` in the second 3.5 days when initialized
  independently. The large regime difference makes annualization unjustified.
- At that profile, increasing the routing-gas penalty from `$0.005` to `$0.25`
  reduced LP excess from about `$314/day` to `$191/day`; a `$1` penalty reduced
  it to about `$10/day`.
- Disabling the hook reduced the same full-flow LP result from about `$314/day`
  to `$284/day`. Most owner economics come from v4 LP fees; the hook primarily
  redirects the post-swap edge to the beneficiary and adds countertrade fee
  volume to the LP position.

## Reproduction

Refresh the fixed event cache:

```bash
BASE_RPC_URL="$BASE_RPC_URL" python3 scripts/model_swap_flow.py \
  --days 7 --end-block 50054168 --refresh
```

Run a focused candidate and discovery sweep:

```bash
python3 scripts/replay_v4_strategy.py \
  --capitals 250,500,2000,10000 \
  --ranges 300 --fees 1500 \
  --hook-modes on \
  --principal-caps 100 \
  --max-iterations 10 \
  --min-profits 0.05 \
  --gas-penalties 0.005 \
  --discovery-shares 0.1,1,5,10,25,50,100
```

Add `--flow-filter canonical-router` for the canonical-call subset. Generated
JSON and CSV artifacts live under ignored `artifacts/strategy-replay/` paths.

## Decision

The best-supported first market remains WETH/USDC because it has deep flash
liquidity, multiple low-fee V3-compatible references, and enough observed flow
to build a replay. This report does not establish that WETH/USDC is globally
optimal versus every Base token pair.

Do not scale capital from the full-discovery table. The next meaningful proof is
operational:

1. Deploy the reviewed hook disabled.
2. Register both low-fee WETH/USDC references and configure both token
   directions.
3. Complete Uniswap routing allowlisting for the exact deployed hook.
4. Verify production quotes actually consider and select the PoolId.
5. Start near `$250..$500` per side around `+/-300` ticks and `10 bp`.
6. Compare actual quote requests, route wins, LP fees, inventory drift, hook
   settlements, rebates, and gas with the replay before adding capital.

Without step 3 or another measured traffic source, the expected organic routing
share is unknown and the earnings tables should not be used as forecasts.
