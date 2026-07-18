#!/usr/bin/env python3
"""
perf_compare.py — reproducible perf gate for luazig.

Builds luazig (ReleaseFast) and PUC Lua reference, then runs
tools/microbench.lua under both binaries with median-of-N sampling
on a pinned CPU core. Compares Zig/PUC ratios and checks for
regressions against a versioned baseline JSON.

Usage:
  perf_compare.py                    # run + compare vs baseline
  perf_compare.py --update-baseline  # rewrite baseline JSON with current results
  perf_compare.py --perf             # also run perf stat on a representative workload
  perf_compare.py --runs N           # override number of median runs (default 7)
  perf_compare.py --no-build         # skip zig build + make lua-c (use existing)
"""
from __future__ import annotations

import argparse
import json
import math
import platform
import statistics
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parents[1]
ZIG_LUA = ROOT / "zig-out" / "bin" / "luazig"
PUC_LUA = ROOT / "build" / "lua-c" / "lua"
BENCH = ROOT / "tools" / "microbench.lua"
BASELINE = ROOT / "tools" / "perf" / "baseline-p15.37.json"

# Pin to a single CPU core to reduce scheduler noise. Core 0 is a safe default
# on most setups; if it is busy the user can override via --core.
DEFAULT_CORE = "0"
DEFAULT_RUNS = 7
BENCH_TIMEOUT_S = 600  # microbench must finish in under 10 min per run

# Regression thresholds (fraction). WARN at +5%, FAIL at +10%.
REGRESSION_WARN = 0.05
REGRESSION_FAIL = 0.10

# Representative workload for `--perf`: a tight integer loop that exercises
# the VM core (arith + branch + loop) without allocating.
PERF_WORKLOAD = (
    "local N=50000000 local g_count=0 "
    'for i=1,N do g_count=g_count+i end io.write(g_count.."\\n")'
)


# ---------------------------------------------------------------------------
# Build helpers
# ---------------------------------------------------------------------------

def build_all() -> None:
    """Build luazig in ReleaseFast and PUC Lua reference."""
    print(">> zig build -Doptimize=ReleaseFast")
    subprocess.check_call(["zig", "build", "-Doptimize=ReleaseFast"], cwd=ROOT)
    print(">> make -s lua-c")
    subprocess.check_call(["make", "-s", "lua-c"], cwd=ROOT)


def ensure_built() -> None:
    if not ZIG_LUA.exists():
        raise SystemExit(f"missing {ZIG_LUA}; run without --no-build first")
    if not PUC_LUA.exists():
        raise SystemExit(f"missing {PUC_LUA}; run without --no-build first")


# ---------------------------------------------------------------------------
# Microbench runner
# ---------------------------------------------------------------------------

def run_bench(lua_bin: Path, core: str) -> Dict[str, float]:
    """Run microbench once and parse `name\\tseconds` lines."""
    out = subprocess.check_output(
        ["taskset", "-c", core, str(lua_bin), str(BENCH)],
        text=True,
        timeout=BENCH_TIMEOUT_S,
    )
    result: Dict[str, float] = {}
    for line in out.splitlines():
        if "\t" not in line or line.startswith("done"):
            continue
        name, _, sec = line.partition("\t")
        name = name.strip()
        try:
            result[name] = float(sec)
        except ValueError:
            continue
    return result


def median_runs(lua_bin: Path, n: int, core: str, label: str) -> Dict[str, float]:
    """Run microbench n times and take the median per workload."""
    runs: list[Dict[str, float]] = []
    for i in range(n):
        t0 = time.perf_counter()
        runs.append(run_bench(lua_bin, core))
        print(f"  {label} run {i + 1}/{n}: {time.perf_counter() - t0:.1f}s")
    # Workloads present in every run (intersection).
    names = set(runs[0]).intersection(*runs[1:])
    return {name: statistics.median(r[name] for r in runs) for name in names}


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def print_table(zig: Dict[str, float], puc: Dict[str, float]) -> None:
    names = sorted(set(zig) | set(puc))
    print(f"\n{'Workload':<22} {'PUC (s)':>10} {'Zig (s)':>10} {'Zig/PUC':>10}")
    print("-" * 56)
    ratios = []
    for name in names:
        if name in zig and name in puc:
            ratio = zig[name] / puc[name] if puc[name] else 0.0
            ratios.append(ratio)
            print(f"{name:<22} {puc[name]:>10.3f} {zig[name]:>10.3f} {ratio:>9.2f}x")
        elif name in zig:
            print(f"{name:<22} {'--':>10} {zig[name]:>10.3f} {'--':>10}")
        else:
            print(f"{name:<22} {puc[name]:>10.3f} {'--':>10} {'--':>10}")
    if ratios:
        # Geomean: exp(mean(log(ratio)))
        geomean = math.exp(sum(math.log(r) for r in ratios) / len(ratios))
        print("-" * 56)
        print(f"{'geomean':<22} {'':>10} {'':>10} {geomean:>9.2f}x")


