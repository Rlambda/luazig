# P15.66: PUC-faithful Table Rehash + NEWTABLE Hints

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `nextvar.lua:41` pass by implementing PUC-faithful table rehash (`computesizes`/`numusearray`/`numusehash`/`luaH_resize`), replacing eager array extension with PUC's rehash-on-overflow model, adding NEWTABLE size hints in codegen, and implementing PUC `luaH_getn` for the length operator.

**Architecture:** Replace `Table.array: std.ArrayListUnmanaged(Value)` with `Table.array: []Value` + explicit `asize: u32` + `lenhint: u32` fields, mirroring PUC's `Table` struct (`t->asize`, `*lenhint(t)`). Add PUC rehash primitives to `ltable.zig` as pure functions. Implement `tableResize`/`tableRehash` in `vm.zig`. Backpatch NEWTABLE instructions in codegen with array/hash size hints. Rewrite `rawSet` to use PUC `luaH_newkey` flow (insertkey → rehash → newcheckedkey). Replace `tableBorderLen` with PUC `luaH_getn`.

**Tech Stack:** Zig (master), PUC Lua 5.5.0 as reference (`lua-5.5.0/src/ltable.c`, `lparser.c`, `lcode.c`, `lvm.c`, `lobject.c`).

---

## File Structure

### Files to Modify

- **`src/lua/ltable.zig`** — Add PUC rehash primitives: `ceilLog2`, `Counters`, `arrayIndex`, `countInt`, `numUseArray`, `numUseHash`, `computeSizes`. Pure functions with unit tests.
- **`src/lua/vm.zig`** — Core changes:
  - `Table` struct (line ~1458): `array` field type change, add `asize`/`lenhint`.
  - `rawSet` (line ~17898): PUC `luaH_newkey` flow.
  - `tableBorderLen` (line ~24006): PUC `luaH_getn`.
  - `opSetlist` (line ~8460): direct array writes + `tableResizeArray`.
  - `OP_NEWTABLE` handler (line ~7004): read hints, call `tableResize`.
  - `builtinTestcQuerytab` (line ~25426): return `asize` not `capacity`.
  - `builtinTableCreate` (line ~23308): use `tableResize`.
  - GC traversal (lines ~12656, ~13544, ~13896, ~14192, ~14553, ~14733): `array.capacity` → `asize`, `array.items` → `array`.
  - Vararg table creation (line ~8345): `array.append` → `tableResizeArray` + direct write.
  - `appendTableArrayValue` (line ~2781): remove.
  - `noteTableArrayOomContext` (line ~2775): update to use `asize`.
  - `getBytecodeVarargTable` (line ~2260): `array.items.len` → `asize`.
  - `testcMaterializeDeferredVarargTable` (line ~3129): `array.items.len` → `asize`.
- **`src/lua/codegen_bc.zig`** — `genTable` (line ~3104): count `na`/`nh`, backpatch NEWTABLE instruction with size hints.
- **`src/lua/bytecode.zig`** — NEWTABLE instruction format documentation update (line ~120).

### Files to Create

- None. All changes are in existing files.

### Test Files

- Unit tests inline in `ltable.zig` (Zig `test` blocks).
- Codegen tests in `codegen_bc.zig` test section.
- Integration: `lua-5.5.0/testes/nextvar.lua` via `tools/testc_lane.py`.
- Regression: `tools/testes_matrix.py` + `tests/smoke/`.

---

## Reference: PUC Source Locations

All line numbers refer to `lua-5.5.0/src/`:

| Function | File:Line | Purpose |
|---|---|---|
| `luaO_ceillog2` | `lobject.c:37` | ceil(log2(x)) |
| `arrayindex` | `ltable.c:319` | Check if key is valid array index |
| `countint` | `ltable.c:470` | Count an int key into Counters |
| `numusearray` | `ltable.c:488` | Count keys in array part |
| `numusehash` | `ltable.c:521` | Count keys in hash part |
| `computesizes` | `ltable.c:446` | Compute optimal array size |
| `rehash` | `ltable.c:762` | Top-level rehash |
| `luaH_resize` | `ltable.c:716` | Joint array+hash resize |
| `luaH_resizearray` | `ltable.c:751` | Array-only resize |
| `insertkey` | `ltable.c:859` | Brent's variation insert |
| `newcheckedkey` | `ltable.c:902` | Insert into resized table |
| `luaH_newkey` | `ltable.c:914` | Top-level set (insertkey → rehash → newcheckedkey) |
| `luaH_getn` | `ltable.c:1301` | Length operator (border search) |
| `hash_search` | `ltable.c:1239` | Binary search in hash part |
| `binsearch` | `ltable.c:1271` | Binary search in array part |
| `luaK_settablesize` | `lcode.c:1874` | Backpatch NEWTABLE with sizes |
| `constructor` | `lparser.c:1028` | Table constructor parsing (counts na/nh) |
| `OP_NEWTABLE` VM | `lvm.c:1407` | Read hints, call luaH_resize |
| `OP_SETLIST` VM | `lvm.c:1901` | Direct array writes |

## Constants

```
MAXABITS = 31  (l_numbits(int) - 1 = 32 - 1)
MAXASIZE = 2^31 = 2147483648
MAXHBITS = 30  (MAXABITS - 1)
MAXHSIZE = 2^30
```

---

## Task 1: Add PUC rehash primitives to `ltable.zig`

**Files:**
- Modify: `src/lua/ltable.zig` (add functions after existing `rehash` function, before tests)

- [ ] **Step 1: Write failing tests for `ceilLog2`**

Add to `src/lua/ltable.zig` (after the existing `rehash` test block, before the end of file):

