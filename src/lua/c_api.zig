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
const Closure = vm_mod.Closure;

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

/// PUC `luaL_Reg` (lauxlib.h): a {name, func} pair terminated by a sentinel
/// entry whose `name` is NULL. Used by `luaL_setfuncs` / `luaL_newlib` to bulk
/// register C functions into a table. Layout matches the C struct so a pointer
/// returned by a loaded .so's `luaopen_*` is directly reinterpret-able.
const luaL_Reg = extern struct {
    name: ?[*:0]const u8,
    func: ?*const fn (?*lua_State) callconv(.c) c_int,
};

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

// ---------------------------------------------------------------------------
// Stack manipulation (PUC lapi.c: lua_pushvalue / lua_insert / lua_remove /
// lua_rotate). These operate purely on `c_stack`, mirroring PUC's
// `L->stack`/`L->top` pointer arithmetic.
// ---------------------------------------------------------------------------

/// PUC `lua_pushvalue`: push a copy of the value at `idx` onto the top.
export fn lua_pushvalue(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    const i = normalizeIndex(idx, top) orelse return;
    vm.c_stack.append(vm.alloc, vm.c_stack.items[i]) catch {};
}

/// PUC `lua_insert`: move the top element down so it ends up at `idx`,
/// shifting [idx, top-1) up by one. Equivalent to `lua_rotate(L, idx, 1)`.
export fn lua_insert(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    if (top == 0) return;
    const i = normalizeIndex(idx, top) orelse return;
    const val = vm.c_stack.items[top - 1];
    var j: usize = top - 1;
    while (j > i) : (j -= 1) vm.c_stack.items[j] = vm.c_stack.items[j - 1];
    vm.c_stack.items[i] = val;
}

/// PUC `lua_remove`: remove the value at `idx`, shifting above elements down.
export fn lua_remove(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    if (top == 0) return;
    const i = normalizeIndex(idx, top) orelse return;
    var j: usize = i;
    while (j + 1 < top) : (j += 1) vm.c_stack.items[j] = vm.c_stack.items[j + 1];
    vm.c_stack.items.len -= 1;
}

/// PUC `lua_rotate`: rotate the stack segment [idx, top) by `n` positions.
/// Positive `n` moves the top `n` elements to the bottom of the segment; a
/// negative `n` moves the bottom `|n|` elements to the top.
export fn lua_rotate(L: ?*lua_State, idx: c_int, n: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    const i = normalizeIndex(idx, top) orelse return;
    const n_items: i64 = @intCast(top - i);
    if (n_items == 0) return;
    // PUC normalises n into [0, n_items) and applies a three-stage reversal
    // (lapi.c lua_reverse(p,m) / lua_reverse(m+1,t) / lua_reverse(p,t)) whose
    // first reversal covers the leading (n_items - n) elements. Zig's
    // std.mem.rotate(items, amount) performs the same three reversals with the
    // first covering the leading `amount` elements, so the correspondence is
    // amount = (n_items - n) mod n_items. (Using `amount = n` would rotate in
    // the opposite direction.)
    const n_mod: i64 = @rem(@as(i64, n), n_items);
    const n_norm: u64 = @intCast(if (n_mod < 0) n_mod + n_items else n_mod);
    const n_items_u: usize = @intCast(n_items);
    const amount: usize = if (n_norm == 0) 0 else n_items_u - @as(usize, @intCast(n_norm));
    std.mem.rotate(Value, vm.c_stack.items[i..top], amount);
}

// ---------------------------------------------------------------------------
// Table construction & field access (PUC lapi.c).
//
// `lua_createtable` allocates a GC-tracked table (PUC `lua_createtable` →
// `luaH_new` + `checkGC`). `lua_setfield`/`lua_getfield` go through the
// metamethod-respecting `apiSetTable`/`apiGetTable` (PUC implements them with
// `luaV_finishset`/`luaV_finishget`), while `lua_rawset`/`lua_rawget` bypass
// metamethods via `apiRawSet`/`apiRawGet`.
// ---------------------------------------------------------------------------

/// PUC `lua_createtable`: push a new empty table. `narr`/`nrec` hints are
/// accepted for API compatibility but not yet fed to the allocator.
export fn lua_createtable(L: ?*lua_State, narr: c_int, nrec: c_int) void {
    _ = narr;
    _ = nrec;
    const vm = L orelse return;
    const t = vm.apiNewTable() catch return;
    vm.c_stack.append(vm.alloc, .{ .Table = t }) catch {};
}

