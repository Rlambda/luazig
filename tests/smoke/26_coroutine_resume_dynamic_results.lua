-- coroutine.resume has a bounded output buffer internally, but Lua-visible
-- vararg contexts must receive only the values actually produced.
local co = coroutine.create(function()
  coroutine.yield("Y")
  return "R"
end)

print(coroutine.resume(co))
print(coroutine.resume(co))
