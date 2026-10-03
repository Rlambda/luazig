/* cloaders.c - C-module fixtures for the package-loader smoke test
 * (tests/smoke/93_package_c_loaders.lua). One source compiled by
 * tools/smoke_compare.py into several module names per runtime (next to
 * the per-runtime udatatest.so builds), with the same no-llua
 * host-resolution build as udatatest.c:
 *   cload_ok.so      luaopen_cload_ok      plain searcher_C hit (table)
 *   cload_missing.so (no luaopen_cload_missing anywhere)  searcher_C
 *                                            ERRFUNC path (symbol missing)
 *   croot_a.so       luaopen_croot_a_sub   searcher_Croot hit for
 *                                            require("croot_a.sub")
 *   croot_b.so       (no luaopen_croot_b_sub anywhere)   searcher_Croot
 *                                            miss ("no module ... in file")
 *   cload_ig-v2.so   luaopen_cload_ig      IGMARK '-' fallback: the symbol
 *                            name is the prefix before the '-' mark
 * The negative modules stay negative in every build because
 * luaopen_cload_missing and luaopen_croot_b_sub are defined nowhere.
 */

#include "lua.h"
#include "lauxlib.h"

static int push_tagged(lua_State *L, const char *tag) {
  lua_newtable(L);
  lua_pushstring(L, tag);
  lua_setfield(L, -2, "tag");
  return 1;
}

LUAMOD_API int luaopen_cload_ok(lua_State *L) {
  return push_tagged(L, "cload_ok");
}

/* wrong name on purpose: never luaopen_cload_missing */
LUAMOD_API int luaopen_cload_other(lua_State *L) {
  return push_tagged(L, "cload_other");
}

LUAMOD_API int luaopen_croot_a_sub(lua_State *L) {
  return push_tagged(L, "croot_a_sub");
}

/* wrong name on purpose: never luaopen_croot_b_sub */
LUAMOD_API int luaopen_croot_b_other(lua_State *L) {
  return push_tagged(L, "croot_b_other");
}

/* IGMARK prefix symbol: served for require("cload_ig-v2") */
LUAMOD_API int luaopen_cload_ig(lua_State *L) {
  return push_tagged(L, "cload_ig");
}
