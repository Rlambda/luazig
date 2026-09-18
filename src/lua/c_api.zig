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

pub const lua_State = vm_mod.lua_State;

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
    // (b) status contract: lua_newstate returns NULL on failure (PUC
    // lstate.c) — no state exists yet, so there is nothing to throw on.
    const vm = alloc.create(Vm) catch return null;
    vm.* = Vm.init(alloc, false);
    // Install the default bytecode compiler so that text loading via
    // loadChunk → compileTextChunk works on C API states (matching the
    // CLI which sets this via setDynamicBytecodeCompiler).
    vm.dynamic_bytecode_compiler = vm_mod.defaultBytecodeCompiler;
    return vm.setupMainHandle() catch {
        vm.deinit();
        alloc.destroy(vm);
        return null;
    };
}

pub export fn lua_close(L: ?*lua_State) void {
    const h = L orelse return;
    const vm = h.vm;
    vm.deinit();
    const alloc = vm.alloc;
    // Free the main handle (coroutine handles are freed by GC via
    // gcFreeObject(.thread) → Thread.api_handle).
    vm.freeStateHandle(h);
    alloc.destroy(vm);
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
    // PUC lstate.c:354: g->seed = seed. The seed parameter (generated by
    // luaL_makeseed in luaL_newstate) becomes the per-VM hash seed for
    // string hashing (luaS_hash). We pass it through as the hash_seed_override
    // so Vm.init uses it directly instead of generating its own entropy.
    const alloc = std.heap.c_allocator;
    // (b) status contract: lua_newstate returns NULL on failure (PUC
    // lstate.c) — no state exists yet, so there is nothing to throw on.
    const vm = alloc.create(Vm) catch return null;
    vm.* = Vm.initWithSeed(alloc, false, @as(u64, seed));
    vm.c_alloc_fn = f;
    vm.c_alloc_ud = ud;
    // Install the default bytecode compiler (same as luaL_newstate).
    vm.dynamic_bytecode_compiler = vm_mod.defaultBytecodeCompiler;
    return vm.setupMainHandle() catch {
        vm.deinit();
        alloc.destroy(vm);
        return null;
    };
}

/// PUC `lua_newthread` (lstate.c:lua_newthread): create a new coroutine
/// ("thread") that shares the global state of `L`. The new thread has its own
/// `lua_State` handle but shares globals, registry, and metatables.
///
/// The handle is allocated on the heap and its lifetime is tied to the
/// Thread's GC lifetime: `gcFreeObject(.thread)` frees the handle via
/// `Thread.api_handle`. Each handle has its own `c_stack`, and
/// `Vm.cur_c_stack` points to the active handle's stack.
pub export fn lua_newthread(L: ?*lua_State) ?*lua_State {
    // P16.50-review-2 BLOCKER 2: PUC lua_newthread (lua.h:165,
    // lstate.c:273-291) has NO nullable failure result — an allocation
    // failure throws LUA_ERRMEM through the protected boundary
    // (luaC_newobjdt / stack growth → luaM_error → luaD_throw). The
    // earlier null-sentinel silently converted OOM into apparent API
    // failure-by-sentinel. The inner transaction still completes ALL
    // cleanup first; its OOM then travels through the canonical
    // protected transport (cThrow, LUA_ERRMEM) — never a NULL return.
    const parent = L orelse return null;
    const vm = parent.vm;
    const saved_c_api_thread = vm.c_api_thread;
    const result = luaNewThreadTx(parent, vm) catch |err| {
        vm.c_api_thread = saved_c_api_thread;
        cThrowOn(vm, parent, err);
    };
    return result;
}

/// Inner transaction for lua_newthread (P16.50-review): every failure
/// returns an ERROR so the errdefer actually fires.
pub fn luaNewThreadTx(parent: *vm_mod.lua_State, vmp: *Vm) error{OutOfMemory}!*vm_mod.lua_State {
    // Prepare-first: after this, registration cannot fail.
    try vmp.gcPrepareRegister(1);
    const th = try vmp.alloc.create(vm_mod.Thread);
    errdefer vmp.alloc.destroy(th);
    th.* = .{ .status = .suspended, .callee = .Nil };
    vmp.gcRegisterCommit(.{ .thread = th });
    vmp.gcNoteAlloc(@sizeOf(vm_mod.Thread));
    var committed = false;
    errdefer if (committed) {
        vmp.gcUnregisterObjectRollback(.{ .thread = th });
        vmp.gcNoteFree(@sizeOf(vm_mod.Thread));
    };
    committed = true;
    vmp.c_api_thread = th;
    // Create the coroutine handle with its own c_stack (and its
    // LUA_EXTRASPACE extra space in front, inheriting the main thread's
    // extra-space contents — PUC lstate.c:291-293).
    const handle = try vmp.allocStateHandle(false);
    handle.* = .{ .vm = vmp, .thread = th, .is_main = false };
    th.api_handle = handle;
    // Push the thread value on the parent's c_stack (PUC pushes it on L->top).
    parent.c_stack.append(vmp.alloc, .{ .Thread = th }) catch {
        vmp.freeStateHandle(handle);
        th.api_handle = null;
        return error.OutOfMemory;
    };
    return handle;
}

/// PUC `lua_closethread` (lstate.c:324-333): reset a thread to a clean
/// state. `from` is the thread that initiated the close (may be NULL).
///
/// PUC semantics:
///   1. `L->nCcalls = (from) ? getCcalls(from) : 0` — inherit C-call
///      depth from the caller (or zero if no caller).
///   2. `status = luaE_resetthread(L, L->status)` — drop all CallInfos,
///      close all upvalues/TBCs (run `__close`), set status to OK/dead.
///      A `__close` error replaces the status (last error wins).
///   3. `if (L == from) luaD_throwbaselevel(L, status)` — closing itself
///      never returns. DEFERRED: see TODO below.
///   4. Return `APIstatus(status)`: LUA_OK (0) on success; LUA_ERRRUN (2)
///      if a `__close` errored. The error object is on top of the
///      thread's stack (PUC `luaD_seterrorobj`).
///
/// Delegates to `builtinCoroutineClose` via `apiCloseThread`, which
/// implements the full close semantics (forced-close unwind for
/// suspended threads with frames, `__close` metamethod execution,
/// close_has_err latch, idempotent dead-thread handling).
pub export fn lua_closethread(L: ?*lua_State, from: ?*lua_State) c_int {
    const h = L orelse return 1; // LUA_ERRRUN if null
    const vm = h.vm;

    // PUC lua_closethread operates on L (the thread itself). Resolve the
    // thread from the handle. For the main state, PUC allows closing it
    // (resets to clean state), but luazig's main thread is always in a
    // valid state, so return LUA_OK — the main state is torn down by
    // lua_close, and the main thread can never be suspended (it cannot
    // yield), so there is nothing to reset.
    if (h.is_main) return 0; // LUA_OK — main thread
    const th = h.thread orelse return 0;

    // PUC lstate.c:327: L->nCcalls = (from) ? getCcalls(from) : 0
    if (from) |from_ptr| {
        const from_s = api.State.fromHandle(from_ptr);
        if (from_s.vm.current_thread) |from_th| {
            th.nCcalls = @as(u32, from_th.getCcalls());
        } else {
            th.nCcalls = 0;
        }
    } else {
        th.nCcalls = 0;
    }

    // PUC lstate.c:328: status = luaE_resetthread(L, L->status)
    // PUC lstate.c:328: status = luaE_resetthread(L, L->status) — an OOM
    // during the protected close yields LUA_ERRMEM, and lua_closethread
    // returns APIstatus(status) VERBATIM (no kind conversion; PUC's
    // resetthread also installs the error object via luaD_seterrorobj at
    // stack.p+1 — mirrored below with the fixed MEMERRMSG object,
    // best-effort: the c_stack append can itself OOM).
    const result = vm.apiCloseThread(th) catch |err| switch (err) {
        error.OutOfMemory => {
            vm.setOutOfMemoryError();
            h.c_stack.clearRetainingCapacity();
            h.c_stack.append(vm.alloc, vm.errThread().err_obj) catch {};
            return 4; // LUA_ERRMEM (PUC APIstatus, P16.50-review-5 B2)
        },
        error.RuntimeError => {
            // PUC lua_closethread (lstate.c:329-330): if L == from (closing
            // itself), luaD_throwbaselevel(L, status) never returns — it
            // longjmps to the base errorJmp boundary.
            //
            // This occurs when closing the currently-running thread from
            // within itself (lua_closethread(co, co) called from a C
            // function inside the coroutine). builtinCoroutineClose called
            // beginForcedClose and returned error.RuntimeError as a signal.
            // The actual close (forced close unwind) runs when the error
            // propagates to builtinCoroutineResume's error handler.
            //
            // Longjmp to the c_error_jmp boundary (set up by
            // callCFunctionWithBoundary) to abort the C function's
            // execution, matching PUC's luaD_throwbaselevel (which never
            // returns). The error propagates through finishCcall to
            // builtinCoroutineResume, which catches it and runs the
            // forced close unwind (runs __close for TBC variables).
            //
            // PUC throws with the close status (LUA_OK or error). In
            // luazig, the close hasn't run yet at this point — it runs
            // in builtinCoroutineResume. So we longjmp with value 1
            // (error signal) for both OK and error cases. The forced
            // close machinery determines the final status.
            //
            // Limitation: PUC's luaD_throwbaselevel unrolls past ALL
            // pcall boundaries to the base. luazig's c_error_jmp is a
            // single boundary (not chained), so this longjmp targets the
            // nearest c_error_jmp. If a pcall is active inside the
            // coroutine, the error may be caught by the pcall instead of
            // reaching builtinCoroutineResume. The
            // shouldRethrowForcedCloseFromBytecode check in
            // runBytecodeInternal handles the Lua-level path (bypassing
            // pcall for forced close); the C API path has the same
            // limitation as the existing error propagation.
            if (vm.c_error_jmp) |jb| {
                // Set a nil error object — the forced close machinery
                // will set the real error object if __close errors.
                // P16.36 Cut 1b: the raise belongs to the closed thread
                // (beginForcedClose raised on it; PUC throws on L).
                th.err_obj = .Nil;
                th.err_has_obj = true;
                _longjmp(jb, 1);
            }
            // No c_error_jmp boundary (e.g., called from a non-C context
            // or from lua_resetthread which uses from==NULL). Return
            // error — can't throw.
            return 2;
        },
        error.Yield => return 2,
    };

    if (result.status == 0) {
        // PUC luaE_resetthread: L->top = L->stack + 1 (only the function
        // slot). lua_gettop(co) == 0 after close. Clear the handle's c_stack.
        h.c_stack.clearRetainingCapacity();
        return 0; // LUA_OK
    }

    // Error: push the error object on c_stack (PUC luaD_seterrorobj).
    h.c_stack.clearRetainingCapacity();
    // (b) status-returning API: lua_closethread returns the close status;
    // PUC's seterrorobj moves the object WITHIN one stack (infallible), our
    // c_stack append can OOM — the status (2) is still returned, only the
    // object push is lost (P16.50-review-5 B2 inventory; architectural fix
    // = reserved c_stack slots, same family as the LUA_MINSTACK reserve).
    h.c_stack.append(vm.alloc, result.err) catch {};
    return 2; // LUA_ERRRUN
}

/// PUC `lua_atpanic` (lapi.c:lua_atpanic): install a panic function called when
/// an error propagates past the last protected call. Returns the previous panic
/// function. The panic function is stored on the Vm (`c_panicf`).
pub export fn lua_atpanic(
    L: ?*lua_State,
    panicf: ?*const fn (?*lua_State) callconv(.c) c_int,
) ?*const fn (?*lua_State) callconv(.c) c_int {
    const h = L orelse return null;
    const vm = h.vm;
    const old = vm.c_panicf;
    vm.c_panicf = panicf;
    return old;
}

/// PUC `lua_getextraspace` (lua.h:391): return a pointer to the per-state
/// "extra space" — a small raw area IN FRONT of the `lua_State` for very
/// fast access by C extensions (`((char *)L - LUA_EXTRASPACE)`). Every
/// luazig handle is allocated as an `Lx` (PUC's "thread state + extra
/// space" unit, lstate.h LX) with the extra space in front, so this is the
/// same `&lx.extra` computation PUC's macro performs — same ABI. PUC
/// leaves the main thread's extra space uninitialized and copies it into
/// every new thread (lstate.c:291-293); luazig zeroes the main extra space
/// (a safe superset) and keeps the inherit-from-main rule.
pub export fn lua_getextraspace(L: ?*lua_State) ?*anyopaque {
    const h = L orelse return null;
    const lx: *vm_mod.Lx = @fieldParentPtr("l", h);
    return @ptrCast(&lx.extra);
}

/// PUC `lua_xmove` (lapi.c:lua_xmove): move `n` values from the top of `from`'s
/// stack to the top of `to`'s stack. Both states must share the same global
/// state (i.e., `to` was created by `lua_newthread(from)`).
///
/// Operates on the per-handle C-API stacks (`c_stack`). Negative `n` is
/// clamped to zero. Self-move (from == to) is a no-op.
pub export fn lua_xmove(from: ?*lua_State, to: ?*lua_State, n: c_int) void {
    const src_h = from orelse return;
    const dst_h = to orelse return;
    // PUC: both states must share the same global state.
    if (src_h.vm != dst_h.vm) return;
    const vm = src_h.vm;
    const count: usize = @intCast(@max(n, 0));
    if (count == 0) return;
    // Self-move: PUC lua_xmove handles this by copying in-place, which is
    // a no-op for value semantics. Skip to avoid duplicating items.
    if (src_h == dst_h) return;
    if (count > src_h.c_stack.items.len) return;
    const start = src_h.c_stack.items.len - count;
    // Copy top `count` items from src to dst, then truncate src.
    // PUC lua_xmove → luaD_growstack on dst: OOM is LUA_ERRMEM thrown on
    // the DESTINATION state (P16.50-review-5 B2 — the old `catch return`
    // silently dropped the move).
    dst_h.c_stack.appendSlice(vm.alloc, src_h.c_stack.items[start..]) catch |e|
        cThrowOn(vm, dst_h, e);
    src_h.c_stack.items.len = start;
}

// `_longjmp` from libc. Using `_longjmp` (not `longjmp`) matches PUC's
// `__sigsetjmp(env, 0)` no-savemask choice.
extern fn _longjmp(jb: *anyopaque, val: c_int) noreturn;

/// PUC `lua_error` (noreturn): captures the error object from c_stack top into
/// `c_error_value`, then `_longjmp` to the nearest C-function boundary.
pub export fn lua_error(L: ?*lua_State) noreturn {
    const h = L orelse @panic("lua_error: null state");
    const vm = h.vm;
    if (h.c_stack.items.len > 0) {
        vm.c_error_value = h.c_stack.items[h.c_stack.items.len - 1];
    } else {
        @panic("lua_error: no error object on stack");
    }
    // PUC lua_error → luaG_errormsg (ldebug.c:840): the message handler
    // (L->errfunc, set by xpcall/lua_pcallk) runs BEFORE the throw, with
    // the call stack still intact — its return value replaces the thrown
    // object. Fold the C-thrown object into err_obj (the same fold
    // callCFunction performs) and run the handler; then longjmp. For a
    // yieldable lua_pcallk, the transformed object then flows through
    // precover → finishpcallk → seterrorobj → k, exactly like PUC.
    // P16.36 Cut 1b: PUC lua_error throws on L — the error state lands
    // on L's thread (the handle's thread; the main handle maps to the
    // main thread), not on the Vm.
    const eth = h.thread orelse vm.main_thread.?;
    if (vm.c_error_value) |ev| {
        vm.c_error_value = null;
        eth.err_obj = ev;
        eth.err_has_obj = true;
        vm.err = if (ev == .String) ev.String.bytes() else null;
        eth.err_source = null;
        eth.err_line = -1;
    }
    // Fresh error: reset LUA_ERRERR signal before invokeErrfunc.
    eth.err_is_errerr = false;
    // (d) internal cleanup, unobservable: the thrown object is ALREADY
    // installed on eth (the fold above); invokeErrfunc's error return can
    // only be an OOM from its gcTempRoots bookkeeping — PUC's equivalent
    // root-push is a stack-slot store (infallible). A failure here skips
    // only the message handler and the SAME object still longjmps below,
    // which is exactly what PUC throws when its (infallible) setup exists.
    vm.invokeErrfunc() catch {};
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
    const h = L orelse return;
    const vm = h.vm;
    // PUC lapi.c:1041-1042: api_check(k == NULL || !isLua(L->ci),
    // "cannot use continuations inside hooks") — unconditional in PUC.
    // Placed BEFORE the current_thread fallback so a C hook on the MAIN
    // state (current_thread == null there; the hook flag lives on
    // main_thread.debug_hook) is checked too. Enforcement: deterministic
    // runtime error converted to the C boundary via _longjmp (PUC aborts
    // via lua_assert only in apicheck builds).
    if (vm.current_thread orelse vm.main_thread) |th_check| {
        vm.apiCheckHookContinuationInvariant(th_check, k != null, false, 0) catch {
            if (vm.c_error_jmp) |jb| {
                vm.c_error_value = vm.errThread().err_obj;
                _longjmp(jb, 1);
            }
            @panic("lua_call hook api_check violation without an active C-function boundary");
        };
    }

    const th = vm.current_thread orelse {
        lua_callkImpl(L, nargs, nresults);
        return;
    };

    // Read callee/args from c_stack (PUC: func = L->top - (nargs+1)).
    const nargs_usize: usize = @intCast(@max(nargs, 0));
    if (h.c_stack.items.len < nargs_usize + 1) {
        if (vm.c_error_jmp) |jb| {
            vm.c_error_value = .Nil;
            _longjmp(jb, 1);
        }
        @panic("lua_call without an active C-function boundary");
    }
    const fn_idx = h.c_stack.items.len - nargs_usize - 1;
    const callee = h.c_stack.items[fn_idx];
    const call_args = h.c_stack.items[fn_idx + 1 ..];

    // Delegate k/ctx saving + apiCall to the shared helper (PUC lapi.c:1047-1053).
    const kfn: ?*const fn (?*vm_mod.lua_State, c_int, isize) callconv(.c) c_int = if (k) |kf|
        @ptrCast(@alignCast(kf))
    else
        null;

    const ret = vm.luaCallKShared(th, callee, call_args, kfn, ctx) catch |err| switch (err) {
        error.Yield => {
            if (vm.c_error_jmp) |jb| {
                _longjmp(jb, 2);
            }
            @panic("lua_call yield without an active C-function boundary");
        },
        error.RuntimeError => {
            if (vm.c_error_jmp) |jb| {
                vm.c_error_value = vm.errThread().err_obj;
                _longjmp(jb, 1);
            }
            @panic("lua_call without an active C-function boundary");
        },
        error.OutOfMemory => {
            if (vm.c_error_jmp) |jb| {
                vm.c_error_value = .Nil;
                _longjmp(jb, 1);
            }
            @panic("lua_call OOM without an active C-function boundary");
        },
    };
    defer vm.alloc.free(ret);
    h.c_stack.items.len = fn_idx;
    const want: usize = if (nresults < 0) ret.len else @min(ret.len, @as(usize, @intCast(nresults)));
    h.c_stack.appendSlice(vm.alloc, ret[0..want]) catch {
        if (vm.c_error_jmp) |jb| {
            vm.c_error_value = .Nil;
            _longjmp(jb, 1);
        }
        @panic("lua_call OOM without an active C-function boundary");
    };
}

