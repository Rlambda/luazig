// PUC-faithful hash table for Lua values, mirroring `lua-5.5.0/src/ltable.c`.
//
// "Hash uses a mix of chained scatter table with Brent's variation. A main
// invariant of these tables is that, if an element is not in its main position
// (i.e. the 'original' position that its hash gives to it), then the colliding
// element is in its own main position." — ltable.c:13-24
//
// Built and tested in isolation (no Vm coupling) so the algorithmic core —
// Brent's-variation insert, chain lookup, linear next(), rehash — can be
// verified before being wired into the VM's `Table`.

const std = @import("std");
const vm = @import("vm.zig");
const Value = vm.Value;
const LuaString = vm.LuaString;
const Table = vm.Table;
const Closure = vm.Closure;
const Thread = vm.Thread;

/// Flag stored in the top bit of `Node.hash` to mark a dead key (a node
/// whose key was a string that got GC'd). We steal the high bit because
/// wyhash outputs are well-distributed across all 64 bits; losing one bit
/// of hash entropy has no practical impact on collision rates in a table
/// that already handles collisions via chaining. This mirrors PUC Lua's
/// approach of reusing the key's hash slot for the DEADKEY marker
/// (ltable.c: tablekey -> setnodekey -> deadkey), letting us drop the
/// separate `dead_key: bool` field and shrink Node by 8 bytes (no bool +
/// no padding before the pointer).
///
/// IMPORTANT: because wyhash uses all 64 bits, raw hash values frequently
/// have bit 63 set. We must MASK the top bit when storing a hash into a
/// Node so that `isDeadKey()` only returns true for actual dead keys, not
/// for live keys whose hash happened to have bit 63 set. The masking is
/// applied in `nodeInsert` (the only place live-key hashes are written).
const DEAD_KEY_FLAG: u64 = 1 << 63;
const HASH_MASK: u64 = ~DEAD_KEY_FLAG;

/// Type tag for a Node's key. `empty` marks a free slot (no key); `dead`
/// marks a key whose GC-collectable payload must not be dereferenced
/// (chain continuity only). The remaining variants mirror the subset of
/// `Value` variants that can legally appear as a Lua table key (Nil cannot
/// be a key, and Builtin functions cannot be keys).
pub const NodeKeyTag = enum(u8) {
    empty,
    dead,
    int,
    num,
    string,
    table,
    closure,
    thread,
    bool_,
};

/// Bare 8-byte payload union used inside Node alongside a `NodeKeyTag`.
/// This is intentionally NOT a Zig `union(enum)` — saving the inline tag is
/// the whole point (the tag lives separately in `Node.key_tt`). Mirrors PUC
/// `Value` (lobject.h:49) which is also a tagless C union paired with `lu_byte
/// tt_` in the enclosing struct. `extern union` guarantees the C-compatible
/// 8-byte layout with no hidden fields.
const NodeKeyPayload = extern union {
    int: i64,
    num: f64,
    string: *LuaString,
    table: *Table,
    closure: *Closure,
    thread: *Thread,
    bool_val: bool,
};

