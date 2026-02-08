local x = 1
do
  local x = 2
  print(x)
end
print(x)

if true then
  local y = 10
  print(y)
end

-- outside the block, y is a global (nil)
print(y)

