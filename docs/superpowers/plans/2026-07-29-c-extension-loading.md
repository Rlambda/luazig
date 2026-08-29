# C Extension Loading: dlopen + C API + External Strings

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement PUC-faithful C extension loading (`package.loadlib` via dlopen) with a C API shim that lets loaded `.so` functions interact with the VM, plus `lua_pushexternalstring` for PUC 5.5 external string support.

**Architecture:** C functions receive `*Vm` as `lua_State*`. A `c_stack` field on Vm provides the C API push/pop area. A 5-line C file (`src/c/cfunc_wrap.c`) provides the setjmp/longjmp boundary for `lua_error`. External strings add a content pointer + dealloc callback to `LuaString`, branched in `bytes()` and `destroyLuaString`.

**Tech Stack:** Zig (master), `std.DynLib` (dlopen), C `setjmp.h` (error boundary), PUC Lua 5.5 C API (`lua.h`/`lauxlib.h`).

---

## Background

### What PUC Does

PUC Lua loads C extensions at runtime via `dlopen`. A `.so` file exports `luaopen_<name>` which receives `lua_State *L` and returns a table. The C function uses PUC's C API (lua_push*, lua_get*, etc.) to interact with the VM. Error handling uses `setjmp`/`longjmp` — `lua_error` is `noreturn`.

### The Architecture Gap

luazig's `api.State` (src/lua/api.zig:44) owns the Vm by value and has its own separate stack. C functions need direct access to a running Vm. The fix: add `c_stack` to Vm, make `lua_State = *Vm`, and rewrite the C API shim to operate on Vm directly.

### longjmp

PUC's `lua_error` calls `longjmp` to abort the C function. Zig code cannot do this safely. A 5-line C wrapper (`src/c/cfunc_wrap.c`) provides the setjmp/longjmp boundary: Zig calls `wrap_cfunc(f, L, jb)`, which either returns normally (success) or returns -1 (lua_error longjmp'd back to setjmp).

---

## File Structure

### Files to Create

- **`src/c/cfunc_wrap.c`** — setjmp/longjmp boundary (5 lines)
- **`src/lua/lua.h`** — minimal C header for compiling test libraries with zig cc
- **`src/lua/lauxlib.h`** — minimal auxlib header

### Files to Modify

- **`src/lua/vm.zig`** — `Vm.c_stack` field, `Closure.c_func`, `LuaString` external string fields, C function call dispatch, `gcFreeObject`/`destroyLuaString` for external strings, `package.loadlib` implementation
- **`src/lua/c_api.zig`** — rewrite to use `*Vm` instead of `*api.State`, add ~15 missing API functions
- **`src/lua/api.zig`** — minor: add `cApiStackTop`/`cApiPush` helpers if needed
- **`build.zig`** — link libc on executables, compile `cfunc_wrap.c`

---

## Part A: C API Foundation

### Task A1: Add `c_stack` to Vm and rewrite C API shim

**Files:**
- Modify: `src/lua/vm.zig` — Vm struct (~line 1700), add `c_stack` field
- Modify: `src/lua/c_api.zig` — rewrite all export functions to use `*Vm`
- Modify: `build.zig` — add `link_libc = true` to executables

- [ ] **Step 1: Add `c_stack` field to Vm**

In `src/lua/vm.zig`, add near the other stack fields (~line 1990):

```zig
    /// C API stack for lua_State-compatible push/pop operations.
    /// Used by C extension functions loaded via package.loadlib.
    /// Separate from bc_stack (bytecode registers) — mirrors PUC's
    /// separation of L->stack (C API) from VM-internal state.
    c_stack: std.ArrayListUnmanaged(Value) = .empty,
```

- [ ] **Step 2: Change `lua_State` type in c_api.zig**

In `src/lua/c_api.zig`, change:
```zig
pub const lua_State = api.State;
```
to:
```zig
pub const lua_State = @import("vm.zig").Vm;
```

- [ ] **Step 3: Rewrite existing export functions to use `*Vm`**

Each existing function changes from `st.gettop()` / `st.pushinteger(v)` to `vm.c_stack.items.len` / `vm.c_stack.append(vm.alloc, .{ .Int = v })`. Example for `lua_gettop`:

```zig
export fn lua_gettop(L: ?*lua_State) c_int {
    const vm = L orelse return 0;
    return @intCast(vm.c_stack.items.len);
}
```

