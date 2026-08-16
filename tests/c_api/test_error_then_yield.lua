-- Regression: closer errors → next closer yields → resume.
-- PUC luaF_close: if a closer errors, the error replaces the current error
-- (LIFO) and remaining closers still run. If a later closer yields, the
-- coroutine suspends. On resume, remaining closers continue with the
-- preserved error.
-- Before fix: close_err was a local var, not stored in TestcContState.
-- On yield, the error was lost. Resumed closers received null, and the
-- protected call could finish without the original error.
local T = T
local setmetatable = setmetatable
local pcall = pcall
local assert = assert
local print = print
local coroutine = coroutine
local tostring = tostring

local close_order = {}
local received_err = {}
local o1 = setmetatable({}, {
  __close = function(_, err)
    close_order[#close_order + 1] = "o1"
    received_err[#received_err + 1] = tostring(err)
  end
})
local o2 = setmetatable({}, {
  __close = function(_, err)
    close_order[#close_order + 1] = "o2(yield)"
    received_err[#received_err + 1] = tostring(err)
    coroutine.yield()
  end
})
local o3 = setmetatable({}, {
  __close = function(_, err)
    close_order[#close_order + 1] = "o3(error)"
    received_err[#received_err + 1] = tostring(err)
    error("boom")
  end
})

local co = coroutine.wrap(function()
  local ok = pcall(
    T.testC,
    "toclose 2; toclose 3; toclose 4; return 0",
    o1, o2, o3
  )
  assert(not ok)
  -- LIFO: o3 closes first (errors), o2 closes second (yields), o1 closes third (after resume).
  assert(#close_order == 3, "expected 3 closes, got " .. #close_order)
  assert(close_order[1] == "o3(error)", "expected o3(error) first, got " .. close_order[1])
  assert(close_order[2] == "o2(yield)", "expected o2(yield) second, got " .. close_order[2])
  assert(close_order[3] == "o1", "expected o1 third, got " .. close_order[3])
  -- o3 receives nil (first closer, no error yet).
  -- o2 receives "boom" (error from o3, LIFO).
  -- o1 receives "boom" (preserved across yield).
  assert(received_err[1] == "nil", "o3 should receive nil, got " .. received_err[1])
  assert(received_err[2] == "boom", "o2 should receive boom, got " .. received_err[2])
  assert(received_err[3] == "boom", "o1 should receive boom (preserved), got " .. received_err[3])
end)

-- First resume: o3 errors, o2 yields → coroutine suspends.
co()
-- Second resume: o1 closes with preserved error, pcall returns with error.
co()
print("OK order: " .. table.concat(close_order, ", "))
print("OK errors: " .. table.concat(received_err, ", "))
