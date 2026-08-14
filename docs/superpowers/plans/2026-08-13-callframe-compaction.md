# CallFrame Compaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compact `CallFrame` from ~344B to <100B by removing dead/duplicated/derivable fields, moving hook/debug state to thread-level, and moving `PendingCallSlot` to per-Thread sparse storage.

**Architecture:** Remove dead fields (`env_override`, `varargs` for bytecode). Derive `upvalues`, `current_line` on demand. Move hook/debug fields to Thread. Move `debug_namewhat`/`debug_name` to Vm-level save/restore. Compact `?usize` pc fields to `u32` sentinels. Move `PendingCallSlot` to per-Thread sparse continuation storage with a `u32` handle in CallFrame.

**Tech Stack:** Zig (system toolchain), PUC Lua 5.5 (vendored reference), luazig bytecode VM.

**Spec:** `docs/superpowers/specs/2026-08-13-callframe-compaction-design.md`

**Test commands:**
```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc          # matrix 30/31
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
zig build test                                   # unit 146/146
python3 tools/perf_compare.py                    # geomean, WARN +5%, FAIL +10%
```

**AGENTS.md rules (critical):**
- No match-by-name / line-range / special-case hacks
- PUC-first: architecture follows PUC Lua 5.5
- Each task: separate commit + regression tests
- `frame_loop` preserved, no host recursion
- After each task: update STATUS.md, run regression tests
- All `CallFrame*` pointers must be reacquired after reentrant operations

---

## Task 1: Remove dead `env_override` field from CallFrame

**Goal:** Remove `env_override: ?Value` from CallFrame — it is always null, never set to a non-null value. Dead field, saves ~24B.

**Files:**
- Modify: `src/lua/vm.zig` — CallFrame struct (L1138), pushBytecodeExecFrame (L7586), GC marking (L15433, L16667)

- [ ] **Step 1: Remove `env_override` field from CallFrame struct**

In `src/lua/vm.zig`, remove the field declaration:
```zig
    // DELETE THIS LINE:
    env_override: ?Value = null,
```

- [ ] **Step 2: Remove `env_override` writes from pushBytecodeExecFrame**

In `pushBytecodeExecFrame` (L7586), remove:
```zig
    // DELETE THIS LINE:
    ef_slot.env_override = null;
```

- [ ] **Step 3: Remove `env_override` reads from GC marking**

In GC marking (L15433), remove:
```zig
    // DELETE THIS LINE:
    if (frame.env_override) |environment| try self.gcMarkValue(environment);
```

In generational GC marking (L16667), remove:
```zig
    // DELETE THIS BLOCK:
    if (exec_fr.env_override) |env_v| {
        if (GcObject.fromValue(env_v) != null) {
            try self.gcMarkValue(env_v);
        }
    }
```

- [ ] **Step 4: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
zig build test
```

Expected: All pass (30/31, 49/49, 146/146). No behavior change — field was always null.

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51n: remove dead env_override field from CallFrame (always null, ~24B saved)"
```

---

## Task 2: Remove `varargs` field from CallFrame (IR-only, derive from closure)

**Goal:** Remove `varargs: []Value` from CallFrame. For bytecode frames, varargs are on bc_stack via `nextraargs`. For IR frames (proto == null), derive from the IR closure's varargs storage.

**Files:**
- Modify: `src/lua/vm.zig` — CallFrame struct (L1092), frameVarargs (L2894), popBytecodeExecFrame (L7619), GC marking (L15423), pushBytecodeExecFrame (L7559)

- [ ] **Step 1: Check IR frame varargs usage**

Search for all sites that read `frame.varargs`:
```bash
grep -n "\.varargs\b" src/lua/vm.zig | grep -v "fn \|//\|test\|doc\|nextraargs\|vararg_table\|is_vararg\|varargprep\|VARARG\|vararg_"
```

