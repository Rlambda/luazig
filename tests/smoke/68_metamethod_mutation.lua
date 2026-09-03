-- T6: differential metamethod mutation smoke (P16.13).
--
-- Byte-identical stdout+exit on ./build/lua-c/lua (PUC 5.5) and
-- ./zig-out/bin/luazig --engine=zig. Proves the VM does NOT cache
-- metamethod lookups for non-fast events (add..close) — dynamic
-- metatable mutation is visible immediately. Also verifies cached-event
-- invalidation (index..eq zone) via Table.flags.
--
-- Covers (per T6 spec):
--   1. present→absent→present __add (anti-cache: f → nil(err) → f)
--   2. absent→present __add (nil → f — negative cache would hide this)
--   3. callable-value swap repeatedly (__call mutation)
--   4. L/R precedence with mutation (swap L mt __add, keep R)
--   5. debug.setmetatable primitive-type mutation (string __add)
--   6. table/userdata mt replacement (whole metatable swap)
--   7. cached-event invalidation (__index/__newindex — the <=.eq zone)
--   8. callable-valued metamethod (__add = table with __call)
--   9. yielding metamethod (yield mid-call, resume completes)
--  10. hooks-enabled path (debug.sethook "cr" around metamethod calls)
--
-- No address-sensitive output. Deterministic.

-- =========================================================================
-- 1. present→absent→present __add (anti-cache proof).
-- =========================================================================
do
  local mt = {}
  mt.__add = function(a, b) return "present" end
  local x = setmetatable({}, mt)
  print("1:add_present", x + 1)
  mt.__add = nil
  local ok1, err1 = pcall(function() return x + 1 end)
  print("1:add_absent_ok", ok1)
  mt.__add = function(a, b) return "present_again" end
  print("1:add_present_again", x + 1)
end

-- =========================================================================
-- 2. absent→present __add (negative cache would hide the transition).
-- If the VM cached "no __add" via flags, the second call would error.
-- =========================================================================
do
  local mt = {}
  local x = setmetatable({}, mt)
  local ok1, err1 = pcall(function() return x + 1 end)
  print("2:absent_ok", ok1)
  mt.__add = function(a, b) return "now_present" end
  print("2:now_present", x + 1)
end

-- =========================================================================
-- 3. callable-value swap repeatedly (__call mutation).
-- =========================================================================
do
  local mt = {}
  mt.__call = function(self, x) return "call_v1:" .. x end
  local obj = setmetatable({}, mt)
  print("3:call_v1", obj(10))
  mt.__call = function(self, x) return "call_v2:" .. x end
  print("3:call_v2", obj(10))
  mt.__call = nil
  local ok = pcall(function() return obj(10) end)
  print("3:call_absent_ok", ok)
  mt.__call = function(self, x) return "call_v3:" .. x end
  print("3:call_v3", obj(10))
end

-- =========================================================================
-- 4. L/R precedence with mutation (swap L mt __add, keep R).
-- =========================================================================
do
  local lmt = { __add = function(a, b) return "L" end }
  local rmt = { __add = function(a, b) return "R" end }
  local l = setmetatable({}, lmt)
  local r = setmetatable({}, rmt)
  print("4:L_wins", l + r)
  lmt.__add = nil
  print("4:R_wins_after_L_nil", l + r)
  lmt.__add = function(a, b) return "L_again" end
  print("4:L_wins_again", l + r)
end

-- =========================================================================
-- 5. debug.setmetatable primitive-type mutation (string __add).
-- PUC allows setting the string metatable via debug.setmetatable.
-- =========================================================================
do
  local saved = debug.getmetatable("")
  local mt = debug.getmetatable("") or {}
  -- Save original __add if any, then set a custom one.
  local orig_add = mt.__add
  mt.__add = function(a, b) return "str_add:" .. a .. "+" .. tostring(b) end
  debug.setmetatable("hello", mt)
  print("5:str_add", "hello" + 1)
  -- Restore: set original mt back (or nil if none).
  if orig_add then
    mt.__add = orig_add
  else
    mt.__add = nil
  end
  debug.setmetatable("hello", mt)
  -- After restore, "hello" + 1 should use the original string mt __add
  -- (which does tonumber coercion). If orig_add was nil, this errors.
  local ok, err = pcall(function() return "hello" + 1 end)
  print("5:str_add_restored_ok", ok)
end

