#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ZIG_TARGET_FLAGS="${LUAZIG_ZIG_BUILD_FLAGS:-}"
PERF_CURRENT="${LUAZIG_PERF_CURRENT:-tools/perf/core_current.json}"
MATRIX_TIMEOUT="${LUAZIG_MATRIX_TIMEOUT:-120}"

cd "$ROOT_DIR"

echo "==> build/test (${ZIG_TARGET_FLAGS:-system zig default})"
LUAZIG_ZIG_BUILD_FLAGS="$ZIG_TARGET_FLAGS" python3 tools/api_regression_lane.py

echo "==> targeted parity gate"
python3 tools/run_tests.py \
  --suite nextvar.lua \
  --suite coroutine.lua \
  --suite calls.lua \
  --suite files.lua \
  --suite locals.lua \
  --suite db.lua \
  --suite gc.lua \
  --no-build

echo "==> iterative dispatch stress (1-MB host stack)"
tools/iterative_dispatch_stress.sh

echo "==> full safe matrix"
LZ_TEST_TIMEOUT="$MATRIX_TIMEOUT" tools/testes_matrix_safe.sh

echo "==> core perf snapshot"
python3 tools/perf_core_snapshot.py --out "$PERF_CURRENT" --timeout 240

echo "==> core perf guard"
python3 tools/perf_guard_core.py --baseline tools/perf/core_baseline.json --current "$PERF_CURRENT" --max-regression 0.15

echo "release gate: OK"
