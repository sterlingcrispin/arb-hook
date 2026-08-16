#!/usr/bin/env python3
"""Sweep candidate ArbHook v4 pool configurations on a pinned Base fork.

The Foundry harness executes every row from the same snapshot and returns raw
token balances. This runner builds a structural grid, values the LP position at
the deep WETH/USDC benchmark, and then tunes iterations and principal caps for
the strongest quote-competitive rows.

The ranking is per triggering trade, not a daily revenue forecast. Realized
daily profit also requires an observed distribution of swap sizes/frequency.

Usage:
    BASE_RPC_URL=... python3 scripts/sweep_v4_pool.py
    BASE_RPC_URL=... python3 scripts/sweep_v4_pool.py --quick --no-tune
"""

from __future__ import annotations

import argparse
import csv
import itertools
import json
import math
import os
import subprocess
import sys
from dataclasses import dataclass
from decimal import Decimal, getcontext
from pathlib import Path
from typing import Iterable

getcontext().prec = 60

ROOT = Path(__file__).resolve().parents[1]
DEEP_REFERENCE = "0xd0b53D9277642d899DF5C87A3966A349A798F224"
SHALLOW_REFERENCE = "0x1C450D7d1FD98A0b04E30deCFc83497b33A4F608"
REFERENCES = {
    "deep": (DEEP_REFERENCE, 500),
    "shallow": (SHALLOW_REFERENCE, 200),
}
BATCH_SIZE = 24

RAW_FIELDS = [
    "success",
    "error_selector",
    "id",
    "reference_pool",
    "reference_fee",
    "reference_liquidity",
    "pool_fee",
    "tick_spacing",
    "lp_usdc_per_side",
    "half_range_ticks",
    "trade_usdc",
    "max_iterations",
    "principal_cap_bps",
    "v4_liquidity",
    "initial_lp_weth",
    "initial_lp_usdc",
    "benchmark_weth_out",
    "benchmark_swap_gas",
    "user_weth_out",
    "baseline_swap_gas",
    "hook_swap_gas",
    "principal",
    "total_amount_swapped",
    "hook_profit",
    "actual_iterations",
    "residual_ticks_before_backrun",
    "baseline_backrun_venue",
    "baseline_backrun_input",
    "baseline_backrun_profit",
    "residual_backrun_venue",
    "residual_backrun_input",
    "residual_backrun_profit",
    "baseline_lp_weth",
    "baseline_lp_usdc",
    "hook_lp_weth",
    "hook_lp_usdc",
    "initial_price_x18",
    "baseline_final_price_x18",
    "hook_final_price_x18",
]

ADDRESS_FIELDS = {
    "reference_pool",
    "baseline_backrun_venue",
    "residual_backrun_venue",
}


@dataclass(frozen=True)
class Scenario:
    id: int
    reference_pool: str
    reference_fee: int
    pool_fee: int
    tick_spacing: int
    lp_usdc_per_side: int
    half_range_ticks: int
    trade_usdc: int
    max_iterations: int
    principal_cap_bps: int


def parse_numbers(value: str, *, decimal_scale: int = 1) -> list[int]:
    values = []
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        values.append(int(Decimal(item) * decimal_scale))
    if not values:
        raise argparse.ArgumentTypeError("expected at least one comma-separated value")
    return values


def parse_fee_tiers(value: str) -> list[tuple[int, int]]:
    tiers = []
    for item in value.split(","):
        fee, spacing = item.split(":", 1)
        tiers.append((int(fee), int(spacing)))
    return tiers


def run_command(command: list[str], env: dict[str, str] | None = None, timeout: int = 1800) -> str:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"{' '.join(command)} failed:\n{detail[-4000:]}")
    return completed.stdout


def resolve_block(rpc_url: str, requested: int | None) -> int:
    if requested is not None:
        return requested
    return int(run_command(["cast", "block-number", "--rpc-url", rpc_url]).strip())


