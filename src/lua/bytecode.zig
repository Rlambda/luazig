const std = @import("std");

pub const ConstId = u32;
pub const Pc = u32;

// Compact instruction encoding container used by the future BC backend.
// Field semantics are opcode-specific; keeping generic operands lets us
// migrate IR op-by-op without locking ABI too early.
pub const Instruction = packed struct(u64) {
    op: Op,
    a: u8,
    b: u16,
    c: u32,
};

pub const Op = enum(u8) {
    nop,
    move,
    loadk,
    loadbool,
    loadnil,
    getglobal,
    setglobal,
    gettable,
    settable,
    un_not,
    un_minus,
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    eq,
    ne,
    lt,
    lte,
    gt,
    gte,
    call,
    ret,
    jmp,
    jmpif,
    jmpifnot,
    forprep,
    forloop,
    foriter,
};

pub const Constant = union(enum) {
    nil,
    bool: bool,
    int: i64,
    num_bits: u64,
    str: []const u8,

    pub fn num(v: f64) Constant {
        return .{ .num_bits = @bitCast(v) };
    }

    pub fn eql(lhs: Constant, rhs: Constant) bool {
        if (@intFromEnum(lhs) != @intFromEnum(rhs)) return false;
        return switch (lhs) {
            .nil => true,
            .bool => |b| rhs.bool == b,
            .int => |i| rhs.int == i,
            .num_bits => |n| rhs.num_bits == n,
            .str => |s| std.mem.eql(u8, s, rhs.str),
        };
    }
};

// Deduplicated constant pool.
pub const ConstPool = struct {
    items: std.ArrayListUnmanaged(Constant) = .{},
    str_index: std.StringHashMapUnmanaged(ConstId) = .{},
    int_index: std.AutoHashMapUnmanaged(i64, ConstId) = .{},
    num_index: std.AutoHashMapUnmanaged(u64, ConstId) = .{},
    nil_id: ?ConstId = null,
    bool_ids: [2]?ConstId = .{ null, null },

    pub fn deinit(self: *ConstPool, alloc: std.mem.Allocator) void {
        for (self.items.items) |it| {
            if (it == .str) alloc.free(it.str);
        }
        self.items.deinit(alloc);
        self.str_index.deinit(alloc);
        self.int_index.deinit(alloc);
        self.num_index.deinit(alloc);
        self.* = .{};
    }

    pub fn intern(self: *ConstPool, alloc: std.mem.Allocator, c: Constant) !ConstId {
        return switch (c) {
            .nil => self.internNil(alloc),
            .bool => |b| self.internBool(alloc, b),
            .int => |i| self.internInt(alloc, i),
            .num_bits => |bits| self.internNumBits(alloc, bits),
            .str => |s| self.internString(alloc, s),
        };
    }

    fn internNil(self: *ConstPool, alloc: std.mem.Allocator) !ConstId {
        if (self.nil_id) |id| return id;
        const id = try self.appendConst(alloc, .nil);
        self.nil_id = id;
        return id;
    }

    fn internBool(self: *ConstPool, alloc: std.mem.Allocator, b: bool) !ConstId {
        const idx: usize = @intFromBool(b);
        if (self.bool_ids[idx]) |id| return id;
        const id = try self.appendConst(alloc, .{ .bool = b });
        self.bool_ids[idx] = id;
        return id;
    }

    fn internInt(self: *ConstPool, alloc: std.mem.Allocator, i: i64) !ConstId {
        if (self.int_index.get(i)) |id| return id;
        const id = try self.appendConst(alloc, .{ .int = i });
        try self.int_index.put(alloc, i, id);
        return id;
    }

    fn internNumBits(self: *ConstPool, alloc: std.mem.Allocator, bits: u64) !ConstId {
        if (self.num_index.get(bits)) |id| return id;
        const id = try self.appendConst(alloc, .{ .num_bits = bits });
        try self.num_index.put(alloc, bits, id);
        return id;
    }

    fn internString(self: *ConstPool, alloc: std.mem.Allocator, s: []const u8) !ConstId {
        if (self.str_index.get(s)) |id| return id;
        const owned = try alloc.dupe(u8, s);
        const id = try self.appendConst(alloc, .{ .str = owned });
        try self.str_index.put(alloc, owned, id);
        return id;
    }

    fn appendConst(self: *ConstPool, alloc: std.mem.Allocator, c: Constant) !ConstId {
        if (self.items.items.len >= std.math.maxInt(ConstId)) return error.ConstantPoolOverflow;
        try self.items.append(alloc, c);
        return @as(ConstId, @intCast(self.items.items.len - 1));
    }
};