/// Unprotected call: on failure, rethrows through the active C-function
/// boundary via longjmp (PUC `luaD_throw`). The success path delegates to
/// `apiCall`, which marshals results on `c_stack`.
///
/// P15.78: When the callee yields (error.Yield), we longjmp with value 2
/// (yield) instead of value 1 (error). This allows `callCFunction` to
/// distinguish yield from error and propagate `error.Yield` up to the
/// trampoline, leaving the C-frame in place for `finishCcall` on resume.
fn lua_callkImpl(L: ?*lua_State, nargs: c_int, nresults: c_int) void {
    const h = L orelse return;
    const vm = h.vm;
    const nargs_usize: usize = @intCast(@max(nargs, 0));
    if (h.c_stack.items.len < nargs_usize + 1) {
        // Stack underflow — treat as error
        if (vm.c_error_jmp) |jb| {
            vm.c_error_value = .Nil;
            _longjmp(jb, 1);
        }
        @panic("lua_call without an active C-function boundary");
    }
    const fn_idx = h.c_stack.items.len - nargs_usize - 1;
    const callee = h.c_stack.items[fn_idx];
    const args = h.c_stack.items[fn_idx + 1 ..];
    const ret = vm.apiCall(.nonyieldable, callee, args) catch |err| switch (err) {
        error.Yield => {
            // P15.78: Callee yielded. Longjmp with value 2 (yield) so
            // callCFunction can propagate error.Yield and leave the C-frame
            // in place for finishCcall on resume.
            if (vm.c_error_jmp) |jb| {
                _longjmp(jb, 2);
            }
            @panic("lua_call yield without an active C-function boundary");
        },
        error.RuntimeError => {
            // Error: propagate through boundary via longjmp
            if (vm.c_error_jmp) |jb| {
                vm.c_error_value = vm.errThread().err_obj;
                _longjmp(jb, 1);
            }
            @panic("lua_call without an active C-function boundary");
        },
        error.OutOfMemory => {
            if (vm.c_error_jmp) |jb| {
                vm.c_error_value = .Nil;
                _longjmp(jb, 1);
            }
            @panic("lua_call OOM without an active C-function boundary");
        },
    };
    defer vm.alloc.free(ret);
    h.c_stack.items.len = fn_idx;
    const want: usize = if (nresults < 0) ret.len else @min(ret.len, @as(usize, @intCast(nresults)));
    h.c_stack.appendSlice(vm.alloc, ret[0..want]) catch {
        if (vm.c_error_jmp) |jb| {
            vm.c_error_value = .Nil;
            _longjmp(jb, 1);
        }
        @panic("lua_call OOM without an active C-function boundary");
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

/// PUC luaM_error via the C boundary for pushvfstring's locally-held
/// buffer: `_longjmp` bypasses Zig `defer`, so the buffer is deinit'd
/// manually BEFORE the throw (P16.50-review-5 B2 — every append failure
/// previously returned "" and leaked the buffer).
fn cThrowOomBuf(vm: *Vm, h: *vm_mod.lua_State, buf: *std.ArrayList(u8)) noreturn {
    buf.deinit(vm.alloc);
    cThrowOn(vm, h, error.OutOfMemory);
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
    const h = L orelse return "".ptr;
    const vm = h.vm;

    // NO defer: _longjmp bypasses it. Every failure path deinits the
    // buffer manually via cThrowOomBuf before throwing LUA_ERRMEM.
    var buf: std.ArrayList(u8) = .empty;
    // Scratch for numeric/pointer specs: formatted into this fixed buffer
    // (no heap temp — the old allocPrint+defer-free dance is gone; the
    // longest possible output, an f64 shortest-round-trip, is < 32 bytes).
    var tmp: [64]u8 = undefined;

    var i: usize = 0;
    while (true) {
        const c = fmt[i];
        if (c == 0) break;
        if (c != '%') {
            buf.append(vm.alloc, c) catch cThrowOomBuf(vm, h, &buf);
            i += 1;
            continue;
        }
        i += 1;
        const spec = fmt[i];
        switch (spec) {
            0 => {
                buf.append(vm.alloc, '%') catch cThrowOomBuf(vm, h, &buf);
                break;
            },
            'd' => {
                const v = @cVaArg(argp, c_int);
                const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
                buf.appendSlice(vm.alloc, s) catch cThrowOomBuf(vm, h, &buf);
            },
            'I' => {
                const v = @cVaArg(argp, i64);
                const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
                buf.appendSlice(vm.alloc, s) catch cThrowOomBuf(vm, h, &buf);
            },
            'f' => {
                const v = @cVaArg(argp, f64);
                const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
                buf.appendSlice(vm.alloc, s) catch cThrowOomBuf(vm, h, &buf);
            },
            's' => {
                const v = @cVaArg(argp, ?[*:0]const u8);
                if (v) |str| {
                    buf.appendSlice(vm.alloc, std.mem.span(str)) catch cThrowOomBuf(vm, h, &buf);
                } else {
                    buf.appendSlice(vm.alloc, "(null)") catch cThrowOomBuf(vm, h, &buf);
                }
            },
            'c' => {
                const v = @cVaArg(argp, c_int);
                buf.append(vm.alloc, @intCast(@as(u32, @bitCast(v)) & 0xFF)) catch cThrowOomBuf(vm, h, &buf);
            },
            'p' => {
                const v = @cVaArg(argp, ?*anyopaque);
                const s = std.fmt.bufPrint(&tmp, "{x}", .{@intFromPtr(v)}) catch unreachable;
                buf.appendSlice(vm.alloc, s) catch cThrowOomBuf(vm, h, &buf);
            },
            'U' => {
                const cp = @cVaArg(argp, c_int);
                var utf8: [4]u8 = undefined;
                const codepoint: u21 = @intCast(@as(u32, @bitCast(cp)) & 0x7FFFFFFF);
                // (c) PUC parity: an invalid codepoint encodes to 0 bytes
                // (luaO_utf8esc's failure mode) — nothing is appended.
                const n = std.unicode.utf8Encode(codepoint, &utf8) catch 0;
                buf.appendSlice(vm.alloc, utf8[0..n]) catch cThrowOomBuf(vm, h, &buf);
            },
            '%' => buf.append(vm.alloc, '%') catch cThrowOomBuf(vm, h, &buf),
            else => {
                // PUC default: keep unknown specifier verbatim (e.g. "%x" stays "%x")
                buf.append(vm.alloc, '%') catch cThrowOomBuf(vm, h, &buf);
                buf.append(vm.alloc, spec) catch cThrowOomBuf(vm, h, &buf);
            },
        }
        i += 1;
    }

    // PUC luaO_pushvfstring → luaS_new: OOM is LUA_ERRMEM (never "").
    const ls = vm.internStr(buf.items) catch cThrowOomBuf(vm, h, &buf);
    h.c_stack.append(vm.alloc, .{ .String = ls }) catch cThrowOomBuf(vm, h, &buf);
    buf.deinit(vm.alloc);
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
    const h: *lua_State = @ptrCast(@alignCast(ud orelse return null));
    const vm = h.vm;
    if (nsize == 0) {
        if (ptr) |p| {
            const old_buf: [*]u8 = @ptrCast(p);
            vm.alloc.free(old_buf[0..osize]);
        }
        return null;
    }
    if (ptr) |p| {
        const old_buf: [*]u8 = @ptrCast(p);
        // (b) lua_Alloc C contract: the allocator callback returns NULL on
        // failure — PUC's l_alloc does the same (the caller decides the
        // error status; the fixed MEMERRMSG path never re-enters here).
        const new_buf = vm.alloc.realloc(old_buf[0..osize], nsize) catch return null;
        return @ptrCast(new_buf.ptr);
    }
    const new_buf = vm.alloc.alloc(u8, nsize) catch return null; // (b) same contract
    return @ptrCast(new_buf.ptr);
}

/// PUC `lua_getallocf` (lapi.c:1319): return the VM's allocator function.
/// If a custom allocator was set via `lua_newstate` or `lua_setallocf`,
/// returns that function and its user-data — matching PUC's contract.
/// Otherwise returns the internal `cApiAllocWrapper` and `L` as user-data.
pub export fn lua_getallocf(L: ?*lua_State, ud: ?*?*anyopaque) lua_Alloc {
    const h = L orelse return null;
    const vm = h.vm;
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
    const h = L orelse return;
    const vm = h.vm;
    vm.c_alloc_fn = f;
    vm.c_alloc_ud = ud;
}

// ===========================================================================
// Load / dump (PUC lapi.c / ldo.c / ldump.c)
// ===========================================================================

/// PUC `lua_load` (ldo.c:lua_load → lapi.c:1120): load and compile a Lua
/// chunk from a reader callback. The reader is called repeatedly; each call
/// returns a pointer to a chunk and writes its size to `*sz`. NULL or zero
/// size signals end-of-input.
///
/// PUC's `lua_load` feeds the reader to a ZIO stream, then calls
/// `luaD_protectedparser` → `f_parser` (ldo.c:1123-1141), which reads the
/// first byte to dispatch binary vs text and applies `checkmode`
/// (ldo.c:1114-1119). We collect all reader chunks into a contiguous buffer
/// (PUC's ZIO does the same lazily), then delegate to `Vm.loadChunk` (our
/// `f_parser` equivalent).
///
/// **Mode semantics** (PUC ldo.c:1126-1138):
///   - `null` → `"bt"` (both binary and text allowed)
///   - `'b'` → binary allowed; `'t'` → text allowed
///   - `'B'` → binary + fixed-buffer borrowing (input must be contiguous)
///
/// **Generic-reader 'B' verdict**: PUC's ZIO borrows from the reader's
/// current block via `luaZ_getaddr` (lzio.c:79-91). For a fragmented reader
/// (multiple small blocks), `getaddr` returns NULL if the requested block
/// spans two reader chunks, causing `lundump.c:80` to error "truncated fixed
/// buffer". Our `lua_load` collects ALL reader chunks into ONE contiguous
/// buffer before calling `loadChunk`, so 'B' mode borrowing is ALWAYS legal
/// (the buffer is contiguous by construction). This never fails where PUC
/// fails (PUC's auxlib `getS` also returns one block), and may succeed where
/// PUC's generic `lua_load` with a fragmented reader would fail — an
/// acceptable improvement, not a deviation.
pub export fn lua_load(
    L: ?*lua_State,
    reader: ?*const fn (?*lua_State, ?*anyopaque, ?*usize) callconv(.c) ?[*]const u8,
    data: ?*anyopaque,
    chunkname: ?[*:0]const u8,
    mode: ?[*:0]const u8,
) c_int {
    const h = L orelse return 2; // LUA_ERRRUN
    const vm = h.vm;

    // Collect all chunks from the reader into a contiguous buffer (PUC's
    // `luaD_protectedparser` does the same via `luaZ_read` into a growable
    // buffer before parsing). The buffer is owned by us and transferred to
    // `loadChunk` as `.owned`.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(vm.alloc);
    while (true) {
        var sz: usize = 0;
        const chunk = reader.?(L, data, &sz) orelse break;
        if (sz == 0) break;
        buf.appendSlice(vm.alloc, chunk[0..sz]) catch return statusCode(.memory_error);
    }
    const owned_bytes = buf.toOwnedSlice(vm.alloc) catch return statusCode(.memory_error);

    const name = if (chunkname) |n| std.mem.span(n) else "=?";
    const mode_slice: ?[]const u8 = if (mode) |m| std.mem.span(m) else null;
    const env: Value = .{ .Table = vm.global_env };

    const result = vm.loadChunk(.{ .owned = owned_bytes }, owned_bytes, name, mode_slice, env, null) catch |err| switch (err) {
        error.OutOfMemory => return statusCode(.memory_error),
        error.RuntimeError, error.Yield => return statusCode(.runtime_error),
    };
    switch (result) {
        .closure => |cl| {
            h.c_stack.append(vm.alloc, .{ .Closure = cl }) catch return statusCode(.memory_error);
            return 0; // LUA_OK
        },
        .err_msg => |msg| {
            defer vm.alloc.free(msg);
            const errval = vm.internStr(msg) catch return statusCode(.memory_error);
            h.c_stack.append(vm.alloc, .{ .String = errval }) catch return statusCode(.memory_error);
            return statusCode(.syntax_error); // LUA_ERRSYNTAX
        },
    }
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
    const h = L orelse return 1;
    const vm = h.vm;
    if (writer == null) return 1;

    // Get the function at the top of c_stack (PUC uses index2value(L, -1)).
    if (h.c_stack.items.len == 0) return 1;
    const val = h.c_stack.items[h.c_stack.items.len - 1];
    const cl = switch (val) {
        .Closure => |c| c,
        else => return 1, // not a Lua function
    };
    const proto = cl.proto orelse return 1; // C closure — cannot dump

    // Serialize the Proto tree into a binary chunk via DumpWriter.
    // `strip` is a serialization property (PUC DumpState.strip): the
    // writer omits debug fields while serializing — no Proto clone.
    var dw = dump_mod.DumpWriter.init(vm.alloc);
    defer dw.deinit();
    dw.dumpChunk(proto, .{ .strip = strip != 0 }) catch return 1;
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
    const h = L orelse return;
    const vm = h.vm;
    vm.c_warnf = f;
    vm.c_warn_ud = ud;
}

/// PUC `lua_warning` (lapi.c:1333): emit a warning. If a warning handler is
/// installed (via `lua_setwarnf`), the message is forwarded to it. `tocont`
/// is 1 if more warning text follows (multi-part warnings). If no handler is
/// installed, the warning is silently dropped (PUC's default behavior).
pub export fn lua_warning(L: ?*lua_State, msg: ?[*:0]const u8, tocont: c_int) void {
    const h = L orelse return;
    const vm = h.vm;
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
    const h = L orelse return 0;
    const vm = h.vm;
    const str = std.mem.span(s);
    const trimmed = std.mem.trim(u8, str, " \t\n\x0b\x0c\r");
    if (trimmed.len == 0) return 0;

    // Try integer first (PUC's `l_str2int`): handles decimal and hex (0x).
    if (std.fmt.parseInt(i64, trimmed, 0)) |i| {
        // PUC lua_stringtonumber → lua_pushinteger → api_incr_top: OOM is
        // LUA_ERRMEM (P16.50-review-5 B2 — the old `catch return 0` masked
        // the push failure as "not a number").
        h.c_stack.append(vm.alloc, .{ .Int = i }) catch |e| cThrowOn(vm, h, e);
        return str.len + 1; // PUC returns strlen(s) + 1 (including NUL)
    } else |_| {}

    // Try float (PUC's `l_str2d`): handles decimal, hex floats, inf, nan.
    if (std.fmt.parseFloat(f64, trimmed)) |n| {
        h.c_stack.append(vm.alloc, .{ .Num = n }) catch |e| cThrowOn(vm, h, e);
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
    const h = L orelse return 0;
    const abs = normalizeIndex(idx, h.c_stack.items.len) orelse return 0;
    const val = h.c_stack.items[abs];

    switch (val) {
        .Int => |i| {
            // (c) infallible: LUA_N2SBUFFSZ is 64 bytes; the longest {d}
            // output for an i64 is 20 chars — NoSpaceLeft is impossible.
            const s = std.fmt.bufPrint(buff[0..64], "{d}", .{i}) catch unreachable;
            buff[s.len] = 0; // NUL-terminate
            return @intCast(s.len + 1);
        },
        .Num => |n| {
            // (c) infallible: the longest {d} output for an f64 shortest
            // round-trip ("-1.7976931348623157e308") is 24 chars < 64.
            const s = std.fmt.bufPrint(buff[0..64], "{d}", .{n}) catch unreachable;
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

/// PUC `lua_toclose` (lapi.c:1283): mark the stack slot at `idx` as a
/// to-be-closed variable. The mark goes on the THREAD-owned TBC chain
/// (`Thread.c_tbc_chain` — PUC `L->tbclist`), LIFO by mark order; the slot
/// is closed by `lua_closeslot`, when the owning frame returns
/// (callCFunction/finishCcall — PUC `moveresults` → `luaF_close`; a Lua
/// frame's OP_RETURN — PUC `luaF_close(base)`/`moveresults`), or over an
/// in-flight error (PUC `luaD_closeprotected`).
///
/// PUC marks `L->ci` — ALWAYS the topmost CallInfo of the state running the
/// C code. Two lanes reach here:
///   * a C function (called via lua_call/OP_CALL): its own C CallInfo is
///     topmost — the frame_slot path (live slot on the frame's c_stack);
///   * a debug hook (PUC `luaD_hook` runs hooks with NO CallInfo of their
///     own, keeping `L->ci` = the interrupted frame): the topmost frame is
///     the interrupted LUA frame — the hook path below.
///
/// PUC api_check: the new mark must be ABOVE the chain's current top
/// (`L->tbclist.p < o`) — within one frame's stack the marks are LIFO by
/// slot. luazig's chain stores (owning frame, slot) pairs; only slots of
/// the SAME frame are comparable, so the LIFO check is enforced
/// within-frame (cross-frame marks live on different stacks and always
/// append, exactly like PUC marks on different stack levels). Violations
/// are lenient (ignored) instead of api_check-aborting.
pub export fn lua_toclose(L: ?*lua_State, idx: c_int) void {
    const h = L orelse return;
    const vm = h.vm;
    const abs = normalizeIndex(idx, h.c_stack.items.len) orelse return;
    // The mark goes on the topmost frame of the thread that owns the
    // current execution (PUC: L->ci — the running activation). While a C
    // function runs, that is always its own callCFunction frame; while a
    // debug hook runs (hooks get no frame of their own — PUC luaD_hook
    // keeps L->ci = the interrupted frame), it is the interrupted Lua
    // frame.
    const th = vm.current_thread orelse vm.main_thread orelse return;
    const th_bc = th.call_frames;
    if (th_bc.len() == 0) return; // no activation: PUC api_check-fail; lenient no-op
    const fi = th_bc.len() - 1;
    const f = th_bc.getConstPtr(fi);
    // P16.31 Cut 5: TbcEntry is a tagged union — live marks are frame_slot
    // pairs (detached entries arise from pop-detach and the hook lane).
    const chain = &th.c_tbc_chain;
    if (f.isC()) {
        // C-function lane: the slot lives on this frame's (parked) c_stack.
        // Within-frame LIFO: a mark at or below the frame's chain top is a
        // PUC api_check violation — lenient ignore (idempotent re-mark).
        if (chain.items.len > 0) {
            const top = chain.items[chain.items.len - 1];
            if (top == .frame_slot and top.frame_slot.cframe_idx == fi and
                top.frame_slot.slot_idx >= abs) return;
        }
        // PUC lua_toclose → luaF_newtbcmark → luaM_error: OOM is
        // LUA_ERRMEM (P16.50-review-5 B2 — the old `catch {}` silently
        // dropped the __close mark).
        chain.append(vm.alloc, .{ .frame_slot = .{
            .cframe_idx = fi,
            .slot_idx = abs,
        } }) catch |e| cThrowOn(vm, h, e);
    } else {
        // Hook lane (PUC luaD_hook: L->ci = the interrupted Lua frame).
        // PUC marks the frame (CIST_TBC) + the slot's LEVEL in tbclist; the
        // close later reads the LIVE slot at that level. luazig captures
        // the value NOW as a detached entry: the hook's c_stack slot is
        // unstable across later C-API operations, and Lua execution uses
        // the bc_stack — so nothing between the hook and the close observes
        // that c_stack slot. This is equivalent to PUC's live-level read
        // for every shape where the mark's stack level is not reused
        // before the close (a second hook event or a C call reusing the
        // level is a PUC shared-stack quirk luazig's split stacks cannot
        // — and need not — reproduce).
        const value = if (abs < h.c_stack.items.len) h.c_stack.items[abs] else .Nil;
        // Same luaF_newtbcmark OOM contract as the frame_slot lane above.
        chain.append(vm.alloc, .{ .detached = value }) catch |e| cThrowOn(vm, h, e);
    }
    // PUC sets CIST_TBC on L->ci (the frame "has marks" hint) — gates the
    // chain-region close at the frame's return (PUC moveresults) and the
    // script-end close.
    const fmut = th.call_frames.getPtr(fi);
    if (!fmut.isTbc()) fmut.setTbc();
}

/// PUC `lua_closeslot` (lapi.c:206): close the to-be-closed slot at `idx`.
/// PUC api_check: the slot must be the TOP of the thread's tbclist AND
/// belong to the current CallInfo. Lenient: only close when the chain top
/// is exactly (topmost C-frame of the current thread, abs).
///
/// PUC semantics: `luaF_close(level, CLOSEKTOP, yy=0)` — the mark is popped
/// BEFORE the closer runs, the slot is set to nil, and `__close(obj)` is
/// called NON-yieldably (a yield attempt there is "attempt to yield across
/// a C-call boundary"). Errors from `__close` propagate to the caller
/// (PUC `luaD_callnoyield` → `luaD_throw`).
pub export fn lua_closeslot(L: ?*lua_State, idx: c_int) void {
    const h = L orelse return;
    const vm = h.vm;
    const abs = normalizeIndex(idx, h.c_stack.items.len) orelse return;
    const th = vm.current_thread orelse vm.main_thread orelse return;
    const th_bc = th.call_frames;
    // The current C activation: the topmost C-frame of this thread.
    var fi = th_bc.len();
    while (fi > 0) {
        fi -= 1;
        if (th_bc.getConstPtr(fi).isC()) break;
    }
    if (fi == 0 and (th_bc.len() == 0 or !th_bc.getConstPtr(0).isC())) return;
    const chain = &th.c_tbc_chain;
    if (chain.items.len == 0) return;
    const top = chain.items[chain.items.len - 1];
    // P16.31 Cut 3: only a live frame_slot mark can be closed by slot
    // identity (a detached entry has no slot — it was captured at pop).
    if (top != .frame_slot) return;
    if (top.frame_slot.cframe_idx != fi or top.frame_slot.slot_idx != abs) return; // not the chain top

    // Pop the mark BEFORE the closer runs (PUC poptbclist-then-close: a
    // closer error must not re-close this entry). Ordered pop — it IS the
    // top entry.
    _ = chain.pop();
    const val = if (abs < h.c_stack.items.len) h.c_stack.items[abs] else .Nil;
    // PUC preclose(CLOSEKTOP): the closed slot becomes nil immediately.
    if (abs < h.c_stack.items.len) h.c_stack.items[abs] = .Nil;

    const mm = vm.getTmByObj(val, .close);
    if (mm == null) {
        // No __close metamethod: PUC checkclosemth raises "non-closable";
        // the c_api lane is lenient (mark popped, slot nil — close done).
        return;
    }

    // Call __close(val) with 0 results, non-yieldably (PUC luaD_callnoyield).
    // Errors propagate to the caller's pcall/error handler (PUC luaD_call →
    // luaD_throw): re-raise through the C-function boundary directly with
    // the error object the VM already installed — no intermediate stack
    // push (which itself could OOM; P16.50-review-5 B2 removed the old
    // append-swallow-then-lua_error detour).
    var call_args = [_]Value{val};
    _ = vm.apiCall(.nonyieldable, mm.?.*, call_args[0..]) catch |e| switch (e) {
        // .nonyieldable contract: apiCall never reports error.Yield here.
        error.Yield => unreachable,
        error.OutOfMemory => cThrowOn(vm, h, error.OutOfMemory),
        error.RuntimeError => cThrowOn(vm, h, error.Runtime),
    };
}

/// PUC `luaL_loadbufferx` (lauxlib.c:867-872): load a chunk from a byte
/// buffer. PUC wraps the buffer in a `getS` reader (which returns the whole
/// buffer in one call) and delegates to `lua_load`. We delegate directly to
/// `Vm.loadChunk` with `.borrowed` input — the C buffer is contiguous by
/// contract, so mode 'B' (fixed-buffer borrowing) is always legal.
///
/// **'B' fixed-buffer borrowing** (Task 5): when mode contains 'B', the
/// primitive borrows code/lineinfo/long-strings directly from the caller's
/// buffer (no copy). The caller MUST keep `buff` alive until the closure is
/// dropped and GC'd. The tree's `source_backing.external_borrow` records
/// this span (never freed, never GC-marked — distinct from pinned LuaStrings
/// and owned heap buffers).
///
/// **Mode semantics** (PUC ldo.c:1126-1138, via lauxlib.c:872 → lua_load):
///   - `null` → `"bt"` (both binary and text allowed)
///   - `'b'` → binary allowed; `'t'` → text allowed
///   - `'B'` → binary + fixed-buffer borrowing (no copy)
pub export fn luaL_loadbufferx(L: ?*lua_State, buff: [*]const u8, sz: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int {
    const h = L orelse return 2; // LUA_ERRRUN
    const vm = h.vm;
    const mode_slice: ?[]const u8 = if (mode) |m| std.mem.span(m) else null;
    const env: Value = .{ .Table = vm.global_env };

    const result = vm.loadChunk(.{ .borrowed = buff[0..sz] }, buff[0..sz], std.mem.span(name), mode_slice, env, null) catch |err| switch (err) {
        error.OutOfMemory => return statusCode(.memory_error),
        error.RuntimeError, error.Yield => return statusCode(.runtime_error),
    };
    switch (result) {
        .closure => |cl| {
            h.c_stack.append(vm.alloc, .{ .Closure = cl }) catch return statusCode(.memory_error);
            return 0; // LUA_OK
        },
        .err_msg => |msg| {
            defer vm.alloc.free(msg);
            const errval = vm.internStr(msg) catch return statusCode(.memory_error);
            h.c_stack.append(vm.alloc, .{ .String = errval }) catch return statusCode(.memory_error);
            return statusCode(.syntax_error); // LUA_ERRSYNTAX
        },
    }
}

/// PUC `luaL_loadfilex` (lauxlib.c:808-853): load a chunk from a file.
/// PUC reads the file via `getF` (a reader that reads BUFSIZ chunks) and
/// delegates to `lua_load` with the mode string. We read the entire file
/// into a buffer, then delegate to `Vm.loadChunk` with `.owned` input.
///
/// **loadfilex 'B' verdict**: PUC's `luaL_loadfilex` passes mode through to
/// `lua_load`, which uses ZIO. For 'B' mode, `luaZ_getaddr` (lzio.c:79-91)
/// borrows from the ZIO's current buffer — which is `lf.buff` filled by
/// `fread`. If the file fits in one `getF` call (BUFSIZ), the ZIO has one
/// contiguous block and 'B' borrowing works. If the file is larger,
/// `getaddr` returns NULL and `lundump.c:80` errors "truncated fixed
/// buffer". In practice, 'B' mode is only used with `luaL_loadbufferx`
/// (where the buffer is known contiguous); `luaL_loadfilex('B')` is
/// uncommon and PUC's behavior is fragile. Our implementation reads the
/// whole file into ONE contiguous buffer, so 'B' borrowing is always legal
/// — same as our `lua_load` (an acceptable improvement, not a deviation).
pub export fn luaL_loadfilex(L: ?*lua_State, filename: [*:0]const u8, mode: ?[*:0]const u8) c_int {
    const h = L orelse return 2; // LUA_ERRRUN
    const vm = h.vm;
    // (b) status-returning: luaL_loadfilex reports failures as a status.
    // Residual divergence (B2 inventory, not a swallow): PUC maps a missing
    // file to LUA_ERRFILE; loadFile's error set is undifferentiated here, so
    // every failure reports LUA_ERRMEM (candidate follow-up: split the
    // error kinds once statusCode grows an ERRFILE arm).
    const source = source_mod.Source.loadFile(vm.alloc, stdio.activeIo(), std.mem.span(filename)) catch
        return statusCode(.memory_error);
    // PUC lauxlib.c:820-836: skip BOM and optional `#` first-line comment
    // (skipcomment). The chunk name for files is "@<path>", so shebang
    // stripping is always allowed (PUC's skipcomment doesn't check the
    // name; it always checks for `#`).
    const prefix = vm_mod.Vm.stripChunkPrefix(source.bytes, true);
    var chunk_bytes = prefix.bytes;
    var prefixed_buf: ?[]u8 = null;
    defer {
        if (prefixed_buf) |b| vm.alloc.free(b);
    }
    // PUC lauxlib.c:824-825: if a comment was skipped and the chunk is
    // text (not binary), add a '\n' to correct line numbers. Binary
    // chunks don't need line correction (lauxlib.c:827 "remove possible
    // newline").
    if (prefix.had_shebang and !(chunk_bytes.len > 0 and chunk_bytes[0] == 0x1b)) {
        prefixed_buf = vm.alloc.alloc(u8, chunk_bytes.len + 1) catch {
            vm.alloc.free(source.name);
            vm.alloc.free(source.bytes);
            return statusCode(.memory_error);
        };
        prefixed_buf.?[0] = '\n';
        @memcpy(prefixed_buf.?[1..], chunk_bytes);
        chunk_bytes = prefixed_buf.?;
    }

    // The file bytes are owned by us and transferred to loadChunk as .owned
    // (or the prefixed_buf if shebang was stripped). The source name is
    // borrowed from source.name (loadChunk copies it for text, ignores it
    // for binary).
    const mode_slice: ?[]const u8 = if (mode) |m| std.mem.span(m) else null;
    const env: Value = .{ .Table = vm.global_env };

    const input: vm_mod.Vm.LoadInput = if (prefixed_buf) |buf|
        .{ .owned = buf }
    else
        .{ .owned = source.bytes };
    // Track whether we need to free source.bytes (only when prefixed_buf
    // replaced it as the input).
    const source_bytes_freed_by_load = prefixed_buf != null;

    const result = vm.loadChunk(input, chunk_bytes, source.name, mode_slice, env, null) catch |err| switch (err) {
        error.OutOfMemory => {
            vm.alloc.free(source.name);
            if (!source_bytes_freed_by_load) vm.alloc.free(source.bytes);
            if (prefixed_buf) |b| vm.alloc.free(b);
            return statusCode(.memory_error);
        },
        error.RuntimeError, error.Yield => {
            vm.alloc.free(source.name);
            if (!source_bytes_freed_by_load) vm.alloc.free(source.bytes);
            if (prefixed_buf) |b| vm.alloc.free(b);
            return statusCode(.runtime_error);
        },
    };
    // source.name is borrowed during loadChunk; free it now (loadChunk has
    // either copied it for text or ignored it for binary).
    vm.alloc.free(source.name);
    // If loadChunk consumed source.bytes (no prefixed_buf), it's already
    // freed or attached to the tree. If we used prefixed_buf, free
    // source.bytes now (it's no longer needed).
    if (source_bytes_freed_by_load) vm.alloc.free(source.bytes);
    // prefixed_buf ownership was transferred to loadChunk (if used).
    if (prefixed_buf) |_| prefixed_buf = null;

    switch (result) {
        .closure => |cl| {
            h.c_stack.append(vm.alloc, .{ .Closure = cl }) catch return statusCode(.memory_error);
            return 0; // LUA_OK
        },
        .err_msg => |msg| {
            defer vm.alloc.free(msg);
            const errval = vm.internStr(msg) catch return statusCode(.memory_error);
            h.c_stack.append(vm.alloc, .{ .String = errval }) catch return statusCode(.memory_error);
            return statusCode(.syntax_error); // LUA_ERRSYNTAX
        },
    }
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
// B2 inventory note for this block: pop/rotate/copy/insert/remove/absindex
// operate on EXISTING stack slots only — their error sets are
// InvalidIndex-only (no allocation). PUC treats a bad index as an api_check
// precondition (abort in apicheck builds); these shims are lenient no-ops
// instead (class (c) — infallible w.r.t. allocation, precondition-lenient).

pub export fn lua_gettop(L: ?*lua_State) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    return @intCast(s.gettop());
}

pub export fn lua_settop(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.settop(idx) catch |e| switch (e) {
        // Growing the stack (idx above top) → PUC luaD_growstack →
        // LUA_ERRMEM. InvalidIndex is PUC api_check — lenient.
        error.OutOfMemory => cThrowOn(s.vm, L.?, e),
        else => {},
    };
}

pub export fn lua_pop(L: ?*lua_State, n: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    if (n <= 0) return;
    s.pop(@intCast(n)) catch {}; // (c): InvalidIndex-only (see block note)
}

pub export fn lua_rotate(L: ?*lua_State, idx: c_int, n: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.rotate(idx, n) catch {}; // (c): in-stack rotate, InvalidIndex-only
}

pub export fn lua_copy(L: ?*lua_State, fromidx: c_int, toidx: c_int) void {
    const h = L orelse return;
    const vm = h.vm;
    // Handle upvalue pseudo-index as destination (write to upvalue)
    if (toidx < -1001000 and toidx >= -1001255) {
        const src = upvalueAt(vm, fromidx) orelse blk: {
            const abs = normalizeIndex(fromidx, h.c_stack.items.len) orelse return;
            break :blk h.c_stack.items[abs];
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
        const abs = normalizeIndex(toidx, h.c_stack.items.len) orelse return;
        h.c_stack.items[abs] = src;
        return;
    }
    var s = api.State.fromHandle(h);
    s.copy(fromidx, toidx) catch {}; // (c): in-stack write, InvalidIndex-only
}

pub export fn lua_insert(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.insert(idx) catch {}; // (c): in-stack move (rotate), InvalidIndex-only
}

pub export fn lua_remove(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.remove(idx) catch {}; // (c): in-stack move (rotate+pop), InvalidIndex-only
}

pub export fn lua_absindex(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // (c): pure index arithmetic, InvalidIndex-only → lenient 0.
    return @intCast(s.absindex(idx) catch 0);
}

pub export fn lua_checkstack(L: ?*lua_State, n: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    if (n < 0) return 0;
    // (b) PUC contract: lua_checkstack grows with raiseerror=0
    // (luaD_growstack's non-throwing mode) and RETURNS 0 on failure —
    // never a throw.
    s.checkstack(@intCast(n)) catch return 0;
    return 1;
}

// --- Push functions ---

pub export fn lua_pushnil(L: ?*lua_State) void {
    var s = api.State.fromHandle(L orelse return);
    // PUC api_incr_top → luaD_checkstack: an OOM here is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch {}` silently dropped the push).
    s.pushnil() catch |e| cThrowOn(s.vm, L.?, e);
}

pub export fn lua_pushboolean(L: ?*lua_State, b: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.pushboolean(b != 0) catch |e| cThrowOn(s.vm, L.?, e);
}

pub export fn lua_pushinteger(L: ?*lua_State, v: i64) void {
    var s = api.State.fromHandle(L orelse return);
    s.pushinteger(v) catch |e| cThrowOn(s.vm, L.?, e);
}

pub export fn lua_pushnumber(L: ?*lua_State, v: f64) void {
    var s = api.State.fromHandle(L orelse return);
    s.pushnumber(v) catch |e| cThrowOn(s.vm, L.?, e);
}

pub export fn lua_pushstring(L: ?*lua_State, s: [*:0]const u8) void {
    var st = api.State.fromHandle(L orelse return);
    // PUC lua_pushstring → luaS_new → luaC_newobj: OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch {}` silently dropped the push).
    st.pushstring(std.mem.span(s)) catch |e| cThrowOn(st.vm, L.?, e);
}

pub export fn lua_pushliteral(L: ?*lua_State, s: [*:0]const u8) void {
    lua_pushstring(L, s);
}

pub export fn lua_pushlstring(L: ?*lua_State, s: [*]const u8, len: usize) void {
    var st = api.State.fromHandle(L orelse return);
    st.pushlstring(s[0..len]) catch |e| cThrowOn(st.vm, L.?, e);
}

pub export fn lua_pushvalue(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.pushvalue(idx) catch |e| switch (e) {
        // OOM: PUC api_incr_top → luaD_checkstack → LUA_ERRMEM.
        error.OutOfMemory => cThrowOn(s.vm, L.?, e),
        // InvalidIndex: PUC api_check precondition — lenient no-op.
        else => {},
    };
}

pub export fn lua_pushlightuserdata(L: ?*lua_State, p: ?*anyopaque) void {
    var s = api.State.fromHandle(L orelse return);
    s.pushlightuserdata(p) catch |e| cThrowOn(s.vm, L.?, e);
}

/// P16.50-review: the shared `luaD_throw` equivalent for void C-ABI
/// functions whose transactional internals return ApiError. PUC
/// (`lmem.c` luaM_error → `ldo.c:125-146` luaD_throw) never lets an OOM
/// surface as silent success: it longjmps to the nearest pcall anchor
/// (`c_error_jmp` here — installed by callCFunctionWithBoundary, the
/// luaD_rawrunprotected analogue) and, with no anchor, calls the
/// `atpanic` hook then aborts. Matches the existing lua_callkImpl OOM
/// arm (which sets c_error_value = .Nil and _longjmps).
fn cThrowOn(vm: *Vm, throwing: *vm_mod.lua_State, err: api.ApiError) noreturn {
    // P16.50-review-3 HIGH: the throwing STATE is explicit — cPanic used
    // vm.cur_handle which may differ from the L an exported API received
    // (a non-current coroutine handle); the panic hook must see the
    // throwing L and its error object.
    // BLOCKER 2 PUC requirement: OOM installs the FIXED MEMERRMSG object
    // (luaD_seterrorobj parity — "not enough memory", not a nil).
    switch (err) {
        error.OutOfMemory => {
            if (vm.c_error_jmp) |jb| {
                // PUC luaD_seterrorobj(ERRMEM): installs the FIXED
                // statMsg literal — never allocates. The VM's
                // outOfMemoryError installs the same interned literal;
                // reuse its machinery so the object identity matches what
                // the Lua-facing error paths observe (and no new interning
                // can fail under the failing allocator).
                vm.setOutOfMemoryError();
                vm.c_error_value = vm.errThread().err_obj;
                vm.c_error_status = 4; // LUA_ERRMEM
                _longjmp(jb, 1);
            }
            cPanicOn(vm, throwing, "not enough memory");
        },
        // P16.50-review-5 3.1: the remaining ApiError members are
        // ENUMERATED — no catch-all `else` prong. A future ApiError kind
        // must become a compile error here, never a silent ERRRUN. All of
        // these surface as LUA_ERRRUN: Runtime is the Lua-facing runtime
        // error; Type/InvalidIndex/InvalidState are PUC api_check-class
        // failures reported as errors rather than UB; Syntax never reaches
        // the throw path (load maps it to LUA_ERRSYNTAX before throwing);
        // Memory is currently an unused ApiError member kept for source
        // compatibility.
        error.Type,
        error.Runtime,
        error.Syntax,
        error.Memory,
        error.InvalidIndex,
        error.InvalidState,
        => {
            if (vm.c_error_jmp) |jb| {
                vm.c_error_value = vm.errThread().err_obj;
                vm.c_error_status = 2; // LUA_ERRRUN
                _longjmp(jb, 1);
            }
            cPanicOn(vm, throwing, null);
        },
    }
}

// P16.50-review-4 BLOCKER 2: the implicit-current helper is DELETED — it
// substituted vm.cur_handle for the throwing export's L, so an
// unprotected OOM on a non-current coroutine ran atpanic with the main
// state. Every throwing export passes its OWN L to cThrowOn.

/// PUC `g->panic(L)` + abort (ldo.c:141-146): the unprotected-throw
/// fallback. The hook runs EXACTLY once; a return falls through to the
/// terminal panic (PUC aborts — a Zig @panic carries the same
/// no-return contract with a diagnostic).
fn cPanicOn(vm: *Vm, throwing: *vm_mod.lua_State, msg: ?[]const u8) noreturn {
    // PUC g->panic(L) receives the state and reads the error object from
    // its stack top (ldo.c:141-146 sets it via luaD_seterrorobj first).
    // Install the message (fixed MEMERRMSG for OOM) so the hook observes
    // the exact object, run the hook EXACTLY once, then terminate.
    if (msg) |m| {
        // (d) terminal path, best-effort: the only msg is the fixed
        // MEMERRMSG, pre-interned ONCE at Vm init (oom_msg_str — see
        // setOutOfMemoryError), so internStrAssume is a no-alloc lookup.
        // The append installs the object for the panic hook exactly like
        // PUC's in-stack luaD_seterrorobj (infallible there); if the append
        // itself OOMs, the hook sees a stale top — observable only by the
        // hook, which runs once immediately before the terminal abort.
        throwing.c_stack.append(vm.alloc, .{ .String = vm.internStrAssume(m) }) catch {};
    }
    if (vm.c_panicf) |pf| {
        _ = pf(throwing);
    }
    @panic("lua error without an active C-function boundary (panic hook returned)");
}

fn cPanic(vm: *Vm) noreturn {
    cPanicOn(vm, vm.cur_handle.?, null);
}

pub export fn lua_pushcclosure(L: ?*lua_State, f: ?*const fn (?*lua_State) callconv(.c) c_int, n: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.pushcclosure(f, @intCast(@max(n, 0))) catch |e| cThrowOn(s.vm, L.?, e);
}

pub export fn lua_pushcfunction(L: ?*lua_State, f: ?*const fn (?*lua_State) callconv(.c) c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.pushcfunction(f) catch |e| cThrowOn(s.vm, L.?, e);
}

pub export fn lua_pushexternalstring(
    L: ?*lua_State,
    s: [*]u8,
    len: usize,
    falloc: lua_Alloc,
    ud: ?*anyopaque,
) void {
    var st = api.State.fromHandle(L orelse return);
    // PUC lua_pushfstring-family: any string-construction OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch {}` silently dropped the push).
    st.pushexternalString(s, len, falloc, ud) catch |e| cThrowOn(st.vm, L.?, e);
}

// --- Type / conversion ---

pub export fn lua_type(L: ?*lua_State, idx: c_int) c_int {
    const h = L orelse return -1;
    const vm = h.vm;
    if (upvalueAt(vm, idx)) |v| return typeCode(api.valueType(v));
    var s = api.State.fromHandle(h);
    return if (s.typeOf(idx)) |t| typeCode(t) else -1;
}

pub export fn lua_toboolean(L: ?*lua_State, idx: c_int) c_int {
    const h = L orelse return 0;
    const vm = h.vm;
    if (upvalueAt(vm, idx)) |v| return switch (v) {
        .Nil => 0,
        .Bool => |b| if (b) 1 else 0,
        else => 1,
    };
    var s = api.State.fromHandle(h);
    return if (s.toboolean(idx)) 1 else 0;
}

pub export fn lua_tointegerx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) i64 {
    const h = L orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    const vm = h.vm;
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
    var s = api.State.fromHandle(h);
    if (s.tointeger(idx)) |v| {
        if (isnum) |p| p.* = 1;
        return v;
    }
    if (isnum) |p| p.* = 0;
    return 0;
}

pub export fn lua_tonumberx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) f64 {
    const h = L orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    const vm = h.vm;
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
    var s = api.State.fromHandle(h);
    if (s.tonumber(idx)) |v| {
        if (isnum) |p| p.* = 1;
        return v;
    }
    if (isnum) |p| p.* = 0;
    return 0;
}

// --- Type predicates (PUC lapi.c:lua_is*) ---

pub export fn lua_isnumber(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    return if (s.isnumber(idx)) 1 else 0;
}

pub export fn lua_isstring(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    return if (s.isstring(idx)) 1 else 0;
}

pub export fn lua_isinteger(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    return if (s.isinteger(idx)) 1 else 0;
}

pub export fn lua_iscfunction(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    return if (s.iscfunction(idx)) 1 else 0;
}

pub export fn lua_isuserdata(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    return if (s.isuserdata(idx)) 1 else 0;
}

pub export fn lua_isyieldable(L: ?*lua_State) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // (c) infallible: apiIsYieldable is a pure nCcalls/status check (no
    // allocation); the catch only guards the typed error union — false.
    return if (s.isyieldable(null) catch false) 1 else 0;
}

// --- Conversions (PUC lapi.c:lua_to*) ---

/// PUC `lua_tolstring`: convert value to string, return NUL-terminated C
/// pointer. Writes byte length to `*len` if non-null. Returns NULL for
/// non-convertible values and out-of-range indices (PUC: lua_tolstringx →
/// NULL; callers like the lua_tostring macro rely on the NULL check).
pub export fn lua_tolstring(L: ?*lua_State, idx: c_int, len: ?*usize) ?[*:0]const u8 {
    var s = api.State.fromHandle(L orelse {
        if (len) |p| p.* = 0;
        return null;
    });
    // PUC lua_tolstring on a number allocates (luaS_new) — OOM is
    // LUA_ERRMEM, not a silent NULL (P16.50-review-5 B2).
    if (s.tolstring(idx) catch |e| cThrowOn(s.vm, L.?, e)) |bytes| {
        // luazig's LuaString storage is NUL-terminated (createLuaString writes
        // body[raw.len] = 0), so the byte slice can be safely cast to [*:0].
        if (len) |p| p.* = bytes.len;
        return @ptrCast(@constCast(bytes.ptr));
    }
    if (len) |p| p.* = 0;
    return null;
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
    var s = api.State.fromHandle(L orelse return 0);
    return @intCast(s.rawlen(idx));
}

/// PUC `lua_tocfunction` (lapi.c:lua_tocfunction): return C function pointer.
pub export fn lua_tocfunction(L: ?*lua_State, idx: c_int) ?*const fn (?*lua_State) callconv(.c) c_int {
    var s = api.State.fromHandle(L orelse return null);
    return s.tocfunction(idx);
}

/// PUC `lua_tothread` (lapi.c:lua_tothread): return Thread pointer.
pub export fn lua_tothread(L: ?*lua_State, idx: c_int) ?*lua_State {
    var s = api.State.fromHandle(L orelse return null);
    if (s.tothread(idx)) |th| {
        // Reverse-map the thread Value to its lua_State handle: handles are
        // set by lua_newthread (coroutines) and setupMainHandle (main
        // thread, P15.83k). For Lua-created coroutines (no handle yet) we
        // lazily create+cache one here: in PUC a thread IS a lua_State, so
        // lua_tothread returns a non-NULL lua_State* for EVERY thread
        // value. The lazy handle gives Lua-created coroutines the same
        // stable one-to-one Value↔lua_State mapping. The handle is cached
        // on the Thread (created at most once per thread) and its lifetime
        // is tied to the Thread's GC lifetime: gcFreeObject(.thread) frees
        // it via Thread.api_handle. P16.50-review-5 B2: PUC cannot fail
        // here (a thread IS a lua_State); our handle allocation OOM is
        // LUA_ERRMEM (the old `catch return null` silently reported "not
        // a thread" for a real thread value).
        if (th.api_handle) |h| return h;
        const vm = s.vm;
        const h = vm.allocStateHandle(false) catch |e| cThrowOn(vm, L.?, e);
        h.* = .{ .vm = vm, .thread = th, .is_main = false };
        th.api_handle = h;
        return h;
    }
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
    // P16.50-review-4 BLOCKER 3: PUC lua_createtable THROWS LUA_ERRMEM on
    // allocation failure (lapi.c — luaC_newobj → luaM_error); the old
    // `catch {}` silently succeeded with no table on the stack.
    _ = narr;
    _ = nrec;
    var s = api.State.fromHandle(L orelse return);
    s.newtable() catch |e| cThrowOn(s.vm, L.?, e);
}

pub export fn lua_setglobal(L: ?*lua_State, name: [*:0]const u8) void {
    var s = api.State.fromHandle(L orelse return);
    s.setglobal(std.mem.span(name)) catch |e| switch (e) {
        // PUC lua_setglobal → luaH_set on the globals table: OOM (fresh
        // key intern / table growth) is LUA_ERRMEM. Type/InvalidState are
        // PUC api_check preconditions — lenient.
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
}

pub export fn lua_getglobal(L: ?*lua_State, name: [*:0]const u8) c_int {
    var s = api.State.fromHandle(L orelse return -1);
    // Only the result push can fail (OOM → LUA_ERRMEM; PUC api_incr_top).
    return typeCode(s.getglobal(std.mem.span(name)) catch |e| cThrowOn(s.vm, L.?, e));
}

pub export fn lua_setfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) void {
    var s = api.State.fromHandle(L orelse return);
    s.setfield(idx, std.mem.span(k)) catch |e| switch (e) {
        // OOM (key intern / table growth) and Runtime (non-table target →
        // luaG_typeerror) are real PUC throws; Type/InvalidIndex/
        // InvalidState are PUC api_check preconditions — lenient.
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
}

pub export fn lua_getfield(L: ?*lua_State, idx: c_int, k: [*:0]const u8) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    const t = s.getfield(idx, std.mem.span(k)) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => return 0,
    };
    return typeCode(t);
}

pub export fn lua_rawset(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.rawset(idx) catch |e| switch (e) {
        // PUC lua_rawset → luaH_rawset: OOM (table growth) throws ERRMEM;
        // non-table target is a PUC api_check (lenient here).
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
}

pub export fn lua_rawget(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    const t = s.rawget(idx) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => return 0,
    };
    return typeCode(t);
}

/// PUC `lua_gettable` (lapi.c): `t[k]` with metamethods. Pops the key,
/// pushes the value. Returns the value's type code.
pub export fn lua_gettable(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    const t = s.gettable(idx) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => return 0,
    };
    return typeCode(t);
}

/// PUC `lua_settable` (lapi.c): `t[k] = v` with metamethods. Pops both
/// key and value.
pub export fn lua_settable(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.settable(idx) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
}

/// PUC `lua_geti` (lapi.c): `t[n]` with metamethods. Pushes the value.
/// Returns the value's type code.
pub export fn lua_geti(L: ?*lua_State, idx: c_int, n: i64) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    const t = s.geti(idx, n) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => return 0,
    };
    return typeCode(t);
}

/// PUC `lua_seti` (lapi.c): `t[n] = v` with metamethods. Pops the value.
pub export fn lua_seti(L: ?*lua_State, idx: c_int, n: i64) void {
    var s = api.State.fromHandle(L orelse return);
    s.seti(idx, n) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
}

/// PUC `lua_rawgeti` (lapi.c): `t[n]` without metamethods. Pushes the
/// value. Returns the value's type code.
pub export fn lua_rawgeti(L: ?*lua_State, idx: c_int, n: i64) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    const t = s.rawgeti(idx, n) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => return 0,
    };
    return typeCode(t);
}

