# Arb Hook

A Uniswap v4 `afterSwap` hook that uses flash loans to arbitrage the pool that
triggered it against a registered external reference pool. Successful trades
repay the loan atomically and retain the remaining tokens for the hook owner.

This is experimental software. Tests cover execution and accounting, but do not
establish profitable operation or readiness for a particular deployment.

## How it works

After a user swaps through a pool using the hook:

1. The hook checks its execution settings and available gas.
2. It selects a registered reference for the same token pair, using the lowest
   current fee-adjusted buy price for the user's output token.
3. It sizes a counter-trade from the live spread, active liquidity, configured
   limits, and available flash liquidity.
4. It borrows the user's output token through an ERC-3156 lender, sells that
   token into the triggering v4 pool, and buys it back from the reference pool.
5. It can repeat the two swap legs within the same loan, recalculating sizes and
   price limits after each round.
6. It restores the intermediate-token balance, checks realized profit, repays
   principal plus the lender fee, and retains the surplus.

The active route supports ERC-20 pairs with Uniswap V3 or PancakeSwap V3
references. Native-currency pairs are skipped. The hook returns no custom
accounting delta and pays no rebate to the triggering swapper.

The older external-pool V2/V3 scanner remains available to the test harness for
regression coverage. The `afterSwap` path uses the triggering v4 pool and its
reference; it does not dispatch that scanner.

## Contracts

| File | Purpose |
|---|---|
| [ArbHook.sol](contracts/ArbHook.sol) | Hook entry point, owner configuration, reference registration, flash accounting, and callback authentication |
| [V4ArbExecutor.sol](contracts/V4ArbExecutor.sol) | Immutable execution module, called through `delegatecall`, for the iterative v4/V3 route |
| [ArbitrageLogic.sol](contracts/ArbitrageLogic.sol) | Pricing, route screening, sizing, and swap price limits |
| [ArbUtils.sol](contracts/ArbUtils.sol) | Registry types, transient execution context, and legacy route helpers |
| [ArbMath.sol](contracts/lib/ArbMath.sol) | Linked library for liquidity and price-impact calculations |
| [MorphoERC3156Adapter.sol](contracts/MorphoERC3156Adapter.sol) | ERC-3156 interface for one configured Morpho Blue token; quotes a zero flash fee |
| [AaveV3ERC3156Adapter.sol](contracts/AaveV3ERC3156Adapter.sol) | ERC-3156 interface for one configured Aave V3 reserve; quotes the pool's configured premium |

Test harnesses and mocks are in `contracts/test/`, Forge suites are in
`foundry/test/`, and deployment/configuration scripts are in `script/`.

## Build and test

Install Foundry and Node.js with npm, then run these commands from the repository
root:

```bash
npm ci
forge test
npm run size
```

[foundry.toml](foundry.toml) pins Solidity 0.8.26, the Cancun EVM target, and the
optimizer settings. Dependencies are pinned in `package-lock.json`. The
contracts use EIP-1153 transient storage, so the target chain must support it.

`npm run size` builds the contracts and checks the deployed runtime of the hook,
pricing engine, executor, and lender adapters against a 24,000-byte project
budget. Test contracts are not deployment artifacts.

Local suites cover real legacy route execution, flash accounting, callback
authentication, configuration, price normalization, ownership, and protected
balances. `ArbHookFlashLoanE2E` uses a profit-minting stub to isolate flash
plumbing; `ArbHookRealExecution` exercises the actual legacy executor against
pools that enforce their constant-product invariant.

### Fork tests

Fork suites require a Base RPC endpoint with access to the pinned historical
blocks. Set `BASE_RPC_URL` in your environment or an ignored `.env` file, then
enable the desired suite:

```bash
# Active v4/V3 route, both directions, iterative execution, and owner revenue
RUN_V4_LOOP_FORK=true forge test --match-contract ArbHookV4LoopForkTest

# Flash-lender integration and legacy external-pool routes
RUN_FLASH_FORK_INTEGRATION=true forge test

# Legacy inventory-funded route and profit regression checks
RUN_LEGACY_INVENTORY_PARITY=true forge test --match-contract ArbHookParityTest
```

These tests execute on local forks and do not broadcast transactions. Gated
suites report skips when disabled; passing the default suite does not imply
that fork integration has been tested. Parameter sweeps and economic
calibration have additional opt-in settings in their respective test files.

## Configuration

Arbitrage starts disabled. Configuration setters and withdrawals are restricted
to the owner. Ownership transfers require acceptance by the new owner;
renunciation is disabled to preserve the shutdown controls.

