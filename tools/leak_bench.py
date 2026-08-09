#!/usr/bin/env python3
"""
leak_bench.py — reproducible leak gate for luazig.

Builds luazig (ReleaseFast) and PUC Lua reference, then runs
tools/leakbench.lua under both binaries. Compares leaked KB
per workload and highlights significant leaks.

Usage:
  leak_bench.py                # run + compare luazig vs PUC
  leak_bench.py --no-build     # skip zig build + make lua-c
  leak_bench.py --threshold 2  # FAIL if leaked > 2 KB (default: 1)
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ZIG_LUA = ROOT / "zig-out" / "bin" / "luazig"
PUC_LUA = ROOT / "build" / "lua-c" / "lua"
BENCH = ROOT / "tools" / "leakbench.lua"

DEFAULT_THRESHOLD = 1.0  # KB


def run_bench(binary: Path, label: str) -> dict[str, float]:
    """Run leakbench.lua under `binary`, return {test_name: leaked_kb}."""
    result = subprocess.run(
        [str(binary), str(BENCH)],
        capture_output=True, text=True, timeout=120, cwd=str(ROOT),
    )
    leaks: dict[str, float] = {}
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 6:
            continue
        name = parts[0].strip()
        try:
            leaked = float(parts[4])
        except ValueError:
            continue
        leaks[name] = leaked
    return leaks


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--no-build", action="store_true", help="skip build step")
    ap.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD,
                    help=f"FAIL threshold in KB (default: {DEFAULT_THRESHOLD})")
    args = ap.parse_args()

    if not args.no_build:
        print(">> zig build -Doptimize=ReleaseFast")
        subprocess.run(["zig", "build", "-Doptimize=ReleaseFast"], check=True, cwd=str(ROOT))
        print(">> make lua-c")
        lua_dir = ROOT / "lua-5.5.0"
        subprocess.run(["make", "-s", "lua-c"], check=True, cwd=str(lua_dir))

    print(f">> zig: {ZIG_LUA}")
    print(f">> puc: {PUC_LUA}")
    print()

    zig_leaks = run_bench(ZIG_LUA, "zig")
    puc_leaks = run_bench(PUC_LUA, "puc")

    # Print comparison table
    print(f"{'Workload':<25} {'Zig (KB)':>10} {'PUC (KB)':>10} {'Delta':>10}  Status")
    print("-" * 72)

    fails = 0
    all_names = sorted(set(list(zig_leaks.keys()) + list(puc_leaks.keys())))
    for name in all_names:
        z = zig_leaks.get(name, 0.0)
        p = puc_leaks.get(name, 0.0)
        delta = z - p
        status = "OK"
        if z > args.threshold:
            status = "LEAK"
            fails += 1
        print(f"{name:<25} {z:>10.1f} {p:>10.1f} {delta:>10.1f}  {status}")

    print("-" * 72)
    if fails > 0:
        print(f"RESULT: FAIL ({fails} workloads leaked > {args.threshold} KB)")
        return 1
    else:
        print(f"RESULT: PASS (all workloads within {args.threshold} KB)")
        return 0


if __name__ == "__main__":
    sys.exit(main())
