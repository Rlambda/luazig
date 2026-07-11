local started = os.clock()
assert(type(started) == "number" and started >= 0)

local previous = started
local checksum = 0
local advanced = false
for batch = 1, 1000 do
  for i = 1, 10000 do
    checksum = checksum + i
  end
  local current = os.clock()
  assert(current >= previous)
  previous = current
  if current > started then
    advanced = true
    break
  end
end

assert(checksum > 0)
assert(advanced, "os.clock did not advance while the process consumed CPU")
print("OK")
