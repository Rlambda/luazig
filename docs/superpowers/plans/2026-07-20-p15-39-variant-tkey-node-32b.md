# P15.39 — Variant TKey: Node 48B → 32B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shrink `ltable.Node` from 48 B to 32 B by splitting the `key: Value` (16 B tagged union) into a 1 B type tag (`key_tt`) plus an 8 B raw payload union (`key_val`), and removing the cached `hash: u64` field (recompute on demand, like PUC Lua).

**Architecture:** PUC-faithful Node layout. `Value` itself stays as `union(enum)` (16 B) — we only split the key inside `Node`, not the value type. The chain link stays as `next_offset: i32` (PUC `gnext`-style signed offset). Dead keys are marked by a dedicated `key_tt = .dead` tag instead of a high bit in `hash`, mirroring PUC's `LUA_TDEADKEY`. Hashes are computed once per lookup/insert from the key payload and discarded, exactly like PUC's `hashint`/`hashstr`/`hashpointer`/`hashboolean` which are called inline at each use site.

**Tech Stack:** Zig 0.16.0, existing `ltable.zig` test suite + upstream `testes/*.lua` matrix + perf benchmarks.

**Cache-line rationale:** At 48 B only ~1 full Node fits per 64 B cache line; at 32 B two full Nodes fit. That is the qualitative threshold (1→2 nodes/line); further shrinking to 24 B (full PUC parity) would only add a partial third node per line and would require changing `Value` itself (300+ sites) — deferred to P15.40+.

---

## File Structure

- **Modify:** `src/lua/ltable.zig` — new Node layout, accessors, dead-key handling, hash-on-demand.
- **Modify:** `src/lua/vm.zig` — GC marking paths, debug name resolution, `next()` iteration; replace `node.key == .X` with accessor calls.
- **Modify:** `src/lua/api.zig` — `isFileUserdata` walks metatable hash; same accessor migration.
- **No new files.** All changes are in-place refactors of existing code.

## Target Node layout (32 B)

```zig
pub const NodeKeyTag = enum(u8) {
    empty,   // slot is unused (no key). Default for fresh nodes.
    dead,    // dead key — payload not dereferenced (chain stability only).
    int,
    num,
    string,
    table,
    closure,
    thread,
    bool_,   // key_val.bool_val holds the boolean
};

// Bare 8-byte payload union — NO tag, NO Nil variant (Nil is encoded by tag).
// Used only inside Node.key_val. Always paired with NodeKeyTag.
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
    // Field order chosen for natural alignment: Value is 8-aligned,
    // NodeKeyPayload is 8-aligned, i32 is 4-aligned, u8 is 1-aligned.
    // After value (offset 0..16), key_val at 16..24, next_offset at 24..28,
    // key_tt at 28, padding 29..32 to align the next Node in an array.
    value: Value = .Nil,
    key_val: NodeKeyPayload = .{ .int = 0 },
    next_offset: i32 = 0,
    key_tt: NodeKeyTag = .empty,
};
// @sizeOf(Node) == 32  (verified by comptime assertion + test)
```

## Invariants preserved

1. **Empty slot:** `key_tt == .empty`. Distinct from any live key (Nil cannot be a Lua table key).
2. **Dead key:** `key_tt == .dead`. Payload is left as-is (do not dereference; the original pointer may be dangling). Used for chain continuity only — `nodeLookup` skips dead nodes.
3. **Live key:** `key_tt ∈ {int, num, string, table, closure, thread, bool_}`. `key_val` holds the corresponding payload.
4. **Hash not stored:** `keyHash(key, seed)` is called inline at each use site (`nodeLookup`, `nodeInsert`, `nodeMainPosition`). Matches PUC `ltable.c` which calls `hashint`/`hashstr`/etc. at use sites.
5. **Chain link:** `next_offset: i32` signed index offset — unchanged from current PUC `gnext`-style layout.

---

### Task 1: Add NodeKeyTag + NodeKeyPayload types and accessor helpers (no layout change yet)

This task introduces the new types and accessor methods on Node **without** changing the on-disk layout. All existing callers of `node.key` continue to work unchanged. After this task, `@sizeOf(Node)` is still 48 B.

**Files:**
- Modify: `src/lua/ltable.zig:35-92` (Node struct)

