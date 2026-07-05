# Phase A: String Interning — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all Lua strings interned `*LuaString` objects (header + inline bytes + cached hash), so string equality is pointer-equality — the foundation for the Phase B Table keys.

**Architecture:** Evolve the existing `internConstString` seam (`src/lua/vm.zig:2551`, backed by the `const_strings` map) into a full `StringIntern` table keyed by content and storing `*LuaString`. Change `Value.String` from `[]const u8` to `*LuaString`; route every string-creating site through `Vm.internStr(bytes)`; replace `std.mem.eql` string comparisons with pointer-eq; integrate the intern table with GC mark/sweep. Mirrors PUC Lua `lstring.c`.

**Tech Stack:** Zig 0.16 (system), existing `lua` module, `zig build test` + `tools/run_tests.py` parity.

**Branch:** `phase-a-string-interning` (merge to master only when parity ≥ 33/34).

---

## Existing seam (do NOT re-discover)

- `Value.String` is `[]const u8` (`src/lua/vm.zig:519`).
- `internConstString`/`internConstStringMaybeOwned` at `src/lua/vm.zig:2551-2575` already dedups by content via `const_strings: std.StringHashMapUnmanaged([]const u8)` (`vm.zig:637`); frees wholesale at deinit (`vm.zig:778-780`).
- RNG `rng_state` + seeding exist (`vm.zig:633`, `10092-10130`) — reusable for the hash seed.
- GC central marker is `gcMarkValue` (`vm.zig:5625`); `testc_obj_strings` / `testcNoteMemory` track string objects for the OOM tests.
- Construction sites: `.String =` appears in `vm.zig` (~359×), `api.zig` (9×), `parser.zig` (3×), `bc_vm.zig` (3×), `ast.zig` (1×), `token.zig` (1×), `codegen.zig` (1×). Reads of `.String` (the bytes): ~455× in `vm.zig`.

---

## File Structure

- Modify: `src/lua/vm.zig` — add `LuaString`, `StringIntern`, `internStr`; change `Value.String`; route sites; GC integration.
- Modify: `src/lua/api.zig`, `src/lua/parser.zig`, `src/lua/codegen.zig`, `src/lua/ast.zig`, `src/lua/token.zig`, `src/lua/bc_vm.zig` — fix `.String` construction/read sites surfaced by compile errors.
- Test: `test` blocks co-located in `src/lua/vm.zig` (matches existing convention, e.g. `bc_vm.zig` tests).

---

## Task 1: `LuaString` type with inline bytes

**Files:**
- Modify: `src/lua/vm.zig` (add `pub const LuaString` above `pub const Value` at line 514).

- [ ] **Step 1: Write the failing test** — append near other unit tests (e.g. after the bc_vm-style tests, or just below the `LuaString` definition).

```zig
test "LuaString stores inline bytes and cached hash" {
    const alloc = std.testing.allocator;
    const h: u64 = 0xdeadbeef;
    const ls = try createLuaString(alloc, "hello", h);
    defer destroyLuaString(alloc, ls);
    try std.testing.expectEqual(@as(usize, 5), ls.len);
    try std.testing.expectEqual(h, ls.hash);
    try std.testing.expectEqualStrings("hello", ls.bytes());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -- --test-filter "LuaString stores"`
Expected: FAIL — `createLuaString` / `LuaString` undefined (compile error).

- [ ] **Step 3: Write minimal implementation** — insert above `pub const Value` (line 514):

```zig
// Interned Lua string. Layout mirrors PUC Lua's TString: a header immediately
// followed by `len` bytes in the SAME allocation (cache-friendly, one alloc per
// string). Equality between two `*LuaString` is pointer equality, because the
// intern table guarantees uniqueness per content.
pub const LuaString = struct {
    hash: u64, // content hash, computed once at intern time (random-seeded)
    len: usize,
    marked: u8 = 0, // GC mark bit (used in Task 5)

    pub fn bytes(self: *const LuaString) []const u8 {
        const header: [*]const u8 = @ptrCast(self);
        const body = header + @sizeOf(LuaString);
        return body[0..self.len];
    }
};

// Allocate a LuaString with `raw` copied inline right after the header.
fn createLuaString(alloc: std.mem.Allocator, raw: []const u8, hash: u64) !*LuaString {
    const total = @sizeOf(LuaString) + raw.len;
    const buf = try alloc.alignedAlloc(u8, @alignOf(LuaString), total);
    errdefer alloc.free(buf);
    const ls: *LuaString = @ptrCast(@alignCast(buf.ptr));
    ls.hash = hash;
    ls.len = raw.len;
    ls.marked = 0;
    @memcpy(buf[@sizeOf(LuaString)..], raw);
    return ls;
}

// Free a LuaString allocated by `createLuaString`.
fn destroyLuaString(alloc: std.mem.Allocator, ls: *LuaString) void {
    const total = @sizeOf(LuaString) + ls.len;
    const buf: [*]align(@alignOf(LuaString)) u8 = @ptrCast(@alignCast(ls));
    alloc.free(buf[0..total]);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test -- --test-filter "LuaString stores"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "vm: add LuaString type with inline bytes"
```

