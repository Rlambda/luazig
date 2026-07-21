# Regression Report: 28/31 → 25/31 matrix parity

## Breaking commit
**`89a7d70` P15.40b-full: eliminate runtime frame copy push (single addOne)**

Preceding commit `d1f3edd` passes 28/31. Commit `89a7d70` drops to 25/31.

## Failing tests
1. **coroutine.lua** — pcall-in-coroutine with traceback
2. **errors.lua** — `require` becomes table after stack overflow recovery
3. **locals.lua** — `<close>` + xpcall + debug.traceback

## Root cause
`xpcall(func, debug.traceback)` corrupts global state. After xpcall returns,
`print` (and other globals) become wrong values (e.g., `true` — the xpcall
success flag, or a table).

## Minimal reproduction
```lua
local function err_func() error("X") end
local st, msg = xpcall(err_func, debug.traceback)
print("after")  -- ERROR: attempt to call a boolean value (global 'print')
```

`print` has been replaced with `true` after xpcall. The xpcall result write
is corrupting globals.

## Likely culprit in 89a7d70
The commit merged `Vm.call_frames` (runtime copy) into `Thread.call_frames`.
After error recovery + traceback walk, some path writes results to wrong
registers, corrupting globals stored on the bc_stack.

The bug does NOT occur with:
- `xpcall(error, debug.traceback)` (calling error directly)
- `xpcall(func, simple_handler)` (non-traceback handler)
- `pcall(func)` (no xpcall)

Only `xpcall(lua_func, debug.traceback)` where the lua_func errors triggers it.

## Status
Pre-existing from P15.40b-full work (yesterday). My P15.42 (opcode extraction)
and P15.44 (PendingCallSlot shrink) did NOT cause additional regressions.
