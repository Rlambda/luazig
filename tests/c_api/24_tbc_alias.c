/*
** 24_tbc_alias — per-mark close identity for aliased to-be-closed values.
**
** PUC luaF_close walks the tbclist per MARK, never per object: the same
** object bound to N to-be-closed slots is closed N times, LIFO. This
** suite pins that contract on the C lane (lua_toclose marks on a C
** frame), where a historical object-identity guard silently skipped the
** second close of an aliased object.
**
**   C-A1  a C body marks the SAME object twice (two lua_toclose marks
**         on one C frame) with __close = coroutine.yield (direct
**         builtin) and returns normally. The marks close at the C
**         return (luaD_poscall → moveresults CIST_TBC → luaF_close,
**         yy=1), LIFO, one __close invocation per MARK — each close
**         suspends the coroutine with the object itself, so resume1
**         and resume2 must both report LUA_YIELD with a table and
**         resume3 must complete the body with "c-done".
**
**   C-A2  control: the same shape with two DISTINCT objects — the
**         per-mark contract must not depend on aliasing.
**
** Determinism rules (same as 22/23): only fixed labels, statuses and
** controlled strings are printed; suspended values are reported by type
** name, never by address.
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* C-A1 body: mark the SAME object twice — two lua_toclose marks on this
** one C frame — then return normally. The marks close at the C return,
** LIFO, one __close invocation per MARK; with __close = coroutine.yield
** each close suspends the coroutine exactly once. */
static int c_tbc_alias_twice(lua_State *L) {
    lua_pushvalue(L, 1);
    lua_toclose(L, -1);
    lua_pushvalue(L, 1);
    lua_toclose(L, -1);
    lua_pushliteral(L, "c-done");
    return 1;
}

/* C-A2 control body: mark two DISTINCT objects (args 1 and 2). */
static int c_tbc_distinct_twice(lua_State *L) {
    lua_pushvalue(L, 1);
    lua_toclose(L, -1);
    lua_pushvalue(L, 2);
    lua_toclose(L, -1);
    lua_pushliteral(L, "c-done");
    return 1;
}

/* Run one alias case: objsrc defines the global(s) holding the closable
** object(s) (YOBJ with __close = coroutine.yield, direct builtin);
** body marks and returns; three resumes must observe two yield
** suspensions (value = a table) and one final OK ("c-done"). */
static int run_case(const char *label, const char *objsrc,
                    const char *bodycall, lua_CFunction body) {
    lua_State *L = luaL_newstate();
    if (!L) {
        printf("%s FAIL: newstate\n", label);
        return 1;
    }
    luaL_openlibs(L);
    if (luaL_dostring(L, objsrc) != 0) {
        printf("%s FAIL: setup: %s\n", label,
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return 1;
    }
    lua_pushcfunction(L, body);
    lua_setglobal(L, "CBODY");
    /* co = coroutine.create(function() return CBODY(...) end) */
    lua_getglobal(L, "coroutine");
    lua_getfield(L, -1, "create");
    lua_remove(L, -2);
    if (luaL_loadstring(L, bodycall) != 0 ||
        lua_pcall(L, 0, 1, 0) != 0 ||      /* run chunk -> factory */
        lua_pcall(L, 1, 1, 0) != 0) {      /* call create(factory) */
        printf("%s FAIL: create: %s\n", label,
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return 1;
    }
    lua_State *co = lua_tothread(L, -1);
    if (!co) {
        printf("%s FAIL: not a thread\n", label);
        lua_close(L);
        return 1;
    }
    {
        int i;
        for (i = 1; i <= 3; i++) {
            int nres = 0;
            int st = lua_resume(co, L, 0, &nres);
            printf("%s resume%d: st=%d nres=%d val=%s\n", label, i, st,
                   nres,
                   (nres > 0 && lua_isstring(co, -1))
                       ? lua_tostring(co, -1)
                       : (nres > 0 ? lua_typename(co, lua_type(co, -1))
                                   : "-"));
            if (st != LUA_YIELD && st != LUA_OK) {
                printf("%s FAIL: unexpected status\n", label);
                lua_close(L);
                return 1;
            }
        }
    }
    lua_pop(L, 1);  /* co */
    lua_close(L);
    return 0;
}

int main(void) {
    /* Unbuffered stdout: if a runtime dies on a signal mid-suite, every
    ** line printed before the crash is still visible in the lane logs. */
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== 24_tbc_alias: per-mark close identity (C lane) ===\n");
    if (run_case("C-A1",
                 "YOBJ = setmetatable({}, {__close = coroutine.yield})",
                 "return function() return CBODY(YOBJ) end",
                 c_tbc_alias_twice))
        return 1;
    if (run_case("C-A2",
                 "Y1 = setmetatable({}, {__close = coroutine.yield})\n"
                 "Y2 = setmetatable({}, {__close = coroutine.yield})",
                 "return function() return CBODY(Y1, Y2) end",
                 c_tbc_distinct_twice))
        return 1;
    printf("=== 24_tbc_alias DONE ===\n");
    return 0;
}
