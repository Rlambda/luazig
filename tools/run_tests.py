#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path


def run(cmd: list[str], *, cwd: Path, env: dict[str, str], timeout_s: int) -> tuple[int, str]:
    p = subprocess.run(
        cmd,
        cwd=str(cwd),
        env=env,
        input="",
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout_s,
    )
    return p.returncode, p.stdout


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def ensure_ref_built(root: Path) -> None:
    # Build the in-tree reference Lua (C) so we always have a known baseline.
    subprocess.check_call(["make", "-s", "lua-c"], cwd=str(root))


def ensure_zig_built(root: Path) -> None:
    subprocess.check_call([str(root / "tools" / "zig"), "build"], cwd=str(root))


def build_test_libs(testes_dir: Path, lua_src_dir: Path) -> None:
    libs_dir = testes_dir / "libs"
    if not libs_dir.exists():
        return
    # Upstream tests expect shared libs under ./libs. Build them against our
    # vendored reference headers.
    subprocess.check_call(
        ["make", "-s", f"LUA_DIR={lua_src_dir}"],
        cwd=str(libs_dir),
    )


def normalize_output(s: str) -> str:
    # Keep normalization conservative; we can extend as diffs appear.
    s = s.replace("\r\n", "\n")
    lines: list[str] = []
    for line in s.splitlines():
        # Known volatile lines in the upstream suite (timing, randomness, temp paths, pids).
        if line.startswith("random seeds:"):
            continue
        if line.startswith("time:"):
            continue
        if "---- total memory:" in line:
            continue
        if "temporary program file used in these tests:" in line:
            continue
        if "pid " in line and "background" in line:
            continue
        if "testing length for some random tables (seeds " in line:
            # includes per-run seeds
            line = re.sub(r"\(seeds .*\)$", "(seeds <normalized>)", line)
        if line.startswith("testing short-circuit optimizations ("):
            line = re.sub(r"\(.*\)$", "(<normalized>)", line)
        if "sorting 50000" in line and "msec." in line:
            # sort.lua prints timings and counts
            line = re.sub(r"in [0-9.]+ msec\.", "in <ms> msec.", line)
        if "Invert-sorting" in line and "msec." in line:
            line = re.sub(r"in [0-9.]+ msec\.", "in <ms> msec.", line)
        if "with " in line and " comparisons" in line:
            line = re.sub(r"with [0-9]+ comparisons", "with <n> comparisons", line)
        if line.startswith("float random range in ") or line.startswith("integer random range in "):
            line = re.sub(r"in [0-9]+ calls: .*", "in <n> calls: <normalized>", line)
        lines.append(line)
    return "\n".join(lines) + ("\n" if s.endswith("\n") else "")


def main() -> int:
    ap = argparse.ArgumentParser(description="Differential runner: C Lua vs luazig")
    ap.add_argument("--tests-dir", default="third_party/lua-upstream/testes")
    ap.add_argument("--suite", default="all.lua", help="entrypoint file inside tests-dir")
    ap.add_argument("--timeout", type=int, default=600, help="timeout per engine run (seconds)")
    ap.add_argument(
        "--prelude",
        default="_port=true",
        help="Lua snippet executed via -e before running the suite (default: _port=true)",
    )
    ap.add_argument("--no-build", action="store_true", help="do not build reference/zig binaries")
    ap.add_argument("--no-libs", action="store_true", help="do not build upstream test C libs")
    ap.add_argument("--ref-lua", default="build/lua-c/lua")
    ap.add_argument("--ref-luac", default="build/lua-c/luac")
    ap.add_argument("--zig-lua", default="zig-out/bin/luazig")
    ap.add_argument(
        "--mode",
        choices=["compare", "ref", "zig", "selfcheck"],
        default="compare",
        help="compare: run both and diff; ref/zig: run one; selfcheck: ref vs ref",
    )
    args = ap.parse_args()

    root = repo_root()
    testes_dir = (root / args.tests_dir).resolve()
    suite = args.suite

    if not testes_dir.exists():
        print(f"error: tests dir not found: {testes_dir}", file=sys.stderr)
        return 2

    ref_lua = (root / args.ref_lua).resolve()
    ref_luac = (root / args.ref_luac).resolve()
    zig_lua = (root / args.zig_lua).resolve()

    if not args.no_build:
        ensure_ref_built(root)
        ensure_zig_built(root)

    if not args.no_libs:
        build_test_libs(testes_dir, (root / "lua-5.5.0" / "src").resolve())

    base_env = os.environ.copy()
    # Ensure luazig/luazigc delegation works regardless of cwd.
    base_env["LUAZIG_C_LUA"] = str(ref_lua)
    base_env["LUAZIG_C_LUAC"] = str(ref_luac)

    def run_engine(engine: str) -> tuple[int, str]:
        if engine == "ref":
            exe = str(ref_lua)
            cmd = [exe]
        elif engine == "zig":
            exe = str(zig_lua)
            # Force the Zig engine explicitly; don't rely on LUAZIG_ENGINE.
            cmd = [exe, "--engine=zig"]
        else:
            raise ValueError(engine)
        if args.prelude:
            cmd += ["-e", args.prelude]
        cmd += [suite]
        return run(cmd, cwd=testes_dir, env=base_env, timeout_s=args.timeout)

    if args.mode == "ref":
        code, out = run_engine("ref")
        sys.stdout.write(out)
        return code

    if args.mode == "zig":
        code, out = run_engine("zig")
        sys.stdout.write(out)
        return code

    if args.mode == "selfcheck":
        c1, o1 = run_engine("ref")
        c2, o2 = run_engine("ref")
        if c1 != c2 or normalize_output(o1) != normalize_output(o2):
            print("selfcheck failed: ref output differs from itself", file=sys.stderr)
            return 1
        print("selfcheck ok")
        return 0

    # compare
    ref_code, ref_out = run_engine("ref")
    zig_code, zig_out = run_engine("zig")

    ref_out_n = normalize_output(ref_out)
    zig_out_n = normalize_output(zig_out)

    ok = (ref_code == zig_code) and (ref_out_n == zig_out_n)
    if ok:
        print("ok: outputs match")
        return 0

    print("DIFF: outputs differ")
    print(f"ref exit={ref_code}, zig exit={zig_code}")
    ref_lines = ref_out_n.splitlines()
    zig_lines = zig_out_n.splitlines()
    first = None
    for i in range(min(len(ref_lines), len(zig_lines))):
        if ref_lines[i] != zig_lines[i]:
            first = i
            break
    if first is None and len(ref_lines) != len(zig_lines):
        first = min(len(ref_lines), len(zig_lines))

    if first is not None:
        print(f"first diff at line {first + 1}")
        lo = max(0, first - 5)
        hi = first + 6
        print("---- ref (context) ----")
        for j in range(lo, min(hi, len(ref_lines))):
            prefix = ">" if j == first else " "
            print(f"{prefix}{j+1:6d} {ref_lines[j]}")
        print("---- zig (context) ----")
        for j in range(lo, min(hi, len(zig_lines))):
            prefix = ">" if j == first else " "
            print(f"{prefix}{j+1:6d} {zig_lines[j]}")
    else:
        print("---- ref (first 200 lines) ----")
        print("\n".join(ref_lines[:200]))
        print("---- zig (first 200 lines) ----")
        print("\n".join(zig_lines[:200]))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
