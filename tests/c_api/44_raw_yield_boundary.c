/*
 * 44_raw_yield_boundary.c — permanent differential suite: the unified
 * typed raw-yield boundary (A-full foundation cut P1).
 *
 * PUC ground truth: a raw f(L) / lua_callk on a PASSED lua_State whose
 * target yields with no armed protection of its own takes PUC
 * luaD_throw's no-errorJmp branch (ldo.c:125-147): luaE_resetthread(L,
 * LUA_YIELD) closes every to-be-closed mark (YIELD converts to LUA_OK
 * inside the reset; a closer error wins last-error-wins and converts the
 * status), the target's base func slot value (or the closer error object
 * at stack+1) is copied onto MAIN's live top, and the re-throw rides
 * MAIN's armed boundary with that status:
 *   - status OK (the plain absorption): a conventional pcall on main
 *     runs NO recovery and finishpcall returns the live stale-anchored
 *     window as the pcall's SUCCESS results (the luaD_pcall hole);
 *   - a closer error status: the pcall recovers it like an ordinary
 *     error raised across the C frame;
 *   - no armed boundary anywhere: the panic hook runs with the throwing
 *     thread, then the process aborts.
 *
 * Covers (R1-R8 ported from the syres representative matrix, proven
 * byte-identical against clean PUC 5.5.0):
 *   R1  chunk-level raw yield (no pcall): the embedder boundary
 *       (luaL_dostring) absorbs; the host reads the stale-anchored
 *       window;
 *   R2  pcall(lua fn) where the lua fn raw-calls a C-ABI yield replica on the
 *       fresh co: the window anchors at the raw callee's frame through
 *       a Lua frame;
 *   R3  xpcall(probe_raw, msgh): finishpcall(L, OK, 2) drops the
 *       window's bottom 2 values; msgh must NOT run;
 *   R4  raw pcall on a RUNNING co (armed lane under Lua pcall) +
 *       re-resume;
 *   R5  a C function calling lua_yieldk(co) directly (k = NULL);
 *   R6  coroutine.close of a co suspended by an ARMED raw yield;
 *   R7  host callback on a CO raw-yields on a THIRD fresh co under the
 *       co's Lua-level pcall (the rethrow bypasses to MAIN's pad);
 *   R8  pairs regression after all of the above;
 * plus the P1 completion shapes:
 *   RR  re-resume with args of a C-body parked co (args pushed on the
 *       TARGET per the lua_resume contract): the k runs with status
 *       YIELD, the plain-yield form poscalls the arg as the result;
 *   NK  nested continuations: a k that itself lua_callk's a yielding
 *       callee with a second k, parked and re-resumed;
 *   TC  a to-be-closed mark on the fresh target when the unarmed
 *       transport resets it: the __close closer runs, its error
 *       (last-error-wins) rethrows on main and the pcall recovers it;
 *   PH  the panic-hook terminal (forked): an unarmed raw yield with no
 *       armed boundary and no pcall anywhere runs the atpanic hook with
 *       the throwing thread and aborts the process.
 *
 * Every printed line must be byte-identical between PUC Lua 5.5 and
 * luazig. Exit code is non-zero on any failed check.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int fails = 0;

static lua_State *g_co;

static void normprint(lua_State *L, int idx, char *buf, size_t bufsz) {
    switch (lua_type(L, idx)) {
    case LUA_TSTRING: {
        const char *s = lua_tostring(L, idx);
        snprintf(buf, bufsz, "string:%s", s);
        break;
    }
    case LUA_TNUMBER: {
        if (lua_isinteger(L, idx))
            snprintf(buf, bufsz, "int:%lld", (long long)lua_tointeger(L, idx));
        else
            snprintf(buf, bufsz, "float:%g", lua_tonumber(L, idx));
        break;
    }
    case LUA_TBOOLEAN:
        snprintf(buf, bufsz, "bool:%d", lua_toboolean(L, idx));
        break;
    case LUA_TFUNCTION:
        snprintf(buf, bufsz, "function:%s",
            lua_iscfunction(L, idx) ? "+c" : "");
        break;
    case LUA_TNIL:
        snprintf(buf, bufsz, "nil");
        break;
    default:
        snprintf(buf, bufsz, "%s", lua_typename(L, lua_type(L, idx)));
        break;
    }
}

static void print_stack(lua_State *L, const char *tag) {
    char b[128];
    int n = lua_gettop(L);
    printf("%s: n=%d", tag, n);
    for (int i = 1; i <= n; i++) {
        normprint(L, i, b, sizeof b);
        printf(" [%s]", b);
    }
    printf("\n");
}

/* (fn, v1, v2, target): raw-call fn on the target state. */
static int probe_raw(lua_State *L) {
    lua_CFunction f = lua_tocfunction(L, 1);
    const char *target = lua_tostring(L, 4);
    if (strcmp(target, "gco") == 0 || strcmp(target, "co") == 0) {
        lua_pushvalue(L, 2);
        lua_pushvalue(L, 3);
        lua_xmove(L, g_co, 2);
        int n = f(g_co);
        lua_xmove(g_co, L, n);
        return n;
    } else {
        lua_pushvalue(L, 2);
        lua_pushvalue(L, 3);
        return f(L);
    }
}

