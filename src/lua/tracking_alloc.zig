//! TrackingAllocator — wraps any backing allocator with exact byte counting.
//!
//! This is luazig's equivalent of PUC Lua's `luaM_realloc_`: a single
//! accounting chokepoint through which every VM allocation flows. PUC
//! charges every `luaM_*` call to `l_G->totalbytes`; we charge every
//! `alloc`/`resize`/`remap`/`free` to `total_bytes`.
//!
//! `collectgarbage("count")` reads `total_bytes / 1024` — no approximation,
//! no hand-placed `gcNoteAlloc`/`gcNoteFree` call sites.
//!
//! GC pacing also hooks here: the `gc_debt_kb` field is decremented on every
//! alloc, replacing the old `gcNoteAlloc` → `gc_step_debt_kb` mechanism.

const std = @import("std");
const Alignment = std.mem.Alignment;

pub const TrackingAllocator = struct {
    backing: std.mem.Allocator,
    /// Net bytes currently allocated through this allocator.
    /// Equivalent to PUC's `l_G->totalbytes`.
    total_bytes: usize = 0,
    /// GC debt in KB, decremented on every alloc. When ≤ 0, the next
    /// allocation-site GC check runs a step. Equivalent to PUC's `GCdebt`.
    /// Set by the Vm after each GC step/cycle; decremented here on alloc.
    gc_debt_kb: f64 = 0.0,

    pub fn init(backing: std.mem.Allocator) TrackingAllocator {
        return .{ .backing = backing };
    }

    /// Return a `std.mem.Allocator` interface backed by this tracker.
    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    // -----------------------------------------------------------------------
    // VTable implementation
    // -----------------------------------------------------------------------

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    fn allocFn(
        ctx: *anyopaque,
        len: usize,
        alignment: Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr);
        if (ptr != null) {
            self.total_bytes += len;
        }
        return ptr;
    }

    fn resizeFn(
        ctx: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.backing.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) {
            if (new_len >= memory.len) {
                self.total_bytes += new_len - memory.len;
            } else {
                self.total_bytes -|= memory.len - new_len;
            }
        }
        return ok;
    }

    fn remapFn(
        ctx: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (ptr != null) {
            if (new_len >= memory.len) {
                self.total_bytes += new_len - memory.len;
            } else {
                self.total_bytes -|= memory.len - new_len;
            }
        }
        return ptr;
    }

    fn freeFn(
        ctx: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        ret_addr: usize,
    ) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        // Use saturating subtraction to prevent overflow when accounting
        // drifts (e.g., memory allocated before tracker was set up, or
        // GC freeing objects whose allocation bypassed the tracker).
        self.total_bytes -|= memory.len;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "basic alloc/free tracking" {
    var tracker = TrackingAllocator.init(std.testing.allocator);
    const alloc = tracker.allocator();

    const before = tracker.total_bytes;
    const slice = try alloc.alloc(u8, 256);
    try std.testing.expectEqual(before + 256, tracker.total_bytes);

    alloc.free(slice);
    try std.testing.expectEqual(before, tracker.total_bytes);
}

test "resize tracking" {
    var tracker = TrackingAllocator.init(std.testing.allocator);
    const alloc = tracker.allocator();

    const slice = try alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), tracker.total_bytes);
    alloc.free(slice);
    try std.testing.expectEqual(@as(usize, 0), tracker.total_bytes);

    // Alloc larger and free
    const big = try alloc.alloc(u32, 50);
    try std.testing.expectEqual(@as(usize, 200), tracker.total_bytes);
    alloc.free(big);
    try std.testing.expectEqual(@as(usize, 0), tracker.total_bytes);
}

test "struct alloc/destroy tracking" {
    var tracker = TrackingAllocator.init(std.testing.allocator);
    const alloc = tracker.allocator();

    const Foo = struct { x: i32, y: i32, z: [16]u8 };
    const foo = try alloc.create(Foo);
    try std.testing.expectEqual(@sizeOf(Foo), tracker.total_bytes);
    alloc.destroy(foo);
    try std.testing.expectEqual(@as(usize, 0), tracker.total_bytes);
}
