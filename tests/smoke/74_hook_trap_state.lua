-- 74_hook_trap_state.lua — P16.34 Cut 2 parity gate: hook visibility with a
-- dispatch-local gate word (PUC `trap` ownership model). Every probe attacks
-- the immediate-sethook invariant: after debug.sethook / lua_sethook returns
-- to a running frame, the NEXT instruction must observe the new hook state
-- without waiting for a frame boundary.

-- 1. install LINE hook from inside a nested call: the hook must fire at the
--    caller's NEXT line (the line after the installer call), not at the next
--    frame boundary.
local log1 = {}
local function installer1()
    debug.sethook(function(ev, line) log1[#log1 + 1] = ev .. ":" .. line end, "l")
end
local function outer1()
    local a = 1
    installer1()
    local b = 2
    local c = 3
    debug.sethook()
end
outer1()
print("1", table.concat(log1, ","))

-- 2. clear the hook from inside the hook itself: after the clearing call
--    returns, no further line events may fire.
local log2 = {}
local fired2 = 0
debug.sethook(function(ev, line)
    fired2 = fired2 + 1
    log2[#log2 + 1] = line
    if fired2 >= 2 then debug.sethook() end
end, "l")
local function f2()
    local x = 1
    local y = 2
    local z = 3
    local w = 4
end
f2()
debug.sethook()
print("2", fired2, table.concat(log2, ","))

-- 3. change the hook line -> count mid-frame (from inside a nested call).
--    (The count hook is enabled by the 4th argument, independent of the
--    mask string: makemask("", 3) == LUA_MASKCOUNT only.)
local log3 = {}
local function f3()
    local x = 1
    debug.sethook(function(ev) log3[#log3 + 1] = ev end, "l")
    local y = 2
    debug.sethook(function(ev) log3[#log3 + 1] = ev end, "", 3)
    local z = 3
    local w = 4
    debug.sethook()
end
f3()
print("3", table.concat(log3, ","))

-- 4. count hook semantics: COUNT is enabled by the 4th argument
--    independent of the mask string (PUC makemask("", N) == MASKCOUNT
--    only), events are all "count", and clear takes effect immediately.
--    (The ABSOLUTE firing count is compiler-dependent — it counts
--    executed VM instructions and the two engines emit different
--    instruction streams — so the probe asserts semantics, not counts.)
local log4 = {}
debug.sethook(function(ev) log4[#log4 + 1] = ev end, "", 4)
do
    local t = 0
    for i = 1, 10 do t = t + i end
end
debug.sethook()
local n4 = #log4
do
    local t = 0
    for i = 1, 10 do t = t + i end
end
print("4", n4 > 0, #log4 == n4, log4[1] == "count", log4[n4] == "count")

-- 5. call/return hooks around nested calls (event ordering).
local log5 = {}
debug.sethook(function(ev) log5[#log5 + 1] = ev end, "cr")
local function g5() local x = 1 end
local function h5() g5() end
h5()
debug.sethook()
print("5", table.concat(log5, ","))

-- 6. per-thread hook state across yield/resume: hook on the coroutine, a
--    DIFFERENT hook on main; each thread must see only its own events.
local log6 = {}
local co6 = coroutine.create(function()
    debug.sethook(function(ev, line) log6[#log6 + 1] = "co:" .. line end, "l")
    local a = 1
    coroutine.yield()
    local b = 2
    debug.sethook()
end)
coroutine.resume(co6)
debug.sethook(function(ev, line) log6[#log6 + 1] = "main:" .. line end, "l")
local m1 = 1
local m2 = 2
coroutine.resume(co6)
local m3 = 3
debug.sethook()
print("6", table.concat(log6, ","))
print("6r", coroutine.close(co6))

-- 7. debug.sethook on a SUSPENDED coroutine, then resume it: the resumed
--    thread must run with the newly installed hook from its first line.
local log7 = {}
local co7 = coroutine.create(function()
    local a = 1
    coroutine.yield()
    local b = 2
    local c = 3
end)
coroutine.resume(co7)
debug.sethook(co7, function(ev, line) log7[#log7 + 1] = ev .. ":" .. line end, "l")
coroutine.resume(co7)
print("7", table.concat(log7, ","))

-- 8. hook installed by a nested call, then a SYNCHRONOUS builtin metamethod
--    (string __add via MMBIN) runs before the next line: exercises the
--    sync-metamethod return path between install and next line event.
local log8 = {}
local function f8()
    installer8()
    local x = "5" + 1
    local y = 2
    debug.sethook()
    return x
end
function installer8()
    debug.sethook(function(ev, line) log8[#log8 + 1] = line end, "l")
end
print("8", f8(), table.concat(log8, ","))

-- 9. hook installed mid-frame, then a synchronous builtin __index metamethod
--    (rawget) runs before the next line event.
local log9 = {}
local t9 = setmetatable({}, { __index = rawget })
local function f9()
    debug.sethook(function(ev, line) log9[#log9 + 1] = line end, "l")
    local x = t9.absent
    local y = 1
    debug.sethook()
    return x
end
print("9", f9(), table.concat(log9, ","))

-- 10. hook installed from inside a metamethod body (the metamethod frame is
--     a child of the running frame; on return the caller must be traced).
local log10 = {}
local t10 = setmetatable({}, {
    __index = function(_, k)
        debug.sethook(function(ev, line) log10[#log10 + 1] = line end, "l")
        return 7
    end,
})
local function f10()
    local x = t10.k
    local y = 1
    debug.sethook()
    return x
end
print("10", f10(), table.concat(log10, ","))
