# Base Mainnet WETH Canary Runbook

This is the release procedure for a small, owner-operated proof-of-concept on
Base. The exact trigger PoolKey and external pool book are in
[`BASE_WETH_CANARY_MANIFEST.md`](BASE_WETH_CANARY_MANIFEST.md).

## Launch Boundary

The first canary is intentionally narrow:

- one hooked Uniswap V4 WETH/USDC trigger pool;
- one external cbBTC/WETH market containing exactly two pools;
- WETH principal borrowed from Morpho Blue;
- at most two iterative chunks per trigger;
- all realized WETH profit paid to the beneficiary supplied by the swap caller;
- no Aerodrome pools and no additional registered markets.

The trigger pool is not an arbitrage leg. A USDC/WETH swap invokes the hook, and
the hook independently checks the two cbBTC/WETH pools for an opportunity.

Do not broadcast until all of these are true:

1. The intended release commit has been reviewed and recorded.
2. The release gates below pass from a clean checkout.
3. Current official sources still list every canonical Base address in the
   manifest, and each address has runtime code on the deployment RPC.
4. The owner and LP recipient are the intended canary wallets.
5. The accepted LP deposit caps, 1 WETH flash-principal ceiling, and provisional
   WETH profit floor are recorded.
6. The owner can disable iterations and the LP wallet can burn the position.
7. The controlled router call has an explicit minimum WETH output and exactly
   20 bytes of beneficiary hook data.

## Release Gates

Use the lockfile and the compiler pinned in `foundry.toml`:

```bash
npm ci --ignore-scripts
forge --version
forge clean
forge test --summary
npm run size
```

Record the Foundry version, release commit, and runtime sizes. Solc is pinned to
0.8.26; Foundry is not pinned. The size gate requires every production runtime
to remain below the repository's 24,000-byte budget.

Run the historical inventory oracle:

```bash
RUN_LEGACY_INVENTORY_PARITY=true \
BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookParityTest -v
```

Run the fixed-block Morpho flash replay:

```bash
BASE_RPC_URL="$BASE_RPC_URL" scripts/test_flash_fork_cached.sh
```

Run the intended WETH canary against a fresh, unpinned Base head:

```bash
RUN_WETH_CANARY_FORK=true \
BASE_RPC_URL="$BASE_RPC_URL" \
forge test --match-contract ArbHookWethCanaryForkTest -vv
```

The current-head test uses Base's canonical PoolManager, PositionManager,
Permit2, Universal Router, Morpho Blue, and the two manifest pools. It creates a
deterministic external dislocation so that borrowing, trading, repayment,
beneficiary payout, and LP withdrawal are always exercised. It proves the
integration path, not expected live yield.

## 1. Deploy Disabled

`DeployArbHook` creates `ArbitrageLogic`, WETH-bound Aave and Morpho adapters,
and a CREATE2-mined after-swap-only hook. `hookMaxIterations` starts at zero.

Simulate:

```bash
OWNER="$OWNER" PRIVATE_KEY="$OWNER_KEY" forge script \
  script/DeployArbHook.s.sol:DeployArbHook \
  --rpc-url "$BASE_RPC_URL"
```

Record the logic, adapter, hook, and salt outputs. Review the simulation, then
repeat the exact command with `--broadcast`. Do not initialize a pool until the
hook deployment and ownership have been verified.

## 2. Verify Deployment

Set the recorded addresses locally:

```bash
export WETH=0x4200000000000000000000000000000000000006
export HOOK=<deployed-hook>
export LOGIC=<deployed-logic>
export MORPHO_ADAPTER=<deployed-morpho-adapter>
export AAVE_ADAPTER=<deployed-aave-adapter>
```

Read back the deployment:

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

Expected initial execution config is `(0, 10, 1500, 500)` and expected gas
bounds are `(200000, 3000000)`. The hook address's low 14 bits must be `0x40`,
the after-swap-only permission mask. The Morpho adapter must report WETH as its
supported token and quote zero fee.

