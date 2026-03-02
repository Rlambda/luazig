#!/usr/bin/env python3
"""Focused repro for coroutine.lua recursive wrap mismatch (around line 96)."""

from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTES = ROOT / "third_party" / "lua-upstream" / "testes"
REF = ROOT / "build" / "lua-c" / "lua"
ZIG = ROOT / "zig-out" / "bin" / "luazig"

CASE = r"""
local function pf (n, i)
  coroutine.yield(n)
  pf(n*i, i+1)
end

local f = coroutine.wrap(pf)
local s = 1
for i = 1, 10 do
  local v = f(1, 1)
  io.write(i, "\t", tostring(v), "\t", tostring(s), "\n")
  s = s * i
end
"""


def run(cmd: list[str]) -> str:
    p = subprocess.run(cmd, cwd=TESTES, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return p.stdout


def main() -> int:
    tmp = Path("/tmp/coroutine_recursive_repro.lua")
    tmp.write_text(CASE)

    print("== ref ==")
    print(run([str(REF), str(tmp)]).rstrip())

    print("== zig ==")
    print(run([str(ZIG), "--engine=zig", str(tmp)]).rstrip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

