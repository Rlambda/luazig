-- 61_captured_local_coherence.lua
-- Captured-local storage invariant: while a Cell is OPEN, the stack register
-- IS the authoritative storage (Cell.get/set read/write bc_stack[reg]).
-- Therefore direct writes to a captured local's register (arithmetic ADD,
-- MOVE, direct-store) are immediately visible to closures that captured it.
-- This test exercises every coherence path and must be byte-identical vs PUC.

-- ── 1. set/get closure round-trip ──
do
  local box = 10
  local function set(v) box = v end
  local function get() return box end
  set(42)
  print("1:", get())          -- 42
  box = 99                    -- direct write by outer scope
  print("1:", get())          -- 99
end

-- ── 2. direct arithmetic on captured local (x = x + 5) ──
do
  local x = 100
  local function read() return x end
  x = x + 5                   -- direct-store ADD into captured local
  print("2:", read())         -- 105
  x = x - 3
  print("2:", read())         -- 102
end

-- ── 3. loop-accumulate into captured local ──
do
  local sum = 0
  local function get() return sum end
  for i = 1, 10 do
    sum = sum + i             -- repeated direct-store ADD
  end
  print("3:", get())          -- 55
end

-- ── 4. nested closures (closure capturing closure's upvalue) ──
do
  local a = 1
  local function outer()
    local b = 2
    local function inner()
      return a + b            -- captures a (from outer-outer) and b (from outer)
    end
    b = b + 10                -- direct-store into captured b
    return inner
  end
  local f = outer()
  a = 100                     -- direct write after outer returned (a still open)
  print("4:", f())            -- 112  (100 + 12)
end

-- ── 5. multiple closures sharing one upvalue ──
do
  local shared = 0
  local function inc() shared = shared + 1 end
  local function dec() shared = shared - 1 end
  local function val() return shared end
  inc(); inc(); inc()
  dec()
  print("5:", val())          -- 2
end

-- ── 6. coroutine yield while upvalue is open ──
do
  local counter = 0
  local function gen()
    while true do
      counter = counter + 1   -- direct-store into captured local
      coroutine.yield(counter)
    end
  end
  local co = coroutine.wrap(gen)
  print("6:", co())           -- 1
  print("6:", co())           -- 2
  print("6:", co())           -- 3
  -- counter is still an open upvalue of the suspended coroutine
  -- (gen's frame is alive, just yielded). The direct-store in the
  -- next resume must see the previous value.
  print("6:", co())           -- 4
end

-- ── 7. close-of-upvalue: return inner closure, drop outer frame ──
do
  local function make()
    local val = 7
    local function getter() return val end
    val = val * 2             -- direct-store before return
    return getter             -- closing val: snapshot 14 into the cell
  end
  local g = make()
  -- make()'s frame is gone; val is now a closed upvalue = 14
  print("7:", g())            -- 14
end

-- ── 8. arithmetic direct-store into captured local, then closure read ──
do
  local n = 5
  local function get() return n end
  n = n * n                   -- direct-store MUL
  n = n + 1                   -- direct-store ADD
  print("8:", get())          -- 26
end

-- ── 9. assignment via nested closure, then direct local read ──
do
  local v = 0
  local function setter(x) v = x end
  setter(777)
  print("9:", v)              -- 777  (closure wrote, outer reads directly)
  v = v + 1
  print("9:", v)              -- 778
end

-- ── 10. captured local as table field, mutated through closure ──
do
  local t = {}
  local function push(x) t[#t + 1] = x end
  local function dump()
    local s = ""
    for i = 1, #t do s = s .. t[i] .. (i < #t and "," or "") end
    return s
  end
  push(10); push(20); push(30)
  print("10:", dump())        -- 10,20,30
end

print("DONE")
