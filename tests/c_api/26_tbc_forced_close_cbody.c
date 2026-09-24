/*
** 26_tbc_forced_close_cbody — forced close (lua_closethread) of a
** coroutine suspended INSIDE a C call with lua_toclose marks.
**
** PUC 5.5 semantics (lua_closethread -> luaE_resetthread ->
** luaD_closeprotected(L, 1, LUA_OK)): the whole to-be-closed chain of
** the thread closes as ONE region — every live mark (C-frame
** lua_toclose marks AND Lua-frame <close> vars), strict LIFO
** (newest first), yy=0 (a closer error does not stop the close; the
** remaining closers receive the current error object, last-error-wins
** for the final status), closers run on the target thread, and a
** suspended C body's continuation (lua_KFunction) is NEVER invoked —
** the C frames are discarded (luaE_resetthread resets the whole call
** stack) before the close starts, with each mark's value detached
** from its (already dead) stack slot.
**
**   FC-1  two marks, plain loggers: every closer runs exactly once,
**         LIFO, err=nil, LUA_OK; a second lua_closethread on the dead
**         thread is a no-op (LUA_OK).
**
**   FC-2  three marks: same, strict LIFO o3 -> o2 -> o1.
**
**   FC-3  newest closer errors: the close CONTINUES; the older closer
**         receives the error object; status = the closer's error.
**
**   FC-4  middle (of three) closer errors: newest closes clean, the
**         errored middle closes clean then errors, the oldest receives
**         the middle's error; status = that error.
**
**   FC-5  multiple erroring closers + non-string error object: the
**         newest errors with a table (custom __tostring), a plain
**         closer and an erroring closer receive the TABLE (identity
**         preserved, no string coercion), the oldest receives the
**         LAST error (string) — last-error-wins. A full GC between
**         the suspension and the close must not collect the detached
**         mark values; the second closethread is again a no-op.
**
**   FC-6  alias: the SAME object in two marks closes TWICE (no
**         identity dedup), LIFO, LUA_OK.
**
**   FC-7  non-NULL lua_KFunction + yield WITH a value: the
**         continuation is NOT invoked by the forced close (K-RAN
**         never appears in the log).
**
**   FC-8  nested C frames + mixed Lua <close>: the coroutine body has
**         a Lua <close> var and calls a C body that marks OBJ1 and
**         lua_callk's a nested C function (continuation installed)
**         that marks OBJ2 and yields. Forced close: both C frames are
**         discarded (no continuation runs), the C marks close LIFO
**         (o2, o1), then the older Lua <close> var (lv); LUA_OK.
**
**   FC-9  cross-frame error threading: the NESTED frame's closer
**         errors; the OUTER frame's older mark receives that error —
**         the marks of BOTH C frames close as ONE region (a frame-
**         local close would hand the outer closer nil instead).
**
** Determinism rules (same as 22-25): only fixed labels, statuses and
** controlled strings are printed; error objects are raised with level
** 0 (error(msg, 0)) so no source-position prefixes appear; the log is
** read back through the C API and printed with printf only (no Lua
** print — stdout interleaving differs between runtimes).
*/
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* FC-7/FC-8 K continuation: must NEVER run under a forced close; if it
** does, KRAN appends the marker to the log and the diff goes RED. */
static int k_never(lua_State *L, int status, lua_KContext ctx) {
    (void)status; (void)ctx;
    lua_getglobal(L, "KRAN");
    lua_call(L, 0, 0);
    return 0;
}

/* FC-1/FC-3 body: mark OBJ1, OBJ2 (LIFO: OBJ2 closes first), yield. */
static int c_body_mark2(lua_State *L) {
    lua_getglobal(L, "OBJ1");
    lua_toclose(L, -1);
    lua_getglobal(L, "OBJ2");
    lua_toclose(L, -1);
    return lua_yieldk(L, 0, (lua_KContext)0, NULL);
}

/* FC-2/FC-4 body: mark OBJ1..OBJ3 (LIFO: OBJ3 first), yield. */
static int c_body_mark3(lua_State *L) {
    lua_getglobal(L, "OBJ1");
    lua_toclose(L, -1);
    lua_getglobal(L, "OBJ2");
    lua_toclose(L, -1);
    lua_getglobal(L, "OBJ3");
    lua_toclose(L, -1);
    return lua_yieldk(L, 0, (lua_KContext)0, NULL);
}

