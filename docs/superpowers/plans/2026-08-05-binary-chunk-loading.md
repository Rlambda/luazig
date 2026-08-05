# Binary Chunk Loading (string.dump / load) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the side-channel stub `string.dump`/binary-load with real Proto serialization/deserialization so that `string.dump(f)` produces a self-loadable binary chunk.

**Architecture:** PUC-compatible 40-byte header (for binary detection via `0x1b` first byte) followed by a luazig-native body that serializes all Proto fields needed for correct execution. No opcode remapping — luazig opcodes are written as-is. This makes chunks self-compatible (luazig can load what luazig dumps) but not cross-compatible with PUC `luac` (future task: opcode remapping table).

**Tech Stack:** Zig, `std.mem.Allocator`, `std.ArrayListUnmanaged(u8)`, `std.StringHashMapUnmanaged`, luazig `bytecode.Proto`.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `src/lua/undump.zig` (NEW) | Binary chunk reader: `UndumpReader` struct with varint/string/block primitives + `undumpProto` function |
| `src/lua/dump.zig` (NEW) | Binary chunk writer: `DumpWriter` struct with varint/string/block primitives + `dumpProto` function |
| `src/lua/bytecode.zig` (MODIFY) | Add `createProto` allocator helper if needed |
| `src/lua/vm.zig` (MODIFY) | Replace stub `builtinStringDump` and binary-load path in `builtinLoad` with calls to dump.zig/undump.zig |
| `tests/smoke/47_binary_dump.lua` (NEW) | Smoke test: dump → load → execute roundtrip |

## Design Decision: luazig-native format vs PUC-compatible format

**Chosen:** luazig-native format with PUC-compatible header.

