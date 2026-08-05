// Binary chunk writer — serializes a Proto tree into a PUC-compatible
// header + luazig-native body.
//
// The header is byte-for-byte identical to PUC Lua 5.5's luac output
// (so the chunk is detectable via the leading 0x1b signature byte and
// passes PUC's `validateBinaryDumpHeader`). The body uses luazig-native
// encoding: opcodes are written as-is (no opcode remapping), and the
// field order mirrors Proto's layout in bytecode.zig.
//
// This is the write side of the binary chunk format; the read side lives
// in vm.zig (loadChunk / instantiateLoadedClosure). Keeping the writer
// independent of vm.zig avoids pulling the entire VM into tools that
// only need to emit bytecode (e.g. a future standalone luac).

const std = @import("std");
const bc = @import("bytecode.zig");

// ---------------------------------------------------------------------------
// DumpWriter — buffered binary writer with primitive encoders
// ---------------------------------------------------------------------------

/// A growable byte buffer that knows how to encode each field type used by
/// the binary chunk format. All multi-byte fixed-width integers are written
/// little-endian, matching PUC Lua's on-disk format (LUAC_DATA alignment).
pub const DumpWriter = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    alloc: std.mem.Allocator,
    /// String dedup table: maps string content → unique index.
    /// Used only for string constants (dumpConstant tag 5).
    /// Mirrors PUC Lua's `dumpString` dedup mechanism (ldump.c:143-168).
    string_dedup: std.StringHashMapUnmanaged(u32) = .{},
    string_dedup_count: u32 = 0,

    pub fn init(alloc: std.mem.Allocator) DumpWriter {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DumpWriter) void {
        self.buf.deinit(self.alloc);
        self.string_dedup.deinit(self.alloc);
    }

    /// Owned bytes. Caller becomes responsible for freeing the returned slice
    /// with the same allocator that was passed to `init`.
    pub fn toOwnedSlice(self: *DumpWriter) ![]u8 {
        return self.buf.toOwnedSlice(self.alloc);
    }

    // --- Primitive encoders ---

    /// Write a single byte.
    pub fn writeByte(self: *DumpWriter, b: u8) !void {
        try self.buf.append(self.alloc, b);
    }

    /// Write raw bytes verbatim.
    pub fn writeBlock(self: *DumpWriter, data: []const u8) !void {
        try self.buf.appendSlice(self.alloc, data);
    }

    /// LEB128 variable-length unsigned integer encoding.
    /// Emits 7 bits per byte; the high bit (0x80) is set on every byte
    /// except the last. This matches PUC Lua's `dumpSize` for sizes that
    /// fit in a Lua integer, and keeps chunk sizes compact for small
    /// protos (the common case).
    pub fn writeVarint(self: *DumpWriter, value: u64) !void {
        var v = value;
        while (v >= 0x80) {
            try self.buf.append(self.alloc, @as(u8, @intCast(v & 0x7F)) | 0x80);
            v >>= 7;
        }
        try self.buf.append(self.alloc, @as(u8, @intCast(v)));
    }

    /// A u32 encoded as a varint. Used for lengths and line numbers.
    pub fn writeU32(self: *DumpWriter, value: u32) !void {
        try self.writeVarint(value);
    }

    /// A raw u32 in fixed little-endian layout. Used for Instruction words,
    /// which must be byte-stable (the VM reinterprets them directly).
    pub fn writeU32LE(self: *DumpWriter, value: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, value, .little);
        try self.buf.appendSlice(self.alloc, &b);
    }

    /// A raw i64 in fixed little-endian layout. Used for integer constants.
    pub fn writeI64LE(self: *DumpWriter, value: i64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(i64, &b, value, .little);
        try self.buf.appendSlice(self.alloc, &b);
    }

    /// A raw f64 in fixed little-endian layout. The bit pattern is obtained
    /// via @bitCast so NaN payloads are preserved exactly.
    pub fn writeF64LE(self: *DumpWriter, value: f64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, @bitCast(value), .little);
        try self.buf.appendSlice(self.alloc, &b);
    }

    /// A Lua string: varint length prefix followed by raw bytes (no NUL).
    /// An empty string is encoded as a length-0 prefix with no payload.
    pub fn writeString(self: *DumpWriter, s: []const u8) !void {
        try self.writeVarint(s.len);
        try self.buf.appendSlice(self.alloc, s);
    }

    // --- Header ---

    /// Write the 40-byte PUC Lua 5.5 binary chunk header.
    ///
    /// Layout (offset: size  value):
    ///   0:4   "\x1bLua"           LUA_SIGNATURE
    ///   4:1   0x55                LUAC_VERSION = 5*16+5
    ///   5:1   0x00                LUAC_FORMAT
    ///   6:6   "\x19\x93\r\n\x1a\n" LUAC_DATA (alignment + sanity check)
    ///  12:1   4                   sizeof(int)
    ///  13:4   i32 LE -0x5678      endianness check for int
    ///  17:1   4                   sizeof(Instruction)
    ///  18:4   u32 LE 0x12345678   endianness check for Instruction
    ///  22:1   8                   sizeof(lua_Integer)
    ///  23:8   i64 LE -0x5678      endianness check for lua_Integer
    ///  31:1   8                   sizeof(lua_Number)
    ///  32:8   f64 LE -370.5       endianness check for lua_Number
    ///
    /// This must stay byte-identical to `Vm.appendBinaryDumpHeader` in
    /// vm.zig so that the loader's `validateBinaryDumpHeader` accepts
    /// chunks produced by this writer.
    pub fn writeHeader(self: *DumpWriter) !void {
        try self.buf.appendSlice(self.alloc, "\x1bLua");
        try self.buf.append(self.alloc, 0x55); // Lua 5.5 version marker
        try self.buf.append(self.alloc, 0x00); // format
        try self.buf.appendSlice(self.alloc, "\x19\x93\r\n\x1a\n");

        try self.buf.append(self.alloc, 4); // sizeof(int)
        var i4_buf: [4]u8 = undefined;
        std.mem.writeInt(i32, &i4_buf, -0x5678, .little);
        try self.buf.appendSlice(self.alloc, &i4_buf);

        try self.buf.append(self.alloc, 4); // sizeof(Instruction)
        var instr_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &instr_buf, 0x12345678, .little);
        try self.buf.appendSlice(self.alloc, &instr_buf);

        try self.buf.append(self.alloc, 8); // sizeof(lua_Integer)
        var i_buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &i_buf, -0x5678, .little);
        try self.buf.appendSlice(self.alloc, &i_buf);

        try self.buf.append(self.alloc, 8); // sizeof(lua_Number)
        var n_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &n_buf, @bitCast(@as(f64, -370.5)), .little);
        try self.buf.appendSlice(self.alloc, &n_buf);
    }

    // --- Proto serialization ---

    /// Serialize a single constant in the binary chunk's constant-tag format.
    ///
    /// Tag byte mapping (matches PUC Lua 5.5's LUA_V* constants used by
    /// `dumpConstant` in lundump.c):
    ///   0 = nil
    ///   1 = false
    ///   2 = true
    ///   3 = integer (followed by i64 LE)
    ///   4 = number  (followed by raw u64 LE — the f64 bit pattern)
    ///   5 = string  (followed by writeString)
    pub fn dumpConstant(self: *DumpWriter, c: bc.Constant) !void {
        switch (c) {
            .nil => try self.writeByte(0),
            .bool => |b| try self.writeByte(if (b) 2 else 1),
            .int => |i| {
                try self.writeByte(3);
                try self.writeI64LE(i);
            },
            .num_bits => |bits| {
                try self.writeByte(4);
                // Store the raw bits directly — exact, no float rounding.
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, bits, .little);
                try self.buf.appendSlice(self.alloc, &b);
            },
            .str => |ls| {
                try self.writeByte(5);
                // String dedup: if this string was already serialized,
                // write a back-reference (varint(0) + varint(index)).
                // Otherwise, write varint(len+1) + bytes and register it.
                const bytes = ls.bytes();
                if (self.string_dedup.get(bytes)) |idx| {
                    // Back-reference: length 0 means "dedup", followed by index.
                    try self.writeVarint(0);
                    try self.writeVarint(idx);
                } else {
                    // New string: write (len+1) so that 0 is reserved for dedup.
                    try self.writeVarint(@as(u64, @intCast(bytes.len)) + 1);
                    try self.writeBlock(bytes);
                    self.string_dedup_count += 1;
                    try self.string_dedup.put(self.alloc, bytes, self.string_dedup_count);
                }
            },
        }
    }

    /// Serialize a Proto recursively.
    ///
    /// Field order (luazig-native body):
    ///   1.  source_name           string
    ///   2.  name                  string
    ///   3.  line_defined          u32 (varint)
    ///   4.  last_line_defined     u32 (varint)
    ///   5.  numparams             byte
    ///   6.  maxstacksize          byte
    ///   7.  flags                 byte (bit 0 = is_vararg, bit 1 = has vararg_table_reg)
    ///   8.  vararg_table_reg      byte (only if flags bit 1 set)
    ///   9.  code.len              u32, then each Instruction as u32 LE
    ///  10.  k.len                 u32, then each Constant via dumpConstant
    ///  11.  upvalues.len          u32, then each: instack byte, idx byte, is_const byte
    ///  12.  p.len                 u32, then each child Proto recursively
    ///  13.  lineinfo.len          u32, then each entry as u32 (absolute line numbers)
    ///  14.  locvars.len           u32, then each: name string, reg byte, startpc u32, endpc u32
    pub fn dumpProto(self: *DumpWriter, proto: *const bc.Proto) !void {
        try self.dumpProtoImpl(proto, true);
    }

    fn dumpProtoImpl(self: *DumpWriter, proto: *const bc.Proto, is_main: bool) !void {
        // 1. Source name — only the main proto has a source name; inner
        // protos inherit it from the parent (matching PUC Lua's ldump.c
        // which writes NULL source for non-main functions).
        if (is_main) {
            try self.writeString(proto.source_name);
        } else {
            try self.writeString("");
        }
        // 2. Function name.
        try self.writeString(proto.name);
        // 3-4. Line range.
        try self.writeU32(proto.line_defined);
        try self.writeU32(proto.last_line_defined);
        // 5-6. Parameter / register counts.
        try self.writeByte(proto.numparams);
        try self.writeByte(proto.maxstacksize);

        // 7. Flags byte: bit 0 = is_vararg, bit 1 = has vararg_table_reg.
        const has_vararg_table = (proto.vararg_table_reg != null);
        const flags: u8 = (@as(u8, @intFromBool(proto.is_vararg)) & 1) |
            ((@as(u8, @intFromBool(has_vararg_table)) & 1) << 1);
        try self.writeByte(flags);

        // 8. vararg_table_reg — only present when flags bit 1 is set.
        if (has_vararg_table) {
            try self.writeByte(proto.vararg_table_reg.?);
        }

        // 9. Code: length prefix, then each instruction as a raw u32 LE word.
        try self.writeU32(@intCast(proto.code.len));
        for (proto.code) |inst| {
            const raw: u32 = @bitCast(inst);
            try self.writeU32LE(raw);
        }

        // 10. Constants: length prefix, then each via dumpConstant.
        try self.writeU32(@intCast(proto.k.len));
        for (proto.k) |c| {
            try self.dumpConstant(c);
        }

        // 11. Upvalues: length prefix, then each as (instack, idx, is_const, name).
        try self.writeU32(@intCast(proto.upvalues.len));
        for (proto.upvalues) |uv| {
            try self.writeByte(@intFromBool(uv.instack));
            try self.writeByte(uv.idx);
            try self.writeByte(@intFromBool(uv.is_const));
            try self.writeString(uv.name);
        }

        // 12. Inner protos: length prefix, then each child recursively.
        try self.writeU32(@intCast(proto.p.len));
        for (proto.p) |child| {
            try self.dumpProtoImpl(child, false);
        }

        // 13. Line info: length prefix, then each absolute line number as u32.
        try self.writeU32(@intCast(proto.lineinfo.len));
        for (proto.lineinfo) |line| {
            try self.writeU32(line);
        }

        // 14. Locals: length prefix, then each as (name, reg, startpc, endpc).
        try self.writeU32(@intCast(proto.locvars.len));
        for (proto.locvars) |lv| {
            try self.writeString(lv.name);
            try self.writeByte(lv.reg);
            try self.writeU32(lv.startpc);
            try self.writeU32(lv.endpc);
        }
    }

    // --- Entry point ---

    /// Serialize a complete binary chunk: 40-byte header, upvalue count for
    /// the main function, then the main Proto tree.
    ///
    /// The single byte after the header is the main function's upvalue count
    /// (PUC writes `sizeupvalues` here). The body that follows is the main
    /// Proto serialized via `dumpProto`.
    pub fn dumpChunk(self: *DumpWriter, main: *const bc.Proto) !void {
        try self.writeHeader();
        try self.writeByte(@intCast(main.upvalues.len));
        try self.dumpProto(main);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "DumpWriter: writeByte and writeBlock" {
    var w = DumpWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.writeByte(0xAB);
    try w.writeBlock("hello");
    try std.testing.expectEqualSlices(u8, &.{ 0xAB, 'h', 'e', 'l', 'l', 'o' }, w.buf.items);
}

test "DumpWriter: writeVarint LEB128" {
    var w = DumpWriter.init(std.testing.allocator);
    defer w.deinit();

    // 0 → single byte 0x00
    try w.writeVarint(0);
    // 127 → single byte 0x7F (max single-byte value)
    try w.writeVarint(127);
    // 128 → two bytes: 0x80 0x01
    try w.writeVarint(128);
    // 300 → 0xAC 0x02 (300 = 0b100101100 → low 7 = 0101100=0x2C with cont, high = 10=0x02)
    try w.writeVarint(300);

    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x7F, 0x80, 0x01, 0xAC, 0x02,
    }, w.buf.items);
}

