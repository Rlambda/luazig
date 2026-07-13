-- Runtime frame/register/TBC storage belongs to each Lua thread. A nested
-- coroutine can run GC while its caller is parked without losing values that
-- exist only on the caller's bytecode stack.
local weak = setmetatable({}, {__mode = "v"})

local main_only = { value = 41 }
weak[1] = main_only
local inner = coroutine.create(function()
  collectgarbage()
  collectgarbage()
  return "inner"
end)
local ok, value = coroutine.resume(inner)
print(ok, value, main_only.value, weak[1] == main_only)

local outer = coroutine.create(function()
  local outer_only = { value = 42 }
  weak[2] = outer_only
  local nested = coroutine.create(function()
    collectgarbage()
    collectgarbage()
    return "nested"
  end)
  local nested_ok, nested_value = coroutine.resume(nested)
  return outer_only.value, weak[2] == outer_only, nested_ok, nested_value
end)
print(coroutine.resume(outer))
