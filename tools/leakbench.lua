-- leakbench.lua — memory leak detection for luazig.
-- Tests all major Lua concepts for alloc/dealloc cycles.
-- Each test: GC twice → baseline → allocate N → GC twice → measure delta.
-- Usage: luazig tools/leakbench.lua
-- Output: name\tbefore_kb\tafter_kb\tleaked_kb\n

local N_LARGE = 10000
local N_SMALL = 1000

local function leaktest(name, n, fn)
    -- Two GCs for finalizers (PUC luaC_runtilstate convention)
    collectgarbage("collect")
    collectgarbage("collect")
    local before = collectgarbage("count")

    fn(n)

    collectgarbage("collect")
    collectgarbage("collect")
    local after = collectgarbage("count")

    local leaked = after - before
    local status = leaked < 1.0 and "OK" or "LEAK"
    io.write(string.format("%-25s\t%d\t%8.1f\t%8.1f\t%8.1f\t%s\n",
        name, n, before, after, leaked, status))
end

-- ── Tables ──────────────────────────────────────────────────────────────

leaktest("table_empty", N_LARGE, function(n)
    for i = 1, n do local t = {} end
end)

leaktest("table_array", N_LARGE, function(n)
    for i = 1, n do local t = {1,2,3,4,5,6,7,8,9,10} end
end)

leaktest("table_hash", N_LARGE, function(n)
    for i = 1, n do local t = {a=1,b=2,c=3,d=4,e=5} end
end)

leaktest("table_nested", N_SMALL, function(n)
    for i = 1, n do
        local t = { a = { b = { c = { d = {} } } } }
    end
end)

leaktest("table_cycle", N_SMALL, function(n)
    for i = 1, n do
        local t = {}
        t.self = t
    end
end)

leaktest("table_grow_shrink", N_SMALL, function(n)
    for i = 1, n do
        local t = {}
        for j = 1, 100 do t[j] = j end
        for j = 1, 100 do t[j] = nil end
    end
end)

-- ── Strings ─────────────────────────────────────────────────────────────

leaktest("string_create", N_LARGE, function(n)
    for i = 1, n do local s = tostring(i) .. "_test" end
end)

leaktest("string_concat", N_LARGE, function(n)
    for i = 1, n do local s = "x" .. tostring(i) end
end)

leaktest("string_unique", N_LARGE, function(n)
    -- Each string is unique → can't be interned → should be GC'd
    for i = 1, n do local s = string.rep("x", 50 + (i % 10)) .. tostring(i) end
end)

leaktest("string_long", N_SMALL, function(n)
    -- Long strings (>40 bytes) are not interned
    for i = 1, n do local s = string.rep("a", 100) .. tostring(i) end
end)

-- ── Closures ────────────────────────────────────────────────────────────

leaktest("closure_simple", N_LARGE, function(n)
    for i = 1, n do local f = function() return i end end
end)

leaktest("closure_upvalue", N_LARGE, function(n)
    for i = 1, n do
        local x = i
        local f = function() return x end
    end
end)

leaktest("closure_shared_uv", N_SMALL, function(n)
    for i = 1, n do
        local x = 0
        local f = function() x = x + 1; return x end
        local g = function() return x * 2 end
    end
end)

-- ── Coroutines ──────────────────────────────────────────────────────────

leaktest("coroutine_create", N_SMALL, function(n)
    for i = 1, n do
        local co = coroutine.create(function() coroutine.yield(1) end)
        coroutine.resume(co)
    end
end)

leaktest("coroutine_yield", N_LARGE, function(n)
    local co = coroutine.create(function()
        while true do coroutine.yield() end
    end)
    for i = 1, n do coroutine.resume(co) end
end)

-- ── Dynamic load ────────────────────────────────────────────────────────

leaktest("load_chunk", N_SMALL, function(n)
    for i = 1, n do local f = load("return 1") end
end)

leaktest("load_function", N_SMALL, function(n)
    local src = "return function() local x = 0; return x + 1 end"
    for i = 1, n do
        local f = assert(load(src))()
    end
end)

-- ── Metatables / finalizers ─────────────────────────────────────────────

leaktest("metatable_set", N_LARGE, function(n)
    local mt = { __index = function() return 0 end }
    for i = 1, n do setmetatable({}, mt) end
end)

leaktest("metatable_gc", N_SMALL, function(n)
    local mt = { __gc = function() end }
    for i = 1, n do setmetatable({}, mt) end
end)

-- ── Error handling ──────────────────────────────────────────────────────

leaktest("pcall_error", N_LARGE, function(n)
    for i = 1, n do pcall(error, "test") end
end)

leaktest("pcall_recover", N_SMALL, function(n)
    for i = 1, n do
        local ok, err = pcall(function()
            error("msg_" .. tostring(i))
        end)
    end
end)

-- ── Function calls ──────────────────────────────────────────────────────

leaktest("deep_call", N_SMALL, function(n)
    local function rec(x)
        if x > 0 then return rec(x - 1) end
        return x
    end
    for i = 1, n do rec(50) end
end)

leaktest("vararg_call", N_LARGE, function(n)
    local function va(...)
        return select("#", ...)
    end
    for i = 1, n do va(1,2,3,4,5,6,7,8,9,10) end
end)

-- ── Mixed workloads ─────────────────────────────────────────────────────

leaktest("mixed_alloc", N_SMALL, function(n)
    for i = 1, n do
        local t = { tostring(i), i * 2 }
        local s = "key_" .. i
        t[s] = function() return i end
    end
end)

leaktest("table_key_rotation", N_SMALL, function(n)
    for i = 1, n do
        local t = {}
        for j = 1, 20 do t["key_" .. j] = j end
    end
end)

io.write("done\n")