Rewrite ALL ~20 existing functions following this pattern:
- `lua_gettop` → `vm.c_stack.items.len`
- `lua_settop` → set `vm.c_stack.items.len`
- `lua_pop` → truncate `vm.c_stack.items.len`
- `lua_pushnil` → append `.Nil`
- `lua_pushboolean` → append `.Bool`
- `lua_pushinteger` → append `.Int`
- `lua_pushnumber` → append `.Num`
- `lua_pushstring` → intern + append `.String`
- `lua_type` → read `vm.c_stack` at index, return type code
- `lua_toboolean` → read + return bool
- `lua_tointegerx` → read + return int
- `lua_tonumberx` → read + return num
- `lua_getglobal` → `vm.getGlobal(name)` + push to c_stack
- `lua_setglobal` → pop from c_stack + `vm.setGlobal`
- `lua_next` → table iteration on c_stack
- `luaL_loadbufferx` → compile + push closure to c_stack
- `luaL_loadfilex` → loadfile + push to c_stack
- `lua_pcallk` → pop from c_stack, call via VM, push results to c_stack

- [ ] **Step 4: Add c_stack deinit to Vm.deinit**

In `Vm.deinit` (~line 2509), add:
```zig
        self.c_stack.deinit(self.alloc);
```

- [ ] **Step 5: Link libc on executables in build.zig**

In `build.zig`, after creating `luazig_exe` (line 20-31), add:
```zig
    luazig_exe.root_module.link_libc = true;
```
Do the same for `luazigc_exe`.

- [ ] **Step 6: Build and verify**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: BUILD SUCCESS

- [ ] **Step 7: Commit**

```bash
git add src/lua/vm.zig src/lua/c_api.zig build.zig
git commit -m "C API: add c_stack to Vm, rewrite shim to use *Vm directly"
```

---

### Task A2: Add missing C API functions

**Files:**
- Modify: `src/lua/c_api.zig` — add ~15 new export functions

- [ ] **Step 1: Add stack manipulation functions**

```zig
export fn lua_pushvalue(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    const i = cAbsIndex(idx, top) orelse return;
    vm.c_stack.append(vm.alloc, vm.c_stack.items[i]) catch {};
}

export fn lua_insert(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    if (top == 0) return;
    const i = cAbsIndex(idx, top) orelse return;
    const val = vm.c_stack.items[top - 1];
    var j = top - 1;
    while (j > i) : (j -= 1) vm.c_stack.items[j] = vm.c_stack.items[j - 1];
    vm.c_stack.items[i] = val;
}

export fn lua_remove(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    const i = cAbsIndex(idx, top) orelse return;
    var j = i;
    while (j < top - 1) : (j += 1) vm.c_stack.items[j] = vm.c_stack.items[j + 1];
    vm.c_stack.items.len -= 1;
}

export fn lua_rotate(L: ?*lua_State, idx: c_int, n: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    const i = cAbsIndex(idx, top) orelse return;
    const n_items = top - i;
    if (n_items == 0) return;
    const shift: i64 = @rem(@as(i64, n), @as(i64, @intCast(n_items)));
    const k: usize = if (shift < 0) @intCast(shift + @as(i64, @intCast(n_items))) else @intCast(shift);
    // Rotate: move last k items to front of [i..top)
    std.mem.rotate(@import("vm.zig").Value, vm.c_stack.items[i..top], k);
}
```

Add helper `cAbsIndex`:
```zig
fn cAbsIndex(idx: c_int, top: usize) ?usize {
    if (idx > 0) {
        const i: usize = @intCast(idx - 1);
        return if (i < top) i else null;
    } else if (idx < 0) {
        const r: usize = @intCast(-idx);
        return if (r <= top) top - r else null;
    }
    return null;
}
```

- [ ] **Step 2: Add table creation and field access functions**

