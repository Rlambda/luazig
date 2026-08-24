/*
** 14_state_handles.c — Per-lua_State handle isolation tests.
**
** Verifies that lua_newthread returns distinct handles (co != L),
** that each handle has an independent C API stack (Phase 2), that
** lua_xmove moves values between handle stacks, and that coroutine
** resume/closethread/status resolve via the handle.
**
** Phase 2: each handle has its own c_stack. lua_xmove performs a
** real cross-stack move. lua_resume switches cur_handle/cur_c_stack
** to the coroutine's handle during execution.
*/

#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* Test 1: lua_newthread returns a distinct handle */
static void test_newthread_distinct(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    lua_State *co = lua_newthread(L);
    assert(co != NULL);
    assert(co != L);  /* distinct handles */
    lua_close(L);
    printf("test_newthread_distinct: PASS\n");
}

/* Test 2: two newthreads are distinct from each other */
static void test_two_newthreads_distinct(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    lua_State *co1 = lua_newthread(L);
    lua_pop(L, 1);  /* pop the thread value pushed by lua_newthread */
    lua_State *co2 = lua_newthread(L);
    lua_pop(L, 1);
    assert(co1 != co2);
    assert(co1 != L);
    assert(co2 != L);
    lua_close(L);
    printf("test_two_newthreads_distinct: PASS\n");
}

/* Test 3: coroutine resume via handle (co != L) */
static int simple_coroutine(lua_State *L) {
    lua_pushliteral(L, "hello from coroutine");
    return 1;
}

static void test_resume_via_handle(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    lua_State *co = lua_newthread(L);
    assert(co != NULL);
    assert(co != L);

    /* Push the C function on co's stack */
    lua_pushcfunction(co, simple_coroutine);

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    assert(status == LUA_OK);
    assert(nres == 1);

    /* The result should be on co's stack */
    const char *result = lua_tostring(co, -1);
    assert(result != NULL);
    assert(strcmp(result, "hello from coroutine") == 0);

    lua_close(L);
    printf("test_resume_via_handle: PASS\n");
}

/* Test 4: lua_status on a fresh coroutine returns LUA_OK */
static void test_status_fresh(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);
    assert(lua_status(co) == LUA_OK);
    assert(lua_status(L) == LUA_OK);
    lua_close(L);
    printf("test_status_fresh: PASS\n");
}

/* Test 5: lua_tothread returns the handle for a thread value */
static void test_tothread(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    lua_State *co = lua_newthread(L);
    /* lua_newthread pushes the thread value on the stack */
    lua_State *retrieved = lua_tothread(L, -1);
    assert(retrieved == co);
    lua_close(L);
    printf("test_tothread: PASS\n");
}

/* Test 6: independent stacks — pushing on L does not affect co */
static void test_independent_stacks(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);  /* pop the thread value */

    /* Push values on L's stack */
    lua_pushinteger(L, 100);
    lua_pushinteger(L, 200);
    assert(lua_gettop(L) == 2);

    /* co's stack should be empty (independent) */
    assert(lua_gettop(co) == 0);

    /* Push a value on co's stack */
    lua_pushinteger(co, 42);
    assert(lua_gettop(co) == 1);

    /* L's stack should be unchanged */
    assert(lua_gettop(L) == 2);
    assert(lua_tointeger(L, -1) == 200);
    assert(lua_tointeger(L, -2) == 100);

    /* co's stack should have its own value */
    assert(lua_tointeger(co, -1) == 42);

    lua_close(L);
    printf("test_independent_stacks: PASS\n");
}

/* Test 7: lua_xmove moves values between handle stacks */
static void test_xmove(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);  /* pop the thread value */

    /* Push 3 values on L's stack */
    lua_pushinteger(L, 10);
    lua_pushinteger(L, 20);
    lua_pushinteger(L, 30);
    assert(lua_gettop(L) == 3);

    /* Move top 2 from L to co */
    lua_xmove(L, co, 2);

    /* L should have 1 value left */
    assert(lua_gettop(L) == 1);
    assert(lua_tointeger(L, -1) == 10);

    /* co should have 2 values, in order */
    assert(lua_gettop(co) == 2);
    assert(lua_tointeger(co, -1) == 30);
    assert(lua_tointeger(co, -2) == 20);

    lua_close(L);
    printf("test_xmove: PASS\n");
}

