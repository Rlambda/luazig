-- 95_math_ranstate: math.random/randomseed as CClosure(1) over a per-opening
-- RanState userdata (PUC setrandfunc shape). Lua-observable lanes: fixed-seed
-- sequence parity for every argument form (including the 1-arg interval,
-- which must use rejection sampling, not modulo), debug.getupvalue/setupvalue/
-- upvalueid over the real C closures, getinfo, the field set, and coroutine
-- bodies (suspend/resume across calls, upvalue identity from inside a body).
-- The debug.setupvalue lanes only install a RanState userdata value;
-- installing any other class into the slot is PUC UB and is not reproduced.

-- fixed-seed sequences, all argument forms
math.randomseed(42)
for i = 1, 5 do print(string.format("%a", math.random())) end
math.randomseed(42)
for i = 1, 5 do print(math.random(10, 99)) end
math.randomseed(42)
for i = 1, 5 do print(math.random(100)) end
math.randomseed(42)
for i = 1, 5 do print(math.random(0)) end
math.randomseed(42)
print(math.random(-5, 5), math.random(-5, 5), math.random(-5, 5))
math.randomseed(42, 7)
print(math.random(0), math.random(0))
print(math.randomseed(42))

-- debug lanes over the real closures
local name, val = debug.getupvalue(math.random, 1)
print("getupvalue:", "[" .. name .. "]", type(val))
local n2, v2 = debug.getupvalue(math.randomseed, 1)
print("pair.sharesuserdata:", val == v2)
local idr = debug.upvalueid(math.random, 1)
local ids = debug.upvalueid(math.randomseed, 1)
print("upvalueid.distinct:", idr ~= ids)
collectgarbage("collect")
collectgarbage("collect")
print("upvalueid.gc.stable:", debug.upvalueid(math.random, 1) == idr)
-- valid swap: reinstall the (same) RanState userdata; the name comes back
print("setupvalue:", "[" .. tostring(debug.setupvalue(math.random, 1, v2)) .. "]")
math.randomseed(42)
print("after swap r(100):", math.random(100))
local i = debug.getinfo(math.random)
print("getinfo:", i.what, i.source, i.currentline, i.nups)
local t = {}
for k, v in pairs(math) do t[#t+1] = k end
table.sort(t)
print("fields:", table.concat(t, ","))

-- coroutine lanes
math.randomseed(42, 7)
local co = coroutine.create(function() return math.random(100) end)
print("v1:", coroutine.resume(co))
math.randomseed(42, 7)
local co2 = coroutine.create(function()
  math.randomseed(42, 7)
  return math.random(100)
end)
print("v2:", coroutine.resume(co2))
local upid = debug.upvalueid(math.random, 1)
local co3 = coroutine.create(function()
  return debug.upvalueid(math.random, 1) == upid
end)
print("v3:", coroutine.resume(co3))
local co4 = coroutine.create(function() return math.random(100) end)
print("v4:", coroutine.resume(co4))
print("v5:", coroutine.wrap(function()
  math.randomseed(42, 7)
  return math.random(100)
end)())
math.randomseed(42, 7)
local co6 = coroutine.create(function()
  local x = math.random(100)
  coroutine.yield(x)
  return math.random(100)
end)
local ok6, x6 = coroutine.resume(co6)
local ok6b, y6 = coroutine.resume(co6)
print("v6:", ok6, x6, ok6b, y6)
-- the error lane is asserted by class only (catchable inside the body);
-- the argerror function-name resolution is a separate known divergence
local co7 = coroutine.create(function() return math.random("x") end)
local ok7 = coroutine.resume(co7)
print("v7.catchable:", ok7 == false)
local co8 = coroutine.create(function()
  local n, v = debug.getupvalue(math.random, 1)
  return n, type(v)
end)
print("v8:", coroutine.resume(co8))
