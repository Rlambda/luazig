/*
** 25_tbc_closer_escape — closer-error escape in yieldable (yy=1)
** unprotected closes, C lane.
**
** PUC 5.5 yy table: a closer error during a YIELDABLE close
** (luaD_poscall/moveresults C-return, finishpcallk recovery) longjmps OUT
** of luaF_close — nothing closes the remaining marks inside the close;
** they defer to the recovery boundary (an outer pcall's closeprotected
** re-drive or coroutine.close/lua_closethread, which close them with the
** then-current error object, last-error-wins across re-drives).
** Protected/forced closes (luaD_closeprotected, yy=0 + pcall wrapper)
** keep the catch-and-re-drive close-all behavior.
**
**   CE-1  C-return lane: a C body marks 3 values toclose (lua_toclose)
**         and returns; the NEWEST closer errors on the clean return close
**         (moveresults, yy=1) — the close stops, the two older marks
**         defer to lua_closethread, which closes both with the closer's
**         error (LIFO) and reports the error itself.
**
**   CE-2  pcallk recovery lane: a C body calls lua_pcallk on a Lua
**         callee with two <close> vars; the callee errors, the recovery
**         close (finishpcallk, yy=1) runs the newest closer with the
**         original error, that closer errors — the close stops, the
**         recovery re-drive closes the older mark with the NEW error
**         (last-error-wins) before the K continuation runs with the
**         final error object.
**
**   CE-3  CLSRET return_close, yield-then-error: the newest closer first
**         yields (the C-return close parks, results saved) and errors
**         when resumed — the saved results are DISCARDED (the poscall
**         never completes), the error escapes to the failed resume, and
**         the older mark defers to lua_closethread.
**
**   CE-4  forced close (lua_closethread on a coroutine suspended in
**         bytecode with two <close> vars, newest closer errors):
**         closeprotected, yy=0 — the close CONTINUES past the closer
**         error; every mark closes, last-error-wins, and the close
**         reports the error.
**
** Excluded (documented pre-existing divergences, see the stage report):
** (a) lua_settop/lua_closeslot truncation closes — PUC runs them
** UNWRAPPED (yy=0, no closeprotected), so a closer error escapes
** immediately and the remaining marks defer; luazig continues eagerly
** and the apiSettop call site swallows the error (pcall observes
** success). (The former exclusion (b) — forced close of a coroutine
** suspended inside a C call with lua_toclose marks — is fixed and
** covered by 26_tbc_forced_close_cbody.)
**
** Determinism rules (same as 22/23/24): only fixed labels, statuses and
** controlled strings are printed; error objects are strings raised from
** fixed source positions (identical position prefixes on both runtimes).
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* CE-1 body: mark OBJ1, OBJ2, OBJ3 (LIFO: OBJ3 closes first), return. */
static int c_body_mark3(lua_State *L) {
    lua_getglobal(L, "OBJ1");
    lua_toclose(L, -1);
    lua_getglobal(L, "OBJ2");
    lua_toclose(L, -1);
    lua_getglobal(L, "OBJ3");
    lua_toclose(L, -1);
    lua_pushliteral(L, "c-done");
    return 1;
}

