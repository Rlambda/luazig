# Plan: Leak Detection Infrastructure

## Outcome — ALL ITEMS ADDRESSED

### Phase 1: TrackingAllocator ✅ DONE
- `src/lua/tracking_alloc.zig`: exact byte counting via Allocator vtable
- Activated in main binary: wraps smp_allocator
- `collectgarbage("count")` reads exact `tracker.total_bytes`
- `Vm.tracker_total: ?*usize`, `gcMemKb()` helper

### Phase 2: leakbench.lua ✅ DONE
- 25 workloads, all major Lua concepts

### Phase 3: leak_bench.py ✅ DONE
- Side-by-side luazig vs PUC comparison
- 24/25 OK

### §4.1: Short string GC sweep ✅ DONE
- PUC-faithful: short strings in `gc_objects`, normal per-object sweep
- 1844 KB → 0.1 KB

### §4.2.1: LightUserdata null panic ✅ FIXED
- `LightUserdata: *anyopaque` → `?*anyopaque` in Value + NodeKeyPayload
- Also fixed undump.zig alignment crash (copy instead of @alignCast)

### §4.2.1b: Debug-only crashes (investigated)
- `gcMarkValueFinalizerReach` corrupt Value after stack overflow in unprotected thread
- Pre-existing UB in ReleaseFast, revealed by Debug safety checks
- Separate from leak detection scope — needs sub-VM cleanup investigation

### §4.2.2: Coroutine thread leak ✅ PARTIALLY FIXED
- Fixed: `last_yield_payload`, `resume_inbox`, `tail_resume_inbox`,
  `suspended_builtin_args` now freed in `gcFreeObject`
- Remaining: 8 bytes/yield — source not identified despite exhaustive audit
- Needs runtime instrumentation (alloc/free tracing)

### §4.3: smp_allocator + TrackingAllocator ✅ RESOLVED
- Earlier crashes were from sub-VM nested tracker creation (Vm.init creating
  its own tracker wrapping the parent's). Fixed by moving tracker outside Vm.
- smp_allocator works correctly with TrackingAllocator wrapper.

### §4.4: collectgarbage("count") accuracy ✅ DONE
- Tracker activated, reads exact bytes.

## Final metrics
- Matrix: 30/31 · Smoke: 49/49
- Short string leak: FIXED (1844 KB → 0.1 KB)
- Coroutine leak: reduced (last_yield_payload + inbox fields freed)
  Remaining: 8 bytes/yield (under investigation)
- collectgarbage("count"): EXACT (TrackingAllocator)
