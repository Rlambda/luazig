/*
** 13_p15_completion.c — C API test for ERRFUNC_NONE sentinel + LUA_ERRERR.
**
** Tests two coupled fixes (P15.83b):
**   1. ERRFUNC_NONE sentinel: errfunc at bc_stack[0] is no longer silently
**      disabled (was: 0 meant "no handler", but index 0 is valid on a fresh
**      main thread).
**   2. Real LUA_ERRERR (status 5): when the message handler itself errors,
**      pcallk returns LUA_ERRERR (not LUA_ERRRUN) with "error in error
**      handling" on the stack.
**
** PUC model (ldo.c luaD_rawrunprotected, ldebug.c luaG_errormsg):
**   - errfunc succeeds: pcallk → LUA_ERRRUN (2), stack msg = handler result.
**   - errfunc errors:    pcallk → LUA_ERRERR (5), stack msg = "error in error handling".
**   - lua_status after errerr pcall: LUA_OK (0) — pcall absorbed the error.
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* ------------------------------------------------------------------ */
/* C helper functions used as errfunc and error-throwing callees       */
/* ------------------------------------------------------------------ */

/*
** errfunc that succeeds: pushes "handled: " .. tostring(msg).
** Mirrors PUC's typical message handler pattern.
*/
static int eh_handled(lua_State *L) {
    const char *msg = lua_tostring(L, 1);
    lua_pushfstring(L, "handled: %s", msg ? msg : "(null)");
    return 1;
}

/*
** errfunc that errors: throws "handler-boom".
** This triggers LUA_ERRERR in PUC.
*/
static int eh_boom(lua_State *L) {
    (void)L;
    return luaL_error(L, "handler-boom");
}

/*
** Callee that errors with "boom".
*/
static int cfn_boom(lua_State *L) {
    (void)L;
    return luaL_error(L, "boom");
}

/* ------------------------------------------------------------------ */
/* Test 1: main-thread pcallk with errfunc — handler succeeds         */
/* ------------------------------------------------------------------ */

/*
** Push cfn_boom, call lua_pcallk(L, 0, 0, 1, 0, NULL) with errfunc at
** stack index 1 (eh_handled). Expect LUA_ERRRUN (2) and stack top ==
** "handled: boom".
**
** This tests the ERRFUNC_NONE sentinel fix: on a fresh main thread,
** bc_stack starts at 0, so eh_handled is pushed at index 0. With the
** old 0-sentinel, the handler was silently disabled and the raw error
** "boom" appeared instead of "handled: boom".
*/
static int test_mainthread_pcallk_errfunc(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: newstate\n"); return 1; }
    luaL_openlibs(L);

    /* Push errfunc at stack index 1 (will be bc_stack[0]). */
    lua_pushcfunction(L, eh_handled);
    /* Push the callee. */
    lua_pushcfunction(L, cfn_boom);

    int status = lua_pcallk(L, 0, 0, 1, 0, NULL);

    int pass = 1;
    if (status != LUA_ERRRUN) {
        printf("  FAIL: expected LUA_ERRRUN (%d), got %d\n", LUA_ERRRUN, status);
        pass = 0;
    }
    const char *msg = lua_tostring(L, -1);
    if (!msg || strcmp(msg, "handled: boom") != 0) {
        printf("  FAIL: expected \"handled: boom\", got \"%s\"\n", msg ? msg : "(null)");
        pass = 0;
    }
    if (pass) printf("  PASS: status=%d, msg=\"%s\"\n", status, msg ? msg : "(null)");

    lua_close(L);
    return pass ? 0 : 1;
}

/* ------------------------------------------------------------------ */
/* Test 2: errfunc errors → LUA_ERRERR status                         */
/* ------------------------------------------------------------------ */

/*
** Push eh_boom (errfunc that errors) at index 1, push cfn_boom, call
** lua_pcallk(L, 0, 0, 1, 0, NULL). Expect LUA_ERRERR (5).
*/
static int test_errerr_status(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: newstate\n"); return 1; }
    luaL_openlibs(L);

    lua_pushcfunction(L, eh_boom);
    lua_pushcfunction(L, cfn_boom);

    int status = lua_pcallk(L, 0, 0, 1, 0, NULL);

    int pass = 1;
    if (status != LUA_ERRERR) {
        printf("  FAIL: expected LUA_ERRERR (%d), got %d\n", LUA_ERRERR, status);
        pass = 0;
    }
    if (pass) printf("  PASS: status=%d (LUA_ERRERR)\n", status);

    lua_close(L);
    return pass ? 0 : 1;
}

/* ------------------------------------------------------------------ */
/* Test 3: errfunc errors → "error in error handling" message         */
/* ------------------------------------------------------------------ */

/*
** Same as test 2, but also verify the error message on the stack is
** "error in error handling" (PUC luaG_errormsg behavior).
*/
static int test_errerr_message(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: newstate\n"); return 1; }
    luaL_openlibs(L);

    lua_pushcfunction(L, eh_boom);
    lua_pushcfunction(L, cfn_boom);

    int status = lua_pcallk(L, 0, 0, 1, 0, NULL);

    int pass = 1;
    if (status != LUA_ERRERR) {
        printf("  FAIL: expected LUA_ERRERR (%d), got %d\n", LUA_ERRERR, status);
        pass = 0;
    }
    const char *msg = lua_tostring(L, -1);
    if (!msg || strcmp(msg, "error in error handling") != 0) {
        printf("  FAIL: expected \"error in error handling\", got \"%s\"\n", msg ? msg : "(null)");
        pass = 0;
    }
    if (pass) printf("  PASS: status=%d, msg=\"%s\"\n", status, msg ? msg : "(null)");

    lua_close(L);
    return pass ? 0 : 1;
}

/* ------------------------------------------------------------------ */
/* Test 4: lua_status == LUA_OK after errerr pcall                    */
/* ------------------------------------------------------------------ */

/*
** After an errerr pcall completes (error absorbed by pcall), lua_status
** should return LUA_OK (0) — the error was caught by pcall.
*/
static int test_status_after_errerr(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: newstate\n"); return 1; }
    luaL_openlibs(L);

    lua_pushcfunction(L, eh_boom);
    lua_pushcfunction(L, cfn_boom);

    (void)lua_pcallk(L, 0, 0, 1, 0, NULL);

    int st = lua_status(L);
    int pass = 1;
    if (st != LUA_OK) {
        printf("  FAIL: expected LUA_OK (%d), got %d\n", LUA_OK, st);
        pass = 0;
    }
    if (pass) printf("  PASS: lua_status=%d (LUA_OK)\n", st);

    lua_close(L);
    return pass ? 0 : 1;
}

/* ------------------------------------------------------------------ */
/* Main                                                               */
/* ------------------------------------------------------------------ */

int main(void) {
    int fail = 0;
    printf("=== 13_p15_completion ===\n");

    printf("test_mainthread_pcallk_errfunc:\n");
    fail += test_mainthread_pcallk_errfunc();

    printf("test_errerr_status:\n");
    fail += test_errerr_status();

    printf("test_errerr_message:\n");
    fail += test_errerr_message();

    printf("test_status_after_errerr:\n");
    fail += test_status_after_errerr();

    if (fail == 0) printf("ALL PASS\n");
    else printf("%d FAIL\n", fail);
    return fail ? 1 : 0;
}
