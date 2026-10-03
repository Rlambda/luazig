/*
 * 40_package_openf.c - C oracle for package-loading semantics:
 * luaopen_package, luaL_requiref, luaL_openselectedlibs (PUC Lua 5.5
 * model), construction rollback of luaopen_package under OOM, and the
 * nested-require-from-_LOADED-__newindex scenario under OOM (both
 * runtimes; the branch counts and balance numbers are per-runtime, only
 * the output FORM is comparable).
 *
 * No arguments, no addresses/pointers in output. One line per check:
 *   "STEP n: OK <detail>"    - assertion passed
 *   "STEP n: FAIL <detail>"  - assertion failed (baseline divergence)
 *   "STEP n: RESULT <value>" - informational value
 * Final line: "ORACLE: <n> failures".
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int step_no = 0;
static int failures = 0;

static void step(int n) { step_no = n; }

static void ok(const char *detail) {
  printf("STEP %d: OK %s\n", step_no, detail);
}

static void fail(const char *detail) {
  printf("STEP %d: FAIL %s\n", step_no, detail);
  failures++;
}

static void check(int cond, const char *detail) {
  if (cond) ok(detail); else fail(detail);
}

/* loader returned by the custom searcher: returns 73 */
static int loader_73(lua_State *L) {
  lua_pushinteger(L, 73);
  return 1;
}

/* custom searcher: returns (loader_73, "cd") for any module name */
static int custom_searcher(lua_State *L) {
  lua_pushcfunction(L, loader_73);
  lua_pushliteral(L, "cd");
  return 2;
}

/* openf stub for luaL_requiref: returns {v = 42}, counts invocations */
static int openf_calls = 0;
static int openf_stub(lua_State *L) {
  openf_calls++;
  lua_newtable(L);
  lua_pushinteger(L, 42);
  lua_setfield(L, -2, "v");
  return 1;
}

/* The nested-require scenario's 4 results on top of the stack:
 * ('av', ':preload:', 'av', 'bv') — the outer require's value and loader
 * data plus both modules' cached _LOADED entries. */
static int nested_results_ok(lua_State *L) {
  static const char *want[4] = {"av", ":preload:", "av", "bv"};
  for (int i = 0; i < 4; i++) {
    if (!lua_isstring(L, -(4 - i))) return 0;
    if (strcmp(lua_tostring(L, -(4 - i)), want[i]) != 0) return 0;
  }
  return 1;
}

/* call luaopen_package protected; result stays on stack, returns stack index */
static int open_package(lua_State *L, const char *tag) {
  lua_pushcfunction(L, luaopen_package);
  if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
    printf("STEP %d: RESULT err[%s]=%s\n", step_no, tag,
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
    lua_pop(L, 1);
    return 0;
  }
  return lua_gettop(L);
}

/*
** Counting allocator for the OOM rollback steps. PUC-style allocators
** react to a failed allocation with an emergency collection followed by
** a retry (lmem.c tryagain), so a one-shot failure is survived. The
** countdown therefore switches into a sticky failing mode at the N-th
** allocating call (nsize > 0): the retry fails too, forcing ERRMEM at
** that exact construction point. -1 disables failure injection; frees
** always pass through.
**
** Leak balance: every block allocated through this allocator
** (ptr == NULL) is registered; frees and realloc moves update the
** registry. bal_reset() starts a balance window (the state-creation
** allocations are excluded — one newstate block is released through the
** VM's internal plain allocator by design). After a full lua_close no
** registered block may remain live (live == 0): every OOM recovery path
** (the require result-push tails, the return-tail reserves) must release
** what it allocated. Frees of never-registered pointers (foreign_frees)
** are blocks the VM allocated through its internal plain allocator and
** releases through the custom one — pre-existing architecture on the
** luazig side, not a leak signal.
*/
static int alloc_countdown = -1;
#define BAL_MAX_BLOCKS 200000
static void *bal_blocks[BAL_MAX_BLOCKS];
static int bal_nblocks = 0;
static long bal_allocs = 0, bal_frees = 0, bal_foreign_frees = 0;

static void bal_reset(void) {
  bal_nblocks = 0;
  bal_allocs = 0;
  bal_frees = 0;
  bal_foreign_frees = 0;
}

static long bal_live(void) {
  long live = 0;
  for (int i = 0; i < bal_nblocks; i++)
    if (bal_blocks[i] != NULL) live++;
  return live;
}