- [ ] **Step 1: Add `NodeKeyTag` and `NodeKeyPayload` types above the Node struct**

Insert after the `HASH_MASK` const (line 33) and before `pub const Node = struct {`:

```zig
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
```

- [ ] **Step 2: Add accessor helpers on Node (read-only, still using old layout)**

Inside the existing `pub const Node = struct { ... }` body, before the closing `};`, add:

```zig
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
```

- [ ] **Step 3: Verify build**

Run: `zig build -Doptimize=Debug 2>&1 | head -30`
Expected: build succeeds (no callers use the new types yet; they're additive).

- [ ] **Step 4: Add unit test for accessors round-trip**

Add inside `ltable.zig` (anywhere after the Node struct):

```zig
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
```

- [ ] **Step 5: Run ltable tests**

Run: `zig test src/lua/ltable.zig --dep std -Mroot=src/lua/ltable.zig 2>&1 | tail -10`
(Or via the project's test runner if ltable tests are bundled into the main suite.)
Expected: PASS.

If `zig test` on the single file doesn't link due to dependencies, run `zig build test -Doptimize=Debug` and check that all tests still pass.

- [ ] **Step 6: Commit**

```bash
git add src/lua/ltable.zig
git commit -m "P15.39: add NodeKeyTag/Payload types + Node.getKey/setKey accessors (no layout change)"
```

---

### Task 2: Migrate ltable.zig internal callers to use accessors

Replace direct `node.key` reads with `node.getKey()` and direct `node.key = X` writes with `node.setKey(X)`. After this task, the `key: Value` field is only touched inside the accessor methods themselves, preparing for the layout swap in Task 4.

**Files:**
- Modify: `src/lua/ltable.zig` (Node methods, `nodeLookup`, `nodeInsert`, `nodeDelete`, `deadenStringKey`, `rehash`, tests)

- [ ] **Step 1: Migrate `nodeLookup` (line ~143-150)**

Before:
```zig
pub fn nodeLookup(nodes: []Node, key: Value, seed: u64) ?*Node {
    if (nodes.len == 0) return null;
    var n: *Node = &nodes[mainPosition(nodes.len, key, seed)];
    if (n.isEmpty()) return null;
    while (true) {
        if (!n.isDeadKey() and keyEq(n.key, key)) return n;
        n = n.nextNode(nodes) orelse return null;
    }
}
```

After:
```zig
pub fn nodeLookup(nodes: []Node, key: Value, seed: u64) ?*Node {
    if (nodes.len == 0) return null;
    var n: *Node = &nodes[mainPosition(nodes.len, key, seed)];
    if (n.isEmpty()) return null;
    while (true) {
        if (!n.isDeadKey() and keyEq(n.getKey(), key)) return n;
        n = n.nextNode(nodes) orelse return null;
    }
}
```

- [ ] **Step 2: Migrate `nodeInsert` (line ~188-254)**

Three places touch `.key`:

Line 199-202 (`mp.isEmpty()` branch):
```zig
// Before:
mp.key = key;
mp.value = value;
mp.hash = h;
mp.next_offset = 0;

// After:
mp.setKey(key);
mp.value = value;
mp.hash = h;            // hash field still exists in this task
mp.next_offset = 0;
```

Line 229-234 (Brent evict — copies occupant to free slot):
```zig
// Before:
free.* = .{
    .key = mp.key,
    .value = mp.value,
    .hash = mp.hash,
    .next_offset = adjustOffset(mp.next_offset, mp_idx, free_idx),
};

// After: build incrementally (struct literal can't call setKey)
free.* = .{};
free.setKey(mp.getKey());
free.value = mp.value;
free.hash = mp.hash;
free.next_offset = adjustOffset(mp.next_offset, mp_idx, free_idx);
```

Line 240 (place new key at mp):
```zig
// Before:
mp.* = .{ .key = key, .value = value, .hash = h, .next_offset = 0 };

// After:
mp.* = .{};
mp.setKey(key);
mp.value = value;
mp.hash = h;
mp.next_offset = 0;
```

Line 245-250 (append to chain at `free`):
```zig
// Before:
free.* = .{
    .key = key,
    .value = value,
    .hash = h,
    .next_offset = adjustOffset(mp.next_offset, mp_idx, free_idx),
};

// After:
free.* = .{};
free.setKey(key);
free.value = value;
free.hash = h;
free.next_offset = adjustOffset(mp.next_offset, mp_idx, free_idx);
```

- [ ] **Step 3: Migrate `deadenStringKey` (line 338-347)**

Before:
```zig
pub fn deadenStringKey(node: *Node) void {
    if (node.key != .String or node.value != .Nil) return;
    node.key = .Nil;
    node.markDeadKey();
}
```

After:
```zig
pub fn deadenStringKey(node: *Node) void {
    if (node.key_tt != .string or node.value != .Nil) return;
    node.key_tt = .dead;
    node.key_val = .{ .int = 0 };  // sever the stale pointer reference
    node.hash |= DEAD_KEY_FLAG;     // hash field still exists in this task
}
```

- [ ] **Step 4: Migrate `rehash` (line 400-404)**

Before:
```zig
for (old) |*o| {
    if (o.isEmpty() or o.value == .Nil) continue;
    _ = nodeInsert(new_nodes, &lastfree, o.key, o.value, seed);
}
```

After:
```zig
for (old) |*o| {
    if (o.isEmpty() or o.value == .Nil) continue;
    _ = nodeInsert(new_nodes, &lastfree, o.getKey(), o.value, seed);
}
```

- [ ] **Step 5: Migrate in-file test cases**

Test on line 166:
```zig
// Before:
nodes[mp] = .{ .key = key, .value = .{ .Int = 70 } };
// After:
nodes[mp] = .{};
nodes[mp].setKey(key);
nodes[mp].value = .{ .Int = 70 };
```

Test on line 277:
```zig
// Before:
try std.testing.expect(keyEq(inserted.key, key));
// After:
try std.testing.expect(keyEq(inserted.getKey(), key));
```

Tests on lines 378-380:
```zig
// Before:
nodes[1] = .{ .key = .{ .Int = 10 }, .value = .{ .Int = 100 } };
nodes[2] = .{ .key = .{ .Int = 20 }, .value = .Nil };
nodes[3] = .{ .key = .{ .Int = 30 }, .value = .{ .Int = 300 } };
// After:
nodes[1] = .{};
nodes[1].setKey(.{ .Int = 10 });
nodes[1].value = .{ .Int = 100 };
nodes[2] = .{};
nodes[2].setKey(.{ .Int = 20 });
nodes[2].value = .Nil;
nodes[3] = .{};
nodes[3].setKey(.{ .Int = 30 });
nodes[3].value = .{ .Int = 300 };
```

- [ ] **Step 6: Verify build**

Run: `zig build -Doptimize=Debug 2>&1 | head -30`
Expected: PASS. If you see "use of undeclared identifier `key`" anywhere, you missed a site.

- [ ] **Step 7: Run ltable tests**

Run: `zig build test -Doptimize=Debug 2>&1 | tail -30`
Expected: all tests PASS.

- [ ] **Step 8: Commit**

```bash
git add src/lua/ltable.zig
git commit -m "P15.39: migrate ltable.zig internal callers to Node.getKey/setKey"
```

---

### Task 3: Migrate vm.zig callers to use accessors

Replace direct `node.key == .X` and `node.key.String.bytes()` reads with `node.getKey()` / `node.key_tt` checks. These are all read-only uses; the writes happen inside ltable.zig.

**Files:**
- Modify: `src/lua/vm.zig` — sites at lines 14876, 14883, 15237, 15238, 15244, 15275, 15277, 15283, 15475, 15477, 16954, 16958, 16959, 16969, 16973, 16974, 16982, 16986, 16987, 19329.

- [ ] **Step 1: Migrate GC mark paths in `gcMarkValue` (line ~14875-14898)**

Before:
```zig
for (tbl.hash) |*node| {
    if (node.key == .Nil) continue; // empty slot or dead key
    if (node.value == .Nil) continue; // logically deleted
    const k = node.key;
    if (k == .String) {
        try self.gcMarkValue(k);
    } else if (!mode.weak_k) {
        if (k == .Table or k == .Closure or k == .Thread) try self.gcMarkValue(k);
    }
    ...
```

After:
```zig
for (tbl.hash) |*node| {
    if (node.key_tt == .empty or node.key_tt == .dead) continue;
    if (node.value == .Nil) continue;
    const k = node.getKey();
    if (k == .String) {
        try self.gcMarkValue(k);
    } else if (!mode.weak_k) {
        if (k == .Table or k == .Closure or k == .Thread) try self.gcMarkValue(k);
    }
    ...
```

Rationale: `node.key_tt` is the cheapest check — directly reading a `u8` instead of reading a 16-byte `Value` and checking its tag. We skip both empty slots and dead keys (dead keys have no live pointer to mark).

- [ ] **Step 2: Migrate the weak-table ephemeron code (line ~15235-15245)**

Before:
```zig
for (tbl.hash) |*node| {
    if (node.key == .Nil or node.value == .Nil) continue;
    const key_marked = switch (node.key) {
        .Table => |table| ...,
        .Closure => |closure| ...,
        .Thread => |thread| ...,
        else => true,
    };
    if (key_marked) try self.gcMarkValue(node.value);
}
```

After:
```zig
for (tbl.hash) |*node| {
    if (node.key_tt == .empty or node.key_tt == .dead or node.value == .Nil) continue;
    const key_marked = switch (node.key_tt) {
        .table => blk: {
            const table = node.key_val.table;
            break :blk (self.gc_minor_cycle and !gcMinorCandidate(table.gc_age)) or marked_tables.contains(table);
        },
        .closure => blk: {
            const closure = node.key_val.closure;
            break :blk (self.gc_minor_cycle and !gcMinorCandidate(closure.gc_age)) or marked_closures.contains(closure);
        },
        .thread => blk: {
            const thread = node.key_val.thread;
            break :blk (self.gc_minor_cycle and !gcMinorCandidate(thread.gc_age)) or marked_threads.contains(thread);
        },
        else => true,
    };
    if (key_marked) try self.gcMarkValue(node.value);
}
```

Note: this avoids the full `getKey()` reconstruction (no need to build a `Value`); we read `key_val` directly. This is slightly faster for the GC hot path and matches PUC's `gval(n)` access pattern.

- [ ] **Step 3: Migrate `gcMarkValueFinalizerReach` hash walk (line ~15284-15286)**

Before:
```zig
for (tbl.hash) |*node| {
    if (node.key == .Nil) continue;
    if (node.value == .Nil) continue; // tombstone
    const k = node.key;
    ...
```

After:
```zig
for (tbl.hash) |*node| {
    if (node.key_tt == .empty or node.key_tt == .dead) continue;
    if (node.value == .Nil) continue;
    const k = node.getKey();
    ...
```

- [ ] **Step 4: Migrate the finalizer-reachability walk (line ~15474-15478)**

Before:
```zig
for (tbl.hash) |*node| {
    if (node.key == .Nil) continue;
    if (node.value == .Nil) continue; // tombstone
    const k = node.key;
    const vv = node.value;
    ...
```

After:
```zig
for (tbl.hash) |*node| {
    if (node.key_tt == .empty or node.key_tt == .dead) continue;
    if (node.value == .Nil) continue;
    const k = node.getKey();
    const vv = node.value;
    ...
```

- [ ] **Step 5: Migrate debug name resolution in `debugInfoNameOfCallee` (lines 16953-16989)**

This is three near-identical blocks. Apply the same transformation to each.

Before (representative):
```zig
for (v.Table.hash) |*node| {
    if (node.key == .Nil) continue;
    if (node.value == .Nil) continue;
    const fv = node.value;
    if (self.debugFrameCalleeMatches(fv, target)) {
        if (node.key == .String) {
            return .{ .name = node.key.String.bytes(), .namewhat = "field" };
        }
    }
}
```

After:
```zig
for (v.Table.hash) |*node| {
    if (node.key_tt != .string) continue;  // empty/dead/non-string all skip
    if (node.value == .Nil) continue;
    const fv = node.value;
    if (self.debugFrameCalleeMatches(fv, target)) {
        return .{ .name = node.key_val.string.bytes(), .namewhat = "field" };
    }
}
```

Note: `node.key_tt != .string` combines three checks (`== .Nil`, `== .String` branch) into one — strictly faster than before. The `node.key_val.string.bytes()` read goes directly to the payload without reconstructing a `Value`.

Apply this transformation to all three blocks in `debugInfoNameOfCallee` (caller locals, caller upvalues, globals).

- [ ] **Step 6: Migrate `next()` iteration result (line ~19329)**

Before:
```zig
if (ltable.nextLiveIndex(tbl.hash, hash_idx)) |hi| {
    const node = tbl.hash[hi];
    return .{ .key = node.key, .value = node.value };
}
```

After:
```zig
if (ltable.nextLiveIndex(tbl.hash, hash_idx)) |hi| {
    const node = tbl.hash[hi];
    return .{ .key = node.getKey(), .value = node.value };
}
```

- [ ] **Step 7: Verify build**

Run: `zig build -Doptimize=Debug 2>&1 | head -30`
Expected: PASS.

- [ ] **Step 8: Run unit tests**

Run: `zig build test -Doptimize=Debug 2>&1 | tail -20`
Expected: all tests PASS.

- [ ] **Step 9: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.39: migrate vm.zig callers to Node.getKey/key_tt/key_val"
```

---

### Task 4: Migrate api.zig callers

`api.zig` has one site (`isFileUserdata`) that walks a metatable's hash looking for the `__name` field. Apply the same transformation as the debug-name sites.

**Files:**
- Modify: `src/lua/api.zig:620-636`

- [ ] **Step 1: Migrate `isFileUserdata`**

Before:
```zig
for (mt.hash) |*node| {
    if (node.key == .Nil or node.value == .Nil) continue;
    if (node.key != .String) continue;
    if (std.mem.eql(u8, node.key.String.bytes(), "__name")) {
        const nm = node.value;
        if (nm != .String) return false;
        return std.mem.eql(u8, nm.String.bytes(), "FILE*");
    }
}
```

After:
```zig
for (mt.hash) |*node| {
    if (node.key_tt != .string) continue;
    if (node.value == .Nil) continue;
    if (std.mem.eql(u8, node.key_val.string.bytes(), "__name")) {
        const nm = node.value;
        if (nm != .String) return false;
        return std.mem.eql(u8, nm.String.bytes(), "FILE*");
    }
}
```

- [ ] **Step 2: Verify build + tests**

Run: `zig build test -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/lua/api.zig
git commit -m "P15.39: migrate api.zig isFileUserdata to Node key_tt/key_val"
```

---

### Task 5: Swap Node to the 32-byte layout

Now that all external callers go through `getKey()`/`setKey()`/`key_tt`/`key_val`, we can change the struct layout. This is where the cache-line density actually changes.

**Files:**
- Modify: `src/lua/ltable.zig` (Node struct)

- [ ] **Step 1: Replace the Node struct definition**

Before:
```zig
pub const Node = struct {
    key: Value = .Nil, // .Nil marks a free slot (Nil cannot be a Lua table key)
    value: Value = .Nil,
    hash: u64 = 0,
    next_offset: i32 = 0,
    ...methods...
};
```

After:
```zig
pub const Node = struct {
    value: Value = .Nil,
    key_val: NodeKeyPayload = .{ .int = 0 },
    next_offset: i32 = 0,
    key_tt: NodeKeyTag = .empty,

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

    /// Compute the hash of this node's key. Called inline at lookup/insert
    /// sites — we do NOT cache the hash in the node, matching PUC's design
    /// (PUC hashes at each use site via `hashint`/`hashstr`/`hashpointer`/
    /// `hashboolean`). `seed` is the per-VM random hash seed.
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
            .Builtin => {
                self.key_tt = .empty;
                self.key_val = .{ .int = 0 };
            },
        }
    }
};
```

- [ ] **Step 2: Delete `DEAD_KEY_FLAG`, `HASH_MASK`, and `nodeMainPosition`**

These are no longer needed:
- `DEAD_KEY_FLAG`/`HASH_MASK`: dead-key marker moved to `key_tt = .dead`.
- `nodeMainPosition(len, node)`: was used by `nodeInsert` to decide Brent evict vs chain-append. Replace its single caller (see Step 4) with `node.rawHash(seed) & (len - 1)`.

Delete the const declarations at lines 32-33:
```zig
// DELETE:
const DEAD_KEY_FLAG: u64 = 1 << 63;
const HASH_MASK: u64 = ~DEAD_KEY_FLAG;
```

Delete `nodeMainPosition` (line 134-139):
```zig
// DELETE:
fn nodeMainPosition(len: usize, node: *const Node) usize {
    return node.rawHash() & (len - 1);
}
```

- [ ] **Step 3: Add `hashNum` helper**

`rawHash` calls `hashNum`, which doesn't exist yet. Add it next to `hashInt`:

```zig
fn hashNum(n: f64, seed: u64) u64 {
    // PUC reinterprets the f64 bits as i64 and hashes via hashint. We use
    // wyhash for the same property (well-distributed regardless of the
    // float's bit pattern). Endianness-independent via std.mem.asBytes.
    var h = std.hash.Wyhash.init(seed);
    h.update(std.mem.asBytes(&n));
    return h.final();
}
```

- [ ] **Step 4: Update `nodeInsert` (no more cached hash field to write)**

Before:
```zig
pub fn nodeInsert(nodes, lastfree, key, value, seed) ?*Node {
    const h = keyHash(key, seed) & HASH_MASK;
    const mp_idx: usize = h & (nodes.len - 1);
    const mp: *Node = &nodes[mp_idx];
    if (mp.isEmpty()) {
        mp.setKey(key);
        mp.value = value;
        mp.hash = h;            // <-- REMOVE
        mp.next_offset = 0;
        return mp;
    }
    const free = getFreePos(nodes, lastfree) orelse return null;
    const free_idx: usize = ...;
    const other_idx: usize = nodeMainPosition(nodes.len, mp);  // <-- REPLACE
    if (other_idx != mp_idx) {
        // Brent evict
        ...
        free.* = .{};
        free.setKey(mp.getKey());
        free.value = mp.value;
        free.hash = mp.hash;    // <-- REMOVE
        free.next_offset = adjustOffset(...);
        ...
        mp.* = .{};
        mp.setKey(key);
        mp.value = value;
        mp.hash = h;            // <-- REMOVE
        mp.next_offset = 0;
        return mp;
    } else {
        // Chain-append
        free.* = .{};
        free.setKey(key);
        free.value = value;
        free.hash = h;          // <-- REMOVE
        free.next_offset = adjustOffset(...);
        ...
    }
}
```

After (the changes are: drop every `mp.hash = ...` / `free.hash = ...` line, and replace `nodeMainPosition(nodes.len, mp)` with inline `mp.rawHash(seed) & (nodes.len - 1)`):

```zig
pub fn nodeInsert(nodes, lastfree, key, value, seed) ?*Node {
    const h = keyHash(key, seed);
    const mp_idx: usize = h & (nodes.len - 1);
    const mp: *Node = &nodes[mp_idx];
    if (mp.isEmpty()) {
        mp.setKey(key);
        mp.value = value;
        mp.next_offset = 0;
        return mp;
    }
    const free = getFreePos(nodes, lastfree) orelse return null;
    const free_idx: usize = (@intFromPtr(free) - @intFromPtr(nodes.ptr)) / @sizeOf(Node);
    const other_idx: usize = mp.rawHash(seed) & (nodes.len - 1);
    if (other_idx != mp_idx) {
        // Brent evict: occupant of mp belongs elsewhere — relocate to free.
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
        // Same main position — chain-append new key at free.
        free.* = .{};
        free.setKey(key);
        free.value = value;
        free.next_offset = adjustOffset(mp.next_offset, mp_idx, free_idx);
        mp.next_offset = @intCast(@as(i64, @intCast(free_idx)) - @as(i64, @intCast(mp_idx)));
        return free;
    }
}
```

Note: no more `& HASH_MASK` on the hash — we no longer steal a bit from it.

- [ ] **Step 5: Update `deadenStringKey`**

The current implementation uses `hash |= DEAD_KEY_FLAG` and `key = .Nil`. The new code uses `markDeadKey()` which sets `key_tt = .dead`.

Before (after Task 2):
```zig
pub fn deadenStringKey(node: *Node) void {
    if (node.key_tt != .string or node.value != .Nil) return;
    node.key_tt = .dead;
    node.key_val = .{ .int = 0 };
    node.hash |= DEAD_KEY_FLAG;
}
```

After:
```zig
pub fn deadenStringKey(node: *Node) void {
    if (node.key_tt != .string or node.value != .Nil) return;
    node.markDeadKey();
}
```

- [ ] **Step 6: Add comptime size assertion**

After the Node struct definition, add:

```zig
comptime {
    // PUC-faithful 32-byte Node: two full nodes per 64-byte cache line.
    // Value (16) + NodeKeyPayload (8) + i32 (4) + u8 (1) + padding (3) = 32.
    if (@sizeOf(Node) != 32) {
        @compileError("expected Node to be 32 bytes, got " ++ std.fmt.comptimePrint("{d}", .{@sizeOf(Node)}));
    }
}
```

- [ ] **Step 7: Update the doc-comment for the Node struct**

The existing long comment at lines 17-31 talks about `DEAD_KEY_FLAG` in the hash field. Rewrite it to describe the new layout:

```zig
/// PUC-faithful compact Node for hash tables. Field layout:
///   value      Value           (16 B) — full tagged value (PUC's TValue i_val)
///   key_val    NodeKeyPayload  (8 B)  — bare payload (PUC's `Value key_val`)
///   next_offset i32            (4 B)  — signed chain link (PUC's `int next`)
///   key_tt     NodeKeyTag      (1 B)  — key type tag (PUC's `lu_byte key_tt`)
///   padding                    (3 B)
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
```

- [ ] **Step 8: Verify build**

Run: `zig build -Doptimize=Debug 2>&1 | head -30`
Expected: PASS — comptime assertion `@sizeOf(Node) == 32` succeeds.

If the assertion fails with a different size, inspect the layout: `extern union` might force a particular alignment. Common fix: drop `extern` from `NodeKeyPayload` (regular Zig union is also 8 bytes if all variants are 8 bytes) or reorder fields.

- [ ] **Step 9: Run ltable tests**

Run: `zig build test -Doptimize=Debug 2>&1 | tail -20`
Expected: all ltable unit tests PASS — the Brent-chain stress test especially.

- [ ] **Step 10: Commit**

```bash
git add src/lua/ltable.zig
git commit -m "P15.39: swap Node to 32-byte layout (value + key_val + next_offset + key_tt)"
```

---

### Task 6: Full regression suite + perf measurement

Run the complete correctness gate, then measure the perf impact and update README.

**Files:**
- No code changes unless tests fail.

- [ ] **Step 1: Build ReleaseFast**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 2: Zig unit tests (Debug)**

Run: `zig build test -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Smoke tests**

