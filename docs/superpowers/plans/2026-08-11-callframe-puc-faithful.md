# PUC-faithful CallFrame / CALL-RETURN Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign CallFrame / dispatch to be PUC Lua 5.5-faithful, eliminating per-CALL overhead from PendingCallSlot, dispatch ctx round-trip, gcTempRoots, and Proto.live_reg_top mutation.

**Architecture:** One compact PUC-like CallFrame (union/flags/thread-state). Result contract for ordinary Lua CALL stored in callee frame's `callstatus` low 8 bits (PUC `CIST_NRESULTS`). Ordinary CALL does not use PendingCallSlot. Dispatch holds direct frame pointer with locally-cached `pc`. Iterative `frame_loop` preserved, no host recursion.

**Tech Stack:** Zig (system toolchain), PUC Lua 5.5 (vendored reference), luazig bytecode VM.

**Spec:** `docs/superpowers/specs/2026-08-10-callframe-hot-cold-split.md`

**Reference files (PUC Lua 5.5):**
- `lua-5.5.0/src/lstate.h:187-208` — `CallInfo` struct (64B on x86-64)
- `lua-5.5.0/src/lstate.h:222-254` — `callstatus` bits, `CIST_NRESULTS`, `get_nresults`
- `lua-5.5.0/src/ldo.c:715-746` — `luaD_precall` (encodes `nresults+1` into `callstatus`)
- `lua-5.5.0/src/ldo.c:540-611` — `moveresults` / `luaD_poscall` (reads `callstatus & CIST_NRESULTS`)
- `lua-5.5.0/src/lvm.c:1198-1216` — `luaV_execute` (local `pc` cached, `savepc` on safepoints)

**Key luazig files:**
- `src/lua/vm.zig` — Vm struct, CallFrame (L1057), BytecodeDispatchCtx (L7908), runBytecodeDispatch (L8035), pushBytecodeExecFrame (L7242), popBytecodeExecFrame (L7504), completeBytecodeExecFrame (L7535), opCall (L11359), opReturn (L10353), opReturn0 (L10452), opReturn1 (L10499), applyBytecodePendingResults (L5390), gcTempRoots (L4321), condGcFromDispatch (L4481)
- `src/lua/bytecode.zig` — Proto struct, `live_reg_top` field (L479)

**Test commands:**
```bash
# Build ReleaseFast (required before tests)
zig build -Doptimize=ReleaseFast

# Regression tests (all must pass, no regressions)
python3 tools/testes_matrix.py --testc          # matrix 30/31
python3 tools/smoke_compare.py                   # smoke 49/49
python3 tools/leak_bench.py                      # leakbench 25/25
zig build test -Doptimize=Debug                  # unit tests 146/146

# Performance gate
python3 tools/perf_compare.py                    # geomean, WARN +5%, FAIL +10%

# Codegen gate
python3 tools/codegen_compare.py                 # 30/31 patterns
```

**AGENTS.md rules (critical):**
- No match-by-name / line-range / special-case hacks
- PUC-first: architecture follows PUC Lua 5.5
- Each step: separate commit + perf A/B
- `frame_loop` preserved, no host recursion
- After each task: update STATUS.md, run regression tests

---

## Task 1: Add `callstatus` field to CallFrame (additive, no behavior change)

**Goal:** Add a `callstatus: u32` field to `CallFrame` and encode `nresults+1` in its low 8 bits (PUC `CIST_NRESULTS`), matching PUC `luaD_precall` (`ldo.c:716`). No existing fields removed, no behavior changed — purely additive infrastructure for Task 2.

**Files:**
- Modify: `src/lua/vm.zig:1057-1147` (CallFrame struct)
- Modify: `src/lua/vm.zig:7242-7502` (pushBytecodeExecFrame — set callstatus)
- Modify: `src/lua/vm.zig:7504-7533` (popBytecodeExecFrame — clear callstatus)

- [ ] **Step 1: Add callstatus constants and field**

In `src/lua/vm.zig`, add constants near the CallFrame definition (before `const CallFrame = struct {`):

```zig
/// PUC `CIST_NRESULTS` (`lstate.h:223`): low 8 bits of callstatus encode
/// `nresults + 1`. MULTRET (`LUA_MULTRET = -1`) encodes as `0`.
/// `MAXRESULTS = 250` fits (`251 <= 255`).
const CIST_NRESULTS: u32 = 0xff;
const MAXRESULTS: i32 = 250;

/// Encode nresults into callstatus low 8 bits (PUC `ldo.c:716`).
/// MULTRET (-1) encodes as 0. Non-negative encodes as nresults + 1.
inline fn encodeNresults(nresults: i32) u32 {
    return @intCast(@as(u32, @bitCast(@as(i32, nresults + 1))) & CIST_NRESULTS);
}

/// Decode nresults from callstatus low 8 bits (PUC `get_nresults`, `lstate.h:254`).
/// 0 → MULTRET (-1). Non-zero → value - 1.
inline fn decodeNresults(callstatus: u32) i32 {
    const raw: u32 = callstatus & CIST_NRESULTS;
    return @as(i32, @intCast(raw)) - 1;
}
```

