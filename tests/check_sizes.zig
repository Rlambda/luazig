const std = @import("std");
const vm = @import("../../src/lua/vm.zig");
pub fn main() void {
    std.debug.print("CallFrame: {} B\n", .{@sizeOf(vm.CallFrame)});
    std.debug.print("PendingCallSlot: {} B\n", .{@sizeOf(vm.PendingCallSlot)});
    std.debug.print("BytecodePendingCall: {} B\n", .{@sizeOf(vm.BytecodePendingCall)});
    std.debug.print("BytecodePendingCompletion: {} B\n", .{@sizeOf(vm.BytecodePendingCompletion)});
    std.debug.print("32 * CallFrame: {} B = {} KB\n", .{ 32 * @sizeOf(vm.CallFrame), 32 * @sizeOf(vm.CallFrame) / 1024 });
}
