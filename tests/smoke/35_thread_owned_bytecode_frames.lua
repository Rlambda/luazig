-- The explicit bytecode activation stack belongs to the Lua Thread. Nested
-- host re-entry (protected calls, metamethods, and coroutine resume) must only
-- consume the suffix pushed by that entry and leave the caller continuation
-- intact.

local function protected_depth(n)
  if n == 0 then
    return 7
  end
  local ok, value = pcall(protected_depth, n - 1)
  assert(ok)
  return value + 1
end

local mt = {
  __add = function(a, b)
    local ok, value = pcall(function()
      return a.value + b.value
    end)
    assert(ok)
    return value
  end,
}

local co = coroutine.create(function()
  local ok, value = pcall(function()
    coroutine.yield("pause")
    return protected_depth(12)
  end)
  return ok, value
end)

local ok1, marker = coroutine.resume(co)
local ok2, inner_ok, result = coroutine.resume(co)

print(protected_depth(16))
print(setmetatable({ value = 20 }, mt) + setmetatable({ value = 22 }, mt))
print(ok1, marker)
print(ok2, inner_ok, result, coroutine.status(co))
