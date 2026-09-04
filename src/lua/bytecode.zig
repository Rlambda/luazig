// Bytecode definition for the PUC-style bytecode VM.
//
// This module defines the instruction format, opcode set, Proto (the
// compiled function object), constant pool, and upvalue descriptions.
// It mirrors PUC Lua 5.5's architecture: 32-bit instructions, a stack-pointer
// register allocator (freereg), and the OT/IT multi-value convention.
//
// The codegen walks the AST and emits these instructions directly; the VM
// executes them. There is no IR intermediate — bytecode IS the compilation
// target, exactly as in PUC Lua.

const std = @import("std");
const vm = @import("vm.zig");

// ---------------------------------------------------------------------------
// Instruction format — 32-bit packed struct (PUC Lua 5.5 layout)
// ---------------------------------------------------------------------------
//
// PUC Lua 5.5 uses a 7-bit opcode + 1-bit k flag + 8-bit A + 8-bit B + 8-bit C.
// The k-bit serves double duty: for arithmetic/bitwise K/I-variant opcodes it
// encodes the commutative-swap flip flag (codecommutative); for other opcodes
// it carries opcode-specific meaning (e.g. TEST skip-on-true/false). Zig
// packed structs are LSB-first, so the bit layout matches PUC's binary format
// exactly: [C:8 B:8 k:1 A:8 op:7] from MSB to LSB.
//
// Registers are u8 (0–254 valid; 255 = NO_REG sentinel, PUC lopcodes.h:
// MAX_FSTACK = MAXARG_A = 255, NO_REG = MAX_FSTACK).

pub const Instruction = packed struct(u32) {
    op: u7, // opcode (128 max)
    a: u8, // register A, or low byte of jump offset
    k: u1, // k flag: commutative flip for arith K/I-variants, opcode-specific otherwise
    b: u8, // register B, constant index, or mid byte of jump offset
    c: u8, // register C, count, or high byte of jump offset

    /// Create an instruction with three register/count operands (k=0).
    pub fn make(op: Op, a: u8, b: u8, c: u8) Instruction {
        return .{ .op = @intFromEnum(op), .a = a, .k = 0, .b = b, .c = c };
    }

    /// Create an instruction with three operands and an explicit k flag.
    /// Used by arithmetic/bitwise K/I-variant opcodes to carry the
    /// commutative-swap flip flag (PUC GETARG_k).
    pub fn makeK(op: Op, a: u8, b: u8, c: u8, k: bool) Instruction {
        return .{ .op = @intFromEnum(op), .a = a, .k = if (k) 1 else 0, .b = b, .c = c };
    }

    /// Create a simple instruction (op only, operands zeroed).
    pub fn simple(op: Op) Instruction {
        return .{ .op = @intFromEnum(op), .a = 0, .k = 0, .b = 0, .c = 0 };
    }

    /// Create a jump instruction with a signed 24-bit offset.
    pub fn jump(op: Op, offset: i32) Instruction {
        const u: u32 = @bitCast(offset);
        return .{
            .op = @intFromEnum(op),
            .a = @truncate(u),
            .k = 0,
            .b = @truncate(u >> 8),
            .c = @truncate(u >> 16),
        };
    }

    /// Get the signed 24-bit jump offset stored in a, b, c.
    pub fn jumpOffset(self: Instruction) i32 {
        const u: u32 = @as(u32, self.a) | (@as(u32, self.b) << 8) | (@as(u32, self.c) << 16);
        // Sign-extend from 24 bits.
        if (u & 0x800000 != 0) return @bitCast(u | 0xFF000000);
        return @bitCast(u);
    }

    /// Get the 24-bit extra argument stored in a, b, c (unsigned).
    pub fn extraArg(self: Instruction) u32 {
        return @as(u32, self.a) | (@as(u32, self.b) << 8) | (@as(u32, self.c) << 16);
    }

    /// Create an EXTRAARG instruction with a 24-bit value.
    pub fn extra(val: u32) Instruction {
        return .{
            .op = @intFromEnum(Op.extraarg),
            .a = @truncate(val),
            .k = 0,
            .b = @truncate(val >> 8),
            .c = @truncate(val >> 16),
        };
    }

    /// Encode a signed value as 17-bit sBx across k:b:c (PUC sBx with OFFSET).
    ///
    /// Used by LOADI/LOADF: the k-bit extends the 16-bit b:c immediate to a
    /// 17-bit signed offset (range [-65535, 65535]). This mirrors PUC Lua
    /// 5.5's `MAXARG_sBx >> 1 = 65535` bias: the stored bits are
    /// `value + OFFSET_sBx` so the unsigned 17-bit field maps [-65535, 65535]
    /// onto [0, 131070]. PUC lopcodes.h:OFFSET_sBx = MAXARG_sBx >> 1.
    pub fn loadImm(op: Op, a: u8, value: i32) Instruction {
        const off: u32 = @bitCast(value +% 65535);
        return .{
            .op = @intFromEnum(op),
            .a = a,
            .k = @intCast((off >> 16) & 1),
            .b = @truncate(off),
            .c = @truncate(off >> 8),
        };
    }
};

// ---------------------------------------------------------------------------
// Opcode set — PUC-like, simplified
// ---------------------------------------------------------------------------
//
// Opcodes are grouped by category. Where PUC Lua uses a `k` bit for RK
// encoding (register-or-constant), we use separate K-variant opcodes (to be
// added as an optimization). For now, constants are always loaded via LOADK
// before use.

