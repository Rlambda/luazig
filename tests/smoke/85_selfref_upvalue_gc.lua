-- P16.49 regression: open-upvalue Cells must be unlinked from the owning
-- thread's bytecode_boxed when the Cell is swept BEFORE the thread (PUC
-- freeupval → luaF_unlinkupval analogue). Before the fix, the dead thread's
-- later closeThreadOpenUpvalues wrote through the dangling pointer,
-- corrupting the allocator freelist (deterministic SIGSEGV on gc.lua's
-- self-referenced-threads section when the next Cell/Closure was allocated).
--
-- Shape (generic Lua, mirrors the upstream invariant — no test-specific
-- names): many suspended coroutines whose only root is a self-referential
-- open upvalue; drop the table; a full collectgarbage sweeps the group in
-- whatever order the registry provides; the unlink must keep every order
-- safe. Repeat with fresh groups so the Cell/Closure free-list is heavily
-- recycled right after the sweeps (the crash window).

local N_GROUPS = 12
local N_THREADS = 64

local function make_group(n)
    local threads = {}
    local function fn(co)
        local x = {}
        threads[co] = function() co = x end
        coroutine.yield()
    end
    for i = 1, n do
        local co = coroutine.create(fn)
        -- The invariant under test needs the thread SUSPENDED at the yield
        -- with live open upvalues: a failed setup resume must fail the
        -- test, not silently produce an empty group.
        local ok, err = coroutine.resume(co, co)
        assert(ok, err)
        assert(coroutine.status(co) == "suspended",
               "setup: thread must be suspended at the yield")
    end
    return threads
end

for g = 1, N_GROUPS do
    local group = make_group(N_THREADS)
    -- Group is now garbage: the only roots were the self-referential open
    -- upvalues inside the dead-to-be threads. A full collection must free
    -- cells and threads in EITHER order without corrupting the heap.
    group = nil
    collectgarbage()
    -- Immediately allocate closures over captured locals: this is where the
    -- corrupted free-list used to detonate (next Cell/Closure allocation).
    for i = 1, 64 do
        local captured = i
        local f = function() return captured + 1 end
        assert(f() == i + 1)
    end
end

-- Also exercise coroutine.close on suspended threads with open upvalues
-- (thread-first order: teardown closes the still-linked cells).
do
    local saved = {}
    local function fn(co)
        local x = { co }
        saved[co] = function() return x end
        coroutine.yield()
    end
    for i = 1, 32 do
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co, co)
        assert(ok, err)
        assert(coroutine.status(co) == "suspended",
               "setup: thread must be suspended at the yield")
        assert(coroutine.close(co))
    end
    saved = nil
    collectgarbage()
end

print("85 ok")
