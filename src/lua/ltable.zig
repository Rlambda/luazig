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
const BuiltinId = vm.BuiltinId;

/// Type tag for a Node's key. `empty` marks a free slot (no key); `dead`
/// marks a key whose GC-collectable payload must not be dereferenced
/// (chain continuity only). The remaining variants mirror the subset of
/// `Value` variants that can legally appear as a Lua table key (Nil cannot
/// be a key — encoded as `empty`).
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
    /// PUC Lua allows C functions (and Lua functions, threads, tables, etc.)
    /// as table keys — they hash by pointer and compare by identity. Our
    /// `Builtin` Value variant is the analog of a PUC `lua_Cfunction`: a
    /// first-class function value that must round-trip through table keys.
    /// The enum tag (not a pointer) is the hashable identity here.
    builtin,
    /// PUC LUA_TLIGHTUSERDATA as a table key: a plain C pointer that hashes
    /// by its address and compares by identity. Light userdata is NOT
    /// garbage-collected, so a node with this key tag can never become a
    /// dead key — the pointer is always valid (though it may point to
    /// freed memory if the host program mismanages it; that's the caller's
    /// responsibility, same as PUC).
    lightuserdata,
    /// PUC LUA_TUSERDATA as a table key: a full GC-managed userdata object.
    /// Hashes by pointer identity (PUC `hashpointer`), same as table/closure/
    /// thread keys. Can become a dead key if the userdata is collected while
    /// the table entry survives (PUC `LUA_TDEADKEY` transition).
    userdata,
};

/// Bare 8-byte payload union used inside Node alongside a `NodeKeyTag`.
/// This is intentionally NOT a Zig `union(enum)` — saving the inline tag is
/// the whole point (the tag lives separately in `Node.key_tt`). Mirrors PUC
/// `Value` (lobject.h:49) which is also a tagless C union paired with `lu_byte
/// tt_` in the enclosing struct. `extern union` guarantees the C-compatible
/// 8-byte layout with no hidden fields.
///
/// All fields are 8-byte-aligned (i64/f64/pointers) or 1-byte (`bool_val`,
/// `builtin: BuiltinId` where BuiltinId is a u8-backed enum). The union's
/// size is governed by the largest field, so adding `builtin` does not grow
/// the union beyond 8 bytes — keeping `@sizeOf(Node) == 32`.
const NodeKeyPayload = extern union {
    int: i64,
    num: f64,
    string: *LuaString,
    table: *Table,
    closure: *Closure,
    thread: *Thread,
    bool_val: bool,
    builtin: BuiltinId,
    lightuserdata: ?*anyopaque,
    userdata: *vm.Userdata,
};

