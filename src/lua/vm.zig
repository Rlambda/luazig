const std = @import("std");

const ir = @import("ir.zig");
const TokenKind = @import("token.zig").TokenKind;

pub const Value = union(enum) {
    Nil,
    Bool: bool,
    Int: i64,
    Num: f64,
    String: []const u8,

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .Nil => "nil",
            .Bool => "boolean",
            .Int, .Num => "number",
            .String => "string",
        };
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
        const nilv: Value = .Nil;
        const regs = try self.alloc.alloc(Value, f.num_values);
        defer self.alloc.free(regs);
        for (regs) |*r| r.* = nilv;

        var pc: usize = 0;
        while (pc < f.insts.len) : (pc += 1) {
            const inst = f.insts[pc];
            switch (inst) {
                .ConstNil => |n| regs[n.dst] = .Nil,
                .ConstBool => |b| regs[b.dst] = .{ .Bool = b.val },
                .ConstInt => |n| regs[n.dst] = .{ .Int = try self.parseInt(n.lexeme) },
                .ConstNum => |n| regs[n.dst] = .{ .Num = try self.parseNum(n.lexeme) },
                .ConstString => |s| regs[s.dst] = .{ .String = s.lexeme },

                .GetName => |g| regs[g.dst] = self.getGlobal(g.name),
                .SetName => |s| try self.setGlobal(s.name, regs[s.src]),

                .UnOp => |u| regs[u.dst] = try self.evalUnOp(u.op, regs[u.src]),
                .BinOp => |b| regs[b.dst] = try self.evalBinOp(b.op, regs[b.lhs], regs[b.rhs]),

                .Return => |r| {
                    const out = try self.alloc.alloc(Value, r.values.len);
                    for (r.values, 0..) |vid, i| out[i] = regs[vid];
                    return out;
                },

                else => return self.fail("unsupported instruction: {s}", .{@tagName(inst)}),
            }
        }

        // Should not happen: codegen always ensures a terminating `Return`.
        return self.alloc.alloc(Value, 0);
    }

    fn getGlobal(self: *Vm, name: []const u8) Value {
        return self.globals.get(name) orelse .Nil;
    }

    fn setGlobal(self: *Vm, name: []const u8, v: Value) std.mem.Allocator.Error!void {
        // `name` is borrowed from source bytes. If we later need globals to
        // outlive the source, we should intern/dupe keys.
        try self.globals.put(self.alloc, name, v);
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
            else => return self.fail("unsupported binary operator: {s}", .{op.name()}),
        }
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
