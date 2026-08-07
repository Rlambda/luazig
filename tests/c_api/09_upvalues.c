#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int counter(lua_State *L) {
    lua_Integer n = lua_tointegerx(L, lua_upvalueindex(1), NULL);
    n++;
    /* Write new value to upvalue via pseudo-index (lua_replace = copy + pop) */
    lua_pushinteger(L, n);
    lua_replace(L, lua_upvalueindex(1));
    lua_pushinteger(L, n);
    return 1;
}

int main(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* Create closure with 1 upvalue (initial value 0) */
    lua_pushinteger(L, 0);
    lua_pushcclosure(L, counter, 1);
    lua_setglobal(L, "counter");

    luaL_dostring(L, "return counter()");
    if (lua_tointegerx(L, -1, NULL) != 1) {
        fprintf(stderr, "FAIL: counter #1 = %lld\n", (long long)lua_tointegerx(L, -1, NULL));
        return 1;
    }
    lua_pop(L, 1);

    luaL_dostring(L, "return counter()");
    if (lua_tointegerx(L, -1, NULL) != 2) {
        fprintf(stderr, "FAIL: counter #2 = %lld\n", (long long)lua_tointegerx(L, -1, NULL));
        return 1;
    }
    lua_pop(L, 1);

    luaL_dostring(L, "return counter()");
    if (lua_tointegerx(L, -1, NULL) != 3) {
        fprintf(stderr, "FAIL: counter #3 = %lld\n", (long long)lua_tointegerx(L, -1, NULL));
        return 1;
    }

    lua_close(L);
    printf("PASS: 09_upvalues\n");
    return 0;
}
