import unittest

from server import liquidity_amounts, sqrt_price_at_tick, strategy_accounting


class AccountingMathTest(unittest.TestCase):
    def test_tick_math_matches_uniswap_boundaries(self) -> None:
        self.assertEqual(sqrt_price_at_tick(-887272), 4295128739)
        self.assertEqual(sqrt_price_at_tick(0), 1 << 96)
        self.assertEqual(
            sqrt_price_at_tick(887272),
            1461446703485210103287273052203988822378723970342,
        )

    def test_liquidity_amounts_respect_price_regimes(self) -> None:
        lower = sqrt_price_at_tick(-100)
        middle = sqrt_price_at_tick(0)
        upper = sqrt_price_at_tick(100)
        liquidity = 10**18
        below = liquidity_amounts(lower - 1, lower, upper, liquidity)
        inside = liquidity_amounts(middle, lower, upper, liquidity)
        above = liquidity_amounts(upper, lower, upper, liquidity)
        self.assertGreater(below[0], 0)
        self.assertEqual(below[1], 0)
        self.assertGreater(inside[0], 0)
        self.assertGreater(inside[1], 0)
        self.assertEqual(above[0], 0)
        self.assertGreater(above[1], 0)

    def test_strategy_accounting_excludes_operator_wallet(self) -> None:
        accounting = strategy_accounting(495.0, 2.0, 4.0, 0.0, 495.0, 0.16)
        self.assertAlmostEqual(accounting["strategyValueUsd"], 501.0)
        self.assertAlmostEqual(accounting["capitalBenchmarkUsd"], 495.16)
        self.assertAlmostEqual(accounting["netPnlUsd"], 5.84)
        self.assertAlmostEqual(accounting["netPnlPct"], 5.84 / 495.16 * 100)

    def test_strategy_accounting_can_reset_with_existing_reserves(self) -> None:
        accounting = strategy_accounting(495.0, 0.0, 4.0, 0.0, 495.0, 0.0, 4.0)
        self.assertEqual(accounting["netPnlUsd"], 0.0)
        self.assertEqual(accounting["netPnlPct"], 0.0)


if __name__ == "__main__":
    unittest.main()
