-- P16.41 Cut 3: synchronous builtin C-frames are a VIEW over the existing
-- bytecode CALL window (PUC precallC: ci->func points at the caller's
-- callee slot R[A] / R[A+4], never a staged duplicate above the window).
-- Ground truth: PUC ldo.c precallC (func slot in the caller's window),
-- luaD_pretailcall C branch (func moved to the caller's func slot),
-- lvm.c OP_TFORCALL (iterator at R[A+4]).
-- Exercises: arg/result window arithmetic (zero/1/many args; fixed/zero/
-- multi/dynamic results; multret), nested reentrancy, hooks firing on the
-- view frame (incl. reentrant hook bodies), arg errors and RuntimeErrors
-- with location prefixes, pcall recovery, GC finalizer reentry, TBC
-- variables live across builtin calls, tailcall-to-C, TFORCALL-to-C,
-- and testC called from bytecode.

local debug = require("debug")

print("testing builtin C-frame VIEW over the bytecode CALL window")

-- 1. one-arg, fixed-result builtin: result lands in R[A] (dst = a).
do
  assert(math.abs(-5) == 5)
  assert(("ab"):upper() == "AB")
end

-- 2. many-arg builtins: args window R[A+1..A+n] stays intact.
do
  assert(math.max(1, 2, 3, 4, 5, 6, 7) == 7)
  assert(string.format("%d-%s-%d", 5, "x", 9) == "5-x-9")
end

-- 3. zero-arg call: standard missing-argument error (arg window empty).
do
  local ok, msg = pcall(math.abs)
  assert(not ok and msg:find("bad argument #1", 1, true), msg)
end

-- 4. fixed nresults truncation: only the first result is kept.
do
  local a = ("hello"):find("ll")   -- find returns 2 values, nresults = 1
  assert(a == 3)
end

-- 5. zero-result builtin: nothing is written to the destination.
do
  local z = table.insert({}, 1)
  assert(z == nil)
end

-- 6. multi-result builtin into two locals.
do
  local i, j = ("hello"):find("ll")
  assert(i == 3 and j == 4)
end

-- 7. dynamic result count (capture-driven).
do
  local a, b = ("k=v"):match("(%w+)=(%w+)")
  assert(a == "k" and b == "v")
  local c = ("solo"):match("(%w+)")
  assert(c == "solo")
  assert(select('#', ("k=v"):match("(%w+)=(%w+)")) == 2)
  assert(select('#', ("solo"):match("(%w+)")) == 1)
end

-- 8. multret expansion into a table constructor and into call args
--    (multret applies at the last position of a list).
do
  local t = {9, ("hello"):find("ll")}
  assert(#t == 3 and t[1] == 9 and t[2] == 3 and t[3] == 4)
  local u = {9, table.insert({}, 1)}   -- zero results vanish
  assert(#u == 1 and u[1] == 9)
  assert(math.min(("hello"):find("ll")) == 3)
end

-- 9. nested reentrant builtins: a builtin called from a Lua callback
--    that itself runs above another builtin's C-frame (sort).
do
  local t = {5, 2, 8, 1, 9, 3, 7, 4, 6}
  table.sort(t, function(a, b)
    return tonumber(tostring(a)) < tonumber(tostring(b))
  end)
  assert(t[1] == 1 and t[9] == 9)
end

-- 10. plain-C-body builtin with a string replacement (not diverted).
do
  assert(("a-b"):gsub("%a", "X") == "X-X")
  assert(("aXbXc"):gsub("X", "") == "abc")
end

-- 11. arg error carries the Lua caller's location (luaL_where(L,1)).
do
  local line
  local function f()
    line = debug.getinfo(1).currentline + 1  -- the erroring call is next
    return math.abs("x")
  end
  local ok, msg = pcall(f)
  assert(not ok and msg:find("bad argument #1 to 'abs'", 1, true), msg)
  assert(msg:find(":" .. line .. ":", 1, true), msg)
end

-- 12. RuntimeError from a builtin body via pcall.
do
  local ok, msg = pcall(function() return ("x"):rep(math.maxinteger) end)
  assert(not ok and msg:find("too large", 1, true), (msg or ""):sub(1, 60))
end

-- 13. pcall recovery around builtin errors (both call shapes; the
--     argument name is 'abs' from a Lua caller — PUC names it
--     'math.abs' when the caller is C, a documented luazig divergence:
--     the pcall divert has no real C frame, so the name resolves from
--     the Lua caller instead).
do
  local ok1, m1 = pcall(math.abs, "x")
  assert(not ok1 and m1:find("bad argument #1", 1, true), m1)
  local ok2, m2 = pcall(function() return math.abs("x") end)
  assert(not ok2 and m2:find("bad argument #1 to 'abs'", 1, true), m2)
  -- stack stays consistent after recovery: a later builtin call works.
  assert(math.abs(-1) == 1)
end

-- 14. GC finalizer reentry: a builtin call from a Lua __gc body that
--     runs while collector machinery is on the stack.
do
  local log = {}
  do
    local obj = setmetatable({}, {__gc = function()
      log[#log + 1] = tostring(math.abs(-42))
    end})
    assert(obj ~= nil)
  end
  collectgarbage("collect")
  collectgarbage("collect")
  assert(log[1] == "42", "finalizer's builtin call produced its result")
end

-- 15. call hook fires ON the view C-frame: from inside the hook, the
--     hooked builtin is at level 2 (0 = the getinfo call itself,
--     1 = the hook function, 2 = the hooked C function) and .func is
--     the real callee object at the view slot.
do
  local abs_func
  debug.sethook(function()
    local i = debug.getinfo(2)
    if i and i.what == "C" and i.name == "abs" then
      abs_func = i.func
    end
  end, "c")
  local y = math.abs(-3)
  debug.sethook()
  assert(y == 3)
  assert(abs_func == math.abs,
    "getinfo.func on the C frame is the callee at the view slot")
end

-- 16. reentrant hook body: while the hook fires on sort's C-frame, the
--     hook body itself calls builtins and runs a nested sort.
do
  local acc = {}
  local nested = false
  debug.sethook(function()
    local i = debug.getinfo(2)
    if i and i.what == "C" and i.name == "sort" and not nested then
      nested = true
      acc[#acc + 1] = ("h"):rep(3)
      local t = {9, 7, 8}
      table.sort(t, function(a, b) return a < b end)
      acc[#acc + 1] = (t[1] == 7)
    end
  end, "c")
  local t = {3, 1, 2}
  table.sort(t, function(a, b) return a < b end)
  debug.sethook()
  assert(t[1] == 1 and t[2] == 2 and t[3] == 3)
  assert(acc[1] == "hhh" and acc[2] == true)
end

-- 17. to-be-closed variable live across a builtin call; a builtin result
--     becomes the TBC value itself.
do
  local closed = false
  local function f()
    local x <close> = setmetatable({}, {__close = function() closed = true end})
    local t = {3, 1, 2}
    table.sort(t, function(a, b) return a < b end)
    return t[1]
  end
  assert(f() == 1)
  assert(closed, "TBC closed after the function returned")
end

-- 18. tailcall-to-C: OP_TAILCALL to a builtin views the callee at R[A];
--     results become the caller's return values; errors carry location.
--     (The arg-error text itself differs in luazig's string library —
--     documented divergence — so only the raise/catch/location prefix
--     are asserted here.)
do
  local function tailabs(x) return math.abs(x) end
  assert(tailabs(-7) == 7)
  local line
  local function tailerr(x)
    line = debug.getinfo(1).currentline + 1  -- the erroring call is next
    return ("x"):rep(x)
  end
  local ok, msg = pcall(tailerr, "bad")
  assert(not ok, msg)
  assert(msg:find(":" .. line .. ":", 1, true), msg)
end

-- 19. TFORCALL to a C iterator: the view frame sits at R[A+4] for every
--     iteration; a call hook observes the iterator's C frame.
do
  local n = 0
  for k in next, {10, 20, 30} do n = n + 1 end
  assert(n == 3)
  local saw_next = false
  debug.sethook(function()
    local i = debug.getinfo(2)
    -- PUC funcnamefromcall names a C callee reached via OP_TFORCALL
    -- "for iterator"; luazig resolves the builtin's global name "next"
    -- (documented pre-existing divergence — the frame itself is what
    -- matters here: a C frame at level 2 during each iteration).
    if i and i.what == "C" and (i.name == "for iterator" or i.name == "next") then
      saw_next = true
    end
  end, "c")
  for k in next, {10} do end
  debug.sethook()
  assert(saw_next, "call hook observed the next C frame via TFORCALL")
end

-- 19b. GC atomic step DURING the sync hook body over the TFORCALL window
--      (P16.42): gcClearDeadFrameRegisters nils "dead" registers of the
--      parked caller (>= live_reg_top[pc]) once per cycle; the TFORCALL
--      window R[A+4..A+6] sits above the parked pc's compile-time
--      liveness, so a child-frame guard that ignores C view frames let
--      the clear wipe the staged state mid-call (next received nil).
--      Deterministic regression: hammer the cycle so an atomic step
--      inevitably fires inside a hook body's getinfo allocation while
--      the iterator window is live.
do
  collectgarbage("collect")  -- fresh cycle; subsequent allocations re-arm it
  for round = 1, 50 do
    local t = {}
    for j = 1, 3 do t[j] = j end
    local sum = 0
    debug.sethook(function()
      local i = debug.getinfo(2)  -- allocates the info table (GC step site)
      if i and i.what == "C" and (i.name == "for iterator" or i.name == "next") then
        sum = sum + 1
      end
    end, "c")
    for k in next, t do sum = sum + k * 1000 end
    debug.sethook()
    -- t = {1,2,3}: keys 1..3 -> 6000; 4 iterator calls (last returns nil)
    assert(sum == 6004, "round " .. round .. ": iterator state survived")
  end
end

-- 20. testC called from bytecode (its C-frame machinery above the view
--     model) and from inside a sort comparator.
do
  local T = T
  if T == nil then T = select(2, pcall(require, "testc")) end
  if T and type(T) == "table" then
    local x, y = T.testC("return 2", 10, 20)
    assert(x == 10 and y == 20)
    local t = {2, 1}
    table.sort(t, function(a, b)
      return T.testC("return 1", a) < b
    end)
    assert(t[1] == 1 and t[2] == 2)
  end
end

print("OK")
