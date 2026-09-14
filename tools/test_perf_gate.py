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
# P16.48-review: PAIRED-SEED verdict matrix. Fixtures carry seed
# identities; the verdict is a per-seed paired instruction delta — no
# sampling ambiguity, migrations FAIL by construction.
# ---------------------------------------------------------------------------
def mk_rows(walls, instrs, mode="", seeds=None):
    rows = [{"wall": w, "instructions": i, "mode": mode}
            for w, i in zip(walls, instrs)]
    if seeds is not None:
        for r, s in zip(rows, seeds):
            r["seed"] = s
    return rows


SEEDS = list(range(1, 22))  # arbitrary fixture seed identities
S10 = SEEDS[:10]
S20 = SEEDS[:20]  # 20-of-21 partial list (Task 0 negative-fixture basis)
S21 = SEEDS


def run_mode(zig_samples, baseline):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        res = pc.mode_aware_regression(zig_samples, baseline)
    return res, buf.getvalue()


def blank_doc(samples, seed_list=None):
    """Fixture baseline doc. `seed_list` declares the protocol list the
    doc was recorded under (Task 0: mode_aware_regression prefers the
    doc's declared list and falls back to pc.SEED_LIST when absent)."""
    doc = {"baseline_identity": {"baseline_phase": "fixture"},
           "zig_samples": samples}
    if seed_list is not None:
        doc["seed_list"] = list(seed_list)
    return doc


def bimodal(seeds, low_n=10, base=100, high=111, wall=1.0):
    """Bimodal fixture: first low_n seeds cost `base`, rest cost `high`."""
    rows = []
    for i, s in enumerate(seeds):
        cost = base if i < low_n else high
        rows.append({"wall": wall, "instructions": cost, "seed": s})
    return rows


# M1. EXTREME migration (P16.48 reviewer fixture) 10/10 -> 1/20:
#     paired terms — seeds 2..10 (9 low seeds) moved to 111 -> FAIL.
#     (20-seed fixture: the doc declares its own seed_list — Task 0.)
bl = blank_doc({"wl": bimodal(S10 + S10[0:0] + list(range(11, 21)),
                              low_n=10)}, seed_list=S20)
cand_rows = [{"wall": 1.0, "instructions": (100 if s == 1 else 111),
              "seed": s}
             for s in list(range(1, 21))]
res, table = run_mode({"wl": cand_rows}, bl)
check("M1 extreme migration 10/10->1/20 FAILs",
      res["fail"] is True)  # 9 migrated seeds show +11% per-seed deltas

# M2. MODERATE migration (reviewer fixture) 10/10 -> 3/18: seeds 4..10
#     (7 low seeds) moved +11% -> FAIL (the old binomial guard stayed
#     green at p=0.0015 > alpha).
cand_rows = [{"wall": 1.0, "instructions": (100 if s <= 3 else 111),
              "seed": s}
             for s in list(range(1, 21))]
res, table = run_mode({"wl": cand_rows}, bl)
check("M2 moderate migration 10/10->3/18 FAILs", res["fail"] is True)

# M3. Intermediate mass shifts (5/16-class and lighter): every shift of
#     >= 1 low seed by +11% must be nonzero; 5 stay / 5 move -> FAIL.
for keep in (5, 4, 3, 2, 1):
    cand_rows = [{"wall": 1.0,
                  "instructions": (100 if s <= keep else 111),
                  "seed": s}
                 for s in list(range(1, 21))]
    res, table = run_mode({"wl": cand_rows}, bl)
    if not res["fail"]:
        check(f"M3 shift keep={keep} FAILs", False)
check("M3 all intermediate mass shifts FAIL", True)

# M4. Reorder invariance: shuffled candidate rows, identical aggregates.
rows_a = bimodal(list(range(1, 21)), low_n=10)
a = {"wl": [dict(r) for r in rows_a]}
b = {"wl": list(reversed([dict(r) for r in rows_a]))}
ra, _ = run_mode(a, blank_doc({"wl": rows_a}, seed_list=S20))
rb, _ = run_mode(b, blank_doc({"wl": rows_a}, seed_list=S20))
check("M4 reorder invariant", (ra["fail"], ra["warn"], ra["inconclusive"])
      == (rb["fail"], rb["warn"], rb["inconclusive"]))