/// PUC `lua_setfield`: does t[k] = v, where t is at `idx` and v is the top
/// value (popped). Respects `__newindex` like PUC's `luaV_finishset`.
export fn lua_setfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    if (top == 0) return;
    const i = normalizeIndex(idx, top) orelse return;
    const tbl = vm.c_stack.items[i];
    const val = vm.c_stack.items[top - 1];
    vm.c_stack.items.len -= 1;
    const key_str = vm.internStr(std.mem.span(k)) catch return;
    vm.apiSetTable(tbl, .{ .String = key_str }, val) catch {};
}

/// PUC `lua_getfield`: pushes t[k], where t is at `idx`. Respects `__index`
/// like PUC's `luaV_finishget`.
export fn lua_getfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    const i = normalizeIndex(idx, top) orelse return;
    const tbl = vm.c_stack.items[i];
    const key_str = vm.internStr(std.mem.span(k)) catch {
        vm.c_stack.append(vm.alloc, .Nil) catch {};
        return;
    };
    const v = vm.apiGetTable(tbl, .{ .String = key_str }) catch .Nil;
    vm.c_stack.append(vm.alloc, v) catch {};
}

/// PUC `lua_rawset`: does t[k] = v raw (no `__newindex`). t is at `idx`,
/// key at top-1, value at top; both popped.
export fn lua_rawset(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    if (top < 2) return;
    const i = normalizeIndex(idx, top) orelse return;
    const tbl = switch (vm.c_stack.items[i]) {
        .Table => |t| t,
        else => {
            vm.c_stack.items.len -= 2;
            return;
        },
    };
    const key = vm.c_stack.items[top - 2];
    const val = vm.c_stack.items[top - 1];
    vm.c_stack.items.len -= 2;
    vm.apiRawSet(tbl, key, val) catch {};
}

/// PUC `lua_rawget`: pushes t[k] raw (no `__index`). t is at `idx`, key at
/// top; key is replaced by the value.
export fn lua_rawget(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    if (top < 1) return;
    const i = normalizeIndex(idx, top) orelse return;
    const key = vm.c_stack.items[top - 1];
    const v: Value = switch (vm.c_stack.items[i]) {
        .Table => |t| vm.apiRawGet(t, key) catch .Nil,
        else => .Nil,
    };
    vm.c_stack.items[top - 1] = v;
}

// ---------------------------------------------------------------------------
// String helpers (PUC lapi.c / lauxlib.c).
// ---------------------------------------------------------------------------

/// PUC `lua_pushlstring`: push an arbitrary-length string (bytes may contain
/// embedded NULs) by interning a length-delimited slice.
export fn lua_pushlstring(L: ?*lua_State, s: [*]const u8, len: usize) void {
    const vm = L orelse return;
    const ls = vm.internStr(s[0..len]) catch return;
    vm.c_stack.append(vm.alloc, .{ .String = ls }) catch {};
}

/// PUC `lua_pushliteral`: convenience alias for `lua_pushstring`.
export fn lua_pushliteral(L: ?*lua_State, s: [*:0]const u8) void {
    lua_pushstring(L, s);
}

/// PUC `luaL_checklstring`: return the bytes of the string at `arg`, or "" on
/// type mismatch (a full error raise is deferred until the setjmp-based error
/// path lands in Task B2). When `l` is non-null, the string length is written
/// to `l.*`, matching the PUC signature.
export fn luaL_checklstring(L: ?*lua_State, arg: c_int, l: ?*usize) [*:0]const u8 {
    const vm = L orelse {
        if (l) |p| p.* = 0;
        return "";
    };
    const top = vm.c_stack.items.len;
    const i = normalizeIndex(arg, top) orelse {
        if (l) |p| p.* = 0;
        return "";
    };
    switch (vm.c_stack.items[i]) {
        .String => |s| {
            if (l) |p| p.* = s.bytes().len;
            return @ptrCast(@constCast(s.bytes().ptr));
        },
        else => {
            if (l) |p| p.* = 0;
            return "";
        },
    }
}

// ---------------------------------------------------------------------------
// Library registration (PUC lauxlib.c: luaL_setfuncs / luaL_newlib).
// ---------------------------------------------------------------------------

