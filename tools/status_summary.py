#!/usr/bin/env python3
"""
status_summary.py — single source of truth for quantitative status claims.

Reads JSON reports produced by the test/perf lanes:
  --matrix-json   `python3 tools/testes_matrix.py --testc --json-out <path>`
  --smoke-json    `python3 tools/smoke_compare.py --json-out <path>`
  --perf-json     `python3 tools/perf_compare.py --json-out <path>`
plus the C API suite list parsed from tests/c_api/Makefile (TESTS variable).

Performance provenance is split by source of truth (P16.50-review-7 BLOCKER 5):
  - ratios/geomean come from the ordinary measurement snapshot (current.json)
    and are labeled as such; the snapshot run-count is NEVER presented as the
    gate protocol;
  - the paired-seed protocol claim (seed list/runs, verdict) comes from a
    separately loaded and VALIDATED tools/perf/current-gate.json;
  - the api580 fixed-load footprint comes from tools/perf/current-api580-ledger.json
    and uses the MEASURED fields (measured_delta_anchored/no_xy_root); the
    charged/model totals are explicitly labeled as model charges, never as
    measurements.
A missing or schema-incompatible gate/ledger yields honest unavailable/
inconclusive wording, never an invented protocol. A gate/ledger recorded on a
different source/binary than the snapshot is never rendered as a green claim.

Emits a deterministic markdown status block (parity table + performance
table). With --write-readme the block replaces the content between the
BEGIN/END GENERATED STATUS markers in README.md; by default the block is
printed to stdout.

Honesty rule: only numbers backed by the provided inputs are emitted. A
missing input yields an explicit "not run" row/note, never a fabricated or
stale number. No timestamps are embedded, so regeneration is idempotent.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"
CAPI_MAKEFILE = ROOT / "tests" / "c_api" / "Makefile"
PHASE_FILE = ROOT / "tools" / "status" / "phase.txt"
GATE_DEFAULT = ROOT / "tools" / "perf" / "current-gate.json"
API580_DEFAULT = ROOT / "tools" / "perf" / "current-api580-ledger.json"

BEGIN_MARKER = "<!-- BEGIN GENERATED STATUS (tools/status_summary.py) -->"
END_MARKER = "<!-- END GENERATED STATUS -->"

# STATUS.md compact summary uses its own markers so the same generated data
# feeds both files and they cannot drift apart again.
STATUS_BEGIN_MARKER = "<!-- BEGIN GENERATED SUMMARY (tools/status_summary.py) -->"
STATUS_END_MARKER = "<!-- END GENERATED SUMMARY -->"

# The "Last updated" line at the very top of STATUS.md.  Machine-generated
# from tools/status/phase.txt (written by status_snapshot.py --phase) so it
# never suffers hand-edit drift.
LAST_UPDATED_RE = re.compile(r"^> Last updated: .*$", re.MULTILINE)

# ---------------------------------------------------------------------------
# Input loading
# ---------------------------------------------------------------------------

def load_json(path: str | None) -> dict | None:
    """Load an optional JSON report; return None (with a note) if absent."""
    if not path:
        return None
    p = Path(path)
    if not p.exists():
        print(f"note: {path} does not exist, skipping", file=sys.stderr)
        return None
    return json.loads(p.read_text(encoding="utf-8"))


def load_artifact(path: str | None) -> object | None:
    """Load a canonical perf artifact tolerantly.

    Returns None when the file is missing (rendered as "unavailable") and
    the string "corrupt" when it exists but does not parse (rendered as
    "inconclusive" by the validators below). Never raises, so a damaged
    artifact cannot crash the generator.
    """
    if not path:
        return None
    p = Path(path)
    if not p.exists():
        print(f"note: {path} does not exist, skipping", file=sys.stderr)
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"note: {path} is not valid JSON ({e}); treating as corrupt",
              file=sys.stderr)
        return "corrupt"


def parse_capi_suite_count(makefile: Path) -> int | None:
    """Count C API suites from the TESTS variable in tests/c_api/Makefile.

    Handles Make backslash-newline continuations by joining them first.
    Returns the number of suite names, or None if the Makefile/variable
    is missing (the caller then emits an honest 'not available' row).
    """
    if not makefile.exists():
        return None
    joined = makefile.read_text(encoding="utf-8").replace("\\\n", " ")
    m = re.search(r"^TESTS\s*=\s*(.+)$", joined, re.MULTILINE)
    if not m:
        return None
    return len(m.group(1).split())


# ---------------------------------------------------------------------------
# Section builders
# ---------------------------------------------------------------------------

def parity_rows(matrix: dict | None, smoke: dict | None, capi_n: int | None,
                versioned: bool = False) -> list[str]:
    """Build the Parity table rows from the provided inputs."""
    rows: list[str] = []
    not_run_matrix = "_not run (no versioned artifact)_" if versioned else "_not run — no matrix JSON provided_"
    not_run_smoke = "_not run (no versioned artifact)_" if versioned else "_not run — no smoke JSON provided_"

    if matrix:
        s = matrix.get("summary", {})
        total = s.get("total", 0)
        ok = s.get("pass", 0)
        rows.append(
            f"| Upstream matrix (`testes/*.lua`, `--testc`) | **{ok}/{total}** pass (exit code parity) |"
        )
        # Non-pass detail: list files per non-pass class, straight from rows.
        detail = matrix_nonpass_detail(matrix)
        rows.append(f"| Matrix non-pass | {detail} |")
    else:
        rows.append(
            f"| Upstream matrix (`testes/*.lua`, `--testc`) | {not_run_matrix} |"
        )

    if smoke:
        rows.append(
            f"| Smoke tests (`tests/smoke/*.lua`) | **{smoke.get('ok', 0)}/{smoke.get('total', 0)}** "
            "match (byte-identical stdout+stderr+exit) |"
        )
    else:
        rows.append(f"| Smoke tests (`tests/smoke/*.lua`) | {not_run_smoke} |")

    if capi_n is not None:
        rows.append(
            f"| C API suites (`tests/c_api`) | {capi_n} suites (gate: `make -C tests/c_api test`) |"
        )
    else:
        rows.append("| C API suites (`tests/c_api`) | _not available — Makefile TESTS not found_ |")

    return rows


def matrix_nonpass_detail(matrix: dict) -> str:
    """Summarize non-passing matrix files from the per-file rows.

    Example: `both_fail: big.lua`. Returns `none` when everything passes.
    """
    by_class: dict[str, list[str]] = {}
    for r in matrix.get("rows", []):
        cls = r.get("class", "")
        if cls not in ("pass", "output_diff"):
            by_class.setdefault(cls, []).append(str(r.get("file", "?")))
    if not by_class:
        return "none"
    return "; ".join(f"{cls}: {', '.join(files)}" for cls, files in sorted(by_class.items()))


# ---------------------------------------------------------------------------
# Performance section: snapshot numbers vs gate protocol vs api580 ledger
# ---------------------------------------------------------------------------

# Provenance fields that identify the measured source/binary. Two artifacts
# agree only when every field present in BOTH carries the same value; no
# shared field means the identity relation is unverifiable.
IDENTITY_KEYS = ("measured_source_head", "git_head",
                 "zig_binary_sha16", "puc_binary_sha16")


def validate_gate(gate: object) -> tuple[bool, str]:
    """Validate the paired-seed gate artifact schema.

    Required: a positive integer ``runs``, a ``result.verdict``, a
    ``zig_samples`` population where every workload carries exactly one row
    per published seed (same seed set everywhere, no duplicates, usable
    seed identities, positive instruction counts), and a ``provenance``
    block with at least one source/binary identity field. Returns
    (ok, reason); reason is empty when ok.
    """
    if not isinstance(gate, dict):
        return False, "gate artifact is not a JSON object"
    runs = gate.get("runs")
    if isinstance(runs, bool) or not isinstance(runs, int) or runs <= 0:
        return False, "runs must be a positive integer"
    result = gate.get("result")
    if not isinstance(result, dict):
        return False, "result section missing"
    verdict = result.get("verdict")
    if not isinstance(verdict, str) or not verdict:
        return False, "result.verdict missing"
    samples = gate.get("zig_samples")
    if not isinstance(samples, dict) or not samples:
        return False, "zig_samples section missing"
    seed_sets: list[frozenset[int]] = []
    for wl, rows in samples.items():
        if not isinstance(rows, list) or not rows:
            return False, f"zig_samples[{wl}] has no rows"
        seeds: list[int] = []
        for r in rows:
            if not isinstance(r, dict):
                return False, f"zig_samples[{wl}] has a malformed row"
            s = r.get("seed")
            if isinstance(s, bool) or not isinstance(s, int) or s <= 0:
                return False, f"zig_samples[{wl}] has a row with an unusable seed"
            ins = r.get("instructions")
            if isinstance(ins, bool) or not isinstance(ins, int) or ins <= 0:
                return False, f"zig_samples[{wl}] has a row with unusable instructions"
            seeds.append(s)
        if len(set(seeds)) != len(seeds):
            return False, f"zig_samples[{wl}] has duplicate seeds"
        seed_sets.append(frozenset(seeds))
    if any(s != seed_sets[0] for s in seed_sets[1:]):
        return False, "workloads carry different seed populations"
    if len(seed_sets[0]) != runs:
        return False, (f"runs={runs} but workloads carry "
                       f"{len(seed_sets[0])} distinct seeds")
    prov = gate.get("provenance")
    if not isinstance(prov, dict):
        return False, "provenance section missing"
    if not any(k in prov for k in IDENTITY_KEYS):
        return False, "provenance carries no source/binary identity fields"
    return True, ""


def validate_api580(doc: object) -> tuple[bool, str]:
    """Validate the api580 fixed-load ledger schema (measured fields only)."""
    if not isinstance(doc, dict):
        return False, "ledger is not a JSON object"
    for key in ("measured_delta_anchored", "measured_delta_no_xy_root",
                "gate_threshold"):
        v = doc.get(key)
        if isinstance(v, bool) or not isinstance(v, int) or v < 0:
            return False, f"{key} must be a non-negative integer"
    verdict = doc.get("verdict")
    if not isinstance(verdict, str) or not verdict:
        return False, "verdict missing"
    return True, ""


def identity_relation(artifact_prov: object, snapshot_prov: object) -> str:
    """Relate an artifact's measured identity to the snapshot's.

    Returns "match" (every shared identity field agrees), "mismatch" (some
    shared field differs), or "unverifiable" (no shared identity field, so
    the artifact cannot be tied to the snapshot's source/binary).
    """
    if not isinstance(artifact_prov, dict) or not isinstance(snapshot_prov, dict):
        return "unverifiable"
    shared = [k for k in IDENTITY_KEYS
              if k in artifact_prov and k in snapshot_prov]
    if not shared:
        return "unverifiable"
    if any(artifact_prov[k] != snapshot_prov[k] for k in shared):
        return "mismatch"
    return "match"


def api580_identity_prov(doc: dict) -> object:
    """The ledger's ReleaseFast provenance (the mode the perf snapshot uses).

    The ledger's top-level provenance may describe a Debug+ReleaseFast
    measurement pair; the per-mode block carries the ReleaseFast identity
    that must match the snapshot.
    """
    pm = doc.get("per_mode")
    if isinstance(pm, dict):
        rf = pm.get("ReleaseFast")
        if isinstance(rf, dict) and isinstance(rf.get("provenance"), dict):
            return rf["provenance"]
    return doc.get("provenance")


def _seed_span(seeds: list[int], runs: int) -> str:
    """Human form of the published seed list: `1..21` when contiguous."""
    if seeds == list(range(1, runs + 1)):
        return f"1..{runs}"
    return f"{len(seeds)} seeds"


def _not_green_note(rel: str) -> str:
    if rel == "mismatch":
        return ("recorded on a different source/binary than the snapshot — "
                "not a green claim for it")
    return ("recorded without source/binary identity matching the snapshot — "
            "not a green claim for it")


def gate_protocol_lines(gate: object, perf: dict | None) -> list[str]:
    """Render the paired-seed GATE protocol claim from current-gate.json.

    The claim (seed list, runs, verdict) comes exclusively from the
    validated gate artifact — never from the ordinary snapshot's run count.
    """
    if gate is None:
        return ["Gate protocol: _unavailable — no paired-seed gate artifact "
                "(tools/perf/current-gate.json); the snapshot numbers above "
                "are diagnostics, not a gate claim._"]
    ok, reason = validate_gate(gate)
    if not ok:
        return [f"Gate protocol: _inconclusive — the gate artifact failed "
                f"validation ({reason}); no protocol claim is made._"]
    runs = gate["runs"]
    seeds = sorted({r["seed"] for rows in gate["zig_samples"].values()
                    for r in rows})
    verdict = gate["result"]["verdict"]
    method = (f"Gate protocol: paired-seed — {runs} published seeds "
              f"({_seed_span(seeds, runs)}) per workload per session "
              "(`LUAZIG_HASH_SEED` env on the production ReleaseFast binary, "
              "pinned CPU core); verdict = per-seed paired instruction "
              "deltas; wall time is diagnostic only (`tools/perf_compare.py`).")
    rel = identity_relation(gate.get("provenance"), (perf or {}).get("provenance"))
    if rel == "match":
        return [method + f" Latest gate verdict: **{verdict}** "
                "(`tools/perf/current-gate.json`)."]
    return [method + f" Latest gate verdict: {verdict} "
            f"({_not_green_note(rel)}; `tools/perf/current-gate.json`)."]


def _fmt_tristate(v: object) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    return "unknown"


def api580_lines(api580: object, perf: dict | None) -> list[str]:
    """Render the api580 fixed-load footprint from the ledger artifact.

    Only the MEASURED fields (measured_delta_anchored/no_xy_root) are ever
    called measurements; the reconciliation charged totals are explicitly
    labeled as allocation-model charges.
    """
    if api580 is None:
        return ["api580 fixed-load footprint: _unavailable — no ledger artifact "
                "(tools/perf/current-api580-ledger.json)._"]
    ok, reason = validate_api580(api580)
    if not ok:
        return [f"api580 fixed-load footprint: _inconclusive — the ledger "
                f"failed validation ({reason})._"]
    anchored = api580["measured_delta_anchored"]
    no_xy = api580["measured_delta_no_xy_root"]
    threshold = api580["gate_threshold"]
    verdict = api580["verdict"]
    line = (f"api580 fixed-load footprint: measured delta **{anchored} B "
            f"anchored / {no_xy} B no-XY-root** vs threshold {threshold} B")
    rel = identity_relation(api580_identity_prov(api580),
                            (perf or {}).get("provenance"))
    if rel == "match":
        line += f" — verdict **{verdict}**"
    else:
        line += f" — verdict {verdict} ({_not_green_note(rel)})"
    line += " (`tools/perf/current-api580-ledger.json`)."
    rec = api580.get("reconciliation")
    if isinstance(rec, dict):
        ra = rec.get("anchored") if isinstance(rec.get("anchored"), dict) else {}
        rn = rec.get("no_xy_root") if isinstance(rec.get("no_xy_root"), dict) else {}
        ca, cn = ra.get("charged_total"), rn.get("charged_total")
        if (isinstance(ca, int) and not isinstance(ca, bool)
                and isinstance(cn, int) and not isinstance(cn, bool)):
            line += (f" Charged/model totals {ca}/{cn} B (reconciled: "
                     f"{_fmt_tristate(ra.get('reconciled'))}/"
                     f"{_fmt_tristate(rn.get('reconciled'))}) are "
                     "allocation-model charges, not measurements.")
    return [line]


def perf_section(perf: dict | None, gate: object = None,
                 api580: object = None, versioned: bool = False) -> list[str]:
    """Build the Performance section.

    Three provenance-separated parts: the geomean snapshot (current.json,
    honestly labeled as a snapshot), the paired-seed gate protocol claim
    (current-gate.json, validated), and the api580 fixed-load footprint
    (current-api580-ledger.json, measured fields only).

    Geomean mirrors perf_compare.py's print_table: exp(mean(log(ratio))).
    """
    lines: list[str] = ["### Performance", ""]
    not_run = "_not run (no versioned artifact)_" if versioned else "_not run — no perf JSON provided._"
    ratios: dict[str, float] = (perf or {}).get("ratios", {})
    if not perf:
        lines.append(f"Geomean slowdown vs PUC Lua: {not_run}")
    elif not ratios:
        lines.append("Geomean slowdown vs PUC Lua: _no ratios in perf JSON._")
    else:
        geomean = math.exp(sum(math.log(r) for r in ratios.values()) / len(ratios))
        runs = perf.get("runs", "?")
        lines.append(
            f"Geomean slowdown vs PUC Lua: **{geomean:.2f}x** (measurement "
            f"snapshot, runs={runs} per workload; run-dependent diagnostic; "
            "lower is better; 1.0x = parity)."
        )
    lines.append("")
    lines.extend(gate_protocol_lines(gate, perf))
    lines.extend(api580_lines(api580, perf))
    if ratios:
        lines.append("")
        lines.append("| Workload | Zig/PUC |")
        lines.append("|----------|--------:|")
        for name, ratio in sorted(ratios.items(), key=lambda kv: kv[1], reverse=True):
            lines.append(f"| {name} | {ratio:.2f}x |")
    lines.append("")
    return lines


def build_block(matrix: dict | None, smoke: dict | None, perf: dict | None,
                gate: object = None, api580: object = None,
                versioned: bool = False) -> str:
    """Assemble the full generated status block (without the markers)."""
    capi_n = parse_capi_suite_count(CAPI_MAKEFILE)
    lines: list[str] = ["### Parity", "", "| Metric | Result |", "|--------|--------|"]
    lines.extend(parity_rows(matrix, smoke, capi_n, versioned))
    lines.append("")
    lines.append("Regression lane: `python3 tools/testes_matrix.py --testc` (no `_port`/`_soft` prelude overrides).")
    lines.append("")
    lines.extend(perf_section(perf, gate, api580, versioned))
    # Trim the trailing blank line; the END marker follows on its own line.
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# STATUS.md compact summary rewrite
# ---------------------------------------------------------------------------

def gate_summary_row(gate: object, perf: dict | None) -> str:
    """Compact STATUS.md row for the paired-seed gate verdict."""
    if gate is None:
        return "| Perf gate (paired-seed) | _unavailable — no current-gate.json_ |"
    ok, reason = validate_gate(gate)
    if not ok:
        return "| Perf gate (paired-seed) | _inconclusive — gate artifact failed validation_ |"
    runs = gate["runs"]
    seeds = sorted({r["seed"] for rows in gate["zig_samples"].values()
                    for r in rows})
    verdict = gate["result"]["verdict"]
    span = _seed_span(seeds, runs)
    rel = identity_relation(gate.get("provenance"), (perf or {}).get("provenance"))
    if rel == "match":
        return (f"| Perf gate (paired-seed) | **{verdict}** — "
                f"{runs} published seeds ({span}) |")
    return (f"| Perf gate (paired-seed) | {verdict} — "
            f"{_not_green_note(rel)} |")


def api580_summary_row(api580: object, perf: dict | None) -> str:
    """Compact STATUS.md row for the api580 fixed-load footprint."""
    if api580 is None:
        return "| api580 fixed-load footprint | _unavailable — no current-api580-ledger.json_ |"
    ok, _ = validate_api580(api580)
    if not ok:
        return "| api580 fixed-load footprint | _inconclusive — ledger failed validation_ |"
    verdict = api580["verdict"]
    measured = (f"measured {api580['measured_delta_anchored']}/"
                f"{api580['measured_delta_no_xy_root']} B vs threshold "
                f"{api580['gate_threshold']} B")
    rel = identity_relation(api580_identity_prov(api580),
                            (perf or {}).get("provenance"))
    if rel == "match":
        return f"| api580 fixed-load footprint | **{verdict}** — {measured} |"
    return (f"| api580 fixed-load footprint | {verdict} — {measured} "
            f"({_not_green_note(rel)}) |")


def build_status_summary_block(matrix: dict | None, smoke: dict | None,
                               perf: dict | None, gate: object = None,
                               api580: object = None,
                               versioned: bool = False) -> str:
    """Compact summary for the top of STATUS.md, from the same JSON inputs as
    the README block. One generated source of truth for both files."""
    lines: list[str] = ["| Metric | Result |", "|--------|--------|"]
    nr_matrix = "_not run (no versioned artifact)_" if versioned else "_not run — no matrix JSON provided_"
    nr_smoke = "_not run (no versioned artifact)_" if versioned else "_not run — no smoke JSON provided_"
    nr_perf = "_not run (no versioned artifact)_" if versioned else "_not run — no perf JSON provided_"

    if matrix:
        s = matrix.get("summary", {})
        lines.append(
            f"| Upstream matrix (`testes/*.lua`, `--testc`) | **{s.get('pass', 0)}/{s.get('total', 0)}** pass "
            "(exit code parity) |"
        )
        lines.append(f"| Matrix non-pass | {matrix_nonpass_detail(matrix)} |")
        lines.append(f"| Differential output (`--diff`) | **{s.get('output_diff', 0)} output_diff** |")
    else:
        lines.append(f"| Upstream matrix (`testes/*.lua`, `--testc`) | {nr_matrix} |")
        lines.append("| Differential output (`--diff`) | _not run_ |")

    if smoke:
        lines.append(f"| Smoke tests (`tests/smoke/*.lua`) | **{smoke.get('ok', 0)}/{smoke.get('total', 0)}** pass |")
    else:
        lines.append(f"| Smoke tests (`tests/smoke/*.lua`) | {nr_smoke} |")

    capi_n = parse_capi_suite_count(CAPI_MAKEFILE)
    if capi_n is not None:
        lines.append(f"| C API suites (`tests/c_api`) | {capi_n} suites |")
    else:
        lines.append("| C API suites (`tests/c_api`) | _Makefile TESTS not found_ |")

    ratios = (perf or {}).get("ratios", {})
    if ratios:
        geomean = math.exp(sum(math.log(r) for r in ratios.values()) / len(ratios))
        lines.append(f"| Performance (geomean vs PUC) | **{geomean:.2f}x** |")
    else:
        lines.append(f"| Performance (geomean vs PUC) | {nr_perf} |")

    lines.append(gate_summary_row(gate, perf))
    lines.append(api580_summary_row(api580, perf))

    lines.append("")
    if ratios:
        lines.append(
            f"Geomean замедления vs PUC Lua: **{geomean:.2f}x** (цель: 1.0x; run-dependent). "
            "Подробная таблица workload'ов — в generated status-блоке [README.md](README.md)."
        )
    else:
        lines.append(
            "Geomean замедления vs PUC Lua: _not run_. "
            "Подробная таблица workload'ов — в generated status-блоке [README.md](README.md)."
        )
    return "\n".join(lines)


def write_status_summary(block: str) -> None:
    """Replace the content between the STATUS.md summary markers."""
    path = ROOT / "STATUS.md"
    text = path.read_text(encoding="utf-8")
    begin = text.find(STATUS_BEGIN_MARKER)
    end = text.find(STATUS_END_MARKER)
    if begin == -1 or end == -1 or end < begin:
        raise SystemExit("STATUS.md generated-summary markers not found")
    new_text = text[: begin + len(STATUS_BEGIN_MARKER)] + "\n" + block + "\n" + text[end:]
    path.write_text(new_text, encoding="utf-8")


def update_last_updated() -> None:
    """Update the ``> Last updated:`` line in STATUS.md from phase.txt.

    Reads ``tools/status/phase.txt`` (written by ``status_snapshot.py
    --phase``).  If the file is absent the line is left untouched, so
    ``status_summary.py`` called without the orchestrator never clobbers a
    hand-written phase.  When present, the line becomes::

        > Last updated: YYYY-MM-DD (PHASE)

    where PHASE is the full contents of phase.txt and the date is today
    (UTC).  This eliminates hand-edit drift on the phase identifier.
    """
    if not PHASE_FILE.exists():
        return
    phase = PHASE_FILE.read_text(encoding="utf-8").strip()
    if not phase:
        return
    from datetime import datetime, timezone
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    replacement = f"> Last updated: {today} ({phase})"
    path = ROOT / "STATUS.md"
    text = path.read_text(encoding="utf-8")
    new_text, n = LAST_UPDATED_RE.subn(replacement, text, count=1)
    if n == 0:
        # No existing line — insert one after the first line.
        new_text = text.split("\n", 1)[0] + "\n" + replacement + "\n" + text.split("\n", 1)[1]
    path.write_text(new_text, encoding="utf-8")
    print(f"STATUS.md last-updated line updated: {replacement}")


# ---------------------------------------------------------------------------
# README rewrite
# ---------------------------------------------------------------------------

def write_readme(block: str) -> None:
    text = README.read_text(encoding="utf-8")
    begin = text.find(BEGIN_MARKER)
    end = text.find(END_MARKER)
    if begin == -1 or end == -1 or end < begin:
        print(f"error: generated-status markers not found in {README}", file=sys.stderr)
        raise SystemExit(2)
    # Replace everything strictly between the markers, keeping the markers.
    new_text = text[: begin + len(BEGIN_MARKER)] + "\n" + block + "\n" + text[end:]
    README.write_text(new_text, encoding="utf-8")
    print(f"README status block updated: {README}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--matrix-json", default="", help="testes_matrix.py --json-out report")
    ap.add_argument("--smoke-json", default="", help="smoke_compare.py --json-out report")
    ap.add_argument("--perf-json", default="", help="perf_compare.py --json-out report")
    ap.add_argument("--gate-json", default="",
                    help="paired-seed gate artifact (default: "
                         "tools/perf/current-gate.json)")
    ap.add_argument("--api580-json", default="",
                    help="api580 fixed-load ledger artifact (default: "
                         "tools/perf/current-api580-ledger.json)")
    ap.add_argument("--perf-current", action="store_true",
                    help="read the versioned snapshot from tools/perf/current.json "
                         "(takes precedence over --perf-json)")
    ap.add_argument("--use-current", action="store_true",
                    help="read ALL versioned artifacts: tools/status/current-matrix.json, "
                         "tools/status/current-smoke.json, tools/perf/current.json. "
                         "Takes precedence over the explicit --*-json flags. A missing "
                         "artifact yields an honest '_not run (no versioned artifact)_' row.")
    ap.add_argument("--write-readme", action="store_true",
                    help="replace the generated block in README.md instead of printing")
    ap.add_argument("--write-status", action="store_true",
                    help="also replace the generated compact summary in STATUS.md")
    args = ap.parse_args()

    if args.use_current:
        matrix = load_json(str(ROOT / "tools" / "status" / "current-matrix.json"))
        smoke = load_json(str(ROOT / "tools" / "status" / "current-smoke.json"))
        perf = load_json(str(ROOT / "tools" / "perf" / "current.json"))
    else:
        matrix = load_json(args.matrix_json)
        smoke = load_json(args.smoke_json)
        if args.perf_current:
            perf = load_json(str(ROOT / "tools" / "perf" / "current.json"))
        else:
            perf = load_json(args.perf_json)

    # Gate protocol + api580 ledger are loaded independently of the snapshot
    # and validated at render time: a missing/corrupt/incompatible artifact
    # yields honest unavailable/inconclusive wording, never an invented
    # protocol and never a snapshot-run-count passed off as the gate's.
    gate = load_artifact(args.gate_json or str(GATE_DEFAULT))
    api580 = load_artifact(args.api580_json or str(API580_DEFAULT))

    block = build_block(matrix, smoke, perf, gate, api580,
                        versioned=args.use_current)
    if args.write_readme:
        write_readme(block)
    if args.write_status:
        write_status_summary(build_status_summary_block(
            matrix, smoke, perf, gate, api580, versioned=args.use_current))
        update_last_updated()
    else:
        print(block)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
