const std = @import("std");
const stdio = @import("util").stdio;
const api = @import("api.zig");
const vm_mod = @import("vm.zig");

// Compilation pipeline used by luaL_loadbufferx / luaL_loadfilex.
const source_mod = @import("source.zig");

const Vm = vm_mod.Vm;
const Value = vm_mod.Value;

// C-ABI export layer for Lua C API compatibility.
//
// After Phase R3 refactoring, this file is a thin shim: each export function
// creates an `api.State` wrapper around the `*Vm` and delegates to the
// corresponding `api.State` method. The actual implementation logic lives in
// `api.zig`, ensuring a single source of truth.
//
// C-specific functions that cannot be delegated (luaL_newstate, lua_close,
// lua_error/longjmp, lua_pushfstring vararg, lua_callk boundary, etc.)
// remain here with their full implementation.

pub const lua_State = Vm;

/// PUC `lua_Alloc` (lua.h:125): the allocator signature.
pub const lua_Alloc = ?*const fn (
    ?*anyopaque,
    ?*anyopaque,
    usize,
    usize,
) callconv(.c) ?*anyopaque;

/// PUC `LUA_REGISTRYINDEX` (lua.h:43): pseudo-index for the registry table.
pub const LUA_REGISTRYINDEX: c_int = -1001000;

/// PUC reference sentinels (lauxlib.h).
pub const LUA_REFNIL: c_int = -1;
pub const LUA_NOREF: c_int = -2;

/// PUC `luaL_Reg`: a {name, func} pair terminated by a sentinel.
pub const luaL_Reg = api.State.Reg;

// Shared helpers from api.zig (single source of truth).
const normalizeIndex = api.normalizeIndex;
const typeCode = api.typeCode;
const statusCode = api.statusCode;
const mapCompileError = api.mapCompileError;

// ===========================================================================
// C-specific functions (cannot be delegated to api.State)
// ===========================================================================

pub export fn luaL_newstate() ?*lua_State {
    const alloc = std.heap.c_allocator;
    const ptr = alloc.create(lua_State) catch return null;
    ptr.* = lua_State.init(alloc, false);
    return ptr;
}

pub export fn lua_close(L: ?*lua_State) void {
    const vm = L orelse return;
    vm.deinit();
    std.heap.c_allocator.destroy(vm);
}

// `_longjmp` from libc. Using `_longjmp` (not `longjmp`) matches PUC's
// `__sigsetjmp(env, 0)` no-savemask choice.
extern fn _longjmp(jb: *anyopaque, val: c_int) noreturn;

/// PUC `lua_error` (noreturn): captures the error object from c_stack top into
/// `c_error_value`, then `_longjmp` to the nearest C-function boundary.
pub export fn lua_error(L: ?*lua_State) noreturn {
    const vm = L orelse @panic("lua_error: null state");
    if (vm.c_stack.items.len > 0) {
        vm.c_error_value = vm.c_stack.items[vm.c_stack.items.len - 1];
    } else {
        @panic("lua_error: no error object on stack");
    }
    if (vm.c_error_jmp) |jb| {
        _longjmp(jb, 1);
    }
    @panic("lua_error called without a C function error boundary");
}

/// PUC `lua_call` (macro): expands to lua_callk(L, n, r, 0, NULL).
pub export fn lua_call(L: ?*lua_State, nargs: c_int, nresults: c_int) void {
    lua_callkImpl(L, nargs, nresults);
}

/// PUC `lua_callk`: continuations not supported; delegates to lua_callkImpl.
pub export fn lua_callk(
    L: ?*lua_State,
    nargs: c_int,
    nresults: c_int,
    ctx: isize,
    k: ?*const anyopaque,
) void {
    _ = ctx;
    _ = k;
    lua_callkImpl(L, nargs, nresults);
}

/// Unprotected call: on failure, rethrows through the active C-function
/// boundary via longjmp (PUC `luaD_throw`). The success path delegates to
/// `api.State.call()`, which marshals results on `c_stack`.
fn lua_callkImpl(L: ?*lua_State, nargs: c_int, nresults: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.call(@intCast(@max(nargs, 0)), nresults) catch {
        // Error: propagate through boundary via longjmp
        const vm = s.vm;
        if (vm.c_error_jmp) |jb| {
            vm.c_error_value = vm.err_obj;
            _longjmp(jb, 1);
        }
        @panic("lua_call without an active C-function boundary");
    };
}

