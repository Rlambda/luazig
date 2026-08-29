# P15.40b-Full — Merge Dual-Array Pattern Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the dual-array pattern (`Thread.call_frames` for bytecode + `Vm.call_frames` for runtime copies) by removing the runtime frame copy push from `pushBytecodeExecFrame`, making bytecode frames exist ONLY in `Thread.call_frames`. This eliminates one `addOne` call, ~25 redundant field writes, and the `runtime_frame_index` indirection per push.

**Architecture:** Currently `pushBytecodeExecFrame` pushes ONE CallFrame to `exec_frames` (Thread.call_frames, bytecode-specific fields) AND ONE CallFrame to `self.call_frames` (Vm.call_frames, runtime fields like `regs`/`boxed`/`callee`). These are linked by `runtime_frame_index`. The merge eliminates the second push — the single CallFrame in `Thread.call_frames` holds ALL fields. GC, `ensureBcStackCap`, `bcGrowFrame`, and debug code that previously walked `Vm.call_frames` for bytecode frames must be updated to walk `Thread.call_frames` instead.

**Tech Stack:** Zig 0.16.0, existing ArrayListUnmanaged infrastructure.

**Spec:** `docs/superpowers/specs/2026-07-20-callinfo-parity-design.md` (Phase B)

**Prerequisite:** P15.40b Task 1 (CallFrame struct defined, field renames done, `runtime_frame_index` retained). Commit `2fb2c31`.

---

## Root Cause Analysis (previous failed attempt)

The previous attempt failed because ALL changes were made at once (eliminate dual push + update all scanning paths), making it impossible to isolate which change caused the GC regression (coroutines being collected).

The key insight for this plan: **add the new scanning paths FIRST (while keeping the old ones), THEN remove the old push**. This way, each step is a no-op or additive change — if a step breaks, the cause is isolated.

### Why the old code works with stale `pc`

Both old and new code have the same stale `pc` issue: `pushBytecodeExecFrame` sets `pc = 0`, and `collectgarbage("collect")` doesn't go through the safepoint. The GC uses `live_reg_top[0]` (live registers at function entry). This works because:
- For the main chunk (vararg), `live_reg_top[0]` includes all parameters and pre-assigned locals
- The `regs` slice is always valid (updated by `ensureBcStackCap` on realloc)
- The `live_reg_top` fallback (`frame.regs.len`) scans the full window if the table is empty

The regression in the previous attempt was NOT caused by stale `pc` — it was caused by a bug in one of the scanning path updates. The incremental approach will isolate which one.

---

## File Structure

- **Modify:** `src/lua/vm.zig` — all changes in this file
- **No new files.**

## Current state (before this plan)

- `CallFrame` struct defined (merged `BytecodeExecFrame` + `RuntimeFrame`)
- `Frame = CallFrame` type alias
- Field renames done: `call_frames`, `parked_call_frames`, `base`, `reg_top`
- `runtime_frame_index` field retained on `CallFrame`
- `pushBytecodeExecFrame` does TWO `addOne` calls (one to `exec_frames`, one to `self.call_frames`)
- `popBytecodeExecFrame` pops from BOTH arrays
- GC walks `self.call_frames` (Vm) for bytecode frames (finds runtime copies)
- `ensureBcStackCap` walks `self.call_frames` (Vm) for bytecode frames
- `bcGrowFrame` updates `self.call_frames` (Vm) for the topmost frame
- Debug (`debugResolveFrameIndex`, `snapshotThreadTraceFrames`, `currentVisibleFrameDepth`) walks `self.call_frames` (Vm) only

## Target state (after this plan)

- `pushBytecodeExecFrame` does ONE `addOne` to `exec_frames` (Thread.call_frames)
- `popBytecodeExecFrame` pops from `exec_frames` only
- GC walks `Thread.call_frames` for bytecode frames + `Vm.call_frames` for IR frames
- `ensureBcStackCap` walks `Thread.call_frames` for bytecode frames
- `bcGrowFrame` updates `Thread.call_frames` for the topmost frame
- Debug walks both arrays
- `runtime_frame_index` field removed from `CallFrame`

---

### Task 1: Add GC scanning of Thread.call_frames (additive, no-op)

**Files:**
- Modify: `src/lua/vm.zig` — `gcMarkMutableRoots` (~line 14108)

This step adds a NEW scanning loop for `Thread.call_frames` in the GC, WITHOUT removing the existing `self.call_frames` loop. Both loops will scan bytecode frames (redundant but safe — marking an already-marked object is a no-op).