# M5. Real +11% inside a mode STAYS FAIL (not generic INCONCLUSIVE):
#     modes 100/130; all low seeds +11% -> 111 (still nearer low; the
#     per-seed delta is exactly the regression).
bl = blank_doc({"wl": bimodal(list(range(1, 21)), low_n=10,
                              base=100, high=130)}, seed_list=S20)
cand_rows = [{"wall": 1.0, "instructions": (111 if s <= 10 else 130),
              "seed": s} for s in list(range(1, 21))]
res, table = run_mode({"wl": cand_rows}, bl)
check("M5 +11% within mode is FAIL", res["fail"] is True
      and res["inconclusive"] is False)

# M6. Same binary / same seeds: everything reproduces -> all OK.
base_rows = bimodal(list(range(1, 21)), low_n=10, base=1000, high=1111)
cand_rows = [dict(r) for r in base_rows]
res, table = run_mode({"wl": cand_rows},
                      blank_doc({"wl": base_rows}, seed_list=S20))
check("M6 identical paired populations OK", res["fail"] is False
      and res["inconclusive"] is False and res["warn"] is False)

# M7. Missing baseline workload -> INCONCLUSIVE.
res, table = run_mode({}, blank_doc({"wl": base_rows}))
check("M7 missing workload INCONCLUSIVE", res["inconclusive"] is True)

# M8. Seed-identity mismatch -> INCONCLUSIVE (corrupt evidence).
cand_rows = [dict(r) for r in base_rows]
cand_rows[0]["seed"] = 999
res, table = run_mode({"wl": cand_rows},
                      blank_doc({"wl": base_rows}, seed_list=S20))
check("M8 seed mismatch INCONCLUSIVE", res["inconclusive"] is True)

# M9. Anonymous (pre-paired) samples -> INCONCLUSIVE, not a verdict.
anon = [{"wall": 1.0, "instructions": 1000, "mode": "mono"}]
res, table = run_mode({"wl": anon}, blank_doc({"wl": anon}))
check("M9 anonymous schema INCONCLUSIVE", res["inconclusive"] is True)

# M10. mono<->split form change with SUB-THRESHOLD per-seed deltas ->
#      INCONCLUSIVE (the guard exists for evidence-shape anomalies that
#      carry no verdict-relevant delta; a real delta must FAIL instead —
#      see M1-M5). Baseline: two tight sub-threshold groups (gap 4.5%);
#      candidate: second group +1% -> gap crosses 5% -> form flips while
#      every per-seed delta stays OK.
base_rows = ([{"wall": 1.0, "instructions": 1000 + s, "seed": s}
              for s in SEEDS[:10]]
             + [{"wall": 1.0, "instructions": 1049 + s, "seed": s}
                for s in SEEDS[10:20]])
cand_rows = ([dict(r) for r in base_rows[:10]]
             + [{"wall": 1.0, "instructions": int((1049 + s) * 1.01),
                 "seed": s} for s in SEEDS[10:20]])
res, table = run_mode({"wl": cand_rows},
                      blank_doc({"wl": base_rows}, seed_list=S20))
check("M10 sub-threshold mono->split INCONCLUSIVE",
      res["inconclusive"] is True and res["fail"] is False)
res, table = run_mode({"wl": base_rows},
                      blank_doc({"wl": cand_rows}, seed_list=S20))
check("M10 sub-threshold split->mono INCONCLUSIVE",
      res["inconclusive"] is True and res["fail"] is False)

# M11. Outlier above the split threshold with a too-small cluster ON THE
#      BASELINE SIDE (identical candidate — every per-seed delta is ~0):
#      the evidence shape itself is anomalous and cannot back a green
#      verdict -> INCONCLUSIVE. (A candidate-side-only outlier of that
#      magnitude would show a >5% per-seed delta and FAIL first — the
#      guard ordering guarantees real deltas are never masked.)
mono_rows = [{"wall": 1.0, "instructions": 1000 + s, "seed": s}
             for s in S21]
out_base = [dict(r) for r in mono_rows]
out_base[2]["instructions"] = 1080  # isolated by ~5.9% > threshold
res, table = run_mode({"wl": [dict(r) for r in out_base]},
                      blank_doc({"wl": out_base}))
check("M11 baseline-side outlier INCONCLUSIVE",
      res["inconclusive"] is True and res["fail"] is False)

