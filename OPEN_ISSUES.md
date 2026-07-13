# Audit Remediation Status

Last updated: 2026-07-13

The deployability and execution-safety findings recorded for this repository are
resolved in the current branch.

## Resolved

1. **EIP-170 deployment limit — resolved**
   - `ArbHook` is now a thin V4 shell and delegatecalls immutable
     `ArbExecutor` code with an identical leading storage layout.
   - Current optimized runtime sizes: `ArbHook` 14,301 B, `ArbExecutor`
     15,872 B, `ArbitrageLogic` 20,773 B, and `ArbMath` 9,117 B. CI and
     deployment tests enforce the limit for every deployable core component.
   - Deployment tests enforce the 24,576-byte limit for every deployed core
     component.

2. **Forged V2/Pancake V2 callbacks — resolved**
   - Callbacks require a trusted-factory pair, matching registered metadata,
     `sender == address(this)`, and an exact one-shot flash-swap context.
   - The context is consumed before any token transfer.

3. **Partial arbitrage execution / treasury residue — resolved**
   - Failed legs and non-positive final P&L revert the isolated self-call.
   - Residual cleanup is based on entry-balance snapshots and cannot liquidate
     pre-existing intermediate-token inventory.

4. **Price and sizing math — resolved**
   - V2/V3 prices use whole-token decimal orientation and fail closed for
     unsupported decimal exponents or overflowing quote paths.
   - Buy prices round up for fees; V3 sizing accounts for both-leg fees and
     initialized-tick capacity. Coarse nearest-range impact is diagnostic,
     while execution price limits and realized P&L remain authoritative.
   - Pancake V3 uses its own `slot0` ABI wherever the `uint32 feeProtocol`
     field matters.

5. **Pool discovery and lifecycle safety — resolved**
   - Discovery ranks quote-valid pool pairs without rejecting routes that cross
     an initialized tick; sizing and execution apply the directional liquidity,
     spread, impact, and profit guards against live state.
   - Failure-cache entries never use the ambiguous `(0,0)` quantized-price
     default, so valid low-price token pairs are still attempted.
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

7. **Build and supply-chain reproducibility — resolved**
   - Solidity is pinned to 0.8.26, npm dependencies are exact/locked, the stale
     submodule lock metadata was removed, and `npm audit --omit=dev` reports no
     vulnerabilities.
   - CI runs `npm ci`, size checks, and the deterministic Forge suite.

8. **Deployment workflow — resolved**
   - `script/DeployArbHook.s.sol` deploys logic/storage/executor, mines the
     exact five-argument hook address through Foundry's CREATE2 factory, checks
     the prediction, and authorizes the hook as `DataStorage` writer.
   - The documented `forge script` flow also automatically deploys and links
     `ArbMath`; a local dry-run produces the expected six-transaction plan.

9. **Fork parity and fixture fidelity — resolved**
   - The parity fixture registers only the reference USDC-base pool sequence,
     avoids the WETH-as-tokenA decimal-underflow path, and funds inventory with
     the same two WETH-to-USDC swaps as the JS harness.
   - The ten-round fork test asserts every buy/sell pool and raw profit, totaling
     exactly 18,679,602 USDC base units (18.679602 USDC).

## Operational validation

The fork-parity suite remains intentionally RPC-dependent. It runs automatically
when `BASE_RPC_URL` is provided and skips in offline CI; use an archive-capable
Base endpoint to verify the ten-round golden output before a production release.
