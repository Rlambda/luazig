const std = @import("std");

const ir = @import("ir.zig");
const TokenKind = @import("token.zig").TokenKind;
const stdio = @import("util").stdio;

pub const BuiltinId = enum {
    print,
    tostring,
    @"error",

    pub fn name(self: BuiltinId) []const u8 {
        return switch (self) {
            .print => "print",
            .tostring => "tostring",
            .@"error" => "error",
        };
    }
};

pub const Cell = struct {
    value: Value,
};

pub const Closure = struct {
    func: *const ir.Function,
    upvalues: []const *Cell,
};

pub const Value = union(enum) {
    Nil,
    Bool: bool,
    Int: i64,
    Num: f64,
    String: []const u8,
    Table: *Table,
    Builtin: BuiltinId,
    Closure: *Closure,

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .Nil => "nil",
            .Bool => "boolean",
            .Int, .Num => "number",
            .String => "string",
            .Table => "table",
            .Builtin, .Closure => "function",
        };
    }
};

pub const Table = struct {
    array: std.ArrayListUnmanaged(Value) = .{},
    fields: std.StringHashMapUnmanaged(Value) = .{},
    int_keys: std.AutoHashMapUnmanaged(i64, Value) = .{},

    pub fn deinit(self: *Table, alloc: std.mem.Allocator) void {
        self.array.deinit(alloc);
        self.fields.deinit(alloc);
        self.int_keys.deinit(alloc);
    }
};