pub const Op = enum(u7) {
    // --- Moves / loads ---
    move, // R[A] = R[B]
    loadk, // R[A] = K[B]            (B ≤ 255)
    loadkx, // R[A] = K[EXTRAARG]    (followed by EXTRAARG)
    loadi, // R[A] = (i64)(sBx)      (k:b:c = 17-bit signed, range ±65535)
    loadf, // R[A] = (f64)(sBx)      (k:b:c = 17-bit signed, range ±65535)
    loadnil, // R[A..A+B] = nil
    loadtrue, // R[A] = true
    loadfalse, // R[A] = false

    // --- Globals (via _ENV upvalue) ---
    gettabup, // R[A] = UpVal[B][K[C]]  (read global)
    settabup, // UpVal[A][K[B]] = R[C]  (write global)

    // --- Upvalues ---
    getupval, // R[A] = UpVal[B]
    setupval, // UpVal[B] = R[A]

    // --- Table gets ---
    gettable, // R[A] = R[B][R[C]]
    geti, // R[A] = R[B][C]           (integer key)
    getfield, // R[A] = R[B][K[C]]    (string key)
    // Virtual vararg access (PUC 5.5 OP_GETVARG). R[A] := vararg[R[C]],
    // where R[C] is the key (integer index or string "n"). Reads directly
    // from the extra-args slice on the stack — no vararg table needed.
    getvarg, // R[A] = vararg_param[R[C]]

    // --- Table sets ---
    settable, // R[A][R[B]] = R[C]
    seti, // R[A][B] = R[C]           (integer key)
    setfield, // R[A][K[B]] = R[C]    (string key)

    // --- Tables ---
    newtable, // R[A] = {}, array hint C, hash hint B
    self, // R[A+1] = R[B]; R[A] = R[B][K[C]]  (method call setup)

    // --- Arithmetic (register/register) ---
    add, // R[A] = R[B] + R[C]
    sub, // R[A] = R[B] - R[C]
    mul, // R[A] = R[B] * R[C]
    div, // R[A] = R[B] / R[C]
    mod, // R[A] = R[B] % R[C]
    pow, // R[A] = R[B] ^ R[C]
    idiv, // R[A] = R[B] // R[C]     (floor division)

    // --- Arithmetic (immediate/constant variants, PUC 5.5 style) ---
    // ADDI: R[A] = R[B] + sC  (sC is signed 8-bit, offset by 128)
    addi, // R[A] = R[B] + sC
    // K-variants: R[A] = R[B] <op> K[C]  (C is constant pool index)
    addk, // R[A] = R[B] + K[C]:number
    subk, // R[A] = R[B] - K[C]:number
    mulk, // R[A] = R[B] * K[C]:number
    modk, // R[A] = R[B] % K[C]:number
    powk, // R[A] = R[B] ^ K[C]:number
    divk, // R[A] = R[B] / K[C]:number
    idivk, // R[A] = R[B] // K[C]:number

    // --- Bitwise ---
    band, // R[A] = R[B] & R[C]
    bor, // R[A] = R[B] | R[C]
    bxor, // R[A] = R[B] ~ R[C]
    shl, // R[A] = R[B] << R[C]
    shr, // R[A] = R[B] >> R[C]

    // --- Metamethod bookkeeping (PUC 5.5 MMBIN family) ---
    // These follow arithmetic/bitwise opcodes as metamethod event markers.
    // luazig's VM treats them as no-ops: metamethods are handled inline in
    // the arith/bitwise opcodes themselves. They exist for bytecode parity
    // with PUC 5.5 so the compiler can emit them in a later task.
    mmbin, // metamethod event marker (register operands)
    mmbini, // metamethod event marker (immediate operand)
    mmbink, // metamethod event marker (constant operand)

    // --- Boolean literals (PUC 5.5) ---
    // loadfalse already exists above. lfalseskip loads false and skips the
    // next instruction — used by PUC for boolean expression folding.
    lfalseskip, // R[A] = false; pc++ (skip next instruction)

    // --- Bitwise (constant variants) ---
    bandk, // R[A] = R[B] & K[C]:integer
    bork, // R[A] = R[B] | K[C]:integer
    bxork, // R[A] = R[B] ~ K[C]:integer

    // --- Shifts (immediate variants) ---
    shli, // R[A] = sC << R[B]  (sC is signed 8-bit)
    shri, // R[A] = R[B] >> sC  (sC is signed 8-bit)

    // --- Unary ---
    unm, // R[A] = -R[B]
    bnot, // R[A] = ~R[B]
    not, // R[A] = not R[B]
    len, // R[A] = #R[B]

    // --- Concat ---
    concat, // R[A] = R[A] .. ... .. R[A+B-1]

    // --- Control flow ---
    // Comparisons: if condition holds, skip next instruction (which must be JMP).
    // C=0: skip when condition is true; C=1: skip when condition is false.
    // (This matches PUC's k-bit convention: k=0 → skip on true, k=1 → skip on false.)
    eq, // if (R[A] == R[B]) != (C!=0) then pc++
    lt, // if (R[A] <  R[B]) != (C!=0) then pc++
    le, // if (R[A] <= R[B]) != (C!=0) then pc++
    // For > and >=, swap operands and use lt/le.

    // P15.38d: Immediate comparison opcodes (PUC EQI/LTI/LEI/GTI/GEI/EQK).
    // Compare R[A] against a signed immediate (sB) or constant (K[B]),
    // eliminating a preceding LOADI/LOADK. sB is a signed 8-bit
    // integer stored in the B field (reinterpreted via int2sB).
    eqi, // if (R[A] == sB) != (C!=0) then pc++
    lti, // if (R[A] <  sB) != (C!=0) then pc++
    lei, // if (R[A] <= sB) != (C!=0) then pc++
    gti, // if (R[A] >  sB) != (C!=0) then pc++
    gei, // if (R[A] >= sB) != (C!=0) then pc++
    eqk, // if (R[A] == K[B]) != (C!=0) then pc++

    // Test: conditional skip based on truthiness of R[A].
    // C=0: skip if R[A] is truthy; C=1: skip if R[A] is falsy.
    test_, // if (not R[A]) == (C!=0) then pc++  [matches PUC's TEST k-bit]
    // Test+assign: like test, but also assigns R[B] to R[A] when NOT skipping.
    testset, // if (not R[B]) == (C!=0) then pc++ else R[A] = R[B]

    // Unconditional jump (signed 24-bit offset in a:b:c).
    jmp, // pc += offset

    // --- Calls / returns (OT/IT multi-value) ---
    // CALL: R[A..A+C-2] := R[A](R[A+1..A+B-1])
    //   B=0 → use top (multi-value args from previous OT instruction)
    //   C=0 → set top (multi-value results, for next IT instruction)
    call, // A=func, B=nargs+1 (0=multret), C=nresults+1 (0=set top)
    // TAILCALL: return R[A](R[A+1..A+B-1])
    //   B=0 → use top; k equivalent not needed (needclose tracked on proto)
    tailcall, // A=func, B=nargs+1 (0=multret)
    // RETURN: return R[A..A+B-2]
    //   B=0 → use top (multi-value return from previous OT instruction)
    return_, // A=base, B=count+1 (0=multret)
    return0, // return (no values)
    return1, // return R[A]

    // --- Numeric for ---
    // R[A]=init, R[A+1]=limit, R[A+2]=step, R[A+3]=loop var
    forprep, // prepare; if loop shouldn't run, pc += offset (in a:b:c)
    forloop, // add step, compare; if loop continues, pc -= offset (in a:b:c)

    // --- Generic for ---
    // R[A]=iterator, R[A+1]=state, R[A+2]=control, R[A+3]=close value
    tforprep, // create upvalue for R[A+3]; pc += offset (skip to after loop)
    // R[A+4..A+3+C] := R[A](R[A+1], R[A+2])
    tforcall, // A=base, C=nresults+1
    tforloop, // if R[A+2] != nil then R[A]=R[A+2]; pc -= offset (in a:b:c)

    // --- Table constructor ---
    // R[A][C+i] := R[A+i] for 1<=i<=B
    //   B=0 → use top (multi-value from previous OT instruction)
    setlist, // A=table, B=count (0=multret), C=base index (may need EXTRAARG)

    // --- Closures ---
    closure, // R[A] = closure(P[B])  (B = proto index, may need EXTRAARG)

    // --- Upvalue / scope management ---
    close, // close all upvalues >= R[A]
    tbc, // mark R[A] as to-be-closed

    // --- Varargs ---
    // R[A..A+C-2] = varargs
    //   C=0 → set top (all varargs, for next IT instruction)
    vararg, // A=base, C=count+1 (0=set top)
    varargprep, // first instruction of a vararg function; adjusts varargs

    // --- Error ---
    errdefined, // raise if R[A] != nil (global initialization redefinition)
    errnnil, // raise error if R[A] == nil (declared global is nil)

    // --- Extended argument ---
    extraarg, // 24-bit argument for the preceding instruction
};

// ---------------------------------------------------------------------------
// Constant pool — deduplicated
// ---------------------------------------------------------------------------

pub const Constant = union(enum) {
    nil,
    bool: bool,
    int: i64,
    num_bits: u64, // f64 stored as bits for exact comparison
    str: *vm.LuaString, // interned string pointer

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
            .str => |s| s == rhs.str,
        };
    }
};

pub const ConstPool = struct {
    items: std.ArrayListUnmanaged(Constant) = .empty,
    str_index: std.StringHashMapUnmanaged(u32) = .{},
    int_index: std.AutoHashMapUnmanaged(i64, u32) = .{},
    num_index: std.AutoHashMapUnmanaged(u64, u32) = .{},
    nil_id: ?u32 = null,
    bool_ids: [2]?u32 = .{ null, null },

    pub fn deinit(self: *ConstPool, alloc: std.mem.Allocator) void {
        for (self.items.items) |it| {
            if (it == .str) vm.destroyLuaString(alloc, it.str);
        }
        self.items.deinit(alloc);
        self.str_index.deinit(alloc);
        self.int_index.deinit(alloc);
        self.num_index.deinit(alloc);
        self.* = .{};
    }

    pub fn intern(self: *ConstPool, alloc: std.mem.Allocator, c: Constant) !u32 {
        return switch (c) {
            .nil => self.internNil(alloc),
            .bool => |b| self.internBool(alloc, b),
            .int => |i| self.internInt(alloc, i),
            .num_bits => |bits| self.internNumBits(alloc, bits),
            .str => |ls| self.internOwnedString(alloc, ls),
        };
    }

    fn internNil(self: *ConstPool, alloc: std.mem.Allocator) !u32 {
        if (self.nil_id) |id| return id;
        const id = try self.append(alloc, .nil);
        self.nil_id = id;
        return id;
    }

    fn internBool(self: *ConstPool, alloc: std.mem.Allocator, b: bool) !u32 {
        const idx: usize = @intFromBool(b);
        if (self.bool_ids[idx]) |id| return id;
        const id = try self.append(alloc, .{ .bool = b });
        self.bool_ids[idx] = id;
        return id;
    }

    fn internInt(self: *ConstPool, alloc: std.mem.Allocator, i: i64) !u32 {
        if (self.int_index.get(i)) |id| return id;
        const id = try self.append(alloc, .{ .int = i });
        try self.int_index.put(alloc, i, id);
        return id;
    }

    fn internNumBits(self: *ConstPool, alloc: std.mem.Allocator, bits: u64) !u32 {
        if (self.num_index.get(bits)) |id| return id;
        const id = try self.append(alloc, .{ .num_bits = bits });
        try self.num_index.put(alloc, bits, id);
        return id;
    }

    /// Intern a string constant from raw bytes: create one canonical
    /// `*LuaString` per distinct content.
    pub fn internString(self: *ConstPool, alloc: std.mem.Allocator, s: []const u8) !u32 {
        if (self.str_index.get(s)) |id| return id;
        var h = std.hash.Wyhash.init(0);
        h.update(s);
        const ls = try vm.createLuaString(alloc, s, h.final());
        errdefer vm.destroyLuaString(alloc, ls);
        const id = try self.append(alloc, .{ .str = ls });
        try self.str_index.put(alloc, ls.bytes(), id);
        return id;
    }

    fn internOwnedString(self: *ConstPool, alloc: std.mem.Allocator, ls: *vm.LuaString) !u32 {
        if (self.str_index.get(ls.bytes())) |id| {
            vm.destroyLuaString(alloc, ls);
            return id;
        }
        const id = try self.append(alloc, .{ .str = ls });
        try self.str_index.put(alloc, ls.bytes(), id);
        return id;
    }

    fn append(self: *ConstPool, alloc: std.mem.Allocator, c: Constant) !u32 {
        if (self.items.items.len >= std.math.maxInt(u32)) return error.ConstantPoolOverflow;
        try self.items.append(alloc, c);
        return @intCast(self.items.items.len - 1);
    }
};

// ---------------------------------------------------------------------------
// Upvalue description — declarative, like PUC Lua's Upvaldesc
// ---------------------------------------------------------------------------

pub const Upvaldesc = struct {
    /// true = captures a register from the enclosing function (instack in PUC);
    /// false = proxies an upvalue from the enclosing function.
    instack: bool,
    /// Register index (if instack) or upvalue index (if not).
    idx: u8,
    /// true = read-only (const attribute propagated through closure capture).
    is_const: bool,
    /// Debug name (PUC: `TString *name` — pointer-only, 8B). Packed
    /// ptr + u32 len instead of a 16B Zig slice (P16.16 C4/T7):
    /// 24→16 = PUC's Upvaldesc size. Stripped chunks carry a null
    /// pointer + 0 length (PUC: name == NULL).
    name_ptr: ?[*]const u8 = null,
    name_len: u32 = 0,

    /// The debug name as a slice (empty when stripped/null).
    pub inline fn name(self: Upvaldesc) []const u8 {
        const p = self.name_ptr orelse return &.{};
        return p[0..self.name_len];
    }

    /// Construct a descriptor from a name slice (empty slice → null ptr,
    /// the stripped representation).
    pub fn make(instack: bool, idx: u8, is_const: bool, name_: []const u8) Upvaldesc {
        return .{
            .instack = instack,
            .idx = idx,
            .is_const = is_const,
            .name_ptr = if (name_.len == 0) null else name_.ptr,
            .name_len = @intCast(name_.len),
        };
    }
};

