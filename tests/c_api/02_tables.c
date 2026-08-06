/*
** 02_tables.c — tests for Phase 2 table operation C API functions.
**
** Exercises the functions added in Phase 2:
**   lua_gettable, lua_settable,
**   lua_geti, lua_seti,
**   lua_rawgeti, lua_rawseti,
**   lua_rawgetp, lua_rawsetp.
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

int main(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: luaL_newstate\n"); return 1; }

    /* --- seti / geti (with metamethods path, though no MT here) --- */
    lua_newtable(L);  /* stack: {} */
    lua_pushinteger(L, 100);
    lua_seti(L, -2, 1);  /* t[1] = 100 */
    lua_pushinteger(L, 200);
    lua_seti(L, -2, 2);  /* t[2] = 200 */

    lua_geti(L, -1, 1);  /* push t[1] */
    if (lua_tointegerx(L, -1, NULL) != 100) {
        fprintf(stderr, "FAIL: geti(1) = %lld\n", (long long)lua_tointegerx(L, -1, NULL));
        lua_close(L); return 1;
    }
    lua_pop(L, 1);

    lua_geti(L, -1, 2);  /* push t[2] */
    if (lua_tointegerx(L, -1, NULL) != 200) {
        fprintf(stderr, "FAIL: geti(2) = %lld\n", (long long)lua_tointegerx(L, -1, NULL));
        lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- rawseti / rawgeti (no metamethods) --- */
    lua_pushinteger(L, 300);
    lua_rawseti(L, -2, 3);  /* t[3] = 300 (raw) */
    lua_rawgeti(L, -1, 3);  /* push t[3] (raw) */
    if (lua_tointegerx(L, -1, NULL) != 300) {
        fprintf(stderr, "FAIL: rawgeti(3) = %lld\n", (long long)lua_tointegerx(L, -1, NULL));
        lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- gettable / settable (key from stack, with metamethods) --- */
    lua_pushstring(L, "key1");
    lua_pushinteger(L, 42);
    lua_settable(L, -3);  /* t["key1"] = 42 */
    lua_pushstring(L, "key1");
    lua_gettable(L, -2);  /* push t["key1"] */
    if (lua_tointegerx(L, -1, NULL) != 42) {
        fprintf(stderr, "FAIL: gettable(key1) = %lld\n", (long long)lua_tointegerx(L, -1, NULL));
        lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- rawgetp / rawsetp (light userdata pointer key) --- */
    int sentinel = 42;
    lua_pushstring(L, "ptr-value");
    lua_rawsetp(L, -2, &sentinel);  /* t[&sentinel] = "ptr-value" */
    lua_rawgetp(L, -1, &sentinel);  /* push t[&sentinel] */
    size_t len = 0;
    const char *s = lua_tolstring(L, -1, &len);
    if (!s || strcmp(s, "ptr-value") != 0) {
        fprintf(stderr, "FAIL: rawgetp = '%s'\n", s ? s : "(null)");
        lua_close(L); return 1;
    }
    lua_pop(L, 2);  /* pop value and table */

    /* Verify stack is empty */
    if (lua_gettop(L) != 0) {
        fprintf(stderr, "FAIL: stack not empty: %d\n", lua_gettop(L));
        lua_close(L); return 1;
    }

    lua_close(L);
    printf("PASS: 02_tables\n");
    return 0;
}
