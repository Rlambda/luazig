# Dispatch loop hot-path reduction

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce per-instruction overhead in the bytecode VM dispatch loop. Geomean 2.95× → target ~2.7×.

**Architecture:** All changes are PUC-faithful. PUC Lua's `luaV_execute` uses a local `const Instruction *pc` that is written back to `ci->u.l.savedpc` only on call/return. We currently read/write `ctx.fr.pc` (heap-resident CallFrame field) on every instruction — 3 heap dereferences per instruction.

**Parity baseline:** 28/31 matrix, 45/45 smoke. Geomean 2.95×.

---

## Task 1: pc → local variable

PUC `luaV_execute` (lvm.c:793):
```c
const Instruction *pc;
pc = ci->u.l.savedpc;       // load into local at frame entry
for (;;) {
    Instruction i = *pc++;   // fetch + advance LOCAL
    ...
    ci->u.l.savedpc = pc;    // write back ONLY on call/return
}
```

Currently `ctx.fr.pc` is read at:
- `vm.zig:6146` — `while (ctx.fr.pc < code.len)` (loop condition)
- `vm.zig:6157` — `code[ctx.fr.pc]` (instruction fetch)
- `vm.zig:7926` — `ctx.fr.pc += 1` (increment)

And written by:
- LOADKX: `ctx.fr.pc += 1` (6407) + `code[ctx.fr.pc]` (6408)
- Comparisons: `ctx.fr.pc += 1` (7448, 7476, 7504, 7523, 7532, 7557, 7582, 7608, 7634, 7641, 7647)
- FORLOOP/TFORLOOP: `ctx.fr.pc = ...` (8418, 8478) — in extracted handlers
- JMP: sets pc directly
- Extracted handlers (opCall, opReturn, etc.): read `ctx.fr.pc` to re-decode `inst`

