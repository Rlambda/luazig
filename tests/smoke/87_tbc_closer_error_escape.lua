-- TBC closer-error escape (PUC 5.5 yy table): a Lua-closer error during a
-- YIELDABLE unprotected close (OP_CLOSE / OP_RETURN / failed-resume unwind /
-- pcall recovery, yy=1) stops the close region — the remaining entries stay
-- in the chain and close at the recovery boundary (the pcall that catches
-- the error, or coroutine.close) with the then-current error object.
-- Protected/forced closes (yy=0, closeprotected) keep the eager
-- continue-and-close-all behavior with last-error-wins.
-- Differential: C Lua 5.5.0 vs luazig --engine=zig (pure Lua, no testc).

local function func2close(f) return setmetatable({}, {__close = f}) end

-- [1] normal-return lane: the body returns cleanly; the newest closer (v2)
-- runs with err=nil and errors — the close STOPS; v1 is NOT closed now and
-- defers to coroutine.close, which closes it with the stored error object.
do
  local log = {}
  local co = coroutine.create(function()
    local v1 <close> = func2close(function(_, err) log[#log + 1] = "v1:" .. tostring(err) end)
    local v2 <close> = func2close(function(_, err) log[#log + 1] = "v2:" .. tostring(err); error("cerr") end)
    coroutine.yield()
  end)
  local st = coroutine.resume(co)
  print("c1-yield", st, #log)
  st, msg = coroutine.resume(co)
  print("c1-resume2", st, msg, #log, table.concat(log, ","))
  local ok, err = coroutine.close(co)
  print("c1-close", ok, err, #log, table.concat(log, ","))
  ok, err = coroutine.close(co)
  print("c1-close2", ok, err, #log)
end

-- [2] failed-resume lane: the body errors; the newest closer runs with the
-- body's error and errors itself — v1 defers to coroutine.close and closes
-- with the CLOSER's error (last-error-wins across the deferral).
do
  local log = {}
  local co = coroutine.create(function()
    local v1 <close> = func2close(function(_, err) log[#log + 1] = "v1:" .. tostring(err) end)
    local v2 <close> = func2close(function(_, err) log[#log + 1] = "v2:" .. tostring(err); error("e2") end)
    coroutine.yield()
    error("orig")
  end)
  coroutine.resume(co)
  local st, msg = coroutine.resume(co)
  print("c2-resume2", st, msg, #log, table.concat(log, ","))
  local ok, err = coroutine.close(co)
  print("c2-close", ok, err, #log, table.concat(log, ","))
end

-- [3] pcall recovery boundary: the remainder closes BEFORE pcall returns,
-- with the closer's error (the original error is replaced,
-- last-error-wins).
do
  local log = {}
  local st, msg = pcall(function()
    local v1 <close> = func2close(function(_, err) log[#log + 1] = "v1:" .. tostring(err) end)
    local v2 <close> = func2close(function(_, err) log[#log + 1] = "v2:" .. tostring(err); error("e2") end)
    error("orig")
  end)
  print("c3-pcall", st, msg, table.concat(log, ","))
end

-- [3b] two failing closers: the boundary re-drive closes the second one
-- with the first closer's error; its own error then wins (last-error-wins).
do
  local log = {}
  local st, msg = pcall(function()
    local v1 <close> = func2close(function(_, err) log[#log + 1] = "v1:" .. tostring(err); error("e1") end)
    local v2 <close> = func2close(function(_, err) log[#log + 1] = "v2:" .. tostring(err); error("e2") end)
    error("orig")
  end)
  print("c3b-pcall", st, msg, table.concat(log, ","))
end

-- [4] explicit OP_CLOSE (block exit): the newest closer errors on the
-- clean block-exit close; the remainder closes at the pcall boundary.
do
  local log = {}
  local st, msg = pcall(function()
    do
      local v1 <close> = func2close(function(_, err) log[#log + 1] = "v1:" .. tostring(err) end)
      local v2 <close> = func2close(function(_, err) log[#log + 1] = "v2:" .. tostring(err); error("inblock") end)
    end
    return "unreachable"
  end)
  print("c4-opclose", st, msg, table.concat(log, ","))
end

-- [4b] normal OP_RETURN: clean function return, newest closer errors.
do
  local log = {}
  local st, msg = pcall(function()
    local v1 <close> = func2close(function(_, err) log[#log + 1] = "v1:" .. tostring(err) end)
    local v2 <close> = func2close(function(_, err) log[#log + 1] = "v2:" .. tostring(err); error("ret") end)
    return 1
  end)
  print("c4b-opreturn", st, msg, table.concat(log, ","))
end

-- [4c] builtin (__close = tostring) closer inside an escaping region: the
-- deferred builtin close runs silently at the boundary.
do
  local log = {}
  local st, msg = pcall(function()
    local v1 <close> = setmetatable({}, {__close = tostring})
    local v2 <close> = func2close(function(_, err) log[#log + 1] = "v2:" .. tostring(err); error("b") end)
    return 1
  end)
  print("c4c-builtin", st, msg, table.concat(log, ","))
end

-- [4d] forced close (coroutine.close on a SUSPENDED coroutine): yy=0
-- closeprotected — the close CONTINUES past the closer error; every entry
-- closes, last-error-wins, and the close itself reports the error.
do
  local log = {}
  local co = coroutine.create(function()
    local v1 <close> = func2close(function(_, err) log[#log + 1] = "v1:" .. tostring(err) end)
    local v2 <close> = func2close(function(_, err) log[#log + 1] = "v2:" .. tostring(err); error("force") end)
    coroutine.yield()
  end)
  coroutine.resume(co)
  local ok, err = coroutine.close(co)
  print("c4d-forced", ok, err, table.concat(log, ","))
  ok, err = coroutine.close(co)
  print("c4d-forced2", ok, err, #log)
end

-- [4e] builtin erroring closer (__close = error, raising its own object;
-- deterministic via __tostring) in a yy=1 coroutine-body return close: the
-- escape defers the older entry to coroutine.close (close reports
-- false + the closer's object); an eager continue would close the older
-- entry inside the return close and coroutine.close would report true.
do
  local log = {}
  local co = coroutine.create(function()
    local v0 <close> = func2close(function(_, err) log[#log + 1] = "v0:" .. tostring(err) end)
    local v1 <close> = setmetatable({}, {
      __close = error,
      __tostring = function() return "V1ERR" end,
    })
    return 1
  end)
  local ok, err = coroutine.resume(co)
  print("c4e-resume", ok, tostring(err))
  ok, err = coroutine.close(co)
  print("c4e-close", ok, tostring(err), table.concat(log, ","))
end

-- [5] non-string error object: identity preserved through the escape, the
-- failed resume, a GC cycle, and the deferred close at coroutine.close.
do
  local cerr = {tag = "CERR"}
  local seen
  local co = coroutine.create(function()
    local v1 <close> = func2close(function(_, err) seen = err end)
    local v2 <close> = func2close(function(_) error(cerr) end)
    coroutine.yield()
  end)
  coroutine.resume(co)
  local st, msg = coroutine.resume(co)
  print("c5-resume2", st, msg == cerr)
  collectgarbage()
  collectgarbage()
  local ok, err = coroutine.close(co)
  print("c5-close", ok, err == cerr, seen == cerr)
end

-- post-escape sanity: ordinary control flow still correct
local s = 0
for i = 1, 100 do s = s + i end
print("post:", s)
