/*
** 11_closethread.c — C API test for lua_closethread and lua_status.
**
** Tests:
**   1. lua_closethread on a fresh unused coroutine → LUA_OK.
**   2. lua_closethread on a suspended coroutine with a to-be-closed
**      variable → LUA_OK, __close metamethod runs.
**   3. lua_closethread on a coroutine whose __close errors → LUA_ERRRUN,
**      error object on top of stack.
**   4. Double lua_closethread → LUA_OK both times (idempotent reset).
**   5. lua_status after lua_resume returns LUA_YIELD → LUA_YIELD (1);
**      after LUA_OK completion → LUA_OK (0).
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* ------------------------------------------------------------------ */
/* Test 1: lua_closethread on a fresh unused coroutine               */
/* ------------------------------------------------------------------ */

static int test_close_fresh(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: newstate\n"); return 1; }
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    /* A fresh coroutine has not been resumed yet. lua_closethread should
    ** succeed (PUC luaE_resetthread on a fresh thread is a no-op reset). */
    int st = lua_closethread(co, L);
    if (st != LUA_OK) {
        fprintf(stderr, "FAIL t1: lua_closethread returned %d, expected %d\n",
                st, LUA_OK);
        lua_close(L);
        return 1;
    }

    lua_close(L);
    printf("PASS: t1 close_fresh\n");
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 2: lua_closethread on a suspended coroutine with <close>     */
/* ------------------------------------------------------------------ */

static int test_close_suspended(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: newstate\n"); return 1; }
    luaL_openlibs(L);

    /* Set global X = 0 to track __close execution. */
    luaL_dostring(L, "X = 0");

    /* Create a coroutine with a to-be-closed variable that sets X=1,
    ** then yields. When lua_closethread runs, it forces the coroutine
    ** to unwind, running __close which sets X=1. */
    lua_State *co = lua_newthread(L);
    const char *code =
        "local x <close> = setmetatable({}, {\n"
        "  __close = function() X = 1 end\n"
        "})\n"
        "coroutine.yield()\n";
    if (luaL_loadbufferx(co, code, strlen(code), "=t2", NULL) != LUA_OK) {
        fprintf(stderr, "FAIL t2: load: %s\n", lua_tolstring(co, -1, NULL));
        lua_close(L);
        return 1;
    }

    /* Resume: should yield (coroutine.yield() with no args). */
    int nres;
    int st = lua_resume(co, L, 0, &nres);
    if (st != LUA_YIELD) {
        fprintf(stderr, "FAIL t2: resume returned %d, expected LUA_YIELD(%d)\n",
                st, LUA_YIELD);
        lua_close(L);
        return 1;
    }

    /* Close the suspended coroutine. __close should run, setting X=1. */
    st = lua_closethread(co, L);
    if (st != LUA_OK) {
        fprintf(stderr, "FAIL t2: lua_closethread returned %d, expected %d\n",
                st, LUA_OK);
        lua_close(L);
        return 1;
    }

    /* Verify X was set to 1 by __close. */
    lua_getglobal(L, "X");
    lua_Integer x = lua_tointeger(L, -1);
    lua_pop(L, 1);
    if (x != 1) {
        fprintf(stderr, "FAIL t2: X=%lld, expected 1 (__close did not run)\n",
                (long long)x);
        lua_close(L);
        return 1;
    }

    /* Verify the coroutine is now dead: resume should fail. */
    st = lua_resume(co, L, 0, &nres);
    if (st == LUA_OK || st == LUA_YIELD) {
        fprintf(stderr, "FAIL t2: resume after close returned %d, expected error\n",
                st);
        lua_close(L);
        return 1;
    }

    lua_close(L);
    printf("PASS: t2 close_suspended\n");
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 3: lua_closethread with __close error → LUA_ERRRUN          */
/* ------------------------------------------------------------------ */

static int test_close_error(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: newstate\n"); return 1; }
    luaL_openlibs(L);

    /* Create a coroutine with a to-be-closed variable whose __close
    ** errors. When lua_closethread runs, the __close error should
    ** cause it to return LUA_ERRRUN with the error object on the
    ** stack (PUC luaD_seterrorobj). */
    lua_State *co = lua_newthread(L);
    const char *code =
        "local x <close> = setmetatable({}, {\n"
        "  __close = function() error('close_err') end\n"
        "})\n"
        "coroutine.yield()\n";
    if (luaL_loadbufferx(co, code, strlen(code), "=t3", NULL) != LUA_OK) {
        fprintf(stderr, "FAIL t3: load: %s\n", lua_tolstring(co, -1, NULL));
        lua_close(L);
        return 1;
    }

    /* Resume: should yield. */
    int nres;
    int st = lua_resume(co, L, 0, &nres);
    if (st != LUA_YIELD) {
        fprintf(stderr, "FAIL t3: resume returned %d, expected LUA_YIELD(%d)\n",
                st, LUA_YIELD);
        lua_close(L);
        return 1;
    }

    /* Close: __close errors → LUA_ERRRUN, error object on stack. */
    st = lua_closethread(co, L);
    if (st != LUA_ERRRUN) {
        fprintf(stderr, "FAIL t3: lua_closethread returned %d, expected LUA_ERRRUN(%d)\n",
                st, LUA_ERRRUN);
        lua_close(L);
        return 1;
    }

    /* Verify the error object is on top of the stack and contains
    ** "close_err". PUC error() adds location prefix, so use strstr. */
    const char *msg = lua_tolstring(co, -1, NULL);
    if (!msg) {
        fprintf(stderr, "FAIL t3: no error object on stack\n");
        lua_close(L);
        return 1;
    }
    if (strstr(msg, "close_err") == NULL) {
        fprintf(stderr, "FAIL t3: error message '%s' doesn't contain 'close_err'\n",
                msg);
        lua_close(L);
        return 1;
    }

    lua_close(L);
    printf("PASS: t3 close_error\n");
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 4: Double lua_closethread (idempotent)                       */
/* ------------------------------------------------------------------ */

static int test_double_close(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: newstate\n"); return 1; }
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    const char *code =
        "local x <close> = setmetatable({}, {\n"
        "  __close = function() end\n"
        "})\n"
        "coroutine.yield()\n";
    if (luaL_loadbufferx(co, code, strlen(code), "=t4", NULL) != LUA_OK) {
        fprintf(stderr, "FAIL t4: load: %s\n", lua_tolstring(co, -1, NULL));
        lua_close(L);
        return 1;
    }

    /* Resume → yield. */
    int nres;
    int st = lua_resume(co, L, 0, &nres);
    if (st != LUA_YIELD) {
        fprintf(stderr, "FAIL t4: resume returned %d, expected LUA_YIELD(%d)\n",
                st, LUA_YIELD);
        lua_close(L);
        return 1;
    }

    /* First close → LUA_OK. */
    st = lua_closethread(co, L);
    if (st != LUA_OK) {
        fprintf(stderr, "FAIL t4: first close returned %d, expected %d\n",
                st, LUA_OK);
        lua_close(L);
        return 1;
    }

    /* Second close → LUA_OK (idempotent: PUC luaE_resetthread on a dead
    ** thread is a no-op reset). */
    st = lua_closethread(co, L);
    if (st != LUA_OK) {
        fprintf(stderr, "FAIL t4: second close returned %d, expected %d\n",
                st, LUA_OK);
        lua_close(L);
        return 1;
    }

    lua_close(L);
    printf("PASS: t4 double_close\n");
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 5: lua_status after yield and after completion               */
/* ------------------------------------------------------------------ */

static int test_status(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: newstate\n"); return 1; }
    luaL_openlibs(L);

    /* Create a coroutine that yields once, then returns. */
    lua_State *co = lua_newthread(L);
    const char *code =
        "coroutine.yield(42)\n"
        "return 99\n";
    if (luaL_loadbufferx(co, code, strlen(code), "=t5", NULL) != LUA_OK) {
        fprintf(stderr, "FAIL t5: load: %s\n", lua_tolstring(co, -1, NULL));
        lua_close(L);
        return 1;
    }

    /* Before resume: status should be LUA_OK (0) for a fresh thread.
    ** PUC: a fresh thread has status LUA_OK. */
    int st = lua_status(co);
    if (st != LUA_OK) {
        fprintf(stderr, "FAIL t5: status before resume = %d, expected %d\n",
                st, LUA_OK);
        lua_close(L);
        return 1;
    }

    /* First resume → yields 42. */
    int nres;
    st = lua_resume(co, L, 0, &nres);
    if (st != LUA_YIELD) {
        fprintf(stderr, "FAIL t5: resume1 returned %d, expected LUA_YIELD(%d)\n",
                st, LUA_YIELD);
        lua_close(L);
        return 1;
    }

    /* After yield: lua_status should return LUA_YIELD (1). */
    st = lua_status(co);
    if (st != LUA_YIELD) {
        fprintf(stderr, "FAIL t5: status after yield = %d, expected LUA_YIELD(%d)\n",
                st, LUA_YIELD);
        lua_close(L);
        return 1;
    }

    /* Second resume → returns 99 (coroutine completes). */
    st = lua_resume(co, L, 0, &nres);
    if (st != LUA_OK) {
        fprintf(stderr, "FAIL t5: resume2 returned %d, expected LUA_OK(%d)\n",
                st, LUA_OK);
        lua_close(L);
        return 1;
    }

    /* After completion: lua_status should return LUA_OK (0). */
    st = lua_status(co);
    if (st != LUA_OK) {
        fprintf(stderr, "FAIL t5: status after completion = %d, expected LUA_OK(%d)\n",
                st, LUA_OK);
        lua_close(L);
        return 1;
    }

    lua_close(L);
    printf("PASS: t5 status\n");
    return 0;
}

/* ------------------------------------------------------------------ */

int main(void) {
    if (test_close_fresh())    return 1;
    if (test_close_suspended()) return 1;
    if (test_close_error())    return 1;
    if (test_double_close())   return 1;
    if (test_status())         return 1;
    printf("PASS: 11_closethread\n");
    return 0;
}
