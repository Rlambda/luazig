-- 96_os_tmpname: stateless exclusive-create tmpname producer. The name has
-- the PUC POSIX mkstemp shape (/tmp/lua_ + 6 alphanumerics), the file is
-- created (mode 0600) and removable, names stay distinct across a
-- thousand-call storm, after reseeding and after full GC, and the math
-- RanState sequence is not disturbed in either direction.

local function shape(s)
  if s:sub(1, 9) ~= "/tmp/lua_" then return false end
  if #s ~= 15 then return false end
  for i = 10, 15 do
    local c = s:byte(i)
    local alnum = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
    if not alnum then return false end
  end
  return true
end

-- p1: >=1000 consecutive names in one state: unique, PUC shape, file
-- created, removable.
local seen = {}
local dup, shape_ok, file_ok, removed = 0, 0, 0, 0
for _ = 1, 1000 do
  local n = os.tmpname()
  if seen[n] then dup = dup + 1 else seen[n] = true end
  if shape(n) then shape_ok = shape_ok + 1 end
  local f = io.open(n, "r")
  if f then file_ok = file_ok + 1; f:close() end
  if os.remove(n) then removed = removed + 1 end
end
print("p1.count:", 1000)
print("p1.distinct:", 1000 - dup)
print("p1.shape_ok:", shape_ok)
print("p1.file_created:", file_ok)
print("p1.removed:", removed)

-- p2: form + uniqueness after math.randomseed (independence, one direction).
math.randomseed(42, 7)
local t1 = os.tmpname()
local t2 = os.tmpname()
print("p2.post_reseed_distinct:", t1 ~= t2)
print("p2.post_reseed_shape:", shape(t1) and shape(t2))
os.remove(t1)
os.remove(t2)

-- p3: the other direction: os.tmpname must not disturb the math sequence.
math.randomseed(42, 7)
local c1 = math.random(100)
local c2 = math.random(100)
math.randomseed(42, 7)
local x = math.random(100)
local tt = os.tmpname()
local y = math.random(100)
print("p3.seq_isolated:", c1 == x and c2 == y)
os.remove(tt)

-- p4: full GC after the storm, then more names in the same state.
collectgarbage("collect")
collectgarbage("collect")
local t3 = os.tmpname()
local t4 = os.tmpname()
local f3 = io.open(t3, "r")
print("p4.post_gc_distinct:", t3 ~= t4)
print("p4.post_gc_file:", f3 ~= nil)
if f3 then f3:close() end
os.remove(t3)
os.remove(t4)

-- p5: math closures still fully functional after the tmpname storm + GC.
math.randomseed(42, 7)
print("p5.math_after:", math.random(100), math.random(100))
