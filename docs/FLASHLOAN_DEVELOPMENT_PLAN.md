# Flash Loan Migration Plan

## Goal
Migrate `ArbHook` from inventory-funded arbitrage to flash-loan-funded arbitrage, so the hook does not need to hold principal inventory and net profits are paid to the swap initiator (or an explicit beneficiary).

## Context
- Current execution is hook-triggered and best-effort via `_afterSwap -> _attemptAllViaSelfCall -> attemptAllInternal -> _runPair -> executeIterativeArb`.
- Current implementation uses contract balances as principal in iterative sizing and callback repayment logic.
- Existing parity tests target a legacy non-hook implementation and should no longer gate shipping once flash-loan mode becomes the primary execution model.

## Scope
- Add a production-capable flash-loan execution path (initially ERC-3156 lenders).
- Preserve current route discovery and sizing logic where possible.
- Add deterministic beneficiary payout logic.
- Deprecate parity test as a release gate and replace with flash-loan-focused correctness/safety tests.

## Non-Goals (for this phase)
- Full optimal on-chain sizing solver for concentrated liquidity.
- Multi-lender auctioning/routing.
- Automatic dynamic principal optimization beyond guardrailed heuristics.
- Backward compatibility guarantees for exact parity sequence/profits.
- Solving contract-size deployability limits (EIP-170/24KB) in this migration pass.

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
   - Pair traversal order and cache behavior.
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
   - Trade storage/event data stores net profit (or both gross/net explicitly).
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

Add/adjust events:
- `FlashLoanRequested(token, lender, amount, recipient)`
- `FlashLoanSettled(token, lender, amount, fee, netProfit, recipient)`
- `FlashLoanFailed(token, lender, amount, reason)`
- Update `ArbitrageAttempted` docs to clarify gross vs net accounting.

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
- Create feature branch: `codex/flashloan-dev-plan` (done).
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
- `contracts/DataStorage.sol` (if schema changes)
- `contracts/interfaces/IDataStorage.sol` (if schema changes)

Tasks:
1. Distinguish gross profit vs net profit:
   - `gross = postArbStartBal - preArbStartBal`
   - `net = gross - flashFee` (plus any explicit lender fee token handling rules)
2. Enforce net-positive threshold before payout and trade persistence.
3. Update event/store semantics:
   - Either store net only, or store both `grossProfit` and `netProfit`.
4. Ensure unwind logic cannot strand non-repayable balances.

Acceptance:
- No profitable event/storage emission on net-negative outcomes.
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

### Phase 5: Deprecate Parity as Gate
Files:
- `foundry/test/ArbHookParity.t.sol`
- `README.md`
- Optional: `foundry/test/legacy/ArbHookParity.t.sol` (move)

Tasks:
1. Mark parity test as legacy/non-gating.
2. Optionally move parity test file under a legacy folder and run only when explicitly targeted.
3. Update README testing guidance:
   - Primary gates are flash-loan safety and correctness tests.
   - Legacy parity available for historical diagnostics only.

Acceptance:
- Default `forge test` does not fail release flow due to parity drift.
- Documentation clearly reflects new source of truth.

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
- Mitigation: add invariant tests for traversal order, cache skip behavior, and first-profitable-path stop behavior.

8. Hook gas envelope expansion
- Mitigation: track gas snapshots for `_afterSwap` path and set acceptance ceilings before merge.

9. Integration breakage from interface/event schema drift
- Mitigation: keep existing external function/event signatures stable unless strictly necessary; if a change is required, document it and add migration notes.

10. Reduced debuggability from changed failure surfaces
- Mitigation: keep structured failure events (`AttemptAllFailed`, pair failure, flash failure) and add explicit reason tagging for flash callback failures.

11. Operational rollback risk
- Mitigation: keep owner controls for lender allowlist and principal limits so exposure can be reduced immediately without redeploying logic.

## Deliverables
1. Flash-loan-enabled `ArbHook` with strict callback validation.
2. Recipient payout mechanism for net profits.
3. Updated docs and test strategy (parity deprecated as non-gating).
4. New flash-loan test suite passing on fork and local harnesses.

## Definition of Done
- Contract can execute arb without prefunded principal inventory.
- Successful flow always repays principal + fee atomically.
- Net profits are transferred to resolved swap beneficiary.
- Unauthorized flash callbacks are rejected.
- Flash-loan test suite is green and designated as release gate.
- README and test docs reflect parity deprecation and new validation approach.