**Plan:**
1. At inner loop entry (after `loadDispatchCtx`), load `var pc: usize = ctx.fr.pc`
2. Replace all `ctx.fr.pc` reads inside the inner `while` with `pc`
3. Replace `ctx.fr.pc += 1` at line 7926 with `pc += 1`
4. Write back `ctx `ctx.fr.pc = pc` ONLY at:
   a. Before entering the hooks block (line 6172) — hooks read `fr.pc` via `exec_frames.getPtr()`
   b. Before `continue :frame_loop` (frame transition — new frame loads its own pc)
   c. Before calling any extracted handler (`opCall`, `opReturn0/1`, `opClosure`, etc.) that reads `ctx.fr.pc`
   d. Before `break` out of the inner loop
5. The `defer { syncDispatchCtx }` already handles frame-loop exit — but it doesn't sync pc (comment at 6055-6056 says "pc is already in fr"). We need to ensure `ctx.fr.pc = pc` before any point where `syncDispatchCtx` or `loadDispatchCtx` runs.

**Critical invariant:** `ctx.fr.pc` must be valid whenever code outside the inner loop reads it. The extracted handlers (`opCall`, `opReturn0`, etc.) re-decode `inst` from `ctx.fr.pc` — so we must write back before calling them.

**Approach:** Write back `ctx.fr.pc = pc` at these points:
- Before the hooks block (`if (ctx.hooks_active)`)
- Before each extracted handler call (the 5-arm switch dispatches at ~7660-7713)
- Before each `continue :frame_loop`
- At the end of the inner loop body (before the `pc += 1` — actually, just use `pc` for the increment and write back at the top of the next iteration or at exit points)

Actually, the simplest correct approach: write back `ctx.fr.pc = pc` at the **top** of each iteration, before any code that might read `ctx.fr.pc` through `exec_frames.getPtr()`. But this defeats the purpose — we'd still write every iteration.

**Better approach:** Keep `pc` as the sole source of truth within the inner loop. Write back `ctx.fr.pc = pc` only when:
1. Entering hooks block (hooks read `fr.pc` directly)
2. Calling an extracted handler (handlers read `ctx.fr.pc` to re-decode inst)
3. `continue :frame_loop` (new frame will load its own pc via `loadDispatchCtx`)
4. Exiting the inner loop (falling through to the `completeBytecodeExecFrame` fallback)

- [ ] Read the full inner loop (6146-7927) to map all exit points
- [ ] Introduce `var pc: usize = ctx.fr.pc` at line ~6146
- [ ] Replace `ctx.fr.pc` with `pc` in: loop condition (6146), instruction fetchfetch (6157), LOADKX (6407-6408), comparisons (7448-7647), increment (7926)
- [ ] Add `ctx.fr.pc = pc` write-back before: hooks block (6172), each extracted handler dispatch (~7660-7713), each `continue :frame_loop`
- [ ] Verify extracted handlers still work (they read `ctx.fr.pc` — must be synced)
- [ ] Build + smoke + matrix

## Task 2: Inline `bcConstToValue`

`bcConstToValue` (vm.zig:2904) is a 6-arm switch with no loops, used by LOADK, LOADKX, GETFIELD, SETFIELD, GETTABUP, SETTABUP. PUC uses macros (`KBx`, `RK`) — always inline.

- [ ] Change `fn bcConstToValue` to `inline fn bcConstToValue`
- [ ] Build + smoke test

## Task 3: MOVE fast path via `has_open_upvalues`

PUC OP_MOVE is `setobjs2s(L, ra, RB(i))` — a single struct copy, no upvalue check. We currently probe `ctx.boxed[b]` and `ctx.boxed[a]` on every MOVE.

When `has_open_upvalues == false` (the common case), skip both probes:
```zig
.move => {
    if (ctx.fr.has_open_upvalues) {
        // Slow path: check boxed cells
        ctx.regs[a] = if (b < ctx.boxed.len) if (ctx.boxed[b]) |cell|
            cell.value
        else
            ctx.regs[b] else ctx.regs[b];
        if (a < ctx.boxed.len) if (ctx.boxed[a]) |cell| {
            try self.gcStoreCellValue(cell, ctx.regs[a]);
        };
    } else {
        // Fast path: no open upvalues, direct copy
        ctx.regs[a] = ctx.regs[b];
    }
},
```

Note: `has_open_upvalues` is on `CallFrame`, accessed via `ctx.fr.has_open_upvalues`.

- [ ] Read the MOVE handler (6387-6400)
- [ ] Add `has_open_upvalues` fast/slow split
- [ ] Build + smoke + matrix

## Task 4: `@branchHint(.unlikely)` on cold paths

Add branch hints to all slow-path branches in the dispatch loop. PUC structurally puts fast path first, slow path in `else`. `@branchHint` is the Zig-native equivalent.

Target locations (non-exhaustive — add wherever there's a clear fast/slow split):
- GETI: `else` at 6518 (metamethod path)
- GETFIELD: `else` at 6534 (metamethod path)
- SETI: `else` at 6577 (metamethod path)
- SETFIELD: `else` at ~6595 (metamethod path)
- SETTABLE: `else` at 6557 (metamethod path)
- ADD/SUB/MUL/DIV etc: `else` at ~6636 (non-numeric slow path)
- GETUPVAL/SETUPVAL: no slow path (already optimal)
- MOVE: the `has_open_upvalues` true branch (Task 3)
- All `tryPushBytecode*Metamethod` branches
- Stack realloc check: `if (self.bc_stack.ptr != stack_ptr)` at 6151

- [ ] Add `@branchHint(.unlikely)` to each cold-path `else` branch
- [ ] Build + smoke test

## Task 5: Remove redundant `ctx.regs` refresh on fast paths

Audit all `ctx.regs = self.bc_stack[...]` refreshes inside the dispatch switch. Keep only those that follow a call which may realloc `bc_stack` (metamethod dispatch, builtin call, etc.). Remove any that follow functions which cannot realloc (e.g. `bcConstToValue`).

From initial analysis, the fast paths (GETI, GETFIELD, SETI, SETFIELD, GETTABUP, SETTABUP, ADD, SUB, etc.) do NOT have redundant refreshes — they're only on slow paths. Verify this.

- [ ] Grep for `ctx.regs = self.bc_stack` inside the switch (6386-7924)
- [ ] For each occurrence, verify it follows a potentially-realloc'ing call
- [ ] Remove any that are redundant
- [ ] Build + smoke test

## Task 6: Full regression + perf + README

- [ ] Build ReleaseFast
- [ ] Run all smoke tests
- [ ] Run matrix: `python3 tools/testes_matrix.py --timeout 120` — expect 28/31
- [ ] Run perf: `python3 tools/perf_compare.py --runs 7 --core 0`
- [ ] Compare geomean to baseline (2.95×)
- [ ] Update baseline if improved
- [ ] Commit all changes
- [ ] Update README with optimization details