```zig
export fn lua_createtable(L: ?*lua_State, narr: c_int, nrec: c_int) void {
    _ = narr; _ = nrec;
    const vm = L orelse return;
    const t = vm.allocTableNoGc();
    vm.c_stack.append(vm.alloc, .{ .Table = t }) catch {};
}

export fn lua_setfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    if (top == 0) return;
    const i = cAbsIndex(idx, top) orelse return;
    const tbl = vm.c_stack.items[i];
    if (tbl != .Table) return;
    const val = vm.c_stack.items[top - 1];
    vm.c_stack.items.len -= 1;
    const name = std.mem.span(k);
    vm.rawSet(tbl.Table, .{ .String = vm.internStrAssume(name) }, val) catch {};
}

export fn lua_getfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    const i = cAbsIndex(idx, top) orelse return;
    const tbl = vm.c_stack.items[i];
    if (tbl != .Table) { vm.c_stack.append(vm.alloc, .Nil) catch {}; return; }
    const name = std.mem.span(k);
    const v = vm.rawGet(tbl.Table, .{ .String = vm.internStrAssume(name) });
    vm.c_stack.append(vm.alloc, v) catch {};
}

export fn lua_rawset(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    if (top < 3) return;
    const i = cAbsIndex(idx, top) orelse return;
    const tbl = vm.c_stack.items[i];
    if (tbl != .Table) { vm.c_stack.items.len -= 2; return; }
    const key = vm.c_stack.items[top - 2];
    const val = vm.c_stack.items[top - 1];
    vm.c_stack.items.len -= 2;
    vm.rawSet(tbl.Table, key, val) catch {};
}

export fn lua_rawget(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    if (top < 2) return;
    const i = cAbsIndex(idx, top) orelse return;
    const tbl = vm.c_stack.items[i];
    const key = vm.c_stack.items[top - 1];
    vm.c_stack.items.len -= 1;
    if (tbl != .Table) { vm.c_stack.append(vm.alloc, .Nil) catch {}; return; }
    const v = vm.rawGet(tbl.Table, key);
    vm.c_stack.append(vm.alloc, v) catch {};
}
```

- [ ] **Step 3: Add string functions**

```zig
export fn lua_pushlstring(L: ?*lua_State, s: [*]const u8, len: usize) void {
    const vm = L orelse return;
    const str = vm.internStr(s[0..len]) catch return;
    vm.c_stack.append(vm.alloc, .{ .String = str }) catch {};
}

export fn lua_pushliteral(L: ?*lua_State, s: [*:0]const u8) void {
    lua_pushstring(L, s);
}

export fn luaL_checklstring(L: ?*lua_State, arg: c_int, l: ?*usize) [*:0]const u8 {
    _ = l;
    const vm = L orelse return "";
    const top = vm.c_stack.items.len;
    const i = cAbsIndex(arg, top) orelse return "";
    const v = vm.c_stack.items[i];
    return switch (v) {
        .String => |s| @ptrCast(@constCast(s.bytes().ptr)),
        else => "",
    };
}
```

NOTE: `luaL_checklstring` returns `[*:0]const u8` for simplicity. The length is written to `l` if non-null. The actual PUC signature returns `const char*` and sets `*l`.

- [ ] **Step 4: Add registration functions**

```zig
const luaL_Reg = extern struct {
    name: ?[*:0]const u8,
    func: ?*const fn(?*lua_State) callconv(.C) c_int,
};

export fn luaL_setfuncs(L: ?*lua_State, reg: [*]const luaL_Reg, nup: c_int) void {
    const vm = L orelse return;
    // Stack: [table, upvalues...] — table is at top - nup
    const top = vm.c_stack.items.len;
    const nupu: usize = @intCast(nup);
    const tbl_idx = top - nupu - 1;
    var i: usize = 0;
    while (reg[i].name != null) : (i += 1) {
        const name = std.mem.span(reg[i].name.?);
        // Create C closure with upvalues
        const cl = vm.alloc.create(@import("vm.zig").Closure) catch return;
        cl.* = .{
            .upvalues = &.{},
            .c_func = reg[i].func,
        };
        vm.gcRegisterClosure(cl) catch {};
        // Set table[name] = closure
        vm.rawSet(vm.c_stack.items[tbl_idx].Table, vm.internStrAssume(name), .{ .Closure = cl }) catch {};
    }
    // Pop upvalues
    vm.c_stack.items.len -= nupu;
}

export fn luaL_newlib(L: ?*lua_State, reg: [*]const luaL_Reg) void {
    lua_createtable(L, 0, 0);
    luaL_setfuncs(L, reg, 0);
}
```

- [ ] **Step 5: Add misc functions**

