const std = @import("std");
const lua = @import("lua");
const stdio = @import("util").stdio;

fn bumpStackLimit() void {
    const lim = std.posix.getrlimit(.STACK) catch return;
    // Our IR interpreter currently uses deep native recursion for Lua calls.
    // Keep a larger stack cap to avoid hard crashes on deep-return tests.
    const target: usize = 256 * 1024 * 1024;
    if (lim.cur >= target) return;
    var next = lim;
    if (lim.max == std.math.maxInt(usize) or target <= lim.max) {
        next.cur = target;
    } else {
        next.cur = lim.max;
    }
    std.posix.setrlimit(.STACK, next) catch {};
}

fn usage(out: anytype) !void {
    try out.writeAll(
        \\luazig
        \\usage: luazig [lua options] [script [args]]
        \\
        \\Zig engine options (subset):
        \\  -e chunk      execute string 'chunk'
        \\  --vm=ir|bc    select VM backend (default: ir)
        \\  --bc-coverage-out <file.json>   write BC lowering/fallback coverage stats
        \\  --testc       enable test-only module `T` (ltests compatibility path)
        \\
        \\Compatibility:
        \\  --engine=zig  accepted (no-op)
        \\  --engine=ref  removed; run build/lua-c/lua directly for reference behavior
        \\
    );
}

const VmBackend = enum { ir, bc };

const BcCoverageStats = struct {
    total_functions: usize = 0,
    lowered_functions: usize = 0,
    fallback_functions: usize = 0,
    total_insts: usize = 0,
    lowered_insts: usize = 0,
    fallback_insts: usize = 0,
};

fn parseVmBackend(s: []const u8) ?VmBackend {
    if (std.mem.eql(u8, s, "ir")) return .ir;
    if (std.mem.eql(u8, s, "bc")) return .bc;
    return null;
}

fn parseEngineCompat(s: []const u8) enum { zig, ref, invalid } {
    if (std.mem.eql(u8, s, "zig")) return .zig;
    if (std.mem.eql(u8, s, "ref")) return .ref;
    return .invalid;
}

fn runZigSource(aalloc: std.mem.Allocator, vm: *lua.vm.Vm, source: lua.Source, backend: VmBackend, bc_stats: ?*BcCoverageStats) !void {
    var lex = lua.Lexer.init(source);
    var p = lua.Parser.init(&lex) catch {
        var errw = stdio.stderr();
        try errw.print("{s}\n", .{lex.diagString()});
        return error.SyntaxError;
    };

    var ast_arena = lua.ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = p.parseChunkAst(&ast_arena) catch {
        var errw = stdio.stderr();
        try errw.print("{s}\n", .{p.diagString()});
        return error.SyntaxError;
    };

    var cg = lua.codegen.Codegen.init(aalloc, source.name, source.bytes);
    const main_fn = cg.compileChunk(chunk) catch {
        var errw = stdio.stderr();
        try errw.print("{s}\n", .{cg.diagString()});
        return error.CodegenError;
    };

    switch (backend) {
        .ir => {
            const ret = vm.runFunction(main_fn) catch {
                var errw = stdio.stderr();
                try errw.print("{s}\n", .{vm.errorString()});
                return error.RuntimeError;
            };
            aalloc.free(ret);
        },
        .bc => {
            if (bc_stats) |s| {
                s.total_functions += 1;
                s.total_insts += main_fn.insts.len;
            }
            const fallback_ir = blk: {
                const chunk_bc = lua.lower_ir.lowerFunction(aalloc, main_fn) catch break :blk true;
                var owned = chunk_bc;
                defer owned.deinit(aalloc);
                const ret = lua.bc_vm.runChunk(aalloc, &owned) catch break :blk true;
                aalloc.free(ret);
                break :blk false;
            };
            if (fallback_ir) {
                if (bc_stats) |s| {
                    s.fallback_functions += 1;
                    s.fallback_insts += main_fn.insts.len;
                }
                const ret = vm.runFunction(main_fn) catch {
                    var errw = stdio.stderr();
                    try errw.print("{s}\n", .{vm.errorString()});
                    return error.RuntimeError;
                };
                aalloc.free(ret);
            } else if (bc_stats) |s| {
                s.lowered_functions += 1;
                s.lowered_insts += main_fn.insts.len;
            }
        },
    }
}

