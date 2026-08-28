#!/usr/bin/env python3
"""native_mem_check.py — RSS slope verdict for native-memory leak detection.

Runs a given Lua file at 2+ iteration counts (passed as arg[1]) and measures
each run's peak resident set size (RSS) via the child rusage returned by
`os.wait4`. From the per-run `ru_maxrss` (KB on Linux) it computes the RSS
slope (MB per decade of iterations) and prints a BOUNDED/LINEAR verdict.

Why rusage, not /proc/<pid>/status:
  The previous implementation did `proc.wait()` and *then* read
  `/proc/<pid>/status` for VmHWM. By that point the process was already gone,
  so the open() raised FileNotFoundError, get_vmhwm() returned 0, and every
  run reported "0.00 MB" — making the slope 0 and the verdict BOUNDED
  regardless of reality (false-green lane). `os.wait4` returns the child's
  aggregate rusage as part of the wait call itself, so `ru_maxrss` reflects
  the true high-water mark RSS even though the process has exited.

Usage:
    python3 tools/native_mem_check.py <lua_file> [iteration_counts...]
    python3 tools/native_mem_check.py /tmp/co_mem.lua 100000 300000 1000000
    python3 tools/native_mem_check.py --selftest

Defaults to 100000, 300000, 1000000 iterations.
Exit code: 0 = BOUNDED, 1 = LINEAR (leak detected), 2 = usage/error,
           3 = child crashed (signal termination) — treated as a hard failure.
"""

import subprocess
import sys
import os
import math

DEFAULT_ITERATIONS = [100000, 300000, 1000000]
# Threshold: MB of RSS growth per decade (10x) of iterations.
# Bounded programs show <1 MB/decade after warmup; linear leaks show 10+.
LINEAR_THRESHOLD_MB_PER_DECADE = 5.0


