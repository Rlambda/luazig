-- 78_table_sort_yieldability.lua — P16.37 Cut 1: every table.sort
-- comparator invocation runs under a non-yieldable C-call boundary
-- (PUC ltablib.c sort_comp → lua_call → luaD_callnoyield → ccall(nyci):
-- nCcalls += inc BEFORE luaD_precall, so the comparator's CALL hook fires
-- inside the window; nCcalls -= inc on return). A yield attempt inside
-- the comparator — closure, nested helper, or a builtin coroutine.yield
-- passed directly — fails AT THE YIELD SITE with "attempt to yield across
-- a C-call boundary"; comparator errors propagate UNWRAPPED (PUC's
-- "invalid order function for sorting" comes only from the partition
-- invariant, never from sort_comp). Replaces the old
-- id == .coroutine_yield comparator special cases.
--
-- Differential smoke: byte-identical output expected under PUC Lua 5.5
-- and luazig. Comparator CALL COUNTS are implementation-defined (PUC
-- auxsort and luazig quicksort compare different pairs), so every
-- per-comparator print is latched to its first occurrence.

-- T0: plain sort sanity (no comparator) — unaffected by the boundary.
local t0 = {5,3,1,4,2}
table.sort(t0)
print("T0", table.concat(t0, ","))

-- T1: closure comparator yielding directly — REJECTED; the coroutine
-- dies with the boundary error (bare message: the yield's own C-frame
-- is on top, like PUC's luaB_yield frame).
local co1 = coroutine.create(function()
  table.sort({2,1}, function(a,b)
    coroutine.yield("must-not-suspend")
    return a < b
  end)
end)
print("T1", coroutine.resume(co1))
print("T1-status", coroutine.status(co1))

-- T1b: same, pcall-wrapped at the sort call — an ordinary catchable
-- runtime error; the unit is reclaimed and a later yield works.
local co1b = coroutine.create(function()
  local ok, err = pcall(table.sort, {2,1}, function(a,b)
    coroutine.yield("must-not-suspend")
    return a < b
  end)
  print("T1b-sort", ok, err)
  print("T1b-isyieldable", coroutine.isyieldable())
  coroutine.yield("T1b-after")
end)
print("T1b-r1", coroutine.resume(co1b))
print("T1b-r2", coroutine.resume(co1b))

-- T2: yield via a nested helper function inside the comparator.
local co2 = coroutine.create(function()
  local function helper() coroutine.yield("must-not-suspend") end
  local ok, err = pcall(table.sort, {2,1}, function(a,b)
    helper()
    return a < b
  end)
  print("T2-inner", ok, err)
end)
print("T2", coroutine.resume(co2))

-- T3: nested pcall(function() yield() end) INSIDE the comparator — the
-- inner pcall CATCHES the boundary error; the comparator returns
-- normally and the sort completes.
local printed3 = false
local co3 = coroutine.create(function()
  table.sort({3,1,2}, function(a,b)
    local ok, err = pcall(coroutine.yield)
    if not printed3 then
      printed3 = true
      print("T3-inner", ok, err)
    end
    return a < b
  end)
  coroutine.yield("T3-done")
end)
print("T3-r1", coroutine.resume(co3))
print("T3-r2", coroutine.resume(co3))

-- T4: builtin comparator (coroutine.yield passed directly) — the same
-- boundary error, unwrapped (the old code re-wrapped builtin comparator
-- errors as "invalid order function for sorting ('...')").
local co4 = coroutine.create(function()
  table.sort({2,1}, coroutine.yield)
end)
print("T4", coroutine.resume(co4))
print("T4-status", coroutine.status(co4))

-- T5: callable __call table comparator — REJECTED at sort entry
-- (PUC luaL_checktype(L, 2, LUA_TFUNCTION): raw type tag, before any
-- __call resolution; same rule as xpcall's handler check).
local co5 = coroutine.create(function()
  table.sort({2,1}, setmetatable({}, {__call = function(self,a,b) return a < b end}))
end)
print("T5", coroutine.resume(co5))

-- T6: coroutine.isyieldable() is false inside the comparator window.
local printed6 = false
local co6 = coroutine.create(function()
  table.sort({3,1,2}, function(a,b)
    if not printed6 then
      printed6 = true
      print("T6-isyieldable", coroutine.isyieldable())
    end
    return a < b
  end)
  coroutine.yield("T6-after")
end)
print("T6-r1", coroutine.resume(co6))
print("T6-r2", coroutine.resume(co6))

-- T7: unit released on normal return — isyieldable true right after a
-- successful sort, and an ordinary yield works.
local co7 = coroutine.create(function()
  local t = {3,1,2}
  table.sort(t, function(a,b) return a < b end)
  print("T7-sorted", table.concat(t, ","))
  print("T7-isyieldable", coroutine.isyieldable())
  coroutine.yield("T7-after")
end)
print("T7-r1", coroutine.resume(co7))
print("T7-r2", coroutine.resume(co7))

-- T8: unit released on comparator error — pcall catches the comparator's
-- own error (propagated unwrapped, with the comparator's position), and
-- a later yield works.
local co8 = coroutine.create(function()
  local ok, err = pcall(table.sort, {3,1,2}, function(a,b)
    error("cmp-boom")
  end)
  print("T8-sort", ok, err)
  print("T8-isyieldable", coroutine.isyieldable())
  coroutine.yield("T8-after")
end)
print("T8-r1", coroutine.resume(co8))
print("T8-r2", coroutine.resume(co8))

-- T9: invalid-order failure — position semantics follow luaL_where(1):
-- present when sort is called directly from Lua, absent when the caller
-- is a C function (pcall). Unit released either way.
local co9 = coroutine.create(function()
  table.sort({1,2,3,4}, function(a,b) return true end)
end)
print("T9-direct", coroutine.resume(co9))
print("T9-pcall", pcall(table.sort, {1,2,3,4}, function(a,b) return true end))
local co9b = coroutine.create(function()
  local ok, err = pcall(table.sort, {1,2,3,4}, function(a,b) return true end)
  print("T9b-sort", ok, err)
  coroutine.yield("T9b-after")
end)
print("T9b-r1", coroutine.resume(co9b))
print("T9b-r2", coroutine.resume(co9b))

-- T10: nested sorts accumulate nny units — an inner sort inside a
-- comparator completes; isyieldable stays false in BOTH comparator
-- windows (latched prints).
local printed10inner = false
local printed10outer = false
local co10 = coroutine.create(function()
  local inner = {5,3,4,1,2}
  local ok, err = pcall(table.sort, {2,1}, function(a,b)
    table.sort(inner, function(x,y)
      if not printed10inner then
        printed10inner = true
        print("T10-inner-isyieldable", coroutine.isyieldable())
      end
      return x < y
    end)
    if not printed10outer then
      printed10outer = true
      print("T10-outer-isyieldable", coroutine.isyieldable())
    end
    return a < b
  end)
  print("T10-sort", ok, err)
  print("T10-inner-sorted", table.concat(inner, ","))
  coroutine.yield("T10-after")
end)
print("T10-r1", coroutine.resume(co10))
print("T10-r2", coroutine.resume(co10))

-- NOT covered here (known pre-existing trampoline bug, backlog — see
-- STATUS.md "P16.37 backlog"): a comparator that RESUMES another
-- coroutine while the coroutine trampoline is active (coroutine →
-- table.sort comparator → coroutine.resume(inner)). The trampoline
-- switch request unwinds through builtinTableSort's Zig-stack sort
-- state and fails with "coroutine trampoline lost continuation".
-- Reproducer: /tmp/opencode/p37_t12_min.lua; crashes identically on
-- the pre-P16.37 binary (systemic: any Lua nested under a builtin via
-- runClosure, not sort-specific). The nny unit itself is per-thread
-- and does not affect the resumed coroutine's own yieldability.
