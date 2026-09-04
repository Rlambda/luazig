-- Permanent narrow api.lua:580 regression gate (faithful reproducer)
local N = 1000
local source = {}
for i = 1, N do source[i] = "X = X + 1; " end
source[#source + 1] = string.format("Y = '%s'", string.rep("a", N))
source = table.concat(source)
source = load(source, "name1")
source = string.dump(source, true)
collectgarbage(); collectgarbage()
local m1 = collectgarbage("count") * 1024
if not T then
  -- No testc: PUC-ref runs have no T; the fixed-B load is testc-driven.
  -- Upstream api.lua is the authoritative gate; this lane is zig-side.
  print("api580-gate-skipped (no T)")
  return
end
local code = T.testC([[loadstring 2 name B; return 1]], source)
collectgarbage()
local m2 = collectgarbage("count") * 1024
local delta = m2 - m1
assert(m2 > m1 and delta < 400, "api580 gate: delta=" .. math.floor(delta + 0.5))
X = 0; code(); assert(X == N and Y == string.rep("a", N))
X = nil; Y = nil
print("api580-gate-ok delta=" .. math.floor(delta + 0.5))
