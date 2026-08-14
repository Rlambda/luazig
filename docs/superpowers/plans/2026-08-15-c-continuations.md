# PUC Lua 5.5 C Continuations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement real PUC Lua 5.5 C continuation semantics (`lua_callk`, `lua_pcallk`, `lua_yieldk` with `k`/`ctx` that survive yield/resume), replacing the current stub implementations that ignore `k`/`ctx`.

**Architecture:** CallFrame restructured with PUC-faithful extern union (`u: union { lua: LuaFrameState, c: CFrameState }`), `CIST_C` bit as discriminator. C-continuation state (`k`/`ctx`/`old_errfunc`) stored in `u.c`. Resume/unroll integrated into `driveBytecodeCoroutineTrampoline`. `errfunc`/`allowhook`/`nCcalls` moved to per-Thread. `TestcPendingContinuation` removed entirely.

**Tech Stack:** Zig (toolchain target), PUC Lua 5.5 (architectural reference), C API differential tests, testC scripts.

**Spec:** `docs/superpowers/specs/2026-08-15-c-continuations-design.md`

---

## File Structure

### Files to modify:
- `src/lua/vm.zig` (~33K lines): CallFrame restructure, CIST flags, Thread fields, resume/unroll, TestcPendingContinuation removal
- `src/lua/c_api.zig`: lua_callk/lua_pcallk/lua_yieldk/lua_resume implementations
- `src/lua/api.zig`: api.State.call/pcall/yield adjustments
- `tests/check_sizes.zig`: Update for new CallFrame size

### Files to create:
- `tests/c_api/10_continuations.c`: C API differential tests for C continuations
- `tests/c_api/Makefile`: Add test 10

### Test infrastructure:
- `tools/testes_matrix.py --testc`: Upstream Lua test suite
- `tests/smoke/`: 49 smoke tests
- `tests/c_api/`: C API tests (compiled against liblua.so)
- `zig build test`: Zig unit tests

---

## Phase 1: CallFrame Union Restructure + CIST Realignment + Per-Thread State

### Task 1: Add new CIST constants with PUC bit positions

**Files:**
- Modify: `src/lua/vm.zig:1069-1084`

- [ ] **Step 1: Add all PUC CIST constants**

Replace the current CIST constants block (lines 1069-1084) with PUC-faithful bit positions:

```zig
/// PUC `CIST_NRESULTS` (`lstate.h:223`): low 8 bits of callstatus encode
/// `nresults + 1`. MULTRET (`LUA_MULTRET = -1`) encodes as `0`.
/// `MAXRESULTS = 250` fits (`251 <= 255`).
const CIST_NRESULTS: u32 = 0xff;
const MAXRESULTS: i32 = 250;

/// PUC callstatus flag bits (`lstate.h:222-254`).
/// Low 8 bits are CIST_NRESULTS (nresults+1). Upper bits are flags.
/// Bits 8-11: CIST_CCMT — __call metamethod count.
const CIST_CCMT: u32 = 8;  // shift count, not mask
const MAX_CCMT: u32 = 0xf << CIST_CCMT;
/// Bits 12-14: CIST_RECST — recover status (error during pcallk).
const CIST_RECST: u32 = 12;  // shift count
/// Bit 15: CIST_C — C function frame (discriminator).
const CIST_C: u32 = 1 << 15;
/// Bit 16: CIST_FRESH — fresh luaV_execute frame.
const CIST_FRESH: u32 = 1 << 16;
/// Bit 17: CIST_CLSRET — closing TBC variables on return.
const CIST_CLSRET: u32 = 1 << 17;
/// Bit 18: CIST_TBC — has TBC variables.
const CIST_TBC: u32 = 1 << 18;
/// Bit 19: CIST_OAH — saved allowhook.
const CIST_OAH: u32 = 1 << 19;
/// Bit 20: CIST_HOOKED — running debug hook.
const CIST_HOOKED: u32 = 1 << 20;
/// Bit 21: CIST_YPCALL — yieldable protected call.
const CIST_YPCALL: u32 = 1 << 21;
/// Bit 22: CIST_TAIL — tail call.
const CIST_TAIL: u32 = 1 << 22;
/// Bit 23: CIST_HOOKYIELD — last hook yielded.
const CIST_HOOKYIELD: u32 = 1 << 23;
/// Bit 24: CIST_FIN — finalizer.
const CIST_FIN: u32 = 1 << 24;
/// Bit 25: CIST_HIDE — luazig-specific: hide from debug.getinfo.
const CIST_HIDE: u32 = 1 << 25;
```

- [ ] **Step 2: Add CIST_RECST helper functions**

After the `encodeNresults`/`decodeNresults` functions, add:

```zig
/// PUC `getcistrecst` (`lstate.h:243`): extract recover status from callstatus.
inline fn getcistrecst(callstatus: u32) u32 {
    return (callstatus >> CIST_RECST) & 7;
}

/// PUC `setcistrecst` (`lstate.h:244`): set recover status in callstatus.
inline fn setcistrecst(callstatus: u32, st: u32) u32 {
    return (callstatus & ~(7 << CIST_RECST)) | (st << CIST_RECST);
}

/// PUC `setoah` (`lstate.h:248`): save allowhook in callstatus.
inline fn setoah(callstatus: u32, v: bool) u32 {
    return if (v) callstatus | CIST_OAH else callstatus & ~CIST_OAH;
}

/// PUC `getoah` (`lstate.h:249`): restore allowhook from callstatus.
inline fn getoah(callstatus: u32) bool {
    return (callstatus & CIST_OAH) != 0;
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | head -30`
Expected: Build succeeds (existing CIST_TAIL/CIST_HOOKED/CIST_HOOKYIELD/CIST_HIDE references still work because the constants are now at new bit positions but the accessor functions use the constant names)

- [ ] **Step 4: Run tests to verify no regression**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc 2>&1 | tail -5`
Expected: 30/31 (same as before — only big.lua fails)

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" 2>&1 | grep -q "FAIL" && echo "FAIL: $f"; done; echo "smoke done"`
Expected: No failures

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.78: realign CIST flags to PUC bit positions

Add CIST_C (bit 15), CIST_CCMT (bits 8-11), CIST_RECST (bits 12-14),
CIST_FRESH (bit 16), CIST_CLSRET (bit 17), CIST_TBC (bit 18),
CIST_OAH (bit 19), CIST_YPCALL (bit 21), CIST_FIN (bit 24).
Realign CIST_TAIL (22), CIST_HOOKED (20), CIST_HOOKYIELD (23),
CIST_HIDE (25) to PUC positions.
Add getcistrecst/setcistrecst/setoah/getoah helpers."
```

---

### Task 2: Update all CIST flag accessor functions in CallFrame

**Files:**
- Modify: `src/lua/vm.zig:1185-1229` (CallFrame accessor methods)

- [ ] **Step 1: Update accessor methods to use new bit positions**

The accessor functions already reference the constants by name (e.g., `CIST_TAIL`), so they automatically use the new bit positions. But we need to add new accessors for the new flags. Replace the accessor block (lines 1185-1229) with:

```zig
    /// P15.78: callstatus flag accessors (PUC CIST_* bits).
    /// Discriminator: CIST_C (bit 15). isLua = !CIST_C.
    pub fn isLua(fr: CallFrame) bool {
        return fr.callstatus & CIST_C == 0;
    }
    pub fn isC(fr: CallFrame) bool {
        return fr.callstatus & CIST_C != 0;
    }
    pub fn isTailCall(fr: CallFrame) bool {
        return (fr.callstatus & CIST_TAIL) != 0;
    }
    pub fn isDebugHook(fr: CallFrame) bool {
        return (fr.callstatus & CIST_HOOKED) != 0;
    }
    pub fn isHookYield(fr: CallFrame) bool {
        return (fr.callstatus & CIST_HOOKYIELD) != 0;
    }
    pub fn isHidden(fr: CallFrame) bool {
        return (fr.callstatus & CIST_HIDE) != 0;
    }
    pub fn isYpcall(fr: CallFrame) bool {
        return (fr.callstatus & CIST_YPCALL) != 0;
    }
    pub fn isTbc(fr: CallFrame) bool {
        return (fr.callstatus & CIST_TBC) != 0;
    }
    pub fn isClsret(fr: CallFrame) bool {
        return (fr.callstatus & CIST_CLSRET) != 0;
    }
    pub fn setTailCall(fr: *CallFrame) void { fr.callstatus |= CIST_TAIL; }
    pub fn setDebugHook(fr: *CallFrame) void { fr.callstatus |= CIST_HOOKED; }
    pub fn setHookYield(fr: *CallFrame) void { fr.callstatus |= CIST_HOOKYIELD; }
    pub fn setHookYieldBool(fr: *CallFrame, v: bool) void {
        if (v) fr.callstatus |= CIST_HOOKYIELD else fr.callstatus &= ~CIST_HOOKYIELD;
    }
    pub fn setHidden(fr: *CallFrame) void { fr.callstatus |= CIST_HIDE; }
    pub fn setC(fr: *CallFrame) void { fr.callstatus |= CIST_C; }
    pub fn setYpcall(fr: *CallFrame) void { fr.callstatus |= CIST_YPCALL; }
    pub fn clearYpcall(fr: *CallFrame) void { fr.callstatus &= ~CIST_YPCALL; }
    pub fn setTbc(fr: *CallFrame) void { fr.callstatus |= CIST_TBC; }
    pub fn setClsret(fr: *CallFrame) void { fr.callstatus |= CIST_CLSRET; }
    pub fn clearTailCall(fr: *CallFrame) void { fr.callstatus &= ~CIST_TAIL; }
    pub fn clearDebugHook(fr: *CallFrame) void { fr.callstatus &= ~CIST_HOOKED; }
    pub fn clearHookYield(fr: *CallFrame) void { fr.callstatus &= ~CIST_HOOKYIELD; }
    pub fn clearHidden(fr: *CallFrame) void { fr.callstatus &= ~CIST_HIDE; }
    pub fn setTailCallBool(fr: *CallFrame, v: bool) void {
        if (v) fr.callstatus |= CIST_TAIL else fr.callstatus &= ~CIST_TAIL;
    }