Run: `for f in tests/smoke/*.lua; do echo "=== $f ==="; ./zig-out/bin/luazig "$f" || echo "FAIL: $f"; done 2>&1 | tail -40`
Expected: all PASS (44/44).

- [ ] **Step 4: Upstream matrix (the AGENTS.md gate)**

Run: `python3 tools/testes_matrix.py --no-build --timeout 120 2>&1 | tail -30`

**IMPORTANT (from AGENTS.md):** this MUST be run WITHOUT `_soft` and `_port` flags for the regression check. Check the script's defaults; if it defaults to safe mode, override.

Expected: 29/29 PASS (or whatever the current parity count is — must not regress).

Specifically verify the previously-known tricky suites pass:
- `nextvar.lua` (heavy next() iteration — exercises our Node layout)
- `gc.lua` (weak tables + dead keys — exercises `deadenStringKey`)
- `gengc.lua` (generational GC — exercises dead-key transitions)
- `sort.lua` (heavy table access)
- `tpack.lua` (table.pack/unpack — array + hash boundary)

- [ ] **Step 5: Stress test**

Run: `tools/iterative_dispatch_stress.sh 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 6: Perf measurement**

Run: `python3 tools/perf_compare.py --runs 7 --core 0 --no-build 2>&1 | tail -30`

Compare geomean vs baseline (`tools/perf/baseline-p15.37.json`). Expected improvements:
- `hash_access`: ~4.89× → ~3.8-4.0× (nodeLookup-bound)
- `field_access`: ~4.29× → ~3.5-3.7×
- `global_arith`: ~3.35× → ~3.0-3.2×
- `array_access`: ~4.04× → ~3.8× (modest — mostly array part)
- Other workloads: ±noise (Node size shouldn't affect dispatch-only loops).

If hash_access/field_access/global_arith improvements are <5%, something is wrong — investigate cache behavior with `perf record` before claiming success.

- [ ] **Step 7: Update baseline if perf improves**

If the geomean improves by >3%, update the baseline:

Run: `python3 tools/perf_compare.py --runs 7 --core 0 --no-build --update-baseline 2>&1 | tail -10`

This saves the new measurements as the reference for future regression checks.

- [ ] **Step 8: Update README**

In `README.md`, find the section that lists P15.38 patches and add a new P15.39 subsection. Include:
- What changed (Node 48B → 32B, key split into tag+payload, hash removed)
- Why (cache line 1→2 nodes/line)
- Before/after ratios for affected workloads
- New geomean
- Confirm 29/29 parity preserved

Update the geomean numbers in the "Текущий статус" section at the top of README (currently "3.74×").

- [ ] **Step 9: Update P15.34 checkboxes**

In README, under "P15.34 — compact tables", there are two open checkboxes that this work closes:

Before:
```
- [ ] Уплотнить chain metadata и исключить дублирующие key/tag fields. (частично
  закрыто P15.37b — `dead_key` packed в `hash`, но `key`/`value` всё еще 16 B каждая)
