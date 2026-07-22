# Phase C: Inline Call Frame Array in Thread — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate heap allocation for shallow call chains (≤32 deep) by embedding a fixed-size `CallFrame` array directly in `Thread`, falling back to heap `ArrayList` for deeper chains.

**Architecture:** Introduce a `FrameStack` wrapper type that holds an inline `[32]CallFrame` array + a heap `ArrayList` overflow. All 42 functions currently taking `*std.ArrayListUnmanaged(CallFrame)` switch to `*FrameStack`. The wrapper exposes `items`, `len`, `addOne`, `pop`/`itemsLen -= 1` with the same semantics, making the migration mostly mechanical.

**Tech Stack:** Zig (system toolchain), `std.ArrayListUnmanaged` for overflow, existing smoke/matrix test infrastructure.

**Spec:** `docs/superpowers/specs/2026-07-20-callinfo-parity-design.md` § "Phase C: Inline array in Thread"

**Key invariants:**
- `Thread.call_frames` (bytecode frames) stays with the thread during coroutine switch — NOT moved by `parkActiveRuntime`/`activateRuntime`.
- `Vm.call_frames` (IR frames) IS moved via `parked_call_frames` — this stays as `ArrayListUnmanaged` (only 1 append site, not hot path).
- `CallFrame` = 424 B. 32 inline = 13.5 KB per Thread — acceptable.
- `exec_frames` in dispatch functions is always `&thread.call_frames` — a `*FrameStack`.

---

## File Structure

- **Modify:** `src/lua/vm.zig` — all changes in this file
- **Test:** `tests/smoke/*.lua` (existing, no new tests needed)
- **Perf:** `tools/perf_compare.py`

---

### Task 1: Define `FrameStack` wrapper type

**Files:**
- Modify: `src/lua/vm.zig` (near `CallFrame` definition, ~line 958)

- [ ] **Step 1: Define the `FrameStack` struct**

Insert after the `CallFrame` struct definition (after its closing `};`):

```zig
/// PUC `base_ci` equivalent: inline call-frame storage with heap overflow.
///
/// Frames 0..INLINE_FRAME_CAP-1 live in the inline array (no heap
/// allocation). Deeper chains spill to `heap`, which is a standard
/// ArrayList. PUC Lua uses a single inline `base_ci` entry + heap chain;
/// we inline 32 entries because our CallFrame is larger than PUC's ~48B
/// CallInfo, and typical Lua call depth is well under 32.
///
/// All access goes through `getPtr(index)` and `len()` — never index
/// the arrays directly from outside this struct.
const INLINE_FRAME_CAP: usize = 32;

const FrameStack = struct {
    inline_frames: [INLINE_FRAME_CAP]CallFrame = undefined,
    inline_count: usize = 0,
    heap: std.ArrayListUnmanaged(CallFrame) = .empty,

    /// Total number of frames (inline + heap).
    pub fn len(self: *const FrameStack) usize {
        return self.inline_count + self.heap.items.len;
    }

    /// Mutable pointer to frame at `index`.
    pub fn getPtr(self: *FrameStack, index: usize) *CallFrame {
        if (index < INLINE_FRAME_CAP) {
            std.debug.assert(index < self.inline_count);
            return &self.inline_frames[index];
        }
        return &self.heap.items[index - INLINE_FRAME_CAP];
    }

    /// Const pointer to frame at `index`.
    pub fn getConstPtr(self: *const FrameStack, index: usize) *const CallFrame {
        if (index < INLINE_FRAME_CAP) {
            std.debug.assert(index < self.inline_count);
            return &self.inline_frames[index];
        }
        return &self.heap.items[index - INLINE_FRAME_CAP];
    }

    /// Grow by one frame, return mutable pointer to the new slot.
    /// Mirrors `ArrayList.addOne` semantics.
    pub fn addOne(self: *FrameStack, alloc: std.mem.Allocator) !*CallFrame {
        if (self.inline_count < INLINE_FRAME_CAP) {
            const idx = self.inline_count;
            self.inline_count += 1;
            return &self.inline_frames[idx];
        }
        return try self.heap.addOne(alloc);
    }

    /// Ensure total capacity is at least `cap` (pre-allocation hint).
    pub fn ensureTotalCapacity(self: *FrameStack, alloc: std.mem.Allocator, cap: usize) !void {
        if (cap > INLINE_FRAME_CAP) {
            try self.heap.ensureTotalCapacity(alloc, cap - INLINE_FRAME_CAP);
        }
    }

    /// Shrink to exactly `new_len` frames. Mirrors `items.len = new_len`.
    pub fn shrinkTo(self: *FrameStack, new_len: usize) void {
        if (new_len <= INLINE_FRAME_CAP) {
            // All frames fit in inline — clear heap if any spilled.
            self.heap.items.len = 0;
            self.inline_count = new_len;
        } else {
            self.inline_count = INLINE_FRAME_CAP;
            self.heap.items.len = new_len - INLINE_FRAME_CAP;
        }
    }

    /// Deinit heap storage. Inline array needs no cleanup.
    pub fn deinit(self: *FrameStack, alloc: std.mem.Allocator) void {
        self.heap.deinit(alloc);
    }
};
```

