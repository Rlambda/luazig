#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def run(cmd: list[str], *, cwd: Path, env: dict[str, str], timeout_s: int) -> tuple[int, str]:
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
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired as e:
        out = e.stdout or ""
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        return 124, (out + "\nerror: timeout\n")


def ensure_binaries(root: Path) -> None:
    subprocess.check_call(["make", "-s", "lua-c"], cwd=str(root))
    subprocess.check_call([str(root / "tools" / "zig"), "build"], cwd=str(root))


def short_reason(output: str) -> str:
    for line in output.splitlines():
        s = line.strip()
        if not s:
            continue
        if "assertion failed" in s:
            return "assertion failed"
        if s.startswith("error:"):
            return s
    return (output.splitlines()[-1].strip() if output.strip() else "no output")


def main() -> int:
    ap = argparse.ArgumentParser(description="Per-file status for upstream Lua testes (*.lua): ref vs zig")
    ap.add_argument("--tests-dir", default="third_party/lua-upstream/testes")
    ap.add_argument("--prelude", default="_port=true; _soft=true")
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--max-files", type=int, default=0, help="0 means all")
    ap.add_argument("--json-out", default="", help="optional path for JSON report")
    ap.add_argument("--no-build", action="store_true")
    args = ap.parse_args()

    root = repo_root()
    tests_dir = (root / args.tests_dir).resolve()
    if not tests_dir.exists():
        print(f"error: tests dir not found: {tests_dir}", file=sys.stderr)
        return 2

    if not args.no_build:
        ensure_binaries(root)

    ref_lua = (root / "build/lua-c/lua").resolve()
    ref_luac = (root / "build/lua-c/luac").resolve()
    zig_lua = (root / "zig-out/bin/luazig").resolve()

    base_env = os.environ.copy()
    base_env["LUAZIG_C_LUA"] = str(ref_lua)
    base_env["LUAZIG_C_LUAC"] = str(ref_luac)

    files = sorted(p for p in tests_dir.glob("*.lua") if p.name != "main.lua")
    if args.max_files > 0:
        files = files[: args.max_files]

    rows: list[dict[str, object]] = []
    for path in files:
        rel = path.name
        ref_cmd = [str(ref_lua)]
        zig_cmd = [str(zig_lua), "--engine=zig"]
        if args.prelude:
            ref_cmd += ["-e", args.prelude]
            zig_cmd += ["-e", args.prelude]
        ref_cmd.append(rel)
        zig_cmd.append(rel)

        ref_code, ref_out = run(ref_cmd, cwd=tests_dir, env=base_env, timeout_s=args.timeout)
        zig_code, zig_out = run(zig_cmd, cwd=tests_dir, env=base_env, timeout_s=args.timeout)

        if ref_code == 0 and zig_code == 0:
            cls = "pass"
        elif ref_code == 0 and zig_code != 0:
            cls = "zig_fail"
        elif ref_code != 0 and zig_code == 0:
            cls = "zig_only_pass"
        else:
            cls = "both_fail"

        rows.append(
            {
                "file": rel,
                "class": cls,
                "ref_exit": ref_code,
                "zig_exit": zig_code,
                "zig_reason": short_reason(zig_out) if zig_code != 0 else "",
                "ref_reason": short_reason(ref_out) if ref_code != 0 else "",
            }
        )

    total = len(rows)
    pass_n = sum(1 for r in rows if r["class"] == "pass")
    zig_fail_n = sum(1 for r in rows if r["class"] == "zig_fail")
    both_fail_n = sum(1 for r in rows if r["class"] == "both_fail")
    zig_only_pass_n = sum(1 for r in rows if r["class"] == "zig_only_pass")

    print(f"testes matrix: {pass_n}/{total} pass parity")
    print(f"  zig_fail={zig_fail_n} both_fail={both_fail_n} zig_only_pass={zig_only_pass_n}")
    print("")
    print("file\tclass\tzig_exit\treason")
    for r in rows:
        reason = r["zig_reason"] if r["class"] != "pass" else ""
        print(f"{r['file']}\t{r['class']}\t{r['zig_exit']}\t{reason}")

    if args.json_out:
        out_path = Path(args.json_out)
        payload = {
            "summary": {
                "total": total,
                "pass": pass_n,
                "zig_fail": zig_fail_n,
                "both_fail": both_fail_n,
                "zig_only_pass": zig_only_pass_n,
            },
            "rows": rows,
        }
        out_path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
        print(f"\njson: {out_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
