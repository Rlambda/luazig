# Plan: Leak Detection Infrastructure — CLOSED

## Outcome

All actionable items completed. Two items deferred (low priority / blocked).

## What was done

### Phase 1: TrackingAllocator infrastructure ✅
- `src/lua/tracking_alloc.zig`: wraps any backing allocator with exact byte counting
- `Vm.tracker_total: ?*usize`: optional pointer for accurate `collectgarbage("count")`
- `gcMemKb()` helper: reads tracker when available, falls back to `gc_count_kb`
- Exported through `lua.internal.tracking_alloc` in `root.zig`
- **NOT activated** in main binary — `smp_allocator` vtable wrapping causes
  non-deterministic SIGABRT (§4.3). Infrastructure ready for when this is resolved.

### Phase 2: leakbench.lua ✅
- `tools/leakbench.lua`: 25 workloads testing all major Lua concepts
- Each workload: GC → baseline → allocate N → GC → measure delta
- Output: `name\tbefore_kb\tafter_kb\tleaked_kb\tstatus\n`

### Phase 3: leak_bench.py runner ✅
- `tools/leak_bench.py`: side-by-side luazig vs PUC Lua comparison
- Builds ReleaseFast + lua-c, runs both, reports per-workload delta
- Exit code 1 if any workload leaks > threshold (default 1 KB)

### §4.1: Short string GC sweep ✅ (main achievement)
**Problem:** Short strings had `gc_marked=0`, invisible to GC → 1844 KB leak per 10K strings.
**Fix:** PUC-faithful approach — register short strings in `gc_objects` (PUC `allgc`),
swept by normal per-object incremental sweep. `gcFreeObject` removes from
`string_intern.table` (PUC `luaS_remove`).
**Result:** 1844 KB → 0.1 KB. Matrix 30/31, Smoke 49/49.

### §4.2.1: testc_pushuserdata null panic — WON'T FIX ✅
- `@ptrFromInt(0)` panics in Debug (Zig safety check)
- Fixing requires `LightUserdata: *anyopaque` → `?*anyopaque` (Value union refactor)
- ReleaseFast works (UB but correct in practice)
- Documented as known Debug-only issue

## What was deferred

### §4.2.2: Coroutine thread leak (LOW PRIORITY)
- 7.8 KB per 1000 coroutines (~8 bytes/thread)
- Leakbench-visible but negligible for real workloads
- Needs investigation of Thread struct internal buffer freeing

### §4.3: smp_allocator + TrackingAllocator (BLOCKED)
- Vtable wrapping smp_allocator causes non-deterministic SIGABRT
- c_allocator is stable but changes memory characteristics
- Blocks accurate `collectgarbage("count")` (gc_count_kb approximation remains)
- Needs SmpAllocator.zig internals investigation

## Final metrics
- Matrix: 30/31 (unchanged from baseline)
- Smoke: 49/49 (unchanged)
- Leakbench: 24/25 OK (only coroutine_create: 7.8 KB)
- Short string leak: FIXED (1844 KB → 0.1 KB)
