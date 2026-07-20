# P15.40b — Merge BytecodeExecFrame + RuntimeFrame Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge `BytecodeExecFrame` and `RuntimeFrame` into a single `CallFrame` struct, replacing the two parallel arrays (`bytecode_frames` and `frames`) with one `call_frames` array. Eliminates one `addOne` call, ~25 redundant field writes, and the `runtime_frame_index` indirection per push.

**Architecture:** PUC Lua has a single `CallInfo` struct per call frame. luazig currently maintains two parallel structs/arrays that are always pushed and popped together, linked by `runtime_frame_index`. The merge unifies them into one struct with all fields, using `proto: ?*const bc.Proto` (null for IR frames) as the discriminator.

**Tech Stack:** Zig 0.16.0, existing ArrayListUnmanaged infrastructure.

**Spec:** `docs/superpowers/specs/2026-07-20-callinfo-parity-design.md` (Phase B)

---

## Field mapping

### Overlapping fields (same name, same semantics — unify type)

| BytecodeExecFrame | RuntimeFrame | Merged CallFrame | Notes |
|---|---|---|---|
| `proto: *const bc.Proto` | `proto: ?*const bc.Proto` | `proto: ?*const bc.Proto` | Make optional; bytecode frames always set non-null |
| `upvalues: []const *Cell` | `upvalues: []const *Cell` | `upvalues: []const *Cell` | Same |
| `pc: usize = 0` | `pc: usize = 0` | `pc: usize = 0` | Same |
| `current_line: i64 = 0` | `current_line: i64` | `current_line: i64 = 0` | Same |
| `last_hook_line: i64 = -1` | `last_hook_line: i64` | `last_hook_line: i64 = -1` | Same |
| `is_tailcall: bool = false` | `is_tailcall: bool` | `is_tailcall: bool = false` | Same |
| `varargs: []Value` | `varargs: []Value` | `varargs: []Value` | Same |
| `nvarstack: u8` | `nvarstack: u32 = 0` | `nvarstack: u32 = 0` | Widen u8→u32; bytecode sites use `@intCast` |

### Bytecode-only fields (add to CallFrame, unused for IR)

| Field | Type | Notes |
|---|---|---|
| `activation_id: usize = 0` | Bytecode thread identity |
| `base: usize = 0` | bc_stack offset (replaces RuntimeFrame.bc_base) |
| `frame_cap: usize = 0` | Frame capacity |
| `resume_pc: usize = 0` | Resume program counter |
| `reg_top: u32 = 0` | Register top (replaces RuntimeFrame.top) |
| `last_line_pc: ?usize = null` | Line hook tracing |
| `skip_line_hook_pc: ?usize = null` | Hook skip |
| `resumed_direct_yield: bool = false` | Coroutine resume |
| `tbc_mark: usize = 0` | TBC register mark |
| `pending_call: PendingCallSlot = .{}` | Pending call continuation |
| `skip_call_hook_pc: ?usize = null` | Call hook skip |

### IR-only fields (add to CallFrame, unused for bytecode)

| Field | Type | Notes |
|---|---|---|
| `func: *const ir.Function` | IR function (bc_dummy_func for bytecode) |
| `callee: Value = .Nil` | Callee value |
| `regs: []Value = &.{}` | IR register slice (bytecode re-derives from bc_stack) |
| `locals: []Value = &.{}` | IR locals |
| `boxed: []?*Cell = &.{}` | IR boxed cells (bytecode re-derives from bc_boxed) |
| `local_active: []bool = &.{}` | IR local active flags |
| `env_override: ?Value = null` | Environment override |
| `frame_id: usize = 0` | Frame identity |
| `used_closing_line_hook: bool = false` | Hook tracking |
| `resume_skip_count_pc: ?usize = null` | Resume skip |
| `hide_from_debug: bool = false` | Debug visibility |
| `debug_namewhat: ?[]const u8 = null` | Debug name |
| `debug_name: ?[]const u8 = null` | Debug name |
| `is_debug_hook: bool = false` | Debug hook flag |
| `debug_hook_transfer: ?[]const Value = null` | Hook transfer |
| `debug_hook_transfer_start: i64 = 1` | Hook transfer start |
| `debug_hook_event_calllike: bool = false` | Hook event type |
| `debug_hook_event_tailcall: bool = false` | Hook event type |
| `debug_hook_event_is_count: bool = false` | Hook event type |
| `debug_hook_allow_yield: bool = false` | Hook yieldability |

