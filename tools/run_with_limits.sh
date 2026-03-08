#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/run_with_limits.sh [options] -- <command> [args...]

Options:
  --mem-max <SIZE>      MemoryMax for heavy service (default: 4G)
  --mem-high <SIZE>     MemoryHigh for heavy service (default: 3G)
  --swap-max <SIZE>     MemorySwapMax for systemd scope (default: 0)
  --timeout <SECONDS>   Hard timeout for command (default: 900)
  --scope-name <NAME>   systemd scope name (default: luazig-heavy-<pid>)
  --oom-score <INT>     OOMScoreAdjust for child (default: 1000)
  -h, --help            Show this help

Notes:
  1) If `systemd-run --user` is available, command runs in a transient user scope.
  2) If not available, wrapper falls back to `ulimit -Sv` + `timeout`.
EOF
}

to_kb() {
  local raw="${1^^}"
  if [[ "$raw" =~ ^([0-9]+)([KMGT]?)$ ]]; then
    local n="${BASH_REMATCH[1]}"
    local u="${BASH_REMATCH[2]}"
    case "$u" in
      "") echo "$n" ;;
      K) echo "$n" ;;
      M) echo $((n * 1024)) ;;
      G) echo $((n * 1024 * 1024)) ;;
      T) echo $((n * 1024 * 1024 * 1024)) ;;
      *) return 1 ;;
    esac
  else
    return 1
  fi
}

MEM_MAX="4G"
MEM_HIGH="3G"
SWAP_MAX="0"
TIMEOUT_S="900"
SCOPE_NAME="luazig-heavy-$$"
OOM_SCORE="1000"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mem-max) MEM_MAX="${2:?missing value}"; shift 2 ;;
    --mem-high) MEM_HIGH="${2:?missing value}"; shift 2 ;;
    --swap-max) SWAP_MAX="${2:?missing value}"; shift 2 ;;
    --timeout) TIMEOUT_S="${2:?missing value}"; shift 2 ;;
    --scope-name) SCOPE_NAME="${2:?missing value}"; shift 2 ;;
    --oom-score) OOM_SCORE="${2:?missing value}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --) shift; break ;;
    *)
      echo "error: unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "error: missing command after --" >&2
  usage
  exit 2
fi

if command -v systemd-run >/dev/null 2>&1 && systemctl --user is-system-running >/dev/null 2>&1; then
  exec systemd-run \
    --user \
    --quiet \
    --pipe \
    --same-dir \
    --wait \
    --collect \
    --unit "$SCOPE_NAME" \
    -p "MemoryMax=$MEM_MAX" \
    -p "MemoryHigh=$MEM_HIGH" \
    -p "MemorySwapMax=$SWAP_MAX" \
    -p "ManagedOOMMemoryPressure=kill" \
    -p "ManagedOOMSwap=kill" \
    -p "OOMScoreAdjust=$OOM_SCORE" \
    -p "OOMPolicy=kill" \
    timeout --foreground --preserve-status "${TIMEOUT_S}s" "$@"
fi

echo "warn: systemd user scope unavailable, using ulimit fallback" >&2
MEM_MAX_KB="$(to_kb "$MEM_MAX")" || {
  echo "error: invalid --mem-max value for fallback: $MEM_MAX" >&2
  exit 2
}
ulimit -Sv "$MEM_MAX_KB"
exec timeout --foreground --preserve-status "${TIMEOUT_S}s" "$@"
