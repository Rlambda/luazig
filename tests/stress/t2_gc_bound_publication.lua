-- GC root-bound publication parity (t2): every MayGC window inside an
-- instruction runs under the PUC-published rolling live limit (lvm.c
-- savestate/halfProtect order: OP_CALL/OP_TAILCALL `if (b != 0)
-- L->top.p = ra + b` BEFORE precall, OP_CONCAT `L->top.p = ra + n` BEFORE
-- luaV_concat, OP_TFORCALL `L->top.p = ra + 3 + 3` BEFORE the iterator
-- call, OP_SETLIST `L->top.p = ci->top.p` BEFORE the resize, OP_CLOSURE
-- halfProtect(pushclosure), tryfuncTM's shift + top++, buildhiddenargs
-- top++-per-value, luaT_callTMres `L->top.p = func + 3`), and heap-held
-- result slices are rooted across the apply paths' fallible edges.
-- Each section arms the emergency collector (T.totalmem at the current
-- total: the next counted allocation fails, runs the emergency full GC,
-- then retries) or runs ordinary debt / generational steps at the same
-- sites. Assert-based: run with `luazig --engine=zig --testc <file>`.

-- ── Section 1: pcall protection wrap + result application (t2 form) ──
-- The protected result slice is the only reference to its values between
-- the returning child and the parent's registers: the wrap alloc and the
-- frame growth must not sweep it.
do
  collectgarbage(); collectgarbage()
  for i = 1, 50 do local x = {} end
  T.totalmem(T.totalmem())
  local ok, err = pcall(function() return 1 end)
  assert(ok and err == 1)
  T.totalmem(0)
  assert(type(pcall) == "function")
end

-- ── Section 2: OP_CALL stack growth under the published bound (t2v_grow) ──
-- ensureBcStackCap runs BEFORE the PUC-parity top raise used to leave the
-- callee+args region unmarked during the growth's emergency collection.
do
  local garbage = {}
  for i = 1, 200 do garbage[i] = string.rep("x", 10000) end
  local function deep2(n)
    local t = type(1)
    if n == 0 then return "done" end
    local r = deep2(n - 1)
    return r
  end
  collectgarbage(); collectgarbage()
  garbage = nil
  T.totalmem(T.totalmem())
  assert(deep2(400) == "done")
  T.totalmem(0)
end