def block_base_fee(rpc_url: str, block_number: int) -> int:
    payload = json.loads(
        run_command(["cast", "block", str(block_number), "--rpc-url", rpc_url, "--json"])
    )
    value = payload.get("baseFeePerGas", "0x0")
    return int(value, 16) if isinstance(value, str) else int(value)


def scenario_env(rows: list[Scenario], rpc_url: str, block_number: int) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "BASE_RPC_URL": rpc_url,
            "RUN_V4_SWEEP": "true",
            "SWEEP_FORK_BLOCK": str(block_number),
            "SWEEP_IDS": ",".join(str(row.id) for row in rows),
            "SWEEP_REFERENCE_POOLS": ",".join(row.reference_pool for row in rows),
            "SWEEP_REFERENCE_FEES": ",".join(str(row.reference_fee) for row in rows),
            "SWEEP_POOL_FEES": ",".join(str(row.pool_fee) for row in rows),
            "SWEEP_TICK_SPACINGS": ",".join(str(row.tick_spacing) for row in rows),
            "SWEEP_LP_USDC_PER_SIDE": ",".join(str(row.lp_usdc_per_side) for row in rows),
            "SWEEP_HALF_RANGE_TICKS": ",".join(str(row.half_range_ticks) for row in rows),
            "SWEEP_TRADE_USDC": ",".join(str(row.trade_usdc) for row in rows),
            "SWEEP_MAX_ITERATIONS": ",".join(str(row.max_iterations) for row in rows),
            "SWEEP_PRINCIPAL_CAP_BPS": ",".join(str(row.principal_cap_bps) for row in rows),
        }
    )
    return env


def run_chunk(rows: list[Scenario], rpc_url: str, block_number: int) -> list[dict[str, int | str]]:
    if not rows:
        return []
    output = run_command(
        [
            "forge",
            "test",
            "--match-contract",
            "ArbHookV4SweepTest",
            "--match-test",
            "testParameterSweep",
            "-vv",
            "--json",
            "--threads",
            "1",
        ],
        env=scenario_env(rows, rpc_url, block_number),
    )
    suites = json.loads(output)
    test_result = next(iter(next(iter(suites.values()))["test_results"].values()))
    if test_result["status"] != "Success":
        raise RuntimeError(f"sweep harness failed: {test_result.get('reason')}")

    parsed = []
    for log in test_result["decoded_logs"]:
        if not log.startswith("SWEEP_RESULT|"):
            continue
        values = log.split("|")[1:]
        if len(values) != len(RAW_FIELDS):
            raise RuntimeError(f"unexpected sweep row width {len(values)}: {log[:200]}")
        row: dict[str, int | str] = {}
        for field, value in zip(RAW_FIELDS, values, strict=True):
            row[field] = value if field in ADDRESS_FIELDS else int(value)
        parsed.append(row)
    if len(parsed) != len(rows):
        raise RuntimeError(f"expected {len(rows)} results, received {len(parsed)}")
    return parsed


def run_batch(rows: list[Scenario], rpc_url: str, block_number: int) -> list[dict[str, int | str]]:
    if not rows:
        return []
    chunks = [rows[offset : offset + BATCH_SIZE] for offset in range(0, len(rows), BATCH_SIZE)]
    parsed = []
    for index, chunk in enumerate(chunks, start=1):
        print(
            f"Running fork batch {index}/{len(chunks)} ({len(chunk)} scenarios) "
            f"at Base block {block_number}...",
            flush=True,
        )
        parsed.extend(run_chunk(chunk, rpc_url, block_number))
    return parsed


def usdc_value_raw(weth_raw: int, usdc_raw: int, price_x18: int) -> int:
    return usdc_raw + weth_raw * price_x18 // 10**30


