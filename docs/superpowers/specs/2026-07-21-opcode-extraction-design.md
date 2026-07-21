# Bytecode Dispatch Opcode Extraction — Design Spec

**Date:** 2026-07-21
**Status:** Design
**Spec ID:** 2026-07-21-opcode-extraction
**Blocks:** Host recursion plan (`docs/superpowers/plans/2026-07-21-host-recursion.md`)

## Motivation

`runBytecodeDispatch` (src/lua/vm.zig:7283) has a C stack frame of **139 KB** in Debug and **20 KB** in ReleaseFast (measured via gdb). This blocks the PUC-faithful host recursion refactor:

- PUC Lua's `luaV_execute` is host-recursive for OP_CALL (`luaD_call` → `ccall` → `luaV_execute`)
- PUC frame is ~100 B; LUAI_MAXCCALLS=200 limits recursion, fits easily in 8 MB stack
- Our dispatcher at 139 KB / Lua level supports only **~60 levels** in Debug before stack overflow
- Even ReleaseFast (20 KB / level) only supports **~400 levels** — far below the `lua_max_call_frames = 6000` limit

### Why the frame is so big

Both Zig Debug and GCC -O0 perform basic scope-based stack slot reuse. For the same function (100 branches × 8 locals each), Zig Debug = 336 B, GCC -O0 = 96 B — only **3.5×** difference, not 50×.

The 139 KB frame is dominated by the **11 complex opcode handlers**:

| Handler | Lines | Cause of frame bloat |
|---|---|---|
| OP_CALL | 381 | 9-variant `BytecodePendingCompletion`, scratch buffers, hook state |
| OP_TAILCALL | 338 | Frame-reuse logic, varargs copy, tbc slot scans |
| OP_CONCAT | 263 | Multi-step accumulation loop with metamethod cascades |
| OP_FORPREP | 170 | Numeric/generic for-loop state setup |
| OP_TFORCALL | 162 | Generic for-loop iterator call |
| OP_CLOSURE | 93 | Proto upvalue binding loop |
| OP_VARARG | 92 | Vararg copy with frame growth |
| OP_RETURN1 | 49 | Hook continuation + closer scan |
| OP_RETURN0 | 35 | Same |
| OP_SETLIST | 22 | Bulk array writes |
| OP_RETURN | 21 | Same |

The other 68 handlers are 1–2 lines each and contribute negligibly to the frame.

## Goal

Shrink `runBytecodeDispatch` frame from **139 KB → ~200 B** by extracting the 11 complex handlers as separate methods. This unlocks host recursion with the default 8 MB stack (≈2000 Lua levels in Debug, ≈4000 in ReleaseFast).

**Non-goals:**
- Redesign `PendingCallSlot` semantics — unchanged in this refactor
- Enable host recursion directly — that's the next plan
- Touch the 68 small handlers
- Change opcode behavior

## Architecture

### State ownership

Today: 15 local variables in `runBytecodeDispatch` hold all dispatch state, sync'd to `exec_frames.items[frame_index]` via a `defer` block at frame_loop exit.

After refactor: a single `BytecodeDispatchCtx` struct holds the same state. The dispatcher's frame contains only `ctx` plus a few transient variables. The 11 extracted handlers receive `*BytecodeDispatchCtx` and mutate it directly. The `defer` block calls `ctx.syncTo(exec_frames)`.

### Data structures

`BytecodeDispatchCtx` is a plain data struct. The (re)load and sync operations
are methods on `Vm` (so they can access `bc_stack` / `bc_boxed`), taking the
ctx by pointer.

```zig
/// Plain data carrier for dispatch state. Lives in the dispatcher's C frame.
/// Methods on Vm (loadDispatchCtx / syncDispatchCtx) move fields between
/// this struct and exec_frames.items[frame_index].
const BytecodeDispatchCtx = struct {
    // Immutable within a frame iteration
    exec_frames: *std.ArrayListUnmanaged(CallFrame),
    frame_index: usize,
    boundary_depth: usize,
    yielded_in_place: *bool,

    // Frame state (mirrors CallFrame fields)
    cur_proto: *const bc.Proto,
    cur_upvalues: []const *Cell,
    base: usize,
    frame_cap: usize,
    pc: usize,
    resume_pc: usize,
    reg_top: u32,
    nvarstack: u8,
    varargs: []Value,
    tbc_mark: usize,

    // Mutable register window — re-derivable after bc_stack realloc
    regs: []Value,
    boxed: []?*Cell,

    // Debug/hook state
    frame_current_line: i64,
    frame_last_hook_line: i64,
    frame_is_tailcall: bool,
    resumed_direct_yield: bool,
    hooks_active: bool,
};
```

