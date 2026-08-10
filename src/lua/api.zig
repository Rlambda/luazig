const std = @import("std");
const stdio = @import("util").stdio;

const source_mod = @import("source.zig");
const vm_mod = @import("vm.zig");

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
    // value; it wraps a heap-allocated *Vm so that api.State and c_api.zig share
    // the same stack (vm.c_stack), eliminating the dual-stack problem.
    vm: *vm_mod.Vm,
    thread_stacks: std.AutoHashMapUnmanaged(*vm_mod.Thread, std.ArrayListUnmanaged(vm_mod.Value)) = .empty,

    /// Create a new VM (heap-allocated) and wrap it.
    pub fn init(opts: Options) State {
        const alloc = opts.allocator;
        const ptr = alloc.create(vm_mod.Vm) catch @panic("api.State.init: out of memory");
        ptr.* = vm_mod.Vm.init(alloc, false);
        return .{ .vm = ptr };
    }

    /// Clean up the VM and free its heap allocation.
    pub fn deinit(self: *State) void {
        var it = self.thread_stacks.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.vm.alloc);
        self.thread_stacks.deinit(self.vm.alloc);
        // Save the allocator before deinit'ing the Vm — after deinit the Vm's
        // fields are invalid, but the allocator (a value type) is safe to copy.
        const alloc = self.vm.alloc;
        self.vm.deinit();
        alloc.destroy(self.vm);
    }

    /// Wrap an existing *Vm without taking ownership.
    /// Used by c_api.zig to create a State from a lua_State*.
    pub fn fromVm(vm: *vm_mod.Vm) State {
        return .{ .vm = vm };
    }

    pub fn gettop(self: *const State) usize {
        return self.vm.c_stack.items.len;
    }

    pub fn settop(self: *State, idx: i32) ApiError!void {
        const top = self.vm.c_stack.items.len;
        var new_top: usize = 0;
        if (idx >= 0) {
            new_top = @intCast(idx);
        } else {
            const top_i: i64 = @intCast(top);
            const idx_i: i64 = @intCast(idx);
            const nt = top_i + idx_i + 1;
            if (nt < 0) return error.InvalidIndex;
            new_top = @intCast(nt);
        }
        if (new_top < top) {
            self.vm.c_stack.items.len = new_top;
            return;
        }
        const add = new_top - top;
        try self.vm.c_stack.appendNTimes(self.vm.alloc, .Nil, add);
    }

    pub fn pop(self: *State, n: usize) ApiError!void {
        if (n > self.vm.c_stack.items.len) return error.InvalidIndex;
        self.vm.c_stack.items.len -= n;
    }

    pub fn absindex(self: *State, idx: i32) ApiError!i32 {
        if (idx == 0) return error.InvalidIndex;
        if (idx > 0) {
            if (normalizeIndex(idx, self.vm.c_stack.items.len) == null) return error.InvalidIndex;
            return idx;
        }
        if (normalizeIndex(idx, self.vm.c_stack.items.len) == null) return error.InvalidIndex;
        return @intCast(@as(i64, @intCast(self.vm.c_stack.items.len)) + @as(i64, idx) + 1);
    }

    /// PUC `lua_checkstack` (lapi.c:lua_checkstack): ensure at least `n`
    /// extra stack slots are available. Returns void on success; the C shim
    /// translates the error into a 0 return value.
    pub fn checkstack(self: *State, n: usize) ApiError!void {
        try self.vm.c_stack.ensureUnusedCapacity(self.vm.alloc, n);
    }

    pub fn insert(self: *State, idx: i32) ApiError!void {
        try self.rotate(idx, 1);
    }

    pub fn remove(self: *State, idx: i32) ApiError!void {
        try self.rotate(idx, -1);
        try self.pop(1);
    }

    pub fn replace(self: *State, idx: i32) ApiError!void {
        if (self.vm.c_stack.items.len == 0) return error.InvalidState;
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const top = self.vm.c_stack.items.len - 1;
        self.vm.c_stack.items[abs] = self.vm.c_stack.items[top];
        self.vm.c_stack.items.len = top;
    }

    pub fn copy(self: *State, from_idx: i32, to_idx: i32) ApiError!void {
        const from = normalizeIndex(from_idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const to = normalizeIndex(to_idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        self.vm.c_stack.items[to] = self.vm.c_stack.items[from];
    }

    pub fn rotate(self: *State, idx: i32, n: i32) ApiError!void {
        const start = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const slice = self.vm.c_stack.items[start..];
        if (slice.len <= 1) return;

        var nmod = @mod(@as(i64, n), @as(i64, @intCast(slice.len)));
        if (nmod < 0) nmod += @intCast(slice.len);
        if (nmod == 0) return;

        // Zig rotates left; Lua's lua_rotate with positive n rotates right.
        const left: usize = slice.len - @as(usize, @intCast(nmod));
        std.mem.rotate(vm_mod.Value, slice, left);
    }

    pub fn concat(self: *State, n: usize) ApiError!void {
        if (n > self.vm.c_stack.items.len) return error.InvalidIndex;
        if (n == 0) {
            try self.pushstring("");
            return;
        }
        if (n == 1) return;

        const start = self.vm.c_stack.items.len - n;
        var acc = self.vm.c_stack.items[start];
        var i = start + 1;
        while (i < self.vm.c_stack.items.len) : (i += 1) {
            acc = self.vm.apiConcat(acc, self.vm.c_stack.items[i]) catch return mapVmError();
        }
        self.vm.c_stack.items.len = start;
        try self.vm.c_stack.append(self.vm.alloc, acc);
    }

    /// PUC `lua_arith` (lapi.c:lua_arith): perform an arithmetic operation
    /// on the top 1–2 stack values. For binary ops (ADD..SHR): operands at
    /// -2 and -1, pop both, push result. For unary ops (UNM, BNOT): operand
    /// at -1, pop, push result. Handles Int/Num directly; falls back to
    /// metamethods for tables/userdata.
    pub fn arith(self: *State, op: ArithOp) ApiError!void {
        const top = self.vm.c_stack.items.len;
        const is_unary = (op == .unm or op == .bnot);
        const need: usize = if (is_unary) 1 else 2;
        if (top < need) return error.InvalidState;

        const result: vm_mod.Value = if (is_unary) blk: {
            // PUC lua_arith: for unary ops, duplicate the top value as both
            // operands. The result is computed from the single operand.
            const v = self.vm.c_stack.items[top - 1];
            break :blk self.vm.apiArith(@intFromEnum(op), v, v) catch return mapVmError();
        } else blk: {
            const b = self.vm.c_stack.items[top - 1];
            const a = self.vm.c_stack.items[top - 2];
            break :blk self.vm.apiArith(@intFromEnum(op), a, b) catch return mapVmError();
        };

        // Pop operands: 1 for unary, 2 for binary.
        self.vm.c_stack.items.len -= if (is_unary) 1 else 2;
        try self.vm.c_stack.append(self.vm.alloc, result);
    }

    /// PUC `lua_rawequal` (lapi.c:lua_rawequal): raw equality without
    /// metamethods. Returns true if the values at idx1 and idx2 are the
    /// same type and equal value (pointer identity for tables/closures,
    /// byte comparison for strings, numeric cross-comparison for Int/Num).
    pub fn rawequal(self: *State, idx1: i32, idx2: i32) bool {
        const abs1 = normalizeIndex(idx1, self.vm.c_stack.items.len) orelse return false;
        const abs2 = normalizeIndex(idx2, self.vm.c_stack.items.len) orelse return false;
        return vm_mod.Vm.apiRawEqual(self.vm.c_stack.items[abs1], self.vm.c_stack.items[abs2]);
    }

    /// PUC `lua_compare` (lapi.c:lua_compare): comparison with metamethods.
    /// For numbers and strings: direct comparison. For tables/userdata:
    /// tries __eq/__lt/__le metamethods. Returns false if either index is
    /// invalid or the comparison is not possible.
    pub fn compare(self: *State, idx1: i32, idx2: i32, op: CompareOp) ApiError!bool {
        const abs1 = normalizeIndex(idx1, self.vm.c_stack.items.len) orelse return false;
        const abs2 = normalizeIndex(idx2, self.vm.c_stack.items.len) orelse return false;
        const a = self.vm.c_stack.items[abs1];
        const b = self.vm.c_stack.items[abs2];
        return self.vm.apiCompare(@intFromEnum(op), a, b) catch return mapVmError();
    }

    /// PUC `lua_len` (lapi.c:lua_len): push the length of the value at idx.
    /// For strings: byte length. For tables: border length (or __len
    /// metamethod). For other types: tries __len metamethod, errors if none.
    pub fn len(self: *State, idx: i32) ApiError!void {
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const v = self.vm.c_stack.items[abs];
        const result = self.vm.apiLen(v) catch return mapVmError();
        try self.vm.c_stack.append(self.vm.alloc, result);
    }

    /// PUC `lua_gc` (lapi.c:lua_gc): garbage collector control. Maps
    /// LUA_GC* constants to VM GC operations.
    pub fn gc(self: *State, what: i32, data: i32) i32 {
        return self.vm.apiGc(what, data);
    }

    /// PUC `lua_status` (lapi.c:lua_status): return the status of the
    /// thread. For the main VM (always running when C code executes),
    /// returns LUA_OK (0). For coroutine threads, maps the Thread status
    /// to PUC status codes.
    pub fn status(self: *State) c_int {
        // The main VM is always in the OK state when C code is running.
        // Coroutine threads have their own status field, but lua_status is
        // called on L (the main thread), not on a coroutine.
        _ = self;
        return 0; // LUA_OK
    }

    /// PUC `lua_pushthread` (lapi.c:lua_pushthread): push the current thread
    /// onto the stack. Returns 1 if L is the main thread, 0 otherwise.
    /// In luazig, the Vm IS the main thread (not a Thread object), so we
    /// push nil (the main thread cannot be used as a coroutine value) and
    /// return 1. This is a justified deviation: luazig's Vm is not a Thread
    /// object and cannot be pushed as one.
    pub fn pushthread(self: *State) c_int {
        self.vm.c_stack.append(self.vm.alloc, .Nil) catch {};
        return 1; // ismainthread(L) == 1
    }

    pub fn pushnil(self: *State) ApiError!void {
        try self.vm.c_stack.append(self.vm.alloc, .Nil);
    }

    pub fn pushboolean(self: *State, v: bool) ApiError!void {
        try self.vm.c_stack.append(self.vm.alloc, .{ .Bool = v });
    }

    pub fn pushinteger(self: *State, v: i64) ApiError!void {
        try self.vm.c_stack.append(self.vm.alloc, .{ .Int = v });
    }

    pub fn pushnumber(self: *State, v: f64) ApiError!void {
        try self.vm.c_stack.append(self.vm.alloc, .{ .Num = v });
    }

    pub fn pushstring(self: *State, s: []const u8) ApiError!void {
        try self.vm.c_stack.append(self.vm.alloc, .{ .String = try self.vm.internStr(s) });
    }

    pub fn pushvalue(self: *State, idx: i32) ApiError!void {
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        try self.vm.c_stack.append(self.vm.alloc, self.vm.c_stack.items[abs]);
    }

    pub fn typeOf(self: *const State, idx: i32) ?Type {
        const abs = self.normalizeIndexConst(idx, self.vm.c_stack.items.len) orelse return null;
        return valueType(self.vm.c_stack.items[abs]);
    }

    pub fn isuserdata(self: *const State, idx: i32) bool {
        // PUC lua_isuserdata: true for both full userdata and light userdata.
        const t = self.typeOf(idx) orelse return false;
        return t == .userdata or t == .lightuserdata;
    }

    pub fn toboolean(self: *const State, idx: i32) bool {
        const v = self.valueAtConst(idx) orelse return false;
        return switch (v.*) {
            .Nil => false,
            .Bool => |b| b,
            else => true,
        };
    }

    pub fn tointeger(self: *const State, idx: i32) ?i64 {
        const v = self.valueAtConst(idx) orelse return null;
        return switch (v.*) {
            .Int => |i| i,
            .Num => |n| if (n == @round(n)) @as(i64, @intFromFloat(n)) else null,
            else => null,
        };
    }

    pub fn tonumber(self: *const State, idx: i32) ?f64 {
        const v = self.valueAtConst(idx) orelse return null;
        return switch (v.*) {
            .Int => |i| @floatFromInt(i),
            .Num => |n| n,
            else => null,
        };
    }

    pub fn tostring(self: *const State, idx: i32) ?[]const u8 {
        const v = self.valueAtConst(idx) orelse return null;
        return switch (v.*) {
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
        const v = self.valueAtConst(idx) orelse return false;
        return switch (v.*) {
            .Int, .Num => true,
            else => false,
        };
    }

    /// PUC `lua_isstring` (lapi.c): true if the value is a string or a number
    /// (both are "string-convertible" in PUC's cvt2str sense).
    pub fn isstring(self: *const State, idx: i32) bool {
        const v = self.valueAtConst(idx) orelse return false;
        return switch (v.*) {
            .String, .Int, .Num => true,
            else => false,
        };
    }

    /// PUC `lua_isinteger` (lapi.c): true if the value is specifically an
    /// integer (not a float).
    pub fn isinteger(self: *const State, idx: i32) bool {
        const v = self.valueAtConst(idx) orelse return false;
        return v.* == .Int;
    }

    /// PUC `lua_iscfunction` (lapi.c): true if the value is a C closure
    /// (a Closure with `c_func != null`). Lua closures (bytecode protos)
    /// return false.
    pub fn iscfunction(self: *const State, idx: i32) bool {
        const v = self.valueAtConst(idx) orelse return false;
        return switch (v.*) {
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
    pub fn tolstring(self: *State, idx: i32) ?[]const u8 {
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return null;
        switch (self.vm.c_stack.items[abs]) {
            .String => |s| return s.bytes(),
            .Int, .Num => {
                // PUC lua_tolstring: convert number to string in place on stack.
                // valueToInternedStr uses the same formatting as PUC's
                // luaO_tostringbuff (%.14g equivalent + ".0" for integer floats).
                const ls = self.vm.valueToInternedStr(self.vm.c_stack.items[abs]) catch return null;
                self.vm.c_stack.items[abs] = .{ .String = ls };
                return self.vm.c_stack.items[abs].String.bytes();
            },
            else => return null,
        }
    }

    /// PUC `lua_rawlen` (lapi.c:lua_rawlen): raw length without metamethods.
    /// String: byte length. Table: border length (luaH_getn). Userdata:
    /// payload size. Returns 0 for other types.
    pub fn rawlen(self: *State, idx: i32) usize {
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return 0;
        return switch (self.vm.c_stack.items[abs]) {
            .String => |s| s.bytes().len,
            .Table => |t| @intCast(self.vm.tableBorderLen(t)),
            .Userdata => |ud| ud.payload.len,
            else => 0,
        };
    }

    /// PUC `lua_tocfunction` (lapi.c:lua_tocfunction): return the C function
    /// pointer from a Closure, or null if the value is not a C closure.
    pub fn tocfunction(self: *const State, idx: i32) ?*const fn (?*vm_mod.Vm) callconv(.c) c_int {
        const v = self.valueAtConst(idx) orelse return null;
        return switch (v.*) {
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
        try self.vm.c_stack.append(self.vm.alloc, v);
        return valueType(v);
    }

    pub fn setglobal(self: *State, name: []const u8) ApiError!void {
        if (self.vm.c_stack.items.len == 0) return error.InvalidState;
        const v = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
        self.vm.c_stack.items.len -= 1;
        self.vm.apiSetGlobal(name, v) catch return mapVmError();
    }

    pub fn newtable(self: *State) ApiError!void {
        const t = self.vm.apiNewTable() catch return mapVmError();
        try self.vm.c_stack.append(self.vm.alloc, .{ .Table = t });
    }

    pub fn newthread(self: *State) ApiError!void {
        const th = self.vm.apiNewThread(.Nil) catch return mapVmError();
        try self.thread_stacks.put(self.vm.alloc, th, .empty);
        try self.vm.c_stack.append(self.vm.alloc, .{ .Thread = th });
    }

    pub fn xmove(self: *State, from_thread_idx: ?i32, to_thread_idx: ?i32, n: usize) ApiError!void {
        var from_stack = try self.apiStackFor(from_thread_idx);
        var to_stack = try self.apiStackFor(to_thread_idx);
        if (n > from_stack.items.len) return error.InvalidIndex;
        if (n == 0) return;

        const start = from_stack.items.len - n;
        const moved = try self.vm.alloc.alloc(vm_mod.Value, n);
        defer self.vm.alloc.free(moved);
        for (0..n) |i| moved[i] = from_stack.items[start + i];
        from_stack.items.len = start;
        try to_stack.appendSlice(self.vm.alloc, moved);
    }

    pub fn @"resume"(self: *State, thread_idx: i32, nargs: usize) Status {
        const th = self.threadAt(thread_idx) orelse return .runtime_error;
        const th_stack = self.threadStack(th) catch return .memory_error;
        const callee_needed = !isCallableValue(self.vm, th.callee);
        const need = nargs + @as(usize, @intFromBool(callee_needed));
        if (th_stack.items.len < need) return .runtime_error;

        const base = th_stack.items.len - need;
        if (callee_needed) {
            const callee = th_stack.items[base];
            if (!isCallableValue(self.vm, callee)) return .runtime_error;
            th.callee = callee;
        }
        const arg_start = if (callee_needed) base + 1 else base;
        const args = th_stack.items[arg_start .. arg_start + nargs];

        var out: [64]vm_mod.Value = undefined;
        for (&out) |*v| v.* = .Nil;
        const produced = self.vm.apiResumeThread(th, args, out[0..]) catch return .runtime_error;
        const ok = produced > 0 and out[0] == .Bool and out[0].Bool;

        th_stack.items.len = base;
        if (!ok) {
            if (produced > 1) th_stack.append(self.vm.alloc, out[1]) catch return .memory_error;
            return .runtime_error;
        }

        const nres = if (produced > 0) produced - 1 else 0;
        th_stack.appendSlice(self.vm.alloc, out[1 .. 1 + nres]) catch return .memory_error;
        return if (th.status == .suspended) .yielded else .ok;
    }

    pub fn yield(self: *State, nresults: usize) ApiError!void {
        if (nresults > self.vm.c_stack.items.len) return error.InvalidIndex;
        const base = self.vm.c_stack.items.len - nresults;
        self.vm.apiYield(self.vm.c_stack.items[base..]) catch |err| switch (err) {
            error.RuntimeError, error.Yield => return error.Runtime,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    pub fn isyieldable(self: *State, thread_idx: ?i32) ApiError!bool {
        const th = if (thread_idx) |idx| self.threadAt(idx) orelse return error.Type else null;
        return self.vm.apiIsYieldable(th) catch return mapVmError();
    }

    pub fn gettable(self: *State, idx: i32) ApiError!Type {
        if (self.vm.c_stack.items.len == 0) return error.InvalidState;
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const key = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
        const object = self.vm.c_stack.items[abs];
        const out = self.vm.apiGetTable(object, key) catch return mapVmError();
        self.vm.c_stack.items.len -= 1;
        try self.vm.c_stack.append(self.vm.alloc, out);
        return valueType(out);
    }

    pub fn settable(self: *State, idx: i32) ApiError!void {
        if (self.vm.c_stack.items.len < 2) return error.InvalidState;
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const value = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
        const key = self.vm.c_stack.items[self.vm.c_stack.items.len - 2];
        const object = self.vm.c_stack.items[abs];
        self.vm.apiSetTable(object, key, value) catch return mapVmError();
        self.vm.c_stack.items.len -= 2;
    }

    pub fn getfield(self: *State, idx: i32, key: []const u8) ApiError!Type {
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const object = self.vm.c_stack.items[abs];
        const out = self.vm.apiGetTable(object, .{ .String = try self.vm.internStr(key) }) catch return mapVmError();
        try self.vm.c_stack.append(self.vm.alloc, out);
        return valueType(out);
    }

    pub fn setfield(self: *State, idx: i32, key: []const u8) ApiError!void {
        if (self.vm.c_stack.items.len == 0) return error.InvalidState;
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const object = self.vm.c_stack.items[abs];
        const value = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
        self.vm.apiSetTable(object, .{ .String = try self.vm.internStr(key) }, value) catch return mapVmError();
        self.vm.c_stack.items.len -= 1;
    }

    pub fn geti(self: *State, idx: i32, n: i64) ApiError!Type {
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const object = self.vm.c_stack.items[abs];
        const out = self.vm.apiGetTable(object, .{ .Int = n }) catch return mapVmError();
        try self.vm.c_stack.append(self.vm.alloc, out);
        return valueType(out);
    }

    pub fn seti(self: *State, idx: i32, n: i64) ApiError!void {
        if (self.vm.c_stack.items.len == 0) return error.InvalidState;
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const object = self.vm.c_stack.items[abs];
        const value = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
        self.vm.apiSetTable(object, .{ .Int = n }, value) catch return mapVmError();
        self.vm.c_stack.items.len -= 1;
    }

    pub fn rawget(self: *State, idx: i32) ApiError!Type {
        if (self.vm.c_stack.items.len == 0) return error.InvalidState;
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const tbl = switch (self.vm.c_stack.items[abs]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const key = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
        const out = self.vm.apiRawGet(tbl, key) catch return mapVmError();
        self.vm.c_stack.items.len -= 1;
        try self.vm.c_stack.append(self.vm.alloc, out);
        return valueType(out);
    }

    pub fn rawset(self: *State, idx: i32) ApiError!void {
        if (self.vm.c_stack.items.len < 2) return error.InvalidState;
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const tbl = switch (self.vm.c_stack.items[abs]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const value = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
        const key = self.vm.c_stack.items[self.vm.c_stack.items.len - 2];
        self.vm.apiRawSet(tbl, key, value) catch return mapVmError();
        self.vm.c_stack.items.len -= 2;
    }

    pub fn rawgeti(self: *State, idx: i32, n: i64) ApiError!Type {
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const tbl = switch (self.vm.c_stack.items[abs]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const out = self.vm.apiRawGet(tbl, .{ .Int = n }) catch return mapVmError();
        try self.vm.c_stack.append(self.vm.alloc, out);
        return valueType(out);
    }

    pub fn rawseti(self: *State, idx: i32, n: i64) ApiError!void {
        if (self.vm.c_stack.items.len == 0) return error.InvalidState;
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const tbl = switch (self.vm.c_stack.items[abs]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const value = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
        self.vm.apiRawSet(tbl, .{ .Int = n }, value) catch return mapVmError();
        self.vm.c_stack.items.len -= 1;
    }

    /// PUC `lua_rawgetp` (lapi.c): raw table access with a light userdata
    /// pointer key. Pushes `t[p]` (no metamethods). Returns the value type.
    /// Note: PUC allows NULL `p` (creating a light userdata wrapping NULL),
    /// but Zig's `*anyopaque` cannot represent address 0. A null `p` returns
    /// `error.InvalidIndex` — a justified deviation since no real C code uses
    /// NULL pointer keys.
    pub fn rawgetp(self: *State, idx: i32, p: ?*anyopaque) ApiError!Type {
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const tbl = switch (self.vm.c_stack.items[abs]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const key: *anyopaque = p orelse return error.InvalidIndex;
        const out = self.vm.apiRawGet(tbl, .{ .LightUserdata = key }) catch return mapVmError();
        try self.vm.c_stack.append(self.vm.alloc, out);
        return valueType(out);
    }

    /// PUC `lua_rawsetp` (lapi.c): raw table set with a light userdata
    /// pointer key. Performs `t[p] = v` (no metamethods). Pops the value.
    /// See `rawgetp` for the null-`p` deviation note.
    pub fn rawsetp(self: *State, idx: i32, p: ?*anyopaque) ApiError!void {
        if (self.vm.c_stack.items.len == 0) return error.InvalidState;
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const tbl = switch (self.vm.c_stack.items[abs]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const key: *anyopaque = p orelse return error.InvalidIndex;
        const value = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
        self.vm.apiRawSet(tbl, .{ .LightUserdata = key }, value) catch return mapVmError();
        self.vm.c_stack.items.len -= 1;
    }

    pub fn next(self: *State, idx: i32) ApiError!bool {
        if (self.vm.c_stack.items.len == 0) return error.InvalidState;
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const tbl = switch (self.vm.c_stack.items[abs]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const key = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
        var out: [2]vm_mod.Value = .{ .Nil, .Nil };
        const produced = self.vm.apiNext(tbl, key, out[0..]) catch return mapVmError();
        self.vm.c_stack.items.len -= 1;
        if (produced == 0) return false;
        try self.vm.c_stack.appendSlice(self.vm.alloc, out[0..2]);
        return true;
    }

    pub fn loadbuffer(self: *State, chunk: []const u8, chunk_name: []const u8) Status {
        const compiled = self.compileChunk(chunk, chunk_name) catch |e| return mapCompileError(e);
        self.vm.c_stack.append(self.vm.alloc, compiled) catch return .memory_error;
        return .ok;
    }

    pub fn loadfile(self: *State, path: []const u8) Status {
        const source = source_mod.Source.loadFile(self.vm.alloc, stdio.activeIo(), path) catch return .memory_error;
        defer self.vm.alloc.free(source.name);
        defer self.vm.alloc.free(source.bytes);
        return self.loadbuffer(source.bytes, source.name);
    }

    pub fn pcall(self: *State, nargs: usize, nresults: i32) Status {
        if (self.vm.c_stack.items.len < nargs + 1) return .runtime_error;
        const fn_idx = self.vm.c_stack.items.len - nargs - 1;
        const callee = self.vm.c_stack.items[fn_idx];
        const args = self.vm.c_stack.items[fn_idx + 1 ..];
        const ret = self.vm.apiCall(callee, args) catch {
            // PUC luaD_pcall: on error, restore the stack to the base (removing
            // the function and its arguments), then propagate the error status.
            self.vm.c_stack.items.len = fn_idx;
            return .runtime_error;
        };
        defer self.vm.alloc.free(ret);

        self.vm.c_stack.items.len = fn_idx;
        const want: usize = if (nresults < 0)
            ret.len
        else
            @min(ret.len, @as(usize, @intCast(nresults)));
        self.vm.c_stack.appendSlice(self.vm.alloc, ret[0..want]) catch return .memory_error;
        return .ok;
    }

    pub fn getmetatable(self: *State, idx: i32) ApiError!bool {
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const mt: ?*vm_mod.Table = switch (self.vm.c_stack.items[abs]) {
            .Table => |t| t.metatable,
            .Userdata => |ud| ud.metatable,
            else => null,
        };
        if (mt) |m| {
            try self.vm.c_stack.append(self.vm.alloc, .{ .Table = m });
            return true;
        }
        return false;
    }

    pub fn setmetatable(self: *State, idx: i32) ApiError!void {
        if (self.vm.c_stack.items.len < 1) return error.InvalidState;
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const mt_val = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
        self.vm.c_stack.items.len -= 1;
        const mt = if (mt_val == .Table) mt_val.Table else null;
        switch (self.vm.c_stack.items[abs]) {
            .Table => |t| {
                t.metatable = mt;
                if (mt) |m| {
                    if (self.vm.metamethodValue(.{ .Table = m }, "__gc") != null) {
                        self.vm.registerFinalizable(.{ .table = t }) catch {};
                    }
                }
            },
            .Userdata => |ud| {
                ud.metatable = mt;
                if (mt) |m| {
                    if (self.vm.metamethodValue(.{ .Table = m }, "__gc") != null) {
                        self.vm.registerFinalizable(.{ .userdata = ud }) catch {};
                    }
                }
            },
            else => {},
        }
    }

    pub fn getregistry(self: *State) ApiError!void {
        const reg = self.vm.apiEnsureRegistry() catch return error.Runtime;
        try self.vm.c_stack.append(self.vm.alloc, .{ .Table = reg });
    }

    pub fn getupvalue(self: *State, func_idx: i32, n: usize) ApiError!?[]const u8 {
        const fv = self.valueAtConst(func_idx) orelse return error.InvalidIndex;
        const dbg = try self.requireDebugModule();
        const f = self.vm.apiGetTable(dbg, .{ .String = try self.vm.internStr("getupvalue") }) catch return error.Runtime;
        var args = [_]vm_mod.Value{ fv.*, .{ .Int = @intCast(n) } };
        const ret = self.vm.apiCall(f, args[0..]) catch return error.Runtime;
        defer self.vm.alloc.free(ret);
        if (ret.len == 0 or ret[0] == .Nil) return null;
        if (ret[0] != .String) return error.Type;
        if (ret.len > 1) try self.vm.c_stack.append(self.vm.alloc, ret[1]);
        return ret[0].String.bytes();
    }

    pub fn setupvalue(self: *State, func_idx: i32, n: usize) ApiError!?[]const u8 {
        if (self.vm.c_stack.items.len == 0) return error.InvalidState;
        const fv = self.valueAtConst(func_idx) orelse return error.InvalidIndex;
        const set_val = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
        const dbg = try self.requireDebugModule();
        const f = self.vm.apiGetTable(dbg, .{ .String = try self.vm.internStr("setupvalue") }) catch return error.Runtime;
        var args = [_]vm_mod.Value{ fv.*, .{ .Int = @intCast(n) }, set_val };
        const ret = self.vm.apiCall(f, args[0..]) catch return error.Runtime;
        defer self.vm.alloc.free(ret);
        self.vm.c_stack.items.len -= 1;
        if (ret.len == 0 or ret[0] == .Nil) return null;
        if (ret[0] != .String) return error.Type;
        return ret[0].String.bytes();
    }

    // -----------------------------------------------------------------------
    // Push functions (ported from c_api.zig)
    // -----------------------------------------------------------------------

    /// Push an arbitrary-length string (bytes may contain embedded NULs).
    pub fn pushlstring(self: *State, s: []const u8) ApiError!void {
        const ls = try self.vm.internStr(s);
        try self.vm.c_stack.append(self.vm.alloc, .{ .String = ls });
    }

    /// Push a light userdata (raw pointer). Pushes nil if p is null.
    pub fn pushlightuserdata(self: *State, p: ?*anyopaque) ApiError!void {
        if (p) |ptr| {
            try self.vm.c_stack.append(self.vm.alloc, .{ .LightUserdata = ptr });
        } else {
            try self.vm.c_stack.append(self.vm.alloc, .Nil);
        }
    }

    /// Push a C closure wrapping `fn_` with `n` upvalues from the stack.
    /// Currently only n=0 is supported (upvalues need Phase 9).
    pub fn pushcclosure(self: *State, fn_: ?*const fn (?*vm_mod.Vm) callconv(.c) c_int, n: usize) ApiError!void {
        if (n == 0) {
            const cl = try self.vm.alloc.create(vm_mod.Closure);
            cl.* = .{ .upvalues = &.{}, .c_func = fn_ };
            try self.vm.gcRegisterClosure(cl);
            try self.vm.c_stack.append(self.vm.alloc, .{ .Closure = cl });
            return;
        }
        // Pop n values from c_stack, create n Cell objects as closed upvalues.
        if (self.vm.c_stack.items.len < n) return error.InvalidState;
        const upv_cells = try self.vm.alloc.alloc(*vm_mod.Cell, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const cell = try self.vm.alloc.create(vm_mod.Cell);
            cell.* = .{ .value = self.vm.c_stack.items[self.vm.c_stack.items.len - (n - i)] };
            try self.vm.gcRegisterCell(cell);
            upv_cells[i] = cell;
        }
        self.vm.c_stack.items.len -= n;

        const cl = try self.vm.alloc.create(vm_mod.Closure);
        cl.* = .{ .upvalues = upv_cells, .c_func = fn_ };
        try self.vm.gcRegisterClosure(cl);
        try self.vm.c_stack.append(self.vm.alloc, .{ .Closure = cl });
    }

    /// Convenience: push a C function as a closure with 0 upvalues.
    pub fn pushcfunction(self: *State, fn_: ?*const fn (?*vm_mod.Vm) callconv(.c) c_int) ApiError!void {
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
        const ls = try self.vm.createExternalLuaString(s, str_len, falloc, ud);
        try self.vm.c_stack.append(self.vm.alloc, .{ .String = ls });
    }

    // -----------------------------------------------------------------------
    // Userdata functions (ported from c_api.zig)
    // -----------------------------------------------------------------------

    /// Allocate a full userdata with `sz` bytes of payload and `nuvalue`
    /// uservalues, push it, return payload pointer.
    pub fn newuserdatauv(self: *State, sz: usize, nuvalue: usize) ApiError!?*anyopaque {
        const ud = self.vm.allocUserdata(sz, nuvalue) catch return error.Runtime;
        try self.vm.c_stack.append(self.vm.alloc, .{ .Userdata = ud });
        return if (ud.payload.len > 0) @ptrCast(ud.payload.ptr) else @ptrCast(ud);
    }

    /// Return payload pointer for full userdata at `idx`, or lightuserdata
    /// pointer, or null.
    pub fn touserdata(self: *State, idx: i32) ?*anyopaque {
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return null;
        return switch (self.vm.c_stack.items[abs]) {
            .Userdata => |ud| if (ud.payload.len > 0) @ptrCast(ud.payload.ptr) else @ptrCast(ud),
            .LightUserdata => |p| p,
            else => null,
        };
    }

    /// Return raw pointer for GC objects (userdata, table, thread, string).
    pub fn topointer(self: *State, idx: i32) ?*anyopaque {
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return null;
        return switch (self.vm.c_stack.items[abs]) {
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
        if (self.vm.c_stack.items.len < 1) return error.InvalidState;
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        const val = self.vm.c_stack.items[self.vm.c_stack.items.len - 1];
        self.vm.c_stack.items.len -= 1;
        switch (self.vm.c_stack.items[abs]) {
            .Userdata => |ud| {
                const n_idx = n - 1;
                if (n_idx >= ud.uservalues.len) return false;
                ud.uservalues[n_idx] = val;
                return true;
            },
            else => return false,
        }
    }

    /// Push the n-th uservalue from the userdata at `idx`.
    pub fn getiuservalue(self: *State, idx: i32, n: usize) ApiError!Type {
        const abs = normalizeIndex(idx, self.vm.c_stack.items.len) orelse {
            try self.vm.c_stack.append(self.vm.alloc, .Nil);
            return .nil;
        };
        switch (self.vm.c_stack.items[abs]) {
            .Userdata => |ud| {
                const n_idx = n - 1;
                const val = if (n_idx < ud.uservalues.len) ud.uservalues[n_idx] else .Nil;
                try self.vm.c_stack.append(self.vm.alloc, val);
                return valueType(val);
            },
            else => {
                try self.vm.c_stack.append(self.vm.alloc, .Nil);
                return .nil;
            },
        }
    }

    // -----------------------------------------------------------------------
    // Unprotected call (Zig equivalent of lua_call)
    // -----------------------------------------------------------------------

    /// Unprotected call: on failure, returns error.Runtime. The actual longjmp
    /// boundary logic stays in c_api.zig for C callers.
    pub fn call(self: *State, nargs: usize, nresults: i32) ApiError!void {
        if (self.vm.c_stack.items.len < nargs + 1) return error.InvalidState;
        const fn_idx = self.vm.c_stack.items.len - nargs - 1;
        const callee = self.vm.c_stack.items[fn_idx];
        const args = self.vm.c_stack.items[fn_idx + 1 ..];
        const ret = self.vm.apiCall(callee, args) catch return error.Runtime;
        defer self.vm.alloc.free(ret);
        self.vm.c_stack.items.len = fn_idx;
        const want: usize = if (nresults < 0) ret.len else @min(ret.len, @as(usize, @intCast(nresults)));
        try self.vm.c_stack.appendSlice(self.vm.alloc, ret[0..want]);
    }

    // -----------------------------------------------------------------------
    // lauxlib functions (ported from c_api.zig)
    // -----------------------------------------------------------------------

    /// PUC `luaL_Reg`: a {name, func} pair terminated by a sentinel.
    pub const Reg = extern struct {
        name: ?[*:0]const u8,
        func: ?*const fn (?*vm_mod.Vm) callconv(.c) c_int,
    };

    /// Return the bytes of the string at `arg`, or "" on type mismatch.
    pub fn checklstring(self: *State, arg: i32) []const u8 {
        const abs = normalizeIndex(arg, self.vm.c_stack.items.len) orelse return "";
        return switch (self.vm.c_stack.items[abs]) {
            .String => |s| s.bytes(),
            else => "",
        };
    }

    /// Store the top value in table `t` under a fresh integer key and return
    /// that key. Returns -1 (LUA_REFNIL) for nil, -2 (LUA_NOREF) on error.
    pub fn ref(self: *State, t: i32) i32 {
        const top = self.vm.c_stack.items.len;
        if (top == 0) return -2;
        const val = self.vm.c_stack.items[top - 1];
        self.vm.c_stack.items.len -= 1;
        if (val == .Nil) return -1;

        const registry_idx: c_int = -1001000;
        const tbl = if (t == registry_idx) blk: {
            const reg = self.vm.apiEnsureRegistry() catch return -2;
            break :blk reg;
        } else blk: {
            const tbl_idx = normalizeIndex(t, top) orelse return -2;
            break :blk switch (self.vm.c_stack.items[tbl_idx]) {
                .Table => |tt| tt,
                else => return -2,
            };
        };
        const ref_key: i64 = self.vm.c_ref_counter;
        self.vm.c_ref_counter += 1;
        self.vm.apiRawSet(tbl, .{ .Int = ref_key }, val) catch return -2;
        return @intCast(ref_key);
    }

    /// Release reference `ref` from table at `t` (PUC free-list recycling).
    pub fn unref(self: *State, t: i32, ref_id: i32) void {
        const registry_idx: c_int = -1001000;
        const tbl = if (t == registry_idx) blk: {
            break :blk self.vm.apiEnsureRegistry() catch return;
        } else blk: {
            const i = normalizeIndex(t, self.vm.c_stack.items.len) orelse return;
            break :blk switch (self.vm.c_stack.items[i]) {
                .Table => |tt| tt,
                else => return,
            };
        };
        const freelist = self.vm.apiRawGet(tbl, .{ .Int = 0 }) catch .Nil;
        self.vm.apiRawSet(tbl, .{ .Int = @intCast(ref_id) }, freelist) catch {};
        self.vm.apiRawSet(tbl, .{ .Int = 0 }, .{ .Int = @intCast(ref_id) }) catch {};
    }

    /// Create a table, store it in the registry under key `tname`, push it.
    pub fn newmetatable(self: *State, tname: []const u8) ApiError!bool {
        const reg = self.vm.apiEnsureRegistry() catch return error.Runtime;
        const key = try self.vm.internStr(tname);
        const existing = self.vm.apiRawGet(reg, .{ .String = key }) catch .Nil;
        if (existing == .Table) {
            try self.vm.c_stack.append(self.vm.alloc, existing);
            return false;
        }
        const mt = try self.vm.alloc.create(vm_mod.Table);
        mt.* = .{};
        self.vm.registerFinalizable(.{ .table = mt }) catch {};
        self.vm.apiRawSet(reg, .{ .String = key }, .{ .Table = mt }) catch {};
        try self.vm.c_stack.append(self.vm.alloc, .{ .Table = mt });
        return true;
    }

    /// Push the metatable registered under `tname`, or nil.
    pub fn getRegisteredMetatable(self: *State, tname: []const u8) ApiError!void {
        const reg = self.vm.apiEnsureRegistry() catch {
            try self.vm.c_stack.append(self.vm.alloc, .Nil);
            return;
        };
        const key = try self.vm.internStr(tname);
        const val = self.vm.apiRawGet(reg, .{ .String = key }) catch .Nil;
        try self.vm.c_stack.append(self.vm.alloc, val);
    }

    /// Get metatable from registry by name, set on value at top.
    pub fn setRegisteredMetatable(self: *State, tname: []const u8) ApiError!void {
        try self.getRegisteredMetatable(tname);
        _ = try self.setmetatable(-2);
    }

    /// Check if value at `ud` is a userdata with metatable `tname`.
    pub fn testudata(self: *State, ud: i32, tname: []const u8) ?*anyopaque {
        const abs = normalizeIndex(ud, self.vm.c_stack.items.len) orelse return null;
        if (self.vm.c_stack.items[abs] != .Userdata) return null;
        const reg = self.vm.apiEnsureRegistry() catch return null;
        const key = self.vm.internStr(tname) catch return null;
        const expected = self.vm.apiRawGet(reg, .{ .String = key }) catch return null;
        if (expected != .Table) return null;
        const ud_val = self.vm.c_stack.items[abs].Userdata;
        if (ud_val.metatable != expected.Table) return null;
        return if (ud_val.payload.len > 0) @ptrCast(ud_val.payload.ptr) else @ptrCast(ud_val);
    }

    /// Like testudata. Returns null on mismatch.
    pub fn checkudata(self: *State, ud: i32, tname: []const u8) ?*anyopaque {
        return self.testudata(ud, tname);
    }

    /// Return integer at `arg` or error.
    pub fn checkinteger(self: *State, arg: i32) ApiError!i64 {
        const abs = normalizeIndex(arg, self.vm.c_stack.items.len) orelse return error.InvalidIndex;
        return switch (self.vm.c_stack.items[abs]) {
            .Int => |v| v,
            .Num => |v| if (std.math.floor(v) == v and v >= -9.2233720368548e18 and v <= 9.2233720368548e18)
                @intFromFloat(v)
            else
                error.Type,
            else => error.Type,
        };
    }

    /// Return integer at `arg` or `def` if nil/absent.
    pub fn optinteger(self: *State, arg: i32, def: i64) ApiError!i64 {
        const abs = normalizeIndex(arg, self.vm.c_stack.items.len) orelse return def;
        return switch (self.vm.c_stack.items[abs]) {
            .Int => |v| v,
            .Nil => def,
            else => def,
        };
    }

    /// Verify version/size compatibility. No-op in current implementation.
    pub fn checkversion(self: *State) void {
        _ = self;
    }

    /// Register every {name, func} in `reg` into the table at top of stack.
    pub fn registerfuncs(self: *State, reg: [*]const Reg, nup: usize) ApiError!void {
        const top = self.vm.c_stack.items.len;
        if (top < nup + 1) return error.InvalidState;
        const tbl_idx: usize = top - nup - 1;
        const tbl = switch (self.vm.c_stack.items[tbl_idx]) {
            .Table => |t| t,
            else => return error.Type,
        };
        // Snapshot the shared upvalues (they're at [tbl_idx+1 .. tbl_idx+1+nup])
        const upv_start = tbl_idx + 1;
        var shared_cells: []*vm_mod.Cell = &.{};
        if (nup > 0) {
            shared_cells = self.vm.alloc.alloc(*vm_mod.Cell, nup) catch return error.OutOfMemory;
            for (0..nup) |i| {
                const cell = self.vm.alloc.create(vm_mod.Cell) catch return error.OutOfMemory;
                cell.* = .{ .value = self.vm.c_stack.items[upv_start + i] };
                self.vm.gcRegisterCell(cell) catch {};
                shared_cells[i] = cell;
            }
        }
        var i: usize = 0;
        while (reg[i].name != null) : (i += 1) {
            const name = std.mem.span(reg[i].name.?);
            const key_str = self.vm.internStr(name) catch continue;
            if (reg[i].func == null) {
                self.vm.apiRawSet(tbl, .{ .String = key_str }, .{ .Bool = false }) catch {};
                continue;
            }
            const cl = self.vm.alloc.create(vm_mod.Closure) catch return error.OutOfMemory;
            cl.* = .{ .upvalues = @ptrCast(shared_cells), .c_func = reg[i].func };
            self.vm.gcRegisterClosure(cl) catch {};
            self.vm.apiRawSet(tbl, .{ .String = key_str }, .{ .Closure = cl }) catch {};
        }
        self.vm.c_stack.items.len -= nup;
    }

    /// Convenience: create a fresh table and register `reg` into it.
    pub fn newlib(self: *State, reg: [*]const Reg) ApiError!void {
        try self.newtable();
        try self.registerfuncs(reg, 0);
    }

    fn compileChunk(self: *State, bytes: []const u8, chunk_name: []const u8) !vm_mod.Value {
        return self.vm.compileChunkValue(bytes, chunk_name);
    }

    fn valueAtConst(self: *const State, idx: i32) ?*const vm_mod.Value {
        const abs = self.normalizeIndexConst(idx, self.vm.c_stack.items.len) orelse return null;
        return &self.vm.c_stack.items[abs];
    }

    fn threadAt(self: *const State, idx: i32) ?*vm_mod.Thread {
        const v = self.valueAtConst(idx) orelse return null;
        return switch (v.*) {
            .Thread => |th| th,
            else => null,
        };
    }

    fn threadStack(self: *State, th: *vm_mod.Thread) ApiError!*std.ArrayListUnmanaged(vm_mod.Value) {
        const gop = try self.thread_stacks.getOrPut(self.vm.alloc, th);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        return gop.value_ptr;
    }

    fn apiStackFor(self: *State, thread_idx: ?i32) ApiError!*std.ArrayListUnmanaged(vm_mod.Value) {
        if (thread_idx) |idx| {
            const th = self.threadAt(idx) orelse return error.Type;
            return try self.threadStack(th);
        }
        return &self.vm.c_stack;
    }

    fn normalizeIndexConst(_: *const State, idx: i32, top: usize) ?usize {
        return normalizeIndex(idx, top);
    }

    fn callGlobal(self: *State, name: []const u8, args: []const vm_mod.Value) ![]vm_mod.Value {
        const callee = self.vm.apiGetGlobal(name);
        return self.vm.apiCall(callee, args);
    }

    fn requireDebugModule(self: *State) ApiError!vm_mod.Value {
        var args = [_]vm_mod.Value{.{ .String = try self.vm.internStr("debug") }};
        const ret = self.callGlobal("require", args[0..]) catch return error.Runtime;
        defer self.vm.alloc.free(ret);
        if (ret.len == 0 or ret[0] != .Table) return error.Runtime;
        return ret[0];
    }
};

fn isCallableValue(vm: *vm_mod.Vm, v: vm_mod.Value) bool {
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
        if (node.key_tt != .string) continue;
        if (node.value == .Nil) continue;
        if (std.mem.eql(u8, node.key_val.string.bytes(), "__name")) {
            const nm = node.value;
            if (nm != .String) return false;
            return std.mem.eql(u8, nm.String.bytes(), "FILE*");
        }
    }
    return false;
}

fn mapVmError() ApiError {
    return error.Runtime;
}

pub fn mapCompileError(err_val: anyerror) Status {
    return switch (err_val) {
        error.Syntax => .syntax_error,
        error.OutOfMemory => .memory_error,
        else => .runtime_error,
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