def derive(row: dict[str, int | str], base_fee_wei: int) -> dict[str, int | float | str]:
    derived = dict(row)
    reference = str(row["reference_pool"]).lower()
    derived["reference_name"] = next(
        (name for name, (address, _) in REFERENCES.items() if address.lower() == reference),
        reference[:10],
    )
    if not row["success"]:
        derived["error_selector_hex"] = hex(int(row["error_selector"]))
        return derived

    initial_value = usdc_value_raw(
        int(row["initial_lp_weth"]), int(row["initial_lp_usdc"]), int(row["initial_price_x18"])
    )
    baseline_value = usdc_value_raw(
        int(row["baseline_lp_weth"]),
        int(row["baseline_lp_usdc"]),
        int(row["baseline_final_price_x18"]),
    )
    hook_value = usdc_value_raw(
        int(row["hook_lp_weth"]), int(row["hook_lp_usdc"]), int(row["hook_final_price_x18"])
    )
    hook_profit_usdc = int(row["hook_profit"]) * int(row["hook_final_price_x18"]) // 10**30
    residual_profit_usdc = (
        int(row["residual_backrun_profit"]) * int(row["hook_final_price_x18"]) // 10**30
    )
    baseline_profit_usdc = (
        int(row["baseline_backrun_profit"]) * int(row["baseline_final_price_x18"]) // 10**30
    )
    user_output_usdc = int(row["user_weth_out"]) * int(row["hook_final_price_x18"]) // 10**30
    gas_overhead = max(0, int(row["hook_swap_gas"]) - int(row["baseline_swap_gas"]))
    gas_overhead_usdc = gas_overhead * base_fee_wei * int(row["hook_final_price_x18"]) // 10**30
    route_gas_delta = int(row["hook_swap_gas"]) - int(row["benchmark_swap_gas"])
    route_gas_delta_usdc = (
        route_gas_delta * base_fee_wei * int(row["hook_final_price_x18"]) // 10**30
    )
    quote_gap_bps = (
        (int(row["benchmark_weth_out"]) - int(row["user_weth_out"]))
        * 10_000
        / int(row["benchmark_weth_out"])
    )
    quote_gap_usdc = (
        (int(row["benchmark_weth_out"]) - int(row["user_weth_out"]))
        * int(row["hook_final_price_x18"])
        // 10**30
    )
    effective_quote_gap_bps = (quote_gap_usdc + route_gas_delta_usdc) * 10_000 / int(
        row["trade_usdc"]
    )
    user_all_in_gap_bps = (
        (quote_gap_usdc + route_gas_delta_usdc - hook_profit_usdc)
        * 10_000
        / int(row["trade_usdc"])
    )
    opportunity = int(row["hook_profit"]) + int(row["residual_backrun_profit"])

    derived.update(
        {
            "initial_lp_value_usdc_raw": initial_value,
            "baseline_lp_value_usdc_raw": baseline_value,
            "hook_lp_value_usdc_raw": hook_value,
            "baseline_lp_pnl_usdc_raw": baseline_value - initial_value,
            "hook_lp_pnl_usdc_raw": hook_value - initial_value,
            "hook_vs_baseline_lp_usdc_raw": hook_value - baseline_value,
            "hook_lp_return_bps": (hook_value - initial_value) * 10_000 / initial_value,
            "quote_gap_bps": quote_gap_bps,
            "effective_quote_gap_bps": effective_quote_gap_bps,
            "user_all_in_gap_bps": user_all_in_gap_bps,
            "hook_profit_usdc_raw": hook_profit_usdc,
            "residual_profit_usdc_raw": residual_profit_usdc,
            "baseline_backrun_profit_usdc_raw": baseline_profit_usdc,
            "capture_pct": int(row["hook_profit"]) * 100 / opportunity if opportunity else 0.0,
            "prevented_backrun_pct": (
                (int(row["baseline_backrun_profit"]) - int(row["residual_backrun_profit"]))
                * 100
                / int(row["baseline_backrun_profit"])
                if row["baseline_backrun_profit"]
                else 0.0
            ),
            "gas_overhead": gas_overhead,
            "gas_overhead_usdc_raw": gas_overhead_usdc,
            "route_gas_delta": route_gas_delta,
            "route_gas_delta_usdc_raw": route_gas_delta_usdc,
            "rebate_after_incremental_gas_usdc_raw": hook_profit_usdc - gas_overhead_usdc,
            "user_effective_loss_usdc_raw": (
                int(row["trade_usdc"]) - user_output_usdc - hook_profit_usdc
            ),
            "range_approx_pct": (
                0.0
                if int(row["half_range_ticks"]) == 0
                else (math.pow(1.0001, int(row["half_range_ticks"])) - 1) * 100
            ),
        }
    )
    return derived


