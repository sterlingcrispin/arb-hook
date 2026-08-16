# Base Mainnet WETH Canary Runbook

This is the release procedure for a small owner-operated proof of concept on Base. The exact PoolKey, reference venue, and addresses are in [`BASE_WETH_CANARY_MANIFEST.md`](BASE_WETH_CANARY_MANIFEST.md).

## Launch Boundary

The first canary contains:

- one hooked Uniswap v4 WETH/USDC pool;
- one canonical Uniswap v3 WETH/USDC reference pool;
- WETH principal borrowed through the Morpho Blue adapter;
- USDC-to-WETH trigger swaps only;
- one bounded V4/V3 counter-trade per trigger;
- all realized WETH profit paid to the original caller reported by the canonical Universal Router; and
- no unrelated markets, V2 routes, or additional reference venues.

The user's swap creates the edge by moving the hooked v4 pool. `afterSwap` counter-trades that same pool and exits through Uniswap v3 in the same transaction.

Do not broadcast until:

1. The intended release commit and Foundry version are recorded.
2. Every release gate below passes from a clean checkout.
3. Canonical Base addresses and runtime code are reverified.
4. The hook owner and LP recipient are the intended canary wallets.
5. LP caps, swap size, 49 USDC trigger floor, 1 WETH principal ceiling, and WETH profit floor are recorded.
6. The owner can set `hookMaxIterations` to zero.
7. The LP wallet can simulate burning the position.
8. The controlled swap has a current minimum WETH output and uses the canonical Universal Router with empty hook data.
9. The operator records whether this is an integration/rebate study or assumes an external backrun as its economic baseline.

## Release Gates

```bash
npm ci --ignore-scripts
forge --version
forge clean
forge test --summary
npm run size
```

The size gate requires every production runtime below 24,000 bytes. The current expected sizes are:

| Contract | Runtime bytes |
|---|---:|
| `ArbHook` | `22202` |
| `ArbitrageLogic` | `19678` |
| `AaveV3ERC3156Adapter` | `2590` |
| `MorphoERC3156Adapter` | `2144` |

Run the exact historical inventory oracle:

```bash
RUN_LEGACY_INVENTORY_PARITY=true \
BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookParityTest \
  --match-test testAttemptAllOnForkMatchesArbLightweightFlow -vv
```

Expected total: `18,679,602` raw USDC with all ten exact pool selections and profits.

Run the Morpho-funded historical sequence:

```bash
RUN_FLASH_FORK_INTEGRATION=true \
BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookFlashForkAaveTest \
  --match-test testForkMorphoAttemptAllTracksLegacyRoundSequenceFull -vv
```

Expected current result: all ten rounds positive, zero lender fees, total `18,543,625` raw USDC.

Run the actual production architecture against current Base state:

```bash
RUN_WETH_CANARY_FORK=true \
BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookWethCanaryForkTest -vv
```

This test uses canonical Base v4 periphery, Morpho, and Uniswap v3. It initializes the hooked pool, submits an ordinary 100 USDC swap, captures the edge created by that swap, repays, proves that empty hook data pays the Universal Router's original caller, validates the optional explicit-recipient override, and removes liquidity. It does not force an unrelated external dislocation.

It also compares no backrun, a matched external V4/V3 backrun, and the hook using distinct accounts. At pinned block `50018808`, the backrunner and hook each captured `0.804926 USDC` and left the LP at the same value; the recipient was the searcher in one case and the beneficiary in the other. With no backrun, the LP retained an additional `0.813727 USDC`. Treat this as MEV redistribution, not operator revenue, unless organic backrunning is established as the correct baseline.

## 1. Deploy Disabled

Simulate:

```bash
OWNER="$OWNER" PRIVATE_KEY="$OWNER_KEY" forge script \
  script/DeployArbHook.s.sol:DeployArbHook \
  --rpc-url "$BASE_RPC_URL"
```

