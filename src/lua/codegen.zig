const std = @import("std");

const Diag = @import("diag.zig").Diag;
const ast = @import("ast.zig");
const ir = @import("ir.zig");

pub const Codegen = struct {
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
    bindings: std.ArrayListUnmanaged(Binding) = .{},
    outer: ?*Codegen = null,
    upvalues: std.StringHashMapUnmanaged(ir.UpvalueId) = .{},
    captures: std.ArrayListUnmanaged(ir.Capture) = .{},
    captured_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .{},
    scope_marks: std.ArrayListUnmanaged(usize) = .{},
    loop_ends: std.ArrayListUnmanaged(ir.LabelId) = .{},
    is_vararg: bool = false,

    const Binding = struct {
        name: []const u8,
        local: ir.LocalId,
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
    }

    fn popScope(self: *Codegen) void {
        const n = self.scope_marks.items.len;
        std.debug.assert(n > 0);
        const mark = self.scope_marks.items[n - 1];
        self.scope_marks.items.len = n - 1;

        // Clear locals declared in this scope so they don't remain as GC roots
        // after going out of scope (Lua stack top behavior).
        //
        // Important: locals may be "boxed" when captured as upvalues. In that
        // case, we must clear the stack slot without touching the boxed cell,
        // otherwise we'd mutate the upvalue itself.
        for (self.bindings.items[mark..]) |b| {
            self.insts.append(self.alloc, .{ .ClearLocal = .{ .local = b.local } }) catch @panic("oom");
        }

        self.bindings.items.len = mark;
    }

    fn declareLocal(self: *Codegen, name: []const u8) Error!ir.LocalId {
        const id = self.next_local;
        self.next_local += 1;
        try self.bindings.append(self.alloc, .{ .name = name, .local = id });
        return id;
    }

    fn allocTempLocal(self: *Codegen) Error!ir.LocalId {
        const id = self.next_local;
        self.next_local += 1;
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

    fn ensureUpvalueFor(self: *Codegen, name: []const u8) Error!?ir.UpvalueId {
        if (self.upvalues.get(name)) |id| return id;
        const outer = self.outer orelse return null;

        if (outer.lookupLocal(name)) |local| {
            outer.captured_locals.put(outer.alloc, local, {}) catch @panic("oom");
            return try self.createUpvalue(name, .{ .Local = local });
        }
        if (outer.upvalues.get(name)) |up| {
            return try self.createUpvalue(name, .{ .Upvalue = up });
        }
        if (try outer.ensureUpvalueFor(name)) |up| {
            return try self.createUpvalue(name, .{ .Upvalue = up });
        }
        return null;
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

    fn genNameValue(self: *Codegen, span: ast.Span, name: []const u8) Error!ir.ValueId {
        if (self.lookupLocal(name)) |local| {
            const dst = self.newValue();
            try self.emit(.{ .GetLocal = .{ .dst = dst, .local = local } });
            return dst;
        }
        if (try self.ensureUpvalueFor(name)) |up| {
            const dst = self.newValue();
            try self.emit(.{ .GetUpvalue = .{ .dst = dst, .upvalue = up } });
            return dst;
        }
        const dst = self.newValue();
        try self.emit(.{ .GetName = .{ .dst = dst, .name = name } });
        _ = span;
        return dst;
    }

    fn emitSetNameValue(self: *Codegen, span: ast.Span, name: []const u8, rhs: ir.ValueId) Error!void {
        if (self.lookupLocal(name)) |local| {
            try self.emit(.{ .SetLocal = .{ .local = local, .src = rhs } });
            return;
        }
        if (try self.ensureUpvalueFor(name)) |up| {
            try self.emit(.{ .SetUpvalue = .{ .upvalue = up, .src = rhs } });
            return;
        }
        try self.emit(.{ .SetName = .{ .name = name, .src = rhs } });
        _ = span;
    }

    fn emit(self: *Codegen, inst: ir.Inst) Error!void {
        try self.insts.append(self.alloc, inst);
    }

    fn getNil(self: *Codegen, span: ast.Span) Error!ir.ValueId {
        if (self.nil_cache) |v| return v;
        const dst = self.newValue();
        try self.emit(.{ .ConstNil = .{ .dst = dst } });
        self.nil_cache = dst;
        _ = span;
        return dst;
    }

    pub fn compileChunk(self: *Codegen, chunk: *const ast.Chunk) Error!*ir.Function {
        try self.genBlock(chunk.block);

        // Ensure an explicit return for the IR dump.
        if (self.insts.items.len == 0) {
            const empty = &[_]ir.ValueId{};
            try self.emit(.{ .Return = .{ .values = empty[0..] } });
        } else {
            const last = self.insts.items[self.insts.items.len - 1];
            const has_return = switch (last) {
                .Return, .ReturnExpand, .ReturnCall, .ReturnCallVararg, .ReturnCallExpand, .ReturnVararg => true,
                else => false,
            };
            if (!has_return) {
                const empty = &[_]ir.ValueId{};
                try self.emit(.{ .Return = .{ .values = empty[0..] } });
            }
        }

        const insts = try self.insts.toOwnedSlice(self.alloc);
        const caps = try self.captures.toOwnedSlice(self.alloc);
        const f = try self.alloc.create(ir.Function);
        f.* = .{
            .name = "main",
            .insts = insts,
            .num_values = self.next_value,
            .num_locals = self.next_local,
            .num_upvalues = self.next_upvalue,
            .captures = caps,
        };
        return f;
    }

    fn compileFuncBody(self: *Codegen, func_name: []const u8, body: *const ast.FuncBody, extra_param: ?[]const u8) Error!*ir.Function {
        if (body.vararg) |v| {
            self.is_vararg = true;
            if (v.name) |name| {
                const local = try self.declareLocal(name.slice(self.source));
                const dst = self.newValue();
                try self.emit(.{ .VarargTable = .{ .dst = dst } });
                try self.emit(.{ .SetLocal = .{ .local = local, .src = dst } });
            }
        }

        if (extra_param) |pname| _ = try self.declareLocal(pname);
        for (body.params) |p| _ = try self.declareLocal(p.slice(self.source));
        try self.genBlock(body.body);

        // Ensure an explicit return.
        if (self.insts.items.len == 0) {
            const empty = &[_]ir.ValueId{};
            try self.emit(.{ .Return = .{ .values = empty[0..] } });
        } else {
            const last = self.insts.items[self.insts.items.len - 1];
            const has_return = switch (last) {
                .Return, .ReturnExpand, .ReturnCall, .ReturnCallVararg, .ReturnCallExpand, .ReturnVararg => true,
                else => false,
            };
            if (!has_return) {
                const empty = &[_]ir.ValueId{};
                try self.emit(.{ .Return = .{ .values = empty[0..] } });
            }
        }

        const insts = try self.insts.toOwnedSlice(self.alloc);
        const caps = try self.captures.toOwnedSlice(self.alloc);
        const f = try self.alloc.create(ir.Function);
        f.* = .{
            .name = func_name,
            .insts = insts,
            .num_values = self.next_value,
            .num_locals = self.next_local,
            .num_params = @intCast(body.params.len + @intFromBool(extra_param != null)),
            .num_upvalues = self.next_upvalue,
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
        try self.genBlockNoScope(block);
    }

    fn genBlockNoScope(self: *Codegen, block: *const ast.Block) Error!void {
        for (block.stats) |st| {
            const stop = try self.genStat(&st);
            if (stop) break;
        }
    }

    fn genStat(self: *Codegen, st: *const ast.Stat) Error!bool {
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

                const zero = self.newValue();
                try self.emit(.{ .ConstInt = .{ .dst = zero, .lexeme = "0" } });
                const step_neg = self.newValue();
                try self.emit(.{ .BinOp = .{ .dst = step_neg, .op = .Lt, .lhs = step_v, .rhs = zero } });

                const loop_var = try self.declareLocal(n.name.slice(self.source));
                try self.emit(.{ .SetLocal = .{ .local = loop_var, .src = init_v } });

                try self.emit(.{ .Label = .{ .id = start_label } });
                try self.emit(.{ .JumpIfFalse = .{ .cond = step_neg, .target = pos_label } });

                // negative step: i >= limit
                const cur_neg = self.newValue();
                try self.emit(.{ .GetLocal = .{ .dst = cur_neg, .local = loop_var } });
                const cmp_neg = self.newValue();
                try self.emit(.{ .BinOp = .{ .dst = cmp_neg, .op = .Gte, .lhs = cur_neg, .rhs = limit_v } });
                try self.emit(.{ .JumpIfFalse = .{ .cond = cmp_neg, .target = end_label } });
                try self.emit(.{ .Jump = .{ .target = body_label } });

                // positive step: i <= limit
                try self.emit(.{ .Label = .{ .id = pos_label } });
                const cur_pos = self.newValue();
                try self.emit(.{ .GetLocal = .{ .dst = cur_pos, .local = loop_var } });
                const cmp_pos = self.newValue();
                try self.emit(.{ .BinOp = .{ .dst = cmp_pos, .op = .Lte, .lhs = cur_pos, .rhs = limit_v } });
                try self.emit(.{ .JumpIfFalse = .{ .cond = cmp_pos, .target = end_label } });

                try self.emit(.{ .Label = .{ .id = body_label } });
                try self.genBlock(n.block);

                const cur_inc = self.newValue();
                try self.emit(.{ .GetLocal = .{ .dst = cur_inc, .local = loop_var } });
                const next = self.newValue();
                try self.emit(.{ .BinOp = .{ .dst = next, .op = .Plus, .lhs = cur_inc, .rhs = step_v } });
                try self.emit(.{ .SetLocal = .{ .local = loop_var, .src = next } });
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

                var init_vals: [3]ir.ValueId = undefined;
                try self.genForExplist(n.exps, &init_vals);
                try self.emit(.{ .SetLocal = .{ .local = iter_local, .src = init_vals[0] } });
                try self.emit(.{ .SetLocal = .{ .local = state_local, .src = init_vals[1] } });
                try self.emit(.{ .SetLocal = .{ .local = ctrl_local, .src = init_vals[2] } });

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
                try self.emit(.{ .Call = .{ .dsts = dsts[0..], .func = iter_v, .args = args } });

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
                const end_label = self.newLabel();
                try self.pushLoopEnd(end_label);
                defer self.popLoopEnd();

                // In Lua, locals declared inside the repeat block are visible
                // in the `until` condition.
                try self.pushScope();
                defer self.popScope();

                try self.emit(.{ .Label = .{ .id = start_label } });
                try self.genBlockNoScope(n.block);
                const cond = try self.genExp(n.cond);
                try self.emit(.{ .JumpIfFalse = .{ .cond = cond, .target = start_label } });
                try self.emit(.{ .Label = .{ .id = end_label } });
                return false;
            },
            .Return => |n| {
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
                                    try self.genSet(lhs, fixed[idx]);
                                } else {
                                    const j = idx - fixed_count;
                                    const value = if (j < dsts.len) dsts[j] else try self.getNil(lhs.span);
                                    try self.genSet(lhs, value);
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
                    try self.genSet(lhs, value);
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
                                for (n.names, 0..) |d, i| locals[i] = try self.declareLocal(d.name.slice(self.source));
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
                                for (n.names, 0..) |d, i| locals[i] = try self.declareLocal(d.name.slice(self.source));
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
                    for (n.names, 0..) |d, i| locals[i] = try self.declareLocal(d.name.slice(self.source));
                    for (n.names, 0..) |d, i| {
                        const value = if (i < rhs.len) rhs[i] else try self.getNil(d.name.span);
                        try self.emit(.{ .SetLocal = .{ .local = locals[i], .src = value } });
                    }
                    return false;
                }

                const locals = try self.alloc.alloc(ir.LocalId, n.names.len);
                for (n.names, 0..) |d, i| locals[i] = try self.declareLocal(d.name.slice(self.source));
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
            .GlobalDecl => |n| {
                if (n.star) return false;
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
                const fn_ir = try self.compileChildFunction(name, n.body, null);
                const dst = self.newValue();
                try self.emit(.{ .ConstFunc = .{ .dst = dst, .func = fn_ir } });
                try self.emit(.{ .SetName = .{ .name = name, .src = dst } });
                return false;
            },
            .LocalFuncDecl => |n| {
                const name = n.name.slice(self.source);
                const local = try self.declareLocal(name);
                const fn_ir = try self.compileChildFunction(name, n.body, null);
                const dst = self.newValue();
                try self.emit(.{ .ConstFunc = .{ .dst = dst, .func = fn_ir } });
                try self.emit(.{ .SetLocal = .{ .local = local, .src = dst } });
                return false;
            },
            else => {
                self.setDiag(st.span, "IR codegen: unsupported statement");
                return error.CodegenError;
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

    fn genCall(self: *Codegen, call_exp: *const ast.Exp, dsts: []const ir.ValueId) Error!void {
        switch (call_exp.node) {
            .Call => |n| {
                if (n.args.len > 0) {
                    const last = n.args[n.args.len - 1];
                    switch (last.node) {
                        .Call, .MethodCall => {
                            const args = try self.genExplist(n.args[0 .. n.args.len - 1]);
                            const tail = try self.genCallSpec(last);
                            try self.emit(.{
                                .CallExpand = .{
                                    .dsts = dsts[0..],
                                    .func = try self.genExp(n.func),
                                    .args = args,
                                    .tail = tail,
                                },
                            });
                            return;
                        },
                        else => {},
                    }
                }

                const func = try self.genExp(n.func);
                const args_info = try self.genArgs(n.args);
                if (args_info.has_vararg_tail) {
                    try self.emit(.{ .CallVararg = .{ .dsts = dsts[0..], .func = func, .args = args_info.args } });
                } else {
                    try self.emit(.{ .Call = .{ .dsts = dsts[0..], .func = func, .args = args_info.args } });
                }
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
                            try self.emit(.{
                                .CallExpand = .{
                                    .dsts = dsts[0..],
                                    .func = method,
                                    .args = fixed,
                                    .tail = tail,
                                },
                            });
                            return;
                        },
                        else => {},
                    }
                }

                const args_info = try self.genMethodArgs(recv, n.args);
                if (args_info.has_vararg_tail) {
                    try self.emit(.{ .CallVararg = .{ .dsts = dsts[0..], .func = method, .args = args_info.args } });
                } else {
                    try self.emit(.{ .Call = .{ .dsts = dsts[0..], .func = method, .args = args_info.args } });
                }
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
                if (n.args.len > 0) {
                    const last = n.args[n.args.len - 1];
                    switch (last.node) {
                        .Call, .MethodCall => {
                            const args = try self.genExplist(n.args[0 .. n.args.len - 1]);
                            const tail = try self.genCallSpec(last);
                            try self.emit(.{
                                .ReturnCallExpand = .{
                                    .func = try self.genExp(n.func),
                                    .args = args,
                                    .tail = tail,
                                },
                            });
                            return;
                        },
                        else => {},
                    }
                }

                const func = try self.genExp(n.func);
                const args_info = try self.genArgs(n.args);
                if (args_info.has_vararg_tail) {
                    try self.emit(.{ .ReturnCallVararg = .{ .func = func, .args = args_info.args } });
                } else {
                    try self.emit(.{ .ReturnCall = .{ .func = func, .args = args_info.args } });
                }
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
                            try self.emit(.{
                                .ReturnCallExpand = .{
                                    .func = method,
                                    .args = fixed,
                                    .tail = tail,
                                },
                            });
                            return;
                        },
                        else => {},
                    }
                }

                const args_info = try self.genMethodArgs(recv, n.args);
                if (args_info.has_vararg_tail) {
                    try self.emit(.{ .ReturnCallVararg = .{ .func = method, .args = args_info.args } });
                } else {
                    try self.emit(.{ .ReturnCall = .{ .func = method, .args = args_info.args } });
                }
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
                try self.emit(.{ .UnOp = .{ .dst = dst, .op = n.op, .src = src } });
                return dst;
            },
            .BinOp => |n| {
                if (n.op == .And) return try self.genAndExp(n.lhs, n.rhs);
                if (n.op == .Or) return try self.genOrExp(n.lhs, n.rhs);
                const lhs = try self.genExp(n.lhs);
                const rhs = try self.genExp(n.rhs);
                const dst = self.newValue();
                try self.emit(.{ .BinOp = .{ .dst = dst, .op = n.op, .lhs = lhs, .rhs = rhs } });
                return dst;
            },
            .Table => |n| {
                const dst = self.newValue();
                try self.emit(.{ .NewTable = .{ .dst = dst } });
                for (n.fields) |f| {
                    switch (f.node) {
                        .Array => |val_e| {
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

    fn genForExplist(self: *Codegen, exps: []const *ast.Exp, out: *[3]ir.ValueId) Error!void {
        const nilv = try self.getNil(if (exps.len > 0) exps[0].span else ast.Span{ .start = 0, .end = 0, .line = 0, .col = 0 });
        out.* = .{ nilv, nilv, nilv };
        if (exps.len == 0) return;

        if (exps.len == 1) {
            const only = exps[0];
            switch (only.node) {
                .Call, .MethodCall => {
                    const dsts = try self.alloc.alloc(ir.ValueId, 3);
                    for (dsts) |*d| d.* = self.newValue();
                    try self.genCall(only, dsts);
                    out[0] = dsts[0];
                    out[1] = dsts[1];
                    out[2] = dsts[2];
                    return;
                },
                .Dots => {
                    if (!self.is_vararg) {
                        self.setDiag(only.span, "IR codegen: vararg used in non-vararg function");
                        return error.CodegenError;
                    }
                    const dsts = try self.alloc.alloc(ir.ValueId, 3);
                    for (dsts) |*d| d.* = self.newValue();
                    try self.emit(.{ .Vararg = .{ .dsts = dsts } });
                    out[0] = dsts[0];
                    out[1] = dsts[1];
                    out[2] = dsts[2];
                    return;
                },
                else => {
                    out[0] = try self.genExp(only);
                    return;
                },
            }
        }

        const last = exps[exps.len - 1];
        const fixed_count = if (exps.len - 1 < 3) exps.len - 1 else 3;
        var i: usize = 0;
        while (i < fixed_count) : (i += 1) {
            out[i] = try self.genExp(exps[i]);
        }
        while (i < exps.len - 1) : (i += 1) {
            _ = try self.genExp(exps[i]);
        }

        if (fixed_count >= 3) {
            _ = try self.genExp(last);
            return;
        }

        const remaining = 3 - fixed_count;
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
        .bytes =
        "x = {a = 1, [2] = 3, 4}\n" ++
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
