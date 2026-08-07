#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

int main(void) {
    lua_State *L = luaL_newstate();

    /* Open all libraries */
    luaL_openlibs(L);

    /* Verify math table exists */
    lua_getglobal(L, "math");
    if (lua_type(L, -1) != LUA_TTABLE) {
        fprintf(stderr, "FAIL: math is not a table\n");
        return 1;
    }

    /* Verify math.pi exists */
    lua_getfield(L, -1, "pi");
    if (lua_type(L, -1) != LUA_TNUMBER) {
        fprintf(stderr, "FAIL: math.pi is not a number\n");
        return 1;
    }
    lua_pop(L, 2);

    /* Verify string table exists */
    lua_getglobal(L, "string");
    if (lua_type(L, -1) != LUA_TTABLE) {
        fprintf(stderr, "FAIL: string is not a table\n");
        return 1;
    }
    lua_pop(L, 1);

    /* Test running Lua code with libraries open */
    if (luaL_loadstring(L, "return string.len('hello')") != LUA_OK) {
        fprintf(stderr, "FAIL: loadstring with string.len\n");
        return 1;
    }
    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
        fprintf(stderr, "FAIL: pcall string.len\n");
        return 1;
    }
    if (lua_tointegerx(L, -1, NULL) != 5) {
        fprintf(stderr, "FAIL: string.len('hello') = %lld\n",
                (long long)lua_tointegerx(L, -1, NULL));
        return 1;
    }
    lua_pop(L, 1);

    /* Test luaopen_math directly */
    lua_State *L2 = luaL_newstate();
    int n = luaopen_math(L2);
    if (n != 1 || lua_type(L2, -1) != LUA_TTABLE) {
        fprintf(stderr, "FAIL: luaopen_math\n");
        return 1;
    }
    lua_close(L2);

    lua_close(L);
    printf("PASS: 07_libs\n");
    return 0;
}
