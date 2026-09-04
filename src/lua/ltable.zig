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
    /// Raw GC-pointer view of the payload. All collectable key variants
    /// (string/table/closure/thread/userdata) store an 8-byte pointer at
    /// offset 0 of this extern union, so they all alias `gc_ptr`. Used ONLY
    /// for dead-key identity: after `markDeadKey` sets `key_tt = .dead`, the
    /// original variant is forgotten and the raw pointer is all that remains
    /// (PUC's `gcvalueraw(keyval(n))`, ltable.c:260). Never written directly;
    /// read only via `Node.deadKeyPtr()` on a `.dead` node. Non-collectable
    /// keys (int/num/bool/builtin/lightuserdata) never become dead keys
    /// (PUC `clearkey` checks `keyiscollectable`), so this field is never
    /// read on a node whose payload was written as a non-pointer variant.
    gc_ptr: ?*anyopaque,
};

/// PUC-faithful compact Node for hash tables. Field layout:
///   value       Value           (16 B) — full tagged value (PUC's TValue i_val)
///   key_val     NodeKeyPayload  (8 B)  — bare payload (PUC's `Value key_val`)
///   next_offset i32             (4 B)  — signed chain link (PUC's `int next`)
///   key_tt      NodeKeyTag      (1 B)  — key type tag (PUC's `lu_byte key_tt`)
///   padding                     (3 B)
/// Total: 32 B → two full Nodes per 64-byte cache line (was 1 at 48 B).
///
/// Dead keys (GC'd collectable keys in live-deleted nodes) are marked by
/// `key_tt = .dead`; the raw collectable pointer is PRESERVED in `key_val`
/// (via the `gc_ptr` union alias) so that `next()`/traversal can match a
/// live collectable key against a dead node by raw pointer identity (PUC
/// `equalkey` with deadok=1, ltable.c:258-260). The pointer is never
/// dereferenced after death — all normal lookups, GC marking, rehash, and
/// key reconstruction skip `.dead` nodes. Chain position (`next_offset`)
/// is preserved so `nodeLookup` can walk past them — mirrors PUC's
/// `LUA_TDEADKEY` (lobject.h:24).
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

    /// PUC `setdeadkey` (lobject.h:814): `keytt(node) = LUA_TDEADKEY` — ONLY
    /// the tag changes; the raw collectable pointer in `key_val` is PRESERVED.
    /// This lets `equalkey(..., deadok=1)` match a live collectable key
    /// against this dead node by raw GC-pointer identity (ltable.c:258-260).
    /// The pointer is never dereferenced after this — `.dead` nodes are
    /// skipped by all normal lookups (`keyMatches` returns false), GC marking
    /// (the table-traversal loop skips `.dead`), rehash (skips `.dead`), and
    /// key reconstruction (`getKey` returns `.Nil`). Only `deadKeyPtr()` reads
    /// the preserved pointer, and only for raw comparison (never dereference).
    ///
    /// Only collectable keys (string/table/closure/thread/userdata) can become
    /// dead keys — PUC `clearkey` (lgc.c:209-213) checks `keyiscollectable(n)`
    /// before calling `setdeadkey`. Their payloads are 8-byte pointers that
    /// alias `gc_ptr` in the extern union, so leaving `key_val` untouched
    /// preserves the raw pointer. Non-collectable keys (int/num/bool/builtin/
    /// lightuserdata) never reach here.
    pub fn markDeadKey(self: *Node) void {
        self.key_tt = .dead;
        // Do NOT touch key_val: the raw pointer is preserved for deadok
        // matching (PUC setdeadkey does not touch keyval either).
    }

    /// Raw GC pointer preserved in a dead key (PUC `gcvalueraw(keyval(n))`,
    /// ltable.c:260). Valid ONLY on `.dead` nodes. All collectable key
    /// variants alias `gc_ptr` in the extern union, so this reads the
    /// original pointer regardless of which collectable type the key was
    /// before death. The returned pointer may point to freed memory — it must
    /// NEVER be dereferenced; it is valid only for raw pointer comparison.
    pub fn deadKeyPtr(self: *const Node) ?*anyopaque {
        std.debug.assert(self.key_tt == .dead);
        return self.key_val.gc_ptr;
    }

    /// For a node with a live collectable key (string/table/closure/thread/
    /// userdata), return the raw GC pointer. Returns null for non-collectable
    /// keys (int/num/bool/builtin/lightuserdata) and for empty/dead nodes.
    /// PUC `keyiscollectable` + `gckeyN`. Used by the GC deadening pass to
    /// check key liveness (`gcIsDead`) for any collectable key type.
    pub fn collectableKeyPtr(self: *const Node) ?*anyopaque {
        return switch (self.key_tt) {
            .string => @ptrCast(self.key_val.string),
            .table => @ptrCast(self.key_val.table),
            .closure => @ptrCast(self.key_val.closure),
            .thread => @ptrCast(self.key_val.thread),
            .userdata => @ptrCast(self.key_val.userdata),
            .empty, .dead, .int, .num, .bool_, .builtin, .lightuserdata => null,
        };
    }

    /// Compute the hash of this node's key from `key_tt` + `key_val`. Called
    /// inline at lookup/insert sites — we do NOT cache the hash in the node,
    /// matching PUC's design (PUC hashes at each use site via `hashint`/
    /// `hashstr`/`hashpointer`/`hashboolean`). `seed` is the per-VM random
    /// hash seed.
    pub fn rawHash(self: *const Node, seed: u64) u64 {
        return switch (self.key_tt) {
            // Dead nodes are never re-hashed: rehash skips them (value == Nil),
            // and nodeInsert overwrites them in place. The preserved raw pointer
            // must NOT be dereferenced for hashing — it may point to freed
            // memory. Returning 0 is safe because no caller uses the result
            // for a .dead node (all paths skip .dead before hashing).
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
    ///
    /// MUST NOT be called on a `.dead` node in production paths: the payload
    /// holds a raw pointer to potentially-freed memory, and reconstructing it
    /// as a typed Value would create a dangling reference. The `.dead => .Nil`
    /// arm is a defensive fallback only; all production callers skip `.dead`
    /// nodes before reaching `getKey()`.
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
            // deadok=false: dead keys NEVER match a normal lookup. This arm
            // is FIRST so the hot path (nodeLookup) stays branch-cheap — a
            // single tag check eliminates dead nodes without inspecting the
            // payload. PUC equalkey with deadok=0 (ltable.c:252-263): the
            // `keyisdead(n2)` branch is only taken when deadok=1.
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

    /// Dead-key-aware match (PUC `equalkey` with deadok=1, ltable.c:252-282).
    /// Used ONLY by traversal (`rawNext`/`findindex`): a live collectable key
    /// matches a DEADKEY node by raw GC-pointer identity. Normal lookups must
    /// NOT use this — they use `keyMatches` (deadok=0), where `.dead => false`.
    ///
    /// PUC ltable.c:258-260:
    ///   deadok && keyisdead(n2) && iscollectable(k1)
    ///     => gcvalue(k1) == gcvalueraw(keyval(n2))
    ///
    /// For non-dead nodes, this delegates to `keyMatches` (deadok is
    /// irrelevant when the node is not dead — the same-variant comparison
    /// applies). The deadok path only adds the dead-key-by-pointer match.
    pub fn keyMatchesDeadok(self: *const Node, key: Value) bool {
        return switch (self.key_tt) {
            .dead => blk: {
                // Only a collectable key can match a dead key (PUC
                // iscollectable(k1)). Non-collectable keys (int/num/bool/
                // builtin/lightuserdata) never match a dead node.
                const kptr = gcValuePtr(key) orelse break :blk false;
                break :blk kptr == self.deadKeyPtr();
            },
            .empty => false,
            else => self.keyMatches(key),
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
// deadok=false: dead keys NEVER match (PUC getgeneric with deadok=0).
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

/// Specialized integer-key hash lookup — PUC `getintfromhash` (ltable.c:929-942).
///
/// PUC has a dedicated `getintfromhash(Table *t, lua_Integer key)` that hashes
/// via `hashint(t, key)` and walks the chain comparing ONLY `keyisinteger(n) &&
/// keyival(n) == key` — no `keyeq` macro, no `TValue` construction, no tag
/// switch per chain step. This is the Zig equivalent.
///
/// **Position-match proof vs generic path:** the generic `nodeLookup` computes
/// `mainPosition(len, .{ .Int = key }, seed)` = `keyHash(.{ .Int = key }, seed)
/// & (len - 1)` = `hashInt(key, seed) & (len - 1)`. This function computes
/// `hashInt(key, seed) & (nodes.len - 1)` — the exact same expression, using
/// the same `hashInt` function (ltable.zig:406) with the same `seed` parameter.
/// Positions match EXACTLY.
///
/// **Chain-walk equivalence:** the generic path calls `n.keyMatches(key)`,
/// which for `.int` nodes evaluates `key == .Int and self.key_val.int == key.Int`.
/// Since the caller guarantees `key` is an integer, `key == .Int` is always
/// true, so the check reduces to `self.key_val.int == key.Int` — identical to
/// this function's `n.key_val.int == key`. For `.empty`/`.dead`/other-tag
/// nodes, `n.key_tt == .int` is false, matching `keyMatches`'s `.empty, .dead
/// => false` and the tag-mismatch arms. Empty-bucket termination (`isEmpty`)
/// and chain-end termination (`nextNode orelse null`) are identical to
/// `nodeLookup`.
pub inline fn nodeLookupInt(nodes: []Node, key: i64, seed: u64) ?*Node {
    if (nodes.len == 0) return null;
    // Same hash as the generic .Int path: hashInt(key, seed) & (len-1).
    const mp: usize = hashInt(key, seed) & (nodes.len - 1);
    var n: *Node = &nodes[mp];
    if (n.isEmpty()) return null; // bucket unused => key not present
    while (true) {
        // Direct field compare — no Value construction, no tag switch.
        // PUC ltable.c:933: `if (keyisinteger(n) && keyival(n) == key)`.
        if (n.key_tt == .int and n.key_val.int == key) return n;
        n = n.nextNode(nodes) orelse return null;
    }
}

test "nodeLookupInt returns null for empty hash part" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    try std.testing.expect(nodeLookupInt(nodes, 7, 0) == null);
}

test "nodeLookupInt finds an inserted key at its main position" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    const key: i64 = 7;
    const mp: usize = hashInt(key, 0) & (nodes.len - 1);
    nodes[mp].setKey(.{ .Int = key });
    nodes[mp].value = .{ .Int = 70 };
    const found = nodeLookupInt(nodes, key, 0).?;
    try std.testing.expectEqual(@as(i64, 70), found.value.Int);
}

test "nodeLookupInt agrees with nodeLookup for int keys across a range" {
    const cap = 16;
    const nodes = try std.testing.allocator.alloc(Node, cap);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var lastfree: usize = nodes.len;
    // Insert 15 int keys (leave one free slot for chain appends).
    var i: i64 = 1;
    while (i < cap) : (i += 1) {
        _ = nodeInsert(nodes, &lastfree, .{ .Int = i }, .{ .Int = i * 10 }, 0);
    }
    // Every key must be found by BOTH paths, with identical results.
    var k: i64 = 1;
    while (k < cap) : (k += 1) {
        const generic = nodeLookup(nodes, .{ .Int = k }, 0);
        const specialized = nodeLookupInt(nodes, k, 0);
        try std.testing.expect(generic != null);
        try std.testing.expect(specialized != null);
        try std.testing.expectEqual(generic.?.value, specialized.?.value);
    }
    // Absent key: both return null.
    try std.testing.expect(nodeLookupInt(nodes, 99999, 0) == null);
}

test "nodeLookupInt skips dead keys and non-int keys in the chain" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    // Place a dead node at the main position for key 7, and a live int node
    // chained after it. nodeLookupInt must skip the dead node and find the
    // live one — same as the generic nodeLookup.
    const key: i64 = 7;
    const mp: usize = hashInt(key, 0) & (nodes.len - 1);
    nodes[mp].key_tt = .table; // non-int key at main position
    nodes[mp].key_val = .{ .table = @ptrFromInt(@as(usize, 0x1234) & ~@as(usize, @alignOf(*Table) - 1)) };
    nodes[mp].value = .Nil;
    nodes[mp].markDeadKey();
    // Chain to a free slot holding the real int key.
    const free_idx: usize = (mp + 1) % nodes.len;
    nodes[free_idx].setKey(.{ .Int = key });
    nodes[free_idx].value = .{ .Int = 42 };
    nodes[mp].next_offset = @intCast(@as(i64, @intCast(free_idx)) - @as(i64, @intCast(mp)));
    const found = nodeLookupInt(nodes, key, 0).?;
    try std.testing.expectEqual(@as(i64, 42), found.value.Int);
}

/// Specialized string-key hash lookup — PUC `getstr` (ltable.c:944-955).
///
/// PUC has a dedicated `getstr(Table *t, TString *key)` that hashes via
/// `hashstr(t, key)` (= `key->hash & (sizenode(t)-1)`, using the string's
/// **cached** hash) and walks the chain comparing ONLY `keyisshrstr(n) &&
/// keystrval(n) == key` for short strings (pointer identity) or the generic
/// `keyeq` for long strings. This is the Zig equivalent.
///
/// **Hash-source proof:** the generic `nodeLookup` computes
/// `mainPosition(len, .{ .String = key }, seed)` = `keyHash(.{ .String = key },
/// seed) & (len - 1)`. `keyHash(.{ .String = s })` returns `s.hash` directly
/// (ltable.zig:382 — the `.String => |s| s.hash` arm, no switch, no
/// computation). So the generic main position is `key.hash & (len - 1)`. This
/// function computes `key.hash & (nodes.len - 1)` — the exact same expression.
/// Positions match EXACTLY.
///
/// **Chain-walk equivalence:** the generic path calls `n.keyMatches(key)`,
/// which for `.string` nodes evaluates `key == .String and
/// vm.luaStringEq(self.key_val.string, key.String)` (ltable.zig:275). Since
/// the caller guarantees `key` is a `*LuaString`, `key == .String` is always
/// true, so the check reduces to `vm.luaStringEq(self.key_val.string, key)` —
/// identical to this function's chain compare. `luaStringEq` is pointer-eq for
/// interned short strings and content-eq for long strings (vm.zig:2055-2058),
/// so short/interned pairs hit the fast pointer-compare path while long
/// strings keep full content equality. For `.empty`/`.dead`/other-tag nodes,
/// `n.key_tt == .string` is false, matching `keyMatches`'s `.empty, .dead
/// => false` and the tag-mismatch arms. Empty-bucket termination (`isEmpty`)
/// and chain-end termination (`nextNode orelse null`) are identical to
/// `nodeLookup`.
pub inline fn nodeLookupStr(nodes: []Node, key: *LuaString) ?*Node {
    if (nodes.len == 0) return null;
    // Same hash as the generic .String path: key.hash & (len-1).
    // keyHash(.{ .String = key }) = key.hash (ltable.zig:382, no computation).
    const mp: usize = key.hash & (nodes.len - 1);
    var n: *Node = &nodes[mp];
    if (n.isEmpty()) return null; // bucket unused => key not present
    while (true) {
        // Direct string compare — no Value construction, no tag switch.
        // luaStringEq: pointer-eq for interned shorts, content-eq for longs.
        if (n.key_tt == .string and vm.luaStringEq(n.key_val.string, key)) return n;
        n = n.nextNode(nodes) orelse return null;
    }
}

test "nodeLookupStr returns null for empty hash part" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    // Build a dummy LuaString with a known hash.
    var ls: LuaString = .{ .hash = 0, .srkind = @intCast(0) };
    try std.testing.expect(nodeLookupStr(nodes, &ls) == null);
}