- [ ] **Step 2: Build to verify no syntax errors**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: Build succeeds (the new type is unused, so no changes in behavior).

- [ ] **Step 3: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.48c-1: define FrameStack wrapper with inline array + heap overflow"
```

---

### Task 2: Change `Thread.call_frames` to `FrameStack`

**Files:**
- Modify: `src/lua/vm.zig` — `Thread` struct (~line 1089), `parkActiveRuntime` (~2001), `activateRuntime` (~2033), `switchRuntime` (~2092), `Vm.init` (~1947), `freeThread` (~2103)

- [ ] **Step 1: Change `Thread.call_frames` field type**

At ~line 1089, change:
```zig
call_frames: std.ArrayListUnmanaged(CallFrame) = .empty,
```
to:
```zig
call_frames: FrameStack = .{},
```

- [ ] **Step 2: Remove `Thread.parked_call_frames`**

At ~line 1097, the `parked_call_frames` field was used to move `Vm.call_frames` (IR frames) during coroutine switch. This is unrelated to `Thread.call_frames` (bytecode frames) and stays. **Do NOT remove it.** Leave `parked_call_frames` as is.

- [ ] **Step 3: Update `parkActiveRuntime` (~line 2001)**

The function moves `Vm.call_frames` (IR frames) to `owner.parked_call_frames`. This does NOT touch `Thread.call_frames` (bytecode frames). The line:
```zig
if (owner.call_frames.items.len != 0) {
    owner.call_frames.items[owner.call_frames.items.len - 1].pc = self.bc_dispatch_pc;
}
```
Change to:
```zig
if (owner.call_frames.len() != 0) {
    owner.call_frames.getPtr(owner.call_frames.len() - 1).pc = self.bc_dispatch_pc;
}
```

- [ ] **Step 4: Update `activateRuntime` (~line 2033)**

The line:
```zig
if (owner.call_frames.items.len != 0) {
    self.bc_dispatch_pc = owner.call_frames.items[owner.call_frames.items.len - 1].pc;
}
```
Change to:
```zig
if (owner.call_frames.len() != 0) {
    self.bc_dispatch_pc = owner.call_frames.getPtr(owner.call_frames.len() - 1).pc;
}
```

Also at ~line 2065-2066:
```zig
self.call_frames.ensureTotalCapacity(self.alloc, 64) catch {};
owner.call_frames.ensureTotalCapacity(self.alloc, 64) catch {};
```
The first line (`self.call_frames`) is `Vm.call_frames` (IR frames, still `ArrayListUnmanaged`) — leave as is.
The second line (`owner.call_frames`) is now `FrameStack` — change to:
```zig
owner.call_frames.ensureTotalCapacity(self.alloc, 64) catch {};
```
This still works because `FrameStack.ensureTotalCapacity` is defined.

- [ ] **Step 5: Update `Vm.init` (~line 1970-1971)**

```zig
vm.call_frames.ensureTotalCapacity(alloc, 64) catch @panic("oom");
main_th.call_frames.ensureTotalCapacity(alloc, 64) catch @panic("oom");
```
First line is `Vm.call_frames` (ArrayList) — leave as is.
Second line is now `FrameStack` — `ensureTotalCapacity` is defined, so no change needed.

- [ ] **Step 6: Update `freeThread` (~line 2103)**

```zig
th.parked_call_frames.deinit(self.alloc);
```
This is `parked_call_frames` (ArrayList) — leave as is.

Find where `Thread.call_frames` is deinited and change `.deinit(self.alloc)` to `FrameStack.deinit`:
```zig
th.call_frames.deinit(self.alloc);
```
This already works because `FrameStack` has `deinit`.

- [ ] **Step 7: Build and fix compilation errors**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -20`

