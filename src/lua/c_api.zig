const std = @import("std");
const stdio = @import("util").stdio;
const api = @import("api.zig");
const vm_mod = @import("vm.zig");

// Compilation pipeline used by luaL_loadbufferx / luaL_loadfilex.
const source_mod = @import("source.zig");

// Binary chunk serializer (used by lua_dump).
const dump_mod = @import("dump.zig");

// Bytecode types (Proto, Constant, etc.) — used by lua_dump.
const bc = @import("bytecode.zig");

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

/// PUC `luaL_Buffer` (lauxlib.h): dynamic string builder used by C libraries.
/// Layout matches PUC 5.5 exactly so C code allocating it on the C stack is
/// binary-compatible. The `init` union provides an inline buffer of
/// LUAL_BUFFERSIZE bytes; when the buffer grows beyond that, luaL_prepbuffsize
/// spills to heap allocation via the VM's allocator.
pub const luaL_Buffer = extern struct {
    b: [*c]u8,
    size: usize,
    n: usize,
    L: ?*lua_State,
    init: [1024]u8, // LUAL_BUFFERSIZE on 64-bit (16 * 8 * 8)
};

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

/// PUC `lua_pushfstring` (lapi.c): formatted push with C vararg. Delegates
/// to `lua_pushvfstring` (the `luaO_pushvfstring` equivalent) after
/// initializing the va_list with `@cVaStart`. This mirrors PUC's
/// `lua_pushfstring` which is a thin `va_start`/`lua_pushvfstring`/`va_end`
/// wrapper (lapi.c:587-594).
pub export fn lua_pushfstring(L: ?*lua_State, fmt: [*:0]const u8, ...) [*:0]const u8 {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return lua_pushvfstring(L, fmt, &ap);
}

/// PUC `lua_pushvfstring` (lapi.c) / `luaO_pushvfstring` (lobject.c): the
/// core formatting engine. Walks `fmt`, copying literal text to a buffer and
/// substituting `%`-specifiers from the C vararg list `argp`. PUC supports:
/// `%s` (string), `%c` (char), `%d` (int), `%I` (lua_Integer), `%f`
/// (lua_Number), `%p` (pointer), `%U` (UTF-8 codepoint), `%%` (literal
/// percent). Unknown specifiers are kept verbatim (PUC's `default` case).
///
/// The `argp` parameter is a C `va_list`; on x86-64 Linux `va_list` is
/// `struct __va_list_tag[1]` which decays to `*struct __va_list_tag` when
/// passed as a parameter, matching Zig's `*std.builtin.VaList`.
///
/// Returns a NUL-terminated pointer to the interned result string.
pub export fn lua_pushvfstring(
    L: ?*lua_State,
    fmt: [*:0]const u8,
    argp: *std.builtin.VaList,
) [*:0]const u8 {
    const vm = L orelse return "".ptr;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.alloc);

    var i: usize = 0;
    while (true) {
        const c = fmt[i];
        if (c == 0) break;
        if (c != '%') {
            buf.append(vm.alloc, c) catch return "".ptr;
            i += 1;
            continue;
        }
        i += 1;
        const spec = fmt[i];
        switch (spec) {
            0 => {
                buf.append(vm.alloc, '%') catch return "".ptr;
                break;
            },
            'd' => {
                const v = @cVaArg(argp, c_int);
                const s = std.fmt.allocPrint(vm.alloc, "{d}", .{v}) catch return "".ptr;
                defer vm.alloc.free(s);
                buf.appendSlice(vm.alloc, s) catch return "".ptr;
            },
            'I' => {
                const v = @cVaArg(argp, i64);
                const s = std.fmt.allocPrint(vm.alloc, "{d}", .{v}) catch return "".ptr;
                defer vm.alloc.free(s);
                buf.appendSlice(vm.alloc, s) catch return "".ptr;
            },
            'f' => {
                const v = @cVaArg(argp, f64);
                const s = std.fmt.allocPrint(vm.alloc, "{d}", .{v}) catch return "".ptr;
                defer vm.alloc.free(s);
                buf.appendSlice(vm.alloc, s) catch return "".ptr;
            },
            's' => {
                const v = @cVaArg(argp, ?[*:0]const u8);
                if (v) |str| {
                    buf.appendSlice(vm.alloc, std.mem.span(str)) catch return "".ptr;
                } else {
                    buf.appendSlice(vm.alloc, "(null)") catch return "".ptr;
                }
            },
            'c' => {
                const v = @cVaArg(argp, c_int);
                buf.append(vm.alloc, @intCast(@as(u32, @bitCast(v)) & 0xFF)) catch return "".ptr;
            },
            'p' => {
                const v = @cVaArg(argp, ?*anyopaque);
                const s = std.fmt.allocPrint(vm.alloc, "{x}", .{@intFromPtr(v)}) catch return "".ptr;
                defer vm.alloc.free(s);
                buf.appendSlice(vm.alloc, s) catch return "".ptr;
            },
            'U' => {
                const cp = @cVaArg(argp, c_int);
                var utf8: [4]u8 = undefined;
                const codepoint: u21 = @intCast(@as(u32, @bitCast(cp)) & 0x7FFFFFFF);
                const n = std.unicode.utf8Encode(codepoint, &utf8) catch 0;
                buf.appendSlice(vm.alloc, utf8[0..n]) catch return "".ptr;
            },
            '%' => buf.append(vm.alloc, '%') catch return "".ptr,
            else => {
                // PUC default: keep unknown specifier verbatim (e.g. "%x" stays "%x")
                buf.append(vm.alloc, '%') catch return "".ptr;
                buf.append(vm.alloc, spec) catch return "".ptr;
            },
        }
        i += 1;
    }

    const ls = vm.internStr(buf.items) catch return "".ptr;
    vm.c_stack.append(vm.alloc, .{ .String = ls }) catch {};
    return @ptrCast(@constCast(ls.bytes().ptr));
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