test "nodeLookupStr finds an interned string key at its main position" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    // Simulate an interned short string: hash is pre-cached.
    var ls: LuaString = .{ .hash = 0xDEAD_BEEF, .srkind = @intCast(3) };
    const mp: usize = ls.hash & (nodes.len - 1);
    nodes[mp].setKey(.{ .String = &ls });
    nodes[mp].value = .{ .Int = 77 };
    const found = nodeLookupStr(nodes, &ls).?;
    try std.testing.expectEqual(@as(i64, 77), found.value.Int);
}

test "nodeLookupStr agrees with nodeLookup for string keys" {
    const cap = 16;
    const nodes = try std.testing.allocator.alloc(Node, cap);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var lastfree: usize = nodes.len;
    // Insert 15 string keys (leave one free slot for chain appends).
    var keys: [15]LuaString = undefined;
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        keys[i] = .{ .hash = (i + 1) *% 0x9E3779B97F4A7C15, .srkind = @intCast(i) };
        _ = nodeInsert(nodes, &lastfree, .{ .String = &keys[i] }, .{ .Int = @intCast(i * 10) }, 0);
    }
    // Every key must be found by BOTH paths, with identical results.
    var k: usize = 0;
    while (k < 15) : (k += 1) {
        const generic = nodeLookup(nodes, .{ .String = &keys[k] }, 0);
        const specialized = nodeLookupStr(nodes, &keys[k]);
        try std.testing.expect(generic != null);
        try std.testing.expect(specialized != null);
        try std.testing.expectEqual(generic.?.value, specialized.?.value);
    }
    // Absent key: both return null.
    var absent: LuaString = .{ .hash = 0x1234_5678, .srkind = @intCast(0) };
    try std.testing.expect(nodeLookup(nodes, .{ .String = &absent }, 0) == null);
    try std.testing.expect(nodeLookupStr(nodes, &absent) == null);
}

