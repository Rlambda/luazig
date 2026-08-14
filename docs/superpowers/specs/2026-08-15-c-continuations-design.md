# PUC Lua 5.5 C Continuations — Design Spec

## Goal

Implement real PUC Lua 5.5 C continuation semantics: `lua_callk`, `lua_pcallk`,
`lua_yieldk` with `k`/`ctx` that survive yield/resume. Replace the current
stub implementations that ignore `k`/`ctx`.

## Constraints

- `CallFrame` stays compact (~100B; current 96B, growth ≤ ~8B for C-continuation state)
- Ordinary Lua CALL/RETURN uses PUC-like result contract in callee frame
- Ordinary Lua CALL does not use generic `PendingCallSlot`
- Iterative `frame_loop`, no host recursion
- `PendingCallSlot` remains a separate mechanism for luazig-internal VM continuations
  (hooks, close, metamethods, coroutine_resume) — NOT C continuations
- Current correctness baseline preserved: matrix 30/31, smoke 49/49, unit 146/146, leakbench 25/25
- PUC Lua 5.5 (vendored) is the architectural and semantic reference

## PUC Lua 5.5 Reference Architecture

### CallInfo.u (lstate.h:187-202)

```c
struct CallInfo {
  StkIdRel func;
  StkIdRel top;
  struct CallInfo *previous, *next;
  union {
    struct {  /* only for Lua functions */
      const Instruction *savedpc;
      volatile l_signalT trap;
      int nextraargs;
    } l;
    struct {  /* only for C functions */
      lua_KFunction k;       /* continuation in case of yields */
      ptrdiff_t old_errfunc;
      lua_KContext ctx;      /* context info in case of yields */
    } c;
  } u;
  union {  /* u2: mutually exclusive */
    int funcidx;  /* called-function index (pcallk) */
    int nyield;   /* number of values yielded (yieldk) */
    int nres;     /* number of values returned (TBC close) */
  } u2;
  l_uint32 callstatus;
};
```

### callstatus bits (lstate.h:222-251)

| Bits | Name | Meaning |
|------|------|---------|
| 0-7 | `CIST_NRESULTS` | nresults + 1 |
| 8-11 | `CIST_CCMT` | __call metamethod count |
| 12-14 | `CIST_RECST` | recover status (error during pcallk) |
| 15 | `CIST_C` | C function frame |
| 16 | `CIST_FRESH` | fresh luaV_execute frame |
| 17 | `CIST_CLSRET` | closing TBC variables on return |
| 18 | `CIST_TBC` | has TBC variables |
| 19 | `CIST_OAH` | saved allowhook |
| 20 | `CIST_HOOKED` | running debug hook |
| 21 | `CIST_YPCALL` | yieldable protected call |
| 22 | `CIST_TAIL` | tail call |
| 23 | `CIST_HOOKYIELD` | last hook yielded |
| 24 | `CIST_FIN` | finalizer |

Discriminator: `isLua(ci) = !(ci->callstatus & CIST_C)`.

### Control flow

**lua_callk** (lapi.c:1037-1056):
1. `func = L->top - (nargs+1)`
2. If `k != NULL && yieldable(L)`: save `k`/`ctx` in `ci->u.c`, `luaD_call` (yieldable)
3. Else: `luaD_callnoyield` (non-yieldable)
4. `adjustresults`

**lua_pcallk** (lapi.c:1076-1117):
1. If `k == NULL || !yieldable`: conventional `luaD_pcall` (setjmp/longjmp)
2. If `k != NULL && yieldable`:
   - Save `k`/`ctx` in `ci->u.c`
   - Save `funcidx` in `ci->u2.funcidx`
   - Save `old_errfunc` in `ci->u.c.old_errfunc`, set `L->errfunc = func`
   - `setoah(ci, L->allowhook)`
   - Set `CIST_YPCALL`
   - `luaD_call` (yieldable)
   - Normal return: clear `CIST_YPCALL`, restore `L->errfunc`
   - Yield: C-frame stays with `CIST_YPCALL`