/// PUC `lua_setallocf` (lapi.c:1330): set a custom allocator.
/// TODO Phase 9: wire the custom allocator into the VM's allocation path.
/// Until then, this is a no-op — the VM continues using its built-in allocator.
/// This is a deferral, not a workaround: the function signature matches PUC
/// so C code compiles and links correctly; the allocator swap is a larger
/// architectural change that affects every allocation site.
pub export fn lua_setallocf(L: ?*lua_State, f: lua_Alloc, ud: ?*anyopaque) void {
    _ = L;
    _ = f;
    _ = ud;
}

// ===========================================================================
// Load / dump (PUC lapi.c / ldo.c / ldump.c)
// ===========================================================================

/// PUC `lua_load` (ldo.c:lua_load): load and compile a Lua chunk from a
/// reader callback. The reader is called repeatedly; each call returns a
/// pointer to a chunk and writes its size to `*sz`. NULL or zero size
/// signals end-of-input. All chunks are collected into a buffer, then
/// compiled via `Vm.compileChunkValue` (the same path as `luaL_loadbufferx`).
///
/// `mode` is currently ignored (luazig always compiles source text; binary
/// chunk loading is handled by `undump.zig` through a separate path).
pub export fn lua_load(
    L: ?*lua_State,
    reader: ?*const fn (?*lua_State, ?*anyopaque, ?*usize) callconv(.c) ?[*]const u8,
    data: ?*anyopaque,
    chunkname: ?[*:0]const u8,
    mode: ?[*:0]const u8,
) c_int {
    _ = mode;
    const vm = L orelse return 2; // LUA_ERRRUN

    // Collect all chunks from the reader into a buffer (PUC's `luaD_protectedparser`
    // does the same via `luaZ_read` into a growable buffer before parsing).
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(vm.alloc);

    while (true) {
        var sz: usize = 0;
        const chunk = reader.?(L, data, &sz) orelse break;
        if (sz == 0) break;
        buf.appendSlice(vm.alloc, chunk[0..sz]) catch return statusCode(.memory_error);
    }

    const name = if (chunkname) |n| std.mem.span(n) else "=reader";
    const compiled = vm.compileChunkValue(buf.items, name) catch |e|
        return statusCode(mapCompileError(e));
    vm.c_stack.append(vm.alloc, compiled) catch return statusCode(.memory_error);
    return 0; // LUA_OK
}

/// PUC `lua_dump` (ldo.c:lua_dump): dump the function at the top of the stack
/// as a binary chunk, feeding it to the `writer` callback. Returns 0 on
/// success, 1 on error.
///
/// Uses `DumpWriter.dumpChunk` (the same serializer as `string.dump`) to
/// produce a PUC-compatible binary chunk. Only Lua functions (Closures with
/// a non-null `proto`) can be dumped; C functions return error (matching
/// PUC's `luaU_dump` limitation).
pub export fn lua_dump(
    L: ?*lua_State,
    writer: ?*const fn (?*lua_State, ?*const anyopaque, usize, ?*anyopaque) callconv(.c) c_int,
    data: ?*anyopaque,
    strip: c_int,
) c_int {
    const vm = L orelse return 1;
    if (writer == null) return 1;

    // Get the function at the top of c_stack (PUC uses index2value(L, -1)).
    if (vm.c_stack.items.len == 0) return 1;
    const val = vm.c_stack.items[vm.c_stack.items.len - 1];
    const cl = switch (val) {
        .Closure => |c| c,
        else => return 1, // not a Lua function
    };
    const proto = cl.proto orelse return 1; // C closure — cannot dump

    // Serialize the Proto tree into a binary chunk via DumpWriter.
    // When `strip` is set, PUC clones the Proto with debug info removed.
    // We mirror that via `cloneStrippedProto` (same as `string.dump`).
    const dump_proto: *const bc.Proto = if (strip != 0) blk: {
        var seen_bc = std.AutoHashMapUnmanaged(*const bc.Proto, *bc.Proto){};
        defer seen_bc.deinit(vm.alloc);
        break :blk vm.cloneStrippedProto(proto, &seen_bc) catch return 1;
    } else proto;

    var dw = dump_mod.DumpWriter.init(vm.alloc);
    defer dw.deinit();
    dw.dumpChunk(dump_proto) catch return 1;
    const bytes = dw.toOwnedSlice() catch return 1;
    defer vm.alloc.free(bytes);

    // Feed the entire binary chunk to the writer in one call (PUC calls the
    // writer for each sub-component, but a single call is equivalent — the
    // writer is just a byte sink).
    const result = writer.?(L, @ptrCast(bytes.ptr), bytes.len, data);
    return if (result == 0) 0 else 1;
}

// ===========================================================================
// Warnings (PUC lapi.c / lobject.c)
// ===========================================================================