/* FC-5 body: mark OBJ0..OBJ3 (LIFO: OBJ3 first), yield. */
static int c_body_mark4(lua_State *L) {
    lua_getglobal(L, "OBJ0");
    lua_toclose(L, -1);
    lua_getglobal(L, "OBJ1");
    lua_toclose(L, -1);
    lua_getglobal(L, "OBJ2");
    lua_toclose(L, -1);
    lua_getglobal(L, "OBJ3");
    lua_toclose(L, -1);
    return lua_yieldk(L, 0, (lua_KContext)0, NULL);
}

/* FC-6 body: the SAME object in two marks (alias, no dedup), yield. */
static int c_body_alias(lua_State *L) {
    lua_getglobal(L, "OBJX");
    lua_toclose(L, -1);
    lua_getglobal(L, "OBJX");
    lua_toclose(L, -1);
    return lua_yieldk(L, 0, (lua_KContext)0, NULL);
}

/* FC-7 body: mark OBJ1, OBJ2, yield WITH a value and a non-NULL K. */
static int c_body_yieldval(lua_State *L) {
    lua_getglobal(L, "OBJ1");
    lua_toclose(L, -1);
    lua_getglobal(L, "OBJ2");
    lua_toclose(L, -1);
    lua_pushliteral(L, "yv");
    return lua_yieldk(L, 1, (lua_KContext)42, k_never);
}

/* FC-8 nested body: mark OBJ2, yield (suspends inside the nested C
** frame; the outer C frame keeps its lua_callk continuation). */
static int c_nested(lua_State *L) {
    lua_getglobal(L, "OBJ2");
    lua_toclose(L, -1);
    return lua_yieldk(L, 0, (lua_KContext)0, NULL);
}

/* FC-8 outer body: mark OBJ1, then lua_callk NESTED (continuation
** installed on this C frame). */
static int c_body_callk(lua_State *L) {
    lua_getglobal(L, "OBJ1");
    lua_toclose(L, -1);
    lua_getglobal(L, "NESTED");
    lua_callk(L, 0, 1, (lua_KContext)7, k_never);
    return 1;
}

/* FC-10..13 middle C body: mark OBJ2, then lua_callk LUA_MID3 (its
** local <close> obligation sits BETWEEN this C frame's mark and the
** innermost C mark in the global LIFO order). */
static int c_ilv_mid2(lua_State *L) {
    lua_getglobal(L, "OBJ2");
    lua_toclose(L, -1);
    lua_getglobal(L, "LUA_MID3");
    lua_callk(L, 0, 0, (lua_KContext)0, k_never);
    return 0;
}

/* FC-10..13 outer C body: mark OBJ1, then lua_callk LUA_MID (a LIVE
** Lua frame with a <close> local sits between this C frame and the
** inner C frames at the suspension point). */
static int c_ilv_outer(lua_State *L) {
    lua_getglobal(L, "OBJ1");
    lua_toclose(L, -1);
    lua_getglobal(L, "LUA_MID");
    lua_callk(L, 0, 0, (lua_KContext)0, k_never);
    return 0;
}

