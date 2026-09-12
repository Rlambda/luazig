-- P16.41 Cut 1: ordinary builtin C-frames are REAL and VISIBLE to the
-- debug stack (debug.getinfo levels, traceback, getlocal C-temporary
-- window), matching PUC Lua 5.5's CallInfo model.
-- Ground truth: PUC ldebug.c lua_getstack (level = CallInfo depth),
-- luaG_findlocal (C-frame window = [func+1, top) minus moved-out yield
-- values, name "(C temporary)"), ldo.c lua_yieldk + ldebug.c
-- luaG_traceexec (a yield from a frameless C hook truncates the stack
-- back to the interrupted frame).

local debug = require("debug")

print("testing visible C-frames in debug stack walks")

-- 1. getinfo level 0 inside a Lua function called from a builtin:
--    PUC: level 0 = the builtin's C frame ([C], linedefined -1),
--    level 1 = the Lua function, level 2 = the main chunk.
do
  local levels = {}
  table.sort({3, 1, 2}, function(a, b)
    local i0 = debug.getinfo(0)
    local i1 = debug.getinfo(1)
    levels[0] = { i0.source, i0.linedefined, i0.currentline }
    levels[1] = { i1.source, i1.linedefined }
    return a < b
  end)
  assert(levels[0][1] == "=[C]" and levels[0][2] == -1 and levels[0][3] == -1,
    "level 0 inside sort comparator must be the sort C frame")
  assert(levels[1][2] ~= -1,
    "level 1 inside sort comparator must be the comparator Lua function")
end

-- 2. traceback from inside a builtin callback shows the C frame.
do
  local tb
  table.sort({3, 1, 2}, function(a, b)
    tb = debug.traceback()
    return a < b
  end)
  assert(tb:find("%[C%]: in upvalue 'sort'", 1, true) or
         tb:find("[C]: in ", 1, true),
    "traceback inside comparator must include the sort C frame")
  assert(tb:find("in upvalue 'sort'") or tb:find("'sort'"),
    "traceback should name the sort builtin")
end

-- 3. Suspended coroutine at a plain coroutine.yield: level 0 is the
--    yield builtin's C frame with an EMPTY window (the yielded values
--    moved to the resumer); level 1 is the Lua body.
do
  local co = coroutine.create(function(x)
    local y = coroutine.yield(x)
    return y
  end)
  local ok, v = coroutine.resume(co, 42)
  assert(ok and v == 42)
  local i0 = debug.getinfo(co, 0)
  assert(i0.source == "=[C]" and i0.linedefined == -1,
    "level 0 of yield-suspended co is the yield C frame")
  local n1, v1 = debug.getlocal(co, 0, 1)
  assert(n1 == nil and v1 == nil,
    "yield C frame window is empty after resume moved the values out")
  local i1 = debug.getinfo(co, 1)
  assert(i1.what == "Lua" and i1.currentline ~= -1,
    "level 1 of yield-suspended co is the parked Lua body")
  local nx, vx = debug.getlocal(co, 1, 1)
  assert(nx == "x" and vx == 42, "body local x survives at level 1")
end

-- 4. getlocal on a suspended T.testC C frame reads its C-temporary
--    window: the testC stack minus the moved-out yield values
--    (coroutine.lua:717-722 shape).
do
  local T = T
  if T == nil then T = select(2, pcall(require, "testc")) end
  if T and type(T) == "table" then
    local co = coroutine.create(function() T.testC("yield 1", 10, 20) end)
    local ok, v = coroutine.resume(co)
    assert(ok and v == 20)
    local gi = debug.getinfo(co, 0)
    assert(gi.linedefined == -1, "testC C frame at level 0")
    local name, val = debug.getlocal(co, 0, 2)
    assert(name == "(C temporary)" and val == 10,
      "getlocal(co, 0, 2) reads the testC C window below the moved-out value")
    local tb = debug.traceback(co)
    assert(tb:find("%[C%]: in field 'testC'") or tb:find("[C]: in "),
      "traceback names the parked testC C frame")
  end
end

-- 5. Yield from a frameless C hook (testC "yield 0" line hook via
--    T.sethook): the suspended stack is truncated back to the
--    interrupted Lua frame — level 0 is the coroutine body, level 1 is
--    nil (PUC luaG_traceexec's luaD_throw after a hook yield).
do
  local T = T
  if T == nil then T = select(2, pcall(require, "testc")) end
  if T and type(T) == "table" and T.sethook then
    local co = coroutine.create(function(a)
      T.sethook("yield 0", "l") -- yields on the next line's hook event
      local b = a
      return b
    end)
    local ok, v = coroutine.resume(co, 1)
    assert(ok, tostring(v))
    local i0 = debug.getinfo(co, 0)
    assert(i0.what == "Lua" and i0.currentline ~= -1,
      "level 0 after hook yield is the interrupted Lua frame")
    assert(debug.getinfo(co, 1) == nil,
      "no frame above the interrupted frame after a hook yield")
    local na, va = debug.getlocal(co, 0, 1)
    assert(na == "a" and va == 1,
      "interrupted frame's locals readable at level 0 after hook yield")
    local tb = debug.traceback(co)
    assert(not tb:find("%[C%]"), "no C frames in the hook-yield traceback")
    T.sethook()
  end
end

print("OK")
