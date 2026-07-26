## Arb Hook

A Uniswap v4 hook-driven arbitrage system that checks for opportunities during swaps, without relying on always-on off-chain scanners or mempool racing.

On L2's where gas is cheap this may be economically viable. When a user attempts a swap, we piggyback some logic to search for arbs and close them as we can.

Either an opportunity already exists, or the swap creates one. Either way, the hook gets a guaranteed execution point with fresh prices and known state, and uses that moment to see if a profitable, safe arb is possible.

If yes, it executes atomically inside the same transaction. If not, it does nothing and the swap proceeds normally.

## Big Picture

Instead of constantly scanning markets or competing in gas wars, we wait for real trades to happen and then ask:

“Given the current pool state and prices elsewhere, is there a clean arbitrage worth doing right now?”

Most of the time the answer is no, and the hook exits almost immediately. When the answer is yes, the hook can act instantly, without latency or MEV competition.

The hook doesn't assume the arbitrage leg happens on another Uniswap v4 pool. Today the implemented external pool types are Uniswap V2/V3 and PancakeSwap V2/V3, so the v4 hook is acting as an observation point for broader cross-venue price discovery.

The production execution path is flash-loan-funded for principal, so the hook does not need to hold full trading inventory. External pool repayment is made directly from authenticated swap callbacks; no standing pool allowance is required. A loan is attempted only when the token has a configured lender plus a non-zero principal cap, fee cap, and minimum net profit.

There is still required operator setup off-chain: pool registration, lender configuration, and runtime-parameter configuration (`hookMaxIterations`, `minSpreadBps`, `chunkSpreadConsumptionBps`, `maxImpactBps`). Hook execution is disabled by default (`hookMaxIterations = 0`). The Aave V3 integration uses the production adapter in `contracts/AaveV3ERC3156Adapter.sol`, with one configured reserve per adapter deployment.

## Canary Threat Model

The initial canary is owner-operated and targets a small, explicitly curated set of canonical Base tokens, pools, and lender contracts. Pool registration is not permissionless. The canary assumes the operator has verified those addresses and does not spend runtime gas trying to protect the owner from deliberately registering a malicious token or fake pool.

The canary pool book is append-only. If registration is wrong, deploy a fresh hook before routing traffic instead of mutating a live registry and risking traversal-order or shared-metadata corruption.

Runtime safety still treats external callers and callbacks as untrusted. Flash callbacks must come from the active trusted lender, swap callbacks must match the active registered route, repayment remains atomic, and an arbitrage failure must be contained from the triggering user swap.

Factory attestation for owner-supplied V3 pools and arbitrary registry-scale hardening are deferred because they do not address the initial deployment model. Economic correctness, route selection, fee accounting, and recipient routing remain in scope.

## Flash Migration Checklist

- Keep changes minimal and localized; avoid broad rewrites.
- Preserve existing guardrails unless there is a concrete flash-loan incompatibility.
- Keep route traversal/order behavior stable (`supportedTokens`, `baseCounterList`, and per-attempt retry order).
- Preserve bounded loop and early-stop behavior in iterative execution.
- Maintain failure isolation: arb failures must not break user swap settlement.
- Preserve the legacy reference route sequence in the flash fork regression test.
- Keep size reductions behavior-preserving and enforce the runtime-byte budget.

## Primary Test Gate

Run the fast flash safety suites and the fixed-block flash sequence gate:

```bash
forge test
```

```bash
BASE_RPC_URL="$BASE_RPC_URL" scripts/test_flash_fork_cached.sh
```

```bash
npm run size
```

The cached fork gate replays the ten rounds from `ParityTest/attemptAllOutput.txt` with a real Aave-backed ERC-3156 adapter. It requires the same buy/sell route in every round and positive net profit after the loan fee. It does not require legacy gross-profit equality because the flash fee and a bounded capacity refinement can change trade size and net result.

The size gate caps each production runtime at 24,000 bytes, leaving at least 576 bytes below EIP-170's 24,576-byte limit. It currently covers `ArbHook`, `ArbitrageLogic`, and `AaveV3ERC3156Adapter`.

`FlashLoanSettled` is the canonical execution record. It reports the lender, tokens, selected pools, borrowed principal, total input swapped, fee, net profit, iterations, and beneficiary without adding permanent per-trade storage writes to the hook.

