#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def run(cmd: list[str], *, cwd: Path, timeout_s: int) -> tuple[int, str]:
    p = subprocess.run(
        cmd,
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout_s,
    )
    out = p.stdout.replace("\r\n", "\n")
    return p.returncode, out


def discover_files(root: Path, d: str, globs: list[str]) -> list[str]:
    base = (root / d).resolve()
    if not base.exists():
        raise FileNotFoundError(str(base))
    out: list[str] = []
    seen: set[str] = set()
    for g in globs:
        for p in base.rglob(g):
            if not p.is_file():
                continue
            rel = p.relative_to(root).as_posix()
            if rel in seen:
                continue
            seen.add(rel)
            out.append(rel)
    out.sort()
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Differential smoke runner: C Lua vs luazig --engine=zig")
    ap.add_argument("--tests-dir", default="tests/smoke")
    ap.add_argument("--glob", action="append", default=["*.lua"])
    ap.add_argument("--timeout", type=int, default=30, help="timeout per engine run (seconds)")
    ap.add_argument("--no-build", action="store_true", help="do not build reference/zig binaries")
    ap.add_argument("--ref-lua", default="build/lua-c/lua")
    ap.add_argument("--zig-lua", default="zig-out/bin/luazig")
    args = ap.parse_args()

    root = repo_root()
    try:
        files = discover_files(root, args.tests_dir, args.glob)
    except FileNotFoundError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    if not files:
        print("error: no files discovered", file=sys.stderr)
        return 2

    ref_lua = (root / args.ref_lua).resolve()
    zig_lua = (root / args.zig_lua).resolve()

    if not args.no_build:
        subprocess.check_call(["make", "-s", "lua-c"], cwd=str(root))
        subprocess.check_call([str(root / "tools" / "zig"), "build"], cwd=str(root))

    bad = 0
    for rel in files:
        p = (root / rel).resolve()
        if not p.exists():
            print(f"missing: {rel}")
            bad += 1
            continue

        ref_code, ref_out = run([str(ref_lua), str(p)], cwd=root, timeout_s=args.timeout)
        zig_code, zig_out = run([str(zig_lua), "--engine=zig", str(p)], cwd=root, timeout_s=args.timeout)

        ok = (ref_code == zig_code) and (ref_out == zig_out)
        if ok:
            print(f"ok  {rel}")
            continue

        bad += 1
        print(f"DIFF {rel}")
        print(f"  ref exit={ref_code}")
        for line in ref_out.splitlines()[:10]:
            print(f"    {line}")
        print(f"  zig exit={zig_code}")
        for line in zig_out.splitlines()[:10]:
            print(f"    {line}")

    if bad:
        print(f"FAIL ({bad} mismatches)")
        return 1

    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