- [ ] Специализированные integer и interned-string lookup/insert paths.
```

After (mark first one complete, update the parenthetical):
```
- [x] Уплотнить chain metadata и исключить дублирующие key/tag fields.
  **P15.39:** `key: Value` (16 B) split into `key_tt: NodeKeyTag` (1 B) +
  `key_val: NodeKeyPayload` (8 B). `hash: u64` field removed (recomputed on
  demand like PUC). Node 48 B → 32 B; two full nodes per 64 B cache line.
- [ ] Специализированные integer и interned-string lookup/insert paths.
```

- [ ] **Step 10: Final commit**

```bash
git add README.md tools/perf/baseline-p15.37.json
git commit -m "docs: P15.39 Node 32B — update README with results + close P15.34 checkbox"
```

---

## Risk register

1. **`extern union` Zig quirk:** If `NodeKeyPayload` ends up >8 B (e.g. due to Zig adding padding for a particular variant), the whole layout shifts. Mitigation: comptime size assertion in Step 6 catches this at build time.

2. **Dead-key regression:** `gc.lua` and `gengc.lua` exercise weak tables with GC'd string keys. If `deadenStringKey` is wrong (e.g. leaves the string pointer alive in `key_val`), the GC will mark a dead object → use-after-free. Mitigation: `markDeadKey` clears `key_val` to `{ .int = 0 }`.

3. **Hash determinism:** Without a cached hash, every `nodeInsert`/`nodeLookup` recomputes from the key. If `hashInt`/`hashNum`/etc. give different results than the original `keyHash(Value)`, chain positions break silently. Mitigation: the existing `keyHash(Value, seed)` switch is replaced by the same branches in `Node.rawHash(seed)` — they call the same underlying helpers (`hashInt`, `hashPointer`, `s.hash`). The only new helper is `hashNum`, which mirrors `hashInt` exactly.

4. **Brent-chain bug:** The eviction policy in `nodeInsert` is subtle. The refactor in Task 5 Step 4 must preserve the `other_idx != mp_idx` branch logic exactly. Mitigation: the existing `nodeInsert/lookup stress: all keys findable under collisions` unit test exercises both branches; the full 29/29 upstream matrix (esp. `nextvar.lua`) catches any chain corruption.

5. **GC perf regression possible:** Reading `key_val.string` directly (instead of `node.key.String` from a reconstructed `Value`) skips one indirection — should be faster, but if the Zig compiler chooses a worse register allocation, it could regress. Mitigation: Task 6 Step 6 perf measurement catches this; if `hash_access` regresses, revert the direct `key_val` reads in vm.zig GC paths to `node.getKey()` first.

## Self-review notes

- **Spec coverage:** The goal is "shrink Node 48→32 B". Tasks 1-5 do the migration atomically (Tasks 1-4 are no-op refactors that keep the old layout; Task 5 swaps it). Task 6 verifies.
- **Placeholder scan:** No "TODO" / "add error handling" — every step has the full code.
- **Type consistency:** `NodeKeyTag`, `NodeKeyPayload`, `NodeKeyTag.empty/dead/int/num/string/table/closure/thread/bool_` are used consistently. Method names `getKey`/`setKey`/`isDeadKey`/`markDeadKey`/`rawHash`/`isEmpty`/`nextNode` are consistent.
