## Arb Hook

A Uniswap v4 hook-driven arbitrage system that checks for opportunities during swaps, without relying on always-on off-chain scanners or mempool racing.

On L2's where gas is cheap this may be economically viable. When a user attempts a swap, we piggyback some logic to search for arbs and close them as we can.

Either an opportunity already exists, or the swap creates one. Either way, the hook gets a guaranteed execution point with fresh prices and known state, and uses that moment to see if a profitable, safe arb is possible.

If yes, it executes atomically inside the same transaction. If not, it does nothing and the swap proceeds normally.

The current implementation executes arbitrage from hook callbacks only. There is no manual owner-triggered `attemptAll` entrypoint in `ArbHook`.

## Deployment Architecture

`ArbHook` is intentionally a small V4-facing shell. Its immutable `ArbExecutor`
implementation performs discovery and execution through `delegatecall`, so state,
inventory, approvals, callbacks, and `DataStorage` authorization all remain at the
hook address. This keeps every deployable runtime below the EIP-170 24,576-byte
limit while preserving the existing hook entrypoints.

This is a fresh-deployment architecture, not an upgrade path: deploy
`ArbitrageLogic`, `DataStorage`, and `ArbExecutor`, then mine and deploy the
five-argument hook constructor. The hook must be mined for exactly
`Hooks.AFTER_SWAP_FLAG`, and `DataStorage.setWriter` must target the hook—not the
executor.

`ArbMath` is an externally linked library. The documented `forge script` command
automatically deploys and links it; do not deploy raw, unlinked artifacts by hand.

Use the included Foundry script for a production deployment:

```bash
PRIVATE_KEY=... \
V4_POOL_MANAGER=0x498581fF718922c3f8e6A244956aF099B2652b2b \
ARB_HOOK_OWNER=0xYourMultisig \
  forge script script/DeployArbHook.s.sol:DeployArbHook \
  --rpc-url "$BASE_RPC_URL" --broadcast --always-use-create-2-factory
```

