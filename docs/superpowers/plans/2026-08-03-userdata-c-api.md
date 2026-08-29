# Userdata C API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the full userdata C API (`lua_newuserdatauv`, `lua_touserdata`, `lua_setmetatable`, etc.) so C extension libraries can create and use userdata objects through the luazig C ABI.

**Architecture:** The `Userdata` type is already a first-class GC-managed type in the `Value` union (`vm.zig:1694`). GC marking, sweeping, finalization, equality, and table-key hashing all handle `.Userdata` correctly. The gap is exclusively in the **C API layer** (`c_api.zig` + `lua.h`): the functions that C extensions call to create, access, and manipulate userdata objects are missing. This plan adds them, following the same patterns as the existing push/to functions (`lua_pushstring`, `lua_tointegerx`, etc.).

**Tech Stack:** Zig (host), C ABI for extension compatibility, PUC Lua 5.5 `lapi.c`/`lauxlib.c` as semantic reference.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/lua/lua.h` | C header: add declarations for all missing userdata API functions |
| `src/lua/lauxlib.h` | C header: add declarations for `luaL_setmetatable`, `luaL_testudata`, `luaL_checkudata`, `luaL_newmetatable`, `luaL_getmetatable`, `luaL_unref` |
| `src/lua/c_api.zig` | Implement all userdata C API functions |
| `src/lua/vm.zig` | Fix `T.totalmem("userdata")` to count real Userdata objects; add `testc_obj_userdata` counter |
| `tests/smoke/45_userdata_capi.lua` | Smoke test: load a C extension that uses `lua_newuserdatauv` |
| `lua-5.5.0/testes/libs/udatatest.c` | Minimal C extension for testing userdata round-trip |

---

## Task 1: Add `testc_obj_userdata` counter

The `allocUserdata` function (`vm.zig:3893`) already allocates Userdata objects. We need to count them for `T.totalmem("userdata")`.

**Files:**
- Modify: `src/lua/vm.zig` — add counter field, increment in `allocUserdata`, fix `builtinTestcTotalmem`

- [ ] **Step 1: Add counter field**

In `src/lua/vm.zig`, find the counter declarations around line 2211:
```zig
    testc_obj_tables: usize = 0,
    testc_obj_functions: usize = 0,
    testc_obj_threads: usize = 0,
    testc_obj_strings: usize = 0,
```
Add after `testc_obj_strings`:
```zig
    testc_obj_userdata: usize = 0,
```

- [ ] **Step 2: Increment in `allocUserdata`**

In `src/lua/vm.zig:3903`, after `try self.gcRegisterObject(.{ .userdata = ud });`, add:
```zig
        self.testc_obj_userdata += 1;