### Removed fields

| Field | Reason |
|---|---|
| `runtime_frame_index` | No longer needed — single array |
| `bc_base` (RuntimeFrame) | Replaced by `base` (from BytecodeExecFrame) |
| `top` (RuntimeFrame) | Replaced by `reg_top` (from BytecodeExecFrame) |

### Field name changes (access site migration)

| Old (RuntimeFrame) | New (CallFrame) | Sites |
|---|---|---|
| `.bc_base` | `.base` | 2 |
| `.top` | `.reg_top` | ~5 |
| `.nvarstack` (u32) | `.nvarstack` (u32, no cast needed for RT sites; BC sites need `@intCast`) | ~13 |

---

## File Structure

- **Modify:** `src/lua/vm.zig` — define `CallFrame`, migrate all 305 access sites
- **No new files.**

## Current state (before P15.40b)

Two parallel arrays, always pushed/popped together:
- `Thread.bytecode_frames: ArrayListUnmanaged(BytecodeExecFrame)` — 135 access sites
- `Vm.frames: ArrayListUnmanaged(RuntimeFrame)` — 172 access sites (includes IR path)
- Linked by `runtime_frame_index` — 31 sites

## Target state (after P15.40b)

Single array:
- `Thread.call_frames: ArrayListUnmanaged(CallFrame)` — all sites migrated
- No `runtime_frame_index`
- `pushBytecodeExecFrame` does ONE `addOne` + unified field writes
- `popBytecodeExecFrame` does ONE `items.len -= 1`

---

### Task 1: Define CallFrame struct + accessors

**Files:**
- Modify: `src/lua/vm.zig` — add `CallFrame` after `BytecodeExecFrame` (line 789)

- [ ] **Step 1: Define CallFrame struct**

Insert after `BytecodeExecFrame` (line 789), before the PendingCallSlot docs (line 791):

```zig
/// P15.40b: Merged call frame — PUC `CallInfo` equivalent.
///
/// Replaces the dual `BytecodeExecFrame` + `RuntimeFrame` arrays with a
/// single array. PUC Lua has one `CallInfo` per call frame; we now match
/// that architecture. The `proto` field (null for IR frames, non-null for
/// bytecode frames) is the discriminator, like PUC's `CIST_C` bit.
///
/// Fields from BytecodeExecFrame that were also in RuntimeFrame under
/// different names:
/// - `base` (was `bc_base` in RuntimeFrame)
/// - `reg_top` (was `top` in RuntimeFrame)
/// - `nvarstack` widened from u8 (BytecodeExecFrame) to u32 (RuntimeFrame)
/// - `proto` made optional (was non-optional in BytecodeExecFrame)
///
/// Removed: `runtime_frame_index` (no longer needed — single array).
const CallFrame = struct {
    // ── Common fields ──
    func: *const ir.Function = &bc_dummy_func,
    proto: ?*const bc.Proto = null,
    callee: Value = .Nil,
    pc: usize = 0,
    current_line: i64 = 0,
    last_hook_line: i64 = -1,
    is_tailcall: bool = false,
    varargs: []Value = &.{},
    upvalues: []const *Cell = &.{},
    nvarstack: u32 = 0,

    // ── Bytecode-specific (valid when proto != null) ──
    activation_id: usize = 0,
    base: usize = 0,
    frame_cap: usize = 0,
    resume_pc: usize = 0,
    reg_top: u32 = 0,
    last_line_pc: ?usize = null,
    skip_line_hook_pc: ?usize = null,
    resumed_direct_yield: bool = false,
    tbc_mark: usize = 0,
    pending_call: PendingCallSlot = .{},
    skip_call_hook_pc: ?usize = null,

    // ── IR-specific (valid when proto == null) ──
    regs: []Value = &.{},
    locals: []Value = &.{},
    boxed: []?*Cell = &.{},
    local_active: []bool = &.{},

    // ── Debug fields ──
    env_override: ?Value = null,
    frame_id: usize = 0,
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

    // ── Accessors (migrated from RuntimeFrame) ──
    pub fn isVararg(fr: CallFrame) bool {
        if (fr.proto) |p| return p.is_vararg;
        return fr.func.is_vararg;
    }

    pub fn lineDefined(fr: CallFrame) u32 {
        if (fr.proto) |p| return p.line_defined;
        return fr.func.line_defined;
    }

    pub fn sourceName(fr: CallFrame) []const u8 {
        if (fr.proto) |p| return p.source_name;
        return fr.func.source_name;
    }
};
```