```zig
export fn luaL_checkversion(L: ?*lua_State) void {
    _ = L; // no-op — version check always passes
}

export fn lua_pushfstring(L: ?*lua_State, fmt: [*:0]const u8, ...) void {
    // Variadic — use simple %d/%s handling
    // For now, push the format string as-is (test libs use %d%%%d\n)
    // Full implementation would parse format and substitute args
    const vm = L orelse return;
    // Note: Zig doesn't support C variadic directly. For test libs that
    // use lua_pushfstring(L, "%d%%%d\n", a, b), we need a C wrapper.
    // For now, push the format string literally.
    lua_pushstring(L, fmt);
}

export fn luaL_ref(L: ?*lua_State, t: c_int) c_int {
    // PUC luaL_ref: stores top-of-stack in table at 't', returns integer key
    const vm = L orelse return -1;
    const top = vm.c_stack.items.len;
    if (top == 0) return -1;
    const tbl_idx = cAbsIndex(t, top) orelse return -1;
    const val = vm.c_stack.items[top - 1];
    vm.c_stack.items.len -= 1;
    const tbl = vm.c_stack.items[tbl_idx];
    if (tbl != .Table) return -1;
    // Simple: use a counter-based key
    const ref_key: i64 = @intCast(vm.c_ref_counter);
    vm.c_ref_counter += 1;
    vm.rawSet(tbl.Table, .{ .Int = ref_key }, val) catch {};
    return @intCast(ref_key);
}

export fn lua_pushcfunction(L: ?*lua_State, f: ?*const fn(?*lua_State) callconv(.C) c_int) void {
    const vm = L orelse return;
    const cl = vm.alloc.create(@import("vm.zig").Closure) catch return;
    cl.* = .{ .upvalues = &.{}, .c_func = f };
    vm.gcRegisterClosure(cl) catch {};
    vm.c_stack.append(vm.alloc, .{ .Closure = cl }) catch {};
}
```

Add `c_ref_counter: i64 = 0` to Vm.

- [ ] **Step 6: Build**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: BUILD SUCCESS (fix compilation errors as needed)

- [ ] **Step 7: Commit**

```bash
git add src/lua/vm.zig src/lua/c_api.zig
git commit -m "C API: add missing functions (pushvalue, setfield, newlib, etc.)"
```

---

## Part B: C Function Calling

### Task B1: Add `c_func` to Closure and call dispatch

**Files:**
- Modify: `src/lua/vm.zig` — Closure struct, call dispatch

- [ ] **Step 1: Add `c_func` field to Closure**

In Closure struct (vm.zig:515):
```zig
pub const Closure = struct {
    gc_age: GcAge = .new,
    gc_index: usize = 0,
    gc_seq: u64 = 0,
    gc_marked: u8 = 0,
    proto: ?*const bc.Proto = null,
    upvalues: []const *Cell,
    env_override: ?Value = null,
    /// C function pointer (PUC CClosure.f). Non-null when this is a C
    /// closure loaded via package.loadlib. When non-null, proto is null.
    c_func: ?*const fn (*Vm) callconv(.C) c_int = null,
    /// Optional dlopen handle for dlclose on GC (PUC doesn't dlclose;
    /// we do for cleanliness).
    lib_handle: ?*anyopaque = null,
};
```

- [ ] **Step 2: Detect C closures at call sites**

Search for where `Value.Closure` is resolved for calling. Key sites:
- `resolveCallable` (~line 5770) — resolves callable values
- `opCall` (~line 9847) — OP_CALL handler
- `builtinRequire` (~line 16143) — require calls loaders

At each site where a Closure is called, check `cl.c_func`:
```zig
if (cl.c_func) |cf| {
    // C function closure — call via C wrapper
    return try self.callCFunctionClosure(cf, cl);
}
// Otherwise: normal bytecode closure
```

- [ ] **Step 3: Implement `callCFunctionClosure`**

```zig
fn callCFunctionClosure(self: *Vm, f: *const fn(*Vm) callconv(.C) c_int, cl: *Closure) DispatchError!void {
    // Marshal c_stack: push the closure itself + any upvalues
    // (PUC pushes the function + args before calling)
    // For luaopen_*: c_stack already has [modname, filepath]
    
    // Clear c_stack state (caller sets up arguments)
    // Save current c_stack length
    const saved_c_stack_top = self.c_stack.items.len;
    
    // Call C function via setjmp/longjmp wrapper
    const result = callCFunctionWithBoundary(self, f);
    
    if (result < 0) {
        // lua_error was called — RuntimeError
        return error.RuntimeError;
    }
    
    // result = number of return values on c_stack
    const nresults: usize = @intCast(result);
    const ret_start = self.c_stack.items.len - nresults;
    // TODO: marshal return values from c_stack to the caller's output
    // For require: read the table from c_stack and return it
    
    _ = ret_start;
    _ = saved_c_stack_top;
}
```

NOTE: The exact marshaling depends on the call context. For `require`, the return value is a table on c_stack. For general calls, we need to bridge c_stack return values to bc_stack output slots.

- [ ] **Step 4: Build**

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "C function calling: c_func field on Closure, call dispatch"
```

---

### Task B2: Create setjmp/longjmp C wrapper

**Files:**
- Create: `src/c/cfunc_wrap.c`
- Modify: `build.zig` — compile the C file

- [ ] **Step 1: Create the C wrapper**

Create `src/c/cfunc_wrap.c`:
```c
#include <setjmp.h>

