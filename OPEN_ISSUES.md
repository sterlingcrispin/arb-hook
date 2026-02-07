# Open Issues

## Context
This tracker records the audit findings list and current disposition.

## Deferred

1. [Critical] ArbHook undeployable on EVM chains due to code size
- Status: `OPEN`
- Priority: `CRITICAL`
- Summary: Runtime code size exceeded EIP-170 deployment limit.
- Decision: deferred for now per current development priority.

## Addressed

2. Public execution surface for `executeIterativeArb`
- Status: `ADDRESSED`
- Notes: Entry point now reverts unless `msg.sender == address(this)` via `ArbErrors.WrapperOnlySelf`.

3. Callback acceptance for unregistered V2 pools
- Status: `ADDRESSED`
- Notes: `uniswapV2Call` and `pancakeCall` now require factory-valid pair plus registration in `poolMetaByAddr` as a V2/PancakeV2 pool with matching token ordering.

4. Max impact guard not enforced in execution path
- Status: `ADDRESSED`
- Notes: Mixed `V2 -> V3` execution now estimates projected V3-leg input impact and aborts attempts when it exceeds `_MAX_IMPACT_BPS`.

5. Pancake V2 fee modeling consistency
- Status: `ADDRESSED`
- Notes: V2 math/simulation/quote paths now use fee-parameterized logic (`feePPM`) instead of hardcoded `997/1000`.

6. Stale Hardhat/debug references in active workflow
- Status: `ADDRESSED`
- Notes: Removed direct `hardhat/console.sol` usage and active debug logging in runtime paths.
