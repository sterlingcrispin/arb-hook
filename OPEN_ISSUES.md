# Open Issues

## Context
This tracker records the audit findings list and current disposition.

## Canary Threat Model

The initial deployment is owner-operated with a small set of manually verified, canonical Base tokens, pools, and lenders. Malicious owner-supplied assets and permissionless registry inputs are not part of the current threat model. External callbacks, atomic repayment, economic correctness, and recipient routing remain in scope.

## Open For Canary

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

1. ArbHook EIP-170 deployability
- Status: `ADDRESSED`
- Notes: Cold registration validation moved into the existing `ArbitrageLogic` dependency and unused runtime surfaces were removed. `npm run size` enforces a 24,000-byte budget, leaving at least 576 bytes below the 24,576-byte EIP-170 limit for every production contract.

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
- Notes: Cross-callback failed-quote caches were removed. The bounded in-memory retry set remains, and a regression proves an unchanged quote retries after lender capacity recovers.

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