- [ ] **Step 1: Add Thread.call_frames scanning loop in gcMarkMutableRoots**

Find `gcMarkMutableRoots` (vm.zig:~14108). After the existing `for (self.call_frames.items) |frame|` loop ends (after `if (frame.env_override) |environment| try self.gcMarkValue(environment);` followed by `}`), add a new loop:

```zig
        // P15.40b-full: Also scan bytecode frames in Thread.call_frames.
        // Currently redundant (runtime copies are still in self.call_frames),
        // but will become necessary when the runtime copy push is eliminated.
        const active_th = self.activeBytecodeThread();
        for (active_th.call_frames.items) |frame| {
            if (frame.proto) |proto| {
                try self.gcMarkBytecodeProto(proto);
                const live_top: usize = if (frame.pc < proto.live_reg_top.len)
                    @min(proto.live_reg_top[frame.pc], frame.regs.len)
                else
                    frame.regs.len;
                for (frame.regs[0..live_top]) |value| try self.gcMarkValue(value);
            }
            try self.gcMarkValue(frame.callee);
            for (frame.varargs) |value| try self.gcMarkValue(value);
            for (frame.upvalues) |cell| {
                if (!self.gc_marked_cells.contains(cell)) try self.gc_marked_cells.put(self.alloc, cell, {});
                try self.gcMarkValue(cell.get(self.bc_stack));
            }
            for (frame.boxed) |maybe_cell| {
                if (maybe_cell) |cell| {
                    if (!self.gc_marked_cells.contains(cell)) try self.gc_marked_cells.put(self.alloc, cell, {});
                    try self.gcMarkValue(cell.get(self.bc_stack));
                }
            }
            if (frame.env_override) |environment| try self.gcMarkValue(environment);
        }
```

- [ ] **Step 2: Add Thread.call_frames scanning in gcClearDeadFrameRegisters**

Find `gcClearDeadFrameRegisters` (vm.zig:~14354). After the existing `for (self.call_frames.items) |*frame|` loop, add:

```zig
        // P15.40b-full: Also clear dead registers in Thread.call_frames.
        const th = self.activeBytecodeThread();
        for (th.call_frames.items) |*frame| {
            if (frame.proto) |proto| {
                const live_top: usize = if (frame.pc < proto.live_reg_top.len)
                    @min(proto.live_reg_top[frame.pc], frame.regs.len)
                else
                    frame.regs.len;
                for (frame.regs[live_top..]) |*slot| {
                    switch (slot.*) {
                        .Table, .Closure, .Thread => slot.* = .Nil,
                        else => {},
                    }
                }
            }
        }
```

- [ ] **Step 3: Build and verify**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: PASS (no errors).

- [ ] **Step 4: Run smoke tests**

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done`
Expected: 45/45 PASS (no regressions — the new loops are redundant).

- [ ] **Step 5: Run matrix**

Run: `python3 tools/testes_matrix.py --timeout 120 2>&1 | grep -E "both_fail|zig_fail"`
Expected: 3 pre-existing fails (attrib, big, files). No new regressions.

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.40b-full: add GC scanning of Thread.call_frames (additive, no-op)"
```

---

### Task 2: Update ensureBcStackCap to walk Thread.call_frames (additive, no-op)

**Files:**
- Modify: `src/lua/vm.zig` — `ensureBcStackCap` (~line 2165)

Currently `ensureBcStackCap` walks `self.call_frames` (Vm) to fix up `regs`/`boxed` slices after `bc_stack` realloc. Add a SECOND loop for `Thread.call_frames`.

- [ ] **Step 1: Add Thread.call_frames walk in ensureBcStackCap**

Find `ensureBcStackCap` (vm.zig:~2165). After the existing `for (self.call_frames.items) |*fr|` loop, add:

```zig
        // P15.40b-full: Also fix up bytecode frames in Thread.call_frames.
        // Currently redundant (runtime copies in self.call_frames are also fixed),
        // but will become necessary when the runtime copy push is eliminated.
        const th = self.activeBytecodeThread();
        for (th.call_frames.items) |*fr| {
            if (fr.proto != null) {
                const b = fr.base;
                const cap = fr.regs.len;
                const safe_cap = @min(cap, self.bc_stack.len - b);
                fr.regs = self.bc_stack[b .. b + safe_cap];
                const safe_boxed = @min(cap, self.bc_boxed.len - b);
                fr.boxed = self.bc_boxed[b .. b + safe_boxed];
            }
        }
```