pub const Node = struct {
    key: Value = .Nil, // .Nil marks a free slot (Nil cannot be a Lua table key)
    value: Value = .Nil,
    hash: u64 = 0,
    /// Chain link as a SIGNED INDEX OFFSET from this node's position in the
    /// `nodes` slice. 0 = end of chain. PUC Lua stores the same thing as
    /// `int gnext` in ltable.c (see `gnode(t, i + gnext(n))`). Using an i32
    /// offset instead of a pointer saves 4 bytes + alignment padding per
    /// node, fitting more nodes per cache line.
    next_offset: i32 = 0,
    // New fields for the upcoming layout swap (Task 5). Coexist with `key`
    // during the migration period (Tasks 1-4); Task 5 removes `key` and `hash`.
    key_tt: NodeKeyTag = .empty,
    key_val: NodeKeyPayload = .{ .int = 0 },

    pub fn isEmpty(self: *const Node) bool {
        // A node is "free" if it has no key AND is not a dead-key tombstone.
        // The dead-key flag lives in the high bit of `hash`.
        return self.key == .Nil and (self.hash & DEAD_KEY_FLAG) == 0;
    }

    pub fn isDeadKey(self: *const Node) bool {
        return (self.hash & DEAD_KEY_FLAG) != 0;
    }

    /// Mark this node's key as dead (GC'd string key). The hash value is
    /// preserved (with the dead flag OR'd in) so chain positions remain
    /// stable across GC — exactly what PUC does when it swaps the key for
    /// a DEADKEY object while keeping the node in place.
    pub fn markDeadKey(self: *Node) void {
        self.hash |= DEAD_KEY_FLAG;
    }

    /// Get the raw hash value (without the dead-key flag bit). Use this
    /// whenever recomputing main position from a node's stored hash, so
    /// the flag bit doesn't perturb the bucket index.
    pub fn rawHash(self: *const Node) u64 {
        return self.hash & ~DEAD_KEY_FLAG;
    }

    /// Follow the chain link. Returns null if this node is at the end of
    /// the chain. `nodes` is the hash part slice containing this node.
    /// Mirrors PUC's `gnext` walk: `gnode(t, i + gnext(n))`.
    pub fn nextNode(self: *const Node, nodes: []const Node) ?*Node {
        const off = self.next_offset;
        if (off == 0) return null;
        // Compute the next node's address directly from pointer arithmetic:
        // self is at nodes.ptr + self_idx * @sizeOf(Node), and the next node
        // is at nodes.ptr + (self_idx + off) * @sizeOf(Node), which equals
        // self + off * @sizeOf(Node). This avoids recovering self_idx.
        const byte_off: isize = @intCast(@as(i64, @intCast(off)) * @sizeOf(Node));
        const self_addr: isize = @intCast(@intFromPtr(self));
        const next_addr: usize = @intCast(self_addr + byte_off);
        const next_ptr: [*]const Node = @ptrFromInt(next_addr);
        // Defensive bounds check: a corrupt offset should never point outside
        // the slice. Compare as pointers to avoid recomputing indices.
        const base: usize = @intFromPtr(nodes.ptr);
        const limit: usize = base + nodes.len * @sizeOf(Node);
        if (next_addr < base or next_addr >= limit) return null;
        return @constCast(@ptrCast(next_ptr));
    }

    /// Reconstruct the key as a full `Value`. Returns `nil` for empty/dead
    /// slots (callers that care must check `isEmpty()`/`isDeadKey()` first).
    /// This is the bridge between the compact Node key representation and
    /// the rest of the VM, which works in terms of `Value`.
    pub fn getKey(self: *const Node) Value {
        return switch (self.key_tt) {
            .empty, .dead => .Nil,
            .int => .{ .Int = self.key_val.int },
            .num => .{ .Num = self.key_val.num },
            .string => .{ .String = self.key_val.string },
            .table => .{ .Table = self.key_val.table },
            .closure => .{ .Closure = self.key_val.closure },
            .thread => .{ .Thread = self.key_val.thread },
            .bool_ => .{ .Bool = self.key_val.bool_val },
        };
    }

    /// Store `key` into this node, splitting it into tag + payload. The
    /// caller is responsible for setting `next_offset` and (for empty slots)
    /// clearing the payload if desired.
    pub fn setKey(self: *Node, key: Value) void {
        switch (key) {
            .Nil => {
                // Nil cannot be a real key — used internally to mark empty
                // slots during transitions. Set tag to empty.
                self.key_tt = .empty;
                self.key_val = .{ .int = 0 };
            },
            .Bool => |b| {
                self.key_tt = .bool_;
                self.key_val = .{ .bool_val = b };
            },
            .Int => |i| {
                self.key_tt = .int;
                self.key_val = .{ .int = i };
            },
            .Num => |n| {
                self.key_tt = .num;
                self.key_val = .{ .num = n };
            },
            .String => |s| {
                self.key_tt = .string;
                self.key_val = .{ .string = s };
            },
            .Table => |t| {
                self.key_tt = .table;
                self.key_val = .{ .table = t };
            },
            .Closure => |c| {
                self.key_tt = .closure;
                self.key_val = .{ .closure = c };
            },
            .Thread => |t| {
                self.key_tt = .thread;
                self.key_val = .{ .thread = t };
            },
            .Builtin => {
                // Builtin values cannot be table keys — defensive.
                self.key_tt = .empty;
                self.key_val = .{ .int = 0 };
            },
        }
    }
};

