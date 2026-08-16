#!/usr/bin/env python3
"""Replay historical Base WETH/USDC flow through persistent candidate v4 pools.

The replay uses observed swap output as the competing route, mutates candidate
concentrated liquidity across transactions, and mirrors the production v4/v3
countertrade loop. It is a counterfactual model, not a revenue guarantee.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import math
import statistics
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
Q96 = 1 << 96
RAW_PRICE_SCALE = 1e12
TICK_BASE = 1.0001
LOG_TICK_BASE = math.log(TICK_BASE)

REFERENCE_POOLS = {
    "uniswap_v3_1bp": 100,
    "uniswap_v3_5bp": 500,
    "uniswap_v3_30bp": 3_000,
    "pancake_v3_1bp": 100,
}
KNOWN_ROUTERS = {
    "0x2626664c2603336e57b271c5c0b26f421741e481",
    "0x6ff5693b99212da76ad316178a184ab56d299b43",
}


@dataclass(frozen=True, slots=True)
class VenueSnapshot:
    key: str
    fee_ppm: int
    sqrt_price: float
    tick: int
    liquidity: float

    @property
    def price(self) -> float:
        return self.sqrt_price * self.sqrt_price


@dataclass(frozen=True, slots=True)
class Order:
    tx_hash: str
    block: int
    timestamp: int
    direction: str
    usdc_size: float
    amount_in: float
    observed_out: float
    source_pool: str
    sender: str
    pool_count: int
    oracle_price: float
    reference: VenueSnapshot


@dataclass(frozen=True, slots=True)
class Config:
    capital_per_side: float
    half_range_ticks: int
    fee_ppm: int
    hook_enabled: bool
    principal_cap_bps: int
    max_iterations: int


@dataclass(slots=True)
class SwapResult:
    amount_paid: float = 0.0
    amount_out: float = 0.0
    fee_paid: float = 0.0
    full_fill: bool = False


@dataclass(slots=True)
class HookResult:
    success: bool = False
    profit_usdc: float = 0.0
    iterations: int = 0
    principal_usdc: float = 0.0
    residual_ticks: int = 0
    reference: str = ""


@dataclass(slots=True)
class PoolState:
    sqrt_price: float
    liquidity: float
    fee_ppm: int
    lower_sqrt: float = 0.0
    upper_sqrt: float = math.inf
    fee_weth: float = 0.0
    fee_usdc: float = 0.0

    @property
    def price(self) -> float:
        return self.sqrt_price * self.sqrt_price

    @property
    def tick(self) -> int:
        return price_to_tick(self.price)

    def copy(self) -> PoolState:
        return PoolState(
            self.sqrt_price,
            self.liquidity,
            self.fee_ppm,
            self.lower_sqrt,
            self.upper_sqrt,
            self.fee_weth,
            self.fee_usdc,
        )

    def replace_from(self, other: PoolState) -> None:
        self.sqrt_price = other.sqrt_price
        self.fee_weth = other.fee_weth
        self.fee_usdc = other.fee_usdc

    def amounts(self) -> tuple[float, float]:
        if self.sqrt_price <= self.lower_sqrt:
            return (
                self.liquidity * (1 / self.lower_sqrt - 1 / self.upper_sqrt),
                0.0,
            )
        if self.sqrt_price >= self.upper_sqrt:
            return (0.0, self.liquidity * (self.upper_sqrt - self.lower_sqrt))
        return (
            self.liquidity * (1 / self.sqrt_price - 1 / self.upper_sqrt),
            self.liquidity * (self.sqrt_price - self.lower_sqrt),
        )

    def value(self, weth_price: float) -> float:
        weth, usdc = self.amounts()
        return (weth + self.fee_weth) * weth_price + usdc + self.fee_usdc

    def delta_to(self, zero_for_one: bool, target_sqrt: float) -> tuple[float, float]:
        if zero_for_one:
            target = max(self.lower_sqrt, min(self.sqrt_price, target_sqrt))
            return (
                self.liquidity * (1 / target - 1 / self.sqrt_price),
                self.liquidity * (self.sqrt_price - target),
            )
        target = min(self.upper_sqrt, max(self.sqrt_price, target_sqrt))
        return (
            self.liquidity * (target - self.sqrt_price),
            self.liquidity * (1 / self.sqrt_price - 1 / target),
        )

    def swap_exact_in(
        self,
        zero_for_one: bool,
        amount_in: float,
        *,
        limit_sqrt: float | None = None,
        mutate: bool,
    ) -> SwapResult:
        if amount_in <= 0 or self.liquidity <= 0:
            return SwapResult()
        fee_fraction = self.fee_ppm / 1_000_000
        effective_requested = amount_in * (1 - fee_fraction)

        if zero_for_one:
            target = self.lower_sqrt
            if limit_sqrt is not None:
                target = max(target, limit_sqrt)
            if target >= self.sqrt_price:
                return SwapResult()
            max_effective = self.liquidity * (1 / target - 1 / self.sqrt_price)
            effective = min(effective_requested, max_effective)
            new_sqrt = 1 / (1 / self.sqrt_price + effective / self.liquidity)
            amount_out = self.liquidity * (self.sqrt_price - new_sqrt)
        else:
            target = self.upper_sqrt
            if limit_sqrt is not None:
                target = min(target, limit_sqrt)
            if target <= self.sqrt_price:
                return SwapResult()
            max_effective = self.liquidity * (target - self.sqrt_price)
            effective = min(effective_requested, max_effective)
            new_sqrt = self.sqrt_price + effective / self.liquidity
            amount_out = self.liquidity * (1 / self.sqrt_price - 1 / new_sqrt)

        amount_paid = effective / (1 - fee_fraction)
        fee_paid = amount_paid - effective
        full_fill = amount_paid >= amount_in * (1 - 1e-10)
        if mutate:
            self.sqrt_price = new_sqrt
            if zero_for_one:
                self.fee_weth += fee_paid
            else:
                self.fee_usdc += fee_paid
        return SwapResult(amount_paid, amount_out, fee_paid, full_fill)


@dataclass(frozen=True, slots=True)
class Route:
    principal: float = 0.0
    candidate_limit: float = 0.0
    external_limit: float = 0.0
    spread: int = 0


def price_to_tick(price: float) -> int:
    return math.floor(math.log(price / RAW_PRICE_SCALE) / LOG_TICK_BASE)


def tick_to_sqrt_price(tick: int) -> float:
    return math.sqrt(math.exp(tick * LOG_TICK_BASE) * RAW_PRICE_SCALE)


def event_snapshot(event: dict) -> VenueSnapshot:
    return VenueSnapshot(
        key=event["pool"],
        fee_ppm=REFERENCE_POOLS[event["pool"]],
        sqrt_price=event["sqrt_price_x96"] / Q96 * 1e6,
        tick=event["tick"],
        liquidity=event["liquidity_raw"] / 1e12,
    )


def best_reference(states: dict[str, VenueSnapshot], direction: str) -> VenueSnapshot:
    if direction == "usdc_to_weth":
        return min(
            states.values(),
            key=lambda state: state.price / (1 - state.fee_ppm / 1_000_000),
        )
    return min(
        states.values(),
        key=lambda state: (1 / state.price) / (1 - state.fee_ppm / 1_000_000),
    )


def selected_event(events: list[dict]) -> dict:
    return max(events, key=lambda event: event["usdc"])


def order_from_group(
    events: list[dict],
    states: dict[str, VenueSnapshot],
    flow_filter: str,
) -> Order | None:
    chosen = selected_event(events)
    pools = {event["pool"] for event in events}
    if flow_filter == "single-pool" and len(pools) != 1:
        return None
    if flow_filter == "canonical-router" and chosen["sender"] not in KNOWN_ROUTERS:
        return None

    direction = chosen["direction"]
    weth = chosen["weth_raw"] / 1e18
    if direction == "usdc_to_weth":
        amount_in, observed_out = chosen["usdc"], weth
    else:
        amount_in, observed_out = weth, chosen["usdc"]
    if amount_in <= 0 or observed_out <= 0:
        return None

    return Order(
        tx_hash=chosen["tx"],
        block=chosen["block"],
        timestamp=chosen["timestamp"],
        direction=direction,
        usdc_size=chosen["usdc"],
        amount_in=amount_in,
        observed_out=observed_out,
        source_pool=chosen["pool"],
        sender=chosen["sender"],
        pool_count=len(pools),
        oracle_price=statistics.median(state.price for state in states.values()),
        reference=best_reference(states, direction),
    )


def build_order_tape(
    cache: Path,
    references: set[str],
    flow_filter: str,
) -> tuple[dict, list[Order]]:
    states: dict[str, VenueSnapshot] = {}
    orders: list[Order] = []
    group: list[dict] = []
    transaction = ""

    def consume(events: list[dict]) -> None:
        if not events:
            return
        if len(states) == len(references):
            order = order_from_group(events, states, flow_filter)
            if order is not None:
                orders.append(order)
        for event in events:
            if event["pool"] in references:
                states[event["pool"]] = event_snapshot(event)

    with gzip.open(cache, "rt") as handle:
        metadata = json.loads(next(handle))["metadata"]
        if metadata.get("schema_version") != 2:
            raise RuntimeError("event cache lacks replay fields; rebuild it with model_swap_flow.py --refresh")
        for line in handle:
            event = json.loads(line)
            if group and event["tx"] != transaction:
                consume(group)
                group = []
            transaction = event["tx"]
            group.append(event)
        consume(group)
    if not orders:
        raise RuntimeError("no replayable orders found")
    return metadata, orders


def initialize_candidate(config: Config, price: float) -> tuple[PoolState, float, float]:
    center_tick = price_to_tick(price)
    lower = tick_to_sqrt_price(center_tick - config.half_range_ticks)
    upper = tick_to_sqrt_price(center_tick + config.half_range_ticks)
    current = math.sqrt(price)
    weth_max = config.capital_per_side / price
    liquidity_weth = weth_max / (1 / current - 1 / upper)
    liquidity_usdc = config.capital_per_side / (current - lower)
    liquidity = min(liquidity_weth, liquidity_usdc)
    pool = PoolState(current, liquidity, config.fee_ppm, lower, upper)
    initial_weth, initial_usdc = pool.amounts()
    return pool, initial_weth, initial_usdc


def external_pool(snapshot: VenueSnapshot) -> PoolState:
    return PoolState(snapshot.sqrt_price, snapshot.liquidity, snapshot.fee_ppm)


def route_params(
    candidate: PoolState,
    external: PoolState,
    *,
    start_weth: bool,
    balance_cap: float,
    initial_spread: int,
    min_spread_ticks: int,
) -> Route:
    candidate_tick = candidate.tick
    external_tick = external.tick
    spread = candidate_tick - external_tick if start_weth else external_tick - candidate_tick
    if spread < min_spread_ticks:
        return Route()

    candidate_fee = candidate.fee_ppm / 1_000_000
    external_fee = external.fee_ppm / 1_000_000
    if start_weth:
        profitable = candidate.price * (1 - candidate_fee) > external.price / (1 - external_fee)
    else:
        profitable = (1 / candidate.price) * (1 - candidate_fee) > (1 / external.price) / (1 - external_fee)
    if not profitable:
        return Route()

    initial = initial_spread or spread
    move_factor = 1_500 + (2_000 * spread) // initial
    move = spread * move_factor // 20_000
    move = max(1, min(move, 500))
    candidate_target_tick = candidate_tick - move if start_weth else candidate_tick + move
    external_target_tick = external_tick + move if start_weth else external_tick - move
    candidate_limit = tick_to_sqrt_price(candidate_target_tick)
    external_limit = tick_to_sqrt_price(external_target_tick)

    start_in, intermediate_out = candidate.delta_to(start_weth, candidate_limit)
    external_capacity, _ = external.delta_to(not start_weth, external_limit)
    if start_in <= 0 or intermediate_out <= 0 or external_capacity <= 0:
        return Route()
    principal = start_in
    if intermediate_out > external_capacity:
        principal *= external_capacity / intermediate_out
    principal = min(principal, balance_cap)
    if principal < 0.0001:
        return Route()
    return Route(principal, candidate_limit, external_limit, spread)


def execute_hook(
    candidate: PoolState,
    order: Order,
    config: Config,
    principal_cap_weth: float,
    principal_cap_usdc: float,
    min_spread_ticks: int,
    min_profit_usdc: float,
) -> HookResult:
    start_weth = order.direction == "usdc_to_weth"
    principal_cap = principal_cap_weth if start_weth else principal_cap_usdc
    work = candidate.copy()
    external = external_pool(order.reference)
    first = route_params(
        work,
        external,
        start_weth=start_weth,
        balance_cap=principal_cap,
        initial_spread=0,
        min_spread_ticks=min_spread_ticks,
    )
    if first.principal == 0:
        return HookResult(reference=order.reference.key)

    loan_principal = first.principal
    cumulative = 0.0
    iterations = 0
    for _ in range(config.max_iterations):
        route = route_params(
            work,
            external,
            start_weth=start_weth,
            balance_cap=loan_principal + max(0.0, cumulative),
            initial_spread=first.spread,
            min_spread_ticks=min_spread_ticks,
        )
        if route.principal == 0:
            break
        candidate_swap = work.swap_exact_in(
            start_weth,
            route.principal,
            limit_sqrt=route.candidate_limit,
            mutate=True,
        )
        external_swap = external.swap_exact_in(
            not start_weth,
            candidate_swap.amount_out,
            limit_sqrt=route.external_limit,
            mutate=True,
        )
        if candidate_swap.amount_paid <= 0 or not external_swap.full_fill:
            break
        iteration_profit = external_swap.amount_out - candidate_swap.amount_paid
        cumulative += iteration_profit
        iterations += 1
        if iteration_profit <= 0:
            break

    profit_usdc = cumulative * order.oracle_price if start_weth else cumulative
    if iterations == 0 or profit_usdc < min_profit_usdc or cumulative <= 0:
        return HookResult(reference=order.reference.key)
    candidate.replace_from(work)
    residual = abs(candidate.tick - external.tick)
    principal_usdc = loan_principal * order.oracle_price if start_weth else loan_principal
    return HookResult(True, profit_usdc, iterations, principal_usdc, residual, order.reference.key)


def replay(
    config: Config,
    orders: list[Order],
    *,
    discovery_share_pct: float,
    gas_penalty_usdc: float,
    min_spread_ticks: int,
    min_profit_usdc: float,
) -> dict:
    candidate, initial_weth, initial_usdc = initialize_candidate(config, orders[0].oracle_price)
    initial_price = orders[0].oracle_price
    initial_value = initial_weth * initial_price + initial_usdc
    principal_cap_weth = initial_weth * config.principal_cap_bps / 10_000
    principal_cap_usdc = initial_usdc * config.principal_cap_bps / 10_000

    route_wins = 0
    route_volume = 0.0
    arb_count = 0
    rebate = 0.0
    principal = 0.0
    iteration_total = 0
    residual_ticks = 0
    unfillable = 0
    wins_by_direction = Counter()
    wins_by_source = Counter()
    arb_references = Counter()
    discovered_orders = 0

    for order in orders:
        if discovery_share_pct < 100:
            sample = int(order.tx_hash[-16:], 16) / (1 << 64) * 100
            if sample >= discovery_share_pct:
                continue
        discovered_orders += 1
        zero_for_one = order.direction == "weth_to_usdc"
        quote = candidate.swap_exact_in(zero_for_one, order.amount_in, mutate=False)
        if not quote.full_fill:
            unfillable += 1
            continue
        gas_in_output = gas_penalty_usdc / order.oracle_price if order.direction == "usdc_to_weth" else gas_penalty_usdc
        if quote.amount_out - gas_in_output < order.observed_out:
            continue

        execution = candidate.swap_exact_in(zero_for_one, order.amount_in, mutate=True)
        if not execution.full_fill:
            raise AssertionError("a successful preview must execute fully")
        route_wins += 1
        route_volume += order.usdc_size
        wins_by_direction[order.direction] += 1
        wins_by_source[order.source_pool] += 1

        if config.hook_enabled:
            outcome = execute_hook(
                candidate,
                order,
                config,
                principal_cap_weth,
                principal_cap_usdc,
                min_spread_ticks,
                min_profit_usdc,
            )
            if outcome.success:
                arb_count += 1
                rebate += outcome.profit_usdc
                principal += outcome.principal_usdc
                iteration_total += outcome.iterations
                residual_ticks += outcome.residual_ticks
                arb_references[outcome.reference] += 1

    final_price = orders[-1].oracle_price
    final_weth, final_usdc = candidate.amounts()
    final_value = candidate.value(final_price)
    hodl_value = initial_weth * final_price + initial_usdc
    fee_value = candidate.fee_weth * final_price + candidate.fee_usdc
    duration_days = (orders[-1].timestamp - orders[0].timestamp) / 86_400
    excess = final_value - hodl_value
    return {
        **asdict(config),
        "discovery_share_pct": discovery_share_pct,
        "gas_penalty_usdc": gas_penalty_usdc,
        "min_profit_usdc": min_profit_usdc,
        "duration_days": duration_days,
        "orders": len(orders),
        "discovered_orders": discovered_orders,
        "initial_price_usdc": initial_price,
        "final_price_usdc": final_price,
        "initial_weth": initial_weth,
        "initial_usdc": initial_usdc,
        "initial_value_usdc": initial_value,
        "final_weth": final_weth,
        "final_usdc": final_usdc,
        "final_fee_weth": candidate.fee_weth,
        "final_fee_usdc": candidate.fee_usdc,
        "final_lp_value_usdc": final_value,
        "hodl_value_usdc": hodl_value,
        "lp_excess_vs_hodl_usdc": excess,
        "lp_excess_per_day_usdc": excess / duration_days,
        "lp_excess_return_bps": excess * 10_000 / initial_value,
        "fee_value_usdc": fee_value,
        "route_wins": route_wins,
        "route_wins_per_day": route_wins / duration_days,
        "route_volume_usdc": route_volume,
        "route_volume_per_day_usdc": route_volume / duration_days,
        "unfillable_orders": unfillable,
        "arb_count": arb_count,
        "arb_count_per_day": arb_count / duration_days,
        "rebate_usdc": rebate,
        "rebate_per_day_usdc": rebate / duration_days,
        "average_principal_usdc": principal / arb_count if arb_count else 0.0,
        "average_iterations": iteration_total / arb_count if arb_count else 0.0,
        "average_residual_ticks": residual_ticks / arb_count if arb_count else 0.0,
        "wins_by_direction": dict(wins_by_direction),
        "wins_by_source": dict(wins_by_source),
        "arb_references": dict(arb_references),
    }


def verify_fixed_fork_calibration() -> None:
    price = 1_882_251_195_337_107_036_355 / 1e18
    config = Config(1_000, 100, 1, True, 1_000, 10)
    candidate, initial_weth, initial_usdc = initialize_candidate(config, price)
    user_swap = candidate.swap_exact_in(False, 100, mutate=True)
    reference = VenueSnapshot(
        "uniswap_v3_5bp",
        500,
        math.sqrt(price),
        price_to_tick(price),
        1_097_715_714_974_944_790 / 1e12,
    )
    order = Order(
        "0x" + "00" * 32,
        0,
        0,
        "usdc_to_weth",
        100,
        100,
        user_swap.amount_out,
        reference.key,
        "",
        1,
        price,
        reference,
    )
    outcome = execute_hook(
        candidate,
        order,
        config,
        initial_weth / 10,
        initial_usdc / 10,
        10,
        0,
    )
    expected_user_out = 53_101_076_379_780_906 / 1e18
    expected_profit_usdc = 4_356_528_473_964 / 1e18 * price
    if (
        not outcome.success
        or outcome.iterations != 2
        or outcome.residual_ticks != 9
        or abs(user_swap.amount_out / expected_user_out - 1) > 1e-9
        or abs(outcome.profit_usdc / expected_profit_usdc - 1) > 0.001
    ):
        raise AssertionError("analytical replay no longer matches the fixed-fork sweep oracle")


def parse_numbers(value: str, cast) -> list:
    result = [cast(item.strip()) for item in value.split(",") if item.strip()]
    if not result:
        raise argparse.ArgumentTypeError("expected comma-separated values")
    return result


def discover_cache(path: Path | None) -> Path:
    if path is not None:
        return path
    candidates = sorted((ROOT / "artifacts" / "flow-model").glob("swap-flow-*-events.jsonl.gz"))
    if not candidates:
        raise RuntimeError("no swap-flow event cache found")
    return candidates[-1]


def write_results(output_dir: Path, metadata: dict, arguments: dict, rows: list[dict]) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    stem = (
        f"v4-strategy-replay-{metadata['start_block']}-{metadata['end_block']}-"
        f"{metadata['replay_start_timestamp']}-{metadata['replay_end_timestamp']}"
    )
    json_path = output_dir / f"{stem}.json"
    csv_path = output_dir / f"{stem}.csv"
    payload = {
        "metadata": metadata,
        "arguments": arguments,
        "limitations": [
            "Historical swaps are a counterfactual order proxy and include user, router, searcher, and split-route flow.",
            "Discovery share deterministically samples transaction hashes; it is a scenario input, not an inferred routing forecast.",
            "Uniswap's production router filters non-allowlisted hooks, so canonical-router flow requires hook allowlisting.",
            "Observed source output is the competing route; the model does not rerun every external router path.",
            "External venue state follows the historical tape and does not persist the candidate hook's market impact.",
            "The candidate position is fixed for the replay and is not automatically recentered or compounded.",
            "Gas is a configurable USDC routing penalty; Base L1 and priority costs are not reconstructed per transaction.",
            "Arbitrage profit is paid to the swap beneficiary and is not LP revenue.",
        ],
        "results": rows,
    }
    json_path.write_text(json.dumps(payload, indent=2) + "\n")
    csv_rows = []
    for row in rows:
        flat = dict(row)
        for field in ("wins_by_direction", "wins_by_source", "arb_references"):
            flat[field] = json.dumps(flat[field], sort_keys=True)
        csv_rows.append(flat)
    with csv_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(csv_rows[0]))
        writer.writeheader()
        writer.writerows(csv_rows)
    return json_path, csv_path


def report(rows: list[dict]) -> None:
    print("\nTop candidate pools by LP excess versus holding the deposited assets")
    print("hook share fee   LP/side range iter cap   min$  gas    routes/day arbs/day LP excess/day rebate/day")
    for row in rows[:12]:
        print(
            f"{'on' if row['hook_enabled'] else 'off':>4} "
            f"{row['discovery_share_pct']:>5.1f}% "
            f"{row['fee_ppm'] / 100:>4.2f}bp "
            f"${row['capital_per_side']:<7,.0f} "
            f"{row['half_range_ticks']:>5}t "
            f"{row['max_iterations']:>4} "
            f"{row['principal_cap_bps']:>4} "
            f"{row['min_profit_usdc']:>5.2f} "
            f"${row['gas_penalty_usdc']:<6,.3f} "
            f"{row['route_wins_per_day']:>10,.1f} "
            f"{row['arb_count_per_day']:>8,.1f} "
            f"${row['lp_excess_per_day_usdc']:>12,.3f} "
            f"${row['rebate_per_day_usdc']:>10,.3f}"
        )


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(description=__doc__)
    command.add_argument("--cache", type=Path)
    command.add_argument("--references", default=",".join(REFERENCE_POOLS))
    command.add_argument("--flow-filter", choices=("all", "single-pool", "canonical-router"), default="all")
    command.add_argument("--discovery-shares", default="100")
    command.add_argument("--capitals", default="100,500,1000,2000,4000,10000")
    command.add_argument("--ranges", default="50,100,250,500,1000")
    command.add_argument("--fees", default="1,10,100")
    command.add_argument("--hook-modes", choices=("on", "off", "both"), default="both")
    command.add_argument("--principal-cap-bps", "--principal-caps", dest="principal_caps", default="1000")
    command.add_argument("--max-iterations", dest="max_iterations", default="10")
    command.add_argument("--min-spread-ticks", type=int, default=10)
    command.add_argument("--min-profit-usdc", "--min-profits", dest="min_profits", default="0")
    command.add_argument("--gas-penalty-usdc", "--gas-penalties", dest="gas_penalties", default="0.005")
    command.add_argument("--start-day", type=float, default=0.0)
    command.add_argument("--duration-days", type=float)
    command.add_argument("--max-orders", type=int)
    command.add_argument("--output-dir", type=Path, default=ROOT / "artifacts" / "strategy-replay")
    return command


def main() -> int:
    args = parser().parse_args()
    verify_fixed_fork_calibration()
    references = {item.strip() for item in args.references.split(",") if item.strip()}
    unknown = references - REFERENCE_POOLS.keys()
    if not references or unknown:
        raise SystemExit(f"invalid references: {sorted(unknown)}")
    principal_caps = parse_numbers(args.principal_caps, int)
    max_iterations = parse_numbers(args.max_iterations, int)
    min_profits = parse_numbers(args.min_profits, float)
    if any(not 0 < cap <= 10_000 for cap in principal_caps) or any(value <= 0 for value in max_iterations):
        raise SystemExit("principal caps and max iterations must be positive")
    gas_penalties = parse_numbers(args.gas_penalties, float)
    discovery_shares = parse_numbers(args.discovery_shares, float)
    if any(penalty < 0 for penalty in gas_penalties) or any(value < 0 for value in min_profits):
        raise SystemExit("gas penalty and minimum profit cannot be negative")
    if any(not 0 < share <= 100 for share in discovery_shares):
        raise SystemExit("discovery shares must be greater than zero and at most 100")
    if args.start_day < 0 or (args.duration_days is not None and args.duration_days <= 0):
        raise SystemExit("replay window must be positive")

    cache = discover_cache(args.cache)
    print(f"Building transaction tape from {cache}...", flush=True)
    metadata, orders = build_order_tape(cache, references, args.flow_filter)
    window_start = metadata["start_timestamp"] + round(args.start_day * 86_400)
    window_end = (
        window_start + round(args.duration_days * 86_400)
        if args.duration_days is not None
        else metadata["end_timestamp"] + 1
    )
    orders = [order for order in orders if window_start <= order.timestamp < window_end]
    if args.max_orders:
        orders = orders[: args.max_orders]
    if len(orders) < 2:
        raise RuntimeError("replay window contains fewer than two orders")
    metadata = {
        **metadata,
        "replay_start_timestamp": orders[0].timestamp,
        "replay_end_timestamp": orders[-1].timestamp,
    }
    print(f"Replaying {len(orders):,} transaction-level orders...", flush=True)

    capitals = parse_numbers(args.capitals, float)
    ranges = parse_numbers(args.ranges, int)
    fees = parse_numbers(args.fees, int)
    hook_modes = [True, False] if args.hook_modes == "both" else [args.hook_modes == "on"]
    scenarios = [
        (Config(capital, half_range, fee, enabled, principal_cap, iterations), discovery_share, gas_penalty, min_profit)
        for capital in capitals
        for half_range in ranges
        for fee in fees
        for enabled in hook_modes
        for principal_cap in principal_caps
        for iterations in max_iterations
        for discovery_share in discovery_shares
        for gas_penalty in gas_penalties
        for min_profit in min_profits
    ]

    rows = []
    for index, (config, discovery_share, gas_penalty, min_profit) in enumerate(scenarios, start=1):
        print(
            f"[{index}/{len(scenarios)}] ${config.capital_per_side:,.0f}/side, "
            f"{config.half_range_ticks} ticks, {config.fee_ppm / 100:.2f} bp, "
            f"hook={'on' if config.hook_enabled else 'off'}, iterations={config.max_iterations}, "
            f"cap={config.principal_cap_bps} bps, share={discovery_share:g}%, "
            f"min=${min_profit:g}, gas=${gas_penalty:g}",
            flush=True,
        )
        rows.append(
            replay(
                config,
                orders,
                discovery_share_pct=discovery_share,
                gas_penalty_usdc=gas_penalty,
                min_spread_ticks=args.min_spread_ticks,
                min_profit_usdc=min_profit,
            )
        )
    rows.sort(key=lambda row: row["lp_excess_vs_hodl_usdc"], reverse=True)
    report(rows)
    arguments = {
        "cache": str(cache),
        "references": sorted(references),
        "flow_filter": args.flow_filter,
        "discovery_shares_pct": discovery_shares,
        "capitals": capitals,
        "ranges": ranges,
        "fees_ppm": fees,
        "hook_modes": args.hook_modes,
        "principal_caps_bps": principal_caps,
        "max_iterations": max_iterations,
        "min_spread_ticks": args.min_spread_ticks,
        "min_profits_usdc": min_profits,
        "gas_penalties_usdc": gas_penalties,
        "start_day": args.start_day,
        "duration_days": args.duration_days,
        "orders": len(orders),
    }
    json_path, csv_path = write_results(args.output_dir, metadata, arguments, rows)
    print(f"\nArtifacts:\n  {json_path}\n  {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
