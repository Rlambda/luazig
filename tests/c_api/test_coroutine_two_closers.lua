-- Regression: coroutine T.testC with two TBC closers where second errors.
-- PUC luaF_close runs ALL closers in LIFO order even if one errors.
-- Before fix: errdefer treated RuntimeError as yield (because
-- current_thread != null and C-frame had testc_state), skipping
-- remaining closers — o1 was not closed (n1=0).
local T = T
local setmetatable = setmetatable
local pcall = pcall
local assert = assert
local print = print
local coroutine = coroutine

-- Track close order: LIFO means o2 (last declared) closes first,
-- then o1. If o2 errors, o1 must still close.
local close_order = {}
local o1 = setmetatable({}, {
  __close = function() close_order[#close_order + 1] = "o1" end
})
local o2 = setmetatable({}, {
  __close = function()
    close_order[#close_order + 1] = "o2"
    error("boom")
  end
})

local co = coroutine.wrap(function()
  local ok = pcall(
    T.testC,
    "toclose 2; toclose 3; return 0",
    o1, o2
  )
  assert(not ok)
  -- LIFO: o2 closes first (and errors), then o1 closes.
  assert(#close_order == 2, "expected 2 closes, got " .. #close_order)
  assert(close_order[1] == "o2", "expected o2 first, got " .. close_order[1])
  assert(close_order[2] == "o1", "expected o1 second, got " .. close_order[2])
end)

co()
print("OK order: " .. table.concat(close_order, ", "))
