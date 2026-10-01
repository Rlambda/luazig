-- Tail-call frame/window safety: the reused frame's window is the callee's
-- (PUC luaD_pretailcall), __call-chain staging, VATAB raw extras, VAHID
-- hidden args, overflow and error-handler transport across a tail call.

print("chain15", pcall(function()
  local function chk(...) return 1 end
  local v = chk
  for i = 1, 15 do v = setmetatable({}, {__call = v}) end
  return v()
end))

print("chain14", pcall(function()
  local function chk(a, b) return a + b end
  local v = chk
  for i = 1, 14 do v = setmetatable({}, {__call = v}) end
  return v(20, 22)
end))

print("chain16", pcall(function()
  local function chk(...) return 1 end
  local v = chk
  for i = 1, 16 do v = setmetatable({}, {__call = v}) end
  return v()
end))

-- VATAB callee: raw extras stay inside the window until VARARGPREP folds
-- them into the table; the table escapes (returned), forcing table mode.
local function vtab(a, ...t) return t end
local function tv1(x) return vtab(x, 10, 20) end
local r1 = tv1(1)
print("vatab1", r1.n, r1[1], r1[2])
local function tv2(...) return vtab(7, ...) end
local r2 = tv2(30, 40)
print("vatab2", r2.n, r2[1], r2[2])
local function vtabbig(...t) return t.n, t[1], t[17] end
local function tv3(...) return vtabbig(...) end
print("vatab3", tv3(3, 0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15))

-- VAHID callee: hidden args below the reused frame's func slot.
local function vahid(a, ...) return a, select('#', ...), ... end
local function th1(...) return vahid(5, ...) end
print("vahid1", th1())
print("vahid2", th1(8, 9))
local function vcount(...) return select('#', ...) end
local function fwd(...) return vcount(...) end
print("vahid3", fwd(1, nil, 3, nil))

-- Repeated tail-call reuse: the same frame is reused many times, the
-- reset to the original func slot must not shift cumulatively.
local function sum(n, acc)
  if n == 0 then return acc end
  return sum(n - 1, acc + n)
end
print("reuse", sum(200, 0))
local function vsum(n, ...)
  if n == 0 then return select('#', ...) end
  return vsum(n - 1, "x")
end
print("reusevar", vsum(50))

-- Caller window much larger than the callee frame (stale-cap shape) and
-- the opposite direction (callee frame larger than the caller's).
local function bigcaller()
  local a1, a2, a3, a4, a5 = 1, 2, 3, 4, 5
  local t = {a1, a2, a3, a4, a5, a1 + a2, a3 + a4, a5 + a1}
  local function small() return #t end
  return small()
end
print("capshrink", bigcaller())
local function smallcaller() return (function(...) return select('#', ...) end)(1, 2, 3) end
print("capgrow", smallcaller())

-- Real GC cycle between staging and the tail call, then reuse the VM.
do
  local keep = {}
  for i = 1, 40 do keep[i] = {tag = i} end
  local function tagged(...) return select('#', ...) end
  local w = tagged
  for i = 1, 10 do w = setmetatable({}, {__call = w}) end
  collectgarbage()
  local ok, n = pcall(function() return w("a", "b") end)
  print("aftergc", ok, n)
  collectgarbage("collect")
  print("keepfirst", keep[1].tag, keep[40].tag)
end

-- Error object and message transport across a tail-called vararg callee.
do
  local marker = {name = "marker"}
  local function thrower(x) error(x, 0) end
  local function tail() return thrower(marker) end
  local ok, err = pcall(tail)
  print("errobj", ok, err == marker, err.name)
  local ok2, msg = pcall(function() return vahid(nil) end)
  print("errmsg", ok2, msg)
end

-- xpcall handler sees the tail-called frame's error with a traceback.
do
  local function inner() error("boom") end
  local function tail() return inner() end
  local ok, msg = xpcall(tail, function(m) return "H:" .. tostring(m) end)
  print("xpcall", ok, msg)
end

-- To-be-closed variable closes before the tail call replaces the frame.
do
  local log = {}
  local function closer(obj, err)
    log[#log + 1] = "closed:" .. obj.tag .. ":" .. tostring(err ~= nil)
  end
  local function work(...) return select('#', ...) end
  local function tailc()
    local x <close> = setmetatable({}, {__close = closer})
    x.tag = "x"
    return work(1, 2, 3)
  end
  print("tbc", pcall(tailc), log[1])
end

-- Call hook under a chained tail call: the event fires on the reused
-- frame with the callee's identity; arguments survive the reuse.
do
  local seen = 0
  local function target(a, ...) return a, select('#', ...) end
  local w = target
  for i = 1, 3 do w = setmetatable({}, {__call = w}) end
  debug.sethook(function(ev)
    seen = seen + 1
  end, "c")
  local ok1, ok2, n = pcall(function() return w("keep", 1, 2) end)
  debug.sethook()
  local ar = debug.getinfo(2, "t")
  print("hooktail", ok1, n, seen > 0, ar == nil)
end

-- GC inside the call hook while a tail-called vararg frame runs.
do
  local gcdone = false
  local function probe(...) return select('#', ...) end
  local w = probe
  for i = 1, 5 do w = setmetatable({}, {__call = w}) end
  local holder = {{}}
  debug.sethook(function(ev)
    if not gcdone then
      collectgarbage("step")
      gcdone = true
    end
  end, "c")
  local ok, n = pcall(function() return w(holder[1], 2, 4, 6) end)
  debug.sethook()
  print("hookgc", ok, n, gcdone, type(holder[1]))
end

-- Tail-call overflow: forwarding more values than the stack allows raises
-- the same "stack overflow" error PUC raises in luaD_growstack.
do
  local big = {}
  for i = 1, 1000 do big[i] = i end
  local function fwdall(...) return select('#', ...) end
  local function deep(n, ...)
    if n == 0 then return fwdall(...) end
    return deep(n - 1, ...)
  end
  local ok, res = pcall(deep, 600, table.unpack(big, 1, 1000))
  print("deepfwd", ok, res)
end

-- Coroutine: a tail call inside a coroutine body, resumed twice.
do
  local function cotail(a, b) coroutine.yield(a + b); return a * b end
  local co = coroutine.create(function(x) return cotail(x, 5) end)
  local _, s1 = coroutine.resume(co, 3)
  local _, s2 = coroutine.resume(co)
  print("coro", s1, s2, coroutine.status(co))
end