### Reference registration

Use `addPools(token, poolAddresses, fees, poolTypes)` to register reviewed
references under each possible borrowed token. Registration is directional:
for a swap from token A to token B, the hook borrows B and searches the
references registered under B. Supporting the reverse direction also requires
registration and flash configuration under A.

The selected reference must contain the same pair and have a supported V3 pool
type. Equal quoted prices preserve registration order. The registry is
append-only; correcting a bad registration requires a new hook deployment.

### Flash settings

Configure each borrowed token separately:

| Setter | Meaning |
|---|---|
| `setLenderForToken(token, lender)` | Bind an ERC-3156 lender or adapter |
| `setFlashPrincipalForToken(token, cap)` | Set the maximum borrowed amount, in raw token units |
| `setMaxFlashFeeBpsForToken(token, cap)` | Set the maximum accepted lender fee in basis points |
| `setMinNetProfitForToken(token, floor)` | Set the minimum realized profit after lender fees, in raw token units |

A zero principal cap, fee cap, or profit floor disables borrowing for that
token. Even a zero-fee lender requires a nonzero fee cap to enable execution.
The principal cap is a ceiling: the route derives its amount from pool state
before clamping it to that ceiling and the lender's available liquidity.
Existing hook balances are excluded from sizing.

### Execution settings

| Setter | Default | Meaning |
|---|---:|---|
| `setHookMaxIterations(value)` | `0` | Maximum rounds per loan; zero disables arbitrage |
| `setMinSpreadBps(value)` | `10` | Minimum directional tick spread used to screen a route |
| `setChunkSpreadConsumptionBps(value)` | `1500` | Base factor controlling how much of the spread each round consumes |
| `setMaxImpactBps(value)` | `500` | Maximum modeled tick movement per venue per round |
| `setHookGasBounds(reserve, limit)` | `200000`, `3000000` | Gas reserved for settlement and the arbitrage attempt budget |

The spread and impact settings operate on tick differences; they are not
guarantees of realized profit or exact percentage slippage. Sizing uses active
liquidity approximations, while execution enforces swap price limits and final
balance checks.

Read configuration with `getExecutionConfig()`, `getFlashConfig(token)`, and
`getGasBounds()`. Disable arbitrage with `setHookMaxIterations(0)`. The owner
can withdraw retained ERC-20 balances with `removeTokens(token)`.

## Gas and failure behavior

Each arbitrage attempt runs behind a self-call with gas reserved for the
triggering swap's remaining settlement. Failed attempts roll back their trades
and loan while allowing a user swap with sufficient gas to settle.

When execution is enabled and the gas limit is nonzero, the callback requires
more than `reserve + limit` gas before checking route eligibility. With the
defaults, that means more than 3,200,000 gas remaining at this point in the
callback. This is not a transaction gas estimate: routers and other swap work
also consume gas.

An underfunded callback reverts with `InsufficientHookGas`, even if the token
direction has no usable reference or lender configuration. This prevents gas
estimation from selecting a cheaper successful path that suppresses arbitrage.
Setting the limit to zero removes this admission floor and lets an attempt use
the gas available above the nonzero reserve.

## Accounting and integration limits

- Only the configured PoolManager can invoke `afterSwap`. Flash callbacks bind
  the lender, initiator, token, amount, and encoded context. Swap callbacks bind
  the active pool and payload and consume a single-use context.
- Settlement requires the intermediate-token balance to return exactly to its
  starting value. Pre-existing balances cannot fund an unprofitable loan.
- `FlashLoanSettled` reports realized route profit after lender fees. It does
  not subtract transaction gas paid by the triggering swapper.
- If the hook owner also supplies the v4 liquidity, assessing total returns
  requires combining hook revenue with LP inventory value, fees, and costs.
- The registry assumes owner-reviewed tokens, pools, and lenders. Reference
  prices come from current pool state; they are not manipulation-resistant
  oracles. Route availability and router selection depend on market conditions
  and integration behavior.

Hook deployment requires an address whose permission bits match `afterSwap`.
The constructor validates those bits and creates the immutable executor. The
existing deployment scripts contain Base-specific configuration; review chain
addresses, library linking, token compatibility, and hook-address mining when
adapting them. Configuration alone does not register every reference, initialize
a v4 pool, supply liquidity, or enable execution.

Keep RPC credentials and signing keys out of tracked files. Build and local
test commands do not require a signing key.
