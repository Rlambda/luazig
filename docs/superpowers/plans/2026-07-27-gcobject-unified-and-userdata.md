# GcObject Unified GC + Full Userdata Type

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace 5 per-type GC lists (`gc_tables`, `gc_closures`, `gc_threads`, `gc_cells`, `gc_strings`) with a single type-safe `gc_objects: ArrayList(GcObject)` tagged union, then add a full `Userdata` type (PUC `LUA_TUSERDATA`) with per-object metatables and uservalues — fixing `events.lua:347` and enabling all userdata-based testC tests.

**Architecture:** Part A defines `GcObject` as a Zig tagged union of all GC-managed pointers (type-safe, no casts). Generic GC functions (`gcRegister`, `gcUnregister`, `gcSweepOne`, `gcSweepYoungObjects`, `gcMakeAllWhite`, etc.) operate on `GcObject` through accessor functions that switch on the variant to access the flat `gc_marked`/`gc_age`/`gc_index` fields already present on each struct. This eliminates the `GcSweepKind` enum, merges the Cell/Value split (`gc_old1`+`gc_old1_cells` → `gc_old1`), and makes adding new GC types trivial. Part B adds `Userdata` to both `Value` and `GcObject`, fixes all exhaustive switches, and migrates `T.newuserdata` from table-based emulation to real userdata allocation.

**Tech Stack:** Zig (master), PUC Lua 5.5.0 (`lua-5.5.0/src/lobject.h:491-528` for Udata, `lgc.c:631-638` for traverseudata, `lvm.c:625-632` for equality, `lapi.c:1353-1363` for lua_newuserdatauv).

---

## Background: Why Two Parts?

### The Problem with Per-Type Lists

Currently, each GC-managed type has its own `ArrayList(*T)` list, its own `gcRegister*T`/`gcUnregister*T` pair, its own young list, its own snapshot length, and its own sweep kind. Adding a 6th type (`Userdata`) would require ~15 boilerplate sites following this pattern — 6th repetition of identical logic.

Additionally, `Cell` is not a `Value` variant, forcing parallel infrastructure: `gc_old1` (Value) + `gc_old1_cells` (*Cell), `gc_grayagain` (Value) + `gc_grayagain_cells` (*Cell), `gcQueueScanCell` separate from `gcQueueScanValue`.

### The GcObject Solution

A single `GcObject` tagged union captures all GC-managed pointers. One list, one register, one sweep, one young list. Cell folds in naturally (eliminating parallel infrastructure). Adding Userdata becomes one variant in the union + one case in each type-specific switch.

### PUC's Udata (reference for Part B)

```c
typedef struct Udata {
  CommonHeader;              // gc_marked, tt, next
  unsigned short nuvalue;    // number of user values
  size_t len;                // binary data length
  struct Table *metatable;   // per-object metatable
  GCObject *gclist;          // gray list link
  UValue uv[1];              // uservalues (inline, followed by binary data)
} Udata;
```

Our Zig analog separates the inline arrays into slices (idiomatic Zig, easier GC):

```zig
pub const Userdata = struct {
    gc_marked: u8 = 0,
    gc_age: GcAge = .new,
    gc_index: usize = 0,
    metatable: ?*Table = null,
    uservalues: []Value = &.{},
    payload: []u8 = &.{},
};
```

---

## File Structure

### Files to Modify

- **`src/lua/vm.zig`** — Primary file (~29.8k lines). All GC infrastructure, Value union, Userdata struct, all exhaustive switches, testC bootstrap.
- **`src/lua/ltable.zig`** — Table key system: add `userdata` variant to `NodeKeyTag`/`NodeKeyPayload` (only in Part B, if Userdata can be a table key).
- **`src/lua/api.zig`** — `valueType` function (add `.Userdata` case).
- **`src/lua/bc_vm.zig`** — `valuesEqual` function (add `.Userdata` case).

### Files to Create

None — all changes are in existing files.

---

## Part A: GcObject Unified GC

### Design Decisions

1. **Flat fields stay flat.** Each GC-managed struct (`Table`, `Closure`, `Thread`, `Cell`, `LuaString`) already has flat `gc_marked: u8`, `gc_age: GcAge`, `gc_index: usize`. We do NOT nest them into a `GcHeader` sub-struct — that would require touching every `table.gc_marked` access across ~500 sites. Instead, accessor functions switch on `GcObject` variant to return pointers to these flat fields.

2. **GcObject is broader than Value.** GcObject includes `Cell` (not a Value variant) and will include `Userdata`. `GcObject.toValue()` converts to `?Value` (returns null for Cell).

3. **`gc_gray` changes from `ArrayList(Value)` to `ArrayList(GcObject)`.** Only GC-managed values go gray. `gcPropagateOne` takes `GcObject` instead of `Value`.

4. **`gc_old1` and `gc_grayagain` change from `ArrayList(Value)` to `ArrayList(GcObject)`.** Cell's parallel lists (`gc_old1_cells`, `gc_grayagain_cells`) are eliminated — Cell goes into the same GcObject list.

5. **`GcSweepKind` is eliminated.** Single sweep pass over `gc_objects` in allocation order (PUC-faithful — PUC sweeps `allgc` in allocation order).

6. **Strings remain special.** Runtime long strings go into `gc_objects`. Short strings remain in `string_intern` (pinned). Long literals remain in `long_literals` (swept separately). `intern_tables` sweep stays.

---

### Task A1: Define GcObject tagged union and accessor functions

**Files:**
- Modify: `src/lua/vm.zig` — add after `Value` union (line ~1436)

- [x] **Step 1: Define GcObject and GcPtr**

Add after the `Value` union definition (after line ~1447):

```zig
/// Tagged union of all GC-managed heap objects. Replaces PUC's intrusive
/// `GCObject.next` singly-linked `allgc` list with a type-safe Zig union.
/// Each variant is a pointer to a struct with flat `gc_marked: u8`,
/// `gc_age: GcAge`, `gc_index: usize` fields (no layout change needed).
/// Generic GC code accesses these through `gcPtr()` which returns a
/// struct of pointers to the flat fields.
pub const GcObject = union(enum) {
    table: *Table,
    closure: *Closure,
    thread: *Thread,
    string: *LuaString,
    cell: *Cell,

    /// Convert to Value. Returns null for Cell (not a Value variant).
    pub fn toValue(self: GcObject) ?Value {
        return switch (self) {
            .table => |t| .{ .Table = t },
            .closure => |c| .{ .Closure = c },
            .thread => |t| .{ .Thread = t },
            .string => |s| .{ .String = s },
            .cell => null,
        };
    }

    /// Convert from Value. Returns null for non-GC Value variants
    /// (Nil, Bool, Int, Num, Builtin, LightUserdata).
    pub fn fromValue(v: Value) ?GcObject {
        return switch (v) {
            .Table => |t| .{ .table = t },
            .Closure => |c| .{ .closure = c },
            .Thread => |t| .{ .thread = t },
            .String => |s| .{ .string = s },
            else => null,
        };
    }
};

/// Pointer bundle to the flat GC header fields on any GC-managed struct.
/// Returned by `gcPtr()`, used by generic GC code to access marked/age/index
/// without switching on GcObject variant at every access site.
const GcPtr = struct {
    marked: *u8,
    age: *GcAge,
    index: *usize,
};
```

- [x] **Step 2: Add `gcPtr` accessor function**

Add near the existing GC helper functions (before `gcValueAge`, line ~12970):

