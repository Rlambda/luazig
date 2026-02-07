const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const out = std.fs.File.stdout().deprecatedWriter();
    if (args.len <= 1) {
        try out.print("luazig: stub (Lua rewrite in Zig)\n", .{});
        try out.print("usage: luazig <script.lua>\n", .{});
        return;
    }

    // Placeholder: we'll grow this into a real Lua frontend as we port components.
    try out.print("luazig: TODO execute '{s}'\n", .{args[1]});
}

test "smoke" {
    try std.testing.expect(true);
}