/// PUC `lua_rawseti` (lapi.c): `t[n] = v` without metamethods. Pops the
/// value.
pub export fn lua_rawseti(L: ?*lua_State, idx: c_int, n: i64) void {
    var s = api.State.fromHandle(L orelse return);
    s.rawseti(idx, n) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
}

/// PUC `lua_rawgetp` (lapi.c): `t[p]` without metamethods, where `p` is a
/// light userdata key. Pushes the value. Returns the value's type code.
pub export fn lua_rawgetp(L: ?*lua_State, idx: c_int, p: ?*anyopaque) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    const t = s.rawgetp(idx, p) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => return 0,
    };
    return typeCode(t);
}

/// PUC `lua_rawsetp` (lapi.c): `t[p] = v` without metamethods, where `p`
/// is a light userdata key. Pops the value.
pub export fn lua_rawsetp(L: ?*lua_State, idx: c_int, p: ?*anyopaque) void {
    var s = api.State.fromHandle(L orelse return);
    s.rawsetp(idx, p) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
}

pub export fn lua_next(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    const t = s.next(idx) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => return 0,
    };
    return if (t) 1 else 0;
}

// --- Arithmetic / comparison / length (PUC lapi.c) ---

/// PUC `lua_arith` (lapi.c:lua_arith): perform an arithmetic operation on
/// the top 1–2 stack values. For binary ops: operands at -2 and -1. For
/// unary ops (UNM, BNOT): operand at -1. Pops operands, pushes result.
pub export fn lua_arith(L: ?*lua_State, op: c_int) void {
    var s = api.State.fromHandle(L orelse return);
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
    s.arith(arith_op) catch |e| switch (e) {
        // PUC lua_arith → luaT_trybinTM: OOM and Runtime (luaG_opint /
        // __add error) throw; Type/InvalidState are api_check — lenient.
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
}

/// PUC `lua_rawequal` (lapi.c:lua_rawequal): raw equality (no __eq
/// metamethod). Returns 1 if equal, 0 otherwise.
pub export fn lua_rawequal(L: ?*lua_State, idx1: c_int, idx2: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    return if (s.rawequal(idx1, idx2)) 1 else 0;
}

/// PUC `lua_compare` (lapi.c:lua_compare): comparison with metamethods.
/// op is LUA_OPEQ (0), LUA_OPLT (1), or LUA_OPLE (2). Returns 1 if the
/// comparison holds, 0 otherwise.
pub export fn lua_compare(L: ?*lua_State, idx1: c_int, idx2: c_int, op: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    const cmp_op: api.CompareOp = switch (op) {
        0 => .eq,
        1 => .lt,
        2 => .le,
        else => return 0,
    };
    return if (s.compare(idx1, idx2, cmp_op) catch |e| switch (e) {
        // PUC lua_compare: OOM and Runtime (luaG_ordererror / __lt
        // metamethod error) throw; Type/InvalidIndex are api_check —
        // lenient false.
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => false,
    }) 1 else 0;
}

/// PUC `lua_concat` (lapi.c:lua_concat): concatenate n values from the
/// top of the stack. Pops all n values, pushes the result string.
pub export fn lua_concat(L: ?*lua_State, n: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    if (n <= 0) return;
    s.concat(@intCast(n)) catch |e| switch (e) {
        // PUC lua_concat → luaV_concat: OOM (string build) and Runtime
        // (luaG_concaterror / __concat error) throw; Type/InvalidIndex
        // are api_check — lenient.
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
}

/// PUC `lua_len` (lapi.c:lua_len): push the length of the value at idx.
/// For strings: byte length. For tables: border length (or __len). Pops
/// nothing, pushes the length value.
pub export fn lua_len(L: ?*lua_State, idx: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.len(idx) catch |e| switch (e) {
        // PUC lua_len → luaV_objlen: OOM and Runtime (luaG_typeerror /
        // __len error) throw; Type/InvalidIndex are api_check — lenient.
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
}

// --- Coroutines (PUC lapi.c / ldo.c) ---

/// PUC `lua_resume` (ldo.c:lua_resume): resume a coroutine. `from` is the
/// calling thread; its C-call depth is inherited so that C-call nesting limits
/// are enforced across coroutine boundaries (PUC: `L->nCcalls = getCcalls(from) + 1`).
/// nargs values are on the coroutine's stack. Writes the number of results
/// to *nres. Returns LUA_OK on completion, LUA_YIELD on yield, or an error
/// code.
pub export fn lua_resume(L: ?*lua_State, from: ?*lua_State, nargs: c_int, nres: ?*c_int) c_int {
    const h = L orelse return 2;
    const vm = h.vm;
    _ = from; // P16.26 A5: depth inheritance lives in resumeEnterC (shared)
    // P15.83k: resolve the thread directly from the handle. Every handle
    // carries its Thread (coroutine handles from lua_newthread, the main
    // handle from setupMainHandle). Resuming the main state resolves the
    // main thread, which builtinCoroutineResume rejects with PUC's
    // "cannot resume non-suspended coroutine" while it is running — the
    // previous fallback (c_api_thread orelse current_thread) silently
    // resumed an unrelated thread instead (stale lua_State==Vm assumption).
    const co = h.thread orelse return 2;
    // DON'T set vm.current_thread here — builtinCoroutineResume saves/restores
    // current_thread internally. Setting it here would cause the defer in
    // builtinCoroutineResume to restore co's status to its pre-resume value,
    // overwriting the .suspended status set by the yield path.
    // P16.26 A5: resume-entry C-depth ownership is UNIFIED — the manual
    // nCcalls write here is removed; the shared resumeEnterC (reached via
    // builtinCoroutineResume in apiResumeThread) is the single writer of
    // inherited depth, the LUAI_MAXCCALLS entry check, and the one resume
    // unit (PUC lua_resume).
    // Base index in c_stack for truncating after resume (function position on
    // first resume, or args position on subsequent resumes).
    var lua_resume_base: usize = 0;
    // P15.82b: On first resume (co.started == false), the function is on
    // c_stack at position len-nargs-1, followed by nargs arguments.
    // On subsequent resumes (co.started == true, status == suspended),
    // the function was already consumed; c_stack top has only the resume
    // arguments (nargs values). This mirrors PUC's `resume()` which uses
    // `L->ci->func` (already set) and reads nargs from `L->top`.
    const nargs_usize: usize = @intCast(@max(nargs, 0));
    const args: []vm_mod.Value = blk: {
        if (!co.started and co.callee == .Nil) {
            // First resume: function + args on c_stack.
            if (h.c_stack.items.len < nargs_usize + 1) return 2;
            const fi = h.c_stack.items.len - nargs_usize - 1;
            co.callee = h.c_stack.items[fi];
            // P15.83j: remember the function position (PUC ci->func). Every
            // later resume truncates back to it before pushing results, so
            // stale yielded values never remain under the new results.
            h.resume_func_base = fi;
            break :blk h.c_stack.items[fi + 1 ..];
        } else {
            // Subsequent resume: args sit on top of the stack (above any
            // stale values left by the previous yield). PUC `resume()` reads
            // `firstArg = L->top - n` the same way; results are later moved
            // down to ci->func + 1 by luaD_poscall. Use the remembered
            // func base as the truncation target (PUC ci->func).
            if (h.c_stack.items.len < nargs_usize) return 2;
            lua_resume_base = h.resume_func_base orelse (h.c_stack.items.len - nargs_usize);
            break :blk h.c_stack.items[h.c_stack.items.len - nargs_usize ..];
        }
    };
    // Switch cur_handle and cur_c_stack to the coroutine's handle so that
    // C functions called during the coroutine's execution see the coroutine's
    // handle as their L parameter and operate on the coroutine's c_stack.
    // This mirrors PUC Lua where lua_resume operates on the coroutine's L,
    // and C functions called within the coroutine use that same L.
    const saved_cur_handle = vm.cur_handle;
    const saved_cur_c_stack = vm.cur_c_stack;
    vm.cur_handle = h;
    vm.cur_c_stack = &h.c_stack;
    defer {
        vm.cur_handle = saved_cur_handle;
        vm.cur_c_stack = saved_cur_c_stack;
    }

    // P16.50-review-7 BLOCKER 4: apiResumeThread returns the resume's
    // EXACT tuple ([ok] ++ values) as an owned slice — the old 64-slot
    // window truncated every C-API resume to 63 results (PUC lua_resume
    // returns ALL results on the stack). Freed via vm.alloc.free (the
    // charged-block registry passes infraAlloc'd blocks through).
    // P15.83q: pre-call status snapshot. A thread that is already dead
    // can only produce PUC's `resume_error` boundary ("cannot resume
    // dead coroutine", ldo.c:895-903 + 970): the pushed args are popped,
    // the message is APPENDED to the existing stack window, and
    // *nresults is left UNTOUCHED (resume_error returns before
    // lua_resume's *nresults assignment). This is structurally distinct
    // from an error raised inside the coroutine, which flows through
    // luaD_seterrorobj (the [err, err] duplicated window below).
    const dead_before_call = co.status == .dead;
    const res = vm.apiResumeThread(co, args) catch {
        // Error path (PUC ldo.c:983-988): `L->status = status`, then
        // luaD_seterrorobj(L, status, L->top) and `L->ci->top = L->top`.
        // luaD_seterrorobj (ldo.c:112-122) COPIES the top-1 error object
        // to oldtop == L->top — i.e. it DUPLICATES the error object on
        // top of the stack residue — leaving [.., err, err].
        // `*nresults = top - (ci->func + 1)` with ci = the innermost
        // CallInfo at throw time. For errors surfacing from a C-function
        // frame (error(), assert(), metamethod failures, ...) the
        // innermost frame is that C call's frame, so the visible window
        // is exactly the duplicated pair: [err, err], nres == 2 (verified
        // against PUC 5.5.0 with /tmp probes: plain, deeper-Lua-call,
        // table error object, and pcall-recovered-then-error variants).
        // Known divergence (documented in STATUS.md P15.83q): errors
        // raised from a LUA frame via luaG_runerror (index/call nil, ...)
        // keep the frame's register + varinfo residue in PUC's window;
        // luazig's message building does not use the Lua-visible stack,
        // so it exposes the [err, err] pair only.
        h.c_stack.items.len = lua_resume_base;
        // P16.36 Cut 1b: the error was raised inside the resumed thread
        // and — with per-thread error state — STAYS there (the old
        // Vm-global was restored to the caller's pre-resume state by
        // builtinCoroutineResume's bundle defer, relying on latches;
        // the raising thread is now the direct, by-construction owner).
        const ev: vm_mod.Value = if (co.err_has_obj) co.err_obj else .Nil;
        // (b) status-returning API: the status below (co.api_status — 4 for
        // OOM since B1) is returned regardless; PUC's seterrorobj builds
        // the [err, err] window within one stack (infallible), our appends
        // can OOM — the window is lost, the status is not.
        h.c_stack.append(vm.alloc, ev) catch {};
        h.c_stack.append(vm.alloc, ev) catch {};
        if (nres) |p|
            p.* = @intCast(if (h.c_stack.items.len > lua_resume_base)
                h.c_stack.items.len - lua_resume_base
            else
                0);
        // PUC: the status flows from the resumed thread's own status
        // (set by the catching boundary — L->status = status in
        // ldo.c:983-988): LUA_ERRMEM (4) for OOM (P16.50-review-5 B1 —
        // the old unconditional 2/5 mapping discarded the OutOfMemory
        // kind finishCcall carried), ERRERR (5), ERRRUN (2).
        return if (co.api_status != 0) co.api_status else if (co.err_is_errerr) 5 else 2;
    };
    defer vm.alloc.free(res);
    const failed = res.len > 0 and !(res[0] == .Bool and res[0].Bool);
    if (failed) {
        if (dead_before_call) {
            // PUC resume_error (ldo.c:895-903): pop the pushed args,
            // append the message to the existing window, leave *nresults
            // untouched. The engine's only failure for an already-dead
            // thread is "cannot resume dead coroutine".
            h.c_stack.items.len -= @min(nargs_usize, h.c_stack.items.len);
            // (b): same window-append contract as the error path above.
            h.c_stack.append(vm.alloc, res[1]) catch {};
            return 2;
        }
        // Real error inside the coroutine: PUC error window (luaD_seterrorobj
        // duplicates the top-1 error object) = [residue?, err, err], where
        // `residue` is the value the raising C function left below the error
        // object on its frame — error()/assert() with a string message and
        // level >= 1 leave the ORIGINAL unprefixed string there (PUC
        // lbaselib luaB_error pushes where + a copy of the argument, then
        // concatenates). builtinCoroutineResume snapshots it onto the thread
        // as api_err_residue. nres = window size.
        h.c_stack.items.len = lua_resume_base;
        // (b): the [residue?, err, err] window appends — status (below)
        // survives an append OOM; only the observable window is lost.
        if (co.api_err_residue) |r| h.c_stack.append(vm.alloc, r) catch {};
        h.c_stack.append(vm.alloc, res[1]) catch {};
        h.c_stack.append(vm.alloc, res[1]) catch {};
        if (nres) |p|
            p.* = @intCast(if (h.c_stack.items.len > lua_resume_base)
                h.c_stack.items.len - lua_resume_base
            else
                0);
        // PUC APIstatus: the thread's own status (mirrored by
        // builtinCoroutineResume's error tail — ERRMEM=4 included since
        // P16.50-review-5 B1), ERRERR (5), else ERRRUN (2).
        return if (co.api_status != 0) co.api_status else 2;
    }
    // Success or yield: replace function+args with results on c_stack.
    h.c_stack.items.len = lua_resume_base;
    h.c_stack.appendSlice(vm.alloc, res[1..]) catch {
        // PUC luaD_poscall moves results within ONE stack (infallible);
        // our append can OOM — report LUA_ERRMEM with the fixed MEMERRMSG
        // object installed instead of silently reporting LUA_OK with
        // missing results (P16.50-review-5 B2).
        vm.setOutOfMemoryError();
        if (nres) |p| p.* = 0;
        return 4;
    };
    if (nres) |p| p.* = @intCast(res.len - 1);
    // Return LUA_YIELD (1) if suspended, LUA_OK (0) if done.
    const st_result: c_int = if (co.status == .suspended) 1 else 0;
    if (st_result == 1) {
        // Hook-yield visibility (P15.83q): a suspension caused by a debug
        // hook yielding reports *nresults = nyield = 0, but PUC's one-stack
        // model still exposes the suspended Lua frame's ENTIRE register
        // window (luaG_traceexec raised L->top to ci->top before the hook,
        // ldebug.c:954, and the yield longjmp skips luaD_hook's restore).
        // Materialize the register window onto the handle stack above the
        // (empty) results. The values are a snapshot-copy: PUC would show
        // the live registers, but between suspends nothing can observe
        // mutations, and the next resume truncates to lua_resume_base
        // before pushing results, so stale window values can never leak
        // into a later resume's results or be mistaken for its arguments
        // (args are read from the top; the window sits below them).
        if (vm.apiHookYieldWindow(co)) |window|
            // (b): diagnostic-only visibility window (the yield itself is
            // already reported); an append OOM loses just the window.
            h.c_stack.appendSlice(vm.alloc, window) catch {};
    }
    return st_result;
}

/// PUC `lua_yieldk` (ldo.c:1006-1034): yield from a coroutine.
/// nresults values on c_stack are returned to the resume caller.
/// k/ctx are saved in the current C-frame's u.c union for continuation
/// on resume (finishCcall invokes k from the next lua_resume).
///
/// P15.78: In PUC Lua, `lua_yieldk` does a `longjmp` to the `lua_resume`
/// boundary, unwinding the C stack. luazig mirrors this: after storing the
/// yielded values and saving k/ctx, we `_longjmp` to the `c_error_jmp`
/// boundary set up by `callCFunctionWithBoundary` (with value 2 to distinguish
/// yield from error). This unwinds the C function's stack frame, and
/// `callCFunction` catches the yield (return value -2) and propagates
/// `error.Yield` up through the Zig call stack to `driveBytecodeCoroutineTrampoline`.
pub export fn lua_yieldk(L: ?*lua_State, nresults: c_int, ctx: isize, k: ?*const anyopaque) c_int {
    const h = L orelse return 2;
    const vm = h.vm;

    // Read the yielded values from c_stack (PUC: api_checkpop + L->top - nresults).
    const nresults_usize: usize = @intCast(@max(nresults, 0));
    if (nresults_usize > h.c_stack.items.len) return 2;
    const base = h.c_stack.items.len - nresults_usize;

    // Delegate nyield + k/ctx saving + apiYield to the shared helper
    // (PUC ldo.c:1019-1029). The helper saves nyield on the top C-frame,
    // saves k/ctx (unless a debug hook), and calls apiYield which calls
    // builtinCoroutineYield. On success, apiYield returns error.Yield.
    const th = vm.current_thread orelse {
        // No thread — can't yield. Match PUC: luaG_runerror.
        return 2;
    };
    const kfn: ?*const fn (?*vm_mod.lua_State, c_int, isize) callconv(.c) c_int = if (k) |kf|
        @ptrCast(@alignCast(kf))
    else
        null;

    vm.luaYieldKShared(th, h.c_stack.items[base..], nresults, kfn, ctx) catch |err| switch (err) {
        // Yield succeeded: builtinCoroutineYield stored the values in
        // th.yielded and returned error.Yield. Now longjmp to the
        // callCFunctionWithBoundary setjmp point (value 2 = yield).
        error.Yield => {
            if (vm.c_error_jmp) |jb| {
                _longjmp(jb, 2);
            }
            return 2;
        },
        // Non-yieldable (incnny set by lua_call with k==NULL): the yield
        // was rejected. PUC lua_yieldk calls luaD_throw(L, LUA_ERRRUN).
        error.RuntimeError => {
            if (vm.c_error_jmp) |jb| {
                _longjmp(jb, 1);
            }
            return 2;
        },
        // (b) status-returning: LUA_ERRMEM is lua_yieldk's specified OOM
        // status. Install the FIXED MEMERRMSG object first so the error
        // state is observable (allocation-free — oom_msg_str is interned
        // once at Vm init), exactly like the results-append arms in
        // lua_resume/lua_pcallk (P16.50-review-5 B2).
        error.OutOfMemory => {
            vm.setOutOfMemoryError();
            return 4;
        },
    };
    return 1; // LUA_YIELD — shouldn't happen
}

/// PUC `lua_status` (lapi.c:lua_status): return the status of thread L.
/// Returns LUA_OK (0) for the main thread, or the thread's status code
/// (LUA_OK=0, LUA_YIELD=1, LUA_ERRRUN=2, LUA_ERRMEM=4, LUA_ERRERR=5).
///
/// PUC reads `L->status` directly. luazig stores the status code in
/// `Thread.api_status` (mirroring PUC's `L->status`), updated at every
/// lifecycle transition. The thread is resolved from the handle: if the
/// handle has a thread (coroutine), read its `api_status`; otherwise the
/// handle is the main thread, whose status is always LUA_OK.
pub export fn lua_status(L: ?*lua_State) c_int {
    const h = L orelse return 2;
    // PUC: main thread status is always LUA_OK (errors in the main thread
    // either longjmp to a pcall boundary or abort the process). The main
    // handle's .thread is the main Thread (P15.83k), whose api_status tracks
    // coroutine lifecycle transitions it never takes — is_main pins LUA_OK.
    if (h.is_main) return 0; // LUA_OK
    const th = h.thread orelse return 0;
    return th.api_status;
}

/// PUC `lua_pushthread` (lapi.c:lua_pushthread): push the current thread
/// onto the stack as a thread Value. Returns 1 if L is the main thread,
/// 0 otherwise (PUC: `return cast_int(L == mainthread(G(L)))`).
/// P15.83k: every handle carries its Thread (coroutines from lua_newthread,
/// the main handle from setupMainHandle), so the pushed value is a real
/// thread Value and lua_tothread on it returns this exact handle.
pub export fn lua_pushthread(L: ?*lua_State) c_int {
    const h = L orelse return 0;
    const th = h.thread orelse return 0;
    // PUC api_incr_top: OOM is LUA_ERRMEM (P16.50-review-5 B2 — the old
    // `catch return 0` misreported "not the main thread" and pushed
    // nothing).
    h.c_stack.append(h.vm.alloc, .{ .Thread = th }) catch |e| cThrowOn(h.vm, h, e);
    return if (h.is_main) 1 else 0;
}

// --- Garbage collection (PUC lapi.c:lua_gc) ---

/// PUC `lua_gc` is variadic: `int lua_gc(lua_State *L, int what, ...)`.
/// For LUA_GCPARAM, it takes two varargs (param, value); for LUA_GCSTEP,
/// one vararg (size_t n); for all others, one vararg (int data).
/// We expose two fixed-arg Zig functions and provide a C variadic shim
/// (`src/lua/lua_gc_shim.c`) that dispatches to them. This avoids Zig's
/// lack of C variadic export support while maintaining ABI compatibility.
///
/// `luazigGcFixed` handles all non-GCPARAM options. For LUA_GCSTEP, `data`
/// carries the step size (PUC's vararg `size_t n`).
pub export fn luazigGcFixed(L: ?*lua_State, what: c_int, data: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    return s.vm.gcControl(what, data, -1);
}

/// `luazigGcParam` handles LUA_GCPARAM: `param` is the LUA_GCP* index,
/// `value` is the new value (or -1 for getter-only).
pub export fn luazigGcParam(L: ?*lua_State, param: c_int, value: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    return s.vm.gcControl(9, param, value); // LUA_GCPARAM = 9
}

// --- Call / pcall ---

/// PUC `lua_pcallk` (lapi.c:1076-1117): protected call with continuation.
///
/// If k == NULL or not yieldable: conventional pcall (setjmp/longjmp
/// boundary). If errfunc != 0, the error handler is pushed onto bc_stack
/// via `setErrfuncValue` for the duration of the call so `invokeErrfunc`
/// can find it, then restored afterwards.
///
/// If k != NULL and yieldable: save k/ctx/funcidx/old_errfunc in the
/// current C-frame, set CIST_YPCALL, save allowhook via CIST_OAH, then
/// call the callee. On normal return or error, clear CIST_YPCALL and
/// restore errfunc. The saved k/ctx/funcidx/old_errfunc are NOT YET USED
/// on resume — that's Tasks 11-12 (finishCcall/finishpcallk).
pub export fn lua_pcallk(
    L: ?*lua_State,
    nargs: c_int,
    nresults: c_int,
    errfunc: c_int,
    ctx: isize,
    k: ?*const anyopaque,
) c_int {
    const h = L orelse return 2;
    const vm = h.vm;

    // PUC lapi.c:1082-1083: api_check(k == NULL || !isLua(L->ci),
    // "cannot use continuations inside hooks") runs BEFORE the yieldable
    // branch — k != NULL inside a hook is a violation even on a
    // non-yieldable thread, where the conventional-pcall path below would
    // never reach luaPcallKShared's own check. Placed before the
    // current_thread fallback so a C hook on the MAIN state
    // (current_thread == null there; the hook flag lives on
    // main_thread.debug_hook) is checked too. Enforcement model: same as
    // the shared helpers — deterministic runtime error, converted here to
    // the C boundary via _longjmp (PUC aborts via lua_assert only in
    // apicheck builds).
    if (vm.current_thread orelse vm.main_thread) |th_check| {
        vm.apiCheckHookContinuationInvariant(th_check, k != null, false, 0) catch {
            if (vm.c_error_jmp) |jb| {
                vm.c_error_value = vm.errThread().err_obj;
                _longjmp(jb, 1);
            }
            return if (vm.errThread().err_is_errerr) 5 else 2;
        };
    }

    const th = vm.current_thread orelse {
        // No thread — conventional pcall without errfunc.
        // P15.78: Even on the main thread (no current_thread), errfunc must
        // be honored. PUC lapi.c: lua_pcallk always sets L->errfunc = func
        // before calling luaD_call, regardless of thread state.
        if (errfunc != 0) {
            const abs = api.normalizeIndex(errfunc, h.c_stack.items.len) orelse return 2;
            const errfunc_val = h.c_stack.items[abs];
            vm.setErrfuncValue(errfunc_val);
            defer vm.setErrfuncValue(null);
            var s = api.State.fromHandle(h);
            return statusCode(s.pcall(@intCast(@max(nargs, 0)), nresults));
        }
        var s = api.State.fromHandle(h);
        return statusCode(s.pcall(@intCast(@max(nargs, 0)), nresults));
    };

    if (k == null or !th.yieldable()) {
        // ── Conventional pcall (setjmp/longjmp boundary) ──
        // PUC: if errfunc != 0, set L->errfunc = func for the duration.
        // In luazig, th.errfunc is a bc_stack index, so we push the errfunc
        // Value (read from c_stack by index) onto bc_stack via setErrfuncValue.
        if (errfunc != 0) {
            const abs = api.normalizeIndex(errfunc, h.c_stack.items.len) orelse return 2;
            const errfunc_val = h.c_stack.items[abs];
            const saved_errfunc = th.errfunc;
            vm.setErrfuncValue(errfunc_val);
            defer {
                // Pop the errfunc from bc_stack and restore the old index.
                vm.setErrfuncValue(null);
                th.errfunc = saved_errfunc;
            }
            var s = api.State.fromHandle(h);
            return statusCode(s.pcall(@intCast(@max(nargs, 0)), nresults));
        } else {
            var s = api.State.fromHandle(h);
            return statusCode(s.pcall(@intCast(@max(nargs, 0)), nresults));
        }
    }

    // ── Yieldable pcall: delegate to shared helper ──
    // PUC lua_pcallk yieldable path (lapi.c:1097-1117): save k/ctx/funcidx/
    // old_errfunc/OAH on L->ci, set CIST_YPCALL, call the callee. On normal
    // return, clear CIST_YPCALL + restore errfunc. On error/yield, C-frame
    // stays for precover.
    //
    // Read callee/args from c_stack and compute errfunc_val, then delegate
    // the production lifecycle (k/ctx/funcidx/old_errfunc/OAH/YPCALL saving
    // + apiCall + normal-return cleanup) to luaPcallKShared.
    const nargs_usize: usize = @intCast(@max(nargs, 0));
    if (h.c_stack.items.len < nargs_usize + 1) return 2;
    const fn_idx = h.c_stack.items.len - nargs_usize - 1;
    const callee = h.c_stack.items[fn_idx];
    const call_args = h.c_stack.items[fn_idx + 1 ..];
    const errfunc_val: ?Value = if (errfunc != 0) blk: {
        const abs = api.normalizeIndex(errfunc, h.c_stack.items.len) orelse return 2;
        break :blk h.c_stack.items[abs];
    } else null;

    const kfn: *const fn (?*vm_mod.lua_State, c_int, isize) callconv(.c) c_int =
        @ptrCast(@alignCast(k.?));

    const ret = vm.luaPcallKShared(th, callee, call_args, errfunc_val, fn_idx, kfn, ctx) catch |err| switch (err) {
        error.Yield => {
            // P15.78: Callee yielded. Longjmp with value 2 (yield) so
            // callCFunction can propagate error.Yield and leave the C-frame
            // (with CIST_YPCALL set) in place for finishCcall/finishpcallk
            // on resume.
            if (vm.c_error_jmp) |jb| {
                _longjmp(jb, 2);
            }
            // No C-function boundary — can't yield. Fallback cleanup.
            const fr2 = th.call_frames.getPtr(th.call_frames.len() - 1);
            fr2.clearYpcall();
            if (errfunc_val != null) {
                vm.setErrfuncValue(null);
            }
            th.errfunc = fr2.u.c.old_errfunc;
            return 2;
        },
        error.RuntimeError => {
            // PUC: lua_pcallk's yieldable path does NOT catch errors locally.
            // The C-frame (with CIST_YPCALL set) stays in place for precover.
            if (vm.c_error_jmp) |jb| {
                _longjmp(jb, 1);
            }
            // No C-function boundary — fallback cleanup.
            const fr2 = th.call_frames.getPtr(th.call_frames.len() - 1);
            fr2.clearYpcall();
            if (errfunc_val != null) {
                vm.setErrfuncValue(null);
            }
            th.errfunc = fr2.u.c.old_errfunc;
            return if (vm.errThread().err_is_errerr) 5 else 2;
        },
        error.OutOfMemory => {
            const fr2 = th.call_frames.getPtr(th.call_frames.len() - 1);
            fr2.clearYpcall();
            if (errfunc_val != null) {
                vm.setErrfuncValue(null);
            }
            th.errfunc = fr2.u.c.old_errfunc;
            // (b) status-returning: LUA_ERRMEM is the specified OOM status.
            // Install the FIXED MEMERRMSG object (allocation-free) so the
            // error state is observable — the raw `try` OOMs inside apiCall
            // do not install it themselves (P16.50-review-5 B2).
            vm.setOutOfMemoryError();
            return 4; // LUA_ERRMEM
        },
    };
    defer vm.alloc.free(ret);

    // Put results on c_stack
    h.c_stack.items.len = fn_idx;
    const want: usize = if (nresults < 0) ret.len else @min(ret.len, @as(usize, @intCast(nresults)));
    h.c_stack.appendSlice(vm.alloc, ret[0..want]) catch {
        // PUC moves results within one stack (infallible); our append can
        // OOM — install the fixed MEMERRMSG object so the error state is
        // observable, then return LUA_ERRMEM (P16.50-review-5 B2 — the old
        // bare `return 4` left no error object installed).
        vm.setOutOfMemoryError();
        return 4;
    };
    return 0; // LUA_OK
}

// --- Userdata ---

pub export fn lua_newuserdatauv(L: ?*lua_State, sz: usize, nuvalue: c_int) ?*anyopaque {
    var s = api.State.fromHandle(L orelse return null);
    // PUC lua_newuserdatauv → luaC_newobj → luaM_error: OOM is LUA_ERRMEM,
    // never a silent null (P16.50-review-5 B2).
    return s.newuserdatauv(sz, @intCast(@max(nuvalue, 0))) catch |e| cThrowOn(s.vm, L.?, e);
}

pub export fn lua_touserdata(L: ?*lua_State, idx: c_int) ?*anyopaque {
    var s = api.State.fromHandle(L orelse return null);
    return s.touserdata(idx);
}

pub export fn lua_topointer(L: ?*lua_State, idx: c_int) ?*anyopaque {
    var s = api.State.fromHandle(L orelse return null);
    return s.topointer(idx);
}

pub export fn lua_setmetatable(L: ?*lua_State, objindex: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC lua_setmetatable is allocation-free and cannot fail. Our
    // barrier/finalizer bookkeeping can OOM AFTER the observable
    // metatable write commits — throwing would not restore the missed
    // barrier, so the swallow is class (d) documented (P16.50-review-5
    // B2; the architectural fix is pre-reserved barrier lists). The
    // remaining Type/InvalidIndex/InvalidState errors are PUC api_check
    // preconditions — lenient 0.
    s.setmetatable(objindex) catch return 0;
    return 1;
}

pub export fn lua_getmetatable(L: ?*lua_State, objindex: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    return if (s.getmetatable(objindex) catch |e| switch (e) {
        // OOM (metatable-list growth) → LUA_ERRMEM; Type/InvalidIndex are
        // PUC api_check — lenient false (P16.50-review-5 B2).
        error.OutOfMemory => cThrowOn(s.vm, L.?, e),
        else => false,
    }) 1 else 0;
}

pub export fn lua_setiuservalue(L: ?*lua_State, idx: c_int, n: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // (c) infallible w.r.t. allocation: setiuservalue's error set is
    // InvalidState/InvalidIndex only (an in-place uservalue write) — the
    // catch is the lenient api_check answer for a bad index.
    return if (s.setiuservalue(idx, @intCast(@max(n, 0))) catch false) 1 else 0;
}

pub export fn lua_getiuservalue(L: ?*lua_State, idx: c_int, n: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    return typeCode(s.getiuservalue(idx, @intCast(@max(n, 0))) catch |e| switch (e) {
        // OOM (result push) → LUA_ERRMEM; Type/InvalidIndex are PUC
        // api_check — lenient LUA_TNONE-ish 0 (P16.50-review-5 B2).
        error.OutOfMemory => cThrowOn(s.vm, L.?, e),
        else => return 0,
    });
}

// --- lauxlib ---

pub export fn luaL_checklstring(L: ?*lua_State, arg: c_int, l: ?*usize) [*:0]const u8 {
    var s = api.State.fromHandle(L orelse {
        if (l) |p| p.* = 0;
        return "";
    });
    const bytes = s.checklstring(arg);
    if (l) |p| p.* = bytes.len;
    return @ptrCast(@constCast(bytes.ptr));
}

pub export fn luaL_setfuncs(L: ?*lua_State, reg: [*]const luaL_Reg, nup: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.registerfuncs(reg, @intCast(@max(nup, 0))) catch |e| cThrowOn(s.vm, L.?, e);
}

pub export fn luaL_newlib(L: ?*lua_State, reg: [*]const luaL_Reg) void {
    var s = api.State.fromHandle(L orelse return);
    s.newlib(reg) catch |e| cThrowOn(s.vm, L.?, e);
}

pub export fn luaL_ref(L: ?*lua_State, t: c_int) c_int {
    var s = api.State.fromHandle(L orelse return LUA_NOREF);
    return s.ref(t);
}

pub export fn luaL_unref(L: ?*lua_State, t: c_int, ref: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.unref(t, ref);
}

pub export fn luaL_newmetatable(L: ?*lua_State, tname: [*:0]const u8) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC luaL_newmetatable: lua_createtable + lua_setfield — OOM is
    // LUA_ERRMEM, never a silent false (P16.50-review-5 B2).
    return if (s.newmetatable(std.mem.span(tname)) catch |e| cThrowOn(s.vm, L.?, e)) 1 else 0;
}

pub export fn luaL_getmetatable(L: ?*lua_State, tname: [*:0]const u8) void {
    var s = api.State.fromHandle(L orelse return);
    // PUC luaL_getmetatable: lua_getfield on the registry — OOM is
    // LUA_ERRMEM (the old swallow pushed NOTHING, corrupting the stack
    // shape; P16.50-review-5 B2).
    s.getRegisteredMetatable(std.mem.span(tname)) catch |e| cThrowOn(s.vm, L.?, e);
}

pub export fn luaL_setmetatable(L: ?*lua_State, tname: [*:0]const u8) void {
    var s = api.State.fromHandle(L orelse return);
    s.setRegisteredMetatable(std.mem.span(tname)) catch |e| switch (e) {
        // getRegisteredMetatable OOM → LUA_ERRMEM; the trailing
        // setmetatable's post-commit bookkeeping failures are class (d)
        // documented (see lua_setmetatable).
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
}

pub export fn luaL_testudata(L: ?*lua_State, ud: c_int, tname: [*:0]const u8) ?*anyopaque {
    var s = api.State.fromHandle(L orelse return null);
    return s.testudata(ud, std.mem.span(tname));
}

pub export fn luaL_checkudata(L: ?*lua_State, ud: c_int, tname: [*:0]const u8) ?*anyopaque {
    if (luaL_testudata(L, ud, tname)) |p| return p;
    lua_pushstring(L, "bad argument: wrong userdata type");
    lua_error(L);
}

pub export fn luaL_checkinteger(L: ?*lua_State, arg: c_int) i64 {
    var s = api.State.fromHandle(L orelse return 0);
    return s.checkinteger(arg) catch {
        lua_pushstring(L, "bad argument: integer expected");
        lua_error(L);
    };
}

pub export fn luaL_optinteger(L: ?*lua_State, arg: c_int, def: i64) i64 {
    var s = api.State.fromHandle(L orelse return def);
    // (c) infallible: optinteger's every path returns a value (absent or
    // nil → def; the catch only guards the typed error union).
    return s.optinteger(arg, def) catch def;
}

// ===========================================================================
// Phase 5: lauxlib argument checking, error reporting, utilities
// ===========================================================================

pub export fn luaL_checktype(L: ?*lua_State, arg: c_int, t: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    const actual = if (s.typeOf(arg)) |ty| typeCode(ty) else @as(c_int, -1);
    if (actual != t) {
        _ = lua_pushfstring(L, "bad argument #%d (%s expected, got %s)", arg, lua_typename(L, t), lua_typename(L, actual));
        lua_error(L);
    }
}

pub export fn luaL_checkany(L: ?*lua_State, arg: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    if (s.typeOf(arg) == null) {
        _ = lua_pushfstring(L, "bad argument #%d (value expected)", arg);
        lua_error(L);
    }
}

pub export fn luaL_checkstack(L: ?*lua_State, sz: c_int, msg: ?[*:0]const u8) void {
    const h = L orelse return;
    const vm = h.vm;
    h.c_stack.ensureUnusedCapacity(vm.alloc, @intCast(@max(sz, 0))) catch {
        lua_pushstring(L, if (msg) |m| m else "stack overflow");
        lua_error(L);
    };
}

pub export fn luaL_checknumber(L: ?*lua_State, arg: c_int) f64 {
    var s = api.State.fromHandle(L orelse return 0);
    if (s.tonumber(arg)) |n| return n;
    const ty = if (s.typeOf(arg)) |t| typeCode(t) else @as(c_int, -1);
    _ = lua_pushfstring(L, "bad argument #%d (number expected, got %s)", arg, lua_typename(L, ty));
    lua_error(L);
}

pub export fn luaL_optnumber(L: ?*lua_State, arg: c_int, def: f64) f64 {
    var s = api.State.fromHandle(L orelse return def);
    const ty = s.typeOf(arg);
    if (ty == null or ty.? == .nil) return def;
    if (s.tonumber(arg)) |n| return n;
    return def;
}

pub export fn luaL_optlstring(L: ?*lua_State, arg: c_int, def: ?[*:0]const u8, l: ?*usize) [*:0]const u8 {
    var s = api.State.fromHandle(L orelse {
        if (l) |p| {
            if (def) |d| {
                p.* = std.mem.len(d);
            } else {
                p.* = 0;
            }
        }
        return def orelse "";
    });
    const ty = s.typeOf(arg);
    if (ty == null or ty.? == .nil) {
        if (l) |p| {
            if (def) |d| {
                p.* = std.mem.len(d);
            } else {
                p.* = 0;
            }
        }
        return def orelse "";
    }
    const bytes = s.checklstring(arg);
    if (l) |p| p.* = bytes.len;
    return @ptrCast(@constCast(bytes.ptr));
}

pub export fn luaL_checkoption(L: ?*lua_State, arg: c_int, def: ?[*:0]const u8, lst: [*]const ?[*:0]const u8) c_int {
    var s = api.State.fromHandle(L orelse return -1);
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
/// level 1 = the Lua caller. P16.41 Cut 1 made builtin/C CallFrames real
/// and visible, so luazig levels now match PUC exactly and internal
/// callers (`luaL_argerror`, `luaL_error`) use PUC's `luaL_where(L, 1)`.
pub export fn luaL_where(L: ?*lua_State, lvl: c_int) void {
    const h = L orelse return;
    const vm = h.vm;
    var ar: lua_Debug = .{};
    if (lua_getstack(L, lvl, &ar) != 0) {
        _ = lua_getinfo(L, "Sl", &ar);
        if (ar.currentline > 0) {
            // PUC luaL_where uses ar.short_src — the chunkid form
            // (luaO_chunkid: `[string "..."]` for string sources, the
            // trimmed file path for file sources). Using the raw source
            // leaks the full string chunk text into error prefixes
            // (p31d S3/S4: `return function() ... end:1:` instead of
            // `[string "return function() ... end"]:1:`).
            const src: []const u8 = blk: {
                const s = std.mem.sliceTo(&ar.short_src, 0);
                break :blk if (s.len > 0) s else "?";
            };
            var buf: [128]u8 = undefined;
            // Bounded inputs (short_src ≤ 60 bytes, currentline ≤ 11
            // digits) — bufPrint cannot fail; PUC has no failure mode
            // here either (lua_pushfstring on a fixed-size chunkid).
            const formatted = std.fmt.bufPrint(&buf, "{s}:{d}: ", .{ src, ar.currentline }) catch unreachable;
            // PUC lua_pushfstring: OOM is LUA_ERRMEM (P16.50-review-5 B2
            // — the old `catch return` silently pushed nothing).
            const ls = vm.internStr(formatted) catch |e| cThrowOn(vm, h, e);
            h.c_stack.append(vm.alloc, .{ .String = ls }) catch |e| cThrowOn(vm, h, e);
            return;
        }
    }
    // Fallback: empty string (PUC pushes "" when no info is available)
    const ls = vm.internStr("") catch |e| cThrowOn(vm, h, e);
    h.c_stack.append(vm.alloc, .{ .String = ls }) catch |e| cThrowOn(vm, h, e);
}

pub export fn luaL_typeerror(L: ?*lua_State, arg: c_int, tname: [*:0]const u8) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    const ty = if (s.typeOf(arg)) |t| typeCode(t) else @as(c_int, -1);
    _ = lua_pushfstring(L, "bad argument #%d (%s expected, got %s)", arg, tname, lua_typename(L, ty));
    lua_error(L);
}

pub export fn luaL_argerror(L: ?*lua_State, arg: c_int, extramsg: ?[*:0]const u8) c_int {
    // PUC lauxlib.c:174-196: the where-prefix comes from level 1 (the
    // Lua caller of this C function); level 0 is this C frame itself.
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
    // PUC lauxlib.c:238-245: luaL_where(L, 1) — level 1 is the Lua caller
    // of this C function (level 0 is the C frame itself, no position).
    luaL_where(L, 1);
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    _ = lua_pushvfstring(L, fmt, @ptrCast(&ap));
    lua_concat(L, 2);
    lua_error(L);
}

/// cThrowOomBuf's ArrayListUnmanaged twin (traceback/gsub buffers).
fn cThrowOomBufU(vm: *Vm, h: *vm_mod.lua_State, buf: *std.ArrayListUnmanaged(u8)) noreturn {
    buf.deinit(vm.alloc);
    cThrowOn(vm, h, error.OutOfMemory);
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
    const h = L orelse return;
    const vm = h.vm;

    // NO defer: _longjmp bypasses it — every failure path deinits the
    // buffer manually via cThrowOomBufU before throwing LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return`/`catch {}` sites
    // leaked the buffer and/or silently dropped the traceback push).
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    if (msg) |m| {
        buf.appendSlice(vm.alloc, std.mem.span(m)) catch cThrowOomBufU(vm, h, &buf);
        buf.append(vm.alloc, '\n') catch cThrowOomBufU(vm, h, &buf);
    }
    buf.appendSlice(vm.alloc, "stack traceback:\n") catch cThrowOomBufU(vm, h, &buf);

    // Walk frames from level `lvl` upward, building the traceback.
    var ar: lua_Debug = .{};
    var level: c_int = lvl;
    while (lua_getstack(L, level, &ar) != 0) : (level += 1) {
        _ = lua_getinfo(L, "Sl", &ar);
        const src: []const u8 = if (ar.source) |s| std.mem.span(s) else "?";
        const line = ar.currentline;
        if (line > 0) {
            // PUC builds each entry with lua_pushfstring into a
            // luaL_Buffer — OOM throws. The entry temp is freed manually
            // (no defer: a later throw would bypass it).
            const entry = std.fmt.allocPrint(vm.alloc, "\t{s}:{d}: in ?\n", .{ src, line }) catch cThrowOomBufU(vm, h, &buf);
            buf.appendSlice(vm.alloc, entry) catch {
                vm.alloc.free(entry);
                cThrowOomBufU(vm, h, &buf);
            };
            vm.alloc.free(entry);
        } else {
            buf.appendSlice(vm.alloc, "\t[C]: in ?\n") catch cThrowOomBufU(vm, h, &buf);
        }
    }

    const ls = vm.internStr(buf.items) catch cThrowOomBufU(vm, h, &buf);
    h.c_stack.append(vm.alloc, .{ .String = ls }) catch cThrowOomBufU(vm, h, &buf);
    buf.deinit(vm.alloc);
}

pub export fn luaL_tolstring(L: ?*lua_State, idx: c_int, l: ?*usize) [*:0]const u8 {
    var s = api.State.fromHandle(L orelse {
        if (l) |p| p.* = 0;
        return "";
    });
    // PUC luaL_tolstring: lua_tolstring (number → luaS_new: OOM throws)
    // then lua_pushfstring for type names (OOM throws) — never a silent
    // "" (P16.50-review-5 B2).
    if (s.tolstring(idx) catch |e| cThrowOn(s.vm, L.?, e)) |bytes| {
        if (l) |p| p.* = bytes.len;
        return @ptrCast(@constCast(bytes.ptr));
    }
    if (s.typeOf(idx)) |t| {
        const name = switch (t) {
            .nil => "nil",
            .boolean => "true",
            .table => "table: 0x0",
            .function => "function: 0x0",
            .userdata => "userdata: 0x0",
            .thread => "thread: 0x0",
            .lightuserdata => "lightuserdata: 0x0",
            .number, .string => "value",
        };
        const ls = s.vm.internStr(name) catch |e| cThrowOn(s.vm, L.?, e);
        s.stack.append(s.vm.alloc, .{ .String = ls }) catch |e| cThrowOn(s.vm, L.?, e);
        if (l) |p| p.* = name.len;
        return @ptrCast(@constCast(ls.bytes().ptr));
    }
    if (l) |p| p.* = 0;
    return "";
}

pub export fn luaL_len(L: ?*lua_State, idx: c_int) i64 {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC luaL_len: lua_len errors propagate (OOM/Runtime throw);
    // Type/InvalidIndex are api_check — lenient 0 (P16.50-review-5 B2).
    s.len(idx) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => return 0,
    };
    const result = s.tointeger(-1) orelse 0;
    s.stack.items.len -= 1;
    return result;
}

pub export fn luaL_gsub(L: ?*lua_State, s_str: [*:0]const u8, p: [*:0]const u8, r: [*:0]const u8) [*:0]const u8 {
    const h = L orelse return s_str;
    const vm = h.vm;
    const src = std.mem.span(s_str);
    const pat = std.mem.span(p);
    const rep = std.mem.span(r);
    // NO defer: _longjmp bypasses it — every failure path deinits the
    // buffer via cThrowOomBufU before throwing LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return s_str` leaked the
    // buffer and silently returned the UNSUBSTITUTED input).
    var result: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        if (pat.len > 0 and i + pat.len <= src.len and std.mem.eql(u8, src[i .. i + pat.len], pat)) {
            result.appendSlice(vm.alloc, rep) catch cThrowOomBufU(vm, h, &result);
            i += pat.len;
        } else {
            result.append(vm.alloc, src[i]) catch cThrowOomBufU(vm, h, &result);
            i += 1;
        }
    }
    const ls = vm.internStr(result.items) catch cThrowOomBufU(vm, h, &result);
    h.c_stack.append(vm.alloc, .{ .String = ls }) catch cThrowOomBufU(vm, h, &result);
    result.deinit(vm.alloc);
    return @ptrCast(@constCast(ls.bytes().ptr));
}

pub export fn luaL_getmetafield(L: ?*lua_State, obj: c_int, event: [*:0]const u8) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    const abs = normalizeIndex(obj, s.stack.items.len) orelse return 0;
    const mt: ?*vm_mod.Table = switch (s.stack.items[abs]) {
        .Table => |t| t.metatable,
        .Userdata => |ud| ud.metatable,
        else => null,
    };
    if (mt) |m| {
        // PUC luaL_getmetafield: lua_getfield on the metatable — OOM is
        // LUA_ERRMEM (P16.50-review-5 B2 — the old `catch return 0`
        // misreported "no metamethod").
        const key = s.vm.internStr(std.mem.span(event)) catch |e| cThrowOn(s.vm, L.?, e);
        const val = s.vm.apiRawGet(m, .{ .String = key });
        if (val == .Nil) return 0;
        s.stack.append(s.vm.alloc, val) catch |e| cThrowOn(s.vm, L.?, e);
        return 1;
    }
    return 0;
}