**lua_yieldk** (ldo.c:1006-1034):
1. Check yieldable
2. `L->status = LUA_YIELD`
3. `ci->u2.nyield = nresults` — number of values yielded out
4. If `isLua(ci)` (hook yield): assert `nresults == 0`, `k == NULL`
5. Else (C function): save `k`/`ctx` in `ci->u.c` (if `k != NULL`), `luaD_throw(L, LUA_YIELD)`

**resume** (ldo.c:916-944):
1. If starting: `ccall(L, firstArg-1, LUA_MULTRET, 0)`
2. If resuming:
   - If `isLua(ci)` (hook yield): `luaV_execute(L, ci)`
   - Else (C function yield):
     - If `ci->u.c.k != NULL`: `n = k(L, LUA_YIELD, ci->u.c.ctx)`
     - `luaD_poscall(L, ci, n)`
   - `unroll(L, NULL)`

**unroll** (ldo.c:866-877):
```
while (ci != base_ci) {
    if (!isLua(ci)) finishCcall(L, ci);
    else { luaV_finishOp(L); luaV_execute(L, ci); }
}
```

**finishCcall** (ldo.c:837-858):
1. If `CIST_CLSRET`: redo `luaD_poscall` with `ci->u2.nres`
2. Else:
   - `kf = ci->u.c.k`
   - If `CIST_YPCALL`: `status = finishpcallk(L, ci)`
   - `adjustresults(L, LUA_MULTRET)`
   - `n = kf(L, status, ci->u.c.ctx)`
3. `luaD_poscall(L, ci, n)`

**finishpcallk** (ldo.c:804-821):
1. `status = getcistrecst(ci)`
2. If `status == LUA_OK`: `status = LUA_YIELD`
3. Else (error):
   - `func = restorestack(L, ci->u2.funcidx)`
   - `L->allowhook = getoah(ci)`
   - `func = luaF_close(L, func, status, 1)` — close TBC (can yield!)
   - `luaD_seterrorobj(L, status, func)`
   - `luaD_shrinkstack(L)`
   - `setcistrecst(ci, LUA_OK)`
4. `ci->callstatus &= ~CIST_YPCALL`
5. `L->errfunc = ci->u.c.old_errfunc`
6. Return status (passed to `k`)

**findpcall** (ldo.c:884-891): scan `ci` chain for `CIST_YPCALL`.

**precover** (ldo.c:955-963):
```
while (errorstatus(status) && (ci = findpcall(L)) != NULL) {
    L->ci = ci;
    setcistrecst(ci, status);
    status = luaD_rawrunprotected(L, unroll, NULL);
}
```

### nCcalls (lstate.h:95-117)

```c
// lower 16 bits: C call depth
// upper 16 bits: non-yieldable call depth
#define yieldable(L)    (((L)->nCcalls & 0xffff0000) == 0)
#define getCcalls(L)    ((L)->nCcalls & 0xffff)
#define incnny(L)       ((L)->nCcalls += 0x10000)
#define decnny(L)       ((L)->nCcalls -= 0x10000)
#define nyci            (0x10000 | 1)  // non-yieldable call increment
```

`LUAI_MAXCCALLS = 200`.

## Current luazig State

### CallFrame (96B, flat layout)

All fields are in a flat struct. `proto: ?*const bc.Proto` (null = C-frame) is the
implicit discriminator. No `CIST_C` bit. No C-continuation state (`k`/`ctx`/`old_errfunc`).

### CIST flags (current, non-PUC bit positions)

```
CIST_NRESULTS  = 0xff        (bits 0-7)
CIST_TAIL      = 1 << 8      (bit 8)  — PUC: bits 8-11 = CIST_CCMT
CIST_HOOKED    = 1 << 9      (bit 9)  — PUC: bit 15 = CIST_C
CIST_HOOKYIELD = 1 << 10     (bit 10) — PUC: bit 23
CIST_HIDE      = 1 << 11     (bit 11) — luazig-specific
```

