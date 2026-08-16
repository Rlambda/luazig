-- Regression: two TBC closers where second errors. PUC luaF_close runs ALL
-- closers in LIFO order even if one errors. Before fix: o1 was skipped.
local T = T
local setmetatable = setmetatable
local pcall = pcall
local assert = assert
local print = print

local n1 = 0
local n2 = 0
local o1 = setmetatable({}, {__close=function() n1=n1+1 end})
local o2 = setmetatable({}, {__close=function() n2=n2+1; error("boom") end})

local ok = pcall(T.testC, "toclose 2; toclose 3; return 0", o1, o2)
assert(not ok)
print("n1=" .. n1 .. " n2=" .. n2)
-- PUC: both closers run (LIFO: o2 first, then o1)
assert(n1 == 1, "n1=" .. n1)
assert(n2 == 1, "n2=" .. n2)
print("OK")
