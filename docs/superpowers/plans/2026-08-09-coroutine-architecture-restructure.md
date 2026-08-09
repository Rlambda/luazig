# Coroutine Architecture Restructure Implementation Plan

> **STATUS:** Phase 0 complete. Phase 1 (host recursion) CANCELLED — PUC uses
> `goto startfunc` (iterative), not recursion (see DESIGN.md). Phases 1-4
> based on wrong assumption. Phase 6 (zero-alloc) partially done.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ~~Eliminate 5-7 heap allocations per coroutine yield/resume cycle~~
Reduce coroutine overhead within the iterative dispatch model (PUC-faithful).

**Architecture:** Replace the iterative `frame_loop` + `PendingCallSlot` (768B/frame) continuation model with PUC-style host recursion. Each `runBytecodeInternal` call handles ONE frame. OP_CALL recurses. `coroutine.yield` propagates `error.Yield` through the Zig call stack naturally (like PUC's `longjmp`). The `frame_loop` survives only for coroutine resume (walking preserved frames).

**Tech Stack:** Zig (luazig), PUC Lua 5.5.0 reference, `tools/testes_matrix.py`, `tools/smoke_compare.py`, `tools/leak_bench.py`, `tools/perf_compare.py`

**Existing design doc:** `docs/superpowers/specs/2026-07-21-host-recursion-design.md` (335 lines)

**Root causes being fixed:**
1. 5-7 heap allocations per yield/resume (PUC: zero via `lua_xmove`)
2. 3 no-op functions called every yield (`snapshotThreadLocalsFromFrame`, `seedThreadFrameLocalOverridesFromSnapshot`, `seedCloseLocalOverridesFromFrames`)
3. 60+ Thread fields (PUC: ~5 for coroutine support)
4. 190-line `driveBytecodeCoroutineTrampoline` replacing what PUC does with C-stack recursion
5. Redundant yield value copies: `yielded` + `last_yield_payload` (same data, two heap allocs)

---

## File Structure

All changes are in `src/lua/vm.zig` (33,541 lines) unless otherwise noted. Key line numbers (will shift as code is edited — always grep for function names, not line numbers):

| Function / Struct | Purpose |
|---|---|
| `Thread` struct (~1252-1366) | 60+ fields, many to be removed/simplified |
| `CallFrame` struct (~1078-1173) | Has `pending_call: PendingCallSlot` (768B) — to be removed |
| `PendingCallSlot` (~1024) | Hot/cold split: `active: bool` + `payload: BytecodePendingCall` |
| `BytecodePendingCompletion` (~952) | 9-variant tagged union — to be eliminated |
| `runBytecodeDispatch` (~8116) | Main interpreter loop with `frame_loop` — to be split |
| `runBytecodeInternal` (~7826) | Entry point — to become recursive |
| `opCall` (~11439) | OP_CALL handler — Phase 0 inline fast path already added |
| `opReturn/opReturn0/opReturn1` (~10433-10620) | Return handlers |
| `builtinCoroutineResume` (~14589) | 430-line resume — to be simplified |
| `builtinCoroutineYield` (~14418) | 147-line yield — to be simplified |
| `driveBytecodeCoroutineTrampoline` (~6530) | 190-line trampoline — to be deleted |
| `tryPushBytecode*` (~5134-5480) | Push-frame-for-continuation functions — to be replaced by recursive calls |
| `applyBytecodePending*` (~5482-5620) | Continuation handlers — to be deleted |
| `completeBytecodeExecFrame` (~7624) | Frame completion dispatch — to be deleted |
| `switchRuntime`/`parkActiveRuntime`/`activateRuntime` (~2754-2870) | Thread runtime parking — stays |
| `parkDirectBytecodeYield` (~7774) | In-place yield parking — stays (simplified) |

---

## Phase 0: Quick Wins — Eliminate No-Op Functions + Merge Redundant Yield Fields

**Goal:** Reduce yield-path allocations from 5-7 to 2-3. Remove dead code. Low risk.

### Task 0.1: Remove 3 no-op functions from yield path

**Files:**
- Modify: `src/lua/vm.zig` — functions `snapshotThreadLocalsFromFrame` (~14354), `seedThreadFrameLocalOverridesFromSnapshot` (~14404), `seedCloseLocalOverridesFromFrames` (~14413)
- Modify: `src/lua/vm.zig` — call sites in `builtinCoroutineYield` (~14449-14451)

- [ ] **Step 1: Verify functions are no-ops**

Run:
```bash
cd /home/boss/codes/luazig
grep -A5 "fn snapshotThreadLocalsFromFrame" src/lua/vm.zig
grep -A5 "fn seedThreadFrameLocalOverridesFromSnapshot" src/lua/vm.zig
grep -A5 "fn seedCloseLocalOverridesFromFrames" src/lua/vm.zig
```
Expected: each function body is empty or just a comment (no actual logic).

- [ ] **Step 2: Remove the 3 call sites in builtinCoroutineYield**

In `builtinCoroutineYield`, find the block around line ~14449 that calls these 3 functions:
```zig
try self.snapshotThreadLocalsFromFrame(th, fr);
try self.seedThreadFrameLocalOverridesFromSnapshot(th, fr);
try self.seedCloseLocalOverridesFromFrames(th);
```
Delete these 3 lines entirely.

- [ ] **Step 3: Delete the 3 function definitions**

Delete the function bodies of `snapshotThreadLocalsFromFrame`, `seedThreadFrameLocalOverridesFromSnapshot`, `seedCloseLocalOverridesFromFrames`.

- [ ] **Step 4: Remove the `locals_snapshot` field from Thread**

The field `locals_snapshot: ?[]LocalSnap = null` (line ~1275) is never populated (the function that would populate it was a no-op). Delete the field declaration and any references:
```bash
grep -n "locals_snapshot" src/lua/vm.zig
```
Remove all references (field decl, deinit, clear in thread cleanup at ~14204).

- [ ] **Step 5: Remove `frame_local_overrides` and `frame_capture_cells` from Thread**

These ArrayListUnmanaged fields (~1283-1284) are always empty — the functions that would populate them were no-ops. Search for ALL references:
```bash
grep -n "frame_local_overrides\|frame_capture_cells" src/lua/vm.zig
```
Remove field declarations, deinit calls (~14247-14248), clearAndFree calls (~13597, ~13729, ~13737, ~13922, ~14071).

- [ ] **Step 6: Remove `frame_id_counter` field**

Search: `grep -n "frame_id_counter" src/lua/vm.zig` — remove field and all references.

- [ ] **Step 7: Build and verify**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | tail -3
```
Expected: BUILD OK. If errors, fix remaining references to removed fields/functions.

- [ ] **Step 8: Regression test**

```bash
for i in 1 2; do python3 tools/testes_matrix.py --testc 2>&1 | grep "pass parity"; done
python3 tools/smoke_compare.py 2>&1 | tail -2
python3 tools/leak_bench.py --no-build 2>&1 | tail -3
python3 tools/perf_compare.py --no-build --runs 3 2>&1 | grep "geomean"
```
Expected: matrix 30/31, smoke PASS, leakbench PASS, geomean ≤ 2.75x

- [ ] **Step 9: Commit**

```bash
git add src/lua/vm.zig
git commit -m "refactor(coroutine): remove 3 no-op yield functions + dead Thread fields

Removed (no-ops called on every yield):
- snapshotThreadLocalsFromFrame
- seedThreadFrameLocalOverridesFromSnapshot
- seedCloseLocalOverridesFromFrames

Removed dead Thread fields:
- locals_snapshot (always null)
- frame_local_overrides (always empty)
- frame_capture_cells (always empty)
- frame_id_counter (unused)
"
```

### Task 0.2: Merge `yielded` and `last_yield_payload`

**Problem:** `th.yielded` and `th.last_yield_payload` are both heap-allocated copies of the SAME yield values. `last_yield_payload` exists because some code paths read yield values asynchronously (after the thread is already resumed).

**Files:**
- Modify: `src/lua/vm.zig` — Thread struct (~1274, ~1340), `builtinCoroutineYield` (~14460-14463, ~14482), `setThreadLastYieldPayload` (~14326), `bytecodeCoroutineYieldStep` (~6502-6510), `builtinCoroutineResume` (~14720-14803, ~14993), `builtinCoroutineStatus` (~16826, ~17312), thread cleanup (~16441)

- [ ] **Step 1: Analyze usage of both fields**

```bash
grep -n "\.yielded\b" src/lua/vm.zig | grep -v "yielded_in_place\|yielded_from\|last_yield"
grep -n "last_yield_payload" src/lua/vm.zig
```
Document which code reads which field. Both are read in resume formatting (~14720, ~14803, ~14993, ~16826, ~17312).

- [ ] **Step 2: Replace `last_yield_payload` with `yielded` in all read sites**

Every place that reads `th.last_yield_payload` should read `th.yielded` instead:
```zig
// BEFORE:
const ys = if (th.last_yield_payload) |vals| vals else (th.yielded orelse &[_]Value{});
// AFTER:
const ys = th.yielded orelse &[_]Value{};
```

- [ ] **Step 3: Remove `setThreadLastYieldPayload` function**

Delete the function (~14326-14332) and ALL call sites. The `th.yielded` copy (already done in `builtinCoroutineYield` at ~14461) is the single source of truth.

- [ ] **Step 4: Remove `last_yield_payload` field from Thread**

Delete field declaration (~1340), deinit (~16441), and any remaining references.

- [ ] **Step 5: Build and verify**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | tail -3
```

- [ ] **Step 6: Regression test**

```bash
for i in 1 2; do python3 tools/testes_matrix.py --testc 2>&1 | grep "pass parity"; done
python3 tools/smoke_compare.py 2>&1 | tail -2
python3 tools/leak_bench.py --no-build 2>&1 | tail -3
```
Expected: matrix 30/31, smoke PASS, leakbench PASS

- [ ] **Step 7: Commit**

```bash
git add src/lua/vm.zig
git commit -m "perf(coroutine): merge yielded + last_yield_payload into single field

Eliminates one heap allocation per yield cycle. Both fields held copies of
the same yield values — last_yield_payload was a redundant second copy."
```

### Task 0.3: Make `trace_frame_names` lazy

**Problem:** `snapshotThreadTraceFrames` (~14365) allocates an array of frame name pointers on EVERY yield. This is only needed for `debug.getinfo`, not for the yield itself.

**Files:**
- Modify: `src/lua/vm.zig` — `snapshotThreadTraceFrames` (~14365), `builtinCoroutineYield` (~14453), wherever `trace_frame_names` is READ

- [ ] **Step 1: Find all reads of `trace_frame_names`**

```bash
grep -n "trace_frame_names" src/lua/vm.zig
```

- [ ] **Step 2: Remove the `snapshotThreadTraceFrames` call from yield path**

In `builtinCoroutineYield`, delete the line:
```zig
try self.snapshotThreadTraceFrames(th);
```

- [ ] **Step 3: Make trace_frame_names computed on-demand**

Wherever `trace_frame_names` is READ (likely in debug.getinfo or traceback paths), replace the read with a call to compute the frame names from `th.call_frames` at that moment. If no read sites exist (field may be vestigial), simply delete the field.

- [ ] **Step 4: Delete `snapshotThreadTraceFrames` function** if no callers remain

- [ ] **Step 5: Build, test, commit**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | tail -3
for i in 1 2; do python3 tools/testes_matrix.py --testc 2>&1 | grep "pass parity"; done
python3 tools/smoke_compare.py 2>&1 | tail -2
git add src/lua/vm.zig
git commit -m "perf(coroutine): make trace_frame_names lazy instead of per-yield alloc"
```

---

## Phase 1: OP_CALL → Host Recursion

**Goal:** Replace the OP_CALL iterative path (push frame + PendingCallSlot + continue frame_loop) with a recursive `runBytecodeInternal` call. Delete `.results` continuation machinery.

**Key insight:** `runBytecodeDispatch` currently has a `frame_loop: while` that iterates over ALL frames. After this phase, `dispatchOneFrame` handles exactly ONE frame. OP_CALL recurses into `runBytecodeInternal`. The `frame_loop` is preserved ONLY for coroutine resume (Phase 4).

### Task 1.1: Create `dispatchOneFrame` — single-frame dispatch without frame_loop

**Files:**
- Modify: `src/lua/vm.zig` — extract from `runBytecodeDispatch` (~8116)

- [ ] **Step 1: Read `runBytecodeDispatch` structure**

```bash
cd /home/boss/codes/luazig
# Read the function and understand the frame_loop structure
grep -n "fn runBytecodeDispatch\|frame_loop:\|while.*ctx.pc.*code.len" src/lua/vm.zig
```

The current structure:
```
runBytecodeDispatch:
  frame_loop: while (exec_frames.len() > boundary_depth) {
    loadDispatchCtx()
    defer syncDispatchCtx()
    while (ctx.pc < cur_proto.code.len) {
      // opcode handlers
      .call => { opCall → continue :frame_loop }
      .return_ => { opReturn → continue :frame_loop }
    }
  }
```

The target structure:
```
dispatchOneFrame:
  loadDispatchCtx()
  defer syncDispatchCtx()
  while (ctx.pc < cur_proto.code.len) {
    // opcode handlers
    .call => {
      // Recursive call, result returned directly
      const ret = try self.runBytecodeInternal(proto2, ...);
      // Store results inline at regs[a]
    }
    .return_ => {
      // Return results from dispatchOneFrame
      return results;
    }
  }
```

- [ ] **Step 2: Create `dispatchOneFrame` as a copy of the inner loop**

Copy the inner `while (ctx.pc < ...)` loop + its setup (loadDispatchCtx, defer syncDispatchCtx, stack_ptr tracking) into a new function `dispatchOneFrame`. This function handles ONE frame.

Keep `runBytecodeDispatch` with its `frame_loop` intact for now — `runBytecodeInternal` still calls `runBytecodeDispatch`. In a later step, we'll switch to `dispatchOneFrame`.

- [ ] **Step 3: Build to verify the new function compiles**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | tail -3
```

- [ ] **Step 4: Commit (WIP — function exists but unused)**

```bash
git add src/lua/vm.zig
git commit -m "wip: add dispatchOneFrame for single-frame host-recursion dispatch"
```

### Task 1.2: Switch OP_CALL to recursive call in dispatchOneFrame

**Files:**
- Modify: `src/lua/vm.zig` — `.call` handler in `dispatchOneFrame`

- [ ] **Step 1: Replace OP_CALL iterative path with recursive call**

In `dispatchOneFrame`, the `.call` handler should:
1. Resolve callee type (Closure/Builtin/__call)
2. For Closure with proto:
   ```zig
   // Instead of: pushBytecodeExecFrame + pending_call + continue :frame_loop
   // Do: recursive call
   try self.ensureBcStackCap(self.bc_stack_top + child_frame_cap + child_nextra);
   const ret = try self.runBytecodeInternal(proto, cl.upvalues, rargs, cl);
   // Store results inline
   const nstore = if (nresults >= 0) @intCast(nresults) else ret.len;
   // ... store ret values at regs[a]
   ```
3. For Builtin: same as current opCall (callBuiltin directly)
4. NO DispatchResult enum, NO pending_call

- [ ] **Step 2: Handle OP_RETURN to return from dispatchOneFrame**

```zig
.return_ => {
    // Format return values
    // Close upvalues
    // Fire "return" debug hook if active
    return results;  // Returns to caller's OP_CALL handler
}
```

- [ ] **Step 3: Switch runBytecodeInternal to call dispatchOneFrame**

Change `runBytecodeInternal` to call `dispatchOneFrame` instead of `runBytecodeDispatch`. Keep `runBytecodeDispatch` with `frame_loop` for coroutine resume only.

- [ ] **Step 4: Build and fix compilation errors**

This is a large change — expect compilation errors. Fix them one by one. Key issues:
- The `.call` inline fast path added in the previous iteration needs to be removed (replaced by recursion)
- `DispatchResult` enum can be simplified (`.continue_frame_loop` no longer needed for OP_CALL)
- Hook dispatch for call/return needs to be inline

- [ ] **Step 5: Run smoke tests (expect some failures)**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | tail -3
python3 tools/smoke_compare.py 2>&1 | tail -5
```

- [ ] **Step 6: Fix failures iteratively**

Common issues:
- OP_RETURN not popping frame correctly (the defer popBytecodeExecFrame handles this)
- OP_TAILCALL still uses frame_loop (keep iterative for now — tailcall reuse is tricky)
- Pending continuation handlers expecting frame_loop

- [ ] **Step 7: Full regression**

```bash
for i in 1 2; do python3 tools/testes_matrix.py --testc 2>&1 | grep "pass parity"; done
python3 tools/smoke_compare.py 2>&1 | tail -2
python3 tools/leak_bench.py --no-build 2>&1 | tail -3
python3 tools/perf_compare.py --no-build --runs 3 2>&1 | grep "geomean"
```

- [ ] **Step 8: Commit**

```bash
git add src/lua/vm.zig
git commit -m "feat(dispatch): OP_CALL host recursion — replace frame_loop with recursive runBytecodeInternal

Eliminates PendingCallSlot .results continuation for OP_CALL. Recursive
call returns results directly — no pending_call, no applyBytecodePendingResults.

frame_loop survives only for OP_TAILCALL and coroutine resume (Phase 4)."
```

---

## Phase 2: Metamethods → Host Recursion

**Goal:** Replace `tryPushBytecodeMetamethod` with inline `callBytecodeFunction`. Delete `.value`/`.ignore`/`.compare`/`.concat`/`.gsub` continuations.

### Task 2.1: Create `callBytecodeFunction` helper

- [ ] **Step 1: Write the helper**

```zig
/// Call a bytecode closure and return its results. Thin wrapper around
/// runBytecodeInternal — the recursive call IS the continuation.
fn callBytecodeFunction(self: *Vm, cl: *Closure, args: []const Value) DispatchError![]Value {
    const proto = cl.proto orelse return self.fail("cannot call non-bytecode closure", .{});
    return self.runBytecodeInternal(proto, cl.upvalues, args, cl);
}
```

- [ ] **Step 2: Build, commit**

### Task 2.2: Replace metamethod push with recursive call

- [ ] **Step 1: In OP_ADD/SUB/MUL/MOD/POW (and IDIV/BAND/BOR/BXOR/SHL/SHR) handlers**

Replace:
```zig
// BEFORE: push metamethod frame + .value continuation + continue :frame_loop
if (try self.tryPushBytecodeMetamethod(...)) { continue :frame_loop; }
// AFTER child returns: applyBytecodePendingValue stores result
```
With:
```zig
// AFTER: recursive call, result inline
if (metamethod_is_closure) {
    const ret = try self.callBytecodeFunction(meta_cl, args);
    regs[a] = ret[0];
}
```

- [ ] **Step 2: Replace OP_CONCAT metamethod with recursive call in loop**

- [ ] **Step 3: Replace OP_LT/LE comparison metamethods**

- [ ] **Step 4: Delete `tryPushBytecodeMetamethod`, `tryPushBytecodeContinuationCall`**

- [ ] **Step 5: Delete `.value`/`.ignore`/`.compare`/`.concat`/`.gsub` from BytecodePendingCompletion**

- [ ] **Step 6: Delete `applyBytecodePendingValue`, `applyBytecodePendingIgnore`, `applyBytecodePendingCompare`**

- [ ] **Step 7: Build, regression test, commit**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | tail -3
for i in 1 2; do python3 tools/testes_matrix.py --testc 2>&1 | grep "pass parity"; done
python3 tools/smoke_compare.py 2>&1 | tail -2
python3 tools/perf_compare.py --no-build --runs 3 2>&1 | grep -E "geomean|metamethod"
git commit -m "feat(dispatch): metamethods host recursion — inline callBytecodeFunction"
```

---

## Phase 3: Hooks/Closers/pcall → Host Recursion

### Task 3.1: Debug hooks → recursive call

- [ ] Replace `tryPushBytecodeDebugHook` with inline `runBytecodeInternal` for hook closures
- [ ] Delete `.hook` continuation + `applyBytecodePendingHook`
- [ ] Build, test, commit

### Task 3.2: `__close` → recursive call

- [ ] Replace `beginBytecodeClose`/`continueBytecodeClose` with inline loop using `callBytecodeFunction`
- [ ] Delete `.close` continuation + `applyBytecodePendingClose`
- [ ] Build, test, commit

### Task 3.3: pcall/xpcall → recursive call

- [ ] Replace `tryPushBytecodeProtectedCall` with inline `runBytecodeInternal` catch RuntimeError
- [ ] Build, test, commit

---

## Phase 4: Coroutine → Host Recursion

**This is the critical phase for coroutine_yield performance.**

### Task 4.1: Make `error.Yield` propagate through recursive calls

**Key design:** When `coroutine.yield` returns `error.Yield`, it propagates through:
1. `callBuiltin` → OP_CALL handler in `dispatchOneFrame`
2. `dispatchOneFrame` returns `error.Yield` to `runBytecodeInternal`
3. `runBytecodeInternal`'s errdefer checks: if error is Yield AND this is the coroutine boundary → preserve frames (don't pop)
4. `error.Yield` propagates to `builtinCoroutineResume`

