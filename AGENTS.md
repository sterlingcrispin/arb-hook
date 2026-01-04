# Repository Guidelines

Keep contract behavior, documentation, and regression tests consistent.
Use the pinned Foundry compiler and dependency versions for reproducible builds.

- Preserve callback authentication, atomic repayment, and balance invariants.
- Keep arbitrage attempts isolated with an explicit gas budget.
- Preserve deterministic registry traversal and route selection.
- Run relevant local tests and the runtime-size check after contract changes.
- Report gated fork suites as skipped unless they actually ran.
- Do not commit signing keys, RPC credentials, personal wallet details,
  deployment receipts, operator balances, or private financial records.
- Use portable paths and configuration supplied by the operator.

Tests and simulated trade results establish mechanics, not profitability or
deployment approval. Deployment requires a separate review of the exact source,
chain configuration, integrations, and operational controls.
