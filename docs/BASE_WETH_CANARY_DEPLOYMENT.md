# Base WETH Canary Deployment

## Active 5 bp Canary

The reviewed hook at `0x079a5f5231a34C60E60090f7C0CcF333510A4040`
is active against a new 5 bp WETH/USDC pool. The hook bytecode, reference
registrations, flash adapters, range width, and execution controls are unchanged
from the preceding 10 bp epoch.

| Pool field | Value |
|---|---|
| Pool ID | `0xd18a99e2b8363ed02a75863dbbc5b05501a41a708240b9fd038c0f97aaa2e0de` |
| Position NFT | `2917608` |
| Position liquidity | `1626294573145581` |
| Pool fee | `5 bp` |
| Tick range | `-201190..-200580` |
| WETH principal | `0.566572455855413364` |
| USDC principal | `1,069.116219` |
| Pool initialization and mint | `0xcea6823f4d55885e197538015bcbc14afc21b021626c1ac7ced0de325534191f` |
| Enable ten rounds | `0xf9d10962947a75c70ccfb763f42b194c5b8cdfc424ae56db1a3d868da724b950` |
| Accounting start block | `50071787` |

### 5 bp Relaunch

| Action | Transaction |
|---|---|
| Disable execution | `0xc3b643999c72bdffa5f7dfba7488ab150c8465ab73ced7f19bc9fac985a51af1` |
| Disable WETH borrowing | `0x9d1982f0a41422adff0ad0632a291dd4817d297622fd0d4404144b9975257356` |
| Disable USDC borrowing | `0x4cc7fec73f2e54f69d49d774a1e17b46128f3644ebf33770abaef462927263a5` |
| Close 10 bp NFT `2916720` | `0x0f747a518f6a4f48810f9bbf5589959903f7ac12527b22f83ae7d113bfc40d41` |
| Rebalance `262 USDC` to WETH | `0xce2bc8d599e124366df8eda734c8898ad3bae41f7283e27bcc8b5e0ee6136551` |
| Initialize 5 bp pool and mint NFT `2917608` | `0xcea6823f4d55885e197538015bcbc14afc21b021626c1ac7ced0de325534191f` |
| Restore WETH borrowing | `0x422c33fd7acb2335781f3ccb3dfa1ed3a5f1e554cf544765d5adfbe0ad9d1cbb` |
| Restore USDC borrowing | `0xfdba0b0309f9ff642cb3c15a66f4aaaecc88197feec78b32ff186ebbb256b80a` |
| Enable ten rounds | `0xf9d10962947a75c70ccfb763f42b194c5b8cdfc424ae56db1a3d868da724b950` |
| Controlled 1 USDC swap | `0x2f0f853c8a888e60c274a7e9318667481f028ddad9118e6334c479ab22655873` |

The closed position returned `0.427842531960916051 WETH` and
`1,333.203923 USDC`, including accrued LP fees. Rebalancing produced a roughly
symmetric replacement while retaining approximately `0.011 ETH` for gas. The
PositionManager's global token counter advanced between script simulation and
the mint transaction, so the predicted token ID was `2917607`; the mint receipt
proves that the owner received the actual NFT `2917608`.

The controlled swap exchanged `1 USDC` for `0.000529261550885832 WETH` through
the canonical Universal Router. The hook was enabled for ten rounds, both
adapters remained empty, and no settlement was emitted because the trade did
not create a profitable gap. A Forge-generated transaction with insufficient
gas reverted atomically before the successful `4.5M`-gas retry; this confirms
the configured hook gas floor remains enforced.

By Base block `50072002`, the new pool had already received four third-party
transactions totaling `359.880103 USDC` of notional. Transaction
`0x2263ad5ddcd20c650d1d6f32ab11e4c3873dfe5a76f6a30029c014146bbcaf15`
triggered ten profitable rounds from a `205.663560 USDC` swap and retained
`0.000124772601852537 WETH` in the hook. This is initial execution evidence,
not a durable traffic or return estimate.

