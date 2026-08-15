# Base WETH Canary Manifest

This is the exact first-stage Base canary market. Registration is append-only and order-sensitive. Do not add another reference pool before the initial deployment has been observed and stopped cleanly.

## Route Architecture

The two venues have different roles in one WETH/USDC round trip:

1. A user swaps USDC to WETH in the hooked Uniswap v4 pool.
2. That swap raises the WETH price in the v4 pool relative to the external reference.
3. `afterSwap` borrows WETH and counter-trades the same v4 pool from WETH to USDC.
4. The hook trades the received USDC back to WETH in canonical Uniswap v3.
5. The hook repays WETH and transfers all net WETH profit to the beneficiary encoded by the swap caller.

The v4 pool is therefore both the trigger and the first arbitrage leg. The external V3 pool supplies the comparison price and second leg. No unrelated market and no pre-existing external/external spread is required.

## Hooked V4 Pool

| Field | Value |
|---|---|
| Network | Base, chain ID `8453` |
| `currency0` | WETH `0x4200000000000000000000000000000000000006` |
| `currency1` | USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| LP fee | `500` hundredths of a basis point, or 0.05% |
| Tick spacing | `10` |
| Hook permissions | `afterSwap` only |
| Opening price source | Canonical Uniswap V3 WETH/USDC 0.05% |
| First position | Full range, bounded by explicit wallet-supplied WETH and USDC caps |

`script/InitializeArbHookCanaryPool.s.sol` reads the live reference price, initializes this PoolKey, and mints the first position through Base's canonical PositionManager. The pool ID depends on the final mined hook address.

## External Reference

Register exactly one pool under WETH:

| Order | Venue | Pool | Fee | `PoolType` | token0 | token1 |
|---|---|---|---:|---|---|---|
| 1 | Uniswap V3 | `0xd0b53D9277642d899DF5C87A3966A349A798F224` | `500` | `V3` | WETH | USDC |

The production route selects the first registered matching Uniswap V3 or PancakeSwap V3 pool for the triggering pair. Registration order is therefore the operator's reference-venue choice, not a runtime cheapest-pool auction.

`script/RegisterArbHookCanaryPools.s.sol` rejects the transaction unless this address has code and reports:

- factory `0x33128a8fC17869897dcE68Ed026d694621f6FDfD`;
- token0 WETH;
- token1 USDC; and
- fee `500`.

## Enabled Direction

The initial canary registers and configures WETH only. It supports:

```text
user: USDC -> WETH in v4
arb:  WETH -> USDC in v4 -> WETH in v3
profit token: WETH
```

A WETH-to-USDC user swap has USDC as its output and potential flash principal. It will not attempt arbitrage until USDC has its own reviewed lender, cap, fee ceiling, profit floor, and matching reference registration under USDC.

## Lender And Limits

Use the WETH-bound Morpho adapter:

| Field | Value |
|---|---|
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
| Supported asset | WETH |
| Flash fee | 0 in the tested adapter path |
| Initial principal ceiling | `1 WETH` |
| Fee ceiling | `1` bp, the smallest nonzero enabled value |
| Provisional minimum net profit | `0.0001 WETH` |

The 1 WETH value is only a ceiling. Live route math chooses the amount from post-swap spread and active liquidity. The current-head 100 USDC fork rehearsal selected about `0.0089 WETH`, more than 100 times below the cap.

Recheck lender liquidity, fee behavior, gas, and the profit floor immediately before broadcast.

## Canonical Base Contracts

| Contract | Address |
|---|---|
| Uniswap V4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Uniswap V4 PositionManager | `0x7C5f5A4bBd8fD63184577525326123B519429bDc` |
| Uniswap Universal Router | `0x6fF5693b99212Da76ad316178A184AB56D299b43` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Uniswap V3 factory | `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |

Recheck these against current official deployment sources and confirm runtime code on the deployment RPC before broadcast.

## Current Evidence

`foundry/test/ArbHookWethCanaryFork.t.sol` runs against an unpinned Base fork and proves:

- CREATE2 mining of an after-swap-only hook;
- canonical PoolManager, PositionManager, Permit2, and Universal Router integration;
- canonical WETH/USDC V3 reference registration;
- WETH-bound Morpho borrowing and exact zero-fee repayment;
- full-range v4 LP mint and withdrawal;
- a normal 100 USDC-to-WETH trigger with packed beneficiary data;
- adaptive direction and principal selection without a supplied hint;
- bounded execution price limits on both swap legs;
- a counter-swap against the same v4 pool that triggered the hook;
- a Uniswap V3 WETH exit leg;
- positive WETH beneficiary payout; and
- zero residual WETH and USDC in the hook.

At Base block `50018535`, the proof borrowed `0.008907102809547629 WETH`, paid `0.000427463494774361 WETH`, paid zero lender fee, and measured about `419546` incremental gas. The test did not manufacture an external-pool dislocation. Its own v4 swap created the captured edge.

These values are a settlement proof, not expected production yield.
