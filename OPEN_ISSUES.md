# Open Issues

## Context
This tracker captures deferred or follow-up items while hardening ArbHook toward a deployable state.

## Deferred

1. Max impact guard is not enforced in execution path
- Status: `OPEN`
- Priority: `HIGH`
- Summary: `_MAX_IMPACT_BPS` is configured on `ArbHook`, but current chunk selection path does not actively reject trades when computed impact exceeds the configured cap.
- Impact: Operators may assume impact protection that is not currently enforced.
- Planned fix: enforce a hard stop when estimated impact exceeds configured threshold in the V3 path (and equivalent guard in mixed/V2 paths where applicable).

2. Pancake V2 fee modeling consistency
- Status: `OPEN`
- Priority: `MEDIUM`
- Summary: Pancake V2 is configured as `2500 ppm` in pool metadata, while some V2 math helpers still use Uniswap-style `997/1000` constants.
- Impact: Price/quote/profit simulation drift for Pancake V2 routes.
- Planned fix: route all V2 math through fee-parameterized helpers and remove hardcoded `997/1000` from generalized paths.

## Recently Addressed

1. ArbHook runtime size over EIP-170
- Status: `ADDRESSED`
- Notes: Removed heavy debug/log code and trimmed non-essential runtime paths; `ArbHook` runtime now compiles below the 24,576-byte limit.

2. Public execution surface for `executeIterativeArb`
- Status: `ADDRESSED`
- Notes: Restricted to self-call only via `ArbErrors.WrapperOnlySelf`.

3. Callback acceptance for unregistered V2 pools
- Status: `ADDRESSED`
- Notes: V2 callbacks now require caller to be a registered V2 pool in local pool metadata in addition to canonical factory pair validation.

4. Stale legacy JS-tooling references in active workflow
- Status: `ADDRESSED`
- Notes: Package scripts and project instructions were updated to Foundry-first commands.
