# Inline + dedup: reduce function-call overhead in lua_calls

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce per-call overhead in the bytecode VM dispatch loop. `lua_calls` is 4.06× slower than PUC Lua. Root cause: ~10 non-inlined function calls per call/return cycle (PUC does 1), plus redundant work.

**Architecture:** Bytecode-only execution (PUC-faithful). All optimizations are inline/dedup — no new structs, no new codepaths. Just helping Zig's compiler match what C compilers do automatically with PUC Lua's `l_sinline` macros.

**Parity baseline:** 28/31 matrix, 45/45 smoke. Geomean 2.96×.

**Key finding from analysis:** `BytecodePendingCall` is already 48 bytes (NOT 760 — P15.44 already moved large variants to heap). The "760 bytes" comments in the source are stale and must be corrected.

---

## Task 1: Remove duplicate `ensureBcStackCap` call

`opCall` calls `ensureBcStackCap` at line ~8934, then `pushBytecodeExecFrame` calls it again at line ~5506 with the same argument. Remove the call inside `pushBytecodeExecFrame` for the `opCall` path — `opCall` already checked.

- [ ] Read `pushBytecodeExecFrame` (~line 5467) and `opCall` (~line 8852) to confirm both call `ensureBcStackCap` with the same argument
- [ ] Remove the `ensureBcStackCap` call from `pushBytecodeExecFrame`
- [ ] Verify ALL other callers of `pushBytecodeExecFrame` (metamethod dispatch, coroutine resume, etc.) still call `ensureBcStackCap` themselves before calling `pushBytecodeExecFrame` — if not, add it there
- [ ] Build + smoke test

## Task 2: Remove duplicate stack-overflow check

`pushBytecodeExecFrame` has TWO stack-overflow checks (~lines 5488 and 5502) with the same operands when `nextra == 0`. Keep one, remove the other.

- [ ] Read lines ~5485–5510 in `pushBytecodeExecFrame`
- [ ] Merge the two checks into one: `if (exec_frames.len() >= lua_max_call_frames or total_needed > lua_max_stack_slots -| self.bc_stack_top) return self.fail(...)`
- [ ] Build + smoke test

## Task 3: Gate debug-only field writes behind hooks check

`pushBytecodeExecFrame` writes 12 debug-only fields at lines ~5588–5599 on every call: `env_override`, `resume_skip_count_pc`, `hide_from_debug`, `debug_namewhat`, `debug_name`, `is_debug_hook`, `debug_hook_transfer`, `debug_hook_transfer_start`, `debug_hook_event_calllike`, `debug_hook_event_tailcall`, `debug_hook_event_is_count`, `debug_hook_allow_yield`.

These fields are only read when hooks are active or during debug introspection. When `hooks_active_cached == false` (the common case), skip writing them.

- [ ] Read lines ~5585–5600 to see the debug field writes
- [ ] Wrap the 12 debug field writes in `if (self.hooks_active_cached) { ... }`
- [ ] Verify the fields have safe defaults (zero/null/false) that won't cause issues if not reset on frame reuse — check if stale values could leak. If they can, the fields must still be written on first use of each CallFrame slot. Alternative: write them unconditionally but only in the hook-activation path
- [ ] Build + smoke + matrix test

## Task 4: Mark `resolveProtoConstants` as inline

Fast path is `if (proto.constants_resolved) return;` — one bool check. The function is small enough to inline.

- [ ] Change `fn resolveProtoConstants` to `inline fn resolveProtoConstants`
- [ ] Build + smoke test

## Task 5: Mark `popBytecodeExecFrame` as inline

Small function: restore `bc_stack_top`, `tbc_mark`, decrement `inline_count`.

- [ ] Change `fn popBytecodeExecFrame` to `inline fn popBytecodeExecFrame`
- [ ] Verify the function body is small enough to not bloat the dispatch loop
- [ ] Build + smoke test

## Task 6: Skip `closeBytecodeUpvaluesFrom` when no open upvalues

Currently scans all `boxed[0..frame_cap]` (7+ slots) on every return. PUC uses a linked list of open upvalues — O(0) when empty.

Option A (simpler): Add `has_open_upvalues: bool` field to CallFrame. Set to `false` in `pushBytecodeExecFrame`. Set to `true` whenever an upvalue is opened (find the site that writes to `boxed[i]`). In `completeBytecodeExecFrame`, skip `closeBytecodeUpvaluesFrom` when `frame.has_open_upvalues == false`.

Option B (PUC-faithful): Track open upvalues as a linked list per frame, like PUC's `luaF_close`.

Start with Option A (simpler, captures most of the benefit).

- [ ] Add `has_open_upvalues: bool = false` to CallFrame struct
- [ ] Set it to `true` wherever upvalues are opened (search for writes to `boxed[i]` or `openUpvalue` calls)
- [ ] Gate `closeBytecodeUpvaluesFrom` behind `if (frame.has_open_upvalues)` in `completeBytecodeExecFrame` and `opReturn0`/`opReturn1`/`opReturn`
- [ ] Build + smoke + matrix test

## Task 7: Fix stale "760 bytes" comments

Three comments reference the old pre-P15.44 size of `BytecodePendingCall` (760 bytes). The actual size is now 48 bytes.

- [ ] Read vm.zig:~705 — comment about `BytecodePendingCall is 760 bytes`
- [ ] Read vm.zig:~712 — comment about `the payload (760 bytes, cold)`
- [ ] Read vm.zig:~738 — comment about `copying the 760-byte payload`
- [ ] Update all three to reflect the current 48-byte size and note that P15.44 moved large variants to heap pointers
- [ ] Build (comments only, no test needed)

## Task 8: Full regression + perf + README

- [ ] Build ReleaseFast
- [ ] Run all smoke tests: `for f in tests/smoke/*.lua; do timeout 10 ./zig-out/bin/luazig --vm=bc "$f" >/dev/null 2>&1 || echo "FAIL: $f"; done`
- [ ] Run matrix: `python3 tools/testes_matrix.py --timeout 120` — expect 28/31
- [ ] Run perf: `python3 tools/perf_compare.py --runs 7 --core 0`
- [ ] Compare lua_calls and geomean to baseline (2.96×)
- [ ] Update baseline if improved
- [ ] Commit all changes
- [ ] Update README with optimization details
