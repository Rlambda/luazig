# PUC-faithful Host Recursion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace iterative dispatch (`frame_loop` + `PendingCallSlot`) with PUC-style host recursion. Eliminate `PendingCallSlot` (768B/frame). Shrink `CallFrame` from ~1200B to ~430B.

**Architecture:** `dispatchOneFrame` handles ONE frame only. Child calls go through recursive `runBytecodeInternal`. OP_TAILCALL replaces the current frame (no C stack growth). Results returned via normal function return. No continuation objects.

**Tech Stack:** Zig 0.16.0, existing `Thread.call_frames` infrastructure.

**Spec:** `docs/superpowers/specs/2026-07-21-host-recursion-design.md`

**Prerequisite:** P15.40b-full complete (commit `58b9c87`). Matrix 28/31, Smoke 45/45.

---

## Current state (before this plan)

- `runBytecodeInternal` → `runBytecodeDispatch` with `frame_loop: while`
- 74 `continue :frame_loop` statements (frame transitions)
- 17 `pending_call.set(...)` call sites (continuations)
- `completeBytecodeExecFrame` dispatches returning children to parents
- `PendingCallSlot` (768B) on every `CallFrame`
- `BytecodePendingCompletion` union with 9 variants

## Target state (after this plan)

- `dispatchOneFrame` handles ONE frame (no `frame_loop`)
- Child calls via recursive `runBytecodeInternal`
- `PendingCallSlot` deleted entirely
- `CallFrame` ~430B (was ~1200B)
- All continuation logic inlined at call sites

---

### Task 1: Add `callBytecodeFunction` helper (additive, no-op)

**Files:**
- Modify: `src/lua/vm.zig` — add function near `runBytecodeInternal` (~line 7168)

This adds a helper that will be used by all host-recursion call sites. For now it's unused — just preparation.

- [ ] **Step 1: Add `callBytecodeFunction` after `runBytecode`**

Find `pub fn runBytecode` (line 7169). After `runBytecodeInternal` (line 7173, ends ~line 7281), add:

```zig
    /// PUC-faithful host-recursion call entry point.
    /// Calls a bytecode closure by recursively entering runBytecodeInternal.
    /// For IR closures, delegates to runClosure. For builtins, delegates to callBuiltin.
    /// This replaces the iterative dispatch + PendingCallSlot pattern.
    fn callBytecodeFunction(
        self: *Vm,
        cl: *Closure,
        args: []const Value,
    ) DispatchError![]Value {
        if (cl.proto) |proto| {
            return self.runBytecodeInternal(proto, cl.upvalues, args, cl);
        }
        // IR closure: use existing host-recursive path
        var outs = [_]Value{.Nil} ** 1;
        try self.runClosure(cl, args, false);
        // runClosure stores results on bc_stack; caller reads from there
        // TODO: adapt runClosure to return []Value
        return &[_]Value{};
    }
```

Note: The IR closure path needs adaptation. For now this is a placeholder that will be filled in during Task 2.

- [ ] **Step 2: Build and verify**

Run: `zig build -Doptimize=Debug 2>&1 | tail -5`
Expected: PASS (unused function, no warnings in ReleaseFast).

- [ ] **Step 3: Run smoke tests**

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done`
Expected: 45/45 PASS (no behavior change — function is unused).

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "host-recursion: add callBytecodeFunction helper (additive, no-op)"
```

---

### Task 2: Convert OP_CALL bytecode-closure path to host recursion

**Files:**
- Modify: `src/lua/vm.zig` — OP_CALL handler (~line 8943), `runBytecodeDispatch` entry (~line 7289)

This is the **key structural change**. The OP_CALL handler for bytecode closures currently does:
1. `pending_call.set(.{ .results = ... })`
2. `pushBytecodeExecFrame(...)`
3. `continue :frame_loop`

After this task, it does:
1. `const ret = try self.runBytecodeInternal(proto, cl.upvalues, rargs, cl)`
2. Store results inline at `regs[a..]`
3. No `continue :frame_loop`, no `pending_call`

