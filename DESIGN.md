# luazig — Design Decisions & Architectural Findings

This document records important architectural findings and design decisions
to prevent revisiting dead-end approaches.

---

## 1. Dispatch Model: Iterative `frame_loop` — NOT Host Recursion

**Finding (2026-08-09):** PUC Lua uses iterative dispatch for Lua-to-Lua calls,
NOT C-stack recursion. Host recursion is an anti-pattern for this codebase.

### PUC Lua's dispatch model

In PUC's `luaV_execute` (lvm.c), OP_CALL for a Lua function does:

```c
/* luaD_precall returns non-NULL for Lua functions */
ci = luaD_precall(L, ra, nresults);
if (ci != NULL) {
    /* Lua call: run function in this same C frame */
    goto startfunc;  // ← iterative jump, NOT recursive luaV_execute call
}
```

`goto startfunc` re-enters the interpreter loop for the child function
within the **same C stack frame**. No recursion, no C-stack growth.

`LUAI_MAXCCALLS = 200` limits only **C function** nesting (when
`luaD_precall` returns NULL), not Lua recursion depth. PUC handles
5000+ Lua recursion depth because Lua calls don't grow the C stack.

### luazig's dispatch model

luazig's `frame_loop` in `runBytecodeDispatch` is the Zig equivalent of
PUC's `goto startfunc`:

```zig
frame_loop: while (exec_frames.len() > boundary_depth) {
    // Load top frame into ctx
    // Execute opcodes
    //   .call => push child frame + continue :frame_loop (= goto startfunc)
    //   .return_ => pop frame + continue :frame_loop (= return to caller)
}
```

This is **correct and PUC-faithful**. The `PendingCallSlot` continuation
machinery is the Zig equivalent of PUC's `CallInfo` + `savedpc` encoding
the post-call operation.

### Why host recursion was attempted and rejected

Design doc `docs/superpowers/specs/2026-07-21-host-recursion-design.md`
proposed replacing iterative dispatch with recursive `runBytecodeInternal`
calls, claiming PUC uses "host recursion for ALL calls." This was
**factually wrong** — PUC uses `goto startfunc` for Lua calls.

When host recursion was implemented (2026-08-09):

1. **Stack overflow at depth ~2000:** `runBytecodeDispatch` has a ~4-8KB
   Zig stack frame (BytecodeDispatchCtx ~200B + dispatch loop locals
   ~4-8KB due to the 80-case opcode switch). At 2000 recursive levels,
   the 8MB default stack is exhausted.

2. **PUC limit mismatch:** Setting `lua_max_call_frames = 200` (matching
   `LUAI_MAXCCALLS`) would make Lua recursion fail at 200 — but PUC
   handles 5000+ because Lua calls use `goto`, not C recursion.

3. **Anti-pattern:** Recursion for Lua-to-Lua calls is fundamentally
   wrong — it limits Lua recursion depth to the C stack capacity,
   which is NOT how PUC Lua works.

### Conclusion

- **Iterative `frame_loop` is the correct model.** Do not replace it.
- `PendingCallSlot` + continuation machinery stays — it's the PUC equivalent.
- `LUAI_MAXCCALLS` equivalent limits C function nesting only, not Lua calls.
- Coroutine optimization must work **within** the iterative model.

---

## 2. Short String GC: HashMap Tombstone Rehash

**Finding (2026-08-09):** Zig's `HashMapUnmanaged` uses tombstones for
deletions. When GC sweeps dead strings, `string_intern.table.remove()` creates
tombstones. Over many GC cycles, tombstones accumulate → probe chains degrade
to O(N).

**Fix:** Call `string_intern.table.rehash()` at the end of `gcSweepOne`.
This clears all tombstones, restoring O(1) lookup.

**Impact:** string_concat 100x → 1.56x, string_loop 153x → 2.04x,
geomean 4.68x → 2.73x.

---

## 3. SIGINT Check: Periodic Instead of Per-Instruction

**Finding (2026-08-09):** The dispatch loop checked `signal_int_pending.load(.acquire)`
on every instruction — an atomic acquire-load fence. PUC doesn't do per-instruction
signal checks.

