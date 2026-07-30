# Open Issues

## Context
This tracker records the audit findings list and current disposition.

## Canary Threat Model

The initial deployment is owner-operated with a small set of manually verified, canonical Base tokens, pools, and lenders. Malicious owner-supplied assets and permissionless registry inputs are not part of the current threat model. External callbacks, atomic repayment, economic correctness, and recipient routing remain in scope.

## Open For Canary

51. Pre-loan profit estimate is not a usable economic quantity
- Status: `BLOCKS DEPLOYMENT`
- Priority: `CRITICAL`
- Summary: `executeIterativeArbViaFlash` gates borrowing with
  `expectedRouteProfit - fee < minNetProfit`, treating `expectedRouteProfit` as a
  raw token amount. It is not one. Measured against the ten-round gate, the
  estimate misses realized profit by up to five orders of magnitude and in both
  directions:

  | Round | Realized net (raw) | Estimate (raw) | Ratio |
  |-------|--------------------|----------------|-------|
  | 1 | 427 | 168 | 0.4x |
  | 2 | 239 | 65 | 0.3x |
  | 3 | 7,000 | 5,030,965 | 719x |
  | 4 | 59,265 | 46,024,647 | 777x |
  | 7 | 1,161 | 3,004,834 | 2,588x |
  | 8 | 5,646 | 21,258,118 | 3,765x |
  | 9 | 58 | 2,909,521 | 50,164x |

- Cause: `_binarySearchBestChunk` scales both legs linearly
  (`intermOut_full * mid / fullChunk`, `poolB_maxStartOut * intermInB / poolB_maxIn`),
  which is false for concentrated liquidity, and `ArbMath._simulatedPL` deducts
  only pool B's fee because `_deltaAmounts` is a fee-less price-move calculation.
  The quantity was sound as a *relative* ranking for chunk selection, which is all
  the pre-flash design used it for. The flash migration repurposed the same number
  as an absolute currency comparison.
- Status detail: `ADDRESSED`. The V3/V3 path now screens only for the presence of
  edge (`edgeScore != 0`) and never compares the score against currency. The V2/V2
  and mixed paths keep their currency screen because both genuinely simulate each
  leg against real reserves or swap math with both pool fees deducted. Naming was
  corrected throughout: `ArbMath._simulatedPL` is now `_edgeScore`, `findBestV3Chunk`
  returns `edgeScore`, and the hook's currency variable is `expectedNetProfit`.
  `minNetProfit` remains enforced exactly against realized balances in `onFlashLoan`
  for every route type.
- CORRECTION: this defect does **not** explain the `minNetProfit` cliff described in
  item 53. Re-running the sweep after the fix produced identical results. The
  estimate divergence is real and screening on it was wrong, but it was not the
  cause of the cliff. See item 53 for the actual mechanism.

53. The ten-round fixture cannot calibrate minNetProfit
- Status: `DOCUMENTED`
- Priority: `HIGH`
- Summary: Sweeping the floor across the fixture shows 4 rounds executing at
  2,000-6,162 raw and **zero** at 8,000 raw (0.008 USDC). Two hypotheses were
  tested and both are wrong: it is not the pre-loan estimate (item 51, fixed, no
  change to the sweep) and it is not a cascade (seeding round 1 without a floor
  does not unlock later rounds at the higher floor; `testRoundSequenceIsACascade`
  executes 0).
- Actual mechanism: the fixture seeds one fixed displacement and the hook is the
  only actor in it. When no route clears the floor, nothing trades, so the pool
  state never moves and every later round re-evaluates identical state and fails
  identically. The best single-shot opportunity in the seeded state is worth about
  7,369 raw USDC, so any floor above that reports zero forever. The floor also
  changes which route round 1 selects, so each floor traces a different trajectory
  rather than filtering a fixed one.
- Consequence: the number this fixture reports is a property of its seeded
  displacement, not of production. In production each swap is an independent
  trigger and other traders move the pools between them, so a floor above the
  fixture's ceiling is not a deadlock, only "no trade right now".
- Decision: calibrate `minNetProfit` from the runbook's current-head differential
  gas replay, never from this fixture. Keep the fixture's floor at 1 raw unit so it
  continues to exercise all ten routes as a route-selection regression.

52. minSpreadBps is not an economic control
- Status: `RESOLVED (keep at 10)`
- Priority: `MEDIUM`
- Summary: Calibration sweep across the ten-round gate:

  | minSpreadBps | Rounds | Gross net (raw) | After gas (raw) |
  |--------------|--------|-----------------|-----------------|
  | 1 / 5 / 10 | 10 | 8,365,681 | +8,242,441 |
  | 20 | 3 | 7,609 | **-29,363** |
  | >=40 | 0 | 0 | 0 |

- The threshold compares a V3 **tick delta**, but profit is spread times depth.
  The widest tick spreads here belong to the seeded cbBTC/USDC gap, which is the
  least profitable in absolute terms, while rounds 5 and 6 (2.32 and 5.95 USDC)
  come from narrow spreads on deep WETH/USDC liquidity. Raising the threshold
  therefore deletes the profitable trades first and turns the sequence into a net
  loss at 20.
- It also gates V3/V3 routes only (`ArbitrageLogic` spread check, the V3/V3 branch
  of `executeIterativeArb`, and `_deriveV3Principal`). V2/V2 and mixed routes
  ignore it entirely, which `README.md` did not previously say.
- Decision: keep `minSpreadBps = 10` and treat it as a cheap gas pre-filter, not a
  profitability control. Economic filtering belongs in `minNetProfit`, which is
  blocked on item 51.