- [ ] **Step 2: Build and verify**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 3: Run smoke tests**

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done`
Expected: 45/45 PASS.

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.40b-full: add ensureBcStackCap walk of Thread.call_frames (additive, no-op)"
```

---

### Task 3: Update bcGrowFrame to update Thread.call_frames (additive, no-op)

**Files:**
- Modify: `src/lua/vm.zig` — `bcGrowFrame` (~line 2203)

Currently `bcGrowFrame` updates `self.call_frames.items[len-1]` with the new `regs`/`boxed`. Add a SECOND update for `Thread.call_frames`.

- [ ] **Step 1: Add Thread.call_frames update in bcGrowFrame**

Find `bcGrowFrame` (vm.zig:~2234). After the existing `if (self.call_frames.items.len > 0)` block that updates `fr.regs`/`fr.boxed`, add:

```zig
        // P15.40b-full: Also update the bytecode frame in Thread.call_frames.
        const th = self.activeBytecodeThread();
        if (th.call_frames.items.len > 0) {
            const fr = &th.call_frames.items[th.call_frames.items.len - 1];
            fr.regs = regs.*;
            fr.boxed = boxed.*;
            fr.frame_cap = frame_cap.*;
        }
```

- [ ] **Step 2: Build and verify**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 3: Run smoke tests**

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done`
Expected: 45/45 PASS.

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.40b-full: add bcGrowFrame update of Thread.call_frames (additive, no-op)"
```

---

### Task 4: Update debug functions to walk both arrays (additive, no-op)

**Files:**
- Modify: `src/lua/vm.zig` — `debugResolveFrameIndex` (~line 16896), `currentVisibleFrameDepth` (~line 13072), `snapshotThreadTraceFrames` (~line 13080), `threadCurrentParkedRuntimeFrame` (~line 18139)

These functions currently walk `self.call_frames` (Vm) only. Update them to ALSO walk `Thread.call_frames`. Since bytecode frames are currently in BOTH arrays (runtime copy in Vm, bytecode frame in Thread), walking both is redundant but safe.

- [ ] **Step 1: Update debugResolveFrameIndex to return *CallFrame**

Find `debugResolveFrameIndex` (vm.zig:~16896). Change the return type from `?usize` to `?*CallFrame` and walk both arrays:

```zig
    fn debugResolveFrameIndex(self: *Vm, level: usize) ?*CallFrame {
        // P15.40b-full: Walk Thread.call_frames (bytecode, top) then Vm.call_frames
        // (IR, bottom). Bytecode frames are the innermost (most recent).
        var visible: usize = 0;
        const th = self.activeBytecodeThread();
        var i = th.call_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (th.call_frames.items[i].hide_from_debug) continue;
            visible += 1;
            if (visible == level) return &th.call_frames.items[i];
        }
        // Fall through to IR frames in Vm.call_frames.
        i = self.call_frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.call_frames.items[i].hide_from_debug) continue;
            visible += 1;
            if (visible == level) return &self.call_frames.items[i];
        }
        return null;
    }
```

- [ ] **Step 2: Update all debugResolveFrameIndex callers**

Find all callers of `debugResolveFrameIndex` (search for `debugResolveFrameIndex`). Each caller currently does:
```zig
const fr_idx = self.debugResolveFrameIndex(lv) orelse ...;
const fr = &self.call_frames.items[fr_idx];
```

Change each to:
```zig
const fr = self.debugResolveFrameIndex(lv) orelse ...;
```

Remove the `const fr = &self.call_frames.items[fr_idx];` line.

Also find all callers of `debugInferNameFromCaller` that pass `fr_idx`. Change `debugInferNameFromCaller` to take `?*const CallFrame` instead of `usize`:

```zig
    fn debugInferNameFromCaller(self: *Vm, caller_opt: ?*const CallFrame, target: Frame) DebugName {
        const caller = caller_opt orelse return .{};
        // ... rest unchanged, use `caller.*` instead of `caller` ...
    }
```

Update callers to pass `self.debugResolveFrameIndex(lv + 1)` (the caller is level+1).

- [ ] **Step 3: Update currentVisibleFrameDepth**

Find `currentVisibleFrameDepth` (vm.zig:~13072). Add Thread.call_frames walk:

