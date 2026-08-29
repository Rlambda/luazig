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
-- E. MMBINK constant-pool numeric keys + numeric-string coercion.
-- PUC coerces numeric strings in arithmetic (tonumber path in lvm.c
-- arith). "123" + 1 == 124. This is the STRING-constant success path
-- through MMBINK (string K that IS numeric).
--
-- NOTE: the string-constant ERROR path (e.g. t + "hello" where t has no
-- metamethod) currently DIVERGES: PUC 5.5 emits
--   "attempt to add a 'table' with a 'string'"
-- while luazig emits
--   "attempt to perform arithmetic on a table value (upvalue 't')".
-- Bitwise ops on strings also diverge (PUC rejects even numeric strings
-- for bitwise; luazig's message + traceback differ). Those divergent
-- cases are intentionally excluded to keep this differential test
-- byte-identical; they are tracked as a parity gap.
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
