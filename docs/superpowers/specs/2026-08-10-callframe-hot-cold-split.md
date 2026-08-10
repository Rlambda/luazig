# Design: PUC-faithful CallFrame / CALL-RETURN

> **Status:** Approved 2026-08-10 (revised per verifier feedback). Ready for implementation plan.

## Problem

`lua_calls` benchmark: **3.75x** PUC Lua. Bytecode sequence nearly identical to PUC;
overhead is in runtime CALL/RETURN machinery.

Root causes (measured):
- CallFrame ~400B, 38 field stores per CALL (PUC `CallInfo`: ~56B, 4 stores)
- `pending_call` mechanism: 49B set+clear+switch per CALL/RETURN (no PUC equivalent)
- `loadDispatchCtx`/`syncDispatchCtx` round-trip: ~30 field copies per CALL
  (PUC: 3 local reads via `goto startfunc`)
- `gcTempRoots` on every RETURN (PUC: none)
- `Proto.live_reg_top` runtime mutation: 2 conditional writes per RETURN (PUC: none)

## Design Principle

**PUC-first.** Model the CallFrame / Thread / dispatch after PUC Lua 5.5
`CallInfo` / `lua_State` / `luaV_execute`, not a custom hot/cold sidecar.

Reference: vendored PUC Lua 5.5 (`lua-5.5.0/src/`):
- `CallInfo` / `lua_State` (`lstate.h`)
- `luaD_precall` (`ldo.c`)
- `luaD_poscall` / `moveresults` (`ldo.c`)
- `OP_CALL`, `OP_TAILCALL`, `OP_RETURN*` (`lvm.c`)
- C/Lua continuations, hooks, TBC, protected calls, coroutine state

When in conflict between a custom abstraction and a working simple PUC solution,
**prefer PUC architecture** unless there is a concrete reason to deviate.

Sidecar/cold-pool is **not** the primary design. It is допустим only if, after a
PUC-like redesign, real per-frame state remains that cannot be reasonably
represented via union/flags/thread state.

---

## 1. Compact PUC-like CallFrame

Redesign `CallFrame` following PUC `CallInfo` principles:

### Only true per-call common state in the frame

PUC `CallInfo` stores: `func`, `top`, `previous`/`next`, `u` (union: Lua `savedpc`+`trap`+`nextraargs` / C `k`+`old_errfunc`+`ctx`), `u2` (union: `funcidx`/`nyield`/`nres`), `callstatus`.

Analogous luazig fields (to be validated by `@sizeOf` after minimization):
```
proto, pc, base, func_slot, frame_cap, reg_top,
tbc_mark, has_open_upvalues, activation_id,
wanted_results, callstatus (packed flags)
```

### Mutually-exclusive state → union

PUC uses `union { struct { savedpc; trap; nextraargs; } l; struct { k; old_errfunc; ctx; } c; } u`.

luazig analog: Lua-frame vs C-frame vs coroutine-frame state in a `union`.
This includes the continuation pointer for C calls (`lua_KFunction`) and
coroutine yield/resume state.

### Small state/flags → packed `callstatus`

PUC packs: `CIST_LUA`, `CIST_HOOKED`, `CIST_FRESH`, `CIST_YPCALL`, `CIST_TBC`,
`CIST_HOOKYIELD`, `CIST_FIN`, `CIST_TRAN`, `CIST_CLSRET`, `CIST_CPCALL`.

luazig analog: replace individual bool fields (`is_tailcall`, `is_debug_hook`,
`resumed_direct_yield`, `hide_from_debug`, etc.) with a packed `callstatus: u32`.

### Thread-global state → Thread (like PUC `lua_State`)

PUC stores in `lua_State`: `hook`, `hookmask`, `basehookcount`, `hookcount`,
`allowhook`, `errfunc`, `nCcalls`, `nny`, `ci` (current CallInfo), `top`,
`stack` (shared stack array).

luazig analog: move hook state, debug-hook transfer state, error function,
call depth counters, and current-frame pointer from per-CallFrame fields to
`Thread`. Only per-activation state stays in CallFrame.

### Debug name/what → derive on demand

`debug_namewhat`, `debug_name` are derivable from `proto` + `func_slot` +
`callstatus` when `debug.getinfo` is called. Do not store them per-frame.

---

## 2. Remove duplicated state

Principle: **one runtime fact → one authoritative representation.**

### `callee`

If the closure is already at `bc_stack[func_slot]`, do not store a second copy
in the frame. Read from `bc_stack[func_slot]` when needed (like PUC `ci->func`
points into the shared stack).

### `regs` / `boxed`

If fully determined by `base` + `frame_cap`, derive on frame activation:
```
regs = bc_stack[base .. base + frame_cap]
boxed = bc_boxed[base .. base + frame_cap]
```
Do not store stale slices in every frame. This eliminates duplicated state and
the need to update slices after bytecode stack realloc.

### `upvalues`

