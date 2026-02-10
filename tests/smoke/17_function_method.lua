local t = { v = 10 }
function t:add(x)
  return self.v + x
end

print(t:add(5))