There will be many errors from `.items` and `.items.len` access on `FrameStack`. These are expected — we fix them in Task 3.

- [ ] **Step 8: Commit (may not compile yet — that's OK, we fix in Task 3)**

```bash
git add src/lua/vm.zig
git commit -m "P15.48c-2: switch Thread.call_frames to FrameStack type"
```

---

### Task 3: Migrate all `Thread.call_frames` direct access sites

**Files:**
- Modify: `src/lua/vm.zig` — 91 sites indexing `.call_frames.items[i]` on Thread instances, 122 sites using `.call_frames.items.len`

This is the bulk mechanical migration. The pattern is:
- `X.call_frames.items[i]` → `X.call_frames.getPtr(i).*` (for mutable access) or `X.call_frames.getConstPtr(i).*` (for const)
- `X.call_frames.items.len` → `X.call_frames.len()`
- `X.call_frames.items.len = N` → `X.call_frames.shrinkTo(N)`
- `X.call_frames.items.len -= 1` → `X.call_frames.shrinkTo(X.call_frames.len() - 1)`

- [ ] **Step 1: Fix all `thread.call_frames.items[i]` and `th.call_frames.items[i]` sites**

Search for all `\.call_frames\.items\[` on Thread instances. For each:

- `&th.call_frames.items[i]` → `th.call_frames.getPtr(i)`
- `th.call_frames.items[i]` (value access) → `th.call_frames.getConstPtr(i).*`
- `th.call_frames.items[th.call_frames.items.len - 1]` → `th.call_frames.getPtr(th.call_frames.len() - 1)`

Key sites to fix (non-exhaustive, ~91 total):
- ~line 2015: `owner.call_frames.items[owner.call_frames.items.len - 1].pc`
- ~line 2088: `owner.call_frames.items[owner.call_frames.items.len - 1].pc`
- ~line 2129: `thread.call_frames.items[i]`
- ~line 2150: `th.call_frames.items[i]`
- ~line 2200: `th.call_frames.items[i]`
- ~line 2288: `th.call_frames.items[th.call_frames.items.len - 1]`
- ~line 2782-2789: `th_bc.call_frames.items[i]` and `self.call_frames.items[i]` (note: `self.call_frames` is `Vm.call_frames` IR frames — leave those as `ArrayList`)
- ~line 2831, 2842, 2889, 2899, 3152, etc.

**IMPORTANT:** `self.call_frames` (Vm.call_frames, IR frames) is still `ArrayListUnmanaged`. Only `thread.call_frames` / `th.call_frames` / `owner.call_frames` / `exec_frames` (which points to thread's) are `FrameStack`.

- [ ] **Step 2: Fix all `thread.call_frames.items.len` sites**

Search for `\.call_frames\.items\.len` on Thread instances. For each:
- `th.call_frames.items.len` → `th.call_frames.len()`
- `th.call_frames.items.len = N` → `th.call_frames.shrinkTo(N)`
- `th.call_frames.items.len -= 1` → `th.call_frames.shrinkTo(th.call_frames.len() - 1)`

**IMPORTANT:** `self.call_frames.items.len` (Vm IR frames) stays as `.items.len`.

- [ ] **Step 3: Build and fix remaining errors**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -30`

Fix any remaining `.items` access on `FrameStack` instances. The compiler errors will guide you to each site.

- [ ] **Step 4: Run smoke tests**

Run:
```bash
zig build -Doptimize=ReleaseFast 2>&1 | tail -3
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig --vm=bc "$f" > /dev/null 2>&1 || echo "FAIL: $f"; done
```
Expected: No failures.

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.48c-3: migrate Thread.call_frames access sites to FrameStack API"
```

---

### Task 4: Migrate `exec_frames` parameter type and all its access sites

**Files:**
- Modify: `src/lua/vm.zig` — 42 function signatures + 120 access sites

`exec_frames` is always `&thread.call_frames`. Currently typed as `*std.ArrayListUnmanaged(CallFrame)`. Change to `*FrameStack`.

- [ ] **Step 1: Change all 42 function signatures**

Search for `exec_frames: \*std.ArrayListUnmanaged\(CallFrame\)` and replace with:
```
exec_frames: *FrameStack
```

This affects ~42 function parameter declarations.

- [ ] **Step 2: Fix `exec_frames.items[i]` access (120 sites)**

Same pattern as Task 3:
- `&exec_frames.items[i]` → `exec_frames.getPtr(i)`
- `exec_frames.items[i]` (value) → `exec_frames.getConstPtr(i).*`
- `exec_frames.items[exec_frames.items.len - 1]` → `exec_frames.getPtr(exec_frames.len() - 1)`

- [ ] **Step 3: Fix `exec_frames.items.len` access**

- `exec_frames.items.len` → `exec_frames.len()`
- `exec_frames.items.len = N` → `exec_frames.shrinkTo(N)`
- `exec_frames.items.len -= 1` → `exec_frames.shrinkTo(exec_frames.len() - 1)`

- [ ] **Step 4: Fix `exec_frames.addOne(self.alloc)`**

This already works — `FrameStack.addOne` has the same signature.

- [ ] **Step 5: Fix `exec_frames.ensureTotalCapacity`**

This already works — `FrameStack.ensureTotalCapacity` has the same signature.

- [ ] **Step 6: Build and fix remaining errors**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -30`

- [ ] **Step 7: Run smoke tests**

Run:
```bash
zig build -Doptimize=ReleaseFast 2>&1 | tail -3
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig --vm=bc "$f" > /dev/null 2>&1 || echo "FAIL: $f"; done
```
Expected: No failures.

- [ ] **Step 8: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.48c-4: migrate exec_frames parameter type to FrameStack"
```

---

### Task 5: Fix `BytecodeDispatchCtx.exec_frames` field

**Files:**
- Modify: `src/lua/vm.zig` — `BytecodeDispatchCtx` struct

- [ ] **Step 1: Find and update the `BytecodeDispatchCtx` struct**

Search for the struct definition. It has an `exec_frames` field. Change its type from `*std.ArrayListUnmanaged(CallFrame)` to `*FrameStack`.

- [ ] **Step 2: Build and fix errors**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -10`

- [ ] **Step 3: Run smoke tests**

Run:
```bash
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig --vm=bc "$f" > /dev/null 2>&1 || echo "FAIL: $f"; done
```
Expected: No failures.

- [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.48c-5: update BytecodeDispatchCtx.exec_frames to FrameStack"
```

---

### Task 6: Fix remaining `ArrayList`-specific patterns

**Files:**
- Modify: `src/lua/vm.zig`

Some patterns may not have direct `FrameStack` equivalents yet.

- [ ] **Step 1: Search for remaining `.items` on FrameStack**

Run: `grep -n "call_frames\.items\|exec_frames\.items" src/lua/vm.zig`

Any remaining hits on Thread/exec_frames (not `self.call_frames` which is Vm IR frames) need fixing.

- [ ] **Step 2: Handle `append` if any**

Search: `grep -n "call_frames\.append\|exec_frames\.append" src/lua/vm.zig`

If any `append` calls exist on `FrameStack`, convert to `addOne` + field writes (matching the existing pattern in `pushBytecodeExecFrame`).

- [ ] **Step 3: Handle `pop` if any**

Search: `grep -n "call_frames\.pop\|exec_frames\.pop" src/lua/vm.zig`

Convert to `shrinkTo(len() - 1)`.

- [ ] **Step 4: Handle `clearAndFree` if any**

Search: `grep -n "call_frames\.clearAndFree\|exec_frames\.clearAndFree" src/lua/vm.zig`

If found, add a `clearAndFree` method to `FrameStack`:
```zig
pub fn clearAndFree(self: *FrameStack, alloc: std.mem.Allocator) void {
    self.inline_count = 0;
    self.heap.clearAndFree(alloc);
}
```

- [ ] **Step 5: Build and run smoke tests**

Run:
```bash
zig build -Doptimize=ReleaseFast 2>&1 | tail -3
for f in tests/smoke/*.lua; do ./zig-out/bin/luazig --vm=bc "$f" > /dev/null 2>&1 || echo "FAIL: $f"; done
```
Expected: No failures.

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.48c-6: fix remaining ArrayList-specific patterns on FrameStack"
```

---

### Task 7: Full regression + perf verification

**Files:**
- No code changes — verification only

- [ ] **Step 1: Build ReleaseFast**

Run: `zig build -Doptimize=ReleaseFast 2>&1 | tail -3`
Expected: Clean build.

- [ ] **Step 2: Run all smoke tests**

Run:
```bash
passed=0; failed=0
for f in tests/smoke/*.lua; do
  if ./zig-out/bin/luazig --vm=bc "$f" > /dev/null 2>&1; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "FAIL: $f"
  fi
done
echo "Passed: $passed, Failed: $failed"
```
Expected: 45/45 pass.

- [ ] **Step 3: Run matrix tests (no _soft, no _port)**

Run:
```bash
cd lua-5.5.0/testes
python3 ../../tools/testes_matrix.py --timeout 120
```
Expected: 28/31 pass (same as before — no regressions).

- [ ] **Step 4: Run perf comparison**

Run:
```bash
python3 tools/perf_compare.py --runs 7 --core 0 --no-build
```
Expected: lua_calls improvement (~5-10%), geomean improvement (~2-3%). No regressions >5%.

- [ ] **Step 5: Update README.md**

Add a new section after P15.47:

```markdown
### P15.48c — Inline call frame array in Thread (Phase C)

Embed a fixed-size `[32]CallFrame` array directly in `Thread`, eliminating
heap allocation for call chains ≤32 deep (the vast majority of real Lua
programs). Deeper chains spill to a heap `ArrayList` overflow.

PUC Lua's `base_ci` is the equivalent inline first frame; we inline 32
because our `CallFrame` (424 B) is larger than PUC's `CallInfo` (~48 B),
and typical Lua call depth is well under 32.

`FrameStack` wrapper: `inline_frames[32]` + `heap: ArrayList` overflow.
All access goes through `getPtr(index)` / `len()` / `addOne()` / `shrinkTo()`.
42 function signatures migrated from `*std.ArrayListUnmanaged(CallFrame)` to
`*FrameStack`. 211 direct `.items[]` indexing sites migrated to the wrapper API.

`Thread.call_frames` (bytecode frames) stays with the thread during coroutine
switch — no special handling needed (unlike `Vm.call_frames` IR frames which
are moved via `parked_call_frames`).

**Results:** [fill in after perf run]
```

- [ ] **Step 6: Commit**

```bash
git add README.md src/lua/vm.zig
git commit -m "P15.48c: inline call frame array in Thread (Phase C) — complete"
```

---

## Self-Review

**Spec coverage:**
- ✅ Inline array in Thread — Task 1-2
- ✅ `pushBytecodeExecFrame` uses inline first — Task 1 (addOne checks inline_count < CAP)
- ✅ Coroutine switch: inline array stays with Thread — Task 2 (no special handling needed, documented)
- ✅ Frame struct layout unchanged — CallFrame from Phase B, no changes
- ✅ Varargs still heap — Phase D, not this plan
- ✅ Verification: smoke tests, matrix, perf — Task 7

**Placeholder scan:** No placeholders. All code shown is complete.

**Type consistency:** `FrameStack` methods (`getPtr`, `getConstPtr`, `len`, `addOne`, `ensureTotalCapacity`, `shrinkTo`, `deinit`) are used consistently across all tasks.
