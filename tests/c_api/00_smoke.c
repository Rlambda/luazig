/*
** 00_smoke.c — minimal C-link smoke test for liblua.so.
**
** Proves that a real C program can link against luazig's liblua.so and
** exercise the C API: create a state, compile/run a string, test table
** operations, and verify stack management.
**
** Only uses functions from the 62 exported symbols (see build.zig).
** Does NOT use luaL_dostring (macro needing luaL_loadstring) or
** lua_tostring (macro needing lua_tolstring) — both unimplemented.
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

int main(void) {
    lua_State *L = luaL_newstate();
    if (!L) {
        fprintf(stderr, "FAIL: luaL_newstate returned NULL\n");
        return 1;
    }

    /* Compile and run "return 1 + 2" via luaL_loadbufferx + lua_pcallk.
    ** luaL_loadbufferx pushes the compiled chunk as a function; lua_pcallk
    ** calls it with 0 args, expecting 1 result. */
    const char *code = "return 1 + 2";
    if (luaL_loadbufferx(L, code, strlen(code), "=smoke", NULL) != LUA_OK) {
        fprintf(stderr, "FAIL: load error\n");
        lua_close(L);
        return 1;
    }
    if (lua_pcallk(L, 0, 1, 0, 0, NULL) != LUA_OK) {
        fprintf(stderr, "FAIL: pcall error\n");
        lua_close(L);
        return 1;
    }

    /* Check the integer result is 3. */
    lua_Integer result = lua_tointegerx(L, -1, NULL);
    if (result != 3) {
        fprintf(stderr, "FAIL: expected 3, got %lld\n", (long long)result);
        lua_close(L);
        return 1;
    }
    lua_pop(L, 1);

    /* Test table: createtable, setfield, getfield round-trip. */
    lua_createtable(L, 0, 0);
    lua_pushinteger(L, 42);
    lua_setfield(L, -2, "answer");
    lua_getfield(L, -1, "answer");
    lua_Integer val = lua_tointegerx(L, -1, NULL);
    if (val != 42) {
        fprintf(stderr, "FAIL: table getfield = %lld, expected 42\n", (long long)val);
        lua_close(L);
        return 1;
    }
    lua_pop(L, 2);

    /* Verify stack is empty after all pops. */
    if (lua_gettop(L) != 0) {
        fprintf(stderr, "FAIL: stack not empty: %d\n", lua_gettop(L));
        lua_close(L);
        return 1;
    }

    lua_close(L);
    printf("PASS: 00_smoke\n");
    return 0;
}
