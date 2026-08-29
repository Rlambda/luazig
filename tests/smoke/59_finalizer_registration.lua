-- Permanent differential finalizer registration lifecycle tests
-- (verifier P16.8 Tasks 4+5+6+7).
--
-- Byte-identical stdout on PUC 5.5 and luazig. Tests PUC-faithful
-- finalizer registration semantics:
--   * Registration is PERSISTENT: changing/removing the metatable never
--     deregisters. PUC luaC_checkfinalizer (lgc.c:1068) only adds to finobj;
--     it never removes. lua_setmetatable(nil) doesn't even call
--     checkfinalizer (lapi.c:964-996).
--   * The __gc metamethod is resolved DYNAMICALLY at finalization time:
--     GCTM (lgc.c:968) calls luaT_gettmbyobj on the CURRENT metatable.
--   * udata2finalize (lgc.c:947-960) clears FINALIZEDBIT BEFORE GCTM
--     resolves __gc — so even if mt is nil at finalization, the bit is
--     cleared and the object returns to normal allgc for collection.
--
-- No collectgarbage("count") (allocator granularity differs). Only
-- finalizer call counts and ordered event traces are printed.

local function countkeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Run `body` under both GC modes, restoring incremental mode afterwards.
local function both_modes(label, body)
    for _, mode in ipairs({ "generational", "incremental" }) do
        collectgarbage("collect")
        collectgarbage(mode)
        body(mode)
    end
    collectgarbage("collect")
    collectgarbage("incremental")
end

-- =========================================================================
-- A. register → setmetatable(nil) → drop → collect: finalizer NOT called.
--    PUC: registration persists; mt nil at finalization → GCTM looks up
--    __gc on nil mt → no callback. udata2finalize still clears the bit,
--    so the object is collected normally on the next cycle.
-- =========================================================================
both_modes("A", function(mode)
    local called = 0
    local obj = setmetatable({}, { __gc = function(self)
        called = called + 1
    end})
    setmetatable(obj, nil)  -- remove metatable (registration persists in PUC)
    obj = nil

    collectgarbage("collect")
    print("A", mode, "gc1 called=" .. called)
    collectgarbage("collect")
    print("A", mode, "gc2 called=" .. called)
end)

-- =========================================================================
-- B. mt1.__gc=f1 → setmt(mt1) → mt2.__gc=f2 → setmt(mt2) → drop → collect:
--    f2 runs (CURRENT method, dynamic resolution at finalization time).
-- =========================================================================
both_modes("B", function(mode)
    local order = {}
    local obj = setmetatable({}, { __gc = function()
        table.insert(order, "f1")
    end})
    setmetatable(obj, { __gc = function()
        table.insert(order, "f2")
    end})
    obj = nil

    collectgarbage("collect")
    print("B", mode, "gc1 order=" .. table.concat(order, ","))
    collectgarbage("collect")
    print("B", mode, "gc2 order=" .. table.concat(order, ","))
end)

-- =========================================================================
-- C. register with f1 → setmt(no-__gc mt) → setmt(mt with NEW __gc=f3)
--    BEFORE drop → collect: f3 runs.
--    Registration persisted through the no-__gc period; __gc resolved
--    dynamically from the CURRENT metatable at finalization time.
-- =========================================================================
both_modes("C", function(mode)
    local order = {}
    local obj = setmetatable({}, { __gc = function()
        table.insert(order, "f1")
    end})
    setmetatable(obj, {})  -- no __gc (registration persists)
    setmetatable(obj, { __gc = function()
        table.insert(order, "f3")
    end})
    obj = nil

    collectgarbage("collect")
    print("C", mode, "gc1 order=" .. table.concat(order, ","))
    collectgarbage("collect")
    print("C", mode, "gc2 order=" .. table.concat(order, ","))
end)

-- =========================================================================
-- D. register with __gc → setmt(no-__gc mt) → drop → collect:
--    finalizer NOT called (mt has no __gc at finalization time).
--    Registration persisted; udata2finalize cleared the bit; object
--    collected normally on the next cycle.
-- =========================================================================
both_modes("D", function(mode)
    local called = 0
    local obj = setmetatable({}, { __gc = function(self)
        called = called + 1
    end})
    setmetatable(obj, {})  -- no __gc (registration persists)
    obj = nil

    collectgarbage("collect")
    print("D", mode, "gc1 called=" .. called)
    collectgarbage("collect")
    print("D", mode, "gc2 called=" .. called)
end)

-- =========================================================================
-- E. Finalizer exactly once + resurrection/recollect doesn't re-call.
--    __gc stores self into a live registry table (resurrection). After
--    gc1 the object is alive via registry (finalizer ran exactly once).
--    After dropping the registry ref + more collects, the object is
--    collected and the finalizer is NOT called a second time.
-- =========================================================================
both_modes("E", function(mode)
    local gc_count = 0
    local registry = {}
    local weak = setmetatable({}, { __mode = "v" })
    local obj = setmetatable({ x = 42 }, { __gc = function(self)
        gc_count = gc_count + 1
        registry[1] = self  -- resurrect into a live table
    end})
    weak[1] = obj
    obj = nil

    collectgarbage("collect")
    print("E", mode, "gc1 gc_count=" .. gc_count
        .. " weak1=" .. tostring(weak[1])
        .. " reg_alive=" .. tostring(registry[1] ~= nil and registry[1].x == 42))
    collectgarbage("collect")
    print("E", mode, "gc2 gc_count=" .. gc_count
        .. " weak1=" .. tostring(weak[1])
        .. " reg_alive=" .. tostring(registry[1] ~= nil and registry[1].x == 42))
    registry[1] = nil  -- drop the resurrection ref
    collectgarbage("collect")
    print("E", mode, "gc3 gc_count=" .. gc_count
        .. " weak1=" .. tostring(weak[1])
        .. " reg_alive=" .. tostring(registry[1] ~= nil))
end)

-- =========================================================================
-- F. Re-registration after finalization: object finalized, resurrected,
--    then given a NEW __gc metatable → drop → collect: new finalizer runs.
--    PUC: after udata2finalize clears FINALIZEDBIT, the object is "normal".
--    A new setmetatable with __gc calls luaC_checkfinalizer again, which
--    re-registers (tofinalize(o) is false → proceeds).
-- =========================================================================
both_modes("F", function(mode)
    local order = {}
    local registry = {}
    local obj = setmetatable({ x = 1 }, { __gc = function(self)
        table.insert(order, "first_gc")
        registry[1] = self  -- resurrect
    end})
    obj = nil
    collectgarbage("collect")
    -- Now resurrected; give it a new __gc and drop again
    setmetatable(registry[1], { __gc = function(self)
        table.insert(order, "second_gc")
    end})
    registry[1] = nil
    collectgarbage("collect")
    print("F", mode, "order=" .. table.concat(order, ","))
    collectgarbage("collect")
    print("F", mode, "order2=" .. table.concat(order, ","))
end)

print("done")
