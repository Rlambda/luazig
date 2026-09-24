const std = @import("std");
const stdio = @import("util").stdio;

const source_mod = @import("source.zig");
const vm_mod = @import("vm.zig");
const ltable = @import("ltable.zig");

pub const ApiError = std.mem.Allocator.Error || error{
    Type,
    Runtime,
    Syntax,
    Memory,
    InvalidIndex,
    InvalidState,
};

pub const Type = enum(u8) {
    nil,
    boolean,
    number,
    string,
    table,
    function,
    thread,
    userdata,
    lightuserdata,
};

pub const Status = enum(u8) {
    ok,
    yielded,
    runtime_error,
    syntax_error,
    memory_error,
    error_handler_error,
};

/// PUC `LUA_OP*` arithmetic operator codes (lua.h:215-228). Used by
/// `State.arith`. Order matches PUC exactly.
pub const ArithOp = enum(u8) {
    add, // LUA_OPADD (0)
    sub, // LUA_OPSUB (1)
    mul, // LUA_OPMUL (2)
    mod, // LUA_OPMOD (3)
    pow, // LUA_OPPOW (4)
    div, // LUA_OPDIV (5)
    idiv, // LUA_OPIDIV (6)
    band, // LUA_OPBAND (7)
    bor, // LUA_OPBOR (8)
    bxor, // LUA_OPBXOR (9)
    shl, // LUA_OPSHL (10)
    shr, // LUA_OPSHR (11)
    unm, // LUA_OPUNM (12)
    bnot, // LUA_OPBNOT (13)
};

/// PUC `LUA_OPEQ/LT/LE` comparison operator codes (lua.h:232-234). Used by
/// `State.compare`.
pub const CompareOp = enum(u8) {
    eq, // LUA_OPEQ (0)
    lt, // LUA_OPLT (1)
    le, // LUA_OPLE (2)
};

pub const Options = struct {
    allocator: std.mem.Allocator,
};

