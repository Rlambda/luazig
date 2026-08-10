#!/usr/bin/env python3
"""
codegen_compare.py — compare bytecode instruction counts between PUC Lua
and luazig for canonical Lua patterns.

For each .lua file under tests/codegen/ (or a custom path), the script runs
both compilers, parses the main-function bytecode disassembly, groups
instructions by source line, and reports per-line inflation — places where
luazig emits more instructions than PUC Lua for the same source construct.

Usage:
  codegen_compare.py                          # scan tests/codegen/
  codegen_compare.py tests/codegen/assign_index.lua
  codegen_compare.py --fail-on-inflation      # exit 1 on any inflation
  codegen_compare.py --quiet                  # only show inflated lines
  codegen_compare.py --puc /path/to/luac --zig /path/to/luazig
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Tuple

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PUC = ROOT / "lua-5.5.0" / "src" / "luac"
DEFAULT_ZIG = ROOT / "zig-out" / "bin" / "luazig"
DEFAULT_TEST_DIR = ROOT / "tests" / "codegen"

# Function-prologue opcode: emitted once per main by both compilers but
# attributed to different source lines (PUC -> first source line, ZIG -> 0).
# Filtering it keeps per-line comparison focused on real codegen.
SKIP_OPCODES = frozenset({"VARARGPREP"})

# A bytecode instruction line in BOTH compilers has the shape:
#   <pc>\t[<source_line>]\t<OPCODE>\t<operands>
# PUC prefixes pc with a single tab; luazig uses leading spaces + tab.
# \s* in the regex absorbs either indentation style.
INSTR_RE = re.compile(r"\s*(\d+)\s*\[(\d+)\]\s*([A-Z][A-Z0-9_]*)\s*(.*)")


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class Instr:
    """One bytecode instruction attributed to a source line."""
    line: int
    opcode: str


@dataclass
class LineCompare:
    """Per-source-line comparison between PUC and luazig."""
    line: int
    source: str
    puc_opcodes: List[str] = field(default_factory=list)
    zig_opcodes: List[str] = field(default_factory=list)

    @property
    def puc_count(self) -> int:
        return len(self.puc_opcodes)

    @property
    def zig_count(self) -> int:
        return len(self.zig_opcodes)

    @property
    def inflated(self) -> bool:
        return self.zig_count > self.puc_count

    @property
    def ratio(self) -> float:
        if self.puc_count == 0:
            return float("inf") if self.zig_count else 1.0
        return self.zig_count / self.puc_count


# ---------------------------------------------------------------------------
# Bytecode parsing
# ---------------------------------------------------------------------------

def _skip_opcode(opcode: str) -> bool:
    """Filter compiler-prologue (VARARGPREP) and implicit-return opcodes.

    Both compilers emit a single VARARGPREP at function entry and a single
    RETURN-family instruction at the implicit main-body exit. These are not
    user-source codegen and would distort per-line inflation counts.
    """
    return opcode in SKIP_OPCODES or opcode.startswith("RETURN")


def parse_main_bytecode(text: str) -> List[Instr]:
    """Parse bytecode disassembly for the MAIN function only.

    Walks lines after the 'main <...>' header until the body ends (at
    'constants' / 'locals' / 'upvalues' section, a blank line, or the next
    'function' header for a nested prototype). Filters prologue/epilogue
    opcodes (VARARGPREP, RETURN*) so comparisons reflect user code only.
    """
    instrs: List[Instr] = []
    in_main = False
    for raw in text.splitlines():
        stripped = raw.strip()
        if stripped.startswith("main "):
            in_main = True
            continue
        if not in_main:
            continue
        # Body ends at section headers, a blank line, or a nested function.
        if (not stripped
                or stripped.startswith("constants")
                or stripped.startswith("locals")
                or stripped.startswith("upvalues")
                or stripped.startswith("function")):
            break
        # Skip the 'N+ params, M slots, ...' prototype summary line.
        if "params" in stripped and "slots" in stripped:
            continue
        m = INSTR_RE.match(raw)
        if not m:
            continue
        _pc, src_line, opcode, _ops = m.groups()
        if _skip_opcode(opcode):
            continue
        instrs.append(Instr(line=int(src_line), opcode=opcode))
    return instrs


# ---------------------------------------------------------------------------
# Compilation and comparison
# ---------------------------------------------------------------------------

def run_compiler(cmd: List[str]) -> str:
    """Run a compiler command and return its stdout."""
    proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return proc.stdout


def group_by_line(instrs: List[Instr]) -> Dict[int, List[str]]:
    """Group opcodes by source line, preserving emission order."""
    out: Dict[int, List[str]] = {}
    for ins in instrs:
        out.setdefault(ins.line, []).append(ins.opcode)
    return out


def compare_file(path: Path, puc_bin: Path, zig_bin: Path) -> List[LineCompare]:
    """Compile one .lua file under both compilers; build per-line comparison."""
    puc_text = run_compiler([str(puc_bin), "-l", "-l", str(path)])
    zig_text = run_compiler([str(zig_bin), "--dump-bytecode", str(path)])

    puc_groups = group_by_line(parse_main_bytecode(puc_text))
    zig_groups = group_by_line(parse_main_bytecode(zig_text))

    try:
        src_lines = path.read_text().splitlines()
    except OSError:
        src_lines = []

    compares: List[LineCompare] = []
    for ln in sorted(set(puc_groups) | set(zig_groups)):
        source = src_lines[ln - 1].strip() if 0 < ln <= len(src_lines) else ""
        compares.append(LineCompare(
            line=ln,
            source=source,
            puc_opcodes=puc_groups.get(ln, []),
            zig_opcodes=zig_groups.get(ln, []),
        ))
    return compares


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def _fmt_ops(ops: List[str]) -> str:
    return ",".join(ops) if ops else "-"


def _rel(path: Path) -> str:
    """Render a path relative to ROOT (falls back to absolute)."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def print_file_report(
    path: Path, compares: List[LineCompare], quiet: bool
) -> Tuple[int, int, int]:
    """Print per-file report. Returns (puc_total, zig_total, inflated_count)."""
    print(f"\n=== {_rel(path)} ===")
    puc_total = sum(c.puc_count for c in compares)
    zig_total = sum(c.zig_count for c in compares)
    inflated = sum(1 for c in compares if c.inflated)

    for c in compares:
        # In quiet mode, only show inflated lines.
        if quiet and not c.inflated:
            continue
        mark = "❌" if c.inflated else "✅"
        ratio_str = f" {c.ratio:.1f}x" if c.inflated else ""
        print(f"  L{c.line:<2} {c.source:<22} "
              f"PUC: {c.puc_count} ({_fmt_ops(c.puc_opcodes):<16}) "
              f"zig: {c.zig_count} ({_fmt_ops(c.zig_opcodes):<24}) "
              f"{mark}{ratio_str}")

    mult = (zig_total / puc_total) if puc_total else 0.0
    # In quiet mode with no inflation, skip the (uninteresting) OK summary.
    if quiet and inflated == 0:
        return puc_total, zig_total, inflated
    print(f"\nSummary: PUC {puc_total}, zig {zig_total} ({mult:.1f}x) "
          f"— {inflated} inflated lines")
    return puc_total, zig_total, inflated


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "path", nargs="?", default=str(DEFAULT_TEST_DIR),
        help=f".lua file or directory to scan (default: {_rel(DEFAULT_TEST_DIR)})",
    )
    ap.add_argument("--fail-on-inflation", action="store_true",
                    help="exit 1 if any source line has zig_count > puc_count")
    ap.add_argument("--quiet", action="store_true",
                    help="only show inflated lines (skip OK lines)")
    ap.add_argument("--puc", default=str(DEFAULT_PUC),
                    help=f"path to PUC luac (default: {_rel(DEFAULT_PUC)})")
    ap.add_argument("--zig", default=str(DEFAULT_ZIG),
                    help=f"path to luazig binary (default: {_rel(DEFAULT_ZIG)})")
    args = ap.parse_args()

    target = Path(args.path)
    if target.is_dir():
        files = sorted(target.glob("*.lua"))
    else:
        files = [target]

    if not files:
        print(f"no .lua files found at {target}", file=sys.stderr)
        return 2

    puc_bin = Path(args.puc)
    zig_bin = Path(args.zig)

    total_puc = total_zig = total_inflated = 0
    any_inflated = False
    for f in files:
        compares = compare_file(f, puc_bin, zig_bin)
        p, z, infl = print_file_report(f, compares, args.quiet)
        total_puc += p
        total_zig += z
        total_inflated += infl
        if infl > 0:
            any_inflated = True

    print("\n=== OVERALL ===")
    print(f"Files scanned: {len(files)}")
    mult = (total_zig / total_puc) if total_puc else 0.0
    print(f"Total instructions: PUC {total_puc}, zig {total_zig} ({mult:.1f}x)")
    print(f"Total inflated lines: {total_inflated}")

    return 1 if (args.fail_on_inflation and any_inflated) else 0


if __name__ == "__main__":
    sys.exit(main())
