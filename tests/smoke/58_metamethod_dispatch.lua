-- Permanent differential metamethod dispatch test (P16.6 Task 7).
--
-- Byte-identical stdout+exit on ./build/lua-c/lua (PUC 5.5) and
-- ./zig-out/bin/luazig --engine=zig. Covers verifier sections A-H:
--   A. left/right __add lookup precedence (both directions)
--   B. dynamic mt mutation (anti-cache): f1 -> f2 -> nil(error) -> f3,
--      for __add AND __sub
--   C. all 12 binary arithmetic/bitwise events firing + flip paths
--      (number on LEFT) for sub/div/idiv/mod
--   D. MMBINI/MMBINK immediates + constant-pool flips; metamethod prints
--      "event:left/right" tags proving operand order + event identity
--   E. MMBINK constant-pool numeric keys + numeric-string coercion
--      (PUC coerces "123" -> 123 in arithmetic)
--   F. unary __unm / __bnot (firing + error without metamethod)
--   G. yielding Lua metamethod (yield mid-call, resume completes) +
--      nested metamethod-on-metamethod
--   H. debug.sethook call/return trace around metamethod calls
--      (event KINDS + counts only; count-mask hooks diverge by design —
--      instruction counts differ between PUC and luazig bytecodes)
--
-- No address-sensitive output: every metamethod returns a string tag or
-- prints type/counter tags. No raw tostring of tables/objects. No GC-timing
-- dependence. Deterministic.

-- =========================================================================
-- Helper: build a table whose metamethods tag themselves with the event and
-- the type of each operand, e.g. "X:add:table,number". This proves both the
-- event identity and the operand order (left/right) in one string.
-- =========================================================================
local function tagged(tag)
  local mt = {}
  for _, ev in ipairs({"add","sub","mul","mod","pow","div","idiv",
                       "band","bor","bxor","shl","shr"}) do
    mt["__"..ev] = function(a, b)
      return tag .. ":" .. ev .. ":" .. type(a) .. "," .. type(b)
    end
  end
  mt.__unm = function(v) return tag .. ":unm:" .. type(v) end
  mt.__bnot = function(v) return tag .. ":bnot:" .. type(v) end
  return setmetatable({}, mt)
end

-- =========================================================================
-- A. Left/right lookup precedence for __add (both directions).
-- PUC tries the LEFT operand's metamethod first (lvm.c luaT_trybinTM).
-- =========================================================================
do
  local lmt = { __add = function() return "L" end }
  local rmt = { __add = function() return "R" end }
  print("A:left_wins",  setmetatable({}, lmt) + setmetatable({}, rmt))
  print("A:left_wins2", setmetatable({}, rmt) + setmetatable({}, lmt))
end

