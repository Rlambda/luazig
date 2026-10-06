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
pub const LUA_REGISTRYINDEX: c_int = api.State.LUA_REGISTRYINDEX;

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
    extraargs: u8 = 0,
    istailcall: u8 = 0,
    ftransfer: c_int = 0,
    ntransfer: c_int = 0,
    short_src: [60]u8 = [_]u8{0} ** 60,
    i_ci: ?*anyopaque = null,
};

// The published layout must stay binary-compatible with PUC Lua 5.5's
// lua_Debug (LP64): a C client compiled against PUC's lua.h reads a
// luazig-built library through these offsets. int-typed ftransfer/ntransfer
// are part of that contract — the transfer window carries actual argument
// counts, which exceed 16 bits (a call with 70001 arguments reports
// ntransfer=70001). i_ci is an opaque encoded handle (frame index + 1),
// never a dereferenceable pointer.
comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@offsetOf(lua_Debug, "event") == 0);
        std.debug.assert(@offsetOf(lua_Debug, "name") == 8);
        std.debug.assert(@offsetOf(lua_Debug, "namewhat") == 16);
        std.debug.assert(@offsetOf(lua_Debug, "what") == 24);
        std.debug.assert(@offsetOf(lua_Debug, "source") == 32);
        std.debug.assert(@offsetOf(lua_Debug, "srclen") == 40);
        std.debug.assert(@offsetOf(lua_Debug, "currentline") == 48);
        std.debug.assert(@offsetOf(lua_Debug, "linedefined") == 52);
        std.debug.assert(@offsetOf(lua_Debug, "lastlinedefined") == 56);
        std.debug.assert(@offsetOf(lua_Debug, "nups") == 60);
        std.debug.assert(@offsetOf(lua_Debug, "nparams") == 61);
        std.debug.assert(@offsetOf(lua_Debug, "isvararg") == 62);
        std.debug.assert(@offsetOf(lua_Debug, "extraargs") == 63);
        std.debug.assert(@offsetOf(lua_Debug, "istailcall") == 64);
        std.debug.assert(@offsetOf(lua_Debug, "ftransfer") == 68);
        std.debug.assert(@offsetOf(lua_Debug, "ntransfer") == 72);
        std.debug.assert(@offsetOf(lua_Debug, "short_src") == 76);
        std.debug.assert(@offsetOf(lua_Debug, "i_ci") == 136);
        std.debug.assert(@sizeOf(lua_Debug) == 144);
        std.debug.assert(@alignOf(lua_Debug) == 8);
    }
}

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

/// PUC lauxlib.c:1060-1071 `panic`: the default panic function installed
/// by `luaL_newstate` via `lua_atpanic`. Prints the error object at the
/// throwing state's top to stderr ("PANIC: unprotected error in call to
/// Lua API (%s)"); a non-string object prints the fixed placeholder —
/// `lua_type` avoids touching a possibly-invalid object, exactly like
/// PUC's comment there. Write errors are ignored (best-effort last
/// message before the abort).
fn defaultPanic(L: ?*lua_State) callconv(.c) c_int {
    const msg: [*:0]const u8 =
        if (L != null and lua_type(L, -1) == 4) // LUA_TSTRING
            lua_tolstring(L, -1, null) orelse "error object is not a string"
        else
            "error object is not a string";
    var errw = stdio.stderr();
    errw.writeAll("PANIC: unprotected error in call to Lua API (") catch {};
    errw.writeAll(std.mem.span(msg)) catch {};
    errw.writeAll(")\n") catch {};
    return 0; // return to Lua to abort
}

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
    const h = vm.setupMainHandle() catch {
        vm.deinit();
        alloc.destroy(vm);
        return null;
    };
    // PUC luaL_newstate (lauxlib.c:1129-1137): install the default panic
    // function — the hook every unprotected terminal (luaD_throw's
    // no-handler branch, the unarmed transport's no-pad terminals) runs
    // before aborting.
    vm.c_panicf = &defaultPanic;
    return h;
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
    // PUC routes the state's allocations through the caller's lua_Alloc,
    // including the lmem.c tryagain (emergency full GC + retry on
    // failure) — see Vm.CAllocBridge. Only an explicitly provided
    // allocator gets the bridge; the default (f == NULL) keeps the plain
    // allocator.
    if (f) |bridge_fn| {
        const bridge = alloc.create(vm_mod.CAllocBridge) catch {
            vm.deinit();
            alloc.destroy(vm);
            return null;
        };
        bridge.* = .{ .alloc_fn = bridge_fn, .ud = ud, .vm = vm };
        vm.c_alloc_bridge = bridge;
        vm.alloc = bridge.allocator();
    }
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
/// `Thread.api_handle`.
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
    const result = luaNewThreadTx(parent, vm) catch |err| {
        switch (err) {
            error.OutOfMemory => cThrowOn(vm, parent, error.OutOfMemory),
            // The reserve's stack-overflow (fail() inside cWindowEnsure)
            // already installed err_obj — surface it as LUA_ERRRUN.
            error.RuntimeError => cThrowOn(vm, parent, error.Runtime),
        }
    };
    return result;
}

/// Inner transaction for lua_newthread (P16.50-review): every failure
/// returns an ERROR so the errdefer actually fires.
pub fn luaNewThreadTx(parent: *vm_mod.lua_State, vmp: *Vm) error{ OutOfMemory, RuntimeError }!*vm_mod.lua_State {
    // Reserve the parent window's push slot BEFORE the
    // fallible creation work (PUC lua_newthread pushes the new thread on
    // L->top after the object exists; the window growth must not fail
    // after publication — reserve/prepare → allocate → initialize →
    // infallible commit). cWindowEnsure only grows capacity; it does not
    // move top, so no uninitialized slot is exposed to the collector.
    const parent_th = Vm.handleThread(parent);
    vmp.cWindowEnsure(parent_th, 1) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RuntimeError => return error.RuntimeError,
        // The growth path (growBcStackCapSlow → reallocBcStackArrays) is
        // pure allocation — no dispatch, no Lua code, no GC step — so
        // error.Yield is unreachable here (same provably-non-yieldable
        // contract as lua_closeslot's apiCall arm). MainDestined is
        // unreachable by the same proof (no user code runs).
        error.Yield => unreachable,
        error.MainDestined => unreachable,
        // same proof — no user code runs in the growth path.
        error.YieldAbsorbed => unreachable,
    };
    const th = try vmp.alloc.create(vm_mod.Thread);
    // Full teardown — the allocStateHandle failure window
    // below runs AFTER initThreadBaseFrame committed the
    // base-frame arrays to the thread (plain destroy would orphan them).
    errdefer vmp.destroyUnregisteredThread(th);
    th.* = .{ .status = .suspended, .callee = .Nil };
    // Base C frame + initial stack (PUC luaE_newthread →
    // stack_init + base_ci) while UNREGISTERED — transactional, so the
    // destroy errdefer above is safe.
    try vmp.initThreadBaseFrame(th);
    vmp.gcRegisterCommit(.{ .thread = th });
    vmp.gcNoteAlloc(@sizeOf(vm_mod.Thread));
    var committed = false;
    errdefer if (committed) {
        vmp.gcUnregisterObjectRollback(.{ .thread = th });
        vmp.gcNoteFree(@sizeOf(vm_mod.Thread));
    };
    committed = true;
    // Create the coroutine handle (with its LUA_EXTRASPACE extra space
    // in front, inheriting the main thread's extra-space contents — PUC
    // lstate.c:291-293).
    const handle = try vmp.allocStateHandle(false);
    handle.* = .{ .vm = vmp, .thread = th, .is_main = false };
    th.api_handle = handle;
    // Push the thread value on the parent's window (PUC pushes it on
    // L->top). Infallible: the slot was reserved before creation.
    vmp.cWindowPush(parent_th, .{ .Thread = th }) catch unreachable;
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
    // best-effort: the window push can itself OOM).
    const result = vm.apiCloseThread(th) catch |err| switch (err) {
        error.OutOfMemory => {
            vm.setOutOfMemoryError();
            // PUC luaE_resetthread: L->top = L->stack + 1 — window count 0,
            // then seterrorobj installs the object at the (reserved) slot.
            // Best-effort push: the status (4) is still returned, only the
            // object push is lost on a nested OOM.
            th.top = Vm.cWindowBase(th);
            vm.cWindowPush(th, vm.errThread().err_obj) catch {};
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
        // unarmed raw-yield absorption raised inside the close's
        // metamethods: relay with PUC status 0 — the nearest
        // conventional pcall / embedder boundary consumes it (this
        // activation is abandoned like PUC's).
        error.YieldAbsorbed => {
            if (vm.c_error_jmp) |jb| {
                vm.c_error_status = 1; // LUA_YIELD sentinel: the raw-yield absorption fact
                _longjmp(jb, 1);
            }
            vm.panicHookAbort(vm.raw_yield_absorb_thrower);
        },
        // a main-destined closer error raised inside the close's
        // __gc/__close metamethods re-throws on MAIN's armed boundary
        // (PUC ldo.c:130-138) — lua_closethread's status return never
        // happens; the C caller of lua_closethread is abandoned. Relay.
        error.MainDestined => cRelayMainDestined(vm),
    };

    if (result.status == 0) {
        // PUC luaE_resetthread: L->top = L->stack + 1 (only the function
        // slot). lua_gettop(co) == 0 after close.
        th.top = Vm.cWindowBase(th);
        return 0; // LUA_OK
    }

    // Error: push the error object on the window (PUC luaD_seterrorobj —
    // for an ERRMEM death the object IS the fixed MEMERRMSG the close
    // transported). (b) status-returning API: lua_closethread returns the
    // close's status verbatim (PUC APIstatus — ERRRUN(2), ERRMEM(4), or
    // ERRERR(5)); PUC's seterrorobj moves the object WITHIN one stack
    // (infallible), our window push can OOM — the status is still
    // returned, only the object push is lost (P16.50-review-5 B2
    // inventory; architectural fix = reserved window slots, same family
    // as the LUA_MINSTACK reserve).
    th.top = Vm.cWindowBase(th);
    vm.cWindowPush(th, result.err) catch {};
    return result.status;
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
/// Operates on the anchored C-API windows of the two threads' stacks.
/// Negative `n` is clamped to zero. Self-move (from == to) is a no-op.
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
    const src_th = Vm.handleThread(src_h);
    const dst_th = Vm.handleThread(dst_h);
    if (count > Vm.cWindowCount(src_th)) return;
    const start = src_th.top - count;
    // Copy top `count` values from src to dst (alias-safe push: the source
    // offset is captured before any growth), then truncate src plainly
    // (PUC: `from->top.p -= n`).
    // PUC lua_xmove → luaD_growstack on dst: OOM is LUA_ERRMEM thrown on
    // the DESTINATION state (P16.50-review-5 B2 — the old `catch return`
    // silently dropped the move).
    vm.cWindowPushSlice(dst_th, src_th.stack[start..src_th.top]) catch |e|
        cThrowOn(vm, dst_h, api.mapVmError(e));
    src_th.top = start;
    // xmove safepoint — both windows must still hold
    // their live anchors (see api.State.xmove's twin check).
    if (Vm.WINDOW_DEBUG_CHECKS) {
        vm.debugCheckWindowAt(src_th, .xmove);
        vm.debugCheckWindowAt(dst_th, .xmove);
    }
}

// `_longjmp` from libc. Using `_longjmp` (not `longjmp`) matches PUC's
// `__sigsetjmp(env, 0)` no-savemask choice.
extern fn _longjmp(jb: *anyopaque, val: c_int) noreturn;

