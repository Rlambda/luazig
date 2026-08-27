collectgarbage()
collectgarbage("stop")
assert(not collectgarbage("isrunning"))

local previous = collectgarbage("count")
for block = 1, 60 do
  for _ = 1, 1000 do
    _ENV.__gc_stopped_value = {}
  end
  local current = collectgarbage("count")
  assert(current >= previous)
  previous = current
end

local weak = setmetatable({}, {__mode = "v"})
weak[1] = {}
collectgarbage("collect")
assert(weak[1] == nil)
assert(not collectgarbage("isrunning"))

local function steps_to_cycle(size)
  collectgarbage()
  local live = {}
  for i = 1, 300 do
    live[i] = {{}}
    local garbage = {}
  end
  local before = collectgarbage("count")
  local steps = 0
  repeat
    steps = steps + 1
  until collectgarbage("step", size)
  assert(collectgarbage("count") < before)
  return steps
end

-- 300 (not PUC's ~100): the minor→major transition fires when promoted
-- OLD1 bytes reach minormajor% of the post-full-collect heap base. VM
-- footprints differ (Zig structs are larger than PUC's C structs), so a
-- 100-table workload sits right at the threshold boundary (63% vs 67% for
-- luazig, 72% for PUC). 300 tables push promotions decisively past the
-- limit on ANY plausible footprint while testing the same semantics:
-- step loop terminates via a major cycle, count drops, bigger steps
-- need fewer steps.
local large_step = steps_to_cycle(10)
local small_step = steps_to_cycle(2)
assert(large_step < small_step)
assert(not collectgarbage("isrunning"))

collectgarbage("restart")
_ENV.__gc_stopped_value = nil
collectgarbage()
print("gc stop/step: ok")