-- =========================================================================
-- B. Dynamic mutation proof (anti-cache): mt.__add = f1 -> f2 -> nil
-- (pcall error) -> f3. All four results in order. Repeated with __sub to
-- cover a different event. Proves the VM does NOT cache the metamethod
-- lookup across calls.
-- =========================================================================
do
  local mt = {}
  local log = {}
  local function f1() log[#log+1] = "f1"; return "r1" end
  local function f2() log[#log+1] = "f2"; return "r2" end
  mt.__add = f1
  local a = setmetatable({}, mt)
  print("B:add1", a + 1)
  mt.__add = f2
  print("B:add2", a + 1)
  mt.__add = nil
  print("B:add3_err", pcall(function() return a + 1 end))
  mt.__add = f1
  print("B:add4", a + 1)
  print("B:add_log", table.concat(log, ","))

  -- Same sequence with __sub.
  local smt = {}
  local slog = {}
  local function s1() slog[#slog+1] = "s1"; return "rs1" end
  local function s2() slog[#slog+1] = "s2"; return "rs2" end
  smt.__sub = s1
  local b = setmetatable({}, smt)
  print("B:sub1", b - 1)
  smt.__sub = s2
  print("B:sub2", b - 1)
  smt.__sub = nil
  print("B:sub3_err", pcall(function() return b - 1 end))
  smt.__sub = s1
  print("B:sub4", b - 1)
  print("B:sub_log", table.concat(slog, ","))
end

-- =========================================================================
-- C. ALL 12 binary events firing. Table operand(s); metamethod returns a
-- distinct tag. Plus flip paths (number on LEFT) for sub/div/idiv/mod —
-- these exercise ADDI/MMBINI/MMBINK flip and prove operand order is
-- preserved (metamethod receives (number, table), NOT swapped).
-- =========================================================================
do
  local x = tagged("X")
  -- 12 events, immediate on the right (table op number).
  print("C:add",  x + 5)
  print("C:sub",  x - 5)
  print("C:mul",  x * 5)
  print("C:mod",  x % 5)
  print("C:pow",  x ^ 5)
  print("C:div",  x / 5)
  print("C:idiv", x // 5)
  print("C:band", x & 5)
  print("C:bor",  x | 5)
  print("C:bxor", x ~ 5)
  print("C:shl",  x << 5)
  print("C:shr",  x >> 5)
  -- Flip paths: number on LEFT for the non-commutative events.
  -- Metamethod must receive (number, table) in source order.
  print("C:sub_flip",  5 - x)
  print("C:div_flip",  5 / x)
  print("C:idiv_flip", 5 // x)
  print("C:mod_flip",  5 % x)
end

-- =========================================================================
-- D. MMBINI / MMBINK tricky paths. Immediate K, K-flip, constant-pool K,
-- and constant-pool K-flip. Metamethod "event:left/right" tags prove both
-- the event identity and the operand order for every path.
-- =========================================================================
do
  local x = tagged("D")
  -- MMBINI: small immediate K (fits in opcode immediate field).
  print("D:ADDI",        x + 5)       -- x + K   (ADDI)
  print("D:SUBI",        x - 5)       -- x - K   (SUBI)
  print("D:SUBI_flip",   5 - x)       -- K - x   (SUBI flip -> __sub(K,x))
  print("D:ADDI_flip",   5 + x)       -- K + x   (ADDI, commutative)
  -- Shifts by immediate, both directions.
  print("D:SHLI",        x << 3)      -- x << K
  print("D:SHLI_flip",   3 << x)      -- K << x  (flip -> __shl(K,x))
  print("D:SHRI",        x >> 3)
  print("D:SHRI_flip",   3 >> x)
  -- MMBINK: constant-pool K (large int / float, not an immediate).
  print("D:ADDK",        x + 1000)
  print("D:SUBK",        x - 1000)
  print("D:SUBK_flip",   1000 - x)
  print("D:MULK",        x * 2.5)
  print("D:MULK_flip",   2.5 * x)
  print("D:ADDK_flip",   2.5 + x)
  print("D:DIVK_flip",   1000 / x)
  print("D:IDIVK_flip",  1000 // x)
  print("D:MODK_flip",   1000 % x)
end

-- =========================================================================
-- E. MMBANK constant-pool numeric keys + numeric-string coercion.
-- PUC coerces numeric strings in arithmetic via the string metatable's
-- __add/__sub/etc. metamethods (lstrlib.c arith_add..arith_unm). The fast
-- path (tonumberns) does NOT coerce strings; failure falls through to MMBIN
-- → getTmByObj(string, event) → string-mt metamethod → tonum → lua_arith.
--
-- Error cases (t+"5", "x"+1, "3"&t, "x"&"y") are now byte-identical vs PUC:
-- arithmetic errors use the two-operand format from trymt
-- ("attempt to add a 'table' with a 'string'"), and bitwise errors use
-- the single-operand format from luaG_opinterror with constant annotation.
-- =========================================================================
do
  -- Numeric K constants (constant pool) with a metamethod: success path.
  local x = tagged("E")
  print("E:ADDK",   x + 1000)
  print("E:MULK",   x * 3.5)
  print("E:POWK",   x ^ 2.0)

  -- Numeric-string coercion (string constant K that is numeric).
  -- PUC coerces via tonumber; result is a plain number.
  print("E:str+num",  "123" + 1)
  print("E:num+str",  1 + "123")
  print("E:str+str",  "123" + "456")
  print("E:str*str",  "2.5" * 4)
  print("E:str-sub",  "100" - "50")
  print("E:str-idiv", "100" // "7")
  print("E:str-mod",  "100" % "7")
  print("E:str-pow",  "2" ^ "10")

  -- Previously-excluded parity gaps (now byte-identical vs PUC):
  -- Arithmetic errors: two-operand format from trymt (lstrlib.c:283).
  local t = {}
  print("E:t+str_err",  pcall(function() return t + "5" end))
  print("E:str+n_err",  pcall(function() return "x" + 1 end))
  print("E:n-str_err",  pcall(function() return 5 - "x" end))
  -- Bitwise errors: single-operand format from luaG_opinterror with
  -- constant annotation. PUC has no __band on the string metatable.
  print("E:str&t_err",  pcall(function() return "3" & t end))
  print("E:str&str_err", pcall(function() return "x" & "y" end))
  print("E:str&n_err",   pcall(function() return "3" & 1 end))
  print("E:t&str_err",   pcall(function() return t & "5" end))
  print("E:bnot_str_err", pcall(function() return ~"5" end))

  -- getmetatable("").__add existence + call (PUC lstrlib.c arith_add).
  local mm = getmetatable("")
  print("E:mm_add_exists", mm.__add ~= nil, type(mm.__add))
  print("E:mm_add_call",   mm.__add("3", "4"))
  print("E:mm_sub_call",   mm.__sub("10", "3"))
  print("E:mm_mul_call",   mm.__mul("3", "4"))
  print("E:mm_div_call",   mm.__div("10", "4"))
  print("E:mm_idiv_call",  mm.__idiv("10", "3"))
  print("E:mm_mod_call",   mm.__mod("10", "3"))
  print("E:mm_pow_call",   mm.__pow("2", "10"))
  print("E:mm_unm_call",   mm.__unm("5"))
  -- Metamethod error: non-numeric string → trymt two-operand error.
  print("E:mm_add_err",    pcall(function() return mm.__add("x", "y") end))
  -- Metamethod delegates to rhs's __add when rhs has one.
  local t2 = setmetatable({}, {__add = function(a, b) return "custom" end})
  print("E:str+t2_mt",     "x" + t2)
end

-- =========================================================================
-- F. Unary: __unm, __bnot (both firing + error case without metamethod).
-- =========================================================================
do
  local u = setmetatable({}, {
    __unm  = function(v) return "neg" end,
    __bnot = function(v) return "bnot" end,
  })
  print("F:unm_bnot", -u, ~u)

  -- Error cases: no metamethod present.
  local t = {}
  print("F:unm_err",  pcall(function() return -t end))
  print("F:bnot_err", pcall(function() return ~t end))

  -- Unary metamethod receives the operand; prove operand type.
  local u2 = setmetatable({}, { __unm  = function(v) return "unm:"  .. type(v) end })
  local u3 = setmetatable({}, { __bnot = function(v) return "bnot:" .. type(v) end })
  print("F:unm_op",  -u2)
  print("F:bnot_op", ~u3)
end

-- =========================================================================
-- G. Yielding Lua metamethod: __add yields mid-call, resume completes,
-- result correct. ALSO nested (metamethod itself does arithmetic that
-- triggers another metamethod), and nested+yield combined.
-- =========================================================================
do
  -- Simple yield mid-metamethod.
  local y = setmetatable({}, { __add = function(a, b)
    coroutine.yield("mid")
    return "y_add"
  end})
  local co = coroutine.create(function() return y + 1 end)
  print("G:yield1", coroutine.resume(co))
  print("G:yield2", coroutine.resume(co))

  -- Nested: metamethod triggers another metamethod (no yield).
  local inner = setmetatable({}, { __add = function(a, b) return "inner" end })
  local outer = setmetatable({}, { __add = function(a, b)
    return inner + b   -- triggers inner's __add
  end})
  print("G:nested", outer + 1)

  -- Nested + yield: outer metamethod calls inner metamethod that yields.
  local innerY = setmetatable({}, { __mul = function(a, b)
    coroutine.yield("inner_yield")
    return "inner_mul"
  end})
  local outerY = setmetatable({}, { __add = function(a, b)
    local r = innerY * b   -- yields!
    return r .. "_outer"
  end})
  local co2 = coroutine.create(function() return outerY + 1 end)
  print("G:nested_yield1", coroutine.resume(co2))
  print("G:nested_yield2", coroutine.resume(co2))
end

-- =========================================================================
-- H. Hooks: debug.sethook with call/return mask around arithmetic
-- metamethod calls. Event trace must match PUC byte-wise.
--
-- The count mask ("") is intentionally NOT used: count hooks fire every N
-- VM instructions, and PUC vs luazig instruction counts differ by design
-- (different bytecode shapes), so count-event traces are not byte-stable.
-- We use the "cr" (call/return) mask only, which is semantically stable.
-- We print the full event sequence (capped) AND a kind+count summary.
-- =========================================================================
do
  local mt = {
    __add = function(a, b) return a end,
    __sub = function(a, b) return a end,
    __mul = function(a, b) return a end,
  }
  local x = setmetatable({}, mt)

  -- Full call/return sequence (capped at 24 events to keep trace short).
  local seq = {}
  local n = 0
  local function hook(event)
    n = n + 1
    if n <= 24 then seq[#seq+1] = event end
  end
  debug.sethook(hook, "cr")
  local r1 = x + 1
  local r2 = x - 1
  local r3 = x * 1
  debug.sethook()
  print("H:seq", table.concat(seq, ","))
  print("H:total", n)

  -- Kind + count summary (stable even if sequence length varies).
  local counts = {}
  for _, e in ipairs(seq) do counts[e] = (counts[e] or 0) + 1 end
  local kinds = {}
  for k in pairs(counts) do kinds[#kinds+1] = k end
  table.sort(kinds)
  local parts = {}
  for _, k in ipairs(kinds) do parts[#parts+1] = k .. "=" .. counts[k] end
  print("H:summary", table.concat(parts, ","))
end

print("metamethod_dispatch_ok")

-- =========================================================================
-- I. P16.7 Task 6: simple_result completion edge cases.
--   I1. metamethod returning no values → nil (value mode)
--   I2. metamethod returning multiple values → first only (value mode)
--   I3. __call-valued metamethod
--   I4. non-callable metamethod error
--   I5. error traceback name "metamethod 'add'"
--   I6. __len returning no values → nil
--   I7. __eq returning no values → false (compare mode)
--   I8. __lt returning no values → false (compare mode)
--   I9. yielding __len metamethod (value mode + yield)
--   I10. yielding __eq metamethod (compare mode + yield)
-- =========================================================================
do
  -- I1: __add returning no values → result is nil.
  local a = setmetatable({}, {__add = function() return end})
  print("I1:add_noret", tostring(a + 1))

  -- I2: __add returning multiple values → caller takes first only.
  local b = setmetatable({}, {__add = function() return 10, 20, 30 end})
  local r1, r2, r3 = b + 1
  print("I2:add_multi", tostring(r1), tostring(r2), tostring(r3))

  -- I3: Ordinary callable table (direct __call, NOT a metamethod field).
  -- Callable non-function metamethod FIELDS are covered in
  -- 64_callable_metamethods.lua (P16.10a Task 10).
  local c = setmetatable({}, {__call = function(self, x) return x * 2 end})
  print("I3:call_mm", c(21))

  -- I4: non-callable metamethod → error.
  local d = setmetatable({}, {__add = 42})
  local ok, err = pcall(function() return d + 1 end)
  print("I4:noncall_ok", ok)
  print("I4:noncall_err", err)

  -- I5: error traceback name "metamethod 'add'".
  local e = setmetatable({}, {__add = function() error("boom") end})
  local ok2, err2 = pcall(function() return e + 1 end)
  print("I5:err_ok", ok2)
  print("I5:err_msg", err2)

  -- I6: __len returning no values → nil.
  local f = setmetatable({}, {__len = function() return end})
  print("I6:len_noret", tostring(#f))

  -- I7: __eq returning no values → false (compare mode).
  local g = setmetatable({}, {__eq = function() return end})
  print("I7:eq_noret", g == g)

  -- I8: __lt returning no values → false (compare mode).
  local h = setmetatable({}, {__lt = function() return end})
  print("I8:lt_noret", h < h)

  -- I9: yielding __len metamethod (value mode + yield).
  local co_len = coroutine.create(function()
    local obj = setmetatable({}, {__len = function()
      coroutine.yield("len_yield")
      return 42
    end})
    return #obj
  end)
  print("I9:len_yield", coroutine.resume(co_len))
  print("I9:len_result", coroutine.resume(co_len))

  -- I10: yielding __eq metamethod (compare mode + yield).
  local co_eq = coroutine.create(function()
    local obj = setmetatable({}, {__eq = function()
      coroutine.yield("eq_yield")
      return true
    end})
    if obj == obj then return "eq_yes" else return "eq_no" end
  end)
  print("I10:eq_yield", coroutine.resume(co_eq))
  print("I10:eq_result", coroutine.resume(co_eq))
end

-- =========================================================================
-- J. P16.8 Task 3: simple_result + yield invariant coverage.
--   J1. Nested yielding metamethod inside a simple_result metamethod:
--       outer __add (simple_result on parent) calls inner __mul that yields.
--       The outer's simple_result state must persist across the inner yield.
--   J2. Debug name after resume: error inside a resumed metamethod must
--       still show "metamethod 'add'" (getDebugName checks hasSimpleResult).
-- =========================================================================
do
  -- J1: outer __add triggers inner __mul which yields.
  -- The outer metamethod is a bytecode child with simple_result set on
  -- its parent. The inner metamethod is a bytecode child with simple_result
  -- set on the OUTER metamethod's frame. When the inner yields, BOTH
  -- simple_result states must persist (on their respective parent frames).
  local innerY = setmetatable({}, { __mul = function(a, b)
    coroutine.yield("inner_mul_yield")
    return "inner_mul_result"
  end})
  local outerY = setmetatable({}, { __add = function(a, b)
    local r = innerY * b   -- triggers inner __mul which yields
    return r .. "_outer_add"
  end})
  local co_j1 = coroutine.create(function() return outerY + 1 end)
  print("J1:yield", coroutine.resume(co_j1))
  print("J1:result", coroutine.resume(co_j1))

  -- J2: Debug name after resume. The metamethod yields, then on resume
  -- raises an error. The traceback must show "metamethod 'add'" — proving
  -- getDebugName still finds the simple_result state after resume.
  local errY = setmetatable({}, { __add = function(a, b)
    coroutine.yield("err_yield")
    error("boom_after_resume")
  end})
  local co_j2 = coroutine.create(function() return errY + 1 end)
  print("J2:yield", coroutine.resume(co_j2))
  local ok_j2, err_j2 = coroutine.resume(co_j2)
  print("J2:ok", ok_j2)
  -- The error message includes the metamethod name in the traceback.
  local err_str = tostring(err_j2)
  print("J2:has_metamethod_name", string.find(err_str, "metamethod") ~= nil)
end