```zig
test "ceilLog2: PUC luaO_ceillog2 reference values" {
    // PUC: ceil(log2(x)) = smallest n such that x <= (1 << n)
    // luaO_ceillog2(1) = 0, (2) = 1, (3) = 2, (4) = 2, (5) = 3, (256) = 8, (257) = 9
    try std.testing.expectEqual(@as(u8, 0), ceilLog2(1));
    try std.testing.expectEqual(@as(u8, 1), ceilLog2(2));
    try std.testing.expectEqual(@as(u8, 2), ceilLog2(3));
    try std.testing.expectEqual(@as(u8, 2), ceilLog2(4));
    try std.testing.expectEqual(@as(u8, 3), ceilLog2(5));
    try std.testing.expectEqual(@as(u8, 8), ceilLog2(256));
    try std.testing.expectEqual(@as(u8, 9), ceilLog2(257));
    try std.testing.expectEqual(@as(u8, 30), ceilLog2(1 << 30));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: FAIL — `ceilLog2` undefined.

- [ ] **Step 3: Implement `ceilLog2`**

Add to `src/lua/ltable.zig` (before the test section, after the existing `rehash` function):

```zig
/// PUC `luaO_ceillog2` (lobject.c:37). Computes ceil(log2(x)), the smallest
/// integer n such that x <= (1 << n). Used by `computesizes` and `hash_search`.
/// PUC uses a 256-entry lookup table for the low byte; we use a builtin
/// that the Zig optimizer reduces to a single `lzcnt`/`bsr` instruction.
pub fn ceilLog2(x: u32) u8 {
    if (x == 0) return 0;
    // Zig's @intCast is safe: log2 of any u32 fits in u8 (max 31).
    // PUC does x-- then looks up; mathematically equivalent to ceil(log2(x)).
    const xp = x - 1;
    if (xp == 0) return 0;
    return @intCast(32 - @clz(xp));
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: PASS.

- [ ] **Step 5: Write failing tests for `Counters` + `arrayIndex` + `countInt`**

Add to `src/lua/ltable.zig`:

```zig
test "arrayIndex: valid array indices return the index, others return 0" {
    // PUC arrayindex(k) = checkrange(k, MAXASIZE)
    // Returns k if 1 <= k <= MAXASIZE, else 0.
    try std.testing.expectEqual(@as(u32, 0), arrayIndex(0));
    try std.testing.expectEqual(@as(u32, 1), arrayIndex(1));
    try std.testing.expectEqual(@as(u32, 0), arrayIndex(-1));
    try std.testing.expectEqual(@as(u32, 100), arrayIndex(100));
    try std.testing.expectEqual(@as(u32, 0), arrayIndex(std.math.maxInt(i64)));
}

test "countInt: distributes integer keys into bit-buckets" {
    var ct = Counters{};
    // Key 1: arrayindex=1, ceilLog2(1)=0 → nums[0]
    countInt(1, &ct);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[0]);
    try std.testing.expectEqual(@as(u32, 1), ct.na);
    // Key 2: arrayindex=2, ceilLog2(2)=1 → nums[1]
    countInt(2, &ct);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[1]);
    try std.testing.expectEqual(@as(u32, 2), ct.na);
    // Key 3: arrayindex=3, ceilLog2(3)=2 → nums[2]
    countInt(3, &ct);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[2]);
    try std.testing.expectEqual(@as(u32, 3), ct.na);
    // Key 5: arrayindex=5, ceilLog2(5)=3 → nums[3]
    countInt(5, &ct);
    try std.testing.expectEqual(@as(u32, 1), ct.nums[3]);
    try std.testing.expectEqual(@as(u32, 4), ct.na);
    // Non-array key (negative): no change
    countInt(-1, &ct);
    try std.testing.expectEqual(@as(u32, 4), ct.na);
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: FAIL — `Counters`, `arrayIndex`, `countInt` undefined.

- [ ] **Step 7: Implement `Counters`, `arrayIndex`, `countInt`**

Add to `src/lua/ltable.zig`:

```zig
/// PUC MAXABITS = l_numbits(int) - 1 = 31. The largest integer such that
/// 2^MAXABITS fits in an unsigned int.
pub const MAXABITS: usize = 31;

/// PUC MAXASIZE: maximum size of the array part.
pub const MAXASIZE: u32 = 1 << MAXABITS;

/// PUC `Counters` (ltable.c:421-426). Used during rehash to count integer
/// keys by bit-buckets: `nums[i]` = count of keys in range (2^(i-1), 2^i].
pub const Counters = struct {
    nums: [MAXABITS + 1]u32 = [_]u32{0} ** (MAXABITS + 1),
    na: u32 = 0,    // total number of array indices
    total: u32 = 0, // total number of non-deleted entries
    deleted: u32 = 0, // 1 if any deleted entry found in hash part
};

/// PUC `arrayindex` (ltable.c:319). Returns the index `k` (converted to
/// unsigned) if it is inside [1, MAXASIZE], else 0.
pub fn arrayIndex(k: i64) u32 {
    const ku: u64 = @bitCast(k);
    if (ku == 0) return 0; // key <= 0
    if (ku > MAXASIZE) return 0;
    return @intCast(ku);
}

/// PUC `countint` (ltable.c:470). If `key` is a valid array index, count it
/// into the appropriate bit-bucket in `ct`.
pub fn countInt(key: i64, ct: *Counters) void {
    const k = arrayIndex(key);
    if (k != 0) {
        ct.nums[ceilLog2(k)] += 1;
        ct.na += 1;
    }
}
```

- [ ] **Step 8: Run test to verify it passes**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: PASS.

- [ ] **Step 9: Write failing test for `numUseArray`**

Add to `src/lua/ltable.zig`:

```zig
test "numUseArray: counts live keys in array part by bit-bucket" {
    // Array: [10, 20, nil, 40] — 3 live keys (nil is a hole)
    const alloc = std.testing.allocator;
    const arr = try alloc.alloc(Value, 4);
    defer alloc.free(arr);
    arr[0] = .{ .Int = 10 };
    arr[1] = .{ .Int = 20 };
    arr[2] = .Nil;
    arr[3] = .{ .Int = 40 };

    var ct = Counters{};
    numUseArray(arr, &ct);
    // Keys 1,2,4 are live. ceilLog2(1)=0, ceilLog2(2)=1, ceilLog2(4)=2.
    try std.testing.expectEqual(@as(u32, 1), ct.nums[0]); // key 1
    try std.testing.expectEqual(@as(u32, 1), ct.nums[1]); // key 2
    try std.testing.expectEqual(@as(u32, 1), ct.nums[2]); // key 4
    try std.testing.expectEqual(@as(u32, 3), ct.na);
    try std.testing.expectEqual(@as(u32, 3), ct.total);
}
```

- [ ] **Step 10: Run test to verify it fails**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: FAIL — `numUseArray` undefined.

- [ ] **Step 11: Implement `numUseArray`**

Add to `src/lua/ltable.zig`:

```zig
/// PUC `numusearray` (ltable.c:488). Count keys in the array part of a table.
/// A slot is "empty" if it holds `.Nil` (PUC's `tagisempty`). Traverses each
/// bit-bucket slice (2^(lg-1), 2^lg] and tallies live entries into `ct.nums`.
pub fn numUseArray(array: []const Value, ct: *Counters) void {
    var i: usize = 1; // 1-based index, PUC convention
    var lg: usize = 0;
    while (lg <= MAXABITS) : (lg += 1) {
        var lim: usize = @as(usize, 1) << @intCast(lg);
        if (lim > array.len) {
            lim = array.len;
            if (i > lim) break; // no more elements
        }
        var lc: u32 = 0;
        while (i <= lim) : (i += 1) {
            if (array[i - 1] != .Nil) lc += 1;
        }
        ct.nums[lg] += lc;
        ct.na += lc;
        ct.total += lc;
    }
}
```

- [ ] **Step 12: Run test to verify it passes**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: PASS.

- [ ] **Step 13: Write failing test for `numUseHash`**

Add to `src/lua/ltable.zig`:

```zig
test "numUseHash: counts live hash entries and detects deleted" {
    const alloc = std.testing.allocator;
    const nodes = try alloc.alloc(Node, 4);
    defer alloc.free(nodes);
    for (nodes) |*n| n.* = .{};
    var lastfree: usize = nodes.len;
    // Insert int keys 5, 100, 129 into hash
    _ = nodeInsert(nodes, &lastfree, .{ .Int = 5 }, .{ .Int = 50 }, 0);
    _ = nodeInsert(nodes, &lastfree, .{ .Int = 100 }, .{ .Int = 1000 }, 0);
    _ = nodeInsert(nodes, &lastfree, .{ .Int = 129 }, .{ .Int = 1290 }, 0);
    // Delete key 100
    _ = nodeDelete(nodes, .{ .Int = 100 }, 0);

    var ct = Counters{};
    numUseHash(nodes, &ct);
    // 2 live entries (5, 129), 1 deleted
    try std.testing.expectEqual(@as(u32, 2), ct.total);
    try std.testing.expectEqual(@as(u32, 1), ct.deleted);
    // countint should have distributed: key 5 → nums[3], key 129 → nums[8]
    try std.testing.expectEqual(@as(u32, 1), ct.nums[3]); // ceilLog2(5)=3
    try std.testing.expectEqual(@as(u32, 1), ct.nums[8]); // ceilLog2(129)=8
}
```

- [ ] **Step 14: Run test to verify it fails**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: FAIL — `numUseHash` undefined.

- [ ] **Step 15: Implement `numUseHash`**

Add to `src/lua/ltable.zig`:

```zig
/// PUC `numusehash` (ltable.c:521). Count keys in the hash part. During a
/// rehash, all nodes have been used (no empty slots except from deletes).
/// A node with `value == .Nil` is a deleted entry — sets `ct.deleted`.
/// Live integer keys are counted via `countInt`.
pub fn numUseHash(hash: []const Node, ct: *Counters) void {
    var i = hash.len;
    while (i > 0) {
        i -= 1;
        const n = &hash[i];
        if (n.value == .Nil) {
            // Deleted entry (PUC asserts key is not nil — it was created then deleted)
            if (n.key_tt != .empty) ct.deleted = 1;
        } else {
            ct.total += 1;
            if (n.key_tt == .int) {
                countInt(n.key_val.int, ct);
            }
        }
    }
}
```

- [ ] **Step 16: Run test to verify it passes**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: PASS.

- [ ] **Step 17: Write failing test for `computeSizes`**

Add to `src/lua/ltable.zig`:

```zig
test "computeSizes: nextvar.lua:41 scenario — keys 1-100 + 129" {
    // Simulate the rehash triggered by inserting a[129] into a table
    // that has keys 1-4 and 96-100 in the array, 129 in hash.
    // PUC computesizes finds optimal asize=4 (keys 5-95 were deleted).
    var ct = Counters{};
    // Extra key (129) — countint during rehash
    countInt(129, &ct);
    // numUseHash would count 129 again, but for this test we simulate
    // the state after numusehash: 129 is in hash, na from array.
    // Actually, let's simulate the full rehash state:
    // Array has keys 1,2,3,4,96,97,98,99,100 (asize=128, holes 5-95).
    // Hash has key 129.
    ct = Counters{};
    ct.total = 1; // extra key (129)
    countInt(129, &ct); // 129 → nums[8], na=1
    // numusearray on asize=128 array with keys 1,2,3,4,96-100:
    var ct2 = Counters{};
    ct2.total = 1;
    countInt(129, &ct2);
    // Manually set nums as if numusearray ran on [1,2,3,4,nil,...,nil,96,97,98,99,100]
    // Keys 1-4: nums[0]=1, nums[1]=1, nums[2]=2 (keys 3,4)
    // Keys 96-100: all in range (64,128] → nums[7]
    ct2.nums[0] = 1; // key 1
    ct2.nums[1] = 1; // key 2
    ct2.nums[2] = 2; // keys 3,4
    ct2.nums[7] = 5; // keys 96-100
    ct2.na = 1 + 9; // 129 (from countint) + 9 array keys
    ct2.total = 1 + 9; // 129 + 9 array keys
    const asize = computeSizes(&ct2);
    // PUC returns 4: keys 1-4 go to array (asize=4), rest to hash.
    try std.testing.expectEqual(@as(u32, 4), asize);
    try std.testing.expectEqual(@as(u32, 4), ct2.na); // na updated to 4
}

test "computeSizes: all keys 1-100 → asize=128" {
    // Keys 1-100: PUC computesizes returns 128 (best power-of-2).
    var ct = Counters{};
    for (1..101) |k| countInt(@intCast(k), &ct);
    ct.total = ct.na; // all keys are array indices
    const asize = computeSizes(&ct);
    try std.testing.expectEqual(@as(u32, 128), asize);
}
```

- [ ] **Step 18: Run test to verify it fails**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: FAIL — `computeSizes` undefined.

- [ ] **Step 19: Implement `computeSizes`**

Add to `src/lua/ltable.zig`:

```zig
/// PUC `arrayXhash` (ltable.c:435). A hash node uses ~3x more memory than an
/// array entry (two Values + next vs one Value). Returns true if using `na`
/// array entries instead of `nh` hash nodes uses "less or equal" memory.
inline fn arrayXhash(na: u32, nh: u32) bool {
    return @as(u64, na) <= @as(u64, nh) * 3;
}

/// PUC `computesizes` (ltable.c:446). Compute the optimal size for the array
/// part. Maximizes the number of elements going to the array part while
/// satisfying `arrayXhash`. `ct.na` enters with the total number of array
/// indices and leaves with the number of keys that WILL go to the array part.
/// Returns the optimal size (a power of 2).
pub fn computeSizes(ct: *Counters) u32 {
    var a: u32 = 0; // number of elements smaller than 2^i
    var na: u32 = 0; // number of elements to go to array part
    var optimal: u32 = 0;
    var i: usize = 0;
    var twotoi: u32 = 1;
    while (twotoi > 0 and arrayXhash(twotoi, ct.na)) : ({
        i += 1;
        twotoi *|= 2;
    }) {
        const nums = ct.nums[i];
        a += nums;
        if (nums > 0 and arrayXhash(twotoi, a)) {
            optimal = twotoi;
            na = a;
        }
    }
    ct.na = na;
    return optimal;
}
```

- [ ] **Step 20: Run test to verify it passes**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: PASS.

- [ ] **Step 21: Commit**

```bash
cd /home/boss/codes/luazig
git add src/lua/ltable.zig
git commit -m "P15.66: add PUC rehash primitives to ltable.zig (ceilLog2, Counters, numUseArray/Hash, computeSizes)"
```

---

## Task 2: Migrate `Table.array` from `ArrayList` to `[]Value` + `asize`

**Files:**
- Modify: `src/lua/vm.zig` — `Table` struct (line ~1458), all call sites using `.array.*`

This is a mechanical migration. The `Table.array` field changes type, and `asize`/`lenhint` fields are added. All `.array.items` become `.array`, `.array.items.len` becomes `.asize`, `.array.capacity` becomes `.asize`, `.array.append`/`ensureTotalCapacity` are removed (replaced by `tableResize` in later tasks), `.array.deinit` becomes `alloc.free`.

- [ ] **Step 1: Change `Table` struct fields**

In `src/lua/vm.zig`, find the `Table` struct (line ~1458) and replace:

```zig
    // Array part: keys 1..n stored contiguously. A nil entry inside the array
    // is a "hole"; next()/length skip holes by scanning. Untouched by this
    // refactor — all `.array` / `.array.items` call sites stay valid.
    array: std.ArrayListUnmanaged(Value) = .empty,
```

with:

```zig
    // PUC-faithful array part. `array` is a slice of `asize` Values, where
    // `asize` is the logical array size (PUC `t->asize`). A nil entry inside
    // the array is a "hole"; next()/length skip holes by scanning.
    // `asize` may be larger than the number of populated slots (trailing nils
    // are valid holes). Capacity == asize in the PUC model (no over-allocation).
    array: []Value = &[_]Value{},
    asize: u32 = 0,

    // PUC `*lenhint(t)` — cached border hint for the length operator.
    // Set to asize/2 after resize, updated by luaH_getn. Speeds up repeated
    // `#t` calls for the common `t[#t+1] = v` pattern.
    lenhint: u32 = 0,
```

- [ ] **Step 2: Update `Table.deinit`**

In `src/lua/vm.zig`, find `Table.deinit` (line ~1504) and replace:

```zig
    pub fn deinit(self: *Table, alloc: std.mem.Allocator) void {
        self.array.deinit(alloc);
        if (self.hash.len != 0) alloc.free(self.hash);
    }
```

with:

```zig
    pub fn deinit(self: *Table, alloc: std.mem.Allocator) void {
        if (self.array.len != 0) alloc.free(self.array);
        if (self.hash.len != 0) alloc.free(self.hash);
    }
```

- [ ] **Step 3: Update `noteTableArrayOomContext`**

In `src/lua/vm.zig` (line ~2775), replace:

```zig
    fn noteTableArrayOomContext(self: *Vm, tbl: *const Table, context: []const u8) void {
        self.oom_context = context;
        self.oom_table_array_len = tbl.array.items.len;
        self.oom_table_array_capacity = tbl.array.capacity;
    }
```

with:

```zig
    fn noteTableArrayOomContext(self: *Vm, tbl: *const Table, context: []const u8) void {
        self.oom_context = context;
        self.oom_table_array_len = tbl.asize;
        self.oom_table_array_capacity = tbl.asize;
    }
```

- [ ] **Step 4: Remove `appendTableArrayValue`**

In `src/lua/vm.zig` (line ~2781), delete the entire `appendTableArrayValue` function:

```zig
    fn appendTableArrayValue(self: *Vm, tbl: *Table, val: Value) DispatchError!void {
        if (tbl.array.items.len >= tbl.array.capacity) {
            self.noteTableArrayOomContext(tbl, "table array grow");
            const current = tbl.array.capacity;
            const next = if (current < 8) 8 else current *| 2;
            try tbl.array.ensureTotalCapacityPrecis(self.alloc, next);
        }
        tbl.array.appendAssumeCapacity(val);
    }
```

Replace all call sites (lines ~17933, ~17945) with calls to `tableResizeArray` (to be implemented in Task 3). For now, to keep the build compiling, replace the function body with a temporary stub that calls `tableResizeArray`:

Actually, since `tableResizeArray` doesn't exist yet, we need to implement it first. Let's defer removing `appendTableArrayValue` to Task 3. For now, just update it to use the new field names:

```zig
    fn appendTableArrayValue(self: *Vm, tbl: *Table, val: Value) DispatchError!void {
        // Temporary: will be replaced by tableResizeArray in Task 3.
        const new_asize = tbl.asize + 1;
        try self.tableResizeArray(tbl, new_asize);
        tbl.array[new_asize - 1] = val;
    }
```

Wait — `tableResizeArray` doesn't exist yet. Let's keep `appendTableArrayValue` working with the old logic but adapted to `[]Value`:

```zig
    fn appendTableArrayValue(self: *Vm, tbl: *Table, val: Value) DispatchError!void {
        // Temporary: grow array by doubling. Will be replaced by PUC
        // tableResizeArray in Task 3.
        const old_asize = tbl.asize;
        const new_asize = if (old_asize == 0) 1 else old_asize *| 2;
        const new_array = try self.alloc.alloc(Value, new_asize);
        @memcpy(new_array[0..old_asize], tbl.array[0..old_asize]);
        for (new_array[old_asize..]) |*slot| slot.* = .Nil;
        if (tbl.array.len != 0) self.alloc.free(tbl.array);
        tbl.array = new_array;
        tbl.asize = new_asize;
        tbl.array[old_asize] = val;
    }
```

- [ ] **Step 5: Update all `.array.items` → `.array` and `.array.items.len` → `.asize`**

Run this search-and-replace across `src/lua/vm.zig`. The mechanical replacements:

| Old | New |
|---|---|
| `tbl.array.items.len` | `tbl.asize` |
| `tbl.array.items[` | `tbl.array[` |
| `tbl.array.capacity` | `tbl.asize` |
| `tbl.array.items` (in for loops) | `tbl.array` |
| `t.array.items.len` | `t.asize` |
| `t.array.items[` | `t.array[` |
| `t.array.capacity` | `t.asize` |
| `table.array.capacity` | `table.asize` |
| `table.array.items` | `table.array` |

Use `rg` to find all occurrences and update each one:

```bash
cd /home/boss/codes/luazig
rg -n '\.array\.items' src/lua/vm.zig
rg -n '\.array\.capacity' src/lua/vm.zig
```

Update each occurrence. The `for (tbl.array.items)` patterns become `for (tbl.array)`.

- [ ] **Step 6: Update `getBytecodeVarargTable` (line ~2260)**

Replace `var n: usize = tbl.array.items.len;` with `var n: usize = tbl.asize;`

- [ ] **Step 7: Update `testcMaterializeDeferredVarargTable` (line ~3129)**

Replace `try self.testcChargeMemory(@max(tbl.array.items.len, 1) * @sizeOf(Value));` with `try self.testcChargeMemory(@max(tbl.asize, 1) * @sizeOf(Value));`

- [ ] **Step 8: Update GC size accounting (lines ~12656, ~13544, ~13896)**

Replace all occurrences of:
```zig
@sizeOf(Table) + table.array.capacity * @sizeOf(Value) + table.hash.len * @sizeOf(ltable.Node)
```
with:
```zig
@sizeOf(Table) + table.asize * @sizeOf(Value) + table.hash.len * @sizeOf(ltable.Node)
```

- [ ] **Step 9: Update GC traversal (lines ~14192, ~14553, ~14733)**

Replace `for (tbl.array.items)` with `for (tbl.array)` in:
- `gcMarkValue` hash traversal (line ~14192)
- `gcPruneWeakValues` (line ~14553)
- `gcMarkTableFinalizerReach` (line ~14733)

- [ ] **Step 10: Update `opSetlist` (line ~8485-8503)**

Replace the fast path that uses `ensureTotalCapacity` + `appendAssumeCapacity`:

```zig
            if (tbl.metatable == null) {
                const start = base_idx;
                const end = base_idx + @as(u32, @intCast(count));
                // Extend array part if needed (PUC: luaH_resizearray).
                if (end > tbl.array.items.len) {
                    try tbl.array.ensureTotalCapacity(self.alloc, end);
                    // Fill gap (if any) with Nil to maintain array invariants.
                    while (tbl.array.items.len < end) {
                        tbl.array.appendAssumeCapacity(.Nil);
                    }
                }
                // Direct writes (PUC: obj2arr).
                for (0..count) |i| {
                    const idx = start + i;
                    tbl.array.items[idx] = ctx.regs[a + 1 + i];
                    // PUC backward barrier on the table being written to.
                    try self.gcWriteBarrierTable(tbl, ctx.regs[a + 1 + i]);
                }
                tbl.flags &= ~TableFlags.MASK;
            }
```

with (temporary — will be properly rewritten in Task 5):

```zig
            if (tbl.metatable == null) {
                const start = base_idx;
                const end = base_idx + @as(u32, @intCast(count));
                // Extend array part if needed (PUC: luaH_resizearray).
                if (end > tbl.asize) {
                    try self.tableResizeArray(tbl, end);
                }
                // Direct writes (PUC: obj2arr).
                for (0..count) |i| {
                    const idx = start + i;
                    tbl.array[idx] = ctx.regs[a + 1 + i];
                    // PUC backward barrier on the table being written to.
                    try self.gcWriteBarrierTable(tbl, ctx.regs[a + 1 + i]);
                }
                tbl.flags &= ~TableFlags.MASK;
            }
```

Note: `tableResizeArray` will be implemented in Task 3. For now, to keep the build working, add a temporary stub near `appendTableArrayValue`:

```zig
    /// Temporary stub — replaced by PUC-faithful implementation in Task 3.
    fn tableResizeArray(self: *Vm, tbl: *Table, new_asize: u32) DispatchError!void {
        if (new_asize == tbl.asize) return;
        const new_array = try self.alloc.alloc(Value, new_asize);
        const copy_len = @min(tbl.asize, new_asize);
        @memcpy(new_array[0..copy_len], tbl.array[0..copy_len]);
        for (new_array[copy_len..]) |*slot| slot.* = .Nil;
        if (tbl.array.len != 0) self.alloc.free(tbl.array);
        tbl.array = new_array;
        tbl.asize = new_asize;
    }
```

- [ ] **Step 11: Update vararg table creation (line ~8345)**

Replace:
```zig
                            for (va_slice) |v| {
                                try t.array.append(self.alloc, v);
                            }
```
with:
```zig
                            try self.tableResizeArray(t, @intCast(va_slice.len));
                            for (va_slice, 0..) |v, i| {
                                t.array[i] = v;
                            }
```

- [ ] **Step 12: Update `builtinTableCreate` (line ~23308-23323)**

Replace:
```zig
        const t = try self.allocTable();
        if (narray != 0) try t.array.ensureTotalCapacity(self.alloc, narray);
        // Approximate allocation accounting used by tests through collectgarbage("count").
        self.gcNoteAlloc(narray * 8 + nhash * 16);
        outs[0] = .{ .Table = t };
```
with:
```zig
        const t = try self.allocTable();
        if (narray != 0 or nhash != 0) {
            try self.tableResize(t, narray, nhash);
        }
        // Approximate allocation accounting used by tests through collectgarbage("count").
        self.gcNoteAlloc(narray * 8 + nhash * 16);
        outs[0] = .{ .Table = t };
```

Note: `tableResize` will be implemented in Task 3. For now, add a temporary stub that calls `tableResizeArray` for the array part and allocates hash:

```zig
    /// Temporary stub — replaced by PUC-faithful implementation in Task 3.
    fn tableResize(self: *Vm, tbl: *Table, new_asize: u32, new_hsize: u32) DispatchError!void {
        try self.tableResizeArray(tbl, new_asize);
        if (new_hsize > 0 and tbl.hash.len == 0) {
            tbl.hash = try self.alloc.alloc(ltable.Node, new_hsize);
            for (tbl.hash) |*n| n.* = .{};
            tbl.hash_lastfree = tbl.hash.len;
        }
    }
```

- [ ] **Step 13: Update `builtinTestcQuerytab` (line ~25431)**

Replace:
```zig
        const asize: i64 = @intCast(tbl.array.capacity);
```
with:
```zig
        const asize: i64 = @intCast(tbl.asize);
```

And replace (line ~25442):
```zig
            if (outs.len > 2) outs[2] = .{ .Int = if (asize > 0) @as(i64, @intCast(tbl.array.items.len)) else 0 };
```
with:
```zig
            if (outs.len > 2) outs[2] = .{ .Int = if (tbl.asize > 0) @as(i64, @intCast(tbl.lenhint)) else 0 };
```

And replace (line ~25463):
```zig
        if (i < tbl.array.items.len) {
            if (outs.len > 0) outs[0] = .{ .Int = @intCast(i) };
            if (outs.len > 1) outs[1] = tbl.array.items[i];
```
with:
```zig
        if (i < tbl.asize) {
            if (outs.len > 0) outs[0] = .{ .Int = @intCast(i) };
            if (outs.len > 1) outs[1] = tbl.array[i];
```

And replace (line ~25472):
```zig
        const hash_idx = i - tbl.array.items.len;
```
with:
```zig
        const hash_idx = i - tbl.asize;
```

- [ ] **Step 14: Update remaining `.array.items` references**

Find and update any remaining references:

```bash
cd /home/boss/codes/luazig
rg -n '\.array\.items|\.array\.capacity|\.array\.append|\.array\.deinit|\.array\.ensureTotalCapacity' src/lua/vm.zig
```

For each remaining hit:
- `keys.array.items` (line ~17806, ~17816, ~17817) — these are on a different table (`keys`), update similarly.
- `fmts_tbl.array.items` (line ~18914, ~18915) — update similarly.
- `fmt_tbl.?.array.items` (line ~18962, ~18966) — update similarly.
- `upv.Table.array.items` (line ~24920) — update similarly.
- `v.Table.array.items.len` (line ~27442) — update to `v.Table.asize`.

- [ ] **Step 15: Build and verify compilation**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | head -40`
Expected: Compiles successfully (may have warnings, but no errors).

- [ ] **Step 16: Run unit tests**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: PASS.

- [ ] **Step 17: Run smoke tests**

Run: `cd /home/boss/codes/luazig && for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 && echo "OK: $f" || echo "FAIL: $f"; done`
Expected: All 45 smoke tests pass.

- [ ] **Step 18: Run matrix tests**

Run: `cd /home/boss/codes/luazig && python3 tools/testes_matrix.py 2>&1 | tail -20`
Expected: 28/31 (no regressions from baseline).

- [ ] **Step 19: Commit**

```bash
cd /home/boss/codes/luazig
git add src/lua/vm.zig
git commit -m "P15.66: migrate Table.array from ArrayList to []Value + asize/lenhint fields"
```

---

## Task 3: Implement `tableResize` and `tableRehash` in `vm.zig`

**Files:**
- Modify: `src/lua/vm.zig` — add `tableResize`, `tableRehash`, `tableResizeArray` (real implementations), replace stubs from Task 2.

- [ ] **Step 1: Write failing test for `tableResize` (array grow)**

Add a test block at the end of `src/lua/vm.zig` (or in a test section):

```zig
test "tableResize: grow array part preserves existing values" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const tbl = try vm.allocTable();
    // Insert keys 1,2,3 via rawSet
    try vm.rawSet(tbl, .{ .Int = 1 }, .{ .Int = 10 });
    try vm.rawSet(tbl, .{ .Int = 2 }, .{ .Int = 20 });
    try vm.rawSet(tbl, .{ .Int = 3 }, .{ .Int = 30 });
    // Resize array to 8
    try vm.tableResize(tbl, 8, 0);
    try std.testing.expectEqual(@as(u32, 8), tbl.asize);
    try std.testing.expectEqual(@as(i64, 10), tbl.array[0].Int);
    try std.testing.expectEqual(@as(i64, 20), tbl.array[1].Int);
    try std.testing.expectEqual(@as(i64, 30), tbl.array[2].Int);
    try std.testing.expect(tbl.array[3] == .Nil); // new slot is nil
    try std.testing.expect(tbl.array[7] == .Nil);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: FAIL (stub doesn't properly handle hash redistribution).

- [ ] **Step 3: Implement PUC-faithful `tableResize`**

In `src/lua/vm.zig`, replace the temporary `tableResize` stub with:

```zig
    /// PUC `luaH_resize` (ltable.c:716). Joint array+hash resize.
    /// 1. Create new hash part (power-of-2 size).
    /// 2. If array shrinks: move vanishing slice keys → new hash.
    /// 3. Allocate new array, copy common elements.
    /// 4. Reinsert old hash entries into new table (array or hash).
    /// 5. Free old parts, swap in new.
    fn tableResize(self: *Vm, tbl: *Table, new_asize: u32, new_hsize: u32) DispatchError!void {
        const old_asize = tbl.asize;

        // 1. Create new hash part.
        var new_hash: []ltable.Node = &[_]ltable.Node{};
        var new_hash_lastfree: usize = 0;
        if (new_hsize > 0) {
            const hsize = @as(usize, 1) << ltable.ceilLog2(new_hsize);
            new_hash = try self.alloc.alloc(ltable.Node, hsize);
            for (new_hash) |*n| n.* = .{};
            new_hash_lastfree = hsize;
        }

        // 2. If array shrinks, move vanishing slice keys into new_hash.
        if (new_asize < old_asize) {
            // Swap in new_hash temporarily so insertkey works on it.
            const old_hash = tbl.hash;
            const old_lastfree = tbl.hash_lastfree;
            tbl.hash = new_hash;
            tbl.hash_lastfree = new_hash_lastfree;
            for (new_asize..old_asize) |i| {
                if (tbl.array[i] != .Nil) {
                    const key: Value = .{ .Int = @intCast(i + 1) };
                    const val = tbl.array[i];
                    // insertkey: guaranteed to succeed (new hash is empty or large enough)
                    const inserted = ltable.nodeInsert(tbl.hash, &tbl.hash_lastfree, key, val, self.hash_seed);
                    std.debug.assert(inserted != null);
                }
            }
            // Restore old hash (in case array alloc fails below — PUC error recovery).
            tbl.hash = old_hash;
            tbl.hash_lastfree = old_lastfree;
        }

        // 3. Allocate new array.
        const new_array: []Value = if (new_asize > 0) blk: {
            const arr = try self.alloc.alloc(Value, new_asize);
            const copy_len = @min(old_asize, new_asize);
            @memcpy(arr[0..copy_len], tbl.array[0..copy_len]);
            for (arr[copy_len..]) |*slot| slot.* = .Nil;
            break :blk arr;
        } else &[_]Value{};

        // 4. Free old array, set new.
        if (tbl.array.len != 0) self.alloc.free(tbl.array);
        tbl.array = new_array;
        tbl.asize = new_asize;

        // 5. Reinsert old hash entries into new table.
        // Swap: tbl gets new_hash, we iterate over old hash.
        const old_hash = tbl.hash;
        const old_lastfree = tbl.hash_lastfree;
        tbl.hash = new_hash;
        tbl.hash_lastfree = new_hash_lastfree;
        for (old_hash) |*n| {
            if (n.key_tt == .empty or n.key_tt == .dead) continue;
            if (n.value == .Nil) continue; // skip deleted
            const key = n.getKey();
            const val = n.value;
            // newcheckedkey: if key is in array range, put in array; else insertkey.
            const k_int = if (key == .Int) key.Int else 0;
            if (k_int >= 1 and @as(u64, @intCast(k_int)) <= new_asize) {
                tbl.array[@intCast(k_int - 1)] = val;
            } else {
                const inserted = ltable.nodeInsert(tbl.hash, &tbl.hash_lastfree, key, val, self.hash_seed);
                std.debug.assert(inserted != null);
            }
        }

        // Free old hash.
        if (old_hash.len != 0) self.alloc.free(old_hash);

        // Set lenhint (PUC: newasize / 2).
        tbl.lenhint = new_asize / 2;
    }
```

- [ ] **Step 4: Implement `tableResizeArray`**

Replace the temporary stub:

```zig
    /// PUC `luaH_resizearray` (ltable.c:751). Resize only the array part,
    /// keeping the hash part at its current size.
    fn tableResizeArray(self: *Vm, tbl: *Table, new_asize: u32) DispatchError!void {
        try self.tableResize(tbl, new_asize, @intCast(tbl.hash.len));
    }
```

- [ ] **Step 5: Implement `tableRehash`**

Add near `tableResize`:

```zig
    /// PUC `rehash` (ltable.c:762). Count keys, compute optimal array+hash
    /// sizes, then resize. `ek` is the extra key that triggered the rehash
    /// (it may or may not be an array index).
    fn tableRehash(self: *Vm, tbl: *Table, ek: Value) DispatchError!void {
        var ct = ltable.Counters{};
        ct.total = 1; // count extra key
        if (ek == .Int) {
            ltable.countInt(ek.Int, &ct);
        }
        ltable.numUseHash(tbl.hash, &ct);
        var asize: u32 = 0;
        if (ct.na > 0) {
            ltable.numUseArray(tbl.array, &ct);
            asize = ltable.computeSizes(&ct);
        } else {
            asize = tbl.asize; // keep array size if no new array keys
        }
        var nsize: u32 = ct.total - ct.na;
        if (ct.deleted > 0) {
            // PUC: give hash some extra size to avoid repeated resizings.
            nsize += nsize >> 2; // +25%
        }
        try self.tableResize(tbl, asize, nsize);
    }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: PASS.

- [ ] **Step 7: Write test for `tableRehash` (nextvar scenario)**

```zig
test "tableRehash: nextvar.lua:41 scenario — keys 1-100, delete 5-95, insert 129" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const tbl = try vm.allocTable();
    // Insert keys 1-100
    for (1..101) |i| {
        try vm.rawSet(tbl, .{ .Int = @intCast(i) }, .{ .Int = @intCast(i) });
    }
    // Delete keys 5-95
    for (5..96) |i| {
        try vm.rawSet(tbl, .{ .Int = @intCast(i) }, .Nil);
    }
    // Insert 129 — triggers rehash
    try vm.rawSet(tbl, .{ .Int = 129 }, .{ .Int = 1 });
    // PUC: asize=4, hash=8
    try std.testing.expectEqual(@as(u32, 4), tbl.asize);
    try std.testing.expectEqual(@as(usize, 8), tbl.hash.len);
    // Verify key placement
    try std.testing.expectEqual(@as(i64, 1), tbl.array[0].Int); // a[1]
    try std.testing.expectEqual(@as(i64, 2), tbl.array[1].Int); // a[2]
    try std.testing.expectEqual(@as(i64, 3), tbl.array[2].Int); // a[3]
    try std.testing.expectEqual(@as(i64, 4), tbl.array[3].Int); // a[4]
    // Keys 96-100 and 129 should be in hash
    const v96 = vm.rawGet(tbl, .{ .Int = 96 });
    try std.testing.expectEqual(@as(i64, 96), v96.Int);
    const v129 = vm.rawGet(tbl, .{ .Int = 129 });
    try std.testing.expectEqual(@as(i64, 1), v129.Int);
}
```

- [ ] **Step 8: Run test — expected to FAIL (rawSet not yet updated)**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: FAIL — `rawSet` still uses eager extension, so `asize` won't be 4.

- [ ] **Step 9: Commit (tableResize/tableRehash implemented, rawSet still old)**

```bash
cd /home/boss/codes/luazig
git add src/lua/vm.zig
git commit -m "P15.66: implement PUC-faithful tableResize/tableRehash (rawSet not yet updated)"
```

---

## Task 4: Rewrite `rawSet` to use PUC `luaH_newkey` flow

**Files:**
- Modify: `src/lua/vm.zig` — `rawSet` function (line ~17898)

- [ ] **Step 1: Rewrite `rawSet`**

Replace the entire `rawSet` function (lines ~17898-17999) with:

```zig
    /// PUC `luaH_set` / `luaH_newkey` (ltable.c:914). Store `val` at `key`.
    /// Integer keys in [1..asize] go directly to the array part.
    /// All other keys go through `insertkey` → rehash on overflow → `newcheckedkey`.
    /// Setting val==.Nil deletes the entry (PUC: don't insert nils).
    fn rawSet(self: *Vm, tbl: *Table, key: Value, val: Value) DispatchError!void {
        try self.gcTableWriteBarrier(tbl, key, val);
        switch (key) {
            .Nil => return self.fail("table key cannot be nil", .{}),
            .Num => |n| {
                if (std.math.isNan(n)) return self.fail("table key cannot be NaN", .{});
                if (std.math.isFinite(n) and
                    n >= -9_223_372_036_854_775_808.0 and
                    n < 9_223_372_036_854_775_808.0 and
                    @floor(n) == n)
                {
                    return self.rawSet(tbl, .{ .Int = @as(i64, @intFromFloat(n)) }, val);
                }
                // Non-integer float key: hash via hashNum.
            },
            else => {},
        }

        // Integer keys in [1..asize] go to the array part (PUC keyinarray).
        if (key == .Int) {
            const k = key.Int;
            if (k >= 1 and @as(u64, @intCast(k)) <= tbl.asize) {
                tbl.array[@intCast(k - 1)] = val;
                return;
            }
        }

        // Hash-part lookup: update existing node, or delete if val==.Nil.
        if (ltable.nodeLookup(tbl.hash, key, self.hash_seed)) |node| {
            if (val == .Nil) {
                _ = ltable.nodeDelete(tbl.hash, key, self.hash_seed);
            } else {
                node.value = val;
            }
            return;
        }
        if (val == .Nil) return; // PUC: deleting an absent key is a no-op.

        // New key: try insertkey. If hash is empty, allocate initial size.
        if (tbl.hash.len == 0) {
            try self.testcChargeMemory(64);
            tbl.hash = try self.alloc.alloc(ltable.Node, 4);
            for (tbl.hash) |*n| n.* = .{};
            tbl.hash_lastfree = tbl.hash.len;
        }

        if (ltable.nodeInsert(tbl.hash, &tbl.hash_lastfree, key, val, self.hash_seed)) |_| {
            tbl.flags &= ~TableFlags.MASK;
            return;
        }

        // Hash full: rehash (PUC: grow table, redistribute keys between array/hash).
        try self.testcChargeMemory(64);
        try self.tableRehash(tbl, key);
        // After rehash, insert the key (guaranteed to succeed).
        // newcheckedkey: if key is now in array range, put in array; else insertkey.
        if (key == .Int) {
            const k = key.Int;
            if (k >= 1 and @as(u64, @intCast(k)) <= tbl.asize) {
                tbl.array[@intCast(k - 1)] = val;
                tbl.flags &= ~TableFlags.MASK;
                return;
            }
        }
        const inserted = ltable.nodeInsert(tbl.hash, &tbl.hash_lastfree, key, val, self.hash_seed);
        std.debug.assert(inserted != null);
        tbl.flags &= ~TableFlags.MASK;
    }
```

- [ ] **Step 2: Remove `appendTableArrayValue` function entirely**

Delete the `appendTableArrayValue` function (the temporary version from Task 2).

- [ ] **Step 3: Build**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | head -40`
Expected: Compiles.

- [ ] **Step 4: Run the tableRehash test**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | grep -A5 "nextvar"`
Expected: PASS.

- [ ] **Step 5: Run smoke tests**

Run: `cd /home/boss/codes/luazig && for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 && echo "OK: $f" || echo "FAIL: $f"; done`
Expected: All pass.

- [ ] **Step 6: Run matrix tests**

Run: `cd /home/boss/codes/luazig && python3 tools/testes_matrix.py 2>&1 | tail -20`
Expected: 28/31 (no regressions).

- [ ] **Step 7: Commit**

```bash
cd /home/boss/codes/luazig
git add src/lua/vm.zig
git commit -m "P15.66: rewrite rawSet to PUC luaH_newkey flow (insertkey → rehash → newcheckedkey)"
```

---

## Task 5: Implement PUC `luaH_getn` for length operator

**Files:**
- Modify: `src/lua/vm.zig` — replace `tableBorderLen` (line ~24006)

- [ ] **Step 1: Write failing tests for `tableBorderLen` (PUC luaH_getn)**

```zig
test "tableBorderLen: empty table → 0" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const tbl = try vm.allocTable();
    try std.testing.expectEqual(@as(i64, 0), vm.tableBorderLen(tbl));
}

test "tableBorderLen: contiguous array {1,2,3} → 3" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const tbl = try vm.allocTable();
    try vm.tableResizeArray(tbl, 3);
    tbl.array[0] = .{ .Int = 10 };
    tbl.array[1] = .{ .Int = 20 };
    tbl.array[2] = .{ .Int = 30 };
    try std.testing.expectEqual(@as(i64, 3), vm.tableBorderLen(tbl));
}

test "tableBorderLen: array with hole {1,nil,3} → 1" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const tbl = try vm.allocTable();
    try vm.tableResizeArray(tbl, 3);
    tbl.array[0] = .{ .Int = 10 };
    tbl.array[1] = .Nil;
    tbl.array[2] = .{ .Int = 30 };
    try std.testing.expectEqual(@as(i64, 1), vm.tableBorderLen(tbl));
}

test "tableBorderLen: hash key asize+1 extends border → 4" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const tbl = try vm.allocTable();
    try vm.tableResizeArray(tbl, 3);
    tbl.array[0] = .{ .Int = 10 };
    tbl.array[1] = .{ .Int = 20 };
    tbl.array[2] = .{ .Int = 30 };
    // Insert a[4] in hash part
    try vm.rawSet(tbl, .{ .Int = 4 }, .{ .Int = 40 });
    try std.testing.expectEqual(@as(i64, 4), vm.tableBorderLen(tbl));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: FAIL (old `tableBorderLen` doesn't check hash part).

- [ ] **Step 3: Implement PUC `luaH_getn`**

Replace `tableBorderLen` (line ~24006) with:

```zig
    /// PUC `luaH_getn` (ltable.c:1301). Find a border in the table.
    /// A border is an integer index i such that t[i] is present and
    /// t[i+1] is absent (or 0 if t[1] is absent, or maxint if t[maxint] present).
    ///
    /// If there is an array part, try the hint vicinity first, then binary
    /// search. If the array's last element is present, the border may be in
    /// the hash part — use `hash_search` (doubling + binary search).
    fn tableBorderLen(self: *Vm, tbl: *Table) i64 {
        const asize = tbl.asize;
        if (asize > 0) {
            const maxvicinity = 4;
            var limit: u32 = tbl.lenhint;
            if (limit == 0) limit = 1;
            if (limit > asize) limit = asize;

            // t[limit] empty? Search backward.
            if (tbl.array[limit - 1] == .Nil) {
                var i: u32 = 0;
                while (i < maxvicinity and limit > 1) : (i += 1) {
                    limit -= 1;
                    if (tbl.array[limit - 1] != .Nil) {
                        tbl.lenhint = limit;
                        return @intCast(limit);
                    }
                }
                // Binary search in [0, limit)
                const border = binSearchArray(tbl, 0, limit);
                tbl.lenhint = border;
                return @intCast(border);
            }

            // t[limit] present. Search forward.
            var i: u32 = 0;
            while (i < maxvicinity and limit < asize) : (i += 1) {
                limit += 1;
                if (tbl.array[limit - 1] == .Nil) {
                    tbl.lenhint = limit - 1;
                    return @intCast(limit - 1);
                }
            }
            // If last array element is empty, binary search in [limit, asize)
            if (tbl.array[asize - 1] == .Nil) {
                const border = binSearchArray(tbl, limit, asize);
                tbl.lenhint = border;
                return @intCast(border);
            }
            // Last array element is present — border may be in hash.
            tbl.lenhint = asize;
        }

        // Check hash part: is t[asize+1] present?
        if (tbl.hash.len == 0) return @intCast(asize);
        const j: u64 = @as(u64, asize) + 1;
        const j_val = self.rawGet(tbl, .{ .Int = @as(i64, @bitCast(j)) });
        if (j_val == .Nil) return @intCast(asize);

        // hash_search: doubling + binary search in hash part.
        return @intCast(self.hashSearch(tbl, asize));
    }

    /// PUC `binsearch` (ltable.c:1271). Binary search for a border in
    /// array[lo..hi). Returns the largest i in [lo, hi) such that
    /// array[i-1] is non-nil (or lo-1 if all nil, but caller ensures
    /// array[lo-1] is present).
    fn binSearchArray(tbl: *Table, lo: u32, hi: u32) u32 {
        var i = lo;
        var j = hi;
        while (j - i > 1) {
            const m = (i + j) / 2;
            if (tbl.array[m - 1] == .Nil) {
                j = m;
            } else {
                i = m;
            }
        }
        return i;
    }

    /// PUC `hash_search` (ltable.c:1239). Find a border in the hash part
    /// starting from `asize+1` (which is known to be present).
    /// Uses random doubling then binary search.
    fn hashSearch(self: *Vm, tbl: *Table, asize: u32) u64 {
        var i: u64 = @as(u64, asize) + 1;
        const n: u8 = if (asize > 0) ltable.ceilLog2(asize) else 0;
        const mask: u32 = (@as(u32, 1) << @intCast(n)) - 1;
        var rnd = self.hash_seed;
        const incr: u32 = @as(u32, @intCast(rnd & mask)) + 1;
        rnd >>= @intCast(n);
        var j: u64 = if (incr <= std.math.maxInt(u64) - i) i + incr else i + 1;

        // Doubling phase: find j where t[j] is absent.
        while (true) {
            const j_val = self.rawGet(tbl, .{ .Int = @as(i64, @bitCast(j)) });
            if (j_val == .Nil) break;
            i = j;
            if (j <= std.math.maxInt(u64) / 2 - 1) {
                j = j * 2 + (rnd & 1);
                rnd >>= 1;
            } else {
                j = std.math.maxInt(u64);
                const max_val = self.rawGet(tbl, .{ .Int = std.math.maxInt(i64) });
                if (max_val == .Nil) break;
                return j;
            }
        }

        // Binary search between i (present) and j (absent).
        while (j - i > 1) {
            const m = (i + j) / 2;
            const m_val = self.rawGet(tbl, .{ .Int = @as(i64, @bitCast(m)) });
            if (m_val == .Nil) {
                j = m;
            } else {
                i = m;
            }
        }
        return i;
    }
```

- [ ] **Step 4: Run tests**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: PASS.

- [ ] **Step 5: Run smoke tests**

Run: `cd /home/boss/codes/luazig && for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 && echo "OK: $f" || echo "FAIL: $f"; done`
Expected: All pass.

- [ ] **Step 6: Run matrix tests**

Run: `cd /home/boss/codes/luazig && python3 tools/testes_matrix.py 2>&1 | tail -20`
Expected: 28/31 (no regressions).

- [ ] **Step 7: Commit**

```bash
cd /home/boss/codes/luazig
git add src/lua/vm.zig
git commit -m "P15.66: implement PUC luaH_getn (lenhint + vicinity + binsearch + hash_search)"
```

---

## Task 6: NEWTABLE backpatch hints in codegen

**Files:**
- Modify: `src/lua/codegen_bc.zig` — `genTable` (line ~3104)
- Modify: `src/lua/vm.zig` — `OP_NEWTABLE` handler (line ~7004)

- [ ] **Step 1: Write failing codegen test for NEWTABLE hints**

Add to `src/lua/codegen_bc.zig` test section:

```zig
test "NEWTABLE: empty constructor emits asize=0, hsize=0" {
    var cg = try Codegen.init(testing_alloc, sample_source, &ast_chunk_empty);
    defer cg.deinit();
    _ = try cg.genTable(&empty_constructor_node, 1);
    const code = cg.builder.code.items;
    // First instruction should be NEWTABLE with B=0, C=0
    try testing.expectEqual(@as(u8, @intFromEnum(bc.Op.newtable)), code[0].op);
    try testing.expectEqual(@as(u8, 0), code[0].b); // hsize=0
    try testing.expectEqual(@as(u8, 0), code[0].c); // asize=0
}

test "NEWTABLE: {10,20,30} emits asize=3, hsize=0" {
    var cg = try Codegen.init(testing_alloc, sample_source, &ast_chunk_3_array);
    defer cg.deinit();
    _ = try cg.genTable(&constructor_3_array, 1);
    const code = cg.builder.code.items;
    try testing.expectEqual(@as(u8, @intFromEnum(bc.Op.newtable)), code[0].op);
    try testing.expectEqual(@as(u8, 0), code[0].b); // hsize=0
    try testing.expectEqual(@as(u8, 3), code[0].c); // asize=3
}

test "NEWTABLE: {a=1, b=2} emits asize=0, hsize=2" {
    var cg = try Codegen.init(testing_alloc, sample_source, &ast_chunk_2_hash);
    defer cg.deinit();
    _ = try cg.genTable(&constructor_2_hash, 1);
    const code = cg.builder.code.items;
    try testing.expectEqual(@as(u8, @intFromEnum(bc.Op.newtable)), code[0].op);
    // hsize=2 → B = ceilLog2(2)+1 = 2
    try testing.expectEqual(@as(u8, 2), code[0].b);
    try testing.expectEqual(@as(u8, 0), code[0].c); // asize=0
}

test "NEWTABLE: {1,2,3, a=1} emits asize=3, hsize=1" {
    var cg = try Codegen.init(testing_alloc, sample_source, &ast_chunk_mixed);
    defer cg.deinit();
    _ = try cg.genTable(&constructor_mixed, 1);
    const code = cg.builder.code.items;
    try testing.expectEqual(@as(u8, @intFromEnum(bc.Op.newtable)), code[0].op);
    // hsize=1 → B = ceilLog2(1)+1 = 1
    try testing.expectEqual(@as(u8, 1), code[0].b);
    try testing.expectEqual(@as(u8, 3), code[0].c); // asize=3
}

test "NEWTABLE: 300 array elements uses EXTRAARG" {
    var cg = try Codegen.init(testing_alloc, sample_source, &ast_chunk_300_array);
    defer cg.deinit();
    _ = try cg.genTable(&constructor_300_array, 1);
    const code = cg.builder.code.items;
    try testing.expectEqual(@as(u8, @intFromEnum(bc.Op.newtable)), code[0].op);
    // asize=300 > 255 → C=0, EXTRAARG follows
    try testing.expectEqual(@as(u8, 0), code[0].c);
    try testing.expectEqual(@as(u8, @intFromEnum(bc.Op.extraarg)), code[1].op);
    try testing.expectEqual(@as(u32, 300), code[1].extraArg());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: FAIL — codegen always emits B=0, C=0.

- [ ] **Step 3: Implement backpatch in `genTable`**

In `src/lua/codegen_bc.zig`, modify `genTable` (line ~3104). The key change: emit NEWTABLE as a placeholder, count `na`/`nh` during the constructor loop, then backpatch.

Replace the start of `genTable`:

```zig
    fn genTable(self: *Codegen, n: anytype, line: u32) Error!u8 {
        const dst = try self.allocReg();
        // Emit NEWTABLE placeholder — will be backpatched with na/nh after
        // the constructor body is compiled (PUC luaK_settablesize, lcode.c:1874).
        const newtable_pc = try self.builder.emitABC(.newtable, dst, 0, 0, line);
        // Reserve space for EXTRAARG (in case asize > 255).
        _ = try self.builder.emit(bc.Instruction.simple(.extraarg), line);
```

Then, after the constructor loop (before `return dst`), add the backpatch:

```zig
        // Backpatch NEWTABLE with actual array/hash counts (PUC luaK_settablesize).
        // B = ceilLog2(nh) + 1 (0 if nh==0), C = asize (low 8 bits).
        const na: u32 = total_array_count;
        const nh: u32 = total_hash_count;
        const hsize_field: u8 = if (nh == 0) 0 else ltable.ceilLog2(nh) + 1;
        if (na <= 255) {
            self.builder.code.items[newtable_pc] = bc.Instruction.make(.newtable, dst, hsize_field, @intCast(na));
            // Remove the EXTRAARG placeholder (not needed).
            _ = self.builder.code.pop();
        } else {
            // asize > 255: C=0, EXTRAARG carries the full value.
            self.builder.code.items[newtable_pc] = bc.Instruction.make(.newtable, dst, hsize_field, 0);
            self.builder.code.items[newtable_pc + 1] = bc.Instruction.extra(na);
        }

        return dst;
```

Note: need to track `total_array_count` and `total_hash_count` during the loop. The existing `array_count` tracks pending flushes; add a `total_array_count` that accumulates all array elements (including flushed ones), and count `Name`/`Index` fields as hash entries.

Add tracking variables at the top of `genTable`:

```zig
        var total_array_count: u32 = 0;
        var total_hash_count: u32 = 0;
```

In the `.Array` branch, after `array_count += 1`, add `total_array_count += 1`.
In the `.Name` and `.Index` branches, add `total_hash_count += 1`.

For multi-ret (`.Call`/`.MethodCall`/`.Dots`), the array count is unknown at compile time — set `total_array_count = 0` and let SETLIST handle resize at runtime (PUC does the same: `GETARG_vB(i) == 0` triggers `luaH_resizearray`).

- [ ] **Step 4: Update `OP_NEWTABLE` handler in VM**

In `src/lua/vm.zig` (line ~7004), replace:

```zig
                    .newtable => {
                        const t = try self.allocTable();
                        ctx.regs[a] = .{ .Table = t };
                    },
```

with:

```zig
                    .newtable => {
                        // PUC OP_NEWTABLE (lvm.c:1407): B = log2(hash size)+1,
                        // C = array size (low 8 bits). If k bit set, EXTRAARG
                        // follows with high bits of array size.
                        const b = inst.b;
                        var c: u32 = inst.c;
                        const hsize: u32 = if (b > 0) @as(u32, 1) << @intCast(b - 1) else 0;
                        // Check for EXTRAARG (when asize > 255, C==0 and
                        // EXTRAARG follows). We detect this by checking if
                        // the next instruction is EXTRAARG and C==0 but B>0
                        // or the codegen always emits EXTRAARG.
                        // Actually, our codegen emits EXTRAARG only when
                        // asize > 255. When asize <= 255, no EXTRAARG.
                        // But we always reserve the slot... Let's check:
                        // codegen pops EXTRAARG when not needed. So if
                        // next is EXTRAARG, asize > 255.
                        if (c == 0 and ctx.pc + 1 < ctx.cur_proto.code.len) {
                            const next_inst = ctx.cur_proto.code[ctx.pc + 1];
                            if (@as(bc.Op, @enumFromInt(next_inst.op)) == .extraarg) {
                                c = next_inst.extraArg();
                                ctx.pc += 1; // skip EXTRAARG
                            }
                        }
                        const t = try self.allocTable();
                        if (hsize > 0 or c > 0) {
                            try self.tableResize(t, c, hsize);
                        }
                        ctx.regs[a] = .{ .Table = t };
                    },
```

- [ ] **Step 5: Build**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | head -40`
Expected: Compiles.

- [ ] **Step 6: Run codegen tests**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: PASS.

- [ ] **Step 7: Write VM-level test for NEWTABLE hints**

```zig
test "OP_NEWTABLE: hints create correctly-sized table" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    // Compile and run: local t = {10, 20, 30}
    // Check that t has asize=3 after creation.
    const result = try vm.runString("local t = {10, 20, 30}; return t");
    defer vm.alloc.free(result);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(result[0] == .Table);
    const tbl = result[0].Table;
    try std.testing.expectEqual(@as(u32, 3), tbl.asize);
    try std.testing.expectEqual(@as(i64, 10), tbl.array[0].Int);
    try std.testing.expectEqual(@as(i64, 20), tbl.array[1].Int);
    try std.testing.expectEqual(@as(i64, 30), tbl.array[2].Int);
}
```

- [ ] **Step 8: Run tests**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: PASS.

- [ ] **Step 9: Run smoke tests**

Run: `cd /home/boss/codes/luazig && for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 && echo "OK: $f" || echo "FAIL: $f"; done`
Expected: All pass.

- [ ] **Step 10: Run matrix tests**

Run: `cd /home/boss/codes/luazig && python3 tools/testes_matrix.py 2>&1 | tail -20`
Expected: 28/31 (no regressions).

- [ ] **Step 11: Commit**

```bash
cd /home/boss/codes/luazig
git add src/lua/codegen_bc.zig src/lua/vm.zig
git commit -m "P15.66: NEWTABLE backpatch with array/hash size hints (PUC luaK_settablesize)"
```

---

## Task 7: Rewrite SETLIST to use direct array writes

**Files:**
- Modify: `src/lua/vm.zig` — `opSetlist` (line ~8460)

- [ ] **Step 1: Rewrite `opSetlist` fast path**

In `src/lua/vm.zig`, update `opSetlist` (line ~8485). The current code already uses `tableResizeArray` (from Task 2), but verify it's correct:

```zig
            if (tbl.metatable == null) {
                const start = base_idx;
                const end = base_idx + @as(u32, @intCast(count));
                // PUC: if last > h->asize, resize array (luaH_resizearray).
                if (end > tbl.asize) {
                    try self.tableResizeArray(tbl, end);
                }
                // Direct writes (PUC: obj2arr).
                for (0..count) |i| {
                    const idx = start + i;
                    tbl.array[idx] = ctx.regs[a + 1 + i];
                    try self.gcWriteBarrierTable(tbl, ctx.regs[a + 1 + i]);
                }
                tbl.flags &= ~TableFlags.MASK;
            }
```

This should already be correct from Task 2's migration. Verify and add a test.

- [ ] **Step 2: Write test for SETLIST**

```zig
test "SETLIST: {10,20,30} writes directly to pre-sized array" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.runString("local t = {10, 20, 30}; return t");
    defer vm.alloc.free(result);
    try std.testing.expect(result[0] == .Table);
    const tbl = result[0].Table;
    // NEWTABLE should have pre-sized asize=3, no resize needed in SETLIST.
    try std.testing.expectEqual(@as(u32, 3), tbl.asize);
    try std.testing.expectEqual(@as(i64, 10), tbl.array[0].Int);
    try std.testing.expectEqual(@as(i64, 20), tbl.array[1].Int);
    try std.testing.expectEqual(@as(i64, 30), tbl.array[2].Int);
}

test "SETLIST: multi-ret {f()} resizes array at runtime" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.runString(
        \\local function f() return 10, 20, 30 end
        \\local t = {f()}
        \\return t
    );
    defer vm.alloc.free(result);
    try std.testing.expect(result[0] == .Table);
    const tbl = result[0].Table;
    try std.testing.expectEqual(@as(i64, 10), tbl.array[0].Int);
    try std.testing.expectEqual(@as(i64, 20), tbl.array[1].Int);
    try std.testing.expectEqual(@as(i64, 30), tbl.array[2].Int);
}
```

- [ ] **Step 3: Run tests**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd /home/boss/codes/luazig
git add src/lua/vm.zig
git commit -m "P15.66: SETLIST uses direct array writes with tableResizeArray"
```

---

## Task 8: Fix `builtinTableCreate` and vararg table creation

**Files:**
- Modify: `src/lua/vm.zig` — `builtinTableCreate` (line ~23308), vararg table (line ~8345)

- [ ] **Step 1: Verify `builtinTableCreate` uses `tableResize`**

The change from Task 2 should already be in place. Verify:

```zig
        const t = try self.allocTable();
        if (narray != 0 or nhash != 0) {
            try self.tableResize(t, narray, nhash);
        }
        self.gcNoteAlloc(narray * 8 + nhash * 16);
        outs[0] = .{ .Table = t };
```

- [ ] **Step 2: Write test for `table.create`**

```zig
test "table.create(1000) sets asize=1000" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.runString("return table.create(1000)");
    defer vm.alloc.free(result);
    try std.testing.expect(result[0] == .Table);
    try std.testing.expectEqual(@as(u32, 1000), result[0].Table.asize);
}

test "table.create(1000, 1) sets asize=1000, hash=1" {
    var vm = try Vm.init(std.testing.allocator);
    defer vm.deinit();
    const result = try vm.runString("return table.create(1000, 1)");
    defer vm.alloc.free(result);
    try std.testing.expect(result[0] == .Table);
    try std.testing.expectEqual(@as(u32, 1000), result[0].Table.asize);
    try std.testing.expectEqual(@as(usize, 1), result[0].Table.hash.len);
}
```

- [ ] **Step 3: Run tests**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: PASS.

- [ ] **Step 4: Verify vararg table creation**

The change from Task 2 should already use `tableResizeArray`. Verify the vararg table path (line ~8345) works:

```zig
                            try self.tableResizeArray(t, @intCast(va_slice.len));
                            for (va_slice, 0..) |v, i| {
                                t.array[i] = v;
                            }
```

- [ ] **Step 5: Run smoke tests (especially varargs)**

Run: `cd /home/boss/codes/luazig && zig-out/bin/luazig tests/smoke/18_varargs.lua && echo "OK" || echo "FAIL"`
Expected: OK.

- [ ] **Step 6: Commit**

```bash
cd /home/boss/codes/luazig
git add src/lua/vm.zig
git commit -m "P15.66: fix builtinTableCreate and vararg table to use tableResize"
```

---

## Task 9: Final integration testing and README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Build ReleaseFast**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 2: Run testc_lane (nextvar must pass)**

Run: `cd /home/boss/codes/luazig && python3 tools/testc_lane.py --timeout 60 2>&1`
Expected: 8/9 pass (nextvar.lua now passes; coroutine.lua still times out due to stdout buffering).

- [ ] **Step 3: Run full matrix**

Run: `cd /home/boss/codes/luazig && python3 tools/testes_matrix.py 2>&1 | tail -20`
Expected: 28/31 (no regressions).

- [ ] **Step 4: Run all smoke tests**

Run: `cd /home/boss/codes/luazig && for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 && echo "OK: $f" || echo "FAIL: $f"; done`
Expected: 45/45 pass.

- [ ] **Step 5: Run unit tests**

Run: `cd /home/boss/codes/luazig && zig build test 2>&1 | head -20`
Expected: All pass.

- [ ] **Step 6: Update README.md**

Add P15.66 to the progress section. Mark the nextvar.lua checkbox as closed.

- [ ] **Step 7: Commit**

```bash
cd /home/boss/codes/luazig
git add README.md
git commit -m "P15.66: PUC-faithful table rehash — nextvar.lua passes (8/9 testC)"
```

---

## Self-Review Checklist

1. **Spec coverage:**
   - PUC `computesizes` → Task 1 ✓
   - PUC `numusearray`/`numusehash` → Task 1 ✓
   - PUC `luaH_resize` → Task 3 ✓
   - PUC `rehash` → Task 3 ✓
   - PUC `luaH_newkey` (rawSet rewrite) → Task 4 ✓
   - PUC `luaH_getn` → Task 5 ✓
   - NEWTABLE backpatch → Task 6 ✓
   - SETLIST direct writes → Task 7 ✓
   - `table.create` fix → Task 8 ✓
   - `querytab` fix → Task 2 (Step 13) ✓
   - Vararg table fix → Task 2 (Step 11) + Task 8 ✓
   - GC accounting → Task 2 (Step 8-9) ✓

2. **Placeholder scan:** No TBD/TODO placeholders. All code blocks contain actual implementation.

3. **Type consistency:**
   - `tableResize(self, tbl, new_asize: u32, new_hsize: u32)` — consistent across all tasks.
   - `tableResizeArray(self, tbl, new_asize: u32)` — consistent.
   - `tableRehash(self, tbl, ek: Value)` — consistent.
   - `Table.asize: u32` — consistent.
   - `Table.lenhint: u32` — consistent.
   - `Table.array: []Value` — consistent.
