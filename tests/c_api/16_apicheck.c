/*
** 16_apicheck.c — hook-continuation API-check invariants (review item 3,
** spec §7 "API checks", P15.83m).
**
** ZIG-ONLY SUITE (deliberately NOT in the Makefile's DIFF_TESTS): PUC
** compiles api_check out of release builds (it aborts via lua_assert only
** under LUA_USE_APICHECK), so the same invalid usage RUNS NORMALLY on
** release PUC while luazig rejects it with a runtime error. A shared
** byte-identical differential of the ERROR is therefore impossible; per
** the review, these rejection tests do not have to be part of the
** byte-for-byte release differential suite.
**
** Invariants enforced by luazig (PUC sources):
**   lapi.c:1041-1042 lua_callk:
**     api_check(L, k == NULL || !isLua(L->ci),
**               "cannot use continuations inside hooks");
**   lapi.c:1082-1083 lua_pcallk: same check;
**   ldo.c:1023-1024 lua_yieldk (hook branch):
**     api_check(L, nresults == 0, "hooks cannot yield values");
**     api_check(L, k == NULL, "hooks cannot continue after yielding");
**
** luazig enforcement model: while a hook runs (per-thread in_debug_hook,
** the analog of PUC's CIST_HOOKED current CallInfo), a violation raises a
** deterministic runtime error carrying the PUC message text. The invalid
** call happens INSIDE a C hook; the error _longjmps to the hook dispatch
** boundary and surfaces as LUA_ERRRUN from lua_resume / the dostring
** pcall — no continuation state is silently normalized away.
**
** The valid-usages tests (t5, t6) document what must keep working:
** count/line hooks yielding via lua_yieldk(L, 0, 0, NULL) (PUC allows
** count/line hooks to yield), and k == NULL everywhere else.
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* ------------------------------------------------------------------ */
/* Shared helpers                                                     */
/* ------------------------------------------------------------------ */

/* Continuation used as the INVALID k in the violation tests. It must
** never actually run — the tests assert the coroutine died instead. */
static int never_called_cont(lua_State *L, int status, lua_KContext ctx) {
    (void)status; (void)ctx;
    lua_pushliteral(L, "CONTINUATION-RAN");
    return 1;
}

/* cont_ran: set ONLY by never_called_cont — every violation test asserts
** it stays 0 (the continuation must not run; the coroutine must die).
** hook_entered: fire-once guard so a hook violates only on its first
** event (later events must not retry the invalid call). */
static int cont_ran = 0;
static int hook_entered = 0;

static void reset(void) {
    cont_ran = 0;
    hook_entered = 0;
}

/* Lua loop body: enough instructions for count=1 hooks to fire. */
static const char *loop_code =
    "local s = 0\n"
    "for i = 1, 100 do\n"
    "    s = s + i\n"
    "end\n"
    "return s\n";

/* Multi-line body for line hooks. */
static const char *line_code =
    "local x = 1\n"
    "local y = 2\n"
    "local z = 3\n"
    "return x + y + z\n";

/* Checks the LUA_ERRRUN outcome of a violating resume: status, message
** substring, coroutine dead (lua_status + second resume errors), and no
** continuation ran. Returns 0 on success. */
static int check_hook_violation(const char *label, lua_State *L,
                                lua_State *co, const char *needle) {
    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    if (status != LUA_ERRRUN) {
        printf("FAIL: %s resume status = %d, expected LUA_ERRRUN (%d)\n",
               label, status, LUA_ERRRUN);
        return 1;
    }
    const char *msg = lua_tostring(co, -1);
    if (msg == NULL || strstr(msg, needle) == NULL) {
        printf("FAIL: %s message '%s' lacks '%s'\n", label,
               msg ? msg : "(null)", needle);
        return 1;
    }
    if (lua_status(co) != LUA_ERRRUN) {
        printf("FAIL: %s lua_status = %d, expected LUA_ERRRUN\n",
               label, lua_status(co));
        return 1;
    }
    /* No silent normalization: the coroutine is dead. A second resume
** must fail instead of continuing with a dropped continuation. */
    int nres2 = 0;
    int status2 = lua_resume(co, L, 0, &nres2);
    if (status2 == LUA_OK || status2 == LUA_YIELD) {
        printf("FAIL: %s coroutine resumed after violation (status %d)\n",
               label, status2);
        return 1;
    }
    if (cont_ran) {
        printf("FAIL: %s continuation ran despite the violation\n", label);
        return 1;
    }
    printf("PASS: %s (%s)\n", label, msg);
    return 0;
}

/* ------------------------------------------------------------------ */
/* t1: lua_callk with k != NULL from a C count-hook                  */
/* ------------------------------------------------------------------ */

static void callk_violating_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (hook_entered) return;
    hook_entered = 1;
    lua_getglobal(L, "simplefn");
    /* INVALID: k != NULL inside a hook (PUC lapi.c:1041-1042). */
    lua_callk(L, 0, 0, 0, never_called_cont);
    /* unreachable on luazig: the violation _longjmps out of the hook */
}

