-- Permanent differential file finalizer lifecycle tests
-- (verifier P16.8a Task 1).
--
-- Byte-identical stdout on PUC 5.5 and luazig. Tests PUC-faithful
-- file finalizer semantics:
--   * Explicit close (f:close()) only closes the OS resource — it does
--     NOT deregister from the finalization lifecycle. The userdata STAYS
--     registered (FINALIZEDBIT remains set). PUC aux_close (liolib.c:213)
--     sets closef=NULL but does NOT remove from finobj.
--   * The __gc metamethod is resolved DYNAMICALLY at finalization time.
--     If the metatable was changed (no __gc), no callback fires but the
--     object is consumed normally by the next cycle (udata2finalize
--     clears FINALIZEDBIT before GCTM lookup).
--   * f_gc (liolib.c:234-238) checks isclosed(p) and no-ops on an
--     already-closed file.
--   * Repeated explicit close raises an error (tofile → isclosed check).
--
-- No collectgarbage("count") (allocator granularity differs). Only
-- weak-key counts and deterministic event traces are printed.

local function countkeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Helper: create a tmpfile that works on both PUC and luazig.
local function make_tmpfile()
    if io.tmpfile then
        return assert(io.tmpfile())
    end
    return assert(io.open("/tmp/luazig-file-finalizer-test", "w+"))
end

-- =========================================================================
-- A. Explicit close does NOT deregister from finalization lifecycle.
--    After close + metatable mutation (no __gc) + drop + collect:
--    the file userdata survives the first collect (still registered,
--    takeFinalizable dequeues it, no __gc fires, object survives to
--    next cycle). The weak key is still alive after gc1, gone after gc2.
--    PUC: prints "1 0".
-- =========================================================================
do
    local f = make_tmpfile()
    local wk = setmetatable({}, { __mode = "k" })
    wk[f] = true
    assert(f:close())
    debug.setmetatable(f, {})
    f = nil
    collectgarbage("collect")
    local n1 = countkeys(wk)
    collectgarbage("collect")
    local n2 = countkeys(wk)
    print("A", n1, n2)
end

-- =========================================================================
-- B. Explicit close does NOT deregister: __gc still fires at finalization
--    if the metatable still has __gc. After close + drop + collect:
--    the file's __gc runs (it no-ops because the file is already closed,
--    matching PUC f_gc's isclosed check). The object survives gc1
--    (finalizer ran, resurrected for one cycle), collected on gc2.
-- =========================================================================
do
    local gc_called = 0
    local f = make_tmpfile()
    local wk = setmetatable({}, { __mode = "k" })
    wk[f] = true
    -- Set a custom __gc on the file's metatable.
    local mt = getmetatable(f)
    mt.__gc = function(self)
        gc_called = gc_called + 1
    end
    assert(f:close())
    f = nil
    collectgarbage("collect")
    local n1 = countkeys(wk)
    collectgarbage("collect")
    local n2 = countkeys(wk)
    print("B", gc_called, n1, n2)
end

-- =========================================================================
-- C. Repeated explicit close raises an error.
--    PUC: f_close → tofile → isclosed → "attempt to use a closed file".
--    luazig: builtinFileClose checks __closed → error.
-- =========================================================================
do
    local f = make_tmpfile()
    assert(f:close())
    local ok, err = pcall(function() f:close() end)
    print("C", tostring(ok), tostring(err ~= nil))
end

-- =========================================================================
-- D. Auto-finalization of an open (not explicitly closed) tmpfile.
--    Drop an open file without close → GC finalizer closes it (f_gc
--    calls aux_close). Observable via weak-key pattern: the file
--    survives gc1 (finalizer ran), collected on gc2.
-- =========================================================================
do
    local f = make_tmpfile()
    local wk = setmetatable({}, { __mode = "k" })
    wk[f] = true
    f = nil  -- drop WITHOUT close
    collectgarbage("collect")
    local n1 = countkeys(wk)
    collectgarbage("collect")
    local n2 = countkeys(wk)
    print("D", n1, n2)
end

-- =========================================================================
-- E. Metatable mutation after close: the file's __gc is resolved from
--    the CURRENT metatable at finalization time. If we replace the
--    metatable with one that has a different __gc, that one fires.
-- =========================================================================
do
    local gc_msg = "none"
    local f = make_tmpfile()
    local wk = setmetatable({}, { __mode = "k" })
    wk[f] = true
    assert(f:close())
    -- Replace metatable with one that has a tracking __gc.
    debug.setmetatable(f, { __gc = function(self)
        gc_msg = "custom_gc"
    end})
    f = nil
    collectgarbage("collect")
    local n1 = countkeys(wk)
    collectgarbage("collect")
    local n2 = countkeys(wk)
    print("E", gc_msg, n1, n2)
end

print("done")