pub const State = struct {
    // BORROWS *Vm — same pointer c_api.zig uses. State no longer owns a Vm by
    // value; it wraps a heap-allocated *Vm so that api.State and c_api.zig
    // share the same execution state.
    vm: *vm_mod.Vm,
    /// The lua_State handle this State operates on. Every stack operation
    /// resolves `handle → thread → TOP frame window` on `thread.stack` —
    /// the single stack authority: the C-API window lives directly on the
    /// thread's stack.
    /// `init` uses the main handle, `fromVm` the active handle, `fromHandle`
    /// the given one (PUC: the lua_State IS the thread).
    handle: *vm_mod.lua_State,

    /// The thread whose anchored C-API window this State addresses.
    pub fn curThread(self: *const State) *vm_mod.Thread {
        return vm_mod.Vm.handleThread(self.handle);
    }

    /// PUC `lua_gettop`: visible slots in the anchored window.
    pub fn count(self: *const State) usize {
        return vm_mod.Vm.cWindowCount(self.curThread());
    }

    /// PUC `index2value`: resolve `idx` to an ABSOLUTE `th.stack` slot in
    /// the anchored window, or null for an invalid index. Pseudo-indices
    /// (registry/upvalues) are resolved by the call sites that accept them.
    pub fn slot(self: *const State, idx: i32) ?usize {
        return vm_mod.Vm.cWindowSlot(self.curThread(), idx);
    }

    /// The value at `idx` as a COPY. Callers may run nested execution (which
    /// can grow — and therefore move — `th.stack`): a pointer into the stack
    /// would dangle across growth, a copy cannot.
    pub fn valueAt(self: *const State, idx: i32) ?vm_mod.Value {
        const s = self.slot(idx) orelse return null;
        return self.curThread().stack[s];
    }

    /// PUC `api_incr_top`: push one value onto the anchored window.
    pub fn push(self: *State, v: vm_mod.Value) ApiError!void {
        self.vm.cWindowPush(self.curThread(), v) catch |e| return mapVmError(e);
    }

    /// Reserve one window slot for a value
    /// that does not exist yet. PUC shape: the C stack slot is reserved
    /// BEFORE the constructor runs (luaD_checkstack at C entry —
    /// `api_incr_top` itself never allocates), so a constructed-but-not-
    /// yet-rooted object never crosses a fallible operation before its
    /// rooting store. Every construct-then-push constructor calls this
    /// FIRST; the subsequent `push` then hits the reserved capacity and
    /// cannot allocate — without it, a push at a FULL window grows the
    /// stack (a counted allocation), and the testc adapter's emergency
    /// GC + retry (PUC luaM_realloc_ tryagain) sweeps the constructed
    /// unrooted object and the retried push stores a dangling pointer
    /// (full window + pushlstring, dangling at fail k=3).
    fn reservePushSlot(self: *State) ApiError!void {
        self.vm.cWindowEnsure(self.curThread(), 1) catch |e| return mapVmError(e);
    }

    /// Push a slice of values onto the anchored window (alias-safe source).
    pub fn pushSlice(self: *State, vs: []const vm_mod.Value) ApiError!void {
        self.vm.cWindowPushSlice(self.curThread(), vs) catch |e| return mapVmError(e);
    }

    /// PUC `lua_settop`-based count change (TBC close on lowering — the
    /// class-5 contract; nil-fill on raising).
    pub fn setCount(self: *State, n: usize) ApiError!void {
        self.vm.cWindowSetCount(self.curThread(), n) catch |e| return mapDispatchError(e);
    }

    /// PUC `lua_pop` = `lua_settop(-n-1)`: close-then-lower.
    pub fn popN(self: *State, n: usize) ApiError!void {
        const c = self.count();
        if (n > c) return error.InvalidIndex;
        try self.setCount(c - n);
    }

    /// Create a new VM (heap-allocated) and wrap it.
    pub fn init(opts: Options) State {
        const alloc = opts.allocator;
        const ptr = alloc.create(vm_mod.Vm) catch @panic("api.State.init: out of memory");
        ptr.* = vm_mod.Vm.init(alloc, false);
        _ = ptr.setupMainHandle() catch @panic("api.State.init: out of memory");
        return .{ .vm = ptr, .handle = ptr.main_handle.? };
    }

    /// Clean up the VM and free its heap allocation.
    pub fn deinit(self: *State) void {
        // Tear the Vm down FIRST (matching lua_close in c_api.zig): finalizers
        // running inside vm.deinit may touch main_thread.api_handle (whose
        // window is a GC root), so the main handle must stay alive until
        // then. gcFreeObject(.thread) skips main handles (P15.83k), so the
        // handle is freed exactly once, here.
        self.vm.deinit();
        // P16.50-review-5: capture the allocator AFTER deinit. Before the
        // teardown the field may hold the testC adapter, whose control is
        // released inside vm.deinit — freeing the vm struct through it
        // would use a destroyed control. vm.deinit's tail restores the
        // original base allocator, which is also what allocated the vm
        // struct at State.init. The field read is memory-safe: the struct
        // is not freed until the destroy below.
        const alloc = self.vm.alloc;
        if (self.vm.main_handle) |h| {
            self.vm.freeStateHandle(h);
        }
        alloc.destroy(self.vm);
    }

    /// Wrap an existing *Vm without taking ownership.
    /// Used by c_api.zig to create a State from a lua_State*.
    /// The handle resolves to `vm.cur_handle` — the currently active
    /// handle (falling back to the main handle).
    pub fn fromVm(vm: *vm_mod.Vm) State {
        return .{ .vm = vm, .handle = vm.cur_handle orelse vm.main_handle.? };
    }

    /// Wrap an existing `*lua_State` handle without taking ownership.
    /// Used by c_api.zig to create a State from a `?*lua_State` parameter.
    /// All operations address THIS handle's thread window even if
    /// `vm.cur_handle` is later reassigned (e.g. during coroutine resume).
    pub fn fromHandle(h: *vm_mod.lua_State) State {
        return .{ .vm = h.vm, .handle = h };
    }

    pub fn gettop(self: *const State) usize {
        return self.count();
    }

    pub fn settop(self: *State, idx: i32) ApiError!void {
        const c = self.count();
        var new_count: usize = 0;
        if (idx >= 0) {
            new_count = @intCast(idx);
        } else {
            const c_i: i64 = @intCast(c);
            const idx_i: i64 = @intCast(idx);
            const nt = c_i + idx_i + 1;
            if (nt < 0) return error.InvalidIndex;
            new_count = @intCast(nt);
        }
        try self.setCount(new_count);
    }

    pub fn pop(self: *State, n: usize) ApiError!void {
        try self.popN(n);
    }

    pub fn absindex(self: *State, idx: i32) ApiError!i32 {
        if (idx == 0) return error.InvalidIndex;
        const c = self.count();
        if (idx > 0) {
            if (normalizeIndex(idx, c) == null) return error.InvalidIndex;
            return idx;
        }
        if (normalizeIndex(idx, c) == null) return error.InvalidIndex;
        return @intCast(@as(i64, @intCast(c)) + @as(i64, idx) + 1);
    }

    /// PUC `lua_checkstack` (lapi.c:lua_checkstack): ensure at least `n`
    /// extra stack slots are available. Returns void on success; the C shim
    /// translates the error into a 0 return value.
    pub fn checkstack(self: *State, n: usize) ApiError!void {
        self.vm.cWindowEnsure(self.curThread(), n) catch |e| return mapVmError(e);
    }

    pub fn insert(self: *State, idx: i32) ApiError!void {
        try self.rotate(idx, 1);
    }

    pub fn remove(self: *State, idx: i32) ApiError!void {
        try self.rotate(idx, -1);
        try self.pop(1);
    }

    /// PUC 5.5 removed `lua_replace` (replaced by `lua_copy` + `lua_pop`);
    /// this Zig-level convenience keeps the old shape: copy the top value
    /// to `idx`, then pop the top (close-then-lower, like `lua_pop`).
    pub fn replace(self: *State, idx: i32) ApiError!void {
        const c = self.count();
        if (c == 0) return error.InvalidState;
        const s = self.slot(idx) orelse return error.InvalidIndex;
        const th = self.curThread();
        th.stack[s] = th.stack[th.top - 1];
        try self.popN(1);
    }

    pub fn copy(self: *State, from_idx: i32, to_idx: i32) ApiError!void {
        const from = self.slot(from_idx) orelse return error.InvalidIndex;
        const to = self.slot(to_idx) orelse return error.InvalidIndex;
        const th = self.curThread();
        th.stack[to] = th.stack[from];
    }

    pub fn rotate(self: *State, idx: i32, n: i32) ApiError!void {
        const s = self.slot(idx) orelse return error.InvalidIndex;
        const th = self.curThread();
        const slice = th.stack[s..th.top];
        if (slice.len <= 1) return;

        var nmod = @mod(@as(i64, n), @as(i64, @intCast(slice.len)));
        if (nmod < 0) nmod += @intCast(slice.len);
        if (nmod == 0) return;

        // Zig rotates left; Lua's lua_rotate with positive n rotates right.
        const left: usize = slice.len - @as(usize, @intCast(nmod));
        std.mem.rotate(vm_mod.Value, slice, left);
    }

    pub fn concat(self: *State, n: usize) ApiError!void {
        const c = self.count();
        if (n > c) return error.InvalidIndex;
        if (n == 0) {
            try self.pushstring("");
            return;
        }
        if (n == 1) return;

        const th = self.curThread();
        const start = th.top - n;
        // Indexed reads: apiConcat dispatches metamethods (nested execution
        // may grow th.stack); re-deriving th.stack[i] each iteration stays
        // valid across the realloc, and the source values stay rooted on
        // the stack below the metamethod frame for the whole loop.
        // M1: the accumulated result lives in th.stack[start] (PUC
        // luaV_concat shape — intermediates occupy the operand slot), so
        // each fresh result string is STACK-ROOTED across the NEXT
        // iteration's fallible apiConcat (a Zig local is invisible to the
        // emergency GC; the old local-only acc could be swept mid-loop).
        var acc = th.stack[start];
        var i = start + 1;
        while (i < th.top) : (i += 1) {
            acc = self.vm.apiConcat(acc, th.stack[i]) catch |e| return mapVmError(e);
            th.stack[start] = acc;
        }
        // PUC luaV_concat (lvm.c): plain truncation — no TBC close in the
        // concat loop.
        th.top = start;
        // The push lands in the slot the operands vacated (capacity is
        // guaranteed: start+1 <= the pre-truncation top <= stack.len).
        try self.push(acc);
    }

    /// PUC `lua_arith` (lapi.c:lua_arith): perform an arithmetic operation
    /// on the top 1–2 stack values. Unary ops (UNM, BNOT) duplicate the top
    /// as both operands (PUC: `setobjs2s(L, top, top-1); api_incr_top`) and
    /// leave the result in place; binary ops write the result at top-2 and
    /// lower top by one (PUC: plain `L->top.p--`). Handles Int/Num directly;
    /// falls back to metamethods for tables/userdata.
    pub fn arith(self: *State, op: ArithOp) ApiError!void {
        const th = self.curThread();
        const is_unary = (op == .unm or op == .bnot);
        const need: usize = if (is_unary) 1 else 2;
        if (self.count() < need) return error.InvalidState;

        const result: vm_mod.Value = if (is_unary) blk: {
            const v = th.stack[th.top - 1];
            break :blk self.vm.apiArith(@intFromEnum(op), v, v) catch |e| return mapVmError(e);
        } else blk: {
            const b = th.stack[th.top - 1];
            const a = th.stack[th.top - 2];
            break :blk self.vm.apiArith(@intFromEnum(op), a, b) catch |e| return mapVmError(e);
        };

        if (is_unary) {
            th.stack[th.top - 1] = result;
        } else {
            th.top -= 1;
            th.stack[th.top - 1] = result;
        }
    }

    /// PUC `lua_rawequal` (lapi.c:lua_rawequal): raw equality without
    /// metamethods. Returns true if the values at idx1 and idx2 are the
    /// same type and equal value (pointer identity for tables/closures,
    /// byte comparison for strings, numeric cross-comparison for Int/Num).
    pub fn rawequal(self: *State, idx1: i32, idx2: i32) bool {
        const v1 = self.valueAt(idx1) orelse return false;
        const v2 = self.valueAt(idx2) orelse return false;
        return vm_mod.Vm.apiRawEqual(v1, v2);
    }

    /// PUC `lua_compare` (lapi.c:lua_compare): comparison with metamethods.
    /// For numbers and strings: direct comparison. For tables/userdata:
    /// tries __eq/__lt/__le metamethods. Returns false if either index is
    /// invalid or the comparison is not possible.
    pub fn compare(self: *State, idx1: i32, idx2: i32, op: CompareOp) ApiError!bool {
        const a = self.valueAt(idx1) orelse return false;
        const b = self.valueAt(idx2) orelse return false;
        return self.vm.apiCompare(@intFromEnum(op), a, b) catch |e| return mapVmError(e);
    }

    /// PUC `lua_len` (lapi.c:lua_len): push the length of the value at idx.
    /// For strings: byte length. For tables: border length (or __len
    /// metamethod). For other types: tries __len metamethod, errors if none.
    pub fn len(self: *State, idx: i32) ApiError!void {
        const v = self.valueAt(idx) orelse return error.InvalidIndex;
        const result = self.vm.apiLen(v) catch |e| return mapVmError(e);
        try self.push(result);
    }

    /// PUC `lua_gc` (lapi.c:lua_gc): garbage collector control. Maps
    /// LUA_GC* constants to VM GC operations.
    pub fn gc(self: *State, what: i32, data: i32) i32 {
        return self.vm.apiGc(what, data);
    }

    /// PUC `lua_status` (lapi.c:lua_status): return the status of the
    /// thread. PUC returns LUA_YIELD (1) when the thread is suspended
    /// after a yield, LUA_OK (0) for running/main threads, and error
    /// codes when dead-with-error.
    ///
    /// luazig stores the PUC status code in `Thread.api_status` (mirroring
    /// PUC's `L->status`), updated at every lifecycle transition. Resolved
    /// per-handle from this State's thread (PUC: the lua_State IS the
    /// thread).
    pub fn status(self: *State) c_int {
        return self.curThread().api_status;
    }

    /// PUC `lua_pushthread` (lapi.c:lua_pushthread): push the current thread
    /// onto the stack as a thread Value. Returns 1 if the pushed thread is
    /// the main thread, 0 otherwise (PUC: `cast_int(L == mainthread(G(L)))`).
    ///
    /// P15.83k: threads are first-class Values for every state, including
    /// the main one (`Vm.main_thread`). Resolved per-handle from this
    /// State's thread.
    pub fn pushthread(self: *State) c_int {
        const th = self.curThread();
        const is_main = self.vm.main_thread == th;
        self.push(.{ .Thread = th }) catch return 0;
        return if (is_main) 1 else 0;
    }

    pub fn pushnil(self: *State) ApiError!void {
        try self.push(.Nil);
    }

    pub fn pushboolean(self: *State, v: bool) ApiError!void {
        try self.push(.{ .Bool = v });
    }

    pub fn pushinteger(self: *State, v: i64) ApiError!void {
        try self.push(.{ .Int = v });
    }

    pub fn pushnumber(self: *State, v: f64) ApiError!void {
        try self.push(.{ .Num = v });
    }

    pub fn pushstring(self: *State, s: []const u8) ApiError!void {
        try self.reservePushSlot();
        try self.push(.{ .String = try self.vm.internStr(s) });
    }

    pub fn pushvalue(self: *State, idx: i32) ApiError!void {
        const v = self.valueAt(idx) orelse return error.InvalidIndex;
        try self.push(v);
    }

    pub fn typeOf(self: *const State, idx: i32) ?Type {
        const v = self.valueAt(idx) orelse return null;
        return valueType(v);
    }

    pub fn isuserdata(self: *const State, idx: i32) bool {
        // PUC lua_isuserdata: true for both full userdata and light userdata.
        const t = self.typeOf(idx) orelse return false;
        return t == .userdata or t == .lightuserdata;
    }

    pub fn toboolean(self: *const State, idx: i32) bool {
        const v = self.valueAt(idx) orelse return false;
        return switch (v) {
            .Nil => false,
            .Bool => |b| b,
            else => true,
        };
    }

    pub fn tointeger(self: *const State, idx: i32) ?i64 {
        const v = self.valueAt(idx) orelse return null;
        return switch (v) {
            .Int => |i| i,
            .Num => |n| if (n == @round(n)) @as(i64, @intFromFloat(n)) else null,
            else => null,
        };
    }

    pub fn tonumber(self: *const State, idx: i32) ?f64 {
        const v = self.valueAt(idx) orelse return null;
        return switch (v) {
            .Int => |i| @floatFromInt(i),
            .Num => |n| n,
            else => null,
        };
    }

    pub fn tostring(self: *const State, idx: i32) ?[]const u8 {
        const v = self.valueAt(idx) orelse return null;
        return switch (v) {
            .String => |s| s.bytes(),
            else => null,
        };
    }

    // -----------------------------------------------------------------------
    // Type predicates (PUC lapi.c:lua_is*)
    // -----------------------------------------------------------------------

    /// PUC `lua_isnumber` (lapi.c): true if the value is a number or a string
    /// convertible to a number. Currently checks Int/Num only; string-to-number
    /// conversion will be added when `lua_tonumberx` supports it.
    pub fn isnumber(self: *const State, idx: i32) bool {
        const v = self.valueAt(idx) orelse return false;
        return switch (v) {
            .Int, .Num => true,
            else => false,
        };
    }

    /// PUC `lua_isstring` (lapi.c): true if the value is a string or a number
    /// (both are "string-convertible" in PUC's cvt2str sense).
    pub fn isstring(self: *const State, idx: i32) bool {
        const v = self.valueAt(idx) orelse return false;
        return switch (v) {
            .String, .Int, .Num => true,
            else => false,
        };
    }

    /// PUC `lua_isinteger` (lapi.c): true if the value is specifically an
    /// integer (not a float).
    pub fn isinteger(self: *const State, idx: i32) bool {
        const v = self.valueAt(idx) orelse return false;
        return v == .Int;
    }

    /// PUC `lua_iscfunction` (lapi.c): true if the value is a C closure
    /// (a Closure with `c_func != null`). Lua closures (bytecode protos)
    /// return false.
    pub fn iscfunction(self: *const State, idx: i32) bool {
        const v = self.valueAt(idx) orelse return false;
        return switch (v) {
            .Closure => |c| c.c_func != null,
            else => false,
        };
    }

    // -----------------------------------------------------------------------
    // Conversions (PUC lapi.c:lua_to*)
    // -----------------------------------------------------------------------

    /// PUC `lua_tolstring` (lapi.c:lua_tolstring): convert value to string,
    /// returning its bytes. For strings, returns the bytes directly. For
    /// numbers (Int/Num), converts to a string representation IN PLACE on the
    /// stack (replacing the original value), matching PUC's `tonumnsstr` +
    /// `setobj2s` behavior. Returns null for non-convertible types.
    ///
    /// The returned bytes are NUL-terminated in luazig's string storage
    /// (see `createLuaString`: `body[raw.len] = 0`), so the C shim can safely
    /// cast to `[*:0]const u8`.
    ///
    /// P16.50-review-5 B2: PUC lua_tolstring on a number goes through
    /// luaS_new (an allocation) — an OOM there is LUA_ERRMEM, not a silent
    /// null. The signature is now fallible: `ApiError!?[]const u8`.
    pub fn tolstring(self: *State, idx: i32) ApiError!?[]const u8 {
        const s = self.slot(idx) orelse return null;
        const th = self.curThread();
        switch (th.stack[s]) {
            .String => |st| return st.bytes(),
            .Int, .Num => {
                // PUC lua_tolstring: convert number to string in place on stack.
                // valueToInternedStr uses the same formatting as PUC's
                // luaO_tostringbuff (%.14g equivalent + ".0" for integer floats).
                const ls = self.vm.valueToInternedStr(th.stack[s]) catch |e| return mapDispatchError(e);
                th.stack[s] = .{ .String = ls };
                return th.stack[s].String.bytes();
            },
            else => return null,
        }
    }

    /// PUC `lua_rawlen` (lapi.c:lua_rawlen): raw length without metamethods.
    /// String: byte length. Table: border length (luaH_getn). Userdata:
    /// payload size. Returns 0 for other types.
    pub fn rawlen(self: *State, idx: i32) usize {
        const v = self.valueAt(idx) orelse return 0;
        return switch (v) {
            .String => |s| s.bytes().len,
            .Table => |t| @intCast(self.vm.tableBorderLen(t)),
            .Userdata => |ud| ud.payload.len,
            else => 0,
        };
    }

    /// PUC `lua_tocfunction` (lapi.c:lua_tocfunction): return the C function
    /// pointer from a Closure, or null if the value is not a C closure.
    pub fn tocfunction(self: *const State, idx: i32) ?*const fn (?*vm_mod.lua_State) callconv(.c) c_int {
        const v = self.valueAt(idx) orelse return null;
        return switch (v) {
            .Closure => |c| c.c_func,
            else => null,
        };
    }

    /// PUC `lua_tothread` (lapi.c:lua_tothread): return the Thread pointer at
    /// idx, or null if the value is not a thread.
    pub fn tothread(self: *State, idx: i32) ?*vm_mod.Thread {
        return self.threadAt(idx);
    }

    pub fn getglobal(self: *State, name: []const u8) ApiError!Type {
        const v = self.vm.apiGetGlobal(name);
        try self.push(v);
        return valueType(v);
    }

    pub fn setglobal(self: *State, name: []const u8) ApiError!void {
        const th = self.curThread();
        if (self.count() == 0) return error.InvalidState;
        const v = th.stack[th.top - 1];
        // PUC auxsetstr: the set runs first (the value stays rooted on the
        // stack across the fallible table write), the pop is plain.
        self.vm.apiSetGlobal(name, v) catch |e| return mapVmError(e);
        th.top -= 1;
    }

    pub fn newtable(self: *State) ApiError!void {
        try self.reservePushSlot();
        const t = self.vm.apiNewTable() catch |e| return mapVmError(e);
        try self.push(.{ .Table = t });
    }

    pub fn newthread(self: *State) ApiError!void {
        try self.reservePushSlot();
        const th = self.vm.apiNewThread(.Nil) catch |e| return mapVmError(e);
        try self.push(.{ .Thread = th });
    }

    /// PUC `lua_xmove` (lapi.c:lua_xmove): move `n` values between the
    /// windows of two threads. A null thread index addresses this State's
    /// own thread. Same-thread moves are a no-op (PUC). The destination
    /// push happens while the source values are still live (the
    /// alias-safe cWindowPushSlice captures the source offset before any
    /// growth); the source truncation is plain (PUC: `from->top.p -= n`).
    pub fn xmove(self: *State, from_thread_idx: ?i32, to_thread_idx: ?i32, n: usize) ApiError!void {
        const from_th = if (from_thread_idx) |idx| (self.threadAt(idx) orelse return error.Type) else self.curThread();
        const to_th = if (to_thread_idx) |idx| (self.threadAt(idx) orelse return error.Type) else self.curThread();
        if (from_th == to_th) return;
        if (n > vm_mod.Vm.cWindowCount(from_th)) return error.InvalidIndex;
        if (n == 0) return;

        const start = from_th.top - n;
        self.vm.cWindowPushSlice(to_th, from_th.stack[start..from_th.top]) catch |e| return mapVmError(e);
        from_th.top = start;
        // xmove safepoint — both windows must still
        // hold their live anchors (the source truncation cannot cross
        // the window base; the destination push stays within its stack).
        if (vm_mod.Vm.WINDOW_DEBUG_CHECKS) {
            self.vm.debugCheckWindowAt(from_th, .xmove);
            self.vm.debugCheckWindowAt(to_th, .xmove);
        }
    }

    /// PUC `lua_resume` (ldo.c:lua_resume) over the coroutine's anchored
    /// window. First resume: the host-pushed function takes slot F
    /// (`firstArg - 1`); the function and arguments are consumed here and
    /// the trampoline stages the body AT F (PUC `ccall(firstArg - 1,
    /// MULTRET, 0)` — the body CallInfo's func is the host function's
    /// slot; base_ci itself is never repositioned). F is remembered on the
    /// thread so every later resume's results land at [F, F+nres) via
    /// cWindowMoveResults (PUC poscall's moveresults dst = func slot).
    ///
    /// Error windows (verified against PUC 5.5.0 — class 6): a rejection of
    /// a non-resumable thread pops the arguments and appends the message
    /// once (PUC resume_error); a real error leaves [residue?, err, err] —
    /// the error object duplicated on top of the raiser's residue
    /// (PUC luaD_seterrorobj at the resume boundary). Yield: the yielded
    /// values are already parked at the suspended frame's window top.
    pub fn @"resume"(self: *State, thread_idx: i32, nargs: usize) Status {
        const th = self.threadAt(thread_idx) orelse return .runtime_error;
        const vm = self.vm;
        const first_resume = !th.started;
        var func_slot: usize = undefined;
        var args: []const vm_mod.Value = undefined;
        if (first_resume) {
            const callee_needed = !isCallableValue(vm, th.callee);
            const need = nargs + @as(usize, @intFromBool(callee_needed));
            const cnt = vm_mod.Vm.cWindowCount(th);
            if (cnt < need) return .runtime_error;
            func_slot = vm_mod.Vm.cWindowBase(th) + cnt - need;
            if (callee_needed) {
                const callee = th.stack[func_slot];
                if (!isCallableValue(vm, callee)) return .runtime_error;
                th.callee = callee;
            }
            th.resume_func_slot = func_slot;
            args = th.stack[func_slot + need - nargs .. func_slot + need];
            // Consume func+args: the trampoline stages the body at the
            // lowered top = F (PUC precall uses them in place).
            th.top = func_slot;
        } else {
            const cnt = vm_mod.Vm.cWindowCount(th);
            if (cnt < nargs) return .runtime_error;
            func_slot = th.resume_func_slot orelse (vm_mod.Vm.cWindowBase(th) + cnt - nargs);
            args = th.stack[th.top - nargs .. th.top];
        }
        // PUC resume: only a suspended (or never-started) thread resumes;
        // anything else is resume_error (pop the arguments, append the
        // message once).
        const reject_before_call = !first_resume and th.status != .suspended;

        // P16.50-review-7 BLOCKER 4: apiResumeThread returns the resume's
        // EXACT tuple ([ok] ++ values) as an owned slice — no 64-slot
        // window (the old window truncated every host resume to 63
        // results; PUC lua_resume returns ALL results on the stack).
        const res = vm.apiResumeThread(th, args) catch {
            // apiResumeThread itself failed (owned-slice OOM): consume the
            // staging. PUC would install the fixed MEMERRMSG here — an
            // allocation we cannot trust on this path; the window stays
            // empty at F.
            th.top = func_slot;
            return .memory_error;
        };
        defer vm.alloc.free(res);
        const ok = res.len > 0 and res[0] == .Bool and res[0].Bool;

        if (!ok) {
            if (res.len < 2) return .runtime_error;
            if (reject_before_call) {
                // PUC resume_error: pop the arguments, append the message
                // once (plain pop — the engine rejected before running).
                th.top -= @min(nargs, th.top - vm_mod.Vm.cWindowBase(th));
                vm.cWindowPush(th, res[1]) catch return .memory_error;
                return .runtime_error;
            }
            // Real error: [residue?, err, err] anchored at F. Raw top — the
            // thread is dead; PUC never closes TBC at the error boundary.
            th.top = func_slot;
            if (th.api_err_residue) |r| vm.cWindowPush(th, r) catch return .memory_error;
            vm.cWindowPush(th, res[1]) catch return .memory_error;
            vm.cWindowPush(th, res[1]) catch return .memory_error;
            return .runtime_error;
        }

        if (th.status == .suspended) {
            // Yield: the yielded values are already parked at the suspended
            // frame's window top — the window IS the result.
            return .yielded;
        }
        // Completion: PUC poscall to the body frame's func slot F.
        vm.cWindowMoveResults(th, func_slot, res[1..], -1) catch return .memory_error;
        return .ok;
    }

    pub fn yield(self: *State, nresults: usize) ApiError!void {
        const th = self.curThread();
        if (nresults > self.count()) return error.InvalidIndex;
        const base = th.top - nresults;
        self.vm.apiYield(th.stack[base..th.top]) catch |err| switch (err) {
            error.RuntimeError, error.Yield => return error.Runtime,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    pub fn isyieldable(self: *State, thread_idx: ?i32) ApiError!bool {
        const th = if (thread_idx) |idx| self.threadAt(idx) orelse return error.Type else null;
        return self.vm.apiIsYieldable(th) catch |e| return mapVmError(e);
    }

    pub fn gettable(self: *State, idx: i32) ApiError!Type {
        const th = self.curThread();
        if (self.count() == 0) return error.InvalidState;
        const s = self.slot(idx) orelse return error.InvalidIndex;
        const key = th.stack[th.top - 1];
        const object = th.stack[s];
        const out = self.vm.apiGetTable(object, key) catch |e| return mapVmError(e);
        th.top -= 1; // PUC lua_gettable: plain pop of the key
        try self.push(out);
        return valueType(out);
    }

    pub fn settable(self: *State, idx: i32) ApiError!void {
        const th = self.curThread();
        if (self.count() < 2) return error.InvalidState;
        const s = self.slot(idx) orelse return error.InvalidIndex;
        const value = th.stack[th.top - 1];
        const key = th.stack[th.top - 2];
        const object = th.stack[s];
        self.vm.apiSetTable(object, key, value) catch |e| return mapVmError(e);
        th.top -= 2; // PUC lua_settable: plain pop of value and key
    }

    pub fn getfield(self: *State, idx: i32, key: []const u8) ApiError!Type {
        const registry_idx: c_int = -1001000;
        const object: vm_mod.Value = if (idx == registry_idx) blk: {
            const reg = self.vm.apiEnsureRegistry() catch |e| return mapVmError(e);
            break :blk .{ .Table = reg };
        } else blk: {
            break :blk self.valueAt(idx) orelse return error.InvalidIndex;
        };
        const out = self.vm.apiGetTable(object, .{ .String = try self.vm.internStr(key) }) catch |e| return mapVmError(e);
        try self.push(out);
        return valueType(out);
    }

    pub fn setfield(self: *State, idx: i32, key: []const u8) ApiError!void {
        const th = self.curThread();
        if (self.count() == 0) return error.InvalidState;
        const registry_idx: c_int = -1001000;
        const object: vm_mod.Value = if (idx == registry_idx) blk: {
            const reg = self.vm.apiEnsureRegistry() catch |e| return mapVmError(e);
            break :blk .{ .Table = reg };
        } else blk: {
            const s = self.slot(idx) orelse return error.InvalidIndex;
            break :blk th.stack[s];
        };
        const value = th.stack[th.top - 1];
        self.vm.apiSetTable(object, .{ .String = try self.vm.internStr(key) }, value) catch |e| return mapVmError(e);
        th.top -= 1; // PUC auxsetstr: plain pop of the value
    }

    pub fn geti(self: *State, idx: i32, n: i64) ApiError!Type {
        const object = self.valueAt(idx) orelse return error.InvalidIndex;
        const out = self.vm.apiGetTable(object, .{ .Int = n }) catch |e| return mapVmError(e);
        try self.push(out);
        return valueType(out);
    }

    pub fn seti(self: *State, idx: i32, n: i64) ApiError!void {
        const th = self.curThread();
        if (self.count() == 0) return error.InvalidState;
        const s = self.slot(idx) orelse return error.InvalidIndex;
        const object = th.stack[s];
        const value = th.stack[th.top - 1];
        self.vm.apiSetTable(object, .{ .Int = n }, value) catch |e| return mapVmError(e);
        th.top -= 1; // PUC lua_seti: plain pop of the value
    }

    pub fn rawget(self: *State, idx: i32) ApiError!Type {
        const th = self.curThread();
        if (self.count() == 0) return error.InvalidState;
        const s = self.slot(idx) orelse return error.InvalidIndex;
        const tbl = switch (th.stack[s]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const key = th.stack[th.top - 1];
        const out = self.vm.apiRawGet(tbl, key);
        th.top -= 1; // PUC lua_rawget: plain pop of the key
        try self.push(out);
        return valueType(out);
    }

    pub fn rawset(self: *State, idx: i32) ApiError!void {
        const th = self.curThread();
        if (self.count() < 2) return error.InvalidState;
        const s = self.slot(idx) orelse return error.InvalidIndex;
        const tbl = switch (th.stack[s]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const value = th.stack[th.top - 1];
        const key = th.stack[th.top - 2];
        self.vm.apiRawSet(tbl, key, value) catch |e| return mapVmError(e);
        th.top -= 2; // PUC lua_rawset: plain pop of index and value
    }

    pub fn rawgeti(self: *State, idx: i32, n: i64) ApiError!Type {
        const object = self.valueAt(idx) orelse return error.InvalidIndex;
        const tbl = switch (object) {
            .Table => |t| t,
            else => return error.Type,
        };
        const out = self.vm.apiRawGet(tbl, .{ .Int = n });
        try self.push(out);
        return valueType(out);
    }

    pub fn rawseti(self: *State, idx: i32, n: i64) ApiError!void {
        const th = self.curThread();
        if (self.count() == 0) return error.InvalidState;
        const s = self.slot(idx) orelse return error.InvalidIndex;
        const tbl = switch (th.stack[s]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const value = th.stack[th.top - 1];
        self.vm.apiRawSet(tbl, .{ .Int = n }, value) catch |e| return mapVmError(e);
        th.top -= 1; // PUC lua_rawseti: plain pop of the value
    }

    /// PUC `lua_rawgetp` (lapi.c): raw table access with a light userdata
    /// pointer key. Pushes `t[p]` (no metamethods). Returns the value type.
    /// Note: PUC allows NULL `p` (creating a light userdata wrapping NULL),
    /// but Zig's `*anyopaque` cannot represent address 0. A null `p` returns
    /// `error.InvalidIndex` — a justified deviation since no real C code uses
    /// NULL pointer keys.
    pub fn rawgetp(self: *State, idx: i32, p: ?*anyopaque) ApiError!Type {
        const object = self.valueAt(idx) orelse return error.InvalidIndex;
        const tbl = switch (object) {
            .Table => |t| t,
            else => return error.Type,
        };
        const key: *anyopaque = p orelse return error.InvalidIndex;
        const out = self.vm.apiRawGet(tbl, .{ .LightUserdata = key });
        try self.push(out);
        return valueType(out);
    }

    /// PUC `lua_rawsetp` (lapi.c): raw table set with a light userdata
    /// pointer key. Performs `t[p] = v` (no metamethods). Pops the value.
    /// See `rawgetp` for the null-`p` deviation note.
    pub fn rawsetp(self: *State, idx: i32, p: ?*anyopaque) ApiError!void {
        const th = self.curThread();
        if (self.count() == 0) return error.InvalidState;
        const s = self.slot(idx) orelse return error.InvalidIndex;
        const tbl = switch (th.stack[s]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const key: *anyopaque = p orelse return error.InvalidIndex;
        const value = th.stack[th.top - 1];
        self.vm.apiRawSet(tbl, .{ .LightUserdata = key }, value) catch |e| return mapVmError(e);
        th.top -= 1; // PUC lua_rawsetp: plain pop of the value
    }

    pub fn next(self: *State, idx: i32) ApiError!bool {
        const th = self.curThread();
        if (self.count() == 0) return error.InvalidState;
        const s = self.slot(idx) orelse return error.InvalidIndex;
        const tbl = switch (th.stack[s]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const key = th.stack[th.top - 1];
        var out: [2]vm_mod.Value = .{ .Nil, .Nil };
        const produced = self.vm.apiNext(tbl, key, out[0..]) catch |e| return mapVmError(e);
        th.top -= 1; // PUC lua_next: plain pop of the key
        if (produced == 0) return false;
        try self.pushSlice(out[0..2]);
        return true;
    }

    pub fn loadbuffer(self: *State, chunk: []const u8, chunk_name: []const u8) Status {
        // M1: reserve the closure's slot BEFORE the (long, fallible)
        // compile — after compileChunk the push hits reserved capacity,
        // so the constructed closure never crosses a fallible operation
        // before its rooting store. Kind-preserving: OOM → LUA_ERRMEM,
        // stack overflow → LUA_ERRRUN.
        self.reservePushSlot() catch |e| switch (e) {
            error.OutOfMemory => return .memory_error,
            else => return .runtime_error,
        };
        const compiled = self.compileChunk(chunk, chunk_name) catch |e| return mapCompileError(e);
        self.push(compiled) catch return .memory_error;
        return .ok;
    }

    pub fn loadfile(self: *State, path: []const u8) Status {
        const source = source_mod.Source.loadFile(self.vm.alloc, stdio.activeIo(), path) catch return .memory_error;
        defer self.vm.alloc.free(source.name);
        defer self.vm.alloc.free(source.bytes);
        return self.loadbuffer(source.bytes, source.name);
    }

    pub fn pcall(self: *State, nargs: usize, nresults: i32) Status {
        const th = self.curThread();
        if (self.count() < nargs + 1) return .runtime_error;
        const func_slot = th.top - nargs - 1;
        const callee = th.stack[func_slot];
        // The argument slice would alias th.stack, which the nested
        // execution may grow (realloc) — dupe it across the apiCall
        // boundary (PUC precall reads the args in place on the one stack).
        const args = self.vm.alloc.dupe(vm_mod.Value, th.stack[func_slot + 1 .. th.top]) catch return .memory_error;
        defer self.vm.alloc.free(args);
        // P16.31 Cut 1 (PUC lapi.c:1095-1097 + ldo.c f_call): every caller of
        // this method is a CONVENTIONAL pcall — lua_pcallk's `k == NULL ||
        // !yieldable(L)` branch (c_api lua_pcallk, the lua_pcall macro,
        // luaL_dostring/luaL_dofile) and testC's "pcall" command (ltests.c
        // uses lua_pcall). PUC runs those through `f_call`, which calls
        // `luaD_callnoyield` — `ccall(..., nyci)`: +1 depth AND +1 nny. A
        // yield attempt inside therefore fails with "attempt to yield across
        // a C-call boundary" (lua_yieldk's `!yieldable(L)` check), and the
        // pcall catches it as an ordinary error.
        //
        // The old `.yieldable` here (P16.23 T6) let the yield SUCCEED at the
        // VM level: builtinCoroutineYield parked frames and set
        // bytecode_inplace_suspended, then this catch block swallowed
        // error.Yield as a Nil error object — leaving the thread with a stale
        // in-place suspension that corrupted the next runBytecodeInternal
        // (P16.31 S0 SIGSEGV: the __close frame resumed a stale frame whose
        // func_slot no longer held a Closure). The yieldable pcallk path
        // (k != NULL) does NOT come through here — it uses luaPcallKShared,
        // which owns its own `.yieldable` unit (PUC luaD_call, ccall inc=1).
        // P16.31 Cut 3: the TBC-chain snapshot at pcall ENTRY — PUC
        // luaD_pcall's old_top (the callee's func level, lapi.c f_call's
        // savestack). The catch below closes every chain entry above it
        // (luaD_closeprotected) before building the error object.
        const act = self.vm.activeBytecodeThread();
        const tbc_base = act.c_tbc_chain.items.len;
        const ret = self.vm.apiCall(.nonyieldable, callee, args) catch |e| {
            // PUC luaD_pcall (ldo.c:1090-1095): on error, restore the
            // stack to the base, run luaD_closeprotected(old_top, status)
            // — every TBC mark above the pcall entry closes WITH the
            // in-flight error, non-yieldable, last-error-wins (a closer
            // error REPLACES the error object) — then set the error
            // object (luaD_seterrorobj) and propagate status.
            self.vm.apiCloseConventionalPcallBoundary(act, tbc_base);
            // Raw top restore: the close above already ran (PUC restores
            // old_top only after closeprotected).
            th.top = func_slot;
            // PUC luaD_pcall propagates the RAW protected-run status:
            // LUA_ERRMEM stays LUA_ERRMEM (the old code flattened every
            // error to ERRRUN here, so a C-API OOM longjmp — e.g.
            // lua_getupvalue's result push — surfaced as status 2).
            // luaD_seterrorobj(LUA_ERRMEM) unconditionally installs the
            // FIXED MEMERRMSG literal (allocation-free) — matching PUC,
            // which replaces whatever the thrower carried.
            if (e == error.OutOfMemory) self.vm.setOutOfMemoryError();
            // Push the error object onto the window (PUC luaD_seterrorobj).
            // apiCloseConventionalPcallBoundary already replaced err_obj
            // with the final closer error when a closer errored.
            // P16.36 Cut 1b: the pcall'd call raised on the active
            // thread (same-thread protected call) — read its error state
            // directly.
            const errval: vm_mod.Value = if (act.err_has_obj) act.err_obj else .Nil;
            self.vm.cWindowPush(th, errval) catch return .memory_error;
            // PUC: status is LUA_ERRERR (5) if the message handler errored,
            // LUA_ERRMEM (4) for OOM, LUA_ERRRUN (2) otherwise.
            return switch (e) {
                error.OutOfMemory => .memory_error,
                else => if (act.err_is_errerr) .error_handler_error else .runtime_error,
            };
        };
        defer self.vm.alloc.free(ret);

        // PUC poscall moveresults to the callee's func slot: honors the
        // fixed-nresults promise with nil-fill (class 3), MULTRET copies
        // all, 0 drops all.
        self.vm.cWindowMoveResults(th, func_slot, ret, nresults) catch return .memory_error;
        return .ok;
    }

    pub fn getmetatable(self: *State, idx: i32) ApiError!bool {
        const v = self.valueAt(idx) orelse return error.InvalidIndex;
        // PUC lua_getmetatable (lapi.c:951-960): tables/userdata read
        // their own metatable; every other type reads the TYPE-LEVEL slot
        // G(L)->mt[ttype(o)] (P16.50-review-13 — the C-API get previously
        // returned nothing for type-level metatables while the Lua-level
        // getmetatable already did).
        const mt: ?*vm_mod.Table = self.vm.valueMetatable(v);
        if (mt) |m| {
            try self.push(.{ .Table = m });
            return true;
        }
        return false;
    }

    pub fn setmetatable(self: *State, idx: i32) ApiError!void {
        const th = self.curThread();
        if (self.count() < 1) return error.InvalidState;
        const s = self.slot(idx) orelse return error.InvalidIndex;
        // P16.50-review-13: PUC lua_setmetatable (lapi.c:964-1000) — the
        // metatable stays ROOTED on the stack until the transaction
        // commits, api_check requires table-or-nil, and the default arm
        // updates TYPE-LEVEL metatables. The old shape popped the value
        // before the fallible prepare (a prepare failure lost it), swallowed
        // the table-arm barrier OOM (`catch {}`), silently "succeeded" the
        // userdata arm on a reserve failure, registered finalizers after a
        // failed store, and used the (wrong) BACKWARD barrier for userdata.
        const mt_val = th.stack[th.top - 1];
        const mt: ?*vm_mod.Table = switch (mt_val) {
            .Table => |t| t,
            .Nil => null,
            else => return error.Type, // PUC api_check: table or nil
        };
        const target = th.stack[s];
        switch (target) {
            .Table, .Userdata => {
                const owner = vm_mod.GcObject.fromValue(target).?;
                const plan = self.vm.gcPrepareSetMetatable(owner, mt) catch {
                    return error.OutOfMemory;
                };
                self.vm.gcCommitSetMetatable(owner, mt, plan);
            },
            else => {
                if (!self.vm.setTypeMetatableValue(target, mt)) {
                    return error.Type; // unreachable: setTypeMetatableValue
                }
            },
        }
        // Pop only AFTER the infallible commit — a prepare failure leaves
        // the window byte-exact (PUC pops at the end of lua_setmetatable,
        // plainly: `L->top.p--`).
        th.top -= 1;
    }

    pub fn getregistry(self: *State) ApiError!void {
        // Kind-preserving: an OOM creating the registry stays OOM
        // (P16.50-review-5 B2 — the old `catch return error.Runtime`
        // surfaced ERRRUN for an allocation failure).
        const reg = self.vm.apiEnsureRegistry() catch |e| return mapVmError(e);
        try self.push(.{ .Table = reg });
    }

    pub fn getupvalue(self: *State, func_idx: i32, n: usize) ApiError!?[]const u8 {
        const fv = self.valueAt(func_idx) orelse return error.InvalidIndex;
        const dbg = try self.requireDebugModule();
        const f = self.vm.apiGetTable(dbg, .{ .String = try self.vm.internStr("getupvalue") }) catch |e| return mapVmError(e);
        var args = [_]vm_mod.Value{ fv, .{ .Int = @intCast(n) } };
        const ret = self.vm.apiCall(.nonyieldable, f, args[0..]) catch |e| return mapVmError(e);
        defer self.vm.alloc.free(ret);
        if (ret.len == 0 or ret[0] == .Nil) return null;
        if (ret[0] != .String) return error.Type;
        if (ret.len > 1) try self.push(ret[1]);
        return ret[0].String.bytes();
    }

    pub fn setupvalue(self: *State, func_idx: i32, n: usize) ApiError!?[]const u8 {
        const th = self.curThread();
        if (self.count() == 0) return error.InvalidState;
        const fv = self.valueAt(func_idx) orelse return error.InvalidIndex;
        const set_val = th.stack[th.top - 1];
        const dbg = try self.requireDebugModule();
        const f = self.vm.apiGetTable(dbg, .{ .String = try self.vm.internStr("setupvalue") }) catch |e| return mapVmError(e);
        var args = [_]vm_mod.Value{ fv, .{ .Int = @intCast(n) }, set_val };
        const ret = self.vm.apiCall(.nonyieldable, f, args[0..]) catch |e| return mapVmError(e);
        defer self.vm.alloc.free(ret);
        th.top -= 1; // PUC lua_setupvalue: plain pop of the value
        if (ret.len == 0 or ret[0] == .Nil) return null;
        if (ret[0] != .String) return error.Type;
        return ret[0].String.bytes();
    }

    // -----------------------------------------------------------------------
    // Push functions (ported from c_api.zig)
    // -----------------------------------------------------------------------

    /// Push an arbitrary-length string (bytes may contain embedded NULs).
    pub fn pushlstring(self: *State, s: []const u8) ApiError!void {
        try self.reservePushSlot();
        const ls = try self.vm.internStr(s);
        try self.push(.{ .String = ls });
    }

    /// Push a light userdata (raw pointer). Pushes nil if p is null.
    pub fn pushlightuserdata(self: *State, p: ?*anyopaque) ApiError!void {
        if (p) |ptr| {
            try self.push(.{ .LightUserdata = ptr });
        } else {
            try self.push(.Nil);
        }
    }

    /// Push a C closure wrapping `fn_` with `n` upvalues from the stack.
    /// Currently only n=0 is supported (upvalues need Phase 9).
    /// Canonical C-closure constructor (P16.50-review BLOCKER 3).
    /// PUC semantics: `lua_pushcclosure` (lapi.c:609+) allocates a FRESH
    /// CClosure per call and COPIES the given values into that closure's
    /// OWN upvalue slots — closures never share upvalue objects. The old
    /// registerfuncs shared one set of Cell objects across every closure:
    /// lua_setupvalue(f1, 1) mutated the same Cell observed by f2. PUC
    /// luaL_setfuncs (lauxlib.c:965-978) copies the shared VALUES onto
    /// the stack for each function and lets lua_pushcclosure take fresh
    /// copies — this constructor is that mechanism: values in, fresh
    /// per-closure Cells + Closure out, prepared-then-committed.
    /// Returns the closure WITHOUT touching the stack (callers own the
    /// push/pop ordering).
    /// P16.50-review-15 BLOCKER 1: the construction itself lives in
    /// `Vm.allocCclosure` — the ONE owner shared with every other
    /// C-closure builder (coroutine.wrap's auxwrap closure).
    fn makeCclosure(self: *State, fn_: ?*const fn (?*vm_mod.lua_State) callconv(.c) c_int, values: []const vm_mod.Value) ApiError!*vm_mod.Closure {
        return self.vm.allocCclosure(fn_, values);
    }

    pub fn pushcclosure(self: *State, fn_: ?*const fn (?*vm_mod.lua_State) callconv(.c) c_int, n: usize) ApiError!void {
        const th = self.curThread();
        // M1: reserve the closure's slot BEFORE construction (the reserve
        // may grow + move the stack, so the upvalue slice is captured
        // after it). After makeCclosure the push hits reserved capacity —
        // the constructed closure never crosses a fallible operation
        // before its rooting store.
        try self.reservePushSlot();
        if (n == 0) {
            const cl = try self.makeCclosure(fn_, &.{});
            try self.push(.{ .Closure = cl });
            return;
        }
        // Read the n upvalue values from the window top (WITHOUT popping:
        // the pop commits only after the closure exists — PUC
        // lua_pushcclosure copies into the fresh closure first, then does
        // the plain `L->top.p -= n`).
        if (self.count() < n) return error.InvalidState;
        const vals = th.stack[th.top - n .. th.top];
        const cl = try self.makeCclosure(fn_, vals);
        th.top -= n;
        try self.push(.{ .Closure = cl });
    }

    /// Convenience: push a C function as a closure with 0 upvalues.
    pub fn pushcfunction(self: *State, fn_: ?*const fn (?*vm_mod.lua_State) callconv(.c) c_int) ApiError!void {
        try self.pushcclosure(fn_, 0);
    }

    /// Push an external string whose content lives in external memory.
    pub fn pushexternalString(
        self: *State,
        s: [*]u8,
        str_len: usize,
        falloc: ?*const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) ?*anyopaque,
        ud: ?*anyopaque,
    ) ApiError!void {
        try self.reservePushSlot();
        const ls = try self.vm.createExternalLuaString(s, str_len, falloc, ud);
        try self.push(.{ .String = ls });
    }

    // -----------------------------------------------------------------------
    // Userdata functions (ported from c_api.zig)
    // -----------------------------------------------------------------------

    /// Allocate a full userdata with `sz` bytes of payload and `nuvalue`
    /// uservalues, push it, return payload pointer.
    pub fn newuserdatauv(self: *State, sz: usize, nuvalue: usize) ApiError!?*anyopaque {
        // Kind-preserving: allocUserdata OOM stays OOM (LUA_ERRMEM via
        // cThrowOn — P16.50-review-5 B2; the old `catch return
        // error.Runtime` misreported it as ERRRUN).
        try self.reservePushSlot();
        const ud = self.vm.allocUserdata(sz, nuvalue) catch |e| return mapDispatchError(e);
        try self.push(.{ .Userdata = ud });
        return if (ud.payload.len > 0) @ptrCast(ud.payload.ptr) else @ptrCast(ud);
    }

    /// Return payload pointer for full userdata at `idx`, or lightuserdata
    /// pointer, or null.
    pub fn touserdata(self: *State, idx: i32) ?*anyopaque {
        const v = self.valueAt(idx) orelse return null;
        return switch (v) {
            .Userdata => |ud| if (ud.payload.len > 0) @ptrCast(ud.payload.ptr) else @ptrCast(ud),
            .LightUserdata => |p| p,
            else => null,
        };
    }

    /// Return raw pointer for GC objects (userdata, table, thread, string).
    pub fn topointer(self: *State, idx: i32) ?*anyopaque {
        const v = self.valueAt(idx) orelse return null;
        return switch (v) {
            .Userdata => |ud| @ptrCast(ud),
            .LightUserdata => |p| p,
            .Table => |t| @ptrCast(t),
            .Thread => |th| @ptrCast(th),
            .String => |s| @ptrCast(s),
            else => null,
        };
    }

    /// Pop a value and store it as the n-th uservalue on the userdata at `idx`.
    pub fn setiuservalue(self: *State, idx: i32, n: usize) ApiError!bool {
        const th = self.curThread();
        if (self.count() < 1) return error.InvalidState;
        const s = self.slot(idx) orelse return error.InvalidIndex;
        const val = th.stack[th.top - 1];
        switch (th.stack[s]) {
            .Userdata => |ud| {
                const n_idx = n - 1;
                if (n_idx >= ud.uservalues.len) {
                    th.top -= 1; // PUC lua_setiuservalue: plain pop of the value
                    return false;
                }
                // PUC lua_setiuservalue (lapi.c) runs
                // luaC_barrierback(L, obj2gco(o), s2v(L->top - 1)) after the
                // uservalue store — a BACKWARD barrier (the value store may
                // hide a white value inside an already-black userdata; the
                // owner goes to grayagain for re-traversal). Without it a
                // black userdata + fresh white value leaves the value
                // unreachable for the marker and swept while still
                // referenced (UAF). Same prepare→store→commit
                // contract as builtinDebugSetuservalue: the grayagain
                // publication is reserved BEFORE
                // the observable store; prepare failure (OOM) leaves the
                // uservalue unwritten.
                const barrier = try self.vm.gcPrepareUserdataBarrierBack(ud, val);
                ud.uservalues[n_idx] = val;
                self.vm.gcCommitUserdataBarrierBack(ud, barrier);
                th.top -= 1; // PUC lua_setiuservalue: plain pop of the value
                return true;
            },
            else => {
                th.top -= 1; // PUC lua_setiuservalue: plain pop of the value
                return false;
            },
        }
    }

    /// Push the n-th uservalue from the userdata at `idx`.
    pub fn getiuservalue(self: *State, idx: i32, n: usize) ApiError!Type {
        const v = self.valueAt(idx) orelse {
            try self.push(.Nil);
            return .nil;
        };
        switch (v) {
            .Userdata => |ud| {
                const n_idx = n - 1;
                const val = if (n_idx < ud.uservalues.len) ud.uservalues[n_idx] else .Nil;
                try self.push(val);
                return valueType(val);
            },
            else => {
                try self.push(.Nil);
                return .nil;
            },
        }
    }

    // -----------------------------------------------------------------------
    // Unprotected call (Zig equivalent of lua_call)
    // -----------------------------------------------------------------------

    /// Unprotected call: on failure, returns the mapped error (OOM stays
    /// OOM — LUA_ERRMEM via cThrowOn; P16.50-review-5 B2). The actual
    /// longjmp boundary logic stays in c_api.zig for C callers.
    pub fn call(self: *State, nargs: usize, nresults: i32) ApiError!void {
        const th = self.curThread();
        if (self.count() < nargs + 1) return error.InvalidState;
        const func_slot = th.top - nargs - 1;
        const callee = th.stack[func_slot];
        // Dupe the args across the apiCall boundary (the slice would alias
        // th.stack, which the nested execution may grow).
        const args = self.vm.alloc.dupe(vm_mod.Value, th.stack[func_slot + 1 .. th.top]) catch return error.OutOfMemory;
        defer self.vm.alloc.free(args);
        const ret = self.vm.apiCall(.nonyieldable, callee, args) catch |e| return mapVmError(e);
        defer self.vm.alloc.free(ret);
        // PUC poscall moveresults: fixed nresults nil-fills (class 3),
        // MULTRET copies all, 0 drops all.
        self.vm.cWindowMoveResults(th, func_slot, ret, nresults) catch |e| return mapVmError(e);
    }

    // -----------------------------------------------------------------------
    // lauxlib functions (ported from c_api.zig)
    // -----------------------------------------------------------------------

    /// PUC `luaL_Reg`: a {name, func} pair terminated by a sentinel.
    pub const Reg = extern struct {
        name: ?[*:0]const u8,
        func: ?*const fn (?*vm_mod.lua_State) callconv(.c) c_int,
    };

    /// Return the bytes of the string at `arg`, or "" on type mismatch.
    pub fn checklstring(self: *State, arg: i32) []const u8 {
        const v = self.valueAt(arg) orelse return "";
        return switch (v) {
            .String => |s| s.bytes(),
            else => "",
        };
    }

    /// Store the top value in table `t` under a fresh integer key and return
    /// that key. Returns -1 (LUA_REFNIL) for nil, -2 (LUA_NOREF) on error.
    pub fn ref(self: *State, t: i32) i32 {
        const th = self.curThread();
        const top = self.count();
        if (top == 0) return -2;
        const val = th.stack[th.top - 1];
        if (val == .Nil) {
            th.top -= 1; // plain: nil is never referenced (PUC lua_pop of a nil)
            return -1;
        }

        const registry_idx: c_int = -1001000;
        const tbl = if (t == registry_idx) blk: {
            const reg = self.vm.apiEnsureRegistry() catch return -2;
            break :blk reg;
        } else blk: {
            const s = self.slot(t) orelse return -2;
            break :blk switch (th.stack[s]) {
                .Table => |tt| tt,
                else => return -2,
            };
        };
        const ref_key: i64 = self.vm.c_ref_counter;
        self.vm.c_ref_counter += 1;
        // PUC luaL_ref: lua_rawseti pops the value (plain) after the store —
        // the value stays rooted on the window across the fallible store.
        self.vm.apiRawSet(tbl, .{ .Int = ref_key }, val) catch return -2;
        th.top -= 1;
        return @intCast(ref_key);
    }

    /// Release reference `ref` from table at `t` (PUC free-list recycling).
    pub fn unref(self: *State, t: i32, ref_id: i32) void {
        const registry_idx: c_int = -1001000;
        const tbl = if (t == registry_idx) blk: {
            break :blk self.vm.apiEnsureRegistry() catch return;
        } else blk: {
            const v = self.valueAt(t) orelse return;
            break :blk switch (v) {
                .Table => |tt| tt,
                else => return,
            };
        };
        const freelist = self.vm.apiRawGet(tbl, .{ .Int = 0 });
        self.vm.apiRawSet(tbl, .{ .Int = @intCast(ref_id) }, freelist) catch {};
        self.vm.apiRawSet(tbl, .{ .Int = 0 }, .{ .Int = @intCast(ref_id) }) catch {};
    }

    /// Create a table, store it in the registry under key `tname`, push it.
    /// PUC luaL_newmetatable (lauxlib.c:317-327). P16.50-review-6 B2: this
    /// is a THIN wrapper over the one shared semantic path
    /// (`Vm.newMetatableShared`) used by both the C API here and the testC
    /// `newmetatable` command — same registry, same PUC order (lookup →
    /// existing-value-on-top + false | create normal GC table → root on
    /// the resumed thread's window → `__name = tname` → publish to
    /// registry → true). Per-edge OOM ownership is documented and proven
    /// at the primitive.
    pub fn newmetatable(self: *State, tname: []const u8) ApiError!bool {
        return self.vm.apiNewMetatable(tname, self.curThread()) catch |e| mapVmError(e);
    }

    /// Push the metatable registered under `tname`, or nil.
    /// PUC luaL_getmetatable: lua_getfield on the registry — OOM throws
    /// (the old swallow pushed nothing at all, corrupting the stack shape;
    /// P16.50-review-5 B2).
    pub fn getRegisteredMetatable(self: *State, tname: []const u8) ApiError!void {
        const reg = self.vm.apiEnsureRegistry() catch |e| return mapVmError(e);
        const key = try self.vm.internStr(tname);
        const val = self.vm.apiRawGet(reg, .{ .String = key });
        try self.push(val);
    }

    /// Get metatable from registry by name, set on value at top.
    pub fn setRegisteredMetatable(self: *State, tname: []const u8) ApiError!void {
        try self.getRegisteredMetatable(tname);
        _ = try self.setmetatable(-2);
    }

    /// Check if value at `ud` is a userdata with metatable `tname`.
    pub fn testudata(self: *State, ud: i32, tname: []const u8) ?*anyopaque {
        const v = self.valueAt(ud) orelse return null;
        if (v != .Userdata) return null;
        const reg = self.vm.apiEnsureRegistry() catch return null;
        const key = self.vm.internStr(tname) catch return null;
        const expected = self.vm.apiRawGet(reg, .{ .String = key });
        if (expected != .Table) return null;
        const ud_val = v.Userdata;
        if (ud_val.metatable != expected.Table) return null;
        return if (ud_val.payload.len > 0) @ptrCast(ud_val.payload.ptr) else @ptrCast(ud_val);
    }

    /// Like testudata. Returns null on mismatch.
    pub fn checkudata(self: *State, ud: i32, tname: []const u8) ?*anyopaque {
        return self.testudata(ud, tname);
    }

    /// Return integer at `arg` or error.
    pub fn checkinteger(self: *State, arg: i32) ApiError!i64 {
        const v = self.valueAt(arg) orelse return error.InvalidIndex;
        return switch (v) {
            .Int => |i| i,
            .Num => |n| if (std.math.floor(n) == n and n >= -9.2233720368548e18 and n <= 9.2233720368548e18)
                @intFromFloat(n)
            else
                error.Type,
            else => error.Type,
        };
    }

    /// Return integer at `arg` or `def` if nil/absent.
    pub fn optinteger(self: *State, arg: i32, def: i64) ApiError!i64 {
        const v = self.valueAt(arg) orelse return def;
        return switch (v) {
            .Int => |i| i,
            else => def,
        };
    }

    /// Verify version/size compatibility. No-op in current implementation.
    pub fn checkversion(self: *State) void {
        _ = self;
    }

    /// Register every {name, func} in `reg` into the table at top of stack.
    pub fn registerfuncs(self: *State, reg: [*]const Reg, nup: usize) ApiError!void {
        const th = self.curThread();
        const top = self.count();
        if (top < nup + 1) return error.InvalidState;
        const tbl_slot = th.top - nup - 1;
        const tbl = switch (th.stack[tbl_slot]) {
            .Table => |t| t,
            else => return error.Type,
        };
        // P16.50-review BLOCKER 3: PUC luaL_setfuncs (lauxlib.c:965-978)
        // copies the nup SHARED VALUES (not upvalue objects) and, for
        // each registered function, calls lua_pushcclosure — which
        // allocates a FRESH CClosure with its OWN upvalue slots and
        // copies the values in (lapi.c:609+, lfunc.c luaF_newCclosure).
        // The old implementation created one set of shared Cell OBJECTS
        // referenced by every closure: lua_setupvalue(f1, 1) mutated the
        // same Cell observed by f2 — not PUC behavior. The shared-cell
        // phase is REMOVED; each function gets fresh per-closure Cells
        // holding copies of the values (makeCclosure — the canonical
        // constructor shared with pushcclosure).
        //
        // Errors propagate with the original value (no catch {} swallows,
        // no silent partial library): functions registered before a
        // failure stay published — valid, fully-registered objects; the
        // caller sees the error (PUC luaL_setfuncs aborts via luaD_throw
        // on the first failure; our error return is the Zig-native form).
        //
        // The shared-values slice aliases th.stack; nothing in the loop
        // grows the stack (makeCclosure allocates off-stack, apiRawSet
        // writes the table), so the alias stays valid — the same exposure
        // as PUC reading the values per closure.
        const upv_start = tbl_slot + 1;
        const shared_values: []const vm_mod.Value =
            th.stack[upv_start .. upv_start + nup];
        var i: usize = 0;
        while (reg[i].name != null) : (i += 1) {
            const name = std.mem.span(reg[i].name.?);
            const key_str = try self.vm.internStr(name);
            if (reg[i].func == null) {
                self.vm.apiRawSet(tbl, .{ .String = key_str }, .{ .Bool = false }) catch |e| return mapVmError(e);
                continue;
            }
            const cl = try self.makeCclosure(reg[i].func, shared_values);
            self.vm.apiRawSet(tbl, .{ .String = key_str }, .{ .Closure = cl }) catch |e| {
                // Publish failed: roll the fully-committed closure back
                // (its Cells are reachable only through the array we
                // still own — unregister the closure, then every Cell).
                self.vm.gcUnregisterObjectRollback(.{ .closure = cl });
                self.vm.gcNoteFree(@sizeOf(vm_mod.Closure) + nup * @sizeOf(*vm_mod.Cell));
                self.vm.testc_obj_functions -= 1;
                for (cl.upvalues) |c| {
                    self.vm.gcUnregisterObjectRollback(.{ .cell = c });
                    self.vm.gcNoteFree(@sizeOf(vm_mod.Cell));
                    self.vm.alloc.destroy(c);
                }
                self.vm.alloc.free(cl.upvalues);
                self.vm.alloc.destroy(cl);
                return mapVmError(e);
            };
        }
        // PUC luaL_setfuncs ends with lua_pop(L, nup) — close-then-lower.
        try self.popN(nup);
    }

    /// Convenience: create a fresh table and register `reg` into it.
    pub fn newlib(self: *State, reg: [*]const Reg) ApiError!void {
        try self.newtable();
        try self.registerfuncs(reg, 0);
    }

    fn compileChunk(self: *State, bytes: []const u8, chunk_name: []const u8) !vm_mod.Value {
        return self.vm.compileChunkValue(bytes, chunk_name);
    }

    fn threadAt(self: *const State, idx: i32) ?*vm_mod.Thread {
        const v = self.valueAt(idx) orelse return null;
        return switch (v) {
            .Thread => |th| th,
            else => null,
        };
    }

    fn callGlobal(self: *State, name: []const u8, args: []const vm_mod.Value) ![]vm_mod.Value {
        const callee = self.vm.apiGetGlobal(name);
        return self.vm.apiCall(.nonyieldable, callee, args);
    }

    fn requireDebugModule(self: *State) ApiError!vm_mod.Value {
        var args = [_]vm_mod.Value{.{ .String = try self.vm.internStr("debug") }};
        // Kind-preserving: require() OOM stays OOM (P16.50-review-5 B2).
        const ret = self.callGlobal("require", args[0..]) catch |e| return mapVmError(e);
        defer self.vm.alloc.free(ret);
        if (ret.len == 0 or ret[0] != .Table) return error.Runtime;
        return ret[0];
    }
};

pub fn isCallableValue(vm: *vm_mod.Vm, v: vm_mod.Value) bool {
    return switch (v) {
        .Builtin, .Closure => true,
        .Table => |t| t.metatable != null and vm.getFieldOpt(t.metatable.?, "__call") != null,
        else => false,
    };
}

pub fn valueType(v: vm_mod.Value) Type {
    if (v == .Table and isFileUserdata(v.Table)) return .userdata;
    return switch (v) {
        .Nil => .nil,
        .Bool => .boolean,
        .Int, .Num => .number,
        .String => .string,
        .Table => .table,
        .Builtin, .Closure => .function,
        .Thread => .thread,
        .LightUserdata => .lightuserdata,
        .Userdata => .userdata,
    };
}

fn isFileUserdata(tbl: *vm_mod.Table) bool {
    const mt = tbl.metatable orelse return false;
    // Walk the unified hash part directly. __name is a short interned string;
    // its LuaString.hash is cached, so the lookup is independent of the per-VM
    // seed — we just need to find any node with a String key whose content is
    // "FILE*". This avoids threading a *Vm through every valueType() call.
    for (mt.hash) |*node| {
        // `key_tt` collapses three checks into one: empty nodes, dead keys, and
        // non-string keys all fail the `!= .string` test. Only live String keys
        // reach the byte comparison below.
        if (!ltable.Node.isStringTag(node.key_tt)) continue;
        if (node.value == .Nil) continue;
        if (std.mem.eql(u8, node.key_val.string.bytes(), "__name")) {
            const nm = node.value;
            if (nm != .String) return false;
            return std.mem.eql(u8, nm.String.bytes(), "FILE*");
        }
    }
    return false;
}

/// P16.50-review-5 3.1: EXACT typed Vm→API error mapping. The parameter is
/// the precise public Vm error union (`Vm.Error` = {OutOfMemory,
/// RuntimeError, Yield}) — never `anyerror`, never an `else` arm: an error
/// kind added to `Vm.Error` in the future becomes a COMPILE error at this
/// switch instead of silently surfacing as ERRRUN (the forbidden
/// `else => error.Runtime` kind-erasure the review flagged). PUC statuses
/// pass through as data: OOM → LUA_ERRMEM (error.OutOfMemory), runtime
/// error → LUA_ERRRUN (error.Runtime).
pub fn mapVmError(err: vm_mod.Vm.Error) ApiError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.RuntimeError => error.Runtime,
        // Yield is control flow, not an error. Every api.zig call site
        // runs inside a non-yieldable context (apiCall(.nonyieldable) or
        // host-driven metamethod dispatch): PUC converts a yield attempt
        // there into "attempt to yield across a C-call boundary"
        // (RuntimeError) at the yield site itself, so error.Yield never
        // legitimately crosses this boundary. Reaching this arm means the
        // non-yieldable invariant broke — fail loudly instead of silently
        // re-labeling coroutine control flow as ERRRUN.
        error.Yield => @panic("api: yield crossed a non-yieldable API boundary"),
    };
}

/// Same exact-arm contract for the api.zig sites whose VM function returns
/// the wider `Vm.DispatchError` union (valueToInternedStr, allocUserdata).
/// `ThreadSwitch` is private dispatch control flow raised only inside the
/// bytecode coroutine trampoline and consumed by
/// `driveBytecodeCoroutineTrampoline`; it cannot cross a host API boundary.
fn mapDispatchError(err: vm_mod.Vm.DispatchError) ApiError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.RuntimeError => error.Runtime,
        error.Yield => @panic("api: yield crossed a non-yieldable API boundary"),
        error.ThreadSwitch => @panic("api: thread-switch crossed a host API boundary"),
    };
}

/// The exact error union of `Vm.compileChunkValue` (loading a chunk):
/// `Vm.Error` plus `Syntax`. Yield/ThreadSwitch are declared by the
/// underlying constructors (createBytecodeChunkClosure/applyLoadEnv) but
/// unreachable while merely LOADING — loading never runs the chunk and
/// never enters the coroutine trampoline.
pub const CompileError = vm_mod.Vm.Error || error{ Syntax, ThreadSwitch };

/// PUC load-status mapping (LUA_ERRSYNTAX/LUA_ERRMEM/LUA_ERRRUN). Exact
/// arms over `CompileError` — no `anyerror`, no `else` (P16.50-review-5
/// 3.1): a new error kind becomes a compile error here, not a silent
/// ERRRUN.
pub fn mapCompileError(err_val: CompileError) Status {
    return switch (err_val) {
        error.Syntax => .syntax_error,
        error.OutOfMemory => .memory_error,
        error.RuntimeError => .runtime_error,
        error.Yield => @panic("api: yield crossed a non-yieldable load boundary"),
        error.ThreadSwitch => @panic("api: thread-switch crossed a host load boundary"),
    };
}

/// PUC-style pseudo-index resolution. Positive `idx` is absolute (1-based);
/// negative `idx` is relative to top. Returns null for invalid indices
/// (0 or out of range). Shared by api.State and c_api.zig.
pub fn normalizeIndex(idx: i32, top: usize) ?usize {
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
pub fn typeCode(ty: Type) c_int {
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

/// Maps an api.Status to the LUA_*ERR* integer code used by lua_pcall.
pub fn statusCode(st: Status) c_int {
    return switch (st) {
        .ok => 0,
        .yielded => 1,
        .runtime_error => 2,
        .syntax_error => 3,
        .memory_error => 4,
        .error_handler_error => 5,
    };
}

test "api state lifecycle" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();
    try std.testing.expectEqual(@as(usize, 0), st.gettop());
}

test "api index normalization contract" {
    try std.testing.expectEqual(@as(usize, 0), normalizeIndex(1, 3).?);
    try std.testing.expectEqual(@as(usize, 2), normalizeIndex(-1, 3).?);
    try std.testing.expect(normalizeIndex(0, 3) == null);
    try std.testing.expect(normalizeIndex(4, 3) == null);
}

test "api stack push/pop and settop" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    try st.pushinteger(10);
    try st.pushboolean(true);
    try std.testing.expectEqual(@as(usize, 2), st.gettop());
    try std.testing.expectEqual(@as(i64, 10), st.tointeger(1).?);
    try std.testing.expectEqual(true, st.toboolean(-1));

    try st.settop(4);
    try std.testing.expectEqual(@as(usize, 4), st.gettop());
    try std.testing.expectEqual(@as(Type, .nil), st.typeOf(-1).?);

    try st.pop(2);
    try std.testing.expectEqual(@as(usize, 2), st.gettop());
}

test "api stack reorder primitives" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    try st.pushinteger(10);
    try st.pushinteger(20);
    try st.pushinteger(30);
    try std.testing.expectEqual(@as(i32, 3), try st.absindex(-1));

    try st.copy(1, 3);
    try std.testing.expectEqual(@as(i64, 10), st.tointeger(3).?);

    try st.pushinteger(40);
    try st.insert(2);
    try std.testing.expectEqual(@as(i64, 10), st.tointeger(1).?);
    try std.testing.expectEqual(@as(i64, 40), st.tointeger(2).?);
    try std.testing.expectEqual(@as(i64, 20), st.tointeger(3).?);
    try std.testing.expectEqual(@as(i64, 10), st.tointeger(4).?);

    try st.remove(3);
    try std.testing.expectEqual(@as(usize, 3), st.gettop());
    try std.testing.expectEqual(@as(i64, 10), st.tointeger(1).?);
    try std.testing.expectEqual(@as(i64, 40), st.tointeger(2).?);
    try std.testing.expectEqual(@as(i64, 10), st.tointeger(3).?);

    try st.pushinteger(99);
    try st.replace(2);
    try std.testing.expectEqual(@as(usize, 3), st.gettop());
    try std.testing.expectEqual(@as(i64, 99), st.tointeger(2).?);

    try st.rotate(1, 1);
    try std.testing.expectEqual(@as(i64, 10), st.tointeger(1).?);
    try std.testing.expectEqual(@as(i64, 10), st.tointeger(2).?);
    try std.testing.expectEqual(@as(i64, 99), st.tointeger(3).?);
}

test "api stack concat primitive" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    try st.concat(0);
    try std.testing.expectEqualStrings("", st.tostring(-1).?);
    try st.pop(1);

    try st.pushstring("a");
    try st.pushinteger(12);
    try st.pushstring("z");
    try st.concat(3);
    try std.testing.expectEqual(@as(usize, 1), st.gettop());
    try std.testing.expectEqualStrings("a12z", st.tostring(1).?);
}

