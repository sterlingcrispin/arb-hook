# Open Issues

## Context
This tracker records the audit findings list and current disposition.

## Canary Threat Model

The initial deployment is owner-operated with a small set of manually verified, canonical Base tokens, pools, and lenders. Malicious owner-supplied assets and permissionless registry inputs are not part of the current threat model. External callbacks, atomic repayment, economic correctness, and recipient routing remain in scope.

## Strategy Findings

69. Temporary one-round self-pool route bypassed the original iterative engine
- Status: `ADDRESSED BY ITERATIVE SELF-POOL EXECUTION`
- Priority: `CRITICAL`
- Summary: Production `afterSwap` was changed to route directly through
  `attemptHookPoolInternal`, which hardcoded `maxIterations: 1` and executed one
  V4/V3 step. This bypassed the original ordered base/counter scanner and the
  executor loop controlled by `hookMaxIterations`. The live Base experiment
  confirmed the consequence: the hook captured one bounded step and an external
  backrunner immediately captured additional LP-funded edge.
- Resolution: commit `d78c3f3` restores the causal self-pool route without
  restoring the one-shot shortcut. `afterSwap` passes `hookMaxIterations` into
  one flash-funded V4/V3 attempt. `V4ArbExecutor` then rereads both venues,
  derives a new bounded chunk and price limits, executes both legs, and measures
  marginal profit on every round. The original external scanner and its
  V2/V3/mixed iterative engine remain intact as regression and research code.
- Regression evidence:
  `ArbHookV4LoopForkTest` compares identical state and a 100 USDC trigger at Base
  block `50018808`. One round earned `0.000427855387719440 WETH` and left 434
  ticks; ten rounds earned `0.001247055334869567 WETH` and left 134 ticks. It
  also asserts exact Morpho repayment and zero hook residue. Exact inventory
  parity and the fixed-block legacy flash sequence remain independent gates.
- Constraint: do not replace the live-repriced loop with a fixed one-shot route,
  nor remove the preserved scanner, fallback selection, route-specific sizing,
  or legacy iterative executor without explicit design approval and a
  callback-level before/after comparison.

68. Universal Router caller resolution is one hop, not recursive
- Status: `DOCUMENTED`
- Priority: `MEDIUM`
- Summary: Empty hook data resolves the recipient through
  `IMsgSender.msgSender()` on the address that called `PoolManager.swap`. That
  returns the Universal Router's immediate caller. A direct wallet call pays the
  wallet, and a user-owned smart account pays that account. If another routing
  contract calls Universal Router, the hook pays that intermediary.
- Consequence: the hook cannot infer an ultimate beneficial owner through an
  arbitrary contract call chain. Whether an intermediary forwards or retains
  the rebate depends on its settlement logic; a router that sweeps its full WETH
  balance to the user naturally includes the rebate.
- Not a security issue: any contract can already name any recipient by supplying
  20 bytes of hook data, so trusting `msgSender()` grants no new capability. The
  lookup is gas-capped at 10,000 and a router without the interface reverts into
  the catch, which skips the attempt rather than misdirecting funds.
- Decision: treat direct Universal Router calls as the supported rebate path and
  document the one-hop boundary. Intermediaries should either forward their full
  WETH output or pass the end user as packed hook data. There is no safe generic
  onchain mechanism for the hook to discover a user hidden behind arbitrary
  contracts.

65. Hook profit is LP value redistribution, not new value
- Status: `ACCEPTED PRODUCT ECONOMICS`
- Priority: `HIGH`
- Summary: The counter-trade captures value from the v4 LP position. The product
  case is valid only when an external backrunner would otherwise capture the
  same edge; then the hook changes the recipient rather than worsening the LP's
  counterfactual outcome.
- Measurement: `testHookRedistributesExternalBackrunnerValue` uses distinct LP,
  swapper, beneficiary, and searcher accounts and replays three cases from the
  same Base block `50018808` snapshot. The external backrunner uses the hook's
  realized `0.008916275255831863 WETH` v4 input, then exits through the same v3
  pool. Every token balance is valued at the same 1881.305317 USDC/WETH reference:

  | Case | LP value | Captured by | Capture | Combined tracked value |
  |---|---:|---|---:|---:|
  | No backrun | 424,282.414448 USDC | nobody | 0 | 426,261.083397 USDC |
  | External backrun | 424,281.600721 USDC | searcher | 0.804926 USDC | 426,261.074596 USDC |
  | Hook rebate | 424,281.600721 USDC | beneficiary | 0.804926 USDC | 426,261.074596 USDC |

  The swapper's normal output is identical in all three cases. Hook and external
  backrun outcomes match within 10 raw USDC units. Both leave 0.008801 USDC less
  among the tracked parties than no backrun because that value goes to the
  external v3 venue. Gas is excluded: the hook trigger used 609,700 gas versus
  187,559 with no backrun, while the separate backrun used 164,430 gas.
- Interpretation: if nobody would backrun the thin pool, enabling the hook makes
  the LP 0.813727 USDC worse in this sample. If a matched backrun is the real
  baseline, the LP outcome is identical and the hook redirects the searcher's
  0.804926 USDC to the beneficiary. With one wallet in every role, the transfer
  cancels internally and only external fees plus gas remain.
- Live result: the controlled replacement-canary swap paid
  `0.000153175872232624 WETH` from the hook route. The next transaction in the
  same block,
  `0xf2398ab3eb7096450224cb624d46800270b69f638d5bb628f63f4ab47debe176`,
  counter-traded the v4 pool against Hydrex Integral and retained a further
  `0.000326008570667335 WETH` before gas. The one-shot hook therefore did not
  replace the external backrunner; the LP funded both captures.
