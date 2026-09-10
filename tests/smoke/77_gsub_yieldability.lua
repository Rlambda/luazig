-- 77_gsub_yieldability.lua — P16.36 Cut 3: gsub non-yieldability is owned
-- by the nCcalls nny upper unit (PUC ccall(nyci) around each replacement
-- invocation and around the table __index lookup from the gsub C context:
-- lstrlib.c lua_call → luaD_callnoyield; lua_gettable → luaT_callTMres →
-- luaD_callnoyield), replacing the O(frames) pending-.gsub scan.
--
-- Differential smoke: byte-identical output expected under PUC Lua 5.5
-- and luazig. Every probe exercises a yieldability window in or around
-- string.gsub.

-- T1: yield allowed normally (no gsub involved).
local co1 = coroutine.create(function()
    coroutine.yield("normal-yield-ok")
end)
print("T1", coroutine.resume(co1))

-- T2: yield REJECTED inside a gsub replacement function.
local co2 = coroutine.create(function()
    local ok, err = pcall(string.gsub, "abc", "b", function(x)
        coroutine.yield("must-not-suspend")
        return x
    end)
    print("T2-inner", ok, err)
end)
print("T2", coroutine.resume(co2))

-- T2b: same, DIRECT call (no pcall wrapper — the error escapes the
-- coroutine body and surfaces at resume).
local co2b = coroutine.create(function()
    string.gsub("abc", "b", function(x)
        coroutine.yield("must-not-suspend")
        return x
    end)
end)
print("T2b", coroutine.resume(co2b))

-- T3: yield REJECTED inside a gsub table __index metamethod.
local t3 = setmetatable({}, {__index = function(_, k)
    coroutine.yield("must-not-suspend")
    return k
end})
local co3 = coroutine.create(function()
    local ok, err = pcall(string.gsub, "abc", "b", t3)
    print("T3-inner", ok, err)
end)
print("T3", coroutine.resume(co3))

-- T3b: same, DIRECT call.
local t3b = setmetatable({}, {__index = function(_, k)
    coroutine.yield("must-not-suspend")
    return k
end})
local co3b = coroutine.create(function()
    string.gsub("abc", "b", t3b)
end)
print("T3b", coroutine.resume(co3b))

-- T4: coroutine.isyieldable is false inside both windows.
local t4i = setmetatable({}, {__index = function(_, k)
    print("T4-index-isyieldable", coroutine.isyieldable())
    return k
end})
local co4 = coroutine.create(function()
    string.gsub("abc", "b", function(x)
        print("T4-repl-isyieldable", coroutine.isyieldable())
        return x
    end)
    string.gsub("abc", "b", t4i)
    coroutine.yield("T4-done")
end)
print("T4", coroutine.resume(co4))

-- T5: yield allowed again after gsub completes (unit released).
local co5 = coroutine.create(function()
    local r = string.gsub("abc", "b", function(x) return "X" end)
    coroutine.yield("after-gsub", r)
end)
print("T5", coroutine.resume(co5))

