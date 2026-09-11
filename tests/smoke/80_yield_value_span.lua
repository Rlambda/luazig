-- 80_yield_value_span.lua — P16.38 Cut 3: yield values are a stack-span
-- view of the parked frame's call-arg registers (PUC lua_yieldk: the top
-- nresults slots of the yielding thread's stack; the resumer's auxresume
-- lua_xmoves them off, so they are never Lua-observable on the suspended
-- coroutine). Cut 3B: suspended_builtin_args is written only when no Lua
-- frame exists. T4.1: debug.getlocal/setlocal PUC parity on suspended
-- coroutines (empty C window at level 0, temp window bounded at the
-- callee's func slot).
--
-- Differential smoke: byte-identical output expected under PUC Lua 5.5
-- and luazig.

-- ── A: yield value counts 0/1/4/5 flow through resume exactly ──
local function pack_n(...)
    return table.pack(...).n
end
for _, n in ipairs{0, 1, 4, 5} do
    local vals = {}
    for i = 1, n do vals[i] = i end
    local co = coroutine.create(function()
        coroutine.yield(table.unpack(vals))
        return "a-done"
    end)
    local r = table.pack(coroutine.resume(co))
    print("A-count-" .. n, r.n, r[2], r[r.n])
    print("A-finish-" .. n, coroutine.resume(co))
end

-- ── B: many values (100) through a span — no truncation ──
local big = {}
for i = 1, 100 do big[i] = i end
local b_co = coroutine.create(function()
    coroutine.yield(table.unpack(big))
    return "b-done"
end)
local b_r = table.pack(coroutine.resume(b_co))
print("B-count", b_r.n, b_r[2], b_r[101])

-- ── C: objects survive GC while suspended (span targets are marked) ──
local c_co = coroutine.create(function()
    local keep = {}
    for i = 1, 10 do keep[i] = {k = i} end
    coroutine.yield(table.unpack(keep))
    return "c-done"
end)
local c_r = table.pack(coroutine.resume(c_co))
collectgarbage()
collectgarbage()
local alive = 0
for i = 2, c_r.n do
    if type(c_r[i]) == "table" and c_r[i].k == i - 1 then alive = alive + 1 end
end
print("C-alive", alive)
print("C-finish", coroutine.resume(c_co))

-- ── D: repeated yields with different counts on the same coroutine ──
local d_co = coroutine.create(function(x)
    x = coroutine.yield(x, "d1")
    x = coroutine.yield(x, "d2", "d2b")
    return x, "d-done"
end)
print("D-r1", coroutine.resume(d_co, 1))
print("D-r2", coroutine.resume(d_co, 2))
print("D-r3", coroutine.resume(d_co, 3))

-- ── E: resume args become yield results (multi-arg resume) ──
local e_co = coroutine.create(function()
    local a, b, c = coroutine.yield()
    return a + b + c
end)
coroutine.resume(e_co)
print("E-sum", coroutine.resume(e_co, 10, 20, 30))

-- ── F: wrap value flow ──
local f_gen = coroutine.wrap(function()
    for i = 1, 3 do
        coroutine.yield(i, i * 10)
    end
    return "f-end"
end)
print("F-1", f_gen())
print("F-2", f_gen())
print("F-3", f_gen())
print("F-4", f_gen())

-- ── G: debug.getlocal on a suspended coroutine — PUC parity ──
--      level 0 = the yield C frame: EMPTY window (nil for every n);
--      level 1 = the parked Lua frame: named locals only, temps hidden
--      below the yield call's callee slot ──
local g_co
g_co = coroutine.create(function()
    local g_a = 7
    local g_x = 8
    coroutine.yield("gv1", "gv2", "gv3")
    return "g-done"
end)
coroutine.resume(g_co)
for n = 1, 4 do
    local name, value = debug.getlocal(g_co, 0, n)
    print("G-level0-" .. n, name, value)
end
for n = 1, 4 do
    local name, value = debug.getlocal(g_co, 1, n)
    print("G-level1-" .. n, name, value)
end
print("G-finish", coroutine.resume(g_co))

-- ── H: debug.setlocal on a suspended coroutine — PUC parity ──
--      setlocal(co, 0, 1) reports "(C temporary)" but writes nothing
--      (PUC writes a dead slot the next resume overwrites); the span
--      values must stay intact. setlocal on a NAMED local still works ──
local h_co
h_co = coroutine.create(function()
    local h_keep = "orig"
    coroutine.yield("hv1", "hv2")
    return h_keep
end)
coroutine.resume(h_co)
print("H-set0-1", debug.setlocal(h_co, 0, 1, "MUT"))
print("H-set0-2", debug.setlocal(h_co, 0, 2, "MUT"))
print("H-set1-keep", debug.setlocal(h_co, 1, 1, "MUT"))
print("H-resume", coroutine.resume(h_co))

-- ── I: setlocal cannot corrupt span-held values via temp slots ──
--      (the temp window is bounded at the yield call's callee register,
--      so the yielded values are not addressable as locals) ──
local i_co
i_co = coroutine.create(function()
    coroutine.yield("iv1", "iv2", "iv3")
    return "i-done"
end)
coroutine.resume(i_co)
for n = 1, 3 do
    debug.setlocal(i_co, 1, n, "CORRUPT")
end
print("I-resume", coroutine.resume(i_co))

-- ── J: active-thread caller frame — call args above the callee are not
--      exposed as temporaries while the callee runs (PUC bounds the
--      window at ci->next->func) ──
local function j_outer(j_a, j_b)
    local j_x = 8
    local function j_inner()
        local n1, v1 = debug.getlocal(2, 1)
        local n2, v2 = debug.getlocal(2, 2)
        local n3, v3 = debug.getlocal(2, 3)
        local n4, v4 = debug.getlocal(2, 4)
        -- v4 is the closure j_inner: print its type, not its value
        -- (tostring(function) formatting differs pre-existing:
        -- zig "function: <name>" vs PUC "function: <addr>")
        print("J-inner", n1, v1, n2, v2, n3, v3, n4, type(v4))
    end
    j_inner(j_a, j_b)
    return "j-ok"
end
print("J-outer", j_outer(7, 1))

-- ── K: close a suspended coroutine holding a live span ──
local k_co = coroutine.create(function()
    coroutine.yield({k = 1}, "kv")
    return "k-done"
end)
coroutine.resume(k_co)
print("K-close", coroutine.close(k_co))
print("K-status", coroutine.status(k_co))

-- ── L: nested coroutines yielding through each other ──
local l_inner = coroutine.create(function()
    coroutine.yield("li1", "li2")
    return "li-done"
end)
local l_outer = coroutine.create(function()
    print("L-inner", coroutine.resume(l_inner))
    coroutine.yield("lo1")
    print("L-inner-finish", coroutine.resume(l_inner))
    return "lo-done"
end)
print("L-outer-1", coroutine.resume(l_outer))
print("L-outer-2", coroutine.resume(l_outer))
