// Binary chunk reader — deserializes the format produced by dump.zig.
//
// This is the read side of the binary chunk format; the write side lives in
// dump.zig. The two modules are exact mirrors: every field written by
// `DumpWriter.dumpProto` is read back in the same order by
// `UndumpReader.undumpProto`.
//
// The 40-byte PUC Lua 5.5 header is validated byte-by-byte so that chunks
// produced by PUC's `luac` (or by `DumpWriter.writeHeader`) are accepted
// when their body layout matches ours. The body uses luazig-native encoding:
// opcodes are read as-is (no opcode remapping), and the field order mirrors
// Proto's layout in bytecode.zig.
//
// String constants are interned through a caller-provided callback so that
// the deserialized Proto is immediately executable: its `.str` constants
// point at VM-interned `*LuaString` objects, exactly like PUC Lua's
// `lundump.c`, which calls `luaS_new` (the VM's string interner) while
// reading constants. The callback keeps undump.zig free of a direct vm.zig
// dependency (avoiding a circular import) while preserving PUC's
// architecture: strings are interned during undump, not deferred.

const std = @import("std");
const bc = @import("bytecode.zig");

// ---------------------------------------------------------------------------
// UndumpError — the error set for all reader operations
// ---------------------------------------------------------------------------

pub const UndumpError = error{
    TruncatedChunk,
    BadHeader,
    BadConstant,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// UndumpReader — buffered binary reader with primitive decoders
// ---------------------------------------------------------------------------

/// A cursor over a `[]const u8` buffer that knows how to decode each field
/// type used by the binary chunk format. All multi-byte fixed-width integers
/// are read little-endian, matching PUC Lua's on-disk format. Variable-length
/// sizes use LEB128, the inverse of `DumpWriter.writeVarint`.
pub const UndumpReader = struct {
    /// The full input buffer (does not own the bytes).
    data: []const u8,
    /// Current read cursor.
    pos: usize = 0,
    /// Allocator used for all Proto-owned arrays.
    alloc: std.mem.Allocator,
    /// String interning callback. Called once per string constant encountered
    /// during deserialization, with the raw bytes of the string. The callback
    /// returns a pointer to the interned `*LuaString` (as `*anyopaque` to keep
    /// this module free of a vm.zig import). When null, string constants are
    /// left as `.str = undefined` and the caller must patch them up before
    /// first execution. Mirrors PUC Lua's `luaS_new` call in `lundump.c`.
    internFn: ?*const fn (ctx: *anyopaque, bytes: []const u8) anyerror!*anyopaque = null,
    /// Opaque context passed as the first argument to `internFn`. In vm.zig
    /// this is `@ptrCast(self: *Vm)`.
    internCtx: ?*anyopaque = null,
    /// String dedup table: stores raw string bytes by index.
    /// Matches the writer's dedup mechanism for ALL strings.
    string_dedup: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(alloc: std.mem.Allocator, data: []const u8) UndumpReader {
        return .{ .data = data, .alloc = alloc };
    }

    pub fn deinit(self: *UndumpReader) void {
        self.string_dedup.deinit(self.alloc);
    }

    // --- Primitive decoders ---

    /// Read a single byte. Returns `TruncatedChunk` if the cursor is at EOF.
    pub fn readByte(self: *UndumpReader) UndumpError!u8 {
        if (self.pos >= self.data.len) return error.TruncatedChunk;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    /// Read `len` raw bytes. Returns `TruncatedChunk` if fewer than `len`
    /// bytes remain. The returned slice aliases the input buffer — it is
    /// not owned by the caller and must be copied if it needs to outlive
    /// the input.
    pub fn readBlock(self: *UndumpReader, len: usize) UndumpError![]const u8 {
        if (self.pos + len > self.data.len) return error.TruncatedChunk;
        const slice = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }

    /// Read a raw u32 in fixed little-endian layout. Used for Instruction
    /// words, which the VM reinterprets directly via `@bitCast`.
    pub fn readU32LE(self: *UndumpReader) UndumpError!u32 {
        const buf = try self.readBlock(4);
        return std.mem.readInt(u32, buf[0..4], .little);
    }

    /// Read a raw i64 in fixed little-endian layout. Used for integer
    /// constants.
    pub fn readI64LE(self: *UndumpReader) UndumpError!i64 {
        const buf = try self.readBlock(8);
        return std.mem.readInt(i64, buf[0..8], .little);
    }

    /// Read a raw u64 in fixed little-endian layout. Used for the f64 bit
    /// pattern of number constants (the inverse of `DumpWriter.writeF64LE`
    /// / the `num_bits` branch of `dumpConstant`).
    pub fn readU64LE(self: *UndumpReader) UndumpError!u64 {
        const buf = try self.readBlock(8);
        return std.mem.readInt(u64, buf[0..8], .little);
    }

    /// LEB128 variable-length unsigned integer decoding.
    /// Reads 7 bits per byte; the high bit (0x80) is set on every byte
    /// except the last. This is the inverse of `DumpWriter.writeVarint`.
    pub fn readVarint(self: *UndumpReader) UndumpError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.readByte();
            // Accumulate the low 7 bits at the current shift position.
            // The cast is safe: `b & 0x7F` is at most 127, which fits in u64.
            result |= @as(u64, b & 0x7F) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
            // Guard against overflow: a u64 needs at most 10 LEB128 bytes
            // (10 * 7 = 70 bits, but the 10th byte contributes only 1 bit).
            // If we ever advance past 10 continuation bytes, the input is
            // malformed.
            if (shift >= 64) return error.BadHeader;
        }
        return result;
    }

    /// A u32 encoded as a varint. Used for lengths and line numbers.
    /// The inverse of `DumpWriter.writeU32`.
    pub fn readU32(self: *UndumpReader) UndumpError!u32 {
        const v = try self.readVarint();
        return @intCast(v);
    }

    /// A Lua string: varint length prefix followed by raw bytes (no NUL).
    /// The inverse of `DumpWriter.writeString`. The returned slice aliases
    /// the input buffer; callers that need ownership must copy.
    pub fn readString(self: *UndumpReader) UndumpError![]const u8 {
        const len = try self.readU32();
        return try self.readBlock(@intCast(len));
    }

    /// Read a dedup-encoded string (matching DumpWriter.writeStringDedup).
    /// Format: varint(0)+varint(index) = back-reference; varint(n)+bytes = new.
    pub fn readStringDedup(self: *UndumpReader) UndumpError![]const u8 {
        const first = try self.readVarint();
        if (first == 0) {
            const idx = try self.readVarint();
            if (idx == 0) return ""; // empty/null
            if (idx > self.string_dedup.items.len) return error.BadConstant;
            return self.string_dedup.items[@intCast(idx - 1)];
        }
        // New string: length is first-1.
        const str_len: usize = @intCast(first - 1);
        const bytes = try self.readBlock(str_len);
        try self.string_dedup.append(self.alloc, bytes);
        return bytes;
    }

    // --- Header validation ---

    /// Validate the 40-byte PUC Lua 5.5 binary chunk header.
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
    /// This must stay byte-identical to `DumpWriter.writeHeader` so that
    /// chunks round-trip exactly.
    pub fn checkHeader(self: *UndumpReader) UndumpError!void {
        // Grab all 40 bytes up front so any short read becomes a single
        // `TruncatedChunk` rather than a partial validate.
        const h = try self.readBlock(40);
        if (!std.mem.eql(u8, h[0..4], "\x1bLua")) return error.BadHeader;
        if (h[4] != 0x55) return error.BadHeader; // LUAC_VERSION
        if (h[5] != 0x00) return error.BadHeader; // LUAC_FORMAT
        if (!std.mem.eql(u8, h[6..12], "\x19\x93\r\n\x1a\n")) return error.BadHeader;

        // sizeof(int) and its endianness check.
        if (h[12] != 4) return error.BadHeader;
        const int_val = std.mem.readInt(i32, h[13..17], .little);
        if (int_val != -0x5678) return error.BadHeader;

        // sizeof(Instruction) and its endianness check.
        if (h[17] != 4) return error.BadHeader;
        const instr_val = std.mem.readInt(u32, h[18..22], .little);
        if (instr_val != 0x12345678) return error.BadHeader;

        // sizeof(lua_Integer) and its endianness check.
        if (h[22] != 8) return error.BadHeader;
        const i64_val = std.mem.readInt(i64, h[23..31], .little);
        if (i64_val != -0x5678) return error.BadHeader;

        // sizeof(lua_Number) and its endianness check.
        if (h[31] != 8) return error.BadHeader;
        const n_bits = std.mem.readInt(u64, h[32..40], .little);
        const n: f64 = @bitCast(n_bits);
        if (n != -370.5) return error.BadHeader;
    }

    // --- Constant deserialization ---

    /// Deserialize a single constant in the binary chunk's constant-tag
    /// format. The inverse of `DumpWriter.dumpConstant`.
    ///
    /// Tag byte mapping (matches PUC Lua 5.5's LUA_V* constants):
    ///   0 = nil
    ///   1 = false
    ///   2 = true
    ///   3 = integer (followed by i64 LE)
    ///   4 = number  (followed by raw u64 LE — the f64 bit pattern)
    ///   5 = string  (followed by writeString)
    ///
    /// For tag 5 (string), the raw bytes are read off the stream and passed
    /// to the `internFn` callback (if set). The callback returns a
    /// `*vm.LuaString` (as `*anyopaque`) that the Proto's constant pool will
    /// reference. This mirrors PUC Lua's `lundump.c`, which calls `luaS_new`
    /// to intern each string constant during deserialization. If `internFn`
    /// is null, the constant is left as `.str = undefined` and the caller
    /// must patch it up before first execution.
    pub fn undumpConstant(self: *UndumpReader) UndumpError!bc.Constant {
        const tag = try self.readByte();
        return switch (tag) {
            0 => .nil,
            1 => .{ .bool = false },
            2 => .{ .bool = true },
            3 => .{ .int = try self.readI64LE() },
            4 => .{ .num_bits = try self.readU64LE() },
            5 => blk: {
                // String constant: read dedup'd bytes, then intern via callback.
                const bytes = try self.readStringDedup();
                if (self.internFn) |fn_ptr| {
                    const ctx = self.internCtx orelse return error.BadConstant;
                    const opaque_ptr = fn_ptr(ctx, bytes) catch return error.OutOfMemory;
                    const ls: @FieldType(bc.Constant, "str") = @ptrCast(@alignCast(opaque_ptr));
                    break :blk .{ .str = ls };
                }
                break :blk .{ .str = undefined };
            },
            else => error.BadConstant,
        };
    }

    // --- Proto deserialization ---

    /// Deserialize a Proto recursively. The exact inverse of
    /// `DumpWriter.dumpProto`: fields are read in the same order they were
    /// written.
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
    ///  10.  k.len                 u32, then each Constant via undumpConstant
    ///  11.  upvalues.len          u32, then each: instack byte, idx byte, is_const byte
    ///  12.  p.len                 u32, then each child Proto recursively
    ///  13.  lineinfo.len          u32, then each entry as u32 (absolute line numbers)
    ///  14.  locvars.len           u32, then each: name string, reg byte, startpc u32, endpc u32
    pub fn undumpProto(self: *UndumpReader) UndumpError!*bc.Proto {
        const alloc = self.alloc;

        // 1. Source name. Borrows the input buffer's bytes; the caller is
        // responsible for copying if the Proto must outlive the input.
        const source_name = try self.readStringDedup();
        // 2. Function name.
        const name = try self.readStringDedup();
        // 3-4. Line range.
        const line_defined = try self.readU32();
        const last_line_defined = try self.readU32();
        // 5-6. Parameter / register counts.
        const numparams = try self.readByte();
        const maxstacksize = try self.readByte();

        // 7. Flags byte: bit 0 = is_vararg, bit 1 = has vararg_table_reg.
        const flags = try self.readByte();
        const is_vararg = (flags & 1) != 0;
        const has_vtr = (flags & 2) != 0;

        // 8. vararg_table_reg — only present when flags bit 1 is set.
        const vararg_table_reg: ?u8 = if (has_vtr) try self.readByte() else null;

        // 9. Code: length prefix, then each instruction as a raw u32 LE word.
        const code_len = try self.readU32();
        // Allocate the instruction slice up front so we can decode in place.
        const code = try alloc.alloc(bc.Instruction, @intCast(code_len));
        for (0..code_len) |i| {
            const raw = try self.readU32LE();
            code[i] = @bitCast(raw);
        }

        // 10. Constants: length prefix, then each via undumpConstant.
        const k_len = try self.readU32();
        const k = try alloc.alloc(bc.Constant, @intCast(k_len));
        for (0..k_len) |i| {
            k[i] = try self.undumpConstant();
        }

        // 11. Upvalues: length prefix, then each as (instack, idx, is_const, name).
        const upv_len = try self.readU32();
        const upvalues = try alloc.alloc(bc.Upvaldesc, @intCast(upv_len));
        for (0..upv_len) |i| {
            const instack_byte = try self.readByte();
            const idx = try self.readByte();
            const is_const_byte = try self.readByte();
            const uv_name = try self.readStringDedup();
            upvalues[i] = .{
                .instack = instack_byte != 0,
                .idx = idx,
                .is_const = is_const_byte != 0,
                .name = uv_name,
            };
        }

        // 12. Inner protos: length prefix, then each child recursively.
        const p_len = try self.readU32();
        const protos = try alloc.alloc(*bc.Proto, @intCast(p_len));
        for (0..p_len) |i| {
            protos[i] = try self.undumpProto();
        }

        // 13. Line info: length prefix, then each absolute line number as u32.
        const li_len = try self.readU32();
        const lineinfo = try alloc.alloc(u32, @intCast(li_len));
        for (0..li_len) |i| {
            lineinfo[i] = try self.readU32();
        }

        // 14. Locals: length prefix, then each as (name, reg, startpc, endpc).
        const lv_len = try self.readU32();
        const locvars = try alloc.alloc(bc.LocVar, @intCast(lv_len));
        for (0..lv_len) |i| {
            const lv_name = try self.readStringDedup();
            const lv_reg = try self.readByte();
            const lv_startpc = try self.readU32();
            const lv_endpc = try self.readU32();
            locvars[i] = .{
                .name = lv_name,
                .reg = lv_reg,
                .startpc = lv_startpc,
                .endpc = lv_endpc,
            };
        }

        // Build the Proto. Fields not present in the binary format get
        // their defaults. String constants were interned through `internFn`
        // during `undumpConstant` (if the callback was set), so the constant
        // pool is immediately usable. `constants_resolved` stays false: the
        // VM still needs to run `resolveProtoConstants` on first execution to
        // build the `resolved_values` runtime array (PUC Lua stores constants
        // in runtime TValue format directly; we defer that to first use).
        const proto = try alloc.create(bc.Proto);
        proto.* = .{
            .code = code,
            .k = k,
            // The VM resolves `.str` constants to VM-interned pointers on
            // first execution. Until then, string constants are `undefined`
            // and `constants_resolved` stays false.
            .constants_resolved = false,
            .resolved_values = &.{},
            .p = protos,
            .upvalues = upvalues,
            .lineinfo = lineinfo,
            .locvars = locvars,
            // live_reg_top is a codegen-only artifact; the undump path
            // leaves it empty and lets the VM compute it lazily.
            .live_reg_top = &.{},
            .maxstacksize = maxstacksize,
            .numparams = numparams,
            .is_vararg = is_vararg,
            .vararg_table_reg = vararg_table_reg,
            .name = name,
            .source_name = source_name,
            .line_defined = line_defined,
            .last_line_defined = last_line_defined,
        };
        return proto;
    }

    // --- Entry point ---

    /// Deserialize a complete binary chunk: 40-byte header, upvalue count
    /// for the main function, then the main Proto tree.
    ///
    /// The single byte after the header is the main function's upvalue count
    /// (PUC writes `sizeupvalues` here). We read it for cursor alignment but
    /// do not use it: the body that follows already encodes the upvalue
    /// array with its own length prefix, so the count byte is redundant for
    /// our format. PUC's lundump.c uses it to size the upvalue array before
    /// reading the body; we read the array length from the body instead.
    pub fn undumpChunk(self: *UndumpReader) UndumpError!*bc.Proto {
        try self.checkHeader();
        const upvalue_count = try self.readByte();
        _ = upvalue_count; // body already has the right count
        return try self.undumpProto();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "UndumpReader: readByte and readBlock" {
    const data = [_]u8{ 0xAB, 'h', 'e', 'l', 'l', 'o' };
    var r = UndumpReader.init(std.testing.allocator, &data);
    try std.testing.expectEqual(@as(u8, 0xAB), try r.readByte());
    const block = try r.readBlock(5);
    try std.testing.expectEqualSlices(u8, "hello", block);
}

test "UndumpReader: readByte at EOF returns TruncatedChunk" {
    const data = [_]u8{0x01};
    var r = UndumpReader.init(std.testing.allocator, &data);
    _ = try r.readByte();
    try std.testing.expectError(error.TruncatedChunk, r.readByte());
}

test "UndumpReader: readU32LE little-endian" {
    const data = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    var r = UndumpReader.init(std.testing.allocator, &data);
    try std.testing.expectEqual(@as(u32, 0x12345678), try r.readU32LE());
}

test "UndumpReader: readI64LE little-endian" {
    // -0x5678 = 0xFFFFFFFFFFFFA988
    const data = [_]u8{ 0x88, 0xA9, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var r = UndumpReader.init(std.testing.allocator, &data);
    try std.testing.expectEqual(@as(i64, -0x5678), try r.readI64LE());
}

test "UndumpReader: readU64LE little-endian" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x24, 0x40 };
    var r = UndumpReader.init(std.testing.allocator, &data);
    // 0x4024000000000000 = 10.0 as f64 bits
    try std.testing.expectEqual(@as(u64, 0x4024000000000000), try r.readU64LE());
}

test "UndumpReader: readVarint LEB128" {
    // Mirror of the writeVarint test cases.
    const data = [_]u8{ 0x00, 0x7F, 0x80, 0x01, 0xAC, 0x02 };
    var r = UndumpReader.init(std.testing.allocator, &data);
    try std.testing.expectEqual(@as(u64, 0), try r.readVarint());
    try std.testing.expectEqual(@as(u64, 127), try r.readVarint());
    try std.testing.expectEqual(@as(u64, 128), try r.readVarint());
    try std.testing.expectEqual(@as(u64, 300), try r.readVarint());
}

test "UndumpReader: readString length-prefixed" {
    const data = [_]u8{ 2, 'h', 'i', 0 };
    var r = UndumpReader.init(std.testing.allocator, &data);
    const s = try r.readString();
    try std.testing.expectEqualSlices(u8, "hi", s);
    const empty = try r.readString();
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "UndumpReader: checkHeader accepts a valid 40-byte header" {
    // Build a header with DumpWriter so we know it's well-formed.
    var w = @import("dump.zig").DumpWriter.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader();

    var r = UndumpReader.init(std.testing.allocator, w.buf.items);
    try r.checkHeader();
    try std.testing.expectEqual(@as(usize, 40), r.pos);
}

test "UndumpReader: checkHeader rejects bad signature" {
    var w = @import("dump.zig").DumpWriter.init(std.testing.allocator);
    defer w.deinit();
    try w.writeHeader();
    w.buf.items[0] = 'X'; // corrupt the signature

    var r = UndumpReader.init(std.testing.allocator, w.buf.items);
    try std.testing.expectError(error.BadHeader, r.checkHeader());
}

test "UndumpReader: undumpConstant nil/bool/int/num" {
    var w = @import("dump.zig").DumpWriter.init(std.testing.allocator);
    defer w.deinit();
    try w.dumpConstant(.nil);
    try w.dumpConstant(.{ .bool = false });
    try w.dumpConstant(.{ .bool = true });
    try w.dumpConstant(.{ .int = -1 });
    try w.dumpConstant(.{ .num_bits = @bitCast(@as(f64, 3.14)) });

    var r = UndumpReader.init(std.testing.allocator, w.buf.items);
    try std.testing.expectEqual(bc.Constant.nil, try r.undumpConstant());
    const c1 = try r.undumpConstant();
    try std.testing.expectEqual(@as(bool, false), c1.bool);
    const c2 = try r.undumpConstant();
    try std.testing.expectEqual(@as(bool, true), c2.bool);
    const c3 = try r.undumpConstant();
    try std.testing.expectEqual(@as(i64, -1), c3.int);
    const c4 = try r.undumpConstant();
    const f: f64 = @bitCast(c4.num_bits);
    try std.testing.expectEqual(@as(f64, 3.14), f);
}

test "UndumpReader: undumpConstant rejects bad tag" {
    const data = [_]u8{0xFF};
    var r = UndumpReader.init(std.testing.allocator, &data);
    try std.testing.expectError(error.BadConstant, r.undumpConstant());
}

test "UndumpReader: undumpProto round-trips a simple Proto" {
    // Build a small Proto with DumpWriter, then read it back and verify
    // every field matches.
    var w = @import("dump.zig").DumpWriter.init(std.testing.allocator);
    defer w.deinit();

    // Construct a minimal Proto by hand.
    const insts = [_]bc.Instruction{
        bc.Instruction.make(.loadk, 0, 0, 0),
        bc.Instruction.make(.return1, 0, 0, 0),
    };
    const ks = [_]bc.Constant{
        .{ .int = 42 },
        .nil,
    };
    const uvs = [_]bc.Upvaldesc{};
    const ps = [_]*bc.Proto{};
    const lis = [_]u32{ 1, 2 };
    const lvs = [_]bc.LocVar{};
    const proto = bc.Proto{
        .code = &insts,
        .k = @constCast(&ks),
        .p = &ps,
        .upvalues = &uvs,
        .lineinfo = &lis,
        .locvars = &lvs,
        .maxstacksize = 2,
        .numparams = 0,
        .is_vararg = false,
        .vararg_table_reg = null,
        .name = "test",
        .source_name = "test.lua",
        .line_defined = 1,
        .last_line_defined = 2,
    };

    try w.dumpProto(&proto);

    var r = UndumpReader.init(std.testing.allocator, w.buf.items);
    const out = try r.undumpProto();
    defer {
        out.deinit(std.testing.allocator);
        std.testing.allocator.destroy(out);
    }

    try std.testing.expectEqualSlices(u8, "test.lua", out.source_name);
    try std.testing.expectEqualSlices(u8, "test", out.name);
    try std.testing.expectEqual(@as(u32, 1), out.line_defined);
    try std.testing.expectEqual(@as(u32, 2), out.last_line_defined);
    try std.testing.expectEqual(@as(u8, 0), out.numparams);
    try std.testing.expectEqual(@as(u8, 2), out.maxstacksize);
    try std.testing.expectEqual(false, out.is_vararg);
    try std.testing.expectEqual(@as(?u8, null), out.vararg_table_reg);
    try std.testing.expectEqual(@as(usize, 2), out.code.len);
    try std.testing.expectEqual(@as(u32, @bitCast(insts[0])), @as(u32, @bitCast(out.code[0])));
    try std.testing.expectEqual(@as(u32, @bitCast(insts[1])), @as(u32, @bitCast(out.code[1])));
    try std.testing.expectEqual(@as(usize, 2), out.k.len);
    try std.testing.expectEqual(@as(i64, 42), out.k[0].int);
    try std.testing.expectEqual(bc.Constant.nil, out.k[1]);
    try std.testing.expectEqual(@as(usize, 0), out.upvalues.len);
    try std.testing.expectEqual(@as(usize, 0), out.p.len);
    try std.testing.expectEqual(@as(usize, 2), out.lineinfo.len);
    try std.testing.expectEqual(@as(u32, 1), out.lineinfo[0]);
    try std.testing.expectEqual(@as(u32, 2), out.lineinfo[1]);
    try std.testing.expectEqual(@as(usize, 0), out.locvars.len);
    // Defaults for VM-resolved fields.
    try std.testing.expectEqual(false, out.constants_resolved);
    try std.testing.expectEqual(@as(usize, 0), out.resolved_values.len);
    try std.testing.expectEqual(@as(usize, 0), out.live_reg_top.len);
}

test "UndumpReader: undumpProto round-trips vararg + upvalues + locvars" {
    var w = @import("dump.zig").DumpWriter.init(std.testing.allocator);
    defer w.deinit();

    const insts = [_]bc.Instruction{
        bc.Instruction.make(.varargprep, 0, 0, 0),
        bc.Instruction.make(.return1, 0, 0, 0),
    };
    const ks = [_]bc.Constant{};
    const uvs = [_]bc.Upvaldesc{
        .{ .instack = true, .idx = 0, .is_const = false, .name = "x" },
        .{ .instack = false, .idx = 1, .is_const = true, .name = "y" },
    };
    const ps = [_]*bc.Proto{};
    const lis = [_]u32{ 10, 20 };
    const lvs = [_]bc.LocVar{
        .{ .name = "a", .reg = 0, .startpc = 0, .endpc = 1 },
    };
    const proto = bc.Proto{
        .code = &insts,
        .k = @constCast(&ks),
        .p = &ps,
        .upvalues = &uvs,
        .lineinfo = &lis,
        .locvars = &lvs,
        .maxstacksize = 3,
        .numparams = 1,
        .is_vararg = true,
        .vararg_table_reg = 5,
        .name = "f",
        .source_name = "f.lua",
        .line_defined = 5,
        .last_line_defined = 6,
    };

    try w.dumpProto(&proto);

    var r = UndumpReader.init(std.testing.allocator, w.buf.items);
    const out = try r.undumpProto();
    defer {
        out.deinit(std.testing.allocator);
        std.testing.allocator.destroy(out);
    }

    try std.testing.expectEqual(true, out.is_vararg);
    try std.testing.expectEqual(@as(?u8, 5), out.vararg_table_reg);
    try std.testing.expectEqual(@as(u8, 1), out.numparams);
    try std.testing.expectEqual(@as(usize, 2), out.upvalues.len);
    try std.testing.expectEqual(true, out.upvalues[0].instack);
    try std.testing.expectEqual(@as(u8, 0), out.upvalues[0].idx);
    try std.testing.expectEqual(false, out.upvalues[0].is_const);
    try std.testing.expectEqual(false, out.upvalues[1].instack);
    try std.testing.expectEqual(@as(u8, 1), out.upvalues[1].idx);
    try std.testing.expectEqual(true, out.upvalues[1].is_const);
    try std.testing.expectEqual(@as(usize, 1), out.locvars.len);
    try std.testing.expectEqualSlices(u8, "a", out.locvars[0].name);
    try std.testing.expectEqual(@as(u8, 0), out.locvars[0].reg);
    try std.testing.expectEqual(@as(u32, 0), out.locvars[0].startpc);
    try std.testing.expectEqual(@as(u32, 1), out.locvars[0].endpc);
}

test "UndumpReader: undumpChunk round-trips a full chunk" {
    var w = @import("dump.zig").DumpWriter.init(std.testing.allocator);
    defer w.deinit();

    const insts = [_]bc.Instruction{
        bc.Instruction.make(.return0, 0, 0, 0),
    };
    const ks = [_]bc.Constant{};
    const uvs = [_]bc.Upvaldesc{};
    const ps = [_]*bc.Proto{};
    const lis = [_]u32{1};
    const lvs = [_]bc.LocVar{};
    const proto = bc.Proto{
        .code = &insts,
        .k = @constCast(&ks),
        .p = &ps,
        .upvalues = &uvs,
        .lineinfo = &lis,
        .locvars = &lvs,
        .maxstacksize = 2,
        .numparams = 0,
        .is_vararg = true,
        .vararg_table_reg = null,
        .name = "main",
        .source_name = "chunk.lua",
        .line_defined = 0,
        .last_line_defined = 0,
    };

    try w.dumpChunk(&proto);

    var r = UndumpReader.init(std.testing.allocator, w.buf.items);
    const out = try r.undumpChunk();
    defer {
        out.deinit(std.testing.allocator);
        std.testing.allocator.destroy(out);
    }

    try std.testing.expectEqualSlices(u8, "chunk.lua", out.source_name);
    try std.testing.expectEqualSlices(u8, "main", out.name);
    try std.testing.expectEqual(true, out.is_vararg);
    try std.testing.expectEqual(@as(usize, 1), out.code.len);
    try std.testing.expectEqual(@as(u32, @bitCast(insts[0])), @as(u32, @bitCast(out.code[0])));
}

test "UndumpReader: undumpProto round-trips nested protos" {
    var w = @import("dump.zig").DumpWriter.init(std.testing.allocator);
    defer w.deinit();

    // Inner proto.
    const inner_insts = [_]bc.Instruction{
        bc.Instruction.make(.return1, 0, 0, 0),
    };
    const inner_ks = [_]bc.Constant{.{ .int = 7 }};
    const empty_uvs = [_]bc.Upvaldesc{};
    const empty_ps = [_]*bc.Proto{};
    const inner_lis = [_]u32{3};
    const inner_lvs = [_]bc.LocVar{};
    const inner = bc.Proto{
        .code = &inner_insts,
        .k = @constCast(&inner_ks),
        .p = &empty_ps,
        .upvalues = &empty_uvs,
        .lineinfo = &inner_lis,
        .locvars = &inner_lvs,
        .maxstacksize = 2,
        .numparams = 0,
        .is_vararg = false,
        .vararg_table_reg = null,
        .name = "inner",
        .source_name = "outer.lua",
        .line_defined = 2,
        .last_line_defined = 4,
    };

    // Outer proto with one nested child.
    const outer_insts = [_]bc.Instruction{
        bc.Instruction.make(.closure, 0, 0, 0),
        bc.Instruction.make(.return1, 0, 0, 0),
    };
    const outer_ks = [_]bc.Constant{};
    const outer_uvs = [_]bc.Upvaldesc{};
    const outer_ps = [_]*bc.Proto{@constCast(&inner)};
    const outer_lis = [_]u32{ 1, 5 };
    const outer_lvs = [_]bc.LocVar{};
    const outer = bc.Proto{
        .code = &outer_insts,
        .k = @constCast(&outer_ks),
        .p = &outer_ps,
        .upvalues = &outer_uvs,
        .lineinfo = &outer_lis,
        .locvars = &outer_lvs,
        .maxstacksize = 2,
        .numparams = 0,
        .is_vararg = true,
        .vararg_table_reg = null,
        .name = "outer",
        .source_name = "outer.lua",
        .line_defined = 1,
        .last_line_defined = 6,
    };

    try w.dumpProto(&outer);

    var r = UndumpReader.init(std.testing.allocator, w.buf.items);
    const out = try r.undumpProto();
    defer {
        out.deinit(std.testing.allocator);
        std.testing.allocator.destroy(out);
    }

    try std.testing.expectEqualSlices(u8, "outer", out.name);
    try std.testing.expectEqual(@as(usize, 1), out.p.len);
    const child = out.p[0];
    try std.testing.expectEqualSlices(u8, "inner", child.name);
    try std.testing.expectEqualSlices(u8, "outer.lua", child.source_name);
    try std.testing.expectEqual(@as(u32, 2), child.line_defined);
    try std.testing.expectEqual(@as(u32, 4), child.last_line_defined);
    try std.testing.expectEqual(@as(usize, 1), child.code.len);
    try std.testing.expectEqual(@as(usize, 1), child.k.len);
    try std.testing.expectEqual(@as(i64, 7), child.k[0].int);
}
