/*
** 14_state_handles.c — Per-lua_State handle isolation tests.
**
** Verifies that lua_newthread returns distinct handles (co != L),
** that each handle has an independent C API stack (Phase 2), and that
** coroutine resume/closethread/status resolve via the handle.
**
** Phase 1 (current): all handles share Vm.c_stack, so stack isolation
** tests are limited. The identity and resume tests are meaningful now.
*/

#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "lua.h"
#include "lauxlib.h"

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

    /* Push the C function on co's stack (Phase 1: shared stack) */
    lua_pushcfunction(co, simple_coroutine);

    int nres = 0;
    int status = lua_resume(co, L, 0, &nres);
    assert(status == LUA_OK);
    assert(nres == 1);

    /* The result should be on the stack */
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

int main(void) {
    test_newthread_distinct();
    test_two_newthreads_distinct();
    test_resume_via_handle();
    test_status_fresh();
    test_tothread();
    printf("ALL PASS\n");
    return 0;
}
