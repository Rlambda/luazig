#!/usr/bin/env python3
"""
perf_snapshot.py — thin orchestrator for the versioned perf snapshot.

Calls perf_compare.py --snapshot-out to produce the three versioned artifacts
in tools/perf/:

  current.json               — per-workload timing (zig/puc median, ratio, geomean)
  current-counters.json      — per-workload hardware counters (IPC/CPI, branch/cache
                               miss ratios, max RSS, instruction inflation proxy)
  current-profile-index.json — top-N symbols (by cycles%) for 8 hotspot workloads

These are the reproducible artifacts that roadmap decisions cite. They are
SEPARATE from the regression baseline (baseline-p15.37.json).

Usage:
  perf_snapshot.py                    # timing 5, counters 2 (recommended)
  perf_snapshot.py --runs 7           # more timing runs (slower, slightly stabler)
  perf_snapshot.py --no-build         # skip zig build + make lua-c
  perf_snapshot.py --regenerate-docs  # also run status_summary --write-readme --write-status
  perf_snapshot.py --core 2           # pin to a different CPU core
"""
from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PERF_DIR = ROOT / "tools" / "perf"

DEFAULT_TIMING_RUNS = 5
DEFAULT_COUNTERS_RUNS = 2


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=DEFAULT_TIMING_RUNS,
                    help=f"timing median runs (default {DEFAULT_TIMING_RUNS})")
    ap.add_argument("--counters-runs", type=int, default=DEFAULT_COUNTERS_RUNS,
                    help=f"counter median runs (default {DEFAULT_COUNTERS_RUNS})")
    ap.add_argument("--core", default="0", help="CPU core to pin (default 0)")
    ap.add_argument("--no-build", action="store_true", help="skip zig build + make lua-c")
    ap.add_argument("--regenerate-docs", action="store_true",
                    help="also regenerate README + STATUS top block from the snapshot")
    args = ap.parse_args()

    cmd = [
        "python3", str(ROOT / "tools" / "perf_compare.py"),
        "--snapshot-out", str(PERF_DIR),
        "--runs", str(args.runs),
        "--counters-runs", str(args.counters_runs),
        "--core", args.core,
    ]
    if args.no_build:
        cmd.append("--no-build")

    print(f">> {' '.join(cmd)}")
    ret = subprocess.call(cmd, cwd=ROOT)
    if ret != 0:
        return ret

    if args.regenerate_docs:
        docs_cmd = [
            "python3", str(ROOT / "tools" / "status_summary.py"),
            "--perf-current",
            "--write-readme",
            "--write-status",
        ]
        print(f"\n>> {' '.join(docs_cmd)}")
        ret = subprocess.call(docs_cmd, cwd=ROOT)
        if ret != 0:
            return ret

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