Add `callstatus: u32 = 0` field to CallFrame struct (after `nextraargs: u16 = 0`):

```zig
    /// PUC `callstatus` (`lstate.h:208`): low 8 bits = nresults+1 (CIST_NRESULTS),
    /// upper bits = flags (to be populated in later tasks).
    callstatus: u32 = 0,
```

- [ ] **Step 2: Encode nresults in pushBytecodeExecFrame**

In `pushBytecodeExecFrame` (`src/lua/vm.zig:7242`), the function currently receives `nresults` implicitly via the caller's `pending_call`. We need to add a `nresults: i32` parameter and encode it.

Change the signature from:
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
to:
```zig
    fn pushBytecodeExecFrame(
        self: *Vm,
        exec_frames: *FrameStack,
        proto: *const bc.Proto,
        upvalues: []const *Cell,
        args: []const Value,
        callee_cl: ?*Closure,
        caller_func_slot: usize,
        nresults: i32,
    ) DispatchError!void {
```

In the field-write block (after `ef_slot.nextraargs = @intCast(nextra);`), add:
```zig
        ef_slot.callstatus = encodeNresults(nresults);
```

- [ ] **Step 3: Update all pushBytecodeExecFrame call sites**

Search for all callers of `pushBytecodeExecFrame` and add the `nresults` argument:

```bash
grep -n "pushBytecodeExecFrame(" src/lua/vm.zig
```

Each caller must pass the `nresults` value. In `opCall` (L11675), the caller already has `nresults: i32` — pass it:
```zig
try self.pushBytecodeExecFrame(ctx.exec_frames, proto2, cl.upvalues, rargs, cl, ctx.base + a, nresults);
```

For other callers (runBytecodeInternal, coroutine resume, debug hooks, etc.), pass the appropriate nresults value (typically `LUA_MULTRET = -1` for host-initiated calls, or the specific count if known).

- [ ] **Step 4: Clear callstatus in popBytecodeExecFrame**

In `popBytecodeExecFrame` (`src/lua/vm.zig:7504`), the frame is popped via `shrinkTo` which doesn't zero fields. Since frames are reused, stale `callstatus` could leak. Add explicit clear before shrink:

After `self.bc_tbc_regs.items.len = frame.tbc_mark;` and before `exec_frames.shrinkTo(idx);`:
```zig
        frame.callstatus = 0;
```

- [ ] **Step 5: Build and verify no behavior change**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
python3 tools/smoke_compare.py
python3 tools/leak_bench.py
```

Expected: All pass (30/31, 49/49, 25/25). No behavior change — callstatus is set but not yet read.

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51a: add callstatus field to CallFrame (PUC CIST_NRESULTS encoding, additive)"
```

---

## Task 2: Read nresults from callee callstatus in RETURN (dual-write)

**Goal:** In `completeBytecodeExecFrame`, read `nresults` from the callee's `callstatus` (PUC `luaD_poscall` reads `ci->callstatus & CIST_NRESULTS`) instead of `pending_call.completion.results.nresults`. Still set `pending_call` for now (dual-write) — this is a safe transition step.

**Files:**
- Modify: `src/lua/vm.zig:7535-7645` (completeBytecodeExecFrame)
- Modify: `src/lua/vm.zig:5390-5448` (applyBytecodePendingResults — add nresults parameter)

- [ ] **Step 1: Add nresults parameter to applyBytecodePendingResults**

In `applyBytecodePendingResults` (`src/lua/vm.zig:5390`), change signature to accept `nresults` from the callee's callstatus instead of reading from `pending_call`:

```zig
    fn applyBytecodePendingResults(
        self: *Vm,
        exec_frames: *FrameStack,
        parent_index: usize,
        ret: []Value,
        dst: usize,
        nresults: i32,
    ) DispatchError!void {
```

Remove the `result_cont` extraction from `pending_call`. Use the `dst` and `nresults` parameters directly. Replace `result_cont.dst` with `dst` and `result_cont.nresults` with `nresults` throughout the function body.

Keep `parent.pending_call.clear()` at the end (still clearing the pending slot).

- [ ] **Step 2: In completeBytecodeExecFrame, read nresults from callee callstatus**

In `completeBytecodeExecFrame` (`src/lua/vm.zig:7535`), BEFORE `popBytecodeExecFrame`, read the callee's callstatus:

