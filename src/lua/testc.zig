const std = @import("std");
const api = @import("api.zig");

// testC/T scaffold: command interpreter will map upstream ltests-style
// command snippets to calls on public api.State.
pub const Command = enum {
    pushinteger,
    pushint,
    pushnumber,
    pushnum,
    pushbool,
    pushstring,
    pushvalue,
    pushnil,
    gettop,
    absindex,
    settop,
    pop,
    tobool,
    remove,
    insert,
    replace,
    copy,
    rotate,
    concat,
    call,
    tostring,
    checkstack,
    warningC,
    warning,
    pushstatus,
    arith,
    compare,
    len,
    Llen,
    objsize,
    isnumber,
    isstring,
    isfunction,
    iscfunction,
    istable,
    isuserdata,
    isnil,
    isnull,
    tonumber,
    topointer,
    func2num,
    tocfunction,
    threadstatus,
    @"error",
    loadstring,
    setglobal,
    getglobal,
    rawget,
    rawset,
    pcall,
    ret,
};

pub fn parseCommand(name: []const u8) ?Command {
    if (std.mem.eql(u8, name, "pushinteger")) return .pushinteger;
    if (std.mem.eql(u8, name, "pushint")) return .pushint;
    if (std.mem.eql(u8, name, "pushnumber")) return .pushnumber;
    if (std.mem.eql(u8, name, "pushnum")) return .pushnum;
    if (std.mem.eql(u8, name, "pushbool")) return .pushbool;
    if (std.mem.eql(u8, name, "pushstring")) return .pushstring;
    if (std.mem.eql(u8, name, "pushvalue")) return .pushvalue;
    if (std.mem.eql(u8, name, "pushnil")) return .pushnil;
    if (std.mem.eql(u8, name, "gettop")) return .gettop;
    if (std.mem.eql(u8, name, "absindex")) return .absindex;
    if (std.mem.eql(u8, name, "settop")) return .settop;
    if (std.mem.eql(u8, name, "pop")) return .pop;
    if (std.mem.eql(u8, name, "tobool")) return .tobool;
    if (std.mem.eql(u8, name, "remove")) return .remove;
    if (std.mem.eql(u8, name, "insert")) return .insert;
    if (std.mem.eql(u8, name, "replace")) return .replace;
    if (std.mem.eql(u8, name, "copy")) return .copy;
    if (std.mem.eql(u8, name, "rotate")) return .rotate;
    if (std.mem.eql(u8, name, "concat")) return .concat;
    if (std.mem.eql(u8, name, "call")) return .call;
    if (std.mem.eql(u8, name, "tostring")) return .tostring;
    if (std.mem.eql(u8, name, "checkstack")) return .checkstack;
    if (std.mem.eql(u8, name, "warningC")) return .warningC;
    if (std.mem.eql(u8, name, "warning")) return .warning;
    if (std.mem.eql(u8, name, "pushstatus")) return .pushstatus;
    if (std.mem.eql(u8, name, "arith")) return .arith;
    if (std.mem.eql(u8, name, "compare")) return .compare;
    if (std.mem.eql(u8, name, "len")) return .len;
    if (std.mem.eql(u8, name, "Llen")) return .Llen;
    if (std.mem.eql(u8, name, "objsize")) return .objsize;
    if (std.mem.eql(u8, name, "isnumber")) return .isnumber;
    if (std.mem.eql(u8, name, "isstring")) return .isstring;
    if (std.mem.eql(u8, name, "isfunction")) return .isfunction;
    if (std.mem.eql(u8, name, "iscfunction")) return .iscfunction;
    if (std.mem.eql(u8, name, "istable")) return .istable;
    if (std.mem.eql(u8, name, "isuserdata")) return .isuserdata;
    if (std.mem.eql(u8, name, "isnil")) return .isnil;
    if (std.mem.eql(u8, name, "isnull")) return .isnull;
    if (std.mem.eql(u8, name, "tonumber")) return .tonumber;
    if (std.mem.eql(u8, name, "topointer")) return .topointer;
    if (std.mem.eql(u8, name, "func2num")) return .func2num;
    if (std.mem.eql(u8, name, "tocfunction")) return .tocfunction;
    if (std.mem.eql(u8, name, "threadstatus")) return .threadstatus;
    if (std.mem.eql(u8, name, "error")) return .@"error";
    if (std.mem.eql(u8, name, "loadstring")) return .loadstring;
    if (std.mem.eql(u8, name, "setglobal")) return .setglobal;
    if (std.mem.eql(u8, name, "getglobal")) return .getglobal;
    if (std.mem.eql(u8, name, "rawget")) return .rawget;
    if (std.mem.eql(u8, name, "rawset")) return .rawset;
    if (std.mem.eql(u8, name, "pcall")) return .pcall;
    if (std.mem.eql(u8, name, "return")) return .ret;
    return null;
}

