local function add1(x)
  return x + 1
end

local dumped = string.dump(add1, true)
local restored = assert(load(dumped))
print(restored(3))

local function make_adder(x)
  return function(y) return x + y end
end
local restored_make_adder = assert(load(string.dump(make_adder, true)))
print(restored_make_adder(10)(2))

local ok, err = pcall(restored, {})
print(ok)
print(err:find("table value", 1, true) ~= nil)

local current = debug.getinfo(1, "l").currentline
print(current == 19)