/// PUC `lua_pushfstring` (lobject.c:luaO_pushfstring): formatted push with
// C vararg. Must stay in c_api.zig because Zig export fn vararg requires
// `@cVaStart`/`@cVaArg` which is C-ABI-specific.
pub export fn lua_pushfstring(L: ?*lua_State, fmt: [*:0]const u8, ...) void {
    const vm = L orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.alloc);

    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var i: usize = 0;
    while (true) {
        const c = fmt[i];
        if (c == 0) break;
        if (c != '%') {
            buf.append(vm.alloc, c) catch return;
            i += 1;
            continue;
        }
        i += 1;
        const spec = fmt[i];
        switch (spec) {
            0 => {
                buf.append(vm.alloc, '%') catch return;
                break;
            },
            'd', 'i' => {
                const v = @cVaArg(&ap, c_int);
                const s = std.fmt.allocPrint(vm.alloc, "{d}", .{v}) catch return;
                defer vm.alloc.free(s);
                buf.appendSlice(vm.alloc, s) catch return;
            },
            'u' => {
                const v = @cVaArg(&ap, c_uint);
                const s = std.fmt.allocPrint(vm.alloc, "{d}", .{v}) catch return;
                defer vm.alloc.free(s);
                buf.appendSlice(vm.alloc, s) catch return;
            },
            'f', 'g' => {
                const v = @cVaArg(&ap, f64);
                const s = std.fmt.allocPrint(vm.alloc, "{d}", .{v}) catch return;
                defer vm.alloc.free(s);
                buf.appendSlice(vm.alloc, s) catch return;
            },
            's' => {
                const v = @cVaArg(&ap, ?[*:0]const u8);
                if (v) |str| {
                    buf.appendSlice(vm.alloc, std.mem.span(str)) catch return;
                } else {
                    buf.appendSlice(vm.alloc, "(null)") catch return;
                }
            },
            'c' => {
                const v = @cVaArg(&ap, c_int);
                buf.append(vm.alloc, @intCast(@as(u32, @bitCast(v)) & 0xFF)) catch return;
            },
            'p' => {
                const v = @cVaArg(&ap, ?*anyopaque);
                const s = std.fmt.allocPrint(vm.alloc, "{x}", .{@intFromPtr(v)}) catch return;
                defer vm.alloc.free(s);
                buf.appendSlice(vm.alloc, s) catch return;
            },
            'x' => {
                const v = @cVaArg(&ap, c_uint);
                const s = std.fmt.allocPrint(vm.alloc, "{x}", .{v}) catch return;
                defer vm.alloc.free(s);
                buf.appendSlice(vm.alloc, s) catch return;
            },
            'X' => {
                const v = @cVaArg(&ap, c_uint);
                const s = std.fmt.allocPrint(vm.alloc, "{X}", .{v}) catch return;
                defer vm.alloc.free(s);
                buf.appendSlice(vm.alloc, s) catch return;
            },
            'o' => {
                const v = @cVaArg(&ap, c_uint);
                const s = std.fmt.allocPrint(vm.alloc, "{o}", .{v}) catch return;
                defer vm.alloc.free(s);
                buf.appendSlice(vm.alloc, s) catch return;
            },
            'U' => {
                const cp = @cVaArg(&ap, c_int);
                var utf8: [4]u8 = undefined;
                const codepoint: u21 = @intCast(@as(u32, @bitCast(cp)) & 0x7FFFFFFF);
                const n = std.unicode.utf8Encode(codepoint, &utf8) catch 0;
                buf.appendSlice(vm.alloc, utf8[0..n]) catch return;
            },
            '%' => buf.append(vm.alloc, '%') catch return,
            else => {
                buf.append(vm.alloc, '%') catch return;
                buf.append(vm.alloc, spec) catch return;
            },
        }
        i += 1;
    }

    const ls = vm.internStr(buf.items) catch return;
    vm.c_stack.append(vm.alloc, .{ .String = ls }) catch {};
}