/// PUC `luaL_setfuncs`: register every `{name, func}` in `reg` into the table
/// located `nup` slots below the top, optionally closing over `nup` shared
/// upvalues. Each entry becomes a C closure (Closure.c_func set; proto null).
///
/// Task B1 wires VM call dispatch to invoke `c_func`; A2 only populates the
/// closures and table so the registration side is complete.
export fn luaL_setfuncs(L: ?*lua_State, reg: [*]const luaL_Reg, nup: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    const nupu: usize = @intCast(@max(nup, 0));
    // PUC positions the target table at -(nup+1); with a 0-based top that is
    // index `top - nupu - 1`.
    if (top < nupu + 1) return;
    const tbl_idx: usize = top - nupu - 1;
    const tbl = switch (vm.c_stack.items[tbl_idx]) {
        .Table => |t| t,
        else => return,
    };
    var i: usize = 0;
    while (reg[i].name != null) : (i += 1) {
        const name = std.mem.span(reg[i].name.?);
        const key_str = vm.internStr(name) catch continue;
        // PUC lauxlib.c luaL_setfuncs: a NULL `func` is a placeholder entry —
        // PUC pushes `false` for it. We mirror that so partially-filled
        // `luaL_Reg` arrays behave identically.
        // TODO(PUC-parity): when `c_func` upvalue sharing lands (B1), this
        // branch stays; only the else branch gains upvalue wiring.
        if (reg[i].func == null) {
            vm.apiRawSet(tbl, .{ .String = key_str }, .{ .Bool = false }) catch {};
            continue;
        }
        // Build a C closure. Upvalues are not yet wired (PUC stores them in
        // CClosure.upval); A2 leaves the upvalue slice empty — Task B1 will
        // thread shared upvalue cells through here.
        const cl = vm.alloc.create(Closure) catch return;
        cl.* = .{
            .upvalues = &.{},
            .c_func = reg[i].func,
        };
        vm.gcRegisterClosure(cl) catch {};
        vm.apiRawSet(tbl, .{ .String = key_str }, .{ .Closure = cl }) catch {};
    }
    // Pop the upvalues (PUC leaves only the library table on the stack).
    vm.c_stack.items.len -= nupu;
}

/// PUC `luaL_newlib`: convenience macro — create a fresh table and register
/// `reg` into it with no upvalues.
export fn luaL_newlib(L: ?*lua_State, reg: [*]const luaL_Reg) void {
    lua_createtable(L, 0, 0);
    luaL_setfuncs(L, reg, 0);
}

// ---------------------------------------------------------------------------
// Miscellaneous (PUC lauxlib.c / lapi.c).
// ---------------------------------------------------------------------------

/// PUC `luaL_checkversion`: no-op. Version mismatches are a compile-time
/// invariant in our setup, so the runtime check always passes.
export fn luaL_checkversion(L: ?*lua_State) void {
    _ = L;
}

/// PUC `lua_pushfstring`. Zig cannot form a C variadic directly, so this
/// pushes the format string verbatim. The `%d`/`%s` formatting path used by
/// some test libraries is deferred to a small C wrapper in Task B2.
// TODO(B2): implement via C wrapper for variadic args (lua_pushfstring with
// %d/%s/%f formatting currently returns the raw fmt string).
export fn lua_pushfstring(L: ?*lua_State, fmt: [*:0]const u8, ...) void {
    lua_pushstring(L, fmt);
}

/// PUC reference sentinels (lauxlib.h). `luaL_ref` returns `LUA_REFNIL` when
/// the value being referenced is nil (the nil is popped, not stored), and
/// `LUA_NOREF` for an invalid call (no value / bad table). `luaL_unref`
/// accepts either. PUC would `luaL_argerror` on a bad table argument; the shim
/// returns `LUA_NOREF` instead so callers can react without a longjmp.
pub const LUA_REFNIL: c_int = -1;
pub const LUA_NOREF: c_int = -2;

