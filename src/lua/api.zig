const std = @import("std");

const ast = @import("ast.zig");
const codegen = @import("codegen.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const source_mod = @import("source.zig");
const vm_mod = @import("vm.zig");

pub const ApiError = error{
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
    stack: std.ArrayListUnmanaged(vm_mod.Value) = .{},

    pub fn init(opts: Options) State {
        return .{
            .vm = vm_mod.Vm.init(opts.allocator),
            .alloc = opts.allocator,
        };
    }

    pub fn deinit(self: *State) void {
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
        try self.stack.append(self.alloc, .{ .String = s });
    }

    pub fn pushvalue(self: *State, idx: i32) ApiError!void {
        const abs = try self.normalizeIndex(idx, self.stack.items.len);
        try self.stack.append(self.alloc, self.stack.items[abs]);
    }

    pub fn typeOf(self: *const State, idx: i32) ?Type {
        const abs = self.normalizeIndexConst(idx, self.stack.items.len) orelse return null;
        return valueType(self.stack.items[abs]);
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
            .String => |s| s,
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

    pub fn loadbuffer(self: *State, chunk: []const u8, chunk_name: []const u8) Status {
        const compiled = self.compileChunk(chunk, chunk_name) catch |e| return mapCompileError(e);
        self.stack.append(self.alloc, compiled) catch return .memory_error;
        return .ok;
    }

    pub fn loadfile(self: *State, path: []const u8) Status {
        const source = source_mod.Source.loadFile(self.alloc, path) catch return .memory_error;
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

    fn compileChunk(self: *State, bytes: []const u8, chunk_name: []const u8) !vm_mod.Value {
        const src: source_mod.Source = .{ .name = chunk_name, .bytes = bytes };
        var lex = lexer.Lexer.init(src);
        var p = parser.Parser.init(&lex) catch return error.Syntax;

        var arena = ast.AstArena.init(self.alloc);
        defer arena.deinit();
        const chunk = p.parseChunkAst(&arena) catch return error.Syntax;

        var cg = codegen.Codegen.init(self.alloc, src.name, src.bytes);
        const f = cg.compileChunk(chunk) catch return error.Syntax;
        return self.vm.apiWrapFunction(f);
    }

    fn valueAtConst(self: *const State, idx: i32) ?*const vm_mod.Value {
        const abs = self.normalizeIndexConst(idx, self.stack.items.len) orelse return null;
        return &self.stack.items[abs];
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
};

fn valueType(v: vm_mod.Value) Type {
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
    var st = State.init(.{ .allocator = std.testing.allocator });
    defer st.deinit();
    try std.testing.expectEqual(@as(usize, 0), st.gettop());
}

test "api index normalization contract" {
    var st = State.init(.{ .allocator = std.testing.allocator });
    defer st.deinit();

    try std.testing.expectEqual(@as(usize, 0), try st.normalizeIndex(1, 3));
    try std.testing.expectEqual(@as(usize, 2), try st.normalizeIndex(-1, 3));
    try std.testing.expectError(error.InvalidIndex, st.normalizeIndex(0, 3));
    try std.testing.expectError(error.InvalidIndex, st.normalizeIndex(4, 3));
}

test "api stack push/pop and settop" {
    var st = State.init(.{ .allocator = std.testing.allocator });
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

test "api loadbuffer and pcall" {
    var st = State.init(.{ .allocator = std.testing.allocator });
    defer st.deinit();

    const status_load = st.loadbuffer("return 7, 8", "=api-test");
    try std.testing.expectEqual(Status.ok, status_load);
    const status_call = st.pcall(0, -1);
    try std.testing.expectEqual(Status.ok, status_call);
    try std.testing.expectEqual(@as(usize, 2), st.gettop());
    try std.testing.expectEqual(@as(i64, 7), st.tointeger(1).?);
    try std.testing.expectEqual(@as(i64, 8), st.tointeger(2).?);
}
