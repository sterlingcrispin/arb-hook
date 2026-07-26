# Flash Loan Migration Plan

## Goal
Migrate `ArbHook` from inventory-funded arbitrage to flash-loan-funded arbitrage, so the hook does not need to hold principal inventory and net profits are paid to the swap initiator (or an explicit beneficiary).

## Context
- Current execution is hook-triggered and best-effort via `_afterSwap -> _attemptAllViaSelfCall -> attemptAllInternal -> _runPair -> executeIterativeArb`.
- Current implementation uses contract balances as principal in iterative sizing and callback repayment logic.
- The legacy inventory parity suite is the historical gross-profit baseline. The flash fork suite must preserve its natural per-round route sequence while remaining net-positive after lender fees.

## Canary Threat Model
- The owner/operator is trusted and registers a small set of pre-verified, canonical Base tokens, pools, and lender contracts.
- Permissionless pool or token registration is not supported.
- Protecting the owner from intentionally or accidentally registering a malicious token or fake pool is not part of the initial canary.
- External callers, forged callbacks, incorrect flash-loan context, repayment failure, profit accounting, and beneficiary routing remain untrusted runtime boundaries.
- Factory attestation, shared-pool metadata reference counting, and arbitrary registry-scale limits are deferred unless the operating model changes.

## Scope
- Add a production-capable flash-loan execution path (initially ERC-3156 lenders).
- Preserve current route discovery and sizing logic where possible.
- Add deterministic beneficiary payout logic.
- Keep a flash-loan fork regression gate alongside local correctness and safety tests.

## Non-Goals (for this phase)
- Multi-lender auctioning/routing.
- Full optimal on-chain sizing solver or tick-by-tick simulation.
- Exact legacy gross-profit equality after lender fees. The required compatibility target is route sequence plus positive net settlement.
- Solving contract-size deployability limits (EIP-170/24KB) in this migration pass.
- A permissionless or adversarial asset registry.

## Explicit Out-of-Scope Note (Size/Gas)
- The current contract is likely too large for mainnet deployment today.
- We will still keep edits gas-conscious during this refactor, but deep size-reduction work is intentionally deferred.
- A dedicated post-migration pass will handle deployment-size and final gas optimization once flash-loan correctness and safety are stable.

## Refactor Constraints (Critical)
1. Flash-loan path is the only production execution path after this refactor.
2. Do not remove existing guardrails unless there is a concrete incompatibility with flash-loan flow.
3. Prefer wrappers/adapters over rewrites:
   - Keep `attemptAllInternal`, `_runPair`, `findBestPools`, and `executeIterativeArb` logic intact whenever possible.
4. Minimize line churn:
   - Small, targeted edits are preferred over broad restructuring.
5. Preserve behavioral invariants:
   - Pair traversal order and bounded per-attempt retry behavior.
   - Early-stop conditions and bounded loops.
   - Failure isolation (arb failure must not break user swap settlement).
6. Any guardrail removal requires:
   - written rationale,
   - explicit regression tests,
   - and explicit sign-off before merge.

## Target Architecture
1. Hook trigger remains unchanged: `afterSwap` starts attempt cycle.
2. Pair discovery remains unchanged: `findBestPools` and `_runPair` keep selecting candidate pools.
3. Execution funding changes:
   - Replace direct call to `executeIterativeArb` with `executeIterativeArbViaFlash`.
   - `executeIterativeArbViaFlash` requests flash principal in `startToken`.
   - `onFlashLoan` executes existing iterative arb path and repays lender principal + fee.
4. Profit settlement:
   - Net profit is transferred to beneficiary derived from swap context.
   - `FlashLoanSettled` records route details and net profit without permanent trade storage.
5. Failure containment stays the same:
   - Any flash-path failure is isolated by existing self-call boundary.
   - User swap settlement should never be blocked by arbitrage failure.

## Data Model and Config Additions
Add to `ArbHook`:
- `mapping(address => address) public lenderByToken`
- `mapping(address => uint256) public flashPrincipalByToken`
- `mapping(address => uint256) public maxFlashFeeBpsByToken`
- `mapping(address => bool) public trustedFlashLender`
- `address public defaultProfitRecipient` (optional fallback)
- Active callback context fields:
  - `address private _activeProfitRecipient`
  - `address private _activeLoanToken`
  - `uint256 private _activeLoanAmount`
  - `address private _activeLender`
  - `bytes32 private _activeFlashContextHash`

