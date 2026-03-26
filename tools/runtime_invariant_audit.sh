#!/usr/bin/env bash
set -euo pipefail

# Runtime invariant audit focused on areas that previously regressed:
# coroutine/close/error/debug-hooks/metatable/gc/files.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 tools/run_tests.py --no-build \
  --suite coroutine.lua \
  --suite calls.lua \
  --suite db.lua \
  --suite gc.lua \
  --suite files.lua \
  --suite locals.lua

# Additional targeted suites with high signal for control-flow + error paths.
python3 tools/run_tests.py --no-build --suite errors.lua
python3 tools/run_tests.py --no-build --suite closure.lua

echo "runtime invariant audit: ok"
