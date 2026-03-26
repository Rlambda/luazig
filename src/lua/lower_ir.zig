const std = @import("std");

const ir = @import("ir.zig");
const bytecode = @import("bytecode.zig");
const TokenKind = @import("token.zig").TokenKind;

pub const Error = error{
    OutOfMemory,
    UnsupportedInst,
    UnsupportedBinOp,
    UnsupportedConstInt,
    RegisterOverflow,
    ConstantPoolOverflow,
    BytecodeTooLarge,
    InvalidPcOrder,
    UnresolvedLabel,
    DuplicateLabel,
    StackOverflow,
    ParameterOverflow,
    UnsupportedReturnArity,
};

const PendingPatch = struct {
    pc: bytecode.Pc,
    label: ir.LabelId,
};

pub fn lowerFunction(alloc: std.mem.Allocator, f: *const ir.Function) Error!bytecode.Chunk {
    var out: bytecode.Chunk = .{};
    errdefer out.deinit(alloc);

    if (f.num_values > std.math.maxInt(u16)) return error.StackOverflow;
    if (f.num_params > std.math.maxInt(u8)) return error.ParameterOverflow;
    out.max_stack = @intCast(f.num_values);
    out.num_params = @intCast(f.num_params);
    out.is_vararg = f.is_vararg;

    var labels = std.AutoHashMapUnmanaged(ir.LabelId, bytecode.Pc){};
    defer labels.deinit(alloc);

    var patches = std.ArrayListUnmanaged(PendingPatch){};
    defer patches.deinit(alloc);

    for (f.insts, 0..) |inst, idx| {
        const line = lineAt(f, idx);
        switch (inst) {
            .Label => |l| {
                const pc: bytecode.Pc = @intCast(out.code.items.len);
                const gop = try labels.getOrPut(alloc, l.id);
                if (gop.found_existing) return error.DuplicateLabel;
                gop.value_ptr.* = pc;
            },
            .ConstNil => |c| {
                try emitRegOp(&out, alloc, .loadnil, c.dst, 0, 0, line);
            },
            .ConstBool => |c| {
                try emitRegOp(&out, alloc, .loadbool, c.dst, @intFromBool(c.val), 0, line);
            },
            .ConstInt => |c| {
                const value = std.fmt.parseInt(i64, c.lexeme, 10) catch return error.UnsupportedConstInt;
                const kid = try out.const_pool.intern(alloc, .{ .int = value });
                try emitLoadK(&out, alloc, c.dst, kid, line);
            },
            .ConstNum => |c| {
                const n = std.fmt.parseFloat(f64, c.lexeme) catch return error.UnsupportedConstInt;
                const kid = try out.const_pool.intern(alloc, bytecode.Constant.num(n));
                try emitLoadK(&out, alloc, c.dst, kid, line);
            },
            .ConstString => |c| {
                const kid = try out.const_pool.intern(alloc, .{ .str = c.lexeme });
                try emitLoadK(&out, alloc, c.dst, kid, line);
            },
            .GetName => |g| {
                const kid = try out.const_pool.intern(alloc, .{ .str = g.name });
                try emitLoadK(&out, alloc, g.dst, kid, line);
                try emitRegOp(&out, alloc, .getglobal, g.dst, g.dst, 0, line);
            },
            .SetName => |s| {
                const kid = try out.const_pool.intern(alloc, .{ .str = s.name });
                const key_reg: ir.ValueId = s.src;
                try emitLoadK(&out, alloc, key_reg, kid, line);
                try emitRegOp(&out, alloc, .setglobal, s.src, key_reg, 0, line);
            },
            .GetLocal => |g| {
                try emitRegOp(&out, alloc, .move, g.dst, g.local, 0, line);
            },
            .SetLocal => |s| {
                try emitRegOp(&out, alloc, .move, s.local, s.src, 0, line);
            },
            .BinOp => |b| {
                const op = mapBinOp(b.op) orelse return error.UnsupportedBinOp;
                try emitRegOp(&out, alloc, op, b.dst, b.lhs, b.rhs, line);
            },
            .Jump => |j| {
                const pc = try emitJmpPlaceholder(&out, alloc, .jmp, line);
                try patches.append(alloc, .{ .pc = pc, .label = j.target });
            },
            .JumpIfFalse => |j| {
                const cond = try narrowU8(j.cond);
                const pc = try out.emit(alloc, .{ .op = .jmpifnot, .a = cond, .b = 0, .c = 0 }, line);
                try patches.append(alloc, .{ .pc = pc, .label = j.target });
            },
            .Return => |r| {
                if (r.values.len > 1) return error.UnsupportedReturnArity;
                const src: u8 = if (r.values.len == 1) try narrowU8(r.values[0]) else 0;
                const count: u16 = @intCast(r.values.len);
                _ = try out.emit(alloc, .{ .op = .ret, .a = src, .b = count, .c = 0 }, line);
            },
            else => return error.UnsupportedInst,
        }
    }

    for (patches.items) |p| {
        const target = labels.get(p.label) orelse return error.UnresolvedLabel;
        out.code.items[p.pc].c = target;
    }

    return out;
}

