-- Differential smoke: C-module loaders (searcher_C, searcher_Croot,
-- IGMARK '-' fallback). Ground truth: lua-5.5.0/src/loadlib.c
-- (searcher_C, searcher_Croot, loadfunc, lookforfunc).
-- The C fixtures come from tests/smoke/cloaders.c, built per runtime by
-- tools/smoke_compare.py; the harness injects the per-runtime module dir
-- as the first package.cpath entry (LUA_INIT). That absolute dir differs
-- between the two runtimes, so path-bearing messages are asserted via
-- anchored matches and never printed raw; the dlopen/dlsym detail after
-- "error loading module ... from file ...:" also differs by design and
-- is intentionally not printed.

package.path = "./?.lua"
local first = package.cpath:match("^([^;]+)")
package.cpath = first .. ";./tests/smoke/zig-libs/?.so"

-- searcher_C positive: udatatest's luaopen returns no values, so require
-- yields the injected true plus the .so path as loader data
do
  local u1, u2 = require("udatatest")
  print("c-udatatest:", u1, u2:match("udatatest%.so$") ~= nil,
        package.loaded.udatatest, type(newpoint))
  assert(u1 == true and u2:match("udatatest%.so$")
         and package.loaded.udatatest == true and type(newpoint) == "function")
  assert(select("#", require("udatatest")) == 1)
end

-- searcher_C positive: module returning a table
do
  local m, mp = require("cload_ok")
  print("c-table:", m.tag, mp:match("cload_ok%.so$") ~= nil,
        package.loaded.cload_ok == m)
  assert(m.tag == "cload_ok" and mp:match("cload_ok%.so$")
         and package.loaded.cload_ok == m)
end

-- searcher_C ERRFUNC: file found, luaopen symbol missing -> hard error
do
  local ok, err = pcall(require, "cload_missing")
  print("c-errfunc:", ok,
        err:match("^error loading module 'cload_missing' from file '[^']+':") ~= nil)
  assert(not ok
         and err:match("^error loading module 'cload_missing' from file '[^']+':"))
end

-- searcher_Croot positive: dotted name resolved in the root .so
do
  local r, rd = require("croot_a.sub")
  print("croot-hit:", r.tag, rd:match("croot_a%.so$") ~= nil,
        package.loaded["croot_a.sub"] == r)
  assert(r.tag == "croot_a_sub" and rd:match("croot_a%.so$")
         and package.loaded["croot_a.sub"] == r)
end

-- searcher_Croot negative: root .so loads but the submodule symbol is
-- absent -> a miss message ("no module ... in file ..."), not a hard error
do
  local ok, err = pcall(require, "croot_b.sub")
  local nofile = select(2, err:gsub("no file", ""))
  print("croot-miss:", ok,
        err:match("^module 'croot_b%.sub' not found:") ~= nil,
        err:match("no module 'croot_b%.sub' in file '[^']*/croot_b%.so'") ~= nil,
        nofile)
  assert(not ok
         and err:match("^module 'croot_b%.sub' not found:")
         and err:match("no module 'croot_b%.sub' in file '[^']*/croot_b%.so'")
         and nofile == 3)
end

-- IGMARK '-': require("cload_ig-v2") finds cload_ig-v2.so and falls back
-- to the luaopen_ prefix before the mark
do
  local g, gd = require("cload_ig-v2")
  print("igmark:", g.tag, gd:match("cload_ig%-v2%.so$") ~= nil,
        package.loaded["cload_ig-v2"] == g)
  assert(g.tag == "cload_ig" and gd:match("cload_ig%-v2%.so$")
         and package.loaded["cload_ig-v2"] == g)
end

print("OK")
