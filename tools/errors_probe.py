#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


CASES: list[tuple[str, str]] = [
    ("a = {} + 1", "arithmetic"),
    ("a = {} | 1", "bitwise operation"),
    ("a = {} < 1", "attempt to compare"),
    ("a = {} <= 1", "attempt to compare"),
    ("aaa=1; bbbb=2; aaa=math.sin(3)+bbbb(3)", "global 'bbbb'"),
    ("aaa={}; do local aaa=1 end aaa:bbbb(3)", "method 'bbbb'"),
    ("local a={}; a.bbbb(3)", "field 'bbbb'"),
    ("aaa={13}; local bbbb=1; aaa[bbbb](3)", "number"),
    ("aaa=(1)..{}", "a table value"),
    ("a = {_ENV = {}}; print(a._ENV.x + 1)", "field 'x'"),
    ("print(('_ENV').x + 1)", "field 'x'"),
]


def run_one(bin_path: Path, program: str) -> str:
    cmd = [str(bin_path), "-e", program]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    out = p.stdout.strip().splitlines()
    return out[0] if out else ""


def main() -> int:
    ap = argparse.ArgumentParser(description="Probe first failing errors.lua checkmessage case")
    ap.add_argument("--ref", default="build/lua-c/lua")
    ap.add_argument("--zig", default="zig-out/bin/luazig")
    args = ap.parse_args()

    root = Path(__file__).resolve().parents[1]
    ref = (root / args.ref).resolve()
    zig = (root / args.zig).resolve()

    failed = False
    for idx, (prog, needle) in enumerate(CASES, start=1):
        ref_msg = run_one(ref, prog)
        zig_msg = run_one(zig, prog)
        ok_ref = needle in ref_msg
        ok_zig = needle in zig_msg
        if ok_ref and ok_zig:
            print(f"[{idx:02d}] ok: {needle}")
            continue
        failed = True
        print(f"[{idx:02d}] FAIL")
        print(f"  program: {prog}")
        print(f"  needle : {needle}")
        print(f"  ref    : {ref_msg}")
        print(f"  zig    : {zig_msg}")
        break

    if not failed:
        print("all probe cases matched")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
