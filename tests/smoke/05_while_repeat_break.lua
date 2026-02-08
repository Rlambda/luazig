local i = 0
while i < 3 do
  i = i + 1
end
print(i)

local j = 0
repeat
  j = j + 1
  if j == 2 then
    break
  end
until j == 10
print(j)