/// PUC `lua_setwarnf` (lapi.c:1322): install (or remove) the warning handler.
/// Passing `null` for `f` disables warnings (PUC's `lua_setwarnf(L, NULL, ud)`).
pub export fn lua_setwarnf(
    L: ?*lua_State,
    f: ?*const fn (?*anyopaque, [*:0]const u8, c_int) callconv(.c) void,
    ud: ?*anyopaque,
) void {
    const vm = L orelse return;
    vm.c_warnf = f;
    vm.c_warn_ud = ud;
}

/// PUC `lua_warning` (lapi.c:1333): emit a warning. If a warning handler is
/// installed (via `lua_setwarnf`), the message is forwarded to it. `tocont`
/// is 1 if more warning text follows (multi-part warnings). If no handler is
/// installed, the warning is silently dropped (PUC's default behavior).
pub export fn lua_warning(L: ?*lua_State, msg: ?[*:0]const u8, tocont: c_int) void {
    const vm = L orelse return;
    if (vm.c_warnf) |wf| {
        if (msg) |m| wf(vm.c_warn_ud, m, tocont);
    }
    // No handler → warning silently dropped (PUC default)
}

// ===========================================================================
// Number/string conversions (PUC lapi.c / lobject.c)
// ===========================================================================

/// PUC `lua_stringtonumber` (lapi.c:381): parse `s` as a number, push it onto
/// the stack. Returns the string length (including NUL) on success, 0 if the
/// string is not a valid number.
///
/// PUC's `luaO_str2num` tries integer first (`l_str2int`), then float
/// (`l_str2d`). Both trim leading/trailing whitespace and require the entire
/// string to be a valid number. Returns `strlen(s) + 1` on success.
pub export fn lua_stringtonumber(L: ?*lua_State, s: [*:0]const u8) usize {
    const vm = L orelse return 0;
    const str = std.mem.span(s);
    const trimmed = std.mem.trim(u8, str, " \t\n\x0b\x0c\r");
    if (trimmed.len == 0) return 0;

    // Try integer first (PUC's `l_str2int`): handles decimal and hex (0x).
    if (std.fmt.parseInt(i64, trimmed, 0)) |i| {
        vm.c_stack.append(vm.alloc, .{ .Int = i }) catch return 0;
        return str.len + 1; // PUC returns strlen(s) + 1 (including NUL)
    } else |_| {}

    // Try float (PUC's `l_str2d`): handles decimal, hex floats, inf, nan.
    if (std.fmt.parseFloat(f64, trimmed)) |n| {
        vm.c_stack.append(vm.alloc, .{ .Num = n }) catch return 0;
        return str.len + 1;
    } else |_| {}

    return 0; // not a number
}

/// PUC `lua_numbertocstring` (lapi.c:369): convert the number at `idx` to its
/// string representation in `buff`. `buff` must be at least `LUA_N2SBUFFSZ`
/// (64) bytes. Returns the string length (including NUL) on success, 0 if the
/// value at `idx` is not a number.
///
/// PUC's `luaO_tostringbuff` formats integers as `%lld` and floats as `%.14g`
/// (with ".0" appended if the result looks like an integer). luazig uses
/// Zig's `{d}` format, which produces the shortest round-trip representation.
pub export fn lua_numbertocstring(L: ?*lua_State, idx: c_int, buff: [*]u8) c_uint {
    const vm = L orelse return 0;
    const abs = normalizeIndex(idx, vm.c_stack.items.len) orelse return 0;
    const val = vm.c_stack.items[abs];

    switch (val) {
        .Int => |i| {
            const s = std.fmt.bufPrint(buff[0..64], "{d}", .{i}) catch return 0;
            buff[s.len] = 0; // NUL-terminate
            return @intCast(s.len + 1);
        },
        .Num => |n| {
            const s = std.fmt.bufPrint(buff[0..64], "{d}", .{n}) catch return 0;
            // PUC's `tostringbuffFloat` appends ".0" if the result looks like
            // an integer (no decimal point or exponent). Zig's `{d}` for f64
            // may produce "42" for 42.0, so we mirror PUC's behavior.
            const looks_like_int = blk: {
                for (s) |ch| {
                    if (ch == '.' or ch == 'e' or ch == 'E' or ch == 'n' or ch == 'i') break :blk false;
                }
                break :blk true;
            };
            if (looks_like_int and s.len + 2 < 64) {
                buff[s.len] = '.';
                buff[s.len + 1] = '0';
                buff[s.len + 2] = 0;
                return @intCast(s.len + 3);
            }
            buff[s.len] = 0;
            return @intCast(s.len + 1);
        },
        else => return 0,
    }
}

// ===========================================================================
// To-be-closed slots (PUC lapi.c)
// ===========================================================================

/// PUC `lua_toclose` (lapi.c:1340): mark the stack slot at `idx` for
/// automatic closing when it goes out of scope (PUC's to-be-closed mechanism).
/// TODO: implement the to-be-closed mechanism (requires tracking TBC slots on
/// the C stack and invoking `__close` metamethods on scope exit). This is a
/// deferral — the function signature matches PUC so C code compiles and links.
pub export fn lua_toclose(L: ?*lua_State, idx: c_int) void {
    _ = L;
    _ = idx;
}