Ownership renunciation is disabled. Ownership transfer is two-step:
`transferOwnership(newOwner)` followed by `acceptOwnership()` from the new
wallet.

## 3. Register The External Book

Keep iterations at zero. Review the exact addresses and order in the manifest,
then simulate:

```bash
PRIVATE_KEY="$OWNER_KEY" HOOK="$HOOK" forge script \
  script/RegisterArbHookCanaryPools.s.sol:RegisterArbHookCanaryPools \
  --rpc-url "$BASE_RPC_URL"
```

The script checks each pool's factory, token ordering, and fee before calling
`addPools(WETH, ...)`. Repeat with `--broadcast` only if both attestations pass.
The registry is append-only. If this transaction is wrong, abandon this hook and
deploy a fresh one rather than trying to repair traversal order.

## 4. Configure WETH Flash Funding

The initial reviewed values are:

```text
WETH_FLASH_PRINCIPAL_CAP_WEI = 1000000000000000000   # 1 WETH ceiling
WETH_MAX_FLASH_FEE_BPS       = 1                     # smallest enabled cap
WETH_MIN_NET_PROFIT_WEI      = 100000000000000       # provisional 0.0001 WETH
```

The principal value is a ceiling. Existing route math chooses the amount to
borrow and may choose less. A zero principal, fee cap, or profit floor disables
borrowing.

Simulate while iterations remain zero:

```bash
PRIVATE_KEY="$OWNER_KEY" \
HOOK="$HOOK" \
LENDER_ADAPTER="$MORPHO_ADAPTER" \
WETH_FLASH_PRINCIPAL_CAP_WEI=1000000000000000000 \
WETH_MAX_FLASH_FEE_BPS=1 \
WETH_MIN_NET_PROFIT_WEI=100000000000000 \
forge script script/ConfigureArbHookCanary.s.sol:ConfigureArbHookCanary \
  --rpc-url "$BASE_RPC_URL"
```

Repeat with `--broadcast`, then verify:

```bash
cast call "$HOOK" \
  "getFlashConfig(address)(address,uint256,uint256,uint256)" "$WETH" \
  --rpc-url "$BASE_RPC_URL"
```

The `0.0001 WETH` floor is a provisional canary value, not a timeless constant.
Because gas and profit are both ETH-denominated, recalibrate immediately before
launch without an ETH/USD oracle conversion:

```text
minimumProfitWei >=
    incrementalArbGas * conservativeGasPriceWei
  + conservativeExtraFeeWei
  + desiredBeneficiaryMarginWei
```

The 2026-08-15 same-snapshot replay measured 162,467 gas with iterations
disabled and 899,973 gas with arbitrage enabled: 737,506 incremental gas. At the
observed 0.006 gwei RPC gas price that is `0.000004425036 WETH`, making the
provisional floor about 22.6 times measured incremental L2 cost. The forced edge
paid `0.001606426560759256 WETH` and cleared the floor. Re-measure at the release
head and include any fee not represented by `gasUsed * gasPrice`.

## 5. Initialize And Fund The Trigger Pool

The LP wallet needs WETH and USDC. Choose small, explicit caps. For example,
`0.1 WETH` plus `250 USDC` is a proof-of-concept-sized deposit, not a required
ratio or recommendation:

```bash
PRIVATE_KEY="$LP_KEY" \
HOOK="$HOOK" \
LP_RECIPIENT="$LP_RECIPIENT" \
WETH_LP_AMOUNT_WEI=100000000000000000 \
USDC_LP_AMOUNT_RAW=250000000 \
forge script \
  script/InitializeArbHookCanaryPool.s.sol:InitializeArbHookCanaryPool \
  --rpc-url "$BASE_RPC_URL"
```

The script reads the current price from canonical Uniswap V3 WETH/USDC 0.05%,
computes full-range liquidity, approves only the supplied caps, and atomically
initializes plus mints through the canonical V4 PositionManager. Any unused cap
remains in the LP wallet.

