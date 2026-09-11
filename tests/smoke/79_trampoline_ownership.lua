-- 79_trampoline_ownership.lua — P16.38 Cut 1 (T12): the coroutine
-- trampoline's switch eligibility is owned by the drive iteration
-- (requesting thread == trampoline drive thread AND boundary == 0).
-- A coroutine.resume reached from ANY nested host-recursive Lua context
-- (table.sort comparator, __lt metamethod under sort, coroutine.wrap
-- iterator) runs synchronously — exactly PUC's nested
-- luaB_coresume → lua_resume — instead of unwinding the native Zig-stack
-- state to the trampoline ("coroutine trampoline lost continuation").
-- Resumes from ITERATIVE continuations on the drive thread (pcall-wrapped
-- resume, gsub replacement function) keep chaining through the trampoline.
--
-- Differential smoke: byte-identical output expected under PUC Lua 5.5
-- and luazig.

-- ── A: t12 shape — comparator resumes a yielding coroutine ──
local inner = coroutine.create(function()
    coroutine.yield("inner-y")
    return "inner-done"
end)
local outer = coroutine.create(function()
    local once = false
    local t = {2, 1}
    table.sort(t, function(a, b)
        if not once then
            once = true
            print("A-yieldable", coroutine.isyieldable())
            print("A-inner-resume", coroutine.resume(inner))
            print("A-inner-status", coroutine.status(inner))
        end
        return a < b
    end)
    print("A-sorted", table.concat(t, ","))
    return "outer-done"
end)
print("A-outer-resume", coroutine.resume(outer))
print("A-outer-status", coroutine.status(outer))
print("A-inner-status-final", coroutine.status(inner))

-- ── B: child returns immediately (no yield) inside the comparator ──
local b_child = coroutine.create(function() return "b-done", 42 end)
local b_outer = coroutine.create(function()
    local once = false
    local t = {3, 1, 2}
    table.sort(t, function(a, b)
        if not once then
            once = true
            print("B-child-resume", coroutine.resume(b_child))
        end
        return a < b
    end)
    return table.concat(t, ",")
end)
print("B-outer-resume", coroutine.resume(b_outer))

-- ── C: child errors inside the comparator; pcall recovers; sort completes ──
local c_child = coroutine.create(function() error("c-boom") end)
local c_outer = coroutine.create(function()
    local once = false
    local t = {2, 1}
    table.sort(t, function(a, b)
        if not once then
            once = true
            print("C-child-resume", coroutine.resume(c_child))
            print("C-child-status", coroutine.status(c_child))
        end
        return a < b
    end)
    return table.concat(t, ",")
end)
print("C-outer-resume", coroutine.resume(c_outer))

-- ── D: inner resumed twice inside the comparator (yield, then finish) ──
local d_child = coroutine.create(function()
    coroutine.yield("d-y1")
    coroutine.yield("d-y2")
    return "d-done"
end)
local d_outer = coroutine.create(function()
    local once = false
    local t = {2, 1}
    table.sort(t, function(a, b)
        if not once then
            once = true
            print("D-r1", coroutine.resume(d_child))
            print("D-r2", coroutine.resume(d_child))
            print("D-r3", coroutine.resume(d_child))
            print("D-status", coroutine.status(d_child))
        end
        return a < b
    end)
    return table.concat(t, ",")
end)
print("D-outer-resume", coroutine.resume(d_outer))

-- ── E: nested pcall around the inner resume inside the comparator ──
local e_child = coroutine.create(function()
    coroutine.yield("e-y")
    return "e-done"
end)
local e_outer = coroutine.create(function()
    local once = false
    local t = {2, 1}
    table.sort(t, function(a, b)
        if not once then
            once = true
            print("E-pcall", pcall(coroutine.resume, e_child))
            print("E-status", coroutine.status(e_child))
        end
        return a < b
    end)
    return table.concat(t, ",")
end)
print("E-outer-resume", coroutine.resume(e_outer))

-- ── F: the comparator still cannot yield after the child resume — the
--      C-call boundary is unchanged by the nested synchronous resume ──
local f_child = coroutine.create(function() return "f-done" end)
local f_outer = coroutine.create(function()
    local t = {2, 1}
    table.sort(t, function(a, b)
        print("F-child-resume", coroutine.resume(f_child))
        coroutine.yield("must-not-suspend")
        return a < b
    end)
    return "unreachable"
end)
print("F-outer-resume", coroutine.resume(f_outer))
print("F-outer-status", coroutine.status(f_outer))