**Justification (per AGENTS.md "Отступление от PUC-first"):**
1. PUC's binary format uses PUC opcode indices, which differ from luazig's (86 vs 85 opcodes, completely different ordering). Cross-compatibility requires a full opcode remapping table — a separate, mechanical but error-prone task.
2. The `all.lua` test only uses `string.dump` (luazig's own) to produce chunks — it never loads PUC `luac` output. Self-compatibility is sufficient for all tests.
3. The header is PUC-compatible (40 bytes, same signature `0x1b`) so binary detection (`skipcomment` → `0x1b` check) works identically.
4. Future cross-compatibility (loading `luac` output) can be added by introducing an opcode remapping table without changing the body format.

**Trade-off:** luazig binary chunks cannot be loaded by PUC Lua and vice versa. This is documented as a known gap.

---

## Binary Format Specification

### Header (40 bytes — PUC-compatible)

Written by `DumpWriter.writeHeader()`, validated by `UndumpReader.checkHeader()`.

```
Offset  Size  Value
0       4     \x1bLua  (LUA_SIGNATURE)
4       1     0x55     (LUAC_VERSION = 5*16+5)
5       1     0x00     (LUAC_FORMAT)
6       6     \x19\x93\r\n\x1a\n  (LUAC_DATA)
12      1     4        (sizeof(int))
13      4     0x889CFE38 LE  (-0x5678 as i32, LUAC_INT for int)
17      1     4        (sizeof(Instruction))
18      4     0x12345678 LE  (LUAC_INST)
22      1     8        (sizeof(lua_Integer))
23      8     0xFFFFA9B88770FFFF LE  (-0x5678 as i64, LUAC_INT for lua_Integer)
31      1     8        (sizeof(lua_Number))
32      8     -370.5 as f64 LE  (LUAC_NUM)
```

### Body (luazig-native)

After the 40-byte header:

```
Field               Encoding
upvalue_count       1 byte (number of upvalues of main function)
proto               recursive Proto serialization (see below)
```

### Proto serialization

Each Proto is serialized in this order:

```
Field               Encoding
source_name         string (varint length + bytes; empty = no source)
name                string (function name; empty = anonymous)
line_defined        varint (u32)
last_line_defined   varint (u32)
numparams           1 byte
maxstacksize        1 byte
flags               1 byte (bit 0 = is_vararg, bit 1 = has_vararg_table_reg)
vararg_table_reg    1 byte (only if flags bit 1 set)
code_count          varint (number of instructions)
code                code_count * 4 bytes (raw Instruction u32 array, luazig opcodes)
k_count             varint (number of constants)
constants           k_count constant entries (see below)
upvalue_count       varint (number of upvalues)
upvalues            upvalue_count * upvalue entries (see below)
proto_count         varint (number of nested protos)
protos              proto_count recursive Proto entries
lineinfo_count      varint (number of line info entries)
lineinfo            lineinfo_count * 4 bytes (raw u32 array, absolute line numbers)
locvar_count        varint (number of local variables)
locvars             locvar_count * locvar entries (see below)
```

### Constant encoding

```
Type tag (1 byte)   Value
0 (nil)             (nothing)
1 (false)           (nothing)
2 (true)            (nothing)
3 (int)             8 bytes (i64 LE)
4 (float)           8 bytes (f64 LE, raw bits as u64)
5 (string)          string (varint length + bytes)
```

### Upvalue encoding

```
instack    1 byte (0 or 1)
idx        1 byte
is_const   1 byte (0 or 1)
```

### LocVar encoding

```
name       string (varint length + bytes)
reg        1 byte
startpc    varint (u32)
endpc      varint (u32)
```

### String encoding (without dedup for v1)

```
length     varint (u32)
bytes      length bytes (raw content, NO trailing \0)
```

**Note on dedup:** PUC uses a string dedup table to avoid serializing the same string twice. For v1, we skip dedup — every string is written in full. This wastes space for repeated strings (e.g., source_name in nested protos) but simplifies the implementation. Dedup can be added in a follow-up.

### Varint encoding

PUC uses MSB-as-continuation, big-endian-within-varint (least significant 7 bits in the LAST byte). We use standard **LEB128** (least significant 7 bits FIRST, high bit = continuation) which is simpler and more common.

**IMPORTANT:** This means our varint encoding is NOT compatible with PUC's. This is acceptable since we're using a luazig-native body format.

---

## Task 1: Binary writer primitives (`src/lua/dump.zig`)

**Files:**
- Create: `src/lua/dump.zig`

- [ ] **Step 1: Create `dump.zig` with DumpWriter struct and primitives**

```zig
const std = @import("std");
const bc = @import("bytecode.zig");
const vm_mod = @import("vm.zig");

/// Binary chunk writer. Serializes a Proto tree into a PUC-compatible header
/// + luazig-native body.
pub const DumpWriter = struct {
    buf: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8)) DumpWriter {
        return .{ .alloc = alloc, .buf = buf };
    }

    /// Write a single byte.
    pub fn writeByte(self: *DumpWriter, b: u8) !void {
        try self.buf.append(self.alloc, b);
    }

    /// Write a raw block of bytes.
    pub fn writeBlock(self: *DumpWriter, data: []const u8) !void {
        try self.buf.appendSlice(self.alloc, data);
    }

    /// Write a LEB128-encoded unsigned varint.
    pub fn writeVarint(self: *DumpWriter, value: u64) !void {
        var v = value;
        while (v >= 0x80) {
            try self.buf.append(self.alloc, @intCast((v & 0x7F) | 0x80));
            v >>= 7;
        }
        try self.buf.append(self.alloc, @intCast(v));
    }

    /// Write a u32 as a varint.
    pub fn writeU32(self: *DumpWriter, value: u32) !void {
        try self.writeVarint(@intCast(value));
    }

    /// Write a raw u32 in little-endian.
    pub fn writeU32LE(self: *DumpWriter, value: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        try self.writeBlock(&buf);
    }

    /// Write a raw i64 in little-endian.
    pub fn writeI64LE(self: *DumpWriter, value: i64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &buf, value, .little);
        try self.writeBlock(&buf);
    }

    /// Write a raw f64 in little-endian.
    pub fn writeF64LE(self: *DumpWriter, value: f64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @bitCast(value), .little);
        try self.writeBlock(&buf);
    }

    /// Write a string: varint length + raw bytes (no trailing \0).
    pub fn writeString(self: *DumpWriter, s: []const u8) !void {
        try self.writeVarint(@intCast(s.len));
        try self.writeBlock(s);
    }

    /// Write the 40-byte PUC-compatible header.
    pub fn writeHeader(self: *DumpWriter) !void {
        try self.writeBlock("\x1bLua");       // LUA_SIGNATURE
        try self.writeByte(0x55);              // LUAC_VERSION (5.5)
        try self.writeByte(0x00);              // LUAC_FORMAT
        try self.writeBlock("\x19\x93\r\n\x1a\n"); // LUAC_DATA
        try self.writeByte(4);                 // sizeof(int)
        try self.writeI64LE(-0x5678);          // LUAC_INT for int (but we write as 4 bytes LE)
        // Actually PUC writes sizeof(int)=4, then 4 bytes. Let me be precise:
        // We already wrote the i64 — need to fix. Let me re-do.
    }
};
```

Wait — the header needs to be exact. Let me fix the writeHeader method:

```zig
    /// Write the 40-byte PUC-compatible header.
    pub fn writeHeader(self: *DumpWriter) !void {
        try self.writeBlock("\x1bLua");         // bytes 0-3: LUA_SIGNATURE
        try self.writeByte(0x55);                // byte 4: LUAC_VERSION
        try self.writeByte(0x00);                // byte 5: LUAC_FORMAT
        try self.writeBlock("\x19\x93\r\n\x1a\n"); // bytes 6-11: LUAC_DATA
        try self.writeByte(4);                   // byte 12: sizeof(int) = 4
        var int_buf: [4]u8 = undefined;
        std.mem.writeInt(i32, &int_buf, -0x5678, .little);
        try self.writeBlock(&int_buf);           // bytes 13-16: LUAC_INT (int)
        try self.writeByte(4);                   // byte 17: sizeof(Instruction) = 4
        std.mem.writeInt(u32, &int_buf, 0x12345678, .little);
        try self.writeBlock(&int_buf);           // bytes 18-21: LUAC_INST
        try self.writeByte(8);                   // byte 22: sizeof(lua_Integer) = 8
        var i64_buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &i64_buf, -0x5678, .little);
        try self.writeBlock(&i64_buf);           // bytes 23-30: LUAC_INT (lua_Integer)
        try self.writeByte(8);                   // byte 31: sizeof(lua_Number) = 8
        std.mem.writeInt(u64, &i64_buf, @bitCast(@as(f64, -370.5)), .little);
        try self.writeBlock(&i64_buf);           // bytes 32-39: LUAC_NUM
    }
```

- [ ] **Step 2: Verify header writes correctly**

Add a test at the bottom of dump.zig:

```zig
test "writeHeader produces 40-byte PUC header" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var w = DumpWriter.init(std.testing.allocator, &buf);
    try w.writeHeader();
    try std.testing.expectEqual(@as(usize, 40), buf.items.len);
    try std.testing.expectEqualSlices(u8, "\x1bLua", buf.items[0..4]);
    try std.testing.expectEqual(@as(u8, 0x55), buf.items[4]);
}
```

Run: `zig test src/lua/dump.zig -fno-emit-bin`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add src/lua/dump.zig
git commit -m "dump.zig: binary chunk writer primitives (varint, header, string)"
```

---

## Task 2: Proto serializer (`dumpProto`)

**Files:**
- Modify: `src/lua/dump.zig`

- [ ] **Step 1: Add `dumpProto` method to DumpWriter**

```zig
/// Serialize a Proto and all its nested children into the buffer.
pub fn dumpProto(self: *DumpWriter, proto: *const bc.Proto) !void {
    // source_name
    try self.writeString(proto.source_name);

    // name (luazig-specific: proto function name)
    try self.writeString(proto.name);

    // line_defined, last_line_defined
    try self.writeU32(proto.line_defined);
    try self.writeU32(proto.last_line_defined);

    // numparams, maxstacksize
    try self.writeByte(proto.numparams);
    try self.writeByte(proto.maxstacksize);

    // flags: bit 0 = is_vararg, bit 1 = has_vararg_table_reg
    var flags: u8 = 0;
    if (proto.is_vararg) flags |= 1;
    if (proto.vararg_table_reg != null) flags |= 2;
    try self.writeByte(flags);

    // vararg_table_reg (only if flag bit 1 set)
    if (proto.vararg_table_reg) |reg| {
        try self.writeByte(reg);
    }

    // code (instructions — luazig opcodes, written as raw u32)
    try self.writeU32(@intCast(proto.code.len));
    for (proto.code) |inst| {
        try self.writeU32LE(@bitCast(inst));
    }

    // constants
    try self.writeU32(@intCast(proto.k.len));
    for (proto.k) |konst| {
        try self.dumpConstant(konst);
    }

    // upvalues
    try self.writeU32(@intCast(proto.upvalues.len));
    for (proto.upvalues) |uv| {
        try self.writeByte(if (uv.instack) 1 else 0);
        try self.writeByte(uv.idx);
        try self.writeByte(if (uv.is_const) 1 else 0);
    }

    // nested protos
    try self.writeU32(@intCast(proto.p.len));
    for (proto.p) |child| {
        try self.dumpProto(child);
    }

    // lineinfo (absolute u32 per instruction)
    try self.writeU32(@intCast(proto.lineinfo.len));
    for (proto.lineinfo) |line| {
        try self.writeU32(line);
    }

    // locvars
    try self.writeU32(@intCast(proto.locvars.len));
    for (proto.locvars) |lv| {
        try self.writeString(lv.name);
        try self.writeByte(lv.reg);
        try self.writeU32(lv.startpc);
        try self.writeU32(lv.endpc);
    }
}

fn dumpConstant(self: *DumpWriter, konst: bc.Constant) !void {
    switch (konst) {
        .nil => try self.writeByte(0),
        .bool => |b| try self.writeByte(if (b) 2 else 1),
        .int => |i| {
            try self.writeByte(3);
            try self.writeI64LE(i);
        },
        .num_bits => |bits| {
            try self.writeByte(4);
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, bits, .little);
            try self.writeBlock(&buf);
        },
        .str => |s| {
            try self.writeByte(5);
            try self.writeString(s.bytes());
        },
    }
}
```

- [ ] **Step 2: Add `dumpFunction` entry point (top-level)**

```zig
/// Top-level entry: write header + upvalue count + main proto.
pub fn dumpChunk(self: *DumpWriter, main: *const bc.Proto) !void {
    try self.writeHeader();
    try self.writeByte(@intCast(main.upvalues.len));
    try self.dumpProto(main);
}
```

- [ ] **Step 3: Commit**

```bash
git add src/lua/dump.zig
git commit -m "dump.zig: Proto serializer (dumpProto, dumpConstant, dumpChunk)"
```

---

## Task 3: Binary reader primitives (`src/lua/undump.zig`)

**Files:**
- Create: `src/lua/undump.zig`

- [x] **Step 1: Create `undump.zig` with UndumpReader struct**

```zig
const std = @import("std");
const bc = @import("bytecode.zig");
const vm_mod = @import("vm.zig");

