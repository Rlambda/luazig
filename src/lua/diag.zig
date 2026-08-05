const std = @import("std");

/// Maximum size for the chunk-id (matches PUC Lua's LUA_IDSIZE).
const id_size: usize = 59;

/// PUC `luaO_chunkid` (lobject.c:682-718): transform a source name into a
/// human-readable chunk identifier for error messages.
///
/// - `=foo`  → `foo`           (literal source)
/// - `@path` → `path`          (file source; truncated with `...` if too long)
/// - other  → `[string "..."]` (string source; first line, truncated)
///
/// Returns a slice into `buf` when no truncation is needed, or a slice into
/// `fallback` when the result would overflow `buf`.
pub fn chunkId(buf: []u8, source_name: []const u8) []const u8 {
    if (source_name.len == 0) {
        return std.fmt.bufPrint(buf, "[string \"\"]", .{}) catch "[string \"\"]";
    }

    const first = source_name[0];

    // Literal source: `=name` → `name`
    if (first == '=') {
        const raw = source_name[1..];
        if (raw.len <= buf.len) {
            @memcpy(buf[0..raw.len], raw);
            return buf[0..raw.len];
        }
        // Truncate to fit.
        const keep = buf.len;
        @memcpy(buf[0..keep], raw[0..keep]);
        return buf[0..keep];
    }

    // File source: `@path` → `path` (with `...` prefix if truncated)
    if (first == '@') {
        const raw = source_name[1..];
        if (raw.len <= buf.len) {
            @memcpy(buf[0..raw.len], raw);
            return buf[0..raw.len];
        }
        const rets = "...";
        if (buf.len <= rets.len) {
            @memcpy(buf[0..rets.len], rets);
            return buf[0..rets.len];
        }
        const keep = buf.len - rets.len;
        @memcpy(buf[0..rets.len], rets);
        @memcpy(buf[rets.len..buf.len], raw[raw.len - keep ..]);
        return buf[0..buf.len];
    }

    // String source: format as `[string "..."]`
    if (first == '\n' or first == '\r') {
        return std.fmt.bufPrint(buf, "[string \"...\"]", .{}) catch "[string \"...\"]";
    }

    const prefix = "[string \"";
    const suffix = "\"]";
    const rets = "...";
    // Find first newline.
    var body_end: usize = 0;
    while (body_end < source_name.len and source_name[body_end] != '\n' and source_name[body_end] != '\r') : (body_end += 1) {}
    var truncated = body_end < source_name.len;

    const max_body = if (buf.len > prefix.len + suffix.len + rets.len)
        buf.len - prefix.len - suffix.len - rets.len
    else
        0;

    var eff_end = body_end;
    if (eff_end > max_body) {
        eff_end = max_body;
        truncated = true;
    }

    if (!truncated) {
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ prefix, source_name[0..eff_end], suffix }) catch blk: {
            // Overflow — truncate with ...
            break :blk std.fmt.bufPrint(buf, "{s}{s}...{s}", .{ prefix, source_name[0..max_body], suffix }) catch "[string \"...\"]";
        };
    }
    return std.fmt.bufPrint(buf, "{s}{s}...{s}", .{ prefix, source_name[0..eff_end], suffix }) catch "[string \"...\"]";
}

pub const Diag = struct {
    source_name: []const u8,
    line: u32,
    col: u32,
    msg: []const u8,
    /// PUC's `near <token>` text, or null if no "near" suffix.
    /// For EOF this is `"<eof>"`; for tokens it's `"'end'"`, `"'foo'"`,
    /// `"<number>"`, etc. Matches PUC's `txtToken` (llex.c:104-113).
    near_token: ?[]const u8 = null,

    /// PUC `luaG_addinfo` format: `"<chunkid>:<line>: <msg>"` + optional
    /// `" near <token>"`. No column (PUC uses `%s:%d: %s`).
    pub fn format(self: Diag, writer: anytype) !void {
        var id_buf: [id_size]u8 = undefined;
        const id = chunkId(id_buf[0..], self.source_name);
        if (self.near_token) |t| {
            try writer.print("{s}:{d}: {s} near {s}", .{ id, self.line, self.msg, t });
        } else {
            try writer.print("{s}:{d}: {s}", .{ id, self.line, self.msg });
        }
    }

    /// Same as `format` but writes into a caller-provided buffer.
    /// On overflow, falls back to a shorter form (line info preserved).
    pub fn bufFormat(self: Diag, buf: []u8) []const u8 {
        var id_buf: [id_size]u8 = undefined;
        const id = chunkId(id_buf[0..], self.source_name);
        if (self.near_token) |t| {
            const s = std.fmt.bufPrint(buf, "{s}:{d}: {s} near {s}", .{ id, self.line, self.msg, t }) catch {
                return std.fmt.bufPrint(buf, "line {d}: {s}", .{ self.line, self.msg }) catch self.msg;
            };
            return s;
        } else {
            const s = std.fmt.bufPrint(buf, "{s}:{d}: {s}", .{ id, self.line, self.msg }) catch {
                return std.fmt.bufPrint(buf, "line {d}: {s}", .{ self.line, self.msg }) catch self.msg;
            };
            return s;
        }
    }
};

test "chunkId transforms literal source" {
    var buf: [id_size]u8 = undefined;
    try std.testing.expectEqualStrings("stdin", chunkId(buf[0..], "=stdin"));
    try std.testing.expectEqualStrings("foo.lua", chunkId(buf[0..], "@foo.lua"));
    try std.testing.expectEqualStrings("[string \"hello\"]", chunkId(buf[0..], "hello"));
    try std.testing.expectEqualStrings("[string \"...\"]", chunkId(buf[0..], "\nrest"));
}

test "Diag.bufFormat with near_token" {
    var buf: [256]u8 = undefined;
    const d = Diag{
        .source_name = "=stdin",
        .line = 3,
        .col = 5,
        .msg = "unfinished string",
        .near_token = "<eof>",
    };
    try std.testing.expectEqualStrings("stdin:3: unfinished string near <eof>", d.bufFormat(buf[0..]));
}

test "Diag.bufFormat without near_token" {
    var buf: [256]u8 = undefined;
    const d = Diag{
        .source_name = "@foo.lua",
        .line = 10,
        .col = 1,
        .msg = "some error",
    };
    try std.testing.expectEqualStrings("foo.lua:10: some error", d.bufFormat(buf[0..]));
}
