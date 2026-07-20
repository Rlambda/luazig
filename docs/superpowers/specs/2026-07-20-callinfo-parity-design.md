# Spec: PUC CallInfo parity — pre-allocated array, merged frames, inline storage, varargs on bc_stack

**Date:** 2026-07-20
**Status:** Draft
**Goal:** Replace the heap-allocated `ArrayListUnmanaged` frame stacks with a PUC-faithful CallInfo model: pre-allocated capacity, merged frame struct, inline array in Thread, and varargs on bc_stack. Eliminate per-call heap allocation overhead from the hot path.

## Background

### Current architecture

luazig maintains TWO parallel frame stacks per thread:

1. `Thread.bytecode_frames: ArrayListUnmanaged(BytecodeExecFrame)` (~200B per entry)
2. `Vm.frames: ArrayListUnmanaged(RuntimeFrame)` (~280B per entry, parked to `Thread.runtime_frames` during coroutine switch)

Every `pushBytecodeExecFrame` (vm.zig:6653) does:
- `self.frames.addOne(self.alloc)` — capacity check + items.len bump
- `exec_frames.addOne(self.alloc)` — capacity check + items.len bump
- ~50 field writes across both structs
- `alloc.dupe(Value, varargs_src)` for vararg functions

Every `popBytecodeExecFrame` (vm.zig:6800) just decrements `items.len` (no free, reuse on next push).

### PUC Lua model

PUC has a SINGLE `CallInfo` struct (~48B) per call frame:
- `base_ci` embedded inline in `lua_State` (first frame, no allocation)
- `luaE_extendCI` heap-allocs new CIs but never frees on return (amortized via linked list)
- Varargs stored on the value stack via `buildhiddenargs` (shift func+params up, varargs end up below `ci->func`)
- `nextraargs` tracks vararg count; access via `ci->func.p - nextra + n - 1`

### Performance impact

- `lua_calls` microbench: 5.5× PUC (worst workload)
- `addOne` capacity check: branch on every OP_CALL (amortized but not free)
- Dual struct writes: ~50 field assignments per push (redundant overlap)
- Vararg `alloc.dupe`: heap alloc + free on every vararg function call
- 305 total `exec_frames.items[i]` / `self.frames.items[i]` access sites

## Design

Four phases, each independently shippable and measurable.

---

### Phase A: Pre-allocate capacity

**Goal:** Eliminate the capacity-check branch from `addOne` on the hot path.

**Files:** `src/lua/vm.zig`

**Change:** When a Thread is activated (`activateRuntime`, vm.zig:1899), call `ensureTotalCapacity` on both `bytecode_frames` and `frames` with a reasonable initial capacity (64). This means the first 64 `addOne` calls are pure `items.len += 1` (no capacity check, no realloc). Beyond 64, `addOne` falls back to the normal `ensureTotalCapacity` path (geometric growth).

```zig
fn activateRuntime(self: *Vm, owner: *Thread) void {
    // ... existing move logic ...
    // Pre-allocate frame capacity to avoid capacity-check branch on hot path.
    // 64 frames covers typical Lua call depth; deeper chains fall back to
    // geometric growth (rare). PUC has no limit (linked list) but amortizes
    // via never freeing on return.
    self.frames.ensureTotalCapacity(self.alloc, 64) catch {};
    owner.bytecode_frames.ensureTotalCapacity(self.alloc, 64) catch {};
}
```

Also add the same pre-allocation in `seedBytecodeThread` or wherever a fresh Thread is created for bytecode execution.

**What does NOT change:**
- Frame struct layout (BytecodeExecFrame and RuntimeFrame stay separate)
- `pushBytecodeExecFrame` / `popBytecodeExecFrame` logic
- Access patterns (still `exec_frames.items[i]` / `self.frames[i]`)
- Varargs allocation

**Risk:** Low. Pure optimization, no structural change. Memory cost: 64 × 480B = ~30KB per active thread (acceptable; threads are not lightweight).

**Expected perf:** Small but measurable — eliminates the capacity-check branch from the common case. Expected ~2-5% improvement on `lua_calls`.

**Verification:**
- `zig build test -Doptimize=Debug`
- All 45 smoke tests pass
- `python3 tools/testes_matrix.py` — 28/31 (no regressions)
- `python3 tools/perf_compare.py --runs 7 --core 0 --no-build` — lua_calls improvement

---

### Phase B: Merge BytecodeExecFrame + RuntimeFrame

**Goal:** Eliminate the dual `addOne` + dual field writes. PUC has one `CallInfo`; we should too.

**Files:** `src/lua/vm.zig`

