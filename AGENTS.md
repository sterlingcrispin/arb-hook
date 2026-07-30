# Repository Guidelines

## Project Overview

A Uniswap v4 `afterSwap` hook that opportunistically executes bounded arbitrage
across registered external pools, funded by an ERC-3156 flash loan. The v4 swap
is only an execution trigger: route discovery and execution compare registered
Uniswap/PancakeSwap V2 and V3 pools and never quote or trade against the
triggering v4 pool.

`README.md` is the design and operator reference. `docs/MAINNET_CANARY_RUNBOOK.md`
is the release procedure. `OPEN_ISSUES.md` tracks audit findings and their
disposition. Read those three before changing runtime behavior.

## Layout

| Path | Purpose |
|------|---------|
| `contracts/ArbHook.sol` | The hook: registration, discovery, flash borrowing, execution, callbacks |
| `contracts/ArbitrageLogic.sol` | Stateless pricing and sizing; linked against `ArbMath` |
| `contracts/ArbUtils.sol` | Shared registry state, transient execution context, V2 flash-swap helper |
| `contracts/lib/ArbMath.sol` | V3 delta/capacity/impact math (external library) |
| `contracts/AaveV3ERC3156Adapter.sol` | Aave V3 lender adapter (5 bps premium) |
| `contracts/MorphoERC3156Adapter.sol` | Morpho Blue lender adapter (zero fee) |
| `contracts/test/` | Harnesses and mocks; never deployed |
| `foundry/test/` | Forge suites |
| `script/` | Deployment and owner configuration scripts |

## Test Suites

| Suite | Runs by default | What it proves |
|-------|-----------------|----------------|
| `ArbHookRealExecution.t.sol` | yes | Real two-leg route math, V2 repayment callbacks, residue handling, gas budget, against constant-product pools that enforce their own K |
| `ArbHookFlashLoanE2E.t.sol` | yes | Flash callback auth, fee caps, fail-closed config, beneficiary routing |
| `ArbHookFlashConfig.t.sol` | yes | Owner-only setters, CREATE2 hook mining, permission bits |
| `AaveV3ERC3156Adapter.t.sol` | yes | Aave adapter round trip against a mock pool |
| `MorphoERC3156Adapter.t.sol` | needs `RUN_FLASH_FORK_INTEGRATION=true` + `BASE_RPC_URL` | Zero-fee Morpho flash loan against live Base state |
| `ArbHookFlashForkAave.t.sol` | needs `RUN_FLASH_FORK_INTEGRATION=true` + `BASE_RPC_URL` | Ten-round route sequence and every route type at Base block 33942262 |
| `ArbHookParity.t.sol` | needs `RUN_LEGACY_INVENTORY_PARITY=true` + `BASE_RPC_URL` | Historical inventory-funded gross-profit baseline |

**`ArbHookFlashLoanE2E.t.sol` replaces `executeIterativeArb` with a
profit-minting stub** (`ArbHookHarness.setTestProfitBps`). That is deliberate —
those tests isolate flash plumbing — but it means a green run of that suite says
nothing about route math. `ArbHookRealExecution.t.sol` exists to cover the real
executor without a fork; keep it that way.

Gated suites report explicit skips rather than passing vacuously. A green
`forge test` with skips is not the release gate; the runbook is.

```bash
forge test                                            # fast local suites
RUN_FLASH_FORK_INTEGRATION=true forge test            # + current/fixed-block fork gates
npm run size                                          # EIP-170 budget
```

## Invariants To Preserve

- Arbitrage failure must never revert the triggering user swap. The attempt runs
  behind a self-call with an explicit gas budget; keep both.
- Registration order determines traversal order (`supportedTokens` then
  `baseCounterList`). Changing it changes route selection and the fork gate.
- Repayment is atomic and measured against the hook's own pre-loan balance. A
  pre-existing balance may be used as trading capital but must never be lost.
- The flash callback requires exact lender, initiator, token, amount and context
  hash. Swap callbacks require the single-use `(pool, data)` context.
- Intermediate-token balance must be exactly restored before a loan settles.
- Keep runtime under the 24,000-byte budget enforced by `npm run size`.

## Style

Solidity `^0.8.20`, four-space indent, explicit visibility, custom errors in
`ArbErrors` rather than strings. Contracts and structs PascalCase, functions and
state camelCase, constants ALL_CAPS. Prefer `SafeERC20`. Per-transaction state
belongs in transient storage (see the `_T_*` slots in `ArbUtils`), not cold
storage.

## Environment

`PRIVATE_KEY`, `BASE_RPC_URL` and `BASE_TESTNET_RPC_URL` live in an ignored
`.env`. Never commit operator secrets. The deployer and hook owner should be a
dedicated key holding only canary funds, not a main wallet.
