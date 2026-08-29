# DispatchLoopSlim — PUC-faithful dispatch loop

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate per-instruction dispatch overhead by making the dispatch loop work directly with `*CallFrame` (like PUC's `CallInfo*`), instead of caching/syncing frame state through `BytecodeDispatchCtx` + `bc_dispatch_pc` + `bc_dispatch_active`.

**Architecture:** `fr.pc` becomes the sole program counter (like PUC's `ci->u.l.savedpc`). No per-instruction stores. No per-instruction lineinfo read. No per-instruction stack realloc check. `callBuiltin` and error recovery read `fr.pc` from the topmost frame directly.

**Expected perf:** -5-6 cycles/instruction. geomean 3.20× → ~2.7×.

**Spec reference:** PUC Lua `luaV_execute` (lvm.c:1198-1233):

```c
for (;;) {
    if (L->hookmask & (LUA_MASKLINE|LUA_MASKCOUNT))
        luaG_traceexec(L);               // 1 bitmask test
    Instruction i = *ci->u.l.savedpc++;  // fetch + increment in one
    vmdispatch(GET_OPCODE(i)) { ... }    // switch
}
```

Between iterations: NOTHING. No stack check, no pc sync, no lineinfo read.

---

## Current overhead per instruction

Our dispatch loop (~line 7741) does **6 extra operations** per iteration:

| # | Operation | Cycles | PUC equivalent |
|---|---|---|---|
| 1 | `stack_ptr` check (2 loads + 2 compares + branch) | ~2 | — (never reallocs) |
| 2 | `self.bc_dispatch_pc = ctx.pc` (store) | ~1 | — (savedpc IS the pc) |
| 3 | `self.bc_dispatch_active = true` (store, redundant) | ~1 | — |
| 4 | `lineinfo[pc]` check (load + compare + conditional store) | ~2 | — (only in hook handler) |
| 5 | `hooks_active_cached` load (load + compare + branch) | ~1 | 1 bitmask test |
| 6 | `ctx.pc += 1` after switch (separate from fetch) | ~1 | `*savedpc++` inline |

**Total overhead: ~8 cycles. PUC: ~1 cycle. Gap: ~7 cycles (~2 ns at 3.5 GHz).**

---

## File Structure

- **Modify:** `src/lua/vm.zig` — all changes in this file

---

### Task 1: Pre-allocate EXTRA_MARGIN per frame

**Goal:** Guarantee bc_stack never reallocs during simple instruction execution (ADD, SUB, MOVE, FORLOOP, etc.). This eliminates the `stack_ptr` check on the fast path.

PUC uses `EXTRA_STACK = 5` at the end of the global stack (lstate.h:142). We pre-allocate `maxstacksize + EXTRA_MARGIN` per frame (same value: 5), so `bcGrowFrame` for multiret within the margin is a no-op.

**Files:** `src/lua/vm.zig` — `pushBytecodeExecFrame` (~line 7013)

- [ ] **Step 1: Define EXTRA_MARGIN constant**

Near `const empty_varargs` (~line 757):

```zig
/// Extra register slots pre-allocated per frame for multiret temporaries.
/// Matches PUC EXTRA_STACK=5 (lstate.h:142). Per-frame margin is safer
/// than PUC's global end-of-stack margin — each frame has its own.
/// bcGrowFrame is a no-op for typical multiret (≤5 values).
/// Eliminates the per-instruction stack_ptr realloc check.
const EXTRA_MARGIN: usize = 5;
```

- [ ] **Step 2: Change frame_cap in pushBytecodeExecFrame**

At ~line 7013, change:

```zig
const frame_cap: usize = proto.maxstacksize;
```

to:

```zig
const frame_cap: usize = proto.maxstacksize + EXTRA_MARGIN;
```

Everything downstream (`ensureBcStackCap`, `bc_stack_top`, `regs`, `boxed`) automatically accounts for the larger window. The stack overflow check at ~line 7014 still uses `frame_cap` (now larger) which is correct — it checks `frame_cap > lua_max_stack_slots -| bc_stack_top`.

- [ ] **Step 3: Verify bcGrowFrame is a no-op for typical multiret**

`bcGrowFrame` (~line 2358) checks `if (needed_local > frame_cap.*)`. With `frame_cap = maxstacksize + 8`, multiret results that fit within 8 slots (the vast majority) don't trigger growth. `bcGrowFrame` still re-derives `regs`/`boxed` slices and updates the frame — but doesn't call `ensureBcStackCap` or extend `bc_stack_top`.

No code change needed — just verify.

- [ ] **Step 4: Build + smoke + matrix**

```bash
zig build -Doptimize=ReleaseFast
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig --vm=bc "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
cd lua-5.5.0/testes && python3 ../../tools/testes_matrix.py --timeout 120
```

Expected: 45/45 smoke, 28/31 matrix.

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "DispatchLoopSlim: pre-allocate EXTRA_MARGIN per frame"
```

---

### Task 2: Use `fr.pc` as sole pc, eliminate `bc_dispatch_pc` / `bc_dispatch_active`

**Goal:** `fr.pc` is the authoritative program counter (like PUC's `ci->u.l.savedpc`). The dispatch loop reads/writes it directly. No Vm-level pc copy, no sync, no active flag.

**Files:** `src/lua/vm.zig` — `BytecodeDispatchCtx` struct, dispatch loop (~7620), `loadDispatchCtx` (~7563), `syncDispatchCtx` (~7591), `callBuiltin` (~11405), error paths (~2930-3015, ~3261), `parkActiveRuntime` (~2102), `activateRuntime` (~2175)

**Current architecture (3 copies of pc):**

```
ctx.pc (local)  ←→  self.bc_dispatch_pc (Vm field)  ←→  fr.pc (frame field)
```

**Target architecture (1 copy):**

```
fr.pc (frame field) — read/written directly by dispatch loop
```

- [ ] **Step 1: Add `fr: *CallFrame` to BytecodeDispatchCtx**

In the `BytecodeDispatchCtx` struct (~line 7510), add a direct frame pointer and remove `pc`:

```zig
const BytecodeDispatchCtx = struct {
    // Immutable within a frame_loop iteration.
    exec_frames: *FrameStack,
    fr: *CallFrame,               // NEW: direct frame pointer
    frame_index: usize,
    boundary_depth: usize,
    yielded_in_place: *bool,

    // Frame state (cached from fr for register performance).
    cur_proto: *const bc.Proto,
    cur_upvalues: []const *Cell,
    base: usize,
    frame_cap: usize,
    // pc REMOVED — use fr.pc
    resume_pc: usize,
    reg_top: u32,
    nvarstack: u32,
    nextraargs: u16,
    varargs: []Value,
    tbc_mark: usize,

    // Mutable register window.
    regs: []Value,
    boxed: []?*Cell,

    // Debug/hook state.
    hooks_active: bool,
};
```

Note: `frame_current_line`, `frame_last_hook_line`, `frame_is_tailcall`, `resumed_direct_yield` are also removed — read directly from `fr` when needed (cold path or frame_loop entry/exit).

- [ ] **Step 2: Update loadDispatchCtx**

In `loadDispatchCtx` (~line 7563), set `ctx.fr` and remove pc/line/tailcall loads:

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

In `syncDispatchCtx` (~line 7591), remove pc/line/tailcase/resumed writes — they're already in fr:

```zig
fn syncDispatchCtx(self: *Vm, ctx: *const BytecodeDispatchCtx) void {
    if (ctx.frame_index >= ctx.exec_frames.len()) return;
    const saved = ctx.fr;
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

- [ ] **Step 4: Change dispatch loop to use fr.pc**

The inner loop (~line 7741) changes from:

```zig
while (ctx.pc < ctx.cur_proto.code.len) {
    // stack_ptr check...
    const inst = ctx.cur_proto.code[ctx.pc];
    const op: bc.Op = @enumFromInt(inst.op);
    const a = inst.a; const b = inst.b; const c = inst.c;
    self.bc_dispatch_pc = ctx.pc;
    self.bc_dispatch_active = true;
    if (lineinfo check) ctx.frame_current_line = ...;
    ctx.hooks_active = self.hooks_active_cached;
    if (ctx.hooks_active) { ... }
    switch (op) { ... }
    ctx.pc += 1;
}
```

to:

```zig
while (ctx.fr.pc < ctx.cur_proto.code.len) {
    const inst = ctx.cur_proto.code[ctx.fr.pc];
    ctx.fr.pc += 1;                               // = *savedpc++
    const op: bc.Op = @enumFromInt(inst.op);
    const a = inst.a; const b = inst.b; const c = inst.c;
    // NO bc_dispatch_pc store
    // NO bc_dispatch_active store
    // NO lineinfo check (moved to hooks block — Task 3)
    ctx.hooks_active = self.hooks_active_cached;
    if (ctx.hooks_active) {
        // Hook handling — reads fr.pc, fr.current_line
    }
    switch (op) { ... }
    // NO ctx.pc += 1 (already done above)
}
```

**CRITICAL — branch offset adjustment:** `ctx.fr.pc += 1` happens BEFORE the switch (like PUC's `*savedpc++`). Branch instructions that set `ctx.fr.pc` to a target must account for this:

Current FORLOOP:
```zig
ctx.pc = @intCast(@as(i64, @intCast(ctx.pc)) + @as(i64, off) + 1);
continue;  // skip bottom ctx.pc += 1
```
The `+1` compensates for the bottom increment that's now skipped. With pc incremented BEFORE the switch, the `+1` must be removed:
```zig
ctx.fr.pc = @intCast(@as(i64, @intCast(ctx.fr.pc)) + @as(i64, off));
continue;
```

Apply this to ALL instructions that set pc and `continue`:
- FORLOOP (~9348): remove `+ 1`
- FORPREP (~9323): backward jump — check offset
- TFORLOOP (~9391): check offset
- JMP (if any direct pc manipulation): check offset
- Any `.continue_no_advance` return from extracted handlers

Search: `rg "ctx.pc.*\+.*1\|continue_no_advance" src/lua/vm.zig`

- [ ] **Step 5: Remove bc_dispatch_pc and bc_dispatch_active from Vm**

Delete field declarations (~line 1878, ~1883):
```zig
bc_dispatch_pc: usize = 0,        // DELETE
bc_dispatch_active: bool = false, // DELETE
```

Delete per-iteration stores in dispatch loop:
```zig
self.bc_dispatch_pc = ctx.pc;     // DELETE (already done in Step 4)
self.bc_dispatch_active = true;   // DELETE
```

Delete the defer in `runBytecodeDispatch` (~line 7627):
```zig
self.bc_dispatch_active = true;                   // DELETE
defer self.bc_dispatch_active = false;            // DELETE
```

- [ ] **Step 6: Update callBuiltin (~line 11405)**

Delete the entire pc sync block:
```zig
// DELETE this entire block:
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

`fr.pc` is already current (it was incremented before the switch handler ran). `callBuiltin` reads `fr.pc` from the topmost frame when needed — no sync.

- [ ] **Step 7: Update error paths**

At ~lines 2930-3015 and ~3261, multiple error paths do:
```zig
if (self.bc_dispatch_active) fr.pc = self.bc_dispatch_pc;
```

Delete ALL these lines. `fr.pc` is already current.

The lineinfo reads that follow STAY (error messages need line numbers):
```zig
if (fr.proto) |proto| {
    if (fr.pc > 0 and fr.pc - 1 < proto.lineinfo.len and proto.lineinfo[fr.pc - 1] != 0) {
        fr.current_line = @intCast(proto.lineinfo[fr.pc - 1]);
    }
}
```

Note: use `fr.pc - 1` because fr.pc was incremented before the handler ran (it points to the NEXT instruction; the current instruction is at `fr.pc - 1`).

Sites to fix:
```bash
rg "bc_dispatch_active.*fr.pc.*bc_dispatch_pc" src/lua/vm.zig
```

- [ ] **Step 8: Update parkActiveRuntime (~line 2102)**

Delete:
```zig
if (owner.call_frames.len() != 0) {
    owner.call_frames.getPtr(owner.call_frames.len() - 1).pc = self.bc_dispatch_pc;
}
```

`fr.pc` is already current — no sync needed on park.

- [ ] **Step 9: Update activateRuntime (~line 2175)**

Delete:
```zig
if (owner.call_frames.len() != 0) {
    self.bc_dispatch_pc = owner.call_frames.getPtr(owner.call_frames.len() - 1).pc;
}
```

`bc_dispatch_pc` no longer exists. The activated thread's `fr.pc` is already correct.

- [ ] **Step 10: Update BytecodeDispatchCtx initializer**

In `runBytecodeDispatch` (~line 7620), the ctx initializer:
```zig
var ctx: BytecodeDispatchCtx = .{
    .exec_frames = exec_frames,
    .fr = undefined,           // NEW: set by loadDispatchCtx
    .frame_index = 0,
    .boundary_depth = boundary_depth,
    .yielded_in_place = yielded_in_place,
    .cur_proto = undefined,
    // ... remaining fields ...
    // pc field DELETED
};
```

- [ ] **Step 11: Update all `ctx.pc` references to `ctx.fr.pc`**

Search for remaining `ctx.pc` references:
```bash
rg "ctx\.pc\b" src/lua/vm.zig
```

Each must change to `ctx.fr.pc`. Key sites:
- Inner loop condition: `ctx.fr.pc < ctx.cur_proto.code.len`
- Inner loop fetch: `ctx.cur_proto.code[ctx.fr.pc]`
- Branch instructions: all `ctx.pc =` → `ctx.fr.pc =`
- Hook handlers: `ctx.pc` → `ctx.fr.pc`
- Resume/skip logic: `ctx.resume_pc`, `ctx.skip_line_hook_pc` — these are separate fields, leave as-is

- [ ] **Step 12: Build and fix compilation errors**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | grep "error:" | head -30
```

Expected errors:
- `ctx.pc` not found → change to `ctx.fr.pc`
- `bc_dispatch_pc` not found → delete the line
- `bc_dispatch_active` not found → delete the line
- `ctx.frame_current_line` not found → use `ctx.fr.current_line`
- `ctx.frame_is_tailcall` not found → use `ctx.fr.is_tailcall`
- `ctx.resumed_direct_yield` not found → use `ctx.fr.resumed_direct_yield`
- Branch offset off-by-one → remove `+ 1` from branch calculations

- [ ] **Step 13: Run smoke tests**

```bash
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig --vm=bc "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
```

Expected: 45/45.

If for-loop tests fail: branch offset `+1` issue — check FORLOOP/FORPREP.
If hook tests fail: `ctx.fr.current_line` not being set correctly.
If coroutine tests fail: park/resume pc sync issue.

- [ ] **Step 14: Run matrix**

```bash
cd lua-5.5.0/testes && python3 ../../tools/testes_matrix.py --timeout 120
```

Expected: 28/31.

- [ ] **Step 15: Commit**

```bash
git add src/lua/vm.zig
git commit -m "DispatchLoopSlim: use fr.pc as sole pc, eliminate bc_dispatch_pc/active"
```

---

### Task 3: Move lineinfo read to hooks cold path

**Goal:** Stop reading `lineinfo[pc]` on every instruction. Only read it when hooks are active or when an error occurs.

**Files:** `src/lua/vm.zig` — dispatch loop fast path (~line 7772), hooks block (~7780)

- [ ] **Step 1: Remove lineinfo read from fast path**

The lineinfo read was already removed in Task 2 Step 4 (the per-iteration block was deleted). Verify there's no remaining lineinfo read between instruction fetch and switch.

- [ ] **Step 2: Add lineinfo read to hooks block**

Inside `if (ctx.hooks_active)` (~line 7780), BEFORE the hook dispatch:

```zig
if (ctx.hooks_active) {
    @branchHint(.unlikely);
    const cur_pc = ctx.fr.pc - 1;  // fr.pc was incremented; -1 = current instruction
    if (cur_pc < ctx.cur_proto.lineinfo.len and ctx.cur_proto.lineinfo[cur_pc] != 0) {
        ctx.fr.current_line = @intCast(ctx.cur_proto.lineinfo[cur_pc]);
    }
    // ... existing hook dispatch ...
}
```

- [ ] **Step 3: Verify error paths read lineinfo lazily**

Error paths (Task 2 Step 7) already read `lineinfo[fr.pc - 1]` explicitly. Verify:
```bash
rg "lineinfo\[fr\.pc" src/lua/vm.zig
```
Each should use `fr.pc - 1` (not `fr.pc` directly, since fr.pc points to the next instruction).

- [ ] **Step 4: Build + smoke + matrix**

Expected: 45/45 smoke, 28/31 matrix. If `db.lua` line numbers are wrong, check `fr.pc - 1` adjustment.

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "DispatchLoopSlim: move lineinfo read to hooks cold path"
```

---

### Task 4: Remove stack_ptr check from inner loop

**Goal:** With EXTRA_MARGIN (Task 1), bc_stack never reallocs during simple instruction execution. Remove the per-iteration ptr comparison.

**Files:** `src/lua/vm.zig` — dispatch loop (~line 7733-7755)

- [ ] **Step 1: Delete stack_ptr variables and check**

Delete the variable declarations (~line 7733):
```zig
var stack_ptr = self.bc_stack.ptr;          // DELETE
var stack_boxed_ptr = self.bc_boxed.ptr;    // DELETE
var cached_frame_cap = ctx.frame_cap;       // DELETE
```

Delete the check block (~line 7746):
```zig
if (self.bc_stack.ptr != stack_ptr or       // DELETE entire block
    self.bc_boxed.ptr != stack_boxed_ptr or
    ctx.frame_cap != cached_frame_cap)
{
    ctx.regs = self.bc_stack[ctx.base .. ctx.base + ctx.frame_cap];
    ctx.boxed = self.bc_boxed[ctx.base .. ctx.base + ctx.frame_cap];
    stack_ptr = self.bc_stack.ptr;
    stack_boxed_ptr = self.bc_boxed.ptr;
    cached_frame_cap = ctx.frame_cap;
}
```

- [ ] **Step 2: Verify handlers re-derive slices after potential realloc**

Handlers that call `bcGrowFrame` or `pushBytecodeExecFrame` may trigger bc_stack realloc. After such calls, `ctx.regs`/`ctx.boxed` are stale. Each handler MUST re-derive them.

Search for handlers that call bcGrowFrame:
```bash
rg "bcGrowFrame" src/lua/vm.zig | grep -v "fn \|//"
```

Key sites (~11 call sites):
- opVararg (~9720, ~9732): already re-derives via bcGrowFrame's out-params
- opCall (~10475): already re-derives
- opTailcall (~10266): already re-derives
- OP_SETLIST handler: check
- IR interp (~26840): check

For each: verify `ctx.regs` is refreshed after the call. If missing, add:
```zig
ctx.regs = self.bc_stack[ctx.base .. ctx.base + ctx.frame_cap];
ctx.boxed = self.bc_boxed[ctx.base .. ctx.base + ctx.frame_cap];
```

- [ ] **Step 3: Build + smoke + matrix**

Expected: 45/45 smoke, 28/31 matrix. If SIGSEGV: a handler is using stale slices after bc_stack realloc. Binary-search with smoke tests to find the offending handler.

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "DispatchLoopSlim: remove stack_ptr check from inner loop"
```

---

### Task 5: Perf measurement + README

- [ ] **Step 1: Perf comparison**

```bash
python3 tools/perf_compare.py --runs 7 --core 0
```

Expected: geomean ≤ 2.9× (from 3.20×). Key workloads:
- int_arith: ≤ 2.3× (from 2.77×) — pure dispatch overhead
- lua_calls: ≤ 3.5× (from 4.43×) — dispatch + call overhead
- hash_access: ≤ 4.0× (from 4.92×) — dispatch + hash overhead
- array_access: ≤ 3.2× (from 4.24×) — dispatch + array overhead

- [ ] **Step 2: Update baseline if improved >3%**

```bash
python3 tools/perf_compare.py --runs 7 --core 0 --update-baseline
```

- [ ] **Step 3: Update README**

Add section:

```markdown
### DispatchLoopSlim — PUC-faithful dispatch loop

Eliminate per-instruction dispatch overhead by working directly with
`*CallFrame` (like PUC's `CallInfo*`), instead of caching/syncing frame
state through BytecodeDispatchCtx + bc_dispatch_pc + bc_dispatch_active.

Changes:
- `fr.pc` is the sole program counter (like PUC `ci->u.l.savedpc`).
  Eliminated `ctx.pc`, `bc_dispatch_pc`, `bc_dispatch_active` — three
  copies of pc reduced to one.
- `EXTRA_MARGIN` (8 slots) pre-allocated per frame. `bcGrowFrame` is a
  no-op for typical multiret. Eliminated per-instruction stack realloc
  check (2 loads + 2 compares per instruction).
- `lineinfo[pc]` read moved from fast path to hooks cold path. Error
  paths read lineinfo lazily (`lineinfo[fr.pc - 1]`).
- `callBuiltin` reads `fr.pc` from topmost frame directly. No pc sync.
- `parkActiveRuntime` / `activateRuntime`: no pc sync needed.

Result: dispatch loop per-iteration overhead reduced from ~8 cycles to
~1 cycle (matching PUC's `*savedpc++` + bitmask test).

**Results:** [fill perf numbers]
```

- [ ] **Step 4: Commit**

```bash
git add README.md tools/perf/
git commit -m "DispatchLoopSlim: update README + perf baseline"
```

---

## Risk register

1. **Branch offset +1**: Moving pc increment before the switch changes branch offset semantics. FORLOOP/FORPREP currently add `+1` to compensate for the bottom-of-loop increment. With increment-at-top, the `+1` must be removed.
   **Mitigation:** Task 2 Step 4 explicitly lists all branch instructions. Smoke tests 06_for_numeric.lua and 32_for_loop_locvars.lua catch offset errors immediately.

2. **Stale slices after bc_stack realloc**: Removing stack_ptr check means handlers must re-derive `regs`/`boxed` after any potential realloc.
   **Mitigation:** Task 4 Step 2 verifies each bcGrowFrame call site. SIGSEGV during testing pinpoints the missing re-derivation.

3. **Error message line numbers**: `fr.current_line` is no longer updated on fast path. Error messages must read lineinfo lazily.
   **Mitigation:** Task 3 Step 3 verifies error paths use `lineinfo[fr.pc - 1]`. `errors.lua` and `db.lua` tests verify line numbers.

4. **callBuiltin during error recovery**: Currently guarded by `bc_dispatch_active`. Without it, callBuiltin reads fr.pc which is always current — the topmost frame IS the dispatch frame. No guard needed.
   **Mitigation:** Verified by architecture analysis — the topmost frame is always the one executing.

## Self-review

**Perf analysis (per-instruction overhead):**

| Operation | Before | After | Saved |
|---|---|---|---|
| stack_ptr check | ~2 cycles | 0 | ~2 |
| bc_dispatch_pc store | ~1 cycle | 0 | ~1 |
| bc_dispatch_active store | ~1 cycle | 0 | ~1 |
| lineinfo read | ~2 cycles | 0 (cold path) | ~2 |
| hooks check | ~1 cycle | ~1 cycle | 0 |
| pc fetch + increment | ~2 cycles | ~1 cycle | ~1 |
| **Total** | **~9 cycles** | **~2 cycles** | **~7 cycles** |

At 3.5 GHz: ~2 ns saved per instruction. For int_arith (9.7 ns): ~20% improvement.