/// PUC-faithful compact Node for hash tables. Field layout:
///   value       Value           (16 B) — full tagged value (PUC's TValue i_val)
///   key_val     NodeKeyPayload  (8 B)  — bare payload (PUC's `Value key_val`)
///   next_offset i32             (4 B)  — signed chain link (PUC's `int next`)
///   key_tt      NodeKeyTag      (1 B)  — key type tag (PUC's `lu_byte key_tt`)
///   padding                     (3 B)
/// Total: 32 B → two full Nodes per 64-byte cache line (was 1 at 48 B).
///
/// Dead keys (GC'd string keys in live-deleted nodes) are marked by
/// `key_tt = .dead`; the payload is cleared so the GC can't follow a stale
/// pointer. Chain position (`next_offset`) is preserved so `nodeLookup` can
/// still walk past them — mirrors PUC's `LUA_TDEADKEY` (lobject.h:24).
///
/// We do NOT cache the hash in the node (PUC doesn't either — ltable.c calls
/// `hashint`/`hashstr`/`hashpointer`/`hashboolean` at each use site). The
/// per-VM `seed` is threaded through `nodeLookup`/`nodeInsert`/`rawHash`.
pub const Node = struct {
    // Field order chosen for natural 8-byte alignment of Value and
    // NodeKeyPayload. After value (offset 0..16), key_val at 16..24,
    // next_offset at 24..28, key_tt at 28, padding 29..32.
    value: Value = .Nil,
    key_val: NodeKeyPayload = .{ .int = 0 },
    next_offset: i32 = 0,
    key_tt: NodeKeyTag = .empty,

    /// A node is "free" if it has no key. (Nil cannot be a Lua table key, so
    /// there is no conflicting "Nil key" state.) Dead keys are NOT empty —
    /// they preserve chain continuity.
    pub fn isEmpty(self: *const Node) bool {
        return self.key_tt == .empty;
    }

    pub fn isDeadKey(self: *const Node) bool {
        return self.key_tt == .dead;
    }

    /// Mark this node's key as dead. The payload is cleared so the GC can
    /// never follow a stale pointer; only the chain position (governed by
    /// `next_offset`) is preserved, which is all that `nodeLookup` needs to
    /// walk past this node. Matches PUC's `clearkey` (ltable.c) which sets
    /// `gval(n).tt = LUA_TDEADKEY` and leaves the node in place.
    pub fn markDeadKey(self: *Node) void {
        self.key_tt = .dead;
        self.key_val = .{ .int = 0 };
    }

    /// Compute the hash of this node's key from `key_tt` + `key_val`. Called
    /// inline at lookup/insert sites — we do NOT cache the hash in the node,
    /// matching PUC's design (PUC hashes at each use site via `hashint`/
    /// `hashstr`/`hashpointer`/`hashboolean`). `seed` is the per-VM random
    /// hash seed.
    pub fn rawHash(self: *const Node, seed: u64) u64 {
        return switch (self.key_tt) {
            .empty, .dead => 0,
            .int => hashInt(self.key_val.int, seed),
            .num => hashNum(self.key_val.num, seed),
            .string => self.key_val.string.hash,
            .table => hashPointer(@intFromPtr(self.key_val.table), seed),
            .closure => hashPointer(@intFromPtr(self.key_val.closure), seed),
            .thread => hashPointer(@intFromPtr(self.key_val.thread), seed),
            .bool_ => if (self.key_val.bool_val) 1 else 0,
            // Builtins have no pointer identity; hash the enum tag, which is
            // the stable identity of the function (PUC's `hashpointer` for the
            // C-function case is the analog: a stable, per-function value).
            .builtin => hashPointer(@intFromEnum(self.key_val.builtin), seed),
            // Light userdata hashes by its raw pointer address (PUC's
            // `hashpointer`). The pointer is the identity.
            .lightuserdata => hashPointer(@intFromPtr(self.key_val.lightuserdata), seed),
            // Full userdata hashes by pointer identity (PUC `hashpointer`),
            // same as table/closure/thread keys.
            .userdata => hashPointer(@intFromPtr(self.key_val.userdata), seed),
        };
    }

    /// Follow the chain link. Returns null at end of chain. Pointer arithmetic
    /// identical to before; only the field name `next_offset` is unchanged.
    pub fn nextNode(self: *const Node, nodes: []const Node) ?*Node {
        const off = self.next_offset;
        if (off == 0) return null;
        const byte_off: isize = @intCast(@as(i64, @intCast(off)) * @sizeOf(Node));
        const self_addr: isize = @intCast(@intFromPtr(self));
        const next_addr: usize = @intCast(self_addr + byte_off);
        const next_ptr: [*]const Node = @ptrFromInt(next_addr);
        const base: usize = @intFromPtr(nodes.ptr);
        const limit: usize = base + nodes.len * @sizeOf(Node);
        if (next_addr < base or next_addr >= limit) return null;
        return @constCast(@ptrCast(next_ptr));
    }

    /// Reconstruct the key as a full `Value`. Returns `.Nil` for empty/dead
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
            .builtin => .{ .Builtin = self.key_val.builtin },
            .lightuserdata => .{ .LightUserdata = self.key_val.lightuserdata },
            .userdata => .{ .Userdata = self.key_val.userdata },
        };
    }

    /// Inline key comparison against a `Value` without reconstructing a full
    /// Value from the split `key_tt`+`key_val` representation. PUC's hot path
    /// uses the `keyeq(NODE, KEY)` macro (ltable.c:60-90) which compares tag
    /// and payload in place — no TValue is built on the way. The reconstruction
    /// via `getKey()` + `keyEq(Value, Value)` was costing ~2× the per-node
    /// work (two switches and a 16-byte on-stack Value per chain step); this
    /// method is the architectural PUC-faithful equivalent.
    ///
    /// Empty and dead slots never match (a caller looking up a real key never
    /// has `key == .Nil`, since Nil cannot be a Lua table key).
    pub fn keyMatches(self: *const Node, key: Value) bool {
        return switch (self.key_tt) {
            .empty, .dead => false,
            .int => key == .Int and self.key_val.int == key.Int,
            .num => key == .Num and self.key_val.num == key.Num,
            .string => key == .String and vm.luaStringEq(self.key_val.string, key.String),
            .table => key == .Table and self.key_val.table == key.Table,
            .closure => key == .Closure and self.key_val.closure == key.Closure,
            .thread => key == .Thread and self.key_val.thread == key.Thread,
            .bool_ => key == .Bool and self.key_val.bool_val == key.Bool,
            .builtin => key == .Builtin and self.key_val.builtin == key.Builtin,
            .lightuserdata => key == .LightUserdata and self.key_val.lightuserdata == key.LightUserdata,
            .userdata => key == .Userdata and self.key_val.userdata == key.Userdata,
        };
    }

    /// Store `key` into this node, splitting it into tag + payload. The
    /// caller is responsible for setting `next_offset` and (for empty slots)
    /// clearing the payload if desired.
    pub fn setKey(self: *Node, key: Value) void {
        switch (key) {
            .Nil => {
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
            .Builtin => |b| {
                self.key_tt = .builtin;
                self.key_val = .{ .builtin = b };
            },
            .LightUserdata => |p| {
                self.key_tt = .lightuserdata;
                self.key_val = .{ .lightuserdata = p };
            },
            .Userdata => |u| {
                self.key_tt = .userdata;
                self.key_val = .{ .userdata = u };
            },
        }
    }
};

