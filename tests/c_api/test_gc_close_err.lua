-- Regression: GC between resumes must not collect close_err.
-- close_err and close_return_values are stored in TestcContState and must
-- be traced by GC. If GC runs between the first and second resume, the
-- error object must survive.
--
-- Test setup (LIFO close order: o3, o2, o1):
--   o3.__close → error("gc_test")        (first resume: error)
--   o2.__close → receives "gc_test", yields  (first resume: yield)
--   o1.__close → receives "gc_test"      (second resume: receives "gc_test")
--
-- Between resumes, force GC to run. If close_err is not traced, the error
-- string is collected and o1 receives garbage or nil.
local T = T
local setmetatable = setmetatable
local pcall = pcall
local assert = assert
local print = print
local tostring = tostring
local coroutine = coroutine
local collectgarbage = collectgarbage

local close_order = {}
local received_err = {}

local o1 = setmetatable({}, {
  __close = function(_, err)
    close_order[#close_order + 1] = "o1"
    received_err[#received_err + 1] = tostring(err)
  end,
})
local o2 = setmetatable({}, {
  __close = function(_, err)
    close_order[#close_order + 1] = "o2(yield)"
    received_err[#received_err + 1] = tostring(err)
    coroutine.yield()
  end,
})
local o3 = setmetatable({}, {
  __close = function(_, err)
    close_order[#close_order + 1] = "o3(error)"
    received_err[#received_err + 1] = tostring(err)
    error("gc_test_error_string")
  end,
})

local co = coroutine.create(function()
  pcall(T.testC, "toclose 2; toclose 3; toclose 4; return 0", o1, o2, o3)
end)

-- First resume: o3 errors, o2 receives error and yields.
local ok1, r1 = coroutine.resume(co)
assert(ok1, "first resume should succeed, got: " .. tostring(r1))

-- Force GC between resumes. If close_err is not traced by GC, the error
-- string will be collected and o1 will receive garbage.
collectgarbage("collect")
collectgarbage("collect")

-- Second resume: o1 receives the preserved error.
local ok2, err2 = coroutine.resume(co)
assert(not ok2, "second resume should fail")
assert(string.find(tostring(err2), "gc_test_error_string"),
  "expected gc_test_error_string in error, got: " .. tostring(err2))

-- Verify close order.
assert(#close_order == 3, "expected 3 closes, got " .. #close_order)
assert(close_order[1] == "o3(error)", "expected o3(error) first, got " .. close_order[1])
assert(close_order[2] == "o2(yield)", "expected o2(yield) second, got " .. close_order[2])
assert(close_order[3] == "o1", "expected o1 third, got " .. close_order[3])

-- o1 should receive the error string (not garbage, not nil).
assert(string.find(received_err[3], "gc_test_error_string"),
  "o1 should receive gc_test_error_string, got " .. received_err[3])

print("OK order: " .. table.concat(close_order, ", "))
print("OK: close_err survived GC between resumes")
