#!/Users/sterlingcrispin/miniconda3/bin/python3
"""Monitor the Base canary and disable hook execution on a concrete invariant failure."""

from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.request


WETH = "0x4200000000000000000000000000000000000006"
USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
POOL_MANAGER = "0x498581ff718922c3f8e6a244956af099b2652b2b"
SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
SETTLED_TOPIC = "0x3304c4667c0287e82d18466387f012d2b5697e469fa81019b29b428bcf58a15c"

EXPECTED = {
    WETH: (2_700_000_000_000_000, 1, 27_000_000_000_000),
    USDC: (5_000_000, 1, 50_000),
}


def fail(message: str) -> None:
    raise SystemExit(message)


def normalize_address(value: str) -> str:
    value = value.lower()
    if not value.startswith("0x") or len(value) != 42:
        fail(f"invalid address: {value}")
    return value


RPC_URL = os.environ.get("BASE_RPC_URL", "")
HOOK = normalize_address(os.environ.get("HOOK", ""))
POOL_ID = os.environ.get("POOL_ID", "").lower()
OWNER = normalize_address(os.environ.get("EXPECTED_OWNER", ""))
WETH_ADAPTER = normalize_address(os.environ.get("WETH_ADAPTER", ""))
USDC_ADAPTER = normalize_address(os.environ.get("USDC_ADAPTER", ""))
EXPECTED_ITERATIONS = int(os.environ.get("EXPECTED_ITERATIONS", "10"))
POLL_SECONDS = float(os.environ.get("POLL_SECONDS", "4"))
AUTO_DISABLE = os.environ.get("AUTO_DISABLE", "false").lower() == "true"

if not RPC_URL:
    fail("BASE_RPC_URL is required")
if not POOL_ID.startswith("0x") or len(POOL_ID) != 66:
    fail("POOL_ID must be bytes32 hex")


_request_id = 0


def rpc(method: str, params: list[object]) -> object:
    global _request_id
    _request_id += 1
    payload = json.dumps({"jsonrpc": "2.0", "id": _request_id, "method": method, "params": params}).encode()
    request = urllib.request.Request(
        RPC_URL,
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "arb-hook2-canary-monitor/1"},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        body = json.load(response)
    if body.get("error"):
        raise RuntimeError(f"RPC {method}: {body['error']}")
    return body["result"]


def call(to: str, data: str) -> list[int]:
    result = str(rpc("eth_call", [{"to": to, "data": data}, "latest"]))
    raw = bytes.fromhex(result[2:])
    if len(raw) % 32:
        raise RuntimeError(f"malformed eth_call result from {to}")
    return [int.from_bytes(raw[i : i + 32], "big") for i in range(0, len(raw), 32)]


def address_word(value: str) -> str:
    return value[2:].rjust(64, "0")


def word_address(value: int) -> str:
    return "0x" + value.to_bytes(32, "big")[-20:].hex()


def signed(value: int) -> int:
    return value - (1 << 256) if value >= 1 << 255 else value


def token_label(token: str) -> tuple[str, int]:
    return ("WETH", 18) if token == WETH else ("USDC", 6)


def stamp(message: str) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S %Z"), message, flush=True)


def read_state() -> tuple[int, list[str]]:
    problems: list[str] = []
    code = str(rpc("eth_getCode", [HOOK, "latest"]))
    if code == "0x":
        return 0, ["hook bytecode disappeared"]

    actual_owner = word_address(call(HOOK, "0x8da5cb5b")[0])
    if actual_owner != OWNER:
        problems.append(f"owner drift: {actual_owner}")

    execution = call(HOOK, "0xef132bce")
    iterations = execution[0]
    if execution[1:] != [10, 1_500, 500]:
        problems.append(f"execution config drift: {execution}")
    if iterations != EXPECTED_ITERATIONS:
        problems.append(f"iteration limit drift: {iterations}")

    gas_bounds = call(HOOK, "0xdf61515a")
    if gas_bounds != [200_000, 3_000_000]:
        problems.append(f"gas bounds drift: {gas_bounds}")

    for token, adapter in ((WETH, WETH_ADAPTER), (USDC, USDC_ADAPTER)):
        lender, cap, max_fee, min_profit = call(HOOK, "0x5e1fc16c" + address_word(token))
        expected_cap, expected_fee, expected_profit = EXPECTED[token]
        if word_address(lender) != adapter or (cap, max_fee, min_profit) != (
            expected_cap,
            expected_fee,
            expected_profit,
        ):
            problems.append(f"{token_label(token)[0]} flash config drift")
        balance = call(token, "0x70a08231" + address_word(HOOK))[0]
        if balance:
            problems.append(f"hook retained {balance} raw {token_label(token)[0]}")
    return iterations, problems


