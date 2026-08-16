# Base Canary Runbook

This runbook deploys one hooked WETH/USDC v4 pool on Base. The first position is
bounded to roughly +/-3% around the live reference price and uses approximately
250 USDC plus 250 USDC worth of WETH.

## Fixed Configuration

- Hooked pool: WETH/USDC, 10 bp fee, tick spacing 10
- Reference pools: PancakeSwap v3 1 bp and Uniswap v3 1 bp
- Flash lender: Morpho Blue, with separate WETH and USDC adapters
- Principal caps: 0.0027 WETH and 5 USDC
- Minimum net profit: 0.000027 WETH and 0.05 USDC
- Iterations: 10
- Attempt gas reserve/limit: 200,000 / 3,000,000

The hook is deployed and configured with zero iterations. Enabling is a separate
last step that verifies the position owner, liquidity, pool state, loan config,
and execution config.

## Environment

```bash
set -a
source .env
set +a
[[ "$PRIVATE_KEY" == 0x* ]] || PRIVATE_KEY="0x$PRIVATE_KEY"
export PRIVATE_KEY
```

Store the addresses printed by each stage in an ignored file under `artifacts/`.

## Deployment Order

```bash
forge script script/DeployArbHook.s.sol:DeployArbHook \
  --rpc-url "$BASE_RPC_URL" --broadcast --slow

export HOOK=<deployed-hook>
export WETH_ADAPTER=<deployed-weth-adapter>
export USDC_ADAPTER=<deployed-usdc-adapter>

forge script script/ConfigureBaseCanary.s.sol:ConfigureBaseCanary \
  --rpc-url "$BASE_RPC_URL" --broadcast --slow

forge script script/RegisterBaseCanaryPools.s.sol:RegisterBaseCanaryPools \
  --rpc-url "$BASE_RPC_URL" --broadcast --slow
```

Wrap only the WETH shortfall while retaining enough ETH for shutdown and LP
withdrawal transactions. Then initialize and mint while the hook is disabled:

```bash
export WETH_LP_AMOUNT_WEI=132640000000000000
export USDC_LP_AMOUNT_RAW=250000000

forge script script/InitializeBaseCanaryPool.s.sol:InitializeBaseCanaryPool \
  --rpc-url "$BASE_RPC_URL" --broadcast --slow

export POSITION_TOKEN_ID=<printed-token-id>

forge script script/EnableBaseCanary.s.sol:EnableBaseCanary \
  --rpc-url "$BASE_RPC_URL" --broadcast --slow
```

## Controlled Swap

The hook intentionally requires more than 3.2M gas at callback entry. Foundry's
default estimator can submit a transaction that follows the low-gas revert path.
Always use the 300% multiplier for controlled swaps.

```bash
export ZERO_FOR_ONE=false
export SWAP_AMOUNT_IN=50000000
export SWAP_AMOUNT_OUT_MINIMUM=25000000000000000

forge script script/SwapBaseCanary.s.sol:SwapBaseCanary \
  --rpc-url "$BASE_RPC_URL" --broadcast --slow \
  --gas-estimate-multiplier 300
```

## Monitoring

```bash
export POOL_ID=<printed-pool-id>
export EXPECTED_OWNER=<owner-wallet>
export EXPECTED_ITERATIONS=10
export AUTO_DISABLE=true

/Users/sterlingcrispin/miniconda3/bin/python3 scripts/monitor_base_canary.py \
  >> artifacts/base-canary-monitor.log 2>&1
```

The monitor treats a swap without settlement as a normal economic no-op. It
uses the kill switch only for owner/config drift, retained WETH/USDC, or a
settlement outside the configured profit and iteration bounds.

## Stop And Exit

Disable before removing liquidity:

```bash
forge script script/DisableBaseCanary.s.sol:DisableBaseCanary \
  --rpc-url "$BASE_RPC_URL" --broadcast --slow

forge script script/RemoveBaseCanaryLiquidity.s.sol:RemoveBaseCanaryLiquidity \
  --rpc-url "$BASE_RPC_URL" --broadcast --slow
```