# M12. FAIL not erased by a later INCONCLUSIVE (fold after the loop).
doc2 = blank_doc({"ok_wl": mono_rows, "gone_wl": mono_rows[:5]})
cand = {"ok_wl": [{"wall": 1.0, "instructions": 1120 + s, "seed": s}
                  for s in S21]}  # +12% on every seed -> FAIL
res, table = run_mode(cand, doc2)
check("M12 FAIL preserved alongside INCONCLUSIVE",
      res["fail"] is True and res["inconclusive"] is True)

# M13. Candidate-only workload -> NEW informational row.
res, table = run_mode({"wl": [dict(r) for r in mono_rows],
                       "brand_new": mono_rows[:3]}, blank_doc({"wl": mono_rows}))
check("M13 candidate-only NEW informational", "NEW" in table)

# M14. Weights computed FROM LABELS (P16.48-review BLOCKER 2): ten
#      DISTINCT low values + ten DISTINCT high values must give
#      baseline_low_frac == 0.5 (the old median-comparison gave 0.25).
rows = ([{"wall": 1.0, "instructions": 1000 + 3 * s, "seed": s}
         for s in SEEDS[:10]]
        + [{"wall": 1.0, "instructions": 1300 + 3 * s, "seed": s}
           for s in SEEDS[10:20]])
cand_rows = [dict(r) for r in rows]
res, table = run_mode({"wl": cand_rows}, blank_doc({"wl": rows},
                                                   seed_list=S20))
w = res["matching"]["wl"]["weights"]
check("M14 weights from labels (0.5 not 0.25)",
      w["baseline_low_frac"] == 0.5 and w["candidate_low_frac"] == 0.5)

# M15. Wall-P25 envelope secondary rule with paired OK instructions.
bl = blank_doc({"wl": [{"wall": 0.50, "instructions": 1000 + s, "seed": s}
                       for s in S21]})
cand = {"wl": [{"wall": 0.56, "instructions": 1000 + s, "seed": s}
               for s in S21]}
res, table = run_mode(cand, bl)
check("M15 wall-P25 envelope shift INCONCLUSIVE",
      res["inconclusive"] is True and res["fail"] is False
      and "causal counters" in table)

# M16. Wall-lottery median flip (fast sublevel intact) stays OK.
cand = {"wl": [{"wall": 0.50 if s % 2 else 0.95,
                "instructions": 1000 + s, "seed": s} for s in S21]}
res, table = run_mode(cand, bl)
check("M16 wall-lottery median flip OK", res["fail"] is False
      and res["inconclusive"] is False)

# M17. classify_modes basics (kept): spread< threshold mono; gap> splits;
#      one-sample cluster rejected.
mono_e = pc.classify_modes([{"wall": 0.5, "instructions": 1000 + k}
                            for k in range(20)])
check("M17 spread below threshold mono", set(mono_e["centers"]) == {"mono"})
bim_e = pc.classify_modes(
    [{"wall": 0.5, "instructions": 1000 + k} for k in range(10)]
    + [{"wall": 0.5, "instructions": 1120 + k} for k in range(10)])
check("M17 gap above threshold splits", set(bim_e["centers"]) == {"low", "high"})

# M18-M22 (Task 0): bounded paired-seed schema hardening. The old dict/set
# comparison collapsed duplicates and only checked set equality, so
# symmetrically corrupt sessions returned OK. These docs declare NO
# seed_list -> the expected list falls back to the published pc.SEED_LIST.
full_rows = [{"wall": 1.0, "instructions": 1000 + s, "mode": "mono",
              "seed": s} for s in S21]

# M18. Both sides ONLY seed 1 -> INCONCLUSIVE (missing 2..21), never OK.
one = [{"wall": 1.0, "instructions": 1000, "mode": "mono", "seed": 1}]
res, table = run_mode({"wl": [dict(r) for r in one]},
                      blank_doc({"wl": one}))
check("M18 both sides only seed 1 INCONCLUSIVE",
      res["inconclusive"] is True and res["fail"] is False
      and "missing seed" in table)

# M19. Both sides the SAME 20 of 21 seeds (symmetric truncation) ->
#      INCONCLUSIVE: incomplete populations are not comparable evidence.
rows20 = [{"wall": 1.0, "instructions": 1000 + s, "mode": "mono",
           "seed": s} for s in S20]
res, table = run_mode({"wl": [dict(r) for r in rows20]},
                      blank_doc({"wl": rows20}))
