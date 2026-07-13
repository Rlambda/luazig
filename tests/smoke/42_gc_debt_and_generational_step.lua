-- Automatic collection must account for short interned strings. Otherwise a
-- weak value can stay alive forever while the loop creates only short-string
-- garbage and the GC debt never grows.
collectgarbage("collect")
local oldpause = collectgarbage("param", "pause", 100)
local weak = setmetatable({[1] = {}}, {__mode = "v"})
for i = 1, 20000 do
  local garbage = tostring(i) .. ":" .. tostring(i)
  if weak[1] == nil then break end
end
assert(weak[1] == nil)
collectgarbage("param", "pause", oldpause)

-- PUC advances a young collection on every explicit step in generational
-- mode. The current atomic collector must preserve that observable behavior.
local oldmode = collectgarbage("generational")
local genweak = setmetatable({[1] = {10}}, {__mode = "kv"})
assert(collectgarbage("step") == false)
assert(genweak[1] == nil)
collectgarbage(oldmode)

print("gc-debt-generational-step-ok")
