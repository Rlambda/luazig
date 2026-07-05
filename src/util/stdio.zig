const std = @import("std");

var process_io: ?std.Io = null;

pub fn init(process_io_value: std.Io) void {
    process_io = process_io_value;
}

fn activeIo() std.Io {
    return process_io orelse @panic("stdio.init() must be called before stdout/stderr");
}

/// Small wrapper around `std.Io.File.Writer` that:
/// - uses the current Zig stdlib I/O API directly;
/// - maps `std.Io.Writer.Error` (`error.WriteFailed`) back to the underlying
///   `std.Io.File.Writer.Error` stored on the writer.
///
/// We intentionally use an empty buffer to keep stdout/stderr unbuffered,
/// matching the old `deprecatedWriter()` behavior and making pipes (e.g. `| head`)
/// behave as expected without needing explicit flushes.
pub const Writer = struct {
    fw: std.Io.File.Writer,
    buf: [0]u8 = .{},

    pub fn init(file: std.Io.File) Writer {
        var self: Writer = .{ .fw = undefined };
        self.fw = file.writerStreaming(activeIo(), self.buf[0..]);
        return self;
    }

    fn mapWriteFailed(self: *Writer) std.Io.File.Writer.Error {
        return self.fw.err orelse error.Unexpected;
    }

    pub fn writeAll(self: *Writer, bytes: []const u8) std.Io.File.Writer.Error!void {
        self.fw.interface.writeAll(bytes) catch return self.mapWriteFailed();
    }

    pub fn writeByte(self: *Writer, byte: u8) std.Io.File.Writer.Error!void {
        self.fw.interface.writeByte(byte) catch return self.mapWriteFailed();
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) std.Io.File.Writer.Error!void {
        self.fw.interface.print(fmt, args) catch return self.mapWriteFailed();
    }
};

pub fn stdout() Writer {
    return Writer.init(std.Io.File.stdout());
}

pub fn stderr() Writer {
    return Writer.init(std.Io.File.stderr());
}
