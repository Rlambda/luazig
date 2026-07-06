const std = @import("std");

const TokenKind = @import("token.zig").TokenKind;

pub const ValueId = u32;
pub const LabelId = u32;
pub const LocalId = u32;
pub const UpvalueId = u32;

pub const Capture = union(enum) {
    Local: LocalId,
    Upvalue: UpvalueId,
};

pub const Function = struct {
    pub const ForNumericControl = struct {
        init_local: LocalId,
        limit_local: LocalId,
        step_local: LocalId,
    };

    name: []const u8,
    source_name: []const u8 = "=?",
    line_defined: u32 = 0,
    last_line_defined: u32 = 0,
    insts: []const Inst,
    inst_lines: []const u32 = &.{},
    num_values: ValueId,
    num_locals: LocalId,
    /// Per-PC live register set (flat 2D: `live_regs[pc * num_values + reg]`).
    /// Computed by backward liveness at codegen time. Used by GC to mark only
    /// the live registers as roots — PUC Lua's `L->top` equivalent, but as a
    /// precise set rather than a high-water mark (registers below the max live
    /// index can be dead if they were consumed earlier).
    live_regs: []const bool = &.{},
    local_names: []const []const u8 = &.{},
    close_locals: []const LocalId = &.{},
    active_lines: []const u32 = &.{},
    is_vararg: bool = false,
    num_params: LocalId = 0,
    vararg_table_local: ?LocalId = null,
    num_upvalues: UpvalueId = 0,
    upvalue_names: []const []const u8 = &.{},
    captures: []const Capture = &.{},
    for_numeric_controls: []const ForNumericControl = &.{},
};

pub const CallSpec = struct {
    func: ValueId,
    args: []const ValueId,
    use_vararg: bool = false,
    tail: ?*const CallSpec = null,
};

pub const Inst = union(enum) {
    ConstNil: struct { dst: ValueId },
    ConstBool: struct { dst: ValueId, val: bool },
    ConstInt: struct { dst: ValueId, lexeme: []const u8 },
    ConstNum: struct { dst: ValueId, lexeme: []const u8 },
    ConstString: struct { dst: ValueId, lexeme: []const u8 },
    ConstFunc: struct { dst: ValueId, func: *const Function },

    GetName: struct { dst: ValueId, name: []const u8 },
    SetName: struct { name: []const u8, src: ValueId },
    GetLocal: struct { dst: ValueId, local: LocalId },
    SetLocal: struct { local: LocalId, src: ValueId },
    // Run `<close>` handler for a local (if any).
    CloseLocal: struct { local: LocalId },
    // Clear the *stack slot* for a local without touching a boxed upvalue cell.
    // This matches Lua's "stack top" behavior for GC roots at scope exit.
    ClearLocal: struct { local: LocalId },
    GetUpvalue: struct { dst: ValueId, upvalue: UpvalueId },
    SetUpvalue: struct { upvalue: UpvalueId, src: ValueId },

    UnOp: struct { dst: ValueId, op: TokenKind, src: ValueId },
    BinOp: struct { dst: ValueId, op: TokenKind, lhs: ValueId, rhs: ValueId },

    NewTable: struct { dst: ValueId },
    SetField: struct { object: ValueId, name: []const u8, value: ValueId },
    SetIndex: struct { object: ValueId, key: ValueId, value: ValueId },
    Append: struct { object: ValueId, value: ValueId },
    AppendCallExpand: struct { object: ValueId, tail: *const CallSpec },
    AppendVarargExpand: struct { object: ValueId },

    GetField: struct { dst: ValueId, object: ValueId, name: []const u8 },
    GetIndex: struct { dst: ValueId, object: ValueId, key: ValueId },

    Call: struct { dsts: []const ValueId, func: ValueId, args: []const ValueId },
    ForIterCall: struct { dsts: []const ValueId, func: ValueId, state: ValueId, ctrl: ValueId },
    CallVararg: struct { dsts: []const ValueId, func: ValueId, args: []const ValueId },
    CallExpand: struct { dsts: []const ValueId, func: ValueId, args: []const ValueId, tail: *const CallSpec },
    Return: struct { values: []const ValueId },
    ReturnExpand: struct { values: []const ValueId, tail: *const CallSpec },
    ReturnCall: struct { func: ValueId, args: []const ValueId },
    ReturnCallVararg: struct { func: ValueId, args: []const ValueId },
    ReturnCallExpand: struct { func: ValueId, args: []const ValueId, tail: *const CallSpec },
    Vararg: struct { dsts: []const ValueId },
    VarargTable: struct { dst: ValueId },
    ReturnVarargExpand: struct { values: []const ValueId },
    ReturnVararg,

    Label: struct { id: LabelId },
    Jump: struct { target: LabelId },
    JumpIfFalse: struct { cond: ValueId, target: LabelId },
    RaiseError: struct { msg: []const u8 },
};

