# Audit Remediation Status

Last updated: 2026-07-14

The deployability and execution-safety findings recorded for this repository are
resolved in the current branch.

## Resolved

1. **EIP-170 deployment limit — resolved**
   - `ArbHook` is now a thin V4 shell and delegatecalls immutable
     `ArbExecutor` code with an identical leading storage layout.
   - Current optimized runtime sizes: `ArbHook` 15,258 B, `ArbExecutor`
     14,381 B, `ArbitrageLogic` 22,627 B, and `ArbMath` 12,159 B.
   - CI size checks cover every deployable component, while deployment tests
     enforce the 24,576-byte runtime limit for the hook, executor, and logic.

2. **Forged swap callbacks — resolved**
   - V2 callbacks require a trusted-factory pair, matching registered metadata,
     `sender == address(this)`, and an exact one-shot flash-swap context.
   - V3 registration accepts only the canonical Base Uniswap or Pancake factory
     pool. Its one-shot capability binds the pool family and callback selector,
     input token, direction, and maximum debit.
   - Every callback capability is consumed before any token transfer, preventing
     unsolicited calls, replay, cross-family use, and reentrant reuse.

3. **Atomic flash settlement / treasury residue — resolved**
   - A nonzero owner-set `maxFlashTradeAmount` enables pool-native flash
     settlement per start token; the cap controls sizing and is not deposited
     into the hook. A zero cap preserves the legacy treasury-funded path.
   - The first pool fronts the intermediate token, the second leg executes
     inside its callback, and the second leg's output repays the first pool
     atomically. Failed legs and non-positive final P&L revert the isolated
     self-call without consuming pre-existing hook balances.
   - Successful flash-settled trades forward realized start-token profit to the
     hook owner. Entry-balance invariants prevent working inventory or residue
     from accumulating at the hook address.

4. **Price and sizing math — resolved**
   - V2/V3 prices use whole-token decimal orientation, preserve normalized
     precision below one raw output unit, and fail closed for unsupported
     decimal exponents or overflowing quote paths.
   - Buy prices round up for fees; V3 sizing validates both-leg fees and crosses
     an initialized current-tick boundary before measuring usable capacity.
   - V3 impact is actual tick- and fee-aware price movement. The configured cap
     constrains both execution legs and residual unwinds, with amount-specific
     price limits instead of a fixed tolerance.
   - Quantized prices saturate at `uint128.max` instead of wrapping.
   - Pancake V3 uses its own `slot0` ABI wherever the `uint32 feeProtocol`
     field matters.

5. **Pool discovery and lifecycle safety — resolved**
   - Discovery ranks quote-valid pool pairs without rejecting routes that cross
     an initialized tick; sizing and execution apply the directional liquidity,
     spread, impact, and profit guards against live state.
   - Price-only failures are not persisted across callbacks because balances,
     approvals, liquidity, and policy can change without a price move. Bounded
     invocation-local retries bind their dedupe key to the exact buy/sell pools,
     rotate away from a reverting route immediately, and can try same-price alternatives.
   - Empty registrations do not create ghost base tokens. Removing pools prunes
     orphan counters while preserving base/counter/pool insertion order, and a
     counter remains live until its final matching pool is removed.
   - Pool metadata survives dual-base registration until the final registration
     is removed.
   - Stale trade data is cleared before a scan and only persisted when the
     configured profit threshold is met.

6. **V4 production integration — resolved**
   - Production hooks retain BaseHook address validation and must be mined for
     `AFTER_SWAP_FLAG`; the test harness is the only validation bypass.
   - An owner-managed V4 pool-key allowlist makes unlisted `afterSwap` calls
     no-ops, and callback iterations are capped at 10.
   - A real `PoolManager` integration test covers initialization, liquidity,
     an unlisted swap, and an allowlisted swap.
   - V4 is the trigger integration, not an external arbitrage leg. Executable
     external pools are currently limited to Uniswap V2/V3 and PancakeSwap
     V2/V3; Aerodrome and V4-router interfaces remain unused scaffolding.

7. **Build and supply-chain reproducibility — resolved**
   - Solidity is pinned to 0.8.26, npm dependencies are exact/locked, the stale
     submodule lock metadata was removed, and `npm audit --omit=dev` reports no
     vulnerabilities.
   - CI actions are pinned to full commit SHAs, Node and Foundry are pinned to
     exact releases, and CI runs `npm ci`, a production dependency audit, size
     checks, and the deterministic Forge suite.
   - The RPC-dependent parity contract is excluded explicitly from the
     deterministic job. A separate job runs on every push, pull request, and
     manual invocation, prefers the protected `BASE_RPC_URL` secret, uses the
     public Base endpoint when secrets are unavailable, and enforces all ten
     golden rounds instead of passing on skipped tests.

8. **Deployment workflow — resolved**
   - `script/DeployArbHook.s.sol` deploys logic/storage/executor, mines the
     exact five-argument hook address through Foundry's CREATE2 factory, checks
     the prediction, and authorizes the hook as `DataStorage` writer.
   - On Base, the script requires the canonical PoolManager address and runtime
     code hash. Non-Base local/test managers require an explicit opt-in that
     cannot bypass the Base checks.
   - The documented `forge script` flow also automatically deploys and links
     `ArbMath`. The broadcaster performs initial wiring, then optionally hands
     ownership of both `ArbHook` and `DataStorage` to `ARB_HOOK_OWNER`.
   - Deployment uses multiple independent transactions. There is no aggregate
     on-chain deployment event or cross-transaction rollback; operators must
     verify the Foundry broadcast artifact, receipts, ownership, writer, and
     immutable manager before registering pools and setting per-token flash
     trade caps.

9. **Fork parity and fixture fidelity — resolved**
   - The parity fixture registers only the reference USDC-base pool sequence,
     avoids the WETH-as-tokenA decimal-underflow path, and retains the same two
     WETH-to-USDC market-shaping swaps as the JS harness. The resulting USDC is
     not deposited into the hook; a 100,000 USDC flash-trade cap reproduces the
     reference sizing while the hook begins and ends without working inventory.
   - The ten-round fork test asserts every buy/sell pool and raw profit, totaling
     exactly 18,679,602 USDC base units (18.679602 USDC).

## Operational validation

The fork-parity suite remains RPC-dependent. CI does not count parity skips as
validation: a dedicated job runs the exact ten-round assertions on every event,
using the protected `BASE_RPC_URL` secret when configured and Base's public
endpoint as the fallback. Failure to reach a valid Base archive endpoint fails
the job and blocks validation.