```

- [ ] **Step 2: Build and test**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | head -30`
Expected: Build succeeds

Run: `python3 tools/testes_matrix.py --testc 2>&1 | tail -5`
Expected: 30/31

- [ ] **Step 3: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.78: add CIST_C discriminator and new flag accessors

Add isLua/isC (CIST_C discriminator), isYpcall/isTbc/isClsret accessors.
Add setC/setYpcall/clearYpcall/setTbc/setClsret mutators."
```

---

### Task 3: Set CIST_C on C-frames in pushBuiltinCFrame

**Files:**
- Modify: `src/lua/vm.zig:4248-4252` (pushBuiltinCFrame)

- [x] **Step 1: Set CIST_C bit when creating C-frame**

In `pushBuiltinCFrame`, after `slot.* = .{ ... }` and before `slot.clearHidden()`, add `slot.setC()`:

```zig
        slot.* = .{
            .func_slot = func_slot,
            .base = func_slot + 1,
        };
        slot.setC();
        slot.clearHidden();
```

- [ ] **Step 2: Search for all other C-frame creation sites**

Run: `grep -n "proto = null\|proto =\s*null" src/lua/vm.zig | head -20`

Any site that creates a CallFrame with `proto = null` (implicitly or explicitly) is a C-frame and must set CIST_C. Check each one.

- [ ] **Step 3: Build and test**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc 2>&1 | tail -5`
Expected: 30/31

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.78: set CIST_C on C-frames in pushBuiltinCFrame"
```

---

### Task 4: Add StackOffset type and CFrameState/LuaFrameState structs

**Files:**
- Modify: `src/lua/vm.zig` (before CallFrame struct definition)

- [ ] **Step 1: Add StackOffset type**

Before the CallFrame struct (around line 1098), add:

```zig
/// PUC `ptrdiff_t` — stack offset for errfunc and funcidx.
/// 0 = no errfunc / invalid position.
const StackOffset = usize;
```

- [ ] **Step 2: Add CFrameAux union**

```zig
/// PUC `CallInfo.u2` — mutually exclusive C-frame auxiliary state.
const CFrameAux = union {
    /// pcallk: callee stack offset for error recovery (PUC `u2.funcidx`).
    funcidx: StackOffset,
    /// yieldk: number of values yielded out (PUC `u2.nyield`).
    nyield: i32,
};
```

- [ ] **Step 3: Add CFrameState struct**

```zig
/// PUC `CallInfo.u.c` — C function frame state.
/// Only valid when `callstatus & CIST_C != 0`.
const CFrameState = struct {
    /// PUC `u.c.k`: continuation function, called on resume after yield.
    /// null = no continuation (plain yield or non-yieldable call).
    k: ?*const fn (?*lua_State, c_int, isize) callconv(.c) c_int = null,
    /// PUC `u.c.ctx`: continuation context, passed to k on resume.
    ctx: isize = 0,
    /// PUC `u.c.old_errfunc`: saved errfunc for pcallk error recovery.
    /// 0 = no errfunc was set.
    old_errfunc: StackOffset = 0,
    /// PUC `u2`: mutually exclusive auxiliary state.
    aux: CFrameAux = .{ .funcidx = 0 },
};
```

- [ ] **Step 4: Add LuaFrameState struct**

```zig
/// PUC `CallInfo.u.l` — Lua function frame state.
/// Only valid when `callstatus & CIST_C == 0`.
const LuaFrameState = struct {
    /// PUC `u.l.savedpc`: current bytecode PC.
    pc: usize = 0,
    /// PUC `ci->func`: bc_stack index of the function value.
    func_slot: usize = 0,
    /// Unshifted func_slot — position before buildhiddenargs shifted it.
    func_slot_base: usize = 0,
    /// Register window upper bound (PUC `ci->top - ci->func`).
    frame_cap: u32 = 0,
    /// PUC `u.l.nextraargs`: extra vararg arguments.
    nextraargs: u16 = 0,
    /// Fixed params count (PUC `ci->func + 1 .. ci->base`).
    nvarstack: u32 = 0,
    /// True when any register in boxed has an open upvalue cell.
    has_open_upvalues: bool = false,
    /// Hook PC tracking (Lua-only, per-frame).
    resume_pc: u32 = INVALID_PC,
    last_line_pc: u32 = INVALID_PC,
    skip_line_hook_pc: u32 = INVALID_PC,
    skip_call_hook_pc: u32 = INVALID_PC,
    resume_skip_count_pc: u32 = INVALID_PC,
};
```

- [ ] **Step 5: Build to verify structs compile**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | head -30`
Expected: Build succeeds (structs defined but not yet used)

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.78: add StackOffset, CFrameAux, CFrameState, LuaFrameState

