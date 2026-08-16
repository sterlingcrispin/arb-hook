"""Candidate search for the current external/external scanner.

The execution engine handles Uniswap V2/V3 and PancakeSwap V2/V3 only. Aerodrome
is not supported, which rules out most Base memecoin liquidity, so a candidate
pair only qualifies when it has real depth on at least two of the four supported
venues.

The current production route again compares registered external venues. This
script remains useful for candidate-pool discovery, but historical measurements
show that volume and liquidity alone do not establish a profitable spread.
Token addresses are verified on-chain by reading symbol() and decimals(); any
address that does not respond is dropped rather than assumed.

Usage:
    BASE_RPC_URL=... python3 scripts/find_multivenue_pools.py
"""

import json
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor

RPC = os.environ["BASE_RPC_URL"]

WETH = "0x4200000000000000000000000000000000000006"

UNISWAP_V3_FACTORY = "0x33128a8fC17869897dcE68Ed026d694621f6FDfD"
PANCAKE_V3_FACTORY = "0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865"
UNISWAP_V2_FACTORY = "0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6"
PANCAKE_V2_FACTORY = "0x02a84c1b3BBD7401a5f7fa98a384EBC70bB5749E"

V3_FEES = [100, 500, 2500, 3000, 10000]

# Candidate Base tokens. Addresses are verified before use.
CANDIDATES = {
    "BRETT": "0x532f27101965dd16442E59d40670FaF5eBB142E4",
    "DEGEN": "0x4ed4E862860beD51a9570b96d89aF5E1B0Efefed",
    "TOSHI": "0xAC1Bd2486aAf3B5C0fc3Fd868558b082a531B2B4",
    "HIGHER": "0x0578d8A44db98B23BF096A382e016e29a5Ce0ffe",
    "VIRTUAL": "0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b",
    "AERO": "0x940181a94A35A4569E4529A3CDfB74e38FD98631",
    "KEYCAT": "0x9a26F5433671751C3276a065f57e5a02D2817973",
    "MIGGLES": "0xB1a03EdA10342529bBF8EF700fC808cb0b3E2a5D",
    "MOCHI": "0xF6e932Ca12afa26665dC4dDE7e27be02A7c02e50",
    "NORMIE": "0x7F12d13B34F5F4f0a9449c16Bcd42f0da47AF200",
    "USDC": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    "cbBTC": "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf",
    "DAI": "0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb",
}


def cast(args):
    out = subprocess.run(["cast", *args, "--rpc-url", RPC],
                         capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        return None
    return out.stdout.strip()


def verify_token(item):
    name, address = item
    symbol = cast(["call", address, "symbol()(string)"])
    decimals = cast(["call", address, "decimals()(uint8)"])
    if symbol is None or decimals is None:
        return name, address, None, None
    return name, address, symbol.strip('"'), decimals.split()[0]


def v3_pool(factory, token, fee):
    result = cast(["call", factory, "getPool(address,address,uint24)(address)", token, WETH, str(fee)])
    if not result or result.startswith("0x0000000000000000000000000000000000000000"):
        return None
    return result.split()[0]


def v2_pair(factory, token):
    result = cast(["call", factory, "getPair(address,address)(address)", token, WETH])
    if not result or result.startswith("0x0000000000000000000000000000000000000000"):
        return None
    return result.split()[0]


def weth_depth(pool):
    """WETH held by the pool: a venue-neutral proxy for tradable depth."""
    raw = cast(["call", WETH, "balanceOf(address)(uint256)", pool])
    if not raw:
        return 0.0
    return int(raw.split()[0].replace(",", "")) / 1e18


def scan(item):
    name, address, symbol, decimals = item
    venues = []
    for fee in V3_FEES:
        pool = v3_pool(UNISWAP_V3_FACTORY, address, fee)
        if pool:
            venues.append((f"UniV3-{fee}", pool, "uniswap"))
        pool = v3_pool(PANCAKE_V3_FACTORY, address, fee)
        if pool:
            venues.append((f"CakeV3-{fee}", pool, "pancake"))
    pool = v2_pair(UNISWAP_V2_FACTORY, address)
    if pool:
        venues.append(("UniV2", pool, "v2"))
    pool = v2_pair(PANCAKE_V2_FACTORY, address)
    if pool:
        venues.append(("CakeV2", pool, "v2"))

    scored = []
    for label, pool, kind in venues:
        depth = weth_depth(pool)
        if depth >= 1.0:  # ignore dust pools that cannot support any trade
            scored.append((depth, label, pool, kind))
    scored.sort(reverse=True)
    return name, symbol, decimals, scored


def main():
    print("verifying token addresses on-chain...")
    with ThreadPoolExecutor(max_workers=8) as pool:
        verified = list(pool.map(verify_token, CANDIDATES.items()))

    good = []
    for name, address, symbol, decimals in verified:
        if symbol is None:
            print(f"  DROP {name:8s} {address} - no symbol(), address unverified")
        else:
            good.append((name, address, symbol, decimals))
    print(f"  verified {len(good)}/{len(verified)}\n")

    print("enumerating pools against WETH across supported venues (>= 1 WETH depth)...\n")
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(scan, good))

    qualifying = []
    for name, symbol, decimals, scored in sorted(results, key=lambda r: -len(r[3])):
        tag = "OK " if len(scored) >= 2 else "   "
        print(f"{tag}{name:8s} ({symbol}, {decimals}d): {len(scored)} venue(s) with depth")
        for depth, label, pool_address, kind in scored[:5]:
            print(f"      {label:12s} {pool_address}  {depth:>12.2f} WETH  [{kind}]")
        if len(scored) >= 2:
            qualifying.append((name, scored))
        print()

    print("=" * 72)
    print("PAIRS SCREENABLE FOR INTRA-BLOCK MOVEMENT (top two venues each):\n")
    for name, scored in qualifying:
        (depth_a, label_a, pool_a, kind_a) = scored[0]
        (depth_b, label_b, pool_b, kind_b) = scored[1]
        if kind_a == "v2" or kind_b == "v2":
            note = "  # includes a V2 leg: tick script covers V3 only"
        else:
            note = ""
        print(f"# {name}: {label_a} ({depth_a:.1f} WETH) vs {label_b} ({depth_b:.1f} WETH){note}")
        print(f"POOL_A={pool_a} POOL_A_KIND={kind_a} \\")
        print(f"POOL_B={pool_b} POOL_B_KIND={kind_b} \\")
        print("  python3 scripts/sample_intrablock_spread.py 20000\n")


if __name__ == "__main__":
    main()