Missing: `CIST_C`, `CIST_CCMT`, `CIST_RECST`, `CIST_FRESH`, `CIST_CLSRET`,
`CIST_TBC`, `CIST_OAH`, `CIST_YPCALL`, `CIST_FIN`.

### C API stubs

- `lua_callk`: ignores `k`/`ctx`, delegates to `lua_callkImpl` (non-yieldable)
- `lua_pcallk`: ignores `k`/`ctx`/`errfunc`, delegates to `api.State.pcall`
- `lua_yieldk`: ignores `k`/`ctx`, delegates to `api.State.yield`

### Yield/resume mechanism

- `builtinCoroutineYield`: uses `error.Yield` (Zig error) to unwind Zig stack
- `builtinCoroutineResume` / `driveBytecodeCoroutineTrampoline`: handles resume
- `TestcPendingContinuation`: special-case mechanism (~200 lines) for testC
  callk/pcallk/yieldk — duplicates what C-continuations should do
- `non_yieldable_c_depth: usize`: tracks non-yieldable depth (not PUC-faithful encoding)

### Error handling

- `c_error_jmp` (setjmp/longjmp): for `lua_error` in C functions
- `Vm.errfunc: ?Value` (24B, Vm-global): should be `Thread.errfunc: StackOffset` (8B, per-Thread)

## Design

### 1. CallFrame extern union

#### Discriminator

Single discriminator: `CIST_C` bit in `callstatus`.

```zig
pub fn isLua(fr: *const CallFrame) bool {
    return fr.callstatus & CIST_C == 0;
}
```

`proto` moves to `u.lua` and becomes non-optional (`*const bc.Proto`).
Invariant: `isLua(fr)` → `fr.u.lua.proto` is valid. `!isLua(fr)` → `fr.u.c` is valid.

#### CIST flag realignment

Realign bit positions to PUC (lstate.h:222-251). Add missing flags:

```
CIST_NRESULTS  = 0xff           (bits 0-7)
CIST_CCMT      = 0xf << 8       (bits 8-11)  — __call metamethod count
CIST_RECST     = 12             (bits 12-14) — recover status offset
CIST_C         = 1 << 15        (bit 15)     — C function frame
CIST_FRESH     = 1 << 16        (bit 16)     — fresh luaV_execute
CIST_CLSRET    = 1 << 17        (bit 17)     — closing TBC on return
CIST_TBC       = 1 << 18        (bit 18)     — has TBC variables
CIST_OAH       = 1 << 19        (bit 19)     — saved allowhook
CIST_HOOKED    = 1 << 20        (bit 20)     — running debug hook
CIST_YPCALL    = 1 << 21        (bit 21)     — yieldable protected call
CIST_TAIL      = 1 << 22        (bit 22)     — tail call
CIST_HOOKYIELD = 1 << 23        (bit 23)     — last hook yielded
CIST_FIN       = 1 << 24        (bit 24)     — finalizer
CIST_HIDE      = 1 << 25        (bit 25)     — luazig-specific: hide from debug
```

This is a breaking change: all existing `CIST_TAIL`/`CIST_HOOKED`/`CIST_HOOKYIELD`/`CIST_HIDE`
bit positions change. All accessor functions and all call sites must be updated.

#### StackOffset type

```zig
const StackOffset = usize;  // PUC ptrdiff_t — bc_stack index offset
```

#### CallFrame layout

```zig
pub const CallFrame = struct {
    // ── Common (both Lua and C frames) ──
    func_slot: usize = 0,
    base: usize = 0,
    callstatus: u32 = 0,
    activation_id: u32 = 0,
    reg_top: u32 = 0,
    tbc_mark: usize = 0,
    pending_call_index: u32 = INVALID_PENDING,

    // ── Variant state (PUC CallInfo.u) ──
    // Discriminator: callstatus & CIST_C
    u: union {
        lua: LuaFrameState,
        c: CFrameState,
    },
};
```

#### LuaFrameState

Fields used only by Lua frames (proto != null, `CIST_C == 0`):