Review the deployment trace and predicted addresses. Add `--broadcast` only after review. Record:

- linked `ArbMath` deployment;
- `ArbitrageLogic`;
- Aave WETH adapter;
- Morpho WETH adapter;
- `ArbHook`; and
- CREATE2 salt.

The hook starts with `hookMaxIterations = 0`. Do not initialize a pool until ownership, code, and permission bits have been verified.

## 2. Verify Deployment

```bash
export WETH=0x4200000000000000000000000000000000000006
export USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
export POOL_MANAGER=0x498581fF718922c3f8e6A244956aF099B2652b2b
export V3_REFERENCE=0xd0b53D9277642d899DF5C87A3966A349A798F224
export HOOK=<deployed-hook>
export LOGIC=<deployed-logic>
export MORPHO_ADAPTER=<deployed-morpho-adapter>
export AAVE_ADAPTER=<deployed-aave-adapter>
```

```bash
cast call "$HOOK" "owner()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$HOOK" "poolManager()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$HOOK" \
  "getExecutionConfig()(uint256,uint16,uint16,uint256)" \
  --rpc-url "$BASE_RPC_URL"
cast call "$HOOK" "getGasBounds()(uint32,uint32)" --rpc-url "$BASE_RPC_URL"
cast call "$MORPHO_ADAPTER" "morpho()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$MORPHO_ADAPTER" "supportedToken()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$MORPHO_ADAPTER" \
  "flashFee(address,uint256)(uint256)" "$WETH" 1000000000000000000 \
  --rpc-url "$BASE_RPC_URL"
cast call "$MORPHO_ADAPTER" \
  "maxFlashLoan(address)(uint256)" "$WETH" \
  --rpc-url "$BASE_RPC_URL"
cast codesize "$HOOK" --rpc-url "$BASE_RPC_URL"
cast codesize "$LOGIC" --rpc-url "$BASE_RPC_URL"
cast codesize "$MORPHO_ADAPTER" --rpc-url "$BASE_RPC_URL"
cast codesize "$AAVE_ADAPTER" --rpc-url "$BASE_RPC_URL"
```

Expected initial execution config is `(0, 10, 1500, 500)`. Expected gas bounds are `(200000, 3000000)`. The hook address low permission bits must encode `afterSwap` only. The Morpho adapter must report WETH and quote zero fee.

Ownership renunciation is disabled. Ownership transfer is two-step: call `transferOwnership(newOwner)`, then call `acceptOwnership()` from the new owner.

## 3. Register The Reference Venue

Keep execution disabled. Simulate:

```bash
PRIVATE_KEY="$OWNER_KEY" HOOK="$HOOK" forge script \
  script/RegisterArbHookCanaryPools.s.sol:RegisterArbHookCanaryPools \
  --rpc-url "$BASE_RPC_URL"
```

The script attests the canonical Uniswap V3 factory, WETH/USDC ordering, and fee `500`, then calls `addPools(WETH, ...)` with exactly one pool. Repeat with `--broadcast` only if the attestation and transaction are correct.

The first registered matching concentrated pool is the production reference venue. The registry is append-only. If this step is wrong, abandon the hook before traffic and deploy a fresh one.

## 4. Configure WETH Flash Funding

Initial reviewed values:

```text
WETH_FLASH_PRINCIPAL_CAP_WEI = 1000000000000000000   # 1 WETH ceiling
WETH_MAX_FLASH_FEE_BPS       = 1                     # smallest enabled cap
WETH_MIN_NET_PROFIT_WEI      = 100000000000000       # provisional 0.0001 WETH
USDC_MIN_TRIGGER_AMOUNT_RAW  = 49000000               # 49 USDC actual input
```

The principal is a ceiling, not the requested amount. A zero principal, fee cap, or profit floor disables borrowing. The trigger floor is keyed to the exact WETH/USDC PoolId and USDC-to-WETH direction; swaps below it skip before route discovery.