/* Test 8: lua_xmove with n=0 is a no-op */
static void test_xmove_zero(void) {
    lua_State *L = luaL_newstate();
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);

    lua_pushinteger(L, 99);
    lua_xmove(L, co, 0);

    assert(lua_gettop(L) == 1);
    assert(lua_gettop(co) == 0);

    lua_close(L);
    printf("test_xmove_zero: PASS\n");
}

/* Test 9: lua_xmove self-move is a no-op */
static void test_xmove_self(void) {
    lua_State *L = luaL_newstate();
    lua_pushinteger(L, 1);
    lua_pushinteger(L, 2);
    lua_xmove(L, L, 2);

    /* Self-move should not duplicate or remove values */
    assert(lua_gettop(L) == 2);
    assert(lua_tointeger(L, -1) == 2);
    assert(lua_tointeger(L, -2) == 1);

    lua_close(L);
    printf("test_xmove_self: PASS\n");
}

/* Test 10: coroutine with yield — co's stack is independent from L */
static int yielding_coroutine(lua_State *L) {
    lua_pushinteger(L, 111);
    return lua_yield(L, 1);
}

static void test_coroutine_yield_independent(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);
    assert(co != L);

    /* Push the yielding coroutine function on co's stack */
    lua_pushcfunction(co, yielding_coroutine);

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    assert(status == LUA_YIELD);
    assert(nres == 1);
    /* The yielded value (111) is on co's stack */
    assert(lua_tointeger(co, -1) == 111);

    /* L's stack should be empty (independent from co) */
    assert(lua_gettop(L) == 0);

    /* Push something on L while co is suspended */
    lua_pushinteger(L, 999);
    assert(lua_gettop(L) == 1);

    /* Resume co with 1 arg. Since k==NULL, finishCcall treats the resume
     * values as the C function's results. The coroutine completes. */
    lua_pushinteger(co, 222);  /* resume argument */
    nres = 0;
    status = lua_resume(co, L, 1, &nres);
    assert(status == LUA_OK);
    assert(nres == 1);
    /* The result is the resume value (222) — k==NULL returns resume values */
    assert(lua_tointeger(co, -1) == 222);

    /* L's stack should still have our 999 */
    assert(lua_gettop(L) == 1);
    assert(lua_tointeger(L, -1) == 999);

    lua_close(L);
    printf("test_coroutine_yield_independent: PASS\n");
}

/* Test 11: multiple coroutines with independent stacks */
static void test_multiple_coroutines_independent(void) {
    lua_State *L = luaL_newstate();
    lua_State *co1 = lua_newthread(L);
    lua_pop(L, 1);
    lua_State *co2 = lua_newthread(L);
    lua_pop(L, 1);

    /* Push different values on each stack */
    lua_pushinteger(L, 1);
    lua_pushinteger(co1, 2);
    lua_pushinteger(co2, 3);

    assert(lua_gettop(L) == 1);
    assert(lua_gettop(co1) == 1);
    assert(lua_gettop(co2) == 1);

    assert(lua_tointeger(L, -1) == 1);
    assert(lua_tointeger(co1, -1) == 2);
    assert(lua_tointeger(co2, -1) == 3);

    /* xmove from co1 to co2 */
    lua_xmove(co1, co2, 1);
    assert(lua_gettop(co1) == 0);
    assert(lua_gettop(co2) == 2);
    assert(lua_tointeger(co2, -1) == 2);
    assert(lua_tointeger(co2, -2) == 3);

    /* L is unaffected */
    assert(lua_gettop(L) == 1);
    assert(lua_tointeger(L, -1) == 1);

    lua_close(L);
    printf("test_multiple_coroutines_independent: PASS\n");
}

