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

/// PUC `lua_Debug` (lua.h:307-325): debug info struct filled by
/// `lua_getinfo`/`lua_getstack` and passed to hook functions.
///
/// Layout matches the C `lua_Debug` exactly (extern struct) so C code
/// allocating it on the C stack is binary-compatible with the Zig-side
/// accessor functions. `LUA_IDSIZE` is 60 (luaconf.h:228).
pub const lua_Debug = extern struct {
    event: c_int = 0,
    name: ?[*:0]const u8 = null,
    namewhat: ?[*:0]const u8 = null,
    what: ?[*:0]const u8 = null,
    source: ?[*:0]const u8 = null,
    srclen: usize = 0,
    currentline: c_int = 0,
    linedefined: c_int = 0,
    lastlinedefined: c_int = 0,
    nups: u8 = 0,
    nparams: u8 = 0,
    isvararg: u8 = 0,
    istailcall: u8 = 0,
    ftransfer: u16 = 0,
    ntransfer: u16 = 0,
    short_src: [60]u8 = [_]u8{0} ** 60,
    i_ci: ?*anyopaque = null,
};

// Shared helpers from api.zig (single source of truth).
const normalizeIndex = api.normalizeIndex;
const typeCode = api.typeCode;
const statusCode = api.statusCode;
const mapCompileError = api.mapCompileError;

/// Resolve a C API index that may be an upvalue pseudo-index.
/// Returns the Value pointer for the upvalue, or null if not an upvalue index.
fn upvalueAt(vm: *Vm, idx: c_int) ?Value {
    // Upvalue indices are LUA_REGISTRYINDEX - n (n=1,2,...)
    // LUA_REGISTRYINDEX = -1001000
    if (idx < -1001000 and idx >= -1001255) {
        const upv_n: usize = @intCast(-1001000 - idx); // 1-based
        if (vm.c_active_closure) |cl| {
            if (upv_n >= 1 and upv_n <= cl.upvalues.len) {
                return cl.upvalues[upv_n - 1].value;
            }
        }
    }
    return null;
}

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

// ===========================================================================
// State management (PUC lstate.c / lapi.c)
// ===========================================================================

/// PUC `lua_newstate` (lstate.c:lua_newstate): create a new Lua state with an
/// optional custom allocator and random seed. In PUC, `f` is the allocator
/// function and `ud` is its opaque context; `seed` seeds the PRNG.
///
/// The custom allocator function and its user-data are stored on the Vm
/// (`c_alloc_fn` / `c_alloc_ud`) so that `lua_getallocf` can return them,
/// matching PUC's contract. The VM's actual allocations continue to use
/// `std.heap.c_allocator` — see the comment on `c_alloc_fn` for why this
/// is correct for the vast majority of `lua_Alloc` implementations.
pub export fn lua_newstate(
    f: lua_Alloc,
    ud: ?*anyopaque,
    seed: c_uint,
) ?*lua_State {
    _ = seed; // PRNG seeding not yet wired (PUC uses it for table hash randomization)
    const alloc = std.heap.c_allocator;
    const ptr = alloc.create(lua_State) catch return null;
    ptr.* = lua_State.init(alloc, false);
    ptr.c_alloc_fn = f;
    ptr.c_alloc_ud = ud;
    return ptr;
}

/// PUC `lua_newthread` (lstate.c:lua_newthread): create a new coroutine
/// ("thread") that shares the global state of `L`. The new thread has its own
/// stack but shares globals, registry, and metatables.
///
/// luazig's internal coroutine type (`Thread`) is distinct from `Vm` (the
/// `lua_State` handle). A full C-API `lua_newthread` would require allocating a
/// new `Vm` that shares the same `global_State` — an architectural change
/// planned for the coroutine phase. For now we return the same state, which is
/// safe for the main thread (PUC permits this) and lets C code that only needs
/// a scratch state compile and link. TODO: implement proper thread creation.
pub export fn lua_newthread(L: ?*lua_State) ?*lua_State {
    const vm = L orelse return null;
    return vm;
}

/// PUC `lua_closethread` (lstate.c:lua_closethread): reset a thread to a clean
/// state. In PUC this closes all upvalues, clears the stack, and sets status to
/// `LUA_OK`. `from` is the thread that initiated the close (may be NULL).
///
/// Returns `LUA_OK` (0) on success. luazig does not yet expose a per-thread
/// status reset; returning `LUA_OK` is correct for the main thread (which is
/// always in a valid state). TODO: wire thread status reset.
pub export fn lua_closethread(L: ?*lua_State, from: ?*lua_State) c_int {
    _ = from;
    _ = L orelse return 1; // LUA_ERRRUN if null
    return 0; // LUA_OK
}

/// PUC `lua_atpanic` (lapi.c:lua_atpanic): install a panic function called when
/// an error propagates past the last protected call. Returns the previous panic
/// function. The panic function is stored on the Vm (`c_panicf`).
pub export fn lua_atpanic(
    L: ?*lua_State,
    panicf: ?*const fn (?*lua_State) callconv(.c) c_int,
) ?*const fn (?*lua_State) callconv(.c) c_int {
    const vm = L orelse return null;
    const old = vm.c_panicf;
    vm.c_panicf = panicf;
    return old;
}

/// PUC `lua_getextraspace` (lua.h:lua_getextraspace): return a pointer to the
/// per-state "extra space" — a small area before `lua_State` for very fast
/// access by C extensions. luazig does not allocate this area (no
/// `LUA_EXTRASPACE`), so we return `NULL`. C code must check before use.
pub export fn lua_getextraspace(L: ?*lua_State) ?*anyopaque {
    _ = L;
    return null; // luazig doesn't implement LUA_EXTRASPACE
}

