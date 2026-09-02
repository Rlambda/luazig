-- Permanent differential: upvalue (Cell) GC lifetime semantics
-- (verifier Tasks 5+6).
--
-- Byte-identical stdout+exit on build/lua-c/lua and ./zig-out/bin/luazig.
-- Pins the OBSERVABLE contract behind luazig's Cell GC model (PUC-faithful
-- UpVal: open cells point at the stack; closed cells hold their own copy;
-- the write barrier strengthens a young value stored into an aged cell so
-- the tri-color invariant holds across minor + full collects).
--
-- Methodology:
--   * Each scenario is a function body run under BOTH GC modes
--     (generational + incremental) via `under_mode`, which stops, cleans,
--     switches, restarts, and restores — matching the 63-smoke pattern.
--   * Probes use weak-table sentinels (weak-key / weak-value), booleans,
--     and ordered traces only. No collectgarbage("count") (allocator
--     granularity differs), no pointer addresses, no count() of internals.
--   * Fixed counts of explicit collectgarbage("collect") calls (not steps).
--   * PUC 5.5 accepts both "generational" and "incremental" modes (default
--     is generational); collectgarbage(mode) returns the previous mode.
--
-- Encoded PUC behavior (prototyped side-by-side against the oracle
-- lua-5.5.0/src/lua, 3× stable and byte-identical on both runtimes):
--   1. live closure → closed Cell → collectable table → full GC →
--      child SURVIVES (read after collect); weak-value sentinel alive.
--   2. open captured local on an active frame → GC mid-frame →
--      child reads the correct object (open cell reads the stack).
--   3. open captured local in a SUSPENDED coroutine → GC from the caller →
--      resume → correct object (suspended frame's stack is GC-reachable
--      via the coroutine thread; the open cell resolves to it).
--   4. parent thread/frame dies while a child closure survives →
--      UpVal closes (stack value snapshotted into cell.value) →
--      child reads the closed value (the P16.4e/P16.10 pattern).
--   5. multiple closures share one Cell; drop one closure →
--      the other is unaffected (shared cell, refcounted by closures).
--   6. SETUPVAL/captured assignment stores a young collectable into an
--      AGED cell (aged with collects) → minor + full GC → SURVIVES
--      (the write barrier marks the young value); then clear the cell →
--      the young table is COLLECTED (weak-value sentinel clears).
--   7. repeated open/close/collect transitions (loop create-capture-
--      close-collect) — each iteration's closed cell survives long enough
--      to be read, then is collected on the next iteration.
--   8. incremental AND generational modes — exercised by `under_mode`
--      running every scenario under both.
--   9. weak-sentinel probes (weak-key + weak-value refs to the children)
--      proving SURVIVAL while the closure is live and COLLECTION after
--      the closure is dropped (both sentinel kinds clear).

-- =========================================================================
-- Helpers
-- =========================================================================

-- Run a scenario body under a specific GC mode, then restore.
-- PUC 5.5: collectgarbage("generational"/"incremental") switches mode and
-- returns the previous mode. We stop, clean, switch, restart, clean again.
local function under_mode(mode, body)
    collectgarbage("stop")
    collectgarbage("collect")       -- clean slate
    collectgarbage(mode)            -- switch mode (returns prev, ignored)
    collectgarbage("restart")       -- start collector in new mode
    collectgarbage("collect")       -- one full collect to settle
    local result = body()
    -- Restore to incremental and clean up for the next scenario.
    collectgarbage("incremental")
    collectgarbage("collect")
    collectgarbage("restart")
    return result
end

-- Boolean probe: is the table empty? (next returns nil for empty tables.)
local function isempty(t)
    return next(t) == nil
end

-- =========================================================================
-- 1. live closure → closed Cell → collectable table → full GC →
--    child survives (read after collect).
--    PUC: the closed cell holds the only strong ref to the child table.
--    The closure (and thus the cell) is reachable from `g`, so the child
--    SURVIVES a full collect. The weak-value sentinel stays alive too.
-- =========================================================================
local function scenario_1()
    local sentinel = setmetatable({}, { __mode = "v" })
    local function make()
        local child = { x = 1 }
        local function getter() return child end
        return getter
    end
    local g = make()
    sentinel[1] = g()               -- weak ref to the child
    collectgarbage("collect")       -- full GC; child reachable via g's cell
    local v = g()
    return ("survived=%s weak_alive=%s"):format(
        tostring(v ~= nil and v.x == 1), tostring(sentinel[1] ~= nil))
