const std = @import("std");

const lua = @import("lua");
const stdio = @import("util").stdio;

fn usage(out: anytype) !void {
    try out.writeAll(
        \\luazigc (bootstrap)
        \\usage: luazigc [--engine=zig] [options] file.lua
        \\
        \\Options:
        \\  --engine=zig  accepted (no-op)
        \\  --engine=ref  removed; run ./build/lua-c/luac directly for reference behavior
        \\
        \\Compiler options:
        \\  -p            parse only (no output)
        \\  --tokens      print tokens
        \\  --ast         print AST (debug dump)
        \\  --ir          print IR (debug dump)
        \\
    );
}

fn parseEngineCompat(s: []const u8) enum { zig, ref, invalid } {
    if (std.mem.eql(u8, s, "zig")) return .zig;
    if (std.mem.eql(u8, s, "ref")) return .ref;
    return .invalid;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const argv0 = if (args.len > 0) args[0] else "luazigc";

    var rest_count: usize = 0;
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
                    try errw.print("{s}: --engine=ref was removed; run ./build/lua-c/luac directly\n", .{argv0});
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
                    try errw.print("{s}: --engine ref was removed; run ./build/lua-c/luac directly\n", .{argv0});
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

        rest_count += 1;
    }

    const rest = try alloc.alloc([]const u8, rest_count);
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

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    var parse_only = false; // currently parse-only is the default behavior
    var print_tokens = false;
    var print_ast = false;
    var print_ir = false;
    var file_path: ?[]const u8 = null;

    for (rest) |a| {
        if (std.mem.eql(u8, a, "-p")) {
            parse_only = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--tokens")) {
            print_tokens = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--ast")) {
            print_ast = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--ir")) {
            print_ir = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "-")) {
            var errw = stdio.stderr();
            try errw.print("{s}: unsupported option: {s}\n", .{ argv0, a });
            return error.InvalidArgument;
        }
        if (file_path == null) file_path = a else {
            var errw = stdio.stderr();
            try errw.print("{s}: only one input file is supported\n", .{argv0});
            return error.InvalidArgument;
        }
    }

    const path = file_path orelse {
        var errw = stdio.stderr();
        try errw.print("{s}: missing input file\n", .{argv0});
        return error.InvalidArgument;
    };

    const dbg_flags = @as(u8, @intFromBool(print_tokens)) + @as(u8, @intFromBool(print_ast)) + @as(u8, @intFromBool(print_ir));
    if (dbg_flags > 1) {
        var errw = stdio.stderr();
        try errw.print("{s}: --tokens, --ast, and --ir are mutually exclusive\n", .{argv0});
        return error.InvalidArgument;
    }

    const source = try lua.Source.loadFile(aalloc, path);
    var lex = lua.Lexer.init(source);

    if (print_tokens) {
        var out = stdio.stdout();
        while (true) {
            const tok = lex.next() catch {
                var errw = stdio.stderr();
                try errw.print("{s}\n", .{lex.diagString()});
                return error.SyntaxError;
            };
            out.print("{d}:{d}\t{s}", .{ tok.line, tok.col, tok.kind.name() }) catch |e| switch (e) {
                error.BrokenPipe => return,
                else => return e,
            };
            if (tok.kind.hasLexeme()) {
                const s = tok.slice(source.bytes);
                out.print("\t{s}", .{s}) catch |e| switch (e) {
                    error.BrokenPipe => return,
                    else => return e,
                };
            }
            out.writeByte('\n') catch |e| switch (e) {
                error.BrokenPipe => return,
                else => return e,
            };
            if (tok.kind == .Eof) break;
        }
        return;
    }

    if (print_ir) {
        var p = lua.Parser.init(&lex) catch {
            var errw = stdio.stderr();
            try errw.print("{s}\n", .{lex.diagString()});
            return error.SyntaxError;
        };

        var ast_arena = lua.ast.AstArena.init(alloc);
        defer ast_arena.deinit();

        const chunk = p.parseChunkAst(&ast_arena) catch {
            var errw = stdio.stderr();
            try errw.print("{s}\n", .{p.diagString()});
            return error.SyntaxError;
        };

        var ir_arena = std.heap.ArenaAllocator.init(alloc);
        defer ir_arena.deinit();

        var cg = lua.codegen.Codegen.init(ir_arena.allocator(), source.name, source.bytes);
        const main_fn = cg.compileChunk(chunk) catch {
            var errw = stdio.stderr();
            try errw.print("{s}\n", .{cg.diagString()});
            return error.CodegenError;
        };

        var out = stdio.stdout();
        lua.ir.dumpFunction(&out, main_fn) catch |e| switch (e) {
            error.BrokenPipe => return,
            else => return e,
        };
        return;
    }

    if (print_ast) {
        var p = lua.Parser.init(&lex) catch {
            var errw = stdio.stderr();
            try errw.print("{s}\n", .{lex.diagString()});
            return error.SyntaxError;
        };

        var ast_arena = lua.ast.AstArena.init(alloc);
        defer ast_arena.deinit();

        const chunk = p.parseChunkAst(&ast_arena) catch {
            var errw = stdio.stderr();
            try errw.print("{s}\n", .{p.diagString()});
            return error.SyntaxError;
        };

        var out = stdio.stdout();
        lua.ast.dumpChunk(&out, source.bytes, chunk) catch |e| switch (e) {
            error.BrokenPipe => return,
            else => return e,
        };
        return;
    }

    // Default: parse-only (-p) or just a syntax check for now.
    // In the future, when we have our own bytecode/IR, this is where
    // compilation would happen when `-p` is not specified.
    if (!parse_only) {
        // TODO: compile to IR/bytecode when available.
    }
    var p = lua.Parser.init(&lex) catch {
        var errw = stdio.stderr();
        try errw.print("{s}\n", .{lex.diagString()});
        return error.SyntaxError;
    };
    p.parseChunk() catch {
        var errw = stdio.stderr();
        try errw.print("{s}\n", .{p.diagString()});
        return error.SyntaxError;
    };
    return;
}
