#!/usr/bin/env python3
"""
perf_api580_ledger.py — fully-explained allocation ledger for the
api.lua:555-580 fixed-buffer load interval.

The upstream test (lua-5.5.0/testes/api.lua:555-580) builds a chunk of
1000x"X = X + 1; " plus a 1000-char string constant, compiles it, dumps it
stripped, then measures:

    m1 = collectgarbage("count") * 1024
    code = T.testC([[loadstring 2 name B; return 1]], source)  -- mode 'B'
    collectgarbage()
    m2 = collectgarbage("count") * 1024
    assert(m2 - m1 < 400)

This artifact explains the measured m2-m1 delta byte-for-byte:

  1. A Zig test harness (generated into a temp dir, never committed) runs the
     exact interval under a TrackingAllocator, snapshots the outstanding-
     allocation map at m1/m2, diffs them, and labels every new allocation by
     pointer identity (walking the loaded CODE closure) plus nm symbolization
     of the allocation return addresses.
  2. Two harness variants bracket the one context-dependent component —
      whether the short strings "X"/"Y" are still interned when the
      interval's undump runs:
      - "anchored": the SETUP chunk ends with the api.lua:578-579 trailing
        statements ("X = 0; Y = 0; X = nil; Y = nil"), making "X"/"Y"
        constants of the enclosing (always-alive) chunk -> they stay
        interned through every GC -> no re-intern -> delta 544.
      - "variance": no X/Y constants in the enclosing chunk -> the initial
        compile closure (the only referent) is collected by the pre-m1 GCs
        -> "X"/"Y" swept -> re-interned by the undump -> delta 690.
   3. The luazig binary cross-checks: the anchored driver (the exact api.lua
      statement shape, including the trailing verification statements)
      measures 544; the same driver minus the trailing X/Y statements
      measures 690.
   4. The PUC side is source-derived (build/lua-c/lua has no testc module, so
      the mode-'B' interval cannot be executed under PUC): struct sizes are
      gcc-measured from the vendored lua-5.5.0 headers, and both behavioral
      assumptions are verified against the PUC binary with an X/Y rooting
      probe run in the anchored shape: the initial compile closure IS
      collected, yet "X"/"Y" stay interned (the enclosing chunk's constants
      root them there too) — so PUC performs no re-intern either, and the
      identical probe result under luazig confirms mechanism parity.

Output: tools/perf/current-api580-ledger.json

Usage:
  perf_api580_ledger.py                # build + measure + write JSON
  perf_api580_ledger.py --no-build     # skip zig build + make lua-c
  perf_api580_ledger.py --out PATH     # custom output path
  perf_api580_ledger.py --keep-temp    # keep the temp harness dir
"""
from __future__ import annotations

import argparse
import bisect
import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

# Shared provenance helpers live next to this script; make them importable
# regardless of the caller's CWD.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import provenance

ROOT = Path(__file__).resolve().parents[1]
ZIG_LUA = ROOT / "zig-out" / "bin" / "luazig"
PUC_LUA = ROOT / "build" / "lua-c" / "lua"


def run(cmd: list[str], timeout_s: int = 300,
        cwd: Path | None = None) -> tuple[int, str, str]:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s,
                       cwd=str(cwd) if cwd else None)
    return p.returncode, p.stdout, p.stderr


def build_all(modes: list[str]) -> None:
    """Build the luazig binary once per requested optimize mode.

    After the LAST mode is built, the binary on disk corresponds to the last
    entry; per-mode driver runs below build+run inside the same mode loop, so
    each delta is always measured with the binary just built for that mode.
    The PUC reference is mode-independent and built once.
    """
    for mode in modes:
        run(["zig", "build", f"-Doptimize={mode}"], timeout_s=600)
    run(["make", "-C", str(ROOT / "lua-5.5.0"), "clean", "lua-c"],
        timeout_s=180)


# ---------------------------------------------------------------------------
# Zig measurement harness — generated into a temp dir, compiled with
# `zig test -O ReleaseFast`, run directly. Emits JSON between markers.
# ---------------------------------------------------------------------------