The swap router must pass the beneficiary as exactly 20 packed address bytes (`abi.encodePacked(beneficiary)`) in v4 `hookData`. Missing, malformed, or zero-address data disables the arb attempt for that swap. The hook does not fall back to the router or `tx.origin`.

`ArbHook` uses Uniswap v4's normal hook-address validation. A production deployment must therefore use CREATE2 to mine an address whose permission bits specify `afterSwap` only. The arbitrary-address validation bypass exists only in `contracts/test/ArbHookHarness.sol`.

## Base Deployment

`script/DeployArbHook.s.sol` deploys `ArbitrageLogic`, the USDC Aave adapter,
and an after-swap-only hook mined against Base's canonical CREATE2 deployer.
The complete release, configuration, canary, and shutdown procedure is in
[`docs/MAINNET_CANARY_RUNBOOK.md`](docs/MAINNET_CANARY_RUNBOOK.md).
Simulate first:

```bash
PRIVATE_KEY="$PRIVATE_KEY" forge script \
  script/DeployArbHook.s.sol:DeployArbHook \
  --rpc-url "$BASE_RPC_URL"
```

Add `--broadcast` only after reviewing the simulation. The optional `OWNER`
environment variable defaults to the key's address. The script intentionally does not
register pools, configure lender limits, or enable callback
iterations; those owner actions must be reviewed separately after deployment.

## Cached Fork Workflow (Fast Re-runs)

Fork-level tests are RPC-heavy on the first run because missing state is fetched lazily.
To speed up repeated runs at the same fork block (`33942262`), use cached Anvil:

```bash
# Terminal 1: start a cached local Base fork
BASE_RPC_URL="$BASE_RPC_URL" npm run anvil:base:cached
```

```bash
# Terminal 2: run flash fork tests against local cached Anvil
BASE_RPC_URL="$BASE_RPC_URL" npm run test:flash:fork:cached
```

`test:flash:fork:cached` defaults to:
- `ArbHookFlashForkAaveTest`
- `testForkAaveAttemptAllTracksLegacyRoundSequenceFull`

You can pass any other forge test args:

```bash
BASE_RPC_URL="$BASE_RPC_URL" scripts/test_flash_fork_cached.sh --match-contract ArbHookFlashForkAaveTest -vv
```

Local cache/state artifacts are ignored by git (`.anvil-cache/`, `.anvil-state/`).

## Runtime Parameters Explained

The main runtime knobs are owner-settable on `ArbHook`:

- `setHookMaxIterations(uint256)`  
  Limits how many iterative chunks can execute in one trigger.
  Higher values can capture more residual spread, but increase gas and can over-trade into diminishing returns.
  Lower values are safer/cheaper but may leave profit on the table.

- `setMinSpreadBps(uint16)`  
  Minimum spread threshold required before execution continues.
  This acts as a noise filter so tiny spreads (often eaten by fees/rounding/impact) are skipped.

- `setChunkSpreadConsumptionBps(uint16)`  
  Controls chunk aggressiveness: how much spread each iteration tries to consume.
  Higher values are more aggressive (fewer, larger chunks; more impact risk).
  Lower values are more conservative (more, smaller chunks; less impact risk).

- `setMaxImpactBps(uint256)`  
  Caps each V3/V3 leg's adaptive tick movement before the pool-enforced
  `sqrtPriceLimit` is derived. Mixed V2-to-V3 routes use the same value as an
  estimated-impact rejection threshold.

The per-token flash controls are:

- `setFlashPrincipalForToken(address,uint256)`
  Sets the maximum amount that adaptive sizing may borrow. Zero disables borrowing; it never means "use all lender liquidity."

- `setMaxFlashFeeBpsForToken(address,uint256)`
  Sets the maximum lender fee relative to principal. Zero disables borrowing. Both the quote and actual callback fee are checked with ceiling rounding.

- `setMinNetProfitForToken(address,uint256)`
  Sets the minimum profit after the flash fee, in raw units of the borrowed token. Zero disables borrowing. V3/V3 and V2/V2 routes reject an obviously insufficient opportunity before borrowing by reusing their existing sizing estimates, and the realized result is checked again during repayment.

### Reference Sequence Profile

In the legacy parity harness (`foundry/test/ArbHookParity.t.sol`), the runtime profile is:

- `hookMaxIterations = 2`
- `minSpreadBps = 10`
- `chunkSpreadConsumptionBps = 1500`
- `maxImpactBps = 500`
- `flashPrincipal cap = 100,000 USDC`
- `maxFlashFeeBps = 100`
- `minNetProfit = 1` raw USDC unit

