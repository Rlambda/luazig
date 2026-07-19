// Bytecode definition for the PUC-style bytecode VM.
//
// This module defines the instruction format, opcode set, Proto (the
// compiled function object), constant pool, and upvalue descriptions.
// It mirrors PUC Lua 5.5's architecture: 32-bit instructions, a stack-pointer
// register allocator (freereg), and the OT/IT multi-value convention.
//
// The codegen walks the AST and emits these instructions directly; the bc_vm
// executes them. There is no IR intermediate — bytecode IS the compilation
// target, exactly as in PUC Lua.

const std = @import("std");
const vm = @import("vm.zig");

// ---------------------------------------------------------------------------
// Instruction format — 32-bit packed struct (like PUC Lua)
// ---------------------------------------------------------------------------
//
// Fields are opcode-specific but the layout is fixed: every instruction is
// 4 bytes. For jump offsets, the three operand fields (a, b, c) are combined
// into a 24-bit signed offset. For constants whose index exceeds 255, a
// following EXTRAARG instruction provides a 24-bit extension.
//
// Registers are u8 (0–255), matching PUC Lua's MAX_FSTACK = 255.

pub const Instruction = packed struct(u32) {
    op: u8, // opcode (256 max)
    a: u8, // register A, or low byte of jump offset
    b: u8, // register B, constant index, or mid byte of jump offset
    c: u8, // register C, count, or high byte of jump offset

    /// Create an instruction with three register/count operands.
    pub fn make(op: Op, a: u8, b: u8, c: u8) Instruction {
        return .{ .op = @intFromEnum(op), .a = a, .b = b, .c = c };
    }

    /// Create a simple instruction (op only, operands zeroed).
    pub fn simple(op: Op) Instruction {
        return .{ .op = @intFromEnum(op), .a = 0, .b = 0, .c = 0 };
    }

    /// Create a jump instruction with a signed 24-bit offset.
    pub fn jump(op: Op, offset: i32) Instruction {
        const u: u32 = @bitCast(offset);
        return .{
            .op = @intFromEnum(op),
            .a = @truncate(u),
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
            .b = @truncate(val >> 8),
            .c = @truncate(val >> 16),
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

pub const Op = enum(u8) {
    // --- Moves / loads ---
    move, // R[A] = R[B]
    loadk, // R[A] = K[B]            (B ≤ 255)
    loadkx, // R[A] = K[EXTRAARG]    (followed by EXTRAARG)
    loadi, // R[A] = (i64)(sBx)      (B=low, C=high, signed 16-bit)
    loadf, // R[A] = (f64)(sBx)      (B=low, C=high, signed 16-bit)
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
    /// Human-readable name for debug info.
    name: []const u8,
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
// Proto — the compiled function object (replaces ir.Function)
// ---------------------------------------------------------------------------

pub const Proto = struct {
    /// Bytecode instructions.
    code: []const Instruction,
    /// Deduplicated constant pool. Mutable so the VM can resolve string
    /// constants in-place: at first execution, compile-time `*LuaString`
    /// objects (hashed with seed 0) are replaced by VM-interned pointers
    /// (hashed with the VM's per-instance seed). After resolution,
    /// `bcConstToValue` returns string constants directly — no re-hashing
    /// on every GETTABUP/GETFIELD/SETFIELD execution. This mirrors PUC Lua,
    /// where the compiler interns strings through the same string table as
    /// the runtime, so constant pool strings are already interned.
    k: []Constant,
    /// True after the VM has resolved all `.str` constants to VM-interned
    /// pointers. When true, string constants are owned by the VM's intern
    /// table (not by this Proto) and must NOT be freed in `deinit`.
    constants_resolved: bool = false,
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

    /// Maximum register count (frame capacity). ≤ 255.
    maxstacksize: u8,
    /// Number of fixed (named) parameters.
    numparams: u8,
    /// Whether the function accepts varargs.
    is_vararg: bool,

    // --- Metadata (for error messages, debug info) ---
    name: []const u8,
    source_name: []const u8,
    line_defined: u32,
    last_line_defined: u32,

    // --- Lua 5.5 named varargs ---
    /// If non-null, this is the register index of the vararg table
    /// (for named varargs like `function f(x...)`). The VM creates the
    /// table at function entry and stores it in this register.
    vararg_table_reg: ?u8 = null,

    /// Deinitialize all owned data. Call once when the Proto is no longer
    /// referenced. Inner protos (in `p`) are recursively deinitialized.
    pub fn deinit(self: *Proto, alloc: std.mem.Allocator) void {
        alloc.free(self.code);
        // Constant pool: free owned strings — but only if they haven't been
        // resolved to VM-interned pointers. After resolution, string
        // constants are owned by the VM's string intern table, not by this
        // Proto (matching PUC Lua's ownership model where TString objects
        // belong to the global string table, not to the Proto).
        if (!self.constants_resolved) {
            for (self.k) |c| {
                if (c == .str) vm.destroyLuaString(alloc, c.str);
            }
        }
        alloc.free(self.k);
        // Recursively deinitialize inner protos.
        for (self.p) |child| {
            child.deinit(alloc);
            alloc.destroy(child);
        }
        alloc.free(self.p);
        alloc.free(self.upvalues);
        alloc.free(self.lineinfo);
        alloc.free(self.locvars);
        if (self.live_reg_top.len > 0) alloc.free(self.live_reg_top);
        // name/source_name/locvar names are borrowed from the source arena;
        // they are NOT freed here.
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
        // Inner protos are owned by the final Proto; if finish() was not
        // called, they leak. Callers should always finish().
        self.upvalues.deinit(self.alloc);
        self.locvars.deinit(self.alloc);
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
        // P15.36: Record the "before" boundary — registers written by PREVIOUS
        // instructions only. This ensures GC safepoints don't scan registers
        // that will be written by this instruction but haven't been yet.
        try self.live_reg_top.append(self.alloc, self.live_top_before);
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
    pub fn checkStack(self: *ProtoBuilder, n: u8) void {
        const needed = @as(u16, n) + 1; // +1 for safety margin
        if (needed > self.maxstacksize) {
            self.maxstacksize = @intCast(@min(needed, 255));
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
    pub fn addProto(self: *ProtoBuilder, child: *Proto) !u8 {
        const idx: u8 = @intCast(self.protos.items.len);
        try self.protos.append(self.alloc, child);
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

    /// Finalize: transfer all data into a heap-allocated Proto.
    /// The ProtoBuilder is consumed and should be deinit'd after.
    pub fn finish(self: *ProtoBuilder) !*Proto {
        const alloc = self.alloc;
        const proto = try alloc.create(Proto);
        proto.* = .{
            .code = try self.code.toOwnedSlice(alloc),
            .k = try self.const_pool.items.toOwnedSlice(alloc),
            .p = try self.protos.toOwnedSlice(alloc),
            .upvalues = try self.upvalues.toOwnedSlice(alloc),
            .lineinfo = try self.lineinfo.toOwnedSlice(alloc),
            .locvars = try self.locvars.toOwnedSlice(alloc),
            .live_reg_top = try self.live_reg_top.toOwnedSlice(alloc),
            .maxstacksize = self.maxstacksize,
            .numparams = self.numparams,
            .is_vararg = self.is_vararg,
            .vararg_table_reg = self.vararg_table_reg,
            .name = self.name,
            .source_name = self.source_name,
            .line_defined = self.line_defined,
            .last_line_defined = self.last_line_defined,
        };
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "instruction: make and decode" {
    const inst = Instruction.make(.add, 1, 2, 3);
    try std.testing.expectEqual(Op.add, @as(Op, @enumFromInt(inst.op)));
    try std.testing.expectEqual(@as(u8, 1), inst.a);
    try std.testing.expectEqual(@as(u8, 2), inst.b);
    try std.testing.expectEqual(@as(u8, 3), inst.c);
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
    defer {
        proto.deinit(std.testing.allocator);
        std.testing.allocator.destroy(proto);
    }

    try std.testing.expectEqual(@as(usize, 4), proto.code.len);
    try std.testing.expectEqual(@as(usize, 2), proto.k.len);
    try std.testing.expectEqual(@as(u8, 4), proto.maxstacksize);
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
    defer {
        proto.deinit(std.testing.allocator);
        std.testing.allocator.destroy(proto);
    }

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
            proto.source_name,
            proto.line_defined,
            proto.last_line_defined,
            proto.code.len,
        });
    } else {
        try w.print("function <{s}:{d},{d}> ({d} instructions)\n", .{
            proto.source_name,
            proto.line_defined,
            proto.last_line_defined,
            proto.code.len,
        });
    }

    // Summary line: params, slots, upvalues, locals, constants, functions.
    try w.print("{s}{d}{s} params, {d} slots, {d} upvalue{s}, {d} local{s}, {d} constant{s}, {d} function{s}\n", .{
        indent,
        proto.numparams,
        if (proto.is_vararg) "+" else "",
        proto.maxstacksize,
        proto.upvalues.len,
        if (proto.upvalues.len != 1) "s" else "",
        proto.locvars.len,
        if (proto.locvars.len != 1) "s" else "",
        proto.k.len,
        if (proto.k.len != 1) "s" else "",
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

            // LOADI/LOADF: signed 16-bit immediate in B:C.
            .loadi, .loadf => {
                const bits: u32 = @as(u32, inst.b) | (@as(u32, inst.c) << 8);
                const signed: i32 = @bitCast(bits);
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
                const kstr = formatConst(&buf, proto.k[inst.c]);
                try w.print("\t{d}\t{d}\t{d}\t; {s}", .{ inst.a, inst.b, inst.c, kstr });
            },

            // LOADK: show constant value.
            .loadk => {
                var buf: [64]u8 = undefined;
                const kstr = formatConst(&buf, proto.k[inst.b]);
                try w.print("\t{d}\t{d}\t; {s}", .{ inst.a, inst.b, kstr });
            },

            // GETFIELD/SETFIELD/SELF/GETTABUP/SETTABUP: show string key.
            .getfield, .self => {
                var buf: [64]u8 = undefined;
                const kstr = formatConst(&buf, proto.k[inst.c]);
                try w.print("\t{d}\t{d}\t{d}\t; {s}", .{ inst.a, inst.b, inst.c, kstr });
            },
            .setfield => {
                var buf: [64]u8 = undefined;
                const kstr = formatConst(&buf, proto.k[inst.b]);
                try w.print("\t{d}\t{d}\t{d}\t; {s}", .{ inst.a, inst.b, inst.c, kstr });
            },
            .gettabup => {
                var buf: [64]u8 = undefined;
                const kstr = formatConst(&buf, proto.k[inst.c]);
                try w.print("\t{d}\t{d}\t{d}\t; {s}", .{ inst.a, inst.b, inst.c, kstr });
            },
            .settabup => {
                var buf: [64]u8 = undefined;
                const kstr = formatConst(&buf, proto.k[inst.b]);
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
    if (proto.k.len > 0) {
        try w.print("constants ({d}) for {s}:\n", .{ proto.k.len, proto.source_name });
        for (proto.k, 0..) |c, idx| {
            var buf: [64]u8 = undefined;
            const kstr = formatConst(&buf, c);
            try w.print("{s}\t{d}\t{s}\n", .{ indent, idx, kstr });
        }
    }

    // Locals table.
    if (proto.locvars.len > 0) {
        try w.print("locals ({d}) for {s}:\n", .{ proto.locvars.len, proto.source_name });
        for (proto.locvars) |lv| {
            try w.print("{s}\t{d}\t{s}\t{d}\t{d}\n", .{ indent, lv.reg, lv.name, lv.startpc, lv.endpc });
        }
    }

    // Upvalues table.
    if (proto.upvalues.len > 0) {
        try w.print("upvalues ({d}) for {s}:\n", .{ proto.upvalues.len, proto.source_name });
        for (proto.upvalues, 0..) |uv, idx| {
            try w.print("{s}\t{d}\t{s}\t{s}\t{d}\n", .{
                indent, idx, uv.name,
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