- [ ] **Step 1: Modify `runBytecodeInternal` errdefer to preserve frames on Yield**

```zig
fn runBytecodeInternal(...) DispatchError![]Value {
    try self.pushBytecodeExecFrame(...);
    const frame_idx = exec_frames.len() - 1;
    errdefer {
        // On Yield: preserve ALL frames for coroutine resume
        // On RuntimeError: pop only this frame (normal error cleanup)
        if (err != error.Yield) {
            self.popBytecodeExecFrame(exec_frames);
        }
    }
    ...
    return self.dispatchOneFrame(...);
}
```

Wait — Zig's errdefer doesn't have access to the error value. Use a different approach:

```zig
fn runBytecodeInternal(...) DispatchError![]Value {
    try self.pushBytecodeExecFrame(...);
    const result = self.dispatchOneFrame(...);
    if (result) |ret| {
        return ret;
    } else |err| {
        if (err == error.Yield) {
            // Preserve frame for coroutine resume — don't pop
            return err;
        }
        // Normal error — pop frame and propagate
        self.popBytecodeExecFrame(exec_frames);
        return err;
    }
}
```

- [ ] **Step 2: Build and test basic yield**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | tail -3
python3 tools/smoke_compare.py 2>&1 | grep -E "coroutine|FAIL|PASS"
```

- [ ] **Step 3: Commit**

### Task 4.2: Simplify `builtinCoroutineResume` to use recursive call

- [ ] **Step 1: Replace trampoline with direct recursive call**

For the Closure callee path in `builtinCoroutineResume`:
```zig
// BEFORE: driveBytecodeCoroutineTrampoline → frame_loop
// AFTER:
const result = self.runBytecodeInternal(proto, cl.upvalues, rargs, cl) catch |err| switch (err) {
    error.Yield => {
        // Park thread, return yield values
        th.status = .suspended;
        // ... format yield values into outs ...
        return;
    },
    error.RuntimeError => {
        // Format error
        th.status = .dead;
        // ... format error into outs ...
        return;
    },
    else => |e| return e,
};
// Normal return — coroutine completed
th.status = .dead;
// ... format result into outs ...
```

- [ ] **Step 2: Handle resume of already-suspended coroutine**

On re-resume, `runBytecodeInternal` detects `bytecode_inplace_suspended == true` and enters `runBytecodeDispatch` (with `frame_loop`) to walk the preserved frames. This is the ONLY path that uses `frame_loop`.

```zig
fn runBytecodeInternal(...) DispatchError![]Value {
    const th = self.activeBytecodeThread();
    if (th.bytecode_inplace_suspended) {
        // Resume: walk preserved frames via frame_loop
        th.bytecode_inplace_suspended = false;
        return self.runBytecodeDispatch(exec_frames, boundary_depth, ...);
    }
    // Fresh entry: push frame, dispatch one frame (recursive)
    try self.pushBytecodeExecFrame(...);
    // ... dispatchOneFrame ...
}
```

- [ ] **Step 3: Build and test coroutine smoke tests**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | tail -3
# Critical: smoke 36, 37, 49 (coroutine tests)
python3 tools/smoke_compare.py 2>&1 | grep -E "36_|37_|49_"
python3 tools/testes_matrix.py --testc 2>&1 | grep "pass parity"
```

