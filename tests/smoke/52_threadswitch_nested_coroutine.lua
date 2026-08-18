-- ThreadSwitch: coroutine.resume/wrap inside a coroutine driven by the
-- trampoline must switch between threads without nesting runBytecode on the
-- Zig stack. This test exercises the ThreadSwitch error path through:
--  1. Nested coroutine.resume (trampoline → ThreadSwitch → trampoline)
--  2. Multiple yields across nested coroutines
--  3. Error propagation across nested coroutines
--  4. coroutine.wrap inside a coroutine
--  5. __close metamethod triggering coroutine.resume (ThreadSwitch in close)
-- All outputs must match PUC Lua exactly.

-- 1. Basic nested resume: A resumes B, B yields, A resumes B again.
local co_a = coroutine.create(function()
  local co_b = coroutine.create(function()
    coroutine.yield("b1")
    return "b2"
  end)
  local ok, r1 = coroutine.resume(co_b)
  assert(ok and r1 == "b1", "nested resume 1 failed")
  local ok2, r2 = coroutine.resume(co_b)
  assert(ok2 and r2 == "b2", "nested resume 2 failed")
  return "a_done"
end)
local ok, r = coroutine.resume(co_a)
assert(ok and r == "a_done", "outer resume failed")
assert(coroutine.status(co_a) == "dead")

-- 2. Multiple yields: A yields, B yields multiple times, A resumes B in a loop.
co_a = coroutine.create(function()
  local co_b = coroutine.create(function()
    coroutine.yield("b_yield_1")
    coroutine.yield("b_yield_2")
    return "b_done"
  end)
  for i = 1, 3 do
    local ok, r = coroutine.resume(co_b)
    assert(ok, "nested resume " .. i .. " failed")
  end
  coroutine.yield("a_yield")
  return "a_done"
end)
local ok1, r1 = coroutine.resume(co_a)
assert(ok1 and r1 == "a_yield")
local ok2, r2 = coroutine.resume(co_a)
assert(ok2 and r2 == "a_done")
local ok3, r3 = coroutine.resume(co_a)
assert(not ok3, "dead coroutine should fail")

-- 3. Error propagation: B errors, A catches via pcall, A re-errors.
co_a = coroutine.create(function()
  local co_b = coroutine.create(function()
    coroutine.yield("b_ok")
    error("b_error")
  end)
  local ok1, r1 = coroutine.resume(co_b)
  assert(ok1 and r1 == "b_ok")
  local ok2, r2 = coroutine.resume(co_b)
  assert(not ok2 and r2:find("b_error") ~= nil, "error should propagate")
  error("caught from b: " .. r2)
end)
local ok, r = coroutine.resume(co_a)
assert(not ok and r:find("caught from b") ~= nil, "outer should fail")

-- 4. coroutine.wrap inside a coroutine (uses coroutine_wrap_iter builtin).
co_a = coroutine.create(function()
  local wrap = coroutine.wrap(function()
    coroutine.yield("w1")
    coroutine.yield("w2")
    return "w3"
  end)
  assert(wrap() == "w1")
  assert(wrap() == "w2")
  assert(wrap() == "w3")
  return "a_done"
end)
local ok, r = coroutine.resume(co_a)
assert(ok and r == "a_done")

-- 5. __close metamethod triggering coroutine.resume (ThreadSwitch in close).
local func2close = function(f)
  return setmetatable({}, {__close = f})
end
co_a = coroutine.create(function()
  local co_b = coroutine.create(function()
    coroutine.yield("b1")
    return "b2"
  end)
  local ok1, r1 = coroutine.resume(co_b)
  assert(ok1 and r1 == "b1")
  local closer <close> = func2close(function()
    local ok2, r2 = coroutine.resume(co_b)
    assert(ok2 and r2 == "b2", "close resume failed")
  end)
  return "a_done"
end)
local ok, r = coroutine.resume(co_a)
assert(ok and r == "a_done", "close resume should work")

-- 6. Deeply nested: A → B → C, all yield and resume.
co_a = coroutine.create(function()
  local co_b = coroutine.create(function()
    local co_c = coroutine.create(function()
      coroutine.yield("c1")
      return "c2"
    end)
    local ok1, r1 = coroutine.resume(co_c)
    assert(ok1 and r1 == "c1")
    local ok2, r2 = coroutine.resume(co_c)
    assert(ok2 and r2 == "c2")
    coroutine.yield("b1")
    return "b2"
  end)
  local ok1, r1 = coroutine.resume(co_b)
  assert(ok1 and r1 == "b1")
  local ok2, r2 = coroutine.resume(co_b)
  assert(ok2 and r2 == "b2")
  return "a_done"
end)
local ok, r = coroutine.resume(co_a)
assert(ok and r == "a_done")

print("threadswitch-nested-coroutine-ok")
