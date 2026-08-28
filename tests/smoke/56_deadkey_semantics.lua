-- Dead-key semantics test (PUC DEADKEY, ltable.c:252-282 + lgc.c:209-213).
--
-- Verifies that next() works correctly after deleting collectable keys and
-- running GC, which turns deleted nodes into DEADKEYs. PUC's `next` accepts
-- a deleted (Nil-valued) or dead (DEADKEY) control key via `equalkey` with
-- deadok=1 (ltable.c:351). The dead node's raw GC pointer is preserved
-- (PUC `setdeadkey` sets ONLY the tag, lobject.h:814) so the live key can
-- be matched by raw pointer identity.
--
-- Exercises multiple collectable key classes: short string, long string,
-- table, closure. Each is deleted, GC'd, and then next() must skip the
-- dead key and continue iteration without error.

local function assert_eq(a, b, msg)
    if a ~= b then
        error(("assert_eq failed: %s: got %s, expected %s"):format(
            msg or "", tostring(a), tostring(b)))
    end
end

-- =========================================================================
-- Part 1: next() after deleting a key and running GC (all key classes)
-- =========================================================================
-- Pattern: fill a table with collectable keys, iterate with next(), delete
-- the current key, run collectgarbage(), then call next(t, deleted_key).
-- PUC accepts the deleted control key (deadok=1) and returns the NEXT pair.

local function test_deadkey_class(key_factory, label)
    local t = {}
    -- Insert 5 keys of this class.
    local keys = {}
    for i = 1, 5 do
        local k = key_factory(i)
        t[k] = i
        keys[i] = k
    end
    -- Keep references to all keys so they survive GC (the deadok path is
    -- for when the key is still alive but the node is deadened — the key
    -- must NOT be collected, only deadened if it were unreachable. Since we
    -- hold references, the key stays alive and the node keeps its live tag.
    -- This tests the normal path: next(t, deleted_key) where the key is
    -- alive and the node has value==Nil.)

    -- Delete key #3, then iterate from it.
    t[keys[3]] = nil
    collectgarbage("collect")

    -- next(t, keys[3]) must NOT error (PUC accepts deleted control keys via
    -- deadok=1, ltable.c:351). It returns the next live entry or nil if
    -- keys[3] was the last in iteration order — both are valid.
    local nk, nv = next(t, keys[3])
    if nk ~= nil then
        assert(t[nk] == nv, label .. ": next returned inconsistent pair")
    end

    -- Verify all remaining entries are reachable by full traversal.
    local count = 0
    for k, v in pairs(t) do
        assert(t[k] == v, label .. ": pairs inconsistency")
        count = count + 1
    end
    assert_eq(count, 4, label .. ": entry count after one deletion")
end

-- Short string keys (interned, never collected — but node can be deadened
-- if the string is unreachable; here we hold references so it stays alive).
test_deadkey_class(function(i) return "key" .. i end, "short_string")

-- Long string keys (collectable, can be collected if unreachable).
test_deadkey_class(function(i) return string.rep("x", 100) .. i end, "long_string")

-- Table keys (collectable).
test_deadkey_class(function(i) return { tag = i } end, "table")

-- Closure keys (collectable).
test_deadkey_class(function(i) return function() return i end end, "closure")

-- =========================================================================
-- Part 2: next() from the beginning after GC deadens deleted keys
-- =========================================================================
-- Delete all entries one by one, running GC between deletions. After all
-- deletions, next(t) must return nil (table is empty). This exercises the
-- nextLiveIndex scan skipping dead/deleted nodes.

local function test_full_deletion(key_factory, label)
    local t = {}
    local keys = {}
    for i = 1, 10 do
        local k = key_factory(i)
        t[k] = i
        keys[i] = k
    end
    -- Delete all entries, GC after each.
    for i = 1, 10 do
        t[keys[i]] = nil
        collectgarbage("collect")
    end
    -- Table must be empty.
    assert(next(t) == nil, label .. ": table not empty after full deletion")
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    assert_eq(count, 0, label .. ": pairs count after full deletion")
end

test_full_deletion(function(i) return string.rep("a", 50) .. i end, "long_string_full")
test_full_deletion(function(i) return { tag = i } end, "table_full")
test_full_deletion(function(i) return function() return i end end, "closure_full")

-- =========================================================================
-- Part 3: coroutine + GC suspension during iteration with deleted keys
-- =========================================================================
-- Model the nextvar.lua:515-544 pattern: iterate a table with collectable
-- keys in a coroutine, delete the current key, yield, GC, resume. The
-- control key (from the for loop) must survive suspension + GC, and next()
-- must advance past the deleted key.

local function test_coroutine_deadkey()
    local t = {}
    -- Add unanchored collectable keys (like nextvar.lua:531-537).
    t[{1}] = 1
    t[{2}] = 2
    t[string.rep("a", 50)] = "a"   -- long string
    t[string.rep("b", 50)] = "b"   -- long string
    t[{3}] = 3
    t[string.rep("c", 10)] = "c"   -- short string
    t[function() return 10 end] = 10

    local co = coroutine.wrap(function(tbl)
        for k, v in pairs(tbl) do
            local k1 = next(tbl)  -- all previous keys were deleted
            assert(k == k1, "current key is not the first in the table")
            tbl[k] = nil
            local expected = (type(k) == "table" and k[1] or
                              type(k) == "function" and k() or
                              string.sub(k, 1, 1))
            assert(expected == v, "value mismatch for key type " .. type(k))
            coroutine.yield(v)
        end
    end)

    local count = 7
    while co(t) do
        collectgarbage("collect")  -- collect dead keys
        count = count - 1
    end
    assert_eq(count, 0, "coroutine deadkey: not all keys iterated")
    assert(next(t) == nil, "coroutine deadkey: table not empty after iteration")
end

test_coroutine_deadkey()

-- =========================================================================
-- Part 4: next(t, deleted_key) right after deletion (before GC)
-- =========================================================================
-- PUC accepts a deleted control key immediately after deletion (the node
-- has value==Nil but key tag is still live). next must return the NEXT pair.

local function test_next_after_immediate_deletion()
    local t = {}
    local keys = {}
    for i = 1, 5 do
        local k = { tag = i }
        t[k] = i * 10
        keys[i] = k
    end
    -- Delete key #2, immediately call next(t, keys[2]) (no GC).
    -- PUC accepts a deleted control key (deadok=1, ltable.c:351). Returns
    -- the next live entry or nil if keys[2] was last — both are valid.
    t[keys[2]] = nil
    local nk, nv = next(t, keys[2])
    if nk ~= nil then
        assert(t[nk] == nv, "immediate deletion: inconsistent pair")
    end
    -- Full traversal must see exactly 4 entries.
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    assert_eq(count, 4, "immediate deletion: entry count")
end

test_next_after_immediate_deletion()

print("deadkey_semantics_ok")