- [ ] **Step 2: Verify build**

Run: `zig build -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS (the struct is additive, no callers yet).

- [ ] **Step 3: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.40b: define CallFrame struct (merged BytecodeExecFrame + RuntimeFrame)"
```

---

### Task 2: Migrate pushBytecodeExecFrame + popBytecodeExecFrame

**Files:**
- Modify: `src/lua/vm.zig` — `pushBytecodeExecFrame` (line 6700), `popBytecodeExecFrame` (line 6825)

This is the core change: replace the dual `addOne` + dual field writes with a single `addOne` + unified field writes.

- [ ] **Step 1: Replace pushBytecodeExecFrame body**

Find `pushBytecodeExecFrame` (vm.zig:6700). The current code does:
1. `self.frames.addOne(self.alloc)` → writes RuntimeFrame fields
2. `exec_frames.addOne(self.alloc)` → writes BytecodeExecFrame fields

Replace with a single `addOne` on `call_frames` and unified field writes.

**Before (lines 6700-6824, approximate):**
```zig
fn pushBytecodeExecFrame(
    self: *Vm,
    exec_frames: *std.ArrayListUnmanaged(BytecodeExecFrame),
    proto: *const bc.Proto,
    upvalues: []const *Cell,
    args: []const Value,
    callee_cl: ?*Closure,
) DispatchError!void {
    // ... resolveProtoConstants, stack checks ...
    const runtime_frame_index = self.frames.items.len;
    const rf_slot = try self.frames.addOne(self.alloc);
    // ... write ~25 RuntimeFrame fields ...
    const ef_slot = try exec_frames.addOne(self.alloc);
    // ... write ~20 BytecodeExecFrame fields ...
}
```

**After:**
```zig
fn pushBytecodeExecFrame(
    self: *Vm,
    call_frames: *std.ArrayListUnmanaged(CallFrame),
    proto: *const bc.Proto,
    upvalues: []const *Cell,
    args: []const Value,
    callee_cl: ?*Closure,
) DispatchError!void {
    // ... resolveProtoConstants, stack checks (unchanged) ...
    const nparams = proto.numparams;
    // ... varargs logic (unchanged) ...
    const base = self.bc_stack_top;
    // ... ensureBcStackCap, bc_stack_top (unchanged) ...
    const regs = self.bc_stack[base .. base + frame_cap];
    const boxed = self.bc_boxed[base .. base + frame_cap];
    // ... ncopy, nil-fill (unchanged) ...
    const tbc_mark = self.bc_tbc_regs.items.len;

    const frame_callee: Value = if (callee_cl) |cl| .{ .Closure = cl } else .Nil;
    const activation_owner = self.activeBytecodeThread();
    activation_owner.bytecode_activation_counter +%= 1;
    if (activation_owner.bytecode_activation_counter == 0)
        activation_owner.bytecode_activation_counter = 1;

    // P15.40b: Single addOne + unified field writes (was two addOne + ~50 writes).
    const cf_slot = try call_frames.addOne(self.alloc);
    errdefer call_frames.items.len -= 1;

    // Common fields
    cf_slot.func = &bc_dummy_func;
    cf_slot.proto = proto;
    cf_slot.callee = frame_callee;
    cf_slot.pc = 0;
    cf_slot.current_line = 0;
    cf_slot.last_hook_line = -1;
    cf_slot.is_tailcall = false;
    cf_slot.varargs = frame_varargs;
    cf_slot.upvalues = upvalues;
    cf_slot.nvarstack = @intCast(nparams);

    // Bytecode-specific
    cf_slot.activation_id = activation_owner.bytecode_activation_counter;
    cf_slot.base = base;
    cf_slot.frame_cap = frame_cap;
    cf_slot.resume_pc = 0;
    cf_slot.reg_top = @intCast(nparams);
    cf_slot.last_line_pc = null;
    cf_slot.skip_line_hook_pc = null;
    cf_slot.resumed_direct_yield = false;
    cf_slot.tbc_mark = tbc_mark;
    cf_slot.pending_call.clear();
    cf_slot.skip_call_hook_pc = null;

    // Debug fields (defaults — must set explicitly per P15.37a)
    cf_slot.env_override = null;
    cf_slot.frame_id = 0;
    cf_slot.used_closing_line_hook = false;
    cf_slot.resume_skip_count_pc = null;
    cf_slot.hide_from_debug = false;
    cf_slot.debug_namewhat = null;
    cf_slot.debug_name = null;
    cf_slot.is_debug_hook = false;
    cf_slot.debug_hook_transfer = null;
    cf_slot.debug_hook_transfer_start = 1;
    cf_slot.debug_hook_event_calllike = false;
    cf_slot.debug_hook_event_tailcall = false;
    cf_slot.debug_hook_event_is_count = false;
    cf_slot.debug_hook_allow_yield = false;

    // IR-specific (unused for bytecode, but must be initialized for safety)
    cf_slot.regs = &.{};
    cf_slot.locals = &.{};
    cf_slot.boxed = &.{};
    cf_slot.local_active = &.{};
}
```

