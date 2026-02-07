#!/bin/sh
set -eu

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing: $1" >&2
    return 1
  fi
  return 0
}

missing=0
need_cmd make || missing=1
need_cmd gcc || missing=1
need_cmd git || missing=1
need_cmd python3 || missing=1

if ! ./tools/zig version >/dev/null 2>&1; then
  echo "missing: zig (try: sudo pacman -S --needed zig)" >&2
  echo "or: ./tools/fetch-zig.sh 0.15.2" >&2
  missing=1
fi

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "ok"

