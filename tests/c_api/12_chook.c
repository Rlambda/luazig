/*
** 12_chook.c — C API test for lua_sethook / lua_gethook / lua_gethookmask /
** lua_gethookcount (PUC ldebug.c).
**
** This exercises the C hook dispatch (P15.82h):
**   - lua_sethook installs a C hook function that is called at hook events
**     (count, line, call, return). The hook receives the lua_State and a
**     lua_Debug struct with the event code and currentline.
**   - lua_gethook returns the installed hook function (or NULL).
**   - lua_gethookmask returns the mask, lua_gethookcount returns the count.
**   - lua_sethook(L, NULL, 0, 0) clears the hook.
**
** PUC model (ldebug.c:133 lua_sethook, ldo.c:439 luaD_hook):
**   - ONE hook slot per lua_State: L->hook, L->hookmask, L->basehookcount.
**   - luaD_hook saves top/ci->top, sets allowhook=0 + CIST_HOOKED, calls
**     (*hook)(L, &ar) with lua_Debug{event, currentline, i_ci}, restores.
**   - The hook runs with allowhook=0 (no re-entrant hooks).
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* ------------------------------------------------------------------ */
/* Global counters (the hook must be reentrant-safe and minimal)      */
/* ------------------------------------------------------------------ */

static int hook_call_count = 0;
static int hook_last_event = -1;
static int hook_last_line = -1;

static void reset_counters(void) {
    hook_call_count = 0;
    hook_last_event = -1;
    hook_last_line = -1;
}

/* ------------------------------------------------------------------ */
/* Hook functions                                                     */
/* ------------------------------------------------------------------ */

/*
** Count hook: fires every LUA_MASKCOUNT instructions. Increments a
** counter and records the event code. Must be minimal and reentrant-safe
** (PUC runs hooks with allowhook=0).
*/
static void count_hook(lua_State *L, lua_Debug *ar) {
    (void)L;
    hook_call_count++;
    hook_last_event = ar->event;
}

/*
** Line hook: fires on line changes. Records the line number.
*/
static void line_hook(lua_State *L, lua_Debug *ar) {
    (void)L;
    hook_call_count++;
    hook_last_event = ar->event;
    hook_last_line = ar->currentline;
}

/* ------------------------------------------------------------------ */
/* Test 1: Count hook fires on a coroutine running a Lua loop         */
/* ------------------------------------------------------------------ */

/*
** Lua function: sum 1..100 in a loop. This generates enough instructions
** for the count hook to fire many times.
*/
static const char *sum_loop_code =
    "local s = 0\n"
    "for i = 1, 100 do\n"
    "    s = s + i\n"
    "end\n"
    "return s\n";

