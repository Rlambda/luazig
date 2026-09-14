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
# P16.48 matched-mode matrix: INDEPENDENT clustering of both sides,
# order-matched centers, weight compatibility, wall-P25 envelope rule.
# Pure fixtures — no binaries, no policy constants, no workload names.
# ---------------------------------------------------------------------------
def mk_rows(walls, instrs, mode=""):
    return [{"wall": w, "instructions": i, "mode": mode}
            for w, i in zip(walls, instrs)]


def run_mode(zig_samples, baseline):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        res = pc.mode_aware_regression(zig_samples, baseline)
    return res, buf.getvalue()


def blank_doc(samples):
    return {"baseline_identity": {"baseline_phase": "fixture"},
            "zig_samples": samples}


# N1. missing baseline workload in candidate -> INCONCLUSIVE/nonzero.
bl = blank_doc({"wl": mk_rows([1.0] * 5, [100] * 5, "mono")})
res, table = run_mode({}, bl)
check("N1 missing baseline workload INCONCLUSIVE",
      res["inconclusive"] is True and res["fail"] is False)

# N2. partial mode migration (reviewer fixture): baseline low=10x100 /
#     high=10x111; candidate 1x100 + 20x111 -> must NEVER be OK.
bl = blank_doc({"wl": mk_rows([1.0] * 10, [100] * 10)
                       + mk_rows([1.0] * 10, [111] * 10)})
cand = {"wl": mk_rows([1.0], [100]) + mk_rows([1.0] * 20, [111] * 20)}
res, table = run_mode(cand, bl)
check("N2 mode migration nonzero", (res["fail"] or res["inconclusive"]) is True)

# N3. mono -> minority +11% (reviewer fixture): 21x100 vs 11x100+10x111.
bl = blank_doc({"wl": mk_rows([1.0] * 21, [100] * 21)})
cand = {"wl": mk_rows([1.0] * 11, [100] * 11)
             + mk_rows([1.0] * 10, [111] * 10)}
res, table = run_mode(cand, bl)
check("N3 mono->minority +11% nonzero", res["inconclusive"] is True)

# N4. mirror: bimodal -> mono collapse -> nonzero.
bl = blank_doc({"wl": mk_rows([1.0] * 10, [100] * 10)
                       + mk_rows([1.0] * 10, [111] * 10)})
cand = {"wl": mk_rows([1.0] * 21, [100] * 21)}
res, table = run_mode(cand, bl)
check("N4 bimodal->mono nonzero", res["inconclusive"] is True)

# N5. same independently clustered mono populations -> OK.
bl = blank_doc({"wl": mk_rows([0.5] * 21, [1000 + k for k in range(21)])})
cand = {"wl": mk_rows([0.5] * 21, [1000 + k * 0 for k in range(21)])}
res, table = run_mode(cand, bl)
check("N5 matched mono OK", res["fail"] is False
      and res["inconclusive"] is False and res["warn"] is False)

# N6. same binary, sessions with different mode MIXES but compatible
#     weights -> not a regression (the old scalar +13% flip must not FAIL).
bl = blank_doc({"wl": mk_rows([1.0] * 12, [100] * 12)
                       + mk_rows([1.0] * 9, [111] * 9)})
cand = {"wl": mk_rows([1.0] * 9, [100] * 9) + mk_rows([1.0] * 12, [111] * 12)}
res, table = run_mode(cand, bl)
check("N6 cross-mode same-binary mix OK", res["fail"] is False
      and res["inconclusive"] is False and res["warn"] is False)

# N7. wall-lottery flip (same instructions): within each mode the session
#     mixes fast/slow wall sublevels (measured shape: levels ~0.75/0.95
#     interleaved per process); medians move, the P25 ENVELOPE keeps the
#     fast edge — verdict stays OK.
bl = blank_doc({"wl": mk_rows([0.75] * 10, [100] * 10)
                       + mk_rows([0.85] * 10, [111] * 10)})
cand = {"wl": mk_rows([0.75] * 5 + [0.95] * 5, [100] * 10)
               + mk_rows([0.74] * 5 + [0.95] * 5, [111] * 10)}
res, table = run_mode(cand, bl)
check("N7 wall-lottery median flip stays OK", res["fail"] is False
      and res["inconclusive"] is False and res["warn"] is False)

# N8. +11% inside a stably matched mode (centers 30% apart, weights kept)
#     -> FAIL.
bl = blank_doc({"wl": mk_rows([0.6] * 10, [1000] * 10)
                       + mk_rows([0.8] * 10, [1300] * 10)})
cand = {"wl": mk_rows([0.6] * 10, [1110] * 10)
               + mk_rows([0.8] * 10, [1300] * 10)}
res, table = run_mode(cand, bl)
check("N8 +11% in matched low FAIL", res["fail"] is True)

