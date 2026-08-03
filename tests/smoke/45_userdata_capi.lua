-- Smoke test: C extension userdata round-trip via C API
package.cpath = package.cpath .. ";./lua-5.5.0/testes/libs/?.so;./libs/?.so"

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