Review the PoolKey, opening price, liquidity, LP recipient, and predicted token
ID. Repeat with `--broadcast`, then record the minted PositionManager token ID
from the receipt. Keep that NFT in the canary wallet; it controls withdrawal.

## 6. Prove Normal Settlement While Disabled

Before enabling arbitrage, send a very small controlled USDC-to-WETH swap with
iterations still zero. Obtain a current output quote and set a real minimum;
never use `1` as production slippage protection.

```bash
PRIVATE_KEY="$SWAP_KEY" \
HOOK="$HOOK" \
BENEFICIARY="$SWAP_BENEFICIARY" \
USDC_SWAP_AMOUNT_RAW=1000000 \
MIN_WETH_OUT_WEI="$MIN_WETH_OUT_WEI" \
forge script script/SwapArbHookCanary.s.sol:SwapArbHookCanary \
  --rpc-url "$BASE_RPC_URL"
```

First run without `--broadcast`. Adjust only from a current quote and the
accepted slippage, not until the simulation happens to pass. Then broadcast and
confirm the payer spent exactly the intended USDC and received WETH. No
`FlashLoanSettled` event should exist while iterations are zero.

## 7. Enable And Run The Canary

Recheck all config, then enable two chunks:

```bash
cast send "$HOOK" "setHookMaxIterations(uint256)" 2 \
  --private-key "$OWNER_KEY" --rpc-url "$BASE_RPC_URL"
```

Read back `getExecutionConfig()`, then run another small protected swap with the
same script. Use enough transaction gas for discovery; the current rehearsal
used about 0.9 million gas, while failed pair attempts receive progressively
smaller subcall budgets. A low-gas swap can skip arbitrage and still settle.

A successful arbitrage emits `FlashLoanSettled`. Verify:

- lender equals the deployed Morpho adapter;
- `tokenA` is WETH and `tokenB` is cbBTC;
- buy and sell pools are the two manifest addresses;
- principal is positive and no more than 1 WETH;
- fee is zero;
- net profit is at least the configured WETH floor;
- beneficiary matches the packed hook data;
- Morpho's WETH balance is unchanged after the transaction;
- the hook retains neither WETH nor cbBTC.

No event is a valid result when the live pools have no profitable discrepancy.
Do not create an unsafe mainnet dislocation merely to force a loan. The fresh
fork gate is the deterministic proof that the path executes.

## Beneficiary And Router Requirement

The router must pass exactly `abi.encodePacked(beneficiary)`, which is 20 bytes,
in V4 `hookData`. Empty, zero-address, or differently encoded data deliberately
skips the arbitrage attempt. There is no fallback to the router or `tx.origin`.

The normal swap output is returned by the Universal Router. Arbitrage profit is
a separate WETH transfer from the hook to the beneficiary; the hook returns zero
V4 delta. If payer and beneficiary are the same address, their WETH balance
increase combines normal output and arb profit, while `FlashLoanSettled`
identifies the profit component.

Do not assume the public Uniswap app or an aggregator will route through a new
hooked pool or encode this custom beneficiary. Until a frontend explicitly
supports it, only the repository's controlled router script is a validated
traffic path.

## Stop And Withdraw

Stop borrowing before touching liquidity:

```bash
cast send "$HOOK" "setHookMaxIterations(uint256)" 0 \
  --private-key "$OWNER_KEY" --rpc-url "$BASE_RPC_URL"
cast send "$HOOK" "setFlashPrincipalForToken(address,uint256)" "$WETH" 0 \
  --private-key "$OWNER_KEY" --rpc-url "$BASE_RPC_URL"
```

Read back both configs. Then quote the position's current WETH and USDC amounts,
set nonzero accepted minimums, and simulate the burn:

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

Repeat with `--broadcast` only after reviewing the simulation. Confirm both
assets returned to the LP wallet and the PositionManager NFT was burned.

A hook attached to an initialized V4 pool cannot be detached. Disabling
iterations stops arbitrage; burning the LP position removes the canary capital.
