-- Permanent differential: callable non-function metamethod fields (P16.10a Task 10).
--
-- Byte-identical stdout+exit on lua-5.5.0/src/lua and ./zig-out/bin/luazig.
-- Covers the PUC two-stage metamethod invocation model where a metamethod
-- FIELD's VALUE is a callable non-function (table with __call):
--
--   A. ordinary callable table (the old 58 I3 case, relabeled)
--   B. arithmetic-field-callable (__add is a table with __call)
--   C. yielding callable field (__add table with __call that yields)
--   D. callable __len
--   E. callable __tostring
--   F. callable __eq
--   G. callable __gc
--   H. non-callable errors (3 variants: number as __add, table whose __call
--      is non-callable, 2-level __call chain ending non-callable)
--
-- No address-sensitive output. Deterministic. 3x stability verified.

-- =========================================================================
-- A. Ordinary callable table (not a metamethod field — direct __call).
-- This is the baseline: a table with __call invoked directly.
-- =========================================================================
do
  local c = setmetatable({}, { __call = function(self, x) return x * 2 end })
  print("A:call_mm", c(21))
end

-- =========================================================================
-- B. Arithmetic-field-callable: __add is a table with __call.
-- PUC: luaT_callTMres pushes the table value, luaD_call → tryfuncTM
-- resolves __call, shifts args (self prepended, operands follow).
-- =========================================================================
do
  local mm = setmetatable({}, { __call = function(self, a, b) return 42 end })
  local t = setmetatable({}, { __add = mm })
  print("B:add", t + 1)

  -- Two-level __call chain: mm2's __call is mm1 (another callable table).
  local mm1 = setmetatable({}, { __call = function(self, a, b) return 999 end })
  local mm2 = setmetatable({}, { __call = mm1 })
  local t2 = setmetatable({}, { __add = mm2 })
  print("B:chain", t2 + 1)

  -- Arg semantics: __call(self, a, b) receives the callable OBJECT first,
  -- then the original operands. self is the callable table (mm), a/b are
  -- the original arithmetic operands (t, 10).
  local mm_args = setmetatable({}, { __call = function(self, a, b)
    return self.result
  end})
  mm_args.result = "ARG_OK"
  local ta = setmetatable({}, { __add = mm_args })
  print("B:args", ta + 10)
end

-- =========================================================================
-- C. Yielding callable field: __add table with __call that yields.
-- The callable metamethod must go through the continuation path (not
-- synchronous host-recursion) so the yield properly suspends the
-- coroutine and resume completes with the correct result.
-- =========================================================================
do
  local mm_yield = setmetatable({}, { __call = function(self, a, b)
    coroutine.yield(100)
    return 42
  end})
  local ty = setmetatable({}, { __add = mm_yield })
  local co = coroutine.create(function()
    local r = ty + 1
    print("C:yielded_result", r)
  end)
  print("C:resume1", coroutine.resume(co))
  print("C:resume2", coroutine.resume(co))
end

-- =========================================================================
-- D. Callable __len: the __len field is a table with __call.
-- =========================================================================
do
  local mm_len = setmetatable({}, { __call = function(self) return 7 end })
  local tl = setmetatable({}, { __len = mm_len })
  print("D:len", #tl)
end

-- =========================================================================
-- E. Callable __tostring: the __tostring field is a table with __call.
-- =========================================================================
do
  local mm_ts = setmetatable({}, { __call = function(self) return "CALLABLE_TS" end })
  local tts = setmetatable({}, { __tostring = mm_ts })
  print("E:tostring", tostring(tts))
end

-- =========================================================================
-- F. Callable __eq: the __eq field is a table with __call.
-- =========================================================================
do
  local mm_eq = setmetatable({}, { __call = function(self, a, b) return true end })
  local teq = setmetatable({}, { __eq = mm_eq })
  print("F:eq", teq == teq)
end

-- =========================================================================
-- G. Callable __gc: the __gc field is a table with __call.
-- PUC GCTM resolves __gc at finalization time, then calls through normal
-- call machinery (luaD_pcall → luaD_call → tryfuncTM → __call chain).
-- FINALIZEDBIT lifecycle untouched; callable-table __gc invoked once.
-- =========================================================================
do
  local mm_gc = setmetatable({}, { __call = function(self) print("GCOK") end })
  local tgc = setmetatable({}, { __gc = mm_gc })
  tgc = nil  -- make eligible for GC
end
collectgarbage("collect")
collectgarbage("collect")

-- =========================================================================
-- H. Non-callable errors (3 variants).
-- PUC error text: "attempt to call a number value (metamethod 'add')"
-- for ALL three cases — the error is produced by tryfuncTM → luaG_callerror
-- → luaG_typeerror with the metamethod name from funcnamefromcall.
-- =========================================================================
do
  -- H1: number as __add (directly non-callable).
  local ok1, err1 = pcall(function()
    local tn = setmetatable({}, { __add = 123 })
    return tn + 1
  end)
  print("H1:num_err", ok1, err1)

  -- H2: table whose __call is non-callable (number).
  local ok2, err2 = pcall(function()
    local mm_bad = setmetatable({}, { __call = 456 })
    local tbad = setmetatable({}, { __add = mm_bad })
    return tbad + 1
  end)
  print("H2:badcall_err", ok2, err2)

  -- H3: 2-level __call chain ending in non-callable (number).
  local ok3, err3 = pcall(function()
    local mm_chain1 = setmetatable({}, { __call = 789 })
    local mm_chain2 = setmetatable({}, { __call = mm_chain1 })
    local tchain = setmetatable({}, { __add = mm_chain2 })
    return tchain + 1
  end)
  print("H3:chain_err", ok3, err3)
end

print("callable_metamethods_ok")