/* Test 12: lua_status preserves error status after runtime error */
static void test_status_after_error(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    luaL_openlibs(L);
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);
    luaL_loadstring(co, "error('boom')");
    int nres = 0;
    int st = lua_resume(co, L, 0, &nres);
    assert(st == LUA_ERRRUN);
    assert(lua_status(co) == LUA_ERRRUN);
    lua_close(L);
    printf("test_status_after_error: PASS\n");
}

/* Test 13: lua_status after yield and after completion (via handle) */
static void test_status_yield_complete(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    luaL_openlibs(L);
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);
    luaL_loadstring(co, "coroutine.yield(42) return 99");

    assert(lua_status(co) == LUA_OK); /* fresh */

    int nres = 0;
    int st = lua_resume(co, L, 0, &nres);
    assert(st == LUA_YIELD);
    assert(lua_status(co) == LUA_YIELD);

    st = lua_resume(co, L, 0, &nres);
    assert(st == LUA_OK);
    assert(lua_status(co) == LUA_OK);

    lua_close(L);
    printf("test_status_yield_complete: PASS\n");
}

/* Test 14 (P15.83k review item 1): after a yield, a subsequent resume must
 * REPLACE the stale yielded values on the coroutine's C stack exactly
 * (PUC lua_resume: results occupy ci->func+1..top). Resuming with one
 * extra argument makes the replacement observable: only 'done' remains. */
static void test_direct_resume_stack_exact(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    luaL_openlibs(L);
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);
    luaL_loadstring(co, "local y = coroutine.yield('Y') return 'done'");

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    assert(status == LUA_YIELD);
    assert(nres == 1);
    assert(lua_gettop(co) == 1);
    assert(strcmp(lua_tostring(co, -1), "Y") == 0);

    /* Resume with an extra arg: the arg is consumed, and the final results
     * must start at slot 1 with nothing stale underneath. */
    lua_pushliteral(co, "X");
    status = lua_resume(co, L, 1, &nres);
    assert(status == LUA_OK);
    assert(nres == 1);
    assert(lua_gettop(co) == 1);
    assert(strcmp(lua_tostring(co, 1), "done") == 0);  /* absolute index */
    assert(lua_tostring(co, 2) == NULL);  /* stale 'Y' must not remain */
    assert(lua_status(co) == LUA_OK);

    lua_close(L);
    printf("test_direct_resume_stack_exact: PASS\n");
}

/* Test 15 (P15.83k edge case 4, CIST_CLSRET): a C function marks its first
 * argument to-be-closed, pushes a result and returns; the Lua __close
 * yields once. The yielded 'Y' must be fully replaced by the C function's
 * results when the close completes. */
static int c_return_with_tbc(lua_State *L) {
    lua_settop(L, 1);
    lua_toclose(L, 1);
    lua_pushliteral(L, "done");
    return 1;
}

static void test_resume_clsret_stack_exact(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    luaL_openlibs(L);
    lua_pushcfunction(L, c_return_with_tbc);
    lua_setglobal(L, "c_return_with_tbc");
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);
    luaL_loadstring(co,
        "local o = setmetatable({},{__close=function() coroutine.yield('Y') end})"
        "; return c_return_with_tbc(o)");

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    assert(status == LUA_YIELD);
    assert(nres == 1);
    assert(lua_gettop(co) == 1);
    assert(strcmp(lua_tostring(co, -1), "Y") == 0);

    status = lua_resume(co, L, 0, &nres);
    assert(status == LUA_OK);
    assert(nres == 1);
    assert(lua_gettop(co) == 1);
    assert(strcmp(lua_tostring(co, -1), "done") == 0);
    assert(lua_tostring(co, 2) == NULL);  /* stale 'Y' must not remain */
    assert(lua_status(co) == LUA_OK);

    lua_close(L);
    printf("test_resume_clsret_stack_exact: PASS\n");
}

/* Test 16 (P15.83k edge case 1): subsequent resume with nargs == 0 after a
 * yield — the stale yielded value must be removed; only the coroutine's
 * return values remain. */