fn emitLoadK(chunk: *bytecode.Chunk, alloc: std.mem.Allocator, dst: ir.ValueId, kid: bytecode.ConstId, line: i32) Error!void {
    const a = try narrowU8(dst);
    _ = try chunk.emit(alloc, .{ .op = .loadk, .a = a, .b = 0, .c = kid }, line);
}

fn emitRegOp(chunk: *bytecode.Chunk, alloc: std.mem.Allocator, op: bytecode.Op, a0: anytype, b0: anytype, c0: anytype, line: i32) Error!void {
    const a = try narrowU8(a0);
    const b = try narrowU16(b0);
    const c = try narrowU32(c0);
    _ = try chunk.emit(alloc, .{ .op = op, .a = a, .b = b, .c = c }, line);
}

fn emitJmpPlaceholder(chunk: *bytecode.Chunk, alloc: std.mem.Allocator, op: bytecode.Op, line: i32) Error!bytecode.Pc {
    return chunk.emit(alloc, .{ .op = op, .a = 0, .b = 0, .c = 0 }, line);
}

fn mapBinOp(op: TokenKind) ?bytecode.Op {
    return switch (op) {
        .Plus => .add,
        .Minus => .sub,
        .Star => .mul,
        .Slash => .div,
        .Percent => .mod,
        .Caret => .pow,
        else => null,
    };
}

fn lineAt(f: *const ir.Function, idx: usize) i32 {
    if (idx < f.inst_lines.len) return @intCast(f.inst_lines[idx]);
    return 0;
}

fn narrowU8(v: anytype) Error!u8 {
    const x: u64 = @intCast(v);
    if (x > std.math.maxInt(u8)) return error.RegisterOverflow;
    return @intCast(x);
}

fn narrowU16(v: anytype) Error!u16 {
    const x: u64 = @intCast(v);
    if (x > std.math.maxInt(u16)) return error.RegisterOverflow;
    return @intCast(x);
}

fn narrowU32(v: anytype) Error!u32 {
    const x: u64 = @intCast(v);
    if (x > std.math.maxInt(u32)) return error.RegisterOverflow;
    return @intCast(x);
}

test "lower basic const/binop/return" {
    const insts = [_]ir.Inst{
        .{ .ConstInt = .{ .dst = 0, .lexeme = "1" } },
        .{ .ConstInt = .{ .dst = 1, .lexeme = "2" } },
        .{ .BinOp = .{ .dst = 2, .op = .Plus, .lhs = 0, .rhs = 1 } },
        .{ .Return = .{ .values = &[_]ir.ValueId{2} } },
    };
    const lines = [_]u32{ 10, 11, 12, 13 };
    const f = ir.Function{
        .name = "t",
        .insts = insts[0..],
        .inst_lines = lines[0..],
        .num_values = 3,
        .num_locals = 0,
    };

    var chunk = try lowerFunction(std.testing.allocator, &f);
    defer chunk.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), chunk.code.items.len);
    try std.testing.expectEqual(bytecode.Op.loadk, chunk.code.items[0].op);
    try std.testing.expectEqual(bytecode.Op.loadk, chunk.code.items[1].op);
    try std.testing.expectEqual(bytecode.Op.add, chunk.code.items[2].op);
    try std.testing.expectEqual(bytecode.Op.ret, chunk.code.items[3].op);
    try std.testing.expectEqual(@as(?i32, 12), chunk.line_table.lineAt(2));
}

test "lower resolves labels for jumps" {
    const insts = [_]ir.Inst{
        .{ .ConstBool = .{ .dst = 0, .val = true } },
        .{ .Jump = .{ .target = 7 } },
        .{ .ConstBool = .{ .dst = 0, .val = false } },
        .{ .Label = .{ .id = 7 } },
        .{ .Return = .{ .values = &[_]ir.ValueId{0} } },
    };
    const f = ir.Function{
        .name = "jmp",
        .insts = insts[0..],
        .num_values = 1,
        .num_locals = 0,
    };

    var chunk = try lowerFunction(std.testing.allocator, &f);
    defer chunk.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), chunk.code.items.len);
    try std.testing.expectEqual(bytecode.Op.jmp, chunk.code.items[1].op);
    try std.testing.expectEqual(@as(u32, 3), chunk.code.items[1].c);
}