pub const UndumpError = error{
    TruncatedChunk,
    BadHeader,
    BadConstant,
    OutOfMemory,
};

/// Binary chunk reader. Deserializes a PUC-compatible header + luazig-native
/// body into a Proto tree.
pub const UndumpReader = struct {
    data: []const u8,
    pos: usize = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, data: []const u8) UndumpReader {
        return .{ .alloc = alloc, .data = data };
    }

    fn remaining(self: *UndumpReader) usize {
        return self.data.len - self.pos;
    }

    fn readByte(self: *UndumpReader) UndumpError!u8 {
        if (self.pos >= self.data.len) return error.TruncatedChunk;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readBlock(self: *UndumpReader, len: usize) UndumpError![]const u8 {
        if (self.remaining() < len) return error.TruncatedChunk;
        const block = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return block;
    }

    fn readU32LE(self: *UndumpReader) UndumpError!u32 {
        const block = try self.readBlock(4);
        return std.mem.readInt(u32, block[0..4], .little);
    }

    fn readI64LE(self: *UndumpReader) UndumpError!i64 {
        const block = try self.readBlock(8);
        return std.mem.readInt(i64, block[0..8], .little);
    }

    fn readU64LE(self: *UndumpReader) UndumpError!u64 {
        const block = try self.readBlock(8);
        return std.mem.readInt(u64, block[0..8], .little);
    }

    /// Read a LEB128-encoded varint.
    fn readVarint(self: *UndumpReader) UndumpError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.readByte();
            result |= (@as(u64, b & 0x7F) << shift);
            if ((b & 0x80) == 0) break;
            shift += 7;
            if (shift > 63) return error.BadHeader;
        }
        return result;
    }

    fn readU32(self: *UndumpReader) UndumpError!u32 {
        return @intCast(try self.readVarint());
    }

    fn readString(self: *UndumpReader) UndumpError![]const u8 {
        const len = try self.readU32();
        if (len == 0) return "";
        return try self.readBlock(len);
    }

    /// Validate the 40-byte PUC header.
    fn checkHeader(self: *UndumpReader) UndumpError!void {
        // LUA_SIGNATURE
        const sig = try self.readBlock(4);
        if (!std.mem.eql(u8, sig, "\x1bLua")) return error.BadHeader;
        // LUAC_VERSION
        if ((try self.readByte()) != 0x55) return error.BadHeader;
        // LUAC_FORMAT
        if ((try self.readByte()) != 0x00) return error.BadHeader;
        // LUAC_DATA
        const data = try self.readBlock(6);
        if (!std.mem.eql(u8, data, "\x19\x93\r\n\x1a\n")) return error.BadHeader;
        // sizeof(int)
        if ((try self.readByte()) != 4) return error.BadHeader;
        // LUAC_INT (int)
        const int_val = try self.readU32LE();
        if (int_val != @as(u32, @bitCast(@as(i32, -0x5678)))) return error.BadHeader;
        // sizeof(Instruction)
        if ((try self.readByte()) != 4) return error.BadHeader;
        // LUAC_INST
        const inst_val = try self.readU32LE();
        if (inst_val != 0x12345678) return error.BadHeader;
        // sizeof(lua_Integer)
        if ((try self.readByte()) != 8) return error.BadHeader;
        // LUAC_INT (lua_Integer)
        const i64_val = try self.readI64LE();
        if (i64_val != -0x5678) return error.BadHeader;
        // sizeof(lua_Number)
        if ((try self.readByte()) != 8) return error.BadHeader;
        // LUAC_NUM
        const num_bits = try self.readU64LE();
        if (num_bits != @as(u64, @bitCast(@as(f64, -370.5)))) return error.BadHeader;
    }
};
```

- [x] **Step 2: Add roundtrip test for primitives**

```zig
test "varint roundtrip" {
    var w_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer w_buf.deinit(std.testing.allocator);
    const dump = @import("dump.zig");
    var w = dump.DumpWriter.init(std.testing.allocator, &w_buf);
    try w.writeVarint(0);
    try w.writeVarint(127);
    try w.writeVarint(128);
    try w.writeVarint(16384);
    try w.writeVarint(1000000);

    var r = UndumpReader.init(std.testing.allocator, w_buf.items);
    try std.testing.expectEqual(@as(u64, 0), try r.readVarint());
    try std.testing.expectEqual(@as(u64, 127), try r.readVarint());
    try std.testing.expectEqual(@as(u64, 128), try r.readVarint());
    try std.testing.expectEqual(@as(u64, 16384), try r.readVarint());
    try std.testing.expectEqual(@as(u64, 1000000), try r.readVarint());
}
```

Run: `zig test src/lua/undump.zig -fno-emit-bin`
Expected: PASS

- [x] **Step 3: Commit**

```bash
git add src/lua/undump.zig
git commit -m "undump.zig: binary chunk reader primitives (varint, header, string)"
```

---

## Task 4: Proto deserializer (`undumpProto`)

**Files:**
- Modify: `src/lua/undump.zig`

- [x] **Step 1: Add `undumpProto` to UndumpReader**

```zig
/// Deserialize a Proto from the binary stream. Allocates a new Proto with
/// all fields populated. The caller must ensure Proto lifetime.
fn undumpProto(self: *UndumpReader, vm: *vm_mod.Vm) UndumpError!*bc.Proto {
    const source_name = try self.readString();
    const name = try self.readString();
    const line_defined = try self.readU32();
    const last_line_defined = try self.readU32();
    const numparams = try self.readByte();
    const maxstacksize = try self.readByte();
    const flags = try self.readByte();
    const is_vararg = (flags & 1) != 0;
    const has_vtr = (flags & 2) != 0;
    const vararg_table_reg: ?u8 = if (has_vtr) try self.readByte() else null;

    // code
    const code_count = try self.readU32();
    const code = try self.alloc.alloc(bc.Instruction, code_count);
    for (0..code_count) |i| {
        const raw = try self.readU32LE();
        code[i] = @bitCast(raw);
    }

    // constants
    const k_count = try self.readU32();
    const constants = try self.alloc.alloc(bc.Constant, k_count);
    for (0..k_count) |i| {
        constants[i] = try self.undumpConstant(vm);
    }

    // upvalues
    const uv_count = try self.readU32();
    const upvalues = try self.alloc.alloc(bc.Upvaldesc, uv_count);
    for (0..uv_count) |i| {
        const instack = (try self.readByte()) != 0;
        const idx = try self.readByte();
        const is_const = (try self.readByte()) != 0;
        upvalues[i] = .{
            .instack = instack,
            .idx = idx,
            .is_const = is_const,
            .name = "",
        };
    }

    // nested protos
    const p_count = try self.readU32();
    const protos = try self.alloc.alloc(*const bc.Proto, p_count);
    for (0..p_count) |i| {
        protos[i] = try self.undumpProto(vm);
    }

    // lineinfo
    const li_count = try self.readU32();
    const lineinfo = try self.alloc.alloc(u32, li_count);
    for (0..li_count) |i| {
        lineinfo[i] = try self.readU32();
    }

    // locvars
    const lv_count = try self.readU32();
    const locvars = try self.alloc.alloc(bc.LocVar, lv_count);
    for (0..lv_count) |i| {
        const lv_name = try self.readString();
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

    // Build the Proto
    const proto = try self.alloc.create(bc.Proto);
    proto.* = .{
        .source_name = source_name,
        .name = name,
        .line_defined = line_defined,
        .last_line_defined = last_line_defined,
        .numparams = numparams,
        .maxstacksize = maxstacksize,
        .is_vararg = is_vararg,
        .vararg_table_reg = vararg_table_reg,
        .code = code,
        .k = constants,
        .upvalues = upvalues,
        .p = protos,
        .lineinfo = lineinfo,
        .locvars = locvars,
        .constants_resolved = false,
        .resolved_values = &.{},
        .live_reg_top = &.{},
    };
    return proto;
}

fn undumpConstant(self: *UndumpReader, vm: *vm_mod.Vm) UndumpError!bc.Constant {
    _ = vm;
    const tag = try self.readByte();
    return switch (tag) {
        0 => .nil,
        1 => .{ .bool = false },
        2 => .{ .bool = true },
        3 => .{ .int = try self.readI64LE() },
        4 => .{ .num_bits = try self.readU64LE() },
        5 => .{ .str = undefined }, // string interning handled in Task 6
        else => error.BadConstant,
    };
}
```

**NOTE:** The constant string deserialization (tag 5) needs vm interning. This will be wired up in Task 6 when we integrate with the VM. For now it's a placeholder.

- [x] **Step 2: Add `undumpChunk` entry point**

```zig
/// Top-level entry: validate header + read upvalue count + read main proto.
pub fn undumpChunk(self: *UndumpReader, vm: *vm_mod.Vm) UndumpError!*bc.Proto {
    try self.checkHeader();
    const upvalue_count = try self.readByte();
    const main = try self.undumpProto(vm);
    // Override upvalue count from header (PUC does the same)
    // main.upvalues was already read from the body, but the header
    // value is authoritative for the main function.
    _ = upvalue_count; // body already has the right count
    return main;
}
```

- [x] **Step 3: Commit**

```bash
git add src/lua/undump.zig
git commit -m "undump.zig: Proto deserializer (undumpProto, undumpChunk)"
```

---

## Task 5: Wire up `string.dump`

**Files:**
- Modify: `src/lua/vm.zig` — replace stub `builtinStringDump`

- [ ] **Step 1: Find the current stub `builtinStringDump`**

Run: `grep -n "fn builtinStringDump" src/lua/vm.zig`

Read the function and understand what it currently does (side-channel stub).

- [ ] **Step 2: Replace with real serialization**

Replace the body of `builtinStringDump` with:

```zig
fn builtinStringDump(self: *Vm, args: []const Value, outs: []Value) DispatchError!void {
    if (args.len == 0) return self.fail("bad argument #1 to 'dump' (function expected)", .{});
    const strip = if (args.len >= 2) args[1] != .Nil and args[1] != .Bool(false) else false;
    const cl = switch (args[0]) {
        .Closure => |c| c,
        else => return self.fail("bad argument #1 to 'dump' (Lua function expected)", .{}),
    };
    const proto = cl.proto orelse return self.fail("unable to dump given function", .{});

    // Serialize the Proto using the real binary format.
    const dump = @import("dump.zig");
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(self.alloc);
    var writer = dump.DumpWriter.init(self.alloc, &buf);
    writer.dumpChunk(if (strip) stripProto(proto) else proto) catch return error.OutOfMemory;

    // Return as a Lua string.
    const s = self.internStr(buf.items) catch return error.OutOfMemory;
    if (outs.len > 0) {
        outs[0] = .{ .String = s };
        self.last_builtin_out_count = 1;
    }
}
```

Note: `stripProto` returns a shallow copy with debug info cleared. If the existing `cloneStrippedProto` function works, use it. Otherwise, just serialize the full proto and ignore `strip` for now.

- [ ] **Step 3: Build and test**

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/luazig --vm=bc -e "
local f = load('print(3)')
local s = string.dump(f)
print('dump size:', #s)
print('first 4 bytes:', string.byte(s, 1), string.byte(s, 2), string.byte(s, 3), string.byte(s, 4))
"
```

Expected: dump size > 40, first 4 bytes = 27 76 117 97 (0x1b 'L' 'u' 'a')

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "vm.zig: replace stub string.dump with real Proto serialization"
```

---

## Task 6: Wire up binary `load`

**Files:**
- Modify: `src/lua/vm.zig` — replace stub binary path in `builtinLoad`

- [ ] **Step 1: Find the current binary load path**

Run: `grep -n "validateBinaryDumpHeader\|dump_registry\|LZIG\|0x1b" src/lua/vm.zig | head -20`

Read the current binary load path (should be around line 17571).

- [ ] **Step 2: Replace with real deserialization**

In `builtinLoad`, replace the binary-chunk detection block with:

```zig
// Binary chunk: first byte is LUA_SIGNATURE[0] = 0x1b
if (chunk_bytes.len > 0 and chunk_bytes[0] == 0x1b) {
    const undump = @import("undump.zig");
    var reader = undump.UndumpReader.init(self.alloc, chunk_bytes);
    const proto = reader.undumpChunk(self) catch |err| {
        const msg = switch (err) {
            error.TruncatedChunk => "truncated chunk",
            error.BadHeader => "bad binary header",
            error.BadConstant => "bad constant in binary chunk",
            error.OutOfMemory => return error.OutOfMemory,
        };
        return self.fail("{s}", .{msg});
    };
    // Create a closure from the loaded Proto.
    // ... (use existing instantiateLoadedClosure or create new closure)
    return; // success
}
```

**IMPORTANT:** The constant string deserialization needs VM interning. In Task 4, the `undumpConstant` for tag 5 (string) was left as a placeholder. Wire it up:

```zig
5 => {
    const bytes = try self.readString();
    const interned = try vm.internStr(bytes);
    return .{ .str = interned };
},
```

Also, source_name and other strings need interning. These are stored as `[]const u8` in Proto, so they can reference the binary buffer directly (the buffer is kept alive by the closure). Or, for safety, intern them.

- [ ] **Step 3: Build and test roundtrip**

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/luazig --vm=bc -e "
local f = load('return 42')
local s = string.dump(f)
local g = load(s)
print(g())  -- should print 42
"
```

Expected: `42`

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "vm.zig: replace stub binary load with real Proto deserialization"
```

---

## Task 7: Handle `#comment` prefix in file loading

**Files:**
- Modify: `src/lua/vm.zig` — `stripChunkPrefix` or `builtinLoadfile`

- [ ] **Step 1: Verify that `#comment\n` + binary chunk works**

The test is:
```lua
prepfile("#comment\n" .. string.dump(load("print(3)")), true)
RUN('lua %s > %s', prog, out)
checkout('3\n')
```

This writes `#comment\n` + binary data to a file. When luazig loads the file, it should:
1. Detect `#` first line → skip to `\n`
2. Next byte is `0x1b` → binary chunk
3. Load and execute

Check if `stripChunkPrefix` already handles this, or if additional logic is needed.

Run: 
```bash
printf '#comment\n' > /tmp/test_bc_prefix.lua
./zig-out/bin/luazig --vm=bc /tmp/test_bc_prefix.lua 2>&1
```

- [ ] **Step 2: Fix if needed**

If the `#comment\n` prefix causes issues with binary detection, update `stripChunkPrefix` (or the file loading path) to correctly handle binary chunks after a shebang comment.

- [ ] **Step 3: Commit (if changes needed)**

```bash
git add src/lua/vm.zig
git commit -m "vm.zig: handle #comment prefix before binary chunk in file loading"
```

---

## Task 8: Remove old stub infrastructure

**Files:**
- Modify: `src/lua/vm.zig`

- [ ] **Step 1: Remove stub code**

Remove or replace:
- `dump_registry` field and all its uses
- `appendBinaryDumpHeader` (now in dump.zig)
- `validateBinaryDumpHeader` (now in undump.zig)
- `"LZIG"` magic handling
- `"DUMP:"` text-prefix side channel
- `instantiateLoadedClosure` (if no longer needed)
- `cloneStrippedProto` (if replaced by dump.zig's strip handling)

- [ ] **Step 2: Build and verify no regressions**

```bash
zig build -Doptimize=ReleaseFast
python3 tools/testes_matrix.py
```

Expected: 30/31 (same as before)

- [ ] **Step 3: Commit**

```bash
git add src/lua/vm.zig
git commit -m "vm.zig: remove old binary dump/load stub infrastructure"
```

---

## Task 9: Smoke test + regression suite

**Files:**
- Create: `tests/smoke/47_binary_dump.lua`

- [ ] **Step 1: Write smoke test**

```lua
-- Binary chunk roundtrip: dump → load → execute
local f = load("return 1 + 2")
local s = string.dump(f)
assert(type(s) == "string")
assert(#s > 40)  -- at least the header
assert(string.byte(s, 1) == 27)  -- LUA_SIGNATURE[0]

local g = load(s)
assert(type(g) == "function")
assert(g() == 3)

-- More complex function with constants
local h = load("local x = 'hello' .. ' world'; return x")
local sh = string.dump(h)
local h2 = load(sh)
assert(h2() == "hello world")

print("binary dump smoke test passed")
```

- [ ] **Step 2: Run smoke test**

```bash
./zig-out/bin/luazig --vm=bc tests/smoke/47_binary_dump.lua
```

Expected: `binary dump smoke test passed`

- [ ] **Step 3: Run full regression suite**

```bash
python3 tools/testes_matrix.py
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig --vm=bc "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done
```

Expected: matrix 30/31, smoke 47/47

- [ ] **Step 4: Commit**

```bash
git add tests/smoke/47_binary_dump.lua
git commit -m "tests: binary dump/load smoke test"
```

---

## Task 10: Run `all.lua` and update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Run all.lua**

```bash
cd lua-5.5.0/testes && ../../zig-out/bin/luazig --vm=bc all.lua 2>&1 | head -30
```

Check if the binary chunk test (line 441) passes now.

- [ ] **Step 2: Update README**

Add a section documenting:
- Binary chunk format: PUC-compatible header + luazig-native body
- Known limitation: not cross-compatible with PUC luac (opcode remapping is future work)
- Design justification per AGENTS.md

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "README: document binary chunk loading"
```
