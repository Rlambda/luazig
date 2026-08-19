-- Regression test for P15.51l dangling *CallFrame pointer bug.
-- Scenario: call depth > 32 (heap-backed FrameStack) + reentrant debug hook
-- that grows exec_frames heap → stale *CallFrame pointer in opCall/varargprep.
--
-- Before fix: fr_call/fr_vp obtained via getPtr() before reentrant ops,
-- then used after exec_frames.heap realloc → dangling pointer → corrupted
-- reg_top → crash (typically in OP_SETLIST underflow).

-- Build a chain of 40 nested Lua closures (depth > INLINE_FRAME_CAP=32).
local function make_chain(depth)
    if depth == 0 then
        return function()
            -- At the bottom: trigger a CALL that will invoke the hook.
            -- The hook fires reentrantly, growing exec_frames heap.
            local t = {}
            for i = 1, 5 do
                t[i] = i * 2
            end
            return t
        end
    end
    return function()
        return make_chain(depth - 1)()
    end
end

-- Hook that does reentrant Lua calls to grow exec_frames heap storage.
-- Each hook invocation pushes 10+ frames, forcing heap realloc when
-- the inline capacity (32) is exceeded by the combined depth.
local hook_call_count = 0
local function reentrant_hook(event, line)
    hook_call_count = hook_call_count + 1
    -- Reentrant calls: push enough frames to force exec_frames heap growth.
    -- The outer call chain is already at depth ~40, so even a few extra
    -- frames here will exceed the inline capacity and trigger realloc.
    local function a() return 1 end
    local function b() return a() + 1 end
    local function c() return b() + 1 end
    local function d() return c() + 1 end
    local function e() return d() + 1 end
    local function f() return e() + 1 end
    local function g() return f() + 1 end
    local function h() return g() + 1 end
    local function i() return h() + 1 end
    local function j() return i() + 1 end
    -- Call through the chain — this pushes 10 frames on top of the
    -- already-deep stack, forcing heap growth.
    j()
end

-- Install a call hook so it fires on every function call.
-- The hook fires inside opCall, which is where fr_call is held stale.
debug.sethook(reentrant_hook, "c")

-- Run the deep chain. At depth 40, the current frame is in heap storage.
-- When the hook fires inside the innermost CALL, the hook's reentrant
-- calls grow exec_frames.heap, invalidating the fr_call pointer obtained
-- at the top of opCall. After the hook returns, opCall writes to
-- fr_call.reg_top — a dangling pointer.
local result = make_chain(40)()

-- Verify correctness: the bottom function returns {1,2,3,4,5} * 2.
assert(type(result) == "table", "expected table result")
assert(#result == 5, "expected 5 elements, got " .. #result)
for i = 1, 5 do
    assert(result[i] == i * 2, "expected " .. (i*2) .. " at index " .. i .. ", got " .. tostring(result[i]))
end

-- Also test vararg path (fr_vp dangling pointer in varargprep).
local function vararg_func(...)
    local args = {...}
    return #args
end

-- Call vararg_func at depth > 32 with the hook active.
-- varargprep obtains fr_vp before allocations, uses it after.
local function deep_vararg_chain(depth, ...)
    if depth == 0 then
        return vararg_func(1, 2, 3, 4, 5, 6, 7, 8)
    end
    return deep_vararg_chain(depth - 1, ...)
end

local vararg_result = deep_vararg_chain(40)
assert(vararg_result == 8, "expected 8 varargs, got " .. tostring(vararg_result))

debug.sethook()  -- Remove hook

print("PASS: reentrant hook + deep frames (50_reentrant_hook_deep_frames)")