/// PUC `lua_closeslot` (lapi.c:1350): close and remove a to-be-closed slot.
/// TODO: implement together with `lua_toclose` (requires the TBC mechanism).
pub export fn lua_closeslot(L: ?*lua_State, idx: c_int) void {
    _ = L;
    _ = idx;
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

pub export fn lua_absindex(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return @intCast(s.absindex(idx) catch 0);
}

pub export fn lua_checkstack(L: ?*lua_State, n: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    if (n < 0) return 0;
    s.checkstack(@intCast(n)) catch return 0;
    return 1;
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

// --- Type predicates (PUC lapi.c:lua_is*) ---

pub export fn lua_isnumber(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.isnumber(idx)) 1 else 0;
}

pub export fn lua_isstring(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.isstring(idx)) 1 else 0;
}

pub export fn lua_isinteger(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.isinteger(idx)) 1 else 0;
}

pub export fn lua_iscfunction(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.iscfunction(idx)) 1 else 0;
}

pub export fn lua_isuserdata(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.isuserdata(idx)) 1 else 0;
}

pub export fn lua_isyieldable(L: ?*lua_State) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.isyieldable(null) catch false) 1 else 0;
}

// --- Conversions (PUC lapi.c:lua_to*) ---

/// PUC `lua_tolstring`: convert value to string, return NUL-terminated C
/// pointer. Writes byte length to `*len` if non-null. Returns NULL for
/// non-convertible types.
pub export fn lua_tolstring(L: ?*lua_State, idx: c_int, len: ?*usize) [*:0]const u8 {
    var s = api.State.fromVm(L orelse {
        if (len) |p| p.* = 0;
        return "";
    });
    if (s.tolstring(idx)) |bytes| {
        // luazig's LuaString storage is NUL-terminated (createLuaString writes
        // body[raw.len] = 0), so the byte slice can be safely cast to [*:0].
        if (len) |p| p.* = bytes.len;
        return @ptrCast(@constCast(bytes.ptr));
    }
    if (len) |p| p.* = 0;
    return "";
}

/// PUC `lua_typename` (lapi.c:lua_typename): return the name of the type
/// identified by `tp` (a LUA_T* code). No state access needed — the names are
/// static strings matching PUC's `luaT_typenames[]`.
pub export fn lua_typename(L: ?*lua_State, tp: c_int) [*:0]const u8 {
    _ = L;
    return switch (tp) {
        0 => "nil",
        1 => "boolean",
        2 => "lightuserdata",
        3 => "number",
        4 => "string",
        5 => "table",
        6 => "function",
        7 => "userdata",
        8 => "thread",
        else => "no value",
    };
}

/// PUC `lua_rawlen` (lapi.c:lua_rawlen): raw length without metamethods.
pub export fn lua_rawlen(L: ?*lua_State, idx: c_int) c_uint {
    var s = api.State.fromVm(L orelse return 0);
    return @intCast(s.rawlen(idx));
}

/// PUC `lua_tocfunction` (lapi.c:lua_tocfunction): return C function pointer.
pub export fn lua_tocfunction(L: ?*lua_State, idx: c_int) ?*const fn (?*lua_State) callconv(.c) c_int {
    var s = api.State.fromVm(L orelse return null);
    return s.tocfunction(idx);
}

/// PUC `lua_tothread` (lapi.c:lua_tothread): return Thread pointer.
pub export fn lua_tothread(L: ?*lua_State, idx: c_int) ?*lua_State {
    var s = api.State.fromVm(L orelse return null);
    if (s.tothread(idx)) |th| return @ptrCast(th);
    return null;
}

/// PUC `lua_version` (lapi.c:lua_version): return Lua version number.
/// luazig targets Lua 5.5.0 → 505.0 (matching PUC's LUA_VERSION_NUM).
pub export fn lua_version(L: ?*lua_State) f64 {
    _ = L;
    return 505.0;
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

/// PUC `lua_gettable` (lapi.c): `t[k]` with metamethods. Pops the key,
/// pushes the value. Returns the value's type code.
pub export fn lua_gettable(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return typeCode(s.gettable(idx) catch return 0);
}

/// PUC `lua_settable` (lapi.c): `t[k] = v` with metamethods. Pops both
/// key and value.
pub export fn lua_settable(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.settable(idx) catch {};
}

/// PUC `lua_geti` (lapi.c): `t[n]` with metamethods. Pushes the value.
/// Returns the value's type code.
pub export fn lua_geti(L: ?*lua_State, idx: c_int, n: i64) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return typeCode(s.geti(idx, n) catch return 0);
}

/// PUC `lua_seti` (lapi.c): `t[n] = v` with metamethods. Pops the value.
pub export fn lua_seti(L: ?*lua_State, idx: c_int, n: i64) void {
    var s = api.State.fromVm(L orelse return);
    s.seti(idx, n) catch {};
}

/// PUC `lua_rawgeti` (lapi.c): `t[n]` without metamethods. Pushes the
/// value. Returns the value's type code.
pub export fn lua_rawgeti(L: ?*lua_State, idx: c_int, n: i64) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return typeCode(s.rawgeti(idx, n) catch return 0);
}

/// PUC `lua_rawseti` (lapi.c): `t[n] = v` without metamethods. Pops the
/// value.
pub export fn lua_rawseti(L: ?*lua_State, idx: c_int, n: i64) void {
    var s = api.State.fromVm(L orelse return);
    s.rawseti(idx, n) catch {};
}

/// PUC `lua_rawgetp` (lapi.c): `t[p]` without metamethods, where `p` is a
/// light userdata key. Pushes the value. Returns the value's type code.
pub export fn lua_rawgetp(L: ?*lua_State, idx: c_int, p: ?*anyopaque) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return typeCode(s.rawgetp(idx, p) catch return 0);
}

