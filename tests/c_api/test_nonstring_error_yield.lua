-- Regression: non-string error object preserved across yield.
-- PUC luaF_close: the error object is the exact Lua value from error().
-- Tables, userdata, etc. must be preserved without string normalization.
--
-- Test setup (LIFO close order: o3, o2, o1):
--   o3.__close → error({code=42})         (first resume: error with table)
--   o2.__close → receives table, yields    (first resume: yield)
--   o1.__close → receives table            (second resume: receives table)
--
-- Before fix: error normalization parsed the rendered string, corrupting
-- non-string error objects. close_err must store the exact Lua error Value.
local T = T
local setmetatable = setmetatable
local pcall = pcall
local assert = assert
local print = print
local tostring = tostring
local type = type
local coroutine = coroutine

local close_order = {}
local received_err = {}
local err_idx = 0

local function record_err(err)
  err_idx = err_idx + 1
  received_err[err_idx] = err
end

local o1 = setmetatable({}, {
  __close = function(_, err)
    close_order[#close_order + 1] = "o1"
    record_err(err)
  end,
})
local o2 = setmetatable({}, {
  __close = function(_, err)
    close_order[#close_order + 1] = "o2(yield)"
    record_err(err)
    coroutine.yield()
  end,
})
local o3 = setmetatable({}, {
  __close = function(_, err)
    close_order[#close_order + 1] = "o3(error)"
    record_err(err)
    error({code = 42, msg = "table_error"})
  end,
})

local co = coroutine.create(function()
  pcall(T.testC, "toclose 2; toclose 3; toclose 4; return 0", o1, o2, o3)
end)

-- First resume: o3 errors with table, o2 receives table and yields.
local ok1, r1 = coroutine.resume(co)
assert(ok1, "first resume should succeed, got: " .. tostring(r1))

-- Second resume: o1 receives table (preserved across yield).
local ok2, err2 = coroutine.resume(co)
assert(not ok2, "second resume should fail")

-- Verify close order.
assert(#close_order == 3, "expected 3 closes, got " .. #close_order)
assert(close_order[1] == "o3(error)", "expected o3(error) first, got " .. close_order[1])
assert(close_order[2] == "o2(yield)", "expected o2(yield) second, got " .. close_order[2])
assert(close_order[3] == "o1", "expected o1 third, got " .. close_order[3])

-- o3 receives nil (first closer, no error yet).
assert(received_err[1] == nil, "o3 should receive nil, got " .. tostring(received_err[1]))

-- o2 receives a table with code=42.
assert(type(received_err[2]) == "table", "o2 should receive table, got " .. type(received_err[2]))
assert(received_err[2].code == 42, "o2 table should have code=42, got " .. tostring(received_err[2].code))

-- o1 receives the SAME table (preserved across yield).
assert(type(received_err[3]) == "table", "o1 should receive table, got " .. type(received_err[3]))
assert(received_err[3].code == 42, "o1 table should have code=42, got " .. tostring(received_err[3].code))

-- The error from coroutine.resume should also be the table.
assert(type(err2) == "table", "coroutine.resume should return table error, got " .. type(err2))
assert(err2.code == 42, "coroutine.resume error should have code=42, got " .. tostring(err2.code))

print("OK order: " .. table.concat(close_order, ", "))
print("OK: non-string error object preserved across yield")
