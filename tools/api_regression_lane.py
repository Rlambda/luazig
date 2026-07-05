#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TARGETED_PARITY_SUITES = ["coroutine.lua", "api.lua", "locals.lua"]


def run_step(name: str, cmd: list[str], timeout: int) -> int:
    print(f"==> {name}", flush=True)
    print("$ " + " ".join(cmd), flush=True)
    t0 = time.time()
    proc = subprocess.run(
        cmd,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
    )
    dt = time.time() - t0
    if proc.stdout:
        print(proc.stdout, end="")
    status = "ok" if proc.returncode == 0 else "fail"
    print(f"<== {name}: {status} rc={proc.returncode} time={dt:.2f}s", flush=True)
    return proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser(
        description="API regression lane: Zig tests + official testC lane + targeted parity suites."
    )
    parser.add_argument("--timeout", type=int, default=180, help="Per-step timeout in seconds.")
    parser.add_argument(
        "--no-zig-tests",
        action="store_true",
        help="Skip `zig build test`; intended only for local narrowing.",
    )
    parser.add_argument(
        "--no-targeted-parity",
        action="store_true",
        help="Skip targeted differential suites; intended only for local narrowing.",
    )
    parser.add_argument(
        "--testc-timeout",
        type=int,
        default=120,
        help="Per-suite timeout forwarded to tools/testc_lane.py.",
    )
    args = parser.parse_args()

    steps: list[tuple[str, list[str], int]] = []
    zig_build_flags = shlex.split(os.environ.get("LUAZIG_ZIG_BUILD_FLAGS", ""))
    if not args.no_zig_tests:
        steps.append(("zig unit/integration tests", ["zig", "build", "test", "-Doptimize=Debug", *zig_build_flags], args.timeout))

    steps.append(("official testC lane", ["python3", "tools/testc_lane.py", "--timeout", str(args.testc_timeout)], args.timeout * 2))

    if not args.no_targeted_parity:
        parity_cmd = ["python3", "tools/run_tests.py"]
        for suite in TARGETED_PARITY_SUITES:
            parity_cmd.extend(["--suite", suite])
        steps.append(("targeted parity suites", parity_cmd, args.timeout))

    overall = 0
    for name, cmd, timeout in steps:
        try:
            rc = run_step(name, cmd, timeout)
        except subprocess.TimeoutExpired as exc:
            print(f"<== {name}: timeout after {timeout}s", file=sys.stderr)
            if exc.stdout:
                print(exc.stdout, end="")
            rc = 124
        if rc != 0:
            overall = rc
            break
    if overall == 0:
        print("api regression lane: OK")
    return overall


if __name__ == "__main__":
    raise SystemExit(main())
