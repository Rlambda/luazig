local function func2close(f)
  return setmetatable({}, {__close = f})
end

-- debug.getinfo must identify the actual bytecode closure while its <close>
-- handler is running; all bytecode functions share the IR dummy function.
local close_caller_name
local function named_close_owner()
  local value <close> = func2close(function()
    close_caller_name = debug.getinfo(2, "n").name
  end)
end
named_close_owner()
print(close_caller_name)

-- A non-closable value is rejected when OP_TBC activates the declaration,
-- and the diagnostic names the source local.
local ok, err = pcall(function()
  local value <close> = 1
end)
print(ok, err:find("variable 'value' got a non%-closable value") ~= nil)

-- Yielding close chains preserve an error raised by an older closer. The
-- surrounding pcall must not turn the suspended unwind into a successful
-- return when the final closer resumes.
local co = coroutine.wrap(function()
  local function foo(err_value)
    local z <close> = func2close(function(_, msg)
      coroutine.yield("z")
      return msg
    end)
    local y <close> = func2close(function(_, msg)
      coroutine.yield("y")
      error(err_value + 20)
    end)
    local x <close> = func2close(function(_, msg)
      coroutine.yield("x")
      return msg
    end)
    if err_value == 10 then error(err_value) end
    return 10, 20
  end
  return pcall(foo, 10)
end)
print(co())
print(co())
print(co())
print(co())

-- A forward goto that leaves nested generic-for scopes must close both hidden
-- fourth iterator values. Those TBC slots are below the visible loop locals.
local numopen = 0
local function open(n)
  numopen = numopen + 1
  return function()
      n = n - 1
      if n > 0 then return n end
    end,
    nil,
    nil,
    func2close(function() numopen = numopen - 1 end)
end

local sum = 0
for i in open(10) do
  for j in open(10) do
    if i + j < 5 then goto done end
    sum = sum + i
  end
end
::done::
print(sum, numopen)