def make_structural_rows(args: argparse.Namespace, start_id: int = 1) -> list[Scenario]:
    reference_names = [name.strip() for name in args.references.split(",") if name.strip()]
    unknown = set(reference_names) - REFERENCES.keys()
    if unknown:
        raise ValueError(f"unknown references: {', '.join(sorted(unknown))}")

    capitals = parse_numbers(args.capitals, decimal_scale=10**6)
    ranges = parse_numbers(args.ranges)
    trades = parse_numbers(args.trades, decimal_scale=10**6)
    fee_tiers = parse_fee_tiers(args.pool_fees)
    rows = []
    for values in itertools.product(reference_names, capitals, ranges, fee_tiers, trades):
        reference_name, capital, half_range, (pool_fee, spacing), trade = values
        reference_pool, reference_fee = REFERENCES[reference_name]
        rows.append(
            Scenario(
                id=start_id + len(rows),
                reference_pool=reference_pool,
                reference_fee=reference_fee,
                pool_fee=pool_fee,
                tick_spacing=spacing,
                lp_usdc_per_side=capital,
                half_range_ticks=half_range,
                trade_usdc=trade,
                max_iterations=args.base_iterations,
                principal_cap_bps=args.base_cap_bps,
            )
        )
    return rows


def tuning_rows(
    ranked: list[dict[str, int | float | str]], args: argparse.Namespace, start_id: int
) -> list[Scenario]:
    candidates = [
        row
        for row in ranked
        if row.get("success")
        and float(row["effective_quote_gap_bps"]) <= args.max_quote_gap_bps
        and int(row["hook_profit"]) > 0
    ]
    candidates.sort(key=lambda row: int(row["hook_profit_usdc_raw"]), reverse=True)

    selected = []
    seen = set()
    for row in candidates:
        key = (
            row["reference_pool"],
            row["pool_fee"],
            row["tick_spacing"],
            row["lp_usdc_per_side"],
            row["half_range_ticks"],
            row["trade_usdc"],
        )
        if key in seen:
            continue
        seen.add(key)
        selected.append(row)
        if len(selected) == args.tune_top:
            break

    iterations = parse_numbers(args.tune_iterations)
    caps = parse_numbers(args.tune_cap_bps)
    rows = []
    existing = {
        (
            row["reference_pool"],
            row["reference_fee"],
            row["pool_fee"],
            row["tick_spacing"],
            row["lp_usdc_per_side"],
            row["half_range_ticks"],
            row["trade_usdc"],
            row["max_iterations"],
            row["principal_cap_bps"],
        )
        for row in ranked
    }
    for candidate, max_iterations, cap_bps in itertools.product(selected, iterations, caps):
        scenario = Scenario(
            id=start_id + len(rows),
            reference_pool=str(candidate["reference_pool"]),
            reference_fee=int(candidate["reference_fee"]),
            pool_fee=int(candidate["pool_fee"]),
            tick_spacing=int(candidate["tick_spacing"]),
            lp_usdc_per_side=int(candidate["lp_usdc_per_side"]),
            half_range_ticks=int(candidate["half_range_ticks"]),
            trade_usdc=int(candidate["trade_usdc"]),
            max_iterations=max_iterations,
            principal_cap_bps=cap_bps,
        )
        frozen = (
            scenario.reference_pool,
            scenario.reference_fee,
            scenario.pool_fee,
            scenario.tick_spacing,
            scenario.lp_usdc_per_side,
            scenario.half_range_ticks,
            scenario.trade_usdc,
            scenario.max_iterations,
            scenario.principal_cap_bps,
        )
        if frozen not in existing:
            existing.add(frozen)
            rows.append(scenario)
    return rows