pub export fn luaL_callmeta(L: ?*lua_State, obj: c_int, event: [*:0]const u8) c_int {
    if (luaL_getmetafield(L, obj, event) == 0) return 0;
    var s = api.State.fromHandle(L orelse return 0);
    // PUC luaL_callmeta: lua_pushvalue → api_incr_top: OOM throws;
    // InvalidIndex is api_check — lenient 0 (P16.50-review-5 B2).
    s.pushvalue(obj) catch |e| switch (e) {
        error.OutOfMemory => cThrowOn(s.vm, L.?, e),
        else => return 0,
    };
    return lua_pcallk(L, 1, 1, 0, 0, null);
}

pub export fn luaL_requiref(L: ?*lua_State, modname: [*:0]const u8, openf: ?*const fn (?*lua_State) callconv(.c) c_int, glb: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    // PUC luaL_requiref: every step (pushcfunction / pushstring / call /
    // setfield / setglobal) throws on failure — no silent early return
    // leaving a half-pushed stack (P16.50-review-5 B2).
    s.pushcfunction(openf) catch |e| cThrowOn(s.vm, L.?, e);
    s.pushstring(std.mem.span(modname)) catch |e| cThrowOn(s.vm, L.?, e);
    s.call(1, 1) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
    // Store in package.loaded[modname]
    _ = s.getglobal("package") catch |e| cThrowOn(s.vm, L.?, e);
    if (s.typeOf(-1)) |t| if (t == .table) {
        _ = s.getfield(-1, "loaded") catch |e| switch (e) {
            error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
            else => {},
        };
        if (s.typeOf(-1)) |t2| if (t2 == .table) {
            _ = s.pushvalue(-3) catch |e| switch (e) {
                error.OutOfMemory => cThrowOn(s.vm, L.?, e),
                else => {},
            };
            s.setfield(-2, std.mem.span(modname)) catch |e| switch (e) {
                error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
                else => {},
            };
        };
        s.stack.items.len -= 1;
    };
    s.stack.items.len -= 1;
    if (glb != 0) {
        _ = s.pushvalue(-1) catch |e| switch (e) {
            error.OutOfMemory => cThrowOn(s.vm, L.?, e),
            else => {},
        };
        s.setglobal(std.mem.span(modname)) catch |e| switch (e) {
            error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
            else => {},
        };
    }
}