- [ ] **Step 4: Commit**

### Task 4.3: Delete trampoline and coroutine switch machinery

- [ ] **Step 1: Delete `driveBytecodeCoroutineTrampoline` (~190 lines)**

- [ ] **Step 2: Delete `tryRequestBytecodeCoroutineSwitch`, `prepareBytecodeCoroutineSwitch`, `bytecodeCoroutineYieldStep`**

- [ ] **Step 3: Delete `error.ThreadSwitch` signal and all handling**

- [ ] **Step 4: Delete `.coroutine_resume` continuation + `BytecodeCoroutineContinuation`**

- [ ] **Step 5: Delete `coroutine_resume_chain` tracking**

- [ ] **Step 6: Build, full regression, commit**

```bash
zig build -Doptimize=ReleaseFast 2>&1 | tail -3
for i in 1 2; do python3 tools/testes_matrix.py --testc 2>&1 | grep "pass parity"; done
python3 tools/smoke_compare.py 2>&1 | tail -2
python3 tools/leak_bench.py --no-build 2>&1 | tail -3
python3 tools/perf_compare.py --no-build --runs 3 2>&1 | grep -E "geomean|coroutine"
git commit -m "feat(coroutine): host recursion — delete trampoline + ThreadSwitch machinery

Eliminates driveBytecodeCoroutineTrampoline (190 lines), error.ThreadSwitch
signal, and BytecodeCoroutineContinuation. coroutine.yield now propagates
error.Yield through the Zig call stack naturally (like PUC's longjmp)."
```