def money(raw: int | float | str) -> str:
    return f"{Decimal(int(raw)) / Decimal(10**6):,.4f}"


def range_name(row: dict[str, int | float | str]) -> str:
    ticks = int(row["half_range_ticks"])
    return "full" if ticks == 0 else f"+/-{float(row['range_approx_pct']):.1f}%"


def print_table(title: str, rows: Iterable[dict[str, int | float | str]], limit: int = 10) -> None:
    rows = list(rows)[:limit]
    print(f"\n{title}")
    print(
        "ref      LP/side range      fee trade iter/cap route all-in   LP PnL  rebate residual capture gas+"
    )
    for row in rows:
        print(
            f"{str(row['reference_name']):8} "
            f"${int(row['lp_usdc_per_side']) / 1e6:<7.0f} "
            f"{range_name(row):8} "
            f"{int(row['pool_fee']) / 100:>6.2f}bp "
            f"${int(row['trade_usdc']) / 1e6:<5.0f} "
            f"{int(row['max_iterations']):>2}/{int(row['principal_cap_bps']) / 100:>2.0f}% "
            f"{float(row['effective_quote_gap_bps']):>5.1f} "
            f"{float(row['user_all_in_gap_bps']):>6.1f}bp "
            f"${money(row['hook_lp_pnl_usdc_raw']):>7} "
            f"${money(row['hook_profit_usdc_raw']):>6} "
            f"${money(row['residual_profit_usdc_raw']):>7} "
            f"{float(row['capture_pct']):>6.1f}% "
            f"{int(row['gas_overhead']) / 1e6:>4.2f}M"
        )


def report(results: list[dict[str, int | float | str]], max_quote_gap_bps: float) -> None:
    failures = [row for row in results if not row.get("success")]
    successful = [row for row in results if row.get("success")]
    eligible = [
        row for row in successful if float(row["effective_quote_gap_bps"]) <= max_quote_gap_bps
    ]
    eligible_arbs = [row for row in eligible if int(row["hook_profit"]) > 0]
    route_winners = [row for row in eligible_arbs if float(row["effective_quote_gap_bps"]) <= 0]
    user_winners = [row for row in eligible_arbs if float(row["user_all_in_gap_bps"]) <= 0]

    print(
        f"\nCompleted {len(successful)}/{len(results)} scenarios; {len(eligible)} are within "
        f"{max_quote_gap_bps:g} bps of the deep-pool route after execution gas and {len(eligible_arbs)} "
        f"of those execute an arb. {len(route_winners)} beat the benchmark before rebate; "
        f"{len(user_winners)} beat it after rebate."
    )
    if failures:
        print(f"Invalid/reverted scenarios: {len(failures)}")

    print_table(
        "Best near-benchmark LP return per triggering trade",
        sorted(eligible_arbs, key=lambda row: float(row["hook_lp_return_bps"]), reverse=True),
    )
    print_table(
        "Largest near-benchmark user rebate",
        sorted(
            eligible_arbs,
            key=lambda row: int(row["hook_profit_usdc_raw"]),
            reverse=True,
        ),
    )
    print_table(
        "Highest MEV capture percentage (minimum one cent baseline backrun)",
        sorted(
            [row for row in eligible_arbs if int(row["baseline_backrun_profit_usdc_raw"]) >= 10_000],
            key=lambda row: float(row["capture_pct"]),
            reverse=True,
        ),
    )
    print_table(
        "Closest all-in user execution to the deep-pool benchmark",
        sorted(eligible_arbs, key=lambda row: float(row["user_all_in_gap_bps"])),
    )


