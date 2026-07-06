#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${ROOT_DIR}/lua-5.5.0/testes"
VMEM_KB="${LZ_HEAVY_VMEM_KB:-131072}"
TIMEOUT_S="${LZ_HEAVY_VMEM_TIMEOUT:-120}"
OUT_DIR="${LZ_HEAVY_VMEM_OUT_DIR:-/tmp}"
REF_OUT="${OUT_DIR}/luazig-heavy-ref-vmem${VMEM_KB}.out"
ZIG_OUT="${OUT_DIR}/luazig-heavy-zig-vmem${VMEM_KB}.out"

run_one() {
  local label="$1"
  local exe="$2"
  local out="$3"
  set +e
  (
    cd "$TEST_DIR" || exit 1
    ulimit -Sv "$VMEM_KB"
    timeout "$TIMEOUT_S" "$exe" -e '_port=true; _soft=true' heavy.lua
  ) >"$out" 2>&1
  local rc=$?
  set -e
  printf '%s_rc=%s\n' "$label" "$rc"
  printf '%s_out=%s\n' "$label" "$out"
  tail -40 "$out" || true
}

run_one ref "${ROOT_DIR}/build/lua-c/lua" "$REF_OUT"
run_one zig "${ROOT_DIR}/zig-out/bin/luazig" "$ZIG_OUT"