```zig
const LuaFrameState = struct {
    proto: *const bc.Proto,           // non-optional — invariant: isLua → proto valid
    pc: usize = 0,                    // PUC u.l.savedpc
    func_slot_base: usize = 0,        // TAILCALL reset
    frame_cap: u32 = 0,               // register window upper bound
    nvarstack: u32 = 0,               // fixed params
    nextraargs: u16 = 0,              // PUC u.l.nextraargs
    has_open_upvalues: bool = false,  // upvalue optimization
    // Hook PC tracking (Lua-only, per-frame):
    resume_pc: u32 = INVALID_PC,
    last_line_pc: u32 = INVALID_PC,
    skip_line_hook_pc: u32 = INVALID_PC,
    skip_call_hook_pc: u32 = INVALID_PC,
    resume_skip_count_pc: u32 = INVALID_PC,
};
```

#### CFrameState

Fields used only by C frames (`CIST_C != 0`):

```zig
const CFrameAux = union {
    funcidx: StackOffset,  // pcallk: callee position for error recovery
    nyield: i32,           // yieldk: number of values yielded out
};

const CFrameState = struct {
    k: ?*const fn (?*lua_State, c_int, isize) callconv(.c) c_int = null,
    ctx: isize = 0,                    // PUC lua_KContext (ptrdiff_t)
    old_errfunc: StackOffset = 0,      // PUC ptrdiff_t; 0 = no errfunc
    aux: CFrameAux = .{ .funcidx = 0 },
};
```

**Deviation from PUC:** `u2.nres` (TBC close return count) is not in `CFrameAux`.
luazig stores TBC-close return state in `PendingCallSlot.completion.close`.
This is a deliberate deviation: luazig's continuation machinery for close operations
predates C-continuations and remains the mechanism for `__close` yield/recovery.
Documented here; not to be unified without explicit analysis.

#### pending_call_index: common

`pending_call_index` stays in common (not `u.lua`) because C-frames with TBC
variables (`CIST_TBC`) can trigger `__close` metamethods on return, which may
yield. The close continuation is stored in `PendingCallSlot`, and the C-frame
must survive resume with its `pending_call_index` intact.

#### Helper functions with assertions

```zig
pub fn isLua(fr: *const CallFrame) bool {
    return fr.callstatus & CIST_C == 0;
}
fn luaState(fr: *CallFrame) *LuaFrameState {
    std.debug.assert(fr.isLua());
    return &fr.u.lua;
}
fn cState(fr: *CallFrame) *CFrameState {
    std.debug.assert(!fr.isLua());
    return &fr.u.c;
}
```

#### Size estimate

- Common: 8+8+4+4+4+8+4 = 40B + 4B padding = 44B
- LuaFrameState: ~56B
- CFrameState: 8+8+8+8 = 32B
- Union: max(56, 32) = 56B
- Total: ~100B

Exact size measured via `@sizeOf(CallFrame)` after implementation. Growth from
96B to ~100B is the cost of adding real C-continuation state (32B) via union,
replacing fields that move from common to `u.lua`.

### 2. C-continuation lifecycle

#### Key principle: C-frame is the current C function's frame

`lua_callk`/`lua_pcallk` do NOT create a new C-frame. They save `k`/`ctx` in
the **existing** C-frame (created by `pushBuiltinCFrame` when the C function
was entered via `callCFunction`). The callee gets its own frame through the
normal call machinery (`pushBytecodeExecFrame` for Lua, `pushBuiltinCFrame`
for nested C).

The C-frame is popped only when:
- The C function returns normally (no yield) → `popBuiltinCFrame` / poscall
- The continuation `k` returns after resume → pop C-frame, poscall

#### lua_callk

1. C-frame already exists (created at `callCFunction` entry)
2. `func_slot = c_stack_top - (nargs+1)` — callee position
3. If `k != NULL` and yieldable: save `k`/`ctx` in `fr.u.c`
4. If `k == NULL` or not yieldable: `incnny(th)` (increment non-yieldable depth)
   (`lua_call` without continuation = non-yieldable boundary)