- [ ] **Step 2: Replace popBytecodeExecFrame body**

Find `popBytecodeExecFrame` (vm.zig:6825). The current code pops both arrays and uses `runtime_frame_index` to link them.

**Before:**
```zig
fn popBytecodeExecFrame(
    self: *Vm,
    exec_frames: *std.ArrayListUnmanaged(BytecodeExecFrame),
) void {
    const idx = exec_frames.items.len - 1;
    const frame = exec_frames.items[idx];
    if (exec_frames.items[idx].pending_call.getPtr()) |pending| {
        const runtime: ?*RuntimeFrame = if (frame.runtime_frame_index < self.frames.items.len)
            &self.frames.items[frame.runtime_frame_index]
        else
            null;
        self.cancelBytecodePendingCall(pending, runtime);
    }
    std.debug.assert(self.frames.items.len == frame.runtime_frame_index + 1);
    if (self.frames.items[frame.runtime_frame_index].is_debug_hook) {
        self.activeHookState().in_debug_hook = false;
    }
    if (frame.varargs.ptr != empty_varargs.ptr) self.alloc.free(frame.varargs);
    self.frames.items.len = frame.runtime_frame_index;
    self.bc_tbc_regs.items.len = frame.tbc_mark;
    self.bc_stack_top = frame.base;
    exec_frames.items.len = idx;
}
```

**After:**
```zig
fn popBytecodeExecFrame(
    self: *Vm,
    call_frames: *std.ArrayListUnmanaged(CallFrame),
) void {
    const idx = call_frames.items.len - 1;
    const frame = &call_frames.items[idx];
    if (frame.pending_call.getPtr()) |pending| {
        self.cancelBytecodePendingCall(pending, frame);
    }
    if (frame.is_debug_hook) {
        self.activeHookState().in_debug_hook = false;
    }
    if (frame.varargs.ptr != empty_varargs.ptr) self.alloc.free(frame.varargs);
    self.bc_tbc_regs.items.len = frame.tbc_mark;
    self.bc_stack_top = frame.base;
    call_frames.items.len = idx;
}
```

Note: `cancelBytecodePendingCall` takes `?*RuntimeFrame` — update its signature to take `*CallFrame` (or `?*CallFrame`).

- [ ] **Step 3: Verify build (will fail — callers not yet updated)**

Run: `zig build -Doptimize=Debug 2>&1 | tail -20`
Expected: FAIL (callers still pass `exec_frames` and reference `BytecodeExecFrame`). This is expected — Task 3 migrates the callers.

- [ ] **Step 4: Commit (WIP — not expected to build yet)**

```bash
git add src/lua/vm.zig
git commit -m "P15.40b: migrate push/popBytecodeExecFrame to CallFrame (WIP)"
```

