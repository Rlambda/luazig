# Plan: Leak Detection Infrastructure

## Motivation

luazig uses manual memory management (Zig allocators + custom GC). Memory
tracking via `gc_count_kb` is approximate (hand-placed `gcNoteAlloc`/
`gcNoteFree` at ~20 call sites), causing drift — `collectgarbage("count")`
returns 0.0 KB after GC when baseline is ~33 KB. Without accurate memory
measurement, leak detection is impossible.

PUC Lua solves this with a single allocation chokepoint (`luaM_realloc_`)
that counts every byte. We replicate this with a `TrackingAllocator`.

## Phase 1: TrackingAllocator — accurate memory accounting

### 1.1 Create `TrackingAllocator`

File: `src/lua/tracking_alloc.zig`

```zig
pub const TrackingAllocator = struct {
    backing: std.mem.Allocator,
    total_bytes: usize = 0,

    pub fn init(backing: std.mem.Allocator) TrackingAllocator
    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator

    // VTable: alloc adds len, free subtracts len, resize adjusts delta
};
```

Wraps any backing allocator. Every `alloc`/`resize`/`free` updates
`total_bytes`. No approximation — exact byte counts.

### 1.2 Wire into VM

In `src/bin/luazig.zig`:
```zig
var tracker = TrackingAllocator.init(std.heap.smp_allocator);
const runtime_alloc = tracker.allocator();
var vm = Vm.init(runtime_alloc, disable_env);
```

Store `*TrackingAllocator` on the `Vm` so `collectgarbage("count")` and
GC pacing can read `total_bytes`.

Two implementation options:
- **Option A**: `Vm` stores `tracking: ?*TrackingAllocator` (nullable, null in tests)
- **Option B**: `Vm` stores `tracking_total: *usize` (just the counter pointer)

Option A is cleaner. `Vm.init` gets optional `?*TrackingAllocator` param.

### 1.3 Replace `gc_count_kb` with `tracking.total_bytes`

Every read of `gc_count_kb` becomes `tracker.total_bytes / 1024.0`:

| Current code | New code |
|---|---|
| `self.gc_count_kb` (read) | `self.tracker.?.total_bytes / 1024.0` |
| `self.gcNoteAlloc(bytes)` | DELETE — tracker handles it |
| `self.gcNoteFree(bytes)` | DELETE — tracker handles it |
| `gc_count_kb: f64 = 0.0` (field) | DELETE |
| `gc_step_debt_kb -= kb` (in gcNoteAlloc) | Move to tracker's alloc callback |

### 1.4 Remove `gcNoteAlloc` and `gcNoteFree`

Delete:
- `fn gcNoteAlloc(self, bytes)` at `vm.zig:4388`
- `fn gcNoteFree(self, bytes)` at `vm.zig:4407`
- All ~20 `gcNoteAlloc(...)` call sites
- All ~6 `gcNoteFree(...)` call sites in `gcFreeObject`

### 1.5 GC pacing migration

`gc_step_debt_kb` currently decremented in `gcNoteAlloc`. Move to the
`TrackingAllocator`'s alloc callback:

```zig
fn allocFn(ctx, len, alignment, ra) {
    // ... backing alloc ...
    self.total_bytes += len;
    if (self.vm_gc_debt) |debt| debt.* -= @floatFromInt(len / 1024.0);
}
```

Or simpler: keep a `gc_debt_kb: f64` on the tracker, let VM read it.

### 1.6 Update `collectgarbage("count")`

```zig
// Before:
outs[0] = .{ .Num = self.gc_count_kb + live_ud_kb + ... };

// After:
const kb: f64 = if (self.tracker) |t|
    @as(f64, @floatFromInt(t.total_bytes)) / 1024.0
else
    self.testc_total_bytes / 1024.0;  // fallback for test mode
outs[0] = .{ .Num = kb };
```

### 1.7 Verify

- `collectgarbage("count")` should return ~33 KB at startup (not 0.0)
- After alloc + nil + GC: should return to ~33 KB baseline
- Matrix: 30/31 (no regressions in gc.lua, memerr.lua)
- Smoke: 49/49

### Risks

- gc.lua / memerr.lua depend on specific memory numbers → may need tuning
- GC pacing change may cause more frequent GC → perf regression
- `testc_total_bytes` system is separate — NOT removed in Phase 1, only
  `gc_count_kb` / `gcNoteAlloc` / `gcNoteFree`

## Phase 2: Leak Bench Script (`tools/leakbench.lua`)

15 workloads testing all major Lua concepts:

| # | Name | What it tests |
|---|---|---|
| 1 | `table_empty` | Table alloc/dealloc cycle |
| 2 | `table_array` | Array part resize |
| 3 | `table_hash` | Hash part resize |
| 4 | `table_nested` | Nested tables (multi-level deref) |
| 5 | `table_cycle` | Cyclic references (GC cycle detection) |
| 6 | `string_create` | String interning + GC |
| 7 | `string_concat` | CONCAT opcode temp strings |
| 8 | `closure_simple` | Closure alloc |
| 9 | `closure_upvalue` | Upvalue sharing + Cell alloc |
| 10 | `coroutine_create` | Thread alloc/dealloc |
| 11 | `coroutine_yield` | Resume/yield cycle |
| 12 | `load_chunk` | Proto alloc (parser/codegen) |
| 13 | `metatable_gc` | __gc finalizers |
| 14 | `pcall_error` | Error object + stacktrace alloc |
| 15 | `deep_call` | CallFrame stack growth/shrink |

Each test pattern:
```lua
collectgarbage("collect") collectgarbage("collect")  -- finalizers
local before = collectgarbage("count")
-- ... allocate N objects, lose references ...
collectgarbage("collect") collectgarbage("collect")
local after = collectgarbage("count")
local leaked = after - before
```

Output: `name\tbefore_kb\tafter_kb\tleaked_kb\n`

## Phase 3: Python Runner (`tools/leak_bench.py`)

- Runs `leakbench.lua` under luazig and PUC Lua
- Side-by-side comparison
- PASS if `leaked < threshold` (e.g., 1.0 KB)
- FAIL with red highlighting for leaks

## Phase 4: Run → Identify → Fix

1. Run leak bench, compare luazig vs PUC
2. Rank leaks by severity (KB leaked per N iterations)
3. Fix top-N leaks (GC missing objects, allocation sites not freeing, etc.)
4. Re-run, verify improvements
5. Commit per fix