/* Wrap a C function call with setjmp/longjmp error boundary.
 * Returns: the C function's return value (>=0, number of results),
 *          or -1 if lua_error was called (longjmp landed here).
 * The jmp_buf is stored on the Vm via a pointer field.
 */
typedef int (*cfunc_t)(void *L);
typedef void (*errfn_t)(void *L);

int wrap_cfunc(cfunc_t f, void *L, jmp_buf *jb) {
    if (setjmp(*jb) == 0) {
        return f(L);
    }
    return -1;  /* lua_error longjmp'd back */
}
```

- [ ] **Step 2: Declare extern in vm.zig**

```zig
const JmpBuf = [64]usize; // platform-specific, opaque
extern fn wrap_cfunc(f: *const fn(*Vm) callconv(.C) c_int, L: *Vm, jb: *JmpBuf) c_int;
```

- [ ] **Step 3: Implement the call with boundary**

```zig
fn callCFunctionWithBoundary(self: *Vm, f: *const fn(*Vm) callconv(.C) c_int) i32 {
    var jb: JmpBuf = undefined;
    const prev = self.c_error_jmp;
    self.c_error_jmp = &jb;
    defer self.c_error_jmp = prev;
    return wrap_cfunc(f, self, &jb);
}
```

Add to Vm: `c_error_jmp: ?*anyopaque = null,` (stores `*JmpBuf` as opaque pointer).

- [ ] **Step 4: Implement `lua_error`**

In `c_api.zig`:
```zig
extern fn longjmp(env: *anyopaque, val: c_int) noreturn;

export fn lua_error(L: ?*lua_State) noreturn {
    const vm = L orelse @panic("lua_error: null state");
    // Capture error message from c_stack
    if (vm.c_stack.items.len > 0) {
        const errval = vm.c_stack.items[vm.c_stack.items.len - 1];
        // TODO: set vm.err from errval
    }
    if (vm.c_error_jmp) |jb| {
        longjmp(jb, 1);
    }
    @panic("lua_error without C function context");
}
```

- [ ] **Step 5: Add `lua_call`**

```zig
export fn lua_call(L: ?*lua_State, nargs: c_int, nresults: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    const func_idx = top - @as(usize, @intCast(nargs)) - 1;
    const func = vm.c_stack.items[func_idx];
    // TODO: call the function via VM, handle results
    // For now, this is a simplified version that handles Closure calls
}
```

- [ ] **Step 6: Compile cfunc_wrap.c in build.zig**

In `build.zig`, add:
```zig
    luazig_exe.addCSourceFile(.{
        .file = b.path("src/c/cfunc_wrap.c"),
        .flags = &.{},
    });
```

- [ ] **Step 7: Build and test**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5`

- [ ] **Step 8: Commit**

```bash
git add src/c/cfunc_wrap.c src/lua/vm.zig src/lua/c_api.zig build.zig
git commit -m "longjmp boundary: C wrapper for lua_error, setjmp in cfunc_wrap.c"
```

---

## Part C: package.loadlib

### Task C1: Implement package.loadlib via std.DynLib

**Files:**
- Modify: `src/lua/vm.zig` — replace stub `package_loadlib` builtin

- [ ] **Step 1: Replace the loadlib stub**

Find `builtinPackageLoadlib` or the `package.loadlib` handler (the stub we added earlier). Replace with:

