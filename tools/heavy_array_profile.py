#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEST_DIR = ROOT / "third_party" / "lua-upstream" / "testes"

SIZE_RE = re.compile(r"size:\s*(\d+)")
ERR_RE = re.compile(r"expected error:\s*(.*)")


def run_one(exe: Path, vmem_kb: int, timeout_s: int) -> tuple[int, str]:
    cmd = ["bash", "-lc", f"ulimit -Sv {vmem_kb}; exec {exe} -e '_port=true; _soft=true' heavy.lua"]
    proc = subprocess.run(
        cmd,
        cwd=TEST_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout_s,
    )
    return proc.returncode, proc.stdout


def extract(out: str) -> tuple[str, str]:
    size = "?"
    err = "?"
    for line in out.splitlines():
        m = SIZE_RE.search(line)
        if m:
            size = m.group(1)
        m = ERR_RE.search(line)
        if m:
            err = m.group(1).strip()
    return size, err


def main() -> int:
    ap = argparse.ArgumentParser(description="Profile heavy.lua table-array OOM behavior under virtual-memory limits.")
    ap.add_argument("--limits", default="131072,196608", help="Comma-separated virtual memory limits in KiB.")
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--trace-oom", action="store_true", help="Enable LUAZIG_TRACE_OOM for zig runs.")
    args = ap.parse_args()

    ref = ROOT / "build" / "lua-c" / "lua"
    zig = ROOT / "zig-out" / "bin" / "luazig"
    limits = [int(x.strip()) for x in args.limits.split(",") if x.strip()]
    old_trace = os.environ.get("LUAZIG_TRACE_OOM")

    print("limit_kb\timpl\trc\tsize\terror")
    overall = 0
    for limit in limits:
        for label, exe in (("ref", ref), ("zig", zig)):
            if label == "zig" and args.trace_oom:
                os.environ["LUAZIG_TRACE_OOM"] = "1"
            elif old_trace is None:
                os.environ.pop("LUAZIG_TRACE_OOM", None)
            else:
                os.environ["LUAZIG_TRACE_OOM"] = old_trace
            try:
                rc, out = run_one(exe, limit, args.timeout)
            except subprocess.TimeoutExpired:
                rc, out = 124, "timeout"
            size, err = extract(out)
            print(f"{limit}\t{label}\t{rc}\t{size}\t{err}")
            if rc not in (0, 124):
                overall = rc
    return overall


if __name__ == "__main__":
    raise SystemExit(main())
