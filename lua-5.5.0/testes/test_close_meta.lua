local function func2close(f)
  return setmetatable({}, {__close = f})
end
local function foo (...)
  local x123 <close> = func2close(function () error("@x123") end)
end
local st, msg = xpcall(foo, debug.traceback)
print("MSG:", msg)
print("HAS close:", string.find(msg, "in metamethod 'close'") ~= nil)
