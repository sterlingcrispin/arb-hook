# Open Issues

## Context
This tracker records the audit findings list and current disposition.

## Canary Threat Model

The initial deployment is owner-operated with a small set of manually verified, canonical Base tokens, pools, and lenders. Malicious owner-supplied assets and permissionless registry inputs are not part of the current threat model. External callbacks, atomic repayment, economic correctness, and recipient routing remain in scope.

## Open For Canary

60. No dislocation ever opens on the selected cbBTC/WETH pair
- Status: `BLOCKS DEPLOYMENT`
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
  opens. Trades against this pair are far too small relative to its liquidity to
  move the price. `ArbHookWethCanaryFork.t.sol` has to swap 150 WETH, roughly
  $450k, to manufacture the dislocation it then captures, which is why its
  0.001606 WETH result measures execution rather than opportunity.
- Decision: do not fund this pair. Screen candidates on per-swap tick movement,
  not volume or liquidity. The requirement is a venue where ordinary trades
  routinely move the price past the fee floor, which means thin liquidity
  relative to typical trade size, the opposite of how this target was chosen.

61. Backrunning only pays if the hook can be ordered behind the dislocating swap
- Status: `DOCUMENTED`
- Priority: `HIGH`
- Summary: The hook fires on swaps against its own v4 pool and never trades
  against that pool (item 26). In the WETH canary the trigger is WETH/USDC while
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
- Decision: settle this before selecting a market. Either accept a low capture
  rate on genuinely large dislocations, or change the trigger so the swap that
  fires the hook is the same event that creates the dislocation, for example by
  attaching the hook to a pool that is itself one of the arbitrage venues.

20. Independent review of release commit
- Status: `BLOCKS DEPLOYMENT`
- Priority: `CRITICAL`
- Summary: The flash-loan, callback, and route-execution changes need independent Solidity review against the exact release commit.
- Decision: no mainnet swap routing before sign-off on the exact release diff.
  The prior external review predates the unequal-decimal WETH normalization and
  WETH canary tooling. This is an external release gate, not a reason to add more
  onchain checks.

## Accepted By Design

41. Net profit is paid to a swapper-controlled beneficiary
- Status: `ACCEPTED`
- Summary: `hookData` names the beneficiary and receives 100% of net profit.
  Anyone may swap a hooked pool, or initialize their own pool with this hook,
  and direct the full proceeds to themselves. The contract has no owner fee.
- Decision: intended. The hook returns its edge to the trader who triggered it
  rather than collecting rent for the operator. Recorded in `README.md` so the
  absence of operator revenue is not mistaken for a defect.

## Deferred Outside Canary Threat Model

8. V3 factory attestation
- Status: `ADDRESSED FOR FIXED CANARY; GENERIC ENFORCEMENT DEFERRED`
- Summary: V3 registration trusts the owner-supplied pool address rather than proving it against a factory.
- Decision: `RegisterArbHookCanaryPools` attests code, factory, tokens, and fees
  for the exact two-pool manifest before broadcast. Generic owner-supplied V3
  registration still relies on operator verification to avoid adding runtime
  registry machinery outside the canary threat model.

9. Arbitrary registry-scale gas limits
- Status: `DEFERRED`
- Summary: Discovery cost scales with configured bases, counters, and pools.
- Decision: the canary uses a small bounded pool book. Because each isolated
  route receives half the remaining scanner gas, failed-route budgets decay
  approximately `G/2`, `G/4`, then `G/8` across pairs. Revisit traversal and add
  explicit scale limits before supporting a broad registry.

29. Approximate V3 initialized-tick capacity
- Status: `DEFERRED`
- Summary: `_exactCapacity` advances by tick-spacing intervals rather than scanning the initialized-tick bitmap, so it can miss liquidity changes when the current tick is not aligned to an initialized boundary.
- Decision: do not add expensive tick traversal for the canary. Pool price limits, atomic repayment, intermediate-balance restoration, and realized minimum-profit enforcement remain authoritative; revisit sizing precision after canary results.

## Addressed

