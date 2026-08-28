#!/usr/bin/env python3
"""
status_summary.py — single source of truth for quantitative status claims.

Reads JSON reports produced by the test/perf lanes:
  --matrix-json   `python3 tools/testes_matrix.py --testc --json-out <path>`
  --smoke-json    `python3 tools/smoke_compare.py --json-out <path>`
  --perf-json     `python3 tools/perf_compare.py --json-out <path>`
plus the C API suite list parsed from tests/c_api/Makefile (TESTS variable).

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

BEGIN_MARKER = "<!-- BEGIN GENERATED STATUS (tools/status_summary.py) -->"
END_MARKER = "<!-- END GENERATED STATUS -->"

# STATUS.md compact summary uses its own markers so the same generated data
# feeds both files and they cannot drift apart again.
STATUS_BEGIN_MARKER = "<!-- BEGIN GENERATED SUMMARY (tools/status_summary.py) -->"
STATUS_END_MARKER = "<!-- END GENERATED SUMMARY -->"

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

def parity_rows(matrix: dict | None, smoke: dict | None, capi_n: int | None) -> list[str]:
    """Build the Parity table rows from the provided inputs."""
    rows: list[str] = []

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
            "| Upstream matrix (`testes/*.lua`, `--testc`) | _not run — no matrix JSON provided_ |"
        )

    if smoke:
        rows.append(
            f"| Smoke tests (`tests/smoke/*.lua`) | **{smoke.get('ok', 0)}/{smoke.get('total', 0)}** "
            "match (byte-identical stdout+stderr+exit) |"
        )
    else:
        rows.append("| Smoke tests (`tests/smoke/*.lua`) | _not run — no smoke JSON provided_ |")

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


def perf_section(perf: dict | None) -> list[str]:
    """Build the Performance section: geomean + per-workload table (worst first).

    Geomean mirrors perf_compare.py's print_table: exp(mean(log(ratio))).
    """
    lines: list[str] = ["### Performance", ""]
    if not perf:
        lines.append("Geomean slowdown vs PUC Lua: _not run — no perf JSON provided._")
        lines.append("")
        return lines

    ratios: dict[str, float] = perf.get("ratios", {})
    if not ratios:
        lines.append("Geomean slowdown vs PUC Lua: _no ratios in perf JSON._")
        lines.append("")
        return lines

    geomean = math.exp(sum(math.log(r) for r in ratios.values()) / len(ratios))
    runs = perf.get("runs", "?")
    lines.append(
        f"Geomean slowdown vs PUC Lua: **{geomean:.2f}x** (lower is better; 1.0x = parity)."
    )
    lines.append(f"Method: median-of-{runs} per workload, pinned CPU core (`tools/perf_compare.py`).")
    lines.append("")
    lines.append("| Workload | Zig/PUC |")
    lines.append("|----------|--------:|")
    for name, ratio in sorted(ratios.items(), key=lambda kv: kv[1], reverse=True):
        lines.append(f"| {name} | {ratio:.2f}x |")
    lines.append("")
    return lines


def build_block(matrix: dict | None, smoke: dict | None, perf: dict | None) -> str:
    """Assemble the full generated status block (without the markers)."""
    capi_n = parse_capi_suite_count(CAPI_MAKEFILE)
    lines: list[str] = ["### Parity", "", "| Metric | Result |", "|--------|--------|"]
    lines.extend(parity_rows(matrix, smoke, capi_n))
    lines.append("")
    lines.append("Regression lane: `python3 tools/testes_matrix.py --testc` (no `_port`/`_soft` prelude overrides).")
    lines.append("")
    lines.extend(perf_section(perf))
    # Trim the trailing blank line; the END marker follows on its own line.
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# STATUS.md compact summary rewrite
# ---------------------------------------------------------------------------

def build_status_summary_block(matrix: dict | None, smoke: dict | None,
                               perf: dict | None) -> str:
    """Compact summary for the top of STATUS.md, from the same JSON inputs as
    the README block. One generated source of truth for both files."""
    lines: list[str] = ["| Metric | Result |", "|--------|--------|"]

    if matrix:
        s = matrix.get("summary", {})
        lines.append(
            f"| Upstream matrix (`testes/*.lua`, `--testc`) | **{s.get('pass', 0)}/{s.get('total', 0)}** pass "
            "(exit code parity) |"
        )
        lines.append(f"| Matrix non-pass | {matrix_nonpass_detail(matrix)} |")
        lines.append(f"| Differential output (`--diff`) | **{s.get('output_diff', 0)} output_diff** |")
    else:
        lines.append("| Upstream matrix (`testes/*.lua`, `--testc`) | _not run — no matrix JSON provided_ |")
        lines.append("| Differential output (`--diff`) | _not run_ |")

    if smoke:
        lines.append(f"| Smoke tests (`tests/smoke/*.lua`) | **{smoke.get('ok', 0)}/{smoke.get('total', 0)}** pass |")
    else:
        lines.append("| Smoke tests (`tests/smoke/*.lua`) | _not run — no smoke JSON provided_ |")

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
        lines.append("| Performance (geomean vs PUC) | _not run — no perf JSON provided_ |")

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
    ap.add_argument("--write-readme", action="store_true",
                    help="replace the generated block in README.md instead of printing")
    ap.add_argument("--write-status", action="store_true",
                    help="also replace the generated compact summary in STATUS.md")
    args = ap.parse_args()

    matrix = load_json(args.matrix_json)
    smoke = load_json(args.smoke_json)
    perf = load_json(args.perf_json)

    block = build_block(matrix, smoke, perf)
    if args.write_readme:
        write_readme(block)
    if args.write_status:
        write_status_summary(build_status_summary_block(matrix, smoke, perf))
    else:
        print(block)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