-- T6: yield allowed after a gsub error + pcall recovery (unit reclaimed
-- by the protection's nCcalls snapshot restore).
local co6 = coroutine.create(function()
    local ok, err = pcall(string.gsub, "abc", "b", function(x)
        error("gsub-boom")
    end)
    print("T6-inner", ok, (err:gsub("^.-:%d+: ", "")))
    coroutine.yield("after-gsub-error")
end)
print("T6", coroutine.resume(co6))

-- T7: yield allowed after a gsub __index error + recovery.
local t7 = setmetatable({}, {__index = function(_, k) error("index-boom") end})
local co7 = coroutine.create(function()
    local ok, err = pcall(string.gsub, "abc", "b", t7)
    print("T7-inner", ok, (err:gsub("^.-:%d+: ", "")))
    coroutine.yield("after-index-error")
end)
print("T7", coroutine.resume(co7))

-- T8: nested pcall/xpcall INSIDE a gsub replacement still cannot yield
-- (pcall's own boundary is yieldable, but the gsub nny unit wraps them).
local co8 = coroutine.create(function()
    local ok, err = pcall(string.gsub, "abc", "b", function(x)
        local iok, ierr = pcall(function()
            coroutine.yield("nested-must-not-suspend")
        end)
        print("T8-nested-pcall", iok, (ierr:gsub("^.-:%d+: ", "")))
        local xok, xerr = xpcall(function()
            coroutine.yield("xpcall-must-not-suspend")
            return 1
        end, function(e) return "handled:" .. tostring(e) end)
        print("T8-nested-xpcall", xok, xerr)
        return x
    end)
    print("T8-inner", ok)
end)
print("T8", coroutine.resume(co8))

-- T9: __close inside a gsub replacement (to-be-closed mark set inside the
-- repl; the closer runs at repl-frame unwind — still inside the gsub unit,
-- so its yield attempt fails too; the close itself must not corrupt the
-- unit accounting).
local co9 = coroutine.create(function()
    local ok, err = pcall(string.gsub, "abc", "b", function(x)
        local closed = false
        do
            local probe <close> = setmetatable({}, {__close = function()
                closed = true
            end})
            _ = probe
        end
        return closed and x or "?"
    end)
    print("T9-inner", ok)
    coroutine.yield("T9-after")
end)
print("T9", coroutine.resume(co9))

-- T10: a to-be-closed __close that YIELDS inside a gsub replacement fails
-- like any other yield attempt (PUC: yy=0 close under callnoyield).
local co10 = coroutine.create(function()
    local ok, err = pcall(string.gsub, "abc", "b", function(x)
        local probe <close> = setmetatable({}, {__close = function()
            coroutine.yield("close-must-not-suspend")
        end})
        _ = probe
        return x
    end)
    print("T10-inner", ok, (err:gsub("^.-:%d+: ", "")))
    coroutine.yield("T10-after")
end)
print("T10", coroutine.resume(co10))

-- T11: coroutine.close of a thread that DIED inside a gsub replacement
-- (error escaped the coroutine body): the close runs the body's __close
-- on the dead thread; the gsub unit must have been reclaimed by the
-- error unwind (thread is dead, not stuck non-yieldable). The closer
-- only records a side effect: WHEN it runs (resume unwind vs. close) is
-- a documented pre-existing engine divergence (PUC lua_resume's error
-- path defers TBC close to luaE_resetthread), so the print ordering is
-- not part of the differential contract — only "it ran by close-return".
local t11_ran = {}
local victim = coroutine.create(function()
    local probe <close> = setmetatable({}, {__close = function()
        t11_ran[1] = true
    end})
    string.gsub("abc", "b", function(x) error("victim-boom") end)
    _ = probe
end)
local _, verr = coroutine.resume(victim)
print("T11-resume", (verr:gsub("^.-:%d+: ", "")))
print("T11-close", coroutine.close(victim))
print("T11-closer-ran", t11_ran[1] == true)

-- T12: recursive gsub (repl runs another gsub): nesting consumes C-depth
-- units; a modest depth must work and release cleanly.
local co12 = coroutine.create(function()
    local function rep(x)
        return (string.gsub(x, "a", function(y) return "B" end))
    end
    local r = string.gsub("aa", "a", rep)
    coroutine.yield("T12", r)
end)
print("T12", coroutine.resume(co12))

-- T13: yield from a coroutine resumed INSIDE a gsub replacement is fine
-- (the inner coroutine has its own nCcalls; the gsub unit only pins the
-- outer thread).
local inner13
inner13 = coroutine.create(function()
    coroutine.yield("inner-step")
    return "inner-done"
end)
local co13 = coroutine.create(function()
    local r = string.gsub("abc", "b", function(x)
        local _, y1 = coroutine.resume(inner13)
        local _, y2 = coroutine.resume(inner13)
        return (y1 or "?") .. "/" .. (y2 or "?")
    end)
    coroutine.yield("T13", r)
end)
print("T13", coroutine.resume(co13))
