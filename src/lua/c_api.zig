const std = @import("std");
const api = @import("api.zig");

// Thin C-ABI shim for partial Lua C API compatibility.
//
// Support status: smoke-compat layer, not a committed standalone product yet.
// The supported embedding surface is the Zig API (`api.State`). This file is
// intentionally small and must map exported C-shaped functions onto that public
// Zig layer instead of opening a second path to VM internals. Promoting it to a
// supported C ABI requires a header, shared-library build artifact, and an
// explicit compatibility matrix.

pub const lua_State = api.State;

fn asState(L: ?*lua_State) ?*lua_State {
    return L;
}

fn statusCode(st: api.Status) c_int {
    return switch (st) {
        .ok => 0,
        .yielded => 1,
        .runtime_error => 2,
        .syntax_error => 3,
        .memory_error => 4,
    };
}

export fn luaL_newstate() ?*lua_State {
    const alloc = std.heap.c_allocator;
    const ptr = alloc.create(lua_State) catch return null;
    ptr.* = lua_State.init(.{ .allocator = alloc });
    return ptr;
}

export fn lua_close(L: ?*lua_State) void {
    const st = asState(L) orelse return;
    st.deinit();
    std.heap.c_allocator.destroy(st);
}

export fn lua_gettop(L: ?*lua_State) c_int {
    const st = asState(L) orelse return 0;
    return @intCast(st.gettop());
}

export fn lua_settop(L: ?*lua_State, idx: c_int) void {
    const st = asState(L) orelse return;
    _ = st.settop(idx) catch {};
}

export fn lua_pop(L: ?*lua_State, n: c_int) void {
    const st = asState(L) orelse return;
    if (n <= 0) return;
    _ = st.pop(@intCast(n)) catch {};
}

export fn lua_pushnil(L: ?*lua_State) void {
    const st = asState(L) orelse return;
    _ = st.pushnil() catch {};
}

export fn lua_pushboolean(L: ?*lua_State, b: c_int) void {
    const st = asState(L) orelse return;
    _ = st.pushboolean(b != 0) catch {};
}

export fn lua_pushinteger(L: ?*lua_State, v: i64) void {
    const st = asState(L) orelse return;
    _ = st.pushinteger(v) catch {};
}

export fn lua_pushnumber(L: ?*lua_State, v: f64) void {
    const st = asState(L) orelse return;
    _ = st.pushnumber(v) catch {};
}

export fn lua_pushstring(L: ?*lua_State, s: [*:0]const u8) void {
    const st = asState(L) orelse return;
    _ = st.pushstring(std.mem.span(s)) catch {};
}

export fn lua_type(L: ?*lua_State, idx: c_int) c_int {
    const st = asState(L) orelse return -1;
    const ty = st.typeOf(idx) orelse return -1;
    return switch (ty) {
        .nil => 0,
        .boolean => 1,
        .number => 3,
        .string => 4,
        .table => 5,
        .function => 6,
        .userdata => 7,
        .thread => 8,
    };
}

export fn lua_toboolean(L: ?*lua_State, idx: c_int) c_int {
    const st = asState(L) orelse return 0;
    return if (st.toboolean(idx)) 1 else 0;
}

export fn lua_tointegerx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) i64 {
    const st = asState(L) orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    if (st.tointeger(idx)) |v| {
        if (isnum) |p| p.* = 1;
        return v;
    }
    if (isnum) |p| p.* = 0;
    return 0;
}

export fn lua_tonumberx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) f64 {
    const st = asState(L) orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    if (st.tonumber(idx)) |v| {
        if (isnum) |p| p.* = 1;
        return v;
    }
    if (isnum) |p| p.* = 0;
    return 0;
}

export fn lua_getglobal(L: ?*lua_State, name: [*:0]const u8) c_int {
    const st = asState(L) orelse return -1;
    const ty = st.getglobal(std.mem.span(name)) catch return -1;
    return switch (ty) {
        .nil => 0,
        .boolean => 1,
        .number => 3,
        .string => 4,
        .table => 5,
        .function => 6,
        .userdata => 7,
        .thread => 8,
    };
}

export fn lua_setglobal(L: ?*lua_State, name: [*:0]const u8) void {
    const st = asState(L) orelse return;
    _ = st.setglobal(std.mem.span(name)) catch {};
}

export fn lua_next(L: ?*lua_State, idx: c_int) c_int {
    const st = asState(L) orelse return 0;
    return if (st.next(idx) catch false) 1 else 0;
}

export fn luaL_loadbufferx(L: ?*lua_State, buff: [*]const u8, sz: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int {
    _ = mode;
    const st = asState(L) orelse return 2;
    const chunk = buff[0..sz];
    const status = st.loadbuffer(chunk, std.mem.span(name));
    return statusCode(status);
}

export fn luaL_loadfilex(L: ?*lua_State, filename: [*:0]const u8, mode: ?[*:0]const u8) c_int {
    _ = mode;
    const st = asState(L) orelse return 2;
    return statusCode(st.loadfile(std.mem.span(filename)));
}

export fn lua_pcallk(L: ?*lua_State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?*const anyopaque) c_int {
    _ = errfunc;
    _ = ctx;
    _ = k;
    const st = asState(L) orelse return 2;
    if (nargs < 0) return 2;
    return statusCode(st.pcall(@intCast(nargs), nresults));
}

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