test "api loadbuffer and pcall" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    const status_load = st.loadbuffer("return 7, 8", "=api-test");
    try std.testing.expectEqual(Status.ok, status_load);
    const status_call = st.pcall(0, -1);
    try std.testing.expectEqual(Status.ok, status_call);
    try std.testing.expectEqual(@as(usize, 2), st.gettop());
    try std.testing.expectEqual(@as(i64, 7), st.tointeger(1).?);
    try std.testing.expectEqual(@as(i64, 8), st.tointeger(2).?);
}

test "api globals roundtrip" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    try st.pushinteger(1234);
    try st.setglobal("api_roundtrip_value");
    try std.testing.expectEqual(@as(usize, 0), st.gettop());
    const ty = try st.getglobal("api_roundtrip_value");
    try std.testing.expectEqual(Type.number, ty);
    try std.testing.expectEqual(@as(i64, 1234), st.tointeger(-1).?);
}

test "api table get/set and raw access" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    const setup =
        \\local mt = {
        \\  __index = function(_, k)
        \\    if k == "x" then return 99 end
        \\    return nil
        \\  end,
        \\  __newindex = function(tbl, k, v)
        \\    rawset(tbl, k, v * 2)
        \\  end
        \\}
        \\_G.__api_t = setmetatable({}, mt)
    ;
    try std.testing.expectEqual(Status.ok, st.loadbuffer(setup, "=api-table-setup"));
    try std.testing.expectEqual(Status.ok, st.pcall(0, 0));
    try std.testing.expectEqual(@as(usize, 0), st.gettop());

    _ = try st.getglobal("__api_t");
    try std.testing.expectEqual(Type.table, st.typeOf(-1).?);

    try st.pushstring("x");
    try std.testing.expectEqual(Type.number, try st.gettable(-2));
    try std.testing.expectEqual(@as(i64, 99), st.tointeger(-1).?);
    try st.pop(1);

    try st.pushstring("k");
    try st.pushinteger(5);
    try st.settable(-3);

    try st.pushstring("k");
    try std.testing.expectEqual(Type.number, try st.gettable(-2));
    try std.testing.expectEqual(@as(i64, 10), st.tointeger(-1).?);
    try st.pop(1);

    try st.pushstring("k");
    try std.testing.expectEqual(Type.number, try st.rawget(-2));
    try std.testing.expectEqual(@as(i64, 10), st.tointeger(-1).?);
}