- Decision: the operator disabled the one-round hook, zeroed its WETH principal
  ceiling, and burned that LP position. The current strategy deliberately uses
  the triggering v4 pool again, so this economic property applies: the hook
  redirects LP loss-versus-rebalancing to the beneficiary. That is intended
  when the alternative is an external backrunner, but on an unwatched thin pool
  it creates a transfer that otherwise might not occur. The multi-round loop
  reduces value left for a following backrunner; it does not change who funds
  the counter-trade. Treat LP depth, fee income, beneficiary policy, and external
  backrunner activity as deployment economics rather than a solvency bug.

60. No dislocation ever opens on the selected cbBTC/WETH pair
- Status: `DOES NOT APPLY TO PRODUCTION SELF-POOL ROUTE`
- Priority: `CRITICAL`
- Summary: The intended edge is same-block backrunning: a large swap dislocates
  one venue and the hook, ordered behind it, captures the gap before anyone
  reading published state can react. The mechanism is sound. The premise is not
  met on this pair, because no swap opens a gap worth trading.
- Measurement: `scripts/sample_intrablock_spread.py` replays every Swap event
  from both pools over 20,000 blocks (about 11 hours, 1,953 swaps), tracking each
  pool's post-swap tick by log index. This reconstructs the exact state a
  transaction inserted at any point inside a block would observe, which
  block-boundary sampling cannot see.

  | Series | Median | p99 | Max | Cleared 6 bps fees |
  |--------|--------|-----|-----|--------------------|
  | Spread right after each swap | 2 | 5 | 5 | 0/1937 |
  | Spread at block boundary | 2 | 5 | 5 | 0/1419 |
  | Peak dislocation inside each block | 2 | 5 | 5 | 0/1419 |
  | Per-swap tick movement | 0 | 1 | **3** | n/a |

  The last row is the governing one. Not one swap in 1,951 moved its own pool as
  much as 10 ticks, and the largest moved 3. A round trip owes PancakeSwap 1 bp
  plus Uniswap 5 bps, so it needs more than 6 ticks before gas, and `minSpreadBps`
  gates V3/V3 at 10.
- Interpretation: the gap is not being closed by faster competitors. It never
  opens. The earlier external/external fork proof had to manufacture a large
  cbBTC/WETH displacement, so it measured settlement rather than opportunity.
- Current implication: do not use cbBTC/WETH as an external/external strategy
  merely because it was a parity fixture. Production now needs one external
  reference for the same pair as the hooked v4 pool; the user's v4 swap creates
  the gap rather than relying on two external pools to diverge organically.

62. Spreads equilibrate just below each venue pair's own fee floor
- Status: `DOES NOT APPLY TO PRODUCTION SELF-POOL ROUTE`
- Priority: `CRITICAL`
- Summary: Moving to thin, high-turnover pairs does produce much larger price
  moves, but it does not produce more profit, because the pools that move are
  also the pools that charge more. Screened with
  `scripts/find_multivenue_pools.py` and `scripts/sample_intrablock_spread.py`
  over 20,000 blocks:

  | Pair | Venues | Round trip | Median per-swap move | Median spread | Moments clearing fees |
  |------|--------|-----------|----------------------|---------------|-----------------------|
  | cbBTC | UniV3 0.05% / CakeV3 0.01% | 6 bps | 0 | 2 | 0 / 1937 |
  | DEGEN | UniV3 1% / UniV3 0.3% | 130 bps | 2 | 76 | 1 / 127 |
  | BRETT | UniV3 1% / CakeV3 0.25% | 125 bps | 10 | 47 | 1 / 15 |

  Median spread tracks the fee floor in every case and stays below it.
- CORRECTION to an earlier reading of this table. The resting spread is not a gap
  that competitors are actively compressing. `scripts/find_realized_arbs.py`
  groups Swap logs by transaction hash and separates genuine arbitrage, where
  token0 enters one pool and leaves the other, from router splits, where one
  order is divided across both pools in the same direction. Over the same 20,000
  blocks:

  | Pair | Swaps | Txs touching both pools | Genuine arbs | Router splits | Single-pool txs |
  |------|-------|-------------------------|--------------|---------------|-----------------|
  | cbBTC | 1,956 | 1 | **0** | 1 | 99.9% |
  | DEGEN | 195 | 5 | **0** | 5 | 97.3% |
  | BRETT | 29 | 0 | **0** | 0 | 100% |

  Nobody arbitraged any of these pairs against itself in 11 hours. Between 97%
  and 100% of transactions touch a single pool. Each pool is priced against the
  wider market through aggregators, other venues and centralized exchanges, so
  the spread between any two of them is independent tracking error rather than a
  suppressed opportunity.
- Why there is no pair that fixes this: liquidity providers choose a fee tier to
  match how much the pair moves. Correlated assets sit in 0.01% to 0.05% pools
  and diverge little; volatile assets sit in 0.3% to 1% pools and diverge a lot.
  Spread and hurdle are therefore set by the same underlying property, which is
  why every pair measured lands just under its own fee floor.
- Consequence: the former model, comparing two registered external pools and
  trading between them, targeted a flow that essentially does not exist on Base.
  Pair selection is not the lever.
- Current implication: this remains evidence against deploying the preserved
  external/external scanner as an organic Base strategy. It does not block the
  production self-pool route, where the triggering user swap creates the
  v4/reference displacement in the same transaction. Current-head simulations
  must instead measure which trigger sizes clear both venue fees, lender fees,
  and gas for the proposed v4 liquidity profile.

63. The hook cannot capture the dislocation its own trigger creates
- Status: `ADDRESSED`
- Priority: `CRITICAL`
- Summary: A swap against the triggering v4 pool moves that pool and nothing
  else. The registered venues are untouched by it, so the trigger never creates
  the opportunity the hook then searches for. Combined with item 61, capturing
  anything needs an unrelated large swap and a trigger swap in the same block,
  in the right order.
