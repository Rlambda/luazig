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

### 4.1 GC: Short strings never swept (DONE ✅)

**Root cause:** Short strings (≤40 bytes) interned in `string_intern` had
`gc_marked = 0`, making them invisible to GC marking (`gcIsWhite(0) = false`).

**Solution (PUC-faithful approach — committed):**
1. Set `gc_marked = gc_current_white & WHITEBITS` on new short strings ✅
2. Register short strings in `gc_objects` via `gcRegisterString` (PUC `allgc`) ✅
3. Normal per-object incremental sweep handles short string collection ✅
4. `gcFreeObject` removes freed strings from `string_intern.table` (PUC `luaS_remove`) ✅
5. `gcDeadenUnmarkedStringKeys` uses `gcIsDead` (not `gcIsWhite`) + handles weak-key tables ✅
6. `gcMakeAllWhite` / `gcMakeAllOld` no longer iterate `string_intern` separately ✅
7. `Vm.deinit`: `string_intern.deinit` moved after `drainGcRegistries` ✅

**Leakbench verification (before → after):**
- `string_create`: 1844 KB LEAK → 0.1 KB OK ✅
- `string_concat`: 907 KB LEAK → 0.1 KB OK ✅
- `pcall_recover`: 163 KB LEAK → 0 KB OK ✅
- All other workloads: 0 KB OK ✅

**Note:** `gcSweepStringIntern` function remains in source but is unused.
Can be removed in a cleanup pass.

### 4.2 Pre-existing bugs found during investigation

**4.2.1 `builtinTestcPushuserdata` null pointer panic (PRE-EXISTING)**
- `@ptrFromInt(n)` panics in Debug when `n=0` (null pointer cast)
- Location: `vm.zig:builtinTestcPushuserdata`
- Reproduces: api.lua in Debug mode (`--vm=bc --testc`)
- In ReleaseFast: UB (sometimes core dump, sometimes silent)
- Fix: guard with `if (n == 0) outs[0] = .Nil else ...`

**4.2.2 Coroutine thread leak — 7.8 KB per 1000 coroutines (PRE-EXISTING)**
- Small leak per coroutine creation/resume/dispose cycle
- Likely from Thread struct internal buffers not fully freed
- Low priority — ~8 bytes per coroutine

### 4.3 smp_allocator + TrackingAllocator crash (DEFERRED)

**Symptom:** Wrapping `smp_allocator` with vtable causes non-deterministic
SIGABRT under heavy GC load. `c_allocator` is stable but changes perf/memory.

**Hypothesis:** smp_allocator may have thread-local state or ret_addr
sensitivity that breaks with vtable indirection.

**Investigation needed:** Read SmpAllocator.zig source, check vtable
invariants, test with a minimal wrapper.

### 4.4 collectgarbage("count") accuracy (BLOCKED on 4.3)

`gc_count_kb` approximate — works for GC pacing and matrix compatibility.
Tracker gives exact count but can't be activated due to 4.3. Once 4.3 is
resolved, wire tracker into main binary for accurate `collectgarbage("count")`.

### Execution status
1. ~~Fix 4.1 (GC string sweep)~~ — DONE ✅ (PUC-faithful gc_objects approach)
2. ~~Write leakbench.lua (Phase 2)~~ — DONE ✅ (25 workloads)
3. ~~TrackingAllocator (Phase 1)~~ — Infrastructure DONE ✅ (activation deferred)
4. Fix 4.2.1 (testc_pushuserdata null panic) — TODO
5. Fix 4.2.2 (coroutine leak 8 bytes/thread) — LOW PRIORITY
6. Investigate 4.3 (smp_allocator) — DEFERRED
7. Write leak_bench.py runner (Phase 3) — TODO
