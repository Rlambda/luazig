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
  perf_compare.py --snapshot-out DIR # versioned snapshot: timing + counters + profile
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

# The 18 microbench workloads (must match the bench() labels in
# tools/microbench.lua; a mismatch fails loudly at run time because the
# expected `name\tseconds` line will be missing from the bench output).
WORKLOADS = [
    "int_arith", "global_arith", "branch_loop", "lua_calls",
    "array_access", "hash_access", "temp_table_alloc", "string_loop",
    "coroutine_yield", "dynamic_load", "mixed_arith", "float_arith",
    "string_concat", "metamethod_add", "field_access", "comparisons",
    "metamethod_call_noalloc", "table_alloc_setmetatable",
]

# Userspace-only events so this works with perf_event_paranoid=2.
# `-j` makes perf stat emit one JSON object per line on stderr:
#   {"counter-value" : "290234.000000", "event" : "cpu_core/cycles/u", ...}
# On hybrid CPUs (e.g. i7-13700H) every event appears twice — cpu_core and
# cpu_atom. When the workload is taskset-pinned to a P-core the cpu_atom rows
# read "<not counted>", so we skip those rows and the cpu_atom PMU entirely.
COUNTER_EVENTS = "cycles:u,instructions:u,branches:u,branch-misses:u,cache-misses:u,cache-references:u"

DEFAULT_COUNTERS_RUNS = 3

# ---------------------------------------------------------------------------
# Profile index (`--snapshot-out`, P16.5 Task 0)
# ---------------------------------------------------------------------------

# The 8 hotspot workloads for top-symbol profiling — the workloads where
# luazig shows the largest slowdown vs PUC and where optimisation work is
# most likely to pay off.
PROFILE_WORKLOADS = [
    "lua_calls", "hash_access", "field_access", "coroutine_yield",
    "string_concat", "string_loop", "metamethod_add", "temp_table_alloc",
    "metamethod_call_noalloc", "table_alloc_setmetatable",
]

# Standalone Lua scripts for each hotspot workload, with iteration counts
# tuned so each runs ~2-4 s under luazig ReleaseFast — long enough for perf
# record to collect thousands of cycle samples. The function bodies are
# extracted from tools/microbench.lua bench() definitions; only the iteration
# count differs (10-50x the microbench default, calibrated from the zig
# median times in the current baseline).
PROFILE_SCRIPTS: Dict[str, str] = {
    "lua_calls": (
        "local function inc(x) return x + 1 end\n"
        "local function workload(n)\n"
        "    local s = 0\n"
        "    for i = 1, n do s = inc(s) end\n"
        "    return s\n"
        "end\n"
        "workload(1000)\n"
        "local start = os.clock()\n"
        "workload(75000000)\n"
        'io.write(string.format("%.6f\\n", os.clock() - start))\n'
    ),
    "hash_access": (
        "local ht = {}\n"
        "for i = 1, 10000 do ht[i * 100] = i end\n"
        "local function workload(n)\n"
        "    local s = 0\n"
        "    for i = 1, n do s = ht[((i % 10000) + 1) * 100] end\n"
        "    return s\n"
        "end\n"
        "workload(1000)\n"
        "local start = os.clock()\n"
        "workload(60000000)\n"
        'io.write(string.format("%.6f\\n", os.clock() - start))\n'
    ),
    "field_access": (
        "local fields = {}\n"
        "local function workload(n)\n"
        "    for i = 1, n do\n"
        "        fields.x = i\n"
        "        fields.y = fields.x\n"
        "    end\n"
        "end\n"
        "workload(1000)\n"
        "local start = os.clock()\n"
        "workload(100000000)\n"
        'io.write(string.format("%.6f\\n", os.clock() - start))\n'
    ),
    "coroutine_yield": (
        "local function yielder()\n"
        "    while true do coroutine.yield(42) end\n"
        "end\n"
        "local co = coroutine.create(yielder)\n"
        "local function workload(n)\n"
        "    for i = 1, n do coroutine.resume(co) end\n"
        "end\n"
        "workload(1000)\n"
        "local start = os.clock()\n"
        "workload(10000000)\n"
        'io.write(string.format("%.6f\\n", os.clock() - start))\n'
    ),
    "string_concat": (
        "local function workload(n)\n"
        '    local s = ""\n'
        '    for i = 1, n do s = "x" .. i end\n'
        "    return s\n"
        "end\n"
        "workload(1000)\n"
        "local start = os.clock()\n"
        "workload(15000000)\n"
        'io.write(string.format("%.6f\\n", os.clock() - start))\n'
    ),
    "string_loop": (
        "local function workload(n)\n"
        '    local s = ""\n'
        '    for i = 1, n do s = tostring(i) .. ":" end\n'
        "    return s\n"
        "end\n"
        "workload(1000)\n"
        "local start = os.clock()\n"
        "workload(12000000)\n"
        'io.write(string.format("%.6f\\n", os.clock() - start))\n'
    ),
    "metamethod_add": (
        "local mt = { __add = function(a, b) return setmetatable({v = a.v + b.v}, mt) end }\n"
        "local box = setmetatable({v = 0}, mt)\n"
        "local function workload(n)\n"
        "    local s = box\n"
        "    for i = 1, n do s = s + box end\n"
        "    return s\n"
        "end\n"
        "workload(1000)\n"
        "local start = os.clock()\n"
        "workload(7000000)\n"
        'io.write(string.format("%.6f\\n", os.clock() - start))\n'
    ),
    "temp_table_alloc": (
        "local function workload(n)\n"
        "    for i = 1, n do local t = {1, 2, 3} end\n"
        "end\n"
        "workload(1000)\n"
        "local start = os.clock()\n"
        "workload(25000000)\n"
        'io.write(string.format("%.6f\\n", os.clock() - start))\n'
    ),
    "metamethod_call_noalloc": (
        "local mt = { __add = function(a, b) return a end }\n"
        "local box = setmetatable({}, mt)\n"
        "local function workload(n)\n"
        "    local s = box\n"
        "    for i = 1, n do s = s + box end\n"
        "end\n"
        "workload(1000)\n"
        "local start = os.clock()\n"
        "workload(25000000)\n"
        'io.write(string.format("%.6f\\n", os.clock() - start))\n'
    ),
    "table_alloc_setmetatable": (
        "local mt = {}\n"
        "local function workload(n)\n"
        "    for i = 1, n do local x = setmetatable({v = i}, mt) end\n"
        "end\n"
        "workload(1000)\n"
        "local start = os.clock()\n"
        "workload(25000000)\n"
        'io.write(string.format("%.6f\\n", os.clock() - start))\n'
    ),
}