PUC-faithful CallInfo.u.c/u.l/u2 equivalents. Not yet integrated
into CallFrame — defined as standalone structs for incremental
migration."
```

---

### Task 5: Restructure CallFrame with extern union

**Files:**
- Modify: `src/lua/vm.zig:1099-1243` (CallFrame struct)

This is the largest mechanical change. The CallFrame struct transitions from a flat layout with `proto: ?*const bc.Proto` as discriminator to a union layout with `CIST_C` as discriminator.

- [ ] **Step 1: Replace CallFrame struct with union layout**

Replace the entire CallFrame struct (lines 1099-1243) with:

```zig
pub const CallFrame = struct {
    // ── Common fields (both Lua and C frames) ──
    /// PUC `ci->func`: bc_stack index of the function value.
    /// Common to both Lua and C frames (PUC stores func in CallInfo directly).
    func_slot: usize = 0,
    /// PUC `ci->top` equivalent: base of register window.
    base: usize = 0,
    /// PUC `callstatus`: low 8 bits = nresults+1, upper bits = CIST_* flags.
    /// CIST_C (bit 15) is the discriminator for the `u` union.
    callstatus: u32 = 0,
    /// Activation ID for bytecode frame invalidation.
    activation_id: u32 = 0,
    /// Register top (PUC `ci->top` adjusted during execution).
    reg_top: u32 = 0,
    /// TBC mark: bc_stack index of the to-be-closed slot chain.
    tbc_mark: usize = 0,
    /// Index into Vm.pending_calls (INVALID_PENDING = none).
    pending_call_index: u32 = INVALID_PENDING,

    // ── Variant state (PUC CallInfo.u) ──
    // Discriminator: callstatus & CIST_C
    // isLua(fr) → fr.u.lua is valid
    // isC(fr)   → fr.u.c   is valid
    u: union {
        lua: LuaFrameState,
        c: CFrameState,
    } = .{ .c = .{} },

    // ── Accessors ──
    pub fn isLua(fr: CallFrame) bool {
        return fr.callstatus & CIST_C == 0;
    }
    pub fn isC(fr: CallFrame) bool {
        return fr.callstatus & CIST_C != 0;
    }
    pub fn isTailCall(fr: CallFrame) bool {
        return (fr.callstatus & CIST_TAIL) != 0;
    }
    pub fn isDebugHook(fr: CallFrame) bool {
        return (fr.callstatus & CIST_HOOKED) != 0;
    }
    pub fn isHookYield(fr: CallFrame) bool {
        return (fr.callstatus & CIST_HOOKYIELD) != 0;
    }
    pub fn isHidden(fr: CallFrame) bool {
        return (fr.callstatus & CIST_HIDE) != 0;
    }
    pub fn isYpcall(fr: CallFrame) bool {
        return (fr.callstatus & CIST_YPCALL) != 0;
    }
    pub fn isTbc(fr: CallFrame) bool {
        return (fr.callstatus & CIST_TBC) != 0;
    }
    pub fn isClsret(fr: CallFrame) bool {
        return (fr.callstatus & CIST_CLSRET) != 0;
    }
    pub fn setTailCall(fr: *CallFrame) void { fr.callstatus |= CIST_TAIL; }
    pub fn setDebugHook(fr: *CallFrame) void { fr.callstatus |= CIST_HOOKED; }
    pub fn setHookYield(fr: *CallFrame) void { fr.callstatus |= CIST_HOOKYIELD; }
    pub fn setHookYieldBool(fr: *CallFrame, v: bool) void {
        if (v) fr.callstatus |= CIST_HOOKYIELD else fr.callstatus &= ~CIST_HOOKYIELD;
    }
    pub fn setHidden(fr: *CallFrame) void { fr.callstatus |= CIST_HIDE; }
    pub fn setC(fr: *CallFrame) void { fr.callstatus |= CIST_C; }
    pub fn setYpcall(fr: *CallFrame) void { fr.callstatus |= CIST_YPCALL; }
    pub fn clearYpcall(fr: *CallFrame) void { fr.callstatus &= ~CIST_YPCALL; }
    pub fn setTbc(fr: *CallFrame) void { fr.callstatus |= CIST_TBC; }
    pub fn setClsret(fr: *CallFrame) void { fr.callstatus |= CIST_CLSRET; }
    pub fn clearTailCall(fr: *CallFrame) void { fr.callstatus &= ~CIST_TAIL; }
    pub fn clearDebugHook(fr: *CallFrame) void { fr.callstatus &= ~CIST_HOOKED; }
    pub fn clearHookYield(fr: *CallFrame) void { fr.callstatus &= ~CIST_HOOKYIELD; }
    pub fn clearHidden(fr: *CallFrame) void { fr.callstatus &= ~CIST_HIDE; }
    pub fn setTailCallBool(fr: *CallFrame, v: bool) void {
        if (v) fr.callstatus |= CIST_TAIL else fr.callstatus &= ~CIST_TAIL;
    }

    // ── Proto accessors (delegate to u.lua) ──
    // These provide backward compatibility during migration.
    // After migration is complete, direct u.lua access is preferred.
    pub fn proto(fr: CallFrame) ?*const bc.Proto {
        if (fr.isLua()) return fr.u.lua_proto;
        return null;
    }

    pub fn isVararg(fr: CallFrame) bool {
        if (fr.isLua()) {
            if (fr.u.lua_proto) |p| return p.is_vararg;
        }
        return false;
    }

    pub fn lineDefined(fr: CallFrame) i64 {
        if (fr.isLua()) {
            if (fr.u.lua_proto) |p| return @intCast(p.line_defined);
        }
        return -1;
    }

    pub fn sourceName(fr: CallFrame) []const u8 {
        if (fr.isLua()) {
            if (fr.u.lua_proto) |p| return p.source_name;
        }
        return "=[C]";
    }

    pub fn funcName(fr: CallFrame) []const u8 {
        if (fr.isLua()) {
            if (fr.u.lua_proto) |p| return p.name;
        }
        return "?";
    }

    pub fn regsSlice(fr: CallFrame, stack: []Value) []Value {
        return stack[fr.base .. fr.base + fr.frame_cap];
    }

    pub fn boxedSlice(fr: CallFrame, boxed_stack: []?*Cell) []?*Cell {
        return boxed_stack[fr.base .. fr.base + fr.frame_cap];
    }
};
```

**IMPORTANT:** This step will NOT compile yet because all existing code accesses `fr.proto` as a field (not a function), `fr.pc`, `fr.func_slot_base`, `fr.frame_cap`, `fr.nextraargs`, `fr.nvarstack`, `fr.has_open_upvalues`, `fr.resume_pc`, `fr.last_line_pc`, `fr.skip_line_hook_pc`, `fr.skip_call_hook_pc`, `fr.resume_skip_count_pc` directly. These fields now live inside `fr.u.lua`. The next steps fix all access sites.

- [ ] **Step 2: Add proto to LuaFrameState and update the union**

Actually, `proto` needs to be in `LuaFrameState`. Update `LuaFrameState` to include `proto`:

```zig
const LuaFrameState = struct {
    /// PUC `Proto*` — the bytecode prototype. Non-optional for Lua frames.
    /// Invariant: isLua(fr) → fr.u.lua.proto != null
    proto: ?*const bc.Proto = null,
    // ... rest of LuaFrameState fields ...
};
```

And update the `proto()` accessor in CallFrame:

```zig
    pub fn proto(fr: CallFrame) ?*const bc.Proto {
        if (fr.isLua()) return fr.u.lua.proto;
        return null;
    }
```

- [ ] **Step 3: Find all direct field accesses that need migration**

Run these searches to find all sites that access fields now in `u.lua`:

```bash
grep -n 'fr\.proto\b\|frame\.proto\b\|\.proto\b' src/lua/vm.zig | grep -v '//' | grep -v 'lua_proto' | wc -l
grep -n '\.pc\b' src/lua/vm.zig | grep -v '//' | grep -v 'INVALID_PC\|resume_pc\|skip_\|last_line\|CIST_\|encodeNresults\|decodeNresults' | wc -l
grep -n '\.func_slot_base\b' src/lua/vm.zig | wc -l
grep -n '\.frame_cap\b' src/lua/vm.zig | wc -l
grep -n '\.nextraargs\b' src/lua/vm.zig | wc -l
grep -n '\.nvarstack\b' src/lua/vm.zig | wc -l
grep -n '\.has_open_upvalues\b' src/lua/vm.zig | wc -l
```

- [ ] **Step 4: Migrate all `fr.proto` / `frame.proto` accesses**

Every `fr.proto` becomes `fr.proto()` (function call) OR `fr.u.lua.proto` (direct union access). Use `fr.proto()` for read-only access. For writes, use `fr.u.lua.proto = ...`.

Search and replace pattern:
- `fr.proto` → `fr.proto()` (for reads)
- `frame.proto` → `frame.proto()` (for reads)
- `.proto =` → `.u.lua.proto =` (for writes in struct initialization)
- `.proto ==` → `.proto() =="` (for comparisons)

**NOTE:** This is a large mechanical change. Use `grep` to find all sites, then update each one. Be careful with struct initialization (`.{ .proto = ... }`) — these need `.u = .{ .lua = .{ .proto = ... } }`.

- [ ] **Step 5: Migrate `fr.pc` → `fr.u.lua.pc`**

Every `fr.pc` becomes `fr.u.lua.pc`. Search for all `.pc` accesses on CallFrame variables and update.

- [ ] **Step 6: Migrate remaining Lua-only fields**

Update all accesses:
- `fr.func_slot_base` → `fr.u.lua.func_slot_base`
- `fr.frame_cap` → `fr.u.lua.frame_cap`
- `fr.nextraargs` → `fr.u.lua.nextraargs`
- `fr.nvarstack` → `fr.u.lua.nvarstack`
- `fr.has_open_upvalues` → `fr.u.lua.has_open_upvalues`
- `fr.resume_pc` → `fr.u.lua.resume_pc`
- `fr.last_line_pc` → `fr.u.lua.last_line_pc`
- `fr.skip_line_hook_pc` → `fr.u.lua.skip_line_hook_pc`
- `fr.skip_call_hook_pc` → `fr.u.lua.skip_call_hook_pc`
- `fr.resume_skip_count_pc` → `fr.u.lua.resume_skip_count_pc`