```zig
fn builtinPackageLoadlib(self: *Vm, args: []const Value, outs: []Value) DispatchError!void {
    if (args.len < 2) {
        if (outs.len > 0) outs[0] = .Nil;
        return;
    }
    const lib_path = switch (args[0]) {
        .String => |s| s.bytes(),
        else => { if (outs.len > 0) outs[0] = .Nil; return; },
    };
    const func_name = switch (args[1]) {
        .String => |s| s.bytes(),
        else => { if (outs.len > 0) outs[0] = .Nil; return; },
    };

    // PUC loadlib with "*" checks if the library exists
    if (std.mem.eql(u8, func_name, "*")) {
        // Try to open the library
        const lib = std.DynLib.open(lib_path) catch {
            if (outs.len > 0) outs[0] = .Nil;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr("cannot open library") };
            if (outs.len > 2) outs[2] = .{ .String = try self.internStr("open") };
            self.last_builtin_out_count = @min(outs.len, 3);
            return;
        };
        lib.close();
        // Return a dummy function (the library can be opened)
        if (outs.len > 0) {
            const cl = try self.alloc.create(Closure);
            cl.* = .{ .upvalues = &.{}, .c_func = &dummyLoadlibFunc };
            try self.gcRegisterClosure(cl);
            outs[0] = .{ .Closure = cl };
        }
        self.last_builtin_out_count = @min(outs.len, 1);
        return;
    }

    // Normal loadlib: open library, look up function
    const lib = std.DynLib.open(lib_path) catch {
        if (outs.len > 0) outs[0] = .Nil;
        if (outs.len > 1) outs[1] = .{ .String = try self.internStr("cannot load library") };
        if (outs.len > 2) outs[2] = .{ .String = try self.internStr("absent") };
        self.last_builtin_out_count = @min(outs.len, 3);
        return;
    };

    // Look up lua_CFunction
    const c_func = lib.lookup(*const fn(*Vm) callconv(.C) c_int, func_name) orelse {
        lib.close();
        if (outs.len > 0) outs[0] = .Nil;
        if (outs.len > 1) outs[1] = .{ .String = try self.internStr("symbol not found") };
        if (outs.len > 2) outs[2] = .{ .String = try self.internStr("init") };
        self.last_builtin_out_count = @min(outs.len, 3);
        return;
    };

    // Create a C closure wrapping the function
    const cl = try self.alloc.create(Closure);
    cl.* = .{ .upvalues = &.{}, .c_func = c_func };
    try self.gcRegisterClosure(cl);
    if (outs.len > 0) outs[0] = .{ .Closure = cl };
    self.last_builtin_out_count = @min(outs.len, 1);

    // Note: we intentionally leak the DynLib handle (don't dlclose).
    // The .so stays loaded for the process lifetime. This matches
    // PUC behavior (PUC never dlclose's).
}
```

NOTE: The `dummyLoadlibFunc` for the `"*"` probe is a no-op C function. The actual function lookup happens on the second call with the real function name.

Also note: `std.DynLib.lookup` returns a pointer with a specific calling convention. The type must match our `Closure.c_func` field type. On some platforms, C calling convention differences may need adjustment.

- [ ] **Step 2: Wire require to use C library search**

In `builtinRequire`, after the Lua path search fails, add C path search:

```zig
// C library search (PUC ll_require searcher_C path)
if (cpath.len > 0) {
    try self.builtinPackageSearchpath(&[_]Value{.{.String = try self.internStr(name)}, .{.String = try self.internStr(cpath)}}, searchpath_out[0..]);
    if (searchpath_out[0] == .String) {
        const c_file_path = searchpath_out[0].String.bytes();
        const open_name = try std.fmt.allocPrint(self.alloc, "luaopen_{s}", .{name});
        defer self.alloc.free(open_name);
        // Replace dots with underscores (PUC: "a.b" → "luaopen_a_b")
        const mangled = try self.alloc.dupe(u8, open_name);
        defer self.alloc.free(mangled);
        for (mangled) |*ch| if (ch.* == '.') { ch.* = '_'; };
        
        var loadlib_outs: [3]Value = .{ .Nil, .Nil, .Nil };
        try self.builtinPackageLoadlib(
            &[_]Value{ .{ .String = try self.internStr(c_file_path) }, .{ .String = try self.internStr(mangled) } },
            loadlib_outs[0..],
        );
        if (loadlib_outs[0] == .Closure) {
            const cl = loadlib_outs[0].Closure;
            // Call luaopen_* with (modname, filepath) on c_stack
            self.c_stack.clearRetainingCapacity();
            try self.c_stack.append(self.alloc, .{ .String = try self.internStr(name) });
            try self.c_stack.append(self.alloc, .{ .String = try self.internStr(c_file_path) });
            const result = self.callCFunctionWithBoundary(cl.c_func.?);
            if (result < 0) return error.RuntimeError;
            // Read result from c_stack
            const nret: usize = @intCast(result);
            const ret_val = if (nret > 0) self.c_stack.items[self.c_stack.items.len - nret] else .{ .Bool = true };
            try self.setField(loaded_tbl, name, ret_val);
            outs[0] = ret_val;
            if (outs.len > 1) outs[1] = .{ .String = try self.internStr(c_file_path) };
            return;
        }
    }
}
```

- [ ] **Step 3: Build**

- [ ] **Step 4: Test basic loadlib**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast
cd lua-5.5.0/testes && ../../zig-out/bin/luazig --testc -e '
local f = package.loadlib("./libs/lib1.so", "onefunction")
print("loadlib result:", type(f))
' 2>&1
```

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "package.loadlib: real dlopen via std.DynLib, C path search in require"
```

---

## Part D: External Strings

### Task D1: Add external string support to LuaString

**Files:**
- Modify: `src/lua/vm.zig` — LuaString struct, bytes(), destroyLuaString, gcFreeObject

