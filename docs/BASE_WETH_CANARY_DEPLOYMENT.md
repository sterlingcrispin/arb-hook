# Base WETH Canary Deployment

## Status

The research canary was deployed on Base mainnet on 2026-08-15 from commit
`fca3ced712d1095d19cf7a783041daebc8577c43`. The hooked pool is funded and
`hookMaxIterations` is `1`, so one bounded V4/V3 attempt is enabled for each
eligible USDC-to-WETH swap.

This is a small research deployment, not a claim that generic organic router
traffic will always allocate enough gas. See `OPEN_ISSUES.md` item 69.

## Contracts

| Artifact | Address | Deployment transaction |
|---|---|---|
| `ArbMath` | `0x4038F4F2a91AcC94a2f8A65e0e51E55FB364BE50` | `0x3c47edcadb9d9d3fedead3134f866e3ab025b8e978892d0aed4ab1bcd357a905` |
| `ArbitrageLogic` | `0x1bf5395811a5e3aECa74E42160FCa5353262459A` | `0x91900b179a510dcceafbb011a37724de4b48d599edf5b68072cea8661ad53c57` |
| `AaveV3ERC3156Adapter` | `0xC26284bca5925c24d033F13b5F6C9B1Ab06fA4e8` | `0x15efdc22f95a88d3b0e9ab31a8005e850cc0b41d0a0a2295728aca27afeeab6f` |
| `MorphoERC3156Adapter` | `0xB83d23569c2d8ccb40e48AEeb650119EC0185340` | `0x1a5e97fac23ea405e1ec682eaa566507e57cf9348492219f38cd4573665eb2cd` |
| `ArbHook` | `0xC537EDE696EAC0014A30a51706fb5E95C2734040` | `0x124a1ce2d37ef9b455d6afefeaa7b9db618fd0e366012e25db258b8e8d2589f7` |

The hook was deployed with CREATE2 salt `0x05cf`. Its low permission bits are
`0x0040`, which enables only `afterSwap`.

Source publication was not performed because no BaseScan or Etherscan API key
was configured in the deployment environment. Runtime bytecode and constructor
bindings were checked directly on Base.

## Pool And Position

| Field | Value |
|---|---|
| Pool ID | `0x8b4f7738c31a9a530e4758c0965fc41f75cd10c817693dddbc00a590a190ad69` |
| Pair | WETH/USDC |
| LP fee | `500` (0.05%) |
| Tick spacing | `10` |
| Position NFT | `2909971` |
| Position owner | `0x38580D3E838EdE8E6770Ae80881Cf71BaD2530aB` |
| Position liquidity | `2305286840283` |
| Initialize and mint transaction | `0x187f76c19d9000db94e70a2f2420355af8bdfe3c33cc75dea55374d59c7026c2` |

The mint consumed `0.053143474159822212 WETH` and exactly `100 USDC`.
The external reference is canonical Uniswap V3 WETH/USDC 0.05% at
`0xd0b53D9277642d899DF5C87A3966A349A798F224`.

## Live Configuration

| Setting | Value |
|---|---:|
| Maximum hook attempts | `1` |
| Minimum spread | `10` bps |
| Chunk spread consumption | `1500` bps |
| Maximum modeled impact | `500` bps |
| Gas reserve | `200,000` |
| Attempt gas ceiling | `3,000,000` |
| WETH lender | `0xB83d23569c2d8ccb40e48AEeb650119EC0185340` |
| WETH principal ceiling | `0.005 WETH` |
| Maximum lender fee | `1` bp |
| Minimum net route profit | `0.0001 WETH` |
| USDC-to-WETH input gate | `10 USDC` |

The reference registration transaction is
`0xd1d6e41581ee37ea6a1726c0380e8139bb99c0731aa475cf1ff85a5ccb824f38`.

## Controlled Canary

The first protected 10 USDC transaction,
`0xcf849ad5ccc4a845217ca2bd0eefd42a8e75dcedb9704d0d81ce2a3ff2f39a42`,
proved the ordinary swap remained fail-open but did not settle arbitrage. Its
automatic `628,423` gas limit left `297,092` gas for the isolated attempt, which
ran out of gas. It emitted no `FlashLoanSettled` event and returned only the
ordinary `0.004829028214770908 WETH` output.

The hook was disabled while that receipt was traced, then re-enabled. The retry
used the same protected 10 USDC input with a four-times gas-estimate multiplier:

| Field | Value |
|---|---:|
| Transaction | `0x34f3564ddab4bd7e3f742e5c4b83d866362009e18a81343ab9f61e463efdd2fd` |
| Block | `50030860` |
| Transaction gas limit | `1,817,320` |
| Transaction gas used | `427,602` |
| Normal WETH output | `0.004824884801310788 WETH` |
| Flash principal | `0.000814750614084121 WETH` |
| Principal traded | `0.000814750614084121 WETH` |
| Morpho fee | `0 WETH` |
| Net route profit | `0.000154480306635182 WETH` |
| Total wallet WETH increase | `0.004979365107945970 WETH` |
| Beneficiary | `0x38580D3E838EdE8E6770Ae80881Cf71BaD2530aB` |

The receipt records equal WETH transfers out of and back into Morpho for the
principal. After settlement, the hook and both adapters held zero WETH and zero
USDC. The router transaction's L2 execution fee plus L1 data fee was
`0.000002193377352054 ETH`; the route profit was about 70.43 times that fee.
This compares the beneficiary's route payout with transaction gas, not the
operator's total economic outcome as both LP and beneficiary.

At the post-canary readback, the wallet held `0.009810148810993714 WETH`,
`514.418412 USDC`, and `0.090079168419441344 ETH`. The v4 pool tick was
`-200919`, close to its opening tick of `-200921`.

## Emergency Exit

A post-settlement removal simulation succeeded without broadcasting. Burning
position `2909971` would have returned:

- `0.053142953074783682 WETH`
- `100.020064 USDC`

To stop attempts without removing liquidity, call
`setHookMaxIterations(0)`. To exit fully, disable first and follow
`docs/MAINNET_CANARY_RUNBOOK.md` with current, nonzero withdrawal minima.
