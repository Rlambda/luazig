-- P16.42 T1: pcall inside __gc finalizer must not corrupt VM state
-- (root cause: allocTable's GC step ran finalizers that realloc'd the
-- owning thread's bytecode_stack without re-deriving the dispatch ctx's
-- regs slice — PUC savestack/restorestack discipline).
local name = nil
setmetatable({}, {__gc = function ()
  local ok, err = pcall(print, "X")
  print("pc:", ok)
  name = "__gc"
end})
repeat local a = {} until name
print("name =", name)

-- variant: stack-growing finalizer + allocating builtin via pcall
local name2 = nil
setmetatable({}, {__gc = function ()
  local t = {}
  for i = 1, 50 do t[#t+1] = tostring(i) end
  local ok, err = pcall(string.format, "%d", 42)
  name2 = ok and "__gc" or err
end})
repeat local a = {} until name2
print("name2 =", name2)

-- variant: xpcall in finalizer; finalizer creating another finalizable
local n3 = 0
local function arm()
  setmetatable({}, {__gc = function ()
    n3 = n3 + 1
    local ok = xpcall(function() return 1 + 1 end, function(m) return m end)
    if n3 < 3 then arm() end
  end})
end
arm()
repeat local a = {} until n3 >= 3
print("n3 =", n3)

-- post-corruption sanity: ordinary code still correct
local s = 0
for i = 1, 100 do s = s + i end
print("post:", s)
