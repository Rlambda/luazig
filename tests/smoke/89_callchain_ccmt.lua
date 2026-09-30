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

-- Bytecode-lane Lua-hook identity (PUC luaD_precall order: the callee's
-- CallInfo exists BEFORE the call hook fires, so getinfo(2,"ft") from the
-- hook describes the CALLEE activation — func/what/istailcall/extraargs —
-- not the caller). The C-hook control for the same property is 36_ccmt_abi
-- (F7f); the host-origin control is HB1/HB2 above. Every hook body reads
-- getinfo(2) directly (a helper call would shift the level) and logs
-- without calling anything.
local function hclog(fn)
  local log = {}
  local function h(ev)
    local i = debug.getinfo(2, "Sft")
    log[#log + 1] = ev .. "|" .. tostring(i and i.what) ..
      "|" .. tostring(i and i.istailcall) ..
      "|" .. tostring(i and i.extraargs)
  end
  debug.sethook(h, "c")
  local ok, r = fn()
  debug.sethook()
  local parts = {}
  for k, v in ipairs(log) do parts[k] = tostring(v) end
  echo(ok, tostring(r), #log, table.concat(parts, " "))
end

-- HC1: 1-link chain to a builtin from a BYTECODE caller: the activation
-- event sees extraargs = 1 (was the caller-frame 0 before the fix).
hclog(function()
  local ob = setmetatable({}, { __call = type })
  local function f() local x = ob("x") return x end
  return f()                                               -- "string"
end)

-- HC2: 2-link chain from a bytecode caller: extraargs = 2.
hclog(function()
  local mid = setmetatable({}, { __call = type })
  local o2 = setmetatable({}, { __call = mid })
  local function f() local x = o2("x") return x end
  return f()
end)

-- HC3: 15-link chain from a bytecode caller: extraargs = 15.
hclog(function()
  return (mkchain(15, type)("x"))
end)

-- HC4: tail calls. A tail call to a chained BUILTIN still fires a plain
-- "call" on the fresh C activation (PUC pretailcall → precallC pushes a
-- CallInfo without CIST_TAIL); a tail call into a chained LUA closure
-- fires "tail call" on the reused frame (stale count, istailcall = true).
hclog(function()
  local ob = setmetatable({}, { __call = type })
  local function f() return ob("y") end
  return f()
end)
hclog(function()
  local ol = setmetatable({}, { __call = function(_, s) return s end })
  local function f() return ol("z") end
  return f()
end)

-- HC5: vararg callee reached through a chain (the event fires at the
-- callee's VARARGPREP, after the extra arguments are folded — PUC
-- luaG_tracecall skips vararg fresh frames, lvm.c OP_VARARGPREP fires
-- luaD_hookcall): extraargs = links, arguments intact.
hclog(function()
  local ov = setmetatable({}, { __call = function(_, ...) return select("#", ...) end })
  local function f() local n = ov(1, 2, 3) return n end
  return f()
end)
hclog(function()
  local ov = setmetatable({}, { __call = function(_, ...) return select("#", ...) end })
  local function f() return ov(1, 2, 3) end
  return f()                                               -- tail form
end)

-- HC6: a C-closure callee (coroutine.wrap) is a C activation: what="C"
-- from the hook, arguments delivered once, wrap result correct.
hclog(function()
  local w = coroutine.wrap(function() return "wres" end)
  local function f() local r = w() return r end
  return f()
end)

-- HC7: direct-call controls — a direct Lua closure and a direct builtin
-- under the same hook: what/extraargs of the callee activation, plus the
-- vararg direct control.
hclog(function()
  local function dl(s) return s end
  local function dv(...) return select("#", ...) end
  local a = dl("a")
  local b = dv(1, 2)
  return a .. b
end)
hclog(function()
  local function f() local x = type(1) return x end
  return f()
end)

-- HC8: a real GC step inside the hook body while a chained activation is
-- on the stack: the activation's identity stays correct and the callee's
-- arguments survive the collection (the transfer window is owned by the
-- dispatcher for the hook's duration).
hclog(function()
  local ob = setmetatable({}, { __call = function(_, s) return s .. "!" end })
  local function f() local x = ob("arg") return x end
  local log_seen
  local function h(ev)
    local i = debug.getinfo(2, "ft")
    if i and i.func == ob.__call and i.extraargs == 1 then
      log_seen = ev
      collectgarbage("step")
      local j = debug.getinfo(2, "ft")
      log_seen = log_seen .. "|" .. tostring(j and j.extraargs)
    end
  end
  debug.sethook(h, "c")
  local r = f()
  debug.sethook()
  return tostring(r) .. "/" .. tostring(log_seen)
end)

-- HC9: an error raised inside the hook on the chained activation
-- propagates to the caller's pcall with the exact object (level 0 — no
-- position prefix to diverge), and the engine stays usable afterwards.
hclog(function()
  local ob = setmetatable({}, { __call = type })
  local function h(ev)
    local i = debug.getinfo(2, "ft")
    if i and i.func == type and i.extraargs == 1 then error("hookboom", 0) end
  end
  debug.sethook(h, "c")
  local ok, msg = pcall(function() return ob("x") end)
  debug.sethook()
  return tostring(ok) .. "/" .. tostring(msg)
end)

-- HC10: a call-event hook cannot yield (PUC hookf uses lua_call): the
-- yield attempt raises the C-call-boundary error, catchable inside the
-- hook, and the chained call still completes exactly once.
hclog(function()
  local ob = setmetatable({}, { __call = type })
  local co = coroutine.create(function()
    local function h(ev)
      local i = debug.getinfo(2, "ft")
      if i and i.func == type then
        local ok = pcall(coroutine.yield)
        h.yield_denied = tostring(ok)
      end
    end
    debug.sethook(h, "c")
    local r = ob("x")
    debug.sethook()
    return r .. "/" .. tostring(h.yield_denied)
  end)
  local ok, res = coroutine.resume(co)
  return tostring(ok) .. "/" .. tostring(res)
end)

-- HC11: a line hook that yields across a chained call in a coroutine
-- body: on resume the callee runs to completion exactly once (no double
-- execution through the hook machinery).
do
  local ob = setmetatable({}, { __call = function(_, s) return s end })
  local calls = 0
  local co = coroutine.create(function()
    local function h() coroutine.yield("park") end
    debug.sethook(h, "l")
    local r = ob("once")
    debug.sethook()
    return r
  end)
  local ok1, y = coroutine.resume(co)
  local ok2, r = coroutine.resume(co)
  echo(ok1, tostring(y), ok2, tostring(r))
end