21. Current-head Base rehearsal and economic calibration
- Status: `ADDRESSED; RE-RUN IMMEDIATELY BEFORE BROADCAST`
- Priority: `CRITICAL`
- Notes: `ArbHookWethCanaryForkTest` now runs against an unpinned Base head with
  the exact two-pool cbBTC/WETH manifest, WETH-bound Morpho adapter, canonical
  V4 PoolManager, PositionManager, Permit2, Universal Router, packed beneficiary,
  LP mint, and LP burn. On 2026-08-15 it borrowed 1 WETH, paid zero fee, returned
  no residue, and paid `0.001606426560759256 WETH` to the beneficiary. An
  identical-snapshot disabled/enabled replay measured 162,467 versus 899,973
  gas, or 737,506 incremental gas. At the observed 0.006 gwei RPC price this was
  `0.000004425036 WETH`; the provisional `0.0001 WETH` floor was about 22.6x
  measured incremental L2 cost.
- Decision: the integration and calibration blocker is addressed in code. The
  runbook still requires the same unpinned test and address checks immediately
  before broadcast because lender liquidity, gas price, and market state move.

58. Retry suppression depends on lender revert-data propagation
- Status: `DOCUMENTED`
- Priority: `LOW`
- Notes: `_requestFlashLoan` recognizes `FlashProfitBelowMinimum` from the
  lender's bubbled revert selector so it can suppress smaller-principal retries.
  Both bundled adapters propagate callback reverts unchanged. A future
  owner-configured lender that wraps or fabricates revert data could change retry
  selection, but cannot bypass callback authentication, realized minimum profit,
  or atomic repayment. The dependency is now explicit at the catch site and
  must be checked when adding another adapter.

57. Donated balances could expand trades beyond loan-funded sizing
- Status: `ADDRESSED`
- Priority: `HIGH`
- Notes: The flash principal configuration correctly capped borrowing, but the
  executor sized each iteration from the hook's entire start-token balance. An
  unsolicited transfer could therefore expand pool exposure without increasing
  the loan. The executor now subtracts the balance present before the active loan
  from every sizing pass while retaining it in realized balance accounting. A
  regression compares the same route with and without a 5,000-token donation and
  requires identical principal and swap volume. Documentation now calls the
  setting a borrowing ceiling, not a cumulative-volume ceiling: loan capital and
  earned profit may be reused across bounded iterations.

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
  against realized balances in `onFlashLoan`.

53. The ten-round fixture was being used to calibrate minNetProfit
- Status: `DOCUMENTED`
- Priority: `HIGH`
- Notes: The floor sweep is path-dependent: each floor changes which trades
  settle, subsequent pool state, and scanner work. Gas is now measured around
  every trigger rather than only successful settlements:

  | minNetProfit (raw) | Rounds | Gross net (raw) | Attempt gas | After assumed gas (raw) |
  |--------------------|--------|-----------------|-------------|-------------------------|
  | 1 | 10 | 8,365,681 | 8,422,932 | +8,269,288 |
  | 2,000 / 4,000 / 6,162 | 4 | 8,341,588 | ~21,011,000 | +8,101,137 |
  | >=8,000 | 0 | 0 | ~26,004,900 | -297,603 |

- Decision: these are regression and gas-sensitivity results, not a production
  opportunity ceiling. Production pools move between independent swap triggers.
  Keep the fixture floor at 1 raw unit and calibrate the release floor from the
  runbook's same-snapshot, current-head differential replay.

52. minSpreadBps was treated as an economic control
- Status: `RESOLVED (keep at 10)`
- Priority: `MEDIUM`
- Notes: The threshold is a V3 tick delta, while profit is spread times depth.
  It gates V3/V3 only; V2/V2 and mixed routes do not consult it. The revised
  sweep includes scanner gas for every trigger:

  | minSpreadBps | Rounds | Gross net (raw) | After assumed gas (raw) |
  |--------------|--------|-----------------|-------------------------|
  | 1 / 5 / 10 | 10 | 8,365,681 | +8,269,288 |
  | 20 | 3 | 7,609 | -200,879 |
  | >=40 | 0 | 0 | -264,543 |

- Decision: keep `minSpreadBps = 10` as the regression-proven cheap discovery
  filter. Economic filtering belongs in the route-specific pre-loan checks and
  authoritative realized `minNetProfit` check.

