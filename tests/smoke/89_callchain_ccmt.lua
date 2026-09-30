-- Per-frame __call-chain counter parity (PUC CIST_CCMT): the frame of a
-- function reached through __call metamethods reports the number of chain
-- links as debug.getinfo(...).extraargs ("t"), the chain limit is 15 links
-- (the 16th is rejected with "'__call' chain too long"), and a tailcall
-- reuse keeps the stale count of the original activation (PUC quirk).

local function echo(...)
  local t = table.pack(...)
  local parts = {}
  for i = 1, t.n do
    parts[i] = tostring(t[i])
  end
  print(table.concat(parts, ","))
end

-- A chain of n __call links ending at `final` (a function or builtin).
local function mkchain(n, final)
  local v = final
  for _ = 1, n do
    local t = {}
    setmetatable(t, { __call = v })
    v = t
  end
  return v
end

-- extraargs of a vararg function's own frame is NOT the vararg count
-- (varargs are reported through "u"/isvararg; "t" is the chain count).
local function vf(...)
  return debug.getinfo(1, "t").extraargs
end
echo(vf(1, 2, 3))                                     -- F6a: 0
echo(vf())                                            -- 0

-- Chain count survives yield/resume (NON-tail call inside the body).
local co1 = coroutine.create(function()
  local t = setmetatable({}, { __call = function()
    coroutine.yield("y1")
    return debug.getinfo(1, "t").extraargs
  end})
  local v = t(42)
  return v
end)
echo(coroutine.resume(co1))                           -- F5: true,y1
echo(coroutine.resume(co1))                           -- true,1

local co2 = coroutine.create(function()
  local ff = function()
    coroutine.yield("y1")
    return debug.getinfo(1, "t").extraargs
  end
  local t2 = setmetatable({}, { __call = setmetatable({}, { __call = ff }) })
  local v = t2(42)
  return v
end)
echo(coroutine.resume(co2))                           -- F5b: true,y1
echo(coroutine.resume(co2))                           -- true,2

-- A tailcall from the coroutine body reuses the body's frame: the mm frame
-- keeps the body's stale count (0) and is flagged istailcall.
local co3 = coroutine.create(function()
  local t = setmetatable({}, { __call = function()
    local info = debug.getinfo(1, "t")
    coroutine.yield(info.extraargs, tostring(info.istailcall))
  end})
  return t(42)                                       -- tailcall from the body
end)
echo(coroutine.resume(co3))                           -- F5c: true,0,true

-- Reaching f through 2 links and then tailcalling g: g's reused frame still
-- carries f's original chain count (stale preserved across tailcall reuse).
local g = function()
  return debug.getinfo(1, "t").extraargs
end
local f = mkchain(2, function()
  return g()                                          -- tailcall
end)
echo(f())                                             -- F7a: 2

-- A plain frame tailcalling INTO a 1-link chain: the new chain's count is
-- discarded by the tailcall reuse, the frame keeps its own 0.
local h = function()
  return debug.getinfo(1, "t").extraargs
end
local f2 = function()
  return mkchain(1, h)()                              -- tailcall into chain
end
echo(f2())                                            -- F7b: 0

-- The 15-link boundary: a full 15-link chain is accepted and the reached
-- frame reports 15.
local body15 = function()
  return debug.getinfo(1, "t").extraargs
end
echo(mkchain(15, body15)())                           -- n15: 15

-- The 16th link is rejected with the overflow text (both engines).
local t16 = mkchain(16, body15)
local ok16, msg16 = xpcall(t16, function(m) return m end)
echo(ok16, tostring(tostring(msg16):find("'__call' chain too long", 1, true) ~= nil))

-- The same overflow raised on the bytecode call path carries the calling
-- frame's position in both engines.
local ok17, msg17 = pcall(function() return t16() end)
echo(ok17, tostring(tostring(msg17):find("'__call' chain too long", 1, true) ~= nil))

-- A chain target inside pcall gets its own count from the inner resolution.
echo(pcall(mkchain(2, function()
  return debug.getinfo(1, "t").extraargs
end)))                                                -- pcall(t2): true,2

-- Exact-arity non-vararg chain target: the fast staged activation commits
-- the count too.
local fx = setmetatable({}, { __call = function(_, x)
  return debug.getinfo(1, "t").extraargs + x
end })
echo(fx(41))                                          -- 42

-- Closing a suspended coroutine whose body called through a chain discards
-- the chain frame together with its count.
local coc = coroutine.create(function()
  local t = setmetatable({}, { __call = function() coroutine.yield("parked") end })
  local v = t(42)
  return v
end)
echo(coroutine.resume(coc))                           -- true,parked
echo(coroutine.close(coc))                            -- true

-- The function-value form of getinfo("t") stays 0/0 regardless of any chain.
echo(debug.getinfo(body15, "t").extraargs, tostring(debug.getinfo(body15, "t").istailcall))

-- A __call chain reaching a BUILTIN is a real C activation (PUC precallC
-- creates a CallInfo for every C-function callee): from inside a call hook,
-- getinfo(2,"ft") reports the activation's chain count as extraargs. The
-- hook reads getinfo directly (no helper calls — a nested frame would shift
-- the level), and only fields requested via "ft" are printed.
local function hookrun(fn)
  local log = {}
  local function h(ev)
    local i = debug.getinfo(2, "ft")
    log[#log + 1] = ev .. "|" .. tostring(i and i.what) ..
      "|" .. tostring(i and i.istailcall) .. "|" .. tostring(i and i.extraargs)
  end
  debug.sethook(h, "c")
  local ok, r = fn()
  debug.sethook()
  local parts = {}
  for k, v in ipairs(log) do parts[k] = tostring(v) end
  echo(ok, tostring(r), #log, table.concat(parts, " "))
end

-- HB1: a builtin called through a __call chain from a host caller (pcall
-- resolves the chain): the activation's event carries extraargs = links.
hookrun(function()
  local cg = setmetatable({}, { __call = collectgarbage })
  local ok = pcall(cg, "count")
  return ok                                                -- false, both engines
end)                                                      -- HB1

-- HB2: string.sub through a chain — same mechanism, frameless pair.
hookrun(function()
  local sub = setmetatable({}, { __call = string.sub })
  local ok = pcall(sub, 1, 2)
  return ok                                                -- false, both engines
end)                                                      -- HB2

-- HB3: a 15-link chain to a tolerant builtin succeeds and reports the full
-- chain length on its activation.
hookrun(function()
  return (pcall(mkchain(15, type)))
end)                                                     -- HB3: true, ea=15

-- HB4: direct builtin calls as the fast-path control: no chain, no
-- C-chain count on any event, results correct.
hookrun(function()
  collectgarbage("count")
  return string.sub("wxyz", 2, 3)
end)                                                     -- HB4

-- HB5: after chained builtin activations the VM stays usable — the
-- chained collectgarbage calls fail on their shifted first argument in
-- BOTH engines (the frameless pair's argument validation), and the same
-- state still runs a real GC pass and further builtin calls.
do
  local cg = setmetatable({}, { __call = collectgarbage })
  local t = {}
  for i = 1, 500 do t[i] = { k = i } end
  local ok1 = (pcall(cg, "collect"))
  local ok2, n = pcall(cg, "count")
  echo(ok1, ok2, type(n) == "number", #t)
  echo(collectgarbage("count") ~= 0, string.sub("wxyz", 2, 3)) -- reuse control
end
