local function show3(a, b, c)
  print(a, b, c)
  return a, b, c
end

local reader = assert(io.popen("printf 'hello\\n'", "r"))
assert(reader:read("l") == "hello")
show3(reader:close())

local tmp = os.tmpname()
local writer = assert(io.popen("cat - > " .. tmp, "w"))
assert(writer:write("pipe-data"))
show3(writer:close())
local file = assert(io.open(tmp, "r"))
assert(file:read("a") == "pipe-data")
assert(file:close())
assert(os.remove(tmp))

local ok, what, code = io.popen("exit 3", "r"):close()
assert(ok == nil and what == "exit" and code == 3)
show3(ok, what, code)

ok, what, code = io.popen("kill -s HUP $$", "r"):close()
assert(ok == nil and what == "signal" and code == 1)
show3(ok, what, code)

assert(os.execute(nil) == true)
show3(os.execute("exit 0"))

local executable = assert(arg[-1] or arg[0])
local command = string.format("%q -e %q", executable, "os.exit(7, true)")
ok, what, code = io.popen(command, "r"):close()
assert(ok == nil and what == "exit" and code == 7)
show3(ok, what, code)