pub fn main() !void {
    bumpStackLimit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const argv0 = if (args.len > 0) args[0] else "luazig";
    var backend: VmBackend = .ir;
    var bc_coverage_out: ?[]const u8 = null;
    var enable_testc = false;

    var forwarded_count: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            var out = stdio.stdout();
            try usage(&out);
            return;
        }

        const prefix = "--engine=";
        if (std.mem.startsWith(u8, a, prefix)) {
            const v = a[prefix.len..];
            switch (parseEngineCompat(v)) {
                .zig => {},
                .ref => {
                    var errw = stdio.stderr();
                    try errw.print("{s}: --engine=ref was removed; run ./build/lua-c/lua directly\n", .{argv0});
                    return error.InvalidArgument;
                },
                .invalid => {
                    var errw = stdio.stderr();
                    try errw.print("{s}: unknown engine '{s}'\n", .{ argv0, v });
                    return error.InvalidArgument;
                },
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--engine")) {
            if (i + 1 >= args.len) {
                var errw = stdio.stderr();
                try errw.print("{s}: --engine requires a value\n", .{argv0});
                return error.InvalidArgument;
            }
            i += 1;
            const v = args[i];
            switch (parseEngineCompat(v)) {
                .zig => {},
                .ref => {
                    var errw = stdio.stderr();
                    try errw.print("{s}: --engine ref was removed; run ./build/lua-c/lua directly\n", .{argv0});
                    return error.InvalidArgument;
                },
                .invalid => {
                    var errw = stdio.stderr();
                    try errw.print("{s}: unknown engine '{s}'\n", .{ argv0, v });
                    return error.InvalidArgument;
                },
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--trace-ref")) {
            var errw = stdio.stderr();
            try errw.print("{s}: --trace-ref is no longer supported (no ref delegation)\n", .{argv0});
            return error.InvalidArgument;
        }
        if (std.mem.eql(u8, a, "--bc-coverage-out")) {
            if (i + 1 >= args.len) {
                var errw = stdio.stderr();
                try errw.print("{s}: --bc-coverage-out requires a path\n", .{argv0});
                return error.InvalidArgument;
            }
            i += 1;
            bc_coverage_out = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--testc")) {
            enable_testc = true;
            continue;
        }
        const vm_prefix = "--vm=";
        if (std.mem.startsWith(u8, a, vm_prefix)) {
            const v = a[vm_prefix.len..];
            backend = parseVmBackend(v) orelse {
                var errw = stdio.stderr();
                try errw.print("{s}: unknown vm backend '{s}' (expected ir|bc)\n", .{ argv0, v });
                return error.InvalidArgument;
            };
            continue;
        }
        if (std.mem.eql(u8, a, "--vm")) {
            if (i + 1 >= args.len) {
                var errw = stdio.stderr();
                try errw.print("{s}: --vm requires a value\n", .{argv0});
                return error.InvalidArgument;
            }
            i += 1;
            const v = args[i];
            backend = parseVmBackend(v) orelse {
                var errw = stdio.stderr();
                try errw.print("{s}: unknown vm backend '{s}' (expected ir|bc)\n", .{ argv0, v });
                return error.InvalidArgument;
            };
            continue;
        }

        forwarded_count += 1;
    }

    const rest = try alloc.alloc([]const u8, forwarded_count);
    defer alloc.free(rest);
    i = 1;
    var j: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) continue;

        const prefix = "--engine=";
        if (std.mem.startsWith(u8, a, prefix)) continue;
        if (std.mem.eql(u8, a, "--engine")) {
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--bc-coverage-out")) {
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--testc")) continue;
        const vm_prefix = "--vm=";
        if (std.mem.startsWith(u8, a, vm_prefix)) continue;
        if (std.mem.eql(u8, a, "--vm")) {
            i += 1;
            continue;
        }

        rest[j] = a;
        j += 1;
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    var e_chunks = std.ArrayListUnmanaged([]const u8){};
    defer e_chunks.deinit(aalloc);

    var script_path: ?[]const u8 = null;
    var k: usize = 0;
    while (k < rest.len) : (k += 1) {
        const a = rest[k];
        if (std.mem.eql(u8, a, "-e")) {
            if (k + 1 >= rest.len) {
                var errw = stdio.stderr();
                try errw.print("{s}: -e requires an argument\n", .{argv0});
                return error.InvalidArgument;
            }
            k += 1;
            try e_chunks.append(aalloc, rest[k]);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            k += 1;
            break;
        }
        if (std.mem.startsWith(u8, a, "-")) {
            var errw = stdio.stderr();
            try errw.print("{s}: unsupported option for zig engine: {s}\n", .{ argv0, a });
            return error.InvalidArgument;
        }
        script_path = a;
        k += 1;
        break;
    }

    const script_args = rest[k..];
    _ = script_args; // TODO: implement `arg` and friends.

    var vm = lua.vm.Vm.init(aalloc);
    defer vm.deinit();
    if (enable_testc) try vm.enableTestcModule();
    var bc_stats: BcCoverageStats = .{};
    const bc_stats_ptr: ?*BcCoverageStats = if (backend == .bc) &bc_stats else null;

    for (e_chunks.items) |chunk_src| {
        const source = lua.Source{ .name = "<-e>", .bytes = chunk_src };
        runZigSource(aalloc, &vm, source, backend, bc_stats_ptr) catch |err| switch (err) {
            error.SyntaxError, error.CodegenError, error.RuntimeError => std.process.exit(1),
            else => return err,
        };
    }

    if (script_path) |path| {
        const source = try lua.Source.loadFile(aalloc, path);
        runZigSource(aalloc, &vm, source, backend, bc_stats_ptr) catch |err| switch (err) {
            error.SyntaxError, error.CodegenError, error.RuntimeError => std.process.exit(1),
            else => return err,
        };
    } else if (e_chunks.items.len == 0) {
        var errw = stdio.stderr();
        try errw.print("{s}: missing input file\n", .{argv0});
        return error.InvalidArgument;
    }

    if (bc_coverage_out) |out_path| {
        const payload = try std.fmt.allocPrint(
            aalloc,
            "{{\"total_functions\":{d},\"lowered_functions\":{d},\"fallback_functions\":{d},\"total_insts\":{d},\"lowered_insts\":{d},\"fallback_insts\":{d}}}\n",
            .{
                bc_stats.total_functions,
                bc_stats.lowered_functions,
                bc_stats.fallback_functions,
                bc_stats.total_insts,
                bc_stats.lowered_insts,
                bc_stats.fallback_insts,
            },
        );
        defer aalloc.free(payload);
        try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = payload });
    }
    return;
}
