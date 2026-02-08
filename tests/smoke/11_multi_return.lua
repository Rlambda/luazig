function f()
  return 1, 2, 3
end

local a, b = f()
print(a, b)

a, b, c = f()
print(a, b, c)

function g()
  return f()
end

local p, q, r = g()
print(p, q, r)

