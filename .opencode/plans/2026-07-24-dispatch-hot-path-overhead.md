# Plan: Dispatch hot path — eliminate per-instruction overhead

## Goal
Eliminate per-instruction overhead that PUC Lua does not have:
- `self.dispatch_pc = ctx.pc` store (PUC writes `savedpc` only at call/return)
- `ctx.hooks_active = self.hooks_active_cached` load (PUC uses local `trap`, refreshed at jumps)
- `@branchHint(.unlikely)` on OP_MOVE fast path (bug — both arms unlikely)
- GC tick check every instruction (PUC checks GC only at allocation sites)

Target: ~3% geomean improvement, no parity regressions.

## Tasks

### Task 1 (C): Fix OP_MOVE @branchHint — DONE
- Removed `@branchHint(.unlikely)` from OP_MOVE fast path (else branch)
- Fast path (no open upvalues) is the common case — should not be unlikely
- Verified: smoke + matrix unchanged, perf 2.85→2.89

### Task 2 (A): Eliminate dispatch_pc store — REJECTED
- `fail()` is called from indirect paths (evalBytecodeBinOp, concatValues, etc.) without `ctx`
- Per-instruction `dispatch_pc` store is necessary for error line reporting and GC root scanning
- Cannot eliminate without threading `ctx` through all helper functions

### Task 3 (B): Cache hooks_active in ctx — REJECTED
- Count hooks require per-instruction check (PUC checks `trap` every instruction for count hooks)
- Periodic refresh (every 16 instructions) breaks count hook semantics
- Smoke 31 (`debug.sethook` with count=1) fails

### Task 4 (D): Reduce GC tick frequency — DEFERRED
- PUC-style allocation-site-only GC blocked by pre-existing GC corruption bug
- Bug now FIXED (see below), but GC tick removal needs separate investigation

### Bug fix: GC corruption from stale rargs in opCall/opTailcall
- Root cause: `opCall`/`opTailcall` pre-grew `bc_stack` with `child_frame_cap = p.maxstacksize`,
  but `pushBytecodeExecFrame` uses `frame_cap = proto.maxstacksize + EXTRA_MARGIN`.
  When `pushBytecodeExecFrame` called `ensureBcStackCap` for the extra 5 slots, it could realloc
  `bc_stack`, making the `rargs` slice (derived from `ctx.regs` before the call) a dangling pointer.
  The child frame's register 0 would then contain garbage from freed memory.
- Fix: pre-grow with `child_frame_cap = p.maxstacksize + EXTRA_MARGIN` in both `opCall` and `opTailcall`
- Also fixed: `gcMarkMutableRoots`, `gcClearDeadFrameRegisters`, `gcMarkVmRoots` to use
  `self.bc_stack`/`th.bytecode_stack` directly instead of `frame.regs` (which can be stale after
  GC finalizers execute Lua code that reallocs `bc_stack`)
- Result: smoke 27 crash eliminated (0/20), 45/45 smoke pass, 28/31 matrix, geomean 2.91×

## Verification
After all 4 tasks:
1. `zig build -Doptimize=ReleaseFast`
2. `python3 tools/smoke_compare.py` — 44/45 (only smoke 27 pre-existing)
3. `cd lua-5.5.0/testes && python3 ../../tools/testes_matrix.py --timeout 120` — 28/31
4. `python3 tools/perf_compare.py --runs 7 --core 0` — geomean improvement
5. Update README.md
