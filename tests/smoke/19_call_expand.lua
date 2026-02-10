local function g()
  return 1, 2, 3
end

print(g())
print(0, g())

local function f(a, b, c)
  return a + b + c
end

print(f(g()))

local t = { v = 10 }
function t:sum(a, b, c)
  return a + b + c + self.v
end

print(t:sum(g()))

