#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

MEM_MAX="${LZ_HEAVY_MEM_MAX:-3G}"
MEM_HIGH="${LZ_HEAVY_MEM_HIGH:-2G}"
WRAP_TIMEOUT="${LZ_HEAVY_WRAP_TIMEOUT:-7200}"
TEST_TIMEOUT="${LZ_HEAVY_TEST_TIMEOUT:-1800}"

cd "$ROOT_DIR"
exec "${SCRIPT_DIR}/run_with_limits.sh" \
  --mem-max "$MEM_MAX" \
  --mem-high "$MEM_HIGH" \
  --timeout "$WRAP_TIMEOUT" \
  -- \
  python3 tools/run_tests.py --suite heavy.lua --no-build --timeout "$TEST_TIMEOUT" "$@"
