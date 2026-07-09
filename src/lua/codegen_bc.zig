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
const vm = @import("vm.zig");
const TokenKind = @import("token.zig").TokenKind;

// ---------------------------------------------------------------------------
// Codegen state
// ---------------------------------------------------------------------------

pub const Codegen = struct {
    source_name: []const u8,
    source: []const u8,
    alloc: std.mem.Allocator,

    diag: ?Diag = null,
    diag_buf: [256]u8 = undefined,

    // --- Register allocation (PUC freereg model) ---
    /// Next available register. Registers 0..nvarstack-1 hold locals;
    /// nvarstack..freereg-1 hold temporaries. At statement boundaries,
    /// freereg is reset to nvarstack.
    freereg: u8 = 0,
    /// Number of register-resident locals. This is the lower bound for
    /// freereg — temporaries are allocated above this.
    nvarstack: u8 = 0,

    // --- Bytecode output ---
    builder: bc.ProtoBuilder,
    line_hint: u32 = 0,

    // --- Scoping ---
    bindings: std.ArrayListUnmanaged(Binding) = .empty,
    scope_marks: std.ArrayListUnmanaged(usize) = .empty,
    loop_ends: std.ArrayListUnmanaged(JumpSlot) = .empty,

    // --- Upvalues / closures ---
    outer: ?*Codegen = null,
    upvalues: std.StringHashMapUnmanaged(u8) = .{},
    upvalue_descs: std.ArrayListUnmanaged(bc.Upvaldesc) = .empty,
    captured_regs: std.AutoHashMapUnmanaged(u8, void) = .{},
    const_locals: std.AutoHashMapUnmanaged(u8, void) = .{},
    close_locals: std.AutoHashMapUnmanaged(u8, void) = .{},
    const_upvalues: std.AutoHashMapUnmanaged(u8, void) = .{},

    // --- Vararg state ---
    is_vararg: bool = false,
    chunk_is_vararg: bool = false,

    /// A binding maps a name to a register (local variable).
    const Binding = struct {
        name: []const u8,
        reg: u8,
        depth: usize,
    };

    /// A jump slot is a pending jump that needs backpatching (break target).
    const JumpSlot = struct {
        pc: u32,
        scope_mark: usize,
    };

    pub const Error = std.mem.Allocator.Error || error{CodegenError};

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

    // -----------------------------------------------------------------------
    // Register allocation (freereg model — like PUC Lua)
    // -----------------------------------------------------------------------

    /// Reserve n registers starting at freereg. Updates maxstacksize.
    fn reserveRegs(self: *Codegen, n: u8) Error!void {
        const new_top = self.freereg + n;
        if (new_top > 255) {
            self.setDiag(.{ .start = 0, .end = 0, .line = self.line_hint, .col = 0 }, "too many registers");
            return error.CodegenError;
        }
        self.freereg = new_top;
        self.builder.checkStack(self.freereg);
    }

    /// Allocate one register and return its index.
    fn allocReg(self: *Codegen) Error!u8 {
        try self.reserveRegs(1);
        return self.freereg - 1;
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
    fn resetRegs(self: *Codegen) void {
        self.freereg = self.nvarstack;
    }

    // -----------------------------------------------------------------------
    // Scope management
    // -----------------------------------------------------------------------

    fn pushScope(self: *Codegen) Error!void {
        try self.scope_marks.append(self.alloc, self.bindings.items.len);
    }

    fn popScope(self: *Codegen) void {
        const n = self.scope_marks.items.len;
        std.debug.assert(n > 0);
        const mark = self.scope_marks.items[n - 1];
        self.scope_marks.items.len = n - 1;

        // Emit CLOSE for <close> locals (in reverse declaration order).
        var i = self.bindings.items.len;
        while (i > mark) {
            i -= 1;
            const b = self.bindings.items[i];
            if (self.isCloseLocal(b.reg)) {
                _ = self.builder.emitSimple(.close, self.line_hint) catch @panic("oom");
                // CLOSE takes the register to close from A.
                self.builder.code.items[self.builder.code.items.len - 1].a = b.reg;
            }
        }

        // Restore nvarstack to the scope entry point.
        if (mark < self.bindings.items.len) {
            self.nvarstack = self.bindings.items[mark].reg;
            if (mark > 0) {
                self.nvarstack = self.bindings.items[mark - 1].reg + 1;
            } else {
                self.nvarstack = 0;
            }
        }
        self.freereg = self.nvarstack;
        self.bindings.items.len = mark;
    }

    fn popScopeNoClear(self: *Codegen) void {
        const n = self.scope_marks.items.len;
        std.debug.assert(n > 0);
        const mark = self.scope_marks.items[n - 1];
        self.scope_marks.items.len = n - 1;
        if (mark < self.bindings.items.len) {
            if (mark > 0) {
                self.nvarstack = self.bindings.items[mark - 1].reg + 1;
            } else {
                self.nvarstack = 0;
            }
        }
        self.freereg = self.nvarstack;
        self.bindings.items.len = mark;
    }

    /// Declare a local variable in the next available register.
    fn declareLocal(self: *Codegen, name: []const u8) Error!u8 {
        const reg = self.freereg;
        try self.reserveRegs(1);
        self.nvarstack = self.freereg;
        try self.bindings.append(self.alloc, .{ .name = name, .reg = reg, .depth = self.scope_marks.items.len });
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

    fn markConstLocal(self: *Codegen, reg: u8) void {
        self.const_locals.put(self.alloc, reg, {}) catch @panic("oom");
    }

    fn markCloseLocal(self: *Codegen, reg: u8) void {
        self.close_locals.put(self.alloc, reg, {}) catch @panic("oom");
    }

    fn isConstLocal(self: *Codegen, reg: u8) bool {
        return self.const_locals.contains(reg);
    }

    fn isCloseLocal(self: *Codegen, reg: u8) bool {
        return self.close_locals.contains(reg);
    }

    // -----------------------------------------------------------------------
    // Upvalue management
    // -----------------------------------------------------------------------

    fn ensureUpvalue(self: *Codegen, name: []const u8) Error!u8 {
        if (self.upvalues.get(name)) |idx| return idx;
        // Walk up the closure chain to find the variable.
        if (self.outer) |outer| {
            if (outer.lookupLocal(name)) |reg| {
                // Capture from outer's register.
                outer.captured_regs.put(outer.alloc, reg, {}) catch @panic("oom");
                const is_const = outer.isConstLocal(reg);
                const idx: u8 = @intCast(self.upvalue_descs.items.len);
                try self.upvalue_descs.append(self.alloc, .{
                    .instack = true,
                    .idx = reg,
                    .is_const = is_const,
                    .name = name,
                });
                try self.upvalues.put(self.alloc, name, idx);
                if (is_const) self.const_upvalues.put(self.alloc, idx, {}) catch @panic("oom");
                return idx;
            }
            // Try outer's upvalues.
            if (outer.upvalues.get(name)) |outer_idx| {
                const is_const = outer.isConstUpvalue(outer_idx);
                const idx: u8 = @intCast(self.upvalue_descs.items.len);
                try self.upvalue_descs.append(self.alloc, .{
                    .instack = false,
                    .idx = outer_idx,
                    .is_const = is_const,
                    .name = name,
                });
                try self.upvalues.put(self.alloc, name, idx);
                if (is_const) self.const_upvalues.put(self.alloc, idx, {}) catch @panic("oom");
                return idx;
            }
            // Recurse into outer's outer.
            return outer.ensureUpvalue(name);
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

    /// Patch a jump at `jump_pc` to target the current PC.
    fn patchJumpToHere(self: *Codegen, jump_pc: u32) void {
        self.builder.patchJump(jump_pc, self.builder.pc());
    }

    /// Patch a jump at `jump_pc` to target `target_pc`.
    fn patchJumpTo(self: *Codegen, jump_pc: u32, target_pc: u32) void {
        self.builder.patchJump(jump_pc, target_pc);
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

    // -----------------------------------------------------------------------
    // Expression compilation
    // -----------------------------------------------------------------------

    /// Compile an expression into the next free register.
    /// Returns the register holding the result.
    /// The caller is responsible for freeing the register when done.
    fn genExp(self: *Codegen, e: *const ast.Exp) Error!u8 {
        switch (e.node) {
            .Nil => {
                const dst = try self.allocReg();
                _ = try self.builder.emitABC(.loadnil, dst, 0, 0, e.span.line);
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
                const parsed = std.fmt.parseInt(i64, lexeme, 0) catch {
                    // Unparseable integer — treat as error for now.
                    self.setDiag(e.span, "invalid integer literal");
                    return error.CodegenError;
                };
                // Small integer — use LOADI if it fits in 16-bit signed.
                if (parsed >= -32768 and parsed <= 32767) {
                    const dst = try self.allocReg();
                    const bits: u32 = @bitCast(@as(i32, @intCast(parsed)));
                    const lo: u8 = @truncate(bits);
                    const hi: u8 = @truncate(bits >> 8);
                    _ = try self.builder.emitABC(.loadi, dst, lo, hi, e.span.line);
                    return dst;
                }
                // Large integer — store as constant.
                const dst = try self.allocReg();
                const kid = try self.builder.internInt(parsed);
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
                const kid = try self.builder.internConst(bc.Constant.num(val));
                try self.emitLoadK(dst, kid, e.span.line);
                return dst;
            },
            .String => {
                const lexeme = e.span.slice(self.source);
                const dst = try self.allocReg();
                const kid = try self.builder.internString(lexeme);
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
                if (n.op == .And) return self.genAndExp(n.lhs, n.rhs, e.span.line);
                if (n.op == .Or) return self.genOrExp(n.lhs, n.rhs, e.span.line);
                return self.genBinOp(n, e.span.line);
            },
            .UnOp => |n| {
                return self.genUnOp(n, e.span.line);
            },
            // Phase 3: Call, MethodCall, FuncDef, Table, Field, Index, Dots
            else => {
                self.setDiag(e.span, "bytecode codegen: expression type not yet supported");
                return error.CodegenError;
            },
        }
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

    /// Resolve a name to a value: local → upvalue → global.
    fn genNameValue(self: *Codegen, span: ast.Span, name: []const u8) Error!u8 {
        // Local variable?
        if (self.lookupLocal(name)) |reg| {
            if (self.isConstLocal(reg)) {
                // Const locals are compile-time constants — but we still
                // need to load the value. The VM handles this via the
                // register (the const value is already in the register).
                // For now, just return the register — the value was set
                // when the local was declared.
                return reg;
            }
            // For non-const locals, we need to copy to a fresh register
            // so the caller can free it independently.
            const dst = try self.allocReg();
            _ = try self.builder.emitABC(.move, dst, reg, 0, span.line);
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
        // Global: R[A] = _ENV[name]  →  GETTABUP A env_upval K[name]
        const dst = try self.allocReg();
        const name_kid = try self.builder.internString(name);
        // _ENV is upvalue 0 (like PUC Lua).
        try self.emitGetTabUp(dst, 0, name_kid, span.line);
        return dst;
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
    fn emitSetTabUp(self: *Codegen, upval_idx: u8, kid: u32, val_reg: u8, line: u32) Error!void {
        if (kid <= 255) {
            _ = try self.builder.emitABC(.settabup, upval_idx, @intCast(kid), val_reg, line);
        } else {
            // Fallback: load string, get _ENV, use SETTABLE.
            const key_reg = try self.allocReg();
            try self.emitLoadK(key_reg, kid, line);
            const env_reg = try self.allocReg();
            _ = try self.builder.emitABC(.getupval, env_reg, upval_idx, 0, line);
            _ = try self.builder.emitABC(.settable, env_reg, key_reg, val_reg, line);
            self.freeReg(env_reg);
            self.freeReg(key_reg);
        }
    }

    // -----------------------------------------------------------------------
    // Binary / unary operations
    // -----------------------------------------------------------------------

    fn binOpToBc(op: TokenKind) ?bc.Op {
        return switch (op) {
            .Plus => .add,
            .Minus => .sub,
            .Star => .mul,
            .Slash => .div,
            .Percent => .mod,
            .Caret => .pow,
            .DoubleSlash => .idiv,
            .Amp => .band,
            .Pipe => .bor,
            .Tilde => .bxor,
            .DoubleLess => .shl,
            .DoubleGreater => .shr,
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

    fn genBinOp(self: *Codegen, n: ast.Exp.Node.BinOp, line: u32) Error!u8 {
        // Compile operands into consecutive registers.
        const lhs = try self.genExp(n.lhs);
        const rhs = try self.genExp(n.rhs);

        // Arithmetic / bitwise: emit register/register op.
        if (binOpToBc(n.op)) |op| {
            // Free operands BEFORE allocating result (like PUC's freeexps).
            // The values are still in the registers; we just mark them
            // available for reuse. The result goes to the freed slot.
            self.freeReg2(rhs, lhs);
            const dst = try self.allocReg();
            _ = try self.builder.emitABC(op, dst, lhs, rhs, line);
            return dst;
        }

        // Comparison: produce a boolean value.
        if (n.op == .EqEq or n.op == .NotEq or n.op == .Lt or
            n.op == .Lte or n.op == .Gt or n.op == .Gte)
        {
            return self.genComparison(n.op, lhs, rhs, line);
        }

        // Concat
        if (n.op == .DoubleDot) {
            // PUC: CONCAT R[A] = R[A].. ... ..R[A+B-1]
            // Both operands must be in contiguous registers.
            // Move lhs to a temp, then rhs to temp+1.
            self.freeReg2(rhs, lhs);
            const dst = try self.allocReg();
            _ = try self.builder.emitABC(.move, dst, lhs, 0, line);
            const rhs_reg = try self.allocReg();
            _ = try self.builder.emitABC(.move, rhs_reg, rhs, 0, line);
            _ = try self.builder.emitABC(.concat, dst, 2, 0, line);
            self.freeReg(rhs_reg);
            return dst;
        }

        self.setDiag(.{ .start = 0, .end = 0, .line = line, .col = 0 }, "unsupported binary operator");
        return error.CodegenError;
    }

    /// Compile a comparison into a boolean value in a fresh register.
    /// Uses the EQ/LT/LE + JMP + LOADTRUE/LOADFALSE pattern.
    fn genComparison(self: *Codegen, op: TokenKind, lhs: u8, rhs: u8, line: u32) Error!u8 {
        // Determine the comparison opcode and operand order.
        // For > and >=, swap operands and use lt/le.
        var bc_op: bc.Op = undefined;
        var op_lhs = lhs;
        var op_rhs = rhs;

        switch (op) {
            .EqEq => bc_op = .eq,
            .NotEq => bc_op = .eq, // EQ with inverted skip
            .Lt => bc_op = .lt,
            .Lte => bc_op = .le,
            .Gt => {
                bc_op = .lt;
                op_lhs = rhs;
                op_rhs = lhs;
            },
            .Gte => {
                bc_op = .le;
                op_lhs = rhs;
                op_rhs = lhs;
            },
            else => unreachable,
        }

        // C=0: skip next instruction when condition is TRUE.
        // C=1: skip next instruction when condition is FALSE.
        const invert: u8 = if (op == .NotEq) 0 else 1;

        // Free operands before allocating result.
        self.freeReg2(rhs, lhs);
        const dst = try self.allocReg();

        // Pattern:
        //   CMP op_lhs op_rhs invert   (skip JMP if condition matches)
        //   JMP +2                     (condition false: skip to LOADFALSE)
        //   LOADTRUE dst               (condition true: dst = true)
        //   JMP +1                     (skip LOADFALSE)
        //   LOADFALSE dst              (condition false: dst = false)
        _ = try self.builder.emitABC(bc_op, op_lhs, op_rhs, invert, line);
        const jmp_false = try self.emitJump(line);
        _ = try self.builder.emitABC(.loadtrue, dst, 0, 0, line);
        const jmp_end = try self.emitJump(line);
        self.patchJumpToHere(jmp_false);
        _ = try self.builder.emitABC(.loadfalse, dst, 0, 0, line);
        self.patchJumpToHere(jmp_end);
        return dst;
    }

    fn genUnOp(self: *Codegen, n: ast.Exp.Node.UnOp, line: u32) Error!u8 {
        const src = try self.genExp(n.exp);
        const op: bc.Op = switch (n.op) {
            .Minus => .unm,
            .Tilde => .bnot,
            .Not => .not_,
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
    // Short-circuit and/or
    // -----------------------------------------------------------------------

    fn genAndExp(self: *Codegen, lhs_exp: *const ast.Exp, rhs_exp: *const ast.Exp, line: u32) Error!u8 {
        // a and b: if a is falsy, result = a; else result = b.
        // PUC approach: test lhs, if falsy skip to end (keep lhs in dst),
        // else compile rhs into dst.
        const dst = try self.allocReg();
        const lhs = try self.genExp(lhs_exp);
        _ = try self.builder.emitABC(.move, dst, lhs, 0, line);
        self.freeReg(lhs);

        // TEST dst 1 (skip next if falsy — i.e., if falsy, don't evaluate rhs).
        _ = try self.builder.emitABC(.test_, dst, 0, 1, line);
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

        // TEST dst 0 (skip next if truthy — i.e., if truthy, don't evaluate rhs).
        _ = try self.builder.emitABC(.test_, dst, 0, 0, line);
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
        defer self.resetRegs();

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
            .Label => |n| {
                // Labels are no-ops in bytecode (jumps are patched to the PC).
                _ = n;
                return false;
            },
            .Goto => |n| {
                // Goto: emit JMP, to be patched when the label is seen.
                // For now, we only support forward gotos within the same scope.
                // Full goto/label resolution will be added later.
                _ = n;
                _ = try self.emitJump(st.span.line);
                return false;
            },
            // Phase 3: Call, FuncDecl, LocalFuncDecl, GlobalFuncDecl, GlobalDecl, ForNumeric, ForGeneric
            else => {
                self.setDiag(st.span, "bytecode codegen: statement type not yet supported");
                return error.CodegenError;
            },
        }
    }

    fn genLocalDecl(self: *Codegen, n: ast.Stat.Node.LocalDecl, line: u32) Error!bool {
        // Compile RHS values.
        if (n.values) |values| {
            // For N locals and M values:
            // - If M >= N: compile all values, assign first N to locals.
            // - If M < N: compile M values, nil-fill remaining.
            for (values, 0..) |val, i| {
                if (i < n.names.len) {
                    const reg = try self.genExp(val);
                    // The value is in a temporary register. We'll declare
                    // the local at this register position.
                    // Actually, we need the value to end up in the local's
                    // register. Since we use freereg, the value is already
                    // in the next free register — we just need to declare it.
                    _ = reg; // value is at freereg-1
                } else {
                    // Extra values (discarded) — compile and free.
                    const reg = try self.genExp(val);
                    self.freeReg(reg);
                }
            }
            // Declare locals for each name.
            // The values are in registers [freereg - values.len .. freereg).
            // But we need to handle the case where values.len < names.len.
            const nvals = values.len;
            const nnames = n.names.len;
            if (nvals >= nnames) {
                // Values are already in the right registers. Just declare them.
                for (n.names) |dn| {
                    _ = try self.declareLocal(dn.name.slice(self.source));
                    if (dn.prefix_attr) |attr| {
                        if (attr.kind == .Const) self.markConstLocal(self.freereg - 1);
                        if (attr.kind == .Close) self.markCloseLocal(self.freereg - 1);
                    }
                }
            } else {
                // Fewer values than names: declare what we have, nil-fill the rest.
                for (values) |_| {
                    _ = try self.declareLocal("");
                }
                for (n.names[0..nvals]) |dn| {
                    // Re-name the already-declared locals.
                    // This is a simplification — in a proper implementation,
                    // we'd adjust locals.
                    _ = dn;
                }
                // Fill remaining with nil.
                for (n.names[nvals..]) |dn| {
                    const reg = try self.declareLocal(dn.name.slice(self.source));
                    _ = try self.builder.emitABC(.loadnil, reg, 0, 0, line);
                }
            }
        } else {
            // No values: declare all as nil.
            for (n.names) |dn| {
                const reg = try self.declareLocal(dn.name.slice(self.source));
                _ = try self.builder.emitABC(.loadnil, reg, 0, 0, line);
                if (dn.prefix_attr) |attr| {
                    if (attr.kind == .Const) self.markConstLocal(reg);
                    if (attr.kind == .Close) self.markCloseLocal(reg);
                }
            }
        }
        return false;
    }

    fn genAssign(self: *Codegen, n: ast.Stat.Node.Assign, line: u32) Error!bool {
        // For simple assignments (lhs = rhs), compile RHS into a register,
        // then store to the target.
        // Multi-value assignment: compile all RHS, then assign.
        // For now, handle simple 1:1 assignment.
        if (n.lhs.len == 1 and n.rhs.len == 1) {
            const rhs_reg = try self.genExp(n.rhs[0]);
            try self.genSet(n.lhs[0], rhs_reg, line);
            self.freeReg(rhs_reg);
            return false;
        }
        // Multi-assign: compile all RHS values, then assign.
        const rhs_regs = try self.alloc.alloc(u8, n.rhs.len);
        defer self.alloc.free(rhs_regs);
        for (n.rhs, 0..) |val, i| {
            rhs_regs[i] = try self.genExp(val);
        }
        for (n.lhs, 0..) |lhs, i| {
            if (i < rhs_regs.len) {
                try self.genSet(lhs, rhs_regs[i], line);
            }
        }
        for (rhs_regs) |reg| self.freeReg(reg);
        return false;
    }

    /// Store a value to an lvalue (local, global, table field, table index).
    fn genSet(self: *Codegen, lhs: *const ast.Exp, val_reg: u8, line: u32) Error!void {
        switch (lhs.node) {
            .Name => |n| {
                const name = n.slice(self.source);
                if (self.lookupLocal(name)) |reg| {
                    if (self.isConstLocal(reg)) {
                        self.setDiag(lhs.span, "cannot assign to const local");
                        return error.CodegenError;
                    }
                    _ = try self.builder.emitABC(.move, reg, val_reg, 0, line);
                    return;
                }
                if (self.upvalues.get(name)) |idx| {
                    if (self.isConstUpvalue(idx)) {
                        self.setDiag(lhs.span, "cannot assign to const upvalue");
                        return error.CodegenError;
                    }
                    _ = try self.builder.emitABC(.setupval, val_reg, idx, 0, line);
                    return;
                }
                // Global: _ENV[name] = val
                const kid = try self.builder.internString(name);
                try self.emitSetTabUp(0, kid, val_reg, line);
            },
            .Field => |n| {
                // t.k = val  →  SETFIELD R[t] K[k] R[val]
                const obj = try self.genExp(n.object);
                const kid = try self.builder.internString(n.name.slice(self.source));
                if (kid <= 255) {
                    _ = try self.builder.emitABC(.setfield, obj, @intCast(kid), val_reg, line);
                } else {
                    const key_reg = try self.allocReg();
                    try self.emitLoadK(key_reg, kid, line);
                    _ = try self.builder.emitABC(.settable, obj, key_reg, val_reg, line);
                    self.freeReg(key_reg);
                }
                self.freeReg(obj);
            },
            .Index => |n| {
                // t[k] = val  →  SETTABLE R[t] R[k] R[val]
                const obj = try self.genExp(n.object);
                const key = try self.genExp(n.index);
                _ = try self.builder.emitABC(.settable, obj, key, val_reg, line);
                self.freeReg(key);
                self.freeReg(obj);
            },
            else => {
                self.setDiag(lhs.span, "invalid assignment target");
                return error.CodegenError;
            },
        }
    }

    fn genReturn(self: *Codegen, n: ast.Stat.Node.Return, line: u32) Error!bool {
        if (n.values.len == 0) {
            _ = try self.builder.emitSimple(.return0, line);
        } else if (n.values.len == 1) {
            const reg = try self.genExp(n.values[0]);
            _ = try self.builder.emitABC(.return1, reg, 0, 0, line);
            self.freeReg(reg);
        } else {
            // Multiple return values.
            // Compile all values into contiguous registers, then RETURN.
            const base = try self.allocReg();
            for (n.values[1..]) |val| {
                const reg = try self.genExp(val);
                _ = reg; // values should be contiguous
            }
            const count: u8 = @intCast(n.values.len + 1);
            _ = try self.builder.emitABC(.return_, base, count, 0, line);
        }
        return true;
    }

    fn genIf(self: *Codegen, n: ast.Stat.Node.If, line: u32) Error!bool {
        // Compile condition.
        const cond = try self.genExp(n.cond);

        // TEST cond 1 (skip next if falsy) + JMP to else.
        _ = try self.builder.emitABC(.test_, cond, 0, 1, line);
        self.freeReg(cond);
        const jmp_to_else = try self.emitJump(line);

        // Then block.
        try self.genBlock(n.then_block);

        // JMP to end (if there's an else).
        var jmp_to_end: ?u32 = null;
        if (n.else_block != null or n.elseifs.len > 0) {
            jmp_to_end = try self.emitJump(line);
        }

        // Else target.
        self.patchJumpToHere(jmp_to_else);

        // Elseifs.
        for (n.elseifs) |eif| {
            const econd = try self.genExp(eif.cond);
            _ = try self.builder.emitABC(.test_, econd, 0, 1, eif.cond.span.line);
            self.freeReg(econd);
            const ejmp = try self.emitJump(eif.cond.span.line);
            try self.genBlock(eif.block);
            if (jmp_to_end == null) jmp_to_end = try self.emitJump(line);
            self.patchJumpToHere(ejmp);
        }

        // Else block.
        if (n.else_block) |b| {
            try self.genBlock(b);
        }

        // End target.
        if (jmp_to_end) |end_pc| {
            self.patchJumpToHere(end_pc);
        }
        return false;
    }

    fn genWhile(self: *Codegen, n: ast.Stat.Node.While, line: u32) Error!bool {
        // Loop start.
        const loop_start = self.builder.pc();

        // Condition.
        const cond = try self.genExp(n.cond);
        _ = try self.builder.emitABC(.test_, cond, 0, 1, n.cond.span.line);
        self.freeReg(cond);

        // JMP to end if falsy.
        const jmp_end = try self.emitJump(n.cond.span.line);

        // Body.
        try self.pushScope();
        // Push loop end for break.
        try self.pushLoopEnd(jmp_end);
        try self.genBlock(n.block);
        self.popLoopEnd();
        self.popScope();

        // JMP back to start.
        const back_jmp = try self.emitJump(line);
        const offset: i32 = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(back_jmp)) - 1;
        self.builder.patchJumpOffset(back_jmp, offset);

        // End target.
        self.patchJumpToHere(jmp_end);
        return false;
    }

    fn genRepeat(self: *Codegen, n: ast.Stat.Node.Repeat, line: u32) Error!bool {
        _ = line;
        // repeat...until: body executes first, then condition is checked.
        // The condition can see locals from the body.
        const loop_start = self.builder.pc();

        try self.pushScope();
        try self.pushLoopEnd(0); // break target — will be patched
        const break_jmp_slot = self.loop_ends.items.len - 1;

        try self.genBlockNoScope(n.block);

        // Condition (can see body's locals — don't pop scope yet).
        const cond = try self.genExp(n.cond);
        _ = try self.builder.emitABC(.test_, cond, 0, 0, n.cond.span.line); // skip if truthy
        self.freeReg(cond);
        const jmp_back = try self.emitJump(n.cond.span.line);
        // JMP back to loop_start if cond is falsy (didn't skip).
        const offset: i32 = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(jmp_back)) - 1;
        self.builder.patchJumpOffset(jmp_back, offset);

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
    // Block compilation
    // -----------------------------------------------------------------------

    fn genBlock(self: *Codegen, block: *const ast.Block) Error!void {
        try self.pushScope();
        for (block.stats.items) |st| {
            const terminated = try self.genStat(st);
            if (terminated) break;
        }
        self.popScope();
    }

    fn genBlockNoScope(self: *Codegen, block: *const ast.Block) Error!void {
        for (block.stats.items) |st| {
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
        self.builder.last_line_defined = chunk.span.line;
        self.builder.is_vararg = true;
        self.chunk_is_vararg = true;
        self.is_vararg = true;

        // Reserve register 0 for _ENV (upvalue 0, like PUC Lua).
        // _ENV is always the first upvalue of the main chunk.
        _ = try self.builder.addUpvalue(.{
            .instack = false,
            .idx = 0,
            .is_const = false,
            .name = "_ENV",
        });

        // Emit VARARGPREP if vararg.
        if (self.is_vararg) {
            _ = try self.builder.emitABC(.varargprep, 0, 0, 0, chunk.span.line);
        }

        // Compile the block.
        try self.genBlock(chunk.block);

        // Implicit return at end of chunk.
        _ = try self.builder.emitSimple(.return0, self.line_hint);

        // Transfer upvalue descriptions.
        // (Already added via addUpvalue during compilation.)

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
    var lexer = @import("lexer.zig").Lexer.init(source);
    var parser = @import("parser.zig").Parser.init(&lexer);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const chunk = try parser.parseChunkAst(&arena);

    // Compile to bytecode.
    var cg = Codegen.init(testing.allocator, "test", source);
    const proto = try cg.compileChunk(chunk);
    defer {
        proto.deinit(testing.allocator);
        testing.allocator.destroy(proto);
    }

    // Verify bytecode:
    // 0: VARARGPREP
    // 1: LOADI R0 1       (lhs of +)
    // 2: LOADI R1 2       (rhs of +)
    // 3: ADD R0 R0 R1     (result reuses freed R0)
    // 4: RETURN1 R0       (return x)
    // 5: RETURN0          (implicit return)
    try testing.expectEqual(@as(usize, 6), proto.code.len);
    try testing.expectEqual(bc.Op.varargprep, @enumFromInt(proto.code[0].op));
    try testing.expectEqual(bc.Op.loadi, @enumFromInt(proto.code[1].op));
    try testing.expectEqual(bc.Op.loadi, @enumFromInt(proto.code[2].op));
    try testing.expectEqual(bc.Op.add, @enumFromInt(proto.code[3].op));
    try testing.expectEqual(bc.Op.return1, @enumFromInt(proto.code[4].op));
    try testing.expectEqual(bc.Op.return0, @enumFromInt(proto.code[5].op));
}

test "codegen: if/else" {
    const testing = std.testing;

    const source = "local x = 1\nif x then\nreturn 1\nelse\nreturn 2\nend";
    var lexer = @import("lexer.zig").Lexer.init(source);
    var parser = @import("parser.zig").Parser.init(&lexer);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
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