comptime {
    // PUC-faithful 32-byte Node: two full nodes per 64-byte cache line.
    // Value (16) + NodeKeyPayload (8) + i32 (4) + u8 (1) + padding (3) = 32.
    if (@sizeOf(Node) != 32) {
        @compileError("expected Node to be 32 bytes, got " ++ std.fmt.comptimePrint("{d}", .{@sizeOf(Node)}));
    }
}

// Hash a table key (PUC hashint/hashstr/hashpointer/hashboolean/hashnum),
// seeded by the per-VM random seed. Strings use their cached LuaString.hash
// (which already incorporates the seed); ints/floats/pointers hash directly.
// Float hashing via raw-bit wyhash matches Node.rawHash — both must agree
// for Brent's variation to maintain its chain invariant.
pub inline fn keyHash(key: Value, seed: u64) u64 {
    return switch (key) {
        .Int => |i| hashInt(i, seed),
        .Num => |n| hashNum(n, seed),
        .String => |s| s.hash,
        .Table => |t| hashPointer(@intFromPtr(t), seed),
        .Closure => |c| hashPointer(@intFromPtr(c), seed),
        .Thread => |th| hashPointer(@intFromPtr(th), seed),
        .Bool => |b| if (b) 1 else 0,
        // Builtins hash by their enum tag — must match `Node.rawHash(.builtin)`
        // so a key inserted via `keyHash` is found by `rawHash` at lookup time.
        .Builtin => |b| hashPointer(@intFromEnum(b), seed),
        // Light userdata hashes by its raw pointer address (PUC's
        // `hashpointer`). The pointer IS the identity.
        .LightUserdata => |p| hashPointer(@intFromPtr(p), seed),
        // Full userdata hashes by pointer identity (PUC `hashpointer`).
        .Userdata => |u| hashPointer(@intFromPtr(u), seed),
        else => 0,
    };
}

/// Fast seeded hash for integer keys.
///
/// PUC Lua uses `ui % ((sizenode-1) | 1)` — a simple modulo by an odd number.
/// We use a multiply-based hash instead because our hash parts are power-of-2
/// sized (masking, not modulo), and sequential integers need bit scrambling
/// to avoid collisions. The golden-ratio multiplier provides excellent
/// distribution in a single multiply (1 instruction vs Wyhash's ~10+).
fn hashInt(i: i64, seed: u64) u64 {
    const x = @as(u64, @bitCast(i)) ^ seed;
    return x *% 0x9E3779B97F4A7C15;
}

/// Fast seeded hash for float keys. PUC reinterprets f64 bits as i64 and
/// hashes via hashint; we do the same.
fn hashNum(n: f64, seed: u64) u64 {
    return hashInt(@bitCast(n), seed);
}

/// Fast seeded hash for pointer keys. Same multiply-based approach as
/// hashInt — pointers are already well-distributed, so a single multiply
/// with the seed provides enough scrambling.
fn hashPointer(addr: usize, seed: u64) u64 {
    const x = @as(u64, addr) ^ seed;
    return x *% 0x9E3779B97F4A7C15;
}

// Key equality for table lookup. Mirrors which keys collide "as equal" in PUC.
// For strings this is luaStringEq (short pointer-eq, long content-eq).
pub fn keyEq(a: Value, b: Value) bool {
    if (a == .String and b == .String) return vm.luaStringEq(a.String, b.String);
    return std.meta.eql(a, b);
}

// Main position (home bucket) for `key` in a hash part of `len` nodes. `len`
// must be a power of two; PUC hashes by `& (len-1)` for pow2 sizes (ltable.c:106).
pub inline fn mainPosition(len: usize, key: Value, seed: u64) usize {
    return keyHash(key, seed) & (len - 1);
}

