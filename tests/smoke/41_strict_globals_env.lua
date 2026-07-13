-- Standard-library names are ordinary globals under a lexical `global`
-- declaration. The compiler must not silently whitelist names such as
-- `print`, because a loaded chunk can use an arbitrary environment.
local f, err = load([[global marker; return print(marker)]], "strict-stdlib")
assert(f == nil)
assert(string.find(err, "variable 'print'", 1, true))

local env = { marker = 41 }
local chunk = assert(load([[global marker; return marker]], "strict-env", "t", env))
assert(chunk() == 41)

local g, gerr = load([[global marker; return _G]], "strict-g")
assert(g == nil)
assert(string.find(gerr, "variable '_G'", 1, true))

print("strict-globals-env-ok")
