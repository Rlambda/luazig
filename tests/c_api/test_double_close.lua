-- Regression: main-thread T.testC with erroring __close must call closer exactly once.
-- Before fix: runTestcScript errdefer used self.current_thread (null on main thread),
-- didn't detect the C-frame with testc_state, and ran its own closer loop — double-closing.
local T = T
local setmetatable = setmetatable
local pcall = pcall
local assert = assert
local print = print

local n = 0
local o = setmetatable({}, {
    __close = function()
        n = n + 1
        error("close error")
    end
})
local ok = pcall(T.testC, "toclose 2; return 0", o)
assert(not ok)
assert(n == 1, "n=" .. n)
print("OK n=" .. n)
