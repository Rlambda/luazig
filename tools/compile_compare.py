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
    return p.returncode, p.stdout


def read_list(path: Path) -> list[str]:
    lines: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        lines.append(s)
    return lines


def main() -> int:
    ap = argparse.ArgumentParser(description="Compare compile success: luac -p vs luazigc --engine=zig -p")
    ap.add_argument("--list", default="tests/compile_list.txt")
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--ref-luac", default="build/lua-c/luac")
    ap.add_argument("--zig-luazigc", default="zig-out/bin/luazigc")
    args = ap.parse_args()

    root = repo_root()
    lst_path = (root / args.list).resolve()
    if not lst_path.exists():
        print(f"error: list file not found: {lst_path}", file=sys.stderr)
        return 2

    files = read_list(lst_path)
    if not files:
        print("error: empty list", file=sys.stderr)
        return 2

    ref_luac = (root / args.ref_luac).resolve()
    zig_luazigc = (root / args.zig_luazigc).resolve()

    bad = 0
    for rel in files:
        p = (root / rel).resolve()
        if not p.exists():
            print(f"missing: {rel}")
            bad += 1
            continue

        ref_code, ref_out = run([str(ref_luac), "-p", str(p)], cwd=root, timeout_s=args.timeout)
        zig_code, zig_out = run([str(zig_luazigc), "--engine=zig", "-p", str(p)], cwd=root, timeout_s=args.timeout)

        ref_ok = ref_code == 0
        zig_ok = zig_code == 0

        if ref_ok == zig_ok:
            print(f"ok  {rel}  ({'pass' if ref_ok else 'fail'})")
            continue

        bad += 1
        print(f"DIFF {rel}")
        print(f"  ref exit={ref_code}")
        for line in ref_out.splitlines()[:3]:
            print(f"    {line}")
        print(f"  zig exit={zig_code}")
        for line in zig_out.splitlines()[:3]:
            print(f"    {line}")

    if bad:
        print(f"FAIL ({bad} mismatches)")
        return 1

    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

