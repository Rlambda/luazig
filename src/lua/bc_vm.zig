const std = @import("std");

const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");

pub const Error = error{
    OutOfMemory,
    UnsupportedOp,
    ConstantOutOfBounds,
    RegisterOutOfBounds,
    TypeError,
};

pub fn runChunk(alloc: std.mem.Allocator, chunk: *const bytecode.Chunk) Error![]vm.Value {
    var regs = try alloc.alloc(vm.Value, chunk.max_stack);
    defer alloc.free(regs);
    for (regs) |*r| r.* = .Nil;

    var pc: usize = 0;
    while (pc < chunk.code.items.len) {
        const inst = chunk.code.items[pc];
        switch (inst.op) {
            .nop => {},
            .move => {
                const a = try regIndex(regs.len, inst.a);
                const b = try regIndex(regs.len, inst.b);
                regs[a] = regs[b];
            },
            .loadk => {
                const a = try regIndex(regs.len, inst.a);
                regs[a] = try decodeConst(chunk, inst.c);
            },
            .loadbool => {
                const a = try regIndex(regs.len, inst.a);
                regs[a] = .{ .Bool = inst.b != 0 };
            },
            .loadnil => {
                const a = try regIndex(regs.len, inst.a);
                regs[a] = .Nil;
            },
            .add => try binNumeric(regs, inst, .add),
            .sub => try binNumeric(regs, inst, .sub),
            .mul => try binNumeric(regs, inst, .mul),
            .div => try binNumeric(regs, inst, .div),
            .mod => try binNumeric(regs, inst, .mod),
            .pow => try binNumeric(regs, inst, .pow),
            .jmp => {
                pc = try jumpTarget(chunk, inst.c);
                continue;
            },
            .jmpif => {
                const a = try regIndex(regs.len, inst.a);
                if (isTruthy(regs[a])) {
                    pc = try jumpTarget(chunk, inst.c);
                    continue;
                }
            },
            .jmpifnot => {
                const a = try regIndex(regs.len, inst.a);
                if (!isTruthy(regs[a])) {
                    pc = try jumpTarget(chunk, inst.c);
                    continue;
                }
            },
            .ret => {
                const n: usize = inst.b;
                if (n == 0) return alloc.alloc(vm.Value, 0);
                const a = try regIndex(regs.len, inst.a);
                if (a + n > regs.len) return error.RegisterOutOfBounds;
                const out = try alloc.alloc(vm.Value, n);
                for (0..n) |i| out[i] = regs[a + i];
                return out;
            },
            else => return error.UnsupportedOp,
        }
        pc += 1;
    }

    return alloc.alloc(vm.Value, 0);
}

fn regIndex(reg_len: usize, reg: anytype) Error!usize {
    const idx: usize = @intCast(reg);
    if (idx >= reg_len) return error.RegisterOutOfBounds;
    return idx;
}

fn jumpTarget(chunk: *const bytecode.Chunk, target: u32) Error!usize {
    const pc: usize = @intCast(target);
    if (pc >= chunk.code.items.len) return error.RegisterOutOfBounds;
    return pc;
}

fn decodeConst(chunk: *const bytecode.Chunk, id_raw: u32) Error!vm.Value {
    const id: usize = @intCast(id_raw);
    if (id >= chunk.const_pool.items.items.len) return error.ConstantOutOfBounds;
    return switch (chunk.const_pool.items.items[id]) {
        .nil => .Nil,
        .bool => |b| .{ .Bool = b },
        .int => |i| .{ .Int = i },
        .num_bits => |bits| .{ .Num = @bitCast(bits) },
        .str => |s| .{ .String = s },
    };
}

const NumOp = enum { add, sub, mul, div, mod, pow };

fn binNumeric(regs: []vm.Value, inst: bytecode.Instruction, op: NumOp) Error!void {
    const dst = try regIndex(regs.len, inst.a);
    const lhs_i = try regIndex(regs.len, inst.b);
    const rhs_i = try regIndex(regs.len, inst.c);

    const lhs = regs[lhs_i];
    const rhs = regs[rhs_i];

    if (lhs == .Int and rhs == .Int and op != .div and op != .pow) {
        const li = lhs.Int;
        const ri = rhs.Int;
        regs[dst] = .{ .Int = switch (op) {
            .add => li + ri,
            .sub => li - ri,
            .mul => li * ri,
            .mod => @mod(li, ri),
            else => unreachable,
        } };
        return;
    }

    const ln = toNumber(lhs) orelse return error.TypeError;
    const rn = toNumber(rhs) orelse return error.TypeError;
    regs[dst] = .{ .Num = switch (op) {
        .add => ln + rn,
        .sub => ln - rn,
        .mul => ln * rn,
        .div => ln / rn,
        .mod => @mod(ln, rn),
        .pow => std.math.pow(f64, ln, rn),
    } };
}

fn toNumber(v: vm.Value) ?f64 {
    return switch (v) {
        .Int => |i| @floatFromInt(i),
        .Num => |n| n,
        else => null,
    };
}

fn isTruthy(v: vm.Value) bool {
    return switch (v) {
        .Nil => false,
        .Bool => |b| b,
        else => true,
    };
}

test "bc vm executes lowered arithmetic program" {
    const ir_mod = @import("ir.zig");
    const lower = @import("lower_ir.zig");

    const insts = [_]ir_mod.Inst{
        .{ .ConstInt = .{ .dst = 0, .lexeme = "40" } },
        .{ .ConstInt = .{ .dst = 1, .lexeme = "2" } },
        .{ .BinOp = .{ .dst = 2, .op = .Plus, .lhs = 0, .rhs = 1 } },
        .{ .Return = .{ .values = &[_]ir_mod.ValueId{2} } },
    };
    const f = ir_mod.Function{
        .name = "bc",
        .insts = insts[0..],
        .num_values = 3,
        .num_locals = 0,
    };

    var chunk = try lower.lowerFunction(std.testing.allocator, &f);
    defer chunk.deinit(std.testing.allocator);

    const out = try runChunk(std.testing.allocator, &chunk);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(out[0] == .Int and out[0].Int == 42);
}
