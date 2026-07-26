# Base Mainnet Canary Runbook

This is the release procedure for a small, owner-operated canary. It does not
expand the contract's threat model or add onchain release machinery.

## Go/No-Go Boundary

Do not route mainnet swaps through the hook until all of these are true:

1. An independent Solidity reviewer has signed off on the deployed commit.
2. The full release gate below passes from a clean checkout.
3. A current-head Base fork rehearsal passes with the intended pool manifest,
   owner, Aave reserve, v4 PoolManager, Universal Router, and beneficiary encoding.
4. Every production address has been checked against its current official source
   and its runtime code has been inspected on the deployment RPC.
5. The owner is the intended canary wallet and holds only the deliberately
   limited canary funds.
6. The minimum net-profit floor has been calibrated against incremental L2
   execution cost, L1 data cost, and the desired user margin.
7. The initial v4 liquidity and flash-principal caps are explicitly accepted as
   canary risk limits.

V3/V3, V2/V2, V2-to-V3, and V3-to-V2 routes have route-specific pre-loan
sizing and fixed-block Aave fork coverage. Register only the canonical route
types and pools listed in the reviewed canary manifest.

## Reproduce The Release

Use Node's lockfile and the Solidity compiler pinned in `foundry.toml`:

```bash
npm ci --ignore-scripts
forge --version
forge clean
forge test --summary
npm run size
```

The reviewed release toolchain is Foundry v1.7.1 with solc 0.8.26. Record the
actual `forge --version`, commit, and runtime sizes with the release artifacts.

Run the fixed-block flash gate against Base block 33942262:

```bash
BASE_RPC_URL="$BASE_RPC_URL" scripts/test_flash_fork_cached.sh \
  --match-contract ArbHookFlashForkAaveTest -v
```

Run the historical inventory baseline separately:

```bash
RUN_LEGACY_INVENTORY_PARITY=true \
BASE_RPC_URL="$BASE_RPC_URL" \
forge test \
  --match-contract ArbHookParityTest \
  --match-test testAttemptAllOnForkMatchesArbLightweightFlow -v
```

The fixed block proves regression behavior, not current mainnet conditions.
Repeat the canonical router lifecycle and intended canary scenario on a fresh,
unpinned Base fork immediately before deployment. Do not change a failing
current-head result merely to preserve historical output.

```bash
anvil --fork-url "$BASE_RPC_URL" --fork-chain-id 8453 --port 8547
```

```bash
RUN_FLASH_FORK_INTEGRATION=true FORK_ALREADY_PINNED=true \
BASE_RPC_URL="http://127.0.0.1:8547" \
forge test \
  --match-contract ArbHookFlashForkAaveTest \
  --match-test testCanonicalV4RouterPassesPackedBeneficiary -vv
```

`npm audit` currently reports the OpenZeppelin `Bytes.lastIndexOf` advisory
against the pinned 5.3.0 package. `ArbHook` does not import or reach that library,
so the advisory is not present in the compiled contracts. Recheck this conclusion
if imports or the OpenZeppelin version change.

## Simulate And Deploy

The deployment script is intentionally limited to deploying
`ArbitrageLogic`, the USDC Aave adapter, and a CREATE2-mined after-swap hook:

```bash
OWNER="$OWNER" PRIVATE_KEY="$PRIVATE_KEY" forge script \
  script/DeployArbHook.s.sol:DeployArbHook \
  --rpc-url "$BASE_RPC_URL"
```

Review the simulation, then rerun the same command with `--broadcast`. Set
`OWNER` to the final owner so no post-deployment ownership transfer is needed.
The script rejects chains other than Base mainnet (`8453`) and leaves hook
execution disabled.

Before configuration, verify:

```bash
cast call "$HOOK" "owner()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$HOOK" "poolManager()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$HOOK" \
  "getExecutionConfig()(uint256,uint16,uint16,uint256)" \
  --rpc-url "$BASE_RPC_URL"
cast call "$ADAPTER" "pool()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$ADAPTER" "supportedToken()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$ADAPTER" "liquidityToken()(address)" --rpc-url "$BASE_RPC_URL"
cast codesize "$HOOK" --rpc-url "$BASE_RPC_URL"
```

The hook address's low 14 bits must equal `0x40`, the after-swap-only flag. The
constructor enforces this, but record the mined salt and address from the script.
Verify the three contracts from the exact release commit on the block explorer.

## Configure While Disabled

Keep `hookMaxIterations` at zero until every other step is complete.

1. Record the exact pool manifest, including base token, pool address, fee, type,
   and registration order. Registration order changes route traversal.
2. Call `addPools` in that reviewed order. The registry is append-only; redeploy
   before traffic if any entry is wrong.