Key sites:
- `frameVarargs` (L2900): returns `frame.varargs` for IR frames
- `popBytecodeExecFrame` (L7619): frees `frame.varargs` for IR frames
- GC marking (L15423): marks `frame.varargs` values
- `debug.getinfo` (L18960): reports extraargs count

- [ ] **Step 2: Store IR varargs on the IR closure instead of CallFrame**

IR frames have `proto == null`. The IR closure at `bc_stack[func_slot]` can store the varargs slice. Check if `Closure` already has a field for this, or add one.

Actually, IR frames are rare (frozen IR closures). The simplest approach: store IR varargs in a per-Thread map keyed by frame index, or store them on the `Closure` struct. Check `Closure`:

```bash
grep -n "const Closure = struct" src/lua/vm.zig
```

Add `ir_varargs: ?[]Value = null` to `Closure` (only used by IR closures). Set it when the IR frame is pushed, read it from `bc_stack[func_slot].Closure.ir_varargs` when needed.

- [ ] **Step 3: Update `frameVarargs` to derive from closure**

Change `frameVarargs` to:
```zig
fn frameVarargs(self: *Vm, frame: *const CallFrame, th: ?*Thread) []Value {
    if (frame.proto != null and frame.nextraargs != 0) {
        const stack = stackForThread(self, th);
        return stack[frame.func_slot - frame.nextraargs .. frame.func_slot];
    }
    // IR frames: derive from closure
    const stack = stackForThread(self, th);
    const cl = stack[frame.func_slot].Closure;
    return cl.ir_varargs orelse &.{};
}
```

- [ ] **Step 4: Update `popBytecodeExecFrame` to free IR varargs from closure**

Change the IR varargs free:
```zig
// OLD:
if (frame.proto == null and frame.varargs.len != 0) self.alloc.free(frame.varargs);
// NEW:
if (frame.proto == null) {
    const cl = self.bc_stack[frame.func_slot].Closure;
    if (cl.ir_varargs) |va| {
        self.alloc.free(va);
        cl.ir_varargs = null;
    }
}
```

- [ ] **Step 5: Update GC marking to mark IR varargs from closure**

In GC marking, replace `frame.varargs` iteration with closure-based access:
```zig
// OLD:
for (frame.varargs) |value| try self.gcMarkValue(value);
// NEW:
if (frame.proto == null) {
    const cl = self.bc_stack[frame.func_slot].Closure;
    if (cl.ir_varargs) |va| {
        for (va) |value| try self.gcMarkValue(value);
    }
}
```

- [ ] **Step 6: Remove `varargs` field from CallFrame and its writes**

Remove `varargs: []Value = &.{}` from CallFrame struct. Remove `ef_slot.varargs = &.{};` from pushBytecodeExecFrame. Update all sites that set `frame.varargs` to instead set `cl.ir_varargs`.

- [ ] **Step 7: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
zig build test
```

Expected: All pass. ~16B saved.

- [ ] **Step 8: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51n: remove varargs from CallFrame (IR-only, derive from closure, ~16B saved)"
```

---

## Task 3: Remove `upvalues` field from CallFrame (derive from bc_stack[func_slot])

**Goal:** Remove `upvalues: []const *Cell` from CallFrame. Derive from `bc_stack[func_slot].Closure.upvalues`. The hot path already caches this in `BytecodeDispatchCtx.cur_upvalues`.

**Files:**
- Modify: `src/lua/vm.zig` — CallFrame struct (L1093), pushBytecodeExecFrame (L7560), syncFrame (L8099, L8172), GC marking (L15425, L16655)

- [ ] **Step 1: Add `frameUpvalues` helper function**

Add a helper that derives upvalues from bc_stack:
```zig
fn frameUpvalues(self: *Vm, frame: *const CallFrame, th: ?*Thread) []const *Cell {
    if (frame.proto) |_| {
        const stack = stackForThread(self, th);
        return stack[frame.func_slot].Closure.upvalues;
    }
    return &.{};
}
```

- [ ] **Step 2: Update `syncFrame` to derive upvalues from bc_stack**

