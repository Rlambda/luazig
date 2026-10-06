/* 49_math_open_oom: allocation-failure edges of luaopen_math (countdown
 * allocator, frozen after the k-th failure to defeat the emergency-GC
 * retry), recovery, and VM reuse after the failure.
 *
 * Differential suite (zig vs PUC). The per-runtime allocation structure of
 * luaopen_math is NOT a parity contract, so the k-matrix of which trials
 * fail is not compared byte-wise: every trial must either fail cleanly
 * (LUA_ERRMEM + string error object + working GC + successful retry) or
 * succeed, and in BOTH branches the resulting math table must be fully
 * usable (seed 42 -> first r(10,99) draw is 59 on any correct core). A
 * property violation fails the suite on the runtime that exhibits it. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int countdown = -1;   /* -1: never fail; k: fail the k-th malloc */
static int frozen = 0;       /* once the k-th allocation fails, keep failing
                              * (defeats the emergency-GC retry) until cleared */
static void *falloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    (void)ud; (void)osize;
    if (nsize == 0) { free(ptr); return NULL; }
    if (frozen) return NULL;
    if (countdown > 0) {
        countdown--;
        if (countdown == 0) { frozen = 1; return NULL; }
    }
    if (ptr) return realloc(ptr, nsize);
    return malloc(nsize);
}

static int fails = 0;
__attribute__((constructor)) static void unbuf(void) { setbuf(stdout, NULL); }

/* seed(42) + r(10,99) on the table at the top of the stack: the draw is 59
 * on any correct xoshiro core; also proves the closures carry a live
 * RanState after the (possibly retried) open. Returns 1 on success. */
static int usable_after_open(lua_State *L) {
    lua_getfield(L, -1, "randomseed");
    lua_pushinteger(L, 42);
    if (lua_pcall(L, 1, 2, 0) != LUA_OK) { lua_pop(L, 1); return 0; }
    lua_pop(L, 2);
    lua_getfield(L, -1, "random");
    lua_pushinteger(L, 10); lua_pushinteger(L, 99);
    if (lua_pcall(L, 2, 1, 0) != LUA_OK) { lua_pop(L, 1); return 0; }
    long long d = (long long)lua_tointeger(L, -1);
    lua_pop(L, 1);
    return d == 59;
}

/* one protected luaopen_math under countdown k; verifies the per-trial
 * properties and prints a single normalized verdict line */
static void trial(int k) {
    lua_State *L = lua_newstate(falloc, NULL, 0);
    if (!L) { printf("k=%d: newstate-failed\n", k); fails++; return; }
    countdown = k; frozen = 0;
    lua_pushcfunction(L, luaopen_math);
    int st = lua_pcall(L, 0, 1, 0);
    countdown = -1; frozen = 0;
    const char *verdict = "clean";
    if (st == LUA_OK) {
        /* the freeze never hit a fallible step: the table must be usable */
        if (!usable_after_open(L)) verdict = "VIOLATION(unusable)";
        lua_pop(L, 1);
    } else if (st == LUA_ERRMEM) {
        if (lua_type(L, -1) != LUA_TSTRING) verdict = "VIOLATION(errtype)";
        lua_pop(L, 1);
        /* recovery: the failed state must survive a real GC cycle */
        lua_gc(L, LUA_GCCOLLECT, 0);
        /* VM reuse after the failure: the retry must succeed and the
         * retried opening must be a fully usable fresh table */
        lua_pushcfunction(L, luaopen_math);
        int st2 = lua_pcall(L, 0, 1, 0);
        if (st2 != LUA_OK) { verdict = "VIOLATION(retry)"; lua_pop(L, 1); }
        else {
            if (!usable_after_open(L)) verdict = "VIOLATION(retry-unusable)";
            lua_pop(L, 1);
        }
    } else {
        verdict = "VIOLATION(status)";
        lua_pop(L, 1);
    }
    printf("k=%d: %s\n", k, verdict);
    if (verdict[0] == 'V') fails++;
    lua_close(L);
}

int main(void) {
    for (int k = 1; k <= 12; k++) trial(k);
    /* control: no countdown -> success and the deterministic draw */
    lua_State *L = lua_newstate(falloc, NULL, 0);
    lua_pushcfunction(L, luaopen_math);
    int st = lua_pcall(L, 0, 1, 0);
    printf("control: st=%d\n", st);
    if (st == LUA_OK) {
        if (!usable_after_open(L)) { printf("control: draw=VIOLATION\n"); fails++; }
        else printf("control: draw=59\n");
        lua_pop(L, 1);
    } else {
        fails++;
    }
    lua_close(L);
    printf("fails:%d\n", fails);
    return fails ? 1 : 0;
}
