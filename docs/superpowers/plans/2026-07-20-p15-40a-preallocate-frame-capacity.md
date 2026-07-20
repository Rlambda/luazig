# P15.40a — Pre-allocate frame capacity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pre-allocate `bytecode_frames` and `frames` ArrayList capacity on thread activation to eliminate the capacity-check branch from `addOne` on the hot path.

**Architecture:** When a Thread is activated (`activateRuntime`), call `ensureTotalCapacity(64)` on both `bytecode_frames` and `frames`. This means the first 64 `addOne` calls are pure `items.len += 1` (no capacity check, no realloc). Beyond 64, `addOne` falls back to the normal `ensureTotalCapacity` path (geometric growth). Also pre-allocate on main thread creation and on `apiNewThread`.

**Tech Stack:** Zig 0.16.0, existing ArrayListUnmanaged infrastructure.

**Spec:** `docs/superpowers/specs/2026-07-20-callinfo-parity-design.md` (Phase A)

---

## File Structure

- **Modify:** `src/lua/vm.zig` — add `ensureTotalCapacity` calls in 3 locations
- **No new files.** All changes are in-place additions to existing functions.

## Current state (before P15.40a)

The frame arrays are `ArrayListUnmanaged` with no pre-allocation:

```zig
// Thread struct (vm.zig:975, 981)
bytecode_frames: std.ArrayListUnmanaged(BytecodeExecFrame) = .empty,
runtime_frames: std.ArrayListUnmanaged(RuntimeFrame) = .empty,
```

Every `pushBytecodeExecFrame` (vm.zig:6777) calls `exec_frames.addOne(self.alloc)` and `self.frames.addOne(self.alloc)` (vm.zig:6734). `addOne` calls `ensureTotalCapacity(gpa, newlen)` which checks `self.capacity >= new_capacity` — a branch on every OP_CALL.

## Target state (after P15.40a)

The frame arrays have capacity 64 pre-allocated on thread activation, so the first 64 `addOne` calls skip the capacity check entirely (the `ensureTotalCapacity` early-returns on `self.capacity >= new_capacity`).

---

### Task 1: Pre-allocate frame capacity in `activateRuntime`

**Files:**
- Modify: `src/lua/vm.zig` — `activateRuntime` function (line 1899)

- [ ] **Step 1: Add `ensureTotalCapacity` calls in `activateRuntime`**

Find the `activateRuntime` function (vm.zig:1899). After the existing move logic (after `self.active_runtime_thread = owner;` on line 1917), add:

```zig
    fn activateRuntime(self: *Vm, owner: *Thread) void {
        std.debug.assert(self.active_runtime_thread == null);
        std.debug.assert(self.frames.items.len == 0);
        std.debug.assert(self.bc_stack.len == 0);
        std.debug.assert(self.bc_boxed.len == 0);
        std.debug.assert(self.bc_tbc_regs.items.len == 0);

        self.frames = owner.runtime_frames;
        self.bc_stack = owner.bytecode_stack;
        self.bc_boxed = owner.bytecode_boxed;
        self.bc_stack_top = owner.bytecode_stack_top;
        self.bc_tbc_regs = owner.bytecode_tbc_regs;

        owner.runtime_frames = .empty;
        owner.bytecode_stack = &.{};
        owner.bytecode_boxed = &.{};
        owner.bytecode_stack_top = 0;
        owner.bytecode_tbc_regs = .empty;
        self.active_runtime_thread = owner;

        // P15.40a: Pre-allocate frame capacity to avoid capacity-check branch
        // on the hot path. 64 frames covers typical Lua call depth; deeper
        // chains fall back to geometric growth (rare). PUC has no limit
        // (linked list) but amortizes via never freeing on return.
        // Memory cost: 64 * (BytecodeExecFrame + RuntimeFrame) = ~30KB per
        // active thread (acceptable; threads are not lightweight).
        self.frames.ensureTotalCapacity(self.alloc, 64) catch {};
        owner.bytecode_frames.ensureTotalCapacity(self.alloc, 64) catch {};
    }
```

Note: `ensureTotalCapacity` is infallible in practice (only fails on OOM). We use `catch {}` to avoid propagating the error up through `activateRuntime` (which is called from `switchRuntime` in the coroutine hot path and cannot return an error). If the pre-allocation fails, `addOne` will retry the allocation on the next push — correct behavior, just slower.

- [ ] **Step 2: Verify build**

Run: `zig build -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS (the change is additive — two `ensureTotalCapacity` calls).

- [ ] **Step 3: Run unit tests**

Run: `zig build test -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 4: Run smoke tests**