In `syncFrame`, change `fr.upvalues = ctx.cur_upvalues;` to a no-op (upvalues are no longer stored in frame). In `frame_loop` entry, change `ctx.cur_upvalues = fr.upvalues;` to derive from bc_stack:
```zig
ctx.cur_upvalues = if (fr.proto) |_| 
    self.bc_stack[fr.func_slot].Closure.upvalues 
else 
    &.{};
```

- [ ] **Step 3: Update GC marking to derive upvalues from bc_stack**

Replace `for (frame.upvalues) |cell|` with:
```zig
const uvs = self.frameUpvalues(frame, null);
for (uvs) |cell| {
    try self.gcQueueScanCell(cell);
}
```

Do the same for the generational GC marking path.

- [ ] **Step 4: Remove `upvalues` field and its writes**

Remove `upvalues: []const *Cell = &.{}` from CallFrame. Remove `ef_slot.upvalues = upvalues;` from pushBytecodeExecFrame.

- [ ] **Step 5: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
zig build test
python3 tools/perf_compare.py
```

Expected: All pass. ~16B saved. Perf neutral (one extra indirection on frame_loop entry, but upvalues already cached in ctx).

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51n: remove upvalues from CallFrame (derive from bc_stack[func_slot].Closure, ~16B saved)"
```

---

## Task 4: Remove `current_line` from CallFrame (derive from proto.lineinfo[pc])

**Goal:** Remove `current_line: i64` from CallFrame. Derive on demand from `proto.lineinfo[pc]`. Used only in cold paths (error reporting, debug hooks).

**Files:**
- Modify: `src/lua/vm.zig` — CallFrame struct (L1089), all `current_line` read/write sites

- [ ] **Step 1: Add `frameCurrentLine` helper**

```zig
fn frameCurrentLine(self: *Vm, frame: *const CallFrame) i64 {
    if (frame.proto) |p| {
        if (frame.pc < p.lineinfo.len) return @intCast(p.lineinfo[frame.pc]);
    }
    return -1;
}
```

- [ ] **Step 2: Replace all `frame.current_line` reads with `self.frameCurrentLine(frame)`**

Search for all read sites:
```bash
grep -n "\.current_line\b" src/lua/vm.zig | grep -v "fn \|//\|test\|doc\|=\s*0\|=\s*-1\|last_hook_line"
```

Replace each `frame.current_line` / `fr.current_line` read with `self.frameCurrentLine(frame)` / `self.frameCurrentLine(fr)`.

- [ ] **Step 3: Replace all `frame.current_line` writes with nothing (derive on demand)**

Remove all `fr.current_line = ...` assignments. The value is always derived from `proto.lineinfo[pc]`.

- [ ] **Step 4: Remove `current_line` field from CallFrame**

Remove `current_line: i64 = 0` from CallFrame struct. Remove `ef_slot.current_line = 0;` from pushBytecodeExecFrame.

- [ ] **Step 5: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
zig build test
```

Expected: All pass. ~8B saved.

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51n: remove current_line from CallFrame (derive from proto.lineinfo[pc], ~8B saved)"
```

---

## Task 5: Move `last_hook_line` to Thread