def regression_check(zig: Dict[str, float], baseline: dict) -> tuple[bool, bool]:
    """Compare current zig times vs baseline. Returns (any_warn, any_fail)."""
    prev_zig = baseline.get("zig", {})
    print(f"\nRegression check vs {BASELINE}:")
    print(f"  {'Workload':<22} {'base (s)':>10} {'cur (s)':>10} {'delta':>10}  status")
    print("  " + "-" * 52)
    any_warn = False
    any_fail = False
    for name in sorted(zig):
        old = prev_zig.get(name)
        if old is None:
            print(f"  {name:<22} {'--':>10} {zig[name]:>10.3f} {'--':>10}  NEW")
            continue
        delta = (zig[name] - old) / old if old else 0.0
        tag = "OK"
        if delta > REGRESSION_FAIL:
            tag = "FAIL"
            any_fail = True
        elif delta > REGRESSION_WARN:
            tag = "WARN"
            any_warn = True
        print(f"  {name:<22} {old:>10.3f} {zig[name]:>10.3f} {delta * 100:>+9.1f}%  {tag}")
    return any_warn, any_fail


# ---------------------------------------------------------------------------
# perf stat
# ---------------------------------------------------------------------------

def run_perf_stat(zig_bin: Path, core: str) -> None:
    """Run perf stat on a representative workload to surface microarch events."""
    print("\n>> perf stat on representative workload (int loop):", flush=True)
    # perf stat writes its report to stderr; let it stream directly to the terminal.
    subprocess.run([
        "perf", "stat",
        "-e", "cycles:u,instructions:u,branch-misses:u,cache-misses:u",
        "taskset", "-c", core,
        str(zig_bin), "-e", PERF_WORKLOAD,
    ], check=False)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--update-baseline", action="store_true",
                    help="rewrite baseline JSON with current results")
    ap.add_argument("--perf", action="store_true",
                    help="also run perf stat on a representative workload")
    ap.add_argument("--runs", type=int, default=DEFAULT_RUNS,
                    help=f"number of median runs (default {DEFAULT_RUNS})")
    ap.add_argument("--core", default=DEFAULT_CORE,
                    help=f"CPU core to pin via taskset (default {DEFAULT_CORE})")
    ap.add_argument("--no-build", action="store_true",
                    help="skip zig build + make lua-c (use existing binaries)")
    args = ap.parse_args()

    if args.runs < 1:
        ap.error("--runs must be >= 1")

    if not args.no_build:
        build_all()
    else:
        ensure_built()

    print(f"\n>> {args.runs} median runs each, pinned to core {args.core}")
    print(f">> zig: {ZIG_LUA}")
    print(f">> puc: {PUC_LUA}")
    zig = median_runs(ZIG_LUA, args.runs, args.core, "zig")
    puc = median_runs(PUC_LUA, args.runs, args.core, "puc")

    print_table(zig, puc)

    if args.perf:
        run_perf_stat(ZIG_LUA, args.core)

    current = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "host": {
            "platform": platform.platform(),
            "python": platform.python_version(),
        },
        "runs": args.runs,
        "core": args.core,
        "zig": zig,
        "puc": puc,
        "ratios": {n: zig[n] / puc[n] for n in zig if n in puc and puc[n]},
    }

    if args.update_baseline:
        BASELINE.parent.mkdir(parents=True, exist_ok=True)
        BASELINE.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
        print(f"\nBaseline updated: {BASELINE}")
        return 0

    if BASELINE.exists():
        prev = json.loads(BASELINE.read_text(encoding="utf-8"))
        any_warn, any_fail = regression_check(zig, prev)
        if any_fail:
            print("\nRESULT: FAIL (regression > 10% on one or more workloads)")
            return 1
        if any_warn:
            print("\nRESULT: WARN (regression > 5% on one or more workloads)")
        else:
            print("\nRESULT: OK (no regressions)")
        return 0

    print(f"\nNo baseline at {BASELINE}; run with --update-baseline to create one.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