test "nodeLookupStr skips dead keys and non-string keys in the chain" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    // Place a dead node at the main position, and a live string node chained.
    var ls: LuaString = .{ .hash = 0xCAFE_BABE, .srkind = @intCast(2) };
    const mp: usize = ls.hash & (nodes.len - 1);
    nodes[mp].key_tt = .table; // non-string key at main position
    nodes[mp].key_val = .{ .table = @ptrFromInt(@as(usize, 0x1234) & ~@as(usize, @alignOf(*Table) - 1)) };
    nodes[mp].value = .Nil;
    nodes[mp].markDeadKey();
    // Chain to a free slot holding the real string key.
    const free_idx: usize = (mp + 1) % nodes.len;
    nodes[free_idx].setKey(.{ .String = &ls });
    nodes[free_idx].value = .{ .Int = 42 };
    nodes[mp].next_offset = @intCast(@as(i64, @intCast(free_idx)) - @as(i64, @intCast(mp)));
    const found = nodeLookupStr(nodes, &ls).?;
    try std.testing.expectEqual(@as(i64, 42), found.value.Int);
}

/// Short-string POINTER-IDENTITY hash lookup — PUC `luaH_Hgetshortstr`
/// (ltable.c:975-988).
///
/// PUC's `luaH_Hgetshortstr(Table *t, TString *key)`:
///   - asserts `strisshr(key)` (key is a short/interned string)
///   - hashes via `hashstr(t, key)` = `key->hash & (sizenode(t)-1)` (cached hash)
///   - walks the chain: `if (keyisshrstr(n) && eqshrstr(keystrval(n), key))`
///     where `keyisshrstr(n)` = `keytt(n) == LUA_VSHRSTR` (node key is SHORT
///     string tag) and `eqshrstr(a,b)` = `(a) == (b)` (PURE pointer identity,
///     no content comparison, no long-string fallback)
///   - terminates when `gnext(n) == 0`
///
/// This is the PUC-faithful primitive for metamethod/metafield lookups where
/// the query key is ALWAYS a VM-interned short string (`tm_names[event]` and
/// `metafield_names[field]` — all pre-interned shorts, `kind == .short`).
/// It replaces the general `nodeLookupStr` (which dispatches to `luaStringEq`
/// — pointer-eq for shorts BUT content-eq for longs) in those hot paths.
///
/// **Precondition:** `key` must be a VM-interned short string (`key.isShort()`
/// is true). The caller (getTm/getMetaField) guarantees this via `tm_names` /
/// `metafield_names` — both arrays are populated by `internStr` which produces
/// short strings for all metamethod/metafield names (all <= 40 chars). This
/// matches PUC's `lua_assert(strisshr(key))` in `luaH_Hgetshortstr`.
///
/// **Tag mapping:** PUC has separate tags `LUA_VSHRSTR` and `LUA_VLNGSTR`. Our
/// `NodeKeyTag` has a single `.string` variant; the short/long distinction
/// lives in `LuaString.kind`. So `keyisshrstr(n)` maps to
/// `n.key_tt == .string and n.key_val.string.isShort()`. A node with a LONG
/// string key (`kind != .short`) will NOT match — matching PUC's
/// `keyisshrstr` returning false for `LUA_VLNGSTR`-tagged nodes.
///
/// **No content fallback:** unlike `nodeLookupStr` → `luaStringEq`, this
/// primitive NEVER compares string contents. If a node's key is a long string
/// with the same bytes as `key`, it is skipped (no match). This is the
/// critical invariant: the primitive is PURE pointer-identity, matching PUC's
/// `eqshrstr` exactly. See the unit test
/// "nodeLookupShortStrIdentity does NOT match same-bytes long string".
///
/// **No caching:** this function does not touch `Table.flags`. Caching
/// (cache-on-miss via flags bits) is `fastTm`'s responsibility, and ONLY for
/// events `<= .eq`. See the T5 PROHIBITION in `getTm`'s doc comment.
pub inline fn nodeLookupShortStrIdentity(nodes: []Node, key: *LuaString) ?*Node {
    // PUC luaH_Hgetshortstr lua_assert(strisshr(key)): the identity
    // precondition. Debug-only — zero ReleaseFast cost.
    std.debug.assert(key.isShort());
    if (nodes.len == 0) return null;
    // Same hash as PUC hashstr: key->hash & (sizenode-1).
    // keyHash(.{ .String = key }) = key.hash (ltable.zig:382, no computation).
    const mp: usize = key.hash & (nodes.len - 1);
    var n: *Node = &nodes[mp];
    if (n.isEmpty()) return null; // bucket unused => key not present
    while (true) {
        // PUC keyisshrstr(n) && eqshrstr(keystrval(n), key):
        //   keyisshrstr: node key is SHORT string (our .string + kind)
        //   eqshrstr:    pure pointer identity (a == b)
        // No content comparison. No long-string fallback.
        if (n.key_tt == .string and n.key_val.string.isShort() and n.key_val.string == key)
            return n;
        n = n.nextNode(nodes) orelse return null;
    }
}