pub export fn luaL_loadstring(L: ?*lua_State, s_str: [*:0]const u8) c_int {
    const len = std.mem.len(s_str);
    return luaL_loadbufferx(L, @ptrCast(s_str), len, s_str, null);
}

pub export fn luaL_fileresult(L: ?*lua_State, stat: c_int, fname: ?[*:0]const u8) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC luaL_fileresult: pushboolean/pushnil/pushstring/lua_concat all
    // throw ERRMEM on OOM (P16.50-review-5 B2 — the old `catch {}` sites
    // silently skipped pushes, corrupting the 3-value result shape).
    if (stat >= 0) {
        s.pushboolean(true) catch |e| cThrowOn(s.vm, L.?, e);
        return 1;
    }
    s.pushnil() catch |e| cThrowOn(s.vm, L.?, e);
    s.pushstring("file error") catch |e| cThrowOn(s.vm, L.?, e);
    if (fname) |f| {
        s.pushstring(std.mem.span(f)) catch |e| cThrowOn(s.vm, L.?, e);
        s.concat(2) catch |e| switch (e) {
            error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
            else => {},
        };
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
    const h = L orelse return 0;
    const vm = h.vm;
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
    const h = L orelse return 0;
    const vm = h.vm;
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
                    // PUC pushes the source via lua_pushstring — OOM is
                    // LUA_ERRMEM (P16.50-review-5 B2).
                    const src_ls = vm.internStr(p.sourceName()) catch |e| cThrowOn(vm, h, e);
                    const src_bytes = src_ls.bytes();
                    ar.source = @ptrCast(@constCast(src_bytes.ptr));
                    ar.srclen = src_bytes.len;
                    ar.linedefined = @intCast(p.line_defined);
                    ar.lastlinedefined = @intCast(p.last_line_defined);
                    fillShortSrc(&ar.short_src, p.sourceName());
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
                    ar.isvararg = if (p.flags.is_vararg) 1 else 0;
                } else {
                    // PUC ldebug.c:344-348 (auxgetinfo 'u' for C functions):
                    // nups = nupvalues of the called function (0 for light C
                    // functions / builtins), nparams = 0, isvararg = 1 — C
                    // functions accept any number of arguments.
                    const func = if (frame.func_slot < th.bytecode_stack.len)
                        th.bytecode_stack[frame.func_slot]
                    else
                        .Nil;
                    ar.nups = if (func == .Closure)
                        @intCast(func.Closure.upvalues.len)
                    else
                        0;
                    ar.nparams = 0;
                    ar.isvararg = 1;
                }
            },
            't' => {
                ar.istailcall = if (frame.isTailCall()) 1 else 0;
            },
            'n' => {
                // PUC auxgetinfo 'n' (ldebug.c:369-373): namewhat comes from
                // getfuncname (the CALLER's bytecode at the call site,
                // ldebug.c:323 funcnamefromcall); when it returns NULL the
                // namewhat is "" (empty string) and name is NULL — never a
                // NULL namewhat.
                var resolved_namewhat: []const u8 = "";
                var resolved_name: ?[]const u8 = null;
                if (vm.getFuncNameForFrame(th, frame_idx)) |dn| {
                    resolved_namewhat = dn.namewhat;
                    resolved_name = dn.name;
                }
                const nw_ls = vm.internStr(resolved_namewhat) catch |e| cThrowOn(vm, h, e);
                ar.namewhat = @ptrCast(@constCast(nw_ls.bytes().ptr));
                if (resolved_name) |nm| {
                    const ls = vm.internStr(nm) catch |e| cThrowOn(vm, h, e);
                    ar.name = @ptrCast(@constCast(ls.bytes().ptr));
                } else {
                    ar.name = null;
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
    const h = L orelse return null;
    const vm = h.vm;
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
                const reg_idx = frame.frameBase() + lv.reg;
                if (reg_idx >= th.bytecode_stack.len) return null;
                const val = th.bytecode_stack[reg_idx];
                // PUC lua_getlocal pushes via api_incr_top: OOM is
                // LUA_ERRMEM (P16.50-review-5 B2 — the old `catch return
                // null` misreported "no such local").
                h.c_stack.append(vm.alloc, val) catch |e| cThrowOn(vm, h, e);
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
    const h = L orelse return null;
    const vm = h.vm;
    if (h.c_stack.items.len < 1) return null; // need a value on the stack

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
                const val = h.c_stack.items[h.c_stack.items.len - 1];
                h.c_stack.items.len -= 1;
                const reg_idx = frame.frameBase() + lv.reg;
                if (reg_idx >= th.bytecode_stack.len) return null;
                th.bytecode_stack[reg_idx] = val;
                return @ptrCast(@constCast(lv.name.ptr));
            }
        }
    }
    return null; // no n-th active local
}