```zig
/// Access the flat GC header fields (gc_marked, gc_age, gc_index) of any
/// GC-managed object through its GcObject tag. This is the single dispatch
/// point that lets generic GC code operate on all types uniformly.
fn gcPtr(obj: GcObject) GcPtr {
    return switch (obj) {
        .table    => |t| .{ .marked = &t.gc_marked, .age = &t.gc_age, .index = &t.gc_index },
        .closure  => |c| .{ .marked = &c.gc_marked, .age = &c.gc_age, .index = &c.gc_index },
        .thread   => |t| .{ .marked = &t.gc_marked, .age = &t.gc_age, .index = &t.gc_index },
        .string   => |s| .{ .marked = &s.gc_marked, .age = &s.gc_age, .index = &s.gc_index },
        .cell     => |c| .{ .marked = &c.gc_marked, .age = &c.gc_age, .index = &c.gc_index },
    };
}

/// Byte size of a GC-managed object (for memory accounting).
fn gcObjectBytes(obj: GcObject) usize {
    return switch (obj) {
        .table    => |t| @sizeOf(Table) + t.asize * @sizeOf(Value) + t.hash.len * @sizeOf(ltable.Node),
        .closure  => @sizeOf(Closure),
        .thread   => @sizeOf(Thread),
        .string   => |s| @sizeOf(LuaString) + s.len,
        .cell     => @sizeOf(Cell),
    };
}

/// Whether this object type can have a finalizer (__gc metamethod).
/// PUC: only tables, closures, threads, and userdata support finalization.
fn gcCanFinalize(obj: GcObject) bool {
    return switch (obj) {
        .table, .closure, .thread => true,
        .string, .cell => false,
    };
}
```

- [x] **Step 3: Build and verify compilation**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: BUILD SUCCESS (GcObject is defined but not yet used — no compilation errors)

- [x] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "GC refactor A1: define GcObject tagged union and accessor functions"
```

---

### Task A2: Add unified `gc_objects` list and generic register/unregister

**Files:**
- Modify: `src/lua/vm.zig` — Vm struct fields (line ~1662), register/unregister functions (line ~3109)

- [x] **Step 1: Add `gc_objects` field to Vm struct**

Add after line 1670 (after `gc_strings`):

```zig
    /// Unified GC object list — replaces the per-type lists above.
    /// All GC-managed objects (Table, Closure, Thread, Cell, LuaString,
    /// and future Userdata) are registered here. The per-type lists below
    /// are kept temporarily during migration (Tasks A2–A6); they are
    /// removed in Task A7 once all code is migrated.
    gc_objects: std.ArrayListUnmanaged(GcObject) = .empty,
    gc_objects_snapshot_len: usize = 0,
```

Add after line 1709 (after `gc_young_strings`):

```zig
    /// Unified young list for generational GC.
    gc_young_objects: std.ArrayListUnmanaged(GcObject) = .empty,
    gc_young_objects_snapshot_len: usize = 0,
```

- [x] **Step 2: Add generic `gcRegisterObject` / `gcUnregisterObject`**

Add after `gcRegisterString` (line ~3173):

```zig
    /// Generic GC registration for any GcObject. Appends to both
    /// `gc_objects` (the unified list) and `gc_young_objects` (if in
    /// generational minor mode). Sets gc_marked to current white and
    /// gc_age to .new (if generational).
    fn gcRegisterObject(self: *Vm, obj: GcObject) std.mem.Allocator.Error!void {
        try self.gc_objects.ensureUnusedCapacity(self.alloc, 1);
        if (self.gc_mode == .generational and self.gc_gen_phase == .minor)
            try self.gc_young_objects.ensureUnusedCapacity(self.alloc, 1);
        const p = gcPtr(obj);
        p.index.* = self.gc_objects.items.len;
        p.marked.* = self.gc_current_white & WHITEBITS;
        self.gc_objects.appendAssumeCapacity(obj);
        if (self.gc_mode == .generational and self.gc_gen_phase == .minor) {
            p.age.* = .new;
            self.gc_young_objects.appendAssumeCapacity(obj);
        }
    }

    /// Generic GC unregistration. swapRemoves from gc_objects.
    /// Does NOT remove from gc_young_objects (filtered during sweep
    /// via snapshot/write-pointer, same as per-type approach).
    fn gcUnregisterObject(self: *Vm, obj: GcObject) void {
        const p = gcPtr(obj);
        const index = p.index.*;
        std.debug.assert(index < self.gc_objects.items.len and
            std.meta.eql(self.gc_objects.items[index], obj));
        _ = self.gc_objects.swapRemove(index);
        if (index < self.gc_objects.items.len) {
            const swapped = self.gc_objects.items[index];
            gcPtr(swapped).index.* = index;
        }
    }
```

- [x] **Step 3: Wire existing `gcRegister*T` to also call `gcRegisterObject`**

In each of the 5 `gcRegister*T` functions (lines 3109–3173), add a call to `gcRegisterObject` at the end. For example, `gcRegisterTable` (line 3109):

After the existing body (line 3120), before the closing `}`:
```zig
        // Also register in the unified list during migration.
        try self.gcRegisterObject(.{ .table = table });
```

Repeat for `gcRegisterClosure`, `gcRegisterThread`, `gcRegisterCell`, `gcRegisterString` — each gets:
```zig
        try self.gcRegisterObject(.{ .closure = closure });   // or .thread, .cell, .string
```

Similarly, in each `gcUnregister*T` function (lines 3175–3208), add at the end:
```zig
        // Also unregister from the unified list during migration.
        self.gcUnregisterObject(.{ .table = table });
```

- [x] **Step 4: Add deinit for new lists in `drainGcRegistries`**

In `drainGcRegistries` (line 2344), add before the final closing `}`:

```zig
        // Unified lists (during migration; will replace per-type lists).
        self.gc_objects.deinit(self.alloc);
        self.gc_young_objects.deinit(self.alloc);
