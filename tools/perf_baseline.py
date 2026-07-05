#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def run(cmd: list[str], *, cwd: Path, env: dict[str, str], timeout_s: int) -> tuple[int, str, float]:
    t0 = time.perf_counter()
    try:
        p = subprocess.run(
            cmd,
            cwd=str(cwd),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout_s,
        )
        dt = time.perf_counter() - t0
        return p.returncode, p.stdout, dt
    except subprocess.TimeoutExpired as e:
        out = e.stdout or ""
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        dt = time.perf_counter() - t0
        return 124, out + "\nerror: timeout\n", dt


def short_reason(out: str) -> str:
    for line in out.splitlines():
        s = line.strip()
        if not s:
            continue
        if "assertion failed" in s:
            return "assertion failed"
        if s.startswith("error:"):
            return s
    return out.splitlines()[-1].strip() if out.strip() else ""


def ensure_ref(root: Path) -> None:
    subprocess.check_call(["make", "-s", "lua-c"], cwd=str(root))


def build_profile(root: Path, optimize: str) -> None:
    subprocess.check_call(["zig", "build", f"-Doptimize={optimize}"], cwd=str(root))


def collect_matrix_summary(root: Path) -> dict[str, int]:
    out_json = root / "tools" / "perf" / "matrix-summary.tmp.json"
    cmd = [
        "python3",
        "tools/testes_matrix.py",
        "--no-build",
        "--timeout",
        "120",
        "--json-out",
        str(out_json),
    ]
    p = subprocess.run(cmd, cwd=str(root), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0 or not out_json.exists():
        return {"total": 0, "pass": 0, "zig_fail": 0, "both_fail": 0, "both_fail_infra": 0, "zig_only_pass": 0}
    payload = json.loads(out_json.read_text(encoding="utf-8"))
    try:
        out_json.unlink()
    except OSError:
        pass
    s = payload.get("summary", {})
    return {
        "total": int(s.get("total", 0)),
        "pass": int(s.get("pass", 0)),
        "zig_fail": int(s.get("zig_fail", 0)),
        "both_fail": int(s.get("both_fail", 0)),
        "both_fail_infra": int(s.get("both_fail_infra", 0)),
        "zig_only_pass": int(s.get("zig_only_pass", 0)),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Collect performance baseline for luazig")
    ap.add_argument("--out", default="tools/perf/baseline.json")
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--profiles", default="Debug,ReleaseFast")
    args = ap.parse_args()

    root = repo_root()
    out_path = (root / args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    ensure_ref(root)
    ref_lua = (root / "build/lua-c/lua").resolve()
    zig_lua = (root / "zig-out/bin/luazig").resolve()
    tests_dir = (root / "third_party/lua-upstream/testes").resolve()

    suites = [
        "nextvar.lua",
        "math.lua",
        "coroutine.lua",
        "gc.lua",
    ]
    micro = {
        "arith_loop": "local s=0 for i=1,2000000 do s=s+i end print(s)",
        "table_loop": "local t={} for i=1,400000 do t[i]=i end local s=0 for i=1,400000 do s=s+t[i] end print(s)",
        "call_loop": "local function f(x) return x+1 end local s=0 for i=1,1200000 do s=f(s) end print(s)",
    }

    base_env = os.environ.copy()
    base_env["LUAZIG_C_LUA"] = str(ref_lua)
    base_env["LUAZIG_C_LUAC"] = str((root / "build/lua-c/luac").resolve())

    profiles = [p.strip() for p in args.profiles.split(",") if p.strip()]
    results: dict[str, dict[str, dict[str, object]]] = {}

    for prof in profiles:
        if not args.no_build:
            build_profile(root, prof)

        prof_rows: dict[str, dict[str, object]] = {}
        for suite in suites:
            prelude = "_port=true; _soft=true"
            ref_cmd = [str(ref_lua), "-e", prelude, suite]
            zig_cmd = [str(zig_lua), "-e", prelude, suite]
            ref_code, ref_out, ref_t = run(ref_cmd, cwd=tests_dir, env=base_env, timeout_s=args.timeout)
            zig_code, zig_out, zig_t = run(zig_cmd, cwd=tests_dir, env=base_env, timeout_s=args.timeout)
            row: dict[str, object] = {
                "kind": "suite",
                "ref_exit": ref_code,
                "zig_exit": zig_code,
                "ref_time_s": round(ref_t, 6),
                "zig_time_s": round(zig_t, 6),
                "ref_reason": short_reason(ref_out) if ref_code != 0 else "",
                "zig_reason": short_reason(zig_out) if zig_code != 0 else "",
            }
            if ref_code == 0 and zig_code == 0 and ref_t > 0:
                row["zig_vs_ref_ratio"] = round(zig_t / ref_t, 6)
            prof_rows[suite] = row

        for name, code in micro.items():
            ref_cmd = [str(ref_lua), "-e", code]
            zig_cmd = [str(zig_lua), "-e", code]
            ref_code, ref_out, ref_t = run(ref_cmd, cwd=root, env=base_env, timeout_s=args.timeout)
            zig_code, zig_out, zig_t = run(zig_cmd, cwd=root, env=base_env, timeout_s=args.timeout)
            row = {
                "kind": "microbench",
                "ref_exit": ref_code,
                "zig_exit": zig_code,
                "ref_time_s": round(ref_t, 6),
                "zig_time_s": round(zig_t, 6),
                "ref_reason": short_reason(ref_out) if ref_code != 0 else "",
                "zig_reason": short_reason(zig_out) if zig_code != 0 else "",
            }
            if ref_code == 0 and zig_code == 0 and ref_t > 0:
                row["zig_vs_ref_ratio"] = round(zig_t / ref_t, 6)
            prof_rows[name] = row

        results[prof] = prof_rows

    if "Debug" in profiles and not args.no_build:
        build_profile(root, "Debug")

    payload = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "host": {
            "platform": platform.platform(),
            "python": platform.python_version(),
        },
        "matrix_summary": collect_matrix_summary(root),
        "results": results,
    }
    out_path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
