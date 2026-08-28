-- Chain integrity regression test for the nodeInsert fix (PUC ltable.c:863).
--
-- Before the fix, nodeInsert used `mp.isEmpty()` (key-tag check) instead of
-- `mp.value == .Nil` (value check) to decide if the main position was
-- available for direct overwrite, and cleared `next_offset` on overwrite.
-- This orphaned every node after a deleted or dead-key node at the main
-- position, corrupting the collision chain and making pairs()/next() fail
-- with "invalid key to 'next'" after insert/delete churn.
--
-- This test models the nextvar.lua:135-141 pattern: fill a table with 2^11-1
-- string keys, churn 1e5 insert/delete with colliding keys, then verify
-- pairs() still sees all surviving entries. Also includes a coroutine
-- variant: iterate a churned table, delete the current key, yield,
-- collectgarbage, resume, continue iteration — the control key must survive
-- suspension + GC.

-- =========================================================================
-- Part 1: nextvar.lua:135-141 churn pattern
-- =========================================================================

local function countentries(t)
    local e = 0
    for _ in pairs(t) do e = e + 1 end
    return e
end

local a = {}
for i = 1, 2^11 - 1 do a[i .. ""] = true end
for i = 1, 1e5 do
    local key = i .. "."
    a[key] = true
    a[key] = nil
end
assert(countentries(a) == 2^11 - 1, "chain corruption: entries lost after churn")

-- =========================================================================
-- Part 2: coroutine + GC suspension during iteration over churned table
-- =========================================================================

-- Build a smaller churned table for the coroutine test.
local b = {}
for i = 1, 500 do b[i .. ""] = true end
for i = 1, 5000 do
    local key = i .. "x"
    b[key] = true
    b[key] = nil
end

-- Coroutine that iterates the churned table, yielding periodically with the
-- control key (the TFOR loop variable) live on the stack. Between yields,
-- the main thread runs collectgarbage(). The control key string must survive
-- suspension + GC — it is rooted in the TFOR register, and the chain must
-- remain intact so next() can find the successor after resume.
local co = coroutine.create(function()
    local count = 0
    for k in pairs(b) do
        count = count + 1
        if count % 50 == 0 then
            coroutine.yield(k)  -- suspend with control key live
        end
    end
    return count
end)

local total = 0
while coroutine.status(co) ~= "dead" do
    local ok, val = coroutine.resume(co)
    if not ok then error("coroutine failed: " .. tostring(val)) end
    total = val
    -- GC while coroutine is suspended: may deaden unmarked string keys in
    -- deleted nodes. The control key (val) is rooted in the main thread's
    -- local, so it must survive. The chain integrity must survive GC.
    if coroutine.status(co) ~= "dead" then
        collectgarbage("collect")
    end
end

-- The coroutine should have iterated all surviving entries.
assert(total == 500, "coroutine iteration count mismatch: got " .. tostring(total) .. ", expected 500")

-- After coroutine + GC churn, the table must still be fully iterable.
assert(countentries(b) == 500, "chain corruption after coroutine+GC: entries lost")

-- =========================================================================
-- Part 3: delete current key during iteration, yield, GC, resume
-- =========================================================================

-- Test that next() works with a deleted (Nil-valued) control key after GC.
-- PUC's next() accepts a deleted node as a valid control (ltable.c:291-303).
local c = {}
for i = 1, 200 do c[i .. ""] = true end
-- Churn to create deleted nodes at main positions.
for i = 1, 2000 do
    local key = i .. "y"
    c[key] = true
    c[key] = nil
end

local co2 = coroutine.create(function()
    local count = 0
    local to_delete = nil
    for k in pairs(c) do
        count = count + 1
        -- Delete the PREVIOUS key (not the current one) to test that next()
        -- can advance from a deleted control key after GC.
        if to_delete then
            c[to_delete] = nil
        end
        to_delete = k
        if count % 25 == 0 then
            coroutine.yield(count)
        end
    end
    return count
end)

local total2 = 0
while coroutine.status(co2) ~= "dead" do
    local ok, val = coroutine.resume(co2)
    if not ok then error("coroutine2 failed: " .. tostring(val)) end
    total2 = val
    if coroutine.status(co2) ~= "dead" then
        collectgarbage("collect")
    end
end

-- We deleted ~all-but-last entries during iteration. The count should be 200
-- (we iterated all 200 entries; deletion during iteration doesn't cause skips
-- in PUC because next() uses the control key's node position, not its value).
assert(total2 == 200, "coroutine2 iteration count mismatch: got " .. tostring(total2) .. ", expected 200")

print("chain_integrity_ok")
