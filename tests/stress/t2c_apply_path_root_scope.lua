-- Apply-path RootScope decisive discriminator (class-2): the heap return
-- slice of a completion is invisible to the collector until its values
-- land in the parent's registers; every fallible edge on the apply path
-- (the protection-wrap alloc, the append_nil extension, the result
-- application's frame growth) runs through the counted adapter, so a
-- failure enters an emergency full GC that would sweep result objects
-- that exist ONLY in the slice. The form isolates exactly that: the last
-- result is created directly in the return window (no below-top stack
-- residue — a local would leave a rooted MOVE-source slot), the pcall
-- protection wrap is the first charged allocation after the arming, and
-- its failure's emergency GC is the sweep point.
-- Mutation proof (temporary, reverted): disabling the .return_frame
-- completion scope + the protection-wrap scope makes the emergency GC
-- free the object (weak[1] == nil, the caller receives a dangling
-- pointer); with the scopes the form is GREEN.
-- Assert-based: run with `luazig --engine=zig --testc <file>`.

local weak = setmetatable({}, {__mode = "v"})

local function reg(o)
  weak[1] = o
  local junk = {}
  for i = 1, 400 do junk[i] = {i} end
  junk = nil
  T.totalmem(T.totalmem())  -- arm: the next charged allocation fails
  return o
end

local function body()
  -- The fresh table is created directly in the return window (reg's arg
  -- register): after the pops, its only GC-visible reference is the heap
  -- ret slice of the completion.
  return 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,reg({"payload"})
end

local r = table.pack(pcall(body))
T.totalmem(0)  -- disarm
assert(r[1] == true, "pcall ok")
assert(r.n == 22, "count")
assert(weak[1] ~= nil, "object survived the emergency GC")
assert(weak[1] == r[22], "identity preserved")
assert(r[22][1] == "payload", "payload intact")
print("apply-path-root-scope ok")