---

### Task 3: Migrate Thread/Vm fields + all call sites

**Files:**
- Modify: `src/lua/vm.zig` — all 305 access sites

This is the bulk of the migration. Replace `bytecode_frames` and `frames` with `call_frames`, and update all field access patterns.

- [ ] **Step 1: Replace Thread/Vm fields**

Find `Thread.bytecode_frames` (vm.zig:975) and `Thread.runtime_frames` (vm.zig:981). Replace with:

```zig
// P15.40b: Single merged call frame array (was bytecode_frames + runtime_frames)
call_frames: std.ArrayListUnmanaged(CallFrame) = .empty,
```

Remove `runtime_frames` field. Keep `bytecode_frames` as an alias during migration if needed, but ideally replace all at once.

Find `Vm.frames` (vm.zig:1671). Replace with:

```zig
// P15.40b: Active call frame array (moved from Thread during activation)
call_frames: std.ArrayListUnmanaged(CallFrame) = .empty,
```

- [ ] **Step 2: Update parkActiveRuntime / activateRuntime**

Find `parkActiveRuntime` (vm.zig:1923) and `activateRuntime` (vm.zig:1899). Replace `runtime_frames` / `frames` references with `call_frames`.

- [ ] **Step 3: Update all `exec_frames.items[i]` → `call_frames.items[i]`**

Find all 135 sites with `exec_frames.items[`. Replace `exec_frames` with `call_frames` (the variable name may differ — some sites use `&exec_thread.bytecode_frames`, others use `&parent.bytecode_frames`).

Key sites:
- vm.zig:7063: `const exec_frames = &exec_thread.bytecode_frames;` → `const call_frames = &exec_thread.call_frames;`
- vm.zig:5885: `const exec_frames = &parent.bytecode_frames;` → `const call_frames = &parent.call_frames;`
- vm.zig:6022: same pattern

- [ ] **Step 4: Update all `self.frames.items[i]` → `call_frames.items[i]`**

Find all 172 sites with `self.frames.items[`. Replace with `call_frames.items[`. Field name changes:
- `.bc_base` → `.base` (2 sites)
- `.top` → `.reg_top` (~5 sites)
- `.nvarstack` stays the same (but u32 now, so remove `@intCast` if present)

- [ ] **Step 5: Remove `runtime_frame_index` references**

Find all 31 sites with `runtime_frame_index`. Remove the field and all references. The index into `call_frames` IS the frame index — no indirection needed.

