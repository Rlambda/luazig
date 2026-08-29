-- Permanent barrier-semantics differential test (P16.9 Task 11).
--
-- Verifies that luazig's table write-barrier semantics match PUC Lua 5.5
-- byte-for-byte across strong/weak tables × value/new-key mutations ×
-- incremental/generational GC modes.
--
-- The write barrier (PUC lgc.c luaC_barrierback / luaC_barrierforward) ensures
-- the tri-color invariant holds when a black (old, marked) object gains a
-- pointer to a white (young, unmarked) object. In generational mode this means
-- forwarding the young object into the old set; in incremental mode it means
-- marking the young object or clearing the old object's mark.
--
-- Key invariant tested: the barrier must strengthen strong-table references
-- (young values/keys survive collection) but must NOT strengthen weak-table
-- references (weak keys/values still disappear when otherwise unreachable).
--
-- Methodology:
--   * Each scenario is a function body run under BOTH GC modes.
--   * Probes use weak-table sentinels, booleans, and ordered traces — no
--     collectgarbage("count") (non-deterministic KB), no pointer addresses.
--   * Fixed counts of explicit collectgarbage("collect") calls (not steps).
--   * PUC 5.5 accepts both "generational" and "incremental" modes (default
--     is generational); collectgarbage(mode) returns the previous mode.
--
-- Encoded PUC behavior (prototyped side-by-side, 3× stable on both runtimes):
--   A: young value survives 1 collect after assignment to old table (barrier).
--   B: primitive int/string keys round-trip correctly.
--   C: new collectable key survives in strong table (barrier on key insert).
--   D: weak-key entry disappears after 1 collect (barrier does NOT strengthen).
--   E: weak-value entry disappears after 1 collect (barrier does NOT strengthen).
--   F: t[k]=nil removes existing entry; t[absent]=nil creates nothing.
--   G: mixed insert/delete/reinsert preserves correct counts at each step.
--   H: collectable metatable on old table survives (barrier on setmetatable).
--   I: weak-value with collectable value disappears (same as E, explicit).

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
-- Scenario A: existing key → young collectable value; old/black table.
-- Old table t, t.existing = young_table; drop other ref; collect.
-- PUC: young value SURVIVES — the write barrier (luaC_barrierback) marks the
-- young value so it is not collected by the next cycle.
-- =========================================================================
local function scenario_A()
    local t = {}
    t.existing = 1                  -- primitive placeholder
    collectgarbage("collect")       -- age t (gen: survives minor → old)
    collectgarbage("collect")       -- age again

    -- Create a young table; the only reference after assignment is t.existing.
    local function make_young() return { 10, 20, 30 } end
    t.existing = make_young()       -- young value → old table (barrier triggers)
    collectgarbage("collect")       -- must NOT collect the young value

    local v = t.existing
    local survived = (type(v) == "table")
    local n = 0
    if survived then for _ in pairs(v) do n = n + 1 end end
    return ("survived=%s entries=%d"):format(tostring(survived), n)
end

-- =========================================================================
-- Scenario B: existing integer AND string keys → primitive values.
-- PUC: values stored and read back correctly (correctness, not just perf).
-- =========================================================================
local function scenario_B()
    local t = {}
    t[1] = 100
    t["hello"] = "world"
    t[2] = 200
    collectgarbage("collect")
    local ok = (t[1] == 100 and t["hello"] == "world" and t[2] == 200)
    return ("correct=%s int1=%d str=%s int2=%d"):format(
        tostring(ok), t[1], t["hello"], t[2])
end

-- =========================================================================
-- Scenario C: new collectable hash key in strong table.
-- old_table[new_key] = true; drop external key ref; collect.
-- PUC: key SURVIVES — the barrier (luaC_barrierback for new key insertion
-- into an old table) marks the young key.
--
-- Probe: a weak-KEY sentinel table also holds the key. If the strong table's
-- barrier works, the key survives (reachable via t), so the sentinel entry
-- also survives. If the barrier fails, the key is collected and the sentinel
-- entry disappears. We check sentinel non-emptiness.
-- =========================================================================
local function scenario_C()
    local t = {}
    t[1] = true                     -- age t
    collectgarbage("collect")
    collectgarbage("collect")

    -- Weak-key sentinel: tracks whether the key object survives.
    local sentinel = setmetatable({}, { __mode = "k" })

    -- New collectable key; no external ref after assignment.
    local function make_key() return { tag = "ckey" } end
    local k = make_key()
    t[k] = true                     -- strong table holds key (barrier)
    sentinel[k] = true              -- weak sentinel also tracks it
    k = nil                         -- drop external ref
    collectgarbage("collect")       -- must NOT collect the key

    local key_survived = not isempty(sentinel)
    return ("key_survived=%s"):format(tostring(key_survived))
end

-- =========================================================================
-- Scenario D: weak-KEY table.
-- old weak-k table; weak[new_key] = true; drop ref; collect.
-- PUC: entry DISAPPEARS — the barrier must NOT strengthen a weak key. The
-- weak table's __mode="k" means keys are not barriers; the key is unreachable
-- after the external ref is dropped, so it is collected and the entry removed.
-- =========================================================================
local function scenario_D()
    local w = setmetatable({}, { __mode = "k" })
    collectgarbage("collect")       -- age the weak table
    collectgarbage("collect")

    local function make_key() return { tag = "wkey" } end
    w[make_key()] = true            -- weak key, no external ref
    collectgarbage("collect")       -- key collected, entry removed
    collectgarbage("collect")       -- second collect for gen-mode safety

    local disappeared = isempty(w)
    return ("disappeared=%s"):format(tostring(disappeared))