/* Interleaved-case runner: registers the C bodies the alternation
** shapes need (CBODY outer, NESTED innermost marker, NESTED2 middle
** caller); the Lua middle functions come from objsrc as LUA_MID /
** LUA_MID3. gcflag: two full GCs between the suspension and the close. */
static int run_il(const char *objsrc, const char *cosrc, int gcflag) {
    lua_State *L = luaL_newstate();
    if (!L) {
        printf("FAIL: newstate\n");
        return 1;
    }
    luaL_openlibs(L);
    if (luaL_dostring(L, objsrc) != 0) {
        printf("FAIL: setup: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return 1;
    }
    lua_pushcfunction(L, c_ilv_outer);
    lua_setglobal(L, "CBODY");
    lua_pushcfunction(L, c_nested);
    lua_setglobal(L, "NESTED");
    lua_pushcfunction(L, c_ilv_mid2);
    lua_setglobal(L, "NESTED2");
    if (luaL_dostring(L, cosrc) != 0) {
        printf("FAIL: create: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return 1;
    }
    lua_getglobal(L, "co");
    lua_State *co = lua_tothread(L, -1);
    if (!co) {
        printf("FAIL: not a thread\n");
        lua_close(L);
        return 1;
    }
    {
        int nres = 0;
        int st = lua_resume(co, L, 0, &nres);
        printf("resume1: st=%d nres=%d\n", st, nres);
        if (gcflag) {
            lua_gc(L, LUA_GCCOLLECT, 0);
            lua_gc(L, LUA_GCCOLLECT, 0);
        }
        st = lua_closethread(co, L);
        printf("closethread: st=%d\n", st);
        st = lua_closethread(co, L);
        printf("closethread2: st=%d\n", st);
    }
    lua_getglobal(L, "table");
    lua_getfield(L, -1, "concat");
    lua_remove(L, -2);
    lua_getglobal(L, "LOG");
    lua_pushliteral(L, ",");
    if (lua_pcall(L, 2, 1, 0) != 0) {
        printf("FAIL: log: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return 1;
    }
    printf("log: %s\n", lua_tostring(L, -1));
    lua_pop(L, 2);
    lua_close(L);
    return 0;
}

/* Run one coroutine case: objsrc defines the LOG/OBJ globals, cosrc is
** the coroutine.create body source (references CBODY/NESTED), body is
** the C entry. gcflag: run two full GCs between the suspension and the
** close (detached mark values must survive them). */
static int run_case(const char *objsrc, const char *cosrc, lua_CFunction body,
                    int gcflag) {
    lua_State *L = luaL_newstate();
    if (!L) {
        printf("FAIL: newstate\n");
        return 1;
    }
    luaL_openlibs(L);
    if (luaL_dostring(L, objsrc) != 0) {
        printf("FAIL: setup: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return 1;
    }
    lua_pushcfunction(L, body);
    lua_setglobal(L, "CBODY");
    lua_pushcfunction(L, c_nested);
    lua_setglobal(L, "NESTED");
    if (luaL_dostring(L, cosrc) != 0) {
        printf("FAIL: create: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return 1;
    }
    lua_getglobal(L, "co");
    lua_State *co = lua_tothread(L, -1);
    if (!co) {
        printf("FAIL: not a thread\n");
        lua_close(L);
        return 1;
    }
    {
        int nres = 0;
        int st = lua_resume(co, L, 0, &nres);
        printf("resume1: st=%d nres=%d\n", st, nres);
        if (gcflag) {
            lua_gc(L, LUA_GCCOLLECT, 0);
            lua_gc(L, LUA_GCCOLLECT, 0);
        }
        /* lua_closethread returns the status only (pushes nothing on
        ** L); the error object each closer received is observable
        ** through the log below. */
        st = lua_closethread(co, L);
        printf("closethread: st=%d\n", st);
        /* Repeated close on the dead thread: idempotent no-op. */
        st = lua_closethread(co, L);
        printf("closethread2: st=%d\n", st);
    }
    /* Read the close log back through the C API (printf-only output:
    ** Lua print interleaves differently between the runtimes). */
    lua_getglobal(L, "table");
    lua_getfield(L, -1, "concat");
    lua_remove(L, -2);
    lua_getglobal(L, "LOG");
    lua_pushliteral(L, ",");
    if (lua_pcall(L, 2, 1, 0) != 0) {
        printf("FAIL: log: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return 1;
    }
    printf("log: %s\n", lua_tostring(L, -1));
    lua_pop(L, 2);  /* log result + co */
    lua_close(L);
    return 0;
}

int main(void) {
    /* Unbuffered stdout: if a runtime dies on a signal mid-suite, every
    ** line printed before the crash is still visible in the lane logs. */
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== 26_tbc_forced_close_cbody: forced close, C-body suspension ===\n");

    /* FC-1: two marks, plain loggers; clean LIFO close + idempotent
    ** second close. */
    if (run_case(
            "local log = {}\n"
            "LOG = log\n"
            "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o1:'..tostring(err)\n"
            "end})\n"
            "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o2:'..tostring(err)\n"
            "end})\n",
            "co = coroutine.create(function() return CBODY() end)",
            c_body_mark2, 0))
        return 1;
    printf("\n");

    /* FC-2: three marks, strict LIFO. */
    if (run_case(
            "local log = {}\n"
            "LOG = log\n"
            "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o1:'..tostring(err)\n"
            "end})\n"
            "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o2:'..tostring(err)\n"
            "end})\n"
            "OBJ3 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o3:'..tostring(err)\n"
            "end})\n",
            "co = coroutine.create(function() return CBODY() end)",
            c_body_mark3, 0))
        return 1;
    printf("\n");

    /* FC-3: newest closer errors — the close continues, the older
    ** closer receives the error, status = the error. */
    if (run_case(
            "local log = {}\n"
            "LOG = log\n"
            "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o1:'..tostring(err)\n"
            "end})\n"
            "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o2:'..tostring(err)\n"
            "  error('ferr', 0)\n"
            "end})\n",
            "co = coroutine.create(function() return CBODY() end)",
            c_body_mark2, 0))
        return 1;
    printf("\n");

    /* FC-4: middle (of three) closer errors — newest closes clean, the
    ** oldest receives the middle's error. */
    if (run_case(
            "local log = {}\n"
            "LOG = log\n"
            "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o1:'..tostring(err)\n"
            "end})\n"
            "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o2:'..tostring(err)\n"
            "  error('m2', 0)\n"
            "end})\n"
            "OBJ3 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o3:'..tostring(err)\n"
            "end})\n",
            "co = coroutine.create(function() return CBODY() end)",
            c_body_mark3, 0))
        return 1;
    printf("\n");

    /* FC-5: multiple erroring closers + non-string error object + GC
    ** between suspension and close + idempotent re-close. OBJ3 errors
    ** with a table (custom __tostring); OBJ1 errors with a string; the
    ** final error (last-error-wins) is OBJ1's string. */
    if (run_case(
            "local log = {}\n"
            "LOG = log\n"
            "EOTBL = setmetatable({}, {__tostring = function() return 'ET' end})\n"
            "OBJ0 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o0:'..tostring(err)\n"
            "end})\n"
            "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o1:'..tostring(err)\n"
            "  error('e1', 0)\n"
            "end})\n"
            "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o2:'..tostring(err)\n"
            "end})\n"
            "OBJ3 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o3:'..tostring(err)\n"
            "  error(EOTBL, 0)\n"
            "end})\n",
            "co = coroutine.create(function() return CBODY() end)",
            c_body_mark4, 1))
        return 1;
    printf("\n");

    /* FC-6: alias — the same object in two marks closes twice. */
    if (run_case(
            "local log = {}\n"
            "LOG = log\n"
            "OBJX = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'x:'..tostring(err)\n"
            "end})\n",
            "co = coroutine.create(function() return CBODY() end)",
            c_body_alias, 0))
        return 1;
    printf("\n");

    /* FC-7: non-NULL K + yield with a value — the continuation must
    ** NOT run (no K-RAN in the log). */
    if (run_case(
            "local log = {}\n"
            "LOG = log\n"
            "KRAN = function() log[#log+1] = 'K-RAN' end\n"
            "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o1:'..tostring(err)\n"
            "end})\n"
            "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o2:'..tostring(err)\n"
            "end})\n",
            "co = coroutine.create(function() return CBODY() end)",
            c_body_yieldval, 0))
        return 1;
    printf("\n");

    /* FC-8: nested C frames + mixed Lua <close> — C marks close LIFO
    ** first, then the older Lua var; no continuation runs. */
    if (run_case(
            "local log = {}\n"
            "LOG = log\n"
            "KRAN = function() log[#log+1] = 'K-RAN' end\n"
            "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o1:'..tostring(err)\n"
            "end})\n"
            "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o2:'..tostring(err)\n"
            "end})\n",
            "co = coroutine.create(function()\n"
            "  local lv <close> = setmetatable({}, {__close = function(_, err)\n"
            "    LOG[#LOG+1] = 'lv:'..tostring(err)\n"
            "  end})\n"
            "  local r = CBODY()\n"
            "  return r\n"
            "end)",
            c_body_callk, 0))
        return 1;
    printf("\n");

    /* FC-9: cross-frame error threading — the nested frame's closer
    ** errors; the outer frame's older mark receives that error. */
    if (run_case(
            "local log = {}\n"
            "LOG = log\n"
            "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o1:'..tostring(err)\n"
            "end})\n"
            "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'o2:'..tostring(err)\n"
            "  error('nerr', 0)\n"
            "end})\n",
            "co = coroutine.create(function() return CBODY() end)",
            c_body_callk, 0))
        return 1;

    /* FC-10: INTERLEAVED obligations — C mark, a LIVE Lua frame with a
    ** <close> local (via lua_callk), a newer C mark, yield. The forced
    ** close must run the closers in the GLOBAL LIFO order c2, lua2, c1
    ** (PUC's single tbclist), not c2, c1, lua2. Statuses alone do not
    ** distinguish the orders — the log does. */
    if (run_il(
            "local log = {}\n"
            "LOG = log\n"
            "KRAN = function() log[#log+1] = 'K-RAN' end\n"
            "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'c1:'..tostring(err)\n"
            "end})\n"
            "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'c2:'..tostring(err)\n"
            "end})\n"
            "LUA_MID = function()\n"
            "  local x2 <close> = setmetatable({}, {__close = function(_, err)\n"
            "    log[#log+1] = 'lua2:'..tostring(err)\n"
            "  end})\n"
            "  return NESTED()\n"
            "end\n",
            "co = coroutine.create(function() return CBODY() end)",
            0))
        return 1;
    printf("\n");

    /* FC-11: TWO alternations — C1, Lua2, C2, Lua3, C3, yield. Order
    ** must be c3, lua3, c2, lua2, c1. */
    if (run_il(
            "local log = {}\n"
            "LOG = log\n"
            "KRAN = function() log[#log+1] = 'K-RAN' end\n"
            "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'c1:'..tostring(err)\n"
            "end})\n"
            "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'c2:'..tostring(err)\n"
            "end})\n"
            "OBJ3 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'c3:'..tostring(err)\n"
            "end})\n"
            "LUA_MID = function()\n"
            "  local x2 <close> = setmetatable({}, {__close = function(_, err)\n"
            "    log[#log+1] = 'lua2:'..tostring(err)\n"
            "  end})\n"
            "  return NESTED2()\n"
            "end\n"
            "LUA_MID3 = function()\n"
            "  local x3 <close> = setmetatable({}, {__close = function(_, err)\n"
            "    log[#log+1] = 'lua3:'..tostring(err)\n"
            "  end})\n"
            "  return NESTED()\n"
            "end\n",
            "co = coroutine.create(function() return CBODY() end)",
            0))
        return 1;
    printf("\n");

    /* FC-12a: the interleaved LUA closer errors — the close continues
    ** through the older C obligation with the new error object
    ** (last-error-wins; final status LUA_ERRRUN). */
    if (run_il(
            "local log = {}\n"
            "LOG = log\n"
            "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'c1:'..tostring(err)\n"
            "end})\n"
            "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'c2:'..tostring(err)\n"
            "end})\n"
            "LUA_MID = function()\n"
            "  local x2 <close> = setmetatable({}, {__close = function(_, err)\n"
            "    log[#log+1] = 'lua2:'..tostring(err)\n"
            "    error('lerr', 0)\n"
            "  end})\n"
            "  return NESTED()\n"
            "end\n",
            "co = coroutine.create(function() return CBODY() end)",
            0))
        return 1;
    printf("\n");

    /* FC-12b: the interleaved INNER C closer errors — the Lua and the
    ** older C obligations receive the error object in order. */
    if (run_il(
            "local log = {}\n"
            "LOG = log\n"
            "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'c1:'..tostring(err)\n"
            "end})\n"
            "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'c2:'..tostring(err)\n"
            "  error('cerr', 0)\n"
            "end})\n"
            "LUA_MID = function()\n"
            "  local x2 <close> = setmetatable({}, {__close = function(_, err)\n"
            "    log[#log+1] = 'lua2:'..tostring(err)\n"
            "  end})\n"
            "  return NESTED()\n"
            "end\n",
            "co = coroutine.create(function() return CBODY() end)",
            0))
        return 1;
    printf("\n");

    /* FC-13: interleaved + GC between suspension and close + non-string
    ** error object identity through the alternation. */
    if (run_il(
            "local log = {}\n"
            "LOG = log\n"
            "EOTBL = setmetatable({}, {__tostring = function() return 'ET' end})\n"
            "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'c1:'..tostring(err)\n"
            "end})\n"
            "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
            "  log[#log+1] = 'c2:'..tostring(err)\n"
            "end})\n"
            "LUA_MID = function()\n"
            "  local x2 <close> = setmetatable({}, {__close = function(_, err)\n"
            "    log[#log+1] = 'lua2:'..tostring(err)\n"
            "    error(EOTBL, 0)\n"
            "  end})\n"
            "  return NESTED()\n"
            "end\n",
            "co = coroutine.create(function() return CBODY() end)",
            1))
        return 1;

    printf("=== 26_tbc_forced_close_cbody DONE ===\n");
    return 0;
}
