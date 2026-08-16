-- Regression: nested T.testC where outer callk has C-frame with testc_state.
-- Inner T.testC errors before its own closer section. Before fix: errdefer
-- saw outer C-frame's testc_state and skipped inner closer — zero-close.
local T = T
local setmetatable = setmetatable
local pcall = pcall
local assert = assert
local print = print
local coroutine = coroutine

local n = 0
local o = setmetatable({}, {__close=function() n=n+1 end})

local function f()
  local ok = pcall(T.testC,
    "toclose 2; pushstring boom; error", o)
  assert(not ok)
  assert(n == 1, "inner n=" .. n)
  print("inner ok=" .. tostring(ok) .. " n=" .. n)
end

local co = coroutine.wrap(function()
  return T.testC(
    "pushvalue 2; callk 0 0 3; return 0",
    f, "return 0")
end)

co()
assert(n == 1, "outer n=" .. n)
print("OK n=" .. n)
