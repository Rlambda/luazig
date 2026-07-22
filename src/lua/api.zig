const std = @import("std");
const stdio = @import("util").stdio;

const ast = @import("ast.zig");
const codegen_bc = @import("codegen_bc.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
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
};

pub const Status = enum(u8) {
    ok,
    yielded,
    runtime_error,
    syntax_error,
    memory_error,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
};

pub const State = struct {
    vm: vm_mod.Vm,
    alloc: std.mem.Allocator,
    stack: std.ArrayListUnmanaged(vm_mod.Value) = .empty,
    thread_stacks: std.AutoHashMapUnmanaged(*vm_mod.Thread, std.ArrayListUnmanaged(vm_mod.Value)) = .empty,

    pub fn init(opts: Options) State {
        return .{
            .vm = vm_mod.Vm.init(opts.allocator),
            .alloc = opts.allocator,
        };
    }

    pub fn deinit(self: *State) void {
        var it = self.thread_stacks.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.alloc);
        self.thread_stacks.deinit(self.alloc);
        self.stack.deinit(self.alloc);
        self.vm.deinit();
    }

    pub fn normalizeIndex(self: *State, idx: i32, top: usize) ApiError!usize {
        _ = self;
        if (idx == 0) return error.InvalidIndex;
        if (idx > 0) {
            const abs: usize = @intCast(idx - 1);
            if (abs >= top) return error.InvalidIndex;
            return abs;
        }
        const r: usize = @intCast(-idx);
        if (r == 0 or r > top) return error.InvalidIndex;
        return top - r;
    }

    pub fn gettop(self: *const State) usize {
        return self.stack.items.len;
    }

    pub fn settop(self: *State, idx: i32) ApiError!void {
        const top = self.stack.items.len;
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
            self.stack.items.len = new_top;
            return;
        }
        const add = new_top - top;
        try self.stack.appendNTimes(self.alloc, .Nil, add);
    }

    pub fn pop(self: *State, n: usize) ApiError!void {
        if (n > self.stack.items.len) return error.InvalidIndex;
        self.stack.items.len -= n;
    }

    pub fn absindex(self: *State, idx: i32) ApiError!i32 {
        if (idx == 0) return error.InvalidIndex;
        if (idx > 0) {
            _ = try self.normalizeIndex(idx, self.stack.items.len);
            return idx;
        }
        _ = try self.normalizeIndex(idx, self.stack.items.len);
        return @intCast(@as(i64, @intCast(self.stack.items.len)) + @as(i64, idx) + 1);
    }

    pub fn insert(self: *State, idx: i32) ApiError!void {
        try self.rotate(idx, 1);
    }

    pub fn remove(self: *State, idx: i32) ApiError!void {
        try self.rotate(idx, -1);
        try self.pop(1);
    }

    pub fn replace(self: *State, idx: i32) ApiError!void {
        if (self.stack.items.len == 0) return error.InvalidState;
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        const top = self.stack.items.len - 1;
        self.stack.items[abs] = self.stack.items[top];
        self.stack.items.len = top;
    }

    pub fn copy(self: *State, from_idx: i32, to_idx: i32) ApiError!void {
        const from = try self.normalizeIndex(from_idx, self.stack.items.len);
        const to = try self.normalizeIndex(to_idx, self.stack.items.len);
        self.stack.items[to] = self.stack.items[from];
    }

    pub fn rotate(self: *State, idx: i32, n: i32) ApiError!void {
        const start = try self.normalizeIndex(idx, self.stack.items.len);
        const slice = self.stack.items[start..];
        if (slice.len <= 1) return;

        var nmod = @mod(@as(i64, n), @as(i64, @intCast(slice.len)));
        if (nmod < 0) nmod += @intCast(slice.len);
        if (nmod == 0) return;

        // Zig rotates left; Lua's lua_rotate with positive n rotates right.
        const left: usize = slice.len - @as(usize, @intCast(nmod));
        std.mem.rotate(vm_mod.Value, slice, left);
    }

    pub fn concat(self: *State, n: usize) ApiError!void {
        if (n > self.stack.items.len) return error.InvalidIndex;
        if (n == 0) {
            try self.pushstring("");
            return;
        }
        if (n == 1) return;

        const start = self.stack.items.len - n;
        var acc = self.stack.items[start];
        var i = start + 1;
        while (i < self.stack.items.len) : (i += 1) {
            acc = self.vm.apiConcat(acc, self.stack.items[i]) catch return mapVmError();
        }
        self.stack.items.len = start;
        try self.stack.append(self.alloc, acc);
    }

    pub fn pushnil(self: *State) ApiError!void {
        try self.stack.append(self.alloc, .Nil);
    }

    pub fn pushboolean(self: *State, v: bool) ApiError!void {
        try self.stack.append(self.alloc, .{ .Bool = v });
    }

    pub fn pushinteger(self: *State, v: i64) ApiError!void {
        try self.stack.append(self.alloc, .{ .Int = v });
    }

    pub fn pushnumber(self: *State, v: f64) ApiError!void {
        try self.stack.append(self.alloc, .{ .Num = v });
    }

    pub fn pushstring(self: *State, s: []const u8) ApiError!void {
        try self.stack.append(self.alloc, .{ .String = try self.vm.internStr(s) });
    }

    pub fn pushvalue(self: *State, idx: i32) ApiError!void {
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        try self.stack.append(self.alloc, self.stack.items[abs]);
    }

    pub fn typeOf(self: *const State, idx: i32) ?Type {
        const abs = self.normalizeIndexConst(idx, self.stack.items.len) orelse return null;
        return valueType(self.stack.items[abs]);
    }

    pub fn isuserdata(self: *const State, idx: i32) bool {
        return self.typeOf(idx) == .userdata;
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

    pub fn getglobal(self: *State, name: []const u8) ApiError!Type {
        const v = self.vm.apiGetGlobal(name);
        try self.stack.append(self.alloc, v);
        return valueType(v);
    }

    pub fn setglobal(self: *State, name: []const u8) ApiError!void {
        if (self.stack.items.len == 0) return error.InvalidState;
        const v = self.stack.items[self.stack.items.len - 1];
        self.stack.items.len -= 1;
        self.vm.apiSetGlobal(name, v) catch return mapVmError();
    }

    pub fn newtable(self: *State) ApiError!void {
        const t = self.vm.apiNewTable() catch return mapVmError();
        try self.stack.append(self.alloc, .{ .Table = t });
    }

    pub fn newthread(self: *State) ApiError!void {
        const th = self.vm.apiNewThread(.Nil) catch return mapVmError();
        try self.thread_stacks.put(self.alloc, th, .empty);
        try self.stack.append(self.alloc, .{ .Thread = th });
    }

    pub fn xmove(self: *State, from_thread_idx: ?i32, to_thread_idx: ?i32, n: usize) ApiError!void {
        var from_stack = try self.apiStackFor(from_thread_idx);
        var to_stack = try self.apiStackFor(to_thread_idx);
        if (n > from_stack.items.len) return error.InvalidIndex;
        if (n == 0) return;

        const start = from_stack.items.len - n;
        const moved = try self.alloc.alloc(vm_mod.Value, n);
        defer self.alloc.free(moved);
        for (0..n) |i| moved[i] = from_stack.items[start + i];
        from_stack.items.len = start;
        try to_stack.appendSlice(self.alloc, moved);
    }

    pub fn @"resume"(self: *State, thread_idx: i32, nargs: usize) Status {
        const th = self.threadAt(thread_idx) orelse return .runtime_error;
        const th_stack = self.threadStack(th) catch return .memory_error;
        const callee_needed = !isCallableValue(&self.vm, th.callee);
        const need = nargs + @as(usize, @intFromBool(callee_needed));
        if (th_stack.items.len < need) return .runtime_error;

        const base = th_stack.items.len - need;
        if (callee_needed) {
            const callee = th_stack.items[base];
            if (!isCallableValue(&self.vm, callee)) return .runtime_error;
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
            if (produced > 1) th_stack.append(self.alloc, out[1]) catch return .memory_error;
            return .runtime_error;
        }

        const nres = if (produced > 0) produced - 1 else 0;
        th_stack.appendSlice(self.alloc, out[1 .. 1 + nres]) catch return .memory_error;
        return if (th.status == .suspended) .yielded else .ok;
    }

    pub fn yield(self: *State, nresults: usize) ApiError!void {
        if (nresults > self.stack.items.len) return error.InvalidIndex;
        const base = self.stack.items.len - nresults;
        self.vm.apiYield(self.stack.items[base..]) catch |err| switch (err) {
            error.RuntimeError, error.Yield => return error.Runtime,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    pub fn isyieldable(self: *State, thread_idx: ?i32) ApiError!bool {
        const th = if (thread_idx) |idx| self.threadAt(idx) orelse return error.Type else null;
        return self.vm.apiIsYieldable(th) catch return mapVmError();
    }

    pub fn gettable(self: *State, idx: i32) ApiError!Type {
        if (self.stack.items.len == 0) return error.InvalidState;
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        const key = self.stack.items[self.stack.items.len - 1];
        const object = self.stack.items[abs];
        const out = self.vm.apiGetTable(object, key) catch return mapVmError();
        self.stack.items.len -= 1;
        try self.stack.append(self.alloc, out);
        return valueType(out);
    }

    pub fn settable(self: *State, idx: i32) ApiError!void {
        if (self.stack.items.len < 2) return error.InvalidState;
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        const value = self.stack.items[self.stack.items.len - 1];
        const key = self.stack.items[self.stack.items.len - 2];
        const object = self.stack.items[abs];
        self.vm.apiSetTable(object, key, value) catch return mapVmError();
        self.stack.items.len -= 2;
    }

    pub fn getfield(self: *State, idx: i32, key: []const u8) ApiError!Type {
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        const object = self.stack.items[abs];
        const out = self.vm.apiGetTable(object, .{ .String = try self.vm.internStr(key) }) catch return mapVmError();
        try self.stack.append(self.alloc, out);
        return valueType(out);
    }

    pub fn setfield(self: *State, idx: i32, key: []const u8) ApiError!void {
        if (self.stack.items.len == 0) return error.InvalidState;
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        const object = self.stack.items[abs];
        const value = self.stack.items[self.stack.items.len - 1];
        self.vm.apiSetTable(object, .{ .String = try self.vm.internStr(key) }, value) catch return mapVmError();
        self.stack.items.len -= 1;
    }

    pub fn geti(self: *State, idx: i32, n: i64) ApiError!Type {
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        const object = self.stack.items[abs];
        const out = self.vm.apiGetTable(object, .{ .Int = n }) catch return mapVmError();
        try self.stack.append(self.alloc, out);
        return valueType(out);
    }

    pub fn seti(self: *State, idx: i32, n: i64) ApiError!void {
        if (self.stack.items.len == 0) return error.InvalidState;
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        const object = self.stack.items[abs];
        const value = self.stack.items[self.stack.items.len - 1];
        self.vm.apiSetTable(object, .{ .Int = n }, value) catch return mapVmError();
        self.stack.items.len -= 1;
    }

    pub fn rawget(self: *State, idx: i32) ApiError!Type {
        if (self.stack.items.len == 0) return error.InvalidState;
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        const tbl = switch (self.stack.items[abs]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const key = self.stack.items[self.stack.items.len - 1];
        const out = self.vm.apiRawGet(tbl, key) catch return mapVmError();
        self.stack.items.len -= 1;
        try self.stack.append(self.alloc, out);
        return valueType(out);
    }

    pub fn rawset(self: *State, idx: i32) ApiError!void {
        if (self.stack.items.len < 2) return error.InvalidState;
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        const tbl = switch (self.stack.items[abs]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const value = self.stack.items[self.stack.items.len - 1];
        const key = self.stack.items[self.stack.items.len - 2];
        self.vm.apiRawSet(tbl, key, value) catch return mapVmError();
        self.stack.items.len -= 2;
    }

    pub fn rawgeti(self: *State, idx: i32, n: i64) ApiError!Type {
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        const tbl = switch (self.stack.items[abs]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const out = self.vm.apiRawGet(tbl, .{ .Int = n }) catch return mapVmError();
        try self.stack.append(self.alloc, out);
        return valueType(out);
    }

    pub fn rawseti(self: *State, idx: i32, n: i64) ApiError!void {
        if (self.stack.items.len == 0) return error.InvalidState;
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        const tbl = switch (self.stack.items[abs]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const value = self.stack.items[self.stack.items.len - 1];
        self.vm.apiRawSet(tbl, .{ .Int = n }, value) catch return mapVmError();
        self.stack.items.len -= 1;
    }

    pub fn next(self: *State, idx: i32) ApiError!bool {
        if (self.stack.items.len == 0) return error.InvalidState;
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        const tbl = switch (self.stack.items[abs]) {
            .Table => |t| t,
            else => return error.Type,
        };
        const key = self.stack.items[self.stack.items.len - 1];
        var out: [2]vm_mod.Value = .{ .Nil, .Nil };
        const produced = self.vm.apiNext(tbl, key, out[0..]) catch return mapVmError();
        self.stack.items.len -= 1;
        if (produced == 0) return false;
        try self.stack.appendSlice(self.alloc, out[0..2]);
        return true;
    }

    pub fn loadbuffer(self: *State, chunk: []const u8, chunk_name: []const u8) Status {
        const compiled = self.compileChunk(chunk, chunk_name) catch |e| return mapCompileError(e);
        self.stack.append(self.alloc, compiled) catch return .memory_error;
        return .ok;
    }

    pub fn loadfile(self: *State, path: []const u8) Status {
        const source = source_mod.Source.loadFile(self.alloc, stdio.activeIo(), path) catch return .memory_error;
        defer self.alloc.free(source.name);
        defer self.alloc.free(source.bytes);
        return self.loadbuffer(source.bytes, source.name);
    }

    pub fn pcall(self: *State, nargs: usize, nresults: i32) Status {
        if (self.stack.items.len < nargs + 1) return .runtime_error;
        const fn_idx = self.stack.items.len - nargs - 1;
        const callee = self.stack.items[fn_idx];
        const args = self.stack.items[fn_idx + 1 ..];
        const ret = self.vm.apiCall(callee, args) catch return .runtime_error;
        defer self.alloc.free(ret);

        self.stack.items.len = fn_idx;
        const want: usize = if (nresults < 0)
            ret.len
        else
            @min(ret.len, @as(usize, @intCast(nresults)));
        self.stack.appendSlice(self.alloc, ret[0..want]) catch return .memory_error;
        return .ok;
    }

    pub fn getmetatable(self: *State, idx: i32) ApiError!bool {
        const v = self.valueAtConst(idx) orelse return error.InvalidIndex;
        var args = [_]vm_mod.Value{v.*};
        const ret = self.callGlobal("getmetatable", args[0..]) catch return error.Runtime;
        defer self.alloc.free(ret);
        if (ret.len == 0 or ret[0] == .Nil) return false;
        try self.stack.append(self.alloc, ret[0]);
        return true;
    }

    pub fn setmetatable(self: *State, idx: i32) ApiError!void {
        if (self.stack.items.len == 0) return error.InvalidState;
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        const object = self.stack.items[abs];
        const mt = self.stack.items[self.stack.items.len - 1];
        var args = [_]vm_mod.Value{ object, mt };
        const ret = self.callGlobal("setmetatable", args[0..]) catch return error.Runtime;
        self.alloc.free(ret);
        self.stack.items.len -= 1;
    }

    pub fn getregistry(self: *State) ApiError!void {
        const dbg = try self.requireDebugModule();
        const f = self.vm.apiGetTable(dbg, .{ .String = try self.vm.internStr("getregistry") }) catch return error.Runtime;
        const ret = self.vm.apiCall(f, &.{}) catch return error.Runtime;
        defer self.alloc.free(ret);
        if (ret.len == 0) return error.Runtime;
        try self.stack.append(self.alloc, ret[0]);
    }

    pub fn getupvalue(self: *State, func_idx: i32, n: usize) ApiError!?[]const u8 {
        const fv = self.valueAtConst(func_idx) orelse return error.InvalidIndex;
        const dbg = try self.requireDebugModule();
        const f = self.vm.apiGetTable(dbg, .{ .String = try self.vm.internStr("getupvalue") }) catch return error.Runtime;
        var args = [_]vm_mod.Value{ fv.*, .{ .Int = @intCast(n) } };
        const ret = self.vm.apiCall(f, args[0..]) catch return error.Runtime;
        defer self.alloc.free(ret);
        if (ret.len == 0 or ret[0] == .Nil) return null;
        if (ret[0] != .String) return error.Type;
        if (ret.len > 1) try self.stack.append(self.alloc, ret[1]);
        return ret[0].String.bytes();
    }

    pub fn setupvalue(self: *State, func_idx: i32, n: usize) ApiError!?[]const u8 {
        if (self.stack.items.len == 0) return error.InvalidState;
        const fv = self.valueAtConst(func_idx) orelse return error.InvalidIndex;
        const set_val = self.stack.items[self.stack.items.len - 1];
        const dbg = try self.requireDebugModule();
        const f = self.vm.apiGetTable(dbg, .{ .String = try self.vm.internStr("setupvalue") }) catch return error.Runtime;
        var args = [_]vm_mod.Value{ fv.*, .{ .Int = @intCast(n) }, set_val };
        const ret = self.vm.apiCall(f, args[0..]) catch return error.Runtime;
        defer self.alloc.free(ret);
        self.stack.items.len -= 1;
        if (ret.len == 0 or ret[0] == .Nil) return null;
        if (ret[0] != .String) return error.Type;
        return ret[0].String.bytes();
    }

    fn compileChunk(self: *State, bytes: []const u8, chunk_name: []const u8) !vm_mod.Value {
        const src: source_mod.Source = .{ .name = chunk_name, .bytes = bytes };
        var lex = lexer.Lexer.init(src);
        var p = parser.Parser.init(&lex) catch return error.Syntax;

        var arena = ast.AstArena.init(self.alloc);
        defer arena.deinit();
        const chunk = p.parseChunkAst(&arena) catch return error.Syntax;

        var cg_bc = codegen_bc.Codegen.init(self.alloc, src.name, src.bytes);
        defer cg_bc.deinit();
        const proto = cg_bc.compileChunk(chunk) catch return error.Syntax;
        return self.vm.createBytecodeChunkClosure(proto);
    }

    fn valueAtConst(self: *const State, idx: i32) ?*const vm_mod.Value {
        const abs = self.normalizeIndexConst(idx, self.stack.items.len) orelse return null;
        return &self.stack.items[abs];
    }

    fn threadAt(self: *const State, idx: i32) ?*vm_mod.Thread {
        const v = self.valueAtConst(idx) orelse return null;
        return switch (v.*) {
            .Thread => |th| th,
            else => null,
        };
    }

    fn threadStack(self: *State, th: *vm_mod.Thread) ApiError!*std.ArrayListUnmanaged(vm_mod.Value) {
        const gop = try self.thread_stacks.getOrPut(self.alloc, th);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        return gop.value_ptr;
    }

    fn apiStackFor(self: *State, thread_idx: ?i32) ApiError!*std.ArrayListUnmanaged(vm_mod.Value) {
        if (thread_idx) |idx| {
            const th = self.threadAt(idx) orelse return error.Type;
            return try self.threadStack(th);
        }
        return &self.stack;
    }

    fn normalizeIndexConst(_: *const State, idx: i32, top: usize) ?usize {
        if (idx == 0) return null;
        if (idx > 0) {
            const abs: usize = @intCast(idx - 1);
            return if (abs < top) abs else null;
        }
        const r: usize = @intCast(-idx);
        if (r == 0 or r > top) return null;
        return top - r;
    }

    fn callGlobal(self: *State, name: []const u8, args: []const vm_mod.Value) ![]vm_mod.Value {
        const callee = self.vm.apiGetGlobal(name);
        return self.vm.apiCall(callee, args);
    }

    fn requireDebugModule(self: *State) ApiError!vm_mod.Value {
        var args = [_]vm_mod.Value{.{ .String = try self.vm.internStr("debug") }};
        const ret = self.callGlobal("require", args[0..]) catch return error.Runtime;
        defer self.alloc.free(ret);
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

fn valueType(v: vm_mod.Value) Type {
    if (v == .Table and isFileUserdata(v.Table)) return .userdata;
    return switch (v) {
        .Nil => .nil,
        .Bool => .boolean,
        .Int, .Num => .number,
        .String => .string,
        .Table => .table,
        .Builtin, .Closure => .function,
        .Thread => .thread,
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

fn mapCompileError(err_val: anyerror) Status {
    return switch (err_val) {
        error.Syntax => .syntax_error,
        error.OutOfMemory => .memory_error,
        else => .runtime_error,
    };
}

test "api state lifecycle" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();
    try std.testing.expectEqual(@as(usize, 0), st.gettop());
}

test "api index normalization contract" {
    var st = State.init(.{ .allocator = std.heap.c_allocator });
    defer st.deinit();

    try std.testing.expectEqual(@as(usize, 0), try st.normalizeIndex(1, 3));
    try std.testing.expectEqual(@as(usize, 2), try st.normalizeIndex(-1, 3));
    try std.testing.expectError(error.InvalidIndex, st.normalizeIndex(0, 3));
    try std.testing.expectError(error.InvalidIndex, st.normalizeIndex(4, 3));
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
