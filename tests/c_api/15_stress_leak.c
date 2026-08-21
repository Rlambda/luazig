/*
** 15_stress_leak.c — stress + leak coverage for the C-continuation and
** lua_State-handle machinery (review item 15): repeated coroutine
** create/yield/close with C continuations, repeated nested C-frame TBC,
** repeated callk/pcallk chains. Memory growth after a full GC must stay
** bounded (both runtimes).
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#define N_ITER 2000
#define KB_LIMIT 256

static lua_Integer memkb(lua_State *L) {
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    return lua_gc(L, LUA_GCCOUNT, 0);
}

/* ---- 1. repeated create + yieldk(k) + close (suspended C continuation) */

static int close_k_calls = 0;

static int k_discard(lua_State *L, int status, lua_KContext ctx) {
    (void)L; (void)status; (void)ctx;
    close_k_calls++;
    return 0;
}

static int c_suspend(lua_State *L) {
    return lua_yieldk(L, 0, 7, k_discard);
}

static int test_stress_coro_close(void) {
    lua_State *L = luaL_newstate();
    if (!L) return 1;
    luaL_openlibs(L);
    close_k_calls = 0;
    lua_Integer before = memkb(L);
    for (int i = 0; i < N_ITER; i++) {
        lua_State *co = lua_newthread(L);
        lua_pushcfunction(co, c_suspend);
        int nres = 0;
        if (lua_resume(co, L, 0, &nres) != LUA_YIELD) {
            fprintf(stderr, "FAIL stress-close: resume %d\n", i);
            lua_close(L); return 1;
        }
        if (lua_closethread(co, L) != LUA_OK) {
            fprintf(stderr, "FAIL stress-close: close %d\n", i);
            lua_close(L); return 1;
        }
        lua_pop(L, 1); /* pop the thread object */
    }
    lua_Integer after = memkb(L);
    int pass = (close_k_calls == 0) && (after - before < KB_LIMIT);
    printf("stress_coro_close: k_calls=%d growth=%s %s\n",
           close_k_calls, (after - before) < KB_LIMIT ? "bounded" : "unbounded",
           pass ? "OK" : "LEAK");
    lua_close(L);
    return pass ? 0 : 1;
}

/* ---- 2. repeated nested C-frame TBC marks */

static int c_inner_mark(lua_State *L) {
    lua_toclose(L, 1);
    return 0;
}

static int c_outer_mark(lua_State *L) {
    lua_toclose(L, 1);
    lua_pushcfunction(L, c_inner_mark);
    lua_pushvalue(L, 2);
    lua_call(L, 1, 0);
    return 0;
}

static int test_stress_nested_tbc(void) {
    lua_State *L = luaL_newstate();
    if (!L) return 1;
    luaL_openlibs(L);
    lua_pushcfunction(L, c_outer_mark);
    lua_setglobal(L, "outer_mark");
    lua_Integer before = memkb(L);
    for (int i = 0; i < N_ITER; i++) {
        if (luaL_dostring(L,
                "outer_mark(setmetatable({}, {__close=function() end}), "
                "setmetatable({}, {__close=function() end}))") != LUA_OK) {
            fprintf(stderr, "FAIL stress-tbc: iter %d: %s\n",
                    i, lua_tostring(L, -1));
            lua_close(L); return 1;
        }
    }
    lua_Integer after = memkb(L);
    int pass = (after - before < KB_LIMIT);
    printf("stress_nested_tbc: growth=%s %s\n",
           (after - before) < KB_LIMIT ? "bounded" : "unbounded",
           pass ? "OK" : "LEAK");
    lua_close(L);
    return pass ? 0 : 1;
}

/* ---- 3. repeated callk/pcallk chains with yields ---- */

static int k_ret(lua_State *L, int status, lua_KContext ctx) {
    (void)status;
    lua_pushinteger(L, (lua_Integer)ctx + 1);
    return 1;
}

static int c_callk_yielder(lua_State *L) {
    return lua_yieldk(L, 0, 0, NULL);
}

static int c_callk_mid(lua_State *L) {
    lua_pushcfunction(L, c_callk_yielder);
    lua_callk(L, 0, 1, 41, k_ret);
    return 1;
}

static int c_pcallk_caller(lua_State *L) {
    lua_pushcfunction(L, c_callk_mid);
    int st = lua_pcallk(L, 0, 1, 0, 5, k_ret);
    if (st != LUA_OK) {
        fprintf(stderr, "FAIL stress-k: pcallk status %d\n", st);
        return 0;
    }
    return 1;
}

static int test_stress_callk_pcallk(void) {
    lua_State *L = luaL_newstate();
    if (!L) return 1;
    luaL_openlibs(L);
    lua_pushcfunction(L, c_pcallk_caller);
    lua_setglobal(L, "c_chain");
    lua_Integer before = memkb(L);
    for (int i = 0; i < N_ITER; i++) {
        if (luaL_dostring(L,
                "local co = coroutine.create(function() return c_chain() end)\n"
                "local ok1 = coroutine.resume(co)\n"
                "local ok2, v = coroutine.resume(co)\n"
                "assert(ok1 and ok2 and v == 6, 'chain failed')") != LUA_OK) {
            fprintf(stderr, "FAIL stress-k: iter %d: %s\n",
                    i, lua_tostring(L, -1));
            lua_close(L); return 1;
        }
        /* chunk returns 0 results — nothing to pop (popping an empty
         * stack is a C API error in PUC too). */
    }
    lua_Integer after = memkb(L);
    int pass = (after - before < KB_LIMIT);
    printf("stress_callk_pcallk: growth=%s %s\n",
           (after - before) < KB_LIMIT ? "bounded" : "unbounded",
           pass ? "OK" : "LEAK");
    lua_close(L);
    return pass ? 0 : 1;
}

int main(void) {
    int fail = 0;
    fail |= test_stress_coro_close();
    fail |= test_stress_nested_tbc();
    fail |= test_stress_callk_pcallk();
    if (fail) {
        fprintf(stderr, "FAIL: 15_stress_leak\n");
        return 1;
    }
    printf("PASS: 15_stress_leak\n");
    return 0;
}