Production telemetry:
- `FlashLoanSettled` is the sole execution event and records the completed
  route, principal, fee, net result, iterations, and beneficiary.
- Expected discovery, route, and lender failures are contained without
  serializing revert bytes into logs.
- Historical inventory telemetry exists only in the legacy test harness.

## Beneficiary Resolution Strategy
Implement deterministic recipient selection in `_afterSwap`:
1. If `hookData` decodes to a non-zero recipient address, use it.
2. Else use `sender` from the hook callback.
3. Else fallback to `defaultProfitRecipient`.

Rules:
- Do not use `tx.origin`.
- If recipient is zero after resolution, do not execute flash arb.
- Emit chosen recipient in logs for observability.

## Implementation Plan (Phased)

### Phase 0: Branching and Baseline
- Create a dedicated flash-loan feature branch (done).
- Record baseline gas and behavior on current tests for before/after comparison.
- If A/B comparison against legacy inventory flow is needed, keep any dual-path toggle in test-only harnesses, not in production `ArbHook`.

### Phase 1: Flash Loan Plumbing
Files:
- `contracts/ArbHook.sol`
- `contracts/interfaces/IERC3156FlashBorrower.sol` (already exists)
- `contracts/interfaces/IERC3156FlashLender.sol` (already exists)

Tasks:
1. Make `ArbHook` implement `IERC3156FlashBorrower`.
2. Add owner-only setters:
   - `setLenderForToken`
   - `setFlashPrincipalForToken`
   - `setMaxFlashFeeBpsForToken`
   - `setDefaultProfitRecipient`
3. Add strict lender/token allowlist checks.
4. Add helper to compute context hash and enforce single active flash context.

Acceptance:
- Flash request cannot be made for unconfigured token/lender.
- Invalid lender callbacks revert.

### Phase 2: Execution Path Swap
Files:
- `contracts/ArbHook.sol`

Tasks:
1. In `_runPair`, replace direct self-call to `executeIterativeArb` with new wrapper:
   - `executeIterativeArbViaFlash(...)`.
2. `executeIterativeArbViaFlash`:
   - Determine principal (`flashPrincipalByToken[tokenA]`), bounded by configurable caps.
   - Pre-check lender availability (`maxFlashLoan`), fee (`flashFee`), and fee limits.
   - Request flash loan with encoded execution params and resolved recipient.
3. In `onFlashLoan`:
   - Validate `msg.sender == configured lender`.
   - Validate `initiator == address(this)`.
   - Validate context hash.
   - Execute iterative arb path.
   - Repay lender (approve or transfer based on lender behavior).
   - Compute and transfer net profit to recipient.
   - Return ERC-3156 selector hash.

Acceptance:
- Pair-level execution succeeds using flash capital with zero prefund requirement.
- Repayment is always completed when callback returns success.

### Phase 3: Accounting and Safety
Files:
- `contracts/ArbHook.sol`

Tasks:
1. Distinguish gross profit vs net profit:
   - `gross = postArbStartBal - preArbStartBal`
   - `net = gross - flashFee` (plus any explicit lender fee token handling rules)
2. Enforce net-positive accounting before payout.
3. Emit route, principal, fee, net profit, iterations, and recipient in the final settlement event.
4. Ensure unwind logic cannot strand non-repayable balances.

Acceptance:
- Every completed callback emits its final net settlement without permanent trade-history writes.
- Recipient balance increases exactly by net profit on success.

### Phase 4: Hook Context and Recipient Routing
Files:
- `contracts/ArbHook.sol`
- `contracts/test/PoolManagerHarness.sol` (if needed to pass hook data in tests)

Tasks:
1. Parse `sender` and `hookData` in `_afterSwap`.
2. Bind resolved recipient into active execution context.
3. Handle router/aggregator call paths where sender is not EOA.

Acceptance:
- Tests cover direct user, router sender, and hookData override scenarios.

### Phase 5: Preserve Reference Sequence as Flash Gate
Files:
- `foundry/test/ArbHookParity.t.sol`
- `foundry/test/ArbHookFlashForkAave.t.sol`
- `README.md`

Tasks:
1. Keep `ArbHookParity.t.sol` as an opt-in inventory-funded baseline that asserts the historical gross-profit values.
2. Run `ArbHookFlashForkAave.t.sol` against the same fixed block, funding setup, pool order, and reference rounds using a real lender adapter.
3. Require the flash fork test to assert every expected buy/sell route and positive net profit after loan fees.
4. Document that exact legacy gross-profit equality is not expected once a lender fee and bounded capacity retry are introduced.