```

- [ ] **Step 3: Fix `builtinTestcTotalmem` for `"userdata"`**

In `src/lua/vm.zig`, find `builtinTestcTotalmem` (around line 27632). Replace the `"userdata"` case that returns 0 with:
```zig
                } else if (std.mem.eql(u8, name, "userdata")) {
                    outs[0] = .{ .Int = @intCast(self.testc_obj_userdata) };
```
Remove the stale comment about "luazig does not have a userdata type".

- [ ] **Step 4: Build and verify**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -3
```

Test:
```bash
cd /home/boss/codes/luazig/lua-5.5.0/testes
../../zig-out/bin/luazig --vm=bc --testc -e 'print(T.totalmem"userdata")'
```
Expected output: `0` (no userdata allocated yet, but the counter is wired).

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "vm: count Userdata objects in testc_obj_userdata counter"
```

---

## Task 2: Add `lua_newuserdatauv` and `lua_touserdata` to C API

These are the core functions: `lua_newuserdatauv` allocates a userdata object and pushes it; `lua_touserdata` returns the payload pointer.

**PUC reference:** `lapi.c:1353` (`lua_newuserdatauv`), `lapi.c:473` (`lua_touserdata`).

**Files:**
- Modify: `src/lua/lua.h` — add declarations
- Modify: `src/lua/c_api.zig` — implement

- [ ] **Step 1: Add declarations to `lua.h`**

In `src/lua/lua.h`, after the existing push function declarations (around line 127), add:
```c
/* userdata functions (PUC lua.h:130-143) */
LUA_API void *(lua_newuserdatauv) (lua_State *L, size_t sz, int nuvalue);
LUA_API void *(lua_touserdata) (lua_State *L, int idx);
LUA_API void *(lua_topointer) (lua_State *L, int idx);
LUA_API void  (lua_pushlightuserdata) (lua_State *L, void *p);
```

- [ ] **Step 2: Implement `lua_newuserdatauv` in `c_api.zig`**

In `src/lua/c_api.zig`, add after the existing `lua_pushcclosure` (around line 975):
```zig
/// PUC `lua_newuserdatauv` (lapi.c:1353): allocate a full userdata with
/// `sz` bytes of payload memory and `nuvalue` uservalues, push it onto
/// the stack, and return a pointer to the payload memory.
pub export fn lua_newuserdatauv(L: ?*lua_State, sz: usize, nuvalue: c_int) ?*anyopaque {
    const vm = L orelse return null;
    const ud = vm.allocUserdata(sz, @intCast(@max(nuvalue, 0))) catch return null;
    const val = Value{ .Userdata = ud };
    vm.c_stack.append(vm.alloc, val) catch return null;
    return @ptrCast(ud.payload.ptr);
}
```

- [ ] **Step 3: Implement `lua_touserdata` in `c_api.zig`**

```zig
/// PUC `lua_touserdata` (lapi.c:473): return the payload memory pointer
/// for a full userdata at `idx`, or the lightuserdata pointer, or NULL.
pub export fn lua_touserdata(L: ?*lua_State, idx: c_int) ?*anyopaque {
    const vm = L orelse return null;
    const v = cApiStackValue(vm, idx) orelse return null;
    return switch (v) {
        .Userdata => |ud| if (ud.payload.len > 0) @ptrCast(ud.payload.ptr) else null,
        .LightUserdata => |p| p,
        else => null,
    };
}
```

- [ ] **Step 4: Implement `lua_topointer` in `c_api.zig`**

```zig
/// PUC `lua_topointer` (lapi.c:492): return a raw pointer for
/// userdata/lightuserdata/table/thread/string values, or NULL.
pub export fn lua_topointer(L: ?*lua_State, idx: c_int) ?*anyopaque {
    const vm = L orelse return null;
    const v = cApiStackValue(vm, idx) orelse return null;
    return switch (v) {
        .Userdata => |ud| if (ud.payload.len > 0) @ptrCast(ud.payload.ptr) else null,
        .LightUserdata => |p| p,
        .Table => |t| @ptrCast(t),
        .Thread => |th| @ptrCast(th),
        .String => |s| @ptrCast(s.bytes.ptr),
        else => null,
    };
}
```

- [ ] **Step 5: Implement `lua_pushlightuserdata`**

```zig
/// PUC `lua_pushlightuserdata` (lapi.c): push a light userdata (raw pointer
/// wrapped as a Value, not GC-managed).
pub export fn lua_pushlightuserdata(L: ?*lua_State, p: ?*anyopaque) void {
    const vm = L orelse return;
    vm.c_stack.append(vm.alloc, .{ .LightUserdata = p }) catch return;
}
```

- [ ] **Step 6: Build**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
```
Fix any compile errors.

- [ ] **Step 7: Commit**

```bash
git add src/lua/lua.h src/lua/c_api.zig
git commit -m "c_api: implement lua_newuserdatauv, lua_touserdata, lua_topointer, lua_pushlightuserdata"
```

---

## Task 3: Add `lua_setmetatable` and `lua_getmetatable`

These set/get the per-object metatable on a userdata (or table). PUC: `lapi.c:964`, `lapi.c:805`.

**Files:**
- Modify: `src/lua/lua.h`, `src/lua/c_api.zig`

- [ ] **Step 1: Add declarations to `lua.h`**

```c
LUA_API int  (lua_setmetatable) (lua_State *L, int objindex);
LUA_API int  (lua_getmetatable) (lua_State *L, int objindex);
```

- [ ] **Step 2: Implement `lua_setmetatable` in `c_api.zig`**

PUC `lua_setmetatable` pops the metatable from the top of the stack and sets it on the value at `objindex`. For userdata and tables, it sets the per-object metatable and triggers GC barrier/finalizer registration.

```zig
/// PUC `lua_setmetatable` (lapi.c:964): pop a table from the stack and set
/// it as the metatable for the value at `objindex`. Returns 1 on success.
pub export fn lua_setmetatable(L: ?*lua_State, objindex: c_int) c_int {
    const vm = L orelse return 0;
    if (vm.c_stack.items.len < 1) return 0;
    const mt_val = vm.c_stack.items[vm.c_stack.items.len - 1];
    _ = vm.c_stack.pop();
    const target = cApiStackValue(vm, objindex) orelse return 0;
    const mt = if (mt_val == .Table) mt_val.Table else null;
    switch (target) {
        .Table => |t| {
            t.metatable = mt;
            if (mt) |m| {
                if (vm.metamethodValue(.{ .Table = m }, "__gc") != null) {
                    vm.registerFinalizable(.{ .table = t }) catch {};
                }
            }
        },
        .Userdata => |ud| {
            ud.metatable = mt;
            if (mt) |m| {
                if (vm.metamethodValue(.{ .Table = m }, "__gc") != null) {
                    vm.registerFinalizable(.{ .userdata = ud }) catch {};
                }
            }
        },
        else => {},
    }
    return 1;
}
```

- [ ] **Step 3: Implement `lua_getmetatable`**

PUC `lua_getmetatable` pushes the metatable of the value at `objindex` onto the stack. Returns 1 if a metatable exists, 0 otherwise.

```zig
/// PUC `lua_getmetatable` (lapi.c:805): push the metatable of the value at
/// `objindex`. Returns 1 if a metatable exists, 0 otherwise.
pub export fn lua_getmetatable(L: ?*lua_State, objindex: c_int) c_int {
    const vm = L orelse return 0;
    const v = cApiStackValue(vm, objindex) orelse return 0;
    const mt: ?*Table = switch (v) {
        .Table => |t| t.metatable,
        .Userdata => |ud| ud.metatable,
        else => null,
    };
    if (mt) |m| {
        vm.c_stack.append(vm.alloc, .{ .Table = m }) catch return 0;
        return 1;
    }
    return 0;
}
```

- [ ] **Step 4: Build**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add src/lua/lua.h src/lua/c_api.zig
git commit -m "c_api: implement lua_setmetatable and lua_getmetatable for userdata/tables"
```

---

## Task 4: Add `lua_setiuservalue` and `lua_getiuservalue`

These get/set the indexed uservalue slots on a full userdata. PUC: `lapi.c:1004`, `lapi.c:832`.

**Files:**
- Modify: `src/lua/lua.h`, `src/lua/c_api.zig`

- [ ] **Step 1: Add declarations to `lua.h`**

```c
LUA_API int  (lua_setiuservalue) (lua_State *L, int idx, int n);
LUA_API int  (lua_getiuservalue) (lua_State *L, int idx, int n);
```

- [ ] **Step 2: Implement `lua_setiuservalue`**

PUC pops a value from the stack and stores it as the `n`-th uservalue (1-based) on the userdata at `idx`.

```zig
/// PUC `lua_setiuservalue` (lapi.c:1004): pop a value from the stack and
/// store it as the n-th uservalue (1-based) on the userdata at `idx`.
/// Returns 1 on success, 0 if the value is not a userdata or n is out of range.
pub export fn lua_setiuservalue(L: ?*lua_State, idx: c_int, n: c_int) c_int {
    const vm = L orelse return 0;
    if (vm.c_stack.items.len < 1) return 0;
    const val = vm.c_stack.items[vm.c_stack.items.len - 1];
    _ = vm.c_stack.pop();
    const target = cApiStackValue(vm, idx) orelse return 0;
    switch (target) {
        .Userdata => |ud| {
            const n_idx: usize = @intCast(n - 1);
            if (n_idx >= ud.uservalues.len) return 0;
            ud.uservalues[n_idx] = val;
            return 1;
        },
        else => return 0,
    }
}
```

- [ ] **Step 3: Implement `lua_getiuservalue`**

PUC pushes the `n`-th uservalue (1-based) from the userdata at `idx`. Returns the type of the value.

```zig
/// PUC `lua_getiuservalue` (lapi.c:832): push the n-th uservalue (1-based)
/// from the userdata at `idx`. Returns the type code of the pushed value.
pub export fn lua_getiuservalue(L: ?*lua_State, idx: c_int, n: c_int) c_int {
    const vm = L orelse return 0;
    const target = cApiStackValue(vm, idx) orelse {
        vm.c_stack.append(vm.alloc, .Nil) catch {};
        return 0; // LUA_TNIL
    };
    switch (target) {
        .Userdata => |ud| {
            const n_idx: usize = @intCast(n - 1);
            if (n_idx >= ud.uservalues.len) {
                vm.c_stack.append(vm.alloc, .Nil) catch {};
                return 0;
            }
            vm.c_stack.append(vm.alloc, ud.uservalues[n_idx]) catch {};
            return typeCode(api.valueType(vm, ud.uservalues[n_idx]));
        },
        else => {
            vm.c_stack.append(vm.alloc, .Nil) catch {};
            return 0;
        },
    }
}
```

Note: `typeCode` and `api.valueType` are already defined in `c_api.zig`. If `api.valueType` takes a `*Vm` first arg, adjust accordingly — check the existing `lua_type` implementation (line 187) for the exact pattern.

- [ ] **Step 4: Build**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add src/lua/lua.h src/lua/c_api.zig
git commit -m "c_api: implement lua_setiuservalue and lua_getiuservalue"
```

---

## Task 5: Add `luaL_newmetatable`, `luaL_getmetatable`, `luaL_setmetatable`

These are the lauxlib convenience functions that C extensions use to register named metatables for their userdata types. PUC: `lauxlib.c:~310-333`.

**Files:**
- Modify: `src/lua/lauxlib.h`, `src/lua/c_api.zig`

- [ ] **Step 1: Add declarations to `lauxlib.h`**

In `src/lua/lauxlib.h`, after the existing `luaL_ref` declaration, add:
```c
LUALIB_API int  (luaL_newmetatable) (lua_State *L, const char *tname);
LUALIB_API void (luaL_getmetatable) (lua_State *L, const char *tname);
LUALIB_API void (luaL_setmetatable) (lua_State *L, const char *tname);
LUALIB_API void *(luaL_testudata) (lua_State *L, int ud, const char *tname);
LUALIB_API void *(luaL_checkudata) (lua_State *L, int ud, const char *tname);
LUALIB_API void (luaL_unref) (lua_State *L, int t, int ref);
```

- [ ] **Step 2: Implement `luaL_newmetatable`**

PUC `luaL_newmetatable`: creates a new table, stores it in the registry under key `tname`, and also sets it as a metatable entry `tname → true` so that `luaL_getmetatable` can find it. Returns 1.

PUC uses the registry (`LUA_REGISTRYINDEX`) which in luazig maps to a special table. Check how `luaL_ref` accesses the registry (around line 922 in `c_api.zig`) for the pattern.

```zig
/// PUC `luaL_newmetatable` (lauxlib.c:310): create a new table, store it
/// in the registry under key `tname`, and also set `registry[tname] = true`.
/// Returns 1 always.
pub export fn luaL_newmetatable(L: ?*lua_State, tname: [*:0]const u8) c_int {
    const vm = L orelse return 0;
    // Push registry table onto c_stack
    _ = lua_rawgeti(L, LUA_REGISTRYINDEX, 0); // Hmm — need registry access pattern
    // Actually, PUC does:
    //   lua_newtable(L);  // new metatable
    //   lua_pushvalue(L, -1);
    //   lua_setfield(L, LUA_REGISTRYINDEX, tname);
    // But luazig's registry access may differ. Check luaL_ref implementation.
    // For now, create the metatable and store it:
    const mt = vm.alloc.create(Table) catch return 0;
    mt.* = .{};
    vm.registerFinalizable(.{ .table = mt }) catch {};
    // Store in registry under tname. The registry is typically io_tbl-like:
    // lua_setfield(L, LUA_REGISTRYINDEX, tname)
    // Need to check how registry works in luazig.
    vm.c_stack.append(vm.alloc, .{ .Table = mt }) catch {};
    return 1;
}
```

**IMPORTANT:** The above is a sketch. You MUST check how the registry is accessed in luazig. Look at:
- `luaL_ref` implementation in `c_api.zig` (around line 922) — it accesses a registry-like table
- `LUA_REGISTRYINDEX` constant — is it defined in `lua.h`?
- How `luaL_setfuncs` (line 722) pushes hidden tables

Adjust the implementation to match luazig's registry pattern. The goal: store the metatable in the registry under `tname`, push it onto the stack.

- [ ] **Step 3: Implement `luaL_getmetatable`**

```zig
/// PUC `luaL_getmetatable` (lauxlib.c:318): push the metatable previously
/// stored in the registry under `tname`.
pub export fn luaL_getmetatable(L: ?*lua_State, tname: [*:0]const u8) void {
    const vm = L orelse return;
    // Get from registry: lua_getfield(L, LUA_REGISTRYINDEX, tname)
    // Adjust to match luazig's registry access pattern.
}
```

- [ ] **Step 4: Implement `luaL_setmetatable`**

```zig
/// PUC `luaL_setmetatable` (lauxlib.c:330): get the metatable from the
/// registry by name and set it on the value at the top of the stack.
pub export fn luaL_setmetatable(L: ?*lua_State, tname: [*:0]const u8) void {
    luaL_getmetatable(L, tname);
    lua_setmetatable(L, -2);
}
```

- [ ] **Step 5: Implement `luaL_testudata`**

PUC `luaL_testudata`: check if the value at `ud` is a userdata whose metatable matches the one registered under `tname`. Returns the payload pointer, or NULL.

```zig
/// PUC `luaL_testudata` (lauxlib.c:336): check if value at `ud` is a userdata
/// with metatable `tname`. Returns payload pointer, or NULL.
pub export fn luaL_testudata(L: ?*lua_State, ud: c_int, tname: [*:0]const u8) ?*anyopaque {
    const vm = L orelse return null;
    const v = cApiStackValue(vm, ud) orelse return null;
    if (v != .Userdata) return null;
    // Get expected metatable from registry
    luaL_getmetatable(L, tname);
    const expected_mt = vm.c_stack.popOrNull() orelse return null;
    defer _ = expected_mt;
    const expected_tbl = if (expected_mt == .Table) expected_mt.Table else return null;
    if (v.Userdata.metatable != expected_tbl) return null;
    return if (v.Userdata.payload.len > 0) @ptrCast(v.Userdata.payload.ptr) else null;
}
```

- [ ] **Step 6: Implement `luaL_checkudata`**

```zig
/// PUC `luaL_checkudata` (lauxlib.c:351): like `luaL_testudata` but raises
/// an error on mismatch.
pub export fn luaL_checkudata(L: ?*lua_State, ud: c_int, tname: [*:0]const u8) ?*anyopaque {
    if (luaL_testudata(L, ud, tname)) |p| return p;
    // Raise type error
    const vm = L orelse return null;
    _ = vm.fail("bad argument #{d} ({s} expected, got {s})", .{ ud, std.mem.span(tname), "wrong type" }) catch {};
    return null;
}
```

- [ ] **Step 7: Implement `luaL_unref`**

```zig
/// PUC `luaL_unref` (lauxlib.c:714): release reference `ref` from the
/// table at index `t`.
pub export fn luaL_unref(L: ?*lua_State, t: c_int, ref: c_int) void {
    const vm = L orelse return;
    // PUC: lua_rawgeti(L, t, 0) to get the free list, then
    // lua_pushinteger(L, ref_table[ref]); lua_rawseti(L, -2, ref)
    // Simplified: find the registry table at `t`, set t[ref] = t[0], t[0] = ref
    // Adjust to match luazig's luaL_ref pattern.
    _ = vm;
    _ = t;
    _ = ref;
}
```

- [ ] **Step 8: Build**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
```

- [ ] **Step 9: Commit**

```bash
git add src/lua/lauxlib.h src/lua/c_api.zig
git commit -m "c_api: implement luaL_newmetatable, luaL_getmetatable, luaL_setmetatable, luaL_testudata, luaL_checkudata, luaL_unref"
```

---

## Task 6: Write C extension test and smoke test

Create a minimal C extension that exercises the userdata API, compile it against luazig headers, and write a Lua smoke test that loads it.

**Files:**
- Create: `lua-5.5.0/testes/libs/udatatest.c`
- Create: `tests/smoke/45_userdata_capi.lua`

- [ ] **Step 1: Create the C extension**

`lua-5.5.0/testes/libs/udatatest.c`:
```c
#include "lua.h"
#include "lauxlib.h"

typedef struct {
    int x;
    int y;
} Point;

static int new_point(lua_State *L) {
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    Point *p = (Point *)lua_newuserdatauv(L, sizeof(Point), 0);
    p->x = x;
    p->y = y;
    luaL_setmetatable(L, "Point");
    return 1;
}

static int point_getx(lua_State *L) {
    Point *p = (Point *)luaL_checkudata(L, 1, "Point");
    lua_pushinteger(L, p->x);
    return 1;
}

static int point_gety(lua_State *L) {
    Point *p = (Point *)luaL_checkudata(L, 1, "Point");
    lua_pushinteger(L, p->y);
    return 1;
}

static int point_gc(lua_State *L) {
    /* In a real extension, this would free resources */
    return 0;
}

static int point_tostring(lua_State *L) {
    Point *p = (Point *)luaL_checkudata(L, 1, "Point");
    lua_pushfstring(L, "Point(%d, %d)", (int)p->x, (int)p->y);
    return 1;
}

static const luaL_Reg point_methods[] = {
    {"getx", point_getx},
    {"gety", point_gety},
    {"__gc", point_gc},
    {"__tostring", point_tostring},
    {NULL, NULL}
};

LUAMOD_API int luaopen_udatatest(lua_State *L) {
    luaL_newmetatable(L, "Point");
    luaL_setfuncs(L, point_methods, 0);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, new_point);
    lua_setglobal(L, "newpoint");
    return 0;
}
```

- [ ] **Step 2: Compile the C extension**

```bash
cd /home/boss/codes/luazig/lua-5.5.0/testes/libs
gcc -Wall -O2 -I../../../src -fPIC -shared -o udatatest.so udatatest.c
```

- [ ] **Step 3: Write the smoke test**

`tests/smoke/45_userdata_capi.lua`:
```lua
-- Smoke test: C extension userdata round-trip via C API
package.cpath = package.cpath .. ";./libs/?.so"
package.path = package.path .. ";./libs/?.lua"