5. Call callee via `callBuiltin`/`runClosure` (callee gets its own frame)
6. Normal return: callee popped by normal mechanism, C function continues
7. Yield from callee: `error.Yield` propagates through callee frame → C-frame
   stays on `call_frames` with `k`/`ctx`

#### lua_pcallk

1. C-frame already exists
2. If `k == NULL` or not yieldable: conventional pcall (setjmp/longjmp via
   `callCFunctionWithBoundary`)
3. If `k != NULL` and yieldable:
   - Save `k`/`ctx` in `fr.u.c`
   - Save `funcidx` in `fr.u.c.aux.funcidx` (callee stack offset for error recovery)
   - Save `old_errfunc` in `fr.u.c.old_errfunc`, set `th.errfunc = func_offset`
   - `setoah(fr, th.allowhook)` — save allowhook via `CIST_OAH`
   - Set `CIST_YPCALL` on `fr.callstatus`
   - Call callee (yieldable path)
   - Normal return: clear `CIST_YPCALL`, restore `th.errfunc = fr.u.c.old_errfunc`
   - Yield: C-frame stays with `CIST_YPCALL`

#### lua_yieldk

1. Check yieldable (`th.yieldable()`)
2. `th.status = .suspended`
3. `fr.u.c.aux.nyield = nresults` — number of values yielded out (NOT results
   after resume; at resume, result count comes from resume nargs or `k` return)
4. Save `k`/`ctx` in `fr.u.c` (if `k != NULL`)
5. `error.Yield` — unwind Zig stack (replaces `luaD_throw(L, LUA_YIELD)`)

If `isLua(ci)` (hook yield): PUC asserts `nresults == 0` and `k == NULL`.
luazig: existing hook-yield path remains (no C-continuation for hooks).

#### Resume / unroll

Integrated into `driveBytecodeCoroutineTrampoline`:

1. After resume, inspect topmost frame:
   - **Lua frame** (`isLua`): continue bytecode execution (existing path)
   - **C-frame with `k != NULL`**: `finishCcall` equivalent:
     - `adjustresults(LUA_MULTRET)` — adjust stack to match callee results
     - `status = LUA_YIELD` (or `CIST_RECST` if error recovery)
     - If `CIST_YPCALL`: `finishpcallk(fr)` — restore error state, close TBC
     - `n = k(L, status, ctx)` via raw continuation invocation
       (see "Raw continuation invocation" below)
     - poscall C-frame (move n results, pop frame)
     - continue trampoline (may encounter more frames)
   - **C-frame with `k == NULL`**: poscall with resume `nargs` (not `nyield`),
     pop, continue. `nyield` is used for `lua_resume(..., &nresults)` at yield
     time (reported to the resume caller), not for poscall at resume time.
   - **Ordinary coroutine yield** (no C-frame): existing coroutine result/resume semantics
2. If `k` itself yield'ит: `error.Yield` propagates, C-frame stays suspended
3. If `k` calls `lua_callk`/`lua_pcallk` which yield: nested C-frames created,
   unroll continues

#### finishpcallk (error recovery)

1. `status = getcistrecst(fr)` — get original error status
2. If `status == LUA_OK`: `status = LUA_YIELD` (interrupted by yield, not error)
3. Else (error):
   - `func = fr.u.c.aux.funcidx` — recover callee position
   - `th.allowhook = getoah(fr)` — restore allowhook
   - Close TBC variables at `func` position (can yield! → re-enter precover loop)
   - Set error object on stack
   - `setcistrecst(fr, LUA_OK)` — clear status
4. `fr.callstatus &= ~CIST_YPCALL`
5. `th.errfunc = fr.u.c.old_errfunc` — restore errfunc
6. Return status (passed to `k` as argument)

#### findpcall / precover

**findpcall**: scan `call_frames` for `CIST_YPCALL` — find suspended pcallk C-frame.