pub const Vm = struct {
    alloc: std.mem.Allocator,
    globals: std.StringHashMapUnmanaged(Value) = .{},

    err: ?[]const u8 = null,
    err_buf: [256]u8 = undefined,

    pub const Error = std.mem.Allocator.Error || error{RuntimeError};

    pub fn init(alloc: std.mem.Allocator) Vm {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Vm) void {
        self.globals.deinit(self.alloc);
    }

    pub fn errorString(self: *Vm) []const u8 {
        return self.err orelse "runtime error";
    }

    fn fail(self: *Vm, comptime fmt: []const u8, args: anytype) Error {
        self.err = std.fmt.bufPrint(self.err_buf[0..], fmt, args) catch "runtime error";
        return error.RuntimeError;
    }

    pub fn runFunction(self: *Vm, f: *const ir.Function) Error![]Value {
        return self.runFunctionArgsWithUpvalues(f, &.{}, &.{});
    }

    pub fn runFunctionArgs(self: *Vm, f: *const ir.Function, args: []const Value) Error![]Value {
        return self.runFunctionArgsWithUpvalues(f, &.{}, args);
    }

    fn runFunctionArgsWithUpvalues(self: *Vm, f: *const ir.Function, upvalues: []const *Cell, args: []const Value) Error![]Value {
        const nilv: Value = .Nil;
        const regs = try self.alloc.alloc(Value, f.num_values);
        defer self.alloc.free(regs);
        for (regs) |*r| r.* = nilv;

        const locals = try self.alloc.alloc(Value, @as(usize, @intCast(f.num_locals)));
        defer self.alloc.free(locals);
        for (locals) |*l| l.* = nilv;

        const boxed = try self.alloc.alloc(?*Cell, @as(usize, @intCast(f.num_locals)));
        defer self.alloc.free(boxed);
        for (boxed) |*b| b.* = null;

        // Fill parameter locals. Missing args become nil, extra args ignored.
        const nparams: usize = @intCast(f.num_params);
        var pi: usize = 0;
        while (pi < nparams) : (pi += 1) {
            locals[pi] = if (pi < args.len) args[pi] else .Nil;
        }

        var labels = std.AutoHashMapUnmanaged(ir.LabelId, usize){};
        defer labels.deinit(self.alloc);
        for (f.insts, 0..) |inst, idx| {
            switch (inst) {
                .Label => |l| try labels.put(self.alloc, l.id, idx),
                else => {},
            }
        }

        var pc: usize = 0;
        while (pc < f.insts.len) {
            const inst = f.insts[pc];
            switch (inst) {
                .ConstNil => |n| regs[n.dst] = .Nil,
                .ConstBool => |b| regs[b.dst] = .{ .Bool = b.val },
                .ConstInt => |n| regs[n.dst] = .{ .Int = try self.parseInt(n.lexeme) },
                .ConstNum => |n| regs[n.dst] = .{ .Num = try self.parseNum(n.lexeme) },
                .ConstString => |s| regs[s.dst] = .{ .String = try self.decodeStringLexeme(s.lexeme) },
                .ConstFunc => |cf| regs[cf.dst] = .{ .Closure = try self.makeClosure(cf.func, locals, boxed, upvalues) },

                .GetName => |g| regs[g.dst] = self.getGlobal(g.name),
                .SetName => |s| try self.setGlobal(s.name, regs[s.src]),
                .GetLocal => |g| {
                    const idx: usize = @intCast(g.local);
                    regs[g.dst] = if (boxed[idx]) |cell| cell.value else locals[idx];
                },
                .SetLocal => |s| {
                    const idx: usize = @intCast(s.local);
                    if (boxed[idx]) |cell| {
                        cell.value = regs[s.src];
                    } else {
                        locals[idx] = regs[s.src];
                    }
                },
                .GetUpvalue => |g| {
                    const idx: usize = @intCast(g.upvalue);
                    if (idx >= upvalues.len) return self.fail("invalid upvalue index u{d}", .{g.upvalue});
                    regs[g.dst] = upvalues[idx].value;
                },
                .SetUpvalue => |s| {
                    const idx: usize = @intCast(s.upvalue);
                    if (idx >= upvalues.len) return self.fail("invalid upvalue index u{d}", .{s.upvalue});
                    upvalues[idx].value = regs[s.src];
                },

                .UnOp => |u| regs[u.dst] = try self.evalUnOp(u.op, regs[u.src]),
                .BinOp => |b| regs[b.dst] = try self.evalBinOp(b.op, regs[b.lhs], regs[b.rhs]),

                .Label => {},
                .Jump => |j| {
                    pc = labels.get(j.target) orelse return self.fail("unknown label L{d}", .{j.target});
                    continue;
                },
                .JumpIfFalse => |j| {
                    if (!isTruthy(regs[j.cond])) {
                        pc = labels.get(j.target) orelse return self.fail("unknown label L{d}", .{j.target});
                        continue;
                    }
                },

                .NewTable => |t| {
                    const tbl = try self.alloc.create(Table);
                    tbl.* = .{};
                    regs[t.dst] = .{ .Table = tbl };
                },
                .SetField => |s| {
                    const tbl = try self.expectTable(regs[s.object]);
                    try tbl.fields.put(self.alloc, s.name, regs[s.value]);
                },
                .SetIndex => |s| {
                    const tbl = try self.expectTable(regs[s.object]);
                    const key = regs[s.key];
                    const val = regs[s.value];
                    switch (key) {
                        .Int => |k| {
                            if (k >= 1 and k <= @as(i64, @intCast(tbl.array.items.len))) {
                                const idx: usize = @intCast(k - 1);
                                tbl.array.items[idx] = val;
                            } else {
                                try tbl.int_keys.put(self.alloc, k, val);
                            }
                        },
                        .String => |k| {
                            try tbl.fields.put(self.alloc, k, val);
                        },
                        else => return self.fail("unsupported table key type: {s}", .{key.typeName()}),
                    }
                },
                .Append => |a| {
                    const tbl = try self.expectTable(regs[a.object]);
                    try tbl.array.append(self.alloc, regs[a.value]);
                },
                .GetField => |g| {
                    const tbl = try self.expectTable(regs[g.object]);
                    regs[g.dst] = tbl.fields.get(g.name) orelse .Nil;
                },
                .GetIndex => |g| {
                    const tbl = try self.expectTable(regs[g.object]);
                    const key = regs[g.key];
                    regs[g.dst] = switch (key) {
                        .Int => |k| blk: {
                            if (k >= 1 and k <= @as(i64, @intCast(tbl.array.items.len))) {
                                const idx: usize = @intCast(k - 1);
                                break :blk tbl.array.items[idx];
                            }
                            break :blk tbl.int_keys.get(k) orelse .Nil;
                        },
                        .String => |k| tbl.fields.get(k) orelse .Nil,
                        else => return self.fail("unsupported table key type: {s}", .{key.typeName()}),
                    };
                },

                .Call => |c| {
                    const callee = regs[c.func];
                    const call_args = try self.alloc.alloc(Value, c.args.len);
                    defer self.alloc.free(call_args);
                    for (c.args, 0..) |id, k| call_args[k] = regs[id];

                    var outs_small: [8]Value = undefined;
                    var outs: []Value = undefined;
                    var outs_heap = false;
                    if (c.dsts.len <= outs_small.len) {
                        outs = outs_small[0..c.dsts.len];
                    } else {
                        outs = try self.alloc.alloc(Value, c.dsts.len);
                        outs_heap = true;
                    }
                    defer if (outs_heap) self.alloc.free(outs);
                    for (outs) |*o| o.* = .Nil;

                    switch (callee) {
                        .Builtin => |id| try self.callBuiltin(id, call_args, outs),
                        .Closure => |cl| {
                            const ret = try self.runFunctionArgsWithUpvalues(cl.func, cl.upvalues, call_args);
                            defer self.alloc.free(ret);
                            const n = @min(outs.len, ret.len);
                            for (0..n) |idx| outs[idx] = ret[idx];
                        },
                        else => return self.fail("attempt to call a {s} value", .{callee.typeName()}),
                    }

                    for (c.dsts, 0..) |dst, idx| regs[dst] = outs[idx];
                },

                .Return => |r| {
                    const out = try self.alloc.alloc(Value, r.values.len);
                    for (r.values, 0..) |vid, i| out[i] = regs[vid];
                    return out;
                },

                .ReturnCall => |r| {
                    const callee = regs[r.func];
                    const call_args = try self.alloc.alloc(Value, r.args.len);
                    defer self.alloc.free(call_args);
                    for (r.args, 0..) |id, k| call_args[k] = regs[id];

                    switch (callee) {
                        .Builtin => |id| {
                            const out_len: usize = switch (id) {
                                .tostring => 1,
                                else => 0,
                            };
                            const outs = try self.alloc.alloc(Value, out_len);
                            errdefer self.alloc.free(outs);
                            try self.callBuiltin(id, call_args, outs);
                            return outs;
                        },
                        .Closure => |cl| return try self.runFunctionArgsWithUpvalues(cl.func, cl.upvalues, call_args),
                        else => return self.fail("attempt to call a {s} value", .{callee.typeName()}),
                    }
                },
            }
            pc += 1;
        }

        // Should not happen: codegen always ensures a terminating `Return`.
        return self.alloc.alloc(Value, 0);
    }

    fn decodeStringLexeme(self: *Vm, lexeme: []const u8) Error![]const u8 {
        if (lexeme.len < 2) return lexeme;
        const q = lexeme[0];
        if (!((q == '"' or q == '\'') and lexeme[lexeme.len - 1] == q)) return lexeme;

        const inner = lexeme[1 .. lexeme.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;

        var out = std.ArrayListUnmanaged(u8){};
        var i: usize = 0;
        while (i < inner.len) {
            const c = inner[i];
            if (c != '\\') {
                try out.append(self.alloc, c);
                i += 1;
                continue;
            }

            i += 1;
            if (i >= inner.len) return self.fail("unfinished string escape", .{});
            const e = inner[i];

            switch (e) {
                'a' => {
                    try out.append(self.alloc, 0x07);
                    i += 1;
                },
                'b' => {
                    try out.append(self.alloc, 0x08);
                    i += 1;
                },
                'f' => {
                    try out.append(self.alloc, 0x0c);
                    i += 1;
                },
                'n' => {
                    try out.append(self.alloc, '\n');
                    i += 1;
                },
                'r' => {
                    try out.append(self.alloc, '\r');
                    i += 1;
                },
                't' => {
                    try out.append(self.alloc, '\t');
                    i += 1;
                },
                'v' => {
                    try out.append(self.alloc, 0x0b);
                    i += 1;
                },
                '\\' => {
                    try out.append(self.alloc, '\\');
                    i += 1;
                },
                '"' => {
                    try out.append(self.alloc, '"');
                    i += 1;
                },
                '\'' => {
                    try out.append(self.alloc, '\'');
                    i += 1;
                },
                'z' => {
                    i += 1;
                    while (i < inner.len) {
                        const ws = inner[i];
                        if (ws == ' ' or ws == '\t' or ws == 0x0b or ws == 0x0c) {
                            i += 1;
                            continue;
                        }
                        if (ws == '\n' or ws == '\r') {
                            i += 1;
                            if (i < inner.len) {
                                const nxt = inner[i];
                                if ((ws == '\n' and nxt == '\r') or (ws == '\r' and nxt == '\n')) i += 1;
                            }
                            continue;
                        }
                        break;
                    }
                },
                'x' => {
                    if (i + 2 >= inner.len) return self.fail("invalid hex escape", .{});
                    const h1 = hexVal(inner[i + 1]) orelse return self.fail("invalid hex escape", .{});
                    const h2 = hexVal(inner[i + 2]) orelse return self.fail("invalid hex escape", .{});
                    try out.append(self.alloc, (h1 << 4) | h2);
                    i += 3;
                },
                'u' => {
                    if (i + 1 >= inner.len or inner[i + 1] != '{') return self.fail("invalid unicode escape", .{});
                    i += 2; // skip 'u' '{'
                    if (i >= inner.len) return self.fail("invalid unicode escape", .{});
                    var codepoint: u32 = 0;
                    var digits: usize = 0;
                    while (i < inner.len and inner[i] != '}') : (i += 1) {
                        const hv = hexVal(inner[i]) orelse return self.fail("invalid unicode escape", .{});
                        codepoint = (codepoint << 4) | hv;
                        digits += 1;
                        if (digits > 8) return self.fail("invalid unicode escape", .{});
                    }
                    if (i >= inner.len or inner[i] != '}' or digits == 0) return self.fail("invalid unicode escape", .{});
                    i += 1; // skip '}'
                    var buf: [4]u8 = undefined;
                    const nbytes = std.unicode.utf8Encode(@as(u21, @intCast(codepoint)), buf[0..]) catch return self.fail("invalid unicode escape", .{});
                    try out.appendSlice(self.alloc, buf[0..nbytes]);
                },
                '\n' => {
                    try out.append(self.alloc, '\n');
                    i += 1;
                },
                '\r' => {
                    try out.append(self.alloc, '\n');
                    i += 1;
                    if (i < inner.len and inner[i] == '\n') i += 1;
                },
                else => {
                    if (e >= '0' and e <= '9') {
                        var val: u32 = 0;
                        var count: usize = 0;
                        while (i < inner.len and count < 3) : (count += 1) {
                            const d = inner[i];
                            if (!(d >= '0' and d <= '9')) break;
                            val = (val * 10) + @as(u32, d - '0');
                            i += 1;
                        }
                        if (val > 255) return self.fail("decimal escape out of range", .{});
                        try out.append(self.alloc, @as(u8, @intCast(val)));
                    } else {
                        try out.append(self.alloc, e);
                        i += 1;
                    }
                },
            }
        }
        return try out.toOwnedSlice(self.alloc);
    }

    fn hexVal(c: u8) ?u8 {
        if (c >= '0' and c <= '9') return c - '0';
        if (c >= 'a' and c <= 'f') return 10 + (c - 'a');
        if (c >= 'A' and c <= 'F') return 10 + (c - 'A');
        return null;
    }

    fn expectTable(self: *Vm, v: Value) Error!*Table {
        return switch (v) {
            .Table => |t| t,
            else => self.fail("type error: expected table, got {s}", .{v.typeName()}),
        };
    }

    fn getGlobal(self: *Vm, name: []const u8) Value {
        if (self.globals.get(name)) |v| return v;
        if (std.mem.eql(u8, name, "print")) return .{ .Builtin = .print };
        if (std.mem.eql(u8, name, "tostring")) return .{ .Builtin = .tostring };
        if (std.mem.eql(u8, name, "error")) return .{ .Builtin = .@"error" };
        if (std.mem.eql(u8, name, "_VERSION")) return .{ .String = "Lua 5.5" };
        return .Nil;
    }

    fn setGlobal(self: *Vm, name: []const u8, v: Value) std.mem.Allocator.Error!void {
        // `name` is borrowed from source bytes. If we later need globals to
        // outlive the source, we should intern/dupe keys.
        try self.globals.put(self.alloc, name, v);
    }

    fn callBuiltin(self: *Vm, id: BuiltinId, args: []const Value, outs: []Value) Error!void {
        // Initialize outputs to nil.
        for (outs) |*o| o.* = .Nil;
        switch (id) {
            .print => try self.builtinPrint(args),
            .tostring => {
                if (outs.len == 0) return;
                outs[0] = .{ .String = try self.valueToStringAlloc(if (args.len > 0) args[0] else .Nil) };
            },
            .@"error" => {
                const msg = try self.valueToStringAlloc(if (args.len > 0) args[0] else .Nil);
                self.err = msg;
                return error.RuntimeError;
            },
        }
    }

    fn builtinPrint(self: *Vm, args: []const Value) Error!void {
        var out = stdio.stdout();
        for (args, 0..) |v, i| {
            if (i != 0) out.writeByte('\t') catch |e| switch (e) {
                error.BrokenPipe => return,
                else => return self.fail("stdout write error: {s}", .{@errorName(e)}),
            };
            self.writeValue(&out, v) catch |e| switch (e) {
                error.BrokenPipe => return,
                else => return self.fail("stdout write error: {s}", .{@errorName(e)}),
            };
        }
        out.writeByte('\n') catch |e| switch (e) {
            error.BrokenPipe => return,
            else => return self.fail("stdout write error: {s}", .{@errorName(e)}),
        };
    }

    fn writeValue(self: *Vm, w: anytype, v: Value) anyerror!void {
        _ = self;
        switch (v) {
            .Nil => try w.writeAll("nil"),
            .Bool => |b| try w.writeAll(if (b) "true" else "false"),
            .Int => |i| try w.print("{d}", .{i}),
            .Num => |n| try w.print("{}", .{n}),
            .String => |s| try w.writeAll(s),
            .Table => |t| try w.print("table: 0x{x}", .{@intFromPtr(t)}),
            .Builtin => |id| try w.print("function: builtin {s}", .{id.name()}),
            .Closure => |cl| try w.print("function: {s}", .{cl.func.name}),
        }
    }

    fn valueToStringAlloc(self: *Vm, v: Value) Error![]const u8 {
        return switch (v) {
            .Nil => "nil",
            .Bool => |b| if (b) "true" else "false",
            .Int => |i| try std.fmt.allocPrint(self.alloc, "{d}", .{i}),
            .Num => |n| try std.fmt.allocPrint(self.alloc, "{}", .{n}),
            .String => |s| s,
            .Table => |t| try std.fmt.allocPrint(self.alloc, "table: 0x{x}", .{@intFromPtr(t)}),
            .Builtin => |id| try std.fmt.allocPrint(self.alloc, "function: builtin {s}", .{id.name()}),
            .Closure => |cl| try std.fmt.allocPrint(self.alloc, "function: {s}", .{cl.func.name}),
        };
    }

    fn parseInt(self: *Vm, lexeme: []const u8) Error!i64 {
        var s = lexeme;
        var base: u8 = 10;
        if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
            base = 16;
            s = s[2..];
        }
        const v = std.fmt.parseInt(i64, s, base) catch |e| switch (e) {
            error.InvalidCharacter => return self.fail("invalid integer literal: {s}", .{lexeme}),
            error.Overflow => return self.fail("integer literal overflow: {s}", .{lexeme}),
        };
        return v;
    }

    fn parseNum(self: *Vm, lexeme: []const u8) Error!f64 {
        const v = std.fmt.parseFloat(f64, lexeme) catch return self.fail("invalid number literal: {s}", .{lexeme});
        return v;
    }

    fn isTruthy(v: Value) bool {
        return switch (v) {
            .Nil => false,
            .Bool => |b| b,
            else => true,
        };
    }

    fn evalUnOp(self: *Vm, op: TokenKind, src: Value) Error!Value {
        switch (op) {
            .Not => return .{ .Bool = !isTruthy(src) },
            .Minus => return switch (src) {
                .Int => |i| .{ .Int = -%i },
                .Num => |n| .{ .Num = -n },
                else => self.fail("type error: unary '-' expects number, got {s}", .{src.typeName()}),
            },
            else => return self.fail("unsupported unary operator: {s}", .{op.name()}),
        }
    }

    fn evalBinOp(self: *Vm, op: TokenKind, lhs: Value, rhs: Value) Error!Value {
        switch (op) {
            .Plus => return self.binAdd(lhs, rhs),
            .Minus => return self.binSub(lhs, rhs),
            .Star => return self.binMul(lhs, rhs),
            .Slash => return self.binDiv(lhs, rhs),
            .Idiv => return self.binIdiv(lhs, rhs),
            .Percent => return self.binMod(lhs, rhs),
            .Caret => return self.binPow(lhs, rhs),

            .EqEq => return .{ .Bool = valuesEqual(lhs, rhs) },
            .NotEq => return .{ .Bool = !valuesEqual(lhs, rhs) },
            .Lt => return .{ .Bool = try self.cmpLt(lhs, rhs) },
            .Lte => return .{ .Bool = try self.cmpLte(lhs, rhs) },
            .Gt => return .{ .Bool = try self.cmpGt(lhs, rhs) },
            .Gte => return .{ .Bool = try self.cmpGte(lhs, rhs) },

            .Concat => return self.binConcat(lhs, rhs),
            else => return self.fail("unsupported binary operator: {s}", .{op.name()}),
        }
    }

    fn valuesEqual(lhs: Value, rhs: Value) bool {
        return switch (lhs) {
            .Nil => rhs == .Nil,
            .Bool => |lb| switch (rhs) {
                .Bool => |rb| lb == rb,
                else => false,
            },
            .Int => |li| switch (rhs) {
                .Int => |ri| li == ri,
                .Num => |rn| @as(f64, @floatFromInt(li)) == rn,
                else => false,
            },
            .Num => |ln| switch (rhs) {
                .Int => |ri| ln == @as(f64, @floatFromInt(ri)),
                .Num => |rn| ln == rn,
                else => false,
            },
            .String => |ls| switch (rhs) {
                .String => |rs| std.mem.eql(u8, ls, rs),
                else => false,
            },
            .Table => |lt| switch (rhs) {
                .Table => |rt| lt == rt,
                else => false,
            },
            .Builtin => |lid| switch (rhs) {
                .Builtin => |rid| lid == rid,
                else => false,
            },
            .Closure => |lc| switch (rhs) {
                .Closure => |rc| lc == rc,
                else => false,
            },
        };
    }

    fn makeClosure(self: *Vm, func: *const ir.Function, locals: []Value, boxed: []?*Cell, upvalues: []const *Cell) Error!*Closure {
        const n: usize = @intCast(func.num_upvalues);
        if (func.captures.len != n) return self.fail("invalid closure metadata for function {s}", .{func.name});

        const cells = try self.alloc.alloc(*Cell, n);
        for (cells) |*c| c.* = undefined;

        for (func.captures, 0..) |cap, i| {
            cells[i] = switch (cap) {
                .Local => |local_id| blk: {
                    const idx: usize = @intCast(local_id);
                    if (idx >= locals.len) return self.fail("invalid capture local l{d}", .{local_id});
                    if (boxed[idx]) |cell| break :blk cell;
                    const cell = try self.alloc.create(Cell);
                    cell.* = .{ .value = locals[idx] };
                    boxed[idx] = cell;
                    break :blk cell;
                },
                .Upvalue => |up_id| blk: {
                    const idx: usize = @intCast(up_id);
                    if (idx >= upvalues.len) return self.fail("invalid capture upvalue u{d}", .{up_id});
                    break :blk upvalues[idx];
                },
            };
        }

        const cl = try self.alloc.create(Closure);
        cl.* = .{ .func = func, .upvalues = cells };
        return cl;
    }

    fn binAdd(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        return switch (lhs) {
            .Int => |li| switch (rhs) {
                .Int => |ri| .{ .Int = li +% ri },
                .Num => |rn| .{ .Num = @as(f64, @floatFromInt(li)) + rn },
                else => self.fail("type error: '+' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .Num => |ln| switch (rhs) {
                .Int => |ri| .{ .Num = ln + @as(f64, @floatFromInt(ri)) },
                .Num => |rn| .{ .Num = ln + rn },
                else => self.fail("type error: '+' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => self.fail("type error: '+' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn binSub(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        return switch (lhs) {
            .Int => |li| switch (rhs) {
                .Int => |ri| .{ .Int = li -% ri },
                .Num => |rn| .{ .Num = @as(f64, @floatFromInt(li)) - rn },
                else => self.fail("type error: '-' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .Num => |ln| switch (rhs) {
                .Int => |ri| .{ .Num = ln - @as(f64, @floatFromInt(ri)) },
                .Num => |rn| .{ .Num = ln - rn },
                else => self.fail("type error: '-' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => self.fail("type error: '-' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn binMul(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        return switch (lhs) {
            .Int => |li| switch (rhs) {
                .Int => |ri| .{ .Int = li *% ri },
                .Num => |rn| .{ .Num = @as(f64, @floatFromInt(li)) * rn },
                else => self.fail("type error: '*' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .Num => |ln| switch (rhs) {
                .Int => |ri| .{ .Num = ln * @as(f64, @floatFromInt(ri)) },
                .Num => |rn| .{ .Num = ln * rn },
                else => self.fail("type error: '*' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => self.fail("type error: '*' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn binDiv(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        const ln = switch (lhs) {
            .Int => |li| @as(f64, @floatFromInt(li)),
            .Num => |n| n,
            else => return self.fail("type error: '/' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
        const rn = switch (rhs) {
            .Int => |ri| @as(f64, @floatFromInt(ri)),
            .Num => |n| n,
            else => return self.fail("type error: '/' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
        if (rn == 0.0) return self.fail("division by zero", .{});
        return .{ .Num = ln / rn };
    }

    fn binIdiv(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        return switch (lhs) {
            .Int => |li| switch (rhs) {
                .Int => |ri| {
                    if (ri == 0) return self.fail("division by zero", .{});
                    return .{ .Int = @divFloor(li, ri) };
                },
                .Num => |rn| {
                    if (rn == 0.0) return self.fail("division by zero", .{});
                    return .{ .Num = std.math.floor(@as(f64, @floatFromInt(li)) / rn) };
                },
                else => self.fail("type error: '//' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .Num => |ln| switch (rhs) {
                .Int => |ri| {
                    if (ri == 0) return self.fail("division by zero", .{});
                    return .{ .Num = std.math.floor(ln / @as(f64, @floatFromInt(ri))) };
                },
                .Num => |rn| {
                    if (rn == 0.0) return self.fail("division by zero", .{});
                    return .{ .Num = std.math.floor(ln / rn) };
                },
                else => self.fail("type error: '//' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => self.fail("type error: '//' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn binMod(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        return switch (lhs) {
            .Int => |li| switch (rhs) {
                .Int => |ri| {
                    if (ri == 0) return self.fail("division by zero", .{});
                    return .{ .Int = @mod(li, ri) };
                },
                .Num => |rn| {
                    if (rn == 0.0) return self.fail("division by zero", .{});
                    const q = std.math.floor(@as(f64, @floatFromInt(li)) / rn);
                    return .{ .Num = @as(f64, @floatFromInt(li)) - (q * rn) };
                },
                else => self.fail("type error: '%' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .Num => |ln| switch (rhs) {
                .Int => |ri| {
                    if (ri == 0) return self.fail("division by zero", .{});
                    const rn = @as(f64, @floatFromInt(ri));
                    const q = std.math.floor(ln / rn);
                    return .{ .Num = ln - (q * rn) };
                },
                .Num => |rn| {
                    if (rn == 0.0) return self.fail("division by zero", .{});
                    const q = std.math.floor(ln / rn);
                    return .{ .Num = ln - (q * rn) };
                },
                else => self.fail("type error: '%' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => self.fail("type error: '%' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn binPow(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        const ln = switch (lhs) {
            .Int => |li| @as(f64, @floatFromInt(li)),
            .Num => |n| n,
            else => return self.fail("type error: '^' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
        const rn = switch (rhs) {
            .Int => |ri| @as(f64, @floatFromInt(ri)),
            .Num => |n| n,
            else => return self.fail("type error: '^' expects numbers, got {s} and {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
        return .{ .Num = std.math.pow(f64, ln, rn) };
    }

    fn cmpLt(self: *Vm, lhs: Value, rhs: Value) Error!bool {
        return switch (lhs) {
            .Int => |li| switch (rhs) {
                .Int => |ri| li < ri,
                .Num => |rn| @as(f64, @floatFromInt(li)) < rn,
                else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .Num => |ln| switch (rhs) {
                .Int => |ri| ln < @as(f64, @floatFromInt(ri)),
                .Num => |rn| ln < rn,
                else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .String => |ls| switch (rhs) {
                .String => |rs| std.mem.order(u8, ls, rs) == .lt,
                else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn cmpLte(self: *Vm, lhs: Value, rhs: Value) Error!bool {
        return switch (lhs) {
            .Int => |li| switch (rhs) {
                .Int => |ri| li <= ri,
                .Num => |rn| @as(f64, @floatFromInt(li)) <= rn,
                else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .Num => |ln| switch (rhs) {
                .Int => |ri| ln <= @as(f64, @floatFromInt(ri)),
                .Num => |rn| ln <= rn,
                else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .String => |ls| switch (rhs) {
                .String => |rs| {
                    const ord = std.mem.order(u8, ls, rs);
                    return ord == .lt or ord == .eq;
                },
                else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn cmpGt(self: *Vm, lhs: Value, rhs: Value) Error!bool {
        return switch (lhs) {
            .Int => |li| switch (rhs) {
                .Int => |ri| li > ri,
                .Num => |rn| @as(f64, @floatFromInt(li)) > rn,
                else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .Num => |ln| switch (rhs) {
                .Int => |ri| ln > @as(f64, @floatFromInt(ri)),
                .Num => |rn| ln > rn,
                else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .String => |ls| switch (rhs) {
                .String => |rs| std.mem.order(u8, ls, rs) == .gt,
                else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn cmpGte(self: *Vm, lhs: Value, rhs: Value) Error!bool {
        return switch (lhs) {
            .Int => |li| switch (rhs) {
                .Int => |ri| li >= ri,
                .Num => |rn| @as(f64, @floatFromInt(li)) >= rn,
                else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .Num => |ln| switch (rhs) {
                .Int => |ri| ln >= @as(f64, @floatFromInt(ri)),
                .Num => |rn| ln >= rn,
                else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            .String => |ls| switch (rhs) {
                .String => |rs| {
                    const ord = std.mem.order(u8, ls, rs);
                    return ord == .gt or ord == .eq;
                },
                else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
            },
            else => self.fail("attempt to compare {s} with {s}", .{ lhs.typeName(), rhs.typeName() }),
        };
    }

    fn concatOperandToString(self: *Vm, v: Value) Error![]const u8 {
        return switch (v) {
            .String => |s| s,
            .Int => |i| try std.fmt.allocPrint(self.alloc, "{d}", .{i}),
            .Num => |n| try std.fmt.allocPrint(self.alloc, "{}", .{n}),
            else => self.fail("attempt to concatenate a {s} value", .{v.typeName()}),
        };
    }

    fn binConcat(self: *Vm, lhs: Value, rhs: Value) Error!Value {
        const a = try self.concatOperandToString(lhs);
        const b = try self.concatOperandToString(rhs);
        const out = try self.alloc.alloc(u8, a.len + b.len);
        std.mem.copyForwards(u8, out[0..a.len], a);
        std.mem.copyForwards(u8, out[a.len..], b);
        return .{ .String = out };
    }
};

test "vm: run return 1+2" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "return 1 + 2\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
}

test "vm: table constructor and access" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "x = {a = 1, [2] = 3, 4}\n" ++
            "return x.a + x[2]\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 4), v),
        else => try testing.expect(false),
    }
}

test "vm: call tostring (one result)" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "return tostring(1 + 2)\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .String => |s| try testing.expectEqualStrings("3", s),
        else => try testing.expect(false),
    }
}

test "vm: if statement (NotEq) with _VERSION" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "local version = \"Lua 5.5\"\n" ++
            "if _VERSION ~= version then\n" ++
            "  return 1\n" ++
            "end\n" ++
            "return 2\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 2), v),
        else => try testing.expect(false),
    }
}

test "vm: string concat" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "return \"a\" .. \"b\" .. 1\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .String => |s| try testing.expectEqualStrings("ab1", s),
        else => try testing.expect(false),
    }
}

test "vm: locals swap uses temporaries" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "local a, b = 1, 2\n" ++
            "a, b = b, a\n" ++
            "return tostring(a) .. tostring(b)\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .String => |s| try testing.expectEqualStrings("21", s),
        else => try testing.expect(false),
    }
}

test "vm: local shadowing" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "local x = 1\n" ++
            "do\n" ++
            "  local x = 2\n" ++
            "end\n" ++
            "return x\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 1), v),
        else => try testing.expect(false),
    }
}

test "vm: local initializer sees outer binding" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "local x = 1\n" ++
            "do\n" ++
            "  local x = x + 1\n" ++
            "  return x\n" ++
            "end\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 2), v),
        else => try testing.expect(false),
    }
}

test "vm: while loop" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "local i = 3\n" ++
            "local sum = 0\n" ++
            "while i ~= 0 do\n" ++
            "  sum = sum + i\n" ++
            "  i = i + -1\n" ++
            "end\n" ++
            "return sum\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 6), v),
        else => try testing.expect(false),
    }
}

test "vm: while break" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "local i = 0\n" ++
            "while true do\n" ++
            "  i = i + 1\n" ++
            "  if i == 3 then\n" ++
            "    break\n" ++
            "  end\n" ++
            "end\n" ++
            "return i\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
}

test "vm: repeat until" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "local i = 0\n" ++
            "repeat\n" ++
            "  i = i + 1\n" ++
            "until i == 3\n" ++
            "return i\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
}

test "vm: repeat until condition sees locals from block" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "local out = 0\n" ++
            "repeat\n" ++
            "  local y = 1\n" ++
            "  out = y\n" ++
            "until y == 1\n" ++
            "return out\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 1), v),
        else => try testing.expect(false),
    }
}

test "vm: arithmetic operators" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "return 5 - 2, 3 * 4, 7 // 2, 7 % 4, 7 / 2, 2 ^ 3\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 6), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
    switch (ret[1]) {
        .Int => |v| try testing.expectEqual(@as(i64, 12), v),
        else => try testing.expect(false),
    }
    switch (ret[2]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
    switch (ret[3]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
    switch (ret[4]) {
        .Num => |v| try testing.expectApproxEqAbs(@as(f64, 3.5), v, 1e-9),
        else => try testing.expect(false),
    }
    switch (ret[5]) {
        .Num => |v| try testing.expectApproxEqAbs(@as(f64, 8.0), v, 1e-9),
        else => try testing.expect(false),
    }
}

test "vm: numeric comparisons" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "local i = 0\n" ++
            "while i < 3 do i = i + 1 end\n" ++
            "return i, 1 < 2, 2 <= 2, 3 > 2, 3 >= 3\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 5), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
    for (ret[1..]) |v| {
        switch (v) {
            .Bool => |b| try testing.expect(b),
            else => try testing.expect(false),
        }
    }
}

test "vm: string comparisons" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes = "return \"a\" < \"b\", \"a\" <= \"a\", \"b\" > \"a\", \"b\" >= \"b\"\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 4), ret.len);
    for (ret) |v| {
        switch (v) {
            .Bool => |b| try testing.expect(b),
            else => try testing.expect(false),
        }
    }
}

test "vm: string escapes" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "return " ++
            "\"a\\n\", " ++
            "\"\\x41\", " ++
            "\"\\065\", " ++
            "\"\\u{41}\", " ++
            "\"a\\z \n\tb\"\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 5), ret.len);
    switch (ret[0]) {
        .String => |s| try testing.expectEqualStrings("a\n", s),
        else => try testing.expect(false),
    }
    switch (ret[1]) {
        .String => |s| try testing.expectEqualStrings("A", s),
        else => try testing.expect(false),
    }
    switch (ret[2]) {
        .String => |s| try testing.expectEqualStrings("A", s),
        else => try testing.expect(false),
    }
    switch (ret[3]) {
        .String => |s| try testing.expectEqualStrings("A", s),
        else => try testing.expect(false),
    }
    switch (ret[4]) {
        .String => |s| try testing.expectEqualStrings("ab", s),
        else => try testing.expect(false),
    }
}

test "vm: and/or semantics and short-circuit" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig").AstArena;
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "return " ++
            "nil and 1, " ++
            "0 and 1, " ++
            "false or 1, " ++
            "2 or 3, " ++
            "(false and error(\"boom\")) == false, " ++
            "(true or error(\"boom\")) == true\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 6), ret.len);
    try testing.expect(ret[0] == .Nil);
    switch (ret[1]) {
        .Int => |v| try testing.expectEqual(@as(i64, 1), v),
        else => try testing.expect(false),
    }
    switch (ret[2]) {
        .Int => |v| try testing.expectEqual(@as(i64, 1), v),
        else => try testing.expect(false),
    }
    switch (ret[3]) {
        .Int => |v| try testing.expectEqual(@as(i64, 2), v),
        else => try testing.expect(false),
    }
    switch (ret[4]) {
        .Bool => |b| try testing.expect(b),
        else => try testing.expect(false),
    }
    switch (ret[5]) {
        .Bool => |b| try testing.expect(b),
        else => try testing.expect(false),
    }
}

test "vm: numeric for loop (default step)" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "local sum = 0\n" ++
            "for i = 1, 5 do\n" ++
            "  sum = sum + i\n" ++
            "end\n" ++
            "return sum\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 15), v),
        else => try testing.expect(false),
    }
}

test "vm: numeric for loop (negative step)" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "local sum = 0\n" ++
            "for i = 5, 1, -1 do\n" ++
            "  sum = sum + i\n" ++
            "end\n" ++
            "return sum\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 1), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 15), v),
        else => try testing.expect(false),
    }
}

test "vm: numeric for loop break + scope" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const ast = @import("ast.zig");
    const Codegen = @import("codegen.zig").Codegen;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aalloc = arena.allocator();

    const src = Source{
        .name = "<test>",
        .bytes =
        "local sum = 0\n" ++
            "for i = 1, 5 do\n" ++
            "  if i == 3 then break end\n" ++
            "  sum = sum + i\n" ++
            "end\n" ++
            "return sum, i\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);

    var cg = Codegen.init(aalloc, src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var vm = Vm.init(aalloc);
    defer vm.deinit();
    const ret = try vm.runFunction(main_fn);

    try testing.expectEqual(@as(usize, 2), ret.len);
    switch (ret[0]) {
        .Int => |v| try testing.expectEqual(@as(i64, 3), v),
        else => try testing.expect(false),
    }
    try testing.expect(ret[1] == .Nil);
}
