# Base WETH Canary Deployment

## Current Status

The replacement research canary is live on Base mainnet from contract commit
`284fe20`. Hook `0x7e8d44E0eAfB387a91a630536d934bbb1Ca34040` is enabled for one bounded
V4/V3 attempt. Its full-range WETH/USDC position is NFT `2909998`.

The first hook `0xC537EDE696EAC0014A30a51706fb5E95C2734040` is disabled and holds no
tokens. Its position NFT `2909971` was burned after the replacement settled a
live RPC-estimated transaction.

## Current Contracts

| Artifact | Address | Deployment transaction | Sourcify |
|---|---|---|---|
| `ArbMath` | `0x4038F4F2a91AcC94a2f8A65e0e51E55FB364BE50` | Reused from first deployment | Exact match |
| `ArbitrageLogic` | `0x30e472Fa4eBB7Fc9abC5E671382dEA7A5E718B15` | `0xb11600c77d9a1f21d46f589d2f0d05430fad802315430da6bfee369e116ae1de` | Match with linked `ArbMath` |
| `AaveV3ERC3156Adapter` | `0xd22aDc67E2607a9E95262022F7AC061b579bDeD9` | `0x149d8be487386d9c3cdf1b3ef6737c4fbf53db31cb413ba2801376b4ddabd046` | Exact match |
| `MorphoERC3156Adapter` | `0x54329f5B9b4079E9C4B8bda26F046Ad8c7Ac08a9` | `0x3e98505928806315516c0a7797a890f63f3b6d47f37dcc843f699818d39d3ec6` | Exact match |
| `ArbHook` | `0x7e8d44E0eAfB387a91a630536d934bbb1Ca34040` | `0xd734addd8531b20fc4995ea67c9e19b12b9e4a27a9dc9be4321655a274c49313` | Exact match |

The hook used CREATE2 salt `0x9d52`. Its low permission bits are `0x0040`,
which enables only `afterSwap`. Runtime sizes are `22,215` bytes for `ArbHook`,
`19,678` for `ArbitrageLogic`, `5,779` for `ArbMath`, `2,590` for the Aave
adapter, and `2,144` for the Morpho adapter.

## Current Pool

| Field | Value |
|---|---|
| Pool ID | `0x21f1bb25f9226f19d056d047dff68e15d3ff56a17e0a70c9791896452d02371c` |
| Pair | WETH/USDC |
| LP fee | `500` (0.05%) |
| Tick spacing | `10` |
| Position NFT | `2909998` |
| Position owner | `0x38580D3E838EdE8E6770Ae80881Cf71BaD2530aB` |
| Position liquidity | `2305313247698` |
| Initialize and mint transaction | `0x49cff08a1c4b509b083906a0ce2fb3c66d95a04fb9bf8118ace4fc9bd92aa62c` |
| Opening sqrt price | `3436763424379252776215504` |
| Post-canary tick | `-200915` |

The mint consumed `0.053144691700125703 WETH` and exactly `100 USDC`. The
external reference is canonical Uniswap V3 WETH/USDC 0.05% at
`0xd0b53D9277642d899DF5C87A3966A349A798F224`. Reference registration transaction:
`0x7d82aa8677008ce213d9b6f69013a477203eb7949cce51115f6c5720d23239a2`.

## Live Configuration

| Setting | Value |
|---|---:|
| Maximum hook attempts | `1` |
| Minimum spread | `10` bps |
| Chunk spread consumption | `1500` bps |
| Maximum modeled impact | `500` bps |
| Gas reserve | `200,000` |
| Required attempt budget and ceiling | `3,000,000` |
| WETH lender | `0x54329f5B9b4079E9C4B8bda26F046Ad8c7Ac08a9` |
| WETH principal ceiling | `0.005 WETH` |
| Maximum lender fee | `1` bp |
| Minimum net route profit | `0.0001 WETH` |
| USDC-to-WETH input gate | `10 USDC` |

Configuration transactions:

| Setting | Transaction |
|---|---|
| Lender | `0x167bf9f58e79c57b0781901581f699c68fab67742c3441e312ff4cac5ba21b1b` |
| Fee ceiling | `0xb752928e24521cd7d960474c80aafbe312c7af9bbef54e589032c9ef45c993c8` |
| Profit floor | `0x08569e0d2f5edc00a3e04cfa11018cd6c10879d1b8bf5251893fb4a3833c1ccb` |
| Principal ceiling | `0x09e39a2a62f8f9c9c248716115d9bbe5e88352786a09049da1f8967daef9d656` |
| Input gate | `0x958f6831095269ebef6fcd6b6f4092767e0a276c7f415448f97c16d5aa11b328` |
| Enable | `0xa9200e151a764342b06baf93e813c7ab88ab7a60cb8e5056b75bfa1fc94a899c` |

## RPC-Estimated Canary

The replacement launch generated fresh Universal Router calldata, set exact
one-swap USDC and Permit2 allowances, and requested `eth_estimateGas` from the
Base RPC. The RPC returned `3,514,705` gas. The transaction consumed `454,936`;
the unused limit was not charged.

| Field | Value |
|---|---:|
| Transaction | `0x16a597c30f2c2feba6668f02890b536a3fbdf9e7e346e4cdb8fc78541dae471b` |
| Block | `50031938` |
| USDC input | `10 USDC` |
| Protected minimum output | `0.004780847561621046 WETH` |
| Normal WETH output | `0.004829138951132370 WETH` |
| Flash principal | `0.000811651931448483 WETH` |
| Principal traded | `0.000811651931448483 WETH` |
| Morpho fee | `0 WETH` |
| Net route profit | `0.000153175872232624 WETH` |
| Total wallet WETH increase | `0.004982314823364994 WETH` |
| Beneficiary | `0x38580D3E838EdE8E6770Ae80881Cf71BaD2530aB` |
| L2 execution plus L1 data fee | `0.000002275646603574 ETH` |

The route profit was 67.31 times the router transaction fee. This compares the
beneficiary payout with gas, not the operator's total economic outcome as both
LP and beneficiary. The receipt records equal principal transfers out of and
back into Morpho. The hook and both adapters retain zero WETH and zero USDC.

Forge's script broadcaster does not preserve the required unused gas envelope:
it derives a transaction limit from measured gas consumption. Use RPC estimation
for the release proof or a deliberately sufficient Forge multiplier. Always
regenerate dry-run calldata immediately before sending because its Universal
Router deadline is ten minutes.

## First Deployment Retirement

The first hook demonstrated settlement but allowed automatic gas estimation to
select a successful no-arbitrage branch. Transaction
`0xcf849ad5ccc4a845217ca2bd0eefd42a8e75dcedb9704d0d81ce2a3ff2f39a42`
settled an ordinary swap after its 297,092-gas attempt ran out of gas. A later
controlled transaction with a larger envelope proved the route itself.

After the replacement settled:

| Action | Transaction |
|---|---|
| Disable first hook | `0x19375884bb1e60c1e58532abb53bf5af6b855948bc6a895cac9236999826a572` |
| Burn first position | `0x8554cd5d09292a0177847e76c31f4489f1e9132e0704bd66552ccf206608e603` |

Burning NFT `2909971` returned `0.053196931435194189 WETH` and `99.919323 USDC`.
Its liquidity now reads zero and `ownerOf(2909971)` reverts with `NOT_MINTED`.

## Current Balances And Exit

After migration, the operator wallet held:

- `0.059844703369427194 WETH`
- `504.337735 USDC`
- `0.045016816369054533 ETH`

The old hook, replacement hook, and both replacement adapters each held zero
WETH and zero USDC. A post-settlement replacement withdrawal simulation passed
without broadcasting and would return:

- `0.053130079473601032 WETH`
- `100.037035 USDC`

To stop attempts, call `setHookMaxIterations(0)` on the replacement hook. To
exit fully, disable first and follow `docs/MAINNET_CANARY_RUNBOOK.md` with fresh,
nonzero withdrawal minima.
