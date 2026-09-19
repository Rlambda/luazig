#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"

static int r14_cfun(lua_State *L) {
    (void)L;
    return 0;
}

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

    /* ── P16.50-review-14 2c: luaL_getmetafield (lauxlib.c:884-897) ── */

    /* (1) no metatable: LUA_TNIL, stack unchanged */
    lua_settop(L, 0);
    lua_pushinteger(L, 42);
    if (luaL_getmetafield(L, 1, "__index") != LUA_TNIL) {
        fprintf(stderr, "FAIL: getmetafield no-mt\n"); return 1;
    }
    if (lua_gettop(L) != 1) {
        fprintf(stderr, "FAIL: getmetafield no-mt stack\n"); return 1;
    }

    /* (2) metatable with fields: the REAL type tag is returned and the
       value is pushed on top of the stack */
    lua_settop(L, 0);
    lua_newtable(L);              /* owner at 1 */
    lua_newtable(L);              /* metatable at 2 */
    lua_pushcfunction(L, r14_cfun);
    lua_setfield(L, 2, "f");
    lua_pushstring(L, "str");
    lua_setfield(L, 2, "s");
    lua_pushnumber(L, 1.5);
    lua_setfield(L, 2, "n");
    if (lua_setmetatable(L, 1) != 1) {
        fprintf(stderr, "FAIL: setmetatable owner\n"); return 1;
    }
    if (luaL_getmetafield(L, 1, "f") != LUA_TFUNCTION) {
        fprintf(stderr, "FAIL: getmetafield f tag\n"); return 1;
    }
    if (lua_type(L, -1) != LUA_TFUNCTION) {
        fprintf(stderr, "FAIL: getmetafield f pushed\n"); return 1;
    }
    lua_pop(L, 1);
    if (luaL_getmetafield(L, 1, "s") != LUA_TSTRING) {
        fprintf(stderr, "FAIL: getmetafield s tag\n"); return 1;
    }
    lua_pop(L, 1);
    if (luaL_getmetafield(L, 1, "n") != LUA_TNUMBER) {
        fprintf(stderr, "FAIL: getmetafield n tag\n"); return 1;
    }
    lua_pop(L, 1);
    /* nil/absent metafield: LUA_TNIL, stack unchanged */
    {
        int top = lua_gettop(L);
        if (luaL_getmetafield(L, 1, "absent") != LUA_TNIL) {
            fprintf(stderr, "FAIL: getmetafield absent\n"); return 1;
        }
        if (lua_gettop(L) != top) {
            fprintf(stderr, "FAIL: getmetafield absent stack\n"); return 1;
        }
    }

    /* (3) TYPE-LEVEL slot (number owner): luaL_getmetafield resolves it
       through lua_getmetatable like PUC */
    lua_settop(L, 0);
    lua_pushinteger(L, 42);
    lua_newtable(L);              /* metatable at 2 */
    lua_pushinteger(L, 7);
    lua_setfield(L, 2, "answer");
    if (lua_setmetatable(L, 1) != 1) {
        fprintf(stderr, "FAIL: setmetatable number slot\n"); return 1;
    }
    if (luaL_getmetafield(L, 1, "answer") != LUA_TNUMBER) {
        fprintf(stderr, "FAIL: getmetafield number slot tag\n"); return 1;
    }
    if (lua_tointegerx(L, -1, NULL) != 7) {
        fprintf(stderr, "FAIL: getmetafield number slot value\n"); return 1;
    }
    lua_pop(L, 1);
    lua_settop(L, 0);

    lua_close(L);
    printf("PASS: 05_auxlib\n");
    return 0;
}
