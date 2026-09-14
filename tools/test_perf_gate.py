#!/usr/bin/env python3
"""P16.45: fail-safe perf-gate aggregation tests.

Covers the P16.44 false-green bug: one NOISE-downgraded workload erased
another workload's FAIL from the aggregate, so the printed table contained
a real FAIL while the process exited 0. The fail-safe regression_check
must (a) never let a diagnostic change a verdict, (b) be invariant under
workload ordering, (c) derive aggregates only from per-workload verdicts.

Run: python3 tools/test_perf_gate.py
"""
from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import json as _json
import contextlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("perf_compare", REPO / "tools" / "perf_compare.py")
pc = importlib.util.module_from_spec(_spec)
sys.modules["perf_compare"] = pc
_spec.loader.exec_module(pc)

REGRESSION_FAIL = pc.REGRESSION_FAIL  # 0.10
REGRESSION_WARN = pc.REGRESSION_WARN  # 0.05


def run_check(zig: dict, baseline: dict, spreads: dict | None = None):
    """Invoke regression_check with stdout captured; return (warn, fail, table)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        warn, fail = pc.regression_check(zig, baseline, spreads)
    return warn, fail, buf.getvalue()


def base(times: dict) -> dict:
    return {"zig": dict(times), "baseline_identity": {"baseline_phase": "test"}}


def spread(lo: float, hi: float) -> dict:
    return {"min": lo, "max": hi, "median": (lo + hi) / 2}


FAILS = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global FAILS
    status = "ok" if cond else "FAIL"
    if not cond:
        FAILS += 1
    print(f"  {name}: {status}{(' — ' + detail) if detail and not cond else ''}")


# ---------------------------------------------------------------------------
# P16.47 matched-mode verdict matrix (owner-approved design A).
# Pure fixtures injected into mode_aware_regression — no binaries, no
# policy constants (workload names here are arbitrary fixture labels).
# ---------------------------------------------------------------------------
def mk_rows(walls, instrs, mode):
    return [{"wall": w, "instructions": i, "mode": mode}
            for w, i in zip(walls, instrs)]


def bimodal_doc(low_w=0.750, high_w=0.850):
    """Baseline with both seed modes covered (4 low + 3 high samples)."""
    return {
        "baseline_identity": {"baseline_phase": "fixture"},
        "zig_samples": {
            "wl": mk_rows([low_w] * 4, [12_583_900_000 + k * 1000 for k in range(4)], "low")
                 + mk_rows([high_w] * 3, [13_997_900_000 + k * 1000 for k in range(3)], "high"),
        },
        "mode_evidence": {"wl": {"centers": {"low": 12_583_900_500,
                                             "high": 13_997_900_500},
                                 "split_rel_gap": 0.11, "n": 7}},
    }


def run_mode(zig_samples, baseline):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        res = pc.mode_aware_regression(zig_samples, baseline)
    return res, buf.getvalue()


# 1. Same binary, sessions sampling different mode MIXES: after matched-mode
#    classification this is NOT a runtime regression (the scalar gate's
#    +13% flip must not appear as FAIL).
cand = {"wl": mk_rows([0.751] * 4, [12_583_940_000] * 4, "low")
             + mk_rows([0.849] * 3, [13_997_940_000] * 3, "high")}
res, table = run_mode(cand, bimodal_doc())
check("1 cross-mode same-binary not a regression",
      res["fail"] is False and res["inconclusive"] is False and res["warn"] is False)

# 2. Real +11% slowdown INSIDE low mode -> FAIL.
cand = {"wl": mk_rows([0.833] * 4, [12_583_940_000] * 4, "low")
             + mk_rows([0.851] * 3, [13_997_940_000] * 3, "high")}
res, table = run_mode(cand, bimodal_doc())
check("2 +11% inside low FAILs", res["fail"] is True)

# 3. Real +11% slowdown INSIDE high mode -> FAIL.
cand = {"wl": mk_rows([0.751] * 4, [12_583_940_000] * 4, "low")
             + mk_rows([0.944] * 3, [13_997_940_000] * 3, "high")}
res, table = run_mode(cand, bimodal_doc())
check("3 +11% inside high FAILs", res["fail"] is True)

# 4. One mode missing from the candidate session -> INCONCLUSIVE.
cand = {"wl": mk_rows([0.751] * 7, [12_583_940_000] * 7, "low")}
res, table = run_mode(cand, bimodal_doc())
check("4 uncovered baseline mode INCONCLUSIVE",
      res["inconclusive"] is True and res["fail"] is False)

# 5. Reorder invariance: shuffled samples, identical aggregates.
a = {"wl": mk_rows([0.751, 0.752, 0.750, 0.751],
                   [12_583_940_000, 12_583_941_000, 12_583_939_000,
                    12_583_940_500], "low")
          + mk_rows([0.849, 0.850, 0.848],
                    [13_997_940_000, 13_997_941_000, 13_997_939_000], "high")}
b = {"wl": list(reversed(a["wl"]))}
ra, _ = run_mode(a, bimodal_doc())
rb, _ = run_mode(b, bimodal_doc())
check("5 reorder invariant", (ra["fail"], ra["warn"], ra["inconclusive"])
      == (rb["fail"], rb["warn"], rb["inconclusive"]))

# 6. NOISE diagnostics never change aggregates: wide overlapping candidate
#    spread produces the same flags as a tight one.
tight = {"wl": mk_rows([0.751] * 4, [12_583_940_000] * 4, "low")
               + mk_rows([0.849] * 3, [13_997_940_000] * 3, "high")}
wide = {"wl": mk_rows([0.70, 0.751, 0.80, 0.751], [12_583_940_000] * 4, "low")
              + mk_rows([0.80, 0.849, 0.90], [13_997_940_000] * 3, "high")}
rt, tt = run_mode(tight, bimodal_doc())
rw, tw = run_mode(wide, bimodal_doc())
check("6 NOISE diagnostic-only", (rt["fail"], rt["warn"], rt["inconclusive"])
      == (rw["fail"], rw["warn"], rw["inconclusive"]) and "NOISE?" in tw)

# 7. Corrupt/mislabeled mode evidence (sample 20% away from every center)
#    -> ModeEvidenceError inside the check -> INCONCLUSIVE verdict path.
cand = {"wl": mk_rows([0.751] * 4, [12_583_940_000] * 4, "low")
             + mk_rows([0.849] * 2, [13_997_940_000] * 2, "high")
             + [{"wall": 0.9, "instructions": 16_000_000_000, "mode": "?"}]}
res, table = run_mode(cand, bimodal_doc())
check("7 corrupt evidence INCONCLUSIVE", res["inconclusive"] is True)

# 8. Fail-safe fold: a real FAIL cannot be erased by later OK/INCONCLUSIVE
#    rows (verdicts folded after the loop from the list).
doc2 = bimodal_doc()
doc2["zig_samples"]["a_fail"] = mk_rows([1.0], [100], "mono")
doc2["mode_evidence"]["a_fail"] = {"centers": {"mono": 100}, "split_rel_gap": 0.0, "n": 1}
cand = {"wl": mk_rows([0.751] * 7, [12_583_940_000] * 7, "low"),
        "a_fail": mk_rows([1.11], [100], "mono")}
res, table = run_mode(cand, doc2)
check("8 FAIL preserved alongside INCONCLUSIVE",
      res["fail"] is True and res["inconclusive"] is True)

# 9. NEW workload (candidate-only) does not influence verdicts.
res, table = run_mode({"wl": cand["wl"], "brand_new": mk_rows([1.0], [5], "mono")},
                      bimodal_doc())
check("9 NEW row no crash", "NEW" in table)

# 10. classify_modes clustering: split threshold + reorder invariance.
rows = [{"wall": 0.75, "instructions": 1000 + k} for k in range(4)]
rows += [{"wall": 0.85, "instructions": 1115 + k} for k in range(3)]
ev = pc.classify_modes(rows)
check("10 classify splits bimodal", set(ev["centers"]) == {"low", "high"})
mono = [{"wall": 0.5, "instructions": 1000 + k} for k in range(6)]
ev2 = pc.classify_modes(mono)
check("10 classify keeps unimodal", set(ev2["centers"]) == {"mono"})
ev3 = pc.classify_modes(list(reversed(rows)))
check("10 classify reorder invariant", ev3["centers"] == ev["centers"])


# ---------------------------------------------------------------------------
# P16.45-finalization BLOCKER 4: test the REAL production serializer
# (build_baseline_document / validate_baseline_document /
# write_baseline_atomic — the same helpers the CLI --update-baseline path
# calls). The previous hand-rolled version stayed green when production
# broke; this one cannot.
# ---------------------------------------------------------------------------
import copy


def _mk_current():
    return {"created_utc": "2026-09-14T00:00:00Z",
            "host": {"platform": "test"},
            "zig": {"w1": 1.0, "w2": 2.0},
            "puc": {"w1": 0.5, "w2": 1.0},
            "ratios": {"w1": 2.0, "w2": 2.0},
            "zig_samples": {"w1": [{"wall": 1.0, "instructions": 10,
                                    "mode": "mono"}]},
            "mode_evidence": {"w1": {"centers": {"mono": 10},
                                     "split_rel_gap": 0.0, "n": 1}}}


SPREADS = {"w1": {"min": 0.9, "max": 1.1, "median": 1.0},
           "w2": {"min": 1.9, "max": 2.1, "median": 2.0}}
INJ_PROV = {"git_head": "cccc" * 10, "zig_binary_sha256": "dddd" * 8,
            "puc_binary_sha256": "eeee" * 8}


def test_real_serializer():
    doc = pc.build_baseline_document(_mk_current(), SPREADS, 7, "0",
                                    "test-phase", "caller note", prov=INJ_PROV)
    check("serializer: caller note recorded", doc["baseline_identity"]["note"] == "caller note")
    check("serializer: geomean preserved", doc["geomean"] == 2.0)
    check("serializer: spreads preserved", doc["zig_spread"] == SPREADS)
    check("serializer: mode samples preserved",
          doc["zig_samples"] == _mk_current()["zig_samples"])
    check("serializer: mode evidence preserved",
          doc["mode_evidence"] == _mk_current()["mode_evidence"])
    check("serializer: injected provenance", doc["provenance"]["git_head"] == INJ_PROV["git_head"])
    check("serializer: validate accepts", pc.validate_baseline_document(doc))

    # Strict reload + atomic write + no residue + old-baseline survival.
    with tempfile.TemporaryDirectory() as td:
        fake = Path(td) / "baseline.json"
        fake.write_text('{"zig": {"old": 1.0}}\n')
        assert pc.write_baseline_atomic(fake, doc)
        reloaded = _json.loads(fake.read_text())
        check("serializer: atomic write + strict reload", reloaded["geomean"] == 2.0)
        check("serializer: no tmp residue", not (Path(str(fake) + ".tmp").exists()))

        # Validation failure must NOT replace the old approved baseline.
        bad = copy.deepcopy(doc)
        del bad["zig_spread"]
        ok = pc.write_baseline_atomic(fake, bad)
        after = _json.loads(fake.read_text())
        check("serializer: invalid doc leaves old baseline",
              ok is False and after.get("geomean") == 2.0)

        # validate_baseline_document rejects each missing section.
        all_rejected = True
        for missing in ("provenance", "geomean", "zig", "ratios",
                        "zig_spread", "baseline_identity"):
            bad2 = copy.deepcopy(doc)
            del bad2[missing]
            if pc.validate_baseline_document(bad2):
                all_rejected = False
                check(f"serializer: validate rejects missing {missing}", False)
        check("serializer: validate rejects every missing section", all_rejected)
        empty_ident = copy.deepcopy(doc)
        empty_ident["baseline_identity"] = {"baseline_phase": ""}
        check("serializer: validate rejects empty phase",
              not pc.validate_baseline_document(empty_ident))


test_real_serializer()



# ---------------------------------------------------------------------------
# P16.45-correction: every canonical JSON artifact must parse strictly
# (the committed noise-lanes.json with 12451044xxx literals must be caught).
# ---------------------------------------------------------------------------
CANONICAL = [
    "tools/perf/current.json",
    "tools/perf/current-counters.json",
    "tools/perf/current-profile-index.json",
    "tools/perf/current-differential-profile.json",
    "tools/perf/current-codesize.json",
    "tools/perf/current-callframe-layout.json",
    "tools/perf/current-dispatch-floor.json",
    "tools/perf/baseline-approved.json",
    "tools/perf/noise-lanes.json",
    "tools/perf/baseline-p15.37.json",
    # P16.45-finalization: the list must actually cover EVERY canonical
    # artifact (matrix/smoke were previously omitted while the docstring
    # claimed full coverage).
    "tools/status/current-matrix.json",
    "tools/status/current-smoke.json",
]
for rel in CANONICAL:
    p = REPO / rel
    if not p.exists():
        check(f"json {rel}", False, "missing")
        continue
    try:
        _json.loads(p.read_text())
        check(f"json {rel}", True)
    except _json.JSONDecodeError as e:
        check(f"json {rel}", False, str(e))


def _negative_invalid_json():
    bad = '{"x": 12451044xxx}'
    try:
        _json.loads(bad)
        return False
    except _json.JSONDecodeError:
        return True


check("negative: invalid numeric literal caught", _negative_invalid_json())

print(f"\n{'ALL OK' if FAILS == 0 else str(FAILS) + ' FAILURES'}")
sys.exit(1 if FAILS else 0)
