"""Reconstruct the INTRA-BLOCK tick spread between two V3 pools.

Reading pool state at block boundaries measures the residual spread left after
every in-block arbitrage has already run, so it systematically cannot see the
dislocation a backrunner would target. This script instead replays the exact
state sequence inside each block.

Both Uniswap V3 and PancakeSwap V3 emit the post-swap `tick` in their Swap
event, so ordering every Swap log by (blockNumber, logIndex) and tracking each
pool's running tick reproduces the state a transaction inserted at that point in
the block would have observed.

For each event the script reports the spread visible immediately after it. That
is what the hook would see if its trigger swap were ordered directly behind that
transaction. It also separates the spread at the block boundary, which is what
survives to the next block, so the two can be compared directly.

Usage:
    BASE_RPC_URL=... python3 scripts/sample_intrablock_spread.py [blocks]

Environment:
    POOL_A, POOL_A_FEE_BPS, POOL_A_KIND (uniswap|pancake)
    POOL_B, POOL_B_FEE_BPS, POOL_B_KIND
"""

import json
import os
import subprocess
import sys
from collections import defaultdict

UNISWAP_SWAP_TOPIC = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"
PANCAKE_SWAP_TOPIC = "0x19b47279256b2a23a1665c810c8d55a1758940ee09377d4f8d26497a3577dc83"

POOL_A = os.environ.get("POOL_A", "0xC211e1f853A898Bd1302385CCdE55f33a8C4B3f3")
POOL_B = os.environ.get("POOL_B", "0x7AeA2E8A3843516afa07293a10Ac8E49906dabD1")
POOL_A_KIND = os.environ.get("POOL_A_KIND", "pancake")
POOL_B_KIND = os.environ.get("POOL_B_KIND", "uniswap")
FEE_A = float(os.environ.get("POOL_A_FEE_BPS", "1"))
FEE_B = float(os.environ.get("POOL_B_FEE_BPS", "5"))
ROUND_TRIP_FEE_BPS = FEE_A + FEE_B
GATE_TICKS = int(os.environ.get("MIN_SPREAD_BPS", "10"))

RPC = os.environ["BASE_RPC_URL"]
CHUNK = int(os.environ.get("LOG_CHUNK", "800"))


def rpc(method, params):
    out = subprocess.run(
        ["cast", "rpc", method, "--rpc-url", RPC, "--raw", json.dumps(params)],
        capture_output=True, text=True, timeout=180,
    )
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:300])
    return json.loads(out.stdout)


def topic_for(kind):
    return PANCAKE_SWAP_TOPIC if kind == "pancake" else UNISWAP_SWAP_TOPIC


def decode_tick(data_hex):
    """Non-indexed layout, identical prefix in both Uniswap and Pancake Swap events:
    word0 amount0, word1 amount1, word2 sqrtPriceX96, word3 liquidity, word4 tick.
    So tick occupies hex characters 256:320."""
    body = data_hex[2:]
    word = body[256:320]
    value = int(word, 16) & ((1 << 24) - 1)
    return value - (1 << 24) if value >= 1 << 23 else value


def fetch(pool, kind, start, end):
    events = []
    for lo in range(start, end + 1, CHUNK):
        hi = min(lo + CHUNK - 1, end)
        logs = rpc("eth_getLogs", [{
            "address": pool,
            "topics": [topic_for(kind)],
            "fromBlock": hex(lo),
            "toBlock": hex(hi),
        }])
        for entry in logs:
            events.append((
                int(entry["blockNumber"], 16),
                int(entry["logIndex"], 16),
                decode_tick(entry["data"]),
            ))
    return events


