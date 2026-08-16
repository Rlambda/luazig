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

local n1, n2 = 0, 0
local o1 = setmetatable({}, {
  __close = function() n1 = n1 + 1 end
})
local o2 = setmetatable({}, {
  __close = function()
    n2 = n2 + 1
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
  assert(n1 == 1, "n1=" .. n1)
  assert(n2 == 1, "n2=" .. n2)
end)

co()
print("OK n1=" .. n1 .. " n2=" .. n2)
