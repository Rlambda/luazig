-- Permanent differential: Proto tree lifetime semantics (P16.10b Task 12).
--
-- Byte-identical stdout+exit on build/lua-c/lua and ./zig-out/bin/luazig.
-- Pins the OBSERVABLE contract behind the ProtoTreeOwner refcount in
-- luazig (many closures share one tree; children outlive parents; the
-- tree stays executable while ANY of its closures lives):
--
--   A. depth-3 tree (main -> base -> mid -> leaf): several sibling leaf
--      closures over the SAME leaf proto; drop the root chunk closure,
--      the base closure, and some of the siblings.
--   B. collectgarbage() between every call: surviving leaves stay
--      callable and keep captured upvalues correct.
--   C. string.dump of a surviving leaf AFTER the root died, and a fresh
--      execution of the undumped copy (plain and stripped).
--   D. debug.getinfo(leaf): source/short_src/linedefined/nups/nparams
--      survive the root's death.
--   E. drop the last sibling too: nothing observable remains; a fresh
--      identical load still works afterwards (allocator health).
--
-- Deterministic: no addresses, no timing, no absolute memory values.

local function fmt(info)
  return string.format("%s|%s|%d|%d|%d|%s",
    info.source, info.short_src, info.linedefined, info.nups, info.nparams, info.what)
end

print("start")

-- A. Build a deep tree whose leaves escape. Chunk name fixed so source
-- fields are deterministic. Tree: main(root) -> base(base) -> mid(delta)
-- -> leaf(x).
local root = assert(load([=[
return function(base)
  local scale = 3
  local function mid(delta)
    local off = delta * 2
    return function(x) return x * scale + off + base end
  end
  return mid
end
]=], "=lifetime"))

collectgarbage()
collectgarbage()

local basef = root()               -- closure over child #1 of the tree
root = nil                         -- drop the ROOT closure of the tree
collectgarbage()
collectgarbage()

local make_mid = basef(100)        -- mid closure (grandchild proto)
basef = nil                        -- drop the base closure too
collectgarbage()

local leaves = {}
for d = 1, 4 do
  leaves[d] = make_mid(d)          -- four siblings over the SAME leaf proto
end
make_mid = nil                     -- drop the mid factory as well
leaves[2] = nil                    -- drop one sibling
leaves[4] = nil                    -- and another
collectgarbage()
collectgarbage()

-- B. Surviving leaves (1 and 3) still execute with correct upvalues.
print("leaf1", leaves[1](10))      -- 10*3 + 1*2 + 100 = 132
collectgarbage()
print("leaf3", leaves[3](7))       -- 7*3 + 3*2 + 100 = 127
collectgarbage()

-- C. Dump a surviving leaf after the root died; roundtrip and re-execute.
-- string.dump serializes the proto, not upvalue VALUES, so capture them
-- from the living leaf and re-attach on the reloaded copy (works on both
-- runtimes; the upvalue ORDER is part of the proto).
local ups = {}
for i = 1, math.huge do
  local n, v = debug.getupvalue(leaves[1], i)
  if not n then break end
  ups[i] = v
end
local blob = string.dump(leaves[1], false)
local again = assert(load(blob))
for i = 1, #ups do
  debug.setupvalue(again, i, ups[i])
end
print("undumped", again(5))        -- 5*3 + 1*2 + 100 = 117
local stripped = assert(load(string.dump(leaves[1], true)))
for i = 1, #ups do
  debug.setupvalue(stripped, i, ups[i])
end
print("stripped", stripped(6))     -- 6*3 + 1*2 + 100 = 120
collectgarbage()

-- D. debug.getinfo on a surviving leaf.
local i1 = debug.getinfo(leaves[1], "Sun")
print("info", fmt(i1))
local ia = debug.getinfo(again, "Sun")
print("info2", ia.source == "=?" and "?source" or fmt(ia))

-- E. Drop every reference into the tree and verify a fresh identical load
-- still behaves (the whole tree became garbage; nothing may corrupt).
leaves[1] = nil
leaves[3] = nil
again = nil
stripped = nil
blob = nil
ups = nil
collectgarbage()
collectgarbage()

local root2 = assert(load([=[
return function(base)
  local scale = 3
  local function mid(delta)
    local off = delta * 2
    return function(x) return x * scale + off + base end
  end
  return mid
end
]=], "=lifetime"))
local base2 = root2()
root2 = nil
local mid2 = base2(100)
base2 = nil
local leaf2 = mid2(1)
mid2 = nil
collectgarbage()
collectgarbage()
print("fresh", leaf2(10))          -- 132 again
print("done")
