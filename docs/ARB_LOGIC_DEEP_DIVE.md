# ArbHook Logic Deep Dive

This note explains the intent behind the main loops and sizing heuristics in:

- `contracts/ArbHook.sol`
- `contracts/ArbExecutor.sol`
- `contracts/ArbUtils.sol`
- `contracts/ArbitrageLogic.sol`

## 1) Route Planning Model

The route graph is intentionally shallow and deterministic:

- `tokenPools[baseToken]`: all pools registered under that base token.
- `baseCounterList[baseToken]`: unique counter tokens seen for that base.
- `supportedTokens`: base tokens in insertion order.

Execution traversal is:

1. base token from `supportedTokens`
2. counter token from `baseCounterList[base]`
3. best buy/sell pool pair from `tokenPools[base]`

Because traversal order is deterministic, **pool registration order directly affects evaluation sequence** and can affect parity outcomes when early-exit conditions are active.

## 2) Outer Execution Loops

### `attemptAllInternal(maxIterations)`

- Iterates base/counter pairs in order.
- Calls `_runPair(base, counter, maxIterations)` for each.
- Stops at the **first profitable pair**.

`ArbHook` keeps this selector as a self-only wrapper and delegates the heavy
implementation to its immutable `ArbExecutor`. The executor runs in the hook's
storage context, so callback permissions, configuration, and trade records
stay tied to the hook address.

Why this is done:

- Hook execution must remain bounded.
- Once profitable path is found, additional scanning adds gas and risk without improving user swap execution.

### `_runPair(tokenA, tokenB, maxIter)`

This is the pair-level controller with bounded retries.

- Reads `lastFailedAttemptForPair` and skips if quantized prices have not changed.
- Up to 2 attempts:
  - find best pools
  - skip repeated/known-bad quote keys
  - execute via low-level self-call to isolate reverts
- Maintains two caches:
  - `lastFailedQuote`: quote-level failure suppression
  - `lastFailedAttemptForPair`: pair-level stale-route suppression

Why this is done:

- Prevents repeated retries on identical market states.
- Avoids revert cascades from one bad route.

## 3) Pool Selection

### `findBestPools(tokenA, tokenB, ...)`

Single pass over `tokenPools[tokenA]`:

- choose minimum effective buy price
- choose maximum effective sell price
- ensure spread exists and pools are distinct

This is deliberately simple and fast; it is rerun frequently inside callback-driven execution.

## 4) Iterative Arbitrage Engine

### `executeIterativeArb(...)`

Per iteration:

1. Recompute chunk size from current state.
2. If `maxFlashTradeAmount[start]` is nonzero, use it as the available-capital
   sizing bound. The hook does not need to hold that amount.
3. Ask the first pool to send its `start -> intermediate` output before payment.
4. Inside the first pool's callback, execute the
   `intermediate -> start` leg and repay the first pool from its output.
5. Measure realized per-iteration profit from balance deltas.
6. Stop if marginal iteration profit is `<= 0`.

After loop:

- The intermediate-token balance must return to its entry value after each
  flash-settled round; the second leg must consume exactly what the first leg
  produced.
- Repayment must come from the second leg's realized output. Any remaining
  residue, failed leg, or non-positive final P&L reverts the isolated self-call.
- Positive start-token profit is sent to the hook owner, returning the hook's
  working balance to its entry value.
- Emit/store trade only if positive and above `minProfitToEmit`.

Setting a token's flash-trade cap to zero retains the legacy path, where the
hook's existing token balance bounds and funds sequential execution.

Why stop on non-positive marginal profit:

- At that point local slippage/impact has usually consumed edge.
- In flash mode, a later reverse leg that cannot repay its initiating swap is
  reverted as an atomic no-op, preserving earlier profitable iterations.
- Continuing generally burns gas and worsens aggregate outcome.

## 5) Why the Size Search Starts Large

Exact on-chain optimal sizing across concentrated liquidity is expensive because:

- price curve changes across ticks
- both legs interact
- constraints change after each executed step

So the implementation uses bounded heuristics:

### V3-V3 path

- `getV3SwapParameters`: derive a rough upper bound from spread and liquidity window.
- `findBestV3Chunk`: bounded binary search on profit proxy.

### V2-V2 path

- Probe ladder (`minChunk`, `1%`, `10%`, `50%` available-capital bound).
- Start from best heuristic chunk and halve until profitable/safe.

### Mixed V2/V3 path

- Start at half the available-capital bound.
- Halve until a profitable chunk appears or floor/iteration cap is hit.

Large-first probing is intentional: it converges quickly and cheaply with halving when oversized.

## 6) Callback Safety Model

V3 callbacks (`uniswapV3SwapCallback`, `pancakeV3SwapCallback`) enforce:

- callback payload caller is this contract
- `msg.sender` equals expected pool in encoded callback data
- pool exists in registered metadata
- token deltas have expected sign
- callback data is bound to the one-shot capability, including any nested
  second-leg route

V2 callbacks (`uniswapV2Call`, `pancakeCall`) enforce:

- pair address matches trusted factory lookup
- pair is also registered in local metadata
- repayment token/output amounts match a one-shot execution context created
  immediately before the canonical pair swap
- the context is consumed before the repayment transfer

For an outer flash-settled leg, the callback consumes its capability before
starting the nested second leg. The nested pool gets its own one-shot callback
capability, and the outer pool is paid only after that leg realizes enough of
the start token to cover its exact debt.

These checks are defense-in-depth against forged callbacks.