pub const ReturnSpec = union(enum) {
    fixed: usize,
    all,
};

pub const RunResult = struct {
    return_spec: ?ReturnSpec = null,
};

pub fn execute(st: *api.State, cmd: Command, args: []const []const u8) api.ApiError!?ReturnSpec {
    switch (cmd) {
        .pushinteger => {
            if (args.len != 1) return error.InvalidState;
            const v = std.fmt.parseInt(i64, args[0], 10) catch return error.Type;
            try st.pushinteger(v);
        },
        .pushint => {
            if (args.len != 1) return error.InvalidState;
            const v = std.fmt.parseInt(i64, args[0], 10) catch return error.Type;
            try st.pushinteger(v);
        },
        .pushnumber => {
            if (args.len != 1) return error.InvalidState;
            const v = std.fmt.parseFloat(f64, args[0]) catch return error.Type;
            try st.pushnumber(v);
        },
        .pushnum => {
            if (args.len != 1) return error.InvalidState;
            const v = std.fmt.parseFloat(f64, args[0]) catch return error.Type;
            try st.pushnumber(v);
        },
        .pushstring => {
            if (args.len != 1) return error.InvalidState;
            try st.pushstring(args[0]);
        },
        .pushbool => {
            if (args.len != 1) return error.InvalidState;
            const v = std.fmt.parseInt(i64, args[0], 10) catch return error.Type;
            try st.pushboolean(v != 0);
        },
        .pushvalue => {
            if (args.len != 1) return error.InvalidState;
            const idx = parseIndex(args[0]) catch return error.Type;
            try st.pushvalue(idx);
        },
        .pushnil => {
            if (args.len != 0) return error.InvalidState;
            try st.pushnil();
        },
        .gettop => {
            if (args.len != 0) return error.InvalidState;
            try st.pushinteger(@intCast(st.gettop()));
        },
        .absindex => {
            if (args.len != 1) return error.InvalidState;
            if (std.mem.eql(u8, args[0], "R")) {
                try st.pushinteger(-10000);
            } else {
                const idx = parseIndex(args[0]) catch return error.Type;
                const top = st.gettop();
                const abs: i64 = if (idx > 0)
                    idx
                else if (idx < 0)
                    @as(i64, @intCast(top)) + @as(i64, idx) + 1
                else
                    return error.InvalidIndex;
                try st.pushinteger(abs);
            }
        },
        .settop => {
            if (args.len != 1) return error.InvalidState;
            const idx = parseIndex(args[0]) catch return error.Type;
            try st.settop(idx);
        },
        .pop => {
            if (args.len != 1) return error.InvalidState;
            const n = std.fmt.parseInt(usize, args[0], 10) catch return error.Type;
            try st.pop(n);
        },
        .tobool => {
            if (args.len != 1) return error.InvalidState;
            const idx = parseIndex(args[0]) catch return error.Type;
            try st.pushboolean(st.toboolean(idx));
        },
        .remove, .insert, .replace, .copy, .rotate, .concat, .call, .tostring, .checkstack, .warningC, .warning, .pushstatus, .arith, .compare, .len, .Llen, .objsize, .isnumber, .isstring, .isfunction, .iscfunction, .istable, .isuserdata, .isnil, .isnull, .tonumber, .topointer, .func2num, .tocfunction, .threadstatus, .@"error", .loadstring => return error.InvalidState,
        .setglobal => {
            if (args.len != 1) return error.InvalidState;
            try st.setglobal(args[0]);
        },
        .getglobal => {
            if (args.len != 1) return error.InvalidState;
            _ = try st.getglobal(args[0]);
        },
        .rawget => {
            if (args.len != 1) return error.InvalidState;
            const idx = std.fmt.parseInt(i32, args[0], 10) catch return error.Type;
            _ = try st.rawget(idx);
        },
        .rawset => {
            if (args.len != 1) return error.InvalidState;
            const idx = std.fmt.parseInt(i32, args[0], 10) catch return error.Type;
            try st.rawset(idx);
        },
        .pcall => {
            if (args.len != 2) return error.InvalidState;
            const nargs = std.fmt.parseInt(usize, args[0], 10) catch return error.Type;
            const nresults = std.fmt.parseInt(i32, args[1], 10) catch return error.Type;
            const stc = st.pcall(nargs, nresults);
            if (stc != .ok) return error.Runtime;
        },
        .ret => {
            if (args.len != 1) return error.InvalidState;
            if (std.mem.eql(u8, args[0], "*")) return .all;
            const n = std.fmt.parseInt(usize, args[0], 10) catch return error.Type;
            return .{ .fixed = n };
        },
    }
    return null;
}