test "nodeLookupShortStrIdentity returns null for empty hash part" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var ls: LuaString = .{ .hash = 0, .srkind = @intCast(0) };
    try std.testing.expect(nodeLookupShortStrIdentity(nodes, &ls) == null);
}

test "nodeLookupShortStrIdentity finds an interned short string at main position" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var ls: LuaString = .{ .hash = 0xDEAD_BEEF, .srkind = @intCast(3) };
    const mp: usize = ls.hash & (nodes.len - 1);
    nodes[mp].setKey(.{ .String = &ls });
    nodes[mp].value = .{ .Int = 77 };
    const found = nodeLookupShortStrIdentity(nodes, &ls).?;
    try std.testing.expectEqual(@as(i64, 77), found.value.Int);
}

test "nodeLookupShortStrIdentity finds short string in collision chain" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    // Two short strings hashing to the same bucket (collision).
    var ls1: LuaString = .{ .hash = 0x10, .srkind = @intCast(2) };
    var ls2: LuaString = .{ .hash = 0x10, .srkind = @intCast(2) }; // same hash, different ptr
    const mp: usize = ls1.hash & (nodes.len - 1); // = 0
    nodes[mp].setKey(.{ .String = &ls1 });
    nodes[mp].value = .{ .Int = 1 };
    const free_idx: usize = (mp + 1) % nodes.len;
    nodes[free_idx].setKey(.{ .String = &ls2 });
    nodes[free_idx].value = .{ .Int = 2 };
    nodes[mp].next_offset = @intCast(@as(i64, @intCast(free_idx)) - @as(i64, @intCast(mp)));
    // Both must be found by pointer identity.
    try std.testing.expectEqual(@as(i64, 1), nodeLookupShortStrIdentity(nodes, &ls1).?.value.Int);
    try std.testing.expectEqual(@as(i64, 2), nodeLookupShortStrIdentity(nodes, &ls2).?.value.Int);
}

test "nodeLookupShortStrIdentity returns null for absent key" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var present: LuaString = .{ .hash = 0x20, .srkind = @intCast(1) };
    var absent: LuaString = .{ .hash = 0x40, .srkind = @intCast(1) };
    const mp: usize = present.hash & (nodes.len - 1);
    nodes[mp].setKey(.{ .String = &present });
    nodes[mp].value = .{ .Int = 42 };
    try std.testing.expect(nodeLookupShortStrIdentity(nodes, &absent) == null);
}

test "nodeLookupShortStrIdentity skips dead keys and non-string keys in chain" {
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var ls: LuaString = .{ .hash = 0xCAFE_BABE, .srkind = @intCast(2) };
    const mp: usize = ls.hash & (nodes.len - 1);
    // Dead key at main position (non-string, dead).
    nodes[mp].key_tt = .table;
    nodes[mp].key_val = .{ .table = @ptrFromInt(@as(usize, 0x1234) & ~@as(usize, @alignOf(*Table) - 1)) };
    nodes[mp].value = .Nil;
    nodes[mp].markDeadKey();
    // Chain to a free slot with the real short-string key.
    const free_idx: usize = (mp + 1) % nodes.len;
    nodes[free_idx].setKey(.{ .String = &ls });
    nodes[free_idx].value = .{ .Int = 42 };
    nodes[mp].next_offset = @intCast(@as(i64, @intCast(free_idx)) - @as(i64, @intCast(mp)));
    const found = nodeLookupShortStrIdentity(nodes, &ls).?;
    try std.testing.expectEqual(@as(i64, 42), found.value.Int);
}