static void *counting_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  (void)ud; (void)osize;
  if (nsize == 0) {
    if (ptr != NULL) {
      bal_frees++;
      int found = 0;
      for (int i = 0; i < bal_nblocks; i++)
        if (bal_blocks[i] == ptr) { bal_blocks[i] = NULL; found = 1; break; }
      if (!found) bal_foreign_frees++;
    }
    free(ptr);
    return NULL;
  }
  if (alloc_countdown > 0) alloc_countdown--;
  if (alloc_countdown == 0) return NULL; /* failed: nothing moves */
  void *r = realloc(ptr, nsize);
  if (r != NULL) {
    if (ptr == NULL) {
      bal_allocs++;
      if (bal_nblocks < BAL_MAX_BLOCKS) bal_blocks[bal_nblocks++] = r;
    }
    else {
      for (int i = 0; i < bal_nblocks; i++)
        if (bal_blocks[i] == ptr) { bal_blocks[i] = r; break; }
    }
  }
  return r;
}

int main(void) {
  const int raw_diag = getenv("LUACORACLE_RAW") != NULL;
  /* ---- STEP 1: base state via luaL_openselectedlibs(L, ~0, 0) ---- */
  step(1);
  lua_State *L = luaL_newstate();
  check(L != NULL, "luaL_newstate");
  luaL_openselectedlibs(L, ~0, 0);
  check(lua_getglobal(L, "package") == LUA_TTABLE, "global package is table");
  check(lua_getglobal(L, "require") == LUA_TFUNCTION, "global require is function");
  lua_pop(L, 2);

  /* ---- STEP 2: two direct luaopen_package calls ---- */
  step(2);
  int p1 = open_package(L, "p1");
  check(p1 > 0 && lua_type(L, p1) == LUA_TTABLE, "type(p1) == table");
  int p2 = open_package(L, "p2");
  check(p2 > p1 && lua_type(L, p2) == LUA_TTABLE, "type(p2) == table");
  if (p1 == 0 || p2 == 0) {
    printf("ORACLE: aborted after luaopen_package failure\n");
    return 1;
  }
  check(!lua_rawequal(L, p1, p2), "p1 ~= p2 (rawequal: distinct tables)");

  lua_getfield(L, p1, "searchers");
  int s1 = lua_gettop(L);
  lua_getfield(L, p2, "searchers");
  int s2 = lua_gettop(L);
  int s1_is_table = (lua_type(L, s1) == LUA_TTABLE);
  int s2_is_table = (lua_type(L, s2) == LUA_TTABLE);
  check(s1_is_table, "p1.searchers is table");
  check(s2_is_table, "p2.searchers is table");
  if (s1_is_table && s2_is_table) {
    check(!lua_rawequal(L, s1, s2), "p1.searchers ~= p2.searchers");
    lua_Integer n1 = luaL_len(L, s1);
    lua_Integer n2 = luaL_len(L, s2);
    printf("STEP 2: RESULT #p1.searchers=%lld #p2.searchers=%lld\n",
           (long long)n1, (long long)n2);
    check(n1 == 4, "#p1.searchers == 4");
    check(n2 == 4, "#p2.searchers == 4");
    int all_fn = 1;
    for (lua_Integer i = 1; i <= n2; i++) {
      lua_rawgeti(L, s2, i);
      if (lua_type(L, -1) != LUA_TFUNCTION) all_fn = 0;
      lua_pop(L, 1);
    }
    check(all_fn, "all p2.searchers elements are functions");
  } else {
    /* keep the same check lines so puc/zig outputs stay comparable */
    printf("STEP 2: RESULT #p1.searchers=%s #p2.searchers=%s\n",
           s1_is_table ? "?" : "n/a", s2_is_table ? "?" : "n/a");
    fail("#p1.searchers == 4");
    fail("#p2.searchers == 4");
    fail("all p2.searchers elements are functions");
  }

  check(lua_getglobal(L, "require") == LUA_TFUNCTION,
        "global require is function after 2nd luaopen_package");
  const char *upname = lua_getupvalue(L, -1, 1);
  if (upname == NULL) {
    fail("require has upvalue 1 (package binding)");
  } else {
    printf("STEP 2: RESULT require upvalue 1 name='%s'\n", upname);
    check(lua_rawequal(L, -1, p2), "require upvalue[1] == p2 (last opened)");
    check(!lua_rawequal(L, -1, p1), "require upvalue[1] ~= p1");
    lua_pop(L, 1); /* upvalue */
  }
  lua_pop(L, 1); /* require */

  lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
  int rl = lua_gettop(L);
  check(lua_type(L, rl) == LUA_TTABLE, "registry._LOADED is table");
  lua_getfield(L, p1, "loaded");
  int l1 = lua_gettop(L);
  lua_getfield(L, p2, "loaded");
  int l2 = lua_gettop(L);
  check(lua_rawequal(L, l1, l2), "p1.loaded == p2.loaded");
  check(lua_rawequal(L, l1, rl), "p1.loaded == registry._LOADED");
  check(lua_rawequal(L, l2, rl), "p2.loaded == registry._LOADED");

  lua_getfield(L, LUA_REGISTRYINDEX, "_PRELOAD");
  int rp = lua_gettop(L);
  check(lua_type(L, rp) == LUA_TTABLE, "registry._PRELOAD is table");
  lua_getfield(L, p1, "preload");
  int q1 = lua_gettop(L);
  lua_getfield(L, p2, "preload");
  int q2 = lua_gettop(L);
  check(lua_rawequal(L, q1, q2), "p1.preload == p2.preload");
  check(lua_rawequal(L, q1, rp), "p1.preload == registry._PRELOAD");
  check(lua_rawequal(L, q2, rp), "p2.preload == registry._PRELOAD");

  /* ---- STEP 3: custom searcher in p2 + global package replacement ---- */
  step(3);
  /* table.insert(p2.searchers, 1, custom_searcher) */
  lua_getglobal(L, "table");
  lua_getfield(L, -1, "insert");
  lua_pushvalue(L, s2);
  lua_pushinteger(L, 1);
  lua_pushcfunction(L, custom_searcher);
  if (lua_pcall(L, 3, 0, 0) != LUA_OK) {
    printf("STEP 3: RESULT insert err=%s\n",
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
    fail("table.insert(p2.searchers, 1, custom_searcher)");
    lua_pop(L, 1);
  } else {
    ok("custom searcher inserted at p2.searchers[1]");
  }
  lua_pop(L, 1); /* table */

  /* replace global package with an empty stub table */
  lua_newtable(L);
  lua_setglobal(L, "package");
  ok("global package replaced with empty stub table");
  check(lua_getglobal(L, "package") == LUA_TTABLE && !lua_rawequal(L, -1, p2),
        "stub global package is a table distinct from p2");
  lua_pop(L, 1);

  /* require('m') must go through p2.searchers (upvalue), not the stub.
     Lua 5.5 require returns 2 values: module result + loader data. */
  if (luaL_dostring(L, "local a, b = require('m'); return a, tostring(b)")
      != LUA_OK) {
    printf("STEP 3: RESULT require err=%s\n",
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
    fail("require('m') succeeds after global package replacement");
    lua_pop(L, 1);
  } else {
    check(lua_isnumber(L, -2) && lua_tointeger(L, -2) == 73,
          "require('m') == 73 (served by p2.searchers[1])");
    printf("STEP 3: RESULT require('m') 2nd return (loader data): %s\n",
           lua_tostring(L, -1));
    lua_pop(L, 2);
  }
  lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
  lua_getfield(L, -1, "m");
  check(lua_isnumber(L, -1) && lua_tointeger(L, -1) == 73,
        "_LOADED['m'] == 73");
  lua_pop(L, 2);

  lua_settop(L, 0); /* drop p1/p2/searchers/registry refs */

  /* ---- STEP 4: luaL_requiref semantics ---- */
  step(4);
  openf_calls = 0;
  luaL_requiref(L, "anypkg", openf_stub, 1);
  check(openf_calls == 1, "first requiref: openf called exactly once");
  check(lua_istable(L, -1), "first requiref: module table left on stack");
  int m1 = lua_gettop(L);
  lua_getfield(L, -1, "v");
  check(lua_isnumber(L, -1) && lua_tointeger(L, -1) == 42, "module.v == 42");
  lua_pop(L, 1);
  lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
  lua_getfield(L, -1, "anypkg");
  check(lua_rawequal(L, -1, m1), "_LOADED['anypkg'] == module (rawequal)");
  lua_pop(L, 2);
  check(lua_getglobal(L, "anypkg") == LUA_TTABLE, "global anypkg set (glb=1)");
  check(lua_rawequal(L, -1, m1), "global anypkg == module (rawequal)");
  lua_pop(L, 1);

  luaL_requiref(L, "anypkg", openf_stub, 1);
  check(openf_calls == 1, "second requiref: openf NOT called again");
  check(lua_rawequal(L, -1, m1),
        "second requiref returns cached table (rawequal first)");
  lua_pop(L, 2); /* second result + first module */

  /* pre-cached _LOADED entry: openf must not run, cached value returned */
  lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
  lua_pushliteral(L, "cached");
  lua_setfield(L, -2, "pre");
  lua_pop(L, 1);
  luaL_requiref(L, "pre", openf_stub, 1);
  check(openf_calls == 1, "requiref('pre'): openf NOT called for cached entry");
  check(lua_isstring(L, -1) &&
        strcmp(lua_tostring(L, -1), "cached") == 0,
        "requiref('pre') returns cached value 'cached'");
  lua_pop(L, 1);

  /* ---- STEP 5: luaL_openselectedlibs load/preload bitmasks ---- */
  step(5);
  lua_State *L2 = luaL_newstate();
  luaL_openselectedlibs(L2, 0, LUA_STRLIBK);
  /* Contract: globals are eagerly published by init; preload-bit
     publication is checked via _PRELOAD contents. */
  lua_getfield(L2, LUA_REGISTRYINDEX, "_PRELOAD");
  check(lua_istable(L2, -1), "preload-only: registry._PRELOAD is table");
  lua_getfield(L2, -1, "string");
  check(lua_isfunction(L2, -1), "_PRELOAD['string'] is function");
  lua_pop(L2, 2);

  luaL_openselectedlibs(L2, LUA_STRLIBK, 0);
  check(lua_getglobal(L2, "string") == LUA_TTABLE,
        "after load: global string is table");
  int r = luaL_ref(L2, LUA_REGISTRYINDEX); /* pops the string table */
  lua_getfield(L2, LUA_REGISTRYINDEX, "_LOADED");
  lua_getfield(L2, -1, "string");
  check(lua_istable(L2, -1), "_LOADED['string'] is table");
  lua_rawgeti(L2, LUA_REGISTRYINDEX, r);
  check(lua_rawequal(L2, -1, -2), "global string == _LOADED['string']");
  lua_pop(L2, 2);

  luaL_openselectedlibs(L2, LUA_STRLIBK, 0); /* repeat: must not recreate */
  lua_getglobal(L2, "string");
  lua_rawgeti(L2, LUA_REGISTRYINDEX, r);
  check(lua_rawequal(L2, -1, -2),
        "repeat load does not recreate string table (rawequal)");
  lua_pop(L2, 2);
  luaL_unref(L2, LUA_REGISTRYINDEX, r);

  lua_getfield(L2, LUA_REGISTRYINDEX, "_PRELOAD");
  lua_getfield(L2, -1, "string");
  printf("STEP 5: RESULT _PRELOAD['string'] after load: %s\n",
         lua_typename(L2, lua_type(L2, -1)));
  lua_pop(L2, 2);

  lua_close(L2);

  /* ---- STEP 6: luaopen_package construction rollback under OOM ----
     For each of the first 40 allocation-failure points: a pcall-protected
     luaopen_package either fails with ERRMEM or succeeds; in both cases
     the VM must stay usable (dostring, full GC), a failed open must not
     disturb the global require, and an allocation-enabled retry must
     build the full library. Whether a given N fails or succeeds is
     implementation-dependent (allocation counts differ), so the per-N
     line is branch-independent; only a real recovery violation prints
     FAIL. The summary line makes the coverage observable: both branches
     must occur, and the ERRMEM window must span several points (the
     sweep reaches late construction points, not just the first). The
     alloc/free balance after lua_close proves the OOM paths leak
     nothing. */
  step(6);
  lua_State *L3 = lua_newstate(counting_alloc, NULL, 0);
  check(L3 != NULL, "lua_newstate with counting alloc");
  if (L3 != NULL) {
    luaL_openselectedlibs(L3, ~0, 0);
    bal_reset(); /* balance window: the OOM loop and close */
    check(lua_getglobal(L3, "require") == LUA_TFUNCTION,
          "global require before OOM loop");
    lua_pop(L3, 1);
    int saw_errmem = 0, saw_success = 0;
    int errmem_min = 0, errmem_max = 0, success_min = 0, success_max = 0;
    for (int n = 1; n <= 40; n++) {
      lua_getglobal(L3, "require");
      int r0 = luaL_ref(L3, LUA_REGISTRYINDEX);
      /* scaffold push outside the failure window: the countdown is armed
         only around the protected call, so every failure point lies inside
         the pcall, from the start of luaopen_package itself */
      lua_pushcfunction(L3, luaopen_package);
      alloc_countdown = n;
      int rc = lua_pcall(L3, 0, 1, 0);
      alloc_countdown = -1;
      int recovered = 1;
      const char *why = "";
      if (rc == LUA_OK) {
        saw_success++;
        if (success_min == 0) success_min = n;
        success_max = n;
        lua_pop(L3, 1); /* fresh package table */
      }
      else if (rc == LUA_ERRMEM) {
        saw_errmem++;
        if (errmem_min == 0) errmem_min = n;
        errmem_max = n;
        lua_pop(L3, 1); /* error object */
        lua_getglobal(L3, "require");
        lua_rawgeti(L3, LUA_REGISTRYINDEX, r0);
        if (!lua_rawequal(L3, -1, -2)) {
          recovered = 0;
          why = "global require changed by failed open";
        }
        lua_pop(L3, 2);
      }
      else {
        lua_pop(L3, 1);
        recovered = 0;
        why = "open failed with unexpected status";
      }
      if (recovered && luaL_dostring(L3, "return 1+1") != LUA_OK) {
        recovered = 0;
        why = "dostring failed after OOM";
      }
      else if (recovered) {
        lua_Integer v = lua_tointeger(L3, -1);
        lua_pop(L3, 1);
        if (v != 2) {
          recovered = 0;
          why = "dostring returned wrong value";
        }
      }
      if (recovered
          && luaL_dostring(L3, "collectgarbage('collect')") != LUA_OK) {
        recovered = 0;
        why = "collectgarbage failed after OOM";
      }
      if (recovered) {
        lua_pushcfunction(L3, luaopen_package);
        if (lua_pcall(L3, 0, 1, 0) != LUA_OK) {
          lua_pop(L3, 1);
          recovered = 0;
          why = "retry open failed";
        }
        else {
          lua_getfield(L3, -1, "searchers");
          lua_Integer ns = luaL_len(L3, -1);
          lua_pop(L3, 2);
          if (ns != 4) {
            recovered = 0;
            why = "retry open searchers != 4";
          }
        }
      }
      if (recovered)
        printf("STEP 6: OK N=%d recovered\n", n);
      else {
        printf("STEP 6: FAIL N=%d %s\n", n, why);
        failures++;
      }
      luaL_unref(L3, LUA_REGISTRYINDEX, r0);
    }
    /* Engine-dependent counts (allocation totals, ERRMEM/success split,
     * N ranges) are NOT a PUC parity criterion: LUACORACLE_RAW=1 exposes
     * them for manual raw evidence; the byte-exact differential lane runs
     * without it. The class assertions below stay unconditional. */
    if (raw_diag)
      printf("STEP 6: RESULT saw_errmem=%d saw_success=%d points=40 "
             "errmem_N=%d..%d success_N=%d..%d\n",
             saw_errmem, saw_success, errmem_min, errmem_max,
             success_min, success_max);
    check(saw_errmem > 0, "OOM loop saw at least one ERRMEM");
    check(saw_success > 0, "OOM loop saw at least one success");
    check(saw_errmem + saw_success == 40,
          "every OOM point classified (ERRMEM or success)");
    check(errmem_max > errmem_min,
          "ERRMEM window spans several points (late points reached)");
    lua_close(L3);
    if (raw_diag)
      printf("STEP 6: RESULT balance allocs=%ld frees=%ld "
             "foreign_frees=%ld live=%ld\n",
             bal_allocs, bal_frees, bal_foreign_frees, bal_live());
    check(bal_live() == 0,
          "no block allocated in the OOM window survives lua_close");
  }

  /* ---- STEP 7: nested require from a _LOADED __newindex metamethod ----
     The loader of module A installs __newindex on registry._LOADED; the
     outer require's _LOADED publication fires the callback, which
     requires module B (both preloaded) — the nested require's C
     activation runs while the outer activation's return tail is armed,
     so the two reserves must be independent per activation. The plain
     run must succeed with both modules cached in _LOADED. The OOM sweep
     then fails every allocation point of a protected run in turn: each
     ERRMEM must leave the VM usable with a working retry, and the
     alloc/free balance after lua_close must hold (the require
     result-push tails and the return-tail reserves leak nothing). */
  step(7);
  lua_State *L4 = lua_newstate(counting_alloc, NULL, 0);
  check(L4 != NULL, "lua_newstate for nested-reserve scenario");
  if (L4 != NULL) {
    luaL_openselectedlibs(L4, ~0, 0);
    bal_reset(); /* balance window: the scenario runs and close */
    /* The chunk resets its own _LOADED state first, so every run (plain,
       sweep cell, retry) starts from the same shape even after a partial
       ERRMEM failure. */
    static const char nested_src[] =
      "local reg = debug.getregistry()\n"
      "local LOADED = reg._LOADED\n"
      "setmetatable(LOADED, nil)\n"
      "rawset(LOADED, 'A', nil)\n"
      "rawset(LOADED, 'B', nil)\n"
      "reg._PRELOAD['A'] = function()\n"
      "  setmetatable(LOADED, { __newindex = function(t, k, v)\n"
      "    rawset(t, k, v)\n"
      "    if k == 'A' then require('B') end\n"
      "  end })\n"
      "  return 'av'\n"
      "end\n"
      "reg._PRELOAD['B'] = function() return 'bv' end\n"
      "local a, b = require('A')\n"
      "setmetatable(LOADED, nil)\n"
      "return a, b, rawget(LOADED, 'A'), rawget(LOADED, 'B')\n";
    if (luaL_dostring(L4, nested_src) != LUA_OK) {
      printf("STEP 7: RESULT err[plain]=%s\n",
             lua_tostring(L4, -1) ? lua_tostring(L4, -1) : "?");
      fail("nested require scenario succeeds");
      lua_pop(L4, 1);
    }
    else {
      check(nested_results_ok(L4), "nested require results (a, data, A, B)");
      lua_pop(L4, 4);
    }
    int saw_errmem = 0, saw_success = 0;
    int errmem_min = 0, errmem_max = 0, success_min = 0, success_max = 0;
    for (int n = 1; n <= 40; n++) {
      luaL_loadstring(L4, nested_src); /* compile outside the window */
      alloc_countdown = n;
      int rc = lua_pcall(L4, 0, LUA_MULTRET, 0);
      alloc_countdown = -1;
      int recovered = 1;
      const char *why = "";
      if (rc == LUA_OK) {
        saw_success++;
        if (success_min == 0) success_min = n;
        success_max = n;
        if (!nested_results_ok(L4)) {
          recovered = 0;
          why = "wrong results after in-window success";
        }
        lua_pop(L4, 4);
      }
      else if (rc == LUA_ERRMEM) {
        saw_errmem++;
        if (errmem_min == 0) errmem_min = n;
        errmem_max = n;
        lua_pop(L4, 1); /* error object */
        if (luaL_dostring(L4, "return 1+1") != LUA_OK) {
          lua_pop(L4, 1);
          recovered = 0;
          why = "VM unusable after ERRMEM";
        }
        else {
          if (lua_tointeger(L4, -1) != 2) {
            recovered = 0;
            why = "dostring wrong value after ERRMEM";
          }
          lua_pop(L4, 1);
        }
        if (recovered) {
          if (luaL_dostring(L4, nested_src) != LUA_OK) {
            lua_pop(L4, 1);
            recovered = 0;
            why = "retry after ERRMEM failed";
          }
          else if (!nested_results_ok(L4)) {
            lua_pop(L4, 4);
            recovered = 0;
            why = "retry after ERRMEM returned wrong results";
          }
          else {
            lua_pop(L4, 4);
          }
        }
      }
      else {
        lua_pop(L4, 1);
        recovered = 0;
        why = "protected run failed with unexpected status";
      }
      if (recovered)
        printf("STEP 7: OK N=%d recovered\n", n);
      else {
        printf("STEP 7: FAIL N=%d %s\n", n, why);
        failures++;
      }
    }
    if (raw_diag)
      printf("STEP 7: RESULT saw_errmem=%d saw_success=%d points=40 "
             "errmem_N=%d..%d success_N=%d..%d\n",
             saw_errmem, saw_success, errmem_min, errmem_max,
             success_min, success_max);
    check(saw_errmem > 0, "nested OOM sweep saw at least one ERRMEM");
    check(saw_success > 0, "nested OOM sweep saw at least one success");
    check(saw_errmem + saw_success == 40,
          "every nested OOM point classified (ERRMEM or success)");
    check(errmem_max > errmem_min,
          "nested ERRMEM window spans several points (late points reached)");
    lua_close(L4);
    if (raw_diag)
      printf("STEP 7: RESULT balance allocs=%ld frees=%ld "
             "foreign_frees=%ld live=%ld\n",
             bal_allocs, bal_frees, bal_foreign_frees, bal_live());
    check(bal_live() == 0,
          "no block allocated in the nested OOM window survives lua_close");
  }

  lua_close(L);
  printf("ORACLE: %d failures\n", failures);
  return failures == 0 ? 0 : 1;
}