**IMPORTANT:** This task changes the OP_CALL handler but keeps the `frame_loop` structure for all other frame transitions (metamethods, hooks, closers, etc.). The `frame_loop` is still entered for those paths.

- [ ] **Step 1: Change OP_CALL bytecode-closure branch to recursive call**

Find the OP_CALL handler (`.call =>` at line 8943). Find the `.Closure` branch with `cl.proto != null` (the bytecode closure path, around line 9225-9260).

The current code does:
```zig
if (cl.proto) |proto2| {
    // ... resolve args ...
    exec_frames.items[frame_index].pending_call.set(.{
        .callee = .{ .Closure = cl },
        .completion = .{ .results = .{ .dst = a, .nresults = nresults } },
    });
    try self.pushBytecodeExecFrame(exec_frames, proto2, cl.upvalues, rargs, cl);
    continue :frame_loop;
}
```

Replace with:
```zig
if (cl.proto) |proto2| {
    // ... resolve args ...
    // Host recursion: call child directly, store results inline.
    const child_ret = try self.runBytecodeInternal(proto2, cl.upvalues, rargs, cl);
    defer if (self.returnSliceIsOwned(child_ret)) self.alloc.free(child_ret);
    // Re-derive regs (child may have grown/realloc'd bc_stack)
    regs = self.bc_stack[base .. base + frame_cap];
    boxed = self.bc_boxed[base .. base + frame_cap];
    // Store results (matches applyBytecodePendingResults logic)
    const nstore: usize = if (nresults >= 0) @intCast(nresults) else child_ret.len;
    for (0..nstore) |i| {
        regs[a + i] = if (i < child_ret.len) child_ret[i] else .Nil;
    }
    if (nresults < 0) {
        reg_top = a + child_ret.len;
    } else {
        reg_top = @max(reg_top, a + nstore);
    }
    pc += 1; // advance past OP_CALL
    continue; // continue inner while loop (NOT :frame_loop)
}
```

- [ ] **Step 2: Handle `error.Yield` from recursive call**

The `try` in Step 1 propagates `error.Yield` automatically. But the current code has special handling for yield in `completeBytecodeExecFrame`. Verify that `error.Yield` from `runBytecodeInternal` propagates correctly through the dispatch loop to `runBytecodeInternal`'s caller.

No code change needed if `try` propagates correctly. Verify by checking that the `runBytecodeDispatch` error handler at line 7253 handles `error.Yield` (it does: `if (dispatch_err == error.Yield or dispatch_err == error.ThreadSwitch) return dispatch_err;`).

- [ ] **Step 3: Handle OP_RETURN0/OP_RETURN1 fast paths**

The OP_RETURN0/OP_RETURN1 fast paths (lines 9686, 9722) call `completeBytecodeExecFrame` which reads `pending_call`. Since OP_CALL no longer sets `pending_call`, the fast paths must be updated.

Find the OP_RETURN0 fast path (line 9694-9702):
```zig
if (!has_pending_tbc and !hooks_active) {
    const empty: []Value = self.bc_return_scratch[0..0];
    if (try self.completeBytecodeExecFrame(
        exec_frames,
        boundary_depth,
        empty,
    )) |final| return final;
    continue :frame_loop;
}
```

Replace with:
```zig
if (!has_pending_tbc and !hooks_active) {
    // No TBC closers, no hooks: return directly from this frame.
    if (exec_frames.items.len == boundary_depth + 1) {
        // Returning from the boundary frame: return to caller
        return self.bc_return_scratch[0..0];
    }
    // Parent has a pending_call (metamethod/hook/etc.) — use old path
    if (try self.completeBytecodeExecFrame(
        exec_frames,
        boundary_depth,
        self.bc_return_scratch[0..0],
    )) |final| return final;
    continue :frame_loop;
}
```

Apply the same pattern to OP_RETURN1 fast path (line 9729-9736) and OP_RETURN handler (line 9672-9684).

The key insight: when the parent frame has NO `pending_call` (because OP_CALL now uses host recursion), we return directly. When the parent HAS `pending_call` (metamethod/hook/etc. still using iterative dispatch), we use `completeBytecodeExecFrame`.