// Hash a table key (PUC hashint/hashstr/hashpointer/hashboolean), seeded by the
// per-VM random seed. Strings use their cached LuaString.hash (which already
// incorporates the seed); ints/pointers hash directly.
pub fn keyHash(key: Value, seed: u64) u64 {
    return switch (key) {
        .Int => |i| hashInt(i, seed),
        .String => |s| s.hash,
        .Table => |t| hashPointer(@intFromPtr(t), seed),
        .Closure => |c| hashPointer(@intFromPtr(c), seed),
        .Thread => |th| hashPointer(@intFromPtr(th), seed),
        .Bool => |b| if (b) 1 else 0,
        else => 0,
    };
}

fn hashInt(i: i64, seed: u64) u64 {
    var h = std.hash.Wyhash.init(seed);
    h.update(std.mem.asBytes(&i));
    return h.final();
}

fn hashPointer(addr: usize, seed: u64) u64 {
    var h = std.hash.Wyhash.init(seed);
    h.update(std.mem.asBytes(&addr));
    return h.final();
}

// Key equality for table lookup. Mirrors which keys collide "as equal" in PUC.
// For strings this is luaStringEq (short pointer-eq, long content-eq).
pub fn keyEq(a: Value, b: Value) bool {
    if (a == .String and b == .String) return vm.luaStringEq(a.String, b.String);
    return std.meta.eql(a, b);
}

// Main position (home bucket) for `key` in a hash part of `len` nodes. `len`
// must be a power of two; PUC hashes by `& (len-1)` for pow2 sizes (ltable.c:106).
pub fn mainPosition(len: usize, key: Value, seed: u64) usize {
    return keyHash(key, seed) & (len - 1);
}

fn nodeMainPosition(len: usize, node: *const Node) usize {
    // Use rawHash() so the DEAD_KEY_FLAG bit doesn't perturb the bucket
    // index — a dead-key node must still hash to the same main position it
    // had when its key was live, so chain structure stays intact across GC.
    return node.rawHash() & (len - 1);
}

// Look up `key` in a hash part. Returns the matching node, or null if absent.
// Walks the chain from the main position (PUC getgeneric/getintfromhash).
pub fn nodeLookup(nodes: []Node, key: Value, seed: u64) ?*Node {
    if (nodes.len == 0) return null;
    var n: *Node = &nodes[mainPosition(nodes.len, key, seed)];
    if (n.isEmpty()) return null; // bucket unused => key not present
    while (true) {
        if (!n.isDeadKey() and keyEq(n.key, key)) return n;
        n = n.nextNode(nodes) orelse return null;
    }
}

test "nodeLookup returns null for empty hash part" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    try std.testing.expect(nodeLookup(nodes, .{ .Int = 7 }, 0) == null);
}

test "nodeLookup finds an inserted key at its main position" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    const key: Value = .{ .Int = 7 };
    const mp = mainPosition(nodes.len, key, 0);
    nodes[mp] = .{ .key = key, .value = .{ .Int = 70 } };
    const found = nodeLookup(nodes, key, 0).?;
    try std.testing.expectEqual(@as(i64, 70), found.value.Int);
}

// Find a free slot scanning downward from `lastfree` (PUC getfreepos). Updates
// lastfree in place; returns null if the hash part is full.
fn getFreePos(nodes: []Node, lastfree: *usize) ?*Node {
    while (lastfree.* > 0) {
        lastfree.* -= 1;
        const n = &nodes[lastfree.*];
        if (n.isEmpty()) return n;
    }
    return null;
}