**Change:** Merge `BytecodeExecFrame` (vm.zig:745) and `RuntimeFrame` (vm.zig:848) into a single `CallFrame` struct. Use a tagged approach (not a Zig tagged union — a simple `is_bytecode: bool` flag) to distinguish bytecode frames from IR frames, like PUC's `CIST_C` bit.

**Merged struct design:**

```zig
const CallFrame = struct {
    // ── Common fields (present for all frame types) ──
    func: *const ir.Function,       // bc_dummy_func for bytecode frames
    proto: ?*const bc.Proto,        // non-null for bytecode frames
    callee: Value,
    pc: usize = 0,
    current_line: i64 = 0,
    last_hook_line: i64 = -1,
    is_tailcall: bool = false,
    varargs: []Value,               // heap-allocated (Phase D moves to bc_stack)
    upvalues: []const *Cell,
    env_override: ?Value = null,
    frame_id: usize = 0,

    // ── Bytecode-specific fields (valid when proto != null) ──
    base: usize = 0,                // bc_stack offset
    frame_cap: usize = 0,
    resume_pc: usize = 0,
    reg_top: u32 = 0,
    nvarstack: u8 = 0,
    activation_id: usize = 0,
    tbc_mark: usize = 0,
    last_line_pc: ?usize = null,
    skip_line_hook_pc: ?usize = null,
    skip_call_hook_pc: ?usize = null,
    resumed_direct_yield: bool = false,
    pending_call: PendingCallSlot = .{},

    // ── IR-specific fields (valid when proto == null) ──
    regs: []Value = &.{},
    locals: []Value = &.{},
    boxed: []?*Cell = &.{},
    local_active: []bool = &.{},
    top: u32 = 0,

    // ── Debug fields (common, but only used when hooks active) ──
    used_closing_line_hook: bool = false,
    resume_skip_count_pc: ?usize = null,
    hide_from_debug: bool = false,
    debug_namewhat: ?[]const u8 = null,
    debug_name: ?[]const u8 = null,
    is_debug_hook: bool = false,
    debug_hook_transfer: ?[]const Value = null,
    debug_hook_transfer_start: i64 = 1,
    debug_hook_event_calllike: bool = false,
    debug_hook_event_tailcall: bool = false,
    debug_hook_event_is_count: bool = false,
    debug_hook_allow_yield: bool = false,
    bc_base: usize = 0,
};
```