/// PUC `lua_error` (noreturn): captures the error object from the window
/// top into `c_error_value`, then `_longjmp` to the nearest C-function
/// boundary.
pub export fn lua_error(L: ?*lua_State) noreturn {
    const h = L orelse @panic("lua_error: null state");
    const vm = h.vm;
    const th = Vm.handleThread(h);
    if (Vm.cWindowCount(th) > 0) {
        vm.c_error_value = th.stack[th.top - 1];
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
    eth.err_is_oom = false;
    // (d) internal cleanup, unobservable: the thrown object is ALREADY
    // installed on eth (the fold above); invokeErrfunc's error return can
    // only be an OOM from its RootScope reserve — PUC's equivalent
    // root-push is a stack-slot store (infallible). A failure here skips
    // only the message handler and the SAME object still longjmps below,
    // which is exactly what PUC throws when its (infallible) setup exists.
    vm.invokeErrfunc() catch {};
    // C-S3: latch the raise window AFTER the message handler (its
    // transform is final now) and BEFORE the longjmp — the geometry the
    // throw leaves behind. The resume publication reads it back via
    // Vm.resumeErrorWindowIntact: an unchanged base/top pair means the
    // raising C frame survived the unwind (PUC keeps L->ci in place),
    // so the publication appends the error at the live top (PUC
    // luaD_seterrorobj) instead of collapsing the window onto
    // TBC-marked slots. eth == the raising thread == the window owner
    // (verified: handleThread(h) == h.thread orelse main here).
    eth.err_c_window = .{ .kind = .raise, .base = Vm.cWindowBase(eth), .top = eth.top, .obj = eth.err_obj };
    if (vm.c_error_jmp) |jb| {
        _longjmp(jb, 1);
    }
    @panic("lua_error called without a C function error boundary");
}

/// PUC `lua_call` (macro): expands to lua_callk(L, n, r, 0, NULL).
pub export fn lua_call(L: ?*lua_State, nargs: c_int, nresults: c_int) void {
    lua_callk(L, nargs, nresults, 0, null);
}

/// PUC `lua_callk` (lapi.c:1037-1056): call a function with optional
/// continuation. The callee and arguments are read from L's window and the
/// call EXECUTES on L's own thread (PUC luaD_call pushes the callee's
/// CallInfo on L's stack: a direct call on another thread's handle runs the
/// callee on THAT thread, with L as its running state — not on the caller's
/// thread). If k != NULL and yieldable, save k/ctx on L's current frame
/// (PUC: L->ci — for a fresh coroutine, base_ci). If k == NULL, the call is
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

    // Read callee/args from the anchored window (PUC: func = L->top -
    // (nargs+1)). The args are DUPED across the call boundary: the slice
    // would alias th.stack, which the nested execution may grow (realloc),
    // and a yield longjmps past any `defer` — the copy is freed explicitly
    // in every arm below.
    const wth = Vm.handleThread(h);
    const nargs_usize: usize = @intCast(@max(nargs, 0));
    if (Vm.cWindowCount(wth) < nargs_usize + 1) {
        if (vm.c_error_jmp) |jb| {
            vm.c_error_value = .Nil;
            _longjmp(jb, 1);
        }
        @panic("lua_call without an active C-function boundary");
    }
    const func_slot = wth.top - nargs_usize - 1;
    const callee = wth.stack[func_slot];
    const call_args = vm.alloc.dupe(vm_mod.Value, wth.stack[func_slot + 1 .. wth.top]) catch {
        if (vm.c_error_jmp) |jb| {
            vm.c_error_value = .Nil;
            _longjmp(jb, 1);
        }
        @panic("lua_call OOM without an active C-function boundary");
    };

    // Cross-thread direct call (the handle's thread is not the active
    // runtime — e.g. a host C callback on MAIN calling lua_callk(co,...)):
    // activate the handle's thread as the execution authority for the
    // whole call — the proven sync-close cross-thread pattern
    // (enterSyncCloseContext: current_thread/cur_handle switch, caller
    // status mirror, hook cache refresh). The context is restored on EVERY
    // exit, including before each _longjmp relay below: a throw from inside
    // the callee lands at the callee's own armed boundary (armed inside
    // this activation) and returns here as a Zig error first, so the
    // restore always runs before control leaves this frame.
    const cross = wth != vm.activeBytecodeThread();
    var xctx: ?Vm.SyncCloseContext = null;
    if (cross) {
        xctx = vm.enterSyncCloseContext(wth) catch {
            vm.alloc.free(call_args);
            if (vm.c_error_jmp) |jb| {
                vm.c_error_value = .Nil;
                _longjmp(jb, 1);
            }
            @panic("lua_call OOM without an active C-function boundary");
        };
    }

    // Delegate the hook-continuation check (PUC: L->ci), k/ctx saving on
    // L's current frame, and apiCall to the shared helper (lapi.c:1041-1053).
    const kfn: ?*const fn (?*vm_mod.lua_State, c_int, isize) callconv(.c) c_int = if (k) |kf|
        @ptrCast(@alignCast(kf))
    else
        null;
    // The callee's window-relative slot (PUC lua_callk: the callee sits at
    // L->top - (nargs+1); funcidx for the resume-side completion
    // publication — see luaCallKShared).
    const fn_idx = func_slot - Vm.cWindowBase(wth);

    const ret = vm.luaCallKShared(wth, callee, call_args, nresults, fn_idx, kfn, ctx) catch |err| {
        vm.alloc.free(call_args);
        // Capture the error object from the EXECUTION thread's error state
        // BEFORE the context restore (errThread() resolves through the
        // active thread; the raise installed the object on wth while the
        // switch was active).
        const err_obj: vm_mod.Value = if (err == error.RuntimeError)
            vm.errThread().err_obj
        else
            .Nil;
        // Cross-thread error transport (PUC luaD_throw's no-errorJmp
        // branch, ldo.c:129-146): an error raised on the callee's thread
        // under NO armed protection of its own — any active pcall/resume
        // on wth sits BELOW this catch on the call chain and would have
        // consumed the error first — resets the target (PUC
        // luaE_resetthread: every mark closes with the error status,
        // last-error-wins; the target dies with the final status and the
        // final object at its window) and re-throws on MAIN with the
        // final object. The shared transport (crossCloseErrorRaise — the
        // proven sync-close site's machinery) runs BEFORE the context
        // restore so the closers execute on wth through the switch; the
        // kind relays after it. For OOM the fixed ERRMEM object is
        // ensured first (idempotent — the raise usually installed it).
        var cross_md = false;
        var cross_throw: ?api.ApiError = null;
        if (xctx != null and (err == error.RuntimeError or err == error.OutOfMemory)) {
            if (err == error.OutOfMemory) vm.setOutOfMemoryError();
            const cr = if (vm.crossCloseErrorRaise(xctx.?, wth, vm.errThread().err_obj))
                error.MainDestined
            else |re|
                re;
            if (cr == error.MainDestined) cross_md = true else cross_throw =
                if (cr == error.OutOfMemory or err == error.OutOfMemory) error.OutOfMemory else error.Runtime;
        }
        if (xctx) |c| vm.restoreSyncCloseContext(c);
        switch (err) {
            error.Yield => {
                if (vm.c_error_jmp) |jb| {
                    _longjmp(jb, 2);
                }
                @panic("lua_call yield without an active C-function boundary");
            },
            error.RuntimeError, error.OutOfMemory => {
                if (cross_md) {
                    // The transport finalized wth (or a nested
                    // main-destined raise from one of its closers
                    // relayed through): MAIN's err state owns the final
                    // object; relay the kind toward MAIN's consumer
                    // (this activation is a zombie — PUC abandons
                    // intermediate activations mid-flight).
                    cRelayMainDestined(vm);
                }
                if (cross_throw) |t| {
                    // Transport machinery failure (an ordinary re-throw —
                    // the context is already restored above).
                    if (t == error.OutOfMemory) {
                        vm.setOutOfMemoryError();
                        vm.latchErrmemRaiseWindow(vm.activeBytecodeThread());
                        if (vm.c_error_jmp) |jb| {
                            vm.c_error_value = vm.errThread().err_obj;
                            vm.c_error_status = 4;
                            _longjmp(jb, 1);
                        }
                        @panic("lua_call OOM without an active C-function boundary");
                    }
                    if (vm.c_error_jmp) |jb| {
                        vm.c_error_value = err_obj;
                        _longjmp(jb, 1);
                    }
                    @panic("lua_call without an active C-function boundary");
                }
                // Same-thread call: the caller's own armed boundary
                // consumes the error directly (PUC L->errorJmp set — a
                // plain throw, no reset).
                if (vm.c_error_jmp) |jb| {
                    vm.c_error_value = err_obj;
                    _longjmp(jb, 1);
                }
                @panic("lua_call without an active C-function boundary");
            },
            // a main-destined closer error from the callee relays
            // across this C frame (longjmp value 4) toward MAIN's armed
            // boundary — this activation becomes a zombie (PUC ldo.c
            // re-throw bypasses it).
            error.MainDestined => cRelayMainDestined(vm),
            // unarmed raw-yield absorption from the callee: relay with
            // PUC status 0 — the nearest conventional pcall / embedder
            // boundary consumes it (this activation is abandoned).
            error.YieldAbsorbed => {
                if (vm.c_error_jmp) |jb| {
                    vm.c_error_status = 1; // LUA_YIELD sentinel: the raw-yield absorption fact
                    _longjmp(jb, 1);
                }
                vm.panicHookAbort(vm.raw_yield_absorb_thrower);
            },
        }
    };
    if (xctx) |c| vm.restoreSyncCloseContext(c);
    vm.alloc.free(call_args);
    // PUC poscall moveresults to the callee's func slot: fixed nresults
    // nil-fills (class 3), MULTRET copies all, 0 drops all. Freed manually
    // in the OOM arm — the _longjmp there bypasses any `defer`.
    vm.cWindowMoveResults(wth, func_slot, ret, nresults) catch {
        vm.alloc.free(ret);
        if (vm.c_error_jmp) |jb| {
            vm.c_error_value = .Nil;
            _longjmp(jb, 1);
        }
        @panic("lua_call OOM without an active C-function boundary");
    };
    vm.alloc.free(ret);
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
    // Reserve the slot BEFORE the string exists — the
    // push then hits reserved capacity and cannot sweep the constructed
    // unrooted string at a full window (emergency GC + retry).
    vm.cWindowEnsure(Vm.handleThread(h), 1) catch |e| {
        buf.deinit(vm.alloc);
        cThrowOn(vm, h, api.mapVmError(e));
    };
    const ls = vm.internStr(buf.items) catch cThrowOomBuf(vm, h, &buf);
    vm.cWindowPush(Vm.handleThread(h), .{ .String = ls }) catch cThrowOomBuf(vm, h, &buf);
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

    // Reserve the result slot BEFORE the load — the
    // closure (or error string) push then hits reserved capacity and
    // cannot sweep the constructed unrooted object at a full window.
    vm.cWindowEnsure(Vm.handleThread(h), 1) catch |e| switch (api.mapVmError(e)) {
        error.OutOfMemory => return statusCode(.memory_error),
        else => return statusCode(.runtime_error),
    };

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
    const env: Value = vm.registryGlobalsValue();

    const result = vm.loadChunk(.{ .owned = owned_bytes }, owned_bytes, name, mode_slice, env, null) catch |err| switch (err) {
        error.OutOfMemory => return statusCode(.memory_error),
        error.RuntimeError, error.Yield => return statusCode(.runtime_error),
        // loading never runs user code, so the kind is unreachable
        // here — relay (never fold) if a regression ever produces one.
        error.MainDestined => cRelayMainDestined(vm),
        // same proof — loading never raises it; relay if a regression
        // ever produces one (status 0 rides the pad).
        error.YieldAbsorbed => {
            if (vm.c_error_jmp) |jb| {
                vm.c_error_status = 1; // LUA_YIELD sentinel: the raw-yield absorption fact
                _longjmp(jb, 1);
            }
            vm.panicHookAbort(vm.raw_yield_absorb_thrower);
        },
    };
    switch (result) {
        .closure => |cl| {
            vm.cWindowPush(Vm.handleThread(h), .{ .Closure = cl }) catch return statusCode(.memory_error);
            return 0; // LUA_OK
        },
        .err_msg => |msg| {
            defer vm.alloc.free(msg);
            const errval = vm.internStr(msg) catch return statusCode(.memory_error);
            vm.cWindowPush(Vm.handleThread(h), .{ .String = errval }) catch return statusCode(.memory_error);
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

    // Get the function at the top of the window (PUC uses index2value(L, -1)).
    const dump_th = Vm.handleThread(h);
    if (Vm.cWindowCount(dump_th) == 0) return 1;
    const val = dump_th.stack[dump_th.top - 1];
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
        vm.cWindowPush(Vm.handleThread(h), .{ .Int = i }) catch |e| cThrowOn(vm, h, api.mapVmError(e));
        return str.len + 1; // PUC returns strlen(s) + 1 (including NUL)
    } else |_| {}

    // Try float (PUC's `l_str2d`): handles decimal, hex floats, inf, nan.
    if (std.fmt.parseFloat(f64, trimmed)) |n| {
        vm.cWindowPush(Vm.handleThread(h), .{ .Num = n }) catch |e| cThrowOn(vm, h, api.mapVmError(e));
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
    const st = api.State.fromHandle(L orelse return 0);
    const val = st.index2value(idx);

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
///     topmost — the frame_slot path (live slot on th.stack);
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
    // Resolve `idx` against the PASSED STATE's thread (PUC lua_toclose:
    // index2value(L, idx) + luaF_newtbcmark(L, level) — everything on L).
    // For the running thread this is the current execution's window (a C
    // function's own frame / a hook's interrupted Lua frame — the lanes
    // below); for a host call on ANOTHER thread's handle (e.g. marking a
    // fresh never-resumed coroutine before a raw f(L) call on it) it is
    // THAT thread's window — the old `current_thread orelse main_thread`
    // resolution silently marked (or no-op'd on) the WRONG thread.
    const th = Vm.handleThread(h);
    const abs_slot = Vm.cWindowSlot(th, idx) orelse return;
    // The mark goes on the topmost frame of the passed state's thread
    // (PUC: L->ci — the running activation). While a C function runs,
    // that is always its own callCFunction frame; while a debug hook
    // runs (hooks get no frame of their own — PUC luaD_hook keeps L->ci
    // = the interrupted frame), it is the interrupted Lua frame.
    const th_bc = th.call_frames;
    const chain = &th.c_tbc_chain;
    if (th_bc.len() == 0) {
        // Frameless target (a fresh never-resumed coroutine — PUC's
        // base_ci, a CIST_C frame that always exists, gets the mark).
        // No frame exists to anchor a frame_slot pair: capture the value
        // as a detached entry (nothing can execute on the target between
        // the mark and its close, so the captured value is exactly what
        // PUC's live-level entry reads at closeprotected time — the
        // unarmed raw-yield transport's reset closes it).
        const value = th.stack[abs_slot];
        vm.reserveTbcChainMark(th) catch |e| cThrowOn(vm, h, e);
        chain.appendAssumeCapacity(.{ .detached = .{ .value = value, .level = abs_slot } });
        return;
    }
    const fi = th_bc.len() - 1;
    const f = th_bc.getConstPtr(fi);
    // P16.31 Cut 5: TbcEntry is a tagged union — live marks are frame_slot
    // pairs (detached entries arise from pop-detach and the hook lane).
    if (f.isC()) {
        // C-function lane: the slot is an ABSOLUTE Thread.stack index in
        // this frame's window (PUC: a stack LEVEL on the shared L->stack).
        // Within-frame LIFO: a mark at or below the frame's chain top is a
        // PUC api_check violation — lenient ignore (idempotent re-mark).
        if (chain.items.len > 0) {
            const top = chain.items[chain.items.len - 1];
            if (top == .frame_slot and top.frame_slot.cframe_idx == fi and
                top.frame_slot.slot_idx >= abs_slot) return;
        }
        // PUC lua_toclose → luaF_newtbcmark → luaM_error: OOM is
        // LUA_ERRMEM (P16.50-review-5 B2 — the old `catch {}` silently
        // dropped the __close mark). Reserve the unwind-transfer capacity
        // BEFORE the mark exists (reserveTbcChainMark) — a failure leaves
        // no obligation and keeps the LUA_ERRMEM contract; the eventual
        // detach of this mark then never allocates.
        vm.reserveTbcChainMark(th) catch |e| cThrowOn(vm, h, e);
        chain.appendAssumeCapacity(.{ .frame_slot = .{
            .cframe_idx = fi,
            .slot_idx = abs_slot,
        } });
    } else {
        // Hook lane (PUC luaD_hook: L->ci = the interrupted Lua frame).
        // PUC marks the frame (CIST_TBC) + the slot's LEVEL in tbclist; the
        // close later reads the LIVE slot at that level. luazig captures
        // the value NOW as a detached entry: the hook's window slot is
        // unstable across later C-API operations, and Lua execution uses
        // the stack — so nothing between the hook and the close observes
        // that window slot. This is equivalent to PUC's live-level read
        // for every shape where the mark's stack level is not reused
        // before the close (a second hook event or a C call reusing the
        // level is a PUC shared-stack quirk luazig's split stacks cannot
        // — and need not — reproduce).
        const value = th.stack[abs_slot];
        // Same luaF_newtbcmark OOM contract as the frame_slot lane above
        // (reserve first — no obligation on failure). The captured level
        // is the mark's PUC tbclist LEVEL — the level, not the frame,
        // decides which boundary's close runs the closer.
        vm.reserveTbcChainMark(th) catch |e| cThrowOn(vm, h, e);
        chain.appendAssumeCapacity(.{ .detached = .{ .value = value, .level = abs_slot } });
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
    // PUC lua_closeslot resolves everything on the PASSED L (index2stack,
    // L->ci, L->tbclist): the thread a handle's C API ops address — not
    // the currently running thread (a cross-thread L closes L's own mark).
    const th = Vm.handleThread(h);
    const abs = Vm.cWindowSlot(th, idx) orelse return;
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
    const val = th.stack[abs];
    // PUC preclose(CLOSEKTOP): the closed slot becomes nil immediately.
    th.stack[abs] = .Nil;

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
    // PUC lua_closeslot(L, ...) runs the closer ON L: a cross-thread L (a
    // suspended/dead coroutine's handle driven from another thread) gets
    // the target's own close context (coroutine.running, the C API handle,
    // hooks). The same-thread fast path keeps the caller's context.
    if (th != vm.activeBytecodeThread()) {
        const ctx = vm.enterSyncCloseContext(th) catch {
            cThrowOn(vm, h, error.OutOfMemory);
            return;
        };
        var throw: ?api.ApiError = null;
        // a MainDestined raised inside the closer (a NESTED
        // cross-thread close) or by this close's own finalize must relay
        // to MAIN's armed boundary after the context restore — never fold
        // into a caller-local throw (PUC: the inner luaD_throw longjmped
        // straight to main, abandoning this close's error handling).
        var relay_main_destined = false;
        {
            defer vm.restoreSyncCloseContext(ctx);
            _ = vm.apiCall(.nonyieldable, mm.?.*, call_args[0..]) catch |e| switch (e) {
                // .nonyieldable contract: apiCall never reports error.Yield here.
                error.Yield => unreachable,
                error.MainDestined => {
                    // A nested main-destined raise already finalized its
                    // target and installed main's err state — no second
                    // finalize here.
                    relay_main_destined = true;
                },
                else => {
                    // PUC luaD_throw on the target (no armed boundary of
                    // its own): resetthread semantics + re-raise on the
                    // caller. The arm's normal exit IS the re-raise; a
                    // machinery OOM inside it overrides the transport kind.
                    const fe: Value = if (th.err_has_obj) th.err_obj else .Nil;
                    const arm_err = if (vm.crossCloseErrorRaise(ctx, th, fe)) error.MainDestined else |re| re;
                    if (arm_err == error.MainDestined) {
                        // the finalize succeeded — the re-raise is
                        // main-destined (PUC ldo.c:130-138).
                        relay_main_destined = true;
                    } else {
                        throw = if (arm_err == error.OutOfMemory or e == error.OutOfMemory)
                            error.OutOfMemory
                        else
                            error.Runtime;
                    }
                },
            };
        }
        // Caller context restored: a main-destined relay jumps to the
        // innermost pad (the object is in MAIN's err state); an ordinary
        // throw reads the caller's error object installed by
        // crossCloseErrorRaise above.
        if (relay_main_destined) cRelayMainDestined(vm);
        if (throw) |te| cThrowOn(vm, h, te);
        return;
    }
    _ = vm.apiCall(.nonyieldable, mm.?.*, call_args[0..]) catch |e| switch (e) {
        // .nonyieldable contract: apiCall never reports error.Yield here.
        error.Yield => unreachable,
        error.OutOfMemory => cThrowOn(vm, h, error.OutOfMemory),
        error.RuntimeError => cThrowOn(vm, h, error.Runtime),
        // a nested main-destined raise inside the closer (a
        // cross-thread op on another L) relays to MAIN's boundary.
        error.MainDestined => cRelayMainDestined(vm),
        // unarmed raw-yield absorption inside the metamethod: relay
        // with PUC status 0 (the nearest conventional pcall / embedder
        // boundary consumes it).
        error.YieldAbsorbed => {
            if (vm.c_error_jmp) |jb| {
                vm.c_error_status = 1; // LUA_YIELD sentinel: the raw-yield absorption fact
                _longjmp(jb, 1);
            }
            vm.panicHookAbort(vm.raw_yield_absorb_thrower);
        },
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
    // Reserve the result slot BEFORE the load — the
    // closure (or error string) push then hits reserved capacity and
    // cannot sweep the constructed unrooted object at a full window.
    vm.cWindowEnsure(Vm.handleThread(h), 1) catch |e| switch (api.mapVmError(e)) {
        error.OutOfMemory => return statusCode(.memory_error),
        else => return statusCode(.runtime_error),
    };
    const mode_slice: ?[]const u8 = if (mode) |m| std.mem.span(m) else null;
    const env: Value = vm.registryGlobalsValue();

    const result = vm.loadChunk(.{ .borrowed = buff[0..sz] }, buff[0..sz], std.mem.span(name), mode_slice, env, null) catch |err| switch (err) {
        error.OutOfMemory => return statusCode(.memory_error),
        error.RuntimeError, error.Yield => return statusCode(.runtime_error),
        // loading never runs user code, so the kind is unreachable
        // here — relay (never fold) if a regression ever produces one.
        error.MainDestined => cRelayMainDestined(vm),
        // same proof — loading never raises it; relay if a regression
        // ever produces one (status 0 rides the pad).
        error.YieldAbsorbed => {
            if (vm.c_error_jmp) |jb| {
                vm.c_error_status = 1; // LUA_YIELD sentinel: the raw-yield absorption fact
                _longjmp(jb, 1);
            }
            vm.panicHookAbort(vm.raw_yield_absorb_thrower);
        },
    };
    switch (result) {
        .closure => |cl| {
            vm.cWindowPush(Vm.handleThread(h), .{ .Closure = cl }) catch return statusCode(.memory_error);
            return 0; // LUA_OK
        },
        .err_msg => |msg| {
            defer vm.alloc.free(msg);
            const errval = vm.internStr(msg) catch return statusCode(.memory_error);
            vm.cWindowPush(Vm.handleThread(h), .{ .String = errval }) catch return statusCode(.memory_error);
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
    // Reserve the result slot BEFORE the load — the
    // closure (or error string) push then hits reserved capacity and
    // cannot sweep the constructed unrooted object at a full window.
    vm.cWindowEnsure(Vm.handleThread(h), 1) catch |e| switch (api.mapVmError(e)) {
        error.OutOfMemory => return statusCode(.memory_error),
        else => return statusCode(.runtime_error),
    };
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
    const env: Value = vm.registryGlobalsValue();

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
        // loading never runs user code — relay (never fold) if a
        // regression ever produces the kind here.
        error.MainDestined => {
            vm.alloc.free(source.name);
            if (!source_bytes_freed_by_load) vm.alloc.free(source.bytes);
            if (prefixed_buf) |b| vm.alloc.free(b);
            cRelayMainDestined(vm);
        },
        // same proof — loading never raises it; status 0 rides the pad.
        error.YieldAbsorbed => {
            vm.alloc.free(source.name);
            if (!source_bytes_freed_by_load) vm.alloc.free(source.bytes);
            if (prefixed_buf) |b| vm.alloc.free(b);
            if (vm.c_error_jmp) |jb| {
                vm.c_error_status = 1; // LUA_YIELD sentinel: the raw-yield absorption fact
                _longjmp(jb, 1);
            }
            vm.panicHookAbort(vm.raw_yield_absorb_thrower);
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
            vm.cWindowPush(Vm.handleThread(h), .{ .Closure = cl }) catch return statusCode(.memory_error);
            return 0; // LUA_OK
        },
        .err_msg => |msg| {
            defer vm.alloc.free(msg);
            const errval = vm.internStr(msg) catch return statusCode(.memory_error);
            vm.cWindowPush(Vm.handleThread(h), .{ .String = errval }) catch return statusCode(.memory_error);
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
        // LUA_ERRMEM; lowering past a TBC mark runs __close on the handle's
        // thread (PUC luaF_close(L, level, CLOSEKTOP, 0)) and a closer
        // error escapes lua_settop to the enclosing boundary (LUA_ERRRUN).
        // InvalidIndex is PUC api_check — lenient.
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        // a cross-thread closer error finalized by the truncation
        // close is destined for MAIN's armed boundary — relay across this
        // C frame (longjmp value 4), never a caller-local throw.
        error.MainDestined => cRelayMainDestined(s.vm),
        else => {},
    };
}

pub export fn lua_pop(L: ?*lua_State, n: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    if (n <= 0) return;
    // Same channel as lua_settop (PUC lua_pop = lua_settop(-n-1)): the
    // truncation close may raise LUA_ERRMEM/LUA_ERRRUN. InvalidIndex-only
    // otherwise (see block note).
    s.pop(@intCast(n)) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        // see lua_settop — relay to MAIN's armed boundary.
        error.MainDestined => cRelayMainDestined(s.vm),
        else => {},
    };
}

pub export fn lua_rotate(L: ?*lua_State, idx: c_int, n: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    s.rotate(idx, n) catch {}; // (c): in-stack rotate, InvalidIndex-only
}

pub export fn lua_copy(L: ?*lua_State, fromidx: c_int, toidx: c_int) void {
    const h = L orelse return;
    const vm = h.vm;
    var s = api.State.fromHandle(h);
    // PUC lua_copy (lapi.c:256-266): fr = index2value (a copy), to =
    // index2value target, setobj through the target. An invalid source
    // resolves to the nilvalue and really copies nil (PUC release); a .none
    // destination is PUC's api_check "invalid index" (release: setobj into
    // the nilvalue — UB) — a lenient no-op here.
    const src = s.index2value(fromidx);
    switch (s.index2target(toidx)) {
        .stack_slot => |slot| {
            const th = Vm.handleThread(h);
            th.stack[slot] = src;
        },
        .upvalue_cell => |cell| {
            // Class 13 (F7): PUC lua_copy's upvalue arm runs luaC_barrier
            // (lapi.c) — reserve BEFORE the observable store
            // (lua_setupvalue's prepare/commit contract). Open cells write
            // through to the owning stack slot, closed cells to the cell's
            // own value (Cell.set = both).
            const plan = vm.gcPrepareWriteBarrierCell(cell, src) catch |e| cThrowOn(vm, h, e);
            cell.set(vm, src);
            vm.gcCommitWriteBarrierCell(cell, src, plan);
        },
        .registry_slot => |rslot| {
            // Plain setobj with NO barrier — PUC lapi.c:264-265:
            // "LUA_REGISTRYINDEX does not need gc barrier (collector
            // revisits it before finishing collection)". The atomic re-mark
            // (gcAtomicCommon, PUC lgc.c:1553 parity) keeps a mid-cycle slot
            // store alive.
            rslot.* = src;
        },
        .none => {},
    }
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
    // PUC lua_absindex (lapi.c:166-170): pure arithmetic, no validation —
    // pseudo/positive passthrough (even beyond top), 0 → count+1, negative
    // window arithmetic (possibly negative). Infallible.
    return s.absindex(idx);
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
/// `atpanic` hook then aborts. Matches the existing lua_callk OOM
/// arm (which sets c_error_value = .Nil and _longjmps).
/// typed transport: relay a main-destined closer error across the
/// current C frame to its landing pad (PUC ldo.c:130-138: the re-throw on
/// MAIN's armed boundary, bypassing every intermediate frame). The error
/// object is already canonically owned by MAIN's thread error state
/// (installed by `crossCloseErrorRaise` before the kind started
/// propagating) — the jump carries NO payload, only the signal (longjmp
/// value 4); the landing pad's `.main_destined` arm propagates
/// `error.MainDestined` without touching the error state, leaving the
/// crossed C activation a zombie (PUC abandons it). The jump crosses
/// exactly ONE C frame — from this shim to the innermost landing pad —
/// never arbitrary Zig defers. Without an active pad there is no armed
/// boundary on the path: PUC's no-handler branch (ldo.c:139-146) calls
/// `g->panic` with the ORIGINAL throwing target L — the thread whose
/// frame the cross-thread close was truncating — with the error object
/// at ITS top (published by the unarmed raise, PUC resetthread's
/// seterrorobj); MAIN's stack is not touched (PUC copies the object onto
/// main only for the armed-mainthread re-throw, ldo.c:131-133, which took
/// the pad branch above). Mirror that: the thrower is
/// `vm.main_destined_thrower` (set by `crossCloseErrorRaise`'s unarmed
/// arm — the only raise site whose transport can reach this terminal),
/// and the hook receives the thrower's handle with its already-published
/// object.
fn cRelayMainDestined(vm: *Vm) noreturn {
    if (vm.c_error_jmp) |jb| {
        _longjmp(@ptrCast(jb), 4);
    }
    // PUC ldo.c:139-146: g->panic(ORIGINAL throwing target), not main.
    // Defensive fallback to main covers a MainDestined that did not come
    // from crossCloseErrorRaise's unarmed arm (none exists today — the
    // armed arm's transport always lands on its own pad or a Zig
    // consumer).
    const thrower = vm.main_destined_thrower orelse vm.main_thread.?;
    vm.ensureThreadApiHandle(thrower) catch {
        @panic("main-destined error without an armed C-function boundary");
    };
    cPanicOn(vm, thrower.api_handle.?, null);
}

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
                // C-S3: latch the raise window BEFORE the longjmp — the
                // structural witness for the resume publication. The
                // throwing state's top C frame is the raising frame; the
                // eligibility re-proves the geometry at the publication,
                // so a cross-thread throw whose frame is not on this
                // thread's window self-invalidates there.
                vm.latchErrmemRaiseWindow(Vm.handleThread(throwing));
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
        // a main-destined closer error is never a caller-local
        // throw — relay it across the current C frame toward MAIN's armed
        // boundary (the object is already in main's err state).
        error.MainDestined => cRelayMainDestined(vm),
        // an in-flight raw-yield absorption is never a caller-local
        // throw either — relay with PUC status 0 (the nearest
        // conventional pcall / embedder boundary consumes it).
        error.YieldAbsorbed => {
            if (vm.c_error_jmp) |jb| {
                vm.c_error_status = 1; // LUA_YIELD sentinel: the raw-yield absorption fact
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
        vm.cWindowPush(Vm.handleThread(throwing), .{ .String = vm.internStrAssume(m) }) catch {};
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
    // PUC api_check parity (lapi.c): external content must be
    // NUL-terminated at s[len] — the contract every LuaString consumer
    // of `cstr()` relies on (warnings, C-API tostring). Debug-enforced
    // assumption, exactly like PUC's api_check.
    if (std.debug.runtime_safety) std.debug.assert(s[len] == 0);
    // PUC lua_pushfstring-family: any string-construction OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch {}` silently dropped the push).
    st.pushexternalString(s, len, falloc, ud) catch |e| cThrowOn(st.vm, L.?, e);
}

// --- Type / conversion ---

pub export fn lua_type(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromHandle(L orelse return -1);
    return if (s.typeOf(idx)) |t| typeCode(t) else -1;
}

pub export fn lua_toboolean(L: ?*lua_State, idx: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    return if (s.toboolean(idx)) 1 else 0;
}

pub export fn lua_tointegerx(L: ?*lua_State, idx: c_int, isnum: ?*c_int) i64 {
    var s = api.State.fromHandle(L orelse {
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
    var s = api.State.fromHandle(L orelse {
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
    //
    // Unified window model (mirrors api.zig @"resume"). First resume: the function and
    // args are the window's top need values; the func is consumed into
    // co.callee and the window is truncated to F (the func slot) so the
    // trampoline stages the body there (PUC resume: ccall(L, firstArg - 1,
    // ...) uses func+args in place; there is NO base_ci repositioning in
    // PUC 5.5 — verified: ldo.c has only the ccall and L->top.p =
    // firstArg). Re-resume: the args are the window's top nargs values
    // (PUC: firstArg = L->top - n); F is the remembered func slot (PUC
    // ci->func, which stays valid across suspensions).
    const first_resume = !co.started;
    const th = Vm.handleThread(h);
    var func_slot: usize = undefined;
    var args: []const vm_mod.Value = undefined;
    const nargs_usize: usize = @intCast(@max(nargs, 0));
    if (first_resume) {
        const callee_needed = !api.isCallableValue(vm, co.callee);
        const need = nargs_usize + @as(usize, @intFromBool(callee_needed));
        const cnt = Vm.cWindowCount(th);
        if (cnt < need) return 2;
        func_slot = Vm.cWindowBase(th) + cnt - need;
        if (callee_needed) {
            const callee = th.stack[func_slot];
            if (!api.isCallableValue(vm, callee)) return 2;
            co.callee = callee;
        }
        // P15.83j: remember the function position (PUC ci->func). Every
        // later resume anchors its result/error window at it.
        co.resume_func_slot = func_slot;
        args = th.stack[func_slot + need - nargs_usize .. func_slot + need];
        // Consume func+args: the trampoline stages the body at the lowered
        // top = F (PUC precall uses them in place).
        th.top = func_slot;
    } else {
        const cnt = Vm.cWindowCount(th);
        if (cnt < nargs_usize) return 2;
        func_slot = co.resume_func_slot orelse (Vm.cWindowBase(th) + cnt - nargs_usize);
        args = th.stack[th.top - nargs_usize .. th.top];
    }
    // PUC resume: only a suspended (or never-started) thread resumes;
    // anything else is resume_error (ldo.c:970-977: pop the arguments,
    // append the message once, return BEFORE the *nresults assignment).
    const reject_before_call = !first_resume and co.status != .suspended;

    // Switch cur_handle to the coroutine's handle so that C functions
    // called during the coroutine's execution see the coroutine's handle
    // as their L parameter. This mirrors PUC Lua where lua_resume
    // operates on the coroutine's L, and C functions called within it use
    // that same L.
    const saved_cur_handle = vm.cur_handle;
    vm.cur_handle = h;
    defer {
        vm.cur_handle = saved_cur_handle;
    }

    // P16.50-review-7 BLOCKER 4: apiResumeThread returns the resume's
    // EXACT tuple ([ok] ++ values) as an owned slice — the old 64-slot
    // window truncated every C-API resume to 63 results (PUC lua_resume
    // returns ALL results on the stack). Freed via vm.alloc.free (the
    // charged-block registry passes infraAlloc'd blocks through).
    const res = vm.apiResumeThread(co, args) catch |e| {
        // an unarmed raw-yield absorption escaping the resume (PUC: the
        // rethrow rides MAINTH's pad chain and BYPASSES lua_resume
        // entirely — its own error publication never runs for it):
        // restore the handle and relay with the LUA_YIELD sentinel —
        // the nearest conventional pcall / embedder boundary consumes
        // it. This activation is abandoned like PUC's.
        if (e == error.YieldAbsorbed) {
            vm.cur_handle = saved_cur_handle;
            if (vm.c_error_jmp) |jb| {
                vm.c_error_status = 1; // LUA_YIELD sentinel: the absorption fact
                _longjmp(jb, 1);
            }
            // No pad anywhere: PUC ldo.c:139-146 — the panic hook runs
            // with the transport target (recorded in
            // raw_yield_absorb_thrower), then the abort.
            vm.panicHookAbort(vm.raw_yield_absorb_thrower);
        }
        // typed transport: a main-destined closer error escaping the
        // resume (the driven coroutine's caller frames are zombies; the
        // object is in MAIN's err state) relays across this C frame to the
        // innermost landing pad (PUC ldo.c:130-138: the re-throw on MAIN's
        // armed boundary — lua_resume's own error publication NEVER runs
        // for it). The cur_handle restore is manual: the relay's longjmp
        // bypasses the defer above.
        if (e == error.MainDestined) {
            vm.cur_handle = saved_cur_handle;
            cRelayMainDestined(vm);
        }
        // apiResumeThread itself failed (owned-slice OOM): the resume's
        // error tail already ran inside apiResumeThread (the thread is
        // dead with its error latched); PUC's transport is infallible
        // (stack writes), so this arm is a best-effort publication of
        // the FIXED pre-interned MEMERRMSG (the intern is a no-alloc
        // lookup, only the window growth can fail). The C-S3 latch is
        // the structural witness read through the shared eligibility:
        // when the raiser's C window survived the throw (an in-coroutine
        // C-API OOM), the fixed object is appended at the LIVE top —
        // the window, TBC-marked slots included, stays observable for
        // lua_closethread exactly like PUC luaD_seterrorobj(ERRMEM).
        // Ineligible (no live raising C window — the raise popped the
        // frame or moved the window): anchor at the TOP frame's base
        // like the main arm's reconstruction (the old func_slot anchor
        // sits BELOW the surviving top frame's base whenever the
        // raiser's frame is still on the stack, leaving top < base and
        // underflowing every later window count).
        if (Vm.resumeErrorWindowIntact(co)) {
            // (b): the append is best-effort under OOM — the status
            // below survives; only the observable window is lost.
            if (vm.oom_msg_str) |ms| vm.cWindowPush(th, .{ .String = ms }) catch {};
        } else {
            th.top = Vm.cWindowBase(th);
            if (vm.oom_msg_str) |ms| vm.cWindowPush(th, .{ .String = ms }) catch {};
        }
        if (nres) |p| p.* = @intCast(Vm.cWindowCount(th));
        return 4; // LUA_ERRMEM
    };
    defer vm.alloc.free(res);
    const ok = res.len > 0 and res[0] == .Bool and res[0].Bool;

    if (!ok) {
        if (res.len < 2) {
            // C-S3 hygiene: a malformed failure tuple never reaches the
            // publication below — drop any latch the resume left.
            co.err_c_window = null;
            if (nres) |p| p.* = @intCast(Vm.cWindowCount(th));
            return 2;
        }
        if (reject_before_call) {
            // PUC resume_error (ldo.c:895-903): pop the pushed args
            // (plain pop — the engine rejected before running), append
            // the message once, leave *nresults untouched.
            th.top -= @min(nargs_usize, th.top - Vm.cWindowBase(th));
            // (b) status-returning API: the status (2) is returned
            // regardless; only the observable window is lost on OOM.
            vm.cWindowPush(th, res[1]) catch {};
            return 2;
        }
        // Real error inside the coroutine. PUC lua_resume's error arm
        // (ldo.c:991): luaD_seterrorobj APPENDS the error object at the
        // CURRENT top of the coroutine's frozen window — the window
        // [ci->func+1, top) the throw left behind survives until
        // lua_closethread (luaE_resetthread closes TBC marks on the
        // ORIGINAL objects with the original error; a closer error is
        // last-error-wins). Two publication shapes:
        //
        // - Eligible C-API raise (lua_error / testC error, latch intact:
        //   the raiser's C frame and window survived the unwind): append
        //   res[1] ONCE — the PUC duplicate of top-1. The full window
        //   (marked objects included) stays observable for
        //   lua_gettop/-1 indexing until the close.
        //
        // - Ineligible (Lua-frame raise via luaG_runerror — the [err, err]
        //   pair only, raw C body whose frame the error return popped
        //   (P1), handler-transformed geometry, or a moved window):
        //   reconstruct [residue?, err, err] at the TOP frame's base
        //   (PUC *nresults = top - (ci->func+1) with L->ci = the frame
        //   the throw left; a C-continuation error keeps k's C-frame on
        //   top, a Lua-body error leaves the base frame). Known
        //   divergence documented in STATUS.md P15.83q.
        if (Vm.resumeErrorWindowIntact(co)) {
            // (b): the append is best-effort under OOM — the status
            // below survives; only the observable window is lost.
            vm.cWindowPush(th, res[1]) catch {};
        } else {
            th.top = Vm.cWindowBase(th);
            // (b): the [residue?, err, err] window appends — the status
            // below survives an append OOM; only the observable window
            // is lost.
            if (co.api_err_residue) |r| vm.cWindowPush(th, r) catch {};
            vm.cWindowPush(th, res[1]) catch {};
            vm.cWindowPush(th, res[1]) catch {};
        }
        // PUC: *nresults = L->top - (L->ci->func + 1) — the visible window
        // (== lua_gettop(L) after the return; the class-6 pin is tolerant:
        // nres >= 2 with the top two values equal).
        if (nres) |p| p.* = @intCast(Vm.cWindowCount(th));
        // PUC APIstatus: the thread's own status (mirrored by
        // builtinCoroutineResume's error tail — ERRMEM=4 included since
        // P16.50-review-5 B1), ERRERR (5), else ERRRUN (2).
        return if (co.api_status != 0) co.api_status else if (co.err_is_errerr) 5 else 2;
    }

    if (co.status == .suspended) {
        // Yield: the yielded values are already parked at the suspended
        // frame's window top — the dynamically anchored window (top
        // frame's func, PUC L->ci->func) IS the host-visible result, so
        // the window is left untouched (any materialization below F would
        // overwrite the parked frame's registers). *nresults = nyield
        // (PUC ldo.c:996: L->ci->u2.nyield — NOT a stack-derived count;
        // hook yields report 0 while the window shows the register file).
        // PUC lua_resume: the caller reads EXACTLY nyield values at the
        // thread's stack top. A recovery suspension (a yielding closer
        // parked the pcall frame mid-recovery-close) can leave close-
        // staging residue ABOVE the parked payload; republish the yielded
        // values into the top nres slots — a value-identical no-op when
        // the top already holds them (every other suspension class).
        const nyield = res.len - 1;
        if (nyield > 0) {
            const cnt = Vm.cWindowCount(th);
            if (cnt >= nyield) {
                @memcpy(th.stack[th.top - nyield .. th.top], res[1..]);
            } else {
                for (res[1..]) |v| vm.cWindowPush(th, v) catch break;
            }
        }
        if (nres) |p| p.* = @intCast(res.len - 1);
        return 1; // LUA_YIELD
    }
    // Completion: PUC poscall moves the results to the body frame's func
    // slot F (MULTRET — all results; fixed counts nil-fill, class 3).
    vm.cWindowMoveResults(th, func_slot, res[1..], -1) catch {
        // PUC luaD_poscall moves results within ONE stack (infallible);
        // our move can OOM — report LUA_ERRMEM with the fixed MEMERRMSG
        // object installed instead of silently reporting LUA_OK with
        // missing results (P16.50-review-5 B2).
        vm.setOutOfMemoryError();
        if (nres) |p| p.* = 0;
        return 4;
    };
    // PUC: *nresults = L->top - (base_ci->func + 1) == lua_gettop(L).
    if (nres) |p| p.* = @intCast(Vm.cWindowCount(th));
    return 0; // LUA_OK
}

/// PUC `lua_yieldk` (ldo.c:1006-1034): yield from a coroutine.
/// nresults values on the window are returned to the resume caller.
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

    // Read the yielded values from the anchored window (PUC: api_checkpop
    // + L->top - nresults). The values stay in place: builtinCoroutineYield
    // parks a stack-resident SPAN (PUC lua_yieldk saves only the count; the
    // values remain on the yielding thread's stack).
    const th = Vm.handleThread(h);
    const nresults_usize: usize = @intCast(@max(nresults, 0));
    if (nresults_usize > Vm.cWindowCount(th)) return 2;
    const base = th.top - nresults_usize;

    // Delegate nyield + k/ctx saving + apiYield to the shared helper
    // (PUC ldo.c:1019-1029). The helper saves nyield on the top C-frame,
    // saves k/ctx (unless a debug hook), and calls apiYield which calls
    // builtinCoroutineYield. On success, apiYield returns error.Yield.
    const kfn: ?*const fn (?*vm_mod.lua_State, c_int, isize) callconv(.c) c_int = if (k) |kf|
        @ptrCast(@alignCast(kf))
    else
        null;

    // PUC lua_yieldk's unarmed arm: when L runs under NO armed protection
    // of its own (L->errorJmp == NULL — a fresh never-resumed target called
    // raw from host C), luaD_throw(L, LUA_YIELD) takes the no-errorJmp path
    // (ldo.c:130-138): the target is RESET, its base func slot value is
    // copied to MAIN's top, and the throw re-enters MAIN's armed boundary
    // with status LUA_OK — the yield core never runs (no parking: the
    // window is discarded by the reset). The yieldable check still
    // precedes everything (a non-yieldable target falls through to the
    // core's "attempt to yield" rejection, PUC ldo.c:1013-1017).
    if (!th.in_resume and th.yieldable()) {
        vm.unarmedRawYieldTransport(th);
    }

    vm.luaYieldKShared(th, th.stack[base..th.top], nresults, kfn, ctx) catch |err| switch (err) {
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
        // relay a main-destined closer error toward MAIN's armed
        // boundary (the yield machinery itself never raises it; the arm
        // keeps the kind unfolded if a nested path ever produces one).
        error.MainDestined => cRelayMainDestined(vm),
        // same proof — the yield machinery itself never raises it;
        // status 0 rides the pad if a nested path ever produces one.
        error.YieldAbsorbed => {
            if (vm.c_error_jmp) |jb| {
                vm.c_error_status = 1; // LUA_YIELD sentinel: the raw-yield absorption fact
                _longjmp(jb, 1);
            }
            vm.panicHookAbort(vm.raw_yield_absorb_thrower);
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
    h.vm.cWindowPush(Vm.handleThread(h), .{ .Thread = th }) catch |e| cThrowOn(h.vm, h, api.mapVmError(e));
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
    return s.vm.gcControlRelay(what, data, -1) catch |e| switch (e) {
        // PUC lua_gc → luaC_fullgc/GCTM → luaD_throw: a main-destined
        // closer error raised by a finalizer (the GC running on a
        // coroutine) re-throws on MAIN's armed boundary, crossing this
        // lua_gc C frame (ldo.c:130-138). Relay the same way (pad-4
        // longjmp to the innermost landing pad); OOM stays absorbed at
        // this i32 boundary (pre-existing documented trade-off).
        error.MainDestined => cRelayMainDestined(s.vm),
        // an unarmed raw-yield absorption from a finalizer crosses this
        // lua_gc C frame the same way (PUC: the rethrow rides MAINTH's
        // pad chain and bypasses lua_gc entirely): relay with PUC status
        // 0 — the nearest conventional pcall / embedder boundary consumes
        // it (this activation is abandoned like PUC's).
        error.YieldAbsorbed => {
            if (s.vm.c_error_jmp) |jb| {
                s.vm.c_error_status = 1; // LUA_YIELD sentinel: the raw-yield absorption fact
                _longjmp(jb, 1);
            }
            s.vm.panicHookAbort(s.vm.raw_yield_absorb_thrower);
        },
    };
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
/// boundary). If errfunc != 0, the error handler is pushed onto stack
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
            const wth0 = Vm.handleThread(h);
            const abs0 = Vm.cWindowSlot(wth0, errfunc) orelse return 2;
            const saved0 = wth0.errfunc;
            // PUC savestack discipline: arm the client's own slot index,
            // not a staged copy (lapi.c:1081-1087 — the index survives
            // every stack realloc; the slot stays valid for the whole
            // conventional extent).
            wth0.errfunc = abs0;
            defer wth0.errfunc = saved0;
            var s = api.State.fromHandle(h);
            // a conventional pcall never consumes a main-destined
            // error on a non-main L — relay toward MAIN's boundary.
            const st0 = s.pcall(@intCast(@max(nargs, 0)), nresults) catch |pe| switch (pe) {
                error.MainDestined => cRelayMainDestined(vm),
                error.YieldAbsorbed => {
                    if (vm.c_error_jmp) |jb| {
                        vm.c_error_status = 1; // LUA_YIELD sentinel
                        _longjmp(jb, 1);
                    }
                    vm.panicHookAbort(vm.raw_yield_absorb_thrower);
                },
            };
            return statusCode(st0);
        }
        var s = api.State.fromHandle(h);
        const st0 = s.pcall(@intCast(@max(nargs, 0)), nresults) catch |pe| switch (pe) {
            error.MainDestined => cRelayMainDestined(vm),
            error.YieldAbsorbed => {
                if (vm.c_error_jmp) |jb| {
                    vm.c_error_status = 1; // LUA_YIELD sentinel
                    _longjmp(jb, 1);
                }
                vm.panicHookAbort(vm.raw_yield_absorb_thrower);
            },
        };
        return statusCode(st0);
    };

    if (k == null or !th.yieldable()) {
        // ── Conventional pcall (setjmp/longjmp boundary) ──
        // PUC: if errfunc != 0, set L->errfunc = func (the client's slot
        // index — savestack, lapi.c:1081-1087) for the duration; the raise
        // machinery reads the handler straight from that slot.
        if (errfunc != 0) {
            const wth1 = Vm.handleThread(h);
            const abs1 = Vm.cWindowSlot(wth1, errfunc) orelse return 2;
            const saved_errfunc = th.errfunc;
            wth1.errfunc = abs1;
            defer th.errfunc = saved_errfunc;
            var s = api.State.fromHandle(h);
            // see the no-thread arm above.
            const st1 = s.pcall(@intCast(@max(nargs, 0)), nresults) catch |pe| switch (pe) {
                error.MainDestined => cRelayMainDestined(vm),
                error.YieldAbsorbed => {
                    if (vm.c_error_jmp) |jb| {
                        vm.c_error_status = 1; // LUA_YIELD sentinel
                        _longjmp(jb, 1);
                    }
                    vm.panicHookAbort(vm.raw_yield_absorb_thrower);
                },
            };
            return statusCode(st1);
        } else {
            var s = api.State.fromHandle(h);
            const st1 = s.pcall(@intCast(@max(nargs, 0)), nresults) catch |pe| switch (pe) {
                error.MainDestined => cRelayMainDestined(vm),
                error.YieldAbsorbed => {
                    if (vm.c_error_jmp) |jb| {
                        vm.c_error_status = 1; // LUA_YIELD sentinel
                        _longjmp(jb, 1);
                    }
                    vm.panicHookAbort(vm.raw_yield_absorb_thrower);
                },
            };
            return statusCode(st1);
        }
    }

    // ── Yieldable pcall: delegate to shared helper ──
    // PUC lua_pcallk yieldable path (lapi.c:1097-1117): save k/ctx/funcidx/
    // old_errfunc/OAH on L->ci, set CIST_YPCALL, call the callee. On normal
    // return, clear CIST_YPCALL + restore errfunc. On error/yield, C-frame
    // stays for precover.
    //
    // Read callee/args from the window and compute errfunc_val, then delegate
    // the production lifecycle (k/ctx/funcidx/old_errfunc/OAH/YPCALL saving
    // + apiCall + normal-return cleanup) to luaPcallKShared.
    const wth = Vm.handleThread(h);
    const nargs_usize: usize = @intCast(@max(nargs, 0));
    if (Vm.cWindowCount(wth) < nargs_usize + 1) return 2;
    const fn_idx = Vm.cWindowCount(wth) - nargs_usize - 1;
    const func_slot = Vm.cWindowBase(wth) + fn_idx;
    const callee = wth.stack[func_slot];
    // Dupe the args across the call boundary (the slice would alias
    // th.stack, which the nested execution may grow); a yield/error
    // longjmp bypasses `defer`, so every arm below frees it explicitly.
    const call_args = vm.alloc.dupe(vm_mod.Value, wth.stack[func_slot + 1 .. wth.top]) catch {
        vm.setOutOfMemoryError();
        return 4; // LUA_ERRMEM
    };
    const errfunc_slot: ?usize = if (errfunc != 0) blk: {
        const abs = Vm.cWindowSlot(wth, errfunc) orelse {
            vm.alloc.free(call_args);
            return 2;
        };
        break :blk abs;
    } else null;

    const kfn: *const fn (?*vm_mod.lua_State, c_int, isize) callconv(.c) c_int =
        @ptrCast(@alignCast(k.?));

    const ret = vm.luaPcallKShared(th, callee, call_args, errfunc_slot, fn_idx, nresults, kfn, ctx) catch |err| {
        vm.alloc.free(call_args);
        switch (err) {
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
                th.errfunc = fr2.u.c.old_errfunc;
                return if (vm.errThread().err_is_errerr) 5 else 2;
            },
            error.OutOfMemory => {
                // PUC: the yieldable branch has NO local catch — an ERRMEM
                // longjmps to the nearest protected boundary with the
                // status (luaD_throw(LUA_ERRMEM)), which for a pcallk
                // inside a running coroutine is the resume boundary:
                // precover → finishpcallk → k(LUA_ERRMEM, memerrmsg).
                // Mirror the RuntimeError arm: install the fixed MEMERRMSG
                // object, record the status, and longjmp — the CIST_YPCALL
                // frame stays armed so the recovery owns the continuation.
                if (vm.c_error_jmp) |jb| {
                    vm.setOutOfMemoryError();
                    // C-S3: latch the raise window (the pcallk caller's
                    // top C frame is the raising frame). A recovery
                    // (precover → finishpcallk) consumes the latch with
                    // the error; only an unrecovered crossing reaches a
                    // publication, where the latch is the eligibility
                    // witness.
                    vm.latchErrmemRaiseWindow(th);
                    vm.c_error_value = vm.errThread().err_obj;
                    vm.c_error_status = 4; // LUA_ERRMEM
                    _longjmp(jb, 1);
                }
                // No C-function boundary — fallback cleanup (the recovery
                // machinery cannot run without one).
                const fr2 = th.call_frames.getPtr(th.call_frames.len() - 1);
                fr2.clearYpcall();
                th.errfunc = fr2.u.c.old_errfunc;
                // (b) status-returning: LUA_ERRMEM is the specified OOM status.
                // Install the FIXED MEMERRMSG object (allocation-free) so the
                // error state is observable — the raw `try` OOMs inside apiCall
                // do not install it themselves.
                vm.setOutOfMemoryError();
                return 4; // LUA_ERRMEM
            },
            // a main-destined closer error bypasses the armed
            // YPCALL frame (PUC ldo.c:130-138 — the re-throw is on MAIN's
            // boundary; this pcallk's C-frame stays armed as a zombie,
            // exactly like PUC's abandoned CIST_YPCALL activation) —
            // relay across this C frame, no local cleanup.
            error.MainDestined => cRelayMainDestined(vm),
            // an unarmed raw-yield absorption bypasses the armed YPCALL
            // frame the same way (PUC: the rethrow rides MAINTH's pad
            // chain): relay with PUC status 0, no local cleanup — the
            // nearest conventional pcall / embedder boundary consumes it.
            error.YieldAbsorbed => {
                if (vm.c_error_jmp) |jb| {
                    vm.c_error_status = 1; // LUA_YIELD sentinel: the raw-yield absorption fact
                    _longjmp(jb, 1);
                }
                vm.panicHookAbort(vm.raw_yield_absorb_thrower);
            },
        }
    };
    vm.alloc.free(call_args);
    defer vm.alloc.free(ret);

    // Put results on the window at the callee's func slot (PUC poscall:
    // fixed nresults nil-fills, class 3; MULTRET copies all).
    vm.cWindowMoveResults(wth, func_slot, ret, nresults) catch {
        // PUC moves results within one stack (infallible); our move can
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
    // P16.50-review-13: PUC lua_setmetatable has no ordinary failure-return
    // — its barrier and luaC_checkfinalizer are infallible. The unified
    // prepare→store→commit transaction moved every fallible step BEFORE the
    // observable store, so an allocation failure is now a protected-transport
    // LUA_ERRMEM (with the fixed MEMERRMSG) rather than a swallowed `0`.
    // Type/InvalidIndex/InvalidState remain PUC api_check preconditions —
    // lenient 0.
    s.setmetatable(objindex) catch |e| switch (e) {
        error.OutOfMemory => return cThrowOn(s.vm, L.?, e),
        else => return 0,
    };
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
    // setiuservalue runs the PUC backward barrier
    // (luaC_barrierback) around the uservalue store — its grayagain
    // reservation can fail, so OOM → LUA_ERRMEM;
    // InvalidState/InvalidIndex remain PUC api_check — lenient false.
    return if (s.setiuservalue(idx, @intCast(@max(n, 0))) catch |e| switch (e) {
        error.OutOfMemory => cThrowOn(s.vm, L.?, e),
        else => false,
    }) 1 else 0;
}

pub export fn lua_getiuservalue(L: ?*lua_State, idx: c_int, n: c_int) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC lapi.c: n outside [1, nuvalue] or a non-userdata target pushes
    // nil and returns LUA_TNONE (-1); OOM (the push) is LUA_ERRMEM.
    const t = s.getiuservalue(idx, @intCast(@max(n, 0))) catch |e| switch (e) {
        error.OutOfMemory => cThrowOn(s.vm, L.?, e),
        else => return 0,
    };
    return if (t) |tt| typeCode(tt) else -1; // LUA_TNONE
}

// --- lauxlib ---

pub export fn luaL_checklstring(L: ?*lua_State, arg: c_int, l: ?*usize) [*:0]const u8 {
    var s = api.State.fromHandle(L orelse {
        if (l) |p| p.* = 0;
        return "";
    });
    // PUC luaL_checklstring (lauxlib.c:408-412): lua_tolstring (numbers
    // convert IN PLACE through the unified resolver — stack slots, upvalue
    // cells, the registry slot) + tag_error on NULL: a raise, never a
    // silent "" (the old lenient "" misreported "missing string" as an
    // empty one). OOM inside the conversion is LUA_ERRMEM.
    const bytes = s.checklstring(arg) catch |e| cThrowOn(s.vm, L.?, e);
    if (bytes) |b| {
        if (l) |p| p.* = b.len;
        return @ptrCast(@constCast(b.ptr));
    }
    // PUC tag_error(L, arg, LUA_TSTRING): luaL_typeerror → luaL_argerror —
    // the common argument error (function name, method/self, where-prefix).
    // luaL_typeerror always raises through lua_error (noreturn) for a
    // non-null state, which `s` above already proved.
    _ = luaL_typeerror(L, arg, "string");
    unreachable;
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
    // PUC luaL_ref: OOM inside the rawseti pair is luaM_error →
    // LUA_ERRMEM, never a silent LUA_NOREF.
    return s.ref(t) catch |e| cThrowOn(s.vm, L.?, e);
}

pub export fn luaL_unref(L: ?*lua_State, t: c_int, ref: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    // PUC luaL_unref: OOM inside the rawseti pair is luaM_error →
    // LUA_ERRMEM (the old swallow could leave a half-recycled freelist).
    s.unref(t, ref) catch |e| cThrowOn(s.vm, L.?, e);
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
        // getRegisteredMetatable/setmetatable OOM → LUA_ERRMEM (the
        // setmetatable transaction is prepare→store→commit since
        // P16.50-review-13 — no post-commit swallow remains).
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
    vm.cWindowEnsure(Vm.handleThread(h), @intCast(@max(sz, 0))) catch {
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
    // PUC lauxlib.c:415-423: absent/nil → def; everything else is
    // luaL_checklstring (numbers convert in place through the unified
    // resolver; a non-convertible value raises the common argument error).
    return luaL_checklstring(L, arg, l);
}

pub export fn luaL_checkoption(L: ?*lua_State, arg: c_int, def: ?[*:0]const u8, lst: [*]const ?[*:0]const u8) c_int {
    // PUC luaL_checkoption (lauxlib.c:366-377): the option name comes from
    // luaL_optstring/luaL_checkstring — both lua_tolstring-based, so a
    // NUMBER argument converts IN PLACE through the unified resolver
    // (upvalue cells and the registry slot mutate like stack slots).
    var bytes: [:0]const u8 = undefined;
    if (def) |d| {
        bytes = std.mem.span(luaL_optlstring(L, arg, d, null));
    } else {
        bytes = std.mem.span(luaL_checklstring(L, arg, null));
    }
    var i: usize = 0;
    while (lst[i] != null) : (i += 1) {
        if (std.mem.eql(u8, bytes, std.mem.span(lst[i].?))) return @intCast(i);
    }
    // PUC lauxlib.c:374-375: the invalid option goes through the common
    // argument error. luaL_argerror always raises through lua_error
    // (noreturn) for a non-null state; both luaL_optlstring and
    // luaL_checklstring above returned a real string for `bytes`, so the
    // state is live here.
    const msg = lua_pushfstring(L, "invalid option '%s'", bytes.ptr);
    _ = luaL_argerror(L, arg, msg);
    unreachable;
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
    // Reserve the result slot BEFORE the string exists —
    // the push then hits reserved capacity and cannot sweep the constructed
    // unrooted string at a full window.
    vm.cWindowEnsure(Vm.handleThread(h), 1) catch |e| cThrowOn(vm, h, api.mapVmError(e));
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
            vm.cWindowPush(Vm.handleThread(h), .{ .String = ls }) catch |e| cThrowOn(vm, h, api.mapVmError(e));
            return;
        }
    }
    // Fallback: empty string (PUC pushes "" when no info is available)
    const ls = vm.internStr("") catch |e| cThrowOn(vm, h, e);
    vm.cWindowPush(Vm.handleThread(h), .{ .String = ls }) catch |e| cThrowOn(vm, h, api.mapVmError(e));
}

pub export fn luaL_typeerror(L: ?*lua_State, arg: c_int, tname: [*:0]const u8) c_int {
    // PUC lauxlib.c:197-208: the "T expected, got X" extra message names
    // the ARGUMENT's type — the __name metafield when it is a string, the
    // special "light userdata" spelling, or the type name ("no value" for
    // a missing argument) — and raises through the common luaL_argerror.
    var typearg: ?[*:0]const u8 = null;
    if (luaL_getmetafield(L, arg, "__name") == api.typeCode(.string)) {
        typearg = lua_tolstring(L, -1, null);
    }
    if (typearg == null) {
        if (lua_type(L, arg) == api.typeCode(.lightuserdata)) {
            typearg = "light userdata";
        } else {
            typearg = lua_typename(L, lua_type(L, arg));
        }
    }
    const msg = lua_pushfstring(L, "%s expected, got %s", tname, typearg);
    return luaL_argerror(L, arg, msg);
}

pub export fn luaL_argerror(L: ?*lua_State, arg: c_int, extramsg: ?[*:0]const u8) c_int {
    // PUC lauxlib.c:171-194: the message names the level-0 frame (this C
    // function) — getinfo "nt" reads the caller's call site; an argument
    // that is one of the __call-chain's shifted extras keeps its original
    // number ("bad extra argument #N"); otherwise the numbering drops the
    // chain count (arg -= extraargs) and a method call then shifts past
    // the implicit self ("calling 'name' on bad self" when the self itself
    // is the bad argument); an unnamed function falls back to
    // pushglobalfuncname (the registry _LOADED search) or '?'. luaL_error
    // prepends the where-prefix of the Lua caller (level 1). No level-0
    // frame at all: the bare "bad argument #n (msg)" form.
    var ar: lua_Debug = .{};
    if (lua_getstack(L, 0, &ar) == 0) {
        return luaL_error(L, "bad argument #%d (%s)", arg, extramsg);
    }
    _ = lua_getinfo(L, "nt", &ar);
    var argnum = arg;
    var argword: [*:0]const u8 = "argument";
    if (arg <= @as(c_int, ar.extraargs)) {
        argword = "extra argument";
    } else {
        argnum -= ar.extraargs;
        if (ar.namewhat) |nw| {
            if (std.mem.eql(u8, std.mem.span(nw), "method")) {
                argnum -= 1;
                if (argnum == 0) {
                    return luaL_error(L, "calling '%s' on bad self (%s)", ar.name, extramsg);
                }
            }
        }
    }
    var name: [*:0]const u8 = "?";
    if (ar.name) |n| {
        name = n;
    } else if (L) |h| {
        // PUC pushglobalfuncname: search registry._LOADED for the level-0
        // frame's function ("lib.field"; the "_G" module covers globals,
        // printed unqualified). The name bytes are copied into buf — no
        // rooting window needed on this cold error path.
        const vm = h.vm;
        const th = vm.current_thread orelse vm.main_thread orelse {
            return luaL_error(L, "bad %s #%d to '%s' (%s)", argword, argnum, name, extramsg);
        };
        const ci_raw = if (ar.i_ci) |ci| @intFromPtr(ci) else 0;
        if (ci_raw != 0 and ci_raw - 1 < th.call_frames.len()) {
            const fr = th.call_frames.getConstPtr(ci_raw - 1);
            if (fr.func_slot < th.stack.len) {
                var name_buf: [128]u8 = undefined;
                if (vm.pushGlobalFuncName(&name_buf, th.stack[fr.func_slot])) |found| {
                    // found.len < name_buf.len (pushGlobalFuncName bounds
                    // it); NUL-terminate the copy for the %s argument.
                    name_buf[found.len] = 0;
                    name = @ptrCast(&name_buf);
                }
            }
        }
    }
    return luaL_error(L, "bad %s #%d to '%s' (%s)", argword, argnum, name, extramsg);
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
    // (a `catch return`/`catch {}` site would leak the buffer and/or
    // silently drop the traceback push).
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    // Reserve the result slot BEFORE the buffer is
    // interned — the push then hits reserved capacity and cannot sweep
    // the constructed unrooted string at a full window.
    vm.cWindowEnsure(Vm.handleThread(h), 1) catch |e| {
        buf.deinit(vm.alloc);
        cThrowOn(vm, h, api.mapVmError(e));
    };

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
    vm.cWindowPush(Vm.handleThread(h), .{ .String = ls }) catch cThrowOomBufU(vm, h, &buf);
    buf.deinit(vm.alloc);
}

/// PUC `luaL_tolstring` (lauxlib.c:866-889): convert any value to a string,
/// ALWAYS pushing the result (every branch pushes exactly one value) and
/// returning the pushed string's bytes. Shape:
///   - absindex FIRST (the __tostring call and the branch pushes move the
///     stack — a relative idx must be pinned; pseudo indices pass through);
///   - `__tostring` metamethod through luaL_callmeta (its result must be a
///     string — a raise, never a silent coercion);
///   - number: formatted COPY pushed (lua_numbertocstring + pushstring —
///     NO in-place mutation of the target, unlike lua_tolstring);
///   - string: pushvalue; boolean: "true"/"false"; nil: "nil";
///   - default: `__name` metafield (or the type name) + "%s: %p" (pointer
///     text — not byte-comparable across runtimes; excluded from the
///     differential suite).
/// Returns `lua_tolstring(L, -1, len)` — the pushed value's bytes.
pub export fn luaL_tolstring(L: ?*lua_State, idx: c_int, l: ?*usize) [*:0]const u8 {
    var s = api.State.fromHandle(L orelse {
        if (l) |p| p.* = 0;
        return "";
    });
    const abs = s.absindex(idx);
    if (luaL_callmeta(L, abs, "__tostring") != 0) {
        // __tostring ran: its result is on top and must be a string (PUC
        // luaL_error — OOM inside the raise path is LUA_ERRMEM).
        if (lua_isstring(L, -1) == 0) {
            _ = lua_pushfstring(L, "'__tostring' must return a string");
            lua_error(L);
        }
    } else {
        switch (lua_type(L, abs)) {
            3 => { // LUA_TNUMBER: formatted copy — NO in-place mutation
                var buff: [64]u8 = undefined; // LUA_N2SBUFFSZ
                const n = lua_numbertocstring(L, abs, &buff);
                if (n > 0) {
                    lua_pushlstring(L, &buff, @intCast(n - 1));
                } else {
                    // lua_type reported a number: unreachable (defensive).
                    lua_pushnil(L);
                }
            },
            4 => _ = lua_pushvalue(L, abs), // LUA_TSTRING
            1 => lua_pushstring(L, if (lua_toboolean(L, abs) != 0) "true" else "false"),
            0 => lua_pushstring(L, "nil"), // LUA_TNIL
            else => {
                // default: __name metafield or the type name + "%s: %p".
                const tt = luaL_getmetafield(L, abs, "__name");
                const ty = lua_type(L, abs);
                const kind: [*:0]const u8 = if (tt == 4)
                    (lua_tolstring(L, -1, null) orelse lua_typename(L, ty))
                else
                    lua_typename(L, ty);
                _ = lua_pushfstring(L, "%s: %p", kind, lua_topointer(L, abs));
                if (tt != 0) lua_remove(L, -2); // remove '__name'
            },
        }
    }
    // PUC: every branch pushed exactly one value; a string is on top
    // (lua_assert(lua_isstring(L, -1)) there). The `orelse ""` is the
    // defensive arm of that assert — unreachable by construction.
    return lua_tolstring(L, -1, l) orelse "";
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
    s.curThread().top -= 1; // PUC luaL_len: plain pop of the length value
    return result;
}

pub export fn luaL_gsub(L: ?*lua_State, s_str: [*:0]const u8, p: [*:0]const u8, r: [*:0]const u8) [*:0]const u8 {
    const h = L orelse return s_str;
    const vm = h.vm;
    // Reserve the result slot BEFORE the string exists —
    // the push then hits reserved capacity and cannot sweep the constructed
    // unrooted string at a full window.
    vm.cWindowEnsure(Vm.handleThread(h), 1) catch |e| cThrowOn(vm, h, api.mapVmError(e));
    const src = std.mem.span(s_str);
    const pat = std.mem.span(p);
    const rep = std.mem.span(r);
    // NO defer: _longjmp bypasses it — every failure path deinits the
    // buffer via cThrowOomBufU before throwing LUA_ERRMEM
    // (a `catch return s_str` would leak the buffer and silently
    // return the UNSUBSTITUTED input).
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
    vm.cWindowPush(Vm.handleThread(h), .{ .String = ls }) catch cThrowOomBufU(vm, h, &result);
    result.deinit(vm.alloc);
    return @ptrCast(@constCast(ls.bytes().ptr));
}

pub export fn luaL_getmetafield(L: ?*lua_State, obj: c_int, event: [*:0]const u8) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC lauxlib.c:884-897: lua_getmetatable covers EVERY value kind —
    // including the type-level slots (G(L)->mt[ttype(o)]) — not just
    // table/userdata. index2value resolution: a pseudo obj addresses the
    // value it resolves to. No metatable → LUA_TNIL, stack unchanged.
    const mt: *vm_mod.Table = s.vm.valueMetatable(s.index2value(obj)) orelse return 0;
    // lua_pushstring + lua_rawget on the metatable — OOM is LUA_ERRMEM
    // (P16.50-review-5 B2 — the old `catch return 0` misreported "no
    // metamethod").
    const key = s.vm.internStr(std.mem.span(event)) catch |e| cThrowOn(s.vm, L.?, e);
    const val = s.vm.apiRawGet(mt, .{ .String = key });
    // Nil metafield: PUC pops metatable+metafield (stack unchanged) and
    // returns LUA_TNIL.
    if (val == .Nil) return 0;
    s.push(val) catch |e| cThrowOn(s.vm, L.?, e);
    // PUC returns the metafield's REAL type tag (lauxlib.c:895 `return tt`),
    // not a boolean.
    return api.typeCode(api.valueType(val));
}

pub export fn luaL_callmeta(L: ?*lua_State, obj: c_int, event: [*:0]const u8) c_int {
    // PUC luaL_callmeta (lauxlib.c:900-906): absindex FIRST — a relative
    // obj index must be pinned BEFORE luaL_getmetafield pushes the
    // metafield (pushing obj after the push would push the METAFIELD, not
    // the object). Pseudo indices pass through unchanged. No metafield →
    // 0; otherwise lua_call (errors RAISE — no status return) and 1.
    const abs = lua_absindex(L, obj);
    if (luaL_getmetafield(L, abs, event) == 0) return 0;
    var s = api.State.fromHandle(L orelse return 0);
    // PUC lua_pushvalue → api_incr_top: OOM throws; InvalidIndex is
    // api_check — lenient 0 (P16.50-review-5 B2).
    s.pushvalue(abs) catch |e| switch (e) {
        error.OutOfMemory => cThrowOn(s.vm, L.?, e),
        else => return 0,
    };
    // PUC lua_call: a metamethod error propagates by raising (the old
    // pcallk-status return misreported success as 0 — PUC returns 1).
    lua_call(L, 1, 1);
    return 1;
}

pub export fn luaL_requiref(L: ?*lua_State, modname: [*:0]const u8, openf: ?*const fn (?*lua_State) callconv(.c) c_int, glb: c_int) void {
    var s = api.State.fromHandle(L orelse return);
    // PUC luaL_requiref (lauxlib.c:1006-1023): check the registry _LOADED
    // table (luaL_getsubtable — get-or-create); on a falsy entry call
    // openf(modname) and store the result into _LOADED[modname] (the
    // REGISTRY table, not the global package.loaded — require reads the
    // registry one); if glb, also publish _G[modname]. The module is left
    // on top. Every step throws on failure — no silent early return
    // leaving a half-pushed stack.
    const name = std.mem.span(modname);
    // luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE)
    s.getregistry() catch |e| cThrowOn(s.vm, L.?, e);
    _ = s.getfield(-1, "_LOADED") catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
    if (s.typeOf(-1)) |t| if (t != .table) {
        // Missing or non-table: replace with a fresh table (PUC
        // luaL_getsubtable get-or-create semantics).
        s.pop(1) catch {};
        s.newtable() catch |e| cThrowOn(s.vm, L.?, e);
        s.setfield(-2, "_LOADED") catch |e| switch (e) {
            error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
            else => {},
        };
    };
    // Drop the registry push: PUC addresses the registry by pseudo-index
    // and pushes only the subtable (stack: [loaded]).
    s.remove(-2) catch {};
    _ = s.getfield(-1, name) catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
    // Stack: [loaded, module-or-nil]
    if (!s.toboolean(-1)) {
        // Package not already loaded: pop the field, call openf(modname).
        s.pop(1) catch {};
        s.pushcfunction(openf) catch |e| cThrowOn(s.vm, L.?, e);
        s.pushstring(name) catch |e| cThrowOn(s.vm, L.?, e);
        s.call(1, 1) catch |e| switch (e) {
            error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
            else => {},
        };
        // Stack: [loaded, module] — store a copy into _LOADED[modname].
        _ = s.pushvalue(-1) catch |e| cThrowOn(s.vm, L.?, e);
        s.setfield(-3, name) catch |e| switch (e) {
            error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
            else => {},
        };
    }
    // lua_remove(L, -2): drop the LOADED table below the module.
    s.remove(-2) catch {};
    if (glb != 0) {
        _ = s.pushvalue(-1) catch |e| cThrowOn(s.vm, L.?, e);
        s.setglobal(name) catch |e| switch (e) {
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
/// The fixed namewhat vocabulary of PUC
/// auxgetinfo/getfuncname (ldebug.c) — every value is a C string literal.
/// Maps a runtime namewhat slice back to the static literal so
/// lua_getinfo 'n' hands out a `[*:0]` with static lifetime and no
/// interning per query (PUC shape). Returns null for a slice outside the
/// vocabulary (defensive: the current producers only emit these values).
fn namewhatLiteralZ(nw: []const u8) ?[*:0]const u8 {
    const vocab = [_][:0]const u8{
        "",       "hook",  "metamethod", "local",    "upvalue",
        "global", "field", "method",     "constant", "for iterator",
    };
    for (vocab) |t| {
        if (std.mem.eql(u8, nw, t)) return t.ptr;
    }
    return null;
}

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
    // PUC: string source — [string "body"] (luaO_chunkid's string arm).
    // The body is the source up to the first '\n', truncated to the
    // 45-char budget; the "..." marker appears whenever the source had a
    // newline or exceeded the budget (a short one-line source keeps no
    // marker — `srclen < bufflen && nl == NULL`).
    const nl = std.mem.indexOfScalar(u8, source, '\n');
    const prefix = "[string \"";
    const suffix = "\"]";
    const budget = 59 - prefix.len - 3 - suffix.len; // room for "..." + NUL
    if (source.len < budget and nl == null) {
        const total = prefix.len + source.len + suffix.len;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..][0..source.len], source);
        @memcpy(buf[prefix.len + source.len ..][0..suffix.len], suffix);
        buf[total] = 0;
    } else {
        var body_len = source.len;
        if (nl) |pos| body_len = pos;
        if (body_len > budget) body_len = budget;
        const total = prefix.len + body_len + 3 + suffix.len;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..][0..body_len], source[0..body_len]);
        @memcpy(buf[prefix.len + body_len ..][0..3], "...");
        @memcpy(buf[prefix.len + body_len + 3 ..][0..suffix.len], suffix);
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

/// PUC `funcinfo` (ldebug.c:259-281): fill the 'S' fields for a function
/// VALUE (shared by lua_getinfo's frame form and '>' function form).
/// Non-Lua-closure values (light C functions, C closures, and — matching
/// release PUC's closure unwrap — any non-closure value) get the C shape.
fn getinfoFillSource(vm: *Vm, h: *lua_State, ar: *lua_Debug, func: Value) void {
    if (func == .Closure) blk: {
        const cl = func.Closure;
        const p = cl.proto orelse break :blk; // C closure
        if (p.sourceName().len == 0 and p.lineinfo.len == 0) {
            // PUC funcinfo's NULL-source arm (ldebug.c:269-273): protos
            // from stripped dumps report "=?", which luaO_chunkid shortens
            // to "?".
            ar.source = "=?";
            ar.srclen = 2;
            ar.linedefined = @intCast(p.line_defined);
            ar.lastlinedefined = @intCast(p.last_line_defined);
            ar.what = if (p.line_defined == 0) "main" else "Lua";
            fillShortSrc(&ar.short_src, "=?");
            return;
        }
        ar.what = if (p.line_defined == 0) "main" else "Lua";
        // PUC ldebug.c funcinfo (ldebug.c:358): ar->source =
        // svalue(p->source) — a PROTO-LIFETIME NUL-terminated
        // pointer, no fresh allocation per query. Protos
        // carrying the debug_names_z
        // contract (builder-fused tail, fixed undump, cloned
        // non-fixed undump) hand the pointer out directly; a
        // fresh internStr would leave an UNROOTED string that a
        // collection between getinfo and the caller's read
        // can sweep.
        if (p.flags.debug_names_z) {
            ar.source = @ptrCast(@constCast(p.sourceName().ptr));
            ar.srclen = @intCast(p.sourceName().len);
        } else {
            // Fallback (protos without the contract — hand-built
            // test protos, un-cloned non-fixed undump): intern
            // and root the string on the C window so it survives
            // any collection until the caller pops the window —
            // the closest PUC-parity lifetime available without
            // the contract. OOM is LUA_ERRMEM.
            // Reserve the slot BEFORE the
            // intern — the push then hits reserved capacity and
            // cannot sweep the fresh unrooted string at a full
            // window.
            const wth = Vm.handleThread(h);
            vm.cWindowEnsure(wth, 1) catch |e| cThrowOn(vm, h, api.mapVmError(e));
            const src_ls = vm.internStr(p.sourceName()) catch |e| cThrowOn(vm, h, e);
            vm.cWindowPush(wth, .{ .String = src_ls }) catch |e| cThrowOn(vm, h, api.mapVmError(e));
            ar.source = @ptrCast(@constCast(src_ls.bytes().ptr));
            ar.srclen = src_ls.bytes().len;
        }
        ar.linedefined = @intCast(p.line_defined);
        ar.lastlinedefined = @intCast(p.last_line_defined);
        fillShortSrc(&ar.short_src, p.sourceName());
        return;
    }
    // C function shape (PUC funcinfo's !LuaClosure arm): no source info.
    ar.what = "C";
    ar.source = "=[C]";
    ar.srclen = 4;
    ar.linedefined = -1;
    ar.lastlinedefined = -1;
    fillShortSrc(&ar.short_src, "=[C]");
}

/// PUC `collectvalidlines` (ldebug.c:292-321): the 'L' flag pushes a table
/// with a `true` entry per active line for a Lua closure, nil for anything
/// else. The table is pushed BEFORE it is filled (PUC ldebug.c:302-303):
/// the window slot roots it across every insert allocation. The raw Proto
/// is held across those same allocations, so the caller must keep `func`
/// rooted for the whole call (the '>' form's RootScope; the frame form's
/// function slot). The line set is the same computation the Lua-level
/// debug.getinfo 'L' lane uses (byte-identical to PUC's per-instruction
/// walk on all validated shapes).
fn getinfoCollectValidLines(vm: *Vm, h: *lua_State, func: Value) void {
    const proto: ?*const bc.Proto = if (func == .Closure) func.Closure.proto else null;
    if (proto == null) {
        vm.cWindowPush(Vm.handleThread(h), .Nil) catch |e| cThrowOn(vm, h, api.mapVmError(e));
        return;
    }
    var s = api.State.fromHandle(h);
    s.newtable() catch |e| cThrowOn(vm, h, e);
    for (proto.?.lineinfo) |line| {
        if (line > 0) {
            s.pushboolean(true) catch |e| cThrowOn(vm, h, e);
            // The table sits at -2 while the value is staged on top.
            s.rawseti(-2, line) catch |e| cThrowOn(vm, h, e);
        }
    }
}

/// PUC `lua_getinfo` (ldebug.c:lua_getinfo): fill `lua_Debug` fields from
/// the frame identified by `ar->i_ci` (set by `lua_getstack`) or — when
/// `what` starts with '>' — from the function value on top of the stack
/// (PUC pops it before reading the flags; every flag then runs with
/// ci == NULL, so 'l' is -1 and 'n' finds no name). 'f' pushes the
/// function back after the flags; 'L' pushes the valid-lines table (or
/// nil). Returns 0 when `what` holds an invalid option (flags before the
/// invalid one are still filled), 1 otherwise; 0 on an invalid frame
/// handle.
pub export fn lua_getinfo(L: ?*lua_State, what: [*:0]const u8, ar: *lua_Debug) c_int {
    const h = L orelse return 0;
    const vm = h.vm;
    const flags = std.mem.span(what);
    const fn_form = flags.len > 0 and flags[0] == '>';
    const opts = if (fn_form) flags[1..] else flags;

    var func: Value = .Nil;
    var frame_idx: usize = 0;
    var th: *vm_mod.Thread = undefined;
    // Temporary GC root for the '>' form's popped function. PUC's pop
    // (ldebug.c:406) leaves the value above L->top for the rest of the
    // call, safe only because no luaC_checkGC point runs inside
    // lua_getinfo; our allocators step the collector at allocation time,
    // so a sole-reference function must stay rooted across every fallible
    // section below (the 'S' intern fallback, the 'L' table construction,
    // the 'f' push). `defer close` covers every normal return lane; a
    // longjmp out of the call is cleaned by the protected-boundary
    // landing pad's restoreRoots.
    var fn_root: ?Vm.RootScope = null;
    defer if (fn_root != null) fn_root.?.close();
    if (fn_form) {
        // PUC ldebug.c:401-407: func = s2v(L->top.p - 1), then pop. An empty
        // window makes PUC read ci->func (the running function) and pop
        // below the API base — window corruption we do not mirror; the
        // read is kept, the pop clamps at the window base.
        const wth = Vm.handleThread(h);
        if (wth.top == 0) return 0;
        func = wth.stack[wth.top - 1];
        // Root the function BEFORE the pop: an OOM here leaves the value
        // on the stack (still a root) and no collector has run (the
        // reserve uses the NoGC infra allocator).
        fn_root = vm.openRootScope(1, 0) catch |e| cThrowOn(vm, h, api.mapVmError(e));
        _ = fn_root.?.protectValueAssumeCapacity(func);
        if (wth.top > Vm.cWindowBase(wth)) wth.top -= 1;
        th = wth;
    } else {
        // Recover the frame index from ar.i_ci (1-based, stored by lua_getstack).
        const ci_raw = @intFromPtr(ar.i_ci orelse return 0);
        if (ci_raw == 0) return 0;
        const fi = ci_raw - 1; // convert back to 0-based

        th = vm.current_thread orelse vm.main_thread orelse return 0;
        if (fi >= th.call_frames.len()) return 0;
        frame_idx = fi;
        const frame = th.call_frames.getConstPtr(fi);
        func = if (frame.func_slot < th.stack.len) th.stack[frame.func_slot] else .Nil;
    }

    var status: c_int = 1;
    var push_func = false;
    var push_lines = false;
    for (opts) |flag| {
        switch (flag) {
            'S' => getinfoFillSource(vm, h, ar, func),
            'l' => {
                ar.currentline = if (!fn_form)
                    @intCast(vm.frameCurrentLine(th.call_frames.getConstPtr(frame_idx)))
                else
                    -1;
            },
            'u' => {
                if (func == .Closure) blk: {
                    const cl = func.Closure;
                    const p = cl.proto orelse break :blk; // C closure
                    ar.nups = @intCast(cl.upvalues.len);
                    // A load()ed main chunk always carries _ENV as its one
                    // upvalue in PUC (luaF_newLclosure(L, 1) at lua_load);
                    // our main closures hold no cells for it, so the
                    // class-level shape reports the PUC-visible count.
                    if (p.line_defined == 0 and p.flags.is_vararg and
                        p.numparams == 0 and cl.upvalues.len == 0)
                    {
                        ar.nups = 1;
                    }
                    ar.nparams = p.numparams;
                    ar.isvararg = if (p.flags.is_vararg) 1 else 0;
                    continue;
                }
                // PUC ldebug.c:344-348 (auxgetinfo 'u' for C functions):
                // nups = nupvalues of the called function (0 for light C
                // functions / builtins), nparams = 0, isvararg = 1 — C
                // functions accept any number of arguments. Release PUC
                // treats any non-closure value through the same arm.
                ar.nups = if (func == .Closure) @intCast(func.Closure.upvalues.len) else 0;
                ar.nparams = 0;
                ar.isvararg = 1;
            },
            't' => {
                // PUC auxgetinfo 't' (ldebug.c:356-366): extraargs is the
                // frame's committed __call-chain count (callstatus bits
                // 8-11), istailcall the CIST_TAIL flag; both zero without
                // a frame (the '>' form).
                if (fn_form) {
                    ar.istailcall = 0;
                    ar.extraargs = 0;
                } else {
                    const frame = th.call_frames.getConstPtr(frame_idx);
                    ar.istailcall = if (frame.isTailCall()) 1 else 0;
                    ar.extraargs = @intCast(frame.ccmt());
                }
            },
            'n' => {
                // PUC auxgetinfo 'n' (ldebug.c:369-373): namewhat comes from
                // getfuncname (the CALLER's bytecode at the call site,
                // ldebug.c:323 funcnamefromcall); when it returns NULL the
                // namewhat is "" (empty string) and name is NULL — never a
                // NULL namewhat.
                var resolved_namewhat: []const u8 = "";
                var resolved_name: ?[]const u8 = null;
                if (!fn_form) {
                    if (vm.getFuncNameForFrame(th, frame_idx)) |dn| {
                        resolved_namewhat = dn.namewhat;
                        resolved_name = dn.name;
                    }
                }
                // PUC hands out C string
                // LITERALS for namewhat (ldebug.c) — no allocation per
                // query. Map the runtime slice back to the static literal;
                // the defensive intern fallback covers a value outside the
                // vocabulary (cannot happen with the current producers).
                if (namewhatLiteralZ(resolved_namewhat)) |nw_z| {
                    ar.namewhat = nw_z;
                } else {
                    // Reserve the slot BEFORE the intern
                    // (same window discipline as the 'S' fallback above).
                    vm.cWindowEnsure(Vm.handleThread(h), 1) catch |e| cThrowOn(vm, h, api.mapVmError(e));
                    const nw_ls = vm.internStr(resolved_namewhat) catch |e| cThrowOn(vm, h, e);
                    vm.cWindowPush(Vm.handleThread(h), .{ .String = nw_ls }) catch |e| cThrowOn(vm, h, api.mapVmError(e));
                    ar.namewhat = @ptrCast(@constCast(nw_ls.bytes().ptr));
                }
                if (resolved_name) |nm| {
                    // The name's provenance (getFuncNameForFrame): the
                    // naming PARENT proto's locvars/upvalues/constants
                    // (proto-lifetime; NUL-terminated when the parent
                    // carries the debug_names_z contract — upvalue tails
                    // and LuaString constants are NUL regardless), or a
                    // static literal when there is no naming parent proto
                    // (hook "?", finalizer "__gc", "for iterator",
                    // metamethod opnames). Both shapes allow handing the
                    // pointer out directly, PUC auxgetinfo style; the
                    // intern+window-root fallback covers parent protos
                    // without the contract (hand-built test protos).
                    const parent_has_contract = blk: {
                        if (fn_form or frame_idx == 0) break :blk true; // no naming parent: literal-only sources
                        const parent = th.call_frames.getConstPtr(frame_idx - 1);
                        if (parent.proto()) |pp| break :blk pp.flags.debug_names_z;
                        break :blk true; // C/hook/fin caller: literal-only sources
                    };
                    if (parent_has_contract) {
                        ar.name = @ptrCast(@constCast(nm.ptr));
                    } else {
                        // Reserve the slot BEFORE the
                        // intern (same window discipline as the 'S' fallback).
                        vm.cWindowEnsure(Vm.handleThread(h), 1) catch |e| cThrowOn(vm, h, api.mapVmError(e));
                        const ls = vm.internStr(nm) catch |e| cThrowOn(vm, h, e);
                        vm.cWindowPush(Vm.handleThread(h), .{ .String = ls }) catch |e| cThrowOn(vm, h, api.mapVmError(e));
                        ar.name = @ptrCast(@constCast(ls.bytes().ptr));
                    }
                } else {
                    ar.name = null;
                }
            },
            'r' => {
                // PUC auxgetinfo 'r' (ldebug.c:376-383): both transfer
                // fields are zero except on the frame a running hook is
                // interrupting, which reports the active transfer window;
                // always zero without a frame (the '>' form).
                if (!fn_form) {
                    if (vm.debugTransferWindowForFrame(th, frame_idx)) |tr| {
                        ar.ftransfer = @intCast(tr.ftransfer);
                        ar.ntransfer = @intCast(tr.ntransfer);
                        continue;
                    }
                }
                ar.ftransfer = 0;
                ar.ntransfer = 0;
            },
            // 'f'/'L' are handled by the push tail below (PUC
            // ldebug.c:417-423 runs them after auxgetinfo).
            'f' => push_func = true,
            'L' => push_lines = true,
            else => status = 0, // invalid option (PUC auxgetinfo default)
        }
    }
    if (push_func) {
        vm.cWindowPush(Vm.handleThread(h), func) catch |e| cThrowOn(vm, h, api.mapVmError(e));
    }
    if (push_lines) {
        getinfoCollectValidLines(vm, h, func);
    }
    return status;
}

/// PUC `lua_getlocal` (lapi.c:lua_getlocal): get the name of the `n`-th local
/// variable in the frame identified by `ar`. Pushes the local's value onto
/// the C stack and returns its name. Returns null if `n` is out of range.
///
/// Mirrors PUC's `luaF_getlocalname` (lfunc.c): iterate forward through
/// `Proto.locvars`, counting locals whose `[startpc, endpc)` range contains
/// the frame's current `pc`. The n-th active local's value lives at
/// `stack[frame.base + locvar.reg]` — pushed onto the window for C access.
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
                if (reg_idx >= th.stack.len) return null;
                const val = th.stack[reg_idx];
                // PUC lua_getlocal pushes via api_incr_top: OOM is
                // LUA_ERRMEM (a `catch return null` would misreport
                // "no such local").
                vm.cWindowPush(Vm.handleThread(h), val) catch |e| cThrowOn(vm, h, api.mapVmError(e));
                // PUC luaF_getlocalname returns the locvar's proto-owned
                // TString — a proto-lifetime NUL-terminated name. Protos
                // with the debug_names_z
                // contract (fused tail / fixed undump / cloned undump)
                // hand the pointer out directly; for protos whose locvar
                // names borrow un-terminated source bytes the direct
                // cast would hand out a non-NUL-terminated slice.
                // Fallback: intern and
                // root on the C window (same lifetime discipline as
                // lua_getinfo 'S'/'n').
                if (proto.flags.debug_names_z) {
                    return @ptrCast(@constCast(lv.name.ptr));
                }
                // Reserve the slot BEFORE the intern
                // (same window discipline as lua_getinfo 'S'/'n').
                vm.cWindowEnsure(Vm.handleThread(h), 1) catch |e| cThrowOn(vm, h, api.mapVmError(e));
                const ls = vm.internStr(lv.name) catch |e| cThrowOn(vm, h, e);
                vm.cWindowPush(Vm.handleThread(h), .{ .String = ls }) catch |e| cThrowOn(vm, h, api.mapVmError(e));
                return @ptrCast(@constCast(ls.bytes().ptr));
            }
        }
    }
    return null; // no n-th active local
}

/// PUC `lua_setlocal` (lapi.c:lua_setlocal): set the `n`-th local variable
/// in the frame identified by `ar` to the value on top of the C stack.
/// Returns the local's name, or null if `n` is out of range.
///
/// Pops the value from the window and writes it to the bytecode register at
/// `stack[frame.base + locvar.reg]`, mirroring PUC's `setobjs2s(L, pos, --L->top)`.
pub export fn lua_setlocal(L: ?*lua_State, ar: *lua_Debug, n: c_int) ?[*:0]const u8 {
    const h = L orelse return null;
    const vm = h.vm;
    const setlocal_th = Vm.handleThread(h);
    if (Vm.cWindowCount(setlocal_th) < 1) return null; // need a value on the stack

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
                // Pop the value from the window (plain pop — PUC
                // setobjs2s(L, pos, --L->top)), write to the register.
                const val = setlocal_th.stack[setlocal_th.top - 1];
                setlocal_th.top -= 1;
                const reg_idx = frame.frameBase() + lv.reg;
                if (reg_idx >= th.stack.len) return null;
                th.stack[reg_idx] = val;
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
    // PUC 5.5 aux_upvalue (lapi.c:1372-1391): index2value(L, funcindex) —
    // a PSEUDO funcindex resolves through the unified resolver (an upvalue
    // of the running C closure holding a closure addresses THAT closure's
    // upvalues); a non-closure (nilvalue included) → NULL, no error.
    const cl = switch (s.index2value(funcindex)) {
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
    s.push(aux.cell.get(s.vm)) catch |e| cThrowOn(s.vm, L.?, e);
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
    if (s.count() == 0) return null;
    const name = upvalueCName(aux);
    const v = s.curThread().stack[s.curThread().top - 1];
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
    s.curThread().top -= 1; // PUC lua_setupvalue: plain pop of the value
    return name;
}

pub export fn lua_upvalueid(L: ?*lua_State, fidx: c_int, n: c_int) ?*anyopaque {
    const s = api.State.fromHandle(L orelse return null);
    // PUC 5.5 lua_upvalueid (lapi.c:1441-1459) via getupvalref:
    // index2value(L, fidx) — a pseudo fidx resolves through the unified
    // resolver; light C functions (LUA_VLCF) and non-functions → NULL (the
    // api_check in the default arm is a release no-op).
    const cl = switch (s.index2value(fidx)) {
        .Closure => |c| c,
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
    // PUC 5.5 lua_upvaluejoin (lapi.c:1463-1470) via getupvalref:
    // index2value on BOTH funcindices — pseudo indices resolve through
    // the unified resolver.
    // PUC lua_upvaluejoin via getupvalref: ONLY Lua closures participate
    // (api_check ttisLclosure — a release no-op; the manual documents
    // non-Lua-closure input as undefined behavior). We fail soft: a
    // silent no-op for any non-Lua-closure or out-of-range index, keeping
    // the C-API contract non-raising (P16.50-review-7 B1).
    const cl1 = switch (s.index2value(fidx1)) {
        .Closure => |c| c,
        else => return,
    };
    const cl2 = switch (s.index2value(fidx2)) {
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
    vm.cWindowPush(Vm.handleThread(h), vm.registryGlobalsValue()) catch |e| cThrowOn(vm, h, api.mapVmError(e));
    return 1;
}

/// PUC `luaopen_package` (loadlib.c:724-747): opens the package library —
/// builds a FRESH package table (path/cpath, config, searchpath/loadlib,
/// loaded/preload from the registry, the 4-entry searchers table and the
/// require closure, each carrying the package table as upvalue 1) and
/// pushes it. _G.package is left to the caller (PUC hosts publish it via
/// luaL_requiref's glb flag).
pub export fn luaopen_package(L: ?*lua_State) c_int {
    var s = api.State.fromHandle(L orelse return 0);
    // PUC publication-order contract (loadlib.c luaopen_package over
    // luaD_checkstack): every fallible step — the return-tail reserve,
    // the rooting scope, the whole constructor — precedes the
    // constructor's global publication (its setGlobal("require") is the
    // final fallible act); the tail protect/push/result handoff is
    // allocation-free, so a failed open leaves _G byte-exact.
    s.vm.cReturnTailReserve(Vm.handleThread(L.?), 1) catch |e|
        cThrowOn(s.vm, L.?, api.mapVmError(e));
    var scope = s.vm.openRootScope(1, 0) catch cThrowOn(s.vm, L.?, error.OutOfMemory);
    defer scope.close();
    const pkg = s.vm.openPackageLibrary() catch |e| switch (e) {
        error.OutOfMemory => cThrowOn(s.vm, L.?, error.OutOfMemory),
        error.RuntimeError => cThrowOn(s.vm, L.?, error.Runtime),
        error.MainDestined => cRelayMainDestined(s.vm),
        // The constructor runs no user code: coroutine control flow cannot
        // legitimately cross this boundary — fail loudly instead of
        // silently re-labeling it as ERRRUN.
        error.Yield, error.ThreadSwitch => @panic(
            "luaopen_package: coroutine control flow crossed the constructor boundary",
        ),
        // the constructor runs no host C callbacks: an absorption cannot
        // start here; relay if a regression ever produces one.
        error.YieldAbsorbed => {
            if (s.vm.c_error_jmp) |jb| {
                s.vm.c_error_status = 1; // LUA_YIELD sentinel: the raw-yield absorption fact
                _longjmp(jb, 1);
            }
            s.vm.panicHookAbort(s.vm.raw_yield_absorb_thrower);
        },
    };
    // Root the fresh table across the window push: until the value lands
    // on the thread stack it is visible only to this C frame (the
    // constructor's root scope has closed). Abandoned scopes on a throw
    // are cleaned by the C landing pad's restoreRoots.
    _ = scope.protectValueAssumeCapacity(.{ .Table = pkg });
    s.vm.cWindowPush(Vm.handleThread(L.?), .{ .Table = pkg }) catch |e| cThrowOn(s.vm, L.?, api.mapVmError(e));
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
    // PUC publication-order contract (luaopen_package pattern over
    // luaD_checkstack): every fallible step — the return-tail reserve,
    // the rooting scope, the whole constructor (fresh table + RanState
    // userdata + the two CClosure(1) shims) — precedes the window push;
    // the tail protect/push/result handoff is allocation-free, so a
    // failed open leaves the thread byte-exact.
    s.vm.cReturnTailReserve(Vm.handleThread(L.?), 1) catch |e|
        cThrowOn(s.vm, L.?, api.mapVmError(e));
    var scope = s.vm.openRootScope(1, 0) catch cThrowOn(s.vm, L.?, error.OutOfMemory);
    defer scope.close();
    const math_tbl = s.vm.openMathLibrary() catch |e| switch (e) {
        error.OutOfMemory => cThrowOn(s.vm, L.?, error.OutOfMemory),
        error.RuntimeError => cThrowOn(s.vm, L.?, error.Runtime),
        error.MainDestined => cRelayMainDestined(s.vm),
        // The constructor runs no user code: coroutine control flow cannot
        // legitimately cross this boundary — fail loudly instead of
        // silently re-labeling it as ERRRUN.
        error.Yield, error.ThreadSwitch => @panic(
            "luaopen_math: coroutine control flow crossed the constructor boundary",
        ),
        // the constructor runs no host C callbacks: an absorption cannot
        // start here; relay if a regression ever produces one.
        error.YieldAbsorbed => {
            if (s.vm.c_error_jmp) |jb| {
                s.vm.c_error_status = 1; // LUA_YIELD sentinel: the raw-yield absorption fact
                _longjmp(jb, 1);
            }
            s.vm.panicHookAbort(s.vm.raw_yield_absorb_thrower);
        },
    };
    // Root the fresh table across the window push: until the value lands
    // on the thread stack it is visible only to this C frame (the
    // constructor's root scope has closed). Abandoned scopes on a throw
    // are cleaned by the C landing pad's restoreRoots.
    _ = scope.protectValueAssumeCapacity(.{ .Table = math_tbl });
    s.vm.cWindowPush(Vm.handleThread(L.?), .{ .Table = math_tbl }) catch |e| cThrowOn(s.vm, L.?, api.mapVmError(e));
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

    // PUC: luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE) —
    // get-or-create the PRELOAD table in the registry (the VM's
    // openPackageLibrary normally created it; a stripped or mutated
    // registry still gets a fresh table here, exactly like PUC).
    // PUC luaL_getsubtable throws on OOM (P16.50-review-5 B2 — the old
    // early returns left the library set half-open with no error).
    s.getregistry() catch |e| cThrowOn(s.vm, L.?, e);
    _ = s.getfield(-1, "_PRELOAD") catch |e| switch (e) {
        error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
        else => {},
    };
    if (s.typeOf(-1)) |t| if (t != .table) {
        // Missing or non-table: replace with a fresh table.
        s.pop(1) catch {};
        s.newtable() catch |e| cThrowOn(s.vm, L.?, e);
        s.setfield(-2, "_PRELOAD") catch |e| switch (e) {
            error.OutOfMemory, error.Runtime => cThrowOn(s.vm, L.?, e),
            else => {},
        };
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
    s.curThread().top -= 2; // plain pop (auxsetstr-family contract)
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
    const av_th = Vm.handleThread(h);
    if (Vm.cWindowCount(av_th) == 0) return;
    var l: usize = 0;
    const s = lua_tolstring(h, -1, &l);
    luaL_addlstring(B, s, l);
    av_th.top -= 1; // PUC luaL_addvalue: plain pop of the converted value
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
    // Reserve the result slot BEFORE the string exists —
    // the push then hits reserved capacity and cannot sweep the constructed
    // unrooted string at a full window.
    vm.cWindowEnsure(Vm.handleThread(h), 1) catch |e| {
        if (B.b != &B.init[0]) vm.alloc.free(B.b[0..B.size]);
        cThrowOn(vm, h, api.mapVmError(e));
    };
    // PUC luaL_pushresultsize → lua_pushlstring: OOM is LUA_ERRMEM, with
    // the spilled heap buffer freed BEFORE the throw (a
    // `catch return`/`catch {}` would leak the heap spill
    // and/or silently skip the push).
    const ls = vm.internStr(B.b[0..sz]) catch {
        if (B.b != &B.init[0]) vm.alloc.free(B.b[0..B.size]);
        cThrowOn(vm, h, error.OutOfMemory);
    };
    vm.cWindowPush(Vm.handleThread(h), .{ .String = ls }) catch {
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
    // Stage the Lua closure at index 1 on the fresh window (pcallk with
    // 0 args → the activation reserved LUA_MINSTACK spare slots), then
    // fill the stack to EXACT capacity so the result push inside
    // lua_getupvalue MUST allocate (the growth is the armed failure).
    s.push(.{ .Closure = b1_oom_closure.? }) catch return -1;
    // Fill the window to the stack buffer's EXACT capacity (no growth:
    // top never passes the captured len) so the result push inside
    // lua_getupvalue MUST grow (the growth is the armed failure).
    {
        const fill_th = s.curThread();
        const cap = fill_th.stack.len;
        while (fill_th.top < cap) s.push(.Nil) catch return -1;
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
    b1_oom_closure = s.curThread().stack[s.curThread().top - 1].Closure;
    // Keep the closure and the name alive across the pcall (temp roots —
    // the swapped-out main stack is not GC-marked during the C call).
    var scope = try vm.openRootScope(2, 0);
    defer scope.close();
    _ = scope.protectValueAssumeCapacity(.{ .Closure = b1_oom_closure.? });
    const xkey = try vm.internStr("x");
    _ = scope.protectValueAssumeCapacity(.{ .String = xkey });

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
    s.push(.{ .Closure = b8_owner.? }) catch return -1;
    lua_createtable(L, 0, 0);
    b8_young = s.curThread().stack[s.curThread().top - 1].Table;
    // Force both reserves to allocate (fresh capacity-less lists).
    s.vm.gc_gray.deinit(s.vm.alloc);
    s.vm.gc_gray = .empty;
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
    var s = api.State.fromHandle(L);
    b8_owner = s.curThread().stack[s.curThread().top - 1].Closure;
    const owner_cell = b8_owner.?.upvalues[0];
    const orig_value = owner_cell.value;
    var scope = try vm.openRootScope(1, 0);
    defer scope.close();
    _ = scope.protectValueAssumeCapacity(.{ .Closure = b8_owner.? });

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
    try std.testing.expect(b8AgeIsYoung(b8_young.?.gc.age));
    try std.testing.expectEqual(@as(usize, 0), vm.testGcCountAge(.old0));
    try std.testing.expectEqual(@as(usize, 0), vm.gc_gray.items.len);

    // Reuse with the real allocator: the same store succeeds, returns the
    // arena-backed name, promotes + publishes the young table exactly
    // once, and a full collection keeps it alive through the old cell.
    // (The failed pcallk left the error object on the stack — drop it.)
    lua_settop(L, 1); // [closure]
    s.push(.{ .Table = b8_young.? }) catch return error.OutOfMemory;
    const name = lua_setupvalue(L, -2, 1);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("x", std.mem.span(name.?));
    try std.testing.expect(std.meta.eql(owner_cell.value, .{ .Table = b8_young.? }));
    // Promotion is the age bit itself (published exactly once by
    // construction — there is no list entry to duplicate).
    try std.testing.expect(b8_young.?.gc.age == .old0);
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
    s.push(.{ .Closure = b8_owner.? }) catch return -1;
    s.push(.{ .Closure = b8_donor.? }) catch return -1;
    s.vm.gc_gray.deinit(s.vm.alloc);
    s.vm.gc_gray = .empty;
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
    b8_owner = s.curThread().stack[s.curThread().top - 1].Closure;
    const owner_cell = b8_owner.?.upvalues[0];
    var scope = try vm.openRootScope(2, 0);
    defer scope.close();
    _ = scope.protectValueAssumeCapacity(.{ .Closure = b8_owner.? });
    _ = luazigGcFixed(L, 7, 0); // LUA_GCGENERATIONAL

    try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, "local y = {2} return function() return y end"));
    try std.testing.expectEqual(@as(c_int, 0), lua_pcallk(L, 0, 1, 0, 0, null));
    b8_donor = s.curThread().stack[s.curThread().top - 1].Closure;
    const donor_cell = b8_donor.?.upvalues[0];
    _ = scope.protectValueAssumeCapacity(.{ .Closure = b8_donor.? });
    try std.testing.expect(b8AgeIsYoung(donor_cell.gc.age));

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
    try std.testing.expect(b8AgeIsYoung(donor_cell.gc.age));
    try std.testing.expectEqual(@as(usize, 0), vm.testGcCountAge(.old0));
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
    var s = api.State.fromHandle(L);
    const closure = s.curThread().stack[s.curThread().top - 1].Closure;
    var scope = try vm.openRootScope(1, 0);
    defer scope.close();
    _ = scope.protectValueAssumeCapacity(.{ .Closure = closure });

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
        s.push(.{ .Closure = closure }) catch return error.OutOfMemory;
        s.checkstack(8) catch return error.OutOfMemory; // spare capacity: the push cannot need growth
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

// ─────────────────────────────────────────────────────────────────
// P16.50-review-13: unified metatable transaction (lua_setmetatable)
// ─────────────────────────────────────────────────────────────────

var r13_base: std.mem.Allocator = undefined;
var r13_failing: std.testing.FailingAllocator = undefined;
var r13_owner_table: ?*vm_mod.Table = null;
var r13_owner_ud: ?*vm_mod.Userdata = null;
var r13_mt: ?*vm_mod.Table = null;

fn r13StageTable(L: ?*lua_State) callconv(.c) c_int {
    var s = api.State.fromHandle(L.?);
    // Fresh lists force every reserve to actually allocate.
    s.vm.gc_gray.deinit(s.vm.alloc);
    s.vm.gc_gray = .empty;
    s.vm.gc_grayagain.deinit(s.vm.alloc);
    s.vm.gc_grayagain = .empty;
    s.push(.{ .Table = r13_owner_table.? }) catch return -1;
    s.push(.{ .Table = r13_mt.? }) catch return -1;
    r13_failing = std.testing.FailingAllocator.init(r13_base, .{
        .fail_index = r13_fail_idx,
        .resize_fail_index = 0,
    });
    // The metatable transaction's reserves all go through infraAlloc()
    // (= testc_alloc_base orelse alloc) — arm THAT seam; vm.alloc stays
    // real so the LUA_ERRMEM transport itself cannot fail.
    s.vm.testc_alloc_base = r13_failing.allocator();
    _ = lua_setmetatable(L, 1); // prepare OOM → LUA_ERRMEM longjmp
    return 0;
}

var r13_fail_idx: usize = 0;

fn r13StageUserdata(L: ?*lua_State) callconv(.c) c_int {
    var s = api.State.fromHandle(L.?);
    s.vm.gc_gray.deinit(s.vm.alloc);
    s.vm.gc_gray = .empty;
    s.vm.gc_grayagain.deinit(s.vm.alloc);
    s.vm.gc_grayagain = .empty;
    s.push(.{ .Userdata = r13_owner_ud.? }) catch return -1;
    s.push(.{ .Table = r13_mt.? }) catch return -1;
    r13_failing = std.testing.FailingAllocator.init(r13_base, .{
        .fail_index = r13_fail_idx,
        .resize_fail_index = 0,
    });
    // The metatable transaction's reserves all go through infraAlloc()
    // (= testc_alloc_base orelse alloc) — arm THAT seam; vm.alloc stays
    // real so the LUA_ERRMEM transport itself cannot fail.
    s.vm.testc_alloc_base = r13_failing.allocator();
    _ = lua_setmetatable(L, 1); // reserve OOM → LUA_ERRMEM longjmp
    return 0;
}

/// A fresh YOUNG/WHITE metatable with __gc, created AFTER the owners were
/// promoted OLD so the forward barrier arms (black OLD owner + white young
/// metatable). __gc is the `type` builtin — deliberately silent: registered
/// finalizers run at lua_close, and a printing __gc would write to raw
/// stdout (corrupting the zig-build-test RPC stream in listen mode).
/// Protects the metatable into the CALLER's scope (counts against its
/// value reserve).
fn r13NewMt(vm: *vm_mod.Vm, scope: *vm_mod.Vm.RootScope) !*vm_mod.Table {
    const mt = try vm.apiNewTable();
    _ = scope.protectValueAssumeCapacity(.{ .Table = mt });
    try vm.apiSetTable(.{ .Table = mt }, .{ .String = try vm.internStr("__gc") }, .{ .Builtin = .type });
    return mt;
}

fn r13AssertByteExact(vm: *vm_mod.Vm, table_arm: bool) !void {
    // Prepare failure changed NOTHING: the arm's metatable unset, the
    // owner unregistered, all worklists empty (the stage re-created them
    // fresh, so a published entry would be visible here). The finobj
    // census keeps the state's own io-file baseline (stdin/stdout/stderr
    // register at bootstrap) — no NEW registration may appear.
    if (table_arm) {
        try std.testing.expect(r13_owner_table.?.metatable == null);
        try std.testing.expect(!vm.testGcRegistered(.{ .table = r13_owner_table.? }));
    } else {
        try std.testing.expect(r13_owner_ud.?.metatable == null);
        try std.testing.expect(!vm.testGcRegistered(.{ .userdata = r13_owner_ud.? }));
    }
    try std.testing.expectEqual(r13_fin_baseline, vm.testGcFinobjLen());
    try std.testing.expectEqual(@as(usize, 0), vm.gc_gray.items.len);
    try std.testing.expectEqual(@as(usize, 0), vm.gc_grayagain.items.len);
}

/// The pre-transaction finobj census for `r13AssertByteExact` (set by each
/// test arm right after state creation).
var r13_fin_baseline: usize = 0;

test "c api lua_setmetatable OOM transaction matrix (table + userdata, every reserve edge)" {
    // P16.50-review-14: one FRESH VM per arm. The boundary success of an
    // arm registers its owner (FINALIZEDBIT + finobj membership); the
    // other arm's per-probe worklist resets must never disturb that live
    // registration (test honesty: FINALIZEDBIT ⟺ registered must stay
    // checkable). Each arm ends with a REAL full cycle after its
    // failure-sweep + boundary success.

    // ── TABLE arm ── exactly ONE reserve edge (the gray worklist slot —
    // the allgc→finobj registration move is infallible pointer surgery,
    // HIGH 1 removed the PUC-unintended grayagain re-queue and the OLD0
    // promotion is an infallible age store): fail_index 0 must abort the
    // transaction with LUA_ERRMEM/MEMERRMSG before ANY observable change.
    {
        const L = luaL_newstate() orelse return error.OutOfMemory;
        defer lua_close(L);
        const vm = L.vm;
        var scope = try vm.openRootScope(2, 0);
        defer scope.close();
        // Generational mode; a full collect promotes the rooted owner
        // OLD/black so every gen reserve arms for a young/white metatable.
        _ = luazigGcFixed(L, 7, 0); // LUA_GCGENERATIONAL
        _ = luazigGcFixed(L, 2, 0); // LUA_GCCOLLECT
        const owner = try vm.apiNewTable();
        _ = scope.protectValueAssumeCapacity(.{ .Table = owner });
        _ = luazigGcFixed(L, 2, 0); // promote the owner OLD/black
        _ = luazigGcFixed(L, 7, 0); // generational MINOR phase (non-sweep)
        r13_owner_table = owner;
        r13_owner_ud = null;

        // The real infra base (pre-arming) — restored after each edge probe.
        r13_base = vm.testc_alloc_base orelse vm.alloc;
        r13_fin_baseline = vm.testGcFinobjLen();

        const mt_a = try r13NewMt(vm, &scope);
        r13_mt = mt_a;
        for (0..1) |fi| {
            r13_fail_idx = fi;
            lua_settop(L, 0);
            lua_pushcfunction(L, r13StageTable);
            const st = lua_pcallk(L, 0, 0, 0, 0, null);
            vm.testc_alloc_base = r13_base;
            try std.testing.expectEqual(@as(c_int, 4), st);
            try std.testing.expectEqualStrings("not enough memory", vm.errThread().err_obj.String.bytes());
            try r13AssertByteExact(vm, true);
        }
        // Boundary: fail_index == 1 (past the last edge) — the transaction
        // succeeds and publishes EVERYTHING exactly once: the store, the
        // forward-barrier publications (gray + the metatable's OLD0) and
        // the finalizer registration. NO grayagain re-queue (HIGH 1: PUC
        // lua_setmetatable runs only the forward luaC_objbarrier — the
        // owner stays old/black and is NOT re-traversed).
        {
            r13_fail_idx = 1;
            lua_settop(L, 0);
            lua_pushcfunction(L, r13StageTable);
            const st = lua_pcallk(L, 0, 0, 0, 0, null);
            vm.testc_alloc_base = r13_base;
            try std.testing.expectEqual(@as(c_int, 0), st);
            try std.testing.expect(r13_owner_table.?.metatable == mt_a);
            try std.testing.expect(vm.testGcRegistered(.{ .table = r13_owner_table.? }));
            try std.testing.expectEqual(r13_fin_baseline + 1, vm.testGcFinobjLen());
            try std.testing.expectEqual(@as(usize, 1), vm.gc_gray.items.len);
            try std.testing.expectEqual(@as(usize, 1), vm.testGcCountAge(.old0));
            try std.testing.expectEqual(@as(usize, 0), vm.gc_grayagain.items.len);
        }
        // REAL full cycle after failure + success: the rooted owner keeps
        // the store; the registration persists (registered, not run).
        _ = luazigGcFixed(L, 2, 0);
        try std.testing.expect(r13_owner_table.?.metatable == mt_a);
        try std.testing.expect(vm.testGcRegistered(.{ .table = r13_owner_table.? }));
        lua_settop(L, 0);
    }

    // ── USERDATA arm ── (fresh VM) exactly ONE reserve edge (the gray
    // worklist slot — the metatable pointer takes the FORWARD barrier
    // only, never the backward one; the registration move and the OLD0
    // promotion are infallible): fail_index 0 aborts byte-exact.
    {
        const L = luaL_newstate() orelse return error.OutOfMemory;
        defer lua_close(L);
        const vm = L.vm;
        var s = api.State.fromHandle(L);
        var scope = try vm.openRootScope(2, 0);
        defer scope.close();
        _ = luazigGcFixed(L, 7, 0); // LUA_GCGENERATIONAL
        _ = luazigGcFixed(L, 2, 0); // LUA_GCCOLLECT
        const ud = try vm.allocUserdata(0, 0);
        _ = scope.protectValueAssumeCapacity(.{ .Userdata = ud });
        _ = luazigGcFixed(L, 2, 0); // promote the owner OLD/black
        _ = luazigGcFixed(L, 7, 0); // generational MINOR phase (non-sweep)
        r13_owner_ud = ud;
        r13_owner_table = null;

        r13_base = vm.testc_alloc_base orelse vm.alloc;
        r13_fin_baseline = vm.testGcFinobjLen();

        const mt_b = try r13NewMt(vm, &scope);
        r13_mt = mt_b;
        for (0..1) |fi| {
            r13_fail_idx = fi;
            lua_settop(L, 0);
            lua_pushcfunction(L, r13StageUserdata);
            const st = lua_pcallk(L, 0, 0, 0, 0, null);
            vm.testc_alloc_base = r13_base;
            try std.testing.expectEqual(@as(c_int, 4), st);
            try std.testing.expectEqualStrings("not enough memory", vm.errThread().err_obj.String.bytes());
            try r13AssertByteExact(vm, false);
        }
        // Boundary: fail_index == 1 — success with the userdata
        // publications (gray + OLD0; NO grayagain — the owner is not
        // re-queued).
        {
            r13_fail_idx = 1;
            lua_settop(L, 0);
            lua_pushcfunction(L, r13StageUserdata);
            const st = lua_pcallk(L, 0, 0, 0, 0, null);
            vm.testc_alloc_base = r13_base;
            try std.testing.expectEqual(@as(c_int, 0), st);
            try std.testing.expect(r13_owner_ud.?.metatable == mt_b);
            try std.testing.expect(vm.testGcRegistered(.{ .userdata = r13_owner_ud.? }));
            try std.testing.expectEqual(r13_fin_baseline + 1, vm.testGcFinobjLen());
            try std.testing.expectEqual(@as(usize, 1), vm.gc_gray.items.len);
            try std.testing.expectEqual(@as(usize, 1), vm.testGcCountAge(.old0));
            try std.testing.expectEqual(@as(usize, 0), vm.gc_grayagain.items.len);
        }

        // ── Real-allocator success + full-cycle survival ── re-setting the
        // already-published metatable is a no-op transaction (registered → no
        // finalizer edge; gray child → no barrier edge) that still pops
        // exactly the metatable, and a real full cycle keeps the store and
        // the exactly-once registration.
        lua_settop(L, 0);
        s.push(.{ .Userdata = r13_owner_ud.? }) catch return error.OutOfMemory;
        s.push(.{ .Table = mt_b }) catch return error.OutOfMemory;
        try std.testing.expectEqual(@as(c_int, 1), lua_setmetatable(L, 1));
        // A SUCCESSFUL transaction pops exactly the metatable (one value) —
        // the owner remains on the stack.
        try std.testing.expectEqual(@as(usize, 1), s.count());
        try std.testing.expect(r13_owner_ud.?.metatable == mt_b);
        try std.testing.expect(vm.testGcRegistered(.{ .userdata = r13_owner_ud.? }));
        try std.testing.expectEqual(r13_fin_baseline + 1, vm.testGcFinobjLen());
        _ = luazigGcFixed(L, 2, 0); // real full cycle — everything rooted survives
        try std.testing.expect(r13_owner_ud.?.metatable == mt_b);
        // The registration survives the collect (registered, not run).
        try std.testing.expect(vm.testGcRegistered(.{ .userdata = r13_owner_ud.? }));
        lua_settop(L, 0);
    }
}

test "c api debug.setmetatable protected Lua call OOM matrix (shared transaction)" {
    // P16.50-review-14: one FRESH VM per probe. A probe that publishes
    // registers its owner (FINALIZEDBIT + finobj membership); the next
    // probe's worklist resets must never disturb that live registration
    // (test honesty: FINALIZEDBIT ⟺ registered must stay checkable). Every
    // probe — failure OR boundary success — ends with a REAL full cycle in
    // a consistent state.
    var boundary: ?usize = null;
    for (0..16) |fi| {
        const L = luaL_newstate() orelse return error.OutOfMemory;
        defer lua_close(L);
        const vm = L.vm;
        var s = api.State.fromHandle(L);

        var scope = try vm.openRootScope(4, 0);
        defer scope.close();
        // Generational mode: full collects promote fresh owners OLD, arming the
        // forward barrier for a later young/white metatable.
        _ = luazigGcFixed(L, 7, 0); // LUA_GCGENERATIONAL

        // Build the Lua closure `function(o, m) return debug.setmetatable(o,
        // m) end` under the REAL allocator (the chunk compile must not see
        // the seam) and root it for this probe.
        try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, "return function(o, m) return debug.setmetatable(o, m) end"));
        try std.testing.expectEqual(@as(c_int, 0), lua_pcallk(L, 0, 1, 0, 0, null));
        const closure = s.curThread().stack[s.curThread().top - 1].Closure;
        _ = scope.protectValueAssumeCapacity(.{ .Closure = closure });
        lua_settop(L, 0);

        const base = vm.testc_alloc_base orelse vm.alloc;
        r13_fin_baseline = vm.testGcFinobjLen();

        r13_fail_idx = fi;
        // Fresh OLD owner (full collect promotes the rooted table OLD).
        const owner = try vm.apiNewTable();
        _ = scope.protectValueAssumeCapacity(.{ .Table = owner });
        _ = luazigGcFixed(L, 2, 0); // LUA_GCCOLLECT → owner OLD/black
        r13_owner_table = owner;
        r13_owner_ud = null;
        // Fresh young/white metatable AFTER the owner is OLD.
        const mt = try r13NewMt(vm, &scope);
        r13_mt = mt;
        // Fresh worklists force the transaction's reserves (safe: this
        // fresh VM holds no live registration yet).
        vm.gc_gray.deinit(vm.alloc);
        vm.gc_gray = .empty;
        vm.gc_grayagain.deinit(vm.alloc);
        vm.gc_grayagain = .empty;
        s.push(.{ .Closure = closure }) catch return error.OutOfMemory;
        s.push(.{ .Table = owner }) catch return error.OutOfMemory;
        s.push(.{ .Table = mt }) catch return error.OutOfMemory;
        var failing = std.testing.FailingAllocator.init(base, .{
            .fail_index = r13_fail_idx,
            .resize_fail_index = 0,
        });
        vm.testc_alloc_base = failing.allocator();
        const st = lua_pcallk(L, 2, 0, 0, 0, null);
        vm.testc_alloc_base = base;
        if (st == 0) {
            // Boundary success: the shared transaction published everything
            // exactly once — the store, the forward barrier (gray + the
            // metatable's OLD0 promotion) and the __gc registration. NO
            // grayagain re-queue (HIGH 1: PUC lua_setmetatable runs only
            // the forward luaC_objbarrier).
            try std.testing.expect(owner.metatable == mt);
            try std.testing.expect(vm.testGcRegistered(.{ .table = owner }));
            try std.testing.expectEqual(r13_fin_baseline + 1, vm.testGcFinobjLen());
            try std.testing.expectEqual(@as(usize, 1), vm.gc_gray.items.len);
            try std.testing.expectEqual(@as(usize, 1), vm.testGcCountAge(.old0));
            try std.testing.expectEqual(@as(usize, 0), vm.gc_grayagain.items.len);
            // REAL full cycle after the boundary success: stack-rooted
            // owner + metatable survive and the registration persists
            // (registered, not run).
            lua_settop(L, 0);
            s.push(.{ .Table = owner }) catch return error.OutOfMemory;
            s.push(.{ .Table = mt }) catch return error.OutOfMemory;
            _ = luazigGcFixed(L, 2, 0);
            try std.testing.expect(owner.metatable == mt);
            try std.testing.expect(vm.testGcRegistered(.{ .table = owner }));
            boundary = fi;
            break;
        }
        try std.testing.expectEqual(@as(c_int, 4), st);
        try std.testing.expectEqualStrings("not enough memory", vm.errThread().err_obj.String.bytes());
        const published = owner.metatable != null;
        if (published) {
            // Post-commit failure: the atomic transaction published
            // EVERYTHING exactly once before the failing allocation.
            try std.testing.expect(owner.metatable == mt);
            try std.testing.expect(vm.testGcRegistered(.{ .table = owner }));
            try std.testing.expectEqual(r13_fin_baseline + 1, vm.testGcFinobjLen());
            try std.testing.expectEqual(@as(usize, 1), vm.gc_gray.items.len);
            try std.testing.expectEqual(@as(usize, 1), vm.testGcCountAge(.old0));
            try std.testing.expectEqual(@as(usize, 0), vm.gc_grayagain.items.len);
        } else {
            // Reserve failure: NOTHING changed.
            try r13AssertByteExact(vm, true);
        }
        // REAL full cycle after the failure: the rooted owner + metatable
        // survive and the state stays consistent with what the failure
        // published (or did not publish).
        _ = luazigGcFixed(L, 2, 0);
        if (published) {
            try std.testing.expect(owner.metatable == mt);
            try std.testing.expect(vm.testGcRegistered(.{ .table = owner }));
        } else {
            try std.testing.expect(owner.metatable == null);
            try std.testing.expect(!vm.testGcRegistered(.{ .table = owner }));
            try std.testing.expectEqual(r13_fin_baseline, vm.testGcFinobjLen());
        }
        lua_settop(L, 0);
    }
    // The boundary MUST exist within the sweep bound — otherwise the
    // protected path never reached the real allocator's success case.
    try std.testing.expect(boundary != null);
}

test "c api lua_setmetatable type-level default arm matches PUC" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);
    const vm = L.vm;
    var s = api.State.fromHandle(L);
    const mt = try vm.apiNewTable();
    var scope = try vm.openRootScope(1, 0);
    defer scope.close();
    _ = scope.protectValueAssumeCapacity(.{ .Table = mt });
    // nil, boolean, number, string, function, thread, lightuserdata.
    lua_pushnil(L);
    lua_pushboolean(L, 1);
    lua_pushnumber(L, 3.5);
    lua_pushliteral(L, "str");
    lua_pushcfunction(L, b8CfSetupvalueOom); // any C function
    // Thread via a real coroutine value:
    try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, "return coroutine.create(function() end)"));
    try std.testing.expectEqual(@as(c_int, 0), lua_pcallk(L, 0, 1, 0, 0, null));
    // Lightuserdata (the 7th type slot — not reachable from pure Lua, so
    // the PUC differential script cannot cover it; pushed from C here).
    lua_pushlightuserdata(L, @ptrFromInt(0xdeadbeef));

    // Slots: 1=nil 2=boolean 3=number 4=string 5=function 6=thread
    // 7=lightuserdata. Positive indices; a SUCCESSFUL setmetatable pops
    // its metatable.
    for (1..8) |slot| {
        s.push(.{ .Table = mt }) catch return error.OutOfMemory;
        try std.testing.expectEqual(@as(c_int, 1), lua_setmetatable(L, @intCast(slot)));
        try std.testing.expectEqual(@as(usize, 7), s.count());
    }
    // getmetatable round-trips each type slot to the SAME table.
    for (1..8) |slot| {
        try std.testing.expectEqual(@as(c_int, 1), lua_getmetatable(L, @intCast(slot)));
        try std.testing.expect(s.curThread().stack[s.curThread().top - 1].Table == mt);
        s.curThread().top -= 1; // plain pop
    }
    lua_settop(L, 0);
}

// ═══════════════════════════════════════════════════════════════════════
// P16.50-review-14 BLOCKER 2c: luaL_getmetafield (lauxlib.c:884-897) —
// covers EVERY value kind (lua_getmetatable's type-level slots included)
// and returns the metafield's REAL type tag, not a boolean; a nil
// metafield returns LUA_TNIL with the stack unchanged.
// ═══════════════════════════════════════════════════════════════════════

fn r14SilentCfun(L: ?*lua_State) callconv(.c) c_int {
    _ = L;
    return 0;
}

test "c api luaL_getmetafield: every value kind + real type tags (lauxlib.c:884-897)" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);

    // ── (1) no metatable → LUA_TNIL, stack unchanged ──
    lua_settop(L, 0);
    lua_pushinteger(L, 42);
    try std.testing.expectEqual(@as(c_int, 0), luaL_getmetafield(L, 1, "__index"));
    try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L));

    // ── (2) table owner: the REAL type tag of each metafield, and the
    // value pushed on top of the stack ──
    lua_settop(L, 0);
    lua_createtable(L, 0, 0); // owner at 1
    lua_createtable(L, 0, 7); // mt at 2
    lua_pushcfunction(L, r14SilentCfun);
    lua_setfield(L, 2, "f");
    lua_pushstring(L, "str");
    lua_setfield(L, 2, "s");
    lua_pushnumber(L, 1.5);
    lua_setfield(L, 2, "n");
    lua_pushboolean(L, 1);
    lua_setfield(L, 2, "b");
    lua_createtable(L, 0, 0);
    lua_setfield(L, 2, "t");
    _ = lua_newthread(L);
    lua_setfield(L, 2, "th");
    lua_pushlightuserdata(L, @ptrFromInt(0xcafe));
    lua_setfield(L, 2, "lu");
    try std.testing.expectEqual(@as(c_int, 1), lua_setmetatable(L, 1)); // pops mt

    const cases = [_]struct { name: [*:0]const u8, want: c_int }{
        .{ .name = "f", .want = 6 }, // LUA_TFUNCTION
        .{ .name = "s", .want = 4 }, // LUA_TSTRING
        .{ .name = "n", .want = 3 }, // LUA_TNUMBER
        .{ .name = "b", .want = 1 }, // LUA_TBOOLEAN
        .{ .name = "t", .want = 5 }, // LUA_TTABLE
        .{ .name = "th", .want = 8 }, // LUA_TTHREAD
        .{ .name = "lu", .want = 2 }, // LUA_TLIGHTUSERDATA
    };
    for (cases) |c| {
        const top_before = lua_gettop(L);
        try std.testing.expectEqual(c.want, luaL_getmetafield(L, 1, c.name));
        try std.testing.expectEqual(c.want, lua_type(L, -1));
        try std.testing.expectEqual(top_before + 1, lua_gettop(L));
        lua_pop(L, 1);
    }
    // Nil/absent metafield → LUA_TNIL with the stack unchanged.
    const top_before = lua_gettop(L);
    try std.testing.expectEqual(@as(c_int, 0), luaL_getmetafield(L, 1, "absent"));
    try std.testing.expectEqual(top_before, lua_gettop(L));

    // ── (3) TYPE-LEVEL slots: luaL_getmetafield resolves them through
    // lua_getmetatable (the old implementation saw only table/userdata
    // owners and returned 0 for every primitive) ──
    lua_settop(L, 0);
    lua_createtable(L, 0, 1); // shared mt
    lua_pushinteger(L, 7);
    lua_setfield(L, 1, "answer");
    // Targets at slot 1..7: nil, boolean, number, string, function,
    // thread, lightuserdata (mt re-pushed before each setmetatable — a
    // successful setmetatable pops it).
    lua_pushnil(L);
    lua_pushboolean(L, 1);
    lua_pushinteger(L, 42);
    lua_pushstring(L, "x");
    lua_pushcfunction(L, r14SilentCfun);
    _ = lua_newthread(L);
    lua_pushlightuserdata(L, @ptrFromInt(0xbeef));
    for (1..8) |slot| {
        lua_pushvalue(L, 1); // the shared mt
        try std.testing.expectEqual(@as(c_int, 1), lua_setmetatable(L, @intCast(slot)));
    }
    for (1..8) |slot| {
        try std.testing.expectEqual(@as(c_int, 3), luaL_getmetafield(L, @intCast(slot), "answer")); // LUA_TNUMBER
        try std.testing.expectEqual(@as(c_int, 3), lua_type(L, -1));
        lua_pop(L, 1);
    }
    lua_settop(L, 0);
}

