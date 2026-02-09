#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${BASE_RPC_URL:-}" ]]; then
  echo "BASE_RPC_URL is required"
  echo "Example: BASE_RPC_URL=https://... scripts/start_cached_base_anvil.sh"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORK_BLOCK="${FORK_BLOCK_NUMBER:-33942262}"
ANVIL_HOST="${ANVIL_HOST:-127.0.0.1}"
ANVIL_PORT="${ANVIL_PORT:-8546}"
CACHE_PATH="${ANVIL_CACHE_PATH:-${ROOT_DIR}/.anvil-cache/base-${FORK_BLOCK}}"

mkdir -p "${CACHE_PATH}"

echo "Starting cached Base fork on ${ANVIL_HOST}:${ANVIL_PORT}"
echo "Fork block: ${FORK_BLOCK}"
echo "Cache path: ${CACHE_PATH}"

exec anvil \
  --fork-url "${BASE_RPC_URL}" \
  --fork-block-number "${FORK_BLOCK}" \
  --fork-chain-id 8453 \
  --host "${ANVIL_HOST}" \
  --port "${ANVIL_PORT}" \
  --cache-path "${CACHE_PATH}" \
  "$@"
