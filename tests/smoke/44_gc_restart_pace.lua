-- `collectgarbage("restart")` resets GC debt in PUC Lua. The next
-- allocations must therefore make collection progress fast enough to bring a
-- stopped-collector heap back near its live baseline; merely scheduling tiny
-- slices every many thousands of allocations makes this loop diverge.
collectgarbage("collect")
collectgarbage("collect")

local baseline = collectgarbage("count")
collectgarbage("stop")

repeat
    local dead = {}
until collectgarbage("count") > baseline * 3

collectgarbage("restart")

local allocations = 0
repeat
    local dead = {}
    allocations = allocations + 1
    assert(allocations < 100000, "automatic GC did not catch up after restart")
until collectgarbage("count") <= baseline * 2

print("gc-restart-pace-ok")
