#!/usr/bin/env python3
"""Model Base WETH/USDC swap sizes and arrival rates from onchain events.

The model deliberately separates observed market flow from assumed routing
share. A new pool's share cannot be inferred from historical swaps on existing
venues, so projections are emitted at explicit hypothetical shares.

Usage:
    BASE_RPC_URL=... python3 scripts/model_swap_flow.py --days 7
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import math
import os
import statistics
import threading
import time
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]
WETH = "0x4200000000000000000000000000000000000006"
USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
POOL_MANAGER = "0x498581ff718922c3f8e6a244956af099b2652b2b"

V3_SWAP_TOPIC = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"
PANCAKE_V3_SWAP_TOPIC = "0x19b47279256b2a23a1665c810c8d55a1758940ee09377d4f8d26497a3577dc83"
V4_SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"

THRESHOLDS_USDC = (1, 5, 10, 25, 50, 75, 100, 150, 250, 500, 1_000, 5_000, 10_000)
QUANTILES = (0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99, 0.999)
KNOWN_CALLERS = {
    "0x2626664c2603336e57b271c5c0b26f421741e481": "Uniswap SwapRouter02",
    "0x6ff5693b99212da76ad316178a184ab56d299b43": "Uniswap Universal Router",
}


@dataclass(frozen=True)
class Pool:
    key: str
    label: str
    dex: str
    address: str
    fee_bps: float
    topic: str
    pool_id: str = ""


POOLS = (
    Pool(
        "uniswap_v3_1bp",
        "Uniswap v3 1 bp",
        "uniswap-v3",
        "0xb4cb800910b228ed3d0834cf79d697127bbb00e5",
        1.0,
        V3_SWAP_TOPIC,
    ),
    Pool(
        "uniswap_v3_5bp",
        "Uniswap v3 5 bp",
        "uniswap-v3",
        "0xd0b53d9277642d899df5c87a3966a349a798f224",
        5.0,
        V3_SWAP_TOPIC,
    ),
    Pool(
        "uniswap_v3_30bp",
        "Uniswap v3 30 bp",
        "uniswap-v3",
        "0x6c561b446416e1a00e8e93e221854d6ea4171372",
        30.0,
        V3_SWAP_TOPIC,
    ),
    Pool(
        "pancake_v3_1bp",
        "Pancake v3 1 bp",
        "pancake-v3",
        "0x72ab388e2e2f6facef59e3c3fa2c4e29011c2d38",
        1.0,
        PANCAKE_V3_SWAP_TOPIC,
    ),
    Pool(
        "aerodrome_5bp_a",
        "Aerodrome Slipstream 5 bp A",
        "aerodrome-slipstream",
        "0x3fe04a59ebd38cf06080a6f60a98d124eb59392a",
        5.0,
        V3_SWAP_TOPIC,
    ),
    Pool(
        "aerodrome_5bp_b",
        "Aerodrome Slipstream 5 bp B",
        "aerodrome-slipstream",
        "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59",
        5.0,
        V3_SWAP_TOPIC,
    ),
    Pool(
        "uniswap_v4_5bp",
        "Uniswap v4 5 bp",
        "uniswap-v4",
        POOL_MANAGER,
        5.0,
        V4_SWAP_TOPIC,
        "0x90333bb05c258fe0dddb2840ef66f1a05165aa7dac6815d24e807cc6ebd943a0",
    ),
)


class Rpc:
    def __init__(self, url: str):
        self.url = url
        self._ids = 0
        self._lock = threading.Lock()

    def call(self, method: str, params: list, timeout: int = 90):
        with self._lock:
            self._ids += 1
            request_id = self._ids
        payload = json.dumps(
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        ).encode()
        request = urllib.request.Request(
            self.url, data=payload, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.load(response)
        if "error" in body:
            raise RuntimeError(f"{method}: {body['error']}")
        return body["result"]

    def block(self, number: int | str) -> dict:
        tag = number if isinstance(number, str) else hex(number)
        return self.call("eth_getBlockByNumber", [tag, False])

    def logs(self, pool: Pool, start: int, end: int) -> list[dict]:
        topics = [pool.topic]
        if pool.pool_id:
            topics.append(pool.pool_id)
        return self.call(
            "eth_getLogs",
            [{"address": pool.address, "fromBlock": hex(start), "toBlock": hex(end), "topics": topics}],
        )

    def token(self, address: str, selector: str) -> str:
        result = self.call("eth_call", [{"to": address, "data": selector}, "latest"])
        return "0x" + result[-40:].lower()


def block_number(block: dict) -> int:
    return int(block["number"], 16)


def block_timestamp(block: dict) -> int:
    return int(block["timestamp"], 16)


def block_at_timestamp(rpc: Rpc, end_block: int, target: int) -> int:
    low, high = 0, end_block
    while low < high:
        middle = (low + high) // 2
        if block_timestamp(rpc.block(middle)) < target:
            low = middle + 1
        else:
            high = middle
    return low


def verify_pools(rpc: Rpc, pools: Iterable[Pool]) -> None:
    for pool in pools:
        if pool.pool_id:
            continue
        token0 = rpc.token(pool.address, "0x0dfe1681")
        token1 = rpc.token(pool.address, "0xd21220a7")
        if token0 != WETH or token1 != USDC:
            raise RuntimeError(f"{pool.label} token order is {token0}/{token1}, expected WETH/USDC")


def fetch_range(rpc: Rpc, pool: Pool, start: int, end: int) -> list[dict]:
    last_error = None
    for attempt in range(3):
        try:
            return rpc.logs(pool, start, end)
        except Exception as exc:  # noqa: BLE001 - retry provider failures before splitting
            last_error = exc
            time.sleep(0.5 * (2**attempt))
    if start == end:
        raise RuntimeError(f"failed to fetch {pool.key} block {start}: {last_error}")
    middle = (start + end) // 2
    return fetch_range(rpc, pool, start, middle) + fetch_range(rpc, pool, middle + 1, end)


def signed_word(data: str, index: int) -> int:
    start = 2 + index * 64
    value = int(data[start : start + 64], 16)
    return value - (1 << 256) if value >= 1 << 255 else value


def topic_address(topic: str) -> str:
    return "0x" + topic[-40:].lower()


def normalize_log(
    pool: Pool,
    log: dict,
    start_block: int,
    end_block: int,
    start_time: int,
    end_time: int,
) -> dict | None:
    amount0 = signed_word(log["data"], 0)
    amount1 = signed_word(log["data"], 1)
    if amount1 == 0:
        return None
    number = int(log["blockNumber"], 16)
    if "blockTimestamp" in log:
        timestamp = int(log["blockTimestamp"], 16)
    else:
        elapsed = (number - start_block) / max(1, end_block - start_block)
        timestamp = round(start_time + elapsed * (end_time - start_time))
    sender_index = 2 if pool.pool_id else 1
    return {
        "pool": pool.key,
        "block": number,
        "timestamp": timestamp,
        "tx": log["transactionHash"].lower(),
        "sender": topic_address(log["topics"][sender_index]),
        "usdc": abs(amount1) / 1e6,
        "weth_raw": abs(amount0),
        "direction": "usdc_to_weth" if amount1 > 0 else "weth_to_usdc",
    }


def fetch_events(
    rpc: Rpc,
    pools: tuple[Pool, ...],
    start_block: int,
    end_block: int,
    start_time: int,
    end_time: int,
    chunk_blocks: int,
    workers: int,
) -> list[dict]:
    tasks = []
    for pool in pools:
        for start in range(start_block, end_block + 1, chunk_blocks):
            tasks.append((pool, start, min(end_block, start + chunk_blocks - 1)))

    events = []
    completed = 0
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(fetch_range, rpc, pool, start, end): (pool, start, end)
            for pool, start, end in tasks
        }
        for future in as_completed(futures):
            pool, _, _ = futures[future]
            logs = future.result()
            for log in logs:
                event = normalize_log(
                    pool, log, start_block, end_block, start_time, end_time
                )
                if event is not None:
                    events.append(event)
            completed += 1
            if completed % 25 == 0 or completed == len(tasks):
                print(f"Fetched {completed}/{len(tasks)} chunks; {len(events):,} swaps", flush=True)
    events.sort(key=lambda event: (event["block"], event["tx"], event["pool"]))
    return events


def write_event_cache(path: Path, metadata: dict, events: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(path, "wt") as handle:
        handle.write(json.dumps({"metadata": metadata}) + "\n")
        for event in events:
            handle.write(json.dumps(event, separators=(",", ":")) + "\n")


def read_event_cache(path: Path) -> tuple[dict, list[dict]]:
    with gzip.open(path, "rt") as handle:
        metadata = json.loads(next(handle))["metadata"]
        events = [json.loads(line) for line in handle]
    return metadata, events


def quantile(sorted_values: list[float], probability: float) -> float:
    if not sorted_values:
        return 0.0
    position = probability * (len(sorted_values) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return sorted_values[lower]
    weight = position - lower
    return sorted_values[lower] * (1 - weight) + sorted_values[upper] * weight


def weighted_quantile(sorted_values: list[float], probability: float) -> float:
    total = sum(sorted_values)
    if total <= 0:
        return 0.0
    target = total * probability
    cumulative = 0.0
    for value in sorted_values:
        cumulative += value
        if cumulative >= target:
            return value
    return sorted_values[-1]


def bucket_counts(events: list[dict], start_time: int, end_time: int, seconds: int) -> list[int]:
    bucket_total = max(1, math.ceil((end_time - start_time) / seconds))
    counts = Counter((event["timestamp"] - start_time) // seconds for event in events)
    return [counts[bucket] for bucket in range(bucket_total)]


def bucket_volume(events: list[dict], start_time: int, end_time: int, seconds: int) -> list[float]:
    bucket_total = max(1, math.ceil((end_time - start_time) / seconds))
    volume = defaultdict(float)
    for event in events:
        volume[(event["timestamp"] - start_time) // seconds] += event["usdc"]
    return [volume[bucket] for bucket in range(bucket_total)]


def count_model(hourly_counts: list[int]) -> dict:
    mean = statistics.fmean(hourly_counts) if hourly_counts else 0.0
    variance = statistics.variance(hourly_counts) if len(hourly_counts) > 1 else 0.0
    if mean > 0 and variance > mean:
        dispersion = mean * mean / (variance - mean)
        probability = dispersion / (dispersion + mean)
        family = "negative_binomial"
    else:
        dispersion = 0.0
        probability = 0.0
        family = "poisson"
    return {
        "family": family,
        "hourly_mean": mean,
        "hourly_variance": variance,
        "fano_factor": variance / mean if mean else 0.0,
        "negative_binomial_r": dispersion,
        "negative_binomial_p": probability,
        "hourly_quantiles": {
            "p10": quantile(sorted(hourly_counts), 0.10),
            "p50": quantile(sorted(hourly_counts), 0.50),
            "p90": quantile(sorted(hourly_counts), 0.90),
            "p99": quantile(sorted(hourly_counts), 0.99),
            "max": max(hourly_counts, default=0),
        },
    }


def flow_stats(events: list[dict], start_time: int, end_time: int) -> dict:
    duration_days = (end_time - start_time) / 86_400
    sizes = sorted(event["usdc"] for event in events if event["usdc"] > 0)
    timestamps = sorted(event["timestamp"] for event in events)
    hourly = bucket_counts(events, start_time, end_time, 3_600)
    daily = bucket_counts(events, start_time, end_time, 86_400)
    daily_volume = bucket_volume(events, start_time, end_time, 86_400)
    callers = Counter(event["sender"] for event in events)
    caller_volume = Counter()
    for event in events:
        caller_volume[event["sender"]] += event["usdc"]
    caller_counts = sorted(callers.values(), reverse=True)
    directions = Counter(event["direction"] for event in events)
    log_sizes = [math.log(size) for size in sizes if size >= 0.01]
    tail_threshold = quantile(sizes, 0.90)
    tail = [size for size in sizes if size >= tail_threshold and size > 0]
    tail_denominator = sum(math.log(size / tail_threshold) for size in tail if size > tail_threshold)
    pareto_alpha = len(tail) / tail_denominator if tail_denominator else 0.0
    intervals = [later - earlier for earlier, later in zip(timestamps, timestamps[1:])]
    intervals.sort()

    stats = {
        "events": len(events),
        "unique_transactions": len({event["tx"] for event in events}),
        "unique_callers": len(callers),
        "events_per_day": len(events) / duration_days,
        "volume_usdc": sum(sizes),
        "volume_usdc_per_day": sum(sizes) / duration_days,
        "mean_size_usdc": statistics.fmean(sizes) if sizes else 0.0,
        "volume_weighted_median_size_usdc": weighted_quantile(sizes, 0.50),
        "size_quantiles_usdc": {f"p{probability * 100:g}": quantile(sizes, probability) for probability in QUANTILES},
        "daily_event_quantiles": {
            "p10": quantile(sorted(daily), 0.10),
            "p50": quantile(sorted(daily), 0.50),
            "p90": quantile(sorted(daily), 0.90),
        },
        "daily_volume_quantiles_usdc": {
            "p10": quantile(sorted(daily_volume), 0.10),
            "p50": quantile(sorted(daily_volume), 0.50),
            "p90": quantile(sorted(daily_volume), 0.90),
        },
        "interarrival_seconds": {
            "p50": quantile(intervals, 0.50),
            "p90": quantile(intervals, 0.90),
            "p99": quantile(intervals, 0.99),
        },
        "direction_fraction": {
            direction: count / len(events) for direction, count in directions.items()
        } if events else {},
        "caller_concentration": {
            "top1_event_fraction": sum(caller_counts[:1]) / len(events) if events else 0.0,
            "top5_event_fraction": sum(caller_counts[:5]) / len(events) if events else 0.0,
            "top10_event_fraction": sum(caller_counts[:10]) / len(events) if events else 0.0,
        },
        "top_callers": [
            {
                "address": address,
                "label": KNOWN_CALLERS.get(address, "unlabelled"),
                "events": count,
                "event_fraction": count / len(events),
                "volume_usdc": caller_volume[address],
            }
            for address, count in callers.most_common(10)
        ],
        "arrival_model": count_model(hourly),
        "size_model": {
            "body": "lognormal",
            "log_mu": statistics.fmean(log_sizes) if log_sizes else 0.0,
            "log_sigma": statistics.stdev(log_sizes) if len(log_sizes) > 1 else 0.0,
            "tail": "pareto",
            "tail_threshold_usdc_p90": tail_threshold,
            "pareto_alpha": pareto_alpha,
        },
        "thresholds": {},
    }
    for threshold in THRESHOLDS_USDC:
        qualifying_events = [event for event in events if event["usdc"] >= threshold]
        qualifying = [event["usdc"] for event in qualifying_events]
        threshold_daily = bucket_counts(qualifying_events, start_time, end_time, 86_400)
        stats["thresholds"][str(threshold)] = {
            "events": len(qualifying),
            "events_per_day": len(qualifying) / duration_days,
            "event_fraction": len(qualifying) / len(sizes) if sizes else 0.0,
            "volume_fraction": sum(qualifying) / sum(sizes) if sizes and sum(sizes) else 0.0,
            "daily_event_quantiles": {
                "p10": quantile(sorted(threshold_daily), 0.10),
                "p50": quantile(sorted(threshold_daily), 0.50),
                "p90": quantile(sorted(threshold_daily), 0.90),
            },
            "arrival_model": count_model(
                bucket_counts(qualifying_events, start_time, end_time, 3_600)
            ),
        }
    return stats


def market_order_proxy(events: list[dict]) -> list[dict]:
    by_transaction = defaultdict(list)
    for event in events:
        by_transaction[event["tx"]].append(event)
    proxy = []
    for transaction_events in by_transaction.values():
        largest = max(transaction_events, key=lambda event: event["usdc"])
        item = dict(largest)
        item["pool"] = "market_order_proxy"
        item["observed_pool_count"] = len({event["pool"] for event in transaction_events})
        proxy.append(item)
    proxy.sort(key=lambda event: (event["block"], event["tx"]))
    return proxy


def interpolate(points: list[dict], size: float, field: str) -> float | None:
    if size < points[0]["trade_usdc"] / 1e6 or size > points[-1]["trade_usdc"] / 1e6:
        return None
    for left, right in zip(points, points[1:]):
        x0 = left["trade_usdc"] / 1e6
        x1 = right["trade_usdc"] / 1e6
        if x0 <= size <= x1:
            if x0 == x1:
                return float(left[field])
            weight = (size - x0) / (x1 - x0)
            return float(left[field]) * (1 - weight) + float(right[field]) * weight
    return float(points[-1][field])


def weight_sweep(path: Path, source_events: list[dict], duration_days: float) -> list[dict]:
    if not path.exists():
        return []
    rows = json.loads(path.read_text())["results"]
    groups = defaultdict(list)
    for row in rows:
        if not row.get("success") or row.get("reference_name") != "deep":
            continue
        if row["max_iterations"] != 10 or row["principal_cap_bps"] != 1000:
            continue
        key = (
            row["pool_fee"],
            row["tick_spacing"],
            row["lp_usdc_per_side"],
            row["half_range_ticks"],
        )
        groups[key].append(row)

    weighted = []
    for key, points in groups.items():
        points.sort(key=lambda row: row["trade_usdc"])
        if len(points) < 2:
            continue
        modeled = 0
        route_winners = 0
        arb_events = 0
        totals = defaultdict(float)
        competitive = defaultdict(float)
        for event in source_events:
            size = event["usdc"]
            route_gap = interpolate(points, size, "effective_quote_gap_bps")
            if route_gap is None:
                continue
            modeled += 1
            metrics = {
                "lp_pnl_usdc": interpolate(points, size, "hook_lp_pnl_usdc_raw") / 1e6,
                "rebate_usdc": interpolate(points, size, "hook_profit_usdc_raw") / 1e6,
                "residual_usdc": interpolate(points, size, "residual_profit_usdc_raw") / 1e6,
                "gas_usdc": interpolate(points, size, "gas_overhead_usdc_raw") / 1e6,
            }
            for field, value in metrics.items():
                totals[field] += value
            if metrics["rebate_usdc"] > 0:
                arb_events += 1
            if route_gap <= 0:
                route_winners += 1
                for field, value in metrics.items():
                    competitive[field] += value
        pool_fee, tick_spacing, capital, half_range = key
        weighted.append(
            {
                "pool_fee_ppm": pool_fee,
                "pool_fee_bps": pool_fee / 100,
                "tick_spacing": tick_spacing,
                "lp_usdc_per_side": capital / 1e6,
                "half_range_ticks": half_range,
                "modeled_trade_min_usdc": points[0]["trade_usdc"] / 1e6,
                "modeled_trade_max_usdc": points[-1]["trade_usdc"] / 1e6,
                "modeled_event_fraction": modeled / len(source_events) if source_events else 0.0,
                "modeled_events_per_day": modeled / duration_days,
                "arb_events_per_day": arb_events / duration_days,
                "route_winner_events_per_day": route_winners / duration_days,
                "route_winner_fraction_of_modeled": route_winners / modeled if modeled else 0.0,
                **{f"unconstrained_{field}_per_day": value / duration_days for field, value in totals.items()},
                **{f"route_winner_{field}_per_day": value / duration_days for field, value in competitive.items()},
            }
        )
    weighted.sort(key=lambda row: row.get("route_winner_lp_pnl_usdc_per_day", 0), reverse=True)
    return weighted


def projection(stats: dict, shares: list[float]) -> list[dict]:
    rows = []
    for share in shares:
        row = {
            "market_share_pct": share,
            "events_per_day": stats["events_per_day"] * share / 100,
            "volume_usdc_per_day": stats["volume_usdc_per_day"] * share / 100,
        }
        for threshold in (50, 75, 100, 150):
            row[f"events_ge_{threshold}_per_day"] = (
                stats["thresholds"][str(threshold)]["events_per_day"] * share / 100
            )
        rows.append(row)
    return rows


def write_outputs(output_dir: Path, stem: str, payload: dict) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / f"{stem}.json"
    csv_path = output_dir / f"{stem}-pools.csv"
    json_path.write_text(json.dumps(payload, indent=2) + "\n")
    fields = [
        "key",
        "label",
        "dex",
        "fee_bps",
        "events",
        "events_per_day",
        "volume_usdc_per_day",
        "median_size_usdc",
        "p90_size_usdc",
        "p99_size_usdc",
        "events_ge_100_per_day",
        "fano_factor",
    ]
    with csv_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for pool in POOLS:
            stats = payload["pools"][pool.key]["stats"]
            writer.writerow(
                {
                    "key": pool.key,
                    "label": pool.label,
                    "dex": pool.dex,
                    "fee_bps": pool.fee_bps,
                    "events": stats["events"],
                    "events_per_day": stats["events_per_day"],
                    "volume_usdc_per_day": stats["volume_usdc_per_day"],
                    "median_size_usdc": stats["size_quantiles_usdc"]["p50"],
                    "p90_size_usdc": stats["size_quantiles_usdc"]["p90"],
                    "p99_size_usdc": stats["size_quantiles_usdc"]["p99"],
                    "events_ge_100_per_day": stats["thresholds"]["100"]["events_per_day"],
                    "fano_factor": stats["arrival_model"]["fano_factor"],
                }
            )
    return json_path, csv_path


def print_report(payload: dict) -> None:
    print("\nObserved event flow")
    print("pool                       swaps/day  volume/day median     p90     p99  >=$100/day")
    for pool in POOLS:
        stats = payload["pools"][pool.key]["stats"]
        quantiles = stats["size_quantiles_usdc"]
        print(
            f"{pool.label:26} {stats['events_per_day']:>9,.0f} "
            f"${stats['volume_usdc_per_day']:>10,.0f} "
            f"${quantiles['p50']:>6,.2f} ${quantiles['p90']:>7,.2f} "
            f"${quantiles['p99']:>8,.2f} {stats['thresholds']['100']['events_per_day']:>10,.1f}"
        )

    reference = payload["pools"]["uniswap_v3_5bp"]["stats"]
    model = reference["arrival_model"]
    print("\nDeep Uniswap v3 5 bp reference model")
    print(
        f"  {reference['events_per_day']:,.0f} swaps/day, ${reference['volume_usdc_per_day']:,.0f}/day; "
        f"hourly count model={model['family']} (Fano {model['fano_factor']:.2f})"
    )
    print(
        f"  median ${reference['size_quantiles_usdc']['p50']:,.2f}, "
        f"p90 ${reference['size_quantiles_usdc']['p90']:,.2f}, "
        f"p99 ${reference['size_quantiles_usdc']['p99']:,.2f}"
    )
    print("  hypothetical shares of that pool's observed flow:")
    for row in payload["reference_flow_projections"]:
        print(
            f"    {row['market_share_pct']:>4.1f}%: {row['events_per_day']:>7.1f} swaps/day, "
            f"{row['events_ge_100_per_day']:>5.1f} >=$100, ${row['volume_usdc_per_day']:>9,.0f}/day"
        )

    weighted = payload.get("sweep_weighting", [])
    if weighted:
        print("\nExisting frontier sweep weighted by deep-pool USDC->WETH trades in its $50-$150 modeled slice")
        print("fee   LP/side range  covered/day route-win/day LP PnL/day at 1% observed share")
        for row in weighted[:8]:
            pnl = row.get("route_winner_lp_pnl_usdc_per_day", 0) * 0.01
            print(
                f"{row['pool_fee_bps']:>4.2f}bp ${row['lp_usdc_per_side']:<7,.0f} "
                f"{row['half_range_ticks']:>5}t {row['modeled_events_per_day']:>11,.0f} "
                f"{row['route_winner_events_per_day']:>13,.0f} ${pnl:>10,.2f}"
            )
        executing = sorted(
            (row for row in weighted if row["arb_events_per_day"] > 0),
            key=lambda row: row.get("route_winner_rebate_usdc_per_day", 0),
            reverse=True,
        )
        print("\nRoute-competitive rows that also execute the hook")
        print("fee   LP/side range  arb/day route-win/day rebate/day at 1% observed share")
        for row in executing[:8]:
            rebate = row.get("route_winner_rebate_usdc_per_day", 0) * 0.01
            print(
                f"{row['pool_fee_bps']:>4.2f}bp ${row['lp_usdc_per_side']:<7,.0f} "
                f"{row['half_range_ticks']:>5}t {row['arb_events_per_day']:>8,.0f} "
                f"{row['route_winner_events_per_day']:>13,.0f} ${rebate:>10,.3f}"
            )


def parse_shares(value: str) -> list[float]:
    shares = [float(item.strip()) for item in value.split(",") if item.strip()]
    if not shares or any(share < 0 or share > 100 for share in shares):
        raise argparse.ArgumentTypeError("shares must be comma-separated percentages from 0 to 100")
    return shares


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(description=__doc__)
    command.add_argument("--rpc-url", default=os.environ.get("BASE_RPC_URL"))
    command.add_argument("--days", type=float, default=7.0)
    command.add_argument("--end-block", type=int)
    command.add_argument("--chunk-blocks", type=int, default=5_000)
    command.add_argument("--workers", type=int, default=6)
    command.add_argument("--shares", type=parse_shares, default=parse_shares("0.1,1,5"))
    command.add_argument("--refresh", action="store_true")
    command.add_argument("--output-dir", type=Path, default=ROOT / "artifacts" / "flow-model")
    command.add_argument(
        "--sweep-results",
        type=Path,
        default=ROOT / "artifacts" / "frontier" / "v4-parameter-sweep-50052773.json",
    )
    return command


def main() -> int:
    args = parser().parse_args()
    if not args.rpc_url:
        raise SystemExit("BASE_RPC_URL or --rpc-url is required")
    if args.days <= 0 or args.chunk_blocks <= 0 or args.workers <= 0:
        raise SystemExit("days, chunk-blocks, and workers must be positive")

    rpc = Rpc(args.rpc_url)
    end = args.end_block or block_number(rpc.block("latest"))
    end_time = block_timestamp(rpc.block(end))
    start = block_at_timestamp(rpc, end, end_time - round(args.days * 86_400))
    start_time = block_timestamp(rpc.block(start))
    duration_days = (end_time - start_time) / 86_400
    stem = f"swap-flow-{start}-{end}"
    cache_path = args.output_dir / f"{stem}-events.jsonl.gz"
    metadata = {
        "chain_id": 8453,
        "start_block": start,
        "end_block": end,
        "start_timestamp": start_time,
        "end_timestamp": end_time,
        "duration_days": duration_days,
        "pools": [asdict(pool) for pool in POOLS],
    }

    verify_pools(rpc, POOLS)
    if cache_path.exists() and not args.refresh:
        cached_metadata, events = read_event_cache(cache_path)
        if cached_metadata != metadata:
            raise RuntimeError(f"cache metadata mismatch: {cache_path}")
        print(f"Loaded {len(events):,} cached swaps from {cache_path}")
    else:
        print(
            f"Fetching {duration_days:.2f} days across {len(POOLS)} pools, "
            f"Base blocks {start}..{end}..."
        )
        events = fetch_events(
            rpc,
            POOLS,
            start,
            end,
            start_time,
            end_time,
            args.chunk_blocks,
            args.workers,
        )
        write_event_cache(cache_path, metadata, events)

    by_pool = defaultdict(list)
    transaction_pools = defaultdict(set)
    for event in events:
        by_pool[event["pool"]].append(event)
        transaction_pools[event["tx"]].add(event["pool"])
    cross_pool_events = sum(1 for event in events if len(transaction_pools[event["tx"]]) > 1)
    proxy = market_order_proxy(events)
    pool_payload = {}
    for pool in POOLS:
        stats = flow_stats(by_pool[pool.key], start_time, end_time)
        pool_payload[pool.key] = {"metadata": asdict(pool), "stats": stats}

    aggregate_stats = flow_stats(events, start_time, end_time)
    aggregate_stats["cross_pool_event_fraction"] = cross_pool_events / len(events) if events else 0.0
    sender_pools = defaultdict(set)
    sender_events = Counter()
    sender_volume = Counter()
    for event in events:
        sender_pools[event["sender"]].add(event["pool"])
        sender_events[event["sender"]] += 1
        sender_volume[event["sender"]] += event["usdc"]
    aggregate_stats["multi_venue_sender_concentration"] = {
        f"at_least_{minimum}_pools": {
            "sender_count": sum(len(venues) >= minimum for venues in sender_pools.values()),
            "event_fraction": sum(
                count
                for sender, count in sender_events.items()
                if len(sender_pools[sender]) >= minimum
            ) / len(events),
            "volume_fraction": sum(
                volume
                for sender, volume in sender_volume.items()
                if len(sender_pools[sender]) >= minimum
            ) / aggregate_stats["volume_usdc"],
        }
        for minimum in (2, 3, 5, 7)
    }
    proxy_stats = flow_stats(proxy, start_time, end_time)
    reference_events = [
        event
        for event in by_pool["uniswap_v3_5bp"]
        if event["direction"] == "usdc_to_weth"
    ]
    payload = {
        "metadata": metadata,
        "limitations": [
            "Observed swaps include organic routing, split routes, arbitrage, and bot flow; event logs do not identify user intent.",
            "Market-order proxy takes the largest observed WETH/USDC leg per transaction and is not a perfect de-duplication.",
            "A new pool's routing share is not inferred; projections use explicit hypothetical shares.",
            "Sweep weighting linearly interpolates isolated reset-per-trigger fork scenarios and does not model evolving LP inventory.",
            "Sweep economics cover only trade sizes present in the selected result file; larger and smaller swaps are excluded.",
            "Sweep weighting uses only USDC-to-WETH events because the selected sweep does not model the reverse direction.",
        ],
        "pools": pool_payload,
        "aggregate_event_flow": aggregate_stats,
        "market_order_proxy": proxy_stats,
        "reference_flow_projections": projection(pool_payload["uniswap_v3_5bp"]["stats"], args.shares),
        "sweep_weighting_source": "uniswap_v3_5bp_usdc_to_weth",
        "sweep_weighting": weight_sweep(args.sweep_results, reference_events, duration_days),
    }
    json_path, csv_path = write_outputs(args.output_dir, stem, payload)
    print_report(payload)
    print(f"\nArtifacts:\n  {json_path}\n  {csv_path}\n  {cache_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