// Insert (key, value) into a non-full hash part using Brent's variation
// (ltable.c:860-887 `insertkey`). Returns the node that now stores the key, or
// null if there is no free slot (caller must rehash and retry).
//
// Invariant maintained: a key not in its main position always collides with a
// key that IS in its own main position.
pub fn nodeInsert(
    nodes: []Node,
    lastfree: *usize,
    key: Value,
    value: Value,
    seed: u64,
) ?*Node {
    const h = keyHash(key, seed) & HASH_MASK; // reserve top bit for DEAD_KEY_FLAG
    const mp_idx: usize = h & (nodes.len - 1);
    const mp: *Node = &nodes[mp_idx];
    if (mp.isEmpty()) {
        mp.key = key;
        mp.value = value;
        mp.hash = h;
        mp.next_offset = 0;
        return mp;
    }
    // Main position occupied. Decide Brent evict vs chain-append.
    const free = getFreePos(nodes, lastfree) orelse return null;
    const free_idx: usize = (@intFromPtr(free) - @intFromPtr(nodes.ptr)) / @sizeOf(Node);
    const other_idx: usize = nodeMainPosition(nodes.len, mp);
    if (other_idx != mp_idx) {
        // The occupant of `mp` is foreign (its own main position is `other`).
        // Evict it: move its contents to `free`, relink its predecessor to free,
        // then place the new key at its rightful main position `mp`.
        //
        // Walk the chain from `other_idx` until we find the node whose
        // `next_offset` points to `mp_idx` (i.e. prev_idx + next_offset == mp_idx).
        // That's the predecessor we need to relink. The original PUC code does
        // the same walk with pointer comparisons: `while (prev.next != mp)`.
        var prev_idx: usize = other_idx;
        while (nodes[prev_idx].next_offset != 0) {
            const candidate: usize = @intCast(
                @as(i64, @intCast(prev_idx)) + @as(i64, @intCast(nodes[prev_idx].next_offset)),
            );
            if (candidate == mp_idx) break;
            prev_idx = candidate;
        }
        // Copy mp's state to free, adjusting the chain offset for the new
        // node position. `mp.next_offset` was relative to mp_idx; it must be
        // re-expressed relative to free_idx.
        free.* = .{
            .key = mp.key,
            .value = mp.value,
            .hash = mp.hash, // already masked (read from a Node)
            .next_offset = adjustOffset(mp.next_offset, mp_idx, free_idx),
        };
        // Relink predecessor to free (offset relative to prev_idx).
        nodes[prev_idx].next_offset = @intCast(
            @as(i64, @intCast(free_idx)) - @as(i64, @intCast(prev_idx)),
        );
        // Place new key at mp (its rightful main position), end of chain.
        mp.* = .{ .key = key, .value = value, .hash = h, .next_offset = 0 };
        return mp;
    } else {
        // The occupant belongs here (same main position). Append the new key to
        // the chain: it goes into `free`, linked after `mp`.
        free.* = .{
            .key = key,
            .value = value,
            .hash = h,
            .next_offset = adjustOffset(mp.next_offset, mp_idx, free_idx),
        };
        mp.next_offset = @intCast(@as(i64, @intCast(free_idx)) - @as(i64, @intCast(mp_idx)));
        return free;
    }
}

/// When moving a chain link from a node at `old_idx` to a node at `new_idx`,
/// the offset to the same target changes. If the old offset was `off`
/// (relative to old_idx), the new offset (relative to new_idx) is:
///   new_off = (old_idx + off) - new_idx = off + (old_idx - new_idx)
/// End-of-chain (off == 0) is preserved: a node that was last in its chain
/// is still last after being moved.
fn adjustOffset(old_offset: i32, old_idx: usize, new_idx: usize) i32 {
    if (old_offset == 0) return 0; // end of chain stays end of chain
    const old_i: i64 = @intCast(old_idx);
    const new_i: i64 = @intCast(new_idx);
    const off_i: i64 = @intCast(old_offset);
    return @intCast(off_i + (old_i - new_i));
}

