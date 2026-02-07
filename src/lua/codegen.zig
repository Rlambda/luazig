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
    nil_cache: ?ir.ValueId = null,
    insts: std.ArrayListUnmanaged(ir.Inst) = .{},
    bindings: std.ArrayListUnmanaged(Binding) = .{},
    scope_marks: std.ArrayListUnmanaged(usize) = .{},
    loop_ends: std.ArrayListUnmanaged(ir.LabelId) = .{},

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
        self.bindings.items.len = mark;
    }

    fn declareLocal(self: *Codegen, name: []const u8) Error!ir.LocalId {
        const id = self.next_local;
        self.next_local += 1;
        try self.bindings.append(self.alloc, .{ .name = name, .local = id });
        return id;
    }

    fn allocTempLocal(self: *Codegen) ir.LocalId {
        const id = self.next_local;
        self.next_local += 1;
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
                .Return => true,
                else => false,
            };
            if (!has_return) {
                const empty = &[_]ir.ValueId{};
                try self.emit(.{ .Return = .{ .values = empty[0..] } });
            }
        }

        const insts = try self.insts.toOwnedSlice(self.alloc);
        const f = try self.alloc.create(ir.Function);
        f.* = .{
            .name = "main",
            .insts = insts,
            .num_values = self.next_value,
            .num_locals = self.next_local,
        };
        return f;
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
                const rhs = if (n.values) |vs| try self.genExplist(vs) else empty[0..];
                const locals = try self.alloc.alloc(ir.LocalId, n.names.len);
                for (n.names, 0..) |d, i| locals[i] = try self.declareLocal(d.name.slice(self.source));
                for (n.names, 0..) |d, i| {
                    const value = if (i < rhs.len) rhs[i] else try self.getNil(d.name.span);
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
                const empty = &[_]ir.ValueId{};
                const rhs = if (n.values) |vs| try self.genExplist(vs) else empty[0..];
                for (n.names, 0..) |d, i| {
                    const value = if (i < rhs.len) rhs[i] else try self.getNil(d.name.span);
                    try self.emit(.{ .SetName = .{ .name = d.name.slice(self.source), .src = value } });
                }
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
                const name = n.slice(self.source);
                if (self.lookupLocal(name)) |local| {
                    try self.emit(.{ .SetLocal = .{ .local = local, .src = rhs } });
                } else {
                    try self.emit(.{ .SetName = .{ .name = name, .src = rhs } });
                }
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
        switch (call_exp.node) {
            .Call => |n| {
                const func = try self.genExp(n.func);
                const args = try self.genExplist(n.args);
                const dsts = &[_]ir.ValueId{};
                try self.emit(.{ .Call = .{ .dsts = dsts[0..], .func = func, .args = args } });
            },
            .MethodCall => |n| {
                const recv = try self.genExp(n.receiver);
                const method = self.newValue();
                try self.emit(.{ .GetField = .{ .dst = method, .object = recv, .name = n.method.slice(self.source) } });

                const args = try self.genExplistMethod(recv, n.args);
                const dsts = &[_]ir.ValueId{};
                try self.emit(.{ .Call = .{ .dsts = dsts[0..], .func = method, .args = args } });
            },
            else => {
                self.setDiag(call_exp.span, "IR codegen: expected call expression");
                return error.CodegenError;
            },
        }
    }

    fn genExplistMethod(self: *Codegen, recv: ir.ValueId, args: []const *ast.Exp) Error![]const ir.ValueId {
        const out = try self.alloc.alloc(ir.ValueId, 1 + args.len);
        out[0] = recv;
        for (args, 0..) |e, i| {
            out[1 + i] = try self.genExp(e);
        }
        return out;
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
            .Name => |n| {
                const name = n.slice(self.source);
                if (self.lookupLocal(name)) |local| {
                    const dst = self.newValue();
                    try self.emit(.{ .GetLocal = .{ .dst = dst, .local = local } });
                    return dst;
                }
                const dst = self.newValue();
                try self.emit(.{ .GetName = .{ .dst = dst, .name = name } });
                return dst;
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
            .Call => |n| {
                const func = try self.genExp(n.func);
                const args = try self.genExplist(n.args);
                const dst = self.newValue();
                const dsts = try self.alloc.alloc(ir.ValueId, 1);
                dsts[0] = dst;
                try self.emit(.{ .Call = .{ .dsts = dsts, .func = func, .args = args } });
                return dst;
            },
            .MethodCall => |n| {
                const recv = try self.genExp(n.receiver);
                const method = self.newValue();
                try self.emit(.{ .GetField = .{ .dst = method, .object = recv, .name = n.method.slice(self.source) } });
                const args = try self.genExplistMethod(recv, n.args);
                const dst = self.newValue();
                const dsts = try self.alloc.alloc(ir.ValueId, 1);
                dsts[0] = dst;
                try self.emit(.{ .Call = .{ .dsts = dsts, .func = method, .args = args } });
                return dst;
            },
            else => {
                self.setDiag(e.span, "IR codegen: unsupported expression");
                return error.CodegenError;
            },
        }
    }

    fn genAndExp(self: *Codegen, lhs_exp: *const ast.Exp, rhs_exp: *const ast.Exp) Error!ir.ValueId {
        const tmp = self.allocTempLocal();
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
        const tmp = self.allocTempLocal();
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