40. Flash-fee choice dominates canary economics
- Status: `BLOCKS DEPLOYMENT`
- Priority: `CRITICAL`
- Summary: Replaying the ten-round fixed-block gate with real Aave fees nets
  8.365681 USDC against the 18.679602 USDC legacy gross. The 5 bps premium takes
  55% of the edge. Against the runbook's measured 0.012324 USDC L2 execution
  cost, rounds 1, 2, 3, 7, 8 and 9 are net-negative and round 10 is marginal;
  only rounds 4, 5 and 6 clear. At the provisional 0.10 USDC floor only rounds 5
  and 6 would execute, so the gate cannot run at production economic settings.
- Decision: bind `MorphoERC3156Adapter` (zero fee, ~197.6M USDC on Base,
  verified against live state by `MorphoERC3156Adapter.t.sol`) instead of the
  Aave adapter, then recalculate the minimum net-profit floor from a current-head
  differential gas replay. Re-run the fixed-block gate against the chosen lender
  and record the resulting per-round net profits with the release artifacts.

20. Independent review of release commit
- Status: `BLOCKS DEPLOYMENT`
- Priority: `CRITICAL`
- Summary: The flash-loan, callback, and route-execution changes need independent Solidity review against the exact release commit.
- Decision: no mainnet swap routing before external sign-off. This is an external release gate, not a reason to add more onchain checks.

21. Current-head Base rehearsal and economic calibration
- Status: `BLOCKS DEPLOYMENT`
- Priority: `CRITICAL`
- Summary: The deterministic fork gates use Base block 33942262. They cannot prove current lender premiums, liquidity, canonical contract state, route economics, or transaction cost.
- Evidence: The canonical router lifecycle passed on Base block 49149499 with the live Aave premium at 5 bps. The successful hook path used 1,076,889 gas and settled through the expected beneficiary path.
- Decision: run the intended manifest through a fresh current-head fork, verify canonical addresses and code, and set the minimum net-profit floor from a differential gas replay before deployment.

6. Mandatory on-chain trade-history persistence
- Status: `RESOLVED`
- Priority: `MEDIUM`
- Summary: Permanent per-trade storage made telemetry expensive and able to cancel an otherwise profitable trade.
- Decision: removed `DataStorage`; `FlashLoanSettled` is now the canonical event-only execution record.

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
- Status: `DEFERRED`
- Summary: V3 registration trusts the owner-supplied pool address rather than proving it against a factory.
- Decision: the canary operator verifies canonical pool addresses before registration.

9. Arbitrary registry-scale gas limits
- Status: `DEFERRED`
- Summary: Discovery cost scales with configured bases, counters, and pools.
- Decision: the canary uses a small bounded pool book; add explicit limits before supporting a broad registry.

28. Non-USDC base-token price normalization
- Status: `DEFERRED`
- Summary: Legacy V2/V3 price normalization preserves relative ordering for the regression-tested USDC-base pool book, but V3 WETH-base prices can round to zero.
- Decision: the canary registers and borrows USDC only. Correct both token orientations later behind dedicated parity coverage rather than changing legacy discovery immediately before the canary.

29. Approximate V3 initialized-tick capacity
- Status: `DEFERRED`
- Summary: `_exactCapacity` advances by tick-spacing intervals rather than scanning the initialized-tick bitmap, so it can miss liquidity changes when the current tick is not aligned to an initialized boundary.
- Decision: do not add expensive tick traversal for the canary. Pool price limits, atomic repayment, intermediate-balance restoration, and realized minimum-profit enforcement remain authoritative; revisit sizing precision after canary results.

## Addressed

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
  requires exact intermediate restoration. For the USDC-base canary the
  intermediate *is* WETH, so any partially filled leg aborted the loan. Unwinding
  now runs for every intermediate token and covers V2 pools as well as V3.
  Residue is measured as a delta against the balance held at route entry, so a
  pre-existing intermediate balance is never spent or counted.

44. Zero-output leg reverted instead of stopping
- Status: `ADDRESSED`
- Notes: A price-limited V3 leg can legitimately fill for nothing. The V2 helper
  reverted `InvalidV2FlashSwapParams` on a zero quote, discarding profit already
  realized in earlier iterations of the same loan. The executor now breaks
  cleanly, matching how the V3 path already behaved.

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
  1.8e19 in raw units. It is now two `mulDiv` steps with every intermediate below
  2^256 across the full uint160 sqrt-price range. The legacy inventory oracle
  still reproduces 18,679,602 raw USDC exactly and the fixed-block flash gate
  still matches every round's route, so the rewrite is behavior-preserving.

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
- Notes: Cold registration validation moved into the existing `ArbitrageLogic` dependency and unused runtime surfaces were removed. `ArbHook` is 21,945 runtime bytes: 2,055 bytes below the repository's 24,000-byte budget and 2,631 bytes below the 24,576-byte EIP-170 limit.

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
- Notes: `contracts/AaveV3ERC3156Adapter.sol` is now the production artifact used by both local adapter tests and the fixed-block Aave fork suite.

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
- Notes: The fixed-block fork test now sends a real v4 swap through Base's canonical Universal Router and PoolManager, then verifies that the real Aave-backed arb pays the beneficiary encoded as exactly 20 packed bytes.

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
- Notes: `ArbitrageLogic` has an external link to `ArbMath`, which Foundry deploys automatically through the CREATE2 factory. The runbook now requires recording and verifying that library alongside `ArbitrageLogic`, the Aave adapter, and `ArbHook`.

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