test "nodeInsert places a key and nodeLookup finds it" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var lastfree: usize = nodes.len;
    const key: Value = .{ .Int = 7 };
    const inserted = nodeInsert(nodes, &lastfree, key, .{ .Int = 42 }, 0).?;
    try std.testing.expect(keyEq(inserted.key, key));
    const found = nodeLookup(nodes, key, 0).?;
    try std.testing.expectEqual(@as(i64, 42), found.value.Int);
}

// Stress: insert many distinct int keys into a small hash part and verify every
// one is findable afterward. This exercises collisions, chain-appends, and
// Brent evictions (whichever the hash distribution forces). The invariant
// "every inserted key is reachable by lookup" must hold regardless.
test "nodeInsert/lookup stress: all keys findable under collisions" {
    const cap = 8;
    const nodes = try std.testing.allocator.alloc(Node, cap);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var lastfree: usize = nodes.len;
    var i: i64 = 1;
    while (i < cap) : (i += 1) { // insert cap-1 keys (leave one free slot)
        const node = nodeInsert(nodes, &lastfree, .{ .Int = i }, .{ .Int = i * 10 }, 0) orelse {
            try std.testing.expect(false); // should not be full yet
            return;
        };
        _ = node;
    }
    // Every inserted key must be findable.
    var k: i64 = 1;
    while (k < cap) : (k += 1) {
        const found = nodeLookup(nodes, .{ .Int = k }, 0) orelse {
            try std.testing.expect(false);
            return;
        };
        try std.testing.expectEqual(k * 10, found.value.Int);
    }
}

// When the hash part is full, nodeInsert returns null (caller must rehash).
test "nodeInsert returns null when hash part is full" {
    const cap = 4;
    const nodes = try std.testing.allocator.alloc(Node, cap);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var lastfree: usize = nodes.len;
    // Fill all slots (insert keys known to spread across distinct main positions
    // is not required — once lastfree hits 0, getFreePos returns null).
    var i: i64 = 1;
    while (i <= cap) : (i += 1) {
        _ = nodeInsert(nodes, &lastfree, .{ .Int = i }, .{ .Int = i }, 0);
    }
    try std.testing.expect(lastfree == 0);
    try std.testing.expect(nodeInsert(nodes, &lastfree, .{ .Int = 999 }, .{ .Int = 999 }, 0) == null);
}

// Delete a key by setting its value to Nil (PUC 5.5 semantics, ltable.c: the
// node stays in place with its chain links intact; next()/lookup treat a
// Nil-valued node as absent). No unlinking, no tombstone counter — compaction
// happens at rehash. Returns true if the key was present (and is now deleted).
pub fn nodeDelete(nodes: []Node, key: Value, seed: u64) bool {
    const n = nodeLookup(nodes, key, seed) orelse return false;
    n.value = .Nil;
    return true;
}

pub fn deadenStringKey(node: *Node) void {
    if (node.key != .String or node.value != .Nil) return;
    // PUC turns collectable keys in dead nodes into DEADKEY so the GC may
    // reclaim the object while collision-chain placement still has a stable
    // hash. We model that by clearing the key and setting the DEAD_KEY_FLAG
    // bit in the node's stored hash — the hash value itself is preserved,
    // so main-position/chain structure stays intact across GC.
    node.key = .Nil;
    node.markDeadKey();
}

// Index of the first live (value != Nil) node at or after `start`, scanning
// nodes in memory order (PUC luaH_next hash-part loop, ltable.c:372-379).
// Returns null if there is no live node at/after `start`.
pub fn nextLiveIndex(nodes: []Node, start: usize) ?usize {
    var i: usize = start;
    while (i < nodes.len) : (i += 1) {
        if (!nodes[i].isEmpty() and nodes[i].value != .Nil) return i;
    }
    return null;
}

test "nodeDelete nils the value; lookup then sees it absent" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var lastfree: usize = nodes.len;
    const key: Value = .{ .Int = 5 };
    _ = nodeInsert(nodes, &lastfree, key, .{ .Int = 50 }, 0);
    try std.testing.expect(nodeDelete(nodes, key, 0));
    const found = nodeLookup(nodes, key, 0).?;
    try std.testing.expect(found.value == .Nil); // logically deleted
    try std.testing.expect(!nodeDelete(nodes, .{ .Int = 999 }, 0)); // absent key
}

