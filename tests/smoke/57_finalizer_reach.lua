-- Permanent differential finalizer/weak-table tests (verifier P16.4h Tasks 3+4).
--
-- Byte-identical stdout on PUC 5.5 and luazig. Each scenario is run under both
-- GC modes (generational + incremental) by switching the mode at the start of
-- the body and restoring it at the end.
--
-- Encoded PUC 5.5 atomic-phase ordering (lgc.c:1543 `atomic`), verified
-- empirically against the oracle (lua-5.5.0/src/lua):
--   1. mark strongly-reachable objects
--   2. clearbyvalues(weak) / clearbyvalues(allweak)  -- BEFORE resurrection
--   3. separatetobefnz + markbeingfnz + propagate   -- resurrect to-be-finalized
--   4. clearbykeys(ephemeron) / clearbykeys(allweak) -- AFTER resurrection
--   5. clearbyvalues(weak, origweak)                 -- resurrected weak tables
--
-- Consequence (the key differential invariant this file pins down):
--   * A weak VALUE pointing at a descendant of a to-be-finalized object is
--     cleared in step 2, BEFORE the descendant is resurrected in step 3.
--     => weak-value probe is nil already at gc1, yet the parent's finalizer
--        still observes the live descendant (resurrected for the call).
--   * A weak KEY pointing at the same descendant survives step 4 (the
--     descendant is now marked) and is only collected on the NEXT cycle.
--
-- No collectgarbage("count") output (allocator granularity differs). Only
-- booleans / nil-checks / ordered event traces are printed.

local function countkeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Run `body` under both GC modes, restoring incremental mode afterwards.
-- PUC 5.5 accepts collectgarbage("generational") / ("incremental").
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
-- A. Descendant of a to-be-finalized parent (weak VALUE probe)
--    Parent's __gc accesses self.c; if the descendant were collected before
--    the finalizer ran, self.c would be nil. PUC resurrects the parent graph
--    for the finalizer call, so the descendant is live during __gc, but the
--    weak-value entry is cleared in step 2 (before resurrection).
-- =========================================================================
both_modes("A", function(mode)
    local saw_child = false
    local child = { x = 123 }
    local parent = setmetatable({ c = child }, { __gc = function(self)
        saw_child = (self.c ~= nil and self.c.x == 123)
    end})
    local weak = setmetatable({}, { __mode = "v" })
    weak[1] = child
    child = nil; parent = nil

    collectgarbage("collect")
    print("A", mode, "gc1 finalize_saw_child=" .. tostring(saw_child)
        .. " weak1=" .. tostring(weak[1]))
    collectgarbage("collect")
    print("A", mode, "gc2 weak1=" .. tostring(weak[1]))
end)

-- =========================================================================
-- B. Weak-KEY descendant of a to-be-finalized parent
--    The child is the KEY. Step 4 (clearbykeys) runs AFTER resurrection, so
--    the resurrected descendant keeps its weak-key entry through gc1 and is
--    only collected on the next full cycle.
-- =========================================================================
both_modes("B", function(mode)
    local parent_finalized = false
    local child = { x = 7 }
    local parent = setmetatable({ c = child }, { __gc = function()
        parent_finalized = true
    end})
    local weak = setmetatable({}, { __mode = "k" })
    weak[child] = "marker"
    child = nil; parent = nil

    collectgarbage("collect")
    print("B", mode, "gc1 parent_finalized=" .. tostring(parent_finalized)
        .. " weak_n=" .. countkeys(weak))
    collectgarbage("collect")
    print("B", mode, "gc2 weak_n=" .. countkeys(weak))
end)

-- =========================================================================
-- C. Weak-VALUE descendant where the descendant is itself finalizable
--    Both parent and child have __gc. PUC finalizes parent first then child
--    in the same cycle (order: parent_gc, child_gc). Weak-value entry cleared
--    in step 2 before resurrection => nil at gc1.
-- =========================================================================
both_modes("C", function(mode)
    local order = {}
    local child = setmetatable({ x = 9 }, { __gc = function()
        table.insert(order, "child_gc")
    end})
    local parent = setmetatable({ c = child }, { __gc = function()
        table.insert(order, "parent_gc")
    end})
    local wv = setmetatable({}, { __mode = "v" })
    wv[1] = child
    child = nil; parent = nil

    collectgarbage("collect")
    print("C", mode, "gc1 order=" .. table.concat(order, ",")
        .. " wv1=" .. tostring(wv[1]))
    collectgarbage("collect")
    print("C", mode, "gc2 order=" .. table.concat(order, ",")
        .. " wv1=" .. tostring(wv[1]))
end)

-- =========================================================================
-- D. Cycle reachable from a finalizer (marking must terminate)
--    parent -> a -> b -> a (b.a = a, a.b = b). The finalizer touches the
--    cycle. A broken visited-set would infinite-loop or UAF here. Weak-value
--    probe of `a` cleared in step 2 (a is a descendant of parent).
-- =========================================================================
both_modes("D", function(mode)
    local finalized = false
    local a = {}
    local b = { a = a }
    a.b = b
    local parent = setmetatable({ a = a }, { __gc = function(self)
        finalized = true
        assert(self.a.b.a == self.a)  -- touch the cycle
    end})
    local wa = setmetatable({}, { __mode = "v" })
    wa[1] = a
    a = nil; b = nil; parent = nil

    collectgarbage("collect")
    print("D", mode, "gc1 finalized=" .. tostring(finalized)
        .. " wa_n=" .. countkeys(wa))
    collectgarbage("collect")
    print("D", mode, "gc2 wa_n=" .. countkeys(wa))
    collectgarbage("collect")
    print("D", mode, "gc3 wa_n=" .. countkeys(wa))
end)

-- =========================================================================
-- E. Resurrection via a live registry table
--    __gc stores self into a live `registry` table. After gc1 the object is
--    alive via registry (finalizer ran exactly once). After dropping the
--    registry ref + more collects, the object is collected and the finalizer
--    is NOT called a second time (gc_count stays at 1).
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
-- F. Interleaved garbage between collects (no premature collection)
--    Scenario A body, but new garbage is created between full collects. The
--    finalizer-held descendant graph must not be prematurely collected: the
--    finalizer still observes the live child, and the weak-value probe is
--    nil only after the finalizer has run.
-- =========================================================================
both_modes("F", function(mode)
    local saw_child = false
    local child = { x = 1 }
    local parent = setmetatable({ c = child }, { __gc = function(self)
        saw_child = (self.c ~= nil and self.c.x == 1)
    end})
    local weak = setmetatable({}, { __mode = "v" })
    weak[1] = child
    child = nil; parent = nil

    for _ = 1, 100 do local _ = { 0 } end
    collectgarbage("collect")
    for _ = 1, 100 do local _ = { 0 } end
    collectgarbage("collect")
    print("F", mode, "saw_child=" .. tostring(saw_child)
        .. " weak1=" .. tostring(weak[1]))
end)

print("done")