static void test_resume_nargs0_replacement(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    luaL_openlibs(L);
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);
    luaL_loadstring(co, "local y = coroutine.yield('Y') return 'R', y");

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    assert(status == LUA_YIELD);
    assert(nres == 1);
    assert(lua_gettop(co) == 1);
    assert(strcmp(lua_tostring(co, 1), "Y") == 0);

    status = lua_resume(co, L, 0, &nres);
    assert(status == LUA_OK);
    assert(nres == 2);
    assert(lua_gettop(co) == 2);  /* not 3: stale 'Y' gone */
    assert(strcmp(lua_tostring(co, 1), "R") == 0);
    assert(lua_isnil(co, 2));
    assert(lua_tostring(co, 3) == NULL);
    assert(lua_status(co) == LUA_OK);

    lua_close(L);
    printf("test_resume_nargs0_replacement: PASS\n");
}

/* Test 17 (P15.83k edge case 2): multiple yield->resume cycles — each
 * cycle's results replace the previous ones; nothing accumulates. */
static void test_resume_multi_cycle_exact(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    luaL_openlibs(L);
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);
    luaL_loadstring(co,
        "coroutine.yield('A') coroutine.yield('B') return 'C','D'");

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    assert(status == LUA_YIELD);
    assert(nres == 1);
    assert(lua_gettop(co) == 1);
    assert(strcmp(lua_tostring(co, 1), "A") == 0);

    status = lua_resume(co, L, 0, &nres);
    assert(status == LUA_YIELD);
    assert(nres == 1);
    assert(lua_gettop(co) == 1);  /* not 2: 'A' replaced by 'B' */
    assert(strcmp(lua_tostring(co, 1), "B") == 0);
    assert(lua_tostring(co, 2) == NULL);

    status = lua_resume(co, L, 0, &nres);
    assert(status == LUA_OK);
    assert(nres == 2);
    assert(lua_gettop(co) == 2);  /* not 3/4: no accumulation */
    assert(strcmp(lua_tostring(co, 1), "C") == 0);
    assert(strcmp(lua_tostring(co, 2), "D") == 0);
    assert(lua_tostring(co, 3) == NULL);
    assert(lua_status(co) == LUA_OK);

    lua_close(L);
    printf("test_resume_multi_cycle_exact: PASS\n");
}

/* Test 18 (P15.83k edge case 5): resume-arg count varying vs the previous
 * yield's value count (more args, then fewer). Every resume replaces the
 * previous window exactly. */
static void test_resume_args_mix_exact(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    luaL_openlibs(L);
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);
    luaL_loadstring(co,
        "local a = coroutine.yield('Y1') "
        "local b, c = coroutine.yield('Y2', a) "
        "local d = coroutine.yield('Y3', b, c) "
        "return a, b, c, d");

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);  /* 0 args, 1 yielded */
    assert(status == LUA_YIELD);
    assert(nres == 1);
    assert(lua_gettop(co) == 1);
    assert(strcmp(lua_tostring(co, 1), "Y1") == 0);

    lua_pushliteral(co, "x");
    status = lua_resume(co, L, 1, &nres);      /* 1 arg after 1-value yield */
    assert(status == LUA_YIELD);
    assert(nres == 2);
    assert(lua_gettop(co) == 2);
    assert(strcmp(lua_tostring(co, 1), "Y2") == 0);
    assert(strcmp(lua_tostring(co, 2), "x") == 0);
    assert(lua_tostring(co, 3) == NULL);

    lua_pushliteral(co, "p");
    lua_pushliteral(co, "q");
    status = lua_resume(co, L, 2, &nres);      /* 2 args after 2-value yield */
    assert(status == LUA_YIELD);
    assert(nres == 3);
    assert(lua_gettop(co) == 3);
    assert(strcmp(lua_tostring(co, 1), "Y3") == 0);
    assert(strcmp(lua_tostring(co, 2), "p") == 0);
    assert(strcmp(lua_tostring(co, 3), "q") == 0);
    assert(lua_tostring(co, 4) == NULL);

    status = lua_resume(co, L, 0, &nres);      /* 0 args after 3-value yield */
    assert(status == LUA_OK);
    assert(nres == 4);
    assert(lua_gettop(co) == 4);
    assert(strcmp(lua_tostring(co, 1), "x") == 0);
    assert(strcmp(lua_tostring(co, 2), "p") == 0);
    assert(strcmp(lua_tostring(co, 3), "q") == 0);
    assert(lua_isnil(co, 4));
    assert(lua_tostring(co, 5) == NULL);
    assert(lua_status(co) == LUA_OK);

    lua_close(L);
    printf("test_resume_args_mix_exact: PASS\n");
}

