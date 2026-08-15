"""Historical evidence for the retired external/external strategy.

Measuring the spread only shows what is left over. It cannot distinguish
"competitors closed the gap" from "the gap never opened" or from "each pool is
priced against venues we are not watching". Realized arbitrage is directly
observable: an atomic two-leg arb emits a Swap on both pools inside the SAME
transaction, so grouping Swap logs by transaction hash finds them exactly.

Reported per pool pair:
  * two-leg arbs: one transaction touching both pools (someone arbing A vs B)
  * same-block, different transaction: a swap on one pool followed by a swap on
    the other later in the block, which is what a backrunner looks like
  * solo swaps: a pool traded without the other reacting, which is what it looks
    like when a pool is priced against venues outside this pair

Usage:
    BASE_RPC_URL=... POOL_A=... POOL_B=... python3 scripts/find_realized_arbs.py [blocks]
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
LABEL = os.environ.get("PAIR_LABEL", "pair")

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


def decode_tick(data_hex):
    body = data_hex[2:]
    value = int(body[256:320], 16) & ((1 << 24) - 1)
    return value - (1 << 24) if value >= 1 << 23 else value


def decode_amount0(data_hex):
    """amount0 is the first non-indexed word, int256. Positive means token0 flowed
    INTO the pool, negative means it flowed OUT."""
    value = int(data_hex[2:][0:64], 16)
    return value - (1 << 256) if value >= 1 << 255 else value


def fetch(pool, kind, start, end):
    topic = PANCAKE_SWAP_TOPIC if kind == "pancake" else UNISWAP_SWAP_TOPIC
    events = []
    for lo in range(start, end + 1, CHUNK):
        hi = min(lo + CHUNK - 1, end)
        for entry in rpc("eth_getLogs", [{
            "address": pool, "topics": [topic],
            "fromBlock": hex(lo), "toBlock": hex(hi),
        }]):
            events.append({
                "block": int(entry["blockNumber"], 16),
                "index": int(entry["logIndex"], 16),
                "tx": entry["transactionHash"],
                "tick": decode_tick(entry["data"]),
                "amount0": decode_amount0(entry["data"]),
            })
    return events


def main():
    span = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    head = int(rpc("eth_blockNumber", []), 16)
    start, end = head - span, head
    print(f"{LABEL}: blocks {start}..{end} ({span}, ~{span * 2 / 3600:.1f}h)")

    a = fetch(POOL_A, POOL_A_KIND, start, end)
    b = fetch(POOL_B, POOL_B_KIND, start, end)
    print(f"  swaps: pool A {len(a)}, pool B {len(b)}")
    if not a and not b:
        print("  no activity")
        return

    tx_pools = defaultdict(set)
    tx_dir = defaultdict(dict)
    for event in a:
        tx_pools[event["tx"]].add("A")
        tx_dir[event["tx"]]["A"] = event["amount0"]
    for event in b:
        tx_pools[event["tx"]].add("B")
        tx_dir[event["tx"]]["B"] = event["amount0"]

    two_leg = [tx for tx, pools in tx_pools.items() if len(pools) == 2]

    # An arbitrage pushes token0 INTO one pool and pulls it OUT of the other, so
    # the amount0 signs oppose. A router splitting one large order across both
    # pools moves token0 the same way in each, so the signs agree.
    arbs, splits = [], []
    for tx in two_leg:
        d = tx_dir[tx]
        (arbs if (d["A"] > 0) != (d["B"] > 0) else splits).append(tx)

    by_block = defaultdict(lambda: defaultdict(set))
    for event in a:
        by_block[event["block"]][event["tx"]].add("A")
    for event in b:
        by_block[event["block"]][event["tx"]].add("B")

    same_block_multi_tx = 0
    for block, txs in by_block.items():
        touched = set()
        for pools in txs.values():
            touched |= pools
        if touched == {"A", "B"} and len(txs) > 1:
            same_block_multi_tx += 1

    total_tx = len(tx_pools)
    solo = total_tx - len(two_leg)

    print(f"\n  transactions touching BOTH pools                    : {len(two_leg)}")
    print(f"    of those, genuine arbitrage (opposing directions) : {len(arbs)}")
    print(f"    of those, router splits (same direction)          : {len(splits)}")
    print(f"  blocks where both pools traded in DIFFERENT txs     : {same_block_multi_tx}")
    print(f"  transactions touching only one pool                 : {solo}/{total_tx}"
          f" ({100 * solo / total_tx:.1f}%)")

    if arbs:
        print("\n  sample genuine arbs:")
        for tx in arbs[:5]:
            print(f"    {tx}")
    if not arbs:
        print("\n  No transaction arbed these two pools against each other.")
        print("  Each pool is being priced against venues outside this pair,")
        print("  so the residual spread between them is not a closable gap.")


if __name__ == "__main__":
    main()
