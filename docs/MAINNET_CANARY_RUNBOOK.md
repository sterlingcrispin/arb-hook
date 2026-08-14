# Base Mainnet Canary Runbook

This is the release procedure for a small, owner-operated canary. It does not
expand the contract's threat model or add onchain release machinery.

## Go/No-Go Boundary

Do not route mainnet swaps through the hook until all of these are true:

1. An independent Solidity reviewer has signed off on the deployed commit.
2. The full release gate below passes from a clean checkout.
3. A current-head Base fork rehearsal passes with the intended pool manifest,
   owner, Morpho reserve and adapter, v4 PoolManager, Universal Router, and
   beneficiary encoding.
4. Every production address has been checked against its current official source
   and its runtime code has been inspected on the deployment RPC.
5. The owner is the intended canary wallet and holds only the deliberately
   limited canary funds.
6. The minimum net-profit floor has been calibrated against incremental L2
   execution cost, L1 data cost, and the desired user margin.
7. The initial v4 liquidity and flash-principal caps are explicitly accepted as
   canary risk limits.

V3/V3, V2/V2, V2-to-V3, and V3-to-V2 routes have route-specific pre-loan
sizing and real fixed-block fork coverage. The ten-round intended-lender gate
uses Morpho; Aave remains a fee-bearing comparison. Register only the canonical
route types and pools listed in the reviewed canary manifest. The initial
manifest must use USDC as the registered base and flash-loan token; WETH-base V3
discovery is not part of this release gate.

## Reproduce The Release

Use Node's lockfile and the Solidity compiler pinned in `foundry.toml`:

```bash
npm ci --ignore-scripts
forge --version
forge clean
forge test --summary
npm run size
```

Solc is pinned to 0.8.26 in `foundry.toml`; Foundry is not yet pinned. Select one
Foundry release for the final clean gate and record its full `forge --version`,
the release commit, and runtime sizes with the release artifacts. Do not mix
artifacts produced by different Foundry versions.

Run the fixed-block flash gate against Base block 33942262:

```bash
BASE_RPC_URL="$BASE_RPC_URL" scripts/test_flash_fork_cached.sh
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
  --match-test testCanonicalV4RouterUsesMorphoAndPaysPackedBeneficiary -vv
```

`npm audit` currently reports the OpenZeppelin `Bytes.lastIndexOf` advisory
against the pinned 5.3.0 package. `ArbHook` does not import or reach that library,
so the advisory is not present in the compiled contracts. Recheck this conclusion
if imports or the OpenZeppelin version change.

## Simulate And Deploy

The deployment is intentionally limited to the linked `ArbMath` library,
`ArbitrageLogic`, the USDC Aave and Morpho adapters, and a CREATE2-mined
after-swap hook. Foundry deploys `ArbMath` automatically because
`ArbitrageLogic` contains external library links:

```bash
OWNER="$OWNER" PRIVATE_KEY="$PRIVATE_KEY" forge script \
  script/DeployArbHook.s.sol:DeployArbHook \
  --rpc-url "$BASE_RPC_URL"
```

Review the simulation, then rerun the same command with `--broadcast`. Set
`OWNER` to the final owner so no post-deployment ownership transfer is needed.
The script rejects chains other than Base mainnet (`8453`) and leaves hook
execution disabled.

Ownership renunciation is disabled because a live v4 hook cannot be detached and
must retain its shutdown controls. If ownership must change, the current owner
calls `transferOwnership(newOwner)`, the new owner calls `acceptOwnership()`, and
the operator verifies both `owner()` and `pendingOwner()` before retiring the old
key. A transfer is not complete when only the first transaction succeeds.

Before configuration, verify:

```bash
cast call "$HOOK" "owner()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$HOOK" "poolManager()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$HOOK" \
  "getExecutionConfig()(uint256,uint16,uint16,uint256)" \
  --rpc-url "$BASE_RPC_URL"
cast call "$MORPHO_ADAPTER" "morpho()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$MORPHO_ADAPTER" "supportedToken()(address)" --rpc-url "$BASE_RPC_URL"
cast call "$MORPHO_ADAPTER" \
  "flashFee(address,uint256)(uint256)" "$USDC" 1000000000 \
  --rpc-url "$BASE_RPC_URL"
cast call "$MORPHO_ADAPTER" "maxFlashLoan(address)(uint256)" "$USDC" \
  --rpc-url "$BASE_RPC_URL"
cast codesize "$HOOK" --rpc-url "$BASE_RPC_URL"
cast codesize "$MORPHO_ADAPTER" --rpc-url "$BASE_RPC_URL"
cast codesize "$AAVE_ADAPTER" --rpc-url "$BASE_RPC_URL"
```

The hook address's low 14 bits must equal `0x40`, the after-swap-only flag. The
constructor enforces this, but record the mined salt and address from the script.
Record the linked `ArbMath` address from the simulation/broadcast artifact and
verify all five artifacts from the exact release commit on the block explorer:
`ArbMath`, `ArbitrageLogic`, both adapters, and `ArbHook`. If Aave is selected
instead, verify its provider-specific `pool()` and `liquidityToken()` getters;
those getters do not exist on the Morpho adapter.

## Configure While Disabled

Keep `hookMaxIterations` at zero until every other step is complete.

1. Record the exact pool manifest, including base token, pool address, fee, type,
   and registration order. Registration order changes route traversal. For this
   canary every entry must be registered under USDC as the base.
2. Call `addPools` in that reviewed order. The registry is append-only; redeploy
   before traffic if any entry is wrong.
3. Set the reviewed execution profile. The historical profile is `10` spread
   bps, `1500` chunk-consumption bps, and `500` max-impact bps.
