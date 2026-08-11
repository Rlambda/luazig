# Design: PUC-faithful CallFrame / CALL-RETURN

> **Status:** Revised 2026-08-11 per 2nd verifier pass (PUC CallInfo size 64B,
> callstatus-encoded nresults, locally-cached pc, Lua|C union w/o coroutine
> variant, gcTempRoots safety rule, main direction preserved). Ready for
> implementation plan.

## Problem

`lua_calls` benchmark: **3.75x** PUC Lua. Bytecode sequence nearly identical to PUC;
overhead is in runtime CALL/RETURN machinery.

Root causes (measured):
- CallFrame ~400B, 38 field stores per CALL (PUC `CallInfo`: 64 B on x86-64;
  number of stores per CALL not yet measured — do not claim otherwise)
- `pending_call` mechanism: 49B set+clear+switch per CALL/RETURN (no PUC equivalent)
- `loadDispatchCtx`/`syncDispatchCtx` round-trip: ~30 field copies per CALL
  (PUC: local reads via `goto startfunc`, no per-field copy)
- `gcTempRoots` on every RETURN (PUC: none on the common RETURN path)
- `Proto.live_reg_top` runtime mutation: 2 conditional writes per RETURN (PUC: none)

PUC `CallInfo` size reference (x86-64, `lstate.h:187`):
`func` (4) + `top` (4) + `previous`/`next` (8+8) + `u` (24, union of `l`/`c`)
+ `u2` (4, union of int) + `callstatus` (4) + alignment → **64 B**.

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
proto, base, func_slot, frame_cap, reg_top,
tbc_mark, has_open_upvalues, activation_id,
callstatus (packed: low 8 bits = nresults+1, plus PUC-style flag bits)
```

### Result-count representation (PUC-faithful)

PUC encodes the expected result count in the low 8 bits of `callstatus`
(`CIST_NRESULTS = 0xff`, `lstate.h:223`): `status = nresults + 1` is stored on
precall (`ldo.c:716`), `get_nresults(cs) = (cs & 0xff) - 1` decodes it
(`lstate.h:254`). `MULTRET` (`LUA_MULTRET = -1`) encodes as `0`. `MAXRESULTS = 250`
fits (`251 ≤ 255`).

luazig analog: **no separate `wanted_results` field** (an `i8` is too small for
`MAXRESULTS = 250` anyway). Store `nresults + 1` in the low 8 bits of the
`callstatus: u32` field, exactly as PUC. Decoding helper:
```
nresults = @as(i32, @intCast(callstatus & 0xff)) - 1  // -1 → MULTRET
```

### Mutually-exclusive state → union (PUC Lua-frame vs C/native-frame)

PUC `CallInfo.u` is a union of exactly two variants (`lstate.h:191-202`):
- `struct l { savedpc; trap; nextraargs; }` — Lua-frame state
- `struct c { k; old_errfunc; ctx; }` — C/native-frame state (continuation,
  protected-call saved errfunc, KContext)

There is **no third "coroutine" variant** in PUC. Coroutine yield/resume is
**execution state of a thread/frame**, not a function type:
- `u2.nyield` (int, `lstate.h:206`) counts yielded values — lives in the
  separate `u2` union, reused only while a function is mid-yield.
- `callstatus` flags (`CIST_HOOKYIELD`, `CIST_YPCALL`, `CIST_FIN`,
  `lstate.h:245-251`) mark yield/pcall/finalizer execution state.
- `lua_State` (not `CallInfo`) holds coroutine thread state (`status`,
  `twups` list, etc.).

luazig analog: the main `CallFrame` union has exactly two variants mirroring
PUC — **Lua-frame** vs **C/native-frame**. Coroutine-related fields are
**not** a third union variant; they are unioned only where their lifetime is
genuinely mutually exclusive with other `u2`-style state (e.g. `nyield`
reuses the same slot as `funcidx`/`nres`, as in PUC `u2`). Coroutine
thread-level state lives in `Thread` (analogous to `lua_State`), not in the
per-frame union.

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
- `callstatus` low 8 bits (`CIST_NRESULTS`) encode expected result count
  (`nresults + 1`, MULTRET = 0), `lstate.h:223`, `ldo.c:716`

luazig analog: result count encoded in `callstatus` low 8 bits of the callee
frame (PUC `CIST_NRESULTS`-style). No separate `wanted_results` field.

Ordinary RETURN:
```
dst = callee.func_slot
wanted = decode_nresults(callee.callstatus)  // (cs & 0xff) - 1
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

## 5. PUC-like dispatch — direct frame access, locally cached pc

Keep **iterative `frame_loop`**. Host recursion forbidden.

Current frame accessible to dispatch directly, analogous to PUC `ci`:
- Dispatch holds a pointer to the current CallFrame (like PUC `L->ci`)
- Hot fields read directly via pointer — no copy to `BytecodeDispatchCtx`

**pc caching model (PUC `luaV_execute`, `lvm.c:1198`):**
PUC does **not** read/write `ci->u.l.savedpc` on every instruction. `pc` is a
**local variable** of `luaV_execute`, initialized from `ci->u.l.savedpc` at
`startfunc:`/`returning:` (`lvm.c:1212`). The interpreter loop advances the
local `pc`. `ci->u.l.savedpc` is written back only via the `savepc(ci)` macro
(`lvm.c:1144`) on **safepoints** (calls, returns, hooks, errors, yields,
GC-triggering ops, line hooks).

luazig analog: the interpreter loop holds `pc` (and other hot state like `base`,
`k`) as **locals**, not as fields read/written through the frame pointer on every
instruction. The frame's saved pc is synced only on observation/safepoint
boundaries:
- call / frame switch
- return
- GC
- hook
- error / unwind
- yield / resume

Eliminate `loadDispatchCtx` / `syncDispatchCtx` round-trip (~30 field copies → 0).
The hot loop touches the frame pointer only for state that is genuinely
per-instruction (e.g. writing a register), not for `pc`.

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

The criterion for skipping `gcTempRoots` on RETURN is **not** a simple
"GC debt check". A debt check alone is unsafe: GC may be triggered by any
allocation or barrier before the next safepoint, and debt can be non-zero
without an immediate collection, or zero with a pending atomic phase.

Correct rule (PUC-faithful): **common RETURN may skip temp roots only if,
provably, nothing GC-triggering executes between the RETURN and the next
safepoint** (next frame switch / hook / error / yield). Concretely:
- If the RETURN target is an ordinary Lua frame and the move-results path
  performs no allocation and no table/object barrier, temp roots are not
  needed on that path.
- **Before any operation that may trigger GC** (table insert, string intern,
  closure creation, upvalue close, metamethod call, stack realloc), temp
  roots must be installed for any live objects not yet rooted elsewhere.

This matches PUC, which has no per-RETURN temp-root machinery on the common
path (`moveresults`/`luaD_poscall`, `ldo.c:561`), but does protect roots
around specific GC-triggering operations elsewhere (e.g. `luaC_barrier`,
`luaC_condGC` in `lgc.h`).

---

## Execution Order

```
1. Compact PUC-like CallFrame (union/flags/thread-state), semantics unchanged → benchmark
2. Remove duplicated state (callee, regs, boxed, upvalues) → benchmark each
3. Ordinary OP_CALL: nresults encoded in callee callstatus → benchmark
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
