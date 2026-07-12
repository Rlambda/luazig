local function iterator(state, control)
  if control == nil then
    local resumed = coroutine.yield("iterator-yield", state)
    return 1, resumed
  end
end

local marker = {alive = true}
local co = coroutine.create(function ()
  for key, value in iterator, marker, nil do
    assert(marker.alive)
    return key, value
  end
end)

local ok, tag, yielded_marker = coroutine.resume(co)
assert(ok and tag == "iterator-yield" and yielded_marker == marker)

local info = debug.getinfo(co, 1, "Sl")
assert(info.what == "Lua" and info.currentline > 0)
collectgarbage()

ok, key, value = coroutine.resume(co, "resume-value")
assert(ok and key == 1 and value == "resume-value")
assert(coroutine.status(co) == "dead")

print("generic-for-inplace-yield-ok")