**Migration strategy:**
1. Define `CallFrame` with all fields from both structs
2. Replace `BytecodeExecFrame` and `RuntimeFrame` with `CallFrame` everywhere
3. Replace `exec_frames` and `frames` with a single `call_frames: ArrayListUnmanaged(CallFrame)`
4. Update `pushBytecodeExecFrame` to push ONE frame (not two)
5. Update `popBytecodeExecFrame` to pop ONE frame
6. Update all 305 access sites: `exec_frames.items[i]` and `self.frames.items[i]` → `call_frames.items[i]`
7. Remove `runtime_frame_index` field (no longer needed — there's only one array)

**Key invariants to preserve:**
- `regs` / `boxed` for bytecode frames are derived from `bc_stack[base..base+frame_cap]`, not stored in the frame (they were stored in RuntimeFrame but are re-derived in the dispatch loop anyway)
- IR frames store `regs` / `locals` / `boxed` / `local_active` directly (they don't use bc_stack)
- The `pending_call` field is bytecode-only; IR frames never set it
- The `func` field is `bc_dummy_func` for bytecode frames (existing pattern)

**Risk:** Medium. Large diff (305 call sites), but mechanical. The field sets overlap significantly. Main risk: missing a field initialization in `pushBytecodeExecFrame` (stale value from prior activation leaks through). Mitigation: P15.37a already established the `addOne` + explicit field write pattern; we follow it.

**Expected perf:** ~5-10% improvement on `lua_calls` — eliminates one `addOne` call and ~25 redundant field writes per push.

**Verification:**
- `zig build test -Doptimize=Debug`
- All 45 smoke tests pass
- `python3 tools/testes_matrix.py` — 28/31 (no regressions)
- `python3 tools/perf_compare.py --runs 7 --core 0 --no-build` — lua_calls improvement
- Stress test: `tools/iterative_dispatch_stress.sh`

---

### Phase C: Inline array in Thread

**Goal:** Eliminate heap allocation for shallow call chains (common case).

**Files:** `src/lua/vm.zig`

**Change:** Embed a fixed-size array of `CallFrame` entries directly in `Thread`. `pushBytecodeExecFrame` uses the inline array first (indices 0..INLINE_CAP-1), falls back to heap `ArrayList` for deeper chains (indices >= INLINE_CAP). PUC's `base_ci` is the first inline entry.

```zig
const INLINE_FRAME_CAP: usize = 32;

const Thread = struct {
    // ... existing fields ...
    /// Inline call frame storage. Frames 0..INLINE_FRAME_CAP-1 live here
    /// (no heap allocation). Deeper chains spill to `call_frames_heap`.
    /// PUC's `base_ci` is the equivalent inline first frame.
    inline_frames: [INLINE_FRAME_CAP]CallFrame = undefined,
    inline_frame_count: usize = 0,
    /// Heap overflow for call chains deeper than INLINE_FRAME_CAP.
    /// Empty for typical programs.
    call_frames_heap: std.ArrayListUnmanaged(CallFrame) = .empty,
    call_frames_total: usize = 0,  // inline_frame_count + call_frames_heap.items.len
    // ...
};
```

**Access pattern:**
```zig
fn getCallFrame(self: *Thread, index: usize) *CallFrame {
    if (index < INLINE_FRAME_CAP) return &self.inline_frames[index];
    return &self.call_frames_heap.items[index - INLINE_FRAME_CAP];
}

fn pushCallFrame(self: *Thread, alloc: std.mem.Allocator) !*CallFrame {
    if (self.inline_frame_count < INLINE_FRAME_CAP) {
        const idx = self.inline_frame_count;
        self.inline_frame_count += 1;
        self.call_frames_total += 1;
        return &self.inline_frames[idx];
    }
    const slot = try self.call_frames_heap.addOne(alloc);
    self.call_frames_total += 1;
    return slot;
}

fn popCallFrame(self: *Thread, alloc: std.mem.Allocator) void {
    if (self.call_frames_heap.items.len > 0) {
        self.call_frames_heap.items.len -= 1;
    } else {
        self.inline_frame_count -= 1;
    }
    self.call_frames_total -= 1;
}
```

**Coroutine switch:** The inline array is part of `Thread`, so it's automatically parked/resumed with the thread. No special handling needed (unlike the current `parkActiveRuntime`/`activateRuntime` which moves ArrayLists between Vm and Thread).

**What does NOT change:**
- Frame struct layout (CallFrame from Phase B)
- Field initialization pattern (addOne + explicit writes)
- Varargs allocation (still heap, Phase D fixes this)

**Risk:** Medium. Increases `Thread` size by 32 × ~300B = ~9.6KB. The inline→heap transition is the main complexity. Must ensure all access goes through `getCallFrame(index)`, not direct array indexing.

**Expected perf:** ~5-10% improvement on `lua_calls` — eliminates heap allocation entirely for call chains ≤ 32 deep (the vast majority of real Lua programs).

**Verification:**
- `zig build test -Doptimize=Debug`
- All 45 smoke tests pass
- `python3 tools/testes_matrix.py` — 28/31 (no regressions)
- Stress test with deep recursion (smoke test 14_local_function_recursion.lua)
- `python3 tools/perf_compare.py --runs 7 --core 0 --no-build` — lua_calls improvement

---

### Phase D: Varargs on bc_stack

**Goal:** Eliminate `alloc.dupe(Value, varargs_src)` on every vararg function call.

**Files:** `src/lua/vm.zig`

**Change:** Implement PUC's `buildhiddenargs` pattern (ltm.c:255-269): shift the function and fixed params up past the extra args, so varargs end up below the frame base. Store `nextraargs` in the frame instead of a `varargs: []Value` slice.

**PUC's stack layout (ltm.c:250-268):**
```
Before buildhiddenargs:
  func arg1 arg2 arg3 extra1 extra2 extra3
  ^ci->func                        ^L->top

After buildhiddenargs:
  extra1 extra2 extra3 func arg1 arg2 arg3
                       ^ci->func   (shifted up by nextra+1)
```

Varargs are accessed via `ci->func.p - nextra + n - 1` (ltm.c:297).

**Our adaptation:**

Currently our stack layout for a vararg function call is:
```
bc_stack: [callee][fixed_params][extra_args][...]
          ^regs[a]              ^regs[a+1+nparams]
```

After the shift (PUC `buildhiddenargs` equivalent):
```
bc_stack: [extra_args][callee][fixed_params][register_window...]
           ^base-nextra  ^base
```

The frame's `base` points to `callee`. Varargs are at `bc_stack[base - nextra .. base]`.

**Frame field change:**
```zig
// Before (Phase B/C):
varargs: []Value,  // heap-allocated slice

// After (Phase D):
nextraargs: u16 = 0,  // number of varargs (0 for non-vararg functions)
// Varargs accessed via: bc_stack[frame.base - frame.nextraargs .. frame.base]
```

**pushBytecodeExecFrame change:**
```zig
// Before:
const frame_varargs = if (varargs_src.len != 0)
    try self.alloc.dupe(Value, varargs_src)
else
    empty_varargs;

// After (PUC buildhiddenargs):
if (proto.is_vararg and args.len > nparams) {
    const nextra = args.len - nparams;
    // Shift callee + fixed params up by nextra, leaving varargs below base.
    // This is a memmove on bc_stack — no heap allocation.
    // ... shift logic ...
    frame.nextraargs = @intCast(nextra);
} else {
    frame.nextraargs = 0;
}
```

**Varargs access change:**
All sites that read `frame.varargs[i]` must change to `bc_stack[frame.base - frame.nextraargs + i]`. Key sites:
- vm.zig:7189 (dispatch loop caches `varargs` into local)
- vm.zig:9398 (OP_TAILCALL frame-reuse varargs update)
- vm.zig:14002 (GC mark)
- vm.zig:15137, 15174, 15302 (GC scan parked threads)

**Constraint resolution:**
The comment at vm.zig:758-759 says "Stable owned varargs. They cannot share the register frame because dynamic multireturn growth may use registers beyond maxstacksize."

This constraint is resolved by PUC's layout: varargs are stored BELOW `base` (in the region `base-nextra..base`), while the register window is `base..base+frame_cap`. Multireturn growth extends ABOVE `base+frame_cap` (via `bcGrowFrame`), which does NOT clobber the varargs region below `base`.

The only risk: if `bcGrowFrame` or `ensureBcStackCap` reallocs `bc_stack`, the varargs region moves too. But since we access varargs via `bc_stack[base - nextra .. base]` (not a cached slice), the access is always valid after realloc.

**Risk:** High. Changes the stack layout for vararg functions. Must handle:
- GC scanning (varargs are now on bc_stack, scanned as part of the stack)
- Coroutine park/resume (varargs move with bc_stack, no special handling)
- OP_TAILCALL frame-reuse (must re-derive varargs from new base)
- The `buildhiddenargs` shift itself (memmove on bc_stack, must be overlap-safe)

**Expected perf:** ~3-5% improvement on `lua_calls` — eliminates heap alloc + free for every vararg function call. Also reduces GC pressure (fewer heap objects to scan).

**Verification:**
- `zig build test -Doptimize=Debug`
- All 45 smoke tests pass (especially 18_varargs.lua)
- `python3 tools/testes_matrix.py` — 28/31 (no regressions, especially vararg.lua)
- Stress test: `tools/iterative_dispatch_stress.sh`
- `python3 tools/perf_compare.py --runs 7 --core 0 --no-build` — lua_calls improvement

---

## Phase ordering and dependencies

```
Phase A (pre-allocate) ──→ Phase B (merge frames) ──→ Phase C (inline array) ──→ Phase D (varargs)
```

- Phase A is independent — can be done first.
- Phase B should come before C (merged struct is simpler to inline).
- Phase C should come before D (inline array simplifies varargs migration — no heap overflow case to worry about for common call depths).
- Phase D depends on B (merged struct has the `nextraargs` field) and C (inline array ensures varargs region is on bc_stack, not heap overflow).

## Expected total impact

| Phase | lua_calls improvement | geomean improvement | Risk |
|---|---:|---:|---|
| A: pre-allocate | ~2-5% | ~1% | Low |
| B: merge frames | ~5-10% | ~2-3% | Medium |
| C: inline array | ~5-10% | ~2-3% | Medium |
| D: varargs on bc_stack | ~3-5% | ~1-2% | High |
| **Total** | **~15-30%** | **~6-9%** | |

Current baseline: lua_calls 5.03×, geomean 3.23×.
Target after all 4 phases: lua_calls ~3.5-4.5×, geomean ~2.9-3.0×.

## PUC references

- `CallInfo` — lstate.h:187-209 (single frame struct, ~48B)
- `base_ci` — lstate.h:299 (inline first frame in lua_State)
- `luaE_extendCI` — lstate.c:71-82 (heap alloc new CI, never free on return)
- `buildhiddenargs` — ltm.c:255-269 (shift func+params up, varargs below base)
- `luaT_getvararg` — ltm.c:292-311 (access varargs via `ci->func.p - nextra + n - 1`)
- `luaD_precall` — ldo.c:715-746 (inline type switch, checkstackp, prepCallInfo)
