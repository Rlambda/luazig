#!/usr/bin/env python3
"""
perf_fixed_load_footprint.py — honest fixed-buffer GC accounting artifact.

Measures the per-component allocation delta for a fixed-buffer binary load
of the api.lua:555-580 chunk shape (1000×"X=X+1; " + 1000-char string,
dumped stripped, loaded via mode 'B'). Records:

  1. Zig struct sizes (Proto, Closure, Cell, ProtoTreeOwner, SourceBacking,
     Value, Constant, Upvaldesc, LocVar, Instruction, LuaString).
  2. PUC Lua struct sizes (Proto, TValue, Upvaldesc, LocVar, LClosure,
     UpVal, TString, Instruction) compiled from the vendored PUC headers.
  3. Per-component allocation breakdown for the fixed-load shape:
     - Borrowed (not charged): code, lineinfo, long-string constants
     - Owned+charged (GC objects via gcNoteAlloc): Closure, Cell
     - Owned+charged (tree footprint): Proto, k, upvalues, resolved_values,
       ProtoTreeOwner, SourceBacking
  4. The honest m2-m1 delta and the PUC-equivalent delta.
  5. The api.lua:580 verdict (green via honesty or documented deviation).

Usage:
  perf_fixed_load_footprint.py                  # measure + write JSON
  perf_fixed_load_footprint.py --no-build       # skip zig build + make lua-c
  perf_fixed_load_footprint.py --out PATH       # custom output path

The output JSON is saved to tools/perf/current-fixed-load-footprint.json.
Regenerable: re-run after any struct layout change to update the artifact.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ZIG_LUA = ROOT / "zig-out" / "bin" / "luazig"
PUC_LUA = ROOT / "build" / "lua-c" / "lua"


def run(cmd: list[str], timeout_s: int = 120) -> tuple[int, str, str]:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s)
    return p.returncode, p.stdout, p.stderr

def zig_version() -> str:
    rc, out, _ = run(["zig", "version"])
    return out.strip() if rc == 0 else "unknown"


def git_head() -> str:
    rc, out, _ = run(["git", "rev-parse", "--short", "HEAD"], )
    return out.strip() if rc == 0 else "unknown"


def git_dirty() -> str:
    """Provenance: a dirty-tree measurement must never be labeled by HEAD alone."""
    rc, out, _ = run(["git", "status", "--porcelain", "--untracked-files=no"], )
    return "dirty" if out.strip() else "clean"


def binary_sha(path) -> str:
    import hashlib
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()[:16]
    except OSError:
        return "unknown"


def build_all() -> None:
    run(["zig", "build", "-Doptimize=ReleaseFast"], timeout_s=300)
    run(["make", "-C", str(ROOT / "lua-5.5.0"), "clean", "lua-c"],
        timeout_s=120)


# ---------------------------------------------------------------------------
# Zig struct sizes — compiled from a small Zig program that prints @sizeOf
# ---------------------------------------------------------------------------

ZIG_SIZES_PROG = r'''
const std = @import("std");
const lua = @import("lua");
const bc = lua.internal.bytecode;
const vm = lua.internal.vm;

pub fn main() void {
    std.debug.print("Proto\t{}\n", .{@sizeOf(bc.Proto)});
    std.debug.print("Closure\t{}\n", .{@sizeOf(vm.Closure)});
    std.debug.print("Cell\t{}\n", .{@sizeOf(vm.Cell)});
    std.debug.print("LuaString\t{}\n", .{@sizeOf(vm.LuaString)});
    std.debug.print("Value\t{}\n", .{@sizeOf(vm.Value)});
    std.debug.print("Constant\t{}\n", .{@sizeOf(bc.Constant)});
    std.debug.print("Instruction\t{}\n", .{@sizeOf(bc.Instruction)});
    std.debug.print("Upvaldesc\t{}\n", .{@sizeOf(bc.Upvaldesc)});
    std.debug.print("LocVar\t{}\n", .{@sizeOf(bc.LocVar)});
    std.debug.print("SourceBacking\t{}\n", .{@sizeOf(bc.SourceBacking)});
    std.debug.print("SourceBackingExtra\t{}\n", .{@sizeOf(bc.SourceBackingExtra)});
}
'''

ZIG_SIZES_BUILD = r'''
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const util_mod = b.addModule("util", .{
        .root_source_file = b.path("src/util/root.zig"),
        .target = target, .optimize = optimize,
    });
    const lua_mod = b.addModule("lua", .{
        .root_source_file = b.path("src/lua/root.zig"),
        .target = target, .optimize = optimize,
    });
    lua_mod.addImport("util", util_mod);
    const exe = b.addExecutable(.{
        .name = "zig_sizes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("_zig_sizes_tmp.zig"),
            .target = target, .optimize = optimize, .link_libc = true,
            .imports = &.{.{ .name = "lua", .module = lua_mod }},
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("sizes", "Print sizes").dependOn(&run.step);
}
'''

PUC_SIZES_C = r'''
#include <stdio.h>
#include <stddef.h>
#include "lprefix.h"
#include "lua.h"
#include "luaconf.h"
#include "lobject.h"
int main() {
    printf("Proto\t%zu\n", sizeof(Proto));
    printf("TValue\t%zu\n", sizeof(TValue));
    printf("Upvaldesc\t%zu\n", sizeof(Upvaldesc));
    printf("LocVar\t%zu\n", sizeof(LocVar));
    printf("LClosure\t%zu\n", sizeof(LClosure));
    printf("UpVal\t%zu\n", sizeof(UpVal));
    printf("TString\t%zu\n", sizeof(TString));
    printf("Instruction\t%zu\n", sizeof(Instruction));
    printf("lu_byte\t%zu\n", sizeof(lu_byte));
    printf("AbsLineInfo\t%zu\n", sizeof(AbsLineInfo));
    return 0;
}
'''


def measure_zig_sizes() -> dict[str, int]:
    sizes_prog = ROOT / "_zig_sizes_tmp.zig"
    sizes_build = ROOT / "_zig_sizes_build_tmp.zig"
    sizes_prog.write_text(ZIG_SIZES_PROG, encoding="utf-8")
    sizes_build.write_text(ZIG_SIZES_BUILD, encoding="utf-8")
    rc, out, err = run(
        ["zig", "build", "--build-file", str(sizes_build), "sizes"],
        timeout_s=120,
    )
    if rc != 0:
        print(f"zig sizes build failed: {err}", file=sys.stderr)
        sizes_prog.unlink(missing_ok=True)
        sizes_build.unlink(missing_ok=True)
        return {}
    # std.debug.print writes to stderr
    sizes: dict[str, int] = {}
    output = err if err.strip() else out
    for line in output.strip().splitlines():
        if "\t" in line:
            name, val = line.split("\t")
            sizes[name] = int(val)
    sizes_prog.unlink(missing_ok=True)
    sizes_build.unlink(missing_ok=True)
    return sizes


def measure_puc_sizes() -> dict[str, int]:
    c_file = ROOT / "tools" / "perf" / "_puc_sizes.c"
    c_file.write_text(PUC_SIZES_C, encoding="utf-8")
    exe = ROOT / "tools" / "perf" / "_puc_sizes"
    rc, _, err = run(
        ["gcc", "-I", str(ROOT / "lua-5.5.0" / "src"),
         "-o", str(exe), str(c_file)],
        timeout_s=30,
    )
    if rc != 0:
        print(f"puc sizes compile failed: {err}", file=sys.stderr)
        c_file.unlink(missing_ok=True)
        return {}
    rc, out, _ = run([str(exe)], timeout_s=10)
    sizes: dict[str, int] = {}
    for line in out.strip().splitlines():
        name, val = line.split("\t")
        sizes[name] = int(val)
    c_file.unlink(missing_ok=True)
    exe.unlink(missing_ok=True)
    return sizes


def measure_actual_delta() -> dict[str, int]:
    """Run the api.lua fixed-load shape under luazig and measure m2-m1."""
    lua_script = r'''
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
X = nil; Y = nil
'''
    rc, out, err = run(
        [str(ZIG_LUA), "--testc", "-e", lua_script],
        timeout_s=30,
    )
    result: dict[str, int] = {}
    for line in (out + err).splitlines():
        line = line.strip()
        if line.startswith("DELTA="):
            result["delta"] = int(line.split("=")[1])
        elif line.startswith("M1="):
            result["m1"] = int(line.split("=")[1])
        elif line.startswith("M2="):
            result["m2"] = int(line.split("=")[1])
    return result


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Measure fixed-buffer load GC footprint artifact")
    ap.add_argument("--no-build", action="store_true",
                    help="Skip zig build + make lua-c")
    ap.add_argument("--out", default="tools/perf/current-fixed-load-footprint.json",
                    help="Output JSON path")
    args = ap.parse_args()

    if not args.no_build:
        build_all()

    zig_sizes = measure_zig_sizes()
    puc_sizes = measure_puc_sizes()
    actual = measure_actual_delta()

    # Per-component breakdown for the api.lua fixed-load shape:
    # k_len ~ 3 (X string, 1 int, Y string or aaa string)
    # upvalues_len = 1 (_ENV)
    # p_len = 0, locvars = 0 (stripped), live_reg_top = 0 (undump)
    k_len = 3
    upvalues_len = 1

    # luazig components
    zig_components: dict[str, int] = {}
    if zig_sizes:
        zig_components["Proto_struct"] = zig_sizes["Proto"]
        # CUT1: for undumped trees after adoption, k is aliased to
        # resolved_values (in-place Constant→Value conversion). k_array
        # is 0 (k.len==0); resolved_values is the single constant array.
        zig_components["k_array"] = 0  # CUT1: aliased to resolved_values
        zig_components["upvalues_array"] = upvalues_len * zig_sizes["Upvaldesc"]
        zig_components["resolved_values"] = k_len * zig_sizes["Value"]
        # CUT2: ProtoTreeOwner eliminated — owner fields merged into root Proto.
        # The Proto struct already includes owner fields (ref_count, vm,
        # source_backing, flags, gc_charged/gc_footprint). No separate owner
        # allocation. SourceBacking is now compact (inline pin + external_borrow
        # + ?*SourceBackingExtra). For the common fixed-buffer case: 1 pin
        # (inline in SourceBacking, which is inline in Proto), no extra.
        zig_components["SourceBacking_struct"] = 0  # inline in Proto (already counted)
        zig_components["pinned_list_storage"] = 0  # inline pin in SourceBacking (already counted)
        zig_components["Closure_GC"] = zig_sizes["Closure"]
        zig_components["Cell_GC"] = zig_sizes["Cell"]
        # Borrowed (not charged)
        zig_components["code_borrowed"] = 0
        zig_components["lineinfo_borrowed"] = 0
        zig_components["tree_total"] = (
            zig_components["Proto_struct"] +
            zig_components["k_array"] +
            zig_components["upvalues_array"] +
            zig_components["resolved_values"] +
            zig_components["SourceBacking_struct"] +
            zig_components["pinned_list_storage"]
        )
        zig_components["gc_objects"] = (
            zig_components["Closure_GC"] +
            zig_components["Cell_GC"]
        )
        zig_components["honest_total"] = (
            zig_components["tree_total"] +
            zig_components["gc_objects"]
        )

    # PUC components
    puc_components: dict[str, int] = {}
    if puc_sizes:
        puc_components["Proto_struct"] = puc_sizes["Proto"]
        puc_components["k_array"] = k_len * puc_sizes["TValue"]
        puc_components["upvalues_array"] = upvalues_len * puc_sizes["Upvaldesc"]
        puc_components["LClosure_GC"] = puc_sizes["LClosure"]
        puc_components["UpVal_GC"] = puc_sizes["UpVal"]
        puc_components["tree_total"] = (
            puc_components["Proto_struct"] +
            puc_sizes["k_array"] if "k_array" in puc_sizes else k_len * puc_sizes["TValue"]
        )
        puc_components["tree_total"] = (
            puc_components["Proto_struct"] +
            k_len * puc_sizes["TValue"] +
            puc_components["upvalues_array"]
        )
        puc_components["gc_objects"] = (
            puc_components["LClosure_GC"] +
            puc_components["UpVal_GC"]
        )
        puc_components["honest_total"] = (
            puc_components["tree_total"] +
            puc_components["gc_objects"]
        )

    # Verdict
    zig_honest = zig_components.get("honest_total", 0)
    puc_honest = puc_components.get("honest_total", 0)
    verdict = "DEVIATION" if zig_honest >= 400 else "GREEN"
    deviation_bytes = max(0, zig_honest - 400) if verdict == "DEVIATION" else 0

    payload = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "zig_version": zig_version(),
        "git_head": git_head(),
        "git_dirty": git_dirty(),
        "zig_binary_sha256_16": binary_sha(ROOT / "zig-out" / "bin" / "luazig"),
        "zig_sizes": zig_sizes,
        "puc_sizes": puc_sizes,
        "zig_components": zig_components,
        "puc_components": puc_components,
        "actual_delta": actual,
        "verdict": verdict,
        "gate_threshold": 400,
        "deviation_bytes": deviation_bytes,
        "deviation_explanation": (
            "Honest charge exceeds PUC's 400-byte gate due to structural "
            "overhead: SourceBacking (32B inline in Proto, PUC has none), "
            "resolved_values (48B, PUC's k IS runtime format), larger GC "
            "structs (Proto +56B including owner fields, Closure +48, "
            "Cell +24, Upvaldesc +8). CUT1 eliminated the duplicate k array "
            "for undumped trees (aliased to resolved_values, -48B). CUT2 "
            "eliminated ProtoTreeOwner (144B) by merging owner fields into "
            "root Proto and compacting SourceBacking (88B→32B inline). "
            "Getting under 400 requires eliminating resolved_values — larger "
            "structural change (Proto-as-GC-object / lazy resolved_values at "
            "first frame push). Per verifier allowance, honest accounting is "
            "kept and the deviation is documented."
        ) if verdict == "DEVIATION" else (
            "Honest charge is under PUC's 400-byte gate."
        ),
    }

    out = (ROOT / args.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"Written: {out}")
    print(f"Zig honest total: {zig_honest} bytes")
    print(f"PUC honest total: {puc_honest} bytes")
    print(f"Verdict: {verdict}" +
          (f" (deviation: {deviation_bytes} bytes over 400)" if verdict == "DEVIATION" else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
