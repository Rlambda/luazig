#!/usr/bin/env python3
"""
perf_profile.py — per-workload `perf record` profiling pipeline (P16.0c).

For each selected microbench workload x binary (zig / puc) it records a
short userspace profile with LBR call graphs (paranoid=2 friendly), then
renders two `perf report --stdio` views next to the data file:

  <wl>-<bin>.perf      raw perf.data (NOT committed — see .gitignore)
  <wl>-<bin>.txt       report, default sort, --no-children, >=1% samples
  <wl>-<bin>.sym.txt   report aggregated purely by --sort symbol
  index.json           machine-readable manifest of everything above

The workload selector added to tools/microbench.lua keeps each record
session short (one workload instead of all 16).

Usage:
  python3 tools/perf_profile.py                     # 7 default workloads, zig+puc
  python3 tools/perf_profile.py --workloads lua_calls,array_access
  python3 tools/perf_profile.py --binaries zig
"""
from __future__ import annotations

import argparse
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

# Reuse paths and the canonical workload list from the perf gate — single
# source of truth for binary locations and valid microbench labels.
from perf_compare import (
    BENCH,
    PUC_LUA,
    ROOT,
    WORKLOADS,
    ZIG_LUA,
)

DEFAULT_WORKLOADS = (
    "lua_calls,array_access,hash_access,field_access,"
    "coroutine_yield,temp_table_alloc,metamethod_add"
)
DEFAULT_BINARIES = "zig,puc"
BENCH_TIMEOUT_S = 600


def perf_record(binary_path: Path, workload: str, core: str, data_file: Path) -> None:
    """Record one workload run with LBR call graphs (userspace samples only)."""
    proc = subprocess.run(
        ["taskset", "-c", core, "perf", "record",
         "--call-graph", "lbr", "-e", "cycles:u",
         "-o", str(data_file),
         str(binary_path), str(BENCH), workload],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        timeout=BENCH_TIMEOUT_S, check=True,
    )
    if f"{workload}\t" not in proc.stdout:
        raise SystemExit(
            f"workload '{workload}' produced no bench output under {binary_path}; "
            f"check the label against tools/microbench.lua"
        )


def perf_report(data_file: Path, report_file: Path, extra: list[str]) -> None:
    """Render one --stdio report view of a recorded data file."""
    with report_file.open("w", encoding="utf-8") as out:
        subprocess.run(
            ["perf", "report", "--stdio", "-i", str(data_file),
             "--no-children", "--percent-limit", "1", *extra],
            stdout=out, stderr=subprocess.PIPE, text=True,
            timeout=BENCH_TIMEOUT_S, check=True,
        )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workloads", default=DEFAULT_WORKLOADS,
                    help=f"comma-separated workload labels (default: {DEFAULT_WORKLOADS})")
    ap.add_argument("--binaries", default=DEFAULT_BINARIES,
                    help="comma-separated binary subset of {zig,puc} (default: zig,puc)")
    ap.add_argument("--out-dir", default="",
                    help="output directory (default: tools/perf/profiles/<UTC-date>)")
    ap.add_argument("--core", default="0",
                    help="CPU core to pin via taskset (default: 0)")
    args = ap.parse_args()

    binaries = {name.strip() for name in args.binaries.split(",") if name.strip()}
    unknown_bins = binaries - {"zig", "puc"}
    if unknown_bins:
        ap.error(f"--binaries must be a subset of zig,puc (got: {sorted(unknown_bins)})")
    bin_paths = {"zig": ZIG_LUA, "puc": PUC_LUA}

    workloads = [w.strip() for w in args.workloads.split(",") if w.strip()]
    unknown = [w for w in workloads if w not in WORKLOADS]
    if unknown:
        ap.error(f"unknown workloads {unknown}; valid labels: {WORKLOADS}")

    out_dir = Path(args.out_dir) if args.out_dir else (
        ROOT / "tools" / "perf" / "profiles" / datetime.now(timezone.utc).strftime("%Y-%m-%d")
    )
    out_dir.mkdir(parents=True, exist_ok=True)

    records = []
    for wl in workloads:
        for bin_name in sorted(binaries):
            data_file = out_dir / f"{wl}-{bin_name}.perf"
            print(f">> perf record {wl}/{bin_name} -> {data_file}", flush=True)
            perf_record(bin_paths[bin_name], wl, args.core, data_file)
            report_files = []
            for suffix, extra in (
                (".txt", []),                 # default sort (overhead, symbol, callchains)
                (".sym.txt", ["--sort", "symbol"]),  # pure per-symbol aggregation
            ):
                report_file = out_dir / f"{wl}-{bin_name}{suffix}"
                perf_report(data_file, report_file, extra)
                report_files.append(report_file.name)
                print(f"   report -> {report_file}")
            records.append({
                "workload": wl,
                "binary": bin_name,
                "data_file": data_file.name,
                "report_files": report_files,
            })

    index = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "core": args.core,
        "records": records,
    }
    (out_dir / "index.json").write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")
    print(f"\nindex: {out_dir / 'index.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