// ---------------------------------------------------------------------------
// Local variable debug info
// ---------------------------------------------------------------------------

pub const LocVar = struct {
    name: []const u8,
    /// Register that stores this local while it is active.  PUC can derive
    /// this from LocVar ordering plus the active-local stack; keeping it
    /// explicit matches this compiler's register-reuse model and lets debug
    /// name inference distinguish bytecode closures without IR placeholders.
    reg: u8,
    startpc: u32,
    endpc: u32,
};

// ---------------------------------------------------------------------------
// SourceBacking — compact source-byte lifetime tracking (CUT2)
// ---------------------------------------------------------------------------
//
// Keeps alive the bytes that the tree's debug lexeme slices borrow (locvar/
// upvalue names, function name, source_name; fixed-buffer undump also borrows
// long-string constants). PUC Lua has no explicit backing tracking — Proto
// IS a GC object and its debug strings are GC-managed TStrings.
//
// CUT2 compact representation (16B inline, down from 88B):
//   pin:   single GC-pinned source LuaString (common case: 1 pin)
//   extra: ?*SourceBackingExtra for rare multi-pin/owned/name_copies
//
// For the common case (1 pin via builtinLoadEx) the inline fields suffice
// and no extra allocation is needed. For rare cases (multiple pins, owned
// buffers, name_copies), extra is heap-allocated with the full list-based
// backing.
//
// P16.16 C6: the former `external_borrow` span (C-API load mode 'B') was
// removed — it was written once at load and never read: the borrowed bytes
// are CALLER-OWNED for the tree's whole lifetime (never freed, never
// GC-marked by us), so recording the span served no lifetime-tracking
// purpose. The borrow contract is documented at the load site instead.

/// Compact source backing (16B inline in Proto). Covers the common case
/// (1 pin) without allocation. Rare cases use extra.
pub const SourceBacking = struct {
    /// Single GC-pinned source LuaString (common: builtinLoadEx load(string)).
    /// For multi-pin, the first pin lives here; additional pins go in extra.
    pin: ?*vm.LuaString = null,
    /// Rare-case backing (multi-pin, owned buffers, name_copies).
    /// Heap-allocated only when needed; null for the common case.
    extra: ?*SourceBackingExtra = null,

    /// Ensure extra exists (allocates if null). Returns the extra for
    /// appending to pinned/owned/name_copies lists.
    pub fn ensureExtra(self: *SourceBacking, alloc: std.mem.Allocator) !*SourceBackingExtra {
        if (self.extra) |e| return e;
        const e = try alloc.create(SourceBackingExtra);
        e.* = .{};
        self.extra = e;
        return e;
    }

    /// Add a GC-pinned source string. First pin goes inline; additional
    /// pins go to extra.pinned.
    pub fn addPin(self: *SourceBacking, alloc: std.mem.Allocator, str: *vm.LuaString) !void {
        if (self.pin == null) {
            self.pin = str;
        } else {
            const e = try self.ensureExtra(alloc);
            // Move the first pin to extra, then set the new one inline.
            try e.pinned.append(alloc, self.pin.?);
            self.pin = str;
        }
    }

    /// Add an owned byte buffer (reader-fn collection, shebang prefix, API
    /// copies). Goes to extra.owned. The tree frees this at last release.
    pub fn addOwned(self: *SourceBacking, alloc: std.mem.Allocator, bytes: []const u8) !void {
        const e = try self.ensureExtra(alloc);
        try e.owned.append(alloc, bytes);
    }

    /// Add a debug-name copy (cloneUndumpedStrings). Goes to
    /// extra.name_copies. The tree frees this at last release.
    pub fn addNameCopy(self: *SourceBacking, alloc: std.mem.Allocator, bytes: []const u8) !void {
        const e = try self.ensureExtra(alloc);
        try e.name_copies.append(alloc, bytes);
    }

    /// Number of owned byte buffers (for test assertions).
    pub fn ownedCount(self: *const SourceBacking) usize {
        if (self.extra) |e| return e.owned.items.len;
        return 0;
    }

    /// Get owned buffer by index (for test assertions).
    pub fn ownedAt(self: *const SourceBacking, idx: usize) []const u8 {
        return self.extra.?.owned.items[idx];
    }

    /// Free owned buffers and extra. Pins are GC-owned (not freed here).
    /// External borrows are caller-owned (not freed).
    pub fn deinit(self: *SourceBacking, alloc: std.mem.Allocator) void {
        if (self.extra) |e| {
            e.deinit(alloc);
            alloc.destroy(e);
        }
        self.* = .{};
    }

    /// Whether this backing has any pins (inline or extra).
    pub fn hasPins(self: *const SourceBacking) bool {
        if (self.pin != null) return true;
        if (self.extra) |e| return e.pinned.items.len > 0;
        return false;
    }

    /// Iterate over pinned strings (for GC marking). Returns the inline
    /// pin first, then extra.pinned items.
    pub fn forEachPin(self: *const SourceBacking, comptime ctx_fn: anytype, ctx: anytype) void {
        if (self.pin) |s| ctx_fn(ctx, s);
        if (self.extra) |e| {
            for (e.pinned.items) |s| ctx_fn(ctx, s);
        }
    }
};

/// Rare-case source backing (multi-pin, owned buffers, name_copies).
/// Heap-allocated only when the compact SourceBacking's inline fields
/// are insufficient.
pub const SourceBackingExtra = struct {
    /// Additional GC-pinned LuaStrings (beyond the first, which is inline).
    pinned: std.ArrayListUnmanaged(*vm.LuaString) = .empty,
    /// Heap byte buffers the tree owns outright (reader-fn collection,
    /// shebang-prefixed buffers, API copies). Freed at deinit.
    owned: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Debug-name copies (cloneUndumpedStrings). Freed at deinit.
    name_copies: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *SourceBackingExtra, alloc: std.mem.Allocator) void {
        for (self.owned.items) |b| alloc.free(b);
        for (self.name_copies.items) |b| alloc.free(b);
        self.pinned.deinit(alloc);
        self.owned.deinit(alloc);
        self.name_copies.deinit(alloc);
        self.* = .{};
    }
};

/// Compute the native memory footprint of a SourceBackingExtra (for GC
/// accounting). Includes the struct itself, list storage, and owned/name
/// buffer bytes. Pins are GC-owned (not counted).
pub fn sourceBackingExtraFootprint(extra: SourceBackingExtra) usize {
    var total: usize = @sizeOf(SourceBackingExtra);
    for (extra.owned.items) |b| total += b.len;
    for (extra.name_copies.items) |b| total += b.len;
    total += extra.pinned.items.len * @sizeOf(*vm.LuaString);
    total += extra.owned.items.len * @sizeOf([]const u8);
    total += extra.name_copies.items.len * @sizeOf([]const u8);
    return total;
}

// ---------------------------------------------------------------------------
// Proto — the compiled function object (CUT2: owner fields merged in)
// ---------------------------------------------------------------------------
//
// CUT2 merges ProtoTreeOwner into the root Proto, eliminating the separately
// allocated 144B owner struct. The root Proto carries owner fields directly
// (ref_count, vm, source_backing, flags, gc_charged/gc_footprint). Non-root
// protos have these fields zeroed; `.tree` points to the root proto.
//
// PUC model: the Proto IS the ownership root. There's no separate owner.
// CUT2 achieves the same: the root Proto IS the owner.
//
// `.tree` semantics:
//   null     → owner-less (under construction, unit test proto)
//   self     → root proto (owner fields are valid)
//   other    → non-root proto (points to root; owner fields are zeroed)

/// Free an entire proto tree structurally: every array, every seed-0
/// string constant that is still tree-owned, every Proto struct —
/// recursively. This is the single deinit implementation shared by
/// `ProtoTreeOwner.release` (production) and construction error paths
/// (Codegen.deinit leftovers, undump partial trees) that have no owner.
///
/// `k_strings_vm_owned` mirrors `ProtoTreeOwner.k_strings_vm_owned`: when
/// false (unresolved text tree) the `.str` constants are seed-0 LuaStrings
/// owned by the tree and destroyed here; when true they belong to the VM
/// string table (or are `undefined` in no-callback undump unit tests) and
/// are never touched.
///
/// CUT1 aliasing: for undumped trees after adoption, `k` has been aliased
/// to `resolved_values` (in-place Constant→Value conversion). `k.len == 0`
/// and `resolved_values` holds the single allocation. When aliased, the
/// allocation is freed via `resolved_values` below; `k` is skipped (its
/// zero-length slice shares the allocation ptr — freeing it would
/// double-free).
pub fn destroyProtoTree(alloc: std.mem.Allocator, root: *Proto, k_strings_vm_owned: bool) void {
    // PUC PF_FIXED parity: when fixed_arrays is set, code and lineinfo are
    // borrowed from the input buffer (not tree-owned). Skip freeing them —
    // the input buffer's lifetime is managed by source_backing (on the
    // root proto in CUT2). PUC's luaF_freeproto (lfunc.c:285-287) does the
    // same check via `PF_FIXED` on `f->flag`.
    if (!root.flags.fixed_arrays) alloc.free(root.code);
    // CUT1: detect k-aliased-to-resolved_values (undumped trees after
    // adoption). When aliased, k.len==0 and resolved_values.len>0; the
    // single allocation is freed via resolved_values below. For all other
    // cases (compiled trees, undumped trees before adoption), k is a
    // separate allocation (or &.{} for no-constant protos) freed here.
    const k_aliased = root.k.len == 0 and root.resolved_values.len > 0;
    if (!k_aliased) {
        if (!k_strings_vm_owned) {
            for (root.k) |c| {
                if (c == .str) vm.destroyLuaString(alloc, c.str);
            }
        }
        alloc.free(root.k);
    }
    // Recursive call frees each child's subtree INCLUDING the child struct.
    for (root.p) |child| {
        destroyProtoTree(alloc, child, k_strings_vm_owned);
    }
    alloc.free(root.p);
    alloc.free(root.upvalues);
    if (!root.flags.fixed_arrays) alloc.free(root.lineinfo);
    alloc.free(root.locvars);
    if (root.live_reg_top.len > 0) alloc.free(root.live_reg_top);
    if (root.resolved_values.len > 0) alloc.free(root.resolved_values);
    // CUT2: source_backing is now on the root proto. Deinit it before
    // destroying the struct. For non-root protos (recursive calls),
    // source_backing is empty (.{}) so deinit is a no-op. For the root,
    // this frees owned buffers and name_copies; pins are GC-owned and
    // external borrows are caller-owned (neither freed here).
    root.source_backing.deinit(alloc);
    alloc.destroy(root);
    // name/source_name/locvar names are borrowed from the source bytes;
    // they are NOT freed here (backing owned by source_backing, just deinit'd).
}

