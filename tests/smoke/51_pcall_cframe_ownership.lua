-- Regression test: pcall(function() return 1 end) with allocator churn
-- This exercises the C-parent branch of completeBytecodeExecFrame where
-- runClosure returns bc_return_scratch. With the inverted ownership logic,
-- alloc.free(ret) would corrupt the smp_allocator free list.
for i = 1, 10000 do
  local ok, v = pcall(function() return 1 end)
  assert(ok and v == 1, "iteration " .. i .. ": ok=" .. tostring(ok) .. " v=" .. tostring(v))
  collectgarbage("collect")
end
print("pcall churn: OK")

-- Test load(reader) with Lua closure reader that returns nil to end chunk
local called = false
local function reader()
  if called then return nil end
  called = true
  return "return 99"
end
local ok, result = pcall(load, reader)
assert(ok and result and result() == 99, "pcall(load, reader) should work")
print("pcall(load, reader): OK")

-- Test load(reader) with C closure reader
local called2 = false
local function c_reader()
  if called2 then return nil end
  called2 = true
  return "return 42"
end
local f = load(c_reader)
assert(f and f() == 42, "load(C closure reader) should work")
print("load(C closure reader): OK")
