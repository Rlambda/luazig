local function func2close(f) return setmetatable({}, {__close=f}) end
local extrares
local function check (body, extra, ...t)
  local co = coroutine.wrap(body)
  if extra then extrares = co() end
  local res = table.pack(co())
  assert(res.n == 1 and type(res[1]) == "table", "A:"..res.n)
  local res2 = table.pack(co())
  assert(res2.n == #t, "B:"..res2.n.." want "..#t)
  for i = 1, #t do
    if t[i] == "x" then assert(res2[i] == res[1], "C:"..i)
    else assert(res2[i] == t[i], "D:"..i.." got "..tostring(res2[i])) end
  end
end
local function foo2 ()
  local x <close> = func2close(coroutine.yield)
  local extra <close> = func2close(function (self) coroutine.yield(100) end)
  extrares = extra
  error("210")
end
local ok, e = pcall(function () check(foo2, true, false, "x") end)
print("k2:", ok, e)
