-- Regression: yield → resume → next closer errors.
-- PUC luaF_close: if a closer yields, the coroutine suspends. On resume,
-- remaining closers continue. If a later closer errors, the error replaces
-- the current error (LIFO) and remaining closers still run.
-- Before fix: testcContShim passed null to resumed closers and treated
-- every non-Yield error as return -1, losing the error and not running
-- remaining closers.
local T = T
local setmetatable = setmetatable
local pcall = pcall
local assert = assert
local print = print
local coroutine = coroutine

local close_order = {}
local o1 = setmetatable({}, {
  __close = function() close_order[#close_order + 1] = "o1" end
})
local o2 = setmetatable({}, {
  __close = function()
    close_order[#close_order + 1] = "o2(yield)"
    coroutine.yield()
  end
})
local o3 = setmetatable({}, {
  __close = function()
    close_order[#close_order + 1] = "o3(error)"
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
  -- LIFO: o3 closes first (errors), o2 closes second (yields),
  -- o1 closes third (after resume).
  assert(#close_order == 3, "expected 3 closes, got " .. #close_order)
  assert(close_order[1] == "o3(error)", "expected o3(error) first, got " .. close_order[1])
  assert(close_order[2] == "o2(yield)", "expected o2(yield) second, got " .. close_order[2])
  assert(close_order[3] == "o1", "expected o1 third, got " .. close_order[3])
end)

-- First resume: o3 errors, o2 yields → coroutine suspends.
co()
-- Second resume: o1 closes, pcall returns with error.
co()
print("OK order: " .. table.concat(close_order, ", "))