def parse_perf_report(text: str, top_n: int = 10) -> list[dict]:
    """Parse `perf report --stdio --no-children` output into top-N symbols.

    Extracts data lines like:
        54.19%  luazig   luazig   [.] vm.Vm.runBytecodeDispatch
    Returns a list of {"symbol": str, "overhead_pct": float} dicts,
    sorted by overhead descending. Comment/header lines (starting with #)
    and blank lines are skipped.
    """
    entries: list[dict] = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # Data lines: "54.19%  command  shared_obj  [.] symbol"
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pct = float(parts[0].rstrip("%"))
        except ValueError:
            continue
        symbol_field = parts[3]
        # Symbol is after "[.] " — strip the prefix if present.
        if symbol_field.startswith("[.] "):
            symbol = symbol_field[4:]
        else:
            symbol = symbol_field
        entries.append({"symbol": symbol, "overhead_pct": pct})
    entries.sort(key=lambda e: e["overhead_pct"], reverse=True)
    return entries[:top_n]


def collect_profile_index(core: str, out_dir: Path) -> dict:
    """Run perf record + report for each hotspot workload, collect top symbols.

    For each workload in PROFILE_WORKLOADS:
    1. Write the standalone Lua script to /tmp.
    2. perf record -e cycles:u -o /tmp/<wl>.perf -- luazig /tmp/<wl>.lua
    3. perf report --stdio --no-children -i /tmp/<wl>.perf
    4. Parse top-10 symbols (>=0.1% overhead).

    Writes the index to out_dir/current-profile-index.json and returns it.
    """
    results: Dict[str, list[dict]] = {}
    for wl in PROFILE_WORKLOADS:
        script = PROFILE_SCRIPTS[wl]
        script_path = Path(tempfile.gettempdir()) / f"perf_profile_{wl}.lua"
        script_path.write_text(script, encoding="utf-8")
        data_file = Path(tempfile.gettempdir()) / f"perf_profile_{wl}.perf"

        print(f"  profile {wl}: perf record ...", flush=True)
        subprocess.run(
            ["taskset", "-c", core, "perf", "record",
             "-e", "cycles:u", "-o", str(data_file),
             str(ZIG_LUA), str(script_path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            timeout=BENCH_TIMEOUT_S, check=True,
        )

        report_proc = subprocess.run(
            ["perf", "report", "--stdio", "--no-children",
             "-i", str(data_file), "--percent-limit", "0.1"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            timeout=BENCH_TIMEOUT_S, check=True,
        )
        symbols = parse_perf_report(report_proc.stdout, top_n=10)
        results[wl] = symbols
        if symbols:
            top = symbols[0]
            print(f"    top: {top['symbol']} ({top['overhead_pct']:.1f}%)")

        # Clean up perf.data to avoid filling /tmp.
        data_file.unlink(missing_ok=True)

    index = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "core": core,
        "workloads": results,
    }
    out_path = out_dir / "current-profile-index.json"
    out_path.write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")
    print(f"  wrote {out_path}")
    return index

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


def collect_counters(args) -> Dict[str, dict]:
    """Collect per-workload hardware counters for zig and puc.

    Shared core of `--counters` and `--snapshot-out`. Returns the results
    dict (same structure as the ``workloads`` key in the counters JSON).
    """
    results: Dict[str, dict] = {}
    for wl in WORKLOADS:
        entry: dict = {}
        for label, lua_bin in (("zig", ZIG_LUA), ("puc", PUC_LUA)):
            print(f"  {wl}/{label}: perf stat x{args.counters_runs} ...", flush=True)
            raw = perf_stat_workload(lua_bin, wl, args.core, args.counters_runs)
            # RSS + CPU come from a plain (perf-less) run: perf adds overhead.
            rsrc = rss_cpu_workload(lua_bin, wl, args.core)
            cpi = (raw["cycles"] / raw["instructions"]) if raw.get("cycles") and raw.get("instructions") else None
            entry[label] = {
                "counters": raw,
                "ipc": derived(raw).get("ipc"),
                "cpi": cpi,
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
    return results


def run_counters_mode(args) -> int:
    """B1 mode: per-workload hardware counters for zig and puc."""
    print(f"\n>> counters mode: {args.counters_runs} median runs per workload, "
          f"pinned to core {args.core}")
    print(f">> zig: {ZIG_LUA}")
    print(f">> puc: {PUC_LUA}")
    results = collect_counters(args)

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
# Snapshot mode (`--snapshot-out`, P16.5 Task 0)
# ---------------------------------------------------------------------------

def run_snapshot_mode(args) -> int:
    """Produce the versioned perf snapshot — three JSON artifacts.

    Writes to the --snapshot-out directory:
      current.json               — per-workload timing + geomean + zig version
      current-counters.json      — per-workload hardware counters (zig + puc)
      current-profile-index.json — top-N symbols for 8 hotspot workloads

    This is the reproducible artifact that roadmap decisions cite. It is
    SEPARATE from the regression baseline (baseline-p15.37.json): the baseline
    is for regression checking, current.json is the versioned snapshot.
    """
    out_dir = Path(args.snapshot_out)
    out_dir.mkdir(parents=True, exist_ok=True)

    zig_version = subprocess.check_output(["zig", "version"], text=True).strip()

    # --- 1. Timing: median-of-N → current.json ---
    print(f"\n>> snapshot: timing {args.runs} runs each, pinned to core {args.core}")
    print(f">> zig: {ZIG_LUA}")
    print(f">> puc: {PUC_LUA}")
    zig = median_runs(ZIG_LUA, args.runs, args.core, "zig")
    puc = median_runs(PUC_LUA, args.runs, args.core, "puc")
    print_table(zig, puc)

    ratios = {n: zig[n] / puc[n] for n in zig if n in puc and puc[n]}
    geomean = math.exp(sum(math.log(r) for r in ratios.values()) / len(ratios)) if ratios else 0.0

    current = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "zig_version": zig_version,
        "host": {
            "platform": platform.platform(),
            "python": platform.python_version(),
        },
        "runs": args.runs,
        "core": args.core,
        "geomean": geomean,
        "workloads": {
            n: {"zig_s": zig[n], "puc_s": puc[n], "ratio": ratios[n]}
            for n in zig if n in puc
        },
        # Legacy fields for backward compat with status_summary --perf-json
        "zig": zig,
        "puc": puc,
        "ratios": ratios,
    }
    current_path = out_dir / "current.json"
    current_path.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
    print(f"\n>> wrote {current_path} (geomean {geomean:.2f}x)")

    # --- 2. Counters: reduced runs → current-counters.json ---
    print(f"\n>> snapshot: counters {args.counters_runs} runs each, pinned to core {args.core}")
    counters_results = collect_counters(args)
    counters_doc = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "zig_version": zig_version,
        "mode": "counters",
        "runs": args.counters_runs,
        "core": args.core,
        "host": {
            "platform": platform.platform(),
            "python": platform.python_version(),
        },
        "events": COUNTER_EVENTS,
        "workloads": counters_results,
    }
    counters_path = out_dir / "current-counters.json"
    counters_path.write_text(json.dumps(counters_doc, indent=2) + "\n", encoding="utf-8")
    print(f">> wrote {counters_path}")

    # --- 3. Profile index: 8 hotspot workloads → current-profile-index.json ---
    print(f"\n>> snapshot: profile index for {len(PROFILE_WORKLOADS)} hotspot workloads")
    collect_profile_index(args.core, out_dir)

    print(f"\n>> snapshot complete: {out_dir}/")
    print(f">> geomean: {geomean:.2f}x")
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
    ap.add_argument("--snapshot-out", default="",
                    help="produce versioned snapshot (current.json + current-counters.json + "
                         "current-profile-index.json) in DIR; supersedes --counters/--json-out")
    args = ap.parse_args()

    if args.runs < 1:
        ap.error("--runs must be >= 1")
    if args.counters_runs < 1:
        ap.error("--counters-runs must be >= 1")

    if not args.no_build:
        build_all()
    else:
        ensure_built()

    if args.snapshot_out:
        return run_snapshot_mode(args)

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