**Goal:** Move `last_hook_line: i64` from CallFrame to Thread. It is single-valued (only the active frame's line hook matters), matching PUC's `oldpc` which is on `lua_State`.

**Files:**
- Modify: `src/lua/vm.zig` — CallFrame struct (L1090), Thread struct, all `last_hook_line` sites

- [ ] **Step 1: Add `last_hook_line` to Thread**

Add to Thread struct:
```zig
last_hook_line: i64 = -1,
```

- [ ] **Step 2: Replace all `frame.last_hook_line` / `fr.last_hook_line` with Thread access**

Search for all sites:
```bash
grep -n "last_hook_line" src/lua/vm.zig | grep -v "fn \|//\|test\|doc"
```

Replace `fr.last_hook_line` with `self.activeBytecodeThread().last_hook_line` (or `th.last_hook_line` for parked coroutines).

- [ ] **Step 3: Remove `last_hook_line` from CallFrame**

Remove the field and its initialization in pushBytecodeExecFrame.

- [ ] **Step 4: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
zig build test
```

Expected: All pass. ~8B saved.

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51n: move last_hook_line to Thread (single-valued, PUC oldpc equivalent, ~8B saved)"
```

---

## Task 6: Move debug hook fields to Thread

**Goal:** Move `debug_hook_transfer`, `debug_hook_transfer_start`, `debug_hook_event_calllike`, `debug_hook_event_tailcall`, `debug_hook_event_is_count`, `debug_hook_allow_yield` from CallFrame to Thread. These are ONLY used by debug hook frames (CIST_HOOKED). Replace the O(n) `activeAsyncDebugHookFrame()` scan with a `hook_frame_index: ?usize` on Thread.

**Files:**
- Modify: `src/lua/vm.zig` — CallFrame struct (L1144-1149), Thread struct, all hook field sites, `activeAsyncDebugHookFrame()`

- [ ] **Step 1: Add hook fields to Thread**

Add to Thread struct:
```zig
hook_frame_index: ?usize = null,
hook_transfer: ?[]const Value = null,
hook_transfer_start: i64 = 1,
hook_event_calllike: bool = false,
hook_event_tailcall: bool = false,
hook_event_is_count: bool = false,
hook_allow_yield: bool = false,
```

- [ ] **Step 2: Replace `activeAsyncDebugHookFrame()` with `hook_frame_index` check**

Change `activeAsyncDebugHookFrame()` to:
```zig
fn activeAsyncDebugHookFrame(self: *Vm) ?*CallFrame {
    const th = self.activeBytecodeThread();
    const idx = th.hook_frame_index orelse return null;
    if (idx >= th.call_frames.len()) return null;
    const fr = th.call_frames.getPtr(idx);
    if (!fr.isDebugHook()) {
        th.hook_frame_index = null;
        return null;
    }
    return fr;
}
```

- [ ] **Step 3: Set `hook_frame_index` when pushing a debug hook frame**

In `tryPushBytecodeDebugHook` and other sites that set `CIST_HOOKED`, set:
```zig
self.activeBytecodeThread().hook_frame_index = exec_frames.len(); // about to be the new frame
```

In `popBytecodeExecFrame`, when popping a CIST_HOOKED frame, clear:
```zig
if (frame.isDebugHook()) {
    self.activeBytecodeThread().hook_frame_index = null;
}
```

- [ ] **Step 4: Replace all CallFrame hook field reads with Thread access**

Replace `fr.debug_hook_transfer` with `self.activeBytecodeThread().hook_transfer`, etc. Update all accessor functions (`activeDebugHookAllowsYield`, `activeDebugTransferValues`, etc.) to read from Thread.

- [ ] **Step 5: Replace all CallFrame hook field writes with Thread access**

Replace `ef_slot.debug_hook_transfer = ...` with `self.activeBytecodeThread().hook_transfer = ...`, etc. Update `pushBytecodeExecFrame` and `debugDispatchHookTransfer`.

- [ ] **Step 6: Remove hook fields from CallFrame**

Remove all 6 debug hook fields from CallFrame struct and their initializations in pushBytecodeExecFrame.

- [ ] **Step 7: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
zig build test
```

Expected: All pass. ~40B saved (6 fields: 24+8+1+1+1+1 = 36B + padding).

- [ ] **Step 8: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51n: move debug hook fields to Thread (hook-frame-only, ~40B saved)"
```

---

## Task 7: Move `debug_namewhat`/`debug_name` to Vm-level save/restore

**Goal:** Move `debug_namewhat` and `debug_name` from CallFrame to Vm-level fields with save/restore. These are set on continuation-entered frames and need to persist for the frame's lifetime.

**Files:**
- Modify: `src/lua/vm.zig` — CallFrame struct (L1142-1143), Vm struct, all `debug_namewhat`/`debug_name` sites

- [ ] **Step 1: Add `frame_namewhat`/`frame_name` to Vm**

Add to Vm struct (near `debug_namewhat_override`):
```zig
/// Continuation frame debug name (set on push, cleared on pop).
frame_namewhat: ?[]const u8 = null,
frame_name: ?[]const u8 = null,
```

- [ ] **Step 2: Set on continuation frame push, save/restore on pop**

In `tryPushBytecodeContinuationCall`, save the old values and set new ones:
```zig
const saved_nw = self.frame_namewhat;
const saved_n = self.frame_name;
self.frame_namewhat = debug_namewhat;
self.frame_name = debug_name;
```

In `popBytecodeExecFrame`, when popping a frame that had these set, restore:
```zig
// Actually, simpler: set on push, clear on pop. Since continuation frames
// are nested LIFO, save/restore works.
```

Actually, the simplest approach: store the saved values on the Thread (or use the frame's `continuation` handle to track). But since we're moving PendingCallSlot in Task 9, let's use a simpler approach: store `frame_namewhat`/`frame_name` on the **Thread** with save/restore in push/pop.

Add to Thread:
```zig
frame_namewhat: ?[]const u8 = null,
frame_name: ?[]const u8 = null,
```

In `pushBytecodeExecFrame`, if the frame is a continuation frame (has `debug_namewhat`/`debug_name` to set), save the old Thread values and set new ones. In `popBytecodeExecFrame`, restore.

But `pushBytecodeExecFrame` doesn't know about `debug_namewhat`/`debug_name` — they're set after the push in `tryPushBytecodeContinuationCall`. So:

In `tryPushBytecodeContinuationCall` (after pushBytecodeExecFrame):
```zig
const th = self.activeBytecodeThread();
// Save old values on the frame's continuation (or a Thread-level stack)
// For simplicity, use a Thread-level stack of saved values.
```

Actually, the cleanest approach: keep a per-Thread stack of `(?[]const u8, ?[]const u8)` pairs, pushed when a continuation frame is created and popped when it's destroyed. But that's complex.

Simpler: since continuation frames are rare and always have `pending_call` active on the parent, store `debug_namewhat`/`debug_name` in the `BytecodePendingCall` struct (which is being moved to per-Thread storage in Task 9). For now, store them on Thread with a simple save/restore:

In `tryPushBytecodeContinuationCall`:
```zig
const th = self.activeBytecodeThread();
th.frame_namewhat = debug_namewhat;
th.frame_name = debug_name;
```

In `popBytecodeExecFrame`, when popping a frame whose parent has `pending_call` active:
```zig
// Clear frame name when popping a continuation frame
const th = self.activeBytecodeThread();
th.frame_namewhat = null;
th.frame_name = null;
```

Wait, this doesn't handle nesting. Let me think again...

Actually, continuation frames DON'T nest in practice — a metamethod frame runs to completion before another is pushed. But to be safe, save/restore:

In `tryPushBytecodeContinuationCall`:
```zig
const th = self.activeBytecodeThread();
// Save previous values on the child frame's activation_id for later restore.
// Actually, save them on a Thread-level small stack.
```

OK, the simplest correct approach: add a small stack on Thread:
```zig
frame_name_stack: std.ArrayListUnmanaged(struct { nw: ?[]const u8, n: ?[]const u8 }) = .empty,
```

Push on continuation frame creation, pop on frame destruction. This is correct for nesting.

- [ ] **Step 3: Replace `fr.debug_namewhat`/`fr.debug_name` reads with Thread access**

In `debug.getinfo` (L19044, L20102), replace `fr.debug_namewhat` with `self.activeBytecodeThread().frame_namewhat` (or the top of the name stack).

- [ ] **Step 4: Remove `debug_namewhat`/`debug_name` from CallFrame**

Remove the fields and their initializations.

- [ ] **Step 5: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
zig build test
```

Expected: All pass. ~48B saved (two `?[]const u8` = 24B each).

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51n: move debug_namewhat/debug_name to Thread name stack (continuation-only, ~48B saved)"
```

---

## Task 8: Compact `?usize` pc fields to `u32` sentinels

**Goal:** Replace `?usize` pc fields (16B each) with `u32` (4B each) using `INVALID_PC = 0xFFFFFFFF` sentinel. Saves ~60B (5 fields × 12B).

**Files:**
- Modify: `src/lua/vm.zig` — CallFrame struct, all pc field sites

- [ ] **Step 1: Define `INVALID_PC` constant**

```zig
const INVALID_PC: u32 = std.math.maxInt(u32);
```

- [ ] **Step 2: Change field types and initializations**

Change in CallFrame:
```zig
// OLD:
resume_pc: usize = 0,
last_line_pc: ?usize = null,
skip_line_hook_pc: ?usize = null,
skip_call_hook_pc: ?usize = null,
resume_skip_count_pc: ?usize = null,

// NEW:
resume_pc: u32 = INVALID_PC,
last_line_pc: u32 = INVALID_PC,
skip_line_hook_pc: u32 = INVALID_PC,
skip_call_hook_pc: u32 = INVALID_PC,
resume_skip_count_pc: u32 = INVALID_PC,
```

- [ ] **Step 3: Update all read sites**

Replace `?usize` checks:
- `if (fr.last_line_pc) |pc|` → `if (fr.last_line_pc != INVALID_PC) { const pc = fr.last_line_pc; ... }`
- `fr.resume_pc` (when used as usize) → `@as(usize, fr.resume_pc)` (when != INVALID_PC)

- [ ] **Step 4: Update all write sites**

Replace:
- `fr.last_line_pc = some_pc;` → `fr.last_line_pc = @intCast(some_pc);`
- `fr.last_line_pc = null;` → `fr.last_line_pc = INVALID_PC;`
- `fr.last_line_pc = fr.pc;` → `fr.last_line_pc = @intCast(fr.pc);`

- [ ] **Step 5: Update pushBytecodeExecFrame initializations**

```zig
ef_slot.resume_pc = INVALID_PC;
ef_slot.last_line_pc = INVALID_PC;
ef_slot.skip_line_hook_pc = INVALID_PC;
ef_slot.skip_call_hook_pc = INVALID_PC;
ef_slot.resume_skip_count_pc = INVALID_PC;
```

- [ ] **Step 6: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
zig build test
```

Expected: All pass. ~60B saved.

- [ ] **Step 7: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51n: compact ?usize pc fields to u32 sentinels (INVALID_PC, ~60B saved)"
```

---

## Task 9: Move `PendingCallSlot` to per-Thread sparse storage

**Goal:** Replace inline `pending_call: PendingCallSlot` (~64B) with a `continuation: u32` handle (4B). Value 0 = no continuation. Non-zero = index+1 into `Thread.continuations` array.

**Files:**
- Modify: `src/lua/vm.zig` — CallFrame struct, Thread struct, all `pending_call` sites

- [ ] **Step 1: Add continuation storage to Thread**

Add to Thread:
```zig
/// Sparse storage for BytecodePendingCall payloads.
/// Index 0 is unused (continuation handle 0 = no continuation).
/// Handles are `index + 1` to avoid the 0-is-none ambiguity.
continuations: std.ArrayListUnmanaged(?BytecodePendingCall) = .empty,
continuation_free_list: std.ArrayListUnmanaged(u32) = .empty,
```

- [ ] **Step 2: Add continuation handle accessors**

```zig
fn getContinuation(self: *Thread, handle: u32) ?*BytecodePendingCall {
    if (handle == 0) return null;
    const idx = handle - 1;
    if (idx >= self.continuations.items.len) return null;
    const slot = &self.continuations.items[idx];
    if (slot.*) |*payload| return payload;
    return null;
}

fn setContinuation(self: *Thread, payload: BytecodePendingCall) !u32 {
    if (self.continuation_free_list.pop()) |idx| {
        self.continuations.items[idx] = payload;
        return idx + 1;
    }
    const idx: u32 = @intCast(self.continuations.items.len);
    try self.continuations.append(self.vm.alloc, payload);
    return idx + 1;
}

fn clearContinuation(self: *Thread, handle: u32) void {
    if (handle == 0) return;
    const idx = handle - 1;
    if (idx < self.continuations.items.len) {
        self.continuations.items[idx] = null;
        self.continuation_free_list.append(self.vm.alloc, idx) catch {};
    }
}
```

- [ ] **Step 3: Replace `pending_call` field with `continuation: u32`**

In CallFrame, replace:
```zig
// OLD:
pending_call: PendingCallSlot = .{},
// NEW:
continuation: u32 = 0,
```

- [ ] **Step 4: Replace all `pending_call` access patterns**

Replace all `frame.pending_call.get()` with `th.getContinuation(frame.continuation)`.
Replace all `frame.pending_call.getPtr()` with `th.getContinuation(frame.continuation)`.
Replace all `frame.pending_call.set(payload)` with `frame.continuation = try th.setContinuation(payload)`.
Replace all `frame.pending_call.clear()` with `th.clearContinuation(frame.continuation); frame.continuation = 0;`.
Replace all `frame.pending_call.active` with `frame.continuation != 0`.

- [ ] **Step 5: Update `popBytecodeExecFrame` to clear continuation**

```zig
if (frame.continuation != 0) {
    if (th.getContinuation(frame.continuation)) |pending| {
        self.cancelBytecodePendingCall(pending, frame);
    }
    th.clearContinuation(frame.continuation);
    frame.continuation = 0;
}
```

- [ ] **Step 6: Update GC marking to mark continuation payloads**

In GC marking, replace `frame.pending_call.get()` with `th.getContinuation(frame.continuation)`.

- [ ] **Step 7: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
zig build test
python3 tools/perf_compare.py
```

Expected: All pass. ~60B saved (64B → 4B). Perf neutral or slight improvement (no 64B memset on frame push).

- [ ] **Step 8: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51n: move PendingCallSlot to per-Thread sparse storage (u32 handle, ~60B saved)"
```

---

## Task 10: Compact `activation_id` to `u32` and final size check

**Goal:** Change `activation_id` from `usize` (8B) to `u32` (4B). Verify final CallFrame size <100B.

**Files:**
- Modify: `src/lua/vm.zig` — CallFrame struct, all `activation_id` sites

- [ ] **Step 1: Change `activation_id` type**

In CallFrame:
```zig
// OLD:
activation_id: usize = 0,
// NEW:
activation_id: u32 = 0,
```

- [ ] **Step 2: Update all `activation_id` sites**

Update `bytecode_activation_counter` on Thread to `u32`. Update all comparisons and assignments.

- [ ] **Step 3: Build and verify CallFrame size**

Add a temporary compile-time check:
```zig
comptime {
    if (@sizeOf(CallFrame) >= 100) {
        @compileError("CallFrame too large: " ++ @import("std").fmt.comptimePrint("{}", .{@sizeOf(CallFrame)}));
    }
}
```

Or just print the size:
```bash
# Add a temporary print and check
```

- [ ] **Step 4: Run full regression suite**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
zig build test
python3 tools/perf_compare.py
```

Expected: All pass. CallFrame <100B.

- [ ] **Step 5: Update STATUS.md**

Update STATUS.md with P15.51n completion summary, CallFrame size, and Task 9/10 status.

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig STATUS.md
git commit -m "P15.51n: compact activation_id to u32, CallFrame <100B achieved"
```

---

## Post-Implementation Verification

After all 10 tasks:

- [x] **Final regression suite:**
```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
zig build test
python3 tools/perf_compare.py
```

- [x] **Verify CallFrame size <100B** — CallFrame = **96B**

- [x] **Update STATUS.md** with P15.51n completion summary.

- [ ] **Update baseline if perf improved significantly:**
```bash
python3 tools/perf_compare.py --update-baseline
```

## Post-Implementation: Deviations from Plan

The original plan described per-Thread sparse storage for `PendingCallSlot`.
The actual implementation uses **Vm-level** sparse storage instead. Key
deviations and follow-up fixes:

### 1. Vm-level (not per-Thread) pending_calls storage
**Reason:** During coroutine resume/yield, `self.activeBytecodeThread()` returns
the wrong thread (the resumed coroutine, not the resumer), making per-Thread
storage unsafe for continuation access.
**Implementation:** `pending_calls: std.ArrayListUnmanaged(PendingCallSlot)` on
`Vm`, with `pending_free_head: u32` free-list. Each `CallFrame.pending_call_index`
(u32) is the handle. Ownership is per-frame, not per-Thread.

### 2. Debug name stored in BytecodePendingCall (not Thread array)
**Reason:** Original plan used `debug_name_entries[32]` array on Thread with
`u4` counter — overflow at 32 entries, hidden depth limit.
**Implementation:** `debug_namewhat`/`debug_name` stored directly in
`BytecodePendingCall` (parent frame's continuation). `setDebugName(parent_frame, ...)`
writes to parent's pending call; `getDebugName(parent_frame)` reads from it.

### 3. frame_cap compacted to u32
**Reason:** `frame_cap` was `usize` (8B). Changed to `u32` (4B) in `CallFrame`,
`BytecodeDispatchCtx`, and `bcGrowFrame` signature. The initial value is
`proto.maxstacksize + EXTRA_MARGIN` (u8 + 5, up to 260), but `bcGrowFrame`
can dynamically increase `frame_cap` for multret and vararg expansion.
The VM's bytecode stack is bounded by `MAXSTACK` (1 000 000) + `ERRORSTACKSIZE`
margin (200), so `frame_cap` never exceeds ~1 000 200 — well within `u32` range.
This brought CallFrame from 104B to **96B**.

### 4. OOM semantics fixed
**Reason:** `allocPendingCall` used `pending_calls.append` which could panic on
OOM. Changed to return `error{OutOfMemory}!u32`. `setPendingCall` returns
`error{OutOfMemory}!void`. All 16 call sites updated with `try`. No partial
state on failure — `allocPendingCall` fails before setting
`frame.pending_call_index`.

### 5. 256 cleanup limit removed
**Reason:** `freeThreadBytecodeFrames` used `var indices: [256]u32 = undefined`
— fixed limit on pending calls per thread. Replaced with direct iteration over
`call_frames`, processing each frame's pending call one at a time.

### 6. Pointer-lifetime audit
**Reason:** `*BytecodePendingCall` pointers point into `pending_calls.items`
(reallocatable ArrayList). 3 sites held pointers across reentrant operations
(`clearPendingCall` + `tryPushBytecodeDebugHook` + `dispatchBytecodeHookWithCallee`)
that can realloc `pending_calls`:
1. `completeBytecodePendingExternalResults`
2. `completeBytecodeCoroutineResult`
3. `completeBytecodeProtectedResult`
**Fix:** Snapshot `pending.callee` into a local before the reentrant region.

### 7. Vm-level ownership documented
Added comprehensive documentation to `pending_calls` field covering design
rationale, ownership model, and 5 invariants.

## Invariants (all tasks)

- `frame_loop` preserved — no host recursion
- PUC-faithful: result contract in callee frame (`callstatus` + `func_slot`)
- Cold paths still work: debug hooks, coroutines, protected calls, TBC
- No test regressions: matrix 30/31, smoke 49/49, unit 146/146
- No match-by-name / line-range / special-case hacks (AGENTS.md)
- Each task: separate commit + regression tests
- All `CallFrame*` pointers must be reacquired after reentrant operations
- Ordinary Lua CALL/RETURN must not touch continuation storage
