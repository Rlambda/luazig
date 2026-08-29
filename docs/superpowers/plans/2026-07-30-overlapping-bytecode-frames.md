# PUC-Faithful Overlapping Bytecode Frames Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace non-overlapping bytecode frames with PUC Lua's overlapping frame model so that stack overflow behavior, recursion depth, and `cstack.lua` tests match PUC Lua.

**Architecture:** PUC Lua places each new call frame starting at the caller's register `A+1` (where the function + args already live), so frames overlap — the callee reuses the caller's register space above the call site. This gives ~1-3 slots of stack growth per recursive call (vs our current ~20+ slots), and the overflow check uses the actual call position (`caller_base + A + 1 + frame_cap > MAXSTACK`) instead of the accumulated frame capacity. The change centers on `pushBytecodeExecFrame` (new `base` computation), `popBytecodeExecFrame` (new `bc_stack_top` restore), varargs elimination (args already in place), and `shrinkBcStack` (walk frames like PUC's `stackinuse`).

**Tech Stack:** Zig (`vm.zig` ~31k lines), PUC Lua 5.5.0 reference (`ldo.c`, `lvm.c`, `ltm.c`)

---

## Background: Why This Change Is Needed

### Current model (non-overlapping frames)

```
bc_stack: [caller regs 0..frame_cap-1] [varargs] [callee regs 0..frame_cap-1] ...
                                          ^         ^
                                   bc_stack_top    base = bc_stack_top + nextra
                                                   bc_stack_top = base + frame_cap
```

Each frame is placed **above** the previous frame's full register window. Arguments are **copied** from caller's registers into the callee's fresh register block. Varargs are stored in a separate region below `base`.

**Problem 1:** Stack grows by `frame_cap` (~20-25 slots) per recursive call. PUC grows by `A+1` (~1-3 slots). This is a ~10-20x difference in recursion depth.

**Problem 2:** Overflow check uses `bc_stack_top` (accumulated frame capacity), while PUC uses `L->top.p` (actual call position = `func + 1 + nargs`). Our check triggers overflow at a different depth than PUC, breaking `cstack.lua` "testing stack recovery".

**Problem 3:** Varargs require a separate below-`base` region and explicit copy, adding complexity and per-call overhead.

### PUC model (overlapping frames)

```
bc_stack: [caller regs 0..A-1] [func | arg1 arg2 ... argN | .......... callee regs .......... ]
                                  ^     ^                                                     ^
                            func slot   base = func + 1                              base + frame_cap
```

The callee's `base` is `caller_base + A + 1` — right where the function and args already sit in the caller's registers. No arg copy. The callee's registers extend from `base` to `base + frame_cap`, overlapping the caller's registers `[A+1 .. caller_frame_cap]` (which are dead during the callee's execution).

Stack growth per recursive call: `A + 1 + frame_cap - caller_frame_cap`. For self-recursion with `A=0`, this is `1 + frame_cap - frame_cap = 1` slot.

---

## File Structure

All changes are in a single file:

- **Modify:** `src/lua/vm.zig` — the bytecode VM (~31k lines)

No new files. No changes to `build.zig`, headers, or test infrastructure.

### Key code regions in `vm.zig`:

| Region | Lines (approx) | Responsibility |
|--------|-----------------|----------------|
| `CallFrame` struct | 986-1062 | Frame fields including `base`, `frame_cap`, `nextraargs` |
| `ensureBcStackCap` | 2682-2721 | Grow `bc_stack`, refresh frame slices |
| `shrinkBcStack` | 2741-2777 | Shrink `bc_stack` after overflow recovery |
| `bcGrowFrame` | 2786-2819 | Grow a single frame's capacity |
| `frameVarargs` | 2578-2583 | Derive varargs slice from frame |
| `pushBytecodeExecFrame` | 6480-6653 | **Core change:** new `base` computation |
| `popBytecodeExecFrame` | 6655-6679 | **Core change:** `bc_stack_top` restore |
| `completeBytecodeExecFrame` | 6681-6791 | Return value placement |
| `BytecodeDispatchCtx` | 7046-7079 | Dispatch loop cached state |
| `runBytecodeInternal` | 6883-7008 | Host-recursion entry point |
| `opVararg` | 9452-9489 | OP_VARARG handler |
| `opTailcall` | 9896-10216 | OP_TAILCALL handler |
| `opCall` | 10232-10600 | OP_CALL handler |
| `gcMarkMutableRoots` | 14084-14132 | GC scanning of bc_stack frames |
| `builtinTestcStacklevel` | 27357-27387 | T.stacklevel() debug introspection |

---

## Task 1: Add `func_slot` field to `CallFrame` and `BytecodeDispatchCtx`

This field stores the bc_stack index of the function value for the current frame — PUC's `ci->func` equivalent. It's the foundation for all subsequent changes.

**Files:**
- Modify: `src/lua/vm.zig:986-1062` (CallFrame struct)
- Modify: `src/lua/vm.zig:7046-7079` (BytecodeDispatchCtx struct)

- [ ] **Step 1: Add `func_slot` to `CallFrame`**

In `src/lua/vm.zig`, find the `CallFrame` struct (line ~998, after `base: usize = 0`):

```zig
    // ── Bytecode-specific (valid when proto != null) ──
    activation_id: usize = 0,
    base: usize = 0,
    /// PUC `ci->func` equivalent: bc_stack index of the function value.
    /// `base = func_slot + 1` for bytecode frames. The function value
    /// at `bc_stack[func_slot]` is preserved for debug.getinfo and return
    /// value placement.
    func_slot: usize = 0,
    frame_cap: usize = 0,
```

- [ ] **Step 2: Add `func_slot` to `BytecodeDispatchCtx`**

In `src/lua/vm.zig`, find the `BytecodeDispatchCtx` struct (line ~7056, after `base: usize`):

```zig
    base: usize,
    /// PUC `ci->func` equivalent — bc_stack index of the function value.
    func_slot: usize,
    frame_cap: usize,
```

- [ ] **Step 3: Build to verify compilation**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: BUILD OK (the new fields default to 0, existing code doesn't set them yet)

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "add func_slot field to CallFrame and BytecodeDispatchCtx

Preparation for overlapping frames: func_slot stores the bc_stack index
of the function value (PUC ci->func equivalent). Unused in this commit."
```

---

## Task 2: Change `pushBytecodeExecFrame` to overlapping base

This is the core change. The new frame's `base` is computed from the caller's register position where the function sits, not from `bc_stack_top + nextra`.

**Files:**
- Modify: `src/lua/vm.zig:6480-6653` (`pushBytecodeExecFrame`)

The function currently receives `args: []const Value` — a slice that may point into `bc_stack` (from OP_CALL) or into a heap array (from `runBytecodeInternal` / `builtinPcall`).

For the overlapping model, we need to know WHERE in the caller's registers the function + args sit. This is `caller_base + A` where `A` is the OP_CALL register operand.

**New parameter:** `caller_func_slot: usize` — the bc_stack index where the function value sits. For OP_CALL, this is `ctx.base + a`. For `runBytecodeInternal` (host recursion), this is `bc_stack_top` (the function goes at the current top).

- [ ] **Step 1: Add `caller_func_slot` parameter to `pushBytecodeExecFrame`**

Change the signature at `vm.zig:6480`:

```zig
    fn pushBytecodeExecFrame(
        self: *Vm,
        exec_frames: *FrameStack,
        proto: *const bc.Proto,
        upvalues: []const *Cell,
        args: []const Value,
        callee_cl: ?*Closure,
        caller_func_slot: usize,
    ) DispatchError!void {
```

- [ ] **Step 2: Compute overlapping `base` and `func_slot`**

Replace the varargs-write + base-computation block (lines ~6560-6575). The new code:

```zig
        // ── PUC-faithful overlapping frame placement ──
        // PUC luaD_precall: ci->func = func (the function slot in the
        // caller's registers), ci->top = func + 1 + fsize. The callee's
        // base = func + 1. Arguments are already at func+1..func+nargs
        // in the caller's registers — no copy needed.
        //
        // For host-recursion calls (runBytecodeInternal, builtinPcall),
        // caller_func_slot = bc_stack_top (the function will be placed
        // at the current top, args follow). This path DOES need to write
        // the function + args into bc_stack because they may come from
        // a heap slice.

        const func_slot = caller_func_slot;
        const base = func_slot + 1;
        // frame_cap is proto.maxstacksize + EXTRA_MARGIN (unchanged).
        // The overflow check now uses func_slot + 1 + frame_cap (PUC model)
        // instead of bc_stack_top + nextra + frame_cap.

        // Check if args already live on bc_stack at func_slot+1.
        // This is the OP_CALL fast path — args are caller's regs[A+1..].
        const args_on_stack = blk: {
            const args_ptr = @intFromPtr(args.ptr);
            const bc_ptr = @intFromPtr(self.bc_stack.ptr);
            const expected = bc_ptr + (func_slot + 1) * @sizeOf(Value);
            break :blk args_ptr == expected;
        };

        if (!args_on_stack) {
            // Host-recursion path: write function + args into bc_stack
            // at func_slot. This is the pcall/runBytecodeInternal case
            // where args may come from a heap slice.
            // First ensure capacity for func + args + frame_cap.
            try self.ensureBcStackCap(func_slot + 1 + args.len + frame_cap);
            // Re-derive nothing — we just ensured capacity, no realloc
            // concern for the writes below since we ensured enough space.
            // Write function value.
            self.bc_stack[func_slot] = if (callee_cl) |cl|
                .{ .Closure = cl }
            else
                .Nil;
            // Write args.
            for (0..args.len) |i| {
                self.bc_stack[func_slot + 1 + i] = args[i];
            }
        }
```

- [ ] **Step 3: Change overflow check and bc_stack_top**

Replace the old overflow check and bc_stack_top setting. The old code was:

```zig
        const total_needed = nextra + frame_cap;
        if (exec_frames.len() >= lua_max_call_frames or
            total_needed > lua_stack_overflow_limit -| self.bc_stack_top) {
```

New overflow check (PUC model):

```zig
        // PUC checkstackp: func_slot + 1 + frame_cap must fit.
        const needed_top = base + frame_cap; // = func_slot + 1 + frame_cap
        if (exec_frames.len() >= lua_max_call_frames or
            needed_top > lua_stack_overflow_limit) {
            const PHYSICAL_LIMIT: usize = lua_max_stack_slots + ERRORSTACKSIZE;
            if (self.bc_stack.len < PHYSICAL_LIMIT) {
                self.ensureBcStackCap(PHYSICAL_LIMIT) catch {};
            }
            return self.fail("stack overflow error", .{});
        }
```

Set `bc_stack_top` to the new frame's top (this is the high-water for capacity):

```zig
        // Ensure bc_stack has room for the full frame.
        try self.ensureBcStackCap(needed_top);

        const old_stack_top = self.bc_stack_top;
        self.bc_stack_top = needed_top;
        errdefer self.bc_stack_top = old_stack_top;
```

- [ ] **Step 4: Remove varargs copy and arg copy**

The old code copied varargs into `bc_stack[va_start..]` and copied args into `regs[0..ncopy]`. With overlapping frames, args are already in place. But we need to nil-fill missing parameters (PUC pads with nil).

Replace the old arg-copy block (lines ~6576-6581) with:

```zig
        const regs = self.bc_stack[base .. base + frame_cap];
        const boxed = self.bc_boxed[base .. base + frame_cap];
        // PUC luaD_precall: nil-fill missing fixed parameters.
        // Args are already in regs[0..nargs] (either from caller's
        // registers or from the host-recursion write above).
        // For vararg functions, extra args beyond numparams become
        // varargs — they're accessible via OP_VARARG.
        const nactual_args: usize = if (args_on_stack)
            args.len  // args already in place at func_slot+1
        else
            args.len; // we just wrote them
        const ncopy = @min(nparams, nactual_args);
        // Nil-fill missing parameters (PUC luaD_precall behavior).
        for (ncopy..nparams) |i| regs[i] = .Nil;
```

- [ ] **Step 5: Set `func_slot` and `nextraargs` on the frame**

In the frame field-writing block (lines ~6622-6625), update:

```zig
        ef_slot.base = base;
        ef_slot.func_slot = func_slot;
        ef_slot.frame_cap = frame_cap;
        // PUC nextraargs: varargs are args beyond numparams, stored
        // at func_slot + 1 + numparams .. func_slot + 1 + nactual_args.
        // They're accessed relative to func_slot, not relative to base.
        ef_slot.nextraargs = if (proto.is_vararg and nactual_args > nparams)
            @intCast(nactual_args - nparams)
        else
            0;
```

- [ ] **Step 6: Update all callers of `pushBytecodeExecFrame`**

Find ALL call sites and add the `caller_func_slot` argument:

**Site 1: `opCall` at `vm.zig:10519`** — bytecode-to-bytecode call:

```zig
                    try self.pushBytecodeExecFrame(
                        ctx.exec_frames, proto2, cl.upvalues, rargs, cl,
                        ctx.base + a,  // func at caller's register A
                    );
```

**Site 2: `runBytecodeInternal` at `vm.zig:6918`** — host recursion:

```zig
        try self.pushBytecodeExecFrame(
            exec_frames, proto_in, upvalues_in, args, effective_callee,
            self.bc_stack_top,  // function goes at current top
        );
```

**Site 3: `tryPushBytecodeProtectedCall` at `vm.zig:6034`** — protected call fast path. Find the `pushBytecodeExecFrame` call and add `caller_func_slot`. This call passes `child_args` which come from the dispatch loop — the func is at `ctx.base + a`:

```zig
        try self.pushBytecodeExecFrame(
            exec_frames, proto, cl.upvalues, child_args, cl,
            parent_base + parent_a,  // func at caller's register
        );
```

You need to pass `parent_base` and `parent_a` through from the dispatch loop. Check the function signature and callers.

**Site 4: Any other callers** — search for `pushBytecodeExecFrame` calls:

Run: `grep -n "pushBytecodeExecFrame" src/lua/vm.zig | grep -v "fn pushBytecode"`

Every call site needs the new argument.

- [ ] **Step 7: Update `opTforcall`**

Find the `pushBytecodeExecFrame` call in `opTforcall` and add the func slot argument. The TFORCALL sets up iterator function and state in specific registers.

- [ ] **Step 8: Build and fix compilation errors**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -20`
Expected: May have errors in callers that need updating. Fix each one.

- [ ] **Step 9: Run basic smoke tests**

Run: `for f in tests/smoke/*.lua; do timeout 5 zig-out/bin/luazig "$f" 2>&1 | tail -1; done | grep -c "."`

Expected: Same count as before (basic functionality should work — we haven't changed varargs access yet, which may cause issues for vararg functions).

- [ ] **Step 10: Commit**

```bash
git add src/lua/vm.zig
git commit -m "overlapping frames: change pushBytecodeExecFrame base computation

PUC-faithful frame placement: new frame's base = caller_base + A + 1,
where A is the OP_CALL register operand. Args are already in place at
the caller's registers — no arg copy needed.

Overflow check now uses func_slot + 1 + frame_cap (PUC model) instead
of accumulated bc_stack_top + nextra + frame_cap.

This is the core architectural change. Varargs access and frame popping
still need updating (subsequent tasks)."
```

---

## Task 3: Change `popBytecodeExecFrame` to restore overlapping `bc_stack_top`

With overlapping frames, popping restores `bc_stack_top` to the caller's frame capacity, not `frame.base - frame.nextraargs`.

**Files:**
- Modify: `src/lua/vm.zig:6655-6679` (`popBytecodeExecFrame`)

- [ ] **Step 1: Change `bc_stack_top` restore**

The old code:
```zig
        self.bc_stack_top = frame.base - frame.nextraargs;
```

New code — restore to the caller's frame capacity. The caller is the frame below us in `exec_frames`:

```zig
        // PUC model: restore bc_stack_top to the caller's frame capacity.
        // With overlapping frames, the callee's base was inside the caller's
        // register space. After popping, bc_stack_top should be the caller's
        // base + caller's frame_cap (i.e., where it was before the call).
        if (idx > 0) {
            const caller = exec_frames.getConstPtr(idx - 1);
            self.bc_stack_top = caller.base + caller.frame_cap;
        } else {
            // No caller — reset to initial state.
            self.bc_stack_top = 0;
        }
```

- [ ] **Step 2: Build**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: BUILD OK

- [ ] **Step 3: Run smoke tests**

Run: `for f in tests/smoke/*.lua; do timeout 5 zig-out/bin/luazig "$f" 2>&1 | tail -1; done | grep -c "."`
Expected: Same or better than before

- [ ] **Step 4: Run regression matrix**

Run: `python3 tools/testes_matrix.py --timeout 30 2>&1 | head -5`
Expected: May have regressions — record the count and which files fail

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "overlapping frames: fix popBytecodeExecFrame bc_stack_top restore

Restore bc_stack_top to caller's frame capacity after frame pop,
matching PUC's call-stack unwind model."
```

---

## Task 4: Update varargs access for overlapping frames

With overlapping frames, varargs are the extra arguments already sitting at `func_slot + 1 + numparams .. func_slot + 1 + nargs`. No separate region below base.

**Files:**
- Modify: `src/lua/vm.zig:2578-2583` (`frameVarargs`)
- Modify: `src/lua/vm.zig:9452-9489` (`opVararg`)
- Modify: `src/lua/vm.zig:14084-14132` (GC varargs scan)

- [ ] **Step 1: Change `frameVarargs`**

Replace the old function:

```zig
    fn frameVarargs(self: *Vm, frame: *const CallFrame) []Value {
        if (frame.proto != null and frame.nextraargs != 0) {
            // PUC model: varargs live at func_slot + 1 + numparams,
            // extending nextraargs slots. They're part of the caller's
            // argument region (overlapping frames).
            const nparams = frame.proto.?.numparams;
            const va_start = frame.func_slot + 1 + nparams;
            return self.bc_stack[va_start .. va_start + frame.nextraargs];
        }
        return frame.varargs;
    }
```

- [ ] **Step 2: Update `opVararg` handler**

The OP_VARARG handler reads varargs from `ctx.base - ctx.nextraargs`. Change to use `func_slot`:

Find the varargs slice computation in `opVararg` (~line 9459) and change:

```zig
        // PUC model: varargs at func_slot + 1 + numparams.
        const nparams = ctx.cur_proto.numparams;
        const va_start = ctx.func_slot + 1 + nparams;
        const va = self.bc_stack[va_start .. va_start + ctx.nextraargs];
```

- [ ] **Step 3: Update `BytecodeDispatchCtx` initialization**

Ensure `func_slot` is loaded when entering a frame. Search for where `ctx.base` is set from a frame (the `startfunc` / `reloadFrame` logic in the dispatch loop) and add `ctx.func_slot = frame.func_slot`.

- [ ] **Step 4: Update GC varargs scan**

In `gcMarkMutableRoots` (~line 14117), the old code scanned:
```zig
        const va = self.bc_stack[frame.base - frame.nextraargs .. frame.base];
```

Change to:
```zig
        if (frame.proto != null and frame.nextraargs != 0) {
            const nparams = frame.proto.?.numparams;
            const va_start = frame.func_slot + 1 + nparams;
            const va = self.bc_stack[va_start .. va_start + frame.nextraargs];
            for (va) |value| try self.gcMarkValue(value);
        }
```

Apply the same change to the parked-coroutine GC scan (~line 15284).

- [ ] **Step 5: Build and test**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Run: `for f in tests/smoke/*.lua; do timeout 5 zig-out/bin/luazig "$f" 2>&1 | tail -1; done | grep -c "."`
Run: `python3 tools/testes_matrix.py --timeout 30 2>&1 | head -5`

Expected: Vararg functions should now work correctly with overlapping frames.

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig
git commit -m "overlapping frames: update varargs access to use func_slot

Varargs now live at func_slot + 1 + numparams (within the caller's
argument region) instead of a separate region below base. Updates
frameVarargs, opVararg, and GC scanning."
```

---

## Task 5: Update `opTailcall` for overlapping frames

The tail-call handler currently shifts `base` when `new_nextra > old_nextra`. With overlapping frames, the tail-call should reuse the caller's `func_slot` — PUC copies the function + args down to `ci->func`.

**Files:**
- Modify: `src/lua/vm.zig:9896-10216` (`opTailcall`)

- [ ] **Step 1: Simplify tail-call frame reuse**

PUC `luaD_pretailcall` copies `func + args` down to `ci->func`, then reuses the same `ci`. In our model, the tail call should:
1. Close upvalues (already done)
2. Copy `regs[a .. a+nargs+1]` (function + args) down to `func_slot`
3. Reset `pc = 0`, update `func_slot` for the new callee
4. Continue in the same frame

Find the base-shift logic in `opTailcall` (~lines 10066-10092) and replace with:

```zig
        // PUC luaD_pretailcall: copy func + args down to func_slot.
        // In the overlapping model, func_slot stays the same — just
        // copy the new function and its args there.
        const dst = ctx.func_slot;
        const src = a;
        // Copy function + args: regs[src] = function, regs[src+1..] = args
        for (0..effective_nargs + 1) |i| {
            ctx.regs[dst + i] = ctx.regs[src + i];
        }
        // Now re-derive args from the new position.
        // No base shift needed — func_slot is unchanged.
        // Nil-fill missing params for the callee.
        const callee_nparams = proto2.numparams;
        for (effective_nargs..callee_nparams) |i| {
            ctx.regs[dst + 1 + i] = .Nil;
        }
```

The key insight: `func_slot` doesn't change for a tail call. The callee replaces the caller at the same `func_slot`. The base remains `func_slot + 1`.

- [ ] **Step 2: Remove the old `nextra` base-shift code**

Delete the old code that computed `extra_va`, shifted `ctx.base`, and recomputed `bc_stack_top`. This is no longer needed.

- [ ] **Step 3: Build and test**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Run: `for f in tests/smoke/*.lua; do timeout 5 zig-out/bin/luazig "$f" 2>&1 | tail -1; done | grep -c "."`
Run: `python3 tools/testes_matrix.py --timeout 30 2>&1 | head -5`

Expected: Tail calls should work. May have regressions — record the state.

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "overlapping frames: simplify opTailcall to reuse func_slot

PUC luaD_pretailcall model: copy func+args down to func_slot, reset pc.
No base shift or nextra recomputation needed."
```

---

## Task 6: Update `shrinkBcStack` to walk frames (PUC `stackinuse`)

With overlapping frames, `bc_stack_top` may not reflect the true high-water mark because frames overlap. We need to walk all frames and compute the max, like PUC's `stackinuse`.

**Files:**
- Modify: `src/lua/vm.zig:2741-2777` (`shrinkBcStack`)

- [ ] **Step 1: Implement `bcStackInUse` helper**

Add a new function near `shrinkBcStack`:

```zig
    /// PUC ldo.c `stackinuse`: compute the true high-water mark of bc_stack
    /// by walking all bytecode frames and taking the max of their
    /// `base + frame_cap`. This is needed because overlapping frames mean
    /// bc_stack_top may be less than the actual high-water mark.
    fn bcStackInUse(self: *Vm) usize {
        const LUA_MINSTACK: usize = 20;
        var inuse: usize = self.bc_stack_top;
        const th = self.activeBytecodeThread();
        for (0..th.call_frames.len()) |i| {
            const fr = th.call_frames.getConstPtr(i);
            if (fr.proto != null) {
                const frame_top = fr.base + fr.frame_cap;
                if (frame_top > inuse) inuse = frame_top;
            }
        }
        if (inuse < LUA_MINSTACK) inuse = LUA_MINSTACK;
        return inuse;
    }
```

- [ ] **Step 2: Use `bcStackInUse` in `shrinkBcStack`**

Replace `var inuse = self.bc_stack_top;` with:

```zig
        var inuse = self.bcStackInUse();
```

- [ ] **Step 3: Build and test**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Run: `python3 tools/testes_matrix.py --timeout 30 2>&1 | head -5`

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "overlapping frames: shrinkBcStack walks frames like PUC stackinuse

With overlapping frames, bc_stack_top may underreport actual usage.
bcStackInUse walks all frames computing max(base + frame_cap)."
```

---

## Task 7: Update `T.stacklevel()` for overlapping frames

The testC `T.stacklevel()` function reports `bc_stack_top` as `top` and `bc_stack.len` as `size`. With overlapping frames, `bc_stack_top` now represents the high-water capacity mark (like PUC's `ci->top`), which is the correct value for `size` after overflow.

**Files:**
- Modify: `src/lua/vm.zig:27357-27387` (`builtinTestcStacklevel`)

- [ ] **Step 1: Verify `T.stacklevel` semantics**

PUC `stacklevel` returns:
1. `top` = `L->top.p - L->stack.p` (number of slots in use)
2. `size` = `stacksize(L)` (total allocated stack size)

With overlapping frames:
- `bc_stack_top` = high-water mark (max `base + frame_cap` across frames) — this is PUC's `ci->top.p` equivalent, NOT `L->top.p`.
- `bc_stack.len` = allocated capacity.

PUC's `L->top.p` is the actual runtime top, which fluctuates per-instruction. We don't track this separately. For the `cstack.lua` test, the important value is `size` (which determines overflow behavior), and `top` is used only for before/after comparison.

Keep `T.stacklevel` returning `bc_stack_top` as `top` and `bc_stack.len` as `size`. This is close enough — the test checks `sizeA < sizeB * 2` (overflow recovery shrinks the stack) and `topA == topB` (stack usage restored).

- [ ] **Step 2: No code change needed, verify test passes**

Run: `cd lua-5.5.0/testes && timeout 30 ../../zig-out/bin/luazig --testc cstack.lua 2>&1 | tail -10`
Expected: "testing stack recovery" should pass (or at least progress further than before)

- [ ] **Step 3: Commit if any changes were needed**

---

## Task 8: Fix return value placement for overlapping frames

PUC's `luaD_poscall`/`moveresults` copies return values from the callee's position to the caller's `func_slot` (register `R[A]`). Our `completeBytecodeExecFrame` and `applyBytecodePendingResults` need to place results at the correct position.

**Files:**
- Modify: `src/lua/vm.zig:4688-4711` (`applyBytecodePendingResults`)
- Verify: `src/lua/vm.zig:6681-6791` (`completeBytecodeExecFrame`)

- [ ] **Step 1: Verify result placement in `applyBytecodePendingResults`**

The function writes results at `parent.base + result_cont.dst`. With overlapping frames, `parent.base` is the parent frame's base, and `dst` is the register `A` from OP_CALL. So results go to `parent.base + A`, which is the caller's register `R[A]` — the function slot. This is correct!

Verify by reading the code and confirming no change needed.

- [ ] **Step 2: Verify `opCall` result placement for builtins**

In `opCall` (~line 10415), builtins write results to `ctx.regs[a + i]`. Register `a` is relative to `ctx.base`, so `ctx.regs[a]` = `bc_stack[ctx.base + a]` = the function slot. This is correct for the overlapping model.

- [ ] **Step 3: Run full regression suite**

Run: `python3 tools/testes_matrix.py --timeout 30 2>&1 | head -5`
Run: `python3 tools/testes_matrix.py --testc --timeout 30 2>&1 | head -5`
Run: `python3 tools/testc_lane.py --timeout 30 2>&1 | grep -c "ok"`
Run: `for f in tests/smoke/*.lua; do timeout 5 zig-out/bin/luazig "$f" 2>&1 | tail -1; done | grep -c "."`

Expected: Record the state. Regressions at this point indicate remaining issues.

- [ ] **Step 4: Commit if changes were needed**

---

## Task 9: Fix `ensureBcStackCap` pre-grow in `opCall`

The `opCall` handler pre-grows `bc_stack` before calling `pushBytecodeExecFrame` (to keep `rargs` valid). With overlapping frames, the args are already in the caller's registers — they don't move during frame push. The pre-grow is unnecessary.

**Files:**
- Modify: `src/lua/vm.zig:10312-10327` (`opCall` pre-grow)

- [ ] **Step 1: Remove the pre-grow**

Find the pre-grow block in `opCall` (~lines 10312-10327):

```zig
        // Pre-grow bc_stack so rargs stays valid across pushBytecodeExecFrame.
        const child_frame_cap: usize = switch (ctx.regs[a]) {
            .Closure => |cl| if (cl.proto) |p| p.maxstacksize + EXTRA_MARGIN else 0,
            else => 0,
        };
        const child_nextra: usize = ...;
        try self.ensureBcStackCap(self.bc_stack_top + child_frame_cap + child_nextra);
        ctx.regs = self.bc_stack[ctx.base .. ctx.base + ctx.frame_cap];
        ctx.boxed = self.bc_boxed[ctx.base .. ctx.base + ctx.frame_cap];
```

With overlapping frames, `rargs` points into the caller's registers which don't move during `pushBytecodeExecFrame` (the callee frame starts at `ctx.base + a + 1`, within the existing capacity). But `pushBytecodeExecFrame` may still call `ensureBcStackCap` which can realloc.

The fix: keep the pre-grow but change the capacity computation to match the new model:

```zig
        // Pre-grow bc_stack so rargs (in caller's registers) stays valid
        // across pushBytecodeExecFrame's potential ensureBcStackCap call.
        // With overlapping frames, the callee's frame extends from
        // ctx.base + a + 1 to ctx.base + a + 1 + child_frame_cap.
        const child_frame_cap: usize = switch (ctx.regs[a]) {
            .Closure => |cl| if (cl.proto) |p| p.maxstacksize + EXTRA_MARGIN else 0,
            else => 0,
        };
        const child_needed = ctx.base + a + 1 + child_frame_cap;
        if (child_needed > self.bc_stack.len) {
            try self.ensureBcStackCap(child_needed);
            ctx.regs = self.bc_stack[ctx.base .. ctx.base + ctx.frame_cap];
            ctx.boxed = self.bc_boxed[ctx.base .. ctx.base + ctx.frame_cap];
        }
```

Note: `child_nextra` is eliminated — no separate varargs region.

- [ ] **Step 2: Same fix for `opTforcall`**

Apply the same pattern to `opTforcall`'s pre-grow (~line 9621).

- [ ] **Step 3: Build and test**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Run: `python3 tools/testes_matrix.py --timeout 30 2>&1 | head -5`

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "overlapping frames: fix opCall/opTforcall pre-grow for new frame model

Pre-grow uses ctx.base + a + 1 + child_frame_cap (overlapping position)
instead of bc_stack_top + child_frame_cap + child_nextra. Removes
child_nextra computation (no separate varargs region)."
```

---

## Task 10: Fix `bcGrowFrame` for overlapping frames

`bcGrowFrame` grows the CURRENT frame's capacity (for multret / VARARG expansion). With overlapping frames, growing the frame may extend into the callee's space if there is an active callee. But `bcGrowFrame` is only called when there's no active callee (the frame is the topmost), so it should be fine.

**Files:**
- Modify: `src/lua/vm.zig:2786-2819` (`bcGrowFrame`)

- [ ] **Step 1: Verify `bcGrowFrame` is only called on the topmost frame**

Search for all callers:
Run: `grep -n "bcGrowFrame" src/lua/vm.zig | grep -v "fn bcGrowFrame"`

All callers should be in the dispatch loop (`opCall`, `opVararg`, etc.) where the current frame is topmost. If so, no change needed — `bc_stack_top` is updated to `@max(bc_stack_top, base + new_cap)`.

- [ ] **Step 2: Verify the `@max` computation**

The current code:
```zig
self.bc_stack_top = @max(self.bc_stack_top, base + frame_cap.*);
```

With overlapping frames, `base + frame_cap` is the frame's top. `bc_stack_top` should be the max of all frame tops. Since we're growing the topmost frame, `base + frame_cap` is the new high-water. The `@max` is correct.

- [ ] **Step 3: Build and run full suite**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Run: `python3 tools/testes_matrix.py --timeout 30 2>&1 | head -5`
Run: `cd lua-5.5.0/testes && timeout 30 ../../zig-out/bin/luazig --testc cstack.lua 2>&1 | tail -10`

- [ ] **Step 4: Commit if changes were needed**

---

## Task 11: Run full regression suite and fix remaining issues

This is the integration task — verify everything works and fix any remaining issues.

**Files:**
- Modify: `src/lua/vm.zig` (wherever issues are found)

- [ ] **Step 1: Build ReleaseFast**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: BUILD OK

- [ ] **Step 2: Normal matrix**

Run: `python3 tools/testes_matrix.py --timeout 30 2>&1 | head -5`
Expected: At least as many pass as before the change (was 28/31)

- [ ] **Step 3: TestC matrix**

Run: `python3 tools/testes_matrix.py --testc --timeout 30 2>&1 | head -5`
Expected: At least as many pass as before (was 26/31). `cstack.lua` should now pass!

- [ ] **Step 4: TestC lane**

Run: `python3 tools/testc_lane.py --timeout 30 2>&1 | grep -c "ok"`
Expected: 9 (same as before)

- [ ] **Step 5: Smoke tests**

Run: `for f in tests/smoke/*.lua; do timeout 5 zig-out/bin/luazig "$f" 2>&1 | tail -1; done | grep -c "."`
Expected: Same count as before (42+)

- [ ] **Step 6: cstack.lua specifically**

Run: `cd lua-5.5.0/testes && timeout 30 ../../zig-out/bin/luazig --testc cstack.lua 2>&1`
Expected: Full pass (prints "OK" at the end, no assertion failures)

- [ ] **Step 7: code.lua (uses T.listcode which is still missing)**

Run: `cd lua-5.5.0/testes && timeout 30 ../../zig-out/bin/luazig --testc code.lua 2>&1`
Expected: Still fails on `T.listcode` (not implemented) — this is a separate task.

- [ ] **Step 8: Fix any regressions found**

For each failing test, investigate the root cause. Common issues:
- Vararg functions not receiving correct args
- Tail calls not preserving results
- Deep recursion overflowing at wrong depth
- Return values placed at wrong position

Fix each issue, rebuild, re-test.

- [ ] **Step 9: Commit**

```bash
git add src/lua/vm.zig
git commit -m "overlapping frames: fix regressions from integration testing

[Description of specific fixes applied]"
```

---

## Task 12: Performance verification

Verify that overlapping frames don't introduce performance regressions. The change should be neutral-to-positive (no arg copy, less memory).

**Files:**
- No code changes (measurement only)

- [ ] **Step 1: Run perf_compare**

Run: `python3 tools/perf_compare.py --runs 3 2>&1 | grep -E "RESULT|geomean"`

Expected: geomean ≤ 2.9x (was 2.86x). If significantly worse, investigate.

- [ ] **Step 2: If perf regressed, investigate**

Common perf concerns:
- The `args_on_stack` check in `pushBytecodeExecFrame` adds a pointer comparison per call
- The host-recursion path (`!args_on_stack`) writes func+args into bc_stack

If the fast path (`args_on_stack == true`) is efficient (one pointer comparison), perf should be fine.

- [ ] **Step 3: Commit if any perf fixes were applied**

---

## Task 13: Update README and final commit

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README**

Document the architectural change:
- What: switched from non-overlapping to overlapping bytecode frames
- Why: PUC parity, correct stack overflow behavior, cstack.lua tests pass
- How: frame base = caller's func_slot + 1, args in-place, no separate varargs region

- [ ] **Step 2: Final regression run**

Run: `python3 tools/testes_matrix.py --timeout 30 2>&1 | head -5`
Run: `python3 tools/testes_matrix.py --testc --timeout 30 2>&1 | head -5`
Run: `for f in tests/smoke/*.lua; do timeout 5 zig-out/bin/luazig "$f" 2>&1 | tail -1; done | grep -c "."`

- [ ] **Step 3: Commit**

```bash
git add README.md src/lua/vm.zig
git commit -m "overlapping bytecode frames: PUC-faithful call stack model

Replace non-overlapping frame model with PUC Lua's overlapping frames.
Each new frame starts at the caller's function register (func_slot + 1),
reusing the caller's argument registers. Stack growth per recursive call
drops from ~20+ slots to ~1-3 slots.

Changes:
- pushBytecodeExecFrame: base = caller_func_slot + 1 (PUC ci->func model)
- popBytecodeExecFrame: restore bc_stack_top to caller's frame capacity
- Varargs: at func_slot + 1 + numparams (within caller's arg region)
- opTailcall: reuse func_slot, copy func+args down (PUC luaD_pretailcall)
- shrinkBcStack: walk frames for high-water mark (PUC stackinuse)
- Overflow check: func_slot + 1 + frame_cap > MAXSTACK (PUC model)

Result: cstack.lua 'testing stack recovery' passes. Stack overflow depth
matches PUC Lua. No arg copy on bytecode-to-bytecode calls."
```

---

## Summary of Changes

| Component | Before | After |
|-----------|--------|-------|
| Frame base | `bc_stack_top + nextra` | `caller_func_slot + 1` |
| Arg copy | Copy nparams args into fresh regs | No copy (args already in place) |
| Varargs | Separate region below base | At `func_slot + 1 + numparams` |
| Overflow check | `bc_stack_top + total > limit` | `func_slot + 1 + frame_cap > MAXSTACK` |
| Stack growth/call | ~20-25 slots | ~1-3 slots |
| `popBytecodeExecFrame` | `bc_stack_top = base - nextraargs` | `bc_stack_top = caller.base + caller.frame_cap` |
| `shrinkBcStack` inuse | `bc_stack_top` | `max(all frame tops)` (PUC `stackinuse`) |
| Tail call | Shift base, recompute nextra | Copy func+args to func_slot (PUC `luaD_pretailcall`) |

## Risk Assessment

**High risk:**
- `pushBytecodeExecFrame` is called from multiple paths (OP_CALL, runBytecodeInternal, tryPushBytecodeProtectedCall, opTforcall). Each must pass the correct `caller_func_slot`.
- Varargs access change may break vararg-heavy tests.

**Medium risk:**
- Tail call simplification may break coroutine yield/resume inside tail calls.
- GC scanning of overlapping frames (frames share memory).

**Low risk:**
- `shrinkBcStack` change is straightforward.
- `T.stacklevel` semantics are close enough.

**Mitigation:** Each task has a build+test checkpoint. Commit after each task for bisect capability.