// Look up `key` in a hash part. Returns the matching node, or null if absent.
// Walks the chain from the main position (PUC getgeneric/getintfromhash).
pub inline fn nodeLookup(nodes: []Node, key: Value, seed: u64) ?*Node {
    if (nodes.len == 0) return null;
    var n: *Node = &nodes[mainPosition(nodes.len, key, seed)];
    if (n.isEmpty()) return null; // bucket unused => key not present
    while (true) {
        // Inline comparison (Node.keyMatches) — avoids reconstructing a full
        // Value on every chain step, matching PUC's `keyeq` macro hot path.
        if (n.keyMatches(key)) return n;
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
    nodes[mp] = .{};
    nodes[mp].setKey(key);
    nodes[mp].value = .{ .Int = 70 };
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
    const h = keyHash(key, seed);
    const mp_idx: usize = h & (nodes.len - 1);
    const mp: *Node = &nodes[mp_idx];
    if (mp.isEmpty()) {
        mp.setKey(key);
        mp.value = value;
        mp.next_offset = 0;
        return mp;
    }
    // Main position occupied. Decide Brent evict vs chain-append.
    const free = getFreePos(nodes, lastfree) orelse return null;
    const free_idx: usize = (@intFromPtr(free) - @intFromPtr(nodes.ptr)) / @sizeOf(Node);
    const other_idx: usize = mp.rawHash(seed) & (nodes.len - 1);
    if (other_idx != mp_idx) {
        // The occupant of `mp` is foreign (its own main position is `other`).
        // Evict it: move its contents to `free`, relink its predecessor to free,
        // then place the new key at its rightful main position `mp`.
        var prev_idx: usize = other_idx;
        while (nodes[prev_idx].next_offset != 0) {
            const candidate: usize = @intCast(
                @as(i64, @intCast(prev_idx)) + @as(i64, @intCast(nodes[prev_idx].next_offset)),
            );
            if (candidate == mp_idx) break;
            prev_idx = candidate;
        }
        free.* = .{};
        free.setKey(mp.getKey());
        free.value = mp.value;
        free.next_offset = adjustOffset(mp.next_offset, mp_idx, free_idx);
        nodes[prev_idx].next_offset = @intCast(
            @as(i64, @intCast(free_idx)) - @as(i64, @intCast(prev_idx)),
        );
        mp.* = .{};
        mp.setKey(key);
        mp.value = value;
        mp.next_offset = 0;
        return mp;
    } else {
        // The occupant belongs here (same main position). Append the new key
        // to the chain: it goes into `free`, linked after `mp`.
        free.* = .{};
        free.setKey(key);
        free.value = value;
        free.next_offset = adjustOffset(mp.next_offset, mp_idx, free_idx);
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
    try std.testing.expect(keyEq(inserted.getKey(), key));
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

// Regression for P15.39 Task 5 bug: mixing non-integer float keys with int
// keys previously broke the Brent chain invariant because keyHash returned
// 0 for floats while Node.rawHash used hashNum. This test verifies all
// keys remain findable after the fix.
test "nodeInsert/lookup stress: mixed float and int keys findable" {
    const cap = 8;
    const nodes = try std.testing.allocator.alloc(Node, cap);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var lastfree: usize = nodes.len;

    // Insert 3 float keys (non-integer, so they go to hash part).
    const float_keys = [_]f64{ 0.5, 1.5, 2.5 };
    for (float_keys) |fk| {
        _ = nodeInsert(nodes, &lastfree, .{ .Num = fk }, .{ .Num = fk * 10 }, 0) orelse return error.UnexpectedFullHash;
    }
    // Insert 4 int keys (also hash part).
    var i: i64 = 100;
    while (i < 104) : (i += 1) {
        _ = nodeInsert(nodes, &lastfree, .{ .Int = i }, .{ .Int = i * 10 }, 0) orelse return error.UnexpectedFullHash;
    }

    // Every float key must be findable.
    for (float_keys) |fk| {
        const found = nodeLookup(nodes, .{ .Num = fk }, 0) orelse return error.FloatKeyLost;
        try std.testing.expect(found.value == .Num);
        try std.testing.expectEqual(fk * 10, found.value.Num);
    }
    // Every int key must be findable.
    i = 100;
    while (i < 104) : (i += 1) {
        const found = nodeLookup(nodes, .{ .Int = i }, 0) orelse return error.IntKeyLost;
        try std.testing.expect(found.value == .Int);
        try std.testing.expectEqual(i * 10, found.value.Int);
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
    if (node.key_tt != .string or node.value != .Nil) return;
    // PUC turns collectable keys in dead nodes into DEADKEY so the GC may
    // reclaim the object while collision-chain placement stays intact.
    // `markDeadKey` flips the tag to `.dead` and clears the payload (severing
    // the stale pointer); `next_offset` is preserved so chain structure
    // survives across GC.
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
    nodes[1] = .{};
    nodes[1].setKey(.{ .Int = 10 });
    nodes[1].value = .{ .Int = 100 };
    nodes[2] = .{};
    nodes[2].setKey(.{ .Int = 20 });
    nodes[2].value = .Nil; // deleted
    nodes[3] = .{};
    nodes[3].setKey(.{ .Int = 30 });
    nodes[3].value = .{ .Int = 300 };
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
        _ = nodeInsert(new_nodes, &lastfree, o.getKey(), o.value, seed);
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

test "Node.getKey/setKey round-trips a Builtin key" {
    // Regression for the P15.39 bug where `.Builtin` was mapped to `.empty`,
    // silently dropping the key. PUC Lua permits C functions as table keys
    // (they hash by identity and compare by equality), and our `Builtin`
    // Value variant is the analog — it must round-trip through the compact
    // Node representation just like Int/Num/String/etc.
    var n: Node = .{};
    const key: Value = .{ .Builtin = .print };
    n.setKey(key);

    // Tag must be `.builtin`, NOT `.empty` (the old bug).
    try std.testing.expectEqual(NodeKeyTag.builtin, n.key_tt);
    // Round-trip via getKey + keyEq.
    try std.testing.expect(keyEq(n.getKey(), key));
    // Inline comparison via keyMatches must agree.
    try std.testing.expect(n.keyMatches(key));
    // A different Builtin must NOT match (identity comparison).
    try std.testing.expect(!n.keyMatches(.{ .Builtin = .assert }));
    // Empty slot must not match any key (sanity for isEmpty interplay).
    var empty: Node = .{};
    try std.testing.expect(!empty.keyMatches(key));
}

test "Node.rawHash and keyHash agree for Builtin keys" {
    // Brent's variation requires that the hash used at insert time (keyHash)
    // and the hash recomputed at the home node (rawHash) are identical —
    // otherwise the "collider is in its own main position" invariant breaks.
    const seed: u64 = 0xdeadbeef;
    const b: BuiltinId = .tostring;
    var n: Node = .{};
    n.setKey(.{ .Builtin = b });
    try std.testing.expectEqual(n.rawHash(seed), keyHash(.{ .Builtin = b }, seed));
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

// =========================================================================
// PUC rehash primitives (lua-5.5.0/src/ltable.c:412-537, lobject.c:37-52)
//
// Pure functions implementing PUC Lua's table rehash algorithm: counting
// integer keys by bit-bucket, computing the optimal array-part size, and
// deciding which keys go to the array part vs. the hash part. These have
// no VM coupling — they operate on []const Value and []const Node slices
// and a standalone Counters struct. They will be called by tableRehash/
// tableResize in vm.zig (Task 3) to decide the new array size before
// rehashing.
// =========================================================================

/// MAXABITS: largest integer such that 2^MAXABITS fits in an `unsigned int`.
/// PUC defines this as `l_numbits(int) - 1` = `sizeof(int) * 8 - 1` = 31
/// (ltable.c:70). This bounds the `nums` count array: `nums[0..MAXABITS]`
/// covers all power-of-two slices up to 2^31 = MAXASIZE.
pub const MAXABITS: usize = 31;

/// MAXASIZE: maximum size of the array part. PUC defines this as
/// `1 << MAXABITS` = 2^31 (ltable.c:84-85), the largest power-of-two array
/// size that fits in an `unsigned int`. Integer keys in `[1, MAXASIZE]` are
/// candidates for the array part; everything else goes to the hash part.
pub const MAXASIZE: u32 = 1 << MAXABITS;

/// Computes ceil(log2(x)) — the smallest integer n such that x <= (1 << n).
/// PUC `luaO_ceillog2` (lobject.c:37-52) uses a 256-entry lookup table with
/// byte-wise reduction. We use `@clz` (count leading zeros) for the
/// Zig-native equivalent: for x >= 1, `32 - @clz(x - 1)` gives the same
/// result because `@clz(x-1)` counts the leading zeros of `x-1`, and
/// `32 - @clz` gives the bit-length of `x-1`, which equals ceil(log2(x)).
///
/// For x == 0, the mathematical definition gives 0 (0 <= 1 = 1<<0). PUC's
/// raw C implementation underflows on `x--` and returns 32, but PUC never
/// calls `luaO_ceillog2(0)` in the rehash path — `countint` guards with
/// `k != 0`, and `ltable.c:1242` explicitly checks `asize > 0` first.
pub fn ceilLog2(x: u32) u8 {
    if (x == 0) return 0;
    return @intCast(32 - @clz(x - 1));
}

/// Return the index `k` if it is in `[1, MAXASIZE]`, else 0.
/// PUC `arrayindex` / `checkrange` (ltable.c:310-319): converts the signed
/// Lua integer to unsigned, then checks `k - 1 < limit` (i.e., `1 <= k <= limit`).
/// Keys outside this range cannot go in the array part and must live in the
/// hash part.
pub fn arrayIndex(k: i64) u32 {
    // PUC checkrange: (l_castS2U(k) - 1u < limit) ? cast_uint(k) : 0.
    // For k <= 0, the unsigned subtraction underflows to a huge value >= limit → 0.
    // For k >= 1, checks k-1 < MAXASIZE, i.e., 1 <= k <= MAXASIZE.
    if (k < 1) return 0;
    if (k > MAXASIZE) return 0;
    return @intCast(k);
}

/// Counters for the rehash algorithm. PUC `Counters` (ltable.c:421-426).
///
/// `nums[i]` is the number of integer keys in the half-open interval
/// `(2^(i-1), 2^i]` (i.e., keys k where `ceilLog2(k) == i`). `na` is the
/// total number of array-index candidates. `total` is the total number of
/// non-deleted entries. `deleted` is 1 if any deleted entry was found in
/// the hash part (triggers compaction).
pub const Counters = struct {
    nums: [MAXABITS + 1]u32 = [_]u32{0} ** (MAXABITS + 1),
    na: u32 = 0,
    total: u32 = 0,
    deleted: u32 = 0,
};

/// If `key` is a valid array index, count it into `ct.nums[ceilLog2(k)]`
/// and increment `ct.na`. PUC `countint` (ltable.c:470-476).
///
/// This is used both for array-part entries (via `numUseArray`, which counts
/// them directly) and for hash-part integer keys (via `numUseHash`). The
/// bit-bucket assignment determines which power-of-two slice the key belongs
/// to, which `computeSizes` uses to find the optimal array size.
pub fn countInt(key: i64, ct: *Counters) void {
    const k = arrayIndex(key);
    if (k != 0) {
        ct.nums[ceilLog2(k)] += 1;
        ct.na += 1;
    }
}

/// Count live keys in the array part by bit-bucket. PUC `numusearray`
/// (ltable.c:488-513).
///
/// Traverses each power-of-two slice `(2^(lg-1), 2^lg]` of the array
/// (1-based PUC indices), counting non-empty slots into `ct.nums[lg]`.
/// A slot is "empty" if it holds `.Nil` (PUC `arraykeyisempty` checks the
/// tag byte; our array part uses `Value == .Nil` for the same purpose).
/// Updates `ct.na` (array-index count) and `ct.total` (live entry count).
pub fn numUseArray(array: []const Value, ct: *Counters) void {
    var lg: usize = 0;
    var ttlg: u32 = 1; // 2^lg
    var ause: u32 = 0;
    var i: u32 = 1; // 1-based PUC index
    const asize: u32 = @intCast(array.len);
    while (lg <= MAXABITS) : ({ lg += 1; ttlg *%= 2; }) {
        var lc: u32 = 0;
        var lim = ttlg;
        if (lim > asize) {
            lim = asize;
            if (i > lim) break; // no more elements to count
        }
        // Count live entries in range (2^(lg-1), 2^lg], i.e., indices i..=lim.
        // Array is 0-indexed; PUC index i corresponds to array[i-1].
        while (i <= lim) : (i += 1) {
            if (array[i - 1] != .Nil) lc += 1;
        }
        ct.nums[lg] += lc;
        ause += lc;
    }
    ct.total += ause;
    ct.na += ause;
}

/// Count keys in the hash part. PUC `numusehash` (ltable.c:521-537).
///
/// A node with `value == .Nil` is a deleted entry — sets `ct.deleted = 1`.
/// Live integer keys are counted via `countInt` (they may go to the array
/// part after rehash). Other live keys (strings, floats, etc.) increment
/// `total` but not `na`. Updates `ct.total`.
///
/// PUC's comment: "As this only happens during a rehash, all nodes have been
/// used. A node can have a nil value only if it was deleted after being
/// created." We check `value == .Nil` for deleted entries, matching PUC's
/// `isempty(gval(n))`.
pub fn numUseHash(hash: []const Node, ct: *Counters) void {
    var i: usize = hash.len;
    var total: u32 = 0;
    while (i > 0) {
        i -= 1;
        const n = &hash[i];
        if (n.key_tt == .empty or n.key_tt == .dead) continue; // unused slot
        if (n.value == .Nil) {
            // Deleted entry: key is present but value is nil.
            ct.deleted = 1;
        } else {
            total += 1;
            if (n.key_tt == .int) {
                countInt(n.key_val.int, ct);
            }
        }
    }
    ct.total += total;
}

/// Returns true if `na` array entries use less-or-equal memory than `nh`
/// hash nodes. PUC `arrayXhash` (ltable.c:435).
///
/// A hash node uses ~3 times more memory than an array entry (two Values
/// plus a chain link vs. one Value), so it's worth moving `na` entries to
/// the array part only if `na <= nh * 3`. Evaluated with `usize` to avoid
/// overflow, matching PUC's `cast_sizet`.
pub fn arrayXhash(na: u32, nh: u32) bool {
    return @as(usize, na) <= @as(usize, nh) * 3;
}

/// Compute the optimal array size. PUC `computesizes` (ltable.c:446-467).
///
/// Maximizes the number of elements going to the array part while satisfying
/// `arrayXhash` (the memory tradeoff predicate). Traverses each power-of-two
/// candidate `twotoi = 2^i`, accumulating the count of array-index candidates
/// in slices `[1, twotoi]` into `a`. If `a` entries in an array of size
/// `twotoi` still satisfy `arrayXhash(twotoi, a)`, this size is optimal so far.
///
/// `ct.na` enters with the total number of array-index candidates and leaves
/// with the number that will actually go to the array part. Returns the
/// optimal size (a power of 2, or 0 if no array part is worthwhile).
pub fn computeSizes(ct: *Counters) u32 {
    var i: usize = 0;
    var twotoi: u32 = 1; // 2^i (candidate for optimal size)
    var a: u32 = 0; // number of elements in slices [1, twotoi]
    var na: u32 = 0; // number of elements to go to array part
    var optimal: u32 = 0;
    // Traverse slices while 'twotoi' does not overflow (wraps to 0 via *%= 2)
    // and total array indices still satisfy arrayXhash against the array size.
    while (twotoi > 0 and arrayXhash(twotoi, ct.na)) {
        const nums = ct.nums[i];
        a += nums;
        // Grow array only if this slice has elements AND the accumulated
        // count still satisfies the memory tradeoff for size 'twotoi'.
        if (nums > 0 and arrayXhash(twotoi, a)) {
            optimal = twotoi;
            na = a;
        }
        i += 1;
        twotoi *%= 2; // wrapping multiply: detects overflow (twotoi > 0 guard)
    }
    ct.na = na;
    return optimal;
}

test "ceilLog2: PUC luaO_ceillog2 reference values" {
    // ceilLog2(x) = smallest n such that x <= (1 << n).
    // PUC lobject.c:37 — table-based; we use @clz for the Zig-native equivalent.
    try std.testing.expectEqual(@as(u8, 0), ceilLog2(0));
    try std.testing.expectEqual(@as(u8, 0), ceilLog2(1));
    try std.testing.expectEqual(@as(u8, 1), ceilLog2(2));
    try std.testing.expectEqual(@as(u8, 2), ceilLog2(3));
    try std.testing.expectEqual(@as(u8, 2), ceilLog2(4));
    try std.testing.expectEqual(@as(u8, 3), ceilLog2(5));
    try std.testing.expectEqual(@as(u8, 8), ceilLog2(255));
    try std.testing.expectEqual(@as(u8, 8), ceilLog2(256));
    try std.testing.expectEqual(@as(u8, 9), ceilLog2(257));
    try std.testing.expectEqual(@as(u8, 30), ceilLog2(@as(u32, 1) << 30));
}

test "arrayIndex: PUC checkrange with MAXASIZE" {
    // arrayIndex(k) = k if 1 <= k <= MAXASIZE, else 0.
    // PUC ltable.c:319 — checkrange(k, MAXASIZE).
    try std.testing.expectEqual(@as(u32, 0), arrayIndex(0));
    try std.testing.expectEqual(@as(u32, 1), arrayIndex(1));
    try std.testing.expectEqual(@as(u32, 0), arrayIndex(-1));
    try std.testing.expectEqual(@as(u32, 100), arrayIndex(100));
    try std.testing.expectEqual(@as(u32, 0), arrayIndex(std.math.maxInt(i64)));
}

test "countInt: counts integer keys into bit-buckets" {
    // countInt(key, ct) — PUC ltable.c:470.
    // If key is a valid array index, increments nums[ceilLog2(k)] and na.
    var ct = Counters{};
    countInt(1, &ct);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[0]); // ceilLog2(1)=0
    countInt(2, &ct);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[1]); // ceilLog2(2)=1
    countInt(3, &ct);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[2]); // ceilLog2(3)=2
    countInt(5, &ct);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[3]); // ceilLog2(5)=3
    // Negative key is not an array index — no change.
    countInt(-1, &ct);
    try std.testing.expectEqual(@as(u32, 4), ct.na);
}

test "numUseArray: counts live entries by bit-bucket" {
    // numUseArray(array, ct) — PUC ltable.c:488.
    // [10,20,nil,40] → nums[0]=1, nums[1]=1, nums[2]=1, na=3, total=3.
    var ct = Counters{};
    const array = [_]Value{
        .{ .Int = 10 },
        .{ .Int = 20 },
        .Nil,
        .{ .Int = 40 },
    };
    numUseArray(&array, &ct);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[0]);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[1]);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[2]);
    try std.testing.expectEqual(@as(u32, 3), ct.na);
    try std.testing.expectEqual(@as(u32, 3), ct.total);
}