// ---------------------------------------------------------------------------
// Register liveness analysis (backward dataflow with fixpoint for loops).
// ---------------------------------------------------------------------------

fn killDst(live: []bool, inst: Inst) void {
    switch (inst) {
        .ConstNil => |n| live[n.dst] = false,
        .ConstBool => |b| live[b.dst] = false,
        .ConstInt => |n| live[n.dst] = false,
        .ConstNum => |n| live[n.dst] = false,
        .ConstString => |n| live[n.dst] = false,
        .ConstFunc => |c| live[c.dst] = false,
        .GetName => |g| live[g.dst] = false,
        .GetLocal => |g| live[g.dst] = false,
        .GetUpvalue => |g| live[g.dst] = false,
        .UnOp => |u| live[u.dst] = false,
        .BinOp => |b| live[b.dst] = false,
        .NewTable => |t| live[t.dst] = false,
        .GetField => |g| live[g.dst] = false,
        .GetIndex => |g| live[g.dst] = false,
        .VarargTable => |v| live[v.dst] = false,
        .Call => |c| { for (c.dsts) |d| live[d] = false; },
        .ForIterCall => |c| { for (c.dsts) |d| live[d] = false; },
        .CallVararg => |c| { for (c.dsts) |d| live[d] = false; },
        .CallExpand => |c| { for (c.dsts) |d| live[d] = false; },
        .Vararg => |v| { for (v.dsts) |d| live[d] = false; },
        else => {},
    }
}

fn genSrc(live: []bool, inst: Inst) void {
    switch (inst) {
        .ConstNil, .ConstBool, .ConstInt, .ConstNum, .ConstString,
        .ConstFunc, .NewTable, .Label, .Jump, .RaiseError, .ReturnVararg,
        .CloseLocal, .ClearLocal, .VarargTable, .GetName, .GetLocal,
        .GetUpvalue, .Vararg => {},
        .UnOp => |u| live[u.src] = true,
        .JumpIfFalse => |j| live[j.cond] = true,
        .SetLocal => |s| live[s.src] = true,
        .SetUpvalue => |s| live[s.src] = true,
        .SetName => |s| live[s.src] = true,
        .BinOp => |b| { live[b.lhs] = true; live[b.rhs] = true; },
        .GetField => |g| live[g.object] = true,
        .GetIndex => |g| { live[g.object] = true; live[g.key] = true; },
        .SetField => |s| { live[s.object] = true; live[s.value] = true; },
        .SetIndex => |s| { live[s.object] = true; live[s.key] = true; live[s.value] = true; },
        .Append => |a| { live[a.object] = true; live[a.value] = true; },
        .AppendVarargExpand => |a| live[a.object] = true,
        .Call => |c| { live[c.func] = true; for (c.args) |a| live[a] = true; },
        .CallVararg => |c| { live[c.func] = true; for (c.args) |a| live[a] = true; },
        .CallExpand => |c| { live[c.func] = true; for (c.args) |a| live[a] = true; },
        .ForIterCall => |c| { live[c.func] = true; live[c.state] = true; live[c.ctrl] = true; },
        .Return => |r| { for (r.values) |v| live[v] = true; },
        .ReturnExpand => |r| { for (r.values) |v| live[v] = true; },
        .ReturnVarargExpand => |r| { for (r.values) |v| live[v] = true; },
        .ReturnCall => |r| { live[r.func] = true; for (r.args) |a| live[a] = true; },
        .ReturnCallVararg => |r| { live[r.func] = true; for (r.args) |a| live[a] = true; },
        .ReturnCallExpand => |r| { live[r.func] = true; for (r.args) |a| live[a] = true; },
        .AppendCallExpand => |a| {
            live[a.object] = true;
            var tail: ?*const CallSpec = a.tail;
            while (tail) |t| {
                live[t.func] = true;
                for (t.args) |arg| live[arg] = true;
                tail = t.tail;
            }
        },
    }
}

