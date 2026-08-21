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
/* Main                                                               */
/* ------------------------------------------------------------------ */

int main(void) {
    int fail = 0;
    fail += test_count_hook();
    fail += test_gethook_api();
    fail += test_clear_hook();
    fail += test_line_hook();
    if (fail == 0) {
        printf("ALL PASS\n");
    } else {
        printf("%d TEST(S) FAILED\n", fail);
    }
    return fail ? 1 : 0;
}