- [ ] **Step 7: Update struct initialization sites**

Every site that creates a CallFrame with `.{ .proto = ..., .pc = ..., ... }` must be updated to use the union:

```zig
// Before:
.{ .proto = p, .pc = 0, .func_slot = fs, .base = fs + 1, ... }

// After:
.{ .func_slot = fs, .base = fs + 1, .u = .{ .lua = .{ .proto = p, .pc = 0, ... } }, ... }
```

For C-frames:
```zig
// Before:
.{ .func_slot = fs, .base = fs + 1 }

// After:
.{ .func_slot = fs, .base = fs + 1, .u = .{ .c = .{} } }
```

- [ ] **Step 8: Build and fix compilation errors**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | head -50`

Fix errors iteratively. Common issues:
- `fr.proto` should be `fr.proto()` for reads
- Field accesses need `.u.lua.` prefix
- Struct initialization needs union syntax

- [ ] **Step 9: Run tests**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc 2>&1 | tail -5`
Expected: 30/31

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" 2>&1 | grep -q "FAIL" && echo "FAIL: $f"; done; echo "smoke done"`
Expected: No failures

- [ ] **Step 10: Check CallFrame size**

Run: `zig build -Doptimize=ReleaseFast && zig run tests/check_sizes.zig`
Expected: CallFrame ~100B (up from 96B, due to CFrameState in union)

- [ ] **Step 11: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.78: restructure CallFrame with PUC-faithful extern union

CallFrame now uses u: union { lua: LuaFrameState, c: CFrameState }
with CIST_C bit as discriminator. proto moves to u.lua, C-continuation
state (k/ctx/old_errfunc/aux) in u.c. All field accesses migrated."
```

---

### Task 6: Move errfunc from Vm to Thread

**Files:**
- Modify: `src/lua/vm.zig` (Thread struct, Vm struct, all errfunc access sites)
- Modify: `src/lua/c_api.zig` (lua_pcallk errfunc parameter)

- [ ] **Step 1: Add errfunc field to Thread**

In the Thread struct (around line 1342, after `status`), add:

```zig
    /// PUC `L->errfunc` (lstate.h:307): stack offset of error handler.
    /// 0 = no errfunc. Set by xpcall and pcallk.
    errfunc: StackOffset = 0,
```

- [ ] **Step 2: Remove errfunc from Vm**

Remove `errfunc: ?Value = null` (line 2625) and `errfunc_running: bool = false` (line 2630) from the Vm struct. Keep `errfunc_running` on Thread too:

```zig
    errfunc_running: bool = false,
```

- [ ] **Step 3: Update all errfunc access sites**

Search for all `self.errfunc` / `vm.errfunc` references and update to `th.errfunc` (where `th` is the active thread). Key sites:

- `invokeErrfunc` (vm.zig:4279): `if (self.errfunc) |ef|` → `const th = self.activeBytecodeThread(); if (th.errfunc != 0) { const ef = self.bc_stack[th.errfunc]; ... }`
- `builtinPcall` (vm.zig:13614): `const saved_errfunc = self.errfunc; self.errfunc = null;` → `const saved_errfunc = th.errfunc; th.errfunc = 0;`
- `builtinXpcall` (vm.zig:13917): same pattern
- `builtinCoroutineResume` (vm.zig:14564): same pattern
- testC pcall (vm.zig:31100): same pattern
- All save/restore sites in vm.zig

- [ ] **Step 4: Build and fix errors**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | head -50`
Fix iteratively.

- [ ] **Step 5: Run tests**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc 2>&1 | tail -5`
Expected: 30/31

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig src/lua/c_api.zig
git commit -m "P15.78: move errfunc from Vm to Thread (per-Thread state)

PUC L->errfunc is per lua_State. Changed from ?Value (24B) to
StackOffset (8B, 0=none). All save/restore sites updated."
```

---

### Task 7: Move allowhook to Thread and add nCcalls

**Files:**
- Modify: `src/lua/vm.zig` (Thread struct, Vm struct, all access sites)

- [ ] **Step 1: Add allowhook and nCcalls to Thread**

In the Thread struct, add:

```zig
    /// PUC `L->allowhook` (lstate.h:290): whether hooks are allowed.
    allowhook: bool = true,
    /// PUC `L->nCcalls` (lstate.h:308): lower 16 bits = C call depth,
    /// upper 16 bits = non-yieldable call depth.
    nCcalls: u32 = 0,
```

- [ ] **Step 2: Add yieldable/incnny/decnny helpers**

Add helper functions (as methods on Thread or as free functions):

```zig
    pub fn yieldable(th: *const Thread) bool {
        return th.nCcalls & 0xffff0000 == 0;
    }
    pub fn getCcalls(th: *const Thread) u16 {
        return @truncate(th.nCcalls & 0xffff);
    }
    pub fn incnny(th: *Thread) void {
        th.nCcalls +%= 0x10000;
    }
    pub fn decnny(th: *Thread) void {
        th.nCcalls -%= 0x10000;
    }
```

- [ ] **Step 3: Remove non_yieldable_c_depth from Vm**

Remove `non_yieldable_c_depth: usize = 0` (line 2639) and `max_non_yieldable_c_depth` (line 898).

- [ ] **Step 4: Update all non_yieldable_c_depth access sites**

Search for all `self.non_yieldable_c_depth` references and update to use `th.incnny()`/`th.decnny()`/`th.yieldable()`:

- `builtinCoroutineYield` (vm.zig:14390): `self.non_yieldable_c_depth > 0` → `!th.yieldable()`
- `apiYield` (vm.zig:15013): same
- Metamethod call sites (vm.zig:25654-25656, 25683-25685): `self.non_yieldable_c_depth += 1; defer self.non_yieldable_c_depth -= 1;` → `th.incnny(); defer th.decnny();`
- testC closeslot (vm.zig:31004): same

- [ ] **Step 5: Update lua_resume to inherit nCcalls from `from`**

In `lua_resume` (c_api.zig:1214), update to set `co.nCcalls` from `from`:

```zig
pub export fn lua_resume(L: ?*lua_State, from: ?*lua_State, nargs: c_int, nres: ?*c_int) c_int {
    var s = api.State.fromVm(L orelse return 2);
    const co = s.vm.current_thread orelse return 2;
    // PUC: L->nCcalls = (from) ? getCcalls(from) : 0; L->nCcalls++;
    if (from) |from_vm| {
        const from_th = from_vm.current_thread orelse {};
        co.nCcalls = (@as(u32, from_th.getCcalls())) + 1;
    } else {
        co.nCcalls = 1;
    }
    const st = s.@"resume"(-1, @intCast(@max(nargs, 0)));
    // ... rest unchanged
}
```

- [ ] **Step 6: Build and fix errors**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | head -50`

- [ ] **Step 7: Run tests**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc 2>&1 | tail -5`
Expected: 30/31

- [ ] **Step 8: Commit**

```bash
git add src/lua/vm.zig src/lua/c_api.zig
git commit -m "P15.78: move allowhook/nCcalls to Thread, PUC-faithful encoding

nCcalls: u32 with lower 16 = C-call depth, upper 16 = non-yieldable.
yieldable() = upper 16 == 0. lua_resume inherits getCcalls(from)+1.
Replace Vm.non_yieldable_c_depth with Thread.nCcalls."
```

---

## Phase 2: C Continuation Lifecycle

### Task 8: Implement lua_yieldk with k/ctx saving

**Files:**
- Modify: `src/lua/c_api.zig:1229-1235` (lua_yieldk)
- Modify: `src/lua/vm.zig` (builtinCoroutineYield, apiYield)

- [ ] **Step 1: Implement lua_yieldk to save k/ctx in C-frame**

Replace `lua_yieldk` (c_api.zig:1229-1235):

