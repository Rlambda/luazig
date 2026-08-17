-- Regression: yield → resume → next closer errors.
-- PUC luaF_close: if a closer yields, the coroutine suspends. On resume,
-- remaining closers continue. If a later closer errors, the error replaces
-- the current error (LIFO) and the coroutine fails with that error.
--
-- Test setup (LIFO close order: o3, o2, o1):
--   o3.__close → coroutine.yield()     (first resume: yield)
--   o2.__close → error("e2")            (second resume: error)
--   o1.__close → receives o2 error      (second resume: receives "e2")
--
-- Before fix: close_err was a local var lost on yield; resumed closers
-- received null. Also, error normalization corrupted the error object.
local T = T
local setmetatable = setmetatable
local pcall = pcall
local assert = assert
local print = print
local tostring = tostring
local string = string
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
    close_order[#close_order + 1] = "o2(error)"
    received_err[#received_err + 1] = tostring(err)
    error("e2")
  end,
})
local o3 = setmetatable({}, {
  __close = function()
    close_order[#close_order + 1] = "o3(yield)"
    coroutine.yield()
  end,
})

local co = coroutine.create(function()
  pcall(T.testC, "toclose 2; toclose 3; toclose 4; return 0", o1, o2, o3)
end)

-- First resume: o3 yields → coroutine suspends.
local ok1, r1 = coroutine.resume(co)
assert(ok1, "first resume should succeed, got: " .. tostring(r1))

-- Second resume: o2 errors, o1 receives o2 error.
-- pcall doesn't return correctly after yield (pre-existing luazig issue),
-- so the error propagates to coroutine.resume.
local ok2, err2 = coroutine.resume(co)
assert(not ok2, "second resume should fail")
assert(string.find(tostring(err2), "e2"), "expected e2 in error, got: " .. tostring(err2))

-- Verify close order: o3(yield), o2(error), o1.
assert(#close_order == 3, "expected 3 closes, got " .. #close_order)
assert(close_order[1] == "o3(yield)", "expected o3(yield) first, got " .. close_order[1])
assert(close_order[2] == "o2(error)", "expected o2(error) second, got " .. close_order[2])
assert(close_order[3] == "o1", "expected o1 third, got " .. close_order[3])

-- o2 receives nil (o3 didn't error, just yielded).
-- o1 receives "e2" (error from o2, preserved across yield).
assert(received_err[1] == "nil", "o2 should receive nil, got " .. tostring(received_err[1]))
assert(string.find(received_err[2], "e2"), "o1 should receive e2, got " .. tostring(received_err[2]))

print("OK order: " .. table.concat(close_order, ", "))
print("OK errors: " .. table.concat(received_err, ", "))
