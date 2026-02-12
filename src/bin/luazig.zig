const std = @import("std");
const lua = @import("lua");
const stdio = @import("util").stdio;

fn usage(out: anytype) !void {
    try out.writeAll(
        \\luazig
        \\usage: luazig [lua options] [script [args]]
        \\
        \\Zig engine options (subset):
        \\  -e chunk      execute string 'chunk'
        \\
        \\Compatibility:
        \\  --engine=zig  accepted (no-op)
        \\  --engine=ref  removed; run build/lua-c/lua directly for reference behavior
        \\
    );
}

fn parseEngineCompat(s: []const u8) enum { zig, ref, invalid } {
    if (std.mem.eql(u8, s, "zig")) return .zig;
    if (std.mem.eql(u8, s, "ref")) return .ref;
    return .invalid;
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