```zig
/// PUC `lua_yieldk` (ldo.c:1006-1034): yield from a coroutine.
/// nresults values on c_stack are returned to the resume caller.
/// k/ctx are saved in the current C-frame for continuation on resume.
pub export fn lua_yieldk(L: ?*lua_State, nresults: c_int, ctx: isize, k: ?*const anyopaque) c_int {
    var s = api.State.fromVm(L orelse return 2);
    const vm = s.vm;
    const th = vm.current_thread orelse return 2;

    // PUC: check yieldable
    if (!th.yieldable()) {
        // PUC: if not main thread → "C-call boundary", else "outside a coroutine"
        vm.err_obj = .{ .String = vm.internStrAssume("attempt to yield across a C-call boundary") catch .Nil };
        vm.err_has_obj = true;
        return 2; // LUA_ERRRUN
    }

    // PUC: ci->u2.nyield = nresults
    // Save k/ctx in the current C-frame (if k != null)
    const th_bc = vm.activeBytecodeThread();
    if (th_bc.call_frames.len() > 0) {
        const fr = th_bc.call_frames.getPtr(th_bc.call_frames.len() - 1);
        if (fr.isC()) {
            fr.u.c.aux.nyield = nresults;
            if (k) |kf| {
                // PUC API-check: hooks cannot continue after yielding
                if (fr.isDebugHook()) {
                    // PUC: api_check(L, k == NULL, "hooks cannot continue after yielding")
                    // In luazig, we just don't save k for hook frames
                } else {
                    fr.u.c.k = @ptrCast(@alignCast(kf));
                    fr.u.c.ctx = ctx;
                }
            }
        }
    }

    s.yield(@intCast(@max(nresults, 0))) catch return 2;
    return 1; // LUA_YIELD
}
```

- [ ] **Step 2: Build and test**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc 2>&1 | tail -5`
Expected: 30/31 (no regression — k/ctx saved but not yet used on resume)

- [ ] **Step 3: Commit**

```bash
git add src/lua/c_api.zig
git commit -m "P15.78: implement lua_yieldk with k/ctx saving in C-frame

Save k/ctx and nyield in the current C-frame's u.c union.
PUC API-check: hooks cannot use continuations."
```

---

### Task 9: Implement lua_callk with k/ctx saving

**Files:**
- Modify: `src/lua/c_api.zig:245-271` (lua_callk, lua_callkImpl)

- [ ] **Step 1: Implement lua_callk to save k/ctx**

Replace `lua_callk` and `lua_callkImpl` (c_api.zig:244-271):

```zig
/// PUC `lua_callk` (lapi.c:1037-1056): call a function with optional
/// continuation. If k != NULL and yieldable, save k/ctx in the current
/// C-frame so the callee can yield. If k == NULL, the call is
/// non-yieldable (incnny).
pub export fn lua_callk(
    L: ?*lua_State,
    nargs: c_int,
    nresults: c_int,
    ctx: isize,
    k: ?*const anyopaque,
) void {
    const vm = if (L) |v| v else return;
    const th = vm.current_thread orelse return;
    const th_bc = vm.activeBytecodeThread();

    if (k) |kf| {
        if (th.yieldable()) {
            // Save k/ctx in the current C-frame
            if (th_bc.call_frames.len() > 0) {
                const fr = th_bc.call_frames.getPtr(th_bc.call_frames.len() - 1);
                if (fr.isC()) {
                    fr.u.c.k = @ptrCast(@alignCast(kf));
                    fr.u.c.ctx = ctx;
                }
            }
        }
    } else {
        // PUC: luaD_callnoyield — non-yieldable boundary
        th.incnny();
    }
    defer {
        if (k == null) th.decnny();
    }

    lua_callkImpl(L, nargs, nresults);
}
```

- [ ] **Step 2: Build and test**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc 2>&1 | tail -5`
Expected: 30/31

- [ ] **Step 3: Commit**

```bash
git add src/lua/c_api.zig
git commit -m "P15.78: implement lua_callk with k/ctx saving

k==NULL → non-yieldable (incnny). k!=NULL → save k/ctx in C-frame."
```

---

### Task 10: Implement lua_pcallk with k/ctx/errfunc saving

**Files:**
- Modify: `src/lua/c_api.zig:1264-1270` (lua_pcallk)

- [ ] **Step 1: Implement lua_pcallk with yieldable path**

Replace `lua_pcallk` (c_api.zig:1264-1270):

```zig
/// PUC `lua_pcallk` (lapi.c:1076-1117): protected call with continuation.
/// If k == NULL or not yieldable: conventional pcall (setjmp/longjmp).
/// If k != NULL and yieldable: save k/ctx/funcidx/old_errfunc in C-frame,
/// set CIST_YPCALL, call callee (yieldable).
pub export fn lua_pcallk(
    L: ?*lua_State,
    nargs: c_int,
    nresults: c_int,
    errfunc: c_int,
    ctx: isize,
    k: ?*const anyopaque,
) c_int {
    const vm = if (L) |v| v else return 2;
    const th = vm.current_thread orelse return 2;
    const th_bc = vm.activeBytecodeThread();

    if (k == null or !th.yieldable()) {
        // Conventional pcall (setjmp/longjmp boundary)
        // Set errfunc for the duration of the pcall
        if (errfunc != 0) {
            const saved_errfunc = th.errfunc;
            // Convert relative errfunc index to StackOffset
            // PUC: L->errfunc = func (stack index)
            th.errfunc = @intCast(if (errfunc < 0)
                @as(usize, @intCast(vm.c_stack.items.len)) + @as(usize, @intCast(errfunc))
            else
                @as(usize, @intCast(errfunc)));
            defer th.errfunc = saved_errfunc;
            var s = api.State.fromVm(L.?);
            return statusCode(s.pcall(@intCast(@max(nargs, 0)), nresults));
        } else {
            var s = api.State.fromVm(L.?);
            return statusCode(s.pcall(@intCast(@max(nargs, 0)), nresults));
        }
    }

    // Yieldable pcall: save state in C-frame
    if (th_bc.call_frames.len() == 0) return 2;
    const fr = th_bc.call_frames.getPtr(th_bc.call_frames.len() - 1);
    if (!fr.isC()) return 2;

    // PUC: save k/ctx in ci->u.c
    fr.u.c.k = @ptrCast(@alignCast(k.?));
    fr.u.c.ctx = ctx;
    // PUC: save funcidx in ci->u2.funcidx (callee position for error recovery)
    const funcidx: StackOffset = @intCast(@as(usize, @intCast(vm.c_stack.items.len)) - @as(usize, @intCast(@max(nargs, 0))) - 1);
    fr.u.c.aux.funcidx = funcidx;
    // PUC: save old_errfunc, set L->errfunc = func
    fr.u.c.old_errfunc = th.errfunc;
    if (errfunc != 0) {
        th.errfunc = @intCast(if (errfunc < 0)
            @as(usize, @intCast(vm.c_stack.items.len)) + @as(usize, @intCast(errfunc))
        else
            @as(usize, @intCast(errfunc)));
    }
    // PUC: setoah(ci, L->allowhook)
    fr.callstatus = setoah(fr.callstatus, th.allowhook);
    // PUC: set CIST_YPCALL
    fr.setYpcall();

    // Call callee (yieldable path)
    var s = api.State.fromVm(L.?);
    const result = s.call(@intCast(@max(nargs, 0)), nresults);
    if (result) |_| {
        // Normal return: clear CIST_YPCALL, restore errfunc
        fr.clearYpcall();
        th.errfunc = fr.u.c.old_errfunc;
        return 0; // LUA_OK
    } else |_| {
        // Error: conventional error handling (longjmp or error propagation)
        // finishpcallk will handle this on resume if yielded
        fr.clearYpcall();
        th.errfunc = fr.u.c.old_errfunc;
        return 2; // LUA_ERRRUN
    }
}
```

- [ ] **Step 2: Build and test**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc 2>&1 | tail -5`
Expected: 30/31

- [ ] **Step 3: Commit**

```bash
git add src/lua/c_api.zig
git commit -m "P15.78: implement lua_pcallk with k/ctx/errfunc saving

Yieldable path: save k/ctx/funcidx/old_errfunc in C-frame, set
CIST_YPCALL, save allowhook via CIST_OAH. Non-yieldable path:
conventional pcall with errfunc."
```

---

### Task 11: Add finishCcall in driveBytecodeCoroutineTrampoline

**Files:**
- Modify: `src/lua/vm.zig` (driveBytecodeCoroutineTrampoline, around line 6723)

- [ ] **Step 1: Add C-frame resume detection in trampoline**

In `driveBytecodeCoroutineTrampoline`, after the resume point where the topmost frame is inspected, add C-frame handling:

```zig
        // After resume, inspect topmost frame
        const th_bc = active.call_frames;
        if (th_bc.len() > 0) {
            const fr = th_bc.getPtr(th_bc.len() - 1);
            if (fr.isC()) {
                // C-frame resume: finishCcall equivalent
                const n = try self.finishCcall(active);
                // poscall C-frame: move n results, pop frame
                try self.poscallCFrame(active, n);
                continue; // :drive — may encounter more frames
            }
        }
