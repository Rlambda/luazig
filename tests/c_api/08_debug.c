#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

int main(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* Test hook set/get */
    lua_sethook(L, NULL, 0, 0);
    if (lua_gethook(L) != NULL) { fprintf(stderr, "FAIL: hook not cleared\n"); return 1; }
    if (lua_gethookmask(L) != 0) { fprintf(stderr, "FAIL: mask not 0\n"); return 1; }

    /* Test getupvalue on C function (should return NULL — no upvalues) */
    lua_pushcfunction(L, NULL);
    const char *up = lua_getupvalue(L, -1, 1);
    if (up != NULL) { fprintf(stderr, "FAIL: C fn has upvalues?\n"); return 1; }
    lua_pop(L, 1);

    /* Test getstack */
    lua_Debug ar;
    lua_getstack(L, 0, &ar); /* OK regardless of return value */

    /* ── P16.50-review-14 2b: debug.getmetatable is a RAW
       lua_getmetatable (ldblib.c:48-54); the global getmetatable honors
       the __metatable protection field (lbaselib.c:134) ── */
    if (luaL_dostring(L,
        "local sentinel = {'sentinel'}\n"
        "local mt = {__metatable = sentinel}\n"
        "local t = setmetatable({}, mt)\n"
        "assert(getmetatable(t) == sentinel, 'global honors __metatable')\n"
        "assert(debug.getmetatable(t) == mt, 'debug.getmetatable is raw')\n"
        "local nummt = {__metatable = 'numlock'}\n"
        "assert(getmetatable(42) == nil, 'number slot unset')\n"
        "local ok = pcall(setmetatable, 42, nummt)\n"
        "assert(not ok, 'setmetatable rejects non-table owner')\n"
        "assert(debug.setmetatable(42, nummt) == 42, 'debug.setmetatable returns value')\n"
        "assert(getmetatable(42) == 'numlock', 'global sees sentinel')\n"
        "assert(debug.getmetatable(42) == nummt, 'debug sees original')\n"
        "assert(debug.setmetatable(42, nil) == 42, 'clear returns value')\n"
        "assert(debug.getmetatable(42) == nil, 'slot cleared')\n"
        "assert(debug.getmetatable(print) == nil, 'function slot unset')\n"
        "return true\n") != LUA_OK) {
        fprintf(stderr, "FAIL: debug.getmetatable differential: %s\n",
                lua_tostring(L, -1));
        return 1;
    }
    lua_pop(L, 1);

    lua_close(L);
    printf("PASS: 08_debug\n");
    return 0;
}
