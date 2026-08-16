import json
import unittest
from pathlib import Path

from server import CanaryConfig, PortfolioEngine, liquidity_amounts, sqrt_price_at_tick


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

    def test_external_deposit_changes_benchmark_not_profit(self) -> None:
        config = CanaryConfig(json.loads((Path(__file__).parent / "base-canary.json").read_text()))
        engine = object.__new__(PortfolioEngine)
        engine.config = config
        snapshot = {
            "referencePrice": 2000.0,
            "strategyValueUsd": 2240.0,
            "holdValueUsd": 900.0,
            "balances": {"ownerEth": 0.693438687085635},
        }
        adjusted = engine.apply_external_flows(
            snapshot,
            {"native": 668251304314405286, "weth": 0, "usdc": 0},
        )
        self.assertAlmostEqual(adjusted["externalNetFlowUsd"], 1336.5026086288106)
        self.assertAlmostEqual(adjusted["netPnlUsd"], 3.4973913711894358)
        self.assertGreater(adjusted["ownerGasValueUsd"], 0)


if __name__ == "__main__":
    unittest.main()