check("M19 both sides same 20-of-21 seeds INCONCLUSIVE",
      res["inconclusive"] is True and "missing seed" in table)

# M20. Both sides 21 COPIES of seed 1 (duplicates the old dict
#      comprehension silently collapsed) -> INCONCLUSIVE.
dupes = [{"wall": 1.0, "instructions": 1000, "mode": "mono", "seed": 1}
         for _ in S21]
res, table = run_mode({"wl": [dict(r) for r in dupes]},
                      blank_doc({"wl": dupes}))
check("M20 both sides 21 copies of seed 1 INCONCLUSIVE",
      res["inconclusive"] is True and "duplicate seed" in table)

# M21. Candidate carries an EXTRA seed 99 -> INCONCLUSIVE.
cand = [dict(r) for r in full_rows] + [{"wall": 1.0, "instructions": 1000,
                                        "mode": "mono", "seed": 99}]
res, table = run_mode({"wl": cand}, blank_doc({"wl": full_rows}))
check("M21 extra seed 99 INCONCLUSIVE",
      res["inconclusive"] is True and "extra seed" in table)

# M22. A row with a NULL seed -> INCONCLUSIVE.
nullseed = [dict(r) for r in full_rows]
nullseed[5]["seed"] = None
res, table = run_mode({"wl": nullseed}, blank_doc({"wl": full_rows}))
check("M22 null seed INCONCLUSIVE",
      res["inconclusive"] is True and "null seed" in table)


# ---------------------------------------------------------------------------
# P16.45-finalization BLOCKER 4: test the REAL production serializer
# (build_baseline_document / validate_baseline_document /
# write_baseline_atomic — the same helpers the CLI --update-baseline path
# calls). The previous hand-rolled version stayed green when production
# broke; this one cannot.
# ---------------------------------------------------------------------------
import copy


