-- Every Lua-controlled bytecode re-entry path uses the Thread-owned explicit
-- dispatch stack: metamethods, debug hooks, yielding __close, and nested
-- coroutine.resume.  This complements the ordinary/protected call coverage in
-- 27_iterative_bytecode_calls.lua and 38_iterative_protected_dispatch.lua.

local function show_resume(co, ...)
  local r = table.pack(coroutine.resume(co, ...))
  print(table.unpack(r, 1, r.n))
end

local function one_yield(op)
  local co = coroutine.create(op)
  show_resume(co)
  show_resume(co, 41)
end

one_yield(function()
  local t = setmetatable({}, {
    __index = function(_, key)
      return coroutine.yield("index", key)
    end,
  })
  return t.answer
end)

one_yield(function()
  local t = setmetatable({}, {
    __newindex = function(self, key, value)
      coroutine.yield("newindex", key, value)
      rawset(self, key, value)
    end,
  })
  t.answer = 42
  return t.answer
end)

one_yield(function()
  local mt = {
    __add = function(a, b)
      return coroutine.yield("add", a.value + b.value)
    end,
  }
  return setmetatable({ value = 20 }, mt) + setmetatable({ value = 22 }, mt)
end)

one_yield(function()
  local mt = {
    __unm = function(a)
      return coroutine.yield("unm", a.value)
    end,
  }
  return -setmetatable({ value = 42 }, mt)
end)

one_yield(function()
  local mt = {
    __len = function(a)
      return coroutine.yield("len", a.value)
    end,
  }
  return #setmetatable({ value = 42 }, mt)
end)

one_yield(function()
  local mt = {
    __concat = function(a, b)
      return coroutine.yield("concat", a.value .. b.value)
    end,
  }
  return setmetatable({ value = "a" }, mt) .. setmetatable({ value = "b" }, mt)
end)

local compare_mt = {
  __eq = function() return coroutine.yield("eq") end,
  __lt = function() return coroutine.yield("lt") end,
  __le = function() return coroutine.yield("le") end,
}
one_yield(function()
  return setmetatable({}, compare_mt) == setmetatable({}, compare_mt)
end)
one_yield(function()
  return setmetatable({}, compare_mt) < setmetatable({}, compare_mt)
end)
one_yield(function()
  return setmetatable({}, compare_mt) <= setmetatable({}, compare_mt)
end)

-- A Lua debug hook is an explicit dispatch child, but debug.sethook itself is
-- a non-yieldable C boundary in PUC Lua.
local hook_trace = {}
local hook_co = coroutine.create(function()
  local x = 1
  x = x + 1
  return x
end)
debug.sethook(hook_co, function(event)
  local function nested(n)
    if n == 0 then return 7 end
    return nested(n - 1) + 1
  end
  hook_trace[#hook_trace + 1] = event .. ":" .. nested(40)
  debug.sethook(hook_co)
end, "l")
show_resume(hook_co)
print(hook_trace[1])

local bad_hook_co = coroutine.create(function()
  debug.sethook(function()
    coroutine.yield("not allowed")
  end, "", 1)
  return 1
end)
local hook_ok, hook_err = coroutine.resume(bad_hook_co)
print(hook_ok, type(hook_err) == "string" and hook_err:find("yield across a C%-call boundary") ~= nil)

-- Yielding __close keeps its scan position and resumes later closers.
local closed = {}
local function closer(name)
  return setmetatable({}, {
    __close = function()
      coroutine.yield("close", name)
      closed[#closed + 1] = name
    end,
  })
end
local close_co = coroutine.create(function()
  local a <close> = closer("a")
  local b <close> = closer("b")
  return "done"
end)
show_resume(close_co)
show_resume(close_co)
show_resume(close_co)
print(table.concat(closed, ","))

-- Keep the differential lane below PUC's native C-stack limit.  The separate
-- stress lane uses thousands of nested resumes under a 1-MB host stack.
local function chain(depth)
  return coroutine.create(function(value)
    if depth == 0 then
      local resumed = coroutine.yield(value)
      return resumed + 1
    end
    local child = chain(depth - 1)
    local ok, child_value = coroutine.resume(child, value + 1)
    assert(ok, child_value)
    local resumed = coroutine.yield(child_value)
    ok, child_value = coroutine.resume(child, resumed)
    assert(ok, child_value)
    return child_value + 1
  end)
end
local root = chain(20)
show_resume(root, 0)
show_resume(root, 1000)

-- `pairs` is a yieldable standard-library wrapper around __pairs. The
-- metamethod must continue after yield rather than replaying the builtin.
local pair_values = {}
local pair_co = coroutine.create(function()
  local t = setmetatable({10, 20, 30}, {
    __pairs = function(self)
      local step = coroutine.yield("pairs")
      return function(state, control)
        if control > 1 then
          local next_control = control - step
          return next_control, state[next_control]
        end
      end, self, #self + 1
    end,
  })
  for _, value in pairs(t) do pair_values[#pair_values + 1] = value end
  return table.concat(pair_values, ",")
end)
show_resume(pair_co)
show_resume(pair_co, 1)

-- Nested pcall/xpcall builtins are peeled into one explicit protected stack;
-- yielding in the innermost Lua target must not restart any outer builtin.
local protected_co = coroutine.create(function()
  return xpcall(pcall, function(err) return "handler:" .. tostring(err) end,
    function()
      local value = coroutine.yield("protected")
      return value + 1
    end)
end)
show_resume(protected_co)
show_resume(protected_co, 41)

-- Resuming an ancestor is a logical error, not a trampoline cycle.
local ancestor
local descendant = coroutine.create(function()
  local ok, err = coroutine.resume(ancestor)
  return ok, type(err) == "string" and err:find("non%-suspended") ~= nil
end)
ancestor = coroutine.create(function()
  return coroutine.resume(descendant)
end)
show_resume(ancestor)

-- A named <close> local also blocks frame-reusing tailcall. The callee must
-- run first; only its completed return allows the caller's close chain to run.
local named_tail_order = {}
local function named_tail_target()
  named_tail_order[#named_tail_order + 1] = "callee"
  return "named-result"
end
local function named_close_tail()
  local value <close> = setmetatable({}, {
    __close = function() named_tail_order[#named_tail_order + 1] = "close" end,
  })
  return named_tail_target()
end
print(named_close_tail(), table.concat(named_tail_order, ","))

-- A generic-for scope owns a hidden TBC slot. A tail-looking return must keep
-- the frame alive until the returned call completes, then close the iterator.
local iterator_closed = false
local function iterator_source()
  return function() return true end, nil, nil,
    setmetatable({}, { __close = function() iterator_closed = true end })
end
local function iterator_tail() return iterator_closed end
local function return_from_iterator()
  for _ in iterator_source() do return iterator_tail() end
end
print(return_from_iterator(), iterator_closed)

-- The yieldable `pairs` bridge must also work when it is the target of a
-- protected builtin; otherwise builtinPcall -> builtinPairs would re-enter
-- runBytecode and replay __pairs after resume.
local protected_pairs_table = setmetatable({}, {
  __pairs = function(self)
    coroutine.yield("protected-pairs")
    return next, self, nil
  end,
})
local protected_pairs_co = coroutine.create(function()
  local packed = table.pack(pcall(pairs, protected_pairs_table))
  return packed.n, packed[1], packed[5] == nil
end)
show_resume(protected_pairs_co)
show_resume(protected_pairs_co)
print(select("#", pairs(setmetatable({}, {
  __pairs = function(self) return next, self, nil end,
}))))