def write_results(
    output_dir: Path,
    block_number: int,
    base_fee_wei: int,
    args: argparse.Namespace,
    results: list[dict[str, int | float | str]],
) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    stem = output_dir / f"v4-parameter-sweep-{block_number}"
    json_path = stem.with_suffix(".json")
    csv_path = stem.with_suffix(".csv")
    payload = {
        "block_number": block_number,
        "base_fee_wei": base_fee_wei,
        "arguments": {
            key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()
        },
        "limitations": [
            "Per-trigger economics only; no trade-frequency or daily-volume model.",
            "Route competitiveness compares output and execution gas with the deep Uniswap V3 5 bp pool.",
            "Backruns optimize across the configured reference and deep benchmark, not every Base venue.",
            "Gas conversion uses Base execution base fee and excludes L1 data fee and priority fee.",
            "The harness uses minNetProfit=1 wei to expose raw economics; ranking deducts estimated gas off-chain.",
        ],
        "results": results,
    }
    json_path.write_text(json.dumps(payload, indent=2) + "\n")
    fields = sorted({key for row in results for key in row})
    with csv_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(results)
    return json_path, csv_path


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(description=__doc__)
    command.add_argument("--rpc-url", default=os.environ.get("BASE_RPC_URL"))
    command.add_argument("--fork-block", type=int)
    command.add_argument("--references", default="deep,shallow")
    command.add_argument("--capitals", default="100,500,2000", help="USDC per LP side")
    command.add_argument("--ranges", default="0,250,1000", help="half-width in ticks; zero is full range")
    command.add_argument("--pool-fees", default="100:1,500:10", help="fee ppm:tick spacing")
    command.add_argument("--trades", default="10,50,100", help="trigger sizes in USDC")
    command.add_argument("--base-iterations", type=int, default=10)
    command.add_argument("--base-cap-bps", type=int, default=1000)
    command.add_argument("--max-quote-gap-bps", type=float, default=30.0)
    command.add_argument("--tune-top", type=int, default=4)
    command.add_argument("--tune-iterations", default="5,10,15")
    command.add_argument("--tune-cap-bps", default="500,1000,2500")
    command.add_argument("--no-tune", action="store_true")
    command.add_argument("--quick", action="store_true", help="run a 32-row smoke grid")
    command.add_argument("--output-dir", type=Path, default=ROOT / "artifacts")
    return command


def main() -> int:
    args = parser().parse_args()
    if not args.rpc_url:
        print("BASE_RPC_URL or --rpc-url is required", file=sys.stderr)
        return 2
    if args.quick:
        args.capitals = "100,2000"
        args.ranges = "0,250"
        args.trades = "10,100"
        args.tune_top = min(args.tune_top, 2)

    block_number = resolve_block(args.rpc_url, args.fork_block)
    base_fee_wei = block_base_fee(args.rpc_url, block_number)
    structural = make_structural_rows(args)
    raw_results = run_batch(structural, args.rpc_url, block_number)
    results = [derive(row, base_fee_wei) for row in raw_results]

    if not args.no_tune and args.tune_top > 0:
        tuning = tuning_rows(results, args, start_id=len(structural) + 1)
        if tuning:
            raw_tuning = run_batch(tuning, args.rpc_url, block_number)
            results.extend(derive(row, base_fee_wei) for row in raw_tuning)

    report(results, args.max_quote_gap_bps)
    json_path, csv_path = write_results(
        args.output_dir, block_number, base_fee_wei, args, results
    )
    print(f"\nRaw and derived results:\n  {json_path}\n  {csv_path}")
    print("\nInterpretation: rankings are per trigger. Multiply by an observed trade-size/frequency "
          "distribution before treating any row as a daily-profit forecast.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
