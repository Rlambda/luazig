# C API Drop-in Replacement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make luazig a true drop-in C library replacement for PUC Lua 5.5 — any C program that compiles against `lua.h`/`lauxlib.h`/`lualib.h` and links against `-llua` should work unchanged when linked against luazig.

**Architecture:** First consolidate the two parallel API layers (`api.zig` with its own `State.stack` and `c_api.zig` with `Vm.c_stack`) into a single implementation: `api.State` becomes a thin wrapper around `*Vm` using `vm.c_stack`, and `c_api.zig` becomes thin C-ABI shims that delegate to `api.State` methods. Then extend the unified API to the full PUC Lua 5.5 C API surface (~200 symbols). Add shared/static library targets to `build.zig`, ship complete `lua.h`/`lauxlib.h`/`lualib.h`/`luaconf.h` headers, and add C-link integration tests.

**Tech Stack:** Zig (export fn with C ABI), C (test programs compiled with gcc), PUC Lua 5.5 headers as reference (`lua-5.5.0/src/*.h`).

---

## Current State (as of 2026-08-06)

### Implemented (62 export fn in `src/lua/c_api.zig`)

**lua.h:** close, gettop, settop, rotate, copy, pop, pushnil, pushboolean, pushinteger, pushnumber, pushstring, pushvalue, pushcclosure, pushfstring, pushexternalstring, pushlightuserdata, pushcfunction, pushliteral, insert, remove, type, toboolean, tointegerx, tonumberx, getglobal, setglobal, next, pcallk, error, call, callk, createtable, setfield, getfield, rawset, rawget, pushlstring, getallocf, newuserdatauv, touserdata, topointer, setmetatable, getmetatable, setiuservalue, getiuservalue, register

**lauxlib.h:** newstate, checklstring, setfuncs, ref, unref, newmetatable, getmetatable, setmetatable, testudata, checkudata, checkinteger, optinteger, loadbufferx, loadfilex, newlib, checkversion, checkversion_

### Missing (full manifest below)

~65 `lua_*` functions, ~35 `luaL_*` functions, all 10 `luaopen_*` + `luaL_openselectedlibs`, entire `luaL_Buffer` subsystem, entire Debug C API (12 functions), `luaconf.h`, `lualib.h`, library build targets, C-link tests.

---

## Dependency Graph

```
Phase R1 (Refactor: api.State → *Vm + vm.c_stack)
  └── Phase R2 (Consolidate: port c_api.zig logic into api.State methods)
        └── Phase R3 (Simplify: reduce c_api.zig to thin C-ABI shims)
              │
              ▼
Phase 0 (Foundation: build.zig + luaconf.h + test harness)
  ├── Phase 1 (Core lua.h: state + stack + type predicates)
  │     ├── Phase 2 (Table operations)
  │     ├── Phase 3 (Arithmetic + coroutines + GC)
  │     └── Phase 4 (Load/dump/warnings/misc)
  ├── Phase 5 (lauxlib: argcheck/error/opt/check)
  │     └── Phase 6 (luaL_Buffer + Stream)
  ├── Phase 7 (lualib: luaopen_* + openlibs)
  ├── Phase 8 (Debug C API) — depends on Phase 1
  └── Phase 9 (Semantic fixes: cclosure upvalues + ref free-list) — independent
       └── Phase 10 (Integration testing) — depends on all above
```

**After R1-R3, every new C API function (Phases 0-10) follows this workflow:**
1. Implement the logic as an `api.State` method (Zig types, `ApiError!`)
2. Write a thin `c_api.zig` export shim (type conversion + delegation)

This ensures single-source-of-truth: one implementation, two facades.

---

## File Structure

| File | Responsibility | Status |
|------|---------------|--------|
| `src/lua/api.zig` | **Primary API layer**: `State` (thin `*Vm` wrapper) + all implementation logic | Refactor R1-R2, then extend |
| `src/lua/c_api.zig` | **C-ABI shims**: thin `pub export fn` wrappers delegating to `api.State` | Reduce R3, then extend |
| `src/lua/lauxlib.zig` | `luaL_Buffer` subsystem + `luaL_Stream` (new file, ~300 lines) | **Create** (Phase 6) |
| `src/lua/lualib.zig` | `luaopen_*` exports + `luaL_openselectedlibs` (new file, ~150 lines) | **Create** (Phase 7) |
| `src/lua/lua.h` | Complete PUC-compatible lua.h | Extend 203 → ~550 lines |
| `src/lua/lauxlib.h` | Complete PUC-compatible lauxlib.h | Extend 63 → ~270 lines |
| `src/lua/lualib.h` | Complete PUC-compatible lualib.h | **Create** (~65 lines) |
| `src/lua/luaconf.h` | Build configuration header | **Create** (~200 lines) |
| `build.zig` | Add `liblua` shared + static library targets | Modify |
| `tests/c_api/` | C programs linked against liblua | **Create** directory |

### Current Architecture Problem

`api.State` and `c_api.zig` are **parallel surfaces** with separate stacks:

```
api.State (owns Vm, has own stack)     c_api.zig (borrows *Vm, uses vm.c_stack)
    ├── stack: ArrayList                    ├── vm.c_stack: ArrayList
    ├── ~53 methods (Zig types)             ├── 62 export fn (C types)
    └── delegates to vm.apiCall() etc       └── delegates to vm.apiCall() etc
```

**Duplicate logic, divergent coverage.** Adding a function to one doesn't add it to the other. R1-R3 fix this.

### Target Architecture

```
api.State (thin wrapper around *Vm, uses vm.c_stack)
    ├── ~200 methods (Zig types, ApiError!)
    └── single implementation of all logic
          ↑
          │ delegates
          │
c_api.zig (C-ABI shims)
    └── ~200 export fn, each ~3 lines: type-convert → call api.State method
```

---

## Phase R1: Unify api.State on *Vm + vm.c_stack

**Goal:** Change `api.State` from a Vm-owning struct with its own `stack` to a thin wrapper around `*Vm` that uses `vm.c_stack`. This is the foundational refactoring that eliminates the dual-stack problem.

**Prerequisite:** None (first phase).

**Files:**
- Modify: `src/lua/api.zig` (State struct + all methods)
- Modify: `src/lua/testc.zig` (adapt to new State.init/deinit if signature changes)

### Current State (api.zig:44-63)

```zig
pub const State = struct {
    vm: vm_mod.Vm,              // OWNS Vm by value
    alloc: std.mem.Allocator,   // separate allocator reference
    stack: ArrayList(Value),    // OWN stack — separate from vm.c_stack
    thread_stacks: HashMap,     // per-thread stacks for Zig API
};
```

### Target State

```zig
pub const State = struct {
    vm: *vm_mod.Vm,             // BORROWS *Vm — same pointer c_api.zig uses
    // stack: removed — use self.vm.c_stack
    // alloc: removed — use self.vm.alloc
    thread_stacks: HashMap,     // kept for Zig API thread methods (xmove/resume/yield)
};
```

### Task R1.1: Change State struct fields

**Files:**
- Modify: `src/lua/api.zig:44-63`

- [ ] **Step 1: Change State fields**

Replace the struct definition:

```zig
pub const State = struct {
    vm: *vm_mod.Vm,
    thread_stacks: std.AutoHashMapUnmanaged(*vm_mod.Thread, std.ArrayListUnmanaged(vm_mod.Value)) = .empty,

    /// Create a new VM (heap-allocated) and wrap it.
    /// Caller must call `deinit` to free the VM.
    pub fn init(opts: Options) State {
        const alloc = opts.allocator;
        const ptr = alloc.create(vm_mod.Vm) catch @panic("api.State.init: out of memory");
        ptr.* = vm_mod.Vm.init(alloc, false);
        return .{ .vm = ptr };
    }

    /// Clean up the VM and free its heap allocation.
    pub fn deinit(self: *State) void {
        var it = self.thread_stacks.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.vm.alloc);
        self.thread_stacks.deinit(self.vm.alloc);
        const alloc = self.vm.alloc;
        self.vm.deinit();
        alloc.destroy(self.vm);
    }

    /// Wrap an existing `*Vm` without taking ownership.
    /// Used by `c_api.zig` to create a State from a `lua_State*`.
    pub fn fromVm(vm: *vm_mod.Vm) State {
        return .{ .vm = vm };
    }
};
```

- [ ] **Step 2: Verify compilation fails** (expected — all methods reference `self.stack` and `self.alloc`)

Run: `zig build 2>&1 | head -20`
Expected: Many "no field named 'stack'" / "no field named 'alloc'" errors in api.zig

### Task R1.2: Rewrite all State methods to use vm.c_stack + vm.alloc

**Files:**
- Modify: `src/lua/api.zig` (all ~53 methods)

This is a mechanical search-and-replace across api.zig:

| Old pattern | New pattern |
|---|---|
| `self.stack` | `self.vm.c_stack` |
| `self.alloc` | `self.vm.alloc` |
| `self.vm.apiCall(...)` | `self.vm.apiCall(...)` (unchanged) |
| `self.stack.items.len` | `self.vm.c_stack.items.len` |
| `try self.stack.append(self.alloc, X)` | `try self.vm.c_stack.append(self.vm.alloc, X)` |
| `try self.stack.appendSlice(self.alloc, X)` | `try self.vm.c_stack.appendSlice(self.vm.alloc, X)` |
| `self.stack.items[X]` | `self.vm.c_stack.items[X]` |
| `self.stack.items.len -= N` | `self.vm.c_stack.items.len -= N` |

- [ ] **Step 1: Replace all `self.stack` → `self.vm.c_stack` and `self.alloc` → `self.vm.alloc`**

Do this with a search-and-replace pass. Every method in State needs the same transformation.

Key methods to verify after replacement:
- `gettop`: `self.vm.c_stack.items.len`
- `settop`: operates on `self.vm.c_stack`
- `pushinteger`: `self.vm.c_stack.append(self.vm.alloc, .{ .Int = v })`
- `pushstring`: `self.vm.c_stack.append(self.vm.alloc, .{ .String = try self.vm.internStr(s) })`
- `pcall`: uses `self.vm.c_stack` for fn_idx, args, results
- `getglobal`: `self.vm.c_stack.append(self.vm.alloc, v)`
- etc.

- [ ] **Step 2: Fix `normalizeIndex` and `normalizeIndexConst`**

These currently take `self: *State` / `self: *const State` but don't use `self`. They can become standalone functions or stay as methods — but remove any `self.stack` references.

`normalizeIndex` already doesn't use self (`_ = self` at line 66). `normalizeIndexConst` also doesn't use self (`_: *const State` at line 567). These are fine — just verify they compile.

- [ ] **Step 3: Fix `valueAtConst`**

Currently:
```zig
fn valueAtConst(self: *const State, idx: i32) ?*const vm_mod.Value {
    const abs = self.normalizeIndexConst(idx, self.stack.items.len) orelse return null;
    return &self.stack.items[abs];
}
```

Change to:
```zig
fn valueAtConst(self: *const State, idx: i32) ?*const vm_mod.Value {
    const abs = self.normalizeIndexConst(idx, self.vm.c_stack.items.len) orelse return null;
    return &self.vm.c_stack.items[abs];
}
```

- [ ] **Step 4: Verify compilation succeeds**

Run: `zig build`
Expected: Clean build (runtime behavior may differ — verify in tests)

- [ ] **Step 5: Run api.zig unit tests**

Run: `zig build test 2>&1 | tail -20`
Expected: All api.* tests pass (they create State via `init`, push/pop on stack, pcall, etc.)

- [ ] **Step 6: Run testc.zig tests**

Run: `zig build test 2>&1 | tail -20`
Expected: testc tests pass (testc.zig uses api.State methods)

- [ ] **Step 7: Run c_api.zig tests**

Run: `zig build test 2>&1 | tail -20`
Expected: c_api tests pass (they use `luaL_newstate` → c_stack directly, unaffected by api.State changes)

- [ ] **Step 8: Run matrix regression**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc`
Expected: 30/31 (no new regressions)

- [ ] **Step 9: Run smoke regression**

Run: `python3 tools/smoke_compare.py`
Expected: 49/49 pass, 0 output_diff

- [ ] **Step 10: Commit**

```bash
git add src/lua/api.zig
git commit -m "refactor: unify api.State on *Vm + vm.c_stack

State now wraps *Vm (borrowed) instead of owning a Vm by value.
All methods use self.vm.c_stack instead of a separate self.stack.
This eliminates the dual-stack problem: api.State and c_api.zig
now share the same stack (vm.c_stack), preparing for consolidation.

