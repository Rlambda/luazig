//! P16.45 Task 3: seed-variation diagnostic harness for global_arith.
//!
//! Runs a tight arithmetic workload under `Vm.initWithSeed` with a seed
//! from argv, so ONE process == ONE deterministic seed. Wrap with
//! `perf stat -e instructions:u` to correlate seed → table layout →
//! executed-instruction mode. DIAGNOSTIC harness in tools/, deliberately
//! NOT a production CLI semantic mode.
//!
//! Usage: zig run tools/perf/seed_harness.zig -- <seed-decimal>
const std = @import("std");
const lua = @import("lua");
const stdio = @import("util").stdio;

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.smp_allocator;
    stdio.init(init.io, init.minimal.environ);

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer it.deinit();
    _ = it.next(); // argv0
    const seed_str = it.next() orelse "0";
    const seed = std.fmt.parseInt(u64, seed_str, 10) catch 0;

    // global_arith's exact shape: the loop variable accumulates through a
    // GLOBAL (GETTABUP/SETTABUP on _ENV each iteration) — the workload the
    // P16.44 bimodality was observed on.
    const workload =
        "local N = 50000000 " ++
        \\g_acc = 0
        \\for i = 1, N do g_acc = g_acc + i end
        \\io.write(string.format('%d\n', g_acc))
    ;

    var vm = lua.internal.vm.Vm.initWithSeed(alloc, false, seed);
    defer vm.deinit();

    // Minimal CLI source path: lex → parse → codegen → runBytecode.
    var lex = lua.internal.Lexer.init(.{ .name = "@seedh", .bytes = workload });
    var p = try lua.internal.Parser.init(&lex);
    var ast_arena = lua.internal.ast.AstArena.init(alloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);
    var cg = lua.internal.codegen_bc.Codegen.init(alloc, "@seedh", workload);
    defer cg.deinit();
    const proto = try cg.compileChunk(chunk);
    defer proto.tree.?.releaseTree(alloc);

    const env_cell = try alloc.create(lua.internal.vm.Cell);
    env_cell.* = .{ .value = .{ .Table = vm.global_env } };
    const upvals = [_]*lua.internal.vm.Cell{env_cell};

    try vm.pushHostEntryCFrame();
    defer vm.popHostEntryCFrame();

    const t0 = std.Io.Timestamp.now(stdio.activeIo(), .real).toNanoseconds();
    const ret = vm.runBytecode(proto, &upvals, &.{}, null) catch {
        std.debug.print("seed={d} RUNTIME-ERROR\n", .{seed});
        return error.RuntimeError;
    };
    _ = ret;
    std.debug.print("seed={d} ns={d}\n", .{ seed, std.Io.Timestamp.now(stdio.activeIo(), .real).toNanoseconds() - t0 });
}
