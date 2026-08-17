-- Regression: exact string error object preserved through pcall result.
-- PUC luaG_runerror: the error object IS the string value from error().
-- Source location is part of the object (added by error() with level > 0),
-- but diagnostic annotations like "\nin metamethod 'close'" must NOT appear
-- in the pcall result — they are diagnostic-only.
--
-- Test: error("foo: bar", 0) in a __close metamethod.
--   - pcall should return exactly "foo: bar" (no source prefix, no annotation)
--   - subsequent __close should receive exactly "foo: bar"
--
-- Before fix: protectedErrorValue() read from self.err (diagnostic message)
-- which had "\nin metamethod 'close'" appended by annotateCloseRuntimeError.
local T = T
local setmetatable = setmetatable
local pcall = pcall
local error = error
local assert = assert
local print = print
local tostring = tostring

local received = {}
local ridx = 0
local function record(err) ridx = ridx + 1; received[ridx] = err end

local o1 = setmetatable({}, {__close = function(_, err) record(err) end})
local o2 = setmetatable({}, {__close = function(_, err) record(err); error("foo: bar", 0) end})

local ok, err = pcall(T.testC, "toclose 2; toclose 3; return 0", o1, o2)
assert(not ok, "pcall should fail")
-- PUC: pcall returns exact "foo: bar" (error with level 0 = no source info)
assert(tostring(err) == "foo: bar", "expected exact 'foo: bar', got: " .. tostring(err))
-- o2 receives nil (first closer, no error yet)
assert(received[1] == nil, "o2 should receive nil, got: " .. tostring(received[1]))
-- o1 receives exact "foo: bar" (not annotated with metamethod suffix)
assert(tostring(received[2]) == "foo: bar", "o1 should receive exact 'foo: bar', got: " .. tostring(received[2]))

print("OK: exact string error preserved: '" .. tostring(err) .. "'")
