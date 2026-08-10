# Phase 0: Closure.upvalues Ownership + Test Suite Memory Safety

> **STATUS: COMPLETE** — All 4 tasks done (2026-08-10). `zig build test -Doptimize=Debug`:
> 146/146 pass, 0 fail, 0 crash, 0 leaks. Matrix 30/31, smoke 49/49, leakbench 25/25,
> perf 2.69x (stable).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Problem

`zig build test -Doptimize=Debug` reports **3 fail + 9 crash + 89 leaks** (146 total).
The root cause is a single ownership invariant violation in `runBytecodeInternal`.

### Root Cause: Borrowed upvalues freed as owned

`runBytecodeInternal` (vm.zig:7727) creates a GC-registered `Closure` whose
`upvalues` field is set to `upvalues_in` — a **borrowed** slice (stack-local
array, `&.{}`, etc. from callers like `vm.runBytecode(proto, &.{}, &.{}, null)`).

`gcFreeObject(.closure)` (vm.zig:16123) calls `self.alloc.free(c.upvalues)` —
treating the slice as **owned**. This causes:
- **Invalid free** when `upvalues_in` is a stack-local array (4 `codegen_bc` crashes)
- **Index out of bounds** when `upvalues_in` is `&.{}` and the VM accesses
  `ctx.cur_upvalues[b]` (5 `vm` crashes — empty slice, any index is OOB)
- **89 leaks** from undumped Proto closures and test harness finalizers

### Ownership Invariant (must hold for ALL GC-registered Closures)

> Every GC-registered `Closure` MUST own its `upvalues` slice.
> `gcFreeObject(.closure)` calls `self.alloc.free(c.upvalues)`, so the slice
> must be heap-allocated by the closure creator.

### All Closure creation sites

