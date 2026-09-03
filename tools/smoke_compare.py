#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Shared provenance helpers live next to this script; make them importable
# regardless of the caller's CWD.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import provenance


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def lane_metadata(argv: list[str]) -> dict:
    """Metadata stamped into the versioned JSON artifact so a reader can tell
    exactly which lane/flags/host produced it. Zig version comes from the
    shared provenance helper (fails soft to None)."""
    return {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "lane": "smoke_compare",
        "argv": argv,
        "zig_version": provenance.zig_version(),
    }


def run(
    cmd: list[str], *, cwd: Path, timeout_s: int, env: dict[str, str] | None = None
) -> tuple[int, str]:
    p = subprocess.run(
        cmd,
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout_s,
        env=env,
    )
    out = p.stdout.replace("\r\n", "\n")
    return p.returncode, out


def discover_files(root: Path, d: str, globs: list[str]) -> list[str]:
    base = (root / d).resolve()
    if not base.exists():
        raise FileNotFoundError(str(base))
    out: list[str] = []
    seen: set[str] = set()
    for g in globs:
        for p in base.rglob(g):
            if not p.is_file():
                continue
            rel = p.relative_to(root).as_posix()
            if rel in seen:
                continue
            seen.add(rel)
            out.append(rel)
    out.sort()
    return out


# C-extension smoke support (45_userdata_capi.lua). The single upstream source
# lua-5.5.0/testes/libs/udatatest.c is compiled TWICE, once per runtime:
#   * udatatest.so in lua-5.5.0/testes/libs/  — against PUC headers (lua-5.5.0/src)
#   * udatatest.so in tests/smoke/zig-libs/   — against luazig headers (src/lua)
# Both follow the upstream testes/libs makefile pattern: -fPIC -shared WITHOUT
# -llua, leaving lua_* symbols undefined so they resolve from the host
# interpreter's exported dynamic symbol table (both build/lua-c/lua and
# zig-out/bin/luazig export the full C API). Linking a hosted module against a
# liblua would map a second VM image into the process; host resolution keeps a
# single VM, exactly like PUC's own test libraries.
UDATATEST_SRC = "lua-5.5.0/testes/libs/udatatest.c"
UDATATEST_PUC_DIR = "lua-5.5.0/testes/libs"
UDATATEST_ZIG_DIR = "tests/smoke/zig-libs"


def build_udatatest_modules(root: Path) -> None:
    """Compile the two per-runtime udatatest.so builds (see comment above)."""
    src = root / UDATATEST_SRC
    if not src.exists():
        raise FileNotFoundError(str(src))
    for out_dir, include_dir in (
        (UDATATEST_PUC_DIR, "lua-5.5.0/src"),
        (UDATATEST_ZIG_DIR, "src/lua"),
    ):
        out = root / out_dir
        out.mkdir(parents=True, exist_ok=True)
        subprocess.check_call(
            [
                "gcc", "-O2", "-Wall",
                "-I", str(root / include_dir),
                "-fPIC", "-shared",
                "-o", str(out / "udatatest.so"),
                str(src),
            ],
            cwd=str(root),
        )


def udatatest_cpath_preamble(root: Path, *, zig: bool) -> str:
    """Per-runtime startup chunk (passed via the LUA_INIT_5_5 env var, PUC's
    standard pre-script hook) making require("udatatest") resolve to the
    module build compiled against THAT runtime's headers. The smoke files
    themselves cannot branch on the runtime (differential runs execute the
    same script), so the harness performs the explicit selection. LUA_INIT
    is used instead of `-e` because `-e` shifts the `arg` table (arg[-1]
    etc.), which smoke tests such as 29_platform_process_io.lua observe."""
    d = UDATATEST_ZIG_DIR if zig else UDATATEST_PUC_DIR
    return f'package.cpath="{(root / d).resolve()}/?.so;" .. package.cpath'


def main() -> int:
    ap = argparse.ArgumentParser(description="Differential smoke runner: C Lua vs luazig --engine=zig")
    ap.add_argument("--tests-dir", default="tests/smoke")
    ap.add_argument("--glob", action="append", default=["*.lua"])
    ap.add_argument("--timeout", type=int, default=30, help="timeout per engine run (seconds)")
    ap.add_argument("--no-build", action="store_true", help="do not build reference/zig binaries")
    ap.add_argument("--ref-lua", default="build/lua-c/lua")
    ap.add_argument("--zig-lua", default="zig-out/bin/luazig")
    ap.add_argument("--json-out", default="", help="optional path for JSON report")
    args = ap.parse_args()

    root = repo_root()
    try:
        files = discover_files(root, args.tests_dir, args.glob)
    except FileNotFoundError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    if not files:
        print("error: no files discovered", file=sys.stderr)
        return 2

    ref_lua = (root / args.ref_lua).resolve()
    zig_lua = (root / args.zig_lua).resolve()

    if not args.no_build:
        subprocess.check_call(["make", "-s", "lua-c"], cwd=str(root))
        subprocess.check_call(["zig", "build", "-Doptimize=ReleaseFast"], cwd=str(root))
        build_udatatest_modules(root)

    # Per-runtime module selection preambles (see udatatest_cpath_preamble),
    # delivered via LUA_INIT_5_5. Applied to every file: harmless for scripts
    # that never require C modules, and it keeps require() semantics explicit
    # and consistent across the two runtimes.
    ref_env = {**os.environ, "LUA_INIT_5_5": udatatest_cpath_preamble(root, zig=False)}
    zig_env = {**os.environ, "LUA_INIT_5_5": udatatest_cpath_preamble(root, zig=True)}

    bad = 0
    results: list[dict[str, object]] = []
    for rel in files:
        p = (root / rel).resolve()
        if not p.exists():
            print(f"missing: {rel}")
            bad += 1
            results.append({"file": rel, "match": False})
            continue

        ref_code, ref_out = run(
            [str(ref_lua), str(p)], cwd=root, timeout_s=args.timeout, env=ref_env
        )
        zig_code, zig_out = run(
            [str(zig_lua), "--engine=zig", str(p)], cwd=root, timeout_s=args.timeout, env=zig_env
        )

        ok = (ref_code == zig_code) and (ref_out == zig_out)
        results.append({"file": rel, "match": ok})
        if ok:
            print(f"ok  {rel}")
            continue

        bad += 1
        print(f"DIFF {rel}")
        print(f"  ref exit={ref_code}")
        for line in ref_out.splitlines()[:10]:
            print(f"    {line}")
        print(f"  zig exit={zig_code}")
        for line in zig_out.splitlines()[:10]:
            print(f"    {line}")

    if bad:
        print(f"FAIL ({bad} mismatches)")
        status = 1
    else:
        print("PASS")
        status = 0

    if args.json_out:
        payload = {
            "meta": lane_metadata(sys.argv),
            # Provenance: the smoke lane executes BOTH engines, so both
            # binary hashes apply (see tools/provenance.py block()).
            "provenance": provenance.block(zig_bin=zig_lua, puc_bin=ref_lua),
            "total": len(results),
            "ok": sum(1 for r in results if r["match"]),
            "mismatches": bad,
            "results": results,
        }
        out_path = Path(args.json_out)
        if out_path.parent != Path("."):
            out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
        print(f"json: {out_path}")

    return status


if __name__ == "__main__":
    raise SystemExit(main())

