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

        UnOp: struct { op: TokenKind, exp: *Exp, op_line: u32 = 0 },
        BinOp: struct { op: TokenKind, lhs: *Exp, rhs: *Exp, op_line: u32 = 0 },

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

pub fn dumpChunk(w: anytype, source: []const u8, chunk: *const Chunk) anyerror!void {
    try w.writeAll("Chunk\n");
    try dumpBlock(w, source, 1, chunk.block);
}

fn dumpBlock(w: anytype, source: []const u8, indent: usize, b: *const Block) anyerror!void {
    try writeIndent(w, indent);
    try w.writeAll("Block\n");
    for (b.stats) |st| {
        try dumpStat(w, source, indent + 1, &st);
    }
}

fn writeQuoted(w: anytype, bytes: []const u8) anyerror!void {
    try w.writeByte('"');
    try writeEscaped(w, bytes);
    try w.writeByte('"');
}

fn writeNameQuoted(w: anytype, source: []const u8, n: Name) anyerror!void {
    try writeQuoted(w, n.slice(source));
}

fn writeFuncNameQuoted(w: anytype, source: []const u8, fn_name: FuncName) anyerror!void {
    try w.writeByte('"');
    try writeEscaped(w, fn_name.base.slice(source));
    for (fn_name.fields) |f| {
        try w.writeByte('.');
        try writeEscaped(w, f.slice(source));
    }
    if (fn_name.method) |m| {
        try w.writeByte(':');
        try writeEscaped(w, m.slice(source));
    }
    try w.writeByte('"');
}

fn dumpDeclName(w: anytype, source: []const u8, indent: usize, d: DeclName) anyerror!void {
    try writeIndent(w, indent);
    try w.writeAll("Decl name=");
    try writeNameQuoted(w, source, d.name);
    if (d.prefix_attr) |a| {
        try w.print(" prefix={s}", .{a.kind.name()});
    }
    if (d.suffix_attr) |a| {
        try w.print(" suffix={s}", .{a.kind.name()});
    }
    try w.writeByte('\n');
}

fn dumpFuncBody(w: anytype, source: []const u8, indent: usize, body: *const FuncBody) anyerror!void {
    try writeIndent(w, indent);
    try w.writeAll("FuncBody\n");

    try writeIndent(w, indent + 1);
    try w.writeAll("Params\n");
    for (body.params) |p| {
        try writeIndent(w, indent + 2);
        try w.writeAll("Param ");
        try writeNameQuoted(w, source, p);
        try w.writeByte('\n');
    }

    if (body.vararg) |v| {
        try writeIndent(w, indent + 1);
        try w.writeAll("Vararg");
        if (v.name) |n| {
            try w.writeAll(" name=");
            try writeNameQuoted(w, source, n);
        }
        try w.writeByte('\n');
    }

    try writeIndent(w, indent + 1);
    try w.writeAll("Body\n");
    try dumpBlock(w, source, indent + 2, body.body);
}

