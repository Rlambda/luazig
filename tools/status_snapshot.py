#!/usr/bin/env python3
"""
status_snapshot.py — atomic orchestrator for the versioned correctness snapshot.

Runs the EXACT normal correctness lanes (matrix + smoke) and writes their JSON
reports to versioned artifacts under tools/status/:

  tools/status/current-matrix.json  — `testes_matrix.py --testc --json-out`
  tools/status/current-smoke.json   — `smoke_compare.py --json-out`

Atomicity: each lane writes to a temp file (tools/status/.tmp.<name>.json);
only on success is it atomically renamed over the current-*.json. A half-run
therefore never leaves a mix of fresh and stale artifacts. After both lanes
land, README.md + STATUS.md compact blocks are regenerated via
status_summary.py --use-current (which also reads tools/perf/current.json).

The perf snapshot is NOT rebuilt here — it lives in perf_snapshot.py. This
orchestrator only refreshes the correctness artifacts and the docs that cite
them. If tools/perf/current.json is missing, the perf row honestly reports
"_not run (no versioned artifact)_".

Usage:
  status_snapshot.py                 # full: build + matrix + smoke + docs
  status_snapshot.py --no-build      # skip zig build + make lua-c
  status_snapshot.py --skip-matrix   # smoke-only (quick sanity)
"""
from __future__ import annotations

import argparse
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATUS_DIR = ROOT / "tools" / "status"

MATRIX_ARTIFACT = STATUS_DIR / "current-matrix.json"
SMOKE_ARTIFACT = STATUS_DIR / "current-smoke.json"
PHASE_FILE = STATUS_DIR / "phase.txt"


def build() -> int:
    print(">> zig build -Doptimize=ReleaseFast")
    ret = subprocess.call(["zig", "build", "-Doptimize=ReleaseFast"], cwd=ROOT)
    if ret != 0:
        return ret
    print(">> make -s lua-c")
    return subprocess.call(["make", "-s", "lua-c"], cwd=ROOT)


def run_lane_atomic(name: str, cmd: list[str], artifact: Path) -> int:
    """Run a lane writing JSON to a temp file, then atomically rename over the
    versioned artifact. On failure the temp file is removed and the existing
    artifact is left untouched (stale but never half-written)."""
    STATUS_DIR.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_path = tempfile.mkstemp(
        prefix=f".tmp.{name}.", suffix=".json", dir=str(STATUS_DIR))
    os.close(tmp_fd)
    tmp = Path(tmp_path)
    try:
        full_cmd = cmd + ["--json-out", str(tmp)]
        print(f">> {' '.join(full_cmd)}")
        ret = subprocess.call(full_cmd, cwd=ROOT)
        if ret != 0:
            print(f"!! {name} lane failed (exit {ret}); leaving {artifact} untouched")
            return ret
        os.replace(tmp, artifact)
        print(f"   atomically wrote {artifact}")
        return 0
    finally:
        if tmp.exists():
            tmp.unlink()


def write_phase(phase: str) -> None:
    """Write the current phase identifier to tools/status/phase.txt.

    status_summary.py reads this file to machine-generate the ``> Last
    updated:`` line in STATUS.md, eliminating hand-edit drift.
    """
    STATUS_DIR.mkdir(parents=True, exist_ok=True)
    PHASE_FILE.write_text(phase + "\n", encoding="utf-8")
    print(f"   wrote {PHASE_FILE} ({phase})")


def regenerate_docs() -> int:
    cmd = [
        "python3", str(ROOT / "tools" / "status_summary.py"),
        "--use-current",
        "--write-readme",
        "--write-status",
    ]
    print(f"\n>> {' '.join(cmd)}")
    return subprocess.call(cmd, cwd=ROOT)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-build", action="store_true", help="skip zig build + make lua-c")
    ap.add_argument("--skip-matrix", action="store_true",
                    help="skip the (slow) matrix lane; smoke + docs only")
    ap.add_argument("--skip-docs", action="store_true",
                    help="do not regenerate README/STATUS blocks afterwards")
    ap.add_argument("--phase", default="",
                    help="phase identifier for the STATUS.md 'Last updated' line "
                         "(e.g. P16.9). Written to tools/status/phase.txt; "
                         "status_summary.py reads it to eliminate hand-edit drift.")
    args = ap.parse_args()

    if args.phase:
        write_phase(args.phase)

    if not args.no_build:
        ret = build()
        if ret != 0:
            return ret

    if not args.skip_matrix:
        ret = run_lane_atomic(
            "matrix",
            ["python3", str(ROOT / "tools" / "testes_matrix.py"), "--testc"],
            MATRIX_ARTIFACT,
        )
        if ret != 0:
            return ret

    ret = run_lane_atomic(
        "smoke",
        ["python3", str(ROOT / "tools" / "smoke_compare.py")],
        SMOKE_ARTIFACT,
    )
    if ret != 0:
        return ret

    if not args.skip_docs:
        ret = regenerate_docs()
        if ret != 0:
            return ret

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