Simulate while the hook remains disabled:

```bash
PRIVATE_KEY="$OWNER_KEY" \
HOOK="$HOOK" \
LENDER_ADAPTER="$MORPHO_ADAPTER" \
WETH_FLASH_PRINCIPAL_CAP_WEI=1000000000000000000 \
WETH_MAX_FLASH_FEE_BPS=1 \
WETH_MIN_NET_PROFIT_WEI=100000000000000 \
USDC_MIN_TRIGGER_AMOUNT_RAW=49000000 \
forge script script/ConfigureArbHookCanary.s.sol:ConfigureArbHookCanary \
  --rpc-url "$BASE_RPC_URL"
```

Record the deterministic PoolId printed by the simulation as `POOL_ID`. Repeat with `--broadcast`, then read back:

```bash
cast call "$HOOK" \
  "getFlashConfig(address)(address,uint256,uint256,uint256)" "$WETH" \
  --rpc-url "$BASE_RPC_URL"
cast call "$HOOK" \
  "getMinTriggerAmount(bytes32,bool)(uint256)" "$POOL_ID" false \
  --rpc-url "$BASE_RPC_URL"
```

Recalculate the profit floor immediately before launch:

```text
minimumProfitWei >=
    incrementalArbGas * conservativeGasPriceWei
  + conservativeExtraFeeWei
  + desiredBeneficiaryMarginWei
```

At pinned block `50018808`, the calibrated boundary was 48 USDC below the `0.0001 WETH` floor and 49 USDC above it. With the 49 USDC input gate enabled, smaller swaps added only about 2,500 to 3,100 gas instead of entering the roughly 419,500-gas attempt. These values depend on pool liquidity and state and are not production guarantees.

## 5. Initialize And Fund The V4 Pool

Choose explicit LP caps and test them on a current fork with the intended swap size. The integration proof uses up to 2 WETH and 5,000 USDC; those are test parameters, not mandatory launch amounts.

```bash
PRIVATE_KEY="$LP_KEY" \
HOOK="$HOOK" \
LP_RECIPIENT="$LP_RECIPIENT" \
WETH_LP_AMOUNT_WEI="$WETH_LP_AMOUNT_WEI" \
USDC_LP_AMOUNT_RAW="$USDC_LP_AMOUNT_RAW" \
forge script \
  script/InitializeArbHookCanaryPool.s.sol:InitializeArbHookCanaryPool \
  --rpc-url "$BASE_RPC_URL"
```

The script reads the current canonical V3 price, computes full-range liquidity, approves only the supplied caps, and atomically initializes plus mints through the canonical V4 PositionManager.

Review the PoolKey, opening price, liquidity, LP recipient, and predicted token ID. Repeat with `--broadcast`, record `POSITION_TOKEN_ID`, and keep the NFT in the canary LP wallet.

## 6. Prove Normal Settlement While Disabled

Use a small protected USDC-to-WETH swap. Obtain a current quote and choose an explicit minimum WETH output. Never use `1` as production slippage protection.

```bash
PRIVATE_KEY="$SWAP_KEY" \
HOOK="$HOOK" \
USDC_SWAP_AMOUNT_RAW="$USDC_SWAP_AMOUNT_RAW" \
MIN_WETH_OUT_WEI="$MIN_WETH_OUT_WEI" \
forge script script/SwapArbHookCanary.s.sol:SwapArbHookCanary \
  --rpc-url "$BASE_RPC_URL"
```

Simulate first, then broadcast. Confirm exact USDC spend, normal WETH output, and no `FlashLoanSettled` event while disabled.

## 7. Enable And Run One Canary Swap

Recheck all configuration and enable the production path:

```bash
cast send "$HOOK" "setHookMaxIterations(uint256)" 1 \
  --private-key "$OWNER_KEY" --rpc-url "$BASE_RPC_URL"
```