testc.zig unchanged — State.init/deinit API is preserved."
```

---

## Phase R2: Consolidate implementation — port c_api.zig functions into api.State

**Goal:** Move all implementation logic from `c_api.zig` into `api.State` methods. After this phase, `api.State` is the single source of truth for all API logic, and `c_api.zig` still has its exports but they duplicate logic that also exists in `api.State`.

**Prerequisite:** R1 complete.

**Files:**
- Modify: `src/lua/api.zig` (add ~30 missing methods, rewrite ~5 indirect methods)
- Modify: `src/lua/c_api.zig` (helper functions become shared utilities)

### Gap Analysis

**Functions in c_api.zig but NOT in api.State:**

| c_api.zig function | api.State method to create | Notes |
|---|---|---|
| `lua_pop` | `pop(n)` already exists | Same logic — verify matches |
| `lua_pushlstring` | `pushlstring(s: []const u8)` | New — push arbitrary bytes |
| `lua_pushfstring` | `pushfstring(fmt: []const u8, ...)` | New — format string |
| `lua_pushcclosure` | `pushcclosure(fn, n)` | New — C closure |
| `lua_pushcfunction` | `pushcfunction(fn)` | New — C function |
| `lua_pushlightuserdata` | `pushlightuserdata(p)` | New |
| `lua_pushexternalstring` | `pushexternalstring(s, len, falloc, ud)` | New |
| `lua_error` | `raiseError()` | New — noreturn, C-specific (longjmp) |
| `lua_call`/`lua_callk` | `call(nargs, nresults)` | New — unprotected call |
| `lua_pcallk` | `pcall(nargs, nresults)` already exists | Verify matches c_api version |
| `lua_newuserdatauv` | `newuserdatauv(sz, nuvalue)` | New |
| `lua_touserdata` | `touserdata(idx)` | New |
| `lua_topointer` | `topointer(idx)` | New |
| `lua_setmetatable` | `setmetatable(idx)` already exists | **Rewrite** — currently uses callGlobal |
| `lua_getmetatable` | `getmetatable(idx)` already exists | **Rewrite** — currently uses callGlobal |
| `lua_setiuservalue` | `setiuservalue(idx, n)` | New |
| `lua_getiuservalue` | `getiuservalue(idx, n)` | New |
| `luaL_checklstring` | `checklstring(arg)` | New |
| `luaL_setfuncs` | `registerfuncs(reg, nup)` | New |
| `luaL_newlib` | `newlib(reg)` | New |
| `luaL_ref` | `ref(t)` | New |
| `luaL_unref` | `unref(t, ref)` | New |
| `luaL_newmetatable` | `newmetatable(tname)` | New |
| `luaL_getmetatable` | `getmetatable(tname)` — name conflict! | Rename to `getRegisteredMetatable` |
| `luaL_setmetatable` | `setregisteredmetatable(tname)` | New |
| `luaL_testudata` | `testudata(ud, tname)` | New |
| `luaL_checkudata` | `checkudata(ud, tname)` | New |
| `luaL_checkinteger` | `checkinteger(arg)` | New |
| `luaL_optinteger` | `optinteger(arg, def)` already exists | Verify |
| `luaL_checkversion` | `checkversion()` | New |
| `luaL_loadbufferx` | `loadbuffer` already exists | Verify matches |
| `luaL_loadfilex` | `loadfile` already exists | Verify matches |
| `lua_getallocf` | `getallocf()` | New |

**api.State methods that need rewriting** (currently use indirect Lua calls):

| Method | Current implementation | Direct implementation |
|---|---|---|
| `getmetatable(idx)` | Calls Lua's `getmetatable()` global via `callGlobal` | Direct: read `t.metatable` / `ud.metatable` (like c_api.zig:1074) |
| `setmetatable(idx)` | Calls Lua's `setmetatable()` global via `callGlobal` | Direct: set `t.metatable` / `ud.metatable` (like c_api.zig:1041) |
| `getupvalue(func_idx, n)` | Calls Lua's `debug.getupvalue` via `requireDebugModule` | Direct: read Closure upvalues (Phase 8 will add proper impl) |
| `setupvalue(func_idx, n)` | Calls Lua's `debug.setupvalue` via `requireDebugModule` | Direct: write Closure upvalues (Phase 8 will add proper impl) |
| `getregistry()` | Calls Lua's `debug.getregistry` via `requireDebugModule` | Direct: `vm.apiEnsureRegistry()` |

### Task R2.1: Move shared helpers from c_api.zig to api.zig

**Files:**
- Modify: `src/lua/api.zig` (add helpers)
- Modify: `src/lua/c_api.zig` (import from api.zig instead of defining locally)

- [ ] **Step 1: Move `normalizeIndex` into api.zig as a standalone function**

c_api.zig currently has its own `normalizeIndex` (line 74) and api.zig has `normalizeIndexConst` (line 567). These are identical logic. Consolidate into one:

```zig
// In api.zig — shared index normalization
pub fn normalizeIndex(idx: i32, top: usize) ?usize {
    if (idx == 0) return null;
    if (idx > 0) {
        const abs: usize = @intCast(idx - 1);
        return if (abs < top) abs else null;
    }
    const r: usize = @intCast(-idx);
    if (r == 0 or r > top) return null;
    return top - r;
}
```

- [ ] **Step 2: Move `typeCode`, `statusCode`, `mapCompileError` into api.zig**

These are used by c_api.zig but belong with the API types. Add them as public functions in api.zig:

```zig
pub fn typeCode(ty: Type) c_int { ... }
pub fn statusCode(st: Status) c_int { ... }
pub fn mapCompileError(err: anyerror) Status { ... }
```

- [ ] **Step 3: Update c_api.zig to import these from api.zig**

Replace local definitions with `const normalizeIndex = api.normalizeIndex;` etc.

- [ ] **Step 4: Build and verify**

Run: `zig build && zig build test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add src/lua/api.zig src/lua/c_api.zig
git commit -m "refactor: consolidate shared helpers (normalizeIndex, typeCode, statusCode) into api.zig"
```

### Task R2.2: Rewrite indirect api.State methods to use direct Vm access

**Files:**
- Modify: `src/lua/api.zig` (5 methods)

- [ ] **Step 1: Rewrite `getmetatable(idx)`**

Replace the `callGlobal("getmetatable", ...)` implementation with direct access (matching c_api.zig:1074-1088):

```zig
pub fn getmetatable(self: *State, idx: i32) ApiError!bool {
    const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
    const mt: ?*vm_mod.Table = switch (self.vm.c_stack.items[abs]) {
        .Table => |t| t.metatable,
        .Userdata => |ud| ud.metatable,
        else => null,
    };
    if (mt) |m| {
        try self.vm.c_stack.append(self.vm.alloc, .{ .Table = m });
        return true;
    }
    return false;
}
```

- [ ] **Step 2: Rewrite `setmetatable(idx)`**

Replace `callGlobal("setmetatable", ...)` with direct access (matching c_api.zig:1041-1070):

```zig
pub fn setmetatable(self: *State, idx: i32) ApiError!void {
    if (self.vm.c_stack.items.len < 1) return error.InvalidState;
    const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
    const mt_val = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
    self.vm.c_stack.items.len -= 1;
    const mt = if (mt_val == .Table) mt_val.Table else null;
    switch (self.vm.c_stack.items[abs]) {
        .Table => |t| {
            t.metatable = mt;
            if (mt) |m| if (self.vm.metamethodValue(.{ .Table = m }, "__gc") != null) {
                self.vm.registerFinalizable(.{ .table = t }) catch {};
            };
        },
        .Userdata => |ud| {
            ud.metatable = mt;
            if (mt) |m| if (self.vm.metamethodValue(.{ .Table = m }, "__gc") != null) {
                self.vm.registerFinalizable(.{ .userdata = ud }) catch {};
            };
        },
        else => {},
    }
}
```

- [ ] **Step 3: Rewrite `getregistry()`**

Replace `requireDebugModule` + `callGlobal("debug.getregistry")` with:

```zig
pub fn getregistry(self: *State) ApiError!void {
    const reg = self.vm.apiEnsureRegistry() catch return error.Runtime;
    try self.vm.c_stack.append(self.vm.alloc, .{ .Table = reg });
}
```

- [ ] **Step 4: Leave `getupvalue`/`setupvalue` as-is for now**

These will be properly implemented in Phase 8 (Debug C API) with direct Closure access. For now, keep the `requireDebugModule` approach — it works, just slower. Add a TODO comment.

- [ ] **Step 5: Build and run all tests**

Run: `zig build && zig build test`
Expected: All tests pass (including the metatable test at api.zig:921)

- [ ] **Step 6: Commit**

```bash
git add src/lua/api.zig
git commit -m "refactor: rewrite getmetatable/setmetatable/getregistry to use direct Vm access

Replace indirect Lua function calls (callGlobal/requireDebugModule)
with direct struct field access, matching c_api.zig implementation."
```

### Task R2.3: Add missing api.State methods (port from c_api.zig)

**Files:**
- Modify: `src/lua/api.zig` (add ~25 new methods)

- [ ] **Step 1: Add push methods**

```zig
pub fn pushlstring(self: *State, s: []const u8) ApiError!void {
    const ls = try self.vm.internStr(s);
    try self.vm.c_stack.append(self.vm.alloc, .{ .String = ls });
}

pub fn pushlightuserdata(self: *State, p: ?*anyopaque) ApiError!void {
    if (p) |ptr| {
        try self.vm.c_stack.append(self.vm.alloc, .{ .LightUserdata = ptr });
    } else {
        try self.vm.c_stack.append(self.vm.alloc, .Nil);
    }
}

pub fn pushcclosure(self: *State, fn_: ?*const fn(?*anyopaque) callconv(.c) c_int, n: usize) ApiError!void {
    // Port from c_api.zig lua_pushcclosure (line 962)
    // For now n must be 0 (upvalues not yet supported — Phase 9)
    if (n != 0) return error.InvalidState;
    const cl = try self.vm.alloc.create(vm_mod.Closure);
    cl.* = .{ .upvalues = &.{}, .c_func = fn_ };
    try self.vm.gcRegisterClosure(cl);
    try self.vm.c_stack.append(self.vm.alloc, .{ .Closure = cl });
}

pub fn pushcfunction(self: *State, fn_: ?*const fn(?*anyopaque) callconv(.c) c_int) ApiError!void {
    try self.pushcclosure(fn_, 0);
}
```

- [ ] **Step 2: Add userdata methods**

```zig
pub fn newuserdatauv(self: *State, sz: usize, nuvalue: usize) ApiError!?*anyopaque {
    const ud = try self.vm.allocUserdata(sz, nuvalue);
    try self.vm.c_stack.append(self.vm.alloc, .{ .Userdata = ud });
    return if (ud.payload.len > 0) @ptrCast(ud.payload.ptr) else @ptrCast(ud);
}

pub fn touserdata(self: *State, idx: i32) ?*anyopaque {
    const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return null;
    return switch (self.vm.c_stack.items[abs]) {
        .Userdata => |ud| if (ud.payload.len > 0) @ptrCast(ud.payload.ptr) else @ptrCast(ud),
        .LightUserdata => |p| p,
        else => null,
    };
}

pub fn topointer(self: *State, idx: i32) ?*anyopaque {
    // Port from c_api.zig lua_topointer (line 1015)
    ...
}

pub fn setiuservalue(self: *State, idx: i32, n: usize) ApiError!bool {
    // Port from c_api.zig lua_setiuservalue (line 1092)
    ...
}

pub fn getiuservalue(self: *State, idx: i32, n: usize) ApiError!Type {
    // Port from c_api.zig lua_getiuservalue (line 1113)
    ...
}
```

- [ ] **Step 3: Add lauxlib methods**

```zig
pub fn checklstring(self: *State, arg: i32) []const u8 {
    // Port from c_api.zig luaL_checklstring (line 692)
    // Returns "" on type mismatch (full error handling in Phase 5)
    ...
}

pub fn ref(self: *State, t: i32) i32 {
    // Port from c_api.zig luaL_ref (line 924)
    ...
}

pub fn unref(self: *State, t: i32, ref: i32) void {
    // Port from c_api.zig luaL_unref (line 1207)
    ...
}

pub fn newmetatable(self: *State, tname: []const u8) ApiError!bool {
    // Port from c_api.zig luaL_newmetatable (line 1140)
    ...
}

pub fn getRegisteredMetatable(self: *State, tname: []const u8) ApiError!void {
    // Port from c_api.zig luaL_getmetatable (line 1161)
    // Named differently to avoid clash with getmetatable(idx)
    ...
}

pub fn testudata(self: *State, ud: i32, tname: []const u8) ?*anyopaque {
    // Port from c_api.zig luaL_testudata (line 1184)
    ...
}

pub fn checkinteger(self: *State, arg: i32) i64 {
    // Port from c_api.zig luaL_checkinteger (line 1226)
    ...
}

pub fn checkversion(self: *State) void {
    // Port from c_api.zig luaL_checkversion (line 785)
    ...
}
```

- [ ] **Step 4: Add call/error methods**

```zig
pub fn call(self: *State, nargs: usize, nresults: i32) ApiError!void {
    // Unprotected call — port from c_api.zig lua_callkImpl (line 399)
    // On error, propagates through the active C-function boundary
    ...
}
```

Note: `raiseError()` (lua_error) is C-specific (requires longjmp). It stays in c_api.zig as a C-only function — api.State users use Zig error unions instead.

- [ ] **Step 5: Build and run all tests**

Run: `zig build && zig build test`
Expected: All existing tests pass. New methods compile but may not have tests yet.

- [ ] **Step 6: Run regression tests**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc && python3 tools/smoke_compare.py`
Expected: 30/31 matrix, 49/49 smoke

- [ ] **Step 7: Commit**

```bash
git add src/lua/api.zig
git commit -m "refactor: port c_api.zig implementation logic into api.State methods

~25 new methods added (push*, userdata*, luaL_*).
Indirect methods (getmetatable/setmetatable/getregistry) rewritten
to use direct Vm field access.
api.State is now the single source of truth for API logic."
```

---

## Phase R3: Reduce c_api.zig to thin C-ABI shims

**Goal:** Rewrite every `pub export fn` in `c_api.zig` to be a thin wrapper that creates an `api.State` from the `?*lua_State` and delegates to the corresponding `api.State` method.

**Prerequisite:** R2 complete.

**Files:**
- Modify: `src/lua/c_api.zig` (rewrite all 62 export functions as shims)

### Task R3.1: Rewrite c_api.zig exports as delegation shims

**Files:**
- Modify: `src/lua/c_api.zig`

- [ ] **Step 1: Define the delegation pattern**

Every export function follows the same shape:

```zig
pub export fn lua_pushinteger(L: ?*lua_State, v: i64) void {
    var s = api.State.fromVm(L orelse return);
    s.pushinteger(v) catch {};
}

pub export fn lua_gettop(L: ?*lua_State) c_int {
    const vm = L orelse return 0;
    var s = api.State.fromVm(vm);
    return @intCast(s.gettop());
}

pub export fn lua_tointegerx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) i64 {
    var s = api.State.fromVm(L orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    });
    // api.State.tointeger returns ?i64 — map to C API contract
    if (s.tointeger(idx)) |v| {
        if (isnum) |p| p.* = 1;
        return v;
    }
    if (isnum) |p| p.* = 0;
    return 0;
}
```

- [ ] **Step 2: Rewrite simple stack functions**

Functions that are pure type conversion (push*, pop, gettop, settop, rotate, copy, insert, remove, type, toboolean):

```zig
pub export fn lua_pushnil(L: ?*lua_State) void {
    var s = api.State.fromVm(L orelse return);
    s.pushnil() catch {};
}

pub export fn lua_pushboolean(L: ?*lua_State, b: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.pushboolean(b != 0) catch {};
}

pub export fn lua_type(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromVm(L orelse return -1);
    return if (s.typeOf(idx)) |t| api.typeCode(t) else -1;
}
```