```zig
    fn currentVisibleFrameDepth(self: *Vm) usize {
        var n: usize = 0;
        const th = self.activeBytecodeThread();
        for (th.call_frames.items) |fr| {
            if (!fr.hide_from_debug) n += 1;
        }
        for (self.call_frames.items) |fr| {
            if (!fr.hide_from_debug) n += 1;
        }
        return n;
    }
```

- [ ] **Step 4: Update snapshotThreadTraceFrames**

Find `snapshotThreadTraceFrames` (vm.zig:~13080). Add Thread.call_frames walk. Walk bytecode frames (Thread.call_frames) first (most recent), then IR frames (Vm.call_frames[start..]):

```zig
    fn snapshotThreadTraceFrames(self: *Vm, th: *Thread) DispatchError!void {
        if (th.trace_frame_names) |names| {
            self.alloc.free(names);
            th.trace_frame_names = null;
        }
        const start = @min(th.resume_base_depth, self.call_frames.items.len);
        var depth: usize = 0;
        for (th.call_frames.items) |fr| {
            if (!fr.hide_from_debug) depth += 1;
        }
        for (self.call_frames.items[start..]) |fr| {
            if (!fr.hide_from_debug) depth += 1;
        }
        if (depth == 0) {
            th.trace_stack_depth = 0;
            return;
        }
        const out = try self.alloc.alloc(?[]const u8, depth);
        var oi: usize = 0;
        // Bytecode frames (top, most recent first).
        var i = th.call_frames.items.len;
        while (i > 0) {
            i -= 1;
            const fr = th.call_frames.items[i];
            if (fr.hide_from_debug) continue;
            if (fr.proto != null) {
                out[oi] = self.debugNameFromCallee(fr.callee);
            } else {
                const nm = fr.func.name;
                out[oi] = if (nm.len != 0 and !std.mem.eql(u8, nm, "<anon>")) nm else null;
            }
            oi += 1;
        }
        // IR frames (bottom, most recent first).
        i = self.call_frames.items.len;
        while (i > start) {
            i -= 1;
            const fr = self.call_frames.items[i];
            if (fr.hide_from_debug) continue;
            if (fr.proto != null) {
                out[oi] = self.debugNameFromCallee(fr.callee);
            } else {
                const nm = fr.func.name;
                out[oi] = if (nm.len != 0 and !std.mem.eql(u8, nm, "<anon>")) nm else null;
            }
            oi += 1;
        }
        th.trace_stack_depth = oi;
        th.trace_frame_names = out;
    }
```

- [ ] **Step 5: Update threadCurrentParkedRuntimeFrame**

Find `threadCurrentParkedRuntimeFrame` (vm.zig:~18139). Change to check `th.call_frames` instead of `th.parked_call_frames`:

```zig
    fn threadCurrentParkedRuntimeFrame(th: *Thread) ?*CallFrame {
        // P15.40b-full: Bytecode frames are in th.call_frames.
        if (!th.bytecode_inplace_suspended or th.call_frames.items.len == 0) return null;
        return &th.call_frames.items[th.call_frames.items.len - 1];
    }
```

- [ ] **Step 6: Update sethook seeding (line ~19192)**

Find the `if (hook_state.has_line)` block (~line 19192) that walks `self.call_frames` to update `last_hook_line`. Add Thread.call_frames walk:

```zig
            if (target_thread == null and (self.call_frames.items.len != 0 or self.activeBytecodeThread().call_frames.items.len != 0)) {
                for (self.call_frames.items) |*fr| {
                    fr.last_hook_line = fr.current_line;
                }
                const th = self.activeBytecodeThread();
                for (th.call_frames.items) |*fr| {
                    fr.last_hook_line = fr.current_line;
                }
            }
```

- [ ] **Step 7: Build and verify**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 8: Run smoke tests**

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done`
Expected: 45/45 PASS.

- [ ] **Step 9: Run matrix**

Run: `python3 tools/testes_matrix.py --timeout 120 2>&1 | grep -E "both_fail|zig_fail"`
Expected: 3 pre-existing fails. No new regressions.

- [ ] **Step 10: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.40b-full: update debug functions to walk both arrays (additive, no-op)"
```

---

### Task 5: Eliminate runtime frame copy push (THE KEY CHANGE)

**Files:**
- Modify: `src/lua/vm.zig` — `pushBytecodeExecFrame` (~line 6840), `popBytecodeExecFrame` (~line 6927)