```

- [x] **Step 5: Build**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: BUILD SUCCESS

- [x] **Step 6: Run tests to verify dual registration doesn't break anything**

Run: `cd /home/boss/codes/luazig && python3 tools/testes_matrix.py --timeout 30 2>&1 | head -3`
Expected: 28/31 pass parity (no regression)

Run: `cd /home/boss/codes/luazig && for f in tests/smoke/*.lua; do timeout 5 zig-out/bin/luazig "$f" 2>&1 | tail -1; done | grep -c "."`
Expected: 45 (all smoke tests produce output)

- [x] **Step 7: Commit**

```bash
git add src/lua/vm.zig
git commit -m "GC refactor A2: add unified gc_objects list with dual registration"
```

---

### Task A3: Migrate `gcMarkValue` / `gcQueueScanValue` to use GcObject

**Files:**
- Modify: `src/lua/vm.zig` — `gcMarkValue` (line 14458), `gcQueueScanValue` (line 13023), `gcPropagateOne` (line 14497), `gc_gray` field (line 1748)

- [x] **Step 1: Change `gc_gray` from `ArrayList(Value)` to `ArrayList(GcObject)`**

At line 1748, change:
```zig
    gc_gray: std.ArrayListUnmanaged(Value) = .empty,
```
to:
```zig
    gc_gray: std.ArrayListUnmanaged(GcObject) = .empty,
```

- [x] **Step 2: Rewrite `gcQueueScanValue` to use GcObject**

Replace `gcQueueScanValue` (line 13023) with:

```zig
    fn gcQueueScanValue(self: *Vm, value: Value) DispatchError!void {
        const obj = GcObject.fromValue(value) orelse return;
        try self.gcQueueScanObject(obj);
    }

    fn gcQueueScanObject(self: *Vm, obj: GcObject) DispatchError!void {
        const p = gcPtr(obj);
        if (!gcIsWhite(p.marked.*)) return;
        // Strings have no outgoing edges — go straight to black.
        if (obj == .string) {
            gcSetBlack(p.marked);
        } else {
            gcSetGray(p.marked);
            try self.gc_gray.append(self.alloc, obj);
        }
    }
```

- [x] **Step 3: Rewrite `gcQueueScanCell` to delegate to `gcQueueScanObject`**

Replace `gcQueueScanCell` (line 13056) with:

```zig
    fn gcQueueScanCell(self: *Vm, cell: *Cell) DispatchError!void {
        // Open upvalues are kept gray (like PUC's LUA_VUPVAL handling);
        // closed upvalues are treated like regular objects.
        if (cell.open) {
            if (!gcIsWhite(cell.gc_marked)) return;
            if (!gcIsGray(cell.gc_marked)) {
                gcSetGray(&cell.gc_marked);
                try self.gc_grayagain.append(self.alloc, .{ .cell = cell });
            }
        } else {
            try self.gcQueueScanObject(.{ .cell = cell });
        }
    }
```

Note: `gc_grayagain` will be changed to `ArrayList(GcObject)` in Step 5.

- [x] **Step 4: Rewrite `gcMarkValue` to use GcObject**

Replace `gcMarkValue` (line 14458) with:

```zig
    fn gcMarkValue(self: *Vm, v: Value) DispatchError!void {
        if (self.gc_minor_cycle) return self.gcMarkMinorValue(v);
        const obj = GcObject.fromValue(v) orelse return;
        try self.gcQueueScanObject(obj);
        self.gc_mark_epoch += 1;
    }
```

The old `gcMarkValue` switch had special handling for `.String` (immediate black) vs `.Table/.Closure/.Thread` (gray + queue). That logic is now in `gcQueueScanObject`. The `gc_mark_epoch` increment was previously inside each case — now it's at the end.

Also update `gcMarkMinorValue` similarly — replace the switch body with:
```zig
    fn gcMarkMinorValue(self: *Vm, v: Value) DispatchError!void {
        const obj = GcObject.fromValue(v) orelse return;
        try self.gcQueueScanObject(obj);
    }
```

- [x] **Step 5: Update `gcPropagateOne` to take GcObject from `gc_gray`**

The function currently pops a `Value` from `gc_gray`. Now `gc_gray` holds `GcObject`. Update the function signature and switch:

At line 14498, change:
```zig
        const cur = self.gc_gray.pop() orelse return false;
```
The `cur` is now `GcObject`. The switch at line 14505 changes from `switch (cur)` on Value to `switch (cur)` on GcObject. The variant names change from `.Table`/`.Closure`/`.Thread` to `.table`/`.closure`/`.thread` (lowercase, GcObject variant names).

For the `else => {}` at line 14678: String and Cell now reach `gcPropagateOne` (they couldn't before because `gc_gray` was Value-typed and Cell isn't a Value). Add explicit handling:

```zig
        .string => {}, // strings go straight to black in gcQueueScanObject; no children
        .cell => |cell| {
            // Closed cell: mark its stored value.
            if (!cell.open) {
                try self.gcMarkValue(cell.value);
            }
            // Open cells are handled via gc_grayagain, not gc_gray.
            // If we get here for an open cell, mark it black (its value
            // was already marked when the cell was scanned).
        },
```

Also: the `gcValueAge(cur)` call at line 14501 currently takes `Value`. Change to:
```zig
        if (gcObjectAge(cur)) |age| { if (age.isOld()) self.gc_gen_last_minor_old_visited += 1; }
```

where `gcObjectAge` is a new accessor (see Step 6).

- [x] **Step 6: Add GcObject-based age/bytes accessors**

Add near the existing `gcValueAge` (line 12970):

```zig
    fn gcObjectAge(obj: GcObject) ?GcAge {
        return gcPtr(obj).age.*;
    }

    fn gcSetObjectAge(obj: GcObject, age: GcAge) void {
        gcPtr(obj).age.* = age;
    }
```

- [x] **Step 7: Update all `gc_gray.append` call sites**

Search for all `.append(self.alloc, value)` where the target list is `gc_gray`. These now need a `GcObject` instead of `Value`. Convert using `GcObject.fromValue(value).?` (safe because only GC-managed values are ever appended to `gc_gray`):

```bash
grep -n "gc_gray.append" src/lua/vm.zig
```

Each site like `try self.gc_gray.append(self.alloc, value)` where `value` is a `Value` changes to:
```zig
try self.gc_gray.append(self.alloc, GcObject.fromValue(value).?)
```

Or better: if the site has the typed pointer available (e.g., `table`), use:
```zig
try self.gc_gray.append(self.alloc, .{ .table = table })
```

- [x] **Step 8: Build and fix compilation errors**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -20`
Expected: Possible errors from `.append` sites that need `GcObject` instead of `Value`. Fix each by converting using `GcObject.fromValue()` or direct tagged union literal.

- [x] **Step 9: Run tests**

Run: `cd /home/boss/codes/luazig && python3 tools/testes_matrix.py --timeout 30 2>&1 | head -3`
Expected: 28/31 pass parity

Run smoke tests (45/45 must pass).

- [x] **Step 10: Commit**

```bash
git add src/lua/vm.zig
git commit -m "GC refactor A3: migrate gcMarkValue/gcPropagateOne to GcObject"
```

---

### Task A4: Migrate generational lists (`gc_old1`, `gc_grayagain`) to GcObject

**Files:**
- Modify: `src/lua/vm.zig` — `gc_old1` (line 1710), `gc_old1_cells` (line 1711), `gc_grayagain` (line 1712), `gc_grayagain_cells` (line 1713)

- [x] **Step 1: Change list types from Value/per-type to GcObject**

At lines 1710–1713, change:
```zig
    gc_old1: std.ArrayListUnmanaged(Value) = .empty,
    gc_old1_cells: std.ArrayListUnmanaged(*Cell) = .empty,
    gc_grayagain: std.ArrayListUnmanaged(Value) = .empty,
    gc_grayagain_cells: std.ArrayListUnmanaged(*Cell) = .empty,
```
to:
```zig
    gc_old1: std.ArrayListUnmanaged(GcObject) = .empty,
    gc_grayagain: std.ArrayListUnmanaged(GcObject) = .empty,
```

Remove `gc_old1_cells` and `gc_grayagain_cells` entirely. All their entries now go into `gc_old1` and `gc_grayagain` as `.{ .cell = cell }`.

- [x] **Step 2: Update snapshot lengths**

Remove lines 1724–1726:
```zig
    gc_old1_cells_snapshot_len: usize = 0,
    gc_grayagain_snapshot_len: usize = 0,
    gc_grayagain_cells_snapshot_len: usize = 0,
```

Keep `gc_old1_snapshot_len` and add:
```zig
    gc_grayagain_snapshot_len: usize = 0,
```

- [x] **Step 3: Update all `gc_old1`/`gc_grayagain` append sites**

Search for all `.append` to these lists:

```bash
grep -n "gc_old1.append\|gc_grayagain.append\|gc_old1_cells.append\|gc_grayagain_cells.append" src/lua/vm.zig
```

Each `gc_old1_cells.append(self.alloc, cell)` becomes `gc_old1.append(self.alloc, .{ .cell = cell })`.

Each `gc_grayagain.append(self.alloc, value)` (Value-typed) becomes `gc_grayagain.append(self.alloc, GcObject.fromValue(value).?)`.

Each `gc_grayagain_cells.append(self.alloc, cell)` becomes `gc_grayagain.append(self.alloc, .{ .cell = cell })`.

- [x] **Step 4: Update `gcMinorCollection` (line 14114)**

Replace the grayagain re-traversal (lines 14155–14172) — change the switch from `switch (value)` on Value to `switch (obj)` on GcObject:

```zig
        for (self.gc_grayagain.items[0..self.gc_grayagain_snapshot_len]) |obj| {
            const p = gcPtr(obj);
            gcSetGray(p.marked);
            try self.gc_gray.append(self.alloc, obj);
        }
```

This replaces the old Value switch (`.Table`, `.Closure`, `.Thread`, `else => {}`) with a uniform loop — GcObject dispatches to gcPtr which handles all types.

Remove the old `gc_grayagain_cells` re-traversal loop (line 14172).

Update `gc_old1` re-traversal (line 14149) — change from Value to GcObject:
```zig
        for (self.gc_old1.items[0..self.gc_old1_snapshot_len]) |obj| try self.gcQueueScanObject(obj);
```

Remove the `gc_old1_cells` re-traversal (line 14150).

- [x] **Step 5: Update `gcRememberValue` (line 13075)**

This function currently takes `Value`. It needs to handle Cell too. Change signature to accept `GcObject`:

```zig
    fn gcRememberObject(self: *Vm, owner: GcObject) DispatchError!void {
        if (self.gc_mode != .generational or self.gc_gen_phase != .minor) return;
        const age = gcObjectAge(owner) orelse return;
        switch (age) {
            .old0, .old1 => {
                gcSetTouched1(gcPtr(owner).marked);
                try self.gc_grayagain.append(self.alloc, owner);
            },
            .old => {
                gcSetTouched2(gcPtr(owner).marked);
                try self.gc_old1.append(self.alloc, owner);
            },
            else => {},
        }
    }
```

Keep `gcRememberValue` as a thin wrapper:
```zig
    fn gcRememberValue(self: *Vm, owner: Value) DispatchError!void {
        if (GcObject.fromValue(owner)) |obj| try self.gcRememberObject(obj);
    }
```

- [x] **Step 6: Update `gcClearGenerationalLists` (line 13147)**

Remove `gc_old1_cells`, `gc_grayagain_cells` clear calls. The remaining lists clear as before.

- [x] **Step 7: Build and fix errors**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -20`

Fix all compilation errors from the type changes. Search for remaining references to removed fields:
```bash
grep -n "gc_old1_cells\|gc_grayagain_cells" src/lua/vm.zig
```
Expected: no matches after all sites updated.

- [x] **Step 8: Run tests**

Run matrix (28/31 expected) and smoke (45/45 expected).

- [x] **Step 9: Commit**

```bash
git add src/lua/vm.zig
git commit -m "GC refactor A4: unify gc_old1/gc_grayagain as GcObject, eliminate Cell parallel lists"
```

---

### Task A5: Unify sweep — eliminate `GcSweepKind`

**Files:**
- Modify: `src/lua/vm.zig` — `GcSweepKind` (line 1578), `gcSweepOne` (line 14190), `gc_sweep_kind`/`gc_sweep_cursor` (lines 1763–1764)

- [x] **Step 1: Remove `GcSweepKind` enum**

Delete line 1578:
```zig
const GcSweepKind = enum { tables, threads, closures, strings, cells, intern_tables, done };
```

- [x] **Step 2: Replace `gc_sweep_kind` and `gc_sweep_cursor` with `gc_sweep_objects_cursor`**

At lines 1763–1764, replace:
```zig
    gc_sweep_kind: GcSweepKind = .tables,
    gc_sweep_cursor: usize = 0,
```
with:
```zig
    gc_sweep_objects_cursor: usize = 0,
```

Also remove the old per-type snapshot lengths at lines 1758–1762:
```zig
    gc_tables_snapshot_len: usize = 0,
    gc_closures_snapshot_len: usize = 0,
    gc_threads_snapshot_len: usize = 0,
    gc_strings_snapshot_len: usize = 0,
    gc_cells_snapshot_len: usize = 0,
```
(Keep `gc_objects_snapshot_len` added in Task A2.)

- [x] **Step 3: Rewrite `gcSweepOne` as a single-pass sweep over `gc_objects`**

Replace `gcSweepOne` (line 14190) with:

```zig
    /// Incremental sweep: walk gc_objects up to snapshot length, freeing
    /// dead objects. Returns true if there are more objects to sweep.
    /// PUC-faithful: sweeps allgc in allocation order.
    fn gcSweepOne(self: *Vm) DispatchError!bool {
        if (self.gc_sweep_objects_cursor >= self.gc_objects_snapshot_len) {
            // Sweep remaining post-snapshot objects (allocated during sweep).
            // Reset their marks; they survive this cycle.
            if (self.gc_sweep_objects_cursor < self.gc_objects.items.len) {
                const obj = self.gc_objects.items[self.gc_sweep_objects_cursor];
                gcPtr(obj).marked.* = self.gc_current_white & WHITEBITS;
                self.gc_sweep_objects_cursor += 1;
                return true;
            }
            // Sweep intern tables (long literals).
            try self.long_literals.sweep(self.alloc, self.gc_current_white);
            return false;
        }

        const obj = self.gc_objects.items[self.gc_sweep_objects_cursor];
        self.gc_sweep_objects_cursor += 1;
        const p = gcPtr(obj);
        const is_dead = gcIsDead(p.marked.*, self.gc_current_white) and
            (p.marked.* & FINALIZEDBIT) == 0;
        const has_finalizer = gcCanFinalize(obj) and self.gcHasFinalizer(obj);

        if (is_dead and !has_finalizer) {
            // Object is dead — free it.
            self.gcFreeObject(obj);
            _ = self.gc_objects.swapRemove(self.gc_sweep_objects_cursor - 1);
            if (self.gc_sweep_objects_cursor - 1 < self.gc_objects.items.len) {
                const swapped = self.gc_objects.items[self.gc_sweep_objects_cursor - 1];
                gcPtr(swapped).index.* = self.gc_sweep_objects_cursor - 1;
            }
            self.gc_sweep_objects_cursor -= 1; // re-examine the swapped entry
        } else {
            // Object is alive — reset mark to current white.
            p.marked.* = self.gc_current_white & WHITEBITS;
        }
        return true;
    }

    /// Free a GC object's memory. Type-specific teardown.
    fn gcFreeObject(self: *Vm, obj: GcObject) void {
        switch (obj) {
            .table => |t| { t.deinit(self.alloc); self.alloc.destroy(t); },
            .closure => |c| self.alloc.destroy(c),
            .thread => |th| {
                self.freeThreadWrapBuffers(th);
                self.freeThreadBytecodeFrames(th);
                if (self.active_runtime_thread != th) self.freeParkedThreadRuntime(th);
                if (th.yielded) |ys| self.alloc.free(ys);
                if (th.locals_snapshot) |snap| self.alloc.free(snap);
                self.alloc.destroy(th);
            },
            .string => |s| destroyLuaString(self.alloc, s),
            .cell => |c| self.alloc.destroy(c),
        }
    }

    /// Check if an object has a registered finalizer (__gc metamethod).
    fn gcHasFinalizer(self: *Vm, obj: GcObject) bool {
        return switch (obj) {
            .table => |t| self.finalizables.contains(t),
            .closure => false, // closures don't use finalizables in current code
            .thread => false,
            .string, .cell => false,
        };
    }
```

- [x] **Step 4: Update snapshot length setting**

Search for where `gc_tables_snapshot_len`, `gc_closures_snapshot_len`, etc. are set (in `gcAtomicCommon` or similar). Replace with:
```zig
self.gc_objects_snapshot_len = self.gc_objects.items.len;
```

- [x] **Step 5: Update sweep state initialization**

Search for `gc_sweep_kind = .tables` and replace with:
```zig
self.gc_sweep_objects_cursor = 0;
```

- [x] **Step 6: Build and fix errors**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -20`

Fix all references to removed `gc_sweep_kind`, `GcSweepKind`, per-type snapshot lengths.

- [x] **Step 7: Run tests**

Run matrix (28/31 expected) and smoke (45/45 expected).

- [x] **Step 8: Commit**

```bash
git add src/lua/vm.zig
git commit -m "GC refactor A5: unified sweep over gc_objects, eliminate GcSweepKind"
```

---

### Task A6: Unify generational sweep and make-all-white/old

**Files:**
- Modify: `src/lua/vm.zig` — `gcSweepYoungTables`/`gcSweepYoungClosures`/etc. (lines 13871–14019), `gcMakeAllWhite` (13167), `gcMakeAllOld` (13180), `gcClearFinalizedBit` (13764)

- [x] **Step 1: Replace 5 `gcSweepYoung*` functions with one `gcSweepYoungObjects`**

Replace all 5 functions (lines 13871–14019) with:

```zig
    fn gcSweepYoungObjects(self: *Vm) DispatchError!void {
        const snapshot = @min(self.gc_young_objects_snapshot_len, self.gc_young_objects.items.len);
        var write: usize = 0;
        for (self.gc_young_objects.items[0..snapshot]) |obj| {
            const p = gcPtr(obj);
            const alive = !gcIsDead(p.marked.*, self.gc_current_white) or
                (p.marked.* & FINALIZEDBIT) != 0 or
                p.age.* == .old0;
            if (!alive) {
                self.gcFreeObject(obj);
                self.gcUnregisterObject(obj);
                continue;
            }
            p.marked.* = self.gc_current_white & WHITEBITS;
            if (try self.gcPromoteYoungObject(obj)) {
                self.gc_young_objects.items[write] = obj;
                write += 1;
            }
        }
        // Compact post-snapshot entries (mid-cycle allocations).
        for (self.gc_young_objects.items[snapshot..]) |obj| {
            gcPtr(obj).marked.* = self.gc_current_white & WHITEBITS;
            self.gc_young_objects.items[write] = obj;
            write += 1;
        }
        self.gc_young_objects.items.len = write;
    }
```

- [x] **Step 2: Replace `gcPromoteYoungValue`/`gcPromoteYoungCell` with `gcPromoteYoungObject`**

Replace `gcPromoteYoungValue` (line 13827) and `gcPromoteYoungCell` (line 13851) with:

```zig
    fn gcPromoteYoungObject(self: *Vm, obj: GcObject) DispatchError!bool {
        const p = gcPtr(obj);
        switch (p.age.*) {
            .new => { p.age.* = .survival; return true; },
            .survival => { p.age.* = .old0; try self.gc_old1.append(self.alloc, obj); return false; },
            .old0 => { p.age.* = .old1; return false; },
            else => return true, // old1, old, touched — keep in young list
        }
    }
```

- [x] **Step 3: Replace `gcMakeAllWhite` with unified version**

Replace `gcMakeAllWhite` (line 13167) with:

```zig
    fn gcMakeAllWhite(self: *Vm) void {
        const w = self.gc_current_white & WHITEBITS;
        for (self.gc_objects.items) |obj| {
            gcPtr(obj).marked.* = w;
        }
        // Short strings and long literals are in separate stores.
        var short_it = self.string_intern.table.iterator();
        while (short_it.next()) |entry| entry.value_ptr.*.gc_marked = w;
        var literal_it = self.long_literals.table.iterator();
        while (literal_it.next()) |entry| entry.value_ptr.*.gc_marked = w;
    }
```

- [x] **Step 4: Replace `gcMakeAllOld` with unified version**

Replace `gcMakeAllOld` (line 13180) with:

```zig
    fn gcMakeAllOld(self: *Vm) std.mem.Allocator.Error!void {
        self.gcClearGenerationalLists();
        for (self.gc_objects.items) |obj| {
            gcPtr(obj).age.* = .old;
            if (obj == .thread) {
                try self.gc_gen_threads.append(self.alloc, obj.thread);
            }
        }
        var short_it = self.string_intern.table.iterator();
        while (short_it.next()) |entry| entry.value_ptr.*.gc_age = .old;
        var literal_it = self.long_literals.table.iterator();
        while (literal_it.next()) |entry| entry.value_ptr.*.gc_age = .old;
    }
```

- [x] **Step 5: Replace `gcClearFinalizedBit` with unified version**

Replace `gcClearFinalizedBit` (line 13764) with:

```zig
    fn gcClearFinalizedBit(self: *Vm) void {
        for (self.gc_objects.items) |obj| {
            gcPtr(obj).marked.* &= ~FINALIZEDBIT;
        }
    }
```

- [x] **Step 6: Update `gcMinorCollection` to use unified young list**

At lines 14124–14128, replace per-type snapshot setting:
```zig
        self.gc_young_objects_snapshot_len = self.gc_young_objects.items.len;
```

At lines 14142–14146, replace per-type mark reset:
```zig
        for (self.gc_young_objects.items) |obj| gcPtr(obj).marked.* = self.gc_current_white & WHITEBITS;
```

At line 14177, replace `gcSweepYoungGeneration` call:
```zig
        try self.gcSweepYoungObjects();
```

- [x] **Step 7: Update `gcClearGenerationalLists`**

Replace the per-type clear calls with:
```zig
    fn gcClearGenerationalLists(self: *Vm) void {
        self.gc_young_objects.clearRetainingCapacity();
        self.gc_old1.clearRetainingCapacity();
        self.gc_grayagain.clearRetainingCapacity();
        self.gc_gen_threads.clearRetainingCapacity();
    }
```

- [x] **Step 8: Update `drainGcRegistries`**

The per-type free loops (lines 2346–2385) can now be replaced by a single loop:
```zig
        for (self.gc_objects.items) |obj| {
            self.gcFreeObject(obj);
        }
        self.gc_objects.deinit(self.alloc);
```

But KEEP the per-type `.deinit(self.alloc)` calls for the old per-type lists (they still exist during migration). Actually — by this point, the per-type lists should be empty if all registration is dual (per-type + unified). The per-type free loops can be removed.

Wait — the old per-type lists are still being appended to by the old `gcRegister*T` functions. In Task A2, we added dual registration. To fully remove the old lists, we need to remove the per-type registration from `gcRegister*T`.

Let me reconsider the order. Actually, let's keep the old lists and their free loops for now. They'll be removed in Task A7 when we remove the old registration entirely.

- [x] **Step 9: Build and fix errors**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -20`

- [x] **Step 10: Run tests**

Run matrix (28/31 expected) and smoke (45/45 expected).

- [x] **Step 11: Commit**

```bash
git add src/lua/vm.zig
git commit -m "GC refactor A6: unified generational sweep, make-all-white/old, finalize bit"
```

---

### Task A7: Remove old per-type lists and registration

**Files:**
- Modify: `src/lua/vm.zig` — Remove old fields, functions, and migration scaffolding

- [x] **Step 1: Remove per-type list fields**

Remove lines 1662–1670:
```zig
    gc_tables, gc_closures, gc_threads, gc_cells, gc_strings
```

Remove lines 1705–1709:
```zig
    gc_young_tables, gc_young_closures, gc_young_threads, gc_young_cells, gc_young_strings
```

Remove lines 1715–1719 (young snapshot lengths).

- [x] **Step 2: Simplify `gcRegister*T` functions**

Replace each of the 5 `gcRegister*T` functions with a call to `gcRegisterObject`:

```zig
    fn gcRegisterTable(self: *Vm, table: *Table) std.mem.Allocator.Error!void {
        try self.gcRegisterObject(.{ .table = table });
    }
```

Repeat for Closure, Thread, Cell, String. (Keep the wrappers for call-site compatibility.)

- [x] **Step 3: Simplify `gcUnregister*T` functions**

```zig
    fn gcUnregisterTable(self: *Vm, table: *Table) void {
        self.gcUnregisterObject(.{ .table = table });
    }
```

- [x] **Step 4: Remove old `gcSweepYoung*` functions**

Delete the bodies of the old per-type young sweep functions (they were replaced by `gcSweepYoungObjects` in Task A6).

- [x] **Step 5: Remove old per-type drain loops in `drainGcRegistries`**

Remove the per-type iteration loops (lines 2346–2385). The unified loop from Task A6 Step 8 handles all freeing.

- [x] **Step 6: Update `gcPropagateOne` Thread case — remove `if (v == .Table or .Closure or ...)` chains**

The 24 `if (v == .Table or v == .Closure or v == .Thread or v == .String)` checks inside the Thread propagation case (lines 14532–14804) can be simplified to `if (GcObject.fromValue(v) != null)`. This is a mechanical find-and-replace:

Replace:
```zig
if (v == .Table or v == .Closure or v == .Thread or v == .String)
```
with:
```zig
if (GcObject.fromValue(v) != null)
```

- [x] **Step 7: Build**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -20`

- [x] **Step 8: Run full test suite**

Run: `cd /home/boss/codes/luazig && python3 tools/testes_matrix.py --timeout 30 2>&1 | head -3`
Expected: 28/31 pass parity

Run: `cd /home/boss/codes/luazig && python3 tools/testes_matrix.py --testc --timeout 30 --no-ref 2>&1 | head -3`
Expected: 25/31 (testC baseline)

Run all smoke tests (45/45 expected).

- [x] **Step 9: Commit**

```bash
git add src/lua/vm.zig
git commit -m "GC refactor A7: remove per-type lists, fully unified GcObject"
```

---

## Part B: Full Userdata Type

### Task B1: Define Userdata struct and add to Value + GcObject

**Files:**
- Modify: `src/lua/vm.zig` — Value union (line ~1422), GcObject union

- [x] **Step 1: Define `Userdata` struct**

Add near the `Table` struct definition:

```zig
/// Full userdata (PUC `LUA_TUSERDATA`). GC-managed, with per-object
/// metatable and an array of user values. Mirrors PUC's `Udata` struct
/// (`lobject.h:491-498`) but uses separate Zig slices instead of PUC's
/// inline `uv[1]` + binary data layout.
pub const Userdata = struct {
    gc_marked: u8 = 0,
    gc_age: GcAge = .new,
    gc_index: usize = 0,
    /// Per-object metatable (PUC `Udata.metatable`). Null = no metatable.
    metatable: ?*Table = null,
    /// User values array (PUC `Udata.uv[]`). `nuvalue` elements, all
    /// initialized to Nil. Accessed 1-indexed from Lua via debug.setiuservalue.
    uservalues: []Value = &.{},
    /// Binary payload (PUC `getudatamem(u)`). `len` bytes of raw data.
    /// The testC `newuserdata` command allocates this as zero-filled.
    payload: []u8 = &.{},
};
```

- [x] **Step 2: Add `Userdata` variant to `Value` union**

At line 1436 (after `LightUserdata: *anyopaque,`), add:

```zig
    Userdata: *Userdata,
```

Update `typeName` (line 1438):
```zig
            .Userdata => "userdata",
```

- [x] **Step 3: Add `userdata` variant to `GcObject` union**

In the `GcObject` definition from Task A1, add:

```zig
    userdata: *Userdata,
```

Update `toValue`:
```zig
            .userdata => |u| .{ .Userdata = u },
```

Update `fromValue`:
```zig
            .Userdata => |u| .{ .userdata = u },
```

Update `gcPtr`:
```zig
        .userdata => |u| .{ .marked = &u.gc_marked, .age = &u.gc_age, .index = &u.gc_index },
```

Update `gcObjectBytes`:
```zig
        .userdata => |u| @sizeOf(Userdata) + u.uservalues.len * @sizeOf(Value) + u.payload.len,
```

Update `gcCanFinalize`:
```zig
        .userdata => true,
```

- [x] **Step 4: Build and fix exhaustive switch errors**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -30`

The compiler will report all exhaustive switches missing `.Userdata`. Fix each:

**Value switches needing `.Userdata` case:**

| Function | Line | New case |
|---|---|---|
| `valueToString` | ~24175 | `.Userdata => \|ud\| try w.print("userdata: 0x{x}", .{@intFromPtr(ud)})` |
| `valueToStringAlloc` | ~24200 | `.Userdata => \|ud\| try std.fmt.allocPrint(self.alloc, "userdata: 0x{x}", .{@intFromPtr(ud)})` |
| `valueMetatable` | ~24629 | `.Userdata => \|ud\| ud.metatable` |
| `valuesEqual` | ~25278 | `.Userdata => \|lu\| switch (rhs) { .Userdata => \|ru\| lu == ru, else => false }` |
| `builtinType` | ~11230 | `.Userdata => "userdata"` |
| `builtinDebugSetmetatable` | ~17655 | `.Userdata => \|ud\| { ud.metatable = mt; /* barrier */ }` |
| testc `topointer` | ~26915 | `.Userdata => \|ud\| try self.makeTestcPointerValue(@intCast(@intFromPtr(ud)))` |

**GcObject/Gc switches needing `.userdata` case:**

| Function | Line | New case |
|---|---|---|
| `gcPropagateOne` | ~14505 | `.userdata => \|ud\| { if (ud.metatable) \|mt\| try self.gcMarkValue(.{ .Table = mt }); for (ud.uservalues) \|uv\| try self.gcMarkValue(uv); }` |
| `gcFreeObject` (from Task A5) | — | `.userdata => \|u\| { self.alloc.free(u.uservalues); self.alloc.free(u.payload); self.alloc.destroy(u); }` |
| `gcHasFinalizer` (from Task A5) | — | `.userdata => \|u\| if (u.metatable) \|mt\| self.finalizables.contains(mt) else false` |

**api.zig `valueType`:**
```zig
.Userdata => .userdata,
```

**bc_vm.zig `valuesEqual`:**
```zig
.Userdata => |lu| switch (rhs) { .Userdata => |ru| lu == ru, else => false },
```

**ltable.zig** — add `userdata` variant to `NodeKeyTag`/`NodeKeyPayload` and related functions (6 sites, see audit). Only if Userdata can be a table key (PUC allows it).

- [x] **Step 5: Build successfully**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: BUILD SUCCESS

- [x] **Step 6: Commit**

```bash
git add src/lua/vm.zig src/lua/api.zig src/lua/bc_vm.zig src/lua/ltable.zig
git commit -m "Userdata B1: define Userdata struct, add to Value/GcObject, fix all switches"
```

---

### Task B2: Implement Userdata allocation and metatable semantics

**Files:**
- Modify: `src/lua/vm.zig` — allocation functions, `cmpEq`, `builtinDebugSetmetatable`

- [x] **Step 1: Add `allocUserdata` function**

Near `allocTable` (line ~3264):

```zig
    /// Allocate a new full userdata (PUC `luaS_newudata` / `lua_newuserdatauv`).
    /// `size` is the binary payload size; `nuvalue` is the number of user values.
    /// All payload bytes are zero-filled; all uservalues are Nil.
    fn allocUserdata(self: *Vm, size: usize, nuvalue: usize) DispatchError!*Userdata {
        try self.testcChargeMemory(@sizeOf(Userdata) + nuvalue * @sizeOf(Value) + size);
        const ud = try self.alloc.create(Userdata);
        ud.* = .{
            .uservalues = if (nuvalue > 0) try self.alloc.alloc(Value, nuvalue) else &.{},
            .payload = if (size > 0) try self.alloc.alloc(u8, size) else &.{},
        };
        @memset(ud.payload, 0);
        for (ud.uservalues) |*uv| uv.* = .Nil;
        try self.gcRegisterObject(.{ .userdata = ud });
        self.gcNoteAlloc(@sizeOf(Userdata) + nuvalue * @sizeOf(Value) + size);
        return ud;
    }