test "numUseHash: counts live keys, marks deleted" {
    // numUseHash(hash, ct) — PUC ltable.c:521.
    // hash with int keys 5,100,129 + delete 100:
    //   total=2, deleted=1, nums[3]=1 (key 5), nums[8]=1 (key 129).
    var ct = Counters{};
    var nodes: [3]Node = undefined;
    for (&nodes) |*n| n.* = .{};

    // Key 5 — live.
    nodes[0].setKey(.{ .Int = 5 });
    nodes[0].value = .{ .Int = 50 };
    // Key 100 — deleted (value == .Nil).
    nodes[1].setKey(.{ .Int = 100 });
    nodes[1].value = .Nil;
    // Key 129 — live.
    nodes[2].setKey(.{ .Int = 129 });
    nodes[2].value = .{ .Int = 1290 };

    numUseHash(&nodes, &ct);
    try std.testing.expectEqual(@as(u32, 2), ct.total);
    try std.testing.expectEqual(@as(u32, 1), ct.deleted);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[3]); // ceilLog2(5)=3
    try std.testing.expectEqual(@as(u32, 1), ct.nums[8]); // ceilLog2(129)=8
}

test "arrayXhash: memory tradeoff predicate" {
    // arrayXhash(na, nh) — PUC ltable.c:435.
    // Returns true if na <= nh * 3 (array entries use ~3x less memory).
    try std.testing.expect(arrayXhash(3, 1)); // 3 <= 3
    try std.testing.expect(!arrayXhash(4, 1)); // 4 > 3
    try std.testing.expect(arrayXhash(0, 0)); // 0 <= 0
    try std.testing.expect(arrayXhash(100, 34)); // 100 <= 102
    try std.testing.expect(!arrayXhash(100, 33)); // 100 > 99
}

