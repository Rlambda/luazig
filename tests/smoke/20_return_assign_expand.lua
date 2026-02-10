local function g()
  return 1, 2, 3
end

local function r()
  return "x", g()
end

print(r())

local a, b, c = 0, g()
print(a, b, c)

d, e, f = 0, g()
print(d, e, f)