test "c api lua_getinfo '>' sole-reference function survives in-call collector steps (poison oracle)" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);
    const vm = L.vm;
    // The poison/unmap oracle traps every freed block (PROT_NONE): a
    // Closure/Proto freed while lua_getinfo still reads it faults loudly
    // instead of silently returning stale lines. The adapter's base must
    // match the state's own allocator (luaL_newstate uses c_allocator).
    vm.testcInstallAdapterOverBase(std.heap.c_allocator);
    vm.testcArmPoisonUnmap();
    // Generational mode entered BEFORE the probe closures exist: they stay
    // young, so the first due minor step sweeps them the instant they lose
    // their last root (the popped stack slot).
    _ = luazigGcFixed(L, 7, 0); // LUA_GCGENERATIONAL

    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    source.writer.writeAll("local a=0\n") catch return error.OutOfMemory;
    for (0..120) |_| source.writer.writeAll("a=a+1\n") catch return error.OutOfMemory;
    source.writer.writeAll("return a\n\x00") catch return error.OutOfMemory;

    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const th = vm_mod.Vm.handleThread(L);

        // '>L' (no 'f'): the popped function is NOT pushed back, so the
        // whole 'L' table construction and every insert run while the
        // sole reference is off the stack. LUA_GCRESTART leaves the
        // collector due at the next allocation (PUC lapi.c:1184
        // luaE_setdebt(g, 0)), so the newtable allocation itself steps
        // the minor collection.
        try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, @ptrCast(source.written().ptr)));
        const cl = th.stack[th.top - 1].Closure;
        _ = luazigGcFixed(L, 1, 0); // LUA_GCRESTART
        vm.stats.enabled = true;
        const steps_before = vm.stats.gc_steps_auto;
        var ar: lua_Debug = std.mem.zeroes(lua_Debug);
        try std.testing.expectEqual(@as(c_int, 1), lua_getinfo(L, ">L", &ar));
        // The pressure is real: the in-call allocation ran a collector
        // step (otherwise this round would silently prove nothing).
        try std.testing.expect(vm.stats.gc_steps_auto > steps_before);
        // PUC stack effect: the table replaces the popped function (net 0).
        try std.testing.expectEqual(@as(c_int, 1), lua_gettop(L));
        try std.testing.expect(th.stack[th.top - 1] == .Table);
        // The Proto survived the steps: first and last chunk lines are set.
        _ = lua_rawgeti(L, -1, 1);
        try std.testing.expect(th.stack[th.top - 1] == .Bool);
        _ = lua_pop(L, 1);
        _ = lua_rawgeti(L, -1, 122);
        try std.testing.expect(th.stack[th.top - 1] == .Bool);
        lua_settop(L, 0);

        // '>fL': the function is pushed back BEFORE the table (PUC
        // ldebug.c:415-420 order), then the table is built while the
        // pushed copy roots it — but the pop-to-push window and the push
        // itself (stack growth) still need the root.
        try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, @ptrCast(source.written().ptr)));
        const cl2 = th.stack[th.top - 1].Closure;
        _ = luazigGcFixed(L, 1, 0);
        var ar2: lua_Debug = std.mem.zeroes(lua_Debug);
        try std.testing.expectEqual(@as(c_int, 1), lua_getinfo(L, ">fL", &ar2));
        try std.testing.expectEqual(@as(c_int, 2), lua_gettop(L));
        try std.testing.expect(th.stack[th.top - 2] == .Closure);
        try std.testing.expect(th.stack[th.top - 2].Closure == cl2); // identity, not a copy
        try std.testing.expect(th.stack[th.top - 1] == .Table);
        _ = lua_rawgeti(L, -1, 122);
        try std.testing.expect(th.stack[th.top - 1] == .Bool);
        lua_settop(L, 0);

        // The in-call root is temporary: with every reference dropped, a
        // full collection really frees both closures (address-only chain
        // walk — the freed bodies are unmapped, any stale touch faults).
        _ = luazigGcFixed(L, 2, 0); // LUA_GCCOLLECT
        var alive: usize = 0;
        var node = vm.gc_allgc_head;
        while (node) |hdr| : (node = hdr.next) {
            if (@intFromPtr(hdr) == @intFromPtr(&cl.gc)) alive += 1;
            if (@intFromPtr(hdr) == @intFromPtr(&cl2.gc)) alive += 1;
        }
        try std.testing.expectEqual(@as(usize, 0), alive);
    }
}