4. Choose the lender. The deployment script deploys both adapters; only the one
   bound with `setLenderForToken` is live.

   **Bind the Morpho adapter unless a rehearsal gives a reason not to.** Morpho
   Blue charges no flash premium, Aave charges 5 bps, and at canary size that fee
   is the dominant cost. Replaying the ten-round fixed-block sequence through
   each lender, identical pool book and routes:

   | Lender | Fees paid | Net profit | vs legacy gross |
   |--------|-----------|------------|-----------------|
   | Morpho Blue | 0 | **18.543625 USDC** | 99.3% |
   | Aave V3 | 8.945556 USDC | 8.365681 USDC | 44.8% |

   Verify the chosen lender before binding:

```bash
# Morpho: confirm code, USDC liquidity, and that the adapter quotes zero
cast codesize 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb --rpc-url "$BASE_RPC_URL"
cast call "$MORPHO_ADAPTER" "flashFee(address,uint256)(uint256)" "$USDC" 1000000000 --rpc-url "$BASE_RPC_URL"
cast call "$MORPHO_ADAPTER" "maxFlashLoan(address)(uint256)" "$USDC" --rpc-url "$BASE_RPC_URL"

# Aave, only if binding Aave instead
cast call "$AAVE_POOL" "FLASHLOAN_PREMIUM_TOTAL()(uint128)" --rpc-url "$BASE_RPC_URL"
```

   Set the fee cap from the bound lender's live quote. A zero-fee lender still
   needs a nonzero cap because zero disables borrowing entirely. For Morpho use
   the smallest enabled cap, currently 1 bps; it rejects a later fee only when
   that fee exceeds the configured cap.

5. Assign the chosen adapter to USDC, then set the principal cap, maximum fee,
   and minimum net profit. All three economic values must be
   nonzero or borrowing remains disabled. Simulate the owner-only configuration
   script with explicit raw-unit values, then add `--broadcast`:

```bash
PRIVATE_KEY="$OWNER_KEY" HOOK="$HOOK" LENDER_ADAPTER="$MORPHO_ADAPTER" \
USDC_FLASH_PRINCIPAL_CAP_RAW="$USDC_FLASH_PRINCIPAL_CAP_RAW" \
USDC_MAX_FLASH_FEE_BPS="$USDC_MAX_FLASH_FEE_BPS" \
USDC_MIN_NET_PROFIT_RAW="$USDC_MIN_NET_PROFIT_RAW" \
forge script script/ConfigureArbHookCanary.s.sol:ConfigureArbHookCanary \
  --rpc-url "$BASE_RPC_URL"
```

   The script configures the principal cap last and does not enable hook
   iterations.
6. Read back all runtime configurations:

```bash
cast call "$HOOK" \
  "getFlashConfig(address)(address,uint256,uint256,uint256)" "$USDC" \
  --rpc-url "$BASE_RPC_URL"
cast call "$HOOK" \
  "getExecutionConfig()(uint256,uint16,uint16,uint256)" \
  --rpc-url "$BASE_RPC_URL"
cast call "$HOOK" "getGasBounds()(uint32,uint32)" --rpc-url "$BASE_RPC_URL"
```

Set the principal as a borrowing ceiling; adaptive route math chooses the actual
loan below it. Start-token balances already held by the hook are excluded from
sizing, so donations cannot expand the route. The ceiling is not a bound on
cumulative swap volume because borrowed principal and earned profit can be reused
across bounded iterations. `hookMaxIterations`, route sizing, price limits, and
`maxImpactBps` bound that execution. The historical flash sequence reached a
maximum principal of 10,695.735171 USDC, so an 11,000 USDC cap is the smallest
simple cap that covers that fixed-block gate. The test suite's 100,000 USDC cap
is not a production recommendation.

**Do not calibrate `minNetProfit` against the fixed-block fixture.** It seeds one
displacement, and each candidate floor creates a different pool-state trajectory
and amount of scanner work. At an 8,000-raw floor the sweep settles no trades but
still spends about 26.0 million attempt gas across ten triggers. That result is
useful for regression and gas-cost sensitivity; it does not establish a
production opportunity ceiling. Production triggers arrive after unrelated
traders have changed pool state. The sweep is documented in OPEN_ISSUES item 53
and implemented by `testCalibrateMinNetProfit`, gated behind
`RUN_SPREAD_CALIBRATION=true`. Calibrate from the current-head differential gas
replay below instead, and leave the fixture's floor at 1 raw unit so it keeps
exercising all ten routes.

`minSpreadBps` is not an economic control and should stay at `10`; see
OPEN_ISSUES item 52.

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
V2/V2 and mixed routes reuse fee-aware raw-token simulations to reject estimates
that cannot cover the quoted flash fee plus this floor before borrowing. The
V3/V3 score is only a relative chunk-ranking signal, not a currency estimate, so
that route checks for an edge before borrowing and enforces the floor against
realized balances in the callback. The realized post-loan check is authoritative
for every route.

The 2026-07-26 rehearsal at Base block 49149499 measured 1,076,889 gas inside
the successful hook path. At that block's 0.006 gwei gas price and observed
WETH/USDC price, L2 execution alone was about 0.012324 USDC. A provisional
rehearsal value of `100000` raw USDC (`0.10 USDC`) is roughly eight times that
measured L2 cost, but it is not a release value. Recalculate from the final
current-head differential replay and the desired user margin.

On 2026-08-02, a fresh current-head fork also passed the canonical v4 router
lifecycle through the intended Morpho adapter, including the real route book,
packed beneficiary, zero flash fee, and beneficiary payout. This validates the
lender integration path but does not replace the final-manifest differential gas
calibration above.

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

Then set the USDC principal cap to zero and remove application routing to the
hooked pool.
The hook attached to an initialized v4 pool is immutable; disabling execution
does not remove the hook from that pool.
