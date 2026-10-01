-- pcall/xpcall recovery and errfunc lifetime across yields (PUC 5.5
-- lua_pcallk yieldable path + ldo.c finishpcallk), in ordinary coroutines
-- (yy=1) and inside non-yieldable C boundaries (yy=0):
--   * pcall/xpcall entered from a yieldable thread arm CIST_YPCALL and
--     DEFER error recovery to the resume boundary: the callee's error is
--     not caught locally; precover closes the TBC region yieldably and
--     finishpcallk publishes [false, err].
--   * The armed errfunc (NONE for pcall, the handler for xpcall) stays
--     armed across a yield suspension (luaD_throw(LUA_YIELD) unwinds past
--     lua_pcallk without running its restore) and until finishpcallk
--     closes the region — a closer erroring during the recovery close
--     still runs the handler; errors outside the protected extent after
--     its completion do not.
--   * A non-yieldable context (main thread, C boundary like table.sort)
--     takes the conventional branch: local catch, yy=0 region close.
--
-- Determinism rules: errors are raised with level 0 or as tables (no
-- position prefixes); objects are compared with rawequal, never printed;
-- the table.sort comparator log is invocation-count independent (the
-- comparator count is not specified by the language).
-- Differential: C Lua 5.5.0 vs luazig --engine=zig (pure Lua, no testc).