/// PUC `lua_rawsetp` (lapi.c): `t[p] = v` without metamethods, where `p`
/// is a light userdata key. Pops the value.
pub export fn lua_rawsetp(L: ?*lua_State, idx: c_int, p: ?*anyopaque) void {
    var s = api.State.fromVm(L orelse return);
    s.rawsetp(idx, p) catch {};
}

pub export fn lua_next(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.next(idx) catch false) 1 else 0;
}

// --- Arithmetic / comparison / length (PUC lapi.c) ---

/// PUC `lua_arith` (lapi.c:lua_arith): perform an arithmetic operation on
/// the top 1–2 stack values. For binary ops: operands at -2 and -1. For
/// unary ops (UNM, BNOT): operand at -1. Pops operands, pushes result.
pub export fn lua_arith(L: ?*lua_State, op: c_int) void {
    var s = api.State.fromVm(L orelse return);
    const arith_op: api.ArithOp = switch (op) {
        0 => .add,
        1 => .sub,
        2 => .mul,
        3 => .mod,
        4 => .pow,
        5 => .div,
        6 => .idiv,
        7 => .band,
        8 => .bor,
        9 => .bxor,
        10 => .shl,
        11 => .shr,
        12 => .unm,
        13 => .bnot,
        else => return,
    };
    s.arith(arith_op) catch {};
}

/// PUC `lua_rawequal` (lapi.c:lua_rawequal): raw equality (no __eq
/// metamethod). Returns 1 if equal, 0 otherwise.
pub export fn lua_rawequal(L: ?*lua_State, idx1: c_int, idx2: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return if (s.rawequal(idx1, idx2)) 1 else 0;
}

/// PUC `lua_compare` (lapi.c:lua_compare): comparison with metamethods.
/// op is LUA_OPEQ (0), LUA_OPLT (1), or LUA_OPLE (2). Returns 1 if the
/// comparison holds, 0 otherwise.
pub export fn lua_compare(L: ?*lua_State, idx1: c_int, idx2: c_int, op: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    const cmp_op: api.CompareOp = switch (op) {
        0 => .eq,
        1 => .lt,
        2 => .le,
        else => return 0,
    };
    return if (s.compare(idx1, idx2, cmp_op) catch false) 1 else 0;
}

/// PUC `lua_concat` (lapi.c:lua_concat): concatenate n values from the
/// top of the stack. Pops all n values, pushes the result string.
pub export fn lua_concat(L: ?*lua_State, n: c_int) void {
    var s = api.State.fromVm(L orelse return);
    if (n <= 0) return;
    s.concat(@intCast(n)) catch {};
}

/// PUC `lua_len` (lapi.c:lua_len): push the length of the value at idx.
/// For strings: byte length. For tables: border length (or __len). Pops
/// nothing, pushes the length value.
pub export fn lua_len(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.len(idx) catch {};
}

// --- Coroutines (PUC lapi.c / ldo.c) ---

/// PUC `lua_resume` (ldo.c:lua_resume): resume a coroutine. `from` is the
/// calling thread (ignored in luazig — the calling Vm IS the from thread).
/// nargs values are on the coroutine's stack. Writes the number of results
/// to *nres. Returns LUA_OK on completion, LUA_YIELD on yield, or an error
/// code.
pub export fn lua_resume(L: ?*lua_State, from: ?*lua_State, nargs: c_int, nres: ?*c_int) c_int {
    _ = from;
    var s = api.State.fromVm(L orelse return 2);
    const st = s.@"resume"(-1, @intCast(@max(nargs, 0)));
    if (nres) |p| {
        // Number of results = current top minus the coroutine itself.
        const top = s.gettop();
        p.* = @intCast(if (top > 0) top - 1 else 0);
    }
    return statusCode(st);
}

/// PUC `lua_yieldk` (ldo.c:lua_yieldk): yield from a coroutine. nresults
/// values are on the stack to be returned to the resume caller. The
/// continuation function k is ignored (continuations not supported).
pub export fn lua_yieldk(L: ?*lua_State, nresults: c_int, ctx: isize, k: ?*const anyopaque) c_int {
    _ = ctx;
    _ = k;
    var s = api.State.fromVm(L orelse return 2);
    s.yield(@intCast(@max(nresults, 0))) catch return 2;
    return 1; // LUA_YIELD
}

/// PUC `lua_status` (lapi.c:lua_status): return the status of thread L.
/// Returns LUA_OK (0) for the main thread, or the thread's error/yield
/// status code.
pub export fn lua_status(L: ?*lua_State) c_int {
    var s = api.State.fromVm(L orelse return 2);
    return s.status();
}

/// PUC `lua_pushthread` (lapi.c:lua_pushthread): push the current thread
/// onto the stack. Returns 1 if L is the main thread, 0 otherwise.
pub export fn lua_pushthread(L: ?*lua_State) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return s.pushthread();
}

// --- Garbage collection (PUC lapi.c:lua_gc) ---

