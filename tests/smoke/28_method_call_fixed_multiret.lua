local object = {}

function object:values()
  return "first", 22, true
end

local a, b, c, d
a, b, c, d = object:values()

print(a, b, c, d)
assert(a == "first")
assert(b == 22)
assert(c == true)
assert(d == nil)
