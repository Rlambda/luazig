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
            // Register clearing is an internal GC-liveness operation, not a
            // Lua source instruction. A zero line keeps it invisible to line
            // hooks while debug.currentline retains the last source line.
            _ = self.builder.emitABC(.loadnil, self.nvarstack, count - 1, 0, 0) catch @panic("oom");
        }
        self.freereg = self.nvarstack;
        self.peak_freereg = self.nvarstack;
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

    fn markReadonlyLocal(self: *Codegen, reg: u8) void {
        self.readonly_locals.put(self.alloc, reg, {}) catch @panic("oom");
    }

    fn markCloseLocal(self: *Codegen, reg: u8) void {
        self.close_locals.put(self.alloc, reg, {}) catch @panic("oom");
        // A <close> variable is read-only after its initialization, exactly
        // like PUC Lua's VDKTOCLOSE kind.
        self.markReadonlyLocal(reg);
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
                const op_line = if (n.op_line != 0) n.op_line else e.span.line;
                if (n.op == .And) return self.genAndExp(n.lhs, n.rhs, op_line);
                if (n.op == .Or) return self.genOrExp(n.lhs, n.rhs, op_line);
                return self.genBinOp(n, op_line);
            },
            .UnOp => |n| {
                const op_line = if (n.op_line != 0) n.op_line else e.span.line;
                return self.genUnOp(n, op_line);
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
        const r = try self.genExp(e);
        if (r + 1 == self.freereg) {
            // Already the most recently allocated register — nothing to do.
            return r;
        }
        // The value is in a non-contiguous register (typically a local).
        // MOVE it into the next free register so callers see a contiguous
        // sequence of values.
        const dst = try self.allocReg();
        _ = try self.builder.emitABC(.move, dst, r, 0, e.span.line);
        return dst;
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
            // Return the local's register directly (PUC VLOCAL semantics).
            // Callers that need the value in a specific position (e.g., genCall
            // for call arguments) already emit MOVE when the register isn't
            // where they need it.  genBinOp frees operands before allocating
            // the result, so using the local register as a source operand is
            // safe — the arithmetic opcode reads it before writing the result.
            return binding.reg;
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
            try self.checkDeclaredGlobal(span, name);
            if (self.isConstGlobal(name)) {
                self.setDiagFmt(span, "attempt to assign to const variable '{s}'", .{name});
                return error.CodegenError;
            }
            const kid = try self.builder.internString(name);
            try self.emitGlobalSet(kid, val_reg, span.line);
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
        try self.checkDeclaredGlobal(span, name);
        if (self.isConstGlobal(name)) {
            self.setDiagFmt(span, "attempt to assign to const variable '{s}'", .{name});
            return error.CodegenError;
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
        // PUC discharges the left expression when it sees the infix operator,
        // so instructions materializing that operand carry the operator line.
        // This matters for line hooks when a binary expression spans large
        // source gaps (the official db.lua suite checks this explicitly).
        const lhs_start_pc: usize = @intCast(self.builder.pc());
        const lhs = try self.genExp(n.lhs);
        const lhs_end_pc: usize = @intCast(self.builder.pc());
        for (self.builder.lineinfo.items[lhs_start_pc..lhs_end_pc]) |*inst_line| {
            inst_line.* = line;
        }
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
                                try self.emitSetList(dst, 0, flush_base, line);
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
                                try self.emitSetList(dst, 0, flush_base, line);
                                self.freereg = dst + 1;
                                array_count = 0;
                                continue;
                            },
                            else => {},
                        }
                    }
                    _ = try self.genExpNextReg(val_e);
                    array_count += 1;
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
                },
            }
        }

        // Flush remaining array values.
        if (array_count > 0) {
            try self.emitSetList(dst, @intCast(array_count), flush_base, line);
            self.freereg = dst + 1;
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
            // Named vararg (Lua 5.5): creates a table.
            if (va.name) |va_name| {
                // The vararg table goes in a register after params.
                const va_reg = try self.declareLocal(va_name.slice(self.source));
                self.markReadonlyLocal(va_reg);
                self.builder.vararg_table_reg = va_reg;
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
                try self.emitGlobalSet(kid, func_reg, st.span.line);
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
                            _ = try self.builder.emitABC(.loadnil, value_reg, 0, 0, st.span.line);
                        }
                        const kid = try self.builder.internString(decl.name.slice(self.source));
                        try self.emitGlobalDefinitionGuard(kid, st.span.line);
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
                _ = try self.genExpNextReg(val);
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
                        _ = try self.genExpNextReg(last);
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
                try self.appendBinding(dn.name.slice(self.source), reg);
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
                try self.appendBinding(dn.name.slice(self.source), reg);
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
            const store_line = self.spanLastTokenLine(n.rhs[0].span);
            try self.genSet(n.lhs[0], rhs_reg, store_line);
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
                    else => _ = try self.genExpNextReg(val),
                }
            } else {
                _ = try self.genExpNextReg(val);
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
                    try self.checkDeclaredGlobal(lhs.span, name);
                    if (self.isConstGlobal(name)) {
                        self.setDiagFmt(lhs.span, "attempt to assign to const variable '{s}'", .{name});
                        return error.CodegenError;
                    }
                    const kid = try self.builder.internString(name);
                    try self.emitGlobalSet(kid, val_reg, line);
                    return;
                }
                if (self.lookupLocal(name)) |reg| {
                    if (self.isReadonlyLocal(reg)) {
                        self.setDiagFmt(lhs.span, "attempt to assign to const variable '{s}'", .{name});
                        return error.CodegenError;
                    }
                    _ = try self.builder.emitABC(.move, reg, val_reg, 0, line);
                    return;
                }
                if (self.upvalues.get(name)) |idx| {
                    if (self.isConstUpvalue(idx)) {
                        self.setDiagFmt(lhs.span, "attempt to assign to const variable '{s}'", .{name});
                        return error.CodegenError;
                    }
                    _ = try self.builder.emitABC(.setupval, val_reg, idx, 0, line);
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
                        _ = try self.builder.emitABC(.setupval, val_reg, idx, 0, line);
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

        // Compile condition.
        const cond = try self.genExp(n.cond);

        // PUC attributes the branch-control instructions to the condition,
        // not to the opening `if` token. This is observable through line hooks
        // when a multiline condition starts below the `if` keyword.
        const cond_line = n.cond.span.line;
        _ = try self.builder.emitABC(.test_, cond, 0, 0, cond_line);
        self.freeReg(cond);
        const jmp_to_else = try self.emitJump(cond_line);

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

        // Else target.
        self.patchJumpToHere(jmp_to_else);

        // Elseifs.
        for (n.elseifs) |eif| {
            const econd = try self.genExp(eif.cond);
            _ = try self.builder.emitABC(.test_, econd, 0, 0, eif.cond.span.line);
            self.freeReg(econd);
            const ejmp = try self.emitJump(eif.cond.span.line);
            try self.genBlock(eif.block);
            // Each elseif needs its own JMP to end. Keep it on the final
            // source line of that branch so the synthetic control transfer does
            // not introduce a spurious line-hook event at the opening `if`.
            const branch_line = if (eif.block.stats.len != 0)
                eif.block.stats[eif.block.stats.len - 1].span.line
            else
                eif.cond.span.line;
            const ej = try self.emitJump(branch_line);
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
        _ = line;
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

        try self.genBlockNoScope(n.block, true);

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
            if (self.anyCapturedInRange(first_reg, self.nvarstack)) {
                _ = try self.builder.emitABC(.close, first_reg, 0, 0, n.cond.span.line);
            }
        }
        const jmp_back = try self.emitJump(n.cond.span.line);
        const offset: i32 = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(jmp_back)) - 1;
        self.builder.patchJumpOffset(jmp_back, offset);

        // Exit cleanup target (truthy path lands here).
        const exit_target = self.builder.pc();
        if (first_body_reg) |first_reg| {
            if (self.anyCapturedInRange(first_reg, self.nvarstack)) {
                _ = try self.builder.emitABC(.close, first_reg, 0, 0, n.cond.span.line);
            }
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
        _ = try self.genExpNextReg(n.init);
        _ = try self.genExpNextReg(n.limit);
        if (n.step) |s| {
            _ = try self.genExpNextReg(s);
        } else {
            // Default step = 1.
            const step_reg = try self.allocReg();
            _ = try self.builder.emitABC(.loadi, step_reg, 1, 0, line); // LOADI R 1
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

    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expect(results[0] == .Thread);
    const th = results[0].Thread;
    try testing.expect(results[1] == .Bool and results[1].Bool);
    try testing.expect(results[2] == .Int and results[2].Int == 41);

    // A direct bytecode yield must retain the authoritative continuation in
    // the thread-owned frame/register/TBC stacks. The IR snapshot list belongs
    // only to the frozen IR backend and must remain empty for bytecode execution.
    try testing.expect(th.bytecode_inplace_suspended);
    try testing.expect(th.bytecode_frames.items.len != 0);
    try testing.expectEqual(@as(usize, 0), th.ir_suspended_frames.items.len);

    var resume_out: [3]vm.Value = .{ .Nil, .Nil, .Nil };
    const resume_count = try v.apiResumeThread(th, &[_]vm.Value{.{ .Int = 42 }}, resume_out[0..]);
    try testing.expectEqual(@as(usize, 2), resume_count);
    try testing.expect(resume_out[0] == .Bool and resume_out[0].Bool);
    try testing.expect(resume_out[1] == .Int and resume_out[1].Int == 42);
    try testing.expect(!th.bytecode_inplace_suspended);
    try testing.expectEqual(@as(usize, 0), th.bytecode_frames.items.len);
    try testing.expectEqual(@as(usize, 0), th.ir_suspended_frames.items.len);
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

    try testing.expectEqual(@as(usize, 3), results.len);
    try testing.expect(results[0] == .Thread);
    const th = results[0].Thread;
    try testing.expect(results[1] == .Bool and results[1].Bool);
    try testing.expect(results[2] == .String);
    try testing.expectEqualStrings("iterator-yield", results[2].String.bytes());

    // The coroutine body and iterator activation remain authoritative in the
    // per-thread explicit stack. No SuspendedFrame replay copy is created.
    try testing.expect(th.bytecode_inplace_suspended);
    try testing.expect(th.bytecode_frames.items.len >= 2);
    try testing.expectEqual(@as(usize, 0), th.suspended_frames.items.len);

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
    try testing.expectEqual(@as(usize, 0), th.bytecode_frames.items.len);
    try testing.expectEqual(@as(usize, 0), th.suspended_frames.items.len);
}
