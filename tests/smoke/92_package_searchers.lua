-- Differential smoke: package.searchers / require semantics (PUC 5.5 model).
-- Ground truth: lua-5.5.0/src/loadlib.c (ll_require, findloader, searchers).
-- Every block prints a `name:`-prefixed line; errors are pcall-wrapped.
-- package.path/cpath are pinned to fixed relative entries so all not-found
-- messages are deterministic (the differential harness injects an absolute
-- per-runtime cpath entry via LUA_INIT, which must not leak into output).

package.path = "./?.lua"
package.cpath = "./?.so"

local S = package.searchers
local preload_searcher = S[1]
local lua_searcher = S[2]

local function tail(err)
  -- message part after "module 'X' not found:" (the searcher journal)
  return (err:match("not found:(.*)$"))
end

-- shape: searchers table layout
do
  local all_fn = true
  for i = 1, #S do
    if type(S[i]) ~= "function" then all_fn = false end
  end
  print("shape:", type(S), #S, all_fn)
  assert(type(S) == "table" and #S == 4 and all_fn)
end

-- custom searcher returning (loader, data) at first/middle/last position
local function try_position(pos)
  local cs = function(name)
    return function(n, d) return 73 end, "mydata"
  end
  local t
  if pos == "first" then t = { cs, S[1], S[2], S[3], S[4] }
  elseif pos == "last" then t = { S[1], S[2], S[3], S[4], cs }
  else t = { S[1], cs, S[2], S[3], S[4] } end
  package.searchers = t
  local name = "cmod_" .. pos
  local r1, r2 = require(name)
  local n = select("#", require(name))
  print(pos .. ":", "n=2", "r1=" .. r1, "r2=" .. r2, "repeat-n=" .. n,
        "loaded=" .. tostring(package.loaded[name]))
  assert(r1 == 73 and r2 == "mydata" and n == 1 and package.loaded[name] == 73)
  package.searchers = S
end
try_position("first")
try_position("middle")
try_position("last")

-- reorder: searcher order determines miss-message order
do
  package.searchers = { preload_searcher, lua_searcher }
  local o1 = select(2, pcall(require, "omod"))
  package.searchers = { lua_searcher, preload_searcher }
  local o2 = select(2, pcall(require, "omod"))
  print("reorder-1:", tail(o1))
  print("reorder-2:", tail(o2))
  assert(o1 ~= o2 and o2 ~= nil)
  package.searchers = S
end

-- remove: only preload left / all removed (empty message tail)
do
  package.searchers = { preload_searcher }
  local e1 = select(2, pcall(require, "rmod"))
  print("remove-preload-only:", tail(e1))
  package.searchers = {}
  local e2 = select(2, pcall(require, "rmod"))
  print("remove-all:", #e2, e2)
  assert(e2 == "module 'rmod' not found:")
  package.searchers = S
end

-- nil-stop: a nil hole ends the search; later searchers never run
do
  local late_calls = 0
  package.searchers = {
    function(name) return "missA" end,
    nil,
    function(name) late_calls = late_calls + 1 return "missB" end,
  }
  local e = select(2, pcall(require, "smod"))
  print("nil-stop:", tail(e), "late-calls=" .. late_calls)
  assert(late_calls == 0)
  package.searchers = S
end

-- mutation during search: searcher #1 appends searcher #2, which runs
do
  package.searchers = { function(name)
    table.insert(package.searchers, 2, function(n2) return "appended" end)
    return "mutator"
  end }
  local e = select(2, pcall(require, "mmod"))
  print("mutate:", tail(e))
  package.searchers = S
end

-- result classes of a searcher in the chain
do
  -- (a) function + data -> hit
  package.searchers = { function(name)
    return function(n, d) return "hit", d end, "d1"
  end }
  local h1, h2 = require("amod")
  print("class-fn:", h1, h2)
  assert(h1 == "hit" and h2 == "d1")
  package.searchers = S

  -- (b) string -> miss message
  package.searchers = { function(name) return "str-msg" end }
  print("class-str:", tail(select(2, pcall(require, "bmod"))))
  package.searchers = S

  -- (c) number -> coerced into the miss message
  package.searchers = { function(name) return 42 end }
  print("class-num:", tail(select(2, pcall(require, "cmod"))))
  package.searchers = S

  -- (d) nil / false / table -> silent (not in the message)
  package.searchers = {
    function(name) return nil end,
    function(name) return false end,
    function(name) return {} end,
    function(name) return "only-this" end,
  }
  print("class-silent:", tail(select(2, pcall(require, "dmod"))))
  package.searchers = S

  -- (e) callable non-function searcher (table with __call): invoked via
  --     the VM call path, results classified the same way
  local seen_name
  local hit_tbl = setmetatable({}, { __call = function(self, name)
    seen_name = name
    return function(n, d) return "via-call" end, "cd"
  end })
  package.searchers = { hit_tbl }
  local c1 = require("emod")
  print("class-callable:", c1, seen_name)
  assert(c1 == "via-call" and seen_name == "emod")
  local miss_tbl = setmetatable({}, { __call = function(self, name)
    return "tbl-miss"
  end })
  package.searchers = { miss_tbl }
  print("class-callable-miss:", tail(select(2, pcall(require, "emod2"))))
  package.searchers = S
end

-- searcher raising an error: the error object propagates as is
do
  package.searchers = { function(name) error({ code = 99 }) end }
  local ok, err = pcall(require, "throwmod")
  print("searcher-error-obj:", ok, type(err), err.code)
  assert(not ok and type(err) == "table" and err.code == 99)
  package.searchers = { function(name) error("boom") end }
  local ok2, err2 = pcall(require, "throwmod")
  print("searcher-error-str:", ok2, err2)
  package.searchers = S
end

-- cache semantics of package.loaded / loader results
do
  -- loaded[y] = 42: truthy cache hit, single result, no searcher run
  package.loaded.cache_y = 42
  local y1 = select("#", require("cache_y"))
  print("cache-42:", y1, package.loaded.cache_y)
  assert(y1 == 1)

  -- loaded[x] = false: false is falsy, the module is (re)loaded
  local runs = 0
  package.searchers = { function(name)
    runs = runs + 1
    return function() return "served" end, "fd"
  end }
  package.loaded.cache_f = false
  local f1 = require("cache_f")
  print("cache-false-preset:", f1, runs)
  assert(f1 == "served" and runs == 1)

  -- loader returns false: require returns (false, data); false is not a
  -- truthy cache entry, so a repeat require runs the loader again
  local lruns = 0
  package.searchers = { function(name)
    return function() lruns = lruns + 1 return false end, "fd"
  end }
  local r1, r2 = require("cache_lf")
  local again = require("cache_lf")
  print("cache-loader-false:", r1, r2, again, lruns)
  assert(r1 == false and r2 == "fd" and again == false and lruns == 2)

  -- loader returns nil without writing loaded: require returns (true, data)
  package.searchers = { function(name)
    return function() return nil end, "nd"
  end }
  local n1, n2 = require("cache_nil")
  print("cache-loader-nil:", n1, n2, package.loaded.cache_nil)
  assert(n1 == true and n2 == "nd" and package.loaded.cache_nil == true)

  -- loader writes loaded itself and returns nil: the written value wins
  package.searchers = { function(name)
    return function() package.loaded.cache_w = "custom" return nil end, "wd"
  end }
  local w1, w2 = require("cache_w")
  print("cache-loader-write:", w1, w2, package.loaded.cache_w)
  assert(w1 == "custom" and w2 == "wd")
  package.searchers = S
end

-- nested require: a loader requiring another module
do
  package.preload.nest_b = function() return "B" end
  package.searchers = { preload_searcher, function(name)
    if name == "nest_a" then
      return function() return "A(" .. tostring(require("nest_b")) .. ")" end, "na"
    end
    return "no " .. name
  end }
  local n1 = require("nest_a")
  local n2 = require("nest_a")
  print("nested:", n1, n2, package.loaded.nest_a, package.loaded.nest_b)
  assert(n1 == "A(B)" and n2 == "A(B)")
  package.searchers = S
end

-- global package replacement: require keeps using its package upvalue
do
  local oldpkg = package
  oldpkg.path = "./?.lua"
  local f = assert(io.open("./tmpmod_92g.lua", "w"))
  f:write("return { val = 'from-file' }")
  f:close()
  table.insert(oldpkg.searchers, 1, function(name)
    if name == "gmod" then return function() return 73 end, "gd" end
    return "no " .. name
  end)
  _G.package = { loaded = { gmod = 999, tmpmod_92g = 888 }, searchers = {} }
  local g1, g2 = require("gmod")
  local m, mpath = require("tmpmod_92g")
  print("pkg-replace:", g1, g2, m.val, mpath)
  print("pkg-replace-loaded:", oldpkg.loaded.gmod,
        oldpkg.loaded.tmpmod_92g ~= nil,
        _G.package.loaded.gmod, _G.package.loaded.tmpmod_92g)
  assert(g1 == 73 and g2 == "gd" and m.val == "from-file"
         and mpath == "./tmpmod_92g.lua")
  assert(oldpkg.loaded.gmod == 73 and _G.package.loaded.gmod == 999)
  _G.package = oldpkg
  os.remove("./tmpmod_92g.lua")
end

-- Lua-file loader: chunk + file-name data, then a single-result cache hit
do
  local f = assert(io.open("./tmpmod_92f.lua", "w"))
  f:write("return 7")
  f:close()
  local q1, q2 = require("tmpmod_92f")
  local qn = select("#", require("tmpmod_92f"))
  print("luafile:", q1, q2, "repeat-n=" .. qn)
  assert(q1 == 7 and q2 == "./tmpmod_92f.lua" and qn == 1)
  os.remove("./tmpmod_92f.lua")
end

-- GC inside the file loader: long (>64) module name and path survive
do
  local longname = "gcmod_" .. string.rep("x", 70)
  local path = "./" .. longname .. ".lua"
  local f = assert(io.open(path, "w"))
  f:write("collectgarbage('collect')\nreturn { tag = 'gc-ok' }\n")
  f:close()
  local mod, mpath = require(longname)
  collectgarbage("collect")
  print("gc-in-loader:", mod.tag, mpath == path, #longname, #mpath)
  assert(mod.tag == "gc-ok" and mpath == path)
  collectgarbage("collect")
  assert(mod.tag == "gc-ok" and mpath == path)
  os.remove(path)
end

-- searchers-table lifetime: searcher #1 drops package.searchers (the only
-- reference) and forces a full GC mid-search; the table being walked must
-- survive to the next iteration (PUC keeps it at a stack slot across the
-- whole findloader loop)
do
  package.searchers = {
    function(name)
      package.searchers = nil
      collectgarbage("collect")
      return "dropped"
    end,
    function(name)
      return function(n, d) return 1 end
    end,
  }
  local a, b = require("lmod")
  print("searchers-lifetime:", a, b)
  assert(a == 1 and b == nil)
  package.searchers = S
end

-- yield from a searcher / from a loader inside a coroutine: the require
-- C frame is a non-yieldable boundary; the coroutine dies with the exact
-- error and nothing is cached
do
  package.searchers = { function(name)
    coroutine.yield("nope")
    return "s-miss"
  end }
  local co = coroutine.create(function() require("ymod") end)
  local ok, err = coroutine.resume(co)
  print("yield-searcher:", ok, err, coroutine.status(co), package.loaded.ymod)
  assert(not ok and err == "attempt to yield across a C-call boundary"
         and coroutine.status(co) == "dead" and package.loaded.ymod == nil)

  package.searchers = { function(name)
    return function(n, d) return coroutine.yield("in-loader") end, "ld"
  end }
  local co2 = coroutine.create(function() require("ymod2") end)
  local ok2, err2 = coroutine.resume(co2)
  print("yield-loader:", ok2, err2, coroutine.status(co2), package.loaded.ymod2)
  assert(not ok2 and err2 == "attempt to yield across a C-call boundary"
         and coroutine.status(co2) == "dead" and package.loaded.ymod2 == nil)
  package.searchers = S
end

-- metamethod-aware package.loaded: __index serves the require cache read
-- (PUC ll_require reads _LOADED[name] with lua_getfield)
do
  setmetatable(package.loaded, { __index = function(_, k)
    if k == "virtual" then return 42 end
  end })
  print("meta-loaded-index:", require("virtual"))
  assert(require("virtual") == 42)
  setmetatable(package.loaded, nil)
end

-- metamethod-aware package fields: searcher #2 reads pkg.path through
-- package's __index when the raw field is nil (PUC findfile lua_getfield)
do
  local saved = package.path
  package.path = nil
  setmetatable(package, { __index = function(_, k)
    if k == "path" then return "./?.lua" end
  end })
  print("meta-package-index-path:", type(package.searchers[2]("absent_module_xyz")))
  setmetatable(package, nil)
  package.path = saved
end

-- metamethod-aware cache write: __newindex on package.loaded fires for the
-- _LOADED[name] = result store (PUC ll_require lua_setfield)
do
  package.preload["m"] = function() return "mv" end
  local fired = {}
  setmetatable(package.loaded, { __newindex = function(t, k, v)
    table.insert(fired, k)
    rawset(t, k, v)
  end })
  local a, b = require("m")
  print("meta-loaded-newindex:", #fired, fired[1], a, b)
  assert(fired[1] == "m" and a == "mv" and b == ":preload:")
  setmetatable(package.loaded, nil)
end

-- yield from package.loaded __index during require: the metamethod runs
-- under require's non-yieldable C boundary; the coroutine dies with the
-- exact error and nothing is cached
do
  package.preload["vy"] = function() return "v" end
  setmetatable(package.loaded, { __index = function() coroutine.yield() end })
  local co = coroutine.create(function() require("vy") end)
  local ok, err = coroutine.resume(co)
  local cached = rawget(package.loaded, "vy")
  print("meta-yield:", ok, err, coroutine.status(co), cached)
  assert(not ok and err == "attempt to yield across a C-call boundary"
         and coroutine.status(co) == "dead" and cached == nil)
  setmetatable(package.loaded, nil)
end

-- nested require inside a __newindex callback on package.loaded: the
-- callback's own require re-enters the loader path and fires __newindex
-- again for the inner module
do
  package.preload["outer_m"] = function() return "omv" end
  package.preload["inner_m"] = function() return "imv" end
  local order = {}
  setmetatable(package.loaded, { __newindex = function(t, k, v)
    table.insert(order, "newindex:" .. k)
    rawset(t, k, v)
    if k == "outer_m" then require("inner_m") end
  end })
  local a, b = require("outer_m")
  print("meta-newindex-nested:", a, b, table.concat(order, ","))
  assert(a == "omv" and b == ":preload:"
         and table.concat(order, ",") == "newindex:outer_m,newindex:inner_m")
  setmetatable(package.loaded, nil)
end

-- exact error texts
do
  local e_noarg = select(2, pcall(function() return require() end))
  print("exact-noarg:", e_noarg)
  assert(e_noarg:match("bad argument #1 to 'require' %(string expected, got no value%)$"))

  -- require(42) coerces the argument: same failure as require("42")
  local e_num = select(2, pcall(require, 42))
  local e_str = select(2, pcall(require, "42"))
  print("exact-num-coerce:", e_num == e_str)
  assert(e_num == e_str and e_num:match("^module '42' not found:"))

  package.searchers = 3
  local e_st = select(2, pcall(require, "exactmod"))
  print("exact-searchers:", e_st)
  assert(e_st == "'package.searchers' must be a table")
  package.searchers = S

  package.path = {}
  local e_path = select(2, pcall(require, "exactmod"))
  print("exact-path:", e_path)
  assert(e_path == "'package.path' must be a string")
  package.path = "./?.lua"
end

print("OK")
