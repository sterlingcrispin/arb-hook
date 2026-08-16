# Flash Loan Migration Plan

Status: implemented and extended. This file records the inventory-to-flash
migration and the later replacement of a temporary one-round self-pool route
with repeated live-repriced self-pool execution. Current architecture is
described in `README.md` and `docs/ARB_LOGIC_DEEP_DIVE.md`.

## Goal
Migrate `ArbHook` from inventory-funded arbitrage to flash-loan-funded arbitrage
without deleting its route traversal, sizing, or guardrails. The hook does not
need to hold principal inventory. Realized profit remains in the hook for the
current owner to withdraw.

## Context
- Production execution is hook-triggered via `afterSwap -> attemptTriggerPoolInternal -> onFlashLoan -> V4ArbExecutor`.
- The triggering v4 pool is the first arbitrage leg; one registered V3-compatible pool for the same pair is the return leg.
- `V4ArbExecutor` recomputes a bounded chunk from live state on every round while one flash loan remains active.
- The external pool scanner and its V2/V3/mixed iterative executor remain intact for historical parity and research, but production `afterSwap` does not call them.
- `ArbHookHarness` exposes the prefunded branch needed to reproduce the historical inventory oracle.
- The pre-migration implementation used contract balances as principal in iterative sizing and callback repayment logic.
- The legacy inventory parity suite is the historical gross-profit baseline. The flash fork suite must preserve its natural per-round route sequence while remaining net-positive after lender fees.

## Canary Threat Model
- The owner/operator is trusted and registers a small set of pre-verified, canonical Base tokens, pools, and lender contracts.
- Permissionless pool or token registration is not supported.
- Protecting the owner from intentionally or accidentally registering a malicious token or fake pool is not part of the initial canary.
- The curated pool book is append-only; a bad registration requires a fresh deployment before traffic is routed through the hook.
- External callers, forged callbacks, incorrect flash-loan context, repayment failure, and profit accounting remain untrusted runtime boundaries.
- The fixed canary registration script attests its V3 factories and pool metadata before broadcast. Generic onchain factory enforcement and arbitrary registry-scale limits remain deferred unless the operating model changes.

## Scope
- Add a production-capable flash-loan execution path (initially ERC-3156 lenders).
- Preserve current route discovery and sizing logic where possible.
- Retain realized profit for current-owner withdrawal.
- Keep a flash-loan fork regression gate alongside local correctness and safety tests.

## Non-Goals (for this phase)
- Multi-lender auctioning/routing.
- Full optimal on-chain sizing solver or tick-by-tick simulation.
- Exact legacy gross-profit equality after lender fees. The required compatibility target is route sequence plus positive net settlement.
- A permissionless or adversarial asset registry.

## Deployment Size
- `npm run size` reports production runtime sizes and enforces the repository budget.
- `ArbHook` is 23,644 runtime bytes: 932 bytes below EIP-170 and 356 bytes below the repository's 24,000-byte budget.
- The immutable delegate-called `V4ArbExecutor` is 5,624 runtime bytes. Its separation preserves both the production loop and the legacy route engine without making the hook undeployable.
- Size reduction remains separate from flash-loan correctness and parity work; do not remove route behavior merely to satisfy an interim development budget.

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
1. `afterSwap` selects the hook as profit recipient and dispatches the triggering-pool attempt behind a gas-bounded failure boundary.
2. Direction comes from the triggering swap: borrow the token the user bought and sell it back into v4.
3. Reference discovery selects the cheapest fee-adjusted registered V3-compatible venue for that exact pair and direction.
4. Existing concentrated-liquidity math derives a bounded flash principal from live spread, active liquidity, price limits, and configured caps.
5. The loan callback repeatedly recomputes and executes v4-to-V3 rounds up to `hookMaxIterations`.
6. Realized balance checks remain authoritative; exact intermediate restoration, retained net profit, and repayment are atomic.

## Iterative Self-Pool Extension

The first self-pool prototype hardcoded one V4/V3 round. A live canary proved
that this left a large gap for the next external backrunner. Commit `d78c3f3`
replaced that stopgap with a bounded loop while preserving the original engines:

1. Select the reference and derive one flash principal before borrowing.
2. Borrow once.
3. Before every round, reread v4 and reference ticks, fees, and active liquidity.
4. Recompute directional edge, adaptive movement, both price limits, and the
   smaller venue capacity.
5. Execute v4 exact input, settle its deltas, execute the complete intermediate
   output through V3, and measure actual marginal start-token profit.
6. Repeat while profitable and below `hookMaxIterations`; then require exact
   residue restoration and settle the loan.

The fixed Base-block comparison for the same 50 USDC trigger improved from one
round and `0.000012668624087717 WETH` to ten rounds and
`0.000053328188113127 WETH`, while reducing the residual gap from 54 to 18
ticks. This is bounded convergence, not a claim of an exact tick-level optimum.

## Data Model and Config Additions
Implemented in `ArbHook`:
- Internal lender, principal-cap, max-fee, and minimum-net-profit state.
- `getFlashConfig(token)` and `getExecutionConfig()` provide consolidated operator inspection without separate autogenerated getters for every storage field.
- Active lender, loan, recipient, result, and swap-callback context held in
  EIP-1153 transient slots because it is valid for one transaction only.

