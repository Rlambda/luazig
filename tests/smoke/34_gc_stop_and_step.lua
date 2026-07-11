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
  for i = 1, 100 do
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

local large_step = steps_to_cycle(10)
local small_step = steps_to_cycle(2)
assert(large_step < small_step)
assert(not collectgarbage("isrunning"))

collectgarbage("restart")
_ENV.__gc_stopped_value = nil
collectgarbage()
print("gc stop/step: ok")
