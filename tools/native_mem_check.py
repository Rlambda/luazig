#!/usr/bin/env python3
"""native_mem_check.py — RSS slope verdict for native-memory leak detection.

Runs a given Lua file at 2+ iteration counts (passed as arg[1]), samples
VmHWM from /proc/<pid>/status, and prints a LINEAR/BOUNDED verdict.

Usage:
    python3 tools/native_mem_check.py <lua_file> [iteration_counts...]
    python3 tools/native_mem_check.py /tmp/co_mem.lua 100000 300000 1000000

Defaults to 100000, 300000, 1000000 iterations.
Exit code: 0 = BOUNDED, 1 = LINEAR (leak detected).
"""

import subprocess
import sys
import os
import re
import math

DEFAULT_ITERATIONS = [100000, 300000, 1000000]
# Threshold: MB of RSS growth per decade (10x) of iterations.
# Bounded programs show <1 MB/decade after warmup; linear leaks show 10+.
LINEAR_THRESHOLD_MB_PER_DECADE = 5.0


def get_vmhwm(pid):
    """Read VmHWM (high-water mark RSS) in KB from /proc/<pid>/status."""
    try:
        with open(f"/proc/{pid}/status", "r") as f:
            for line in f:
                if line.startswith("VmHWM:"):
                    return int(line.split()[1])
    except (FileNotFoundError, IndexError, ValueError):
        pass
    return 0


def run_and_measure(luazig_path, lua_file, iterations):
    """Run luazig with the given file and iterations, return VmHWM in KB."""
    proc = subprocess.Popen(
        [luazig_path, lua_file, str(iterations)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    proc.wait()
    vmhwm = get_vmhwm(proc.pid)
    stdout = proc.stdout.read().decode("utf-8", errors="replace").strip()
    return vmhwm, stdout


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <lua_file> [iteration_counts...]")
        sys.exit(2)

    lua_file = sys.argv[1]
    iterations = [int(x) for x in sys.argv[2:]] if len(sys.argv) > 2 else DEFAULT_ITERATIONS

    if len(iterations) < 2:
        print("Need at least 2 iteration counts", file=sys.stderr)
        sys.exit(2)

    # Find luazig binary
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    luazig_path = os.path.join(repo_root, "zig-out", "bin", "luazig")
    if not os.path.exists(luazig_path):
        # Try Debug build location
        luazig_path = os.path.join(repo_root, "zig-out", "bin", "luazig")
        if not os.path.exists(luazig_path):
            print(f"luazig binary not found at {luazig_path}", file=sys.stderr)
            sys.exit(2)

    print(f"File: {lua_file}")
    print(f"Iterations: {iterations}")
    print()

    results = []
    for iters in iterations:
        vmhwm_kb, stdout = run_and_measure(luazig_path, lua_file, iters)
        vmhwm_mb = vmhwm_kb / 1024.0
        results.append((iters, vmhwm_mb, stdout))
        print(f"  {iters:>10d} iters  VmHWM={vmhwm_mb:>8.2f} MB  stdout: {stdout}")

    print()

    # Compute slope: MB per decade (10x iterations)
    # Use the last two points (after warmup) for the slope.
    if len(results) >= 2:
        iters1, mb1, _ = results[-2]
        iters2, mb2, _ = results[-1]
        decades = math.log10(iters2 / iters1) if iters1 > 0 else 1
        delta_mb = mb2 - mb1
        slope = delta_mb / decades if decades > 0 else 0

        # Also compute warmup delta (first to second point)
        if len(results) >= 3:
            iters0, mb0, _ = results[0]
            warmup_delta = mb1 - mb0
        else:
            warmup_delta = mb1 - results[0][1]

        verdict = "BOUNDED" if slope < LINEAR_THRESHOLD_MB_PER_DECADE else "LINEAR"
        print(f"Warmup delta:     {warmup_delta:>8.2f} MB")
        print(f"Slope (last 2):   {slope:>8.2f} MB/decade")
        print(f"Threshold:        {LINEAR_THRESHOLD_MB_PER_DECADE:>8.2f} MB/decade")
        print(f"Verdict:          {verdict}")

        if verdict == "LINEAR":
            sys.exit(1)
    else:
        print("Not enough data points", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
