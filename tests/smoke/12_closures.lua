local function make_counter()
  local x = 0
  return function()
    x = x + 1
    return x
  end
end

local a = make_counter()
local b = make_counter()

print(a(), a(), b(), a(), b())

