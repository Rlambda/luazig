# ctx.pc: Eliminate ctx.fr from dispatch hot path

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate `ctx.fr` (dangling-prone `*CallFrame` pointer) from the dispatch hot path. Move `pc` and other directly-accessed fields into `BytecodeDispatchCtx` as value fields. `syncDispatchCtx` writes them to the re-derived frame pointer. This is the PUC `luaV_execute` pattern: local `pc` written back to `ci->u.l.savedpc` only at call/return boundaries.

**Parity baseline:** 28/31 matrix, 45/45 smoke. Geomean 2.86×.

**Root cause of previous failure:** The previous attempt (Task 1) introduced a local `var pc` alongside `ctx.fr.pc`, creating two sources of truth. `ctx.fr` became a dangling pointer after `exec_frames` realloc (`pushBytecodeExecFrame` → `addOne`), and the local `pc` was not synced at all exit points. The fix: **one source of truth** — `ctx.pc` (a value, not a pointer), synced to the heap frame only via `syncDispatchCtx` / `loadDispatchCtx`.

---

## Architecture

### Current (broken) design

```
BytecodeDispatchCtx {
    fr: *CallFrame,    // ← DANGLING after exec_frames realloc
    // pc, is_tailcall, resumed_direct_yield, current_line, last_hook_line
    // accessed via ctx.fr.* (pointer dereference → heap access every instruction)
}
```

### New design

```
BytecodeDispatchCtx {
    // fr removed entirely from hot path
    pc: usize,                    // working program counter (value, not pointer)
    is_tailcall: bool,            // frame reuse flag
    resumed_direct_yield: bool,   // coroutine resume flag
    has_open_upvalues: bool,      // upvalue fast-path gate
    // current_line, last_hook_line stay on the heap frame (only accessed in hooks block)
    // syncDispatchCtx writes ctx.pc etc. to re-derived exec_frames.getPtr()
}
```

### Key invariant

