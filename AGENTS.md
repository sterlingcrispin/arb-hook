# Repository Guidelines

## Project Overview
This is a **generic multi-DEX arbitrage system** that runs on Base network. It detects price discrepancies for any registered token pairs across multiple liquidity pools and executes atomic arbitrage swaps to capture profits. The system supports Uniswap V2/V3/V4, PancakeSwap V2/V3, and Aerodrome.

The current test suite focuses on **cbBTC/USDC and WETH/USDC** pairs as the primary validation case, but the architecture is token-agnostic—any token pairs can be registered via `addPools()`.

## Primary Goal: Exact Parity with ExampleTests

**The ArbHook Forge tests must produce EXACTLY the same output as the reference JS harness in `ExampleTests/`.** This means:
- Same pool selection per round
- Same profit amounts per round
- Same total profit (18.679602 USDC across 10 rounds)
- Same buy/sell pool addresses per round

### Reference Output (from `ExampleTests/attemptAllOutput.txt`)

| Round | Buy Pool | Sell Pool | Profit (USDC) | Profit (raw) |
|-------|----------|-----------|---------------|--------------|
| 1 | `0x56C8` | `0x1C45` | 0.000521 | 521 |
| 2 | `0x56C8` | `0x1C45` | 0.000301 | 301 |
| 3 | `0x56C8` | `0xd0b5` | 0.013268 | 13,268 |
| 4 | `0xb4CB` | `0xd0b5` | 0.124048 | 124,048 |
| 5 | `0xB775` | `0xd0b5` | 5.391960 | 5,391,960 |
| 6 | `0x72AB` | `0xd0b5` | 11.373898 | 11,373,898 |
| 7 | `0x56C8` | `0xd0b5` | 0.004842 | 4,842 |
| 8 | `0xb4CB` | `0xd0b5` | 0.052775 | 52,775 |
| 9 | `0x56C8` | `0xd0b5` | 0.002828 | 2,828 |
| 10 | `0xB775` | `0xd0b5` | 1.715161 | 1,715,161 |
| **Total** | | | **18.679602** | **18,679,602** |

### Key Files

| File | Purpose |
|------|---------|
| `ExampleTests/ArbLightweight.attemptAll.js` | **Golden source of truth** - JS test harness |
| `ExampleTests/attemptAllOutput.txt` | **Reference output** - exact profits/pools to match |
| `ExampleTests/ArbLightweight.sol` | Original arbitrage contract (non-hook) |
| `ExampleTests/helpers/constants.js` | Token addresses, pool addresses, router addresses |
| `ExampleTests/helpers/poolData.js` | CSV parser for `pool_csv/uniswap_top5_zoraTrump.csv` |
| `contracts/ArbHook.sol` | Uniswap V4 hook version we're testing |
| `foundry/test/ArbHookParity.t.sol` | Forge test attempting exact parity |

**Note**: The actual JS harness lives at `/Users/sterlingcrispin/code/arb-bot/test/ArbLightweight.attemptAll.js`. The `ExampleTests/` folder may not be present in this repo; run JS debugging from the arb-bot project.

## JS Harness Behavior (What We Must Replicate)

### 1. Fork Configuration
```javascript
const FORK_START_BLOCK = 33942332 - 70;  // = 33942262
```

### 2. Pool Registration Order (CRITICAL)
The JS harness registers pools in this exact order:

**Step 1**: Register cbBTC/USDC V3 pools under USDC base token (line 399):
```javascript
await arbLight.addPools(usdcAddress, [lowLiqPool, highLiqPool], [100, 500], [V3, V3]);
```
- `0xE9e25E35aa99A2A60155010802b81A25C45bA185` (fee=100, low liquidity)
- `0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef` (fee=500, high liquidity)

**Step 2**: Register CSV pools from `pool_csv/uniswap_top5_zoraTrump.csv` (lines 496-509):
- Pools containing WETH are added under `wethAddress` as base
- Pools containing USDC are added under `usdcAddress` as base
- **Pools containing BOTH are added under BOTH base tokens**

The `poolsByToken` Map iteration order determines `supportedTokens` order, which affects `attemptAll` iteration.

### 3. Funding
- 10 WETH transferred to bot
- 100,000 USDC transferred to bot
- MaxUint256 approvals for WETH/USDC/cbBTC on all pools

### 4. Runtime Parameters
- `MAX_ITER_PER_ATTEMPT = 2`
- `MAX_ROUNDS = 10`
- `minSpreadBps = 10`
- `CHUNK_SPREAD_CONSUMPTION_BPS = 1500`
- `_MAX_IMPACT_BPS = 500`
- `minProfitToEmit = 0`

### 5. Token Ordering Rule
**The JS harness NEVER calls `_getSinglePoolPrices` with WETH as tokenA.**
- Confirmed by: `grep "tokenA 0x4200" attemptAllOutput.txt` returns nothing
- When tokenA is WETH and the pool has WETH as token0, the decimal math underflows to zero
- The Forge test must avoid querying with WETH as tokenA

## Current Issues (What's Breaking Parity)

### Issue 1: Pool Registration Order
The Forge test `_parityPools()` doesn't match the JS registration order. The JS:
1. First adds cbBTC/USDC pools under USDC
2. Then adds CSV pools, registering each under WETH if it contains WETH, AND under USDC if it contains USDC

### Issue 2: Missing Dual-Base Registration
Pools like USDC/WETH (`0x1C45`, `0xd0b5`, etc.) need to be registered under BOTH:
- `base: USDC` (so USDC->WETH arb paths work)
- `base: WETH` (if the JS does this)

