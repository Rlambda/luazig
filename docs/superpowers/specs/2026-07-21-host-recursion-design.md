# Spec: PUC-faithful host recursion — eliminate iterative dispatch + PendingCallSlot

**Date:** 2026-07-21
**Status:** Draft
**Goal:** Replace the iterative dispatch loop (`frame_loop` + `PendingCallSlot`) with PUC-style host recursion. Eliminate `PendingCallSlot` (768B/frame) entirely. Shrink `CallFrame` from ~1200B to ~430B. Enable Phase C (inline array).

## Background

### Current architecture (P15.13–P15.40b)

`runBytecodeInternal` enters `runBytecodeDispatch`, which loops over frames via `frame_loop: while`. When OP_CALL is dispatched:
1. `pushBytecodeExecFrame` pushes a child frame onto `Thread.call_frames`
2. `pending_call.set(.{ .results = ... })` records the continuation on the parent
3. `continue :frame_loop` enters the child frame
4. When the child hits OP_RETURN, `completeBytecodeExecFrame` reads `pending_call`, dispatches to the matching `applyBytecodePending*` helper, stores results, advances parent PC

Metamethods (`__add`, `__index`, ...), debug hooks, `__close`, `pcall` targets, `string.gsub` callbacks, and `coroutine.resume` all follow the same pattern: push a child frame + set a continuation.

`PendingCallSlot` = `active: bool` + `payload: BytecodePendingCall` (768B). The payload is a tagged union with 9 variants. The hot/cold split (`active` byte vs `payload` bytes) was added in P15.37a to avoid a 768-byte memset on every frame push/return.

### PUC Lua architecture

PUC uses host recursion for ALL calls. `luaV_execute` contains the main interpreter loop. When OP_CALL is dispatched:
1. `luaD_precall` sets up the child `CallInfo`
2. `luaV_execute` is called recursively for the child
3. When the child returns, the recursive call returns the results
4. The parent `luaV_execute` continues from the next instruction

No continuation objects, no explicit frame stack switching. The C stack IS the continuation. `CallInfo` is ~48 bytes with no continuation payload.

C call depth is limited by `LUAI_MAXCCALLS = 200`. Each Lua call adds ~100B of C stack. 200 × 100B = 20KB, trivially within the default 8MB stack.

### Why luazig diverged

Before P15.13, luazig used host recursion WITHOUT a C call depth limit. Lua programs could recurse arbitrarily deep, causing C stack overflow. The workaround was `std.Thread.spawn(.{ .stack_size = 256MB })`. P15.13 replaced host recursion with iterative dispatch, eliminating the 256MB hack. P15.25 extended iterative dispatch to metamethods/hooks/closers, creating `PendingCallSlot`.

### Why we can return now

The C call depth limit already exists: `lua_max_call_frames = 6000` (1000 in error handler). At ~270B per C stack frame (Debug build), 6000 × 270B = 1.6MB — comfortably within the default 8MB stack. No 256MB hack needed.

---

## Design

### Core change: `runBytecodeDispatch` handles ONE frame

Currently `runBytecodeDispatch` loops over frames via `frame_loop`. After this change, it handles exactly ONE frame. Child calls are recursive `runBytecodeInternal` calls.

```zig
fn runBytecodeInternal(self: *Vm, proto, upvalues, args, callee_cl) DispatchError![]Value {
    const exec_frames = &self.activeBytecodeThread().call_frames;
    try self.pushBytecodeExecFrame(exec_frames, proto, upvalues, args, callee_cl);
    defer self.popBytecodeExecFrame(exec_frames);

    // Dispatch ONE frame. Child calls are recursive.
    return self.dispatchOneFrame(exec_frames);
}

fn dispatchOneFrame(self: *Vm, exec_frames: *ArrayListUnmanaged(CallFrame)) DispatchError![]Value {
    const frame_index = exec_frames.items.len - 1;
    // Load frame state into locals (pc, base, regs, etc.)
    // ... existing dispatch loop, but NO frame_loop ...
    while (pc < cur_proto.code.len) {
        // ... opcode handlers ...
        .call => {
            // Recursive call — results returned directly
            const ret = try self.runBytecodeInternal(proto2, cl.upvalues, rargs, cl);
            // Store results inline
            // No pending_call needed!
        }
        .return_ => {
            // Return from this frame
            return results;
        }
    }
}
```

### OP_TAILCALL: frame replacement, no C stack growth

