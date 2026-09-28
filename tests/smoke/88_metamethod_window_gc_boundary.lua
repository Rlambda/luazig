-- Metamethod staging vs the GC-visible stack top (PUC ci->top parity).
-- Every metamethod/hook/__close activation stages its callee+args at the
-- caller's published top; PUC's bound is ci->top = frameBase + maxstacksize
-- (the register file end), NOT the grown window (maxstacksize + EXTRA_MARGIN).
-- The bound decides whether a stale slot at the file end is clobbered by the
-- staged callee (PUC: yes) or survives inside the GC-marked region and is
-- retained through a collectgarbage() inside the metamethod (weak-table
-- observable). The dead object is planted by make() at exactly the caller's
-- ci->top (make's first local past the pad lands there when the call
-- register is the caller's last live register); section [11] plants it in
-- a dead multret slot ABOVE the register file instead (a B==0 producer's
-- leftover that the metamethod savestate plain-set drops back to the file
-- end — PUC lvm.c:1151).
-- Also covers the __close staging bounds (PUC prepcallclosemth per path:
-- OP_RETURN k = max(top, ci->top); OP_CLOSE = level+1; error unwind =
-- level+2 with the error object written at level+1) and the debug-hook
-- raise (PUC luaD_hook: raise to ci->top), plus the luaG_traceexec
-- correct-top (PUC ldebug.c:955-957: before count/line hooks, a non-IT
-- upcoming instruction gets top plain-set to ci->top; an IT upcoming
-- consumer keeps its live multret bound GC-visible through the hook).
-- Section [14] covers the full luaG_traceexec dispatch order (PUC
-- ldebug.c:947-967): the count budget is consumed and the count hook
-- dispatched BEFORE the line hook; a completed count hook's return
-- clobbers L->oldpc to the current instruction (rethook, ldo.c:511-512),
-- so the line hook fires for the SAME instruction right after it; each
-- executed instruction consumes the budget exactly once across the
-- hook-completion re-entry passes; a count-only mask without a hit
-- returns before the correct-top (ldebug.c:950-951); a stripped proto's
-- count hit publishes top through the same lineinfo-independent owner
-- (ldebug.c:956-957); a hook yield suppresses every hook on the replayed
-- opcode (CIST_HOOKYIELD, ldebug.c:952-955).
-- Differential: C Lua 5.5.0 vs luazig --engine=zig (pure Lua, no testc).

local weak = setmetatable({}, {__mode = "v"})

local function make(npads)
  -- object lands at make-base + npads + 1; with the caller's call register
  -- at its last live register this is exactly the caller's ci->top.
  local o
  if npads == 0 then
    o = {}
  elseif npads == 1 then
    local pad = 7
    o = {pad}
  elseif npads == 2 then
    local p1, p2 = 1, 2
    o = {p1, p2}
  else
    local p1, p2, p3 = 1, 2, 3
    o = {p1, p2, p3}
  end
  weak[1] = o
  return 1
end

-- [1] __add simple-result lane: the arithmetic metamethod stages at
-- ci->top; the stale object there must be clobbered (freed).
do
  local trigger = setmetatable({}, {__add = function()
    collectgarbage(); collectgarbage()
    return weak[1] == nil
  end})
  local function caller()
    local x = make(1)
    x = nil
    return trigger + 1
  end
  print("add", caller(), weak[1] == nil)
end

-- [2] __concat pending lane: same staging bound through the concat
-- metamethod call.
do
  local trigger = setmetatable({}, {__concat = function()
    collectgarbage(); collectgarbage()
    return "r"
  end})
  local function caller()
    local x = make(1)
    x = nil
    return "s" .. trigger
  end
  print("concat", caller(), weak[1] == nil)
end

-- [3] __lt compare lane: the compare metamethod completion leaves top at
-- the staged bound; the stale object at ci->top must not be retained
-- through a GC inside the metamethod.
do
  local trigger = setmetatable({}, {__lt = function()
    collectgarbage(); collectgarbage()
    return true
  end})
  local function caller()
    local x = make(1)
    x = nil
    return trigger < 1
  end
  print("lt", caller(), weak[1] == nil)
end

-- [4] yield/resume across the metamethod: the __add metamethod yields
-- mid-flight; the suspension/resume must preserve the staging bound (the
-- stale object stays clobbered after the resume).
do
  local trigger = setmetatable({}, {__add = function()
    coroutine.yield("y")
    collectgarbage(); collectgarbage()
    return weak[1] == nil
  end})
  local function caller()
    local x = make(1)
    x = nil
    return trigger + 1
  end
  local co = coroutine.create(function() return caller() end)
  local ok1, v = coroutine.resume(co)
  local ok2, r = coroutine.resume(co)
  print("yield", ok1, v, ok2, r)
end

-- [5] __close on OP_RETURN (CLOSEKTOP): PUC lvm.c raises top to ci->top
-- before luaF_close; the staged closer clobbers the stale object there.
do
  local closer = setmetatable({}, {__close = function()
    collectgarbage(); collectgarbage()
  end})
  local function parent()
    local x <close> = closer
    local y = make(1)
    y = nil
    return 1
  end
  print("close-ret", parent(), weak[1] == nil)
end

-- [6] __close on the error unwind: PUC writes the error object at level+1
-- and stages the closer at level+2; a stale object at either slot is
-- clobbered/freed.
do
  local closer = setmetatable({}, {__close = function()
    collectgarbage(); collectgarbage()
  end})
  local function parent()
    local x <close> = closer
    local pad = make(1)
    pad = nil
    error("boom")
  end
  local ok, err = pcall(parent)
  print("close-err", ok, err, weak[1] == nil)
end

-- [7] __close on OP_CLOSE (LUA_OK): PUC sets top = level+1 ("call will be
-- at this level"); the staged closer clobbers the stale slots at
-- level+1/level+2.
do
  local closer = setmetatable({}, {__close = function()
    collectgarbage(); collectgarbage()
  end})
  local function parent()
    do
      local x <close> = closer
      local pad = make(1)
      pad = nil
    end
    return 1
  end
  parent()
  print("close-blk", weak[1] == nil)
end

-- [8] __close arity: the no-error paths pass exactly one argument (PUC
-- callclosemethod with err == NULL).
do
  local n
  local closer = setmetatable({}, {__close = function(...) n = select('#', ...) end})
  do local x <close> = closer end
  print("close-arity-blk", n)
  local function f()
    local x <close> = closer
    return 1
  end
  f()
  print("close-arity-ret", n)
end

-- [9] count hook: PUC luaD_hook raises top to ci->top before staging the
-- hook frame; the stale object at ci->top is clobbered by the staged hook
-- closure.
do
  local function caller()
    local x = make(1)
    x = nil
    local y = 7
    y = nil
    return y
  end
  debug.sethook(function() collectgarbage() end, "", 1)
  local r = caller()
  debug.sethook()
  print("hook-count", r, weak[1] == nil)
end

-- [10] return hook on a builtin call: the builtin's return hook runs with
-- top at the caller's ci->top (PUC poscall + luaD_hook raise); the stale
-- object there is clobbered by the staged hook closure.
do
  local function caller()
    local x = make(3)
    x = nil
    local y = string.rep("a", 2)
    return 1
  end
  debug.sethook(function() collectgarbage(); collectgarbage() end, "r")
  caller()
  debug.sethook()
  print("hook-ret-builtin", weak[1] == nil)
end

-- [11] high rolling top after a B==0 multret consumer: many() returns 25
-- values, {many()} (SETLIST B==0) consumes them but leaves the rolling top
-- ABOVE the caller's register file, with the weak-registered object parked
-- in a dead multret slot beyond the file end. The next metamethod's
-- savestate is a PLAIN SET to ci->top (PUC lvm.c:1151 savestate — raised
-- or lowered): the dead multret slots above the file end become
-- GC-invisible, so the object dies in the metamethod's collectgarbage;
-- after the metamethod the VM continues on the lowered top and the next
-- GC cycle keeps the object dead.
do
  local trigger = setmetatable({}, {__add = function()
    collectgarbage(); collectgarbage()
    return weak[1] == nil
  end})
  local function many()
    local o = {}
    weak[1] = o
    return 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,o
  end
  local function caller()
    local t = {many()}
    t = nil
    return trigger + 1
  end
  local r = caller()
  collectgarbage()
  print("add-high-top", r, weak[1] == nil)
end

-- [12] luaG_traceexec correct-top (PUC ldebug.c:955-957): the B==0 SETLIST
-- consumed the multret but left the rolling top above the register file,
-- with the weak object parked in a dead multret slot beyond the file end.
-- Before the next non-IT instruction, traceexec plain-sets top to
-- ci->top (it may LOWER): the dead slot becomes GC-invisible inside the
-- count hook's collectgarbage. Without the correct-top the hook stages at
-- the stale high top and the dead slot stays inside the GC-scanned region.
do
  local function many()
    local o = {}
    weak[1] = o
    return 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,o
  end
  local armed, seen
  local function caller()
    local t = {many()}
    t = nil
    armed = true
    local x = 1
    return x
  end
  debug.sethook(function()
    if armed and seen == nil then
      collectgarbage(); collectgarbage()
      seen = weak[1] == nil
    end
  end, "", 1)
  caller()
  debug.sethook()
  print("hook-top", seen, weak[1] == nil)
end

-- [13] IT control for the correct-top: the count hook fires between the
-- CALL C==0 producer and the SETLIST B==0 consumer — the upcoming
-- instruction is IT, so traceexec must NOT correct top: the live multret
-- bound (the object reachable only through the multret slot above the
-- file) stays GC-visible through the hook's collectgarbage, and the
-- consumer reads all 25 values with identity preserved. A blanket
-- correct-top (no isIT test) would lower top past the live multret: the
-- object dies inside the hook's collection and the consumer's count
-- truncates.
do
  local armed, died
  local function many()
    local o = {}
    weak[1] = o
    armed = true
    return 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,o
  end
  local function caller()
    local t = {many()}
    return #t, t[25] == weak[1]
  end
  debug.sethook(function()
    if armed then
      collectgarbage()
      if weak[1] == nil then died = true end
    end
  end, "", 1)
  local n, same = caller()
  debug.sethook()
  print("hook-it-live", died, n, same)
end

-- [14] combined COUNT+LINE dispatch order (PUC luaG_traceexec,
-- ldebug.c:947-967): the count budget is consumed and the count hook
-- dispatched BEFORE the line hook; per traced instruction the event order
-- is count then line, and hook-completion re-entries produce no duplicate
-- line event. count=3 interleaves hits with line events (budget
-- accounting); a count-only budget>1 hit publishes top exactly at the hit
-- (ldebug.c:950-951 returns before the correct-top while the budget
-- lasts); a stripped proto's count hit publishes top through the same
-- lineinfo-independent owner (ldebug.c:956-957); a count-hook yield must
-- not re-fire any hook on the replayed opcode (CIST_HOOKYIELD).
do
  local out = {}
  debug.sethook(function(ev) out[#out + 1] = ev end, "l", 1)
  local x = 1
  local y = 2
  debug.sethook()
  print("hook-order", table.concat(out, ","), x, y)

  local out3 = {}
  debug.sethook(function(ev) out3[#out3 + 1] = ev end, "l", 3)
  local a = 1
  local b = 2
  local c = 3
  debug.sethook()
  print("hook-order-3", table.concat(out3, ","))

  local armed2, seen2
  local function many2()
    local o = {}
    weak[1] = o
    return 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,o
  end
  local function caller2()
    local t = {many2()}
    t = nil
    armed2 = true
    local x = 1
    local y = 2
    return x + y
  end
  debug.sethook(function()
    if armed2 and seen2 == nil then
      collectgarbage(); collectgarbage()
      seen2 = weak[1] == nil
    end
  end, "", 2)
  caller2()
  debug.sethook()
  print("hook-budget2", seen2, weak[1] == nil)

  armed3 = false
  local seen3
  local function h0(w)
    local function many3()
      local o = {}
      w[1] = o
      return 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,o
    end
    local t = {many3()}
    t = nil
    armed3 = true
    return 1
  end
  local h = assert(load(string.dump(h0, true)))
  debug.sethook(function()
    if armed3 and seen3 == nil then
      collectgarbage(); collectgarbage()
      seen3 = weak[1] == nil
    end
  end, "", 1)
  h(weak)
  debug.sethook()
  print("hook-stripped-top", seen3, weak[1] == nil)

  local co = coroutine.create(function()
    local outy = {}
    debug.sethook(function(ev)
      outy[#outy + 1] = ev
      if #outy == 1 then coroutine.yield("y") end
    end, "l", 1)
    local x = 1
    debug.sethook()
    return table.concat(outy, ",")
  end)
  local ok1, yv = coroutine.resume(co)
  local ok2, r = coroutine.resume(co)
  print("hook-yield-order", ok1, yv, ok2, r)
end
