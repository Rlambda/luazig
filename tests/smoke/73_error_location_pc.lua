-- 73_error_location_pc.lua — P16.34 Cut 1 parity gate: error locations and
-- GC-live-pc correctness after removing the per-opcode dispatch_pc store.
-- DRAFT (print-only) — run on PUC to capture expected strings.

-- 1. arith error inside a loop (MMBIN path)
local ok, err = pcall(function()
    local acc = 0
    for i = 1, 10 do acc = acc + nil end
end)
print("1", ok, err)

-- 2. comparison error (slow path)
local ok2, err2 = pcall(function()
    return {} < {}
end)
print("2", ok2, err2)

-- 3. bad table index (rawSet nil/NaN key)
local ok3, err3 = pcall(function()
    local t = {}
    t[nil] = 1
end)
print("3a", ok3, err3)
local ok3b, err3b = pcall(function()
    local t = {}
    t[0 / 0] = 1
end)
print("3b", ok3b, err3b)

-- 4. __index metamethod error
local ok4, err4 = pcall(function()
    local t = setmetatable({}, { __index = function(_, k) error("no field " .. tostring(k)) end })
    return t.missing
end)
print("4", ok4, err4)

-- 5a. call a nil value
local ok5, err5 = pcall(function()
    local f
    f()
end)
print("5a", ok5, err5)

-- 5b. builtin argument error (location = caller line)
local ok5b, err5b = pcall(function()
    return math.floor("x")
end)
print("5b", ok5b, err5b)

-- 6. nested call error (innermost location)
local function inner() error("deep") end
local function outer() inner() end
local ok6, err6 = pcall(outer)
print("6", ok6, err6)

-- 7. coroutine resume error line
local co = coroutine.create(function()
    local x = 1
    error("coerr")
end)
local ok7, err7 = coroutine.resume(co)
print("7", ok7, err7)

-- 8. __close metamethod error line
local ok8, err8 = pcall(function()
    local x <close> = setmetatable({}, { __close = function() error("cerr") end })
    return 1
end)
print("8", ok8, err8)

-- 9. hook callback error line (fires once, inside the protected function)
local ok9, err9
do
    local fired = false
    local function hook()
        if not fired then
            fired = true
            error("hook!")
        end
    end
    ok9, err9 = pcall(function()
        debug.sethook(hook, "l")
        local a = 1
        local b = 2
        return a + b
    end)
    debug.sethook()
end
print("9", ok9, err9)

-- 10. concat error (opConcat park)
local ok10, err10 = pcall(function()
    return nil .. "x"
end)
print("10", ok10, err10)

-- 11. integer division / modulo by zero (already-published sites)
local ok11, err11 = pcall(function()
    return 5 // 0
end)
print("11a", ok11, err11)
local ok11b, err11b = pcall(function()
    return 5 % 0
end)
print("11b", ok11b, err11b)

-- 12. 'for' initial value error (opForprep)
local ok12, err12 = pcall(function()
    for i = 1, "x" do end
end)
print("12", ok12, err12)

-- 13. length error (LEN)
local ok13, err13 = pcall(function()
    return #nil
end)
print("13", ok13, err13)

-- GC-live-pc cases: locals must stay live across NEWTABLE-storm GC steps.

-- G1. weak-table: register-held object survives GC, dies after scope
local weak = setmetatable({}, { __mode = "v" })
do
    local obj = {}
    weak[1] = obj
    local sink = {}
    for i = 1, 5000 do sink = {} end
    assert(weak[1] == obj, "G1 live")
end
collectgarbage()
assert(weak[1] == nil, "G1 dead")

-- G2. closure over local at allocation point
local weak2 = setmetatable({}, { __mode = "v" })
do
    local captured = {}
    weak2[1] = captured
    local f = function() return captured end
    local sink = {}
    for i = 1, 5000 do sink = {} end
    assert(weak2[1] ~= nil, "G2 live")
    assert(f() == captured, "G2 closure")
end
collectgarbage()
assert(weak2[1] == nil, "G2 dead")

-- G3. TBC local across allocation
local closed = {}
do
    local x <close> = setmetatable({}, { __close = function() closed[#closed + 1] = "c" end })
    local sink = {}
    for i = 1, 5000 do sink = {} end
end
assert(#closed == 1, "G3 tbc")

-- G4. finalizer runs only after the local dies
local finalizers = 0
do
    local keep = setmetatable({}, { __gc = function() finalizers = finalizers + 1 end })
    local sink = {}
    for i = 1, 5000 do sink = {} end
    assert(type(keep) == "table", "G4 live")
    keep = nil
end
collectgarbage()
collectgarbage()
assert(finalizers == 1, "G4 finalizer")

print("GC OK")
