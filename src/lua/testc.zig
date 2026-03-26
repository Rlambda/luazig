const std = @import("std");
const api = @import("api.zig");

// testC/T scaffold: command interpreter will map upstream ltests-style
// command snippets to calls on public api.State.
pub const Command = enum {
    pushinteger,
    pushnumber,
    pushstring,
    pushnil,
    setglobal,
    getglobal,
    rawget,
    rawset,
    pcall,
};

pub fn parseCommand(name: []const u8) ?Command {
    if (std.mem.eql(u8, name, "pushinteger")) return .pushinteger;
    if (std.mem.eql(u8, name, "pushnumber")) return .pushnumber;
    if (std.mem.eql(u8, name, "pushstring")) return .pushstring;
    if (std.mem.eql(u8, name, "pushnil")) return .pushnil;
    if (std.mem.eql(u8, name, "setglobal")) return .setglobal;
    if (std.mem.eql(u8, name, "getglobal")) return .getglobal;
    if (std.mem.eql(u8, name, "rawget")) return .rawget;
    if (std.mem.eql(u8, name, "rawset")) return .rawset;
    if (std.mem.eql(u8, name, "pcall")) return .pcall;
    return null;
}

pub fn execute(st: *api.State, cmd: Command, args: []const []const u8) api.ApiError!void {
    switch (cmd) {
        .pushinteger => {
            if (args.len != 1) return error.InvalidState;
            const v = std.fmt.parseInt(i64, args[0], 10) catch return error.Type;
            try st.pushinteger(v);
        },
        .pushnumber => {
            if (args.len != 1) return error.InvalidState;
            const v = std.fmt.parseFloat(f64, args[0]) catch return error.Type;
            try st.pushnumber(v);
        },
        .pushstring => {
            if (args.len != 1) return error.InvalidState;
            try st.pushstring(args[0]);
        },
        .pushnil => {
            if (args.len != 0) return error.InvalidState;
            try st.pushnil();
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
    }
}

test "testc parse command" {
    try std.testing.expectEqual(Command.pushinteger, parseCommand("pushinteger").?);
    try std.testing.expect(parseCommand("missing") == null);
}
