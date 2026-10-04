-- Differential smoke: package.loadlib direct differential (lookforfunc,
-- loadlib.c:384-402 ground truth), run against the DL-enabled C Lua
-- interpreter (the stock liblua.so oracle is built without dynamic-library
-- support and is NOT an oracle for this path). The loader is a light C
-- function in PUC 5.5 (lua_pushcfunction at loadlib.c:399); luazig
-- publishes the same light value.
-- Path-bearing and dlerror-bearing messages are never printed raw (they
-- differ by design); only non-nil-ness and the category string are
-- observed. The "*" probe mode is a known boolean-vs-function divergence
-- and intentionally not tested here.
local dir = package.cpath:match("^([^;]+)")
local ok_path = assert(package.searchpath("cload_ok", package.cpath))

-- positive: loader identity is the resolved C function pointer — two
-- loadlib calls return the SAME function value in both engines.
local f1 = assert(package.loadlib(ok_path, "luaopen_cload_ok"))
local f2 = assert(package.loadlib(ok_path, "luaopen_cload_ok"))
print("ld-pos:", type(f1), f1 == f2, debug.getinfo(f1).what,
      debug.getinfo(f1).nups)

-- the loader is callable and opens the module
local m = f1("cload_ok")
print("ld-call:", type(m), m.tag)

-- require via searcher_C resolves through the same lookforfunc path
local r1 = require("cload_ok")
print("ld-require:", r1.tag, package.loaded.cload_ok == r1)

-- ERRFUNC: file loads, symbol missing -> nil, msg, "init"
local a, b, c = package.loadlib(ok_path, "luaopen_nope")
print("ld-errfunc:", a, b ~= nil, c)

-- ERRLIB: file missing -> nil, msg, "open"
local d, e, g = package.loadlib(dir .. "/no_such_lib_41.so", "luaopen_x")
print("ld-errlib:", d, e ~= nil, g)