This is the core change: `pushBytecodeExecFrame` does ONE `addOne` to `exec_frames` (Thread.call_frames) with ALL fields set. No more second `addOne` to `self.call_frames` (Vm). `popBytecodeExecFrame` pops from `exec_frames` only.

**Why this is safe now:** Tasks 1-4 added scanning paths for `Thread.call_frames` in GC, `ensureBcStackCap`, `bcGrowFrame`, and debug. These paths are ALREADY walking `Thread.call_frames`. Removing the runtime copy from `self.call_frames` means bytecode frames are ONLY in `Thread.call_frames` — but all scanning paths already look there.

- [ ] **Step 1: Rewrite pushBytecodeExecFrame body**

Find `pushBytecodeExecFrame` (vm.zig:~6775). Replace the body from `const frame_callee` onwards. The current code does:
1. `const runtime_frame_index = self.call_frames.items.len;`
2. `const rf_slot = try self.call_frames.addOne(self.alloc);` — runtime frame copy
3. Write ~25 runtime fields to `rf_slot`
4. `const ef_slot = try exec_frames.addOne(self.alloc);` — bytecode frame
5. Write ~20 bytecode fields to `ef_slot`
6. `ef_slot.runtime_frame_index = runtime_frame_index;`

Replace with a SINGLE `addOne` to `exec_frames` and unified field writes:

```zig
        const frame_callee: Value = if (callee_cl) |cl| .{ .Closure = cl } else .Nil;
        const activation_owner = self.activeBytecodeThread();
        activation_owner.bytecode_activation_counter +%= 1;
        if (activation_owner.bytecode_activation_counter == 0) activation_owner.bytecode_activation_counter = 1;

        // P15.40b-full: Single addOne + unified field writes (was two addOne + ~50 writes).
        // The CallFrame in Thread.call_frames holds ALL fields — no runtime copy
        // in Vm.call_frames needed. GC, ensureBcStackCap, bcGrowFrame, and debug
        // all walk Thread.call_frames for bytecode frames (added in Tasks 1-4).
        const ef_slot = try exec_frames.addOne(self.alloc);
        errdefer exec_frames.items.len -= 1;

        // Common fields
        ef_slot.func = &bc_dummy_func_global;
        ef_slot.proto = proto;
        ef_slot.callee = frame_callee;
        ef_slot.pc = 0;
        ef_slot.current_line = 0;
        ef_slot.last_hook_line = -1;
        ef_slot.is_tailcall = false;
        ef_slot.varargs = frame_varargs;
        ef_slot.upvalues = upvalues;
        ef_slot.nvarstack = @intCast(nparams);

        // Bytecode-specific
        ef_slot.activation_id = activation_owner.bytecode_activation_counter;
        ef_slot.base = base;
        ef_slot.frame_cap = frame_cap;
        ef_slot.resume_pc = 0;
        ef_slot.reg_top = @intCast(nparams);
        ef_slot.last_line_pc = null;
        ef_slot.skip_line_hook_pc = null;
        ef_slot.resumed_direct_yield = false;
        ef_slot.tbc_mark = tbc_mark;
        ef_slot.pending_call.clear();
        ef_slot.skip_call_hook_pc = null;

        // Runtime fields (used by GC, ensureBcStackCap, debug)
        ef_slot.regs = regs;
        ef_slot.locals = &.{};
        ef_slot.boxed = boxed;
        ef_slot.local_active = &.{};

        // Debug fields (must set explicitly — defaults don't re-apply on reuse)
        ef_slot.env_override = null;
        ef_slot.frame_id = 0;
        ef_slot.used_closing_line_hook = false;
        ef_slot.resume_skip_count_pc = null;
        ef_slot.hide_from_debug = false;
        ef_slot.debug_namewhat = null;
        ef_slot.debug_name = null;
        ef_slot.is_debug_hook = false;
        ef_slot.debug_hook_transfer = null;
        ef_slot.debug_hook_transfer_start = 1;
        ef_slot.debug_hook_event_calllike = false;
        ef_slot.debug_hook_event_tailcall = false;
        ef_slot.debug_hook_event_is_count = false;
        ef_slot.debug_hook_allow_yield = false;
```

- [ ] **Step 2: Rewrite popBytecodeExecFrame body**

Find `popBytecodeExecFrame` (vm.zig:~6927). Replace the body to pop from `exec_frames` only:

```zig
    fn popBytecodeExecFrame(
        self: *Vm,
        exec_frames: *std.ArrayListUnmanaged(CallFrame),
    ) void {
        std.debug.assert(exec_frames.items.len != 0);
        const idx = exec_frames.items.len - 1;
        const frame = &exec_frames.items[idx];
        // P15.40b-full: Single pop — the merged CallFrame holds all fields.
        if (frame.pending_call.getPtr()) |pending| {
            self.cancelBytecodePendingCall(pending, frame);
        }
        // P15.38f: Clear in_debug_hook if this was a debug hook frame.
        if (frame.is_debug_hook) {
            self.activeHookState().in_debug_hook = false;
        }
        // P15.35: Skip free for non-vararg frames (static empty_varargs slice).
        if (frame.varargs.ptr != empty_varargs.ptr) self.alloc.free(frame.varargs);
        self.bc_tbc_regs.items.len = frame.tbc_mark;
        self.bc_stack_top = frame.base;
        exec_frames.items.len = idx;
    }
```

- [ ] **Step 3: Update cancelBytecodePendingCall signature**

Find `cancelBytecodePendingCall` (vm.zig:~4569). Change `owner_runtime: ?*RuntimeFrame` to `owner_runtime: ?*CallFrame`:

```zig
    fn cancelBytecodePendingCall(
        self: *Vm,
        pending: *BytecodePendingCall,
        owner_runtime: ?*CallFrame,
    ) void {
```

- [ ] **Step 4: Update runtime_frame_index references in dispatch loop**

Find all remaining `runtime_frame_index` references (search: `rg -n "runtime_frame_index" src/lua/vm.zig`). For each:

**Pattern 1:** `const parent_runtime_index = exec_frames.items[parent_index].runtime_frame_index;`
→ Change to: `const parent_runtime_index = parent_index;` (the frame IS in exec_frames at parent_index)

**Pattern 2:** `self.call_frames.items[parent_runtime_index].field`
→ Change to: `exec_frames.items[parent_runtime_index].field`

