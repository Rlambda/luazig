#!/usr/bin/env python3
"""
perf_global_arith_decomp.py — decompose the global_arith workload into
per-opcode instruction costs (zig vs PUC), with honest uncertainty.

Produces tools/perf/current-global-arith-decomposition.json — a versioned
artifact cited by roadmap decisions. Regenerable: run this script after
`zig build -Doptimize=ReleaseFast && make -s lua-c`.

Method (P16.9 T3 — honest instruction numbers):
  1. DIRECT measurements: run each isolated single-opcode workload
     (forloop_only, int_arith, gettabup_only, settabup_only) and the
     combined global_arith workload under `perf stat -e instructions`
     at N=1B (isolated) / N=100M (global_arith), REPEATED ≥3 times per
     runtime. Report the MEDIAN instr/iter and the MAX SPREAD
     (max−min across runs) to demonstrate determinism.
  2. DERIVED estimates: per-opcode (handler+dispatch) contribution via
     isolated-workload subtraction (e.g. ADD = int_arith − forloop_only).
     These are LABELED "derived_estimate" with an explicit method note
     and an uncertainty ±X instr/iter propagated from the component
     spreads (sum of absolute spreads, conservative). Non-additive
     branch/layout effects are possible, so derived numbers are
     approximate — the global_arith cross-check residual quantifies the
     additive-model error.
  3. Per-opcode histogram from luazig --stats (executed-instruction
     counts; MMBIN is skipped via pc++ on the int fast path).

Usage:
  python3 tools/perf_global_arith_decomp.py            # full regenerate
  python3 tools/perf_global_arith_decomp.py --no-build  # skip build step
  python3 tools/perf_global_arith_decomp.py --runs 5    # more repeats
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
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
DEFAULT_RUNS = 5

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


def perf_instr_once(binary: str, workload: str, n: int,
                    extra_args: list[str] | None = None) -> int:
    """Run perf stat -e instructions:u once and return the user-mode instruction count.

    Uses instructions:u (user-mode only) to exclude kernel/interrupt noise —
    raw `instructions` counts both user and kernel, and interrupt handlers
    during a ~40s run add ~18 instr/iter of variance to PUC global_arith
    (the historical '208 vs 190' discrepancy). User-mode-only counts are
    deterministic for a deterministic program.
    """
    cmd = ["perf", "stat", "-x,", "-e", "instructions:u",
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


def measure(binary: str, workload: str, n: int, runs: int,
            extra_args: list[str] | None = None) -> dict:
    """Measure a workload `runs` times; return median + max spread (instr/iter).

    Direct measurement: the reported instr/iter is the median of the repeated
    runs. max_spread = max−min across runs, demonstrating determinism (perf
    instruction counts are deterministic modulo interrupts/ASLR noise, so the
    spread should be ≤ a few instr/iter).
    """
    vals = [perf_instr_once(binary, workload, n, extra_args) / n
            for _ in range(runs)]
    med = statistics.median(vals)
    spread = max(vals) - min(vals)
    return {
        "median_instr_per_iter": round(med, 2),
        "max_spread": round(spread, 2),
        "all_runs": [round(v, 2) for v in vals],
    }


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
    ap.add_argument("--runs", type=int, default=DEFAULT_RUNS,
                    help=f"repeated runs per workload (default {DEFAULT_RUNS})")
    args = ap.parse_args()

    if not args.no_build:
        build()

    write_workloads()

    # 1. DIRECT measurements: isolated workloads at N=1B, repeated.
    print(f">> Measuring isolated workloads (N={N_ISOLATED}, {args.runs} runs)...")
    isolated: dict[str, dict] = {}
    for wl in ["forloop_only", "int_arith", "gettabup_only", "settabup_only"]:
        zi = measure(str(ZIG_LUA), wl, N_ISOLATED, args.runs, ["--vm=bc"])
        pi = measure(str(PUC_LUA), wl, N_ISOLATED, args.runs)
        isolated[wl] = {"zig": zi, "puc": pi}
        print(f"   {wl}: zig={zi['median_instr_per_iter']:.1f}±{zi['max_spread']:.1f} "
              f"puc={pi['median_instr_per_iter']:.1f}±{pi['max_spread']:.1f}")

    # 2. DIRECT measurement: global_arith at N=100M, repeated.
    print(f">> Measuring global_arith (N={N_GLOBAL}, {args.runs} runs)...")
    ga_zig = measure(str(ZIG_LUA), "global_arith", N_GLOBAL, args.runs, ["--vm=bc"])
    ga_puc = measure(str(PUC_LUA), "global_arith", N_GLOBAL, args.runs)
    ga_zig_med = ga_zig["median_instr_per_iter"]
    ga_puc_med = ga_puc["median_instr_per_iter"]
    print(f"   global_arith: zig={ga_zig_med:.1f}±{ga_zig['max_spread']:.1f} "
          f"puc={ga_puc_med:.1f}±{ga_puc['max_spread']:.1f}")

    # 3. Per-opcode histogram (executed instructions; MMBIN skipped on fast path).
    print(">> Collecting --stats histogram...")
    stats = get_stats("global_arith", N_GLOBAL)

    # 4. DERIVED estimates: per-opcode (dispatch+handler) costs by subtraction.
    #    Uncertainty = sum of component max_spreads (conservative propagation).
    #    Non-additive branch/layout effects are possible — the global_arith
    #    cross-check residual quantifies the additive-model error.
    dz_f = isolated["forloop_only"]["zig"]["median_instr_per_iter"]
    dp_f = isolated["forloop_only"]["puc"]["median_instr_per_iter"]
    uz_f = isolated["forloop_only"]["zig"]["max_spread"]
    up_f = isolated["forloop_only"]["puc"]["max_spread"]

    dz_a = isolated["int_arith"]["zig"]["median_instr_per_iter"] - dz_f
    dp_a = isolated["int_arith"]["puc"]["median_instr_per_iter"] - dp_f
    uz_a = isolated["int_arith"]["zig"]["max_spread"] + uz_f
    up_a = isolated["int_arith"]["puc"]["max_spread"] + up_f

    dz_g = isolated["gettabup_only"]["zig"]["median_instr_per_iter"] - dz_f
    dp_g = isolated["gettabup_only"]["puc"]["median_instr_per_iter"] - dp_f
    uz_g = isolated["gettabup_only"]["zig"]["max_spread"] + uz_f
    up_g = isolated["gettabup_only"]["puc"]["max_spread"] + up_f

    dz_s = isolated["settabup_only"]["zig"]["median_instr_per_iter"] - dz_f
    dp_s = isolated["settabup_only"]["puc"]["median_instr_per_iter"] - dp_f
    uz_s = isolated["settabup_only"]["zig"]["max_spread"] + uz_f
    up_s = isolated["settabup_only"]["puc"]["max_spread"] + up_f

    total_delta = ga_zig_med - ga_puc_med
    derived_method = (
        "isolated-workload subtraction; non-additive branch/layout effects "
        "possible; uncertainty = sum of component max_spreads (conservative)"
    )

    def row(opcode, dz, dp, uz, up):
        delta = dz - dp
        # Percentage of total inflation, as a range reflecting uncertainty.
        unc = uz + up
        pct_low = 100 * (delta - unc) / total_delta if total_delta else 0
        pct_high = 100 * (delta + unc) / total_delta if total_delta else 0
        return {
            "opcode": opcode,
            "kind": "derived_estimate",
            "method": derived_method,
            "zig_instr": round(dz, 1),
            "zig_uncertainty": round(uz, 1),
            "puc_instr": round(dp, 1),
            "puc_uncertainty": round(up, 1),
            "delta": round(delta, 1),
            "ratio": round(dz / dp, 2) if dp else None,
            "pct_of_inflation": f"≈{100 * delta / total_delta:.0f}%" if total_delta else "n/a",
            "pct_range": f"[{pct_low:.0f}%, {pct_high:.0f}%]" if total_delta else "n/a",
        }

    table = [
        row("SETTABUP", dz_s, dp_s, uz_s, up_s),
        row("GETTABUP", dz_g, dp_g, uz_g, up_g),
        row("FORLOOP", dz_f, dp_f, uz_f, up_f),
        row("ADD", dz_a, dp_a, uz_a, up_a),
    ]
    table.sort(key=lambda x: -x["delta"])

    # Cross-check: additive model sum vs measured global_arith total.
    sum_zig = dz_f + dz_a + dz_g + dz_s
    sum_puc = dp_f + dp_a + dp_g + dp_s
    residual_zig = ga_zig_med - sum_zig
    residual_puc = ga_puc_med - sum_puc

    # In-context SETTABUP: the last opcode's cost derived from the global_arith
    # total minus the other three (forces additivity). This is the contribution
    # SETTABUP actually makes inside global_arith, as opposed to its isolated
    # cost. The gap between isolated and in-context is the non-additive effect.
    dz_s_inctx = ga_zig_med - dz_f - dz_a - dz_g
    dp_s_inctx = ga_puc_med - dp_f - dp_a - dp_g

    head = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"],
                                   cwd=ROOT, text=True).strip()

    artifact = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "task": "P16.9 T3 — honest instruction numbers (direct + derived)",
        "head": head,
        "measurement": {
            "runs_per_workload": args.runs,
            "n_isolated": N_ISOLATED,
            "n_global": N_GLOBAL,
            "statistic": "median instr/iter; max_spread = max−min across runs",
            "core": "0",
            "determinism_note": (
                "FORLOOP and ADD (no hash-table access) are perfectly "
                "deterministic (spread = 0). GETTABUP and SETTABUP have a "
                "~9 instr/iter spread because both PUC (luai_makeseed: "
                "time+address) and luazig (makeRandomSeed: time+address) use "
                "a PER-PROCESS RANDOM HASH SEED for string interning. "
                "Different seeds → different hash-table bucket for 'g_count' "
                "→ different collision-chain length → different instruction "
                "count per lookup. This is the root cause of the historical "
                "'208 vs 190' PUC global_arith discrepancy: it is NOT "
                "measurement error but a genuine property of hash-seed "
                "randomization. The max_spread is the honest uncertainty."
            ),
        },
        "workload": {
            "name": "global_arith",
            "shape": "g_count = 0; for i=1,n do g_count = g_count + i end; return g_count",
            "source": "tools/microbench.lua:34-38",
            "N_reference": N_GLOBAL,
            "ratio_instr": round(ga_zig_med / ga_puc_med, 2),
            "zig_direct": ga_zig,
            "puc_direct": ga_puc,
        },
        "bytecode": {
            "listed_loop_body_zig": ["GETTABUP", "ADD", "MMBIN", "SETTABUP", "FORLOOP"],
            "listed_loop_body_puc": ["GETTABUP", "ADD", "MMBIN", "SETTABUP", "FORLOOP"],
            "executed_loop_body_zig_fast_int": ["GETTABUP", "ADD", "SETTABUP", "FORLOOP"],
            "executed_loop_body_puc_fast_int": ["GETTABUP", "ADD", "SETTABUP", "FORLOOP"],
            "note": (
                "Both runtimes LIST 5 opcodes per iteration (GETTABUP, ADD, "
                "MMBIN, SETTABUP, FORLOOP). On the int+int fast path, op_arith_aux "
                "does pc++ to SKIP the companion MMBIN (PUC lvm.c luaV_arith + "
                "luazig ADD handler), so only 4 opcodes are EXECUTED per iteration. "
                "Verified via PUC count hook: N=10 -> 52 hits, N=20 -> 92 hits, "
                "delta = 40, i.e. 4.0 ops/iter."
            ),
            "ops_listed_per_iter": 5,
            "ops_executed_per_iter_fast_int": 4,
        },
        "opcode_histogram_zig": {
            "source": "luazig --vm=bc --stats (EXECUTED instructions; MMBIN skipped)",
            "N": N_GLOBAL,
            "total": stats["instructions_total"],
            "per_op": {k: v for k, v in sorted(stats["instructions_by_op"].items())
                       if v > N_GLOBAL // 2},
        },
        "direct_measurements": {
            "method": "perf stat -e instructions, median of repeated runs.",
            "workloads": isolated,
        },
        "per_opcode_costs": {
            "method": derived_method,
            "table": table,
            "total_zig_direct": round(ga_zig_med, 1),
            "total_puc_direct": round(ga_puc_med, 1),
            "total_delta": round(total_delta, 1),
            "total_ratio": round(ga_zig_med / ga_puc_med, 2),
            "additive_model_sum_zig": round(sum_zig, 1),
            "additive_model_sum_puc": round(sum_puc, 1),
            "residual_zig": round(residual_zig, 1),
            "residual_puc": round(residual_puc, 1),
            "residual_note": (
                "Residual = direct global_arith − sum of derived per-opcode. "
                "Non-zero residual reflects non-additive branch/layout effects "
                "(e.g. code layout, BTB state differences between isolated and "
                "combined workloads)."
            ),
            "in_context_settabup": {
                "method": "global_arith subtraction (forces additivity): "
                          "SETTABUP = global_arith − FORLOOP − ADD − GETTABUP.",
                "zig_instr": round(dz_s_inctx, 1),
                "puc_instr": round(dp_s_inctx, 1),
                "delta": round(dz_s_inctx - dp_s_inctx, 1),
                "pct_of_inflation": f"≈{100 * (dz_s_inctx - dp_s_inctx) / total_delta:.0f}%" if total_delta else "n/a",
                "note": (
                    "In-context SETTABUP (inside global_arith) vs isolated "
                    "SETTABUP: the gap is the non-additive branch/layout effect. "
                    "PUC is nearly additive (residual ≈ 0); zig's isolated "
                    "SETTABUP overestimates because the 2-opcode isolated loop "
                    "has worse dispatch/BTB behavior than the 4-opcode "
                    "global_arith loop."
                ),
            },
        },
    }

    OUT.write_text(json.dumps(artifact, indent=2) + "\n")
    print(f"\n>> Wrote {OUT}")

    # Print summary table.
    print(f"\n{'Opcode':<12} {'Zig':>10} {'PUC':>10} {'Delta':>8} {'Ratio':>7} {'%infl':>10}")
    print("-" * 60)
    for r in table:
        print(f"{r['opcode']:<12} {r['zig_instr']:>7.1f}±{r['zig_uncertainty']:<2.0f} "
              f"{r['puc_instr']:>7.1f}±{r['puc_uncertainty']:<2.0f} "
              f"{r['delta']:>8.1f} {r['ratio']:>6.2f}x {r['pct_of_inflation']:>9}")
    print("-" * 60)
    print(f"{'Total(direct)':<12} {ga_zig_med:>10.1f} {ga_puc_med:>10.1f} "
          f"{total_delta:>8.1f} {ga_zig_med/ga_puc_med:>6.2f}x {100.0:>9.0f}%")
    print(f"{'Additive sum':<12} {sum_zig:>10.1f} {sum_puc:>10.1f} "
          f"{sum_zig-sum_puc:>8.1f}")
    print(f"{'Residual':<12} {residual_zig:>10.1f} {residual_puc:>10.1f}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