But the JS iterates `supportedTokens` and when WETH is the base token, it still uses USDC as tokenA in price queries (needs verification).

### Issue 3: Price Calculation When tokenA = WETH
When `_getSinglePoolPrices` is called with tokenA=WETH (18 decimals) and tokenB=USDC (6 decimals):
- The `_calculatePrice1e18_corrected` function underflows to zero
- This breaks pool discovery for WETH-base iterations

### Issue 4: `supportedTokens` Order Affects Iteration
The `attemptAllInternal` function iterates `supportedTokens` in order. Different order = different pool pairs evaluated first = different arbitrage results.

## Test Commands
```bash
# Start Anvil with correct fork block
anvil --fork-url "$BASE_RPC_URL" --fork-block-number 33942262 --host 127.0.0.1 --port 8546

# Run Forge parity test
BASE_RPC_URL=http://127.0.0.1:8546 forge test --match-contract ArbHookParityTest -vv

# Run JS harness for comparison (from arb-bot repo)
(cd /Users/sterlingcrispin/code/arb-bot && npm test -- --grep "attemptAll")
```

## Steps to Achieve Parity

### Step 1: Trace JS Pool Registration Order
Add logging to `ArbLightweight.attemptAll.js` to capture the exact order of:
- `supportedTokens` array after all `addPools` calls
- `baseCounterList[token]` for each supported token
- Which base token is used for each `_runPair` call

### Step 2: Match Pool Registration in Forge
Update `_parityPools()` to register pools in the exact same order as JS, with the same base tokens.

### Step 3: Verify Seeding Produces Same State
The JS harness doesn't explicitly seed cbBTC/USDC pools - it just funds and approves. The Forge test has `_seedCbBtcUsdcGap()` which might be creating different pool states. May need to remove or adjust seeding.

### Step 4: Match `supportedTokens` Order
Ensure the Forge test's `supportedTokens` array matches JS exactly. This determines iteration order in `attemptAllInternal`.

### Step 5: Per-Round Validation
After each round, compare:
- `buyPool` address
- `sellPool` address
- `profit` amount
- `iterations` count

## Current Test Status (as of 2026-01-04)

**PARITY ACHIEVED** - All 10 rounds pass with exact match:

| Round | Profit (USDC) | buyPool | sellPool | Status |
|-------|--------------|---------|----------|--------|
| 1 | 521 | 0x56C8 | 0x1C45 | ✅ |
| 2 | 301 | 0x56C8 | 0x1C45 | ✅ |
| 3 | 13,268 | 0x56C8 | 0xd0b5 | ✅ |
| 4 | 124,048 | 0xb4CB | 0xd0b5 | ✅ |
| 5 | 5,391,960 | 0xB775 | 0xd0b5 | ✅ |
| 6 | 11,373,898 | 0x72AB | 0xd0b5 | ✅ |
| 7 | 4,842 | 0x56C8 | 0xd0b5 | ✅ |
| 8 | 52,775 | 0xb4CB | 0xd0b5 | ✅ |
| 9 | 2,828 | 0x56C8 | 0xd0b5 | ✅ |
| 10 | 1,715,161 | 0xB775 | 0xd0b5 | ✅ |
| **Total** | **18,679,602** | | | ✅ |

**Key Fix**: The Round 3 parity issue was caused by different funding behavior:
- **JS**: Swaps 2×25 WETH → USDC through the fee=500 pool (`0xd0b5`) to acquire ~200k USDC
- **Forge (old)**: Pulled USDC from a whale without touching pools

The WETH→USDC swaps change the fee=500 pool's price, which affects subsequent arbitrage decisions. By Round 3, this price change makes `0xd0b5` a better sell pool than `0x1C45`.

**Anvil command**:
```bash
anvil --fork-url "$BASE_RPC_URL" --fork-block-number 33942262 --host 127.0.0.1 --port 8546
```

**Test command**:
```bash
BASE_RPC_URL=http://127.0.0.1:8546 forge test --match-contract ArbHookParityTest -v
```

## Completed Work

- [x] Fork block aligned to 33942262
- [x] Removed extra `_logBestSpread(WETH, USDC)` calls that caused underflow
- [x] Removed WETH-based pool registrations (only USDC-based now)
- [x] Fixed funding to replicate JS WETH→USDC swaps (the key fix!)
- [x] All 10 rounds match expected profits and pool selections
- [x] `ENFORCE_PARITY = true` enabled and passing

## Remaining Work

- [ ] Clean up debug logging if desired
- [ ] Consider adding more edge case tests

## Project Structure & Module Organization
Core Solidity lives in `contracts/`: `ArbHook.sol` hosts the Uniswap v4 after-swap hook, `ArbitrageLogic.sol` + `ArbUtils.sol` cover pricing/loop helpers, and `contracts/interfaces/` + `contracts/lib/` mirror external pool ABIs. Test fixtures (`contracts/test/*.sol`) include deterministic ERC20s, hook miners, and PoolManager harnesses. Forge tests live under `foundry/`; the JS reference harness lives in the external arb-bot repo.

## Coding Style & Naming Conventions
Stick to Solidity ^0.8.20, four-space indentation, explicit visibility, and descriptive custom errors (`ArbErrors`). Contracts/structs are PascalCase, functions/state camelCase, and constants ALL_CAPS. Favor `using SafeERC20`, guard callbacks with `nonReentrant`, and emit events mirroring major revert reasons.

## Security & Environment
Store `PRIVATE_KEY`, `BASE_RPC_URL`, and `BASE_TESTNET_RPC_URL` inside an ignored `.env`; never push operator secrets. Double-check trusted factory addresses, hook iteration caps, and min-profit guards prior to Base deployments.