```zig
        const child_idx = exec_frames.len() - 1;
        const child_frame = exec_frames.getPtr(child_idx);
        const callee_nresults = decodeNresults(child_frame.callstatus);
        const callee_func_slot = child_frame.func_slot;
```

After `popBytecodeExecFrame`, when reaching the `.results => |cont|` switch case, compute `dst` from the callee's func_slot and the parent's base:

```zig
        const parent = exec_frames.getPtr(parent_index);
        const dst = callee_func_slot - parent.base;
        try self.applyBytecodePendingResults(exec_frames, parent_index, completed_ret, dst, callee_nresults);
```

Keep the `pending_call` set/clear as-is (dual-write). The `pending_call.completion.results.dst` and `.nresults` are now redundant but still set — they will be removed in Task 3.

- [ ] **Step 3: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
python3 tools/smoke_compare.py
python3 tools/leak_bench.py
python3 tools/perf_compare.py
```

Expected: All tests pass. Perf should be neutral (dual-write adds no measurable overhead, reading from callstatus is as cheap as reading from pending_call).

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51b: read nresults from callee callstatus in RETURN (dual-write transition)"
```

---

## Task 3: Remove PendingCallSlot from ordinary Lua CALL path

**Goal:** In `opCall` for `.Closure` with proto, do NOT set `pending_call` at all. The result contract is fully in the callee's `callstatus` (nresults) and `func_slot` (dst derivation). In `completeBytecodeExecFrame`, detect ordinary Lua CALL by checking `pending_call` is empty — if so, use callee callstatus directly.

**Files:**
- Modify: `src/lua/vm.zig:11359-11736` (opCall — remove pending_call.set for .Closure with proto)
- Modify: `src/lua/vm.zig:7535-7645` (completeBytecodeExecFrame — handle empty pending_call)

- [ ] **Step 1: Remove pending_call.set from opCall .Closure-with-proto path**

In `opCall` (`src/lua/vm.zig:11661-11677`), the `.Closure => |cl|` branch with `cl.proto` currently does:
```zig
            .Closure => |cl| {
                if (cl.proto) |proto2| {
                    ctx.exec_frames.getPtr(ctx.frame_index).pending_call.set(.{
                        .callee = callee_val,
                        .completion = .{ .results = .{
                            .dst = a,
                            .nresults = nresults,
                        } },
                    });
                    try self.pushBytecodeExecFrame(ctx.exec_frames, proto2, cl.upvalues, rargs, cl, ctx.base + a, nresults);
                    return .continue_frame_loop;
                }
```

Remove the `pending_call.set(...)` call. The callee frame's `callstatus` (set by `pushBytecodeExecFrame`) and `func_slot` are the sole result contract:

```zig
            .Closure => |cl| {
                if (cl.proto) |proto2| {
                    // PUC-faithful: result contract is in callee's callstatus
                    // (CIST_NRESULTS) and func_slot (dst derivation). No
                    // pending_call needed for ordinary Lua CALL.
                    try self.pushBytecodeExecFrame(ctx.exec_frames, proto2, cl.upvalues, rargs, cl, ctx.base + a, nresults);
                    return .continue_frame_loop;
                }
```

Keep the `pending_call.set(...)` for the IR-closure path (no proto) — that path still needs host recursion and pending_call.

- [ ] **Step 2: Handle empty pending_call in completeBytecodeExecFrame**

In `completeBytecodeExecFrame` (`src/lua/vm.zig:7535`), after `popBytecodeExecFrame`, check if the parent has a pending_call. If not (ordinary Lua CALL), use the callee-derived `dst` and `callee_nresults` directly:

```zig
        const parent_index = exec_frames.len() - 1;
        const parent = exec_frames.getPtr(parent_index);
        
        // PUC-faithful: ordinary Lua CALL has no pending_call. Result
        // contract is in callee's callstatus (nresults) + func_slot (dst).
        if (parent.pending_call.get() == null) {
            const dst = callee_func_slot - parent.base;
            try self.applyBytecodeResultsDirect(exec_frames, parent_index, completed_ret, dst, callee_nresults);
            return null;
        }
        
        // Special calls (builtins, metamethods, hooks, pcall, etc.)
        // still use pending_call.
        const pending = parent.pending_call.get() orelse unreachable;
        // ... existing pending_call handling ...
```

