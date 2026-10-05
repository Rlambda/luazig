/*
 * 43_yield_park_window.c — permanent differential suite: the C-API window
 * of a coroutine parked by coroutine.yield() (empty and non-empty park).
 *
 * PUC ground truth: after `coroutine.yield(...)` suspends a coroutine,
 * the suspended thread's API window ([ci->func+1, top) of the yield's own
 * C frame) contains EXACTLY the yielded values — zero of them for a
 * no-argument yield. lua_gettop(co) therefore reports 0 for an empty
 * park, 1 for a one-value park, and the window survives lua_settop,
 * lua_gc and repeated resume cycles.
 *
 * Covers:
 *   - no-arg park: gettop == 0, status YIELD, coroutine.status view;
 *   - one-arg control: gettop == 1 and the parked value is readable;
 *   - lua_settop(co, 0) on both park shapes (drops the value, stays
 *     resumable);
 *   - GC while parked (window + frames + parked values rooted);
 *   - repeated park/resume cycles alternating empty/one-arg parks;
 *   - an object parked as the yielded value survives GC and reaches the
 *     final results;
 *   - a no-arg yield from inside a nested Lua function (the register
 *     file of the suspended inner frame must NOT leak into the window).
 *
 * Every printed line must be byte-identical between PUC Lua 5.5 and
 * luazig. Exit code is non-zero on any failed check.
 */

#include <stdio.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int fails = 0;

static void check(long cond, const char *label) {
    printf("%s:%ld\n", label, cond);
    if (!cond) fails++;
}

static void checkeq(long v, long want, const char *label) {
    printf("%s=%ld\n", label, v);
    if (v != want) fails++;
}

static void checkstr(const char *v, const char *want, const char *label) {
    printf("%s=%s\n", label, v ? v : "(null)");
    if (v == NULL || want == NULL || strcmp(v, want) != 0) fails++;
}

static lua_State *park(lua_State *L, const char *body) {
    /* the new thread value STAYS at the bottom of L's stack: it is the
     * only reference keeping the coroutine alive across the GC checks */
    lua_State *co = lua_newthread(L);
    if (luaL_loadstring(co, body) != 0) {
        printf("LOADERR %s\n", lua_tostring(co, -1));
        return NULL;
    }
    int nres = 0;
    int rst = lua_resume(co, L, 0, &nres);
    checkeq(rst, LUA_YIELD, "park.rst");
    return co;
}

/* drop the thread reference parked at the bottom of L's stack */
static void unref_co(lua_State *L) {
    lua_pop(L, 1);
}

static void part_noarg(lua_State *L) {
    lua_State *co = park(L, "local a = coroutine.yield()\nreturn 'done', a");
    if (!co) return;
    checkeq(lua_status(co), LUA_YIELD, "N1.status");
    checkeq(lua_gettop(co), 0, "N1.gettop"); /* the empty park window */
    lua_getglobal(L, "coroutine");
    lua_getfield(L, -1, "status");
    lua_pushvalue(L, -3); /* the thread */
    lua_call(L, 1, 1);
    checkstr(lua_tostring(L, -1), "suspended", "N1.costatus");
    lua_pop(L, 2); /* result, coroutine — the thread stays referenced */

    /* settop(0) on the parked coroutine: stays suspended, stays empty */
    lua_settop(co, 0);
    checkeq(lua_status(co), LUA_YIELD, "N1.settop-status");
    checkeq(lua_gettop(co), 0, "N1.settop-gettop");

    /* GC must not disturb the parked window or frames */
    lua_gc(L, LUA_GCCOLLECT, 0);
    checkeq(lua_status(co), LUA_YIELD, "N1.gc-status");
    checkeq(lua_gettop(co), 0, "N1.gc-gettop");

    /* re-resume with one argument: the argument becomes the yield result */
    lua_pushstring(co, "r1");
    int nres = 0;
    int rst = lua_resume(co, L, 1, &nres);
    checkeq(rst, LUA_OK, "N1.r2-rst");
    checkeq(nres, 2, "N1.r2-nres");
    checkstr(lua_tostring(co, -2), "done", "N1.r2-a");
    checkstr(lua_tostring(co, -1), "r1", "N1.r2-b");
    lua_pop(co, 2);
    checkeq(lua_status(co), LUA_OK, "N1.r2-status");
    checkeq(lua_gettop(co), 0, "N1.r2-gettop");
    unref_co(L);
}

static void part_onearg(lua_State *L) {
    lua_State *co = park(L, "local a = coroutine.yield('park')\nreturn 'fin', a");
    if (!co) return;
    checkeq(lua_status(co), LUA_YIELD, "N2.status");
    checkeq(lua_gettop(co), 1, "N2.gettop");
    checkstr(lua_tostring(co, -1), "park", "N2.value");

    /* settop(0) drops the parked value; the coroutine stays resumable */
    lua_settop(co, 0);
    checkeq(lua_status(co), LUA_YIELD, "N2.settop-status");
    checkeq(lua_gettop(co), 0, "N2.settop-gettop");
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_pushstring(co, "x");
    int nres = 0;
    int rst = lua_resume(co, L, 1, &nres);
    checkeq(rst, LUA_OK, "N2.r2-rst");
    checkeq(nres, 2, "N2.r2-nres");
    checkstr(lua_tostring(co, -1), "x", "N2.r2-b");
    lua_pop(co, 2);
    unref_co(L);
}