/// C-callable wrapper exposing the VM's allocator through the PUC `lua_Alloc`
/// signature. Routes alloc/realloc/free calls to `vm.alloc`.
fn cApiAllocWrapper(
    ud: ?*anyopaque,
    ptr: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.c) ?*anyopaque {
    const vm: *Vm = @ptrCast(@alignCast(ud orelse return null));
    if (nsize == 0) {
        if (ptr) |p| {
            const old_buf: [*]u8 = @ptrCast(p);
            vm.alloc.free(old_buf[0..osize]);
        }
        return null;
    }
    if (ptr) |p| {
        const old_buf: [*]u8 = @ptrCast(p);
        const new_buf = vm.alloc.realloc(old_buf[0..osize], nsize) catch return null;
        return @ptrCast(new_buf.ptr);
    }
    const new_buf = vm.alloc.alloc(u8, nsize) catch return null;
    return @ptrCast(new_buf.ptr);
}

/// PUC `lua_getallocf` (lapi.c:1319): return the VM's allocator function.
pub export fn lua_getallocf(L: ?*lua_State, ud: ?*?*anyopaque) lua_Alloc {
    if (ud) |u| u.* = @ptrCast(L);
    return cApiAllocWrapper;
}

/// PUC `luaL_loadbufferx`: compile a source chunk from a byte buffer.
/// Delegates to `Vm.compileChunkValue` (shared with `api.State.compileChunk`).
pub export fn luaL_loadbufferx(L: ?*lua_State, buff: [*]const u8, sz: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int {
    _ = mode;
    const vm = L orelse return 2;
    const compiled = vm.compileChunkValue(buff[0..sz], std.mem.span(name)) catch |e|
        return statusCode(mapCompileError(e));
    vm.c_stack.append(vm.alloc, compiled) catch return statusCode(.memory_error);
    return 0;
}

/// PUC `luaL_loadfilex`: load and compile a source file.
pub export fn luaL_loadfilex(L: ?*lua_State, filename: [*:0]const u8, mode: ?[*:0]const u8) c_int {
    _ = mode;
    const vm = L orelse return 2;
    const source = source_mod.Source.loadFile(vm.alloc, stdio.activeIo(), std.mem.span(filename)) catch
        return statusCode(.memory_error);
    defer vm.alloc.free(source.name);
    defer vm.alloc.free(source.bytes);
    const compiled = vm.compileChunkValue(source.bytes, source.name) catch |e|
        return statusCode(mapCompileError(e));
    vm.c_stack.append(vm.alloc, compiled) catch return statusCode(.memory_error);
    return 0;
}

/// PUC `luaL_checkversion` (macro): expands to luaL_checkversion_.
pub export fn luaL_checkversion(L: ?*lua_State) void {
    _ = L;
}

/// PUC `luaL_checkversion_` (lauxlib.c:1194): verify numeric type sizes
/// and version match. Calls lua_error on mismatch.
pub export fn luaL_checkversion_(L: ?*lua_State, ver: f64, sz: usize) void {
    const expected_sz = @sizeOf(i64) * 16 + @sizeOf(f64);
    if (sz != expected_sz) {
        lua_pushstring(L, "core and library have incompatible numeric types");
        lua_error(L);
    }
    const expected_ver: f64 = 505.0;
    if (ver != expected_ver) {
        lua_pushstring(L, "version mismatch: C library and Lua core disagree");
        lua_error(L);
    }
}

// ===========================================================================
// Thin C-ABI shims — each delegates to api.State
// ===========================================================================

// --- Stack manipulation ---

pub export fn lua_gettop(L: ?*lua_State) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return @intCast(s.gettop());
}

pub export fn lua_settop(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.settop(idx) catch {};
}

pub export fn lua_pop(L: ?*lua_State, n: c_int) void {
    var s = api.State.fromVm(L orelse return);
    if (n <= 0) return;
    s.pop(@intCast(n)) catch {};
}

pub export fn lua_rotate(L: ?*lua_State, idx: c_int, n: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.rotate(idx, n) catch {};
}

pub export fn lua_copy(L: ?*lua_State, fromidx: c_int, toidx: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.copy(fromidx, toidx) catch {};
}

pub export fn lua_insert(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.insert(idx) catch {};
}

pub export fn lua_remove(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.remove(idx) catch {};
}

// --- Push functions ---