Why these values are used for parity:

- `2` iterations keeps execution bounded while still allowing a follow-up chunk after the first fill.
- `10 bps` filters micro-spreads that are usually not robust after execution costs.
- `1500` gives a moderate first-step aggressiveness instead of over-consuming spread immediately.
- `500` caps adaptive V3 price-limit movement at 500 ticks (approximately 5%)
  and rejects mixed routes whose estimated V3 impact exceeds 500 bps.
- The `100,000 USDC` value is a ceiling, not the amount borrowed. Existing route math derives each round's principal below that ceiling.
- The `100 bps` fee cap is deliberately above Aave's 5 bps test-block premium and catches unexpected lender changes.
- The `1` raw-unit profit floor keeps every historically profitable round observable, including very small rounds. It is a regression-test value, not a production recommendation; a canary floor should cover expected transaction cost and desired margin.

`ArbHookParity.t.sol` remains an opt-in inventory-funded baseline that asserts the original gross-profit values exactly. To run it intentionally:
- Set `RUN_LEGACY_INVENTORY_PARITY=true`
- Set `BASE_RPC_URL`

`ArbHookFlashForkAave.t.sol` uses the same fixed block, funding setup, pool registration order, and ten-round route sequence with borrowed USDC. It asserts each route and positive net profit after the Aave fee.


## How an Arbitrage Actually Happens (Step by Step)

1. A user submits a swap to a Uniswap v4 pool that has this hook enabled.

2. During the swap, the hook is invoked with visibility into the pool's updated state.

3. The hook calls into `ArbitrageLogic` to evaluate:
   - Is this pool currently out of parity relative to other venues?
   - Does an executable arbitrage path exist right now?
   - Is there enough liquidity to do it without self-destructing on price impact?

4. If any check fails, the hook exits immediately. No side effects.

5. If a viable arb exists, the system:
   - Chooses direction
   - Searches for a safe trade size
   - Accounts for fees, slippage, rounding, and impact
   - Avoids naive “max size” execution

6. The arbitrage is executed via a self-call pattern:
   - Failures are expected and isolated
   - Reverts do not affect the user’s swap
   - State remains clean

7. If the arb clears profit after costs, it commits.
   If not, it reverts internally and becomes a no-op.

8. The user’s swap completes regardless.

## Why This Design 

- Hook-based instead of off chain bots  
  Because hooks remove latency, gas wars, and mempool uncertainty entirely. And I thought it would be cool to do this all onchain.

- Swaps as observation points, not causes  
  The system doesn’t care why an arb exists, only whether it exists at the moment of execution.

- Opportunistic, not always-on  
  No background scanning, no constant gas spend. The logic only runs when there’s a real trade.

- Chunked sizing over brute force  
  Large arbs often lose money due to impact. This code searches for a profitable size instead of assuming one. 

- Chunked sizing over “solve the optimum”  
  Because this is all on chain you can’t cheaply compute the real optimal trade size for concentrated liquidity because the price curve changes at every tick/liquidity boundary. Exact sizing would require expensive tick-by-tick simulation. So instead this system sizes the arb iteratively in bounded chunks and stops when marginal profit flips negative.

- Self-call execution  
  Arbitrage is treated as speculative and allowed to fail safely without polluting hook state, so the users swap will succeed even if our arb fails.

- Flash safety as the current invariant  
  Primary gating focuses on flash-loan callback safety, repayment correctness, and net-profit payout behavior.

## Parity Test Context

The parity suite in `foundry/test/ArbHookParity.t.sol` is a regression target against a **previous non-hook arbitrage implementation**, not a comparison between two hook designs. It also represents a legacy inventory-funded flow.

The expected behavior is defined by the legacy reference artifacts in `ParityTest/`:
- `ParityTest/ArbLightweight.sol` (original non-hook contract)
- `ParityTest/ArbLightweight.attemptAll.js` (legacy harness logic)
- `ParityTest/attemptAllOutput.txt` (golden per-round pool/profit sequence)

Legacy comments that referred to a "worker bot" or "worker deployment" were describing that earlier non-hook implementation.

The inventory parity test confirms the historical gross-profit values exactly. The flash fork test keeps the same per-round buy/sell route sequence while requiring positive profit after real lender fees; its gross and net amounts can differ from the inventory reference.