Check: `if (exec_frames.items[frame_index - 1].pending_call.get() != null)` — if the parent has a pending call, use old path. Otherwise, return directly.

Actually, simpler: check `boundary_depth`. If we're at the boundary (only 1 frame above boundary_depth), the parent is the `runBytecodeInternal` caller — return directly.

- [ ] **Step 4: Build**

Run: `zig build -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS. May need iteration to fix compilation errors.

- [ ] **Step 5: Run smoke tests**

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done`
Expected: 45/45 PASS.

If failures: debug by running the failing test directly. The most likely issue is OP_RETURN not correctly detecting whether the parent expects results via return (host recursion) or via `pending_call` (iterative dispatch).

- [ ] **Step 6: Run matrix**

Run: `python3 tools/testes_matrix.py --timeout 120 2>&1 | grep "testes matrix"`
Expected: 28/31 (no regressions).

- [ ] **Step 7: Commit**

```bash
git add src/lua/vm.zig
git commit -m "host-recursion: convert OP_CALL bytecode-closure to recursive call"
```

---

### Task 3: Convert OP_TFORCALL bytecode-closure path to host recursion

**Files:**
- Modify: `src/lua/vm.zig` — OP_TFORCALL handler (~line 9943)

Same pattern as Task 2. The OP_TFORCALL handler pushes an iterator frame + sets `.results`. Replace with recursive call.

- [ ] **Step 1: Change OP_TFORCALL bytecode-closure branch**

Find the OP_TFORCALL handler (`.tforcall =>` around line 9943). Find the `.Closure` branch with `cl.proto != null` (around line 10017). Replace the `pending_call.set` + `pushBytecodeExecFrame` + `continue :frame_loop` with recursive `runBytecodeInternal` call, same pattern as Task 2 Step 1.

