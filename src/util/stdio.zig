const std = @import("std");

/// Small wrapper around `std.fs.File.Writer` that:
/// - avoids deprecated stdlib APIs (`deprecatedWriter`)
/// - maps `std.Io.Writer.Error` (`error.WriteFailed`) back to the underlying
///   `std.fs.File.WriteError` stored on the writer.
///
/// We intentionally use an empty buffer to keep stdout/stderr unbuffered,
/// matching the old `deprecatedWriter()` behavior and making pipes (e.g. `| head`)
/// behave as expected without needing explicit flushes.
pub const Writer = struct {
    fw: std.fs.File.Writer,
    buf: [0]u8 = .{},

    pub fn init(file: std.fs.File) Writer {
        var self: Writer = .{ .fw = undefined };
        self.fw = file.writerStreaming(self.buf[0..]);
        return self;
    }

    fn mapWriteFailed(self: *Writer) std.fs.File.WriteError {
        return self.fw.err orelse error.Unexpected;
    }

    pub fn writeAll(self: *Writer, bytes: []const u8) std.fs.File.WriteError!void {
        self.fw.interface.writeAll(bytes) catch return self.mapWriteFailed();
    }

    pub fn writeByte(self: *Writer, byte: u8) std.fs.File.WriteError!void {
        self.fw.interface.writeByte(byte) catch return self.mapWriteFailed();
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) std.fs.File.WriteError!void {
        self.fw.interface.print(fmt, args) catch return self.mapWriteFailed();
    }
};

pub fn stdout() Writer {
    return Writer.init(std.fs.File.stdout());
}

pub fn stderr() Writer {
    return Writer.init(std.fs.File.stderr());
}