- [ ] **Step 3: Rewrite string functions**

```zig
pub export fn lua_pushstring(L: ?*lua_State, s: [*:0]const u8) void {
    var st = api.State.fromVm(L orelse return);
    st.pushstring(std.mem.span(s)) catch {};
}

pub export fn lua_pushlstring(L: ?*lua_State, s: [*]const u8, len: usize) void {
    var st = api.State.fromVm(L orelse return);
    st.pushlstring(s[0..len]) catch {};
}
```

- [ ] **Step 4: Rewrite table functions**

```zig
pub export fn lua_createtable(L: ?*lua_State, narr: c_int, nrec: c_int) void {
    _ = narr; _ = nrec;
    var s = api.State.fromVm(L orelse return);
    s.newtable() catch {};
}

pub export fn lua_setfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void {
    var s = api.State.fromVm(L orelse return);
    s.setfield(idx, std.mem.span(k)) catch {};
}

pub export fn lua_getfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) c_int {
    var s = api.State.fromVm(L orelse return -1);
    return if (s.getfield(idx, std.mem.span(k))) |t| api.typeCode(t) else 0;
}
```

- [ ] **Step 5: Rewrite call/pcall functions**

```zig
pub export fn lua_pcallk(L: ?*lua_State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?*const anyopaque) c_int {
    _ = errfunc; _ = ctx; _ = k;
    var s = api.State.fromVm(L orelse return 2);
    const status = s.pcall(@intCast(nargs), nresults);
    return api.statusCode(status);
}
```

- [ ] **Step 6: Rewrite userdata functions**

```zig
pub export fn lua_newuserdatauv(L: ?*lua_State, sz: usize, nuvalue: c_int) ?*anyopaque {
    var s = api.State.fromVm(L orelse return null);
    return s.newuserdatauv(sz, @intCast(@max(nuvalue, 0))) catch null;
}

pub export fn lua_touserdata(L: ?*lua_State, idx: c_int) ?*anyopaque {
    var s = api.State.fromVm(L orelse return null);
    return s.touserdata(idx);
}
```

- [ ] **Step 7: Rewrite metatable functions**

```zig
pub export fn lua_setmetatable(L: ?*lua_State, objindex: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    s.setmetatable(objindex) catch return 0;
    return 1;
}

pub export fn lua_getmetatable(L: ?*lua_State, objindex: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.getmetatable(objindex) catch false) 1 else 0;
}
```

- [ ] **Step 8: Rewrite lauxlib functions**

```zig
pub export fn luaL_ref(L: ?*lua_State, t: c_int) c_int {
    var s = api.State.fromVm(L orelse return LUA_NOREF);
    return s.ref(t);
}

pub export fn luaL_unref(L: ?*lua_State, t: c_int, ref: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.unref(t, ref);
}

pub export fn luaL_newmetatable(L: ?*lua_State, tname: [*:0]const u8) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.newmetatable(std.mem.span(tname)) catch false) 1 else 0;
}
```

- [ ] **Step 9: Keep C-specific functions as-is**

These functions are C-ABI-specific and cannot be delegated to api.State:
- `luaL_newstate` — allocates Vm on heap (delegates to `Vm.init` + `c_allocator.create`)
- `lua_close` — frees Vm (delegates to `vm.deinit` + `c_allocator.destroy`)
- `lua_error` — noreturn longjmp boundary (C-specific control flow)
- `lua_callkImpl` — unprotected call with longjmp error propagation
- `cApiAllocWrapper` — C allocator callback
- `lua_pushfstring` — C vararg formatting (stays in c_api.zig, delegates to vm.internStr)
- `luaL_loadbufferx` / `luaL_loadfilex` — compilation (delegates to vm.compileChunkValue, already shared)

Leave these unchanged — they are genuinely C-specific.

- [ ] **Step 10: Build and run all tests**

Run: `zig build && zig build test`
Expected: All tests pass (c_api.zig embedded tests at line 1258+, api.zig tests, testc.zig tests)

- [ ] **Step 11: Run full regression**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc && python3 tools/smoke_compare.py`
Expected: 30/31 matrix, 49/49 smoke, 0 output_diff

- [ ] **Step 12: Verify c_api.zig line count dropped significantly**

Run: `wc -l src/lua/c_api.zig`
Expected: ~600-700 lines (down from 1555), mostly tests + C-specific functions + thin shims

- [ ] **Step 13: Commit**

```bash
git add src/lua/c_api.zig
git commit -m "refactor: reduce c_api.zig to thin C-ABI shims over api.State

All 62 export functions now delegate to api.State methods.
C-specific machinery (luaL_newstate, lua_close, lua_error/longjmp,
lua_pushfstring vararg, cApiAllocWrapper) remains in c_api.zig.

c_api.zig: 1555 → ~650 lines.
api.State is now the single source of truth for all API logic."
```

- [ ] **Step 14: Update STATUS.md**

Mark the api.zig consolidation as done, note the new architecture:
- api.State = primary implementation (thin *Vm wrapper, vm.c_stack)
- c_api.zig = thin C-ABI shims

```markdown
- [x] ~~Развивать Zig embedding API~~ — api.State is now the primary implementation
  layer (thin *Vm wrapper using vm.c_stack). c_api.zig is thin C-ABI shims.
```

---


## Phase 0: Foundation — Build System + Headers + Test Harness

**Goal:** Produce `liblua.so` / `liblua.a` that a C program can link against, with complete headers, and a working C-link test that does `luaL_newstate()` → `luaL_dostring()` → `lua_close()`.

**Files:**
- Modify: `build.zig` (add library targets)
- Create: `src/lua/luaconf.h` (complete config header)
- Modify: `src/lua/lua.h` (add missing constants/macros, no new function decls needed yet)
- Create: `src/lua/lualib.h` (lualib header, even if exports are stubs initially)
- Create: `tests/c_api/Makefile` (compile + link C tests)
- Create: `tests/c_api/00_smoke.c` (minimal C-link test)

### Task 0.1: Add shared and static library targets to build.zig

**Files:**
- Modify: `build.zig`

- [ ] **Step 1: Add library artifacts after the executable definitions (after line 56)**

```zig
    // --- Library targets: liblua.so / liblua.a for C drop-in linking ---
    //
    // Produces a shared library that C programs can link against:
    //   gcc app.c -Isrc/lua -Lzig-out/lib -llua -o app
    //
    // The library includes all `pub export fn` symbols from c_api.zig.
    // Linking libc is required for the setjmp/longjmp pcall boundary.
    const liblua = b.addSharedLibrary(.{
        .name = "lua",
        .root_module = lua_mod,
    });
    liblua.root_module.link_libc = true;
    liblua.linker_allow_shlib_undefined = true;
    b.installArtifact(liblua);

    // Static library for static linking scenarios.
    const liblua_static = b.addStaticLibrary(.{
        .name = "lua",
        .root_module = lua_mod,
    });
    liblua_static.root_module.link_libc = true;
    b.installArtifact(liblua_static);
```

- [ ] **Step 2: Build and verify the .so is produced**

Run: `zig build -Doptimize=ReleaseFast`
Expected: `zig-out/lib/liblua.so` and `zig-out/lib/liblua.a` exist

- [ ] **Step 3: Verify exported symbols**

Run: `nm -D --defined-only zig-out/lib/liblua.so | grep -c " T lua"`
Expected: At least 40 `lua_*` / `luaL_*` symbols present

- [ ] **Step 4: Commit**

```bash
git add build.zig
git commit -m "build: add liblua.so and liblua.a library targets for C drop-in linking"
```

### Task 0.2: Create luaconf.h

**Files:**
- Create: `src/lua/luaconf.h`
- Reference: `lua-5.5.0/src/luaconf.h` (745 lines — copy the subset luazig needs)

- [ ] **Step 1: Create `src/lua/luaconf.h` with essential defines**

The file must contain at minimum:
- `LUAI_MAXSTACK` (already 1000000 in lua.h — move here)
- `LUA_ID_SIZE` (default 60)
- `LUAL_BUFFERSIZE` (default 8192 — computed as `((int)(16 * sizeof(void*) * sizeof(lua_Integer)))`)
- `LUA_QL(x)` / `LUA_QS` macros (used by error messages)
- `LUAI_UACINT` / `LUAI_UACNUMBER` (union-aligned types for vararg)
- `lua_number2str` / `lua_integer2str` / `lua_str2number` macros
- `l_mathop` / `l_noret` / `luai_apicheck` (luazig: define `luai_apicheck` as no-op)
- `LUA_USE_LONGJMP` or equivalent (luazig uses setjmp/longjmp)
- `LUAI_MAXCCALLS` (default 200)
- `LUAL_PATH_DEFAULT` / `LUAL_CPATH_DEFAULT` (copy from PUC for Linux)
- `LUA_DIRSEP` / `LUA_PATH_SEP` / `LUA_PATH_MARK` / `LUA_EXEC_DIR`
- `LUA_VDIR` ("lua-5.5")
- `LUA_LOADLIB`, `LUA_DL_DLL` defines (Linux: `LUA_USE_DLOPEN`)

Copy from `lua-5.5.0/src/luaconf.h` lines 43-745, adapting:
- Remove `#if !defined(LUA_USE_C89)` conditional blocks — always use the C99 path
- Set platform defaults for Linux
- Remove `lua_tonumber_` / float-precision toggles (luazig is always double)

- [ ] **Step 2: Add `#include "luaconf.h"` to lua.h after line 19**

```c
#include "luaconf.h"
```

- [ ] **Step 3: Verify headers parse**

Run: `gcc -fsyntax-only -Isrc/lua src/lua/lua.h`
Expected: no errors

- [ ] **Step 4: Commit**

```bash
git add src/lua/luaconf.h src/lua/lua.h
git commit -m "feat: add luaconf.h with PUC-compatible build configuration"
```

### Task 0.3: Create lualib.h (stub luaopen_* declarations)

**Files:**
- Create: `src/lua/lualib.h`
- Reference: `lua-5.5.0/src/lualib.h` (65 lines — copy verbatim)

- [ ] **Step 1: Create `src/lua/lualib.h`**

Copy PUC's `lualib.h` verbatim. All `luaopen_*` functions are declared but not yet exported (implemented in Phase 7). The `LUALIB_API` prefix is already `extern` in our lua.h.

```c
#ifndef lualib_h
#define lualib_h

#include "lua.h"

/* ... copy all LUAMOD_API declarations and LUA_*LIBNAME macros from PUC ... */

#endif
```

- [ ] **Step 2: Verify headers parse together**

Run: `gcc -fsyntax-only -Isrc/lua src/lua/lualib.h`
Expected: no errors

- [ ] **Step 3: Commit**

```bash
git add src/lua/lualib.h
git commit -m "feat: add lualib.h with PUC-compatible standard library declarations"
```

### Task 0.4: Create C-link test harness

**Files:**
- Create: `tests/c_api/Makefile`
- Create: `tests/c_api/00_smoke.c`

- [ ] **Step 1: Write `tests/c_api/00_smoke.c`**

```c
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* Minimal C-link test: create state, run a string, check result. */
int main(void) {
    lua_State *L = luaL_newstate();
    if (L == NULL) {
        fprintf(stderr, "FAIL: luaL_newstate returned NULL\n");
        return 1;
    }

    /* luaL_dostring is a macro: (luaL_loadstring(L, str) || lua_pcall(L, 0, -1, 0)) */
    /* luaL_loadstring is not yet exported — use luaL_loadbufferx for now */
    const char *code = "return 1 + 2";
    if (luaL_loadbufferx(L, code, strlen(code), "test", NULL) != LUA_OK) {
        fprintf(stderr, "FAIL: load error: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
        fprintf(stderr, "FAIL: pcall error: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    lua_Integer result = lua_tointeger(L, -1);
    if (result != 3) {
        fprintf(stderr, "FAIL: expected 3, got %lld\n", (long long)result);
        lua_close(L);
        return 1;
    }

    lua_close(L);
    printf("PASS: 00_smoke\n");
    return 0;
}
```

- [ ] **Step 2: Write `tests/c_api/Makefile`**

```makefile
# C API test harness — compiles C programs against luazig's liblua.so
LUA_DIR = ../../src/lua
LIB_DIR = ../../zig-out/lib

CC = gcc
CFLAGS = -I$(LUA_DIR) -Wall -Wextra
LDFLAGS = -L$(LIB_DIR) -llua -lm -ldl -Wl,-rpath,$(LIB_DIR)

TESTS = 00_smoke

all: $(TESTS)

%: %.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

test: $(TESTS)
	@for t in $(TESTS); do ./$$t; done

clean:
	rm -f $(TESTS)

.PHONY: all test clean
```

- [ ] **Step 3: Build luazig ReleaseFast**

Run: `zig build -Doptimize=ReleaseFast`
Expected: `zig-out/lib/liblua.so` and `zig-out/lib/liblua.a` exist

- [ ] **Step 4: Compile and run the test**

Run:
```bash
cd tests/c_api && make test
```
Expected: `PASS: 00_smoke`

- [ ] **Step 5: Commit**

```bash
git add tests/c_api/
git commit -m "test: add C-link smoke test proving liblua.so is linkable from C"
```

### Task 0.5: Extend lua.h with missing constants and macros

**Files:**
- Modify: `src/lua/lua.h`

- [ ] **Step 1: Add missing type codes, pseudo-indices, and constants**

Add after the existing type codes section:

```c
/* Pseudo-index for upvalues (lua.h:52) */
#define LUA_UPVALINDEX(idx) (LUA_REGISTRYINDEX - (idx))

/* Type count (lua.h:85) */
#define LUA_NUMTYPES 9

/* Arithmetic operators (lua.h:152) */
#define LUA_OPADD 0
#define LUA_OPSUB 1
#define LUA_OPMUL 2
#define LUA_OPMOD 3
#define LUA_OPPOW 4
#define LUA_OPDIV 5
#define LUA_OPIDIV 6
#define LUA_OPBAND 7
#define LUA_OPBOR 8
#define LUA_OPBXOR 9
#define LUA_OPSHL 10
#define LUA_OPSHR 11
#define LUA_OPUNM 12
#define LUA_OPBNOT 13

/* Comparison (lua.h:162) */
#define LUA_OPEQ 0
#define LUA_OPLT 1
#define LUA_OPLE 2

/* GC options (lua.h:188) */
#define LUA_GCSTOP 0
#define LUA_GCRESTART 1
#define LUA_GCCOLLECT 2
#define LUA_GCCOUNT 3
#define LUA_GCCOUNTB 4
#define LUA_GCSTEP 5
#define LUA_GCSETPAUSE 6
#define LUA_GCSETSTEPMUL 7
#define LUA_GCISRUNNING 9
#define LUA_GCGEN 10
#define LUA_GCINC 11

/* Hook events (lua.h:342) */
#define LUA_HOOKCALL 0
#define LUA_HOOKRET 1
#define LUA_HOOKLINE 2
#define LUA_HOOKCOUNT 3
#define LUA_HOOKTAILCALL 4

/* Hook masks (lua.h:348) */
#define LUA_MASKCALL (1 << LUA_HOOKCALL)
#define LUA_MASKRET (1 << LUA_HOOKRET)
#define LUA_MASKLINE (1 << LUA_HOOKLINE)
#define LUA_MASKCOUNT (1 << LUA_HOOKCOUNT)

/* Identity of the registry, globals (lua.h:67) */
#define LUA_RIDX_MAINTHREAD 1
#define LUA_RIDX_GLOBALS 2

/* Signature/copyright (lua.h:20-24) */
#define LUA_SIGNATURE "\x1bLua"
#define LUA_COPYRIGHT LUA_RELEASE "  Copyright (C) 1994-2024 Lua.org, PUC-Rio"
#define LUA_AUTHORS "R. Ierusalimschy, L. H. de Figueiredo, W. Celes"
#define LUA_VERSION_RELEASE_NUM (LUA_VERSION_NUM * 100 + 0)

/* Minimum stack size (lua.h:114) */
#define LUA_MINSTACK 20

/* Extra space (lua.h:61) */
#define LUA_EXTRASPACE (sizeof(void *))
```

- [ ] **Step 2: Add missing convenience macros**

```c
/* Upvalue index (lua.h:52) */
#define lua_upvalueindex(i) (LUA_REGISTRYINDEX - (i))

/* Push global table (lua.h:429) */
#define lua_pushglobaltable(L) \
    ((void)lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS))

/* Reset thread (compat, lua.h:415) */
#define lua_resetthread(L) lua_closethread(L, NULL)

/* Compatibility userdata (lua.h:417-422) */
#define lua_newuserdata(L,s) lua_newuserdatauv(L, s, 1)
#define lua_getuservalue(L,idx) lua_getiuservalue(L, idx, 1)
#define lua_setuservalue(L,idx) lua_setiuservalue(L, idx, 1)

/* Type predicate macros (lua.h:400-410) */
#define lua_isnil(L,i) (lua_type(L,i) == LUA_TNIL)
#define lua_isboolean(L,i) (lua_type(L,i) == LUA_TBOOLEAN)
#define lua_isfunction(L,i) (lua_type(L,i) == LUA_TFUNCTION)
#define lua_istable(L,i) (lua_type(L,i) == LUA_TTABLE)
#define lua_isthread(L,i) (lua_type(L,i) == LUA_TTHREAD)
#define lua_isnone(L,i) (lua_type(L,i) == LUA_TNONE)
#define lua_isnoneornil(L,i) (lua_type(L,i) <= 0)
#define lua_islightuserdata(L,i) (lua_type(L,i) == LUA_TLIGHTUSERDATA)
```

- [ ] **Step 3: Verify headers still parse**

Run: `gcc -fsyntax-only -Isrc/lua src/lua/lua.h src/lua/lauxlib.h src/lua/lualib.h`
Expected: no errors

- [ ] **Step 4: Run existing tests to verify nothing broke**

Run: `cd tests/c_api && make clean && make test`
Expected: `PASS: 00_smoke`

- [ ] **Step 5: Commit**

```bash
git add src/lua/lua.h
git commit -m "feat: extend lua.h with full PUC 5.5 constants, type codes, and macros"
```

---

## Phase 1: Core lua.h — State Lifecycle + Stack + Type Predicates + Conversions

**Goal:** Implement the foundational C API functions that every C program needs: `lua_newstate` with custom allocator, `lua_absindex`, `lua_checkstack`, `lua_xmove`, all `lua_is*` predicates, `lua_tolstring`, `lua_typename`, `lua_rawlen`, `lua_tocfunction`, `lua_tothread`.

**Prerequisite:** Phase 0 complete.

**Workflow (applies to all phases 1-10 after R1-R3 refactoring):**
Each function is implemented in two steps:
1. **api.State method** in `api.zig` — the real logic with Zig types (`ApiError!`, `[]const u8`, enums)
2. **c_api.zig shim** — thin `pub export fn` that creates `api.State.fromVm(L)` and delegates

**Files:**
- Modify: `src/lua/api.zig` (add State methods)
- Modify: `src/lua/c_api.zig` (add export shims)
- Modify: `src/lua/lua.h` (add function declarations)
- Create: `tests/c_api/01_core.c`

### Function Manifest

| Function | Signature | Notes |
|----------|-----------|-------|
| `lua_newstate` | `lua_State *(lua_Alloc f, void *ud, unsigned int seed)` | Create VM with custom allocator + seed |
| `lua_newthread` | `lua_State *(lua_State *L)` | Create coroutine thread |
| `lua_closethread` | `int (lua_State *L, lua_State *from)` | Close/reset thread |
| `lua_atpanic` | `lua_CFunction (lua_State *L, lua_CFunction panicf)` | Set panic function |
| `lua_version` | `lua_Number ()` | Return version number |
| `lua_absindex` | `int (lua_State *L, int idx)` | Convert to absolute index |
| `lua_checkstack` | `int (lua_State *L, int n)` | Ensure stack space |
| `lua_xmove` | `void (lua_State *from, lua_State *to, int n)` | Move values between threads |
| `lua_iscfunction` | `int (lua_State *L, int idx)` | Test if C function |
| `lua_isinteger` | `int (lua_State *L, int idx)` | Test if integer |
| `lua_isnumber` | `int (lua_State *L, int idx)` | Test if number |
| `lua_isstring` | `int (lua_State *L, int idx)` | Test if string |
| `lua_isuserdata` | `int (lua_State *L, int idx)` | Test if userdata |
| `lua_isyieldable` | `int (lua_State *L)` | Test if yieldable |
| `lua_tolstring` | `const char *(lua_State *L, int idx, size_t *len)` | Convert to string |
| `lua_typename` | `const char *(lua_State *L, int tp)` | Type name string |
| `lua_rawlen` | `unsigned int (lua_State *L, int idx)` | Raw length |
| `lua_tocfunction` | `lua_CFunction (lua_State *L, int idx)` | Get C function pointer |
| `lua_tothread` | `lua_State *(lua_State *L, int idx)` | Get thread |
| `lua_pushvfstring` | `const char *(lua_State *L, const char *fmt, va_list argp)` | Vararg format (refactor pushfstring) |

### Task 1.1: lua_absindex + lua_checkstack

- [ ] **Step 1: Write failing test in `tests/c_api/01_core.c`**

```c
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"

int main(void) {
    lua_State *L = luaL_newstate();

    /* Push some values */
    lua_pushnil(L);
    lua_pushinteger(L, 42);
    lua_pushstring(L, "hello");

    /* absindex converts relative to absolute */
    int abs = lua_absindex(L, -1);
    if (abs != 3) {
        fprintf(stderr, "FAIL: absindex(-1) = %d, expected 3\n", abs);
        return 1;
    }

    /* checkstack ensures space */
    if (!lua_checkstack(L, 100)) {
        fprintf(stderr, "FAIL: checkstack(100) returned false\n");
        return 1;
    }

    lua_close(L);
    printf("PASS: 01_core absindex+checkstack\n");
    return 0;
}
```

- [ ] **Step 2: Run test — expect link error (undefined symbols)**

Run: `cd tests/c_api && gcc -I../../src/lua -L../../zig-out/lib -llua -lm -ldl -o 01_core 01_core.c && ./01_core`
Expected: undefined reference to `lua_absindex`, `lua_checkstack`

- [ ] **Step 3: Implement `lua_absindex` and `lua_checkstack` in c_api.zig**

Follow existing patterns in c_api.zig. `lua_absindex` translates a relative index to absolute (matching the existing `cIndexToAbs` helper). `lua_checkstack` calls `vm.c_stack.ensureUnusedCapacity`.

```zig
/// PUC `lua_absindex` (lapi.c:240): converts a relative index to an
/// absolute index. Negative indices count from the top; positive indices
/// are already absolute.
pub export fn lua_absindex(L: ?*lua_State, idx: c_int) c_int {
    const vm = L orelse return 0;
    if (idx > 0) return idx;
    if (idx > LUA_REGISTRYINDEX) {
        return @intCast(vm.c_stack.items.len + 1 + idx);
    }
    return idx;  // pseudo-indices are returned as-is
}

/// PUC `lua_checkstack` (lapi.c:206): ensures at least `n` extra stack slots.
/// Returns 1 on success, 0 on failure (OOM).
pub export fn lua_checkstack(L: ?*lua_State, n: c_int) c_int {
    const vm = L orelse return 0;
    vm.c_stack.ensureUnusedCapacity(@intCast(n)) catch return 0;
    return 1;
}
```

- [ ] **Step 4: Add declarations to lua.h**

```c
LUA_API int   (lua_absindex)(lua_State *L, int idx);
LUA_API int   (lua_checkstack)(lua_State *L, int n);
```

- [ ] **Step 5: Build, run test, verify pass**

Run: `zig build -Doptimize=ReleaseFast && cd tests/c_api && make 01_core && ./01_core`
Expected: `PASS: 01_core absindex+checkstack`

- [ ] **Step 6: Commit**

```bash
git add src/lua/c_api.zig src/lua/lua.h tests/c_api/01_core.c
git commit -m "feat(c-api): add lua_absindex and lua_checkstack"
```

### Task 1.2: Type predicates (lua_isnumber, lua_isstring, lua_isinteger, lua_iscfunction, lua_isuserdata, lua_isyieldable)

- [ ] **Step 1: Extend `tests/c_api/01_core.c` with type predicate tests**

```c
    /* Type predicates */
    lua_pushinteger(L, 42);
    if (!lua_isnumber(L, -1) || !lua_isinteger(L, -1)) {
        fprintf(stderr, "FAIL: integer not detected as number/integer\n");
        return 1;
    }

    lua_pushnumber(L, 3.14);
    if (!lua_isnumber(L, -1) || lua_isinteger(L, -1)) {
        fprintf(stderr, "FAIL: float number predicate wrong\n");
        return 1;
    }

    lua_pushstring(L, "test");
    if (!lua_isstring(L, -1) || lua_isnumber(L, -1)) {
        fprintf(stderr, "FAIL: string predicate wrong\n");
        return 1;
    }

    lua_pushcfunction(L, NULL);
    if (!lua_iscfunction(L, -1)) {
        fprintf(stderr, "FAIL: cfunction not detected\n");
        return 1;
    }
```

- [ ] **Step 2: Run test — expect undefined reference errors**

- [ ] **Step 3: Implement all type predicates**

Most are trivial (check `Value` tag). `lua_isnumber` checks if the value is a number OR a string convertible to number (use `vm.apiToNumber`). `lua_isstring` checks for string or number.

```zig
pub export fn lua_isnumber(L: ?*lua_State, idx: c_int) c_int {
    const vm = L orelse return 0;
    const v = cIndexToValue(vm, idx) orelse return 0;
    return switch (v.*) {
        .int, .num => 1,
        else => if (vm.apiToNumber(v) != null) 1 else 0,
    };
}

pub export fn lua_isstring(L: ?*lua_State, idx: c_int) c_int {
    const vm = L orelse return 0;
    const v = cIndexToValue(vm, idx) orelse return 0;
    return switch (v.*) {
        .str, .int, .num => 1,
        else => 0,
    };
}

pub export fn lua_isinteger(L: ?*lua_State, idx: c_int) c_int {
    const vm = L orelse return 0;
    const v = cIndexToValue(vm, idx) orelse return 0;
    return switch (v.*) { .int => 1, else => 0 };
}

pub export fn lua_iscfunction(L: ?*lua_State, idx: c_int) c_int {
    const vm = L orelse return 0;
    const v = cIndexToValue(vm, idx) orelse return 0;
    return switch (v.*) {
        .closure => |c| if (c.flags.is_c_closure) 1 else 0,
        else => 0,
    };
}

pub export fn lua_isuserdata(L: ?*lua_State, idx: c_int) c_int {
    const vm = L orelse return 0;
    const v = cIndexToValue(vm, idx) orelse return 0;
    return switch (v.*) {
        .userdata, .light_userdata => 1,
        else => 0,
    };
}

pub export fn lua_isyieldable(L: ?*lua_State) c_int {
    _ = L;
    return 1; // luazig always allows yield from the main thread
}
```

- [ ] **Step 4: Add declarations to lua.h**

```c
LUA_API int   (lua_isnumber)(lua_State *L, int idx);
LUA_API int   (lua_isstring)(lua_State *L, int idx);
LUA_API int   (lua_isinteger)(lua_State *L, int idx);
LUA_API int   (lua_iscfunction)(lua_State *L, int idx);
LUA_API int   (lua_isuserdata)(lua_State *L, int idx);
LUA_API int   (lua_isyieldable)(lua_State *L);
```

- [ ] **Step 5: Build, test, commit**

### Task 1.3: Conversions (lua_tolstring, lua_typename, lua_rawlen, lua_tocfunction, lua_tothread)

- [ ] **Step 1: Write failing test**

```c
    /* Conversions */
    lua_pushinteger(L, 42);
    size_t len;
    const char *s = lua_tolstring(L, -1, &len);
    if (s == NULL || strcmp(s, "42") != 0 || len != 2) {
        fprintf(stderr, "FAIL: tolstring(int) = '%s', expected '42'\n", s ? s : "NULL");
        return 1;
    }

    const char *tn = lua_typename(L, LUA_TSTRING);
    if (strcmp(tn, "string") != 0) {
        fprintf(stderr, "FAIL: typename(STRING) = '%s'\n", tn);
        return 1;
    }

    lua_pushstring(L, "hello");
    unsigned int rl = lua_rawlen(L, -1);
    if (rl != 5) {
        fprintf(stderr, "FAIL: rawlen('hello') = %u, expected 5\n", rl);
        return 1;
    }
```