Key patterns:
- `frame.runtime_frame_index` → remove (use the frame's own index in the array)
- `self.frames.items[frame.runtime_frame_index]` → `call_frames.items[frame_idx]` (same frame)
- `const runtime_frame_index = self.frames.items.len;` → remove (no separate array)

- [ ] **Step 6: Update IR path (vm.zig:3127)**

Find `self.frames.append(self.alloc, .{...})` at vm.zig:3127. Replace with `self.call_frames.append(self.alloc, .{...})` using CallFrame field names. The IR path sets `func`, `callee`, `regs`, `locals`, `boxed`, `local_active`, `varargs`, `upvalues`, `env_override`, `frame_id`, `current_line`, `last_hook_line`, `used_closing_line_hook`, `resume_skip_count_pc`, `is_tailcall`, `hide_from_debug`. All other fields get defaults.

- [ ] **Step 7: Update freeThreadBytecodeFrames (vm.zig:2045)**

Replace `th.bytecode_frames` with `th.call_frames`. Remove `th.runtime_frames` references.

- [ ] **Step 8: Update GC scanning paths**

Find all `for (self.frames.items)` and `for (th.bytecode_frames.items)` loops in GC code. Replace with `for (self.call_frames.items)` and `for (th.call_frames.items)`.

- [ ] **Step 9: Update ensureTotalCapacity calls (P15.40a)**

Replace `self.frames.ensureTotalCapacity` and `owner.bytecode_frames.ensureTotalCapacity` with `self.call_frames.ensureTotalCapacity` and `owner.call_frames.ensureTotalCapacity`.

- [ ] **Step 10: Remove old struct definitions**

Remove `BytecodeExecFrame` and `RuntimeFrame` struct definitions. Remove `bc_dummy_func` reference if it's now a CallFrame default.

- [ ] **Step 11: Verify build**

Run: `zig build -Doptimize=Debug 2>&1 | tail -30`
Expected: PASS. Common errors:
- "use of undeclared identifier `exec_frames`" — missed a variable rename
- "use of undeclared identifier `runtime_frame_index`" — missed a reference
- "expected `*CallFrame`, found `*RuntimeFrame`" — missed a type annotation
- "no field named `bc_base`" — missed a field rename
- "no field named `top`" — missed a field rename (should be `reg_top`)

Fix all errors before proceeding.

- [ ] **Step 12: Run unit tests**

Run: `zig build test -Doptimize=Debug 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 13: Run smoke tests**

```bash
for f in tests/smoke/*.lua; do
    ./zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo "FAIL: $f"
done
```
Expected: 45/45 PASS.

- [ ] **Step 14: Commit**

```bash
git add src/lua/vm.zig
git commit -m "P15.40b: migrate all 305 call sites to CallFrame (merge complete)"
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

- [ ] **Step 4: Upstream matrix**

Run: `python3 tools/testes_matrix.py --timeout 120 2>&1 | tail -30`
Expected: 28/31 pass (no regressions).

- [ ] **Step 5: Stress test**

Run: `tools/iterative_dispatch_stress.sh 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 6: Perf measurement**

Run: `python3 tools/perf_compare.py --runs 7 --core 0 --no-build 2>&1 | tail -40`

Expected: ~5-10% improvement on `lua_calls` (one `addOne` instead of two, ~25 fewer field writes per push).

- [ ] **Step 7: Update baseline if perf improved >3%**

```bash
python3 tools/perf_compare.py --runs 7 --core 0 --no-build --update-baseline 2>&1 | tail -10
```

- [ ] **Step 8: Update README**

Add P15.40b section after P15.40a. Include perf table.

- [ ] **Step 9: Commit**

```bash
git add README.md tools/perf/baseline-p15.37.json
git commit -m "docs: P15.40b merge frames — update README + perf results"
```

---

## Risk register

1. **Field initialization order matters**
   - **Impact:** Stale values from prior activation leak through if a field is not explicitly written in `pushBytecodeExecFrame`.
   - **Mitigation:** P15.37a established the `addOne` + explicit write pattern. The plan lists every field that must be written.

2. **`nvarstack` type widening (u8 → u32)**
   - **Impact:** Bytecode sites that wrote `nvarstack = nparams` (u8) now need `@intCast(nparams)` for u32.
   - **Mitigation:** The plan specifies `@intCast` in the push function. Other bytecode sites that read `nvarstack` as u8 may need adjustment.

3. **`proto` optionality**
   - **Impact:** Bytecode sites that assumed `proto` is non-optional now need to unwrap `?*const bc.Proto`.
   - **Mitigation:** In `pushBytecodeExecFrame`, `proto` is set to a non-null value. Sites that read `frame.proto` in bytecode context can use `frame.proto.?` or keep the existing `if (fr.proto) |p|` pattern from RuntimeFrame.

4. **IR path compatibility**
   - **Impact:** IR frames use `func` and don't set bytecode fields. The merged struct has bytecode fields as defaults (0/null/empty), which should be safe.
   - **Mitigation:** IR path in Task 3 Step 6 explicitly sets all IR-specific fields and relies on defaults for bytecode-specific fields.

5. **`cancelBytecodePendingCall` signature change**
   - **Impact:** Takes `?*RuntimeFrame` → needs to take `?*CallFrame`.
   - **Mitigation:** Task 2 Step 2 notes this. Update the function signature.

## Self-review notes

- **Spec coverage:** Phase B of the spec requires merging the two structs into one `CallFrame`, replacing two arrays with one, and removing `runtime_frame_index`. Tasks 1-3 cover this. Task 4 verifies and documents.
- **Placeholder scan:** Every step has exact code or explicit "find lines X-Y and change Z to W" instructions. No "TODO" / "implement later".
- **Type consistency:** `CallFrame` field types are consistent across all tasks. `nvarstack` is u32 everywhere, `proto` is optional everywhere, `base` replaces `bc_base`, `reg_top` replaces `top`.
