#!/Users/sterlingcrispin/miniconda3/bin/python3
"""Serve a read-only live dashboard for the active Base arbitrage canary."""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import threading
import time
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

try:
    from eth_hash.auto import keccak
except ImportError:  # pragma: no cover - fallback for lean Python installations
    from Crypto.Hash import keccak as crypto_keccak

    def keccak(data: bytes) -> bytes:
        digest = crypto_keccak.new(digest_bits=256)
        digest.update(data)
        return digest.digest()


ROOT = Path(__file__).resolve().parents[1]
STATIC_DIR = Path(__file__).resolve().parent
UINT256_MOD = 1 << 256
Q96 = 1 << 96
Q128 = 1 << 128
POOL_SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
FLASH_SETTLED_TOPIC = "0x3304c4667c0287e82d18466387f012d2b5697e469fa81019b29b428bcf58a15c"


def load_env(path: Path) -> None:
    if not path.exists():
        return
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip("\"").strip("'")
        os.environ.setdefault(key.strip(), value)


def selector(signature: str) -> bytes:
    return keccak(signature.encode())[:4]


def word(value: int) -> bytes:
    return (value % UINT256_MOD).to_bytes(32, "big")


def address_word(address: str) -> bytes:
    return bytes(12) + bytes.fromhex(address[2:])


def signed(value: int, bits: int = 256) -> int:
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def words(data: str) -> list[int]:
    raw = bytes.fromhex(data.removeprefix("0x"))
    if len(raw) % 32:
        raise ValueError("malformed ABI response")
    return [int.from_bytes(raw[i : i + 32], "big") for i in range(0, len(raw), 32)]


def rpc_quantity(value: int) -> str:
    return hex(value)


def checksumless(address: str) -> str:
    value = address.lower()
    if not value.startswith("0x") or len(value) != 42:
        raise ValueError(f"invalid address: {address}")
    return value


def short_address(address: str) -> str:
    return f"{address[:6]}...{address[-4:]}"


class RpcError(RuntimeError):
    pass


