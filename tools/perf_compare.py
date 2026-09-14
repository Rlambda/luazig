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
import os
import platform
import re
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict

# Shared provenance helpers live next to this script; make them importable
# regardless of the caller's CWD.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import provenance

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parents[1]
ZIG_LUA = ROOT / "zig-out" / "bin" / "luazig"
PUC_LUA = ROOT / "build" / "lua-c" / "lua"
BENCH = ROOT / "tools" / "microbench.lua"
# P16.18 T11: the regression guard compares against the EXPLICITLY approved
# baseline, never against a historical file that happens to lie around.
# `--update-baseline` rewrites baseline-approved.json (an explicit,
# reviewable operation that stamps identity metadata); the historical
# P15.37 measurement is preserved immutably in baseline-p15.37.json.
BASELINE = ROOT / "tools" / "perf" / "baseline-approved.json"
HISTORICAL_BASELINE = ROOT / "tools" / "perf" / "baseline-p15.37.json"

# Pin to a single CPU core to reduce scheduler noise. Core 0 is a safe default
# on most setups; if it is busy the user can override via --core.
DEFAULT_CORE = "0"
# P16.47: 21 samples per workload per session — SYMMETRIC with the baseline
# recording breadth. Coverage math: a seed mode observed at probability p
# is missed by N independent samples with probability (1-p)^N. The recorded
# minor modes: metamethod_call_noalloc ~0.29 (6/21; the binomial CI allows
# lower), global_arith ~0.43, field_access ~0.43. At N=21 the per-session
# miss is <=~0.5% for p>=0.29 (<=~3% even if the true p is 0.15); a miss is
# a fail-safe INCONCLUSIVE (nonzero, rerun) — never a silent OK. Measured
# earlier: N=7 missed ~9% of sessions on the 29% mode; N=13 still ~1-12%
# depending on the mode's true probability.
DEFAULT_RUNS = 21
BENCH_TIMEOUT_S = 600  # microbench must finish in under 10 min per run

# P16.47 owner-approved matched-mode policy (AGENTS.md «Инструменты
# производительности»): the mandatory gate compares COMPARABLE seed-mode
# populations of the production ReleaseFast binary. Causal observable =
# per-process instructions:u (deterministic per seed; the bimodal gap is
# orders of magnitude above jitter); wall = the workload's self-reported
# os.clock time (immune to wrapper startup overhead).
# Regression thresholds (fraction). WARN at +5%, FAIL at +10%.
REGRESSION_WARN = 0.05
REGRESSION_FAIL = 0.10

# P16.48: the split threshold is TIED TO THE VERDICT THRESHOLD — a gap
# smaller than REGRESSION_WARN cannot by itself create a WARN/FAIL verdict
# (mode-mix can shift a median at most by the gap size), so gaps below it
# are safely treated as within-population spread; gaps at/above it are
# modes whose mixing WOULD corrupt a verdict. Verified on the stored raw
# sessions: at the WARN-tied threshold the 18 workloads show 0/18 cluster-
# form flips between sessions (vs 3/18 at the old 1%: coroutine_yield,
# temp_table_alloc, metamethod_call_noalloc flipped forms — the gate had
# ignored candidate classification entirely, which is the false-green).
MODE_SPLIT_REL_GAP = REGRESSION_WARN
# Population-weight compatibility: a candidate whose mode mixture is
# statistically incompatible with the baseline mixture (exact two-sided
# binomial p-value < 1e-3) signals mass migration between modes — NOT a
# benign seed-mix change — and must not yield a green verdict.
WEIGHT_ALPHA = 1e-3
# Secondary wall rule (owner-approved P16.48): per matched instruction
# mode, compare the wall P25 (lower envelope). The per-process address
# layout lottery inflates/mixes the UPPER part of the wall distribution
# but leaves the fast envelope stable (measured ±1.6% across sessions
# while medians flipped >25%); a real slowdown shifts the whole
# distribution including the envelope. Envelope shift > 10% with an
# instruction-OK verdict → INCONCLUSIVE + run causal counters.
WALL_P25_LIMIT = 0.10
# (P16.48) The nearest-baseline-center assignment verdict is RETIRED: it
# had three proven false-greens (ignored candidate cluster form; absorbed
# a migrated population into the destination mode; absorbed a new minority
# mode into a mono median). The gate now clusters both sides INDEPENDENTLY
# and compares order-matched centers — see mode_aware_regression.

