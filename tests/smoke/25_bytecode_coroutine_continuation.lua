-- Bytecode coroutine frames must resume at the yielding CALL and preserve
-- multiple values in both directions.
local co = coroutine.create(function(a)
  local b, c = coroutine.yield(a + 1, a + 2)
  return b, c
end)
local r1, r2, r3 = coroutine.resume(co, 10)
print(r1, r2, r3)
r1, r2, r3 = coroutine.resume(co, 20, 30)
print(r1, r2, r3)

local function func2close(f)
  return setmetatable({}, {__close = f})
end

-- Closing a suspended coroutine must continue through every closer after an
-- error, pass the latest error object onward, and return the last error.
local track = {}
co = coroutine.create(function()
  local outer <close> = func2close(function(_, err)
    track[#track + 1] = err
    error(200)
  end)
  local inner <close> = func2close(function(_, err)
    track[#track + 1] = err == nil and "nil" or err
    error(111)
  end)
  coroutine.yield()
end)
local started = coroutine.resume(co)
print(started)
local ok, err = coroutine.close(co)
print(ok, err, track[1], track[2], coroutine.status(co))

-- Runtime errors unwind bytecode TBC slots before pcall returns.
local seen
co = coroutine.create(function()
  return pcall(function()
    local value <close> = func2close(function(_, err_obj)
      seen = err_obj
    end)
    error(43)
  end)
end)
local resumed, protected, protected_err = coroutine.resume(co)
print(resumed, protected, protected_err)
print(seen)

-- A live TBC slot disables frame-reusing tail-call behavior.
local closed = false
local wrapped
wrapped = coroutine.wrap(function()
  local value <close> = func2close(function()
    closed = true
  end)
  return pcall(wrapped)
end)
local st, msg = wrapped()
print(st, type(msg) == "string" and msg:find("non%-suspended") ~= nil, closed)

-- Per-thread call/line/return hooks survive a yield/resume boundary.
co = coroutine.create(function()
  coroutine.yield(10)
  return 20
end)
local trace = {}
debug.sethook(co, function(event)
  trace[#trace + 1] = event
end, "clr")
repeat until not coroutine.resume(co)
print(table.concat(trace, ","))
