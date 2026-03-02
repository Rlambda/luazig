#!/usr/bin/env python3
"""Reproduce locals.lua coroutine+__close resume mismatch on luazig."""

from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTES = ROOT / "third_party" / "lua-upstream" / "testes"
REF = ROOT / "build" / "lua-c" / "lua"
ZIG = ROOT / "zig-out" / "bin" / "luazig"

CASE = r'''
local function func2close(f) return setmetatable({}, {__close=f}) end
local trace = {}
local co = coroutine.wrap(function ()
  trace[#trace+1] = 'nowX'
  local x <close> = func2close(function(_,msg)
    assert(msg==nil)
    trace[#trace+1]='x1'
    coroutine.yield('x')
    trace[#trace+1]='x2'
  end)
  return pcall(function()
    do
      local z <close> = func2close(function(_,msg)
        assert(msg==nil)
        trace[#trace+1]='z1'
        coroutine.yield('z')
        trace[#trace+1]='z2'
      end)
    end
    trace[#trace+1]='nowY'
    local y <close> = func2close(function(_,msg)
      assert(msg==nil)
      trace[#trace+1]='y1'
      coroutine.yield('y')
      trace[#trace+1]='y2'
    end)
    return 10,20,30
  end)
end)

local function dump(tag, ...)
  local t={...}
  io.write(tag, "\t#", #t)
  for i=1,#t do io.write("\t", tostring(t[i])) end
  io.write("\n")
end

dump('1', co())
dump('2', co())
dump('3', co())
dump('4', co())
for i,v in ipairs(trace) do print('tr', i, v) end
'''


def run(cmd: list[str]) -> str:
    p = subprocess.run(cmd, cwd=TESTES, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return p.stdout


def main() -> int:
    tmp = Path('/tmp/locals_coroutine_close_repro.lua')
    tmp.write_text(CASE)

    print('== ref ==')
    print(run([str(REF), str(tmp)]).rstrip())

    print('== zig ==')
    print(run([str(ZIG), '--engine=zig', str(tmp)]).rstrip())
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
