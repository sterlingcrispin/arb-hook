# Open Issues

## Context
This tracker records the audit findings list and current disposition.

## Canary Threat Model

The initial deployment is owner-operated with a small set of manually verified, canonical Base tokens, pools, and lenders. Malicious owner-supplied assets and permissionless registry inputs are not part of the current threat model. External callbacks, atomic repayment, economic correctness, and recipient routing remain in scope.

## Open For Canary

1. [Critical] ArbHook undeployable on EVM chains due to code size
- Status: `OPEN`
- Priority: `CRITICAL`
- Summary: Runtime code size exceeded EIP-170 deployment limit.
- Decision: deferred for now per current development priority.

2. V2 and mixed-route flash principal sizing
- Status: `OPEN`
- Priority: `HIGH`
- Summary: V3/V3 routes derive principal from existing liquidity math before borrowing. V2/V2 and mixed routes still begin with a generic quote-based principal and calculate their trade chunk after the loan fee is committed.
- Decision: add route-specific tests before changing the legacy sizing loops.

3. V3/V3 max-impact enforcement
- Status: `OPEN`
- Priority: `HIGH`
- Summary: V3 sizing calculates estimated impact but does not currently apply `_MAX_IMPACT_BPS` as a hard cap.
- Decision: enforce only with a regression that preserves the ten-round fixed-block route sequence.

4. Production router recipient integration
- Status: `OPEN`
- Priority: `HIGH`
- Summary: Unit tests cover `sender` and a 32-byte `hookData` override, but a real V4 router usually appears as the hook sender.
- Decision: test and document the intended router's beneficiary encoding before canary traffic.

5. CREATE2 deployment workflow
- Status: `OPEN`
- Priority: `HIGH`
- Summary: Production `ArbHook` now validates V4 permission bits, but the repository does not yet include the mined-address deployment script.
- Decision: add the deployment workflow during the EIP-170 deployment pass.

6. Mandatory on-chain trade-history persistence
- Status: `RESOLVED`
- Priority: `MEDIUM`
- Summary: Permanent per-trade storage made telemetry expensive and able to cancel an otherwise profitable trade.
- Decision: removed `DataStorage`; `FlashLoanSettled` is now the canonical event-only execution record.

## Deferred Outside Canary Threat Model

7. Shared pool metadata removal
- Status: `DEFERRED`
- Summary: Removing a pool registered under multiple base tokens clears global metadata for surviving registrations.
- Decision: the canary uses a static curated registry and will not mutate shared registrations while live.

8. V3 factory attestation
- Status: `DEFERRED`
- Summary: V3 registration trusts the owner-supplied pool address rather than proving it against a factory.
- Decision: the canary operator verifies canonical pool addresses before registration.

9. Arbitrary registry-scale gas limits
- Status: `DEFERRED`
- Summary: Discovery cost scales with configured bases, counters, and pools.
- Decision: the canary uses a small bounded pool book; add explicit limits before supporting a broad registry.

## Addressed

10. Public execution surface for `executeIterativeArb`
- Status: `ADDRESSED`
- Notes: Entry point now reverts unless `msg.sender == address(this)` via `ArbErrors.WrapperOnlySelf`.

11. Callback acceptance for unregistered V2 pools
- Status: `ADDRESSED`
- Notes: `uniswapV2Call` and `pancakeCall` now require factory-valid pair plus registration in `poolMetaByAddr` as a V2/PancakeV2 pool with matching token ordering.

12. Mixed V2-to-V3 max-impact guard
- Status: `ADDRESSED`
- Notes: Mixed `V2 -> V3` execution now estimates projected V3-leg input impact and aborts attempts when it exceeds `_MAX_IMPACT_BPS`.

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
- Notes: Production `ArbHook` now uses BaseHook permission-bit validation. Only `ArbHookHarness` bypasses validation for arbitrary-address tests.

17. False-green opt-in tests
- Status: `ADDRESSED`
- Notes: Fork and inventory parity suites now report explicit skips when their required environment is absent.

18. Persistent failed-quote poisoning
- Status: `ADDRESSED`
- Notes: Cross-callback failed-quote caches were removed. The bounded in-memory retry set remains, and a regression proves an unchanged quote retries after lender capacity recovers.

19. Write-only discovery and activity caches
- Status: `ADDRESSED`
- Notes: Removed winner and pool-activity storage that had no read path. The ten-round route sequence remains unchanged.