# Noisy-lane policy (P15.37; fail-safe rework P16.45 after review
# rejected the P16.44 downgrade): the current session's per-workload run
# spread of the SAME binary is printed as a NOISE DIAGNOSTIC when the
# baseline value falls inside it, but it NEVER changes the exit verdict.
# Reason: the candidate's own range cannot prove absence of regression —
# a genuinely slower, high-variance candidate can reach the old baseline
# with one lucky run. Downgrading requires comparable baseline AND
# candidate distributions, which the tool does not have (the baseline
# stores a single median). The aggregate WARN/FAIL verdicts below are
# computed per-workload first and folded afterwards — order-independent
# and never cleared while iterating (the P16.44 bug: one NOISE lane
# erased another lane's FAIL).

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
        # Provenance: zig-only lane — only luazig is profiled here, so no
        # puc_binary_sha16 (see tools/provenance.py block()).
        "provenance": provenance.block(zig_bin=ZIG_LUA,
                                         optimize_mode="ReleaseFast"),
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
    SEPARATE from the regression baseline (baseline-approved.json): the baseline
    is for regression checking, current.json is the versioned snapshot.
    """
    out_dir = Path(args.snapshot_out)
    out_dir.mkdir(parents=True, exist_ok=True)

    zig_version = provenance.zig_version()
    # Both binaries are measured in the timing and counters lanes, so both
    # hashes apply; the profile index (zig-only) computes its own block.
    prov = provenance.block(zig_bin=ZIG_LUA, puc_bin=PUC_LUA,
                            optimize_mode="ReleaseFast")

    # --- 1. Timing: median-of-N → current.json ---
    print(f"\n>> snapshot: timing {args.runs} runs each, pinned to core {args.core}")
    print(f">> zig: {ZIG_LUA}")
    print(f">> puc: {PUC_LUA}")
    zig, zig_spread = median_runs(ZIG_LUA, args.runs, args.core, "zig")
    puc, _ = median_runs(PUC_LUA, args.runs, args.core, "puc")
    print_table(zig, puc)

    ratios = {n: zig[n] / puc[n] for n in zig if n in puc and puc[n]}
    geomean = math.exp(sum(math.log(r) for r in ratios.values()) / len(ratios)) if ratios else 0.0

    current = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "zig_version": zig_version,
        "provenance": prov,
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
        "provenance": prov,
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


def median_runs(lua_bin: Path, n: int, core: str, label: str
               ) -> tuple[Dict[str, float], Dict[str, Dict[str, float]]]:
    """Run microbench n times; return (median, spread) per workload.

    The spread (min/max/median of this session's own runs of the SAME
    binary) feeds the diagnostic NOISE annotation in the gate tables.
    Used by the snapshot/counters lanes; the P16.47 mandatory gate lane
    collects per-workload mode samples instead (collect_mode_samples)."""
    runs: list[Dict[str, float]] = []
    for i in range(n):
        t0 = time.perf_counter()
        runs.append(run_bench(lua_bin, core))
        print(f"  {label} run {i + 1}/{n}: {time.perf_counter() - t0:.1f}s")
    # Workloads present in every run (intersection).
    names = set(runs[0]).intersection(*runs[1:])
    med = {name: statistics.median(r[name] for r in runs) for name in names}
    spread = {
        name: {
            "min": min(r[name] for r in runs),
            "max": max(r[name] for r in runs),
            "median": med[name],
        }
        for name in names
    }
    return med, spread


# ---------------------------------------------------------------------------
# P16.47 matched-mode measurement core
# ---------------------------------------------------------------------------

class ModeEvidenceError(RuntimeError):
    """Unclassifiable or mislabeled mode evidence — the gate must NOT guess.

    Raised when a candidate instruction sample cannot be assigned to any
    recorded baseline center within CENTER_TOLERANCE: the populations are
    then not comparable and the mandatory verdict is INCONCLUSIVE (nonzero),
    never a silent OK."""


def run_bench_one(lua_bin: Path, core: str, workload: str,
                  with_perf: bool = True) -> dict:
    """One workload in one fresh process (one hash seed = one mode sample).

    Returns {"wall": self-reported seconds, "instructions": process total}.
    Wall comes from the workload's own os.clock print, so wrapping the
    process in perf/taskset does not distort the measured section."""
    cmd = ["taskset", "-c", core, str(lua_bin), str(BENCH), workload]
    if with_perf:
        cmd = ["perf", "stat", "-e", "instructions:u"] + cmd
    proc = subprocess.run(cmd, capture_output=True, text=True,
                          timeout=BENCH_TIMEOUT_S)
    if proc.returncode != 0:
        raise ModeEvidenceError(
            f"workload {workload} exited {proc.returncode}: "
            f"{proc.stderr[-300:]}")
    wall = None
    for line in proc.stdout.splitlines():
        name, _, sec = line.partition("\t")
        if name.strip() == workload:
            try:
                wall = float(sec)
            except ValueError:
                pass
    if wall is None or wall <= 0:
        raise ModeEvidenceError(f"no self-reported wall for {workload}")
    if not with_perf:
        return {"wall": wall, "instructions": None}
    instr = None
    for line in proc.stderr.splitlines():
        m = re.match(r"\s*([\d,]+)\s+cpu_core/instructions/u", line)
        if m:
            instr = int(m.group(1).replace(",", ""))
    if instr is None or instr <= 0:
        raise ModeEvidenceError(f"no instructions:u for {workload}")
    return {"wall": wall, "instructions": instr}


def collect_mode_samples(lua_bin: Path, n: int, core: str, label: str,
                         workloads=None, with_perf: bool = True
                         ) -> dict[str, list[dict]]:
    """Per-workload sample populations: n fresh processes per workload.

    Each process draws an independent hash seed, so the samples of a
    bimodal workload populate both mode clusters; a unimodal workload
    stays in one cluster. Raw samples are kept verbatim (artifact evidence)."""
    samples: dict[str, list[dict]] = {}
    for wl in (workloads or WORKLOADS):
        rows = []
        t0 = time.perf_counter()
        for i in range(n):
            rows.append(run_bench_one(lua_bin, core, wl, with_perf))
        samples[wl] = rows
        print(f"  {label} {wl}: {n} samples in {time.perf_counter() - t0:.1f}s",
              flush=True)
    return samples


def classify_modes(samples: list[dict]) -> dict:
    """Cluster a workload's instruction population into seed modes.

    Deterministic and reorder-invariant: sort the instruction counts,
    split at the largest adjacent gap when that gap exceeds
    MODE_SPLIT_REL_GAP (WARN-tied — see the constant's comment; the
    global_arith mode gap is ~11% while same-mode jitter is ~0.001%).
    A split needs BOTH sides >= 2 samples and >= 10% of the population —
    a one-sample "cluster" is an outlier, not a mode. No workload names
    involved."""
    instrs = sorted(s["instructions"] for s in samples)
    n = len(instrs)
    if n < 2:
        labels = ["mono"] * n
        centers = {"mono": instrs[0] if n else 0}
        return {"labels": labels, "centers": centers, "split_rel_gap": 0.0, "n": n}
    best_gap, best_i = 0.0, 0
    for i in range(n - 1):
        a, b = instrs[i], instrs[i + 1]
        g = (b - a) / a if a else 0.0
        if g > best_gap:
            best_gap, best_i = g, i
    # A single-sample "cluster" is an outlier, not a mode: a split is only
    # accepted when BOTH sides have at least 2 samples (and at least 10% of
    # the population), otherwise the form is mono-with-outlier and the
    # comparison geometry below reports it honestly.
    splittable = (best_i + 1 >= 2 and n - best_i - 1 >= 2
                  and best_i + 1 >= max(2, n // 10)
                  and n - best_i - 1 >= max(2, n // 10))
    # A gap above the threshold whose split was rejected by the minimum
    # cluster size is ANOMALOUS evidence (an outlier that would otherwise
    # be its own mode): carried out so the regression can fail safe.
    rejected_split_gap = best_gap if (best_gap > MODE_SPLIT_REL_GAP
                                      and not splittable) else 0.0
    if best_gap > MODE_SPLIT_REL_GAP and splittable:
        low, high = instrs[:best_i + 1], instrs[best_i + 1:]
        centers = {"low": statistics.median(low), "high": statistics.median(high)}
        labels = []
        for s in samples:
            labels.append("low" if s["instructions"] <= instrs[best_i] else "high")
    else:
        centers = {"mono": statistics.median(instrs)}
        labels = ["mono"] * n
    return {"labels": labels, "centers": centers,
            "split_rel_gap": best_gap, "n": n,
            "rejected_split_gap": rejected_split_gap}


def _binom_two_sided_p(k: int, n: int, p: float) -> float:
    """Exact two-sided binomial p-value (no scipy dependency)."""
    def pmf(i: int) -> float:
        return math.comb(n, i) * p ** i * (1.0 - p) ** (n - i)
    pk = pmf(k)
    return min(1.0, sum(pmf(i) for i in range(n + 1)
                        if pmf(i) <= pk * (1 + 1e-9)))


def _p25(walls: list[float]) -> float:
    """Lower-envelope quantile of a wall population (deterministic).

    The address-layout lottery inflates the upper part of the wall
    distribution; the P25 envelope is its stable fast edge."""
    xs = sorted(walls)
    return xs[min(len(xs) - 1, int(0.25 * len(xs)))]


def mode_aware_regression(zig_samples: dict[str, list[dict]],
                          baseline_doc: dict) -> dict:
    """Matched-mode regression with INDEPENDENT cluster forms.

    P16.48 correction of three proven false-greens:
      1. a baseline workload missing from the candidate → INCONCLUSIVE
         (the old code printed "NEW" and returned a green aggregate);
      2. mode migration hid regressions: samples were only assigned to
         nearest BASELINE centers, so a population that migrated +11% into
         the other mode kept a green verdict (independently reproduced
         fixture: baseline low=10x100/high=10x111 vs candidate 1x100 +
         20x111 → old verdict OK);
      3. a new minority mode was absorbed by a mono median (baseline
         21x100 vs candidate 11x100 + 10x111 → old verdict OK).

    Both sides are now clustered INDEPENDENTLY by the same reorder-
    invariant largest-gap algorithm (threshold = WARN-tied, see
    MODE_SPLIT_REL_GAP). Verdicts compare cluster centers matched BY ORDER
    (low↔low, high↔high) only when the mode counts agree; any form change
    (mono↔split) is INCONCLUSIVE. For split↔split, the population weights
    must additionally be binomially compatible (WEIGHT_ALPHA): mass
    migration between modes is not a benign seed-mix change.

    Verdict metric: instruction center medians per matched mode (causal,
    deterministic per seed). Secondary owner-approved rule: a wall P25
    envelope shift > WALL_P25_LIMIT inside a matched mode with an
    instruction-OK verdict → INCONCLUSIVE (possible memory-hierarchy
    regression invisible to instruction counts) with guidance to run the
    causal counters lane.

    Fail-safe aggregation: per-verdict list folded after the loop; nothing
    can erase a FAIL; INCONCLUSIVE yields rc=2; NOISE/wall prints are
    diagnostics only."""
    base_samples_all = baseline_doc.get("zig_samples", {})
    prev_ident = baseline_doc.get("baseline_identity", {})
    print(f"\nMatched-mode regression check vs {BASELINE} "
          f"(phase: {prev_ident.get('baseline_phase', 'unknown')}):")
    print(f"  {'Workload[mode]':<28} {'base instr':>13} {'cur instr':>13} "
          f"{'delta':>9}  status")
    print("  " + "-" * 78)
    verdicts: list[str] = []
    inconclusive = False
    matching: dict[str, dict] = {}
    for wl in sorted(base_samples_all):
        base_rows = base_samples_all[wl]
        cand_rows = zig_samples.get(wl)
        if cand_rows is None:
            print(f"  {wl:<28}  MISSING from candidate session "
                  f"-> INCONCLUSIVE")
            inconclusive = True
            continue
        # Independent clustering of BOTH sides from raw samples — recorded
        # labels are provenance, never verdict input.
        base_ev = classify_modes(base_rows)
        cand_ev = classify_modes(cand_rows)
        base_form = "split" if len(base_ev["centers"]) == 2 else "mono"
        cand_form = "split" if len(cand_ev["centers"]) == 2 else "mono"
        matching[wl] = {"baseline_form": base_form,
                        "candidate_form": cand_form,
                        "baseline_centers": base_ev["centers"],
                        "candidate_centers": cand_ev["centers"]}
        outlier_gap = max(base_ev.get("rejected_split_gap", 0.0),
                          cand_ev.get("rejected_split_gap", 0.0))
        if outlier_gap > MODE_SPLIT_REL_GAP:
            print(f"  {wl:<28}  outlier above split threshold "
                  f"(gap {outlier_gap * 100:.1f}%, cluster too small) — "
                  f"corrupt evidence? -> INCONCLUSIVE")
            inconclusive = True
            continue
        if base_form != cand_form:
            print(f"  {wl:<28}  cluster form changed "
                  f"({base_form} -> {cand_form}) -> INCONCLUSIVE")
            inconclusive = True
            continue
        # Population-weight compatibility for split↔split (order-matched).
        if base_form == "split":
            base_low_n = sum(1 for s in base_rows
                             if s["instructions"] <= base_ev["centers"]["low"])
            cand_low_n = sum(1 for s in cand_rows
                             if s["instructions"] <= cand_ev["centers"]["low"])
            p = base_low_n / len(base_rows)
            pv = _binom_two_sided_p(cand_low_n, len(cand_rows), p)
            matching[wl]["weights"] = {"baseline_low_frac": p,
                                       "candidate_low_frac":
                                           cand_low_n / len(cand_rows),
                                       "binom_p": pv}
            if pv < WEIGHT_ALPHA:
                print(f"  {wl:<28}  population weights incompatible "
                      f"(low {p:.2f} -> {cand_low_n / len(cand_rows):.2f}, "
                      f"p={pv:.1e}) — mass migration? -> INCONCLUSIVE")
                inconclusive = True
                continue
        for mode in sorted(base_ev["centers"]):
            base_c = base_ev["centers"][mode]
            cand_c = cand_ev["centers"][mode]
            delta = (cand_c - base_c) / base_c if base_c else 0.0
            verdict = classify(delta)
            verdicts.append(verdict)
            # Secondary wall-envelope rule (owner-approved P16.48).
            b_walls = [s["wall"] for s, lab in zip(base_rows, base_ev["labels"])
                       if lab == mode]
            c_walls = [s["wall"] for s, lab in zip(cand_rows, cand_ev["labels"])
                       if lab == mode]
            env_note = ""
            if b_walls and c_walls:
                env_shift = (_p25(c_walls) - _p25(b_walls)) / _p25(b_walls)
                matching[wl].setdefault("wall_p25", {})[mode] = {
                    "baseline": _p25(b_walls), "candidate": _p25(c_walls),
                    "shift": env_shift}
                if verdict == "OK" and env_shift > WALL_P25_LIMIT:
                    verdict = "INCONCLUSIVE"
                    inconclusive = True
                    env_note = (f"  wall-P25 {env_shift * 100:+.0f}% -> "
                                f"INCONCLUSIVE (run causal counters: "
                                f"--perf)")
            w_med = statistics.median(c_walls) if c_walls else float("nan")
            w_spread = (f"[wall {min(c_walls):.3f}..{max(c_walls):.3f}"
                        f", med {w_med:.3f}]" if c_walls else "")
            print(f"  {wl + '[' + mode + ']':<28} {base_c:>13} "
                  f"{cand_c:>13} {delta * 100:>+8.2f}%  {verdict}  "
                  f"{w_spread}{env_note}")
    for wl in sorted(set(zig_samples) - set(base_samples_all)):
        med = statistics.median(s["wall"] for s in zig_samples[wl])
        print(f"  {wl:<28} {'--':>13} "
              f"{statistics.median(s['instructions'] for s in zig_samples[wl]):>13} "
              f"{'--':>9}  NEW (no baseline; informational)")
    any_warn = "WARN" in verdicts
    any_fail = "FAIL" in verdicts
    return {"warn": any_warn, "fail": any_fail,
            "inconclusive": inconclusive, "verdicts": verdicts,
            "matching": matching}


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


def classify(delta: float) -> str:
    """Threshold verdict for one workload — independent of all others."""
    if delta > REGRESSION_FAIL:
        return "FAIL"
    if delta > REGRESSION_WARN:
        return "WARN"
    return "OK"


def noise_annotation(old: float, current: float,
                     sp: Dict[str, float] | None) -> str:
    """Diagnostic-only noise marker (P16.45 fail-safe policy).

    Prints when the baseline value lies inside the CURRENT session's own
    min..max range of the SAME binary: the delta is then within that
    binary's observed run-to-run variance for this workload. This is
    EVIDENCE, never permission — the threshold verdict is unchanged,
    because the candidate's own range cannot prove absence of regression
    (a genuinely slower, high-variance candidate reaches the old baseline
    with one lucky run)."""
    if sp is None or old <= 0:
        return ""
    lo, hi = sp["min"], sp["max"]
    spread = hi - lo
    if spread <= 0 or not (lo <= old <= hi):
        return ""
    overlap = min(hi, max(old, current)) - max(lo, min(old, current))
    return f"  NOISE? [runs {lo:.3f}..{hi:.3f}, overlap {overlap / spread * 100:.0f}%]"


# ---------------------------------------------------------------------------
# P16.45-finalization: production baseline-serialization helpers.
# The CLI path and tools/test_perf_gate.py call THESE SAME functions — no
# duplicated test logic that could stay green while production breaks.
# ---------------------------------------------------------------------------

def build_baseline_document(current: dict, spreads: dict, runs: int, core: str,
                           baseline_phase: str, note=None, prov=None) -> dict:
    """Assemble the complete reviewable baseline document.

    `prov` overrides the default provenance.block() result (tests inject
    deterministic hashes without touching live binaries)."""
    ratios = current.get("ratios", {})
    geomean = (math.exp(sum(math.log(r) for r in ratios.values()) / len(ratios))
               if ratios else 0.0)
    return {
        "created_utc": current["created_utc"],
        "provenance": prov if prov is not None else
            provenance.block(zig_bin=ZIG_LUA, puc_bin=PUC_LUA,
                             optimize_mode="ReleaseFast"),
        "host": current["host"],
        "runs": runs,
        "core": core,
        "zig": current["zig"],
        "puc": current["puc"],
        "ratios": ratios,
        "geomean": geomean,
        "zig_spread": spreads,
        # P16.47 matched-mode evidence: raw per-sample populations (wall +
        # instructions + mode label) and the cluster centers they were
        # classified into. The mandatory gate compares modes against THESE,
        # never against mode-blind scalar medians.
        "zig_samples": current.get("zig_samples", {}),
        "mode_evidence": current.get("mode_evidence", {}),
        "baseline_identity": {
            "baseline_phase": baseline_phase,
            "note": (note or
                     "Approved regression baseline. Updating this file is an "
                     "EXPLICIT operation; the historical P15.37 baseline is "
                     "preserved separately in baseline-p15.37.json and is "
                     "never overwritten."),
        },
    }


def validate_baseline_document(doc: dict) -> bool:
    """Strict schema check for a serialized baseline document."""
    required = ("provenance", "geomean", "zig", "puc", "ratios",
                "zig_spread", "baseline_identity", "created_utc",
                "host", "runs", "core",
                # P16.47: a baseline without mode populations cannot back a
                # matched-mode verdict and must not replace a valid one.
                "zig_samples", "mode_evidence")
    for key in required:
        if key not in doc or doc[key] in (None, {}, []):
            return False
    ident = doc["baseline_identity"]
    if not isinstance(ident, dict) or not ident.get("baseline_phase"):
        return False
    return True


def write_baseline_atomic(path, doc: dict) -> bool:
    """Serialize + strict-reload-validate + atomically replace.

    On ANY failure the temp file is removed and the existing approved
    baseline is untouched; no .tmp residue survives either way."""
    tmp = Path(str(path) + ".tmp")
    try:
        tmp.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
        reloaded = json.loads(tmp.read_text(encoding="utf-8"))
        if reloaded.get("zig") != doc.get("zig") \
                or not validate_baseline_document(reloaded):
            tmp.unlink(missing_ok=True)
            return False
        os.replace(tmp, path)
        return True
    except (OSError, json.JSONDecodeError):
        tmp.unlink(missing_ok=True)
        return False


# (P16.47) the scalar mode-blind regression_check was REMOVED: comparing
# independently sampled seed-mode medians made the mandatory verdict
# session-dependent (OK ~0.744s / FAIL ~0.847s for one identical binary).
# Its fail-safe aggregation semantics live on in mode_aware_regression
# (per-verdict computation, fold after the loop, NOISE diagnostic-only);
# the scalar wall table remains as a printed diagnostic only.


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
    ap.add_argument("--baseline-note",
                    help="Caller-supplied provenance note recorded verbatim in "
                         "the baseline's baseline_identity when --update-baseline "
                         "runs (the reviewable justification for the refresh).",
                    default=None)
    ap.add_argument("--baseline-phase", default="unlabeled",
                    help="Phase label stamped into baseline-approved.json "
                         "by --update-baseline (e.g. P16.18)")
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
    ap.add_argument("--gate-out", default="",
                    help="explicit path for this gate session's evidence JSON "
                         "(atomic temp->replace); when omitted the canonical "
                         "tools/perf/current-gate.json is atomically updated")
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

    print(f"\n>> matched-mode gate: {args.runs} samples per workload per "
          f"binary, pinned to core {args.core}")
    print(f">> zig: {ZIG_LUA} (wall = self-reported; mode observable = "
          f"instructions:u)")
    print(f">> puc: {PUC_LUA} (wall only — ratio diagnostic)")

    # Zig: per-workload populations WITH the causal observable.
    zig_mode_samples = collect_mode_samples(ZIG_LUA, args.runs, args.core,
                                            "zig", with_perf=True)
    mode_evidence: dict[str, dict] = {}
    zig_samples_labeled: dict[str, list[dict]] = {}
    for wl, rows in zig_mode_samples.items():
        ev = classify_modes(rows)
        mode_evidence[wl] = {"centers": ev["centers"],
                             "split_rel_gap": ev["split_rel_gap"], "n": ev["n"]}
        zig_samples_labeled[wl] = [
            {"wall": s["wall"], "instructions": s["instructions"], "mode": lab}
            for s, lab in zip(rows, ev["labels"])]

    # PUC: wall-only populations for the scalar ratio diagnostic.
    puc_mode_samples = collect_mode_samples(PUC_LUA, args.runs, args.core,
                                            "puc", with_perf=False)

    zig = {wl: statistics.median(s["wall"] for s in rows)
           for wl, rows in zig_samples_labeled.items()}
    puc = {wl: statistics.median(s["wall"] for s in rows)
           for wl, rows in puc_mode_samples.items()}
    zig_spread = {wl: {"min": min(s["wall"] for s in rows),
                       "max": max(s["wall"] for s in rows),
                       "median": zig[wl]}
                  for wl, rows in zig_samples_labeled.items()}

    print("\nScalar diagnostic table (mode-blind medians — NOT the gate "
          "verdict; see the matched-mode check below):")
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
        "zig_samples": zig_samples_labeled,
        "mode_evidence": mode_evidence,
    }

    if args.json_out:
        out_path = Path(args.json_out)
        if out_path.parent != Path("."):
            out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
        print(f"\njson: {out_path}")

    if args.update_baseline:
        # P16.45-finalization: the CLI calls the SAME shared helpers the
        # serializer tests exercise (build/validate/write_baseline_atomic).
        baseline_doc = build_baseline_document(
            current, zig_spread, args.runs, args.core,
            args.baseline_phase, args.baseline_note)
        if not write_baseline_atomic(BASELINE, baseline_doc):
            print("\nBaseline update FAILED validation; "
                  "approved baseline NOT replaced.")
            return 1
        print(f"\nBaseline updated: {BASELINE} (phase {args.baseline_phase}, "
              f"geomean {baseline_doc['geomean']:.5f}, full provenance + spreads)")
        return 0

    if BASELINE.exists():
        prev = json.loads(BASELINE.read_text(encoding="utf-8"))
        if "zig_samples" not in prev or "mode_evidence" not in prev:
            print("\nBaseline carries no mode evidence (pre-P16.47 schema).")
            print("Re-record via --update-baseline under the owner-approved "
                  "matched-mode policy; a mode-blind comparison is NOT a "
                  "valid gate verdict.")
            return 2
        res = mode_aware_regression(zig_samples_labeled, prev)
        if res["fail"]:
            result_line = ("RESULT: FAIL (regression > 10% inside a "
                           "matched mode on one or more workloads)")
            rc = 1
        elif res["inconclusive"]:
            result_line = ("RESULT: INCONCLUSIVE (cluster-form change, "
                           "incompatible weights, missing workload, wall-P25 "
                           "envelope shift or corrupt evidence — NOT green; "
                           "rerun or re-record the baseline)")
            rc = 2
        elif res["warn"]:
            result_line = ("RESULT: WARN (regression > 5% inside a matched "
                           "mode on one or more workloads)")
            rc = 0
        else:
            result_line = "RESULT: OK (no regressions in any matched mode)"
            rc = 0
        print(f"\n{result_line}")

        # Persist this gate session (owner-approved evidence policy):
        # samples, BOTH independent cluster-evidence blocks, the explicit
        # matching decisions, provenance and the verdict. Written via
        # temp+atomic-replace so a tracked artifact is never left torn or
        # half-written; the canonical tools/perf/current-gate.json is the
        # record of the LATEST completed gate run unless --gate-out points
        # elsewhere.
        gate_session = {
            "created_utc": current["created_utc"],
            "provenance": provenance.block(zig_bin=ZIG_LUA, puc_bin=PUC_LUA,
                                           optimize_mode="ReleaseFast"),
            "runs": args.runs,
            "core": args.core,
            "result": {"verdict": ("FAIL" if rc == 1 else
                                   "INCONCLUSIVE" if rc == 2 else
                                   "WARN" if res["warn"] else "OK"),
                       "line": result_line},
            "zig_samples": zig_samples_labeled,
            "mode_evidence": mode_evidence,
            "baseline_evidence": prev.get("mode_evidence", {}),
            "matching": res.get("matching", {}),
        }
        gate_path = (Path(args.gate_out) if args.gate_out
                     else ROOT / "tools/perf/current-gate.json")
        tmp = Path(str(gate_path) + ".tmp")
        tmp.write_text(json.dumps(gate_session, indent=2) + "\n",
                       encoding="utf-8")
        import hashlib
        artifact_sha = hashlib.sha256(
            tmp.read_bytes()).hexdigest()
        os.replace(tmp, gate_path)
        print(f"gate session evidence: {gate_path}")

        # Multi-session manifest (P16.48 MEDIUM): consecutive-session
        # claims are backed by compact per-session records — timestamp,
        # source SHA, binary hash, artifact hash, result, per-mode centers.
        manifest_path = ROOT / "tools/perf/current-gate-manifest.json"
        manifest = []
        if manifest_path.exists():
            try:
                manifest = json.loads(
                    manifest_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                manifest = []
        centers_digest = {wl: {m: c for m, c in ev["centers"].items()}
                          for wl, ev in mode_evidence.items()}
        manifest.append({
            "created_utc": current["created_utc"],
            "source_head": gate_session["provenance"].get("git_head"),
            "zig_binary_sha256": gate_session["provenance"].get(
                "zig_binary_sha256"),
            "runs": args.runs,
            "result": gate_session["result"]["verdict"],
            "artifact_sha256": artifact_sha,
            "mode_centers": centers_digest,
        })
        mtmp = Path(str(manifest_path) + ".tmp")
        mtmp.write_text(json.dumps(manifest, indent=2) + "\n",
                        encoding="utf-8")
        os.replace(mtmp, manifest_path)
        return rc
    print(f"\nNo baseline at {BASELINE}; run with --update-baseline to "
          "create one.")
    return 0

    print(f"\nNo baseline at {BASELINE}; run with --update-baseline to create one.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
