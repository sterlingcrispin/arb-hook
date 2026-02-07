# Review Scope

This file lists areas to assess for the source revision being reviewed. It is
not a claim that every historical revision implements the same protections.

- Authenticate hook entry points, flash-loan callbacks, and swap callbacks.
- Verify repayment, realized profit checks, and preservation of existing balances.
- Verify intermediate-token restoration and failure containment.
- Check directional pool registration, token units, pricing, and sizing limits.
- Measure gas admission, attempt budgets, and deployed runtime size.
- Distinguish real execution tests from mocks and gated fork integrations.
- Review token, pool, lender, ownership, and chain assumptions before use.
- Evaluate total LP and hook accounting separately from route-level revenue.

Private deployment records and wallet financial results are not published.
