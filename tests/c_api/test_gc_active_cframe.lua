-- Regression: GC during active C-frame __close metamethod.
-- PUC luaF_close: __close runs while the C-frame (testC) is still on
-- the call stack. GC must trace the C-frame's testc_state without
-- crashing on u.lua field access.
--
-- Before fix: gcMarkMutableRoots accessed frame.u.lua.frame_cap without
-- checking frame.isC(), causing "access of union field 'lua' while
-- field 'c' is active" panic in Debug mode.
local T = T
local setmetatable = setmetatable
local pcall = pcall
local assert = assert
local print = print
local collectgarbage = collectgarbage

local n = 0
local o = setmetatable({}, {
  __close = function()
    n = n + 1
    -- Force GC while the testC C-frame is still active on the call stack.
    collectgarbage("collect")
    collectgarbage("collect")
  end,
})

local ok, e = pcall(T.testC, "toclose 2; return 0", o)
assert(ok, e)
assert(n == 1, "expected 1 close, got " .. n)

print("OK: GC during active C-frame __close")