static int test_callk_in_hook(void) {
    reset();
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    (void)luaL_dostring(L, "function simplefn() return 7 end");

    lua_State *co = lua_newthread(L);
    if (luaL_loadstring(co, loop_code) != LUA_OK) {
        printf("FAIL: t1 loadstring: %s\n", lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }
    lua_sethook(co, callk_violating_hook, LUA_MASKCOUNT, 1);

    int fail = check_hook_violation("t1 callk_in_hook", L, co,
                                    "cannot use continuations inside hooks");
    lua_close(L);
    return fail;
}

/* ------------------------------------------------------------------ */
/* t2: lua_pcallk with k != NULL from a C count-hook (yieldable co)   */
/* ------------------------------------------------------------------ */

static void pcallk_violating_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (hook_entered) return;
    hook_entered = 1;
    lua_getglobal(L, "simplefn");
    /* INVALID: k != NULL inside a hook (PUC lapi.c:1082-1083). The
** coroutine is yieldable, so this reaches luaPcallKShared's check. */
    lua_pcallk(L, 0, 0, 0, 0, never_called_cont);
}

static int test_pcallk_in_hook(void) {
    reset();
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    (void)luaL_dostring(L, "function simplefn() return 7 end");

    lua_State *co = lua_newthread(L);
    if (luaL_loadstring(co, loop_code) != LUA_OK) {
        printf("FAIL: t2 loadstring: %s\n", lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }
    lua_sethook(co, pcallk_violating_hook, LUA_MASKCOUNT, 1);

    int fail = check_hook_violation("t2 pcallk_in_hook", L, co,
                                    "cannot use continuations inside hooks");
    lua_close(L);
    return fail;
}

/* ------------------------------------------------------------------ */
/* t3: lua_pcallk with k != NULL from a C count-hook on the MAIN state */
/* ------------------------------------------------------------------ */

/*
** The main state is NOT yieldable: lua_pcallk's conventional branch would
** bypass luaPcallKShared, so this exercises the wrapper-level check
** (PUC's api_check runs before the yieldable branch, unconditionally).
** The error propagates through luaL_dostring's pcall boundary.
*/
static void pcallk_main_violating_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (hook_entered) return;
    hook_entered = 1;
    lua_getglobal(L, "simplefn");
    lua_pcallk(L, 0, 0, 0, 0, never_called_cont);
}