-- ── G: the outer coroutine yields AFTER the sort and is resumed again ──
local g_child = coroutine.create(function() return "g-done" end)
local g_outer = coroutine.create(function()
    local once = false
    local t = {2, 1}
    table.sort(t, function(a, b)
        if not once then
            once = true
            print("G-child-resume", coroutine.resume(g_child))
        end
        return a < b
    end)
    coroutine.yield("g-after-sort")
    return "g-final"
end)
print("G-r1", coroutine.resume(g_outer))
print("G-r2", coroutine.resume(g_outer))
print("G-status", coroutine.status(g_outer))

-- ── H: gsub replacement function resumes a yielding coroutine — the
--      gsub continuation is ITERATIVE on the drive thread, so the resume
--      must keep chaining through the trampoline (P16.36 Cut 3 model) ──
local h_child = coroutine.create(function()
    coroutine.yield("h-y")
    return "h-done"
end)
local h_outer = coroutine.create(function()
    local out = string.gsub("ab", "%a", function(ch)
        print("H-child-resume", coroutine.resume(h_child))
        return ch
    end)
    return out
end)
print("H-outer-resume", coroutine.resume(h_outer))
print("H-child-status", coroutine.status(h_child))

-- ── I: __lt metamethod comparator resumes a yielding coroutine — the
--      metamethod runs host-recursively under builtinTableSort, so the
--      resume runs synchronously (nested lua_resume) ──
local i_child = coroutine.create(function()
    coroutine.yield("i-y")
    return "i-done"
end)
local i_outer = coroutine.create(function()
    local once = false
    local mt = {
        __lt = function(x, y)
            if not once then
                once = true
                print("I-child-resume", coroutine.resume(i_child))
                print("I-status", coroutine.status(i_child))
            end
            return rawget(x, "v") < rawget(y, "v")
        end,
    }
    local a = setmetatable({v = 2}, mt)
    local b = setmetatable({v = 1}, mt)
    local t = {a, b}
    table.sort(t)
    return tostring(rawget(t[1], "v")) .. "," .. tostring(rawget(t[2], "v"))
end)
print("I-outer-resume", coroutine.resume(i_outer))

-- ── J: nested graph — comparator resumes B; B's body resumes C; C yields
--      inside B's synchronous run (B itself is non-yieldable, but C is
--      yieldable: lua_resume inherits only the LOWER nCcalls bits) ──
local j_c = coroutine.create(function()
    coroutine.yield("j-c-y")
    return "j-c-done"
end)
local j_b = coroutine.create(function()
    print("J-c-resume", coroutine.resume(j_c))
    print("J-c-status", coroutine.status(j_c))
    return "j-b-done"
end)
local j_a = coroutine.create(function()
    local once = false
    local t = {2, 1}
    table.sort(t, function(x, y)
        if not once then
            once = true
            print("J-b-resume", coroutine.resume(j_b))
            print("J-b-status", coroutine.status(j_b))
        end
        return x < y
    end)
    return table.concat(t, ",")
end)
print("J-outer-resume", coroutine.resume(j_a))

-- ── K: coroutine.wrap iterator called from a comparator — the wrap body
--      runs synchronously through builtinCoroutineResume's fallback ──
local k_gen = coroutine.wrap(function()
    coroutine.yield("k-y1")
    coroutine.yield("k-y2")
    return "k-end"
end)
local k_outer = coroutine.create(function()
    local once = false
    local t = {2, 1}
    table.sort(t, function(a, b)
        if not once then
            once = true
            print("K-w1", k_gen())
            print("K-w2", k_gen())
        end
        return a < b
    end)
    return table.concat(t, ",")
end)
print("K-outer-resume", coroutine.resume(k_outer))

-- ── L: pcall-wrapped resume in the drive body — the protected frame is
--      ITERATIVE on the drive thread (boundary 0), so the resume chains
--      through the trampoline even under pcall ──
local l_child = coroutine.create(function()
    coroutine.yield("l-y")
    return "l-done"
end)
local l_outer = coroutine.create(function()
    print("L-pcall-yield", pcall(coroutine.resume, l_child))
    print("L-pcall-finish", pcall(coroutine.resume, l_child))
    print("L-status", coroutine.status(l_child))
    coroutine.yield("l-outer-y")
    return "l-outer-done"
end)
print("L-r1", coroutine.resume(l_outer))
print("L-r2", coroutine.resume(l_outer))
