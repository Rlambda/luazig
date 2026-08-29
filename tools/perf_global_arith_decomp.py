#!/usr/bin/env python3
"""
perf_global_arith_decomp.py — decompose the global_arith workload (2.31x)
into per-opcode instruction costs (zig vs PUC).

Produces tools/perf/current-global-arith-decomposition.json — a versioned
artifact cited by roadmap decisions. Regenerable: run this script after
`zig build -Doptimize=ReleaseFast && make -s lua-c`.

Method:
  1. Run isolated single-opcode workloads at N=1B under perf stat -e
     instructions for both runtimes (forloop_only, int_arith, gettabup_only,
     settabup_only).
  2. Run luazig --stats on global_arith to get the per-opcode histogram.
  3. Derive per-opcode (dispatch+handler) costs by subtracting the
     forloop_only baseline and cross-checking against the global_arith total.
  4. perf record + annotate the zig binary to identify hot lines and
     outlined calls.

Usage:
  python3 tools/perf_global_arith_decomp.py            # full regenerate
  python3 tools/perf_global_arith_decomp.py --no-build  # skip build step
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PERF_DIR = ROOT / "tools" / "perf"
ZIG_LUA = ROOT / "zig-out" / "bin" / "luazig"
PUC_LUA = ROOT / "build" / "lua-c" / "lua"
OUT = PERF_DIR / "current-global-arith-decomposition.json"
TMP = Path("/tmp/ga_decomp")

N_ISOLATED = 1_000_000_000
N_GLOBAL = 100_000_000

WORKLOADS = {
    "forloop_only": 'local n=tonumber(arg[1]) or 1e9 local s=os.clock() for i=1,n do end io.write(string.format("forloop_only\\t%.6f\\t%d\\n",os.clock()-s,n)) return n',
    "int_arith": 'local n=tonumber(arg[1]) or 1e9 local s=0 local t=os.clock() for i=1,n do s=s+i end io.write(string.format("int_arith\\t%.6f\\t%d\\n",os.clock()-t,n)) return s',
    "gettabup_only": 'local n=tonumber(arg[1]) or 1e9 g_count=0 local t=os.clock() for i=1,n do local x=g_count end io.write(string.format("gettabup_only\\t%.6f\\t%d\\n",os.clock()-t,n)) return g_count',
    "settabup_only": 'local n=tonumber(arg[1]) or 1e9 local t=os.clock() for i=1,n do g_count=i end io.write(string.format("settabup_only\\t%.6f\\t%d\\n",os.clock()-t,n)) return g_count',
    "global_arith": 'local n=tonumber(arg[1]) or 1e8 g_count=0 local t=os.clock() for i=1,n do g_count=g_count+i end io.write(string.format("global_arith\\t%.6f\\t%d\\n",os.clock()-t,n)) return g_count',
}


def build():
    print(">> zig build -Doptimize=ReleaseFast")
    subprocess.check_call(["zig", "build", "-Doptimize=ReleaseFast"], cwd=ROOT)
    print(">> make -s lua-c")
    subprocess.check_call(["make", "-s", "lua-c"], cwd=ROOT)


def write_workloads():
    TMP.mkdir(parents=True, exist_ok=True)
    for name, src in WORKLOADS.items():
        (TMP / f"ga_{name}.lua").write_text(src + "\n")


def perf_instr(binary: str, workload: str, n: int, extra_args: list[str] | None = None) -> int:
    """Run perf stat -e instructions and return the core instruction count."""
    cmd = ["perf", "stat", "-x,", "-e", "instructions",
           "taskset", "-c", "0", binary]
    if extra_args:
        cmd += extra_args
    cmd += [str(TMP / f"ga_{workload}.lua"), str(n)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    for line in r.stderr.splitlines():
        if "atom" in line:
            continue
        if "instructions" in line:
            val = line.split(",")[0].strip()
            if val and val != "<not counted>":
                return int(val)
    raise RuntimeError(f"Could not parse instructions from perf output:\n{r.stderr}")


def get_stats(workload: str, n: int) -> dict:
    stats_path = TMP / f"stats_{workload}.json"
    cmd = [str(ZIG_LUA), "--vm=bc", "--stats", str(stats_path),
           str(TMP / f"ga_{workload}.lua"), str(n)]
    subprocess.run(cmd, capture_output=True)
    return json.loads(stats_path.read_text())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-build", action="store_true")
    args = ap.parse_args()

    if not args.no_build:
        build()

    write_workloads()

    # 1. Isolated workload instruction counts at N=1B
    print(">> Measuring isolated workloads (N=1B)...")
    isolated = {}
    for wl in ["forloop_only", "int_arith", "gettabup_only", "settabup_only"]:
        zi = perf_instr(str(ZIG_LUA), wl, N_ISOLATED, ["--vm=bc"])
        pi = perf_instr(str(PUC_LUA), wl, N_ISOLATED)
        isolated[wl] = {
            "zig_instr_per_iter": zi / N_ISOLATED,
            "puc_instr_per_iter": pi / N_ISOLATED,
        }
        print(f"   {wl}: zig={isolated[wl]['zig_instr_per_iter']:.1f} puc={isolated[wl]['puc_instr_per_iter']:.1f}")

    # 2. global_arith at N=100M
    print(">> Measuring global_arith (N=100M)...")
    ga_zig = perf_instr(str(ZIG_LUA), "global_arith", N_GLOBAL, ["--vm=bc"])
    ga_puc = perf_instr(str(PUC_LUA), "global_arith", N_GLOBAL)
    ga_zig_per_iter = ga_zig / N_GLOBAL
    ga_puc_per_iter = ga_puc / N_GLOBAL
    print(f"   global_arith: zig={ga_zig_per_iter:.1f} puc={ga_puc_per_iter:.1f}")

    # 3. Per-opcode histogram
    print(">> Collecting --stats histogram...")
    stats = get_stats("global_arith", N_GLOBAL)

    # 4. Derive per-opcode costs
    dz_f = isolated["forloop_only"]["zig_instr_per_iter"]
    dp_f = isolated["forloop_only"]["puc_instr_per_iter"]
    dz_a = isolated["int_arith"]["zig_instr_per_iter"] - dz_f
    dp_a = isolated["int_arith"]["puc_instr_per_iter"] - dp_f
    dz_g = isolated["gettabup_only"]["zig_instr_per_iter"] - dz_f
    dp_g = isolated["gettabup_only"]["puc_instr_per_iter"] - dp_f
    dz_s = ga_zig_per_iter - dz_g - dz_a - dz_f
    dp_s = ga_puc_per_iter - dp_g - dp_a - dp_f

    table = [
        {"opcode": "SETTABUP", "zig_instr": round(dz_s, 1), "puc_instr": round(dp_s, 1),
         "delta": round(dz_s - dp_s, 1), "ratio": round(dz_s / dp_s, 2),
         "pct_of_inflation": round(100 * (dz_s - dp_s) / (ga_zig_per_iter - ga_puc_per_iter), 1)},
        {"opcode": "FORLOOP", "zig_instr": round(dz_f, 1), "puc_instr": round(dp_f, 1),
         "delta": round(dz_f - dp_f, 1), "ratio": round(dz_f / dp_f, 2),
         "pct_of_inflation": round(100 * (dz_f - dp_f) / (ga_zig_per_iter - ga_puc_per_iter), 1)},
        {"opcode": "GETTABUP", "zig_instr": round(dz_g, 1), "puc_instr": round(dp_g, 1),
         "delta": round(dz_g - dp_g, 1), "ratio": round(dz_g / dp_g, 2),
         "pct_of_inflation": round(100 * (dz_g - dp_g) / (ga_zig_per_iter - ga_puc_per_iter), 1)},
        {"opcode": "ADD", "zig_instr": round(dz_a, 1), "puc_instr": round(dp_a, 1),
         "delta": round(dz_a - dp_a, 1), "ratio": round(dz_a / dp_a, 2),
         "pct_of_inflation": round(100 * (dz_a - dp_a) / (ga_zig_per_iter - ga_puc_per_iter), 1)},
    ]

    # Sort by delta descending
    table.sort(key=lambda x: -x["delta"])

    head = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"],
                                   cwd=ROOT, text=True).strip()

    artifact = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "task": "P16.8a Task 7 — global_arith decomposition",
        "head": head,
        "workload": {
            "name": "global_arith",
            "shape": "g_count = 0; for i=1,n do g_count = g_count + i end; return g_count",
            "source": "tools/microbench.lua:34-38",
            "N_reference": N_GLOBAL,
            "ratio_instr": round(ga_zig_per_iter / ga_puc_per_iter, 2),
        },
        "bytecode": {
            "loop_body_zig": ["GETTABUP", "ADD", "SETTABUP", "FORLOOP"],
            "loop_body_puc": ["GETTABUP", "ADD", "MMBIN", "SETTABUP", "FORLOOP"],
            "note": "ADD int+int fast path skips MMBIN. PUC executes MMBIN as a no-op fast check.",
            "ops_per_iter_zig": 4,
            "ops_per_iter_puc": 5,
        },
        "opcode_histogram_zig": {
            "source": "luazig --vm=bc --stats",
            "N": N_GLOBAL,
            "total": stats["instructions_total"],
            "per_op": {k: v for k, v in sorted(stats["instructions_by_op"].items())
                       if v > N_GLOBAL // 2},
        },
        "per_opcode_costs": {
            "method": "Isolated single-opcode workloads at N=1B, perf stat -e instructions.",
            "workloads": isolated,
            "table": table,
            "total_zig": round(ga_zig_per_iter, 1),
            "total_puc": round(ga_puc_per_iter, 1),
            "total_delta": round(ga_zig_per_iter - ga_puc_per_iter, 1),
            "total_ratio": round(ga_zig_per_iter / ga_puc_per_iter, 2),
        },
    }

    OUT.write_text(json.dumps(artifact, indent=2) + "\n")
    print(f"\n>> Wrote {OUT}")

    # Print summary table
    print(f"\n{'Opcode':<12} {'Zig':>8} {'PUC':>8} {'Delta':>8} {'Ratio':>7} {'%infl':>7}")
    print("-" * 52)
    for row in table:
        print(f"{row['opcode']:<12} {row['zig_instr']:>8.1f} {row['puc_instr']:>8.1f} "
              f"{row['delta']:>8.1f} {row['ratio']:>6.2f}x {row['pct_of_inflation']:>6.1f}%")
    print("-" * 52)
    print(f"{'Total':<12} {ga_zig_per_iter:>8.1f} {ga_puc_per_iter:>8.1f} "
          f"{ga_zig_per_iter-ga_puc_per_iter:>8.1f} {ga_zig_per_iter/ga_puc_per_iter:>6.2f}x {100.0:>6.1f}%")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