Production telemetry:
- `FlashLoanSettled` is the sole execution event and records the completed
  route, principal, fee, net result, iterations, and recipient. The historical
  ABI field name is `beneficiary`; production always records the hook address.
- Expected discovery, route, and lender failures are contained without
  serializing revert bytes into logs.
- Historical inventory telemetry exists only in the legacy test harness.

## Profit Retention Strategy
Production `afterSwap` always selects `address(this)` as the recipient. Router
identity and `hookData` cannot redirect revenue or suppress execution. The
current owner withdraws accumulated profit with `removeTokens`; protected-balance
sizing prevents retained revenue from increasing later flash trade size.

## Historical Implementation Plan (Phased)

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
   - `setMinNetProfitForToken`
3. Bind each token to one owner-configured lender and reject callbacks that do
   not match the active lender, token, amount, initiator, and context.
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
   - Request flash loan with encoded execution params and active recipient context.
3. In `onFlashLoan`:
   - Validate `msg.sender == configured lender`.
   - Validate `initiator == address(this)`.
   - Validate context hash.
   - Execute iterative arb path.
   - Repay lender (approve or transfer based on lender behavior).
   - Compute net profit and retain it when the hook is the production recipient.
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
2. Require the configured minimum net profit before settlement; below-floor loans revert atomically.
3. Emit route, principal, fee, net profit, iterations, and recipient in the final settlement event.
4. Ensure unwind logic cannot strand non-repayable balances.

Acceptance:
- Every completed callback emits its final net settlement without permanent trade-history writes.
- Production success increases the hook's start-token balance exactly by net profit.

### Phase 4: Hook Context and Recipient Routing (Superseded)
Files:
- `contracts/ArbHook.sol`
- `contracts/test/PoolManagerHarness.sol` (if needed to pass hook data in tests)

Tasks:
1. Resolve empty `hookData` through the router's `IMsgSender` interface or parse an exact packed recipient in `afterSwap`.
2. Bind resolved recipient into active execution context.
3. Skip execution only for malformed nonempty data or a packed zero address.

Acceptance:
- Historical tests covered valid packed data and safe handling of missing or malformed data. Production now ignores both sender and hook data and retains profit.

### Phase 5: Preserve Reference Sequence as Flash Gate
Files:
- `foundry/test/ArbHookParity.t.sol`
- `foundry/test/ArbHookFlashForkAave.t.sol`
- `README.md`

Tasks:
1. Keep `ArbHookParity.t.sol` as an opt-in inventory-funded baseline that asserts the historical gross-profit values.
2. Run `ArbHookFlashForkAave.t.sol` against the same fixed block, funding setup,
   pool order, and reference rounds using the intended Morpho adapter; retain the
   Aave sequence as a fee-bearing comparison.
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
- production callback revenue-retention coverage
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
   - net-positive retention in the production hook
   - net-negative no settlement/no storage
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
   - keep one explicit lender binding and conservative principal/fee limits per token.
   - tune per-token principal/fee limits conservatively first.

## Risk Register
1. Lender callback model mismatch
- Mitigation: start with one known ERC-3156-compliant lender and strict integration tests.

2. Profit redirection through routers
- Mitigation: production ignores router identity and hook data and retains profit in the hook for current-owner withdrawal.

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
- Mitigation: track gas snapshots for the `afterSwap` path and set acceptance ceilings before merge.

9. Integration breakage from interface/event schema drift
- Mitigation: keep existing external function/event signatures stable unless strictly necessary; if a change is required, document it and add migration notes.

10. Reduced debuggability from contained failure surfaces
- Mitigation: assert observable behavior in local tests, use fixed-block
  simulation and traces during canary diagnosis, and keep successful economic
  accounting in `FlashLoanSettled`.

11. Operational rollback risk
- Mitigation: keep owner controls for each token's lender binding and principal
  limit so exposure can be reduced immediately without redeploying logic.

## Deliverables
1. Flash-loan-enabled `ArbHook` with strict callback validation.
2. Owner-withdrawable retention of net profits.
3. Updated docs and test strategy with a required flash route-sequence gate.
4. New flash-loan test suite passing on fork and local harnesses.

## Deferred Correctness Work
- V3/V3, V2/V2, and both mixed route directions reuse their existing sizing
  logic before borrowing and have real Base fork coverage. The ten-round default
  gate uses Morpho; Aave remains covered as a fee-bearing comparison.
- Further executor decomposition is deferred. The current immutable
  `V4ArbExecutor` contains the self-pool loop and delegate-calls in hook context;
  moving callback-sensitive legacy execution requires more complexity than the
  remaining size benefit justifies.

## Definition of Done
- Contract can execute arb without prefunded principal inventory.
- Successful flow always repays principal + fee atomically.
- Production net profits remain in the hook for current-owner withdrawal.
- Unauthorized flash callbacks are rejected.
- Flash-loan test suite is green and designated as release gate.
- Cached fork sequence test preserves all reference routes and positive net settlement.
- Fixed-block self-pool test proves multiple live-repriced rounds outperform the
  one-round baseline with exact repayment and exact retained owner revenue.
- README and test docs distinguish inventory gross parity from flash net-profit parity.