/// PUC `lua_gc` (lapi.c:lua_gc): garbage collector control. `what` is a
/// LUA_GC* constant. Returns context-dependent values (memory in KB for
/// GCCOUNT, running status for GCISRUNNING, 0 for most others).
pub export fn lua_gc(L: ?*lua_State, what: c_int, data: c_int) c_int {
    var s = api.State.fromVm(L orelse return 0);
    return s.gc(what, data);
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
// Phase 5: lauxlib argument checking, error reporting, utilities
// ===========================================================================

pub export fn luaL_checktype(L: ?*lua_State, arg: c_int, t: c_int) void {
    var s = api.State.fromVm(L orelse return);
    const actual = if (s.typeOf(arg)) |ty| typeCode(ty) else @as(c_int, -1);
    if (actual != t) {
        _ = lua_pushfstring(L, "bad argument #%d (%s expected, got %s)", arg, lua_typename(L, t), lua_typename(L, actual));
        lua_error(L);
    }
}

pub export fn luaL_checkany(L: ?*lua_State, arg: c_int) void {
    var s = api.State.fromVm(L orelse return);
    if (s.typeOf(arg) == null) {
        _ = lua_pushfstring(L, "bad argument #%d (value expected)", arg);
        lua_error(L);
    }
}

pub export fn luaL_checkstack(L: ?*lua_State, sz: c_int, msg: ?[*:0]const u8) void {
    const vm = L orelse return;
    vm.c_stack.ensureUnusedCapacity(vm.alloc, @intCast(@max(sz, 0))) catch {
        lua_pushstring(L, if (msg) |m| m else "stack overflow");
        lua_error(L);
    };
}

pub export fn luaL_checknumber(L: ?*lua_State, arg: c_int) f64 {
    var s = api.State.fromVm(L orelse return 0);
    if (s.tonumber(arg)) |n| return n;
    const ty = if (s.typeOf(arg)) |t| typeCode(t) else @as(c_int, -1);
    _ = lua_pushfstring(L, "bad argument #%d (number expected, got %s)", arg, lua_typename(L, ty));
    lua_error(L);
}

pub export fn luaL_optnumber(L: ?*lua_State, arg: c_int, def: f64) f64 {
    var s = api.State.fromVm(L orelse return def);
    const ty = s.typeOf(arg);
    if (ty == null or ty.? == .nil) return def;
    if (s.tonumber(arg)) |n| return n;
    return def;
}

pub export fn luaL_optlstring(L: ?*lua_State, arg: c_int, def: ?[*:0]const u8, l: ?*usize) [*:0]const u8 {
    var s = api.State.fromVm(L orelse {
        if (l) |p| { if (def) |d| { p.* = std.mem.len(d); } else { p.* = 0; } }
        return def orelse "";
    });
    const ty = s.typeOf(arg);
    if (ty == null or ty.? == .nil) {
        if (l) |p| { if (def) |d| { p.* = std.mem.len(d); } else { p.* = 0; } }
        return def orelse "";
    }
    const bytes = s.checklstring(arg);
    if (l) |p| p.* = bytes.len;
    return @ptrCast(@constCast(bytes.ptr));
}

pub export fn luaL_checkoption(L: ?*lua_State, arg: c_int, def: ?[*:0]const u8, lst: [*]const ?[*:0]const u8) c_int {
    var s = api.State.fromVm(L orelse return -1);
    var bytes: []const u8 = undefined;
    if (s.tostring(arg)) |str| {
        bytes = str;
    } else if (def) |d| {
        bytes = std.mem.span(d);
    } else {
        _ = lua_pushfstring(L, "bad argument #%d (string expected)", arg);
        lua_error(L);
    }
    var i: usize = 0;
    while (lst[i] != null) : (i += 1) {
        if (std.mem.eql(u8, bytes, std.mem.span(lst[i].?))) return @intCast(i);
    }
    _ = lua_pushfstring(L, "bad argument #%d (invalid option)", arg);
    lua_error(L);
}

pub export fn luaL_where(L: ?*lua_State, lvl: c_int) void {
    _ = lvl;
    const vm = L orelse return;
    // TODO: proper call stack walking — push "source:line: "
    vm.c_stack.append(vm.alloc, .{ .String = vm.internStr("") catch return }) catch {};
}

pub export fn luaL_typeerror(L: ?*lua_State, arg: c_int, tname: [*:0]const u8) c_int {
    var s = api.State.fromVm(L orelse return 0);
    const ty = if (s.typeOf(arg)) |t| typeCode(t) else @as(c_int, -1);
    _ = lua_pushfstring(L, "bad argument #%d (%s expected, got %s)", arg, tname, lua_typename(L, ty));
    lua_error(L);
}

pub export fn luaL_argerror(L: ?*lua_State, arg: c_int, extramsg: ?[*:0]const u8) c_int {
    luaL_where(L, 1);
    if (extramsg) |msg| {
        _ = lua_pushfstring(L, "bad argument #%d (%s)", arg, msg);
    } else {
        _ = lua_pushfstring(L, "bad argument #%d", arg);
    }
    lua_concat(L, 2);
    lua_error(L);
}

pub export fn luaL_error(L: ?*lua_State, fmt: [*:0]const u8, ...) c_int {
    luaL_where(L, 1);
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    _ = lua_pushvfstring(L, fmt, @ptrCast(&ap));
    lua_concat(L, 2);
    lua_error(L);
}

pub export fn luaL_traceback(L: ?*lua_State, L1: ?*lua_State, msg: ?[*:0]const u8, lvl: c_int) void {
    _ = L1;
    _ = lvl;
    const vm = L orelse return;
    if (msg) |m| {
        vm.c_stack.append(vm.alloc, .{ .String = vm.internStr(std.mem.span(m)) catch return }) catch {};
    }
    // Simplified traceback — TODO: proper stack walking
    vm.c_stack.append(vm.alloc, .{ .String = vm.internStr("stack traceback:\n\t[C]: in ?") catch return }) catch {};
}

pub export fn luaL_tolstring(L: ?*lua_State, idx: c_int, l: ?*usize) [*:0]const u8 {
    var s = api.State.fromVm(L orelse { if (l) |p| p.* = 0; return ""; });
    if (s.tolstring(idx)) |bytes| {
        if (l) |p| p.* = bytes.len;
        return @ptrCast(@constCast(bytes.ptr));
    }
    if (s.typeOf(idx)) |t| {
        const name = switch (t) {
            .nil => "nil", .boolean => "true", .table => "table: 0x0",
            .function => "function: 0x0", .userdata => "userdata: 0x0",
            .thread => "thread: 0x0", .lightuserdata => "lightuserdata: 0x0",
            .number, .string => "value",
        };
        const ls = s.vm.internStr(name) catch { if (l) |p| p.* = 0; return ""; };
        s.vm.c_stack.append(s.vm.alloc, .{ .String = ls }) catch {};
        if (l) |p| p.* = name.len;
        return @ptrCast(@constCast(ls.bytes().ptr));
    }
    if (l) |p| p.* = 0;
    return "";
}

pub export fn luaL_len(L: ?*lua_State, idx: c_int) i64 {
    var s = api.State.fromVm(L orelse return 0);
    s.len(idx) catch return 0;
    const result = s.tointeger(-1) orelse 0;
    s.vm.c_stack.items.len -= 1;
    return result;
}

pub export fn luaL_gsub(L: ?*lua_State, s_str: [*:0]const u8, p: [*:0]const u8, r: [*:0]const u8) [*:0]const u8 {
    const vm = L orelse return s_str;
    const src = std.mem.span(s_str);
    const pat = std.mem.span(p);
    const rep = std.mem.span(r);
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(vm.alloc);
    var i: usize = 0;
    while (i < src.len) {
        if (pat.len > 0 and i + pat.len <= src.len and std.mem.eql(u8, src[i .. i + pat.len], pat)) {
            result.appendSlice(vm.alloc, rep) catch return s_str;
            i += pat.len;
        } else {
            result.append(vm.alloc, src[i]) catch return s_str;
            i += 1;
        }
    }
    const ls = vm.internStr(result.items) catch return s_str;
    vm.c_stack.append(vm.alloc, .{ .String = ls }) catch {};
    return @ptrCast(@constCast(ls.bytes().ptr));
}

pub export fn luaL_getmetafield(L: ?*lua_State, obj: c_int, event: [*:0]const u8) c_int {
    var s = api.State.fromVm(L orelse return 0);
    const abs = normalizeIndex(obj, s.vm.c_stack.items.len) orelse return 0;
    const mt: ?*vm_mod.Table = switch (s.vm.c_stack.items[abs]) {
        .Table => |t| t.metatable,
        .Userdata => |ud| ud.metatable,
        else => null,
    };
    if (mt) |m| {
        const key = s.vm.internStr(std.mem.span(event)) catch return 0;
        const val = s.vm.apiRawGet(m, .{ .String = key }) catch return 0;
        if (val == .Nil) return 0;
        s.vm.c_stack.append(s.vm.alloc, val) catch {};
        return 1;
    }
    return 0;
}

pub export fn luaL_callmeta(L: ?*lua_State, obj: c_int, event: [*:0]const u8) c_int {
    if (luaL_getmetafield(L, obj, event) == 0) return 0;
    var s = api.State.fromVm(L orelse return 0);
    s.pushvalue(obj) catch return 0;
    return lua_pcallk(L, 1, 1, 0, 0, null);
}

pub export fn luaL_requiref(L: ?*lua_State, modname: [*:0]const u8, openf: ?*const fn (?*lua_State) callconv(.c) c_int, glb: c_int) void {
    var s = api.State.fromVm(L orelse return);
    s.pushcfunction(openf) catch return;
    s.pushstring(std.mem.span(modname)) catch return;
    s.call(1, 1) catch return;
    // Store in package.loaded[modname]
    _ = s.getglobal("package") catch return;
    if (s.typeOf(-1)) |t| if (t == .table) {
        _ = s.getfield(-1, "loaded") catch return;
        if (s.typeOf(-1)) |t2| if (t2 == .table) {
            _ = s.pushvalue(-3) catch {};
            s.setfield(-2, std.mem.span(modname)) catch {};
        };
        s.vm.c_stack.items.len -= 1;
    };
    s.vm.c_stack.items.len -= 1;
    if (glb != 0) {
        _ = s.pushvalue(-1) catch {};
        s.setglobal(std.mem.span(modname)) catch {};
    }
}

pub export fn luaL_loadstring(L: ?*lua_State, s_str: [*:0]const u8) c_int {
    const len = std.mem.len(s_str);
    return luaL_loadbufferx(L, @ptrCast(s_str), len, s_str, null);
}

pub export fn luaL_fileresult(L: ?*lua_State, stat: c_int, fname: ?[*:0]const u8) c_int {
    var s = api.State.fromVm(L orelse return 0);
    if (stat >= 0) {
        s.pushboolean(true) catch {};
        return 1;
    }
    s.pushnil() catch {};
    s.pushstring("file error") catch {};
    if (fname) |f| {
        s.pushstring(std.mem.span(f)) catch {};
        s.concat(2) catch {};
    }
    return 3;
}

// ===========================================================================
// luaL_Buffer subsystem (PUC lauxlib.c)
// ===========================================================================

/// PUC `luaL_buffinit` (lauxlib.c:516): initialize a buffer with the inline
/// storage. The buffer struct is allocated by the C caller (typically on the
/// C stack).
pub export fn luaL_buffinit(L: ?*lua_State, B: *luaL_Buffer) void {
    B.b = &B.init[0];
    B.size = B.init.len;
    B.n = 0;
    B.L = L;
}

/// PUC `luaL_prepbuffsize` (lauxlib.c:528): ensure at least `sz` bytes of free
/// space after `n`. If the inline buffer is exhausted, spills to heap via the
/// VM's allocator. Returns a pointer to the free space starting at `b[n]`.
pub export fn luaL_prepbuffsize(B: *luaL_Buffer, sz: usize) [*c]u8 {
    const vm = B.L orelse return &B.init[0];
    if (B.n + sz <= B.size) return &B.b[B.n];

    // Need to grow. Compute new capacity (at least double, at least n+sz).
    var new_size = B.size;
    while (new_size < B.n + sz) new_size *= 2;

    if (B.b == &B.init[0]) {
        // Spilling from inline to heap: allocate and copy inline content.
        const new_buf = vm.alloc.alloc(u8, new_size) catch return &B.init[0];
        @memcpy(new_buf[0..B.n], B.init[0..B.n]);
        B.b = new_buf.ptr;
        B.size = new_size;
    } else {
        // Already on heap: realloc.
        const old_buf = B.b[0..B.size];
        const new_buf = vm.alloc.realloc(old_buf, new_size) catch return B.b;
        B.b = new_buf.ptr;
        B.size = new_size;
    }
    return &B.b[B.n];
}

/// PUC `luaL_addlstring` (lauxlib.c:566): append `l` bytes from `s` to B.
pub export fn luaL_addlstring(B: *luaL_Buffer, s: [*c]const u8, l: usize) void {
    if (l == 0) return;
    const dst = luaL_prepbuffsize(B, l);
    @memcpy(dst[0..l], s[0..l]);
    B.n += l;
}

/// PUC `luaL_addstring` (lauxlib.c:578): append NUL-terminated `s` to B.
pub export fn luaL_addstring(B: *luaL_Buffer, s: [*c]const u8) void {
    luaL_addlstring(B, s, std.mem.len(s));
}

/// PUC `luaL_addvalue` (lauxlib.c:589): pop the top value from the Lua stack,
/// convert to string (via lua_tolstring), and append to B.
pub export fn luaL_addvalue(B: *luaL_Buffer) void {
    const vm = B.L orelse return;
    if (vm.c_stack.items.len == 0) return;
    var l: usize = 0;
    const s = lua_tolstring(vm, -1, &l);
    luaL_addlstring(B, s, l);
    vm.c_stack.items.len -= 1;
}

/// PUC `luaL_pushresult` (lauxlib.c:601): push the buffer content as a Lua
/// string onto the stack, freeing any heap allocation.
pub export fn luaL_pushresult(B: *luaL_Buffer) void {
    luaL_pushresultsize(B, B.n);
}

/// PUC `luaL_pushresultsize` (lauxlib.c:593): push the first `sz` bytes of
/// the buffer as a Lua string, then free heap allocation if any.
pub export fn luaL_pushresultsize(B: *luaL_Buffer, sz: usize) void {
    const vm = B.L orelse return;
    B.n = sz;
    const ls = vm.internStr(B.b[0..sz]) catch {
        // Free heap if spilled
        if (B.b != &B.init[0]) vm.alloc.free(B.b[0..B.size]);
        return;
    };
    vm.c_stack.append(vm.alloc, .{ .String = ls }) catch {};
    // Free heap if spilled
    if (B.b != &B.init[0]) vm.alloc.free(B.b[0..B.size]);
}

/// PUC `luaL_buffinitsize` (lauxlib.c:614): initialize B and preallocate `sz`
/// bytes. Returns pointer to the buffer.
pub export fn luaL_buffinitsize(L: ?*lua_State, B: *luaL_Buffer, sz: usize) [*c]u8 {
    luaL_buffinit(L, B);
    return luaL_prepbuffsize(B, sz);
}

/// PUC `luaL_addgsub` (lauxlib.c:628): append to B the result of gsub(s, p, r).
pub export fn luaL_addgsub(B: *luaL_Buffer, s: [*c]const u8, p: [*c]const u8, r: [*c]const u8) void {
    const src = std.mem.span(s);
    const pat = std.mem.span(p);
    const rep = std.mem.span(r);
    var i: usize = 0;
    while (i < src.len) {
        if (pat.len > 0 and i + pat.len <= src.len and std.mem.eql(u8, src[i .. i + pat.len], pat)) {
            luaL_addlstring(B, @ptrCast(rep.ptr), rep.len);
            i += pat.len;
        } else {
            const ch = src[i..i + 1];
            luaL_addlstring(B, @ptrCast(ch.ptr), 1);
            i += 1;
        }
    }
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
    _ = lua_getfield(L, 1, "x");
    try std.testing.expectEqual(@as(c_int, 2), lua_gettop(L));
    try std.testing.expectEqual(@as(i64, 42), intAt(L, -1));
    try std.testing.expectEqual(@as(c_int, 5), lua_type(L, 1));
    _ = lua_getfield(L, 1, "absent");
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
    _ = lua_rawget(L, -2);
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
    _ = lua_getfield(L, -1, "noop");
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
