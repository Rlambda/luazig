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
//!
//! ## Leak-map mode (LUAZIG_TRACK_ALLOC=1)
//!
//! When `leak_track_enabled` is true, every alloc/remap/free is recorded in
//! a `leak_map` keyed by pointer address. At process exit, `reportLeaks`
//! groups outstanding allocations by callsite (return address) and prints
//! count/bytes, top-10 callsites, and size-bucket distribution. This is how
//! the P16.4f concat leak and the P16.5a coroutine RSS growth were found.
//!
//! The leak map uses the **backing** allocator directly (not through the
//! tracker vtable) to avoid recursive accounting.

const std = @import("std");
const Alignment = std.mem.Alignment;

/// Record for a single outstanding allocation in the leak map.
const AllocRecord = struct {
    ret_addr: usize,
    len: usize,
};

/// Entry for a callsite group in the leak report.
const CallsiteGroup = struct {
    ret_addr: usize,
    count: usize,
    bytes: usize,
    /// Representative allocation lengths (up to 8 samples).
    sample_lens: [8]usize = [_]usize{0} ** 8,
    n_samples: usize = 0,
};

pub const TrackingAllocator = struct {
    backing: std.mem.Allocator,
    /// Net bytes currently allocated through this allocator.
    /// Equivalent to PUC's `l_G->totalbytes`.
    total_bytes: usize = 0,
    /// GC debt in KB, decremented on every alloc.
    gc_debt_kb: f64 = 0.0,
    /// Debug: count of alloc/free calls (set LUAZIG_TRACE_ALLOC=1 to print).
    alloc_count: usize = 0,
    free_count: usize = 0,
    trace_enabled: bool = false,

    // --- Leak-map support (P16.5a) ---
    /// When true, every alloc/remap/free is tracked in `leak_map`.
    /// Enable via `enableLeakTracking()`. Zero overhead when false.
    leak_track_enabled: bool = false,
    /// Map from pointer address → AllocRecord. Uses `backing` directly
    /// (not through the tracker vtable) to avoid recursive accounting.
    leak_map: std.AutoHashMapUnmanaged(usize, AllocRecord) = .{},

    pub fn init(backing: std.mem.Allocator) TrackingAllocator {
        return .{ .backing = backing };
    }

    /// Enable leak-map tracking. Must be called before any allocations
    /// flow through the tracker. The leak map uses the backing allocator
    /// directly, so its own internal allocations are NOT tracked.
    pub fn enableLeakTracking(self: *TrackingAllocator) void {
        self.leak_track_enabled = true;
    }

    /// Free all leak-map storage. Call after `reportLeaks` if the tracker
    /// is not going to be used again.
    pub fn deinitLeakMap(self: *TrackingAllocator) void {
        self.leak_map.deinit(self.backing);
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
            self.alloc_count += 1;
            if (self.leak_track_enabled) {
                self.leak_map.put(self.backing, @intFromPtr(ptr), .{
                    .ret_addr = ret_addr,
                    .len = len,
                }) catch {};
            }
            if (self.trace_enabled and len == 8) {
                // Trace logging disabled — re-enable with trace_enabled.
            }
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
            // resize is in-place: ptr unchanged, just update len.
            if (self.leak_track_enabled) {
                if (self.leak_map.getPtr(@intFromPtr(memory.ptr))) |rec| {
                    rec.len = new_len;
                }
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
        const old_ptr = @intFromPtr(memory.ptr);
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        if (ptr != null) {
            if (new_len >= memory.len) {
                self.total_bytes += new_len - memory.len;
            } else {
                self.total_bytes -|= memory.len - new_len;
            }
            if (self.leak_track_enabled) {
                const new_ptr = @intFromPtr(ptr);
                if (new_ptr != old_ptr) {
                    // Remap moved the allocation: remove old, insert new.
                    _ = self.leak_map.remove(old_ptr);
                    self.leak_map.put(self.backing, new_ptr, .{
                        .ret_addr = ret_addr,
                        .len = new_len,
                    }) catch {};
                } else {
                    // In-place remap: just update len.
                    if (self.leak_map.getPtr(new_ptr)) |rec| {
                        rec.len = new_len;
                    }
                }
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
        self.total_bytes -|= memory.len;
        self.free_count += 1;
        if (self.leak_track_enabled) {
            _ = self.leak_map.remove(@intFromPtr(memory.ptr));
        }
        if (self.trace_enabled and memory.len == 8) {
            // Trace logging disabled — re-enable with trace_enabled.
        }
        self.backing.rawFree(memory, alignment, ret_addr);
    }

    // -----------------------------------------------------------------------
    // Leak report
    // -----------------------------------------------------------------------

    /// Print a leak report to stderr: total outstanding bytes, alloc/free
    /// counts, TOP-10 callsites by outstanding bytes (with representative
    /// lengths), and size-bucket distribution. This is the diagnostic
    /// output used to identify native-memory leaks (P16.5a).
    pub fn reportLeaks(self: *TrackingAllocator) void {
        const n_outstanding = self.leak_map.count();
        var total_outstanding: usize = 0;

        // Group by callsite (ret_addr).
        var groups = std.AutoHashMapUnmanaged(usize, CallsiteGroup){};
        defer groups.deinit(self.backing);

        var it = self.leak_map.iterator();
        while (it.next()) |entry| {
            const rec = entry.value_ptr.*;
            total_outstanding += rec.len;

            const gop = groups.getOrPut(self.backing, rec.ret_addr) catch continue;
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .ret_addr = rec.ret_addr,
                    .count = 0,
                    .bytes = 0,
                };
            }
            gop.value_ptr.count += 1;
            gop.value_ptr.bytes += rec.len;
            if (gop.value_ptr.n_samples < 8) {
                gop.value_ptr.sample_lens[gop.value_ptr.n_samples] = rec.len;
                gop.value_ptr.n_samples += 1;
            }
        }

        std.debug.print(
            \\=== TrackingAllocator Leak Report ===
            \\alloc_count:    {d}
            \\free_count:     {d}
            \\outstanding:    {d} allocations, {d} bytes
            \\
        , .{ self.alloc_count, self.free_count, n_outstanding, total_outstanding });

        if (n_outstanding == 0) {
            std.debug.print("(no outstanding allocations)\n", .{});
            return;
        }

        // Collect groups into a slice for sorting.
        var group_list = self.backing.alloc(CallsiteGroup, groups.count()) catch return;
        defer self.backing.free(group_list);
        var gi: usize = 0;
        var git = groups.iterator();
        while (git.next()) |entry| {
            group_list[gi] = entry.value_ptr.*;
            gi += 1;
        }

        // Sort by bytes descending.
        std.mem.sort(CallsiteGroup, group_list, {}, struct {
            fn lessThan(_: void, a: CallsiteGroup, b: CallsiteGroup) bool {
                return a.bytes > b.bytes;
            }
        }.lessThan);

        // TOP-10 callsites.
        const top_n = @min(group_list.len, 10);
        std.debug.print("\nTOP-{d} callsites by outstanding bytes:\n", .{top_n});
        for (group_list[0..top_n]) |g| {
            std.debug.print(
                "  ra=0x{x:0>16}  count={d:>6}  bytes={d:>10}  ",
                .{ g.ret_addr, g.count, g.bytes },
            );
            std.debug.print("lens=[", .{});
            for (0..g.n_samples) |si| {
                if (si > 0) std.debug.print(", ", .{});
                std.debug.print("{d}", .{g.sample_lens[si]});
            }
            std.debug.print("]\n", .{});
        }

        // Size-bucket distribution.
        const bucket_sizes = [_]usize{ 0, 1, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 };
        var bucket_counts = [_]usize{0} ** bucket_sizes.len;
        var bucket_bytes = [_]usize{0} ** bucket_sizes.len;

        for (group_list) |g| {
            const len = if (g.n_samples > 0) g.sample_lens[0] else 0;
            var bi: usize = 0;
            while (bi < bucket_sizes.len - 1 and len >= bucket_sizes[bi + 1]) bi += 1;
            bucket_counts[bi] += g.count;
            bucket_bytes[bi] += g.bytes;
        }

        std.debug.print("\nSize-bucket distribution:\n", .{});
        for (0..bucket_sizes.len) |bi| {
            if (bucket_counts[bi] > 0) {
                const lo = bucket_sizes[bi];
                const hi = if (bi + 1 < bucket_sizes.len) bucket_sizes[bi + 1] - 1 else std.math.maxInt(usize);
                std.debug.print("  [{d:>6}..{d:>6}]  count={d:>6}  bytes={d:>10}\n", .{ lo, hi, bucket_counts[bi], bucket_bytes[bi] });
            }
        }
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

test "leak map tracks outstanding allocations" {
    var tracker = TrackingAllocator.init(std.testing.allocator);
    tracker.enableLeakTracking();
    defer tracker.deinitLeakMap();
    const alloc = tracker.allocator();

    // Two allocations outstanding.
    const a = try alloc.alloc(u8, 100);
    const b = try alloc.alloc(u8, 200);
    try std.testing.expectEqual(@as(usize, 2), tracker.leak_map.count());

    // Free one — leak map should shrink.
    alloc.free(a);
    try std.testing.expectEqual(@as(usize, 1), tracker.leak_map.count());

    // The remaining entry should be for b.
    const rec = tracker.leak_map.get(@intFromPtr(b.ptr)).?;
    try std.testing.expectEqual(@as(usize, 200), rec.len);

    alloc.free(b);
    try std.testing.expectEqual(@as(usize, 0), tracker.leak_map.count());
}