3. Set the reviewed execution profile. The historical profile is `10` spread
   bps, `1500` chunk-consumption bps, and `500` max-impact bps.
4. Read Aave's live premium:

```bash
cast call "$AAVE_POOL" \
  "FLASHLOAN_PREMIUM_TOTAL()(uint128)" \
  --rpc-url "$BASE_RPC_URL"
```

5. Trust the deployed adapter, assign it to USDC, then set the principal cap,
   maximum fee, and minimum net profit. All three economic values must be
   nonzero or borrowing remains disabled. Simulate the owner-only configuration
   script with explicit raw-unit values, then add `--broadcast`:

```bash
PRIVATE_KEY="$OWNER_KEY" HOOK="$HOOK" AAVE_ADAPTER="$ADAPTER" \
USDC_FLASH_PRINCIPAL_CAP_RAW="$USDC_FLASH_PRINCIPAL_CAP_RAW" \
USDC_MAX_FLASH_FEE_BPS="$USDC_MAX_FLASH_FEE_BPS" \
USDC_MIN_NET_PROFIT_RAW="$USDC_MIN_NET_PROFIT_RAW" \
forge script script/ConfigureArbHookCanary.s.sol:ConfigureArbHookCanary \
  --rpc-url "$BASE_RPC_URL"
```

   The script configures the principal cap last and does not enable hook
   iterations.
6. Read back both configurations:

```bash
cast call "$HOOK" \
  "getFlashConfig(address)(address,uint256,uint256,uint256,bool)" "$USDC" \
  --rpc-url "$BASE_RPC_URL"
cast call "$HOOK" \
  "getExecutionConfig()(uint256,uint16,uint16,uint256)" \
  --rpc-url "$BASE_RPC_URL"
```

Set the fee cap from the live Aave premium, not from a stale test constant. Set
the principal as an operator risk ceiling; adaptive route math chooses the
actual loan below it. The historical flash sequence reached a maximum principal
of 10,695.735171 USDC, so an 11,000 USDC cap is the smallest simple cap that
covers that fixed-block gate. The test suite's 100,000 USDC cap is not a
production recommendation.

`minNetProfit` is denominated in raw borrowed-token units. It excludes ETH gas
even though it includes the flash fee. For USDC, calculate:

```text
gasCostRaw = ceil(
  (incrementalGas * conservativeGasPriceWei + extraEthFeeWei)
  * conservativeEthUsdcRaw / 1e18
)
minNetProfitRaw = gasCostRaw + desiredUserMarginRaw
```

Measure `incrementalGas` by replaying the same swap from the same current-head
fork snapshot with iterations first at `0` and then at the intended value. The
swap calldata is unchanged, so normal user traffic does not incur incremental
L1 calldata cost from the arb itself. If the canary swap exists only to trigger
the hook, include the full transaction gas and L1 fee in `extraEthFeeWei`.
Every route type reuses its sizing estimate to reject opportunities that cannot
cover the quoted flash fee plus this floor before borrowing. The realized
post-loan check remains authoritative because the estimate is not exact.

The 2026-07-26 rehearsal at Base block 49149499 measured 1,076,889 gas inside
the successful hook path. At that block's 0.006 gwei gas price and observed
WETH/USDC price, L2 execution alone was about 0.012324 USDC. A provisional
rehearsal value of `100000` raw USDC (`0.10 USDC`) is roughly eight times that
measured L2 cost, but it is not a release value. Recalculate from the final
current-head differential replay and the desired user margin.

## Route Canary Traffic

Initialize and fund only the intended v4 canary pool after verifying its
`PoolKey` contains the deployed hook. Cap the initial LP capital independently
of the flash principal cap.

The router must put exactly `abi.encodePacked(beneficiary)` in `hookData`.
Missing, zero, or non-20-byte data deliberately skips arbitrage. The beneficiary
should be the swap user if the user is meant to receive the net profit.

Run one controlled swap while iterations are still zero and confirm normal pool
settlement. Then set `hookMaxIterations` to the reviewed value, historically
`2`, and run the smallest useful live canary swap.

## Observe And Stop

`FlashLoanSettled` is the settlement record. Confirm its lender, route,
principal, fee, positive net profit, and beneficiary against token transfers.
The event's net profit is after the flash fee but before the user's transaction
gas. A missing event means no arbitrage settled; failures are intentionally
contained so the triggering swap can still succeed.

Stop globally with:

```bash
cast send "$HOOK" "setHookMaxIterations(uint256)" 0 \
  --private-key "$OWNER_KEY" --rpc-url "$BASE_RPC_URL"
```

Then set the USDC principal cap to zero and, if the lender itself is in doubt,
mark the adapter untrusted. Remove application routing to the hooked pool.
The hook attached to an initialized v4 pool is immutable; disabling execution
does not remove the hook from that pool.