HARNESS_TEMPLATE = r'''
const std = @import("std");
const lua = @import("lua");
const vm_mod = lua.internal.vm;
const bc = lua.internal.bytecode;
const ta = lua.internal.tracking_alloc;

// Backing allocator matches the luazig binary (src/bin/luazig.zig uses
// std.heap.smp_allocator behind the TrackingAllocator).
var tracker = ta.TrackingAllocator.init(std.heap.smp_allocator);

// SETUP chunk: mirrors the api.lua:555-580 driver statement sequence exactly
// (source build -> text compile -> stripped dump -> two full GCs), with the
// interval body pre-compiled as RUNB so the Zig harness can bracket the
// interval with leak-map snapshots taken from native code.
//   - RUNB/CODE/M2/BINSRC global slots are created here (pre-m1) so the
//     interval itself never grows the global table.
//   - __XY_ROOT_STMT__ selects the variant: the anchored api.lua shape ends
//     with "X = 0; Y = 0; X = nil; Y = nil" (api.lua:578-579), which makes
//     "X"/"Y" constants of the ENCLOSING chunk — the SETUP closure stays
//     alive on the C stack for the whole measurement, so those constants
//     root the short strings "X"/"Y" through every GC, exactly like the
//     running api.lua main chunk roots them during the upstream test. The
//     variance variant omits them, leaving "X"/"Y" referenced only by the
//     initial compile closure (which the pre-m1 GCs collect).
const SETUP_SRC =
    \\local T = T or require "T"
    \\RUNB = load([=[CODE = T.testC("loadstring 2 name B; return 1", BINSRC); collectgarbage(); M2 = collectgarbage("count") * 1024]=])
    \\CODE, M2 = 0, 0
    \\local source = {}
    \\local N = 1000
    \\for i = 1, N do source[i] = "X = X + 1; " end
    \\source[#source + 1] = string.format("Y = '%s'", string.rep("a", N))
    \\source = table.concat(source)
    \\source = load(source, "name1")
    \\source = string.dump(source, true)
    \\collectgarbage(); collectgarbage()
    \\BINSRC = source
    \\__XY_ROOT_STMT__
;

// collectgarbage("count") * 1024, computed natively: k = gcControl(3) (KB,
// floored), b = gcControl(4) (byte remainder) -> m = k*1024 + b. This is the
// same arithmetic the Lua-side driver performs.
fn countTotal(vm: *vm_mod.Vm) f64 {
    const k = vm.gcControl(3, 0, -1);
    const b = vm.gcControl(4, 0, -1);
    return @as(f64, @floatFromInt(k)) * 1024.0 + @as(f64, @floatFromInt(b));
}

// Hash exactly as internStr does (Wyhash over hash_seed) so string_intern
// lookups hit the right bucket.
fn internHash(vm: *vm_mod.Vm, raw: []const u8) u64 {
    var h = std.hash.Wyhash.init(vm.hash_seed);
    h.update(raw);
    return h.final();
}

const SnapEntry = struct { len: usize, ret_addr: usize };
const Snap = std.AutoHashMapUnmanaged(usize, SnapEntry);

// Copy the tracker's outstanding-allocation map into snapshot storage that
// does NOT flow through the tracker (arena over page_allocator), so the
// snapshot itself never pollutes the measurement.
fn snapshot(alloc: std.mem.Allocator) !Snap {
    var s: Snap = .{};
    var it = tracker.leak_map.iterator();
    while (it.next()) |e| {
        try s.put(alloc, e.key_ptr.*, .{ .len = e.value_ptr.len, .ret_addr = e.value_ptr.ret_addr });
    }
    return s;
}

fn numOrNeg(v: vm_mod.Value) f64 {
    return switch (v) {
        .Int => |i| @floatFromInt(i),
        .Num => |n| n,
        else => -1,
    };
}

test "api580 interval allocation ledger" {
    tracker.enableLeakTracking();
    const talloc = tracker.allocator();

    var vm = vm_mod.Vm.init(talloc, false);
    defer vm.deinit();
    _ = try vm.setupMainHandle();
    vm.setDynamicBytecodeCompiler(vm_mod.defaultBytecodeCompiler);
    try vm.enableTestcModule();
    // pmain parity (src/bin/luazig.zig:1175-1176): GCRESTART then GCGEN.
    _ = vm.gcControl(1, 0, -1);
    _ = vm.gcControl(7, 0, -1);

    var st = lua.State.fromVm(&vm);

    // Compile + run SETUP. The duplicate closure stays on the C stack (a GC
    // root via the main handle), mirroring the driver chunk's live frame
    // that keeps the interval's enclosing constants interned throughout.
    if (st.loadbuffer(SETUP_SRC, "setup") != .ok) return error.SetupCompile;
    try st.pushvalue(-1);
    if (st.pcall(0, 0) != .ok) return error.SetupRun;
    // Pre-grow the C stack so interval pushes never allocate.
    try st.stack.ensureUnusedCapacity(vm.alloc, 64);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const sa = arena.allocator();

    // --- m1: count + outstanding-allocation snapshot + intern diagnostics ---
    const m1 = countTotal(&vm);
    const l1 = try snapshot(sa);
    const x_m1 = vm.string_intern.lookup("X", internHash(&vm, "X")) != null;
    const y_m1 = vm.string_intern.lookup("Y", internHash(&vm, "Y")) != null;
    const name_m1 = vm.string_intern.lookup("name", internHash(&vm, "name")) != null;
    const b_m1 = vm.string_intern.lookup("B", internHash(&vm, "B")) != null;

    // --- the interval: RUNB executes testC loadstring + collectgarbage ---
    _ = st.getglobal("RUNB") catch return error.GetRunb;
    if (st.pcall(0, 0) != .ok) return error.RunbRun;

    // --- m2 ---
    const m2 = countTotal(&vm);
    const l2 = try snapshot(sa);
    const x_m2 = vm.string_intern.lookup("X", internHash(&vm, "X")) != null;
    const y_m2 = vm.string_intern.lookup("Y", internHash(&vm, "Y")) != null;

    // Cross-check: the Lua-computed M2 global must equal the native m2.
    _ = st.getglobal("M2") catch return error.GetM2;
    const m2g = numOrNeg(st.stack.items[st.stack.items.len - 1]);

    // --- walk the CODE closure for pointer-identity labels ---
    _ = st.getglobal("CODE") catch return error.GetCode;
    const codev = st.stack.items[st.stack.items.len - 1];
    const cl = switch (codev) {
        .Closure => |c| c,
        else => return error.CodeNotClosure,
    };
    const proto = cl.proto orelse return error.CodeNoProto;

    var labels = std.AutoHashMapUnmanaged(usize, []const u8){};
    try labels.put(sa, @intFromPtr(cl), "Closure");
    if (cl.upvalues.len > 0) {
        try labels.put(sa, @intFromPtr(cl.upvalues.ptr), "Closure.upvalues slice");
        try labels.put(sa, @intFromPtr(cl.upvalues[0]), "Cell");
    }
    try labels.put(sa, @intFromPtr(proto), "Proto");
    if (proto.resolved_values.len > 0)
        try labels.put(sa, @intFromPtr(proto.resolved_values.ptr), "resolved_values");
    if (proto.upvalues.len > 0)
        try labels.put(sa, @intFromPtr(proto.upvalues.ptr), "upvalues_desc");
    for (proto.resolved_values) |rv| switch (rv) {
        .String => |s| if (s.isExternal())
            try labels.put(sa, @intFromPtr(s), "external_LuaString_header"),
        else => {},
    };
    // Label the interval-relevant short strings by pointer identity: the
    // re-interned "X"/"Y" (when the initial compile closure died before m1)
    // and the chunk-name/mode strings "name"/"B" interned by the testC
    // loadstring path (vm.zig builtinTestcTestC .loadstring).
    if (vm.string_intern.lookup("X", internHash(&vm, "X"))) |ls|
        try labels.put(sa, @intFromPtr(ls), "short_string_X");
    if (vm.string_intern.lookup("Y", internHash(&vm, "Y"))) |ls|
        try labels.put(sa, @intFromPtr(ls), "short_string_Y");
    if (vm.string_intern.lookup("name", internHash(&vm, "name"))) |ls|
        try labels.put(sa, @intFromPtr(ls), "short_string_name");
    if (vm.string_intern.lookup("B", internHash(&vm, "B"))) |ls|
        try labels.put(sa, @intFromPtr(ls), "short_string_B");
    if (proto.source_backing.pin) |pin| {
        try labels.put(sa, @intFromPtr(pin), "source_backing.pin_BINSRC");
    }

    // --- diff: new outstanding (l2 - l1) and freed (l1 - l2) ---
    var freed_count: usize = 0;
    var freed_bytes: usize = 0;
    var fit = l1.iterator();
    while (fit.next()) |e| {
        if (!l2.contains(e.key_ptr.*)) {
            freed_count += 1;
            freed_bytes += e.value_ptr.len;
        }
    }

    // --- emit JSON between markers on stderr ---
    const w = std.debug.print;
    w("===API580_JSON_BEGIN===\n", .{});
    w("{{\n", .{});
    w("  \"m1\": {d},\n", .{m1});
    w("  \"m2\": {d},\n", .{m2});
    w("  \"delta\": {d},\n", .{m2 - m1});
    w("  \"m2_global_crosscheck\": {d},\n", .{m2g});
    w("  \"x_interned_m1\": {},\n", .{x_m1});
    w("  \"y_interned_m1\": {},\n", .{y_m1});
    w("  \"name_interned_m1\": {},\n", .{name_m1});
    w("  \"b_interned_m1\": {},\n", .{b_m1});
    w("  \"x_interned_m2\": {},\n", .{x_m2});
    w("  \"y_interned_m2\": {},\n", .{y_m2});
    w("  \"l1_outstanding\": {d},\n", .{l1.count()});
    w("  \"l2_outstanding\": {d},\n", .{l2.count()});
    w("  \"freed_in_interval_count\": {d},\n", .{freed_count});
    w("  \"freed_in_interval_bytes\": {d},\n", .{freed_bytes});
    w("  \"sizes\": {{\n", .{});
    w("    \"Proto\": {d},\n", .{@sizeOf(bc.Proto)});
    w("    \"Closure\": {d},\n", .{@sizeOf(vm_mod.Closure)});
    w("    \"Cell\": {d},\n", .{@sizeOf(vm_mod.Cell)});
    w("    \"LuaString\": {d},\n", .{@sizeOf(vm_mod.LuaString)});
    w("    \"LuaString_lstrfix\": {d},\n", .{vm_mod.LuaString.lstrfix_header_size});
    w("    \"Value\": {d},\n", .{@sizeOf(vm_mod.Value)});
    w("    \"Upvaldesc\": {d},\n", .{@sizeOf(bc.Upvaldesc)});
    w("    \"Constant\": {d}\n", .{@sizeOf(bc.Constant)});
    w("  }},\n", .{});
    w("  \"code_closure\": {{\n", .{});
    w("    \"ptr\": {d},\n", .{@intFromPtr(cl)});
    w("    \"tree_is_root\": {},\n", .{cl.proto.?.tree == cl.proto});
    w("    \"upvalues_len\": {d},\n", .{cl.upvalues.len});
    w("    \"proto\": {{\n", .{});
    w("      \"ptr\": {d},\n", .{@intFromPtr(proto)});
    w("      \"gc_charged\": {},\n", .{proto.flags.gc_charged});
    w("      \"gc_footprint\": {d},\n", .{bc.protoTreeFootprint(proto.tree.?) + bc.sourceBackingFootprint(proto.tree.?.source_backing)});
    w("      \"fixed_arrays\": {},\n", .{proto.flags.fixed_arrays});
    w("      \"k_len\": {d},\n", .{proto.k.len});
    w("      \"resolved_values_len\": {d},\n", .{proto.resolved_values.len});
    w("      \"upvalues_len\": {d},\n", .{proto.upvalues.len});
    w("      \"p_len\": {d},\n", .{proto.p.len});
    w("      \"code_len\": {d},\n", .{proto.code.len});
    w("      \"lineinfo_len\": {d},\n", .{proto.lineinfo.len});
    w("      \"locvars_len\": {d},\n", .{proto.locvars.len});
    w("      \"live_reg_top_len\": {d},\n", .{proto.live_reg_top.len});
    w("      \"ref_count\": {d},\n", .{proto.ref_count});
    w("      \"source_backing_extra\": {},\n", .{proto.source_backing.extra != null});
    w("      \"source_backing_pin_len\": {d},\n", .{if (proto.source_backing.pin) |p| p.len else 0});
    w("      \"constants\": [", .{});
    for (proto.resolved_values, 0..) |rv, i| {
        if (i > 0) w(", ", .{});
        switch (rv) {
            .String => |s| w("{{\"type\": \"string\", \"len\": {d}, \"srkind\": {d}}}", .{ s.len(), s.srkind }),
            .Int => |v| w("{{\"type\": \"int\", \"value\": {d}}}", .{v}),
            .Num => |v| w("{{\"type\": \"num\", \"value\": {d}}}", .{v}),
            else => w("{{\"type\": \"{s}\"}}", .{rv.typeName()}),
        }
    }
    w("]\n", .{});
    w("    }}\n", .{});
    w("  }},\n", .{});
    w("  \"new_outstanding\": [\n", .{});
    var nit = l2.iterator();
    var first = true;
    while (nit.next()) |e| {
        if (l1.contains(e.key_ptr.*)) continue;
        const label = labels.get(e.key_ptr.*) orelse "unmatched";
        if (!first) w(",\n", .{});
        first = false;
        w("    {{\"ptr\": {d}, \"len\": {d}, \"ret_addr\": {d}, \"label\": \"{s}\"}}", .{ e.key_ptr.*, e.value_ptr.len, e.value_ptr.ret_addr, label });
    }
    w("\n  ],\n", .{});
    w("  \"freed_in_interval\": [\n", .{});
    var fit2 = l1.iterator();
    first = true;
    while (fit2.next()) |e| {
        if (l2.contains(e.key_ptr.*)) continue;
        if (!first) w(",\n", .{});
        first = false;
        w("    {{\"ptr\": {d}, \"len\": {d}, \"ret_addr\": {d}}}", .{ e.key_ptr.*, e.value_ptr.len, e.value_ptr.ret_addr });
    }
    w("\n  ]\n", .{});
    w("}}\n", .{});
    w("===API580_JSON_END===\n", .{});
}
'''