Add a new `applyBytecodeResultsDirect` function (simplified version of `applyBytecodePendingResults` that doesn't read or clear pending_call):

```zig
    fn applyBytecodeResultsDirect(
        self: *Vm,
        exec_frames: *FrameStack,
        parent_index: usize,
        ret: []Value,
        dst: usize,
        nresults: i32,
    ) DispatchError!void {
        errdefer if (!self.returnSliceIsOwned(ret)) self.alloc.free(ret);
        const parent = exec_frames.getPtr(parent_index);
        var regs = self.bc_stack[parent.base .. parent.base + parent.frame_cap];
        var boxed = self.bc_boxed[parent.base .. parent.base + parent.frame_cap];
        const nstore: usize = if (nresults >= 0) @intCast(nresults) else ret.len;
        try self.bcGrowFrame(parent.base, dst + nstore, &parent.frame_cap, &regs, &boxed);
        for (0..nstore) |i| regs[dst + i] = if (i < ret.len) ret[i] else .Nil;
        if (nresults < 0) parent.reg_top = @intCast(@as(usize, dst) + ret.len);
        parent.pc += 1;
        if (!self.returnSliceIsOwned(ret)) self.alloc.free(ret);
    }
```

Note: `applyBytecodeResultsDirect` does NOT call `pending_call.clear()` (there is none) and does NOT update `live_reg_top` (that's Task 4). It does advance `parent.pc += 1` (PUC `luaD_poscall` returns to caller, caller's `luaV_execute` advances pc).

- [ ] **Step 3: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
python3 tools/smoke_compare.py
python3 tools/leak_bench.py
python3 tools/perf_compare.py
```

Expected: All tests pass. Perf should improve on lua_calls benchmark (no pending_call set+clear per CALL).

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51c: remove PendingCallSlot from ordinary Lua CALL (PUC-faithful callee-frame result contract)"
```

---

## Task 4: Remove Proto.live_reg_top runtime mutation

**Goal:** Remove all `@constCast(proto).live_reg_top[pc] = ...` runtime writes. Dynamic register liveness lives in `frame.reg_top`. GC uses `max(proto.live_reg_top[pc], frame.reg_top)` — static metadata is compile-time, not mutated at runtime.

**Files:**
- Modify: `src/lua/vm.zig:5390-5448` (applyBytecodePendingResults — remove live_reg_top writes)
- Modify: `src/lua/vm.zig:5411-5443` (applyBytecodeResultsDirect — no live_reg_top writes)
- Modify: `src/lua/vm.zig:11628-11653` (opCall builtin path — remove live_reg_top writes)
- Modify: `src/lua/vm.zig` — all `@constCast(proto).live_reg_top` sites (search and remove)

- [ ] **Step 1: Find all live_reg_top mutation sites**

```bash
grep -n "@constCast.*live_reg_top\|live_reg_top\[.*\] =" src/lua/vm.zig
```

Document every site. These are the runtime mutations to remove.

- [ ] **Step 2: Remove live_reg_top writes from applyBytecodePendingResults**

In `applyBytecodePendingResults` (`src/lua/vm.zig:5411-5443`), remove the entire block:
```zig
        // P15.36: Extend live_reg_top to cover the just-written result
        // registers...
        if (parent.proto) |proto| {
            ...
        }
```

The `parent.reg_top` is already set correctly by the line `if (result_cont.nresults < 0) parent.reg_top = ...`. GC will use `max(proto.live_reg_top[pc], frame.reg_top)` — the static liveness is a lower bound, `reg_top` is the dynamic upper bound.

- [ ] **Step 3: Remove live_reg_top writes from opCall builtin path**

In `opCall` builtin path (`src/lua/vm.zig:11628-11653`), remove the block:
```zig
                {
                    const proto = ctx.cur_proto;
                    if (ctx.pc < proto.live_reg_top.len) {
                        ...
                    }
                }
```

- [ ] **Step 4: Verify GC uses max(static, dynamic) for liveness**

Search for where GC reads `live_reg_top`:
```bash
grep -n "live_reg_top" src/lua/vm.zig | grep -v "@constCast"
```

Verify that every GC read site uses `max(proto.live_reg_top[pc], frame.reg_top)`. If any site uses only `live_reg_top[pc]`, fix it to use the max. This ensures GC marks all live registers even after removing runtime mutation.

- [ ] **Step 5: Build and test (focus on GC regression)**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
python3 tools/smoke_compare.py
python3 tools/leak_bench.py
python3 tools/perf_compare.py
```

Expected: All tests pass. GC tests (gc, coroutine, nextvar) are the critical regression targets. Perf should improve slightly (fewer writes per CALL/RETURN).

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51d: remove Proto.live_reg_top runtime mutation (use max(static, frame.reg_top) for GC)"
```

---

## Task 5: Conditional gcTempRoots on RETURN

**Goal:** In `completeBytecodeExecFrame`, skip `gcTempRoots` on the common RETURN path (ordinary Lua frame returning to ordinary Lua frame, no allocation on move-results path). Keep `gcTempRoots` before any GC-triggering operation.

**Files:**
- Modify: `src/lua/vm.zig:7535-7645` (completeBytecodeExecFrame)
- Modify: `src/lua/vm.zig:5390-5448` (applyBytecodePendingResults / applyBytecodeResultsDirect)

- [ ] **Step 1: Analyze gcTempRoots usage in completeBytecodeExecFrame**

In `completeBytecodeExecFrame` (`src/lua/vm.zig:7544-7546`):
```zig
        var return_roots = self.gcTempRoots();
        defer return_roots.end();
        for (ret) |value| try return_roots.add(value);
```

This protects `ret` (return values) across `closeBytecodeUpvaluesFrom` and `popBytecodeExecFrame`. The return values are in the child frame's registers (already on `bc_stack`), which is a GC root. The risk is that `closeBytecodeUpvaluesFrom` may trigger `__close` metamethods which run Lua code and could trigger GC.

- [ ] **Step 2: Split gcTempRoots — only when __close may run**

Replace the unconditional `gcTempRoots` with a conditional:

```zig
        const child_idx = exec_frames.len() - 1;
        const child_frame = exec_frames.getPtr(child_idx);
        const needs_close = child_frame.has_open_upvalues and
            self.bc_tbc_regs.items.len > child_frame.tbc_mark;
        
        if (needs_close) {
            // __close metamethods may run Lua code → GC may trigger.
            // Protect return values across the close.
            var return_roots = self.gcTempRoots();
            defer return_roots.end();
            for (ret) |value| try return_roots.add(value);
            if (child_frame.has_open_upvalues)
                self.closeBytecodeUpvaluesFrom(child_frame, 0);
            self.popBytecodeExecFrame(exec_frames);
            // ... continue with result application ...
        } else {
            // Common path: no __close, no GC trigger between here and
            // result application. Return values are on bc_stack (GC root).
            if (child_frame.has_open_upvalues)
                self.closeBytecodeUpvaluesFrom(child_frame, 0);
            self.popBytecodeExecFrame(exec_frames);
            // ... continue with result application ...
        }
```

Note: `closeBytecodeUpvaluesFrom` without TBC is cheap (just closes Cell objects, no Lua code). The GC-triggering path is only when TBC variables exist (`bc_tbc_regs.items.len > tbc_mark`).

- [ ] **Step 3: Verify applyBytecodeResultsDirect doesn't need gcTempRoots**

In `applyBytecodeResultsDirect`, the operations are:
- `bcGrowFrame` — may realloc bc_stack but doesn't trigger GC
- Register writes — no GC
- `alloc.free(ret)` — no GC

No GC-triggering operation between `popBytecodeExecFrame` and the end of `applyBytecodeResultsDirect`. So no `gcTempRoots` needed on the common path.

For `applyBytecodePendingResults` (special calls path), keep `gcTempRoots` — special calls may involve hooks, metamethods, etc.

- [ ] **Step 4: Build and test (focus on leakbench)**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/leak_bench.py
python3 tools/testes_matrix.py --testc
python3 tools/smoke_compare.py
python3 tools/perf_compare.py
```

Expected: All tests pass. leakbench 25/25 (no leaks). Perf should improve on lua_calls (no gcTempRoots setup/teardown per RETURN).

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51e: conditional gcTempRoots on RETURN (skip when no GC-triggering ops on common path)"
```

---

## Task 6: Remove duplicated `callee` field from CallFrame

**Goal:** Remove `callee: Value` from CallFrame. The callee is already at `bc_stack[func_slot]` — derive it on demand (PUC `ci->func` points into the shared stack).

**Files:**
- Modify: `src/lua/vm.zig:1057-1147` (CallFrame struct — remove callee field)
- Modify: `src/lua/vm.zig:7242-7502` (pushBytecodeExecFrame — remove callee write)
- Modify: `src/lua/vm.zig` — all `frame.callee` / `fr.callee` read sites

- [ ] **Step 1: Find all callee read sites**

```bash
grep -n "\.callee\b" src/lua/vm.zig | grep -v "pending_call\|callee_cl\|callee_val\|resolved_callee\|frame_callee\|current_callee"
```

These are the sites that read `frame.callee` directly. Each must be replaced with `self.bc_stack[frame.func_slot]`.

- [ ] **Step 2: Add accessor function**

Add to CallFrame struct:
```zig
    /// PUC `ci_func(ci)` equivalent: read the function value from bc_stack[func_slot].
    /// The callee is NOT stored in the frame — it lives in the shared stack
    /// (PUC `ci->func` points into `L->stack`).
    pub fn callee(self: *const CallFrame, bc_stack: []const Value) Value {
        return bc_stack[self.func_slot];
    }
```

- [ ] **Step 3: Replace all frame.callee reads with frame.callee(bc_stack)**

Update each read site from `frame.callee` to `frame.callee(self.bc_stack)`.

- [ ] **Step 4: Remove callee field and its writes**

Remove `callee: Value = .Nil` from CallFrame struct. Remove `ef_slot.callee = frame_callee;` from pushBytecodeExecFrame. Remove `const frame_callee: Value = ...` if no longer used.

- [ ] **Step 5: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
python3 tools/smoke_compare.py
python3 tools/leak_bench.py
python3 tools/perf_compare.py
```

Expected: All tests pass. Perf neutral or slight improvement (one less field write per CALL).

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51f: remove duplicated callee field from CallFrame (derive from bc_stack[func_slot])"
```

---

## Task 7: Remove duplicated `regs`/`boxed` slices from CallFrame

**Goal:** Remove `regs: []Value` and `boxed: []?*Cell` from CallFrame. These are fully determined by `base + frame_cap` and can be derived on demand. This eliminates stale slices after bc_stack realloc.

**Files:**
- Modify: `src/lua/vm.zig:1057-1147` (CallFrame struct — remove regs, boxed)
- Modify: `src/lua/vm.zig:7242-7502` (pushBytecodeExecFrame — remove regs/boxed writes)
- Modify: `src/lua/vm.zig` — all `frame.regs` / `frame.boxed` read sites
- Modify: `src/lua/vm.zig` — ensureBcStackCap (remove frame.regs/boxed update)

- [ ] **Step 1: Find all frame.regs / frame.boxed read sites**

```bash
grep -n "frame\.regs\|frame\.boxed\|fr\.regs\|fr\.boxed\|ef_slot\.regs\|ef_slot\.boxed\|\.regs\b" src/lua/vm.zig | head -40
```

- [ ] **Step 2: Add accessor functions**

Add to CallFrame struct:
```zig
    /// Derive register slice from base + frame_cap (PUC: `ci->func + 1 .. ci->top`).
    /// NOT stored in the frame — eliminates stale slices after bc_stack realloc.
    pub fn regsSlice(self: *const CallFrame, bc_stack: []Value) []Value {
        return bc_stack[self.base .. self.base + self.frame_cap];
    }
    pub fn boxedSlice(self: *const CallFrame, bc_boxed: []?*Cell) []?*Cell {
        return bc_boxed[self.base .. self.base + self.frame_cap];
    }
```

- [ ] **Step 3: Replace all frame.regs / frame.boxed reads**

Replace `frame.regs` with `frame.regsSlice(self.bc_stack)` and `frame.boxed` with `frame.boxedSlice(self.bc_boxed)` at each read site.

For hot paths (inner dispatch loop), the `BytecodeDispatchCtx` already caches `regs`/`boxed` as local fields — those stay. Only the frame struct field is removed.

- [ ] **Step 4: Remove regs/boxed from ensureBcStackCap frame update**

In `ensureBcStackCap` and the stack-overflow path in `pushBytecodeExecFrame`, remove the `fr.regs = ...` / `fr.boxed = ...` updates. These are no longer needed since the frame doesn't store slices.

- [ ] **Step 5: Remove regs/boxed fields and their writes**

Remove `regs: []Value = &.{}` and `boxed: []?*Cell = &.{}` from CallFrame. Remove `ef_slot.regs = regs;` and `ef_slot.boxed = boxed;` from pushBytecodeExecFrame.

- [ ] **Step 6: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
python3 tools/smoke_compare.py
python3 tools/leak_bench.py
python3 tools/perf_compare.py
```

Expected: All tests pass. Perf neutral or slight improvement (no stale-slice updates on realloc).

- [ ] **Step 7: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51g: remove duplicated regs/boxed slices from CallFrame (derive from base+frame_cap)"
```

---

## Task 8: Eliminate loadDispatchCtx/syncDispatchCtx round-trip

**Goal:** Replace `loadDispatchCtx`/`syncDispatchCtx` (~30 field copies per CALL) with direct frame pointer access. The interpreter loop caches `pc` as a local variable (PUC `luaV_execute:1202`), syncing to `frame.pc` only on safepoints (calls, returns, hooks, errors, GC).

**Files:**
- Modify: `src/lua/vm.zig:8035-8200` (runBytecodeDispatch — restructure frame access)
- Modify: `src/lua/vm.zig:7974-8033` (loadDispatchCtx/syncDispatchCtx — remove or simplify)
- Modify: `src/lua/vm.zig:7908-7943` (BytecodeDispatchCtx — simplify, keep only non-frame-cached state)

- [ ] **Step 1: Restructure runBytecodeDispatch to use direct frame pointer**

In `runBytecodeDispatch` (`src/lua/vm.zig:8035`), replace the `loadDispatchCtx` call with direct frame pointer access. Keep `pc` as a local variable:

```zig
        frame_loop: while (exec_frames.len() > boundary_depth) {
            ctx.frame_index = exec_frames.len() - 1;
            const fr = exec_frames.getPtr(ctx.frame_index);
            
            // PUC luaV_execute: cache hot state as locals.
            // fr is the direct frame pointer (like PUC L->ci).
            var pc = fr.pc;
            const cur_proto = fr.proto.?;
            const base = fr.base;
            const frame_cap = fr.frame_cap;
            var reg_top = fr.reg_top;
            // ... other hot fields as locals ...
            
            // regs/boxed derived from base+frame_cap (not stored in frame after Task 7)
            var regs = self.bc_stack[base .. base + frame_cap];
            var boxed = self.bc_boxed[base .. base + frame_cap];
```

- [ ] **Step 2: Replace ctx.field with local variables in inner loop**

In the inner `while (pc < cur_proto.code.len)` loop, replace all `ctx.pc` with `pc`, `ctx.reg_top` with `reg_top`, `ctx.regs` with `regs`, etc. The inner loop touches only locals — no frame pointer dereference for hot state.

- [ ] **Step 3: Sync pc to frame only on safepoints**

Replace the `defer { self.syncDispatchCtx(&ctx); }` with targeted syncs:

```zig
            // Sync pc to frame on safepoint boundaries (PUC savepc(ci)).
            // Called before: calls, returns, hooks, errors, GC, yields.
            inline fn savepc() void {
                exec_frames.getPtr(ctx.frame_index).pc = pc;
            }
```

Call `savepc()` (or inline `fr.pc = pc;`) at:
- OP_CALL (before pushing child frame)
- OP_RETURN (before pop)
- Hook dispatch (before calling hook)
- GC safepoint (before condGcFromDispatch)
- Error propagation (before fail)
- Yield (before park)

- [ ] **Step 4: Remove loadDispatchCtx/syncDispatchCtx**

Delete `loadDispatchCtx` and `syncDispatchCtx` functions. They are no longer needed — the frame pointer is accessed directly, and hot state is cached as locals.

- [ ] **Step 5: Simplify BytecodeDispatchCtx**

`BytecodeDispatchCtx` can be reduced to only the non-frame-cached state:
```zig
    const BytecodeDispatchCtx = struct {
        exec_frames: *FrameStack,
        frame_index: usize,
        boundary_depth: usize,
        yielded_in_place: *bool,
        hooks_active: bool,
    };
```

All other fields are now locals in `runBytecodeDispatch`.

- [ ] **Step 6: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
python3 tools/smoke_compare.py
python3 tools/leak_bench.py
python3 tools/perf_compare.py
```

Expected: All tests pass. Perf should improve on lua_calls (no 30-field copy per CALL).

- [ ] **Step 7: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51h: eliminate loadDispatchCtx/syncDispatchCtx (direct frame pointer, locally-cached pc)"
```

---

## Task 9: Move debug/hook fields to Thread, derive debug name on demand

**Goal:** Move per-frame debug/hook fields (`debug_namewhat`, `debug_name`, `is_debug_hook`, `debug_hook_*`) to `Thread` or derive on demand. Replace individual bool fields with `callstatus` flag bits.

**Files:**
- Modify: `src/lua/vm.zig:1057-1147` (CallFrame — remove debug fields)
- Modify: `src/lua/vm.zig:1226-1353` (Thread — add debug/hook state)
- Modify: `src/lua/vm.zig` — all debug field read/write sites

- [ ] **Step 1: Define callstatus flag bits**

Add PUC-style flag constants:
```zig
const CIST_C: u32 = 1 << 15;        // call is running a C function
const CIST_FRESH: u32 = 1 << 16;    // fresh luaV_execute frame
const CIST_CLSRET: u32 = 1 << 17;   // function is closing tbc variables
const CIST_TBC: u32 = 1 << 18;      // function has tbc variables to close
const CIST_OAH: u32 = 1 << 19;      // original value of allowhook
const CIST_HOOKED: u32 = 1 << 20;   // call is running a debug hook
const CIST_YPCALL: u32 = 1 << 21;   // doing a yieldable protected call
const CIST_TAIL: u32 = 1 << 22;     // call was tail called
const CIST_HOOKYIELD: u32 = 1 << 23; // last hook called yielded
const CIST_FIN: u32 = 1 << 24;      // function "called" a finalizer
```

- [ ] **Step 2: Replace bool fields with callstatus flags**

Replace:
- `is_tailcall: bool` → `CIST_TAIL` bit in callstatus
- `is_debug_hook: bool` → `CIST_HOOKED` bit in callstatus
- `resumed_direct_yield: bool` → `CIST_HOOKYIELD` or dedicated bit
- `hide_from_debug: bool` → dedicated bit or Thread-level flag

Add helper functions:
```zig
    pub fn isTailCall(fr: CallFrame) bool {
        return (fr.callstatus & CIST_TAIL) != 0;
    }
    pub fn isDebugHook(fr: CallFrame) bool {
        return (fr.callstatus & CIST_HOOKED) != 0;
    }
```

- [ ] **Step 3: Remove debug_namewhat / debug_name (derive on demand)**

Remove `debug_namewhat: ?[]const u8` and `debug_name: ?[]const u8` from CallFrame. Derive from `proto` + `func_slot` + `callstatus` when `debug.getinfo` is called:

```zig
    pub fn debugNamewhat(fr: CallFrame) []const u8 {
        if (fr.proto == null) return "C";
        if (fr.isTailCall()) return "tail";
        return "Lua";
    }
    pub fn debugName(fr: CallFrame) []const u8 {
        if (fr.proto) |p| return p.name;
        return "?";
    }
```

- [ ] **Step 4: Move debug_hook_transfer state to Thread**

Move `debug_hook_transfer`, `debug_hook_transfer_start`, `debug_hook_event_*`, `debug_hook_allow_yield` from CallFrame to Thread. These are single-valued (at most one hook active at a time).

- [ ] **Step 5: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
python3 tools/smoke_compare.py
python3 tools/leak_bench.py
python3 tools/perf_compare.py
```

Expected: All tests pass. CallFrame size reduced. Perf neutral (debug paths are cold).

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51i: move debug/hook fields to Thread, derive debug name on demand (callstatus flags)"
```

---

## Task 10: Union for Lua-frame vs C-frame state

**Goal:** Create a `union` for mutually-exclusive Lua-frame vs C-frame state in CallFrame, matching PUC `CallInfo.u` (`lstate.h:191-202`). Lua-frame: `savedpc` (already local), `trap`, `nextraargs`. C-frame: `k` (continuation), `old_errfunc`, `ctx`.

**Files:**
- Modify: `src/lua/vm.zig:1057-1147` (CallFrame — add union)
- Modify: `src/lua/vm.zig` — all sites that set/read union fields

- [ ] **Step 1: Define the union**

Replace individual fields with a union:
```zig
    /// PUC CallInfo.u (`lstate.h:191-202`): Lua-frame vs C-frame state.
    /// Lua-frame: nextraargs (vararg), trap (line hook).
    /// C-frame: continuation (k), old_errfunc, ctx.
    /// No third "coroutine" variant — yield/resume is execution state
    /// (callstatus flags + u2.nyield), not a function type.
    u: union(enum) {
        lua: struct {
            nextraargs: u16 = 0,
        },
        c: struct {
            k: ?*const anyopaque = null,  // lua_KFunction equivalent
            old_errfunc: usize = 0,
            ctx: usize = 0,
        },
    } = .{ .lua = .{} },
```

- [ ] **Step 2: Migrate nextraargs to union**

Replace `fr.nextraargs` with `fr.u.lua.nextraargs` at all sites. For C-frames (synthetic C-call frames), the `u` variant is `.c`.

- [ ] **Step 3: Migrate C-call continuation state to union**

Move `PendingCallSlot`'s C-continuation fields (`k`, `ctx`, `old_errfunc`) into `u.c` when the frame is a C-frame. This may require restructuring how `PendingCallSlot` stores continuation state — but for ordinary Lua CALL (Task 3 already removed pending_call), this only affects special calls.

- [ ] **Step 4: Build and test**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
python3 tools/smoke_compare.py
python3 tools/leak_bench.py
python3 tools/perf_compare.py
```

Expected: All tests pass. CallFrame size reduced (union saves space vs separate fields).

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.51j: union for Lua-frame vs C-frame state (PUC CallInfo.u, no coroutine variant)"
```

---

## Post-Implementation Verification

After all 10 tasks:

- [ ] **Final regression suite:**
```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py --testc
python3 tools/smoke_compare.py
python3 tools/leak_bench.py
zig build test -Doptimize=Debug
python3 tools/perf_compare.py
python3 tools/codegen_compare.py
```

- [ ] **Verify CallFrame size reduction:**
```bash
# Add a temporary @sizeOf(CallFrame) print and compare ~400B → target <100B
```

- [ ] **Update STATUS.md** with P15.51 completion summary.

- [ ] **Update baseline if perf improved significantly:**
```bash
python3 tools/perf_compare.py --update-baseline
```

## Invariants (all tasks)

- `frame_loop` preserved — no host recursion
- PUC-faithful: result contract in callee frame (`callstatus` + `func_slot`)
- Cold paths still work: debug hooks, coroutines, protected calls, TBC
- No test regressions: matrix 30/31, smoke 49/49, leakbench 25/25, zig build test 146/146
- No match-by-name / line-range / special-case hacks (AGENTS.md)
- Each task: separate commit + perf A/B
