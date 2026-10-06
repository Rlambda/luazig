-- 98_io_lines_iter: io.lines/file:lines iterators as per-call CClosures
-- with upvalues [file, n, toclose, formats...] (PUC 5.5 liolib.c
-- aux_lines/io_readline). Lua-observable lanes: the by-name construction's
-- exact 4 results (iterator, nil, nil, toclose file) vs the default-input
-- form's 1, the upvalue contract via debug.getupvalue (file handle, the
-- remaining-format counter, the toclose flag, then the format strings; no
-- upvalue past the formats), per-iterator freshness (two iterators
-- interleave), exhaustion (0 results) with the auto-close that follows
-- (the next call raises "file is already closed" with the chunk position:
-- the immediate caller is Lua), exact result counts per format ('l' + 'n'
-- interplay: a failed number read unreads its look-ahead, so the line
-- survives; pure number files; multiple formats), the 252-format "too many
-- arguments" argerror for io.lines and file:lines, the FILE*-handle
-- argerror, the number-coerced open failure (no position prefix under
-- pcall: the immediate caller is a C function), debug.setupvalue on the
-- file upvalue (swapping the handle changes what the iterator reads), and
-- statefulness across a full GC and across coroutine suspension.
-- Plus the signed-hex read("n") conversion (PUC l_str2int recognizes 0x
-- after the optional sign and wraps in lua_Unsigned): a signed hex token
-- reads back as an integer with the exact value (even beyond binary64
-- precision), hex floats/decimals keep their PUC kinds, and a failed
-- read leaves the look-ahead for the next read — on all three public
-- paths: file:read, file:lines and io.read.

local P = "/tmp/luazig_s98_lines.txt"
local N = "/tmp/luazig_s98_nums.txt"
local fh = assert(io.open(P, "w")); fh:write("B1 42\nB2 84\n"); fh:close()
fh = assert(io.open(N, "w")); fh:write("10\n20\n"); fh:close()

-- by-name construction: exactly 4 results; default-input form: 1
print("results:", select("#", io.lines(P, "l", "n")))
print("default:", select("#", io.lines()))

-- upvalue contract of a fresh iterator
local it = io.lines(P, "l", "n")
local u1n, u1 = debug.getupvalue(it, 1)
local u2n, u2 = debug.getupvalue(it, 2)
local u3n, u3 = debug.getupvalue(it, 3)
local u4n, u4 = debug.getupvalue(it, 4)
local u5n, u5 = debug.getupvalue(it, 5)
local u6 = debug.getupvalue(it, 6)
print("upvalues:",
  "[" .. u1n .. "]" .. type(u1),
  "[" .. u2n .. "]" .. type(u2) .. ":" .. tostring(u2),
  "[" .. u3n .. "]" .. type(u3) .. ":" .. tostring(u3),
  "[" .. u4n .. "]" .. type(u4) .. ":" .. tostring(u4),
  "[" .. u5n .. "]" .. type(u5) .. ":" .. tostring(u5),
  u6 == nil and "no-6th" or "HAS-6th")
local gi = debug.getinfo(it)
print("getinfo:", gi.what, gi.nups)

-- per-iterator freshness: two independent iterators, interleaved
local a = io.lines(P)
local b = io.lines(P)
print("interleaved:", a(), b(), a(), b())
print("exhausted:", select("#", a()), select("#", b()))
print("closed:", (select(2, pcall(a))))

-- exact result counts per format
local ln = io.lines(P, "l", "n")
print("ln.c1:", ln())
print("ln.c2:", ln())
print("ln.eof:", select("#", ln()))
local nf = io.lines(N, "n")
print("n.c1:", nf())
print("n.c2:", nf())
print("n.eof:", select("#", nf()))
local mf = io.lines(P, "l", "l")
print("multi:", mf())
print("multi.eof:", select("#", mf()))