def _mk_current():
    # Task 0: a schema-valid paired-seed current session — every workload
    # carries exactly one row per published seed with positive
    # wall/instructions and a mode label, plus the protocol declaration.
    zig_samples = {
        wl: [{"wall": 1.0, "instructions": 1000 + s, "mode": "mono",
              "seed": s} for s in pc.SEED_LIST]
        for wl in pc.WORKLOADS
    }
    mode_evidence = {
        wl: {"centers": {"mono": 1000 + pc.SEED_LIST[len(pc.SEED_LIST) // 2]},
             "split_rel_gap": 0.0, "n": len(pc.SEED_LIST)}
        for wl in pc.WORKLOADS
    }
    return {"created_utc": "2026-09-14T00:00:00Z",
            "host": {"platform": "test"},
            "zig": {"w1": 1.0, "w2": 2.0},
            "puc": {"w1": 0.5, "w2": 1.0},
            "ratios": {"w1": 2.0, "w2": 2.0},
            "zig_samples": zig_samples,
            "mode_evidence": mode_evidence,
            "seed_list": pc.SEED_LIST,
            "protocol": "paired-seed-v1"}


SPREADS = {"w1": {"min": 0.9, "max": 1.1, "median": 1.0},
           "w2": {"min": 1.9, "max": 2.1, "median": 2.0}}
INJ_PROV = {"git_head": "cccc" * 10, "zig_binary_sha256": "dddd" * 8,
            "puc_binary_sha256": "eeee" * 8}


# ---------------------------------------------------------------------------
# P16.48-review MEDIUM: manifest schema contract + redirect separation.
# ---------------------------------------------------------------------------
def test_manifest_contract():
    check("manifest: redirected run must not touch canonical",
          pc.should_write_manifest("/tmp/review.json", "") is False)
    check("manifest: canonical run writes canonical",
          pc.should_write_manifest("", "") is True)
    check("manifest: explicit manifest-out wins over gate-out",
          pc.should_write_manifest("/tmp/r.json", "/tmp/m.json") is True)
    with tempfile.TemporaryDirectory() as td:
        mp = Path(td) / "manifest.json"
        entry = {"created_utc": "2026-09-14T00:00:00Z",
                 "source_head": "a" * 40,
                 "zig_binary_sha256": "b" * 64,
                 "seed_list": [1, 2], "runs": 21, "result": "OK",
                 "artifact_sha256": "c" * 64, "mode_centers": {}}
        pc.manifest_append(mp, entry)
        pc.manifest_append(mp, dict(entry, result="FAIL"))
        data = _json.loads(mp.read_text())
        check("manifest: atomic append keeps history",
              [e["result"] for e in data] == ["OK", "FAIL"])
        check("manifest: no tmp residue",
              not (Path(str(mp) + ".tmp")).exists())
    # Canonical manifest (if present): rows written by the paired-seed
    # protocol (they carry "seed_list") must carry FULL 64-hex digests —
    # never null, never a short prefix posing as a full hash. Legacy rows
    # (pre-protocol, no "seed_list") may carry a null zig digest — the old
    # writer never recorded it and the true historical digest is
    # unrecoverable — but a short/prefix digest must still fail, and every
    # row's artifact hash must be a full 64-hex string.
    canon = REPO / "tools/perf/current-gate-manifest.json"
    if canon.exists():
        rows = _json.loads(canon.read_text())
        def _hex64(v):
            return isinstance(v, str) and len(v) == 64
        ok_hashes = all(
            (_hex64(e.get("zig_binary_sha256"))
             if "seed_list" in e
             else (e.get("zig_binary_sha256") is None
                   or _hex64(e.get("zig_binary_sha256"))))
            and _hex64(e.get("artifact_sha256"))
            for e in rows) if rows else True
        check("manifest: canonical rows carry full 64-hex hashes", ok_hashes)


test_manifest_contract()


def test_real_serializer():
    doc = pc.build_baseline_document(_mk_current(), SPREADS, len(pc.SEED_LIST),
                                     "0", "test-phase", "caller note", prov=INJ_PROV)
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
# Task 0: bounded paired-seed schema hardening — the production validator
# (validate_baseline_document) must reject every incomplete / corrupt
# protocol declaration and seed population, so such a doc can never
# replace a valid approved baseline via write_baseline_atomic.
# ---------------------------------------------------------------------------
def test_paired_seed_schema():
    doc = pc.build_baseline_document(_mk_current(), SPREADS,
                                     len(pc.SEED_LIST), "0", "test-phase",
                                     "caller note", prov=INJ_PROV)
    check("schema: valid paired-seed doc accepted",
          pc.validate_baseline_document(doc))

    def rejects(name, mutate):
        bad = copy.deepcopy(doc)
        mutate(bad)
        check(f"schema: rejects {name}",
              not pc.validate_baseline_document(bad))

    wl0 = pc.WORKLOADS[0]
    rejects("missing protocol", lambda d: d.pop("protocol"))
    rejects("wrong protocol string",
            lambda d: d.update(protocol="anonymous-v0"))
    rejects("missing seed_list", lambda d: d.pop("seed_list"))
    rejects("duplicate seed_list entries",
            lambda d: d.update(seed_list=[1, 1] + pc.SEED_LIST[2:]))
    rejects("runs != len(seed_list)",
            lambda d: d.update(runs=len(pc.SEED_LIST) - 1))

    def _dup_seed(d):
        d["zig_samples"][wl0][1]["seed"] = d["zig_samples"][wl0][0]["seed"]
    rejects("zig_samples workload with duplicate seed", _dup_seed)
    rejects("zig_samples workload missing a seed",
            lambda d: d["zig_samples"][wl0].pop(0))
    rejects("row with wall=0",
            lambda d: d["zig_samples"][wl0][0].update(wall=0))
    rejects("row with instructions=0",
            lambda d: d["zig_samples"][wl0][0].update(instructions=0))
    rejects("row with empty mode",
            lambda d: d["zig_samples"][wl0][0].update(mode=""))
    rejects("row with null seed",
            lambda d: d["zig_samples"][wl0][0].update(seed=None))
    rejects("mode_evidence missing a workload",
            lambda d: d["mode_evidence"].pop(wl0))
    rejects("mode_evidence empty centers",
            lambda d: d["mode_evidence"][wl0].update(centers={}))
    rejects("zig_samples missing a workload",
            lambda d: d["zig_samples"].pop(wl0))

    # build_baseline_document refuses to RECORD inconsistent metadata:
    # runs != len(seed_list) raises instead of serializing.
    try:
        pc.build_baseline_document(_mk_current(), SPREADS,
                                   len(pc.SEED_LIST) - 1, "0",
                                   "test-phase", prov=INJ_PROV)
        raised = False
    except ValueError:
        raised = True
    check("schema: build_baseline_document rejects runs != len(seed_list)",
          raised)


test_paired_seed_schema()



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
