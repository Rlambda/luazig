/*
** 20_ccall_depth.c — PUC C-call-depth (LUAI_MAXCCALLS) regression suite.
**
** P16.24 blocking coverage: the same C boundary must be owned EXACTLY once
** per call (PUC ldo.c ccall), resume must inherit the source thread's C
** depth (lstate.c), and caught overflow must not leak depth.
**
** Prints depth numbers; the DIFF lane compares them against PUC directly.
** Expected (PUC 5.5 reference): main ~= 198, coroutine ~= 198 — the same
** boundary model in both contexts, NOT a factor-of-two divergence.
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int depth;

/* Recursive C function: each level consumes one C-call unit through
** lua_call (PUC: lua_call -> luaD_callnoyield -> ccall(nyci)). */
static int c_recurse(lua_State *L) {
  depth++;
  lua_getglobal(L, "c_recurse");
  lua_call(L, 0, 0);
  return 0;
}

/* Case A: recursive lua_call from main execution (protected outer pcall). */
static int run_main(lua_State *L) {
  (void)L;
  depth = 0;
  lua_getglobal(L, "c_recurse");
  lua_call(L, 0, 0);
  return 0;
}

/* Case B: the same recursive lua_call, but entered inside a coroutine. */
static int run_in_co(lua_State *L) {
  (void)L;
  depth = 0;
  lua_getglobal(L, "c_recurse");
  lua_call(L, 0, 0);
  return 0;
}

/* Case E: lua_callk with a real continuation (yieldable variant). */
static int k_noop(lua_State *L, int status, lua_KContext ctx) {
  (void)L; (void)status; (void)ctx;
  return 0;
}
static int c_recurse_k(lua_State *L) {
  depth++;
  lua_getglobal(L, "c_recurse_k");
  lua_callk(L, 0, 0, 0, k_noop);
  return 0;
}
static int run_main_k(lua_State *L) {
  (void)L;
  depth = 0;
  lua_getglobal(L, "c_recurse_k");
  lua_callk(L, 0, 0, 0, k_noop);
  return 0;
}

/* Case C/D helper: run `run_main` repeatedly; every iteration must reach
** the same depth (no leaked units across caught overflows). */
static int run_repeat(lua_State *L) {
  int i;
  int first = -1;
  for (i = 0; i < 3; i++) {
    depth = 0;
    lua_getglobal(L, "run_main");
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
      lua_pop(L, 1);
      if (first < 0) first = depth;
      else if (depth != first) {
        lua_pushfstring(L, "leak: run %d depth %d != %d", i, depth, first);
        return lua_error(L);
      }
    }
    else {
      lua_pushstring(L, "no overflow?");
      return lua_error(L);
    }
  }
  lua_pushinteger(L, first);
  return 1;
}

/* Report one protected overflow run of `fn`, printing its depth. */
static void report(lua_State *L, const char *tag, const char *fn) {
  int st;
  depth = 0;
  lua_getglobal(L, fn);
  st = lua_pcall(L, 0, 0, 0);
  printf("%s: status=%d depth=%d err=%s\n", tag, st, depth,
         (st != LUA_OK) ? lua_tostring(L, -1) : "none");
  if (st != LUA_OK) lua_pop(L, 1);
}

int main(void) {
  lua_State *L = luaL_newstate();
  setvbuf(stdout, NULL, _IONBF, 0);
  luaL_openlibs(L);

  lua_pushcfunction(L, c_recurse);   lua_setglobal(L, "c_recurse");
  lua_pushcfunction(L, c_recurse_k); lua_setglobal(L, "c_recurse_k");
  lua_pushcfunction(L, run_main);    lua_setglobal(L, "run_main");
  lua_pushcfunction(L, run_in_co);   lua_setglobal(L, "run_in_co");
  lua_pushcfunction(L, run_main_k);  lua_setglobal(L, "run_main_k");
  lua_pushcfunction(L, run_repeat);  lua_setglobal(L, "run_repeat");

  /* Case A — main-execution recursive lua_call. */
  report(L, "A main", "run_main");

  /* Case B — identical recursion inside a coroutine: resume entry must
  ** inherit the SOURCE depth (getCcalls(from)), so the boundary model is
  ** the same as on the main thread — not a factor-of-two divergence. */
  {
    /* Case B: the recursive C boundary INSIDE a coroutine, with the resume
    ** itself driven from Lua (the upstream cstack.lua shape — raw
    ** lua_resume from a C host hits a vendored-PUC development-snapshot
    ** bug in the overflow-unwind path, so the DIFF lane uses the Lua-driven
    ** form both engines support). Depth must match Case A's model — a
    ** factor-of-two divergence means double boundary ownership. */
    static const char *body =
      "local co = coroutine.wrap(function() c_recurse() end)\n"
      "local ok, e = pcall(co)\n"
      "if not ok then error(e, 0) end";
    if (luaL_loadstring(L, body) != LUA_OK) {
      printf("B co: load failed\n");
    }
    else {
      depth = 0;
      {
        int st = lua_pcall(L, 0, 0, 0);
        printf("B co: status=%d depth=%d err=%s\n", st, depth,
               (st != LUA_OK) ? lua_tostring(L, -1) : "none");
      }
    }
  }

  /* Case C — VM usable after overflow; plain call still works. */
  lua_getglobal(L, "tostring");
  lua_pushinteger(L, 42);
  lua_call(L, 1, 1);
  printf("C recovered: %s\n", lua_tostring(L, -1));
  lua_pop(L, 1);

  /* Case D — repeated overflow: identical depths (no leak). */
  lua_getglobal(L, "run_repeat");
  if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
    printf("D repeat: FAIL %s\n", lua_tostring(L, -1));
    lua_pop(L, 1);
  }
  else {
    printf("D repeat: stable depth=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
  }

  /* Case E — recursive lua_callk (yieldable variant) on main. */
  report(L, "E callk", "run_main_k");

  /* Case F — pcallk with continuation stays functional (10_continuations
  ** covers the full matrix; here just a sanity call-through). */
  lua_getglobal(L, "run_main");
  if (lua_pcallk(L, 0, 0, 0, 0, NULL) != LUA_OK) {
    printf("F pcallk: caught overflow (ok)\n");
    lua_pop(L, 1);
  }

  lua_close(L);
  printf("OK\n");
  return 0;
}