```bash
for f in tests/smoke/*.lua; do
    ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"
done
```
Expected: 45/45 PASS (no FAIL lines).

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.40a: pre-allocate frame capacity in activateRuntime (eliminate capacity-check branch)"
```

---

### Task 2: Pre-allocate frame capacity for main thread

**Files:**
- Modify: `src/lua/vm.zig` — `init` function (around line 1841)

The main thread is created in `init` (vm.zig:1841-1867). It's activated directly (not via `activateRuntime`) — `vm.active_runtime_thread = main_th` is set at line 1847. The `bytecode_frames` and `runtime_frames` arrays start empty (`.empty` default). We need to pre-allocate capacity here too.

- [ ] **Step 1: Add `ensureTotalCapacity` calls after main thread creation**

Find the `init` function (vm.zig:1841). After `vm.active_runtime_thread = main_th;` (line 1847), add:

```zig
        vm.main_thread = main_th;
        vm.active_runtime_thread = main_th;
        // P15.40a: Pre-allocate frame capacity for the main thread (same as
        // activateRuntime does for coroutines). The main thread is activated
        // directly here, not via activateRuntime, so we pre-allocate inline.
        vm.frames.ensureTotalCapacity(alloc, 64) catch @panic("oom");
        main_th.bytecode_frames.ensureTotalCapacity(alloc, 64) catch @panic("oom");
```

Note: Here we use `@panic("oom")` instead of `catch {}` because this is the VM initialization path — if we can't allocate 64 frames at init time, the VM can't start. This matches the existing `@panic("oom")` pattern used for `alloc.create(Thread)` at line 1841.

- [ ] **Step 2: Verify build**

Run: `zig build -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Run unit tests**

