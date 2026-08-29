local t = {}
for i = 1, 800 do t[i] = string.rep("x", 10240) end
-- keep references alive until exit
assert(t[800] ~= nil)
