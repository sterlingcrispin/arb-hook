## Arb Hook

A Uniswap v4 hook-driven arbitrage system that checks for opportunities during swaps, without relying on always-on off-chain scanners or mempool racing.

On L2's where gas is cheap this may be economically viable. When a user attempts a swap, we piggyback some logic to search for arbs and close them as we can.

Either an opportunity already exists, or the swap creates one. Either way, the hook gets a guaranteed execution point with fresh prices and known state, and uses that moment to see if a profitable, safe arb is possible.

If yes, it executes atomically inside the same transaction. If not, it does nothing and the swap proceeds normally.

The current implementation executes arbitrage from hook callbacks only. There is no manual owner-triggered `attemptAll` entrypoint in `ArbHook`.

## Big Picture

Instead of constantly scanning markets or competing in gas wars, we wait for real trades to happen and then ask:

“Given the current pool state and prices elsewhere, is there a clean arbitrage worth doing right now?”

Most of the time the answer is no, and the hook exits almost immediately. When the answer is yes, the hook can act instantly, without latency or MEV competition.

The hook doesn't assume the arbitrage leg happens on another Uniswap v4 pool. Today the implemented external pool types are Uniswap V2/V3 and PancakeSwap V2/V3, so the v4 hook is acting as an observation point for broader cross-venue price discovery.

The current code assumes the hook contract holds its own funds for arbitrage execution. For now, this simplifies control flow during swaps. In the future I imagine this would be done with flash loans instead to remove capital constraints. That also opens a clearer path to allow profits from arbitrages to be shared with the user that started the transaction.

There is still required operator setup off-chain: pool registration, approvals, inventory funding, and parameter tuning.


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

The expected behavior is defined by the legacy reference artifacts in `ParityTest/`:
- `ParityTest/ArbLightweight.sol` (original non-hook contract)
- `ParityTest/ArbLightweight.attemptAll.js` (legacy harness logic)
- `ParityTest/attemptAllOutput.txt` (golden per-round pool/profit sequence)

Legacy comments that referred to a "worker bot" or "worker deployment" were describing that earlier non-hook implementation.

The purpose of the parity test is to confirm the current Uniswap v4 hook path reproduces that same outcome sequence and total profit profile, including per-round buy/sell pool choices and profit values.