test "nextLiveIndex scans nodes in memory order, skipping deleted/empty" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    // Place live entries at indices 1 and 3; index 2 deleted (value Nil); 0 empty.
    nodes[1] = .{ .key = .{ .Int = 10 }, .value = .{ .Int = 100 } };
    nodes[2] = .{ .key = .{ .Int = 20 }, .value = .Nil }; // deleted
    nodes[3] = .{ .key = .{ .Int = 30 }, .value = .{ .Int = 300 } };
    try std.testing.expectEqual(@as(usize, 1), nextLiveIndex(nodes, 0).?);
    try std.testing.expectEqual(@as(usize, 3), nextLiveIndex(nodes, 2).?);
    try std.testing.expect(nextLiveIndex(nodes, 4) == null); // past end
}

// Rebuild the hash part at a new (power-of-two) size, reinserting only live
// entries (dropping deleted/Nil-valued ones). PUC `reinserthash`/`luaH_resize`
// (ltable.c:637-746). Frees the old slice; returns the new one + lastfree.
pub fn rehash(
    alloc: std.mem.Allocator,
    old: []Node,
    new_len_log2: u6,
    seed: u64,
) !struct { nodes: []Node, lastfree: usize } {
    const new_len: usize = @as(usize, 1) << new_len_log2;
    const new_nodes = try alloc.alloc(Node, new_len);
    errdefer alloc.free(new_nodes);
    for (new_nodes) |*n| n.* = .{};
    var lastfree: usize = new_len;
    for (old) |*o| {
        if (o.isEmpty() or o.value == .Nil) continue; // skip free + deleted
        // new_len is chosen large enough that reinsert cannot fail.
        _ = nodeInsert(new_nodes, &lastfree, o.key, o.value, seed);
    }
    return .{ .nodes = new_nodes, .lastfree = lastfree };
}

test "Node.getKey/setKey round-trips every key type" {
    var n: Node = .{};
    const cases = [_]Value{
        .{ .Int = -123 },
        .{ .Num = 3.14 },
        .{ .Bool = true },
        .{ .Bool = false },
        // String/Table/Closure/Thread require live objects; we test Int/Num/Bool
        // exhaustively here and rely on the upstream test suite for the
        // pointer-typed keys.
    };
    for (cases) |key| {
        n.setKey(key);
        try std.testing.expect(keyEq(n.getKey(), key));
    }
}

test "rehash preserves live entries and drops deleted ones" {
    const alloc = std.testing.allocator;
    const nodes = try alloc.alloc(Node, 4);
    for (nodes) |*n| n.* = .{};
    var lastfree: usize = nodes.len;
    _ = nodeInsert(nodes, &lastfree, .{ .Int = 1 }, .{ .Int = 10 }, 0);
    _ = nodeInsert(nodes, &lastfree, .{ .Int = 2 }, .{ .Int = 20 }, 0);
    _ = nodeInsert(nodes, &lastfree, .{ .Int = 3 }, .{ .Int = 30 }, 0);
    _ = nodeDelete(nodes, .{ .Int = 2 }, 0); // delete key 2

    const r = try rehash(alloc, nodes, 3, 0); // grow to 8
    defer alloc.free(r.nodes);
    alloc.free(nodes);

    // Live keys survive.
    try std.testing.expectEqual(@as(i64, 10), nodeLookup(r.nodes, .{ .Int = 1 }, 0).?.value.Int);
    try std.testing.expectEqual(@as(i64, 30), nodeLookup(r.nodes, .{ .Int = 3 }, 0).?.value.Int);
    // Deleted key is gone (not reinserted).
    const deleted = nodeLookup(r.nodes, .{ .Int = 2 }, 0);
    try std.testing.expect(deleted == null or deleted.?.value == .Nil);
}
