-- repeated_stripped_dump.lua — native-memory lane (P16.10b Task 0).
--
-- The P16.10 Blocker 2 reproducer: `string.dump(f, true)` in a loop with
-- periodic collectgarbage(). Before P16.10b Task 1, the strip path built a
-- throwaway `cloneStrippedProto()` tree per dump that was never freed
-- (linear native-memory growth). After Task 1, strip is a serialization
-- property of DumpWriter (no clone), so the loop is bounded.
--
-- The dumped function has a nested closure, locals and named upvalues so
-- the stripped clone used to carry a multi-proto tree — enough leak mass
-- for the 5 MB/decade threshold to discriminate.
--
-- Run with the RSS-slope instrument (iterations come in as arg[1]):
--   python3 tools/native_mem_check.py tools/native_mem_lanes/repeated_stripped_dump.lua
--
-- Expected verdicts:
--   LINEAR  — strip clones leak (pre-Task-1 behavior).
--   BOUNDED — strip-as-serialization fix in place.

local n = tonumber(arg[1]) or 100000

local f = assert(load([[
local function inner(a, b)
  local sum = a + b
  return function(c) return sum + c end
end
return inner
]], "=lane"))()

for i = 1, n do
  local d = string.dump(f, true)
  if #d == 0 then error("empty dump") end
  if i % 100 == 0 then collectgarbage() end
end

print("done", n)
