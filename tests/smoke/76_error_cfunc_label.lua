-- 76_error_cfunc_label.lua — P16.36 Cut 1 (T2.3): the raiser's C-frame
-- label in tracebacks is derived STRUCTURALLY at capture time
-- (writeSyntheticTopCFrame: PUC pushfuncname — the name comes from the
-- caller's calling instruction, with a _G search fallback and "?"),
-- replacing the persistent Vm.err_cfunc_label that leaked across
-- recovered errors and coroutine switches.
--
-- Differential smoke: byte-identical output expected under PUC Lua 5.5
-- and luazig. Assertions use string.find on the traceback returned by
-- debug.traceback handlers (the traceback captured at the fault point),
-- so known pre-existing divergences in the hidden-C-frame walk (frames
-- BELOW the raiser) do not affect the comparison.

-- A: _G fallback label — xpcall's argerror raised while xpcall is called
-- from a C frame (the outer xpcall): no name from code, so pushfuncname
-- falls back to the _G search: "[C]: in function 'xpcall'".
local ok_a, tb_a = xpcall(xpcall, debug.traceback, print, "not-a-function")
print("A", ok_a, tb_a:find("[C]: in function 'xpcall'", 1, true) ~= nil)

-- B: direct-call label + no stale label from a prior RECOVERED error()
-- (the T2.3 leak: the old persistent label showed "global 'error'").
pcall(function() error("prior-plain", 0) end)
local ok_b, tb_b = xpcall(function()
    return xpcall(print, "not-a-function")
end, debug.traceback)
print("B", ok_b,
    tb_b:find("[C]: in global 'xpcall'", 1, true) ~= nil,
    tb_b:find("global 'error'", 1, true) ~= nil)

-- C: no stale label from a prior RECOVERED assert() (old leak: "global
-- 'assert'" misattributed to the later xpcall argerror).
pcall(function() assert(false) end)
local ok_c, tb_c = xpcall(function()
    return xpcall(print, "not-a-function")
end, debug.traceback)
print("C", ok_c,
    tb_c:find("[C]: in global 'xpcall'", 1, true) ~= nil,
    tb_c:find("global 'assert'", 1, true) ~= nil)

-- D: no cross-thread leak — a coroutine dies with error(), then the
-- caller's xpcall argerror is attributed to xpcall, not the coroutine's
-- error (old leak: the dying thread's label survived the switch).
local co = coroutine.create(function() error("in-co", 0) end)
local ok_resume = coroutine.resume(co)
local ok_d, tb_d = xpcall(function()
    return xpcall(print, "not-a-function")
end, debug.traceback)
print("D", ok_resume, ok_d,
    tb_d:find("[C]: in global 'xpcall'", 1, true) ~= nil,
    tb_d:find("global 'error'", 1, true) ~= nil)

-- E: field attribution — io.open's argerror called directly from a Lua
-- frame shows "[C]: in field 'open'" (name from the GETFIELD instruction).
local ok_e, tb_e = xpcall(function()
    return io.open("x", "badmode")
end, debug.traceback)
print("E", ok_e, tb_e:find("[C]: in field 'open'", 1, true) ~= nil)

-- F: error() attribution preserved — "[C]: in global 'error'".
local ok_f, tb_f = xpcall(function() error("boom", 0) end, debug.traceback)
print("F", ok_f, tb_f:find("[C]: in global 'error'", 1, true) ~= nil)

-- G: argerror message position (luaL_where(1) semantics): a direct call
-- from a Lua frame carries the caller's "source:line:" prefix; the same
-- argerror raised through pcall (a C caller) carries none.
local ok_g1, err_g1 = xpcall(function()
    return xpcall(print, "not-a-function")
end, function(m) return "M:" .. tostring(m) end)
print("G1", ok_g1, err_g1)
local ok_g2, err_g2 = pcall(xpcall, print, "not-a-function")
print("G2", ok_g2, err_g2)
