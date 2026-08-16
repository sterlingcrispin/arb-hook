# Retired Base WETH Canary Manifest

> **HISTORICAL ONLY. DO NOT REGISTER OR FUND THIS MARKET FROM THIS FILE.**

This manifest described the retired deployed one-round self-pool strategy:

```text
trigger: user swaps USDC -> WETH in hooked v4
retired route: WETH -> USDC in the same v4 pool -> WETH in external v3
```

The live experiment proved flash borrowing and repayment, but the hook consumed only one bounded step. An external backrunner immediately captured additional value from the same LP position. The operator disabled the hook, zeroed the WETH principal cap, and burned the position.

Current source keeps the same causal venue relationship but replaces the
one-round stopgap:

- the triggering v4 pool is the first leg;
- one registered V3-compatible pool for the same pair is the return leg;
- every round rereads both venues and derives a new bounded chunk;
- `hookMaxIterations` bounds rounds inside one flash loan; and
- there is no PoolId-specific minimum trigger amount.

The former manifest's `0.005 WETH` cap, `10 USDC` trigger floor, and
`$100`-per-side LP profile are not valid current configuration. The old
operational scripts were removed to prevent accidental reuse. A new deployment
requires fresh current-head loop, gas, and LP-economic calibration.

Historical deployment evidence is preserved in [`BASE_WETH_CANARY_DEPLOYMENT.md`](BASE_WETH_CANARY_DEPLOYMENT.md). Current architecture and configuration semantics are in [`../README.md`](../README.md) and [`ARB_LOGIC_DEEP_DIVE.md`](ARB_LOGIC_DEEP_DIVE.md).