- Rough magnitude: the best screened pair offers on the order of one tradable
  moment per ten hours. A canary v4 pool realistically sees a handful of swaps
  per day against roughly 43,000 blocks. The chance of those coinciding is far
  below one capture per year.
- The version that works: use the triggering v4 pool directly as the first leg.
  A large swap against it dislocates that pool relative to the external
  venues, and `afterSwap` runs inside the same transaction, so the hook is first
  by construction rather than by luck. This is the edge the original design
  described; the former implementation excluded it by never quoting or trading
  against the triggering pool.
- Current behavior: `afterSwap` derives the token bought by the user, sells that
  token back into the triggering v4 pool, and buys it back in a registered
  V3-compatible reference. It runs before the triggering transaction completes,
  so the hook is first by construction. Each bounded round rereads both venues.
  The preserved external scanner is not dispatched by production `afterSwap`.

64. Known-undersized trigger swaps still enter the full arbitrage path
- Status: `ACCEPTED; DYNAMIC SCREENING`
- Priority: `HIGH`
- Summary: The realized `minNetProfit` check safely rejects small opportunities,
  but only after route discovery, a flash loan, and both swap attempts. At pinned
  block `50018808`, 48 USDC fell below the `0.0001 WETH` floor while 49 USDC
  cleared it for the tested v4 liquidity.
- Current behavior: there is no PoolId-specific magic threshold. Every enabled
  callback with a valid beneficiary cheaply screens the live directional spread,
  both fees, active liquidity, price limits, minimum chunk, lender availability,
  and principal cap before borrowing. Realized `minNetProfit` remains the final
  atomic gate because the exact output is not knowable before execution. A
  market-specific offchain trigger threshold may be added only if current-head
  measurements show its saved gas justifies new onchain state and branches.

61. Backrunning only pays if the hook can be ordered behind the dislocating swap
- Status: `ADDRESSED BY CAUSAL SELF-POOL ROUTE`
- Priority: `HIGH`
- Summary: The former hook fired on swaps against its own v4 pool but never traded
  against that pool (item 26). In the old canary the trigger was WETH/USDC while
  the opportunity is cbBTC/WETH, so the two are unrelated events that must land
  in the same block in the right order.
- What works in the design's favour: Base does not publicly gossip its mempool,
  so a competitor cannot reliably observe the dislocating swap before inclusion
  and backrun it the way it could on Ethereum L1. A transaction that does land
  directly behind the dislocating swap genuinely sees state nobody reading
  published blocks could have acted on.
- What does not: the hook does not choose its position. It executes wherever the
  triggering swap happens to be ordered. Landing behind a specific transaction
  requires bidding for placement, which is the searcher game rather than an
  alternative to it. Under organic traffic the placement is luck.
- Current implication: the production route trades the pool that invoked
  `afterSwap`, so the dislocating swap and counter-trade are in the same
  transaction and ordering is deterministic. This resolves the random observer
  problem. It does not resolve item 65's LP-versus-beneficiary economics.

66. Retired native-trigger tests made the flash-fork release gate fail
- Status: `ADDRESSED`
- Priority: `HIGH`
- Summary: Two canonical-router tests still created a native-ETH/TestToken v4
  pool and expected it to trigger the retired external/external scanner. The
  production route correctly rejects native currencies and had no matching
  reference venue, so both tests failed with no settlement event.
- Resolution: stale native-trigger assumptions remain removed. The current
  ERC20/ERC20 route is covered by `ArbHookV4LoopForkTest`; it executes the actual
  callback, nested v4 settlement, V3 callback, Morpho loan, recipient payout,
  exact repayment, and residue checks. Local tests separately assert that
  production no longer scans unrelated registered pairs.

67. Nested v4 counter-trade recursion was attributed to empty hook data
- Status: `ADDRESSED AND DOCUMENTED`
- Priority: `HIGH`
- Summary: An audit claimed the nested counter-swap re-enters `afterSwap` and
  relies on empty `hookData` to stop recursion. In this v4 core,
  `Hooks.afterSwap` returns without calling the hook whenever
  `msg.sender == address(hook)`. `_executeV4Swap` is called by the hook itself,
  so its nested swap cannot invoke `ArbHook.afterSwap`, regardless of hook data.
- Decision: nested v4 execution is active in `V4ArbExecutor`. It is invoked with
  `delegatecall`, so PoolManager sees `ArbHook` as the swap caller and v4 skips
  calling that same hook recursively. Recursion safety does not depend on empty
  nested hook data. The fixed-fork multi-round test would fail recursively if
  this invariant changed.

## Open Before Any Deployment

71. Organic Uniswap routing requires hook allowlisting
- Status: `REQUIRED BEFORE ROUTING-DEPENDENT DEPLOYMENT`
- Priority: `CRITICAL`
- Summary: Uniswap's production routing API filters v4 pools whose nonzero hook
  address is not in its explicit hook-address allowlist. Adding metadata to the
  public hooklist does not automatically add an address to that routing
  allowlist. Direct swaps, third-party integrations, and searchers can still
  target the PoolId, but ordinary UI/API route discovery cannot be assumed.
- Consequence: historical canonical-router replays are upper-bound scenarios
  conditional on allowlisting. They are not evidence that a newly deployed pool
  will receive canonical flow. Without a measured traffic source, expected
  routing share and therefore expected LP revenue remain unknown.
- Action: deploy the exact reviewed hook disabled, complete the current Uniswap
  allowlisting process, then verify production quote requests consider and
  select the PoolId before enabling or scaling liquidity. Keep explicit
  discovery-share sensitivity in every economic projection.
