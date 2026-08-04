const std = @import("std");

pub const Source = struct {
    name: []const u8,
    bytes: []const u8,

    pub fn loadFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Source {
        const max_bytes: usize = 64 * 1024 * 1024;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_bytes));
        const name = try std.fmt.allocPrint(alloc, "@{s}", .{path});
        return .{ .name = name, .bytes = bytes };
    }

    /// Read entire stdin as a Lua script. Used by the PUC `-` option
    /// (`lua - < script.lua`). Returns a Source with name "@stdin".
    pub fn loadStdin(alloc: std.mem.Allocator, io: std.Io) !Source {
        const stdin = std.Io.File.stdin();
        var list = std.ArrayList(u8).empty;
        defer list.deinit(alloc);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = stdin.readStreaming(io, &.{buf[0..]}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => break,
            };
            if (n == 0) break;
            try list.appendSlice(alloc, buf[0..n]);
        }
        const bytes = try list.toOwnedSlice(alloc);
        const name = try alloc.dupe(u8, "@stdin");
        return .{ .name = name, .bytes = bytes };
    }
};
