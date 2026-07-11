-- Bytecode debug API parity across live, suspended, and stripped frames.

local main = debug.getinfo(1, "fu")
assert(type(main.func) == "function")
assert(debug.getupvalue(main.func, 1) == "_ENV")

local count = 0
debug.sethook(function () count = count + 1 end, "", 1)
count = 0
for _ = 1, 100 do end
local observed = count
debug.sethook()
assert(100 < observed and observed < 115)

local co = coroutine.create(function (x)
  local a = 1
  coroutine.yield(debug.getinfo(1, "l"))
  return x + a
end)
local ok, yielded_info = coroutine.resume(co, 10)
assert(ok)
local suspended_info = debug.getinfo(co, 1, "lfLS")
assert(suspended_info.currentline == yielded_info.currentline)
assert(suspended_info.activelines[suspended_info.currentline])
local name, value = debug.getlocal(co, 1, 1)
assert(name == "x" and value == 10)
assert(debug.setlocal(co, 1, 1, 20) == "x")
ok, value = coroutine.resume(co)
assert(ok and value == 21)

local iterator_name
local function iterator()
  iterator_name = debug.getinfo(1).name
  return nil
end
for _ in iterator do end
assert(iterator_name == "for iterator")

local metamethod_name, metamethod_kind
local object = setmetatable({}, {
  __concat = function ()
    local info = debug.getinfo(1)
    metamethod_name = info.name
    metamethod_kind = info.namewhat
    return "joined"
  end,
})
assert(object .. object == "joined")
assert(metamethod_name == "concat" and metamethod_kind == "metamethod")

local function source_with_lines()
  local x = 1
  return x
end
local stripped = assert(load(string.dump(source_with_lines, true)))
local hook_event, hook_line = false, true
debug.sethook(function (event, line)
  hook_event, hook_line = event, line
end, "l")
assert(stripped() == 1); debug.sethook(nil)
assert(hook_event == "line" and hook_line == nil)

local args = {}
for i = 1, 100 do args[i] = i end
local function preserve_varargs(...)
  local packed = table.pack(...)
  return select(100, ...), packed.n
end
local hundredth, argc = preserve_varargs(table.unpack(args))
assert(hundredth == 100 and argc == 100)

print("debug-bytecode-parity-ok")
