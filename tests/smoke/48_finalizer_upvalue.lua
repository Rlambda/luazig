-- Finalizer that uses builtins via upvalue captures.
-- Reproduces gc.lua ">>> closing state <<<" gap.
local sm = setmetatable
local getmeta = getmetatable
local assert = assert
local print = print

___Glob = nil

local tt = {}
tt.__gc = function(o)
    assert(getmeta(o) == tt)
    local a = "xuxu"..(10+3).."joao", {}
    ___Glob = o
    sm({}, tt)
    print(">>> closing state <<<")
end
local u = sm({}, tt)
___Glob = {u}

-- Force a full GC cycle, then let state close run finalizers.
collectgarbage("collect")
print("OK")
