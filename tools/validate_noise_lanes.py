#!/usr/bin/env python3
"""P16.46: mechanical noise-evidence validator (BLOCKER 2 rewrite).

tools/perf/noise-lanes.json is EVIDENCE: every summary field, every prose
claim that can be checked mechanically, and every determinism recheck row
are recomputed here from the raw data — nothing stays green just because a
hand-written number sits in the file.

Validated:
- mechanical_summary: low/high counts, medians and deltas
  (instructions/branches/cycles/wall), per-iteration deltas — recomputed
  from raw_runs with exact equality;
- placement separation: ALL low runs have env_node_depth=0/len=1, ALL high
  runs depth>=1/len>=2 (raw runs);
- intern negative result: intern chain depth 0 in EVERY raw run;
- prose hygiene: no stale arithmetic literals (12.9, 645M), no
  "mode blends" phrasing (a median SELECTS the mode containing the middle
  order statistic), no single top-level created_utc spanning both the raw
  session and the C verification — timestamps are per-section;
- determinism_recheck (structured schema): for every row the seed must
  exist in raw_runs; the EXPECTED mode is derived INDEPENDENTLY from the
  raw seed row (mode label AND its placement observables must agree);
  every repeat carries numeric instructions/mode/env_node_depth/
  env_node_chain_len/intern_depth; repeat mode must equal the expected
  mode; placement must match the mode; intern depth must be 0 (the
  documented negative result); instructions must sit within
  DRIFT_BOUND_INSTR of the raw seed's instruction count (the mode gap is
  ~1.4 G instructions, observed cross-session startup jitter <=~1 M);
  an empty recheck set is rejected.

Negative validation: --negative [case] perturbs an in-memory copy and the
validator MUST fail. Cases: arithmetic (default), wrong-mode,
wrong-placement, drift, missing-seed, missing-field, empty-recheck.
Exit codes: positive run 0 (ALL OK); negative case 0 when the defect is
DETECTED (correct behavior), 1 when it is NOT detected (validator bug).
"""
from __future__ import annotations

import copy
import json
import statistics
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_ART = REPO / "tools/perf/noise-lanes.json"
ITERATIONS = 50_000_000
# Wrong-mode repeats are ~1.4e9 instructions away from the raw seed count;
# honest cross-session perf-stat jitter observed at ~1.6e5. 5e6 separates
# both by two orders of magnitude.
DRIFT_BOUND_INSTR = 5_000_000

NEGATIVE_CASES = ("arithmetic", "wrong-mode", "wrong-placement", "drift",
                  "missing-seed", "missing-field", "empty-recheck")

FAILS: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> bool:
    if not cond:
        FAILS.append(f"{name}{(' — ' + detail) if detail else ''}")
    print(f"  {name}: {'ok' if cond else 'FAIL'}"
          f"{(' — ' + detail) if detail and not cond else ''}")
    return cond


def expected_mode_for_seed(raw_runs: list[dict], seed: int) -> str | None:
    """Derive the expected mode for a seed INDEPENDENTLY of any recheck row.

    The raw row carries both the recorded mode label and the placement
    observables; they must agree, otherwise the raw evidence itself is
    inconsistent and validation fails."""
    rows = [r for r in raw_runs if r["seed"] == seed]
    if len(rows) != 1:
        return None
    r = rows[0]
    by_label = r["mode"]
    by_placement = "low" if (r["env_node_depth"] == 0
                             and r["env_node_chain_len"] == 1) else "high"
    return by_label if by_label == by_placement else None


