#!/usr/bin/env python3
from __future__ import annotations

import os
import shlex
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    flags = shlex.split(os.environ.get("LUAZIG_ZIG_BUILD_FLAGS", ""))
    cmd = [str(ROOT / "tools" / "zig"), "build", "test", "-Doptimize=Debug", *flags]
    print("==> public Zig API integration lane", flush=True)
    print("$ " + " ".join(cmd), flush=True)
    t0 = time.time()
    proc = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    dt = time.time() - t0
    if proc.stdout:
        print(proc.stdout, end="")
    status = "ok" if proc.returncode == 0 else "fail"
    print(f"<== public Zig API integration lane: {status} rc={proc.returncode} time={dt:.2f}s", flush=True)
    return proc.returncode


if __name__ == "__main__":
    raise SystemExit(main())