40. Flash-fee choice dominated canary economics
- Status: `ADDRESSED (bind Morpho)`
- Priority: `CRITICAL`
- Notes: The fixed-block ten-round sequence nets 8.365681 USDC through Aave
  after 8.945556 USDC of fees, versus 18.543625 USDC through zero-fee Morpho.
  The intended-lender gate now uses Morpho by default, preserves all ten legacy
  buy/sell routes, and pays zero lender fee. A fresh current-head canonical v4
  router lifecycle also passed through Morpho on 2026-08-02. Aave remains an
  explicit fee-bearing comparison, not the default release path. Final economic
  calibration remains item 21.

54. One V3 route could exhaust the scanner gas budget
- Status: `ADDRESSED`
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
  Exact inventory parity remains 18,679,602 raw USDC, the Morpho fixed-block
  sequence keeps all ten routes, and the current-head WETH canary settles the
  real cbBTC/WETH route naturally.

42. Unbounded hook gas could revert the triggering swap
- Status: `ADDRESSED`
- Notes: The `attemptAllInternal` self-call forwarded all remaining gas. The
  63/64 rule leaves only 1/64 behind, which does not cover v4 settlement when the
  swap was submitted with a modest gas limit, so an expensive discovery pass
  could revert the user's swap. The attempt now runs on an explicit budget from
  `setHookGasBounds` (200,000 reserve, 3,000,000 ceiling by default), covered by
  `testTightGasBudgetSkipsArbAndLeavesCallerGas` and
  `testGasCeilingBoundsASuccessfulAttempt`.

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
  profit-minting stub, so all eleven of its tests validated flash plumbing
  against synthetic profit while real route math sat behind skipped fork tests.
  `ArbHookRealExecution.t.sol` adds six local tests that run the real executor
  against constant-product pools enforcing their own K invariant, covering both
  swap legs, the V2 repayment callbacks, residue handling, unprofitable-route
  containment and the gas budget.

50. Flash principal sized above what is traded
- Status: `WONTFIX`
- Notes: V3/V3 borrows the coarse upper bound rather than the refined chunk, so
  the lender fee is paid on principal that never moves (measured worst case:
  round 8 wasted 24% of its net profit). Funding only the refined chunk was
  implemented and measured against the fixed-block gate: it breaks the route
  sequence and collapses rounds 5 and 6 from 2.32/5.95 USDC to 0.0004/0.0002,
  because the executor re-derives its binary-search range from its own balance.
  The coarse bound is the search range, not waste. Removing the double
  derivation would require threading the planned chunk into the executor, which
  changes route selection. A zero-fee lender makes the cost exactly zero without
  touching route selection; see item 40.

1. ArbHook EIP-170 deployability
- Status: `ADDRESSED`
- Notes: Cold registration validation moved into the existing `ArbitrageLogic`
  dependency and unused runtime surfaces were removed. `ArbHook` is 22,333
  runtime bytes: 1,667 bytes below the repository's 24,000-byte budget and 2,243
  bytes below the 24,576-byte EIP-170 limit.

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
- Notes: Fork tests send a real v4 swap through Base's canonical Universal Router
  and PoolManager, then verify that the arb pays the beneficiary encoded as
  exactly 20 packed bytes. The Aave lifecycle remains covered, and a fresh
  current-head rehearsal passed through the intended Morpho adapter on
  2026-08-02 with zero lender fee.

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
- Notes: The owner-run configuration script requires explicit nonzero USDC principal, fee-cap, and minimum-net-profit values, applies the principal cap last, and does not enable hook iterations. The runbook defines the raw-unit differential-gas formula and records `0.10 USDC` only as a provisional rehearsal floor; the final value remains part of the current-head release gate.

24. Swap callback binding to active execution
- Status: `ADDRESSED`
- Notes: V2 and V3 repayment callbacks now require the exact `(pool, callback data)` context installed immediately around the synchronous swap. A registered pool cannot spend residual hook balances by presenting a forged payload outside an ArbHook-initiated swap.

25. Linked library omitted from release inventory
- Status: `ADDRESSED`
- Notes: `ArbitrageLogic` has an external link to `ArbMath`, which Foundry deploys
  automatically through the CREATE2 factory. The runbook requires recording and
  verifying all five artifacts: `ArbMath`, `ArbitrageLogic`, the Aave and Morpho
  adapters, and `ArbHook`.

26. Triggering v4 pool is not an arbitrage venue
- Status: `DOCUMENTED`
- Notes: `afterSwap` uses the v4 swap only as an execution trigger. Current route discovery and execution compare registered V2/V3 pools and do not quote or trade against the triggering v4 pool.

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