fn jumpTargetLabel(inst: Inst) ?LabelId {
    return switch (inst) {
        .Jump => |j| j.target,
        .JumpIfFalse => |j| j.target,
        else => null,
    };
}

pub fn computeLiveRegs(alloc: std.mem.Allocator, insts: []const Inst, num_values: ValueId) ![]bool {
    const n = insts.len * @as(usize, num_values);
    const result = try alloc.alloc(bool, n);
    @memset(result, false);
    if (num_values == 0 or insts.len == 0) return result;

    var label_map = std.AutoHashMap(LabelId, usize).init(alloc);
    defer label_map.deinit();
    for (insts, 0..) |inst, pc| {
        if (inst == .Label) try label_map.put(inst.Label.id, pc);
    }

    // Per-PC live-in sets (temporary, freed at end).
    const live_in = try alloc.alloc([]bool, insts.len);
    defer {
        for (live_in) |s| alloc.free(s);
        alloc.free(live_in);
    }
    for (live_in) |*s| {
        s.* = try alloc.alloc(bool, num_values);
        @memset(s.*, false);
    }
    const live_out = try alloc.alloc(bool, num_values);
    defer alloc.free(live_out);

    // Fixpoint iteration for backward liveness with loop support.
    var changed = true;
    while (changed) {
        changed = false;
        var pc: usize = insts.len;
        while (pc > 0) {
            pc -= 1;
            @memset(live_out, false);
            if (pc + 1 < insts.len) {
                for (live_in[pc + 1], 0..) |is_live, r| { if (is_live) live_out[r] = true; }
            }
            if (jumpTargetLabel(insts[pc])) |label| {
                if (label_map.get(label)) |target_pc| {
                    for (live_in[target_pc], 0..) |is_live, r| { if (is_live) live_out[r] = true; }
                }
            }
            killDst(live_out, insts[pc]);
            genSrc(live_out, insts[pc]);
            for (live_out, 0..) |is_live, r| {
                if (is_live != live_in[pc][r]) {
                    live_in[pc][r] = is_live;
                    changed = true;
                }
            }
        }
    }

    // Flatten live_in into result.
    for (live_in, 0..) |s, pc| {
        @memcpy(result[pc * num_values .. (pc + 1) * num_values], s);
    }
    return result;
}

fn isLiveAt(live_regs: []const bool, num_values: ValueId, pc: usize, reg: ValueId) bool {
    if (num_values == 0) return false;
    return live_regs[pc * num_values + reg];
}

test "computeLiveRegs: sequential dead-after-use" {
    const insts = [_]Inst{
        .{ .NewTable = .{ .dst = 0 } },                              // 0: R0 = {}
        .{ .SetLocal = .{ .local = 0, .src = 0 } },                  // 1: local t = R0
        .{ .NewTable = .{ .dst = 1 } },                              // 2: R1 = {} (temp key)
        .{ .ConstInt = .{ .dst = 2, .lexeme = "1" } },               // 3: R2 = 1
        .{ .SetIndex = .{ .object = 0, .key = 1, .value = 2 } },     // 4: t[R1] = R2
        .{ .GetName = .{ .dst = 3, .name = "collectgarbage" } },     // 5: R3 = collectgarbage
        .{ .Call = .{ .dsts = &.{}, .func = 3, .args = &.{} } },     // 6: collectgarbage()
        .{ .Return = .{ .values = &.{} } },                          // 7: return
    };
    const nv: ValueId = 4;
    const lr = try computeLiveRegs(std.testing.allocator, &insts, nv);
    defer std.testing.allocator.free(lr);
    // At Call (PC 6): only R3 is live. R0-R2 are dead.
    try std.testing.expect(isLiveAt(lr, nv, 6, 3));   // R3 live
    try std.testing.expect(!isLiveAt(lr, nv, 6, 0));  // R0 dead
    try std.testing.expect(!isLiveAt(lr, nv, 6, 1));  // R1 dead
    try std.testing.expect(!isLiveAt(lr, nv, 6, 2));  // R2 dead
}