pub export fn lua_pushnil(L: ?*lua_State) void {
    var s = api.State.fromVm(L orelse return);
    s.pushnil() catch {};
}

pub export fn lua_pushboolean(L: ?*lua_State, b: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.pushboolean(b != 0) catch {};
}

pub export fn lua_pushinteger(L: ?*lua_State, v: i64) void {
    var s = api.State.fromVm(L orelse return);
    s.pushinteger(v) catch {};
}

pub export fn lua_pushnumber(L: ?*lua_State, v: f64) void {
    var s = api.State.fromVm(L orelse return);
    s.pushnumber(v) catch {};
}

pub export fn lua_pushstring(L: ?*lua_State, s: [*:0]const u8) void {
    var st = api.State.fromVm(L orelse return);
    st.pushstring(std.mem.span(s)) catch {};
}

pub export fn lua_pushliteral(L: ?*lua_State, s: [*:0]const u8) void {
    lua_pushstring(L, s);
}

pub export fn lua_pushlstring(L: ?*lua_State, s: [*]const u8, len: usize) void {
    var st = api.State.fromVm(L orelse return);
    st.pushlstring(s[0..len]) catch {};
}

pub export fn lua_pushvalue(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.pushvalue(idx) catch {};
}

pub export fn lua_pushlightuserdata(L: ?*lua_State, p: ?*anyopaque) void {
    var s = api.State.fromVm(L orelse return);
    s.pushlightuserdata(p) catch {};
}

pub export fn lua_pushcclosure(L: ?*lua_State, f: ?*const fn (?*lua_State) callconv(.c) c_int, n: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.pushcclosure(f, @intCast(@max(n, 0))) catch {};
}

pub export fn lua_pushcfunction(L: ?*lua_State, f: ?*const fn (?*lua_State) callconv(.c) c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.pushcfunction(f) catch {};
}

pub export fn lua_pushexternalstring(
    L: ?*lua_State,
    s: [*]u8,
    len: usize,
    falloc: lua_Alloc,
    ud: ?*anyopaque,
) void {
    var st = api.State.fromVm(L orelse return);
    st.pushexternalString(s, len, falloc, ud) catch {};
}

// --- Type / conversion ---

pub export fn lua_type(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromVm(L orelse return -1);
    return if (s.typeOf(idx)) |t| typeCode(t) else -1;
}

pub export fn lua_toboolean(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.toboolean(idx)) 1 else 0;
}

pub export fn lua_tointegerx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) i64 {
    var s = api.State.fromVm(L orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    });
    if (s.tointeger(idx)) |v| {
        if (isnum) |p| p.* = 1;
        return v;
    }
    if (isnum) |p| p.* = 0;
    return 0;
}

pub export fn lua_tonumberx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) f64 {
    var s = api.State.fromVm(L orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    });
    if (s.tonumber(idx)) |v| {
        if (isnum) |p| p.* = 1;
        return v;
    }
    if (isnum) |p| p.* = 0;
    return 0;
}

// --- Table / globals ---

pub export fn lua_createtable(L: ?*lua_State, narr: c_int, nrec: c_int) void {
    _ = narr;
    _ = nrec;
    var s = api.State.fromVm(L orelse return);
    s.newtable() catch {};
}

pub export fn lua_setglobal(L: ?*lua_State, name: [*:0]const u8) void {
    var s = api.State.fromVm(L orelse return);
    s.setglobal(std.mem.span(name)) catch {};
}

pub export fn lua_getglobal(L: ?*lua_State, name: [*:0]const u8) c_int {
    var s = api.State.fromVm(L orelse return -1);
    return typeCode(s.getglobal(std.mem.span(name)) catch return 0);
}

pub export fn lua_setfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void {
    var s = api.State.fromVm(L orelse return);
    s.setfield(idx, std.mem.span(k)) catch {};
}

pub export fn lua_getfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return typeCode(s.getfield(idx, std.mem.span(k)) catch return 0);
}

pub export fn lua_rawset(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.rawset(idx) catch {};
}

pub export fn lua_rawget(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return typeCode(s.rawget(idx) catch return 0);
}

pub export fn lua_next(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.next(idx) catch false) 1 else 0;
}

// --- Call / pcall ---