/// PUC `aux_upvalue` (lapi.c:1367-1391) resolved at the C-API layer —
/// NEVER through the Lua debug library. PUC contract:
///   - C closure (LUA_VCCL)  → the upvalue slot; the name is `""` (C
///     closures have unnamed upvalues);
///   - Lua closure (LUA_VLCL) → the upvalue slot; the name comes from the
///     proto (PUC returns "(no name)" when the proto records none);
///   - ANY other value — including light C functions (LUA_VLCF) — → NULL,
///     with NO error raised (PUC's `default: return NULL` arm).
/// `n` must be in [1, nupvalues]: PUC's unsigned `cast_uint(n) - 1u <
/// nupvalues` check — n <= 0 wraps to a huge unsigned and fails the range
/// test, so index 0 and negatives are out of range by construction.
///
/// P16.50-review-7 B1: the old `lua_getupvalue`/`lua_setupvalue` fell
/// through to `State.getupvalue`/`State.setupvalue`, which invoke the Lua
/// function `debug.getupvalue` — raising "function expected" for
/// non-function values (12_chook t11: `lua_getupvalue(L, 1, 1)` on the
/// integer argument inside a C closure). PUC returns NULL there.
const AuxUpvalue = struct {
    /// The upvalue cell (our UpVal equivalent — the slot PUC's `*val`
    /// points at; open cells read/write through to the owning stack).
    cell: *vm_mod.Cell,
    /// PUC's name return: `""` for C closures, the proto's arena-backed
    /// NUL-terminated name for Lua closures. `null` never reaches here
    /// (handled by the caller). P16.50-review-8 §1.3: NUL-terminated and
    /// proto-lifetime-stable — the C API hands the bytes out directly.
    name: [:0]const u8,
    /// PUC LUA_VCCL vs LUA_VLCL discrimination: C closures report the
    /// static `""` name; Lua-closure names come from the proto's fused
    /// upvalue-name tail or the fixed dump buffer (no interning on the
    /// query path).
    c_closure: bool,
};

