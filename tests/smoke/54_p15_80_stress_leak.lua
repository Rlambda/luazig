-- P15.80: Stress test for coroutine yield/resume memory ownership.
-- Verifies that coroutine yield/resume in a tight loop do not leak memory.
-- Each iteration creates a coroutine, resumes it, it yields, resumes again.
-- If C-frame ownership is broken, RSS grows linearly with iteration count.

local function stress_coroutine_yield(n)
    for i = 1, n do
        local co = coroutine.create(function()
            coroutine.yield(1)
            coroutine.yield(2)
            return 3
        end)
        coroutine.resume(co)
        coroutine.resume(co)
        coroutine.resume(co)
    end
end

local function stress_pcall_coroutine(n)
    for i = 1, n do
        local co = coroutine.create(function()
            pcall(coroutine.yield, 42)
            return 99
        end)
        coroutine.resume(co)
        coroutine.resume(co)
    end
end

local function stress_tbc_coroutine(n)
    -- TBC + coroutine yield: __close runs on coroutine exit.
    for i = 1, n do
        local closed = false
        local co = coroutine.create(function()
            local v <close> = setmetatable({}, {__close = function() closed = true end})
            coroutine.yield(1)
            return 2
        end)
        coroutine.resume(co)
        coroutine.resume(co)
        assert(closed, "TBC not closed")
    end
end

stress_coroutine_yield(2000)
stress_pcall_coroutine(2000)
stress_tbc_coroutine(1000)

print("stress_ok")
