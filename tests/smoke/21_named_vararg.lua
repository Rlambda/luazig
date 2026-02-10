local function f(...t)
  print(t[1], t[2], t[3])
  return t[1]
end

print(f(5, 6, 7))
