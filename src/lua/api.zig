const std = @import("std");

const vm_mod = @import("vm.zig");

// Public Zig API (C-like by semantics) design contract.
//
// Scope of this module in current phase:
// - define stable surface and ownership/error model;
// - keep implementation thin and non-invasive to existing VM.
//
// Runtime methods are added in P4.2+.
pub const ApiError = error{
    Type,
    Runtime,
    Syntax,
    Memory,
    InvalidIndex,
    InvalidState,
};

pub const Type = enum(u8) {
    nil,
    boolean,
    number,
    string,
    table,
    function,
    thread,
    userdata,
};

pub const Status = enum(u8) {
    ok,
    runtime_error,
    syntax_error,
    memory_error,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
};

// `State` owns VM lifetime and the API stack frame used by public calls.
// Invariants:
// 1) stack_top <= stack_cap
// 2) positive indexes are 1-based from bottom; negative indexes from top (-1 top)
// 3) API functions never return borrowed pointers that outlive `State`
pub const State = struct {
    vm: vm_mod.Vm,
    alloc: std.mem.Allocator,

    pub fn init(opts: Options) State {
        return .{
            .vm = vm_mod.Vm.init(opts.allocator),
            .alloc = opts.allocator,
        };
    }

    pub fn deinit(self: *State) void {
        self.vm.deinit();
    }

    // Index normalization semantics (contract for P4.2 implementation):
    // idx > 0  -> absolute 1-based index from stack bottom
    // idx < 0  -> relative index from top
    // idx == 0 -> invalid
    pub fn normalizeIndex(self: *State, idx: i32, top: usize) ApiError!usize {
        _ = self;
        if (idx == 0) return error.InvalidIndex;
        if (idx > 0) {
            const abs: usize = @intCast(idx - 1);
            if (abs >= top) return error.InvalidIndex;
            return abs;
        }
        const r: usize = @intCast(-idx);
        if (r == 0 or r > top) return error.InvalidIndex;
        return top - r;
    }
};

test "api state lifecycle" {
    var st = State.init(.{ .allocator = std.testing.allocator });
    defer st.deinit();
    try std.testing.expect(true);
}

test "api index normalization contract" {
    var st = State.init(.{ .allocator = std.testing.allocator });
    defer st.deinit();

    try std.testing.expectEqual(@as(usize, 0), try st.normalizeIndex(1, 3));
    try std.testing.expectEqual(@as(usize, 2), try st.normalizeIndex(-1, 3));
    try std.testing.expectError(error.InvalidIndex, st.normalizeIndex(0, 3));
    try std.testing.expectError(error.InvalidIndex, st.normalizeIndex(4, 3));
}