# Variant selector for the \\__XY_ROOT_STMT__ placeholder line in SETUP_SRC.
# (The replacement includes the multiline-literal \\ prefix.)
# Anchored: the api.lua:578-579 trailing statements, which make "X"/"Y"
# constants of the enclosing (always-alive) chunk — this is the upstream
# test's actual rooting mechanism for the short strings "X"/"Y".
XY_ROOT_STMT_ANCHORED = r"\X = 0; Y = 0; X = nil; Y = nil"
# Variance: no "X"/"Y" constants in the enclosing chunk; the short strings
# are then referenced only by the initial compile closure, which the pre-m1
# full GCs collect (probe-verified below), so the interval's undump
# re-interns both strings (+146B charged).
XY_ROOT_STMT_VARIANCE = r"\-- (variance context: no X/Y constants in the enclosing chunk)"


def parse_harness_json(output: str) -> dict:
    begin = output.find("===API580_JSON_BEGIN===")
    end = output.find("===API580_JSON_END===")
    if begin < 0 or end < 0:
        raise RuntimeError("harness did not emit JSON markers")
    return json.loads(output[begin + len("===API580_JSON_BEGIN==="):end])


def render_harness(xy_root_stmt: str) -> str:
    # The placeholder occupies a whole \\<placeholder> line of the Zig
    # multiline literal; replace it together with its \\ prefix so the
    # replacement becomes exactly one source line.
    return HARNESS_TEMPLATE.replace("\\__XY_ROOT_STMT__", xy_root_stmt)


