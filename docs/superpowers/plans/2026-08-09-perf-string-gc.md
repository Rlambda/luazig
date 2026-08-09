# Plan: PUC-faithful Short String GC — Performance Fix

## Problem

Short string GC causes 2.87x → 4.68x perf regression. Two O(N) bottlenecks:
1. `gcSweepStringIntern` — iterates entire HashMap per cycle
2. `gcDeadenUnmarkedStringKeys` — iterates all gc_objects per atomic phase

## Solution: match PUC architecture

PUC puts short strings in `allgc` (per-object incremental sweep) + `strt` (interning).
luazig should match: strings in `gc_objects` (per-object sweep) + `string_intern` (interning).

## Tasks

### Task 1: Populate gc_marked_tables during mark phase

**File:** `src/lua/vm.zig`

**Problem:** `gc_marked_tables` is declared at line ~2286 but NEVER populated. It's dead code.

**Change:** In `gcPropagateOne`, when traversing a table (the `.table => |tbl|` case, around line ~16688), add `try self.gc_marked_tables.put(self.alloc, tbl, {})` BEFORE traversing the table's children. This records that the table was marked during this cycle.

**Note:** `gc_marked_tables` is a `std.AutoHashMapUnmanaged(*Table, void)`. Using `put` deduplicates — if the table is already in the map, it's a no-op. `gcResetCycleState` at line ~15504 already clears it with `clearRetainingCapacity()`.

**Verify:** Build succeeds. No behavioral change yet.

### Task 2: gcDeadenUnmarkedStringKeys iterates gc_marked_tables instead of gc_objects

**File:** `src/lua/vm.zig`

**Problem:** `gcDeadenUnmarkedStringKeys` (around line ~16620) iterates ALL `gc_objects` looking for tables. This is O(total_objects) per atomic phase — the main bottleneck.

**Change:** Replace `for (self.gc_objects.items) |obj|` with iteration over `self.gc_marked_tables`. The function should:
```zig
fn gcDeadenUnmarkedStringKeys(self: *Vm) void {
    var it = self.gc_marked_tables.iterator();
    while (it.next()) |entry| {
        const tbl = entry.key_ptr.*;
        // (existing logic for hash keys and array values)
    }
}
```

Keep the existing logic inside (gcIsDead check, weak-key handling, array value Nil'ing). Only change the outer iteration.

**Verify:** Build succeeds. Run `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py --testc` — must be 30/31.

### Task 3: Register short strings in gc_objects

**File:** `src/lua/vm.zig`

**Problem:** `internStr` (around line ~11924) creates short strings in `string_intern` but does NOT register them in `gc_objects`. The `gcRegisterString` function exists but is never called.

**Change:** In `internStr`, after `try self.string_intern.table.put(...)`, add `try self.gcRegisterString(ls)`:
```zig
try self.string_intern.table.put(self.alloc, ls.bytes(), ls);
try self.gcRegisterString(ls);  // Register in gc_objects (PUC allgc)
```

**Also:** In `gcFreeObject` for `.string`, add `string_intern.table.remove` BEFORE `destroyLuaString`:
```zig
.string => |s| {
    if (s.len <= lua_string_max_short_len) {
        _ = self.string_intern.table.remove(s.bytes());
    }
    const bytes = ...;
    self.gcNoteFree(bytes);
    destroyLuaString(self.alloc, s);
},
```

**Verify:** Build succeeds. `python3 tools/leak_bench.py --no-build` — must show 0 leaks for string workloads.

### Task 4: Remove gcSweepStringIntern from Phase 3

**File:** `src/lua/vm.zig`

**Problem:** `gcSweepStringIntern` in Phase 3 is an O(N) non-incremental spike. With strings in gc_objects (Task 3), per-object sweep handles string collection.

**Change:** Remove the `gcSweepStringIntern` call from Phase 3:
```zig
// Phase 3: sweep long string literals only.
// Short strings are in gc_objects and swept by Phase 1 per-object sweep.
try self.long_literals.sweep(self.alloc, self.gc_current_white);
```

Remove the `if (self.gc_mode == .incremental)` guard and the `gcSweepStringIntern` call.

**Also:** Restore `gcMakeAllWhite` and `gcMakeAllOld` to iterate `gc_objects` only (strings are now in gc_objects). Remove separate `string_intern` iterations from these functions.

**Verify:** Build succeeds. `python3 tools/testes_matrix.py --testc` — must be 30/31. `python3 tools/smoke_compare.py` — must be PASS.

### Task 5: Performance verification

Run all four gates:
1. `python3 tools/testes_matrix.py --testc` — 30/31
2. `python3 tools/smoke_compare.py` — 49/49
3. `python3 tools/leak_bench.py` — 25/25 PASS
4. `python3 tools/perf_compare.py` — geomean ≤ 3.0x (baseline was 2.87x)

If perf is still > 3.0x, profile to find remaining bottleneck.

### Task 6: Commit and update plan

Commit all changes with descriptive message. Update `docs/superpowers/plans/2026-08-08-leak-detection.md`.
