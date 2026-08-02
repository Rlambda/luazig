// Bytecode codegen — walks the AST and emits PUC-style bytecode directly.
//
// This replaces the old IR-based codegen. Key differences from the old codegen:
//   - freereg model: registers are allocated LIFO (like PUC Lua), not SSA.
//   - Locals live in registers (not a separate array).
//   - Jump backpatching (not symbolic labels).
//   - Constant pool with deduplication.
//   - OT/IT multi-value convention (not CallSpec).
//   - Output is *bytecode.Proto (not *ir.Function).
//
// The codegen walks the same AST as the old codegen. The parser and AST
// types are unchanged.

const std = @import("std");

const Diag = @import("diag.zig").Diag;
const ast = @import("ast.zig");
const bc = @import("bytecode.zig");
const ltable = @import("ltable.zig");
const vm = @import("vm.zig");
const TokenKind = @import("token.zig").TokenKind;

// ---------------------------------------------------------------------------
// PUC ltm.h TMS event numbers for MMBIN C field.
//
// PUC Lua 5.5 emits a companion MMBIN/MMBINI/MMBINK instruction after every
// arithmetic and bitwise opcode. The C field carries the TMS event index so
// the VM knows which metamethod to dispatch when the operands don't support
// the native operation. luazig's VM handles metamethods inline, so MMBIN is
// a no-op at runtime — it exists solely for bytecode parity (T.listcode).
// ---------------------------------------------------------------------------

const TMS_ADD: u8 = 6;
const TMS_SUB: u8 = 7;
const TMS_MUL: u8 = 8;
const TMS_MOD: u8 = 9;
const TMS_POW: u8 = 10;
const TMS_DIV: u8 = 11;
const TMS_IDIV: u8 = 12;
const TMS_BAND: u8 = 13;
const TMS_BOR: u8 = 14;
const TMS_BXOR: u8 = 15;
const TMS_SHL: u8 = 16;
const TMS_SHR: u8 = 17;

