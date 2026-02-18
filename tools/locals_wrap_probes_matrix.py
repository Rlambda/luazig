#!/usr/bin/env python3
"""Focused differential checks for locals.lua wrap-close probe scenarios.

Covers three blocks currently guarded by locals_wrap_close_* synthetic modes.
"""

from __future__ import annotations

import argparse
import subprocess
import tempfile
from pathlib import Path

COMMON = r'''
local function func2close (f)
  return setmetatable({}, {__close = f})
end
'''

CASE_1 = COMMON + r'''
local x = false
local y = false
local co = coroutine.wrap(function ()
  local xv <close> = func2close(function () x = true end)
  do
    local yv <close> = func2close(function () y = true end)
    coroutine.yield(100)
  end
  coroutine.yield(200)
  error(23)
end)

print("S1", co(), x, y)
print("S2", co(), x, y)
local ok, err = pcall(co)
print("S3", ok, err, x, y)
'''

CASE_2 = COMMON + r'''
local x = 0
local co = coroutine.wrap(function ()
  local xx <close> = func2close(function (_, msg)
    x = x + 1
    assert(string.find(msg, "@XXX"))
    error("@YYY")
  end)
  local xv <close> = func2close(function ()
    x = x + 1
    error("@XXX")
  end)
  coroutine.yield(100)
  error(200)
end)

print("T1", co(), x)
local ok, err = pcall(co)
print("T2", ok, err, x)
'''

CASE_3 = COMMON + r'''
local x = 0
local y = 0
local co = coroutine.wrap(function ()
  local xx <close> = func2close(function (_, err)
    y = y + 1
    assert(string.find(err, "XXX"))
    error("YYY")
  end)
  local xv <close> = func2close(function ()
    x = x + 1
    error("XXX")
  end)
  coroutine.yield(100)
  return 200
end)

print("U1", co(), x, y)
local ok, err = pcall(co)
print("U2", ok, err, x, y)
'''


def run(lua_bin: Path, code: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "case.lua"
        path.write_text(code, encoding="utf-8")
        return subprocess.run([str(lua_bin), str(path)], text=True, capture_output=True, check=False)


def check_case(name: str, code: str, ref_bin: Path, zig_bin: Path) -> bool:
    ref = run(ref_bin, code)
    zig = run(zig_bin, code)
    ok = ref.returncode == zig.returncode and ref.stdout == zig.stdout and ref.stderr == zig.stderr

    print(f"== {name} ==")
    print(f"ref exit={ref.returncode}, zig exit={zig.returncode}")
    if ok:
        print("match")
        return True

    print("DIFF")
    if ref.stdout != zig.stdout:
        print("-- ref stdout --")
        print(ref.stdout, end="")
        print("-- zig stdout --")
        print(zig.stdout, end="")
    if ref.stderr != zig.stderr:
        print("-- ref stderr --")
        print(ref.stderr, end="")
        print("-- zig stderr --")
        print(zig.stderr, end="")
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref-lua", default="build/lua-c/lua")
    ap.add_argument("--zig-lua", default="zig-out/bin/luazig")
    args = ap.parse_args()

    ref_bin = Path(args.ref_lua)
    zig_bin = Path(args.zig_lua)

    results = [
        check_case("locals_wrap_close_probe", CASE_1, ref_bin, zig_bin),
        check_case("locals_wrap_close_error_probe1", CASE_2, ref_bin, zig_bin),
        check_case("locals_wrap_close_error_probe2", CASE_3, ref_bin, zig_bin),
    ]

    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
