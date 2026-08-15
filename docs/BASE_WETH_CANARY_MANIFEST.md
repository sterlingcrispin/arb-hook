# Base WETH Canary Manifest

This is the exact first-stage market manifest for the Base canary. Registration
is append-only and order-sensitive. Do not substitute pools or add a second
market during the initial launch.

Market data below is a point-in-time screening snapshot from 2026-08-15 near
Base block `50011045`. Volume and liquidity are indexer estimates and will
change. Contract identity, token ordering, factories, and fees were also read
directly from Base at that block.

## Architecture Boundary

The canary has two separate pool roles:

- The **trigger pool** is a new hooked Uniswap V4 WETH/USDC pool. Its swaps call
  `afterSwap`; it is not one of the pools compared by the route planner.
- The **arbitrage market** is cbBTC/WETH across two existing external pools.
  The hook compares those pools, borrows WETH, trades WETH to cbBTC and back,
  repays WETH, and sends remaining WETH to the trigger-swap beneficiary.

A USDC-to-WETH trigger can therefore earn unrelated cbBTC/WETH arbitrage profit
without requiring a price discrepancy among WETH/USDC pools.

## Trigger Pool

| Field | Value |
|---|---|
| Network | Base, chain ID `8453` |
| `currency0` | WETH `0x4200000000000000000000000000000000000006` |
| `currency1` | USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| LP fee | `500` hundredths of a basis point, or 0.05% |
| Tick spacing | `10` |
| Hook | The release deployment of `ArbHook` |
| Opening price source | Uniswap V3 WETH/USDC 0.05% `0xd0b53D9277642d899DF5C87A3966A349A798F224` |
| First position | Full range, with explicit WETH and USDC wallet caps |

`script/InitializeArbHookCanaryPool.s.sol` creates this PoolKey and mints the
first position through Base's canonical PositionManager. The pool ID depends on
the final hook address and cannot be known before deployment.

## External Pool Book

Register both entries under WETH in exactly this order:

| Order | Venue | Pool | Fee | `PoolType` | token0 | token1 |
|---|---|---|---:|---|---|---|
| 1 | PancakeSwap V3 | `0xC211e1f853A898Bd1302385CCdE55f33a8C4B3f3` | `100` | `PANCAKESWAP_V3` | WETH | cbBTC |
| 2 | Uniswap V3 | `0x7AeA2E8A3843516afa07293a10Ac8E49906dabD1` | `500` | `V3` | WETH | cbBTC |

Canonical cbBTC is
`0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf`. The registration script rejects
the transaction unless each pool's code, factory, token ordering, and fee match
this manifest.

Snapshot screening data:

| Pool | 24h volume | Liquidity | Screening link |
|---|---:|---:|---|
| PancakeSwap V3 cbBTC/WETH 0.01% | ~$12.04M | ~$4.80M | [DexScreener](https://dexscreener.com/base/0xc211e1f853a898bd1302385ccde55f33a8c4b3f3) |
| Uniswap V3 cbBTC/WETH 0.05% | ~$3.28M | ~$6.02M | [DexScreener](https://dexscreener.com/base/0x7aea2e8a3843516afa07293a10ac8e49906dabd1) |

This is the strongest first market because it has two independently deployed,
already-supported concentrated-liquidity pools, high current flow on both, and
only 6 bps of combined pool fees for a two-leg route. These facts improve the
chance of executable dislocations; they do not guarantee that one exists on any
particular swap.

## Compatible Follow-On Markets

Do not register these in the first deployment. Each addition increases callback
gas and changes traversal order, so it needs its own current-head route rehearsal.

| Priority | Market | Supported pools | Snapshot 24h volume | Reason deferred |
|---|---|---|---:|---|
| 2 | VIRTUAL/WETH | Uniswap V3 `0x9c087Eb773291e50CF6c6a90ef0F4500e349B903`; Uniswap V2 `0xE31c372a7Af875b3B5E0F3713B17ef51556da667` | ~$450K + ~$57K | Compatible mixed V3/V2 route, but far less flow and depth than cbBTC |
| 3 | AERO/WETH | Uniswap V3 `0x3d5D143381916280ff91407FeBEB52f2b60f33Cf`; PancakeSwap V3 `0x20CB8f872ae894F7c9e32e621C186e5AFCe82Fd0` | ~$39K + ~$31K | Supported venues are small; most AERO liquidity is on unsupported Aerodrome |

The current runtime supports only Uniswap V2/V3 and PancakeSwap V2/V3 as
external arbitrage legs. Aerodrome, Uniswap V4, and other CLAMMs are not valid
registry entries. Several large Base WETH markets, including the dominant
cbBTC/WETH and liquid-staking-token venues, trade primarily on Aerodrome; their
volume is inaccessible until an Aerodrome executor and pricing path are added.

## Lender

Use the WETH-bound Morpho adapter for the first canary:

| Field | Value |
|---|---|
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
| Supported asset | WETH |
| Flash fee | 0 |
| WETH held at snapshot | ~77,743 WETH |
| Initial principal ceiling | At most 1 WETH; adaptive route math may choose less |
| Fee ceiling | 1 bp, the smallest nonzero enabled value |

The WETH balance is lender capacity, not a recommended loan size. The first
fork rehearsal reached the explicit 1 WETH ceiling and settled profitably, so
start no higher than that. Lowering the cap is safe but requires another
current-head rehearsal to ensure the route can still clear its profit floor.

## Canonical Base Contracts

| Contract | Address |
|---|---|
| Uniswap V4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Uniswap V4 PositionManager | `0x7C5f5A4bBd8fD63184577525326123B519429bDc` |
| Uniswap Universal Router | `0x6fF5693b99212Da76ad316178A184AB56D299b43` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Uniswap V3 factory | `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` |
| PancakeSwap V3 factory | `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865` |

Recheck all addresses against current official deployment pages immediately
before broadcast:

- [Uniswap V4 deployments](https://developers.uniswap.org/docs/protocols/v4/deployments)
- [Uniswap V3 Base deployments](https://developers.uniswap.org/docs/protocols/v3/deployments/v3-base-deployments)
- [PancakeSwap V3 addresses](https://developer.pancakeswap.finance/contracts/v3/addresses)
- [Morpho contract addresses](https://docs.morpho.org/developers/contracts/addresses/)

## Evidence

`foundry/test/ArbHookWethCanaryFork.t.sol` runs against an unpinned current Base
fork and proves the complete intended lifecycle:

- after-swap-only hook address mining against the canonical PoolManager;
- WETH-bound Morpho adapter and exact repayment at zero fee;
- this two-pool cbBTC/WETH registration order;
- hooked WETH/USDC initialization and LP mint through the canonical PositionManager;
- USDC-to-WETH trigger through the canonical Universal Router with packed beneficiary data;
- natural route, direction, and principal discovery without a supplied hint;
- positive WETH payout to the beneficiary and no WETH or cbBTC left in the hook.

The test creates a deterministic cbBTC/WETH dislocation so the full path always
executes. Its observed profit demonstrates settlement correctness, not expected
production yield.
