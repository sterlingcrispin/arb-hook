# ArbHook Logic Deep Dive

This note explains the intent behind the main loops and sizing heuristics in:

- `contracts/ArbHook.sol`
- `contracts/ArbUtils.sol`
- `contracts/ArbitrageLogic.sol`

## 1) Route Planning Model

The v4 swap is the execution trigger only. The current planner does not include
the triggering v4 pool as a route leg.

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

- Up to 2 attempts:
  - find best pools
  - execute via a gas-bounded low-level self-call to isolate reverts
- Excludes the failed pool combination before its fallback discovery pass.

Why this is done:

- Avoids revert cascades from one bad route.
- Gives each route at most half the remaining scanner gas, so one expensive V3
  path cannot starve the fallback or later base/counter pairs.
- Keeps no failed-quote state across later user swaps, so a temporary lender or
  route failure cannot poison a future opportunity.

## 3) Pool Selection

### `findBestPools(tokenA, tokenB, ...)`

Single pass over `tokenPools[tokenA]`:

- choose minimum effective buy price
- choose maximum effective sell price
- ensure spread exists and pools are distinct

This is deliberately simple and fast; it is rerun frequently inside callback-driven execution.

The price normalizer handles both token orientations with exact quotient and
remainder arithmetic over the full V3 sqrt-price range. The initial canary still
registers only USDC-base routes because that is the reviewed, regression-tested
manifest; adding a WETH-base route requires separate route and economic coverage.

## 4) Iterative Arbitrage Engine

### `executeIterativeArb(...)`

Per iteration:

1. Recompute chunk size from current state.
2. Execute leg 1 (`start -> intermediate`) then leg 2 (`intermediate -> start`).
3. Measure realized per-iteration profit from wallet balances.
4. Stop if marginal iteration profit is `<= 0`.

After the loop:

- Best-effort unwind of any residual intermediate-token delta, first through the
  second-leg pool and then through the first-leg pool if residue remains.
- Return the realized profit, iteration count, and total input swapped to the flash callback.
- Emit the final route and net accounting in `FlashLoanSettled`.

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
- The coarse upper bound is borrowed first because the unchanged executor uses
  its balance as the search range. If execution is unprofitable, the route may
  retry with the refined principal and one half-sized candidate. A positive
  result below `minNetProfit` is final so retries cannot consume the whole scan.
- The capacity calculation walks nearby tick-spacing intervals and reads
  liquidity only when those sampled ticks are initialized. It is a bounded
  sizing approximation, not a complete initialized-tick bitmap simulation.
- Pool-enforced price limits and realized post-loan profit checks remain the
  authoritative execution safeguards when the estimate is imperfect.

### V2-V2 path

- Probe ladder (`minChunk`, `1%`, `10%`, `50%` balance).
- Start from best heuristic chunk and halve until profitable/safe.
- Before a flash loan, run that same probe ladder with the configured principal
  cap as its available balance. Borrow twice the selected chunk because the
  unchanged executor limits its first candidate to half of its balance. This
  preserves the executor's selected trade size without adding another sizing
  model.

### Mixed V2/V3 path

- Start at half balance.
- Halve until a profitable chunk appears or floor/iteration cap is hit.
- Before a flash loan, run that same bounded simulation from half of the
  configured principal cap. Borrow twice the selected chunk so callback
  execution begins with the same candidate; no separate spread-based sizing
  model is used.

Large-first probing is intentional: it converges quickly and cheaply with halving when oversized.

## 6) Callback Safety Model

V3 callbacks (`uniswapV3SwapCallback`, `pancakeV3SwapCallback`) enforce:

- callback payload matches the exact pool swap currently awaiting repayment
- callback payload caller is this contract
- `msg.sender` equals expected pool in encoded callback data
- pool exists in registered metadata
- token deltas have expected sign

V2 callbacks (`uniswapV2Call`, `pancakeCall`) enforce:

- callback payload matches the exact pair swap currently awaiting repayment
- pair address matches trusted factory lookup
- pair is also registered in local metadata
- repayment token is one of pair tokens

These checks are defense-in-depth against forged callbacks.