```

- [x] **Step 2: Fix `cmpEq` to check type compatibility (PUC `luaV_equalobj`)**

Replace `cmpEq` (line ~25331):

```zig
    fn cmpEq(self: *Vm, lhs: Value, rhs: Value) DispatchError!bool {
        if (valuesEqual(lhs, rhs)) return true;
        // PUC luaV_equalobj: __eq metamethod is invoked only when both
        // operands are the same type (both table, both userdata, etc.).
        // Different types → false without metamethod (events.lua:347).
        if (lhs == .Table and rhs == .Table) {
            if (try self.callBinaryMetamethod(lhs, rhs, "__eq", "eq")) |v| return isTruthy(v);
        }
        if (lhs == .Userdata and rhs == .Userdata) {
            if (try self.callBinaryMetamethod(lhs, rhs, "__eq", "eq")) |v| return isTruthy(v);
        }
        return false;
    }
```

This is the KEY fix for `events.lua:347`: `u2` (Userdata) vs `{}` (Table) → different types → `__eq` NOT called → `false`.

- [x] **Step 3: Update `builtinDebugSetmetatable` for Userdata**

In the `builtinDebugSetmetatable` switch (line ~17655), the `.Userdata` case:

```zig
            .Userdata => |ud| {
                ud.metatable = mt;
                if (mt) |m| {
                    try self.gcWriteBarrierValue(.{ .Userdata = ud }, .{ .Table = m });
                }
            },
