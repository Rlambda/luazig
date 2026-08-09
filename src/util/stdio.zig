const std = @import("std");

/// Whether `init()` or `ensureDefaultInit()` has been called.
/// Without synchronization: in the C-library scenario (no Zig `main`),
/// `luaL_newstate` is the first entry point and is typically called from a
/// single thread. If a race occurs, the worst case is redundant initialization
/// of `global_single_threaded.io()` — which is idempotent and safe.
var initialized: bool = false;

var process_io: ?std.Io = null;
var process_environ: std.process.Environ = .empty;

/// Explicit initialization, called by the `luazig` binary entry point
/// with the `std.process.Init` values.
pub fn init(process_io_value: std.Io, environ: std.process.Environ) void {
    process_io = process_io_value;
    process_environ = environ;
    initialized = true;
}

/// Lazily initialize a default I/O context when liblua.so is loaded by a C
/// program and the Zig runtime startup (`pub fn main(init: std.process.Init)`)
/// never runs. We fall back to `Io.Threaded.global_single_threaded` — the Zig
/// stdlib's pre-initialized, always-available I/O implementation that supports
/// file I/O and timestamps but not async/concurrency.
///
/// This is the C-library counterpart of what `main(init)` does for Zig
/// binaries: it provides a working `std.Io` so that `Vm.init` (which needs
/// `Io.Timestamp.now` for seed initialization) and other runtime code can
/// function. The environ is left as `.empty`; full `os.getenv` support from C
/// requires constructing a `PosixBlock` from the libc `environ` global — a
/// future enhancement.
fn ensureDefaultInit() void {
    if (initialized) return;
    initialized = true;
    process_io = std.Io.Threaded.global_single_threaded.io();
    // environ stays .empty — see comment above.
}

pub fn activeIo() std.Io {
    if (process_io) |io| return io;
    ensureDefaultInit();
    return process_io.?;
}

pub fn activeEnviron() std.process.Environ {
    if (!initialized) ensureDefaultInit();
    return process_environ;
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
