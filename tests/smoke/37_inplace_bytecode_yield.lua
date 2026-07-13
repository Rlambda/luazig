local co = coroutine.create(function (x)
  local marker = {x}

  local function inner()
    local a, b = coroutine.yield("pause", marker)
    assert(marker[1] == x)
    return a, b
  end

  return inner()
end)

local ok, tag, marker = coroutine.resume(co, 7)
assert(ok and tag == "pause" and marker[1] == 7)

local info = debug.getinfo(co, 1, "Sl")
assert(info.what == "Lua" and info.currentline > 0)

collectgarbage()
ok, a, b = coroutine.resume(co, "done", 9)
assert(ok and a == "done" and b == 9)
assert(coroutine.status(co) == "dead")

local tail = coroutine.create(function ()
  return coroutine.yield("tail")
end)

ok, tag = coroutine.resume(tail)
assert(ok and tag == "tail")
ok, a, b = coroutine.resume(tail, "x", "y")
assert(ok and a == "x" and b == "y")

local abandoned = coroutine.create(function ()
  coroutine.yield("abandoned")
end)
assert(coroutine.resume(abandoned))
abandoned = nil
collectgarbage()

print("inplace-bytecode-yield-ok")
