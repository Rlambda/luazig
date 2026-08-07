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

    lua_close(L);
    printf("PASS: 08_debug\n");
    return 0;
}
