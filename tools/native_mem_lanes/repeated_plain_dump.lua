-- repeated_plain_dump.lua — native-memory lane (P16.10b Task 0).
--
-- Control workload for repeated_stripped_dump.lua: the same loop with
-- strip=false. The plain dump path never built a clone, so this lane is
-- expected BOUNDED both before and after P16.10b Task 1 — a non-leaking
-- baseline that isolates any growth the stripped lane reports to the strip
-- path alone.
--
-- Run with the RSS-slope instrument (iterations come in as arg[1]):
--   python3 tools/native_mem_check.py tools/native_mem_lanes/repeated_plain_dump.lua
--
-- Expected verdict: BOUNDED (always).

local n = tonumber(arg[1]) or 100000

local f = assert(load([[
local function inner(a, b)
  local sum = a + b
  return function(c) return sum + c end
end
return inner
]], "=lane"))()

for i = 1, n do
  local d = string.dump(f, false)
  if #d == 0 then error("empty dump") end
  if i % 100 == 0 then collectgarbage() end
end

print("done", n)
