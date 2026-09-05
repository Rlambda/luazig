-- 70_coroutine_close_nonyieldable.lua — PUC-parity semantics of running
-- __close metamethods for coroutine.close (PUC lua_closethread →
-- luaD_closeprotected → luaF_close(yy=0) → callclosemethod →
-- luaD_callnoyield: the closer itself executes on a NON-YIELDABLE C
-- boundary).
--
-- Differential smoke: byte-identical output expected under PUC Lua 5.5
-- and luazig. Cases A–H per P16.25 T1.

-- A: isyieldable() is naturally false inside a thread-close __close.
local a_result
local co_a = coroutine.create(function()
    local x <close> = setmetatable({}, {
        __close = function() a_result = coroutine.isyieldable() end,
    })
    coroutine.yield("ready")
end)
assert(coroutine.resume(co_a))
print("A close", coroutine.close(co_a))
print("A isyieldable", a_result)

-- B: direct yield inside the closer errors like any non-yieldable yield.
local b_err
local co_b = coroutine.create(function()
    local x <close> = setmetatable({}, {
        __close = function()
            coroutine.yield("x")
        end,
    })
    coroutine.yield("ready")
end)
assert(coroutine.resume(co_b))
local b_ok, b_e = coroutine.close(co_b)
print("B close", b_ok, b_e)

-- C (KEY): pcall(coroutine.yield) inside the closer is CAUGHT as an
-- ordinary runtime error; the remainder of the closer RUNS; close still
-- succeeds.
local after = false
local caught = nil
local co_c = coroutine.create(function()
    local x <close> = setmetatable({}, {
        __close = function()
            local ok, err = pcall(coroutine.yield, "x")
            caught = { ok, err }
            after = true
        end,
    })
    coroutine.yield("ready")
end)
assert(coroutine.resume(co_c))
local c_ok, c_e = coroutine.close(co_c)
print("C close", c_ok, c_e)
print("C after", after)
print("C caught", caught[1], caught[2])

-- D: xpcall handler sees the catchable close-method runtime error.
local d_handler_msg
local co_d = coroutine.create(function()
    local x <close> = setmetatable({}, {
        __close = function()
            local ok, err = xpcall(coroutine.yield, function(m)
                d_handler_msg = m
                return "handled:" .. tostring(m)
            end)
            print("D xpcall", ok, err)
        end,
    })
    coroutine.yield("ready")
end)
assert(coroutine.resume(co_d))
print("D close", coroutine.close(co_d))

-- E: multiple TBC vars — reverse order, one closer's caught error does
-- not stop the others; last-error semantics per PUC.
local order = {}
local co_e = coroutine.create(function()
    do
        local a <close> = setmetatable({}, { __close = function()
            order[#order + 1] = "a"
            local ok, err = pcall(coroutine.yield)
            order[#order + 1] = "a-after:" .. tostring(ok)
        end })
        local b <close> = setmetatable({}, { __close = function()
            order[#order + 1] = "b"
        end })
        coroutine.yield("ready")
    end
end)
assert(coroutine.resume(co_e))
print("E close", coroutine.close(co_e))
print("E order", table.concat(order, ","))

-- F: nested coroutine.close chain stays bounded (P16.24 cstack parity).
local N = 50
local coro = false
for i = 1, N do
    local previous = coro
    coro = coroutine.create(function()
        local x <close> = setmetatable({}, { __close = function()
            if previous then coroutine.close(previous) end
        end })
        coroutine.yield("chain")
    end)
    assert(coroutine.resume(coro))
end
print("F chain", coroutine.close(coro))

-- G: an ordinary error() raised by a closer is an ordinary Lua error
-- (close reports false + the error object).
local co_g = coroutine.create(function()
    local x <close> = setmetatable({}, { __close = function()
        error("closer-failed", 0)
    end })
    coroutine.yield("ready")
end)
assert(coroutine.resume(co_g))
local g_ok, g_err = coroutine.close(co_g)
print("G close", g_ok, g_err)

-- H: C callback inside __close keeps the C-depth model consistent.
local co_h = coroutine.create(function()
    local x <close> = setmetatable({}, { __close = function()
        -- string.gsub repl is a C-call boundary inside the non-yieldable
        -- closer; recursion stays bounded by the shared LUAI_MAXCCALLS.
        local n = 0
        local function r() n = n + 1; return string.gsub("a", ".", r) end
        local ok, err = pcall(r)
        print("H gsub", ok, (tostring(err):find("C stack overflow") ~= nil), n > 100)
    end })
    coroutine.yield("ready")
end)
assert(coroutine.resume(co_h))
print("H close", coroutine.close(co_h))

print("OK")
