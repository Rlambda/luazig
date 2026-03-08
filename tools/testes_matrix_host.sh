#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

TIMEOUT_PER_TEST="${LZ_TEST_TIMEOUT:-120}"
TIMEOUT_OVERRIDES="${LZ_TEST_TIMEOUT_OVERRIDES:-all.lua=300}"
JSON_OUT="${LZ_MATRIX_JSON_OUT:-}"

cd "$ROOT_DIR"

if [[ ! -w /dev/full ]]; then
  echo "warn: /dev/full is not writable in this environment." >&2
  echo "warn: run this script from host shell (outside sandbox) for true files.lua parity." >&2
fi

CMD=(python3 tools/testes_matrix.py --no-build --timeout "$TIMEOUT_PER_TEST" --timeout-overrides "$TIMEOUT_OVERRIDES")
if [[ -n "$JSON_OUT" ]]; then
  CMD+=(--json-out "$JSON_OUT")
fi
CMD+=("$@")

exec "${CMD[@]}"
