-- Regression: error → next closer yields → resume.
-- PUC luaF_close: if a closer errors, the error replaces the current error
-- (LIFO) and remaining closers still run. If a later closer yields, the
-- coroutine suspends. On resume, remaining closers continue with the
-- preserved error.
--
-- Test setup (LIFO close order: o3, o2, o1):
--   o3.__close → error("e3")            (first resume: error)
--   o2.__close → receives "e3", yields  (first resume: yield)
--   o1.__close → receives "e3"          (second resume: receives "e3")
--
-- Before fix: close_err was a local var lost on yield; resumed closers
-- received null. Also, error normalization corrupted the error object.
local T = T
local setmetatable = setmetatable
local pcall = pcall
local assert = assert
local print = print
local tostring = tostring
local coroutine = coroutine

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
    error("e3")
  end,
})

local co = coroutine.create(function()
  pcall(T.testC, "toclose 2; toclose 3; toclose 4; return 0", o1, o2, o3)
end)

-- First resume: o3 errors, o2 receives "e3" and yields → coroutine suspends.
local ok1, r1 = coroutine.resume(co)
assert(ok1, "first resume should succeed, got: " .. tostring(r1))

-- Second resume: o1 receives "e3" (preserved across yield).
-- pcall doesn't return correctly after yield (pre-existing luazig issue),
-- so the error propagates to coroutine.resume.
local ok2, err2 = coroutine.resume(co)
assert(not ok2, "second resume should fail")
assert(string.find(tostring(err2), "e3"), "expected e3 in error, got: " .. tostring(err2))

-- Verify close order: o3(error), o2(yield), o1.
assert(#close_order == 3, "expected 3 closes, got " .. #close_order)
assert(close_order[1] == "o3(error)", "expected o3(error) first, got " .. close_order[1])
assert(close_order[2] == "o2(yield)", "expected o2(yield) second, got " .. close_order[2])
assert(close_order[3] == "o1", "expected o1 third, got " .. close_order[3])

-- o3 receives nil (first closer, no error yet).
-- o2 receives "e3" (error from o3, LIFO).
-- o1 receives "e3" (preserved across yield).
assert(received_err[1] == "nil", "o3 should receive nil, got " .. received_err[1])
assert(string.find(received_err[2], "e3"), "o2 should receive e3, got " .. received_err[2])
assert(string.find(received_err[3], "e3"), "o1 should receive e3 (preserved), got " .. received_err[3])

print("OK order: " .. table.concat(close_order, ", "))
print("OK errors: " .. table.concat(received_err, ", "))