test "api table field and integer primitives" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    try st.newtable();
    try std.testing.expectEqual(Type.table, st.typeOf(-1).?);

    try st.pushinteger(21);
    try st.setfield(-2, "answer");
    try std.testing.expectEqual(Type.number, try st.getfield(-1, "answer"));
    try std.testing.expectEqual(@as(i64, 21), st.tointeger(-1).?);
    try st.pop(1);

    try st.pushinteger(34);
    try st.seti(-2, 2);
    try std.testing.expectEqual(Type.number, try st.geti(-1, 2));
    try std.testing.expectEqual(@as(i64, 34), st.tointeger(-1).?);
    try st.pop(1);

    try st.pushinteger(55);
    try st.rawseti(-2, 3);
    try std.testing.expectEqual(Type.number, try st.rawgeti(-1, 3));
    try std.testing.expectEqual(@as(i64, 55), st.tointeger(-1).?);
}

test "api integer table primitives respect metamethods" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    const setup =
        \\local mt = {
        \\  __index = function(_, k)
        \\    if k == 7 then return 70 end
        \\    return nil
        \\  end,
        \\  __newindex = function(tbl, k, v)
        \\    rawset(tbl, k, v + 1)
        \\  end
        \\}
        \\return setmetatable({}, mt)
    ;
    try std.testing.expectEqual(Status.ok, st.loadbuffer(setup, "=api-i-meta"));
    try std.testing.expectEqual(Status.ok, st.pcall(0, 1));

    try std.testing.expectEqual(Type.number, try st.geti(-1, 7));
    try std.testing.expectEqual(@as(i64, 70), st.tointeger(-1).?);
    try st.pop(1);

    try st.pushinteger(10);
    try st.seti(-2, 8);
    try std.testing.expectEqual(Type.number, try st.rawgeti(-1, 8));
    try std.testing.expectEqual(@as(i64, 11), st.tointeger(-1).?);
    try st.pop(1);

    try st.pushinteger(20);
    try st.rawseti(-2, 9);
    try std.testing.expectEqual(Type.number, try st.geti(-1, 9));
    try std.testing.expectEqual(@as(i64, 20), st.tointeger(-1).?);
}

