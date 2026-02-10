local t = { a = 1, b = 2 }
local sum = 0
for k, v in pairs(t) do
  sum = sum + v
end
print(sum)

local s2 = 0
for i, v in ipairs({ 10, 20, 30 }) do
  s2 = s2 + i * 10 + v
end
print(s2)