-- ── Section 3: OP_CONCAT operand region across the dupe (t2v_concat) ──
-- PUC raises top to ra+n BEFORE luaV_concat; the operand dupe and the
-- __concat machinery run under it.
do
  local a = string.rep("a", 40)
  local b = string.rep("b", 40)
  local c = string.rep("c", 40)
  collectgarbage(); collectgarbage()
  for i = 1, 50 do local x = {} end
  T.totalmem(T.totalmem())
  assert(a .. b .. c == a .. b .. c)
  T.totalmem(0)
  collectgarbage(); collectgarbage()
  assert(#(a .. b .. c) == 120)
end

-- ── Section 4: OP_CLOSURE upvalue sources (t2v_upv) ──
-- halfProtect(pushclosure): the captured locals stay inside the marked
-- window across the Cell creates and the Closure commit.
do
  local function mk()
    local a = string.rep("x", 100)
    local b = {}
    collectgarbage(); collectgarbage()
    for i = 1, 50 do local x = {} end
    T.totalmem(T.totalmem())
    local f = function() return a, b end
    return f
  end
  local f = mk()
  collectgarbage(); collectgarbage()
  local x, y = f()
  assert(type(x) == "string" and #x == 100 and type(y) == "table")
  T.totalmem(0)
end

-- ── Section 5: __call chain shift (tryfuncTM parity) ──
-- Each chain link shifts callee+args up by one and raises the bound with
-- it (PUC: shift + top++); the args must survive the shift's frame growth
-- and the metamethod call under emergency.
do
  local garbage = {}
  for i = 1, 200 do garbage[i] = {} end
  local callable = setmetatable({}, {
    __call = function(self, p, q) return p .. q end,
  })
  collectgarbage(); collectgarbage()
  garbage = nil
  local p = string.rep("L", 30)
  local q = string.rep("R", 30)
  T.totalmem(T.totalmem())
  assert(callable(p, q) == p .. q)
  T.totalmem(0)
  collectgarbage(); collectgarbage()
  assert(callable(p, q) == p .. q)
end

-- ── Section 6: OP_TFORCALL iterator region ──
-- The copied func+state+control region (luazig layout: R[A+4..A+6]) is
-- published as the rolling live limit BEFORE the call, so the iterator
-- activation's growth runs with it marked.
do
  local function iter(s, c)
    local i = (c or 0) + 1
    if i <= 3 then return i, string.rep("v", i) end
  end
  local state = string.rep("s", 50)
  collectgarbage(); collectgarbage()
  for i = 1, 50 do local x = {} end
  T.totalmem(T.totalmem())
  local acc = {}
  for _, v in iter, state, nil do acc[#acc + 1] = v end
  T.totalmem(0)
  assert(#acc == 3 and acc[1] == "v" and acc[3] == "vvv")
end

-- ── Section 7: OP_TAILCALL + VAHID buildhiddenargs shift ──
-- The tail-call bound is published before precall, and the shifted
-- func+params region (above the caller-side bound) is published before
-- the frame growth — the just-shifted values must survive the emergency.
do
  local function vt(...)
    return select("#", ...), ...
  end
  local function tc(n, ...)
    if n == 0 then return vt(...) end
    return tc(n - 1, ...)
  end
  collectgarbage(); collectgarbage()
  for i = 1, 50 do local x = {} end
  T.totalmem(T.totalmem())
  local n = tc(120, "a", "b", "c")
  assert(n == 3)
  T.totalmem(0)
  collectgarbage(); collectgarbage()
  assert(tc(120, "a") == 1)
end

-- ── Section 8: multret producer/consumer bound exactness (B==0) ──
-- The producer publishes the exact occupied bound; the B==0 consumer
-- (SETLIST / CALL / TAILCALL) reads its count from it — nil holes and
-- trailing values must be counted exactly, not window-derived.
do
  local function va(...) return ... end
  assert(select("#", va(1, nil, 3)) == 3)
  assert(select("#", va()) == 0)
  assert(select("#", va(nil)) == 1)
  local t = { va(1, nil, 3) }
  assert(#t == 3 or #t == 1) -- #t is border-defined across the nil hole
  assert(t[1] == 1 and t[2] == nil and t[3] == 3)
  local packed = table.pack(va(nil, nil))
  assert(packed.n == 2 and packed[1] == nil and packed[2] == nil)
  -- multret into a fixed-arity call: the truncated tail dies above top
  local function one(x) return type(x) end
  assert(one(va({}, 2)) == "table")
end

-- ── Section 9: weak retention — the published bound must not over-retain ──
-- Everything above the rolling live limit is dead at a collection: a weak
-- reference must NOT be kept alive by a dead slot (the flip side of the
-- root-bound parity — PUC lets above-top slots die, observable through
-- weak tables).
do
  local w = setmetatable({}, { __mode = "v" })
  local function f()
    local obj = {}
    w[1] = obj
    return type(obj)
  end
  assert(f() == "table")
  collectgarbage(); collectgarbage()
  assert(w[1] == nil)
  -- truncated multret tail: the second result's slot is above the
  -- published bound after the fixed-nresults consumer stored the first
  local w2 = setmetatable({}, { __mode = "v" })
  local function prod()
    local keep = {}
    local drop = {}
    w2[1] = drop
    return keep, drop
  end
  local function con()
    local a = prod() -- nresults == 1: drop's slot dies above the bound
    return a
  end
  local kept = con()
  assert(type(kept) == "table")
  collectgarbage(); collectgarbage()
  assert(w2[1] == nil) -- the dead slot did not keep drop alive
end

-- ── Section 10: same sites under ordinary debt and generational steps ──
-- The emergency is the sharp edge; the ordinary step/debt cycles at the
-- same checkGC sites must preserve the same values (t2v_ord / t2v_gen).
do
  collectgarbage("incremental")
  collectgarbage()
  collectgarbage("param", "pause", 1)
  collectgarbage("param", "stepsize", 1)
  for i = 1, 200 do local x = {} end
  local ok, err = pcall(function() return "inc" end)
  assert(ok and err == "inc")

  collectgarbage("generational")
  collectgarbage()
  for i = 1, 5000 do local x = {} end
  local ok2, err2 = pcall(function() return "gen" end)
  assert(ok2 and err2 == "gen")

  -- generational minor at the concat/closure sites
  collectgarbage("generational")
  collectgarbage()
  local s1 = string.rep("g", 40)
  local s2 = string.rep("h", 40)
  local function mkc()
    local u = string.rep("u", 60)
    return function() return u .. s1 end
  end
  local fc = mkc()
  for i = 1, 200 do local x = {} end
  collectgarbage()
  assert(#fc() == 100)
  assert(#(s1 .. s2) == 80)
end

-- ── Section 11: emergency with finalizable garbage at the same sites ──
-- The emergency full GC separates finalizers exactly like an ordinary
-- cycle (no age filtering); the live values still survive (t2v_fin).
do
  collectgarbage(); collectgarbage()
  for i = 1, 50 do local x = setmetatable({}, { __gc = function() end }) end
  T.totalmem(T.totalmem())
  local ok, err = pcall(function() return "fin" end)
  assert(ok and err == "fin")
  T.totalmem(0)
  assert(type(pcall) == "function")
end

print("t2-gc-bound-publication-ok")