test "computeSizes: keys 1-100 → asize=128" {
    // computeSizes(ct) — PUC ltable.c:446.
    // All 100 keys are array indices; optimal array size is 128.
    var ct = Counters{};
    var k: i64 = 1;
    while (k <= 100) : (k += 1) {
        countInt(k, &ct);
    }
    try std.testing.expectEqual(@as(u32, 100), ct.na);
    const asize = computeSizes(&ct);
    try std.testing.expectEqual(@as(u32, 128), asize);
    try std.testing.expectEqual(@as(u32, 100), ct.na); // all go to array
}

test "computeSizes: nextvar.lua:41 scenario → asize=4" {
    // The critical nextvar.lua:41 scenario:
    //   Keys 1,2,3,4 → nums[0]=1, nums[1]=1, nums[2]=2
    //   Keys 96-100  → nums[7]=5
    //   Key 129      → nums[8]=1
    //   ct.na = 10, ct.total = 10
    //   computeSizes returns 4 (keys 1-4 go to array, rest to hash).
    var ct = Counters{};
    // Keys 1,2,3,4 in array.
    countInt(1, &ct);
    countInt(2, &ct);
    countInt(3, &ct);
    countInt(4, &ct);
    // Keys 96,97,98,99,100 in array.
    countInt(96, &ct);
    countInt(97, &ct);
    countInt(98, &ct);
    countInt(99, &ct);
    countInt(100, &ct);
    // Key 129 in hash.
    countInt(129, &ct);

    try std.testing.expectEqual(@as(u32, 10), ct.na);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[0]); // key 1
    try std.testing.expectEqual(@as(u32, 1), ct.nums[1]); // key 2
    try std.testing.expectEqual(@as(u32, 2), ct.nums[2]); // keys 3,4
    try std.testing.expectEqual(@as(u32, 5), ct.nums[7]); // keys 96-100
    try std.testing.expectEqual(@as(u32, 1), ct.nums[8]); // key 129

    const asize = computeSizes(&ct);
    try std.testing.expectEqual(@as(u32, 4), asize);
    try std.testing.expectEqual(@as(u32, 4), ct.na); // only 4 go to array
}

