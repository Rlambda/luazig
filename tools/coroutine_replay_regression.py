#!/usr/bin/env python3
from __future__ import annotations

import subprocess
from pathlib import Path


def run(cmd: list[str], cwd: Path) -> tuple[int, str]:
    p = subprocess.run(
        cmd,
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=120,
    )
    return p.returncode, p.stdout


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    testes = root / "third_party" / "lua-upstream" / "testes"
    ref = root / "build" / "lua-c" / "lua"
    zig = root / "zig-out" / "bin" / "luazig"

    chunk = r"""
local co = coroutine.wrap(function (t)
  for k, v in pairs(t) do
    local k1 = next(t)
    if k ~= k1 then print("MISMATCH", tostring(k), tostring(k1)) end
    t[k] = nil
    coroutine.yield(v)
  end
end)
local t = {}
t[{1}] = 1; t[{2}] = 2; t[string.rep("a",50)] = "a"
t[string.rep("b",50)] = "b"; t[{3}] = 3; t[string.rep("c",10)] = "c"
t[function() return 10 end] = 10
local count = 7
while co(t) do
  collectgarbage("collect")
  count = count - 1
end
print("FINAL", count, next(t) == nil)
"""

    ref_code, ref_out = run([str(ref), "-e", chunk], testes)
    zig_code, zig_out = run([str(zig), "--engine=zig", "-e", chunk], testes)

    print("== ref ==")
    print(ref_out.rstrip())
    print("== zig ==")
    print(zig_out.rstrip())

    if ref_code != 0 or zig_code != 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
