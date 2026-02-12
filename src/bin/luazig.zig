const std = @import("std");
const lua = @import("lua");
const stdio = @import("util").stdio;

const Engine = enum {
    ref,
    zig,
};

fn usage(out: anytype) !void {
    try out.writeAll(
        \\luazig (bootstrap)
        \\usage: luazig [--engine=ref|zig] [--trace-ref] [lua options] [script [args]]
        \\
        \\Engines:
        \\  ref: delegate to a reference C Lua (default)
        \\  zig: run the Zig implementation (very limited; IR interpreter)
        \\
        \\Zig engine options (subset):
        \\  -e chunk      execute string 'chunk'
        \\
        \\Env:
        \\  LUAZIG_ENGINE=ref|zig
        \\  LUAZIG_TRACE_REF=1  print delegated ref command before execution
        \\Set LUAZIG_C_LUA=/abs/path/to/lua to control which interpreter is used.
        \\
    );
}

fn parseEngineValue(s: []const u8) ?Engine {
    if (std.mem.eql(u8, s, "ref")) return .ref;
    if (std.mem.eql(u8, s, "zig")) return .zig;
    return null;
}

fn engineFromEnv() ?Engine {
    const p = std.posix.getenv("LUAZIG_ENGINE") orelse return null;
    return parseEngineValue(std.mem.sliceTo(p, 0));
}

fn findRefLua(alloc: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("LUAZIG_C_LUA")) |p| {
        return alloc.dupe(u8, std.mem.sliceTo(p, 0));
    }
    // Fallback: assume repository root is current working directory.
    return alloc.dupe(u8, "./build/lua-c/lua");
}

fn runZigSource(aalloc: std.mem.Allocator, vm: *lua.vm.Vm, source: lua.Source) !void {
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

    const ret = vm.runFunction(main_fn) catch {
        var errw = stdio.stderr();
        try errw.print("{s}\n", .{vm.errorString()});
        return error.RuntimeError;
    };
    aalloc.free(ret);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const argv0 = if (args.len > 0) args[0] else "luazig";

    var engine: Engine = engineFromEnv() orelse .ref;
    var trace_ref = false;

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
            engine = parseEngineValue(v) orelse {
                var errw = stdio.stderr();
                try errw.print("{s}: unknown engine '{s}'\n", .{ argv0, v });
                return error.InvalidArgument;
            };
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
            engine = parseEngineValue(v) orelse {
                var errw = stdio.stderr();
                try errw.print("{s}: unknown engine '{s}'\n", .{ argv0, v });
                return error.InvalidArgument;
            };
            continue;
        }
        if (std.mem.eql(u8, a, "--trace-ref")) {
            trace_ref = true;
            continue;
        }

        forwarded_count += 1;
    }
    if (!trace_ref) {
        if (std.posix.getenv("LUAZIG_TRACE_REF")) |p| {
            const v = std.mem.sliceTo(p, 0);
            trace_ref = v.len != 0 and !std.mem.eql(u8, v, "0");
        }
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
        if (std.mem.eql(u8, a, "--trace-ref")) continue;

        rest[j] = a;
        j += 1;
    }

    if (engine == .zig) {
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

        for (e_chunks.items) |chunk_src| {
            const source = lua.Source{ .name = "<-e>", .bytes = chunk_src };
            try runZigSource(aalloc, &vm, source);
        }

        if (script_path) |path| {
            const source = try lua.Source.loadFile(aalloc, path);
            try runZigSource(aalloc, &vm, source);
        } else if (e_chunks.items.len == 0) {
            var errw = stdio.stderr();
            try errw.print("{s}: missing input file\n", .{argv0});
            return error.InvalidArgument;
        }
        return;
    }

    const ref_lua = try findRefLua(alloc);
    defer alloc.free(ref_lua);

    // Reconstruct argv for the child: [ref_lua] + args excluding wrapper-only
    // flags (e.g. --engine).
    const child_argv = try alloc.alloc([]const u8, 1 + rest.len);
    defer alloc.free(child_argv);
    child_argv[0] = ref_lua;
    for (rest, 0..) |a, k| child_argv[1 + k] = a;
    if (trace_ref) {
        var errw = stdio.stderr();
        try errw.print("[luazig ref] {s}", .{child_argv[0]});
        for (child_argv[1..]) |a| try errw.print(" {s}", .{a});
        try errw.writeByte('\n');
    }

    var child = std.process.Child.init(child_argv, alloc);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| std.process.exit(code),
        .Signal => |sig| {
            // Mirror common shell behavior: 128 + signal.
            std.process.exit(128 + @as(u8, @intCast(sig)));
        },
        else => std.process.exit(1),
    }
}