- [ ] **Step 2: Implement**

`lua_tolstring` converts a number to its string representation and pushes it (replacing the original value — PUC behavior). For strings, returns the pointer directly.

`lua_typename` returns the PUC type name strings: "no value", "nil", "boolean", "lightuserdata", "number", "string", "table", "function", "userdata", "thread".

`lua_rawlen` returns `#` operator result without metamethods: string length, table array length, userdata length.

- [ ] **Step 3: Add declarations to lua.h, build, test, commit**

### Task 1.4: State lifecycle (lua_newstate with allocator, lua_atpanic, lua_version)

- [ ] **Step 1: Write failing test**

```c
    /* lua_version returns the version number */
    lua_Number ver = lua_version(NULL);
    if ((int)ver != 505) {
        fprintf(stderr, "FAIL: lua_version = %g, expected 505\n", ver);
        return 1;
    }
```

- [ ] **Step 2: Implement**

`lua_newstate(f, ud, seed)`: The existing `luaL_newstate` creates a VM with luazig's default allocator. Extend it to accept an optional `lua_Alloc` function and seed. If `f` is NULL, use the default page allocator.

```zig
pub export fn lua_newstate(
    f: lua_Alloc,
    ud: ?*anyopaque,
    seed: c_uint,
) ?*lua_State {
    // Create VM with the provided allocator (or default if NULL).
    // The seed is used for hash randomization (currently ignored — luazig
    // uses a fixed seed; TODO: wire it into the string hash salt).
    return luaL_newstate();  // Phase 1: delegate; Phase 9 will add allocator support
}

pub export fn lua_version(L: ?*lua_State) f64 {
    _ = L;
    return @floatFromInt(LUA_VERSION_NUM);
}
```

Note: `lua_atpanic` and full `lua_newstate` with custom allocator are deferred to Phase 9 (they require VM allocator plumbing). For now, `lua_newstate` delegates to `luaL_newstate` — sufficient for programs that don't use custom allocators (which is the vast majority).

- [ ] **Step 3: Add declarations, build, test, commit**

### Task 1.5: lua_pushvfstring (refactor lua_pushfstring)

- [ ] **Step 1: Refactor `lua_pushfstring` to delegate to `lua_pushvfstring`**

PUC Lua's `lua_pushfstring` is a thin wrapper around `lua_pushvfstring`. Currently luazig implements `lua_pushfstring` directly. Add `lua_pushvfstring` that takes a `va_list` and make `lua_pushfstring` call it.

```zig
pub export fn lua_pushvfstring(
    L: ?*lua_State,
    fmt: [*:0]const u8,
    argp: *anyopaque,  // va_list — Zig uses @cVaArg to read
) [*:0]const u8 {
    // ... extract the existing format loop from lua_pushfstring into here ...
}

pub export fn lua_pushfstring(L: ?*lua_State, fmt: [*:0]const u8, ...) [*:0]const u8 {
    @cVaStart(&fmt);  // Zig comptime vararg start
    defer @cVaEnd(&fmt);
    return lua_pushvfstring(L, fmt, @cVaArg(&fmt, *anyopaque));
}
```

- [ ] **Step 2: Add declarations, build, test, commit**

### Task 1.6: lua_newthread + lua_closethread + lua_xmove

- [ ] **Step 1: Implement thread creation**

`lua_newthread` creates a new coroutine that shares the global state with the parent. In luazig, this maps to creating a new `Thread`/`Vm` that shares the same `global_env` (globals table, registry, string pool).

```zig
pub export fn lua_newthread(L: ?*lua_State) ?*lua_State {
    const vm = L orelse return null;
    // Create a child VM sharing the same global state.
    return vm.apiNewThread();
}
```

`lua_closethread(L, from)` resets a thread to its initial state.

- [ ] **Step 2: Implement `lua_xmove`**

Moves `n` values from one thread's stack to another. Both threads must share the same global state.

```zig
pub export fn lua_xmove(from: ?*lua_State, to: ?*lua_State, n: c_int) void {
    const src = from orelse return;
    const dst = to orelse return;
    const count: usize = @intCast(n);
    if (count > src.c_stack.items.len) return;
    dst.c_stack.appendSlice(src.c_stack.items[src.c_stack.items.len - count ..]) catch {};
    src.c_stack.shrinkRetainingCapacity(src.c_stack.items.len - count);
}
```

- [ ] **Step 3: Add declarations, build, test, commit**

---

## Phase 2: Table Operations — gettable/settable/geti/seti/raw* variants

**Goal:** Complete the table access C API: `lua_gettable`, `lua_settable`, `lua_geti`, `lua_seti`, `lua_rawgeti`, `lua_rawseti`, `lua_rawgetp`, `lua_rawsetp`.

**Prerequisite:** Phase 1 complete.

**Files:**
- Modify: `src/lua/c_api.zig`, `src/lua/lua.h`
- Create: `tests/c_api/02_tables.c`

### Function Manifest

| Function | Signature | Notes |
|----------|-----------|-------|
| `lua_gettable` | `int (lua_State *L, int idx)` | `t[k]` with metamethod |
| `lua_settable` | `void (lua_State *L, int idx)` | `t[k] = v` with metamethod |
| `lua_geti` | `int (lua_State *L, int idx, lua_Integer n)` | `t[n]` with metamethod |
| `lua_seti` | `void (lua_State *L, int idx, lua_Integer n)` | `t[n] = v` with metamethod |
| `lua_rawgeti` | `int (lua_State *L, int idx, lua_Integer n)` | `t[n]` without metamethod |
| `lua_rawseti` | `void (lua_State *L, int idx, lua_Integer n)` | `t[n] = v` without metamethod |
| `lua_rawgetp` | `int (lua_State *L, int idx, const void *p)` | `t[p]` without metamethod |
| `lua_rawsetp` | `void (lua_State *L, int idx, const void *p)` | `t[p] = v` without metamethod |

### Implementation Pattern

All table operations follow the same pattern as the existing `lua_getfield`/`lua_setfield`/`lua_rawget`/`lua_rawset`:

1. Resolve the table value from the index (using the existing `cIndexToValue` helper)
2. Pop the key/value from `c_stack` as needed
3. Call the VM's table access method (`apiTableGet`, `apiTableSet`, `apiRawGet`, `apiRawSet`)

For integer keys (`geti`/`seti`/`rawgeti`/`rawseti`), create a `Value.int(n)` key instead of a string key.

For pointer keys (`rawgetp`/`rawsetp`), create a `Value.light_userdata(p)` key.

### Task 2.1: Implement all 8 table functions

- [ ] **Step 1: Write `tests/c_api/02_tables.c`**

```c
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"

int main(void) {
    lua_State *L = luaL_newstate();

    /* Create a table and use seti/geti */
    lua_newtable(L);  /* stack: {} */
    lua_pushinteger(L, 100);
    lua_seti(L, -2, 1);  /* t[1] = 100 */
    lua_pushinteger(L, 200);
    lua_seti(L, -2, 2);  /* t[2] = 200 */

    /* geti */
    lua_geti(L, -1, 1);  /* push t[1] */
    if (lua_tointeger(L, -1) != 100) {
        fprintf(stderr, "FAIL: geti(1) = %lld\n", (long long)lua_tointeger(L, -1));
        return 1;
    }
    lua_pop(L, 1);

    lua_geti(L, -1, 2);
    if (lua_tointeger(L, -1) != 200) {
        fprintf(stderr, "FAIL: geti(2) = %lld\n", (long long)lua_tointeger(L, -1));
        return 1;
    }
    lua_pop(L, 1);

    /* rawsetp / rawgetp */
    int sentinel = 42;
    lua_pushstring(L, "ptr-value");
    lua_rawsetp(L, -2, &sentinel);  /* t[&sentinel] = "ptr-value" */
    lua_rawgetp(L, -1, &sentinel);
    if (lua_tostring(L, -1) == NULL) {
        fprintf(stderr, "FAIL: rawgetp returned NULL\n");
        return 1;
    }
    lua_pop(L, 2);

    lua_close(L);
    printf("PASS: 02_tables\n");
    return 0;
}
```

- [ ] **Step 2: Implement all 8 functions** following the existing `lua_rawget`/`lua_rawset` pattern

- [ ] **Step 3: Add declarations to lua.h**

```c
LUA_API int   (lua_gettable)(lua_State *L, int idx);
LUA_API void  (lua_settable)(lua_State *L, int idx);
LUA_API int   (lua_geti)(lua_State *L, int idx, lua_Integer n);
LUA_API void  (lua_seti)(lua_State *L, int idx, lua_Integer n);
LUA_API int   (lua_rawgeti)(lua_State *L, int idx, lua_Integer n);
LUA_API void  (lua_rawseti)(lua_State *L, int idx, lua_Integer n);
LUA_API int   (lua_rawgetp)(lua_State *L, int idx, const void *p);
LUA_API void  (lua_rawsetp)(lua_State *L, int idx, const void *p);
```

- [ ] **Step 4: Build, test, commit**

---

## Phase 3: Arithmetic, Comparison, Coroutines, GC

**Goal:** Implement `lua_arith`, `lua_rawequal`, `lua_compare`, `lua_concat`, `lua_len`, `lua_resume`, `lua_yieldk`, `lua_status`, `lua_pushthread`, `lua_gc`.

**Prerequisite:** Phase 1 complete.

**Files:**
- Modify: `src/lua/c_api.zig`, `src/lua/lua.h`
- Create: `tests/c_api/03_arith.c`

### Function Manifest

| Function | Signature | Notes |
|----------|-----------|-------|
| `lua_arith` | `void (lua_State *L, int op)` | Perform arithmetic op |
| `lua_rawequal` | `int (lua_State *L, int idx1, int idx2)` | Raw equality |
| `lua_compare` | `int (lua_State *L, int idx1, int idx2, int op)` | EQ/LT/LE |
| `lua_concat` | `void (lua_State *L, int n)` | Concatenate n values |
| `lua_len` | `void (lua_State *L, int idx)` | Length with metamethod |
| `lua_resume` | `int (lua_State *L, lua_State *from, int nargs, int *nres)` | Resume coroutine |
| `lua_yieldk` | `int (lua_State *L, int nresults, lua_KContext ctx, lua_KFunction k)` | Yield coroutine |
| `lua_status` | `int (lua_State *L)` | Thread status |
| `lua_pushthread` | `int (lua_State *L)` | Push thread object |
| `lua_gc` | `int (lua_State *L, int what, ...)` | GC control |

### Task 3.1: lua_arith + lua_rawequal + lua_compare

- [ ] **Step 1: Write failing test**

```c
    /* arith: add */
    lua_pushinteger(L, 10);
    lua_pushinteger(L, 20);
    lua_arith(L, LUA_OPADD);
    if (lua_tointeger(L, -1) != 30) {
        fprintf(stderr, "FAIL: 10+20 = %lld\n", (long long)lua_tointeger(L, -1));
        return 1;
    }

    /* compare: equal */
    lua_pushinteger(L, 5);
    lua_pushinteger(L, 5);
    if (!lua_compare(L, -1, -2, LUA_OPEQ)) {
        fprintf(stderr, "FAIL: 5 == 5 failed\n");
        return 1;
    }
```

- [ ] **Step 2: Implement**

`lua_arith(L, op)`: pops the top value (or two for binary ops), performs the operation, pushes the result. For binary ops, the operands are at `-2` and `-1`. Map `LUA_OP*` constants to VM arithmetic operations.

`lua_rawequal`: compare two values without metamethods (raw equality).
`lua_compare`: compare with metamethods (__eq, __lt, __le).

- [ ] **Step 3: Add declarations, build, test, commit**

### Task 3.2: lua_concat + lua_len

- [ ] **Step 1: Implement `lua_concat`**

Concatenates `n` values on the stack, popping them and pushing the result. Follows PUC `lapi.c:lua_concat`.

```zig
pub export fn lua_concat(L: ?*lua_State, n: c_int) void {
    const vm = L orelse return;
    const count: usize = @intCast(n);
    if (count == 0) {
        vm.c_stack.append(vm.gc.internStr("")) catch {};
        return;
    }
    // Call VM's concat helper, which handles __concat metamethods.
    vm.apiConcat(count);
}
```

- [ ] **Step 2: Implement `lua_len`**

Pushes the length of the value at `idx`, honoring `__len` metamethods.

- [ ] **Step 3: Build, test, commit**

### Task 3.3: Coroutines (lua_resume, lua_yieldk, lua_status, lua_pushthread)

- [ ] **Step 1: Implement `lua_resume`**

Resumes a coroutine. This integrates with the VM's existing coroutine machinery. The `from` parameter is the resuming thread; `nargs` values are on the coroutine's stack; `*nres` receives the result count.

```zig
pub export fn lua_resume(
    L: ?*lua_State,
    from: ?*lua_State,
    nargs: c_int,
    nres: ?*c_int,
) c_int {
    const vm = L orelse return LUA_ERRRUN;
    // Transfer nargs from `from.c_stack` to the coroutine's stack,
    // then resume via vm.apiResume().
    const status = vm.apiResume(from, @intCast(nargs));
    if (nres) |nr| nr.* = @intCast(vm.c_stack.items.len);
    return switch (status) {
        .ok => LUA_OK,
        .yield => LUA_YIELD,
        .error_runtime => LUA_ERRRUN,
    };
}
```

- [ ] **Step 2: Implement `lua_yieldk`**

Yields from a coroutine. The `nresults` values on the stack are passed back to the resumer.

- [ ] **Step 3: Implement `lua_status` and `lua_pushthread`**

- [ ] **Step 4: Write test (create coroutine in Lua, resume from C)**

- [ ] **Step 5: Build, test, commit**

### Task 3.4: lua_gc

- [ ] **Step 1: Implement `lua_gc`**

Map `LUA_GC*` options to the VM's GC controller:

```zig
pub export fn lua_gc(L: ?*lua_State, what: c_int, data: c_int) c_int {
    const vm = L orelse return 0;
    return switch (what) {
        LUA_GCSTOP => { vm.gc.stop(); return 0; },
        LUA_GCRESTART => { vm.gc.restart(); return 0; },
        LUA_GCCOLLECT => { vm.gc.collectAll(); return 0; },
        LUA_GCCOUNT => @intCast(vm.gc.totalKbytes()),
        LUA_GCCOUNTB => @intCast(vm.gc.totalBytes() % 1024),
        LUA_GCSTEP => { vm.gc.step(@intCast(data)); return 1; },
        LUA_GCSETPAUSE => { return vm.gc.setPause(@intCast(data)); },
        LUA_GCSETSTEPMUL => { return vm.gc.setStepMul(@intCast(data)); },
        LUA_GCISRUNNING => { return if (vm.gc.isRunning()) 1 else 0; },
        else => 0,
    };
}
```

Note: The GC controller methods (`stop`, `step`, `collectAll`, etc.) may need to be added to the VM if they don't exist. Check `vm.zig` and `gc.zig` for existing GC control surface.

- [ ] **Step 2: Build, test, commit**

---

## Phase 4: Load/Dump, Warnings, Miscellaneous

**Goal:** Implement `lua_load` (with `lua_Reader` callback), `lua_dump` (with `lua_Writer`), `lua_setwarnf`/`lua_warning`, `lua_stringtonumber`, `lua_numbertocstring`, `lua_setallocf`, `lua_toclose`, `lua_closeslot`, `lua_upvalueid`, `lua_upvaluejoin`.

**Prerequisite:** Phase 1 complete.

**Files:**
- Modify: `src/lua/c_api.zig`, `src/lua/lua.h`
- Create: `tests/c_api/04_load.c`

### Function Manifest

| Function | Signature | Notes |
|----------|-----------|-------|
| `lua_load` | `int (lua_State *L, lua_Reader reader, void *dt, const char *chunkname, const char *mode)` | Load from reader callback |
| `lua_dump` | `int (lua_State *L, lua_Writer writer, void *data, int strip)` | Dump function to writer |
| `lua_Reader` | typedef | `const char *(*)(lua_State *L, void *data, size_t *size)` |
| `lua_Writer` | typedef | `int *(*)(lua_State *L, const void *p, size_t sz, void *ud)` |
| `lua_setwarnf` | `void (lua_State *L, lua_WarnFunction f, void *ud)` | Set warning handler |
| `lua_warning` | `void (lua_State *L, const char *msg, int tocont)` | Emit warning |
| `lua_WarnFunction` | typedef | `void (*)(void *ud, const char *msg, int tocont)` |
| `lua_stringtonumber` | `size_t (lua_State *L, const char *s)` | Parse string to number |
| `lua_numbertocstring` | `int (lua_State *L, lua_Number n, char *buff)` | Format number to buffer |
| `lua_setallocf` | `void (lua_State *L, lua_Alloc f, void *ud)` | Set allocator |
| `lua_toclose` | `void (lua_State *L, int idx)` | Mark for auto-close |
| `lua_closeslot` | `void (lua_State *L, int idx)` | Close and remove |
| `lua_upvalueid` | `void *(lua_State *L, int fidx, int n)` | Get upvalue identity |
| `lua_upvaluejoin` | `void (lua_State *L, int fidx1, int n1, int fidx2, int n2)` | Join upvalues |

### Task 4.1: lua_load (with lua_Reader)

- [ ] **Step 1: Define `lua_Reader` typedef in lua.h**

```c
typedef const char *(*lua_Reader)(lua_State *L, void *data, size_t *size);
```

- [ ] **Step 2: Implement `lua_load`**

The reader is called repeatedly to produce the source stream. Collect chunks into a buffer, then compile:

```zig
pub export fn lua_load(
    L: ?*lua_State,
    reader: ?*const fn (?*lua_State, ?*anyopaque, ?*usize) callconv(.c) ?[*]const u8,
    dt: ?*anyopaque,
    chunkname: ?[*:0]const u8,
    mode: ?[*:0]const u8,
) c_int {
    const vm = L orelse return LUA_ERRRUN;

    // Collect all chunks from the reader into a buffer.
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(vm.gpa);

    while (true) {
        var sz: usize = 0;
        const chunk = reader.?(L, dt, &sz) orelse break;
        if (sz == 0) break;
        buf.appendSlice(vm.gpa, chunk[0..sz]) catch return LUA_ERRMEM;
    }

    // Compile the collected source.
    return compileBuffer(vm, buf.items, chunkname, mode);
}
```

- [ ] **Step 3: Write test with a memory reader**

- [ ] **Step 4: Build, test, commit**

### Task 4.2: lua_dump (with lua_Writer)

- [ ] **Step 1: Define `lua_Writer` typedef**

```c
typedef int *(*lua_Writer)(lua_State *L, const void *p, size_t sz, void *ud);
```

- [ ] **Step 2: Implement `lua_dump`**

Serializes the function at the top of the stack using the existing `undump.zig` / binary chunk format (added in P15.74h). Calls the writer with the serialized bytes.

Note: `strip` controls whether debug info is stripped. If the binary chunk format supports it, honor it; otherwise ignore.

- [ ] **Step 3: Write roundtrip test (dump then load)**

- [ ] **Step 4: Build, test, commit**

### Task 4.3: Warnings (lua_setwarnf, lua_warning)

- [ ] **Step 1: Define `lua_WarnFunction` typedef**

```c
typedef void (*lua_WarnFunction)(void *ud, const char *msg, int tocont);
```

- [ ] **Step 2: Implement**

Store the warning function + ud on the VM. `lua_warning` calls it. If no handler is set, warnings are silently dropped (matching PUC's default).

- [ ] **Step 3: Build, test, commit**

### Task 4.4: String/number conversions + misc

- [ ] **Step 1: Implement `lua_stringtonumber`, `lua_numbertocstring`**

`lua_stringtonumber(s)` parses `s` as a number and pushes it. Returns the string length consumed (0 if not a number).

`lua_numbertocstring(n, buff)` formats `n` into `buff` (must be at least `LUAI_NUMBUFLEN` = 50 chars). Returns success.

- [ ] **Step 2: Implement `lua_setallocf`** (store on VM; actual wiring deferred to Phase 9)

- [ ] **Step 3: Implement `lua_toclose`/`lua_closeslot`**

These integrate with PUC's `<close>` / to-be-closed mechanism. Mark a stack slot for auto-close; `lua_closeslot` triggers the `__close` metamethod and removes the value.

- [ ] **Step 4: Implement `lua_upvalueid`/`lua_upvaluejoin`**

`lua_upvalueid` returns a unique pointer for an upvalue (allows identity comparison). `lua_upvaluejoin` makes one closure's upvalue share the same cell as another's.

Note: These require that cclosure upvalues are working (Phase 9). If Phase 9 is not done yet, implement them to return `null` with a `@panic` for `n > 0`.

- [ ] **Step 5: Build, test, commit**

---

## Phase 5: lauxlib — Argument Checking, Error, Traceback

**Goal:** Complete the `luaL_*` auxiliary library: all argument checking functions, error reporting, traceback, opt/check variants, `requiref`, `gsub`, `fileresult`/`execresult`.

**Prerequisite:** Phase 1 complete.

**Files:**
- Modify: `src/lua/c_api.zig`, `src/lua/lauxlib.h`
- Create: `tests/c_api/05_auxlib.c`

### Function Manifest

| Function | Signature | Notes |
|----------|-----------|-------|
| `luaL_checktype` | `void (lua_State *L, int arg, int t)` | Check type, error if mismatch |
| `luaL_checkany` | `void (lua_State *L, int arg)` | Ensure argument exists |
| `luaL_checkstack` | `void (lua_State *L, int sz, const char *msg)` | Check stack, error if fail |
| `luaL_checknumber` | `lua_Number (lua_State *L, int arg)` | Check number argument |
| `luaL_optnumber` | `lua_Number (lua_State *L, int arg, lua_Number def)` | Optional number |
| `luaL_optlstring` | `const char *(lua_State *L, int arg, const char *def, size_t *l)` | Optional string |
| `luaL_checkoption` | `int (lua_State *L, int arg, const char *def, const char *const lst[])` | String → enum |
| `luaL_typeerror` | `int (lua_State *L, int arg, const char *tname)` | Raise type error |
| `luaL_argerror` | `int (lua_State *L, int arg, const char *extramsg)` | Raise arg error |
| `luaL_where` | `void (lua_State *L, int lvl)` | Push source location |
| `luaL_error` | `int (lua_State *L, const char *fmt, ...)` | Formatted error (noreturn) |
| `luaL_traceback` | `void (lua_State *L, lua_State *L1, const char *msg, int lvl)` | Push traceback |
| `luaL_tolstring` | `const char *(lua_State *L, int idx, size_t *len)` | `__tostring` or default |
| `luaL_len` | `lua_Integer (lua_State *L, int idx)` | Length via `__len` |
| `luaL_gsub` | `const char *(lua_State *L, const char *s, const char *p, const char *r)` | String replace |
| `luaL_addgsub` | `void (luaL_Buffer *b, const char *s, const char *p, const char *r)` | Buffer gsub |
| `luaL_getmetafield` | `int (lua_State *L, int obj, const char *event)` | Get metamethod |
| `luaL_callmeta` | `int (lua_State *L, int obj, const char *event)` | Call metamethod |
| `luaL_getsubtable` | `int (lua_State *L, int idx, const char *fname)` | Get/create subtable |
| `luaL_requiref` | `void (lua_State *L, const char *modname, lua_CFunction openf, int glb)` | require + openlibs |
| `luaL_fileresult` | `int (lua_State *L, int stat, const char *fname)` | File op result |
| `luaL_execresult` | `int (lua_State *L, int stat)` | exec op result |
| `luaL_loadstring` | `int (lua_State *L, const char *s)` | Compile string |
| `luaL_makeseed` | `unsigned int (lua_State *L)` | Generate random seed |
| `luaL_alloc` | `void *(lua_State *L, void *ptr, size_t osize, size_t nsize)` | Default allocator |

### Implementation Pattern

All `luaL_check*` functions follow PUC's `lauxlib.c` pattern:
1. Try to convert/check the value
2. On failure, call `luaL_typeerror` or `luaL_argerror`, which formats a message and calls `lua_error` (longjmp)

The error message format matches PUC exactly: `"bad argument #%d to '%s' (%s expected, got %s)"`.

### Task 5.1: Error infrastructure (argerror, typeerror, where)

- [ ] **Step 1: Implement `luaL_where`**

Pushes `"source:line: "` for the given stack level. Used as prefix for error messages.

- [ ] **Step 2: Implement `luaL_argerror` and `luaL_typeerror`**

These format the standard "bad argument" message and call `lua_error`. The message format must match PUC exactly for compatibility with test suites.

- [ ] **Step 3: Write test, build, commit**

### Task 5.2: All check/opt functions

- [ ] **Step 1: Implement `luaL_checktype`, `luaL_checkany`, `luaL_checkstack`**

- [ ] **Step 2: Implement `luaL_checknumber`, `luaL_optnumber`, `luaL_optlstring`**

- [ ] **Step 3: Implement `luaL_checkoption`**

String-to-enum lookup in a `const char *[]` array.

- [ ] **Step 4: Add declarations to lauxlib.h, write test, build, commit**

### Task 5.3: Traceback and formatting

- [ ] **Step 1: Implement `luaL_traceback`**

Builds a stack trace string by walking the call stack via `lua_getstack`/`lua_getinfo`. This depends on Phase 8 (Debug API) for `lua_getstack`/`lua_getinfo`. If Phase 8 is not done, implement a simplified version that uses the VM's internal call frame list.

- [ ] **Step 2: Implement `luaL_tolstring`**

Calls `__tostring` metamethod if present; otherwise formats the value using default rules.

- [ ] **Step 3: Implement `luaL_error` (formatted, noreturn)**

```zig
pub export fn luaL_error(L: ?*lua_State, fmt: [*:0]const u8, ...) noreturn {
    @cVaStart(&fmt);
    defer @cVaEnd(&fmt);
    const vm = L.?;
    luaL_where(vm, 1);  // push "source:line: "
    const msg = lua_pushvfstring(vm, fmt, @cVaArg(&fmt, *anyopaque));
    vm.c_stack.append(vm.gc.internStr(": ")) catch {};
    vm.c_stack.appendSlice(msg) catch {};
    vm.apiConcat(3);
    lua_error(vm);  // longjmp — never returns
}
```

- [ ] **Step 4: Build, test, commit**

### Task 5.4: Utility functions (gsub, len, getmetafield, callmeta, getsubtable, requiref)

- [ ] **Step 1: Implement `luaL_gsub`**

String substitution: replaces all occurrences of `p` in `s` with `r`. Pushes result, returns pointer.

- [ ] **Step 2: Implement `luaL_len`, `luaL_getmetafield`, `luaL_callmeta`**

- [ ] **Step 3: Implement `luaL_getsubtable`**

Gets (or creates) a table stored as a field/metatable entry.

- [ ] **Step 4: Implement `luaL_requiref`**

Calls `openf` to open a module, stores it in `package.loaded`, optionally sets it as global. This is needed by `luaL_openlibs` (Phase 7).

```zig
pub export fn luaL_requiref(
    L: ?*lua_State,
    modname: [*:0]const u8,
    openf: ?*const fn (?*lua_State) callconv(.c) c_int,
    glb: c_int,
) void {
    const vm = L.?;
    // Call openf to push the module table
    lua_pushcclosure(vm, openf, 0);
    lua_pushstring(vm, modname);
    lua_pcall(vm, 1, 1, 0);

    // Store in package.loaded[modname]
    lua_getglobal(vm, "package");
    if (lua_type(vm, -1) == LUA_TTABLE) {
        lua_getfield(vm, -1, "loaded");
        if (lua_type(vm, -1) == LUA_TTABLE) {
            lua_pushvalue(vm, -3);  // module table
            lua_setfield(vm, -2, modname);  // package.loaded[modname] = mod
        }
        lua_pop(vm, 1);  // pop "loaded"
    }
    lua_pop(vm, 1);  // pop "package"

    // Optionally set as global
    if (glb != 0) {
        lua_pushvalue(vm, -1);
        lua_setglobal(vm, modname);
    }
}
```

- [ ] **Step 5: Build, test, commit**

### Task 5.5: File/exec result + loadstring + makeseed + alloc

- [ ] **Step 1: Implement `luaL_fileresult` and `luaL_execresult`**

These push standard error/result values for file and exec operations. They use `errno` and `strerror` for error messages.

- [ ] **Step 2: Implement `luaL_loadstring`**

```zig
pub export fn luaL_loadstring(L: ?*lua_State, s: [*:0]const u8) c_int {
    const len = std.mem.len(s);
    return luaL_loadbufferx(L, s, len, s, null);
}
```

- [ ] **Step 3: Add macros to lauxlib.h**

```c
#define luaL_dostring(L, s) \
    (luaL_loadstring(L, s) || lua_pcall(L, 0, LUA_MULTRET, 0))

#define luaL_loadbuffer(L, buff, sz, name) \
    luaL_loadbufferx(L, buff, sz, name, NULL)

#define luaL_loadfile(L, fn) \
    luaL_loadfilex(L, fn, NULL)

#define luaL_dofile(L, fn) \
    (luaL_loadfile(L, fn) || lua_pcall(L, 0, LUA_MULTRET, 0))

#define luaL_checkstring(L, a) (luaL_checklstring(L, (a), NULL))
#define luaL_optstring(L, a, d) (luaL_optlstring(L, (a), NULL, (d)))
#define luaL_typename(L, i) lua_typename(L, lua_type(L, (i)))
#define luaL_pushfail(L) lua_pushnil(L)
```

- [ ] **Step 4: Implement `luaL_makeseed` and `luaL_alloc`**

`luaL_makeseed` generates a random seed from time/address entropy (used by `lua_newstate`). `luaL_alloc` is the default allocator (realloc-based).

- [ ] **Step 5: Build, test, commit**

---

## Phase 6: luaL_Buffer Subsystem + luaL_Stream

**Goal:** Implement the complete buffer API used by many C libraries for efficient string building, plus `luaL_Stream` / `LUA_FILEHANDLE` for `io` library integration.

**Prerequisite:** Phase 5 complete (uses `luaL_error`).

**Files:**
- Create: `src/lua/lauxlib.zig` (buffer subsystem, ~300 lines)
- Modify: `src/lua/c_api.zig` (import + re-export buffer functions)
- Modify: `src/lua/lauxlib.h` (add Buffer + Stream types)

### Buffer Architecture

PUC Lua's `luaL_Buffer` uses a "box on stack" technique:
1. A buffer is initialized with `luaL_buffinit(L, &b)`
2. Data is added via `luaL_addlstring`, `luaL_addstring`, `luaL_addvalue`
3. Internally, the buffer preallocates `LUAL_BUFFERSIZE` bytes on the stack
4. If exceeded, it creates a Lua string object as a "box" on the stack and reallocates

The C-facing `luaL_Buffer` struct must have a stable layout (extern struct):

```c
typedef struct luaL_Buffer {
    char *b;          /* buffer address */
    size_t size;      /* buffer size */
    size_t n;         /* number of characters in buffer */
    lua_State *L;
    /* ... init fields ... */
} luaL_Buffer;
```

### Function Manifest

| Function | Signature |
|----------|-----------|
| `luaL_buffinit` | `void (lua_State *L, luaL_Buffer *B)` |
| `luaL_prepbuffsize` | `char *(luaL_Buffer *B, size_t sz)` |
| `luaL_addlstring` | `void (luaL_Buffer *B, const char *s, size_t l)` |
| `luaL_addstring` | `void (luaL_Buffer *B, const char *s)` |
| `luaL_addvalue` | `void (luaL_Buffer *B)` |
| `luaL_pushresult` | `void (luaL_Buffer *B)` |
| `luaL_pushresultsize` | `void (luaL_Buffer *B, size_t sz)` |
| `luaL_buffinitsize` | `char *(lua_State *L, luaL_Buffer *B, size_t sz)` |
| `luaL_buffaddr` | `char *(luaL_Buffer *B)` |
| `luaL_bufflen` | `size_t (luaL_Buffer *B)` |
| `luaL_buffsub` | `void (luaL_Buffer *B, size_t l)` |

### Task 6.1: Implement luaL_Buffer

- [ ] **Step 1: Define `luaL_Buffer` as an extern struct in c_api.zig / lauxlib.zig**

Match PUC's layout exactly so C code allocating `luaL_Buffer` on its stack is binary-compatible.

- [ ] **Step 2: Implement all buffer functions**

The buffer manages an internal `std.ArrayListUnmanaged(u8)`. `luaL_prepbuffsize` ensures capacity. `luaL_addvalue` pops a value from the Lua stack, converts to string, and appends.

- [ ] **Step 3: Define macros in lauxlib.h**

```c
#define luaL_addchar(B,c) \
    ((void)((B)->n < (B)->size || luaL_prepbuffsize(B, 1)), \
     ((B)->b[(B)->n++] = (c)))

#define luaL_addsize(B,s) ((B)->n += (s))

#define luaL_prepbuffer(B) luaL_prepbuffsize(B, LUAL_BUFFERSIZE)
```

- [ ] **Step 4: Write test that builds a string via buffer API**

- [ ] **Step 5: Build, test, commit**

### Task 6.2: luaL_Stream + LUA_FILEHANDLE

- [ ] **Step 1: Define `luaL_Stream` in lauxlib.h**

```c
typedef struct luaL_Stream {
    FILE *f;              /* stream (NULL means incompletely created) */
    lua_CFunction closef; /* to close stream (NULL for standard files) */
} luaL_Stream;

#define LUA_FILEHANDLE "FILE*"
```

- [ ] **Step 2: Export `LUA_FILEHANDLE` and the stream metatable registration**

This enables C libraries that use `luaL_newstream` / `luaL_teststream` patterns.

- [ ] **Step 3: Build, test, commit**

---

## Phase 7: lualib — Standard Library Exports

**Goal:** Export all 10 `luaopen_*` functions + `luaL_openselectedlibs` so C programs can open individual standard libraries via `luaL_openlibs` or selectively.

**Prerequisite:** Phase 5 complete (uses `luaL_requiref`).

**Files:**
- Create: `src/lua/lualib.zig` (~150 lines)
- Modify: `src/lua/c_api.zig` (import lualib module)
- Modify: `src/lua/lualib.h` (verify all declarations present)

### Architecture

luazig's standard libraries are implemented internally in Zig (base, string, math, table, io, os, coroutine, debug, utf8, package). They are registered when the VM starts up via `initStdLib`. The `luaopen_*` exports need to:

1. Create a new table on the C stack
2. Populate it with the library's functions (delegate to the VM's existing library initialization code)
3. Return 1 (the table)