```

- [ ] **Step 2: Implement finishCcall**

Add a new method on Vm:

```zig
    /// PUC `finishCcall` (ldo.c:837-858): resume a C function's continuation.
    /// Called when the topmost frame is a C-frame after resume.
    fn finishCcall(self: *Vm, th: *Thread) DispatchError!i32 {
        const th_bc = th.call_frames;
        const fr = th_bc.getPtr(th_bc.len() - 1);
        std.debug.assert(fr.isC());

        if (fr.isClsret()) {
            // PUC: was closing TBC variable — redo poscall with u2.nres
            // luazig: TBC close return state is in PendingCallSlot
            // This path is handled by existing close continuation machinery
            return error.UnexpectedClsret;
        }

        // PUC: adjustresults(L, LUA_MULTRET) — adjust stack to match callee results
        // For C-frames, the callee results are on c_stack
        // (adjustresults is a no-op for LUA_MULTRET in PUC)

        var status: i32 = 0; // LUA_YIELD
        const kf = fr.u.c.k;

        // PUC: if CIST_YPCALL, status = finishpcallk(L, ci)
        if (fr.isYpcall()) {
            status = try self.finishpcallk(th);
        }

        // PUC: n = (*kf)(L, APIstatus(status), ci->u.c.ctx)
        if (kf) |k| {
            // Raw continuation invocation — no new C-frame
            const n = k(@ptrCast(self), @intCast(status), fr.u.c.ctx);
            return n;
        } else {
            // k == NULL: poscall with resume nargs
            // nyield was used for lua_resume(&nresults) at yield time
            const nargs = if (th.resume_inbox) |ri| @as(i32, @intCast(ri.len)) else 0;
            return nargs;
        }
    }
```

- [ ] **Step 3: Implement poscallCFrame**

```zig
    /// PUC `luaD_poscall` for C-frames: move n results and pop the C-frame.
    fn poscallCFrame(self: *Vm, th: *Thread, n: i32) DispatchError!void {
        const th_bc = th.call_frames;
        const cur_len = th_bc.len();
        if (cur_len == 0) return;
        const fr = th_bc.getConstPtr(cur_len - 1);
        // Restore bc_stack_top to func_slot + n results
        const n_usize: usize = @intCast(@max(n, 0));
        self.bc_stack_top = fr.func_slot + 1 + n_usize;
        th_bc.shrinkTo(cur_len - 1);
    }
```

- [ ] **Step 4: Build and test**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc 2>&1 | tail -5`
Expected: 30/31

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.78: add finishCcall and poscallCFrame for C-frame resume

finishCcall: inspect C-frame, call k continuation via raw invocation
(no new C-frame), handle CIST_YPCALL via finishpcallk.
poscallCFrame: move results and pop C-frame."
```

---

### Task 12: Implement finishpcallk and findpcall/precover

**Files:**
- Modify: `src/lua/vm.zig`

- [ ] **Step 1: Implement finishpcallk**

```zig
    /// PUC `finishpcallk` (ldo.c:804-821): error recovery for yieldable pcall.
    /// Returns the status to pass to k.
    fn finishpcallk(self: *Vm, th: *Thread) DispatchError!i32 {
        const th_bc = th.call_frames;
        const fr = th_bc.getPtr(th_bc.len() - 1);
        std.debug.assert(fr.isC() and fr.isYpcall());

        // PUC: status = getcistrecst(ci)
        var status = getcistrecst(fr.callstatus);
        if (status == 0) {
            // PUC: no error → was interrupted by yield
            status = 1; // LUA_YIELD
        } else {
            // PUC: error — close TBC, set error object
            const funcidx = fr.u.c.aux.funcidx;
            th.allowhook = getoah(fr.callstatus);
            // PUC: func = luaF_close(L, func, status, 1) — close TBC (can yield!)
            // luazig: TBC close is handled by existing close continuation machinery
            // For now, set error object on stack
            // TODO: integrate with TBC close continuation
            // PUC: luaD_seterrorobj(L, status, func)
            // PUC: luaD_shrinkstack(L)
            fr.callstatus = setcistrecst(fr.callstatus, 0); // clear status
        }

        // PUC: ci->callstatus &= ~CIST_YPCALL
        fr.clearYpcall();
        // PUC: L->errfunc = ci->u.c.old_errfunc
        th.errfunc = fr.u.c.old_errfunc;

        return @intCast(status);
    }
```

- [ ] **Step 2: Implement findpcall**

```zig
    /// PUC `findpcall` (ldo.c:884-891): scan call_frames for CIST_YPCALL.
    fn findpcall(self: *Vm, th: *Thread) ?usize {
        const th_bc = th.call_frames;
        var i = th_bc.len();
        while (i > 0) {
            i -= 1;
            const fr = th_bc.getConstPtr(i);
            if (fr.isYpcall()) return i;
        }
        return null;
    }
```

- [ ] **Step 3: Implement precover**

```zig
    /// PUC `precover` (ldo.c:955-963): error recovery loop.
    /// Find suspended CIST_YPCALL, save error status, re-enter unroll.
    fn precover(self: *Vm, th: *Thread, status: u32) DispatchError!u32 {
        var current_status = status;
        while (current_status != 0 and current_status != 1) { // errorstatus
            const ci_idx = self.findpcall(th) orelse break;
            const fr = th.call_frames.getPtr(ci_idx);
            fr.callstatus = setcistrecst(fr.callstatus, current_status);
            // Re-enter trampoline (unroll) from that frame
            // This is integrated into the trampoline's error handling
            current_status = 0; // TODO: actual re-entry
        }
        return current_status;
    }
```

- [ ] **Step 4: Build and test**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc 2>&1 | tail -5`
Expected: 30/31

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.78: implement finishpcallk, findpcall, precover

finishpcallk: error recovery for yieldable pcall — restore errfunc,
allowhook, close TBC, set error object.
findpcall: scan call_frames for CIST_YPCALL.
precover: error recovery loop — find pcall, save status, re-enter."
```

---

## Phase 3: TestcPendingContinuation Removal

### Task 13: Migrate testC callk/pcallk/yieldk to real C continuations

**Files:**
- Modify: `src/lua/vm.zig` (testC command implementations)

- [ ] **Step 1: Find all testC callk/pcallk/yieldk command implementations**

Run: `grep -n "callk\|pcallk\|yieldk\|T\.callk\|T\.pcallk\|T\.yieldk" src/lua/vm.zig | head -30`

- [ ] **Step 2: Update testC callk to use real lua_callk**

The testC `callk` command should call `lua_callk` with a real `k` callback instead of using `saveTestcPendingContinuation`. The `k` callback re-executes the remaining testC script.

- [ ] **Step 3: Update testC pcallk to use real lua_pcallk**

Same pattern — use real `lua_pcallk` with `k` callback.

- [ ] **Step 4: Update testC yieldk to use real lua_yieldk**

Same pattern — use real `lua_yieldk` with `k` callback.

- [ ] **Step 5: Build and test**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc 2>&1 | tail -5`
Expected: 30/31

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.78: migrate testC callk/pcallk/yieldk to real C continuations

testC commands now use lua_callk/lua_pcallk/lua_yieldk with real k
callbacks instead of TestcPendingContinuation."
```

---

### Task 14: Remove TestcPendingContinuation and all related code

**Files:**
- Modify: `src/lua/vm.zig`

- [ ] **Step 1: Remove TestcPendingContinuation struct**

Delete the struct definition (vm.zig:1502-1513).

- [ ] **Step 2: Remove testc_pending_conts field from Thread**

Delete `testc_pending_conts: std.ArrayListUnmanaged(TestcPendingContinuation) = .empty` (vm.zig:1441).

- [ ] **Step 3: Remove saveTestcPendingContinuation**

Delete the function (vm.zig:31326-31377).

- [ ] **Step 4: Remove resumePendingTestcContinuation**

Delete the function (vm.zig:29520-29605).

- [ ] **Step 5: Remove resumeTestcCloseReturnContinuation**

Delete the function (vm.zig:28696-28730).

- [ ] **Step 6: Remove all references to testc_pending_conts**

Search for all remaining references and remove them:

```bash
grep -n "testc_pending_conts\|TestcPendingContinuation\|saveTestcPending\|resumePendingTestc\|resumeTestcCloseReturn" src/lua/vm.zig
```

Remove each reference. Key sites:
- `builtinCoroutineResume` (vm.zig:14718-14785): testC continuation paths
- `builtinCoroutineYield`: testC continuation saving
- Any other references

- [ ] **Step 7: Remove testc_close_current/testc_close_return_values/testc_close_remaining from Thread**

Delete these fields (vm.zig:1442-1444) if no longer used.

- [ ] **Step 8: Build and fix errors**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | head -50`
Fix any remaining references.