test "api next iterates table with C API stack shape" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    try std.testing.expectEqual(Status.ok, st.loadbuffer("return { a = 1, b = 2 }", "=api-next"));
    try std.testing.expectEqual(Status.ok, st.pcall(0, 1));
    try std.testing.expectEqual(Type.table, st.typeOf(1).?);

    try st.pushnil();
    var seen: usize = 0;
    while (try st.next(1)) {
        seen += 1;
        try std.testing.expect(st.typeOf(-2).? == .string);
        try std.testing.expect(st.typeOf(-1).? == .number);
        try st.pop(1);
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
    try std.testing.expectEqual(@as(usize, 1), st.gettop());
}

test "api thread resume yield and xmove primitives" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    try st.newthread();
    try std.testing.expectEqual(Type.thread, st.typeOf(1).?);
    try std.testing.expectEqual(true, try st.isyieldable(1));

    const chunk =
        \\return function(x)
        \\  local y = coroutine.yield(x + 1)
        \\  return y + 2
        \\end
    ;
    try std.testing.expectEqual(Status.ok, st.loadbuffer(chunk, "=api-thread"));
    try std.testing.expectEqual(Status.ok, st.pcall(0, 1));
    try st.pushinteger(41);
    try st.xmove(null, 1, 2);
    try std.testing.expectEqual(@as(usize, 1), st.gettop());

    try std.testing.expectEqual(Status.yielded, st.@"resume"(1, 1));
    try st.xmove(1, null, 1);
    try std.testing.expectEqual(@as(i64, 42), st.tointeger(-1).?);
    try st.pop(1);

    try st.pushinteger(50);
    try st.xmove(null, 1, 1);
    try std.testing.expectEqual(Status.ok, st.@"resume"(1, 1));
    try st.xmove(1, null, 1);
    try std.testing.expectEqual(@as(i64, 52), st.tointeger(-1).?);
}

