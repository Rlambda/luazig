#!/usr/bin/env python3
"""P16.50-review-7 BLOCKER 5: status-generator provenance-separation tests.

Covers the snapshot/gate confusion: tools/status_summary.py used to derive
the "N published seeds" protocol claim from the ordinary measurement
snapshot (current.json, runs=5) instead of the paired-seed gate artifact
(current-gate.json, published seeds 1..21), and the api580 wording used to
present the charged/model totals (376/428) as measured anchored deltas.

The generator must:
  (a) label the geomean/run-count as a measurement snapshot;
  (b) take the protocol claim (seed list, runs, verdict) ONLY from a
      separately loaded and VALIDATED current-gate.json;
  (c) render missing/corrupt/schema-incompatible gate or ledger artifacts
      as unavailable/inconclusive — never an invented protocol, never a
      crash;
  (d) never render a gate/ledger verdict as green when its recorded
      source/binary identity differs from the snapshot's;
  (e) call only measured_delta_anchored/no_xy_root measurements and label
      the reconciliation charged totals as model charges.

Run: python3 tools/test_status_summary.py
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "status_summary", REPO / "tools" / "status_summary.py")
ss = importlib.util.module_from_spec(_spec)
sys.modules["status_summary"] = ss
_spec.loader.exec_module(ss)

FAILS = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global FAILS
    status = "ok" if cond else "FAIL"
    if not cond:
        FAILS += 1
    print(f"  {name}: {status}{(' — ' + detail) if detail and not cond else ''}")


# ---------------------------------------------------------------------------
# Fixtures. The snapshot mimics tools/perf/current.json (an ORDINARY 5-run
# measurement); the gate mimics tools/perf/current-gate.json (the paired
# seed protocol artifact with published seeds 1..21).
# ---------------------------------------------------------------------------
SNAP_PROV = {"git_head": "abc1234", "measured_source_head": "abc1234",
             "zig_binary_sha16": "feedfacefeedface",
             "puc_binary_sha16": "0123456789abcdef"}


def snapshot(runs: int = 5) -> dict:
    return {"created_utc": "2026-09-18T00:00:00Z", "runs": runs,
            "provenance": dict(SNAP_PROV),
            "ratios": {"int_arith": 1.31, "string_concat": 1.06}}


def gate_doc(runs: int = 21, verdict: str = "OK", prov: dict | None = None,
             seeds: list[int] | None = None) -> dict:
    seeds = seeds if seeds is not None else list(range(1, runs + 1))
    rows = [{"wall": 0.1, "instructions": 1000 + s, "mode": "mono", "seed": s}
            for s in seeds]
    return {"created_utc": "2026-09-18T00:00:00Z",
            "provenance": dict(prov if prov is not None else SNAP_PROV),
            "runs": runs, "core": "0",
            "result": {"verdict": verdict, "line": f"RESULT: {verdict}"},
            "zig_samples": {"int_arith": [dict(r) for r in rows],
                            "string_concat": [dict(r) for r in rows]}}


def api580_doc(measured_a: int = 111, measured_n: int = 222,
               charged_a: int = 100, charged_n: int = 200,
               verdict: str = "GREEN", prov: dict | None = None) -> dict:
    return {"verdict": verdict, "gate_threshold": 400,
            "measured_delta_anchored": measured_a,
            "measured_delta_no_xy_root": measured_n,
            "provenance": dict(prov if prov is not None else SNAP_PROV),
            "reconciliation": {
                "anchored": {"measured": measured_a,
                             "charged_total": charged_a,
                             "reconciled": False},
                "no_xy_root": {"measured": measured_n,
                               "charged_total": charged_n,
                               "reconciled": False}},
            "per_mode": {"ReleaseFast": {"provenance": dict(
                prov if prov is not None else SNAP_PROV)}}}


def render(gate, api580, perf=None) -> str:
    return ss.build_block(None, None, perf or snapshot(), gate, api580)


# ---------------------------------------------------------------------------
# G1-G3: the core BLOCKER 5 fixture — snapshot runs=5 + gate runs=21.
# ---------------------------------------------------------------------------
text = render(gate_doc(), api580_doc())
check("G1 never claims the snapshot run-count as the protocol",
      "5 published seeds" not in text and "5 seeds" not in text)
check("G1 gate part shows the 21 published seeds",
      "21 published seeds (1..21)" in text)
check("G1 snapshot part is labeled a snapshot with its own runs",
      "measurement snapshot, runs=5 per workload" in text)
check("G1 green gate verdict rendered on identity match",
      "Latest gate verdict: **OK**" in text)

# G2. Missing gate artifact -> unavailable wording, no protocol claim.
text = render(None, api580_doc())
check("G2 missing gate -> unavailable wording",
      "Gate protocol: _unavailable" in text)
check("G2 missing gate -> no seed-count claim",
      "published seeds" not in text)

# G3. Schema-incompatible gate artifacts -> inconclusive, never a claim.
for name, bad in [
    ("missing runs", lambda g: g.pop("runs")),
    ("runs disagrees with seed population",
     lambda g: g.update(runs=20)),
    ("missing verdict", lambda g: g["result"].pop("verdict")),
    ("missing result", lambda g: g.pop("result")),
    ("duplicate seed", lambda g: g["zig_samples"]["int_arith"][1].update(
        seed=g["zig_samples"]["int_arith"][0]["seed"])),
    ("workload missing a seed",
     lambda g: g["zig_samples"]["int_arith"].pop(0)),
    ("workloads carry different seeds",
     lambda g: g["zig_samples"]["string_concat"].pop()),
    ("null seed", lambda g: g["zig_samples"]["int_arith"][0].update(
        seed=None)),
    ("missing provenance", lambda g: g.pop("provenance")),
    ("provenance without identity fields",
     lambda g: g.update(provenance={"zig_version": "0.16.0"})),
    ("non-dict artifact", lambda g: None),
]:
    g = gate_doc()
    if name == "non-dict artifact":
        g = "corrupt"
    else:
        bad(g)
    text = render(g, api580_doc())
    check(f"G3 gate {name} -> inconclusive",
          "Gate protocol: _inconclusive" in text
          and "failed validation" in text)
    check(f"G3 gate {name} -> no seed-count claim",
          "published seeds" not in text)

# ---------------------------------------------------------------------------
# G4-G6: identity rules — a gate/ledger recorded on a different
# source/binary than the snapshot is never a green claim.
# ---------------------------------------------------------------------------
mismatch_prov = dict(SNAP_PROV, zig_binary_sha16="deadbeefdeadbeef")
text = render(gate_doc(prov=mismatch_prov), api580_doc())
check("G4 binary mismatch -> not a green claim",
      "not a green claim" in text)
check("G4 binary mismatch -> no bold OK verdict",
      "Latest gate verdict: **OK**" not in text)

mismatch_src = dict(SNAP_PROV, measured_source_head="ffff000")
text = render(gate_doc(prov=mismatch_src), api580_doc())
check("G5 source mismatch -> not a green claim",
      "not a green claim" in text
      and "Latest gate verdict: **OK**" not in text)

# G6. Snapshot without provenance -> identity unverifiable -> not green.
snap_noprov = snapshot()
del snap_noprov["provenance"]
text = render(gate_doc(), api580_doc(), perf=snap_noprov)
check("G6 unverifiable identity -> not a green claim",
      "not a green claim" in text
      and "Latest gate verdict: **OK**" not in text)

# G7. A non-OK verdict is rendered honestly (never green by wording).
text = render(gate_doc(verdict="FAIL"), api580_doc())
check("G7 FAIL verdict rendered honestly",
      "Latest gate verdict: **FAIL**" in text)

# ---------------------------------------------------------------------------
# A1-A5: api580 wording — measured fields vs charged/model totals.
# ---------------------------------------------------------------------------
text = render(gate_doc(), api580_doc())
check("A1 measured deltas come from measured_delta_* fields",
      "measured delta **111 B anchored / 222 B no-XY-root**" in text)
check("A1 charged totals labeled as model charges",
      "Charged/model totals 100/200 B" in text
      and "allocation-model charges, not measurements" in text)
check("A1 charged totals never called measured",
      "measured delta **100" not in text and "measured 376" not in text)

text = render(gate_doc(), None)
check("A2 missing ledger -> unavailable wording",
      "api580 fixed-load footprint: _unavailable" in text)

bad_ledger = api580_doc()
del bad_ledger["measured_delta_anchored"]
text = render(gate_doc(), bad_ledger)
check("A3 ledger missing measured field -> inconclusive",
      "api580 fixed-load footprint: _inconclusive" in text)

text = render(gate_doc(), api580_doc(prov=mismatch_prov))
check("A4 ledger identity mismatch -> not a green claim",
      "not a green claim" in text and "verdict **GREEN**" not in text)

# A5. Ledger without a reconciliation block: measured numbers only, no
# invented charged totals.
no_rec = api580_doc()
del no_rec["reconciliation"]
text = render(gate_doc(), no_rec)
check("A5 no reconciliation block -> no charged totals invented",
      "measured delta **111 B anchored / 222 B no-XY-root**" in text
      and "Charged/model totals" not in text)

# ---------------------------------------------------------------------------
# C1-C4: compact STATUS.md summary rows follow the same rules.
# ---------------------------------------------------------------------------
rows = ss.build_status_summary_block(None, None, snapshot(), gate_doc(),
                                     api580_doc())
check("C1 gate row shows 21 published seeds with verdict",
      "**OK** — 21 published seeds (1..21)" in rows)
check("C1 gate row never shows 5 published seeds",
      "5 published seeds" not in rows)
check("C1 api580 row uses measured fields",
      "**GREEN** — measured 111/222 B vs threshold 400 B" in rows)

rows = ss.build_status_summary_block(None, None, snapshot(), None, None)
check("C2 missing artifacts -> unavailable rows",
      "_unavailable — no current-gate.json_" in rows
      and "_unavailable — no current-api580-ledger.json_" in rows)

rows = ss.build_status_summary_block(None, None, snapshot(),
                                     gate_doc(prov=mismatch_prov),
                                     api580_doc(prov=mismatch_prov))
check("C3 identity mismatch -> not-green rows",
      "not a green claim" in rows and "**OK**" not in rows
      and "**GREEN**" not in rows)

bad_g = gate_doc()
bad_g["runs"] = 5  # schema lie: 5 runs vs 21-seed population
rows = ss.build_status_summary_block(None, None, snapshot(), bad_g,
                                     api580_doc())
check("C4 invalid gate schema -> inconclusive row",
      "_inconclusive — gate artifact failed validation_" in rows)

# ---------------------------------------------------------------------------
# CLI1-CLI4: end-to-end generator runs on temp fixtures (stdout mode only —
# canonical README.md/STATUS.md are never touched by this test).
# ---------------------------------------------------------------------------
def run_cli(*extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(REPO / "tools" / "status_summary.py"), *extra],
        capture_output=True, text=True, cwd=REPO)


with tempfile.TemporaryDirectory(dir="/tmp/opencode") as td:
    snap_path = Path(td) / "snapshot.json"
    gate_path = Path(td) / "gate.json"
    api_path = Path(td) / "api580.json"
    snap_path.write_text(json.dumps(snapshot()))
    gate_path.write_text(json.dumps(gate_doc()))
    api_path.write_text(json.dumps(api580_doc()))

    r = run_cli("--perf-json", str(snap_path),
                "--gate-json", str(gate_path),
                "--api580-json", str(api_path))
    check("CLI1 snapshot+gate+ledger run exits 0", r.returncode == 0)
    check("CLI1 output separates snapshot from 21-seed gate",
          "measurement snapshot, runs=5 per workload" in r.stdout
          and "21 published seeds (1..21)" in r.stdout
          and "5 published seeds" not in r.stdout)

    missing = Path(td) / "missing-gate.json"
    r = run_cli("--perf-json", str(snap_path),
                "--gate-json", str(missing),
                "--api580-json", str(api_path))
    check("CLI2 missing gate file -> unavailable, no crash",
          r.returncode == 0 and "Gate protocol: _unavailable" in r.stdout)

    corrupt = Path(td) / "corrupt-gate.json"
    corrupt.write_text('{"runs": 21, "result": {broken')
    r = run_cli("--perf-json", str(snap_path),
                "--gate-json", str(corrupt),
                "--api580-json", str(api_path))
    check("CLI3 corrupt gate JSON -> inconclusive, no crash",
          r.returncode == 0 and "Gate protocol: _inconclusive" in r.stdout)

    other_bin = gate_doc(prov=dict(SNAP_PROV,
                                   zig_binary_sha16="cafebabecafebabe"))
    other_path = Path(td) / "gate-other-bin.json"
    other_path.write_text(json.dumps(other_bin))
    r = run_cli("--perf-json", str(snap_path),
                "--gate-json", str(other_path),
                "--api580-json", str(api_path))
    check("CLI4 gate on another binary -> not green",
          r.returncode == 0 and "not a green claim" in r.stdout
          and "Latest gate verdict: **OK**" not in r.stdout)

# ---------------------------------------------------------------------------
# Canonical artifacts (when present) must render without crashing and the
# gate part must agree with the artifact's own runs (21), not the
# snapshot's (5).
# ---------------------------------------------------------------------------
if ss.GATE_DEFAULT.exists():
    gate = json.loads(ss.GATE_DEFAULT.read_text(encoding="utf-8"))
    text = render(gate, None)
    ok, reason = ss.validate_gate(gate)
    check("canonical current-gate.json passes validation", ok, reason)
    check("canonical gate renders its own runs as the seed count",
          f"{gate['runs']} published seeds" in text)
else:
    check("canonical current-gate.json passes validation", False, "missing")

if ss.API580_DEFAULT.exists():
    ledger = json.loads(ss.API580_DEFAULT.read_text(encoding="utf-8"))
    ok, reason = ss.validate_api580(ledger)
    check("canonical api580 ledger passes validation", ok, reason)
    text = render(gate_doc(), ledger)
    check("canonical ledger measured fields rendered",
          f"measured delta **{ledger['measured_delta_anchored']} B anchored / "
          f"{ledger['measured_delta_no_xy_root']} B no-XY-root**" in text)
    rec = ledger.get("reconciliation", {})
    ca = rec.get("anchored", {}).get("charged_total")
    cn = rec.get("no_xy_root", {}).get("charged_total")
    check("canonical charged totals labeled as model charges",
          f"Charged/model totals {ca}/{cn} B" in text
          and "not measurements" in text)
else:
    check("canonical api580 ledger passes validation", False, "missing")

print(f"\n{'ALL OK' if FAILS == 0 else str(FAILS) + ' FAILURES'}")
sys.exit(1 if FAILS else 0)
