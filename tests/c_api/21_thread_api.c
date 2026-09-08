/*
** 21_thread_api.c — lua_tothread / lua_getextraspace parity suite.
**
** 1. lua_tothread on a LUA-created coroutine (coroutine.create + yield):
**    PUC returns the thread's lua_State* for EVERY thread value (a thread
**    IS a lua_State there); luazig lazily creates+caches a stable handle
**    on the first lua_tothread call (one handle per Thread, freed with
**    the Thread by GC).
** 2. lua_getextraspace: non-NULL per-state scratch at the PUC ABI spot
**    (the LUA_EXTRASPACE bytes in front of L). New threads inherit the
**    MAIN thread's extra-space contents (PUC lstate.c:291-293 memcpy).
**
** Differential vs PUC: prints only parity-stable facts (no pointer
** values). The luaL_traceback(L, co, ...) divergence is NOT covered here
** (documented separately, out of scope for this suite).
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int failures;

static void check(int cond, const char *what) {
  if (cond) printf("PASS: %s\n", what);
  else { printf("FAIL: %s\n", what); failures++; }
}

/* Markers stored through lua_getextraspace. */
#define MAIN_MARK 0x1122334455667788ULL
#define CO_MARK   0x8877665544332211ULL

/* Copy min(sizeof(unsigned long long), LUA_EXTRASPACE) bytes — the extra
** space is sizeof(void*) bytes; on 64-bit both are 8. */
static unsigned long long read_ex(void *ex) {
  unsigned long long v = 0;
  memcpy(&v, ex, sizeof(v) < LUA_EXTRASPACE ? sizeof(v) : LUA_EXTRASPACE);
  return v;
}
static void write_ex(void *ex, unsigned long long v) {
  memcpy(ex, &v, sizeof(v) < LUA_EXTRASPACE ? sizeof(v) : LUA_EXTRASPACE);
}

int main(void) {
  lua_State *L = luaL_newstate();
  lua_State *co, *co2, *again;
  void *ex;
  setvbuf(stdout, NULL, _IONBF, 0);
  luaL_openlibs(L);
  check(L != NULL, "newstate");

  /* --- B first: store MAIN_MARK in the MAIN state's extra space BEFORE
  ** any coroutine exists, so every thread created later must inherit it
  ** (PUC lua_newthread memcpy's mainthread's extra space into L1). --- */
  ex = lua_getextraspace(L);
  check(ex != NULL, "B1 lua_getextraspace(main) != NULL");
  write_ex(ex, MAIN_MARK);
  check(read_ex(ex) == MAIN_MARK, "B2 main extra space readback");

  /* --- A: Lua-created coroutine (created AFTER the marker was stored). --- */
  if (luaL_dostring(L,
      "CO = coroutine.create(function(a)\n"
      "  local y = coroutine.yield('yielded')\n"
      "  return 'done'\n"
      "end)\n"
      "local ok, v = coroutine.resume(CO, 1)\n"
      "assert(ok and v == 'yielded')\n") != 0) {
    printf("FAIL: setup dostring: %s\n", lua_tostring(L, -1));
    return 1;
  }
  lua_getglobal(L, "CO");
  check(lua_isthread(L, -1), "A1 CO is a thread value");
  co = lua_tothread(L, -1);
  check(co != NULL, "A2 lua_tothread(Lua-created co) != NULL");
  again = lua_tothread(L, -1);
  check(again == co, "A3 lua_tothread stable across calls");
  lua_pop(L, 1);

  /* The handle round-trips through pushthread/tothread like any handle. */
  lua_pushthread(co);
  check(lua_tothread(co, -1) == co, "A4 pushthread/tothread round-trip");
  lua_pop(co, 1);

  /* --- C: the coroutine's extra space: non-NULL, inherits MAIN_MARK
  ** (PUC: memcpy at lua_newthread time; luazig: memcpy at handle-creation
  ** time — the marker was stored before coroutine.create, so both see
  ** it), and is isolated from the main state's. --- */
  ex = lua_getextraspace(co);
  check(ex != NULL, "C1 lua_getextraspace(co) != NULL");
  check(read_ex(ex) == MAIN_MARK, "C2 co extra space inherits main's contents");
  write_ex(ex, CO_MARK);
  check(read_ex(lua_getextraspace(L)) == MAIN_MARK,
        "C3 co write does not leak into main");

  /* --- D: C-created coroutine (lua_newthread): same extra-space contract. --- */
  co2 = lua_newthread(L);
  check(co2 != NULL, "D1 lua_newthread != NULL");
  check(lua_tothread(L, -1) == co2, "D2 tothread returns the newthread handle");
  ex = lua_getextraspace(co2);
  check(ex != NULL, "D3 lua_getextraspace(newthread) != NULL");
  check(read_ex(ex) == MAIN_MARK, "D4 newthread extra space inherits main's contents");
  lua_pop(L, 1);

  /* --- E: handle stability across a full GC — the coroutine is anchored
  ** in the global CO, so its Thread (and with it the cached handle) must
  ** survive collection; tothread must keep returning the SAME pointer. --- */
  lua_gc(L, LUA_GCCOLLECT);
  lua_gc(L, LUA_GCCOLLECT);
  lua_getglobal(L, "CO");
  again = lua_tothread(L, -1);
  check(again == co, "E1 handle stable across full GC");
  lua_pop(L, 1);

  /* --- F: drop the coroutine, finish it, collect: the Thread (and its
  ** handle) are freed — no crash, and the main state stays usable. --- */
  luaL_dostring(L,
      "local ok, v = coroutine.resume(CO, 2)\n"
      "assert(ok and v == 'done')\n"
      "CO = nil\n");
  lua_gc(L, LUA_GCCOLLECT);
  lua_gc(L, LUA_GCCOLLECT);
  lua_gc(L, LUA_GCCOLLECT);
  check(lua_gettop(L) == 0, "F1 main stack clean after GC");
  lua_getglobal(L, "string");
  lua_pushliteral(L, "format");
  lua_gettable(L, -2);
  lua_pushliteral(L, "%d");
  lua_pushinteger(L, 7);
  lua_call(L, 2, 1);
  check(strcmp(lua_tostring(L, -1), "7") == 0, "F2 main state usable after");
  lua_pop(L, 2);

  lua_close(L);
  if (failures) { printf("FAILURES: %d\n", failures); return 1; }
  printf("OK\n");
  return 0;
}
