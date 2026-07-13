-- Frozen testC/IR compatibility children can yield while the bytecode backend
-- remains the authoritative caller.  The bytecode continuation must survive
-- without replaying CALL, TAILCALL, or TFORCALL.
local calls = 0
local direct = T.makeCfunc("pushnum 5; yield 1;")
local normal = coroutine.wrap(function()
  calls = calls + 1
  local value = direct()
  return value, calls
end)
assert(normal() == 5)
local value, count = normal(23)
assert(value == 23 and count == 1)

local tail_calls = 0
local tail = coroutine.wrap(function()
  tail_calls = tail_calls + 1
  return direct()
end)
assert(tail() == 5)
assert(tail(31) == 31)
assert(tail_calls == 1)

local iter_calls = 0
local iterator = T.makeCfunc("pushnum 7; yield 1;")
local loop = coroutine.wrap(function()
  for item in iterator, nil, nil do
    iter_calls = iter_calls + 1
    return item
  end
end)
assert(loop() == 7)
assert(loop(42) == 42)
assert(iter_calls == 1)

-- Native protected frames count for error(message, level), but do not invent
-- a Lua source location. This is the final cstack/protected-call regression in
-- the upstream coroutine suite.
local packed = table.pack(pcall(pcall, pcall, pcall, error, "hi"))
assert(packed[1] and packed[2] and packed[3] and not packed[4])
assert(packed[5] == "hi")

print("iterative-dispatch-testc-ok")
