#!/usr/bin/env python3
"""
provenance.py — shared provenance helpers for the versioned JSON artifacts.

Every artifact generator (perf_compare.py, smoke_compare.py, testes_matrix.py,
perf_fixed_load_footprint.py) stamps the same provenance block into its JSON
payload so a reader can tell exactly which source state and which binaries
produced the numbers:

  git_head        — short SHA of HEAD at generation time
  git_dirty       — "clean"/"dirty": whether the tracked tree differs from
                    HEAD. A dirty measurement MUST say dirty — a dirty tree
                    is never represented by HEAD alone, because HEAD does not
                    identify uncommitted changes that the measurement may
                    depend on. Untracked files are ignored: only tracked
                    sources are inputs to the measured binaries.
  zig_version     — `zig version` of the toolchain that built the binaries
  zig_binary_sha16 / puc_binary_sha16 — first 16 hex chars of the sha256 of
                    each binary the lane actually executes ("only applicable
                    fields per lane": a lane that never runs the PUC binary
                    does not hash it).

All lookups fail soft ("unknown" / None) so a missing git or zig never breaks
a measurement run.
"""
from __future__ import annotations

import hashlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ZIG_LUA = ROOT / "zig-out" / "bin" / "luazig"
PUC_LUA = ROOT / "build" / "lua-c" / "lua"


def _capture(cmd: list[str]) -> str | None:
    """Run cmd, return stripped stdout, or None on any failure (fail soft)."""
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30, check=True)
        return proc.stdout.strip()
    except Exception:
        return None


def git_head() -> str:
    """Short SHA of HEAD ("unknown" outside a git repository)."""
    return _capture(["git", "rev-parse", "--short", "HEAD"]) or "unknown"


def git_dirty() -> str:
    """"clean" if the tracked tree matches HEAD, else "dirty".

    Untracked files are ignored (--untracked-files=no): they are not inputs
    to the measured binaries. This is the field that makes a dirty
    measurement honestly distinguishable from a clean one — see module
    docstring for the dirty-tree rule.
    """
    out = _capture(["git", "status", "--porcelain", "--untracked-files=no"])
    if out is None:
        return "unknown"
    return "dirty" if out else "clean"


def zig_version() -> str | None:
    """Version string of the `zig` toolchain on PATH (None if unavailable)."""
    return _capture(["zig", "version"])


def file_sha16(path) -> str:
    """First 16 hex chars of the sha256 of a file ("unknown" if unreadable)."""
    try:
        digest = hashlib.sha256(Path(path).read_bytes()).hexdigest()
        return digest[:16]
    except OSError:
        return "unknown"


def block(*, zig_bin: Path | None = ZIG_LUA,
          puc_bin: Path | None = None,
          optimize_mode: str | None = None) -> dict:
    """Assemble the standard provenance block for an artifact payload.

    Binary hashes are included only for binaries the lane executes: pass
    puc_bin for lanes that run the PUC reference (perf timing/counters,
    matrix, smoke); omit it for zig-only lanes (profile index, fixed-load
    footprint, whose PUC side comes from the vendored headers, not the
    binary).

    `optimize_mode` records which Zig optimize mode built the measured
    binary (Debug / ReleaseFast / ...). Layout-sensitive results (struct
    sizes, byte deltas) differ between modes, so every such artifact must
    identify its mode — or carry one provenance block per mode.

    P16.17 T5 naming rule: `git_head`/`measured_source_head` identify the
    source the MEASURED binary was built from (captured while the tree is
    clean; lanes that need to write outputs stage them to /tmp first). The
    later artifact/documentation commit is a DIFFERENT commit and is
    reported separately (STATUS / final report), never conflated with the
    measured head.
    """
    head = git_head()
    prov: dict = {
        "git_head": head,
        # Explicit alias: this head is what the BINARY was built from.
        "measured_source_head": head,
        "git_dirty": git_dirty(),
        "zig_version": zig_version(),
    }
    if optimize_mode is not None:
        prov["optimize_mode"] = optimize_mode
    if zig_bin is not None:
        prov["zig_binary_sha16"] = file_sha16(zig_bin)
    if puc_bin is not None:
        prov["puc_binary_sha16"] = file_sha16(puc_bin)
    return prov