The automatic kill-switch monitor runs in tmux session
`arb-hook-canary-079a`; its current log is
`artifacts/base-canary-monitor-079a-5bp.log`. The dashboard accounting and event
index start fresh at block `50071787`; prior LP fees and hook revenue are opening
capital rather than current-epoch profit.

## Closed 10 bp Canary

This section records the immediately preceding pool from source commit
`57a0cfb`. NFT `2916720` is burned with zero liquidity; the same hook remains
active only through the 5 bp pool documented above.

| Artifact | Address | Deployment transaction |
|---|---|---|
| `ArbitrageLogic` | `0x4B2FA891c57b3919aac9e55391Eb61E731957873` | `0x528e1d7c9d46d4033a0636e1b00a4d368f48a4b241974840397284853323cfaa` |
| WETH Morpho adapter | `0x2a7911Afdb539B776579F9ce04C7d292C5A0a1F3` | `0xc80507ff00a610bb284baa7cc8e2bc1bd229e5ee1d3665a5ad67afde6f9eb4d0` |
| USDC Morpho adapter | `0x5c192911f3e5AAaf244ba9d133A3A81010bCA459` | `0x98163735c4f4e38bfc3f5a0d696bc662b8012276d511fa2bae37a7c9fecb1829` |
| `ArbHook` | `0x079a5f5231a34C60E60090f7C0CcF333510A4040` | `0x4bd7ad50da8ee707a31c6e47457c52c33170f0630ace7b6c6d89aaca53854bdc` |

The hook requests only `afterSwap`; its low permission bits are `0x0040`.

| Pool field | Value |
|---|---|
| Pool ID | `0x2d92e3aff6dc298dab4bea46e759156162777da3636d43424254ffbdbc4466db` |
| Position NFT | `2916720` |
| Position liquidity | `1628106437688273` |
| Tick range | `-201260..-200650` |
| WETH principal at relaunch | `0.589761878443739373` |
| USDC principal at relaunch | `1,028.015276` |
| Final mint | `0xbc0edaf85e4d722ac278e117a6517f7c70d84baca00828607c631f1dc6dd78a3` |
| Enable ten rounds | `0x6f95511f39ba8a958663163ec6da9ddad3a163bad44abc3e3294740a1a9a2cc4` |
| Relaunch block | `50069285` |

### Position Relaunch

The original NFT `2913425` was closed with zero remaining liquidity. Wallet
capital was rebalanced against the configured PancakeSwap V3 reference pool,
then reminted into the same v4 pool and range. The final operator balance was
`0.011151056246671743 ETH`, approximately `$20.91` at the relaunch reference
price. Only token dust remained outside the strategy.

| Action | Transaction |
|---|---|
| Disable execution | `0x78f60b3d3c2963ac4e90271c66e709eee406ddced13ebc695161d76dfa5a0d6f` |
| Disable WETH borrowing | `0x0ef7aad1f9fe84a341a1a07130856bf6bc54aa7873ae4d6b3272a93ce876cd08` |
| Disable USDC borrowing | `0xcc53186058da99d43c587fcf732547cbd4e1395f5bc3c4ee75ec34f5f316dbd1` |
| Close NFT `2913425` | `0x08090b6379b8e1cde8e59a74c81d98630d9e66c721641e956b9a9d86f15fa9ed` |
| Wrap wallet ETH | `0x2cdc02346e7f10a5cbc4717f905831b8f16971b87c013ad7bc847bf4395fc372` |
| Rebalance WETH to USDC | `0x1695b652d81161008c8db6a4c84c8745ea025074db97666b28515aef9fd24e9a` |
| Close provisional NFT `2916697` | `0x4acb36ee0a5cca85dab91872f31be413f91bc90f45c619cc728bbbe57e11ff12` |
| Mint final NFT `2916720` | `0xbc0edaf85e4d722ac278e117a6517f7c70d84baca00828607c631f1dc6dd78a3` |
| Restore WETH configuration | `0x575f1da7e9602dff5993c16c1e20a2a6e2d6c564a79e5d4afe686c9af16c5849` |
| Restore USDC configuration | `0xdea1aa3e370045df1ff44a420ab7c217f1239e655611458ce1946655aadebcb0` |
| Enable ten rounds | `0x6f95511f39ba8a958663163ec6da9ddad3a163bad44abc3e3294740a1a9a2cc4` |