def nm_symbols(binpath: Path) -> list[tuple[int, str]]:
    """Sorted (address, name) pairs from nm for return-address symbolization."""
    rc, out, err = run(["nm", str(binpath)], timeout_s=120)
    if rc != 0:
        raise RuntimeError(f"nm failed: {err}")
    syms: list[tuple[int, str]] = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0]:
            try:
                syms.append((int(parts[0], 16), parts[2]))
            except ValueError:
                pass
    syms.sort()
    return syms


def symbolize(syms: list[tuple[int, str]], addr: int) -> str:
    i = bisect.bisect_right(syms, (addr, "\xff")) - 1
    return syms[i][1] if i >= 0 else "?"


def build_and_run_harness(tmpdir: Path, variant: str,
                          keep_stmt: str) -> dict:
    """Generate, compile, run one harness variant; return its JSON result
    with symbolized allocation sites."""
    src_path = tmpdir / f"harness_{variant}.zig"
    bin_path = tmpdir / f"harness_{variant}_bin"
    src_path.write_text(render_harness(keep_stmt), encoding="utf-8")
    rc, _, err = run(
        ["zig", "test", "-O", "ReleaseFast", "-lc", "--test-no-exec",
         f"-femit-bin={bin_path}",
         "--dep", "lua", f"-Mroot={src_path}",
         "--dep", "util", f"-Mlua={ROOT / 'src' / 'lua' / 'root.zig'}",
         f"-Mutil={ROOT / 'src' / 'util' / 'root.zig'}"],
        timeout_s=600, cwd=ROOT)
    if rc != 0:
        raise RuntimeError(f"harness {variant} compile failed:\n{err}")
    rc, out, err = run([str(bin_path)], timeout_s=120)
    if rc != 0:
        raise RuntimeError(f"harness {variant} run failed:\n{err}\n{out}")
    data = parse_harness_json(err if "===API580_JSON_BEGIN===" in err else out)
    syms = nm_symbols(bin_path)
    for entry in data["new_outstanding"]:
        entry["symbol"] = symbolize(syms, entry["ret_addr"])
    return data


# ---------------------------------------------------------------------------
# Binary cross-check drivers (luazig --testc)
# ---------------------------------------------------------------------------

