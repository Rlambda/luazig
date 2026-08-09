# Plan: Leak Detection Infrastructure — COMPLETE

## All items resolved

### Phase 1: TrackingAllocator ✅
- `src/lua/tracking_alloc.zig`: exact byte counting via Allocator vtable
- Activated in main binary, `collectgarbage("count")` reads exact bytes
- Debug tracing infrastructure (disabled by default)

### Phase 2: leakbench.lua ✅
- 25 workloads, all major Lua concepts

### Phase 3: leak_bench.py ✅
- Side-by-side luazig vs PUC comparison

### §4.1: Short string GC sweep ✅
- PUC-faithful: short strings in `gc_objects`, per-object sweep
- 1844 KB → 0.1 KB

### §4.2.1: LightUserdata null panic ✅ FIXED
- `*anyopaque` → `?*anyopaque` in Value + NodeKeyPayload
- undump.zig alignment crash fixed (copy instead of @alignCast)

### §4.2.2: Closure upvalues leak ✅ FIXED
- `gcFreeObject` for closures: free `cl.upvalues` array
- PUC `luaF_freecupvals` equivalent
- 8 bytes/closure leaked → 0

### §4.2.2b: Thread field leaks ✅ FIXED
- `gcFreeObject` for threads: free `last_yield_payload`, `resume_inbox`,
  `tail_resume_inbox`, `suspended_builtin_args`

### §4.3: smp_allocator + TrackingAllocator ✅ RESOLVED
- Earlier crashes were from sub-VM nested tracker creation
- Fixed by moving tracker outside Vm.init

### §4.4: collectgarbage("count") accuracy ✅ DONE
- Exact via tracker.total_bytes

## Final metrics
- Matrix: 30/31 · Smoke: 49/49
- Leakbench: **25/25 PASS** (zero leaks)
