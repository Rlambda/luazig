# P15.35 — PUC-faithful call resolution (inline luaD_precall + tryfuncTM) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Inline PUC Lua's `luaD_precall`/`tryfuncTM` call resolution model directly into the OP_CALL/OP_TAILCALL/OP_TFORCALL bytecode handlers, eliminating the `resolveCallable` function call on the fast path and the heap allocation on the `__call` metamethod path.

**Architecture:** PUC Lua's `luaD_precall` (ldo.c:715-746) is a single `switch` on the callee type tag — the common case (Lua closure) is handled inline with no function call indirection. The `__call` metamethod resolution (`tryfuncTM`, ldo.c:523-536) shifts the Lua stack in-place to prepend the original callee as argument 0 — no heap allocation. luazig currently routes ALL calls through `resolveCallable()` (vm.zig:25809), which returns a `ResolvedCall` struct and heap-allocates a `Value[]` buffer for `__call`. This plan inlines the type switch into the three hot bytecode handlers, adds an in-place stack-shift helper for `__call`, and eliminates the `ResolvedCall` struct + heap alloc from the hot path.

**Tech Stack:** Zig 0.16.0, existing ltable/vm infrastructure, upstream `testes/*.lua` matrix + perf benchmarks.

**PUC references:**
- `luaD_precall` — ldo.c:715-746 (inline type switch, fast path for `LUA_VLCL`)
- `tryfuncTM` — ldo.c:523-536 (in-place stack shift for `__call` metamethod)
- `CallInfo` — lstate.h:187-209 (PUC's compact call frame)

---

## File Structure

- **Modify:** `src/lua/vm.zig` — add `tryCallMetamethodInPlace` helper; refactor OP_CALL/OP_TAILCALL/OP_TFORCALL handlers.
- **No new files.** All changes are in-place refactors of existing code in vm.zig.

## Current state (before P15.35)

The three hot bytecode handlers all call `resolveCallable()`:

```zig
const resolved = self.resolveCallable(func_val, orig_args, null) catch ...;
defer if (resolved.owned_args) |owned| self.alloc.free(owned);
```

`resolveCallable` (vm.zig:25809-25840) loops on callee type:
- `.Builtin, .Closure` → return immediately with `{callee, args, owned_args: null}` (fast path, no alloc)
- `else` → look up `__call` metamethod; if found, **heap-alloc** `Value[args.len + 1]`, prepend callee, loop

The `ResolvedCall` struct (vm.zig:25699-25703):
```zig
const ResolvedCall = struct {
    callee: Value,
    args: []const Value,
    owned_args: ?[]Value = null,
};
```

28 total call sites of `resolveCallable`. Of these, **3 are hot path** (OP_CALL at 8841, OP_TAILCALL at 9188, OP_TFORCALL at 9748) and **25 are cold path** (hooks, builtins, metamethods, coroutine.resume, apiCall, IR backend). This plan only touches the 3 hot-path sites. The 25 cold-path sites keep using `resolveCallable` unchanged.

## Target state (after P15.35)

Each hot handler inlines the type switch and uses `tryCallMetamethodInPlace` for `__call`:

```zig
// PUC luaD_precall inline resolution
var effective_nargs = nargs;
var chain_depth: usize = 0;
while (true) {
    switch (regs[a]) {
        .Closure, .Builtin => break,  // fast path: exits on first iteration
        else => {
            // PUC tryfuncTM: shift stack, prepend callee as arg[0]
            try self.tryCallMetamethodInPlace(
                base, a, &effective_nargs, &frame_cap, &regs, &boxed, &chain_depth,
            );
        },
    }
}
// Args are now guaranteed on bc_stack at regs[a+1..a+1+effective_nargs]
const rargs = regs[a + 1 .. a + 1 + effective_nargs];
```

**Eliminates on the hot path:**
1. `resolveCallable` function call (one function call per OP_CALL)
2. `ResolvedCall` struct construction
3. `defer if (resolved.owned_args)` cleanup registration
4. `rargs` derivation block with `owned_args` branching (lines 8875-8896)
5. Two-phase error retry (replaced with lazy name inference on error path only)
6. Heap allocation `alloc(Value, args.len + 1)` for `__call` (replaced with bc_stack shift)

**Does NOT change:**
- `resolveCallable` function itself (kept for 25 cold-path sites)
- `ResolvedCall` struct (kept for cold-path sites)
- IR backend call handlers (7 sites, frozen backend)
- Builtin branch special cases (pairs/pcall/coroutine/gsub)
- Hook transfer mechanism
- Error message format

---

### Task 1: Add `tryCallMetamethodInPlace` helper

New method on `Vm` that implements PUC `tryfuncTM` (ldo.c:523-536). Shifts `bc_stack` in-place to prepend the current callee as argument 0, then writes the `__call` metamethod into the callee slot.

**Files:**
- Modify: `src/lua/vm.zig` — add method near `resolveCallable` (around line 25840)

- [ ] **Step 1: Add the helper method after `resolveCallable`**

Insert after `resolveCallable` (line 25840), before `runResolvedCallInto` (line 25842):

```zig
/// PUC `tryfuncTM` equivalent (ldo.c:523-536). Resolve a `__call`
/// metamethod for a non-callable value by shifting the argument slice
/// on the shared bytecode stack up by one slot, making room for the
/// original callee to become argument 0 (the "self" parameter that PUC
/// passes to `__call` metamethods). The metamethod is then written into
/// the callee slot (`regs[a]`), and the caller re-enters the type switch.
///
/// This eliminates the heap allocation that `resolveCallable` performs
/// for the `__call` path (`alloc(Value, args.len + 1)`). On the hot
/// bytecode path, args are always on `bc_stack`, so the shift is a
/// simple `memmove` — exactly what PUC does.
///
/// PUC reference (ldo.c:529-532):
///   for (p = L->top.p; p > func; p--)  // open space for metamethod
///     setobjs2s(L, p, p-1);
///   L->top.p++;
///   setobj2s(L, func, tm);  // metamethod is the new function
///
/// In PUC, `func` is the stack slot of the callee. The shift moves
/// `func+1..top` up by one, then overwrites `func` with the metamethod.
/// Our equivalent: shift `regs[a+1..a+1+nargs]` up by one (to
/// `regs[a+2..a+2+nargs]`), write the original `regs[a]` into
/// `regs[a+1]` (it was already there before the shift — the shift
/// copies it up), then write the metamethod into `regs[a]`.
///
/// **Stack growth:** the shift needs one extra slot beyond the current
/// `nargs`. We grow the frame via `bcGrowFrame` if needed, which may
/// realloc `bc_stack` — the caller's `regs`/`boxed` slices are updated
/// in place through the pointer parameters.
///
/// **Chain depth:** PUC limits `__call` chains to 16 (counted in
/// `callstatus` bits `CIST_CCMT`). We track this in `chain_depth`,
/// checked by the caller before calling this method.
fn tryCallMetamethodInPlace(
    self: *Vm,
    base: usize,
    a: usize,
    nargs: *usize,
    frame_cap: *usize,
    regs: *[]Value,
    boxed: *[]?*Cell,
    chain_depth: *usize,
) DispatchError!void {
    const current_callee = regs.*[a];
    // Look up __call metamethod on the current (non-callable) value.
    const mm = metamethodValue(self, current_callee, "__call") orelse {
        // No __call metamethod — the value is not callable.
        // The caller handles error formatting (with lazy name inference).
        return self.fail("attempt to call a {s} value", .{current_callee.typeName()});
    };

    // Ensure the frame has space for one extra slot (the shift target).
    // PUC does this via checkstackp(L, 1, func) before the shift.
    const needed = a + 1 + nargs.* + 1;
    if (needed > frame_cap.*) {
        try self.bcGrowFrame(base, needed, frame_cap, regs, boxed);
    }

    // Shift args up by 1 slot (high-to-low for overlap safety).
    // Before: regs[a] = callee, regs[a+1..a+1+nargs] = args
    // After:  regs[a] = mm, regs[a+1] = callee (now arg[0]), regs[a+2..a+2+nargs] = args
    //
    // The shift copies regs[a+nargs] → regs[a+nargs+1], ..., regs[a] → regs[a+1].
    // Then we overwrite regs[a] with the metamethod.
    {
        var i: usize = nargs.* + 1;
        while (i > 0) : (i -= 1) {
            regs.*[a + i] = regs.*[a + i - 1];
        }
    }
    regs.*[a] = mm;

    nargs.* += 1;
    chain_depth.* += 1;
}
```

- [ ] **Step 2: Add unit test for single `__call` resolution**

Add near the existing ltable/call unit tests or in the vm test block. This test verifies the stack shift works for a simple callable-table scenario:

```zig
test "tryCallMetamethodInPlace: single __call shifts stack correctly" {
    // Setup: create a VM with a small bc_stack frame.
    // Place a non-callable value at regs[a] and args at regs[a+1..].
    // The value's metatable has __call = a closure.
    // After tryCallMetamethodInPlace:
    //   regs[a] = the closure (metamethod)
    //   regs[a+1] = the original non-callable value (now arg[0])
    //   regs[a+2..] = original args (shifted up by 1)
    //   nargs incremented by 1
    // (This test requires VM setup boilerplate — adapt to the existing
    // test harness pattern used in vm.zig.)
    // TODO: implement with the test harness used by other vm.zig tests.
}
```

Note: vm.zig's test harness requires significant VM setup. If the existing test pattern is too heavy, add the regression test as a Lua-level smoke test in `tests/smoke/` instead (Task 5 covers this).

- [ ] **Step 3: Verify build**

Run: `zig build -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS (the method is additive, no callers yet).

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.35: add tryCallMetamethodInPlace helper (PUC tryfuncTM equivalent)"
```

---

### Task 2: Refactor OP_CALL handler — inline fast path

Restructure the OP_CALL handler (lines 8796-9152) to inline the type switch and use `tryCallMetamethodInPlace` for `__call`, eliminating `resolveCallable` from this hot path.

**Files:**
- Modify: `src/lua/vm.zig` — OP_CALL handler (lines 8796-9152)

- [ ] **Step 1: Replace the `resolveCallable` call + `rargs` derivation block**

Find lines 8832-8896 (from `const func_val = regs[a];` through the end of the `rargs` block). Replace the entire block:

**Before (lines 8832-8896):**
```zig
const func_val = regs[a];
const nargs: usize = if (b == 0) reg_top - a - 1 else b - 1;
const orig_args = regs[a + 1 .. a + 1 + nargs];

const resolved = self.resolveCallable(func_val, orig_args, null) catch |err| blk: {
    if (err == error.RuntimeError and self.err != null and
        std.mem.startsWith(u8, self.err.?, "attempt to call a "))
    {
        const inferred = debugBytecodeOperandName(cur_proto, pc, a);
        if (inferred.name) |name| {
            break :blk self.resolveCallable(func_val, orig_args, .{
                .namewhat = inferred.namewhat, .name = name,
            }) catch return err;
        }
    }
    return err;
};
defer if (resolved.owned_args) |owned| self.alloc.free(owned);

// ... long P15.35 comment ...
const rargs: []Value = blk: {
    if (resolved.owned_args != null) {
        break :blk @constCast(resolved.args);
    }
    const child_frame_cap: usize = switch (resolved.callee) {
        .Closure => |cl| if (cl.proto) |p| p.maxstacksize else 0,
        else => 0,
    };
    const stack_ptr_before = self.bc_stack.ptr;
    try self.ensureBcStackCap(self.bc_stack_top + child_frame_cap);
    if (self.bc_stack.ptr == stack_ptr_before) {
        break :blk @constCast(resolved.args);
    }
    break :blk self.bc_stack[base + a + 1 .. base + a + 1 + nargs];
};
```

**After:**
```zig
const nargs: usize = if (b == 0) reg_top - a - 1 else b - 1;

// ── PUC luaD_precall: inline callee type resolution ──
// (ldo.c:715-746). The common case (Closure/Builtin) exits the loop
// on the first iteration — no function call, no struct allocation,
// no heap alloc. Only the `__call` metamethod path (the `default`
// case in PUC) enters the loop body.
var effective_nargs = nargs;
var chain_depth: usize = 0;
while (true) {
    switch (regs[a]) {
        .Closure, .Builtin => break, // resolved
        else => {
            // PUC tryfuncTM: __call metamethod resolution via in-place
            // stack shift. Shifts regs[a..a+nargs+1] up by 1 slot,
            // writes metamethod to regs[a]. No heap allocation.
            if (chain_depth >= 16) {
                return self.fail("'__call' chain too long", .{});
            }
            // Capture the current callee for lazy error-name inference.
            const current_callee = regs[a];
            try self.tryCallMetamethodInPlace(
                base, a, &effective_nargs, &frame_cap, &regs, &boxed, &chain_depth,
            ) catch |err| {
                // If the error is "attempt to call a X value" (no __call
                // metamethod found), retry with an inferred name for a
                // better error message. This matches the previous
                // two-phase retry but is lazier — only runs on error.
                if (err == error.RuntimeError and self.err != null and
                    std.mem.startsWith(u8, self.err.?, "attempt to call a "))
                {
                    const inferred = debugBytecodeOperandName(cur_proto, pc, a);
                    if (inferred.name) |name| {
                        return self.fail(
                            "attempt to call a {s} value ({s} '{s}')",
                            .{ current_callee.typeName(), inferred.namewhat, name },
                        );
                    }
                }
                return err;
            };
        },
    }
}

// Pre-grow bc_stack for the child frame BEFORE deriving rargs, so the
// rargs slice stays valid. Matches PUC luaD_precall's checkstackp +
// luaD_reallocstack. ensureBcStackCap inside pushBytecodeExecFrame
// becomes a no-op (already grown here).
const child_frame_cap: usize = switch (regs[a]) {
    .Closure => |cl| if (cl.proto) |p| p.maxstacksize else 0,
    else => 0,
};
try self.ensureBcStackCap(self.bc_stack_top + child_frame_cap);
regs = self.bc_stack[base .. base + frame_cap];
boxed = self.bc_boxed[base .. base + frame_cap];

// Args are now guaranteed on bc_stack — no owned_args branching needed.
const rargs = regs[a + 1 .. a + 1 + effective_nargs];
```

- [ ] **Step 2: Update the hook transfer to use `regs[a]` instead of `resolved.callee`**

Find lines 8898-8914 (the hook transfer block). Replace `resolved.callee` with the re-read from `regs[a]`:

**Before:**
```zig
const skip_call_hook = exec_frames.items[frame_index].skip_call_hook_pc == pc;
if (skip_call_hook) {
    exec_frames.items[frame_index].skip_call_hook_pc = null;
} else if (try self.tryPushBytecodeDebugHook(
    exec_frames,
    frame_index,
    "call",
    null,
    resolved.callee,
    rargs,
    1,
    .retry_call,
)) {
    continue :frame_loop;
} else {
    try self.dispatchBytecodeHookWithCallee("call", resolved.callee, rargs);
}
```

**After:**
```zig
const resolved_callee = regs[a]; // .Closure or .Builtin (verified by the loop above)
const skip_call_hook = exec_frames.items[frame_index].skip_call_hook_pc == pc;
if (skip_call_hook) {
    exec_frames.items[frame_index].skip_call_hook_pc = null;
} else if (try self.tryPushBytecodeDebugHook(
    exec_frames,
    frame_index,
    "call",
    null,
    resolved_callee,
    rargs,
    1,
    .retry_call,
)) {
    continue :frame_loop;
} else {
    try self.dispatchBytecodeHookWithCallee("call", resolved_callee, rargs);
}
```

- [ ] **Step 3: Update the dispatch switch to use `regs[a]` instead of `resolved.callee`**

Find line 8916 (`switch (resolved.callee) {`). Replace with:

**Before:**
```zig
switch (resolved.callee) {
    .Builtin => |id| {
        ...
    },
    .Closure => |cl| {
        ...
    },
    else => unreachable,
}
```

**After:**
```zig
switch (regs[a]) {
    .Builtin => |id| {
        ...
    },
    .Closure => |cl| {
        ...
    },
    else => unreachable, // the loop above guarantees .Closure or .Builtin
}
```

- [ ] **Step 4: Update Builtin branch `outs_start` to use `effective_nargs`**

Inside the Builtin branch, find the `outs_start` computation (around line 8999). It currently uses `nargs` (the original arg count). With the `__call` stack shift, args may include the extra self parameter, so we must use `effective_nargs`:

**Before:**
```zig
const outs_start = a + 1 + nargs;
```

**After:**
```zig
const outs_start = a + 1 + effective_nargs;
```

Also check any other reference to `nargs` inside the Builtin branch — if it refers to the number of arguments passed to the builtin, it should use `effective_nargs`. The builtin receives `rargs` (which is `regs[a+1..a+1+effective_nargs]`), so `rargs.len == effective_nargs` is the correct arg count.

- [ ] **Step 5: Update Closure branch to use `regs[a]` instead of `resolved.callee`**

Find lines 9077-9149 (the Closure branch). Replace `resolved.callee` references:

**Before (line 9083-9084):**
```zig
exec_frames.items[frame_index].pending_call.set(.{
    .callee = resolved.callee,
```

**After:**
```zig
exec_frames.items[frame_index].pending_call.set(.{
    .callee = regs[a],
```

Similarly for the IR/testC closure sub-path (around line 9098-9099):
```zig
// Before:
.callee = resolved.callee,
// After:
.callee = regs[a],
```

And the hook transfer inside the Closure branch (lines 9128, 9139):
```zig
// Before:
resolved.callee
// After:
regs[a]  // (or capture into a local before the switch)
```

To avoid reading `regs[a]` multiple times, capture it once before the switch:
```zig
const callee_val = regs[a]; // .Closure or .Builtin
switch (callee_val) {
    .Builtin => |id| { ... },
    .Closure => |cl| { ... },
    else => unreachable,
}
```

Then use `callee_val` everywhere that previously used `resolved.callee`.

- [ ] **Step 6: Verify build**

Run: `zig build -Doptimize=Debug 2>&1 | tail -20`
Expected: PASS. Common errors:
- "use of undeclared identifier `resolved`" — you missed a reference to `resolved.callee` or `resolved.args`
- "unreachable" — the `else => unreachable` in the switch is correct (the loop guarantees Closure/Builtin)

- [ ] **Step 7: Run unit tests**

Run: `zig build test -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 8: Run smoke tests**

```bash
for f in tests/smoke/*.lua; do
    ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"
done
```
Expected: 44/44 PASS.

- [ ] **Step 9: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.35: inline luaD_precall in OP_CALL (eliminate resolveCallable + heap alloc)"
```

---

### Task 3: Refactor OP_TAILCALL handler — same pattern

Apply the same inline resolution to OP_TAILCALL (lines 9153-9460). The main difference from OP_CALL is the frame-reuse path.

**Files:**
- Modify: `src/lua/vm.zig` — OP_TAILCALL handler (lines 9153-9460)

- [ ] **Step 1: Replace the `resolveCallable` call**

Find lines 9176-9205 (from `const func_val = regs[a];` through `const call_args = resolved.args;`). Replace with the same inline resolution pattern as Task 2:

**Before (lines 9176-9205):**
```zig
const func_val = regs[a];
const nargs: usize = if (b == 0) reg_top - a - 1 else b - 1;
const orig_args = regs[a + 1 .. a + 1 + nargs];

// P15.35: Eliminate the per-tailcall dup_args ...
const resolved = self.resolveCallable(func_val, orig_args, null) catch |err| blk: {
    ...
};
defer if (resolved.owned_args) |owned| self.alloc.free(owned);
const call_args = resolved.args;
```

**After:**
```zig
const nargs: usize = if (b == 0) reg_top - a - 1 else b - 1;

// ── PUC luaD_precall: inline callee type resolution ──
var effective_nargs = nargs;
var chain_depth: usize = 0;
while (true) {
    switch (regs[a]) {
        .Closure, .Builtin => break,
        else => {
            if (chain_depth >= 16) return self.fail("'__call' chain too long", .{});
            const current_callee = regs[a];
            try self.tryCallMetamethodInPlace(
                base, a, &effective_nargs, &frame_cap, &regs, &boxed, &chain_depth,
            ) catch |err| {
                if (err == error.RuntimeError and self.err != null and
                    std.mem.startsWith(u8, self.err.?, "attempt to call a "))
                {
                    const inferred = debugBytecodeOperandName(cur_proto, pc, a);
                    if (inferred.name) |name| {
                        return self.fail(
                            "attempt to call a {s} value ({s} '{s}')",
                            .{ current_callee.typeName(), inferred.namewhat, name },
                        );
                    }
                }
                return err;
            };
        },
    }
}
const callee_val = regs[a];
const call_args = regs[a + 1 .. a + 1 + effective_nargs];
```

- [ ] **Step 2: Update hook transfer references**

Find lines 9207-9233. Replace `resolved.callee` with `callee_val`:

**Before:**
```zig
const hook_args = switch (resolved.callee) {
    .Closure => |cl| debugCallTransferArgsForClosure(cl, call_args),
    else => call_args,
};
...
try self.tryPushBytecodeDebugHook(..., resolved.callee, hook_args, ...)
...
try self.debugDispatchHookWithCalleeTransfer("tail call", null, resolved.callee, hook_args, 1);
```

**After:**
```zig
const hook_args = switch (callee_val) {
    .Closure => |cl| debugCallTransferArgsForClosure(cl, call_args),
    else => call_args,
};
...
try self.tryPushBytecodeDebugHook(..., callee_val, hook_args, ...)
...
try self.debugDispatchHookWithCalleeTransfer("tail call", null, callee_val, hook_args, 1);
```

- [ ] **Step 3: Update frame-reuse path — simplify args copy**

Find lines 9289-9371 (the `.Closure` frame-reuse path). The current code branches on `resolved.owned_args == null` (line 9320) to choose between `copyForwards` (overlap-safe, fast path) and `@memcpy` (heap buffer, slow path). With the inline resolution, args are ALWAYS on bc_stack, so `copyForwards` is always correct:

**Before (lines 9318-9326):**
```zig
const np = new_proto.numparams;
const nc = @min(np, call_args.len);
if (resolved.owned_args == null) {
    // Fast path: call_args is regs[a+1..], overlaps regs[0..nc].
    std.mem.copyForwards(Value, regs[0..nc], call_args[0..nc]);
} else {
    // __call slow path: call_args is a heap buffer, no overlap.
    @memcpy(regs[0..nc], call_args[0..nc]);
}
```

**After:**
```zig
const np = new_proto.numparams;
const nc = @min(np, call_args.len);
// call_args always points into regs[a+1..] after inline resolution.
// copyForwards is overlap-safe when dst.ptr <= src.ptr (holds since
// regs[0] <= regs[a+1]).
std.mem.copyForwards(Value, regs[0..nc], call_args[0..nc]);
```

- [ ] **Step 4: Update varargs computation**

Find lines 9328-9342 (varargs dupe). The varargs offset uses `np` (numparams), which is correct. But `call_args.len` is now `effective_nargs` (which includes the `__call` self arg if applicable). The varargs computation at line 9332 uses `call_args.len > np`:

**Before:**
```zig
const va_src = if (new_proto.is_vararg and call_args.len > np)
    call_args[np..]
else
    &[_]Value{};
```

This is still correct — `call_args.len` is the effective arg count (including self), and `np` is the new function's parameter count. The slice `call_args[np..]` correctly captures the excess args as varargs.

No change needed — just verify it compiles.

- [ ] **Step 5: Update the dispatch switch**

Find line 9289 (`switch (resolved.callee) {`). Replace with `switch (callee_val)`:

**Before:**
```zig
switch (resolved.callee) {
    .Closure => |cl| if (cl.proto) |new_proto| { ... },
    .Builtin => {},
    else => {},
}
```

**After:**
```zig
switch (callee_val) {
    .Closure => |cl| if (cl.proto) |new_proto| { ... },
    .Builtin => {},
    else => {},
}
```

- [ ] **Step 6: Update the non-bytecode fallback path**

Find lines 9377-9459 (the fallback for builtins and IR closures). Replace `resolved.callee` references with `callee_val`:

**Before (representative):**
```zig
const ret = self.runClosure(cl, call_args, false) catch ...
...
try self.dispatchBytecodeHookWithCallee("return", resolved.callee, ret);
...
try self.tryPushBytecodeDebugHook(..., resolved.callee, ret, ...);
```

**After:**
```zig
const ret = self.runClosure(cl, call_args, false) catch ...
...
try self.dispatchBytecodeHookWithCallee("return", callee_val, ret);
...
try self.tryPushBytecodeDebugHook(..., callee_val, ret, ...);
```

- [ ] **Step 7: Verify build + tests**

Run: `zig build -Doptimize=Debug 2>&1 | tail -10`
Run: `zig build test -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 8: Run smoke tests**

```bash
for f in tests/smoke/*.lua; do
    ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"
done
```
Expected: 44/44 PASS.

- [ ] **Step 9: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.35: inline luaD_precall in OP_TAILCALL + simplify frame-reuse args copy"
```

---

### Task 4: Refactor OP_TFORCALL handler — same pattern + dupe elimination

Apply inline resolution to OP_TFORCALL (lines 9740-9827) and eliminate the unconditional `alloc.dupe`.

**Files:**
- Modify: `src/lua/vm.zig` — OP_TFORCALL handler (lines 9740-9827)

- [ ] **Step 1: Replace `resolveCallable` + `alloc.dupe` with inline resolution**

Find lines 9742-9751. Replace:

**Before:**
```zig
const iter = regs[a];
const state = regs[a + 1];
const ctrl = regs[a + 2];
const nresults: u8 = if (c == 0) 0 else c - 1;

var call_args = [_]Value{ state, ctrl };
const resolved = try self.resolveCallable(iter, call_args[0..], null);
defer if (resolved.owned_args) |owned| self.alloc.free(owned);
const rargs = try self.alloc.dupe(Value, resolved.args);
defer self.alloc.free(rargs);
```

**After:**
```zig
const nresults: u8 = if (c == 0) 0 else c - 1;

// ── PUC luaD_precall: inline callee type resolution ──
// TFORCALL has 2 fixed args (state, ctrl) at regs[a+1..a+3].
// If __call metamethod fires, the shift moves them to regs[a+2..a+4]
// and prepends the original iterator as regs[a+1] (self arg).
var effective_nargs: usize = 2;
var chain_depth: usize = 0;
while (true) {
    switch (regs[a]) {
        .Closure, .Builtin => break,
        else => {
            if (chain_depth >= 16) return self.fail("'__call' chain too long", .{});
            const current_callee = regs[a];
            try self.tryCallMetamethodInPlace(
                base, a, &effective_nargs, &frame_cap, &regs, &boxed, &chain_depth,
            ) catch |err| {
                if (err == error.RuntimeError and self.err != null and
                    std.mem.startsWith(u8, self.err.?, "attempt to call a "))
                {
                    return self.fail(
                        "attempt to call a {s} value (iterator)",
                        .{current_callee.typeName()},
                    );
                }
                return err;
            };
        },
    }
}
const callee_val = regs[a];
// Args are on bc_stack — no dupe needed. pushBytecodeExecFrame copies
// them into the child frame's registers. Pre-grow to keep the rargs
// slice valid across the push.
const child_frame_cap: usize = switch (callee_val) {
    .Closure => |cl| if (cl.proto) |p| p.maxstacksize else 0,
    else => 0,
};
try self.ensureBcStackCap(self.bc_stack_top + child_frame_cap);
regs = self.bc_stack[base .. base + frame_cap];
boxed = self.bc_boxed[base .. base + frame_cap];
const rargs = regs[a + 1 .. a + 1 + effective_nargs];
```

- [ ] **Step 2: Update references to `resolved`**

Find lines 9756-9826. Replace `resolved.callee` with `callee_val`:

**Before (line 9756):**
```zig
if (resolved.callee == .Closure) {
    const cl = resolved.callee.Closure;
```

**After:**
```zig
if (callee_val == .Closure) {
    const cl = callee_val.Closure;
```

**Before (line 9760):**
```zig
.callee = resolved.callee,
```

**After:**
```zig
.callee = callee_val,
```

**Before (line 9773):**
```zig
const ret = switch (resolved.callee) {
```

**After:**
```zig
const ret = switch (callee_val) {
```

- [ ] **Step 3: Verify build + tests**

Run: `zig build -Doptimize=Debug 2>&1 | tail -10`
Run: `zig build test -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 4: Run smoke tests**

```bash
for f in tests/smoke/*.lua; do
    ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"
done
```
Expected: 44/44 PASS. Pay attention to any `for ... in` iterator tests.

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.35: inline luaD_precall in OP_TFORCALL + eliminate alloc.dupe"
```

---

### Task 5: Add regression tests + full regression + perf + README

Add Lua-level regression tests for `__call` through the hot paths, run the full gate, measure perf, and update README.

**Files:**
- Create: `tests/smoke/45_p15_35_call_metamethod_inline.lua`
- Modify: `README.md`

- [ ] **Step 1: Create regression test for `__call` through OP_CALL**

Create `tests/smoke/45_p15_35_call_metamethod_inline.lua`:

```lua
-- P15.35 regression: __call metamethod through OP_CALL hot path.
-- Verifies that the in-place stack shift correctly prepends the callee
-- as argument 0 when a non-callable value is called.

-- Single __call resolution
local t = setmetatable({}, { __call = function(self, x)
    return x + 1
end})
assert(t(41) == 42, "single __call through OP_CALL")

-- __call with multiple args
local t2 = setmetatable({}, { __call = function(self, a, b, c)
    return a + b + c
end})
assert(t2(10, 20, 30) == 60, "__call with 3 args")

-- __call chain (2 levels)
local inner = setmetatable({}, { __call = function(self, x)
    return x * 2
end})
local outer = setmetatable({}, { __call = inner })
assert(outer(21) == 42, "__call chain depth 2")

-- __call in tail position (OP_TAILCALL)
local function tail_call(v)
    return v(100)  -- tail call on a callable table
end
assert(tail_call(t) == 101, "__call through OP_TAILCALL")

-- __call in for-in iterator (OP_TFORCALL)
local function iter_factory(arr)
    local i = 0
    return setmetatable({}, { __call = function(self, state, ctrl)
        i = i + 1
        if i <= #arr then
            return i, arr[i]
        end
    end}), arr, 0
end
local sum = 0
for idx, val in iter_factory({1, 2, 3, 4, 5}) do
    sum = sum + val
end
assert(sum == 15, "__call through OP_TFORCALL iterator")

-- Builtin called normally (fast path, no __call)
assert(type(42) == "number", "builtin fast path still works")
assert(tostring(42) == "42", "builtin with args still works")

print("P15.35 __call inline regression: OK")
```

- [ ] **Step 2: Run the regression test**

```bash
./zig-out/bin/luazig tests/smoke/45_p15_35_call_metamethod_inline.lua
```
Expected: prints `P15.35 __call inline regression: OK`.

- [ ] **Step 3: Build ReleaseFast**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 4: Zig unit tests**

Run: `zig build test -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5: All smoke tests (now 45/45)**

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

- [ ] **Step 6: Upstream matrix (per AGENTS.md, without `_soft`/`_port`)**

Run: `python3 tools/testes_matrix.py --timeout 120 2>&1 | tail -30`
Expected: 28/31 pass (same as pre-P15.35 baseline; no regressions). The 3 pre-existing fails (`attrib`, `big`, `files`) are unrelated.

- [ ] **Step 7: Stress test**

Run: `tools/iterative_dispatch_stress.sh 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 8: Perf measurement**

Run: `python3 tools/perf_compare.py --runs 7 --core 0 --no-build 2>&1 | tail -40`

Expected improvements:
- `lua_calls`: ~10-20% improvement (no resolveCallable function call on fast path, no ResolvedCall struct, no defer)
- `metamethod_add`: ~5-10% improvement (same call machinery; `__call` no longer heap-allocs)
- Other workloads: ±noise (unrelated to call resolution)

If `lua_calls` improvement is <5%, investigate with `perf record` before claiming success. Possible causes:
- Compiler already inlined `resolveCallable` (check with `perf record --call-graph lbr`)
- The fast path was already fast (the `resolveCallable` call was predicted well)
- The benchmark is bottlenecked elsewhere (frame push/pop, not resolution)

- [ ] **Step 9: Update baseline if perf improved**

If geomean improved by >3%:
```bash
python3 tools/perf_compare.py --runs 7 --core 0 --no-build --update-baseline 2>&1 | tail -10
```

- [ ] **Step 10: Update README**

Add a P15.35 section to README.md after the P15.39 section. Include:

```markdown
### P15.35 — PUC-faithful inline call resolution (luaD_precall + tryfuncTM)

Инлайнинг PUC `luaD_precall` (ldo.c:715-746) в три горячих bytecode-handler'а
(OP_CALL, OP_TAILCALL, OP_TFORCALL). Fast path (Closure/Builtin) больше не
вызывает `resolveCallable` — type switch происходит inline, нулевой overhead.
`__call` metamethod resolution использует in-place stack shift (PUC `tryfuncTM`,
ldo.c:523-536) вместо heap allocation `Value[args.len + 1]`.

Что изменилось:
1. `tryCallMetamethodInPlace` — новый метод на Vm, PUC `tryfuncTM` equivalent.
   Shifts `bc_stack[a..a+nargs+1]` up by 1 slot, writes metamethod to `regs[a]`.
2. OP_CALL: inline type switch + `tryCallMetamethodInPlace`. Eliminates
   `resolveCallable` call, `ResolvedCall` struct, `defer owned_args`,
   `rargs` derivation block, two-phase error retry, heap alloc for `__call`.
3. OP_TAILCALL: same inline pattern. Frame-reuse path simplified — always
   uses `copyForwards` (no `owned_args` branching).
4. OP_TFORCALL: same inline pattern + eliminates `alloc.dupe(resolved.args)`.

`resolveCallable` остаётся для 25 холодных сайтов (hooks, builtins, metamethods,
coroutine.resume, apiCall, IR backend). Эти сайты конструируют args в локальных
массивах, не на bc_stack — heap alloc для `__call` там малый и не влияет на perf.

**Результат:**

| Workload | До P15.35 | После P15.35 | Изменение |
|---|---:|---:|---:|
| lua_calls | <FILL> | <FILL> | <FILL> |
| metamethod_add | <FILL> | <FILL> | <FILL> |
| ... (geomean) | <FILL> | <FILL> | <FILL> |

(Fill in actual numbers from Step 8.)
```

Also close the P15.35 checkbox:
```
- [x] Прямой known-Lua-closure path без повторного `resolveCallable`.
  **P15.35:** PUC `luaD_precall` inlined into OP_CALL/OP_TAILCALL/OP_TFORCALL.
  Fast path (Closure/Builtin) exits inline type switch on first iteration —
  no function call, no struct, no heap alloc. `__call` uses in-place stack
  shift (PUC `tryfuncTM`). `resolveCallable` kept for 25 cold-path sites.
```

- [ ] **Step 11: Commit**

```bash
git add tests/smoke/45_p15_35_call_metamethod_inline.lua README.md tools/perf/baseline-p15.37.json
git commit -m "docs: P15.35 inline call resolution — update README + add __call regression test"
```

---

## Risk register

1. **bc_stack realloc during shift invalidates `regs`/`rargs`**
   - **Impact:** use-after-free if `regs` slice points to old allocation
   - **Mitigation:** `tryCallMetamethodInPlace` calls `bcGrowFrame` which re-derives `regs`/`boxed` through pointer parameters. After the call, the handler re-derives `regs = self.bc_stack[base..base+frame_cap]` before computing `rargs`.

2. **`outs_start` uses wrong arg count in Builtin branch**
   - **Impact:** builtin results overwrite the last argument (the `__call` self arg)
   - **Mitigation:** Task 2 Step 4 explicitly changes `outs_start` from `a + 1 + nargs` to `a + 1 + effective_nargs`.

3. **OP_TAILCALL frame-reuse path overlap with shifted args**
   - **Impact:** args clobbered during copy
   - **Mitigation:** Task 3 Step 3 simplifies to always use `copyForwards` (overlap-safe when `dst.ptr <= src.ptr`). This was already the fast-path behavior; we just remove the slow-path branch.

4. **Hook transfer reads stale callee**
   - **Impact:** debug hook sees the original non-callable value instead of the resolved metamethod
   - **Mitigation:** `callee_val = regs[a]` is read AFTER the resolution loop, so it's always the final resolved value (Closure/Builtin/metamethod).

5. **Lazy name inference not triggered on all error paths**
   - **Impact:** worse error messages (missing variable name in "attempt to call a X value")
   - **Mitigation:** The `catch` block in each handler checks for "attempt to call a" prefix and calls `debugBytecodeOperandName` to infer the name. This matches the previous two-phase retry behavior.

6. **`__call` chain causes N stack shifts**
   - **Impact:** stack overflow if chain is very deep
   - **Mitigation:** Same 16-depth limit as PUC (`CIST_CCMT`). Each shift grows the frame by 1 slot via `bcGrowFrame`. The `lua_max_call_frames` limit in `pushBytecodeExecFrame` (6000 frames) still applies.

7. **TFORCALL has fixed 2 args — shift changes the arg layout**
   - **Impact:** state/ctrl positions change after `__call` shift
   - **Mitigation:** Task 4 Step 1 handles this: `effective_nargs` starts at 2 and increments by 1 per chain step. The handler reads `rargs = regs[a+1..a+1+effective_nargs]` which correctly captures the shifted args.

## Self-review notes

- **Spec coverage:** The goal is "inline luaD_precall + eliminate heap alloc + integrate resolveCallable into OP_CALL". Tasks 1-4 do the inlining. Task 5 verifies.
- **Placeholder scan:** Every step has the full code or explicit "find lines X-Y and change Z to W" instructions. No "TODO" / "implement later".
- **Type consistency:** `tryCallMetamethodInPlace` signature is consistent across all three handlers. `callee_val` / `effective_nargs` / `chain_depth` naming is uniform.
- **`resolveCallable` NOT removed:** It stays for 25 cold-path sites. Only the 3 hot-path call sites are eliminated. This is documented in the plan and in the code comments.