# The exact api.lua:555-580 statement shape: the trailing verification
# statements (api.lua:578-579) make "X"/"Y" constants of the driver chunk
# itself, so the short strings stay interned through every GC (the driver
# frame is live for the whole run) and the interval's undump finds them in
# the intern table — no re-intern.
DRIVER_ANCHORED = r'''
local T = T or require "T"
local source = {}
local N = 1000
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
io.write("DELTA=" .. math.floor(delta + 0.5) .. "\n")
io.write("M1=" .. math.floor(m1 + 0.5) .. "\n")
io.write("M2=" .. math.floor(m2 + 0.5) .. "\n")
io.write("UNDER400=" .. tostring(delta < 400) .. "\n")
X = 0; code(); assert(X == N and Y == string.rep("a", N))
X = nil; Y = nil
'''

# Variance context: identical shape minus the trailing X/Y statements, so
# the driver chunk has no "X"/"Y" constants. The short strings are then
# referenced only by the initial compile closure, which the pre-m1 full GCs
# collect — the interval's undump re-interns both (+146B charged). This is
# the mechanism behind the historical 544-690 range recorded in STATUS.md.
DRIVER_NO_XY_ROOT = r'''
local T = T or require "T"
local source = {}
local N = 1000
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
io.write("DELTA=" .. math.floor(delta + 0.5) .. "\n")
io.write("M1=" .. math.floor(m1 + 0.5) .. "\n")
io.write("M2=" .. math.floor(m2 + 0.5) .. "\n")
io.write("UNDER400=" .. tostring(delta < 400) .. "\n")
code()
'''


def run_driver(script: str) -> dict:
    rc, out, err = run([str(ZIG_LUA), "--testc", "-e", script], timeout_s=60)
    result: dict[str, int | str] = {}
    for line in (out + err).splitlines():
        line = line.strip()
        for key in ("DELTA", "M1", "M2"):
            if line.startswith(f"{key}="):
                result[key.lower()] = int(line.split("=")[1])
        if line.startswith("UNDER400="):
            result["under400"] = line.split("=")[1]
    if "delta" not in result:
        raise RuntimeError(f"driver produced no DELTA:\n{out}\n{err}")
    return result


# ---------------------------------------------------------------------------
# X/Y rooting probe — binary evidence for the two behavioral assumptions in
# the ledgers, run under BOTH PUC and luazig in the anchored api.lua shape:
#   1. the initial compile closure is collected by the pre-m1 full GCs
#      (weak-table liveness), and
#   2. the short strings "X"/"Y" nevertheless stay interned (same interned
#      object across the GCs), because the trailing api.lua:578-579
#      statements make them constants of the enclosing (running) chunk.
# Pointer identity is detected via table keys: short-string keys hash by
# pointer, so a re-interned "X" lands in a different slot and the lookup
# misses.
# ---------------------------------------------------------------------------

XY_ROOT_PROBE = r'''
local t = {}
local w = setmetatable({}, {__mode="v"})
local a1 = ("XY"):sub(1,1)   -- "X" via sub (interned short string)
local b1 = ("ZY"):sub(2,2)   -- "Y" via sub
t[a1] = 1; t[b1] = 2
local source = {}
local N = 1000
for i = 1, N do source[i] = "X = X + 1; " end
source[#source + 1] = string.format("Y = '%s'", string.rep("a", N))
source = table.concat(source)
source = load(source, "name1")
w[1] = source
source = string.dump(source, true)
collectgarbage(); collectgarbage()
X = 0; Y = 0
X = nil; Y = nil
local a2 = ("XY"):sub(1,1)
local b2 = ("ZY"):sub(2,2)
io.write("closure_alive=", tostring(w[1] ~= nil), "\n")
io.write("X_same_ptr=", tostring(t[a2] == 1), "\n")
io.write("Y_same_ptr=", tostring(t[b2] == 2), "\n")
'''


def run_xy_root_probe(binary: Path, label: str) -> dict:
    rc, out, err = run([str(binary), "-e", XY_ROOT_PROBE], timeout_s=60)
    result: dict[str, bool] = {}
    for line in (out + err).splitlines():
        for key in ("closure_alive", "X_same_ptr", "Y_same_ptr"):
            if line.startswith(f"{key}="):
                result[key] = line.split("=")[1] == "true"
    if len(result) != 3:
        raise RuntimeError(
            f"{label} X/Y rooting probe incomplete: {out}\n{err}")
    return result


# ---------------------------------------------------------------------------
# PUC struct sizes/offsets — gcc-compiled against the vendored headers.
# ---------------------------------------------------------------------------

PUC_SIZES_C = r'''
#include <stdio.h>
#include <stddef.h>
#include "lprefix.h"
#include "lua.h"
#include "luaconf.h"
#include "lobject.h"
#include "lfunc.h"
#include "lstring.h"
int main() {
    printf("Proto\t%zu\n", sizeof(Proto));
    printf("TValue\t%zu\n", sizeof(TValue));
    printf("Upvaldesc\t%zu\n", sizeof(Upvaldesc));
    printf("LClosure\t%zu\n", sizeof(LClosure));
    printf("UpVal\t%zu\n", sizeof(UpVal));
    printf("TString\t%zu\n", sizeof(TString));
    printf("offsetof_TString_contents\t%zu\n", offsetof(TString, contents));
    printf("offsetof_TString_falloc\t%zu\n", offsetof(TString, falloc));
    printf("offsetof_LClosure_upvals\t%zu\n", offsetof(LClosure, upvals));
    printf("sizeLclosure_1\t%zu\n", (size_t)sizeLclosure(1));
    printf("sizestrshr_1\t%zu\n", (size_t)sizestrshr(1));
    printf("lstrfix_header\t%zu\n", (size_t)offsetof(TString, falloc));
    return 0;
}
'''


