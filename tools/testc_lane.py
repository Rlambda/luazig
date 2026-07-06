#!/usr/bin/env python3
import argparse
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LUAZIG = ROOT / "zig-out" / "bin" / "luazig"
TESTES = ROOT / "lua-5.5.0" / "testes"
DEFAULT_SUITES = [
    "api.lua",
    "coroutine.lua",
    "errors.lua",
    "strings.lua",
    "locals.lua",
    "memerr.lua",
]


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the official upstream testC lane against luazig.")
    parser.add_argument("--timeout", type=int, default=120, help="Per-suite timeout in seconds.")
    parser.add_argument("suites", nargs="*", default=DEFAULT_SUITES)
    args = parser.parse_args()

    overall_rc = 0
    for name in args.suites:
        path = TESTES / name
        if not path.exists():
            print(f"{name}: missing", file=sys.stderr)
            overall_rc = 1
            continue
        t0 = time.time()
        proc = subprocess.run(
            [str(LUAZIG), "--testc", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=args.timeout,
            cwd=TESTES,
        )
        dt = time.time() - t0
        lines = [line for line in (proc.stdout.splitlines() + proc.stderr.splitlines()) if line.strip()]
        tail = lines[-1] if lines else ""
        status = "ok" if proc.returncode == 0 else "fail"
        print(f"{name}: {status} rc={proc.returncode} time={dt:.2f}s tail={tail}")
        if proc.returncode != 0:
            overall_rc = 1
    return overall_rc


if __name__ == "__main__":
    raise SystemExit(main())
