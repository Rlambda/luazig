#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    ap = argparse.ArgumentParser(description="Guard core perf suites against regressions")
    ap.add_argument("--baseline", default="tools/perf/core_baseline.json")
    ap.add_argument("--current", default="tools/perf/core_current.json")
    ap.add_argument("--max-regression", type=float, default=0.15)
    args = ap.parse_args()

    base = load(Path(args.baseline)).get("suites", {})
    cur = load(Path(args.current)).get("suites", {})

    bad: list[str] = []
    for suite in sorted(set(base.keys()) & set(cur.keys())):
        b = base[suite]
        c = cur[suite]
        if b.get("zig_exit") != 0 or c.get("zig_exit") != 0:
            bad.append(f"{suite}: non-zero zig exit (baseline={b.get('zig_exit')} current={c.get('zig_exit')})")
            continue
        bt = float(b.get("zig_time_s", 0.0))
        ct = float(c.get("zig_time_s", 0.0))
        if bt <= 0.0:
            continue
        reg = (ct - bt) / bt
        if reg > args.max_regression:
            bad.append(f"{suite}: regression={reg:.2%} baseline={bt:.4f}s current={ct:.4f}s")

    if bad:
        print("core perf guard failed:")
        for x in bad:
            print(f"  {x}")
        return 1

    print("core perf guard ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