// Run-length encoded source mapping: stores only line transitions.
pub const LineRun = struct {
    pc_start: Pc,
    line: i32,
};

pub const LineTable = struct {
    runs: std.ArrayListUnmanaged(LineRun) = .{},

    pub fn deinit(self: *LineTable, alloc: std.mem.Allocator) void {
        self.runs.deinit(alloc);
        self.* = .{};
    }

    pub fn add(self: *LineTable, alloc: std.mem.Allocator, pc: Pc, line: i32) !void {
        if (self.runs.items.len == 0) {
            try self.runs.append(alloc, .{ .pc_start = pc, .line = line });
            return;
        }
        const last = &self.runs.items[self.runs.items.len - 1];
        if (last.line == line) return;
        if (pc < last.pc_start) return error.InvalidPcOrder;
        try self.runs.append(alloc, .{ .pc_start = pc, .line = line });
    }

    pub fn lineAt(self: *const LineTable, pc: Pc) ?i32 {
        if (self.runs.items.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = self.runs.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.runs.items[mid].pc_start <= pc) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) return null;
        return self.runs.items[lo - 1].line;
    }
};

pub const Chunk = struct {
    code: std.ArrayListUnmanaged(Instruction) = .{},
    const_pool: ConstPool = .{},
    line_table: LineTable = .{},
    max_stack: u16 = 0,
    num_params: u8 = 0,
    is_vararg: bool = false,

    pub fn deinit(self: *Chunk, alloc: std.mem.Allocator) void {
        self.code.deinit(alloc);
        self.const_pool.deinit(alloc);
        self.line_table.deinit(alloc);
        self.* = .{};
    }

    pub fn emit(self: *Chunk, alloc: std.mem.Allocator, inst: Instruction, line: i32) !Pc {
        if (self.code.items.len >= std.math.maxInt(Pc)) return error.BytecodeTooLarge;
        const pc: Pc = @intCast(self.code.items.len);
        try self.code.append(alloc, inst);
        try self.line_table.add(alloc, pc, line);
        return pc;
    }
};

test "const pool deduplicates scalar and string constants" {
    var pool: ConstPool = .{};
    defer pool.deinit(std.testing.allocator);

    const id_nil_1 = try pool.intern(std.testing.allocator, .nil);
    const id_nil_2 = try pool.intern(std.testing.allocator, .nil);
    try std.testing.expectEqual(id_nil_1, id_nil_2);

    const id_int_1 = try pool.intern(std.testing.allocator, .{ .int = 42 });
    const id_int_2 = try pool.intern(std.testing.allocator, .{ .int = 42 });
    try std.testing.expectEqual(id_int_1, id_int_2);

    const id_str_1 = try pool.intern(std.testing.allocator, .{ .str = "hello" });
    const id_str_2 = try pool.intern(std.testing.allocator, .{ .str = "hello" });
    try std.testing.expectEqual(id_str_1, id_str_2);
}

test "line table maps pc to last known line" {
    var lines: LineTable = .{};
    defer lines.deinit(std.testing.allocator);

    try lines.add(std.testing.allocator, 0, 10);
    try lines.add(std.testing.allocator, 1, 10);
    try lines.add(std.testing.allocator, 2, 11);
    try lines.add(std.testing.allocator, 5, 20);

    try std.testing.expectEqual(@as(?i32, 10), lines.lineAt(0));
    try std.testing.expectEqual(@as(?i32, 10), lines.lineAt(1));
    try std.testing.expectEqual(@as(?i32, 11), lines.lineAt(2));
    try std.testing.expectEqual(@as(?i32, 11), lines.lineAt(4));
    try std.testing.expectEqual(@as(?i32, 20), lines.lineAt(5));
}