local results = {}
local function emit(name, ...)
  local t = { ... }
  for i = 1, #t do t[i] = tostring(t[i]) end
  results[#results + 1] = name .. " " .. table.concat(t, ",")
end
local function flush()
  for i = 1, #results do print(results[i]) end
end

-- N1: outer xpcall wraps inner pcall; the inner callee yields, then
-- errors. The inner pcall owns the recovery: the outer handler must NOT
-- run for the inner error (pcall's errfunc is NONE), xpcall completes
-- normally with pcall's [false, err].
do
  local log = {}
  local co = coroutine.create(function()
    return xpcall(function()
      local ok, err = pcall(function()
        coroutine.yield("pause")
        error("inner", 0)
      end)
      return ok, err
    end, function(err)
      log[#log + 1] = "outer-handler:" .. tostring(err)
      return "H:" .. tostring(err)
    end)
  end)
  emit("N1_r1", coroutine.resume(co))
  emit("N1_r2", coroutine.resume(co))
  emit("N1_log", table.concat(log, ","))
  emit("N1_status", coroutine.status(co))
end

-- N2: inner xpcall with its own handler, outer pcall. The handler runs at
-- the throw site (after the resume), xpcall recovers, the outer pcall
-- completes normally.
do
  local log = {}
  local co = coroutine.create(function()
    local ok, a, b = pcall(function()
      coroutine.yield("p1")
      return xpcall(function()
        coroutine.yield("x1")
        error("deep", 0)
      end, function(e)
        log[#log + 1] = "h:" .. tostring(e)
        return "HR"
      end)
    end)
    return ok, a, b
  end)
  emit("N2_r1", coroutine.resume(co))
  emit("N2_r2", coroutine.resume(co))
  emit("N2_r3", coroutine.resume(co))
  emit("N2_log", table.concat(log, ","))
  emit("N2_status", coroutine.status(co))
end

-- N3: three levels — xpcall(h1) -> pcall -> xpcall(h2), innermost body
-- yields twice then errors with a TABLE object. h2 must transform the
-- error; neither pcall nor h1 sees it.
do
  local log = {}
  local marker = { tag = "orig" }
  local co = coroutine.create(function()
    local ok1, a, b, c = xpcall(function()
      local ok2, r1, r2 = pcall(function()
        local ok3, e3 = xpcall(function()
          coroutine.yield("y1")
          coroutine.yield("y2")
          error(marker, 0)
        end, function(e)
          log[#log + 1] = "h2:" .. tostring(rawequal(e, marker))
          return { tag = "h2out", orig = e }
        end)
        return ok3, e3
      end)
      return ok2, r1, r2
    end, function(e)
      log[#log + 1] = "h1:ran"
      return "H1"
    end)
    return ok1, a, b, c ~= nil and c.tag or "nil", c ~= nil and rawequal(c.orig, marker) or false
  end)
  emit("N3_r1", coroutine.resume(co))
  emit("N3_r2", coroutine.resume(co))
  emit("N3_r3", coroutine.resume(co))
  emit("N3_log", table.concat(log, ","))
  emit("N3_status", coroutine.status(co))
end

-- N4: after the inner pcall completes across a yield, the outer xpcall's
-- handler must be armed AGAIN for a later error OUTSIDE the inner pcall
-- (the inner pcall's ERRFUNC_NONE must not leak past its completion).
do
  local log = {}
  local co = coroutine.create(function()
    local ok, a, b = xpcall(function()
      local ok2 = pcall(function()
        coroutine.yield("p")
      end)
      log[#log + 1] = "inner:" .. tostring(ok2)
      error("late", 0)
    end, function(e)
      log[#log + 1] = "H:" .. tostring(e)
      return "HR:" .. tostring(e)
    end)
    return ok, a, b
  end)
  emit("N4_r1", coroutine.resume(co))
  emit("N4_r2", coroutine.resume(co))
  emit("N4_log", table.concat(log, ","))
  emit("N4_status", coroutine.status(co))
end

-- R1: yielding __close under xpcall on the error path: the recovery close
-- suspends (r1), resumes (r2), and a closer error on the resumed drive
-- runs the still-armed handler (PUC finishpcallk closes BEFORE restoring
-- errfunc); the final error object is the handler's result.
do
  local log = {}
  local co = coroutine.create(function()
    local ok, a, b = xpcall(function()
      local x <close> = setmetatable({}, { __close = function(o, e)
        log[#log + 1] = "cl:" .. tostring(e)
        coroutine.yield("inclose")
        error("CERR", 0)
      end })
      error("boom", 0)
    end, function(e)
      log[#log + 1] = "H:" .. tostring(e)
      return "HR:" .. tostring(e)
    end)
    return "xp", ok, a, b
  end)
  emit("R1_r1", coroutine.resume(co))
  emit("R1_r2", coroutine.resume(co))
  emit("R1_log", table.concat(log, ","))
  emit("R1_status", coroutine.status(co))
end

-- R2: same shape under plain pcall (errfunc NONE): a closer error on the
-- resumed drive propagates untransformed; pcall returns the closer's
-- error object (last-error-wins across the re-drive).
do
  local log = {}
  local co = coroutine.create(function()
    local ok, err = pcall(function()
      local x <close> = setmetatable({}, { __close = function(o, e)
        log[#log + 1] = "cl:" .. tostring(e)
        coroutine.yield("inclose")
        error("CERR", 0)
      end })
      error("boom", 0)
    end)
    return "p", ok, err
  end)
  emit("R2_r1", coroutine.resume(co))
  emit("R2_r2", coroutine.resume(co))
  emit("R2_log", table.concat(log, ","))
  emit("R2_status", coroutine.status(co))
end

-- R3: yielding __close on the NORMAL return path under xpcall: the
-- return-path close suspends; after completion the handler must be
-- disarmed (a later error in the same coroutine runs NO handler).
do
  local log = {}
  local co = coroutine.create(function()
    local ok, a = xpcall(function()
      local x <close> = setmetatable({}, { __close = function()
        coroutine.yield("inclose")
      end })
      return "fret"
    end, function(e)
      log[#log + 1] = "H:" .. tostring(e)
      return "HR"
    end)
    log[#log + 1] = "xp:" .. tostring(ok) .. ":" .. tostring(a)
    error("late", 0)
  end)
  emit("R3_r1", coroutine.resume(co))
  emit("R3_r2", coroutine.resume(co))
  emit("R3_log", table.concat(log, ","))
  emit("R3_status", coroutine.status(co))
end

-- R4: inner pcall's suspended return-close must not leak ERRFUNC_NONE:
-- after the inner pcall completes, the outer xpcall handler sees a later
-- error.
do
  local log = {}
  local co = coroutine.create(function()
    local ok, a, b = xpcall(function()
      local ok2, a2 = pcall(function()
        local x <close> = setmetatable({}, { __close = function()
          coroutine.yield("inclose")
        end })
        return "fret"
      end)
      log[#log + 1] = "p:" .. tostring(ok2) .. ":" .. tostring(a2)
      error("late", 0)
    end, function(e)
      log[#log + 1] = "H:" .. tostring(e)
      return "HR:" .. tostring(e)
    end)
    return ok, a, b
  end)
  emit("R4_r1", coroutine.resume(co))
  emit("R4_r2", coroutine.resume(co))
  emit("R4_log", table.concat(log, ","))
  emit("R4_status", coroutine.status(co))
end

-- R5: xpcall handler ERRORS at the throw site: "error in error handling"
-- (LUA_ERRERR), the coroutine dies; nothing else runs afterwards.
do
  local log = {}
  local co = coroutine.create(function()
    local ok, a = xpcall(function()
      error("boom", 0)
    end, function(e)
      error("in-handler", 0)
    end)
    log[#log + 1] = "unreachable"
    return "xp", ok, a
  end)
  emit("R5_r1", coroutine.resume(co))
  emit("R5_r2", coroutine.resume(co))
  emit("R5_log", table.concat(log, ","))
  emit("R5_status", coroutine.status(co))
end

-- R6: xpcall handler YIELDS at the throw site: handlers run non-yieldable
-- (PUC luaG_errormsg -> luaD_callnoyield): the yield attempt becomes an
-- error -> error in error handling.
do
  local log = {}
  local co = coroutine.create(function()
    local ok, a = xpcall(function()
      error("boom", 0)
    end, function(e)
      coroutine.yield("hy")
      return "HR"
    end)
    return "xp", ok, a
  end)
  emit("R6_r1", coroutine.resume(co))
  emit("R6_r2", coroutine.resume(co))
  emit("R6_status", coroutine.status(co))
end

-- T1: OP_TAILCALL entry into pcall: `return pcall(f)` with a yielding
-- close and an error — same recovery contract as the OP_CALL entry.
do
  local log = {}
  local co = coroutine.create(function()
    local function driver()
      return pcall(function()
        local x <close> = setmetatable({}, { __close = function(o, e)
          log[#log + 1] = "cl:" .. tostring(e)
          coroutine.yield("inclose")
        end })
        error("boom", 0)
      end)
    end
    return "tc", driver()
  end)
  emit("T1_r1", coroutine.resume(co))
  emit("T1_r2", coroutine.resume(co))
  emit("T1_log", table.concat(log, ","))
  emit("T1_status", coroutine.status(co))
end

-- T2: OP_TAILCALL into xpcall with handler: handler runs at the throw
-- site, xpcall result [false, transformed].
do
  local log = {}
  local co = coroutine.create(function()
    local function driver()
      return xpcall(function()
        coroutine.yield("p")
        error("boom", 0)
      end, function(e)
        log[#log + 1] = "H:" .. tostring(e)
        return "HR"
      end)
    end
    return "tc", driver()
  end)
  emit("T2_r1", coroutine.resume(co))
  emit("T2_r2", coroutine.resume(co))
  emit("T2_log", table.concat(log, ","))
  emit("T2_status", coroutine.status(co))
end

-- E1: pcall inside a NON-YIELDABLE C boundary (table.sort comparator in a
-- coroutine): the conventional branch. A <close> closer attempting to
-- yield there becomes "attempt to yield across a C-call boundary" as the
-- closer error (last-error-wins, all closers run), caught by the inner
-- pcall; the comparator runs to completion and sort succeeds.
do
  local log = {}
  local first = true
  local co = coroutine.create(function()
    local arr = { 3, 1, 2 }
    table.sort(arr, function(a, b)
      local ok, err = pcall(function()
        local x <close> = setmetatable({}, { __close = function(o, e)
          if first then log[#log + 1] = "cl:" .. tostring(e) end
          coroutine.yield("nope")
          if first then log[#log + 1] = "unreachable" end
        end })
        if first then log[#log + 1] = "body" end
        error("boom", 0)
      end)
      if first then
        log[#log + 1] = "p:" .. tostring(ok) .. ":" .. tostring(err)
        first = false
      end
      return a < b
    end)
    return "sorted", arr[1], arr[2], arr[3]
  end)
  emit("E1_r1", coroutine.resume(co))
  emit("E1_log", table.concat(log, ","))
  emit("E1_status", coroutine.status(co))
end

-- C1: coroutine suspended across a pcall/xpcall yield, then forcibly
-- closed: the armed handler must NOT run during the forced close
-- (PUC resetCI clears the errfunc before closeprotected); the closer runs
-- once with the close error; close reports success.
do
  local log = {}
  local co = coroutine.create(function()
    local ok = xpcall(function()
      local x <close> = setmetatable({}, { __close = function(o, e)
        log[#log + 1] = "cl:" .. tostring(e)
      end })
      coroutine.yield("parked")
      return "never"
    end, function(e)
      log[#log + 1] = "H:" .. tostring(e)
      return "HR"
    end)
    return ok
  end)
  emit("C1_r1", coroutine.resume(co))
  emit("C1_close", coroutine.close(co))
  emit("C1_log", table.concat(log, ","))
  emit("C1_status", coroutine.status(co))
end

-- C2: forced close of a coroutine suspended INSIDE the recovery close
-- (yielding closer under pcall): the remaining close runs with the
-- pending error object; no handler, no second close of the first closer.
do
  local log = {}
  local co = coroutine.create(function()
    local ok, err = pcall(function()
      local x <close> = setmetatable({}, { __close = function(o, e)
        log[#log + 1] = "cl1:" .. tostring(e)
        coroutine.yield("inclose")
        log[#log + 1] = "cl1:after"
      end })
      error("boom", 0)
    end)
    return "unreachable"
  end)
  emit("C2_r1", coroutine.resume(co))
  emit("C2_close", coroutine.close(co))
  emit("C2_log", table.concat(log, ","))
  emit("C2_status", coroutine.status(co))
end

-- V1: VM reuse after everything above: fresh coroutines, plain pcall and
-- xpcall behave normally (no stale errfunc from any earlier state).
do
  local log = {}
  local co = coroutine.create(function()
    return pcall(function() return "plain" end)
  end)
  emit("V1_pcall", coroutine.resume(co))
  local ok, r = xpcall(function() error("vboom", 0) end, function(e)
    return "VH:" .. tostring(e)
  end)
  emit("V1_xpcall", ok, r)
  local co2 = coroutine.create(function()
    coroutine.yield("v")
    return "done2"
  end)
  emit("V1_c2a", coroutine.resume(co2))
  emit("V1_c2b", coroutine.resume(co2))
  emit("V1_log", table.concat(log, ","))
end

flush()
