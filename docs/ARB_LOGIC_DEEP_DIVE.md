# ArbHook Logic Deep Dive

This note explains the intent behind the main loops and sizing heuristics in:

- `contracts/ArbHook.sol`
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
2. Execute leg 1 (`start -> intermediate`) then leg 2 (`intermediate -> start`).
3. Measure realized per-iteration profit from wallet balances.
4. Stop if marginal iteration profit is `<= 0`.

After loop:

- Best-effort unwind of residual intermediate tokens (except USDC/WETH skip case).
- Emit/store trade only if positive and above `minProfitToEmit`.

Why stop on non-positive marginal profit:

- At that point local slippage/impact has usually consumed edge.
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

- Probe ladder (`minChunk`, `1%`, `10%`, `50%` balance).
- Start from best heuristic chunk and halve until profitable/safe.

### Mixed V2/V3 path

- Start at half balance.
- Halve until a profitable chunk appears or floor/iteration cap is hit.

Large-first probing is intentional: it converges quickly and cheaply with halving when oversized.

## 6) Callback Safety Model

V3 callbacks (`uniswapV3SwapCallback`, `pancakeV3SwapCallback`) enforce:

- callback payload caller is this contract
- `msg.sender` equals expected pool in encoded callback data
- pool exists in registered metadata
- token deltas have expected sign

V2 callbacks (`uniswapV2Call`, `pancakeCall`) enforce:

- pair address matches trusted factory lookup
- pair is also registered in local metadata
- repayment token is one of pair tokens

These checks are defense-in-depth against forged callbacks.
