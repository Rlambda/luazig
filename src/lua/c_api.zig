const std = @import("std");
const stdio = @import("util").stdio;
const api = @import("api.zig");
const vm_mod = @import("vm.zig");

// Compilation pipeline used by luaL_loadbufferx / luaL_loadfilex. Mirrors the
// imports of api.zig's compileChunk helper — the C shim now compiles against
// the Vm directly rather than going through api.State.
const ast = @import("ast.zig");
const codegen_bc = @import("codegen_bc.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const source_mod = @import("source.zig");

const Vm = vm_mod.Vm;
const Value = vm_mod.Value;

// C-ABI shim for partial Lua C API compatibility.
//
// Each exported function operates directly on a `*Vm` via its `c_stack` field
// — a dedicated push/pop stack mirroring PUC Lua's `L->stack` used by C
// extension functions. This keeps loaded .so modules honest: they interact
// with the real running VM, not a separate state wrapper.
//
// `lua_State` IS `Vm`. C functions receive the same VM the bytecode dispatch
// loop runs on; `c_stack` provides the C-API push/pop surface that PUC Lua
// implements on `L->stack`.

pub const lua_State = Vm;

fn statusCode(st: api.Status) c_int {
    return switch (st) {
        .ok => 0,
        .yielded => 1,
        .runtime_error => 2,
        .syntax_error => 3,
        .memory_error => 4,
    };
}

/// PUC-style pseudo-index resolution. Positive `idx` is absolute (1-based);
/// negative `idx` is relative to top. Returns null for invalid indices
/// (0 or out of range), matching api.State.normalizeIndexConst semantics.
fn normalizeIndex(idx: c_int, top: usize) ?usize {
    if (idx == 0) return null;
    if (idx > 0) {
        const abs: usize = @intCast(idx - 1);
        return if (abs < top) abs else null;
    }
    const r: usize = @intCast(-idx);
    if (r == 0 or r > top) return null;
    return top - r;
}

/// Maps an api.Type to the LUA_T* integer code used by lua_type/lua_getglobal.
fn typeCode(ty: api.Type) c_int {
    return switch (ty) {
        .nil => 0,
        .boolean => 1,
        .lightuserdata => 2,
        .number => 3,
        .string => 4,
        .table => 5,
        .function => 6,
        .userdata => 7,
        .thread => 8,
    };
}

/// Compile a source chunk into a Closure Value. Uses the same
// lexer/parser/codegen pipeline as api.State.compileChunk so loaded chunks
// behave identically whether compiled through the Zig or C API surface.
fn compileChunk(vm: *Vm, bytes: []const u8, chunk_name: []const u8) !Value {
    const src: source_mod.Source = .{ .name = chunk_name, .bytes = bytes };
    var lex = lexer.Lexer.init(src);
    var p = parser.Parser.init(&lex) catch return error.Syntax;
    var arena = ast.AstArena.init(vm.alloc);
    defer arena.deinit();
    const chunk = p.parseChunkAst(&arena) catch return error.Syntax;
    var cg_bc = codegen_bc.Codegen.init(vm.alloc, src.name, src.bytes);
    defer cg_bc.deinit();
    const proto = cg_bc.compileChunk(chunk) catch return error.Syntax;
    const cl = try vm.createBytecodeChunkClosure(proto);
    return Value{ .Closure = cl };
}

fn mapCompileError(err_val: anyerror) api.Status {
    return switch (err_val) {
        error.Syntax => .syntax_error,
        error.OutOfMemory => .memory_error,
        else => .runtime_error,
    };
}

export fn luaL_newstate() ?*lua_State {
    const alloc = std.heap.c_allocator;
    const ptr = alloc.create(lua_State) catch return null;
    ptr.* = lua_State.init(alloc);
    return ptr;
}

export fn lua_close(L: ?*lua_State) void {
    const vm = L orelse return;
    vm.deinit();
    std.heap.c_allocator.destroy(vm);
}

export fn lua_gettop(L: ?*lua_State) c_int {
    const vm = L orelse return 0;
    return @intCast(vm.c_stack.items.len);
}

export fn lua_settop(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    var new_top: usize = 0;
    if (idx >= 0) {
        new_top = @intCast(idx);
    } else {
        const top_i: i64 = @intCast(top);
        const idx_i: i64 = @intCast(idx);
        const nt = top_i + idx_i + 1;
        if (nt < 0) return;
        new_top = @intCast(nt);
    }
    if (new_top < top) {
        vm.c_stack.items.len = new_top;
        return;
    }
    const add = new_top - top;
    vm.c_stack.appendNTimes(vm.alloc, .Nil, add) catch {};
}

export fn lua_pop(L: ?*lua_State, n: c_int) void {
    const vm = L orelse return;
    if (n <= 0) return;
    const dn: usize = @intCast(n);
    if (dn > vm.c_stack.items.len) return;
    vm.c_stack.items.len -= dn;
}

export fn lua_pushnil(L: ?*lua_State) void {
    const vm = L orelse return;
    vm.c_stack.append(vm.alloc, .Nil) catch {};
}

export fn lua_pushboolean(L: ?*lua_State, b: c_int) void {
    const vm = L orelse return;
    vm.c_stack.append(vm.alloc, .{ .Bool = b != 0 }) catch {};
}

export fn lua_pushinteger(L: ?*lua_State, v: i64) void {
    const vm = L orelse return;
    vm.c_stack.append(vm.alloc, .{ .Int = v }) catch {};
}

export fn lua_pushnumber(L: ?*lua_State, v: f64) void {
    const vm = L orelse return;
    vm.c_stack.append(vm.alloc, .{ .Num = v }) catch {};
}

export fn lua_pushstring(L: ?*lua_State, s: [*:0]const u8) void {
    const vm = L orelse return;
    const ls = vm.internStr(std.mem.span(s)) catch return;
    vm.c_stack.append(vm.alloc, .{ .String = ls }) catch {};
}

export fn lua_type(L: ?*lua_State, idx: c_int) c_int {
    const vm = L orelse return -1;
    const abs = normalizeIndex(idx, vm.c_stack.items.len) orelse return -1;
    return typeCode(api.valueType(vm.c_stack.items[abs]));
}

export fn lua_toboolean(L: ?*lua_State, idx: c_int) c_int {
    const vm = L orelse return 0;
    const abs = normalizeIndex(idx, vm.c_stack.items.len) orelse return 0;
    const v = vm.c_stack.items[abs];
    return switch (v) {
        .Nil => 0,
        .Bool => |b| if (b) 1 else 0,
        else => 1,
    };
}

export fn lua_tointegerx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) i64 {
    const vm = L orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    const abs = normalizeIndex(idx, vm.c_stack.items.len) orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    const v = vm.c_stack.items[abs];
    const result: ?i64 = switch (v) {
        .Int => |i| i,
        .Num => |n| if (n == @round(n)) @as(i64, @intFromFloat(n)) else null,
        else => null,
    };
    if (result) |i| {
        if (isnum) |p| p.* = 1;
        return i;
    }
    if (isnum) |p| p.* = 0;
    return 0;
}

