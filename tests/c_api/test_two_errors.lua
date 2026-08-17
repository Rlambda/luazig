-- Regression: two successive erroring closers — last error wins (LIFO).
-- PUC luaF_close: if multiple closers error, the last error replaces
-- previous errors (LIFO). Each closer receives the error from the previous
-- closer.
--
-- Test setup (LIFO close order: o3, o2, o1):
--   o3.__close → error("e3")             (first error)
--   o2.__close → receives "e3", error("e2")  (second error, replaces e3)
--   o1.__close → receives "e2"           (receives last error)
--
-- The final pcall error should be "e2" (last error wins).
local T = T
local setmetatable = setmetatable
local pcall = pcall
local assert = assert
local print = print
local tostring = tostring
local string = string

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
    close_order[#close_order + 1] = "o2(error)"
    received_err[#received_err + 1] = tostring(err)
    error("e2")
  end,
})
local o3 = setmetatable({}, {
  __close = function(_, err)
    close_order[#close_order + 1] = "o3(error)"
    received_err[#received_err + 1] = tostring(err)
    error("e3")
  end,
})

-- No yield — pcall catches the error directly.
local ok, err = pcall(T.testC, "toclose 2; toclose 3; toclose 4; return 0", o1, o2, o3)
assert(not ok, "pcall should fail")
-- Last error wins: "e2" (o2 errored after o3).
assert(string.find(tostring(err), "e2"), "expected e2 (last error wins), got: " .. tostring(err))

-- Verify close order: o3(error), o2(error), o1.
assert(#close_order == 3, "expected 3 closes, got " .. #close_order)
assert(close_order[1] == "o3(error)", "expected o3(error) first, got " .. close_order[1])
assert(close_order[2] == "o2(error)", "expected o2(error) second, got " .. close_order[2])
assert(close_order[3] == "o1", "expected o1 third, got " .. close_order[3])

-- o3 receives nil (first closer, no error yet).
-- o2 receives "e3" (error from o3).
-- o1 receives "e2" (last error, from o2).
assert(received_err[1] == "nil", "o3 should receive nil, got " .. tostring(received_err[1]))
assert(string.find(received_err[2], "e3"), "o2 should receive e3, got " .. tostring(received_err[2]))
assert(string.find(received_err[3], "e2"), "o1 should receive e2 (last error), got " .. tostring(received_err[3]))

print("OK order: " .. table.concat(close_order, ", "))
print("OK errors: " .. table.concat(received_err, ", "))
print("OK: last error wins (LIFO)")