Operations on `Vm`:

```zig
/// Reload all ctx fields from exec_frames.items[ctx.frame_index].
/// Called at the top of each frame_loop iteration.
fn loadDispatchCtx(self: *Vm, ctx: *BytecodeDispatchCtx) void {
    const fr = &ctx.exec_frames.items[ctx.frame_index];
    ctx.cur_proto = fr.proto.?;
    ctx.cur_upvalues = fr.upvalues;
    ctx.base = fr.base;
    ctx.frame_cap = fr.frame_cap;
    ctx.pc = fr.pc;
    ctx.resume_pc = fr.resume_pc;
    ctx.reg_top = fr.reg_top;
    ctx.nvarstack = fr.nvarstack;
    ctx.varargs = fr.varargs;
    ctx.tbc_mark = fr.tbc_mark;
    ctx.regs = self.bc_stack[fr.base .. fr.base + fr.frame_cap];
    ctx.boxed = self.bc_boxed[fr.base .. fr.base + fr.frame_cap];
    ctx.frame_current_line = fr.current_line;
    ctx.frame_last_hook_line = fr.last_hook_line;
    ctx.frame_is_tailcall = fr.is_tailcall;
    ctx.resumed_direct_yield = fr.resumed_direct_yield;
    // hooks_active is re-derived per inner-loop iteration
}

/// Persist all ctx fields back to exec_frames.items[ctx.frame_index].
/// Called from the defer block on frame_loop exit.
fn syncDispatchCtx(self: *Vm, ctx: *const BytecodeDispatchCtx) void {
    if (ctx.frame_index >= ctx.exec_frames.items.len) return;
    const saved = &ctx.exec_frames.items[ctx.frame_index];
    saved.proto = ctx.cur_proto;
    saved.upvalues = ctx.cur_upvalues;
    saved.frame_cap = ctx.frame_cap;
    saved.pc = ctx.pc;
    saved.resume_pc = ctx.resume_pc;
    saved.reg_top = ctx.reg_top;
    saved.nvarstack = ctx.nvarstack;
    saved.varargs = ctx.varargs;
    saved.current_line = ctx.frame_current_line;
    saved.last_hook_line = ctx.frame_last_hook_line;
    saved.is_tailcall = ctx.frame_is_tailcall;
    saved.resumed_direct_yield = ctx.resumed_direct_yield;
    saved.regs = self.bc_stack[ctx.base .. ctx.base + ctx.frame_cap];
    saved.boxed = self.bc_boxed[ctx.base .. ctx.base + ctx.frame_cap];
}

/// Re-derive ctx.regs / ctx.boxed after a callee may have realloc'd bc_stack.
/// Cheap (just slice arithmetic); call liberally.
fn refreshCtxSlices(self: *Vm, ctx: *BytecodeDispatchCtx) void {
    ctx.regs = self.bc_stack[ctx.base .. ctx.base + ctx.frame_cap];
    ctx.boxed = self.bc_boxed[ctx.base .. ctx.base + ctx.frame_cap];
}
```

```zig
const DispatchResult = union(enum) {
    /// Advance to the next instruction. Handler must have set ctx.pc.
    continue_dispatch,

    /// Re-enter frame_loop. The current frame may have been popped
    /// (e.g. OP_RETURN) or replaced (e.g. OP_TAILCALL).
    continue_frame_loop,

    /// Return from runBytecodeDispatch with the given values.
    return_results: []Value,

    /// Signal a runtime error. Caller will run error recovery.
    propagate_error,
};
```

### Handler signature

All 11 extracted handlers follow the same shape:

```zig
fn opCall(self: *Vm, ctx: *BytecodeDispatchCtx) DispatchError!DispatchResult {
    // ... current 381-line OP_CALL body, reading/writing ctx.* instead of locals ...
}
```