---

## Task 2: `StringIntern` table + `Vm.internStr`

**Files:**
- Modify: `src/lua/vm.zig` — add `StringIntern` struct; add field `string_intern` to `Vm`; add `internStr` method; seed from existing RNG.

- [ ] **Step 1: Write the failing tests** (append after Task 1's test):

```zig
test "StringIntern dedups equal content to same pointer" {
    var intern = StringIntern{};
    defer intern.deinit(std.testing.allocator);
    const a = try intern.intern(std.testing.allocator, "foo", hashStringForTest("foo"));
    const b = try intern.intern(std.testing.allocator, "foo", hashStringForTest("foo"));
    try std.testing.expect(a == b); // pointer identity
    try std.testing.expectEqualStrings("foo", a.bytes());
}

test "StringIntern keeps distinct content distinct" {
    var intern = StringIntern{};
    defer intern.deinit(std.testing.allocator);
    const a = try intern.intern(std.testing.allocator, "foo", hashStringForTest("foo"));
    const c = try intern.intern(std.testing.allocator, "bar", hashStringForTest("bar"));
    try std.testing.expect(a != c);
}

fn hashStringForTest(s: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(s);
    return h.final();
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -- --test-filter "StringIntern"`
Expected: FAIL — `StringIntern` undefined.

- [ ] **Step 3: Write minimal implementation** — add near `LuaString`:

```zig
// Global table of all live interned strings. Keyed by content bytes (the inline
// slice of the stored LuaString, stable for its allocation lifetime), mapping to
// the canonical `*LuaString`. Mirrors PUC `lstring.c` stringtable.
pub const StringIntern = struct {
    const Table = std.HashMapUnmanaged([]const u8, *LuaString, Context, std.hash_map.default_max_load_percentage);
    const Context = struct {
        pub fn hash(_: @This(), k: []const u8) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(k);
            return h.final();
        }
        pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    };

    table: Table = .empty,

    fn intern(self: *StringIntern, alloc: std.mem.Allocator, raw: []const u8, hash: u64) !*LuaString {
        if (self.table.get(raw)) |existing| return existing;
        const ls = try createLuaString(alloc, raw, hash);
        try self.table.put(alloc, ls.bytes(), ls);
        return ls;
    }

    fn deinit(self: *StringIntern, alloc: std.mem.Allocator) void {
        var it = self.table.valueIterator();
        while (it.next()) |ls_ptr| destroyLuaString(alloc, ls_ptr.*);
        self.table.deinit(alloc);
    }
};
```

Add to `Vm` struct (near `const_strings` at line 637): `string_intern: StringIntern = .{},`

Add the Vm-level helper (seed from `rng_state`; place near `internConstString` at line 2551):

```zig
// Intern `raw` and return the canonical *LuaString. All string-creating sites
// must go through here so that two equal-content strings share one pointer.
fn internStr(self: *Vm, raw: []const u8) Error!*LuaString {
    const seed = self.rng_state[0] ^ self.rng_state[2];
    var h = std.hash.Wyhash.init(seed);
    h.update(raw);
    const hash = h.final();
    if (self.string_intern.table.get(raw)) |existing| return existing;
    const ls = try createLuaString(self.alloc, raw, hash);
    try self.string_intern.table.put(self.alloc, ls.bytes(), ls);
    self.testcNoteMemory(@sizeOf(LuaString) + raw.len + 24);
    self.testc_obj_strings += 1;
    return ls;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test -- --test-filter "StringIntern"`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "vm: add StringIntern table and Vm.internStr"
```

---

## Task 3: Change `Value.String` to `*LuaString` (compile-driven routing)

This is the large mechanical task. The compiler enumerates every site. Strategy: flip the type, then walk every compile error; for each, route construction through `internStr` and adapt reads (`s` → `s.bytes()`).

**Files:** `src/lua/vm.zig` (primary), then `api.zig`, `parser.zig`, `codegen.zig`, `ast.zig`, `token.zig`, `bc_vm.zig` as compile errors surface them.

- [ ] **Step 1: Flip the type** at `src/lua/vm.zig:519`:

```zig
    String: *LuaString, // interned; compare by pointer
```

- [ ] **Step 2: Build and capture the error list**

Run: `zig build 2>&1 | tee /tmp/phaseA-build.log`
Expected: many compile errors (expected count: ~hundreds). This is the work list.

- [ ] **Step 3: Fix construction sites** — every `.String = <slice>` must become `.String = try self.internStr(<slice>)` (or the appropriate allocator-bearing owner in non-Vm files). For `parser.zig`/`ast.zig`/`token.zig`/`codegen.zig`, the AST tokens still carry raw source slices — those stay as `[]const u8` on the AST; only `Value.String` is interned, at the point a `Value` is created (codegen/vm), not during parsing. So parser/AST/token files likely need NO change unless they construct `Value`s — verify via the compile errors.

- [ ] **Step 4: Fix read sites** — every `.String => |s|` that uses `s` as bytes becomes `.String => |s| s.bytes()` (or bind `const s = ls.bytes();`). Keep `.String => "string"` (typeName) as-is.

- [ ] **Step 5: Fix `bc_vm.zig`** — its `valuesEqual` for `.String` uses `std.mem.eql(u8, ls, rs)` (`bc_vm.zig:231`); change to pointer-eq `ls == rs`. Its `decodeConst` `.str => |s| .{ .String = ... }` (`bc_vm.zig:118`) must intern — but bc_vm has no Vm handle; route by storing `*LuaString` in the const pool instead, or intern at chunk-build time (decide at the compile-error site).

- [ ] **Step 6: Build until green**

Run: `zig build`
Expected: success (no output).

- [ ] **Step 7: Run unit tests**

Run: `zig build test`
Expected: PASS (all existing tests).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "vm: switch Value.String to interned *LuaString"
```

---

## Task 4: String equality → pointer-eq; remove dead `std.mem.eql`

**Files:** `src/lua/vm.zig`, `src/lua/bc_vm.zig`.

- [ ] **Step 1: Find remaining content comparisons**

Run: `rg -n "std\.mem\.eql\(u8, .*\.String" src/`
Expected: a handful of sites (e.g. `vm.zig:4153`, `4336`, `3417`, equality helpers in `valuesEqual`-style functions).

- [ ] **Step 2: Replace with pointer-eq** — each `std.mem.eql(u8, a.String, b.String)` becomes `a.String == b.String`.

- [ ] **Step 3: Build + test**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "vm: string equality by pointer identity"
```

---

## Task 5: GC integration (mark + sweep intern table) — DEFERRED

**Finding during execution:** luazig has **no sweep pass for any object type**.
`gcCycleFull` (vm.zig:5777) only (1) marks reachable objects into sets,
(2) prunes weak-table entries, (3) runs `__gc` finalizers. Tables/closures/
threads are freed only at `Vm` deinit — there is no mid-run reclamation
(comment at vm.zig:5857: "We don't have real memory accounting").

A string-only sweep would be **incorrect**: interned strings are referenced
from tables/closures that are themselves never swept, so freeing an
"unreachable" string could free a string still live in an unswept table
→ use-after-free. The `marked` bit on `LuaString` is retained for future use.

This belongs to a dedicated **GC sweep-pass** effort (mark+sweep for all
object types) — added as its own README checkbox. Not a Phase A blocker:
parity 33/34 holds, `memerr.lua` green (tests allocation-failure, not
accumulation); intern tables are freed at deinit, consistent with all other
objects.

- [ ] **Step 1: Write the failing test** — strings unreachable from roots are freed; reachable survive a forced cycle.

```zig
test "GC sweeps unreachable interned strings" {
    // Use the existing Vm test harness if present; otherwise construct a minimal
    // Vm via the public API: intern a string, drop all references, force a full
    // GC cycle, assert the intern table no longer contains it.
    // (Adapt to the existing test-vm constructor used elsewhere in vm.zig tests.)
}
```

Note: if no in-process Vm test harness exists, validate via the `memerr.lua` parity canary in Task 7 instead, and write a focused `StringIntern.sweep` unit test:

```zig
test "StringIntern sweep removes unmarked strings" {
    var intern = StringIntern{};
    defer intern.deinit(std.testing.allocator);
    const keep = try intern.intern(std.testing.allocator, "keep", hashStringForTest("keep"));
    _ = try intern.intern(std.testing.allocator, "drop", hashStringForTest("drop"));
    keep.marked = 1;
    try intern.sweepUnmarked(std.testing.allocator); // implement in Step 3
    try std.testing.expectEqualStrings("keep", intern.table.get("keep").?.bytes());
    try std.testing.expect(intern.table.get("drop") == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -- --test-filter "sweep"`
Expected: FAIL — `sweepUnmarked` undefined.

- [ ] **Step 3: Implement mark + sweep**
  - In `gcMarkValue`, on `.String => |ls|` set `ls.marked = 1` (and register nothing else — strings are leaf objects).
  - Add `StringIntern.sweepUnmarked`: iterate `table`; for each entry whose `.marked == 0`, `destroyLuaString` + remove from table; reset `.marked = 0` for survivors.
  - Call `sweepUnmarked` from `gcCycleFull` (atomic phase, after marking), matching PUC `lstring.c` sweep.
  - In `Vm.deinit` (`vm.zig:778-780`): replace the old `const_strings` free loop with `self.string_intern.deinit(self.alloc)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test -- --test-filter "sweep"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "vm: GC mark/sweep for interned strings"
```

---

## Task 6: Remove the old `const_strings` interning path — DEFERRED TO PHASE B

**Finding during execution:** `internConstString` is **not** dead code — it has
~20 live callers (vm.zig:2489-17804) that still need a stable `[]const u8`:
the 4-map `Table.fields` StringHashMap keys, status/error/testc diagnostic
strings, etc. Its removal is coupled with Phase B (Table unification to
`*LuaString` keys), where the 4-map `[]const u8` keys become `*LuaString`.
Doing it in Phase A would require a half-conversion that Phase B reverts.

**Current state:** literals are stored twice (in `const_strings` as `[]const u8`
via `decodeStringLexeme`, and in `string_intern`/`long_literals` as `*LuaString`
via `internLiteral`). This is bounded memory waste, acceptable as a transient
state until Phase B removes `const_strings`. Not a correctness issue.

---

## Task 7: Parity checkpoint + README close-out

**Files:** `tools/perf/core_current.json`, `README.md`.

- [ ] **Step 1: Targeted parity (the canaries)**

Run:
```bash
python3 tools/run_tests.py --suite nextvar.lua --suite strings.lua --suite locals.lua --suite db.lua --suite gc.lua --suite memerr.lua --no-build
```
Expected: all PASS (parity holds). If any regress, fix before proceeding (no harness masking — root-cause).

- [ ] **Step 2: Full safe matrix**

Run: `LZ_TEST_TIMEOUT=120 tools/testes_matrix_safe.sh`
Expected: 33/34 pass, `zig_fail=0`.

- [ ] **Step 3: Perf snapshot**

Run: `python3 tools/perf_core_snapshot.py --out tools/perf/core_current.json --timeout 240`
Expected: completes; compare nextvar.lua vs baseline (no regression expected from Phase A alone; the big win lands in Phase B).

- [ ] **Step 4: Close README checkbox** — mark Phase A `[x]` in `README.md` ("План работ → Активный шаг"). Add a one-line note in "История закрытых фаз": `- P13: string interning (аналог lstring.c)`.

- [ ] **Step 5: Commit + push**

```bash
git add README.md tools/perf/core_current.json
git commit -m "docs: close Phase A (string interning)"
git push -u origin phase-a-string-interning
```

---

## Acceptance criteria (Phase A done)

- `zig build` and `zig build test` green.
- Parity ≥ 33/34, `zig_fail=0` (safe matrix).
- No `std.mem.eql(u8, ..., .String ...)` content comparisons remain for `Value` strings.
- No `.String = <raw slice>` construction remains outside `internStr`.
- Intern table participates in GC mark/sweep (`memerr.lua` green).
- README Phase A checkbox `[x]`; perf current snapshot refreshed.

## Risks (carried from design)

- Missed string-creation site → two equal strings non-pointer-equal → table-lookup miss. Canary: `strings.lua`, `nextvar.lua`. Mitigation: compile errors from the type flip enumerate sites; parity gate catches.
- GC regression in OOM preservation. Canary: `memerr.lua`. Mitigation: keep `testcNoteMemory`/`testc_obj_strings` accounting in `internStr`.
- Hash seed determinism vs the test allocator. Mitigation: seed from `rng_state` (already seeded deterministically per Vm at `vm.zig:10127`).