OP_TAILCALL replaces the current frame with the callee and continues the dispatch loop. This does NOT add a C stack frame — the tail call reuses the current `dispatchOneFrame` call.

```zig
.tailcall => {
    // Pop current frame's varargs/tbc, then re-push with new proto
    // (existing bcGrowFrame + frame reuse logic)
    // Continue the dispatch loop with the new function
    cur_proto = new_proto;
    pc = 0;
    // ... no recursive call, no C stack growth ...
}
```

This mirrors PUC's `luaD_pcall` → `luaV_execute` OP_TAILCALL handling: the current `CallInfo` is reused for the new function.

### Metamethods: host recursion

When OP_ADD encounters a table operand and `__add` is a bytecode closure:
```zig
// BEFORE (iterative + PendingCallSlot):
if (try self.tryPushBytecodeMetamethod(exec_frames, frame_index, meta, "__add", args, .{ .value = .{ .dst = a } })) {
    continue :frame_loop;  // enter metamethod child
}
// AFTER child returns: applyBytecodePendingValue stores result at regs[a]

// AFTER (host recursion):
const ret = try self.callBytecodeFunction(meta_closure, args);
regs[a] = ret[0];  // result available inline
```

`callBytecodeFunction` is a thin wrapper around `runBytecodeInternal`:
```zig
fn callBytecodeFunction(self: *Vm, cl: *Closure, args: []const Value) DispatchError![]Value {
    const proto = cl.proto orelse return self.runClosure(cl, args, false);
    return self.runBytecodeInternal(proto, cl.upvalues, args, cl);
}
```

### Debug hooks: host recursion

When a line/count hook fires and the hook is a bytecode closure:
```zig
// BEFORE: tryPushBytecodeDebugHook pushes a frame + .hook continuation
// AFTER:
const hook_ret = try self.runBytecodeInternal(hook_proto, hook_upvalues, hook_args, hook_cl);
// Hook returned — no continuation processing needed
// Apply skip flags inline
```

### `__close`: host recursion

When a TBC variable's `__close` metamethod is a bytecode closure:
```zig
// BEFORE: beginBytecodeClose + continueBytecodeClose + .close continuation
// AFTER:
const close_ret = try self.callBytecodeFunction(close_cl, close_args);
// __close returned — continue scanning TBC slots inline
```

### `pcall`/`xpcall`: host recursion

Already partially host-recursive via `builtinPcall`/`builtinXpcall`. The `tryPushBytecodeProtectedCall` path (iterative pcall target) becomes:
```zig
// BEFORE: tryPushBytecodeProtectedCall pushes target + .results + .protection
// AFTER:
const result = self.runBytecodeInternal(target_proto, ...) catch |err| switch (err) {
    error.RuntimeError => { /* return false, err_obj */ },
    else => |e| return e,
};
// Return true, result
```

Error handling via `catch` — no continuation needed.

### Coroutine yield

`error.Yield` propagates through the C call stack. Already works for builtins (`coroutine.yield` called via `callBuiltin`). With host recursion, ALL yield paths go through C stack propagation.

`coroutine.resume` calls `runBytecodeInternal` for the coroutine's function. If it yields, `error.Yield` propagates up to `builtinCoroutineResume`, which catches it and parks the thread.

### What gets eliminated

| Component | Size | Disposition |
|---|---|---|
| `PendingCallSlot` | 768B | **Deleted entirely** |
| `BytecodePendingCall` | 760B | **Deleted** |
| `BytecodePendingCompletion` (9 variants) | ~700B | **Deleted** |
| `PendingCallSlot` field on `CallFrame` | 769B | **Deleted** |
| `tryPushBytecodeContinuationCall` | — | **Deleted** (replaced by `callBytecodeFunction`) |
| `tryPushBytecodeMetamethod` | — | **Deleted** (inline `callBytecodeFunction`) |
| `tryPushBytecodeDebugHook` | — | **Deleted** (inline `callBytecodeFunction`) |
| `tryPushBytecodeProtectedCall` | — | **Deleted** (inline `runBytecodeInternal`) |
| `completeBytecodeExecFrame` | — | **Deleted** (frame pop is `defer popBytecodeExecFrame`) |
| `applyBytecodePendingResults` | — | **Deleted** (inline result storage) |
| `applyBytecodePendingValue/Ignore/Compare/Concat/Gsub/Hook/Close` | — | **Deleted** (inline) |
| `cancelBytecodePendingCall` | — | **Deleted** (no pending state to cancel) |
| `beginBytecodeClose` / `continueBytecodeClose` | — | **Rewritten** (inline loop with `callBytecodeFunction`) |
| `applyBytecodePendingHook` | — | **Deleted** (inline after hook returns) |
| `startBytecodePendingCall` | — | **Deleted** (already dead code) |
| `tryRequestBytecodeCoroutineSwitch` | — | **Rewritten** (direct `runBytecodeInternal` on target thread) |
| `driveBytecodeCoroutineTrampoline` | — | **Simplified** (no trampoline needed — direct recursive call) |