pub export fn lua_pcallk(L: ?*lua_State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?*const anyopaque) c_int {
    _ = errfunc;
    _ = ctx;
    _ = k;
    var s = api.State.fromVm(L orelse return 2);
    return statusCode(s.pcall(@intCast(@max(nargs, 0)), nresults));
}

// --- Userdata ---

pub export fn lua_newuserdatauv(L: ?*lua_State, sz: usize, nuvalue: c_int) ?*anyopaque {
    var s = api.State.fromVm(L orelse return null);
    return s.newuserdatauv(sz, @intCast(@max(nuvalue, 0))) catch null;
}

pub export fn lua_touserdata(L: ?*lua_State, idx: c_int) ?*anyopaque {
    var s = api.State.fromVm(L orelse return null);
    return s.touserdata(idx);
}

pub export fn lua_topointer(L: ?*lua_State, idx: c_int) ?*anyopaque {
    var s = api.State.fromVm(L orelse return null);
    return s.topointer(idx);
}

pub export fn lua_setmetatable(L: ?*lua_State, objindex: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    s.setmetatable(objindex) catch return 0;
    return 1;
}

pub export fn lua_getmetatable(L: ?*lua_State, objindex: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.getmetatable(objindex) catch false) 1 else 0;
}

pub export fn lua_setiuservalue(L: ?*lua_State, idx: c_int, n: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.setiuservalue(idx, @intCast(@max(n, 0))) catch false) 1 else 0;
}

pub export fn lua_getiuservalue(L: ?*lua_State, idx: c_int, n: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return typeCode(s.getiuservalue(idx, @intCast(@max(n, 0))) catch return 0);
}

// --- lauxlib ---

pub export fn luaL_checklstring(L: ?*lua_State, arg: c_int, l: ?*usize) [*:0]const u8 {
    var s = api.State.fromVm(L orelse {
        if (l) |p| p.* = 0;
        return "";
    });
    const bytes = s.checklstring(arg);
    if (l) |p| p.* = bytes.len;
    return @ptrCast(@constCast(bytes.ptr));
}

pub export fn luaL_setfuncs(L: ?*lua_State, reg: [*]const luaL_Reg, nup: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.registerfuncs(reg, @intCast(@max(nup, 0))) catch {};
}

pub export fn luaL_newlib(L: ?*lua_State, reg: [*]const luaL_Reg) void {
    var s = api.State.fromVm(L orelse return);
    s.newlib(reg) catch {};
}

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

pub export fn luaL_getmetatable(L: ?*lua_State, tname: [*:0]const u8) void {
    var s = api.State.fromVm(L orelse return);
    s.getRegisteredMetatable(std.mem.span(tname)) catch {};
}

pub export fn luaL_setmetatable(L: ?*lua_State, tname: [*:0]const u8) void {
    var s = api.State.fromVm(L orelse return);
    s.setRegisteredMetatable(std.mem.span(tname)) catch {};
}

pub export fn luaL_testudata(L: ?*lua_State, ud: c_int, tname: [*:0]const u8) ?*anyopaque {
    var s = api.State.fromVm(L orelse return null);
    return s.testudata(ud, std.mem.span(tname));
}

pub export fn luaL_checkudata(L: ?*lua_State, ud: c_int, tname: [*:0]const u8) ?*anyopaque {
    if (luaL_testudata(L, ud, tname)) |p| return p;
    lua_pushstring(L, "bad argument: wrong userdata type");
    lua_error(L);
}

pub export fn luaL_checkinteger(L: ?*lua_State, arg: c_int) i64 {
    var s = api.State.fromVm(L orelse return 0);
    return s.checkinteger(arg) catch {
        lua_pushstring(L, "bad argument: integer expected");
        lua_error(L);
    };
}

pub export fn luaL_optinteger(L: ?*lua_State, arg: c_int, def: i64) i64 {
    var s = api.State.fromVm(L orelse return def);
    return s.optinteger(arg, def) catch def;
}

// ===========================================================================
// Tests (unchanged from pre-refactoring)
// ===========================================================================

test "c api shim smoke" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    try std.testing.expectEqual(@as(c_int, 0), lua_gettop(L));
    lua_pushinteger(L, 42);
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L));
    var ok: c_int = 0;
    const iv = lua_tointegerx(L, -1, &ok);
    try std.testing.expectEqual(@as(c_int, 1), ok);
    try std.testing.expectEqual(@as(i64, 42), iv);
}

