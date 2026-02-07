const std = @import("std");

pub const Diag = struct {
    source_name: []const u8,
    line: u32,
    col: u32,
    msg: []const u8,

    pub fn format(self: Diag, writer: anytype) !void {
        try writer.print("{s}:{d}:{d}: {s}", .{ self.source_name, self.line, self.col, self.msg });
    }

    pub fn bufFormat(self: Diag, buf: []u8) []const u8 {
        const s = std.fmt.bufPrint(buf, "{s}:{d}:{d}: {s}", .{ self.source_name, self.line, self.col, self.msg }) catch {
            // Best-effort on overflow.
            return self.msg;
        };
        return s;
    }
};

