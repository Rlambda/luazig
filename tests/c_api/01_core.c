/*
** 01_core.c — tests for Phase 1 core C API functions.
**
** Exercises the new functions added in Phase 1:
**   lua_absindex, lua_checkstack,
**   lua_isnumber, lua_isstring, lua_isinteger, lua_iscfunction,
**   lua_isuserdata, lua_isyieldable,
**   lua_tolstring, lua_typename, lua_rawlen, lua_tocfunction,
**   lua_tothread, lua_version.
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int dummy_cfunc(lua_State *L) {
    lua_pushinteger(L, 777);
    return 1;
}

int main(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: luaL_newstate\n"); return 1; }

    /* --- lua_absindex --- */
    lua_pushnil(L);
    lua_pushinteger(L, 42);
    int abs = lua_absindex(L, -1);
    if (abs != 2) {
        fprintf(stderr, "FAIL: absindex(-1) = %d, expected 2\n", abs);
        lua_close(L); return 1;
    }
    abs = lua_absindex(L, 1);
    if (abs != 1) {
        fprintf(stderr, "FAIL: absindex(1) = %d, expected 1\n", abs);
        lua_close(L); return 1;
    }

    /* --- lua_checkstack --- */
    if (lua_checkstack(L, 100) != 1) {
        fprintf(stderr, "FAIL: checkstack(100) returned 0\n");
        lua_close(L); return 1;
    }

    /* --- lua_isnumber / lua_isinteger / lua_isstring --- */
    /* Stack: [nil, 42] — top is integer 42 */
    if (!lua_isnumber(L, -1)) {
        fprintf(stderr, "FAIL: isnumber(-1) expected true for integer\n");
        lua_close(L); return 1;
    }
    if (!lua_isinteger(L, -1)) {
        fprintf(stderr, "FAIL: isinteger(-1) expected true\n");
        lua_close(L); return 1;
    }
    if (!lua_isstring(L, -1)) {
        fprintf(stderr, "FAIL: isstring(-1) expected true for integer\n");
        lua_close(L); return 1;
    }
    if (lua_isnumber(L, -2)) {
        fprintf(stderr, "FAIL: isnumber(-2) expected false for nil\n");
        lua_close(L); return 1;
    }
    if (lua_isstring(L, -2)) {
        fprintf(stderr, "FAIL: isstring(-2) expected false for nil\n");
        lua_close(L); return 1;
    }

    /* Push a string and check isnumber/isstring */
    lua_pushstring(L, "hello");
    if (lua_isnumber(L, -1)) {
        fprintf(stderr, "FAIL: isnumber expected false for string\n");
        lua_close(L); return 1;
    }
    if (!lua_isstring(L, -1)) {
        fprintf(stderr, "FAIL: isstring expected true for string\n");
        lua_close(L); return 1;
    }
    if (lua_isinteger(L, -1)) {
        fprintf(stderr, "FAIL: isinteger expected false for string\n");
        lua_close(L); return 1;
    }

    /* Push a float and check isnumber=true, isinteger=false */
    lua_pushnumber(L, 3.14);
    if (!lua_isnumber(L, -1)) {
        fprintf(stderr, "FAIL: isnumber expected true for float\n");
        lua_close(L); return 1;
    }
    if (lua_isinteger(L, -1)) {
        fprintf(stderr, "FAIL: isinteger expected false for float\n");
        lua_close(L); return 1;
    }

    lua_settop(L, 0);

    /* --- lua_tolstring on integer --- */
    lua_pushinteger(L, 42);
    size_t len = 999;
    const char *s = lua_tolstring(L, -1, &len);
    if (!s || strcmp(s, "42") != 0 || len != 2) {
        fprintf(stderr, "FAIL: tolstring(int) = '%s' len=%zu, expected '42' len=2\n",
                s ? s : "(null)", len);
        lua_close(L); return 1;
    }
    /* After tolstring, the stack value should now be a string */
    if (lua_type(L, -1) != LUA_TSTRING) {
        fprintf(stderr, "FAIL: tolstring should convert in place, type = %d\n",
                lua_type(L, -1));
        lua_close(L); return 1;
    }

    /* --- lua_tolstring on nil (should return NULL/empty) --- */
    lua_pushnil(L);
    s = lua_tolstring(L, -1, &len);
    if (s != NULL && len != 0) {
        fprintf(stderr, "FAIL: tolstring(nil) should return NULL, got '%s' len=%zu\n",
                s ? s : "(null)", len);
        lua_close(L); return 1;
    }
    /* Restore len if it was set */
    if (s == NULL && len != 0) len = 0;

    lua_settop(L, 0);

    /* --- lua_tolstring on float --- */
    lua_pushnumber(L, 3.0);
    s = lua_tolstring(L, -1, &len);
    if (!s || len == 0) {
        fprintf(stderr, "FAIL: tolstring(float) returned null\n");
        lua_close(L); return 1;
    }
    /* PUC formats 3.0 as "3.0" */
    if (strcmp(s, "3.0") != 0) {
        fprintf(stderr, "FAIL: tolstring(3.0) = '%s', expected '3.0'\n", s);
        lua_close(L); return 1;
    }

    lua_settop(L, 0);

    /* --- lua_typename --- */
    if (strcmp(lua_typename(L, LUA_TSTRING), "string") != 0) {
        fprintf(stderr, "FAIL: typename(TSTRING) = '%s'\n", lua_typename(L, LUA_TSTRING));
        lua_close(L); return 1;
    }
    if (strcmp(lua_typename(L, LUA_TNUMBER), "number") != 0) {
        fprintf(stderr, "FAIL: typename(TNUMBER) = '%s'\n", lua_typename(L, LUA_TNUMBER));
        lua_close(L); return 1;
    }
    if (strcmp(lua_typename(L, LUA_TNIL), "nil") != 0) {
        fprintf(stderr, "FAIL: typename(TNIL) = '%s'\n", lua_typename(L, LUA_TNIL));
        lua_close(L); return 1;
    }
    if (strcmp(lua_typename(L, LUA_TTABLE), "table") != 0) {
        fprintf(stderr, "FAIL: typename(TTABLE) = '%s'\n", lua_typename(L, LUA_TTABLE));
        lua_close(L); return 1;
    }
    if (strcmp(lua_typename(L, LUA_TFUNCTION), "function") != 0) {
        fprintf(stderr, "FAIL: typename(TFUNCTION) = '%s'\n", lua_typename(L, LUA_TFUNCTION));
        lua_close(L); return 1;
    }
    if (strcmp(lua_typename(L, LUA_TTHREAD), "thread") != 0) {
        fprintf(stderr, "FAIL: typename(TTHREAD) = '%s'\n", lua_typename(L, LUA_TTHREAD));
        lua_close(L); return 1;
    }

    /* --- lua_rawlen on string --- */
    lua_pushstring(L, "hello world");
    if (lua_rawlen(L, -1) != 11) {
        fprintf(stderr, "FAIL: rawlen(string) = %u, expected 11\n", lua_rawlen(L, -1));
        lua_close(L); return 1;
    }

    /* --- lua_rawlen on table --- */
    lua_createtable(L, 0, 0);
    lua_pushinteger(L, 1);  /* key */
    lua_pushinteger(L, 10); /* value */
    lua_rawset(L, -3);
    lua_pushinteger(L, 2);  /* key */
    lua_pushinteger(L, 20); /* value */
    lua_rawset(L, -3);
    lua_pushinteger(L, 3);  /* key */
    lua_pushinteger(L, 30); /* value */
    lua_rawset(L, -3);
    if (lua_rawlen(L, -1) != 3) {
        fprintf(stderr, "FAIL: rawlen(table) = %u, expected 3\n", lua_rawlen(L, -1));
        lua_close(L); return 1;
    }

    /* --- lua_iscfunction / lua_tocfunction --- */
    lua_pushcfunction(L, dummy_cfunc);
    if (!lua_iscfunction(L, -1)) {
        fprintf(stderr, "FAIL: iscfunction expected true for C function\n");
        lua_close(L); return 1;
    }
    /* lua_tocfunction should return a non-null function pointer */
    lua_CFunction cf = lua_tocfunction(L, -1);
    if (!cf) {
        fprintf(stderr, "FAIL: tocfunction returned NULL for C closure\n");
        lua_close(L); return 1;
    }

    /* A Lua function should not be a C function */
    if (luaL_loadbufferx(L, "return function() end", 21, "=t", NULL) != LUA_OK) {
        fprintf(stderr, "FAIL: loadbuffer for lua function\n");
        lua_close(L); return 1;
    }
    if (lua_pcallk(L, 0, 1, 0, 0, NULL) != LUA_OK) {
        fprintf(stderr, "FAIL: pcall for lua function\n");
        lua_close(L); return 1;
    }
    if (lua_iscfunction(L, -1)) {
        fprintf(stderr, "FAIL: iscfunction expected false for Lua function\n");
        lua_close(L); return 1;
    }
    if (lua_tocfunction(L, -1) != NULL) {
        fprintf(stderr, "FAIL: tocfunction expected NULL for Lua function\n");
        lua_close(L); return 1;
    }

    lua_settop(L, 0);

    /* --- lua_isyieldable ---
    ** PUC semantics: the main thread is NOT yieldable (coroutine.isyieldable()
    ** returns false on the main thread). luazig follows this. */
    if (lua_isyieldable(L)) {
        fprintf(stderr, "FAIL: isyieldable expected false for main thread\n");
        lua_close(L); return 1;
    }

    /* --- lua_version --- */
    lua_Number ver = lua_version(L);
    if (ver != 505.0) {
        fprintf(stderr, "FAIL: lua_version = %g, expected 505\n", (double)ver);
        lua_close(L); return 1;
    }

    /* --- lua_isuserdata (negative test) --- */
    lua_pushinteger(L, 42);
    if (lua_isuserdata(L, -1)) {
        fprintf(stderr, "FAIL: isuserdata expected false for integer\n");
        lua_close(L); return 1;
    }

    /* --- lua_tothread (negative test: integer is not a thread) --- */
    if (lua_tothread(L, -1) != NULL) {
        fprintf(stderr, "FAIL: tothread expected NULL for integer\n");
        lua_close(L); return 1;
    }

    lua_close(L);
    printf("PASS: 01_core\n");
    return 0;
}