/// Compute the native memory footprint of a Proto tree: all Proto structs
/// plus every owned array (code, k, p, upvalues, lineinfo, locvars,
/// live_reg_top, resolved_values). Recursively sums children.
///
/// Does NOT include:
///   - Interned LuaStrings (owned by the VM string table, already charged
///     by `internStr`).
///   - Seed-0 LuaStrings in unresolved text trees (transient — destroyed
///     at resolution; the interned replacements are already charged).
///   - The ProtoTreeOwner struct and SourceBacking (added separately by
///     `chargeTreeFootprint` in vm.zig).
///   - BORROWED code/lineinfo arrays when `fixed_arrays` is set (PUC
///     PF_FIXED parity: these point into the input buffer, which is pinned
///     by source_backing and already charged as a GC object — the LuaString
///     holding the binary chunk). Excluding them here is what makes
///     `collectgarbage("count")` rise < 400 bytes after a fixed-buffer
///     binary load (api.lua:580), matching PUC Lua's behavior where
///     `luaF_freeproto` skips freeing code when PF_FIXED is set.
///
/// This is the amount charged to `gc_count_kb` at adoption and credited
/// at last release, mirroring PUC Lua where Proto IS a GC object charged
/// at `luaC_newobj(L, LUA_VPROTO, sizeof(Proto))`.
pub fn protoTreeFootprint(root: *const Proto) usize {
    var total: usize = @sizeOf(Proto);
    // PUC PF_FIXED: exclude borrowed code/lineinfo from the footprint.
    if (!root.flags.fixed_arrays) {
        total += root.code.len * @sizeOf(Instruction);
        total += root.lineinfo.len * @sizeOf(u32);
    }
    total += root.k.len * @sizeOf(Constant);
    total += root.p.len * @sizeOf(*Proto);
    total += root.upvalues.len * @sizeOf(Upvaldesc);
    total += root.locvars.len * @sizeOf(LocVar);
    total += root.live_reg_top.len * @sizeOf(u8);
    total += root.resolved_values.len * @sizeOf(vm.Value);
    for (root.p) |child| {
        total += protoTreeFootprint(child);
    }
    return total;
}

