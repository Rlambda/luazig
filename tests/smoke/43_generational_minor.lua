local oldmode = collectgarbage("generational")

local anchor = {}
collectgarbage() -- make anchor old
anchor.child = { nested = { 234 } }
collectgarbage("step")
assert(anchor.child.nested[1] == 234)
collectgarbage("step")
assert(anchor.child.nested[1] == 234)

local weak = setmetatable({}, { __mode = "v" })
collectgarbage() -- make weak table old
weak.child = { 99 }
collectgarbage("step")
assert(weak.child == nil)

local old_minor = collectgarbage("param", "minormul")
local old_switch = collectgarbage("param", "minormajor")
local old_return = collectgarbage("param", "majorminor")
assert(type(old_minor) == "number")
assert(type(old_switch) == "number")
assert(type(old_return) == "number")
collectgarbage("param", "minormul", old_minor)
collectgarbage("param", "minormajor", old_switch)
collectgarbage("param", "majorminor", old_return)

collectgarbage(oldmode)
print("generational-minor-ok")