**precover**:
1. Error during resumed/unrolled execution
2. `findpcall` finds C-frame with `CIST_YPCALL`
3. `setcistrecst(fr, status)` — save error status in `CIST_RECST`
4. Re-enter trampoline (unroll) from that frame
5. `finishpcallk` reads `CIST_RECST`, restores error state, calls `k` with error status
6. If `k` errors again → `precover` loop continues
7. If no `CIST_YPCALL` found → unrecoverable error, coroutine dies

#### CIST_RECST (recover status)

3 bits in `callstatus` (bits 12-14). Stores error status during yield from
`__close` at error recovery in pcallk. `getcistrecst(fr)` / `setcistrecst(fr, status)`.

#### CIST_OAH (saved allowhook)

1 bit in `callstatus` (bit 19). `setoah(fr, th.allowhook)` / `getoah(fr)`.
Used in `lua_pcallk` (save before yieldable call) and `finishpcallk` (restore on error).

#### Raw continuation invocation

The continuation `k` must execute **in the existing suspended C-frame**, not
through a helper that pushes a new C CallFrame. PUC calls `k` directly in
`finishCcall` without creating a new `CallInfo`.

luazig must provide a raw continuation invocation path:
- No `pushBuiltinCFrame` / `callCFunction` call for `k` itself
- The suspended C-frame's `func_slot`/`base`/`top` remain as-is
- `k` runs with the current thread's stack state as-is
- `k` returns `n` (number of results), then `poscall` moves results and pops
  the C-frame
- If `k` itself calls `lua_callk`/`lua_pcallk` that yields, a **nested** C-frame
  is created for the callee — but `k`'s own C-frame is the one it's running in

This is distinct from `callCFunction` (which pushes a new C-frame for an
initial C function entry). The continuation path reuses the existing frame.

### 3. nCcalls / yieldable (per-Thread)

Replace `non_yieldable_c_depth: usize` (Vm-global) with PUC-faithful
`nCcalls: u32` **on Thread** (lua_State equivalent), not Vm-global:

```zig
// On Thread (lua_State equivalent), NOT Vm:
nCcalls: u32 = 0,
// lower 16 bits: C call depth (getCcalls)
// upper 16 bits: non-yieldable call depth

fn yieldable(th: *Thread) bool {
    return th.nCcalls & 0xffff0000 == 0;
}
fn getCcalls(th: *Thread) u16 {
    return @truncate(th.nCcalls & 0xffff);
}
fn incnny(th: *Thread) void {
    th.nCcalls +%= 0x10000;
}
fn decnny(th: *Thread) void {
    th.nCcalls -%= 0x10000;
}
```

`LUAI_MAXCCALLS = 200`. `nyci = 0x10001` (increment both C-call and non-yieldable).

**lua_resume C-call depth inheritance:** PUC `lua_resume` sets
`L->nCcalls = getCcalls(from) + 1` — the resumed coroutine inherits the
lower 16 bits (C-call depth) from the resuming thread, plus 1. The upper
16 bits (non-yieldable depth) start at 0 (coroutine is yieldable at start).
luazig must replicate this: `co.nCcalls = (from.nCcalls & 0xffff) + 1`.

### 4. errfunc / allowhook refactor (per-Thread)

`errfunc` and `allowhook` are **per-Thread** (lua_State equivalent), not
Vm-global. PUC stores `L->errfunc` and `L->allowhook` on `lua_State`.

Current luazig has `Vm.errfunc: ?Value` (24B) and `Vm.allowhook` — both
Vm-global. These must move to Thread.

`Vm.errfunc: ?Value` (24B) → `Thread.errfunc: StackOffset` (8B, 0 = no errfunc).
`Vm.allowhook` → `Thread.allowhook`.

All access sites updated:
- `invokeErrfunc`: `th.bc_stack[th.errfunc]` instead of direct `Value`
- `lua_pcallk`: save/restore `th.errfunc` as `StackOffset`
- `finishpcallk`: restore `th.errfunc` from `fr.u.c.old_errfunc`
- `setoah(fr, th.allowhook)` / `th.allowhook = getoah(fr)`

### 5. TestcPendingContinuation removal