On Base (chain ID 8453), the script requires Uniswap's
[canonical PoolManager](https://docs.uniswap.org/contracts/v4/deployments),
`0x498581fF718922c3f8e6A244956aF099B2652b2b`, and verifies its runtime code
hash. The validation cannot be bypassed on Base. A non-Base local or test
deployment must explicitly set `ALLOW_UNVERIFIED_POOL_MANAGER=true`; the target
must still contain contract code.

The broadcaster initially owns `ArbHook` and `DataStorage` so it can authorize
the hook as the trade-data writer. If `ARB_HOOK_OWNER` is provided, the script
then transfers both contracts to that address, which should normally be an
operator multisig. It defaults to the broadcaster when omitted. Verify the
`owner()` of both contracts, `DataStorage.authorizedWriter()`, the immutable
PoolManager, and the hook permission bits before funding or approving pools.

This deployment is a sequence of independent transactions, not an atomic
factory deployment. A partially failed broadcast is not rolled back. Inspect
Foundry's `broadcast/DeployArbHook.s.sol/8453/run-latest.json` artifact and the
individual transaction receipts before retrying or using any deployed address.
The script itself does not create an aggregate on-chain deployment event; its
return values and broadcast artifact are the deployment record.

## Big Picture

Instead of constantly scanning markets or competing in gas wars, we wait for real trades to happen and then ask:

“Given the current pool state and prices elsewhere, is there a clean arbitrage worth doing right now?”

Most of the time the answer is no, and the hook exits almost immediately. When the answer is yes, the hook can act instantly, without latency or MEV competition.

The hook doesn't assume the arbitrage leg happens on another Uniswap v4 pool. Today the implemented external pool types are Uniswap V2/V3 and PancakeSwap V2/V3, so the v4 hook is acting as an observation point for broader cross-venue price discovery.
The Aerodrome and V4 router interfaces in `contracts/interfaces/` are unused
scaffolding, not supported execution venues.

The current code assumes the hook contract holds its own funds for arbitrage execution. For now, this simplifies control flow during swaps. In the future I imagine this would be done with flash loans instead to remove capital constraints. That also opens a clearer path to allow profits from arbitrages to be shared with the user that started the transaction.

There is still required operator setup off-chain: pool registration, approvals, and inventory funding.

## Runtime Parameters Explained

The main runtime knobs are owner-settable on `ArbHook`:

- `setHookMaxIterations(uint256)`  
  Limits how many iterative chunks can execute in one trigger (0 disables hook
  execution; the production cap is 10).
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
  Maximum estimated price impact allowed for guarded V2-to-V3 paths before
  skipping. V3-to-V3 sizing uses bounded price-limit windows and realized P&L
  checks instead, because a coarse current-range estimate can incorrectly reject
  a route that crosses an initialized tick.

- `setMinProfitToEmit(uint256)`  
  Minimum cumulative profit required before emitting/storing trade data.
  Unit is raw `tokenA` units (not 1e18 normalized).

- `setHookPoolEnabled(PoolKey,bool)`
  Opts a specific V4 pool key into callback-driven arbitrage. Unlisted pools
  always receive a no-op `afterSwap` response, so registering a hook address on a
  pool cannot accidentally enable costly execution.

### Parity Test Profile (Current)

In the parity harness (`foundry/test/ArbHookParity.t.sol`), the runtime profile is:

- `hookMaxIterations = 2`
- `minSpreadBps = 10`
- `chunkSpreadConsumptionBps = 1500`
- `maxImpactBps = 500`
- `minProfitToEmit = 0`

Why these values are used for parity:

- `2` iterations keeps execution bounded while still allowing a follow-up chunk after the first fill.
- `10 bps` filters micro-spreads that are usually not robust after execution costs.
- `1500` gives a moderate first-step aggressiveness instead of over-consuming spread immediately.
- `500` (5%) blocks obviously excessive-impact paths.
- `0` ensures every profitable round is emitted/stored, which makes round-by-round parity assertions observable.


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

- Parity as the real invariant  
  Current parity tests target exact sequence matching against the legacy non-hook reference (pool picks and profit amounts), not just "some profitable trade happened."

## Parity Test Context

The parity suite in `foundry/test/ArbHookParity.t.sol` is a regression target against a **previous non-hook arbitrage implementation**, not a comparison between two hook designs.

The expected behavior is defined by legacy reference artifacts in the external
arb-bot project's `ExampleTests/` directory:

- `ExampleTests/ArbLightweight.sol` (original non-hook contract)
- `ExampleTests/ArbLightweight.attemptAll.js` (legacy harness logic)
- `ExampleTests/attemptAllOutput.txt` (golden per-round pool/profit sequence)

Legacy comments that referred to a "worker bot" or "worker deployment" were describing that earlier non-hook implementation.

The purpose of the parity test is to confirm the current Uniswap v4 hook path reproduces that same outcome sequence and total profit profile, including per-round buy/sell pool choices and profit values.

## Local Verification

```bash
npm ci --ignore-scripts
forge build --sizes
forge test --no-match-contract ArbHookParityTest -vvv
```

Run the fork-parity suite separately with an archive-capable Base endpoint when
validating the golden round-by-round output:

```bash
BASE_RPC_URL=... forge test --match-contract ArbHookParityTest -vv
```

CI deliberately excludes the RPC-dependent contract from its deterministic
job instead of counting skipped fork tests as success. Exact ten-round parity is
a separate CI job on every push, pull request, and manual workflow run.
It prefers the protected `BASE_RPC_URL` repository secret and falls back to
Base's public `https://mainnet.base.org` endpoint when secrets are unavailable
(including fork pull requests). The job fails if the endpoint is unavailable,
does not resolve to chain ID 8453, the canonical PoolManager code hash changes,
or any golden parity assertion fails.