test "computeLiveRegs: register defined before loop, dead after" {
    const L_start: LabelId = 0;
    const L_end: LabelId = 1;
    const insts = [_]Inst{
        .{ .NewTable = .{ .dst = 0 } },                              // 0: R0 = table t
        .{ .Label = .{ .id = L_start } },                            // 1: loop start
        .{ .GetLocal = .{ .dst = 1, .local = 0 } },                  // 2: R1 = i
        .{ .JumpIfFalse = .{ .cond = 1, .target = L_end } },         // 3: if not R1 goto end
        .{ .NewTable = .{ .dst = 2 } },                              // 4: R2 = {} key
        .{ .SetIndex = .{ .object = 0, .key = 2, .value = 1 } },     // 5: t[R2] = R1
        .{ .Jump = .{ .target = L_start } },                         // 6: loop back
        .{ .Label = .{ .id = L_end } },                              // 7: end
        .{ .GetName = .{ .dst = 3, .name = "collectgarbage" } },     // 8: R3 = collectgarbage
        .{ .Call = .{ .dsts = &.{}, .func = 3, .args = &.{} } },     // 9: collectgarbage()
        .{ .Return = .{ .values = &.{} } },                          // 10: return
    };
    const nv: ValueId = 4;
    const lr = try computeLiveRegs(std.testing.allocator, &insts, nv);
    defer std.testing.allocator.free(lr);
    // At Call (PC 9): only R3 is live. R0 (table t) is dead after loop.
    try std.testing.expect(isLiveAt(lr, nv, 9, 3));   // R3 live
    try std.testing.expect(!isLiveAt(lr, nv, 9, 0));  // R0 dead after loop
    try std.testing.expect(!isLiveAt(lr, nv, 9, 2));  // R2 dead (loop temp)
}

fn writeIndent(w: anytype, n: usize) anyerror!void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll("  ");
}

