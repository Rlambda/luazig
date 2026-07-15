-- Microbenchmarks for luazig performance profiling.
-- Each workload is a tight loop isolating one VM subsystem.
-- Usage: luazig --vm=bc tools/microbench.lua [label]
-- Prints: label\telapsed_seconds

local function bench(label, n, fn)
    -- Warmup
    fn(math.max(1, math.floor(n / 100)))
    local start = os.clock()
    fn(n)
    local elapsed = os.clock() - start
    io.write(string.format("%s\t%.6f\n", label, elapsed))
end

local N = 50000000

-- 1. Integer arithmetic
bench("int_arith", N, function(n)
    local s = 0
    for i = 1, n do s = s + i end
    return s
end)

-- 2. Global access + arithmetic
bench("global_arith", N, function(n)
    g_count = 0
    for i = 1, n do g_count = g_count + i end
    return g_count
end)

-- 3. Branch loop
bench("branch_loop", N, function(n)
    local s = 0
    for i = 1, n do
        if i % 2 == 0 then s = s + 1 else s = s - 1 end
    end
    return s
end)

-- 4. Lua calls
local function inc(x) return x + 1 end
bench("lua_calls", N // 10, function(n)
    local s = 0
    for i = 1, n do s = inc(s) end
    return s
end)

-- 5. Array table access
local arr = {}
for i = 1, 10000 do arr[i] = i end
bench("array_access", N // 10, function(n)
    local s = 0
    for i = 1, n do s = arr[(i % 10000) + 1] end
    return s
end)

-- 6. Integer hash table access
local ht = {}
for i = 1, 10000 do ht[i * 100] = i end
bench("hash_access", N // 10, function(n)
    local s = 0
    for i = 1, n do s = ht[((i % 10000) + 1) * 100] end
    return s
end)

-- 7. Temporary table allocation
bench("temp_table_alloc", N // 100, function(n)
    for i = 1, n do local t = {1, 2, 3} end
end)

-- 8. String-heavy loop
bench("string_loop", N // 100, function(n)
    local s = ""
    for i = 1, n do s = tostring(i) .. ":" end
    return s
end)

-- 9. Coroutine resume/yield
local co
do
    local function yielder()
        while true do coroutine.yield(42) end
    end
    co = coroutine.create(yielder)
end
bench("coroutine_yield", N // 100, function(n)
    for i = 1, n do coroutine.resume(co) end
end)

-- 10. Dynamic load()
local chunk_src = "return function(n) local s = 0 for i = 1, n do s = s + i end return s end"
bench("dynamic_load", N // 1000, function(n)
    for i = 1, n do
        local f = assert(load(chunk_src))()
        _ = f(100)
    end
end)

io.write("done\n")
