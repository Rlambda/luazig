#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zig_bin=${ZIG:-zig}

cd "$root"
"$zig_bin" build -Doptimize=Debug
(
  ulimit -s 1024
  ./zig-out/bin/luazig --engine=zig tests/stress/iterative_dispatch.lua "${1:-5000}" "${2:-3000}" "${3:-2000}" "${4:-1000}"
  ./zig-out/bin/luazig --engine=zig --testc tests/stress/iterative_dispatch_testc.lua
)