```

- [x] **Step 4: Add `debug.setuservalue` / `debug.getuservalue` for real Userdata**

In `builtinDebugSetuservalue` (line ~18080), add Userdata handling:

```zig
    // Before the table-based isTestcUserdata fallback:
    if (target == .Userdata) {
        const ud = target.Userdata;
        if (ud.uservalues.len > 0) {
            ud.uservalues[0] = value;
            try self.gcWriteBarrierValue(.{ .Userdata = ud }, value);
        }
        if (outs.len > 0) outs[0] = target;
        self.last_builtin_out_count = @min(outs.len, 1);
        return;
    }
```

Similarly in `builtinDebugGetuservalue` (line ~18113):

```zig
    if (target == .Userdata) {
        const ud = target.Userdata;
        if (outs.len > 0) outs[0] = if (ud.uservalues.len > 0) ud.uservalues[0] else .Nil;
        self.last_builtin_out_count = @min(outs.len, 1);
        return;
    }
```

- [x] **Step 5: Build**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5`

- [x] **Step 6: Run quick test**

```bash
cat > /tmp/test_userdata_eq.lua << 'EOF'
local u1 = T.newuserdata(0, 1)
local u2 = T.newuserdata(0, 1)
local u3 = T.newuserdata(0, 1)
print("u1 ~= u2:", u1 ~= u2)  -- true (different objects)
debug.setmetatable(u2, {__eq = function(a, b) return true end})
print("u2 == u1:", u2 == u1)  -- true (__eq returns true, both userdata)
print("u2 ~= {}:", u2 ~= {})  -- true (different types, __eq NOT called)
EOF
cd /home/boss/codes/luazig && timeout 5 zig-out/bin/luazig --testc /tmp/test_userdata_eq.lua 2>&1
```