end

-- =========================================================================
-- Scenario E: weak-VALUE table.
-- existing-key update to young table value; weak-value semantics preserved.
-- PUC: entry DISAPPEARS — the barrier must NOT strengthen a weak value. The
-- weak table's __mode="v" means values are not barriers; the young table is
-- unreachable after the external ref is dropped (only weak ref remains), so
-- it is collected and the entry cleared.
-- =========================================================================
local function scenario_E()
    local w = setmetatable({}, { __mode = "v" })
    w.existing = 1                  -- primitive placeholder
    collectgarbage("collect")       -- age the weak table
    collectgarbage("collect")

    local function make_val() return { tag = "wval" } end
    w.existing = make_val()         -- young value, only ref is weak w.existing
    collectgarbage("collect")       -- value collected, entry cleared
    collectgarbage("collect")       -- second collect for gen-mode safety

    local disappeared = isempty(w)
    local val_nil = (w.existing == nil)
    return ("disappeared=%s val_nil=%s"):format(tostring(disappeared), tostring(val_nil))
end

-- =========================================================================
-- Scenario F: delete / absent-nil.
-- t[k]=nil for existing key (entry removed); t[absent]=nil (no creation).
-- PUC: deleting an existing key removes the entry (next returns nil). Assigning
-- nil to an absent key must NOT create an entry (no ownership/allocation).
-- =========================================================================
local function scenario_F()
    local t = {}
    local k = { tag = "fkey" }
    t[k] = true
    t[k] = nil                      -- delete existing key
    collectgarbage("collect")
    local after_delete = isempty(t)

    -- Absent key nil assignment: must not create an entry.
    local absent = { tag = "absent" }
    t[absent] = nil
    collectgarbage("collect")
    local after_absent_nil = isempty(t)

    return ("after_delete_empty=%s after_absent_nil_empty=%s"):format(
        tostring(after_delete), tostring(after_absent_nil))
end

-- =========================================================================
-- Scenario G (extra hardening): mixed sequence.
-- Insert new collectable key THEN delete THEN re-insert primitive.
-- Verifies barrier + deletion + re-insertion interact correctly.
-- =========================================================================
local function scenario_G()
    local t = {}
    t[1] = true                     -- age t
    collectgarbage("collect")
    collectgarbage("collect")

    -- Step 1: insert new collectable key.
    local function make_key() return { tag = "mix" } end
    local k = make_key()
    t[k] = "collectable"
    collectgarbage("collect")
    local after_insert = not isempty(t) and t[k] == "collectable"

    -- Step 2: delete it.
    t[k] = nil
    k = nil
    collectgarbage("collect")
    collectgarbage("collect")
    local after_delete = isempty(t)

    -- Step 3: re-insert a primitive key.
    t["reinserted"] = "primitive"
    collectgarbage("collect")
    local after_reinsert = (not isempty(t)) and t["reinserted"] == "primitive"

    return ("after_insert=%s after_delete=%s after_reinsert=%s"):format(
        tostring(after_insert), tostring(after_delete), tostring(after_reinsert))
end

-- =========================================================================
-- Scenario H (extra hardening): metatable-mutation interplay.
-- Set a collectable metatable on an old table; drop external mt ref; collect.
-- PUC: metatable SURVIVES — setmetatable triggers a barrier (luaC_objbarrier)
-- marking the young metatable. The __index metamethod must still work after GC.
-- =========================================================================
local function scenario_H()
    local t = {}
    t[1] = true                     -- age t
    collectgarbage("collect")
    collectgarbage("collect")

    -- Collectable metatable with __index.
    local function make_mt()
        return { __index = function(_, key) return "from_mt_" .. key end }
    end
    local mt = make_mt()
    setmetatable(t, mt)             -- barrier marks young mt
    mt = nil                        -- drop external ref; only t's mt slot holds it
    collectgarbage("collect")       -- must NOT collect the metatable

    local has_mt = (getmetatable(t) ~= nil)
    local v = t.nonexistent         -- triggers __index
    return ("has_mt=%s index_result=%s"):format(tostring(has_mt), tostring(v))
end

-- =========================================================================
-- Scenario I (extra hardening): weak-value with collectable value.
-- Same as E but with a fresh key, verifying barrier does NOT strengthen.
-- =========================================================================
local function scenario_I()
    local w = setmetatable({}, { __mode = "v" })
    collectgarbage("collect")       -- age
    collectgarbage("collect")

    local function make_val() return { tag = "wval2" } end
    w.k1 = make_val()               -- young value, only ref is weak w.k1
    collectgarbage("collect")
    collectgarbage("collect")

    local disappeared = isempty(w)
    local val_nil = (w.k1 == nil)
    return ("disappeared=%s val_nil=%s"):format(tostring(disappeared), tostring(val_nil))
end

-- =========================================================================
-- Run all scenarios under both GC modes.
-- =========================================================================

local scenarios = {
    { "A", scenario_A },
    { "B", scenario_B },
    { "C", scenario_C },
    { "D", scenario_D },
    { "E", scenario_E },
    { "F", scenario_F },
    { "G", scenario_G },
    { "H", scenario_H },
    { "I", scenario_I },
}

for _, mode in ipairs({ "incremental", "generational" }) do
    print(("=== mode=%s ==="):format(mode))
    for _, sc in ipairs(scenarios) do
        local label, body = sc[1], sc[2]
        local result = under_mode(mode, body)
        print(("%s: %s"):format(label, result))
    end
end

print("barrier_semantics_ok")
