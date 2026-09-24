-- A1.1 Stage 2 regression guard: a Lua-closure debug hook interpolating
-- between a multret producer and its B==0 consumer must not corrupt the
-- consumer's value count. PUC luaD_hook restores L->top exactly around the
-- hook (lua-5.5.0/src/ldo.c:439-466); luazig's hook frame pop restores the
-- pre-hook top (the frame's original func slot), NOT the parent window.

local function g() return 1, 2, 3 end
local function f(...) return select('#', ...) end

-- Count hooks fire between any two instructions: every producer/consumer
-- pair below is interpolated.
debug.sethook(function() end, "", 1)
assert(f(g()) == 3, "count hook: call-multret miscount")
local function h() return g() end
assert(select('#', h()) == 3, "count hook: return-multret miscount")
local t = {g()}
assert(#t == 3 and t[1] == 1 and t[3] == 3, "count hook: setlist miscount")
local function v(...) return f(...) end
assert(v(7, 8, 9) == 3, "count hook: vararg miscount")
debug.sethook()

-- Line hooks fire on line change: the producer (g's call) and the consumer
-- (f's call) sit on different lines, so a line event interpolates them.
debug.sethook(function() end, "l")
assert(f(
  g()) == 3, "line hook: call-multret miscount")
local function h2() return
  g() end
assert(select('#', h2()) == 3, "line hook: return-multret miscount")
debug.sethook()

print("hook-multret-interp-ok")
