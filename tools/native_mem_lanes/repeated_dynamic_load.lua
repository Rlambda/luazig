-- repeated_dynamic_load.lua — native-memory lane (P16.10b Task 0).
--
-- The P16.10 verifier's exact reproducer for the dynamic-load retention
-- blocker: repeatedly load a tiny source chunk, call it, and collect
-- periodically. Each load() compiles a fresh Proto tree; the lane detects
-- whether those trees (or their runtime attachments) are retained by the
-- VM after the closure becomes unreachable.
--
-- Run with the RSS-slope instrument (iterations come in as arg[1]):
--   python3 tools/native_mem_check.py tools/native_mem_lanes/repeated_dynamic_load.lua
--
-- Expected verdicts:
--   LINEAR  — retainer bug present (Proto trees leak per load).
--   BOUNDED — load path frees/reuses everything after collectgarbage().

local n = tonumber(arg[1]) or 100000

for i = 1, n do
  local f = assert(load("return 1"))
  f()
  if i % 100 == 0 then collectgarbage() end
end

print("done", n)