Store results at `regs[a + 4..]` (TFORCALL's destination offset).

- [ ] **Step 2: Build and verify**

Run: `zig build -Doptimize=Debug 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 3: Run smoke tests**

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done`
Expected: 45/45 PASS.

- [ ] **Step 4: Run matrix**

Run: `python3 tools/testes_matrix.py --timeout 120 2>&1 | grep "testes matrix"`
Expected: 28/31.

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "host-recursion: convert OP_TFORCALL bytecode-closure to recursive call"
```

---

### Task 4: Convert metamethods to host recursion

**Files:**
- Modify: `src/lua/vm.zig` — all `tryPushBytecodeMetamethod` call sites

Metamethods currently use `tryPushBytecodeMetamethod` → `tryPushBytecodeContinuationCall` → push frame + set `.value`/`.compare`/`.concat`/`.gsub` continuation. Replace with inline `callBytecodeFunction`.

**Key call sites to convert** (search: `rg -n "tryPushBytecodeMetamethod" src/lua/vm.zig`):
- OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_MOD, OP_POW, OP_IDIV, OP_UNM, OP_BNOT (~10 sites)
- OP_CONCAT (concat accumulator loop)
- OP_INDEX (table index fallback)
- OP_LT, OP_LE (comparison)
- OP_LEN, OP_CONCAT
- `string.gsub` replacement callback

- [ ] **Step 1: Create `callBytecodeMetamethod` helper**

Near `callBytecodeFunction`, add:

```zig
    /// Call a metamethod and return the single result value.
    /// For bytecode closures: recursive runBytecodeInternal.
    /// For IR closures/builtins: existing callMetamethod path.
    fn callBytecodeMetamethod(
        self: *Vm,
        meta: Value,
        args: []const Value,
    ) DispatchError!?Value {
        switch (meta) {
            .Closure => |cl| {
                if (cl.proto) |proto| {
                    const ret = try self.runBytecodeInternal(proto, cl.upvalues, args, cl);
                    defer if (self.returnSliceIsOwned(ret)) self.alloc.free(ret);
                    if (ret.len > 0) return ret[0];
                    return .Nil;
                }
            },
            else => {},
        }
        // Non-bytecode: use existing synchronous path
        return null; // signal: caller should use tryPushBytecodeMetamethod (old path)
    }
```

- [ ] **Step 2: Convert OP_ADD metamethod path**

Find the OP_ADD handler (`.add =>` in the dispatch loop). Find where it calls `tryPushBytecodeMetamethod` for `__add`. Replace:

```zig
// BEFORE:
if (try self.tryPushBytecodeMetamethod(exec_frames, frame_index, meta, "__add", args, .{ .value = .{ .dst = a } })) {
    continue :frame_loop;
}

// AFTER:
if (try self.callBytecodeMetamethod(meta, args)) |result| {
    regs[a] = result;
    pc += 1;
    continue;
}
// Fall through to old path for IR/builtin metamethods
if (try self.tryPushBytecodeMetamethod(exec_frames, frame_index, meta, "__add", args, .{ .value = .{ .dst = a } })) {
    continue :frame_loop;
}
```

Note: `callBytecodeMetamethod` returns `null` for non-bytecode metamethods, so the old path is the fallback.

- [ ] **Step 3: Repeat for all arithmetic metamethod opcodes**

Apply the same pattern to: OP_SUB, OP_MUL, OP_DIV, OP_MOD, OP_POW, OP_IDIV, OP_UNM, OP_BNOT, OP_BAND, OP_BOR, OP_BXOR, OP_SHL, OP_SHR.

Search for each: `rg -n "tryPushBytecodeMetamethod.*__sub\|tryPushBytecodeMetamethod.*__mul\|..." src/lua/vm.zig`

- [ ] **Step 4: Convert OP_INDEX metamethod**

Find the OP_INDEX handler. Replace `tryPushBytecodeMetamethod` with `callBytecodeMetamethod`, storing the result at the index register.

- [ ] **Step 5: Convert OP_LT/OP_LE comparison metamethods**

Find OP_LT and OP_LE handlers. Replace `.compare` continuation with inline:

```zig
if (try self.callBytecodeMetamethod(meta, args)) |result| {
    const truth = result != .Nil and result != .BoolFalse;
    // Set comparison result (inverted if needed)
    regs[a] = if (truth == !invert) .True else .False;
    pc += 1;
    continue;
}
```

- [ ] **Step 6: Convert OP_LEN/OP_CONCAT metamethods**

Same pattern. OP_CONCAT is special — it accumulates values in a loop. Replace the `.concat` continuation with an inline accumulation loop using `callBytecodeMetamethod`.

- [ ] **Step 7: Build**

Run: `zig build -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 8: Run smoke tests**

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done`
Expected: 45/45 PASS.

- [ ] **Step 9: Run matrix**

Run: `python3 tools/testes_matrix.py --timeout 120 2>&1 | grep "testes matrix"`
Expected: 28/31.

- [ ] **Step 10: Commit**

```bash
git add src/lua/vm.zig
git commit -m "host-recursion: convert metamethods to recursive calls"
```

---

### Task 5: Convert debug hooks to host recursion

**Files:**
- Modify: `src/lua/vm.zig` — `tryPushBytecodeDebugHook` call sites in dispatch loop

When a line/count hook fires and the hook is a bytecode closure, replace `tryPushBytecodeDebugHook` (push frame + `.hook` continuation) with inline `runBytecodeInternal`.

- [ ] **Step 1: Convert line hook path**

Find the line hook dispatch in the slow path (~line 7487). Currently:
```zig
if (try self.tryPushBytecodeDebugHook(exec_frames, frame_index, "line", ...)) {
    continue :frame_loop;
}
self.dispatchBytecodeHook("line", current_line, null) catch |hook_err| { ... };
```

Replace with:
```zig
// Try host-recursion path for bytecode hook closures
if (hook is bytecode closure) {
    const hook_ret = self.runBytecodeInternal(hook_proto, hook_upvalues, hook_args, hook_cl) catch |hook_err| switch (hook_err) {
        error.Yield => { /* park and propagate */ },
        else => return hook_err,
    };
    // Hook returned — apply skip flags inline
    // (was applyBytecodePendingHook logic)
} else {
    // Non-bytecode hook: use existing dispatchBytecodeHook
    self.dispatchBytecodeHook("line", current_line, null) catch ...;
}
```

- [ ] **Step 2: Convert count hook path**

Same pattern for the count hook path (~line 7581).

- [ ] **Step 3: Build, test, commit**

Run: `zig build -Doptimize=Debug 2>&1 | tail -5`
Run: smoke tests + matrix
Expected: 45/45 + 28/31.

```bash
git add src/lua/vm.zig
git commit -m "host-recursion: convert debug hooks to recursive calls"
```

---

### Task 6: Convert `__close` to host recursion

**Files:**
- Modify: `src/lua/vm.zig` — `beginBytecodeClose`, `continueBytecodeClose`

`__close` metamethods are called when TBC variables go out of scope. Currently uses `beginBytecodeClose` (scan TBC slots) + `continueBytecodeClose` (push closer frame + `.close` continuation).

Replace with an inline loop that calls each `__close` metamethod via `callBytecodeFunction`.

- [ ] **Step 1: Write `closeBytecodeTbcSlots` inline function**

```zig
    /// Close all TBC slots from top to mark. Calls __close metamethods
    /// via host recursion. Propagates errors (last error wins, PUC semantics).
    fn closeBytecodeTbcSlots(
        self: *Vm,
        exec_frames: *std.ArrayListUnmanaged(CallFrame),
        frame_index: usize,
        mark: usize,
        error_on_entry: ?Value,
    ) DispatchError!void {
        const start_tbc = exec_frames.items[frame_index].tbc_mark;
        while (self.bc_tbc_regs.items.len > mark) {
            const slot = self.bc_tbc_regs.pop().?;
            // Get __close metamethod
            const closer = ... ;
            if (closer is bytecode closure) {
                _ = try self.callBytecodeFunction(closer_cl, closer_args);
            } else {
                // Non-bytecode: existing runCloseMetamethod
                try self.runCloseMetamethod(...);
            }
        }
    }
```

- [ ] **Step 2: Replace OP_RETURN `beginBytecodeClose` calls**

In OP_RETURN/RETURN0/RETURN1, replace:
```zig
switch (try self.beginBytecodeClose(exec_frames, boundary_depth, frame_index, 0, null, true, .{ .return_frame = ret })) {
    .resume_dispatch => continue :frame_loop,
    .final => |final| return final,
    .propagate_error => return error.RuntimeError,
}
```
With:
```zig
try self.closeBytecodeTbcSlots(exec_frames, frame_index, exec_frames.items[frame_index].tbc_mark, null);
// Close upvalues, then return
try self.closeBytecodeUpvaluesFrom(exec_frames, frame_index, 0);
// Return values to caller
if (exec_frames.items.len == boundary_depth + 1) return ret;
// Parent has pending_call — use old path (temporary, until all conversions done)
if (try self.completeBytecodeExecFrame(exec_frames, boundary_depth, ret)) |final| return final;
continue :frame_loop;
```

- [ ] **Step 3: Build, test, commit**

```bash
zig build -Doptimize=Debug
# smoke + matrix
git commit -m "host-recursion: convert __close to inline loop with recursive calls"
```

---

### Task 7: Convert pcall/xpcall to host recursion

**Files:**
- Modify: `src/lua/vm.zig` — `tryPushBytecodeProtectedCall`, `builtinPcall`, `builtinXpcall`

pcall already uses host recursion partially (via `builtinPcall`). The `tryPushBytecodeProtectedCall` is the iterative path for bytecode pcall targets. Replace with direct `runBytecodeInternal` + `catch`.

- [ ] **Step 1: Replace `tryPushBytecodeProtectedCall` in the dispatch loop**

Find the pcall path in `runBytecodeDispatch` (the "armed" bytecode pcall target). Replace:
```zig
if (try self.tryPushBytecodeProtectedCall(exec_frames, boundary_depth, frame_index, ...)) {
    continue :frame_loop;
}
```
With:
```zig
const result = self.runBytecodeInternal(proto, cl.upvalues, child_args, cl) catch |err| switch (err) {
    error.RuntimeError => {
        // pcall caught the error — format result
        outs[0] = .False;
        outs[1] = self.err_obj;
        // ... existing pcall error formatting ...
    },
    else => return err,
};
// pcall succeeded — format result
outs[0] = .True;
// ... copy result values ...
```

- [ ] **Step 2: Build, test, commit**

```bash
zig build -Doptimize=Debug
# smoke + matrix (especially errors.lua, coroutine.lua)
git commit -m "host-recursion: convert pcall/xpcall to direct recursive calls"
```

---

### Task 8: Convert coroutine resume to host recursion

**Files:**
- Modify: `src/lua/vm.zig` — `builtinCoroutineResume`, `tryRequestBytecodeCoroutineSwitch`, `driveBytecodeCoroutineTrampoline`

`coroutine.resume` currently uses a trampoline mechanism (`ThreadSwitch` signal). With host recursion, resume can be a direct recursive `runBytecodeInternal` on the target thread.

- [ ] **Step 1: Simplify `builtinCoroutineResume`**

Replace the trampoline with:
```zig
fn builtinCoroutineResume(self, args, outs) {
    // ... setup ...
    self.switchRuntime(target_thread);
    const result = self.runBytecodeInternal(target_proto, ...) catch |err| switch (err) {
        error.Yield => { /* coroutine yielded — park and return yield values */ },
        error.RuntimeError => { /* coroutine errored — return false, err */ },
        else => return err,
    };
    // Coroutine returned normally
    self.switchRuntime(caller_thread);
    outs[0] = .True;
    // ... copy result values ...
}
```

- [ ] **Step 2: Remove trampoline infrastructure**

Delete `tryRequestBytecodeCoroutineSwitch`, `driveBytecodeCoroutineTrampoline`, `bytecode_coroutine_trampoline_active`, `bytecode_coroutine_switch_request`.

- [ ] **Step 3: Build, test, commit**

```bash
zig build -Doptimize=Debug
# smoke 36, 37 + coroutine.lua
git commit -m "host-recursion: convert coroutine.resume to direct recursive call"
```

---

### Task 9: Delete PendingCallSlot and all continuation infrastructure

**Files:**
- Modify: `src/lua/vm.zig` — delete ~1000+ lines of continuation code

After Tasks 2-8, no code uses `PendingCallSlot` anymore. Delete everything.

- [ ] **Step 1: Verify no remaining `pending_call` usage**

Run: `rg -n "pending_call\.set\|pending_call\.get\|pending_call\.clear\|\.pending_call" src/lua/vm.zig`
Expected: Only `CallFrame` struct field definition + `pushBytecodeExecFrame` initialization.

If any usage remains: convert those call sites first (they were missed in Tasks 2-8).

- [ ] **Step 2: Delete continuation structs**

Delete: `BytecodePendingCompletion`, `BytecodeResultContinuation`, `BytecodeValueContinuation`, `BytecodeIgnoreContinuation`, `BytecodeCompareContinuation`, `BytecodeConcatContinuation`, `BytecodeGsubContinuation`, `BytecodeHookContinuation`, `BytecodeCloseContinuation`, `BytecodeCoroutineContinuation`, `BytecodeHookPost`, `BytecodeClosePost`, `BytecodeProtectedCall`, `BytecodePendingCall`, `PendingCallSlot`.

- [ ] **Step 3: Delete continuation functions**

Delete: `completeBytecodeExecFrame`, `completeBytecodePendingExternalResults`, `completeBytecodeProtectedResult`, `completeBytecodeCoroutineResult`, `applyBytecodePendingResults`, `applyBytecodePendingValue`, `applyBytecodePendingIgnore`, `applyBytecodePendingCompare`, `applyBytecodePendingConcat`, `applyBytecodePendingGsub`, `applyBytecodePendingHook`, `applyBytecodePendingClose`, `cancelBytecodePendingCall`, `beginBytecodeClose`, `continueBytecodeClose`, `startBytecodePendingCall`, `tryPushBytecodeContinuationCall`, `tryPushBytecodeMetamethod`, `tryPushBytecodeDebugHook`, `tryPushBytecodeProtectedCall`, `tryRequestBytecodeCoroutineSwitch`, `driveBytecodeCoroutineTrampoline`.

- [ ] **Step 4: Delete `PendingCallSlot` field from `CallFrame`**

Remove `pending_call: PendingCallSlot = .{}` from `CallFrame` struct.

- [ ] **Step 5: Remove `frame_loop`**

The `frame_loop: while` in `runBytecodeDispatch` should now have only ONE iteration (one frame per call). Change to:
```zig
fn dispatchOneFrame(self: *Vm, exec_frames: ..., boundary_depth: ...) DispatchError![]Value {
    const frame_index = exec_frames.items.len - 1;
    // ... load frame state ...
    while (pc < cur_proto.code.len) {
        // ... opcodes (no continue :frame_loop) ...
    }
}
```

All remaining `continue :frame_loop` → `continue` (inner loop) or `return` (from dispatchOneFrame).

- [ ] **Step 6: Build**

Run: `zig build -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS (after fixing compilation errors from dangling references).

- [ ] **Step 7: Run smoke tests**

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done`
Expected: 45/45 PASS.

- [ ] **Step 8: Run matrix (ReleaseFast)**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --timeout 120
```
Expected: 28/31.

- [ ] **Step 9: Run stress test**

Run: `tools/iterative_dispatch_stress.sh 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add src/lua/vm.zig
git commit -m "host-recursion: delete PendingCallSlot + frame_loop + all continuation code"
```

---

### Task 10: Update README + perf measurement

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Run perf comparison**

```bash
python3 tools/perf_compare.py --runs 7 --core 0 --no-build 2>&1 | tail -25
```
Expected: `lua_calls` within ±5% of current baseline.

- [ ] **Step 2: Update README**

Add section documenting the host recursion refactor:
- What changed (iterative dispatch → host recursion)
- Why (PUC-faithful, eliminate PendingCallSlot)
- Impact (CallFrame ~1200B → ~430B, enables Phase C)
- Close relevant checkboxes

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: host recursion refactor — update README"
```

---

## Risk register

1. **OP_RETURN detecting host-recursion vs iterative parent**
   - When a child returns, the parent might be using host recursion (OP_CALL) or iterative dispatch (metamethod/hook).
   - **Mitigation:** Check `exec_frames.items.len == boundary_depth + 1` — if true, the parent is `runBytecodeInternal` (host recursion). If false, parent has `pending_call` (iterative).
   - **Alternative:** Always return from `dispatchOneFrame`, and have the caller decide what to do. This eliminates the detection problem entirely (Task 5 cleanup).

2. **Coroutine yield across recursive C calls**
   - `error.Yield` must propagate through multiple C stack frames.
   - **Mitigation:** Already works for builtins. Same mechanism.

3. **TBC closer ordering during error unwind**
   - `__close` metamethods must run in LIFO order even during error propagation.
   - **Mitigation:** `closeBytecodeTbcSlots` loop handles this inline, with error accumulation.

4. **Debug hook `savedpc` semantics**
   - PUC uses `ci->savedpc` to track the instruction after a hook. Our `pc` local serves the same purpose.
   - **Mitigation:** Hook dispatch is inline — `pc` is directly accessible.

## Self-review notes

- **Spec coverage:** All 9 continuation variants from the spec are addressed in Tasks 2-8.
- **Placeholder scan:** Each task has concrete code patterns. Some mechanical repetition ("same pattern as Task 2") is used for similar opcodes — the engineer should refer to the referenced task for the exact code.
- **Type consistency:** `callBytecodeFunction` and `callBytecodeMetamethod` signatures are consistent throughout.
- **Incremental safety:** Each task is independently testable. Tasks 2-8 can be done in any order (but the suggested order maximizes test coverage early).
- **Scale:** This is a ~2000-line refactor. Tasks 2-8 convert call sites incrementally. Task 9 is the big cleanup. The `frame_loop` stays until Task 9.