/// Map a luazig TokenKind to its PUC TMS event number.
/// Returns null for non-arithmetic/non-bitwise operators.
fn tokenToTms(op: TokenKind) ?u8 {
    return switch (op) {
        .Plus => TMS_ADD,
        .Minus => TMS_SUB,
        .Star => TMS_MUL,
        .Percent => TMS_MOD,
        .Caret => TMS_POW,
        .Slash => TMS_DIV,
        .Idiv => TMS_IDIV,
        .Amp => TMS_BAND,
        .Pipe => TMS_BOR,
        .Tilde => TMS_BXOR,
        .Shl => TMS_SHL,
        .Shr => TMS_SHR,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Codegen state
// ---------------------------------------------------------------------------

pub const Codegen = struct {
    const StrictGlobalsMode = enum { legacy, strict, wildcard };

    source_name: []const u8,
    source: []const u8,
    alloc: std.mem.Allocator,

    diag: ?Diag = null,
    /// Formatting a final diagnostic and constructing a formatted diagnostic
    /// message must use disjoint storage: std.fmt rejects overlapping memcpy,
    /// and the message remains borrowed by `Diag` until the caller prints it.
    diag_buf: [256]u8 = undefined,
    diag_msg_buf: [256]u8 = undefined,

    // --- Register allocation (PUC freereg model) ---
    /// Next available register. Registers 0..nvarstack-1 hold locals;
    /// nvarstack..freereg-1 hold temporaries. At statement boundaries,
    /// freereg is reset to nvarstack.
    freereg: u8 = 0,
    /// Number of register-resident locals. This is the lower bound for
    /// freereg — temporaries are allocated above this.
    nvarstack: u8 = 0,
    /// High-water mark of freereg since the last resetRegs(). resetRegs nils
    /// [nvarstack, peak_freereg) so ALL temps used during a statement are
    /// cleared — including CALL argument registers and table-construction
    /// temps that were freed mid-expression. This prevents stale pointers
    /// from surviving GC, which would block weak table entry pruning.
    /// PUC Lua achieves the same effect via traversestack clearing values
    /// above L->top between GC cycles.
    peak_freereg: u8 = 0,

    // --- Bytecode output ---
    builder: bc.ProtoBuilder,
    line_hint: u32 = 0,
    /// PUC `lasttarget`: the PC of the most recent jump target (label or
    /// patchtohere). Used by `emitLoadNil` to decide whether merging with
    /// the previous LOADNIL is safe: if `pc > lasttarget`, no jump lands
    /// at or after the previous instruction, so merging cannot change
    /// what a jump target hits. If `pc == lasttarget`, the current
    /// position is a jump target and merging would alter the landing pad.
    lasttarget: u32 = 0,

    // --- Scoping ---
    bindings: std.ArrayListUnmanaged(Binding) = .empty,
    scope_marks: std.ArrayListUnmanaged(usize) = .empty,
    /// Lowest register that must be closed when control leaves each scope.
    /// Most scopes derive this from visible bindings; generic-for scopes also
    /// own a hidden TBC slot at base+3, which is tracked here explicitly.
    scope_close_regs: std.ArrayListUnmanaged(?u8) = .empty,
    loop_ends: std.ArrayListUnmanaged(JumpSlot) = .empty,
    // Goto/label resolution: labels are scoped (like locals).
    active_labels: std.ArrayListUnmanaged(ActiveLabel) = .empty,
    label_scope_marks: std.ArrayListUnmanaged(usize) = .empty,
    pending_gotos: std.ArrayListUnmanaged(PendingGoto) = .empty,
    /// Unique IDs for each pushed scope, used to validate goto/label
    /// scope compatibility. Sibling scopes get different IDs even at
    /// the same depth, preventing cross-branch goto resolution.
    scope_ids: std.ArrayListUnmanaged(usize) = .empty,
    /// Parent relation for lexical scope IDs. Scope IDs are never reused, so
    /// a pending goto can retain its origin scope after that scope is popped.
    scope_parent_by_id: std.ArrayListUnmanaged(usize) = .empty,
    scope_counter: usize = 1,
    /// Local declarations that a forward goto is not allowed to jump over.
    /// The log is append-only for the duration of one function compilation,
    /// matching PUC's active-local guard checks during label resolution.
    jump_guards: std.ArrayListUnmanaged(JumpGuard) = .empty,
    label_has_code_after: bool = true,

    // --- Lua 5.5 global declarations ---
    // A `global x` declaration is lexical: inside that scope, `x` must resolve
    // through `_ENV` even when an outer local with the same name exists.
    strict_globals_mode: StrictGlobalsMode = .legacy,
    strict_globals_wildcard_const: bool = false,
    declared_globals: std.StringHashMapUnmanaged(u32) = .{},
    declared_globals_log: std.ArrayListUnmanaged([]const u8) = .empty,
    declared_globals_depth_log: std.ArrayListUnmanaged(usize) = .empty,
    global_attrs: std.StringHashMapUnmanaged(bool) = .{},
    global_attr_log: std.ArrayListUnmanaged(GlobalAttrLog) = .empty,
    global_scope_marks: std.ArrayListUnmanaged(GlobalScopeMark) = .empty,

    // --- Upvalues / closures ---
    outer: ?*Codegen = null,
    upvalues: std.StringHashMapUnmanaged(u8) = .{},
    upvalue_descs: std.ArrayListUnmanaged(bc.Upvaldesc) = .empty,
    captured_regs: std.AutoHashMapUnmanaged(u8, void) = .{},
    const_locals: std.AutoHashMapUnmanaged(u8, void) = .{},
    readonly_locals: std.AutoHashMapUnmanaged(u8, void) = .{},
    close_locals: std.AutoHashMapUnmanaged(u8, void) = .{},
    const_upvalues: std.AutoHashMapUnmanaged(u8, void) = .{},

    // --- Compile-time constant values (PUC Lua RDKCTC / VCONST) ---
    //
    // PUC Lua stores the value of a compile-time `<const>` local directly in
    // the actvar array (`actvar[].k`), so that name references resolve to a
    // constant expdesc (VKINT/VKFLT/VKSTR/VNIL/VTRUE/VFALSE) instead of a
    // register load. This is what enables `constfolding` (lcode.c:1418): when
    // both operands of a binary op are such constants, the result is computed
    // at compile time and no runtime instruction is emitted.
    //
    // Crucially, PUC propagates the value *across function boundaries*: a
    // nested function that references a compile-time const sees VCONST too —
    // no upvalue is ever created for it (singlevaraux returns early, leaving
    // var->k == VCONST; const2val indexes the global actvar array). We mirror
    // this by keeping parallel value maps for locals (keyed by register) and
    // upvalues (keyed by upvalue index).
    /// Compile-time constant values of `<const>` locals in this function,
    /// keyed by register. Present iff the local has a compile-time constant
    /// initializer (literal or foldable expression).
    const_local_values: std.AutoHashMapUnmanaged(u8, ExpDesc.Val) = .{},
    /// Compile-time constant values of `<const>` upvalues, keyed by upvalue
    /// index. Populated when an upvalue captures a compile-time const local
    /// (or another const upvalue) from an enclosing function.
    const_upvalue_values: std.AutoHashMapUnmanaged(u8, ExpDesc.Val) = .{},
    /// Index of the _ENV upvalue for this function.
    /// For the main chunk, this is always 0. For child functions,
    /// it's lazily assigned when a global name is first accessed.
    /// GETTABUP/SETTABUP use this index.
    env_upvalue_idx: ?u8 = null,

    // --- Vararg state ---
    is_vararg: bool = false,
    chunk_is_vararg: bool = false,
    /// Register of the named vararg parameter (e.g. `...arg`).
    /// While the vararg stays virtual (PF_VAHID), reads of `arg[n]`/`arg.n`
    /// compile to GETVARG (no table). When the vararg escapes (assigned,
    /// returned, passed to a call, written to), we set `vararg_table_reg`
    /// on the ProtoBuilder (PF_VATAB) and the VM creates a real table.
    vararg_param_reg: ?u8 = null,

    /// A binding maps a name to a register (local variable).
    const Binding = struct {
        name: []const u8,
        reg: u8,
        depth: usize,
        locvar_index: usize,
    };

    const GlobalScopeMark = struct {
        mode: StrictGlobalsMode,
        wildcard_const: bool,
        decl_log_len: usize,
        decl_depth_log_len: usize,
        attr_log_len: usize,
    };

    const GlobalAttrLog = struct {
        name: []const u8,
        had_prev: bool,
        prev: bool = false,
    };

    /// A jump slot is a pending jump that needs backpatching (break target).
    const JumpSlot = struct {
        pc: u32,
        scope_mark: usize,
    };

    const PreparedLhs = union(enum) {
        direct: *const ast.Exp,
        field: struct { object: u8, key: u32, line: u32 },
        index: struct { object: u8, key: u8, line: u32 },
    };

    /// A pending goto waiting for its label to be seen.
    const PendingGoto = struct {
        pc: u32,
        close_pc: u32,
        name: []const u8,
        span: ast.Span,
        depth: usize,
        scope_id: usize,
        guard_len: usize,
        close_reg: ?u8 = null,
        resolved: bool = false,
    };

    /// An active label in the current scope chain.
    const ActiveLabel = struct {
        name: []const u8,
        pc: u32,
        line: u32,
        depth: usize,
        scope_id: usize,
        binding_mark: usize,
    };

    const JumpGuard = struct {
        name: []const u8,
        depth: usize,
        scope_id: usize,
    };

    pub const Error = std.mem.Allocator.Error || error{ CodegenError, ConstantPoolOverflow };

    // -----------------------------------------------------------------------
    // Initialization
    // -----------------------------------------------------------------------

    pub fn init(alloc: std.mem.Allocator, source_name: []const u8, source: []const u8) Codegen {
        return .{
            .source_name = source_name,
            .source = source,
            .alloc = alloc,
            .builder = bc.ProtoBuilder.init(alloc),
        };
    }

    /// Release compiler-only state. The returned Proto owns the bytecode,
    /// constants, child protos, upvalue descriptors, line tables, and local
    /// debug records transferred by ProtoBuilder.finish(); all maps and logs
    /// left on Codegen are scratch storage and must not accumulate across
    /// repeated load() calls.
    pub fn deinit(self: *Codegen) void {
        self.builder.deinit();
        self.bindings.deinit(self.alloc);
        self.scope_marks.deinit(self.alloc);
        self.scope_close_regs.deinit(self.alloc);
        self.loop_ends.deinit(self.alloc);
        self.active_labels.deinit(self.alloc);
        self.label_scope_marks.deinit(self.alloc);
        self.pending_gotos.deinit(self.alloc);
        self.scope_ids.deinit(self.alloc);
        self.scope_parent_by_id.deinit(self.alloc);
        self.jump_guards.deinit(self.alloc);
        self.declared_globals.deinit(self.alloc);
        self.declared_globals_log.deinit(self.alloc);
        self.declared_globals_depth_log.deinit(self.alloc);
        self.global_attrs.deinit(self.alloc);
        self.global_attr_log.deinit(self.alloc);
        self.global_scope_marks.deinit(self.alloc);
        self.upvalues.deinit(self.alloc);
        self.upvalue_descs.deinit(self.alloc);
        self.captured_regs.deinit(self.alloc);
        self.const_locals.deinit(self.alloc);
        self.readonly_locals.deinit(self.alloc);
        self.close_locals.deinit(self.alloc);
        self.const_upvalues.deinit(self.alloc);
        self.const_local_values.deinit(self.alloc);
        self.const_upvalue_values.deinit(self.alloc);
    }

    pub fn diagString(self: *Codegen) []const u8 {
        const d = self.diag orelse return "unknown error";
        return d.bufFormat(self.diag_buf[0..]);
    }

    fn setDiag(self: *Codegen, span: ast.Span, msg: []const u8) void {
        self.diag = .{
            .source_name = self.source_name,
            .line = span.line,
            .col = span.col,
            .msg = msg,
        };
    }

    fn setDiagFmt(self: *Codegen, span: ast.Span, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(self.diag_msg_buf[0..], fmt, args) catch "code generation error";
        self.setDiag(span, msg);
    }

    // -----------------------------------------------------------------------
    // Register allocation (freereg model — like PUC Lua)
    // -----------------------------------------------------------------------

    /// Reserve n registers starting at freereg. Updates maxstacksize.
    fn reserveRegs(self: *Codegen, n: u8) Error!void {
        const new_top_wide = @as(u16, self.freereg) + @as(u16, n);
        if (new_top_wide > 255) {
            self.setDiag(.{ .start = 0, .end = 0, .line = self.line_hint, .col = 0 }, "too many registers");
            return error.CodegenError;
        }
        const new_top: u8 = @intCast(new_top_wide);
        // P15.36: Snapshot the live top BEFORE bumping peak_freereg. This
        // captures the "before" boundary for the instruction being emitted.
        // The has_live_top_before flag ensures multiple reserveRegs calls
        // within one instruction don't overwrite the first snapshot.
        if (!self.builder.has_live_top_before) {
            self.builder.live_top_before = self.builder.current_live_top;
            self.builder.has_live_top_before = true;
        }
        self.freereg = new_top;
        if (new_top > self.peak_freereg) self.peak_freereg = new_top;
        self.builder.current_live_top = self.peak_freereg;
        self.builder.checkStack(self.freereg);
    }

    /// Allocate one register and return its index.
    fn allocReg(self: *Codegen) Error!u8 {
        try self.reserveRegs(1);
        return self.freereg - 1;
    }

    fn ensureFreeregAtLeast(self: *Codegen, top: u8) Error!void {
        if (self.freereg >= top) return;
        try self.reserveRegs(top - self.freereg);
    }

    /// Free a register if it's a temporary (above nvarstack).
    fn freeReg(self: *Codegen, reg: u8) void {
        if (reg >= self.nvarstack and reg + 1 == self.freereg) {
            self.freereg -= 1;
        }
    }

    /// Free two registers in correct high-to-low order.
    fn freeReg2(self: *Codegen, r1: u8, r2: u8) void {
        if (r1 > r2) {
            self.freeReg(r1);
            self.freeReg(r2);
        } else {
            self.freeReg(r2);
            self.freeReg(r1);
        }
    }

    /// Reset temporaries to the locals boundary. Called at statement boundaries.
    ///
    /// Uses peak_freereg (the high-water mark of register usage during this
    /// statement) instead of freereg, because genCall reduces freereg after
    /// a CALL to just cover the results — leaving argument registers and
    /// sub-expression temps untracked. Without nil'ing those, stale pointers
    /// survive GC and prevent weak table entry pruning.
    fn resetRegs(self: *Codegen) void {
        // P15.32: Instead of emitting LOADNIL to clear stale temp registers,
        // we record the live register boundary in live_reg_top. The GC uses
        // this per-PC table to mark only live registers, and the atomic phase
        // clears dead slots. This is the PUC Lua traversestack approach.
        self.freereg = self.nvarstack;
        self.peak_freereg = self.nvarstack;
        self.builder.current_live_top = self.nvarstack;
        // P15.36: Reset "before" snapshot for the next instruction.
        self.builder.live_top_before = self.nvarstack;
        self.builder.has_live_top_before = false;
    }

    /// Sync builder's current_live_top to the current peak_freereg.
    /// Called whenever peak_freereg changes outside reserveRegs (e.g. direct
    /// assignments in popScope, genCall, genExplistFixed).
    /// P15.36: Also snapshots the "before" boundary if not already set.
    fn syncLiveTop(self: *Codegen) void {
        if (!self.builder.has_live_top_before) {
            self.builder.live_top_before = self.builder.current_live_top;
            self.builder.has_live_top_before = true;
        }
        self.builder.current_live_top = self.peak_freereg;
    }

    // -----------------------------------------------------------------------
    // Expression descriptor (PUC Lua expdesc — P15.32)
    // -----------------------------------------------------------------------
    //
    // PUC Lua delays value materialization until a register is actually
    // needed. An ExpDesc describes *what* the value is, not *where* it is.
    // `dischargevars` resolves variable-kinds to value-kinds; `discharge2reg`
    // materializes a value into a specific register; `exp2nextreg` materializes
    // into the next free register.

    // PUC Lua uses a `expdesc` struct with a `k` (kind) tag and an untagged
    // union `u`. We follow PUC's *architecture* (delayed materialization,
    // the same set of kinds, the same discharge protocol) but use a Zig
    // `tagged union` for the payload — per AGENTS.md this is the idiomatic
    // Zig shape and lets the compiler enforce exhaustive switching.
    const ExpDesc = struct {
        val: Val = .{ .void = {} },
        // Jump lists for short-circuit / conditional expressions.
        // PUC stores these as patch-list head pointers; NULL = empty.
        // We use 0 = empty, positive = pc+1 (so 0 can be a valid pc).
        t_list: i32 = 0,
        f_list: i32 = 0,

        // Payload union. Each variant corresponds 1:1 to a PUC `expdesc.k`
        // value, carrying only the fields that variant needs. PUC uses a
        // single `u` union shared across all kinds; the tagged union keeps
        // the same semantics while making misuse a compile-time error.
        //
        // `idx` fields are `i32` (matching PUC `int`); an earlier `i16`
        // could overflow for large constant pools / register tables.
        const Val = union(enum) {
            void, // empty explist slot
            nil, // constant nil
            true, // constant true
            false, // constant false
            k: i32, // constant pool index
            k_int: i64, // integer constant
            k_float: f64, // float constant
            k_str: []const u8, // string constant (pre-intern)
            non_reloc: u8, // value in fixed register
            local: struct { ridx: u8, vidx: i16 = 0 }, // local variable
            // Virtual vararg parameter (PUC VVARGVAR). The named vararg `arg`
            // before it "escapes" (is discharged to a register, returned,
            // assigned, passed to a call). `ridx` is the register where the
            // vararg table *would* go if materialized (= numparams). While
            // virtual, reads of `arg[n]`/`arg.n` compile to GETVARG
            // instead of GETTABLE — no table allocation needed.
            vararg_var: struct { ridx: u8 },
            // Virtual vararg index (PUC VVARGIND). `arg[key]` where `arg` is
            // still virtual (vararg_var). `t` is the vararg parameter register
            // (= numparams), `idx` is the key register. Compiles to GETVARG
            // unless the vararg escapes (then converted to indexed + GETTABLE).
            vararg_index: struct { idx: i32, t: u8 },
            upval: i32, // upvalue index
            const_local: i32, // actvar index (compile-time const local)
            indexed: struct { idx: i32, t: u8, ro: bool = false, keystr: i32 = -1 }, // t[k] with register key
            index_i: struct { idx: i32, t: u8, ro: bool = false, keystr: i32 = -1 }, // t[const_int]
            index_str: struct { idx: i32, t: u8, ro: bool = false, keystr: i32 = -1 }, // t["string"]
            index_up: struct { idx: i32, t: u8, ro: bool = false, keystr: i32 = -1 }, // upvalue[k]
            reloc: i32, // relocatable instruction pc
            call: i32, // function call instruction pc
            vararg: i32, // vararg expression instruction pc
            // VJMP: a conditional jump (CMP+JMP or TEST+JMP) whose
            // jump-list encodes the boolean value without materializing
            // it in a register. `info` is the PC of the JMP instruction
            // (the comparison/test is at info-1). Mirrors PUC VJMP.
            // See lcode.c:1146-1225 for the jump-list protocol.
            jump: struct { info: i32 },
        };
    };

    /// Free the register held by an expression if it's a non-relocatable
    /// temporary (above nvarstack). Mirrors PUC `freeexp`.
    fn freeExp(self: *Codegen, e: *const ExpDesc) void {
        switch (e.val) {
            .non_reloc => |reg| self.freeReg(reg),
            else => {},
        }
    }

    /// Free two expressions in correct high-to-low order. Mirrors PUC `freeexps`.
    fn freeExps(self: *Codegen, e1: *const ExpDesc, e2: *const ExpDesc) void {
        const r1: i32 = switch (e1.val) {
            .non_reloc => |r| r,
            else => -1,
        };
        const r2: i32 = switch (e2.val) {
            .non_reloc => |r| r,
            else => -1,
        };
        if (r1 > r2) {
            self.freeExp(e1);
            self.freeExp(e2);
        } else {
            self.freeExp(e2);
            self.freeExp(e1);
        }
    }

    /// RK encoding: an operand that is either a register (k=0) or a
    /// constant pool index (k=1). Used by SET opcodes (SETTABLE, SETI,
    /// SETFIELD, SETTABUP) to fold constant values into the C field,
    /// eliminating a preceding LOADK. Mirrors PUC's `exp2RK` (lcode.c:1085).
    const RK = struct {
        /// The C field value: register number or constant pool index.
        c: u8,
        /// k-bit: false → R[C] (register), true → K[C] (constant pool).
        k: bool,
    };

    /// Try to convert an ExpDesc to a constant pool index (K form).
    /// Returns the K index if the expression is a compile-time constant
    /// that fits in MAXINDEXRK (255). Mirrors PUC's `luaK_exp2K`
    /// (lcode.c:1055). Modifies `e` to `.k` form on success.
    fn exp2K(self: *Codegen, e: *ExpDesc) Error!?u32 {
        if (e.t_list != 0 or e.f_list != 0) return null; // hasjumps
        switch (e.val) {
            .nil => {
                const kid = try self.builder.internConst(.nil);
                e.val = .{ .k = @intCast(kid) };
                return kid;
            },
            .true => {
                const kid = try self.builder.internConst(.{ .bool = true });
                e.val = .{ .k = @intCast(kid) };
                return kid;
            },
            .false => {
                const kid = try self.builder.internConst(.{ .bool = false });
                e.val = .{ .k = @intCast(kid) };
                return kid;
            },
            .k_int => |ival| {
                const kid = try self.builder.internConst(.{ .int = ival });
                e.val = .{ .k = @intCast(kid) };
                return kid;
            },
            .k_float => |nval| {
                const bits: u64 = @bitCast(nval);
                const kid = try self.builder.internConst(.{ .num_bits = bits });
                e.val = .{ .k = @intCast(kid) };
                return kid;
            },
            .k_str => |s| {
                const kid = try self.builder.internString(s);
                e.val = .{ .k = @intCast(kid) };
                return kid;
            },
            .k => |kid| return @intCast(kid),
            else => return null,
        }
    }

    /// Resolve an ExpDesc to RK form: try constant pool first (k=1),
    /// then fall back to a register (k=0). Mirrors PUC's `exp2RK`
    /// (lcode.c:1085). The caller must free the register (if k=0)
    /// via `freeExp` when done.
    fn exp2RK(self: *Codegen, e: *ExpDesc) Error!RK {
        if (try self.exp2K(e)) |kid| {
            if (kid <= 255) {
                return .{ .c = @intCast(kid), .k = true };
            }
        }
        const reg = try self.exp2anyreg(e);
        return .{ .c = reg, .k = false };
    }

    /// Resolve variable-kinds (VLOCAL, VUPVAL, VINDEXED*, VCONST) to
    /// value-kinds (VNONRELOC, VRELOC, VK*, VNIL, VTRUE, VFALSE).
    /// Does NOT allocate a register — the result is either a constant
    /// or a reference to an existing instruction/register.
    /// Mirrors PUC Lua `luaK_dischargevars`.
    fn dischargeVars(self: *Codegen, e: *ExpDesc) Error!void {
        switch (e.val) {
            .local => |v| {
                // Local becomes non-relocatable: value is in a fixed register.
                // However, if this local is captured as an upvalue (boxed),
                // the VM's SETUPVAL writes to cell.value, not to the stack
                // register. Non-MOVE instructions read from the stack directly
                // and would see a stale value. Emit MOVE to a fresh temp so
                // the value is read through MOVE's boxed-register workaround.
                // For non-captured locals, the register is valid directly —
                // this preserves the ExpDesc optimization for hot loops.
                if (self.captured_regs.get(v.ridx)) |_|{
                    const tmp = try self.allocReg();
                    _ = try self.builder.emitABC(.move, tmp, v.ridx, 0, self.line_hint);
                    e.val = .{ .non_reloc = tmp };
                } else {
                    e.val = .{ .non_reloc = v.ridx };
                }
            },
            // Virtual vararg parameter discharged to a register — the
            // vararg is escaping. Materialize a real table (PF_VATAB)
            // and convert to a regular local. Mirrors PUC's luaK_vapar2local
            // (lcode.c:808): needvatab(fs->f); var->k = VLOCAL.
            .vararg_var => |v| {
                self.needVarargTable();
                e.val = .{ .local = .{ .ridx = v.ridx } };
                // Now discharge as a local (fallthrough to .local above).
                if (self.captured_regs.get(v.ridx)) |_|{
                    const tmp = try self.allocReg();
                    _ = try self.builder.emitABC(.move, tmp, v.ridx, 0, self.line_hint);
                    e.val = .{ .non_reloc = tmp };
                } else {
                    e.val = .{ .non_reloc = v.ridx };
                }
            },
            // Virtual vararg index discharged — the vararg escapes.
            // Materialize a real table (PF_VATAB) and convert to a regular
            // indexed (GETTABLE). Mirrors PUC's check_readonly VVARGIND case
            // (lparser.c:306): needvatab(fs->f); e->k = VINDEXED.
            .vararg_index => |ind| {
                self.needVarargTable();
                e.val = .{ .indexed = .{ .idx = ind.idx, .t = ind.t } };
                // Now discharge as indexed (fallthrough to .indexed above).
                self.freeReg2(@intCast(ind.t), @intCast(ind.idx));
                const pc = try self.builder.emitABC(.gettable, 0, ind.t, @intCast(ind.idx), self.line_hint);
                e.val = .{ .reloc = @intCast(pc) };
            },
            .upval => |idx| {
                // Emit GETUPVAL with A=0 (relocatable), patch later by discharge2reg.
                const pc = try self.builder.emitABC(.getupval, 0, @intCast(idx), 0, self.line_hint);
                e.val = .{ .reloc = @intCast(pc) };
            },
            .index_up => |ind| {
                // GETTABUP's C field is 8 bits; for large constant indices
                // (>255 interned strings), fall back to GETUPVAL + LOADK +
                // GETTABLE. Mirrors emitGetTabUp's large-index path.
                if (ind.idx <= 255) {
                    const pc = try self.builder.emitABC(.gettabup, 0, ind.t, @intCast(ind.idx), self.line_hint);
                    e.val = .{ .reloc = @intCast(pc) };
                } else {
                    const key_reg = try self.allocReg();
                    try self.emitLoadK(key_reg, @intCast(ind.idx), self.line_hint);
                    const env_reg = try self.allocReg();
                    _ = try self.builder.emitABC(.getupval, env_reg, ind.t, 0, self.line_hint);
                    const pc = try self.builder.emitABC(.gettable, 0, env_reg, key_reg, self.line_hint);
                    self.freeReg(env_reg);
                    self.freeReg(key_reg);
                    e.val = .{ .reloc = @intCast(pc) };
                }
            },
            .index_i => |ind| {
                self.freeReg(ind.t);
                const pc = try self.builder.emitABC(.geti, 0, ind.t, @intCast(ind.idx), self.line_hint);
                e.val = .{ .reloc = @intCast(pc) };
            },
            .index_str => |ind| {
                // GETFIELD's C field is 8 bits; for large constant indices
                // (>255 interned strings), fall back to LOADK + GETTABLE.
                // Mirrors emitGlobalGet's large-index path.
                self.freeReg(ind.t);
                if (ind.idx <= 255) {
                    const pc = try self.builder.emitABC(.getfield, 0, ind.t, @intCast(ind.idx), self.line_hint);
                    e.val = .{ .reloc = @intCast(pc) };
                } else {
                    const key_reg = try self.allocReg();
                    try self.emitLoadK(key_reg, @intCast(ind.idx), self.line_hint);
                    const pc = try self.builder.emitABC(.gettable, 0, ind.t, key_reg, self.line_hint);
                    self.freeReg(key_reg);
                    e.val = .{ .reloc = @intCast(pc) };
                }
            },
            .indexed => |ind| {
                self.freeReg2(@intCast(ind.t), @intCast(ind.idx));
                const pc = try self.builder.emitABC(.gettable, 0, ind.t, @intCast(ind.idx), self.line_hint);
                e.val = .{ .reloc = @intCast(pc) };
            },
            .call => |pc_i| {
                // Already returns 1 result; becomes non-relocatable.
                const pc: usize = @intCast(pc_i);
                e.val = .{ .non_reloc = @intCast(self.builder.code.items[pc].a) };
            },
            .vararg => |pc_i| {
                // Set C=2 (one result), becomes relocatable.
                const pc: usize = @intCast(pc_i);
                self.builder.code.items[pc].c = 2;
                e.val = .{ .reloc = pc_i };
            },
            // const_local is intentionally NOT discharged here: the
            // compile-time-const resolution path is not yet implemented
            // (TODO: resolve to k_int/k_float/k_str/k). Falling through to
            // the `else` (no-op) keeps `const_local` intact, and
            // `discharge2reg` will error loudly if it ever encounters an
            // unresolved `const_local` — better than silently producing
            // wrong code. No code path currently produces `const_local`.
            // nil, true, false, k, k_int, k_float, k_str, non_reloc, reloc,
            // void, jump are already value-kinds — nothing to do.
            // (.jump is a VJMP — already "discharged"; discharge2reg handles
            // materialization when a register is actually required.)
            else => {},
        }
    }

    /// Materialize expression `e` into register `reg`.
    /// After this call, `e.val == .non_reloc` and the register is `reg`.
    /// Mirrors PUC Lua `discharge2reg`.
    fn discharge2reg(self: *Codegen, e: *ExpDesc, reg: u8) Error!void {
        try self.dischargeVars(e);
        switch (e.val) {
            .nil => {
                try self.emitLoadNil(reg, 1, self.line_hint);
            },
            .false => {
                _ = try self.builder.emitABC(.loadfalse, reg, 0, 0, self.line_hint);
            },
            .true => {
                _ = try self.builder.emitABC(.loadtrue, reg, 0, 0, self.line_hint);
            },
            .k_str => |s| {
                // Intern the literal string into the constant pool, then LOADK.
                const kid = try self.builder.internString(s);
                e.val = .{ .k = @intCast(kid) };
                try self.emitLoadK(reg, kid, self.line_hint);
            },
            .k => |kid| {
                // Val.k is i32 (PUC Lua uses `int` for k indices); emitLoadK
                // takes u32. Constant pool indices are non-negative, so the
                // cast is safe.
                try self.emitLoadK(reg, @intCast(kid), self.line_hint);
            },
            .k_int => |ival| {
                // 17-bit sBx LOADI (k-bit extends range to [-65535, 65536]).
                if (ival >= -65535 and ival <= 65536) {
                    _ = try self.builder.emit(Instruction.loadImm(.loadi, reg, @intCast(ival)), self.line_hint);
                } else {
                    const kid = try self.builder.internConst(.{ .int = ival });
                    try self.emitLoadK(reg, kid, self.line_hint);
                }
            },
            .k_float => |nval| {
                // PUC discharge2reg VKFLT → luaK_float: use LOADF for
                // integer-valued floats, else intern + LOADK.
                try self.emitFloatLoad(reg, nval, self.line_hint);
            },
            .reloc => |pc_i| {
                // Patch the instruction's A field to target `reg`.
                const pc: usize = @intCast(pc_i);
                self.builder.code.items[pc].a = reg;
                // P15.36: The instruction was emitted before allocReg
                // (reloc pattern), so live_top_before was snapshotted
                // before the bump. The snapshot correctly reflects the
                // "before" boundary for the patched instruction itself,
                // but it must NOT persist to the NEXT instruction.
                // Clear the flag and update live_top_before to the
                // current "after" boundary so the next instruction
                // sees the newly allocated register as live.
                self.builder.has_live_top_before = false;
                self.builder.live_top_before = self.builder.current_live_top;
            },
            .non_reloc => |src| {
                if (reg != src) {
                    _ = try self.builder.emitABC(.move, reg, src, 0, self.line_hint);
                }
            },
            // VJMP: materialize the conditional jump into a boolean register.
            //
            // `genComparisonExp` emits `CMP + JMP` where:
            //   - CMP skips JMP when condition is FALSE → falls through (false)
            //   - JMP executes when condition is TRUE → true-list (j.info)
            //
            // To materialize into `reg`:
            //   LOADFALSE  reg          (false path — CMP skipped JMP, falls here)
            //   JMP        +2          (skip LOADTRUE)
            //   LOADTRUE   reg          (true path — j.info patched here)
            //
            // This mirrors PUC's `exp2reg` + `code_loadbool` pattern
            // (lcode.c:971-993), but inlined because we lack LFALSESKIP.
            //
            // Safe only when f_list is empty (false path falls through to
            // LOADFALSE). All current callers (genComparison wrapper)
            // satisfy this: they materialize a fresh VJMP before any
            // goIfTrue/goIfFalse can populate f_list.
            .jump => |j| {
                // Use the comparison's line for the materialization
                // instructions, not line_hint (which may be the enclosing
                // statement's line). The CMP is at j.info-1; its lineinfo
                // carries the condition's source line. This preserves the
                // line-hook trace expected by db.lua tests.
                const cmp_pc: usize = @intCast(j.info - 1);
                const cond_line = self.builder.lineinfo.items[cmp_pc];
                _ = try self.builder.emitABC(.loadfalse, reg, 0, 0, cond_line);
                const skip_true = try self.emitJump(cond_line);
                self.patchListToHere(j.info); // true-list → LOADTRUE (here)
                _ = try self.builder.emitABC(.loadtrue, reg, 0, 0, cond_line);
                self.patchJumpToHere(skip_true); // false path skips LOADTRUE
            },
            // void, local, upval, indexed*, call, vararg should have been
            // resolved by dischargeVars. const_local is not yet implemented
            // (see dischargeVars). Reaching here is a codegen bug.
            else => {
                self.setDiag(.{ .start = 0, .end = 0, .line = self.line_hint, .col = 0 }, "internal: cannot discharge expression to register");
                return error.CodegenError;
            },
        }
        e.val = .{ .non_reloc = reg };
    }

    /// Materialize expression into the next free register (freereg).
    /// Allocates a register and discharges the expression into it.
    /// Mirrors PUC Lua `luaK_exp2nextreg`.
    fn exp2nextreg(self: *Codegen, e: *ExpDesc) Error!u8 {
        try self.dischargeVars(e);
        // Free the register if it's a non-relocatable temp, so we can
        // reuse it if it's at the top of the stack.
        self.freeExp(e);
        const reg = try self.allocReg();
        try self.discharge2reg(e, reg);
        return reg;
    }

    /// Materialize expression into any register. If already in a
    /// non-relocatable register, reuse it. Otherwise allocate a new one.
    /// Mirrors PUC Lua `luaK_exp2anyreg`.
    fn exp2anyreg(self: *Codegen, e: *ExpDesc) Error!u8 {
        try self.dischargeVars(e);
        switch (e.val) {
            .non_reloc => |reg| return reg,
            // All other kinds (constants, reloc, call, vararg, ...) go
            // through `exp2nextreg`, which allocates a fresh register and
            // discharges into it. PUC folds the constant special-case into
            // the same path because `discharge2reg` handles constants
            // uniformly; we do the same.
            else => return try self.exp2nextreg(e),
        }
    }

    /// Discharge to a value (no register required). Used when we only
    /// need the value for a test/condition, not as a register operand.
    /// Mirrors PUC Lua `luaK_exp2val`.
    fn exp2val(self: *Codegen, e: *ExpDesc) Error!void {
        try self.dischargeVars(e);
    }

    // -----------------------------------------------------------------------
    // Scope management
    // -----------------------------------------------------------------------

    fn pushScope(self: *Codegen) Error!void {
        try self.scope_marks.append(self.alloc, self.bindings.items.len);
        try self.scope_close_regs.append(self.alloc, null);
        try self.label_scope_marks.append(self.alloc, self.active_labels.items.len);

        const scope_id = self.scope_counter;
        self.scope_counter += 1;
        const parent_id = if (self.scope_ids.items.len == 0)
            0
        else
            self.scope_ids.items[self.scope_ids.items.len - 1];
        while (self.scope_parent_by_id.items.len <= scope_id) {
            try self.scope_parent_by_id.append(self.alloc, 0);
        }
        self.scope_parent_by_id.items[scope_id] = parent_id;
        try self.scope_ids.append(self.alloc, scope_id);
        try self.global_scope_marks.append(self.alloc, .{
            .mode = self.strict_globals_mode,
            .wildcard_const = self.strict_globals_wildcard_const,
            .decl_log_len = self.declared_globals_log.items.len,
            .decl_depth_log_len = self.declared_globals_depth_log.items.len,
            .attr_log_len = self.global_attr_log.items.len,
        });
    }

    fn currentScopeId(self: *const Codegen) usize {
        if (self.scope_ids.items.len == 0) return 0;
        return self.scope_ids.items[self.scope_ids.items.len - 1];
    }

    fn scopeIsDescendantOrSame(self: *const Codegen, child_scope_id: usize, ancestor_scope_id: usize) bool {
        var current = child_scope_id;
        while (current != 0) {
            if (current == ancestor_scope_id) return true;
            if (current >= self.scope_parent_by_id.items.len) break;
            current = self.scope_parent_by_id.items[current];
        }
        return ancestor_scope_id == 0;
    }

    fn mergeCloseReg(dst: *?u8, candidate: ?u8) void {
        const reg = candidate orelse return;
        if (dst.* == null or reg < dst.*.?) dst.* = reg;
    }

    fn markCurrentScopeClose(self: *Codegen, reg: u8) void {
        std.debug.assert(self.scope_close_regs.items.len != 0);
        mergeCloseReg(&self.scope_close_regs.items[self.scope_close_regs.items.len - 1], reg);
    }

    /// Whether returning from the current function still has any live
    /// to-be-closed state. Besides named `<close>` locals, generic-for emits
    /// a hidden TBC control slot tracked per active lexical scope. PUC Lua
    /// keeps the caller frame for both cases and emits CALL + RETURN rather
    /// than TAILCALL so the close chain runs only after the callee returns.
    fn hasActiveClose(self: *const Codegen) bool {
        if (self.close_locals.count() != 0) return true;
        for (self.scope_close_regs.items) |close_reg| {
            if (close_reg != null) return true;
        }
        return false;
    }

    fn scopeExitCloseReg(self: *Codegen, binding_mark: usize, hidden_close: ?u8) ?u8 {
        var result = hidden_close;
        if (binding_mark < self.bindings.items.len) {
            mergeCloseReg(&result, self.bindings.items[binding_mark].reg);
        }
        return result;
    }

    fn patchGotoClose(self: *Codegen, close_pc: u32, close_reg: ?u8) void {
        if (close_reg) |reg| {
            self.builder.code.items[close_pc] = Instruction.make(.close, reg, 0, 0);
        }
        // Otherwise the placeholder remains JMP 0, which is a no-op.
    }

    fn closeRegForActiveLabel(self: *Codegen, label: ActiveLabel) ?u8 {
        var result: ?u8 = null;
        if (label.binding_mark < self.bindings.items.len) {
            mergeCloseReg(&result, self.bindings.items[label.binding_mark].reg);
        }
        var scope_index = label.depth;
        while (scope_index < self.scope_close_regs.items.len) : (scope_index += 1) {
            mergeCloseReg(&result, self.scope_close_regs.items[scope_index]);
        }
        return result;
    }

    fn popGlobalScope(self: *Codegen) void {
        const n = self.global_scope_marks.items.len;
        std.debug.assert(n > 0);
        const mark = self.global_scope_marks.items[n - 1];
        self.global_scope_marks.items.len = n - 1;

        var i = self.declared_globals_log.items.len;
        while (i > mark.decl_log_len) {
            i -= 1;
            const name = self.declared_globals_log.items[i];
            if (self.declared_globals.getPtr(name)) |count| {
                std.debug.assert(count.* > 0);
                count.* -= 1;
                if (count.* == 0) _ = self.declared_globals.remove(name);
            }
        }
        self.declared_globals_log.items.len = mark.decl_log_len;
        self.declared_globals_depth_log.items.len = mark.decl_depth_log_len;
        var attr_index = self.global_attr_log.items.len;
        while (attr_index > mark.attr_log_len) {
            attr_index -= 1;
            const entry = self.global_attr_log.items[attr_index];
            if (entry.had_prev) {
                self.global_attrs.put(self.alloc, entry.name, entry.prev) catch @panic("oom");
            } else {
                _ = self.global_attrs.remove(entry.name);
            }
        }
        self.global_attr_log.items.len = mark.attr_log_len;
        self.strict_globals_mode = mark.mode;
        self.strict_globals_wildcard_const = mark.wildcard_const;
    }

    fn declareGlobalName(self: *Codegen, name: []const u8) Error!void {
        if (self.strict_globals_mode == .wildcard) return;
        self.strict_globals_mode = .strict;
        const entry = try self.declared_globals.getOrPut(self.alloc, name);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
        try self.declared_globals_log.append(self.alloc, name);
        try self.declared_globals_depth_log.append(self.alloc, self.scope_marks.items.len);
    }

    fn declareGlobalWildcard(self: *Codegen, readonly: bool) void {
        self.strict_globals_mode = .wildcard;
        self.strict_globals_wildcard_const = readonly;
    }

    fn declareGlobalAttr(self: *Codegen, name: []const u8, readonly: bool) Error!void {
        const previous = self.global_attrs.get(name);
        try self.global_attr_log.append(self.alloc, .{
            .name = name,
            .had_prev = previous != null,
            .prev = previous orelse false,
        });
        try self.global_attrs.put(self.alloc, name, readonly);
    }

    fn isConstGlobal(self: *const Codegen, name: []const u8) bool {
        var current: ?*const Codegen = self;
        while (current) |codegen| {
            if (codegen.global_attrs.get(name)) |readonly| return readonly;
            if (codegen.strict_globals_mode == .wildcard) return codegen.strict_globals_wildcard_const;
            current = codegen.outer;
        }
        return false;
    }

    fn isGlobalAllowed(self: *const Codegen, name: []const u8) bool {
        // `_ENV` is the mechanism used to access globals, not a declaration
        // governed by `global` statements. `_G` itself is otherwise an
        // ordinary global and follows the same lexical rules as every name.
        if (std.mem.eql(u8, name, "_ENV")) return true;

        var current: ?*const Codegen = self;
        var saw_strict = false;
        while (current) |codegen| {
            switch (codegen.strict_globals_mode) {
                .wildcard => return true,
                .strict => {
                    saw_strict = true;
                    if (codegen.declared_globals.contains(name)) return true;
                },
                .legacy => {},
            }
            current = codegen.outer;
        }
        return !saw_strict;
    }

    fn checkDeclaredGlobal(self: *Codegen, span: ast.Span, name: []const u8) Error!void {
        if (self.isGlobalAllowed(name)) return;
        self.setDiagFmt(span, "variable '{s}' is not declared", .{name});
        return error.CodegenError;
    }

    fn appendJumpGuard(self: *Codegen, name: []const u8) Error!void {
        try self.jump_guards.append(self.alloc, .{
            .name = name,
            .depth = self.scope_marks.items.len,
            .scope_id = self.currentScopeId(),
        });
    }

    fn popScope(self: *Codegen) void {
        const scope_count = self.scope_marks.items.len;
        std.debug.assert(scope_count > 0);
        const mark = self.scope_marks.items[scope_count - 1];
        const hidden_close = self.scope_close_regs.items[scope_count - 1];
        const exit_close = self.scopeExitCloseReg(mark, hidden_close);

        // Adopt unresolved pending gotos from this scope into the parent. Each
        // adoption records the CLOSE needed if the eventual label is outside
        // this scope; a same-scope forward label resolves before this point and
        // leaves the placeholder as a no-op.
        if (scope_count >= 2) {
            const parent_depth = scope_count - 1;
            for (self.pending_gotos.items) |*pg| {
                if (!pg.resolved and pg.depth == scope_count) {
                    mergeCloseReg(&pg.close_reg, exit_close);
                    pg.depth = parent_depth;
                }
            }
        }
        // Pop label scope.
        const ln = self.label_scope_marks.items.len;
        self.active_labels.items.len = self.label_scope_marks.items[ln - 1];
        self.label_scope_marks.items.len = ln - 1;
        // Pop scope ID.
        self.scope_ids.items.len -= 1;
        // Pop binding scope.
        self.scope_marks.items.len = scope_count - 1;
        self.scope_close_regs.items.len = scope_count - 1;

        const scope_end_pc = self.builder.pc();
        for (self.bindings.items[mark..]) |binding| {
            if (self.builder.locvars.items[binding.locvar_index].endpc == 0) {
                self.builder.closeLocVar(binding.locvar_index, scope_end_pc);
            }
        }

        // Emit CLOSE for <close> locals (in reverse declaration order).
        var i = self.bindings.items.len;
        while (i > mark) {
            i -= 1;
            const b = self.bindings.items[i];
            if (self.isCloseLocal(b.reg) or self.captured_regs.contains(b.reg)) {
                _ = self.builder.emitSimple(.close, self.line_hint) catch @panic("oom");
                // CLOSE takes the register to close from A.
                self.builder.code.items[self.builder.code.items.len - 1].a = b.reg;
            }
        }

        // Restore nvarstack to the scope entry point.
        if (mark < self.bindings.items.len) {
            // P15.32: No LOADNIL needed — live_reg_top tracks the boundary
            // and GC marks only live registers. Dead locals above the new
            // nvarstack will be cleared by the atomic phase.
            // Clear attribute markers for departing locals.
            for (self.bindings.items[mark..]) |b| {
                _ = self.const_locals.remove(b.reg);
                _ = self.const_local_values.remove(b.reg);
                _ = self.readonly_locals.remove(b.reg);
                _ = self.close_locals.remove(b.reg);
            }
            self.nvarstack = self.bindings.items[mark].reg;
            if (mark > 0) {
                self.nvarstack = self.bindings.items[mark - 1].reg + 1;
            } else {
                self.nvarstack = 0;
            }
        }
        self.freereg = self.nvarstack;
        self.peak_freereg = self.nvarstack;
        self.syncLiveTop();
        self.bindings.items.len = mark;
        self.popGlobalScope();
    }

    fn popScopeNoClear(self: *Codegen) void {
        const scope_count = self.scope_marks.items.len;
        std.debug.assert(scope_count > 0);
        const mark = self.scope_marks.items[scope_count - 1];
        const hidden_close = self.scope_close_regs.items[scope_count - 1];
        const exit_close = self.scopeExitCloseReg(mark, hidden_close);
        if (scope_count >= 2) {
            const parent_depth = scope_count - 1;
            for (self.pending_gotos.items) |*pg| {
                if (!pg.resolved and pg.depth == scope_count) {
                    mergeCloseReg(&pg.close_reg, exit_close);
                    pg.depth = parent_depth;
                }
            }
        }
        const ln = self.label_scope_marks.items.len;
        self.active_labels.items.len = self.label_scope_marks.items[ln - 1];
        self.label_scope_marks.items.len = ln - 1;
        self.scope_ids.items.len -= 1;
        self.scope_marks.items.len = scope_count - 1;
        self.scope_close_regs.items.len = scope_count - 1;
        const scope_end_pc = self.builder.pc();
        for (self.bindings.items[mark..]) |binding| {
            if (self.builder.locvars.items[binding.locvar_index].endpc == 0) {
                self.builder.closeLocVar(binding.locvar_index, scope_end_pc);
            }
        }
        if (mark < self.bindings.items.len) {
            if (mark > 0) {
                self.nvarstack = self.bindings.items[mark - 1].reg + 1;
            } else {
                self.nvarstack = 0;
            }
        }
        self.freereg = self.nvarstack;
        self.peak_freereg = self.nvarstack;
        self.syncLiveTop();
        self.bindings.items.len = mark;
        self.popGlobalScope();
    }

    fn appendBinding(self: *Codegen, name: []const u8, reg: u8) Error!void {
        const locvar_index = try self.builder.addLocVar(name, reg, self.builder.pc());
        try self.bindings.append(self.alloc, .{
            .name = name,
            .reg = reg,
            .depth = self.scope_marks.items.len,
            .locvar_index = locvar_index,
        });
        if (name.len != 0) try self.appendJumpGuard(name);
    }

    /// Declare a local variable in the next available register.
    fn declareLocal(self: *Codegen, name: []const u8) Error!u8 {
        const reg = self.freereg;
        try self.reserveRegs(1);
        self.nvarstack = self.freereg;
        try self.appendBinding(name, reg);
        return reg;
    }

    /// Allocate an anonymous temporary local (for and/or short-circuit).
    fn allocTempLocal(self: *Codegen) Error!u8 {
        return self.declareLocal("");
    }

    fn lookupLocal(self: *Codegen, name: []const u8) ?u8 {
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.bindings.items[i].name, name)) {
                return self.bindings.items[i].reg;
            }
        }
        return null;
    }

    fn lookupLocalBinding(self: *Codegen, name: []const u8) ?Binding {
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            const binding = self.bindings.items[i];
            if (std.mem.eql(u8, binding.name, name)) return binding;
        }
        return null;
    }

    fn latestDeclaredGlobalDepthSelf(self: *Codegen, name: []const u8) ?usize {
        var i = self.declared_globals_log.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.declared_globals_log.items[i], name)) {
                return self.declared_globals_depth_log.items[i];
            }
        }
        return null;
    }

    fn isForcedGlobalName(self: *Codegen, name: []const u8) bool {
        var current: ?*Codegen = self;
        while (current) |cg| {
            if (cg.declared_globals.contains(name)) return true;
            current = cg.outer;
        }
        return false;
    }

    fn markConstLocal(self: *Codegen, reg: u8) void {
        self.const_locals.put(self.alloc, reg, {}) catch @panic("oom");
        self.markReadonlyLocal(reg);
    }

    /// Capture the compile-time constant value of a `<const>` local's
    /// initializer (PUC RDKCTC, lparser.c:1850). PUC only promotes a `<const>`
    /// local to a compile-time constant when `nvars == nexps` and the
    /// initializer is a compile-time constant (`luaK_exp2const`). We evaluate
    /// the initializer purely (no code) and, if it is constant, store its
    /// value so that name references fold instead of loading the register.
    fn captureConstLocalValue(self: *Codegen, reg: u8, init_exp: ?*const ast.Exp) void {
        const e = init_exp orelse return;
        if (self.genConstExpDesc(e)) |c| {
            self.const_local_values.put(self.alloc, reg, c.val) catch @panic("oom");
        }
    }

    fn markReadonlyLocal(self: *Codegen, reg: u8) void {
        self.readonly_locals.put(self.alloc, reg, {}) catch @panic("oom");
    }

    fn markCloseLocal(self: *Codegen, reg: u8) void {
        self.close_locals.put(self.alloc, reg, {}) catch @panic("oom");
        // A <close> variable is read-only after its initialization, exactly
        // like PUC Lua's VDKTOCLOSE kind.
        self.markReadonlyLocal(reg);
    }

    /// Mark that this function needs a real vararg table (PF_VATAB).
    /// Called when the named vararg parameter "escapes" — i.e. is used as
    /// a regular value (returned, assigned, passed to a call) or written to
    /// via `arg[k] = v`. Mirrors PUC's `needvatab()` (lcode.c / lobject.h).
    /// After this call, `vararg_table_reg` is set on the ProtoBuilder, and
    /// the VM will create a real table in VARARGPREP.
    fn needVarargTable(self: *Codegen) void {
        if (self.vararg_param_reg) |va_reg| {
            if (self.builder.vararg_table_reg == null) {
                self.builder.vararg_table_reg = va_reg;
            }
        }
    }

    /// Check whether the vararg parameter is still virtual (no table).
    /// Returns true if `vararg_param_reg` is set but `vararg_table_reg`
    /// is not — meaning reads should compile to GETVARG.
    fn varargIsVirtual(self: *Codegen) bool {
        return self.vararg_param_reg != null and self.builder.vararg_table_reg == null;
    }

    /// Check if an AST expression is a simple Name reference to the vararg
    /// parameter. If so, return the vararg parameter's register. This lets
    /// `Field`/`Index` codegen intercept `arg[k]`/`arg.k` and compile to
    /// GETVARG instead of materializing a table via GETTABLE.
    fn tryVarargParamReg(self: *Codegen, expr: *const ast.Exp) ?u8 {
        const va_reg = self.vararg_param_reg orelse return null;
        switch (expr.node) {
            .Name => |n| {
                const name = n.slice(self.source);
                if (self.lookupLocalBinding(name)) |binding| {
                    if (binding.reg == va_reg) return va_reg;
                }
                return null;
            },
            else => return null,
        }
    }

    fn isConstLocal(self: *Codegen, reg: u8) bool {
        return self.const_locals.contains(reg);
    }

    fn isReadonlyLocal(self: *Codegen, reg: u8) bool {
        return self.readonly_locals.contains(reg);
    }

    fn isCloseLocal(self: *Codegen, reg: u8) bool {
        return self.close_locals.contains(reg);
    }

    /// Check whether any local in the register range [start_reg, end_reg)
    /// has been captured as an upvalue by a nested function.  Loop back-edges
    /// and break paths need OP_CLOSE only when at least one body local was
    /// captured — otherwise there are no open upvalues to close.
    fn anyCapturedInRange(self: *Codegen, start_reg: u8, end_reg: u8) bool {
        var reg = start_reg;
        while (reg < end_reg) : (reg += 1) {
            if (self.captured_regs.contains(reg)) return true;
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // Upvalue management
    // -----------------------------------------------------------------------

    fn nextUpvalueIndex(self: *Codegen) Error!u8 {
        // Lua bytecode reserves one byte for an upvalue index and limits a
        // function to 255 upvalues (indices 0..254). Diagnose the source
        // construct instead of letting @intCast panic at the boundary.
        if (self.upvalue_descs.items.len >= 255) {
            self.setDiagFmt(
                .{ .start = 0, .end = 0, .line = self.line_hint, .col = 0 },
                "too many upvalues (limit is 255) in function at line {d}",
                .{self.builder.line_defined},
            );
            return error.CodegenError;
        }
        return @intCast(self.upvalue_descs.items.len);
    }

    fn ensureUpvalue(self: *Codegen, name: []const u8) Error!u8 {
        if (self.upvalues.get(name)) |idx| return idx;
        // Walk up the closure chain to find the variable.
        if (self.outer) |outer| {
            if (outer.lookupLocal(name)) |reg| {
                // Capture from outer's register.
                // If this local is the outer function's virtual vararg
                // parameter, materialize the table (PF_VATAB) — the
                // vararg is escaping via upvalue capture.
                if (outer.vararg_param_reg) |va_reg| {
                    if (reg == va_reg and outer.varargIsVirtual()) {
                        outer.needVarargTable();
                    }
                }
                outer.captured_regs.put(outer.alloc, reg, {}) catch @panic("oom");
                const is_const = outer.isReadonlyLocal(reg);
                const idx = try self.nextUpvalueIndex();
                try self.upvalue_descs.append(self.alloc, .{
                    .instack = true,
                    .idx = reg,
                    .is_const = is_const,
                    .name = name,
                });
                try self.upvalues.put(self.alloc, name, idx);
                if (is_const) self.const_upvalues.put(self.alloc, idx, {}) catch @panic("oom");
                // Propagate the compile-time constant value (PUC VCONST):
                // if the captured local is a compile-time const, nested
                // functions see its value directly rather than GETUPVAL.
                if (outer.const_local_values.get(reg)) |v| {
                    self.const_upvalue_values.put(self.alloc, idx, v) catch @panic("oom");
                }
                return idx;
            }
            // Try outer's upvalues.
            if (outer.upvalues.get(name)) |outer_idx| {
                const is_const = outer.isConstUpvalue(outer_idx);
                const idx = try self.nextUpvalueIndex();
                try self.upvalue_descs.append(self.alloc, .{
                    .instack = false,
                    .idx = outer_idx,
                    .is_const = is_const,
                    .name = name,
                });
                try self.upvalues.put(self.alloc, name, idx);
                if (is_const) self.const_upvalues.put(self.alloc, idx, {}) catch @panic("oom");
                if (outer.const_upvalue_values.get(outer_idx)) |v| {
                    self.const_upvalue_values.put(self.alloc, idx, v) catch @panic("oom");
                }
                return idx;
            }
            // Not in outer's locals or upvalues — recurse further up.
            // After the recursive call, outer will have the upvalue
            // registered. We then create a corresponding entry in SELF
            // that references outer's upvalue (instack=false).
            const outer_idx = try outer.ensureUpvalue(name);
            const is_const = outer.isConstUpvalue(outer_idx);
            const idx = try self.nextUpvalueIndex();
            try self.upvalue_descs.append(self.alloc, .{
                .instack = false,
                .idx = outer_idx,
                .is_const = is_const,
                .name = name,
            });
            try self.upvalues.put(self.alloc, name, idx);
            if (is_const) self.const_upvalues.put(self.alloc, idx, {}) catch @panic("oom");
            if (outer.const_upvalue_values.get(outer_idx)) |v| {
                self.const_upvalue_values.put(self.alloc, idx, v) catch @panic("oom");
            }
            return idx;
        }
        return error.CodegenError; // not found
    }

    fn isConstUpvalue(self: *Codegen, idx: u8) bool {
        return self.const_upvalues.contains(idx);
    }

    // -----------------------------------------------------------------------
    // Jump backpatching
    // -----------------------------------------------------------------------

    /// Emit a JMP with offset 0. Returns the PC for later patching.
    fn emitJump(self: *Codegen, line: u32) Error!u32 {
        return self.builder.emitJump(.jmp, line);
    }

    /// Emit a conditional jump: if R[reg] matches the condition, skip the
    /// next instruction (which should be a JMP).
    /// C=0: skip if truthy; C=1: skip if falsy (PUC convention).
    fn emitTestJump(self: *Codegen, reg: u8, skip_if_falsy: bool, line: u32) Error!u32 {
        const c: u8 = if (skip_if_falsy) 1 else 0;
        return self.builder.emitABC(.test_, reg, 0, c, line);
    }

    /// Emit LOADNIL for registers R[from..from+n-1], merging with a preceding
    /// LOADNIL when the ranges are adjacent or overlapping. Mirrors PUC Lua's
    /// `luaK_nil` (lcode.c:846-860): if the previous instruction is LOADNIL
    /// and its range [pfrom..pfrom+pb] touches or overlaps [from..l], the two
    /// are coalesced into a single LOADNIL covering the union.
    ///
    /// CRITICAL for goto/label correctness: the merge only fires when
    /// `pc > lasttarget` (no jump targets the current position), matching
    /// PUC's `if (fs->pc > fs->lasttarget)` guard. Without this guard,
    /// `local x; ::L1::; local y` would merge the LOADNIL for `x` and `y`
    /// across the label, causing `goto L1` to land on the merged LOADNIL
    /// and re-initialize `x` — breaking the "cannot join this SETNIL with
    /// previous one" invariant tested by goto.lua.
    fn emitLoadNil(self: *Codegen, from: u8, n: u8, line: u32) Error!void {
        std.debug.assert(n > 0);
        const l: u8 = from + n - 1;
        if (self.builder.pc() > self.lasttarget and self.builder.code.items.len > 0) {
            const prev_idx = self.builder.code.items.len - 1;
            const prev = self.builder.code.items[prev_idx];
            if (@as(bc.Op, @enumFromInt(prev.op)) == .loadnil) {
                const pfrom: u8 = prev.a;
                const pl: u8 = pfrom + prev.b;
                if ((pfrom <= from and from <= pl + 1) or
                    (from <= pfrom and pfrom <= l + 1))
                {
                    const new_from: u8 = @min(pfrom, from);
                    const new_l: u8 = @max(pl, l);
                    self.builder.code.items[prev_idx] =
                        bc.Instruction.make(.loadnil, new_from, new_l - new_from, 0);
                    if (self.builder.current_live_top > self.builder.live_reg_top.items[prev_idx])
                        self.builder.live_reg_top.items[prev_idx] = self.builder.current_live_top;
                    return;
                }
            }
        }
        _ = try self.builder.emitABC(.loadnil, from, l - from, 0, line);
    }

    /// Patch a jump at `jump_pc` to target the current PC.
    /// Mirrors PUC `luaK_patchtohere` which calls `luaK_getlabel` to mark
    /// the current position as a jump target (updating `lasttarget`).
    fn patchJumpToHere(self: *Codegen, jump_pc: u32) void {
        self.lasttarget = self.builder.pc();
        self.builder.patchJump(jump_pc, self.builder.pc());
    }

    /// Patch a jump at `jump_pc` to target `target_pc`.
    fn patchJumpTo(self: *Codegen, jump_pc: u32, target_pc: u32) void {
        self.builder.patchJump(jump_pc, target_pc);
    }

    // -------------------------------------------------------------------
    // Jump-list management (PUC Lua lcode.c:150-317)
    // -------------------------------------------------------------------
    //
    // PUC Lua represents pending jump targets as singly-linked lists
    // threaded through the JMP instructions themselves: each JMP's offset
    // field stores the PC of the NEXT jump in the list (or NO_JUMP = 0
    // in our encoding, meaning "end of list"). This avoids allocating
    // auxiliary storage for pending patches and makes it trivial to
    // merge lists from short-circuited `and`/`or` operands.
    //
    // Two lists are maintained per ExpDesc:
    //   t_list — jumps taken when the expression is TRUE
    //   f_list — jumps taken when the expression is FALSE
    // A fresh VJMP from a comparison has f_list = its JMP pc (the CMP
    // skips the JMP when true, so the JMP is reached only when false)
    // and t_list = 0 (falling through means true; no true-jump yet).

    /// Concatenate jump-list `l2` into `*l1`. Mirrors PUC `luaK_concat`
    /// (lcode.c:182-193). If `l2` is 0 (end of list), nothing to do.
    /// If `*l1` is empty, `*l1` becomes `l2`. Otherwise walk `*l1` to
    /// its last element and patch that element's offset to point at `l2`'s
    /// head — linking the two lists.
    fn concatJumps(self: *Codegen, l1: *i32, l2: i32) void {
        if (l2 == 0) return; // nothing to concatenate
        if (l1.* == 0) {
            // no original list — l1 takes l2's head
            l1.* = l2;
            return;
        }
        // walk l1 to find its last element (the one whose target is 0)
        var list: i32 = l1.*;
        while (self.builder.getJumpTarget(@intCast(list))) |next| {
            list = @intCast(next);
        }
        // last element links to l2's head
        self.builder.patchJump(@intCast(list), @intCast(l2));
    }

    /// Patch every jump in `list` to target the current PC. Mirrors PUC
    /// `luaK_patchtohere` (lcode.c:314-317). Walks the chain reading the
    /// NEXT target BEFORE patching (patching overwrites the link field).
    fn patchListToHere(self: *Codegen, list: i32) void {
        var cur: i32 = list;
        while (cur != 0) {
            const next_opt = self.builder.getJumpTarget(@intCast(cur));
            self.patchJumpToHere(@intCast(cur));
            cur = if (next_opt) |n| @intCast(n) else 0;
        }
    }

    /// Negate the condition of a VJMP. Mirrors PUC `negatecondition`
    /// (lcode.c:1146-1151). The comparison instruction is at `jmp_pc - 1`
    /// (the instruction before the JMP). Flipping its C field (k-bit)
    /// inverts "skip when true" <-> "skip when false".
    fn negateCondition(self: *Codegen, jmp_pc: i32) void {
        const cmp_idx: usize = @intCast(jmp_pc - 1);
        const old_c = self.builder.code.items[cmp_idx].c;
        self.builder.code.items[cmp_idx].c = old_c ^ 1;
    }

    /// Emit code to "go through if true, jump if false". Mirrors PUC
    /// `luaK_goiftrue` (lcode.c:1178-1199). Produces a false-list (jumps
    /// taken when the expression is false) and patches the true-list to
    /// the current PC (true path falls through to here).
    ///
    /// With PUC convention (VJMP's JMP fires when TRUE), we must NEGATE
    /// the CMP so the JMP fires when FALSE → f_list. (PUC also negates
    /// because its VJMP jumps when true.)
    fn goIfTrue(self: *Codegen, e: *ExpDesc) Error!void {
        try self.dischargeVars(e);
        var pc: i32 = 0; // new jump for false-list (0 = none needed)
        switch (e.val) {
            .jump => |j| {
                // VJMP's JMP fires when true; negate so it fires when false → f_list.
                self.negateCondition(j.info);
                pc = j.info;
            },
            .true, .k, .k_int, .k_float, .k_str => {
                // Always true — no false-jump needed.
            },
            else => {
                // Materialize to a register, TEST + JMP (jump if false).
                // C=0: skip if truthy → JMP reached if falsy → false-list.
                const reg = try self.exp2anyreg(e);
                self.freeExp(e);
                _ = try self.builder.emitABC(.test_, reg, 0, 0, self.line_hint);
                const jmp_pc = try self.emitJump(self.line_hint);
                pc = @intCast(jmp_pc);
            },
        }
        self.concatJumps(&e.f_list, pc);
        self.patchListToHere(e.t_list);
        e.t_list = 0;
    }

    /// Emit code to "go through if false, jump if true". Mirrors PUC
    /// `luaK_goiffalse` (lcode.c:1205-1225). Produces a true-list (jumps
    /// taken when the expression is true) and patches the false-list to
    /// the current PC (false path falls through to here).
    ///
    /// With PUC convention (VJMP's JMP fires when TRUE), the VJMP already
    /// jumps when true → t_list, NO negation needed. (PUC also does not
    /// negate.)
    fn goIfFalse(self: *Codegen, e: *ExpDesc) Error!void {
        try self.dischargeVars(e);
        var pc: i32 = 0; // new jump for true-list (0 = none needed)
        switch (e.val) {
            .jump => |j| {
                // VJMP's JMP already fires when true → t_list, no negate.
                pc = j.info;
            },
            .nil, .false => {
                // Always false — no true-jump needed.
            },
            else => {
                // Materialize to a register, TEST + JMP (jump if true).
                // C=1: skip if falsy → JMP reached if truthy → true-list.
                const reg = try self.exp2anyreg(e);
                self.freeExp(e);
                _ = try self.builder.emitABC(.test_, reg, 0, 1, self.line_hint);
                const jmp_pc = try self.emitJump(self.line_hint);
                pc = @intCast(jmp_pc);
            },
        }
        self.concatJumps(&e.t_list, pc);
        self.patchListToHere(e.f_list);
        e.f_list = 0;
    }

    /// Patch a for-loop jump (FORPREP/FORLOOP/TFORPREP/TFORLOOP).
    /// These use A for the base register and B:C for a 16-bit signed offset.
    fn patchForJumpOffset(builder: *bc.ProtoBuilder, jump_pc: u32, offset: i32) void {
        const bits: i16 = @intCast(offset);
        const ubits: u16 = @bitCast(bits);
        builder.code.items[jump_pc].b = @truncate(ubits);
        builder.code.items[jump_pc].c = @truncate(ubits >> 8);
    }

    // -----------------------------------------------------------------------
    // Loop management (break/continue)
    // -----------------------------------------------------------------------

    fn pushLoopEnd(self: *Codegen, jump_pc: u32) Error!void {
        try self.loop_ends.append(self.alloc, .{
            .pc = jump_pc,
            .scope_mark = self.bindings.items.len,
        });
    }

    fn popLoopEnd(self: *Codegen) void {
        self.loop_ends.items.len -= 1;
    }

    fn currentLoopEnd(self: *Codegen) ?JumpSlot {
        if (self.loop_ends.items.len == 0) return null;
        return self.loop_ends.items[self.loop_ends.items.len - 1];
    }

    fn parseIntegerLiteral(lexeme: []const u8) ?i64 {
        return std.fmt.parseInt(i64, lexeme, 0) catch blk: {
            const uval = std.fmt.parseInt(u64, lexeme, 0) catch {
                if (!(std.mem.startsWith(u8, lexeme, "0x") or std.mem.startsWith(u8, lexeme, "0X"))) return null;
                var acc: u64 = 0;
                for (lexeme[2..]) |ch| {
                    const digit: u64 = if (ch >= '0' and ch <= '9')
                        ch - '0'
                    else if (ch >= 'a' and ch <= 'f')
                        10 + ch - 'a'
                    else if (ch >= 'A' and ch <= 'F')
                        10 + ch - 'A'
                    else
                        return null;
                    acc = acc *% 16 +% digit;
                }
                break :blk @as(i64, @bitCast(acc));
            };
            break :blk @as(i64, @bitCast(uval));
        };
    }

    // -----------------------------------------------------------------------
    // Expression compilation
    // -----------------------------------------------------------------------

    /// Generate code for an expression, returning an ExpDesc instead of
    /// a register. This is the PUC Lua `expr` equivalent. It defers
    /// materialization: the caller decides when to discharge to a register
    /// via exp2nextreg/exp2anyreg/discharge2reg.
    ///
    /// Currently handles leaf expressions (constants, names). Binary ops,
    /// calls, and other complex expressions still use the old genExp path
    /// and return a non_reloc ExpDesc.
    fn genExpDesc(self: *Codegen, e: *const ast.Exp) Error!ExpDesc {
        switch (e.node) {
            .Nil => return .{ .val = .nil },
            .True => return .{ .val = .true },
            .False => return .{ .val = .false },
            .Integer => {
                const lexeme = e.span.slice(self.source);
                const parsed: i64 = parseIntegerLiteral(lexeme) orelse {
                    self.setDiag(e.span, "invalid integer literal");
                    return error.CodegenError;
                };
                return .{ .val = .{ .k_int = parsed } };
            },
            .Number => {
                const lexeme = e.span.slice(self.source);
                const val = std.fmt.parseFloat(f64, lexeme) catch {
                    self.setDiag(e.span, "invalid number literal");
                    return error.CodegenError;
                };
                return .{ .val = .{ .k_float = val } };
            },
            .String => {
                const lexeme = e.span.slice(self.source);
                const decoded = try self.decodeStringLexeme(lexeme);
                return .{ .val = .{ .k_str = decoded } };
            },
            .Name => |n| {
                return self.genNameExpDesc(n.span, n.slice(self.source));
            },
            .Paren => |inner| {
                return self.genExpDesc(inner);
            },
            .BinOp, .UnOp => {
                // PUC constfolding: try to evaluate arithmetic/bitwise
                // expressions as compile-time constants first (no code
                // emitted). This lets folded subexpressions — e.g. the
                // `-k3_78` inside `(-k3_78)/4` — propagate as a constant
                // so the enclosing binary op can fold too. If the
                // expression isn't foldable, fall back to materialization.
                if (self.genConstExpDesc(e)) |c| return c;
                const reg = try self.genExp(e);
                return .{ .val = .{ .non_reloc = reg } };
            },
            .Field => |n| {
                // t.k: create an index_up/index_str ExpDesc that discharges
                // to GETTABUP (upvalue table) or GETFIELD (register table).
                // Mirrors PUC luaK_indexed: VUPVAL → VINDEXUP (1 opcode)
                // instead of GETUPVAL+GETFIELD (2 opcodes). Virtual vararg
                // (arg.k) must bypass and use GETVARG.
                if (self.tryVarargParamReg(n.object)) |va_reg| {
                    if (self.varargIsVirtual()) {
                        const kid = try self.builder.internString(n.name.slice(self.source));
                        const key = try self.allocReg();
                        try self.emitLoadK(key, kid, e.span.line);
                        self.freeReg(key);
                        const dst = try self.allocReg();
                        _ = try self.builder.emitABC(.getvarg, dst, va_reg, key, e.span.line);
                        return .{ .val = .{ .non_reloc = dst } };
                    }
                }
                const saved_hint = self.line_hint;
                defer self.line_hint = saved_hint;
                self.line_hint = e.span.line;
                var obj_ed = try self.genExpDesc(n.object);
                const kid = try self.builder.internString(n.name.slice(self.source));
                // PUC VINDEXUP: upvalue table + short-string key → GETTABUP.
                if (obj_ed.val == .upval and kid <= 255) {
                    return .{ .val = .{ .index_up = .{
                        .idx = @intCast(kid),
                        .t = @intCast(obj_ed.val.upval),
                        .keystr = @intCast(kid),
                    } } };
                }
                // VINDEXSTR / VINDEXED: discharge table to a register.
                const obj_reg = try self.exp2anyreg(&obj_ed);
                // GETFIELD's C field is 8 bits; for large constant indices
                // (>255 interned strings), fall back to indexed (GETTABLE).
                if (kid <= 255) {
                    return .{ .val = .{ .index_str = .{
                        .idx = @intCast(kid),
                        .t = obj_reg,
                        .keystr = @intCast(kid),
                    } } };
                }
                const key_reg = try self.allocReg();
                try self.emitLoadK(key_reg, kid, e.span.line);
                return .{ .val = .{ .indexed = .{
                    .idx = @intCast(key_reg),
                    .t = obj_reg,
                } } };
            },
            .Index => |n| {
                // t[k]: create an ExpDesc that discharges lazily to GETI
                // (integer key), GETFIELD (string key), GETTABUP (upvalue
                // table + string key), or GETTABLE (register key). Mirrors
                // PUC luaK_indexed: const int key → VINDEXI, const string
                // key → VINDEXSTR, upvalue table → VINDEXUP, register key
                // → VINDEXED.
                //
                // Virtual vararg parameter (arg[k]) must bypass this fusion:
                // GETVARG reads directly from the vararg slot without
                // materializing a table. Defer to the genExp path which
                // handles GETVARG.
                if (self.tryVarargParamReg(n.object)) |va_reg| {
                    if (self.varargIsVirtual()) {
                        const key = try self.genExp(n.index);
                        self.freeReg2(key, va_reg);
                        const dst = try self.allocReg();
                        _ = try self.builder.emitABC(.getvarg, dst, va_reg, key, e.span.line);
                        return .{ .val = .{ .non_reloc = dst } };
                    }
                }
                // Save line_hint so sub-expression discharge uses the Index
                // expression's line, then restore for the caller's discharge.
                const saved_hint = self.line_hint;
                defer self.line_hint = saved_hint;
                self.line_hint = e.span.line;
                var obj_ed = try self.genExpDesc(n.object);
                // PUC VINDEXUP: when the table is an upvalue, resolve the
                // key first (upvalue holds no register, so ordering is
                // safe). A short-string constant key produces GETTABUP
                // (1 opcode) instead of GETUPVAL+GETFIELD (2 opcodes).
                // For other key types, fall through to the register-based
                // path below (GETUPVAL + GETI/GETTABLE).
                if (obj_ed.val == .upval) {
                    const upval_idx: u8 = @intCast(obj_ed.val.upval);
                    var key_ed = try self.genExpDesc(n.index);
                    if (key_ed.val == .k_str) {
                        const kid = try self.builder.internString(key_ed.val.k_str);
                        if (kid <= 255) {
                            return .{ .val = .{ .index_up = .{
                                .idx = @intCast(kid),
                                .t = upval_idx,
                                .keystr = @intCast(kid),
                            } } };
                        }
                    }
                    // Non-string or long-string key: discharge upvalue to
                    // a register and use GETI (int key) or GETTABLE.
                    const obj_reg = try self.exp2anyreg(&obj_ed);
                    switch (key_ed.val) {
                        .k_int => |ival| {
                            if (ival >= 0 and ival <= 255) {
                                return .{ .val = .{ .index_i = .{
                                    .idx = @intCast(ival),
                                    .t = obj_reg,
                                } } };
                            }
                        },
                        else => {},
                    }
                    const key_reg = try self.exp2anyreg(&key_ed);
                    return .{ .val = .{ .indexed = .{
                        .idx = @intCast(key_reg),
                        .t = obj_reg,
                    } } };
                }
                // Non-upvalue path: discharge table to register first, then
                // resolve key (preserves existing register allocation order).
                const obj_reg = try self.exp2anyreg(&obj_ed);
                // Resolve the key via genExpDesc so <const> locals fold to
                // k_int/k_str (PUC VCONST). This lets a[k255] where
                // `local k255 <const> = 255` use GETI/SETI just like a[255].
                var key_ed = try self.genExpDesc(n.index);
                switch (key_ed.val) {
                    // Integer constant key in [0,255] → index_i (discharges
                    // to GETI, raw integer in C field). PUC VINDEXI.
                    .k_int => |ival| {
                        if (ival >= 0 and ival <= 255) {
                            return .{ .val = .{ .index_i = .{
                                .idx = @intCast(ival),
                                .t = obj_reg,
                            } } };
                        }
                    },
                    // String constant key → index_str (discharges to GETFIELD,
                    // interned string K index in C field). PUC VINDEXSTR.
                    .k_str => |s| {
                        const kid = try self.builder.internString(s);
                        if (kid <= 255) {
                            return .{ .val = .{ .index_str = .{
                                .idx = @intCast(kid),
                                .t = obj_reg,
                                .keystr = @intCast(kid),
                            } } };
                        }
                    },
                    else => {},
                }
                // Computed key → indexed (discharges to GETTABLE with a
                // register key). PUC VINDEXED. Both obj_reg and key_reg
                // are freed by the discharge's freeReg2(ind.t, ind.idx).
                const key_reg = try self.exp2anyreg(&key_ed);
                return .{ .val = .{ .indexed = .{
                    .idx = @intCast(key_reg),
                    .t = obj_reg,
                } } };
            },
            else => {
                // Fallback: use old genExp, wrap result as non_reloc.
                const reg = try self.genExp(e);
                return .{ .val = .{ .non_reloc = reg } };
            },
        }
    }

    /// Compile an expression in condition context. Returns an ExpDesc
    /// that may be a VJMP (for comparisons) or a materialized value
    /// (non_reloc). The caller passes this to goIfFalse/goIfTrue to
    /// produce the control-flow jumps.
    ///
    /// For comparisons (==, ~=, <, <=, >, >=): returns a VJMP ExpDesc
    /// (CMP+JMP, 2 instructions) — the caller's goIfFalse/goIfTrue will
    /// negate or use the jump directly, avoiding boolean materialization.
    /// For `and`/`or`: uses jump-list concatenation (sub-step 4).
    /// For other expressions: materializes to a register (non_reloc).
    fn genExpCond(self: *Codegen, e: *const ast.Exp) Error!ExpDesc {
        switch (e.node) {
            .BinOp => |n| {
                const op_line = if (n.op_line != 0) n.op_line else e.span.line;
                if (n.op == .EqEq or n.op == .NotEq or n.op == .Lt or
                    n.op == .Lte or n.op == .Gt or n.op == .Gte)
                {
                    // P15.38d: Check if RHS is a numeric constant usable
                    // for an immediate/constant comparison opcode.
                    //
                    // PUC codeeq/codeorder: if LHS is a constant and RHS is
                    // not, swap operands so the constant lands on the RHS.
                    // For order ops, invert direction: K<a → a>K, etc.
                    var rhs_nc = self.cmpConstFromExp(n.op, n.rhs);
                    var cmp_op = n.op;
                    var lhs_exp: *const ast.Exp = n.lhs;
                    var rhs_exp: *const ast.Exp = n.rhs;
                    if (rhs_nc == null) {
                        const lhs_nc = self.cmpConstFromExp(n.op, n.lhs);
                        if (lhs_nc != null) {
                            lhs_exp = n.rhs;
                            rhs_exp = n.lhs;
                            cmp_op = switch (n.op) {
                                .Lt => .Gt,
                                .Lte => .Gte,
                                .Gt => .Lt,
                                .Gte => .Lte,
                                else => n.op,
                            };
                            rhs_nc = lhs_nc;
                        }
                    }
                    const use_imm = rhs_nc != null and rhsConstUsableForCmp(cmp_op, rhs_nc.?);
                    // Normalize integer-valued floats (e.g. -4.0) to I-variant
                    // form so genComparisonExp routes to EQI instead of EQK.
                    if (rhs_nc) |nc| {
                        rhs_nc = normalizeCmpConst(nc);
                    }

                    // Comparison: produce VJMP via genComparisonExp.
                    // Discharge LHS to a register first (PUC infix order).
        const lhs_start_pc: usize = @intCast(self.builder.pc());
                    var lhs_ed = try self.genExpDesc(lhs_exp);
                    const lhs_reg = try self.exp2anyreg(&lhs_ed);
                    const lhs_end_pc: usize = @intCast(self.builder.pc());
                    for (self.builder.lineinfo.items[lhs_start_pc..lhs_end_pc]) |*inst_line| {
                        inst_line.* = op_line;
                    }

                    if (use_imm) {
                        // RHS is embedded in the comparison opcode.
                        return try self.genComparisonExp(cmp_op, lhs_reg, 0, op_line, rhs_nc);
                    }

                    // Standard path: materialize RHS to a register.
                    const saved_hint = self.line_hint;
                    self.line_hint = rhs_exp.span.line;
                    var rhs_ed = try self.genExpDesc(rhs_exp);
                    const rhs_reg = try self.exp2anyreg(&rhs_ed);
                    self.line_hint = saved_hint;
                    return try self.genComparisonExp(cmp_op, lhs_reg, rhs_reg, op_line, null);
                }
                if (n.op == .And) {
                    return try self.genAndExpCond(n.lhs, n.rhs, op_line);
                }
                if (n.op == .Or) {
                    return try self.genOrExpCond(n.lhs, n.rhs, op_line);
                }
                // Other binary ops (arithmetic, concat, bitwise): fall
                // through to materialization.
                const reg = try self.genExp(e);
                return .{ .val = .{ .non_reloc = reg } };
            },
            .Paren => |inner| {
                // Parentheses are transparent in condition context.
                return try self.genExpCond(inner);
            },
            else => {
                // Use genExpDesc so constant kinds (.true/.false/.nil and
                // k_int/k_float/k_str from <const> locals) are preserved
                // rather than materialized to a register. goIfTrue/goIfFalse
                // then fold always-true/always-false conditions without
                // emitting GETUPVAL/LOADBOOL+TEST+JMP (e.g. `while kTrue do`).
                var ed = try self.genExpDesc(e);
                switch (ed.val) {
                    .true, .false, .nil => return ed,
                    // Fold numeric/string constants in condition context
                    // (PUC luaK_goIfTrue/goIfFalse `const_value` path):
                    // any non-zero number is true, 0 is false; any string
                    // is true. This lets `while 1 do ... end` and
                    // `repeat ... until 0` fold to unconditional jumps
                    // without materializing the constant to a register.
                    .k_int => |ival| {
                        if (ival != 0) return .{ .val = .true } else return .{ .val = .false };
                    },
                    .k_float => |fval| {
                        if (fval != 0.0) return .{ .val = .true } else return .{ .val = .false };
                    },
                    .k_str => return .{ .val = .true },
                    else => {
                        const reg = try self.exp2anyreg(&ed);
                        return .{ .val = .{ .non_reloc = reg } };
                    },
                }
            },
        }
    }

    /// `and` in condition context: jump-list concatenation (PUC OPR_AND).
    /// PUC luaK_infix(OPR_AND) calls goIfTrue(lhs) — "go ahead only if
    /// lhs is true" (if false, jump to end). PUC luaK_posfix(OPR_AND)
    /// concats lhs.f_list into rhs.f_list and returns rhs.
    fn genAndExpCond(self: *Codegen, lhs_exp: *const ast.Exp, rhs_exp: *const ast.Exp, line: u32) Error!ExpDesc {
        _ = line;
        var lhs_ed = try self.genExpCond(lhs_exp);
        try self.goIfTrue(&lhs_ed); // if lhs is false, jump to end
        var rhs_ed = try self.genExpCond(rhs_exp);
        // lhs.f_list (false-jumps) are also false for the whole `and`.
        self.concatJumps(&rhs_ed.f_list, lhs_ed.f_list);
        return rhs_ed;
    }

    /// `or` in condition context: jump-list concatenation (PUC OPR_OR).
    /// PUC luaK_infix(OPR_OR) calls goIfFalse(lhs) — "go ahead only if
    /// lhs is false" (if true, jump to end). PUC luaK_posfix(OPR_OR)
    /// concats lhs.t_list into rhs.t_list and returns rhs.
    fn genOrExpCond(self: *Codegen, lhs_exp: *const ast.Exp, rhs_exp: *const ast.Exp, line: u32) Error!ExpDesc {
        _ = line;
        var lhs_ed = try self.genExpCond(lhs_exp);
        try self.goIfFalse(&lhs_ed); // if lhs is true, jump to end
        var rhs_ed = try self.genExpCond(rhs_exp);
        // lhs.t_list (true-jumps) are also true for the whole `or`.
        self.concatJumps(&rhs_ed.t_list, lhs_ed.t_list);
        return rhs_ed;
    }

    /// Resolve a name to an ExpDesc (PUC Lua `singlevar`).
    /// Local → VLOCAL, upvalue → VUPVAL, global → VINDEXUP or VINDEXSTR.
    /// Does NOT emit MOVE — the caller discharges only if needed.
    fn genNameExpDesc(self: *Codegen, span: ast.Span, name: []const u8) Error!ExpDesc {
        // Local variable?
        if (self.lookupLocalBinding(name)) |binding| {
            // Check if a global declaration shadows this local.
            if (self.latestDeclaredGlobalDepthSelf(name)) |global_depth| {
                if (global_depth > binding.depth) {
                    // Global: _ENV[name]
                    return self.genGlobalExpDesc(span, name);
                }
            }
            // Is this the named vararg parameter, still virtual?
            // If so, return vararg_var instead of local. This lets reads
            // of `arg[n]`/`arg.n` compile to GETVARG (no table allocation).
            // When discharged (used as a regular value), needVarargTable()
            // materializes the table and converts to local.
            if (self.vararg_param_reg) |va_reg| {
                if (binding.reg == va_reg and self.varargIsVirtual()) {
                    return .{ .val = .{ .vararg_var = .{ .ridx = va_reg } } };
                }
            }
            // PUC VCONST: a `<const>` local with a compile-time constant
            // initializer resolves directly to its value (VKINT/VKFLT/...),
            // not to its register — enabling constant folding at use sites.
            if (self.const_local_values.get(binding.reg)) |v| {
                return .{ .val = v };
            }
            return .{ .val = .{ .local = .{ .ridx = binding.reg } } };
        }
        // Forced global?
        if (self.isForcedGlobalName(name)) {
            try self.checkDeclaredGlobal(span, name);
            return self.genGlobalExpDesc(span, name);
        }
        // Upvalue?
        if (self.upvalues.get(name)) |idx| {
            // PUC VCONST propagated across functions: a const upvalue also
            // resolves directly to its value rather than emitting GETUPVAL.
            if (self.const_upvalue_values.get(idx)) |v| {
                return .{ .val = v };
            }
            return .{ .val = .{ .upval = @intCast(idx) } };
        }
        // Const in an enclosing scope, not yet registered as an upvalue?
        // PUC singlevaraux leaves such a name as VCONST (no upvalue created);
        // resolve it to the value directly so it can fold without forcing a
        // GETUPVAL at runtime.
        if (self.findConstUpvalueValue(name)) |v| {
            return .{ .val = v };
        }
        // Try to capture from outer scope.
        if (self.outer != null) {
            if (self.ensureUpvalue(name)) |idx| {
                return .{ .val = .{ .upval = @intCast(idx) } };
            } else |_| {}
        }
        // Global: _ENV[name]
        try self.checkDeclaredGlobal(span, name);
        return self.genGlobalExpDesc(span, name);
    }

    /// Build an ExpDesc for global access `_ENV[name]`.
    ///
    /// Mirrors `emitGlobalGet` at the ExpDesc level: when `_ENV` is a local
    /// (e.g. from `local _ENV = ...`), global access is GETFIELD on the local
    /// _ENV register (`.index_str`); otherwise it is GETTABUP on the _ENV
    /// upvalue (`.index_up`).
    fn genGlobalExpDesc(self: *Codegen, span: ast.Span, name: []const u8) Error!ExpDesc {
        const name_kid = try self.builder.internString(name);
        if (try self.resolveEnvReg(span.line)) |env_reg| {
            return .{ .val = .{ .index_str = .{
                .idx = @intCast(name_kid),
                .t = env_reg,
                .keystr = @intCast(name_kid),
            } } };
        }
        const env_idx = try self.ensureEnvUpvalue();
        return .{ .val = .{ .index_up = .{
            .idx = @intCast(name_kid),
            .t = env_idx,
            .keystr = @intCast(name_kid),
        } } };
    }

    /// Compile an expression into the next free register.
    /// Returns the register holding the result.
    fn genExp(self: *Codegen, e: *const ast.Exp) Error!u8 {
        switch (e.node) {
            .Nil => {
                const dst = try self.allocReg();
                try self.emitLoadNil(dst, 1, e.span.line);
                return dst;
            },
            .True => {
                const dst = try self.allocReg();
                _ = try self.builder.emitABC(.loadtrue, dst, 0, 0, e.span.line);
                return dst;
            },
            .False => {
                const dst = try self.allocReg();
                _ = try self.builder.emitABC(.loadfalse, dst, 0, 0, e.span.line);
                return dst;
            },
            .Integer => {
                const lexeme = e.span.slice(self.source);
                const parsed: i64 = parseIntegerLiteral(lexeme) orelse {
                    self.setDiag(e.span, "invalid integer literal");
                    return error.CodegenError;
                };
                // 17-bit sBx LOADI (k-bit extends range to [-65535, 65536]).
                if (parsed >= -65535 and parsed <= 65536) {
                    const dst = try self.allocReg();
                    _ = try self.builder.emit(Instruction.loadImm(.loadi, dst, @intCast(parsed)), e.span.line);
                    return dst;
                }
                // Large integer — store as constant.
                const dst = try self.allocReg();
                const kid = try self.builder.internConst(.{ .int = parsed });
                try self.emitLoadK(dst, kid, e.span.line);
                return dst;
            },
            .Number => {
                const lexeme = e.span.slice(self.source);
                const val = std.fmt.parseFloat(f64, lexeme) catch {
                    self.setDiag(e.span, "invalid number literal");
                    return error.CodegenError;
                };
                const dst = try self.allocReg();
                // PUC luaK_float: integer-valued floats use LOADF (no pool
                // entry); others use LOADK.
                try self.emitFloatLoad(dst, val, e.span.line);
                return dst;
            },
            .String => {
                const lexeme = e.span.slice(self.source);
                const decoded = try self.decodeStringLexeme(lexeme);
                const dst = try self.allocReg();
                const kid = try self.builder.internString(decoded);
                try self.emitLoadK(dst, kid, e.span.line);
                return dst;
            },
            .Name => |n| {
                return self.genNameValue(n.span, n.slice(self.source));
            },
            .Paren => |inner| {
                // Parentheses adjust to 1 value — same as the expression itself
                // for single-value contexts.
                return self.genExp(inner);
            },
            .BinOp => |n| {
                const op_line = if (n.op_line != 0) n.op_line else e.span.line;
                if (n.op == .And) return self.genAndExp(n.lhs, n.rhs, op_line);
                if (n.op == .Or) return self.genOrExp(n.lhs, n.rhs, op_line);
                return self.genBinOp(n, op_line, null);
            },
            .UnOp => |n| {
                const op_line = if (n.op_line != 0) n.op_line else e.span.line;
                return self.genUnOp(n, op_line);
            },
            .Field => |n| {
                // t.k  →  GETFIELD R[dst] R[t] K[k]
                // Or, if t is the virtual vararg parameter, GETVARG R[dst] R[t] R[k]
                // (PUC VVARGIND → OP_GETVARG; no table allocation needed.)
                if (self.tryVarargParamReg(n.object)) |va_reg| {
                    if (self.varargIsVirtual()) {
                        // For GETVARG, the key must be in a register.
                        // Load the string key into a register.
                        const kid = try self.builder.internString(n.name.slice(self.source));
                        const key = try self.allocReg();
                        try self.emitLoadK(key, kid, e.span.line);
                        self.freeReg(key);
                        const dst = try self.allocReg();
                        _ = try self.builder.emitABC(.getvarg, dst, va_reg, key, e.span.line);
                        return dst;
                    }
                }
                const obj = try self.genExp(n.object);
                const kid = try self.builder.internString(n.name.slice(self.source));
                self.freeReg(obj);
                const dst = try self.allocReg();
                if (kid <= 255) {
                    _ = try self.builder.emitABC(.getfield, dst, obj, @intCast(kid), e.span.line);
                } else {
                    const key = try self.allocReg();
                    try self.emitLoadK(key, kid, e.span.line);
                    _ = try self.builder.emitABC(.gettable, dst, obj, key, e.span.line);
                    self.freeReg(key);
                }
                return dst;
            },
            .Index => |n| {
                // t[k]  →  GETTABLE R[dst] R[t] R[k]
                // Or, if t is the virtual vararg parameter, GETVARG R[dst] R[t] R[k]
                // (PUC VVARGIND → OP_GETVARG; no table allocation needed.)
                if (self.tryVarargParamReg(n.object)) |va_reg| {
                    if (self.varargIsVirtual()) {
                        const key = try self.genExp(n.index);
                        // Free operands before allocating result (like genBinOp.
                        self.freeReg2(key, va_reg);
                        const dst = try self.allocReg();
                        _ = try self.builder.emitABC(.getvarg, dst, va_reg, key, e.span.line);
                        return dst;
                    }
                }
                const obj = try self.genExp(n.object);
                const key = try self.genExp(n.index);
                // Free operands before allocating result (like genBinOp).
                self.freeReg2(key, obj);
                const dst = try self.allocReg();
                _ = try self.builder.emitABC(.gettable, dst, obj, key, e.span.line);
                return dst;
            },
            .Call => {
                return self.genCall(e, 1, e.span.line);
            },
            .MethodCall => {
                return self.genMethodCall(e, 1, e.span.line);
            },
            .FuncDef => |body| {
                return self.genFuncDef(body, e.span.line);
            },
            .Table => |n| {
                return self.genTable(n, e.span.line);
            },
            .Dots => {
                if (!self.is_vararg) {
                    self.setDiag(e.span, "vararg used in non-vararg function");
                    return error.CodegenError;
                }
                // ... in single-value context: VARARG A 2 (1 result)
                const dst = try self.allocReg();
                _ = try self.builder.emitABC(.vararg, dst, 0, 2, e.span.line);
                return dst;
            },
        }
    }

    /// Compile an expression and ensure its result is in the next free
    /// register (self.freereg).  This is the bytecode equivalent of PUC
    /// Lua's `luaK_exp2nextreg`: it calls genExp, and if the result is
    /// not already at self.freereg (e.g., a local variable returned
    /// directly by genNameValue), it allocates a fresh register and emits
    /// a MOVE.  Use this in any context that expects values in a
    /// consecutive register range — return lists, multi-assignment RHS,
    /// call argument lists, for-loop control tuples, table constructor
    /// array items, etc.
    fn genExpNextReg(self: *Codegen, e: *const ast.Exp) Error!u8 {
        var ed = try self.genExpDesc(e);
        return self.exp2nextreg(&ed);
    }

    /// Load a constant into a register. Uses LOADK for small indices,
    /// LOADKX + EXTRAARG for large indices.
    fn emitLoadK(self: *Codegen, dst: u8, kid: u32, line: u32) Error!void {
        if (kid <= 255) {
            _ = try self.builder.emitABC(.loadk, dst, @intCast(kid), 0, line);
        } else {
            _ = try self.builder.emitABC(.loadkx, dst, 0, 0, line);
            _ = try self.builder.emit(Instruction.extra(kid), line);
        }
    }

    /// Emit code to load a float into `reg`, mirroring PUC's `luaK_float`
    /// (lcode.c:700). When the float is an exact integer that fits the LOADF
    /// signed-16-bit immediate, emit LOADF — which keeps it out of the
    /// constant pool (e.g. `0.0`, `3.0`). Otherwise intern it and use LOADK.
    ///
    /// This matters for the constant pool layout: PUC-style constant folding
    /// tests (`code.lua` checkKlist) expect integer-valued floats to use
    /// LOADF so they don't pollute the pool alongside genuine folded results.
    fn emitFloatLoad(self: *Codegen, reg: u8, f: f64, line: u32) Error!void {
        if (std.math.isFinite(f) and f == @trunc(f) and @abs(f) < 2147483648.0) {
            const fi: i32 = @intFromFloat(f);
            // 17-bit sBx LOADF (k-bit extends range to [-65535, 65536]).
            if (fi >= -65535 and fi <= 65536) {
                _ = try self.builder.emit(Instruction.loadImm(.loadf, reg, fi), line);
                return;
            }
        }
        const kid = try self.builder.internConst(bc.Constant.num(f));
        try self.emitLoadK(reg, kid, line);
    }

    /// Resolve a name to a value: local → upvalue → global.
    fn genNameValue(self: *Codegen, span: ast.Span, name: []const u8) Error!u8 {
        // Local variable?
        if (self.lookupLocalBinding(name)) |binding| {
            // A global declaration in a nested lexical scope shadows an
            // outer local with the same name. This is the Lua 5.5 equivalent
            // of resolving the name directly through `_ENV`.
            if (self.latestDeclaredGlobalDepthSelf(name)) |global_depth| {
                if (global_depth > binding.depth) {
                    const dst = try self.allocReg();
                    const name_kid = try self.builder.internString(name);
                    try self.emitGlobalGet(dst, name_kid, span.line);
                    return dst;
                }
            }
            // For all locals (const or not), copy to a fresh register so
            // the caller can use it as a call argument in the right position.
            // However, if this local is the virtual vararg parameter, materialize
            // the table first (PF_VATAB) — the vararg is escaping.
            if (self.vararg_param_reg) |va_reg| {
                if (binding.reg == va_reg and self.varargIsVirtual()) {
                    self.needVarargTable();
                }
            }
            // PUC RDKCTC: a <const> local with a compile-time constant
            // initializer has NO code emitted for its declaration — the
            // register is uninitialized. When the value is needed as a
            // runtime register, PUC discharges VCONST to a fresh register
            // via discharge2reg (LOADI/LOADK/LOADFALSE/etc.). We mirror
            // that here instead of MOVE from an uninitialized register.
            if (self.const_local_values.get(binding.reg)) |v| {
                const dst = try self.allocReg();
                var ed = ExpDesc{ .val = v };
                try self.discharge2reg(&ed, dst);
                return dst;
            }
            const dst = try self.allocReg();
            _ = try self.builder.emitABC(.move, dst, binding.reg, 0, span.line);
            return dst;
        }
        // A declaration in this function or an enclosing function forces the
        // name to be global before upvalue lookup. In particular, this keeps a
        // recursive `global function f()` from capturing an outer local `f`.
        if (self.isForcedGlobalName(name)) {
            try self.checkDeclaredGlobal(span, name);
            const dst = try self.allocReg();
            const name_kid = try self.builder.internString(name);
            try self.emitGlobalGet(dst, name_kid, span.line);
            return dst;
        }
        // Upvalue?
        if (self.upvalues.get(name)) |idx| {
            const dst = try self.allocReg();
            _ = try self.builder.emitABC(.getupval, dst, idx, 0, span.line);
            return dst;
        }
        // Try to capture from outer scope.
        if (self.outer != null) {
            if (self.ensureUpvalue(name)) |idx| {
                const dst = try self.allocReg();
                _ = try self.builder.emitABC(.getupval, dst, idx, 0, span.line);
                return dst;
            } else |_| {}
        }
        try self.checkDeclaredGlobal(span, name);
        // Global: R[A] = _ENV[name]. When a `local _ENV` is in scope it
        // shadows the _ENV upvalue (PUC Lua singlevar() semantics), so
        // emitGlobalGet indexes the local register instead of the upvalue.
        const dst = try self.allocReg();
        const name_kid = try self.builder.internString(name);
        try self.emitGlobalGet(dst, name_kid, span.line);
        return dst;
    }

    /// Ensure _ENV is registered as an upvalue, returning its index.
    /// For the main chunk, this is always 0 (pre-registered).
    /// For child functions, it's lazily created on first global access.
    fn ensureEnvUpvalue(self: *Codegen) Error!u8 {
        if (self.env_upvalue_idx) |idx| return idx;
        const idx = try self.ensureUpvalue("_ENV");
        self.env_upvalue_idx = idx;
        return idx;
    }

    /// Resolve the `_ENV` variable to a register that holds its runtime value.
    ///
    /// When `_ENV` is a regular local, returns its register directly. When
    /// `_ENV` is a `<const>` local with a compile-time constant value (PUC
    /// RDKCTC), the declaration emitted no code, so the register is
    /// uninitialized. In that case, PUC's `buildglobal` calls
    /// `luaK_exp2anyregup` which discharges VCONST to a temp register
    /// (emitting LOADI/LOADK on demand). We mirror that here.
    ///
    /// Returns the register holding the `_ENV` value, or null if `_ENV` is
    /// not a local (caller should use the upvalue path).
    fn resolveEnvReg(self: *Codegen, line: u32) Error!?u8 {
        const env_reg = self.lookupLocal("_ENV") orelse return null;
        if (self.const_local_values.get(env_reg)) |v| {
            // RDKCTC: _ENV register is uninitialized — load the constant
            // value into a temp register.
            const tmp = try self.allocReg();
            const prev_hint = self.line_hint;
            self.line_hint = line;
            defer self.line_hint = prev_hint;
            var ed = ExpDesc{ .val = v };
            try self.discharge2reg(&ed, tmp);
            return tmp;
        }
        return env_reg;
    }

    /// Emit a global read: `R[dst] = _ENV[name_kid]`.
    ///
    /// In PUC Lua `_ENV` is an ordinary variable name, and the compiler's
    /// `singlevar()` resolves it through the normal local/upvalue machinery
    /// *before* emitting the indexed load. When a `local _ENV` is in scope it
    /// therefore shadows the `_ENV` upvalue, and the global access must index
    /// that local register with GETFIELD/GETTABLE instead of the upvalue with
    /// GETTABUP. This helper centralises that resolution so every global-read
    /// site honours the shadowing.
    fn emitGlobalGet(self: *Codegen, dst: u8, name_kid: u32, line: u32) Error!void {
        if (try self.resolveEnvReg(line)) |env_reg| {
            // _ENV is shadowed by a local — index the local register directly.
            if (name_kid <= 255) {
                _ = try self.builder.emitABC(.getfield, dst, env_reg, @intCast(name_kid), line);
            } else {
                const key_reg = try self.allocReg();
                try self.emitLoadK(key_reg, name_kid, line);
                _ = try self.builder.emitABC(.gettable, dst, env_reg, key_reg, line);
                self.freeReg(key_reg);
            }
        } else {
            const env_idx = try self.ensureEnvUpvalue();
            try self.emitGetTabUp(dst, env_idx, name_kid, line);
        }
    }

    /// Emit a global write: `_ENV[name_kid] = R[val_reg]`.
    ///
    /// Symmetric counterpart to `emitGlobalGet`: honours a `local _ENV` shadow
    /// by emitting SETFIELD/SETTABLE on the local register, falling back to
    /// SETTABUP on the `_ENV` upvalue when no such local exists.
    fn emitGlobalSet(self: *Codegen, name_kid: u32, val: RK, line: u32) Error!void {
        if (try self.resolveEnvReg(line)) |env_reg| {
            if (name_kid <= 255) {
                _ = try self.builder.emitABCk(.setfield, env_reg, @intCast(name_kid), val.c, val.k, line);
            } else {
                const key_reg = try self.allocReg();
                try self.emitLoadK(key_reg, name_kid, line);
                _ = try self.builder.emitABCk(.settable, env_reg, key_reg, val.c, val.k, line);
                self.freeReg(key_reg);
            }
        } else {
            const env_idx = try self.ensureEnvUpvalue();
            try self.emitSetTabUp(env_idx, name_kid, val, line);
        }
    }

    /// Reject initialization of an already-defined global. Lua 5.5 global
    /// declarations with an initializer are definitions, not assignments:
    /// any existing non-nil value (including false) is a runtime error.
    fn emitGlobalDefinitionGuard(self: *Codegen, name_kid: u32, line: u32) Error!void {
        const current_reg = try self.allocReg();
        defer self.freeReg(current_reg);
        try self.emitGlobalGet(current_reg, name_kid, line);
        if (name_kid < 255) {
            _ = try self.builder.emitABC(.errdefined, current_reg, @intCast(name_kid + 1), 0, line);
        } else {
            _ = try self.builder.emitABC(.errdefined, current_reg, 0, 0, line);
            _ = try self.builder.emit(Instruction.extra(name_kid), line);
        }
    }

    /// Emit GETTABUP: R[A] = UpVal[B][K[C]].
    /// If C > 255, uses GETTABUP + EXTRAARG.
    fn emitGetTabUp(self: *Codegen, dst: u8, upval_idx: u8, kid: u32, line: u32) Error!void {
        if (kid <= 255) {
            _ = try self.builder.emitABC(.gettabup, dst, upval_idx, @intCast(kid), line);
        } else {
            // For large constant indices, load the string first then use GETTABLE.
            // This is a fallback — PUC uses EXTRAARG here.
            const tmp = try self.allocReg();
            try self.emitLoadK(tmp, kid, line);
            // We need UpVal[upval_idx] in a register to do GETTABLE.
            const env_reg = try self.allocReg();
            _ = try self.builder.emitABC(.getupval, env_reg, upval_idx, 0, line);
            _ = try self.builder.emitABC(.gettable, dst, env_reg, tmp, line);
            self.freeReg(env_reg);
            self.freeReg(tmp);
        }
    }

    /// Emit SETTABUP: UpVal[A][K[B]] = R[C].
    fn emitSetTabUp(self: *Codegen, upval_idx: u8, kid: u32, val: RK, line: u32) Error!void {
        if (kid <= 255) {
            _ = try self.builder.emitABCk(.settabup, upval_idx, @intCast(kid), val.c, val.k, line);
        } else {
            // Fallback: load string, get _ENV, use SETTABLE.
            const key_reg = try self.allocReg();
            try self.emitLoadK(key_reg, kid, line);
            const env_reg = try self.allocReg();
            _ = try self.builder.emitABC(.getupval, env_reg, upval_idx, 0, line);
            _ = try self.builder.emitABCk(.settable, env_reg, key_reg, val.c, val.k, line);
            self.freeReg(env_reg);
            self.freeReg(key_reg);
        }
    }

    fn emitSetName(self: *Codegen, span: ast.Span, name: []const u8, val_reg: u8) Error!void {
        const rk = RK{ .c = val_reg, .k = false };
        if (self.isForcedGlobalName(name)) {
            try self.checkDeclaredGlobal(span, name);
            if (self.isConstGlobal(name)) {
                self.setDiagFmt(span, "attempt to assign to const variable '{s}'", .{name});
                return error.CodegenError;
            }
            const kid = try self.builder.internString(name);
            try self.emitGlobalSet(kid, rk, span.line);
            return;
        }
        if (self.lookupLocal(name)) |reg| {
            if (self.isReadonlyLocal(reg)) {
                self.setDiagFmt(span, "attempt to assign to const variable '{s}'", .{name});
                return error.CodegenError;
            }
            _ = try self.builder.emitABC(.move, reg, val_reg, 0, span.line);
            return;
        }
        if (self.upvalues.get(name)) |idx| {
            if (self.isConstUpvalue(idx)) {
                self.setDiagFmt(span, "attempt to assign to const variable '{s}'", .{name});
                return error.CodegenError;
            }
            _ = try self.builder.emitABC(.setupval, val_reg, idx, 0, span.line);
            return;
        }
        // Try to capture from outer scope (mirrors genNameExpDesc's logic).
        // Without this, `function foo() ... end` inside a closure fails to
        // assign to an upvalue `foo` — the name is not yet registered as an
        // upvalue because it was never *read* before this assignment, so
        // `self.upvalues.get(name)` returns null and we fall through to
        // global assignment, silently writing to _ENV instead of the upvalue.
        if (self.outer != null) {
            if (self.ensureUpvalue(name)) |idx| {
                if (self.isConstUpvalue(idx)) {
                    self.setDiagFmt(span, "attempt to assign to const variable '{s}'", .{name});
                    return error.CodegenError;
                }
                _ = try self.builder.emitABC(.setupval, val_reg, idx, 0, span.line);
                return;
            } else |_| {}
        }
        try self.checkDeclaredGlobal(span, name);
        if (self.isConstGlobal(name)) {
            self.setDiagFmt(span, "attempt to assign to const variable '{s}'", .{name});
            return error.CodegenError;
        }
        const kid = try self.builder.internString(name);
        try self.emitGlobalSet(kid, rk, span.line);
    }

    // -----------------------------------------------------------------------
    // Binary / unary operations
    // -----------------------------------------------------------------------

    /// PUC Lua 5.5 uses a signed 8-bit immediate field (sC) for ADDI/SHRI/EQI/etc.
    /// The encoding is: stored_value = actual_value + OFFSET_sC, where
    /// OFFSET_sC = MAXARG_C >> 1 = 127. PUC's `fitsC` uses unsigned arithmetic:
    /// `l_castS2U(i) + OFFSET_sC <= MAXARG_C`, which gives range -127..128.
    /// (int2sC(-127)=0, int2sC(128)=255=MAXARG_C.)
    const SC_MIN: i64 = -127;
    const SC_MAX: i64 = 128;

    /// Check if an integer fits in the sC (signed 8-bit) immediate range.
    fn fitsSC(i: i64) bool {
        return i >= SC_MIN and i <= SC_MAX;
    }

    /// Encode an integer as sC (add OFFSET_sC = 127).
    fn int2sC(i: i64) u8 {
        return @intCast(i + 127);
    }

    /// A numeric constant extracted from an AST expression.
    const NumConst = struct {
        /// Constant pool index (for K-variant opcodes). null if the value
        /// is a small integer that fits in sC (use I-variant instead).
        kid: ?u32 = null,
        /// Small integer value for I-variant opcodes (ADDI/SHLI/SHRI).
        /// Only valid when kid == null.
        ival: i64 = 0,
        /// Whether the original literal was a float (affects ADDI: PUC only
        /// uses ADDI for integer constants; float constants always use K-variants).
        is_float: bool = false,
        /// The float value when is_float is true. Used by rhsConstUsableForCmp
        /// to detect integer-valued floats (e.g. -4.0, 128.0) that can use
        /// EQI/LTI/LEI/GTI/GEI instead of EQK — mirrors PUC's isSCnumber.
        fval: f64 = 0,
    };

    /// Try to extract a numeric constant from an AST expression without
    /// materializing it into a register. Returns null if the expression is
    /// not a simple numeric literal (Integer or Number).
    ///
    /// This mirrors PUC Lua's `tonumeral` function: it checks whether an
    /// expression is a numeric literal that can be used as an immediate or
    /// K operand without allocating a register.
    fn numericConstFromExp(self: *Codegen, e: *const ast.Exp) ?NumConst {
        switch (e.node) {
            .Integer => {
                const lexeme = e.span.slice(self.source);
                const parsed: i64 = parseIntegerLiteral(lexeme) orelse return null;
                if (fitsSC(parsed)) {
                    return .{ .ival = parsed };
                }
                const kid = self.builder.internConst(.{ .int = parsed }) catch return null;
                return .{ .kid = kid };
            },
            .Number => {
                const lexeme = e.span.slice(self.source);
                const val = std.fmt.parseFloat(f64, lexeme) catch return null;
                // Float constants always go through the constant pool.
                // PUC's isSCint only applies to integers.
                const kid = self.builder.internConst(bc.Constant.num(val)) catch return null;
                return .{ .kid = kid, .is_float = true, .fval = val };
            },
            // PUC VCONST: <const> locals and upvalues resolve to their
            // compile-time values. This enables K/I-variant fusion for
            // expressions like 'x + k1' where k1 = <const> 1.
            .Name => |name_tok| {
                const ed = self.constValueOfName(name_tok.slice(self.source)) orelse return null;
                return switch (ed.val) {
                    .k_int => |ival| if (fitsSC(ival))
                        .{ .ival = ival }
                    else blk: {
                        const kid = self.builder.internConst(.{ .int = ival }) catch return null;
                        break :blk .{ .kid = kid };
                    },
                    .k_float => |fval| blk: {
                        const kid = self.builder.internConst(bc.Constant.num(fval)) catch return null;
                        break :blk .{ .kid = kid, .is_float = true, .fval = fval };
                    },
                    else => null,
                };
            },
            // PUC constfolding: `-4.0` / `-128` are folded to constants at
            // parse time (luaK_prefix → luaK_constfolding), so tonumeral
            // recognizes them. Our parser keeps the UnOp node, so fold here
            // via genConstExpDesc and convert the resulting ExpDesc to a
            // NumConst. This enables EQI for `if -4.0 == a` and ADDI for
            // `x + -1` (matching PUC's codeeq/codearith behavior).
            .UnOp => {
                const folded = self.genConstExpDesc(e) orelse return null;
                return switch (folded.val) {
                    .k_int => |ival| if (fitsSC(ival))
                        .{ .ival = ival }
                    else blk: {
                        const kid = self.builder.internConst(.{ .int = ival }) catch return null;
                        break :blk .{ .kid = kid };
                    },
                    .k_float => |fval| blk: {
                        const kid = self.builder.internConst(bc.Constant.num(fval)) catch return null;
                        break :blk .{ .kid = kid, .is_float = true, .fval = fval };
                    },
                    else => null,
                };
            },
            else => return null,
        }
    }

    /// Like `numericConstFromExp`, but also recognizes string literals for
    /// `==`/`~=` comparisons. This mirrors PUC Lua 5.5's split:
    /// `codeeq` uses `isconst`/`exp2K` which intern ANY constant (including
    /// strings) into the constant pool, enabling EQK; `codeorder` uses
    /// `tonumeral`/`isSCnumber` which are numeric-only, so order comparisons
    /// (`<` `<=` `>` `>=`) cannot use a string operand via EQK/LTI/etc.
    ///
    /// By keeping string handling here (comparison-only) rather than in
    /// `numericConstFromExp`, the arithmetic K/I-variant path is protected
    /// from ever seeing a string NumConst (which would wrongly emit ADDK
    /// with a string constant index for `a + "hi"`).
    fn cmpConstFromExp(self: *Codegen, op: TokenKind, e: *const ast.Exp) ?NumConst {
        if (op == .EqEq or op == .NotEq) {
            switch (e.node) {
                // String literal: intern into the constant pool and return
                // a NumConst with kid set. genComparisonExp then emits EQK.
                .String => {
                    const lexeme = e.span.slice(self.source);
                    const decoded = self.decodeStringLexeme(lexeme) catch return null;
                    const kid = self.builder.internString(decoded) catch return null;
                    return .{ .kid = kid };
                },
                // <const> string local/upvalue (PUC VCONST): resolve to its
                // compile-time value and intern. Enables EQK for
                // `if a == kStr then` where `kStr = <const> "hi"`.
                .Name => |name_tok| {
                    const ed = self.constValueOfName(name_tok.slice(self.source)) orelse return null;
                    return switch (ed.val) {
                        .k_str => |s| blk: {
                            const kid = self.builder.internString(s) catch return null;
                            break :blk .{ .kid = kid };
                        },
                        else => null,
                    };
                },
                else => {},
            }
        }
        return self.numericConstFromExp(e);
    }

    fn binOpToBc(op: TokenKind) ?bc.Op {
        return switch (op) {
            .Plus => .add,
            .Minus => .sub,
            .Star => .mul,
            .Slash => .div,
            .Percent => .mod,
            .Caret => .pow,
            .Idiv => .idiv,
            .Amp => .band,
            .Pipe => .bor,
            .Tilde => .bxor,
            .Shl => .shl,
            .Shr => .shr,
            else => null,
        };
    }

    fn cmpOpToBc(op: TokenKind) ?bc.Op {
        return switch (op) {
            .EqEq => .eq,
            .Lt => .lt,
            .Lte => .le,
            // > and >= are handled by swapping operands.
            else => null,
        };
    }

    // -----------------------------------------------------------------------
    // Compile-time constant folding (PUC Lua constfolding — lcode.c:1418)
    // -----------------------------------------------------------------------
    //
    // When both operands of an arithmetic/bitwise op are compile-time
    // numeric constants, PUC computes the result at compile time and emits
    // no runtime instruction. This module mirrors PUC's trio:
    //
    //   tonumeral  — is an expdesc a numeric constant? (lcode.c:57)
    //   validop    — would folding raise a runtime error? (lcode.c:1399)
    //   luaO_rawarith — the actual arithmetic (lobject.c:151)
    //
    // plus the final guard in constfolding: a float result of NaN or 0.0 is
    // not folded (to preserve -0.0 / metamethod semantics at runtime).

    /// A numeric value used during folding — the Zig analogue of PUC's
    /// `TValue` restricted to its numeric tag (LUA_VNUMINT / LUA_VNUMFLT).
    const NumVal = union(enum) { int: i64, float: f64 };

    /// PUC `tonumeral` (lcode.c:57): return the numeric value of an expdesc
    /// if it is an integer or float constant, else null. ExpDescs carrying
    /// jump lists (`.jump`) are naturally excluded — they are not `k_int`/
    /// `k_float` — matching PUC's `hasjumps` guard.
    fn tonumeral(val: ExpDesc.Val) ?NumVal {
        return switch (val) {
            .k_int => |i| .{ .int = i },
            .k_float => |f| .{ .float = f },
            else => null,
        };
    }

    fn numValToFloat(v: NumVal) f64 {
        return switch (v) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
        };
    }

    /// Convert a numeric value to an i64 for a bitwise operation, mirroring
    /// PUC's `tointegerns` with `F2Ieq`: a float converts only if it is an
    /// exact integer. Returns null for non-integral floats (the operation
    /// must fall back to a runtime metamethod path, not be folded).
    fn numValToInt(v: NumVal) ?i64 {
        return switch (v) {
            .int => |i| i,
            .float => |f| if (std.math.isFinite(f) and f == @trunc(f) and @abs(f) < 9.2e18)
                @intFromFloat(f) else null,
        };
    }

    fn numValIsZero(v: NumVal) bool {
        return switch (v) {
            .int => |i| i == 0,
            .float => |f| f == 0.0, // true for both +0.0 and -0.0
        };
    }

    /// Is this binary operator foldable? Mirrors PUC `foldbinop` (lcode.h:45):
    /// `#define foldbinop(op) ((op) <= OPR_SHR)` — i.e. every arithmetic and
    /// bitwise binary operator. Comparisons, concat, and/or are NOT folded.
    fn isFoldBinOp(op: TokenKind) bool {
        return switch (op) {
            .Plus, .Minus, .Star, .Slash, .Percent, .Caret, .Idiv,
            .Amp, .Pipe, .Tilde, .Shl, .Shr => true,
            else => false,
        };
    }

    /// PUC `validop` (lcode.c:1399): return false if folding the operation
    /// would raise an error that must surface at runtime.
    ///   - Bitwise ops need both operands convertible to integers.
    ///   - Division-class ops (DIV/IDIV/MOD) cannot have a zero divisor.
    fn validFoldOp(op: TokenKind, v1: NumVal, v2: NumVal) bool {
        return switch (op) {
            .Amp, .Pipe, .Tilde, .Shl, .Shr =>
                numValToInt(v1) != null and numValToInt(v2) != null,
            .Slash, .Idiv, .Percent => !numValIsZero(v2),
            else => true,
        };
    }

    /// PUC integer left shift, `luaV_shiftl` (lvm.c). Shifts use unsigned
    /// semantics (`intop`); amounts >= 64 or <= -64 yield 0.
    fn foldShiftLeft(x: i64, y: i64) i64 {
        const ux: u64 = @bitCast(x);
        if (y < 0) {
            if (y <= -64) return 0;
            const s: u6 = @intCast(-y);
            return @bitCast(ux >> s);
        }
        if (y >= 64) return 0;
        const s: u6 = @intCast(y);
        return @bitCast(ux << s);
    }

    /// PUC `luaV_shiftr(x,y) == luaV_shiftl(x, -y)` (lvm.h:111), with the
    /// negation performed in wrapping arithmetic so MIN_INT is safe.
    fn foldShiftRight(x: i64, y: i64) i64 {
        return foldShiftLeft(x, 0 -% y);
    }

    /// PUC integer floor-division, `luaV_idiv` (lvm.c:766). Caller guarantees
    /// `n != 0` (validop) — only the MIN_INT // -1 overflow guard remains.
    fn foldIntIdiv(m: i64, n: i64) i64 {
        if (n == -1) return 0 -% m; // avoid MIN_INT // -1 overflow
        var q = @divTrunc(m, n); // C division truncates toward zero
        if ((m ^ n) < 0 and @rem(m, n) != 0) q -= 1; // floor correction
        return q;
    }

    /// PUC integer modulo, `luaV_mod` (lvm.c:778). Caller guarantees `n != 0`
    /// (validop) — only the MIN_INT % -1 overflow guard remains. Result takes
    /// the sign of the divisor.
    fn foldIntMod(m: i64, n: i64) i64 {
        if (n == -1) return 0; // m % -1 == 0; avoid MIN_INT % -1 overflow
        var r = @rem(m, n); // truncated remainder (sign of dividend, == C fmod for ints)
        if (r != 0 and (r ^ n) < 0) r += n; // make sign match divisor
        return r;
    }

    /// PUC `intarith` (lobject.c:112): integer arithmetic for folding.
    /// Wrapping semantics match PUC's `intop` macro (unsigned op + reinterpret).
    fn intArith(op: TokenKind, v1: i64, v2: i64) i64 {
        return switch (op) {
            .Plus => v1 +% v2,
            .Minus => v1 -% v2,
            .Star => v1 *% v2,
            .Percent => foldIntMod(v1, v2),
            .Idiv => foldIntIdiv(v1, v2),
            .Amp => v1 & v2,
            .Pipe => v1 | v2,
            .Tilde => v1 ^ v2,
            .Shl => foldShiftLeft(v1, v2),
            .Shr => foldShiftRight(v1, v2),
            else => unreachable, // only foldable ops reach here
        };
    }

    /// PUC float modulo, `luai_nummod` (llimits.h:257): `fmod` then correct
    /// the sign so the result takes the sign of the divisor.
    fn floatMod(a: f64, b: f64) f64 {
        var m: f64 = @rem(a, b); // Zig @rem == C fmod (sign of dividend)
        if (m > 0) {
            if (b < 0) m += b;
        } else if (m < 0 and b > 0) m += b;
        return m;
    }

    /// PUC `numarith` (lobject.c:135): floating-point arithmetic for folding.
    fn numArith(op: TokenKind, v1: f64, v2: f64) f64 {
        return switch (op) {
            .Plus => v1 + v2,
            .Minus => v1 - v2,
            .Star => v1 * v2,
            .Slash => v1 / v2, // luai_numdiv
            .Caret => std.math.pow(f64, v1, v2), // luai_numpow
            .Idiv => @floor(v1 / v2), // luai_numidiv = floor(a/b)
            .Percent => floatMod(v1, v2), // luai_nummod
            else => unreachable,
        };
    }

    /// PUC `luaO_rawarith` (lobject.c:151): perform the raw arithmetic,
    /// returning null if the operands aren't suitable for this op (the
    /// runtime would then invoke a metamethod). `validFoldOp` is checked by
    /// the caller first, so division-by-zero never reaches here.
    const FoldResult = union(enum) { int: i64, float: f64 };

    fn rawArith(op: TokenKind, v1: NumVal, v2: NumVal) ?FoldResult {
        return switch (op) {
            // Bitwise: operate only on integers (floats must be exact ints).
            .Amp, .Pipe, .Tilde, .Shl, .Shr => blk: {
                const ia = numValToInt(v1) orelse break :blk null;
                const ib = numValToInt(v2) orelse break :blk null;
                break :blk .{ .int = intArith(op, ia, ib) };
            },
            // DIV/POW: operate only on floats.
            .Slash => .{ .float = numValToFloat(v1) / numValToFloat(v2) },
            .Caret => .{ .float = std.math.pow(f64, numValToFloat(v1), numValToFloat(v2)) },
            // ADD/SUB/MUL/MOD/IDIV: int if both int, else float.
            else => blk: {
                if (v1 == .int and v2 == .int) {
                    break :blk .{ .int = intArith(op, v1.int, v2.int) };
                }
                break :blk .{ .float = numArith(op, numValToFloat(v1), numValToFloat(v2)) };
            },
        };
    }

    /// PUC `constfolding` for binary ops (lcode.c:1418). Returns a constant
    /// ExpDesc on success, or null if folding does not apply (non-numeric
    /// operands, unsafe operation, or a float result of NaN/0.0).
    fn foldBinOp(op: TokenKind, lhs: ExpDesc, rhs: ExpDesc) ?ExpDesc {
        if (!isFoldBinOp(op)) return null;
        const v1 = tonumeral(lhs.val) orelse return null;
        const v2 = tonumeral(rhs.val) orelse return null;
        if (!validFoldOp(op, v1, v2)) return null;
        const res = rawArith(op, v1, v2) orelse return null;
        return switch (res) {
            .int => |i| .{ .val = .{ .k_int = i } },
            // PUC: folds neither NaN nor 0.0 (to avoid problems with -0.0).
            .float => |f| if (std.math.isNan(f) or f == 0.0)
                null else .{ .val = .{ .k_float = f } },
        };
    }

    /// PUC unary folding, invoked from `luaK_prefix` (lcode.c:1701) via
    /// `constfolding(fs, opr + LUA_OPUNM, e, &ef)` with a fake zero operand.
    ///   - OPR_MINUS (UNM): 0 - v  (wrapping for int, negate for float)
    ///   - OPR_BNOT:         ~v     (bitwise not of the integer value)
    /// The same NaN/0.0 float guard as `foldBinOp` applies to UNM.
    fn foldUnOp(op: TokenKind, operand: ExpDesc) ?ExpDesc {
        const v = tonumeral(operand.val) orelse return null;
        return switch (op) {
            .Minus => switch (v) {
                .int => |i| .{ .val = .{ .k_int = 0 -% i } }, // intArith UNM = intop(-,0,v)
                .float => |f| blk: {
                    const r = -f; // numArith UNM = luai_numunm
                    if (std.math.isNan(r) or r == 0.0) break :blk null;
                    break :blk .{ .val = .{ .k_float = r } };
                },
            },
            .Tilde => blk: {
                // BNOT: bitwise, so the operand must convert to integer.
                const i = numValToInt(v) orelse break :blk null;
                break :blk .{ .val = .{ .k_int = ~i } }; // intArith BNOT = intop(^, ~0, v)
            },
            else => null,
        };
    }

    /// Walk the enclosing-function chain to find the compile-time constant
    /// value of `name` WITHOUT registering an upvalue. This mirrors PUC's
    /// `singlevaraux`, which — upon finding a VCONST in an outer function —
    /// returns early and leaves the expdesc as VCONST (no upvalue is created;
    /// `const2val` indexes the shared actvar array directly).
    ///
    /// Used by the pure constant evaluator `genConstExpDesc` so that a const
    /// declared in an outer function can be folded even before any runtime
    /// reference has forced upvalue registration.
    fn findConstUpvalueValue(self: *Codegen, name: []const u8) ?ExpDesc.Val {
        var current = self.outer;
        while (current) |cg| {
            if (cg.lookupLocalBinding(name)) |binding| {
                // Respect a global-declaration shadow in that function.
                if (cg.latestDeclaredGlobalDepthSelf(name)) |gd| {
                    if (gd > binding.depth) return null;
                }
                return cg.const_local_values.get(binding.reg);
            }
            if (cg.upvalues.get(name)) |idx| {
                return cg.const_upvalue_values.get(idx);
            }
            current = cg.outer;
        }
        return null;
    }

    /// Look up the compile-time constant value of a name visible in the
    /// current function: a `<const>` local, a registered const upvalue, or a
    /// const in an enclosing scope. Returns null if the name is not a
    /// compile-time constant. Pure — emits no code, allocates no registers.
    fn constValueOfName(self: *Codegen, name: []const u8) ?ExpDesc {
        if (self.lookupLocalBinding(name)) |binding| {
            if (self.latestDeclaredGlobalDepthSelf(name)) |gd| {
                if (gd > binding.depth) return null; // shadowed by a global
            }
            if (self.const_local_values.get(binding.reg)) |v| return .{ .val = v };
            return null;
        }
        if (self.upvalues.get(name)) |idx| {
            if (self.const_upvalue_values.get(idx)) |v| return .{ .val = v };
            return null;
        }
        if (self.findConstUpvalueValue(name)) |v| return .{ .val = v };
        return null;
    }

    /// Evaluate an expression as a compile-time constant ExpDesc WITHOUT
    /// emitting any code or allocating any register. Returns null if the
    /// expression is not a compile-time constant.
    ///
    /// This is the compile-time counterpart to how PUC's single-pass parser
    /// builds expdescs: literals and `<const>` variables become constant
    /// kinds (VKINT/VKFLT/VKSTR/VNIL/VTRUE/VFALSE/VCONST) with no code, and
    /// `constfolding` combines foldable operands. By the time the codegen
    /// equivalent of `luaK_posfix`/`luaK_prefix` runs, foldable subexpressions
    /// are already pure constants.
    ///
    /// Only arithmetic and bitwise operators are folded (PUC `foldbinop`);
    /// comparisons, concat, and `and`/`or` are left to the runtime path.
    fn genConstExpDesc(self: *Codegen, e: *const ast.Exp) ?ExpDesc {
        switch (e.node) {
            .Nil => return .{ .val = .nil },
            .True => return .{ .val = .true },
            .False => return .{ .val = .false },
            .Integer => {
                const lexeme = e.span.slice(self.source);
                const parsed = parseIntegerLiteral(lexeme) orelse return null;
                return .{ .val = .{ .k_int = parsed } };
            },
            .Number => {
                const lexeme = e.span.slice(self.source);
                const val = std.fmt.parseFloat(f64, lexeme) catch return null;
                return .{ .val = .{ .k_float = val } };
            },
            .String => {
                const lexeme = e.span.slice(self.source);
                // Decode failures (only possible on OOM for escape strings)
                // are treated as "not a compile-time constant"; the normal
                // emission path handles the error properly later.
                const decoded = self.decodeStringLexeme(lexeme) catch return null;
                return .{ .val = .{ .k_str = decoded } };
            },
            .Name => |n| return self.constValueOfName(n.slice(self.source)),
            .Paren => |inner| return self.genConstExpDesc(inner),
            .BinOp => |n| {
                if (!isFoldBinOp(n.op)) return null;
                const lhs = self.genConstExpDesc(n.lhs) orelse return null;
                const rhs = self.genConstExpDesc(n.rhs) orelse return null;
                return foldBinOp(n.op, lhs, rhs);
            },
            .UnOp => |n| {
                // PUC Lua `luaK_prefix` folds `not` on a constant operand:
                // only nil and false are falsy, so `not nil`/`not false` →
                // true; `not true`/`not <number>`/`not <string>` → false.
                // This enables `not not X` → LOADFALSE/LOADTRUE when X is a
                // compile-time constant, instead of runtime NOT + NOT.
                if (n.op == .Not) {
                    const operand = self.genConstExpDesc(n.exp) orelse return null;
                    return switch (operand.val) {
                        .nil => .{ .val = .true },
                        .false => .{ .val = .true },
                        .true => .{ .val = .false },
                        .k_int, .k_float, .k_str => .{ .val = .false },
                        else => null,
                    };
                }
                if (n.op != .Minus and n.op != .Tilde) return null;
                const operand = self.genConstExpDesc(n.exp) orelse return null;
                return foldUnOp(n.op, operand);
            },
            else => return null,
        }
    }

    fn genBinOp(self: *Codegen, n: anytype, line: u32, dst_hint: ?u8) Error!u8 {
        // PUC Lua's infix handling: discharge the left expression when the
        // infix operator is seen, so instructions materializing that operand
        // carry the operator's line. This matters for line hooks when a
        // binary expression spans large source gaps (db.lua checks this).
        //
        // P15.32 expdesc migration: genExpDesc returns an ExpDesc that defers
        // register materialization. For locals, exp2anyreg returns the local's
        // register directly — no MOVE. For constants, it allocates a temp only
        // when a register is actually needed. This eliminates the redundant
        // MOVE/LOADK that the old genExp path always emitted.
        //
        // P15.38c: `dst_hint` enables direct-store to a local register.
        // When non-null, the arithmetic/bitwise result is written directly
        // to the hint register, avoiding a trailing MOVE. PUC achieves this
        // via `luaK_storevar` VLOCAL → `exp2reg(fs, ex, var->u.var.ridx)`,
        // which patches a relocatable instruction's A field. We pass the
        // target register as hint and use it instead of allocReg().
        var lhs_start_pc: usize = @intCast(self.builder.pc());
        var lhs_ed = try self.genExpDesc(n.lhs);

        // --- PUC constfolding (lcode.c:1418, via luaK_posfix lcode.c:1790) ---
        // If both operands are compile-time numeric constants, compute the
        // result now and discharge it — no runtime ADD/SUB/... instruction.
        // lhs_ed already holds the (possibly constant) left operand; the
        // right operand is evaluated purely via genConstExpDesc, which emits
        // no code, so a non-foldable RHS leaves register state untouched.
        if (self.genConstExpDesc(n.rhs)) |rhs_c| {
            if (foldBinOp(n.op, lhs_ed, rhs_c)) |folded| {
                var ed = folded;
                const saved_hint = self.line_hint;
                self.line_hint = line;
                const reg = if (dst_hint) |h| blk: {
                    // Direct-store to the assignment target (P15.38c).
                    try self.discharge2reg(&ed, h);
                    break :blk h;
                } else try self.exp2nextreg(&ed);
                self.line_hint = saved_hint;
                return reg;
            }
        }

        // --- K/I-variant optimization (PUC Lua 5.5 style) ---
        // Check if RHS is a numeric constant before materializing it. If so,
        // we can use ADDI/ADDK/SUBK/etc. instead of LOADK + ADD. This
        // eliminates one instruction per binary op with a constant operand
        // — the most common pattern in tight loops (`s = s + 1`, `x = x * 2`).
        var rhs_const = self.numericConstFromExp(n.rhs);

        // PUC codecommutative: for commutative ops (ADD/MUL/BAND/BOR/BXOR),
        // if LHS is a numeric constant and RHS is not, swap so the constant
        // is on the RHS — enabling ADDI/ADDK/MULK/etc fusion.
        var flip = false;
        var actual_rhs: *const ast.Exp = n.rhs;
        if (rhs_const == null) {
            const is_commutative = switch (n.op) {
                .Plus, .Star, .Amp, .Pipe, .Tilde => true,
                else => false,
            };
            if (is_commutative) {
                const lhs_nc = self.numericConstFromExp(n.lhs);
                if (lhs_nc) |lc| {
                    rhs_const = lc;
                    flip = true;
                    actual_rhs = n.lhs;
                    // Regenerate lhs_ed from n.rhs (the actual register operand).
                    lhs_ed = try self.genExpDesc(n.rhs);
                    // CRITICAL: reset lhs_start_pc after swap so the line
                    // fixup below only covers post-swap LHS discharge
                    // instructions, NOT the RHS subexpression instructions
                    // that carry their own meaningful line info.
                    lhs_start_pc = @intCast(self.builder.pc());
                }
            }
        }

        // --- SHLI: K << R (constant LHS, register RHS) ---
        // PUC codebitwise (lcode.c:1827): when op is `<<` and LHS is a small
        // integer constant, swap operands and emit SHLI (R[A] = sC << R[B]).
        // This is the shift analogue of the I-variant path: the constant
        // lives in the immediate field (sC), the register operand is the
        // shift amount. SHL is NOT commutative, so this cannot go through
        // the commutative swap above — the operand order is structurally
        // different (immediate on the LEFT, register on the RIGHT).
        // Only applies when RHS is NOT a constant (rhs_const == null);
        // otherwise the K/I-variant path below handles `x << k` via SHRI-like
        // fallback (PUC has no SHL-with-immediate-RHS, so it uses SHL reg,reg).
        if (n.op == .Shl and rhs_const == null) {
            const lhs_nc = self.numericConstFromExp(n.lhs);
            if (lhs_nc) |lc| {
                if (lc.kid == null) {
                    // K fits sC → emit SHLI directly.
                    // The "lhs" of SHLI (R[B]) is the RHS expression (shift amount).
                    lhs_ed = try self.genExpDesc(n.rhs);
                    lhs_start_pc = @intCast(self.builder.pc());
                    const lhs_reg = try self.exp2anyreg(&lhs_ed);
                    const lhs_end_pc: usize = @intCast(self.builder.pc());
                    for (self.builder.lineinfo.items[lhs_start_pc..lhs_end_pc]) |*il| il.* = line;
                    self.freeReg(lhs_reg);
                    const dst = if (dst_hint) |h| h else try self.allocReg();
                    // SHLI carries k=1 (flip): the constant is on the LEFT,
                    // so metamethod operands are (constant, register) = (LHS, RHS).
                    // This matches PUC's GETARG_k on SHLI for commutative swap.
                    _ = try self.builder.emitABCk(.shli, dst, lhs_reg, int2sC(lc.ival), true, line);
                    // MMBINI carries the plain TMS event in C (no 0x80 hack).
                    // The flip flag is now in the preceding SHLI's k-bit.
                    _ = try self.builder.emitABCk(.mmbini, lhs_reg, int2sC(lc.ival), TMS_SHL, true, line);
                    return dst;
                }
            }
        }

        // --- SHRI for x << K (PUC finishbinexpneg, lcode.c:1832) ---
        // PUC transforms `x << K` into `x >> (-K)` emitting SHRI, because
        // there is no SHL-with-immediate-RHS opcode. Both K and -K must
        // fit sC (range -127..128, so K must be in -128..127). The SHRI
        // opcode computes shiftRight(R[B], sC) = R[B] >> sC; with sC = -K
        // this becomes R[B] >> (-K) = R[B] << K — mathematically equivalent.
        //
        // The metamethod event stays TM_SHL (the original operator), and
        // MMBINI's B field carries the ORIGINAL K (not -K) so __shl
        // receives the correct operand. flip=0: register is on the LEFT.
        // This mirrors PUC's finishbinexpneg which patches SETARG_B to
        // int2sC(v2) after finishbinexpval emits with int2sC(-v2).
        if (n.op == .Shl and rhs_const != null) {
            const nc = rhs_const.?;
            if (nc.kid == null and fitsSC(nc.ival) and fitsSC(-nc.ival)) {
                const lhs_reg = try self.exp2anyreg(&lhs_ed);
                const lhs_end_pc: usize = @intCast(self.builder.pc());
                for (self.builder.lineinfo.items[lhs_start_pc..lhs_end_pc]) |*il| il.* = line;
                self.freeReg(lhs_reg);
                const dst = if (dst_hint) |h| h else try self.allocReg();
                const negated = -nc.ival;
                // SHRI: R[A] = R[B] >> sC(-K)  [=  R[B] << K]
                _ = try self.builder.emitABCk(.shri, dst, lhs_reg, int2sC(negated), false, line);
                // MMBINI: B = sC(original K), C = TM_SHL, k=0 (no flip)
                _ = try self.builder.emitABCk(.mmbini, lhs_reg, int2sC(nc.ival), TMS_SHL, false, line);
                return dst;
            }
        }

        // --- Arithmetic / bitwise: try K/I-variant first, then reg/reg ---
        if (binOpToBc(n.op)) |op| {
            // Discharge LHS to a register (PUC's luaK_infix).
            // For locals: returns the local's register directly (no MOVE).
            // For constants/upvalues: allocates a temp and emits LOADK/GETUPVAL.
            const lhs_reg = try self.exp2anyreg(&lhs_ed);
            // Fix up lines for all LHS instructions (genExpDesc fallback +
            // exp2anyreg discharge) to the operator's line.
            const lhs_end_pc: usize = @intCast(self.builder.pc());
            for (self.builder.lineinfo.items[lhs_start_pc..lhs_end_pc]) |*inst_line| {
                inst_line.* = line;
            }

            // Try K/I-variant: R[dst] = R[lhs] <op> K/I
            if (rhs_const) |nc| {
                if (try self.tryEmitConstBinOp(n.op, lhs_reg, nc, line, dst_hint, flip)) |dst| {
                    // PUC 5.5: emit MMBINI (for I-variants) or MMBINK (for K-variants).
                    // The B field carries the same operand encoding as the arithmetic
                    // opcode's C field: int2sC(ival) for I-variants, K index for K-variants.
                    // The C field carries the TMS event number for metamethod dispatch.
                    // luazig's VM treats these as no-ops (metamethods are handled inline).
                    // Determine MMBIN variant from the LAST EMITTED instruction's
                    // opcode, NOT from the original NumConst. tryEmitConstBinOp may
                    // intern a small integer constant (e.g. `x * -127`) producing a
                    // K-variant (MULK) even though the original NumConst had kid==null.
                    // Using the original nc.kid here would wrongly emit MMBINI.
                    // I-variants (ADDI/SHLI/SHRI) → MMBINI; K-variants → MMBINK.
                    if (tokenToTms(n.op)) |event| {
                        const last_inst: bc.Instruction =
                            self.builder.code.items[self.builder.code.items.len - 1];
                        const last_op: bc.Op = @enumFromInt(last_inst.op);
                        const is_ivariant = switch (last_op) {
                            .addi, .shli, .shri => true,
                            else => false,
                        };
                        // PUC 5.5: MMBINI/MMBINK carry the plain TMS event in C
                        // (no 0x80 hack). The flip flag is in the preceding
                        // arith opcode's k-bit, which the VM reads directly.
                        if (is_ivariant) {
                            // I-variant: B = sC-encoded immediate (same as opcode's C).
                            _ = try self.builder.emitABCk(.mmbini, lhs_reg, last_inst.c, event, flip, line);
                        } else {
                            // K-variant: B = constant pool index (same as opcode's C).
                            _ = try self.builder.emitABCk(.mmbink, lhs_reg, last_inst.c, event, flip, line);
                        }
                    }
                    return dst;
                }
                // K/I-variant didn't apply (constant pool index > 255 or
                // value doesn't fit sC). Fall through to register path.
            }

            // Standard register/register path.
            // Set line_hint to RHS expression's line so RHS discharge
            // instructions carry the correct line (not the statement's line).
            const saved_hint = self.line_hint;
            self.line_hint = actual_rhs.span.line;
            var rhs_ed = try self.genExpDesc(actual_rhs);
            const rhs_reg = try self.exp2anyreg(&rhs_ed);
            self.line_hint = saved_hint;
            self.freeExps(&lhs_ed, &rhs_ed);
            // P15.38c: direct-store to local register when hint is provided.
            // The hint register is the LHS local (e.g. `s` in `s = s + i`),
            // so the result is written directly to it — no trailing MOVE.
            // This mirrors PUC's `exp2reg` patching a relocatable instruction,
            // but applied at codegen time via the destination hint.
            const dst = if (dst_hint) |hint| hint else try self.allocReg();
            // PUC 5.5: the arith opcode carries k=flip for commutative swap.
            // The VM reads inst.k to determine metamethod operand order.
            _ = try self.builder.emitABCk(op, dst, lhs_reg, rhs_reg, flip, line);
            // PUC 5.5: emit MMBIN after each arithmetic/bitwise opcode.
            // The C field carries the TMS event number for metamethod dispatch.
            // luazig's VM treats MMBIN as a no-op (metamethods are handled inline).
            if (tokenToTms(n.op)) |event| {
                _ = try self.builder.emitABC(.mmbin, lhs_reg, rhs_reg, event, line);
            }
            return dst;
        }

        // --- Comparison: produce a boolean value ---
        if (n.op == .EqEq or n.op == .NotEq or n.op == .Lt or
            n.op == .Lte or n.op == .Gt or n.op == .Gte)
        {
            // P15.38d: Check if RHS is a numeric constant usable for an
            // immediate (EQI/LTI/LEI/GTI/GEI) or constant (EQK) opcode.
            // If so, skip materializing RHS — the comparison opcode embeds
            // the value directly, eliminating a preceding LOADI/LOADK.
            //
            // PUC codeeq/codeorder: if LHS is a constant and RHS is not,
            // swap operands so the constant lands on the RHS (enabling the
            // immediate/constant variant). For order ops, the comparison
            // direction must be inverted: K < a → a > K, K <= a → a >= K,
            // K > a → a < K, K >= a → a <= K. == and ~= are symmetric.
            var rhs_nc_for_cmp = self.cmpConstFromExp(n.op, n.rhs);
            var cmp_op = n.op;
            // When LHS is the constant and RHS is not, we swap: the
            // register operand becomes n.rhs, and the constant (from
            // n.lhs) is passed as rhs_nc_for_cmp. lhs_ed (generated from
            // n.lhs at the top of genBinOp) holds an unmaterialized
            // constant ExpDesc in this case, so we generate a fresh
            // ExpDesc from n.rhs for the register operand.
            var lhs_exp: *const ast.Exp = n.lhs;
            var rhs_exp: *const ast.Exp = n.rhs;
            if (rhs_nc_for_cmp == null) {
                const lhs_nc = self.cmpConstFromExp(n.op, n.lhs);
                if (lhs_nc != null) {
                    lhs_exp = n.rhs;
                    rhs_exp = n.lhs;
                    // Transform comparison direction for order ops.
                    // == and ~= are symmetric — no direction change needed.
                    cmp_op = switch (n.op) {
                        .Lt => .Gt,
                        .Lte => .Gte,
                        .Gt => .Lt,
                        .Gte => .Lte,
                        else => n.op,
                    };
                    rhs_nc_for_cmp = lhs_nc;
                }
            }
            const use_imm = rhs_nc_for_cmp != null and
                rhsConstUsableForCmp(cmp_op, rhs_nc_for_cmp.?);
            // Normalize integer-valued floats (e.g. -4.0) to I-variant form
            // so genComparison routes to EQI instead of EQK.
            if (rhs_nc_for_cmp) |nc| {
                rhs_nc_for_cmp = normalizeCmpConst(nc);
            }

            // Discharge the register operand (PUC order: infix discharges
            // LHS, then posfix compiles RHS). When swapped, lhs_exp is
            // n.rhs, so we generate a fresh ExpDesc from it. Otherwise,
            // lhs_ed (from n.lhs, generated at top of genBinOp) is reused.
            const lhs_reg = if (lhs_exp == n.rhs) blk: {
                var swapped_ed = try self.genExpDesc(lhs_exp);
                break :blk try self.exp2anyreg(&swapped_ed);
            } else try self.exp2anyreg(&lhs_ed);
            const lhs_end_pc: usize = @intCast(self.builder.pc());
            for (self.builder.lineinfo.items[lhs_start_pc..lhs_end_pc]) |*inst_line| {
                inst_line.* = line;
            }

            if (use_imm) {
                // RHS is embedded in the comparison opcode — no register needed.
                return self.genComparison(cmp_op, lhs_reg, 0, line, rhs_nc_for_cmp);
            }

            // Standard path: materialize RHS to a register.
            const saved_hint = self.line_hint;
            self.line_hint = rhs_exp.span.line;
            var rhs_ed = try self.genExpDesc(rhs_exp);
            const rhs_reg = try self.exp2anyreg(&rhs_ed);
            self.line_hint = saved_hint;
            return self.genComparison(cmp_op, lhs_reg, rhs_reg, line, null);
        }

        // --- Concat: R[A] = R[A]..R[A+B-1] ---
        // Both operands must be in contiguous registers. exp2nextreg
        // allocates consecutive temps and discharges into them.
        if (n.op == .Concat) {
            const lhs_reg = try self.exp2nextreg(&lhs_ed);
            const lhs_end_pc: usize = @intCast(self.builder.pc());
            for (self.builder.lineinfo.items[lhs_start_pc..lhs_end_pc]) |*inst_line| {
                inst_line.* = line;
            }
            const saved_hint = self.line_hint;
            self.line_hint = n.rhs.span.line;
            var rhs_ed = try self.genExpDesc(n.rhs);
            const rhs_reg = try self.exp2nextreg(&rhs_ed);
            self.line_hint = saved_hint;
            // PUC codeconcat merge: `..` is right-associative, so
            // `a..b..c..d` parses as `a..(b..(c..d))`. The inner concat
            // is emitted first; when the outer concat sees that e2's
            // previous instruction is CONCAT and e1's register is exactly
            // one below the CONCAT's A (contiguous range), it extends the
            // existing CONCAT: moves A down to e1's register and increments
            // B. This folds 3 CONCATs into 1 with B=4.
            // (Mirrors lcode.c:1767 codeconcat exactly.)
            if (self.builder.code.items.len > 0) {
                const prev_idx = self.builder.code.items.len - 1;
                const prev_inst = self.builder.code.items[prev_idx];
                const prev_op: bc.Op = @enumFromInt(prev_inst.op);
                if (prev_op == .concat and lhs_reg + 1 == prev_inst.a) {
                    self.builder.code.items[prev_idx].a = lhs_reg;
                    self.builder.code.items[prev_idx].b += 1;
                    self.freeReg(rhs_reg);
                    return lhs_reg;
                }
            }
            _ = try self.builder.emitABC(.concat, lhs_reg, 2, 0, line);
            self.freeReg(rhs_reg);
            return lhs_reg;
        }

        self.setDiag(.{ .start = 0, .end = 0, .line = line, .col = 0 }, "unsupported binary operator");
        return error.CodegenError;
    }

    /// Try to emit a K-variant or I-variant opcode for a binary operation
    /// where the RHS is a numeric constant. Returns the destination register
    /// on success, or null if the constant doesn't fit any K/I encoding
    /// (caller should fall back to LOADK + register/register op).
    ///
    /// This mirrors PUC Lua 5.5's `codearith`/`codecommutative`/`codebitwise`:
    ///
    /// - ADDI: R[A] = R[B] + sC  (only for ADD with small integer)
    /// - ADDK/SUBK/MULK/MODK/POWK/DIVK/IDIVK: R[A] = R[B] <op> K[C]
    /// - BANDK/BORK/BXORK: R[A] = R[B] <op> K[C]:integer
    /// - SHLI: R[A] = sC << R[B]  (only when LHS is small integer — not handled here)
    /// - SHRI: R[A] = R[B] >> sC  (only for SHR with small integer RHS)
    ///
    /// SUB with a small integer RHS is coded as ADDI(r, -i), matching PUC's
    /// `finishbinexpneg`. The metamethod argument (B field) keeps the original
    /// value so __sub receives the correct operand.
    ///
    /// IMPORTANT: This function must NOT modify register state (freereg,
    /// peak_freereg) if it returns null. The caller needs the register
    /// allocator state to be unchanged so it can fall back to the
    /// register/register path.
    fn tryEmitConstBinOp(self: *Codegen, op: TokenKind, lhs_reg: u8, nc: NumConst, line: u32, dst_hint: ?u8, flip: bool) Error!?u8 {
        // First, determine which opcode to emit (if any) WITHOUT modifying
        // register state. This ensures clean fallback on failure.
        const emit_info = constBinOpInfo(op, nc) orelse {
            // For bitwise operations and SUB with small integers (no K index
            // yet), intern the constant and try again.
            if (nc.kid == null and (op == .Amp or op == .Pipe or op == .Tilde or
                op == .Minus or op == .Star or op == .Percent or op == .Slash or
                op == .Caret or op == .Idiv))
            {
                const kid = try self.builder.internConst(.{ .int = nc.ival });
                var nc2 = nc;
                nc2.kid = kid;
                return self.tryEmitConstBinOp(op, lhs_reg, nc2, line, dst_hint, flip);
            }
            return null;
        };

        // Now we know the operation will succeed. Free the LHS register
        // and allocate the destination (like PUC's freeexp + exp2nextreg).
        // P15.38c: when dst_hint is provided (direct-store to local),
        // write the result directly to the hint register — no MOVE.
        self.freeReg(lhs_reg);
        const dst = if (dst_hint) |hint| hint else try self.allocReg();
        // PUC 5.5: the arith opcode carries k=flip for commutative swap.
        // The VM reads inst.k to determine metamethod operand order.
        _ = try self.builder.emitABCk(emit_info.opcode, dst, lhs_reg, emit_info.c_field, flip, line);
        return dst;
    }

    /// Determine the opcode and C field for a constant-operand binary operation.
    /// Returns null if the constant doesn't fit any K/I encoding.
    const ConstBinOpInfo = struct {
        opcode: bc.Op,
        c_field: u8,
    };

    fn constBinOpInfo(op: TokenKind, nc: NumConst) ?ConstBinOpInfo {
        switch (op) {
            // --- ADD: try ADDI (small int) or ADDK (constant) ---
            .Plus => {
                if (nc.kid == null) {
                    // Small integer: use ADDI.
                    // PUC only uses ADDI for integer constants, not floats.
                    return .{ .opcode = .addi, .c_field = int2sC(nc.ival) };
                }
                if (nc.kid.? <= 255) {
                    return .{ .opcode = .addk, .c_field = @intCast(nc.kid.?) };
                }
                return null;
            },

            // --- SUB: try SUBK (ADDI-for-SUB optimization deferred) ---
            .Minus => {
                // PUC codes `a - <small_int>` as `ADDI(a, -i)` with a
                // separate MMBINI instruction carrying the __sub event
                // (B field patched to the original value via SETARG_B).
                // MMBINI now exists in luazig, but the ADDI-for-SUB
                // optimization (encoding SUB as ADD + negated immediate)
                // is deferred — it requires careful B-field patching to
                // keep the original operand for __sub. Until then, use
                // SUBK which correctly triggers __sub.
                // For small integers, the caller (tryEmitConstBinOp) will
                // intern the constant and retry.
                if (nc.kid == null) return null; // caller will intern
                if (nc.kid.? <= 255) {
                    return .{ .opcode = .subk, .c_field = @intCast(nc.kid.?) };
                }
                return null;
            },

            // --- MUL: try MULK ---
            .Star => {
                if (nc.kid == null) {
                    // Small integer without a K index. PUC doesn't have MULI,
                    // so for small integers we'd need LOADK. Fall back.
                    return null;
                }
                if (nc.kid.? <= 255) {
                    return .{ .opcode = .mulk, .c_field = @intCast(nc.kid.?) };
                }
                return null;
            },

            // --- DIV: try DIVK ---
            .Slash => {
                if (nc.kid == null) return null;
                if (nc.kid.? <= 255) {
                    return .{ .opcode = .divk, .c_field = @intCast(nc.kid.?) };
                }
                return null;
            },

            // --- MOD: try MODK ---
            .Percent => {
                if (nc.kid == null) return null;
                if (nc.kid.? <= 255) {
                    return .{ .opcode = .modk, .c_field = @intCast(nc.kid.?) };
                }
                return null;
            },

            // --- POW: try POWK ---
            .Caret => {
                if (nc.kid == null) return null;
                if (nc.kid.? <= 255) {
                    return .{ .opcode = .powk, .c_field = @intCast(nc.kid.?) };
                }
                return null;
            },

            // --- IDIV: try IDIVK ---
            .Idiv => {
                if (nc.kid == null) return null;
                if (nc.kid.? <= 255) {
                    return .{ .opcode = .idivk, .c_field = @intCast(nc.kid.?) };
                }
                return null;
            },

            // --- Bitwise: BANDK/BORK/BXORK (integer constants only) ---
            // PUC's codebitwise always uses K-variant (no BANDI).
            // For small integers without a K index, we intern them first.
            .Amp, .Pipe, .Tilde => {
                // These need the constant pool index. If nc.kid is null
                // (small integer), we need to intern it. But interning
                // can fail (OOM), so we can't do it in this pure function.
                // Return null for small ints — the caller's fallback will
                // LOADK + register op, which is correct but slower.
                // TODO: handle small-int bitwise by interning in tryEmitConstBinOp.
                if (nc.kid == null) return null;
                if (nc.kid.? > 255) return null;
                const opcode: bc.Op = switch (op) {
                    .Amp => .bandk,
                    .Pipe => .bork,
                    .Tilde => .bxork,
                    else => unreachable,
                };
                return .{ .opcode = opcode, .c_field = @intCast(nc.kid.?) };
            },

            // --- Shifts: SHRI (small int RHS) ---
            .Shr => {
                if (nc.kid == null) {
                    // Small integer: use SHRI.
                    return .{ .opcode = .shri, .c_field = int2sC(nc.ival) };
                }
                // Non-small constant: fall back to register path.
                return null;
            },
            .Shl => {
                // SHL with small int RHS: PUC doesn't have SHL-with-immediate.
                // SHLI is for when the LHS is a small integer (I << r).
                // Since we only check RHS here, fall back to register path.
                return null;
            },

            else => return null,
        }
    }

    /// Compile a comparison into a boolean value in a fresh register.
    /// Uses the EQ/LT/LE + JMP + LOADTRUE/LOADFALSE pattern.
    fn genComparison(self: *Codegen, op: TokenKind, lhs: u8, rhs: u8, line: u32, rhs_const: ?NumConst) Error!u8 {
        // Delegate to genComparisonExp (which returns a VJMP ExpDesc),
        // then materialize the boolean into a register. This keeps the
        // value-context callers (e.g. `local x = a < b`) on the same
        // 5-instruction pattern as before, while letting condition-context
        // callers (genIf/genWhile via genExpCond) use the 2-instruction VJMP.
        var ed = try self.genComparisonExp(op, lhs, rhs, line, rhs_const);
        return try self.exp2anyreg(&ed);
    }

    /// Compile a comparison into a VJMP ExpDesc — the PUC Lua pattern
    /// (lcode.c:1634-1691 codeorder/codeeq). Emits only `CMP + JMP`
    /// (2 instructions) and returns an ExpDesc whose `.val` is `.jump`
    /// and whose `f_list` points at the JMP. The CMP skips the JMP when
    /// the condition is TRUE (fall-through = true); the JMP is reached
    /// only when FALSE, so it goes on the false-list.
    ///
    /// `genComparison` (above) wraps this for value-context callers by
    /// materializing the VJMP into a boolean register. Condition-context
    /// callers (genIf/genWhile via genExpCond) consume the VJMP directly
    /// via goIfFalse/goIfTrue, avoiding the materialization entirely.
    ///
    /// P15.38d: When `rhs_const` is non-null, emits an immediate variant
    /// (EQI/LTI/LEI/GTI/GEI) or constant variant (EQK) instead of the
    /// register/register CMP, eliminating a preceding LOADI/LOADK.
    /// The caller must ensure `rhs_const` is usable for `op` (checked via
    /// `rhsConstUsableForCmp`); when non-null, `rhs` is ignored.
    fn genComparisonExp(self: *Codegen, op: TokenKind, lhs: u8, rhs: u8, line: u32, rhs_const: ?NumConst) Error!ExpDesc {
        // Determine the comparison opcode, operand order, and B field.
        // For > and >= with register operands, swap operands and use lt/le.
        // For immediate variants, use gti/gei directly (no swap needed).
        var bc_op: bc.Op = undefined;
        var op_lhs = lhs;
        var op_rhs = rhs;
        // When rhs_const is usable, B field carries the immediate (sB) or
        // constant pool index (K[B]) instead of a register number.
        var b_imm: ?u8 = null; // set when using EQI/LTI/LEI/GTI/GEI
        var b_k: ?u8 = null; // set when using EQK

        switch (op) {
            .EqEq, .NotEq => {
                if (rhs_const) |nc| {
                    if (nc.kid == null) {
                        // Small integer immediate: use EQI.
                        bc_op = .eqi;
                        b_imm = int2sC(nc.ival);
                    } else {
                        // Constant pool entry: use EQK (kid ≤ 255 guaranteed
                        // by rhsConstUsableForCmp).
                        bc_op = .eqk;
                        b_k = @intCast(nc.kid.?);
                    }
                } else {
                    bc_op = .eq;
                }
            },
            .Lt => {
                if (rhs_const) |nc| {
                    // rhsConstUsableForCmp guarantees kid == null for order ops.
                    bc_op = .lti;
                    b_imm = int2sC(nc.ival);
                } else {
                    bc_op = .lt;
                }
            },
            .Lte => {
                if (rhs_const) |nc| {
                    bc_op = .lei;
                    b_imm = int2sC(nc.ival);
                } else {
                    bc_op = .le;
                }
            },
            .Gt => {
                if (rhs_const) |nc| {
                    // R[A] > sB directly (no operand swap needed for immediate).
                    bc_op = .gti;
                    b_imm = int2sC(nc.ival);
                } else {
                    // Register path: swap operands, use lt (R[rhs] < R[lhs]).
                    bc_op = .lt;
                    op_lhs = rhs;
                    op_rhs = lhs;
                }
            },
            .Gte => {
                if (rhs_const) |nc| {
                    bc_op = .gei;
                    b_imm = int2sC(nc.ival);
                } else {
                    bc_op = .le;
                    op_lhs = rhs;
                    op_rhs = lhs;
                }
            },
            else => unreachable,
        }

        // C field encoding: PUC uses C=isfloat and k=invert as separate
        // fields. Our instruction format has no k bit, so we encode both
        // in the C field: bit 0 = invert, bit 1 = isfloat.
        //   invert=1 for ==/</<=/>/>= (JMP fires when true), 0 for ~=.
        //   isfloat=1 when the immediate originated from a float literal
        //   (e.g. 5.0), so the metamethod receives a float value, not int.
        //   Only set for I-variants (EQI/LTI/LEI/GTI/GEI); EQK/EQ/LT/LE
        //   always have isfloat=0 (PUC codeeq: "not needed here").
        const invert: u8 = if (op == .NotEq) 0 else 1;
        const isfloat: u8 = if (b_imm != null and rhs_const != null and
            rhs_const.?.is_float) 1 else 0;
        const c_field: u8 = invert | (isfloat << 1);

        // Free operands before emitting — the comparison does not hold them.
        // When using immediate/constant variant, RHS was never materialized
        // (no register to free).
        if (b_imm != null or b_k != null) {
            self.freeReg(lhs);
        } else {
            self.freeReg2(rhs, lhs);
        }

        // CMP + JMP: the conditional-skip + jump pattern (PUC `condjump`).
        const b_field: u8 = if (b_imm) |imm| imm else if (b_k) |kid| kid else op_rhs;
        _ = try self.builder.emitABC(bc_op, op_lhs, b_field, c_field, line);
        const jmp_pc = try self.emitJump(line);

        // Build the VJMP ExpDesc. Following PUC, both jump lists start
        // empty — goIfTrue/goIfFalse will populate the appropriate list
        // (f_list for goIfTrue, t_list for goIfFalse). Pre-populating
        // f_list here would cause a double-listing bug when goIfFalse
        // negates the CMP: the JMP would be on BOTH lists and get patched
        // to two different targets.
        var ed = ExpDesc{};
        ed.val = .{ .jump = .{ .info = @intCast(jmp_pc) } };
        return ed;
    }

    /// Check whether a numeric constant can be used as the RHS of a
    /// comparison via an immediate (EQI/LTI/LEI/GTI/GEI) or constant
    /// (EQK) opcode. Mirrors PUC's `isSCnumber` + `exp2RK` checks.
    ///
    /// PUC's `isSCnumber` accepts integer-valued floats (e.g. -4.0, 128.0)
    /// as small integers for EQI/LTI/LEI/GTI/GEI. This matters for code
    /// like `if -4.0 == a` — PUC emits EQI, not LOADF + EQ.
    fn rhsConstUsableForCmp(op: TokenKind, nc: NumConst) bool {
        if (nc.kid == null) return true; // small int: all comparison ops
        if (nc.is_float) {
            // Integer-valued float (e.g. -4.0, 128.0): usable as immediate
            // if the integer value fits sC. Mirrors PUC isSCnumber.
            const as_int: i64 = @intFromFloat(nc.fval);
            if (@as(f64, @floatFromInt(as_int)) != nc.fval) return false;
            return fitsSC(as_int);
        }
        // Non-float constant pool entry (kid <= 255): EQK only for == / ~=.
        if (nc.kid.? <= 255) {
            return op == .EqEq or op == .NotEq;
        }
        return false;
    }

    /// Normalize a NumConst for comparison immediate encoding. When the
    /// constant is an integer-valued float (e.g. -4.0) that fits sC, convert
    /// it to I-variant form (kid=null, ival=integer) so genComparisonExp
    /// routes to EQI/LTI/LEI/GTI/GEI instead of EQK. Mirrors PUC's
    /// isSCnumber → sC encoding in codeeq/codeorder.
    fn normalizeCmpConst(nc: NumConst) NumConst {
        if (nc.kid != null and nc.is_float) {
            const as_int: i64 = @intFromFloat(nc.fval);
            if (@as(f64, @floatFromInt(as_int)) == nc.fval and fitsSC(as_int)) {
                return .{ .ival = as_int, .is_float = true, .fval = nc.fval };
            }
        }
        return nc;
    }

    fn genUnOp(self: *Codegen, n: anytype, line: u32) Error!u8 {
        // PUC constfolding for unary ops (lcode.c:1701, luaK_prefix): for
        // OPR_MINUS/OPR_BNOT, try to fold a compile-time constant operand
        // before emitting a runtime UNM/BNOT. genConstExpDesc is pure (no
        // code emitted), so a non-foldable operand falls through untouched.
        if (n.op == .Minus or n.op == .Tilde) {
            if (self.genConstExpDesc(n.exp)) |operand| {
                if (foldUnOp(n.op, operand)) |folded| {
                    var ed = folded;
                    const saved_hint = self.line_hint;
                    self.line_hint = line;
                    const reg = try self.exp2nextreg(&ed);
                    self.line_hint = saved_hint;
                    return reg;
                }
            }
        }

        const src = try self.genExp(n.exp);
        const op: bc.Op = switch (n.op) {
            .Minus => .unm,
            .Tilde => .bnot,
            .Not => .not,
            .Hash => .len,
            else => {
                self.setDiag(.{ .start = 0, .end = 0, .line = line, .col = 0 }, "unsupported unary operator");
                return error.CodegenError;
            },
        };
        // Free source before allocating result (like PUC).
        self.freeReg(src);
        const dst = try self.allocReg();
        _ = try self.builder.emitABC(op, dst, src, 0, line);
        return dst;
    }

    // -----------------------------------------------------------------------
    // String lexeme decoding (strip quotes, handle escapes)
    // -----------------------------------------------------------------------

    /// Decode a string literal lexeme into its raw bytes.
    /// Handles short strings ("..." or '...') with basic escape sequences,
    /// and long strings ([[...]] or [==[...]==]).
    /// Decode a string literal lexeme into raw bytes.
    /// Handles short strings ("..." or '...') with full escape sequences,
    /// and long strings ([[...]] or [==[...]==]).
    fn decodeStringLexeme(self: *Codegen, raw: []const u8) Error![]const u8 {
        if (raw.len < 2) return raw;
        const q = raw[0];

        // Long string [[...]] or [==[...]==]
        if (q == '[') {
            var eqs: usize = 0;
            var i: usize = 1;
            while (i < raw.len and raw[i] == '=') : (i += 1) eqs += 1;
            if (i < raw.len and raw[i] == '[') {
                const close_len = eqs + 2;
                if (raw.len >= i + 1 + close_len) {
                    const close_start = raw.len - close_len;
                    var content_start = i + 1;
                    // Lua ignores one initial line break and normalizes every
                    // line break inside a long string to a single '\n'.
                    if (content_start < close_start and
                        (raw[content_start] == '\n' or raw[content_start] == '\r'))
                    {
                        const first = raw[content_start];
                        content_start += 1;
                        if (content_start < close_start) {
                            const next = raw[content_start];
                            if ((first == '\n' and next == '\r') or
                                (first == '\r' and next == '\n'))
                            {
                                content_start += 1;
                            }
                        }
                    }
                    const body = raw[content_start..close_start];
                    if (std.mem.indexOfAny(u8, body, "\r\n") == null) return body;

                    var normalized: std.ArrayListUnmanaged(u8) = .empty;
                    var body_index: usize = 0;
                    while (body_index < body.len) {
                        const ch = body[body_index];
                        if (ch == '\n' or ch == '\r') {
                            try normalized.append(self.alloc, '\n');
                            if (body_index + 1 < body.len) {
                                const next = body[body_index + 1];
                                if ((ch == '\n' and next == '\r') or
                                    (ch == '\r' and next == '\n'))
                                {
                                    body_index += 1;
                                }
                            }
                        } else {
                            try normalized.append(self.alloc, ch);
                        }
                        body_index += 1;
                    }
                    return try normalized.toOwnedSlice(self.alloc);
                }
            }
            return raw;
        }

        // Short string "..." or '...'
        if (q == '"' or q == '\'') {
            const inner = raw[1 .. raw.len - 1];
            // Fast path: no backslash, just return the inner slice.
            if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;

            // Slow path: decode escape sequences.
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(self.alloc);
            var pos: usize = 0;
            while (pos < inner.len) {
                const ch = inner[pos];
                if (ch != '\\') {
                    try buf.append(self.alloc, ch);
                    pos += 1;
                    continue;
                }
                pos += 1; // consume backslash
                if (pos >= inner.len) break;
                switch (inner[pos]) {
                    'n' => {
                        try buf.append(self.alloc, '\n');
                        pos += 1;
                    },
                    't' => {
                        try buf.append(self.alloc, '\t');
                        pos += 1;
                    },
                    'r' => {
                        try buf.append(self.alloc, '\r');
                        pos += 1;
                    },
                    '\\' => {
                        try buf.append(self.alloc, '\\');
                        pos += 1;
                    },
                    '"' => {
                        try buf.append(self.alloc, '"');
                        pos += 1;
                    },
                    '\'' => {
                        try buf.append(self.alloc, '\'');
                        pos += 1;
                    },
                    'a' => {
                        try buf.append(self.alloc, 0x07);
                        pos += 1;
                    },
                    'b' => {
                        try buf.append(self.alloc, 0x08);
                        pos += 1;
                    },
                    'f' => {
                        try buf.append(self.alloc, 0x0C);
                        pos += 1;
                    },
                    'v' => {
                        try buf.append(self.alloc, 0x0B);
                        pos += 1;
                    },
                    '0'...'9' => {
                        // Decimal escape \ddd (up to 3 digits)
                        var val: u16 = 0;
                        var count: usize = 0;
                        while (count < 3 and pos < inner.len and inner[pos] >= '0' and inner[pos] <= '9') {
                            val = val * 10 + (inner[pos] - '0');
                            pos += 1;
                            count += 1;
                        }
                        if (val > 255) {
                            self.setDiag(.{ .start = 0, .end = 0, .line = 0, .col = 0 }, "decimal escape too large");
                            return error.CodegenError;
                        }
                        try buf.append(self.alloc, @intCast(val));
                    },
                    'x' => {
                        // Hex escape \xNN
                        pos += 1;
                        if (pos + 1 >= inner.len) {
                            self.setDiag(.{ .start = 0, .end = 0, .line = 0, .col = 0 }, "truncated hex escape");
                            return error.CodegenError;
                        }
                        const h1 = std.fmt.charToDigit(inner[pos], 16) catch {
                            self.setDiag(.{ .start = 0, .end = 0, .line = 0, .col = 0 }, "invalid hex digit");
                            return error.CodegenError;
                        };
                        const h2 = std.fmt.charToDigit(inner[pos + 1], 16) catch {
                            self.setDiag(.{ .start = 0, .end = 0, .line = 0, .col = 0 }, "invalid hex digit");
                            return error.CodegenError;
                        };
                        try buf.append(self.alloc, @intCast(h1 * 16 + h2));
                        pos += 2;
                    },
                    'z' => {
                        // \z skips following whitespace
                        pos += 1;
                        while (pos < inner.len and std.ascii.isWhitespace(inner[pos])) pos += 1;
                    },
                    'u' => {
                        // \u{XXX} — Unicode codepoint as UTF-8
                        pos += 1; // skip 'u'
                        if (pos >= inner.len or inner[pos] != '{') {
                            self.setDiag(.{ .start = 0, .end = 0, .line = 0, .col = 0 }, "missing '{' in \\u escape");
                            return error.CodegenError;
                        }
                        pos += 1; // skip '{'
                        var cp: u32 = 0;
                        while (pos < inner.len and inner[pos] != '}') {
                            const d = std.fmt.charToDigit(inner[pos], 16) catch {
                                self.setDiag(.{ .start = 0, .end = 0, .line = 0, .col = 0 }, "invalid hex digit in \\u escape");
                                return error.CodegenError;
                            };
                            cp = cp * 16 + d;
                            pos += 1;
                        }
                        if (pos >= inner.len) {
                            self.setDiag(.{ .start = 0, .end = 0, .line = 0, .col = 0 }, "missing '}' in \\u escape");
                            return error.CodegenError;
                        }
                        pos += 1; // skip '}'
                        // Lua uses original UTF-8 (up to 31-bit codepoints,
                        // before RFC 3629 limited to 0x10FFFF).
                        if (cp > 0x7FFFFFFF) {
                            self.setDiag(.{ .start = 0, .end = 0, .line = 0, .col = 0 }, "invalid Unicode codepoint");
                            return error.CodegenError;
                        }
                        // Encode as UTF-8 (1-6 bytes)
                        if (cp <= 0x7F) {
                            try buf.append(self.alloc, @intCast(cp));
                        } else if (cp <= 0x7FF) {
                            try buf.append(self.alloc, @intCast(0xC0 | (cp >> 6)));
                            try buf.append(self.alloc, @intCast(0x80 | (cp & 0x3F)));
                        } else if (cp <= 0xFFFF) {
                            try buf.append(self.alloc, @intCast(0xE0 | (cp >> 12)));
                            try buf.append(self.alloc, @intCast(0x80 | ((cp >> 6) & 0x3F)));
                            try buf.append(self.alloc, @intCast(0x80 | (cp & 0x3F)));
                        } else if (cp <= 0x1FFFFF) {
                            try buf.append(self.alloc, @intCast(0xF0 | (cp >> 18)));
                            try buf.append(self.alloc, @intCast(0x80 | ((cp >> 12) & 0x3F)));
                            try buf.append(self.alloc, @intCast(0x80 | ((cp >> 6) & 0x3F)));
                            try buf.append(self.alloc, @intCast(0x80 | (cp & 0x3F)));
                        } else if (cp <= 0x3FFFFFF) {
                            try buf.append(self.alloc, @intCast(0xF8 | (cp >> 24)));
                            try buf.append(self.alloc, @intCast(0x80 | ((cp >> 18) & 0x3F)));
                            try buf.append(self.alloc, @intCast(0x80 | ((cp >> 12) & 0x3F)));
                            try buf.append(self.alloc, @intCast(0x80 | ((cp >> 6) & 0x3F)));
                            try buf.append(self.alloc, @intCast(0x80 | (cp & 0x3F)));
                        } else {
                            try buf.append(self.alloc, @intCast(0xFC | (cp >> 30)));
                            try buf.append(self.alloc, @intCast(0x80 | ((cp >> 24) & 0x3F)));
                            try buf.append(self.alloc, @intCast(0x80 | ((cp >> 18) & 0x3F)));
                            try buf.append(self.alloc, @intCast(0x80 | ((cp >> 12) & 0x3F)));
                            try buf.append(self.alloc, @intCast(0x80 | ((cp >> 6) & 0x3F)));
                            try buf.append(self.alloc, @intCast(0x80 | (cp & 0x3F)));
                        }
                    },
                    '\n' => {
                        // PUC normalizes an escaped physical newline to one
                        // '\n' byte in the resulting short string.
                        try buf.append(self.alloc, '\n');
                        pos += 1;
                        if (pos < inner.len and inner[pos] == '\r') pos += 1;
                    },
                    '\r' => {
                        try buf.append(self.alloc, '\n');
                        pos += 1;
                        if (pos < inner.len and inner[pos] == '\n') pos += 1;
                    },
                    else => {
                        // Unknown escape: keep backslash + char
                        try buf.append(self.alloc, '\\');
                        try buf.append(self.alloc, inner[pos]);
                        pos += 1;
                    },
                }
            }
            return try buf.toOwnedSlice(self.alloc);
        }

        return raw;
    }

    // -----------------------------------------------------------------------
    // Function calls (OT/IT multi-value convention)
    // -----------------------------------------------------------------------

    /// Compile a function call. `nresults` is the number of results wanted
    /// (0 = discard, 1 = single, -1 = all / set top).
    /// Returns the register holding the first result (for nresults=1).
    fn genCall(self: *Codegen, e: *const ast.Exp, nresults: i32, line: u32) Error!u8 {
        // Dispatch to genMethodCall for method calls.
        if (e.node == .MethodCall) return self.genMethodCall(e, nresults, line);

        const call_node = switch (e.node) {
            .Call => |c| c,
            else => unreachable,
        };
        const call_line = if (call_node.call_line != 0) call_node.call_line else line;

        // Compile function expression into a register.
        // CALL writes results starting at func_reg, so if the function is a
        // local (returned directly by genExp), MOVE it to a temp to avoid
        // clobbering the local with the call result.
        var func_reg = try self.genExp(call_node.func);
        if (func_reg < self.nvarstack) {
            const tmp = try self.allocReg();
            _ = try self.builder.emitABC(.move, tmp, func_reg, 0, call_line);
            func_reg = tmp;
        }

        // Compile arguments into consecutive registers after func_reg.
        // PUC CALL expects R[A+1], R[A+2], ... to physically contain the
        // argument values. genExpNextReg uses ExpDesc: for non-captured
        // locals it discharges directly into the target register (no MOVE).
        self.freereg = func_reg + 1;
        for (call_node.args, 0..) |arg, i| {
            const expected: u8 = @intCast(@as(usize, func_reg) + 1 + i);
            self.freereg = expected;
            const is_last = (i + 1 == call_node.args.len);
            if (is_last) {
                // Last argument: if it's a call or vararg, use multi-value.
                switch (arg.node) {
                    .Call, .MethodCall => {
                        // Compile call with C=0 (set top — all results).
                        _ = try self.genCallMulti(arg, line);
                    },
                    .Dots => {
                        if (!self.is_vararg) {
                            self.setDiag(arg.span, "vararg used in non-vararg function");
                            return error.CodegenError;
                        }
                        // VARARG A 0 (C=0, set top — all varargs)
                        const va_reg = try self.allocReg();
                        _ = try self.builder.emitABC(.vararg, va_reg, 0, 0, arg.span.line);
                    },
                    else => {
                        // Set line_hint to arg's line so discharge
                        // instructions carry the correct line number.
                        const saved_hint = self.line_hint;
                        self.line_hint = arg.span.line;
                        _ = try self.genExpNextReg(arg);
                        self.line_hint = saved_hint;
                    },
                }
            } else {
                const saved_hint = self.line_hint;
                self.line_hint = arg.span.line;
                _ = try self.genExpNextReg(arg);
                self.line_hint = saved_hint;
            }
        }

        // Emit CALL: A=func_reg, B=nargs+1 (0=multret), C=nresults+1 (0=set top)
        // If the last arg was multi-value (call/vararg), use B=0 (use top).
        const has_multret_last = call_node.args.len > 0 and switch (call_node.args[call_node.args.len - 1].node) {
            .Call, .MethodCall, .Dots => true,
            else => false,
        };
        const b: u8 = if (has_multret_last) 0 else @intCast(call_node.args.len + 1);
        const c: u8 = switch (nresults) {
            -1 => 0, // all results (set top)
            else => @intCast(nresults + 1),
        };
        _ = try self.builder.emitABC(.call, func_reg, b, c, call_line);

        // After CALL, set freereg to cover the results.
        if (nresults > 0) {
            self.freereg = func_reg + @as(u8, @intCast(nresults));
        } else if (nresults == 0) {
            self.freereg = func_reg;
        } else {
            // Multi-value (set top): conservatively set to func_reg + 1.
            self.freereg = func_reg + 1;
        }

        return func_reg;
    }

    /// Compile a call in multi-value context (C=0, set top).
    fn genCallMulti(self: *Codegen, e: *const ast.Exp, line: u32) Error!u8 {
        return self.genCall(e, -1, line);
    }

    /// Compile a method call: o:m(args...)
    fn genMethodCall(self: *Codegen, e: *const ast.Exp, nresults: i32, line: u32) Error!u8 {
        const mc = switch (e.node) {
            .MethodCall => |m| m,
            else => unreachable,
        };
        const call_line = if (mc.call_line != 0) mc.call_line else line;

        // Compile receiver.  SELF writes to obj_reg and obj_reg+1, so if
        // the receiver is a local variable (returned directly by genExp
        // without allocating a temp), we must MOVE it to a fresh temp to
        // avoid clobbering the local.
        var obj_reg = try self.genExp(mc.receiver);
        if (obj_reg < self.nvarstack) {
            const tmp = try self.allocReg();
            _ = try self.builder.emitABC(.move, tmp, obj_reg, 0, call_line);
            obj_reg = tmp;
        }

        // SELF: R[obj_reg+1] = R[obj_reg]; R[obj_reg] = R[obj_reg][K[method]]
        const kid = try self.builder.internString(mc.method.slice(self.source));
        if (kid <= 255) {
            _ = try self.builder.emitABC(.self, obj_reg, obj_reg, @intCast(kid), call_line);
        } else {
            // Fallback: load method string, gettable, move self.
            const key = try self.allocReg();
            try self.emitLoadK(key, kid, call_line);
            const method_reg = try self.allocReg();
            _ = try self.builder.emitABC(.gettable, method_reg, obj_reg, key, call_line);
            _ = try self.builder.emitABC(.move, obj_reg + 1, obj_reg, 0, call_line);
            _ = try self.builder.emitABC(.move, obj_reg, method_reg, 0, call_line);
            self.freeReg2(method_reg, key);
        }
        self.freereg = obj_reg + 2;
        if (obj_reg + 2 > self.peak_freereg) self.peak_freereg = obj_reg + 2;
        self.syncLiveTop();

        // Compile args.  Args must be in consecutive registers after
        // obj_reg+1 (self).  genExp can return a local register directly,
        // so we must MOVE values that aren't in the right position.
        for (mc.args, 0..) |arg, i| {
            const expected: u8 = @intCast(@as(usize, obj_reg) + 2 + i);
            self.freereg = expected;
            const is_last = (i + 1 == mc.args.len);
            if (is_last) {
                switch (arg.node) {
                    .Call, .MethodCall => _ = try self.genCallMulti(arg, line),
                    .Dots => {
                        const va_reg = try self.allocReg();
                        _ = try self.builder.emitABC(.vararg, va_reg, 0, 0, arg.span.line);
                    },
                    else => {
                        const r = try self.genExp(arg);
                        if (r != expected) {
                            try self.ensureFreeregAtLeast(expected + 1);
                            _ = try self.builder.emitABC(.move, expected, r, 0, arg.span.line);
                        }
                    },
                }
            } else {
                const r = try self.genExp(arg);
                if (r != expected) {
                    try self.ensureFreeregAtLeast(expected + 1);
                    _ = try self.builder.emitABC(.move, expected, r, 0, arg.span.line);
                }
            }
        }

        // CALL: A=obj_reg, B=(nargs+1)+1 (self + args, 0=multret), C=nresults+1
        const has_multret_last = mc.args.len > 0 and switch (mc.args[mc.args.len - 1].node) {
            .Call, .MethodCall, .Dots => true,
            else => false,
        };
        const b: u8 = if (has_multret_last) 0 else @intCast(mc.args.len + 2);
        const c: u8 = switch (nresults) {
            -1 => 0,
            else => @intCast(nresults + 1),
        };
        _ = try self.builder.emitABC(.call, obj_reg, b, c, call_line);

        // Keep register accounting identical to ordinary calls.  A method
        // call in a fixed-width multi-result context (for example,
        // `a, b = object:method()`) owns every requested result register.
        // Leaving `freereg` at `obj_reg + 1` made assignment code believe only
        // the first result existed and emit LOADNIL over the remaining values.
        if (nresults > 0) {
            self.freereg = obj_reg + @as(u8, @intCast(nresults));
        } else if (nresults == 0) {
            self.freereg = obj_reg;
        } else {
            // Multi-value (set top): the runtime decides the final top.
            self.freereg = obj_reg + 1;
        }
        if (self.freereg > self.peak_freereg) self.peak_freereg = self.freereg;
        self.syncLiveTop();
        return obj_reg;
    }

    // -----------------------------------------------------------------------
    // Table constructors
    // -----------------------------------------------------------------------

    fn emitSetList(self: *Codegen, dst: u8, count: u8, base: u32, line: u32) Error!void {
        // SETLIST keeps small array bases inline. 255 is an escape value;
        // the following EXTRAARG carries the full unsigned 24-bit base.
        if (base < 255) {
            _ = try self.builder.emitABC(.setlist, dst, count, @intCast(base), line);
            return;
        }
        if (base > 0xFF_FFFF) {
            self.setDiag(.{ .start = 0, .end = 0, .line = line, .col = 1 }, "table constructor too long");
            return error.CodegenError;
        }
        _ = try self.builder.emitABC(.setlist, dst, count, 255, line);
        _ = try self.builder.emit(bc.Instruction.extra(base), line);
    }

    fn genTable(self: *Codegen, n: anytype, line: u32) Error!u8 {
        const dst = try self.allocReg();
        // PUC `luaK_settablesize`: emit NEWTABLE with placeholder sizes,
        // then backpatch after counting array/hash fields. PUC pre-sizes
        // both parts so the constructor doesn't trigger rehash per key
        // (critical for testC `alloccount` which expects exactly
        // header + array + hash = 3 allocations).
        // We emit NEWTABLE + EXTRAARG (placeholder) so we can backpatch
        // large array sizes (>255) without inserting instructions retroactively.
        const newtable_pc = try self.builder.emitABC(.newtable, dst, 0, 0, line);
        const extraarg_pc = try self.builder.emit(bc.Instruction.extra(0), line);

        // Track array index for SETLIST.
        var array_count: u32 = 0;
        var flush_base: u32 = 0;
        // PUC ConsControl: na = total array fields, nh = total hash fields.
        var na: u32 = 0;
        var nh: u32 = 0;

        for (n.fields, 0..) |f, fi| {
            const is_last = (fi + 1 == n.fields.len);
            switch (f.node) {
                .Array => |val_e| {
                    if (is_last) {
                        switch (val_e.node) {
                            .Call, .MethodCall => {
                                // Multi-value: compile call with set top, then SETLIST with B=0.
                                _ = try self.genCallMulti(val_e, line);
                                try self.emitSetList(dst, 0, flush_base, line);
                                self.freereg = dst + 1;
                                array_count = 0;
                                // Unknown number of array elements from multret.
                                na = 0;
                                continue;
                            },
                            .Dots => {
                                if (!self.is_vararg) {
                                    self.setDiag(val_e.span, "vararg used in non-vararg function");
                                    return error.CodegenError;
                                }
                                const va_reg = try self.allocReg();
                                _ = try self.builder.emitABC(.vararg, va_reg, 0, 0, val_e.span.line);
                                try self.emitSetList(dst, 0, flush_base, line);
                                self.freereg = dst + 1;
                                array_count = 0;
                                na = 0;
                                continue;
                            },
                            else => {},
                        }
                    }
                    _ = try self.genExpNextReg(val_e);
                    array_count += 1;
                    na += 1;
                    // Flush if we have enough values (PUC flushes at ~50).
                    if (array_count >= 50) {
                        try self.emitSetList(dst, @intCast(array_count), flush_base, line);
                        self.freereg = dst + 1;
                        flush_base += array_count;
                        array_count = 0;
                    }
                },
                .Name => |nv| {
                    // Flush pending array values first.
                    if (array_count > 0) {
                        try self.emitSetList(dst, @intCast(array_count), flush_base, line);
                        self.freereg = dst + 1;
                        flush_base += array_count;
                        array_count = 0;
                    }
                    const val = try self.genExp(nv.value);
                    const kid = try self.builder.internString(nv.name.slice(self.source));
                    if (kid <= 255) {
                        _ = try self.builder.emitABC(.setfield, dst, @intCast(kid), val, nv.name.span.line);
                    } else {
                        const key = try self.allocReg();
                        try self.emitLoadK(key, kid, nv.name.span.line);
                        _ = try self.builder.emitABC(.settable, dst, key, val, nv.name.span.line);
                        self.freeReg(key);
                    }
                    self.freeReg(val);
                    nh += 1;
                },
                .Index => |kv| {
                    if (array_count > 0) {
                        try self.emitSetList(dst, @intCast(array_count), flush_base, line);
                        self.freereg = dst + 1;
                        flush_base += array_count;
                        array_count = 0;
                    }
                    const key = try self.genExp(kv.key);
                    const val = try self.genExp(kv.value);
                    _ = try self.builder.emitABC(.settable, dst, key, val, kv.key.span.line);
                    self.freeReg2(val, key);
                    nh += 1;
                },
            }
        }

        // Flush remaining array values.
        if (array_count > 0) {
            try self.emitSetList(dst, @intCast(array_count), flush_base, line);
            self.freereg = dst + 1;
        }

        // PUC `luaK_settablesize`: backpatch the NEWTABLE instruction with
        // the computed array size (na) and hash size (nh). The hash size is
        // encoded as ceilLog2(nh) + 1 (0 means no hash part). The array size
        // is split: low 8 bits in C, high bits in the EXTRAARG.
        // full_na = C + EXTRAARG * 256.
        // Only backpatch if we have known sizes (multret/vararg sets na=0).
        if (na > 0 or nh > 0) {
            const hsize_log2: u8 = if (nh > 0) @intCast(ltable.ceilLog2(nh) + 1) else 0;
            const na_low: u8 = @intCast(na % 256);
            const na_high: u32 = na / 256;
            self.builder.code.items[newtable_pc] = Instruction.make(
                .newtable,
                dst,
                hsize_log2,
                na_low,
            );
            // Backpatch the EXTRAARG with the high bits of na.
            self.builder.code.items[extraarg_pc] = Instruction.extra(na_high);
        }

        return dst;
    }

    fn spanLastLine(self: *const Codegen, span: ast.Span) u32 {
        var line = span.line;
        const text = self.source[span.start..span.end];
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (ch == '\n' or ch == '\r') {
                line += 1;
                if (i + 1 < text.len) {
                    const next = text[i + 1];
                    if ((ch == '\n' and next == '\r') or (ch == '\r' and next == '\n')) i += 1;
                }
            }
        }
        return line;
    }

    /// Last source line containing a token inside `span`. Parser statement
    /// spans may extend through trailing whitespace up to the next token/EOF;
    /// PUC attaches an implicit main-chunk RETURN to the final statement, not
    /// to those trailing blank lines.
    fn spanLastTokenLine(self: *const Codegen, span: ast.Span) u32 {
        var end = span.end;
        while (end > span.start and std.ascii.isWhitespace(self.source[end - 1])) end -= 1;
        return self.spanLastLine(.{
            .start = span.start,
            .end = end,
            .line = span.line,
            .col = span.col,
        });
    }

    // -----------------------------------------------------------------------
    // Closures / function definitions
    // -----------------------------------------------------------------------

    fn genFuncDef(self: *Codegen, body: *const ast.FuncBody, line: u32) Error!u8 {
        const child_proto = try self.compileChildFunction("<anon>", body, null, line);
        const dst = try self.allocReg();
        // CLOSURE A Bx: R[A] = closure(P[B])
        const proto_idx = try self.builder.addProto(child_proto);
        if (proto_idx <= 255) {
            _ = try self.builder.emitABC(.closure, dst, proto_idx, 0, child_proto.last_line_defined);
        } else {
            // Large proto index — needs EXTRAARG.
            _ = try self.builder.emitABC(.closure, dst, 0, 0, child_proto.last_line_defined);
            _ = try self.builder.emit(Instruction.extra(proto_idx), line);
        }
        return dst;
    }

    /// Compile a child function (closure). Creates a new Codegen linked
    /// via `outer`, compiles the body, and returns the child Proto.
    fn compileChildFunction(
        self: *Codegen,
        name: []const u8,
        body: *const ast.FuncBody,
        self_name: ?[]const u8,
        line: u32,
    ) Error!*bc.Proto {
        var child = Codegen.init(self.alloc, self.source_name, self.source);
        defer child.deinit();
        child.outer = self;
        child.builder.name = name;
        child.builder.source_name = self.source_name;
        child.builder.line_defined = line;
        child.builder.last_line_defined = child.spanLastLine(body.span);

        // If this is a method, "self" is the first parameter.
        if (self_name) |sn| {
            const reg = try child.declareLocal(sn);
            _ = reg;
        }

        child.compileFuncBody(body) catch |err| {
            if (child.diag) |diag| {
                const msg = std.fmt.bufPrint(self.diag_buf[0..], "{s}", .{diag.msg}) catch "code generation error";
                self.diag = .{
                    .source_name = diag.source_name,
                    .line = diag.line,
                    .col = diag.col,
                    .msg = msg,
                };
            }
            return err;
        };
        return child.builder.finish();
    }

    /// Compile a function body (parameters + block).
    fn compileFuncBody(self: *Codegen, body: *const ast.FuncBody) Error!void {
        // For the main chunk (outer == null), _ENV is upvalue 0 (instack=true,
        // idx=0) — it represents the environment passed by the host.
        // For child functions, _ENV is lazily created when a global name
        // is first encountered, matching PUC Lua's singlevaraux behavior.
        if (self.outer == null) {
            const idx = try self.nextUpvalueIndex();
            try self.upvalue_descs.append(self.alloc, .{
                .instack = true,
                .idx = 0,
                .is_const = false,
                .name = "_ENV",
            });
            try self.upvalues.put(self.alloc, "_ENV", idx);
            self.env_upvalue_idx = idx;
        }

        // Parameters become locals in registers 0..numparams-1.
        for (body.params) |param| {
            _ = try self.declareLocal(param.slice(self.source));
        }
        self.builder.numparams = self.nvarstack;

        // Vararg handling.
        if (body.vararg) |va| {
            self.is_vararg = true;
            self.builder.is_vararg = true;
            // Named vararg (Lua 5.5): `...arg`.
            // By default, the vararg parameter is *virtual* (PF_VAHID):
            // `arg[n]`/`arg.n` compile to GETVARG reading extra args directly,
            // with no table allocation. Only when the vararg "escapes"
            // (returned, assigned, passed to a call, written to via `arg[k]=v`)
            // do we set `vararg_table_reg` (PF_VATAB) to materialize a real
            // table. This mirrors PUC's needvatab()/PF_VAHID/PF_VATAB design.
            if (va.name) |va_name| {
                // The vararg parameter occupies the register after all fixed
                // params. Declare it as a local so it has a name for debug
                // info and is resolvable by name. The register is nil at
                // runtime while virtual (no table created).
                const va_reg = try self.declareLocal(va_name.slice(self.source));
                self.markReadonlyLocal(va_reg);
                self.vararg_param_reg = va_reg;
                // Special case: if the vararg parameter is named "_ENV",
                // it serves as the function's environment table. It must
                // always be materialized (PF_VATAB) — global access goes
                // through _ENV as a real table, not virtual vararg.
                if (std.mem.eql(u8, va_name.slice(self.source), "_ENV")) {
                    self.needVarargTable();
                }
                // Do NOT set vararg_table_reg here — it's set lazily by
                // needVarargTable() when the vararg escapes.
            }
            // Emit VARARGPREP as first instruction.
            _ = try self.builder.emitABC(.varargprep, self.builder.numparams, 0, 0, 0);
        }

        // Compile the body block.
        try self.genBlock(body.body);

        // PUC associates the implicit RETURN with the closing line of the
        // function body.  This line is observable through debug.getinfo(...,
        // "L") and line hooks, so it must not inherit the last statement's
        // line.
        _ = try self.builder.emitSimple(.return0, self.spanLastLine(body.span));

        // Parameters and named varargs live for the whole function and are
        // declared outside the body block's lexical scope. Close their debug
        // ranges explicitly at the function epilogue; leaving endpc at zero
        // makes debug name resolution treat them as inactive after entry.
        const function_end_pc = self.builder.pc();
        for (self.bindings.items) |binding| {
            if (self.builder.locvars.items[binding.locvar_index].endpc == 0) {
                self.builder.closeLocVar(binding.locvar_index, function_end_pc);
            }
        }

        // Transfer upvalue descriptions to the builder.
        for (self.upvalue_descs.items) |desc| {
            _ = try self.builder.addUpvalue(desc);
        }

        // PUC luaK_finish (lcode.c:1940): rewrite RETURN0/RETURN1 to RETURN
        // when the function has open upvalues (needclose). PUC uses the k-bit
        // on RETURN to signal upvalue closing; luazig's VM always closes
        // upvalues in completeBytecodeExecFrame, so the k-bit is not needed.
        // But T.listcode (code.lua) expects RETURN (not RETURN0) for functions
        // with upvalues — this rewrite produces PUC-faithful bytecode.
        // PUC needclose: at least one local was captured by a nested function.
        // In luazig, captured_regs tracks locals grabbed by inner closures.
        const needclose = self.captured_regs.count() > 0;
        if (needclose) {
            for (self.builder.code.items) |*inst| {
                const op: bc.Op = @enumFromInt(inst.op);
                if (op == .return0) {
                    // PUC luaK_ret: RETURN0 has A=first, B=nret+1=1.
                    // luazig emitSimple sets A=0,B=0. Rewrite to RETURN
                    // and set B=1 (0 return values + 1) to avoid B=0
                    // meaning "use top" (multret) in RETURN semantics.
                    inst.op = @intFromEnum(bc.Op.return_);
                    inst.b = 1;
                } else if (op == .return1) {
                    // RETURN1 A=first B=1 → RETURN A=first B=2 (1 ret + 1)
                    inst.op = @intFromEnum(bc.Op.return_);
                    inst.b = 2;
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Expression lists (for multi-value contexts)
    // -----------------------------------------------------------------------

    /// Compile an expression list, putting results in consecutive registers
    /// starting at the current freereg. If the last expression is a call or
    /// vararg, it produces all its values (multi-value expansion).
    /// Returns the number of registers used (or -1 for variable count).
    fn genExplist(self: *Codegen, exps: []const *const ast.Exp) Error!i32 {
        if (exps.len == 0) return 0;

        for (exps, 0..) |exp, i| {
            const is_last = (i + 1 == exps.len);
            if (is_last) {
                switch (exp.node) {
                    .Call, .MethodCall => {
                        // Multi-value: all results.
                        _ = try self.genCall(exp, -1, exp.span.line);
                        return -1; // variable count
                    },
                    .Dots => {
                        if (!self.is_vararg) {
                            self.setDiag(exp.span, "vararg used in non-vararg function");
                            return error.CodegenError;
                        }
                        const va_reg = try self.allocReg();
                        _ = try self.builder.emitABC(.vararg, va_reg, 0, 0, exp.span.line);
                        return -1;
                    },
                    else => {
                        _ = try self.genExpNextReg(exp);
                        return @intCast(exps.len);
                    },
                }
            } else {
                _ = try self.genExpNextReg(exp);
            }
        }
        return @intCast(exps.len);
    }

    fn genExplistFixed(self: *Codegen, exps: []const *const ast.Exp, wanted: u8, line: u32) Error!void {
        const base = self.freereg;
        for (exps, 0..) |exp, i| {
            if (self.freereg >= base + wanted) break;
            const is_last = (i + 1 == exps.len);
            if (is_last) {
                const remaining: i32 = @intCast(base + wanted - self.freereg);
                switch (exp.node) {
                    .Call, .MethodCall => {
                        _ = try self.genCall(exp, remaining, exp.span.line);
                        self.freereg = base + wanted;
                    },
                    .Dots => {
                        if (!self.is_vararg) {
                            self.setDiag(exp.span, "vararg used in non-vararg function");
                            return error.CodegenError;
                        }
                        const va_reg = try self.allocReg();
                        _ = try self.builder.emitABC(.vararg, va_reg, 0, @intCast(remaining + 1), exp.span.line);
                        self.freereg = base + wanted;
                        if (base + wanted > self.peak_freereg) self.peak_freereg = base + wanted;
                        self.syncLiveTop();
                    },
                    else => {
                        _ = try self.genExpNextReg(exp);
                    },
                }
            } else {
                _ = try self.genExpNextReg(exp);
            }
        }
        while (self.freereg < base + wanted) {
            const nil_reg = try self.allocReg();
            try self.emitLoadNil(nil_reg, 1, line);
        }
    }

    fn genAndExp(self: *Codegen, lhs_exp: *const ast.Exp, rhs_exp: *const ast.Exp, line: u32) Error!u8 {
        // a and b: if a is falsy, result = a; else result = b.
        // PUC approach: test lhs, if falsy skip to end (keep lhs in dst),
        // else compile rhs into dst.
        const dst = try self.allocReg();
        const lhs = try self.genExp(lhs_exp);
        _ = try self.builder.emitABC(.move, dst, lhs, 0, line);
        self.freeReg(lhs);

        // TEST dst 0 (skip JMP when truthy → fall through to rhs).
        _ = try self.builder.emitABC(.test_, dst, 0, 0, line);
        // JMP past rhs evaluation.
        const jmp_pc = try self.emitJump(line);
        // Evaluate rhs into dst.
        const rhs = try self.genExp(rhs_exp);
        _ = try self.builder.emitABC(.move, dst, rhs, 0, line);
        self.freeReg(rhs);
        self.patchJumpToHere(jmp_pc);
        return dst;
    }

    fn genOrExp(self: *Codegen, lhs_exp: *const ast.Exp, rhs_exp: *const ast.Exp, line: u32) Error!u8 {
        // a or b: if a is truthy, result = a; else result = b.
        const dst = try self.allocReg();
        const lhs = try self.genExp(lhs_exp);
        _ = try self.builder.emitABC(.move, dst, lhs, 0, line);
        self.freeReg(lhs);

        // TEST dst 1 (skip JMP when falsy → fall through to rhs).
        _ = try self.builder.emitABC(.test_, dst, 0, 1, line);
        const jmp_pc = try self.emitJump(line);
        const rhs = try self.genExp(rhs_exp);
        _ = try self.builder.emitABC(.move, dst, rhs, 0, line);
        self.freeReg(rhs);
        self.patchJumpToHere(jmp_pc);
        return dst;
    }

    // -----------------------------------------------------------------------
    // Statement compilation
    // -----------------------------------------------------------------------

    /// Compile a statement. Returns true if a terminator (return) was emitted.
    fn genStat(self: *Codegen, st: *const ast.Stat) Error!bool {
        const old_line = self.line_hint;
        self.line_hint = st.span.line;
        defer self.line_hint = old_line;
        // P15.72g: Don't resetRegs after a return statement. The RETURN
        // instruction places return values in registers above nvarstack
        // (e.g. R2-R4 for `return f()`). The subsequent CLOSE instructions
        // (emitted by popScope for <close> variables) must inherit a
        // live_reg_top that covers those return values. If we reset here,
        // live_reg_top[close_pc] = nvarstack, and GC can collect the return
        // values while the coroutine is parked at a yield inside __close.
        const is_return = st.node == .Return;
        defer {
            if (!is_return) self.resetRegs();
        }

        switch (st.node) {
            .LocalDecl => |n| return self.genLocalDecl(n, st.span.line),
            .Assign => |n| return self.genAssign(n, st.span.line),
            .Return => |n| return self.genReturn(n, st.span.line),
            .If => |n| return self.genIf(n, st.span.line),
            .While => |n| return self.genWhile(n, st.span.line),
            .Repeat => |n| return self.genRepeat(n, st.span.line),
            .Break => return self.genBreak(st.span.line),
            .Do => |n| {
                try self.genBlock(n.block);
                return false;
            },
            .Goto => |n| {
                const name = n.label.slice(self.source);
                const current_scope_id = self.currentScopeId();

                // A backward goto may target only a label visible from the
                // current lexical scope. In particular, labels from a sibling
                // block must not survive merely because they have the same
                // numeric nesting depth.
                var label: ?ActiveLabel = null;
                var i = self.active_labels.items.len;
                while (i > 0) {
                    i -= 1;
                    const candidate = self.active_labels.items[i];
                    if (!std.mem.eql(u8, candidate.name, name)) continue;
                    if (!self.scopeIsDescendantOrSame(current_scope_id, candidate.scope_id)) continue;
                    label = candidate;
                    break;
                }

                if (label) |target| {
                    if (self.closeRegForActiveLabel(target)) |first_reg| {
                        _ = try self.builder.emitABC(.close, first_reg, 0, 0, st.span.line);
                    }
                    const jmp_pc = try self.emitJump(st.span.line);
                    self.patchJumpTo(jmp_pc, target.pc);
                } else {
                    // Reserve a patchable no-op before the actual jump. JMP 0
                    // falls through; if resolving the label proves that the
                    // goto exits one or more scopes, it becomes OP_CLOSE.
                    const close_pc = try self.emitJump(st.span.line);
                    const jmp_pc = try self.emitJump(st.span.line);
                    try self.pending_gotos.append(self.alloc, .{
                        .pc = jmp_pc,
                        .close_pc = close_pc,
                        .name = name,
                        .span = st.span,
                        .depth = self.scope_marks.items.len,
                        .scope_id = current_scope_id,
                        .guard_len = self.jump_guards.items.len,
                        .resolved = false,
                    });
                }
                return false;
            },
            .Label => |n| {
                const name = n.label.slice(self.source);
                // Mark the current PC as a jump target (PUC luaK_getlabel).
                self.lasttarget = self.builder.pc();
                const target_pc = self.builder.pc();
                const label_scope_id = self.currentScopeId();

                // A label cannot redefine another label that is already
                // visible at this point. Labels from completed sibling blocks
                // have been expired by popScope and therefore remain legal.
                for (self.active_labels.items) |existing| {
                    if (!std.mem.eql(u8, existing.name, name)) continue;
                    if (!self.scopeIsDescendantOrSame(label_scope_id, existing.scope_id)) continue;
                    self.setDiagFmt(st.span, "label '{s}' already defined on line {d}", .{ name, existing.line });
                    return error.CodegenError;
                }

                const label = ActiveLabel{
                    .name = name,
                    .pc = target_pc,
                    .line = st.span.line,
                    .depth = self.scope_marks.items.len,
                    .scope_id = label_scope_id,
                    .binding_mark = self.bindings.items.len,
                };
                try self.active_labels.append(self.alloc, label);

                // Resolve only gotos whose origin scope is this label's scope
                // or one of its descendants. This is the same visibility rule
                // PUC applies to labels in enclosing blocks.
                for (self.pending_gotos.items) |*pg| {
                    if (pg.resolved or !std.mem.eql(u8, pg.name, name)) continue;
                    if (!self.scopeIsDescendantOrSame(pg.scope_id, label_scope_id)) continue;

                    // Forward control flow cannot enter the lifetime of a local
                    // declared after the goto. The append-only guard log keeps
                    // these declarations available even if the goto originated
                    // in a scope that has since been popped.
                    var guard_index = pg.guard_len;
                    while (self.label_has_code_after and guard_index < self.jump_guards.items.len) : (guard_index += 1) {
                        const guard = self.jump_guards.items[guard_index];
                        if (guard.depth <= self.scope_marks.items.len and
                            self.scopeIsDescendantOrSame(label_scope_id, guard.scope_id))
                        {
                            self.setDiagFmt(
                                pg.span,
                                "goto at line {d} jumps into the scope of '{s}'",
                                .{ pg.span.line, guard.name },
                            );
                            return error.CodegenError;
                        }
                    }

                    self.patchGotoClose(pg.close_pc, pg.close_reg);
                    self.patchJumpTo(pg.pc, target_pc);
                    pg.resolved = true;
                }
                return false;
            },
            .Call => |n| {
                // Statement-form call: compile with 0 results.
                _ = try self.genCall(n.call, 0, st.span.line);
                return false;
            },
            .LocalFuncDecl => |n| {
                // local function f() ... end
                // Declare f first (so f can reference itself for recursion).
                const reg = try self.declareLocal(n.name.slice(self.source));
                const child = try self.compileChildFunction(
                    n.name.slice(self.source),
                    n.body,
                    null,
                    st.span.line,
                );
                const proto_idx = try self.builder.addProto(child);
                const closure_line = child.last_line_defined;
                if (proto_idx <= 255) {
                    _ = try self.builder.emitABC(.closure, reg, proto_idx, 0, closure_line);
                } else {
                    _ = try self.builder.emitABC(.closure, reg, 0, 0, closure_line);
                    _ = try self.builder.emit(Instruction.extra(proto_idx), closure_line);
                }
                return false;
            },
            .FuncDecl => |n| {
                // function a.b.c:d() ... end
                // Desugar: navigate to parent table, then SET last field/method.
                const body_line = n.body.span.line;
                // Method syntax (a:b): implicit first parameter is always "self".
                const self_name: ?[]const u8 = if (n.name.method != null) "self" else null;
                const child = try self.compileChildFunction(
                    n.name.base.slice(self.source),
                    n.body,
                    self_name,
                    body_line,
                );
                const proto_idx = try self.builder.addProto(child);
                const func_reg = try self.allocReg();
                const closure_line = child.last_line_defined;
                if (proto_idx <= 255) {
                    _ = try self.builder.emitABC(.closure, func_reg, proto_idx, 0, closure_line);
                } else {
                    _ = try self.builder.emitABC(.closure, func_reg, 0, 0, closure_line);
                    _ = try self.builder.emit(Instruction.extra(proto_idx), closure_line);
                }
                // Assign to the target. If no fields/method: global assignment.
                if (n.name.fields.len == 0 and n.name.method == null) {
                    try self.emitSetName(n.name.base.span, n.name.base.slice(self.source), func_reg);
                } else {
                    // Navigate to the parent object:
                    // - method != null: navigate ALL fields (method name is separate)
                    // - method == null: navigate all EXCEPT last field (last is SET target)
                    var current = try self.genNameValue(n.name.base.span, n.name.base.slice(self.source));
                    const nav_count = if (n.name.method != null) n.name.fields.len else @max(n.name.fields.len, 1) - 1;
                    for (n.name.fields[0..nav_count]) |field| {
                        const kid = try self.builder.internString(field.slice(self.source));
                        if (kid <= 255) {
                            const next = try self.allocReg();
                            _ = try self.builder.emitABC(.getfield, next, current, @intCast(kid), field.span.line);
                            self.freeReg(current);
                            current = next;
                        } else {
                            const key = try self.allocReg();
                            try self.emitLoadK(key, kid, field.span.line);
                            const next = try self.allocReg();
                            _ = try self.builder.emitABC(.gettable, next, current, key, field.span.line);
                            self.freeReg2(key, current);
                            current = next;
                        }
                    }
                    // SET the last field/method on the parent.
                    const last_name = if (n.name.method) |m| m else n.name.fields[n.name.fields.len - 1];
                    const kid = try self.builder.internString(last_name.slice(self.source));
                    if (kid <= 255) {
                        _ = try self.builder.emitABC(.setfield, current, @intCast(kid), func_reg, st.span.line);
                    } else {
                        const key = try self.allocReg();
                        try self.emitLoadK(key, kid, st.span.line);
                        _ = try self.builder.emitABC(.settable, current, key, func_reg, st.span.line);
                        self.freeReg(key);
                    }
                    self.freeReg(current);
                }
                self.freeReg(func_reg);
                return false;
            },
            .GlobalFuncDecl => |n| {
                // global function f() ... end
                const global_name = n.name.slice(self.source);
                try self.appendJumpGuard(global_name);
                try self.declareGlobalName(global_name);
                try self.declareGlobalAttr(global_name, false);
                const child = try self.compileChildFunction(
                    global_name,
                    n.body,
                    null,
                    st.span.line,
                );
                const proto_idx = try self.builder.addProto(child);
                const func_reg = try self.allocReg();
                const closure_line = child.last_line_defined;
                if (proto_idx <= 255) {
                    _ = try self.builder.emitABC(.closure, func_reg, proto_idx, 0, closure_line);
                } else {
                    _ = try self.builder.emitABC(.closure, func_reg, 0, 0, closure_line);
                    _ = try self.builder.emit(Instruction.extra(proto_idx), closure_line);
                }
                const kid = try self.builder.internString(global_name);
                try self.emitGlobalSet(kid, .{ .c = func_reg, .k = false }, st.span.line);
                self.freeReg(func_reg);
                return false;
            },
            .GlobalDecl => |n| {
                // global a, b, c = ...  (with values: assign to _ENV)
                // global a, b, c        (without values: just declarations, no code)
                if (n.star) {
                    if (n.prefix_attr) |attr| {
                        if (attr.kind == .Close) {
                            self.setDiag(attr.span, "global variable cannot be to-be-closed");
                            return error.CodegenError;
                        }
                    }
                    const readonly = if (n.prefix_attr) |attr| attr.kind == .Const else false;
                    try self.appendJumpGuard("*");
                    self.declareGlobalWildcard(readonly);
                    return false;
                }

                var has_env_name = false;
                for (n.names) |decl| {
                    if (std.mem.eql(u8, decl.name.slice(self.source), "_ENV")) {
                        has_env_name = true;
                        break;
                    }
                }
                if (has_env_name) {
                    // `_ENV` is the compiler's environment variable and cannot
                    // itself be declared global. Enter strict mode, but do not
                    // declare the sibling names from this invalid declaration.
                    if (self.strict_globals_mode != .wildcard) self.strict_globals_mode = .strict;
                    return false;
                }

                // Evaluate initializers before installing the declarations.
                // Therefore `local a=1; global a=a` reads the local on the RHS
                // and writes the global on the LHS, matching PUC Lua.
                //
                // Keep the values in one consecutive register range, using
                // the regular Lua adjustment rule for the last expression:
                // a final call/vararg expands to fill all remaining names.
                const init_base = self.freereg;
                var expanded_first_name = n.names.len;
                if (n.values) |values| {
                    for (values[0..@max(values.len, 1) -| 1]) |value| {
                        _ = try self.genExpNextReg(value);
                    }
                    const last_expands = values.len > 0 and switch (values[values.len - 1].node) {
                        .Call, .MethodCall, .Dots => true,
                        else => false,
                    };
                    expanded_first_name = if (last_expands) values.len - 1 else n.names.len;
                    if (values.len > 0) {
                        const last = values[values.len - 1];
                        const nresults: i32 = @as(i32, @intCast(n.names.len)) - @as(i32, @intCast(values.len)) + 1;
                        switch (last.node) {
                            .Call, .MethodCall => _ = try self.genCall(last, nresults, st.span.line),
                            .Dots => {
                                if (!self.is_vararg) {
                                    self.setDiag(last.span, "vararg used in non-vararg function");
                                    return error.CodegenError;
                                }
                                const vararg_reg = try self.allocReg();
                                const result_count: u8 = if (nresults < 0) 0 else @intCast(nresults + 1);
                                _ = try self.builder.emitABC(.vararg, vararg_reg, 0, result_count, last.span.line);
                            },
                            else => _ = try self.genExpNextReg(last),
                        }
                    }
                }

                const prefix_readonly = if (n.prefix_attr) |attr| attr.kind == .Const or attr.kind == .Close else false;
                for (n.names) |decl| {
                    if ((decl.prefix_attr orelse decl.suffix_attr)) |attr| {
                        if (attr.kind == .Close) {
                            self.setDiag(attr.span, "global variable cannot be to-be-closed");
                            return error.CodegenError;
                        }
                    }
                    const name = decl.name.slice(self.source);
                    const suffix_readonly = if (decl.prefix_attr orelse decl.suffix_attr) |attr| attr.kind == .Const else false;
                    try self.appendJumpGuard(name);
                    try self.declareGlobalName(name);
                    try self.declareGlobalAttr(name, prefix_readonly or suffix_readonly);
                }

                if (n.values != null) {
                    for (n.names, 0..) |decl, i| {
                        const value_reg = init_base + @as(u8, @intCast(i));
                        const values = n.values.?;
                        if (!(i < values.len or i >= expanded_first_name)) {
                            if (value_reg >= self.freereg) try self.ensureFreeregAtLeast(value_reg + 1);
                            try self.emitLoadNil(value_reg, 1, st.span.line);
                        }
                        const kid = try self.builder.internString(decl.name.slice(self.source));
                        try self.emitGlobalDefinitionGuard(kid, st.span.line);
                        try self.emitGlobalSet(kid, .{ .c = value_reg, .k = false }, st.span.line);
                    }
                    // All initializer registers are temporaries and will be
                    // cleared by resetRegs at the statement boundary.
                }
                // No values: global declarations don't emit any code.
                // The globals already exist in _ENV (set up by bootstrapGlobals).
                return false;
            },
            .ForNumeric => |n| return self.genForNumeric(n, st.span.line),
            .ForGeneric => |n| return self.genForGeneric(n, st.span.line),
        }
    }

    fn genLocalDecl(self: *Codegen, n: anytype, line: u32) Error!bool {
        if (n.values) |values| {
            const base = self.freereg;
            // Compile all values except the last as single-value.
            for (values[0..@max(values.len, 1) -| 1]) |val| {
                _ = try self.genExpNextReg(val);
            }
            // Last value: if it's a call/vararg, use multi-value expansion.
            const last_expands = values.len > 0 and switch (values[values.len - 1].node) {
                .Call, .MethodCall, .Dots => true,
                else => false,
            };
            if (values.len > 0) {
                const last = values[values.len - 1];
                const nnames: i32 = @intCast(n.names.len);
                const nresults: i32 = nnames - @as(i32, @intCast(values.len)) + 1;
                switch (last.node) {
                    .Call, .MethodCall => {
                        _ = try self.genCall(last, nresults, line);
                    },
                    .Dots => {
                        if (!self.is_vararg) {
                            self.setDiag(last.span, "vararg used in non-vararg function");
                            return error.CodegenError;
                        }
                        // VARARG with specific result count.
                        const va_reg = try self.allocReg();
                        const c: u8 = if (nresults < 0) 0 else @intCast(nresults + 1);
                        _ = try self.builder.emitABC(.vararg, va_reg, 0, c, last.span.line);
                    },
                    else => {
                        // PUC RDKCTC (lparser.c:1847-1853): when nvars == nexps
                        // (no adjustment needed) AND the last variable has the
                        // <const> attribute AND the last expression folds to a
                        // compile-time constant, PUC skips codegen for the last
                        // expression entirely. The value is captured at compile
                        // time (via captureConstLocalValue, called during
                        // binding below) and folded at every use site.
                        //
                        // We allocate the register slot (so the variable occupies
                        // the correct position in the varstack) but emit NO
                        // instruction — matching PUC's adjustlocalvars(nvars-1)
                        // + nactvar++ path that bypasses adjust_assign.
                        const rdkctc = blk: {
                            if (values.len == n.names.len and values.len > 0) {
                                const dn = n.names[values.len - 1];
                                if (dn.prefix_attr orelse dn.suffix_attr) |attr| {
                                    if (attr.kind == .Const and self.genConstExpDesc(last) != null) {
                                        break :blk true;
                                    }
                                }
                            }
                            break :blk false;
                        };
                        if (rdkctc) {
                            _ = try self.allocReg(); // reserve slot, emit nothing
                        } else {
                            _ = try self.genExpNextReg(last);
                        }
                    },
                }
            }
            // Declare locals: each name gets the next register from base.
            // PUC-faithful: coalesce nil-fills for locals without values into
            // a single LOADNIL A B (B = count-1), matching PUC luaK_nil.
            // Only coalesces within this one declaration — never across
            // statements (cross-statement coalescing broke goto.lua scope
            // handling).
            const promote_count: usize = if (last_expands) n.names.len else values.len;
            for (0..promote_count) |i| {
                const dn = n.names[i];
                const reg = base + @as(u8, @intCast(i));
                // Value already in this register — just promote to local.
                if (reg >= self.nvarstack) {
                    self.nvarstack = reg + 1;
                    self.freereg = @max(self.freereg, self.nvarstack);
                    // PUC-faithful: nvarstack growth must update live_top
                    // so GC marks the new local. Without this, live_reg_top
                    // stays at the old value and GC clears the local.
                    self.peak_freereg = @max(self.peak_freereg, self.nvarstack);
                    self.syncLiveTop();
                }
                try self.appendBinding(dn.name.slice(self.source), reg);
                if (dn.prefix_attr orelse dn.suffix_attr) |attr| {
                    if (attr.kind == .Const) {
                        self.markConstLocal(reg);
                        // PUC RDKCTC: store the compile-time value when the
                        // initializer is a constant expression.
                        self.captureConstLocalValue(reg, if (i < values.len) values[i] else null);
                    }
                    if (attr.kind == .Close) {
                        self.markCloseLocal(reg);
                        _ = try self.builder.emitABC(.tbc, reg, 0, 0, line);
                    }
                }
            }
            // Nil-fill remaining locals (fewer values than names, last value
            // doesn't multi-expand) with a single coalesced LOADNIL.
            if (!last_expands and values.len < n.names.len) {
                const nil_count: usize = n.names.len - values.len;
                const nil_first: u8 = base + @as(u8, @intCast(values.len));
                try self.ensureFreeregAtLeast(nil_first + @as(u8, @intCast(nil_count)));
                try self.emitLoadNil(nil_first, @as(u8, @intCast(nil_count)), line);
                for (values.len..n.names.len) |i| {
                    const dn = n.names[i];
                    const reg = base + @as(u8, @intCast(i));
                    self.nvarstack = reg + 1;
                    self.freereg = @max(self.freereg, self.nvarstack);
                    self.peak_freereg = @max(self.peak_freereg, self.nvarstack);
                    self.syncLiveTop();
                    try self.appendBinding(dn.name.slice(self.source), reg);
                    if (dn.prefix_attr orelse dn.suffix_attr) |attr| {
                        if (attr.kind == .Const) {
                            self.markConstLocal(reg);
                            self.captureConstLocalValue(reg, null);
                        }
                        if (attr.kind == .Close) {
                            self.markCloseLocal(reg);
                            _ = try self.builder.emitABC(.tbc, reg, 0, 0, line);
                        }
                    }
                }
            }
        } else {
            // No values: declare all as nil.
            // PUC-faithful: emit a single LOADNIL A B (B = count-1) covering
            // R[A..A+B] for all locals, matching PUC luaK_nil which coalesces
            // adjacent nil-fills. Only coalesces within this one declaration.
            const count: u8 = @intCast(n.names.len);
            const first_reg = self.freereg;
            try self.reserveRegs(count);
            try self.emitLoadNil(first_reg, count, line);
            for (n.names, 0..) |dn, i| {
                const reg = first_reg + @as(u8, @intCast(i));
                self.nvarstack = @max(self.nvarstack, reg + 1);
                self.peak_freereg = @max(self.peak_freereg, self.nvarstack);
                self.syncLiveTop();
                try self.appendBinding(dn.name.slice(self.source), reg);
                if (dn.prefix_attr orelse dn.suffix_attr) |attr| {
                    // PUC: nvars(1) != nexps(0), so a `<const>` here stays a
                    // regular const (gets a register with nil), not a
                    // compile-time constant. No value is captured.
                    if (attr.kind == .Const) self.markConstLocal(reg);
                    if (attr.kind == .Close) self.markCloseLocal(reg);
                }
            }
        }
        return false;
    }

    fn genAssign(self: *Codegen, n: anytype, line: u32) Error!bool {
        // Pre-resolve LHS names that are upvalues, so upvalues are
        // registered in left-to-right order matching PUC Lua's
        // single-pass compiler (which creates upvalues during parsing,
        // LHS before RHS).  This ensures debug.getupvalue returns names
        // in the same order as PUC Lua.
        for (n.lhs) |lhs| {
            switch (lhs.node) {
                .Name => |nn| {
                    const name = nn.slice(self.source);
                    if (self.lookupLocal(name) == null and
                        self.upvalues.get(name) == null and
                        self.outer != null)
                    {
                        _ = self.ensureUpvalue(name) catch null;
                    }
                },
                else => {},
            }
        }
        // Simple 1:1 assignment.
        if (n.lhs.len == 1 and n.rhs.len == 1) {
            // P15.38c: Direct-store to local. When LHS is a mutable local
            // and RHS is a binary op, pass the local's register as a
            // destination hint to genBinOp. This lets the arithmetic
            // instruction write directly to the local's register, avoiding
            // a trailing MOVE (e.g. `s = s + i` → `ADD s, s, i` instead of
            // `ADD tmp, s, i; MOVE s, tmp`). Mirrors PUC `luaK_storevar`
            // VLOCAL → `exp2reg(fs, ex, var->u.var.ridx)`.
            //
            // IMPORTANT: Skip direct-store when the local is captured as an
            // upvalue (boxed). Arithmetic handlers write `regs[a]` directly
            // without syncing the boxed cell, so a captured local would
            // become stale — closures would see the old value. The normal
            // genExp + genSet path uses MOVE, which syncs the cell.
            if (n.lhs[0].node == .Name) {
                const name = n.lhs[0].node.Name.slice(self.source);
                // Skip direct-store when the name is a forced global (declared
                // via `global`). PUC's `luaK_storevar` checks VLOCAL only for
                // non-global names; a `global` declaration makes the name always
                // resolve to _ENV, even if a local with the same name exists
                // in an outer scope.
                if (!self.isForcedGlobalName(name)) {
                    if (self.lookupLocal(name)) |local_reg| {
                    if (!self.isReadonlyLocal(local_reg) and !self.captured_regs.contains(local_reg)) {
                        const store_line = self.spanLastTokenLine(n.rhs[0].span);
                        // Check if RHS is a compile-time nil constant (either
                        // a `nil` literal or a <const> nil local/upvalue).
                        // PUC discharge2reg → luaK_nil emits LOADNIL directly
                        // to the target register, enabling merge across
                        // consecutive nil-to-local assignments.
                        if (self.genConstExpDesc(n.rhs[0])) |ced| {
                            if (ced.val == .nil) {
                                try self.emitLoadNil(local_reg, 1, store_line);
                                return false;
                            }
                        }
                        switch (n.rhs[0].node) {
                            .BinOp => |bn| {
                                const op_line = if (bn.op_line != 0) bn.op_line else n.rhs[0].span.line;
                                if (bn.op != .And and bn.op != .Or and
                                    bn.op != .EqEq and bn.op != .NotEq and
                                    bn.op != .Lt and bn.op != .Lte and
                                    bn.op != .Gt and bn.op != .Gte and
                                    bn.op != .Concat)
                                {
                                    // Arithmetic/bitwise: pass local_reg as hint.
                                    _ = try self.genBinOp(bn, op_line, local_reg);
                                    return false;
                                }
                            },
                            else => {},
                        }
                        // Other RHS: genExp + MOVE (via genSet).
                        const rhs_reg = try self.genExp(n.rhs[0]);
                        try self.genSet(n.lhs[0], .{ .c = rhs_reg, .k = false }, store_line);
                        self.freeReg(rhs_reg);
                        return false;
                    }
                    }
                }
            }
            // PUC exp2RK: for table/field sets, literals go through the
            // constant pool (RK encoding) so SETFIELD/SETI/SETTABLE can
            // fold the value into the C field with k=1 (no LOADK needed).
            // Mirrors PUC lcode.c:luaK_storevar → codeABRK(val) path.
            const is_table_set = switch (n.lhs[0].node) {
                .Index, .Field => true,
                else => false,
            };
            const store_line = self.spanLastTokenLine(n.rhs[0].span);
            if (is_table_set) {
                // Use exp2RK: if RHS is a constant, fold into C field (k=1);
                // otherwise discharge to a register (k=0). This matches
                // PUC's codeABRK which calls exp2RK(val).
                var rhs_ed = try self.genExpDesc(n.rhs[0]);
                const val_rk = try self.exp2RK(&rhs_ed);
                try self.genSet(n.lhs[0], val_rk, store_line);
                if (!val_rk.k) self.freeReg(val_rk.c);
            } else {
                const rhs_reg = try self.genExp(n.rhs[0]);
                try self.genSet(n.lhs[0], .{ .c = rhs_reg, .k = false }, store_line);
                self.freeReg(rhs_reg);
            }
            return false;
        }
        var prepared = std.ArrayListUnmanaged(PreparedLhs).empty;
        defer prepared.deinit(self.alloc);
        for (n.lhs, 0..) |lhs, i| {
            const prepared_lhs = try self.prepareAssignLhs(lhs, line);
            try prepared.append(self.alloc, prepared_lhs);
            // PUC check_conflict: if this LHS is a direct assignment to a
            // local, check whether any previously-prepared indexed LHS uses
            // that local's register as table or key. If so, copy the local
            // to a safe temp so the earlier store sees the original value.
            // Without this, a multi-assign like `a[i], a = i, 1` would
            // overwrite `a` before storing to `a[i]`.
            if (prepared_lhs == .direct) {
                try self.checkAssignConflict(prepared.items, i, lhs, line);
            }
        }
        // Multi-assign: compile RHS into consecutive registers, then assign.
        // PUC explist: first n-1 RHS go through exp2nextreg (discharged to
        // consecutive temps). The last RHS is kept as an ExpDesc and stored
        // directly via luaK_storevar — for a local, this avoids MOVE.
        const base = self.freereg;
        const n_rhs = n.rhs.len;
        const n_lhs = n.lhs.len;
        // Evaluate first n-1 RHS into consecutive registers at base..
        var i: usize = 0;
        while (i + 1 < n_rhs) : (i += 1) {
            _ = try self.genExpNextReg(n.rhs[i]);
        }
        // Last RHS: keep as ExpDesc for direct store (avoids MOVE for locals).
        // If more LHS than RHS, the last RHS must produce multiple values.
        var last_ed: ?ExpDesc = null;
        if (n_lhs > n_rhs) {
            // Last RHS with more LHS than RHS: adjust multi-value.
            const nresults: i32 = @intCast(n_lhs - i);
            const val = n.rhs[i];
            switch (val.node) {
                .Call, .MethodCall => _ = try self.genCall(val, nresults, line),
                .Dots => {
                    const va_reg = try self.allocReg();
                    const c: u8 = @intCast(nresults + 1);
                    _ = try self.builder.emitABC(.vararg, va_reg, 0, c, val.span.line);
                },
                else => _ = try self.genExpNextReg(val),
            }
        } else if (n_rhs > 0) {
            // Equal LHS/RHS: evaluate last RHS as ExpDesc for direct store.
            last_ed = try self.genExpDesc(n.rhs[i]);
            // Don't discharge yet — the reverse store loop will handle it.
        }
        // Nil-fill missing values (only when more LHS than RHS and the
        // last RHS didn't produce enough values via multi-value adjustment).
        if (n_lhs > n_rhs) {
            while (self.freereg < base + n_lhs) {
                const r = try self.allocReg();
                try self.emitLoadNil(r, 1, line);
            }
        }
        // Assign in reverse order (last LHS first), mirroring PUC's
        // storevartop which stores freereg-1 and decrements. Reverse
        // order is essential for multi-assign aliasing correctness:
        // `a[i], a = i, 1` must store to `a` AFTER `a[i]` so the table
        // is still valid when the indexed store fires. PUC's check_conflict
        // only protects earlier indexed LHS from later direct assignments;
        // it does not protect later indexed LHS. Reverse store order
        // ensures later indexed LHS fire before earlier direct assignments.
        {
            var j: usize = n_lhs;
            while (j > 0) {
                j -= 1;
                if (j == n_rhs - 1 and last_ed != null) {
                    // Last RHS: discharge ExpDesc directly. For a local,
                    // exp2anyreg returns the register without MOVE (PUC
                    // luaK_storevar with VLOCAL value). For table LHS,
                    // use exp2RK to fold constants into C field (k=1).
                    var ed = last_ed.?;
                    const is_tbl = prepared.items[j] == .field or prepared.items[j] == .index;
                    if (is_tbl) {
                        const val_rk = try self.exp2RK(&ed);
                        try self.genPreparedSet(prepared.items[j], val_rk);
                        if (!val_rk.k) self.freeReg(val_rk.c);
                    } else {
                        const src_reg = try self.exp2anyreg(&ed);
                        try self.genPreparedSet(prepared.items[j], .{ .c = src_reg, .k = false });
                        self.freeReg(src_reg);
                    }
                } else {
                    const src_reg: u8 = @intCast(base + j);
                    try self.genPreparedSet(prepared.items[j], .{ .c = src_reg, .k = false });
                    self.freeReg(src_reg);
                }
            }
        }
        self.freePreparedLhs(prepared.items);
        self.freereg = base;
        return false;
    }

    fn prepareAssignLhs(self: *Codegen, lhs: *const ast.Exp, line: u32) Error!PreparedLhs {
        return switch (lhs.node) {
            .Field => |n| blk: {
                // Use genExpDesc+exp2anyreg instead of genExp so that a
                // local table object resolves directly to its register
                // (PUC VLOCAL → non-relocatable) without emitting MOVE.
                // Mirrors PUC luaK_indexed: the table expression stays in
                // place when it is already a register value.
                var obj_ed = try self.genExpDesc(n.object);
                const obj = try self.exp2anyreg(&obj_ed);
                const key = try self.builder.internString(n.name.slice(self.source));
                break :blk .{ .field = .{ .object = obj, .key = key, .line = line } };
            },
            .Index => |n| blk: {
                var obj_ed = try self.genExpDesc(n.object);
                const obj = try self.exp2anyreg(&obj_ed);
                // Use genExpDesc+exp2anyreg for the key too, so a local
                // key resolves directly to its register without MOVE
                // (PUC VLOCAL key in VINDEXED).
                var key_ed = try self.genExpDesc(n.index);
                const key = try self.exp2anyreg(&key_ed);
                break :blk .{ .index = .{ .object = obj, .key = key, .line = line } };
            },
            else => .{ .direct = lhs },
        };
    }

    /// PUC check_conflict: when a direct assignment to local `reg` appears
    /// in a multi-assign, any earlier indexed LHS that uses `reg` as its
    /// table or key register must be redirected to a safe copy. Otherwise
    /// the store to the local would overwrite the table/key before the
    /// indexed store executes.
    ///
    /// Mirrors PUC Lua lparser.c:check_conflict. The copy is emitted at
    /// `freereg` (the "extra" position in PUC), and `freereg` is bumped
    /// by one so subsequent LHS preparation sees the correct free slot.
    fn checkAssignConflict(
        self: *Codegen,
        prepared: []PreparedLhs,
        current: usize,
        lhs: *const ast.Exp,
        line: u32,
    ) Error!void {
        // Resolve which local register this direct LHS assigns to.
        // Only locals conflict (globals/upvalues don't share registers).
        const name = switch (lhs.node) {
            .Name => |n| n.slice(self.source),
            else => return,
        };
        const binding = self.lookupLocalBinding(name) orelse return;
        // If a global declaration shadows this local, it's not a local
        // assignment — no register conflict.
        if (self.latestDeclaredGlobalDepthSelf(name)) |gd| {
            if (gd > binding.depth) return;
        }
        const reg = binding.reg;
        const extra = self.freereg;
        var conflict = false;

        // Scan all previously-prepared indexed LHS for register reuse.
        // If a previous indexed LHS uses `reg` as its table or key, the
        // upcoming store to `reg` would clobber it before the indexed
        // store fires. Redirect the previous LHS to a safe copy.
        var j: usize = 0;
        while (j < current) : (j += 1) {
            switch (prepared[j]) {
                .field => {},
                .index => {},
                else => continue,
            }
            // Check table register (both .field and .index have .object).
            const obj_reg = switch (prepared[j]) {
                .field => |f| f.object,
                .index => |idx| idx.object,
                else => unreachable,
            };
            if (obj_reg == reg) {
                conflict = true;
                switch (prepared[j]) {
                    .field => |*f| f.object = @intCast(extra),
                    .index => |*idx| idx.object = @intCast(extra),
                    else => unreachable,
                }
            }
            // Check key register (only .index has a register key).
            if (prepared[j] == .index) {
                const key_reg = prepared[j].index.key;
                if (key_reg == reg) {
                    conflict = true;
                    prepared[j].index.key = @intCast(extra);
                }
            }
        }

        if (conflict) {
            // Copy the local's current value to the safe temp register.
            _ = try self.builder.emitABC(.move, @intCast(extra), reg, 0, line);
            try self.reserveRegs(1);
        }
    }

    fn genPreparedSet(self: *Codegen, lhs: PreparedLhs, val: RK) Error!void {
        switch (lhs) {
            .direct => |e| try self.genSet(e, val, self.line_hint),
            .field => |f| {
                if (f.key <= 255) {
                    _ = try self.builder.emitABCk(.setfield, f.object, @intCast(f.key), val.c, val.k, f.line);
                } else {
                    const key_reg = try self.allocReg();
                    try self.emitLoadK(key_reg, f.key, f.line);
                    _ = try self.builder.emitABCk(.settable, f.object, key_reg, val.c, val.k, f.line);
                    self.freeReg(key_reg);
                }
            },
            .index => |idx| {
                _ = try self.builder.emitABCk(.settable, idx.object, idx.key, val.c, val.k, idx.line);
            },
        }
    }

    fn freePreparedLhs(self: *Codegen, prepared: []const PreparedLhs) void {
        var i = prepared.len;
        while (i > 0) {
            i -= 1;
            switch (prepared[i]) {
                .direct => {},
                .field => |f| self.freeReg(f.object),
                .index => |idx| self.freeReg2(idx.key, idx.object),
            }
        }
    }

    /// Resolve a Name expression to an upvalue index for table-index
    /// fusion (GETTABUP/SETTABUP). Returns null if the name is a local,
    /// a forced global, or not capturable from an enclosing scope.
    /// Mirrors PUC singlevar's upvalue resolution path: locals shadow
    /// upvalues, forced globals are never upvalues, then check existing
    /// upvalues or capture via ensureUpvalue.
    fn upvalIdxForName(self: *Codegen, obj: *const ast.Exp) ?u8 {
        if (obj.node != .Name) return null;
        const name = obj.node.Name.slice(self.source);
        // Locals (including globals shadowing locals) are not upvalues.
        if (self.lookupLocalBinding(name) != null) return null;
        // Forced globals are never upvalues.
        if (self.isForcedGlobalName(name)) return null;
        // Already captured as an upvalue?
        if (self.upvalues.get(name)) |idx| return idx;
        // Try to capture from outer scope (PUC singlevar → markupval).
        if (self.outer != null) {
            return self.ensureUpvalue(name) catch null;
        }
        return null;
    }

    /// Store a value to an lvalue (local, global, table field, table index).
    /// The value is passed as RK encoding: either a register (k=0) or a
    /// constant pool index (k=1). For SET opcodes (SETTABLE, SETI,
    /// SETFIELD, SETTABUP), k=1 folds the constant into the C field,
    /// eliminating a preceding LOADK. Mirrors PUC's `luaK_storevar` +
    /// `codeABRK` (lcode.c:1095, 1105).
    fn genSet(self: *Codegen, lhs: *const ast.Exp, val: RK, line: u32) Error!void {
        const val_reg = val.c;
        switch (lhs.node) {
            .Name => |n| {
                const name = n.slice(self.source);
                if (self.isForcedGlobalName(name)) {
                    try self.checkDeclaredGlobal(lhs.span, name);
                    if (self.isConstGlobal(name)) {
                        self.setDiagFmt(lhs.span, "attempt to assign to const variable '{s}'", .{name});
                        return error.CodegenError;
                    }
                    const kid = try self.builder.internString(name);
                    try self.emitGlobalSet(kid, val, line);
                    return;
                }
                if (self.lookupLocal(name)) |reg| {
                    if (self.isReadonlyLocal(reg)) {
                        self.setDiagFmt(lhs.span, "attempt to assign to const variable '{s}'", .{name});
                        return error.CodegenError;
                    }
                    // MOVE requires a register. If val is a constant (k=1),
                    // materialize it to a temp register first.
                    if (val.k) {
                        const tmp = try self.allocReg();
                        try self.emitLoadK(tmp, val_reg, line);
                        _ = try self.builder.emitABC(.move, reg, tmp, 0, line);
                        self.freeReg(tmp);
                    } else {
                        _ = try self.builder.emitABC(.move, reg, val_reg, 0, line);
                    }
                    return;
                }
                if (self.upvalues.get(name)) |idx| {
                    if (self.isConstUpvalue(idx)) {
                        self.setDiagFmt(lhs.span, "attempt to assign to const variable '{s}'", .{name});
                        return error.CodegenError;
                    }
                    // SETUPVAL requires a register. If val is a constant (k=1),
                    // materialize it to a temp register first.
                    if (val.k) {
                        const tmp = try self.allocReg();
                        try self.emitLoadK(tmp, val_reg, line);
                        _ = try self.builder.emitABC(.setupval, tmp, idx, 0, line);
                        self.freeReg(tmp);
                    } else {
                        _ = try self.builder.emitABC(.setupval, val_reg, idx, 0, line);
                    }
                    return;
                }
                // Try to capture from outer scope (the variable may only
                // be written, never read, so ensureUpvalue wasn't called yet).
                if (self.outer != null) {
                    if (self.ensureUpvalue(name)) |idx| {
                        if (self.isConstUpvalue(idx)) {
                            self.setDiagFmt(lhs.span, "attempt to assign to const variable '{s}'", .{name});
                            return error.CodegenError;
                        }
                        if (val.k) {
                            const tmp = try self.allocReg();
                            try self.emitLoadK(tmp, val_reg, line);
                            _ = try self.builder.emitABC(.setupval, tmp, idx, 0, line);
                            self.freeReg(tmp);
                        } else {
                            _ = try self.builder.emitABC(.setupval, val_reg, idx, 0, line);
                        }
                        return;
                    } else |_| {}
                }
                // Global: _ENV[name] = val
                try self.checkDeclaredGlobal(lhs.span, name);
                if (self.isConstGlobal(name)) {
                    self.setDiagFmt(lhs.span, "attempt to assign to const variable '{s}'", .{name});
                    return error.CodegenError;
                }
                const kid = try self.builder.internString(name);
                try self.emitGlobalSet(kid, val, line);
            },
            .Field => |n| {
                // t.k = val  →  SETFIELD R[t] K[k] RK[val]
                //           or  SETTABUP UpVal[t] K[k] RK[val]  (t is upvalue)
                if (self.tryVarargParamReg(n.object) != null) {
                    if (self.varargIsVirtual()) {
                        self.needVarargTable();
                    }
                }
                var obj_ed = try self.genExpDesc(n.object);
                if (obj_ed.val == .upval) {
                    const kid = try self.builder.internString(n.name.slice(self.source));
                    if (kid <= 255) {
                        _ = try self.builder.emitABCk(.settabup, @intCast(obj_ed.val.upval), @intCast(kid), val_reg, val.k, line);
                        return;
                    }
                }
                const obj = try self.exp2anyreg(&obj_ed);
                const kid = try self.builder.internString(n.name.slice(self.source));
                if (kid <= 255) {
                    _ = try self.builder.emitABCk(.setfield, obj, @intCast(kid), val_reg, val.k, line);
                } else {
                    const key_reg = try self.allocReg();
                    try self.emitLoadK(key_reg, kid, line);
                    _ = try self.builder.emitABCk(.settable, obj, key_reg, val_reg, val.k, line);
                    self.freeReg(key_reg);
                }
                self.freeReg(obj);
            },
            .Index => |n| {
                // t[k] = val  →  SETI R[t] K[int] RK[val]  (integer key)
                //             or  SETTABUP UpVal[t] K[k] RK[val]  (upvalue + string key)
                //             or  SETTABLE R[t] R[k] RK[val]  (computed key)
                if (self.tryVarargParamReg(n.object) != null) {
                    if (self.varargIsVirtual()) {
                        self.needVarargTable();
                    }
                }
                var key_ed = try self.genExpDesc(n.index);
                if (key_ed.val == .k_int) {
                    const ival = key_ed.val.k_int;
                    if (ival >= 0 and ival <= 255) {
                        var obj_ed = try self.genExpDesc(n.object);
                        const obj = try self.exp2anyreg(&obj_ed);
                        _ = try self.builder.emitABCk(.seti, obj, @intCast(ival), val_reg, val.k, line);
                        self.freeReg(obj);
                        return;
                    }
                }
                if (key_ed.val == .k_str) {
                    const kid = try self.builder.internString(key_ed.val.k_str);
                    if (kid <= 255) {
                        var obj_ed = try self.genExpDesc(n.object);
                        if (obj_ed.val == .upval) {
                            _ = try self.builder.emitABCk(.settabup, @intCast(obj_ed.val.upval), @intCast(kid), val_reg, val.k, line);
                            return;
                        }
                        const obj = try self.exp2anyreg(&obj_ed);
                        _ = try self.builder.emitABCk(.setfield, obj, @intCast(kid), val_reg, val.k, line);
                        self.freeReg(obj);
                        return;
                    }
                }
                const key = try self.exp2anyreg(&key_ed);
                var obj_ed = try self.genExpDesc(n.object);
                const obj = try self.exp2anyreg(&obj_ed);
                _ = try self.builder.emitABCk(.settable, obj, key, val_reg, val.k, line);
                self.freeReg(key);
                self.freeReg(obj);
            },
            else => {
                self.setDiag(lhs.span, "invalid assignment target");
                return error.CodegenError;
            },
        }
    }

    fn genReturn(self: *Codegen, n: anytype, line: u32) Error!bool {
        // RETURN's B field stores result_count + 1 in one byte. PUC rejects
        // fixed returns above 254 values at compile time instead of allowing
        // an integer cast panic in the compiler.
        if (n.values.len > 254) {
            self.setDiag(.{ .start = 0, .end = 0, .line = line, .col = 0 }, "too many returns");
            return error.CodegenError;
        }

        if (n.values.len == 0) {
            _ = try self.builder.emitSimple(.return0, line);
        } else if (n.values.len == 1) {
            // PUC Lua: `return f(args)` is a tail call.
            switch (n.values[0].node) {
                .Call, .MethodCall => {
                    // A return that leaves a live <close> variable is not a
                    // tail call in PUC Lua. The current frame must survive
                    // until the callee returns so OP_RETURN can run its TBC
                    // close chain exactly once. Emitting TAILCALL here would
                    // replay a yielding callee when the frame is resumed.
                    if (self.hasActiveClose()) {
                        const base = try self.genCall(n.values[0], -1, line);
                        _ = try self.builder.emitABC(.return_, base, 0, 0, line);
                        return true;
                    }
                    return self.genTailCall(n.values[0], line);
                },
                .Dots => {
                    // `return ...` — multi-value: VARARG with C=0 (all),
                    // then RETURN with B=0 (set top).
                    if (!self.is_vararg) {
                        self.setDiag(n.values[0].span, "vararg used in non-vararg function");
                        return error.CodegenError;
                    }
                    const reg = try self.allocReg();
                    _ = try self.builder.emitABC(.vararg, reg, 0, 0, line);
                    _ = try self.builder.emitABC(.return_, reg, 0, 0, line);
                    self.freeReg(reg);
                },
                else => {
                    // PUC Lua luaK_exp2anyreg: discharge to any register.
                    // For non-captured locals returns the local's register
                    // directly (no MOVE); for captured locals emits MOVE to
                    // sync cell.value → stack.
                    var ed = try self.genExpDesc(n.values[0]);
                    const reg = try self.exp2anyreg(&ed);
                    _ = try self.builder.emitABC(.return1, reg, 0, 0, line);
                    self.freeReg(reg);
                },
            }
        } else {
            // Multiple values. If last is call/vararg, it's not a pure tail call
            // (there are preceding values), so use CALL+RETURN.
            const last = n.values[n.values.len - 1];
            switch (last.node) {
                .Call, .MethodCall => {
                    for (n.values[0 .. n.values.len - 1]) |val| {
                        _ = try self.genExpNextReg(val);
                    }
                    _ = try self.genCall(last, -1, line);
                    _ = try self.builder.emitABC(.return_, self.nvarstack, 0, 0, line);
                },
                .Dots => {
                    // `return a, b, ...` — preceding values compiled normally,
                    // then VARARG C=0 (all) and RETURN B=0 (set top).
                    if (!self.is_vararg) {
                        self.setDiag(last.span, "vararg used in non-vararg function");
                        return error.CodegenError;
                    }
                    const ret_base = self.freereg;
                    for (n.values[0 .. n.values.len - 1]) |val| {
                        _ = try self.genExpNextReg(val);
                    }
                    const va_reg = try self.allocReg();
                    _ = try self.builder.emitABC(.vararg, va_reg, 0, 0, line);
                    _ = try self.builder.emitABC(.return_, ret_base, 0, 0, line);
                },
                else => {
                    const base = self.freereg;
                    for (n.values) |val| {
                        _ = try self.genExpNextReg(val);
                    }
                    const count: u8 = @intCast(n.values.len + 1);
                    _ = try self.builder.emitABC(.return_, base, count, 0, line);
                },
            }
        }
        return true;
    }

    /// Emit a tail call: `return f(args)` → TAILCALL opcode.
    /// PUC-like: no RETURN follows, the frame is reused.
    fn genTailCall(self: *Codegen, e: *const ast.Exp, line: u32) Error!bool {
        // Dispatch to a tail-call variant of genMethodCall if needed.
        if (e.node == .MethodCall) {
            const mc = e.node.MethodCall;
            const call_line = if (mc.call_line != 0) mc.call_line else line;
            // SELF writes to obj_reg and obj_reg+1 — move to a temp if the
            // receiver is a local to avoid clobbering it.
            var obj_reg = try self.genExp(mc.receiver);
            if (obj_reg < self.nvarstack) {
                const tmp = try self.allocReg();
                _ = try self.builder.emitABC(.move, tmp, obj_reg, 0, call_line);
                obj_reg = tmp;
            }
            const kid = try self.builder.internString(mc.method.slice(self.source));
            if (kid <= 255) {
                _ = try self.builder.emitABC(.self, obj_reg, obj_reg, @intCast(kid), call_line);
            } else {
                const key = try self.allocReg();
                try self.emitLoadK(key, kid, call_line);
                const method_reg = try self.allocReg();
                _ = try self.builder.emitABC(.gettable, method_reg, obj_reg, key, call_line);
                _ = try self.builder.emitABC(.move, obj_reg + 1, obj_reg, 0, call_line);
                _ = try self.builder.emitABC(.move, obj_reg, method_reg, 0, call_line);
                self.freeReg2(method_reg, key);
            }
            self.freereg = obj_reg + 2;
            if (obj_reg + 2 > self.peak_freereg) self.peak_freereg = obj_reg + 2;
            self.syncLiveTop();
            // Args must be consecutive after obj_reg+1 (self).
            for (mc.args, 0..) |arg, i| {
                const expected: u8 = @intCast(@as(usize, obj_reg) + 2 + i);
                self.freereg = expected;
                const is_last = (i + 1 == mc.args.len);
                if (is_last) {
                    switch (arg.node) {
                        .Call, .MethodCall => _ = try self.genCallMulti(arg, line),
                        .Dots => {
                            const va_reg = try self.allocReg();
                            _ = try self.builder.emitABC(.vararg, va_reg, 0, 0, arg.span.line);
                        },
                        else => {
                            const r = try self.genExp(arg);
                            if (r != expected) {
                                try self.ensureFreeregAtLeast(expected + 1);
                                _ = try self.builder.emitABC(.move, expected, r, 0, arg.span.line);
                            }
                        },
                    }
                } else {
                    const r = try self.genExp(arg);
                    if (r != expected) {
                        try self.ensureFreeregAtLeast(expected + 1);
                        _ = try self.builder.emitABC(.move, expected, r, 0, arg.span.line);
                    }
                }
            }
            const has_multret_last = mc.args.len > 0 and switch (mc.args[mc.args.len - 1].node) {
                .Call, .MethodCall, .Dots => true,
                else => false,
            };
            const b: u8 = if (has_multret_last) 0 else @intCast(mc.args.len + 2);
            _ = try self.builder.emitABC(.tailcall, obj_reg, b, 0, call_line);
            return true;
        }

        const call_node = switch (e.node) {
            .Call => |c| c,
            else => unreachable,
        };
        const call_line = if (call_node.call_line != 0) call_node.call_line else line;

        // Compile function expression into a register.
        // TAILCALL reuses the frame starting at func_reg, so if the function
        // is a local (returned directly by genExp), MOVE it to a temp.
        var func_reg = try self.genExp(call_node.func);
        if (func_reg < self.nvarstack) {
            const tmp = try self.allocReg();
            _ = try self.builder.emitABC(.move, tmp, func_reg, 0, call_line);
            func_reg = tmp;
        }
        self.freereg = func_reg + 1;
        for (call_node.args, 0..) |arg, i| {
            const expected: u8 = @intCast(@as(usize, func_reg) + 1 + i);
            self.freereg = expected;
            const is_last = (i + 1 == call_node.args.len);
            if (is_last) {
                switch (arg.node) {
                    .Call, .MethodCall => _ = try self.genCallMulti(arg, line),
                    .Dots => {
                        if (!self.is_vararg) {
                            self.setDiag(arg.span, "vararg used in non-vararg function");
                            return error.CodegenError;
                        }
                        const va_reg = try self.allocReg();
                        _ = try self.builder.emitABC(.vararg, va_reg, 0, 0, arg.span.line);
                    },
                    else => {
                        const r = try self.genExp(arg);
                        if (r != expected) {
                            try self.ensureFreeregAtLeast(expected + 1);
                            _ = try self.builder.emitABC(.move, expected, r, 0, arg.span.line);
                        }
                    },
                }
            } else {
                const r = try self.genExp(arg);
                if (r != expected) {
                    try self.ensureFreeregAtLeast(expected + 1);
                    _ = try self.builder.emitABC(.move, expected, r, 0, arg.span.line);
                }
            }
        }

        const has_multret_last = call_node.args.len > 0 and switch (call_node.args[call_node.args.len - 1].node) {
            .Call, .MethodCall, .Dots => true,
            else => false,
        };
        const b: u8 = if (has_multret_last) 0 else @intCast(call_node.args.len + 1);
        _ = try self.builder.emitABC(.tailcall, func_reg, b, 0, call_line);
        return true;
    }

    fn genIf(self: *Codegen, n: anytype, line: u32) Error!bool {
        _ = line;
        // Collect all JMP-to-end instructions (one per non-empty branch).
        var end_jumps: std.ArrayListUnmanaged(u32) = .empty;
        defer end_jumps.deinit(self.alloc);

        // PUC attributes the branch-control instructions to the condition,
        // not to the opening `if` token. This is observable through line hooks
        // when a multiline condition starts below the `if` keyword.
        const cond_line = n.cond.span.line;
        const saved_hint = self.line_hint;
        self.line_hint = cond_line;

        // Compile condition in condition context (VJMP for comparisons,
        // jump-list-merge for and/or). goIfTrue produces a true-list
        // (jumps to here if true → then-branch entry) and a false-list
        // (jumps if false → else-branch). PUC `ifstat` uses `goiftrue`.
        var cond_ed = try self.genExpCond(n.cond);
        try self.goIfTrue(&cond_ed);
        self.line_hint = saved_hint;
        // cond_ed.t_list was patched to here (then-branch entry) by goIfTrue.
        // cond_ed.f_list holds the false-jumps → patch to else-branch later.

        // Then block.
        try self.genBlock(n.then_block);

        // JMP to end (if there are elseif/else branches).
        if (n.else_block != null or n.elseifs.len > 0) {
            const then_line = if (n.then_block.stats.len != 0)
                n.then_block.stats[n.then_block.stats.len - 1].span.line
            else
                cond_line;
            const ej = try self.emitJump(then_line);
            end_jumps.append(self.alloc, ej) catch @panic("oom");
        }

        // Else target: false-list jumps here.
        self.patchListToHere(cond_ed.f_list);
        cond_ed.f_list = 0;

        // Elseifs.
        for (n.elseifs) |eif| {
            const eif_cond_line = eif.cond.span.line;
            const eif_saved_hint = self.line_hint;
            self.line_hint = eif_cond_line;
            var eif_ed = try self.genExpCond(eif.cond);
            try self.goIfTrue(&eif_ed);
            self.line_hint = eif_saved_hint;
            try self.genBlock(eif.block);
            // Each elseif needs its own JMP to end. Keep it on the final
            // source line of that branch so the synthetic control transfer does
            // not introduce a spurious line-hook event at the opening `if`.
            const branch_line = if (eif.block.stats.len != 0)
                eif.block.stats[eif.block.stats.len - 1].span.line
            else
                eif_cond_line;
            const ej = try self.emitJump(branch_line);
            end_jumps.append(self.alloc, ej) catch @panic("oom");
            self.patchListToHere(eif_ed.f_list);
            eif_ed.f_list = 0;
        }

        // Else block.
        if (n.else_block) |b| {
            try self.genBlock(b);
        }

        // End target: patch all JMP-to-end instructions to here.
        for (end_jumps.items) |ej| {
            self.patchJumpToHere(ej);
        }
        return false;
    }

    fn genWhile(self: *Codegen, n: anytype, line: u32) Error!bool {
        _ = line;
        // Loop start.
        const loop_start = self.builder.pc();

        // Condition: compile in condition context (VJMP for comparisons).
        // goIfTrue produces a false-list (jumps to here if false → loop end)
        // and patches the true-list to here (body entry). For `while`,
        // false = exit, so we want "jump if false" = goIfTrue.
        const cond_line = n.cond.span.line;
        const saved_hint = self.line_hint;
        self.line_hint = cond_line;
        var cond_ed = try self.genExpCond(n.cond);
        try self.goIfTrue(&cond_ed);
        self.line_hint = saved_hint;
        // cond_ed.t_list was patched to here (body entry) by goIfTrue.
        // cond_ed.f_list holds the false-jumps → patch to loop end later.

        // Reset temporaries before entering the body.  The condition may
        // have used temp registers that freeReg couldn't fully release
        // (e.g. comparison results).  Without this reset, the first body
        // statement would allocate locals at wrong registers on the second
        // and subsequent iterations, breaking upvalue capture.
        self.resetRegs();

        // Body.
        try self.pushScope();
        const scope_mark = self.scope_marks.items[self.scope_marks.items.len - 1];
        // Breaks need their own cleanup path: close body locals, then exit.
        // They must not jump to the normal back-edge, otherwise `break` would
        // close locals and continue the loop.
        try self.pushLoopEnd(0);
        const break_slot = self.loop_ends.items.len - 1;
        try self.genBlockNoScope(n.block, false);
        const break_jump_pc = self.loop_ends.items[break_slot].pc;
        self.popLoopEnd();

        const first_body_reg: ?u8 = if (self.bindings.items.len > scope_mark)
            self.bindings.items[scope_mark].reg
        else
            null;
        const body_line = if (n.block.stats.len != 0)
            self.spanLastTokenLine(n.block.stats[n.block.stats.len - 1].span)
        else
            n.cond.span.line;

        // PUC attributes the loop backedge (and its lexical cleanup) to the
        // final statement in the body. Marking it as the condition line would
        // create two line events at the head of every later iteration.
        // Only emit CLOSE if body locals were captured as upvalues.
        if (first_body_reg) |reg| {
            if (self.anyCapturedInRange(reg, self.nvarstack)) {
                _ = try self.builder.emitABC(.close, reg, 0, 0, body_line);
            }
        }

        // JMP back to start.
        const back_jmp = try self.emitJump(body_line);
        const offset: i32 = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(back_jmp)) - 1;
        self.builder.patchJumpOffset(back_jmp, offset);

        // Break cleanup path: close body locals (if captured), then fall
        // through to loop end. Falsy condition jumps directly to end and
        // does not enter the body scope, so it does not need this cleanup.
        const break_cleanup = self.builder.pc();
        if (first_body_reg) |reg| {
            if (self.anyCapturedInRange(reg, self.nvarstack)) {
                _ = try self.builder.emitABC(.close, reg, 0, 0, body_line);
            }
        }
        if (break_jump_pc != 0) {
            self.patchJumpTo(break_jump_pc, break_cleanup);
        }
        self.popScopeNoClear();

        // End target: false-list jumps here (condition is false → exit loop).
        self.patchListToHere(cond_ed.f_list);
        cond_ed.f_list = 0;
        return false;
    }

    fn genRepeat(self: *Codegen, n: anytype, line: u32) Error!bool {
        _ = line;
        // repeat...until: body executes first, then condition is checked.
        // The condition can see locals from the body.
        // Loop continues while condition is FALSE; exits when TRUE.
        //
        // PUC repeatstat (lparser.c:1602-1624): compiles the body, then
        // calls `cond(ls)` which uses `luaK_goiftrue` — producing a
        // false-list (jumps taken when the condition is false → loop back).
        // The true-path falls through to the exit. `luaK_patchlist(condexit,
        // repeat_init)` patches the false-list to the loop start. When the
        // condition is a constant true (e.g. `until true`), goiftrue sets
        // the false-list to NO_JUMP — no loop-back is emitted at all,
        // folding `repeat ... until true` to a single-pass body.
        const loop_start = self.builder.pc();

        try self.pushScope();
        try self.pushLoopEnd(0); // break target — will be patched
        const break_jmp_slot = self.loop_ends.items.len - 1;

        try self.genBlockNoScope(n.block, true);

        // Condition (can see body's locals — don't pop scope yet).
        // goIfTrue produces a false-list (jumps if false → loop back) and
        // patches the true-list to here (true → fall through to exit).
        // For a constant-true condition (e.g. `until true`), the false-list
        // is empty — no loop-back jump is emitted (PUC goiftrue VTRUE case).
        const cond_line = n.cond.span.line;
        const saved_hint = self.line_hint;
        self.line_hint = cond_line;
        var cond_ed = try self.genExpCond(n.cond);
        try self.goIfTrue(&cond_ed);
        self.line_hint = saved_hint;
        // cond_ed.t_list was patched to here (exit) by goIfTrue.
        // cond_ed.f_list holds the false-jumps → loop back.

        // PUC repeatstat upvalue handling (lparser.c:1615-1622):
        // When body locals are captured as upvalues, both the repetition
        // (false) and exit (true) paths need CLOSE. The structure is:
        //   exit = JMP (skip CLOSE on normal exit)
        //   false-list → here (CLOSE)
        //   CLOSE
        //   condexit = JMP (loop back after CLOSE)
        //   exit → here (after CLOSE)
        // Then condexit (the new loop-back) is patched to repeat_init.
        // When no upvalues are captured, condexit stays as the original
        // false-list and is patched directly to repeat_init.
        const scope_mark = self.scope_marks.items[self.scope_marks.items.len - 1];
        const first_body_reg: ?u8 = if (self.bindings.items.len > scope_mark)
            self.bindings.items[scope_mark].reg
        else
            null;
        const has_upval = if (first_body_reg) |first_reg|
            self.anyCapturedInRange(first_reg, self.nvarstack)
        else
            false;

        if (has_upval) {
            // PUC leaveblock(bl2) emits CLOSE for the exit path first.
            // The body always executes at least once in repeat-until, so
            // captured upvalues must be closed on exit.
            _ = try self.builder.emitABC(.close, first_body_reg.?, 0, 0, cond_line);
            // Exit jumps over the false-path CLOSE + loop-back.
            const exit_jmp = try self.emitJump(cond_line);
            // False-list lands on CLOSE (close upvalues before looping back).
            self.patchListToHere(cond_ed.f_list);
            cond_ed.f_list = 0;
            _ = try self.builder.emitABC(.close, first_body_reg.?, 0, 0, cond_line);
            // New loop-back after CLOSE.
            const loop_back = try self.emitJump(cond_line);
            const offset: i32 = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(loop_back)) - 1;
            self.builder.patchJumpOffset(loop_back, offset);
            // Exit lands after the loop-back.
            self.patchJumpToHere(exit_jmp);
        } else if (cond_ed.f_list != 0) {
            // No upvalues: patch false-list directly to loop_start.
            // When the condition is a constant true, f_list is empty — no
            // loop-back is emitted at all (folds to single-pass).
            var cur: i32 = cond_ed.f_list;
            while (cur != 0) {
                const next_opt = self.builder.getJumpTarget(@intCast(cur));
                self.patchJumpTo(@intCast(cur), loop_start);
                cur = if (next_opt) |nx| @intCast(nx) else 0;
            }
            cond_ed.f_list = 0;
        }

        // Break target.
        const break_target = self.builder.pc();
        if (self.loop_ends.items[break_jmp_slot].pc != 0) {
            self.patchJumpTo(self.loop_ends.items[break_jmp_slot].pc, break_target);
        }

        self.loop_ends.items.len -= 1;
        self.popScopeNoClear();
        return false;
    }

    fn genBreak(self: *Codegen, line: u32) Error!bool {
        const loop = self.currentLoopEnd() orelse {
            self.setDiag(.{ .start = 0, .end = 0, .line = line, .col = 0 }, "'break' outside loop");
            return error.CodegenError;
        };
        // Emit JMP — will be patched when the loop ends.
        const jmp_pc = try self.emitJump(line);
        // Update the loop's break jump target.
        // We store the first break jump PC; subsequent breaks chain via patching.
        // For simplicity, we patch each break individually when the loop ends.
        // The loop_end slot stores the first break's PC.
        if (loop.pc == 0) {
            self.loop_ends.items[self.loop_ends.items.len - 1].pc = jmp_pc;
        } else {
            // Chain: patch this break to jump to the previous break's target.
            // Actually, we need a list. For now, patch to the same target later.
            // This is a simplification — full implementation would use a list.
            self.patchJumpTo(jmp_pc, loop.pc);
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // For-loops (PUC-style: FORPREP/FORLOOP, TFORPREP/TFORCALL/TFORLOOP)
    // -----------------------------------------------------------------------

    fn genForNumeric(self: *Codegen, n: anytype, line: u32) Error!bool {
        // PUC layout: R[base]=init, R[base+1]=limit, R[base+2]=step,
        // R[base+3]=loop variable.
        try self.pushScope();
        defer self.popScope();

        // Compile init, limit, step into consecutive registers.
        const base = self.freereg;
        _ = try self.genExpNextReg(n.init);
        _ = try self.genExpNextReg(n.limit);
        if (n.step) |s| {
            _ = try self.genExpNextReg(s);
        } else {
            // Default step = 1.
            const step_reg = try self.allocReg();
            _ = try self.builder.emit(Instruction.loadImm(.loadi, step_reg, 1), line);
        }

        // PUC Lua 5.5 records two hidden numeric-for locals, both named
        // "(for state)".  Keep that metadata in Proto instead of inferring
        // control values from the live register file in debug.getlocal.
        const hidden_start_pc = self.builder.pc();
        const state_locvar_1 = try self.builder.addLocVar("(for state)", base, hidden_start_pc);
        const state_locvar_2 = try self.builder.addLocVar("(for state)", base + 1, hidden_start_pc);

        // Declare loop variable at base+3.  Its debug range starts at the loop
        // body, not while FORPREP is still setting up the control tuple.
        self.freereg = base + 3;
        self.nvarstack = base + 3;
        if (self.peak_freereg < base + 3) self.peak_freereg = base + 3;
        self.syncLiveTop();
        const loop_binding_mark = self.bindings.items.len;
        const loop_var = try self.declareLocal(n.name.slice(self.source));
        self.markReadonlyLocal(loop_var);

        // FORPREP A offset: A=base, offset in B:C (16-bit signed).
        const forprep_pc = try self.builder.emitABC(.forprep, base, 0, 0, line);
        self.builder.locvars.items[state_locvar_1].startpc = forprep_pc;
        self.builder.locvars.items[state_locvar_2].startpc = forprep_pc;

        // Loop body.
        const body_start = self.builder.pc();
        const loop_locvar = self.bindings.items[loop_binding_mark].locvar_index;
        self.builder.locvars.items[loop_locvar].startpc = body_start;
        try self.pushScope();
        try self.pushLoopEnd(0); // break target — patched later
        const break_slot = self.loop_ends.items.len - 1;
        try self.genBlock(n.block);
        // Save break jump PC for patching AFTER CLOSE+FORLOOP.
        const break_jump_pc = self.loop_ends.items[break_slot].pc;
        self.popLoopEnd();
        self.popScope();

        // Close upvalues for locals declared in the loop body (if any were
        // captured by nested closures).  PUC Lua's leaveblock() emits OP_CLOSE
        // only when `bl->firstlabel` indicates upvalues are still open; we
        // gate on captured_regs for the same effect.  Without this check,
        // every numeric-for iteration emits a no-op CLOSE that clobbers the
        // hot loop (e.g. `s = s + i` in int_arith).
        if (self.anyCapturedInRange(base + 3, self.nvarstack)) {
            _ = try self.builder.emitABC(.close, base + 3, 0, 0, line);
        }

        // FORLOOP A offset: A=base, offset in B:C.
        const forloop_pc = try self.builder.emitABC(.forloop, base, 0, 0, line);
        self.builder.closeLocVar(loop_locvar, forloop_pc);
        const loop_offset: i32 = @as(i32, @intCast(body_start)) - @as(i32, @intCast(forloop_pc)) - 1;
        patchForJumpOffset(&self.builder, forloop_pc, loop_offset);

        // Patch FORPREP to skip to here if loop shouldn't run.
        const end_pc = self.builder.pc();
        const prep_offset: i32 = @as(i32, @intCast(end_pc)) - @as(i32, @intCast(forprep_pc)) - 1;
        patchForJumpOffset(&self.builder, forprep_pc, prep_offset);

        // Patch break to jump past FORLOOP (to end_pc).
        if (break_jump_pc != 0) {
            self.patchJumpTo(break_jump_pc, end_pc);
        }

        self.builder.closeLocVar(state_locvar_1, end_pc);
        self.builder.closeLocVar(state_locvar_2, end_pc);

        return false;
    }

    fn genForGeneric(self: *Codegen, n: anytype, line: u32) Error!bool {
        // PUC layout: R[base]=iterator, R[base+1]=state, R[base+2]=control,
        // R[base+3]=close value (to-be-closed), R[base+4..]=loop variables.
        try self.pushScope();
        defer self.popScope();

        // Compile explist into 4 values (iterator, state, control, close).
        // If fewer than 4 expressions, nil-fill. If more, discard extras.
        const base = self.freereg;
        try self.genExplistFixed(n.exps, 4, line);
        self.freereg = base + 4;
        self.nvarstack = base + 4;
        if (self.peak_freereg < base + 4) self.peak_freereg = base + 4;
        self.syncLiveTop();

        // PUC Lua records three hidden generic-for locals: iterator, state,
        // and the closing value.  The internal control register at base+2 is
        // not a debug local; the source-level loop variables start at base+4.
        const hidden_start_pc = self.builder.pc();
        const iterator_locvar = try self.builder.addLocVar("(for state)", base, hidden_start_pc);
        const state_locvar = try self.builder.addLocVar("(for state)", base + 1, hidden_start_pc);
        const close_locvar = try self.builder.addLocVar("(for state)", base + 3, hidden_start_pc);

        // Mark the 4th value (close) as to-be-closed. It is a hidden
        // register rather than a Binding, so scope-exiting gotos must track it
        // explicitly when deciding the lowest OP_CLOSE level.
        _ = try self.builder.emitABC(.tbc, base + 3, 0, 0, line);
        self.markCurrentScopeClose(base + 3);

        // Declare loop variables at base+4, base+5, ... Their LocVar
        // ranges are adjusted below to begin only after the first iterator
        // call has produced values and control enters the loop body.
        self.freereg = base + 4;
        self.nvarstack = base + 4;
        if (self.peak_freereg < base + 4) self.peak_freereg = base + 4;
        self.syncLiveTop();
        const loop_binding_mark = self.bindings.items.len;
        for (n.names) |nm| {
            _ = try self.declareLocal(nm.slice(self.source));
        }
        // First loop variable is const (control variable).
        if (n.names.len > 0) {
            self.markReadonlyLocal(base + 4);
        }

        // TFORPREP A offset: A=base, offset in B:C.
        const tforprep_pc = try self.builder.emitABC(.tforprep, base, 0, 0, line);
        self.builder.locvars.items[iterator_locvar].startpc = tforprep_pc;
        self.builder.locvars.items[state_locvar].startpc = tforprep_pc;
        self.builder.locvars.items[close_locvar].startpc = tforprep_pc;

        // Loop body.
        const body_start = self.builder.pc();
        for (self.bindings.items[loop_binding_mark..]) |binding| {
            self.builder.locvars.items[binding.locvar_index].startpc = body_start;
        }
        try self.pushScope();
        try self.pushLoopEnd(0);
        const break_slot = self.loop_ends.items.len - 1;
        try self.genBlock(n.block);
        const break_jump_pc = self.loop_ends.items[break_slot].pc;
        self.popLoopEnd();
        self.popScope();

        // Close upvalues for locals declared in the loop body (if any were
        // captured by nested closures).
        if (self.anyCapturedInRange(base + 4, self.nvarstack)) {
            _ = try self.builder.emitABC(.close, base + 4, 0, 0, line);
        }

        // TFORCALL reports errors at the iterator expression, which can start
        // on a later line than the `for ... in` header itself.
        const iterator_line = if (n.exps.len != 0) n.exps[0].span.line else line;
        const n_results: u8 = @intCast(n.names.len + 1);
        const tforcall_pc = try self.builder.emitABC(.tforcall, base, 0, n_results, iterator_line);
        for (self.bindings.items[loop_binding_mark..]) |binding| {
            self.builder.closeLocVar(binding.locvar_index, tforcall_pc);
        }

        // TFORLOOP A offset: A=base+2, offset in B:C.
        // PUC convention: if R[A+2] (=R[base+4], first result) != nil,
        // then R[A] (=R[base+2], control) = R[A+2]; pc -= offset.
        const tforloop_pc = try self.builder.emitABC(.tforloop, base + 2, 0, 0, line);
        const loop_offset: i32 = @as(i32, @intCast(body_start)) - @as(i32, @intCast(tforloop_pc)) - 1;
        patchForJumpOffset(&self.builder, tforloop_pc, loop_offset);

        // Close the TBC variable (R[base+3]) on loop exit.
        // This runs both on normal exit (TFORLOOP falls through) and
        // on break (break jumps here). PUC Lua closes the TBC upvalue
        // when the block scope ends (leaveblock → luaF_close).
        const close_tbc_pc = self.builder.pc();
        _ = try self.builder.emitABC(.close, base + 3, 0, 0, line);

        // Patch TFORPREP to the iterator call.
        const prep_offset: i32 = @as(i32, @intCast(tforcall_pc)) - @as(i32, @intCast(tforprep_pc)) - 1;
        patchForJumpOffset(&self.builder, tforprep_pc, prep_offset);

        // Patch break to jump to the CLOSE (so __close runs on break).
        if (break_jump_pc != 0) {
            self.patchJumpTo(break_jump_pc, close_tbc_pc);
        }

        const end_pc = self.builder.pc();
        self.builder.closeLocVar(iterator_locvar, end_pc);
        self.builder.closeLocVar(state_locvar, end_pc);
        self.builder.closeLocVar(close_locvar, end_pc);

        return false;
    }

    // -----------------------------------------------------------------------
    // Block compilation
    // -----------------------------------------------------------------------

    fn genBlock(self: *Codegen, block: *const ast.Block) Error!void {
        try self.pushScope();
        var terminated = false;
        for (block.stats, 0..) |*st, stat_index| {
            self.label_has_code_after = true;
            if (st.node == .Label) {
                var next_index = stat_index + 1;
                self.label_has_code_after = false;
                while (next_index < block.stats.len) : (next_index += 1) {
                    if (block.stats[next_index].node != .Label) {
                        self.label_has_code_after = true;
                        break;
                    }
                }
            }

            if (terminated) {
                // After a terminating statement (return/goto/break), only
                // process labels (for goto resolution) — skip all other
                // statements since they're unreachable. A label resets
                // terminated because code after it is reachable via goto.
                switch (st.node) {
                    .Label => {
                        _ = try self.genStat(st);
                        terminated = false;
                    },
                    else => {},
                }
            } else {
                terminated = try self.genStat(st);
            }
        }
        self.popScope();
    }

    fn genBlockNoScope(self: *Codegen, block: *const ast.Block, has_postlude: bool) Error!void {
        for (block.stats, 0..) |*st, stat_index| {
            self.label_has_code_after = true;
            if (st.node == .Label) {
                var next_index = stat_index + 1;
                self.label_has_code_after = has_postlude;
                while (next_index < block.stats.len) : (next_index += 1) {
                    if (block.stats[next_index].node != .Label) {
                        self.label_has_code_after = true;
                        break;
                    }
                }
            }
            const terminated = try self.genStat(st);
            if (terminated) break;
        }
    }

    // -----------------------------------------------------------------------
    // Entry point: compileChunk
    // -----------------------------------------------------------------------

    pub fn compileChunk(self: *Codegen, chunk: *const ast.Chunk) Error!*bc.Proto {
        self.builder.name = "main";
        self.builder.source_name = self.source_name;
        self.builder.line_defined = 0;
        self.builder.last_line_defined = 0;
        self.builder.is_vararg = true;
        self.chunk_is_vararg = true;
        self.is_vararg = true;

        // Reserve _ENV as upvalue 0 (like PUC Lua).
        _ = try self.builder.addUpvalue(.{
            .instack = false,
            .idx = 0,
            .is_const = false,
            .name = "_ENV",
        });
        try self.upvalues.put(self.alloc, "_ENV", 0);

        // VARARGPREP is VM bookkeeping and has no source-visible line in
        // PUC's active-line table. The first real instruction establishes
        // the first line event.
        if (self.is_vararg) {
            _ = try self.builder.emitABC(.varargprep, 0, 0, 0, 0);
        }

        // Compile the block.
        try self.genBlock(chunk.block);

        for (self.pending_gotos.items) |pending| {
            if (pending.resolved) continue;
            self.setDiagFmt(
                pending.span,
                "no visible label '{s}' for goto at line {d}",
                .{ pending.name, pending.span.line },
            );
            return error.CodegenError;
        }

        // PUC attributes the main chunk's implicit RETURN to the final
        // source statement, not to trailing blank lines or EOF. For compound
        // statements use the end of their span (for example the closing `end`).
        const closing_line = if (chunk.block.stats.len != 0)
            self.spanLastTokenLine(chunk.block.stats[chunk.block.stats.len - 1].span)
        else
            chunk.span.line;
        _ = try self.builder.emitSimple(.return0, closing_line);

        // Transfer upvalue descriptions to the builder.
        for (self.upvalue_descs.items) |desc| {
            _ = try self.builder.addUpvalue(desc);
        }

        const proto = try self.builder.finish();
        return proto;
    }
};

// Re-export for convenience.
const Instruction = bc.Instruction;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "codegen: simple arithmetic" {
    const testing = std.testing;

    // Parse "local x = 1 + 2 return x"
    const source = "local x = 1 + 2 return x";
    var lexer = @import("lexer.zig").Lexer.init(.{ .name = "test", .bytes = source });
    var parser = try @import("parser.zig").Parser.init(&lexer);
    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    // Compile to bytecode.
    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    // Verify bytecode (constant folding collapses "1 + 2" → 3):
    // 0: VARARGPREP
    // 1: LOADI R0 3       (constant-folded result)
    // 2: RETURN1 R0       (return x)
    // 3: RETURN0          (implicit return)
    try testing.expectEqual(@as(usize, 4), proto.code.len);
    try testing.expectEqual(bc.Op.varargprep, @as(bc.Op, @enumFromInt(proto.code[0].op)));
    try testing.expectEqual(bc.Op.loadi, @as(bc.Op, @enumFromInt(proto.code[1].op)));
    try testing.expectEqual(bc.Op.return1, @as(bc.Op, @enumFromInt(proto.code[2].op)));
    try testing.expectEqual(bc.Op.return0, @as(bc.Op, @enumFromInt(proto.code[3].op)));
}

test "codegen: if/else" {
    const testing = std.testing;

    const source = "local x = 1\nif x then\nreturn 1\nelse\nreturn 2\nend";
    var lexer = @import("lexer.zig").Lexer.init(.{ .name = "test", .bytes = source });
    var parser = try @import("parser.zig").Parser.init(&lexer);
    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    // Should compile without error.
    try testing.expect(proto.code.len > 0);
}

test "codegen: for loop" {
    const testing = std.testing;

    const source = "local s = 0\nfor i = 1, 10 do\ns = s + i\nend\nreturn s";
    var lexer = @import("lexer.zig").Lexer.init(.{ .name = "test", .bytes = source });
    var parser = try @import("parser.zig").Parser.init(&lexer);
    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    // Should compile with FORPREP and FORLOOP.
    var has_forprep = false;
    var has_forloop = false;
    for (proto.code) |inst| {
        const op: bc.Op = @enumFromInt(inst.op);
        if (op == .forprep) has_forprep = true;
        if (op == .forloop) has_forloop = true;
    }
    try testing.expect(has_forprep);
    try testing.expect(has_forloop);
}

test "codegen: hot loop instruction count regression" {
    const testing = std.testing;

    // This test guards against codegen inflation in the most common hot
    // loop pattern: `s = s + i` inside a numeric for. The body should
    // execute a small number of opcodes per iteration. If codegen regresses
    // (e.g., unnecessary MOVE, LOADNIL, or CLOSE), this test will fail.
    //
    // PUC Lua 5.5 emits 3 opcodes in the loop body: ADD, MMBIN, FORLOOP.
    // luazig currently emits more due to MOVE for local reads and LOADNIL
    // for register clearing. The regression threshold is generous to allow
    // incremental improvement without breaking the test.
    //
    // Expected layout (current codegen):
    //   VARARGPREP
    //   LOADI R0 0           (s = 0)
    //   LOADI R1 1           (init)
    //   LOADI R2 10          (limit)
    //   LOADI R3 1           (step)
    //   FORPREP R1 ->exit
    //   --- loop body ---
    //   MOVE R5 R0           (copy s to temp)
    //   MOVE R6 R4           (copy i to temp)
    //   ADD R5 R5 R6         (s + i)
    //   MOVE R0 R5           (s = result)
    //   LOADNIL R5..R6       (clear temps)
    //   --- end loop body ---
    //   FORLOOP R1 ->body
    //   LOADNIL R4           (clear i)
    //   MOVE R1 R0           (return value)
    //   RETURN1 R1
    //   LOADNIL R1
    //   LOADNIL R0
    //   RETURN0
    //
    // Loop body = instructions between FORPREP and FORLOOP (exclusive).
    // Currently 5 opcodes: MOVE, MOVE, ADD, MOVE, LOADNIL.
    // Regression threshold: body must not exceed 7 opcodes.
    const source = "local s = 0\nfor i = 1, 10 do\ns = s + i\nend\nreturn s";
    var lexer = @import("lexer.zig").Lexer.init(.{ .name = "test", .bytes = source });
    var parser = try @import("parser.zig").Parser.init(&lexer);
    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    // Find FORPREP and FORLOOP to measure the loop body.
    var forprep_pc: ?usize = null;
    var forloop_pc: ?usize = null;
    for (proto.code, 0..) |inst, pc| {
        const op: bc.Op = @enumFromInt(inst.op);
        if (op == .forprep) forprep_pc = pc;
        if (op == .forloop) forloop_pc = pc;
    }
    try testing.expect(forprep_pc != null);
    try testing.expect(forloop_pc != null);

    const body_start = forprep_pc.? + 1;
    const body_end = forloop_pc.?;
    const body_len = body_end - body_start;

    // The loop body must not exceed 7 opcodes. If it does, codegen has
    // regressed — investigate unnecessary MOVE/LOADNIL/CLOSE emissions.
    try testing.expect(body_len <= 7);
    if (body_len > 5) {
        std.debug.print("warning: hot loop body has {d} opcodes (expected ≤5)\n", .{body_len});
    }
}

test "codegen: K-variant opcodes for constant operands" {
    const testing = std.testing;

    // Verify that binary operations with constant RHS use K/I-variant
    // opcodes instead of LOADK + register/register op.
    const source = "local x = 10\nreturn x + 5";
    var lexer = @import("lexer.zig").Lexer.init(.{ .name = "test", .bytes = source });
    var parser = try @import("parser.zig").Parser.init(&lexer);
    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    // Should contain ADDI (x + 5, where 5 fits in sC).
    var has_addi = false;
    for (proto.code) |inst| {
        const op: bc.Op = @enumFromInt(inst.op);
        if (op == .addi) has_addi = true;
    }
    try testing.expect(has_addi);
}

test "codegen: function call" {
    const testing = std.testing;

    const source = "local x = print(42)\nreturn x";
    var lexer = @import("lexer.zig").Lexer.init(.{ .name = "test", .bytes = source });
    var parser = try @import("parser.zig").Parser.init(&lexer);
    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    // Should have a CALL instruction.
    var has_call = false;
    for (proto.code) |inst| {
        const op: bc.Op = @enumFromInt(inst.op);
        if (op == .call) has_call = true;
    }
    try testing.expect(has_call);
}

test "codegen: table constructor" {
    const testing = std.testing;

    const source = "local t = {1, 2, 3}\nreturn t";
    var lexer = @import("lexer.zig").Lexer.init(.{ .name = "test", .bytes = source });
    var parser = try @import("parser.zig").Parser.init(&lexer);
    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    // Should have NEWTABLE and SETLIST.
    var has_newtable = false;
    var has_setlist = false;
    for (proto.code) |inst| {
        const op: bc.Op = @enumFromInt(inst.op);
        if (op == .newtable) has_newtable = true;
        if (op == .setlist) has_setlist = true;
    }
    try testing.expect(has_newtable);
    try testing.expect(has_setlist);
}

test "codegen: closure" {
    const testing = std.testing;

    const source = "local function f(x)\nreturn x + 1\nend\nreturn f(10)";
    var lexer = @import("lexer.zig").Lexer.init(.{ .name = "test", .bytes = source });
    var parser = try @import("parser.zig").Parser.init(&lexer);
    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    // Should have CLOSURE instruction and an inner proto.
    var has_closure = false;
    for (proto.code) |inst| {
        const op: bc.Op = @enumFromInt(inst.op);
        if (op == .closure) has_closure = true;
    }
    try testing.expect(has_closure);
    try testing.expectEqual(@as(usize, 1), proto.p.len);
}

test "codegen+bc_vm: end-to-end arithmetic" {
    const testing = std.testing;

    const source = "local x = 1 + 2\nreturn x";
    var lexer = @import("lexer.zig").Lexer.init(.{ .name = "test", .bytes = source });
    var parser = try @import("parser.zig").Parser.init(&lexer);
    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    // Create a Vm and execute the proto.
    var v = vm.Vm.init(testing.allocator);
    defer v.deinit();

    const results = try v.runBytecode(proto, &.{}, &.{}, null);
    defer testing.allocator.free(results);

    // Should return [3] (Int(3)).
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expect(results[0] == .Int);
    try testing.expectEqual(@as(i64, 3), results[0].Int);
}

test "codegen+bc_vm: inner global declaration shadows outer local" {
    const testing = std.testing;

    const source =
        \\local X = 10
        \\do
        \\  global X
        \\  X = 20
        \\end
        \\return X, _ENV.X
    ;
    var lexer = @import("lexer.zig").Lexer.init(.{ .name = "test", .bytes = source });
    var parser = try @import("parser.zig").Parser.init(&lexer);
    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    var v = vm.Vm.init(testing.allocator);
    defer v.deinit();
    var env_cell = vm.Cell{ .value = .{ .Table = v.global_env } };
    var upvalues = [_]*vm.Cell{&env_cell};

    const results = try v.runBytecode(proto, upvalues[0..], &.{}, null);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expect(results[0] == .Int);
    try testing.expectEqual(@as(i64, 10), results[0].Int);
    try testing.expect(results[1] == .Int);
    try testing.expectEqual(@as(i64, 20), results[1].Int);
}

test "codegen+bc_vm: global declaration expands final call" {
    const testing = std.testing;

    const source =
        \\global a, b, c, d = table.unpack{1, 2, 3, 6, 5}
        \\return a, b, c, d
    ;
    var lexer = @import("lexer.zig").Lexer.init(.{ .name = "test", .bytes = source });
    var parser = try @import("parser.zig").Parser.init(&lexer);
    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    var v = vm.Vm.init(testing.allocator);
    defer v.deinit();
    var env_cell = vm.Cell{ .value = .{ .Table = v.global_env } };
    var upvalues = [_]*vm.Cell{&env_cell};

    const results = try v.runBytecode(proto, upvalues[0..], &.{}, null);
    defer testing.allocator.free(results);

    const expected = [_]i64{ 1, 2, 3, 6 };
    try testing.expectEqual(expected.len, results.len);
    for (expected, results) |want, got| {
        try testing.expect(got == .Int);
        try testing.expectEqual(want, got.Int);
    }
}

test "codegen+bc_vm: direct bytecode yield parks thread-owned continuation" {
    const testing = std.testing;

    const source =
        \\local co = coroutine.create(function (x)
        \\  local y = coroutine.yield(x)
        \\  return y
        \\end)
        \\local ok, value = coroutine.resume(co, 41)
        \\return co, ok, value
    ;
    var lexer = @import("lexer.zig").Lexer.init(.{ .name = "test", .bytes = source });
    var parser = try @import("parser.zig").Parser.init(&lexer);
    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    var v = vm.Vm.init(testing.allocator);
    defer v.deinit();
    var env_cell = vm.Cell{ .value = .{ .Table = v.global_env } };
    var upvalues = [_]*vm.Cell{&env_cell};

    const results = try v.runBytecode(proto, upvalues[0..], &.{}, null);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expect(results[0] == .Thread);
    const th = results[0].Thread;
    try testing.expect(results[1] == .Bool and results[1].Bool);
    try testing.expect(results[2] == .Int and results[2].Int == 41);

    // A direct bytecode yield must retain the authoritative continuation in
    // the thread-owned frame/register/TBC stacks. The IR snapshot list belongs
    // only to the frozen IR backend and must remain empty for bytecode execution.
    try testing.expect(th.bytecode_inplace_suspended);
    try testing.expect(th.call_frames.len() != 0);

    var resume_out: [3]vm.Value = .{ .Nil, .Nil, .Nil };
    const resume_count = try v.apiResumeThread(th, &[_]vm.Value{.{ .Int = 42 }}, resume_out[0..]);
    try testing.expectEqual(@as(usize, 2), resume_count);
    try testing.expect(resume_out[0] == .Bool and resume_out[0].Bool);
    try testing.expect(resume_out[1] == .Int and resume_out[1].Int == 42);
    try testing.expect(!th.bytecode_inplace_suspended);
    try testing.expectEqual(@as(usize, 0), th.call_frames.len());
}

test "codegen+bc_vm: yielding generic iterator stays on explicit frame stack" {
    const testing = std.testing;

    const source =
        \\local function iter(_, control)
        \\  if control == nil then
        \\    local resumed = coroutine.yield("iterator-yield")
        \\    return 1, resumed
        \\  end
        \\end
        \\local co = coroutine.create(function ()
        \\  for key, value in iter, nil, nil do
        \\    return key, value
        \\  end
        \\end)
        \\local ok, value = coroutine.resume(co)
        \\return co, ok, value
    ;
    var lexer = @import("lexer.zig").Lexer.init(.{ .name = "test", .bytes = source });
    var parser = try @import("parser.zig").Parser.init(&lexer);
    var arena = ast.AstArena.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    var v = vm.Vm.init(testing.allocator);
    defer v.deinit();
    var env_cell = vm.Cell{ .value = .{ .Table = v.global_env } };
    var upvalues = [_]*vm.Cell{&env_cell};

    const results = try v.runBytecode(proto, upvalues[0..], &.{}, null);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expect(results[0] == .Thread);
    const th = results[0].Thread;
    try testing.expect(results[1] == .Bool and results[1].Bool);
    try testing.expect(results[2] == .String);
    try testing.expectEqualStrings("iterator-yield", results[2].String.bytes());

    // The coroutine body and iterator activation remain authoritative in the
    // per-thread explicit stack. No SuspendedFrame replay copy is created.
    try testing.expect(th.bytecode_inplace_suspended);
    try testing.expect(th.call_frames.len() >= 2);

    var resume_out: [4]vm.Value = .{ .Nil, .Nil, .Nil, .Nil };
    const resume_count = try v.apiResumeThread(
        th,
        &[_]vm.Value{.{ .String = try v.internStr("resume-value") }},
        resume_out[0..],
    );
    try testing.expectEqual(@as(usize, 3), resume_count);
    try testing.expect(resume_out[0] == .Bool and resume_out[0].Bool);
    try testing.expect(resume_out[1] == .Int and resume_out[1].Int == 1);
    try testing.expect(resume_out[2] == .String);
    try testing.expectEqualStrings("resume-value", resume_out[2].String.bytes());
    try testing.expect(!th.bytecode_inplace_suspended);
    try testing.expectEqual(@as(usize, 0), th.call_frames.len());
}