test "DumpWriter: writeU32LE little-endian" {
    var w = DumpWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.writeU32LE(0x12345678);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, w.buf.items);
}

test "DumpWriter: writeI64LE little-endian" {
    var w = DumpWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.writeI64LE(-0x5678);
    // -0x5678 = 0xFFFFFFFFFFFFA988
    try std.testing.expectEqualSlices(u8, &.{
        0x88, 0xA9, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    }, w.buf.items);
}

test "DumpWriter: writeF64LE preserves bit pattern" {
    var w = DumpWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.writeF64LE(-370.5);
    // Round-trip: the bytes should decode back to -370.5.
    const items = w.buf.items;
    try std.testing.expect(items.len == 8);
    const bits = std.mem.readInt(u64, items[0..8], .little);
    const f: f64 = @bitCast(bits);
    try std.testing.expectEqual(@as(f64, -370.5), f);
}

test "DumpWriter: writeString length-prefixed" {
    var w = DumpWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.writeString("hi");
    try std.testing.expectEqualSlices(u8, &.{ 2, 'h', 'i' }, w.buf.items);

    // Empty string: just a 0 length byte.
    try w.writeString("");
    try std.testing.expectEqual(@as(usize, 4), w.buf.items.len);
    try std.testing.expectEqual(@as(u8, 0), w.buf.items[3]);
}

