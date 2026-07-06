#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def run(cmd: list[str], cwd: Path, env: dict[str, str], timeout_s: int) -> tuple[int, float]:
    t0 = time.perf_counter()
    p = subprocess.run(cmd, cwd=str(cwd), env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout_s)
    return p.returncode, time.perf_counter() - t0


def main() -> int:
    ap = argparse.ArgumentParser(description="Capture core perf snapshot for luazig")
    ap.add_argument("--out", default="tools/perf/core_current.json")
    ap.add_argument("--timeout", type=int, default=240)
    ap.add_argument("--prelude", default="_port=true; _soft=true")
    ap.add_argument("--suites", default="nextvar.lua,coroutine.lua,gc.lua")
    args = ap.parse_args()

    root = repo_root()
    tests = root / "lua-5.5.0" / "testes"
    ref = root / "build" / "lua-c" / "lua"
    zig = root / "zig-out" / "bin" / "luazig"

    env = os.environ.copy()
    env["LUAZIG_C_LUA"] = str(ref)
    env["LUAZIG_C_LUAC"] = str(root / "build" / "lua-c" / "luac")

    rows: dict[str, dict[str, float | int]] = {}
    for suite in [s.strip() for s in args.suites.split(",") if s.strip()]:
        ref_cmd = [str(ref), "-e", args.prelude, suite]
        zig_cmd = [str(zig), "-e", args.prelude, suite]
        ref_exit, ref_t = run(ref_cmd, tests, env, args.timeout)
        zig_exit, zig_t = run(zig_cmd, tests, env, args.timeout)
        rows[suite] = {
            "ref_exit": ref_exit,
            "zig_exit": zig_exit,
            "ref_time_s": round(ref_t, 6),
            "zig_time_s": round(zig_t, 6),
        }

    payload = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "suites": rows,
    }

    out = (root / args.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