/// PUC `lua_xmove` (lapi.c:lua_xmove): move `n` values from the top of `from`'s
/// stack to the top of `to`'s stack. Both states must share the same global
/// state (i.e., `to` was created by `lua_newthread(from)`).
///
/// Operates on the C-API stack (`c_stack`), which is the stack visible to C
/// code via `lua_pushvalue` / `lua_to*`. Negative `n` is clamped to zero.
pub export fn lua_xmove(from: ?*lua_State, to: ?*lua_State, n: c_int) void {
    const src = from orelse return;
    const dst = to orelse return;
    const count: usize = @intCast(@max(n, 0));
    if (count > src.c_stack.items.len) return;
    const start = src.c_stack.items.len - count;
    dst.c_stack.appendSlice(dst.alloc, src.c_stack.items[start..]) catch {};
    src.c_stack.items.len -= count;
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
    const th = vm.current_thread orelse {
        lua_callkImpl(L, nargs, nresults);
        return;
    };

    if (k) |kf| {
        if (th.yieldable()) {
            // Save k/ctx in the current C-frame
            if (th.call_frames.len() > 0) {
                const fr = th.call_frames.getPtr(th.call_frames.len() - 1);
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
/// If a custom allocator was set via `lua_newstate` or `lua_setallocf`,
/// returns that function and its user-data — matching PUC's contract.
/// Otherwise returns the internal `cApiAllocWrapper` and `L` as user-data.
pub export fn lua_getallocf(L: ?*lua_State, ud: ?*?*anyopaque) lua_Alloc {
    const vm = L orelse return null;
    if (vm.c_alloc_fn) |f| {
        if (ud) |u| u.* = vm.c_alloc_ud;
        return f;
    }
    // Default: return our internal wrapper with L as the user-data.
    if (ud) |u| u.* = @ptrCast(L);
    return cApiAllocWrapper;
}

/// PUC `lua_setallocf` (lapi.c:1330): set a custom allocator.
/// Stores the function and user-data so `lua_getallocf` can return them.
/// The VM's actual allocations continue through `std.heap.c_allocator`;
/// see the comment on `Vm.c_alloc_fn` for the rationale.
pub export fn lua_setallocf(L: ?*lua_State, f: lua_Alloc, ud: ?*anyopaque) void {
    const vm = L orelse return;
    vm.c_alloc_fn = f;
    vm.c_alloc_ud = ud;
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
/// The slot is closed by `lua_closeslot` or when the C function returns
/// (the return-path close is not yet wired — requires integration with
/// `callCFunction`'s return boundary).
///
/// PUC chains to-be-closed slots as a linked list on the stack
/// (`L->ci->tbclist`). We store absolute indices in `c_toclose_slots`;
/// duplicate marks are ignored, matching PUC's idempotent behavior.
pub export fn lua_toclose(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const abs = normalizeIndex(idx, vm.c_stack.items.len) orelse return;
    // Check if already marked — PUC's TBC list is idempotent.
    for (vm.c_toclose_slots.items) |s| {
        if (s == abs) return;
    }
    vm.c_toclose_slots.append(vm.alloc, abs) catch {};
}

/// PUC `lua_closeslot` (lapi.c:1350): close and remove a to-be-closed slot.
/// Invokes the `__close` metamethod on the value at `idx`, then removes the
/// slot from the to-close list. PUC calls `lua_callvalue` for the metamethod;
/// we use `lua_pcallk` to protect against errors in the closer.
pub export fn lua_closeslot(L: ?*lua_State, idx: c_int) void {
    const vm = L orelse return;
    const abs = normalizeIndex(idx, vm.c_stack.items.len) orelse return;

    // Get the value at idx and look up its __close metamethod.
    const val = vm.c_stack.items[abs];
    const mm = vm.metamethodValue(val, "__close") orelse {
        // No __close metamethod — PUC raises an error, but we silently
        // remove the mark to avoid crashing C code that calls closeslot
        // on a non-closable value (defensive: the C API contract says the
        // caller must ensure the value is closable).
        removeTocloseMark(vm, abs);
        return;
    };

    // Push __close function and the value, then call via pcall.
    // PUC: lua_callvalue(L, slot) — calls __close(value) with 0 results.
    vm.c_stack.append(vm.alloc, mm) catch {
        removeTocloseMark(vm, abs);
        return;
    };
    vm.c_stack.append(vm.alloc, val) catch {
        vm.c_stack.items.len -= 1; // pop the __close fn
        removeTocloseMark(vm, abs);
        return;
    };
    _ = lua_pcallk(L, 1, 0, 0, 0, null);

    // Remove from to-close list regardless of pcall success/failure.
    removeTocloseMark(vm, abs);
}

/// Remove `abs` from `c_toclose_slots` if present (swap-remove for O(1)).
fn removeTocloseMark(vm: *Vm, abs: usize) void {
    for (vm.c_toclose_slots.items, 0..) |s, i| {
        if (s == abs) {
            _ = vm.c_toclose_slots.swapRemove(i);
            return;
        }
    }
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
    const vm = L orelse return;
    // Handle upvalue pseudo-index as destination (write to upvalue)
    if (toidx < -1001000 and toidx >= -1001255) {
        const src = upvalueAt(vm, fromidx) orelse blk: {
            const abs = normalizeIndex(fromidx, vm.c_stack.items.len) orelse return;
            break :blk vm.c_stack.items[abs];
        };
        const upv_n: usize = @intCast(-1001000 - toidx);
        if (vm.c_active_closure) |cl| {
            if (upv_n >= 1 and upv_n <= cl.upvalues.len) {
                cl.upvalues[upv_n - 1].value = src;
            }
        }
        return;
    }
    // Handle upvalue pseudo-index as source (read from upvalue)
    if (fromidx < -1001000 and fromidx >= -1001255) {
        const src = upvalueAt(vm, fromidx) orelse return;
        const abs = normalizeIndex(toidx, vm.c_stack.items.len) orelse return;
        vm.c_stack.items[abs] = src;
        return;
    }
    var s = api.State.fromVm(vm);
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
    const vm = L orelse return -1;
    if (upvalueAt(vm, idx)) |v| return typeCode(api.valueType(v));
    var s = api.State.fromVm(vm);
    return if (s.typeOf(idx)) |t| typeCode(t) else -1;
}

pub export fn lua_toboolean(L: ?*lua_State, idx: c_int) c_int {
    const vm = L orelse return 0;
    if (upvalueAt(vm, idx)) |v| return switch (v) {
        .Nil => 0, .Bool => |b| if (b) 1 else 0, else => 1,
    };
    var s = api.State.fromVm(vm);
    return if (s.toboolean(idx)) 1 else 0;
}

pub export fn lua_tointegerx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) i64 {
    const vm = L orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    if (upvalueAt(vm, idx)) |v| {
        const result: ?i64 = switch (v) {
            .Int => |i| i,
            .Num => |n| if (n == @round(n)) @as(i64, @intFromFloat(n)) else null,
            else => null,
        };
        if (result) |r| {
            if (isnum) |p| p.* = 1;
            return r;
        }
    }
    var s = api.State.fromVm(vm);
    if (s.tointeger(idx)) |v| {
        if (isnum) |p| p.* = 1;
        return v;
    }
    if (isnum) |p| p.* = 0;
    return 0;
}

pub export fn lua_tonumberx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) f64 {
    const vm = L orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    if (upvalueAt(vm, idx)) |v| {
        const result: ?f64 = switch (v) {
            .Int => |i| @floatFromInt(i),
            .Num => |n| n,
            else => null,
        };
        if (result) |r| {
            if (isnum) |p| p.* = 1;
            return r;
        }
    }
    var s = api.State.fromVm(vm);
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
/// calling thread; its C-call depth is inherited so that C-call nesting limits
/// are enforced across coroutine boundaries (PUC: `L->nCcalls = getCcalls(from) + 1`).
/// nargs values are on the coroutine's stack. Writes the number of results
/// to *nres. Returns LUA_OK on completion, LUA_YIELD on yield, or an error
/// code.
pub export fn lua_resume(L: ?*lua_State, from: ?*lua_State, nargs: c_int, nres: ?*c_int) c_int {
    var s = api.State.fromVm(L orelse return 2);
    const vm = s.vm;
    const co = vm.current_thread orelse return 2;
    // PUC ldo.c:lua_resume — the resumed coroutine inherits the caller's
    // C-call depth + 1, so nested resumes share the LUAI_MAXCCALLS budget.
    if (from) |from_ptr| {
        const from_s = api.State.fromVm(from_ptr);
        if (from_s.vm.current_thread) |from_th| {
            co.nCcalls = @as(u32, from_th.getCcalls()) + 1;
        } else {
            co.nCcalls = 1;
        }
    } else {
        co.nCcalls = 1;
    }
    const st = s.@"resume"(-1, @intCast(@max(nargs, 0)));
    if (nres) |p| {
        // Number of results = current top minus the coroutine itself.
        const top = s.gettop();
        p.* = @intCast(if (top > 0) top - 1 else 0);
    }
    return statusCode(st);
}

/// PUC `lua_yieldk` (ldo.c:1006-1034): yield from a coroutine.
/// nresults values on c_stack are returned to the resume caller.
/// k/ctx are saved in the current C-frame's u.c union for continuation
/// on resume (Task 11 will invoke k from finishCcall).
pub export fn lua_yieldk(L: ?*lua_State, nresults: c_int, ctx: isize, k: ?*const anyopaque) c_int {
    const vm = if (L) |v| v else return 2;

    // PUC: ci->u2.nyield = nresults — save number of yielded values so
    // lua_resume can report the result count at yield time. Then save k/ctx
    // in u.c for the continuation (invoked on resume by finishCcall).
    // PUC API-check: hooks (CIST_HOOKED) cannot use continuations — a hook
    // frame that yields must not save k (PUC asserts k == NULL for hooks).
    if (vm.current_thread) |th| {
        if (th.call_frames.len() > 0) {
            const fr = th.call_frames.getPtr(th.call_frames.len() - 1);
            if (fr.isC()) {
                fr.u.c.aux.nyield = nresults;
                if (k) |kf| {
                    if (!fr.isDebugHook()) {
                        fr.u.c.k = @ptrCast(@alignCast(kf));
                        fr.u.c.ctx = ctx;
                    }
                }
            }
        }
    }

    // The yield itself uses the existing mechanism (apiYield →
    // builtinCoroutineYield → error.Yield), which performs the full
    // yieldable check and raises the proper PUC error messages
    // ("attempt to yield from outside a coroutine" / "across a C-call
    // boundary"). If the yield fails, the error unwinds the C-frame,
    // discarding the saved k/ctx — matching PUC where the yieldable
    // check precedes the save.
    var s = api.State.fromVm(vm);
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

/// PUC `luaL_where` (lauxlib.c:luaL_where): push a "source:line: " prefix
/// for the frame at `lvl` onto the stack. Used by `luaL_argerror` and
/// `luaL_error` to annotate error messages with the caller's location.
///
/// In PUC, level 0 = the C function itself (which has a CallInfo), and
/// level 1 = the Lua caller. luazig does not push CallFrames for C
/// functions (see vm.zig TODO at callCFunction), so level 0 = the Lua
/// frame that called the C function. Internal callers (`luaL_argerror`,
/// `luaL_error`) therefore use `luaL_where(L, 0)` instead of PUC's `(L, 1)`.
pub export fn luaL_where(L: ?*lua_State, lvl: c_int) void {
    const vm = L orelse return;
    var ar: lua_Debug = .{};
    if (lua_getstack(L, lvl, &ar) != 0) {
        _ = lua_getinfo(L, "Sl", &ar);
        if (ar.currentline > 0) {
            const src: []const u8 = if (ar.source) |s| std.mem.span(s) else "?";
            var buf: [128]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "{s}:{d}: ", .{ src, ar.currentline }) catch {
                vm.c_stack.append(vm.alloc, .{ .String = vm.internStr("") catch return }) catch {};
                return;
            };
            const ls = vm.internStr(formatted) catch return;
            vm.c_stack.append(vm.alloc, .{ .String = ls }) catch {};
            return;
        }
    }
    // Fallback: empty string (PUC pushes "" when no info is available)
    vm.c_stack.append(vm.alloc, .{ .String = vm.internStr("") catch return }) catch {};
}

pub export fn luaL_typeerror(L: ?*lua_State, arg: c_int, tname: [*:0]const u8) c_int {
    var s = api.State.fromVm(L orelse return 0);
    const ty = if (s.typeOf(arg)) |t| typeCode(t) else @as(c_int, -1);
    _ = lua_pushfstring(L, "bad argument #%d (%s expected, got %s)", arg, tname, lua_typename(L, ty));
    lua_error(L);
}

pub export fn luaL_argerror(L: ?*lua_State, arg: c_int, extramsg: ?[*:0]const u8) c_int {
    // Level 0 (not 1 as in PUC): luazig doesn't push C-function CallFrames,
    // so level 0 = the Lua frame that called this C function.
    luaL_where(L, 0);
    if (extramsg) |msg| {
        _ = lua_pushfstring(L, "bad argument #%d (%s)", arg, msg);
    } else {
        _ = lua_pushfstring(L, "bad argument #%d", arg);
    }
    lua_concat(L, 2);
    lua_error(L);
}

pub export fn luaL_error(L: ?*lua_State, fmt: [*:0]const u8, ...) c_int {
    // Level 0 (not 1 as in PUC): luazig doesn't push C-function CallFrames,
    // so level 0 = the Lua frame that called this C function.
    luaL_where(L, 0);
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    _ = lua_pushvfstring(L, fmt, @ptrCast(&ap));
    lua_concat(L, 2);
    lua_error(L);
}

/// PUC `luaL_traceback` (lauxlib.c:luaL_traceback): build a stack traceback
/// string and push it onto the stack. `msg` (if non-null) is prepended.
/// `lvl` is the starting level (0 = the frame that called the C function).
///
/// Walks `lua_getstack`/`lua_getinfo` to enumerate visible frames, matching
/// PUC's format: "stack traceback:\n\tsource:line: in ...\n".
pub export fn luaL_traceback(L: ?*lua_State, L1: ?*lua_State, msg: ?[*:0]const u8, lvl: c_int) void {
    // L1 is the state to introspect; in luazig L and L1 are the same Vm
    // (lua_newthread returns the same state). Use L for both.
    _ = L1;
    const vm = L orelse return;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(vm.alloc);

    if (msg) |m| {
        buf.appendSlice(vm.alloc, std.mem.span(m)) catch return;
        buf.append(vm.alloc, '\n') catch return;
    }
    buf.appendSlice(vm.alloc, "stack traceback:\n") catch return;

    // Walk frames from level `lvl` upward, building the traceback.
    var ar: lua_Debug = .{};
    var level: c_int = lvl;
    while (lua_getstack(L, level, &ar) != 0) : (level += 1) {
        _ = lua_getinfo(L, "Sl", &ar);
        const src: []const u8 = if (ar.source) |s| std.mem.span(s) else "?";
        const line = ar.currentline;
        if (line > 0) {
            const entry = std.fmt.allocPrint(vm.alloc, "\t{s}:{d}: in ?\n", .{ src, line }) catch continue;
            defer vm.alloc.free(entry);
            buf.appendSlice(vm.alloc, entry) catch {};
        } else {
            buf.appendSlice(vm.alloc, "\t[C]: in ?\n") catch {};
        }
    }

    const ls = vm.internStr(buf.items) catch return;
    vm.c_stack.append(vm.alloc, .{ .String = ls }) catch {};
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
// Phase 8: Debug C API (PUC lapi.c / ldebug.c)
// ===========================================================================

/// Fill `short_src` (a `[LUA_IDSIZE]u8` = `[60]u8` buffer) with a
/// human-readable source name, NUL-terminated. Mirrors PUC's `luaO_chunkid`:
/// - `=source`: use `source[1..]` verbatim (up to 59 chars).
/// - `@file`:   use the basename of `file[1..]` (up to 59 chars; prefix
///              "..." if truncated).
/// - other:     wrap as `[string "..."]` (first line, up to 59 chars total).
fn fillShortSrc(buf: *[60]u8, source: []const u8) void {
    if (source.len == 0) {
        buf[0] = 0;
        return;
    }
    // PUC: source starting with '=' — use the remainder verbatim.
    if (source[0] == '=') {
        const raw = source[1..];
        const copy_len = @min(raw.len, 59);
        @memcpy(buf[0..copy_len], raw[0..copy_len]);
        buf[copy_len] = 0;
        return;
    }
    // PUC: source starting with '@' — use the basename (after last '/').
    if (source[0] == '@') {
        const raw = source[1..];
        // Find basename (after last path separator).
        const basename = if (std.mem.lastIndexOfScalar(u8, raw, '/')) |pos|
            raw[pos + 1 ..]
        else if (std.mem.lastIndexOfScalar(u8, raw, '\\')) |pos|
            raw[pos + 1 ..]
        else
            raw;
        if (basename.len <= 59) {
            @memcpy(buf[0..basename.len], basename);
            buf[basename.len] = 0;
        } else {
            // Truncate with "..." prefix (PUC luaO_chunkid style).
            const keep = 59 - 3; // 3 bytes for "..."
            @memcpy(buf[0..3], "...");
            @memcpy(buf[3..59], basename[basename.len - keep ..]);
            buf[59] = 0;
        }
        return;
    }
    // PUC: string source — wrap as [string "..."].
    // Find first line (up to first newline).
    const nl = std.mem.indexOfAny(u8, source, "\r\n") orelse source.len;
    const first_line = source[0..nl];
    const prefix = "[string \"";
    const suffix = "\"]";
    const max_body = 59 - prefix.len - suffix.len; // leave room for prefix+suffix+NUL
    if (first_line.len <= max_body) {
        const total = prefix.len + first_line.len + suffix.len;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..][0..first_line.len], first_line);
        @memcpy(buf[prefix.len + first_line.len ..][0..suffix.len], suffix);
        buf[total] = 0;
    } else {
        const keep = max_body - 3; // 3 bytes for "..."
        const total = prefix.len + keep + 3 + suffix.len;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..][0..keep], first_line[0..keep]);
        @memcpy(buf[prefix.len + keep ..][0..3], "...");
        @memcpy(buf[prefix.len + keep + 3 ..][0..suffix.len], suffix);
        buf[total] = 0;
    }
}

/// PUC `lua_getstack` (lapi.c:lua_getstack): get the CallInfo at `level`
/// and store an opaque handle in `ar->i_ci`. Level 0 = the current (topmost)
/// visible frame. Returns 1 on success, 0 if `level` is too deep.
///
/// Walks `Thread.call_frames` from top (newest) to bottom (oldest), skipping
/// frames where `hide_from_debug == true`. The frame index (1-based, to
/// distinguish from null) is stored in `ar.i_ci` as an opaque pointer.
pub export fn lua_getstack(L: ?*lua_State, level: c_int, ar: *lua_Debug) c_int {
    const vm = L orelse return 0;
    if (level < 0) return 0;
    // call_frames lives on Thread, not Vm. Access via current_thread/main_thread.
    const th = vm.current_thread orelse vm.main_thread orelse return 0;
    const total = th.call_frames.len();
    if (total == 0) return 0;

    // Walk from top (newest) to bottom (oldest), skipping hidden frames.
    var lvl: c_int = 0;
    var i: usize = total;
    while (i > 0) {
        i -= 1;
        const frame = th.call_frames.getConstPtr(i);
        if (frame.isHidden()) continue;
        if (lvl == level) {
            // Store 1-based index as opaque pointer (0 = null = invalid).
            ar.i_ci = @ptrFromInt(i + 1);
            return 1;
        }
        lvl += 1;
    }
    return 0;
}

/// PUC `lua_getinfo` (lapi.c:lua_getinfo): fill `lua_Debug` fields from the
/// frame identified by `ar->i_ci` (set by `lua_getstack`). The `what` string
/// controls which fields are filled: 'S' (source), 'l' (currentline),
/// 'u' (ups/params), 't' (tailcall), 'n' (name/namewhat).
///
/// Returns 1 on success, 0 on invalid frame handle.
pub export fn lua_getinfo(L: ?*lua_State, what: [*:0]const u8, ar: *lua_Debug) c_int {
    const vm = L orelse return 0;
    // Recover the frame index from ar.i_ci (1-based, stored by lua_getstack).
    const ci_raw = @intFromPtr(ar.i_ci orelse return 0);
    if (ci_raw == 0) return 0;
    const frame_idx = ci_raw - 1; // convert back to 0-based

    const th = vm.current_thread orelse vm.main_thread orelse return 0;
    if (frame_idx >= th.call_frames.len()) return 0;
    const frame = th.call_frames.getConstPtr(frame_idx);

    const flags = std.mem.span(what);

    for (flags) |flag| {
        switch (flag) {
            'S' => {
                if (frame.proto()) |p| {
                    // Lua function: fill source info from Proto.
                    const what_str: [*:0]const u8 = if (p.line_defined == 0) "main" else "Lua";
                    ar.what = what_str;
                    // Intern source_name to get a NUL-terminated LuaString.
                    // Proto.source_name is []const u8 (not NUL-terminated);
                    // LuaString storage IS NUL-terminated (createLuaString).
                    const src_ls = vm.internStr(p.source_name) catch return 0;
                    const src_bytes = src_ls.bytes();
                    ar.source = @ptrCast(@constCast(src_bytes.ptr));
                    ar.srclen = src_bytes.len;
                    ar.linedefined = @intCast(p.line_defined);
                    ar.lastlinedefined = @intCast(p.last_line_defined);
                    fillShortSrc(&ar.short_src, p.source_name);
                } else {
                    // C function: no source info.
                    ar.what = "C";
                    ar.source = "=[C]";
                    ar.srclen = 4;
                    ar.linedefined = -1;
                    ar.lastlinedefined = -1;
                    fillShortSrc(&ar.short_src, "=[C]");
                }
            },
            'l' => {
                ar.currentline = @intCast(vm.frameCurrentLine(frame));
            },
            'u' => {
                if (frame.proto()) |p| {
                    ar.nups = @intCast(p.upvalues.len);
                    ar.nparams = p.numparams;
                    ar.isvararg = if (p.is_vararg) 1 else 0;
                } else {
                    ar.nups = @intCast(vm.frameUpvalues(frame, null).len);
                    ar.nparams = 0;
                    ar.isvararg = 0;
                }
            },
            't' => {
                ar.istailcall = if (frame.isTailCall()) 1 else 0;
            },
            'n' => {
                // P15.51n: Debug name stored in parent frame's continuation.
                const parent_frame: ?*const vm_mod.CallFrame = if (frame_idx > 0)
                    th.call_frames.getConstPtr(frame_idx - 1)
                else
                    null;
                if (vm.getDebugName(parent_frame)) |dn| {
                    if (dn.name) |name| {
                        const ls = vm.internStr(name) catch return 0;
                        ar.name = @ptrCast(@constCast(ls.bytes().ptr));
                    } else {
                        ar.name = null;
                    }
                    if (dn.namewhat) |nw| {
                        const ls = vm.internStr(nw) catch return 0;
                        ar.namewhat = @ptrCast(@constCast(ls.bytes().ptr));
                    } else {
                        ar.namewhat = null;
                    }
                } else {
                    ar.name = null;
                    ar.namewhat = null;
                }
            },
            else => {}, // ignore unknown flags (PUC default)
        }
    }
    return 1;
}

/// PUC `lua_getlocal` (lapi.c:lua_getlocal): get the name of the `n`-th local
/// variable in the frame identified by `ar`. Pushes the local's value onto
/// the C stack and returns its name. Returns null if `n` is out of range.
///
/// Mirrors PUC's `luaF_getlocalname` (lfunc.c): iterate forward through
/// `Proto.locvars`, counting locals whose `[startpc, endpc)` range contains
/// the frame's current `pc`. The n-th active local's value lives at
/// `bc_stack[frame.base + locvar.reg]` — pushed onto `c_stack` for C access.
pub export fn lua_getlocal(L: ?*lua_State, ar: *lua_Debug, n: c_int) ?[*:0]const u8 {
    const vm = L orelse return null;
    // Recover the frame index from ar.i_ci (1-based, stored by lua_getstack).
    const ci_raw = @intFromPtr(ar.i_ci orelse return null);
    if (ci_raw == 0) return null;
    const frame_idx = ci_raw - 1;

    const th = vm.current_thread orelse vm.main_thread orelse return null;
    if (frame_idx >= th.call_frames.len()) return null;
    const frame = th.call_frames.getConstPtr(frame_idx);
    const proto = frame.proto() orelse return null; // C function — no locals

    // PUC luaF_getlocalname: iterate forward, count active locals at current pc.
    const pc: u32 = @intCast(@min(frame.u.lua.pc, std.math.maxInt(u32)));
    var count: c_int = 0;
    for (proto.locvars) |lv| {
        if (pc >= lv.startpc and pc < lv.endpc) {
            count += 1;
            if (count == n) {
                // Push the local's value from the bytecode register file.
                const reg_idx = frame.base + lv.reg;
                if (reg_idx >= vm.bc_stack.len) return null;
                const val = vm.bc_stack[reg_idx];
                vm.c_stack.append(vm.alloc, val) catch return null;
                return @ptrCast(@constCast(lv.name.ptr));
            }
        }
    }
    return null; // no n-th active local
}

/// PUC `lua_setlocal` (lapi.c:lua_setlocal): set the `n`-th local variable
/// in the frame identified by `ar` to the value on top of the C stack.
/// Returns the local's name, or null if `n` is out of range.
///
/// Pops the value from `c_stack` and writes it to the bytecode register at
/// `bc_stack[frame.base + locvar.reg]`, mirroring PUC's `setobjs2s(L, pos, --L->top)`.
pub export fn lua_setlocal(L: ?*lua_State, ar: *lua_Debug, n: c_int) ?[*:0]const u8 {
    const vm = L orelse return null;
    if (vm.c_stack.items.len < 1) return null; // need a value on the stack

    // Recover the frame index from ar.i_ci (1-based, stored by lua_getstack).
    const ci_raw = @intFromPtr(ar.i_ci orelse return null);
    if (ci_raw == 0) return null;
    const frame_idx = ci_raw - 1;

    const th = vm.current_thread orelse vm.main_thread orelse return null;
    if (frame_idx >= th.call_frames.len()) return null;
    const frame = th.call_frames.getConstPtr(frame_idx);
    const proto = frame.proto() orelse return null; // C function — no locals

    // PUC luaF_getlocalname: iterate forward, count active locals at current pc.
    const pc: u32 = @intCast(@min(frame.u.lua.pc, std.math.maxInt(u32)));
    var count: c_int = 0;
    for (proto.locvars) |lv| {
        if (pc >= lv.startpc and pc < lv.endpc) {
            count += 1;
            if (count == n) {
                // Pop the value from c_stack, write to the bytecode register.
                const val = vm.c_stack.items[vm.c_stack.items.len - 1];
                vm.c_stack.items.len -= 1;
                const reg_idx = frame.base + lv.reg;
                if (reg_idx >= vm.bc_stack.len) return null;
                vm.bc_stack[reg_idx] = val;
                return @ptrCast(@constCast(lv.name.ptr));
            }
        }
    }
    return null; // no n-th active local
}

pub export fn lua_getupvalue(L: ?*lua_State, funcindex: c_int, n: c_int) ?[*:0]const u8 {
    var s = api.State.fromVm(L orelse return null);
    const abs = normalizeIndex(funcindex, s.vm.c_stack.items.len) orelse return null;
    // C closures: direct upvalue access
    if (s.vm.c_stack.items[abs] == .Closure) {
        const cl = s.vm.c_stack.items[abs].Closure;
        if (cl.c_func != null) {
            const idx: usize = @intCast(@max(n - 1, 0));
            if (idx >= cl.upvalues.len) return null;
            s.vm.c_stack.append(s.vm.alloc, cl.upvalues[idx].value) catch return null;
            return null; // C closures have unnamed upvalues
        }
    }
    // Lua closures: use debug module
    const name = s.getupvalue(funcindex, @intCast(@max(n, 0))) catch return null;
    if (name) |nm| return @ptrCast(@constCast(nm.ptr));
    return null;
}

pub export fn lua_setupvalue(L: ?*lua_State, funcindex: c_int, n: c_int) ?[*:0]const u8 {
    var s = api.State.fromVm(L orelse return null);
    const abs = normalizeIndex(funcindex, s.vm.c_stack.items.len) orelse return null;
    // C closures: direct upvalue write
    if (s.vm.c_stack.items[abs] == .Closure) {
        const cl = s.vm.c_stack.items[abs].Closure;
        if (cl.c_func != null) {
            const idx: usize = @intCast(@max(n - 1, 0));
            if (idx >= cl.upvalues.len) return null;
            if (s.vm.c_stack.items.len < 1) return null;
            cl.upvalues[idx].value = s.vm.c_stack.items[s.vm.c_stack.items.len - 1];
            s.vm.c_stack.items.len -= 1;
            return null;
        }
    }
    // Lua closures: use debug module
    const name = s.setupvalue(funcindex, @intCast(@max(n, 0))) catch return null;
    if (name) |nm| return @ptrCast(@constCast(nm.ptr));
    return null;
}

pub export fn lua_upvalueid(L: ?*lua_State, fidx: c_int, n: c_int) ?*anyopaque {
    const s = api.State.fromVm(L orelse return null);
    const abs = normalizeIndex(fidx, s.vm.c_stack.items.len) orelse return null;
    if (s.vm.c_stack.items[abs] != .Closure) return null;
    const cl = s.vm.c_stack.items[abs].Closure;
    const idx: usize = @intCast(@max(n - 1, 0));
    if (idx >= cl.upvalues.len) return null;
    return @ptrCast(cl.upvalues[idx]);
}

pub export fn lua_upvaluejoin(L: ?*lua_State, fidx1: c_int, n1: c_int, fidx2: c_int, n2: c_int) void {
    const s = api.State.fromVm(L orelse return);
    const abs1 = normalizeIndex(fidx1, s.vm.c_stack.items.len) orelse return;
    const abs2 = normalizeIndex(fidx2, s.vm.c_stack.items.len) orelse return;
    if (s.vm.c_stack.items[abs1] != .Closure or s.vm.c_stack.items[abs2] != .Closure) return;
    const cl1 = s.vm.c_stack.items[abs1].Closure;
    const cl2 = s.vm.c_stack.items[abs2].Closure;
    const idx1: usize = @intCast(@max(n1 - 1, 0));
    const idx2: usize = @intCast(@max(n2 - 1, 0));
    if (idx1 >= cl1.upvalues.len or idx2 >= cl2.upvalues.len) return;
    cl1.upvalues[idx1].value = cl2.upvalues[idx2].value;
}

pub export fn lua_sethook(L: ?*lua_State, func: ?*const fn (?*lua_State, *anyopaque) callconv(.c) void, mask: c_int, count: c_int) void {
    const vm = L orelse return;
    vm.c_hook = func;
    vm.c_hook_mask = mask;
    vm.c_hook_count = count;
}

pub export fn lua_gethook(L: ?*lua_State) ?*const fn (?*lua_State, *anyopaque) callconv(.c) void {
    const vm = L orelse return null;
    return vm.c_hook;
}

pub export fn lua_gethookmask(L: ?*lua_State) c_int {
    const vm = L orelse return 0;
    return vm.c_hook_mask;
}

pub export fn lua_gethookcount(L: ?*lua_State) c_int {
    const vm = L orelse return 0;
    return vm.c_hook_count;
}

// ===========================================================================
// Standard library open functions (PUC lualib.h / linit.c)
// ===========================================================================
//
// In luazig, all standard libraries are already registered in the VM's
// global environment (`_G`) when `Vm.init` runs. The `luaopen_*` functions
// below expose these pre-built library tables to C code that calls them
// individually (e.g., `luaopen_math(L)` pushes the `math` table).
//
// `luaL_openselectedlibs` mirrors PUC linit.c: it iterates the standard
// libraries in bitmask order, calling `luaL_requiref` for each library
// requested by the `load` mask, and registering openf in `package.preload`
// for each library requested by the `preload` mask.

// LUA_*LIBK bitmask constants (matching lualib.h / PUC Lua 5.5 exactly).
const LUA_GLIBK: c_int = 1;
const LUA_LOADLIBK: c_int = LUA_GLIBK << 1;
const LUA_COLIBK: c_int = LUA_LOADLIBK << 1;
const LUA_DBLIBK: c_int = LUA_COLIBK << 1;
const LUA_IOLIBK: c_int = LUA_DBLIBK << 1;
const LUA_MATHLIBK: c_int = LUA_IOLIBK << 1;
const LUA_OSLIBK: c_int = LUA_MATHLIBK << 1;
const LUA_STRLIBK: c_int = LUA_OSLIBK << 1;
const LUA_TABLIBK: c_int = LUA_STRLIBK << 1;
const LUA_UTF8LIBK: c_int = LUA_TABLIBK << 1;

/// PUC `luaopen_base` (lbaselib.c:547): opens the base library.
/// PUC pushes `lua_pushglobaltable(L)`, registers base functions into it,
/// sets `_G` and `_VERSION`, and returns 1. In luazig, base functions are
/// already in `_G` when `Vm.init` runs, so we push the global table directly.
pub export fn luaopen_base(L: ?*lua_State) c_int {
    const vm = L orelse return 0;
    vm.c_stack.append(vm.alloc, .{ .Table = vm.global_env }) catch return 0;
    return 1;
}

/// PUC `luaopen_package` (loadlib.c): opens the package library.
/// The `package` table is already in `_G.package`; push it.
pub export fn luaopen_package(L: ?*lua_State) c_int {
    var s = api.State.fromVm(L orelse return 0);
    _ = s.getglobal("package") catch return 0;
    return 1;
}

/// PUC `luaopen_coroutine` (lcorolib.c): opens the coroutine library.
pub export fn luaopen_coroutine(L: ?*lua_State) c_int {
    var s = api.State.fromVm(L orelse return 0);
    _ = s.getglobal("coroutine") catch return 0;
    return 1;
}

/// PUC `luaopen_debug` (ldblib.c): opens the debug library.
pub export fn luaopen_debug(L: ?*lua_State) c_int {
    var s = api.State.fromVm(L orelse return 0);
    _ = s.getglobal("debug") catch return 0;
    return 1;
}

/// PUC `luaopen_io` (liolib.c): opens the I/O library.
pub export fn luaopen_io(L: ?*lua_State) c_int {
    var s = api.State.fromVm(L orelse return 0);
    _ = s.getglobal("io") catch return 0;
    return 1;
}

/// PUC `luaopen_math` (lmathlib.c): opens the math library.
pub export fn luaopen_math(L: ?*lua_State) c_int {
    var s = api.State.fromVm(L orelse return 0);
    _ = s.getglobal("math") catch return 0;
    return 1;
}

/// PUC `luaopen_os` (loslib.c): opens the os library.
pub export fn luaopen_os(L: ?*lua_State) c_int {
    var s = api.State.fromVm(L orelse return 0);
    _ = s.getglobal("os") catch return 0;
    return 1;
}

/// PUC `luaopen_string` (lstrlib.c): opens the string library.
pub export fn luaopen_string(L: ?*lua_State) c_int {
    var s = api.State.fromVm(L orelse return 0);
    _ = s.getglobal("string") catch return 0;
    return 1;
}

/// PUC `luaopen_table` (ltablib.c): opens the table library.
pub export fn luaopen_table(L: ?*lua_State) c_int {
    var s = api.State.fromVm(L orelse return 0);
    _ = s.getglobal("table") catch return 0;
    return 1;
}

/// PUC `luaopen_utf8` (lutf8lib.c): opens the utf8 library.
pub export fn luaopen_utf8(L: ?*lua_State) c_int {
    var s = api.State.fromVm(L orelse return 0);
    _ = s.getglobal("utf8") catch return 0;
    return 1;
}

/// PUC `luaL_openselectedlibs` (linit.c:46): opens selected standard libraries.
/// `load` is a bitmask of `LUA_*LIBK` constants for libraries to open via
/// `luaL_requiref`. `preload` is a bitmask for libraries to register in
/// `package.preload` (so `require` will call the openf on first use).
/// `luaL_openlibs(L)` is `luaL_openselectedlibs(L, ~0, 0)`.
pub export fn luaL_openselectedlibs(L: ?*lua_State, load: c_int, preload: c_int) void {
    var s = api.State.fromVm(L orelse return);

    // PUC: luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE)
    // Get the PRELOAD table from the registry. The VM stores it under
    // "_PRELOAD" in the debug registry (see Vm.init package setup).
    s.getregistry() catch return;
    _ = s.getfield(-1, "_PRELOAD") catch {
        s.vm.c_stack.items.len -= 1; // pop registry
        return;
    };
    // Stack: [registry, preload_table]

    // Standard libraries in bitmask order (matching LUA_*LIBK constants).
    // PUC linit.c uses a static luaL_Reg array; we inline the same ordering.
    const Lib = struct {
        name: [*:0]const u8,
        openf: *const fn (?*lua_State) callconv(.c) c_int,
        mask: c_int,
    };
    const stdlibs = [_]Lib{
        .{ .name = "_G", .openf = luaopen_base, .mask = LUA_GLIBK },
        .{ .name = "package", .openf = luaopen_package, .mask = LUA_LOADLIBK },
        .{ .name = "coroutine", .openf = luaopen_coroutine, .mask = LUA_COLIBK },
        .{ .name = "debug", .openf = luaopen_debug, .mask = LUA_DBLIBK },
        .{ .name = "io", .openf = luaopen_io, .mask = LUA_IOLIBK },
        .{ .name = "math", .openf = luaopen_math, .mask = LUA_MATHLIBK },
        .{ .name = "os", .openf = luaopen_os, .mask = LUA_OSLIBK },
        .{ .name = "string", .openf = luaopen_string, .mask = LUA_STRLIBK },
        .{ .name = "table", .openf = luaopen_table, .mask = LUA_TABLIBK },
        .{ .name = "utf8", .openf = luaopen_utf8, .mask = LUA_UTF8LIBK },
    };

    for (stdlibs) |lib| {
        if (load & lib.mask != 0) {
            // PUC: luaL_requiref(L, lib->name, lib->func, 1); lua_pop(L, 1);
            luaL_requiref(L, lib.name, lib.openf, 1);
            lua_pop(L, 1);
        } else if (preload & lib.mask != 0) {
            // PUC: lua_pushcfunction(L, lib->func);
            //      lua_setfield(L, -2, lib->name);
            s.pushcfunction(lib.openf) catch {};
            s.setfield(-2, std.mem.span(lib.name)) catch {};
        }
    }

    // PUC: lua_pop(L, 1) — remove PRELOAD table.
    // We also pop the registry table that was pushed above.
    s.vm.c_stack.items.len -= 2;
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