test "DumpWriter: writeHeader is 40 bytes and starts with 0x1bLua" {
    var w = DumpWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.writeHeader();
    try std.testing.expectEqual(@as(usize, 40), w.buf.items.len);
    try std.testing.expectEqualSlices(u8, "\x1bLua", w.buf.items[0..4]);
    // Version byte.
    try std.testing.expectEqual(@as(u8, 0x55), w.buf.items[4]);
    // Format byte.
    try std.testing.expectEqual(@as(u8, 0x00), w.buf.items[5]);
    // LUAC_DATA.
    try std.testing.expectEqualSlices(u8, "\x19\x93\r\n\x1a\n", w.buf.items[6..12]);
    // sizeof(int) = 4.
    try std.testing.expectEqual(@as(u8, 4), w.buf.items[12]);
    // int check value -0x5678 little-endian.
    const int_val = std.mem.readInt(i32, w.buf.items[13..17], .little);
    try std.testing.expectEqual(@as(i32, -0x5678), int_val);
    // sizeof(Instruction) = 4.
    try std.testing.expectEqual(@as(u8, 4), w.buf.items[17]);
    // Instruction check value 0x12345678 little-endian.
    const instr = std.mem.readInt(u32, w.buf.items[18..22], .little);
    try std.testing.expectEqual(@as(u32, 0x12345678), instr);
    // sizeof(lua_Integer) = 8.
    try std.testing.expectEqual(@as(u8, 8), w.buf.items[22]);
    // lua_Integer check value -0x5678 little-endian.
    const i64_val = std.mem.readInt(i64, w.buf.items[23..31], .little);
    try std.testing.expectEqual(@as(i64, -0x5678), i64_val);
    // sizeof(lua_Number) = 8.
    try std.testing.expectEqual(@as(u8, 8), w.buf.items[31]);
    // lua_Number check value -370.5.
    const nbits = std.mem.readInt(u64, w.buf.items[32..40], .little);
    const nf: f64 = @bitCast(nbits);
    try std.testing.expectEqual(@as(f64, -370.5), nf);
}