-- Load the C extension
require("udatatest")

-- Create a userdata via C API
local p = newpoint(10, 20)
assert(type(p) == "userdata", "expected userdata, got " .. type(p))

-- Access payload via C methods
assert(p:getx() == 10, "getx should return 10")
assert(p:gety() == 20, "gety should return 20")

-- tostring should use __tostring metamethod
local s = tostring(p)
assert(s == "Point(10, 20)", "tostring should be 'Point(10, 20)', got " .. s)

-- T.totalmem should report userdata objects
local T = require "T"
if T then
    local count = T.totalmem("userdata")
    assert(count > 0, "T.totalmem('userdata') should be > 0, got " .. tostring(count))
end

-- GC should collect userdata (no crash)
p = nil
collectgarbage("collect")

print("userdata-capi-ok")
```

- [ ] **Step 4: Run the smoke test**

```bash
cd /home/boss/codes/luazig/lua-5.5.0/testes
../../zig-out/bin/luazig --vm=bc --testc ../../tests/smoke/45_userdata_capi.lua
```

Expected: `userdata-capi-ok`

- [ ] **Step 5: Fix any issues**

If the test fails, debug:
- Is `luaL_newmetatable` storing the metatable correctly?
- Is `luaL_checkudata` finding it?
- Is `luaL_setfuncs` registering methods correctly?
- Is `lua_setfield` / `lua_getfield` working?

- [ ] **Step 6: Commit**

```bash
git add lua-5.5.0/testes/libs/udatatest.c tests/smoke/45_userdata_capi.lua
git commit -m "test: add C extension userdata round-trip smoke test"
```

---

## Task 7: Update README and AGENTS.md

- [ ] **Step 1: Update README**

Add to the appropriate section of `README.md`:
- Userdata C API (`lua_newuserdatauv`, `lua_touserdata`, `lua_setmetatable`, `luaL_checkudata`, etc.) is now implemented
- C extensions can create and use userdata objects through the luazig C ABI
- `T.totalmem("userdata")` reports the correct count

- [ ] **Step 2: Remove the stale comment in `builtinTestcTotalmem`**

If not already done in Task 1, remove the comment claiming "luazig does not have a userdata type".

- [ ] **Step 3: Run full regression**

```bash
cd /home/boss/codes/luazig
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
for f in tests/smoke/*.lua; do timeout 10 ./zig-out/bin/luazig --vm=bc "$f" 2>&1 | tail -1; done
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document userdata C API support"
```

---

## Future Work (NOT in this plan)

The following are documented as follow-up items but are explicitly **out of scope** for this plan:

1. **Convert file handles from Tables to real Userdata** — `io.open`, `io.popen`, `io.tmpfile` currently create Tables with `__file_id`. Converting to Userdata requires changing `asFileTable`, `getManagedFile`, `getFileBuffer`, and all file methods. This is a separate large refactoring task.

2. **Remove `asFileTable`/`isFileUserdata` workaround** — Once file handles are real Userdata, the `type()` workaround for Tables with `__name = "FILE*"` can be removed.

3. **`luaL_argerror` / `luaL_typeerror`** — Full argument error formatting. Currently `luaL_checkudata` uses a simplified error message.