**`ctx.fr` is NEVER accessed inside the inner dispatch loop (lines ~6146-7980).** All fields that were accessed via `ctx.fr.*` are now ctx-level value fields. The only place `ctx.fr` is set is `loadDispatchCtx` (for the hooks block's local `fr`), and even there it's not needed — the hooks block already uses its own local `fr`.

### What stays on the heap frame (NOT cached in ctx)

- `current_line`, `last_hook_line` — only accessed in the hooks block (slow path, ~never hit). The hooks block already uses a local `fr = exec_frames.getPtr(...)`.
- `activation_id` — only checked in the defer block and `loadDispatchCtx`.
- `pending_call` — only accessed at frame_loop entry and in helper functions.
- `skip_call_hook_pc`, `skip_line_hook_pc`, `resume_skip_count_pc` — only in hooks block.
- `tbc_mark` — already cached as `ctx.tbc_mark`.
- `debug_namewhat`, `debug_name` — only set in `pushBytecodeExecFrame` / `tryPushBytecodeContinuationCall`.

---

## Task 1: Add value fields to BytecodeDispatchCtx, update load/sync

Add `pc`, `is_tailcall`, `resumed_direct_yield`, `has_open_upvalues` as value fields to `BytecodeDispatchCtx`. Update `loadDispatchCtx` to load them from the frame. Update `syncDispatchCtx` to write them back to the re-derived frame pointer. Remove `fr` field.

### Changes

**`BytecodeDispatchCtx` struct (line ~5957):**
- Remove `fr: *CallFrame`
- Add `pc: usize`
- Add `is_tailcall: bool`
- Add `resumed_direct_yield: bool`
- Add `has_open_upvalues: bool`

**`loadDispatchCtx` (line ~6018):**
- Remove `ctx.fr = fr`
- Add `ctx.pc = fr.pc`
- Add `ctx.is_tailcall = fr.is_tailcall`
- Add `ctx.resumed_direct_yield = fr.resumed_direct_yield`
- Add `ctx.has_open_upvalues = fr.has_open_upvalues`

**`syncDispatchCtx` (line ~6044):**
- Add `saved.pc = ctx.pc`
- Add `saved.is_tailcall = ctx.is_tailcall`
- Add `saved.resumed_direct_yield = ctx.resumed_direct_yield`
- Add `saved.has_open_upvalues = ctx.has_open_upvalues`
- Update comment (remove "pc is already in fr")

**`runBytecodeDispatch` ctx init (line ~6081):**
- Remove `.fr = undefined`
- Add `.pc = 0`, `.is_tailcall = false`, `.resumed_direct_yield = false`, `.has_open_upvalues = false`

**Defer block (line ~6130):**
- No change needed — `syncDispatchCtx` now writes `pc` via re-derived pointer

- [ ] Add value fields to BytecodeDispatchCtx
- [ ] Update loadDispatchCtx
- [ ] Update syncDispatchCtx
- [ ] Update ctx init in runBytecodeDispatch
- [ ] Build (expect errors from all ctx.fr.* accesses — these are fixed in Task 2)

## Task 2: Replace all ctx.fr.pc with ctx.pc in dispatch loop

Replace every `ctx.fr.pc` with `ctx.pc` inside the inner dispatch loop (lines ~6146-7980). This is the hot path — the main optimization target.

### Locations (from audit)

**Reads (hot path):**
- Loop condition: `while (ctx.fr.pc < ...)` → `while (ctx.pc < ...)`
- Instruction fetch: `ctx.cur_proto.code[ctx.fr.pc]` → `ctx.cur_proto.code[ctx.pc]`
- LOADKX: `ctx.fr.pc += 1; code[ctx.fr.pc]` → `ctx.pc += 1; code[ctx.pc]`
- Comparisons (EQ/LT/LE/EQI/EQK/LTI/LEI/GTI/GEI/TEST/TESTSET): `ctx.fr.pc += 1` → `ctx.pc += 1`
- JMP: `ctx.fr.pc = @intCast(...)` → `ctx.pc = @intCast(...)`
- FORLOOP/TFORLOOP/TFORPREP: `ctx.fr.pc = @intCast(...)` → `ctx.pc = @intCast(...)`
- ERRDEFINED: `ctx.fr.pc + 1`, `ctx.fr.pc += 1` → `ctx.pc + 1`, `ctx.pc += 1`
- Dispatcher advance: `ctx.fr.pc += 1` → `ctx.pc += 1`
- Slow-path calls: `bytecodeIndexValue(ctx.cur_proto, ctx.fr.pc, ...)` → `bytecodeIndexValue(ctx.cur_proto, ctx.pc, ...)`
- `bytecodeSetIndexValue(ctx.cur_proto, ctx.fr.pc, ...)` → same
- `evalBytecodeBinOp(ctx.cur_proto, ctx.fr.pc, ...)` → same
- `evalBytecodeUnOp(ctx.cur_proto, ctx.fr.pc, ...)` → same
- `bytecodeLocalNameAt(ctx.cur_proto, a, ctx.fr.pc)` → same

**Writes (hot path):**
- All `ctx.fr.pc += 1` → `ctx.pc += 1`
- All `ctx.fr.pc = @intCast(...)` → `ctx.pc = @intCast(...)`

**GC safepoint (line ~6376):**
- `ctx.fr.reg_top = ctx.reg_top` → `exec_frames.getPtr(ctx.frame_index).reg_top = ctx.reg_top`
- `ctx.fr.nvarstack = ctx.nvarstack` → `exec_frames.getPtr(ctx.frame_index).nvarstack = ctx.nvarstack`
- (GC walks `exec_frames` directly, so we must sync to the heap frame)

**Hooks block (line ~6172):**
- `ctx.fr.pc = pc` → REMOVE (no longer needed — `ctx.pc` IS the pc)
- The hooks block already uses a local `fr = exec_frames.getPtr(...)`. It reads `fr.pc` — this should read `ctx.pc` instead (or keep the local `fr` and write `fr.pc = ctx.pc` at the top of the hooks block, since the local is re-derived).

**MOVE handler (line ~6391):**
- `ctx.fr.has_open_upvalues` → `ctx.has_open_upvalues`

- [ ] sed replace `ctx.fr.pc` → `ctx.pc` in lines 6146-7980
- [ ] Fix GC safepoint to use re-derived pointer
- [ ] Fix hooks block to sync ctx.pc to local fr
- [ ] Fix MOVE handler to use ctx.has_open_upvalues
- [ ] Build + smoke test

## Task 3: Replace ctx.fr.* in extracted handlers

Extracted handlers receive `*BytecodeDispatchCtx` and access `ctx.fr.*` at entry (before any realloc). Replace with ctx-level fields.

### Locations

**opCall (line ~8923):**
- `ctx.cur_proto.code[ctx.fr.pc]` → `ctx.cur_proto.code[ctx.pc]`
- `ctx.fr.resumed_direct_yield` → `ctx.resumed_direct_yield`
- `ctx.fr.resumed_direct_yield = false` → `ctx.resumed_direct_yield = false`
- `ctx.fr.pc` (passed to debugBytecodeOperandName) → `ctx.pc`
- `ctx.fr.pc` (compared with skip_call_hook_pc) → `ctx.pc`
- `ctx.fr.pc` (passed to parkDirectBytecodeYield) → `ctx.pc`
- `&ctx.fr.resumed_direct_yield` → `&ctx.resumed_direct_yield`

**opTailcall (line ~8591):**
- Same pattern as opCall
- `ctx.fr.is_tailcall = true` → `ctx.is_tailcall = true`
- `ctx.fr.pc = 0` → `ctx.pc = 0`

**opReturn (line ~8005):**
- `ctx.cur_proto.code[ctx.fr.pc]` → `ctx.cur_proto.code[ctx.pc]`

**opReturn0 (line ~8078):**
- No ctx.fr access (uses exec_frames.getPtr directly)

**opReturn1 (line ~8142):**
- `ctx.cur_proto.code[ctx.fr.pc]` → `ctx.cur_proto.code[ctx.pc]`

**opSetlist (line ~8041):**
- `ctx.cur_proto.code[ctx.fr.pc]` → `ctx.cur_proto.code[ctx.pc]`
- `ctx.fr.pc + 1` → `ctx.pc + 1`
- `ctx.fr.pc += 1` → `ctx.pc += 1`
- `ctx.cur_proto.code[ctx.fr.pc]` → `ctx.cur_proto.code[ctx.pc]`

**opForprep (line ~8414):**
- `ctx.cur_proto.code[ctx.fr.pc]` → `ctx.cur_proto.code[ctx.pc]`
- `ctx.fr.pc = @intCast(...)` → `ctx.pc = @intCast(...)`

**opTforcall (line ~8279):**
- `ctx.cur_proto.code[ctx.fr.pc]` → `ctx.cur_proto.code[ctx.pc]`

**opClosure (line ~8227):**
- `ctx.cur_proto.code[ctx.fr.pc]` → `ctx.cur_proto.code[ctx.pc]`

**opVararg (line ~8183):**
- `ctx.cur_proto.code[ctx.fr.pc]` → `ctx.cur_proto.code[ctx.pc]`

**opConcat (line ~8553):**
- `ctx.cur_proto.code[ctx.fr.pc]` → `ctx.cur_proto.code[ctx.pc]`

- [ ] Replace all ctx.fr.pc → ctx.pc in extracted handlers
- [ ] Replace ctx.fr.resumed_direct_yield → ctx.resumed_direct_yield
- [ ] Replace ctx.fr.is_tailcall → ctx.is_tailcall
- [ ] Replace &ctx.fr.resumed_direct_yield → &ctx.resumed_direct_yield
- [ ] Build + smoke test

## Task 4: Update fail() and other helpers that assume ctx.fr.pc is current

### fail() (line ~2527)

`fail()` reads `th.call_frames.getPtr(th.call_frames.len() - 1).pc` for line number. With the new design, `ctx.pc` is the working counter, but the heap frame's `pc` is only synced at exit points (defer/syncDispatchCtx). So `fail()` may read a stale `pc`.

**Fix:** Before calling `fail()` in the dispatch loop, sync `ctx.pc` to the heap frame. The cheapest approach: add a helper `syncPcToFrame` that writes `ctx.pc` to `exec_frames.getPtr(ctx.frame_index).pc`. Call it before every `return self.fail(...)` in the dispatch loop.

Alternatively, change `fail()` to accept an optional `pc` parameter. But this changes the signature used everywhere.

**Chosen approach:** Add `exec_frames.getPtr(ctx.frame_index).pc = ctx.pc;` before each `return self.fail(...)` in the dispatch loop. There are ~4 such calls in the dispatch loop (divide-by-zero, etc.). These are error paths — the overhead is negligible.

### callBuiltin (line ~9632)

Same pattern as `fail()` — reads `fr.pc` from re-derived pointer for line number. Same fix: sync `ctx.pc` before calling `callBuiltin` in the dispatch loop. But `callBuiltin` is called from extracted handlers (opCall, opTailcall), not directly from the dispatch loop. The extracted handlers sync `ctx.pc` at entry (they read it). But `callBuiltin` reads from the heap frame, which may be stale.

**Fix:** In extracted handlers that call `callBuiltin`, sync `ctx.pc` to the heap frame before the call. Specifically in `opCall` and `opTailcall`, add `exec_frames.getPtr(ctx.frame_index).pc = ctx.pc;` before `callBuiltin`.

### setOutOfMemoryError (line ~2554)

Same pattern. Called from `pushBytecodeExecFrame` and other places that don't have `ctx`. No fix needed — these paths don't go through the dispatch loop.

- [ ] Add ctx.pc sync before fail() calls in dispatch loop
- [ ] Add ctx.pc sync before callBuiltin in opCall/opTailcall
- [ ] Build + smoke test

## Task 5: Full regression + perf + README

- [ ] Build ReleaseFast
- [ ] Run all smoke tests (45/45 expected)
- [ ] Run matrix: `python3 tools/testes_matrix.py --timeout 120` (28/31 expected)
- [ ] Run perf: `python3 tools/perf_compare.py --runs 7 --core 0`
- [ ] Compare geomean to baseline (2.86×)
- [ ] Update baseline if improved
- [ ] Commit all changes
- [ ] Update README with optimization details
