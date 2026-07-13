local call_depth = tonumber(arg[1]) or 5000
local coroutine_depth = tonumber(arg[2]) or 3000
local metamethod_depth = tonumber(arg[3]) or 2000
local gsub_depth = tonumber(arg[4]) or 1000

local function recurse(n)
  if n == 0 then return 0 end
  return recurse(n - 1) + 1
end
assert(recurse(call_depth) == call_depth)

local recursive_index_mt = {}
recursive_index_mt.__index = function(self, key)
  if self.depth == 0 then return 0 end
  return setmetatable({ depth = self.depth - 1 }, recursive_index_mt)[key] + 1
end
assert(setmetatable({ depth = metamethod_depth }, recursive_index_mt).value == metamethod_depth)

-- string.gsub is a non-yieldable C-library boundary, but its Lua
-- replacement callback still has to run on the explicit bytecode frame stack.
-- This used to recursively enter runBytecode and overflow a 1-MB host stack.
local gsub_calls = 0
local function recursive_gsub_replacement()
  gsub_calls = gsub_calls + 1
  if gsub_calls < gsub_depth then
    assert(string.gsub("a", ".", recursive_gsub_replacement) == "a")
  end
  return "a"
end
assert(string.gsub("a", ".", recursive_gsub_replacement) == "a")
assert(gsub_calls == gsub_depth)

local yield_probe = coroutine.create(function()
  return string.gsub("a", ".", function()
    assert(not coroutine.isyieldable())
    coroutine.yield("must not cross gsub")
  end)
end)
local yield_ok, yield_err = coroutine.resume(yield_probe)
assert(not yield_ok and tostring(yield_err):find("C%-call boundary"), yield_err)

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

local root = chain(coroutine_depth)
local ok, value = coroutine.resume(root, 0)
assert(ok and value == coroutine_depth, value)
ok, value = coroutine.resume(root, 4000)
assert(ok and value == 4000 + coroutine_depth + 1, value)
assert(coroutine.status(root) == "dead")

print("iterative-dispatch-stress-ok", call_depth, coroutine_depth, metamethod_depth, gsub_depth)
