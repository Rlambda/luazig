const std = @import("std");

pub const Source = struct {
    name: []const u8,
    bytes: []const u8,

    pub fn loadFile(alloc: std.mem.Allocator, path: []const u8) !Source {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        // Lua tests can be sizable; keep a reasonable cap to avoid OOM on accidents.
        const max_bytes: usize = 64 * 1024 * 1024;
        const bytes = try file.readToEndAlloc(alloc, max_bytes);
        const name = try alloc.dupe(u8, path);
        return .{ .name = name, .bytes = bytes };
    }
};

