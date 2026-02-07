const std = @import("std");

const Engine = enum {
    ref,
    zig,
};

fn usage(out: anytype) !void {
    try out.writeAll(
        \\luazig (bootstrap)
        \\usage: luazig [--engine=ref|zig] [lua options] [script [args]]
        \\
        \\Engines:
        \\  ref: delegate to a reference C Lua (default)
        \\  zig: run the Zig implementation (not wired yet)
        \\
        \\Env:
        \\  LUAZIG_ENGINE=ref|zig
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const argv0 = if (args.len > 0) args[0] else "luazig";

    var engine: Engine = engineFromEnv() orelse .ref;

    var forwarded_count: usize = 0;
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

        forwarded_count += 1;
    }

    if (engine == .zig) {
        const errw = std.fs.File.stderr().deprecatedWriter();
        try errw.print("{s}: Zig engine not implemented yet\n", .{argv0});
        return error.NotImplemented;
    }

    const ref_lua = try findRefLua(alloc);
    defer alloc.free(ref_lua);

    // Reconstruct argv for the child: [ref_lua] + original args after argv0,
    // excluding wrapper-only flags (e.g. --engine).
    const child_argv = try alloc.alloc([]const u8, 1 + forwarded_count);
    defer alloc.free(child_argv);
    child_argv[0] = ref_lua;

    i = 1;
    var j: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) continue;

        const prefix = "--engine=";
        if (std.mem.startsWith(u8, a, prefix)) continue;
        if (std.mem.eql(u8, a, "--engine")) {
            i += 1;
            continue;
        }

        child_argv[j] = a;
        j += 1;
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