/// PUC `luaL_ref`: store the top value in table `t` under a fresh integer key
/// and return that key (the "ref"). PUC keeps a free-list in t[0] for
/// recycling; we use a monotonic counter (`c_ref_counter`) — semantically
/// equivalent for lookup, just without ref reuse. Returns:
///   - `LUA_REFNIL` (-1) when the value is nil (PUC pops it without storing);
///   - `LUA_NOREF`  (-2) on an invalid call (empty stack / not a table);
///   - otherwise a non-negative integer reference.
export fn luaL_ref(L: ?*lua_State, t: c_int) c_int {
    const vm = L orelse return LUA_NOREF;
    const top = vm.c_stack.items.len;
    if (top == 0) return LUA_NOREF;
    const val = vm.c_stack.items[top - 1];
    // PUC checks `lua_isnil(L, -1)` first and returns LUA_REFNIL without ever
    // touching `t`; pop the operand in every path (PUC consumes it).
    vm.c_stack.items.len -= 1;
    if (val == .Nil) return LUA_REFNIL;
    const tbl_idx = normalizeIndex(t, top) orelse return LUA_NOREF;
    const tbl = switch (vm.c_stack.items[tbl_idx]) {
        .Table => |tt| tt,
        else => return LUA_NOREF,
    };
    const ref_key: i64 = vm.c_ref_counter;
    vm.c_ref_counter += 1;
    vm.apiRawSet(tbl, .{ .Int = ref_key }, val) catch return LUA_NOREF;
    return @intCast(ref_key);
}

/// PUC `lua_pushcfunction`: push a C closure wrapping `f` (no upvalues).
export fn lua_pushcfunction(L: ?*lua_State, f: ?*const fn (?*lua_State) callconv(.c) c_int) void {
    const vm = L orelse return;
    const cl = vm.alloc.create(Closure) catch return;
    cl.* = .{
        .upvalues = &.{},
        .c_func = f,
    };
    vm.gcRegisterClosure(cl) catch {};
    vm.c_stack.append(vm.alloc, .{ .Closure = cl }) catch {};
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

// Helper: read the integer at a (1- or negative) c-stack index.
fn intAt(L: ?*lua_State, idx: c_int) i64 {
    var ok: c_int = 0;
    return lua_tointegerx(L, idx, &ok);
}

test "c api pushvalue/insert/remove" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    // pushvalue: duplicate top.
    lua_pushinteger(L, 10);
    lua_pushvalue(L, -1);
    try std.testing.expectEqual(@as(c_int, 2), lua_gettop(L));
    try std.testing.expectEqual(@as(i64, 10), intAt(L, -1));
    try std.testing.expectEqual(@as(i64, 10), intAt(L, -2));

    // Start fresh: [1 2 3 4].
    lua_settop(L, 0);
    lua_pushinteger(L, 1);
    lua_pushinteger(L, 2);
    lua_pushinteger(L, 3);
    lua_pushinteger(L, 4);

    // insert(idx=1) moves top (4) to the bottom: [4 1 2 3].
    lua_insert(L, 1);
    try std.testing.expectEqual(@as(i64, 4), intAt(L, 1));
    try std.testing.expectEqual(@as(i64, 1), intAt(L, 2));
    try std.testing.expectEqual(@as(i64, 2), intAt(L, 3));
    try std.testing.expectEqual(@as(i64, 3), intAt(L, 4));

    // remove(idx=2) drops the 1: [4 2 3].
    lua_remove(L, 2);
    try std.testing.expectEqual(@as(c_int, 3), lua_gettop(L));
    try std.testing.expectEqual(@as(i64, 4), intAt(L, 1));
    try std.testing.expectEqual(@as(i64, 2), intAt(L, 2));
    try std.testing.expectEqual(@as(i64, 3), intAt(L, 3));
}

test "c api rotate matches PUC direction" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    // Build [1 2 3 4 5] (1 at bottom, 5 at top).
    var i: i64 = 1;
    while (i <= 5) : (i += 1) lua_pushinteger(L, i);

    // PUC lua_rotate(idx=1, n=2) moves the top 2 to the bottom: [4 5 1 2 3].
    lua_rotate(L, 1, 2);
    try std.testing.expectEqual(@as(i64, 4), intAt(L, 1));
    try std.testing.expectEqual(@as(i64, 5), intAt(L, 2));
    try std.testing.expectEqual(@as(i64, 1), intAt(L, 3));
    try std.testing.expectEqual(@as(i64, 2), intAt(L, 4));
    try std.testing.expectEqual(@as(i64, 3), intAt(L, 5));

    // Negative n=-1 moves the bottom element to the top: [5 1 2 3 4].
    lua_rotate(L, 1, -1);
    try std.testing.expectEqual(@as(i64, 5), intAt(L, 1));
    try std.testing.expectEqual(@as(i64, 4), intAt(L, 5));

    // n=0 is a no-op.
    lua_rotate(L, 1, 0);
    try std.testing.expectEqual(@as(i64, 5), intAt(L, 1));
    try std.testing.expectEqual(@as(i64, 4), intAt(L, 5));
}