- [ ] **Step 1: Add external string fields to LuaString**

```zig
pub const LuaString = struct {
    hash: u64,
    len: usize,
    is_short: bool,
    gc_marked: u8 = 0,
    gc_age: GcAge = .new,
    gc_index: usize = 0,
    gc_seq: u64 = 0,
    /// External string support (PUC 5.5 LSTRMEM/LSTRFIX).
    /// When true, content lives in external_ptr (not inline after header).
    is_external: bool = false,
    /// Pointer to external content (valid only when is_external).
    external_ptr: [*]const u8 = &.{},
    /// Dealloc callback (PUC falloc). null = fixed (no dealloc).
    falloc: ?*const fn (?*anyopaque, ?*anyopaque, usize, usize) ?*anyopaque = null,
    /// User data for dealloc callback (PUC ud).
    falloc_ud: ?*anyopaque = null,

    pub fn bytes(self: *const LuaString) []const u8 {
        if (self.is_external) {
            return self.external_ptr[0..self.len];
        }
        const header: [*]const u8 = @ptrCast(self);
        const body = header + @sizeOf(LuaString);
        return body[0..self.len];
    }
};
```

- [ ] **Step 2: Update destroyLuaString**

```zig
pub fn destroyLuaString(alloc: std.mem.Allocator, ls: *LuaString) void {
    if (ls.is_external) {
        // Call dealloc callback (PUC lgc.c:875: falloc(ud, contents, len+1, 0))
        if (ls.falloc) |falloc| {
            _ = falloc(ls.falloc_ud, @ptrCast(@constCast(ls.external_ptr)), ls.len + 1, 0);
        }
        // Free only the header (no inline content)
        alloc.destroy(ls);
    } else {
        // Regular: free header + inline content
        const total = @sizeOf(LuaString) + ls.len;
        const buf: [*]align(@alignOf(LuaString)) u8 = @ptrCast(@alignCast(ls));
        alloc.free(buf[0..total]);
    }
}
```

NOTE: External strings are allocated with `alloc.create(LuaString)` (header only), NOT `createLuaString` (header + inline content). Add a `createExternalLuaString` helper.

- [ ] **Step 3: Add createExternalLuaString**

```zig
fn createExternalLuaString(self: *Vm, content: [*]const u8, len: usize, falloc: ?*const fn(?*anyopaque, ?*anyopaque, usize, usize) ?*anyopaque, ud: ?*anyopaque) !*LuaString {
    const ls = try self.alloc.create(LuaString);
    ls.* = .{
        .hash = hashString(content[0..len], self.hash_seed),
        .len = len,
        .is_short = false,
        .is_external = true,
        .external_ptr = content,
        .falloc = falloc,
        .falloc_ud = ud,
    };
    try self.gcRegisterObject(.{ .string = ls });
    return ls;
}
```

- [ ] **Step 4: Add lua_pushexternalstring to c_api.zig**

```zig
export fn lua_pushexternalstring(L: ?*lua_State, s: [*]u8, len: usize, falloc: ?*const fn(?*anyopaque, ?*anyopaque, usize, usize) ?*anyopaque, ud: ?*anyopaque) void {
    const vm = L orelse return;
    if (len >= 40) {
        // Long string — create external LuaString
        const ls = vm.createExternalLuaString(s, len, falloc, ud) catch return;
        vm.c_stack.append(vm.alloc, .{ .String = ls }) catch {};
    } else {
        // Short string — just intern it normally
        const ls = vm.internStr(s[0..len]) catch return;
        // If falloc is provided, call it now (short strings are copied)
        if (falloc) |fa| {
            _ = fa(ud, @ptrCast(s), len + 1, 0);
        }
        vm.c_stack.append(vm.alloc, .{ .String = ls }) catch {};
    }
}
```

- [ ] **Step 5: Add lua_getallocf to c_api.zig**

```zig
// Wrapper allocator function for lua_getallocf
// PUC's lua_Alloc signature: void* (*)(void *ud, void *ptr, size_t osize, size_t nsize)
fn cApiAllocWrapper(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) ?*anyopaque {
    _ = osize;
    const vm: *@import("vm.zig").Vm = @ptrCast(@alignCast(ud));
    if (nsize == 0) {
        if (ptr) |p| vm.alloc.rawFree(@as([*]u8, @ptrCast(p))[0..osize]);
        return null;
    }
    // Simple: alloc new, copy, free old
    const new_buf = vm.alloc.alloc(u8, nsize) catch return null;
    if (ptr) |p| {
        const old_buf: [*]u8 = @ptrCast(p);
        @memcpy(new_buf[0..@min(osize, nsize)], old_buf[0..@min(osize, nsize)]);
        vm.alloc.rawFree(old_buf[0..osize]);
    }
    return @ptrCast(new_buf.ptr);
}

export fn lua_getallocf(L: ?*lua_State, ud: ?*?*anyopaque) ?*const fn(?*anyopaque, ?*anyopaque, usize, usize) ?*anyopaque {
    if (ud) |u| u.* = @ptrCast(L);
    return cApiAllocWrapper;
}
```