**Pattern 3:** `const runtime = &self.call_frames.items[runtime_frame_index];`
→ Change to: `const runtime = &exec_frames.items[frame_index];` (use the frame's own index)

**Pattern 4:** `self.call_frames.items[runtime_frame_index].resume_skip_count_pc = pc;`
→ Change to: `exec_frames.items[frame_index].resume_skip_count_pc = pc;`

**Pattern 5:** In `parkBytecodeIrHookYield`, change the `runtime_frame_index` parameter to take `exec_frames` and `frame_index`:

```zig
    fn parkBytecodeIrHookYield(
        self: *Vm,
        exec_frames: *std.ArrayListUnmanaged(CallFrame),
        frame_index: usize,
        pc: usize,
        skip_count: bool,
        yielded_in_place: *bool,
    ) void {
        const th = self.current_thread orelse return;
        th.bytecode_inplace_suspended = true;
        yielded_in_place.* = true;
        if (skip_count) {
            exec_frames.items[frame_index].resume_skip_count_pc = pc;
        } else {
            self.activeHookState().skip_bc_line_once = true;
        }
    }
```

Update all callers of `parkBytecodeIrHookYield` to pass `exec_frames, frame_index` instead of `runtime_frame_index`.

**Pattern 6:** In the dispatch loop defer block (~line 7340), remove the `runtime` sync (the `saved` pointer already writes to the unified frame):

Remove:
```zig
                    const runtime = &self.call_frames.items[saved.runtime_frame_index];
                    runtime.proto = cur_proto;
                    runtime.upvalues = cur_upvalues;
                    runtime.regs = self.bc_stack[base .. base + frame_cap];
                    runtime.boxed = self.bc_boxed[base .. base + frame_cap];
                    runtime.varargs = varargs;
                    runtime.pc = pc;
                    runtime.reg_top = reg_top;
                    runtime.nvarstack = nvarstack;
                    runtime.current_line = frame_current_line;
                    runtime.last_hook_line = frame_last_hook_line;
                    runtime.is_tailcall = frame_is_tailcall;
```

Add to the `saved` block:
```zig
                    saved.regs = self.bc_stack[base .. base + frame_cap];
                    saved.boxed = self.bc_boxed[base .. base + frame_cap];
```

**Pattern 7:** In the safepoint (~line 7618), add `regs`/`boxed` sync:

```zig
                                var fr = &exec_frames.items[frame_index];
                                fr.pc = pc;
                                fr.reg_top = reg_top;
                                fr.nvarstack = nvarstack;
                                fr.regs = self.bc_stack[base .. base + frame_cap];
                                fr.boxed = self.bc_boxed[base .. base + frame_cap];
```

**Pattern 8:** In the dispatch loop slow path (~line 7401), change `self.call_frames.items[runtime_frame_index]` to `exec_frames.items[frame_index]`:

```zig
                    var fr = &exec_frames.items[frame_index];
```

**Pattern 9:** In `bcGrowFrame` (~line 2234), the Thread.call_frames update was added in Task 3. Now remove the OLD `self.call_frames` update (it's no longer needed since bytecode frames aren't there):

Remove:
```zig
        if (self.call_frames.items.len > 0) {
            const fr = &self.call_frames.items[self.call_frames.items.len - 1];
            fr.regs = regs.*;
            fr.boxed = boxed.*;
        }
```

(The Thread.call_frames update from Task 3 remains.)

**Pattern 10:** In the OP_CALL handler (~line 9516), change `self.call_frames.items[len-1]` to `exec_frames.items[len-1]`:

```zig
                                const fr2 = &exec_frames.items[exec_frames.items.len - 1];
```

**Pattern 11:** In the debug hook setup code (~line 4496, 4694, 4822, 6341), change `self.call_frames.items[len-1]` to `exec_frames.items[len-1]`.

**Pattern 12:** In the debug seeding code (~line 19145), change `candidate.runtime_frame_index` checks to direct `candidate.is_debug_hook`:

```zig
                if (target_thread == null) {
                    var search = seeded_thread.call_frames.items.len;
                    while (search > 0) {
                        search -= 1;
                        const candidate = &seeded_thread.call_frames.items[search];
                        if (candidate.is_debug_hook) {
                            if (search > 0) seed_index = search - 1;
                            break;
                        }
                    }
                }

                const exec_fr = &seeded_thread.call_frames.items[seed_index];
                const seed_pc = exec_fr.pc;
                exec_fr.last_line_pc = seed_pc;
```

- [ ] **Step 5: Build and verify**

Run: `zig build -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS. If there are errors, search for remaining `runtime_frame_index` or `self.call_frames.items[...runtime_frame_index...]` references and fix them.

- [ ] **Step 6: Run smoke tests**

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done`
Expected: 45/45 PASS.

**If any test fails:** This is the critical step. Debug the failure by checking:
1. Is the GC scanning `Thread.call_frames` correctly? (Task 1)
2. Is `ensureBcStackCap` updating `Thread.call_frames`? (Task 2)
3. Is `bcGrowFrame` updating `Thread.call_frames`? (Task 3)
4. Is `debugResolveFrameIndex` walking both arrays? (Task 4)
5. Are there any remaining `self.call_frames.items[...runtime_frame_index...]` references?

- [ ] **Step 7: Run matrix**

Run: `python3 tools/testes_matrix.py --timeout 120 2>&1 | grep -E "both_fail|zig_fail"`
Expected: 3 pre-existing fails. No new regressions.

- [ ] **Step 8: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.40b-full: eliminate runtime frame copy push (single addOne)"
```

---

### Task 6: Remove runtime_frame_index field from CallFrame

**Files:**
- Modify: `src/lua/vm.zig` — `CallFrame` struct (~line 974), `BytecodeExecFrame` struct (~line 773)

Now that all `runtime_frame_index` references are eliminated, remove the field.

- [ ] **Step 1: Verify no remaining runtime_frame_index references**

Run: `rg -n "runtime_frame_index" src/lua/vm.zig`
Expected: Only struct definition lines (773, 974) and comments (934). No usage sites.

- [ ] **Step 2: Remove runtime_frame_index from CallFrame**

Find the `CallFrame` struct (~line 974). Remove:
```zig
    /// P15.40b TODO: Eliminate once the dual-array pattern is fully merged.
    /// Links this bytecode exec frame (in Thread.call_frames) to its
    /// corresponding runtime frame (in Vm.call_frames). After the full
    /// merge, the frame IS in the single array at its own index.
    runtime_frame_index: usize = 0,
```

- [ ] **Step 3: Remove runtime_frame_index from BytecodeExecFrame (if still present)**

Find `BytecodeExecFrame` (~line 773). Remove:
```zig
    runtime_frame_index: usize,
```

- [ ] **Step 4: Build and verify**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Run smoke tests**

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done`
Expected: 45/45 PASS.

- [ ] **Step 6: Run matrix**

Run: `python3 tools/testes_matrix.py --timeout 120 2>&1 | grep -E "both_fail|zig_fail"`
Expected: 3 pre-existing fails. No new regressions.

- [ ] **Step 7: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.40b-full: remove runtime_frame_index field from CallFrame"
```

---

### Task 7: Full regression + perf + README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Build ReleaseFast**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 2: Zig unit tests**

Run: `zig build test -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: All smoke tests**

```bash
PASS=0; FAIL=0
for f in tests/smoke/*.lua; do
    if ./zig-out/bin/luazig "$f" >/dev/null 2>&1; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL: $f"
    fi
done
echo "Smoke: $PASS pass, $FAIL fail"
```
Expected: 45/45 PASS.

- [ ] **Step 4: Upstream matrix**

Run: `python3 tools/testes_matrix.py --timeout 120 2>&1 | tail -30`
Expected: 28/31 pass (no regressions).

- [ ] **Step 5: Stress test**

Run: `tools/iterative_dispatch_stress.sh 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 6: Perf measurement**

Run: `python3 tools/perf_compare.py --runs 7 --core 0 --no-build 2>&1 | tail -40`

Expected: ~5-10% improvement on `lua_calls` (one `addOne` instead of two, ~25 fewer field writes per push).

- [ ] **Step 7: Update baseline if perf improved >3%**

```bash
python3 tools/perf_compare.py --runs 7 --core 0 --no-build --update-baseline 2>&1 | tail -10
```

- [ ] **Step 8: Update README**

Update the P15.40b section in README.md to reflect the completed merge. Close the "Предвыделенный массив frame/CallInfo records" checkbox (line 1081).

- [ ] **Step 9: Commit**

```bash
git add README.md tools/perf/baseline-p15.37.json
git commit -m "docs: P15.40b-full merge frames — update README + perf results"
```

---

## Risk register

1. **GC regression (coroutines collected)**
   - **Impact:** `collectgarbage()` collects live coroutines
   - **Mitigation:** Task 1 adds GC scanning of `Thread.call_frames` BEFORE eliminating the runtime copy. If Task 5 fails, the cause is isolated to the scanning paths added in Tasks 1-4.
   - **Debug strategy:** If `co` is collected after `collectgarbage()`, check: (a) is `active_th.call_frames` the right array? (b) is `frame.regs` valid? (c) is `live_reg_top[frame.pc]` correct?

2. **Debug frame depth resolution**
   - **Impact:** `debug.getinfo(level)` returns wrong frame or "bad level"
   - **Mitigation:** Task 4 updates `debugResolveFrameIndex` to walk both arrays. The return type changes from `?usize` to `?*CallFrame`, eliminating the index-into-wrong-array bug.

3. **`ensureBcStackCap` stale `regs` slices**
   - **Impact:** After `bc_stack` realloc, bytecode frames' `regs` point to freed memory
   - **Mitigation:** Task 2 adds `Thread.call_frames` walk in `ensureBcStackCap`. Task 5 Step 7 adds `regs`/`boxed` sync at the safepoint.

4. **`bcGrowFrame` stale `regs`/`frame_cap`**
   - **Impact:** After frame growth, the CallFrame's `regs`/`frame_cap` are stale
   - **Mitigation:** Task 3 adds `Thread.call_frames` update in `bcGrowFrame`. Task 5 Step 9 removes the old `self.call_frames` update.

5. **Coroutine yield/resume with inplace-suspended frames**
   - **Impact:** Inplace-suspended frames might not survive thread switch
   - **Mitigation:** Bytecode frames stay in `Thread.call_frames` (NOT moved to Vm). The `bytecode_inplace_suspended` mechanism is unchanged — frames stay on the Thread, which survives thread switches.

## Self-review notes

- **Spec coverage:** Phase B of the spec requires merging the two structs into one `CallFrame`, replacing two arrays with one, and removing `runtime_frame_index`. P15.40b Task 1 defined the struct. This plan completes the merge (Tasks 1-6) and verifies (Task 7).
- **Placeholder scan:** Every step has exact code or explicit "find lines X-Y and change Z to W" instructions. No "TODO" / "implement later".
- **Type consistency:** `CallFrame` field types are consistent. `debugResolveFrameIndex` returns `?*CallFrame` throughout. `parkBytecodeIrHookYield` takes `exec_frames` and `frame_index` throughout.
- **Incremental safety:** Tasks 1-4 are additive (add new scanning paths, keep old ones). Task 5 is the key change (remove old push). Task 6 is cleanup (remove field). Each task is independently testable and revertible.