test "c api createtable setfield/getfield" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    lua_createtable(L, 0, 0); // [t]
    lua_pushinteger(L, 42); // [t 42]
    lua_setfield(L, 1, "x"); // [t]
    lua_getfield(L, 1, "x"); // [t 42]
    try std.testing.expectEqual(@as(c_int, 2), lua_gettop(L));
    try std.testing.expectEqual(@as(i64, 42), intAt(L, -1));
    // Missing field yields nil (type code 0).
    try std.testing.expectEqual(@as(c_int, 5), lua_type(L, 1)); // table still a table
    lua_getfield(L, 1, "absent"); // [t 42 nil]
    try std.testing.expectEqual(@as(c_int, 0), lua_type(L, -1));
}

test "c api rawset/rawget" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    lua_createtable(L, 0, 0); // [t]
    lua_pushinteger(L, 1); // key
    lua_pushinteger(L, 99); // value
    lua_rawset(L, -3); // [t]
    lua_pushinteger(L, 1); // key
    lua_rawget(L, -2); // [t 99]
    try std.testing.expectEqual(@as(i64, 99), intAt(L, -1));
}

test "c api pushlstring and newlib push closure/table" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    // pushlstring with embedded NUL.
    const bytes = [_]u8{ 'a', 0, 'b' };
    lua_pushlstring(L, &bytes, bytes.len);
    try std.testing.expectEqual(@as(c_int, 4), lua_type(L, -1)); // string type code

    // lua_pushcfunction pushes a Closure (type code 6 = function).
    const f: ?*const fn (?*lua_State) callconv(.c) c_int = struct {
        fn r(_: ?*lua_State) callconv(.c) c_int {
            return 0;
        }
    }.r;
    lua_pushcfunction(L, f);
    try std.testing.expectEqual(@as(c_int, 6), lua_type(L, -1));

    // luaL_newlib pushes a table containing the registered function.
    const reg = [_]luaL_Reg{
        .{ .name = "noop", .func = f },
        .{ .name = null, .func = null },
    };
    luaL_newlib(L, &reg);
    try std.testing.expectEqual(@as(c_int, 5), lua_type(L, -1)); // table type code
    lua_getfield(L, -1, "noop");
    try std.testing.expectEqual(@as(c_int, 6), lua_type(L, -1)); // registered fn
}

test "c api luaL_checklstring returns NUL-terminated C string" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    // A LuaString with no embedded NUL: checklstring must hand back a pointer
    // whose terminator is a real '\0' byte (storage now reserves it, matching
    // PUC luaS_createlngstrobj).
    lua_pushlstring(L, "hello", 5);
    var len: usize = 0;
    const ptr = luaL_checklstring(L, -1, &len);
    try std.testing.expectEqual(@as(usize, 5), len);
    const span = std.mem.span(ptr); // reads until '\0'
    try std.testing.expectEqualStrings("hello", span);
}

test "c api luaL_ref LUA_REFNIL / LUA_NOREF / ref" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    // Empty stack -> LUA_NOREF (top==0 guard).
    try std.testing.expectEqual(LUA_NOREF, luaL_ref(L, 1));

    lua_createtable(L, 0, 0); // registry table at index 1; stack=[t]

    // Valid value -> non-negative ref; value is consumed.
    lua_pushinteger(L, 111);
    const r1 = luaL_ref(L, 1);
    try std.testing.expect(r1 >= 0);
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L)); // only the table

    // Nil value -> LUA_REFNIL (-1), popped, not stored.
    lua_pushnil(L);
    try std.testing.expectEqual(LUA_REFNIL, luaL_ref(L, 1));

    // Second valid value -> next monotonic counter.
    lua_pushinteger(L, 222);
    const r3 = luaL_ref(L, 1);
    try std.testing.expectEqual(@as(c_int, r1 + 1), r3);

    // Non-table target -> LUA_NOREF. Clear stack, push two ints so index 1 is
    // an int (the value at top is consumed, then index 1 is found not-a-table).
    lua_settop(L, 0);
    lua_pushinteger(L, 5);
    lua_pushinteger(L, 6);
    try std.testing.expectEqual(LUA_NOREF, luaL_ref(L, 1));
}