class RpcClient:
    def __init__(self, url: str) -> None:
        self.url = url
        self._request_id = 0
        self._lock = threading.Lock()

    def _ids(self, count: int) -> list[int]:
        with self._lock:
            start = self._request_id + 1
            self._request_id += count
        return list(range(start, start + count))

    def request(self, method: str, params: list[Any]) -> Any:
        return self.batch([(method, params)])[0]

    def batch(self, requests: list[tuple[str, list[Any]]], chunk_size: int = 100) -> list[Any]:
        output: list[Any] = []
        for offset in range(0, len(requests), chunk_size):
            chunk = requests[offset : offset + chunk_size]
            ids = self._ids(len(chunk))
            payload = [
                {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
                for request_id, (method, params) in zip(ids, chunk, strict=True)
            ]
            body = json.dumps(payload).encode()
            request = urllib.request.Request(
                self.url,
                data=body,
                headers={"Content-Type": "application/json", "User-Agent": "arb-hook-dashboard/1"},
            )
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    decoded = json.load(response)
            except Exception as exc:
                raise RpcError(f"RPC transport failed: {exc}") from exc
            if not isinstance(decoded, list):
                decoded = [decoded]
            by_id = {entry.get("id"): entry for entry in decoded}
            for request_id in ids:
                entry = by_id.get(request_id)
                if not entry:
                    raise RpcError(f"RPC omitted response {request_id}")
                if entry.get("error"):
                    raise RpcError(str(entry["error"]))
                output.append(entry.get("result"))
        return output


@dataclass(frozen=True)
class CanaryConfig:
    raw: dict[str, Any]

    @property
    def chain_id(self) -> int:
        return int(self.raw["chainId"])

    def address(self, name: str) -> str:
        return checksumless(self.raw[name])

    @property
    def pool_id(self) -> str:
        return self.raw["poolId"].lower()


TICK_RATIOS = (
    0xFFFcb933BD6FAD37AA2D162D1A594001,
    0xFFF97272373D413259A46990580E213A,
    0xFFF2E50F5F656932EF12357CF3C7FDCC,
    0xFFE5CACA7E10E4E61C3624EAA0941CD0,
    0xFFCB9843D60F6159C9DB58835C926644,
    0xFF973B41FA98C081472E6896DFB254C0,
    0xFF2EA16466C96A3843EC78B326B52861,
    0xFE5DEE046A99A2A811C461F1969C3053,
    0xFCBE86C7900A88AEDCFFC83B479AA3A4,
    0xF987A7253AC413176F2B074CF7815E54,
    0xF3392B0822B70005940C7A398E4B70F3,
    0xE7159475A2C29B7443B29C7FA6E889D9,
    0xD097F3BDFD2022B8845AD8F792AA5825,
    0xA9F746462D870FDF8A65DC1F90E061E5,
    0x70D869A156D2A1B890BB3DF62BAF32F7,
    0x31BE135F97D08FD981231505542FCFA6,
    0x9AA508B5B7A84E1C677DE54F3E99BC9,
    0x5D6AF8DEDB81196699C329225EE604,
    0x2216E584F5FA1EA926041BEDFE98,
    0x48A170391F7DC42444E8FA2,
)


def sqrt_price_at_tick(tick: int) -> int:
    absolute = abs(tick)
    if absolute > 887272:
        raise ValueError("tick outside Uniswap range")
    ratio = 1 << 128
    for bit, multiplier in enumerate(TICK_RATIOS):
        if absolute & (1 << bit):
            ratio = ratio * multiplier >> 128
    if tick > 0:
        ratio = (UINT256_MOD - 1) // ratio
    return (ratio + (1 << 32) - 1) >> 32


def liquidity_amounts(sqrt_price: int, sqrt_lower: int, sqrt_upper: int, liquidity: int) -> tuple[int, int]:
    if liquidity == 0 or sqrt_price == 0:
        return 0, 0
    if sqrt_price <= sqrt_lower:
        return liquidity * (sqrt_upper - sqrt_lower) * Q96 // sqrt_upper // sqrt_lower, 0
    if sqrt_price < sqrt_upper:
        amount0 = liquidity * (sqrt_upper - sqrt_price) * Q96 // sqrt_upper // sqrt_price
        amount1 = liquidity * (sqrt_price - sqrt_lower) // Q96
        return amount0, amount1
    return 0, liquidity * (sqrt_upper - sqrt_lower) // Q96


class PortfolioEngine:
    BALANCE_OF = selector("balanceOf(address)")
    EXTSLOAD = selector("extsload(bytes32)")
    V3_SLOT0 = selector("slot0()")

    def __init__(self, rpc: RpcClient, config: CanaryConfig) -> None:
        self.rpc = rpc
        self.config = config
        self.owner = config.address("owner")
        self.hook = config.address("hook")
        self.pool_manager = config.address("poolManager")
        self.position_manager = config.address("positionManager")
        self.weth_adapter = config.address("wethAdapter")
        self.usdc_adapter = config.address("usdcAdapter")
        self.weth = config.address("weth")
        self.usdc = config.address("usdc")
        self.reference_pool = config.address("referencePool")
        self.tick_lower = int(config.raw["tickLower"])
        self.tick_upper = int(config.raw["tickUpper"])
        self.token_id = int(config.raw["positionTokenId"])
        self.sqrt_lower = sqrt_price_at_tick(self.tick_lower)
        self.sqrt_upper = sqrt_price_at_tick(self.tick_upper)
        pool_id = bytes.fromhex(config.pool_id[2:])
        self.pool_state_slot = int.from_bytes(keccak(pool_id + word(6)), "big")
        ticks_mapping = (self.pool_state_slot + 4) % UINT256_MOD
        self.lower_tick_slot = int.from_bytes(keccak(word(self.tick_lower) + word(ticks_mapping)), "big")
        self.upper_tick_slot = int.from_bytes(keccak(word(self.tick_upper) + word(ticks_mapping)), "big")
        position_packed = (
            bytes.fromhex(self.position_manager[2:])
            + (self.tick_lower & 0xFFFFFF).to_bytes(3, "big")
            + (self.tick_upper & 0xFFFFFF).to_bytes(3, "big")
            + word(self.token_id)
        )
        position_id = keccak(position_packed)
        position_mapping = (self.pool_state_slot + 6) % UINT256_MOD
        self.position_slot = int.from_bytes(keccak(position_id + word(position_mapping)), "big")

    @staticmethod
    def _call(to: str, data: bytes, block: int) -> tuple[str, list[Any]]:
        return "eth_call", [{"to": to, "data": "0x" + data.hex()}, rpc_quantity(block)]

    def _balance_request(self, token: str, account: str, block: int) -> tuple[str, list[Any]]:
        return self._call(token, self.BALANCE_OF + address_word(account), block)

    def _slot_request(self, slot: int, block: int) -> tuple[str, list[Any]]:
        return self._call(self.pool_manager, self.EXTSLOAD + word(slot), block)

    def _request_set(self, block: int) -> list[tuple[str, tuple[str, list[Any]]]]:
        requests: list[tuple[str, tuple[str, list[Any]]]] = [
            ("owner_native", ("eth_getBalance", [self.owner, rpc_quantity(block)])),
            ("reference_slot0", self._call(self.reference_pool, self.V3_SLOT0, block)),
            ("pool_slot0", self._slot_request(self.pool_state_slot, block)),
            ("fee_global0", self._slot_request(self.pool_state_slot + 1, block)),
            ("fee_global1", self._slot_request(self.pool_state_slot + 2, block)),
            ("lower_fee0", self._slot_request(self.lower_tick_slot + 1, block)),
            ("lower_fee1", self._slot_request(self.lower_tick_slot + 2, block)),
            ("upper_fee0", self._slot_request(self.upper_tick_slot + 1, block)),
            ("upper_fee1", self._slot_request(self.upper_tick_slot + 2, block)),
            ("position", self._slot_request(self.position_slot, block)),
            ("position_fee0", self._slot_request(self.position_slot + 1, block)),
            ("position_fee1", self._slot_request(self.position_slot + 2, block)),
        ]
        for account_name, account in (
            ("owner", self.owner),
            ("hook", self.hook),
            ("weth_adapter", self.weth_adapter),
            ("usdc_adapter", self.usdc_adapter),
        ):
            requests.append((f"{account_name}_weth", self._balance_request(self.weth, account, block)))
            requests.append((f"{account_name}_usdc", self._balance_request(self.usdc, account, block)))
        return requests

    def snapshots(self, blocks: list[int]) -> list[dict[str, Any]]:
        tagged: list[tuple[int, str]] = []
        requests: list[tuple[str, list[Any]]] = []
        for block in blocks:
            for name, request in self._request_set(block):
                tagged.append((block, name))
                requests.append(request)
        results = self.rpc.batch(requests)
        grouped: dict[int, dict[str, int]] = defaultdict(dict)
        for (block, name), result in zip(tagged, results, strict=True):
            grouped[block][name] = words(result)[0] if name == "reference_slot0" else int(result, 16)
        return [self._derive(block, grouped[block]) for block in blocks]

    def snapshot(self, block: int) -> dict[str, Any]:
        return self.snapshots([block])[0]

    def apply_external_flows(self, snapshot: dict[str, Any], flows: dict[str, int]) -> dict[str, Any]:
        flow_weth_like = flows.get("native", 0) + flows.get("weth", 0)
        flow_value = flow_weth_like / 1e18 * snapshot["referencePrice"] + flows.get("usdc", 0) / 1e6
        snapshot["holdValueUsd"] += flow_value
        snapshot["netPnlUsd"] = snapshot["strategyValueUsd"] - snapshot["holdValueUsd"]
        snapshot["netPnlPct"] = (
            (snapshot["strategyValueUsd"] / snapshot["holdValueUsd"] - 1) * 100
            if snapshot["holdValueUsd"]
            else 0.0
        )
        baseline_native = int(self.config.raw["baseline"]["nativeWei"])
        adjusted_native_budget = baseline_native + flows.get("native", 0)
        snapshot["ownerGasValueUsd"] = max(adjusted_native_budget - int(snapshot["balances"]["ownerEth"] * 1e18), 0) / 1e18 * snapshot["referencePrice"]
        snapshot["externalNetFlowUsd"] = flow_value
        snapshot["externalFlows"] = {
            "native": flows.get("native", 0) / 1e18,
            "weth": flows.get("weth", 0) / 1e18,
            "usdc": flows.get("usdc", 0) / 1e6,
        }
        return snapshot

    def _derive(self, block: int, raw: dict[str, int]) -> dict[str, Any]:
        reference_sqrt = raw["reference_slot0"] & ((1 << 160) - 1)
        reference_price = reference_sqrt * reference_sqrt * 1e12 / (1 << 192)
        slot0 = raw["pool_slot0"]
        sqrt_price = slot0 & ((1 << 160) - 1)
        tick = signed((slot0 >> 160) & 0xFFFFFF, 24) if sqrt_price else 0
        liquidity = raw["position"] & ((1 << 128) - 1)

        if tick < self.tick_lower:
            inside0 = (raw["lower_fee0"] - raw["upper_fee0"]) % UINT256_MOD
            inside1 = (raw["lower_fee1"] - raw["upper_fee1"]) % UINT256_MOD
        elif tick >= self.tick_upper:
            inside0 = (raw["upper_fee0"] - raw["lower_fee0"]) % UINT256_MOD
            inside1 = (raw["upper_fee1"] - raw["lower_fee1"]) % UINT256_MOD
        else:
            inside0 = (raw["fee_global0"] - raw["lower_fee0"] - raw["upper_fee0"]) % UINT256_MOD
            inside1 = (raw["fee_global1"] - raw["lower_fee1"] - raw["upper_fee1"]) % UINT256_MOD

        fee0 = ((inside0 - raw["position_fee0"]) % UINT256_MOD) * liquidity // Q128 if liquidity else 0
        fee1 = ((inside1 - raw["position_fee1"]) % UINT256_MOD) * liquidity // Q128 if liquidity else 0
        principal0, principal1 = liquidity_amounts(sqrt_price, self.sqrt_lower, self.sqrt_upper, liquidity)

        owner_weth_like = raw["owner_native"] + raw["owner_weth"]
        hook_weth = raw["hook_weth"]
        hook_usdc = raw["hook_usdc"]
        adapter_weth = raw["weth_adapter_weth"] + raw["usdc_adapter_weth"]
        adapter_usdc = raw["weth_adapter_usdc"] + raw["usdc_adapter_usdc"]
        total_weth_like = owner_weth_like + hook_weth + adapter_weth + principal0 + fee0
        total_usdc = raw["owner_usdc"] + hook_usdc + adapter_usdc + principal1 + fee1

        baseline = self.config.raw["baseline"]
        baseline_weth_like = int(baseline["nativeWei"]) + int(baseline["wethRaw"])
        baseline_usdc = int(baseline["usdcRaw"])
        strategy_value = total_weth_like / 1e18 * reference_price + total_usdc / 1e6
        hold_value = baseline_weth_like / 1e18 * reference_price + baseline_usdc / 1e6
        lp_principal_value = principal0 / 1e18 * reference_price + principal1 / 1e6
        lp_fee_value = fee0 / 1e18 * reference_price + fee1 / 1e6
        hook_value = hook_weth / 1e18 * reference_price + hook_usdc / 1e6
        wallet_value = owner_weth_like / 1e18 * reference_price + raw["owner_usdc"] / 1e6
        adapter_value = adapter_weth / 1e18 * reference_price + adapter_usdc / 1e6
        deposited_value = (
            int(self.config.raw["depositedWethRaw"]) / 1e18 * reference_price
            + int(self.config.raw["depositedUsdcRaw"]) / 1e6
        )
        gas_weth = int(baseline["nativeWei"]) - raw["owner_native"]
        pool_price = sqrt_price * sqrt_price * 1e12 / (1 << 192) if sqrt_price else 0.0

        return {
            "block": block,
            "referencePrice": reference_price,
            "poolPrice": pool_price,
            "tick": tick,
            "tickLower": self.tick_lower,
            "tickUpper": self.tick_upper,
            "inRange": self.tick_lower <= tick < self.tick_upper if sqrt_price else False,
            "liquidity": str(liquidity),
            "strategyValueUsd": strategy_value,
            "holdValueUsd": hold_value,
            "netPnlUsd": strategy_value - hold_value,
            "netPnlPct": (strategy_value / hold_value - 1) * 100 if hold_value else 0.0,
            "walletValueUsd": wallet_value,
            "lpPrincipalValueUsd": lp_principal_value,
            "lpFeeValueUsd": lp_fee_value,
            "hookRevenueValueUsd": hook_value,
            "adapterValueUsd": adapter_value,
            "lpInventoryPnlUsd": lp_principal_value - deposited_value,
            "ownerGasValueUsd": max(gas_weth, 0) / 1e18 * reference_price,
            "balances": {
                "ownerEth": raw["owner_native"] / 1e18,
                "ownerWeth": raw["owner_weth"] / 1e18,
                "ownerUsdc": raw["owner_usdc"] / 1e6,
                "hookWeth": hook_weth / 1e18,
                "hookUsdc": hook_usdc / 1e6,
                "adapterWeth": adapter_weth / 1e18,
                "adapterUsdc": adapter_usdc / 1e6,
                "lpPrincipalWeth": principal0 / 1e18,
                "lpPrincipalUsdc": principal1 / 1e6,
                "lpFeeWeth": fee0 / 1e18,
                "lpFeeUsdc": fee1 / 1e6,
            },
        }


class EventIndex:
    def __init__(self, rpc: RpcClient, config: CanaryConfig) -> None:
        self.rpc = rpc
        self.config = config
        self.pool_manager = config.address("poolManager")
        self.hook = config.address("hook")
        self.controlled = config.raw["controlledTransaction"].lower()
        self.last_scanned = int(config.raw["enabledBlock"]) - 1
        self.swaps: dict[tuple[str, int], dict[str, Any]] = {}
        self.settlements: dict[tuple[str, int], dict[str, Any]] = {}
        self.blocks: dict[int, dict[str, Any]] = {}
        self.transactions: dict[str, dict[str, Any]] = {}
        self.receipts: dict[str, dict[str, Any]] = {}

    def refresh(self, safe_head: int) -> None:
        start = self.last_scanned + 1
        if start > safe_head:
            return
        swap_filter = {
            "address": self.pool_manager,
            "fromBlock": rpc_quantity(start),
            "toBlock": rpc_quantity(safe_head),
            "topics": [POOL_SWAP_TOPIC, self.config.pool_id],
        }
        settlement_filter = {
            "address": self.hook,
            "fromBlock": rpc_quantity(start),
            "toBlock": rpc_quantity(safe_head),
            "topics": [FLASH_SETTLED_TOPIC],
        }
        swap_logs, settlement_logs = self.rpc.batch(
            [("eth_getLogs", [swap_filter]), ("eth_getLogs", [settlement_filter])]
        )
        for entry in swap_logs:
            sender = "0x" + entry["topics"][2][-40:].lower()
            if sender == self.hook:
                continue
            decoded = words(entry["data"])
            key = (entry["transactionHash"].lower(), int(entry["logIndex"], 16))
            self.swaps[key] = {
                "transaction": key[0],
                "block": int(entry["blockNumber"], 16),
                "logIndex": key[1],
                "sender": sender,
                "amount0": signed(decoded[0]),
                "amount1": signed(decoded[1]),
            }
        for entry in settlement_logs:
            decoded = words(entry["data"])
            key = (entry["transactionHash"].lower(), int(entry["logIndex"], 16))
            self.settlements[key] = {
                "transaction": key[0],
                "block": int(entry["blockNumber"], 16),
                "logIndex": key[1],
                "lender": "0x" + entry["topics"][1][-40:].lower(),
                "tokenA": "0x" + entry["topics"][2][-40:].lower(),
                "tokenB": "0x" + entry["topics"][3][-40:].lower(),
                "buyPool": "0x" + word(decoded[0])[-20:].hex(),
                "sellPool": "0x" + word(decoded[1])[-20:].hex(),
                "principal": decoded[2],
                "totalSwapped": decoded[3],
                "fee": decoded[4],
                "netProfit": signed(decoded[5]),
                "iterations": decoded[6],
                "beneficiary": "0x" + word(decoded[7])[-20:].hex(),
            }
        self.last_scanned = safe_head
        self._hydrate_metadata()

    def _hydrate_metadata(self) -> None:
        all_tx_hashes = {entry["transaction"] for entry in self.swaps.values()}
        settlement_hashes = {entry["transaction"] for entry in self.settlements.values()}
        new_txs = sorted(all_tx_hashes - self.transactions.keys())
        new_receipts = sorted(settlement_hashes - self.receipts.keys())
        new_blocks = sorted(
            {entry["block"] for entry in (*self.swaps.values(), *self.settlements.values())} - self.blocks.keys()
        )
        requests: list[tuple[str, list[Any]]] = []
        tags: list[tuple[str, Any]] = []
        for tx_hash in new_txs:
            tags.append(("tx", tx_hash))
            requests.append(("eth_getTransactionByHash", [tx_hash]))
        for tx_hash in new_receipts:
            tags.append(("receipt", tx_hash))
            requests.append(("eth_getTransactionReceipt", [tx_hash]))
        for block in new_blocks:
            tags.append(("block", block))
            requests.append(("eth_getBlockByNumber", [rpc_quantity(block), False]))
        if not requests:
            return
        for (kind, key), result in zip(tags, self.rpc.batch(requests), strict=True):
            if kind == "tx":
                self.transactions[key] = result
            elif kind == "receipt":
                self.receipts[key] = result
            else:
                self.blocks[key] = result

    def settlement_blocks(self) -> list[int]:
        return sorted({entry["block"] for entry in self.settlements.values()})

    def summary(self, prices: dict[int, float]) -> dict[str, Any]:
        swaps_by_tx: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for entry in self.swaps.values():
            swaps_by_tx[entry["transaction"]].append(entry)
        settlements_by_tx: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for entry in self.settlements.values():
            settlements_by_tx[entry["transaction"]].append(entry)

        organic_txs = {tx_hash for tx_hash in swaps_by_tx if tx_hash != self.controlled}
        organic_settled = organic_txs & settlements_by_tx.keys()
        organic_volume = sum(
            abs(swap["amount1"]) for tx_hash in organic_txs for swap in swaps_by_tx[tx_hash]
        ) / 1e6
        targets = {
            (self.transactions.get(tx_hash) or {}).get("to", "").lower()
            for tx_hash in organic_txs
            if (self.transactions.get(tx_hash) or {}).get("to")
        }

        trades: list[dict[str, Any]] = []
        for settlement in sorted(self.settlements.values(), key=lambda item: (item["block"], item["logIndex"]), reverse=True):
            tx_hash = settlement["transaction"]
            trigger_swaps = swaps_by_tx.get(tx_hash, [])
            amount0 = sum(item["amount0"] for item in trigger_swaps)
            amount1 = sum(item["amount1"] for item in trigger_swaps)
            direction = "USDC -> WETH" if amount1 > 0 else "WETH -> USDC"
            token_is_weth = settlement["tokenA"] == self.config.address("weth")
            decimals = 18 if token_is_weth else 6
            token_symbol = "WETH" if token_is_weth else "USDC"
            profit_token = settlement["netProfit"] / 10**decimals
            block_price = prices.get(settlement["block"], 0.0)
            profit_usd = profit_token * block_price if token_is_weth else profit_token
            receipt = self.receipts.get(tx_hash) or {}
            transaction = self.transactions.get(tx_hash) or {}
            gas_used = int(receipt.get("gasUsed", "0x0"), 16)
            gas_price = int(receipt.get("effectiveGasPrice", "0x0"), 16)
            l1_fee = int(receipt.get("l1Fee", "0x0"), 16)
            tx_fee_eth = (gas_used * gas_price + l1_fee) / 1e18
            timestamp = int((self.blocks.get(settlement["block"]) or {}).get("timestamp", "0x0"), 16)
            trades.append(
                {
                    "transaction": tx_hash,
                    "block": settlement["block"],
                    "timestamp": timestamp,
                    "controlled": tx_hash == self.controlled,
                    "direction": direction,
                    "triggerNotionalUsd": sum(abs(item["amount1"]) for item in trigger_swaps) / 1e6,
                    "profitToken": profit_token,
                    "profitSymbol": token_symbol,
                    "profitUsd": profit_usd,
                    "principalToken": settlement["principal"] / 10**decimals,
                    "totalSwappedToken": settlement["totalSwapped"] / 10**decimals,
                    "iterations": settlement["iterations"],
                    "buyPool": settlement["buyPool"],
                    "sellPool": settlement["sellPool"],
                    "gasUsed": gas_used,
                    "txFeeEth": tx_fee_eth,
                    "payer": (transaction.get("from") or "").lower(),
                    "target": (transaction.get("to") or "").lower(),
                }
            )

        organic_trades = [trade for trade in trades if not trade["controlled"]]
        return {
            "organicTransactions": len(organic_txs),
            "organicSwapEvents": sum(len(swaps_by_tx[tx_hash]) for tx_hash in organic_txs),
            "organicSettlements": len(organic_settled),
            "noOpTransactions": len(organic_txs - organic_settled),
            "successRatePct": len(organic_settled) / len(organic_txs) * 100 if organic_txs else 0.0,
            "organicVolumeUsd": organic_volume,
            "uniqueTargets": len(targets),
            "organicEventProfitUsd": sum(trade["profitUsd"] for trade in organic_trades),
            "allEventProfitUsd": sum(trade["profitUsd"] for trade in trades),
            "averageOrganicProfitUsd": (
                sum(trade["profitUsd"] for trade in organic_trades) / len(organic_trades) if organic_trades else 0.0
            ),
            "trades": trades,
        }


class ExternalFlowIndex:
    """Identify wallet cash flows that must change capital, not reported P&L."""

    def __init__(self, rpc: RpcClient, config: CanaryConfig) -> None:
        self.rpc = rpc
        self.config = config
        self.owner = config.address("owner")
        self.weth = config.address("weth")
        self.usdc = config.address("usdc")
        self.milestones = {value.lower() for value in config.raw.get("milestoneTransactions", [])}
        self.internal_addresses = {
            config.address(name)
            for name in ("hook", "poolManager", "positionManager", "wethAdapter", "usdcAdapter")
        }
        self.flows: list[dict[str, Any]] = []

    def refresh(self, safe_head: int) -> None:
        transfers: list[dict[str, Any]] = []
        for direction in ("toAddress", "fromAddress"):
            params = {
                "fromBlock": rpc_quantity(int(self.config.raw["baselineBlock"])),
                "toBlock": rpc_quantity(safe_head),
                direction: self.owner,
                "category": ["external", "internal", "erc20"],
                "withMetadata": False,
                "excludeZeroValue": True,
                "maxCount": "0x3e8",
                "order": "asc",
            }
            while True:
                result = self.rpc.request("alchemy_getAssetTransfers", [params])
                transfers.extend(result.get("transfers", []))
                page_key = result.get("pageKey")
                if not page_key:
                    break
                params["pageKey"] = page_key

        unique: dict[str, dict[str, Any]] = {}
        for transfer in transfers:
            raw = transfer.get("rawContract") or {}
            raw_value = raw.get("value")
            if not raw_value:
                continue
            tx_hash = (transfer.get("hash") or "").lower()
            from_address = (transfer.get("from") or "").lower()
            to_address = (transfer.get("to") or "").lower()
            other = from_address if to_address == self.owner else to_address
            if tx_hash in self.milestones or other in self.internal_addresses:
                continue
            token_address = (raw.get("address") or "").lower()
            if token_address == self.weth:
                asset = "weth"
            elif token_address == self.usdc:
                asset = "usdc"
            elif not token_address and (transfer.get("asset") or "").upper() == "ETH":
                asset = "native"
            else:
                continue
            sign = (1 if to_address == self.owner else 0) - (1 if from_address == self.owner else 0)
            if sign == 0:
                continue
            identity = transfer.get("uniqueId") or ":".join(
                (tx_hash, from_address, to_address, asset, raw_value)
            )
            unique[identity] = {
                "block": int(transfer["blockNum"], 16),
                "transaction": tx_hash,
                "asset": asset,
                "raw": sign * int(raw_value, 16),
                "from": from_address,
                "to": to_address,
            }
        self.flows = sorted(unique.values(), key=lambda item: (item["block"], item["transaction"]))

    def cumulative(self, block: int) -> dict[str, int]:
        totals = {"native": 0, "weth": 0, "usdc": 0}
        for flow in self.flows:
            if flow["block"] > block:
                break
            totals[flow["asset"]] += flow["raw"]
        return totals

    def public_summary(self, price: float) -> dict[str, Any]:
        totals = self.cumulative(2**63 - 1)
        value = (totals["native"] + totals["weth"]) / 1e18 * price + totals["usdc"] / 1e6
        return {
            "count": len(self.flows),
            "netValueUsd": value,
            "native": totals["native"] / 1e18,
            "weth": totals["weth"] / 1e18,
            "usdc": totals["usdc"] / 1e6,
            "transfers": [
                {
                    **flow,
                    "raw": str(flow["raw"]),
                    "amount": flow["raw"] / (1e6 if flow["asset"] == "usdc" else 1e18),
                }
                for flow in self.flows
            ],
        }


class DashboardModel:
    OWNER = selector("owner()")
    EXECUTION = selector("getExecutionConfig()")
    GAS_BOUNDS = selector("getGasBounds()")

    def __init__(self, rpc: RpcClient, config: CanaryConfig) -> None:
        self.rpc = rpc
        self.config = config
        self.portfolio = PortfolioEngine(rpc, config)
        self.events = EventIndex(rpc, config)
        self.external_flows = ExternalFlowIndex(rpc, config)
        self._history: list[dict[str, Any]] = []
        self._milestone_blocks: set[int] = set()
        self._state: dict[str, Any] = {"status": "loading", "updatedAt": int(time.time())}
        self._state_lock = threading.Lock()
        self._stop = threading.Event()

    def public_state(self) -> dict[str, Any]:
        with self._state_lock:
            return self._state

    def start(self, interval: float) -> None:
        threading.Thread(target=self._worker, args=(interval,), daemon=True, name="dashboard-indexer").start()

    def _worker(self, interval: float) -> None:
        while not self._stop.is_set():
            started = time.monotonic()
            try:
                self.refresh()
            except Exception as exc:
                with self._state_lock:
                    previous = dict(self._state)
                    previous.update({"status": "error", "error": str(exc), "updatedAt": int(time.time())})
                    self._state = previous
                print(f"dashboard refresh failed: {exc}", flush=True)
            wait = max(1.0, interval - (time.monotonic() - started))
            self._stop.wait(wait)

    def refresh(self) -> None:
        head = int(self.rpc.request("eth_blockNumber", []), 16)
        safe_head = max(int(self.config.raw["enabledBlock"]), head - 1)
        self.events.refresh(safe_head)
        self.external_flows.refresh(safe_head)
        if not self._milestone_blocks:
            self._load_milestones()
        if not self._history:
            self._build_history(safe_head)

        current = self.portfolio.apply_external_flows(
            self.portfolio.snapshot(safe_head), self.external_flows.cumulative(safe_head)
        )
        current_block = self.rpc.request("eth_getBlockByNumber", [rpc_quantity(safe_head), False])
        current["timestamp"] = int(current_block["timestamp"], 16)
        if not self._history or safe_head - self._history[-1]["block"] >= 15:
            self._history.append(self._history_point(current))
        elif self._history:
            self._history[-1] = self._history_point(current)
        self._history = self._history[-240:]

        price_blocks = self.events.settlement_blocks()
        prices = {point["block"]: point["referencePrice"] for point in self._history}
        missing_price_blocks = [block for block in price_blocks if block not in prices]
        if missing_price_blocks:
            for snapshot in self.portfolio.snapshots(missing_price_blocks):
                prices[snapshot["block"]] = snapshot["referencePrice"]
        event_summary = self.events.summary(prices)
        health = self._health(current, head)
        baseline_timestamp = self._block_timestamp(int(self.config.raw["baselineBlock"]))
        elapsed = max(0, current["timestamp"] - baseline_timestamp)

        payload = {
            "status": "live",
            "updatedAt": int(time.time()),
            "chain": {"id": self.config.chain_id, "name": self.config.raw["chainName"], "head": head},
            "deployment": {
                "hook": self.config.address("hook"),
                "poolId": self.config.pool_id,
                "positionTokenId": self.config.raw["positionTokenId"],
                "owner": self.config.address("owner"),
                "baselineBlock": self.config.raw["baselineBlock"],
                "enabledBlock": self.config.raw["enabledBlock"],
                "elapsedSeconds": elapsed,
            },
            "current": current,
            "activity": event_summary,
            "history": self._history,
            "health": health,
            "accounting": {
                "method": "Current operator wallet + withdrawable v4 principal and fees + hook and adapter balances, compared with the launch wallet holdings marked at the same reference price.",
                "assumption": "Detected external ETH/WETH/USDC deposits and withdrawals change the benchmark rather than P&L. Unsupported-token activity is outside this view.",
                "reference": "PancakeSwap V3 WETH/USDC 0.01% pool",
                "externalFlows": self.external_flows.public_summary(current["referencePrice"]),
            },
        }
        with self._state_lock:
            self._state = payload

    def _load_milestones(self) -> None:
        hashes = self.config.raw.get("milestoneTransactions", [])
        receipts = self.rpc.batch([("eth_getTransactionReceipt", [tx_hash]) for tx_hash in hashes])
        self._milestone_blocks = {
            int(receipt["blockNumber"], 16) for receipt in receipts if receipt and receipt.get("blockNumber")
        }

    def _build_history(self, head: int) -> None:
        baseline = int(self.config.raw["baselineBlock"])
        span = max(1, head - baseline)
        step = max(30, math.ceil(span / 120))
        blocks = set(range(baseline, head + 1, step))
        blocks.update(self._milestone_blocks)
        blocks.update(self.events.settlement_blocks())
        blocks.update((baseline, head))
        ordered = sorted(block for block in blocks if baseline <= block <= head)
        if len(ordered) > 180:
            stride = math.ceil(len(ordered) / 180)
            ordered = ordered[::stride]
            if ordered[-1] != head:
                ordered.append(head)
        snapshots = self.portfolio.snapshots(ordered)
        timestamps = self._block_timestamps(ordered)
        self._history = [
            self._history_point(
                {
                    **self.portfolio.apply_external_flows(
                        snapshot, self.external_flows.cumulative(snapshot["block"])
                    ),
                    "timestamp": timestamps[snapshot["block"]],
                }
            )
            for snapshot in snapshots
        ]

    @staticmethod
    def _history_point(snapshot: dict[str, Any]) -> dict[str, Any]:
        return {
            "block": snapshot["block"],
            "timestamp": snapshot["timestamp"],
            "netPnlUsd": snapshot["netPnlUsd"],
            "strategyValueUsd": snapshot["strategyValueUsd"],
            "holdValueUsd": snapshot["holdValueUsd"],
            "hookRevenueValueUsd": snapshot["hookRevenueValueUsd"],
            "lpFeeValueUsd": snapshot["lpFeeValueUsd"],
            "referencePrice": snapshot["referencePrice"],
        }

    def _block_timestamps(self, blocks: list[int]) -> dict[int, int]:
        values = self.rpc.batch(
            [("eth_getBlockByNumber", [rpc_quantity(block), False]) for block in blocks]
        )
        return {block: int(value["timestamp"], 16) for block, value in zip(blocks, values, strict=True)}

    def _block_timestamp(self, block: int) -> int:
        value = self.rpc.request("eth_getBlockByNumber", [rpc_quantity(block), False])
        return int(value["timestamp"], 16)

    def _health(self, current: dict[str, Any], head: int) -> dict[str, Any]:
        hook = self.config.address("hook")
        block = rpc_quantity(head)
        requests = [
            ("eth_chainId", []),
            ("eth_getCode", [hook, block]),
            ("eth_call", [{"to": hook, "data": "0x" + self.OWNER.hex()}, block]),
            ("eth_call", [{"to": hook, "data": "0x" + self.EXECUTION.hex()}, block]),
            ("eth_call", [{"to": hook, "data": "0x" + self.GAS_BOUNDS.hex()}, block]),
        ]
        chain_id, code, owner_result, execution_result, gas_result = self.rpc.batch(requests)
        owner = "0x" + words(owner_result)[0].to_bytes(32, "big")[-20:].hex()
        execution = words(execution_result)
        gas_bounds = words(gas_result)
        try:
            monitor_active = subprocess.run(
                ["tmux", "has-session", "-t", "arb-hook-canary-079a"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=2,
            ).returncode == 0
        except (OSError, subprocess.SubprocessError):
            monitor_active = False
        checks = [
            {"label": "Hook bytecode", "ok": code != "0x", "value": "deployed" if code != "0x" else "missing"},
            {
                "label": "Owner",
                "ok": owner == self.config.address("owner"),
                "value": short_address(owner),
            },
            {
                "label": "Execution",
                "ok": execution[:4] == [10, 10, 1500, 500],
                "value": f"{execution[0]} rounds / {execution[1]} bps gate",
            },
            {
                "label": "Gas bounds",
                "ok": gas_bounds[:2] == [200000, 3000000],
                "value": f"{gas_bounds[0]:,} / {gas_bounds[1]:,}",
            },
            {
                "label": "Flash adapters",
                "ok": current["balances"]["adapterWeth"] == 0 and current["balances"]["adapterUsdc"] == 0,
                "value": "empty" if current["adapterValueUsd"] == 0 else "retained funds",
            },
            {
                "label": "LP position",
                "ok": int(current["liquidity"]) > 0,
                "value": "active" if int(current["liquidity"]) > 0 else "closed",
            },
            {"label": "Kill-switch monitor", "ok": monitor_active, "value": "active" if monitor_active else "offline"},
        ]
        return {
            "ok": int(chain_id, 16) == self.config.chain_id and all(check["ok"] for check in checks[:-1]),
            "monitorActive": monitor_active,
            "checks": checks,
        }


class DashboardHandler(SimpleHTTPRequestHandler):
    model: DashboardModel

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, directory=str(STATIC_DIR), **kwargs)

    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] == "/api/dashboard":
            body = json.dumps(self.model.public_state(), separators=(",", ":")).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/":
            self.path = "/index.html"
        super().do_GET()

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, format_string: str, *args: Any) -> None:
        if self.path.startswith("/api/"):
            return
        super().log_message(format_string, *args)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--interval", type=float, default=8.0)
    parser.add_argument("--config", type=Path, default=STATIC_DIR / "base-canary.json")
    args = parser.parse_args()

    load_env(ROOT / ".env")
    rpc_url = os.environ.get("BASE_RPC_URL", "")
    if not rpc_url:
        raise SystemExit("BASE_RPC_URL is required in .env")
    config = CanaryConfig(json.loads(args.config.read_text()))
    rpc = RpcClient(rpc_url)
    chain_id = int(rpc.request("eth_chainId", []), 16)
    if chain_id != config.chain_id:
        raise SystemExit(f"RPC chain ID {chain_id} does not match {config.chain_id}")

    model = DashboardModel(rpc, config)
    DashboardHandler.model = model
    model.start(args.interval)
    server = ThreadingHTTPServer((args.host, args.port), DashboardHandler)
    print(f"dashboard listening on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