/* Test 19 (P15.83k edge case 3): error after a yield — the error object is
 * on top, the stale yielded value is gone, and lua_status preserves the
 * error. (Checked via invariants that hold identically on PUC and luazig:
 * PUC's error-path stack keeps frame-relative residue whose exact layout
 * is not part of the API contract; luazig exposes just the error object.) */
static void test_resume_error_replacement(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    luaL_openlibs(L);
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);
    luaL_loadstring(co, "coroutine.yield('Y') error('boom')");

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    assert(status == LUA_YIELD);
    assert(nres == 1);
    assert(lua_gettop(co) == 1);
    assert(strcmp(lua_tostring(co, 1), "Y") == 0);

    status = lua_resume(co, L, 0, &nres);
    assert(status == LUA_ERRRUN);
    assert(lua_status(co) == LUA_ERRRUN);
    /* error object on top of the stack */
    assert(lua_isstring(co, -1));
    assert(strstr(lua_tostring(co, -1), "boom") != NULL);
    /* stale 'Y' must not remain anywhere in the visible window */
    for (int i = 1; i <= lua_gettop(co); i++)
        assert(!(lua_type(co, i) == LUA_TSTRING &&
                 strcmp(lua_tostring(co, i), "Y") == 0));

    lua_close(L);
    printf("test_resume_error_replacement: PASS\n");
}

/* Test 20 (P15.83k review item 4): every lua_State maps to a Lua thread
 * Value, including the main state. lua_pushthread pushes that value and
 * returns 1 only for the main state; lua_tothread reverse-maps the value
 * to the exact lua_State handle. */
static void test_pushthread_identity(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);

    /* main state: pushes a real thread value, returns 1 */
    assert(lua_pushthread(L) == 1);
    assert(lua_type(L, -1) == LUA_TTHREAD);
    assert(lua_tothread(L, -1) == L);
    lua_pop(L, 1);

    /* coroutine state: returns 0, maps to its own handle */
    lua_State *co = lua_newthread(L);
    lua_pop(L, 1);
    assert(lua_pushthread(co) == 0);
    assert(lua_type(co, -1) == LUA_TTHREAD);
    assert(lua_tothread(co, -1) == co);
    lua_pop(co, 1);

    /* thread values keep identity across xmove between stacks */
    lua_pushthread(L);
    lua_xmove(L, co, 1);
    assert(lua_tothread(co, -1) == L);
    lua_pushthread(co);
    lua_xmove(co, L, 1);
    assert(lua_tothread(L, -1) == co);

    /* non-thread values map to NULL */
    lua_pushinteger(L, 42);
    assert(lua_tothread(L, -1) == NULL);

    lua_close(L);
    printf("test_pushthread_identity: PASS\n");
}

int main(void) {
    test_newthread_distinct();
    test_two_newthreads_distinct();
    test_resume_via_handle();
    test_status_fresh();
    test_tothread();
    test_independent_stacks();
    test_xmove();
    test_xmove_zero();
    test_xmove_self();
    test_coroutine_yield_independent();
    test_multiple_coroutines_independent();
    test_status_after_error();
    test_status_yield_complete();
    test_direct_resume_stack_exact();
    test_resume_clsret_stack_exact();
    test_resume_nargs0_replacement();
    test_resume_multi_cycle_exact();
    test_resume_args_mix_exact();
    test_resume_error_replacement();
    test_pushthread_identity();
    printf("ALL PASS\n");
    return 0;
}