/* C fn calling lua_yieldk directly (k = NULL): (v1, v2, target). */
static int probe_yieldk(lua_State *L) {
    const char *target = lua_tostring(L, 3);
    if (strcmp(target, "co") == 0) {
        return lua_yieldk(g_co, 0, 0, NULL);
    } else {
        return lua_yieldk(L, 0, 0, NULL);
    }
}

/* C replica of PUC luaB_yield (lcorolib.c): yield every argument.
 * The raw callee for the unarmed-transport shapes — master luazig
 * publishes coroutine.yield as a native builtin (the light-C
 * publication is a later cut), so the suite carries its own C-ABI
 * yield to drive raw f(L) calls on a passed lua_State. */
static int cyieldn(lua_State *L) {
    return lua_yieldk(L, lua_gettop(L), 0, NULL);
}

static void check(lua_State *L, const char *chunk) {
    if (luaL_dostring(L, chunk) != LUA_OK) {
        printf("CHUNK ERR: %s\n", lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_pop(L, 1);
    }
}

/* ---- RR: re-resume with args of a C-body parked co (args on target) -- */

static int rr_k1(lua_State *L, int status, lua_KContext ctx) {
    printf("RR-K1: status=%d top=%d t1=%s\n", status, lua_gettop(L),
        lua_typename(L, lua_type(L, 1)));
    (void)ctx;
    return 0;
}

static int rr_body_callk(lua_State *L) {
    lua_getglobal(L, "coroutine");
    lua_getfield(L, -1, "yield");
    lua_remove(L, -2);
    lua_callk(L, 0, 0, 0, rr_k1);
    printf("RR-AFTER-CALLK\n");
    return 0;
}

static int rr_body_yieldk(lua_State *L) {
    return lua_yieldk(L, 0, 0, rr_k1);
}

static int rr_body_yield(lua_State *L) {
    return lua_yield(L, 0);
}

static void rr_case(lua_State *L, const char *tag, lua_CFunction body) {
    lua_State *co = lua_newthread(L);
    lua_pushcfunction(co, body);
    int nres = 0;
    int rst = lua_resume(co, L, 0, &nres);
    printf("%s-park: rst=%d top=%d\n", tag, rst, lua_gettop(co));
    lua_pushstring(co, "ra");
    rst = lua_resume(co, L, 1, &nres);
    printf("%s-resume2: rst=%d nres=%d status=%d top=%d", tag, rst, nres,
        lua_status(co), lua_gettop(co));
    if (rst == LUA_OK && nres > 0)
        printf(" r0=%s", lua_typename(L, lua_type(co, -1)));
    printf("\n");
}

/* ---- NK: nested continuations (a k that callk's again) -------------- */

static int nk_k2(lua_State *L, int status, lua_KContext ctx) {
    printf("NK-K2: status=%d top=%d\n", status, lua_gettop(L));
    (void)ctx;
    lua_pushstring(L, "k2ret");
    return 1;
}

static int nk_k1(lua_State *L, int status, lua_KContext ctx) {
    printf("NK-K1: status=%d top=%d\n", status, lua_gettop(L));
    (void)ctx;
    lua_getglobal(L, "coroutine");
    lua_getfield(L, -1, "yield");
    lua_remove(L, -2);
    lua_callk(L, 0, 0, 0, nk_k2);
    printf("NK-AFTER-CALLK2\n");
    return 0;
}

static int nk_body(lua_State *L) {
    lua_getglobal(L, "coroutine");
    lua_getfield(L, -1, "yield");
    lua_remove(L, -2);
    lua_callk(L, 0, 0, 0, nk_k1);
    printf("NK-AFTER-CALLK1\n");
    return 0;
}

/* ---- PH: panic-hook terminal (forked child) ------------------------- */

static int ph_hook(lua_State *L) {
    /* Read like the default panic does (lauxlib.c:1060-1071): the object
     * at the top, with the fixed placeholder for a non-string object —
     * the unarmed-yield terminal's object is the reset target's base
     * slot (never a string here), so both engines print the placeholder
     * without locking any below-window value read. */
    const char *m = (lua_type(L, -1) == LUA_TSTRING)
        ? lua_tostring(L, -1)
        : "error object is not a string";
    printf("PH-HOOK: top=%d msg=%s\n", lua_gettop(L), m);
    fflush(stdout);
    return 0;
}

static void ph_run(lua_State *L) {
    lua_State *co = lua_newthread(L);
    lua_getglobal(co, "cyieldn");
    /* raw f(co) with NO pcall and NO armed boundary anywhere */
    lua_CFunction f = lua_tocfunction(co, -1);
    f(co);
    printf("PH-UNREACHABLE\n");
}

static void ph_case(lua_State *L) {
    pid_t pid = fork();
    if (pid == 0) {
        lua_atpanic(L, ph_hook);
        ph_run(L);
        _exit(0);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    if (WIFSIGNALED(st))
        printf("PH: signal=%d\n", WTERMSIG(st));
    else
        printf("PH: exit=%d\n", WEXITSTATUS(st));
}

/* PH2: the DEFAULT panic hook (no atpanic override) — byte-parity of the
 * installed defaultPanic (message + abort) for the unarmed-yield
 * terminal. The child's stderr line lands before the parent's status
 * line (waitpid synchronizes). */
static void ph2_case(lua_State *L) {
    pid_t pid = fork();
    if (pid == 0) {
        ph_run(L);
        _exit(0);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    if (WIFSIGNALED(st))
        printf("PH2: signal=%d\n", WTERMSIG(st));
    else
        printf("PH2: exit=%d\n", WEXITSTATUS(st));
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    lua_pushcfunction(L, probe_raw);
    lua_setglobal(L, "probe_raw");
    lua_pushcfunction(L, probe_yieldk);
    lua_setglobal(L, "probe_yieldk");
    lua_pushcfunction(L, cyieldn);
    lua_setglobal(L, "cyieldn");
    g_co = lua_newthread(L);
    lua_setglobal(L, "co");

    /* R1: chunk-level raw yield, no pcall — dostring absorbs */
    lua_settop(g_co, 0);
    {
        const char *chunk =
            "local r = table.pack(probe_raw(cyieldn, 7, 99, 'co'))\n"
            "print('R1-unreachable: ' .. tostring(r[1]))"; /* abandoned: never runs */
        int st = luaL_dostring(L, chunk);
        printf("R1: dostring_status=%d\n", st);
        print_stack(L, "R1-window");
    }

    /* R2: pcall(lua fn) -> probe_raw */
    lua_settop(L, 0);
    lua_settop(g_co, 0);
    check(L, "local r = table.pack(pcall(function() probe_raw(cyieldn, 5, 6, 'co') print('R2-unreachable') end))\n"
             "print('R2: n=' .. r.n .. ' t1=' .. type(r[1]) .. ' eq=' .. tostring(r[1] == cyieldn)\n"
             "  .. ' v2=' .. tostring(r[2]) .. ' v3=' .. tostring(r[3]) .. ' t4=' .. type(r[4]) .. ' v4=' .. tostring(r[4]))");

    /* R3: xpcall(probe_raw, msgh) — msgh must NOT run */
    lua_settop(L, 0);
    lua_settop(g_co, 0);
    check(L, "local ran = false\n"
             "local r = table.pack(xpcall(probe_raw, function(e) ran = true; return 'HANDLER' end, cyieldn, 8, 10, 'co'))\n"
             "print('R3: n=' .. r.n .. ' t1=' .. type(r[1]) .. ' v1=' .. tostring(r[1]) .. ' v2=' .. tostring(r[2])\n"
             "  .. ' t3=' .. type(r[3]) .. ' v3=' .. tostring(r[3]) .. ' t4=' .. type(r[4]) .. ' v4=' .. tostring(r[4])\n"
             "  .. ' t5=' .. type(r[5]) .. ' v5=' .. tostring(r[5]) .. ' ran=' .. tostring(ran))");

    /* R4: raw pcall on a RUNNING co (armed) + re-resume */
    lua_settop(L, 0);
    check(L, "local c = coroutine.create(function(a)\n"
             "  local x, y = pcall(probe_raw, cyieldn, a, 'b', 'self')\n"
             "  return 'done', tostring(x), tostring(y)\n"
             "end)\n"
             "local r1 = table.pack(coroutine.resume(c, 'A'))\n"
             "print('R4a: n=' .. r1.n .. ' r1=' .. tostring(r1[1]) .. ' eq2=' .. tostring(r1[2] == cyieldn)\n"
             "  .. ' t2=' .. type(r1[2]) .. ' r3=' .. tostring(r1[3]) .. ' r4=' .. tostring(r1[4]) .. ' r5=' .. tostring(r1[5]) .. ' r6=' .. tostring(r1[6]))\n"
             "print('R4b: ' .. coroutine.status(c))\n"
             "local r2 = table.pack(coroutine.resume(c))\n"
             "print('R4c: n=' .. r2.n .. ' r1=' .. tostring(r2[1]) .. ' r2=' .. tostring(r2[2]) .. ' r3=' .. tostring(r2[3]))\n"
             "print('R4d: ' .. coroutine.status(c))");

    /* R5: C lua_yieldk(k=NULL) on a fresh co inside pcall */
    lua_settop(L, 0);
    lua_settop(g_co, 0);
    check(L, "local r = table.pack(pcall(probe_yieldk, 1, 2, 'co'))\n"
             "print('R5: n=' .. r.n .. ' t1=' .. type(r[1]) .. ' v1=' .. tostring(r[1])\n"
             "  .. ' v2=' .. tostring(r[2]) .. ' v3=' .. tostring(r[3]) .. ' t4=' .. type(r[4]) .. ' v4=' .. tostring(r[4]))");

    /* R6: coroutine.close of an ARMED raw-yield-suspended co */
    lua_settop(L, 0);
    check(L, "local c = coroutine.create(function(a)\n"
             "  local x = probe_raw(cyieldn, a, 'z', 'self')\n"
             "  return 'end'\n"
             "end)\n"
             "local r1 = table.pack(coroutine.resume(c, 'Q'))\n"
             "print('R6a: n=' .. r1.n .. ' r1=' .. tostring(r1[1]) .. ' eq2=' .. tostring(r1[2] == cyieldn))\n"
             "local ok, err = coroutine.close(c)\n"
             "print('R6b: ok=' .. tostring(ok) .. ' err=' .. tostring(err) .. ' st=' .. coroutine.status(c))");

    /* R7: host cb on a CO raw-yields on a THIRD fresh co under the co's
     * Lua-level pcall. */
    lua_settop(L, 0);
    lua_settop(g_co, 0);
    check(L, "local c = coroutine.create(function()\n"
             "  local ok, e = pcall(probe_raw, cyieldn, 11, 12, 'gco')\n"
             "  print('R7-inner: ok=' .. tostring(ok) .. ' e=' .. tostring(e))\n"
             "  return 'bodyend'\n"
             "end)\n"
             "local r = table.pack(coroutine.resume(c))\n"
             "print('R7: n=' .. r.n .. ' r1=' .. tostring(r[1]) .. ' r2=' .. tostring(r[2]) .. ' r3=' .. tostring(r[3]))");

    /* R8: pairs regression after all of the above */
    lua_settop(L, 0);
    check(L, "local t = {3, 1, 2}\n"
             "local s = 0\n"
             "for _, v in pairs(t) do s = s + v end\n"
             "print('R8: sum=' .. s)");

    /* RR: re-resume with args of a C-body parked co (args on target) */
    rr_case(L, "RR-callk", rr_body_callk);
    rr_case(L, "RR-yieldk", rr_body_yieldk);
    rr_case(L, "RR-yield", rr_body_yield);

    /* NK: nested continuations */
    {
        lua_State *co = lua_newthread(L);
        lua_pushcfunction(co, nk_body);
        int nres = 0;
        int rst = lua_resume(co, L, 0, &nres);
        printf("NK-park: rst=%d top=%d\n", rst, lua_gettop(co));
        rst = lua_resume(co, L, 0, &nres);
        printf("NK-resume2: rst=%d nres=%d status=%d top=%d\n", rst, nres,
            lua_status(co), lua_gettop(co));
        rst = lua_resume(co, L, 0, &nres);
        printf("NK-resume3: rst=%d nres=%d status=%d top=%d\n", rst, nres,
            lua_status(co), lua_gettop(co));
        if (rst == LUA_OK && nres > 0)
            printf("NK-r0=%s\n", lua_typename(L, lua_type(co, -1)));
    }

    /* TC: to-be-closed mark on the fresh target of an unarmed raw yield:
     * the resetthread closeprotected runs the closer; a closer error
     * (last-error-wins) rethrows on main and the pcall recovers it with
     * the exact object. */
    lua_settop(L, 0);
    lua_settop(g_co, 0);
    {
        const char *setup =
            "local mt = {__close = function(o, e) error('CLOSER-ERR') end}\n"
            "return setmetatable({}, mt), mt";
        if (luaL_dostring(L, setup) != LUA_OK) {
            printf("TC-SETUP-ERR\n");
            lua_pop(L, 1);
        } else {
            /* stack: [t, mt] — drop mt, move t to the target as its
             * to-be-closed mark (t stays rooted on the target's stack;
             * the target itself is rooted via the global). */
            lua_pop(L, 1);
            lua_xmove(L, g_co, 1);
            lua_toclose(g_co, 1);
            check(L, "local ok, e = pcall(function() probe_raw(cyieldn, 1, 2, 'gco') end)\n"
                     "print('TC: ok=' .. tostring(ok) .. ' e=' .. tostring(e))");
        }
    }

    /* TC2: successful closer (no error) — the absorption stays OK and
     * the pcall returns the stale-anchored window as success results. */
    lua_settop(L, 0);
    lua_settop(g_co, 0);
    {
        const char *setup =
            "local mt = {__close = function(o, e) end}\n"
            "return setmetatable({}, mt), mt";
        if (luaL_dostring(L, setup) != LUA_OK) {
            printf("TC2-SETUP-ERR\n");
            lua_pop(L, 1);
        } else {
            lua_pop(L, 1); /* mt */
            lua_xmove(L, g_co, 1);
            lua_toclose(g_co, 1);
            check(L, "local r = table.pack(pcall(function() probe_raw(cyieldn, 21, 22, 'gco') end))\n"
                     "print('TC2: n=' .. r.n .. ' t1=' .. type(r[1]) .. ' eq1=' .. tostring(r[1] == cyieldn)\n"
                     "  .. ' v2=' .. tostring(r[2]) .. ' v3=' .. tostring(r[3]) .. ' t4=' .. type(r[4]) .. ' v4=' .. tostring(r[4])\n"
                     "  .. ' t5=' .. type(r[5]) .. ' v5=' .. tostring(r[5]))");
        }
    }

    /* PH: panic-hook terminal (forked, custom hook) */
    ph_case(L);

    /* PH2: default panic hook (forked, no override) */
    ph2_case(L);

    lua_close(L);
    printf("SUITE-44-DONE fails=%d\n", fails);
    return fails != 0;
}