-- generic-for drives one iterator to exhaustion (toclose on break too)
local acc = {}
for l in io.lines(P) do acc[#acc + 1] = l end
print("forin:", table.concat(acc, ","))
local first
for l in io.lines(P) do first = l; break end
print("break:", first)

-- file:lines: exactly 1 result, method iteration; the caller's file is
-- NOT auto-closed at exhaustion (toclose is false — only the by-name
-- io.lines closes its own file)
fh = assert(io.open(P))
print("f:lines:", select("#", fh:lines("l")))
local acc2 = {}
for l in fh:lines("l") do acc2[#acc2 + 1] = l end
print("f:forin:", table.concat(acc2, ","))
print("f:not-closed:", io.type(fh), tostring((fh:read("l"))))
fh:close()

-- argerrors
local function pfmt(...) return select(2, pcall(...)) end
print("toomany:", pfmt(io.lines, P, table.unpack(
  (function() local t = {}; for i = 1, 251 do t[i] = "l" end return t end)())))
fh = assert(io.open(P))
print("f-toomany:", pfmt(fh.lines, fh, table.unpack(
  (function() local t = {}; for i = 1, 251 do t[i] = "l" end return t end)())))
print("fh-arg:", pfmt(io.lines, io.stdout))
print("num-arg:", pfmt(io.lines, 42))

-- setupvalue on the file upvalue: swapping the handle changes the read
fh = assert(io.open(P))
local sw = io.lines(P)
print("before:", sw())
debug.setupvalue(sw, 1, fh)
print("after.swap:", sw())
local _, back = debug.getupvalue(sw, 1)
print("u1.readback:", type(back))

-- upvalueid distinct + GC-stable across a saved iterator
local s1 = io.lines(P)
local s2 = io.lines(P)
print("uvid.distinct:", debug.upvalueid(s1, 1) ~= debug.upvalueid(s2, 1))
local id1 = debug.upvalueid(s1, 1)
s1()
collectgarbage("collect")
collectgarbage("collect")
print("uvid.gc.stable:", debug.upvalueid(s1, 1) == id1)
print("after.gc:", s1())

-- coroutine suspension between calls keeps per-iterator state
local co = coroutine.wrap(function()
  local g = io.lines(P)
  coroutine.yield(g())
  coroutine.yield(g())
  return select("#", g())
end)
print("coro.1:", co())
print("coro.2:", co())
print("coro.3:", co())

-- signed hex through read("n") on all three public paths
local SX = "/tmp/luazig_s98_shex.txt"
local sx = assert(io.open(SX, "w"))
sx:write("+0x20000000000001 -0x10 +0x10 0X10 -0X10 0x10 0xFFFFFFFFFFFFFFFF"
  .. " +0xFFFFFFFFFFFFFFFF -0xFFFFFFFFFFFFFFFF +0x8000000000000000"
  .. " -0x8000000000000000 0x10000000000000000 0x1.8 -0x1p3 42 -3.5"
  .. " 0x10Z 42X tail\n")
sx:close()
local function kindval(v) return tostring(math.type(v)), tostring(v) end

do
  local f = assert(io.open(SX))
  for i = 1, 18 do
    local v = f:read("n")
    print("shex.f:read:", i, kindval(v))
    if v == nil then break end
  end
  print("shex.f:read.rest:", f:read("l"))
  f:close()
end

do
  local f = assert(io.open(SX))
  local n = 0
  for v in f:lines("n") do
    n = n + 1
    print("shex.lines:", n, kindval(v))
  end
  print("shex.lines.count:", n)
  print("shex.lines.rest:", f:read("l"))
  f:close()
end

do
  local f = assert(io.open(SX))
  io.input(f)
  for i = 1, 18 do
    local v = io.read("n")
    print("shex.io.read:", i, kindval(v))
    if v == nil then break end
  end
  print("shex.io.read.rest:", io.read("l"))
  io.input():close()
end
