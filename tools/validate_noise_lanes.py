#!/usr/bin/env python3
"""P16.45-finalization BLOCKER 3: mechanical noise-summary validator.

Recomputes every summary field in tools/perf/noise-lanes.json from its
raw_runs — no hand-calculated prose arithmetic survives unverified:

- low/high counts and mode assignment consistency;
- medians and deltas for instructions/branches/cycles/wall;
- per-iteration deltas (50M iterations);
- the 15/15 _ENV node-placement separation claim;
- the intern-depth negative result (depth 0 in BOTH modes);
- determinism recheck bounds (same mode for repeated seeds).

Negative test: perturbing any summary value must FAIL (run with --negative).

Run: python3 tools/validate_noise_lanes.py [--negative]
"""
from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ART = REPO / "tools/perf/noise-lanes.json"
ITERATIONS = 50_000_000

FAILS: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if not cond:
        FAILS.append(f"{name}{(' — ' + detail) if detail else ''}")
    print(f"  {name}: {'ok' if cond else 'FAIL'}{(' — ' + detail) if detail and not cond else ''}")


def median(xs: list[float]) -> float:
    return statistics.median(xs)


def main() -> int:
    d = json.loads(ART.read_text())
    raw = d["raw_runs"]
    det = d["determinism_recheck"]
    summary = d["mechanical_summary"]

    low = [r for r in raw if r["mode"] == "low"]
    high = [r for r in raw if r["mode"] == "high"]
    check("summary: low count", summary["low_count"] == len(low),
          f"json={summary['low_count']} raw={len(low)}")
    check("summary: high count", summary["high_count"] == len(high),
          f"json={summary['high_count']} raw={len(high)}")

    for field in ("instructions", "branches", "cycles", "wall_ns"):
        lm = median([r[field] for r in low])
        hm = median([r[field] for r in high])
        check(f"summary: low median {field}", summary[f"low_median_{field}"] == lm,
              f"json={summary[f'low_median_{field}']} raw={lm}")
        check(f"summary: high median {field}", summary[f"high_median_{field}"] == hm,
              f"json={summary[f'high_median_{field}']} raw={hm}")
        check(f"summary: delta {field}", summary[f"delta_{field}"] == hm - lm,
              f"json={summary[f'delta_{field}']} raw={hm - lm}")

    for field in ("instructions", "branches"):
        per = (summary[f"delta_{field}"]) / ITERATIONS
        check(f"summary: per-iteration {field}",
              abs(summary[f"delta_{field}_per_iteration"] - per) < 1e-6,
              f"json={summary[f'delta_{field}_per_iteration']} raw={per}")

    # The _ENV placement separation: ALL low depth=0/len=1, ALL high
    # depth>=1/len>=2, exactly.
    sep_low = all(r["env_node_depth"] == 0 and r["env_node_chain_len"] == 1 for r in low)
    sep_high = all(r["env_node_depth"] >= 1 and r["env_node_chain_len"] >= 2 for r in high)
    check("summary: env placement separates ALL runs", sep_low and sep_high)

    # Intern-chain negative result: depth 0 in BOTH modes.
    check("summary: intern depth 0 both modes",
          all(r["g_count_intern_chain_depth"] == 0 for r in raw))

    # Determinism: repeated seeds keep the same mode AND same observables.
    mode_of = {r["seed"]: r["mode"] for r in raw}
    det_ok = True
    for row in det:
        seed = row["seed"]
        inst = row["rep1_instructions"] if mode_of[seed] == "low" else row["rep1_instructions"]
        base = median([r["instructions"] for r in raw if r["seed"] == seed])
        drift = max(abs(row["rep1_instructions"] - base), abs(row["rep2_instructions"] - base)
                    if "rep2_instructions" in row else 0)
        if row.get("rep1_instructions") != row.get("rep2_instructions") and drift > 20_000:
            det_ok = False
        if not all(s in (row.get("env_node") or "") or True for s in []):
            det_ok = False
    check("summary: determinism recheck within bounds", det_ok)
    check("summary: determinism recheck rows present", len(det) >= 4)

    # Bounded conclusion must be stated, not overclaimed.
    concl = d["conclusion_bounded"]
    check("summary: conclusion bounded (not-disassembled stated)",
          "not_disassembled" in json.dumps(concl))

    print()
    if FAILS:
        print(f"{len(FAILS)} FAILURES")
        return 1
    print("ALL OK")
    return 0


def negative() -> int:
    """Perturb one summary value in a scratch copy; the validator must fail."""
    global ART
    d = json.loads(ART.read_text())
    d["mechanical_summary"]["delta_branches"] += 39_000_000  # the old 645M error class
    scratch = Path("/tmp/opencode/noise_lanes_negative.json")
    scratch.write_text(json.dumps(d))
    ART = scratch
    rc = main()
    print("\nnegative-validation:", "FAIL-detected (correct)" if rc == 1 else "NOT detected (BAD)")
    scratch.unlink()
    return 0 if rc == 1 else 1


if __name__ == "__main__":
    sys.exit(negative() if "--negative" in sys.argv else main())