fn auxUpvalue(s: *api.State, funcindex: c_int, n: c_int) ?AuxUpvalue {
    const abs = normalizeIndex(funcindex, s.stack.items.len) orelse return null;
    const cl = switch (s.stack.items[abs]) {
        .Closure => |c| c,
        // PUC aux_upvalue default arm: not a closure → NULL (no error).
        else => return null,
    };
    // PUC: `!(cast_uint(n) - 1u < cast_uint(nupvalues))` → NULL.
    const un: c_uint = @as(c_uint, @bitCast(n)) -% 1;
    if (un >= cl.upvalues.len) return null;
    const idx: usize = @intCast(un);
    return .{
        .cell = cl.upvalues[idx],
        .name = if (cl.c_func != null) "" else vm_mod.Vm.debugUpvalueName(cl, idx),
        .c_closure = cl.c_func != null,
    };
}

/// Resolve the C-API upvalue name as a NUL-terminated `const char*`.
/// C closures use the static `""` (PUC aux_upvalue LUA_VCCL arm). Lua
/// closure names are the proto's arena-backed bytes (P16.50-review-8
/// §1.3) — PUC parity: PUC's `lua_getupvalue` returns `getstr(name)`
/// without allocating, and the pointer stays valid for the closure's
/// proto lifetime (the arena dies with the proto tree). The old
/// implementation interned the name on every query — an allocation on a
/// PUC-allocation-free path whose OOM misreported LUA_ERRMEM.
fn upvalueCName(aux: AuxUpvalue) [*:0]const u8 {
    if (aux.c_closure) return ""; // PUC's static "" (LUA_VCCL arm)
    return aux.name.ptr;
}

pub export fn lua_getupvalue(L: ?*lua_State, funcindex: c_int, n: c_int) ?[*:0]const u8 {
    var s = api.State.fromHandle(L orelse return null);
    // PUC lua_getupvalue (lapi.c:1396-1405): aux_upvalue resolves the name
    // and slot; NULL (never an error) for a non-closure or out-of-range n.
    const aux = auxUpvalue(&s, funcindex, n) orelse return null;
    // PUC resolves the name BEFORE the stack mutation (aux_upvalue runs
    // before setobj2s/api_incr_top). Allocation-free (§1.3 arena names).
    const name = upvalueCName(aux);
    // PUC setobj2s + api_incr_top: push the upvalue's CURRENT value (open
    // cells read through to the owning thread's stack). OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return null` misreported "no
    // such upvalue").
    s.stack.append(s.vm.alloc, aux.cell.get(s.vm)) catch |e| cThrowOn(s.vm, L.?, e);
    return name;
}

pub export fn lua_setupvalue(L: ?*lua_State, funcindex: c_int, n: c_int) ?[*:0]const u8 {
    var s = api.State.fromHandle(L orelse return null);
    // PUC lua_setupvalue (lapi.c:1407-1421): aux_upvalue; NULL (no error)
    // for a non-closure or out-of-range n; on success pops the value from
    // the stack top, stores it into the upvalue slot, and runs the write
    // barrier (luaC_barrier(L, owner, val)).
    const aux = auxUpvalue(&s, funcindex, n) orelse return null;
    // PUC api_checknelems(L, 1) is a no-op in release builds; we fail soft
    // (NULL) instead of popping from an empty stack.
    if (s.stack.items.len == 0) return null;
    const name = upvalueCName(aux);
    const v = s.stack.items[s.stack.items.len - 1];
    // P16.50-review-8 §1.2: reserve the barrier bookkeeping BEFORE the
    // observable store — PUC's luaC_barrier is infallible; a reserve OOM
    // after the write commits would leave the store in place with a
    // missed barrier (the old `catch {}` swallowed exactly that). The
    // reserve OOM throws BEFORE any mutation (LUA_ERRMEM); nothing
    // between prepare and commit allocates, so the plan stays valid.
    const plan = s.vm.gcPrepareWriteBarrierCell(aux.cell, v) catch |e| cThrowOn(s.vm, L.?, e);
    // Store into the slot PUC's `*val` designates: open cells write
    // through to the owning thread's stack slot, closed cells to the
    // cell's own value (Cell.set handles both — PUC writes through *val,
    // which for open upvalues IS the stack slot).
    aux.cell.set(s.vm, v);
    s.vm.gcCommitWriteBarrierCell(aux.cell, v, plan);
    s.stack.items.len -= 1;
    return name;
}

pub export fn lua_upvalueid(L: ?*lua_State, fidx: c_int, n: c_int) ?*anyopaque {
    const s = api.State.fromHandle(L orelse return null);
    const abs = normalizeIndex(fidx, s.stack.items.len) orelse return null;
    const cl = switch (s.stack.items[abs]) {
        .Closure => |c| c,
        // PUC lua_upvalueid (lapi.c:1441-1459): light C functions
        // (LUA_VLCF) and non-functions → NULL (the api_check in the
        // default arm is a release no-op).
        else => return null,
    };
    // PUC: LCL out-of-range → NULL (getupvalref's nullup); CCL out-of-range
    // → falls through to NULL.
    const un: c_uint = @as(c_uint, @bitCast(n)) -% 1;
    if (un >= cl.upvalues.len) return null;
    const idx: usize = @intCast(un);
    // PUC LCL returns the UpVal object pointer; CCL returns &f->upvalue[n-1]
    // — the address of the closure's own upvalue slot. Our representation
    // gives both closures heap Cells: the Cell pointer is the stable
    // per-closure-lifetime identity in both cases (for C closures the Cell
    // plays the role of PUC's inline upvalue slot).
    return @ptrCast(cl.upvalues[idx]);
}

pub export fn lua_upvaluejoin(L: ?*lua_State, fidx1: c_int, n1: c_int, fidx2: c_int, n2: c_int) void {
    const s = api.State.fromHandle(L orelse return);
    const abs1 = normalizeIndex(fidx1, s.stack.items.len) orelse return;
    const abs2 = normalizeIndex(fidx2, s.stack.items.len) orelse return;
    // PUC lua_upvaluejoin (lapi.c:1463-1470) via getupvalref: ONLY Lua
    // closures participate (api_check ttisLclosure — a release no-op; the
    // manual documents non-Lua-closure input as undefined behavior). We
    // fail soft: a silent no-op for any non-Lua-closure or out-of-range
    // index, keeping the C-API contract non-raising (P16.50-review-7 B1).
    const cl1 = switch (s.stack.items[abs1]) {
        .Closure => |c| c,
        else => return,
    };
    const cl2 = switch (s.stack.items[abs2]) {
        .Closure => |c| c,
        else => return,
    };
    if (cl1.proto == null or cl2.proto == null) return; // not Lua closures
    const un1: c_uint = @as(c_uint, @bitCast(n1)) -% 1;
    const un2: c_uint = @as(c_uint, @bitCast(n2)) -% 1;
    if (un1 >= cl1.upvalues.len or un2 >= cl2.upvalues.len) return;
    const idx1: usize = @intCast(un1);
    const idx2: usize = @intCast(un2);
    // PUC `*up1 = *up2`: re-point f1's upvalue slot to f2's UpVal object —
    // NOT a value copy. After the join both closures observe the SAME
    // upvalue cell (a setupvalue through one is visible through the
    // other; lua_upvalueid reports the shared identity). The old code
    // copied the current value, breaking exactly that shared identity.
    //
    // P16.50-review-8 §1.1/§1.2: reserve the forward-barrier bookkeeping
    // BEFORE the observable re-point. The barrier targets the joined CELL
    // (PUC luaC_objbarrier(L, f1, *up1)) — the old code marked only the
    // cell's VALUE, so a white joined cell reachable solely through the
    // black owner closure was swept (use-after-free). A reserve OOM
    // throws BEFORE the re-point (LUA_ERRMEM via the error-jump boundary);
    // nothing between prepare and commit allocates.
    const plan = s.vm.gcPrepareForwardBarrierCell(cl1, cl2.upvalues[idx2]) catch |e| cThrowOn(s.vm, L.?, e);
    @constCast(cl1.upvalues)[idx1] = cl2.upvalues[idx2];
    s.vm.gcCommitForwardBarrierCell(cl1, cl2.upvalues[idx2], plan);
}

/// PUC `lua_sethook` (ldebug.c:133): install/clear a C hook function.
/// PUC has a single hook slot per thread: `L->hook`, `L->hookmask`,
/// `L->basehookcount`. When `func == NULL` or `mask == 0`, the hook is
/// turned off. Otherwise the hook, mask, and count are stored and the
/// running count is reset (`resethookcount`).
///
/// P15.83h: The C hook function pointer now lives in DebugHookState.c_hook
/// (per-thread, PUC-faithful). The mask/count are mirrored into the shared
/// DebugHookState fields (has_call/has_return/has_line/count/budget) so
/// existing trigger sites fire. Setting a C hook clears the Lua-level
/// DebugHookState.func (single slot), mirroring PUC's singular hook design.
pub export fn lua_sethook(L: ?*lua_State, func: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, mask: c_int, count: c_int) void {
    const h = L orelse return;
    const vm = h.vm;
    // P15.83h: Resolve the thread via the handle (PUC L->hook is per-thread).
    // L.thread is null for the main state → use main_thread.
    const th = h.thread orelse vm.main_thread orelse return;
    const hs = &th.debug_hook;
    // PUC lua_sethook: if func==NULL or mask==0, turn off hooks.
    if (func == null or mask == 0) {
        hs.clear();
        vm.refreshHooksCached();
        return;
    }
    hs.c_hook = func;
    hs.func = null; // Single hook slot — clear the Lua-level hook.
    hs.has_call = (mask & 1) != 0; // LUA_MASKCALL
    hs.has_return = (mask & 2) != 0; // LUA_MASKRET
    hs.has_line = (mask & 4) != 0; // LUA_MASKLINE
    const count_i64: i64 = @intCast(@max(count, 0));
    hs.count = if ((mask & 8) != 0) count_i64 else 0; // LUA_MASKCOUNT
    hs.budget = hs.count;
    hs.tick = 0;
    hs.allow_yield = false;
    // P16.21 T4.3: hooks transitioning to active — sanitize replay state
    // for every live Lua frame of this thread (mirrors debug.sethook).
    vm.sanitizeHookReplayState(th);
    vm.refreshHooksCached();
}

/// PUC `lua_gethook` (ldebug.c:152): return the current hook function.
pub export fn lua_gethook(L: ?*lua_State) ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void {
    const h = L orelse return null;
    const vm = h.vm;
    const th = h.thread orelse vm.main_thread orelse return null;
    return th.debug_hook.c_hook;
}

pub export fn lua_gethookmask(L: ?*lua_State) c_int {
    const h = L orelse return 0;
    const vm = h.vm;
    const th = h.thread orelse vm.main_thread orelse return 0;
    const hs = &th.debug_hook;
    // Reconstruct the PUC mask from the shared DebugHookState fields.
    return (if (hs.has_call) @as(c_int, 1) else 0) | // LUA_MASKCALL
        (if (hs.has_return) @as(c_int, 2) else 0) | // LUA_MASKRET
        (if (hs.has_line) @as(c_int, 4) else 0) | // LUA_MASKLINE
        (if (hs.count > 0) @as(c_int, 8) else 0); // LUA_MASKCOUNT
}

pub export fn lua_gethookcount(L: ?*lua_State) c_int {
    const h = L orelse return 0;
    const vm = h.vm;
    const th = h.thread orelse vm.main_thread orelse return 0;
    // PUC returns basehookcount (the interval set by lua_sethook).
    return @intCast(@max(th.debug_hook.count, 0));
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
    const h = L orelse return 0;
    const vm = h.vm;
    // PUC lua_pushglobaltable → api_incr_top: OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return 0` pushed nothing).
    h.c_stack.append(vm.alloc, .{ .Table = vm.global_env }) catch |e| cThrowOn(vm, h, e);
    return 1;
}

/// PUC `luaopen_package` (loadlib.c): opens the package library.
/// The `package` table is already in `_G.package`; push it.
pub export fn luaopen_package(L: ?*lua_State) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC pushes the module table — OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return 0` pushed nothing).
    _ = s.getglobal("package") catch |e| cThrowOn(s.vm, L.?, e);
    return 1;
}

/// PUC `luaopen_coroutine` (lcorolib.c): opens the coroutine library.
pub export fn luaopen_coroutine(L: ?*lua_State) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC pushes the module table — OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return 0` pushed nothing).
    _ = s.getglobal("coroutine") catch |e| cThrowOn(s.vm, L.?, e);
    return 1;
}

/// PUC `luaopen_debug` (ldblib.c): opens the debug library.
pub export fn luaopen_debug(L: ?*lua_State) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC pushes the module table — OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return 0` pushed nothing).
    _ = s.getglobal("debug") catch |e| cThrowOn(s.vm, L.?, e);
    return 1;
}

/// PUC `luaopen_io` (liolib.c): opens the I/O library.
pub export fn luaopen_io(L: ?*lua_State) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC pushes the module table — OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return 0` pushed nothing).
    _ = s.getglobal("io") catch |e| cThrowOn(s.vm, L.?, e);
    return 1;
}

/// PUC `luaopen_math` (lmathlib.c): opens the math library.
pub export fn luaopen_math(L: ?*lua_State) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC pushes the module table — OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return 0` pushed nothing).
    _ = s.getglobal("math") catch |e| cThrowOn(s.vm, L.?, e);
    return 1;
}

/// PUC `luaopen_os` (loslib.c): opens the os library.
pub export fn luaopen_os(L: ?*lua_State) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC pushes the module table — OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return 0` pushed nothing).
    _ = s.getglobal("os") catch |e| cThrowOn(s.vm, L.?, e);
    return 1;
}

/// PUC `luaopen_string` (lstrlib.c): opens the string library.
pub export fn luaopen_string(L: ?*lua_State) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC pushes the module table — OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return 0` pushed nothing).
    _ = s.getglobal("string") catch |e| cThrowOn(s.vm, L.?, e);
    return 1;
}

/// PUC `luaopen_table` (ltablib.c): opens the table library.
pub export fn luaopen_table(L: ?*lua_State) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC pushes the module table — OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return 0` pushed nothing).
    _ = s.getglobal("table") catch |e| cThrowOn(s.vm, L.?, e);
    return 1;
}