def main():
    span = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    head = int(rpc("eth_blockNumber", []), 16)
    start, end = head - span, head
    print(f"replaying blocks {start}..{end} ({span} blocks, ~{span * 2 / 60:.0f} min)")

    events_a = fetch(POOL_A, POOL_A_KIND, start, end)
    events_b = fetch(POOL_B, POOL_B_KIND, start, end)
    print(f"  pool A swaps: {len(events_a)}   pool B swaps: {len(events_b)}")
    if not events_a or not events_b:
        print("  insufficient activity to reconstruct spreads")
        return

    merged = sorted(
        [(b, i, "A", t) for b, i, t in events_a] + [(b, i, "B", t) for b, i, t in events_b]
    )

    tick_a = tick_b = None
    intrablock = []          # spread visible right after each swap
    per_block = defaultdict(list)
    for block, _index, which, tick in merged:
        if which == "A":
            tick_a = tick
        else:
            tick_b = tick
        if tick_a is not None and tick_b is not None:
            spread = abs(tick_a - tick_b)
            intrablock.append(spread)
            per_block[block].append(spread)

    # Spread surviving to the end of each block: what boundary sampling sees.
    boundary = [spreads[-1] for spreads in per_block.values()]
    # Largest dislocation opened at any point inside each block.
    peak = [max(spreads) for spreads in per_block.values()]

    def summarize(label, values):
        if not values:
            print(f"  {label}: no data")
            return
        ordered = sorted(values)
        n = len(ordered)
        over_fee = sum(1 for v in ordered if v > ROUND_TRIP_FEE_BPS)
        over_gate = sum(1 for v in ordered if v >= GATE_TICKS)
        over_both = sum(1 for v in ordered if v >= GATE_TICKS and v > ROUND_TRIP_FEE_BPS)
        print(f"\n  {label}  (n={n})")
        print(f"    median {ordered[n // 2]}   p90 {ordered[min(n - 1, int(n * 0.9))]}   "
              f"p99 {ordered[min(n - 1, int(n * 0.99))]}   max {ordered[-1]}")
        print(f"    > {ROUND_TRIP_FEE_BPS:.0f} bps fees : {over_fee}/{n} ({100 * over_fee / n:.1f}%)")
        print(f"    >= {GATE_TICKS}-tick gate : {over_gate}/{n} ({100 * over_gate / n:.1f}%)")
        print(f"    clears BOTH      : {over_both}/{n} ({100 * over_both / n:.1f}%)")

    print(f"\nround-trip pool fees: {ROUND_TRIP_FEE_BPS:.0f} bps    "
          f"minSpreadBps gate: {GATE_TICKS} ticks")

    summarize("A) spread right after each swap (what a backrunner sees)", intrablock)
    summarize("B) spread at block boundary (what my earlier sampling saw)", boundary)
    summarize("C) peak dislocation opened within each block", peak)

    # How far does any single swap move its own pool? A dislocation can only open
    # if some trade is large enough relative to liquidity to push the price.
    moves = []
    last = {}
    for block, _index, which, tick in merged:
        if which in last:
            moves.append(abs(tick - last[which]))
        last[which] = tick
    if moves:
        moves.sort()
        n = len(moves)
        print(f"\n  per-swap tick movement (n={n})")
        print(f"    median {moves[n // 2]}   p90 {moves[min(n - 1, int(n * 0.9))]}   "
              f"p99 {moves[min(n - 1, int(n * 0.99))]}   max {moves[-1]}")
        big = sum(1 for m in moves if m >= GATE_TICKS)
        print(f"    swaps moving >= {GATE_TICKS} ticks: {big}/{n} ({100 * big / n:.2f}%)")
        print("    a dislocation worth trading needs a single swap to move one pool")
        print("    materially further than the other, so this bounds what is possible")

    tradable = [s for s in intrablock if s >= GATE_TICKS and s > ROUND_TRIP_FEE_BPS]
    blocks_with = sum(
        1 for spreads in per_block.values()
        if any(s >= GATE_TICKS and s > ROUND_TRIP_FEE_BPS for s in spreads)
    )
    print(f"\n  tradable moments: {len(tradable)} across {blocks_with} distinct blocks "
          f"out of {len(per_block)} active blocks")
    if blocks_with:
        rate = blocks_with / span
        print(f"  a randomly placed trigger lands in a tradable block "
              f"~{100 * rate:.3f}% of the time ({1 / rate:.0f} blocks between)")


if __name__ == "__main__":
    main()
