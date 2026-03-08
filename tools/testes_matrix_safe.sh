#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

MEM_MAX="${LZ_MEM_MAX:-3G}"
MEM_HIGH="${LZ_MEM_HIGH:-2G}"
TIMEOUT_WRAPPER="${LZ_WRAPPER_TIMEOUT:-1800}"
TIMEOUT_PER_TEST="${LZ_TEST_TIMEOUT:-120}"

cd "$ROOT_DIR"
exec "${SCRIPT_DIR}/run_with_limits.sh" \
  --mem-max "$MEM_MAX" \
  --mem-high "$MEM_HIGH" \
  --timeout "$TIMEOUT_WRAPPER" \
  -- \
  python3 tools/testes_matrix.py --no-build --timeout "$TIMEOUT_PER_TEST" "$@"