### What stays

- `Thread.call_frames` (ArrayListUnmanaged) — still the authoritative frame stack
- `pushBytecodeExecFrame` / `popBytecodeExecFrame` — still push/pop frames
- `ensureBcStackCap` / `bcGrowFrame` — still manage register windows
- GC scanning of `Thread.call_frames` — unchanged
- `ensureBcStackCap` walk of `Thread.call_frames` — unchanged
- All debug API (`debug.getinfo`, `debug.getlocal`, etc.) — unchanged
- Coroutine park/resume (`parkActiveRuntime`/`activateRuntime`) — unchanged

### C call depth management

The existing `lua_max_call_frames = 6000` check in `pushBytecodeExecFrame` stays. It now doubles as the C call depth limit: each recursive `runBytecodeInternal` call pushes one frame, so `exec_frames.items.len` == C call depth.

At ~270B per C stack frame (Debug), 6000 × 270B = **1.6MB**. The default 8MB stack has 5× headroom.

For ReleaseFast, C frames are smaller (~150B), giving even more headroom.

### `completeBytecodeExecFrame` removal

Currently, `completeBytecodeExecFrame` is the central dispatch point where returning child frames are reunited with parents. With host recursion, this is unnecessary:

- OP_RETURN formats the return values into a slice on `bc_stack`
- `closeBytecodeUpvaluesFrom` closes open upvalues of the returning frame
- `defer popBytecodeExecFrame` pops the frame (runs when `dispatchOneFrame` returns)
- `dispatchOneFrame` returns the values slice to the caller
- The caller (parent's OP_CALL handler) stores results inline (no dispatch)

The "return" debug hook fires inline before `dispatchOneFrame` returns:
```zig
.return_ => {
    // Format return values
    const results = regs[a..a+nresults];
    // Dispatch "return" hook if active
    if (hooks_active) try self.dispatchReturnHook(...);
    // Close upvalues
    try self.closeBytecodeUpvaluesFrom(exec_frames, frame_index, 0);
    return results;  // defer popBytecodeExecFrame runs here
}
```

The entire `completeBytecodeExecFrame` function (~100 lines) and all `applyBytecodePending*` helpers are deleted.

### `BytecodePendingCompletion` → inline code

Each continuation variant becomes inline code at the call site:

| Variant | Where (inline) | What it does |
|---|---|---|
| `.results` | OP_CALL/OP_TFORCALL handler | `ret = runBytecodeInternal(...); store ret at regs[dst..]` |
| `.value` | metamethod handler (OP_ADD etc.) | `ret = callBytecodeFunction(...); regs[a] = ret[0]` |
| `.ignore` | `__len`/`__tostring` | `ret = callBytecodeFunction(...); discard` |
| `.compare` | OP_LT/OP_LE/OP_GT | `ret = callBytecodeFunction(...); result = ret[0] != .Nil` |
| `.concat` | OP_CONCAT loop | Loop: `ret = callBytecodeFunction(...); accumulate` |
| `.gsub` | string.gsub replacement | Loop: `ret = callBytecodeFunction(...); build result` |
| `.hook` | line/count/call hook | `ret = runBytecodeInternal(hook...); apply skip flags` |
| `.close` | TBC closer scan | Loop: `ret = callBytecodeFunction(...); next TBC slot` |
| `.coroutine_resume` | coroutine.resume | `ret = runBytecodeInternal(target...); wrap results` |

---

## Risk analysis

### 1. C stack overflow
- **Risk:** Deep Lua recursion exhausts 8MB C stack
- **Mitigation:** `lua_max_call_frames = 6000` limits depth. 6000 × 270B = 1.6MB < 8MB. PUC uses 200.
- **Verification:** `cstack.lua` test must pass. Stress test with 1MB stack (existing `iterative_dispatch_stress.sh`).

### 2. Coroutine yield across C boundary
- **Risk:** `error.Yield` must propagate through recursive C calls correctly
- **Mitigation:** Already works for builtins (`coroutine.yield` via `callBuiltin`). Same mechanism.
- **Verification:** `coroutine.lua` + smoke 36/37 must pass.

### 3. Error handling across C boundary
- **Risk:** Runtime errors must propagate through recursive C calls
- **Mitigation:** Already works for builtins (`pcall`/`xpcall`). `error.RuntimeError` propagates through `catch`.
- **Verification:** `errors.lua` must pass.

### 4. GC correctness
- **Risk:** GC must see all frames on the C stack during recursive calls
- **Mitigation:** `Thread.call_frames` (heap-resident) always has ALL frames. GC scans `Thread.call_frames`. C stack only holds locals (copies of frame data), not GC roots.
- **Verification:** GC smoke tests (34, 36, 37, 43) must pass.

### 5. Debug API correctness
- **Risk:** `debug.getinfo(level)` must walk the C call stack correctly
- **Mitigation:** Already walks `Thread.call_frames` (heap-resident). C recursion doesn't change this.
- **Verification:** `db.lua` + smoke 31 must pass.

### 6. Performance regression
- **Risk:** C function call overhead per OP_CALL (~50-100ns)
- **Mitigation:** Eliminated PendingCallSlot operations (set/clear/apply per call). Net change likely neutral or positive.
- **Verification:** `perf_compare.py` — `lua_calls` within ±3% of current.

---

## Migration strategy

This is a large refactor (~500-800 lines of net deletion). The migration should be done in phases:

### Phase 1: OP_CALL → host recursion
- Replace the OP_CALL iterative path with recursive `runBytecodeInternal`
- Delete `.results` continuation + `applyBytecodePendingResults`
- Keep iterative dispatch for metamethods/hooks/closers (temporary)
- Verify: smoke tests, matrix

### Phase 2: Metamethods → host recursion
- Replace `tryPushBytecodeMetamethod` with inline `callBytecodeFunction`
- Delete `.value`/`.ignore`/`.compare`/`.concat`/`.gsub` variants
- Delete `tryPushBytecodeContinuationCall`, `tryPushBytecodeMetamethod`
- Verify: smoke tests, matrix

### Phase 3: Hooks/closers → host recursion
- Replace `tryPushBytecodeDebugHook` with inline `runBytecodeInternal`
- Replace `beginBytecodeClose`/`continueBytecodeClose` with inline loop
- Delete `.hook`/`.close` variants
- Verify: smoke tests, matrix

### Phase 4: pcall/coroutine → host recursion
- Replace `tryPushBytecodeProtectedCall` with inline `runBytecodeInternal`
- Replace `tryRequestBytecodeCoroutineSwitch` with direct recursive call
- Delete `.coroutine_resume` variant + remaining `BytecodeProtectedCall`
- Delete `PendingCallSlot`, `BytecodePendingCall`, `BytecodePendingCompletion`
- Verify: smoke tests, matrix

### Phase 5: Cleanup
- Remove `frame_loop` from `runBytecodeDispatch` (now single-frame)
- Remove `completeBytecodeExecFrame` (now `defer popBytecodeExecFrame`)
- Remove `cancelBytecodePendingCall`
- Update README
- Verify: full regression + perf

---

## Expected impact

| Metric | Before | After | Delta |
|---|---|---|---|
| CallFrame size | ~1200B | ~430B | −64% |
| PendingCallSlot | 768B/frame | 0 | eliminated |
| `frame_loop` complexity | ~2000 lines | 0 | eliminated |
| C call depth limit | 6000 (heap) | 6000 (C stack) | same |
| `lua_calls` perf | baseline | ±3% | neutral |

After this change, Phase C (inline `[32]CallFrame` in Thread) becomes feasible:
32 × 430B = **13.7KB** per Thread (was 32 × 1200B = 38.4KB — too much).

## PUC references

- `luaV_execute` — lvm.c:414-824 (single-frame interpreter loop, recursive calls via `luaD_precall`)
- `luaD_precall` — ldo.c:222-326 (call setup, C call depth check via `getCcalls`)
- `LUAI_MAXCCALLS` — ldo.h:18 (`#define LUAI_MAXCCALLS 200`)
- `CallInfo` — lstate.h:187-209 (~48 bytes, no continuation payload)
- OP_TAILCALL — lvm.c:744-766 (frame reuse, no recursive call)
