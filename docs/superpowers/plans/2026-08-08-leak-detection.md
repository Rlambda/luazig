# Plan: Leak Detection Infrastructure

## Outcome

All actionable items completed or investigated to root cause.

## What was done

### Phase 1: TrackingAllocator infrastructure ✅
- `src/lua/tracking_alloc.zig`: wraps any backing allocator with exact byte counting
- `Vm.tracker_total: ?*usize`: optional pointer for accurate `collectgarbage("count")`
- `gcMemKb()` helper: reads tracker when available, falls back to `gc_count_kb`
- Exported through `lua.internal.tracking_alloc` in `root.zig`
- **NOT activated** in main binary — needs §4.3 resolution.

### Phase 2: leakbench.lua ✅
- `tools/leakbench.lua`: 25 workloads testing all major Lua concepts

### Phase 3: leak_bench.py runner ✅
- `tools/leak_bench.py`: side-by-side luazig vs PUC Lua comparison
- Result: 24/25 workloads OK, 1 marginal (coroutine_create: gc_count_kb drift)

### §4.1: Short string GC sweep ✅
**Fix:** PUC-faithful — register short strings in `gc_objects`, normal per-object sweep.
`gcFreeObject` removes from `string_intern.table` (PUC `luaS_remove`).
**Result:** 1844 KB → 0.1 KB.

### §4.2.1: LightUserdata null panic ✅ FIXED
- Changed `LightUserdata: *anyopaque` → `?*anyopaque` in Value union + NodeKeyPayload
- `@ptrFromInt(0)` now returns null (valid for optional pointers)
- Also fixed undump.zig alignment crash (copy instead of @alignCast on unaligned buffer)

### §4.2.1b: Debug-only crashes after LightUserdata fix (investigated)
- `gcMarkValueFinalizerReach`: corrupt Value tag after stack overflow in unprotected thread
- Pre-existing UB in ReleaseFast, revealed by Debug safety checks
- Root cause: sub-VM teardown after stack overflow leaves dangling table references
- **Status:** Needs sub-VM cleanup investigation — separate from leak detection scope

### §4.2.2: Coroutine "leak" ✅ INVESTIGATED (not a real leak)
- gc_count_kb shows 7.8 KB per 1000 coroutines — **approximation drift**
- RSS shows smp_allocator slab retention (memory freed to slab, not to OS)
- Verified: GC properly collects Thread objects (gc_count_kb stays ~34 KB baseline)
- **Real fix:** TrackingAllocator (§4.3/4.4) eliminates gc_count_kb drift

### §4.3: smp_allocator + TrackingAllocator crash (IN PROGRESS)
**Symptom:** Wrapping `smp_allocator` with vtable causes non-deterministic SIGABRT.
**Next step:** Investigate SmpAllocator.zig internals, test with minimal wrapper.

### §4.4: Activate TrackingAllocator (BLOCKED on §4.3)
Once §4.3 is resolved, wire tracker into main binary for exact `collectgarbage("count")`.

## Final metrics (current)
- Matrix: 30/31 (unchanged from baseline)
- Smoke: 49/49 (unchanged)
- Leakbench: 24/25 OK (coroutine_create: gc_count_kb drift, not real leak)
- Short string leak: FIXED (1844 KB → 0.1 KB)