def emergency_disable(reason: str) -> bool:
    private_key = os.environ.get("PRIVATE_KEY", "")
    if not AUTO_DISABLE or not private_key:
        stamp(f"ALERT: {reason}; automatic disable unavailable")
        return False
    if not private_key.startswith("0x"):
        private_key = "0x" + private_key
    stamp(f"ALERT: {reason}; sending kill-switch transaction")
    command = [
        "cast",
        "send",
        HOOK,
        "setHookMaxIterations(uint256)",
        "0",
        "--rpc-url",
        RPC_URL,
        "--private-key",
        private_key,
        "--json",
    ]
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode:
        stamp(f"EMERGENCY DISABLE FAILED: {result.stderr.strip()}")
        return False
    receipt = json.loads(result.stdout)
    stamp(f"kill switch confirmed in {receipt.get('transactionHash', 'unknown transaction')}")
    return True


def logs(address: str, topic0: str, start: int, end: int, topic1: str | None = None) -> list[dict[str, object]]:
    topics: list[object] = [topic0]
    if topic1 is not None:
        topics.append(topic1)
    return list(
        rpc(
            "eth_getLogs",
            [{"address": address, "fromBlock": hex(start), "toBlock": hex(end), "topics": topics}],
        )
    )


def report_events(start: int, end: int) -> None:
    swap_logs = logs(POOL_MANAGER, SWAP_TOPIC, start, end, POOL_ID)
    settlement_logs = logs(HOOK, SETTLED_TOPIC, start, end)
    settled_transactions = {str(entry["transactionHash"]).lower() for entry in settlement_logs}

    for entry in settlement_logs:
        topics = list(entry["topics"])
        words = [int(str(entry["data"])[i : i + 64], 16) for i in range(2, len(str(entry["data"])), 64)]
        token = "0x" + str(topics[2])[-40:].lower()
        label, decimals = token_label(token)
        net_profit = signed(words[5])
        stamp(
            f"SETTLED tx={entry['transactionHash']} token={label} principal={words[2] / 10**decimals:.9f} "
            f"profit={net_profit / 10**decimals:.9f} iterations={words[6]} beneficiary={word_address(words[7])}"
        )
        expected_profit = EXPECTED[token][2]
        if net_profit < expected_profit or words[6] > 10:
            if emergency_disable("settlement violated profit or iteration bound"):
                raise SystemExit("canary disabled")

    for entry in swap_logs:
        sender = "0x" + str(entry["topics"][2])[-40:].lower()
        tx_hash = str(entry["transactionHash"]).lower()
        if sender != HOOK and tx_hash not in settled_transactions:
            stamp(f"NO-OP tx={tx_hash}: trigger swap completed without a profitable settlement")


def main() -> None:
    head = int(str(rpc("eth_blockNumber", [])), 16)
    next_block = int(os.environ.get("START_BLOCK", str(head)))
    stamp(f"monitoring hook={HOOK} pool={POOL_ID} from block={next_block} auto_disable={AUTO_DISABLE}")
    last_safety_check = 0.0
    while True:
        try:
            head = int(str(rpc("eth_blockNumber", [])), 16)
            safe_head = head - 1
            if next_block <= safe_head:
                report_events(next_block, safe_head)
                next_block = safe_head + 1
            if time.monotonic() - last_safety_check >= 15:
                iterations, problems = read_state()
                if problems:
                    if iterations == 0:
                        stamp(f"canary is disabled: {'; '.join(problems)}")
                        return
                    if emergency_disable("; ".join(problems)):
                        return
                last_safety_check = time.monotonic()
        except Exception as exc:  # RPC failures are alerts, not reasons to sign a transaction.
            stamp(f"monitor error: {exc}")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
