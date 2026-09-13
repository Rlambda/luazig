-- P16.42 Iteration 2: GC-rooting of builtin-constructed tables.
-- PUC ltests.c builds T.stats' result tables through the C API — they live
-- on L's stack below L->top, a region traversethread marks, so an
-- allocation-triggered GC step mid-construction can never sweep them.
-- luazig's builtinTestcStats held its seven tables in plain Zig locals
-- across allocating calls: an inline GC step in a later allocTable could
-- sweep the not-yet-linked ones (the P16.42-T3 documented crash shape:
-- "switch on corrupt value" in ltable keyMatches). Fixed via gcTempRoots
-- (the non-moving analogue of the C-stack rooting).
-- Also drives the general invariant: GC steps inside any T.* builtin that
-- constructs tables must not corrupt the tables under construction.
--
-- Runs under --testc (global T from enableTestcModule); skipped in plain
-- mode (the testc module is test-only).

print("testing GC rooting of builtin-constructed tables")

if T == nil then
  T = select(2, pcall(require, "testc"))
end
if not (type(T) == "table" and type(T.stats) == "function") then
  print("SKIPPED (no testc module)")
  return
end

-- 1. T.stats under a mid-cycle collector: position the cycle (gcstate),
--    burn the step debt with junk allocations, then let T.stats' own seven
--    allocTables fire the inline steps that drive the cycle through
--    atomic+sweep while its result tables are still unlinked.
for attempt = 1, 60 do
  collectgarbage("collect")
  T.gcstate("propagate")
  local junk = {}
  for i = 1, 10 + attempt do junk[i] = { i, tostring(i) } end
  junk = nil
  local s = T.stats()
  assert(type(s) == "table", "attempt " .. attempt)
  assert(type(s.calls) == "table" and s.calls.fast ~= nil, "attempt " .. attempt)
  assert(type(s.op_histogram) == "table" and s.op_histogram.move ~= nil, "attempt " .. attempt)
  assert(type(s.tables) == "table" and s.tables.insert ~= nil, "attempt " .. attempt)
  assert(type(s.allocs) == "table" and s.gc and s.yield_resume, "attempt " .. attempt)
end

-- 2. The P16.42-T3 original crash shape: many dynamic loads + full GC +
--    T.stats (the collapsed-threshold accounting is fixed, but the rooting
--    must hold under any pacing).
do
  local keep = {}
  for i = 1, 200 do keep[i] = load("return " .. i) end
  collectgarbage("collect")
  local s = T.stats()
  assert(type(s) == "table" and type(s.calls) == "table")
  assert(#keep == 200 and keep[1]() == 1 and keep[200]() == 200)
end

print("OK")