Expected: `u1 ~= u2: true`, `u2 == u1: true`, `u2 ~= {}: true`

NOTE: `T.newuserdata` still creates table-based emulation at this point. Task B3 migrates it to real Userdata. This test will pass only after B3.

- [x] **Step 7: Commit**

```bash
git add src/lua/vm.zig
git commit -m "Userdata B2: allocUserdata, cmpEq type check, debug.setuservalue/getuservalue"
```

---

### Task B3: Migrate `T.newuserdata` from table emulation to real Userdata

**Files:**
- Modify: `src/lua/vm.zig` — testC bootstrap (line ~10663), testC `newuserdata` command handler (line ~26978)

- [ ] **Step 1: Add `testc_newuserdata` builtin**

Add to `BuiltinId` enum, `name()` function, `callBuiltin` dispatch, and T table registration (following the pattern of existing testc builtins):

In `BuiltinId` enum:
```zig
    testc_newuserdata,
```

In `name()`:
```zig
    .testc_newuserdata => "T._newuserdata",
```

In `callBuiltin`:
```zig
    .testc_newuserdata => try self.builtinTestcNewuserdata(args, outs),
```

In `enableTestcModuleInternal` (line ~10638):
```zig
    try self.setField(t, "_newuserdata", .{ .Builtin = .testc_newuserdata });
```