- [ ] **Step 6: Build and test**

- [ ] **Step 7: Commit**

```bash
git add src/lua/vm.zig src/lua/c_api.zig
git commit -m "external strings: LuaString.is_external, pushexternalstring, getallocf"
```

---

## Part E: Integration Testing

### Task E1: Compile test C libraries and run attrib.lua

**Files:**
- Modify: `Makefile` — add target for test libraries compiled with zig cc
- Test: `lua-5.5.0/testes/attrib.lua`

- [ ] **Step 1: Ensure test libraries are compiled**

The test libraries (`lib1.so`, `lib2.so`, `lib2-v2.so`, etc.) need to be compiled with our `lua.h` headers (which declare `lua_error` as returning, not noreturn — so the C compiler doesn't optimize away error checks).

Create `src/lua/lua.h` with the minimum declarations needed by the test libraries. Include the `lua_CFunction` typedef, `lua_State` typedef (as `struct Vm`), and all function declarations used by the test C files.

Create `src/lua/lauxlib.h` with `luaL_Reg`, `luaL_newlib`, `luaL_checklstring`, `luaL_checkversion`.

- [ ] **Step 2: Compile test libraries with zig cc**

```bash
cd lua-5.5.0/testes/libs && \
zig cc -shared -o lib1.so -I ../../../src/lua lib1.c && \
zig cc -shared -o lib2.so -I ../../../src/lua lib2.c && \
zig cc -shared -o lib2-v2.so -I ../../../src/lua lib22.c && \
zig cc -shared -o lib11.so -I ../../../src/lua lib11.c && \
zig cc -shared -o lib21.so -I ../../../src/lua lib21.c
```

- [ ] **Step 3: Run attrib.lua testC**

```bash
cd lua-5.5.0/testes && rm -f libs/A.lua libs/B.lua libs/C.lua libs/L libs/XXxX libs/err.lua libs/names.lua libs/synerr.lua libs/A libs/A.lc && rm -rf libs/P1 && mkdir -p libs/P1 && timeout 30 ../../zig-out/bin/luazig --testc attrib.lua 2>&1 | tail -10
```

- [ ] **Step 4: Debug and fix issues**

Iterate on C API functions, call dispatch, and external string handling until attrib.lua passes.

- [ ] **Step 5: Run full testC matrix**

```bash
cd /home/boss/codes/luazig && python3 tools/testes_matrix.py --testc --timeout 30 2>&1 | head -5
```

Expected: 27/31+ (attrib.lua passes).

- [ ] **Step 6: Run regression matrix + smoke**

```bash
python3 tools/testes_matrix.py --timeout 30 2>&1 | head -3
for f in tests/smoke/*.lua; do timeout 5 zig-out/bin/luazig "$f" 2>&1 | tail -1; done | grep -c "."
python3 tools/testc_lane.py --timeout 30 2>&1 | grep -c "ok"
```

- [ ] **Step 7: Update README**

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "C extension loading: attrib.lua passes, full regression OK"
```

---

## Risk Assessment

| Risk | Mitigation |
|---|---|
| c_stack/bc_stack bridging | C functions only touch c_stack; VM calls bridge explicitly |
| longjmp skipping Zig defers | longjmp is in C wrapper; Zig defer runs on normal return from wrapper |
| External string perf (bytes() branch) | One branch in hot path; measure against perf baseline |
| lua_pushfstring variadic | C variadics need a C wrapper; test libs use simple %d/%s |
| DynLib.lookup calling convention | Must match `fn(*Vm) callconv(.C) c_int`; platform-dependent |
| Test library compilation | Need compatible lua.h; zig cc handles it |

## Expected Final State

| Metric | Before | After |
|---|---|---|
| testC matrix | 26/31 (3 zig_fail) | 27/31+ (attrib.lua passes) |
| package.loadlib | Stub (returns nil) | Real dlopen via std.DynLib |
| lua_pushexternalstring | Not implemented | Full PUC 5.5 external string support |
| C function calling | Not supported | Full lua_CFunction support |
| lua_error | Not implemented | longjmp boundary via cfunc_wrap.c |