/// Compute the native memory footprint of a compact `SourceBacking` (CUT2):
/// the inline struct itself (already counted via @sizeOf(Proto) on root),
/// plus any `SourceBackingExtra` (rare case) and its owned/name buffer bytes.
/// Pinned LuaStrings are GC-owned and NOT included. External borrows are
/// caller-owned and NOT included (and, since P16.16 C6, not even recorded).
/// The inline `pin` pointer is part of @sizeOf(Proto) and not added here.
pub fn sourceBackingFootprint(sb: SourceBacking) usize {
    if (sb.extra) |e| {
        return sourceBackingExtraFootprint(e.*);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Constant access helpers (CUT1: dual representation elimination)
// ---------------------------------------------------------------------------
//
// For COMPILED (text) trees, `proto.k` (Constant[]) holds the compile-time
// constant pool and `proto.resolved_values` (Value[]) holds the runtime
// values built at adoption — both arrays exist (double storage, needed
// because k holds compile-time Constant that must survive for source/debug
// info and dump round-trips).
//
// For UNDUMPED (binary) trees after adoption, CUT1 aliases resolved_values
// onto the SAME allocation as k via in-place Constant→Value conversion
// (both are 16B, align 8; .int→.Int, .num_bits→.Num, .str→.String are
// value-preserving rewrites). After conversion, k.len==0 and
// resolved_values is the single constant array. This mirrors PUC Lua,
// where Proto.k IS the runtime TValue array (no separate compile-time
// representation).
//
// Invariant: "undumped trees have k.len==0 and resolved_values as the
// single constant array (aliased onto the original k allocation);
// compiled trees have both k (compile-time Constant) and resolved_values
// (runtime Value)."
//
// These helpers let readers (dump, debug, disassembly) access constants
// uniformly regardless of which representation is active.

/// Read the constant at index `kidx` from whichever array is active:
/// `proto.k` for compiled trees (or undumped trees before adoption),
/// `proto.resolved_values` for undumped trees after adoption (aliased).
/// Returns null if kidx is out of range or the Value is not a
/// constant-type (nil/bool/int/num/string).
pub fn protoConstAt(proto: *const Proto, kidx: usize) ?Constant {
    if (kidx < proto.k.len) return proto.k[kidx];
    if (kidx < proto.resolved_values.len) {
        return switch (proto.resolved_values[kidx]) {
            .Nil => .nil,
            .Bool => |b| .{ .bool = b },
            .Int => |i| .{ .int = i },
            .Num => |n| .{ .num_bits = @bitCast(n) },
            .String => |s| .{ .str = s },
            else => null,
        };
    }
    return null;
}

/// Number of constants in this proto. For compiled trees, k.len; for
/// undumped trees after adoption (k.len==0), resolved_values.len.
pub fn protoConstCount(proto: *const Proto) usize {
    if (proto.k.len > 0) return proto.k.len;
    return proto.resolved_values.len;
}

// ---------------------------------------------------------------------------
// Proto — the compiled function object
// ---------------------------------------------------------------------------

pub const Proto = struct {
    /// Bytecode instructions.
    code: []const Instruction,
    /// Deduplicated constant pool. Mutable so the VM can resolve string
    /// constants in-place: at adoption, compile-time `*LuaString`
    /// objects (hashed with seed 0) are replaced by VM-interned pointers
    /// (hashed with the VM's per-instance seed). After resolution,
    /// string constants are owned by the VM's intern table — whether the
    /// pool is still tree-owned is recorded STRUCTURALLY on the tree
    /// owner (`ProtoTreeOwner.k_strings_vm_owned`), never per-proto.
    k: []Constant,
    /// The tree this proto belongs to (CUT2: owner merged into root Proto).
    ///
    /// Semantics:
    ///   null  → owner-less (under construction, or unit test proto)
    ///   self  → this IS the root proto (owner fields below are valid)
    ///   other → non-root proto (points to root; owner fields are zeroed)
    ///
    /// Every production proto is bound for its whole observable lifetime.
    /// `ProtoBuilder.finish()` and `UndumpReader.undumpChunk()` bind the
    /// finished/deserialized tree (root .tree = self, children .tree = root).
    tree: ?*Proto = null,

    // --- CUT2 owner fields (valid only on root proto where tree == self) ---
    // These replace the former ProtoTreeOwner struct. Non-root protos have
    // them zeroed/null/false. Only the root proto carries ownership state.
    //
    // PUC model: the Proto IS the ownership root (no separate owner). CUT2
    // achieves the same: the root Proto IS the owner.
    //
    // P16.16 C6: the four former standalone bools (k_strings_vm_owned,
    // constants_resolved, gc_charged, fixed_arrays) are packed into one
    // `flags: Flags` byte (packed struct(u8)) — bool semantics preserved,
    // 4 bytes → 1.

    /// Tree-wide state flags (P16.16 C6: packed bools, 1 byte total).
    /// Valid only on root (tree == self); zeroed on non-root protos.
    flags: Flags = .{},

    /// Number of live references (producing reference + one per Closure).
    /// Reaching 0 in `releaseTree` performs the one-time tree deinit.
    /// Valid only on root (tree == self).
    /// P16.16 C6: usize → u32 — a tree can never reach 4G live closures.
    ref_count: u32 = 0,
    /// VM identity binding (P16.10b Task 8): the `*Vm` (as `*anyopaque` to
    /// avoid a circular import) this tree's constants were interned into /
    /// executes on. Valid only on root.
    vm: ?*anyopaque = null,
    /// Source backing (CUT2 compact): keeps alive the bytes that the tree's
    /// debug lexeme slices borrow. Valid only on root.
    source_backing: SourceBacking = .{},
    /// GC memory accounting (Task 7): false on construction, set true at
    /// adoption (first closure creation). Valid only on root.
    /// P16.16 C6: the cached `gc_footprint` was removed — the tree is
    /// immutable after adoption, so the credit at last release simply
    /// recomputes `protoTreeFootprint + sourceBackingFootprint` (a cheap
    /// one-time tree walk at tree death, never hot).
    /// Pre-resolved constant values in runtime `Value` format. Populated
    /// tree-wide by constant resolution (`resolveProtoConstants`) before
    /// first execution. After resolution, opcode handlers read
    /// `resolved_values[kid]` directly — no per-execution switch on
    /// `Constant` tag. This mirrors PUC Lua, where `TValue k[]` in Proto
    /// is already in runtime format (lobject.h:614). Empty until the tree
    /// is adopted; freed by the tree deinit. Readiness lives on the OWNER
    /// (`constants_resolved`), not per-proto.
    resolved_values: []vm.Value = &.{},
    /// Inner prototypes (for OP_CLOSURE — child functions).
    p: []const *Proto,
    /// Upvalue descriptions (how to capture upvalues when creating a closure).
    upvalues: []const Upvaldesc,
    /// Source line for each instruction (one entry per instruction).
    lineinfo: []const u32,
    /// Local variable debug info (name, start PC, end PC).
    locvars: []const LocVar,
    /// P15.32: High-water mark of allocated registers at each instruction.
    /// The GC uses this to mark only live registers instead of the full
    /// maxstacksize window, eliminating the need for codegen-emitted LOADNIL
    /// at statement boundaries. Indexed by PC; one byte per instruction.
    live_reg_top: []const u8 = &.{},

    /// Maximum register count (frame capacity). 0–254 valid (255 = NO_REG).
    maxstacksize: u8,
    /// Number of fixed (named) parameters.
    numparams: u8,

    // --- Metadata (for error messages, debug info) ---
    // P16.16 C7: packed ptr+u32 representation (same trick as Upvaldesc C4):
    // two 16B slices → 24B. Empty string = null ptr + 0 len — the
    // stripped-chunk representation (PUC: NULL TString* pointer).
    name_ptr: ?[*]const u8 = null,
    name_len: u32 = 0,
    source_name_ptr: ?[*]const u8 = null,
    source_name_len: u32 = 0,
    line_defined: u32,
    last_line_defined: u32,

    // --- Lua 5.5 named varargs ---
    /// If != no_vararg_reg, this is the register index of the vararg table
    /// (for named varargs like `function f(x...)`). The VM creates the
    /// table at function entry and stores it in this register.
    /// P16.16 C7: ?u8 → u8 + sentinel (register indices are 0–254, so 255
    /// = NO_REG is unambiguous — same sentinel PUC uses for NO_REG).
    vararg_table_reg: u8 = no_vararg_reg,

    // NOTE: there is no `deinit` method. The tree deinit is STRUCTURAL and
    // lives in `destroyProtoTree` above, invoked either through
    // `releaseTree` (production: the last closure of the tree died) or
    // directly on construction error paths (no owner exists yet).

    /// Tree-wide state flags (P16.16 C6): the former standalone
    /// Proto bools packed into a single byte. Packed struct(u8) keeps
    /// plain `flags.<name>` bool read/write syntax at every call site.
    /// P16.16 C7: `flags.is_vararg` moved in from a standalone bool (5 bits).
    pub const Flags = packed struct(u8) {
        /// True once the k pool's `.str` pointers belong to the VM string
        /// table (undumped trees: from birth; text-compiled: flipped by
        /// resolution). Valid only on root.
        k_strings_vm_owned: bool = false,
        /// Readiness (tree-wide): all protos have resolved_values built and
        /// k pool is VM-canonical. Flipped once, never reset. Valid only on
        /// root.
        constants_resolved: bool = false,
        /// GC memory accounting (Task 7): false on construction, set true at
        /// adoption (first closure creation). Valid only on root.
        gc_charged: bool = false,
        /// PUC PF_FIXED parity (fixed-buffer undump): when true, `code` and
        /// `lineinfo` are BORROWED from the caller-owned input buffer.
        /// `destroyProtoTree` skips freeing them, and `protoTreeFootprint`
        /// excludes them from the GC memory charge. Only set by
        /// `UndumpReader.undumpProto` in fixed mode; text-compiled protos
        /// always own their arrays (flag = false).
        fixed_arrays: bool = false,
        /// Whether the function accepts varargs (PUC `flags.is_vararg`).
        is_vararg: bool = false,
        _pad: u3 = 0,
    };

    /// "No vararg table register" sentinel (P16.16 C7): register indices
    /// are 0–254 (255 = NO_REG, same value PUC uses), so this is
    /// unambiguous.
    pub const no_vararg_reg: u8 = 255;

    /// Function name for error messages / debug info (PUC: NULL for
    /// stripped chunks — represented as the empty string here).
    pub inline fn name(self: *const Proto) []const u8 {
        return if (self.name_ptr) |p| p[0..self.name_len] else &.{};
    }

    /// Chunk/source name (e.g. "@file.lua"); empty for stripped chunks.
    pub inline fn sourceName(self: *const Proto) []const u8 {
        return if (self.source_name_ptr) |p| p[0..self.source_name_len] else &.{};
    }

    /// Set the function name (empty → null ptr, the stripped form).
    pub fn setName(self: *Proto, s: []const u8) void {
        self.name_ptr = if (s.len == 0) null else s.ptr;
        self.name_len = @intCast(s.len);
    }

    /// Set the source name (empty → null ptr, the stripped form).
    pub fn setSourceName(self: *Proto, s: []const u8) void {
        self.source_name_ptr = if (s.len == 0) null else s.ptr;
        self.source_name_len = @intCast(s.len);
    }

    // --- CUT2 owner methods (valid only on root proto where tree == self) ---

    /// Add one reference (a Closure was created over this tree). Called on
    /// the root proto. Mirrors `ProtoTreeOwner.retain` from pre-CUT2.
    pub fn retainTree(self: *Proto) void {
        std.debug.assert(self.tree.? == self); // must be root
        self.ref_count += 1;
    }

    /// Drop one reference. The LAST release performs the full recursive
    /// tree deinit exactly once. `alloc` is the allocator the tree was
    /// compiled/undumped with (recovered from the VM in production paths,
    /// passed explicitly here — NOT stored in Proto to save 16B). Mirrors
    /// `ProtoTreeOwner.release` from pre-CUT2.
    pub fn releaseTree(self: *Proto, alloc: std.mem.Allocator) void {
        std.debug.assert(self.tree.? == self); // must be root
        std.debug.assert(self.ref_count > 0);
        self.ref_count -= 1;
        if (self.ref_count != 0) return;
        // Credit the tree's GC memory footprint (charged at adoption —
        // see flags.gc_charged). Only credit if the tree was actually
        // charged: error paths that release an un-adopted tree never set
        // gc_charged. P16.16 C6: the footprint is recomputed here instead
        // of cached in the Proto — the tree is immutable after adoption,
        // so this equals what was charged, and the walk runs once per
        // tree death (never hot).
        if (self.flags.gc_charged) {
            const vm_ptr: *vm.Vm = @ptrCast(@alignCast(self.vm.?));
            vm_ptr.gcCreditTreeMemory(protoTreeFootprint(self) +
                sourceBackingFootprint(self.source_backing));
        }
        // Structural deinit of the whole tree (arrays + structs + source
        // backing). Interned LuaStrings are NEVER destroyed here —
        // `k_strings_vm_owned` says whether the k pool still belongs to
        // the tree.
        destroyProtoTree(alloc, self, self.flags.k_strings_vm_owned);
    }
};

// ---------------------------------------------------------------------------
// ProtoBuilder — used by codegen to construct a Proto incrementally
// ---------------------------------------------------------------------------

pub const ProtoBuilder = struct {
    alloc: std.mem.Allocator,
    code: std.ArrayListUnmanaged(Instruction) = .empty,
    lineinfo: std.ArrayListUnmanaged(u32) = .empty,
    const_pool: ConstPool = .{},
    protos: std.ArrayListUnmanaged(*Proto) = .empty,
    upvalues: std.ArrayListUnmanaged(Upvaldesc) = .empty,
    locvars: std.ArrayListUnmanaged(LocVar) = .empty,
    /// Per-PC register boundary. Records the "before" high-water mark:
    /// the live top BEFORE the instruction at this PC writes its destination.
    /// GC uses this to scan only registers actually written by previous
    /// instructions, avoiding stale pointers from prior frames.
    /// (P15.36: changed from "after" to "before" semantics to eliminate
    /// the per-call @memset in pushBytecodeExecFrame.)
    live_reg_top: std.ArrayListUnmanaged(u8) = .empty,
    /// Current live register top (the "after" boundary for the instruction
    /// being emitted). Updated by reserveRegs/syncLiveTop.
    current_live_top: u8 = 0,
    /// P15.36: Snapshot of current_live_top captured BEFORE the first
    /// register allocation for the instruction being emitted. emit() records
    /// this value. The has_live_top_before flag prevents multiple reserveRegs
    /// calls within one instruction from overwriting the snapshot.
    live_top_before: u8 = 0,
    has_live_top_before: bool = false,

    maxstacksize: u8 = 2, // PUC starts at 2 (regs 0 and 1 always valid)
    numparams: u8 = 0,
    is_vararg: bool = false,
    vararg_table_reg: ?u8 = null,

    name: []const u8 = "=?",
    source_name: []const u8 = "=?",
    line_defined: u32 = 0,
    last_line_defined: u32 = 0,

    pub fn init(alloc: std.mem.Allocator) ProtoBuilder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *ProtoBuilder) void {
        self.code.deinit(self.alloc);
        self.lineinfo.deinit(self.alloc);
        self.const_pool.deinit(self.alloc);
        // Finished-but-unclaimed protos (compile failed after a child
        // finished but before this builder's own finish() adopted them)
        // still carry their own per-subtree owners with exactly the one
        // producing reference. Release each: the subtree frees itself and
        // its owner. After a successful finish() this list is empty
        // (toOwnedSlice). (P16.10b Task 4/C4 — was a partial-tree leak.)
        for (self.protos.items) |child| {
            child.tree.?.releaseTree(self.alloc);
        }
        self.upvalues.deinit(self.alloc);
        self.locvars.deinit(self.alloc);
        self.live_reg_top.deinit(self.alloc);
    }

    /// Current PC (index of the next instruction to emit).
    pub fn pc(self: *const ProtoBuilder) u32 {
        return @intCast(self.code.items.len);
    }

    /// Emit an instruction at the current PC, recording the source line.
    /// P15.36: Records live_top_before (the "before" boundary) rather than
    /// current_live_top (the "after" boundary). This ensures GC safepoints
    /// only scan registers written by PREVIOUS instructions.
    pub fn emit(self: *ProtoBuilder, inst: Instruction, line: u32) !u32 {
        const result_pc: u32 = @intCast(self.code.items.len);
        try self.code.append(self.alloc, inst);
        try self.lineinfo.append(self.alloc, line);
        // P15.38: Record the "after" boundary (current_live_top). This
        // includes the destination register of the instruction being emitted.
        // The "before" boundary (P15.36) caused GC to clear the destination
        // register of allocation instructions (OP_CLOSURE, OP_CONCAT) when GC
        // ran during the allocation (via gcNoteAlloc) but before the result
        // was stored. The "after" boundary correctly preserves the destination.
        // Stale objects in result registers of OP_CALL may be leaked (not
        // cleared), but this is a minor leak, not a crash.
        try self.live_reg_top.append(self.alloc, self.current_live_top);
        // Reset for the next instruction: default live_top_before to the
        // current "after" boundary (covers instructions with no allocations).
        self.has_live_top_before = false;
        self.live_top_before = self.current_live_top;
        return result_pc;
    }

    /// Emit a simple instruction (operands zeroed).
    pub fn emitSimple(self: *ProtoBuilder, op: Op, line: u32) !u32 {
        return self.emit(Instruction.simple(op), line);
    }

    /// Emit a three-operand instruction.
    pub fn emitABC(self: *ProtoBuilder, op: Op, a: u8, b: u8, c: u8, line: u32) !u32 {
        return self.emit(Instruction.make(op, a, b, c), line);
    }

    /// Emit a three-operand instruction with an explicit k flag.
    /// Used by arithmetic/bitwise K/I-variant opcodes to carry the
    /// commutative-swap flip flag (PUC GETARG_k).
    pub fn emitABCk(self: *ProtoBuilder, op: Op, a: u8, b: u8, c: u8, k: bool, line: u32) !u32 {
        return self.emit(Instruction.makeK(op, a, b, c, k), line);
    }

    /// Emit a jump instruction with offset 0 (to be patched later).
    /// Returns the PC of the jump for later patching.
    pub fn emitJump(self: *ProtoBuilder, op: Op, line: u32) !u32 {
        return self.emit(Instruction.jump(op, 0), line);
    }

    /// Patch a jump instruction at `jump_pc` to target `target_pc`.
    /// The offset is relative: target_pc - jump_pc - 1 (skip the JMP itself).
    pub fn patchJump(self: *ProtoBuilder, jump_pc: u32, target_pc: u32) void {
        const offset: i32 = @as(i32, @intCast(target_pc)) - @as(i32, @intCast(jump_pc)) - 1;
        const old_op: Op = @enumFromInt(self.code.items[jump_pc].op);
        self.code.items[jump_pc] = Instruction.jump(old_op, offset);
    }

    /// Patch a jump to skip N instructions (forward jump by N).
    pub fn patchJumpOffset(self: *ProtoBuilder, jump_pc: u32, offset: i32) void {
        const old_op: Op = @enumFromInt(self.code.items[jump_pc].op);
        self.code.items[jump_pc] = Instruction.jump(old_op, offset);
    }

    /// Get the target PC of the jump instruction at `jump_pc`.
    /// Returns null if the offset is 0 — our "end of list" sentinel
    /// (PUC uses NO_JUMP = -1; we use 0 because a JMP with offset 0
    /// jumps to the next instruction, which is never a useful jump-list
    /// target, so 0 safely marks an uninitialized/end-of-list slot).
    /// Mirrors PUC `getjump` (lcode.c:155-161).
    pub fn getJumpTarget(self: *const ProtoBuilder, jump_pc: u32) ?u32 {
        const offset = self.code.items[jump_pc].jumpOffset();
        if (offset == 0) return null; // end of list
        return @intCast(@as(i32, @intCast(jump_pc)) + 1 + offset);
    }

    /// Update maxstacksize to ensure at least `n` registers are available.
    /// PUC `luaK_checkstack` (lcode.c): `newstack = freereg + n;
    /// if (newstack > maxstacksize) maxstacksize = newstack`. Callers pass
    /// the register count they need (including the one about to be
    /// allocated), so `n` IS the PUC `newstack` — no extra margin. (A
    /// former `+1 for safety margin` here inflated every proto's register
    /// file by one slot, which became observable through the hook-yield
    /// resume window of P15.83q: PUC exposes exactly
    /// `ci->func + 1 .. ci->func + 1 + maxstacksize` live registers.)
    pub fn checkStack(self: *ProtoBuilder, n: u8) void {
        if (n > self.maxstacksize) {
            self.maxstacksize = @min(n, 255);
        }
    }

    /// Intern a constant and return its index in the pool.
    pub fn internConst(self: *ProtoBuilder, c: Constant) !u32 {
        return self.const_pool.intern(self.alloc, c);
    }

    /// Intern a string constant from raw bytes.
    pub fn internString(self: *ProtoBuilder, s: []const u8) !u32 {
        return self.const_pool.internString(self.alloc, s);
    }

    /// Add an inner proto (child function). Returns its index for OP_CLOSURE.
    /// The child must be a freshly finished proto tree still holding its
    /// producing reference (ref_count == 1); this builder takes over that
    /// reference. On append failure the child is released so the finished
    /// subtree cannot leak (P16.10b Task 4 error-path hygiene).
    pub fn addProto(self: *ProtoBuilder, child: *Proto) !u8 {
        const idx: u8 = @intCast(self.protos.items.len);
        self.protos.append(self.alloc, child) catch |e| {
            child.tree.?.releaseTree(self.alloc);
            return e;
        };
        return idx;
    }

    /// Add an upvalue description. Returns its index.
    pub fn addUpvalue(self: *ProtoBuilder, desc: Upvaldesc) !u8 {
        const idx: u8 = @intCast(self.upvalues.items.len);
        try self.upvalues.append(self.alloc, desc);
        return idx;
    }

    /// Add a local variable debug info entry.
    pub fn addLocVar(self: *ProtoBuilder, name: []const u8, reg: u8, startpc: u32) !usize {
        const index = self.locvars.items.len;
        try self.locvars.append(self.alloc, .{
            .name = name,
            .reg = reg,
            .startpc = startpc,
            .endpc = 0,
        });
        return index;
    }

    /// Close one exact local-variable debug range.  Scopes may contain several
    /// locals, so "close the last entry" is insufficient when all of them leave
    /// at the same lexical boundary.
    pub fn closeLocVar(self: *ProtoBuilder, index: usize, endpc: u32) void {
        std.debug.assert(index < self.locvars.items.len);
        self.locvars.items[index].endpc = endpc;
    }

    /// Finalize: transfer all data into a heap-allocated Proto, create the
    /// per-tree `ProtoTreeOwner`, and bind the whole tree (this proto plus
    /// every adopted descendant) to it. The returned root's owner carries
    /// ref_count = 1 — the PRODUCER's reference, owned by whoever receives
    /// the proto; closure creation retains, failure paths release.
    /// The ProtoBuilder is consumed and should be deinit'd after.
    pub fn finish(self: *ProtoBuilder) !*Proto {
        const alloc = self.alloc;
        const proto = try alloc.create(Proto);
        errdefer alloc.destroy(proto);
        const code_slice = try self.code.toOwnedSlice(alloc);
        errdefer alloc.free(code_slice);
        const k_slice = try self.const_pool.items.toOwnedSlice(alloc);
        errdefer {
            // The pool is still tree-owned here (nothing resolves constants
            // before a tree exists): destroy the seed-0 strings with it.
            for (k_slice) |c| {
                if (c == .str) vm.destroyLuaString(alloc, c.str);
            }
            alloc.free(k_slice);
        }
        const p_slice = try self.protos.toOwnedSlice(alloc);
        errdefer {
            // Adopted children still carry their own per-subtree ownership
            // (rebinding happens only after the new root is bound below).
            for (p_slice) |child| child.tree.?.releaseTree(alloc);
            alloc.free(p_slice);
        }
        const upv_slice = try self.upvalues.toOwnedSlice(alloc);
        errdefer alloc.free(upv_slice);
        const li_slice = try self.lineinfo.toOwnedSlice(alloc);
        errdefer alloc.free(li_slice);
        const lv_slice = try self.locvars.toOwnedSlice(alloc);
        errdefer alloc.free(lv_slice);
        const lrt_slice = try self.live_reg_top.toOwnedSlice(alloc);
        errdefer if (lrt_slice.len > 0) alloc.free(lrt_slice);
        proto.* = .{
            .code = code_slice,
            .k = k_slice,
            .p = p_slice,
            .upvalues = upv_slice,
            .lineinfo = li_slice,
            .locvars = lv_slice,
            .live_reg_top = lrt_slice,
            .maxstacksize = self.maxstacksize,
            .numparams = self.numparams,
            .flags = .{ .is_vararg = self.is_vararg },
            .vararg_table_reg = self.vararg_table_reg orelse Proto.no_vararg_reg,
            .line_defined = self.line_defined,
            .last_line_defined = self.last_line_defined,
        };
        // Packed name fields (P16.16 C7): set via accessors — the builder
        // keeps plain slices, the runtime Proto stores ptr+u32 len.
        proto.setName(self.name);
        proto.setSourceName(self.source_name);
        // ── Tree binding (CUT2: owner merged into root Proto) ──
        // Every adopted child was finished by its own builder and therefore
        // IS its own root (tree == self, ref_count == 1, its producing
        // reference). Detach those child roots — clear their owner fields
        // and null their tree pointers — then bind every proto in the tree
        // to THIS proto as the new root. No separate owner allocation.
        proto.ref_count = 1; // producing reference
        proto.flags.k_strings_vm_owned = false; // text-compiled: born owning seed-0 strings
        for (p_slice) |child| detachOwnerGroup(alloc, child);
        bindTreeRecursive(proto, proto); // root.tree = self, children.tree = root
        // Transfer ownership of the const pool's internal maps to nothing —
        // they were temporary dedup indices. The actual constants are now in
        // proto.k. We need to clear the maps without freeing the strings
        // (strings are owned by proto.k now).
        self.const_pool.items = .empty;
        self.code = .empty;
        self.lineinfo = .empty;
        self.protos = .empty;
        self.upvalues = .empty;
        self.locvars = .empty;
        // Clear the const pool's internal maps without freeing the constants
        // (they're now owned by proto.k). The maps themselves need deinit.
        self.const_pool.str_index.deinit(alloc);
        self.const_pool.int_index.deinit(alloc);
        self.const_pool.num_index.deinit(alloc);
        self.const_pool.items = .empty;
        self.const_pool.str_index = .{};
        self.const_pool.int_index = .{};
        self.const_pool.num_index = .{};
        self.const_pool.nil_id = null;
        self.const_pool.bool_ids = .{ null, null };
        return proto;
    }
};

/// Detach a finished subtree's own root status at adoption time (called from
/// `ProtoBuilder.finish` for every adopted child). In CUT2, the child IS its
/// own root (tree == self, ref_count == 1 — no closures can exist for an
/// un-adopted subtree). Clear the child's owner fields and null the subtree's
/// `tree` pointers so the subsequent `bindTreeRecursive` rebinds them to the
/// parent's new root. The child proto struct itself stays alive (it becomes
/// a non-root member of the parent's tree).
fn detachOwnerGroup(alloc: std.mem.Allocator, group_root: *Proto) void {
    std.debug.assert(group_root.tree.? == group_root); // was its own root
    std.debug.assert(group_root.ref_count == 1); // only the producer's reference
    // Deinit any source_backing the child accumulated (normally empty for
    // freshly compiled children, but safe to call).
    group_root.source_backing.deinit(alloc);
    // Clear owner fields (no longer a root).
    group_root.ref_count = 0;
    group_root.vm = null;
    group_root.flags.k_strings_vm_owned = false;
    group_root.flags.constants_resolved = false;
    group_root.flags.gc_charged = false;
    clearTreePtrs(group_root);
}

/// Null every `.tree` pointer in a subtree (used while detaching a tree
/// group; the pointers are immediately rebound by bindTreeRecursive).
fn clearTreePtrs(proto: *Proto) void {
    proto.tree = null;
    for (proto.p) |child| clearTreePtrs(child);
}

/// Point every proto of a subtree at `root` (post-detach rebinding).
/// Also used by `undump.undumpChunk` to bind a freshly deserialized tree.
/// CUT2: `root` is the root Proto itself (owner merged in). The root's
/// `.tree` is set to `self` (self-pointer); children point to root.
pub fn bindTreeRecursive(proto: *Proto, root: *Proto) void {
    proto.tree = root;
    for (proto.p) |child| bindTreeRecursive(child, root);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "instruction: make and decode" {
    const inst = Instruction.make(.add, 1, 2, 3);
    try std.testing.expectEqual(Op.add, @as(Op, @enumFromInt(inst.op)));
    try std.testing.expectEqual(@as(u8, 1), inst.a);
    try std.testing.expectEqual(@as(u1, 0), inst.k);
    try std.testing.expectEqual(@as(u8, 2), inst.b);
    try std.testing.expectEqual(@as(u8, 3), inst.c);
}

test "instruction: makeK with k flag" {
    const inst = Instruction.makeK(.addk, 1, 2, 3, true);
    try std.testing.expectEqual(Op.addk, @as(Op, @enumFromInt(inst.op)));
    try std.testing.expectEqual(@as(u1, 1), inst.k);
    const inst2 = Instruction.makeK(.addk, 1, 2, 3, false);
    try std.testing.expectEqual(@as(u1, 0), inst2.k);
}

test "instruction: jump offset round-trip" {
    const offsets = [_]i32{ 0, 1, -1, 127, -128, 8388607, -8388608 };
    for (offsets) |off| {
        const inst = Instruction.jump(.jmp, off);
        try std.testing.expectEqual(off, inst.jumpOffset());
    }
}

test "instruction: extra arg round-trip" {
    const vals = [_]u32{ 0, 1, 255, 256, 65535, 65536, 16777215 };
    for (vals) |v| {
        const inst = Instruction.extra(v);
        try std.testing.expectEqual(v, inst.extraArg());
    }
}

test "const pool: deduplication" {
    var pool: ConstPool = .{};
    defer pool.deinit(std.testing.allocator);

    const id_nil_1 = try pool.intern(std.testing.allocator, .nil);
    const id_nil_2 = try pool.intern(std.testing.allocator, .nil);
    try std.testing.expectEqual(id_nil_1, id_nil_2);

    const id_int_1 = try pool.intern(std.testing.allocator, .{ .int = 42 });
    const id_int_2 = try pool.intern(std.testing.allocator, .{ .int = 42 });
    try std.testing.expectEqual(id_int_1, id_int_2);

    const id_str_1 = try pool.internString(std.testing.allocator, "hello");
    const id_str_2 = try pool.internString(std.testing.allocator, "hello");
    try std.testing.expectEqual(id_str_1, id_str_2);
}

test "proto builder: emit and finish" {
    var builder = ProtoBuilder.init(std.testing.allocator);
    defer builder.deinit();

    _ = try builder.emitABC(.loadk, 0, 0, 0, 1); // R0 = K0
    _ = try builder.emitABC(.loadk, 1, 1, 0, 1); // R1 = K1
    _ = try builder.emitABC(.add, 2, 0, 1, 2); // R2 = R0 + R1
    _ = try builder.emitABC(.return1, 2, 0, 0, 3); // return R2

    _ = try builder.internConst(.{ .int = 10 });
    _ = try builder.internConst(.{ .int = 20 });
    builder.checkStack(3);

    const proto = try builder.finish();
    defer proto.tree.?.releaseTree(std.testing.allocator); // frees the whole tree + owner

    try std.testing.expectEqual(@as(usize, 4), proto.code.len);
    try std.testing.expectEqual(@as(usize, 2), proto.k.len);
    try std.testing.expectEqual(@as(u8, 3), proto.maxstacksize);
    try std.testing.expectEqual(Op.add, @as(Op, @enumFromInt(proto.code[2].op)));
}

test "proto builder: jump backpatching" {
    var builder = ProtoBuilder.init(std.testing.allocator);
    defer builder.deinit();

    // Emit: jmp ?; loadk R0 K0; <target>
    const jmp_pc = try builder.emitJump(.jmp, 1);
    _ = try builder.emitABC(.loadk, 0, 0, 0, 1);
    const target_pc = builder.pc();

    // Patch the jump to target.
    builder.patchJump(jmp_pc, target_pc);

    const proto = try builder.finish();
    defer proto.tree.?.releaseTree(std.testing.allocator);

    // The jump should skip 1 instruction (the LOADK).
    const offset = proto.code[jmp_pc].jumpOffset();
    try std.testing.expectEqual(@as(i32, 1), offset);
}

// ---------------------------------------------------------------------------
// Bytecode dump — text disassembly (like `luac -l`)
// ---------------------------------------------------------------------------

/// Return the mnemonic name for an opcode (uppercase, PUC-style).
pub fn opName(op: Op) []const u8 {
    return switch (op) {
        .move => "MOVE",
        .loadk => "LOADK",
        .loadkx => "LOADKX",
        .loadi => "LOADI",
        .loadf => "LOADF",
        .loadnil => "LOADNIL",
        .loadtrue => "LOADTRUE",
        .loadfalse => "LOADFALSE",
        .gettabup => "GETTABUP",
        .settabup => "SETTABUP",
        .getupval => "GETUPVAL",
        .setupval => "SETUPVAL",
        .gettable => "GETTABLE",
        .geti => "GETI",
        .getfield => "GETFIELD",
        .getvarg => "GETVARG",
        .settable => "SETTABLE",
        .seti => "SETI",
        .setfield => "SETFIELD",
        .newtable => "NEWTABLE",
        .self => "SELF",
        .add => "ADD",
        .sub => "SUB",
        .mul => "MUL",
        .div => "DIV",
        .mod => "MOD",
        .pow => "POW",
        .idiv => "IDIV",
        .addi => "ADDI",
        .addk => "ADDK",
        .subk => "SUBK",
        .mulk => "MULK",
        .modk => "MODK",
        .powk => "POWK",
        .divk => "DIVK",
        .idivk => "IDIVK",
        .band => "BAND",
        .bor => "BOR",
        .bxor => "BXOR",
        .shl => "SHL",
        .shr => "SHR",
        .mmbin => "MMBIN",
        .mmbini => "MMBINI",
        .mmbink => "MMBINK",
        .lfalseskip => "LFALSESKIP",
        .bandk => "BANDK",
        .bork => "BORK",
        .bxork => "BXORK",
        .shli => "SHLI",
        .shri => "SHRI",
        .unm => "UNM",
        .bnot => "BNOT",
        .not => "NOT",
        .len => "LEN",
        .concat => "CONCAT",
        .eq => "EQ",
        .lt => "LT",
        .le => "LE",
        .eqi => "EQI",
        .lti => "LTI",
        .lei => "LEI",
        .gti => "GTI",
        .gei => "GEI",
        .eqk => "EQK",
        .test_ => "TEST",
        .testset => "TESTSET",
        .jmp => "JMP",
        .call => "CALL",
        .tailcall => "TAILCALL",
        .return_ => "RETURN",
        .return0 => "RETURN0",
        .return1 => "RETURN1",
        .forprep => "FORPREP",
        .forloop => "FORLOOP",
        .tforprep => "TFORPREP",
        .tforcall => "TFORCALL",
        .tforloop => "TFORLOOP",
        .setlist => "SETLIST",
        .closure => "CLOSURE",
        .close => "CLOSE",
        .tbc => "TBC",
        .vararg => "VARARG",
        .varargprep => "VARARGPREP",
        .errdefined => "ERRDEFINED",
        .errnnil => "ERRNNIL",
        .extraarg => "EXTRAARG",
    };
}

/// Format a constant value for display in the dump.
fn formatConst(buf: []u8, c: Constant) []const u8 {
    return switch (c) {
        .nil => "nil",
        .bool => |b| if (b) "true" else "false",
        .int => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch "?",
        .num_bits => |n| blk: {
            const f: f64 = @bitCast(n);
            break :blk std.fmt.bufPrint(buf, "{d}", .{f}) catch "?";
        },
        .str => |s| std.fmt.bufPrint(buf, "\"{s}\"", .{s.bytes()}) catch "?",
    };
}

/// Dump a single Proto (function) to a writer, PUC `luac -l` style.
/// Recursively dumps inner protos.
pub fn dumpProto(w: anytype, proto: *const Proto, depth: u32) !void {
    const indent = "  " ** 4;
    // Header line: function name, source, line range, instruction count.
    if (depth == 0) {
        try w.print("main <{s}:{d},{d}> ({d} instructions)\n", .{
            proto.sourceName(),
            proto.line_defined,
            proto.last_line_defined,
            proto.code.len,
        });
    } else {
        try w.print("function <{s}:{d},{d}> ({d} instructions)\n", .{
            proto.sourceName(),
            proto.line_defined,
            proto.last_line_defined,
            proto.code.len,
        });
    }

    // Summary line: params, slots, upvalues, locals, constants, functions.
    const k_count_summary = protoConstCount(proto);
    try w.print("{s}{d}{s} params, {d} slots, {d} upvalue{s}, {d} local{s}, {d} constant{s}, {d} function{s}\n", .{
        indent,
        proto.numparams,
        if (proto.flags.is_vararg) "+" else "",
        proto.maxstacksize,
        proto.upvalues.len,
        if (proto.upvalues.len != 1) "s" else "",
        proto.locvars.len,
        if (proto.locvars.len != 1) "s" else "",
        k_count_summary,
        if (k_count_summary != 1) "s" else "",
        proto.p.len,
        if (proto.p.len != 1) "s" else "",
    });

    // Instruction listing.
    var pc: usize = 0;
    while (pc < proto.code.len) : (pc += 1) {
        const inst = proto.code[pc];
        const op: Op = @enumFromInt(inst.op);
        const line: u32 = if (pc < proto.lineinfo.len) proto.lineinfo[pc] else 0;

        try w.print("{s}\t{d}\t[{d}]\t{s}", .{ indent, pc + 1, line, opName(op) });

        // Operand formatting depends on opcode category.
        switch (op) {
            // JMP: 24-bit signed offset in a:b:c.
            .jmp => {
                const off = inst.jumpOffset();
                const target: i64 = @as(i64, @intCast(pc + 1)) + off;
                try w.print("\t; to {d}", .{target});
            },

            // FORPREP/FORLOOP/TFORPREP/TFORLOOP: A=base register, B:C=signed 16-bit offset.
            .forprep, .forloop, .tforprep, .tforloop => {
                const off_bits: u16 = @as(u16, inst.b) | (@as(u16, inst.c) << 8);
                const off: i16 = @bitCast(off_bits);
                const target: i64 = @as(i64, @intCast(pc + 1)) + @as(i64, off);
                try w.print("\t{d}\t; to {d}", .{ inst.a, target });
            },

            // EXTRAARG: just show the value.
            .extraarg => {
                try w.print("\t{d}", .{inst.extraArg()});
            },

            // LOADI/LOADF: 17-bit signed sBx in k:b:c (range ±65535).
            .loadi, .loadf => {
                const bits: u17 = @as(u17, inst.b) | (@as(u17, inst.c) << 8) | (@as(u17, inst.k) << 16);
                const signed: i32 = @as(i32, @intCast(bits)) - 65535;
                try w.print("\t{d}\t{d}", .{ inst.a, signed });
            },

            // LOADNIL: A..A+B.
            .loadnil => {
                try w.print("\t{d}\t{d}", .{ inst.a, inst.b });
            },

            // ADDI/SHLI/SHRI: signed 8-bit immediate (sC) in C.
            .addi, .shli, .shri => {
                const sc: i64 = @as(i64, inst.c) - 127;
                try w.print("\t{d}\t{d}\t{d}", .{ inst.a, inst.b, sc });
            },

            // K-variant arithmetic: show constant value.
            .addk, .subk, .mulk, .modk, .powk, .divk, .idivk,
            .bandk, .bork, .bxork => {
                var buf: [64]u8 = undefined;
                const kstr = formatConst(&buf, protoConstAt(proto, inst.c) orelse .nil);
                try w.print("\t{d}\t{d}\t{d}\t; {s}", .{ inst.a, inst.b, inst.c, kstr });
            },

            // LOADK: show constant value.
            .loadk => {
                var buf: [64]u8 = undefined;
                const kstr = formatConst(&buf, protoConstAt(proto, inst.b) orelse .nil);
                try w.print("\t{d}\t{d}\t; {s}", .{ inst.a, inst.b, kstr });
            },

            // GETFIELD/SETFIELD/SELF/GETTABUP/SETTABUP: show string key.
            .getfield, .self => {
                var buf: [64]u8 = undefined;
                const kstr = formatConst(&buf, protoConstAt(proto, inst.c) orelse .nil);
                try w.print("\t{d}\t{d}\t{d}\t; {s}", .{ inst.a, inst.b, inst.c, kstr });
            },
            .setfield => {
                var buf: [64]u8 = undefined;
                const kstr = formatConst(&buf, protoConstAt(proto, inst.b) orelse .nil);
                try w.print("\t{d}\t{d}\t{d}\t; {s}", .{ inst.a, inst.b, inst.c, kstr });
            },
            .gettabup => {
                var buf: [64]u8 = undefined;
                const kstr = formatConst(&buf, protoConstAt(proto, inst.c) orelse .nil);
                try w.print("\t{d}\t{d}\t{d}\t; {s}", .{ inst.a, inst.b, inst.c, kstr });
            },
            .settabup => {
                var buf: [64]u8 = undefined;
                const kstr = formatConst(&buf, protoConstAt(proto, inst.b) orelse .nil);
                try w.print("\t{d}\t{d}\t{d}\t; {s}", .{ inst.a, inst.b, inst.c, kstr });
            },

            // CALL/TAILCALL: show B (nargs+1) and C (nresults+1).
            .call, .tailcall => {
                try w.print("\t{d}\t{d}\t{d}", .{ inst.a, inst.b, inst.c });
                if (inst.c == 0) {
                    try w.writeAll("\t; multret");
                } else if (inst.c == 1) {
                    try w.writeAll("\t; 0 out");
                } else {
                    try w.print("\t; {d} out", .{inst.c - 1});
                }
            },

            // RETURN: B (count+1).
            .return_ => {
                try w.print("\t{d}\t{d}\t{d}", .{ inst.a, inst.b, inst.c });
                if (inst.b == 0) {
                    try w.writeAll("\t; multret");
                } else {
                    try w.print("\t; {d} out", .{inst.b - 1});
                }
            },

            // SETLIST: B (count), C (base index).
            .setlist => {
                try w.print("\t{d}\t{d}\t{d}", .{ inst.a, inst.b, inst.c });
                if (inst.c == 0) {
                    try w.writeAll("\t; EXTRAARG follows");
                }
            },

            // CLOSURE: proto index.
            .closure => {
                try w.print("\t{d}\t{d}", .{ inst.a, inst.b });
            },

            // Default: A B C.
            else => {
                // For most ABC instructions, print all three operands.
                if (inst.b != 0 or inst.c != 0) {
                    try w.print("\t{d}\t{d}\t{d}", .{ inst.a, inst.b, inst.c });
                } else if (inst.a != 0 or op == .return0 or op == .varargprep) {
                    try w.print("\t{d}", .{inst.a});
                }
            },
        }

        try w.writeAll("\n");

        // If LOADKX, the next instruction is EXTRAARG — skip it in the listing.
        if (op == .loadkx) {
            pc += 1;
            if (pc < proto.code.len) {
                const extra = proto.code[pc];
                const extra_line: u32 = if (pc < proto.lineinfo.len) proto.lineinfo[pc] else 0;
                try w.print("{s}\t{d}\t[{d}]\t{s}\t{d}\n", .{
                    indent, pc + 1, extra_line, opName(.extraarg), extra.extraArg(),
                });
            }
        }
    }

    // Constants table.
    const k_count = protoConstCount(proto);
    if (k_count > 0) {
        try w.print("constants ({d}) for {s}:\n", .{ k_count, proto.sourceName() });
        var idx: usize = 0;
        while (idx < k_count) : (idx += 1) {
            var buf: [64]u8 = undefined;
            const kstr = formatConst(&buf, protoConstAt(proto, idx) orelse .nil);
            try w.print("{s}\t{d}\t{s}\n", .{ indent, idx, kstr });
        }
    }

    // Locals table.
    if (proto.locvars.len > 0) {
        try w.print("locals ({d}) for {s}:\n", .{ proto.locvars.len, proto.sourceName() });
        for (proto.locvars) |lv| {
            try w.print("{s}\t{d}\t{s}\t{d}\t{d}\n", .{ indent, lv.reg, lv.name, lv.startpc, lv.endpc });
        }
    }

    // Upvalues table.
    if (proto.upvalues.len > 0) {
        try w.print("upvalues ({d}) for {s}:\n", .{ proto.upvalues.len, proto.sourceName() });
        for (proto.upvalues, 0..) |uv, idx| {
            try w.print("{s}\t{d}\t{s}\t{s}\t{d}\n", .{
                indent, idx, uv.name(),
                if (uv.instack) "register" else "upvalue",
                uv.idx,
            });
        }
    }

    // Recursively dump inner protos.
    for (proto.p) |child| {
        try w.writeAll("\n");
        try dumpProto(w, child, depth + 1);
    }
}
