const std = @import("std");
const api = @import("api.zig");

// testC/T scaffold: command interpreter will map upstream ltests-style
// command snippets to calls on public api.State.
pub const Command = enum {
    pushinteger,
    pushint,
    pushnumber,
    pushnum,
    pushstring,
    pushvalue,
    pushnil,
    gettop,
    settop,
    pop,
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
    if (std.mem.eql(u8, name, "pushstring")) return .pushstring;
    if (std.mem.eql(u8, name, "pushvalue")) return .pushvalue;
    if (std.mem.eql(u8, name, "pushnil")) return .pushnil;
    if (std.mem.eql(u8, name, "gettop")) return .gettop;
    if (std.mem.eql(u8, name, "settop")) return .settop;
    if (std.mem.eql(u8, name, "pop")) return .pop;
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

    var stmts = std.mem.tokenizeAny(u8, script, ";\n,");
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
            if (argc >= args_buf.len) return error.InvalidState;
            args_buf[argc] = w;
            argc += 1;
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
