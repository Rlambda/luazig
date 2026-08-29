# fr.pc as sole pc — eliminate bc_dispatch_pc / bc_dispatch_active

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `fr.pc` the sole program counter (like PUC's `ci->u.l.savedpc`), eliminating `bc_dispatch_pc`, `bc_dispatch_active`, and the per-instruction stores that sync them.

**Architecture:** The dispatch loop reads/writes `ctx.fr.pc` directly (a `*CallFrame` pointer into `exec_frames`). `fail()`, `callBuiltin()`, and error paths read `fr.pc` from the topmost frame — always current, no sync needed. `ctx.fr` is safe because `exec_frames` only grows via `pushBytecodeExecFrame`, which always exits the inner loop via `continue :frame_loop`. Re-entrancy from `require`/`dofile` is fine — each `runBytecodeDispatch` invocation has its own `ctx` (on Zig stack), and nested calls don't touch the parent frame's `pc`.

**Expected perf:** -2 cycles/instruction (eliminate `bc_dispatch_pc` store + `bc_dispatch_active` store). Geomean 3.10× → ~2.95×.

**PUC reference:** `luaV_execute` (lvm.c:1198): `Instruction i = *ci->u.l.savedpc++;` — no separate dispatch_pc, no active flag.

**Parity baseline:** 28/31 matrix (3 acceptable fails: `attrib`, `big`, `files`), 45/45 smoke.

---

## Why ctx.fr is safe (aliasing analysis)

`exec_frames: FrameStack` uses an inline `[32]CallFrame` array + heap overflow. The heap can realloc on growth. But `exec_frames` only grows via `pushBytecodeExecFrame` / `addOne`, which is called exclusively from handlers that immediately return `.continue_frame_loop`. This exits the inner dispatch loop, triggering `defer { syncDispatchCtx(&ctx); }`, then `frame_loop` restarts and `loadDispatchCtx` re-derives `ctx.fr`.

Therefore: **`ctx.fr` is never stale within the inner dispatch loop.** The pointer is valid from `loadDispatchCtx` (at `frame_loop` entry) until `continue :frame_loop` or `syncDispatchCtx` (at `frame_loop` exit).

For deep recursion (32+ frames), `ctx.fr` points into the heap. Heap realloc only happens during `pushBytecodeExecFrame`, which exits the inner loop. So the pointer is safe.

---

## Why the previous attempt failed (root-cause analysis)

The DispatchLoopSlim attempt (commit history, abandoned) had two bugs:

1. **CLOSE handler double-increment.** `continueBytecodeClose` increments `fr.pc` directly (vm.zig:4744: `exec_frames.getPtr(parent_index).pc += 1`). With `ctx.fr.pc` IS `fr.pc`, the CLOSE handler's mirror `ctx.pc += 1` became a double-increment. This corrupted the pc, causing `for_generic.lua` to read wrong instructions and crash. → Fix: Task 3 removes the mirror.

2. **Half-removed bc_dispatch_active.** The per-instruction `self.bc_dispatch_active = true;` store was removed, but the error path sync `if (self.bc_dispatch_active) fr.pc = self.bc_dispatch_pc;` was kept. During re-entrancy from `require`/`dofile`, the nested `runBytecodeDispatch` exit cleared `bc_dispatch_active` via defer. The outer dispatch loop continued with `bc_dispatch_active = false`. Then `callBuiltin` skipped the pc sync, and `fail()` read stale `fr.pc`. → Fix: Tasks 4-5 remove `bc_dispatch_pc` AND `bc_dispatch_active` entirely. Error paths read `fr.pc` directly (always current).

---

## File Structure

- **Modify:** `src/lua/vm.zig` — all changes in this file (~31479 lines)

Key locations (line numbers approximate, verify with `rg`):
- `BytecodeDispatchCtx` struct: ~line 7509
- `loadDispatchCtx`: ~line 7518
- `syncDispatchCtx`: ~line 7550
- `runBytecodeDispatch` entry + ctx init: ~line 7577
- Inner dispatch loop: ~line 7748
- CLOSE handler: ~line 9427
- `fail()`: ~line 2895
- `setOutOfMemoryError()`: ~line 2950
- `syncTopFrameForGc()`: ~line 3234
- `callBuiltin()`: ~line 11333
- `.error` builtin path: ~line 11430
- `parkActiveRuntime()`: ~line 2098
- `activateRuntime()`: ~line 2162
- Vm fields `bc_dispatch_pc`/`bc_dispatch_active`: ~line 1885
- `continueBytecodeClose` with `.advance_instruction`: ~line 4742

---

### Task 1: Add `fr: *CallFrame` to BytecodeDispatchCtx, remove cached pc/line fields

**Goal:** Replace `ctx.pc` and debug-state caches with a direct frame pointer.

**Files:** `src/lua/vm.zig` — `BytecodeDispatchCtx` struct (~line 7509)

- [ ] **Step 1: Replace struct fields**

Change the struct to use `fr: *CallFrame` and remove `pc`, `frame_current_line`, `frame_last_hook_line`, `frame_is_tailcall`, `resumed_direct_yield`:

```zig
const BytecodeDispatchCtx = struct {
    // Immutable within a frame_loop iteration.
    exec_frames: *FrameStack,
    /// Direct pointer to the current CallFrame. fr.pc is the sole
    /// program counter (like PUC's ci->u.l.savedpc). fr.current_line,
    /// fr.last_hook_line, fr.is_tailcall, fr.resumed_direct_yield are
    /// read/written directly — no ctx-level copies.
    fr: *CallFrame,
    frame_index: usize,
    boundary_depth: usize,
    yielded_in_place: *bool,

    // Frame state (cached from fr for register performance).
    cur_proto: *const bc.Proto,
    cur_upvalues: []const *Cell,
    base: usize,
    frame_cap: usize,
    resume_pc: usize,
    reg_top: u32,
    nvarstack: u32,
    nextraargs: u16,
    varargs: []Value, // kept for IR frames; bytecode uses nextraargs + bc_stack
    tbc_mark: usize,

    // Mutable register window — re-derivable after bc_stack realloc.
    regs: []Value,
    boxed: []?*Cell,

    // Debug/hook state — read/written directly via ctx.fr.*.
    hooks_active: bool,
};
```

- [ ] **Step 2: Update loadDispatchCtx**

```zig
fn loadDispatchCtx(self: *Vm, ctx: *BytecodeDispatchCtx) void {
    const fr = ctx.exec_frames.getPtr(ctx.frame_index);
    ctx.fr = fr;
    ctx.cur_proto = fr.proto.?;
    ctx.cur_upvalues = fr.upvalues;
    ctx.base = fr.base;
    ctx.frame_cap = fr.frame_cap;
    ctx.resume_pc = fr.resume_pc;
    ctx.reg_top = fr.reg_top;
    ctx.nvarstack = fr.nvarstack;
    ctx.nextraargs = fr.nextraargs;
    ctx.varargs = fr.varargs;
    ctx.tbc_mark = fr.tbc_mark;
    ctx.regs = self.bc_stack[fr.base .. fr.base + fr.frame_cap];
    ctx.boxed = self.bc_boxed[fr.base .. fr.base + fr.frame_cap];
    // hooks_active is re-derived per inner-loop iteration.
}
```

- [ ] **Step 3: Update syncDispatchCtx**

Don't sync `pc` / `current_line` / `last_hook_line` / `is_tailcall` / `resumed_direct_yield` — they're already in `fr` (written directly during dispatch). Still sync cached working state:

```zig
fn syncDispatchCtx(self: *Vm, ctx: *const BytecodeDispatchCtx) void {
    if (ctx.frame_index >= ctx.exec_frames.len()) return;
    const saved = ctx.exec_frames.getPtr(ctx.frame_index);
    saved.proto = ctx.cur_proto;
    saved.upvalues = ctx.cur_upvalues;
    saved.frame_cap = ctx.frame_cap;
    saved.resume_pc = ctx.resume_pc;
    saved.reg_top = ctx.reg_top;
    saved.nvarstack = ctx.nvarstack;
    saved.nextraargs = ctx.nextraargs;
    saved.varargs = ctx.varargs;
    saved.regs = self.bc_stack[ctx.base .. ctx.base + ctx.frame_cap];
    saved.boxed = self.bc_boxed[ctx.base .. ctx.base + ctx.frame_cap];
    // pc, current_line, last_hook_line, is_tailcall, resumed_direct_yield
    // are already in fr (written directly during dispatch).
}
```

- [ ] **Step 4: Update ctx initializer in runBytecodeDispatch**

```zig
var ctx: BytecodeDispatchCtx = .{
    .exec_frames = exec_frames,
    .fr = undefined, // set by loadDispatchCtx
    .frame_index = 0, // set per-iteration below
    .boundary_depth = boundary_depth,
    .yielded_in_place = yielded_in_place,
    // remaining fields set by loadDispatchCtx
    .cur_proto = undefined,
    .cur_upvalues = &.{},
    .base = 0,
    .frame_cap = 0,
    .resume_pc = 0,
    .reg_top = 0,
    .nvarstack = 0,
    .nextraargs = 0,
    .varargs = &.{},
    .tbc_mark = 0,
    .regs = &.{},
    .boxed = &.{},
    .hooks_active = false,
};
```

- [ ] **Step 5: Build (expect errors from ctx.pc → ctx.fr.pc renames)**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | grep "error:" | head -10
```

Expected: many `no field named 'pc'` / `no field named 'frame_current_line'` errors. These are fixed in Task 2.

---

### Task 2: Rename all ctx.pc → ctx.fr.pc, ctx.frame_* → ctx.fr.*

**Goal:** Bulk-replace all references to removed fields.

**Files:** `src/lua/vm.zig`

- [ ] **Step 1: Bulk rename via sed**

```bash
sed -i 's/ctx\.pc\b/ctx.fr.pc/g' src/lua/vm.zig
sed -i 's/ctx\.frame_current_line/ctx.fr.current_line/g' src/lua/vm.zig
sed -i 's/ctx\.frame_last_hook_line/ctx.fr.last_hook_line/g' src/lua/vm.zig
sed -i 's/ctx\.frame_is_tailcall/ctx.fr.is_tailcall/g' src/lua/vm.zig
sed -i 's/ctx\.resumed_direct_yield/ctx.fr.resumed_direct_yield/g' src/lua/vm.zig
```

- [ ] **Step 2: Verify no stale references remain**

```bash
rg "ctx\.pc\b|ctx\.frame_current_line|ctx\.frame_last_hook_line|ctx\.frame_is_tailcall|ctx\.resumed_direct_yield" src/lua/vm.zig | grep -v "ctx\.fr\." | grep -v "^[0-9]*:.*//"
```

Expected: no matches (all converted to `ctx.fr.*` form).

- [ ] **Step 3: Build**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | grep "error:" | head -10
```

Expected: compiles clean (or minor errors from DispatchResult comments referencing old field names — fix manually).

---

### Task 3: Fix CLOSE handler — remove double-increment

**Goal:** `continueBytecodeClose` already increments `fr.pc` directly (vm.zig:4744: `exec_frames.getPtr(parent_index).pc += 1`). With `ctx.fr.pc` IS `fr.pc`, the CLOSE handler must NOT mirror the increment.

**Files:** `src/lua/vm.zig` — CLOSE handler (~line 9436)

- [ ] **Step 1: Remove the mirror increment**

In the `.close =>` handler, the `.resume_dispatch` branch currently does:

```zig
.resume_dispatch => {
    // A close chain that completed synchronously
    // advanced the descriptor directly. Mirror that
    // in the instruction-local alias so this loop's
    // defer does not overwrite it with the old PC.
    if (ctx.frame_index < exec_frames.len() and
        !(exec_frames.getPtr(ctx.frame_index).pending_call.active))
    {
        ctx.fr.pc += 1;
    }
    continue :frame_loop;
},
```

Change to:

```zig
.resume_dispatch => {
    // continueBytecodeClose already incremented fr.pc via
    // exec_frames.getPtr(parent_index).pc += 1 (line ~4744).
    // ctx.fr.pc IS fr.pc — no mirror increment needed.
    continue :frame_loop;
},
```

- [ ] **Step 2: Build + smoke (22_for_generic.lua is the key test)**

```bash
zig build -Doptimize=ReleaseFast
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig --vm=bc "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
```

Expected: 45/45. If `22_for_generic.lua` fails: the double-increment is still present — verify Task 3 Step 1 was applied correctly.

---

### Task 4: Remove per-instruction bc_dispatch_pc/bc_dispatch_active stores

**Goal:** Eliminate the per-instruction stores that sync ctx.fr.pc to Vm-level fields.

**Files:** `src/lua/vm.zig` — dispatch loop (~line 7729)

- [ ] **Step 1: Delete bc_dispatch_active set/defer in runBytecodeDispatch**

Delete these lines (~line 7595):

```zig
self.bc_dispatch_active = true;                   // DELETE
defer self.bc_dispatch_active = false;            // DELETE
```

- [ ] **Step 2: Delete per-instruction stores**

In the inner dispatch loop, delete:

```zig
self.bc_dispatch_pc = ctx.fr.pc;           // DELETE
self.bc_dispatch_active = true;            // DELETE
```

KEEP the per-instruction lineinfo fast-path read (needed for child frame entry correctness):

```zig
// KEEP — needed when child frame reads parent's current_line
if (ctx.fr.pc < ctx.cur_proto.lineinfo.len and ctx.cur_proto.lineinfo[ctx.fr.pc] != 0) {
    ctx.fr.current_line = @intCast(ctx.cur_proto.lineinfo[ctx.fr.pc]);
}
```

- [ ] **Step 3: Build**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | grep "error:" | head -10
```

Expected: errors from `bc_dispatch_pc` / `bc_dispatch_active` references in error paths. Fixed in Task 5.

---

### Task 5: Remove bc_dispatch_pc / bc_dispatch_active from Vm struct and all reference sites

**Goal:** Delete the fields and update all ~15 sites that read them. After this task, `fr.pc` is the sole pc — read directly from the topmost frame by all consumers.

**Files:** `src/lua/vm.zig`

- [ ] **Step 1: Delete field declarations (~line 1885)**

```zig
bc_dispatch_pc: usize = 0,        // DELETE entire field + doc comment
bc_dispatch_active: bool = false, // DELETE entire field + doc comment
```

- [ ] **Step 2: Update fail() (~line 2918)**

In the `fail()` function, there are two branches (Thread.call_frames and self.call_frames). In each, delete `if (self.bc_dispatch_active) fr.pc = self.bc_dispatch_pc;`:

Before:
```zig
if (th.call_frames.len() != 0) {
    var fr = th.call_frames.getPtr(th.call_frames.len() - 1);
    if (self.bc_dispatch_active) fr.pc = self.bc_dispatch_pc;  // DELETE
    if (fr.proto) |proto| {
        if (fr.pc < proto.lineinfo.len and proto.lineinfo[fr.pc] != 0) {
            fr.current_line = @intCast(proto.lineinfo[fr.pc]);
        }
    }
    self.err_source = fr.sourceName();
    self.err_line = fr.current_line;
} else if (self.call_frames.items.len != 0) {
    const top_idx = self.call_frames.items.len - 1;
    var fr = &self.call_frames.items[top_idx];
    if (self.bc_dispatch_active) fr.pc = self.bc_dispatch_pc;  // DELETE
    if (fr.proto) |proto| {
```

After:
```zig
if (th.call_frames.len() != 0) {
    var fr = th.call_frames.getPtr(th.call_frames.len() - 1);
    if (fr.proto) |proto| {
        if (fr.pc < proto.lineinfo.len and proto.lineinfo[fr.pc] != 0) {
            fr.current_line = @intCast(proto.lineinfo[fr.pc]);
        }
    }
    self.err_source = fr.sourceName();
    self.err_line = fr.current_line;
} else if (self.call_frames.items.len != 0) {
    const top_idx = self.call_frames.items.len - 1;
    var fr = &self.call_frames.items[top_idx];
    if (fr.proto) |proto| {
```

- [ ] **Step 3: Update setOutOfMemoryError() (~line 2974)**

Same pattern — delete `if (self.bc_dispatch_active) fr.pc = self.bc_dispatch_pc;` in both Thread.call_frames and self.call_frames branches.

- [ ] **Step 4: Update syncTopFrameForGc() (~line 3234)**

Before:
```zig
fn syncTopFrameForGc(self: *Vm) void {
    const th = self.activeBytecodeThread();
    if (th.call_frames.len() == 0) return;
    var fr = th.call_frames.getPtr(th.call_frames.len() - 1);
    if (self.bc_dispatch_active) fr.pc = self.bc_dispatch_pc;
    // fr.reg_top and fr.nvarstack are best-effort ...
}
```

After:
```zig
fn syncTopFrameForGc(self: *Vm) void {
    const th = self.activeBytecodeThread();
    if (th.call_frames.len() == 0) return;
    // fr.pc is already current — no sync needed.
}
```

- [ ] **Step 5: Update callBuiltin() (~line 11355)**

Remove the outer `bc_dispatch_active` guard and the pc sync. Keep the lineinfo read (builtins like debug.getinfo, error, assert read fr.current_line):

Before:
```zig
if (self.bc_dispatch_active) {
    const th = self.activeBytecodeThread();
    if (th.call_frames.len() != 0) {
        var fr = th.call_frames.getPtr(th.call_frames.len() - 1);
        if (self.bc_dispatch_active) fr.pc = self.bc_dispatch_pc;
        if (fr.proto) |proto| {
            if (fr.pc < proto.lineinfo.len and proto.lineinfo[fr.pc] != 0) {
                fr.current_line = @intCast(proto.lineinfo[fr.pc]);
            }
        }
    }
}
```

After:
```zig
{
    const th = self.activeBytecodeThread();
    if (th.call_frames.len() != 0) {
        var fr = th.call_frames.getPtr(th.call_frames.len() - 1);
        if (fr.proto) |proto| {
            if (fr.pc < proto.lineinfo.len and proto.lineinfo[fr.pc] != 0) {
                fr.current_line = @intCast(proto.lineinfo[fr.pc]);
            }
        }
    }
}
```

- [ ] **Step 6: Update .error builtin path (~line 11455)**

Same pattern — delete `if (self.bc_dispatch_active) fr.pc = self.bc_dispatch_pc;` in both Thread.call_frames and self.call_frames branches.

- [ ] **Step 7: Update parkActiveRuntime() (~line 2098)**

Delete the entire pc sync block:

```zig
// DELETE these lines:
if (owner.call_frames.len() != 0) {
    owner.call_frames.getPtr(owner.call_frames.len() - 1).pc = self.bc_dispatch_pc;
}
```

fr.pc is already current — no sync needed on park.

- [ ] **Step 8: Update activateRuntime() (~line 2162)**

Delete the bc_dispatch_pc load:

```zig
// DELETE these lines:
if (owner.call_frames.len() != 0) {
    self.bc_dispatch_pc = owner.call_frames.getPtr(owner.call_frames.len() - 1).pc;
}
```

bc_dispatch_pc no longer exists. The activated thread's fr.pc is already correct.

- [ ] **Step 9: Verify no remaining references**

```bash
rg -n "bc_dispatch_pc|bc_dispatch_active" src/lua/vm.zig
```

Expected: no matches.

- [ ] **Step 10: Build**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | grep "error:" | head -10
```

Expected: clean build.

---

### Task 6: Full regression test + commit

- [ ] **Step 1: Smoke tests**

```bash
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig --vm=bc "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
```

Expected: 45/45.

Diagnosis guide for failures:
- `22_for_generic.lua` / `38_generic_for_inplace_yield.lua`: CLOSE handler double-increment (Task 3 not applied correctly)
- `27_iterative_bytecode_calls.lua`: deep recursion crash — check `ctx.fr` aliasing in hooks block; verify `syncDispatchCtx` re-derives `saved` via `exec_frames.getPtr` (not `ctx.fr`)
- `31_debug_bytecode_parity.lua`: hooks block using stale `ctx.fr.current_line` — verify lineinfo read still runs per-instruction on fast path
- `37_inplace_bytecode_yield.lua`: coroutine park/resume — verify `parkActiveRuntime` doesn't need pc sync (fr.pc already current)

- [ ] **Step 2: Matrix tests**

```bash
cd lua-5.5.0/testes && python3 ../../tools/testes_matrix.py --timeout 120
```

Expected: 28/31 (same as baseline).

Diagnosis guide for regressions:
- `gc.lua` / `gengc.lua`: `syncTopFrameForGc` not syncing pc — verify fr.pc is already current (the dispatch loop writes ctx.fr.pc directly)
- `calls.lua`: `require` re-entrancy — verify outer dispatch continues correctly after nested call returns (outer ctx.fr untouched by nested call)
- `coroutine.lua`: `parkActiveRuntime` / `activateRuntime` — verify fr.pc survives park/resume without explicit sync
- `db.lua`: `callBuiltin` lineinfo read — verify current_line is correct for debug.getinfo/error
- `errors.lua`: `fail()` line number — verify fr.pc gives correct lineinfo[fr.pc] at error site
- `events.lua`: hook dispatch — verify hooks block reads correct current_line from ctx.fr

- [ ] **Step 3: Perf measurement**

```bash
python3 tools/perf_compare.py --runs 7 --core 0
```

Expected: geomean ≤ 3.05× (from 3.10× baseline).

- [ ] **Step 4: Update baseline if improved >3%**

```bash
python3 tools/perf_compare.py --runs 7 --core 0 --update-baseline
```

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig tools/perf/
git commit -m "fr.pc as sole pc: eliminate bc_dispatch_pc/bc_dispatch_active

ctx.fr.pc replaces 3 copies of pc (ctx.pc, bc_dispatch_pc, fr.pc) with
one. fail()/callBuiltin() read fr.pc from topmost frame directly — no
sync needed. Re-entrancy from require/dofile is safe because each
runBytecodeDispatch has its own ctx (Zig stack), and nested calls don't
touch parent frame pc.

Per-instruction stores eliminated:
- self.bc_dispatch_pc = ctx.fr.pc  (store to Vm field)
- self.bc_dispatch_active = true   (store to Vm field)

ctx.fr pointer is safe because exec_frames only grows via
pushBytecodeExecFrame which always exits inner loop via
continue :frame_loop."
```

---

### Task 7: Update README

- [ ] **Step 1: Add entry to changelog**

After the DispatchLoopSlim entry (~line 2072), add:

```markdown
- fr.pc sole pc: eliminated `bc_dispatch_pc` and `bc_dispatch_active` from Vm.
  `ctx.fr: *CallFrame` pointer gives direct access to `fr.pc` (like PUC's
  `ci->u.l.savedpc`). Three copies of pc reduced to one. `fail()` and
  `callBuiltin()` read `fr.pc` from topmost frame directly. Per-instruction
  `bc_dispatch_pc` store and `bc_dispatch_active` store eliminated (-2 cycles).
  Re-entrancy from `require`/`dofile` is safe — each `runBytecodeDispatch`
  invocation has its own `ctx` (Zig stack), nested calls don't touch parent
  frame pc. `ctx.fr` pointer is safe because `exec_frames` only grows via
  `pushBytecodeExecFrame` which always exits inner loop via `continue :frame_loop`.
  Geomean: **[fill perf numbers]**.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "README: fr.pc sole pc changelog"
```

---

## Risk register

1. **CLOSE handler double-increment**: `continueBytecodeClose` increments `fr.pc` directly (line 4744: `exec_frames.getPtr(parent_index).pc += 1`). The CLOSE handler previously mirrored this with `ctx.pc += 1`. With `ctx.fr.pc` IS `fr.pc`, the mirror becomes a double-increment.
   **Fix**: Task 3 removes the mirror.
   **Test**: `22_for_generic.lua` catches this immediately (generic-for with TBC uses OP_CLOSE).

2. **Deep recursion (32+ frames)**: `ctx.fr` points into `FrameStack.heap` for frames 32+. Heap realloc on `pushBytecodeExecFrame` could invalidate the pointer.
   **Mitigation**: `pushBytecodeExecFrame` always exits the inner loop via `continue :frame_loop`, which triggers `defer { syncDispatchCtx }` and then `loadDispatchCtx` re-derives `ctx.fr`. The pointer is never used after a heap realloc.
   **Test**: `27_iterative_bytecode_calls.lua` (350 non-tail calls).

3. **Re-entrancy from require/dofile**: `runClosure` → `runBytecodeInternal` → `runBytecodeDispatch` is recursive. The nested call's defer previously cleared `bc_dispatch_active`. Without `bc_dispatch_active`, there's nothing to clear. The outer `ctx.fr` (on Zig stack) is untouched by the nested call.
   **Test**: `calls.lua` uses `require` heavily.

4. **Coroutine park/resume**: `parkActiveRuntime` previously synced `fr.pc = bc_dispatch_pc`. Without `bc_dispatch_pc`, there's nothing to sync. `fr.pc` is already current (written directly by dispatch loop).
   **Test**: `coroutine.lua`, `37_inplace_bytecode_yield.lua`.

5. **Error message line numbers**: `fail()` previously synced `fr.pc = bc_dispatch_pc` before reading lineinfo. Without the sync, `fr.pc` must already be current. Since the dispatch loop writes `ctx.fr.pc` directly (the `ctx.fr.pc += 1` at the bottom of the loop hasn't run yet when `fail()` is called from a handler), `fr.pc` points at the current instruction.
   **Test**: `errors.lua`, `db.lua`.

6. **syncDispatchCtx using stale ctx.fr**: `syncDispatchCtx` must re-derive `saved` via `exec_frames.getPtr(ctx.frame_index)`, NOT use `ctx.fr` directly. If `exec_frames` heap was realloc'd by a handler before `continue :frame_loop`, `ctx.fr` may be stale. The re-derivation in `syncDispatchCtx` (already in the code from Task 1 Step 3) handles this.
   **Test**: `27_iterative_bytecode_calls.lua`.

## Self-review

**Perf analysis (per-instruction overhead):**

| Operation | Before | After | Saved |
|---|---|---|---|
| `bc_dispatch_pc = ctx.pc` (store) | ~1 cycle | 0 | ~1 |
| `bc_dispatch_active = true` (store) | ~1 cycle | 0 | ~1 |
| **Total per-instruction** | **~2 cycles** | **0** | **~2** |

At 3.5 GHz: ~0.57 ns saved per instruction. For int_arith (~4.4 ns/instruction): ~13% improvement.

**Architecture check:**

| Aspect | PUC Lua | Our approach | Match |
|---|---|---|---|
| Sole pc | `ci->u.l.savedpc` | `ctx.fr.pc` (= `fr.pc`) | ✅ |
| dispatch_pc field | none | none (eliminated) | ✅ |
| active flag | none | none (eliminated) | ✅ |
| Re-entrancy | `luaD_call` → `luaV_execute` | `runClosure` → `runBytecodeDispatch` | ✅ |
| require/dofile | recursive `luaD_call` | recursive `runClosure` | ✅ |
| fail() reads pc | `ci->u.l.savedpc` | `exec_frames.getPtr(top).pc` | ✅ |

**Verification commands (per AGENTS.md):**

```bash
# Regression testing (mandatory per AGENTS.md)
python3 tools/testes_matrix.py --timeout 120
# All tests/smoke/ must pass
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig --vm=bc "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
# Compile in ReleaseFast
zig build -Doptimize=ReleaseFast
```