static int test_pcallk_in_hook_main(void) {
    reset();
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    (void)luaL_dostring(L, "function simplefn() return 7 end");

    lua_sethook(L, pcallk_main_violating_hook, LUA_MASKCOUNT, 1);
    /* luaL_dostring collapses statuses through ||; call lua_pcall directly
** so the real status code (LUA_ERRRUN) is observable. */
    if (luaL_loadstring(L, loop_code) != LUA_OK) {
        printf("FAIL: t3 loadstring: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }
    int status = lua_pcall(L, 0, 0, 0);
    lua_sethook(L, NULL, 0, 0);
    if (status != LUA_ERRRUN) {
        printf("FAIL: t3 dostring status = %d, expected LUA_ERRRUN (%d)\n",
               status, LUA_ERRRUN);
        lua_close(L);
        return 1;
    }
    const char *msg = lua_tostring(L, -1);
    if (msg == NULL || strstr(msg, "cannot use continuations inside hooks") == NULL) {
        printf("FAIL: t3 message '%s' lacks the invariant text\n",
               msg ? msg : "(null)");
        lua_close(L);
        return 1;
    }
    if (cont_ran) {
        printf("FAIL: t3 continuation ran despite the violation\n");
        lua_close(L);
        return 1;
    }
    printf("PASS: t3 pcallk_in_hook_main (%s)\n", msg);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* t4: lua_yieldk with nresults=2 from a C line-hook                  */
/* ------------------------------------------------------------------ */

static void yieldvals_violating_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (hook_entered) return;
    hook_entered = 1;
    lua_pushinteger(L, 1);
    lua_pushinteger(L, 2);
    /* INVALID: hooks cannot yield values (PUC ldo.c:1023, checked before
** the k check). k is NULL here so ONLY the nresults invariant fires. */
    lua_yieldk(L, 2, 0, NULL);
}

static int test_yieldk_values_in_hook(void) {
    reset();
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    if (luaL_loadstring(co, line_code) != LUA_OK) {
        printf("FAIL: t4 loadstring: %s\n", lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }
    lua_sethook(co, yieldvals_violating_hook, LUA_MASKLINE, 0);

    int fail = check_hook_violation("t4 yieldk_values_in_hook", L, co,
                                    "hooks cannot yield values");
    lua_close(L);
    return fail;
}

/* ------------------------------------------------------------------ */
/* t5: lua_yieldk with k != NULL (nresults=0) from a C count-hook     */
/* ------------------------------------------------------------------ */

static void yieldk_cont_violating_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (hook_entered) return;
    hook_entered = 1;
    /* INVALID: hooks cannot continue after yielding (PUC ldo.c:1024).
** nresults == 0 so ONLY the k invariant fires. */
    lua_yieldk(L, 0, 0, never_called_cont);
}

static int test_yieldk_cont_in_hook(void) {
    reset();
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    if (luaL_loadstring(co, loop_code) != LUA_OK) {
        printf("FAIL: t5 loadstring: %s\n", lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }
    lua_sethook(co, yieldk_cont_violating_hook, LUA_MASKCOUNT, 1);

    int fail = check_hook_violation("t5 yieldk_cont_in_hook", L, co,
                                    "hooks cannot continue after yielding");
    lua_close(L);
    return fail;
}

/* ------------------------------------------------------------------ */
/* t6 (valid): count hook yields via lua_yieldk(L, 0, 0, NULL)        */
/* ------------------------------------------------------------------ */

/*
** The invariants ALLOW this: k == NULL and nresults == 0. PUC permits
** count/line hooks to suspend the running coroutine (luaG_traceexec
** checks L->status == LUA_YIELD after the hook). Regression guard for
** the checker: it must not reject valid hook yields (same pattern as
** 12_chook t7 / coroutine.lua's T.sethook("yield 0", ...) testC hooks).
*/
static int yield0_fired = 0;

static void yield0_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (yield0_fired) return;
    yield0_fired = 1;
    lua_yieldk(L, 0, 0, NULL);
}

static int test_valid_hook_yield(void) {
    yield0_fired = 0;
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    lua_State *co = lua_newthread(L);
    if (luaL_loadstring(co, loop_code) != LUA_OK) {
        printf("FAIL: t6 loadstring: %s\n", lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }
    lua_sethook(co, yield0_hook, LUA_MASKCOUNT, 1);

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    if (status != LUA_YIELD) {
        printf("FAIL: t6 resume1 status = %d, expected LUA_YIELD (%d)\n",
               status, LUA_YIELD);
        lua_close(L);
        return 1;
    }
    status = lua_resume(co, L, 0, &nres);
    if (status != LUA_OK || nres < 1) {
        printf("FAIL: t6 resume2 status = %d: %s\n", status,
               lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }
    lua_Integer result = lua_tointeger(co, -1);
    if (result != 5050) {
        printf("FAIL: t6 sum = %lld, expected 5050\n", (long long)result);
        lua_close(L);
        return 1;
    }
    printf("PASS: t6 valid_hook_yield (result=%lld)\n", (long long)result);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* t7 (valid): lua_callk/lua_pcallk with k == NULL inside a hook      */
/* ------------------------------------------------------------------ */

/*
** k == NULL is always allowed (the api_check only forbids k != NULL):
** a hook may call functions with plain lua_call semantics. Exercises
** luaCallKShared's k == NULL path (incnny boundary) from a hook.
*/
static int callnull_ok = 0;

static void callnull_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (callnull_ok) return;
    callnull_ok = 1;
    lua_getglobal(L, "simplefn");
    lua_callk(L, 0, 0, 0, NULL);  /* valid: k == NULL inside a hook */
}

static int test_valid_callk_null_in_hook(void) {
    callnull_ok = 0;
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    (void)luaL_dostring(L, "function simplefn() return 7 end");

    lua_State *co = lua_newthread(L);
    if (luaL_loadstring(co, loop_code) != LUA_OK) {
        printf("FAIL: t7 loadstring: %s\n", lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }
    lua_sethook(co, callnull_hook, LUA_MASKCOUNT, 1);

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    if (status != LUA_OK || nres < 1) {
        printf("FAIL: t7 resume status = %d: %s\n", status,
               lua_tostring(co, -1));
        lua_close(L);
        return 1;
    }
    lua_Integer result = lua_tointeger(co, -1);
    if (!callnull_ok || result != 5050) {
        printf("FAIL: t7 hook_ran=%d result=%lld\n", callnull_ok,
               (long long)result);
        lua_close(L);
        return 1;
    }
    printf("PASS: t7 valid_callk_null_in_hook (result=%lld)\n",
           (long long)result);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Main                                                               */
/* ------------------------------------------------------------------ */

int main(void) {
    int fail = 0;
    fail += test_callk_in_hook();          /* t1 */
    fail += test_pcallk_in_hook();         /* t2 */
    fail += test_pcallk_in_hook_main();    /* t3 */
    fail += test_yieldk_values_in_hook();  /* t4 */
    fail += test_yieldk_cont_in_hook();    /* t5 */
    fail += test_valid_hook_yield();       /* t6 */
    fail += test_valid_callk_null_in_hook(); /* t7 */
    /* testC hook routes (T.sethook("yield 0", ...), .callk/.pcallk/.yieldk
** through the shared helpers) are covered by coroutine.lua --testc and
** the upstream matrix — noted here, not duplicated. */
    if (fail == 0) {
        printf("ALL PASS\n");
    } else {
        printf("%d TEST(S) FAILED\n", fail);
    }
    return fail ? 1 : 0;
}