Acceptance:
- Local flash safety suites pass without an RPC.
- The cached fork sequence test is required for release validation.
- Documentation distinguishes inventory gross parity from flash net-profit parity.

### Phase 6: Flash Loan Test Suite (New Primary Gate)
Add tests in `foundry/test/`:
- `ArbHookFlashLoan.t.sol`
- `ArbHookFlashLoanFailure.t.sol`
- `ArbHookRecipientRouting.t.sol`
- `ArbHookFlashFeeAccounting.t.sol`

Test categories:
1. Config/permission tests:
   - onlyOwner setters
   - invalid lender/token configuration reverts
2. Callback auth tests:
   - unauthorized lender callback reverts
   - wrong initiator reverts
   - stale/forged context hash reverts
3. Repayment tests:
   - exact principal+fee repayment
   - fee cap enforcement
4. Profit tests:
   - net-positive payout to recipient
   - net-negative no payout/no storage
5. Failure containment:
   - arb revert inside flash path does not revert user swap path
6. Mixed pool-type regression:
   - V3-V3, V2-V2, V2-V3, V3-V2 still execute via flash path

Acceptance:
- New suite becomes release gate for this repository.

### Phase 7: Rollout and Hardening
1. Pre-enable validation:
   - Run fork tests with conservative per-token principal settings.
   - Run dry-run instrumentation against real pools.
2. Enablement:
   - Deploy with flash-loan path active as the only production path.
3. Operational controls:
   - keep strict lender/token allowlists.
   - tune per-token principal/fee limits conservatively first.

## Risk Register
1. Lender callback model mismatch
- Mitigation: start with one known ERC-3156-compliant lender and strict integration tests.

2. Beneficiary misattribution with routers
- Mitigation: hookData override support + clear integration contract expectations.

3. Profit accounting mismatch (gross vs net)
- Mitigation: explicit dual accounting and assertions in tests.

4. Reentrancy side effects
- Mitigation: context hash/state machine guard; avoid broad guard that breaks swap callbacks.

5. Behavioral drift from current sizing logic due to different principal profile
- Mitigation: fixed per-token principal configs and staged tuning.

6. Guardrail regression from over-refactor
- Mitigation: enforce minimal-diff policy, preserve existing checks by default, and require explicit justification + tests for any removed guardrail.

7. Accidental routing behavior changes
- Mitigation: add invariant tests for traversal order, per-attempt retry behavior, and first-profitable-path stop behavior.

8. Hook gas envelope expansion
- Mitigation: track gas snapshots for `_afterSwap` path and set acceptance ceilings before merge.

9. Integration breakage from interface/event schema drift
- Mitigation: keep existing external function/event signatures stable unless strictly necessary; if a change is required, document it and add migration notes.

10. Reduced debuggability from contained failure surfaces
- Mitigation: assert observable behavior in local tests, use fixed-block
  simulation and traces during canary diagnosis, and keep successful economic
  accounting in `FlashLoanSettled`.

11. Operational rollback risk
- Mitigation: keep owner controls for lender allowlist and principal limits so exposure can be reduced immediately without redeploying logic.

## Deliverables
1. Flash-loan-enabled `ArbHook` with strict callback validation.
2. Recipient payout mechanism for net profits.
3. Updated docs and test strategy with a required flash route-sequence gate.
4. New flash-loan test suite passing on fork and local harnesses.

## Deferred Correctness Work
- V2/V2 and mixed V2/V3 routes still need route-specific pre-loan principal tests. The initial V3/V3 canary uses the existing V3 liquidity-derived sizing path.
- `_MAX_IMPACT_BPS` is enforced on the mixed V2-to-V3 guard but is not yet applied as a hard cap inside the V3/V3 sizing path. Any change must run through the fixed ten-round fork gate.
- Profit-recipient behavior still needs an integration test through the intended production V4 router and its `hookData` encoding.
- Moving execution into a separate engine is deferred. It would add synchronization and deployment surface during the canary and should be evaluated as part of the dedicated EIP-170 size pass.

## Definition of Done
- Contract can execute arb without prefunded principal inventory.
- Successful flow always repays principal + fee atomically.
- Net profits are transferred to resolved swap beneficiary.
- Unauthorized flash callbacks are rejected.
- Flash-loan test suite is green and designated as release gate.
- Cached fork sequence test preserves all reference routes and positive net settlement.
- README and test docs distinguish inventory gross parity from flash net-profit parity.