-- =========================================================================
-- 6. table/userdata mt replacement (whole metatable swap).
-- =========================================================================
do
  local mt1 = { __add = function(a, b) return "mt1" end,
                __index = function(t, k) return "idx1_" .. k end }
  local mt2 = { __add = function(a, b) return "mt2" end,
                __index = function(t, k) return "idx2_" .. k end }
  local x = setmetatable({}, mt1)
  print("6:add_mt1", x + 1)
  print("6:idx_mt1", x.foo)
  setmetatable(x, mt2)
  print("6:add_mt2", x + 1)
  print("6:idx_mt2", x.foo)
  setmetatable(x, mt1)
  print("6:add_mt1_again", x + 1)
  print("6:idx_mt1_again", x.foo)
end

-- =========================================================================
-- 7. cached-event invalidation (__index/__newindex — the <=.eq zone).
-- These events ARE cached via Table.flags (fastTm/gfasttm). When the
-- metamethod is set AFTER a miss, the flags bit must be cleared so the
-- new metamethod is visible. PUC does this via invalidation in
-- luaH_set/luaH_remove.
-- =========================================================================
do
  local mt = {}
  local x = setmetatable({}, mt)
  -- __index miss: no __index, so x.foo is nil.
  print("7:idx_miss", x.foo)
  -- Now set __index. The flags bit for __index must be cleared.
  mt.__index = function(t, k) return "idx_" .. k end
  print("7:idx_hit", x.foo)
  -- Remove __index again.
  mt.__index = nil
  print("7:idx_miss2", x.foo)
  -- Set it again.
  mt.__index = function(t, k) return "idx2_" .. k end
  print("7:idx_hit2", x.foo)

  -- Same for __newindex.
  local log = {}
  mt.__newindex = nil
  x.bar = 1  -- goes to the table directly (no __newindex)
  print("7:newidx_direct", x.bar)
  mt.__newindex = function(t, k, v) log[#log+1] = k.."="..v end
  x.baz = 2  -- should call __newindex
  print("7:newidx_log", table.concat(log, ","))
  print("7:newidx_direct_baz", x.baz)  -- baz not set on table (went to __newindex)
  mt.__newindex = nil
  x.qux = 3  -- goes to table directly again
  print("7:newidx_direct_qux", x.qux)
end

-- =========================================================================
-- 8. callable-valued metamethod (__add = table with __call).
-- =========================================================================
do
  local callmt = setmetatable({}, { __call = function(self, a, b) return "callable:" .. type(a) .. "+" .. type(b) end })
  local mt = { __add = callmt }
  local x = setmetatable({}, mt)
  print("8:callable_add", x + 1)
  -- Swap to a different callable.
  local callmt2 = setmetatable({}, { __call = function(self, a, b) return "callable2:" .. type(a) .. "+" .. type(b) end })
  mt.__add = callmt2
  print("8:callable_add2", x + 1)
  -- Swap back to a function.
  mt.__add = function(a, b) return "func_add" end
  print("8:func_add", x + 1)
end

-- =========================================================================
-- 9. yielding metamethod (yield mid-call, resume completes).
-- =========================================================================
do
  local mt = { __add = function(a, b)
    coroutine.yield("yield_val")
    return "add_result"
  end }
  local x = setmetatable({}, mt)
  local co = coroutine.create(function() return x + 1 end)
  print("9:yield1", coroutine.resume(co))
  print("9:yield2", coroutine.resume(co))
end

-- =========================================================================
-- 10. hooks-enabled path (debug.sethook "cr" around metamethod calls).
-- Call/return trace must match PUC byte-wise. Count hooks are NOT used
-- (instruction counts differ between PUC and luazig bytecodes by design).
-- =========================================================================
do
  local mt = { __add = function(a, b) return a end,
               __sub = function(a, b) return a end }
  local x = setmetatable({}, mt)
  local seq = {}
  local n = 0
  local function hook(event)
    n = n + 1
    if n <= 20 then seq[#seq+1] = event end
  end
  debug.sethook(hook, "cr")
  local r1 = x + 1
  local r2 = x - 1
  debug.sethook()
  print("10:seq", table.concat(seq, ","))
  print("10:total", n)
  -- Kind + count summary.
  local counts = {}
  for _, e in ipairs(seq) do counts[e] = (counts[e] or 0) + 1 end
  local kinds = {}
  for k in pairs(counts) do kinds[#kinds+1] = k end
  table.sort(kinds)
  local parts = {}
  for _, k in ipairs(kinds) do parts[#parts+1] = k .. "=" .. counts[k] end
  print("10:summary", table.concat(parts, ","))
end

print("metamethod_mutation_ok")
