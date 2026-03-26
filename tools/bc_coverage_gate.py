#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def run_suite(root: Path, suite: str, prelude: str, timeout: int) -> dict[str, int]:
    zig = root / "zig-out" / "bin" / "luazig"
    testes = root / "third_party" / "lua-upstream" / "testes"
    with tempfile.NamedTemporaryFile(prefix="bc-cov-", suffix=".json", delete=False) as tmp:
        cov_path = Path(tmp.name)
    try:
        cmd = [str(zig), "--vm=bc", "--bc-coverage-out", str(cov_path)]
        if prelude:
            cmd += ["-e", prelude]
        cmd += [suite]
        p = subprocess.run(
            cmd,
            cwd=str(testes),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
        )
        if p.returncode != 0:
            print(f"suite failed: {suite}\n{p.stdout}")
            raise SystemExit(1)
        return json.loads(cov_path.read_text(encoding="utf-8"))
    finally:
        cov_path.unlink(missing_ok=True)


def main() -> int:
    ap = argparse.ArgumentParser(description="Check BC lowering/fallback coverage gate")
    ap.add_argument("--mode", choices=["bootstrap", "suites"], default="bootstrap")
    ap.add_argument("--suites", default="nextvar.lua,coroutine.lua,calls.lua")
    ap.add_argument("--chunks", default="return 42,local a=40+2; return a")
    ap.add_argument("--prelude", default="_port=true; _soft=true")
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--min-function-ratio", type=float, default=0.05)
    ap.add_argument("--min-inst-ratio", type=float, default=0.05)
    args = ap.parse_args()

    root = repo_root()

    total = {
        "total_functions": 0,
        "lowered_functions": 0,
        "fallback_functions": 0,
        "total_insts": 0,
        "lowered_insts": 0,
        "fallback_insts": 0,
    }

    if args.mode == "suites":
        suites = [s.strip() for s in args.suites.split(",") if s.strip()]
        for suite in suites:
            row = run_suite(root, suite, args.prelude, args.timeout)
            for k in total:
                total[k] += int(row.get(k, 0))
    else:
        zig = root / "zig-out" / "bin" / "luazig"
        for chunk in [c.strip() for c in args.chunks.split(",") if c.strip()]:
            with tempfile.NamedTemporaryFile(prefix="bc-cov-", suffix=".json", delete=False) as tmp:
                cov_path = Path(tmp.name)
            try:
                cmd = [str(zig), "--vm=bc", "--bc-coverage-out", str(cov_path), "-e", chunk]
                p = subprocess.run(
                    cmd,
                    cwd=str(root),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    timeout=args.timeout,
                )
                if p.returncode != 0:
                    print(f"chunk failed: {chunk}\n{p.stdout}")
                    return 1
                row = json.loads(cov_path.read_text(encoding="utf-8"))
                for k in total:
                    total[k] += int(row.get(k, 0))
            finally:
                cov_path.unlink(missing_ok=True)

    fn_ratio = (total["lowered_functions"] / total["total_functions"]) if total["total_functions"] else 0.0
    inst_ratio = (total["lowered_insts"] / total["total_insts"]) if total["total_insts"] else 0.0

    print(
        f"bc coverage: function_ratio={fn_ratio:.3f} "
        f"inst_ratio={inst_ratio:.3f} totals={total}"
    )

    if fn_ratio < args.min_function_ratio:
        print(
            f"gate failed: function_ratio {fn_ratio:.3f} < {args.min_function_ratio:.3f}",
        )
        return 1
    if inst_ratio < args.min_inst_ratio:
        print(
            f"gate failed: inst_ratio {inst_ratio:.3f} < {args.min_inst_ratio:.3f}",
        )
        return 1

    print("gate ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