The provisional NFT was opened while execution remained disabled, then closed
when its computed range differed from the prequoted range by one tick-spacing
step. The final mint pins `-201260..-200650` explicitly. NFTs `2913425` and
`2916697` both report zero liquidity.

At relaunch, the hook already held `0.002070361754776988 WETH` earned during
the prior position epoch; both adapters held zero. The dashboard preserves that
balance in strategy value but treats it as opening capital, so relaunch P&L and
retained revenue both begin at zero at block `50069285`.

### Previous-Epoch Controlled Swap

Transaction `0xb0f1a93ae4fb495723a8c7237f2f0c459fbf418c4bd88a20168410c5f5844eab`
swapped 50 USDC for `0.026562851994812012 WETH`. The hook borrowed
`0.0027 WETH`, traded `0.023050022309536079 WETH` over ten rounds, repaid
Morpho with zero fee, and retained `0.000093783763919242 WETH` for the owner.
The hook balance exactly matched that event and both adapter balances remained
zero.

The swap used a `4,459,209` gas limit and consumed `1,387,508` gas. Its L2
execution gas was about `$0.025` at the contemporaneous WETH reference price,
before the receipt's L1 data fee.

### Previous-Epoch Organic Observation

Through Base block `50064407`, the pool received 23 third-party transactions
after the controlled swap, totaling about `455.64 USDC` of notional across both
directions and six non-canonical transaction targets. Two produced profitable
ten-round hook settlements:

| Trigger transaction | Trigger size | Retained WETH profit |
|---|---:|---:|
| `0x430c968d72ae09afc419986c41f9dc7c0ad688875fd55126b6ece98375b0f1c6` | `71.701586 USDC` | `0.000098362506912760` |
| `0x0aa19f1b5e06bfb47cac32af72f8f204243ccb0c341335e292a4d4bbde426609` | `180.712651 USDC` | `0.000527459829378727` |

Total retained hook revenue at that snapshot was
`0.000719606100210729 WETH`. No invariant was violated. This proves immediate
external route discovery and actual third-party revenue, not sustained volume
or a long-term return rate.

The 10 bp epoch used tmux session `arb-hook-canary-079a`; its historical log is
`artifacts/base-canary-monitor-079a.log`.

## Retired Canaries

### Latest Closed Canary

The multi-round hook `0x431380080801E04D5D886390E40c84323E37c040`
is disabled (`hookMaxIterations = 0`) and holds no WETH or USDC. Its WETH/USDC
pool ID is `0x75082c78b2212356872e0f4f7856e97b32e77adabe0401c6c6e82893f28c7a13`.
Position NFT `2912936` was burned and `ownerOf` now reverts.

| Closure action | Transaction |
|---|---|
| Disable hook | `0x5e9cf4f0b854757741d265cdfd9c10bcedd04800905220e7654c0281fc887bd4` |
| Burn position and withdraw liquidity | `0x1a49a491ad847232ee21b96ba2753e5ac62ffb094b7a3587233dafab1d331fe5` |
| Revoke Permit2 router/PositionManager allowances | `0x3afe5a10504beee33d1b10dd939539a73a2a786b64343457587dab4b7afeac6d` |
| Revoke residual WETH-to-Permit2 approval | `0x6211e7ff5b1256f6eccf05d6fc3df7891913754566eed5f58603c0c15255b44e` |

The burn returned `0.140536465569262201 WETH` and `231.046985 USDC` to the
operator wallet. ERC20-to-Permit2 and Permit2-to-PositionManager/Universal
Router allowances are zero for both WETH and USDC.

### Earlier One-Round Canaries