The simplest approach: each `luaopen_*` calls the internal library registration function, adapted to push onto `c_stack` instead of the bytecode stack.

### Function Manifest

| Function | Opens |
|----------|-------|
| `luaopen_base` | base library (print, pairs, ipairs, etc.) |
| `luaopen_package` | package module (require, loadlib, etc.) |
| `luaopen_coroutine` | coroutine library |
| `luaopen_table` | table library (insert, remove, sort, etc.) |
| `luaopen_io` | io library (read, write, open, etc.) |
| `luaopen_math` | math library (sin, cos, floor, etc.) |
| `luaopen_os` | os library (time, date, execute, etc.) |
| `luaopen_string` | string library (sub, gsub, format, etc.) |
| `luaopen_utf8` | utf8 library (char, codepoint, etc.) |
| `luaopen_debug` | debug library (getinfo, traceback, etc.) |
| `luaL_openselectedlibs` | Open a subset of libraries |

### Task 7.1: Implement luaopen_base

- [ ] **Step 1: Create `src/lua/lualib.zig`**

```zig
const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const lua_State = Vm;

/// PUC `luaopen_base` (lbaselib.c:luaopen_base): pushes the base library
/// table onto the C stack.
pub export fn luaopen_base(L: ?*lua_State) c_int {
    const vm = L orelse return 0;
    // Delegate to the VM's base library registration, adapted for c_stack.
    vm.apiOpenBaseLib();
    return 1;
}
```

- [ ] **Step 2: Add `apiOpenBaseLib()` to the VM** if it doesn't exist — it should create a table, populate it with base functions, and push it onto `c_stack`.

Note: The VM already has base library functions registered internally. The task is to extract them into a table on `c_stack` rather than the globals table. This may require refactoring the library registration to work in both modes (register-as-globals for the interpreter, return-as-table for `luaopen_*`).

- [ ] **Step 3: Build, write test, commit**

### Task 7.2: Implement remaining luaopen_* (9 functions)

- [ ] **Step 1: Implement `luaopen_package`, `luaopen_coroutine`, `luaopen_table`, `luaopen_io`, `luaopen_math`, `luaopen_os`, `luaopen_string`, `luaopen_utf8`, `luaopen_debug`**

Each follows the same pattern: call the VM's library opener, push result table on `c_stack`.

- [ ] **Step 2: Build, test each one, commit**

### Task 7.3: Implement luaL_openselectedlibs

- [ ] **Step 1: Implement bitmask-based library opener**

PUC Lua 5.5's `luaL_openselectedlibs` takes a bitmask of which libraries to open:

```zig
pub export fn luaL_openselectedlibs(L: ?*lua_State, mask: c_uint) void {
    const vm = L orelse return;
    if (mask & luaL_bit(LUA_BASELIB)) != 0 {
        luaL_requiref(vm, "_G", luaopen_base, 1);
        lua_pop(vm, 1);
    }
    if (mask & luaL_bit(LUA_LOADLIB)) != 0 {
        luaL_requiref(vm, LUA_LOADLIBNAME, luaopen_package, 1);
        lua_pop(vm, 1);
    }
    // ... etc for each library ...
}
```

The `luaL_bit` macro and library bitmask constants must be in lualib.h.

- [ ] **Step 2: Add `luaL_openlibs` macro to lualib.h**

```c
#define luaL_openlibs(L) luaL_openselectedlibs(L, ~0u)
```

- [ ] **Step 3: Update `tests/c_api/00_smoke.c` to use `luaL_openlibs`**

- [ ] **Step 4: Build, test, commit**

---

## Phase 8: Debug C API

**Goal:** Implement all 12 debug API functions and the `lua_Debug` struct, enabling debuggers, profilers, and `luaL_traceback` to work.

**Prerequisite:** Phase 1 complete.

**Files:**
- Modify: `src/lua/c_api.zig`, `src/lua/lua.h`
- Create: `tests/c_api/06_debug.c`

### Function Manifest

| Function | Signature | Notes |
|----------|-----------|-------|
| `lua_getstack` | `int (lua_State *L, int level, lua_Debug *ar)` | Get frame info at level |
| `lua_getinfo` | `int (lua_State *L, const char *what, lua_Debug *ar)` | Fill lua_Debug fields |
| `lua_getlocal` | `const char *(lua_State *L, const lua_Debug *ar, int n)` | Get local var name+value |
| `lua_setlocal` | `const char *(lua_State *L, const lua_Debug *ar, int n)` | Set local var value |
| `lua_getupvalue` | `const char *(lua_State *L, int funcindex, int n)` | Get upvalue name+value |
| `lua_setupvalue` | `const char *(lua_State *L, int funcindex, int n)` | Set upvalue value |
| `lua_sethook` | `void (lua_State *L, lua_Hook f, int mask, int count)` | Set debug hook |
| `lua_gethook` | `lua_Hook (lua_State *L)` | Get current hook |
| `lua_gethookmask` | `int (lua_State *L)` | Get hook mask |
| `lua_gethookcount` | `int (lua_State *L)` | Get hook count |

### Architecture

The `lua_Debug` struct (PUC `lua.h:323`) must be an extern struct with binary-compatible layout:

```c
typedef struct lua_Debug {
    int event;
    const char *name;           /* (n) */
    const char *namewhat;       /* (n) */
    const char *what;           /* (S) */
    const char *source;         /* (S) */
    size_t srclen;              /* (S) */
    int currentline;            /* (l) */
    int linedefined;            /* (S) */
    int lastlinedefined;        /* (S) */
    unsigned char nups;         /* (u) number of upvalues */
    unsigned char nparams;      /* (u) number of parameters */
    char isvararg;              /* (u) */
    char istailcall;            /* (t) */
    unsigned short ftransfer;   /* (r) first transfered value */
    unsigned short ntransfer;   /* (r) number of transfered values */
    char short_src[LUA_IDSIZE]; /* (S) */
    /* private part */
    struct CallInfo *i_ci;      /* active function */
} lua_Debug;
```

### Task 8.1: Define lua_Debug + lua_Hook

- [ ] **Step 1: Add `lua_Debug` and `lua_Hook` to lua.h**

```c
typedef void (*lua_Hook)(lua_State *L, lua_Debug *ar);

typedef struct lua_Debug {
    /* ... fields as above ... */
} lua_Debug;
```

- [ ] **Step 2: Add corresponding extern struct in c_api.zig**

### Task 8.2: lua_getstack + lua_getinfo

- [ ] **Step 1: Implement `lua_getstack`**

Walks the VM's call frame list to the given level. Returns 1 on success, 0 if level is too deep. Stores an internal CallInfo pointer in `ar->i_ci`.

- [ ] **Step 2: Implement `lua_getinfo`**

Fills `lua_Debug` fields based on the `what` string (e.g., `"nSlu"` for name/source/line/upvalues). Reads from the Proto associated with the CallInfo.

- [ ] **Step 3: Write test that gets info for a called function**

- [ ] **Step 4: Build, test, commit**

### Task 8.3: Local/upvalue access

- [ ] **Step 1: Implement `lua_getlocal`/`lua_setlocal`**

Access local variables by index within a frame. Uses the Proto's debug info (local names, register ranges).

- [ ] **Step 2: Implement `lua_getupvalue`/`lua_setupvalue`**

Access upvalues by index. Requires cclosure upvalue support (Phase 9). For Lua closures, reads from the Closure's upvalue array.

- [ ] **Step 3: Build, test, commit**

### Task 8.4: Hook functions

- [ ] **Step 1: Implement `lua_sethook`/`lua_gethook`/`lua_gethookmask`/`lua_gethookcount`**

Store hook function + mask + count on the VM. Integrate with the VM's dispatch loop: when the hook is armed, check the mask at call/return/line/count boundaries and invoke the C hook function.

Note: The VM may already have some hook infrastructure for `debug.sethook`. Wire the C API hook to the same mechanism.