test "c api shim lua_next iterates table" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    const src = "return { a = 1, b = 2 }";
    try std.testing.expectEqual(@as(c_int, 0), luaL_loadbufferx(L, src.ptr, src.len, "=c-api-next", null));
    try std.testing.expectEqual(@as(c_int, 0), lua_pcallk(L, 0, 1, 0, 0, null));

    lua_pushnil(L);
    var seen: usize = 0;
    while (lua_next(L, -2) != 0) {
        seen += 1;
        lua_pop(L, 1);
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L));
}

fn intAt(L: ?*lua_State, idx: c_int) i64 {
    var ok: c_int = 0;
    return lua_tointegerx(L, idx, &ok);
}

test "c api pushvalue/insert/remove" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    lua_pushinteger(L, 10);
    lua_pushvalue(L, -1);
    try std.testing.expectEqual(@as(c_int, 2), lua_gettop(L));
    try std.testing.expectEqual(@as(i64, 10), intAt(L, -1));
    try std.testing.expectEqual(@as(i64, 10), intAt(L, -2));

    lua_settop(L, 0);
    lua_pushinteger(L, 1);
    lua_pushinteger(L, 2);
    lua_pushinteger(L, 3);
    lua_pushinteger(L, 4);

    lua_insert(L, 1);
    try std.testing.expectEqual(@as(i64, 4), intAt(L, 1));
    try std.testing.expectEqual(@as(i64, 1), intAt(L, 2));
    try std.testing.expectEqual(@as(i64, 2), intAt(L, 3));
    try std.testing.expectEqual(@as(i64, 3), intAt(L, 4));

    lua_remove(L, 2);
    try std.testing.expectEqual(@as(c_int, 3), lua_gettop(L));
    try std.testing.expectEqual(@as(i64, 4), intAt(L, 1));
    try std.testing.expectEqual(@as(i64, 2), intAt(L, 2));
    try std.testing.expectEqual(@as(i64, 3), intAt(L, 3));
}

test "c api rotate matches PUC direction" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    var i: i64 = 1;
    while (i <= 5) : (i += 1) lua_pushinteger(L, i);

    lua_rotate(L, 1, 2);
    try std.testing.expectEqual(@as(i64, 4), intAt(L, 1));
    try std.testing.expectEqual(@as(i64, 5), intAt(L, 2));
    try std.testing.expectEqual(@as(i64, 1), intAt(L, 3));
    try std.testing.expectEqual(@as(i64, 2), intAt(L, 4));
    try std.testing.expectEqual(@as(i64, 3), intAt(L, 5));

    lua_rotate(L, 1, -1);
    try std.testing.expectEqual(@as(i64, 5), intAt(L, 1));
    try std.testing.expectEqual(@as(i64, 4), intAt(L, 5));

    lua_rotate(L, 1, 0);
    try std.testing.expectEqual(@as(i64, 5), intAt(L, 1));
    try std.testing.expectEqual(@as(i64, 4), intAt(L, 5));
}

test "c api createtable setfield/getfield" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    lua_createtable(L, 0, 0);
    lua_pushinteger(L, 42);
    lua_setfield(L, 1, "x");
    lua_getfield(L, 1, "x");
    try std.testing.expectEqual(@as(c_int, 2), lua_gettop(L));
    try std.testing.expectEqual(@as(i64, 42), intAt(L, -1));
    try std.testing.expectEqual(@as(c_int, 5), lua_type(L, 1));
    lua_getfield(L, 1, "absent");
    try std.testing.expectEqual(@as(c_int, 0), lua_type(L, -1));
}

test "c api rawset/rawget" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    lua_createtable(L, 0, 0);
    lua_pushinteger(L, 1);
    lua_pushinteger(L, 99);
    lua_rawset(L, -3);
    lua_pushinteger(L, 1);
    lua_rawget(L, -2);
    try std.testing.expectEqual(@as(i64, 99), intAt(L, -1));
}

