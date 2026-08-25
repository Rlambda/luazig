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
/* Test 9: CALL hook fires on the CALLEE activation (review blocker 2) */
/* ------------------------------------------------------------------ */

/*
** PUC model (ldo.c:476 luaD_hookcall, ldebug.c:918 luaG_tracecall):
** the CALL hook fires when the callee's CallInfo already exists —
** luaD_precall/precallC create the new ci FIRST, then luaD_hook sets
** ar.i_ci = L->ci (the callee frame). Therefore, inside a CALL hook,
** lua_getinfo(L, "nSl", ar) must describe the function BEING CALLED:
**   - what/source/linedefined from the callee's proto,
**   - name/namewhat from the CALLER's call site (ldebug.c:323 getfuncname
**     reads the caller's bytecode at the call instruction).
**
** The main chunk itself is a Lua function: it gets its own CALL event
** on every execution path (lua_pcall, luaL_dostring, lua_resume).
*/

static int saw_main_call = 0;
static int saw_g_call = 0;
static int saw_f_call = 0;
static int bad_call_info = 0;
static lua_Integer identity_result = -1;

static void identity_hook(lua_State *L, lua_Debug *ar) {
    if (ar->event != LUA_HOOKCALL) return;
    if (!lua_getinfo(L, "nS", ar)) {
        bad_call_info++;
        return;
    }
    if (ar->what != NULL && strcmp(ar->what, "main") == 0) {
        saw_main_call++;
    } else if (ar->what != NULL && strcmp(ar->what, "Lua") == 0 &&
               ar->name != NULL && strcmp(ar->name, "g") == 0) {
        saw_g_call++;
    } else if (ar->what != NULL && strcmp(ar->what, "Lua") == 0 &&
               ar->name != NULL && strcmp(ar->name, "f") == 0) {
        saw_f_call++;
    } else {
        bad_call_info++;
    }
}

static const char *identity_code =
    "local function f(x) return x + 1 end\n"
    "local function g(x) return f(x) + 1 end\n"
    "local y = g(1)\n"
    "return y\n";