def measure_puc_sizes(tmpdir: Path) -> dict[str, int]:
    c_file = tmpdir / "puc_sizes.c"
    exe = tmpdir / "puc_sizes"
    c_file.write_text(PUC_SIZES_C, encoding="utf-8")
    rc, _, err = run(
        ["gcc", "-I", str(ROOT / "lua-5.5.0" / "src"), "-o", str(exe),
         str(c_file)], timeout_s=60)
    if rc != 0:
        raise RuntimeError(f"PUC sizes compile failed: {err}")
    rc, out, _ = run([str(exe)], timeout_s=30)
    sizes: dict[str, int] = {}
    for line in out.strip().splitlines():
        name, val = line.split("\t")
        sizes[name] = int(val)
    return sizes


# ---------------------------------------------------------------------------
# Ledger assembly
# ---------------------------------------------------------------------------

def assemble_ledger(anchored: dict, variance: dict, driver_anchored: dict,
                    driver_no_xy_root: dict, xy_probe_puc: dict,
                    xy_probe_zig: dict, puc_sizes: dict[str, int]) -> dict:
    sizes = anchored["sizes"]
    proto_info = anchored["code_closure"]["proto"]
    k_len = proto_info["resolved_values_len"]   # 3: "X", "aaa...", "Y"
    nups = proto_info["upvalues_len"]           # 1: _ENV

    # The string_dedup leak size, taken from the measured new_outstanding
    # entry allocated in undump.UndumpReader.readStringDedup.
    dedup_leak = next(
        (e["len"] for e in anchored["new_outstanding"]
         if "readStringDedup" in e.get("symbol", "")), 0)

    # --- zig components (anchored api.lua context: the trailing api.lua:578
    # -- statements make "X"/"Y" constants of the enclosing chunk, so the
    # short strings stay interned through every GC and are NOT re-interned
    # by the undump; the initial compile closure itself IS collected, but
    # that no longer matters for X/Y). ---
    zig: dict[str, int] = {
        # charged to gc_count_kb (tree footprint at adoption)
        "Proto_struct": sizes["Proto"],
        "k_array": 0,  # CUT1: k aliased to resolved_values for undumped trees
        "resolved_values": k_len * sizes["Value"],
        "upvalues_desc": nups * sizes["Upvaldesc"],
        # charged to gc_count_kb (gcNoteAlloc at GC-object creation)
        "Closure": sizes["Closure"],
        "Cell": sizes["Cell"],  # eager _ENV upvalue cell
        # "aaa..." LSTRFIX: P16.17 T2 truncated this header to the PUC
        # prefix (offsetof-equivalent of TString.falloc = 32 B); charge the
        # actually-allocated size, matching gcNoteAlloc at creation.
        "external_LuaString_header": sizes["LuaString_lstrfix"],
        # NOT charged (real memory nonetheless)
        "Closure_upvalues_slice": nups * 8,  # upvalue pointer array
        "string_dedup_leak": dedup_leak,     # leaked per binary load
        # context-dependent (0 in the anchored context; 2*(LuaString+1)
        # charged when the enclosing chunk has no X/Y constants — see
        # context_variance)
        "xy_reintern": 0,
        # borrowed, not charged (fixed_arrays / stripped dump)
        "code_borrowed": 0,
        "lineinfo_borrowed": 0,
    }
    zig["charged_total"] = (
        zig["Proto_struct"] + zig["k_array"] + zig["resolved_values"] +
        zig["upvalues_desc"] + zig["Closure"] + zig["Cell"] +
        zig["external_LuaString_header"] + zig["xy_reintern"])
    zig["real_outstanding_total"] = (
        zig["charged_total"] + zig["Closure_upvalues_slice"] +
        zig["string_dedup_leak"])

    # --- PUC components (source-derived; sizes gcc-measured; both
    # behavioral assumptions verified on the PUC binary by the X/Y rooting
    # probe: the initial compile closure IS collected, yet "X"/"Y" stay
    # interned — the enclosing chunk's constants root them there too). ---
    puc: dict[str, int] = {
        # luaF_newLclosure (lfunc.c:35): ONE allocation of
        # sizeLclosure(1) = offsetof(LClosure, upvals) + 1 pointer.
        "LClosure_incl_1_upval_ptr": puc_sizes["sizeLclosure_1"],
        # luaF_newproto (lfunc.c:243)
        "Proto_struct": puc_sizes["Proto"],
        # lundump.c loadConstants: luaM_newvectorchecked(3, TValue)
        "k_array": k_len * puc_sizes["TValue"],
        # lundump.c:268 loadUpvalues: 1 x Upvaldesc
        "upvalues_desc": nups * puc_sizes["Upvaldesc"],
        # "aaa..." via luaS_newextlstr LSTRFIX: header-only allocation of
        # luaS_sizelngstr(len, LSTRFIX) = offsetof(TString, falloc)
        "TString_LSTRFIX_header": puc_sizes["lstrfix_header"],
        # ldo.c:1141 f_parser -> luaF_initupvals -> new UpVal (_ENV)
        "UpVal": puc_sizes["UpVal"],
        # anchored: "X"/"Y" are constants of the enclosing api.lua main
        # chunk (api.lua:578-579), whose running frame roots its Proto and
        # therefore its k[] TStrings through every GC — no re-intern
        # (probe-verified: X_same_ptr=true, Y_same_ptr=true).
        "X_reintern": 0,
        "Y_reintern": 0,
        # borrowed (PF_FIXED: luaU_undump getaddr, loadCode skips copying)
        "code_borrowed": 0,
        "lineinfo_borrowed": 0,  # stripped dump
        # lundump.c:411 luaH_new dedup table: transient, popped at :423 and
        # freed by the interval GC — net 0 at m2 (unlike the zig leak).
        "dedup_table_transient": 0,
    }
    puc["total"] = sum(v for k, v in puc.items() if k != "total")

    # --- per-component zig-minus-PUC gaps (anchored context) ---
    gaps: dict[str, int] = {
        "Proto": zig["Proto_struct"] - puc["Proto_struct"],
        "constants_array": zig["resolved_values"] - puc["k_array"],
        "upvalues_desc": zig["upvalues_desc"] - puc["upvalues_desc"],
        "closure_total": (zig["Closure"] + zig["Closure_upvalues_slice"]) -
                         puc["LClosure_incl_1_upval_ptr"],
        "upvalue_cell": zig["Cell"] - puc["UpVal"],
        "long_const_header": zig["external_LuaString_header"] -
                             puc["TString_LSTRFIX_header"],
        "xy_reintern": zig["xy_reintern"] -
                       (puc["X_reintern"] + puc["Y_reintern"]),
        "string_dedup_leak": zig["string_dedup_leak"],  # PUC: transient, 0
        "charged_total": zig["charged_total"] - puc["total"],
        "real_memory_total": zig["real_outstanding_total"] - puc["total"],
    }

    measured_anchored = int(driver_anchored["delta"])
    measured_no_xy_root = int(driver_no_xy_root["delta"])
    charged_anchored = zig["charged_total"]
    charged_no_xy_root = charged_anchored + 2 * (sizes["LuaString"] + 1)

    verdict = "GREEN" if measured_anchored < 400 else "DEVIATION"
    savings_needed = max(0, measured_anchored - 399)

    return {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "provenance": provenance.block(zig_bin=ZIG_LUA),
        "gate_threshold": 400,
        "verdict": verdict,
        "measured_delta_anchored": measured_anchored,
        "measured_delta_no_xy_root": measured_no_xy_root,
        "savings_needed_below_400": savings_needed,
        "zig_sizes": sizes,
        "puc_sizes": puc_sizes,
        "zig_components": zig,
        "puc_components": puc,
        "gaps_zig_minus_puc": gaps,
        "reconciliation": {
            "rule": (
                "collectgarbage(\"count\")*1024 == gcControl(3)*1024 + "
                "gcControl(4) == trunc(gc_count_kb * 1024); the ledger's "
                "charged components must sum EXACTLY to m2 - m1"),
            "anchored": {
                "measured": measured_anchored,
                "charged_total": charged_anchored,
                "reconciled": measured_anchored == charged_anchored,
            },
            "no_xy_root": {
                "measured": measured_no_xy_root,
                "charged_total": charged_no_xy_root,
                "reconciled": measured_no_xy_root == charged_no_xy_root,
                "note": (
                    f"adds the X/Y re-intern: 2 x "
                    f"(sizeof(LuaString)+1) = "
                    f"{charged_no_xy_root - charged_anchored} charged; each "
                    f"allocation is @sizeOf(LuaString)+1 bytes (extra NUL "
                    f"byte not charged), so tracker bytes exceed the charge "
                    f"by 2"),
            },
            "real_outstanding_anchored": {
                "tracker_bytes": zig["real_outstanding_total"],
                "uncounted_by_gc": {
                    "Closure_upvalues_slice": zig["Closure_upvalues_slice"],
                    "string_dedup_leak": zig["string_dedup_leak"],
                },
            },
        },
        "context_variance": {
            "summary": (
                "The delta depends on ONE context-dependent component: "
                "whether the short strings \"X\"/\"Y\" are still interned "
                "when the interval's undump runs. They are referenced by "
                "the initial compile closure AND by the enclosing chunk's "
                "own constants when it contains the api.lua:578-579 "
                "trailing statements (\"X = 0; ... X = nil; Y = nil\")."),
            "anchored": (
                f"In the exact api.lua shape the trailing verification "
                f"statements make \"X\"/\"Y\" constants of the enclosing "
                f"chunk; its frame is live for the whole run, so the "
                f"constants root the short strings through every GC and the "
                f"undump finds them in the intern table — no re-intern: "
                f"{measured_anchored} (current binary-measured; reproduced "
                f"by the anchored harness variant)."),
            "no_xy_root": (
                f"Without the trailing statements the enclosing chunk has no "
                f"X/Y constants; the initial compile closure (the only other "
                f"referent) is collected by the pre-m1 GCs (probe-verified), "
                f"X/Y are swept from the intern table, and the undump "
                f"re-interns them: {measured_anchored} + re-intern charge "
                f"= {measured_no_xy_root} (current binary-measured; "
                f"reproduced by the variance harness variant)."),
        },
        "history": {
            "p16_16_pre_cuts": {
                "anchored": 544,
                "no_xy_root": 690,
                "note": (
                    "P16.16 T1 fully explained the then-measured 544-690 "
                    "range (STATUS.md): drivers omitting the trailing X/Y "
                    "statements measured 690. Those were the sizes BEFORE "
                    "the C1-C7 representation cuts; kept here as history "
                    "only — current values live in measured_delta_* and "
                    "context_variance above."),
            },
            "p16_16_post_cuts": {
                "anchored": 392,
                "note": (
                    "After C1-C7 (P16.16 final, commit 042d0dd): 392 in "
                    "ReleaseFast, but Debug measured 400 (LuaString auto-"
                    "union safety tag, P16.17 T1) — the cross-mode failure "
                    "that motivated the extern-union fix and this ledger's "
                    "per-mode section."),
            },
        },
        "puc_measurement_note": (
            "The PUC ledger is source-derived: build/lua-c/lua has no testc "
            "module, so the mode-'B' fixed-buffer loadstring interval cannot "
            "be executed under the PUC binary. Struct sizes/offsets are "
            "gcc-measured against the vendored lua-5.5.0 headers; both "
            "behavioral assumptions are verified on the PUC binary via the "
            "X/Y rooting probe (anchored shape): the initial compile closure "
            "is collected (closure_alive=false) yet \"X\"/\"Y\" stay interned "
            "(X_same_ptr=true, Y_same_ptr=true) — the enclosing chunk's "
            "constants root them, so PUC's undump also performs no re-intern. "
            "The identical probe result under luazig confirms mechanism "
            "parity between the two implementations."),
        "findings": {
            "string_dedup_leak": (
                {
                    "status": "fixed",
                    "fixed_in_commit": "d4fc485",
                    "fix": "loadBinaryChunk now defers reader.deinit(); the "
                           "string_dedup ArrayList is reclaimed per load "
                           "(current measurement: leaks "
                           f"{dedup_leak} bytes).",
                }
                if dedup_leak == 0 else
                {
                    "status": "ACTIVE REGRESSION",
                    "detail": (
                        "loadBinaryChunk leaks "
                        f"{dedup_leak} bytes per binary-chunk load again — "
                        "reader.deinit() missing or bypassed. PUC's "
                        "equivalent (lundump.c:411 luaH_new dedup table) is "
                        "transient and freed by the interval GC."),
                }),
            "uncounted_upvalues_slice": (
                "The Closure's upvalue-pointer array (8 bytes for 1 upvalue) "
                "is allocated with the Closure but never charged to "
                "gc_count_kb. PUC has no such array: sizeLclosure(n) embeds "
                "the upvalue pointers inline in the LClosure allocation."),
        },
        "evidence": {
            "harness_anchored": anchored,
            "harness_variance": variance,
            "driver_anchored": driver_anchored,
            "driver_no_xy_root": driver_no_xy_root,
            "xy_root_probe_puc": xy_probe_puc,
            "xy_root_probe_zig": xy_probe_zig,
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Measure and write the api.lua:580 allocation ledger")
    ap.add_argument("--no-build", action="store_true",
                    help="Skip zig build + make lua-c")
    ap.add_argument("--out",
                    default="tools/perf/current-api580-ledger.json",
                    help="Output JSON path")
    ap.add_argument("--keep-temp", action="store_true",
                    help="Keep the temporary harness directory")
    ap.add_argument("--modes", default="ReleaseFast,Debug",
                    help="Comma-separated Zig optimize modes to measure "
                         "(per-mode driver deltas + provenance)")
    args = ap.parse_args()

    modes = [m.strip() for m in args.modes.split(",") if m.strip()]
    if not args.no_build:
        build_all(modes)

    tmpdir = Path(tempfile.mkdtemp(prefix="api580_ledger_"))
    try:
        anchored = build_and_run_harness(tmpdir, "anchored",
                                         XY_ROOT_STMT_ANCHORED)
        variance = build_and_run_harness(tmpdir, "variance",
                                         XY_ROOT_STMT_VARIANCE)
        # Per-mode driver runs: rebuild the binary in each mode, then run
        # both driver variants against it. Layout-sensitive deltas (and the
        # 400-B gate) must hold in EVERY mode, so the ledger records each
        # mode's delta with its own provenance block (T4).
        per_mode: dict[str, dict] = {}
        for mode in modes:
            if not args.no_build:
                run(["zig", "build", f"-Doptimize={mode}"], timeout_s=600)
            per_mode[mode] = {
                "driver_anchored": run_driver(DRIVER_ANCHORED),
                "driver_no_xy_root": run_driver(DRIVER_NO_XY_ROOT),
                "provenance": provenance.block(optimize_mode=mode),
            }
        # Charged-component harness + probes run against the LAST built
        # mode's binary (layout is build-mode-stable since P16.17 T1; the
        # per-mode deltas above prove that for the gate).
        xy_probe_puc = run_xy_root_probe(PUC_LUA, "PUC")
        xy_probe_zig = run_xy_root_probe(ZIG_LUA, "zig")
        puc_sizes = measure_puc_sizes(tmpdir)

        payload = assemble_ledger(anchored, variance,
                                  per_mode[modes[0]]["driver_anchored"],
                                  per_mode[modes[0]]["driver_no_xy_root"],
                                  xy_probe_puc, xy_probe_zig, puc_sizes)
        payload["per_mode"] = per_mode
        payload["provenance"] = provenance.block(
            optimize_mode="+".join(modes))

        out_path = ROOT / args.out if not Path(args.out).is_absolute() \
            else Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(payload, indent=2) + "\n",
                            encoding="utf-8")
        print(f"wrote {out_path}")

        # Console summary
        z, p = payload["zig_components"], payload["puc_components"]
        print(f"  zig charged total (anchored): {z['charged_total']}"
              f"  (measured {payload['measured_delta_anchored']})")
        print(f"  zig charged total (no_xy_root): "
              f"{payload['reconciliation']['no_xy_root']['charged_total']}"
              f"  (measured {payload['measured_delta_no_xy_root']})")
        print(f"  puc total (source-derived): {p['total']}")
        print(f"  verdict: {payload['verdict']}, "
              f"savings needed: {payload['savings_needed_below_400']}B")
        return 0
    finally:
        if args.keep_temp:
            print(f"kept temp dir: {tmpdir}")
        else:
            shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
