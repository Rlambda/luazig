# P15.79 — Coroutine Yield/Close Parity with PUC Lua

## Objective

Achieve full parity with PUC Lua 5.5 for coroutine yield/close semantics,
specifically:

1. `coroutine.yield` across builtin C-frames (pcall, dofile)
2. `coroutine.close` with pcall + TBC `__close` metamethods
3. Error location (source:line prefix) for C-function vs Lua-function errors
4. ThreadSwitch (nested coroutine.resume inside trampoline)

## Background

P15.79 started as a fix for `runClosure` ownership contract
(`completeBytecodeExecFrame` C-parent branch inverted). It expanded to cover
all coroutine yield/close parity issues found during review.

## Completed Work

### 1. runClosure ownership contract (commit `fac2ef4`)

**Root cause:** `completeBytecodeExecFrame`'s C-parent branch had inverted
ownership logic. When a Lua function returned into a C-frame, the branch
returned `bc_return_scratch` (a VM-owned static array) directly, instead of
duplicating it. Consumers doing `alloc.free(ret)` would corrupt the allocator.

**Fix:** Invert the C-parent branch to match the external-boundary branch:
if `returnSliceIsOwned(ret)` is true (scratch), duplicate to heap-owned.

**Test:** `tests/smoke/51_pcall_cframe_ownership.lua`

### 2. pcall C-frame CIST_YPCALL + funcidx + OAH (commit `ccce14b`)

**Root cause:** `builtinPcall` did not save PUC recovery state (funcidx, OAH,
old_errfunc) on the pcall C-frame. When a coroutine yielded across pcall and
then errored on resume, `finishpcallk` had no recovery state to use.

**Fix:** Mark the pcall C-frame with CIST_YPCALL and save:
- `old_errfunc` — restored on error recovery
- `aux.funcidx` — callee stack position for error object placement
- `callstatus` OAH bits — saved allowhook, restored by finishpcallk

### 3. Remove testC string normalization + heuristics (commit `4abf708`)

**Root cause:** Three workarounds masked the real bug in error location:
1. `normalizeTestcErrorForHandler` — stripped source:line prefix from errors
2. `protectedErrorValue` heuristic — added source prefix at pcall recovery
3. `caller_builtin_id` workaround — skipped source prefix for C-function callers

**Fix:** Remove all three. Add `isTestcCFrame` to `errorLocationFrameIndex`
to correctly count testC C-frames. Add `fail()` (bakes source prefix at error
creation) and `failLib()` (luaL_error, no source prefix).

### 4. coroutine.close with pcall + TBC __close error (commit `bc2c62e`)

**Root cause:** `coroutine.close` used `appendBytecodeUnwind` which calls
`bytecodeUnwindDisposition` that stops at CIST_YPCALL frames. This preserved
the pcall C-frame, causing `__close` errors to be caught by pcall instead of
propagating. PUC's `lua_resetthread` discards ALL frames (including pcall)
before `luaF_close`.

**Fix:** Use `appendBytecodeForcedCloseUnwind` (target_depth = boundary_depth,
no CIST_YPCALL stop).

### 5. Forced close error propagation (this commit)

**Root cause:** When multiple `__close` metamethods error during
`coroutine.close`, the last error should propagate. But the re-entrant forced
close path in `runBytecodeDispatch`'s error handler cleared the error when
`shouldRethrowForcedCloseFromBytecode()` returned true (after all __close
children were released, `bytecode_close_metamethod_depth == 0`).

**Fix:** If `forced_close_had_error` is true, skip the re-entrant forced
close (all TBC slots already processed by `continueBytecodeErrorUnwind` →
`close_parent` → `continueBytecodeClose`). Just return `error.RuntimeError`
with the current error state (the last __close error).

### 6. CIST_CLSRET

**Finding:** `setClsret()` is defined but never called. testC handles TBC
close via `testcContShim` (pushed BEFORE closers). No other C API function in
luazig uses `lua_toclose`. The hard-fail in `finishCcall` on CIST_CLSRET is
dead code / safety check — retained as invariant guard.

### 7. luaF_close in finishpcallk

**Finding:** TBC close on error is handled by `continueBytecodeErrorUnwind`
during forced close. `precover` pops frames after TBC close. No separate
`luaF_close` needed in `finishpcallk`.

### 8. pcall/dofile semantics in builtinCoroutineResume

**Finding:** The inline pcall/dofile formatting in `builtinCoroutineResume`'s
`.Builtin` branch is correct and necessary for `coroutine.create(pcall)`
(builtin callee). The `.Closure` branch uses the trampoline +
`tryPushBytecodeProtectedCall` (no pcall C-frame). Both paths are PUC-faithful.

Two distinct code paths:
- `coroutine.create(function() pcall(foo) end)` (Closure callee):
  `tryPushBytecodeProtectedCall` intercepts pcall — no pcall C-frame.
  PendingCallSlot wraps results as `[true, ...ret]`.
- `coroutine.create(pcall)` (Builtin callee):
  pcall C-frame IS pushed. `.Builtin` branch resumes top Lua frame directly.
  On return, checks `is_ypcall` → formats as `[true, ...ret]` or
  `[false, error]`.

## Tests

- `tests/smoke/52_threadswitch_nested_coroutine.lua` — ThreadSwitch paths
- `tests/smoke/53_p15_79_regression.lua` — P15.79 regression tests

## Results

- Matrix: 30/32 (coroutine.lua `--testc` hang pre-existing, big.lua both_fail
  pre-existing)
- Smoke: 53/53
- PUC Lua differential: all tests match PUC exactly

## Architecture Notes

### PUC-faithful design

- `builtinPcall` sets CIST_YPCALL + saves funcidx/OAH/old_errfunc on the
  C-frame, mirroring PUC's `lua_pcallk`.
- `finishpcallk` reads saved state to restore errfunc and allowhook,
  mirroring PUC's `finishpcallk` (ldo.c:804-821).
- `precover` finds the innermost CIST_YPCALL frame and saves the error
  status, mirroring PUC's `precover` (ldo.c:955-963).
- `coroutine.close` uses `appendBytecodeForcedCloseUnwind` (no CIST_YPCALL
  stop), mirroring PUC's `lua_resetthread` which discards ALL frames.
- Error source:line prefix is baked at error creation time by `fail()`,
  mirroring PUC's `luaG_addinfo`. C-function errors use `failC()`/`failLib()`
  (no prefix), mirroring PUC's `luaG_runerror` skipping `luaG_addinfo` for
  C functions.

### Zig-native implementation

- C-frames are `CallFrame` structs with `u.c` union (not PUC's `CallInfo`
  struct with bitfields)
- `bytecode_close_metamethod_depth` tracks __close metamethod depth (not
  PUC's `L->nCcalls`)
- `forced_close_had_error` flag on Vm (not PUC's `L->status`)
- `bytecode_unwinds` array on Thread (not PUC's `longjmp`-based unwinding)
