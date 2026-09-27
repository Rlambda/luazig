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
-- raise (PUC luaD_hook: raise to ci->top).
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