fn dumpField(w: anytype, source: []const u8, indent: usize, f: *const Field) anyerror!void {
    switch (f.node) {
        .Array => |e| {
            try writeIndent(w, indent);
            try w.writeAll("FieldArray\n");
            try dumpExp(w, source, indent + 1, e);
        },
        .Name => |nv| {
            try writeIndent(w, indent);
            try w.writeAll("FieldName name=");
            try writeNameQuoted(w, source, nv.name);
            try w.writeByte('\n');
            try dumpExp(w, source, indent + 1, nv.value);
        },
        .Index => |kv| {
            try writeIndent(w, indent);
            try w.writeAll("FieldIndex\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("Key\n");
            try dumpExp(w, source, indent + 2, kv.key);
            try writeIndent(w, indent + 1);
            try w.writeAll("Value\n");
            try dumpExp(w, source, indent + 2, kv.value);
        },
    }
}

fn dumpStat(w: anytype, source: []const u8, indent: usize, st: *const Stat) anyerror!void {
    switch (st.node) {
        .If => |n| {
            try writeIndent(w, indent);
            try w.writeAll("If\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("Cond\n");
            try dumpExp(w, source, indent + 2, n.cond);
            try writeIndent(w, indent + 1);
            try w.writeAll("Then\n");
            try dumpBlock(w, source, indent + 2, n.then_block);
            for (n.elseifs) |ei| {
                try writeIndent(w, indent + 1);
                try w.writeAll("ElseIf\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("Cond\n");
                try dumpExp(w, source, indent + 3, ei.cond);
                try writeIndent(w, indent + 2);
                try w.writeAll("Then\n");
                try dumpBlock(w, source, indent + 3, ei.block);
            }
            if (n.else_block) |eb| {
                try writeIndent(w, indent + 1);
                try w.writeAll("Else\n");
                try dumpBlock(w, source, indent + 2, eb);
            }
        },
        .While => |n| {
            try writeIndent(w, indent);
            try w.writeAll("While\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("Cond\n");
            try dumpExp(w, source, indent + 2, n.cond);
            try writeIndent(w, indent + 1);
            try w.writeAll("Body\n");
            try dumpBlock(w, source, indent + 2, n.block);
        },
        .Do => |n| {
            try writeIndent(w, indent);
            try w.writeAll("Do\n");
            try dumpBlock(w, source, indent + 1, n.block);
        },
        .Repeat => |n| {
            try writeIndent(w, indent);
            try w.writeAll("Repeat\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("Body\n");
            try dumpBlock(w, source, indent + 2, n.block);
            try writeIndent(w, indent + 1);
            try w.writeAll("Until\n");
            try dumpExp(w, source, indent + 2, n.cond);
        },
        .ForNumeric => |n| {
            try writeIndent(w, indent);
            try w.writeAll("ForNumeric name=");
            try writeNameQuoted(w, source, n.name);
            try w.writeByte('\n');
            try writeIndent(w, indent + 1);
            try w.writeAll("Init\n");
            try dumpExp(w, source, indent + 2, n.init);
            try writeIndent(w, indent + 1);
            try w.writeAll("Limit\n");
            try dumpExp(w, source, indent + 2, n.limit);
            if (n.step) |s| {
                try writeIndent(w, indent + 1);
                try w.writeAll("Step\n");
                try dumpExp(w, source, indent + 2, s);
            }
            try writeIndent(w, indent + 1);
            try w.writeAll("Body\n");
            try dumpBlock(w, source, indent + 2, n.block);
        },
        .ForGeneric => |n| {
            try writeIndent(w, indent);
            try w.writeAll("ForGeneric\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("Names\n");
            for (n.names) |nm| {
                try writeIndent(w, indent + 2);
                try w.writeAll("Name ");
                try writeNameQuoted(w, source, nm);
                try w.writeByte('\n');
            }
            try writeIndent(w, indent + 1);
            try w.writeAll("Exps\n");
            for (n.exps) |e| try dumpExp(w, source, indent + 2, e);
            try writeIndent(w, indent + 1);
            try w.writeAll("Body\n");
            try dumpBlock(w, source, indent + 2, n.block);
        },
        .FuncDecl => |n| {
            try writeIndent(w, indent);
            try w.writeAll("FuncDecl name=");
            try writeFuncNameQuoted(w, source, n.name);
            try w.writeByte('\n');
            try dumpFuncBody(w, source, indent + 1, n.body);
        },
        .LocalFuncDecl => |n| {
            try writeIndent(w, indent);
            try w.writeAll("LocalFuncDecl name=");
            try writeNameQuoted(w, source, n.name);
            try w.writeByte('\n');
            try dumpFuncBody(w, source, indent + 1, n.body);
        },
        .GlobalFuncDecl => |n| {
            try writeIndent(w, indent);
            try w.writeAll("GlobalFuncDecl name=");
            try writeNameQuoted(w, source, n.name);
            try w.writeByte('\n');
            try dumpFuncBody(w, source, indent + 1, n.body);
        },
        .LocalDecl => |n| {
            try writeIndent(w, indent);
            try w.writeAll("LocalDecl\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("Names\n");
            for (n.names) |d| try dumpDeclName(w, source, indent + 2, d);
            if (n.values) |vs| {
                try writeIndent(w, indent + 1);
                try w.writeAll("Values\n");
                for (vs) |e| try dumpExp(w, source, indent + 2, e);
            }
        },
        .GlobalDecl => |n| {
            try writeIndent(w, indent);
            try w.writeAll("GlobalDecl");
            if (n.star) try w.writeAll(" star=true");
            if (n.prefix_attr) |a| try w.print(" prefix={s}", .{a.kind.name()});
            try w.writeByte('\n');
            if (!n.star) {
                try writeIndent(w, indent + 1);
                try w.writeAll("Names\n");
                for (n.names) |d| try dumpDeclName(w, source, indent + 2, d);
                if (n.values) |vs| {
                    try writeIndent(w, indent + 1);
                    try w.writeAll("Values\n");
                    for (vs) |e| try dumpExp(w, source, indent + 2, e);
                }
            }
        },
        .Return => |r| {
            try writeIndent(w, indent);
            try w.writeAll("Return\n");
            for (r.values) |e| try dumpExp(w, source, indent + 1, e);
        },
        .Break => {
            try writeIndent(w, indent);
            try w.writeAll("Break\n");
        },
        .Goto => |n| {
            try writeIndent(w, indent);
            try w.writeAll("Goto label=");
            try writeNameQuoted(w, source, n.label);
            try w.writeByte('\n');
        },
        .Label => |n| {
            try writeIndent(w, indent);
            try w.writeAll("Label label=");
            try writeNameQuoted(w, source, n.label);
            try w.writeByte('\n');
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
    }
}

fn dumpExp(w: anytype, source: []const u8, indent: usize, e: *const Exp) anyerror!void {
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
        .Paren => |inner| {
            try writeIndent(w, indent);
            try w.writeAll("Paren\n");
            try dumpExp(w, source, indent + 1, inner);
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
        .Table => |t| {
            try writeIndent(w, indent);
            try w.writeAll("Table\n");
            for (t.fields) |f| try dumpField(w, source, indent + 1, &f);
        },
        .FuncDef => |b| {
            try writeIndent(w, indent);
            try w.writeAll("FuncDef\n");
            try dumpFuncBody(w, source, indent + 1, b);
        },
        .Field => |n| {
            try writeIndent(w, indent);
            try w.writeAll("Field name=");
            try writeNameQuoted(w, source, n.name);
            try w.writeByte('\n');
            try writeIndent(w, indent + 1);
            try w.writeAll("Object\n");
            try dumpExp(w, source, indent + 2, n.object);
        },
        .Index => |n| {
            try writeIndent(w, indent);
            try w.writeAll("Index\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("Object\n");
            try dumpExp(w, source, indent + 2, n.object);
            try writeIndent(w, indent + 1);
            try w.writeAll("Key\n");
            try dumpExp(w, source, indent + 2, n.index);
        },
        .Call => |c| {
            try writeIndent(w, indent);
            try w.writeAll("Call\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("Func\n");
            try dumpExp(w, source, indent + 2, c.func);
            try writeIndent(w, indent + 1);
            try w.writeAll("Args\n");
            for (c.args) |a| try dumpExp(w, source, indent + 2, a);
        },
        .MethodCall => |c| {
            try writeIndent(w, indent);
            try w.writeAll("MethodCall method=");
            try writeNameQuoted(w, source, c.method);
            try w.writeByte('\n');
            try writeIndent(w, indent + 1);
            try w.writeAll("Receiver\n");
            try dumpExp(w, source, indent + 2, c.receiver);
            try writeIndent(w, indent + 1);
            try w.writeAll("Args\n");
            for (c.args) |a| try dumpExp(w, source, indent + 2, a);
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
