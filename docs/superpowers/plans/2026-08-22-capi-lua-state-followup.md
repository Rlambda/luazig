# C-API / lua_State follow-up plan (out of the 2026-08-15 C-continuations scope)

> **STATUS: OPEN** — carved out of the C-continuations plan (P15.83s scope
> decision, third review item 4). These are real, documented deviations of
> the general C API / lua_State abstraction. They are NOT blockers for the
> C-continuations plan (continuation semantics, resume boundary exposure,
> hooks, TBC, errfunc/ERRERR are all PUC-parity-verified there), but the
> lua_State abstraction must not be called "full C API parity" until the
> items below are closed.

PUC Lua 5.5.0 vendored in this repository is the oracle.

## Items

- [ ] **lua_tothread for Lua-created coroutines** returns NULL today (no C
  handle exists for threads created by `coroutine.create`/`wrap`). PUC
  returns the `lua_State*` for ANY thread value. Fix direction: give every
  Thread a lazily-created api_handle (weak or strong ref decision needed)
  so the reverse mapping works both ways.
- [ ] **Fresh-main-state resume**: resuming the MAIN state as a coroutine
  (`lua_resume(L_main, ...)`, PUC's "using a main thread as a coroutine"
  — see coroutine.lua T.newstate section) is unsupported in luazig (the
  main thread is not resumable). Requires base_ci-level call semantics for
  the main thread. Zero upstream coverage outside ltests `doremote`.
- [ ] **Divert-bound builtins CALL-hook identity** (from P15.83r): pcall
  fast-path, resume/wrap, gsub, `__pairs` builtins keep caller identity in
  the CALL hook because an intermediate C-frame misroutes the `parent.isC()`
  return routing. Architectural: divert protocol needs a C-frame-aware
  return path.
- [ ] Audit remaining C API surface for stale `lua_State == Vm` assumptions
  (grep-driven): anything resolving threads via Vm-level singletons instead
  of the handle.

## Gates
Each item lands with a differential test (PUC vs zig, byte-identical) in
tests/c_api/ (extend 14_state_handles.c or a new suite) + the full standard
gate (c_api test/test-diff, matrix --testc, smoke_compare, leak_bench,
zig build test Debug+RF).
