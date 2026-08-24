-- Smoke test: C extension userdata round-trip via C API
-- udatatest.so is built per-runtime (gcc -fPIC -shared against each
-- runtime's headers) by tools/smoke_compare.py. The differential harness
-- prepends the PUC-flavored build's directory to package.cpath via -e when
-- running the reference interpreter; for standalone luazig runs this cpath
-- entry finds the luazig-flavored build in tests/smoke/zig-libs/.
package.cpath = package.cpath .. ";./tests/smoke/zig-libs/?.so"

require("udatatest")

local p = newpoint(10, 20)
assert(type(p) == "userdata", "expected userdata, got " .. type(p))

assert(p:getx() == 10, "getx should return 10")
assert(p:gety() == 20, "gety should return 20")

local s = tostring(p)
assert(s == "Point(10, 20)", "tostring should be 'Point(10, 20)', got " .. s)

p = nil
collectgarbage("collect")

print("userdata-capi-ok")