- Sources: the routing API's
  [hook allowlist](https://github.com/Uniswap/routing-api/blob/main/lib/util/hooksAddressesAllowlist.ts),
  [quote filter](https://github.com/Uniswap/routing-api/blob/main/lib/handlers/quote/quote.ts),
  and the [hooklist submission notes](https://github.com/Uniswap/hooklist).

20. Independent review of release commit
- Status: `REQUIRED FOR NEXT DEPLOYMENT`
- Priority: `CRITICAL`
- Summary: the former review covered materially different production routes,
  including the retired one-round implementation. The current release adds an
  immutable delegate-called executor and repeated live-repriced v4/V3 rounds
  inside one flash loan. Review the exact next deployment commit rather than
  treating either the retired canary review or legacy scanner review as
  transferable.

## Accepted By Design

41. Net profit recipient resolution
- Status: `ACCEPTED`
- Summary: Empty hook data resolves the original execution caller through
  `IMsgSender.msgSender()` on the callback sender. Base's canonical Universal
  Router supports this interface. Exact packed recipient data remains an
  optional override, while failed lookups and malformed data remain fail-closed.
- Decision: ordinary canonical-router swaps rebate their initiator without a
  custom frontend. Unsupported routers skip arbitrage rather than misdirecting
  profit. Intermediary semantics are documented in item 68. The triggering
  user's ordinary swap output remains unchanged.

## Deferred Outside Research Threat Model

8. V3 factory attestation
- Status: `DEFERRED; OPERATOR VERIFICATION REQUIRED`
- Summary: V3 registration trusts the owner-supplied pool address rather than proving it against a factory.
- Decision: the retired fixed-market registration script was removed with the
  self-pool canary. Generic owner-supplied V3 registration relies on operator
  verification to avoid adding runtime registry machinery outside the trusted
  owner threat model. A future market-specific deployment script should attest
  every configured pool before broadcast.

9. Arbitrary registry-scale gas limits
- Status: `OPEN FOR DEPLOYMENT CONFIGURATION`
- Summary: Production reference selection linearly scans
  `tokenPools[startToken]` once before the loan. The legacy external/external
  scanner has deeper base/counter/pool scaling, but is not called by `afterSwap`.
- Decision: keep each production direction's reference list deliberately small
  and measure callback gas for its exact registration order. Do not add generic
  onchain scale accounting unless real use requires it.

29. Approximate V3 initialized-tick capacity
- Status: `DEFERRED IN BOUNDED CONCENTRATED-LIQUIDITY MODEL`
- Summary: Both the original V3/V3 engine and the production V4/V3 loop size
  from current active liquidity rather than traversing all initialized ticks.
- Decision: preserve the existing model. Pool-enforced price limits, atomic
  repayment, exact intermediate restoration, and realized minimum-profit checks
  remain authoritative. Do not add broad tick traversal without measured need.

## Addressed

70. Fail-open execution could make automatic gas estimation suppress arbitrage
- Status: `ADDRESSED`
- Priority: `HIGH`
- Notes: The first hook allowed an eligible low-gas swap to settle after its
  arbitrage self-call exhausted its budget. Base transaction
  `0xcf849ad5ccc4a845217ca2bd0eefd42a8e75dcedb9704d0d81ce2a3ff2f39a42`
  therefore completed without `FlashLoanSettled`. A nonzero `hookGasLimit` is
  now both the required attempt budget and its ceiling. With the trigger floor
  removed, every enabled callback with a valid recipient reaches this check;
  under-gassed swaps revert so `eth_estimateGas` must raise the limit.
- Live proof: replacement hook
  `0x7e8d44E0eAfB387a91a630536d934bbb1Ca34040` received a Base RPC estimate of
  `3,514,705` gas. Transaction
  `0x16a597c30f2c2feba6668f02890b536a3fbdf9e7e346e4cdb8fc78541dae471b`
  used `454,936` gas and settled a zero-fee Morpho route for
  `0.000153175872232624 WETH` profit. Forge script broadcasting still needs an
  RPC-derived or deliberately generous limit because Forge estimates consumed
  gas rather than the required unused envelope; that is an operator-tooling
  distinction, not an organic-router limitation.

21. Current-head Base rehearsal and economic calibration
- Status: `REQUIRED FOR NEXT DEPLOYMENT`
- Priority: `CRITICAL`
- Historical notes: the removed `ArbHookWethCanaryForkTest` ran against an unpinned Base head with
  canonical WETH/USDC V3 reference, WETH-bound Morpho adapter, canonical V4
  PoolManager, PositionManager, Permit2, Universal Router caller resolution,
  LP mint, and LP burn. At Base block `50018535`, an ordinary 100 USDC swap
  created the edge itself. The route borrowed `0.008907102809547629 WETH`, paid
  zero lender fee, returned no residue, and paid `0.000427463494774361 WETH` to
  the beneficiary. The same-snapshot disabled/enabled replay measured about
  `419546` incremental gas.
- Current evidence: `ArbHookV4LoopForkTest` now exercises the iterative successor
  at pinned Base block `50018808`. Ten rounds repay Morpho exactly, leave no
  hook residue, earn `0.001247055334869567 WETH`, and leave 134 ticks versus the
  one-round baseline's 434 ticks after the same 100 USDC trigger.
- Calibration sweep: 20 rounds settled under the default 3,000,000-gas attempt
  budget and earned `0.001313458837594588 WETH`; 25 rounds exhausted that budget
  and settled nothing. At an 8,000,000-gas diagnostic budget, the route stopped
  naturally after 31 rounds and earned `0.001321853496019977 WETH`. Iteration
  and gas bounds must be selected together; maximizing the iteration number can
  reduce realized capture to zero.
- Decision: preserve the retired figures only as historical one-round evidence.
  Before deployment, repeat the current iterative callback at current head with
  the actual v4 liquidity, V3 reference, iteration bound, principal cap, fee
  ceiling, profit floor, and realistic gas assumptions.

58. Retry suppression depends on lender revert-data propagation
- Status: `DOCUMENTED FOR LEGACY SCANNER`
- Priority: `LOW`
- Notes: `_requestFlashLoan` recognizes `FlashProfitBelowMinimum` from the
  lender's bubbled revert selector so it can suppress smaller-principal retries.
  Both bundled adapters propagate callback reverts unchanged. A future
  owner-configured lender that wraps or fabricates revert data could change the
  legacy scanner's retry selection, but cannot bypass callback authentication,
  realized minimum profit, or atomic repayment. The production V4/V3 route makes
  one adaptively sized loan request rather than trying smaller principals. The
  dependency remains explicit at the catch site for legacy execution.

57. Donated balances could expand trades beyond loan-funded sizing
- Status: `ADDRESSED`
- Priority: `HIGH`
- Notes: The flash principal configuration correctly capped borrowing, but the
  executor sized each iteration from the hook's entire start-token balance. An
  unsolicited transfer could therefore expand pool exposure without increasing
  the loan. The executor now subtracts the balance present before the active loan
  from every sizing pass while retaining it in realized balance accounting. A
  regression compares the same legacy route with and without a 5,000-token
  donation and requires identical principal and swap volume. The production
  V4/V3 loop independently sizes from loan principal plus positive profit from
  completed rounds, never `balanceOf(hook)`. Documentation calls the setting a
  borrowing ceiling, not a cumulative-volume ceiling: loan capital and earned
  profit may be reused across bounded iterations.

56. Ownership renunciation could permanently destroy the kill switch
- Status: `ADDRESSED`
- Priority: `CRITICAL`
- Notes: OpenZeppelin's inherited `renounceOwnership()` was a one-transaction,
  irreversible path to remove the only account able to disable iterations or
  flash principal. A hook cannot be detached from an initialized v4 pool, so
  `ArbHook` now overrides renunciation to revert. Two-step ownership transfer
  remains available, and the runbook requires `acceptOwnership()` plus owner and
  pending-owner readback before retiring the old key.

51. V3 edge score was treated as a raw-token profit estimate
- Status: `ADDRESSED`
- Priority: `CRITICAL`
- Notes: The flash migration compared the V3/V3 chunk-ranking score directly
  against lender fee and `minNetProfit`, even though its linearized concentrated-
  liquidity arithmetic was designed only to rank candidate chunks. Against the
  ten-round gate it differed from realized profit by up to five orders of
  magnitude in both directions. V3/V3 now uses `edgeScore` only to establish and
  rank an edge. V2/V2 and mixed paths retain their raw-token screens because they
  simulate both fee-bearing legs. Every route enforces `minNetProfit` exactly
  against realized balances in `onFlashLoan`. The production V4/V3 route does
  not use this legacy edge score; it checks directional fee-adjusted prices and
  then relies on the same authoritative realized settlement.

53. The ten-round fixture was being used to calibrate minNetProfit
- Status: `DOCUMENTED`
- Priority: `HIGH`
- Notes: This legacy external-route floor sweep is path-dependent: each floor
  changes which trades settle, subsequent pool state, and scanner work. Gas was
  measured around every trigger rather than only successful settlements:

  | minNetProfit (raw) | Rounds | Gross net (raw) | Attempt gas | After assumed gas (raw) |
  |--------------------|--------|-----------------|-------------|-------------------------|
  | 1 | 10 | 8,365,681 | 8,422,932 | +8,269,288 |
  | 2,000 / 4,000 / 6,162 | 4 | 8,341,588 | ~21,011,000 | +8,101,137 |
  | >=8,000 | 0 | 0 | ~26,004,900 | -297,603 |

- Decision: these are legacy regression and gas-sensitivity results, not a
  production opportunity ceiling. Keep that fixture floor at 1 raw unit and
  calibrate the self-pool release floor from a same-snapshot, current-head replay
  of the actual deployment configuration.

52. minSpreadBps was treated as an economic control
- Status: `RESOLVED (keep at 10)`
- Priority: `MEDIUM`
- Notes: The threshold is a tick delta, while profit is spread times depth. It
  gates legacy V3/V3 and current V4/V3 routes; V2/V2 and mixed legacy routes do
  not consult it. The historical scanner sweep included gas for every trigger:

  | minSpreadBps | Rounds | Gross net (raw) | After assumed gas (raw) |
  |--------------|--------|-----------------|-------------------------|
  | 1 / 5 / 10 | 10 | 8,365,681 | +8,269,288 |
  | 20 | 3 | 7,609 | -200,879 |
  | >=40 | 0 | 0 | -264,543 |

- Decision: keep `minSpreadBps = 10` as a cheap discovery filter. Production
  additionally checks direction, both venue fees, liquidity capacity, and
  minimum chunk before borrowing. Economic acceptance remains the authoritative
  realized `minNetProfit` check.

40. Flash-fee choice dominated canary economics
- Status: `ADDRESSED (bind Morpho)`
- Priority: `CRITICAL`
- Notes: The fixed-block ten-round sequence nets 8.365681 USDC through Aave
  after 8.945556 USDC of fees, versus 18.543625 USDC through zero-fee Morpho.
  The intended-lender gate now uses Morpho by default, preserves all ten legacy
  buy/sell routes, and pays zero lender fee. A fresh current-head canonical v4
  router lifecycle also passed through Morpho on 2026-08-02. Aave remains an
  explicit fee-bearing comparison, not the default release path. Final economic
  calibration remains item 21. The current self-pool fixed-block gate also uses
  Morpho and asserts exact zero-fee repayment; each enabled token still needs a
  current lender-availability check.

54. One V3 route could exhaust the scanner gas budget
- Status: `ADDRESSED IN LEGACY SCANNER`
- Priority: `HIGH`
- Notes: A positive result rejected by the authoritative `minNetProfit` check
  still retried alternate principals, allowing an early route to consume the
  3,000,000-gas scanner budget and starve later pairs without any guarantee that
  a retry would clear the floor. The callback now distinguishes positive-but-
  below-floor from unprofitable execution: only the latter keeps adaptive
  principal retries. Each
  isolated route execution receives half of the scanner's remaining gas so one
  route cannot consume the whole scan. A two-pair local regression proves that a
  later profitable pair still executes after an earlier below-floor pair. The
  high-floor fixed-block scan now completes in about 2.60 million gas instead of
  exhausting the ceiling, while all ten reference routes remain unchanged.

55. Calibration omitted gas from unsuccessful triggers
- Status: `ADDRESSED`
- Priority: `MEDIUM`
- Notes: The calibration harness previously added gas only when a settlement
  event existed, reporting zero execution cost for scans that consumed gas but
  settled nothing. Both sweeps now measure `gasleft()` around every
  `attemptAllForTest` trigger and convert the total with the same current-head
  reference cost. The revised tables in items 52 and 53 include failed,
  below-floor, and contained out-of-gas route work.

6. Mandatory on-chain trade-history persistence
- Status: `RESOLVED`
- Priority: `MEDIUM`
- Notes: Permanent per-trade storage made telemetry expensive and able to cancel
  an otherwise profitable trade. `DataStorage` was removed;
  `FlashLoanSettled` is the canonical event-only execution record.

28. Non-USDC base-token price normalization
- Status: `ADDRESSED`
- Notes: `_calculatePrice1e18_corrected` now uses exact quotient/remainder
  arithmetic in both token orientations without materializing a 320-bit square.
  Boundary tests cover WETH/cbBTC in both directions, the former floor-to-zero
  case, the reciprocal near the minimum sqrt price, and `type(uint160).max`.
  Exact inventory parity remains 18,679,602 raw USDC and the Morpho fixed-block
  sequence keeps all ten routes. The retired WETH canary also exercised the
  corrected orientation, but is no longer a current production gate.

42. Unbounded hook gas could revert the triggering swap
- Status: `ADDRESSED`
- Notes: The speculative self-call previously forwarded all remaining gas. The
  63/64 rule leaves only 1/64 behind, which does not cover v4 settlement when the
  swap was submitted with a modest gas limit. The production self-pool attempt
  now runs on an explicit budget from `setHookGasBounds` (200,000 reserve and
  3,000,000 required budget and ceiling by default). The current-head test
  measures the full enabled router lifecycle against an identical disabled
  snapshot. Eligible callers below that floor now revert deliberately so gas
  estimation cannot choose a successful no-arbitrage branch.

43. Unwind skipped for USDC and WETH intermediates
- Status: `ADDRESSED`
- Notes: `executeIterativeArb` skipped residue unwinding when the intermediate
  was USDC or WETH and when running profit was non-positive, but `onFlashLoan`
  requires exact intermediate restoration. In the historical USDC-base fixture
  the intermediate *is* WETH, so any partially filled leg aborted the loan.
  Unwinding now runs for every intermediate token and covers V2 pools as well as V3.
  Residue is measured as a delta against the balance held at route entry, so a
  pre-existing intermediate balance is never spent or counted.

44. Zero-output leg reverted instead of stopping
- Status: `ADDRESSED`
- Notes: A price-limited V3 leg can legitimately fill for nothing. The V2 helper
  reverted `InvalidV2FlashSwapParams` on a zero quote, discarding profit already
  realized in earlier iterations of the same loan. Both the first and second V2
  legs now stop cleanly when their quoted output is zero, matching how the V3
  path already behaved.

45. Per-transaction state held in cold storage
- Status: `ADDRESSED`
- Notes: The swap context, profit recipient, active loan fields and last-result
  fields are single-transaction values and now use EIP-1153 transient storage.
  Revert semantics are unchanged. Measured saving is roughly 75,000-90,000 gas
  per attempt (`testProfitableLoanPaysBeneficiaryAndEmitsSettlement` 794,418 to
  717,666).

46. Swap-callback context was reusable within one swap
- Status: `ADDRESSED`
- Notes: `activeSwapContextHash` was checked but never cleared, so the pool being
  swapped could invoke the repayment callback repeatedly and be paid each time.
  Not reachable with canonical pools, but the context is now single-use.

47. V3 price normalization overflowed for extreme prices
- Status: `ADDRESSED`
- Notes: `_calculatePrice1e18_corrected` materialized `sqrtP^2`, which needs up to
  320 bits and reverted inside `FullMath` for any pool priced above roughly
  1.8e19 in raw units. Exact quotient/remainder arithmetic now preserves the
  remainder before decimal scaling in the direct orientation and decomposes the
  reciprocal without materializing an oversized product. Boundary tests cover
  both ends of the uint160 sqrt-price range and the former floor-to-zero case.
  The legacy inventory oracle still reproduces 18,679,602 raw USDC exactly and
  both fixed-block flash sequences still match every round's route.

48. Single-step ownership transfer
- Status: `ADDRESSED`
- Notes: `Ownable2Step` replaces `Ownable`. A mistyped `transferOwnership`
  previously bricked all configuration including the `setHookMaxIterations(0)`
  kill switch.

49. Default suite did not exercise real route execution
- Status: `ADDRESSED`
- Notes: `ArbHookFlashLoanE2E.t.sol` replaces `executeIterativeArb` with a
  profit-minting stub, so its legacy-route tests validate flash plumbing
  against synthetic profit while real route math sat behind skipped fork tests.
  `ArbHookRealExecution.t.sol` adds three local tests that run the legacy real executor
  against constant-product pools enforcing their own K invariant, covering both
  swap legs, V2 repayment callbacks, residue handling, unprofitable-route
  containment, and donated-balance isolation. The production callback path is
  additionally exercised against real Base v4, V3, and Morpho contracts by
  `ArbHookV4LoopForkTest`, including repeated live-repriced rounds. It compares
  one and ten iterations from identical snapshots and asserts the configured
  bound reaches the production executor.

50. Flash principal sized above what is traded
- Status: `WONTFIX IN LEGACY V3/V3 ENGINE`
- Notes: Legacy V3/V3 borrows the coarse upper bound rather than the refined chunk, so
  the lender fee is paid on principal that never moves (measured worst case:
  round 8 wasted 24% of its net profit). Funding only the refined chunk was
  implemented and measured against the fixed-block gate: it breaks the route
  sequence and collapses rounds 5 and 6 from 2.32/5.95 USDC to 0.0004/0.0002,
  because the executor re-derives its binary-search range from its own balance.
  The coarse bound is the search range, not waste. Removing the double
  derivation would require threading the planned chunk into the executor, which
  changes route selection. A zero-fee lender makes the cost exactly zero without
  touching route selection; see item 40. Production V4/V3 derives and borrows
  the bounded initial route principal directly.

1. ArbHook EIP-170 deployability
- Status: `ADDRESSED; RE-MEASURED AFTER ITERATIVE SELF-POOL RESTORATION`
- Notes: `npm run size` reports `ArbHook` at 23,818 runtime bytes. That leaves
  758 bytes below EIP-170 and 182 bytes below the repository's 24,000-byte
  budget. The immutable delegate-called `V4ArbExecutor` is 5,429 bytes. Size
  optimization must not remove core route logic; the narrow project margin means
  every new onchain branch needs explicit execution value.

7. Shared pool metadata removal
- Status: `ADDRESSED`
- Notes: The canary registry is append-only. Removing/resetting live registrations was removed; a bad pre-traffic configuration requires redeployment, so one base registration cannot invalidate another registration's shared callback metadata.

10. Public execution surface for `executeIterativeArb`
- Status: `ADDRESSED`
- Notes: Entry point now reverts unless `msg.sender == address(this)` via `ArbErrors.WrapperOnlySelf`.

11. Callback acceptance for unregistered V2 pools
- Status: `ADDRESSED`
- Notes: `uniswapV2Call` and `pancakeCall` now require factory-valid pair plus registration in `poolMetaByAddr` as a V2/PancakeV2 pool with matching token ordering.

12. Mixed V2-to-V3 max-impact guard
- Status: `ADDRESSED`
- Notes: Mixed `V2 -> V3` execution now estimates projected V3-leg input impact and aborts attempts when it exceeds `_MAX_IMPACT_BPS`.
- Follow-up: the same guard now applies when V3 is the first leg of a `V3 -> V2` route.

13. Pancake V2 fee modeling consistency
- Status: `ADDRESSED`
- Notes: V2 math/simulation/quote paths now use fee-parameterized logic (`feePPM`) instead of hardcoded `997/1000`.

14. Stale Hardhat/debug references in active workflow
- Status: `ADDRESSED`
- Notes: Removed direct `hardhat/console.sol` usage and active debug logging in runtime paths.

15. Production Aave adapter missing
- Status: `ADDRESSED`
- Notes: `contracts/AaveV3ERC3156Adapter.sol` and
  `contracts/MorphoERC3156Adapter.sol` are production artifacts with local
  adapter tests and real fixed-block fork coverage. Morpho is the intended
  canary binding; Aave remains the fee-bearing comparison.

16. V4 hook-address validation disabled
- Status: `ADDRESSED`
- Notes: Production `ArbHook` validates the exact afterSwap permission bits and restricts callback entry to its immutable PoolManager. Only `ArbHookHarness` bypasses address-bit validation for arbitrary-address tests.

17. False-green opt-in tests
- Status: `ADDRESSED`
- Notes: Fork and inventory parity suites now report explicit skips when their required environment is absent.

18. Persistent failed-quote poisoning
- Status: `ADDRESSED`
- Notes: Cross-callback failed-quote caches and the redundant in-call quote set were removed. Each `_runPair` call still has at most two attempts, and the fallback excludes the first failed route's sell pool rather than poisoning the same quote across later hook callbacks.

19. Write-only discovery and activity caches
- Status: `ADDRESSED`
- Notes: Removed winner and pool-activity storage that had no read path. The ten-round route sequence remains unchanged.

3. V3/V3 max-impact enforcement
- Status: `ADDRESSED`
- Notes: V3 sizing now caps each leg's adaptive tick movement before deriving the pool-enforced `sqrtPriceLimit`. This reuses the existing sizing path, removes a redundant impact read and write-only field, and preserves both exact inventory parity and the flash-loan ten-round route sequence.

4. Production router recipient integration
- Status: `ADDRESSED`
- Notes: The callback-level flash regression uses empty hook data, resolves the
  original caller through `IMsgSender`, and pays that beneficiary. The fixed
  Base test executes the current self-pool loop and Morpho settlement, while the
  retired live canary separately proved Base's canonical Universal Router
  implementation. An exact 20-byte recipient remains an optional override.

5. CREATE2 deployment workflow
- Status: `ADDRESSED`
- Notes: `script/DeployArbHook.s.sol` mines the after-swap-only address against the canonical CREATE2 deployer and deploys the production hook. The local deployment test verifies the predicted address and constructor permission check.

22. V2/V2 flash principal sizing and execution
- Status: `ADDRESSED`
- Notes: Inventory-funded V2 execution was not historically broken; the flash migration lacked the route-specific principal decision that must happen before execution. Pre-loan sizing now reuses the existing V2 reserve-based probe ladder against the configured principal cap. It borrows twice the selected chunk so the unchanged executor's half-balance starting candidate remains identical. A fixed-block Base fork test executes a real PancakeSwap V2 to Uniswap V2 route through Aave: 20 USDC borrowed, 10 USDC swapped, 0.01 USDC fee, and 0.984011 USDC net profit in the deliberately displaced test state.

2. Mixed-route flash principal sizing
- Status: `ADDRESSED`
- Notes: Pre-loan sizing now reuses the existing mixed-route simulator and bounded halving loop, and the obsolete generic spread-utilization hint was removed. Fixed-block Aave fork tests cover both directions against real Base pools. V2-to-V3 borrowed 50 USDC, swapped 25 USDC, paid 0.025 USDC, and netted 1.190636 USDC; V3-to-V2 used the same principal and fee and netted 1.820425 USDC in deliberately displaced test states.

23. Fail-closed canary economic configuration
- Status: `ADDRESSED`
- Notes: The owner-run configuration script requires explicit nonzero WETH
  principal, fee-cap, and minimum-net-profit values, applies the principal cap
  last, and does not enable execution. Historical WETH values are not valid for
  a new v4/reference liquidity profile; recalibration is required before any
  deployment.

24. Swap callback binding to active execution
- Status: `ADDRESSED`
- Notes: V2 and V3 repayment callbacks now require the exact `(pool, callback data)` context installed immediately around the synchronous swap. A registered pool cannot spend residual hook balances by presenting a forged payload outside an ArbHook-initiated swap.

25. Linked library omitted from release inventory
- Status: `ADDRESSED`
- Notes: `ArbitrageLogic` has an external link to `ArbMath`, which Foundry deploys
  automatically through the CREATE2 factory. Any replacement runbook must record
  and verify `ArbMath`, `ArbitrageLogic`, the Aave and Morpho adapters,
  `ArbHook`, and the immutable `V4ArbExecutor` created by the hook constructor.

26. Triggering v4 pool is not an arbitrage venue
- Status: `ADDRESSED; TRIGGERING V4 POOL IS THE FIRST LEG`
- Notes: Production now trades the triggering v4 pool against one registered
  V3-compatible reference for the same pair. This makes the user's swap the
  cause of the opportunity and removes the unrelated-event timing dependency.
  The legacy external/external scanner remains intact for parity and research
  but is not called by `afterSwap`.

27. Flash settlement can retain intermediate-token residue
- Status: `ADDRESSED`
- Notes: The flash callback snapshots the intermediate-token balance and requires exact restoration after route execution. A partial fill cannot settle while trapping new intermediate tokens or consuming an accidental pre-existing balance.

30. Unused deployed calculation surfaces
- Status: `ADDRESSED`
- Notes: Removed unused dust checks, exact-output helpers, public passthroughs, and dead `ArbMath` pricing/profit routines. This removed 2,148 runtime bytes across `ArbitrageLogic` and `ArbMath` without changing hook behavior or exact parity.

31. Mixed-route impact unit mismatch
- Status: `ADDRESSED`
- Notes: The local V3 impact estimate previously returned `10,000` for one tick-spacing interval while `_MAX_IMPACT_BPS` treats approximately one tick as one basis point. The estimate now scales interval capacity by tick spacing, preserving the existing cheap approximation without adding tick traversal.

32. Mutable V3 binary-search scale denominator
- Status: `ADDRESSED`
- Notes: Midpoint output was scaled against the search's mutable upper bound even though the full-output quote came from the original upper bound. The search now retains that original bound; exact inventory parity and all fixed-fork flash routes remain unchanged.

33. Lossy V3 liquidity-delta arithmetic
- Status: `ADDRESSED`
- Notes: `_exactCapacity` converted the current `uint128` liquidity through `int128`, which could reinterpret valid high liquidity as negative before crossing a tick. It now uses Uniswap's canonical `LiquidityMath.addDelta` implementation.

34. Reverted route did not advance fallback discovery
- Status: `ADDRESSED`
- Notes: A contained low-level execution revert incremented the retry count without excluding the failed sell pool, so the second and final attempt could rediscover the same route. The fallback now excludes that sell pool before discovery runs again.

35. Unreachable two-attempt retry bookkeeping
- Status: `ADDRESSED`
- Notes: The removed quote-hash array and buy-pool rotation counters could not affect a two-attempt loop once every failed first route advances by excluding its sell pool. The two-attempt guardrail and deterministic fallback remain.

36. Oversized internal calculation interfaces
- Status: `ADDRESSED`
- Notes: Removed unused simulator arguments and external selectors from helpers used only inside `ArbitrageLogic`. This changes no route math or hook-facing behavior.

37. Write-only pool fee metadata
- Status: `ADDRESSED`
- Notes: Removed the duplicated `PoolMeta.fee` storage field. Pricing and execution continue to derive fees from the registered pool type or the pool itself.

38. Duplicate flash-lender authorization state
- Status: `ADDRESSED`
- Notes: Removed the independent lender-trust mapping because only the owner can bind a lender to a token and the callback already requires the exact active lender, initiator, token, amount, and context hash. One per-token lender binding is now the single source of truth.

39. Unreachable V2 sizing fallbacks
- Status: `ADDRESSED`
- Notes: Removed a duplicate minimum-chunk simulation and post-selection cap branches that could not change the result because the minimum is always the first probe and every probe is bounded before selection. The minimum, 1%, 10%, and 50% probe ladder, fee-aware reserve simulation, and best-profit choice remain unchanged.