/* CE-2 K continuation: report the status; on error return the error
** object on top (pcallk places it before K runs). */
static int k_report(lua_State *L, int status, lua_KContext ctx) {
    (void)ctx;
    if (status != LUA_OK) {
        printf("CE-2 K: status=%d err=%s\n", status,
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        return 1;  /* the error object */
    }
    printf("CE-2 K: status=%d\n", status);
    return lua_gettop(L);
}

/* CE-2 body: pcallk the callee (arg 1) from inside the coroutine. */
static int c_body_pcallk(lua_State *L) {
    lua_pushvalue(L, 1);
    return lua_pcallk(L, 0, LUA_MULTRET, 0, (lua_KContext)0, k_report);
}

/* CE-3 body: mark OBJ1 (older, plain logger), OBJ2 (newest: yields then
** errors), return — the return close parks on OBJ2's yield. */
static int c_body_yield_err(lua_State *L) {
    lua_getglobal(L, "OBJ1");
    lua_toclose(L, -1);
    lua_getglobal(L, "OBJ2");
    lua_toclose(L, -1);
    lua_pushliteral(L, "c-done");
    return 1;
}

/* CE-4 needs no C body: the coroutine suspends in bytecode (yield inside
** a Lua body with the <close> vars); lua_closethread force-closes it. */

/* Print a resume status with the top-of-stack string. */
static void report(const char *label, int st, int nres, lua_State *co) {
    printf("%s: st=%d nres=%d val=%s\n", label, st, nres,
           (nres > 0 && lua_isstring(co, -1)) ? lua_tostring(co, -1)
                                              : (nres > 0
                                                     ? lua_typename(
                                                           co, lua_type(co, -1))
                                                     : "-"));
}

/* Run one coroutine case: objsrc defines LOG globals, bodysrc is the
** coroutine factory body source (references CBODY when body != NULL),
** and the scenario drives resumes + closethread per `mode`:
**   1 = one resume (expect error) + closethread
**   2 = one resume (pcallk catches; K returns) + closethread (no-op)
**   3 = resume (yield) + resume (error) + closethread
**   4 = one resume (yield) + closethread (forced, expect error)
*/
static int run_case(int mode, const char *objsrc, const char *bodysrc,
                    lua_CFunction body) {
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
    if (body) {
        lua_pushcfunction(L, body);
        lua_setglobal(L, "CBODY");
    }
    /* co = coroutine.create(function() return CBODY() end) — bodysrc is
    ** the factory source returning the body closure. */
    lua_getglobal(L, "coroutine");
    lua_getfield(L, -1, "create");
    lua_remove(L, -2);
    if (luaL_loadstring(L, bodysrc) != 0 || lua_pcall(L, 0, 1, 0) != 0 ||
        lua_pcall(L, 1, 1, 0) != 0) {
        printf("FAIL: create: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return 1;
    }
    lua_State *co = lua_tothread(L, -1);
    if (!co) {
        printf("FAIL: not a thread\n");
        lua_close(L);
        return 1;
    }
    {
        int nres = 0;
        int st;
        if (mode == 1 || mode == 2 || mode == 3 || mode == 4) {
            st = lua_resume(co, L, 0, &nres);
            report("resume1", st, nres, co);
        }
        if (mode == 3) {
            st = lua_resume(co, L, 0, &nres);
            report("resume2", st, nres, co);
        }
        /* lua_closethread returns the status only (it pushes nothing on
        ** L); the error object each deferred closer received is already
        ** observable through the log below. */
        st = lua_closethread(co, L);
        printf("closethread: st=%d\n", st);
    }
    /* Print the close log from the setup globals. */
    lua_getglobal(L, "table");
    lua_getfield(L, -1, "concat");
    lua_remove(L, -2);
    lua_getglobal(L, "LOG");
    if (lua_pcall(L, 1, 1, 0) != 0) {
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
    printf("=== 25_tbc_closer_escape: yy=1 closer-error escape (C lane) ===\n");

    /* CE-1: three marks, newest errors on the clean C-return close. */
    if (run_case(1,
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
                 "  error('cerr')\n"
                 "end})\n",
                 "return function() return CBODY() end",
                 c_body_mark3))
        return 1;

    /* CE-2: pcallk recovery — callee errors, newest closer errors during
    ** the recovery close, re-drive closes the older with the new error. */
    if (run_case(2,
                 "local log = {}\n"
                 "LOG = log\n"
                 "CALLEE = function()\n"
                 "  local v1 <close> = setmetatable({}, {__close = function(_, err)\n"
                 "    log[#log+1] = 'v1:'..tostring(err)\n"
                 "  end})\n"
                 "  local v2 <close> = setmetatable({}, {__close = function(_, err)\n"
                 "    log[#log+1] = 'v2:'..tostring(err)\n"
                 "    error('c2')\n"
                 "  end})\n"
                 "  error('orig')\n"
                 "end\n",
                 "return function() return CBODY(CALLEE) end",
                 c_body_pcallk))
        return 1;

    /* CE-3: newest closer yields then errors — parked return close
    ** resumes into the error; saved results discarded. */
    if (run_case(3,
                 "local log = {}\n"
                 "LOG = log\n"
                 "OBJ1 = setmetatable({}, {__close = function(_, err)\n"
                 "  log[#log+1] = 'o1:'..tostring(err)\n"
                 "end})\n"
                 "OBJ2 = setmetatable({}, {__close = function(_, err)\n"
                 "  log[#log+1] = 'o2:'..tostring(err)\n"
                 "  coroutine.yield('inclose')\n"
                 "  error('yerr')\n"
                 "end})\n",
                 "return function() return CBODY() end",
                 c_body_yield_err))
        return 1;

    /* CE-4: forced close of a coroutine suspended in bytecode —
    ** closeprotected continues past the closer error; every mark
    ** closes. */
    if (run_case(4,
                 "local log = {}\n"
                 "LOG = log\n",
                 "return function()\n"
                 "  local v1 <close> = setmetatable({}, {__close = function(_, err)\n"
                 "    LOG[#LOG+1] = 'v1:'..tostring(err)\n"
                 "  end})\n"
                 "  local v2 <close> = setmetatable({}, {__close = function(_, err)\n"
                 "    LOG[#LOG+1] = 'v2:'..tostring(err)\n"
                 "    error('ferr')\n"
                 "  end})\n"
                 "  coroutine.yield('susp')\n"
                 "end",
                 NULL))
        return 1;

    printf("=== 25_tbc_closer_escape DONE ===\n");
    return 0;
}