export fn lua_tonumberx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) f64 {
    const vm = L orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    const abs = normalizeIndex(idx, vm.c_stack.items.len) orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    const v = vm.c_stack.items[abs];
    const result: ?f64 = switch (v) {
        .Int => |i| @floatFromInt(i),
        .Num => |n| n,
        else => null,
    };
    if (result) |n| {
        if (isnum) |p| p.* = 1;
        return n;
    }
    if (isnum) |p| p.* = 0;
    return 0;
}

export fn lua_getglobal(L: ?*lua_State, name: [*:0]const u8) c_int {
    const vm = L orelse return -1;
    const v = vm.apiGetGlobal(std.mem.span(name));
    vm.c_stack.append(vm.alloc, v) catch return -1;
    return typeCode(api.valueType(v));
}

export fn lua_setglobal(L: ?*lua_State, name: [*:0]const u8) void {
    const vm = L orelse return;
    if (vm.c_stack.items.len == 0) return;
    const v = vm.c_stack.items[vm.c_stack.items.len - 1];
    vm.c_stack.items.len -= 1;
    vm.apiSetGlobal(std.mem.span(name), v) catch {};
}

export fn lua_next(L: ?*lua_State, idx: c_int) c_int {
    const vm = L orelse return 0;
    const abs = normalizeIndex(idx, vm.c_stack.items.len) orelse return 0;
    const tbl = switch (vm.c_stack.items[abs]) {
        .Table => |t| t,
        else => return 0,
    };
    if (vm.c_stack.items.len == 0) return 0;
    const key = vm.c_stack.items[vm.c_stack.items.len - 1];
    var out: [2]Value = .{ .Nil, .Nil };
    const produced = vm.apiNext(tbl, key, out[0..]) catch return 0;
    vm.c_stack.items.len -= 1;
    if (produced == 0) return 0;
    vm.c_stack.appendSlice(vm.alloc, out[0..2]) catch return 0;
    return 1;
}

export fn luaL_loadbufferx(L: ?*lua_State, buff: [*]const u8, sz: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int {
    _ = mode;
    const vm = L orelse return 2;
    const chunk = buff[0..sz];
    const compiled = compileChunk(vm, chunk, std.mem.span(name)) catch |e| return statusCode(mapCompileError(e));
    vm.c_stack.append(vm.alloc, compiled) catch return statusCode(.memory_error);
    return 0;
}

export fn luaL_loadfilex(L: ?*lua_State, filename: [*:0]const u8, mode: ?[*:0]const u8) c_int {
    _ = mode;
    const vm = L orelse return 2;
    const source = source_mod.Source.loadFile(vm.alloc, stdio.activeIo(), std.mem.span(filename)) catch return statusCode(.memory_error);
    defer vm.alloc.free(source.name);
    defer vm.alloc.free(source.bytes);
    const compiled = compileChunk(vm, source.bytes, source.name) catch |e| return statusCode(mapCompileError(e));
    vm.c_stack.append(vm.alloc, compiled) catch return statusCode(.memory_error);
    return 0;
}

export fn lua_pcallk(L: ?*lua_State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?*const anyopaque) c_int {
    _ = errfunc;
    _ = ctx;
    _ = k;
    const vm = L orelse return 2;
    if (nargs < 0) return 2;
    const n: usize = @intCast(nargs);
    if (vm.c_stack.items.len < n + 1) return statusCode(.runtime_error);
    const fn_idx = vm.c_stack.items.len - n - 1;
    const callee = vm.c_stack.items[fn_idx];
    const args = vm.c_stack.items[fn_idx + 1 ..];
    const ret = vm.apiCall(callee, args) catch return statusCode(.runtime_error);
    defer vm.alloc.free(ret);
    vm.c_stack.items.len = fn_idx;
    const want: usize = if (nresults < 0)
        ret.len
    else
        @min(ret.len, @as(usize, @intCast(nresults)));
    vm.c_stack.appendSlice(vm.alloc, ret[0..want]) catch return statusCode(.memory_error);
    return 0;
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
