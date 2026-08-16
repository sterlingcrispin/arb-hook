# Retired Base Mainnet WETH Canary Runbook

> **DO NOT USE THIS RUNBOOK FOR A DEPLOYMENT.**

The WETH/USDC canary described by the former version of this file has been
retired. Its deployed bytecode performed only one counter-trade against the
hook's own v4 pool. Current source performs repeated live-repriced rounds, but it
has not been deployed and the old settings were calibrated for different code.

The retired instructions are not compatible with current bytecode:

- current `afterSwap` trades the triggering v4 pool against one registered
  V3-compatible reference for the same pair;
- `hookMaxIterations` bounds live sizing-and-swap rounds inside one flash loan;
- the per-PoolId trigger floor no longer exists;
- reference registration and lender economics are directional, so each enabled
  output token needs its own registration/configuration;
- the hooked v4 pool needs enough reviewed liquidity for the intended triggers;
  and
- the old principal/profit calibration measured one-shot bytecode and must not be reused.

The deployed research hooks are disabled and their LP positions were burned. Transactions, addresses, balances, and the reason for retirement remain in [`BASE_WETH_CANARY_DEPLOYMENT.md`](BASE_WETH_CANARY_DEPLOYMENT.md).

A replacement runbook must be written from a reviewed release commit after all of the following are known:

1. The exact v4 pair, fee, liquidity range, starting price, and LP capital.
2. At least one reviewed V3-compatible reference registered for every enabled
   output-token direction.
3. Current lender bindings, principal ceilings, fee ceilings, and net-profit floors.
4. Current fixed-block and current-head fork results for the production callback path.
5. Runtime byte size and gas requirements at the chosen iteration bound.
6. Trigger-size economics showing the loop clears venue fees, lender fees, and gas.
7. An explicit acceptance of the LP-to-beneficiary redistribution described in
   `OPEN_ISSUES.md` item 65.

Until that work exists, keep `hookMaxIterations = 0` on any deployed hook.
