-- 71_xpcall_errfunc_timing.lua — PUC-parity semantics of the xpcall
-- message handler (P16.29 T5): the handler runs AT THE THROW SITE via the
-- errfunc mechanism (PUC luaG_errormsg), BEFORE the call stack is
-- unwound — not after error propagation.
--
-- Differential smoke: byte-identical output expected under PUC Lua 5.5
-- and luazig.

-- A (KEY): TBC ordering — the message handler runs BEFORE __close
-- metamethods of the failing frame (PUC luaG_errormsg precedes unwinding).
local close_order = {}
local ok_a, err_a = xpcall(function()
    local x <close> = setmetatable({}, {
        __close = function() close_order[#close_order + 1] = "close" end,
    })
    error("boomA")
end, function(m)
    close_order[#close_order + 1] = "handler"
    return "H:" .. m
end)
print("A", ok_a, err_a, table.concat(close_order, ","))

-- B (KEY): inside the handler, level 2 is the raising C function
-- (error's CallInfo: currentline=-1, what="C", source="=[C]"), and
-- level 3 is the erroring Lua function.
local ok_b, err_b = xpcall(function()
    error("boomB")
end, function(m)
    local i2 = debug.getinfo(2)
    local i3 = debug.getinfo(3)
    return "B:" .. m ..
        " L2:" .. i2.currentline .. "/" .. i2.what .. "/" .. i2.source ..
        " L3:" .. i3.currentline .. "/" .. i3.what
end)
print("B", ok_b, err_b)

-- C: the handler receives the RAW error object — error(nil) hands nil to
-- the handler (PUC normalizes to "<no error object>" only for the
-- protected RESULT).
local ok_c, err_c = xpcall(function()
    error(nil)
end, function(m) return "C:" .. tostring(m) end)
print("C", ok_c, err_c)
local ok_c2, err_c2 = pcall(function() error(nil) end)
print("C2", ok_c2, err_c2)

-- D: a nil handler result becomes the literal "<no error object>";
-- a non-string result is preserved as-is (no tostring coercion).
local ok_d, err_d = xpcall(function() error("boomD") end, function(m) return nil end)
print("D", ok_d, err_d)
local ok_d2, err_d2 = xpcall(function() error("boomD2") end, function(m) return { 1, 2 } end)
print("D2", ok_d2, type(err_d2), #err_d2)

-- E: a handler that itself errors is called AGAIN with its own error
-- object (PUC luaG_errormsg recursion); the last successful result wins.
local calls = 0
local ok_e, err_e = xpcall(function() error("origE") end, function(m)
    calls = calls + 1
    if calls < 3 then error("e" .. calls) end
    return "E:" .. m .. "/" .. calls
end)
print("E", ok_e, err_e, "calls=" .. calls)

-- F: a handler that always errors drives the recursion to the emergency
-- limit — the protected call ends with "error in error handling".
local ok_f, err_f = xpcall(function() error("origF") end, function(m)
    error("f:" .. m)
end)
print("F", ok_f, err_f)

-- G: xpcall(loop, loop) — the handler IS the failing target.
local function loop_g(m) error("loopG") end
local ok_g, err_g = xpcall(loop_g, loop_g)
print("G", ok_g, err_g)

-- H: deep recursion overflow inside the target — the handler still runs
-- (PUC grows the stack to ERRORSTACKSIZE for it) and its result is used
-- as-is, with NO position prefix re-applied to it.
local ok_h, err_h
do
    local function deep(n)
        if n <= 0 then error("bottomH") end
        return deep(n - 1) + 1
    end
    local h_calls = 0
    ok_h, err_h = xpcall(function() return deep(200000) end, function(m)
        h_calls = h_calls + 1
        return "H"
    end)
    print("H", ok_h, err_h, "calls=" .. h_calls)
end

-- I: pcall INSIDE a message handler catches the real error it caught
-- (PUC finishpcall: errerr is transported as an object, not inferred from
-- handler depth).
local ok_i, err_i = xpcall(function() error("origI") end, function(m)
    local ok2, err2 = pcall(function() error("innerI") end)
    return "I:" .. tostring(ok2) .. "/" .. tostring(err2)
end)
print("I", ok_i, err_i)

-- I2: xpcall INSIDE a message handler arms and runs its own handler.
local ok_i2, err_i2 = xpcall(function() error("origI2") end, function(m)
    local ok2, err2 = xpcall(function() error("innerI2") end, function(mm)
        return "IH:" .. mm
    end)
    return "I2:" .. tostring(ok2) .. "/" .. tostring(err2)
end)
print("I2", ok_i2, err_i2)

-- I3: a handler that always errors makes its xpcall return the errerr
-- OBJECT ("error in error handling"); an outer pcall observes the pair.
local ok_i3, r1_i3, r2_i3 = pcall(function()
    return xpcall(function() error("origI3") end, function(m)
        error("handlerI3")
    end)
end)
print("I3", ok_i3, r1_i3, r2_i3)

-- J: the handler runs exactly ONCE per PUC error event — the operand
-- annotation ("(local 't')") is composed at the single raise site
-- (PUC luaG_typeerror/varinfo), not observed as a separate raise.
local j_calls = 0
local ok_j, err_j = xpcall(function()
    local t = nil
    return t.x
end, function(m)
    j_calls = j_calls + 1
    return m
end)
print("J", ok_j, err_j, "calls=" .. j_calls)

local j2_calls = 0
local ok_j2, err_j2 = xpcall(function()
    local not_a_function = 42
    return not_a_function()
end, function(m)
    j2_calls = j2_calls + 1
    return m
end)
print("J2", ok_j2, err_j2, "calls=" .. j2_calls)

-- K: a coroutine suspended inside a fast-path xpcall keeps its armed
-- handler parked; the error AFTER resume still runs the handler with the
-- frames intact.
local co_k = coroutine.create(function()
    local ok, err = xpcall(function()
        coroutine.yield("yK")
        error("afterK")
    end, function(m) return "K:" .. m end)
    coroutine.yield(tostring(ok) .. "/" .. tostring(err))
end)
print("K1", coroutine.resume(co_k))
print("K2", coroutine.resume(co_k))

-- L: assert() raises through the armed handler at the throw site (PUC
-- luaB_assert → luaB_error → luaG_errormsg).
local ok_l, err_l = xpcall(function()
    assert(false, "boomL")
end, function(m) return "L:" .. m end)
print("L", ok_l, err_l)

-- M: the handler's result is NOT re-prefixed with position info when it
-- crosses the protected boundary (PUC bakes position only at the raise).
local ok_m, err_m = xpcall(function() error("boomM") end, function(m)
    return "M"
end)
print("M", ok_m, err_m)