The replacement research canary has been retired. Hook
`0x7e8d44E0eAfB387a91a630536d934bbb1Ca34040` is disabled, its WETH flash
principal ceiling is zero, and its full-range WETH/USDC position NFT `2909998`
has been burned. The hook remains deployed as historical research evidence but
has no liquidity or token balances.

The first hook `0xC537EDE696EAC0014A30a51706fb5E95C2734040` is disabled and holds no
tokens. Its position NFT `2909971` was burned after the replacement settled a
live RPC-estimated transaction.

### One-Round Replacement Contracts

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

### One-Round Replacement Pool

| Field | Value |
|---|---|
| Pool ID | `0x21f1bb25f9226f19d056d047dff68e15d3ff56a17e0a70c9791896452d02371c` |
| Pair | WETH/USDC |
| LP fee | `500` (0.05%) |
| Tick spacing | `10` |
| Position NFT | `2909998` (burned) |
| Position owner | None (`ownerOf` reverts `NOT_MINTED`) |
| Position liquidity | `0` (initially `2305313247698`) |
| Initialize and mint transaction | `0x49cff08a1c4b509b083906a0ce2fb3c66d95a04fb9bf8118ace4fc9bd92aa62c` |
| Opening sqrt price | `3436763424379252776215504` |
| Post-canary tick | `-200915` |

The pool remains initialized, but position NFT `2909998` has been burned and
its liquidity is zero.

The mint consumed `0.053144691700125703 WETH` and exactly `100 USDC`. The
external reference is canonical Uniswap V3 WETH/USDC 0.05% at
`0xd0b53D9277642d899DF5C87A3966A349A798F224`. Reference registration transaction:
`0x7d82aa8677008ce213d9b6f69013a477203eb7949cce51115f6c5720d23239a2`.

### One-Round Replacement Configuration

| Setting | Value |
|---|---:|
| Maximum hook attempts | `0` (disabled; controlled value was `1`) |
| Minimum spread | `10` bps |
| Chunk spread consumption | `1500` bps |
| Maximum modeled impact | `500` bps |
| Gas reserve | `200,000` |
| Required attempt budget and ceiling | `3,000,000` |
| WETH lender | `0x54329f5B9b4079E9C4B8bda26F046Ad8c7Ac08a9` |
| WETH principal ceiling | `0` (controlled value was `0.005 WETH`) |
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

### One-Round RPC-Estimated Canary

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

### First Deployment Retirement

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

### Retired Balances And Exit

The replacement position was retired after the controlled transaction showed
that one bounded hook counter-trade did not consume the full edge. A separate
transaction immediately after it in the same block counter-traded the v4 pool
against Hydrex Integral. That transaction,
`0xf2398ab3eb7096450224cb624d46800270b69f638d5bb628f63f4ab47debe176`,
retained `0.000326008570667335 WETH` before gas, versus the hook route's
`0.000153175872232624 WETH`. The hook therefore redirected part of the
LP-funded price movement to the swap initiator while leaving additional
LP-funded value for an external searcher. Adding more operator liquidity was
rejected as the next step.

| Action | Transaction |
|---|---|
| Disable replacement hook | `0x6a3c57320c329d98f613b6e4bd22794ed55781059e9c17eee36eb4045fe3330e` |
| Set WETH principal ceiling to zero | `0x6023c9147172aba0eb86c50306551284ec1cdf88ee8f4e60862af5581ab89161` |
| Burn replacement position | `0x8500504e30486f7e4b6eebab5f7f9b6adfc96155c4589921ea0e23dc00b369f3` |

Burning NFT `2909998` returned:

- `0.053130079473601032 WETH`
- `100.037035 USDC`

After the exit, the operator wallet held:

- `0.112974782843028226 WETH`
- `604.374770 USDC`
- `0.045015450956452899 ETH`

The old hook, replacement hook, and both replacement adapters each hold zero
WETH and zero USDC. Replacement NFT `2909998` reports zero liquidity and
`ownerOf(2909998)` reverts with `NOT_MINTED`.