static void part_onearg_nodrop(lua_State *L) {
    lua_State *co = park(L, "local a = coroutine.yield('keep')\nreturn 'fin', a");
    if (!co) return;
    checkeq(lua_gettop(co), 1, "N3.gettop");
    lua_gc(L, LUA_GCCOLLECT, 0);
    checkeq(lua_gettop(co), 1, "N3.gc-gettop");
    checkstr(lua_tostring(co, -1), "keep", "N3.value");
    lua_pushstring(co, "y");
    int nres = 0;
    int rst = lua_resume(co, L, 1, &nres);
    checkeq(rst, LUA_OK, "N3.r2-rst");
    checkeq(nres, 2, "N3.r2-nres");
    checkstr(lua_tostring(co, -1), "y", "N3.r2-b");
    lua_pop(co, 2);
    unref_co(L);
}

static void part_cycles(lua_State *L) {
    lua_State *co = lua_newthread(L);
    luaL_loadstring(co,
        "local a = coroutine.yield()\n"
        "local b = coroutine.yield('one')\n"
        "local c = coroutine.yield()\n"
        "return 'sum', a, b, c");
    int nres = 0;
    int rst = lua_resume(co, L, 0, &nres);
    checkeq(rst, LUA_YIELD, "N4.p1-rst");
    checkeq(lua_gettop(co), 0, "N4.p1-top");
    lua_pushstring(co, "A");
    rst = lua_resume(co, L, 1, &nres);
    checkeq(rst, LUA_YIELD, "N4.p2-rst");
    checkeq(lua_gettop(co), 1, "N4.p2-top");
    checkstr(lua_tostring(co, -1), "one", "N4.p2-val");
    lua_pushstring(co, "B");
    rst = lua_resume(co, L, 1, &nres);
    checkeq(rst, LUA_YIELD, "N4.p3-rst");
    checkeq(lua_gettop(co), 0, "N4.p3-top");
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_pushstring(co, "C");
    rst = lua_resume(co, L, 1, &nres);
    checkeq(rst, LUA_OK, "N4.p4-rst");
    checkeq(nres, 4, "N4.p4-nres");
    checkstr(lua_tostring(co, -4), "sum", "N4.p4-0");
    checkstr(lua_tostring(co, -3), "A", "N4.p4-1");
    checkstr(lua_tostring(co, -2), "B", "N4.p4-2");
    checkstr(lua_tostring(co, -1), "C", "N4.p4-3");
    lua_pop(co, 4);
    unref_co(L);
}

static void part_roots(lua_State *L) {
    lua_State *co = lua_newthread(L);
    luaL_loadstring(co,
        "local t = {tag = 'kept'}\n"
        "local r = coroutine.yield(t)\n"
        "return r, t");
    int nres = 0;
    int rst = lua_resume(co, L, 0, &nres);
    checkeq(rst, LUA_YIELD, "N5.p1-rst");
    checkeq(lua_gettop(co), 1, "N5.p1-top");
    /* the parked table is reachable through the window; nothing else
     * references it — it must survive collection */
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    checkeq(lua_gettop(co), 1, "N5.gc-top");
    check(lua_istable(co, -1), "N5.gc-is-table");
    lua_getfield(co, -1, "tag");
    checkstr(lua_tostring(co, -1), "kept", "N5.gc-tag");
    lua_pop(co, 1);
    lua_pushstring(co, "z");
    rst = lua_resume(co, L, 1, &nres);
    checkeq(rst, LUA_OK, "N5.r2-rst");
    checkeq(nres, 2, "N5.r2-nres");
    checkstr(lua_tostring(co, -2), "z", "N5.r2-r");
    lua_getfield(co, -1, "tag");
    checkstr(lua_tostring(co, -1), "kept", "N5.r2-tag");
    lua_pop(co, 2);
    unref_co(L);
}

static void part_nested(lua_State *L) {
    lua_State *co = park(L,
        "local function f()\n"
        "  local deep = 99\n"
        "  return coroutine.yield(), deep\n"
        "end\n"
        "local a, d = f()\n"
        "return 'd2', a, d");
    if (!co) return;
    checkeq(lua_status(co), LUA_YIELD, "N6.status");
    checkeq(lua_gettop(co), 0, "N6.gettop"); /* inner registers must not leak */
    lua_gc(L, LUA_GCCOLLECT, 0);
    checkeq(lua_gettop(co), 0, "N6.gc-gettop");
    lua_pushstring(co, "w");
    int nres = 0;
    int rst = lua_resume(co, L, 1, &nres);
    checkeq(rst, LUA_OK, "N6.r2-rst");
    checkeq(nres, 3, "N6.r2-nres");
    checkstr(lua_tostring(co, -3), "d2", "N6.r2-0");
    checkstr(lua_tostring(co, -2), "w", "N6.r2-1");
    checkeq(lua_tointeger(co, -1), 99, "N6.r2-2");
    lua_pop(co, 3);
    unref_co(L);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    part_noarg(L);
    part_onearg(L);
    part_onearg_nodrop(L);
    part_cycles(L);
    part_roots(L);
    part_nested(L);

    lua_close(L);
    printf("FAILS=%d\n", fails);
    return fails != 0;
}