Handler responsibilities:
1. Read instruction fields from `ctx.cur_proto.code[ctx.pc]` (or accept `inst` as second param — TBD)
2. Mutate `ctx` fields directly (regs, pc, reg_top, frame_current_line, etc.)
3. Return `DispatchResult` indicating next action
4. **Must** set `ctx.pc` correctly before returning `continue_dispatch`
5. **Must not** assume `ctx.regs` / `ctx.boxed` are stable across function calls that may realloc `bc_stack` — re-derive via `ctx.regs = self.bc_stack[ctx.base .. ctx.base + ctx.frame_cap]` after any potential realloc

### Dispatcher shape

```zig
fn runBytecodeDispatch(
    self: *Vm,
    exec_frames: *std.ArrayListUnmanaged(CallFrame),
    boundary_depth: usize,
    yielded_in_place: *bool,
) DispatchError![]Value {
    var ctx: BytecodeDispatchCtx = .{
        .exec_frames = exec_frames,
        .frame_index = undefined,           // set inside frame_loop
        .boundary_depth = boundary_depth,
        .yielded_in_place = yielded_in_place,
        // remaining fields set by reloadFrom
    };

    frame_loop: while (exec_frames.items.len > boundary_depth) {
        ctx.frame_index = exec_frames.items.len - 1;
        try self.loadDispatchCtx(&ctx);

        // Sync back on every exit from this frame iteration (P15.37 invariant).
        defer self.syncDispatchCtx(&ctx);

        // ... existing pre-dispatch logic (resume yield, pending completion, etc.) ...

        while (true) {
            const inst = ctx.cur_proto.code[ctx.pc];
            const op: bc.Op = @enumFromInt(inst.op);
            self.bc_dispatch_pc = ctx.pc;
            // ... existing fast-path hook check ...

            const result: DispatchResult = switch (op) {
                // 68 small handlers — inline, set ctx.pc, return continue_dispatch
                .move => blk: {
                    ctx.regs[inst.a] = ctx.regs[inst.b];
                    ctx.pc += 1;
                    break :blk .continue_dispatch;
                },
                .loadtrue => blk: {
                    ctx.regs[inst.a] = .{ .Bool = true };
                    ctx.pc += 1;
                    break :blk .continue_dispatch;
                },
                // ... etc ...

                // 11 big handlers — method calls
                .call => try self.opCall(&ctx),
                .tailcall => try self.opTailcall(&ctx),
                .concat => try self.opConcat(&ctx),
                .forprep => try self.opForprep(&ctx),
                .tforcall => try self.opTforcall(&ctx),
                .closure => try self.opClosure(&ctx),
                .vararg => try self.opVararg(&ctx),
                .return0 => try self.opReturn0(&ctx),
                .return1 => try self.opReturn1(&ctx),
                .setlist => try self.opSetlist(&ctx),
                .return_ => try self.opReturn(&ctx),
            };

            switch (result) {
                .continue_dispatch => continue,
                .continue_frame_loop => continue :frame_loop,
                .return_results => |r| return r,
                .propagate_error => return error.RuntimeError,
            }
        }
    }
    return &[_]Value{};
}
```

## Instruction parameter

Each handler reads `inst` from `ctx.cur_proto.code[ctx.pc]` directly. This avoids a second parameter and matches the existing pattern where `a, b, c` are unpacked at the top of the inner loop.

Alternative considered: pass `inst` as a second parameter (`fn opCall(self, ctx, inst: bc.Inst)`). This is cleaner but adds a parameter to every handler. Decision: **read from ctx.pc** — matches existing inline pattern.

## Migration order

Each step is independently verifiable (smoke 45/45 + matrix 28/31). Order is by complexity (easiest first) to build confidence:

1. **Add scaffolding** — `BytecodeDispatchCtx` struct, `DispatchResult` enum, `reloadDispatchCtx`/`syncDispatchCtx` methods. Additive only, no behavior change.
2. **Convert dispatcher to use ctx** — replace 15 locals with ctx fields. Inner loop reads/writes `ctx.*`. **No handlers extracted yet.** Verify frame size drops slightly (basic liveness improvement from struct vs scattered locals).
3. **Extract OP_RETURN (21 lines)** — smallest big handler. Validates the extraction pattern.
4. **OP_SETLIST (22)** — same pattern.
5. **OP_RETURN0 (35)** — adds hook logic.
6. **OP_RETURN1 (49)** — adds single-result path.
7. **OP_VARARG (92)** — adds frame growth.
8. **OP_CLOSURE (93)** — adds Proto upvalue binding.
9. **OP_TFORCALL (162)** — adds iterator call pattern.
10. **OP_FORPREP (170)** — adds for-loop state setup.
11. **OP_CONCAT (263)** — adds multi-step metamethod cascade.
12. **OP_TAILCALL (338)** — adds frame-reuse logic.
13. **OP_CALL (381)** — biggest, most complex. Validates the whole refactor.

After step 13, measure frame size. Expected: `runBytecodeDispatch` < 1 KB (Debug).

## Verification

After **each step**:
- `zig build -Doptimize=Debug` clean
- `tests/smoke/*.lua` — 45/45 pass
- `tools/testes_matrix.py` (ReleaseFast) — 28/31 (no regressions vs baseline)

After **step 13** additionally:
- gdb measurement of `runBytecodeDispatch` RSP delta < 1 KB
- Re-run the simplified Task 2 from host recursion plan (delete bytecode-closure branch in OP_CALL, let it use `runClosure`)
- smoke 24, 27, 32 pass (the three that broke earlier)
- Matrix still 28/31

## Risk register

1. **Defer block semantics**
   - The current defer at line 7372-7394 only runs on `frame_loop` exit, NOT on inner-loop `continue`. After refactor, `syncDispatchCtx` runs in the same places — semantics preserved.
   - **Mitigation:** keep the defer inside `frame_loop`, not at function level.

2. **Realloc invalidation of `ctx.regs`**
   - Any function call that may grow `bc_stack` invalidates `ctx.regs`. Handlers must re-derive after such calls.
   - **Mitigation:** same pattern as today's `bcGrowFrame(base, needed, &frame_cap, &regs, &boxed)`. New helper: `self.refreshCtxSlices(&ctx)` after potential-realloc calls.

3. **`continue :frame_loop` from extracted handler**
   - Today, handlers can `continue :frame_loop` to break out of the inner loop. After extraction, they return `.continue_frame_loop` instead.
   - **Mitigation:** mechanical replacement, no semantic change.

4. **`return` from extracted handler**
   - Today, handlers can `return values` from `runBytecodeDispatch` directly. After extraction, they return `.return_results = values`.
   - **Mitigation:** mechanical replacement.

5. **Stack overflow detection during testing**
   - In Debug, the dispatcher frame is still 139 KB until step 13. Tests 24, 27, 32 will fail until then.
   - **Mitigation:** don't merge the host-recursion change until step 13. This refactor is purely about frame size.

6. **Performance**
   - Method calls add a tiny overhead per opcode. PUC has similar overhead (function calls for `luaV_concat`, etc.).
   - **Mitigation:** measure `tools/perf_compare.py` after step 13. Expected within ±3%.

## Test plan

| Test | What it exercises |
|---|---|
| smoke 02 — basic calls | OP_CALL fast path |
| smoke 03 — arithmetic | Inline arithmetic ops |
| smoke 09 — closures | OP_CLOSURE |
| smoke 13 — concat | OP_CONCAT |
| smoke 14 — varargs | OP_VARARG |
| smoke 19 — generic for | OP_TFORCALL, OP_FORPREP |
| smoke 21 — tail calls | OP_TAILCALL |
| smoke 24 — xpcall | Error paths |
| smoke 27 — iterative calls | OP_CALL recursion |
| smoke 32 — for-loop locvars | Debug info during dispatch |
| testes matrix (28/31) | Full suite parity |

## Success criteria

1. `runBytecodeDispatch` C stack frame < 1 KB (Debug, measured via gdb)
2. Smoke 45/45 pass
3. Matrix 28/31 (no regressions)
4. Host recursion Task 2 (delete bytecode-closure branch in OP_CALL) works with default 8 MB stack
5. Perf within ±3% of baseline

## Out of scope

- Host recursion implementation (separate plan, unblocked by this)
- `PendingCallSlot` elimination (depends on host recursion)
- Phase C: inline array (depends on PendingCallSlot elimination)
- Refactoring the 68 small handlers
