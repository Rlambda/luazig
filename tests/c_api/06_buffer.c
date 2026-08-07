#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"

int main(void) {
    lua_State *L = luaL_newstate();

    /* luaL_Buffer: build a string incrementally */
    luaL_Buffer B;
    luaL_buffinit(L, &B);

    luaL_addstring(&B, "hello ");
    luaL_addstring(&B, "world");

    /* Test addchar macro */
    luaL_addchar(&B, '!');
    luaL_addchar(&B, '!');

    luaL_pushresult(&B);

    size_t len;
    const char *result = lua_tolstring(L, -1, &len);
    if (!result || strcmp(result, "hello world!!") != 0) {
        fprintf(stderr, "FAIL: buffer result = '%s'\n", result ? result : "NULL");
        return 1;
    }
    if (len != 13) {
        fprintf(stderr, "FAIL: buffer len = %zu\n", len);
        return 1;
    }
    lua_pop(L, 1);

    /* Test addvalue */
    luaL_buffinit(L, &B);
    lua_pushstring(L, "from-stack");
    luaL_addvalue(&B);
    luaL_addstring(&B, "-suffix");
    luaL_pushresult(&B);
    result = lua_tolstring(L, -1, &len);
    if (!result || strcmp(result, "from-stack-suffix") != 0) {
        fprintf(stderr, "FAIL: addvalue result = '%s'\n", result ? result : "NULL");
        return 1;
    }
    lua_pop(L, 1);

    /* Test buffinitsize for large buffer */
    luaL_buffinit(L, &B);
    char *buf = luaL_prepbuffsize(&B, 2048); /* exceeds inline 1024 */
    if (!buf) {
        fprintf(stderr, "FAIL: prepbuffsize returned NULL\n");
        return 1;
    }
    memset(buf, 'x', 2048);
    luaL_addsize(&B, 2048);
    luaL_pushresult(&B);
    result = lua_tolstring(L, -1, &len);
    if (len != 2048) {
        fprintf(stderr, "FAIL: large buffer len = %zu\n", len);
        return 1;
    }
    lua_pop(L, 1);

    /* Test addgsub */
    luaL_buffinit(L, &B);
    luaL_addgsub(&B, "a-b-c", "-", "+");
    luaL_pushresult(&B);
    result = lua_tolstring(L, -1, &len);
    if (!result || strcmp(result, "a+b+c") != 0) {
        fprintf(stderr, "FAIL: addgsub = '%s'\n", result ? result : "NULL");
        return 1;
    }
    lua_pop(L, 1);

    lua_close(L);
    printf("PASS: 06_buffer\n");
    return 0;
}