| Site | Line | upvalues source | Owned? |
|------|------|----------------|--------|
| `runBytecodeInternal` | 7737 | `upvalues_in` (borrowed) | ❌ BUG |
| `opClosure` | 10621 | `cells` (alloc'd L10606) | ✅ |
| `createBytecodeChunkClosure` | 17133 | `cells` (alloc'd L17121) | ✅ |
| `setClosureEnv` | 17359 | `cells` (alloc'd L17350) | ✅ |
| `createUndumpedClosure` | 17460 | `cells` (alloc'd L17450) | ✅ |

Only `runBytecodeInternal` violates the invariant.

### Why the 5 `vm` crashes happen

Tests call `vm.runBytecode(proto, &.{}, &.{}, null)` — passing `&.{}` (empty
slice) as `upvalues_in`. The closure is registered with `upvalues = &.{}`.
When the bytecode accesses `ctx.cur_upvalues[b]` (GETUPVAL/GETTABUP/SETTABUP),
it indexes an empty slice → `index out of bounds: index 0, len 0`.

The fix: dup `upvalues_in` into a heap-allocated slice. For `&.{}` (len=0),
the dup produces a valid 0-length heap slice. The `index out of bounds` crash
is then a **separate** issue: the test bytecode uses GETUPVAL/GETTABUP but the
proto has 0 upvalues. This is a test harness issue — the tests compile source
that references globals (compiled to GETTABUP on upvalue 0 = `_ENV`), but pass
no upvalues. The fix is to provide a `_ENV` upvalue in the test harness, OR
to not register a closure at all when `callee_cl` is null and `upvalues_in`
is empty.

**Decision:** The closure materialization in `runBytecodeInternal` exists for
debug.getinfo parity. For test harness calls with `&.{}`, the closure should
still be created (for GC ownership consistency), but the test harness must
provide a `_ENV` upvalue if the bytecode uses globals. The 5 `vm` test crashes
will be fixed by providing a `_ENV` cell in the test harness.

---

## Task 1: Fix Closure.upvalues ownership in runBytecodeInternal

### What

In `runBytecodeInternal` (vm.zig:7727), when `callee_cl` is null, the code
creates a new `Closure` with `upvalues = upvalues_in` (borrowed). Fix: dup
`upvalues_in` into a heap-allocated slice so the closure owns it.

### Location

`src/lua/vm.zig`, function `runBytecodeInternal` (L7727).

### Change

**Before (L7732-7743):**
```zig
const effective_callee = callee_cl orelse blk: {
    const cl = try self.alloc.create(Closure);
    errdefer self.alloc.destroy(cl);
    cl.* = .{
        .proto = proto_in,
        .upvalues = upvalues_in,
    };
    try self.gcRegisterClosure(cl);
    self.gcNoteAlloc(@sizeOf(Closure));
    self.testc_obj_functions += 1;
    break :blk cl;
};
```

**After:**
```zig
// Ownership invariant: every GC-registered Closure owns its `upvalues`
// slice. gcFreeObject(.closure) calls self.alloc.free(c.upvalues), so
// the slice must be heap-allocated by the closure creator. Callers of
// runBytecode pass borrowed upvalues (stack-local arrays, &.{}, etc.);
// we dup the slice here so the closure owns it.
const effective_callee = callee_cl orelse blk: {
    const owned_upvalues = try self.alloc.alloc(*Cell, upvalues_in.len);
    errdefer self.alloc.free(owned_upvalues);
    @memcpy(owned_upvalues, upvalues_in);
    const cl = try self.alloc.create(Closure);
    errdefer self.alloc.destroy(cl);
    cl.* = .{
        .proto = proto_in,
        .upvalues = owned_upvalues,
    };
    try self.gcRegisterClosure(cl);
    self.gcNoteAlloc(@sizeOf(Closure) + upvalues_in.len * @sizeOf(*Cell));
    self.testc_obj_functions += 1;
    break :blk cl;
};
```

### Acceptance

- `zig build test -Doptimize=Debug`: the 4 `codegen_bc` "Invalid free" crashes
  are resolved (reduced from 9 crash to 5 crash)
- `python3 tools/testes_matrix.py --testc` — 30/31 (no regressions)
- `python3 tools/smoke_compare.py --no-build` — 49/49 (no regressions)

---

## Task 2: Fix vm test harness — provide _ENV upvalue ✅ DONE

### What

The 5 `vm.test.vm` crashes are `index out of bounds: index 0, len 0` at
`ctx.cur_upvalues[b]` (GETTABUP/GETUPVAL). The test harness calls
`vm.runBytecode(proto, &.{}, &.{}, null)` — passing empty upvalues. But the
compiled bytecode uses globals (`x = {...}`, `return x.a`), which compile to
GETTABUP on upvalue 0 (`_ENV`). With empty upvalues, this is an OOB access.

Fix: each `vm.test.vm` test that compiles source with global access must
provide a `_ENV` upvalue (a Cell pointing to `vm.global_env`).

### Location

`src/lua/vm.zig`, test functions at lines:
- 32064: `test "vm: table constructor and access"`
- 32104: `test "vm: call tostring (one result)"`
- 32143: `test "vm: if statement (NotEq) with _VERSION"`
- 32225: `test "vm: locals swap uses temporaries"`
- 32309: `test "vm: numeric for loop break + scope"`

### Pattern

Each test currently does:
```zig
const ret = try vm.runBytecode(proto, &.{}, &.{}, null);
```

Change to:
```zig
const env_cell = try aalloc.create(Cell);
env_cell.* = .{ .value = .{ .Table = vm.global_env } };
const upvals = [_]*Cell{env_cell};
const ret = try vm.runBytecode(proto, &upvals, &.{}, null);
```

Note: `Cell` has a field `.value` (check the actual struct definition — it may
be `.value` or something else). Check `src/lua/vm.zig` for `const Cell = struct`.

### Acceptance

- `zig build test -Doptimize=Debug`: the 5 `vm` crashes are resolved
  (reduced from 5 crash to 0 crash) ✅
- `python3 tools/testes_matrix.py --testc` — 30/31 (no regressions) ✅
- `python3 tools/smoke_compare.py --no-build` — 49/49 (no regressions) ✅

---

## Task 3: Fix remaining 3 test failures + leaks

### What

After Tasks 1-2, remaining failures are:
- `c_api.test: c api lua_error crosses the setjmp boundary into pcall` (fail)
- `lexer.test: lexer tokenizes global declaration` (fail)
- `ltable.test: nodeInsert returns null when hash part is full` (fail)
- `vm.test: external string: destroyLuaString invokes falloc and frees header only` (1 error)
- 89 leaks (mostly from `undump` and `codegen_bc` tests)

Each failure needs individual investigation. The leaks are likely from test
harness not properly cleaning up VM resources (Proto, Closure, etc.).

### Approach

For each failure:
1. Read the test function
2. Understand what it tests
3. Fix the test or the code it tests
4. Verify the fix

For leaks:
1. Run `zig build test -Doptimize=Debug` after Tasks 1-2
2. Categorize leaks by test file
3. Fix each category (likely missing `vm.deinit()` or Proto cleanup)

### Acceptance

- `zig build test -Doptimize=Debug`: **146/146 pass, 0 fail, 0 crash, 0 leaks**
- `python3 tools/testes_matrix.py --testc` — 30/31 (no regressions)
- `python3 tools/smoke_compare.py --no-build` — 49/49 (no regressions)

---

## Task 4: Final verification + commit

### Steps

1. `zig build test -Doptimize=Debug` — 146/146 pass, 0 leaks
2. `python3 tools/testes_matrix.py --testc` — 30/31
3. `python3 tools/smoke_compare.py --no-build` — 49/49
4. `python3 tools/leak_bench.py --no-build` — 25/25
5. `python3 tools/perf_compare.py` — geomean stable (±2% of 2.68x)
6. Update STATUS.md
7. Commit