`1` is an enable value. The production route performs one bounded V4/V3 counter-trade; it does not execute one legacy scanner iteration.

Read back `getExecutionConfig()`, then simulate the intended protected USDC-to-WETH swap with the same script. Supply enough gas for the 3,000,000-gas attempt ceiling plus normal router settlement. A low-gas attempt may be skipped while the user swap still settles.

A successful `FlashLoanSettled` event must show:

- lender equals the deployed Morpho adapter;
- `tokenA` is WETH;
- `tokenB` is USDC;
- `buyPool` is `0xd0b53D9277642d899DF5C87A3966A349A798F224`;
- `sellPool` is the canonical v4 PoolManager `0x498581fF718922c3f8e6A244956aF099B2652b2b`;
- principal is positive and no more than 1 WETH;
- fee is zero;
- iterations equals `1`;
- net profit meets the configured WETH floor; and
- beneficiary matches the wallet derived from `$SWAP_KEY`.

Also verify Morpho's WETH balance is unchanged after the transaction and the hook retains neither WETH nor USDC.

`netProfit` is route profit paid to the event's beneficiary address. On the controlled empty-data path, that address is the Universal Router's original caller. It is not proof that the LP/operator gained value. When the operator is also LP and recipient, the transfer is internal and external fees plus gas remain as net costs.

No event is expected below the configured 49 USDC actual-input floor or when an eligible swap cannot clear pool fees and the minimum-profit floor. Do not deliberately create an unsafe mainnet trade merely to force a loan. Reproduce the exact intended LP and swap parameters on a current fork first.

## Profit Recipient

No custom frontend or hook data is required for a direct caller using Base's canonical Universal Router. During `afterSwap`, the hook calls `IMsgSender.msgSender()` on the callback's router address and pays the returned execution initiator.

An exact packed address remains an optional override for controlled integrations:

```solidity
abi.encodePacked(beneficiary)
```

If an empty-data swap uses a custom router that does not implement `IMsgSender`, fails the lookup, or returns zero, the hook skips the attempt. A packed zero address or malformed nonempty data also skips. There is no `tx.origin` fallback.

Normal swap output is returned by the router and the hook returns zero V4 delta. Arbitrage profit is a separate WETH transfer from the hook to the resolved recipient.

The caller lookup does not guarantee that the public Uniswap interface or an aggregator will discover and route through the canary pool. It only removes the need for recipient-specific calldata once a canonical Universal Router swap reaches the pool. An aggregator contract that initiates the Universal Router execution receives the rebate and is responsible for forwarding it to its user.

## Stop And Withdraw

Stop attempts before changing liquidity:

```bash
cast send "$HOOK" "setHookMaxIterations(uint256)" 0 \
  --private-key "$OWNER_KEY" --rpc-url "$BASE_RPC_URL"
cast send "$HOOK" "setFlashPrincipalForToken(address,uint256)" "$WETH" 0 \
  --private-key "$OWNER_KEY" --rpc-url "$BASE_RPC_URL"
```

Read back both configurations. Quote the position's current WETH and USDC amounts, set accepted withdrawal minimums, and simulate:

```bash
PRIVATE_KEY="$LP_KEY" \
HOOK="$HOOK" \
POSITION_TOKEN_ID="$POSITION_TOKEN_ID" \
MIN_WETH_WITHDRAW_WEI="$MIN_WETH_WITHDRAW_WEI" \
MIN_USDC_WITHDRAW_RAW="$MIN_USDC_WITHDRAW_RAW" \
forge script \
  script/RemoveArbHookCanaryLiquidity.s.sol:RemoveArbHookCanaryLiquidity \
  --rpc-url "$BASE_RPC_URL"
```

Repeat with `--broadcast` only after reviewing the simulation. Confirm both assets returned and the PositionManager NFT was burned.

A hook cannot be detached from an initialized v4 pool. Setting the enable value to zero stops arbitrage; burning the LP position removes canary liquidity.
