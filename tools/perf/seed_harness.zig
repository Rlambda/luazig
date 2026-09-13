//! P16.45-correction: seed-variation diagnostic harness.
//!
//! Executes the CANONICAL `tools/microbench.lua` (file read from argv,
//! workload selector as script arg — identical to the luazig CLI path)
//! under `Vm.initWithSeed`, so ONE process == ONE deterministic seed AND
//! the workload/population history is byte-identical to the perf-gate's
//! global_arith lane (same file, same bench() warmup, same stdlib setup).
//!
//! After the run it prints a STRUCTURAL observable — the intern-table
//! chain depth of the hot global's name string ("g_count") — so the
//! seed→mode correlation can be attributed to a measured table fact, not
//! just inferred.
//!
//! DIAGNOSTIC harness in tools/, NOT a production CLI semantic mode.
//! Canonical build (single uniform mode):
//!   zig build seed-harness -Doptimize=ReleaseFast
//! Usage: ./seed_harness <seed-decimal> [path/to/microbench.lua] [selector]
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
    const script_path = it.next() orelse "tools/microbench.lua";
    const selector = it.next() orelse "global_arith";

    // Process-lifetime script buffer (never freed — the CLI does the same;
    // the tree's debug lexemes borrow it). Source.loadFile = the CLI's own
    // loader (std.Io.Dir.cwd().readFileAlloc + "@path" name).
    const src_val = lua.internal.Source.loadFile(alloc, init.io, script_path) catch |e| {
        std.debug.print("seed={d} OPEN-ERROR {any}\n", .{ seed, e });
        return e;
    };
    const source: []const u8 = src_val.bytes;

    var vm = lua.internal.vm.Vm.initWithSeed(alloc, false, seed);
    defer vm.deinit();

    // CLI source path: lex → parse → codegen → runBytecode, script_args
    // carries the workload selector (microbench reads `local only = ...`).
    var lex = lua.internal.Lexer.init(.{ .name = src_val.name, .bytes = source });
    var p = try lua.internal.Parser.init(&lex);
    var ast_arena = lua.internal.ast.AstArena.init(alloc);
    defer ast_arena.deinit();
    const chunk = try p.parseChunkAst(&ast_arena);
    var cg = lua.internal.codegen_bc.Codegen.init(alloc, src_val.name, source);
    defer cg.deinit();
    const proto = try cg.compileChunk(chunk);
    defer proto.tree.?.releaseTree(alloc);

    const env_cell = try alloc.create(lua.internal.vm.Cell);
    env_cell.* = .{ .value = .{ .Table = vm.global_env } };
    const upvals = [_]*lua.internal.vm.Cell{env_cell};
    const script_args = [_]lua.internal.vm.Value{.{ .String = try vm.internStr(selector) }};

    try vm.pushHostEntryCFrame();
    defer vm.popHostEntryCFrame();

    const t0 = std.Io.Timestamp.now(stdio.activeIo(), .real).toNanoseconds();
    _ = vm.runBytecode(proto, &upvals, &script_args, null) catch {
        std.debug.print("seed={d} RUNTIME-ERROR\n", .{seed});
        return error.RuntimeError;
    };
    const t1 = std.Io.Timestamp.now(stdio.activeIo(), .real).toNanoseconds();

    // ── Structural observable: intern-table chain facts for the hot
    // global's name. The hash is recomputed EXACTLY as internStr does
    // (Wyhash over the bytes with the VM seed), the bucket index as
    // `hash & (len-1)`, and the chain walked from the bucket head. Chain
    // depth 0 = the name sits at the bucket head (every lookup touches
    // one node); depth N = N+1 node visits per interned-name table get.
    const name = "g_count";
    var h = std.hash.Wyhash.init(seed);
    h.update(name);
    const hash = h.final();
    const st = &vm.string_intern;
    var chain_depth: i64 = -1; // -1 = not found (should not happen)
    var bucket_len: usize = 0;
    if (st.buckets.len != 0) {
        const bucket: usize = @intCast(hash & (st.buckets.len - 1));
        var cur = st.buckets[bucket];
        var idx: usize = 0;
        while (cur) |ls| : (cur = ls.nextShort()) {
            if (ls.len() == name.len and std.mem.eql(u8, ls.bytes(), name))
                chain_depth = @intCast(idx);
            idx += 1;
        }
        bucket_len = idx;
    }

    // ── Second structural observable: the _ENV TABLE's node for the hot
    // global. The intern chain was depth-0 in BOTH modes (measured); the
    // table's own node placement is the next candidate — its chain length
    // (from the key's main position) is the work each GETTABUP/SETTABUP's
    // table-get actually pays.
    var env_node_depth: i64 = -1; // -1 = key not found
    var env_node_chain_len: usize = 0;
    {
        const env = vm.global_env;
        const nodes = env.hash;
        if (nodes.len != 0) {
            const ls = st.lookup(name, hash) orelse null;
            if (ls) |key| {
                const mp: usize = key.hash & (nodes.len - 1);
                var n: ?*lua.internal.ltable.Node = &nodes[mp];
                var idx: usize = 0;
                while (n) |node| : (n = node.nextNode(nodes)) {
                    if (node.key_tt == .short_string and node.key_val.string == key)
                        env_node_depth = @intCast(idx);
                    idx += 1;
                }
                env_node_chain_len = idx;
            }
        }
    }

    std.debug.print("seed={d} ns={d} g_count_chain_depth={d} bucket_len={d} intern_nuse={d} env_node_depth={d} env_node_chain_len={d}\n", .{ seed, t1 - t0, chain_depth, bucket_len, st.nuse, env_node_depth, env_node_chain_len });
}