test "api yield outside coroutine reports invalid runtime context" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    try st.pushinteger(1);
    try std.testing.expectError(error.Runtime, st.yield(1));
}

test "api metatable registry upvalues and userdata type tag" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    try std.testing.expectEqual(Status.ok, st.loadbuffer("return {}, { __name = 'M' }", "=api-meta"));
    try std.testing.expectEqual(Status.ok, st.pcall(0, -1));
    try st.setmetatable(-2);
    try std.testing.expectEqual(true, try st.getmetatable(-1));
    try std.testing.expectEqual(Type.table, st.typeOf(-1).?);
    try st.pop(1);
    try st.pop(1);

    try st.getregistry();
    try std.testing.expectEqual(Type.table, st.typeOf(-1).?);
    try st.pop(1);

    try std.testing.expectEqual(Status.ok, st.loadbuffer("local x = 41; return function() return x end", "=api-up"));
    try std.testing.expectEqual(Status.ok, st.pcall(0, -1));
    const nm = try st.getupvalue(-1, 1);
    try std.testing.expect(nm != null);
    try std.testing.expectEqualStrings("x", nm.?);
    try std.testing.expectEqual(@as(i64, 41), st.tointeger(-1).?);
    try st.pop(1);

    try st.pushinteger(99);
    const nm2 = try st.setupvalue(-2, 1);
    try std.testing.expect(nm2 != null);
    try std.testing.expectEqualStrings("x", nm2.?);
    const call_st = st.pcall(0, 1);
    try std.testing.expectEqual(Status.ok, call_st);
    try std.testing.expectEqual(@as(i64, 99), st.tointeger(-1).?);
    try st.pop(1);

    try std.testing.expectEqual(Status.ok, st.loadbuffer("return io.stdout", "=api-ud"));
    try std.testing.expectEqual(Status.ok, st.pcall(0, -1));
    try std.testing.expectEqual(Type.userdata, st.typeOf(-1).?);
    try std.testing.expect(st.isuserdata(-1));
}

