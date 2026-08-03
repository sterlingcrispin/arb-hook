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
ANVIL_QUIET="${ANVIL_QUIET:-1}"
ANVIL_NO_RATE_LIMIT="${ANVIL_NO_RATE_LIMIT:-1}"
ANVIL_CUPS="${ANVIL_CUPS:-5000}"
FORK_IDENTITY_ADDRESS="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" # Base USDC
FORK_BLOCK_HEX="$(printf '0x%x' "${FORK_BLOCK}")"

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

rpc_matches_fork() {
  local block_response
  local code_response
  block_response="$(curl -sS \
    -H "Content-Type: application/json" \
    -X POST \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "${LOCAL_RPC_URL}" 2>/dev/null || true)"
  code_response="$(curl -sS \
    -H "Content-Type: application/json" \
    -X POST \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"${FORK_IDENTITY_ADDRESS}\",\"latest\"],\"id\":1}" \
    "${LOCAL_RPC_URL}" 2>/dev/null || true)"

  [[ "${block_response}" == *"\"result\":\"${FORK_BLOCK_HEX}\""* ]] &&
    [[ "${code_response}" =~ \"result\":\"0x[0-9a-fA-F]{2,}\" ]]
}

cleanup() {
  if [[ "${anvil_started_by_script}" == "1" && -n "${anvil_pid}" ]]; then
    kill "${anvil_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if rpc_ready; then
  if ! rpc_matches_fork; then
    echo "Existing RPC at ${LOCAL_RPC_URL} is not the expected Base fork at block ${FORK_BLOCK}"
    echo "Stop it or choose another ANVIL_PORT before running this test"
    exit 1
  fi
  echo "Using existing anvil at ${LOCAL_RPC_URL}"
else
  echo "Starting cached anvil at ${LOCAL_RPC_URL} (log: ${ANVIL_LOG_PATH})"
  anvil_args=(
    --fork-url "${BASE_RPC_URL}"
    --fork-block-number "${FORK_BLOCK}"
    --fork-chain-id 8453
    --host "${ANVIL_HOST}"
    --port "${ANVIL_PORT}"
    --cache-path "${CACHE_PATH}"
  )
  if [[ "${ANVIL_QUIET}" == "1" ]]; then
    anvil_args+=(--quiet)
  fi
  if [[ "${ANVIL_NO_RATE_LIMIT}" == "1" ]]; then
    anvil_args+=(--no-rate-limit)
  fi
  if [[ -n "${ANVIL_CUPS}" ]]; then
    anvil_args+=(--compute-units-per-second "${ANVIL_CUPS}")
  fi

  anvil "${anvil_args[@]}" >"${ANVIL_LOG_PATH}" 2>&1 &
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
    --match-test testForkMorphoAttemptAllTracksLegacyRoundSequenceFull \
    -vv
fi

BASE_RPC_URL="${LOCAL_RPC_URL}" FORK_ALREADY_PINNED=true RUN_FLASH_FORK_INTEGRATION=true \
  forge test "$@"