fn writeEscaped(w: anytype, bytes: []const u8) anyerror!void {
    for (bytes) |c| {
        switch (c) {
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            else => {
                if (c < 0x20 or c >= 0x7f) {
                    try w.print("\\x{X:0>2}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

fn writeQuoted(w: anytype, bytes: []const u8) anyerror!void {
    try w.writeByte('"');
    try writeEscaped(w, bytes);
    try w.writeByte('"');
}

fn writeValue(w: anytype, v: ValueId) anyerror!void {
    try w.print("v{d}", .{v});
}

fn writeValueList(w: anytype, vals: []const ValueId) anyerror!void {
    try w.writeByte('[');
    for (vals, 0..) |v, i| {
        if (i != 0) try w.writeAll(", ");
        try writeValue(w, v);
    }
    try w.writeByte(']');
}

fn writeCallSpec(w: anytype, spec: *const CallSpec) anyerror!void {
    try writeValue(w, spec.func);
    try w.writeAll(" args=");
    try writeValueList(w, spec.args);
    if (spec.use_vararg) try w.writeAll(" + ...");
    if (spec.tail) |t| {
        try w.writeAll(" + call ");
        try writeCallSpec(w, t);
    }
}

pub fn dumpFunction(w: anytype, f: *const Function) anyerror!void {
    try w.writeAll("Function ");
    try writeQuoted(w, f.name);
    try w.writeByte('\n');

    for (f.insts, 0..) |inst, i| {
        try writeIndent(w, 1);
        try w.print("{d}: ", .{i});
        try dumpInst(w, inst);
        try w.writeByte('\n');
    }
}

pub fn dumpInst(w: anytype, inst: Inst) anyerror!void {
    switch (inst) {
        .ConstNil => |n| {
            try writeValue(w, n.dst);
            try w.writeAll(" = const nil");
        },
        .ConstBool => |b| {
            try writeValue(w, b.dst);
            try w.print(" = const {s}", .{if (b.val) "true" else "false"});
        },
        .ConstInt => |n| {
            try writeValue(w, n.dst);
            try w.writeAll(" = const_int ");
            try writeQuoted(w, n.lexeme);
        },
        .ConstNum => |n| {
            try writeValue(w, n.dst);
            try w.writeAll(" = const_num ");
            try writeQuoted(w, n.lexeme);
        },
        .ConstString => |s| {
            try writeValue(w, s.dst);
            try w.writeAll(" = const_str ");
            try writeQuoted(w, s.lexeme);
        },
        .ConstFunc => |f| {
            try writeValue(w, f.dst);
            try w.writeAll(" = const_func ");
            try writeQuoted(w, f.func.name);
        },
        .GetName => |g| {
            try writeValue(w, g.dst);
            try w.writeAll(" = getname ");
            try writeQuoted(w, g.name);
        },
        .SetName => |s| {
            try w.writeAll("setname ");
            try writeQuoted(w, s.name);
            try w.writeAll(" <- ");
            try writeValue(w, s.src);
        },
        .GetLocal => |g| {
            try writeValue(w, g.dst);
            try w.print(" = getlocal l{d}", .{g.local});
        },
        .SetLocal => |s| {
            try w.print("setlocal l{d} <- ", .{s.local});
            try writeValue(w, s.src);
        },
        .CloseLocal => |c| {
            try w.print("closelocal l{d}", .{c.local});
        },
        .ClearLocal => |c| {
            try w.print("clearlocal l{d}", .{c.local});
        },
        .GetUpvalue => |g| {
            try writeValue(w, g.dst);
            try w.print(" = getup u{d}", .{g.upvalue});
        },
        .SetUpvalue => |s| {
            try w.print("setup u{d} <- ", .{s.upvalue});
            try writeValue(w, s.src);
        },
        .UnOp => |u| {
            try writeValue(w, u.dst);
            try w.print(" = unop {s} ", .{u.op.name()});
            try writeValue(w, u.src);
        },
        .BinOp => |b| {
            try writeValue(w, b.dst);
            try w.print(" = binop {s} ", .{b.op.name()});
            try writeValue(w, b.lhs);
            try w.writeAll(", ");
            try writeValue(w, b.rhs);
        },
        .NewTable => |t| {
            try writeValue(w, t.dst);
            try w.writeAll(" = newtable");
        },
        .SetField => |s| {
            try w.writeAll("setfield ");
            try writeValue(w, s.object);
            try w.writeAll(" ");
            try writeQuoted(w, s.name);
            try w.writeAll(" <- ");
            try writeValue(w, s.value);
        },
        .SetIndex => |s| {
            try w.writeAll("setindex ");
            try writeValue(w, s.object);
            try w.writeAll(" [");
            try writeValue(w, s.key);
            try w.writeAll("] <- ");
            try writeValue(w, s.value);
        },
        .Append => |a| {
            try w.writeAll("append ");
            try writeValue(w, a.object);
            try w.writeAll(" <- ");
            try writeValue(w, a.value);
        },
        .AppendCallExpand => |a| {
            try w.writeAll("append_expand ");
            try writeValue(w, a.object);
            try w.writeAll(" <- call ");
            try writeCallSpec(w, a.tail);
        },
        .AppendVarargExpand => |a| {
            try w.writeAll("append_expand ");
            try writeValue(w, a.object);
            try w.writeAll(" <- vararg");
        },
        .GetField => |g| {
            try writeValue(w, g.dst);
            try w.writeAll(" = getfield ");
            try writeValue(w, g.object);
            try w.writeAll(" ");
            try writeQuoted(w, g.name);
        },
        .GetIndex => |g| {
            try writeValue(w, g.dst);
            try w.writeAll(" = getindex ");
            try writeValue(w, g.object);
            try w.writeAll(" [");
            try writeValue(w, g.key);
            try w.writeAll("]");
        },
        .Call => |c| {
            try w.writeAll("call ");
            try writeValueList(w, c.dsts);
            try w.writeAll(" <- ");
            try writeValue(w, c.func);
            try w.writeAll(" args=");
            try writeValueList(w, c.args);
        },
        .ForIterCall => |c| {
            try w.writeAll("foriter ");
            try writeValueList(w, c.dsts);
            try w.writeAll(" <- ");
            try writeValue(w, c.func);
            try w.writeAll(" state=");
            try writeValue(w, c.state);
            try w.writeAll(" ctrl=");
            try writeValue(w, c.ctrl);
        },
        .CallVararg => |c| {
            try w.writeAll("call_vararg ");
            try writeValueList(w, c.dsts);
            try w.writeAll(" <- ");
            try writeValue(w, c.func);
            try w.writeAll(" args=");
            try writeValueList(w, c.args);
            try w.writeAll(" + ...");
        },
        .CallExpand => |c| {
            try w.writeAll("call_expand ");
            try writeValueList(w, c.dsts);
            try w.writeAll(" <- ");
            try writeValue(w, c.func);
            try w.writeAll(" args=");
            try writeValueList(w, c.args);
            try w.writeAll(" + call ");
            try writeCallSpec(w, c.tail);
        },
        .Return => |r| {
            try w.writeAll("return ");
            try writeValueList(w, r.values);
        },
        .ReturnExpand => |r| {
            try w.writeAll("return_expand ");
            try writeValueList(w, r.values);
            try w.writeAll(" + call ");
            try writeCallSpec(w, r.tail);
        },
        .ReturnCall => |r| {
            try w.writeAll("return_call ");
            try writeValue(w, r.func);
            try w.writeAll(" args=");
            try writeValueList(w, r.args);
        },
        .ReturnCallVararg => |r| {
            try w.writeAll("return_call_vararg ");
            try writeValue(w, r.func);
            try w.writeAll(" args=");
            try writeValueList(w, r.args);
            try w.writeAll(" + ...");
        },
        .ReturnCallExpand => |r| {
            try w.writeAll("return_call_expand ");
            try writeValue(w, r.func);
            try w.writeAll(" args=");
            try writeValueList(w, r.args);
            try w.writeAll(" + call ");
            try writeCallSpec(w, r.tail);
        },
        .Vararg => |v| {
            try w.writeAll("vararg ");
            try writeValueList(w, v.dsts);
        },
        .VarargTable => |v| {
            try writeValue(w, v.dst);
            try w.writeAll(" = vararg_table");
        },
        .ReturnVarargExpand => |r| {
            try w.writeAll("return_vararg_expand ");
            try writeValueList(w, r.values);
            try w.writeAll(" + ...");
        },
        .ReturnVararg => {
            try w.writeAll("return_vararg");
        },
        .Label => |l| {
            try w.print("label L{d}", .{l.id});
        },
        .Jump => |j| {
            try w.print("jump L{d}", .{j.target});
        },
        .JumpIfFalse => |j| {
            try w.writeAll("jifalse ");
            try writeValue(w, j.cond);
            try w.print(" -> L{d}", .{j.target});
        },
        .RaiseError => |r| {
            try w.writeAll("raise_error ");
            try writeQuoted(w, r.msg);
        },
    }
}

test "ir dump: manual small function" {
    const testing = std.testing;

    const insts = [_]Inst{
        .{ .ConstInt = .{ .dst = 0, .lexeme = "1" } },
        .{ .ConstInt = .{ .dst = 1, .lexeme = "2" } },
        .{ .BinOp = .{ .dst = 2, .op = .Plus, .lhs = 0, .rhs = 1 } },
        .{ .Return = .{ .values = &[_]ValueId{2} } },
    };

    const f: Function = .{
        .name = "main",
        .insts = insts[0..],
        .num_values = 3,
        .num_locals = 0,
    };

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    try dumpFunction(&buf.writer, &f);
    try testing.expectEqualStrings(
        \\Function "main"
        \\  0: v0 = const_int "1"
        \\  1: v1 = const_int "2"
        \\  2: v2 = binop + v0, v1
        \\  3: return [v2]
        \\
    , buf.written());
}
