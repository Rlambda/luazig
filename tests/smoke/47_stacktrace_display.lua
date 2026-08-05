-- Scenario 1: table index is nil (error message text)
local ok, err = pcall(function() local t={}; t[nil]=1 end)
print(ok)
print(err)

-- Scenario 2: table index is NaN (error message text)
local ok, err = pcall(function() local t={}; t[0/0]=1 end)
print(ok)
print(err)

-- Scenario 3: xpcall with debug.traceback (anonymous function)
local ok, err = xpcall(function() local t={}; t[nil]=1 end, debug.traceback)
print(ok)
print(err)

-- Scenario 4: Global function names in traceback
function g_m() local t={}; t[nil]=1 end
function g_m1() g_m() end
local ok, err = xpcall(g_m1, debug.traceback)
print(ok)
print(err)

-- Scenario 5: Local function names (upvalue/local)
local function l_m() local t={}; t[nil]=1 end
local function l_m1() l_m() end
local ok, err = xpcall(l_m1, debug.traceback)
print(ok)
print(err)

-- Scenario 6: error() call shows [C]: in global 'error'
local function inner() error("boom") end
local function outer() inner() end
local ok, err = xpcall(outer, debug.traceback)
print(ok)
print(err)
