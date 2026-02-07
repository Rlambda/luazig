const std = @import("std");

const lua = @import("lua");

const Engine = enum {
    ref,
    zig,
};

fn usage(out: anytype) !void {
    try out.writeAll(
        \\luazigc (bootstrap)
        \\usage: luazigc [--engine=ref|zig] [options] file.lua
        \\
        \\Engines:
        \\  ref: delegate to a reference C luac (default)
        \\  zig: run the Zig compiler (parse/tokenize only for now)
        \\
        \\Zig engine options:
        \\  -p            parse only (no output)
        \\  --tokens      print tokens
        \\  --ast         print AST (debug dump)
        \\  --ir          print IR (debug dump)
        \\
        \\Env:
        \\  LUAZIG_ENGINE=ref|zig
        \\Set LUAZIG_C_LUAC=/abs/path/to/luac to control which compiler is used.
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

fn findRefLuac(alloc: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("LUAZIG_C_LUAC")) |p| {
        return alloc.dupe(u8, std.mem.sliceTo(p, 0));
    }
    return alloc.dupe(u8, "./build/lua-c/luac");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const argv0 = if (args.len > 0) args[0] else "luazigc";

    var engine: Engine = engineFromEnv() orelse .ref;

    var rest_count: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            const out = std.fs.File.stdout().deprecatedWriter();
            try usage(out);
            return;
        }

        const prefix = "--engine=";
        if (std.mem.startsWith(u8, a, prefix)) {
            const v = a[prefix.len..];
            engine = parseEngineValue(v) orelse {
                const errw = std.fs.File.stderr().deprecatedWriter();
                try errw.print("{s}: unknown engine '{s}'\n", .{ argv0, v });
                return error.InvalidArgument;
            };
            continue;
        }
        if (std.mem.eql(u8, a, "--engine")) {
            if (i + 1 >= args.len) {
                const errw = std.fs.File.stderr().deprecatedWriter();
                try errw.print("{s}: --engine requires a value\n", .{argv0});
                return error.InvalidArgument;
            }
            i += 1;
            const v = args[i];
            engine = parseEngineValue(v) orelse {
                const errw = std.fs.File.stderr().deprecatedWriter();
                try errw.print("{s}: unknown engine '{s}'\n", .{ argv0, v });
                return error.InvalidArgument;
            };
            continue;
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

        rest[j] = a;
        j += 1;
    }

    if (engine == .zig) {
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
                const errw = std.fs.File.stderr().deprecatedWriter();
                try errw.print("{s}: unsupported option for zig engine: {s}\n", .{ argv0, a });
                return error.InvalidArgument;
            }
            if (file_path == null) file_path = a else {
                const errw = std.fs.File.stderr().deprecatedWriter();
                try errw.print("{s}: only one input file is supported for zig engine\n", .{argv0});
                return error.InvalidArgument;
            }
        }

        const path = file_path orelse {
            const errw = std.fs.File.stderr().deprecatedWriter();
            try errw.print("{s}: missing input file\n", .{argv0});
            return error.InvalidArgument;
        };

        const dbg_flags = @as(u8, @intFromBool(print_tokens)) + @as(u8, @intFromBool(print_ast)) + @as(u8, @intFromBool(print_ir));
        if (dbg_flags > 1) {
            const errw = std.fs.File.stderr().deprecatedWriter();
            try errw.print("{s}: --tokens, --ast, and --ir are mutually exclusive\n", .{argv0});
            return error.InvalidArgument;
        }

        const source = try lua.Source.loadFile(aalloc, path);
        var lex = lua.Lexer.init(source);

        if (print_tokens) {
            const out = std.fs.File.stdout().deprecatedWriter();
            while (true) {
                const tok = lex.next() catch {
                    const errw = std.fs.File.stderr().deprecatedWriter();
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
                const errw = std.fs.File.stderr().deprecatedWriter();
                try errw.print("{s}\n", .{lex.diagString()});
                return error.SyntaxError;
            };

            var ast_arena = lua.ast.AstArena.init(alloc);
            defer ast_arena.deinit();

            const chunk = p.parseChunkAst(&ast_arena) catch {
                const errw = std.fs.File.stderr().deprecatedWriter();
                try errw.print("{s}\n", .{p.diagString()});
                return error.SyntaxError;
            };

            var ir_arena = std.heap.ArenaAllocator.init(alloc);
            defer ir_arena.deinit();

            var cg = lua.codegen.Codegen.init(ir_arena.allocator(), source.name, source.bytes);
            const main_fn = cg.compileChunk(chunk) catch {
                const errw = std.fs.File.stderr().deprecatedWriter();
                try errw.print("{s}\n", .{cg.diagString()});
                return error.CodegenError;
            };

            const out = std.fs.File.stdout().deprecatedWriter();
            lua.ir.dumpFunction(out, main_fn) catch |e| switch (e) {
                error.BrokenPipe => return,
                else => return e,
            };
            return;
        }

        if (print_ast) {
            var p = lua.Parser.init(&lex) catch {
                const errw = std.fs.File.stderr().deprecatedWriter();
                try errw.print("{s}\n", .{lex.diagString()});
                return error.SyntaxError;
            };

            var ast_arena = lua.ast.AstArena.init(alloc);
            defer ast_arena.deinit();

            const chunk = p.parseChunkAst(&ast_arena) catch {
                const errw = std.fs.File.stderr().deprecatedWriter();
                try errw.print("{s}\n", .{p.diagString()});
                return error.SyntaxError;
            };

            const out = std.fs.File.stdout().deprecatedWriter();
            lua.ast.dumpChunk(out, source.bytes, chunk) catch |e| switch (e) {
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
            const errw = std.fs.File.stderr().deprecatedWriter();
            try errw.print("{s}\n", .{lex.diagString()});
            return error.SyntaxError;
        };
        p.parseChunk() catch {
            const errw = std.fs.File.stderr().deprecatedWriter();
            try errw.print("{s}\n", .{p.diagString()});
            return error.SyntaxError;
        };
        return;
    }

    const ref_luac = try findRefLuac(alloc);
    defer alloc.free(ref_luac);

    const child_argv = try alloc.alloc([]const u8, 1 + rest.len);
    defer alloc.free(child_argv);
    child_argv[0] = ref_luac;
    for (rest, 0..) |a, k| child_argv[1 + k] = a;

    var child = std.process.Child.init(child_argv, alloc);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| std.process.exit(code),
        .Signal => |sig| std.process.exit(128 + @as(u8, @intCast(sig))),
        else => std.process.exit(1),
    }
}
