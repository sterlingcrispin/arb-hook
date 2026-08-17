# Robinhood WETH/USDG Strategy Replay

## Decision

Robinhood Chain is economically credible enough for a small second canary, but
the current evidence does not show that it is more profitable than Base. The
best modeled Robinhood configuration earned positive LP excess in every tested
discovery-share scenario, yet Base produced more modeled dollars at `$500`,
`$2,000`, and `$10,000` per side.

The practical order is:

1. Keep Base as the first economic target.
2. Port and rehearse Robinhood independently.
3. Start Robinhood near `$250..$500` per side only after production quotes
   prove that its PoolId is considered and selected.
4. Scale either chain from measured route wins and LP returns, not from the
   full-discovery replay.

The Robinhood result is not a daily-income forecast. It is a counterfactual
ranking over three unusually active days on a young chain.

## Network Feasibility

Robinhood Chain is an Arbitrum Orbit L2 with chain ID `4663` and ETH as its gas
token. Uniswap v2, v3, and v4 are live, including PoolManager
`0x8366a39cc670b4001a1121b8f6a443a643e40951`. The canonical ERC20 pair for this
study is:

- WETH: `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- USDG: `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`

Sources: [Robinhood connection documentation](https://docs.robinhood.com/chain/connecting/),
[Robinhood token contracts](https://docs.robinhood.com/chain/contracts/),
[Uniswap launch announcement](https://blog.uniswap.org/robinhood-chain-is-live),
and [Uniswap chain deployment inventory](https://github.com/Uniswap/contracts/blob/main/deployments/4663.md).

The selected reference is the live Uniswap v3 WETH/USDG `1 bp` pool:

- pool: `0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca`
- token0: WETH
- token1: USDG
- fee: `100 ppm` (`1 bp`)
- tick spacing: `1`

This is directly compatible with the production self-pool route. The
Base-specific V2 factory constants and Pancake v3 factory lookup are irrelevant
when Robinhood registers only this Uniswap v3 reference.

### Flash Direction

Morpho Blue is deployed at
`0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010`. At Robinhood block `38206281`,
direct token-balance reads showed:

| Token | Morpho balance | Consequence |
|---|---:|---|
| USDG | `$39,098,381.59` | More than enough for the tested USDG principals |
| WETH | `0.012349237541181278 WETH` | Not enough for a meaningful WETH direction |

The [Morpho address inventory](https://docs.morpho.org/developers/contracts/addresses/)
lists the deployment, and the [Morpho API documentation](https://docs.morpho.org/developers/api/get-started/)
lists chain `4663` as supported. Availability above is a direct onchain balance
measurement, not a promise that it remains constant.

An initial deployment therefore supports one hook direction:

- A user swaps WETH to USDG, receives USDG, and moves the candidate pool.
- `afterSwap` borrows USDG, buys WETH back from the candidate v4 pool, sells
  WETH in the v3 reference, repays USDG, and pays net USDG profit to the
  resolved swap caller.
- A USDG-to-WETH swap still routes and pays the v4 LP fee, but its hook attempt
  safely skips because no WETH lender/configuration is enabled.

This is a deliberate one-direction launch, not dual-mode flash support.

### ERC20 Versus Native ETH

Several high-flow Robinhood v4 venues use native ETH rather than WETH. The
current hook correctly rejects native-currency pairs, so the candidate must be
WETH/USDG. The replay treats ETH and WETH as economically equivalent and
charges a `$0.05` incremental routing penalty, but it does not reproduce every
router wrap/unwrap path. Production quote verification must prove that the
router can compare and select the WETH candidate against native-ETH routes.

## Fixed Sample

- Robinhood blocks: `35608430..38193418`
- UTC window: `2026-08-13 18:32:33` through `2026-08-16 18:32:33`
- Raw swap events: `693,667`
- Transaction-level order proxies: `630,796`
- Venues: twelve WETH-or-native-ETH/USDG V3, V4, and PancakeSwap pools
- Replay reference: Uniswap v3 `1 bp`
- Candidate hook direction: WETH to USDG triggers only

Selected observed flow:

| Venue | Swaps/day | USDG volume/day | Median | p90 | Swaps >= $100/day |
|---|---:|---:|---:|---:|---:|
| Uniswap v3 1 bp | 163,369 | $62.70m | $37 | $968 | 52,523 |
| Uniswap v3 5 bp | 6,653 | $1.16m | $43 | $554 | 2,106 |
| V4 native dynamic A | 10,763 | $19.98m | $1,138 | $4,801 | 8,673 |
| V4 native dynamic B | 4,171 | $4.81m | $500 | $2,890 | 3,198 |
| V4 native dynamic C | 1,801 | $1.54m | $639 | $1,896 | 1,337 |
| V4 native 0.25 bp | 12,644 | $1.57m | $59 | $300 | 4,309 |
| V4 native 4.6 bp | 7,904 | $3.00m | $94 | $1,097 | 3,794 |
| V4 WETH 2 bp | 6,129 | $1.05m | $55 | $450 | 2,391 |

The volume is real, but its intent is unknown. The v3 `1 bp` pool's ten largest
callback callers generated about `81%` of its events, and hourly arrivals were
extremely overdispersed. The tape includes routers, aggregators, arbitrage,
split routes, and automated churn. It must not be labeled organic user demand.

## Replay Configuration

`scripts/replay_v4_strategy.py` keeps one candidate position's inventory and
fees across the full transaction sequence. It quotes the candidate against the
observed source output, mutates it only when it wins, then mirrors the current
iterative v4/v3 hook route. The primary sweep used:

- `$250`, `$500`, `$2,000`, and `$10,000` nominal capital per side;
- `+/-50`, `100`, `150`, `200`, and `300` ticks;
- static fees from `1` through `15 bp`;
- ten hook rounds;
- principal capped at `1%` of quote-side capital;
- `$0.05` minimum net profit;
- `$0.05` incremental routing-cost penalty; and
- USDG borrowing only.

`+/-50` ticks is approximately `+/-0.5%` around the opening price. The position
is not automatically recentered or compounded. The reference price moved from
about `$1,875.63` to `$1,883.96`, roughly `0.44%`, during the sample. The winning
range therefore ended close to its upper boundary. A real deployment needs an
explicit monitor-and-recenter policy; inactive time, repositioning gas, and the
inventory consequences of recentering are not included in these returns.

## Optimized Full-Discovery Ceiling

"LP excess" includes candidate-pool fees and values closing inventory against
holding the opening assets. "User rebate" is hook profit paid to swap callers;
it is not owner or LP income.

| Nominal capital | Range | Fee | LP excess/day | User rebate/day | Routes/day | Arbs/day |
|---|---:|---:|---:|---:|---:|---:|
| $250/side | +/-50 ticks | 10 bp | $4.59 | $0.19 | 57 | 3 |
| $500/side | +/-50 ticks | 10 bp | $10.40 | $1.03 | 95 | 12 |
| $2,000/side | +/-50 ticks | 7.5 bp | $38.30 | $4.54 | 230 | 17 |
| $10,000/side | +/-50 ticks | 7.5 bp | $106.50 | $3.01 | 375 | 7 |

These rows assume every historical order was eligible to discover the
candidate. That is an optimization ceiling. The large observed market volume
does not imply that a new pool receives it.

## Discovery Sensitivity

| Discovery share | $250/side | $500/side | $2,000/side | $10,000/side |
|---:|---:|---:|---:|---:|
| 0.1% | $0.35/day | $0.73/day | $2.03/day | $7.65/day |
| 1% | $0.49/day | $1.18/day | $6.16/day | $28.18/day |
| 10% | $1.33/day | $2.99/day | $11.77/day | $43.94/day |
| 100% | $4.59/day | $10.40/day | $38.30/day | $106.50/day |

These are deterministic flow samples, not inferred market shares. Low-share
results do not scale linearly because the candidate follows a different state
path when it sees fewer orders.

Restricting the tape to calls made by the known Robinhood SwapRouter02 and
Universal Router addresses produced a narrower upper bound:

| Nominal capital | LP excess/day | User rebate/day | Routes/day |
|---|---:|---:|---:|
| $250/side | $2.17 | $0.16 | 28 |
| $500/side | $4.31 | $0.43 | 45 |
| $2,000/side | $10.21 | $0.18 | 86 |
| $10,000/side | $44.52 | $0.00 | 150 |

Known-router flow is not guaranteed flow. It only narrows which historical
orders entered the counterfactual quote comparison.

## LP Income Versus Hook Value

Most modeled operator return comes from providing a competitively priced,
narrow v4 position. The hook rebate goes to the swap caller. At full discovery:

| Nominal capital | Hook on LP excess/day | Hook off | LP delta | User rebate/day |
|---|---:|---:|---:|---:|
| $250/side | $4.59 | $4.68 | -$0.09 | $0.19 |
| $500/side | $10.40 | $9.85 | +$0.55 | $1.03 |
| $2,000/side | $38.30 | $39.39 | -$1.09 | $4.54 |
| $10,000/side | $106.50 | $105.76 | +$0.73 | $3.01 |

The hook is not generating the entire LP return. It closes some post-swap edge,
changes inventory, and adds countertrade fee volume while transferring realized
net arbitrage profit to the beneficiary. Depending on path and capital, that can
slightly increase or decrease the LP's own marked result.

## Time Sensitivity

Each day was also replayed from a fresh opening position:

| Profile | Day 1 | Day 2 | Day 3 | Three-day continuous average |
|---|---:|---:|---:|---:|
| $500/side, 10 bp | $17.33 | $11.01 | $3.12 | $10.40/day |
| $2,000/side, 7.5 bp | $59.83 | $46.75 | $14.29 | $38.30/day |
| $10,000/side, 7.5 bp | $177.18 | $110.76 | $35.91 | $106.50/day |

Every tested day remained positive, but activity and return declined sharply
through the window. Three days are insufficient for annualization or stable
income estimates.

## Existing-Control Sensitivity

The replay also swept the existing principal cap (`0.5%..5%`) and iteration
limit (`2, 5, 10, 15`). It did not identify a reason to add new onchain sizing
logic:

- At `$500` per side, the existing `1%` cap and ten rounds remained the best LP
  result in the tested grid.
- At `$2,000` per side, `5%` and five rounds increased LP excess from `$38.30`
  to `$39.69` per day and rebate from `$4.54` to `$5.98` per day.
- At `$10,000` per side, all leading control combinations were within roughly
  one dollar per day of each other.

Higher caps primarily moved more value into the user rebate. Exact production
settings should be calibrated on a current-head fork with measured callback gas;
the three-day differences are too small to justify aggressive defaults.

## Base Comparison

The two chains were optimized separately, so this is not a controlled
same-window experiment. It is still the best current deployment evidence:

| Nominal capital | Base full discovery | Robinhood full discovery | Base known-router subset | Robinhood subset |
|---|---:|---:|---:|---:|
| $500/side | $12.31/day | $10.40/day | $7.41/day | $4.31/day |
| $2,000/side | $119.24/day | $38.30/day | $99.04/day | $10.21/day |
| $10,000/side | $309.45/day | $106.50/day | $251.54/day | $44.52/day |

Robinhood has much more observed WETH/USDG flow and larger trades, but its deep
`1 bp` reference and low-fee native v4 pools quote aggressively. A new candidate
wins a smaller useful fraction of that flow. Base currently has the stronger
modeled dollars per unit of capital; Robinhood has enough positive evidence to
justify a separate small experiment.

## Required Port Before Deployment

No Robinhood production deployment was made by this analysis. The contracts are
mostly chain-parameterized, but the current scripts and release gates are Base
specific. A Robinhood launch requires:

1. Add a chain-attested deployment path using Robinhood PoolManager, WETH,
   USDG, and Morpho addresses. Do not deploy the Base Aave adapter.
2. Deploy `MorphoERC3156Adapter` for USDG and enable only the USDG output-token
   direction.
3. Add a fixed-block Robinhood fork test covering the real v4 callback, the
   Uniswap v3 `1 bp` reference, Morpho USDG repayment, beneficiary resolution,
   residue checks, and repeated rounds.
4. Verify Robinhood's Universal Router `msgSender()` behavior rather than
   assuming the Base proof transfers.
5. Calibrate `hookGasLimit`, the absolute USDG principal cap, and raw-USDG
   `minNetProfit` at current head.
6. Deploy the exact reviewed hook disabled.
7. Confirm live production quotes compare and select the WETH/USDG PoolId,
   including wrap/unwrap competition with native-ETH pools.
8. Start near `$250..$500` per side, `+/-50` ticks, and `10 bp`; monitor route
   wins, inventory, fees, hook settlements, recipient payouts, and gas before
   increasing capital.

Uniswap Labs states that classic routing automatically considers hooked v4
pools and reserves manual allowlisting for hooks using custom accounting. This
hook profile does not return accounting deltas, but production quote selection
on Robinhood must still be verified directly.

## Reproduction

Refresh the pinned market-flow cache:

```bash
ROBINHOOD_RPC_URL="$ROBINHOOD_RPC_URL" python3 scripts/model_swap_flow.py \
  --network robinhood \
  --days 3 \
  --end-block 38193418 \
  --output-dir artifacts/flow-model-robinhood \
  --refresh
```

Run the refined strategy surface:

```bash
python3 scripts/replay_v4_strategy.py \
  --cache artifacts/flow-model-robinhood/robinhood-swap-flow-35608430-38193418-events.jsonl.gz \
  --references uniswap_v3_1bp \
  --capitals 250,500,2000,10000 \
  --ranges 50,100,150,200,300 \
  --fees 100,200,300,500,750,1000,1500 \
  --hook-modes on \
  --hook-direction weth_to_usdc \
  --principal-caps 100 \
  --max-iterations 10 \
  --min-profits 0.05 \
  --gas-penalties 0.05 \
  --discovery-shares 100
```

Generated market and replay artifacts remain under ignored `artifacts/` paths.