var bN_oom_base: std.mem.Allocator = undefined;
var bN_oom_failing: std.testing.FailingAllocator = undefined;
var bN_oom_fail_at: usize = 0;

/// Arms the failing allocator (budget `bN_oom_fail_at`), then runs the
/// '>'-form 'L' query on its sole-reference argument closure. Every
/// allocation inside the call — the temporary-root reserve, the newtable,
/// the line inserts — must turn into a LUA_ERRMEM longjmp, never a crash
/// or a leaked root.
fn bNCfGetinfoLOom(L: ?*lua_State) callconv(.c) c_int {
    bN_oom_failing = std.testing.FailingAllocator.init(bN_oom_base, .{
        .fail_index = bN_oom_fail_at,
        .resize_fail_index = bN_oom_fail_at,
    });
    L.?.vm.alloc = bN_oom_failing.allocator();
    var ar: lua_Debug = std.mem.zeroes(lua_Debug);
    _ = lua_getinfo(L.?, ">L", &ar); // OOM → LUA_ERRMEM longjmp (never returns)
    return 0;
}

test "c api lua_getinfo '>' OOM inside the 'L' construction is LUA_ERRMEM with a clean root state" {
    const L = luaL_newstate() orelse return error.OutOfMemory;
    defer lua_close(L);
    const vm = L.vm;
    _ = luazigGcFixed(L, 7, 0); // LUA_GCGENERATIONAL

    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    source.writer.writeAll("local a=0\n") catch return error.OutOfMemory;
    for (0..60) |_| source.writer.writeAll("a=a+1\n") catch return error.OutOfMemory;
    source.writer.writeAll("return a\n\x00") catch return error.OutOfMemory;

    // fail_at walks the fallible sites inside the call: the RootScope
    // reserve, the newtable creation and the first inserts. Every lane
    // must raise LUA_ERRMEM through the pcall boundary.
    var fail_at: usize = 0;
    while (fail_at < 4) : (fail_at += 1) {
        // Fresh sole-reference closure as the C function's argument
        // (PUC call protocol: function first, arguments above it); the
        // '>' form pops it from the C window.
        lua_pushcfunction(L, bNCfGetinfoLOom);
        try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, @ptrCast(source.written().ptr)));
        bN_oom_base = vm.alloc;
        bN_oom_fail_at = fail_at;
        const status = lua_pcallk(L, 1, 0, 0, 0, null);
        vm.alloc = bN_oom_base; // restore before any other API use
        try std.testing.expectEqual(@as(c_int, 4), status); // LUA_ERRMEM
        try std.testing.expect(vm.errThread().err_has_obj);
        try std.testing.expectEqualStrings("not enough memory", vm.errThread().err_obj.String.bytes());
        // The landing pad dropped the abandoned in-call scope: the root
        // state is back to the boundary mark (no leaked temporary root).
        try std.testing.expectEqual(@as(usize, 0), vm.gc_root_depth);
        try std.testing.expectEqual(@as(usize, 0), vm.gc_root_values.items.len);
        // A real next cycle runs (the failed call's popped closure is
        // unrooted garbage — swept without touching stale state) and the
        // VM stays reusable.
        _ = luazigGcFixed(L, 2, 0); // LUA_GCCOLLECT
        try std.testing.expectEqual(@as(c_int, 0), luaL_loadstring(L, "return 1"));
        lua_pop(L, 1);
    }
}