`TestcPendingContinuation` (~200 lines) fully removed:
- `testc_pending_conts` field on Thread — deleted
- `saveTestcPendingContinuation` — deleted
- `resumeTestcCloseReturnContinuation` — deleted
- testC `callk`/`pcallk`/`yieldk` commands use real `lua_callk`/`lua_pcallk`/`lua_yieldk`
  with actual `k` callback functions

### 6. What does NOT change

- **Ordinary Lua coroutine yield/resume** — no C-frame, no `k`/`ctx`. Existing path:
  `error.Yield` → `th.yielded` → resume → continue bytecode execution.
- **Debug-hook yield** — hook-specific state (`CIST_HOOKYIELD`, hook frame cleanup)
  remains. Hook yield does not use C-continuation `k` (PUC: `api_check(L, k == NULL,
  "hooks cannot continue after yielding")`).
- **`PendingCallSlot`** — unchanged. Vm-level sparse storage for luazig-internal VM
  continuations (hooks, close, metamethods, coroutine_resume). NOT C continuations.
- **`callCFunction` / `callCFunctionWithBoundary`** — setjmp/longjmp boundary remains
  for error handling in non-yieldable C calls. Yieldable C calls (`lua_callk`/`lua_pcallk`
  with `k`) use `error.Yield` instead of longjmp.
- **`frame_loop`** — unchanged. C-continuation replay happens in
  `driveBytecodeCoroutineTrampoline`, not in `frame_loop`.

### 7. API checks (PUC-faithful)

PUC enforces several API invariants via `api_check`. luazig must replicate these:

- **`lua_yieldk` inside a hook**: `api_check(L, k == NULL, "hooks cannot continue
  after yielding")`. If the topmost frame is a hook frame (`CIST_HOOKED` /
  `CIST_HOOKYIELD`), `k` must be NULL. A non-NULL `k` in a hook context is an
  API violation.
- **`lua_yieldk` yieldability**: `api_check(L, yieldable(L), "attempt to yield
  across a C-call boundary")`. Enforced via `!th.yieldable()` check
  (upper 16 bits of `nCcalls` nonzero).
- **`lua_callk`/`lua_pcallk` continuation in hook**: PUC does not explicitly
  forbid `lua_callk`/`lua_pcallk` with `k != NULL` inside hooks, but since hooks
  cannot yield (`CIST_HOOKYIELD` path), any yield from the callee would be a
  "attempt to yield across a C-call boundary" error. The `k` would simply never
  be called. This is consistent PUC behavior — no extra check needed.

## Testing

### C API differential tests

C test programs compiled against both luazig's `c_api.zig` exports and PUC Lua's
`liblua.a`. Compare stdout. Cover:

1. `lua_yieldk` → resume → `k` called with correct `ctx`
2. `lua_callk` with callee that yields
3. `lua_pcallk` with yield
4. `lua_pcallk` with error
5. Nested C continuations
6. C → Lua → C → yield → resume
7. Continuation that itself calls Lua
8. Continuation that yields again (if PUC allows)
9. Coroutine close/reset with suspended C continuation
10. TBC/error interaction
11. Debug hooks near suspended C continuation
12. Stack/result placement and MULTRET
13. Correct status argument passed to `k`
14. Correct `ctx` preservation
15. Non-yieldable boundary behavior

### testC scripts

testC scripts using `T.callk`/`T.pcallk`/`T.yieldk` commands, comparing luazig
vs PUC Lua testC output. Reuses existing testC infrastructure.

### Regression

- matrix 30/31 (no new regressions)
- smoke 49/49
- unit 146/146
- leakbench 25/25
- `lua_calls` benchmark — no significant regression
- geomean — no significant regression

## Implementation phases (Approach A: Bottom-up)

1. **Phase 1**: CallFrame union restructure + CIST flag realignment + errfunc refactor
2. **Phase 2**: `lua_callk`/`lua_pcallk`/`lua_yieldk` with real `k`/`ctx` + resume/unroll integration
3. **Phase 3**: TestcPendingContinuation migration + removal
4. **Phase 4**: C API differential tests + testC scripts + final verification
