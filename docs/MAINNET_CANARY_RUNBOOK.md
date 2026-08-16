# Retired Base Mainnet WETH Canary Runbook

> **DO NOT USE THIS RUNBOOK FOR A DEPLOYMENT.**

The WETH/USDC canary described by the former version of this file has been retired. Its production path performed one counter-trade against the hook's own v4 pool. That path has been removed from `ArbHook` and its strategy-specific scripts and fork tests have been deleted.

The retired instructions are not compatible with current bytecode:

- current `afterSwap` scans registered external pools and never trades the triggering v4 pool;
- `hookMaxIterations` is once again the real iterative executor bound;
- the per-PoolId trigger floor no longer exists;
- one registered WETH/USDC V3 pool is insufficient because discovery needs distinct buy and sell venues;
- no project-owned v4 liquidity is required; and
- the old principal/profit calibration measured a different strategy and must not be reused.

The deployed research hooks are disabled and their LP positions were burned. Transactions, addresses, balances, and the reason for retirement remain in [`BASE_WETH_CANARY_DEPLOYMENT.md`](BASE_WETH_CANARY_DEPLOYMENT.md).

A replacement runbook must be written from a reviewed release commit after all of the following are known:

1. The exact external pool book and registration order.
2. At least two viable venues for every enabled base/counter pair.
3. Current lender bindings, principal ceilings, fee ceilings, and net-profit floors.
4. Current fixed-block and current-head fork results for the production callback path.
5. Runtime byte size and gas requirements for the actual pool-book depth.
6. The expected rate at which unrelated v4 callbacks coincide with external opportunities.

Until that work exists, keep `hookMaxIterations = 0` on any deployed hook.
