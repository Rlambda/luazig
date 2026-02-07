const std = @import("std");

const Token = @import("token.zig").Token;
const TokenKind = @import("token.zig").TokenKind;

pub const Span = struct {
    start: usize,
    end: usize,
    line: u32,
    col: u32,

    pub fn fromToken(t: Token) Span {
        return .{
            .start = t.start,
            .end = t.end,
            .line = t.line,
            .col = t.col,
        };
    }

    pub fn join(a: Span, b: Span) Span {
        return .{
            .start = a.start,
            .end = b.end,
            .line = a.line,
            .col = a.col,
        };
    }

    pub fn slice(self: Span, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const AttrKind = enum {
    Const,
    Close,

    pub fn name(self: AttrKind) []const u8 {
        return switch (self) {
            .Const => "const",
            .Close => "close",
        };
    }
};

pub const Attr = struct {
    span: Span,
    kind: AttrKind,
};

pub const Name = struct {
    span: Span,

    pub fn slice(self: Name, source: []const u8) []const u8 {
        return self.span.slice(source);
    }
};

pub const Chunk = struct {
    span: Span,
    block: *Block,
};

pub const Block = struct {
    span: Span,
    stats: []Stat,
};

pub const ElseIf = struct {
    cond: *Exp,
    block: *Block,
};

pub const FuncName = struct {
    span: Span,
    base: Name,
    fields: []Name,
    method: ?Name,
};

pub const Vararg = struct {
    span: Span,
    name: ?Name,
};

pub const FuncBody = struct {
    span: Span,
    params: []Name,
    vararg: ?Vararg,
    body: *Block,
};

pub const DeclName = struct {
    name: Name,
    prefix_attr: ?Attr = null,
    suffix_attr: ?Attr = null,
};

pub const Field = struct {
    span: Span,
    node: Node,

    pub const Node = union(enum) {
        Array: *Exp,
        Name: struct { name: Name, value: *Exp },
        Index: struct { key: *Exp, value: *Exp },
    };
};

pub const Stat = struct {
    span: Span,
    node: Node,

    pub const Node = union(enum) {
        If: struct {
            cond: *Exp,
            then_block: *Block,
            elseifs: []ElseIf,
            else_block: ?*Block,
        },
        While: struct { cond: *Exp, block: *Block },
        Do: struct { block: *Block },
        Repeat: struct { block: *Block, cond: *Exp },
        ForNumeric: struct {
            name: Name,
            init: *Exp,
            limit: *Exp,
            step: ?*Exp,
            block: *Block,
        },
        ForGeneric: struct { names: []Name, exps: []*Exp, block: *Block },

        FuncDecl: struct { name: FuncName, body: *FuncBody },
        LocalFuncDecl: struct { name: Name, body: *FuncBody },
        GlobalFuncDecl: struct { name: Name, body: *FuncBody },

        LocalDecl: struct { names: []DeclName, values: ?[]*Exp },
        GlobalDecl: struct { prefix_attr: ?Attr, star: bool, names: []DeclName, values: ?[]*Exp },

        Assign: struct { lhs: []*Exp, rhs: []*Exp },
        Call: struct { call: *Exp },

        Return: struct { values: [](*Exp) },
        Break,
        Goto: struct { label: Name },
        Label: struct { label: Name },
    };
};

pub const Exp = struct {
    span: Span,
    node: Node,

    pub const Node = union(enum) {
        Nil,
        True,
        False,
        Integer,
        Number,
        String,
        Dots,

        Name: Name,
        Paren: *Exp,

        UnOp: struct { op: TokenKind, exp: *Exp },
        BinOp: struct { op: TokenKind, lhs: *Exp, rhs: *Exp },

        Table: struct { fields: []Field },
        FuncDef: *FuncBody,

        Field: struct { object: *Exp, name: Name },
        Index: struct { object: *Exp, index: *Exp },

        Call: struct { func: *Exp, args: []*Exp },
        MethodCall: struct { receiver: *Exp, method: Name, args: []*Exp },
    };
};

pub const AstArena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(alloc: std.mem.Allocator) AstArena {
        return .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *AstArena) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *AstArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn create(self: *AstArena, comptime T: type) !*T {
        return try self.allocator().create(T);
    }
};

fn writeIndent(w: anytype, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll("  ");
}

fn writeEscaped(w: anytype, bytes: []const u8) !void {
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

pub fn dumpChunk(w: anytype, source: []const u8, chunk: *const Chunk) !void {
    try w.writeAll("Chunk\n");
    try dumpBlock(w, source, 1, chunk.block);
}

fn dumpBlock(w: anytype, source: []const u8, indent: usize, b: *const Block) !void {
    try writeIndent(w, indent);
    try w.writeAll("Block\n");
    for (b.stats) |st| {
        try dumpStat(w, source, indent + 1, &st);
    }
}

fn dumpStat(w: anytype, source: []const u8, indent: usize, st: *const Stat) !void {
    switch (st.node) {
        .Return => |r| {
            try writeIndent(w, indent);
            try w.writeAll("Return\n");
            for (r.values) |e| try dumpExp(w, source, indent + 1, e);
        },
        .Break => {
            try writeIndent(w, indent);
            try w.writeAll("Break\n");
        },
        .Call => |c| {
            try writeIndent(w, indent);
            try w.writeAll("CallStat\n");
            try dumpExp(w, source, indent + 1, c.call);
        },
        .Assign => |a| {
            try writeIndent(w, indent);
            try w.writeAll("Assign\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("LHS\n");
            for (a.lhs) |e| try dumpExp(w, source, indent + 2, e);
            try writeIndent(w, indent + 1);
            try w.writeAll("RHS\n");
            for (a.rhs) |e| try dumpExp(w, source, indent + 2, e);
        },
        else => {
            try writeIndent(w, indent);
            try w.writeAll("(stat ...)\n");
        },
    }
}

fn dumpExp(w: anytype, source: []const u8, indent: usize, e: *const Exp) !void {
    switch (e.node) {
        .Integer => {
            try writeIndent(w, indent);
            try w.writeAll("Integer \"");
            try writeEscaped(w, e.span.slice(source));
            try w.writeAll("\"\n");
        },
        .Number => {
            try writeIndent(w, indent);
            try w.writeAll("Number \"");
            try writeEscaped(w, e.span.slice(source));
            try w.writeAll("\"\n");
        },
        .String => {
            try writeIndent(w, indent);
            try w.writeAll("String \"");
            try writeEscaped(w, e.span.slice(source));
            try w.writeAll("\"\n");
        },
        .Name => |n| {
            try writeIndent(w, indent);
            try w.writeAll("Name \"");
            try writeEscaped(w, n.slice(source));
            try w.writeAll("\"\n");
        },
        .BinOp => |b| {
            try writeIndent(w, indent);
            try w.print("BinOp op={s}\n", .{b.op.name()});
            try dumpExp(w, source, indent + 1, b.lhs);
            try dumpExp(w, source, indent + 1, b.rhs);
        },
        .UnOp => |u| {
            try writeIndent(w, indent);
            try w.print("UnOp op={s}\n", .{u.op.name()});
            try dumpExp(w, source, indent + 1, u.exp);
        },
        .Dots => {
            try writeIndent(w, indent);
            try w.writeAll("Dots\n");
        },
        .Nil => {
            try writeIndent(w, indent);
            try w.writeAll("Nil\n");
        },
        .True => {
            try writeIndent(w, indent);
            try w.writeAll("True\n");
        },
        .False => {
            try writeIndent(w, indent);
            try w.writeAll("False\n");
        },
        else => {
            try writeIndent(w, indent);
            try w.writeAll("(exp ...)\n");
        },
    }
}

test "ast printer: manual small tree" {
    const testing = std.testing;

    const src = "return 1+2";
    var arena = AstArena.init(testing.allocator);
    defer arena.deinit();

    const e1 = try arena.create(Exp);
    e1.* = .{ .span = .{ .start = 7, .end = 8, .line = 1, .col = 8 }, .node = .Integer };

    const e2 = try arena.create(Exp);
    e2.* = .{ .span = .{ .start = 9, .end = 10, .line = 1, .col = 10 }, .node = .Integer };

    const ebin = try arena.create(Exp);
    ebin.* = .{
        .span = Span.join(e1.span, e2.span),
        .node = .{ .BinOp = .{ .op = .Plus, .lhs = e1, .rhs = e2 } },
    };

    const values = try arena.allocator().alloc(*Exp, 1);
    values[0] = ebin;

    const st = Stat{
        .span = .{ .start = 0, .end = src.len, .line = 1, .col = 1 },
        .node = .{ .Return = .{ .values = values } },
    };

    const stats = try arena.allocator().alloc(Stat, 1);
    stats[0] = st;

    const block = try arena.create(Block);
    block.* = .{
        .span = .{ .start = 0, .end = src.len, .line = 1, .col = 1 },
        .stats = stats,
    };

    const chunk = try arena.create(Chunk);
    chunk.* = .{
        .span = .{ .start = 0, .end = src.len, .line = 1, .col = 1 },
        .block = block,
    };

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try dumpChunk(buf.writer(testing.allocator), src, chunk);

    try testing.expectEqualStrings(
        \\Chunk
        \\  Block
        \\    Return
        \\      BinOp op=+
        \\        Integer "1"
        \\        Integer "2"
        \\
    , buf.items);
}
