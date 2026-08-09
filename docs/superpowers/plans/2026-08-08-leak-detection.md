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

### 4.1 GC: Short strings never swept (IN PROGRESS — sweep code ready, disabled)

**Root cause:** Short strings (≤40 bytes) interned in `string_intern` had
`gc_marked = 0`, making them invisible to GC marking (`gcIsWhite(0) = false`).

**Fixed (committed):**
- Set `gc_marked = gc_current_white & WHITEBITS` on new short strings
  (vm.zig `internStr`). This enables proper GC mark/sweep tracking.
- `gcDeadenUnmarkedStringKeys` extended to handle weak-key tables.

**Sweep implemented but DISABLED** (`gcSweepStringIntern` at vm.zig):
- `gcSweepStringIntern` correctly identifies and frees dead short strings
- Works for simple cases (standalone string allocation)
- **CRASHES** after generational→incremental mode transition

**Crash analysis:**
- Crash: `switch on corrupt value` in `ltable.zig:getKey()` during
  `gcMarkTableFinalizerReach`
- Root cause: table hash array contains freed memory (0xAA debug pattern)
- The table is BLACK+FINALIZEDBIT (alive) but its hash is dangling
- Reproduces: gc.lua with `collectgarbage("generational")` → `"incremental"`
- Does NOT reproduce: gc.lua without gen mode switching
- Does NOT reproduce: minimal test cases (string+__gc+weak tables)

**Hypothesis:** `gcEnterGenerational` runs `gcCycleFull` which sweeps strings.
After gen→inc transition, a subsequent cycle's `gcMarkFinalizerReach` accesses
a table whose hash was corrupted. The exact mechanism is unclear — possibly
related to how `gcMakeAllOld` / `gcMakeAllWhite` interact with the string
intern table during mode transitions.

**Next steps for 4.1:**
1. String sweep causes issues even in pure incremental mode (api.lua hangs)
2. The `gcDeadenUnmarkedStringKeys` fix (gcIsDead vs gcIsWhite) was necessary
   but not sufficient — another mechanism causes incorrect behavior
3. **Hypothesis**: short strings are NOT registered in `gc_objects`, so the
   snapshot-based sweep (`gc_sweep_objects_cursor < snapshot_len`) doesn't
   protect new strings created during the sweep. A string created during
   sweep has the new white bit. `gcSweepStringIntern` uses `gcIsDead` which
   should protect it, BUT if the white bit was flipped during sweep (gen
   mode minor cycle), new strings might become dead.
4. **Alternative approach**: register short strings in `gc_objects` (like PUC's
   `allgc`) and remove the separate `string_intern` sweep. This is the
   PUC-faithful approach — PUC keeps all short strings in `allgc` and sweeps
   them per-object. Performance cost: gc_objects grows with thousands of
   short strings, incremental sweep takes more steps. But correctness is
   guaranteed.
5. **Performance mitigation**: batch short strings into the sweep by adding
   them all at once (string_intern iteration) to gc_objects snapshot at cycle
   start, then let normal per-object sweep handle them.

### 4.2 smp_allocator + TrackingAllocator crash (DEFERRED)

**Symptom:** Wrapping `smp_allocator` with vtable causes non-deterministic
SIGABRT under heavy GC load. `c_allocator` is stable but changes perf/memory.

**Hypothesis:** smp_allocator may have thread-local state or ret_addr
sensitivity that breaks with vtable indirection.

**Investigation needed:** Read SmpAllocator.zig source, check vtable
invariants, test with a minimal wrapper.

### 4.3 collectgarbage("count") accuracy (BLOCKED on 4.2)

`gc_count_kb` undercounts (returns ~0 after GC). Tracker gives accurate
count but can't be activated due to 4.2. Once 4.2 is resolved, wire tracker
into main binary for accurate `collectgarbage("count")`.

### Execution order
1. Fix 4.1 (GC string sweep) — highest impact, unblocked
2. Write leakbench.lua (Phase 2) — verify 4.1 fix
3. Investigate 4.2 (smp_allocator) — needed for accurate counting
4. Activate tracker (Phase 1 completion)
5. Write leak_bench.py runner (Phase 3)