- [ ] **Step 2: Write test that sets a line hook and counts lines**

- [ ] **Step 3: Build, test, commit**

---

## Phase 9: Semantic Fixes — cclosure Upvalues + luaL_ref Free-list

**Goal:** Fix two known correctness gaps: `lua_pushcclosure` with `n > 0` (currently panics), and `luaL_ref` ref recycling (currently monotonic).

**Prerequisite:** None (independent of other phases, but unblocks Phase 8 upvalue access).

**Files:**
- Modify: `src/lua/c_api.zig`
- Modify: `src/lua/vm.zig` (Closure struct, if needed)
- Create: `tests/c_api/07_upvalues.c`

### Task 9.1: Fix lua_pushcclosure with n upvalues

- [ ] **Step 1: Write failing test**

```c
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"

static int counter(lua_State *L) {
    /* Upvalue 1 is the initial value, increment and return */
    lua_Integer n = lua_tointeger(L, lua_upvalueindex(1));
    lua_pushinteger(L, n + 1);
    lua_pushvalue(L, -1);
    lua_setupvalue(L, lua_upvalueindex(1), 1);
    return 1;
}

int main(void) {
    lua_State *L = luaL_newstate();

    /* Create a closure with 1 upvalue */
    lua_pushinteger(L, 0);          /* initial counter value */
    lua_pushcclosure(L, counter, 1); /* close over the value */

    /* Register as global */
    lua_setglobal(L, "counter");

    /* Call three times */
    luaL_dostring(L, "return counter()");
    if (lua_tointeger(L, -1) != 1) {
        fprintf(stderr, "FAIL: counter() = %lld, expected 1\n", (long long)lua_tointeger(L, -1));
        return 1;
    }
    lua_pop(L, 1);

    luaL_dostring(L, "return counter()");
    if (lua_tointeger(L, -1) != 2) {
        fprintf(stderr, "FAIL: counter() = %lld, expected 2\n", (long long)lua_tointeger(L, -1));
        return 1;
    }

    lua_close(L);
    printf("PASS: 07_upvalues\n");
    return 0;
}
```

- [ ] **Step 2: Fix `lua_pushcclosure` to accept n > 0**

The Closure struct must store an array of upvalue cells. When `n > 0`, pop `n` values from `c_stack` and store them as the closure's upvalues.

```zig
pub export fn lua_pushcclosure(
    L: ?*lua_State,
    fn_: ?*const fn (?*lua_State) callconv(.c) c_int,
    n: c_int,
) void {
    const vm = L orelse return;
    const nup: usize = @intCast(n);

    // Pop n values from c_stack to use as upvalues
    var upvalues: [UpvalueCell] = .{};
    for (0..nup) |i| {
        upvalues[i] = vm.c_stack.pop().?;
    }

    // Create closure with upvalues
    const closure = vm.gc.createCClosure(fn_, upvalues[0..nup]);
    vm.c_stack.append(vm.gpa, .{ .closure = closure }) catch {};
}
```

Note: The exact mechanism depends on how the VM's Closure struct stores upvalues. Check `vm.zig` for the existing Closure type and adapt.

- [ ] **Step 3: Fix `luaL_setfuncs` with `nup > 0`**

Each registered function should share the same `nup` upvalues. Currently silently drops them.

- [ ] **Step 4: Implement `lua_getupvalue`/`lua_setupvalue` for cclosures** (if not done in Phase 8)

- [ ] **Step 5: Build, test, commit**

### Task 9.2: Fix luaL_ref to use free-list recycling

- [ ] **Step 1: Implement PUC's ref free-list**

PUC Lua stores freed refs in `t[0]` as a linked list. When `luaL_ref` is called:
- If `t[0]` has a free ref, pop it and use that index
- Otherwise, allocate a new index (`#t + 1`)

When `luaL_unref` is called:
- Push the freed ref onto `t[0]`

```zig
pub export fn luaL_ref(L: ?*lua_State, t: c_int) c_int {
    const vm = L orelse return LUA_NOREF;
    // If value is nil, return LUA_REFNIL
    if (cIndexToValue(vm, -1).* == .nil) {
        vm.c_stack.items.len -= 1;
        return LUA_REFNIL;
    }
    // Check free list at t[0]
    // ... PUC algorithm: lua_rawgeti(t, 0); if integer, use as ref ...
}

pub export fn luaL_unref(L: ?*lua_State, t: c_int, ref: c_int) void {
    // Push ref onto free list: lua_rawgeti(t, 0); set t[0] = ref; t[ref] = old_t[0]
}
```

- [ ] **Step 2: Build, test, commit**

### Task 9.3: Full lua_newstate with custom allocator

- [ ] **Step 1: Wire custom `lua_Alloc` into VM creation**

Currently `luaL_newstate` uses the VM's default allocator. Extend to accept an optional `lua_Alloc`:

```zig
pub export fn lua_newstate(
    f: lua_Alloc,
    ud: ?*anyopaque,
    seed: c_uint,
) ?*lua_State {
    if (f) |allocator_fn| {
        // Create VM with custom C allocator
        return Vm.initWithCAllocator(allocator_fn, ud, seed);
    }
    return luaL_newstate();
}
```

This requires adding `Vm.initWithCAllocator` that wraps the C allocator function as a Zig allocator interface.

- [ ] **Step 2: Implement `lua_setallocf`** (swap allocator at runtime)

- [ ] **Step 3: Build, test, commit**

---

## Phase 10: Integration Testing — Real C Library Compatibility

**Goal:** Verify luazig's C API works with real-world C libraries by compiling and running them against `liblua.so`.

**Prerequisite:** Phases 0-9 complete.

**Files:**
- Create: `tests/c_api/integration/` directory
- Create: `tests/c_api/run_integration.sh`

### Task 10.1: Compile and run PUC Lua's own C test extensions

- [ ] **Step 1: Build `lua-5.5.0/testes/libs/*.c` against luazig headers**

Currently these are compiled against PUC headers (`LUA_DIR=lua-5.5.0/src`). Switch to luazig headers:

```bash
cd lua-5.5.0/testes/libs
gcc -shared -fPIC -I../../../src/lua -o lib1.so lib1.c
gcc -shared -fPIC -I../../../src/lua -o lib2.so lib2.c
gcc -shared -fPIC -I../../../src/lua -o udatatest.so udatatest.c
```

- [ ] **Step 2: Load and exercise these from Lua scripts via `require`**

- [ ] **Step 3: Verify all upstream test C extensions pass**

### Task 10.2: Test with a real third-party C library

- [ ] **Step 1: Compile a simple real-world C library (e.g., a JSON parser, or lua-cjson subset) against luazig**

- [ ] **Step 2: Load it via `require` and verify functionality**

- [ ] **Step 3: Document any compatibility issues found and create fix tasks**

### Task 10.3: Full upstream test suite via C API

- [ ] **Step 1: Write a C test runner that links against liblua.so and runs the entire PUC Lua test suite programmatically**

```c
int main(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    luaL_dofile(L, "lua-5.5.0/testes/all.lua");
    lua_close(L);
}
```

- [ ] **Step 2: Compare results with the luazig interpreter running the same suite**

- [ ] **Step 3: Commit integration test infrastructure**

---

## Verification Checklist

After all phases are complete, verify:

- [ ] `liblua.so` and `liblua.a` are produced by `zig build -Doptimize=ReleaseFast`
- [ ] `nm -D --defined-only zig-out/lib/liblua.so | grep -c "lua_"` returns ~200
- [ ] `gcc -Isrc/lua -Lzig-out/lib -llua any_c_program.c -o app && ./app` works
- [ ] All PUC Lua 5.5 header declarations compile against `src/lua/{lua,lauxlib,lualib,luaconf}.h`
- [ ] `tests/c_api/` — all C tests pass
- [ ] PUC Lua test suite runs through C-linked test runner
- [ ] Matrix: `python3 tools/testes_matrix.py --testc` — no regressions
- [ ] Smoke: `python3 tools/smoke_compare.py` — no regressions
- [ ] Perf: `python3 tools/perf_compare.py` — no regression (geomean within +5% of baseline)

---

## Appendix: Full Function Inventory

### PUC lua.h functions (95 total — types excluded)

| Status | Function | Phase |
|--------|----------|-------|
| ✅ | absindex | — |
| ✅ | call, callk | — |
| ✅ | close | — |
| ✅ | copy | — |
| ✅ | createtable | — |
| ✅ | error | — |
| ✅ | getallocf | — |
| ✅ | getfield | — |
| ✅ | getglobal | — |
| ✅ | getiuservalue | — |
| ✅ | getmetatable | — |
| ✅ | gettop | — |
| ✅ | insert | — |
| ✅ | next | — |
| ✅ | pcallk | — |
| ✅ | pop | — |
| ✅ | pushboolean | — |
| ✅ | pushcclosure | — |
| ✅ | pushexternalstring | — |
| ✅ | pushfstring | — |
| ✅ | pushinteger | — |
| ✅ | pushlightuserdata | — |
| ✅ | pushlstring | — |
| ✅ | pushnil | — |
| ✅ | pushnumber | — |
| ✅ | pushstring | — |
| ✅ | pushvalue | — |
| ✅ | rawget | — |
| ✅ | rawset | — |
| ✅ | remove | — |
| ✅ | rotate | — |
| ✅ | setfield | — |
| ✅ | setglobal | — |
| ✅ | setiuservalue | — |
| ✅ | setmetatable | — |
| ✅ | settop | — |
| ✅ | toboolean | — |
| ✅ | tointegerx | — |
| ✅ | tonumberx | — |
| ✅ | topointer | — |
| ✅ | touserdata | — |
| ✅ | type | — |
| ✅ | newuserdatauv | — |
| ❌ | arith | 3 |
| ❌ | atpanic | 1 |
| ❌ | checkstack | 1 |
| ❌ | closeslot | 4 |
| ❌ | closethread | 1 |
| ❌ | compare | 3 |
| ❌ | concat | 3 |
| ❌ | dump | 4 |
| ❌ | gc | 3 |
| ❌ | gethook | 8 |
| ❌ | gethookcount | 8 |
| ❌ | gethookmask | 8 |
| ❌ | geti | 2 |
| ❌ | getinfo | 8 |
| ❌ | getlocal | 8 |
| ❌ | getstack | 8 |
| ❌ | gettable | 2 |
| ❌ | getupvalue | 8 |
| ❌ | iscfunction | 1 |
| ❌ | isinteger | 1 |
| ❌ | isnumber | 1 |
| ❌ | isstring | 1 |
| ❌ | isuserdata | 1 |
| ❌ | isyieldable | 1 |
| ❌ | len | 3 |
| ❌ | load | 4 |
| ❌ | newstate | 1/9 |
| ❌ | newthread | 1 |
| ❌ | numbertocstring | 4 |
| ❌ | pushthread | 3 |
| ❌ | pushvfstring | 1 |
| ❌ | rawequal | 3 |
| ❌ | rawgeti | 2 |
| ❌ | rawgetp | 2 |
| ❌ | rawlen | 1 |
| ❌ | rawseti | 2 |
| ❌ | rawsetp | 2 |
| ❌ | resume | 3 |
| ❌ | setallocf | 4/9 |
| ❌ | sethook | 8 |
| ❌ | seti | 2 |
| ❌ | setlocal | 8 |
| ❌ | settable | 2 |
| ❌ | setupvalue | 8 |
| ❌ | setwarnf | 4 |
| ❌ | status | 3 |
| ❌ | stringtonumber | 4 |
| ❌ | tocfunction | 1 |
| ❌ | toclose | 4 |
| ❌ | tolstring | 1 |
| ❌ | tothread | 1 |
| ❌ | typename | 1 |
| ❌ | upvalueid | 4 |
| ❌ | upvaluejoin | 4 |
| ❌ | version | 1 |
| ❌ | warning | 4 |
| ❌ | xmove | 1 |
| ❌ | yieldk | 3 |

### PUC lauxlib.h functions (50 total)

| Status | Function | Phase |
|--------|----------|-------|
| ✅ | checkinteger, checklstring, checkudata, checkversion, checkversion_ | — |
| ✅ | getmetatable | — |
| ✅ | loadbufferx, loadfilex | — |
| ✅ | newlib, newmetatable, newstate | — |
| ✅ | optinteger | — |
| ✅ | ref, unref | — |
| ✅ | setfuncs, setmetatable | — |
| ✅ | testudata | — |
| ❌ | addgsub | 5/6 |
| ❌ | addlstring, addstring, addvalue | 6 |
| ❌ | alloc | 5 |
| ❌ | argerror | 5 |
| ❌ | Buffer (type) | 6 |
| ❌ | buffinit, buffinitsize | 6 |
| ❌ | callmeta | 5 |
| ❌ | checkany | 5 |
| ❌ | checknumber | 5 |
| ❌ | checkoption | 5 |
| ❌ | checkstack | 5 |
| ❌ | checktype | 5 |
| ❌ | error | 5 |
| ❌ | execresult | 5 |
| ❌ | fileresult | 5 |
| ❌ | getmetafield | 5 |
| ❌ | getsubtable | 5 |
| ❌ | gsub | 5 |
| ❌ | len | 5 |
| ❌ | loadstring | 5 |
| ❌ | makeseed | 5 |
| ❌ | optlstring | 5 |
| ❌ | optnumber | 5 |
| ❌ | prepbuffsize | 6 |
| ❌ | pushresult, pushresultsize | 6 |
| ❌ | requiref | 5 |
| ❌ | tolstring | 5 |
| ❌ | traceback | 5 |
| ❌ | typeerror | 5 |
| ❌ | where | 5 |

### PUC lualib.h functions (12 total)

| Status | Function | Phase |
|--------|----------|-------|
| ❌ | luaopen_base | 7 |
| ❌ | luaopen_coroutine | 7 |
| ❌ | luaopen_debug | 7 |
| ❌ | luaopen_io | 7 |
| ❌ | luaopen_math | 7 |
| ❌ | luaopen_os | 7 |
| ❌ | luaopen_package | 7 |
| ❌ | luaopen_string | 7 |
| ❌ | luaopen_table | 7 |
| ❌ | luaopen_utf8 | 7 |
| ❌ | luaL_openselectedlibs | 7 |
| ❌ | luaL_openlibs (macro) | 7 |
