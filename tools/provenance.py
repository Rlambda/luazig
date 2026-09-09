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
                    P16.34 Cut 0A: kept for backward compat, but it is a
                    whole-tree blur — artifact edits (tools/perf JSONs,
                    STATUS.md) make it say "dirty" even when the measured
                    source is pristine. The CANONICAL truth for "was the
                    measured binary built from committed source?" is now
                    source_dirty.
  source_dirty    — "clean"/"dirty": same check scoped to the BUILD/RUNTIME
                    INPUTS of every measured binary: src/, build.zig, and the
                    vendored lua-5.5.0/src/ (PUC reference inputs). This is
                    the field a reader should trust: source_dirty=clean means
                    HEAD alone fully identifies the measured source, no
                    matter how many artifacts were edited afterwards.
  artifact_dirty  — "clean"/"dirty": same check scoped to the ARTIFACT and
                    documentation surfaces (tools/perf, tools/status,
                    README.md, STATUS.md). Expected "dirty" while an
                    artifact regeneration is in flight (e.g. a historical
                    rename staged before the new current-*.json is written);
                    it never contaminates source_dirty.
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

# Pathspecs for the scoped dirty checks. Untracked files are ignored
# (--untracked-files=no), same convention as git_dirty: an untracked file is
# not a tracked input to any measured binary.
# SOURCE_PATHS: every build/runtime input of the measured binaries — the
# luazig source tree, the build script, and the vendored PUC tree the
# reference binary is built from.
SOURCE_PATHS = ("src/", "build.zig", "lua-5.5.0/src/")
# ARTIFACT_PATHS: the versioned measurement artifacts and the status docs
# that narrate them. Editing these NEVER changes a measured binary.
ARTIFACT_PATHS = ("tools/perf", "tools/status", "README.md", "STATUS.md")


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


def _scoped_dirty(pathspecs: tuple[str, ...]) -> str:
    """"clean"/"dirty" for a pathspec-scoped slice of the tracked tree.

    Shared implementation of source_dirty/artifact_dirty: `git status
    --porcelain --untracked-files=no -- <paths...>`. Fails soft to
    "unknown" like every other lookup.
    """
    cmd = ["git", "status", "--porcelain", "--untracked-files=no", *pathspecs]
    out = _capture(cmd)
    if out is None:
        return "unknown"
    return "dirty" if out else "clean"


def source_dirty() -> str:
    """Dirty check scoped to the BUILD/RUNTIME INPUTS of measured binaries.

    src/, build.zig, and the vendored lua-5.5.0/src/ (the PUC reference
    inputs). This is the canonical "was the measured binary built from
    committed source?" field: artifact/doc edits do not affect it.
    """
    return _scoped_dirty(SOURCE_PATHS)


def artifact_dirty() -> str:
    """Dirty check scoped to the artifact/documentation surfaces.

    tools/perf, tools/status, README.md, STATUS.md. Expected "dirty" while
    regenerating artifacts; never contaminates source_dirty.
    """
    return _scoped_dirty(ARTIFACT_PATHS)


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
        # P16.34 Cut 0A: scoped dirty fields. git_dirty is whole-tree (kept
        # for backward compat) and blurs artifact edits into "dirty";
        # source_dirty is the CANONICAL "measured source is committed" truth,
        # artifact_dirty explains any remaining tree dirt as artifact-side.
        "source_dirty": source_dirty(),
        "artifact_dirty": artifact_dirty(),
        "zig_version": zig_version(),
    }
    if optimize_mode is not None:
        prov["optimize_mode"] = optimize_mode
    if zig_bin is not None:
        prov["zig_binary_sha16"] = file_sha16(zig_bin)
    if puc_bin is not None:
        prov["puc_binary_sha16"] = file_sha16(puc_bin)
    return prov