If the closure is at `bc_stack[func_slot]`, upvalues are accessible via
`closure.upvalues`. Do not store a second reference in the frame unless
benchmarking shows a measurable cost.

### `varargs`

Bytecode frames use `nextraargs` + bc_stack (overlapping model). `varargs`
slice is for IR frames only (which no longer exist). Remove from bytecode
frame path.

Each removal benchmarked separately. Only remove if no perf regression.

---

## 3. Ordinary Lua CALL — result contract in callee frame

PUC stores the result contract in the **callee** `CallInfo`:
- `ci->func` determines destination (results go to `func` slot)
- `callstatus` / `nres` determines expected result count

luazig analog: add `wanted_results: i8` to the callee frame (PUC `callstatus`-style).

Ordinary RETURN:
```
dst = callee.func_slot
wanted = callee.wanted_results
pop callee
move results to dst
resume parent
```

**No `pending_call.results` for ordinary Lua CALL.**
**No `call_pc` + reread OP_CALL on return** (PUC does not do this).

---

## 4. Pending continuation only for special calls

Generic continuation state (`PendingCallSlot` / `BytecodePendingCall`) is needed
**only** where a real continuation exists:
- metamethod invocation
- protected/native calls (PUC `lua_KFunction` + `ctx`)
- TBC / close
- hooks
- coroutine yield/resume
- other VM-internal special calls

Represent this maximally analogous to PUC:
- C-call continuation: `union` variant with `k: ?*const fn`, `ctx: usize`
  (PUC `ci->u.c.k`, `ci->u.c.ctx`)
- Protected call: `callstatus` flag `CIST_YPCALL` + saved `old_errfunc`
  (PUC `ci->u.c.old_errfunc`)
- TBC: `callstatus` flag `CIST_TBC` + `tbc_mark` (PUC `ci->u2.nres` for close)

Ordinary Lua CALL does **not** allocate, set, or clear any pending continuation.

---

## 5. PUC-like dispatch — direct frame access

Keep **iterative `frame_loop`**. Host recursion forbidden.

Current frame accessible to dispatch directly, analogous to PUC `ci`:
- Dispatch holds a pointer to the current CallFrame (like PUC `L->ci`)
- Hot fields read directly via pointer — no copy to `BytecodeDispatchCtx`
- `pc` is read/written in the frame directly (like PUC `ci->u.l.savedpc`)

Eliminate `loadDispatchCtx` / `syncDispatchCtx` round-trip (~30 field copies → 0).

State synchronized only on observation boundaries:
- call / frame switch
- return
- GC
- hook
- error / unwind
- yield / resume

---

## 6. Remove runtime mutation of `Proto.live_reg_top`

`Proto` is compile-time bytecode metadata. Runtime must not mutate it on every
CALL/RETURN.

Current: `@constCast(proto).live_reg_top[pc] = ...` on every RETURN.

Replace: dynamic register liveness lives in `frame.reg_top`. GC uses:
```
effective_live_top = max(proto.static_liveness[pc], frame.reg_top)
```
`static_liveness` is compile-time metadata, not mutated at runtime.

Separate patch after CALL/RETURN simplification, with GC regression tests.

---

## 7. Conditional `gcTempRoots`

Only set up GC temp roots when GC might run (debt check), not on every RETURN.
Last quick win.

---

## Execution Order

```
1. Compact PUC-like CallFrame (union/flags/thread-state), semantics unchanged → benchmark
2. Remove duplicated state (callee, regs, boxed, upvalues) → benchmark each
3. Ordinary OP_CALL: wanted_results in callee frame → benchmark
4. Remove PendingCallSlot from ordinary CALL path → benchmark
5. Dispatch: direct frame pointer, eliminate ctx round-trip → benchmark
6. Remove Proto.live_reg_top runtime mutation → benchmark
7. Conditional gcTempRoots → benchmark
```

Each step: separate commit + perf A/B.
Invariant: `frame_loop` preserved, no host recursion.

## Goals

- `CallFrame` is a Zig analog of PUC `CallInfo`, not a universal VM-state container
- `Thread` holds state analogous to PUC `lua_State`
- Common Lua CALL/RETURN maximally close to PUC
- Ordinary `OP_CALL` does not use generic pending continuation
- Result contract stored in callee frame
- Mutually-exclusive state represented via union/flags
- Duplicated/derived state removed
- Hot frame substantially smaller than current ~392 B
- Ordinary CALL requires substantially less initialization
- Iterative dispatch preserved
- Architecture remains simple and idiomatic for Zig

## Invariants

- Iterative `frame_loop` preserved — no host recursion
- PUC-faithful: result contract in callee frame (like PUC `callstatus` / `ci->func`)
- Cold paths still work: debug hooks, coroutines, protected calls, TBC
- No test regressions: matrix 30/31, smoke 49/49, leakbench 25/25, zig build test 146/146
- No match-by-name / line-range / special-case hacks (AGENTS.md)