test "api integration stack table call and next mirror upstream api basics" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    try st.pushinteger(2);
    try st.pushinteger(3);
    try st.pushinteger(4);
    try st.rotate(1, 1);
    try std.testing.expectEqual(@as(i64, 4), st.tointeger(1).?);
    try std.testing.expectEqual(@as(i64, 2), st.tointeger(2).?);
    try std.testing.expectEqual(@as(i64, 3), st.tointeger(3).?);
    try st.settop(0);

    try st.newtable();
    try st.pushstring("answer");
    try st.pushinteger(42);
    try st.settable(-3);
    try st.pushnil();
    try std.testing.expect(try st.next(1));
    try std.testing.expectEqualStrings("answer", st.tostring(-2).?);
    try std.testing.expectEqual(@as(i64, 42), st.tointeger(-1).?);
    try st.pop(1);
    try std.testing.expect(!(try st.next(1)));
    try std.testing.expectEqual(@as(usize, 1), st.gettop());
}

test "api integration protected call preserves Lua return values" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    const src =
        \\local function f(a, b)
        \\  return a + b, tostring(a) .. ":" .. tostring(b)
        \\end
        \\return f
    ;
    try std.testing.expectEqual(Status.ok, st.loadbuffer(src, "=api-integration-call"));
    try std.testing.expectEqual(Status.ok, st.pcall(0, 1));
    try st.pushinteger(17);
    try st.pushinteger(25);
    try std.testing.expectEqual(Status.ok, st.pcall(2, -1));
    try std.testing.expectEqual(@as(usize, 2), st.gettop());
    try std.testing.expectEqual(@as(i64, 42), st.tointeger(1).?);
    try std.testing.expectEqualStrings("17:25", st.tostring(2).?);
}

test "api integration coroutine resume yield roundtrip" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    try st.newthread();
    try std.testing.expectEqual(Type.thread, st.typeOf(1).?);
    try std.testing.expectEqual(true, try st.isyieldable(1));

    const src =
        \\return function(seed)
        \\  local resumed = coroutine.yield(seed + 10)
        \\  return resumed * 2
        \\end
    ;
    try std.testing.expectEqual(Status.ok, st.loadbuffer(src, "=api-integration-coroutine"));
    try std.testing.expectEqual(Status.ok, st.pcall(0, 1));
    try st.pushinteger(32);
    try st.xmove(null, 1, 2);

    try std.testing.expectEqual(Status.yielded, st.@"resume"(1, 1));
    try st.xmove(1, null, 1);
    try std.testing.expectEqual(@as(i64, 42), st.tointeger(-1).?);
    try st.pop(1);

    try st.pushinteger(21);
    try st.xmove(null, 1, 1);
    try std.testing.expectEqual(Status.ok, st.@"resume"(1, 1));
    try st.xmove(1, null, 1);
    try std.testing.expectEqual(@as(i64, 42), st.tointeger(-1).?);
}