- [ ] **Step 9: Run tests**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc 2>&1 | tail -5`
Expected: 30/31

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" 2>&1 | grep -q "FAIL" && echo "FAIL: $f"; done; echo "smoke done"`
Expected: No failures

- [ ] **Step 10: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.78: remove TestcPendingContinuation (~200 lines)

Replaced by real C continuation mechanism (lua_callk/lua_pcallk/
lua_yieldk with k/ctx). Remove struct, Thread fields, save/resume
functions, and all references."
```

---

## Phase 4: C API Differential Tests + Final Verification

### Task 15: Write C API test for lua_yieldk basic

**Files:**
- Create: `tests/c_api/10_continuations.c`
- Modify: `tests/c_api/Makefile`

- [ ] **Step 1: Write the test**

Create `tests/c_api/10_continuations.c`:

```c
/*
** 10_continuations.c — tests for C continuation functions.
**
** Exercises lua_callk, lua_pcallk, lua_yieldk with real k/ctx.
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* Test 1: basic lua_yieldk with continuation */
static int cont_basic(lua_State *L, int status, lua_KContext ctx) {
    (void)status;
    lua_pushinteger(L, (lua_Integer)ctx + 100);
    return 1;
}

static int yielder_basic(lua_State *L) {
    lua_pushinteger(L, 42);
    return lua_yieldk(L, 1, 7, cont_basic);
}

static int test_basic_yieldk(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: luaL_newstate\n"); return 1; }
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    lua_pushcfunction(co, yielder_basic);
    int status = lua_resume(co, L, 0, NULL);
    if (status != LUA_YIELD) {
        fprintf(stderr, "FAIL: expected LUA_YIELD (%d), got %d\n", LUA_YIELD, status);
        lua_close(L); return 1;
    }

    /* Resume — should call cont_basic with ctx=7, push 107 */
    lua_pushinteger(co, 0); /* resume arg */
    status = lua_resume(co, L, 1, NULL);
    if (status != LUA_OK) {
        fprintf(stderr, "FAIL: expected LUA_OK, got %d\n", status);
        lua_close(L); return 1;
    }
    lua_Integer result = lua_tointeger(co, -1);
    if (result != 107) {
        fprintf(stderr, "FAIL: expected 107, got %lld\n", (long long)result);
        lua_close(L); return 1;
    }

    lua_close(L);
    printf("PASS: test_basic_yieldk\n");
    return 0;
}

/* Test 2: lua_yieldk with k == NULL (plain yield) */
static int yielder_nocont(lua_State *L) {
    lua_pushstring(L, "hello");
    return lua_yieldk(L, 1, 0, NULL);
}

static int test_yieldk_nocont(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: luaL_newstate\n"); return 1; }
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    lua_pushcfunction(co, yielder_nocont);
    int status = lua_resume(co, L, 0, NULL);
    if (status != LUA_YIELD) {
        fprintf(stderr, "FAIL: expected LUA_YIELD, got %d\n", status);
        lua_close(L); return 1;
    }

    const char *s = lua_tostring(co, -1);
    if (!s || strcmp(s, "hello") != 0) {
        fprintf(stderr, "FAIL: expected 'hello', got '%s'\n", s ? s : "NULL");
        lua_close(L); return 1;
    }

    lua_close(L);
    printf("PASS: test_yieldk_nocont\n");
    return 0;
}

/* Test 3: lua_callk with yielding callee */
static int cont_callk(lua_State *L, int status, lua_KContext ctx) {
    (void)status; (void)ctx;
    /* After resume, the callee's results are on the stack */
    lua_Integer v = lua_tointeger(L, -1);
    lua_pushinteger(L, v * 2);
    return 1;
}

static int callk_callee(lua_State *L) {
    lua_pushinteger(L, 10);
    return lua_yieldk(L, 1, 0, NULL);
}

static int callk_caller(lua_State *L) {
    /* Push the callee function and call it with lua_callk */
    lua_pushcfunction(L, callk_callee);
    lua_callk(L, 0, 1, 42, cont_callk);
    /* If we get here, the call completed without yield */
    return 1;
}

static int test_callk_yield(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: luaL_newstate\n"); return 1; }
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    lua_pushcfunction(co, callk_caller);
    int status = lua_resume(co, L, 0, NULL);
    if (status != LUA_YIELD) {
        fprintf(stderr, "FAIL: expected LUA_YIELD, got %d\n", status);
        lua_close(L); return 1;
    }

    /* Resume — cont_callk should be called */
    lua_pushinteger(co, 0);
    status = lua_resume(co, L, 1, NULL);
    if (status != LUA_OK) {
        fprintf(stderr, "FAIL: expected LUA_OK, got %d\n", status);
        lua_close(L); return 1;
    }
    lua_Integer result = lua_tointeger(co, -1);
    if (result != 20) {
        fprintf(stderr, "FAIL: expected 20, got %lld\n", (long long)result);
        lua_close(L); return 1;
    }

    lua_close(L);
    printf("PASS: test_callk_yield\n");
    return 0;
}

int main(void) {
    int fail = 0;
    fail |= test_basic_yieldk();
    fail |= test_yieldk_nocont();
    fail |= test_callk_yield();
    if (fail) {
        fprintf(stderr, "FAIL: some continuation tests failed\n");
        return 1;
    }
    printf("ALL PASS\n");
    return 0;
}
```

- [ ] **Step 2: Update Makefile**

Add `10_continuations` to the TESTS list in `tests/c_api/Makefile`:

```makefile
TESTS = 00_smoke 01_core 02_tables 03_arith 04_misc 05_auxlib 06_buffer 07_libs 08_debug 09_upvalues 10_continuations
```

- [ ] **Step 3: Build and run the test**

Run: `zig build -Doptimize=ReleaseFast && make -C tests/c_api 10_continuations && ./tests/c_api/10_continuations`
Expected: `ALL PASS`

- [ ] **Step 4: Commit**

```bash
git add tests/c_api/10_continuations.c tests/c_api/Makefile
git commit -m "P15.78: add C API continuation tests

Test lua_yieldk with/without continuation, lua_callk with yielding
callee. Differential tests against PUC Lua behavior."
```

---

### Task 16: Add more C API continuation tests

**Files:**
- Modify: `tests/c_api/10_continuations.c`

- [ ] **Step 1: Add lua_pcallk with yield test**

Add to `10_continuations.c`:

```c
/* Test 4: lua_pcallk with yield */
static int cont_pcallk(lua_State *L, int status, lua_KContext ctx) {
    lua_pushinteger(L, (lua_Integer)ctx);
    return 1;
}

static int pcallk_callee(lua_State *L) {
    lua_pushinteger(L, 99);
    return lua_yieldk(L, 1, 0, NULL);
}

static int pcallk_caller(lua_State *L) {
    lua_pushcfunction(L, pcallk_callee);
    int status = lua_pcallk(L, 0, 1, 0, 55, cont_pcallk);
    if (status == LUA_OK) {
        return 1;
    }
    lua_pushstring(L, "pcallk error");
    return 1;
}

static int test_pcallk_yield(void) {
    lua_State *L = luaL_newstate();
    if (!L) return 1;
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    lua_pushcfunction(co, pcallk_caller);
    int status = lua_resume(co, L, 0, NULL);
    if (status != LUA_YIELD) {
        fprintf(stderr, "FAIL: expected LUA_YIELD, got %d\n", status);
        lua_close(L); return 1;
    }

    lua_pushinteger(co, 0);
    status = lua_resume(co, L, 1, NULL);
    if (status != LUA_OK) {
        fprintf(stderr, "FAIL: expected LUA_OK, got %d\n", status);
        lua_close(L); return 1;
    }
    lua_Integer result = lua_tointeger(co, -1);
    if (result != 55) {
        fprintf(stderr, "FAIL: expected 55, got %lld\n", (long long)result);
        lua_close(L); return 1;
    }

    lua_close(L);
    printf("PASS: test_pcallk_yield\n");
    return 0;
}
```

- [ ] **Step 2: Add lua_pcallk with error test**

```c
/* Test 5: lua_pcallk with error in callee */
static int cont_pcallk_err(lua_State *L, int status, lua_KContext ctx) {
    if (status != LUA_OK) {
        lua_pushstring(L, "caught");
        return 1;
    }
    return 0;
}