test "nextvar.lua:41 full scenario: array + hash → computeSizes returns 4" {
    // End-to-end: populate Counters via numUseArray + numUseHash, then
    // call computeSizes. Verifies the counting functions and the size
    // computation work together for the nextvar.lua:41 scenario.
    var ct = Counters{};

    // Array part: keys 1-4 and 96-100 (PUC indices 1,2,3,4,96,97,98,99,100).
    // Array is 0-indexed; PUC index i → array[i-1].
    var array: [100]Value = undefined;
    for (&array) |*v| v.* = .Nil;
    array[0] = .{ .Int = 1 }; // index 1
    array[1] = .{ .Int = 2 }; // index 2
    array[2] = .{ .Int = 3 }; // index 3
    array[3] = .{ .Int = 4 }; // index 4
    array[95] = .{ .Int = 96 }; // index 96
    array[96] = .{ .Int = 97 }; // index 97
    array[97] = .{ .Int = 98 }; // index 98
    array[98] = .{ .Int = 99 }; // index 99
    array[99] = .{ .Int = 100 }; // index 100

    numUseArray(&array, &ct);

    // Hash part: key 129 (live integer key).
    var nodes: [1]Node = undefined;
    nodes[0] = .{};
    nodes[0].setKey(.{ .Int = 129 });
    nodes[0].value = .{ .Int = 1290 };

    numUseHash(&nodes, &ct);

    try std.testing.expectEqual(@as(u32, 10), ct.total); // 9 array + 1 hash
    try std.testing.expectEqual(@as(u32, 10), ct.na); // all are array indices
    try std.testing.expectEqual(@as(u32, 1), ct.nums[0]);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[1]);
    try std.testing.expectEqual(@as(u32, 2), ct.nums[2]);
    try std.testing.expectEqual(@as(u32, 5), ct.nums[7]);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[8]);

    const asize = computeSizes(&ct);
    try std.testing.expectEqual(@as(u32, 4), asize);
    try std.testing.expectEqual(@as(u32, 4), ct.na);
}
