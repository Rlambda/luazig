-- P15.79 regression tests: coroutine.close + pcall + TBC, pcall yield
-- across builtin C-frame, error location with C-frames.
-- All outputs must match PUC Lua exactly.

local func2close = function(f)
  return setmetatable({}, {__close = f})
end

-- 1. coroutine.close with pcall + TBC (no error in __close).
-- PUC lua_resetthread discards ALL frames (including pcall) before luaF_close,
-- so __close runs outside pcall's protection. __close receives nil error.
local function test_close_pcall_tbc_noerr()
  local track = {}
  local function foo()
    local x <close> = func2close(function(_, err)
      track[#track + 1] = err == nil and "nil" or err
    end)
    coroutine.yield(1)
    error("boom")
  end
  local co = coroutine.create(function()
    return pcall(foo)
  end)
  local st, res = coroutine.resume(co)
  assert(st and res == 1, "resume 1 should succeed")
  local st2, msg = coroutine.close(co)
  assert(st2, "close should succeed (no __close error)")
  assert(track[1] == "nil", "__close should receive nil error")
  assert(coroutine.status(co) == "dead")
end

-- 2. coroutine.close with pcall + TBC (__close errors).
-- __close error propagates as the close result. pcall does NOT catch it
-- because lua_resetthread already discarded the pcall frame.
local function test_close_pcall_tbc_err()
  local track = {}
  local function foo()
    local x <close> = func2close(function(_, err)
      track[#track + 1] = err == nil and "nil" or err
      error("close_err")
    end)
    coroutine.yield(1)
  end
  local co = coroutine.create(function()
    return pcall(foo)
  end)
  local st, res = coroutine.resume(co)
  assert(st and res == 1, "resume 1 should succeed")
  local st2, msg = coroutine.close(co)
  assert(not st2, "close should fail (__close error)")
  assert(msg:find("close_err") ~= nil, "error should be close_err")
  assert(track[1] == "nil", "__close should receive nil error")
end

-- 3. pcall yields inside a closure coroutine (trampoline path).
-- The pcall is intercepted by tryPushBytecodeProtectedCall (no pcall C-frame).
-- foo yields, then returns. pcall wraps result as [true, ...ret].
local function test_pcall_yield_closure()
  local function foo()
    coroutine.yield(42)
    return "hello", "world"
  end
  local co = coroutine.create(function()
    local ok, r1, r2 = pcall(foo)
    assert(ok and r1 == "hello" and r2 == "world", "pcall result mismatch")
    return ok, r1, r2
  end)
  local st, res = coroutine.resume(co)
  assert(st and res == 42, "resume 1 should return 42")
  local st2, res1, res2, res3 = coroutine.resume(co)
  assert(st2 and res1 == true and res2 == "hello" and res3 == "world",
    "resume 2 should return pcall results")
  assert(coroutine.status(co) == "dead")
end

-- 4. pcall catches error inside a closure coroutine.
local function test_pcall_error_closure()
  local function foo()
    error("foo_error")
  end
  local co = coroutine.create(function()
    local ok, err = pcall(foo)
    assert(not ok, "pcall should fail")
    assert(err:find("foo_error") ~= nil, "error should be foo_error")
    return ok, err
  end)
  local st, r1, r2 = coroutine.resume(co)
  assert(st, "coroutine should not fail")
  assert(not r1, "pcall ok should be false")
  assert(r2:find("foo_error") ~= nil, "error should propagate")
end

-- 5. Multiple TBC slots with coroutine.close (LIFO order, last error wins).
local function test_close_multiple_tbc()
  local track = {}
  local co = coroutine.create(function()
    local a <close> = func2close(function(_, err)
      track[#track + 1] = "a:" .. (err == nil and "nil" or err)
    end)
    local b <close> = func2close(function(_, err)
      track[#track + 1] = "b:" .. (err == nil and "nil" or err)
      error("b_err")
    end)
    local c <close> = func2close(function(_, err)
      track[#track + 1] = "c:" .. (err == nil and "nil" or err)
      error("c_err")
    end)
    coroutine.yield()
  end)
  local st = coroutine.resume(co)
  assert(st, "resume should succeed")
  local st2, msg = coroutine.close(co)
  assert(not st2, "close should fail")
  assert(msg:find("b_err") ~= nil, "last error (b) should win")
  -- LIFO order: c first (errors with c_err), then b (errors with b_err,
  -- replacing c_err), then a (no error, receives b_err).
  assert(track[1] == "c:nil", "c should close first with nil")
  assert(track[2]:find("c_err") ~= nil, "b should close second with c_err")
  assert(track[3]:find("b_err") ~= nil, "a should close third with b_err")
end

-- 6. pcall yield + coroutine.close (TBC runs during close, not during pcall).
local function test_pcall_yield_then_close()
  local track = {}
  local function foo()
    local x <close> = func2close(function(_, err)
      track[#track + 1] = err == nil and "nil" or tostring(err)
    end)
    coroutine.yield(1)
    return "done"
  end
  local co = coroutine.create(function()
    return pcall(foo)
  end)
  local st, res = coroutine.resume(co)
  assert(st and res == 1)
  -- Close while pcall is suspended: __close runs, pcall does NOT catch it.
  local st2, msg = coroutine.close(co)
  assert(st2, "close should succeed")
  assert(track[1] == "nil", "__close should receive nil")
end

-- 7. Error location: error() called from Lua function has source:line prefix.
-- error() called from C function (builtin) has no source:line prefix.
local function test_error_location()
  -- error() from Lua function: has source:line prefix
  local ok, err = pcall(function()
    error("lua_error")
  end)
  assert(not ok)
  assert(err:find(":%d+: lua_error") ~= nil, "Lua error should have source:line")

  -- error() from C function (coroutine.yield outside coroutine): no prefix
  local ok2, err2 = pcall(coroutine.yield)
  assert(not ok2)
  assert(err2:find(":%d+:") == nil, "C function error should have no source:line")
  assert(err2:find("attempt to yield") ~= nil, "should be yield error")
end

-- 8. coroutine.close with error in __close, then pcall catches the close result.
-- coroutine.close returns (false, err) — NOT an error. pcall sees it as success.
local function test_close_error_caught()
  local co = coroutine.create(function()
    local x <close> = func2close(function(_, err)
      error("close_bang")
    end)
    coroutine.yield()
  end)
  local st = coroutine.resume(co)
  assert(st)
  -- pcall around coroutine.close: close returns (false, err), pcall sees success
  local ok, close_ok, err = pcall(coroutine.close, co)
  assert(ok, "pcall should succeed (close doesn't throw)")
  assert(not close_ok, "close should return false")
  assert(err:find("close_bang") ~= nil, "error should be close_bang")
end

-- Run all tests
test_close_pcall_tbc_noerr()
test_close_pcall_tbc_err()
test_pcall_yield_closure()
test_pcall_error_closure()
test_close_multiple_tbc()
test_pcall_yield_then_close()
test_error_location()
test_close_error_caught()

print("p15-79-regression-ok")
