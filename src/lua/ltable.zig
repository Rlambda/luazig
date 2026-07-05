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

pub const Node = struct {
    key: Value = .Nil, // .Nil marks a free slot (Nil cannot be a Lua table key)
    value: Value = .Nil,
    // Chain link: the next node in this bucket's chain, or null at chain end.
    // PUC stores this as an integer offset (`gnext`); we use a pointer for
    // readability — switch to i32 only if a perf measurement demands it.
    next: ?*Node = null,

    pub fn isEmpty(self: *const Node) bool {
        return self.key == .Nil;
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

// Look up `key` in a hash part. Returns the matching node, or null if absent.
// Walks the chain from the main position (PUC getgeneric/getintfromhash).
pub fn nodeLookup(nodes: []Node, key: Value, seed: u64) ?*Node {
    if (nodes.len == 0) return null;
    var n: *Node = &nodes[mainPosition(nodes.len, key, seed)];
    if (n.isEmpty()) return null; // bucket unused => key not present
    while (true) {
        if (keyEq(n.key, key)) return n;
        n = n.next orelse return null;
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
    const mp_idx = mainPosition(nodes.len, key, seed);
    const mp: *Node = &nodes[mp_idx];
    if (mp.isEmpty()) {
        mp.key = key;
        mp.value = value;
        mp.next = null;
        return mp;
    }
    // Main position occupied. Decide Brent evict vs chain-append.
    const free = getFreePos(nodes, lastfree) orelse return null;
    const other_idx = mainPosition(nodes.len, mp.key, seed);
    if (other_idx != mp_idx) {
        // The occupant of `mp` is foreign (its own main position is `other`).
        // Evict it: move its contents to `free`, relink its predecessor to free,
        // then place the new key at its rightful main position `mp`.
        var prev: *Node = &nodes[other_idx];
        while (prev.next != mp) prev = prev.next.?;
        free.* = .{ .key = mp.key, .value = mp.value, .next = mp.next };
        prev.next = free;
        mp.* = .{ .key = key, .value = value, .next = null };
        return mp;
    } else {
        // The occupant belongs here (same main position). Append the new key to
        // the chain: it goes into `free`, linked after `mp`.
        free.* = .{ .key = key, .value = value, .next = mp.next };
        mp.next = free;
        return free;
    }
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