test "nodeLookupShortStrIdentity does NOT match same-bytes long string" {
    // CRITICAL: proves no accidental content path. A node with a LONG string
    // key (kind != .short) that collides to the same bucket as the query
    // short string must NOT match. PUC's keyisshrstr(n) returns false for
    // LUA_VLNGSTR-tagged nodes; our check n.key_val.string.kind != .short
    // achieves the same. The identity primitive is PURE pointer-identity —
    // it never compares contents, so a long-string node is always skipped.
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    // Query: short string with hash 0x10.
    var short_key: LuaString = .{ .hash = 0x10, .srkind = @intCast(3) };
    // Node: LONG string with same hash (collision) — kind != .short.
    // Even though it has the same hash and same len, the identity primitive
    // must NOT match it because kind != .short (not a short string).
    var long_key: LuaString = .{ .hash = 0x10, .srkind = LuaString.lstrreg, .u = .{ .lnglen = 3 } };
    const mp: usize = short_key.hash & (nodes.len - 1);
    nodes[mp].setKey(.{ .String = &long_key });
    nodes[mp].value = .{ .Int = 99 };
    // The identity primitive must NOT find the long-string node.
    try std.testing.expect(nodeLookupShortStrIdentity(nodes, &short_key) == null);
    // The long key itself IS found (it's a valid string node, just long —
    // the identity primitive checks isShort() on the NODE's key, not the query).
    // Wait: the query must also be short (precondition). long_key.isShort() is
    // false, so calling with &long_key violates the precondition. We only
    // test that a short query does NOT match a long node.
    //
    // For a short query against a short node at the same position, it WOULD
    // match by pointer identity. Verify that a different short pointer does
    // NOT match (pointer identity, not content):
    var other_short: LuaString = .{ .hash = 0x10, .srkind = @intCast(3) };
    try std.testing.expect(nodeLookupShortStrIdentity(nodes, &other_short) == null);
}

test "nodeLookupShortStrIdentity agrees with nodeLookupStr for valid interned-short inputs" {
    // For valid inputs (query is short, node keys are short), both primitives
    // must return identical results. This is the equivalence guarantee.
    const cap = 16;
    const nodes = try std.testing.allocator.alloc(Node, cap);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var lastfree: usize = nodes.len;
    var keys: [15]LuaString = undefined;
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        keys[i] = .{ .hash = (i + 1) *% 0x9E3779B97F4A7C15, .srkind = @intCast(i) };
        _ = nodeInsert(nodes, &lastfree, .{ .String = &keys[i] }, .{ .Int = @intCast(i * 10) }, 0);
    }
    var k: usize = 0;
    while (k < 15) : (k += 1) {
        const general = nodeLookupStr(nodes, &keys[k]);
        const identity = nodeLookupShortStrIdentity(nodes, &keys[k]);
        try std.testing.expect(general != null);
        try std.testing.expect(identity != null);
        try std.testing.expectEqual(general.?.value, identity.?.value);
    }
    // Absent key: both return null.
    var absent: LuaString = .{ .hash = 0x1234_5678, .srkind = @intCast(0) };
    try std.testing.expect(nodeLookupStr(nodes, &absent) == null);
    try std.testing.expect(nodeLookupShortStrIdentity(nodes, &absent) == null);
}

/// Raw GC pointer from a collectable Value (PUC `gcvalue(k1)`, ltable.c:260).
/// Returns null for non-collectable values (Nil/Int/Num/Bool/Builtin/
/// LightUserdata). Used by `keyMatchesDeadok` to compare a live collectable
/// key against a dead node's preserved raw pointer.
pub inline fn gcValuePtr(v: Value) ?*anyopaque {
    return switch (v) {
        .String => |s| @ptrCast(s),
        .Table => |t| @ptrCast(t),
        .Closure => |c| @ptrCast(c),
        .Thread => |t| @ptrCast(t),
        .Userdata => |u| @ptrCast(u),
        else => null,
    };
}