**Fix:** Periodic check every `SIGINT_CHECK_INTERVAL = 1024` instructions.
The countdown decrement (~1 cycle) replaces the atomic load (~3-5 cycles).
SIGINT latency ≈ 1µs — imperceptible for Ctrl-C response.

---

## 4. OP_CALL Inline Fast Path

**Finding (2026-08-09):** The `opCall` function (200+ lines) was called for
every OP_CALL, then a 5-way `DispatchResult` enum was switched. For the common
case (Lua Closure, no hooks, no coroutine resume), this is pure overhead.

**Fix:** Inline the fast path directly in the `.call` case of the dispatch
switch. Avoids function call overhead and enum switch. Slow path (Builtin,
__call metamethod, hooks, coroutine) falls through to full `opCall`.

**Impact:** lua_calls 4.11x → 3.72x (-7.5% vs baseline).

---

## 5. Coroutine Yield Allocations

**Finding (2026-08-09):** Each `coroutine.yield` did 5-7 heap allocations
(PUC does zero via `lua_xmove`). After Phase 0 optimization:

| Allocation | Before | After Phase 0 |
|---|---|---|
| `th.yielded` (yield values copy) | alloc per yield | **kept** (1 alloc) |
| `last_yield_payload` (second copy) | alloc per yield | **merged into yielded** |
| `trace_frame_names` (frame name array) | alloc per yield | **inline [64] buffer** |
| `snapshotThreadLocalsFromFrame` | no-op function call | **deleted** |
| `seedThreadFrameLocalOverridesFromSnapshot` | no-op function call | **deleted** |
| `seedCloseLocalOverridesFromFrames` | no-op function call | **deleted** |
| `frame_capture_cells` (dead ArrayList) | clearAndFree per yield | **deleted** |

**Remaining allocations (3-4 per cycle):**
- `th.yielded` — needed (yield values survive across resume)
- `resume_inbox` — copy of resume args (could borrow)
- `suspended_builtin_args` — copy of builtin args (could borrow)
- Trampoline: yield step dupe + continuation struct

---

## 6. Dead IR Codegen Removal

**Finding (2026-08-09):** The project had TWO codegens:
- `codegen.zig` (2,399 lines) + `ir.zig` (621 lines) — old IR-based, only used by `luazigc`
- `codegen_bc.zig` (7,770 lines) — direct AST→bytecode, used by everything

`luazigc` was a bootstrap debug tool (--tokens, --ast, --ir, -p) that was
no longer needed. `bc_vm.zig` (318 lines) and `lower_ir.zig` (259 lines)
were orphaned and broken (referenced non-existent `bytecode.Chunk`).

**Action:** Deleted `codegen.zig`, `ir.zig`, `luazigc.zig`, `compile_compare.py`,
`compile_list.txt`, `bc_vm.zig`, `lower_ir.zig` — 4,032 lines removed.

---

## 7. TrackingAllocator Non-Deterministic Crashes

**Finding (2026-08-09):** The `TrackingAllocator` wrapping `smp_allocator`
causes non-deterministic SIGABRT crashes in 4 matrix tests (api, locals, math,
strings) when enabled in the main binary. The crashes are reproducible only
intermittently (3 runs → 26/31, then 30/31 after rebuild).

**Root cause:** Likely a memory safety issue in the allocator vtable
indirection under heavy GC load. The tracker is fine for `leak_bench.py`
side-by-side comparison but must NOT be enabled in the main binary.

**Decision:** Tracker is disabled in the main binary
(`runtime_alloc = std.heap.smp_allocator`). `collectgarbage("count")` reads
exact bytes via `tracker_total` field when available.

---

## Open Architectural Questions

### Coroutine trampoline (`driveBytecodeCoroutineTrampoline`)

The 190-line trampoline exists because coroutine.resume can be called from
inside a coroutine. In PUC, nested resumes use the C stack (each `lua_resume`
call is a new C frame). In luazig's iterative dispatch, the trampoline
simulates this with `error.ThreadSwitch` + iterative loop.

The trampoline cannot be eliminated without either:
1. Host recursion (rejected — see §1), or
2. A different coroutine execution model (e.g., separate dispatch loops
   per thread with explicit state machine transitions)

Current approach: keep trampoline, optimize its overhead.
