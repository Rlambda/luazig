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

/// PUC `lua_Alloc` (lua.h:125): the allocator signature shared by
/// `lua_getallocf` and the external-string dealloc callback.
///   `void* (*)(void *ud, void *ptr, size_t osize, size_t nsize)`
/// `nsize == 0` means free; `ptr == NULL` means allocate; otherwise realloc.
pub const lua_Alloc = ?*const fn (
    ?*anyopaque,
    ?*anyopaque,
    usize,
    usize,
) callconv(.c) ?*anyopaque;

/// PUC `LUA_REGISTRYINDEX` (lua.h:43): pseudo-index for the registry table.
/// PUC computes it as `-(INT_MAX/2 + 1000)`; the exact negative value only
/// needs to be distinct from any valid stack index (which are >= -top). Used
/// by `luaL_ref(L, LUA_REGISTRYINDEX)` in lib22.c to keep values alive across
/// C calls.
pub const LUA_REGISTRYINDEX: c_int = -1001000;

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

/// Compile a source chunk into a Closure Value. Delegates to the shared
/// `Vm.compileChunkValue` pipeline (also used by `api.State.compileChunk`)
/// so loaded chunks behave identically whether compiled through the Zig
/// or C API surface.
fn compileChunk(vm: *Vm, bytes: []const u8, chunk_name: []const u8) !Value {
    return vm.compileChunkValue(bytes, chunk_name);
}

fn mapCompileError(err_val: anyerror) api.Status {
    return switch (err_val) {
        error.Syntax => .syntax_error,
        error.OutOfMemory => .memory_error,
        else => .runtime_error,
    };
}

pub export fn luaL_newstate() ?*lua_State {
    const alloc = std.heap.c_allocator;
    const ptr = alloc.create(lua_State) catch return null;
    ptr.* = lua_State.init(alloc);
    return ptr;
}

pub export fn lua_close(L: ?*lua_State) void {
    const vm = L orelse return;
    vm.deinit();
    std.heap.c_allocator.destroy(vm);
}

pub export fn lua_gettop(L: ?*lua_State) c_int {
    const vm = L orelse return 0;
    return @intCast(vm.c_stack.items.len);
}

