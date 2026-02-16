#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def run(cmd: list[str], cwd: Path) -> tuple[int, str]:
    p = subprocess.run(
        cmd,
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return p.returncode, p.stdout


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Fast regression guard: deep recursion smoke + calls.lua parity"
    )
    ap.add_argument("--no-build", action="store_true", help="skip zig build")
    args = ap.parse_args()

    root = Path(__file__).resolve().parents[1]
    zig = root / "tools" / "zig"
    luazig = root / "zig-out" / "bin" / "luazig"

    if not args.no_build:
        code, out = run([str(zig), "build"], root)
        if code != 0:
            print("guard: build failed", file=sys.stderr)
            print(out, end="")
            return code

    deep_snippet = (
        "function deep(n) if n>0 then deep(n-1) end end; "
        "deep(180); print('ok')"
    )
    code, out = run([str(luazig), "-e", deep_snippet], root)
    if code != 0 or "ok" not in out:
        print("guard: deep recursion smoke failed", file=sys.stderr)
        print(out, end="")
        return 1

    code, out = run(
        ["python3", "tools/run_tests.py", "--suite", "calls.lua", "--no-build"], root
    )
    if code != 0:
        print("guard: calls.lua parity failed", file=sys.stderr)
        print(out, end="")
        return code

    print("guard: OK (deep recursion + calls.lua)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
