local function pack(...)
  local a, b, c = ...
  print(a, b, c)
  print("p", ...)
  return ...
end

local x, y = pack(1, 2, 3)
print(x, y)

local function id(...)
  return ...
end

local i, j = id("a", "b", "c")
print(i, j)

