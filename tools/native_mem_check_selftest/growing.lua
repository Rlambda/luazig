local n = tonumber(arg[1]) or 100000
local t = {}
for i = 1, n do t[i] = string.rep("y", 200) end
assert(t[n] ~= nil)