/// PUC `luaopen_utf8` (lutf8lib.c): opens the utf8 library.
pub export fn luaopen_utf8(L: ?*lua_State) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC pushes the module table — OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return 0` pushed nothing).
    _ = s.getglobal("utf8") catch |e| cThrowOn(s.vm, L.?, e);
    return 1;
}

/// PUC `luaL_openselectedlibs` (linit.c:46): opens selected standard libraries.
/// `load` is a bitmask of `LUA_*LIBK` constants for libraries to open via
/// `luaL_requiref`. `preload` is a bitmask for libraries to register in
/// `package.preload` (so `require` will call the openf on first use).
/// `luaL_openlibs(L)` is `luaL_openselectedlibs(L, ~0, 0)`.
pub export fn luaL_openselectedlibs(L: ?*lua_State, load: c_int, preload: c_int) void {
    var s = api.State.fromHandle(L orelse return);

    // PUC: luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE)
    // Get the PRELOAD table from the registry. The VM stores it under
    // "_PRELOAD" in the debug registry (see Vm.init package setup).
    // PUC luaL_getsubtable throws on OOM (P16.50-review-5 B2 — the old
    // early returns left the library set half-open with no error).
    s.getregistry() catch |e| cThrowOn(s.vm, L.?, e);
    _ = s.getfield(-1, "_PRELOAD") catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
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
            // Both throw on OOM in PUC (P16.50-review-5 B2).
            s.pushcfunction(lib.openf) catch |e| cThrowOn(s.vm, L.?, e);
            s.setfield(-2, std.mem.span(lib.name)) catch |e| switch (e) {
                error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
                else => {},
            };
        }
    }

    // PUC: lua_pop(L, 1) — remove PRELOAD table.
    // We also pop the registry table that was pushed above.
    s.stack.items.len -= 2;
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
    const h = B.L orelse return &B.init[0];
    const vm = h.vm;
    if (B.n + sz <= B.size) return &B.b[B.n];

    // Need to grow. Compute new capacity (at least double, at least n+sz).
    var new_size = B.size;
    while (new_size < B.n + sz) new_size *= 2;

    if (B.b == &B.init[0]) {
        // Spilling from inline to heap: allocate and copy inline content.
        // PUC luaL_prepbuffsize → luaM_error: OOM is LUA_ERRMEM
        // (P16.50-review-5 B2 — the old `catch return &B.init[0]` handed
        // the caller the INLINE buffer with no free space, an overflow
        // trap). B is untouched on failure — nothing to clean up.
        const new_buf = vm.alloc.alloc(u8, new_size) catch |e| cThrowOn(vm, h, e);
        @memcpy(new_buf[0..B.n], B.init[0..B.n]);
        B.b = new_buf.ptr;
        B.size = new_size;
    } else {
        // Already on heap: realloc. The old buffer stays valid on
        // failure — nothing to clean up before the throw.
        const old_buf = B.b[0..B.size];
        const new_buf = vm.alloc.realloc(old_buf, new_size) catch |e| cThrowOn(vm, h, e);
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
    const h = B.L orelse return;
    if (h.c_stack.items.len == 0) return;
    var l: usize = 0;
    const s = lua_tolstring(h, -1, &l);
    luaL_addlstring(B, s, l);
    h.c_stack.items.len -= 1;
}

/// PUC `luaL_pushresult` (lauxlib.c:601): push the buffer content as a Lua
/// string onto the stack, freeing any heap allocation.
pub export fn luaL_pushresult(B: *luaL_Buffer) void {
    luaL_pushresultsize(B, B.n);
}

/// PUC `luaL_pushresultsize` (lauxlib.c:593): push the first `sz` bytes of
/// the buffer as a Lua string, then free heap allocation if any.
pub export fn luaL_pushresultsize(B: *luaL_Buffer, sz: usize) void {
    const h = B.L orelse return;
    const vm = h.vm;
    B.n = sz;
    // PUC luaL_pushresultsize → lua_pushlstring: OOM is LUA_ERRMEM, with
    // the spilled heap buffer freed BEFORE the throw (P16.50-review-5
    // B2 — the old `catch return`/`catch {}` leaked the heap spill
    // and/or silently skipped the push).
    const ls = vm.internStr(B.b[0..sz]) catch {
        if (B.b != &B.init[0]) vm.alloc.free(B.b[0..B.size]);
        cThrowOn(vm, h, error.OutOfMemory);
    };
    h.c_stack.append(vm.alloc, .{ .String = ls }) catch {
        if (B.b != &B.init[0]) vm.alloc.free(B.b[0..B.size]);
        cThrowOn(vm, h, error.OutOfMemory);
    };
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
            const ch = src[i .. i + 1];
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

    try std.testing.expect(L.vm.errThread().err_has_obj);
    try std.testing.expectEqualStrings("boom from C", L.vm.errThread().err_obj.String.bytes());
    try std.testing.expect(L.vm.c_error_value == null);
    // PUC luaD_pcall → luaD_seterrorobj: on error, the error object is
    // pushed onto the stack. lua_gettop should be 1 (the error object).
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L));
}

test "c api boundary success path returns results normally" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    lua_pushcfunction(L, cfuncReturns42);
    const status = lua_pcallk(L, 0, 1, 0, 0, null);
    try std.testing.expectEqual(@as(c_int, 0), status);
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L));
    try std.testing.expectEqual(@as(i64, 42), intAt(L, -1));
    try std.testing.expect(!L.vm.errThread().err_has_obj);
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

// ─────────────────────────────────────────────────────────────────────
// P16.50-review-7 B1: the upvalue primitives follow the PUC C-API
// contract (aux_upvalue, lapi.c:1367-1391) at the C-API layer — NEVER
// through the Lua debug library. The old lua_getupvalue/lua_setupvalue
// fell through to State.getupvalue/setupvalue → debug.getupvalue, which
// raises "function expected" for non-function values (12_chook t11:
// lua_getupvalue(L, 1, 1) on the integer argument inside a C closure).
// PUC returns NULL there — no error, no push.
// ─────────────────────────────────────────────────────────────────────
test "c api upvalue primitives follow the PUC aux_upvalue contract" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    // ---- Non-function value: NULL, no error, nothing pushed (PUC
    // aux_upvalue default arm).
    lua_pushinteger(L, 23);
    try std.testing.expect(lua_getupvalue(L, 1, 1) == null);
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L));
    // setupvalue on a non-function: NULL, stack untouched (no pop —
    // PUC pops only on success).
    lua_pushinteger(L, 99);
    try std.testing.expect(lua_setupvalue(L, -2, 1) == null);
    try std.testing.expectEqual(@as(c_int, 2), lua_gettop(L));
    try std.testing.expectEqual(@as(i64, 99), intAt(L, -1));
    // upvalueid on a non-function: NULL (PUC lua_upvalueid default arm).
    try std.testing.expect(lua_upvalueid(L, 1, 1) == null);
    // upvaluejoin with non-functions: silent no-op (PUC documents
    // non-Lua-closure input as UB; we fail soft — see lua_upvaluejoin).
    lua_upvaluejoin(L, 1, 1, 1, 1);
    try std.testing.expectEqual(@as(c_int, 2), lua_gettop(L));
    lua_settop(L, 0);

    // ---- C closure with 1 upvalue: name "" (PUC LUA_VCCL arm — a
    // non-NULL empty string), value push/pop, write-through, stable id.
    // lua_pushcclosure POPS the upvalue values and pushes the closure
    // (PUC lapi.c) — the stack holds exactly the closure afterwards.
    lua_pushinteger(L, 100);
    lua_pushcclosure(L, cfuncReturns42, 1);
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L));
    // Index 0: PUC's unsigned `n - 1u` wraps out of range → NULL.
    try std.testing.expect(lua_getupvalue(L, -1, 0) == null);
    // Out of range (2 > nupvalues): NULL.
    try std.testing.expect(lua_getupvalue(L, -1, 2) == null);
    try std.testing.expect(lua_setupvalue(L, -1, 2) == null);
    try std.testing.expect(lua_upvalueid(L, -1, 2) == null);
    // Valid n=1: name "" and the upvalue value pushed.
    const cnm = lua_getupvalue(L, -1, 1);
    try std.testing.expect(cnm != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.span(cnm.?).len);
    try std.testing.expectEqual(@as(i64, 100), intAt(L, -1));
    lua_pop(L, 1); // drop the pushed upvalue value → stack [cl]
    // setupvalue: pops the value, returns "", writes the cell.
    lua_pushinteger(L, 55);
    const snm = lua_setupvalue(L, -2, 1);
    try std.testing.expect(snm != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.span(snm.?).len);
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L)); // value popped
    _ = lua_getupvalue(L, -1, 1);
    try std.testing.expectEqual(@as(i64, 55), intAt(L, -1));
    lua_pop(L, 1);
    // upvalueid: non-null, stable across reads/writes; out-of-range NULL.
    const cid = lua_upvalueid(L, -1, 1);
    try std.testing.expect(cid != null);
    try std.testing.expectEqual(cid, lua_upvalueid(L, -1, 1));
    // upvaluejoin with a C closure participant: no-op (ids unchanged).
    lua_upvaluejoin(L, -1, 1, -1, 1);
    try std.testing.expectEqual(cid, lua_upvalueid(L, -1, 1));
    lua_settop(L, 0);

    // ---- Lua closure: proto name ("x"), value push, write-through.
    try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, "local x = 7 return function() return x end"));
    try std.testing.expectEqual(@as(c_int, 0), lua_pcallk(L, 0, 1, 0, 0, null));
    try std.testing.expectEqual(@as(c_int, 6), lua_type(L, -1)); // LUA_TFUNCTION
    // Index 0 → NULL (unsigned wrap), out-of-range → NULL.
    try std.testing.expect(lua_getupvalue(L, -1, 0) == null);
    try std.testing.expect(lua_getupvalue(L, -1, 2) == null);
    // Valid n=1: name "x" (the proto-recorded upvalue name), value 7.
    const lnm = lua_getupvalue(L, -1, 1);
    try std.testing.expect(lnm != null);
    try std.testing.expectEqualStrings("x", std.mem.span(lnm.?));
    try std.testing.expectEqual(@as(i64, 7), intAt(L, -1));
    lua_pop(L, 1); // drop the pushed upvalue value → stack [cl]
    // setupvalue writes through the (closed) cell and returns "x".
    lua_pushinteger(L, 8);
    const lsnm = lua_setupvalue(L, -2, 1);
    try std.testing.expectEqualStrings("x", std.mem.span(lsnm.?));
    _ = lua_getupvalue(L, -1, 1);
    try std.testing.expectEqual(@as(i64, 8), intAt(L, -1));
    lua_settop(L, 0);
    try std.testing.expectEqual(@as(c_int, 0), lua_gettop(L));

    // ---- upvaluejoin: f1's upvalue slot is RE-POINTED to f2's cell
    // (PUC `*up1 = *up2`, lapi.c:1470) — shared identity, not a value
    // copy. The old code copied the value: the ids stayed distinct and
    // a write through one was invisible through the other.
    try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(
        L,
        "local function mk() local v = 0 return function() return v end, function(nv) v = nv end end local g1, s1 = mk() local g2, s2 = mk() return g1, s1, g2, s2",
    ));
    try std.testing.expectEqual(@as(c_int, 0), lua_pcallk(L, 0, 4, 0, 0, null));
    // Stack: [g1, s1, g2, s2] — g1/s1 share one cell, g2/s2 another.
    const g1_id = lua_upvalueid(L, -4, 1);
    const s1_id = lua_upvalueid(L, -3, 1);
    const g2_id = lua_upvalueid(L, -2, 1);
    try std.testing.expect(g1_id != null and s1_id != null and g2_id != null);
    try std.testing.expectEqual(g1_id, s1_id); // same function scope
    try std.testing.expect(g1_id != g2_id); // independent mk() scopes
    // Out-of-range join: no-op (ids unchanged).
    lua_upvaluejoin(L, -4, 2, -2, 1);
    try std.testing.expectEqual(g1_id, lua_upvalueid(L, -4, 1));
    // Join g1's upvalue to g2's: g1 now observes g2's cell.
    lua_upvaluejoin(L, -4, 1, -2, 1);
    try std.testing.expectEqual(g2_id, lua_upvalueid(L, -4, 1));
    try std.testing.expect(g1_id != lua_upvalueid(L, -4, 1)); // re-pointed
    // The join is a slot re-point, not a value copy: a write through s2
    // (g2's setter) is visible through g1's cell.
    lua_pushinteger(L, 77);
    try std.testing.expect(lua_setupvalue(L, -2, 1) != null); // s2 writes
    _ = lua_getupvalue(L, -4, 1); // read g1's (joined) upvalue
    try std.testing.expectEqual(@as(i64, 77), intAt(L, -1));
}

// --- review-7 B1: OOM-on-result-push fixtures (file scope — the
// FailingAllocator must outlive the LUA_ERRMEM longjmp: vm.alloc keeps
// pointing at it until the test restores the base after lua_pcallk) ---

var b1_oom_base: std.mem.Allocator = undefined;
var b1_oom_failing: std.testing.FailingAllocator = undefined;
var b1_oom_closure: ?*vm_mod.Closure = null;

fn b1CfGetupvaluePushOom(L: ?*lua_State) callconv(.c) c_int {
    var s = api.State.fromHandle(L.?);
    // Stage the Lua closure at index 1 on the fresh c_stack (pcallk with
    // 0 args → the activation reserved LUA_MINSTACK spare slots), then
    // fill the stack to EXACT capacity so the result push inside
    // lua_getupvalue MUST allocate (the growth is the armed failure).
    s.stack.append(s.vm.alloc, .{ .Closure = b1_oom_closure.? }) catch return -1;
    while (s.stack.capacity > s.stack.items.len) {
        s.stack.append(s.vm.alloc, .Nil) catch return -1;
    }
    // Arm: from here the ONLY fallible step is the result push (the
    // upvalue name "x" is pre-interned by the test — the name lookup is
    // an intern-table hit, no allocation). ArrayList growth tries
    // remap/resize FIRST and falls back to a fresh alloc, so BOTH the
    // remap and the alloc budgets must fail for the push to OOM.
    b1_oom_failing = std.testing.FailingAllocator.init(b1_oom_base, .{ .fail_index = 0, .resize_fail_index = 0 });
    s.vm.alloc = b1_oom_failing.allocator();
    _ = lua_getupvalue(L, 1, 1); // OOM on the push → LUA_ERRMEM longjmp
    return 0; // unreachable on the armed failure
}

test "c api lua_getupvalue OOM on result push is LUA_ERRMEM" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);
    const vm = L.vm;

    // A Lua closure with one named upvalue; pre-intern "x" so the ONLY
    // fallible step inside lua_getupvalue is the result push (PUC
    // api_incr_top → luaD_throw(LUA_ERRMEM)).
    try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, "local x = 7 return function() return x end"));
    try std.testing.expectEqual(@as(c_int, 0), lua_pcallk(L, 0, 1, 0, 0, null));
    const s = api.State.fromHandle(L);
    b1_oom_closure = s.stack.items[s.stack.items.len - 1].Closure;
    // Keep the closure and the name alive across the pcall (temp roots —
    // the swapped-out main stack is not GC-marked during the C call).
    var roots = vm.gcTempRoots();
    defer roots.end();
    try roots.add(.{ .Closure = b1_oom_closure.? });
    const xkey = try vm.internStr("x");
    try roots.add(.{ .String = xkey });

    lua_settop(L, 0);
    lua_pushcfunction(L, b1CfGetupvaluePushOom);
    b1_oom_base = vm.alloc;
    const status = lua_pcallk(L, 0, 0, 0, 0, null);
    // Restore the base allocator BEFORE any other API use (the longjmp
    // left vm.alloc pointing at the (still valid, file-scope) failing
    // allocator; its single failure budget is already spent).
    vm.alloc = b1_oom_base;

    // PUC lua_getupvalue → api_incr_top OOM → luaD_throw(LUA_ERRMEM).
    try std.testing.expectEqual(@as(c_int, 4), status); // LUA_ERRMEM
    // The fixed MEMERRMSG error object is installed (luaD_seterrorobj
    // parity — "not enough memory", not a nil).
    try std.testing.expect(vm.errThread().err_has_obj);
    try std.testing.expectEqualStrings("not enough memory", vm.errThread().err_obj.String.bytes());
}

// --- review-8 §1.2/§1.3: barrier-reserve OOM throws before the observable
// mutation (pcallk boundary pattern — vm.alloc keeps pointing at the
// file-scope failing allocator until the test restores the base after the
// longjmp), and arena-backed upvalue names are pointer-stable and
// allocation-free on the query path. ---

var b8_base: std.mem.Allocator = undefined;
var b8_failing: std.testing.FailingAllocator = undefined;
var b8_owner: ?*vm_mod.Closure = null;
var b8_donor: ?*vm_mod.Closure = null;
var b8_young: ?*vm_mod.Table = null;

/// GcAge.isYoung is vm.zig-private: new|survival (the unpromoted ages).
fn b8AgeIsYoung(age: vm_mod.GcAge) bool {
    return age == .new or age == .survival;
}

/// Stages [owner(1), young_table(2)] on the fresh pcallk stack, forces both
/// generational reserves to really allocate, then arms fail_index=0: the
/// ONLY fallible step inside lua_setupvalue is the barrier reserve, which
/// must throw LUA_ERRMEM BEFORE the store commits.
fn b8CfSetupvalueOom(L: ?*lua_State) callconv(.c) c_int {
    var s = api.State.fromHandle(L.?);
    s.stack.append(s.vm.alloc, .{ .Closure = b8_owner.? }) catch return -1;
    lua_createtable(L, 0, 0);
    b8_young = s.stack.items[s.stack.items.len - 1].Table;
    // Force both reserves to allocate (fresh capacity-less lists).
    s.vm.gc_gray.deinit(s.vm.alloc);
    s.vm.gc_gray = .empty;
    s.vm.gc_old1.deinit(s.vm.alloc);
    s.vm.gc_old1 = .empty;
    b8_failing = std.testing.FailingAllocator.init(b8_base, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    s.vm.alloc = b8_failing.allocator();
    const name = lua_setupvalue(L, 1, 1); // reserve OOM → LUA_ERRMEM longjmp
    return if (name != null) 0 else -1;
}

test "c api lua_setupvalue OOM throws LUA_ERRMEM before the store" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);
    const vm = L.vm;

    // Owner closure with one named CLOSED upvalue ("x" → a table).
    try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, "local x = {1} return function() return x end"));
    try std.testing.expectEqual(@as(c_int, 0), lua_pcallk(L, 0, 1, 0, 0, null));
    const s = api.State.fromHandle(L);
    b8_owner = s.stack.items[s.stack.items.len - 1].Closure;
    const owner_cell = b8_owner.?.upvalues[0];
    const orig_value = owner_cell.value;
    var roots = vm.gcTempRoots();
    defer roots.end();
    try roots.add(.{ .Closure = b8_owner.? });

    // Enter generational mode: the closure + its closed cell become OLD,
    // so storing a young value fires the gen arm's reserves.
    _ = luazigGcFixed(L, 7, 0); // LUA_GCGENERATIONAL

    lua_pushcfunction(L, b8CfSetupvalueOom);
    b8_base = vm.alloc;
    const status = lua_pcallk(L, 0, 0, 0, 0, null);
    vm.alloc = b8_base; // restore before any other API use

    // The reserve OOM is LUA_ERRMEM (PUC luaC_barrier is infallible; the
    // observable store must not commit when the barrier cannot).
    try std.testing.expectEqual(@as(c_int, 4), status);
    try std.testing.expect(vm.errThread().err_has_obj);
    try std.testing.expectEqualStrings("not enough memory", vm.errThread().err_obj.String.bytes());
    // The store did NOT happen: the cell still holds its original table,
    // the young table is unpromoted, nothing was published.
    try std.testing.expect(std.meta.eql(owner_cell.value, orig_value));
    try std.testing.expect(b8AgeIsYoung(b8_young.?.gc_age));
    try std.testing.expectEqual(@as(usize, 0), vm.gc_old1.items.len);
    try std.testing.expectEqual(@as(usize, 0), vm.gc_gray.items.len);

    // Reuse with the real allocator: the same store succeeds, returns the
    // arena-backed name, promotes + publishes the young table exactly
    // once, and a full collection keeps it alive through the old cell.
    // (The failed pcallk left the error object on the stack — drop it.)
    lua_settop(L, 1); // [closure]
    s.stack.append(vm.alloc, .{ .Table = b8_young.? }) catch return error.OutOfMemory;
    const name = lua_setupvalue(L, -2, 1);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("x", std.mem.span(name.?));
    try std.testing.expect(std.meta.eql(owner_cell.value, .{ .Table = b8_young.? }));
    try std.testing.expect(b8_young.?.gc_age == .old0);
    var old1_count: usize = 0;
    for (vm.gc_old1.items) |o| {
        if (std.meta.eql(o, .{ .table = b8_young.? })) old1_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), old1_count);
    _ = luazigGcFixed(L, 2, 0); // LUA_GCCOLLECT
    try std.testing.expect(std.meta.eql(owner_cell.value, .{ .Table = b8_young.? }));
    lua_settop(L, 0);
}

/// Stages [owner(1), donor(2)] on the fresh pcallk stack (both Lua closures
/// with one closed upvalue each; the owner is OLD, the donor YOUNG), forces
/// the generational reserves to allocate, then arms fail_index=0: the join's
/// barrier reserve must throw LUA_ERRMEM BEFORE the re-point.
fn b8CfUpvaluejoinOom(L: ?*lua_State) callconv(.c) c_int {
    var s = api.State.fromHandle(L.?);
    s.stack.append(s.vm.alloc, .{ .Closure = b8_owner.? }) catch return -1;
    s.stack.append(s.vm.alloc, .{ .Closure = b8_donor.? }) catch return -1;
    s.vm.gc_gray.deinit(s.vm.alloc);
    s.vm.gc_gray = .empty;
    s.vm.gc_old1.deinit(s.vm.alloc);
    s.vm.gc_old1 = .empty;
    b8_failing = std.testing.FailingAllocator.init(b8_base, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    s.vm.alloc = b8_failing.allocator();
    lua_upvaluejoin(L, 1, 1, 2, 1); // reserve OOM → LUA_ERRMEM longjmp
    return 0; // unreachable on the armed failure
}

test "c api lua_upvaluejoin OOM throws LUA_ERRMEM before the re-point" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);
    const vm = L.vm;

    // Owner created before entering generational mode (→ OLD), donor after
    // (→ YOUNG): the join's gen arm reserves for the donor's cell.
    try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, "local x = {1} return function() return x end"));
    try std.testing.expectEqual(@as(c_int, 0), lua_pcallk(L, 0, 1, 0, 0, null));
    const s = api.State.fromHandle(L);
    b8_owner = s.stack.items[s.stack.items.len - 1].Closure;
    const owner_cell = b8_owner.?.upvalues[0];
    var roots = vm.gcTempRoots();
    defer roots.end();
    try roots.add(.{ .Closure = b8_owner.? });
    _ = luazigGcFixed(L, 7, 0); // LUA_GCGENERATIONAL

    try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, "local y = {2} return function() return y end"));
    try std.testing.expectEqual(@as(c_int, 0), lua_pcallk(L, 0, 1, 0, 0, null));
    b8_donor = s.stack.items[s.stack.items.len - 1].Closure;
    const donor_cell = b8_donor.?.upvalues[0];
    try roots.add(.{ .Closure = b8_donor.? });
    try std.testing.expect(b8AgeIsYoung(donor_cell.gc_age));

    lua_pushcfunction(L, b8CfUpvaluejoinOom);
    b8_base = vm.alloc;
    const status = lua_pcallk(L, 0, 0, 0, 0, null);
    vm.alloc = b8_base;

    try std.testing.expectEqual(@as(c_int, 4), status); // LUA_ERRMEM
    try std.testing.expect(vm.errThread().err_has_obj);
    try std.testing.expectEqualStrings("not enough memory", vm.errThread().err_obj.String.bytes());
    // The re-point did NOT happen: the owner still observes its own cell,
    // the donor cell is unpromoted, nothing was published.
    try std.testing.expect(b8_owner.?.upvalues[0] == owner_cell);
    try std.testing.expect(b8AgeIsYoung(donor_cell.gc_age));
    try std.testing.expectEqual(@as(usize, 0), vm.gc_old1.items.len);
    try std.testing.expectEqual(@as(usize, 0), vm.gc_gray.items.len);

    // Reuse with the real allocator: the join re-points the owner's slot,
    // shares identity, and a write through the owner is visible through
    // the donor (the shared-cell contract). (The failed pcallk left the
    // error object on the stack — drop it: stack [owner, donor].)
    lua_settop(L, 2);
    lua_upvaluejoin(L, -2, 1, -1, 1);
    try std.testing.expect(b8_owner.?.upvalues[0] == donor_cell);
    try std.testing.expectEqual(lua_upvalueid(L, -2, 1), lua_upvalueid(L, -1, 1));
    lua_pushinteger(L, 77);
    try std.testing.expect(lua_setupvalue(L, -3, 1) != null); // write via owner
    _ = lua_getupvalue(L, -2, 1); // read via donor
    try std.testing.expectEqual(@as(i64, 77), intAt(L, -1));
    lua_settop(L, 0);
}

test "c api upvalue names are arena-backed: stable pointers, no query allocation" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);
    const vm = L.vm;

    // PUC parity (lapi.c aux_upvalue → getstr): the name pointer is valid
    // for the closure's proto lifetime and the query allocates nothing.
    // The old implementation interned the name per query — an allocation
    // on a PUC-allocation-free path.
    try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, "local x = 7 return function() return x end"));
    try std.testing.expectEqual(@as(c_int, 0), lua_pcallk(L, 0, 1, 0, 0, null));
    const s = api.State.fromHandle(L);
    const closure = s.stack.items[s.stack.items.len - 1].Closure;
    var roots = vm.gcTempRoots();
    defer roots.end();
    try roots.add(.{ .Closure = closure });

    const name1 = lua_getupvalue(L, -1, 1);
    try std.testing.expect(name1 != null);
    try std.testing.expectEqualStrings("x", std.mem.span(name1.?));
    try std.testing.expectEqual(@as(i64, 7), intAt(L, -1));
    lua_pop(L, 1); // drop the pushed value → stack [cl]

    // Churn: garbage + full collections. The proto's name arena dies only
    // with the proto tree (rooted via the rooted closure), so the name
    // pointer must stay valid across every collection.
    for (0..8) |_| {
        try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, "local t = {} for i = 1, 100 do t[i] = {i} end"));
        try std.testing.expectEqual(@as(c_int, 0), lua_pcallk(L, 0, 0, 0, 0, null));
        _ = luazigGcFixed(L, 2, 0); // LUA_GCCOLLECT
    }
    try std.testing.expect(lua_type(L, -1) == 6); // LUA_TFUNCTION — still the closure

    const name2 = lua_getupvalue(L, -1, 1);
    try std.testing.expect(name2 != null);
    try std.testing.expectEqualStrings("x", std.mem.span(name2.?));
    // SAME pointer: the arena-backed name, not a per-query intern.
    try std.testing.expect(name1.? == name2.?);
    lua_pop(L, 1);

    // lua_setupvalue returns the same arena-backed name pointer.
    lua_pushinteger(L, 9);
    const setname = lua_setupvalue(L, -2, 1);
    try std.testing.expect(setname != null);
    try std.testing.expect(name1.? == setname.?);
    lua_settop(L, 0);

    // No-alloc proof: with a pre-grown stack (spare capacity — the push
    // cannot need growth) and fail_index=0, the name query still succeeds
    // — the name path allocates nothing.
    {
        s.stack.append(vm.alloc, .{ .Closure = closure }) catch return error.OutOfMemory;
        s.stack.ensureUnusedCapacity(vm.alloc, 8) catch return error.OutOfMemory;
        var failing = std.testing.FailingAllocator.init(vm.alloc, .{
            .fail_index = 0,
            .resize_fail_index = 0,
        });
        const saved = vm.alloc;
        vm.alloc = failing.allocator();
        const name = lua_getupvalue(L, -1, 1);
        vm.alloc = saved;
        try std.testing.expect(name != null);
        try std.testing.expectEqualStrings("x", std.mem.span(name.?));
        try std.testing.expectEqual(@as(i64, 9), intAt(L, -1));
        lua_settop(L, 0);
    }
}