def run_and_measure(luazig_path, lua_file, iterations):
    """Run luazig with the given file and iterations.

    Returns (ru_maxrss_kb, stdout_str). Measurement comes from the child
    rusage returned by os.wait4 (ru_maxrss is in KB on Linux). Child stdout
    is captured for informational purposes only — it does NOT drive the
    measurement. If the child terminates via signal, raises SystemExit(3).
    """
    proc = subprocess.Popen(
        [luazig_path, lua_file, str(iterations)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    # os.wait4 reaps the child AND returns its aggregate rusage. ru_maxrss is
    # the peak RSS over the child's lifetime in kilobytes (Linux). This is
    # read atomically with the wait, so there is no after-exit /proc race.
    pid, status, rusage = os.wait4(proc.pid, 0)
    stdout = proc.stdout.read().decode("utf-8", errors="replace").strip()
    # Drain stderr to avoid resource warnings (not used for measurement).
    proc.stderr.read()

    # Check exit status: signal termination or nonzero exit is a hard failure.
    if os.WIFSIGNALED(status):
        sig = os.WTERMSIG(status)
        print(
            f"  [child killed by signal {sig} at {iterations} iters]",
            file=sys.stderr,
        )
        sys.exit(3)
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1
        print(
            f"  [child exited nonzero ({code}) at {iterations} iters]",
            file=sys.stderr,
        )
        sys.exit(3)

    return rusage.ru_maxrss, stdout


def measure_runs(luazig_path, lua_file, iterations, verbose=True):
    """Run the workload at each iteration count, return list of (iters, mb, stdout)."""
    results = []
    for iters in iterations:
        rss_kb, stdout = run_and_measure(luazig_path, lua_file, iters)
        rss_mb = rss_kb / 1024.0
        results.append((iters, rss_mb, stdout))
        if verbose:
            print(f"  {iters:>10d} iters  RSS={rss_mb:>8.2f} MB  stdout: {stdout}")
    return results


def verdict_from_results(results):
    """Compute slope (MB/decade) and verdict from measured runs.

    Returns (verdict, slope, warmup_delta).
    """
    iters1, mb1, _ = results[-2]
    iters2, mb2, _ = results[-1]
    decades = math.log10(iters2 / iters1) if iters1 > 0 else 1
    delta_mb = mb2 - mb1
    slope = delta_mb / decades if decades > 0 else 0

    if len(results) >= 3:
        iters0, mb0, _ = results[0]
        warmup_delta = mb1 - mb0
    else:
        warmup_delta = mb1 - results[0][1]

    verdict = "BOUNDED" if slope < LINEAR_THRESHOLD_MB_PER_DECADE else "LINEAR"
    return verdict, slope, warmup_delta


def find_luazig():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    luazig_path = os.path.join(repo_root, "zig-out", "bin", "luazig")
    if not os.path.exists(luazig_path):
        print(f"luazig binary not found at {luazig_path}", file=sys.stderr)
        sys.exit(2)
    return luazig_path


def run_main(lua_file, iterations):
    luazig_path = find_luazig()

    print(f"File: {lua_file}")
    print(f"Iterations: {iterations}")
    print()

    results = measure_runs(luazig_path, lua_file, iterations)
    print()

    verdict, slope, warmup_delta = verdict_from_results(results)
    print(f"Warmup delta:     {warmup_delta:>8.2f} MB")
    print(f"Slope (last 2):   {slope:>8.2f} MB/decade")
    print(f"Threshold:        {LINEAR_THRESHOLD_MB_PER_DECADE:>8.2f} MB/decade")
    print(f"Verdict:          {verdict}")

    if verdict == "LINEAR":
        sys.exit(1)


def selftest():
    """Discriminating self-test: a bounded child and a growing child.

    Bounded child: allocates a FIXED ~8MB regardless of N (fixed count of
      10KB strings, ignores arg[1]). Expected verdict: BOUNDED.
    Growing child: allocates proportional to N (N * 200B strings retained).
      Expected verdict: LINEAR (RSS grows across iteration points).

    Both children are Lua scripts run through luazig itself. The self-test
    proves the instrument discriminates: BOUNDED for the fixed allocator,
    LINEAR for the proportional allocator.
    """
    luazig_path = find_luazig()
    selftest_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "native_mem_check_selftest")
    os.makedirs(selftest_dir, exist_ok=True)

    bounded_lua = os.path.join(selftest_dir, "bounded.lua")
    growing_lua = os.path.join(selftest_dir, "growing.lua")

    with open(bounded_lua, "w") as f:
        # Fixed ~8MB allocation: 800 * 10KB = ~8MB, independent of arg[1].
        f.write(
            'local t = {}\n'
            'for i = 1, 800 do t[i] = string.rep("x", 10240) end\n'
            '-- keep references alive until exit\n'
            'assert(t[800] ~= nil)\n'
        )
    with open(growing_lua, "w") as f:
        # Proportional allocation: N * 200B retained. arg[1] drives growth.
        f.write(
            'local n = tonumber(arg[1]) or 100000\n'
            'local t = {}\n'
            'for i = 1, n do t[i] = string.rep("y", 200) end\n'
            'assert(t[n] ~= nil)\n'
        )

    # Iteration counts chosen so the growing child's RSS spans a clear range:
    # 100k*200B = ~20MB, 1M*200B = ~200MB — well above the 5 MB/decade threshold.
    iters = [100000, 1000000]

    print("=== selftest: bounded child (fixed ~8MB) ===")
    bounded_results = measure_runs(luazig_path, bounded_lua, iters)
    bounded_verdict, bounded_slope, _ = verdict_from_results(bounded_results)
    print(f"  verdict: {bounded_verdict}  slope: {bounded_slope:.2f} MB/decade")
    print()

    print("=== selftest: growing child (N*200B) ===")
    growing_results = measure_runs(luazig_path, growing_lua, iters)
    growing_verdict, growing_slope, _ = verdict_from_results(growing_results)
    print(f"  verdict: {growing_verdict}  slope: {growing_slope:.2f} MB/decade")
    print()

    ok = True
    if bounded_verdict != "BOUNDED":
        print(f"FAIL: bounded child got {bounded_verdict}, expected BOUNDED",
              file=sys.stderr)
        ok = False
    if growing_verdict != "LINEAR":
        print(f"FAIL: growing child got {growing_verdict}, expected LINEAR",
              file=sys.stderr)
        ok = False

    if ok:
        print("selftest PASS: instrument discriminates (bounded=BOUNDED, growing=LINEAR)")
        sys.exit(0)
    else:
        print("selftest FAIL", file=sys.stderr)
        sys.exit(1)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--selftest":
        selftest()

    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <lua_file> [iteration_counts...]")
        print(f"       {sys.argv[0]} --selftest")
        sys.exit(2)

    lua_file = sys.argv[1]
    iterations = [int(x) for x in sys.argv[2:]] if len(sys.argv) > 2 else DEFAULT_ITERATIONS

    if len(iterations) < 2:
        print("Need at least 2 iteration counts", file=sys.stderr)
        sys.exit(2)

    run_main(lua_file, iterations)


if __name__ == "__main__":
    main()
