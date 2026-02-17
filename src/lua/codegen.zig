const std = @import("std");

const Diag = @import("diag.zig").Diag;
const ast = @import("ast.zig");
const ir = @import("ir.zig");

pub const Codegen = struct {
    const StrictGlobalsMode = enum { legacy, strict, wildcard };

    source_name: []const u8,
    source: []const u8,
    alloc: std.mem.Allocator,

    diag: ?Diag = null,
    diag_buf: [256]u8 = undefined,

    next_value: ir.ValueId = 0,
    next_label: ir.LabelId = 0,
    next_local: ir.LocalId = 0,
    next_upvalue: ir.UpvalueId = 0,
    nil_cache: ?ir.ValueId = null,
    insts: std.ArrayListUnmanaged(ir.Inst) = .{},
    inst_lines: std.ArrayListUnmanaged(u32) = .{},
    line_hint: u32 = 0,
    bindings: std.ArrayListUnmanaged(Binding) = .{},
    local_names: std.ArrayListUnmanaged([]const u8) = .{},
    outer: ?*Codegen = null,
    upvalues: std.StringHashMapUnmanaged(ir.UpvalueId) = .{},
    captures: std.ArrayListUnmanaged(ir.Capture) = .{},
    captured_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .{},
    const_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .{},
    close_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .{},
    const_upvalues: std.AutoHashMapUnmanaged(ir.UpvalueId, void) = .{},
    scope_marks: std.ArrayListUnmanaged(usize) = .{},
    scope_depth: usize = 0,
    loop_ends: std.ArrayListUnmanaged(ir.LabelId) = .{},
    labels: std.StringHashMapUnmanaged(LabelInfo) = .{},
    is_vararg: bool = false,
    chunk_is_vararg: bool = false,
    strict_globals_mode: StrictGlobalsMode = .legacy,
    declared_globals: std.StringHashMapUnmanaged(u32) = .{},
    declared_globals_log: std.ArrayListUnmanaged([]const u8) = .{},
    global_attrs: std.StringHashMapUnmanaged(bool) = .{},
    global_attr_log: std.ArrayListUnmanaged(GlobalAttrLog) = .{},
    global_scope_marks: std.ArrayListUnmanaged(GlobalScopeMark) = .{},
    label_has_code_after: bool = true,
    jump_guards: std.ArrayListUnmanaged(JumpGuard) = .{},

    const Binding = struct {
        name: []const u8,
        local: ir.LocalId,
    };

    const LabelInfo = struct {
        id: ir.LabelId,
        defined: bool,
        defined_line: u32 = 0,
        defined_depth: usize = 0,
        first_goto: ?ast.Span = null,
        first_goto_depth: usize = 0,
        first_goto_guard_len: usize = 0,
    };

    const GlobalScopeMark = struct {
        mode: StrictGlobalsMode,
        decl_log_len: usize,
        attr_log_len: usize,
    };

    const GlobalAttrLog = struct {
        name: []const u8,
        had_prev: bool,
        prev: bool = false,
    };

    const JumpGuard = struct {
        name: []const u8,
        depth: usize,
    };

    pub const Error = std.mem.Allocator.Error || error{CodegenError};

    pub fn init(alloc: std.mem.Allocator, source_name: []const u8, source: []const u8) Codegen {
        return .{
            .source_name = source_name,
            .source = source,
            .alloc = alloc,
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

    fn declareGlobalName(self: *Codegen, name: []const u8) Error!void {
        if (self.strict_globals_mode == .wildcard) return;
        self.strict_globals_mode = .strict;
        const entry = try self.declared_globals.getOrPut(self.alloc, name);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
        try self.declared_globals_log.append(self.alloc, name);
    }

    fn declareGlobalWildcard(self: *Codegen) void {
        self.strict_globals_mode = .wildcard;
    }

    fn declareGlobalAttr(self: *Codegen, name: []const u8, readonly: bool) Error!void {
        const prev = self.global_attrs.get(name);
        try self.global_attr_log.append(self.alloc, .{
            .name = name,
            .had_prev = prev != null,
            .prev = prev orelse false,
        });
        try self.global_attrs.put(self.alloc, name, readonly);
    }

    fn isConstGlobal(self: *Codegen, name: []const u8) bool {
        var cur: ?*Codegen = self;
        while (cur) |cg| {
            if (cg.global_attrs.get(name)) |ro| return ro;
            cur = cg.outer;
        }
        return false;
    }

    fn isGlobalAllowed(self: *Codegen, name: []const u8) bool {
        if (std.mem.eql(u8, name, "_ENV") or std.mem.eql(u8, name, "_G")) return true;
        if (std.mem.eql(u8, name, "assert") or
            std.mem.eql(u8, name, "collectgarbage") or
            std.mem.eql(u8, name, "dofile") or
            std.mem.eql(u8, name, "error") or
            std.mem.eql(u8, name, "getmetatable") or
            std.mem.eql(u8, name, "ipairs") or
            std.mem.eql(u8, name, "load") or
            std.mem.eql(u8, name, "loadfile") or
            std.mem.eql(u8, name, "next") or
            std.mem.eql(u8, name, "pairs") or
            std.mem.eql(u8, name, "pcall") or
            std.mem.eql(u8, name, "print") or
            std.mem.eql(u8, name, "rawequal") or
            std.mem.eql(u8, name, "rawget") or
            std.mem.eql(u8, name, "rawset") or
            std.mem.eql(u8, name, "require") or
            std.mem.eql(u8, name, "select") or
            std.mem.eql(u8, name, "setmetatable") or
            std.mem.eql(u8, name, "tonumber") or
            std.mem.eql(u8, name, "tostring") or
            std.mem.eql(u8, name, "type") or
            std.mem.eql(u8, name, "warn") or
            std.mem.eql(u8, name, "xpcall") or
            std.mem.eql(u8, name, "coroutine") or
            std.mem.eql(u8, name, "debug") or
            std.mem.eql(u8, name, "io") or
            std.mem.eql(u8, name, "math") or
            std.mem.eql(u8, name, "os") or
            std.mem.eql(u8, name, "package") or
            std.mem.eql(u8, name, "string") or
            std.mem.eql(u8, name, "table") or
            std.mem.eql(u8, name, "utf8"))
        {
            return true;
        }
        var cur: ?*Codegen = self;
        var saw_strict = false;
        while (cur) |cg| {
            switch (cg.strict_globals_mode) {
                .wildcard => return true,
                .strict => {
                    saw_strict = true;
                    if (cg.declared_globals.contains(name)) return true;
                },
                .legacy => {},
            }
            cur = cg.outer;
        }
        return !saw_strict;
    }

    fn checkDeclaredGlobal(self: *Codegen, span: ast.Span, name: []const u8) Error!void {
        if (self.isGlobalAllowed(name)) return;
        const msg = std.fmt.allocPrint(self.alloc, "variable '{s}' is not declared", .{name}) catch "variable is not declared";
        self.setDiag(span, msg);
        return error.CodegenError;
    }

    fn newValue(self: *Codegen) ir.ValueId {
        const v = self.next_value;
        self.next_value += 1;
        return v;
    }

    fn newLabel(self: *Codegen) ir.LabelId {
        const id = self.next_label;
        self.next_label += 1;
        return id;
    }

    fn pushScope(self: *Codegen) Error!void {
        try self.scope_marks.append(self.alloc, self.bindings.items.len);
        try self.global_scope_marks.append(self.alloc, .{
            .mode = self.strict_globals_mode,
            .decl_log_len = self.declared_globals_log.items.len,
            .attr_log_len = self.global_attr_log.items.len,
        });
        self.scope_depth += 1;
    }

    fn popScope(self: *Codegen) void {
        const n = self.scope_marks.items.len;
        std.debug.assert(n > 0);
        const mark = self.scope_marks.items[n - 1];
        self.scope_marks.items.len = n - 1;
        self.scope_depth -= 1;

        // `<close>` handlers run in reverse declaration order.
        var i = self.bindings.items.len;
        while (i > mark) {
            i -= 1;
            const b = self.bindings.items[i];
            if (self.isCloseLocal(b.local)) {
                self.emit(.{ .CloseLocal = .{ .local = b.local } }) catch @panic("oom");
            }
        }

        // Clear locals declared in this scope so they don't remain as GC roots
        // after going out of scope (Lua stack top behavior).
        //
        // Important: locals may be "boxed" when captured as upvalues. In that
        // case, we must clear the stack slot without touching the boxed cell,
        // otherwise we'd mutate the upvalue itself.
        for (self.bindings.items[mark..]) |b| {
            self.emit(.{ .ClearLocal = .{ .local = b.local } }) catch @panic("oom");
        }

        self.bindings.items.len = mark;
        self.popGlobalScope();
        self.expireLabels();
    }

    fn clearScopeFromMark(self: *Codegen, mark: usize) Error!void {
        for (self.bindings.items[mark..]) |b| {
            try self.emit(.{ .ClearLocal = .{ .local = b.local } });
        }
    }

    fn popScopeNoClear(self: *Codegen) void {
        const n = self.scope_marks.items.len;
        std.debug.assert(n > 0);
        const mark = self.scope_marks.items[n - 1];
        self.scope_marks.items.len = n - 1;
        self.scope_depth -= 1;
        self.bindings.items.len = mark;
        self.popGlobalScope();
        self.expireLabels();
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
            if (self.declared_globals.getPtr(name)) |cnt| {
                std.debug.assert(cnt.* > 0);
                cnt.* -= 1;
                if (cnt.* == 0) _ = self.declared_globals.remove(name);
            }
        }
        self.declared_globals_log.items.len = mark.decl_log_len;
        var aidx = self.global_attr_log.items.len;
        while (aidx > mark.attr_log_len) {
            aidx -= 1;
            const entry = self.global_attr_log.items[aidx];
            if (entry.had_prev) {
                self.global_attrs.put(self.alloc, entry.name, entry.prev) catch @panic("oom");
            } else {
                _ = self.global_attrs.remove(entry.name);
            }
        }
        self.global_attr_log.items.len = mark.attr_log_len;
        self.strict_globals_mode = mark.mode;
    }

    fn expireLabels(self: *Codegen) void {
        var stale = std.ArrayListUnmanaged([]const u8){};
        defer stale.deinit(self.alloc);
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.defined and entry.value_ptr.defined_depth > self.scope_depth) {
                stale.append(self.alloc, entry.key_ptr.*) catch @panic("oom");
            }
        }
        for (stale.items) |name| {
            _ = self.labels.remove(name);
        }
    }

    fn declareLocal(self: *Codegen, name: []const u8) Error!ir.LocalId {
        const id = self.next_local;
        self.next_local += 1;
        try self.local_names.append(self.alloc, name);
        try self.bindings.append(self.alloc, .{ .name = name, .local = id });
        if (name.len != 0) try self.jump_guards.append(self.alloc, .{ .name = name, .depth = self.scope_depth });
        return id;
    }

    fn markConstLocal(self: *Codegen, local: ir.LocalId) void {
        self.const_locals.put(self.alloc, local, {}) catch @panic("oom");
    }

    fn markCloseLocal(self: *Codegen, local: ir.LocalId) void {
        self.close_locals.put(self.alloc, local, {}) catch @panic("oom");
    }

    fn isConstLocal(self: *Codegen, local: ir.LocalId) bool {
        return self.const_locals.contains(local);
    }

    fn isCloseLocal(self: *Codegen, local: ir.LocalId) bool {
        return self.close_locals.contains(local);
    }

    fn markConstUpvalue(self: *Codegen, up: ir.UpvalueId) void {
        self.const_upvalues.put(self.alloc, up, {}) catch @panic("oom");
    }

    fn isConstUpvalue(self: *Codegen, up: ir.UpvalueId) bool {
        return self.const_upvalues.contains(up);
    }

    fn declIsReadonly(d: ast.DeclName) bool {
        if (d.prefix_attr) |a| {
            if (a.kind == .Const or a.kind == .Close) return true;
        }
        if (d.suffix_attr) |a| {
            if (a.kind == .Const or a.kind == .Close) return true;
        }
        return false;
    }

    fn declIsClose(d: ast.DeclName) bool {
        if (d.prefix_attr) |a| {
            if (a.kind == .Close) return true;
        }
        if (d.suffix_attr) |a| {
            if (a.kind == .Close) return true;
        }
        return false;
    }

    fn allocTempLocal(self: *Codegen) Error!ir.LocalId {
        const id = self.next_local;
        self.next_local += 1;
        try self.local_names.append(self.alloc, "");
        // Keep temp locals inside normal scope cleanup so they do not remain
        // accidental GC roots for the rest of a long-running chunk.
        try self.bindings.append(self.alloc, .{ .name = "", .local = id });
        return id;
    }

    fn lookupLocal(self: *Codegen, name: []const u8) ?ir.LocalId {
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.bindings.items[i].name, name)) return self.bindings.items[i].local;
        }
        return null;
    }

    fn createUpvalue(self: *Codegen, name: []const u8, cap: ir.Capture) Error!ir.UpvalueId {
        const id = self.next_upvalue;
        self.next_upvalue += 1;
        try self.upvalues.put(self.alloc, name, id);
        std.debug.assert(self.captures.items.len == @as(usize, @intCast(id)));
        try self.captures.append(self.alloc, cap);
        return id;
    }

    fn ensureUpvalueFor(self: *Codegen, name: []const u8, span: ast.Span) Error!?ir.UpvalueId {
        if (self.upvalues.get(name)) |id| return id;
        const outer = self.outer orelse return null;

        if (outer.lookupLocal(name)) |local| {
            if (self.next_upvalue >= 255) {
                self.setDiag(span, "too many upvalues");
                return error.CodegenError;
            }
            outer.captured_locals.put(outer.alloc, local, {}) catch @panic("oom");
            const up = try self.createUpvalue(name, .{ .Local = local });
            if (outer.isConstLocal(local)) self.markConstUpvalue(up);
            return up;
        }
        if (outer.upvalues.get(name)) |up| {
            if (self.next_upvalue >= 255) {
                self.setDiag(span, "too many upvalues");
                return error.CodegenError;
            }
            const new_up = try self.createUpvalue(name, .{ .Upvalue = up });
            if (outer.isConstUpvalue(up)) self.markConstUpvalue(new_up);
            return new_up;
        }
        if (try outer.ensureUpvalueFor(name, span)) |up| {
            if (self.next_upvalue >= 255) {
                self.setDiag(span, "too many upvalues");
                return error.CodegenError;
            }
            const new_up = try self.createUpvalue(name, .{ .Upvalue = up });
            if (outer.isConstUpvalue(up)) self.markConstUpvalue(new_up);
            return new_up;
        }
        return null;
    }

    fn setDiagAssignConst(self: *Codegen, span: ast.Span, name: []const u8) void {
        const msg = std.fmt.allocPrint(self.alloc, ":{d}: attempt to assign to const variable '{s}'", .{ span.line, name }) catch "attempt to assign to const variable";
        self.setDiag(span, msg);
    }

    fn pushLoopEnd(self: *Codegen, label: ir.LabelId) Error!void {
        try self.loop_ends.append(self.alloc, label);
    }

    fn popLoopEnd(self: *Codegen) void {
        const n = self.loop_ends.items.len;
        std.debug.assert(n > 0);
        self.loop_ends.items.len = n - 1;
    }

    fn currentLoopEnd(self: *Codegen) ?ir.LabelId {
        const n = self.loop_ends.items.len;
        if (n == 0) return null;
        return self.loop_ends.items[n - 1];
    }

    fn getOrCreateLabel(self: *Codegen, name: []const u8) Error!ir.LabelId {
        const entry = try self.labels.getOrPut(self.alloc, name);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .id = self.newLabel(),
                .defined = false,
                .defined_line = 0,
                .defined_depth = 0,
                .first_goto = null,
                .first_goto_depth = 0,
                .first_goto_guard_len = 0,
            };
        }
        return entry.value_ptr.id;
    }

    fn markLabelDefined(self: *Codegen, span: ast.Span, name: []const u8, has_code_after: bool) Error!ir.LabelId {
        const entry = try self.labels.getOrPut(self.alloc, name);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .id = self.newLabel(),
                .defined = true,
                .defined_line = span.line,
                .defined_depth = self.scope_depth,
                .first_goto = null,
                .first_goto_depth = 0,
                .first_goto_guard_len = 0,
            };
            return entry.value_ptr.id;
        }
        if (entry.value_ptr.defined) {
            const msg = std.fmt.allocPrint(self.alloc, "label '{s}' already defined on line {d}", .{ name, entry.value_ptr.defined_line }) catch "label already defined";
            self.setDiag(span, msg);
            return error.CodegenError;
        }
        if (entry.value_ptr.first_goto != null and entry.value_ptr.first_goto_depth < self.scope_depth) {
            const sp = entry.value_ptr.first_goto.?;
            const msg = std.fmt.allocPrint(self.alloc, "no visible label '{s}' for goto at line {d}", .{ name, sp.line }) catch "no visible label for goto";
            self.setDiag(sp, msg);
            return error.CodegenError;
        }
        if (has_code_after) if (entry.value_ptr.first_goto) |sp| {
            if (entry.value_ptr.first_goto_guard_len < self.jump_guards.items.len) {
                var i = entry.value_ptr.first_goto_guard_len;
                while (i < self.jump_guards.items.len) : (i += 1) {
                    const g = self.jump_guards.items[i];
                    if (g.depth <= self.scope_depth) {
                        const msg = std.fmt.allocPrint(
                            self.alloc,
                            "goto at line {d} jumps into the scope of '{s}'",
                            .{ sp.line, g.name },
                        ) catch "goto jumps into the scope of local";
                        self.setDiag(sp, msg);
                        return error.CodegenError;
                    }
                }
            }
        };
        entry.value_ptr.defined = true;
        entry.value_ptr.defined_line = span.line;
        entry.value_ptr.defined_depth = self.scope_depth;
        entry.value_ptr.first_goto = null;
        entry.value_ptr.first_goto_depth = 0;
        entry.value_ptr.first_goto_guard_len = 0;
        return entry.value_ptr.id;
    }

    fn markGoto(self: *Codegen, span: ast.Span, name: []const u8) Error!ir.LabelId {
        const id = try self.getOrCreateLabel(name);
        if (self.labels.getPtr(name)) |info| {
            if (info.first_goto == null) {
                info.first_goto = span;
                info.first_goto_depth = self.scope_depth;
                info.first_goto_guard_len = self.jump_guards.items.len;
            }
        }
        return id;
    }

    fn checkUndefinedLabels(self: *Codegen) Error!void {
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.defined) {
                if (entry.value_ptr.first_goto) |sp| {
                    const msg = std.fmt.allocPrint(self.alloc, "no visible label '{s}' for goto at line {d}", .{ entry.key_ptr.*, sp.line }) catch "no visible label for goto";
                    self.setDiag(sp, msg);
                } else {
                    const msg = std.fmt.allocPrint(self.alloc, "no visible label '{s}'", .{entry.key_ptr.*}) catch "no visible label for goto";
                    self.setDiag(.{ .start = 0, .end = 0, .line = 1, .col = 1 }, msg);
                }
                return error.CodegenError;
            }
        }
    }

    fn genNameValue(self: *Codegen, span: ast.Span, name: []const u8) Error!ir.ValueId {
        if (self.lookupLocal(name)) |local| {
            const dst = self.newValue();
            try self.emit(.{ .GetLocal = .{ .dst = dst, .local = local } });
            return dst;
        }
        if (try self.ensureUpvalueFor(name, span)) |up| {
            const dst = self.newValue();
            try self.emit(.{ .GetUpvalue = .{ .dst = dst, .upvalue = up } });
            return dst;
        }
        try self.checkDeclaredGlobal(span, name);
        const dst = self.newValue();
        try self.emit(.{ .GetName = .{ .dst = dst, .name = name } });
        return dst;
    }

    fn emitSetNameValue(self: *Codegen, span: ast.Span, name: []const u8, rhs: ir.ValueId) Error!void {
        if (self.lookupLocal(name)) |local| {
            if (self.isConstLocal(local)) {
                self.setDiagAssignConst(span, name);
                return error.CodegenError;
            }
            try self.emit(.{ .SetLocal = .{ .local = local, .src = rhs } });
            return;
        }
        if (try self.ensureUpvalueFor(name, span)) |up| {
            if (self.isConstUpvalue(up)) {
                self.setDiagAssignConst(span, name);
                return error.CodegenError;
            }
            try self.emit(.{ .SetUpvalue = .{ .upvalue = up, .src = rhs } });
            return;
        }
        try self.checkDeclaredGlobal(span, name);
        if (self.isConstGlobal(name)) {
            self.setDiagAssignConst(span, name);
            return error.CodegenError;
        }
        try self.emit(.{ .SetName = .{ .name = name, .src = rhs } });
    }

    fn emit(self: *Codegen, inst: ir.Inst) Error!void {
        try self.insts.append(self.alloc, inst);
        try self.inst_lines.append(self.alloc, self.line_hint);
    }

    fn getNil(self: *Codegen, span: ast.Span) Error!ir.ValueId {
        if (self.nil_cache) |v| return v;
        const dst = self.newValue();
        try self.emit(.{ .ConstNil = .{ .dst = dst } });
        self.nil_cache = dst;
        _ = span;
        return dst;
    }

    fn spanLastLine(self: *Codegen, span: ast.Span) u32 {
        var line = span.line;
        for (self.source[span.start..span.end]) |ch| {
            if (ch == '\n') line += 1;
        }
        return line;
    }

    fn buildLocalNames(self: *Codegen) ![]const []const u8 {
        return try self.local_names.toOwnedSlice(self.alloc);
    }

    fn buildUpvalueNames(self: *Codegen) ![]const []const u8 {
        const n: usize = @intCast(self.next_upvalue);
        var names = try self.alloc.alloc([]const u8, n);
        for (names) |*nm| nm.* = "";
        var it = self.upvalues.iterator();
        while (it.next()) |entry| {
            const idx: usize = @intCast(entry.value_ptr.*);
            if (idx < names.len) names[idx] = entry.key_ptr.*;
        }
        return names;
    }

    fn appendActiveLine(self: *Codegen, lines: *std.ArrayListUnmanaged(u32), line: u32) Error!void {
        for (lines.items) |v| {
            if (v == line) return;
        }
        try lines.append(self.alloc, line);
    }

    fn collectActiveLinesStat(self: *Codegen, st: *const ast.Stat, lines: *std.ArrayListUnmanaged(u32)) Error!void {
        switch (st.node) {
            .LocalFuncDecl => |n| {
                const body_last = self.spanLastLine(n.body.span);
                const pre_bind_line = if (body_last > 0) body_last - 1 else st.span.line;
                try self.appendActiveLine(lines, pre_bind_line);
                try self.appendActiveLine(lines, body_last);
            },
            else => try self.appendActiveLine(lines, st.span.line),
        }
        switch (st.node) {
            .If => |n| {
                try self.collectActiveLinesBlock(n.then_block, lines);
                for (n.elseifs) |eif| try self.collectActiveLinesBlock(eif.block, lines);
                if (n.else_block) |b| try self.collectActiveLinesBlock(b, lines);
            },
            .While => |n| try self.collectActiveLinesBlock(n.block, lines),
            .Do => |n| try self.collectActiveLinesBlock(n.block, lines),
            .Repeat => |n| try self.collectActiveLinesBlock(n.block, lines),
            .ForNumeric => |n| try self.collectActiveLinesBlock(n.block, lines),
            .ForGeneric => |n| try self.collectActiveLinesBlock(n.block, lines),
            else => {},
        }
    }

    fn collectActiveLinesBlock(self: *Codegen, block: *const ast.Block, lines: *std.ArrayListUnmanaged(u32)) Error!void {
        for (block.stats) |st| try self.collectActiveLinesStat(&st, lines);
    }

    fn buildActiveLines(self: *Codegen, block: *const ast.Block, last_line: u32) Error![]const u32 {
        var lines = std.ArrayListUnmanaged(u32){};
        try self.collectActiveLinesBlock(block, &lines);
        if (last_line != 0) try self.appendActiveLine(&lines, last_line);
        std.sort.heap(u32, lines.items, {}, std.sort.asc(u32));
        return try lines.toOwnedSlice(self.alloc);
    }

    fn buildCloseLocals(self: *Codegen) Error![]const ir.LocalId {
        var out = std.ArrayListUnmanaged(ir.LocalId){};
        var it = self.close_locals.iterator();
        while (it.next()) |entry| {
            try out.append(self.alloc, entry.key_ptr.*);
        }
        std.sort.heap(ir.LocalId, out.items, {}, std.sort.asc(ir.LocalId));
        return try out.toOwnedSlice(self.alloc);
    }

    pub fn compileChunk(self: *Codegen, chunk: *const ast.Chunk) Error!*ir.Function {
        defer self.declared_globals.deinit(self.alloc);
        defer self.declared_globals_log.deinit(self.alloc);
        defer self.global_attrs.deinit(self.alloc);
        defer self.global_attr_log.deinit(self.alloc);
        defer self.global_scope_marks.deinit(self.alloc);
        defer self.jump_guards.deinit(self.alloc);
        self.is_vararg = self.chunk_is_vararg;
        try self.genBlock(chunk.block);
        try self.checkUndefinedLabels();

        // Ensure an explicit return for the IR dump.
        if (self.insts.items.len == 0) {
            const empty = &[_]ir.ValueId{};
            try self.emit(.{ .Return = .{ .values = empty[0..] } });
        } else {
            const last = self.insts.items[self.insts.items.len - 1];
            const has_return = switch (last) {
                .Return, .ReturnExpand, .ReturnCall, .ReturnCallVararg, .ReturnCallExpand, .ReturnVararg, .ReturnVarargExpand => true,
                else => false,
            };
            if (!has_return) {
                const empty = &[_]ir.ValueId{};
                try self.emit(.{ .Return = .{ .values = empty[0..] } });
            }
        }

        const insts = try self.insts.toOwnedSlice(self.alloc);
        const inst_lines = try self.inst_lines.toOwnedSlice(self.alloc);
        const caps = try self.captures.toOwnedSlice(self.alloc);
        const local_names = try self.buildLocalNames();
        const close_locals = try self.buildCloseLocals();
        const upvalue_names = try self.buildUpvalueNames();
        const active_lines = try self.buildActiveLines(chunk.block, self.spanLastLine(chunk.span));
        const f = try self.alloc.create(ir.Function);
        f.* = .{
            .name = "main",
            .source_name = self.source_name,
            .line_defined = 0,
            .last_line_defined = self.spanLastLine(chunk.span),
            .insts = insts,
            .inst_lines = inst_lines,
            .num_values = self.next_value,
            .num_locals = self.next_local,
            .local_names = local_names,
            .close_locals = close_locals,
            .active_lines = active_lines,
            .is_vararg = self.chunk_is_vararg,
            .num_upvalues = self.next_upvalue,
            .upvalue_names = upvalue_names,
            .captures = caps,
        };
        return f;
    }

    fn compileFuncBody(self: *Codegen, func_name: []const u8, body: *const ast.FuncBody, extra_param: ?[]const u8) Error!*ir.Function {
        if (extra_param) |pname| _ = try self.declareLocal(pname);
        for (body.params) |p| _ = try self.declareLocal(p.slice(self.source));
        if (body.vararg) |v| {
            self.is_vararg = true;
            if (v.name) |name| {
                const local = try self.declareLocal(name.slice(self.source));
                const dst = self.newValue();
                try self.emit(.{ .VarargTable = .{ .dst = dst } });
                try self.emit(.{ .SetLocal = .{ .local = local, .src = dst } });
            }
        }
        try self.genBlock(body.body);
        try self.checkUndefinedLabels();

        // Ensure an explicit return.
        if (self.insts.items.len == 0) {
            const empty = &[_]ir.ValueId{};
            try self.emit(.{ .Return = .{ .values = empty[0..] } });
        } else {
            const last = self.insts.items[self.insts.items.len - 1];
            const has_return = switch (last) {
                .Return, .ReturnExpand, .ReturnCall, .ReturnCallVararg, .ReturnCallExpand, .ReturnVararg, .ReturnVarargExpand => true,
                else => false,
            };
            if (!has_return) {
                const empty = &[_]ir.ValueId{};
                try self.emit(.{ .Return = .{ .values = empty[0..] } });
            }
        }

        const insts = try self.insts.toOwnedSlice(self.alloc);
        const inst_lines = try self.inst_lines.toOwnedSlice(self.alloc);
        const caps = try self.captures.toOwnedSlice(self.alloc);
        const local_names = try self.buildLocalNames();
        const close_locals = try self.buildCloseLocals();
        const upvalue_names = try self.buildUpvalueNames();
        const active_lines = try self.buildActiveLines(body.body, self.spanLastLine(body.span));
        const f = try self.alloc.create(ir.Function);
        f.* = .{
            .name = func_name,
            .source_name = self.source_name,
            .line_defined = body.span.line,
            .last_line_defined = self.spanLastLine(body.span),
            .insts = insts,
            .inst_lines = inst_lines,
            .num_values = self.next_value,
            .num_locals = self.next_local,
            .local_names = local_names,
            .close_locals = close_locals,
            .active_lines = active_lines,
            .is_vararg = body.vararg != null,
            .num_params = @intCast(body.params.len + @intFromBool(extra_param != null)),
            .num_upvalues = self.next_upvalue,
            .upvalue_names = upvalue_names,
            .captures = caps,
        };
        return f;
    }

    fn compileChildFunction(self: *Codegen, func_name: []const u8, body: *const ast.FuncBody, extra_param: ?[]const u8) Error!*ir.Function {
        var cg = Codegen.init(self.alloc, self.source_name, self.source);
        cg.outer = self;
        return cg.compileFuncBody(func_name, body, extra_param) catch |e| {
            if (e == error.CodegenError) self.diag = cg.diag;
            return e;
        };
    }

    fn genBlock(self: *Codegen, block: *const ast.Block) Error!void {
        try self.pushScope();
        defer self.popScope();
        try self.genBlockNoScope(block, false);
    }

    fn genBlockNoScope(self: *Codegen, block: *const ast.Block, has_postlude: bool) Error!void {
        for (block.stats, 0..) |st, idx| {
            self.label_has_code_after = true;
            if (st.node == .Label) {
                var has_code_after = false;
                var j = idx + 1;
                while (j < block.stats.len) : (j += 1) {
                    switch (block.stats[j].node) {
                        .Label => {},
                        else => {
                            has_code_after = true;
                            break;
                        },
                    }
                }
                self.label_has_code_after = has_code_after or has_postlude;
            }
            const stop = try self.genStat(&st);
            if (stop) break;
        }
    }

    fn genStat(self: *Codegen, st: *const ast.Stat) Error!bool {
        const old_line_hint = self.line_hint;
        self.line_hint = st.span.line;
        defer self.line_hint = old_line_hint;
        switch (st.node) {
            .If => |n| {
                const end_label = self.newLabel();
                const next_label = self.newLabel();

                const cond = try self.genExp(n.cond);
                try self.emit(.{ .JumpIfFalse = .{ .cond = cond, .target = next_label } });
                try self.genBlock(n.then_block);
                try self.emit(.{ .Jump = .{ .target = end_label } });

                try self.emit(.{ .Label = .{ .id = next_label } });

                for (n.elseifs) |eif| {
                    const this_end = self.newLabel();
                    const econd = try self.genExp(eif.cond);
                    try self.emit(.{ .JumpIfFalse = .{ .cond = econd, .target = this_end } });
                    try self.genBlock(eif.block);
                    try self.emit(.{ .Jump = .{ .target = end_label } });
                    try self.emit(.{ .Label = .{ .id = this_end } });
                }

                if (n.else_block) |b| {
                    try self.genBlock(b);
                }
                try self.emit(.{ .Label = .{ .id = end_label } });
                return false;
            },
            .While => |n| {
                const start_label = self.newLabel();
                const end_label = self.newLabel();
                try self.pushLoopEnd(end_label);
                defer self.popLoopEnd();

                try self.emit(.{ .Label = .{ .id = start_label } });
                const cond = try self.genExp(n.cond);
                try self.emit(.{ .JumpIfFalse = .{ .cond = cond, .target = end_label } });
                try self.genBlock(n.block);
                try self.emit(.{ .Jump = .{ .target = start_label } });
                try self.emit(.{ .Label = .{ .id = end_label } });
                return false;
            },
            .ForNumeric => |n| {
                const start_label = self.newLabel();
                const pos_label = self.newLabel();
                const body_label = self.newLabel();
                const end_label = self.newLabel();
                try self.pushLoopEnd(end_label);
                defer self.popLoopEnd();

                try self.pushScope();
                defer self.popScope();

                const init_v = try self.genExp(n.init);
                const limit_v = try self.genExp(n.limit);
                const step_v = if (n.step) |s| try self.genExp(s) else blk: {
                    const one = self.newValue();
                    try self.emit(.{ .ConstInt = .{ .dst = one, .lexeme = "1" } });
                    break :blk one;
                };

                const limit_local = try self.declareLocal("limit");
                const step_local = try self.declareLocal("step");
                try self.emit(.{ .SetLocal = .{ .local = limit_local, .src = limit_v } });
                try self.emit(.{ .SetLocal = .{ .local = step_local, .src = step_v } });

                const zero = self.newValue();
                try self.emit(.{ .ConstInt = .{ .dst = zero, .lexeme = "0" } });
                const step_cmp = self.newValue();
                try self.emit(.{ .GetLocal = .{ .dst = step_cmp, .local = step_local } });
                const step_neg = self.newValue();
                try self.emit(.{ .BinOp = .{ .dst = step_neg, .op = .Lt, .lhs = step_cmp, .rhs = zero } });

                const loop_counter = try self.declareLocal("initial value");
                try self.emit(.{ .SetLocal = .{ .local = loop_counter, .src = init_v } });

                try self.emit(.{ .Label = .{ .id = start_label } });
                try self.emit(.{ .JumpIfFalse = .{ .cond = step_neg, .target = pos_label } });

                // negative step: i >= limit
                const cur_neg = self.newValue();
                try self.emit(.{ .GetLocal = .{ .dst = cur_neg, .local = loop_counter } });
                const limit_neg = self.newValue();
                try self.emit(.{ .GetLocal = .{ .dst = limit_neg, .local = limit_local } });
                const cmp_neg = self.newValue();
                try self.emit(.{ .BinOp = .{ .dst = cmp_neg, .op = .Gte, .lhs = cur_neg, .rhs = limit_neg } });
                try self.emit(.{ .JumpIfFalse = .{ .cond = cmp_neg, .target = end_label } });
                try self.emit(.{ .Jump = .{ .target = body_label } });

                // positive step: i <= limit
                try self.emit(.{ .Label = .{ .id = pos_label } });
                const cur_pos = self.newValue();
                try self.emit(.{ .GetLocal = .{ .dst = cur_pos, .local = loop_counter } });
                const limit_pos = self.newValue();
                try self.emit(.{ .GetLocal = .{ .dst = limit_pos, .local = limit_local } });
                const cmp_pos = self.newValue();
                try self.emit(.{ .BinOp = .{ .dst = cmp_pos, .op = .Lte, .lhs = cur_pos, .rhs = limit_pos } });
                try self.emit(.{ .JumpIfFalse = .{ .cond = cmp_pos, .target = end_label } });

                try self.emit(.{ .Label = .{ .id = body_label } });
                // Lua's numeric-for control variable is a fresh local each
                // iteration for closures.
                try self.pushScope();
                const iter_local = try self.declareLocal(n.name.slice(self.source));
                const cur_body = self.newValue();
                try self.emit(.{ .GetLocal = .{ .dst = cur_body, .local = loop_counter } });
                try self.emit(.{ .SetLocal = .{ .local = iter_local, .src = cur_body } });
                try self.genBlock(n.block);
                self.popScope();

                const cur_inc = self.newValue();
                try self.emit(.{ .GetLocal = .{ .dst = cur_inc, .local = loop_counter } });
                const step_inc = self.newValue();
                try self.emit(.{ .GetLocal = .{ .dst = step_inc, .local = step_local } });
                const next = self.newValue();
                try self.emit(.{ .BinOp = .{ .dst = next, .op = .Plus, .lhs = cur_inc, .rhs = step_inc } });
                try self.emit(.{ .SetLocal = .{ .local = loop_counter, .src = next } });
                try self.emit(.{ .Jump = .{ .target = start_label } });

                try self.emit(.{ .Label = .{ .id = end_label } });
                return false;
            },
            .ForGeneric => |n| {
                // Keep iterator/state/control temporaries in this loop scope so
                // they are cleared on exit and do not remain GC roots.
                try self.pushScope();
                defer self.popScope();

                const iter_local = try self.allocTempLocal();
                const state_local = try self.allocTempLocal();
                const ctrl_local = try self.allocTempLocal();
                const close_local = try self.allocTempLocal();
                self.markCloseLocal(close_local);

                var init_vals: [4]ir.ValueId = undefined;
                try self.genForExplist(n.exps, &init_vals);
                try self.emit(.{ .SetLocal = .{ .local = iter_local, .src = init_vals[0] } });
                try self.emit(.{ .SetLocal = .{ .local = state_local, .src = init_vals[1] } });
                try self.emit(.{ .SetLocal = .{ .local = ctrl_local, .src = init_vals[2] } });
                try self.emit(.{ .SetLocal = .{ .local = close_local, .src = init_vals[3] } });

                const start_label = self.newLabel();
                const end_label = self.newLabel();
                try self.pushLoopEnd(end_label);
                defer self.popLoopEnd();

                const locals = try self.alloc.alloc(ir.LocalId, n.names.len);
                for (n.names, 0..) |nm, i| locals[i] = try self.declareLocal(nm.slice(self.source));

                try self.emit(.{ .Label = .{ .id = start_label } });

                const iter_v = self.newValue();
                const state_v = self.newValue();
                const ctrl_v = self.newValue();
                try self.emit(.{ .GetLocal = .{ .dst = iter_v, .local = iter_local } });
                try self.emit(.{ .GetLocal = .{ .dst = state_v, .local = state_local } });
                try self.emit(.{ .GetLocal = .{ .dst = ctrl_v, .local = ctrl_local } });

                const dsts = try self.alloc.alloc(ir.ValueId, n.names.len);
                for (dsts) |*d| d.* = self.newValue();
                const args = try self.alloc.alloc(ir.ValueId, 2);
                args[0] = state_v;
                args[1] = ctrl_v;
                const old_line_hint_for_call = self.line_hint;
                if (n.exps.len > 0) self.line_hint = n.exps[0].span.line;
                try self.emit(.{ .Call = .{ .dsts = dsts[0..], .func = iter_v, .args = args } });
                self.line_hint = old_line_hint_for_call;

                if (dsts.len > 0) {
                    try self.emit(.{ .JumpIfFalse = .{ .cond = dsts[0], .target = end_label } });
                    try self.emit(.{ .SetLocal = .{ .local = ctrl_local, .src = dsts[0] } });
                } else {
                    const nilv = try self.getNil(n.names[0].span);
                    try self.emit(.{ .JumpIfFalse = .{ .cond = nilv, .target = end_label } });
                }

                for (locals, 0..) |local, i| {
                    const value = if (i < dsts.len) dsts[i] else try self.getNil(n.names[i].span);
                    try self.emit(.{ .SetLocal = .{ .local = local, .src = value } });
                }

                try self.genBlock(n.block);
                try self.emit(.{ .Jump = .{ .target = start_label } });
                try self.emit(.{ .Label = .{ .id = end_label } });
                return false;
            },
            .Do => |n| {
                try self.genBlock(n.block);
                return false;
            },
            .Repeat => |n| {
                const start_label = self.newLabel();
                const continue_label = self.newLabel();
                const break_label = self.newLabel();
                const end_label = self.newLabel();
                try self.pushLoopEnd(break_label);
                defer self.popLoopEnd();

                // In Lua, locals declared inside the repeat block are visible
                // in the `until` condition.
                try self.pushScope();
                const repeat_mark = self.scope_marks.items[self.scope_marks.items.len - 1];
                defer self.popScopeNoClear();

                try self.emit(.{ .Label = .{ .id = start_label } });
                try self.genBlockNoScope(n.block, true);
                const cond = try self.genExp(n.cond);
                try self.emit(.{ .JumpIfFalse = .{ .cond = cond, .target = continue_label } });
                try self.emit(.{ .Jump = .{ .target = break_label } });
                try self.emit(.{ .Label = .{ .id = continue_label } });
                try self.clearScopeFromMark(repeat_mark);
                try self.emit(.{ .Jump = .{ .target = start_label } });
                try self.emit(.{ .Label = .{ .id = break_label } });
                try self.clearScopeFromMark(repeat_mark);
                try self.emit(.{ .Jump = .{ .target = end_label } });
                try self.emit(.{ .Label = .{ .id = end_label } });
                return false;
            },
            .Return => |n| {
                if (n.values.len > 254) {
                    self.setDiag(n.values[254].span, "too many returns");
                    return error.CodegenError;
                }
                if (n.values.len > 0) {
                    const last = n.values[n.values.len - 1];
                    switch (last.node) {
                        .Call, .MethodCall => {
                            if (n.values.len == 1) {
                                try self.genReturnCall(last);
                                return true;
                            }
                            var values_list = std.ArrayListUnmanaged(ir.ValueId){};
                            for (n.values[0 .. n.values.len - 1]) |e| {
                                const v = try self.genExp(e);
                                try values_list.append(self.alloc, v);
                            }
                            const values = try values_list.toOwnedSlice(self.alloc);
                            const tail = try self.genCallSpec(last);
                            try self.emit(.{ .ReturnExpand = .{ .values = values, .tail = tail } });
                            return true;
                        },
                        else => {},
                    }
                }
                if (n.values.len == 1) {
                    const only = n.values[0];
                    switch (only.node) {
                        .Call, .MethodCall => {
                            try self.genReturnCall(only);
                            return true;
                        },
                        .Dots => {
                            if (!self.is_vararg) {
                                self.setDiag(only.span, "IR codegen: vararg used in non-vararg function");
                                return error.CodegenError;
                            }
                            try self.emit(.ReturnVararg);
                            return true;
                        },
                        else => {},
                    }
                }
                if (n.values.len > 0) {
                    const last = n.values[n.values.len - 1];
                    if (last.node == .Dots) {
                        if (!self.is_vararg) {
                            self.setDiag(last.span, "IR codegen: vararg used in non-vararg function");
                            return error.CodegenError;
                        }
                        var values_list = std.ArrayListUnmanaged(ir.ValueId){};
                        for (n.values[0 .. n.values.len - 1]) |e| {
                            const v = try self.genExp(e);
                            try values_list.append(self.alloc, v);
                        }
                        const values = try values_list.toOwnedSlice(self.alloc);
                        try self.emit(.{ .ReturnVarargExpand = .{ .values = values } });
                        return true;
                    }
                }
                var values_list = std.ArrayListUnmanaged(ir.ValueId){};
                for (n.values) |e| {
                    const v = try self.genExp(e);
                    try values_list.append(self.alloc, v);
                }
                const values = try values_list.toOwnedSlice(self.alloc);
                try self.emit(.{ .Return = .{ .values = values } });
                return true;
            },
            .Assign => |n| {
                // Lua assignment evaluates all lvalues (table/index receivers and keys)
                // before performing any store.
                const pre_obj = try self.alloc.alloc(?ir.ValueId, n.lhs.len);
                const pre_key = try self.alloc.alloc(?ir.ValueId, n.lhs.len);
                for (pre_obj) |*p| p.* = null;
                for (pre_key) |*p| p.* = null;
                for (n.lhs, 0..) |lhs, i| {
                    switch (lhs.node) {
                        .Name => |nm| {
                            const name = nm.slice(self.source);
                            if (self.lookupLocal(name) == null) {
                                _ = try self.ensureUpvalueFor(name, nm.span);
                            }
                        },
                        .Field => |f| {
                            pre_obj[i] = try self.genExp(f.object);
                        },
                        .Index => |ix| {
                            pre_obj[i] = try self.genExp(ix.object);
                            pre_key[i] = try self.genExp(ix.index);
                        },
                        else => {},
                    }
                }

                if (n.rhs.len > 0) {
                    const last = n.rhs[n.rhs.len - 1];
                    switch (last.node) {
                        .Call, .MethodCall => {
                            const fixed_count = if (n.rhs.len > 0) n.rhs.len - 1 else 0;
                            const fixed = try self.alloc.alloc(ir.ValueId, fixed_count);
                            for (fixed, 0..) |*dst, i| dst.* = try self.genExp(n.rhs[i]);

                            const remaining = if (n.lhs.len > fixed_count) n.lhs.len - fixed_count else 0;
                            const dsts = try self.alloc.alloc(ir.ValueId, remaining);
                            for (dsts) |*d| d.* = self.newValue();
                            try self.genCall(last, dsts);

                            for (n.lhs, 0..) |lhs, idx| {
                                if (idx < fixed_count) {
                                    const value = fixed[idx];
                                    switch (lhs.node) {
                                        .Name => |nm| try self.emitSetNameValue(nm.span, nm.slice(self.source), value),
                                        .Field => |f| try self.emit(.{ .SetField = .{ .object = pre_obj[idx].?, .name = f.name.slice(self.source), .value = value } }),
                                        .Index => try self.emit(.{ .SetIndex = .{ .object = pre_obj[idx].?, .key = pre_key[idx].?, .value = value } }),
                                        else => {
                                            self.setDiag(lhs.span, "IR codegen: unsupported lvalue");
                                            return error.CodegenError;
                                        },
                                    }
                                } else {
                                    const j = idx - fixed_count;
                                    const value = if (j < dsts.len) dsts[j] else try self.getNil(lhs.span);
                                    switch (lhs.node) {
                                        .Name => |nm| try self.emitSetNameValue(nm.span, nm.slice(self.source), value),
                                        .Field => |f| try self.emit(.{ .SetField = .{ .object = pre_obj[idx].?, .name = f.name.slice(self.source), .value = value } }),
                                        .Index => try self.emit(.{ .SetIndex = .{ .object = pre_obj[idx].?, .key = pre_key[idx].?, .value = value } }),
                                        else => {
                                            self.setDiag(lhs.span, "IR codegen: unsupported lvalue");
                                            return error.CodegenError;
                                        },
                                    }
                                }
                            }
                            return false;
                        },
                        else => {},
                    }
                }
                const rhs = try self.genExplist(n.rhs);
                for (n.lhs, 0..) |lhs, i| {
                    const value = if (i < rhs.len) rhs[i] else try self.getNil(lhs.span);
                    switch (lhs.node) {
                        .Name => |nm| try self.emitSetNameValue(nm.span, nm.slice(self.source), value),
                        .Field => |f| try self.emit(.{ .SetField = .{ .object = pre_obj[i].?, .name = f.name.slice(self.source), .value = value } }),
                        .Index => try self.emit(.{ .SetIndex = .{ .object = pre_obj[i].?, .key = pre_key[i].?, .value = value } }),
                        else => {
                            self.setDiag(lhs.span, "IR codegen: unsupported lvalue");
                            return error.CodegenError;
                        },
                    }
                }
                return false;
            },
            .Call => |n| {
                try self.genCallNoResults(n.call);
                return false;
            },
            .LocalDecl => |n| {
                const empty = &[_]ir.ValueId{};
                // Evaluate initializers before declaring locals, so `local x = x + 1`
                // sees the outer binding (Lua semantics).
                if (n.values) |vs| {
                    if (n.names.len == 1 and vs.len == 1) {
                        switch (vs[0].node) {
                            .FuncDef => |body| {
                                const fn_ir = try self.compileChildFunction("<anon>", body, null);
                                const fn_last = self.spanLastLine(vs[0].span);
                                const old_hint = self.line_hint;
                                self.line_hint = if (fn_last > 0) fn_last - 1 else st.span.line;
                                const fnv = self.newValue();
                                try self.emit(.{ .ConstFunc = .{ .dst = fnv, .func = fn_ir } });
                                const local = try self.declareLocal(n.names[0].name.slice(self.source));
                                if (declIsReadonly(n.names[0])) self.markConstLocal(local);
                                if (declIsClose(n.names[0])) self.markCloseLocal(local);
                                self.line_hint = fn_last;
                                try self.emit(.{ .SetLocal = .{ .local = local, .src = fnv } });
                                self.line_hint = old_hint;
                                return false;
                            },
                            else => {},
                        }
                    }
                    if (vs.len > 0) {
                        const last = vs[vs.len - 1];
                        switch (last.node) {
                            .Call, .MethodCall => {
                                const fixed_count = if (vs.len > 0) vs.len - 1 else 0;
                                const fixed = try self.alloc.alloc(ir.ValueId, fixed_count);
                                for (fixed, 0..) |*dst, i| dst.* = try self.genExp(vs[i]);

                                const remaining = if (n.names.len > fixed_count) n.names.len - fixed_count else 0;
                                const dsts = try self.alloc.alloc(ir.ValueId, remaining);
                                for (dsts) |*d| d.* = self.newValue();
                                try self.genCall(last, dsts);

                                const locals = try self.alloc.alloc(ir.LocalId, n.names.len);
                                for (n.names, 0..) |d, i| {
                                    locals[i] = try self.declareLocal(d.name.slice(self.source));
                                    if (declIsReadonly(d)) self.markConstLocal(locals[i]);
                                    if (declIsClose(d)) self.markCloseLocal(locals[i]);
                                }
                                for (locals, 0..) |local, idx| {
                                    if (idx < fixed_count) {
                                        try self.emit(.{ .SetLocal = .{ .local = local, .src = fixed[idx] } });
                                    } else {
                                        const j = idx - fixed_count;
                                        const value = if (j < dsts.len) dsts[j] else try self.getNil(n.names[idx].name.span);
                                        try self.emit(.{ .SetLocal = .{ .local = local, .src = value } });
                                    }
                                }
                                return false;
                            },
                            .Dots => {
                                if (!self.is_vararg) {
                                    self.setDiag(last.span, "IR codegen: vararg used in non-vararg function");
                                    return error.CodegenError;
                                }
                                const dsts = try self.alloc.alloc(ir.ValueId, n.names.len);
                                for (dsts) |*d| d.* = self.newValue();
                                try self.emit(.{ .Vararg = .{ .dsts = dsts } });

                                const locals = try self.alloc.alloc(ir.LocalId, n.names.len);
                                for (n.names, 0..) |d, i| {
                                    locals[i] = try self.declareLocal(d.name.slice(self.source));
                                    if (declIsReadonly(d)) self.markConstLocal(locals[i]);
                                    if (declIsClose(d)) self.markCloseLocal(locals[i]);
                                }
                                for (locals, 0..) |local, idx| {
                                    try self.emit(.{ .SetLocal = .{ .local = local, .src = dsts[idx] } });
                                }
                                return false;
                            },
                            else => {},
                        }
                    }

                    const rhs = try self.genExplist(vs);
                    const locals = try self.alloc.alloc(ir.LocalId, n.names.len);
                    for (n.names, 0..) |d, i| {
                        locals[i] = try self.declareLocal(d.name.slice(self.source));
                        if (declIsReadonly(d)) self.markConstLocal(locals[i]);
                        if (declIsClose(d)) self.markCloseLocal(locals[i]);
                    }
                    for (n.names, 0..) |d, i| {
                        const value = if (i < rhs.len) rhs[i] else try self.getNil(d.name.span);
                        try self.emit(.{ .SetLocal = .{ .local = locals[i], .src = value } });
                    }
                    return false;
                }

                const locals = try self.alloc.alloc(ir.LocalId, n.names.len);
                for (n.names, 0..) |d, i| {
                    locals[i] = try self.declareLocal(d.name.slice(self.source));
                    if (declIsReadonly(d)) self.markConstLocal(locals[i]);
                    if (declIsClose(d)) self.markCloseLocal(locals[i]);
                }
                for (n.names, 0..) |d, i| {
                    const value = if (i < empty.len) empty[i] else try self.getNil(d.name.span);
                    try self.emit(.{ .SetLocal = .{ .local = locals[i], .src = value } });
                }
                return false;
            },
            .Break => {
                const end_label = self.currentLoopEnd() orelse {
                    self.setDiag(st.span, "IR codegen: 'break' outside loop");
                    return error.CodegenError;
                };
                try self.emit(.{ .Jump = .{ .target = end_label } });
                return false;
            },
            .Goto => |n| {
                const target = try self.markGoto(st.span, n.label.slice(self.source));
                try self.emit(.{ .Jump = .{ .target = target } });
                return false;
            },
            .Label => |n| {
                const id = try self.markLabelDefined(st.span, n.label.slice(self.source), self.label_has_code_after);
                try self.emit(.{ .Label = .{ .id = id } });
                return false;
            },
            .GlobalDecl => |n| {
                if (n.star) {
                    try self.jump_guards.append(self.alloc, .{ .name = "*", .depth = self.scope_depth });
                    self.declareGlobalWildcard();
                    return false;
                }
                const prefix_ro = if (n.prefix_attr) |a|
                    (a.kind == .Const or a.kind == .Close)
                else
                    false;
                for (n.names) |d| {
                    const name = d.name.slice(self.source);
                    try self.jump_guards.append(self.alloc, .{ .name = name, .depth = self.scope_depth });
                    try self.declareGlobalName(name);
                    try self.declareGlobalAttr(name, prefix_ro or declIsReadonly(d));
                }
                // In Lua 5.5, `global x, y` is a declaration; it must not mutate
                // existing values (the upstream test suite relies on this for
                // prelude variables like `_port=true`).
                if (n.values == null) return false;

                const rhs = try self.genExplist(n.values.?);
                for (n.names, 0..) |d, i| {
                    const value = if (i < rhs.len) rhs[i] else try self.getNil(d.name.span);
                    try self.emit(.{ .SetName = .{ .name = d.name.slice(self.source), .src = value } });
                }
                return false;
            },
            .FuncDecl => |n| {
                const fname = n.name.span.slice(self.source);
                const method_name = if (n.name.method) |m| m.slice(self.source) else null;
                const extra_param: ?[]const u8 = if (method_name != null) "self" else null;

                if (n.name.fields.len == 0 and method_name == null) {
                    const name = n.name.base.slice(self.source);
                    const fn_ir = try self.compileChildFunction(fname, n.body, extra_param);
                    const dst = self.newValue();
                    try self.emit(.{ .ConstFunc = .{ .dst = dst, .func = fn_ir } });
                    try self.emitSetNameValue(n.name.base.span, name, dst);
                    return false;
                }

                // Build target object expression.
                var obj = try self.genNameValue(n.name.base.span, n.name.base.slice(self.source));
                const nfields = n.name.fields.len;
                var object_fields: usize = nfields;
                var field_name: []const u8 = undefined;
                if (method_name) |mname| {
                    field_name = mname;
                } else {
                    field_name = n.name.fields[nfields - 1].slice(self.source);
                    object_fields = nfields - 1;
                }

                var i: usize = 0;
                while (i < object_fields) : (i += 1) {
                    const dst = self.newValue();
                    try self.emit(.{ .GetField = .{ .dst = dst, .object = obj, .name = n.name.fields[i].slice(self.source) } });
                    obj = dst;
                }

                const fn_ir = try self.compileChildFunction(fname, n.body, extra_param);
                const dst = self.newValue();
                try self.emit(.{ .ConstFunc = .{ .dst = dst, .func = fn_ir } });
                try self.emit(.{ .SetField = .{ .object = obj, .name = field_name, .value = dst } });
                return false;
            },
            .GlobalFuncDecl => |n| {
                const name = n.name.slice(self.source);
                try self.declareGlobalName(name);
                try self.declareGlobalAttr(name, false);
                const fn_ir = try self.compileChildFunction(name, n.body, null);
                const dst = self.newValue();
                try self.emit(.{ .ConstFunc = .{ .dst = dst, .func = fn_ir } });
                try self.emitSetNameValue(n.name.span, name, dst);
                return false;
            },
            .LocalFuncDecl => |n| {
                const name = n.name.slice(self.source);
                const local = try self.declareLocal(name);
                const fn_ir = try self.compileChildFunction(name, n.body, null);
                const body_last = self.spanLastLine(n.body.span);
                const old_hint = self.line_hint;
                self.line_hint = if (body_last > 0) body_last - 1 else st.span.line;
                const dst = self.newValue();
                try self.emit(.{ .ConstFunc = .{ .dst = dst, .func = fn_ir } });
                self.line_hint = body_last;
                try self.emit(.{ .SetLocal = .{ .local = local, .src = dst } });
                self.line_hint = old_hint;
                return false;
            },
        }
    }

    fn genExplist(self: *Codegen, exps: []const *ast.Exp) Error![]const ir.ValueId {
        var out = std.ArrayListUnmanaged(ir.ValueId){};
        for (exps) |e| {
            const v = try self.genExp(e);
            try out.append(self.alloc, v);
        }
        return try out.toOwnedSlice(self.alloc);
    }

    fn genSet(self: *Codegen, lhs: *const ast.Exp, rhs: ir.ValueId) Error!void {
        switch (lhs.node) {
            .Name => |n| {
                try self.emitSetNameValue(n.span, n.slice(self.source), rhs);
            },
            .Field => |n| {
                const obj = try self.genExp(n.object);
                try self.emit(.{ .SetField = .{ .object = obj, .name = n.name.slice(self.source), .value = rhs } });
            },
            .Index => |n| {
                const obj = try self.genExp(n.object);
                const key = try self.genExp(n.index);
                try self.emit(.{ .SetIndex = .{ .object = obj, .key = key, .value = rhs } });
            },
            else => {
                self.setDiag(lhs.span, "IR codegen: unsupported lvalue");
                return error.CodegenError;
            },
        }
    }

    fn genCallNoResults(self: *Codegen, call_exp: *const ast.Exp) Error!void {
        const dsts = &[_]ir.ValueId{};
        return self.genCall(call_exp, dsts[0..]);
    }

    fn lineOfOffset(self: *Codegen, off: usize) u32 {
        var line: u32 = 1;
        var i: usize = 0;
        const lim = @min(off, self.source.len);
        while (i < lim) : (i += 1) {
            if (self.source[i] == '\n') line += 1;
        }
        return line;
    }

    fn inferCallLine(self: *Codegen, search_start: usize, call_span: ast.Span) u32 {
        var i = search_start;
        const end = @min(call_span.end, self.source.len);
        while (i < end) : (i += 1) {
            if (self.source[i] == '(') return self.lineOfOffset(i);
        }
        return call_span.line;
    }

    fn genCall(self: *Codegen, call_exp: *const ast.Exp, dsts: []const ir.ValueId) Error!void {
        switch (call_exp.node) {
            .Call => |n| {
                const call_line = self.inferCallLine(n.func.span.end, call_exp.span);
                if (n.args.len > 0) {
                    const last = n.args[n.args.len - 1];
                    switch (last.node) {
                        .Call, .MethodCall => {
                            const args = try self.genExplist(n.args[0 .. n.args.len - 1]);
                            const tail = try self.genCallSpec(last);
                            const old_line_hint = self.line_hint;
                            self.line_hint = call_line;
                            try self.emit(.{
                                .CallExpand = .{
                                    .dsts = dsts[0..],
                                    .func = try self.genExp(n.func),
                                    .args = args,
                                    .tail = tail,
                                },
                            });
                            self.line_hint = old_line_hint;
                            return;
                        },
                        else => {},
                    }
                }

                const func = try self.genExp(n.func);
                const args_info = try self.genArgs(n.args);
                const old_line_hint = self.line_hint;
                self.line_hint = call_line;
                if (args_info.has_vararg_tail) {
                    try self.emit(.{ .CallVararg = .{ .dsts = dsts[0..], .func = func, .args = args_info.args } });
                } else {
                    try self.emit(.{ .Call = .{ .dsts = dsts[0..], .func = func, .args = args_info.args } });
                }
                self.line_hint = old_line_hint;
            },
            .MethodCall => |n| {
                const call_line = self.inferCallLine(n.receiver.span.end, call_exp.span);
                const recv = try self.genExp(n.receiver);
                const method = self.newValue();
                try self.emit(.{ .GetField = .{ .dst = method, .object = recv, .name = n.method.slice(self.source) } });

                if (n.args.len > 0) {
                    const last = n.args[n.args.len - 1];
                    switch (last.node) {
                        .Call, .MethodCall => {
                            const fixed = try self.alloc.alloc(ir.ValueId, n.args.len);
                            fixed[0] = recv;
                            for (n.args[0 .. n.args.len - 1], 0..) |e, i| {
                                fixed[1 + i] = try self.genExp(e);
                            }
                            const tail = try self.genCallSpec(last);
                            const old_line_hint = self.line_hint;
                            self.line_hint = call_line;
                            try self.emit(.{
                                .CallExpand = .{
                                    .dsts = dsts[0..],
                                    .func = method,
                                    .args = fixed,
                                    .tail = tail,
                                },
                            });
                            self.line_hint = old_line_hint;
                            return;
                        },
                        else => {},
                    }
                }

                const args_info = try self.genMethodArgs(recv, n.args);
                const old_line_hint = self.line_hint;
                self.line_hint = call_line;
                if (args_info.has_vararg_tail) {
                    try self.emit(.{ .CallVararg = .{ .dsts = dsts[0..], .func = method, .args = args_info.args } });
                } else {
                    try self.emit(.{ .Call = .{ .dsts = dsts[0..], .func = method, .args = args_info.args } });
                }
                self.line_hint = old_line_hint;
            },
            else => {
                self.setDiag(call_exp.span, "IR codegen: expected call expression");
                return error.CodegenError;
            },
        }
    }

    fn genReturnCall(self: *Codegen, call_exp: *const ast.Exp) Error!void {
        switch (call_exp.node) {
            .Call => |n| {
                const call_line = self.inferCallLine(n.func.span.end, call_exp.span);
                if (n.args.len > 0) {
                    const last = n.args[n.args.len - 1];
                    switch (last.node) {
                        .Call, .MethodCall => {
                            const args = try self.genExplist(n.args[0 .. n.args.len - 1]);
                            const tail = try self.genCallSpec(last);
                            const old_line_hint = self.line_hint;
                            self.line_hint = call_line;
                            try self.emit(.{
                                .ReturnCallExpand = .{
                                    .func = try self.genExp(n.func),
                                    .args = args,
                                    .tail = tail,
                                },
                            });
                            self.line_hint = old_line_hint;
                            return;
                        },
                        else => {},
                    }
                }

                const func = try self.genExp(n.func);
                const args_info = try self.genArgs(n.args);
                const old_line_hint = self.line_hint;
                self.line_hint = call_line;
                if (args_info.has_vararg_tail) {
                    try self.emit(.{ .ReturnCallVararg = .{ .func = func, .args = args_info.args } });
                } else {
                    try self.emit(.{ .ReturnCall = .{ .func = func, .args = args_info.args } });
                }
                self.line_hint = old_line_hint;
            },
            .MethodCall => |n| {
                const call_line = self.inferCallLine(n.receiver.span.end, call_exp.span);
                const recv = try self.genExp(n.receiver);
                const method = self.newValue();
                try self.emit(.{ .GetField = .{ .dst = method, .object = recv, .name = n.method.slice(self.source) } });
                if (n.args.len > 0) {
                    const last = n.args[n.args.len - 1];
                    switch (last.node) {
                        .Call, .MethodCall => {
                            const fixed = try self.alloc.alloc(ir.ValueId, n.args.len);
                            fixed[0] = recv;
                            for (n.args[0 .. n.args.len - 1], 0..) |e, i| {
                                fixed[1 + i] = try self.genExp(e);
                            }
                            const tail = try self.genCallSpec(last);
                            const old_line_hint = self.line_hint;
                            self.line_hint = call_line;
                            try self.emit(.{
                                .ReturnCallExpand = .{
                                    .func = method,
                                    .args = fixed,
                                    .tail = tail,
                                },
                            });
                            self.line_hint = old_line_hint;
                            return;
                        },
                        else => {},
                    }
                }

                const args_info = try self.genMethodArgs(recv, n.args);
                const old_line_hint = self.line_hint;
                self.line_hint = call_line;
                if (args_info.has_vararg_tail) {
                    try self.emit(.{ .ReturnCallVararg = .{ .func = method, .args = args_info.args } });
                } else {
                    try self.emit(.{ .ReturnCall = .{ .func = method, .args = args_info.args } });
                }
                self.line_hint = old_line_hint;
            },
            else => {
                self.setDiag(call_exp.span, "IR codegen: expected call expression");
                return error.CodegenError;
            },
        }
    }

    fn genCallSpec(self: *Codegen, call_exp: *const ast.Exp) Error!*const ir.CallSpec {
        switch (call_exp.node) {
            .Call => |n| {
                if (n.args.len > 0) {
                    const last = n.args[n.args.len - 1];
                    switch (last.node) {
                        .Call, .MethodCall => {
                            const args = try self.genExplist(n.args[0 .. n.args.len - 1]);
                            const tail = try self.genCallSpec(last);
                            const spec = try self.alloc.create(ir.CallSpec);
                            spec.* = .{ .func = try self.genExp(n.func), .args = args, .use_vararg = false, .tail = tail };
                            return spec;
                        },
                        else => {},
                    }
                }

                const func = try self.genExp(n.func);
                const args_info = try self.genArgs(n.args);
                const spec = try self.alloc.create(ir.CallSpec);
                spec.* = .{ .func = func, .args = args_info.args, .use_vararg = args_info.has_vararg_tail, .tail = null };
                return spec;
            },
            .MethodCall => |n| {
                const recv = try self.genExp(n.receiver);
                const method = self.newValue();
                try self.emit(.{ .GetField = .{ .dst = method, .object = recv, .name = n.method.slice(self.source) } });

                if (n.args.len > 0) {
                    const last = n.args[n.args.len - 1];
                    switch (last.node) {
                        .Call, .MethodCall => {
                            const fixed = try self.alloc.alloc(ir.ValueId, n.args.len);
                            fixed[0] = recv;
                            for (n.args[0 .. n.args.len - 1], 0..) |e, i| {
                                fixed[1 + i] = try self.genExp(e);
                            }
                            const tail = try self.genCallSpec(last);
                            const spec = try self.alloc.create(ir.CallSpec);
                            spec.* = .{ .func = method, .args = fixed, .use_vararg = false, .tail = tail };
                            return spec;
                        },
                        else => {},
                    }
                }

                const args_info = try self.genMethodArgs(recv, n.args);
                const spec = try self.alloc.create(ir.CallSpec);
                spec.* = .{ .func = method, .args = args_info.args, .use_vararg = args_info.has_vararg_tail, .tail = null };
                return spec;
            },
            else => {
                self.setDiag(call_exp.span, "IR codegen: expected call expression");
                return error.CodegenError;
            },
        }
    }

    const ArgsInfo = struct {
        args: []const ir.ValueId,
        has_vararg_tail: bool,
    };

    fn genArgs(self: *Codegen, args: []const *ast.Exp) Error!ArgsInfo {
        if (args.len == 0) return .{ .args = &.{}, .has_vararg_tail = false };
        const last = args[args.len - 1];
        const has_vararg_tail = last.node == .Dots;
        const nvals = if (has_vararg_tail) args.len - 1 else args.len;
        if (nvals > 250) {
            self.setDiag(last.span, "too many registers");
            return error.CodegenError;
        }
        const out = try self.alloc.alloc(ir.ValueId, nvals);
        for (out, 0..) |*dst, i| dst.* = try self.genExp(args[i]);
        if (has_vararg_tail and !self.is_vararg) {
            self.setDiag(last.span, "IR codegen: vararg used in non-vararg function");
            return error.CodegenError;
        }
        return .{ .args = out, .has_vararg_tail = has_vararg_tail };
    }

    fn genMethodArgs(self: *Codegen, recv: ir.ValueId, args: []const *ast.Exp) Error!ArgsInfo {
        if (args.len == 0) {
            const out = try self.alloc.alloc(ir.ValueId, 1);
            out[0] = recv;
            return .{ .args = out, .has_vararg_tail = false };
        }
        const last = args[args.len - 1];
        const has_vararg_tail = last.node == .Dots;
        const nvals = (if (has_vararg_tail) args.len - 1 else args.len) + 1;
        if (nvals > 250) {
            self.setDiag(last.span, "too many registers");
            return error.CodegenError;
        }
        const out = try self.alloc.alloc(ir.ValueId, nvals);
        out[0] = recv;
        var i: usize = 0;
        while (i + 1 < nvals) : (i += 1) {
            out[1 + i] = try self.genExp(args[i]);
        }
        if (has_vararg_tail and !self.is_vararg) {
            self.setDiag(last.span, "IR codegen: vararg used in non-vararg function");
            return error.CodegenError;
        }
        return .{ .args = out, .has_vararg_tail = has_vararg_tail };
    }

    fn genExp(self: *Codegen, e: *const ast.Exp) Error!ir.ValueId {
        switch (e.node) {
            .Nil => {
                const dst = self.newValue();
                try self.emit(.{ .ConstNil = .{ .dst = dst } });
                return dst;
            },
            .True => {
                const dst = self.newValue();
                try self.emit(.{ .ConstBool = .{ .dst = dst, .val = true } });
                return dst;
            },
            .False => {
                const dst = self.newValue();
                try self.emit(.{ .ConstBool = .{ .dst = dst, .val = false } });
                return dst;
            },
            .Integer => {
                const dst = self.newValue();
                try self.emit(.{ .ConstInt = .{ .dst = dst, .lexeme = e.span.slice(self.source) } });
                return dst;
            },
            .Number => {
                const dst = self.newValue();
                try self.emit(.{ .ConstNum = .{ .dst = dst, .lexeme = e.span.slice(self.source) } });
                return dst;
            },
            .String => {
                const dst = self.newValue();
                try self.emit(.{ .ConstString = .{ .dst = dst, .lexeme = e.span.slice(self.source) } });
                return dst;
            },
            .Dots => {
                if (!self.is_vararg) {
                    self.setDiag(e.span, "IR codegen: vararg used in non-vararg function");
                    return error.CodegenError;
                }
                const dst = self.newValue();
                const dsts = try self.alloc.alloc(ir.ValueId, 1);
                dsts[0] = dst;
                try self.emit(.{ .Vararg = .{ .dsts = dsts } });
                return dst;
            },
            .Name => |n| {
                return try self.genNameValue(n.span, n.slice(self.source));
            },
            .Paren => |inner| return try self.genExp(inner),
            .UnOp => |n| {
                const src = try self.genExp(n.exp);
                const dst = self.newValue();
                const old_hint = self.line_hint;
                if (n.op_line != 0) self.line_hint = n.op_line;
                try self.emit(.{ .UnOp = .{ .dst = dst, .op = n.op, .src = src } });
                self.line_hint = old_hint;
                return dst;
            },
            .BinOp => |n| {
                if (n.op == .And) return try self.genAndExp(n.lhs, n.rhs);
                if (n.op == .Or) return try self.genOrExp(n.lhs, n.rhs);
                const lhs = try self.genExp(n.lhs);
                const rhs = try self.genExp(n.rhs);
                const dst = self.newValue();
                const old_hint = self.line_hint;
                if (n.op_line != 0) self.line_hint = n.op_line;
                try self.emit(.{ .BinOp = .{ .dst = dst, .op = n.op, .lhs = lhs, .rhs = rhs } });
                self.line_hint = old_hint;
                return dst;
            },
            .Table => |n| {
                const dst = self.newValue();
                // `{...}` should include all varargs, not only the first one.
                if (n.fields.len == 1) {
                    switch (n.fields[0].node) {
                        .Array => |val_e| switch (val_e.node) {
                            .Dots => {
                                if (!self.is_vararg) {
                                    self.setDiag(val_e.span, "IR codegen: vararg used in non-vararg function");
                                    return error.CodegenError;
                                }
                                try self.emit(.{ .VarargTable = .{ .dst = dst } });
                                return dst;
                            },
                            else => {},
                        },
                        else => {},
                    }
                }
                try self.emit(.{ .NewTable = .{ .dst = dst } });
                for (n.fields, 0..) |f, fi| {
                    switch (f.node) {
                        .Array => |val_e| {
                            const is_last = fi + 1 == n.fields.len;
                            if (is_last) {
                                switch (val_e.node) {
                                    .Call, .MethodCall => {
                                        const tail = try self.genCallSpec(val_e);
                                        try self.emit(.{ .AppendCallExpand = .{ .object = dst, .tail = tail } });
                                        continue;
                                    },
                                    else => {},
                                }
                            }
                            const val = try self.genExp(val_e);
                            try self.emit(.{ .Append = .{ .object = dst, .value = val } });
                        },
                        .Name => |nv| {
                            const val = try self.genExp(nv.value);
                            try self.emit(.{ .SetField = .{ .object = dst, .name = nv.name.slice(self.source), .value = val } });
                        },
                        .Index => |kv| {
                            const key = try self.genExp(kv.key);
                            const val = try self.genExp(kv.value);
                            try self.emit(.{ .SetIndex = .{ .object = dst, .key = key, .value = val } });
                        },
                    }
                }
                return dst;
            },
            .FuncDef => |body| {
                const fn_ir = try self.compileChildFunction("<anon>", body, null);
                const dst = self.newValue();
                try self.emit(.{ .ConstFunc = .{ .dst = dst, .func = fn_ir } });
                return dst;
            },
            .Field => |n| {
                const obj = try self.genExp(n.object);
                const dst = self.newValue();
                try self.emit(.{ .GetField = .{ .dst = dst, .object = obj, .name = n.name.slice(self.source) } });
                return dst;
            },
            .Index => |n| {
                const obj = try self.genExp(n.object);
                const key = try self.genExp(n.index);
                const dst = self.newValue();
                try self.emit(.{ .GetIndex = .{ .dst = dst, .object = obj, .key = key } });
                return dst;
            },
            .Call => |_| {
                const dst = self.newValue();
                const dsts = try self.alloc.alloc(ir.ValueId, 1);
                dsts[0] = dst;
                try self.genCall(e, dsts);
                return dst;
            },
            .MethodCall => |_| {
                const dst = self.newValue();
                const dsts = try self.alloc.alloc(ir.ValueId, 1);
                dsts[0] = dst;
                try self.genCall(e, dsts);
                return dst;
            },
        }
    }

    fn genAndExp(self: *Codegen, lhs_exp: *const ast.Exp, rhs_exp: *const ast.Exp) Error!ir.ValueId {
        const tmp = try self.allocTempLocal();
        const end_label = self.newLabel();

        const lhs = try self.genExp(lhs_exp);
        try self.emit(.{ .SetLocal = .{ .local = tmp, .src = lhs } });
        try self.emit(.{ .JumpIfFalse = .{ .cond = lhs, .target = end_label } });

        const rhs = try self.genExp(rhs_exp);
        try self.emit(.{ .SetLocal = .{ .local = tmp, .src = rhs } });

        try self.emit(.{ .Label = .{ .id = end_label } });
        const dst = self.newValue();
        try self.emit(.{ .GetLocal = .{ .dst = dst, .local = tmp } });
        return dst;
    }

    fn genOrExp(self: *Codegen, lhs_exp: *const ast.Exp, rhs_exp: *const ast.Exp) Error!ir.ValueId {
        const tmp = try self.allocTempLocal();
        const rhs_label = self.newLabel();
        const end_label = self.newLabel();

        const lhs = try self.genExp(lhs_exp);
        try self.emit(.{ .SetLocal = .{ .local = tmp, .src = lhs } });
        try self.emit(.{ .JumpIfFalse = .{ .cond = lhs, .target = rhs_label } });
        try self.emit(.{ .Jump = .{ .target = end_label } });

        try self.emit(.{ .Label = .{ .id = rhs_label } });
        const rhs = try self.genExp(rhs_exp);
        try self.emit(.{ .SetLocal = .{ .local = tmp, .src = rhs } });

        try self.emit(.{ .Label = .{ .id = end_label } });
        const dst = self.newValue();
        try self.emit(.{ .GetLocal = .{ .dst = dst, .local = tmp } });
        return dst;
    }

    fn genForExplist(self: *Codegen, exps: []const *ast.Exp, out: *[4]ir.ValueId) Error!void {
        const nilv = try self.getNil(if (exps.len > 0) exps[0].span else ast.Span{ .start = 0, .end = 0, .line = 0, .col = 0 });
        out.* = .{ nilv, nilv, nilv, nilv };
        if (exps.len == 0) return;

        if (exps.len == 1) {
            const only = exps[0];
            switch (only.node) {
                .Call, .MethodCall => {
                    const dsts = try self.alloc.alloc(ir.ValueId, 4);
                    for (dsts) |*d| d.* = self.newValue();
                    try self.genCall(only, dsts);
                    out[0] = dsts[0];
                    out[1] = dsts[1];
                    out[2] = dsts[2];
                    out[3] = dsts[3];
                    return;
                },
                .Dots => {
                    if (!self.is_vararg) {
                        self.setDiag(only.span, "IR codegen: vararg used in non-vararg function");
                        return error.CodegenError;
                    }
                    const dsts = try self.alloc.alloc(ir.ValueId, 4);
                    for (dsts) |*d| d.* = self.newValue();
                    try self.emit(.{ .Vararg = .{ .dsts = dsts } });
                    out[0] = dsts[0];
                    out[1] = dsts[1];
                    out[2] = dsts[2];
                    out[3] = dsts[3];
                    return;
                },
                else => {
                    out[0] = try self.genExp(only);
                    return;
                },
            }
        }

        const last = exps[exps.len - 1];
        const fixed_count = if (exps.len - 1 < 4) exps.len - 1 else 4;
        var i: usize = 0;
        while (i < fixed_count) : (i += 1) {
            out[i] = try self.genExp(exps[i]);
        }
        while (i < exps.len - 1) : (i += 1) {
            _ = try self.genExp(exps[i]);
        }

        if (fixed_count >= 4) {
            _ = try self.genExp(last);
            return;
        }

        const remaining = 4 - fixed_count;
        switch (last.node) {
            .Call, .MethodCall => {
                const dsts = try self.alloc.alloc(ir.ValueId, remaining);
                for (dsts) |*d| d.* = self.newValue();
                try self.genCall(last, dsts);
                for (dsts, 0..) |d, j| out[fixed_count + j] = d;
            },
            .Dots => {
                if (!self.is_vararg) {
                    self.setDiag(last.span, "IR codegen: vararg used in non-vararg function");
                    return error.CodegenError;
                }
                const dsts = try self.alloc.alloc(ir.ValueId, remaining);
                for (dsts) |*d| d.* = self.newValue();
                try self.emit(.{ .Vararg = .{ .dsts = dsts } });
                for (dsts, 0..) |d, j| out[fixed_count + j] = d;
            },
            else => {
                out[fixed_count] = try self.genExp(last);
            },
        }
    }
};