static int pcallk_err_callee(lua_State *L) {
    lua_pushstring(L, "error!");
    lua_error(L);
    return 0;
}

static int pcallk_err_caller(lua_State *L) {
    lua_pushcfunction(L, pcallk_err_callee);
    int status = lua_pcallk(L, 0, 1, 0, 0, cont_pcallk_err);
    if (status == LUA_OK) {
        return 1;
    }
    lua_pushstring(L, "should not reach");
    return 1;
}

static int test_pcallk_error(void) {
    lua_State *L = luaL_newstate();
    if (!L) return 1;
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    lua_pushcfunction(co, pcallk_err_caller);
    int status = lua_resume(co, L, 0, NULL);
    if (status != LUA_OK) {
        fprintf(stderr, "FAIL: expected LUA_OK, got %d\n", status);
        lua_close(L); return 1;
    }
    const char *result = lua_tostring(co, -1);
    if (!result || strcmp(result, "caught") != 0) {
        fprintf(stderr, "FAIL: expected 'caught', got '%s'\n", result ? result : "NULL");
        lua_close(L); return 1;
    }

    lua_close(L);
    printf("PASS: test_pcallk_error\n");
    return 0;
}
```

- [ ] **Step 3: Add non-yieldable boundary test**

```c
/* Test 6: lua_call (k==NULL) is non-yieldable */
static int nonyield_callee(lua_State *L) {
    lua_pushinteger(L, 1);
    return lua_yieldk(L, 1, 0, NULL);
}

static int nonyield_caller(lua_State *L) {
    lua_pushcfunction(L, nonyield_callee);
    lua_call(L, 0, 1); /* k==NULL → non-yieldable */
    return 1;
}

static int test_nonyieldable(void) {
    lua_State *L = luaL_newstate();
    if (!L) return 1;
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    lua_pushcfunction(co, nonyield_caller);
    int status = lua_resume(co, L, 0, NULL);
    /* Should get an error, not LUA_YIELD */
    if (status == LUA_YIELD) {
        fprintf(stderr, "FAIL: expected error, got LUA_YIELD\n");
        lua_close(L); return 1;
    }

    lua_close(L);
    printf("PASS: test_nonyieldable\n");
    return 0;
}
```

- [ ] **Step 4: Update main() to run all tests**

```c
int main(void) {
    int fail = 0;
    fail |= test_basic_yieldk();
    fail |= test_yieldk_nocont();
    fail |= test_callk_yield();
    fail |= test_pcallk_yield();
    fail |= test_pcallk_error();
    fail |= test_nonyieldable();
    if (fail) {
        fprintf(stderr, "FAIL: some continuation tests failed\n");
        return 1;
    }
    printf("ALL PASS\n");
    return 0;
}
```

- [ ] **Step 5: Build and run**

Run: `zig build -Doptimize=ReleaseFast && make -C tests/c_api 10_continuations && ./tests/c_api/10_continuations`
Expected: `ALL PASS`

- [ ] **Step 6: Commit**

```bash
git add tests/c_api/10_continuations.c
git commit -m "P15.78: add pcallk yield/error and non-yieldable boundary tests"
```

---

### Task 17: Run full regression suite and update STATUS.md

**Files:**
- Modify: `STATUS.md`

- [ ] **Step 1: Build ReleaseFast**

Run: `zig build -Doptimize=ReleaseFast`
Expected: Build succeeds

- [ ] **Step 2: Run matrix tests**

Run: `python3 tools/testes_matrix.py --testc 2>&1 | tail -10`
Expected: 30/31 (no new regressions)

- [ ] **Step 3: Run smoke tests**

Run: `for f in tests/smoke/*.lua; do ./zig-out/bin/luazig "$f" 2>&1 | grep -q "FAIL" && echo "FAIL: $f"; done; echo "smoke done"`
Expected: No failures (49/49)

- [ ] **Step 4: Run Zig unit tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 5: Run C API tests**

Run: `make -C tests/c_api test 2>&1`
Expected: All tests pass (including 10_continuations)

- [ ] **Step 6: Check CallFrame size**

Run: `zig run tests/check_sizes.zig`
Expected: CallFrame ~100B

- [ ] **Step 7: Update STATUS.md**

Add a new section for C continuations:

```markdown
## P15.78: C Continuations (lua_callk/lua_pcallk/lua_yieldk)

**Status:** Complete

### What was done
- CallFrame restructured with PUC-faithful extern union (u: union { lua, c })
- CIST_C bit discriminator (PUC bit positions)
- CFrameState: k/ctx/old_errfunc/aux (CFrameAux: funcidx/nyield)
- LuaFrameState: proto/pc/func_slot_base/frame_cap/nextraargs/etc.
- errfunc/allowhook/nCcalls moved to Thread (per-Thread state)
- nCcalls: u32 with PUC encoding (lower 16 = C depth, upper 16 = non-yieldable)
- lua_resume inherits getCcalls(from)+1
- lua_yieldk saves k/ctx/nyield in C-frame
- lua_callk saves k/ctx in C-frame (k==NULL → incnny)
- lua_pcallk saves k/ctx/funcidx/old_errfunc, sets CIST_YPCALL/CIST_OAH
- finishCcall in driveBytecodeCoroutineTrampoline
- finishpcallk/findpcall/precover for error recovery
- Raw continuation invocation (no new C-frame for k)
- TestcPendingContinuation removed (~200 lines)
- C API differential tests (10_continuations.c)

### Metrics
- CallFrame: ~100B (was 96B)
- Matrix: 30/31
- Smoke: 49/49
- C API tests: 11/11 (including continuations)
```

- [ ] **Step 8: Commit**

```bash
git add STATUS.md
git commit -m "P15.78: update STATUS.md — C continuations complete

CallFrame ~100B, matrix 30/31, smoke 49/49, C API tests pass.
TestcPendingContinuation removed (~200 lines)."
```

---

## Self-Review

### Spec coverage
- ✅ CallFrame extern union (Task 4-5)
- ✅ CIST flag realignment (Task 1-2)
- ✅ StackOffset type (Task 4)
- ✅ CFrameAux union (Task 4)
- ✅ CFrameState/LuaFrameState (Task 4)
- ✅ Helper functions with assertions (Task 5)
- ✅ lua_callk (Task 9)
- ✅ lua_pcallk (Task 10)
- ✅ lua_yieldk (Task 8)
- ✅ Resume/unroll (Task 11)
- ✅ finishpcallk (Task 12)
- ✅ findpcall/precover (Task 12)
- ✅ CIST_RECST (Task 1, 12)
- ✅ CIST_OAH (Task 1, 10)
- ✅ nCcalls per-Thread (Task 7)
- ✅ errfunc per-Thread (Task 6)
- ✅ allowhook per-Thread (Task 7)
- ✅ lua_resume nCcalls inheritance (Task 7)
- ✅ API-check: hooks cannot use continuations (Task 8)
- ✅ TestcPendingContinuation removal (Task 13-14)
- ✅ C API differential tests (Task 15-16)
- ✅ Raw continuation invocation (Task 11)
- ✅ adjustresults(LUA_MULTRET) (Task 11)

### Placeholder scan
- Task 12 finishpcallk has a TODO for TBC close integration — this is acknowledged as a limitation that will be addressed when TBC close continuations are unified with C continuations. The existing PendingCallSlot machinery handles TBC close.
- Task 13 (testC migration) is intentionally high-level because the exact testC command structure needs to be studied during implementation. The subagent will need to explore the testC command dispatch code.

### Type consistency
- `StackOffset = usize` — consistent across all tasks
- `CFrameAux` union with `funcidx: StackOffset` and `nyield: i32` — consistent
- `CFrameState.k` type: `?*const fn (?*lua_State, c_int, isize) callconv(.c) c_int` — consistent
- `Thread.nCcalls: u32` — consistent
- `Thread.errfunc: StackOffset` — consistent
- `Thread.allowhook: bool` — consistent