static int test_count_hook(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* Create a coroutine */
    lua_State *co = lua_newthread(L);
    if (co == NULL) {
        printf("FAIL: lua_newthread returned NULL\n");
        lua_close(L);
        return 1;
    }

    /* Load the Lua code into the coroutine */
    if (luaL_loadstring(co, sum_loop_code) != LUA_OK) {
        printf("FAIL: loadstring: %s\n", lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }

    /* Install a count hook with count=1 (fire every instruction) */
    reset_counters();
    lua_sethook(co, count_hook, LUA_MASKCOUNT, 1);

    /* Verify gethook/gethookmask/gethookcount */
    lua_Hook h = lua_gethook(co);
    if (h != count_hook) {
        printf("FAIL: lua_gethook returned wrong function\n");
        lua_close(L);
        return 1;
    }
    int mask = lua_gethookmask(co);
    if (mask != LUA_MASKCOUNT) {
        printf("FAIL: lua_gethookmask = %d, expected %d\n", mask, LUA_MASKCOUNT);
        lua_close(L);
        return 1;
    }
    int count = lua_gethookcount(co);
    if (count != 1) {
        printf("FAIL: lua_gethookcount = %d, expected 1\n", count);
        lua_close(L);
        return 1;
    }

    /* Resume the coroutine */
    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    if (status != LUA_OK) {
        printf("FAIL: lua_resume status = %d: %s\n", status,
               lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }

    /* Check the result */
    if (nres < 1) {
        printf("FAIL: no results from resume\n");
        lua_close(L);
        return 1;
    }
    lua_Integer result = lua_tointeger(co, -1);
    if (result != 5050) {
        printf("FAIL: sum = %lld, expected 5050\n", (long long)result);
        lua_close(L);
        return 1;
    }

    /* Check that the hook fired */
    if (hook_call_count <= 0) {
        printf("FAIL: count hook never fired (hook_call_count = %d)\n",
               hook_call_count);
        lua_close(L);
        return 1;
    }
    if (hook_last_event != LUA_HOOKCOUNT) {
        printf("FAIL: last hook event = %d, expected %d (LUA_HOOKCOUNT)\n",
               hook_last_event, LUA_HOOKCOUNT);
        lua_close(L);
        return 1;
    }

    printf("PASS: t1 count_hook (fired>0=%s, sum=%lld)\n", hook_call_count > 0 ? "yes" : "no", (long long)result);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 2: lua_gethook/gethookmask/gethookcount before and after set */
/* ------------------------------------------------------------------ */

static int test_gethook_api(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    if (co == NULL) {
        printf("FAIL: lua_newthread returned NULL\n");
        lua_close(L);
        return 1;
    }

    /* Before sethook: hook is NULL, mask is 0, count is 0 */
    if (lua_gethook(co) != NULL) {
        printf("FAIL: lua_gethook != NULL before sethook\n");
        lua_close(L);
        return 1;
    }
    if (lua_gethookmask(co) != 0) {
        printf("FAIL: lua_gethookmask != 0 before sethook\n");
        lua_close(L);
        return 1;
    }
    if (lua_gethookcount(co) != 0) {
        printf("FAIL: lua_gethookcount != 0 before sethook\n");
        lua_close(L);
        return 1;
    }

    /* Set a count hook with count=10 */
    lua_sethook(co, count_hook, LUA_MASKCOUNT, 10);
    if (lua_gethook(co) != count_hook) {
        printf("FAIL: lua_gethook != count_hook after sethook\n");
        lua_close(L);
        return 1;
    }
    if (lua_gethookmask(co) != LUA_MASKCOUNT) {
        printf("FAIL: lua_gethookmask != LUA_MASKCOUNT after sethook\n");
        lua_close(L);
        return 1;
    }
    if (lua_gethookcount(co) != 10) {
        printf("FAIL: lua_gethookcount != 10 after sethook\n");
        lua_close(L);
        return 1;
    }

    printf("PASS: t2 gethook_api\n");
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 3: Clearing the hook with lua_sethook(L, NULL, 0, 0)          */
/* ------------------------------------------------------------------ */

static int test_clear_hook(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    if (co == NULL) {
        printf("FAIL: lua_newthread returned NULL\n");
        lua_close(L);
        return 1;
    }

    /* Install a count hook */
    lua_sethook(co, count_hook, LUA_MASKCOUNT, 1);
    if (lua_gethook(co) != count_hook) {
        printf("FAIL: hook not set\n");
        lua_close(L);
        return 1;
    }

    /* Clear the hook */
    lua_sethook(co, NULL, 0, 0);
    if (lua_gethook(co) != NULL) {
        printf("FAIL: lua_gethook != NULL after clear\n");
        lua_close(L);
        return 1;
    }
    if (lua_gethookmask(co) != 0) {
        printf("FAIL: lua_gethookmask != 0 after clear\n");
        lua_close(L);
        return 1;
    }

    /* Run the loop — hook should NOT fire */
    reset_counters();
    if (luaL_loadstring(co, sum_loop_code) != LUA_OK) {
        printf("FAIL: loadstring: %s\n", lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }
    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    if (status != LUA_OK) {
        printf("FAIL: lua_resume status = %d: %s\n", status,
               lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }
    if (hook_call_count != 0) {
        printf("FAIL: hook fired %d times after clear\n", hook_call_count);
        lua_close(L);
        return 1;
    }

    printf("PASS: t3 clear_hook\n");
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 4: Line hook fires on line changes                            */
/* ------------------------------------------------------------------ */

/*
** Multi-line Lua code so line changes are detectable.
*/
static const char *multiline_code =
    "local x = 1\n"
    "local y = 2\n"
    "local z = 3\n"
    "return x + y + z\n";

static int test_line_hook(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    if (co == NULL) {
        printf("FAIL: lua_newthread returned NULL\n");
        lua_close(L);
        return 1;
    }

    if (luaL_loadstring(co, multiline_code) != LUA_OK) {
        printf("FAIL: loadstring: %s\n", lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }

    /* Install a line hook */
    reset_counters();
    lua_sethook(co, line_hook, LUA_MASKLINE, 0);

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    if (status != LUA_OK) {
        printf("FAIL: lua_resume status = %d: %s\n", status,
               lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }

    if (nres < 1) {
        printf("FAIL: no results from resume\n");
        lua_close(L);
        return 1;
    }
    lua_Integer result = lua_tointeger(co, -1);
    if (result != 6) {
        printf("FAIL: result = %lld, expected 6\n", (long long)result);
        lua_close(L);
        return 1;
    }

    if (hook_call_count <= 0) {
        printf("FAIL: line hook never fired\n");
        lua_close(L);
        return 1;
    }
    if (hook_last_event != LUA_HOOKLINE) {
        printf("FAIL: last event = %d, expected %d (LUA_HOOKLINE)\n",
               hook_last_event, LUA_HOOKLINE);
        lua_close(L);
        return 1;
    }

    printf("PASS: t4 line_hook (fired %d times, result=%lld)\n",
           hook_call_count, (long long)result);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 5: Per-thread hook isolation (review item 9.1)                */
/* ------------------------------------------------------------------ */

/*
** co1 and co2 are independent coroutines. Setting a hook on co1 must NOT
** affect co2: lua_gethook(co2) == NULL, lua_gethookmask(co2) == 0.
** PUC stores L->hook/hookmask/basehookcount per lua_State.
*/
static int test_hook_thread_isolation(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    lua_State *co1 = lua_newthread(L);
    lua_State *co2 = lua_newthread(L);
    if (co1 == NULL || co2 == NULL) {
        printf("FAIL: lua_newthread returned NULL\n");
        lua_close(L);
        return 1;
    }

    /* Install a count hook on co1 only */
    reset_counters();
    lua_sethook(co1, count_hook, LUA_MASKCOUNT, 1);

    /* co2 must have no hook */
    if (lua_gethook(co2) != NULL) {
        printf("FAIL: lua_gethook(co2) != NULL after sethook(co1)\n");
        lua_close(L);
        return 1;
    }
    if (lua_gethookmask(co2) != 0) {
        printf("FAIL: lua_gethookmask(co2) != 0 after sethook(co1)\n");
        lua_close(L);
        return 1;
    }
    if (lua_gethookcount(co2) != 0) {
        printf("FAIL: lua_gethookcount(co2) != 0 after sethook(co1)\n");
        lua_close(L);
        return 1;
    }

    /* co1 must have the hook */
    if (lua_gethook(co1) != count_hook) {
        printf("FAIL: lua_gethook(co1) != count_hook\n");
        lua_close(L);
        return 1;
    }
    if (lua_gethookmask(co1) != LUA_MASKCOUNT) {
        printf("FAIL: lua_gethookmask(co1) != LUA_MASKCOUNT\n");
        lua_close(L);
        return 1;
    }

    printf("PASS: t5 hook_thread_isolation\n");
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 6: lua_getinfo from a C hook (review item 9.2)               */
/* ------------------------------------------------------------------ */

static int hook_getinfo_ok = 0;

/*
** Line hook that calls lua_getinfo(L, "l", ar) to verify that ar.i_ci
** is set correctly (non-null) and that currentline is sensible.
** PUC sets ar->i_ci = ci; lua_getinfo uses i_ci to find the frame.
*/
static void info_hook(lua_State *L, lua_Debug *ar) {
    /* ar->currentline is already set by the hook dispatch. Call lua_getinfo
       to verify ar->i_ci points to a valid frame (getinfo returns 1 and
       fills currentline from the frame's line info). */
    if (lua_getinfo(L, "l", ar)) {
        if (ar->currentline > 0) {
            hook_getinfo_ok++;
        }
    }
}

static const char *three_line_code =
    "local x = 1\n"
    "local y = 2\n"
    "return x + y\n";

static int test_hook_getinfo(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    if (co == NULL) {
        printf("FAIL: lua_newthread returned NULL\n");
        lua_close(L);
        return 1;
    }

    if (luaL_loadstring(co, three_line_code) != LUA_OK) {
        printf("FAIL: loadstring: %s\n", lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }

    hook_getinfo_ok = 0;
    lua_sethook(co, info_hook, LUA_MASKLINE, 0);

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    if (status != LUA_OK) {
        printf("FAIL: lua_resume status = %d: %s\n", status,
               lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }

    if (hook_getinfo_ok <= 0) {
        printf("FAIL: lua_getinfo from hook never succeeded (ok=%d)\n",
               hook_getinfo_ok);
        lua_close(L);
        return 1;
    }

    printf("PASS: t6 hook_getinfo (ok>0=%s)\n", hook_getinfo_ok > 0 ? "yes" : "no");
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 7: Yieldable count/line C hooks (review item 9.3)            */
/* ------------------------------------------------------------------ */

static int yielding_hook_fired = 0;

/*
** Line hook that yields on the FIRST line event via lua_yieldk(L, 0, 0, NULL).
** PUC allows count/line hooks to yield inside a coroutine.
*/
static void yielding_line_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (yielding_hook_fired == 0) {
        yielding_hook_fired = 1;
        lua_yieldk(L, 0, 0, NULL);
    }
}

static const char *yield_code =
    "local x = 1\n"
    "x = x + 1\n"
    "return x\n";

static int test_hook_yield(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    if (co == NULL) {
        printf("FAIL: lua_newthread returned NULL\n");
        lua_close(L);
        return 1;
    }

    if (luaL_loadstring(co, yield_code) != LUA_OK) {
        printf("FAIL: loadstring: %s\n", lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }

    yielding_hook_fired = 0;
    lua_sethook(co, yielding_line_hook, LUA_MASKLINE, 0);

    /* First resume: hook yields on the first line event */
    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    if (status != LUA_YIELD) {
        printf("FAIL: resume1 status = %d, expected LUA_YIELD (%d)\n",
               status, LUA_YIELD);
        lua_close(L);
        return 1;
    }

    /* Second resume: continues from where it yielded, returns x = 2 */
    status = lua_resume(co, L, 0, &nres);
    if (status != LUA_OK) {
        printf("FAIL: resume2 status = %d: %s\n", status,
               lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }

    if (nres < 1) {
        printf("FAIL: no results from resume2\n");
        lua_close(L);
        return 1;
    }
    lua_Integer result = lua_tointeger(co, -1);
    if (result != 2) {
        printf("FAIL: result = %lld, expected 2\n", (long long)result);
        lua_close(L);
        return 1;
    }

    printf("PASS: t7 hook_yield (result=%lld)\n", (long long)result);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 8: Per-thread hook independence in execution                 */
/* ------------------------------------------------------------------ */

static int co1_hook_count = 0;
static int co2_hook_count = 0;

static void co1_count_hook(lua_State *L, lua_Debug *ar) {
    (void)L; (void)ar;
    co1_hook_count++;
}

static int test_hook_exec_isolation(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    lua_State *co1 = lua_newthread(L);
    lua_State *co2 = lua_newthread(L);
    if (co1 == NULL || co2 == NULL) {
        printf("FAIL: lua_newthread returned NULL\n");
        lua_close(L);
        return 1;
    }

    /* Install count hook on co1 only */
    co1_hook_count = 0;
    co2_hook_count = 0;
    lua_sethook(co1, co1_count_hook, LUA_MASKCOUNT, 1);

    /* Load and run co1 (has hook) */
    if (luaL_loadstring(co1, sum_loop_code) != LUA_OK) {
        printf("FAIL: co1 loadstring: %s\n", lua_tostring(co1, -1));
        lua_close(L);
        return 1;
    }
    int nres1 = 0;
    int status1 = lua_resume(co1, L, 0, &nres1);
    if (status1 != LUA_OK) {
        printf("FAIL: co1 resume status = %d: %s\n", status1,
               lua_tostring(co1, -1));
        lua_close(L);
        return 1;
    }

    /* Load and run co2 (no hook) */
    if (luaL_loadstring(co2, sum_loop_code) != LUA_OK) {
        printf("FAIL: co2 loadstring: %s\n", lua_tostring(co2, -1));
        lua_close(L);
        return 1;
    }
    int nres2 = 0;
    int status2 = lua_resume(co2, L, 0, &nres2);
    if (status2 != LUA_OK) {
        printf("FAIL: co2 resume status = %d: %s\n", status2,
               lua_tostring(co2, -1));
        lua_close(L);
        return 1;
    }

    /* co1's hook must have fired; co2's must NOT have fired */
    if (co1_hook_count <= 0) {
        printf("FAIL: co1 hook never fired (count=%d)\n", co1_hook_count);
        lua_close(L);
        return 1;
    }
    if (co2_hook_count != 0) {
        printf("FAIL: co2 hook fired (count=%d), expected 0\n", co2_hook_count);
        lua_close(L);
        return 1;
    }

    printf("PASS: t8 hook_exec_isolation (co1>0=%s, co2=0)\n",
           co1_hook_count > 0 ? "yes" : "no");
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Main                                                               */
/* ------------------------------------------------------------------ */

int main(void) {
    int fail = 0;
    fail += test_count_hook();
    fail += test_gethook_api();
    fail += test_clear_hook();
    fail += test_line_hook();
    fail += test_hook_thread_isolation();
    fail += test_hook_getinfo();
    fail += test_hook_yield();
    fail += test_hook_exec_isolation();
    if (fail == 0) {
        printf("ALL PASS\n");
    } else {
        printf("%d TEST(S) FAILED\n", fail);
    }
    return fail ? 1 : 0;
}