Run: `zig build test -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 4: Run smoke tests**

```bash
for f in tests/smoke/*.lua; do
    ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"
done
```
Expected: 45/45 PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.40a: pre-allocate frame capacity for main thread on init"
```

---

### Task 3: Pre-allocate frame capacity for new coroutines

**Files:**
- Modify: `src/lua/vm.zig` — `apiNewThread` function (line 2285)

New coroutines are created via `apiNewThread` (vm.zig:2285-2293). The thread is created with `.empty` arrays. When it's first activated via `activateRuntime`, Task 1's `ensureTotalCapacity` will fire. But we can pre-allocate here too, so the capacity is ready before the first `pushBytecodeExecFrame`.

- [ ] **Step 1: Add `ensureTotalCapacity` calls in `apiNewThread`**

Find the `apiNewThread` function (vm.zig:2285). After `try self.gcRegisterThread(th);` (line 2289), add:

```zig
    pub fn apiNewThread(self: *Vm, callee: Value) Error!*Thread {
        try exposeDispatchResult(void, self.testcChargeMemory(@sizeOf(Thread) + 64));
        const th = try self.alloc.create(Thread);
        th.* = .{ .status = .suspended, .callee = callee };
        try self.gcRegisterThread(th);
        self.gc_count_kb += @as(f64, @floatFromInt(@sizeOf(Thread))) / 1024.0;
        self.testc_obj_threads += 1;
        // P15.40a: Pre-allocate frame capacity for the new coroutine. This
        // avoids the capacity-check branch on the first 64 bytecode calls.
        // activateRuntime also does this (for threads parked and re-activated),
        // but pre-allocating here means the first activation is already ready.
        th.bytecode_frames.ensureTotalCapacity(self.alloc, 64) catch {};
        return th;
    }
```

Note: `runtime_frames` is NOT pre-allocated here because it's only used when the thread is active (moved to `self.frames` via `activateRuntime`). `activateRuntime` already pre-allocates `self.frames` in Task 1. But `bytecode_frames` stays on the Thread even when active (it's accessed via `exec_thread.bytecode_frames` directly), so we pre-allocate it here.

Actually, wait — let me re-check. `activateRuntime` moves `owner.runtime_frames` to `self.frames`, and pre-allocates `self.frames`. But `bytecode_frames` is NOT moved — it stays on the Thread and is accessed via `&exec_thread.bytecode_frames`. So `activateRuntime`'s `owner.bytecode_frames.ensureTotalCapacity` is the right place for coroutine re-activation, and `apiNewThread` is the right place for initial creation.

- [ ] **Step 2: Verify build**

Run: `zig build -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Run unit tests**

Run: `zig build test -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 4: Run smoke tests (especially coroutine tests)**

```bash
for f in tests/smoke/*.lua; do
    ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"
done
```
Expected: 45/45 PASS. Pay attention to:
- `35_thread_owned_bytecode_frames.lua`
- `36_thread_owned_runtime_stacks.lua`
- `37_inplace_bytecode_yield.lua`
- `38_generic_for_inplace_yield.lua`
- `39_complete_iterative_dispatch.lua`

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.40a: pre-allocate frame capacity for new coroutines in apiNewThread"
```

---

### Task 4: Full regression + perf + README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Build ReleaseFast**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 2: Zig unit tests**

Run: `zig build test -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: All smoke tests**

```bash
PASS=0; FAIL=0
for f in tests/smoke/*.lua; do
    if ./zig-out/bin/luazig "$f" >/dev/null 2>&1; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL: $f"
    fi
done
echo "Smoke: $PASS pass, $FAIL fail"
```
Expected: 45/45 PASS.

- [ ] **Step 4: Upstream matrix (per AGENTS.md, without `_soft`/`_port`)**

Run: `python3 tools/testes_matrix.py --timeout 120 2>&1 | tail -30`
Expected: 28/31 pass (same as pre-P15.40a baseline; no regressions). The 3 pre-existing fails (`attrib`, `big`, `files`) are unrelated.

- [ ] **Step 5: Stress test**

Run: `tools/iterative_dispatch_stress.sh 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 6: Perf measurement**

Run: `python3 tools/perf_compare.py --runs 7 --core 0 --no-build 2>&1 | tail -40`

Expected improvements:
- `lua_calls`: ~2-5% improvement (capacity-check branch eliminated from common case)
- Other workloads: ±noise (unrelated to frame allocation)

If `lua_calls` improvement is <2%, that's still acceptable — the capacity check was already well-predicted by the branch predictor. The real win comes from Phase B (merge frames) and Phase C (inline array). Note this in the README.

- [ ] **Step 7: Update baseline if perf improved**

If geomean improved by >3%:
```bash
python3 tools/perf_compare.py --runs 7 --core 0 --no-build --update-baseline 2>&1 | tail -10
```

- [ ] **Step 8: Update README**

Add a P15.40a section to README.md after the P15.40 section (or after P15.39 if P15.40 section doesn't exist yet). Include:

```markdown
### P15.40a — Pre-allocate frame capacity

Pre-allocation `bytecode_frames` и `frames` ArrayList capacity (64 entries) при
активации thread (`activateRuntime`), создании main thread (`init`) и создании
coroutine (`apiNewThread`). Первые 64 `addOne` вызова на каждом thread теперь
pure `items.len += 1` — без capacity-check branch на hot path.

PUC Lua не имеет этого overhead вообще (linked list, `luaE_extendCI` heap-alloc
но никогда не освобождает на return). Наш ArrayList с pre-allocation — это
промежуточный шаг; полная parity требует Phase B (merge frames) и Phase C
(inline array в Thread).

**Результат:**

| Workload | До P15.40a | После P15.40a | Изменение |
|---|---:|---:|---:|
| lua_calls | <FILL> | <FILL> | <FILL> |
| ... (geomean) | <FILL> | <FILL> | <FILL> |

(Fill in actual numbers from Step 6.)
```

- [ ] **Step 9: Commit**

```bash
git add README.md tools/perf/baseline-p15.37.json
git commit -m "docs: P15.40a pre-allocate frame capacity — update README + perf results"
```

---

## Risk register

1. **Memory cost per thread**
   - **Impact:** 64 × (200B + 280B) = ~30KB per active thread
   - **Mitigation:** Threads are not lightweight in luazig (each has its own bc_stack, boxed array, etc.). 30KB is acceptable. If memory becomes a concern, reduce the pre-allocation to 32.

2. **`ensureTotalCapacity` failure in `activateRuntime`**
   - **Impact:** If the pre-allocation fails (OOM), `addOne` will retry on the next push — correct but slower.
   - **Mitigation:** `catch {}` in `activateRuntime` (cannot propagate error). `@panic("oom")` in `init` (VM can't start without frames).

3. **Coroutine switch overhead**
   - **Impact:** `activateRuntime` now does two `ensureTotalCapacity` calls on every coroutine switch. If the thread already has capacity (common case), these are early-return no-ops.
   - **Mitigation:** `ensureTotalCapacity` checks `self.capacity >= new_capacity` first — O(1) early return. No allocation if capacity is already sufficient.

4. **Thread reuse after `freeThreadBytecodeFrames`**
   - **Impact:** `freeThreadBytecodeFrames` (vm.zig:2021) calls `clearAndFree`, which frees the backing memory. The next `activateRuntime` will re-allocate via `ensureTotalCapacity`.
   - **Mitigation:** This is correct — `clearAndFree` resets capacity to 0, and `ensureTotalCapacity` re-allocates. The re-allocation happens once per thread re-activation, not per call.

## Self-review notes

- **Spec coverage:** Phase A of the spec requires pre-allocation in `activateRuntime`, `init`, and `apiNewThread`. Tasks 1-3 cover all three. Task 4 verifies and documents.
- **Placeholder scan:** Every step has exact code or explicit commands. No "TODO" / "implement later".
- **Type consistency:** `ensureTotalCapacity(self.alloc, 64)` is the correct signature for `ArrayListUnmanaged`. The `catch {}` vs `@panic("oom")` choice is documented per call site.
