#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"

int main(void) {
    lua_State *L = luaL_newstate();

    /* luaL_gsub */
    const char *result = luaL_gsub(L, "hello world", "world", "lua");
    if (strcmp(result, "hello lua") != 0) {
        fprintf(stderr, "FAIL: gsub = '%s'\n", result); return 1;
    }
    lua_pop(L, 1);

    /* luaL_loadstring + pcall (expression, not global assignment) */
    if (luaL_loadstring(L, "return 42") != LUA_OK) {
        fprintf(stderr, "FAIL: loadstring\n"); return 1;
    }
    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
        fprintf(stderr, "FAIL: pcall after loadstring\n"); return 1;
    }
    if (lua_tointegerx(L, -1, NULL) != 42) {
        fprintf(stderr, "FAIL: loadstring result\n"); return 1;
    }
    lua_pop(L, 1);

    /* luaL_checktype on a table */
    lua_newtable(L);
    luaL_checktype(L, -1, LUA_TTABLE);

    /* luaL_checknumber on integer */
    lua_pushinteger(L, 99);
    double n = luaL_checknumber(L, -1);
    if (n != 99.0) {
        fprintf(stderr, "FAIL: checknumber = %g\n", n); return 1;
    }

    /* luaL_optnumber with default */
    lua_pop(L, 2);
    lua_pushnil(L);
    double opt = luaL_optnumber(L, -1, 123.0);
    if (opt != 123.0) {
        fprintf(stderr, "FAIL: optnumber = %g\n", opt); return 1;
    }
    lua_pop(L, 1);

    /* luaL_tolstring on integer */
    lua_pushinteger(L, 77);
    size_t len;
    const char *s = luaL_tolstring(L, -1, &len);
    if (!s || strcmp(s, "77") != 0) {
        fprintf(stderr, "FAIL: tolstring(77) = '%s'\n", s ? s : "NULL"); return 1;
    }
    lua_pop(L, 2);

    lua_close(L);
    printf("PASS: 05_auxlib\n");
    return 0;
}