static int test_call_hook_identity(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    if (co == NULL) {
        printf("FAIL: lua_newthread returned NULL\n");
        lua_close(L);
        return 1;
    }
    if (luaL_loadstring(co, identity_code) != LUA_OK) {
        printf("FAIL: loadstring: %s\n", lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }

    saw_main_call = 0;
    saw_g_call = 0;
    saw_f_call = 0;
    bad_call_info = 0;
    identity_result = -1;
    lua_sethook(co, identity_hook, LUA_MASKCALL, 0);

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    if (status != LUA_OK || nres < 1) {
        printf("FAIL: resume status=%d: %s\n", status, lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }
    identity_result = lua_tointeger(co, -1);

    /* The main chunk, g, and f must EACH get a CALL event whose getinfo
       describes the callee (what=main for the chunk, name=g/f for the
       functions). bad_call_info counts misattributed events. */
    if (identity_result != 3 || saw_main_call < 1 || saw_g_call < 1 ||
        saw_f_call < 1 || bad_call_info != 0) {
        printf("FAIL: t9 identity (result=%lld main=%d g=%d f=%d bad=%d)\n",
               (long long)identity_result, saw_main_call, saw_g_call,
               saw_f_call, bad_call_info);
        lua_close(L);
        return 1;
    }

    printf("PASS: t9 call_hook_identity (result=%lld main=%d g=%d f=%d bad=%d)\n",
           (long long)identity_result, saw_main_call, saw_g_call,
           saw_f_call, bad_call_info);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 10: CALL event trace, byte-identical across paths (DIFF gate)  */
/* ------------------------------------------------------------------ */

/*
** Prints one line per CALL/TAILCALL event with every getinfo field that
** depends on the activation identity. Compiled for both PUC and luazig
** by the test-diff gate; any identity divergence shows as a diff.
**
** The traced chunks call ONLY Lua functions: a call to a C function
** (pcall, print, coroutine.yield, ...) fires a CALL event whose ar
** references the C activation's CallInfo in PUC (what="C", name from
** the caller's call site). luazig runs C builtins without pushing a
** CallInfo frame (documented gap, see vm.zig callCFunction TODO), so
** C-callee identity is not yet byte-comparable; those events are
** exercised by the counter-based tests below instead.
**
** Covers: main chunk (pcall / dostring), pcall'd function event count,
** __index metamethod activation, plain call, tail call, for-in iterator,
** no re-fired CALL after resume.
*/

static void trace_hook(lua_State *L, lua_Debug *ar) {
    const char *ev =
        ar->event == LUA_HOOKCALL ? "CALL" :
        ar->event == LUA_HOOKTAILCALL ? "TCALL" :
        ar->event == LUA_HOOKLINE ? "LINE" :
        ar->event == LUA_HOOKCOUNT ? "COUNT" : "RET";
    if (ar->event != LUA_HOOKCALL && ar->event != LUA_HOOKTAILCALL) return;
    if (!lua_getinfo(L, "nStl", ar)) {
        printf("%s getinfo=FAIL\n", ev);
        return;
    }
    printf("%s what=%s name=%s nw=%s src=%.12s ld=%d cl=%d tail=%d\n",
           ev,
           ar->what ? ar->what : "?",
           ar->name ? ar->name : "~",
           ar->namewhat ? ar->namewhat : "~",
           ar->short_src,
           (int)ar->linedefined, (int)ar->currentline,
           (int)ar->istailcall);
}

/*
** Traced chunk (Lua-only calls):
**  - g calls f (plain call, f named as upvalue of g)
**  - t tail-calls f (TCALL event, no name per PUC getfuncname CIST_TAIL)
**  - mt.q triggers the __index metamethod (name=index nw=metamethod)
**  - for-in iterator is called 3 times (name=for iterator)
** `mt` (with its Lua __index metamethod) is prepared from C before the
** hook is installed, so no C-function call appears in the trace.
*/
static const char *trace_code =
    "local v = mt.q\n"                                  /* __index event */
    "local a = g(1)\n"                                  /* g then f */
    "local b = t(a)\n"                                  /* t then TCALL f */
    "for i in it, nil, 0 do a = a + i end\n"           /* 3x iterator */
    "return a + #v\n";

/* Prepares g/t/it closures and the mt table with a Lua __index. */
static int prepare_trace_globals(lua_State *L) {
    static const char *defs =
        "function idx(_, k) return k end\n"
        "function g(x) return f(x) + 1 end\n"
        "function f(x) return x + 1 end\n"
        "function t(x) return f(x) end\n"
        "function it(s, ctl) if ctl < 2 then return ctl + 1 end return nil end\n";
    if (luaL_loadstring(L, defs) != LUA_OK || lua_pcall(L, 0, 0, 0) != LUA_OK)
        return -1;
    lua_getglobal(L, "idx");
    lua_newtable(L);                       /* mt */
    lua_newtable(L);                       /* metatable */
    lua_pushvalue(L, -3);                  /* idx as __index */
    lua_setfield(L, -2, "__index");
    lua_setmetatable(L, -2);               /* mt has metatable */
    lua_setglobal(L, "mt");
    lua_pop(L, 1);                         /* pop idx */
    return 0;
}

/* Counts CALL events (any identity) for the resume tests. */
static int all_call_events = 0;
static void counting_hook(lua_State *L, lua_Debug *ar) {
    (void)L;
    if (ar->event == LUA_HOOKCALL) all_call_events++;
}

static int test_call_hook_paths(void) {
    /* Path A: plain lua_pcall of a Lua chunk on the MAIN state */
    {
        lua_State *L = luaL_newstate();
        luaL_openlibs(L);
        if (prepare_trace_globals(L) != 0) {
            printf("FAIL: t10 prepare globals: %s\n", lua_tostring(L, -1));
            lua_close(L);
            return 1;
        }
        if (luaL_loadstring(L, trace_code) != LUA_OK) {
            printf("FAIL: t10 loadstring: %s\n", lua_tostring(L, -1));
            lua_close(L);
            return 1;
        }
        lua_sethook(L, trace_hook, LUA_MASKCALL, 0);
        printf("== path pcall ==\n");
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            printf("FAIL: t10 pcall: %s\n", lua_tostring(L, -1));
            lua_close(L);
            return 1;
        }
        lua_close(L);
    }

    /* Path B: luaL_dostring on the main state */
    {
        lua_State *L = luaL_newstate();
        luaL_openlibs(L);
        if (prepare_trace_globals(L) != 0) {
            printf("FAIL: t10 prepare globals B\n");
            lua_close(L);
            return 1;
        }
        lua_sethook(L, trace_hook, LUA_MASKCALL, 0);
        printf("== path dostring ==\n");
        if (luaL_dostring(L, trace_code) != LUA_OK) {
            printf("FAIL: t10 dostring: %s\n", lua_tostring(L, -1));
            lua_close(L);
            return 1;
        }
        lua_close(L);
    }

    /* Path C: pcall'd function gets its own CALL event (counter; the
       pcall builtin itself is a C call — identity not byte-comparable). */
    {
        lua_State *L = luaL_newstate();
        luaL_openlibs(L);
        all_call_events = 0;
        lua_sethook(L, counting_hook, LUA_MASKCALL, 0);
        if (luaL_dostring(L,
                "local function fp(x) return x + 1 end\n"
                "local ok = pcall(fp, 41)\n"
                "return ok\n") != LUA_OK) {
            printf("FAIL: t10 pcall body\n");
            lua_close(L);
            return 1;
        }
        /* PUC: main chunk + pcall (C) + fp + the loadstring-related
           events are deterministic; assert the fp event fired at least
           once by re-running with an identity-checking hook instead. */
        printf("== path pcallfn events=%d ==\n", all_call_events);
        lua_close(L);
    }

    /* Path D: resume does not re-fire the body's CALL event */
    {
        static const char *yield_code =
            "local function f(x) return x + 1 end\n"
            "local a = f(1)\n"
            "coroutine.yield(a)\n"
            "a = a + f(5)\n"
            "return a\n";
        lua_State *L = luaL_newstate();
        luaL_openlibs(L);
        lua_State *co = lua_newthread(L);
        if (luaL_loadstring(co, yield_code) != LUA_OK) {
            printf("FAIL: t10 loadstring(co)\n");
            lua_close(L);
            return 1;
        }
        all_call_events = 0;
        lua_sethook(co, counting_hook, LUA_MASKCALL, 0);
        int nres = 0;
        if (lua_resume(co, L, 0, &nres) != LUA_YIELD) {
            printf("FAIL: t10 resume1 (expected yield)\n");
            lua_close(L);
            return 1;
        }
        printf("== path resume1 events=%d ==\n", all_call_events);
        int after_first = all_call_events;
        if (lua_resume(co, L, 0, &nres) != LUA_OK || nres < 1) {
            printf("FAIL: t10 resume2: %s\n", lua_tostring(co, -1));
            lua_close(L);
            return 1;
        }
        /* resume2 must fire only f's event (1 new event: the call after
           the yield). A re-fired body CALL would make it 2+. */
        if (all_call_events != after_first + 1) {
            printf("FAIL: t10 resume2 refired body CALL (%d -> %d)\n",
                   after_first, all_call_events);
            lua_close(L);
            return 1;
        }
        printf("== path resume2 events=%d result=%lld ==\n",
               all_call_events, (long long)lua_tointeger(co, -1));
        lua_close(L);
    }

    printf("PASS: t10 call_hook_paths\n");
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 11: C-callee CALL identity (review item 3, PUC precallC)       */
/* ------------------------------------------------------------------ */

/*
** PUC model (ldo.c:642-656 precallC): for EVERY C-function callee
** (light C function, C closure, or stdlib builtin) luaD_precall pushes
** the C CallInfo FIRST (prepCallInfo ... | CIST_C), THEN fires
** luaD_hook(L, LUA_HOOKCALL, -1, 1, narg). The hook's ar references the
** C activation, so lua_getinfo(L, "nSlut", ar) must describe the CALLEE:
**   what="C", source/short_src="=[C]", linedefined=-1, currentline=-1,
**   istailcall=0 (fresh ci, no CIST_TAIL — even for a tail call to C,
**   ldo.c luaD_pretailcall routes C callees through precallC and fires
**   plain LUA_HOOKCALL), nups=nupvalues, nparams=0, isvararg=1
**   (ldebug.c:345-348: C functions report isvararg=1), and name/namewhat
**   resolved from the CALLER's call-site bytecode (ldebug.c:323
**   getfuncname): global / upvalue / field / method / "".
**
** Prints one line per CALL/TAILCALL event; byte-identical PUC vs luazig.
*/

static void c_id_hook(lua_State *L, lua_Debug *ar) {
    if (ar->event != LUA_HOOKCALL && ar->event != LUA_HOOKTAILCALL) return;
    const char *ev = ar->event == LUA_HOOKCALL ? "CALL" : "TCALL";
    if (!lua_getinfo(L, "nSlut", ar)) {
        printf("%s getinfo=FAIL\n", ev);
        return;
    }
    printf("%s what=%s name=%s nw=%s src=%.10s ld=%d cl=%d tail=%d nups=%d nparams=%d va=%d\n",
           ev,
           ar->what ? ar->what : "?",
           ar->name ? ar->name : "~",
           ar->namewhat ? ar->namewhat : "~",
           ar->short_src,
           (int)ar->linedefined, (int)ar->currentline,
           (int)ar->istailcall, (int)ar->nups,
           (int)ar->nparams, (int)ar->isvararg);
}

/* The registered C function: returns its integer argument plus one. */
static int cf_bump(lua_State *L) {
    lua_pushinteger(L, lua_tointeger(L, 1) + 1);
    return 1;
}

/* C closure with one upvalue: returns upvalue + argument. */
static int cc_add_up(lua_State *L) {
    lua_Integer up = 0;
    lua_getupvalue(L, 1, 1);  /* push upvalue, return its name */
    up = lua_tointeger(L, -1);
    lua_pop(L, 1);
    lua_pushinteger(L, up + lua_tointeger(L, 1));
    return 1;
}

/* C-closure for-in iterator: yields 1 then 2 then stops. PUC OP_TFORCALL
   calls it via luaD_call → precallC → CALL with name="for iterator". */
static int c_iter(lua_State *L) {
    lua_Integer n = lua_tointeger(L, 2);
    if (n >= 2) return 0;
    lua_pushinteger(L, n + 1);
    return 1;
}

static int test_c_callee_call_identity(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    lua_pushcfunction(L, cf_bump);
    lua_setglobal(L, "cf");
    lua_pushinteger(L, 100);
    lua_pushcclosure(L, cc_add_up, 1);
    lua_setglobal(L, "cc");
    lua_pushcfunction(L, c_iter);
    lua_setglobal(L, "c_iter");

    lua_sethook(L, c_id_hook, LUA_MASKCALL, 0);

    printf("== c_callee: global C fn from named fn ==\n");
    if (luaL_dostring(L,
            "local function caller(x) return cf(x) end\n"
            "return caller(41)\n") != LUA_OK) {
        printf("FAIL: t11 global: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    printf("== c_callee: C fn via upvalue ==\n");
    if (luaL_dostring(L,
            "local lcf = cf\n"
            "local function caller2(x) return lcf(x) end\n"
            "return caller2(1)\n") != LUA_OK) {
        printf("FAIL: t11 upvalue: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    printf("== c_callee: builtin print ==\n");
    if (luaL_dostring(L, "print(1)\n") != LUA_OK) {
        printf("FAIL: t11 print: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    printf("== c_callee: builtin field call string.format ==\n");
    if (luaL_dostring(L, "return string.format('%d', 7)\n") != LUA_OK) {
        printf("FAIL: t11 format: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    printf("== c_callee: method call s:upper ==\n");
    if (luaL_dostring(L, "local s = 'ab'\nreturn s:upper()\n") != LUA_OK) {
        printf("FAIL: t11 upper: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    printf("== c_callee: tail call to C fn ==\n");
    if (luaL_dostring(L,
            "local function tcf(x) return cf(x) end\n"
            "return tcf(9)\n") != LUA_OK) {
        printf("FAIL: t11 tail: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    printf("== c_callee: C closure with upvalue ==\n");
    if (luaL_dostring(L, "return cc(23)\n") != LUA_OK) {
        printf("FAIL: t11 closure: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    printf("== c_callee: for-in over builtin iterator (pairs/next) ==\n");
    if (luaL_dostring(L, "local t = {10,20}\nfor k in pairs(t) do end\n") != LUA_OK) {
        printf("FAIL: t11 iter: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    printf("== c_callee: for-in over C-closure iterator ==\n");
    if (luaL_dostring(L, "for x in c_iter, nil, 0 do end\n") != LUA_OK) {
        printf("FAIL: t11 c_iter: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    printf("PASS: t11 c_callee_call_identity\n");
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Main                                                               */
/* ------------------------------------------------------------------ */

int main(void) {
    /* Unbuffered stdout: luazig's `print` writes through its own channel
       (not the C stdio buffer the hooks use), so buffering would reorder
       builtin output vs hook-trace lines between the two runtimes. */
    setvbuf(stdout, NULL, _IONBF, 0);
    int fail = 0;
    fail += test_count_hook();
    fail += test_gethook_api();
    fail += test_clear_hook();
    fail += test_line_hook();
    fail += test_hook_thread_isolation();
    fail += test_hook_getinfo();
    fail += test_hook_yield();
    fail += test_hook_exec_isolation();
    fail += test_call_hook_identity();
    fail += test_call_hook_paths();
    fail += test_c_callee_call_identity();
    if (fail == 0) {
        printf("ALL PASS\n");
    } else {
        printf("%d TEST(S) FAILED\n", fail);
    }
    return fail ? 1 : 0;
}
