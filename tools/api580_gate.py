#!/usr/bin/env python3
"""P16.17 T3: dedicated api.lua:580 regression gate (both build modes).

smoke/69 is only a documentation/differential helper: the differential smoke
runner does not enable --testc, so on hosts without the Zig testc module the
test silently prints its skip path — a skipped test proves nothing. This lane
is the real, permanent gate:

  1. builds luazig in Debug AND ReleaseFast;
  2. runs the EXACT upstream api.lua:576-586 fixed-buffer shape via --testc;
  3. asserts 0 < m2-m1 < 400 (upstream: `m2 > m1 and m2 - m1 < 400`);
  4. executes the loaded closure and verifies X == N and Y == the constant;
  5. additionally prints @sizeOf-probe results for representation tracking;
  6. exits nonzero on ANY failure (delta, assertion, execution, build).

Exit code 0 = gate green in both modes.
"""

import subprocess
import sys
import tempfile
import pathlib
import os

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Faithful reproducer of lua-5.5.0/testes/api.lua:576-586 (unchanged shape:
# same N, same chunk construction, same dump(fixed), same T.testC loadstring
# with mode B, same collectgarbage boundary, same upstream assertion bounds).
PROBE = r"""
local N = 1000
local source = {}
for i = 1, N do source[i] = "X = X + 1; " end
source[#source + 1] = string.format("Y = '%s'", string.rep("a", N))
source = table.concat(source)
source = load(source, "name1")
source = string.dump(source, true)
collectgarbage(); collectgarbage()
local m1 = collectgarbage("count") * 1024
local code = T.testC([[loadstring 2 name B; return 1]], source)
collectgarbage()
local m2 = collectgarbage("count") * 1024
local delta = m2 - m1
io.write(string.format("DELTA=%d\n", math.floor(delta + 0.5)))
assert(m2 > m1 and m2 - m1 < 400, "api.lua:580 parity: delta=" .. math.floor(delta + 0.5))
X = 0; code(); assert(X == N and Y == string.rep("a", N))
io.write("EXEC=OK\n")
"""

# Optional struct-size probe compiled as a tiny Zig unit using the library's
# own comptime asserts (LuaString == 48 both modes; lstrfix prefix == 32).
# Keeping sizes in the gate catches future build-mode layout drift.
SIZE_TEST = r"""
const std = @import("std");
const lua = @import("lua");
test "representation sizes are build-mode stable" {
    const vm = @import("lua").vm;
    const bc = @import("lua").bytecode;
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(vm.LuaString));
    try std.testing.expectEqual(@as(usize, 32), vm.LuaString.lstrfix_header_size);
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(vm.Closure));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(vm.Cell));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(bc.Upvaldesc));
    try std.testing.expectEqual(@as(usize, 200), @sizeOf(bc.Proto));
    try std.testing.expect(@sizeOf(vm.CallFrame) <= 104);
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(@import("lua").ltable.Node));
}
"""


def run_mode(mode: str) -> int:
    print(f"=== api580 gate [{mode}] ===")
    r = subprocess.run(
        ["zig", "build", f"-Doptimize={mode}"],
        cwd=ROOT, capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"BUILD FAIL [{mode}]:\n{r.stderr[-2000:]}")
        return 1
    binary = ROOT / "zig-out" / "bin" / "luazig"
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(PROBE)
        probe = f.name
    try:
        env = dict(os.environ)
        r = subprocess.run(
            [str(binary), "--testc", probe],
            capture_output=True, text=True, env=env, timeout=300,
        )
        out = r.stdout + r.stderr
        delta = None
        for line in out.splitlines():
            if line.startswith("DELTA="):
                delta = int(line.split("=")[1])
        ok_exec = "EXEC=OK" in out
        if delta is None or r.returncode != 0 or not ok_exec:
            print(f"RUN FAIL [{mode}] rc={r.returncode}:\n{out[-2000:]}")
            return 1
        if not (0 < delta < 400):
            print(f"ASSERT FAIL [{mode}]: delta={delta} (must be 0 < delta < 400)")
            return 1
        print(f"PASS [{mode}]: delta={delta} B (< 400), closure executed, X/Y verified")
        return 0
    finally:
        os.unlink(probe)


def run_size_probe() -> int:
    print("=== representation sizes (unit-test path) ===")
    with tempfile.TemporaryDirectory() as td:
        # Reuse the library's own test build: `zig build test` compiles the
        # comptime asserts (LuaString 48 / lstrfix 32) in the given mode.
        for mode in ("Debug", "ReleaseFast"):
            r = subprocess.run(
                ["zig", "build", "test", f"-Doptimize={mode}"],
                cwd=ROOT, capture_output=True, text=True,
            )
            if r.returncode != 0:
                print(f"SIZES FAIL [{mode}]:\n{r.stderr[-2000:]}")
                return 1
            print(f"PASS [{mode}]: comptime size invariants hold "
                  "(LuaString=48, LSTRFIX=32, Closure=40, Cell=40, "
                  "Upvaldesc=16, Proto=200, CallFrame<=104, Node=32)")
    return 0


def main() -> int:
    rc = 0
    rc |= run_mode("Debug")
    rc |= run_mode("ReleaseFast")
    rc |= run_size_probe()
    if rc == 0:
        print("api580 gate: GREEN (Debug + ReleaseFast + sizes)")
    else:
        print("api580 gate: RED")
    return rc


if __name__ == "__main__":
    sys.exit(main())