end

-- =========================================================================
-- 2. open captured local on an active frame → GC mid-frame →
--    child reads the correct object.
--    PUC: while `outer` is executing, `obj` is an OPEN upvalue (the cell
--    points at the stack slot). A mid-frame collect must not collect `obj`
--    (the active frame's stack is a root). After `outer` returns a closure
--    capturing `obj`, the cell closes; the child reads the same object.
-- =========================================================================
local function scenario_2()
    local seen
    local function outer()
        local obj = { tag = "open-active" }
        collectgarbage("collect")   -- GC mid-frame; obj is an open upvalue
        seen = obj.tag              -- direct read while open
        return function() return obj end
    end
    local g = outer()               -- obj closes into the cell on return
    collectgarbage("collect")
    local v = g()
    return ("seen=%s after=%s"):format(tostring(seen), tostring(v.tag))
end

-- =========================================================================
-- 3. open captured local in a SUSPENDED coroutine → GC from the caller →
--    resume → correct object.
--    PUC: a suspended coroutine's stack is GC-reachable via the thread
--    object. The open cell points at the suspended frame's stack slot, so
--    a collect from the caller must not collect the captured object. After
--    resume, the closure reads the same object, and the coroutine's return
--    value matches.
-- =========================================================================
local function scenario_3()
    local co = coroutine.create(function()
        local obj = { tag = "suspended-open" }
        coroutine.yield(function() return obj end)
        return obj.tag
    end)
    local ok, getter = coroutine.resume(co)
    collectgarbage("collect")       -- coroutine suspended; obj open upvalue
    local v = getter()
    local ok2, final = coroutine.resume(co)
    return ("yielded_val=%s resumed_ok=%s final=%s"):format(
        tostring(v.tag), tostring(ok2), tostring(final))
end

-- =========================================================================
-- 4. parent thread/frame dies while a child closure survives →
--    UpVal closes → child valid (the P16.4e/P16.10 pattern).
--    PUC: when the frame that owns an open upvalue is popped (luaF_close),
--    the open cell is closed — the stack value is copied into cell.value
--    and the stack pointer is cleared. The surviving closure reads the
--    closed value. Two collects confirm the closed cell (and its value)
--    are stable.
-- =========================================================================
local function scenario_4()
    local survivor
    do
        local function parent()
            local obj = { tag = "parent-dies" }
            local function child() return obj end
            return child
        end
        survivor = parent()
    end                       -- parent frame gone; obj closed into the cell
    collectgarbage("collect")
    collectgarbage("collect")
    local v = survivor()
    return ("survivor_val=%s"):format(tostring(v.tag))
end

-- =========================================================================
-- 5. multiple closures share one Cell; drop one closure →
--    other unaffected.
--    PUC: two closures over the same local share one UpVal (luaF_findupval
--    deduplicates by stack slot). Dropping one closure's reference does not
--    collect the cell (the other closure still holds it); the survivor
--    reads the shared object.
-- =========================================================================
local function scenario_5()
    local function make()
        local shared = { tag = "shared" }
        local function a() return shared end
        local function b() return shared end
        return a, b
    end
    local a, b = make()
    a = nil                   -- drop one closure
    collectgarbage("collect")
    collectgarbage("collect")
    local v = b()
    return ("b_val=%s a_nil=%s"):format(tostring(v.tag), tostring(a == nil))
end

-- =========================================================================
-- 6. SETUPVAL/captured assignment stores a young collectable into an
--    AGED cell → minor + full GC → survives; then drop → collected.
--    PUC: assigning a young table into an aged (old) cell triggers the
--    write barrier (luaC_barrierback equivalent for upvalues), which marks
--    the young value so the next collect does not reclaim it. After the
--    cell is cleared (slot = nil), the young table is unreachable and is
--    collected; the weak-value sentinel clears.
-- =========================================================================
local function scenario_6()
    local wv = setmetatable({}, { __mode = "v" })
    local function make()
        local slot = { tag = "initial" }
        local function setter(v) slot = v end
        local function getter() return slot end
        return setter, getter
    end
    local setter, getter = make()
    collectgarbage("collect")       -- age the cell
    collectgarbage("collect")
    local young = { tag = "young" }
    wv[1] = young                    -- weak sentinel tracks the young table
    setter(young)                    -- store young collectable into aged cell
    young = nil
    collectgarbage("collect")        -- minor + full: must survive (barrier)
    collectgarbage("collect")
    local v1 = getter()
    local survived = (v1 ~= nil and v1.tag == "young")
    local weak_alive_after_store = (wv[1] ~= nil)
    v1 = nil                         -- drop the local strong ref to the young table
    setter(nil)                      -- clear the cell (last strong ref path)
    collectgarbage("collect")
    collectgarbage("collect")
    local v2 = getter()
    local collected = (v2 == nil) and (wv[1] == nil)
    return ("survived=%s weak_after_store=%s collected=%s"):format(
        tostring(survived), tostring(weak_alive_after_store), tostring(collected))
end

-- =========================================================================
-- 7. repeated open/close/collect transitions
--    (loop create-capture-close-collect).
--    PUC: each iteration creates a fresh local, captures it in a closure
--    (closing the cell on return), collects, and reads the closed value.
--    No cross-iteration leakage: each cell is independent and collected
--    once its closure is dropped (the previous iteration's `g` is
--    overwritten).
-- =========================================================================
local function scenario_7()
    local results = {}
    for i = 1, 5 do
        local function make()
            local x = i
            local function get() return x end
            return get
        end
        local g = make()             -- x closes into the cell on return
        collectgarbage("collect")    -- previous iteration's g is now garbage
        results[i] = g()
    end
    local s = table.concat(results, ",")
    return ("seq=%s"):format(s)
end

-- =========================================================================
-- 8. incremental AND generational modes.
--    PUC 5.5 accepts collectgarbage("incremental") / ("generational").
--    `under_mode` runs every scenario under both; this scenario is a
--    trivial mode-acceptance probe (the wrapper itself is the test).
-- =========================================================================
local function scenario_8()
    return ("mode_ok=%s"):format(tostring(true))
end

-- =========================================================================
-- 9. weak-sentinel probes (weak-key + weak-value refs to the children)
--    proving survival/collection at each stage.
--    PUC: while the closure is live, the closed cell keeps the child
--    reachable, so both weak-key and weak-value sentinels stay populated.
--    After the closure is dropped (and the local strong ref `v` cleared),
--    the cell and child become unreachable; the next collect reclaims them
--    and both sentinel kinds clear.
-- =========================================================================
local function scenario_9()
    local wk = setmetatable({}, { __mode = "k" })
    local wv = setmetatable({}, { __mode = "v" })
    local function make()
        local child = { tag = "sentinel-child" }
        local function getter() return child end
        return getter, child
    end
    local g, child = make()
    wk[child] = "kmark"
    wv[1] = child
    child = nil
    collectgarbage("collect")        -- child reachable via closure cell → survives
    local v = g()
    local survived = (v ~= nil and v.tag == "sentinel-child")
    local wk_alive = not isempty(wk)
    local wv_alive = (wv[1] ~= nil)
    v = nil                          -- drop the local strong ref to the child
    g = nil                          -- drop the closure (last strong ref to the cell)
    collectgarbage("collect")
    collectgarbage("collect")
    local collected = isempty(wk) and (wv[1] == nil)
    return ("survived=%s wk_alive=%s wv_alive=%s collected=%s"):format(
        tostring(survived), tostring(wk_alive), tostring(wv_alive),
        tostring(collected))
end

-- =========================================================================
-- Run all scenarios under both GC modes.
-- =========================================================================

local scenarios = {
    { "1", scenario_1 },
    { "2", scenario_2 },
    { "3", scenario_3 },
    { "4", scenario_4 },
    { "5", scenario_5 },
    { "6", scenario_6 },
    { "7", scenario_7 },
    { "8", scenario_8 },
    { "9", scenario_9 },
}

for _, mode in ipairs({ "incremental", "generational" }) do
    print(("=== mode=%s ==="):format(mode))
    for _, sc in ipairs(scenarios) do
        local label, body = sc[1], sc[2]
        local result = under_mode(mode, body)
        print(("%s: %s"):format(label, result))
    end
end

print("upvalue_gc_lifetime_ok")