test "codegen: IR dump snapshot (basic)" {
    const testing = std.testing;
    const Source = @import("source.zig").Source;
    const Lexer = @import("lexer.zig").Lexer;
    const Parser = @import("parser.zig").Parser;

    const src = Source{
        .name = "<test>",
        .bytes = "x = {a = 1, [2] = 3, 4}\n" ++
            "print(x.a, x[2])\n",
    };

    var lex = Lexer.init(src);
    var p = try Parser.init(&lex);

    var ast_arena = ast.AstArena.init(testing.allocator);
    defer ast_arena.deinit();

    const chunk = try p.parseChunkAst(&ast_arena);

    var ir_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer ir_arena.deinit();

    var cg = Codegen.init(ir_arena.allocator(), src.name, src.bytes);
    const main_fn = try cg.compileChunk(chunk);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try ir.dumpFunction(buf.writer(testing.allocator), main_fn);

    try testing.expectEqualStrings(
        \\Function "main"
        \\  0: v0 = newtable
        \\  1: v1 = const_int "1"
        \\  2: setfield v0 "a" <- v1
        \\  3: v2 = const_int "2"
        \\  4: v3 = const_int "3"
        \\  5: setindex v0 [v2] <- v3
        \\  6: v4 = const_int "4"
        \\  7: append v0 <- v4
        \\  8: setname "x" <- v0
        \\  9: v5 = getname "print"
        \\  10: v6 = getname "x"
        \\  11: v7 = getfield v6 "a"
        \\  12: v8 = getname "x"
        \\  13: v9 = const_int "2"
        \\  14: v10 = getindex v8 [v9]
        \\  15: call [] <- v5 args=[v7, v10]
        \\  16: return []
        \\
    , buf.items);
}
