const std = @import("std");

const TokenKind = @import("token.zig").TokenKind;

pub const ValueId = u32;

pub const Function = struct {
    name: []const u8,
    insts: []const Inst,
    num_values: ValueId,
};

pub const Inst = union(enum) {
    ConstNil: struct { dst: ValueId },
    ConstBool: struct { dst: ValueId, val: bool },
    ConstInt: struct { dst: ValueId, lexeme: []const u8 },
    ConstNum: struct { dst: ValueId, lexeme: []const u8 },
    ConstString: struct { dst: ValueId, lexeme: []const u8 },

    GetName: struct { dst: ValueId, name: []const u8 },
    SetName: struct { name: []const u8, src: ValueId },

    UnOp: struct { dst: ValueId, op: TokenKind, src: ValueId },
    BinOp: struct { dst: ValueId, op: TokenKind, lhs: ValueId, rhs: ValueId },

    NewTable: struct { dst: ValueId },
    TableSetField: struct { table: ValueId, name: []const u8, value: ValueId },
    TableSetIndex: struct { table: ValueId, key: ValueId, value: ValueId },
    TableAppend: struct { table: ValueId, value: ValueId },

    GetField: struct { dst: ValueId, object: ValueId, name: []const u8 },
    GetIndex: struct { dst: ValueId, object: ValueId, key: ValueId },

    Call: struct { dsts: []const ValueId, func: ValueId, args: []const ValueId },
    Return: struct { values: []const ValueId },
};

fn writeIndent(w: anytype, n: usize) anyerror!void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll("  ");
}

fn writeEscaped(w: anytype, bytes: []const u8) anyerror!void {
    for (bytes) |c| {
        switch (c) {
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            else => {
                if (c < 0x20 or c >= 0x7f) {
                    try w.print("\\x{X:0>2}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

fn writeQuoted(w: anytype, bytes: []const u8) anyerror!void {
    try w.writeByte('"');
    try writeEscaped(w, bytes);
    try w.writeByte('"');
}

fn writeValue(w: anytype, v: ValueId) anyerror!void {
    try w.print("v{d}", .{v});
}

fn writeValueList(w: anytype, vals: []const ValueId) anyerror!void {
    try w.writeByte('[');
    for (vals, 0..) |v, i| {
        if (i != 0) try w.writeAll(", ");
        try writeValue(w, v);
    }
    try w.writeByte(']');
}

pub fn dumpFunction(w: anytype, f: *const Function) anyerror!void {
    try w.writeAll("Function ");
    try writeQuoted(w, f.name);
    try w.writeByte('\n');

    for (f.insts, 0..) |inst, i| {
        try writeIndent(w, 1);
        try w.print("{d}: ", .{i});
        try dumpInst(w, inst);
        try w.writeByte('\n');
    }
}

fn dumpInst(w: anytype, inst: Inst) anyerror!void {
    switch (inst) {
        .ConstNil => |n| {
            try writeValue(w, n.dst);
            try w.writeAll(" = const nil");
        },
        .ConstBool => |b| {
            try writeValue(w, b.dst);
            try w.print(" = const {s}", .{if (b.val) "true" else "false"});
        },
        .ConstInt => |n| {
            try writeValue(w, n.dst);
            try w.writeAll(" = const_int ");
            try writeQuoted(w, n.lexeme);
        },
        .ConstNum => |n| {
            try writeValue(w, n.dst);
            try w.writeAll(" = const_num ");
            try writeQuoted(w, n.lexeme);
        },
        .ConstString => |s| {
            try writeValue(w, s.dst);
            try w.writeAll(" = const_str ");
            try writeQuoted(w, s.lexeme);
        },
        .GetName => |g| {
            try writeValue(w, g.dst);
            try w.writeAll(" = getname ");
            try writeQuoted(w, g.name);
        },
        .SetName => |s| {
            try w.writeAll("setname ");
            try writeQuoted(w, s.name);
            try w.writeAll(" <- ");
            try writeValue(w, s.src);
        },
        .UnOp => |u| {
            try writeValue(w, u.dst);
            try w.print(" = unop {s} ", .{u.op.name()});
            try writeValue(w, u.src);
        },
        .BinOp => |b| {
            try writeValue(w, b.dst);
            try w.print(" = binop {s} ", .{b.op.name()});
            try writeValue(w, b.lhs);
            try w.writeAll(", ");
            try writeValue(w, b.rhs);
        },
        .NewTable => |t| {
            try writeValue(w, t.dst);
            try w.writeAll(" = newtable");
        },
        .TableSetField => |s| {
            try w.writeAll("tableset_field ");
            try writeValue(w, s.table);
            try w.writeAll(" ");
            try writeQuoted(w, s.name);
            try w.writeAll(" <- ");
            try writeValue(w, s.value);
        },
        .TableSetIndex => |s| {
            try w.writeAll("tableset_index ");
            try writeValue(w, s.table);
            try w.writeAll(" [");
            try writeValue(w, s.key);
            try w.writeAll("] <- ");
            try writeValue(w, s.value);
        },
        .TableAppend => |a| {
            try w.writeAll("tableappend ");
            try writeValue(w, a.table);
            try w.writeAll(" <- ");
            try writeValue(w, a.value);
        },
        .GetField => |g| {
            try writeValue(w, g.dst);
            try w.writeAll(" = getfield ");
            try writeValue(w, g.object);
            try w.writeAll(" ");
            try writeQuoted(w, g.name);
        },
        .GetIndex => |g| {
            try writeValue(w, g.dst);
            try w.writeAll(" = getindex ");
            try writeValue(w, g.object);
            try w.writeAll(" [");
            try writeValue(w, g.key);
            try w.writeAll("]");
        },
        .Call => |c| {
            try w.writeAll("call ");
            try writeValueList(w, c.dsts);
            try w.writeAll(" <- ");
            try writeValue(w, c.func);
            try w.writeAll(" args=");
            try writeValueList(w, c.args);
        },
        .Return => |r| {
            try w.writeAll("return ");
            try writeValueList(w, r.values);
        },
    }
}

test "ir dump: manual small function" {
    const testing = std.testing;

    const insts = [_]Inst{
        .{ .ConstInt = .{ .dst = 0, .lexeme = "1" } },
        .{ .ConstInt = .{ .dst = 1, .lexeme = "2" } },
        .{ .BinOp = .{ .dst = 2, .op = .Plus, .lhs = 0, .rhs = 1 } },
        .{ .Return = .{ .values = &[_]ValueId{2} } },
    };

    const f: Function = .{
        .name = "main",
        .insts = insts[0..],
        .num_values = 3,
    };

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);

    try dumpFunction(buf.writer(testing.allocator), &f);
    try testing.expectEqualStrings(
        \\Function "main"
        \\  0: v0 = const_int "1"
        \\  1: v1 = const_int "2"
        \\  2: v2 = binop + v0, v1
        \\  3: return [v2]
        \\
    , buf.items);
}
