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
  perf_compare.py --counters         # per-workload hardware counters mode (B1)
"""
from __future__ import annotations

import argparse
import json
import math
import platform
import statistics
import subprocess
import tempfile
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
# Per-workload hardware counters (`--counters`, P16.0c)
# ---------------------------------------------------------------------------

# The 16 microbench workloads (must match the bench() labels in
# tools/microbench.lua; a mismatch fails loudly at run time because the
# expected `name\tseconds` line will be missing from the bench output).
WORKLOADS = [
    "int_arith", "global_arith", "branch_loop", "lua_calls",
    "array_access", "hash_access", "temp_table_alloc", "string_loop",
    "coroutine_yield", "dynamic_load", "mixed_arith", "float_arith",
    "string_concat", "metamethod_add", "field_access", "comparisons",
]

# Userspace-only events so this works with perf_event_paranoid=2.
# `-j` makes perf stat emit one JSON object per line on stderr:
#   {"counter-value" : "290234.000000", "event" : "cpu_core/cycles/u", ...}
# On hybrid CPUs (e.g. i7-13700H) every event appears twice — cpu_core and
# cpu_atom. When the workload is taskset-pinned to a P-core the cpu_atom rows
# read "<not counted>", so we skip those rows and the cpu_atom PMU entirely.
COUNTER_EVENTS = "cycles:u,instructions:u,branches:u,branch-misses:u,cache-misses:u,cache-references:u"

DEFAULT_COUNTERS_RUNS = 3

# Intermediate-python helper for exact per-workload max-RSS.
#
# getrusage(RUSAGE_CHILDREN).ru_maxrss is the MAX over all children reaped so
# far, which is useless in the parent process after a dozen bench runs. Instead
# we spawn a fresh `python3 -c` whose ONLY child is the (taskset→exec) bench
# process, so its own RUSAGE_CHILDREN is exact for that one workload.
# ru_maxrss is KB on Linux; ru_utime/ru_stime are seconds.
_RSS_HELPER = (
    "import json,resource,subprocess,sys\n"
    "subprocess.run(sys.argv[1:],stdout=subprocess.DEVNULL,check=True)\n"
    "r=resource.getrusage(resource.RUSAGE_CHILDREN)\n"
    "print(json.dumps({'maxrss_kb':r.ru_maxrss,'utime':r.ru_utime,'stime':r.ru_stime}))\n"
)


def normalize_event(ev: str) -> str:
    """'cpu_core/cycles/u' -> 'cycles'; plain 'cycles' stays 'cycles'."""
    parts = ev.split("/")
    return parts[1] if len(parts) == 3 else ev


def parse_perf_stat_json(text: str) -> Dict[str, float]:
    """Parse `perf stat -j` JSON-lines into {event_name: value}.

    Skips "<not counted>" rows and cpu_atom rows (hybrid CPU: the run is
    pinned to a P-core, so atom rows carry no data).
    """
    counters: Dict[str, float] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        value = str(rec.get("counter-value", ""))
        event = str(rec.get("event", ""))
        if value.startswith("<"):  # "<not counted>" / "<not supported>"
            continue
        if event.startswith("cpu_atom"):
            continue
        try:
            counters[normalize_event(event)] = float(value)
        except ValueError:
            continue
    return counters


def perf_stat_workload(lua_bin: Path, workload: str, core: str, runs: int) -> Dict[str, float]:
    """Median hardware counters for one workload under one binary.

    Each run: taskset -c CORE perf stat -j -e EVENTS BIN microbench.lua WL.
    The expected `WL\tseconds` line in the bench stdout doubles as validation
    that the workload name is correct.
    """
    per_counter: Dict[str, list[float]] = {}
    for _ in range(runs):
        proc = subprocess.run(
            ["taskset", "-c", core, "perf", "stat", "-j", "-e", COUNTER_EVENTS,
             str(lua_bin), str(BENCH), workload],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            timeout=BENCH_TIMEOUT_S, check=True,
        )
        if f"{workload}\t" not in proc.stdout:
            raise SystemExit(
                f"workload '{workload}' produced no bench output under {lua_bin}; "
                f"check the label against tools/microbench.lua"
            )
        counters = parse_perf_stat_json(proc.stderr)
        if not counters:
            raise SystemExit(f"perf stat -j produced no parseable counters for {workload}/{lua_bin}")
        for name, value in counters.items():
            per_counter.setdefault(name, []).append(value)
    return {name: statistics.median(values) for name, values in per_counter.items()}


def rss_cpu_workload(lua_bin: Path, workload: str, core: str) -> Dict[str, float]:
    """Exact max-RSS + process CPU time for one workload run (see _RSS_HELPER)."""
    proc = subprocess.run(
        ["python3", "-c", _RSS_HELPER,
         "taskset", "-c", core, str(lua_bin), str(BENCH), workload],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        timeout=BENCH_TIMEOUT_S, check=True,
    )
    data = json.loads(proc.stdout.strip().splitlines()[-1])
    data["cpu_s"] = data.pop("utime") + data.pop("stime")
    return data


def zig_vm_instructions(workload: str, core: str) -> int:
    """luazig --stats run: executed Lua VM instructions for one workload."""
    with tempfile.TemporaryDirectory(prefix="luazig-stats-") as td:
        stats_path = Path(td) / "stats.json"
        subprocess.run(
            ["taskset", "-c", core, str(ZIG_LUA), "--stats", str(stats_path), str(BENCH), workload],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
            timeout=BENCH_TIMEOUT_S, check=True,
        )
        stats = json.loads(stats_path.read_text(encoding="utf-8"))
    return int(stats["instructions_total"])


def derived(c: Dict[str, float]) -> Dict[str, float]:
    """IPC / branch-miss / cache-miss ratios from raw counters."""
    out: Dict[str, float] = {}
    if c.get("cycles"):
        out["ipc"] = c["instructions"] / c["cycles"]
    if c.get("branches"):
        out["branch_miss_ratio"] = c["branch-misses"] / c["branches"]
    if c.get("cache-references"):
        out["cache_miss_ratio"] = c["cache-misses"] / c["cache-references"]
    return out


def run_counters_mode(args) -> int:
    """B1 mode: per-workload hardware counters for zig and puc."""
    print(f"\n>> counters mode: {args.counters_runs} median runs per workload, "
          f"pinned to core {args.core}")
    print(f">> zig: {ZIG_LUA}")
    print(f">> puc: {PUC_LUA}")
    results: Dict[str, dict] = {}
    for wl in WORKLOADS:
        entry: dict = {}
        for label, lua_bin in (("zig", ZIG_LUA), ("puc", PUC_LUA)):
            print(f"  {wl}/{label}: perf stat x{args.counters_runs} ...", flush=True)
            raw = perf_stat_workload(lua_bin, wl, args.core, args.counters_runs)
            # RSS + CPU come from a plain (perf-less) run: perf adds overhead.
            rsrc = rss_cpu_workload(lua_bin, wl, args.core)
            entry[label] = {
                "counters": raw,
                "ipc": derived(raw).get("ipc"),
                "branch_miss_ratio": derived(raw).get("branch_miss_ratio"),
                "cache_miss_ratio": derived(raw).get("cache_miss_ratio"),
                "maxrss_kb": rsrc["maxrss_kb"],
                "cpu_s": rsrc["cpu_s"],
            }
        # Instruction-inflation proxy: luazig executed Lua-VM instructions
        # (from --stats) vs PUC native instructions:u (perf). CAVEAT: the PUC
        # count includes its C runtime (parser, stdlib, GC), not just Lua
        # bytecode interpretation — acceptable proxy, not an exact ratio.
        zig_instrs = zig_vm_instructions(wl, args.core)
        puc_instrs = entry["puc"]["counters"].get("instructions")
        entry["zig_vm_instructions"] = zig_instrs
        entry["instr_ratio"] = (zig_instrs / puc_instrs) if puc_instrs else None
        results[wl] = entry

    # Human table (full detail goes to --json-out).
    print(f"\n{'Workload':<18} {'zigIPC':>7} {'pucIPC':>7} {'zigBr%':>7} {'pucBr%':>7} "
          f"{'zigCm%':>7} {'pucCm%':>7} {'zigRSS':>8} {'pucRSS':>8} {'zigCPU':>7} {'pucCPU':>7} {'instrX':>8}")
    print("-" * 112)
    for wl, e in results.items():
        z, p = e["zig"], e["puc"]
        print(f"{wl:<18} "
              f"{z['ipc']:>7.2f} {p['ipc']:>7.2f} "
              f"{100 * z['branch_miss_ratio']:>7.2f} {100 * p['branch_miss_ratio']:>7.2f} "
              f"{100 * z['cache_miss_ratio']:>7.2f} {100 * p['cache_miss_ratio']:>7.2f} "
              f"{z['maxrss_kb'] / 1024:>7.1f}M {p['maxrss_kb'] / 1024:>7.1f}M "
              f"{z['cpu_s']:>7.2f} {p['cpu_s']:>7.2f} "
              f"{e['instr_ratio']:>8.3f}x")

    if args.json_out:
        out = {
            "created_utc": datetime.now(timezone.utc).isoformat(),
            "mode": "counters",
            "runs": args.counters_runs,
            "core": args.core,
            "host": {
                "platform": platform.platform(),
                "python": platform.python_version(),
            },
            "events": COUNTER_EVENTS,
            "workloads": results,
        }
        out_path = Path(args.json_out)
        if out_path.parent != Path("."):
            out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
        print(f"\njson: {out_path}")
    return 0


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
    ap.add_argument("--counters", action="store_true",
                    help="per-workload hardware counters mode (perf stat -j, RSS, --stats); "
                         "replaces the timing lane")
    ap.add_argument("--counters-runs", type=int, default=DEFAULT_COUNTERS_RUNS,
                    help=f"median runs per workload in --counters mode (default {DEFAULT_COUNTERS_RUNS})")
    ap.add_argument("--json-out", default="",
                    help="write the current run result dict to PATH (baseline untouched)")
    args = ap.parse_args()

    if args.runs < 1:
        ap.error("--runs must be >= 1")
    if args.counters_runs < 1:
        ap.error("--counters-runs must be >= 1")

    if not args.no_build:
        build_all()
    else:
        ensure_built()

    if args.counters:
        return run_counters_mode(args)

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

    if args.json_out:
        out_path = Path(args.json_out)
        if out_path.parent != Path("."):
            out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
        print(f"\njson: {out_path}")

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