test "DumpWriter: dumpConstant nil/bool/int/num" {
    var w = DumpWriter.init(std.testing.allocator);
    defer w.deinit();

    try w.dumpConstant(.nil);
    try w.dumpConstant(.{ .bool = false });
    try w.dumpConstant(.{ .bool = true });
    try w.dumpConstant(.{ .int = -1 });
    try w.dumpConstant(.{ .num_bits = @bitCast(@as(f64, 3.14)) });

    // nil → [0]
    // false → [1]
    // true → [2]
    // int -1 → [3, 0xFF*8]
    // num 3.14 → [4, <8 bytes>]
    try std.testing.expectEqual(@as(u8, 0), w.buf.items[0]);
    try std.testing.expectEqual(@as(u8, 1), w.buf.items[1]);
    try std.testing.expectEqual(@as(u8, 2), w.buf.items[2]);
    try std.testing.expectEqual(@as(u8, 3), w.buf.items[3]);
    const i_val = std.mem.readInt(i64, w.buf.items[4..12], .little);
    try std.testing.expectEqual(@as(i64, -1), i_val);
    try std.testing.expectEqual(@as(u8, 4), w.buf.items[12]);
    const n_bits = std.mem.readInt(u64, w.buf.items[13..21], .little);
    const nf: f64 = @bitCast(n_bits);
    try std.testing.expectEqual(@as(f64, 3.14), nf);
}