---

## Phase 5: Cleanup — Delete PendingCallSlot + Simplify Thread

### Task 5.1: Delete PendingCallSlot entirely

- [ ] **Step 1: Verify no remaining callers of pending_call**

```bash
grep -n "pending_call\|PendingCallSlot\|BytecodePendingCall\|BytecodePendingCompletion" src/lua/vm.zig
```

- [ ] **Step 2: Delete PendingCallSlot struct, BytecodePendingCall, BytecodePendingCompletion**

- [ ] **Step 3: Delete `completeBytecodeExecFrame`, `cancelBytecodePendingCall`**

- [ ] **Step 4: Remove `pending_call` field from CallFrame**

- [ ] **Step 5: Build, test, commit**

### Task 5.2: Simplify Thread struct

- [ ] Remove fields that only existed for iterative dispatch:
  - `bytecode_coroutine_switch_request`
  - `capture_yield_id`, `next_yield_id`, `resume_yield_id` (if no longer needed)
  - `wrap_*` fields (evaluate if still needed)
  - `testc_*` fields (evaluate if still needed)
- [ ] Build, test, commit

---

## Phase 6: Zero-Allocation Coroutine Yield/Resume

**Goal:** Eliminate ALL heap allocations from the yield/resume hot path (like PUC's `lua_xmove`).

### Task 6.1: Borrow `resume_inbox` instead of heap-copy

- [ ] Replace `setThreadResumeInbox` (heap alloc + copy) with a pointer + length into the caller's bc_stack. Resume args are already on the caller's register stack — just point to them.

### Task 6.2: Eliminate `yielded` allocation

- [ ] Write yield values directly onto the coroutine's bc_stack (like PUC's stack). The caller reads them from there before the next resume.