test "c api pushlstring and newlib push closure/table" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    const bytes = [_]u8{ 'a', 0, 'b' };
    lua_pushlstring(L, &bytes, bytes.len);
    try std.testing.expectEqual(@as(c_int, 4), lua_type(L, -1));

    const f: ?*const fn (?*lua_State) callconv(.c) c_int = struct {
        fn r(_: ?*lua_State) callconv(.c) c_int {
            return 0;
        }
    }.r;
    lua_pushcfunction(L, f);
    try std.testing.expectEqual(@as(c_int, 6), lua_type(L, -1));

    const reg = [_]luaL_Reg{
        .{ .name = "noop", .func = f },
        .{ .name = null, .func = null },
    };
    luaL_newlib(L, &reg);
    try std.testing.expectEqual(@as(c_int, 5), lua_type(L, -1));
    lua_getfield(L, -1, "noop");
    try std.testing.expectEqual(@as(c_int, 6), lua_type(L, -1));
}

test "c api luaL_checklstring returns NUL-terminated C string" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    lua_pushlstring(L, "hello", 5);
    var len: usize = 0;
    const ptr = luaL_checklstring(L, -1, &len);
    try std.testing.expectEqual(@as(usize, 5), len);
    const span = std.mem.span(ptr);
    try std.testing.expectEqualStrings("hello", span);
}

test "c api luaL_ref LUA_REFNIL / LUA_NOREF / ref" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    try std.testing.expectEqual(LUA_NOREF, luaL_ref(L, 1));

    lua_createtable(L, 0, 0);

    lua_pushinteger(L, 111);
    const r1 = luaL_ref(L, 1);
    try std.testing.expect(r1 >= 0);
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L));

    lua_pushnil(L);
    try std.testing.expectEqual(LUA_REFNIL, luaL_ref(L, 1));

    lua_pushinteger(L, 222);
    const r3 = luaL_ref(L, 1);
    try std.testing.expectEqual(@as(c_int, r1 + 1), r3);

    lua_settop(L, 0);
    lua_pushinteger(L, 5);
    lua_pushinteger(L, 6);
    try std.testing.expectEqual(LUA_NOREF, luaL_ref(L, 1));
}

// --- setjmp/longjmp error boundary tests ---

fn cfuncThatErrors(L: ?*lua_State) callconv(.c) c_int {
    const vm = L.?;
    lua_pushliteral(vm, "boom from C");
    lua_error(vm);
    return 0;
}

fn cfuncReturns42(L: ?*lua_State) callconv(.c) c_int {
    lua_pushinteger(L, 42);
    return 1;
}

test "c api lua_error crosses the setjmp boundary into pcall" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    lua_pushcfunction(L, cfuncThatErrors);
    const status = lua_pcallk(L, 0, 0, 0, 0, null);
    try std.testing.expectEqual(@as(c_int, 2), status);

    try std.testing.expect(L.err_has_obj);
    try std.testing.expectEqualStrings("boom from C", L.err_obj.String.bytes());
    try std.testing.expect(L.c_error_value == null);
    try std.testing.expectEqual(@as(c_int, 0), lua_gettop(L));
}

test "c api boundary success path returns results normally" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    lua_pushcfunction(L, cfuncReturns42);
    const status = lua_pcallk(L, 0, 1, 0, 0, null);
    try std.testing.expectEqual(@as(c_int, 0), status);
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L));
    try std.testing.expectEqual(@as(i64, 42), intAt(L, -1));
    try std.testing.expect(!L.err_has_obj);
}

test "c api lua_getallocf: alloc/realloc/free roundtrip" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    var ud: ?*anyopaque = null;
    const allocf = lua_getallocf(L, &ud);
    try std.testing.expect(allocf != null);
    try std.testing.expect(ud != null);

    const ptr = allocf.?(ud, null, 0, 100);
    try std.testing.expect(ptr != null);

    const ptr2 = allocf.?(ud, ptr, 100, 200);
    try std.testing.expect(ptr2 != null);

    const result = allocf.?(ud, ptr2, 200, 0);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "c api lua_pushexternalstring: pushed string is readable" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    const content = "external string content that is long enough";
    lua_pushexternalstring(L, @constCast(content.ptr), content.len, null, null);
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L));

    var len: usize = 0;
    const got = luaL_checklstring(L, -1, &len);
    try std.testing.expectEqual(@as(usize, content.len), len);
    try std.testing.expectEqualStrings(content, got[0..len]);
}
