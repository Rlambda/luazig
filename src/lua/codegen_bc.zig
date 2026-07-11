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
    const StrictGlobalsMode = enum { legacy, strict, wildcard };

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

    // --- Scoping ---
    bindings: std.ArrayListUnmanaged(Binding) = .empty,
    scope_marks: std.ArrayListUnmanaged(usize) = .empty,
    loop_ends: std.ArrayListUnmanaged(JumpSlot) = .empty,
    // Goto/label resolution: labels are scoped (like locals).
    active_labels: std.ArrayListUnmanaged(ActiveLabel) = .empty,
    label_scope_marks: std.ArrayListUnmanaged(usize) = .empty,
    pending_gotos: std.ArrayListUnmanaged(PendingGoto) = .empty,
    /// Unique IDs for each pushed scope, used to validate goto/label
    /// scope compatibility. Sibling scopes get different IDs even at
    /// the same depth, preventing cross-branch goto resolution.
    scope_ids: std.ArrayListUnmanaged(usize) = .empty,
    scope_counter: usize = 0,

    // --- Lua 5.5 global declarations ---
    // A `global x` declaration is lexical: inside that scope, `x` must resolve
    // through `_ENV` even when an outer local with the same name exists.
    strict_globals_mode: StrictGlobalsMode = .legacy,
    strict_globals_wildcard_const: bool = false,
    declared_globals: std.StringHashMapUnmanaged(u32) = .{},
    declared_globals_log: std.ArrayListUnmanaged([]const u8) = .empty,
    declared_globals_depth_log: std.ArrayListUnmanaged(usize) = .empty,
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
    /// Index of the _ENV upvalue for this function.
    /// For the main chunk, this is always 0. For child functions,
    /// it's lazily assigned when a global name is first accessed.
    /// GETTABUP/SETTABUP use this index.
    env_upvalue_idx: ?u8 = null,

    // --- Vararg state ---
    is_vararg: bool = false,
    chunk_is_vararg: bool = false,

    /// A binding maps a name to a register (local variable).
    const Binding = struct {
        name: []const u8,
        reg: u8,
        depth: usize,
    };

    const GlobalScopeMark = struct {
        mode: StrictGlobalsMode,
        wildcard_const: bool,
        decl_log_len: usize,
        decl_depth_log_len: usize,
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
        name: []const u8,
        depth: usize,
        scope_id: usize,
        resolved: bool = false,
    };

    /// An active label in the current scope chain.
    const ActiveLabel = struct {
        name: []const u8,
        pc: u32,
        depth: usize,
        scope_id: usize,
        binding_mark: usize,
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
        if (new_top > self.peak_freereg) self.peak_freereg = new_top;
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
        if (self.peak_freereg > self.nvarstack) {
            const count = self.peak_freereg - self.nvarstack;
            _ = self.builder.emitABC(.loadnil, self.nvarstack, count - 1, 0, self.line_hint) catch @panic("oom");
        }
        self.freereg = self.nvarstack;
        self.peak_freereg = self.nvarstack;
    }

    // -----------------------------------------------------------------------
    // Scope management
    // -----------------------------------------------------------------------

    fn pushScope(self: *Codegen) Error!void {
        try self.scope_marks.append(self.alloc, self.bindings.items.len);
        try self.label_scope_marks.append(self.alloc, self.active_labels.items.len);
        try self.scope_ids.append(self.alloc, self.scope_counter);
        self.scope_counter += 1;
        try self.global_scope_marks.append(self.alloc, .{
            .mode = self.strict_globals_mode,
            .wildcard_const = self.strict_globals_wildcard_const,
            .decl_log_len = self.declared_globals_log.items.len,
            .decl_depth_log_len = self.declared_globals_depth_log.items.len,
        });
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

    fn popScope(self: *Codegen) void {
        // Adopt unresolved pending gotos from this scope into the parent
        // scope, so they can still match labels in enclosing scopes.
        if (self.scope_marks.items.len >= 2) {
            const parent_depth = self.scope_marks.items.len - 1;
            for (self.pending_gotos.items) |*pg| {
                if (!pg.resolved and pg.depth == self.scope_marks.items.len) {
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
        const n = self.scope_marks.items.len;
        std.debug.assert(n > 0);
        const mark = self.scope_marks.items[n - 1];
        self.scope_marks.items.len = n - 1;

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
            const first_dead = self.bindings.items[mark].reg;
            const last_dead = self.bindings.items[self.bindings.items.len - 1].reg;
            if (last_dead >= first_dead) {
                _ = self.builder.emitABC(.loadnil, first_dead, last_dead - first_dead, 0, self.line_hint) catch @panic("oom");
            }
            // Clear attribute markers for departing locals.
            for (self.bindings.items[mark..]) |b| {
                _ = self.const_locals.remove(b.reg);
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
        self.bindings.items.len = mark;
        self.popGlobalScope();
    }

    fn popScopeNoClear(self: *Codegen) void {
        if (self.scope_marks.items.len >= 2) {
            const parent_depth = self.scope_marks.items.len - 1;
            for (self.pending_gotos.items) |*pg| {
                if (!pg.resolved and pg.depth == self.scope_marks.items.len) {
                    pg.depth = parent_depth;
                }
            }
        }
        const ln = self.label_scope_marks.items.len;
        self.active_labels.items.len = self.label_scope_marks.items[ln - 1];
        self.label_scope_marks.items.len = ln - 1;
        self.scope_ids.items.len -= 1;
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
        self.peak_freereg = self.nvarstack;
        self.bindings.items.len = mark;
        self.popGlobalScope();
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

    fn markReadonlyLocal(self: *Codegen, reg: u8) void {
        self.readonly_locals.put(self.alloc, reg, {}) catch @panic("oom");
    }

    fn markCloseLocal(self: *Codegen, reg: u8) void {
        self.close_locals.put(self.alloc, reg, {}) catch @panic("oom");
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
            // Not in outer's locals or upvalues — recurse further up.
            // After the recursive call, outer will have the upvalue
            // registered. We then create a corresponding entry in SELF
            // that references outer's upvalue (instack=false).
            const outer_idx = try outer.ensureUpvalue(name);
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
                const parsed: i64 = parseIntegerLiteral(lexeme) orelse {
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
                const kid = try self.builder.internConst(bc.Constant.num(val));
                try self.emitLoadK(dst, kid, e.span.line);
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
                if (n.op == .And) return self.genAndExp(n.lhs, n.rhs, e.span.line);
                if (n.op == .Or) return self.genOrExp(n.lhs, n.rhs, e.span.line);
                return self.genBinOp(n, e.span.line);
            },
            .UnOp => |n| {
                return self.genUnOp(n, e.span.line);
            },
            .Field => |n| {
                // t.k  →  GETFIELD R[dst] R[t] K[k]
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
            const dst = try self.allocReg();
            _ = try self.builder.emitABC(.move, dst, binding.reg, 0, span.line);
            return dst;
        }
        // A declaration in this function or an enclosing function forces the
        // name to be global before upvalue lookup. In particular, this keeps a
        // recursive `global function f()` from capturing an outer local `f`.
        if (self.isForcedGlobalName(name)) {
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
        if (self.lookupLocal("_ENV")) |env_reg| {
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
    fn emitGlobalSet(self: *Codegen, name_kid: u32, val_reg: u8, line: u32) Error!void {
        if (self.lookupLocal("_ENV")) |env_reg| {
            if (name_kid <= 255) {
                _ = try self.builder.emitABC(.setfield, env_reg, @intCast(name_kid), val_reg, line);
            } else {
                const key_reg = try self.allocReg();
                try self.emitLoadK(key_reg, name_kid, line);
                _ = try self.builder.emitABC(.settable, env_reg, key_reg, val_reg, line);
                self.freeReg(key_reg);
            }
        } else {
            const env_idx = try self.ensureEnvUpvalue();
            try self.emitSetTabUp(env_idx, name_kid, val_reg, line);
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

    fn emitSetName(self: *Codegen, span: ast.Span, name: []const u8, val_reg: u8) Error!void {
        if (self.isForcedGlobalName(name)) {
            const kid = try self.builder.internString(name);
            try self.emitGlobalSet(kid, val_reg, span.line);
            return;
        }
        if (self.lookupLocal(name)) |reg| {
            if (self.isReadonlyLocal(reg)) {
                self.setDiag(span, "cannot assign to const local");
                return error.CodegenError;
            }
            _ = try self.builder.emitABC(.move, reg, val_reg, 0, span.line);
            return;
        }
        if (self.upvalues.get(name)) |idx| {
            if (self.isConstUpvalue(idx)) {
                self.setDiag(span, "cannot assign to const upvalue");
                return error.CodegenError;
            }
            _ = try self.builder.emitABC(.setupval, val_reg, idx, 0, span.line);
            return;
        }
        const kid = try self.builder.internString(name);
        try self.emitGlobalSet(kid, val_reg, span.line);
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

    fn genBinOp(self: *Codegen, n: anytype, line: u32) Error!u8 {
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
        if (n.op == .Concat) {
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

        // C=0: skip next JMP when condition is TRUE → fall through to LOADTRUE.
        // C=1: skip next JMP when condition is FALSE → fall through to LOADTRUE
        // (used for NotEq: skip when NOT equal, i.e., when condition is false).
        const invert: u8 = if (op == .NotEq) 1 else 0;

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

    fn genUnOp(self: *Codegen, n: anytype, line: u32) Error!u8 {
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
                    const start = i + 1;
                    // Skip first newline if present.
                    const s = if (start < raw.len and raw[start] == '\n') start + 1 else if (start + 1 < raw.len and raw[start] == '\r' and raw[start + 1] == '\n') start + 2 else start;
                    return raw[s .. raw.len - close_len];
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
                    '\n' => pos += 1, // line continuation
                    '\r' => {
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

        // Compile function expression into a register.
        const func_reg = try self.genExp(call_node.func);

        // Compile arguments into consecutive registers after func_reg.
        // PUC CALL expects R[A+1], R[A+2], ... to physically contain the
        // argument values. `genExp(Name)` can return an existing local register
        // without allocating a new temporary, so we must explicitly move such
        // values into the call frame slots.
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
        _ = try self.builder.emitABC(.call, func_reg, b, c, line);

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

        // Compile receiver.
        const obj_reg = try self.genExp(mc.receiver);

        // SELF: R[obj_reg+1] = R[obj_reg]; R[obj_reg] = R[obj_reg][K[method]]
        const kid = try self.builder.internString(mc.method.slice(self.source));
        if (kid <= 255) {
            _ = try self.builder.emitABC(.self, obj_reg, obj_reg, @intCast(kid), line);
        } else {
            // Fallback: load method string, gettable, move self.
            const key = try self.allocReg();
            try self.emitLoadK(key, kid, line);
            const method_reg = try self.allocReg();
            _ = try self.builder.emitABC(.gettable, method_reg, obj_reg, key, line);
            _ = try self.builder.emitABC(.move, obj_reg + 1, obj_reg, 0, line);
            _ = try self.builder.emitABC(.move, obj_reg, method_reg, 0, line);
            self.freeReg2(method_reg, key);
        }
        self.freereg = obj_reg + 2;
        if (obj_reg + 2 > self.peak_freereg) self.peak_freereg = obj_reg + 2;

        // Compile args.
        for (mc.args, 0..) |arg, i| {
            const is_last = (i + 1 == mc.args.len);
            if (is_last) {
                switch (arg.node) {
                    .Call, .MethodCall => _ = try self.genCallMulti(arg, line),
                    .Dots => {
                        const va_reg = try self.allocReg();
                        _ = try self.builder.emitABC(.vararg, va_reg, 0, 0, arg.span.line);
                    },
                    else => _ = try self.genExp(arg),
                }
            } else {
                _ = try self.genExp(arg);
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
        _ = try self.builder.emitABC(.call, obj_reg, b, c, line);

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
        return obj_reg;
    }

    // -----------------------------------------------------------------------
    // Table constructors
    // -----------------------------------------------------------------------

    fn genTable(self: *Codegen, n: anytype, line: u32) Error!u8 {
        const dst = try self.allocReg();
        _ = try self.builder.emitABC(.newtable, dst, 0, 0, line);

        // Track array index for SETLIST.
        var array_count: u32 = 0;
        var flush_base: u32 = 0;

        for (n.fields, 0..) |f, fi| {
            const is_last = (fi + 1 == n.fields.len);
            switch (f.node) {
                .Array => |val_e| {
                    if (is_last) {
                        switch (val_e.node) {
                            .Call, .MethodCall => {
                                // Multi-value: compile call with set top, then SETLIST with B=0.
                                _ = try self.genCallMulti(val_e, line);
                                _ = try self.builder.emitABC(.setlist, dst, 0, @intCast(flush_base), line);
                                self.freereg = dst + 1;
                                array_count = 0;
                                continue;
                            },
                            .Dots => {
                                if (!self.is_vararg) {
                                    self.setDiag(val_e.span, "vararg used in non-vararg function");
                                    return error.CodegenError;
                                }
                                const va_reg = try self.allocReg();
                                _ = try self.builder.emitABC(.vararg, va_reg, 0, 0, val_e.span.line);
                                _ = try self.builder.emitABC(.setlist, dst, 0, @intCast(flush_base), line);
                                self.freereg = dst + 1;
                                array_count = 0;
                                continue;
                            },
                            else => {},
                        }
                    }
                    _ = try self.genExp(val_e);
                    array_count += 1;
                    // Flush if we have enough values (PUC flushes at ~50).
                    if (array_count >= 50) {
                        _ = try self.builder.emitABC(.setlist, dst, @intCast(array_count), @intCast(flush_base), line);
                        self.freereg = dst + 1;
                        flush_base += array_count;
                        array_count = 0;
                    }
                },
                .Name => |nv| {
                    // Flush pending array values first.
                    if (array_count > 0) {
                        _ = try self.builder.emitABC(.setlist, dst, @intCast(array_count), @intCast(flush_base), line);
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
                },
                .Index => |kv| {
                    if (array_count > 0) {
                        _ = try self.builder.emitABC(.setlist, dst, @intCast(array_count), @intCast(flush_base), line);
                        self.freereg = dst + 1;
                        flush_base += array_count;
                        array_count = 0;
                    }
                    const key = try self.genExp(kv.key);
                    const val = try self.genExp(kv.value);
                    _ = try self.builder.emitABC(.settable, dst, key, val, kv.key.span.line);
                    self.freeReg2(val, key);
                },
            }
        }

        // Flush remaining array values.
        if (array_count > 0) {
            _ = try self.builder.emitABC(.setlist, dst, @intCast(array_count), @intCast(flush_base), line);
            self.freereg = dst + 1;
        }

        return dst;
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
            _ = try self.builder.emitABC(.closure, dst, proto_idx, 0, line);
        } else {
            // Large proto index — needs EXTRAARG.
            _ = try self.builder.emitABC(.closure, dst, 0, 0, line);
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
        child.outer = self;
        child.builder.name = name;
        child.builder.source_name = self.source_name;
        child.builder.line_defined = line;
        child.builder.last_line_defined = line;

        // If this is a method, "self" is the first parameter.
        if (self_name) |sn| {
            const reg = try child.declareLocal(sn);
            _ = reg;
        }

        try child.compileFuncBody(body);
        return child.builder.finish();
    }

    /// Compile a function body (parameters + block).
    fn compileFuncBody(self: *Codegen, body: *const ast.FuncBody) Error!void {
        // For the main chunk (outer == null), _ENV is upvalue 0 (instack=true,
        // idx=0) — it represents the environment passed by the host.
        // For child functions, _ENV is lazily created when a global name
        // is first encountered, matching PUC Lua's singlevaraux behavior.
        if (self.outer == null) {
            const idx: u8 = @intCast(self.upvalue_descs.items.len);
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
            // Named vararg (Lua 5.5): creates a table.
            if (va.name) |va_name| {
                // The vararg table goes in a register after params.
                const va_reg = try self.declareLocal(va_name.slice(self.source));
                self.builder.vararg_table_reg = va_reg;
            }
            // Emit VARARGPREP as first instruction.
            _ = try self.builder.emitABC(.varargprep, self.builder.numparams, 0, 0, 0);
        }

        // Compile the body block.
        try self.genBlock(body.body);

        // Implicit return at end.
        _ = try self.builder.emitSimple(.return0, self.line_hint);

        // Transfer upvalue descriptions to the builder.
        for (self.upvalue_descs.items) |desc| {
            _ = try self.builder.addUpvalue(desc);
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
                        _ = try self.genExp(exp);
                        return @intCast(exps.len);
                    },
                }
            } else {
                _ = try self.genExp(exp);
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
                    },
                    else => {
                        _ = try self.genExp(exp);
                    },
                }
            } else {
                _ = try self.genExp(exp);
            }
        }
        while (self.freereg < base + wanted) {
            const nil_reg = try self.allocReg();
            _ = try self.builder.emitABC(.loadnil, nil_reg, 0, 0, line);
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
            .Goto => |n| {
                const name = n.label.slice(self.source);
                // Search active labels from innermost outward.
                var found: ?u32 = null;
                var i = self.active_labels.items.len;
                while (i > 0) {
                    i -= 1;
                    if (std.mem.eql(u8, self.active_labels.items[i].name, name)) {
                        found = self.active_labels.items[i].pc;
                        break;
                    }
                }
                if (found) |target_pc| {
                    const label = blk: {
                        var j = self.active_labels.items.len;
                        while (j > 0) {
                            j -= 1;
                            if (std.mem.eql(u8, self.active_labels.items[j].name, name)) break :blk self.active_labels.items[j];
                        }
                        break :blk null;
                    };
                    if (label) |lbl| {
                        if (self.bindings.items.len > lbl.binding_mark) {
                            const first_reg = self.bindings.items[lbl.binding_mark].reg;
                            _ = try self.builder.emitABC(.close, first_reg, 0, 0, st.span.line);
                        }
                    }
                    const jmp_pc = try self.emitJump(st.span.line);
                    self.patchJumpTo(jmp_pc, target_pc);
                } else {
                    const jmp_pc = try self.emitJump(st.span.line);
                    try self.pending_gotos.append(self.alloc, .{
                        .pc = jmp_pc,
                        .name = name,
                        .depth = self.scope_marks.items.len,
                        .scope_id = self.scope_ids.items[self.scope_ids.items.len - 1],
                        .resolved = false,
                    });
                }
                return false;
            },
            .Label => |n| {
                const name = n.label.slice(self.source);
                const target_pc = self.builder.pc();
                const lbl_scope_id = self.scope_ids.items[self.scope_ids.items.len - 1];
                try self.active_labels.append(self.alloc, .{
                    .name = name,
                    .pc = target_pc,
                    .depth = self.scope_marks.items.len,
                    .scope_id = lbl_scope_id,
                    .binding_mark = self.bindings.items.len,
                });
                // Resolve pending forward gotos to this label.
                // A goto can only jump to a label in its own scope or an
                // ENCLOSING scope (shallower depth). Sibling scopes at the
                // same depth must NOT match. After popScope adopts a goto
                // to its parent, pg.depth decreases, so a label in a
                // sibling (deeper) scope won't match.
                for (self.pending_gotos.items) |*pg| {
                    if (!pg.resolved and std.mem.eql(u8, pg.name, name)) {
                        if (self.scope_marks.items.len <= pg.depth) {
                            self.patchJumpTo(pg.pc, target_pc);
                            pg.resolved = true;
                        }
                    }
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
                if (proto_idx <= 255) {
                    _ = try self.builder.emitABC(.closure, reg, proto_idx, 0, st.span.line);
                } else {
                    _ = try self.builder.emitABC(.closure, reg, 0, 0, st.span.line);
                    _ = try self.builder.emit(Instruction.extra(proto_idx), st.span.line);
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
                if (proto_idx <= 255) {
                    _ = try self.builder.emitABC(.closure, func_reg, proto_idx, 0, body_line);
                } else {
                    _ = try self.builder.emitABC(.closure, func_reg, 0, 0, body_line);
                    _ = try self.builder.emit(Instruction.extra(proto_idx), body_line);
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
                try self.declareGlobalName(global_name);
                const child = try self.compileChildFunction(
                    global_name,
                    n.body,
                    null,
                    st.span.line,
                );
                const proto_idx = try self.builder.addProto(child);
                const func_reg = try self.allocReg();
                if (proto_idx <= 255) {
                    _ = try self.builder.emitABC(.closure, func_reg, proto_idx, 0, st.span.line);
                } else {
                    _ = try self.builder.emitABC(.closure, func_reg, 0, 0, st.span.line);
                    _ = try self.builder.emit(Instruction.extra(proto_idx), st.span.line);
                }
                const kid = try self.builder.internString(global_name);
                try self.emitGlobalSet(kid, func_reg, st.span.line);
                self.freeReg(func_reg);
                return false;
            },
            .GlobalDecl => |n| {
                // global a, b, c = ...  (with values: assign to _ENV)
                // global a, b, c        (without values: just declarations, no code)
                if (n.star) {
                    const readonly = if (n.prefix_attr) |attr| attr.kind == .Const or attr.kind == .Close else false;
                    self.declareGlobalWildcard(readonly);
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
                        _ = try self.genExp(value);
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
                            else => _ = try self.genExp(last),
                        }
                    }
                }

                for (n.names) |decl| {
                    try self.declareGlobalName(decl.name.slice(self.source));
                }

                if (n.values != null) {
                    for (n.names, 0..) |decl, i| {
                        const value_reg = init_base + @as(u8, @intCast(i));
                        const values = n.values.?;
                        if (!(i < values.len or i >= expanded_first_name)) {
                            if (value_reg >= self.freereg) try self.ensureFreeregAtLeast(value_reg + 1);
                            _ = try self.builder.emitABC(.loadnil, value_reg, 0, 0, st.span.line);
                        }
                        const kid = try self.builder.internString(decl.name.slice(self.source));
                        try self.emitGlobalSet(kid, value_reg, st.span.line);
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
                _ = try self.genExp(val);
            }
            // Last value: if it's a call/vararg, use multi-value expansion.
            const last_expands = values.len > 0 and switch (values[values.len - 1].node) {
                .Call, .MethodCall, .Dots => true,
                else => false,
            };
            const expanded_first_name = if (last_expands) values.len - 1 else n.names.len;
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
                        _ = try self.genExp(last);
                    },
                }
            }
            // Declare locals: each name gets the next register from base.
            for (n.names, 0..) |dn, i| {
                const reg = base + @as(u8, @intCast(i));
                if (i < values.len or i >= expanded_first_name) {
                    // Value already in this register — just promote to local.
                    if (reg >= self.nvarstack) {
                        self.nvarstack = reg + 1;
                        self.freereg = @max(self.freereg, self.nvarstack);
                    }
                } else {
                    // Fewer values than names — nil-fill.
                    if (reg >= self.freereg) try self.reserveRegs(1);
                    _ = try self.builder.emitABC(.loadnil, reg, 0, 0, line);
                    self.nvarstack = reg + 1;
                    self.freereg = @max(self.freereg, self.nvarstack);
                }
                try self.bindings.append(self.alloc, .{
                    .name = dn.name.slice(self.source),
                    .reg = reg,
                    .depth = self.scope_marks.items.len,
                });
                if (dn.prefix_attr orelse dn.suffix_attr) |attr| {
                    if (attr.kind == .Const) self.markConstLocal(reg);
                    if (attr.kind == .Close) {
                        self.markCloseLocal(reg);
                        _ = try self.builder.emitABC(.tbc, reg, 0, 0, line);
                    }
                }
            }
        } else {
            // No values: declare all as nil.
            for (n.names) |dn| {
                const reg = try self.allocReg();
                _ = try self.builder.emitABC(.loadnil, reg, 0, 0, line);
                self.nvarstack = @max(self.nvarstack, reg + 1);
                try self.bindings.append(self.alloc, .{
                    .name = dn.name.slice(self.source),
                    .reg = reg,
                    .depth = self.scope_marks.items.len,
                });
                if (dn.prefix_attr orelse dn.suffix_attr) |attr| {
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
            const rhs_reg = try self.genExp(n.rhs[0]);
            try self.genSet(n.lhs[0], rhs_reg, line);
            self.freeReg(rhs_reg);
            return false;
        }
        var prepared = std.ArrayListUnmanaged(PreparedLhs).empty;
        defer prepared.deinit(self.alloc);
        for (n.lhs) |lhs| {
            try prepared.append(self.alloc, try self.prepareAssignLhs(lhs, line));
        }
        // Multi-assign: compile RHS into consecutive registers, then assign.
        const base = self.freereg;
        for (n.rhs, 0..) |val, i| {
            const is_last = (i + 1 == n.rhs.len);
            if (is_last and n.lhs.len > n.rhs.len) {
                // Last RHS with more LHS than RHS: adjust multi-value.
                const nresults: i32 = @intCast(n.lhs.len - i);
                switch (val.node) {
                    .Call, .MethodCall => _ = try self.genCall(val, nresults, line),
                    .Dots => {
                        const va_reg = try self.allocReg();
                        const c: u8 = @intCast(nresults + 1);
                        _ = try self.builder.emitABC(.vararg, va_reg, 0, c, val.span.line);
                    },
                    else => _ = try self.genExp(val),
                }
            } else {
                _ = try self.genExp(val);
            }
        }
        // Nil-fill missing values.
        while (self.freereg < base + n.lhs.len) {
            const r = try self.allocReg();
            _ = try self.builder.emitABC(.loadnil, r, 0, 0, line);
        }
        // Assign: each LHS gets the value from base + index.
        for (prepared.items, 0..) |lhs, i| {
            const src_reg: u8 = @intCast(base + i);
            try self.genPreparedSet(lhs, src_reg);
        }
        self.freePreparedLhs(prepared.items);
        self.freereg = base;
        return false;
    }

    fn prepareAssignLhs(self: *Codegen, lhs: *const ast.Exp, line: u32) Error!PreparedLhs {
        return switch (lhs.node) {
            .Field => |n| blk: {
                const obj = try self.genExp(n.object);
                const key = try self.builder.internString(n.name.slice(self.source));
                break :blk .{ .field = .{ .object = obj, .key = key, .line = line } };
            },
            .Index => |n| blk: {
                const obj = try self.genExp(n.object);
                const key = try self.genExp(n.index);
                break :blk .{ .index = .{ .object = obj, .key = key, .line = line } };
            },
            else => .{ .direct = lhs },
        };
    }

    fn genPreparedSet(self: *Codegen, lhs: PreparedLhs, val_reg: u8) Error!void {
        switch (lhs) {
            .direct => |e| try self.genSet(e, val_reg, self.line_hint),
            .field => |f| {
                if (f.key <= 255) {
                    _ = try self.builder.emitABC(.setfield, f.object, @intCast(f.key), val_reg, f.line);
                } else {
                    const key_reg = try self.allocReg();
                    try self.emitLoadK(key_reg, f.key, f.line);
                    _ = try self.builder.emitABC(.settable, f.object, key_reg, val_reg, f.line);
                    self.freeReg(key_reg);
                }
            },
            .index => |idx| {
                _ = try self.builder.emitABC(.settable, idx.object, idx.key, val_reg, idx.line);
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

    /// Store a value to an lvalue (local, global, table field, table index).
    fn genSet(self: *Codegen, lhs: *const ast.Exp, val_reg: u8, line: u32) Error!void {
        switch (lhs.node) {
            .Name => |n| {
                const name = n.slice(self.source);
                if (self.isForcedGlobalName(name)) {
                    const kid = try self.builder.internString(name);
                    try self.emitGlobalSet(kid, val_reg, line);
                    return;
                }
                if (self.lookupLocal(name)) |reg| {
                    if (self.isReadonlyLocal(reg)) {
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
                // Try to capture from outer scope (the variable may only
                // be written, never read, so ensureUpvalue wasn't called yet).
                if (self.outer != null) {
                    if (self.ensureUpvalue(name)) |idx| {
                        _ = try self.builder.emitABC(.setupval, val_reg, idx, 0, line);
                        return;
                    } else |_| {}
                }
                // Global: _ENV[name] = val
                const kid = try self.builder.internString(name);
                try self.emitGlobalSet(kid, val_reg, line);
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

    fn genReturn(self: *Codegen, n: anytype, line: u32) Error!bool {
        if (n.values.len == 0) {
            _ = try self.builder.emitSimple(.return0, line);
        } else if (n.values.len == 1) {
            // PUC Lua: `return f(args)` is a tail call.
            switch (n.values[0].node) {
                .Call, .MethodCall => {
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
                    const reg = try self.genExp(n.values[0]);
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
                        _ = try self.genExp(val);
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
                        _ = try self.genExp(val);
                    }
                    const va_reg = try self.allocReg();
                    _ = try self.builder.emitABC(.vararg, va_reg, 0, 0, line);
                    _ = try self.builder.emitABC(.return_, ret_base, 0, 0, line);
                },
                else => {
                    const base = self.freereg;
                    for (n.values) |val| {
                        _ = try self.genExp(val);
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
            const obj_reg = try self.genExp(mc.receiver);
            const kid = try self.builder.internString(mc.method.slice(self.source));
            if (kid <= 255) {
                _ = try self.builder.emitABC(.self, obj_reg, obj_reg, @intCast(kid), line);
            } else {
                const key = try self.allocReg();
                try self.emitLoadK(key, kid, line);
                const method_reg = try self.allocReg();
                _ = try self.builder.emitABC(.gettable, method_reg, obj_reg, key, line);
                _ = try self.builder.emitABC(.move, obj_reg + 1, obj_reg, 0, line);
                _ = try self.builder.emitABC(.move, obj_reg, method_reg, 0, line);
                self.freeReg2(method_reg, key);
            }
            self.freereg = obj_reg + 2;
            if (obj_reg + 2 > self.peak_freereg) self.peak_freereg = obj_reg + 2;
            for (mc.args, 0..) |arg, i| {
                const is_last = (i + 1 == mc.args.len);
                if (is_last) {
                    switch (arg.node) {
                        .Call, .MethodCall => _ = try self.genCallMulti(arg, line),
                        .Dots => {
                            const va_reg = try self.allocReg();
                            _ = try self.builder.emitABC(.vararg, va_reg, 0, 0, arg.span.line);
                        },
                        else => _ = try self.genExp(arg),
                    }
                } else {
                    _ = try self.genExp(arg);
                }
            }
            const has_multret_last = mc.args.len > 0 and switch (mc.args[mc.args.len - 1].node) {
                .Call, .MethodCall, .Dots => true,
                else => false,
            };
            const b: u8 = if (has_multret_last) 0 else @intCast(mc.args.len + 2);
            _ = try self.builder.emitABC(.tailcall, obj_reg, b, 0, line);
            return true;
        }

        const call_node = switch (e.node) {
            .Call => |c| c,
            else => unreachable,
        };

        // Compile function expression into a register.
        const func_reg = try self.genExp(call_node.func);
        self.freereg = func_reg + 1;
        for (call_node.args, 0..) |arg, i| {
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
                    else => _ = try self.genExp(arg),
                }
            } else {
                _ = try self.genExp(arg);
            }
        }

        const has_multret_last = call_node.args.len > 0 and switch (call_node.args[call_node.args.len - 1].node) {
            .Call, .MethodCall, .Dots => true,
            else => false,
        };
        const b: u8 = if (has_multret_last) 0 else @intCast(call_node.args.len + 1);
        _ = try self.builder.emitABC(.tailcall, func_reg, b, 0, line);
        return true;
    }

    fn genIf(self: *Codegen, n: anytype, line: u32) Error!bool {
        // Collect all JMP-to-end instructions (one per non-empty branch).
        var end_jumps: std.ArrayListUnmanaged(u32) = .empty;
        defer end_jumps.deinit(self.alloc);

        // Compile condition.
        const cond = try self.genExp(n.cond);

        // TEST cond 0 (skip JMP when truthy → fall through to then block).
        _ = try self.builder.emitABC(.test_, cond, 0, 0, line);
        self.freeReg(cond);
        const jmp_to_else = try self.emitJump(line);

        // Then block.
        try self.genBlock(n.then_block);

        // JMP to end (if there are elseif/else branches).
        if (n.else_block != null or n.elseifs.len > 0) {
            const ej = try self.emitJump(line);
            end_jumps.append(self.alloc, ej) catch @panic("oom");
        }

        // Else target.
        self.patchJumpToHere(jmp_to_else);

        // Elseifs.
        for (n.elseifs) |eif| {
            const econd = try self.genExp(eif.cond);
            _ = try self.builder.emitABC(.test_, econd, 0, 0, eif.cond.span.line);
            self.freeReg(econd);
            const ejmp = try self.emitJump(eif.cond.span.line);
            try self.genBlock(eif.block);
            // Each elseif needs its own JMP to end.
            const ej = try self.emitJump(line);
            end_jumps.append(self.alloc, ej) catch @panic("oom");
            self.patchJumpToHere(ejmp);
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
        // Loop start.
        const loop_start = self.builder.pc();

        // Condition.
        const cond = try self.genExp(n.cond);
        _ = try self.builder.emitABC(.test_, cond, 0, 0, n.cond.span.line);
        self.freeReg(cond);

        // JMP to end if falsy.
        const jmp_end = try self.emitJump(n.cond.span.line);

        // Body.
        try self.pushScope();
        const scope_mark = self.scope_marks.items[self.scope_marks.items.len - 1];
        // Breaks need their own cleanup path: close body locals, then exit.
        // They must not jump to the normal back-edge, otherwise `break` would
        // close locals and continue the loop.
        try self.pushLoopEnd(0);
        const break_slot = self.loop_ends.items.len - 1;
        try self.genBlockNoScope(n.block);
        const break_jump_pc = self.loop_ends.items[break_slot].pc;
        self.popLoopEnd();

        const first_body_reg: ?u8 = if (self.bindings.items.len > scope_mark)
            self.bindings.items[scope_mark].reg
        else
            null;

        // Normal iteration cleanup before jumping back to the condition.
        if (first_body_reg) |reg| {
            _ = try self.builder.emitABC(.close, reg, 0, 0, line);
        }

        // JMP back to start.
        const back_jmp = try self.emitJump(line);
        const offset: i32 = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(back_jmp)) - 1;
        self.builder.patchJumpOffset(back_jmp, offset);

        // Break cleanup path: close the same body locals, then fall through to
        // loop end. Falsy condition jumps directly to end and does not enter the
        // body scope, so it does not need this cleanup.
        const break_cleanup = self.builder.pc();
        if (first_body_reg) |reg| {
            _ = try self.builder.emitABC(.close, reg, 0, 0, line);
        }
        if (break_jump_pc != 0) {
            self.patchJumpTo(break_jump_pc, break_cleanup);
        }
        self.popScopeNoClear();

        // End target.
        self.patchJumpToHere(jmp_end);
        return false;
    }

    fn genRepeat(self: *Codegen, n: anytype, line: u32) Error!bool {
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
        // TEST C=1: if FALSY, skip next instruction (JMP to exit).
        // If truthy: don't skip → JMP exit.
        // If falsy: skip JMP → fall through to CLOSE + JMP loop_start.
        _ = try self.builder.emitABC(.test_, cond, 0, 1, n.cond.span.line); // skip if falsy
        self.freeReg(cond);
        // Truthy: close body locals, then exit.
        const jmp_exit = try self.emitJump(n.cond.span.line);

        // Falsy path: close body locals, then loop back.
        const scope_mark = self.scope_marks.items[self.scope_marks.items.len - 1];
        const first_body_reg: ?u8 = if (self.bindings.items.len > scope_mark)
            self.bindings.items[scope_mark].reg
        else
            null;
        if (first_body_reg) |first_reg| {
            _ = try self.builder.emitABC(.close, first_reg, 0, 0, n.cond.span.line);
        }
        const jmp_back = try self.emitJump(n.cond.span.line);
        const offset: i32 = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(jmp_back)) - 1;
        self.builder.patchJumpOffset(jmp_back, offset);

        // Exit cleanup target (truthy path lands here).
        const exit_target = self.builder.pc();
        if (first_body_reg) |first_reg| {
            _ = try self.builder.emitABC(.close, first_reg, 0, 0, n.cond.span.line);
        }
        const exit_offset: i32 = @as(i32, @intCast(exit_target)) - @as(i32, @intCast(jmp_exit)) - 1;
        self.builder.patchJumpOffset(jmp_exit, exit_offset);

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
        _ = try self.genExp(n.init);
        _ = try self.genExp(n.limit);
        if (n.step) |s| {
            _ = try self.genExp(s);
        } else {
            // Default step = 1.
            const step_reg = try self.allocReg();
            _ = try self.builder.emitABC(.loadi, step_reg, 1, 0, line); // LOADI R 1
        }

        // Declare loop variable at base+3.
        self.freereg = base + 3;
        self.nvarstack = base + 3;
        const loop_var = try self.declareLocal(n.name.slice(self.source));
        self.markReadonlyLocal(loop_var);

        // FORPREP A offset: A=base, offset in B:C (16-bit signed).
        const forprep_pc = try self.builder.emitABC(.forprep, base, 0, 0, line);

        // Loop body.
        const body_start = self.builder.pc();
        try self.pushScope();
        try self.pushLoopEnd(0); // break target — patched later
        const break_slot = self.loop_ends.items.len - 1;
        try self.genBlock(n.block);
        // Save break jump PC for patching AFTER CLOSE+FORLOOP.
        const break_jump_pc = self.loop_ends.items[break_slot].pc;
        self.popLoopEnd();
        self.popScope();

        // Close upvalues for locals declared in the loop body (including
        // the control variable).  This makes each iteration's closures
        // independent — PUC Lua emits CLOSE before FORLOOP for this reason.
        // A = base + 3 (the control variable register), which closes
        // everything >= base+3.
        _ = try self.builder.emitABC(.close, base + 3, 0, 0, line);

        // FORLOOP A offset: A=base, offset in B:C.
        const forloop_pc = try self.builder.emitABC(.forloop, base, 0, 0, line);
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

        // Mark the 4th value (close) as to-be-closed.
        _ = try self.builder.emitABC(.tbc, base + 3, 0, 0, line);

        // Declare loop variables at base+4, base+5, ...
        self.freereg = base + 4;
        self.nvarstack = base + 4;
        for (n.names) |nm| {
            _ = try self.declareLocal(nm.slice(self.source));
        }
        // First loop variable is const (control variable).
        if (n.names.len > 0) {
            self.markReadonlyLocal(base + 4);
        }

        // TFORPREP A offset: A=base, offset in B:C.
        const tforprep_pc = try self.builder.emitABC(.tforprep, base, 0, 0, line);

        // Loop body.
        const body_start = self.builder.pc();
        try self.pushScope();
        try self.pushLoopEnd(0);
        const break_slot = self.loop_ends.items.len - 1;
        try self.genBlock(n.block);
        const break_jump_pc = self.loop_ends.items[break_slot].pc;
        self.popLoopEnd();
        self.popScope();

        // Close upvalues for locals declared in the loop body.
        _ = try self.builder.emitABC(.close, base + 4, 0, 0, line);

        // TFORCALL A C: R[base+4..base+3+C] := R[base](R[base+1], R[base+2])
        const n_results: u8 = @intCast(n.names.len + 1);
        const tforcall_pc = try self.builder.emitABC(.tforcall, base, 0, n_results, line);

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

        return false;
    }

    // -----------------------------------------------------------------------
    // Block compilation
    // -----------------------------------------------------------------------

    fn genBlock(self: *Codegen, block: *const ast.Block) Error!void {
        try self.pushScope();
        var terminated = false;
        for (block.stats) |*st| {
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

    fn genBlockNoScope(self: *Codegen, block: *const ast.Block) Error!void {
        for (block.stats) |*st| {
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

        // Reserve _ENV as upvalue 0 (like PUC Lua).
        _ = try self.builder.addUpvalue(.{
            .instack = false,
            .idx = 0,
            .is_const = false,
            .name = "_ENV",
        });
        try self.upvalues.put(self.alloc, "_ENV", 0);

        // Emit VARARGPREP if vararg.
        if (self.is_vararg) {
            _ = try self.builder.emitABC(.varargprep, 0, 0, 0, chunk.span.line);
        }

        // Compile the block.
        try self.genBlock(chunk.block);

        // Implicit return at end of chunk.
        _ = try self.builder.emitSimple(.return0, self.line_hint);

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

test "codegen: for loop" {
    const testing = std.testing;

    const source = "local s = 0\nfor i = 1, 10 do\ns = s + i\nend\nreturn s";
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

test "codegen: function call" {
    const testing = std.testing;

    const source = "local x = print(42)\nreturn x";
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

    // Create a Vm and execute the proto.
    var v = try vm.Vm.init(testing.allocator);
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

    var v = try vm.Vm.init(testing.allocator);
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

    var v = try vm.Vm.init(testing.allocator);
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
