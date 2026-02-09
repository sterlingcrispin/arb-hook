#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${BASE_RPC_URL:-}" ]]; then
  echo "BASE_RPC_URL is required"
  echo "Example: BASE_RPC_URL=https://... scripts/test_flash_fork_cached.sh"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORK_BLOCK="${FORK_BLOCK_NUMBER:-33942262}"
ANVIL_HOST="${ANVIL_HOST:-127.0.0.1}"
ANVIL_PORT="${ANVIL_PORT:-8546}"
CACHE_PATH="${ANVIL_CACHE_PATH:-${ROOT_DIR}/.anvil-cache/base-${FORK_BLOCK}}"
ANVIL_LOG_PATH="${ANVIL_LOG_PATH:-${ROOT_DIR}/.anvil-cache/anvil-${FORK_BLOCK}.log}"
LOCAL_RPC_URL="http://${ANVIL_HOST}:${ANVIL_PORT}"

mkdir -p "${CACHE_PATH}"

anvil_started_by_script=0
anvil_pid=""

rpc_ready() {
  curl -sS \
    -H "Content-Type: application/json" \
    -X POST \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    "${LOCAL_RPC_URL}" >/dev/null 2>&1
}

cleanup() {
  if [[ "${anvil_started_by_script}" == "1" && -n "${anvil_pid}" ]]; then
    kill "${anvil_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if rpc_ready; then
  echo "Using existing anvil at ${LOCAL_RPC_URL}"
else
  echo "Starting cached anvil at ${LOCAL_RPC_URL} (log: ${ANVIL_LOG_PATH})"
  anvil \
    --fork-url "${BASE_RPC_URL}" \
    --fork-block-number "${FORK_BLOCK}" \
    --fork-chain-id 8453 \
    --host "${ANVIL_HOST}" \
    --port "${ANVIL_PORT}" \
    --cache-path "${CACHE_PATH}" \
    >"${ANVIL_LOG_PATH}" 2>&1 &
  anvil_pid="$!"
  anvil_started_by_script=1

  for _ in $(seq 1 80); do
    if rpc_ready; then
      break
    fi
    sleep 0.25
  done

  if ! rpc_ready; then
    echo "Failed to start anvil at ${LOCAL_RPC_URL}"
    echo "Check log: ${ANVIL_LOG_PATH}"
    exit 1
  fi
fi

if [[ "$#" -eq 0 ]]; then
  set -- \
    --match-contract ArbHookFlashForkAaveTest \
    --match-test testForkAaveAttemptAllTracksLegacyRoundSequenceShape \
    -vv
fi

BASE_RPC_URL="${LOCAL_RPC_URL}" RUN_FLASH_FORK_INTEGRATION=true \
  forge test "$@"
