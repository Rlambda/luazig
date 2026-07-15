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


def parse_timeout_overrides(raw: str) -> dict[str, int]:
    out: dict[str, int] = {}
    s = raw.strip()
    if not s:
        return out
    for item in s.split(","):
        pair = item.strip()
        if not pair:
            continue
        if "=" not in pair:
            raise ValueError(f"invalid timeout override '{pair}', expected name=seconds")
        name, sec_s = pair.split("=", 1)
        name = name.strip()
        sec_s = sec_s.strip()
        if not name:
            raise ValueError(f"invalid timeout override '{pair}', empty file name")
        try:
            sec = int(sec_s)
        except ValueError as e:
            raise ValueError(f"invalid timeout override '{pair}', seconds must be int") from e
        if sec <= 0:
            raise ValueError(f"invalid timeout override '{pair}', seconds must be > 0")
        out[name] = sec
    return out


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
    subprocess.check_call(["zig", "build"], cwd=str(root))


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


def is_sandbox_dev_full_denied(out: str) -> bool:
    return ("/dev/full" in out) and ("Permission denied" in out)


def snapshot_all_lua_time_files(tests_dir: Path) -> dict[str, bytes | None]:
    """Capture upstream timing fixtures before all.lua mutates them."""
    return {
        name: ((tests_dir / name).read_bytes() if (tests_dir / name).exists() else None)
        for name in ("time.txt", "time-debug.txt")
    }


def clear_all_lua_time_files(tests_dir: Path) -> None:
    for name in ("time.txt", "time-debug.txt"):
        (tests_dir / name).unlink(missing_ok=True)


def restore_all_lua_time_files(tests_dir: Path, snapshot: dict[str, bytes | None]) -> None:
    for name, contents in snapshot.items():
        path = tests_dir / name
        if contents is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(contents)


def main() -> int:
    ap = argparse.ArgumentParser(description="Per-file status for upstream Lua testes (*.lua): ref vs zig")
    ap.add_argument("--tests-dir", default="lua-5.5.0/testes")
    ap.add_argument("--prelude", default="", help="Lua code to run before each test (empty = no prelude)")
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument(
        "--timeout-overrides",
        default="",
        help="comma-separated per-file timeout overrides, e.g. 'all.lua=300,heavy.lua=240'",
    )
    ap.add_argument("--max-files", type=int, default=0, help="0 means all")
    ap.add_argument("--json-out", default="", help="optional path for JSON report")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--no-ref", action="store_true", help="skip running PUC Lua reference (only test zig)")
    ap.add_argument("--testc", action="store_true", help="enable testC module (--testc flag for zig)")
    ap.add_argument("--soft", action="store_true", help="add _soft=true to prelude")
    ap.add_argument("--port", action="store_true", help="add _port=true to prelude")
    ap.add_argument("--include-all", action="store_true", help="include all.lua, heavy.lua, verybig.lua")
    args = ap.parse_args()

    # Build prelude from flags if not explicitly set.
    if args.prelude:
        prelude = args.prelude
    else:
        parts: list[str] = []
        if args.port:
            parts.append("_port=true")
        if args.soft:
            parts.append("_soft=true")
        prelude = "; ".join(parts)
    try:
        timeout_overrides = parse_timeout_overrides(args.timeout_overrides)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

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

    # Exclude benchmark/aggregator files by default — they timeout or crash
    # both engines. Use --include-all to run them anyway.
    default_skip = {"all.lua", "heavy.lua", "verybig.lua"}
    if args.include_all:
        default_skip = set()
    files = sorted(
        p for p in tests_dir.glob("*.lua")
        if p.name != "main.lua" and p.name not in default_skip
    )
    if args.max_files > 0:
        files = files[: args.max_files]

    rows: list[dict[str, object]] = []
    for path in files:
        rel = path.name
        ref_cmd = [str(ref_lua)]
        zig_cmd = [str(zig_lua), "--vm=bc"]
        if args.testc:
            zig_cmd.append("--testc")
        if prelude:
            ref_cmd += ["-e", prelude]
            zig_cmd += ["-e", prelude]
        ref_cmd.append(rel)
        zig_cmd.append(rel)
        timeout_s = timeout_overrides.get(rel, args.timeout)

        time_snapshot: dict[str, bytes | None] | None = None
        if rel == "all.lua":
            # all.lua persists elapsed-time markers. Run each engine from a
            # clean state, then restore the upstream fixture exactly so the
            # verification tool never dirties/deletes tracked test data.
            time_snapshot = snapshot_all_lua_time_files(tests_dir)
            clear_all_lua_time_files(tests_dir)
        if args.no_ref:
            ref_code, ref_out = 0, ""
        else:
            ref_code, ref_out = run(ref_cmd, cwd=tests_dir, env=base_env, timeout_s=timeout_s)
        if rel == "all.lua":
            clear_all_lua_time_files(tests_dir)
        zig_code, zig_out = run(zig_cmd, cwd=tests_dir, env=base_env, timeout_s=timeout_s)
        if time_snapshot is not None:
            restore_all_lua_time_files(tests_dir, time_snapshot)

        if args.no_ref:
            # Without a reference run, classify purely on zig's exit code.
            cls = "pass" if zig_code == 0 else "zig_fail"
        elif ref_code == 0 and zig_code == 0:
            cls = "pass"
        elif ref_code == 0 and zig_code != 0:
            cls = "zig_fail"
        elif ref_code != 0 and zig_code == 0:
            cls = "zig_only_pass"
        else:
            if is_sandbox_dev_full_denied(ref_out) and is_sandbox_dev_full_denied(zig_out):
                cls = "both_fail_infra"
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
    both_fail_infra_n = sum(1 for r in rows if r["class"] == "both_fail_infra")
    zig_only_pass_n = sum(1 for r in rows if r["class"] == "zig_only_pass")

    print(f"testes matrix: {pass_n}/{total} pass parity")
    print(f"  zig_fail={zig_fail_n} both_fail={both_fail_n} both_fail_infra={both_fail_infra_n} zig_only_pass={zig_only_pass_n}")
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
                "both_fail_infra": both_fail_infra_n,
                "zig_only_pass": zig_only_pass_n,
            },
            "rows": rows,
        }
        out_path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
        print(f"\njson: {out_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