pub fn runScript(st: *api.State, script: []const u8) api.ApiError!RunResult {
    var out: RunResult = .{};
    var norm = std.ArrayList(u8).empty;
    defer norm.deinit(st.alloc);
    var i_norm: usize = 0;
    while (i_norm < script.len) : (i_norm += 1) {
        if (script[i_norm] == ',') {
            var j = i_norm + 1;
            while (j < script.len and (script[j] == ' ' or script[j] == '\t')) : (j += 1) {}
            if (j + 6 <= script.len and std.mem.eql(u8, script[j .. j + 6], "return")) {
                try norm.append(st.alloc, ';');
                continue;
            }
        }
        try norm.append(st.alloc, script[i_norm]);
    }

    var stmts = std.mem.tokenizeAny(u8, norm.items, ";\n");
    while (stmts.next()) |stmt_raw| {
        const stmt_no_comment = if (std.mem.indexOfScalar(u8, stmt_raw, '#')) |hash_idx|
            std.mem.trim(u8, stmt_raw[0..hash_idx], " \t\r")
        else
            std.mem.trim(u8, stmt_raw, " \t\r");
        if (stmt_no_comment.len == 0) continue;
        var words = std.mem.tokenizeScalar(u8, stmt_no_comment, ' ');
        const op = words.next() orelse continue;
        const cmd = parseCommand(op) orelse return error.InvalidState;

        var args_buf: [8][]const u8 = undefined;
        var argc: usize = 0;
        while (words.next()) |w| {
            var parts = std.mem.tokenizeScalar(u8, w, ',');
            while (parts.next()) |p0| {
                const p = std.mem.trim(u8, p0, " \t\r");
                if (p.len == 0) continue;
                if (argc >= args_buf.len) return error.InvalidState;
                args_buf[argc] = p;
                argc += 1;
            }
        }
        const ret = try execute(st, cmd, args_buf[0..argc]);
        if (ret != null) out.return_spec = ret.?;
    }

    return out;
}

fn parseIndex(s: []const u8) !i32 {
    if (std.mem.eql(u8, s, "R")) return -10000;
    return std.fmt.parseInt(i32, s, 10);
}

test "testc parse command" {
    try std.testing.expectEqual(Command.pushinteger, parseCommand("pushinteger").?);
    try std.testing.expect(parseCommand("missing") == null);
}

test "testc run script subset" {
    var st = api.State.init(.{ .allocator = std.testing.allocator });
    defer st.deinit();

    const rr = try runScript(&st, "pushint 2; pushint 3; gettop; return 2");
    try std.testing.expect(rr.return_spec != null);
    try std.testing.expectEqual(@as(i64, 2), st.tointeger(-1).?);
    try std.testing.expectEqual(@as(i64, 3), st.tointeger(-2).?);
}
