#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    ap = argparse.ArgumentParser(description="Fail on significant luazig perf regressions")
    ap.add_argument("--baseline", default="tools/perf/baseline.json")
    ap.add_argument("--current", default="tools/perf/current.json")
    ap.add_argument("--max-regression", type=float, default=0.15)
    args = ap.parse_args()

    base = load_json(Path(args.baseline))
    cur = load_json(Path(args.current))

    bad: list[str] = []
    profiles = sorted(set(base.get("results", {}).keys()) & set(cur.get("results", {}).keys()))
    for prof in profiles:
        b_rows = base["results"].get(prof, {})
        c_rows = cur["results"].get(prof, {})
        names = sorted(set(b_rows.keys()) & set(c_rows.keys()))
        for name in names:
            b = b_rows[name]
            c = c_rows[name]
            if b.get("zig_exit") != 0 or c.get("zig_exit") != 0:
                continue
            bt = float(b.get("zig_time_s", 0.0))
            ct = float(c.get("zig_time_s", 0.0))
            if bt <= 0.0:
                continue
            reg = (ct - bt) / bt
            if reg > args.max_regression:
                bad.append(f"{prof}:{name} regression={reg:.2%} baseline={bt:.4f}s current={ct:.4f}s")

    if bad:
        print("perf guard failed:")
        for line in bad:
            print(f"  {line}")
        return 1

    print("perf guard ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