Implementation:

```zig
    /// PUC ltests `newuserdata`: creates full userdata with given size
    /// and nuvalue. Returns the userdata value.
    fn builtinTestcNewuserdata(self: *Vm, args: []const Value, outs: []Value) DispatchError!void {
        if (args.len < 1) return self.fail("T._newuserdata expects size", .{});
        const sz: usize = switch (args[0]) {
            .Int => |i| if (i < 0) 0 else @intCast(i),
            .Num => |n| if (n < 0) 0 else @intFromFloat(n),
            else => return self.fail("T._newuserdata: number expected", .{}),
        };
        if (sz > 1_000_000_000) return self.fail("block too big", .{});
        const nuvalue: usize = if (args.len >= 2) switch (args[1]) {
            .Int => |i| if (i < 0) 0 else @intCast(i),
            .Num => |n| if (n < 0) 0 else @intFromFloat(n),
            else => 0,
        } else 0;
        const ud = try self.allocUserdata(sz, nuvalue);
        if (outs.len > 0) outs[0] = .{ .Userdata = ud };
        self.last_builtin_out_count = @min(outs.len, 1);
    }
```

- [ ] **Step 2: Update testC bootstrap to use real Userdata**

Replace the Lua `T.newuserdata` function in the bootstrap (lines ~10663–10680):

```lua
function T.newuserdata(sz, val)
    sz = tonumber(sz) or 0
    if sz > 1000000000 then error("block too big") end
    local lim = select(3, T.totalmem())
    if lim ~= 0 and T.totalmem() + sz > lim then error("not enough memory") end
    local nuv = (val ~= nil) and 1 or 0
    local ud = T._newuserdata(sz, nuv)
    if val ~= nil then
        debug.setuservalue(ud, val)
    end
    return ud
end
```

Remove the old table-based `__testud`/`__ptr`/`__size`/`__isnull`/`__val`/`__light` fields.

- [ ] **Step 3: Update `T.udataval`**

In the bootstrap, update `T.udataval`:

```lua
function T.udataval(u)
    if type(u) ~= "userdata" then return nil end
    -- For full userdata, return the pointer address as a number.
    -- PUC's udataval returns getudatamem pointer; tests use it for identity.
    return tonumber(string.format("%p", u):match("0x(%x+)"), 16)
end
```

Actually, PUC's `udataval` returns `*(lua_Unsigned*)getudatamem(u)` — the VALUE stored in the userdata's payload. For testC `newuserdata(sz, val)`, the `val` is stored as uservalue[0]. So `udataval` should return uservalue[0]:

```lua
function T.udataval(u)
    if type(u) ~= "userdata" then return nil end
    return debug.getuservalue(u)
end
```

- [ ] **Step 4: Update `T.objsize` for Userdata**

The testC `objsize` command (and `T.objsize` if it exists) should return `ud.payload.len` for Userdata. Search for `objsize` in testC command handler and add:

```zig
            // In testC objsize handler:
            .Userdata => |ud| @intCast(ud.payload.len),
```

- [ ] **Step 5: Update testC `newuserdata` command**

In the testC `newuserdata` command handler (line ~26978), replace the table-based approach with calling the builtin:

```zig
            .newuserdata => {
                if (cargs.len != 1) return self.fail("testC newuserdata expects 1 arg", .{});
                const sz = std.fmt.parseInt(i64, cargs[0], 10) catch return self.fail("testC invalid userdata size", .{});
                const ud = try self.allocUserdata(@intCast(@max(0, sz)), 0);
                try st.append(self.alloc, .{ .Userdata = ud });
            },
```

- [ ] **Step 6: Update `isTestcUserdata` / `isTestcLightUserdata`**

Replace these workaround functions:

```zig
    fn isTestcUserdata(v: Value) bool {
        return v == .Userdata;
    }

    fn isTestcLightUserdata(v: Value) bool {
        return v == .LightUserdata;
    }
```

Remove `isTestcNullPointer` or update it to check `v == .LightUserdata`.