/// Dead-key-aware lookup (PUC `getgeneric(t, key, deadok=1)`, ltable.c:291-303).
/// Used ONLY by `rawNext`/traversal to find the node for a control key that
/// may have been collected and turned into a DEADKEY. A live collectable key
/// matches a DEADKEY node by raw GC-pointer identity (PUC equalkey deadok=1).
///
/// Normal lookups must use `nodeLookup` (deadok=0) and never match dead nodes.
/// The deadok path is safe even with a dangling key pointer: it compares raw
/// pointer values only, never dereferences them (PUC "garbage in, garbage out"
/// semantics, ltable.c:242-250).
pub inline fn nodeLookupDeadok(nodes: []Node, key: Value, seed: u64) ?*Node {
    if (nodes.len == 0) return null;
    var n: *Node = &nodes[mainPosition(nodes.len, key, seed)];
    if (n.isEmpty()) return null; // bucket unused => key not present
    while (true) {
        if (n.keyMatchesDeadok(key)) return n;
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
    // PUC `insertkey` (ltable.c:863): the main position is available for
    // direct overwrite iff its VALUE is nil/empty — NOT iff its key tag is
    // "empty". A deleted node (key still set, value == .Nil) or a dead-key
    // node (key_tt == .dead, value == .Nil) is available for overwrite, and
    // crucially its `next_offset` chain link MUST be preserved so the rest
    // of the collision chain stays reachable. The old code used `mp.isEmpty()`
    // (key-tag check) and cleared `next_offset`, which orphaned every node
    // after a deleted/dead node at the main position.
    //
    // Dead-key safety: when overwriting a .dead node, `setKey` fully replaces
    // `key_val` with the new key's payload, so the stale dead pointer is
    // completely overwritten and never read again. The preserved raw pointer
    // in the dead node is only read by `deadKeyPtr()` (deadok traversal), and
    // only while the node remains `.dead` — once overwritten, it is gone.
    if (mp.value == .Nil) {
        mp.setKey(key);
        mp.value = value;
        // Do NOT touch `next_offset`: PUC's `setnodekey`/`setobj2t`
        // (ltable.c:891-893) never modify `gnext`. The chain link from the
        // previous occupant (deleted or dead-key node) is inherited as-is.
        return mp;
    }
    // Main position occupied by a live entry. Decide Brent evict vs chain-append.
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
    // Fill all slots. When all keys hash to distinct main positions (as keys
    // 1..4 do with the golden-ratio hash), each insert places directly at its
    // main position without calling getFreePos, so lastfree is NOT decremented
    // during insertion. The final nodeInsert call will invoke getFreePos, which
    // scans all slots, finds them all occupied, and returns null.
    var i: i64 = 1;
    while (i <= cap) : (i += 1) {
        _ = nodeInsert(nodes, &lastfree, .{ .Int = i }, .{ .Int = i }, 0);
    }
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

/// PUC `clearkey` (lgc.c:209-213): turn a collectable key in a Nil-valued
/// (logically empty) hash node into a DEADKEY, preserving the raw pointer
/// for deadok traversal. Applies to ANY collectable key type (string/table/
/// closure/thread/userdata), not just strings — PUC `clearkey` checks
/// `keyiscollectable(n)`, which is true for all GC-managed key types.
/// Non-collectable keys (int/num/bool/builtin/lightuserdata) are left as-is
/// (they can never become dead keys). The node's `next_offset` chain link is
/// preserved so collision chains stay intact across GC.
pub fn clearKey(node: *Node) void {
    // Only collectable keys can become dead keys (PUC keyiscollectable).
    if (node.collectableKeyPtr() == null) return;
    // PUC clearkey asserts isempty(gval(n)) — the value must be Nil.
    // Callers (gcClearDeadKeys) ensure this; the assert documents the
    // invariant for any future caller.
    std.debug.assert(node.value == .Nil);
    node.markDeadKey();
}

// Index of the first live (value != Nil) node at or after `start`, scanning
// nodes in memory order (PUC luaH_next hash-part loop, ltable.c:372-379).
// Returns null if there is no live node at/after `start`. Dead-key nodes
// (key_tt == .dead) are always skipped — they are logically empty (value is
// Nil) and their payload holds a raw pointer that must not be dereferenced.
pub fn nextLiveIndex(nodes: []Node, start: usize) ?usize {
    var i: usize = start;
    while (i < nodes.len) : (i += 1) {
        // Skip empty, dead, and deleted (Nil-valued) nodes. A .dead node
        // always has value == Nil (clearkey is only called on empty-valued
        // nodes), but the explicit isDeadKey() check is a safety net.
        if (nodes[i].isEmpty() or nodes[i].isDeadKey()) continue;
        if (nodes[i].value != .Nil) return i;
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

// ─────────────────────────────────────────────────────────────────────
// Dead-key semantics tests (PUC DEADKEY, ltable.c:252-282 + lgc.c:209-213)
// ─────────────────────────────────────────────────────────────────────
//
// These tests verify the PUC-faithful dead-key behavior:
//   A. markDeadKey preserves the raw pointer (does NOT zero it).
//   B. keyMatches (deadok=0) never matches a .dead node; keyMatchesDeadok
//      (deadok=1) matches a live collectable key against a .dead node by
//      raw pointer identity.
//   C. clearKey applies to any collectable key type, not just strings.
//   D. rehash skips dead nodes; nodeInsert overwrites dead nodes in place.

test "markDeadKey preserves the raw pointer (PUC setdeadkey)" {
    // PUC setdeadkey (lobject.h:814) sets ONLY the tag; keyval is untouched.
    // The raw pointer must survive so deadok matching can compare by identity.
    var n: Node = .{};
    n.setKey(.{ .Int = 42 });
    n.value = .{ .Int = 420 };
    // Simulate a collectable key: use a dummy pointer via the table variant.
    const dummy_ptr: *Table = @ptrFromInt(0x1000);
    n.key_tt = .table;
    n.key_val = .{ .table = dummy_ptr };
    n.value = .Nil; // clearkey requires empty value
    n.markDeadKey();
    try std.testing.expectEqual(NodeKeyTag.dead, n.key_tt);
    // The raw pointer must be preserved (NOT zeroed).
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(dummy_ptr)), n.deadKeyPtr());
}

test "keyMatches (deadok=0) never matches a dead node" {
    // Normal lookups must never match dead keys (PUC equalkey deadok=0).
    var n: Node = .{};
    n.setKey(.{ .Int = 7 });
    n.value = .Nil;
    n.markDeadKey();
    // A dead node must not match any key, even the original.
    try std.testing.expect(!n.keyMatches(.{ .Int = 7 }));
    try std.testing.expect(!n.keyMatches(.{ .Int = 999 }));
}

test "keyMatchesDeadok (deadok=1) matches by raw pointer identity" {
    // PUC equalkey with deadok=1 (ltable.c:258-260): a collectable key k1
    // matches a dead node n2 iff gcvalue(k1) == gcvalueraw(keyval(n2)).
    var n: Node = .{};
    const dummy_ptr: *Table = @ptrFromInt(0x2000);
    n.key_tt = .table;
    n.key_val = .{ .table = dummy_ptr };
    n.value = .Nil;
    n.markDeadKey();

    // A live table key with the SAME pointer must match (deadok=1).
    const live_key: Value = .{ .Table = dummy_ptr };
    try std.testing.expect(n.keyMatchesDeadok(live_key));

    // A live table key with a DIFFERENT pointer must NOT match.
    const other_ptr: *Table = @ptrFromInt(0x3000);
    const other_key: Value = .{ .Table = other_ptr };
    try std.testing.expect(!n.keyMatchesDeadok(other_key));

    // A non-collectable key must NOT match a dead node (PUC iscollectable).
    try std.testing.expect(!n.keyMatchesDeadok(.{ .Int = 42 }));
    try std.testing.expect(!n.keyMatchesDeadok(.{ .Bool = true }));
}

test "nodeLookupDeadok finds a dead node; nodeLookup does not" {
    // deadok=0 (nodeLookup) must NOT find a dead node.
    // deadok=1 (nodeLookupDeadok) MUST find it by raw pointer.
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};

    const dummy_ptr: *Table = @ptrFromInt(0x4000);
    const key: Value = .{ .Table = dummy_ptr };
    const mp = mainPosition(nodes.len, key, 0);
    nodes[mp].key_tt = .table;
    nodes[mp].key_val = .{ .table = dummy_ptr };
    nodes[mp].value = .Nil;
    nodes[mp].markDeadKey();

    // Normal lookup (deadok=0): must return null (dead node not matched).
    try std.testing.expect(nodeLookup(nodes, key, 0) == null);
    // Deadok lookup (deadok=1): must find the dead node.
    const found = nodeLookupDeadok(nodes, key, 0).?;
    try std.testing.expectEqual(NodeKeyTag.dead, found.key_tt);
}

test "clearKey deadens any collectable key type, not just strings" {
    // PUC clearkey (lgc.c:209-213) applies to ANY collectable key
    // (keyiscollectable), not just strings. Verify table/closure/thread/
    // userdata keys are all deadened.
    var n: Node = .{};

    // Table key
    n.setKey(.{ .Table = @ptrFromInt(0x5000) });
    n.value = .Nil;
    clearKey(&n);
    try std.testing.expectEqual(NodeKeyTag.dead, n.key_tt);

    // Closure key
    n.setKey(.{ .Closure = @ptrFromInt(0x6000) });
    n.value = .Nil;
    clearKey(&n);
    try std.testing.expectEqual(NodeKeyTag.dead, n.key_tt);

    // Thread key
    n.setKey(.{ .Thread = @ptrFromInt(0x7000) });
    n.value = .Nil;
    clearKey(&n);
    try std.testing.expectEqual(NodeKeyTag.dead, n.key_tt);

    // Userdata key
    n.setKey(.{ .Userdata = @ptrFromInt(0x8000) });
    n.value = .Nil;
    clearKey(&n);
    try std.testing.expectEqual(NodeKeyTag.dead, n.key_tt);
}

test "clearKey does not deaden non-collectable keys" {
    // Non-collectable keys (int/num/bool/builtin/lightuserdata) never become
    // dead keys (PUC keyiscollectable returns false for them).
    var n: Node = .{};
    n.setKey(.{ .Int = 42 });
    n.value = .Nil;
    clearKey(&n);
    try std.testing.expectEqual(NodeKeyTag.int, n.key_tt); // unchanged

    n.setKey(.{ .Bool = true });
    n.value = .Nil;
    clearKey(&n);
    try std.testing.expectEqual(NodeKeyTag.bool_, n.key_tt); // unchanged
}

test "rehash skips dead nodes (dead pointer never dereferenced)" {
    // rehash must skip .dead nodes — getKey() must not be called on them
    // (it would return .Nil, but the point is the dead pointer is never read).
    const old = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(old);
    for (old) |*n| n.* = .{};

    // Place a live entry and a dead entry.
    old[0].setKey(.{ .Int = 10 });
    old[0].value = .{ .Int = 100 };
    old[1].key_tt = .table;
    old[1].key_val = .{ .table = @ptrFromInt(0x9000) };
    old[1].value = .Nil;
    old[1].markDeadKey(); // dead node with a raw pointer

    const result = try rehash(std.testing.allocator, old, 2, 0);
    defer std.testing.allocator.free(result.nodes);

    // Only the live entry should be present in the new hash.
    const found = nodeLookup(result.nodes, .{ .Int = 10 }, 0).?;
    try std.testing.expectEqual(@as(i64, 100), found.value.Int);
    // The dead node must not have been reinserted.
    try std.testing.expect(nodeLookup(result.nodes, .{ .Int = 999 }, 0) == null);
}

test "nodeInsert overwrites a dead node in place (stale pointer fully replaced)" {
    // A .dead node at the main position is available for overwrite (value == Nil).
    // setKey must fully replace key_val so the stale dead pointer is gone.
    const nodes = try std.testing.allocator.alloc(Node, 4);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};

    // Insert a key, delete it, deaden it.
    const key1: Value = .{ .Int = 7 };
    var lastfree: usize = nodes.len;
    _ = nodeInsert(nodes, &lastfree, key1, .{ .Int = 70 }, 0);
    _ = nodeDelete(nodes, key1, 0);
    const mp = mainPosition(nodes.len, key1, 0);
    nodes[mp].markDeadKey();
    try std.testing.expectEqual(NodeKeyTag.dead, nodes[mp].key_tt);

    // Insert a different key that maps to the same main position.
    // (With seed=0 and 4 slots, key 7 and key 7+4=11 may collide; use same key
    // to guarantee same main position — the dead node is overwritten.)
    const key2: Value = .{ .Int = 7 };
    _ = nodeInsert(nodes, &lastfree, key2, .{ .Int = 77 }, 0);

    // The node must no longer be dead — it's a live entry now.
    const found = nodeLookup(nodes, key2, 0).?;
    try std.testing.expectEqual(@as(i64, 77), found.value.Int);
    try std.testing.expect(found.key_tt != .dead);
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
        // Skip empty, dead, and deleted (Nil-valued) nodes. Dead nodes hold
        // a raw pointer to potentially-freed memory — getKey() must not be
        // called on them. PUC reinserthash (ltable.c:637-746) skips dead
        // nodes the same way (they have empty values and are not reinserted).
        if (o.isEmpty() or o.isDeadKey() or o.value == .Nil) continue;
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
// Chain-integrity regression tests for the nodeInsert fix (PUC ltable.c:863).
//
// Before the fix, nodeInsert used `mp.isEmpty()` (key-tag check) instead of
// `mp.value == .Nil` (value check) to decide if the main position was
// available for direct overwrite. It also cleared `next_offset` on overwrite.
// Together these two bugs orphaned every node after a deleted or dead-key
// node at the main position, corrupting the collision chain and making
// pairs()/next() fail with "invalid key to 'next'" after insert/delete churn.
// =========================================================================

// Insert several colliding keys, delete the one at the main position, then
// re-insert a new key that lands at the same main position. The new key must
// overwrite the deleted node in place WITHOUT clearing `next_offset`, so the
// rest of the chain remains reachable. Every previously inserted key must
// still be findable via nodeLookup.
test "nodeInsert: overwrite deleted node at main position preserves chain" {
    const cap = 8;
    const nodes = try std.testing.allocator.alloc(Node, cap);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var lastfree: usize = nodes.len;

    // Insert 7 int keys (filling all but one slot). With seed=0 the golden-
    // ratio hash distributes them, but some will collide and chain.
    var i: i64 = 1;
    while (i < cap) : (i += 1) {
        _ = nodeInsert(nodes, &lastfree, .{ .Int = i }, .{ .Int = i * 10 }, 0) orelse {
            try std.testing.expect(false);
            return;
        };
    }

    // Pick the key whose node is at its own main position (index 0 of the
    // chain). We find it by scanning: the main-position node's rawHash must
    // equal its index masked by (cap-1).
    var mp_key: Value = .Nil;
    for (nodes, 0..) |*n, idx| {
        if (n.isEmpty() or n.value == .Nil) continue;
        if ((n.rawHash(0) & (cap - 1)) == idx) {
            mp_key = n.getKey();
            break;
        }
    }
    try std.testing.expect(mp_key != .Nil);

    // If this main-position node has a chain (next_offset != 0), delete it
    // and re-insert a new key at the same main position. The chain must
    // survive.
    const mp_node = nodeLookup(nodes, mp_key, 0).?;
    const had_chain = mp_node.next_offset != 0;
    if (had_chain) {
        // Delete the main-position key.
        try std.testing.expect(nodeDelete(nodes, mp_key, 0));
        // Verify the node is now Nil-valued but still has its chain link.
        const deleted_node = nodeLookup(nodes, mp_key, 0).?;
        try std.testing.expect(deleted_node.value == .Nil);
        try std.testing.expect(deleted_node.next_offset != 0);

        // Insert a new key that hashes to the same main position. We use a
        // key with the same hash: since keyHash(.Int = k, 0) = hashInt(k, 0),
        // and hashInt uses the golden ratio, we find a colliding key by
        // scanning for an int whose hash mod cap equals the main position.
        const mp_idx = mp_node.rawHash(0) & (cap - 1);
        var new_key: i64 = 1000;
        while (new_key < 10000) : (new_key += 1) {
            if ((hashInt(new_key, 0) & (cap - 1)) == mp_idx and new_key != mp_key.Int) break;
        }
        try std.testing.expect(new_key < 10000);

        _ = nodeInsert(nodes, &lastfree, .{ .Int = new_key }, .{ .Int = 999 }, 0) orelse {
            try std.testing.expect(false);
            return;
        };

        // The new key must be findable.
        const found_new = nodeLookup(nodes, .{ .Int = new_key }, 0).?;
        try std.testing.expectEqual(@as(i64, 999), found_new.value.Int);

        // The deleted key's node is now overwritten with the new key; its
        // chain link (next_offset) must still point to the same successor.
        try std.testing.expectEqual(mp_node.next_offset, found_new.next_offset);
    }

    // Every non-deleted key must still be findable.
    i = 1;
    while (i < cap) : (i += 1) {
        if (i == mp_key.Int and had_chain) continue; // deleted, overwritten
        const found = nodeLookup(nodes, .{ .Int = i }, 0) orelse {
            try std.testing.expect(false);
            return;
        };
        try std.testing.expectEqual(i * 10, found.value.Int);
    }
}

// Simulate the nextvar.lua:135-141 churn pattern at the nodeInsert level:
// fill the hash part, then repeatedly insert and delete keys that collide
// with existing main positions. After churn, every surviving key must be
// findable — no chain links orphaned.
test "nodeInsert: insert/delete churn preserves chain integrity" {
    const cap = 16;
    const nodes = try std.testing.allocator.alloc(Node, cap);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var lastfree: usize = nodes.len;

    // Fill with 15 int keys (leave one free slot).
    var i: i64 = 1;
    while (i < cap) : (i += 1) {
        _ = nodeInsert(nodes, &lastfree, .{ .Int = i }, .{ .Int = i }, 0) orelse {
            try std.testing.expect(false);
            return;
        };
    }

    // Churn: insert and delete keys 100..1000. These collide with existing
    // main positions, forcing nodeInsert to either overwrite a deleted node
    // (the fix path) or Brent-evict a live node. Each delete leaves a
    // Nil-valued node at some main position; the next insert at that main
    // position must overwrite in place, preserving the chain.
    var k: i64 = 100;
    while (k < 1000) : (k += 1) {
        _ = nodeInsert(nodes, &lastfree, .{ .Int = k }, .{ .Int = k }, 0) orelse continue;
        _ = nodeDelete(nodes, .{ .Int = k }, 0);
    }

    // Every original key (1..15) must still be findable with its value.
    i = 1;
    while (i < cap) : (i += 1) {
        const found = nodeLookup(nodes, .{ .Int = i }, 0) orelse {
            try std.testing.expect(false);
            return;
        };
        try std.testing.expectEqual(i, found.value.Int);
    }
}

// A dead-key node (key_tt == .dead, value == .Nil) at the main position must
// be overwritten in place by nodeInsert, just like a deleted node. The chain
// link (next_offset) must be preserved. This mirrors PUC's `insertkey` which
// treats any nil-valued main position as available, regardless of key tag.
test "nodeInsert: overwrite dead-key node at main position preserves chain" {
    const cap = 8;
    const nodes = try std.testing.allocator.alloc(Node, cap);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*n| n.* = .{};
    var lastfree: usize = nodes.len;

    // Insert two int keys that collide at the same main position.
    // Find a colliding pair: keys k1, k2 where hashInt(k1,0)&7 == hashInt(k2,0)&7.
    var k1: i64 = 1;
    var k2: i64 = 2;
    outer: while (k1 < 100) : (k1 += 1) {
        k2 = k1 + 1;
        while (k2 < 100) : (k2 += 1) {
            if ((hashInt(k1, 0) & 7) == (hashInt(k2, 0) & 7)) break :outer;
        }
    }
    try std.testing.expect(k1 < 100);

    _ = nodeInsert(nodes, &lastfree, .{ .Int = k1 }, .{ .Int = 11 }, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    _ = nodeInsert(nodes, &lastfree, .{ .Int = k2 }, .{ .Int = 22 }, 0) orelse {
        try std.testing.expect(false);
        return;
    };

    // Find the main-position node (the one whose index == its hash & 7).
    const mp_idx = hashInt(k1, 0) & 7;
    const mp_node = &nodes[mp_idx];

    // Determine which key is at the main position and which is chained.
    const mp_key = mp_node.getKey();
    const chained_key: Value = if (mp_key == .Int and mp_key.Int == k1) .{ .Int = k2 } else .{ .Int = k1 };

    // Simulate GC deadening: mark the main-position node as dead-key.
    // (In real GC, this happens when the string key is collected. Here we
    // use an int key and manually call markDeadKey to simulate the state.)
    _ = nodeDelete(nodes, mp_key, 0); // value -> .Nil
    mp_node.markDeadKey(); // key_tt -> .dead, key_val cleared

    // Verify the dead node still has its chain link.
    const saved_next = mp_node.next_offset;
    try std.testing.expect(saved_next != 0); // must have a chain

    // Insert a new key that hashes to the same main position.
    var new_key: i64 = 1000;
    while (new_key < 10000) : (new_key += 1) {
        if ((hashInt(new_key, 0) & 7) == mp_idx) break;
    }
    try std.testing.expect(new_key < 10000);

    _ = nodeInsert(nodes, &lastfree, .{ .Int = new_key }, .{ .Int = 333 }, 0) orelse {
        try std.testing.expect(false);
        return;
    };

    // The new key must be at the main position (overwrote the dead node).
    const found_new = nodeLookup(nodes, .{ .Int = new_key }, 0).?;
    try std.testing.expectEqual(@as(i64, 333), found_new.value.Int);
    try std.testing.expectEqual(@as(usize, @intFromPtr(found_new)), @as(usize, @intFromPtr(mp_node)));

    // The chain link must be preserved (not cleared to 0).
    try std.testing.expectEqual(saved_next, found_new.next_offset);

    // The chained key must still be findable.
    const found_chained = nodeLookup(nodes, chained_key, 0).?;
    try std.testing.expect(chained_key == .Int);
    const expected_val: i64 = if (chained_key.Int == k1) 11 else 22;
    try std.testing.expectEqual(expected_val, found_chained.value.Int);
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
