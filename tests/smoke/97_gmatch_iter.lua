-- 97_gmatch_iter: string.gmatch's iterator as a per-call CClosure(3) over a
-- GMatchState userdata (PUC lstrlib.c gmatch/gmatch_aux). Lua-observable
-- lanes: the iterator's upvalue contract via debug.getupvalue/upvalueid
-- (subject string, pattern string, state userdata; no 4th upvalue), per-call
-- freshness (two iterators are independent and interleave), statefulness
-- across a full GC and across coroutine suspension, exact result counts
-- (captures, whole match, 0 on exhaustion, 0 on out-of-range init, position
-- captures), the caret-literal / dollar-end / empty-match semantics, and
-- debug.setupvalue on the subject upvalue (iteration unaffected: the cursor
-- lives in the userdata).
-- The setupvalue lanes only assert single values (a pre-existing multret
-- tail drift makes multi-value assignment unreliable there), and the UB lane
-- (installing a non-userdata into upvalue 3) is PUC UB and is not run here;
-- the zig runtime keeps that failure a catchable error (asserted by class in
-- the zig unit battery).

-- upvalue contract of a fresh iterator
local it = string.gmatch("a1b2", "%a%d")
local n1, v1 = debug.getupvalue(it, 1)
local n2, v2 = debug.getupvalue(it, 2)
local n3, v3 = debug.getupvalue(it, 3)
local n4 = debug.getupvalue(it, 4)
print("upvalues:", "[" .. n1 .. "]" .. type(v1), "[" .. n2 .. "]" .. type(v2),
      "[" .. n3 .. "]" .. type(v3), n4 == nil and "no-4th" or "HAS-4th")
print("u1.value:", v1, "u2.value:", v2)
local gi = debug.getinfo(it)
print("getinfo:", gi.what, gi.nups)

-- per-call freshness: two independent iterators, interleaved
local g1 = string.gmatch("a1b2", "%a%d")
local g2 = string.gmatch("x9y8", "%a%d")
print("interleaved:", g1(), g2(), g1(), g2())
print("exhausted:", select("#", g1()), select("#", g2()))
print("uvid.distinct:", debug.upvalueid(g1, 1) ~= debug.upvalueid(g2, 1),
      debug.upvalueid(g1, 3) ~= debug.upvalueid(g2, 3))
local id1 = debug.upvalueid(g1, 1)
local id3 = debug.upvalueid(g1, 3)
collectgarbage("collect")
collectgarbage("collect")
print("uvid.gc.stable:", debug.upvalueid(g1, 1) == id1,
      debug.upvalueid(g1, 3) == id3)

-- statefulness across a second iterator + full GC
local hw = string.gmatch("hello world", "%a+")
print("hw.first:", hw())
local other = string.gmatch("other string", "%a+")
print("other.first:", other())
collectgarbage("collect")
collectgarbage("collect")
print("hw.after.gc:", hw(), select("#", hw()))

-- exact result counts
for w in string.gmatch("key = value, k2 = v2", "(%a+)%s*=%s*(%a+)") do
  print("captures:", w)
end
local whole = string.gmatch("abc", "%a")
print("whole:", whole(), whole(), whole(), select("#", whole()))
local far = string.gmatch("abcdef", "%a", 100)
print("init100:", select("#", far()))
local near = string.gmatch("abcdef", "%a", 3)
print("init3:", near(), select("#", near()))
local neg = string.gmatch("abcdef", "%a", -2)
print("initneg2:", neg(), select("#", neg()))
local pos = string.gmatch("a b  c", "()(%a+)()")
print("poscaps:", pos())
print("poscaps:", pos())
print("poscaps:", pos())
print("poscaps.exhausted:", select("#", pos()))

-- caret is a literal in gmatch; dollar anchors the end
local caret = string.gmatch("a^b", "^%a")
print("caret.literal:", caret(), select("#", caret()))
print("caret.nomatch:", select("#", string.gmatch("abc", "^%a")()))
print("dollar.nomatch:", select("#", string.gmatch("ab", "a$")()))
local dollar = string.gmatch("ab", "b$")
print("dollar.match:", dollar(), select("#", dollar()))

-- empty matches advance by one
local empty = string.gmatch("abc", "b*")
print("empty:", "[" .. empty() .. "]", "[" .. empty() .. "]",
      "[" .. empty() .. "]", select("#", empty()))
local esub = string.gmatch("", "x*")
print("emptysubject:", "[" .. esub() .. "]", select("#", esub()))

-- setupvalue on the subject upvalue: the cursor is unaffected
local sw = string.gmatch("aaa", "a")
print("setupvalue.u1:", "[" .. tostring(debug.setupvalue(sw, 1, "zzz")) .. "]")
print("after.swap:", sw(), sw(), sw(), select("#", sw()))
local _, back = debug.getupvalue(sw, 1)
print("u1.readback:", back)

-- coroutine suspension between calls keeps per-iterator state
local co = coroutine.wrap(function()
  local g = string.gmatch("p1q2", "%a%d")
  coroutine.yield(g())
  coroutine.yield(g())
  return select("#", g()), (g())
end)
print("coro.1:", co())
print("coro.2:", co())
print("coro.3:", co())

-- generic-for drives one iterator to exhaustion
local acc = {}
for w in string.gmatch("one two three", "%a+") do acc[#acc + 1] = w end
print("forin:", table.concat(acc, ","))