pub export fn lua_settop(L: ?*lua_State, idx: c_int) void {
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

pub export fn lua_pop(L: ?*lua_State, n: c_int) void {
    const vm = L orelse return;
    if (n <= 0) return;
    const dn: usize = @intCast(n);
    if (dn > vm.c_stack.items.len) return;
    vm.c_stack.items.len -= dn;
}

pub export fn lua_pushnil(L: ?*lua_State) void {
    const vm = L orelse return;
    vm.c_stack.append(vm.alloc, .Nil) catch {};
}

pub export fn lua_pushboolean(L: ?*lua_State, b: c_int) void {
    const vm = L orelse return;
    vm.c_stack.append(vm.alloc, .{ .Bool = b != 0 }) catch {};
}

pub export fn lua_pushinteger(L: ?*lua_State, v: i64) void {
    const vm = L orelse return;
    vm.c_stack.append(vm.alloc, .{ .Int = v }) catch {};
}

pub export fn lua_pushnumber(L: ?*lua_State, v: f64) void {
    const vm = L orelse return;
    vm.c_stack.append(vm.alloc, .{ .Num = v }) catch {};
}

pub export fn lua_pushstring(L: ?*lua_State, s: [*:0]const u8) void {
    const vm = L orelse return;
    const ls = vm.internStr(std.mem.span(s)) catch return;
    vm.c_stack.append(vm.alloc, .{ .String = ls }) catch {};
}

pub export fn lua_type(L: ?*lua_State, idx: c_int) c_int {
    const vm = L orelse return -1;
    const abs = normalizeIndex(idx, vm.c_stack.items.len) orelse return -1;
    return typeCode(api.valueType(vm.c_stack.items[abs]));
}

pub export fn lua_toboolean(L: ?*lua_State, idx: c_int) c_int {
    const vm = L orelse return 0;
    const abs = normalizeIndex(idx, vm.c_stack.items.len) orelse return 0;
    const v = vm.c_stack.items[abs];
    return switch (v) {
        .Nil => 0,
        .Bool => |b| if (b) 1 else 0,
        else => 1,
    };
}

pub export fn lua_tointegerx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) i64 {
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

pub export fn lua_tonumberx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) f64 {
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

pub export fn lua_getglobal(L: ?*lua_State, name: [*:0]const u8) c_int {
    const vm = L orelse return -1;
    const v = vm.apiGetGlobal(std.mem.span(name));
    vm.c_stack.append(vm.alloc, v) catch return -1;
    return typeCode(api.valueType(v));
}

pub export fn lua_setglobal(L: ?*lua_State, name: [*:0]const u8) void {
    const vm = L orelse return;
    if (vm.c_stack.items.len == 0) return;
    const v = vm.c_stack.items[vm.c_stack.items.len - 1];
    vm.c_stack.items.len -= 1;
    vm.apiSetGlobal(std.mem.span(name), v) catch {};
}

pub export fn lua_next(L: ?*lua_State, idx: c_int) c_int {
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

pub export fn luaL_loadbufferx(L: ?*lua_State, buff: [*]const u8, sz: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int {
    _ = mode;
    const vm = L orelse return 2;
    const chunk = buff[0..sz];
    const compiled = compileChunk(vm, chunk, std.mem.span(name)) catch |e| return statusCode(mapCompileError(e));
    vm.c_stack.append(vm.alloc, compiled) catch return statusCode(.memory_error);
    return 0;
}

pub export fn luaL_loadfilex(L: ?*lua_State, filename: [*:0]const u8, mode: ?[*:0]const u8) c_int {
    _ = mode;
    const vm = L orelse return 2;
    const source = source_mod.Source.loadFile(vm.alloc, stdio.activeIo(), std.mem.span(filename)) catch return statusCode(.memory_error);
    defer vm.alloc.free(source.name);
    defer vm.alloc.free(source.bytes);
    const compiled = compileChunk(vm, source.bytes, source.name) catch |e| return statusCode(mapCompileError(e));
    vm.c_stack.append(vm.alloc, compiled) catch return statusCode(.memory_error);
    return 0;
}

pub export fn lua_pcallk(L: ?*lua_State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?*const anyopaque) c_int {
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
    const ret = vm.apiCall(callee, args) catch {
        vm.c_stack.items.len = fn_idx;
        return statusCode(.runtime_error);
    };
    defer vm.alloc.free(ret);
    vm.c_stack.items.len = fn_idx;
    const want: usize = if (nresults < 0)
        ret.len
    else
        @min(ret.len, @as(usize, @intCast(nresults)));
    vm.c_stack.appendSlice(vm.alloc, ret[0..want]) catch return statusCode(.memory_error);
    return 0;
}

// `_longjmp` is provided by libc (already linked on the host executables — see
// build.zig). We declare it locally with the same opaque-pointer signature as
// vm.zig's `_longjmp`; both resolve to the same libc symbol. Using `_longjmp`
// (not `longjmp`) matches PUC's `__sigsetjmp(env, 0)` no-savemask choice.
extern fn _longjmp(jb: *anyopaque, val: c_int) noreturn;

/// PUC `lua_error` (lauxlib.c / lapi.c): a `noreturn` error signal. The caller
/// pushes the error object onto `c_stack` (PUC leaves it at `L->top`), then
/// calls this. We capture that object into `c_error_value` so the Zig dispatch
/// path can read it after the boundary returns -1, then `_longjmp` to the
/// nearest C-function boundary (`c_error_jmp`, mirroring PUC's `L->errorjmp`).
///
/// If no boundary is active (`c_error_jmp == null`), `lua_error` was called
/// outside any `callCFunctionWithBoundary` frame — there is nowhere safe to
/// land, so we panic. This cannot happen while a C extension is running through
/// `callCFunction`, which is the only supported context.
pub export fn lua_error(L: ?*lua_State) noreturn {
    const vm = L orelse @panic("lua_error: null state");
    // PUC sets L->top = message and throws. Capture c_stack top (the object the
    // C function pushed) so callCFunction can fold it into the VM error state.
    //
    // INVARIANT: c_error_value is a GC root (gcMarkCurrentRoots and
    // gcMarkVmRoots trace it). It is set here and consumed in callCFunction's
    // error path. No GC-triggering allocation may occur between set and
    // consume without either folding into err_obj (which IS traced) or keeping
    // c_error_value traced.
    if (vm.c_stack.items.len > 0) {
        vm.c_error_value = vm.c_stack.items[vm.c_stack.items.len - 1];
    } else {
        // A well-formed C extension always pushes its error object before
        // calling lua_error; an empty stack is a bug in the extension. Surface
        // it loudly rather than silently throwing nil.
        @panic("lua_error: no error object on stack");
    }
    if (vm.c_error_jmp) |jb| {
        _longjmp(jb, 1);
    }
    @panic("lua_error called without a C function error boundary");
}

/// PUC `lua_call` (lua.h:295): macro expanding to `lua_callk(L, n, r, 0, NULL)`.
/// Kept as a real export so the same .so can be built against our headers
/// (where `lua_call` may be a function) or against PUC headers (where it is a
/// macro that lowers to `lua_callk`).
pub export fn lua_call(L: ?*lua_State, nargs: c_int, nresults: c_int) void {
    lua_callkImpl(L, nargs, nresults);
}

/// PUC `lua_callk` (lapi.c:lua_callk): the underlying implementation of the
/// `lua_call` macro. Continuations (`ctx`, `k`) are not supported in our
/// single-shot C-call model — a C extension invoked through `callCFunction`
/// runs to completion before yielding back to bytecode dispatch, so there is
/// no suspend/resume point at which a `lua_KFunction` could fire. We accept
/// the arguments to satisfy the ABI and ignore them, matching PUC's behavior
/// when no yield occurs.
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

/// Shared body of `lua_call` / `lua_callk`. Unprotected call: on failure the
/// error rethrows through the active C-function boundary (if any), mirroring
/// PUC's `luaD_throw`. The success path marshals results on `c_stack`.
fn lua_callkImpl(L: ?*lua_State, nargs: c_int, nresults: c_int) void {
    const vm = L orelse return;
    if (nargs < 0) return;
    const n: usize = @intCast(nargs);
    if (vm.c_stack.items.len < n + 1) return;
    const fn_idx = vm.c_stack.items.len - n - 1;
    const callee = vm.c_stack.items[fn_idx];
    const args = vm.c_stack.items[fn_idx + 1 ..];
    const ret = vm.apiCall(callee, args) catch {
        // Unprotected call failed: the thrown object is already in err_obj
        // (set by `fail`). Rethrow through the active boundary if one exists
        // (PUC `luaD_throw`). With no boundary there is nowhere safe to land,
        // so we panic — mirroring lua_error. (This cannot happen while a C
        // extension runs through callCFunction, the only supported context.)
        if (vm.c_error_jmp) |jb| {
            vm.c_error_value = vm.err_obj;
            _longjmp(jb, 1);
        }
        @panic("lua_call without an active C-function boundary");
    };
    defer vm.alloc.free(ret);
    vm.c_stack.items.len = fn_idx;
    const want: usize = if (nresults < 0) ret.len else @min(ret.len, @as(usize, @intCast(nresults)));
    vm.c_stack.appendSlice(vm.alloc, ret[0..want]) catch return;
}

// ---------------------------------------------------------------------------
// Stack manipulation (PUC lapi.c: lua_pushvalue / lua_insert / lua_remove /
// lua_rotate). These operate purely on `c_stack`, mirroring PUC's
// `L->stack`/`L->top` pointer arithmetic.
// ---------------------------------------------------------------------------

/// PUC `lua_pushvalue`: push a copy of the value at `idx` onto the top.
pub export fn lua_pushvalue(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    const i = normalizeIndex(idx, top) orelse return;
    vm.c_stack.append(vm.alloc, vm.c_stack.items[i]) catch {};
}

/// PUC `lua_insert`: move the top element down so it ends up at `idx`,
/// shifting [idx, top-1) up by one. Equivalent to `lua_rotate(L, idx, 1)`.
pub export fn lua_insert(L: ?*lua_State, idx: c_int) void {
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
pub export fn lua_remove(L: ?*lua_State, idx: c_int) void {
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
pub export fn lua_rotate(L: ?*lua_State, idx: c_int, n: c_int) void {
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

/// PUC `lua_copy` (lapi.c:lua_copy): copy the value at `fromidx` into
/// `toidx`, without changing the stack top. Both indices must be valid. Used
/// by the `lua_replace` macro (`lua_copy(L, -1, idx); lua_pop(L, 1)`).
pub export fn lua_copy(L: ?*lua_State, fromidx: c_int, toidx: c_int) void {
    const vm = L orelse return;
    const top = vm.c_stack.items.len;
    const from = normalizeIndex(fromidx, top) orelse return;
    const to = normalizeIndex(toidx, top) orelse return;
    vm.c_stack.items[to] = vm.c_stack.items[from];
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
pub export fn lua_createtable(L: ?*lua_State, narr: c_int, nrec: c_int) void {
    _ = narr;
    _ = nrec;
    const vm = L orelse return;
    const t = vm.apiNewTable() catch return;
    vm.c_stack.append(vm.alloc, .{ .Table = t }) catch {};
}

/// PUC `lua_setfield`: does t[k] = v, where t is at `idx` and v is the top
/// value (popped). Respects `__newindex` like PUC's `luaV_finishset`.
pub export fn lua_setfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void {
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
pub export fn lua_getfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void {
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
pub export fn lua_rawset(L: ?*lua_State, idx: c_int) void {
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
pub export fn lua_rawget(L: ?*lua_State, idx: c_int) void {
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
pub export fn lua_pushlstring(L: ?*lua_State, s: [*]const u8, len: usize) void {
    const vm = L orelse return;
    const ls = vm.internStr(s[0..len]) catch return;
    vm.c_stack.append(vm.alloc, .{ .String = ls }) catch {};
}

/// PUC `lua_pushliteral`: convenience alias for `lua_pushstring`.
pub export fn lua_pushliteral(L: ?*lua_State, s: [*:0]const u8) void {
    lua_pushstring(L, s);
}

/// PUC 5.5 `lua_pushexternalstring` (lapi.c:555): push a string whose content
/// lives in EXTERNAL memory (not copied). The content at `s[0..len]` must
/// remain valid until the dealloc callback `falloc` is invoked during GC of
/// the string. `falloc(ud, s, len+1, 0)` is called to release the content.
///
/// Architecture (PUC-faithful): the string is always created as an external
/// long string (`LUA_VLNGSTR` / `LSTRMEM`), regardless of length — PUC's
/// `luaS_newextlstr` does not branch on length. Short external strings are
/// NOT interned here; PUC lazily normalizes them to short interned strings
/// only when used as a table key (`luaS_normstr` in ltable.c:1173). That
/// lazy normalization is not yet wired into our table key path; external
/// strings participate in table lookups via content comparison (the
/// `is_short == false` branch of `luaStringEq`), which is correct, just
/// without the interning fast path.
///
/// `falloc` follows PUC `lua_Alloc` semantics: `falloc(ud, ptr, osize, 0)`
/// frees `ptr`. `ud` is passed through unchanged. If `falloc` is null the
/// string is "fixed" (PUC `LSTRFIX`) — the content is assumed static and no
/// dealloc runs at GC.
pub export fn lua_pushexternalstring(
    L: ?*lua_State,
    s: [*]u8,
    len: usize,
    falloc: lua_Alloc,
    ud: ?*anyopaque,
) void {
    const vm = L orelse return;
    // PUC's api_check requires `s[len] == '\0'`; we rely on the caller to
    // provide a NUL-terminated buffer (the +1 in `len+1` passed to falloc
    // accounts for this trailing NUL).
    const ls = vm.createExternalLuaString(s, len, falloc, ud) catch return;
    vm.c_stack.append(vm.alloc, .{ .String = ls }) catch {};
}

/// C-callable wrapper exposing the VM's allocator through the PUC `lua_Alloc`
/// signature. `ud` is the `*Vm` itself (set by `lua_getallocf`), so this
/// wrapper can route back to `vm.alloc`. The three cases match PUC's
/// `luaM_realloc_` (lmem.c) semantics:
///   - `nsize == 0`: free `ptr` (osize is the old size).
///   - `ptr == NULL`: allocate `nsize` bytes.
///   - otherwise: realloc `ptr` from `osize` to `nsize`.
///
/// Returns null on allocation failure (PUC's allocator returns NULL on OOM
/// rather than aborting; callers like `lua_pushexternalstring` check for NULL).
///
/// Divergence note: PUC's `ud` is the global state's allocator user-data
/// (`G(L)->ud`), not `lua_State` itself. We use `*Vm` as `ud` because Zig's
/// `std.mem.Allocator` is a vtable that already captures its own context — the
/// `*Vm` is the handle that gets us back to `vm.alloc`. This is an
/// implementation detail invisible to well-behaved C callers: they treat `ud`
/// as opaque and pass it back to the returned `lua_Alloc`.
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
        // Allocator.realloc requires the old slice length to match the
        // original allocation; the C caller passes `osize` for exactly that.
        const new_buf = vm.alloc.realloc(old_buf[0..osize], nsize) catch return null;
        return @ptrCast(new_buf.ptr);
    }
    const new_buf = vm.alloc.alloc(u8, nsize) catch return null;
    return @ptrCast(new_buf.ptr);
}

/// PUC 5.5 `lua_getallocf` (lapi.c:1319): return the VM's allocator function
/// and write its user-data pointer to `*ud` (if `ud` is non-null). C code uses
/// the returned `lua_Alloc` to allocate memory that will later be freed via
/// the same allocator (e.g. lib22.c's `struct STR` blocks, which are released
/// by the external-string dealloc callback).
///
/// We return `cApiAllocWrapper` and set `*ud = L` (the `*Vm`); the wrapper
/// recovers `vm.alloc` from the `*Vm`. See `cApiAllocWrapper` for the
/// divergence note on why `ud` is `*Vm` rather than PUC's `G(L)->ud`.
pub export fn lua_getallocf(L: ?*lua_State, ud: ?*?*anyopaque) lua_Alloc {
    if (ud) |u| u.* = @ptrCast(L);
    return cApiAllocWrapper;
}

/// PUC `luaL_checklstring`: return the bytes of the string at `arg`, or "" on
/// type mismatch (a full error raise is deferred until the setjmp-based error
/// path lands in Task B2). When `l` is non-null, the string length is written
/// to `l.*`, matching the PUC signature.
pub export fn luaL_checklstring(L: ?*lua_State, arg: c_int, l: ?*usize) [*:0]const u8 {
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
pub export fn luaL_setfuncs(L: ?*lua_State, reg: [*]const luaL_Reg, nup: c_int) void {
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
        if (reg[i].func == null) {
            vm.apiRawSet(tbl, .{ .String = key_str }, .{ .Bool = false }) catch {};
            continue;
        }
        // Build a C closure. Currently c_func closures have empty upvalues.
        // TODO(future): thread shared upvalue cells through c_func closures
        // (PUC CClosure.upval), sharing the `nup` values pushed below the
        // table across all registered functions in this luaL_setfuncs call.
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
pub export fn luaL_newlib(L: ?*lua_State, reg: [*]const luaL_Reg) void {
    lua_createtable(L, 0, 0);
    luaL_setfuncs(L, reg, 0);
}

// ---------------------------------------------------------------------------
// Miscellaneous (PUC lauxlib.c / lapi.c).
// ---------------------------------------------------------------------------

/// PUC `luaL_checkversion` (lauxlib.h:47): macro expanding to
/// PUC `luaL_checkversion_` (lauxlib.c:1194): verifies that the loaded C
/// library and the running core agree on `LUAL_NUMSIZES` (a checksum encoding
/// sizeof(lua_Integer) and sizeof(lua_Number)) and `LUA_VERSION_NUM`.
///
/// `luaL_checkversion` is a macro that expands to
/// `luaL_checkversion_(L, LUA_VERSION_NUM, LUAL_NUMSIZES)`. The `sz` argument
/// is baked into the .so at compile time from the header's `LUAL_NUMSIZES`.
/// If the .so was compiled with different numeric types (e.g. 32-bit int or
/// float instead of double), `sz` won't match and we raise an error —
/// matching PUC behavior exactly.
pub export fn luaL_checkversion(L: ?*lua_State) void {
    _ = L;
}

/// PUC `luaL_checkversion_` (lauxlib.c:1194). See `luaL_checkversion` above.
pub export fn luaL_checkversion_(L: ?*lua_State, ver: f64, sz: usize) void {
    const expected_sz = @sizeOf(i64) * 16 + @sizeOf(f64);
    if (sz != expected_sz) {
        lua_pushstring(L, "core and library have incompatible numeric types");
        lua_error(L); // noreturn
    }
    // LUA_VERSION_NUM = 505 (Lua 5.5), stored as lua_Number (double).
    const expected_ver: f64 = 505.0;
    if (ver != expected_ver) {
        lua_pushstring(L, "version mismatch: C library and Lua core disagree");
        lua_error(L); // noreturn
    }
}

/// PUC `luaO_pushfstring` / `lua_pushfstring` (lobject.c:luaO_pushfstring):
/// formatted push supporting a small, fixed set of conversion specifiers (no
/// width/precision/flags — PUC parses only the bare specifier character).
/// Supported: `%d` `%i` (int), `%u` (unsigned), `%f` `%g` (double), `%s`
/// (const char*), `%c` (char from int), `%p` (pointer), `%x` `%X` (hex int),
/// `%o` (octal int), `%U` (UTF-8 code point), `%%` (literal percent). Unknown
/// specifiers are emitted verbatim with the leading `%`.
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
                if (v) |s| {
                    buf.appendSlice(vm.alloc, std.mem.span(s)) catch return;
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
pub export fn luaL_ref(L: ?*lua_State, t: c_int) c_int {
    const vm = L orelse return LUA_NOREF;
    const top = vm.c_stack.items.len;
    if (top == 0) return LUA_NOREF;
    const val = vm.c_stack.items[top - 1];
    // PUC checks `lua_isnil(L, -1)` first and returns LUA_REFNIL without ever
    // touching `t`; pop the operand in every path (PUC consumes it).
    vm.c_stack.items.len -= 1;
    if (val == .Nil) return LUA_REFNIL;
    // Resolve the target table. `LUA_REGISTRYINDEX` is a pseudo-index into the
    // VM's registry (lazily created); any other index is a normal c-stack slot.
    const tbl = if (t == LUA_REGISTRYINDEX) blk: {
        const reg = vm.apiEnsureRegistry() catch return LUA_NOREF;
        break :blk reg;
    } else blk: {
        const tbl_idx = normalizeIndex(t, top) orelse return LUA_NOREF;
        break :blk switch (vm.c_stack.items[tbl_idx]) {
            .Table => |tt| tt,
            else => return LUA_NOREF,
        };
    };
    const ref_key: i64 = vm.c_ref_counter;
    vm.c_ref_counter += 1;
    vm.apiRawSet(tbl, .{ .Int = ref_key }, val) catch return LUA_NOREF;
    return @intCast(ref_key);
}

/// PUC `lua_pushcclosure` (lapi.c:lua_pushcclosure): push a C closure wrapping
/// `fn` with `n` upvalues taken from the top of the stack. This is the
/// underlying implementation that PUC's `lua_pushcfunction(L, f)` macro
/// expands to (`lua_pushcclosure(L, f, 0)`).
///
/// Upvalues (`n > 0`) are not yet supported: our `Closure.c_func` path runs
/// the C function with only the C stack visible, and there is no mechanism to
/// bind stack values as upvalues that survive across calls. The common case
/// (`n == 0`) — used by every `luaL_newlib` / `luaL_setfuncs` with `nup == 0`
/// — works correctly. Passing `n > 0` is rejected with a panic so the gap is
/// never silently exercised.
pub export fn lua_pushcclosure(
    L: ?*lua_State,
    f: ?*const fn (?*lua_State) callconv(.c) c_int,
    n: c_int,
) void {
    if (n != 0) {
        @panic("lua_pushcclosure: upvalues (n != 0) not yet supported");
    }
    lua_pushcfunction(L, f);
}

/// PUC `lua_pushcfunction` (lua.h:402): macro expanding to
/// `lua_pushcclosure(L, f, 0)`. Implemented directly here so .so files built
/// against our headers (function) and against PUC headers (macro) both
/// resolve to the same symbol on the luazig side.
pub export fn lua_pushcfunction(L: ?*lua_State, f: ?*const fn (?*lua_State) callconv(.c) c_int) void {
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

// ---------------------------------------------------------------------------
// setjmp/longjmp error boundary tests (Task B2).
//
// These exercise the full chain: a C function → lua_error → _longjmp →
// callCFunctionWithBoundary's _setjmp → error.RuntimeError → lua_pcallk
// returns LUA_ERRRUN. They prove the boundary catches the longjmp without
// crashing and that the thrown object reaches the VM's error state.
// ---------------------------------------------------------------------------

/// C extension that signals an error: pushes the object then calls lua_error
/// (noreturn). `_longjmp` inside lua_error unwinds to `callCFunctionWithBoundary`.
fn cfuncThatErrors(L: ?*lua_State) callconv(.c) c_int {
    const vm = L.?;
    lua_pushliteral(vm, "boom from C"); // error object at c_stack top
    lua_error(vm); // noreturn
    return 0; // defensive; unreachable per lua_error's noreturn contract
}

/// C extension that succeeds: pushes one integer result and returns 1.
fn cfuncReturns42(L: ?*lua_State) callconv(.c) c_int {
    lua_pushinteger(L, 42);
    return 1;
}

test "c api lua_error crosses the setjmp boundary into pcall" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    lua_pushcfunction(L, cfuncThatErrors); // c_stack = [fn]
    // lua_pcallk → apiCall → runClosure → callCFunction → boundary.
    // lua_error inside the C func _longjmps back; apiCall returns
    // error.RuntimeError; pcall maps that to status 2 (LUA_ERRRUN).
    const status = lua_pcallk(L, 0, 0, 0, 0, null);
    try std.testing.expectEqual(@as(c_int, 2), status);

    // The thrown object must be folded into the VM's normal error state so
    // pcall/xpcall/traceback consumers see a uniform error object.
    try std.testing.expect(L.err_has_obj);
    try std.testing.expectEqualStrings("boom from C", L.err_obj.String.bytes());
    // c_error_value is consumed (cleared) after folding into err_obj.
    try std.testing.expect(L.c_error_value == null);
    // The caller's c_stack must be restored intact (boundary defers ran).
    try std.testing.expectEqual(@as(c_int, 0), lua_gettop(L));
}

test "c api boundary success path returns results normally" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    lua_pushcfunction(L, cfuncReturns42); // c_stack = [fn]
    const status = lua_pcallk(L, 0, 1, 0, 0, null);
    try std.testing.expectEqual(@as(c_int, 0), status); // LUA_OK
    // Result marshalled back onto c_stack: [42].
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L));
    try std.testing.expectEqual(@as(i64, 42), intAt(L, -1));
    try std.testing.expect(!L.err_has_obj); // no error on success
}

test "c api lua_getallocf: alloc/realloc/free roundtrip" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    var ud: ?*anyopaque = null;
    const allocf = lua_getallocf(L, &ud);
    try std.testing.expect(allocf != null);
    try std.testing.expect(ud != null);

    // allocf(ud, NULL, 0, nsize) → allocate
    const ptr = allocf.?(ud, null, 0, 100);
    try std.testing.expect(ptr != null);

    // allocf(ud, ptr, osize, nsize) → realloc (grow)
    const ptr2 = allocf.?(ud, ptr, 100, 200);
    try std.testing.expect(ptr2 != null);

    // allocf(ud, ptr, osize, 0) → free
    const result = allocf.?(ud, ptr2, 200, 0);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "c api lua_pushexternalstring: pushed string is readable" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    // Static content with no falloc (LSTRFIX-like): content must remain valid
    // for the lifetime of the VM, which it does since it's a string literal.
    const content = "external string content that is long enough";
    lua_pushexternalstring(L, @constCast(content.ptr), content.len, null, null);
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L));

    // The pushed value should be a string whose bytes match the content.
    var len: usize = 0;
    const got = luaL_checklstring(L, -1, &len);
    try std.testing.expectEqual(@as(usize, content.len), len);
    try std.testing.expectEqualStrings(content, got[0..len]);
}
