"""Sample the live tick spread between the two cbBTC/WETH canary pools.

The hook gates V3/V3 routes on the absolute tick difference between the two
pools (minSpreadBps, currently 10). One tick is approximately one basis point,
so this measures directly what the hook would see, historically, block by block.

A round trip must also clear both pool fees: Pancake 0.01% + Uniswap 0.05% =
6 bps, plus gas. So a spread only represents a real opportunity when it exceeds
roughly 6 ticks plus the gas-equivalent margin.
"""

import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

PANCAKE = os.environ.get("POOL_A", "0xC211e1f853A898Bd1302385CCdE55f33a8C4B3f3")
UNISWAP = os.environ.get("POOL_B", "0x7AeA2E8A3843516afa07293a10Ac8E49906dabD1")
PANCAKE_FEE_BPS = float(os.environ.get("POOL_A_FEE_BPS", "1"))
UNISWAP_FEE_BPS = float(os.environ.get("POOL_B_FEE_BPS", "5"))
ROUND_TRIP_FEE_BPS = PANCAKE_FEE_BPS + UNISWAP_FEE_BPS

RPC = os.environ["BASE_RPC_URL"]


def cast(args):
    out = subprocess.run(["cast", *args, "--rpc-url", RPC],
                         capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:200])
    return out.stdout.strip()


def tick_at(pool, block):
    """slot0().tick for a pool at a given block. Pancake and Uniswap slot0 differ
    in later fields, but tick is the second value in both, so one decode works."""
    raw = cast(["call", pool, "slot0()", "--block", str(block)])
    body = raw[2:]
    word = body[64:128]
    value = int(word, 16)
    if value >= 1 << 255:
        value -= 1 << 256
    # tick is int24 packed in a 32-byte word; sign-extend from 24 bits.
    value &= (1 << 24) - 1
    if value >= 1 << 23:
        value -= 1 << 24
    return value


def sample(block):
    try:
        return block, tick_at(PANCAKE, block), tick_at(UNISWAP, block)
    except Exception as exc:  # noqa: BLE001 - report and continue sampling
        return block, None, str(exc)


def main():
    samples = int(sys.argv[1]) if len(sys.argv) > 1 else 40
    stride = int(sys.argv[2]) if len(sys.argv) > 2 else 300  # ~10 min at 2s blocks

    head = int(cast(["block-number"]))
    blocks = [head - i * stride for i in range(samples)]
    print(f"head block {head}, sampling {samples} blocks every {stride} "
          f"(~{stride * 2 / 60:.0f} min apart, spanning ~{samples * stride * 2 / 3600:.1f}h)")

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(sample, blocks))

    spreads = []
    errors = 0
    for block, pancake_tick, uniswap_tick in sorted(results):
        if pancake_tick is None:
            errors += 1
            continue
        spread = abs(pancake_tick - uniswap_tick)
        spreads.append(spread)

    if not spreads:
        print("no samples succeeded")
        return

    spreads.sort()
    count = len(spreads)

    def pct(p):
        return spreads[min(count - 1, int(count * p))]

    over_fee = sum(1 for s in spreads if s > ROUND_TRIP_FEE_BPS)
    over_gate = sum(1 for s in spreads if s >= 10)
    over_both = sum(1 for s in spreads if s >= 10 and s > ROUND_TRIP_FEE_BPS)

    print(f"\nsamples: {count} ({errors} failed)")
    print(f"  tick spread min / median / p90 / max : "
          f"{spreads[0]} / {pct(0.5)} / {pct(0.9)} / {spreads[-1]}")
    print(f"  mean                                 : {sum(spreads) / count:.2f}")
    print(f"\nround-trip pool fees                   : {ROUND_TRIP_FEE_BPS:.0f} bps "
          f"(pancake {PANCAKE_FEE_BPS:.0f} + uniswap {UNISWAP_FEE_BPS:.0f})")
    print(f"  blocks with spread > fees            : {over_fee}/{count} "
          f"({100 * over_fee / count:.1f}%)")
    print(f"  blocks passing minSpreadBps=10 gate  : {over_gate}/{count} "
          f"({100 * over_gate / count:.1f}%)")
    print(f"  blocks passing BOTH                  : {over_both}/{count} "
          f"({100 * over_both / count:.1f}%)")

    print("\n  spread distribution:")
    for lo, hi in ((0, 1), (1, 3), (3, 6), (6, 10), (10, 20), (20, 10**9)):
        n = sum(1 for s in spreads if lo <= s < hi)
        bar = "#" * int(40 * n / count)
        label = f"{lo}-{hi}" if hi < 10**9 else f"{lo}+"
        print(f"    {label:>7} ticks: {n:>3} {bar}")


if __name__ == "__main__":
    main()
