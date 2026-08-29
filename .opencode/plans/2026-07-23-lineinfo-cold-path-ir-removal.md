# lineinfo cold path + IR executor removal

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** (1) Move per-instruction lineinfo read to hooks-only cold path. (2) Remove the deprecated IR executor (`runFunctionArgsWithUpvalues`) and ALL associated dead code.

**Architecture:** Bytecode-only execution (PUC-faithful). IR pipeline (`codegen.zig` → `ir.zig`) stays as a compilation stage and debug dump tool, but `runFunctionArgsWithUpvalues` (the IR interpreter) is removed. All closures have `proto != null`. `runClosure` always calls `runBytecodeInternal`.

**Parity baseline:** 28/31 matrix, 45/45 smoke. Geomean 3.12× → 3.05×.

---

## Phase 1: lineinfo to cold path

### Task 1: Remove per-instruction lineinfo read from fast path ✅ (commit `9ae3e43`)

- [x] Step 1: Remove fast-path lineinfo write (~line 7713) — delete the `if (ctx.fr.pc < lineinfo.len)` block
- [x] Step 2: Remove GC safepoint lineinfo write (~line 7928)
- [x] Step 3: Add re-derivation to debug.getinfo sites (~lines 18063, 18267)
- [x] Step 4: Add re-derivation to debug.sethook seeding (~line 19773)
- [x] Step 5: Add re-derivation to tracebackFrameLabel (~line 19521)
- [x] Step 6: Add re-derivation to hook dispatch fallback (~line 4955)
- [x] Step 7: Build + smoke + matrix
- [x] Step 8: Perf + commit

---

## Phase 2: IR executor removal

### Task 2: Simplify runClosure — always call runBytecodeInternal ✅ (commit `7a674a6`)

- [x] Remove IR dispatch branch, remove `is_tailcall` parameter
- [x] Update all 35 call sites — remove `is_tailcall` argument

### Task 3: Remove IR fallback branches from bytecode dispatch handlers ✅ (commit `7a674a6`)

- [x] opCall (~10648), opTailcall (~10315), opTforcall (~9824)
- [x] startBytecodePendingCall (~4810), pcall error handler (~6681)

### Task 4: Remove runFunctionArgsWithUpvalues and IR-specific helpers ✅ (commit `7a674a6`)

- [x] Delete runFunctionArgsWithUpvalues (~1000+ lines), runFunction, runFunctionArgs
- [x] Delete ~23 IR-specific helper functions

### Task 5: Remove IrSuspendedFrame and IR-specific Thread/Vm fields ✅ (commit `beec04f`)

- [x] Delete IrSuspendedFrame struct, Thread.ir_suspended_frames, tail_resume_func, etc.
- [x] Delete Vm.call_frames (IR frame stack)
- [x] Simplify debug/traceback paths to only use Thread.call_frames

### Task 6: Remove CallFrame IR-specific fields ✅ (commit `beec04f`)

- [x] Delete locals, local_active from CallFrame (regs and boxed are LIVE — used by bytecode backend)

### Task 7: Remove Closure.func and bc_dummy_func_global ✅ (commit `beec04f`)

- [x] Update ~15 debug/introspection sites to use cl.proto exclusively
- [x] Delete Closure.func, synthetic_env_slot, bc_dummy_func_global

### Task 8: Update compilation entry points ✅ (commit `7a4b546`)

- [x] Remove IR codegen fallback from compileTextChunk
- [x] Update api.zig to use codegen_bc
- [x] Remove .ir backend from luazig.zig
- [x] Update bootstrapTestc, apiWrapFunction, testC load

### Task 9: Update unit tests (~20 tests) ✅ (commit `7a4b546`)

- [x] Switch from codegen + runFunction to codegen_bc + runBytecode

### Task 10: Delete disabled files ✅ (commit `0c4f63d`)

- [x] rm lower_ir.zig, bc_vm.zig
- [x] Clean up root.zig

### Task 11: Full regression + perf + README ✅ (commits `0c4f63d`, `beec04f`)

- [x] Full regression: 28/31 matrix, 45/45 smoke
- [x] Perf: geomean 3.05×
- [x] README updated

---

## Plan complete.

All 11 tasks closed. Net result: ~2200 lines of dead IR code removed, bytecode-only
execution (PUC-faithful), geomean improved from 3.12× to 3.05×.