# N9. +11% inside high mode -> FAIL.
cand = {"wl": mk_rows([0.6] * 10, [1000] * 10)
               + mk_rows([0.8] * 10, [1443] * 10)}
res, table = run_mode(cand, bl)
check("N9 +11% in matched high FAIL", res["fail"] is True)

# N10. weight change beyond the binomial bound (10/10 -> 1/20) -> nonzero.
cand = {"wl": mk_rows([1.0], [100]) + mk_rows([1.0] * 20, [111] * 20)}
res, table = run_mode(cand, bl)
check("N10 weight-migration nonzero", res["inconclusive"] is True)

# N11. reorder invariance: reversed candidate samples, same aggregates.
a = {"wl": mk_rows([0.6] * 10, [1000 + k for k in range(10)])
           + mk_rows([0.8] * 10, [1300 + k for k in range(10)])}
b = {"wl": list(reversed(a["wl"]))}
ra, _ = run_mode(a, bl)
rb, _ = run_mode(b, bl)
check("N11 reorder invariant", (ra["fail"], ra["warn"], ra["inconclusive"])
      == (rb["fail"], rb["warn"], rb["inconclusive"]))

# N12. FAIL not erased by a later INCONCLUSIVE (fold after the loop).
doc2 = blank_doc({"ok_wl": mk_rows([1.0] * 10, [1000] * 10)
                          + mk_rows([1.0] * 10, [1300] * 10),
                  "gone_wl": mk_rows([1.0] * 5, [100] * 5)})
cand = {"ok_wl": mk_rows([1.0] * 10, [1110] * 10)
               + mk_rows([1.0] * 10, [1300] * 10)}  # FAIL in low
res, table = run_mode(cand, doc2)
check("N12 FAIL preserved alongside INCONCLUSIVE",
      res["fail"] is True and res["inconclusive"] is True)

# N13. corrupt evidence: a wild outlier sample becomes a 1-sample
#      "cluster" -> rejected as a mode (outlier) -> form change or weight
#      incompatibility -> INCONCLUSIVE.
bl = blank_doc({"wl": mk_rows([1.0] * 21, [100] * 21)})
cand = {"wl": mk_rows([1.0] * 21, [100] * 20 + [500])}
res, table = run_mode(cand, bl)
check("N13 corrupt outlier INCONCLUSIVE", res["inconclusive"] is True)

# N14. candidate-only workload -> NEW informational row, no verdict.
bl = blank_doc({"wl": mk_rows([1.0] * 10, [100] * 10)
                       + mk_rows([1.0] * 10, [1300] * 10)})
cand = {"wl": mk_rows([1.0] * 21, [100] * 21),
        "brand_new": mk_rows([1.0] * 5, [7] * 5)}
res, table = run_mode(cand, bl)
check("N14 candidate-only NEW informational", "NEW" in table)

# N15. wall-P25 envelope secondary rule: instructions identical (OK) but
#      the candidate's fast envelope moved +12% -> INCONCLUSIVE + counter
#      guidance (owner-approved P16.48 policy).
bl = blank_doc({"wl": mk_rows([0.50] * 10, [1000] * 10)
                       + mk_rows([0.80] * 10, [1300] * 10)})
cand = {"wl": mk_rows([0.56] * 10, [1000] * 10)
               + mk_rows([0.90] * 10, [1300] * 10)}
res, table = run_mode(cand, bl)
check("N15 wall-P25 envelope shift INCONCLUSIVE",
      res["inconclusive"] is True and res["fail"] is False
      and "causal counters" in table)

# N16. classify_modes: WARN-tied split threshold + outlier rejection.
mono_rows = [{"wall": 0.5, "instructions": 1000 + k} for k in range(20)]
ev = pc.classify_modes(mono_rows)
check("N16 spread below threshold stays mono",
      set(ev["centers"]) == {"mono"})
bim_rows = ([{"wall": 0.5, "instructions": 1000 + k} for k in range(10)]
            + [{"wall": 0.5, "instructions": 1120 + k} for k in range(10)])
ev2 = pc.classify_modes(bim_rows)
check("N16 gap above threshold splits", set(ev2["centers"]) == {"low", "high"})
outlier = [{"wall": 0.5, "instructions": 1000 + k} for k in range(20)]
outlier[0]["instructions"] = 900
ev3 = pc.classify_modes(outlier)
check("N16 one-sample cluster rejected as outlier",
      set(ev3["centers"]) == {"mono"})


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
    # P16.47: every gate run persists its raw session evidence here
    # (samples + mode labels + cluster evidence + provenance).
    "tools/perf/current-gate.json",
    # P16.48: multi-session manifest for consecutive-session claims.
    "tools/perf/current-gate-manifest.json",
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