- [ ] **Step 7: Build**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5`

- [ ] **Step 8: Run targeted userdata test**

```bash
cat > /tmp/test_userdata_full.lua << 'EOF'
local u1 = T.newuserdata(0, 1)
local u2 = T.newuserdata(0, 1)
local u3 = T.newuserdata(0, 1)
assert(u1 ~= u2 and u1 ~= u3)
debug.setuservalue(u1, 1)
debug.setuservalue(u2, 2)
debug.setuservalue(u3, 1)
debug.setmetatable(u1, {__eq = function (a, b)
    return debug.getuservalue(a) == debug.getuservalue(b)
end})
debug.setmetatable(u2, {__eq = function (a, b)
    return true
end})
assert(u1 == u3 and u3 == u1 and u1 ~= u2)
assert(u2 == u1 and u2 == u3 and u3 == u2)
assert(u2 ~= {})   -- different types cannot be equal
assert(rawequal(u1, u1) and not rawequal(u1, u3))
print("ALL PASS")
EOF
cd /home/boss/codes/luazig && timeout 5 zig-out/bin/luazig --testc /tmp/test_userdata_full.lua 2>&1
```

Expected: `ALL PASS`

- [ ] **Step 9: Run events.lua specifically**

```bash
cd /home/boss/codes/luazig/lua-5.5.0/testes && timeout 30 ../../zig-out/bin/luazig --testc events.lua 2>&1 | tail -5
```

Expected: events.lua passes (was previously failing at line 347).

- [ ] **Step 10: Commit**

```bash
git add src/lua/vm.zig
git commit -m "Userdata B3: migrate T.newuserdata to real Userdata, fix events.lua"
```

---

### Task B4: Full regression testing and cleanup

- [ ] **Step 1: Run full testC matrix**

```bash
cd /home/boss/codes/luazig && python3 tools/testes_matrix.py --testc --timeout 30 --no-ref 2>&1 | head -5
```

Expected: 26/31+ (events.lua should now pass). Remaining fails: cstack.lua (ERRORSTACKSIZE), code.lua (constant folding), attrib.lua (require), big.lua (pre-existing), files.lua (pre-existing).

- [ ] **Step 2: Run normal matrix**

```bash
cd /home/boss/codes/luazig && python3 tools/testes_matrix.py --timeout 30 2>&1 | head -3
```

Expected: 28/31 (no regression).

- [ ] **Step 3: Run smoke tests**

```bash
cd /home/boss/codes/luazig && for f in tests/smoke/*.lua; do timeout 5 zig-out/bin/luazig "$f" 2>&1 | tail -1; done | grep -c "."
```

Expected: 45.

- [ ] **Step 4: Run testC lane (9 default suites)**

```bash
cd /home/boss/codes/luazig && python3 tools/testc_lane.py --timeout 30 2>&1
```

Expected: 9/9 ok.

- [ ] **Step 5: Update README**

Add a section documenting the GcObject refactor and Userdata addition, including what was fixed and what remains open.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "GC refactor + Userdata: update README with results"
```

---

## Risk Assessment

| Risk | Mitigation |
|---|---|
| GC UAF from missed mark sites | Run smoke + matrix after each task; GC bugs manifest as segfault, easy to detect |
| `swapRemove` index corruption | Assert invariant in `gcUnregisterObject`: `gc_objects.items[index] == obj` |
| Cell behavior change (folding into GcObject) | Cell has no semantic change — same mark/sweep, just unified infrastructure |
| testC bootstrap migration breaking existing tests | Step-by-step: first add real Userdata alongside table emulation, test, then switch |
| `gcPropagateOne` Thread case complexity | The 24-site `if (v == .Table or ...)` chain is mechanical `s/GcObject.fromValue(v) != null/` |

## Expected Final State

| Metric | Before | After |
|---|---|---|
| testC matrix | 25/31 | 26/31+ (events.lua passes) |
| Normal matrix | 28/31 | 28/31 (no regression) |
| Smoke | 45/45 | 45/45 |
| GC list boilerplate | 5 types × 15 sites = 75 | 0 (unified) |
| Adding new GC type cost | ~15 sites | 1 variant in GcObject + type-specific cases |

---

## Future Enhancement: `fasttm` Flags Cache for Metamethod Lookup

After completing both parts of this plan, a natural performance improvement is
implementing PUC Lua's `fasttm` mechanism (`ltm.h:63-68`, `ltm.c:60-68`).

### What PUC Does

PUC Lua caches the **absence** of tag methods (metamethods) directly on the
metatable's `flags` bitfield. Each `TMS` event (TM_EQ, TM_INDEX, TM_GC, etc.)
gets one bit. When `fasttm(L, mt, event)` is called:

```c
#define checknoTM(mt,e)  ((mt) == NULL || (mt)->flags & (1u<<(e)))
#define gfasttm(g,mt,e) \
    (checknoTM(mt, e) ? NULL : luaT_gettm(mt, e, (g)->tmname[e]))
```

If the bit is set (metamethod absent), `fasttm` returns `NULL` immediately —
no hash lookup. When a metamethod IS later added, the corresponding bit is
cleared (in `luaT_settm`). This is a per-metatable cache, not per-object.

The valid range for cached events is `TM_EQ` and below (`ltm.h:24`):
events `<= TM_EQ` use the flags cache; higher events (`__index`, `__newindex`,
etc.) always do a hash lookup because their bits are not maintained.

### Why It Matters for Us

Our `metamethodValue` function (`vm.zig:~24651`) currently does a full hash
lookup on the metatable every time a metamethod is needed:
`tableGetRawValue(mt, name)`. On hot paths like `__eq` (equality), `__index`
(table indexing), `__len`, `__concat`, this hash lookup is a measurable cost.

PUC's `fasttm` turns the common case ("metatable has no `__eq`") into a single
bit test — one AND instruction. This is the #1 metamethod optimization in PUC.

### Zig-Native Design

Instead of PUC's raw `lu_byte flags` + manual bit constants, we use a Zig
`PackedIntBitSet` or a simple `u32` with named enum constants:

```zig
/// Bitfield on Table.flags caching the ABSENCE of tag methods.
/// A set bit means "this metamethod is NOT present" (no hash lookup needed).
/// Matches PUC's `Table.flags` (`lobject.h:382`) + `TM_N` event ordering.
const TmFlags = struct {
    bits: u32 = 0xFFFF_FFFF, // all bits set = all metamethods absent (empty mt)

    /// Check if metamethod `event` is known absent (cached).
    fn isAbsent(self: TmFlags, event: TmsEvent) bool {
        return (self.bits & (@as(u32, 1) << @intFromEnum(event))) != 0;
    }

    /// Mark metamethod `event` as present (clear the bit).
    /// Called when a field named "__eq", "__index", etc. is written to the table.
    fn markPresent(self: *TmFlags, event: TmsEvent) void {
        self.bits &= ~(@as(u32, 1) << @intFromEnum(event));
    }
};

/// PUC TM_EVENT enum — ordering matters (must match PUC ltm.h:19-27).
const TmsEvent = enum(u5) {
    index,    // __index
    newindex, // __newindex
    gc,       // __gc
    mode,     // __mode
    len,      // __len
    eq,       // __eq — last "fast" event (flags cache valid for <= TM_EQ)
    // ... addi, mul, etc. (arithmetic events — not cached)
};
```

Wait — PUC's ordering has `TM_EQ` as the LAST cached event. Events above
`TM_EQ` (arithmetic, call, iter, close, etc.) are NOT cached in `flags`. The
`TmsEvent` enum must match PUC's ordering for the caching to be correct.

Actually, re-reading `ltm.h` more carefully:

```c
typedef enum {
    TM_INDEX,     // 0
    TM_NEWINDEX,  // 1
    TM_GC,        // 2
    TM_MODE,      // 3
    TM_LEN,       // 4
    TM_EQ,        // 5 — last "fast" event
    TM_ADD, ...   // arithmetic (not cached)
    TM_CALL,      // not cached
    TM_ITER,      // not cached
    TM_CLOSE,     // not cached
    TM_N          // count
} TMS;
```

Only events 0–5 (`TM_INDEX` through `TM_EQ`) are cached in `flags`. The
`checknoTM` macro is only used for `TM <= TM_EQ`.

So our design:

```zig
const TmsEvent = enum(u5) {
    index = 0,
    newindex = 1,
    gc = 2,
    mode = 3,
    len = 4,
    eq = 5,
    // Non-cached events follow but are NOT in the flags bitfield.
    // fasttm only works for events <= .eq.
    add, sub, mul, mod, pow, div, idiv, band, bor, bxor, shl, shr,
    unm, bnot, lt, le, concat, call, iter, close,
};

/// Maximum event index that is cached in TmFlags.
const TM_FAST_MAX: u5 = @intFromEnum(TmsEvent.eq);

fn fasttm(self: *Vm, mt: ?*Table, event: TmsEvent) ?Value {
    const table = mt orelse return null;
    if (@intFromEnum(event) <= TM_FAST_MAX and table.tm_flags.isAbsent(event))
        return null;
    // Not cached-absent — do the hash lookup.
    return self.tableGetRawValue(table, self.tm_names[@intFromEnum(event)]);
}
```

### What Needs to Change

1. **`Table` struct**: add `tm_flags: TmFlags` field (4 bytes).
2. **`tableSetValue`** (or `rawSet`): when setting a field whose name matches
   a known metamethod string (`__index`, `__newindex`, `__gc`, `__mode`,
   `__len`, `__eq`), call `tm_flags.markPresent(event)`.
3. **`metamethodValue`**: replace `tableGetRawValue(mt, name)` with
   `fasttm(self, mt, event)`.
4. **Per-VM `tm_names`**: array of interned `*LuaString` for each
   `"__index"`, `"__newindex"`, etc. — pre-interned at VM init, used for
   fast pointer comparison in `tableSetValue` and direct key in `fasttm`.
5. **`cmpEq`**: use `fasttm(self, mt, .eq)` instead of
   `callBinaryMetamethod`.

### Expected Impact

- `__eq` on objects WITHOUT `__eq` metamethod: single bit test (was: full
  hash lookup on every `==` comparison).
- `__index` on tables WITHOUT `__index` (the vast majority): single bit test.
- Negligible overhead when metamethod IS present (same hash lookup as now).
- 4 bytes per Table (the `tm_flags` field) — negligible memory cost.

### When to Implement

This is a **standalone performance optimization** — not required for
correctness or testC parity. It should be done AFTER the GcObject refactor
and Userdata implementation are stable. It can be measured with the existing
benchmark suite (`tools/perf/`) and validated by running the full matrix +
testC matrix with no regressions.

### References

- PUC `ltm.h:19-68` — TMS enum, fasttm/gfasttm/checknoTM macros
- PUC `ltm.c:36-68` — luaT_gettm (hash lookup + flags update), luaT_gettmbyobj
- PUC `lobject.h:382` — Table.flags field
- PUC `ltable.c:599-605` — luaH_set clears TM flag bits when new key added
