#!/usr/bin/env python3
"""Reproduce locals.lua coroutine.wrap close/yield ordering behavior.

This is a focused differential check for the blocker around removing
locals_wrap_close_* synthetic probes.
"""

from __future__ import annotations

import argparse
import subprocess
import tempfile
from pathlib import Path

SNIPPET = r'''
local function func2close (f)
  return setmetatable({}, {__close = f})
end

local trace = {}
local co = coroutine.wrap(function ()
  trace[#trace + 1] = "nowX"
  local x <close> = func2close(function (_, msg)
    assert(msg == nil)
    trace[#trace + 1] = "x1"
    coroutine.yield("x")
    trace[#trace + 1] = "x2"
  end)

  return pcall(function ()
    do
      local z <close> = func2close(function (_, msg)
        assert(msg == nil)
        trace[#trace + 1] = "z1"
        coroutine.yield("z")
        trace[#trace + 1] = "z2"
      end)
    end

    trace[#trace + 1] = "nowY"

    local y <close> = func2close(function(_, msg)
      assert(msg == nil)
      trace[#trace + 1] = "y1"
      coroutine.yield("y")
      trace[#trace + 1] = "y2"
    end)

    return 10, 20, 30
  end)
end)

print("R1", co())
print("R2", co())
print("R3", co())
local a, b, c, d = co()
print("R4", a, b, c, d)
print("TRACE", table.concat(trace, ","))
'''


def run(bin_path: Path, script_path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(bin_path), str(script_path)],
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref-lua", default="build/lua-c/lua")
    ap.add_argument("--zig-lua", default="zig-out/bin/luazig")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as td:
        script = Path(td) / "locals_wrap_regression.lua"
        script.write_text(SNIPPET, encoding="utf-8")

        ref = run(Path(args.ref_lua), script)
        zig = run(Path(args.zig_lua), script)

    print("== ref ==")
    print(ref.stdout, end="")
    if ref.stderr:
        print("-- stderr --")
        print(ref.stderr, end="")
    print(f"[exit={ref.returncode}]\n")

    print("== zig ==")
    print(zig.stdout, end="")
    if zig.stderr:
        print("-- stderr --")
        print(zig.stderr, end="")
    print(f"[exit={zig.returncode}]")

    if ref.returncode != zig.returncode or ref.stdout != zig.stdout or ref.stderr != zig.stderr:
        print("\nDIFF: behavior differs")
        return 1

    print("\nOK: behavior matches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