def validate(doc: dict) -> bool:
    """Run every check against a parsed noise-lanes document."""
    raw = doc["raw_runs"]
    summary = doc["mechanical_summary"]

    low = [r for r in raw if r["mode"] == "low"]
    high = [r for r in raw if r["mode"] == "high"]
    check("summary: low count", summary["low_count"] == len(low))
    check("summary: high count", summary["high_count"] == len(high))

    def med(rows, field):
        return statistics.median([r[field] for r in rows])

    for field in ("instructions", "branches", "cycles", "wall_ns"):
        lm, hm = med(low, field), med(high, field)
        check(f"summary: low median {field}", summary[f"low_median_{field}"] == lm)
        check(f"summary: high median {field}", summary[f"high_median_{field}"] == hm)
        check(f"summary: delta {field}", summary[f"delta_{field}"] == hm - lm)

    for field in ("instructions", "branches"):
        per = summary[f"delta_{field}"] / ITERATIONS
        check(f"summary: per-iteration {field}",
              abs(summary[f"delta_{field}_per_iteration"] - per) < 1e-6)

    sep_low = all(r["env_node_depth"] == 0 and r["env_node_chain_len"] == 1
                  for r in low)
    sep_high = all(r["env_node_depth"] >= 1 and r["env_node_chain_len"] >= 2
                   for r in high)
    check("summary: env placement separates ALL raw runs", sep_low and sep_high)
    check("summary: intern depth 0 in every raw run",
          all(r["g_count_intern_chain_depth"] == 0 for r in raw))

    # --- prose hygiene: stale literals and relabeled timestamps ------
    prose = json.dumps(doc)
    check("prose: no stale literal 12.9", "12.9" not in prose)
    check("prose: no stale literal 645", "645" not in prose)
    check("prose: no 'mode blends' claim", "mode blends" not in prose
          and "blends" not in prose)
    check("prose: no top-level created_utc spanning sections",
          "created_utc" not in doc)
    raw_ev = doc.get("raw_evidence", {})
    check("prose: raw_evidence carries its own recorded timestamp",
          isinstance(raw_ev.get("recorded_utc"), str)
          and raw_ev["recorded_utc"].startswith("2026-09-13"))
    check("prose: conclusion references mechanical fields, not hand numbers",
          "delta_instructions_per_iteration" in json.dumps(
              doc.get("conclusion_bounded", {})))

    # --- determinism recheck (per-measurement-session schema) ----------
    sessions = doc.get("det_sessions")
    check("det: session list non-empty",
          isinstance(sessions, list) and len(sessions) > 0)
    idx = doc.get("determinism_verification", {})
    latest = idx.get("latest_session")
    latest_sess = next((s for s in (sessions or [])
                        if s.get("session_id") == latest), None)
    check("det: verification index points at an existing session",
          latest_sess is not None)
    if latest_sess is not None:
        check("det: latest session has a real measured_utc",
              isinstance(latest_sess.get("measured_utc"), str))
        check("det: index SHA == latest session SHA",
              idx.get("measured_source_commit")
              == latest_sess.get("measured_source_commit"))
        check("det: index harness == latest session harness",
              idx.get("harness_sha256") == latest_sess.get("harness_sha256"))
        check("det: index row_count == session rows",
              idx.get("row_count") == len(latest_sess.get("rows", [])))
        check("det: index seeds == session seeds",
              idx.get("seeds")
              == sorted(r["seed"] for r in latest_sess.get("rows", [])))
        check("det: index repeat_count == session repeats",
              idx.get("repeat_count")
              == sum(len(r["repeats"]) for r in latest_sess.get("rows", [])))
    raw_instr = {r["seed"]: r["instructions"] for r in raw}
    for sess in (sessions or []):
        check(f"det {sess.get('session_id')}: source SHA is a full git SHA",
              isinstance(sess.get("measured_source_commit"), str)
              and len(sess["measured_source_commit"]) == 40)
        check(f"det {sess.get('session_id')}: harness hash recorded",
              isinstance(sess.get("harness_sha256"), str)
              and len(sess["harness_sha256"]) == 64)
        for row in sess.get("rows", []):
            seed = row.get("seed")
            exp = expected_mode_for_seed(raw, seed)
            if not check(f"det seed {seed}: known raw seed with consistent mode",
                         exp is not None):
                continue
            reps = row.get("repeats")
            if not check(f"det seed {seed}: non-empty repeats",
                         isinstance(reps, list) and len(reps) > 0):
                continue
            for i, rep in enumerate(reps):
                required = ("instructions", "mode", "env_node_depth",
                            "env_node_chain_len", "intern_depth")
                if not check(f"det seed {seed} rep{i}: all fields present",
                             all(k in rep for k in required)):
                    continue
                check(f"det seed {seed} rep{i}: mode == expected ({exp})",
                      rep["mode"] == exp)
                if exp == "low":
                    ok_place = (rep["env_node_depth"] == 0
                                and rep["env_node_chain_len"] == 1)
                else:
                    ok_place = (rep["env_node_depth"] >= 1
                                and rep["env_node_chain_len"] >= 2)
                check(f"det seed {seed} rep{i}: placement matches mode", ok_place)
                check(f"det seed {seed} rep{i}: intern depth 0",
                      rep["intern_depth"] == 0)
                drift = abs(rep["instructions"] - raw_instr[seed])
                check(f"det seed {seed} rep{i}: instruction drift {drift} "
                      f"<= {DRIFT_BOUND_INSTR}", drift <= DRIFT_BOUND_INSTR)

    print()
    if FAILS:
        print(f"{len(FAILS)} FAILURES")
        return False
    print("ALL OK")
    return True


def load(path: Path) -> dict:
    return json.loads(path.read_text())


def _latest_session(doc: dict) -> dict:
    latest = doc.get("determinism_verification", {}).get("latest_session")
    return next(s for s in doc["det_sessions"]
                if s["session_id"] == latest)


def _latest_rep(doc: dict) -> dict:
    return _latest_session(doc)["rows"][0]["repeats"][0]


def perturb(doc: dict, case: str) -> dict:
    """Return an in-memory copy with exactly one injected defect."""
    d = copy.deepcopy(doc)
    if case == "arithmetic":
        d["mechanical_summary"]["delta_branches"] += 39_000_000
    elif case == "wrong-mode":
        rep = _latest_rep(d)
        rep["mode"] = "low" if rep["mode"] == "high" else "high"
    elif case == "wrong-placement":
        rep = _latest_rep(d)
        rep["env_node_depth"] = 0 if rep["env_node_depth"] >= 1 else 3
        rep["env_node_chain_len"] = 1 if rep["env_node_chain_len"] >= 2 else 4
    elif case == "drift":
        _latest_rep(d)["instructions"] += 1_400_000_000
    elif case == "missing-seed":
        _latest_session(d)["rows"].append(
            {"seed": 999999, "repeats": [{"instructions": 1, "mode": "low",
                                          "env_node_depth": 0,
                                          "env_node_chain_len": 1,
                                          "intern_depth": 0}]})
    elif case == "missing-field":
        del _latest_rep(d)["intern_depth"]
    elif case == "empty-recheck":
        for s in d["det_sessions"]:
            s["rows"] = []
    else:
        raise SystemExit(f"unknown negative case: {case} "
                         f"(valid: {', '.join(NEGATIVE_CASES)})")
    return d


def main(argv: list[str]) -> int:
    if "--negative" in argv:
        i = argv.index("--negative")
        case = argv[i + 1] if len(argv) > i + 1 and argv[i + 1] in NEGATIVE_CASES \
            else "arithmetic"
        FAILS.clear()
        ok = validate(perturb(load(DEFAULT_ART), case))
        detected = not ok
        print(f"negative[{case}]:",
              "FAIL-detected (correct)" if detected else "NOT detected (BAD)")
        return 0 if detected else 1
    return 0 if validate(load(DEFAULT_ART)) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