### Task 6.3: Eliminate `suspended_builtin_args` allocation

- [ ] Borrow the slice from `active_builtin_args` instead of copying.

### Task 6.4: Verify zero allocations

```bash
python3 tools/leak_bench.py --no-build 2>&1 | tail -3
python3 tools/perf_compare.py --no-build --runs 3 2>&1 | grep "coroutine_yield"
```
Expected: coroutine_yield ≤ 2.5x

---

## Verification Commands

After each task, run ALL of these:

```bash
cd /home/boss/codes/luazig

# 1. Build ReleaseFast
zig build -Doptimize=ReleaseFast 2>&1 | tail -3

# 2. Matrix (run twice for stability)
for i in 1 2; do python3 tools/testes_matrix.py --testc 2>&1 | grep "pass parity"; done

# 3. Smoke (all must pass)
python3 tools/smoke_compare.py 2>&1 | tail -2

# 4. Leakbench (all within 1KB)
python3 tools/leak_bench.py --no-build 2>&1 | tail -3

# 5. Perf (geomean + key workloads)
python3 tools/perf_compare.py --no-build --runs 3 2>&1 | grep -E "geomean|coroutine|lua_calls|metamethod"
```

## Expected Results After All Phases

| Metric | Current | Target |
|---|---|---|
| coroutine_yield | 3.87x | ~2.5x |
| lua_calls | 3.72x | ~3.0x |
| metamethod_add | 3.56x | ~2.5x |
| geomean | 2.70x | ~2.3x |
| CallFrame size | ~1200B | ~430B |
| PendingCallSlot | 768B/frame | eliminated |
| vm.zig lines | 33.5K | ~31K |
| Yield allocs | 5-7 | 0 |
