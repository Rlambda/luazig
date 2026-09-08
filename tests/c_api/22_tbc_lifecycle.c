/*
** 22_tbc_lifecycle.c — P16.30 T1: C-frame to-be-closed (lua_toclose)
** ownership lifecycle. PERMANENT differential suite (luazig vs PUC 5.5).
**
** Three known defects under test (all in C-frame TBC ownership):
**
**   T1.A (crash): a C function marks a TBC slot (lua_toclose) and calls
**        a yielding Lua function through lua_pcallk; the coroutine
**        suspends; closing the suspended coroutine (Lua coroutine.close
**        or C lua_closethread) SIGSEGVs luazig.
**        PUC: lua_closethread -> luaE_resetthread -> luaD_closeprotected
**        -> luaF_close walks the per-thread tbclist (independent of any
**        CallInfo) and runs __close with no error object.
**
**   T1.B (freed-not-closed): the same suspension shape with the C
**        function as the coroutine BODY (no Lua frames at all): luazig
**        frees the C-frame-owned TBC state WITHOUT running __close
**        (close_calls stays 0). PUC: close_calls == 1.
**
**   T1.C (dropped at normal return): toclose + yieldable lua_callk; the
**        coroutine is resumed normally and the C function returns;
**        luazig drops the pending TBC (close_calls == 0). PUC closes it
**        exactly once at C-function return (luaD_poscall -> moveresults
**        -> luaF_close), closing the CURRENT slot value: the tbclist
**        stores stack LEVELS, not values (live-slot semantics, G3b).
**
** Group 4 is the general lifecycle matrix: single TBC, LIFO order of two
** marks, explicit lua_closeslot (top slot only), erroring closers (error
** object visibility + last-error-wins), __close that yields during the
** normal-return close (yieldable close: PUC moveresults calls luaF_close
** with yy=1, so a C closer may lua_yieldk), pcallk error recovery (k gets
** the error status), yield -> resume -> error -> close (TBC survives the
** error unwind in the per-thread tbclist and is closed by closethread
** with the in-flight error object), nested C frames (LIFO across frames),
** nested coroutines, and GC between mark and close (the suspended
** coroutine's stack slot must anchor the object; the closer must run on
** the LIVE object).
**
** Determinism rules for the differential lane:
**   - only fixed labels, integers, statuses and controlled strings are
**     printed (no pointers, no tostring() of tables/threads);
**   - error objects are always plain strings raised from C (lua_error)
**     or error(msg, 0) from Lua, so they carry no position prefix;
**   - __close recorders read the object's `name` FIELD instead of
**     tostring(obj) (a table tostring embeds its address). For the same
**     reason the G3b live-slot mutation replaces the marked slot with a
**     second closable OBJECT (named "G3bB") rather than a string: a
**     string in a TBC slot has no __close metamethod, which would send
**     the close down a nondeterministic error path.
**
** The crash case (Group 1) runs FIRST on purpose: if the runtime dies
** there, the process exits on a signal (rc 139) and the lane fails —
** later groups simply do not run on that runtime. stdout is unbuffered
** so everything printed before a crash is preserved.
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* ------------------------------------------------------------------ */
/* Deterministic event log: __close recorders append labeled events.  */
/* No pointers, no addresses — only names, error strings and notes.   */
/* ------------------------------------------------------------------ */

static int close_calls;
static char evlog[1024];

static void log_reset(void) {
    close_calls = 0;
    evlog[0] = '\0';
}

static void log_close(const char *name, const char *err) {
    size_t len = strlen(evlog);
    close_calls++;
    snprintf(evlog + len, sizeof(evlog) - len, "%sname=%s err=%s",
             len ? "; " : "", name, err);
}

static void log_note(const char *note) {
    size_t len = strlen(evlog);
    snprintf(evlog + len, sizeof(evlog) - len, "%s%s", len ? "; " : "", note);
}

static void log_note_i(const char *note, int v) {
    size_t len = strlen(evlog);
    snprintf(evlog + len, sizeof(evlog) - len, "%s%s%d", len ? "; " : "", note, v);
}

/* ------------------------------------------------------------------ */
/* __close metamethods (C functions used as closers)                  */
/* ------------------------------------------------------------------ */

/*
** Recording closer. __close receives (obj) on a normal close (no error
** object — PUC callclosemethod passes err == NULL for LUA_OK/CLOSEKTOP)
** or (obj, err) when closing over an error. Records the object's `name`
** field and the error argument (if any), then — if the object has a
** `raise` field — raises it as the close error (for erroring-closer
** cases). The raise value is left on top of the stack for lua_error.
*/
static int c_close_maybe_error(lua_State *L) {
    const char *name = "noname";
    const char *err = "none";
    int nargs = lua_gettop(L);
    lua_getfield(L, 1, "name");
    if (lua_isstring(L, -1))
        name = lua_tostring(L, -1);
    if (nargs >= 2) {  /* closing over an error: err is argument 2 */
        if (lua_isstring(L, 2))
            err = lua_tostring(L, 2);
        else
            err = "<nonstring>";
    }
    log_close(name, err);
    lua_getfield(L, 1, "raise");
    if (!lua_isnil(L, -1))  /* `raise` string is on top: error with it */
        return lua_error(L);
    lua_pop(L, 2);  /* name + raise fields */
    return 0;
}

/*
** Yielding closer: records like c_close_maybe_error, then yields. Only
** usable when the close is yieldable (PUC luaF_close yy=1: the normal-
** return close inside a coroutine). Its continuation k_close_yield runs
** on the next resume and the close then finishes (PUC finishCcall with
** CIST_CLSRET redoes luaD_poscall).
*/
static int k_close_yield(lua_State *L, int status, lua_KContext ctx) {
    (void)L; (void)status; (void)ctx;
    log_note("yield-k-done");
    return 0;
}

static int c_close_yield(lua_State *L) {
    const char *name = "noname";
    const char *err = "none";
    int nargs = lua_gettop(L);
    lua_getfield(L, 1, "name");
    if (lua_isstring(L, -1))
        name = lua_tostring(L, -1);
    if (nargs >= 2) {
        if (lua_isstring(L, 2))
            err = lua_tostring(L, 2);
        else
            err = "<nonstring>";
    }
    log_close(name, err);
    lua_pop(L, 1);  /* name field */
    return lua_yieldk(L, 0, (lua_KContext)0, k_close_yield);
}

/* ------------------------------------------------------------------ */
/* Marking C functions (the code under test)                          */
/* ------------------------------------------------------------------ */

/*
** Continuation for lua_pcallk/lua_callk: records the status it was
** resumed with (LUA_YIELD on a normal resume, an error code when the
** protected call recovered an error). NOTE: after a yield or a
** recovered error, the original C function never continues past its
** lua_pcallk/lua_callk call — this continuation IS the rest of it.
*/
static int k_log_status(lua_State *L, int status, lua_KContext ctx) {
    (void)L; (void)ctx;
    log_note_i("k-status=", status);
    return 0;
}

/* T1.A/T1.B shape: mark arg 1, call arg 2 (a yielding Lua function)
** through yieldable lua_pcallk. */
static int c_tbc_pcallk(lua_State *L) {
    lua_toclose(L, 1);
    lua_pushvalue(L, 2);
    lua_pcallk(L, 0, 0, 0, (lua_KContext)0, k_log_status);
    return 0;
}

/* T1.C shape: mark arg 1, call arg 2 through yieldable lua_callk. */
static int c_tbc_callk(lua_State *L) {
    lua_toclose(L, 1);
    lua_pushvalue(L, 2);
    lua_callk(L, 0, 0, (lua_KContext)0, k_log_status);
    return 0;
}

/*
** T1.C live-slot check: mark arg 1 (object A), then OVERWRITE the marked
** slot with arg 2 (object B) via lua_replace. PUC's tbclist stores stack
** levels, not values, so the close at C-function return must run __close
** on the CURRENT slot value (B), proving live-slot semantics.
*/
static int c_tbc_callk_mutate(lua_State *L) {
    lua_toclose(L, 1);
    lua_pushvalue(L, 2);
    lua_replace(L, 1);  /* marked slot now holds B */
    lua_pushvalue(L, 3);
    lua_callk(L, 0, 0, (lua_KContext)0, k_log_status);
    return 0;
}

/* Single TBC mark, plain return (closes at luaD_poscall). */
static int c_tbc_plain(lua_State *L) {
    lua_toclose(L, 1);
    return 0;
}

/* Two TBC marks: must close LIFO (slot 2 first, then slot 1). */
static int c_tbc_two(lua_State *L) {
    lua_toclose(L, 1);
    lua_toclose(L, 2);
    return 0;
}

/*
** Two marks + explicit lua_closeslot on the TOP mark (PUC api_check:
** only the top of the tbclist can be closed this way). The lower mark
** must still close at function return.
*/
static int c_tbc_closeslot(lua_State *L) {
    lua_toclose(L, 1);
    lua_toclose(L, 2);
    lua_closeslot(L, 2);  /* closes slot 2 now; slot is set to nil */
    log_note("closeslot-done");
    return 0;  /* slot 1 still closes at return */
}

/*
** Mark arg 1, then raise an error: the unwind must close the TBC with
** the in-flight error object ("orig") visible to __close; if the closer
** itself errors (object has `raise`), the closer's error must win.
*/
static int c_tbc_error(lua_State *L) {
    lua_toclose(L, 1);
    lua_pushliteral(L, "orig");
    return lua_error(L);
}

/* Nested C frames: inner marks its own arg; both close LIFO across the
** two C frames (inner's mark — higher slot — closes at inner's return,
** outer's at outer's return). */
static int c_inner(lua_State *L) {
    lua_toclose(L, 1);
    return 0;
}

static int c_outer(lua_State *L) {
    lua_toclose(L, 1);  /* outer mark: arg 1 */
    lua_getglobal(L, "c_inner");
    lua_pushvalue(L, 2);  /* inner's TBC object: arg 2 */
    lua_call(L, 1, 0);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Per-case infrastructure: fresh state per case for isolation        */
/* ------------------------------------------------------------------ */

static void reg(lua_State *L, lua_CFunction f, const char *name) {
    lua_pushcfunction(L, f);
    lua_setglobal(L, name);
}

/*
** Lua-side object constructors:
**   mkobj(name [, raise]) — object closed by the recording closer
**                           (errors with `raise` if that field is set);
**   mkyld(name)           — object closed by the yielding closer.
*/
#define SETUP_LUA                                               \
    "function mkobj(name, raise)\n"                             \
    "  local o = {name = name}\n"                               \
    "  if raise then o.raise = raise end\n"                     \
    "  return setmetatable(o, {__close = REC})\n"               \
    "end\n"                                                     \
    "function mkyld(name)\n"                                    \
    "  return setmetatable({name = name}, {__close = YLD})\n"   \
    "end\n"

static lua_State *case_begin(const char *id) {
    lua_State *L = luaL_newstate();
    if (!L) {
        printf("%s FAIL: newstate\n", id);
        return NULL;
    }
    luaL_openlibs(L);
    reg(L, c_close_maybe_error, "REC");
    reg(L, c_close_yield, "YLD");
    reg(L, c_tbc_pcallk, "c_tbc_pcallk");
    reg(L, c_tbc_callk, "c_tbc_callk");
    reg(L, c_tbc_callk_mutate, "c_tbc_callk_mutate");
    reg(L, c_tbc_plain, "c_tbc_plain");
    reg(L, c_tbc_two, "c_tbc_two");
    reg(L, c_tbc_closeslot, "c_tbc_closeslot");
    reg(L, c_tbc_error, "c_tbc_error");
    reg(L, c_inner, "c_inner");
    reg(L, c_outer, "c_outer");
    if (luaL_dostring(L, SETUP_LUA) != 0) {
        printf("%s FAIL: setup: %s\n", id,
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return NULL;
    }
    log_reset();
    printf("%s: running\n", id);
    return L;
}

/* Run a Lua snippet that must succeed; returns 1 (and closes L) on error. */
static int need(lua_State *L, const char *code, const char *id) {
    if (luaL_dostring(L, code) != 0) {
        printf("%s FAIL: dostring: %s\n", id,
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return 1;
    }
    return 0;
}

/* Resume `co` from C and print a deterministic one-line report. */
static int do_resume(lua_State *L, lua_State *co, int nargs, const char *label) {
    int nres = 0;
    int st = lua_resume(co, L, nargs, &nres);
    printf("%s: st=%d nres=%d val=%s\n", label, st, nres,
           (nres > 0 && lua_isstring(co, -1)) ? lua_tostring(co, -1) : "-");
    return st;
}

/* Close a thread from C and report status + error object (if any). */
static int do_closethread(lua_State *L, lua_State *co, const char *label) {
    int st = lua_closethread(co, L);
    printf("%s: st=%d err=%s\n", label, st,
           (st != LUA_OK && lua_isstring(co, -1)) ? lua_tostring(co, -1)
                                                  : "none");
    return st;
}

/* Finish a main-thread lua_pcall (function + args already pushed). */
static int finish_pcall(lua_State *L, int nargs, const char *label) {
    int st = lua_pcall(L, nargs, 0, 0);
    printf("%s: st=%d err=%s\n", label, st,
           (st != LUA_OK && lua_isstring(L, -1)) ? lua_tostring(L, -1)
                                                 : "none");
    if (st != LUA_OK)
        lua_pop(L, 1);
    return st;
}

/* Print the case verdict line: __close count + ordered event log. */
static void case_verdict(lua_State *L, const char *id) {
    printf("%s close_calls=%d events=[%s]\n", id, close_calls, evlog);
    lua_close(L);
}

/* ------------------------------------------------------------------ */
/* Group 1 — T1.A crash regression (runs FIRST on purpose)            */
/* ------------------------------------------------------------------ */

/* G1a: the t6_repro shape, minimized, closed from Lua. */
static int t_g1a(void) {
    lua_State *L = case_begin("G1a");
    if (!L) return 1;
    if (need(L,
        "local o = mkobj('G1a')\n"
        "local f = function() coroutine.yield('from-pcallk') end\n"
        "local co = coroutine.create(function() return c_tbc_pcallk(o, f) end)\n"
        "local ok, v = coroutine.resume(co)\n"
        "R1 = tostring(ok) .. '|' .. tostring(v)\n"
        "local okc, errc = coroutine.close(co)\n"
        "RC = tostring(okc) .. '|' .. tostring(errc)\n",
        "G1a"))
        return 1;
    lua_getglobal(L, "R1");
    printf("G1a resume1: %s\n",
           lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
    lua_pop(L, 1);
    lua_getglobal(L, "RC");
    printf("G1a close: %s\n",
           lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
    lua_pop(L, 1);
    case_verdict(L, "G1a");  /* PUC: close_calls=1 events=[name=G1a err=none] */
    return 0;
}

/* G1b: same suspension shape, closed from C via lua_closethread. */
static int t_g1b(void) {
    lua_State *L = case_begin("G1b");
    if (!L) return 1;
    if (need(L,
        "BO = mkobj('G1b')\n"
        "BF = function() coroutine.yield('B-from-pcallk') end\n",
        "G1b"))
        return 1;
    lua_State *co = lua_newthread(L);  /* anchored on L's stack */
    if (luaL_loadstring(co, "return c_tbc_pcallk(BO, BF)") != 0) {
        printf("G1b FAIL: loadstring\n");
        lua_close(L);
        return 1;
    }
    do_resume(L, co, 0, "G1b resume1");   /* suspends inside c_tbc_pcallk */
    do_closethread(L, co, "G1b closethread");
    case_verdict(L, "G1b");  /* PUC: close_calls=1 events=[name=G1b err=none] */
    return 0;
}

/* ------------------------------------------------------------------ */
/* Group 2 — T1.B freed-not-closed (C function as coroutine body)     */
/* ------------------------------------------------------------------ */

/*
** Same suspension shape, but the C function IS the coroutine body (no
** Lua frames at all). Isolates "TBC freed without running __close"
** (close_calls == 0) from the Group 1 crash.
*/
static int t_g2(void) {
    lua_State *L = case_begin("G2");
    if (!L) return 1;
    if (need(L,
        "BO2 = mkobj('G2')\n"
        "BF2 = function() coroutine.yield('G2-from-pcallk') end\n",
        "G2"))
        return 1;
    lua_State *co = lua_newthread(L);
    lua_getglobal(co, "c_tbc_pcallk");  /* the C function as the body */
    lua_getglobal(co, "BO2");
    lua_getglobal(co, "BF2");
    do_resume(L, co, 2, "G2 resume1");   /* suspends inside c_tbc_pcallk */
    do_closethread(L, co, "G2 closethread");
    case_verdict(L, "G2");  /* PUC: close_calls=1 events=[name=G2 err=none] */
    return 0;
}

/* ------------------------------------------------------------------ */
/* Group 3 — T1.C normal-resume drop                                  */
/* ------------------------------------------------------------------ */

/* G3a: toclose + callk; yield; normal resume; C function returns. */
static int t_g3a(void) {
    lua_State *L = case_begin("G3a");
    if (!L) return 1;
    if (need(L,
        "O3 = mkobj('G3a')\n"
        "F3 = function() coroutine.yield('y3') end\n",
        "G3a"))
        return 1;
    lua_State *co = lua_newthread(L);
    if (luaL_loadstring(co, "return c_tbc_callk(O3, F3)") != 0) {
        printf("G3a FAIL: loadstring\n");
        lua_close(L);
        return 1;
    }
    do_resume(L, co, 0, "G3a resume1");  /* yields inside F3 */
    do_resume(L, co, 0, "G3a resume2");  /* k runs, C fn returns, TBC closes */
    case_verdict(L, "G3a");  /* PUC: close_calls=1 events=[k-status=1; name=G3a err=none] */
    return 0;
}

/*
** G3b: live-slot semantics. The marked slot is overwritten with a second
** closable object after lua_toclose; the close at C-function return must
** see the CURRENT slot value (PUC tbclist stores levels, not values).
*/
static int t_g3b(void) {
    lua_State *L = case_begin("G3b");
    if (!L) return 1;
    if (need(L,
        "O3A = mkobj('G3bA')\n"
        "O3B = mkobj('G3bB')\n"
        "F3 = function() coroutine.yield('y3b') end\n",
        "G3b"))
        return 1;
    lua_State *co = lua_newthread(L);
    if (luaL_loadstring(co, "return c_tbc_callk_mutate(O3A, O3B, F3)") != 0) {
        printf("G3b FAIL: loadstring\n");
        lua_close(L);
        return 1;
    }
    do_resume(L, co, 0, "G3b resume1");
    do_resume(L, co, 0, "G3b resume2");
    /* PUC: events=[k-status=1; name=G3bB err=none] — the mutated value,
    ** not the value that was in the slot at lua_toclose time (G3bA). */
    case_verdict(L, "G3b");
    return 0;
}

/* ------------------------------------------------------------------ */
/* Group 4 — lifecycle matrix                                         */
/* ------------------------------------------------------------------ */

/* D1: one TBC mark, normal return -> exactly one __close. */
static int t_d1(void) {
    lua_State *L = case_begin("D1");
    if (!L) return 1;
    if (need(L, "A1 = mkobj('n1')\n", "D1"))
        return 1;
    lua_getglobal(L, "c_tbc_plain");
    lua_getglobal(L, "A1");
    finish_pcall(L, 1, "D1 pcall");
    case_verdict(L, "D1");  /* PUC: close_calls=1 events=[name=n1 err=none] */
    return 0;
}

/* D2: two TBC marks -> LIFO close order (slot 2 first). */
static int t_d2(void) {
    lua_State *L = case_begin("D2");
    if (!L) return 1;
    if (need(L, "A2 = mkobj('n2a')\nB2 = mkobj('n2b')\n", "D2"))
        return 1;
    lua_getglobal(L, "c_tbc_two");
    lua_getglobal(L, "A2");
    lua_getglobal(L, "B2");
    finish_pcall(L, 2, "D2 pcall");
    /* PUC: events=[name=n2b err=none; name=n2a err=none] */
    case_verdict(L, "D2");
    return 0;
}

/* D3: explicit lua_closeslot on the top mark; the lower mark still
** closes at return. */
static int t_d3(void) {
    lua_State *L = case_begin("D3");
    if (!L) return 1;
    if (need(L, "A3 = mkobj('n3a')\nB3 = mkobj('n3b')\n", "D3"))
        return 1;
    lua_getglobal(L, "c_tbc_closeslot");
    lua_getglobal(L, "A3");
    lua_getglobal(L, "B3");
    finish_pcall(L, 2, "D3 pcall");
    /* PUC: events=[name=n3b err=none; closeslot-done; name=n3a err=none] */
    case_verdict(L, "D3");
    return 0;
}

/*
** D4: erroring closer with two marks. The top closer (n4b) errors with
** "e-b" during the normal-return close; the unwind must (a) make the
** error object visible to the caller and (b) close the remaining mark
** (n4a) WITH that error object as __close's second argument.
*/
static int t_d4(void) {
    lua_State *L = case_begin("D4");
    if (!L) return 1;
    if (need(L,
        "A4 = mkobj('n4a')\n"
        "B4 = mkobj('n4b', 'e-b')\n",  /* B4's closer errors with "e-b" */
        "D4"))
        return 1;
    lua_getglobal(L, "c_tbc_two");
    lua_getglobal(L, "A4");
    lua_getglobal(L, "B4");
    finish_pcall(L, 2, "D4 pcall");  /* PUC: st=2 err=e-b */
    /* PUC: events=[name=n4b err=none; name=n4a err=e-b] */
    case_verdict(L, "D4");
    return 0;
}

/*
** D5: last-error-wins. The C function marks n5 and raises "orig"; the
** unwind closes n5 with "orig" visible to __close; n5's closer then
** errors with "e-a", which must REPLACE "orig" as the final error.
*/
static int t_d5(void) {
    lua_State *L = case_begin("D5");
    if (!L) return 1;
    if (need(L, "A5 = mkobj('n5', 'e-a')\n", "D5"))
        return 1;
    lua_getglobal(L, "c_tbc_error");
    lua_getglobal(L, "A5");
    finish_pcall(L, 1, "D5 pcall");  /* PUC: st=2 err=e-a (last error wins) */
    /* PUC: events=[name=n5 err=orig] (in-flight error visible to closer) */
    case_verdict(L, "D5");
    return 0;
}

/*
** D6: __close that yields during the normal-return close. PUC's
** moveresults closes TBC yieldably (luaF_close yy=1), so a C closer may
** lua_yieldk: the coroutine suspends MID-CLOSE, and the next resume runs
** the closer's continuation and finishes the close (finishCcall with
** CIST_CLSRET redoes luaD_poscall).
*/
static int t_d6(void) {
    lua_State *L = case_begin("D6");
    if (!L) return 1;
    if (need(L, "Y6 = mkyld('n6')\n", "D6"))
        return 1;
    lua_State *co = lua_newthread(L);
    if (luaL_loadstring(co, "return c_tbc_plain(Y6)") != 0) {
        printf("D6 FAIL: loadstring\n");
        lua_close(L);
        return 1;
    }
    do_resume(L, co, 0, "D6 resume1");  /* yields inside __close */
    do_resume(L, co, 0, "D6 resume2");  /* continuation runs, close finishes */
    /* PUC: close_calls=1 events=[name=n6 err=none; yield-k-done] */
    case_verdict(L, "D6");
    return 0;
}

/*
** D7: pcallk error recovery. The callee yields, then errors; lua_pcallk
** recovers the error and calls k with the error status; k returns, the
** C function finishes normally and its own TBC closes at return (the
** pcallk's error recovery closes only TBC at/above the called function,
** which is above the C function's own marked slot).
*/
static int t_d7(void) {
    lua_State *L = case_begin("D7");
    if (!L) return 1;
    if (need(L,
        "P7 = mkobj('n7')\n"
        "F7 = function() coroutine.yield('y7'); error('boom7', 0) end\n",
        "D7"))
        return 1;
    lua_State *co = lua_newthread(L);
    if (luaL_loadstring(co, "return c_tbc_pcallk(P7, F7)") != 0) {
        printf("D7 FAIL: loadstring\n");
        lua_close(L);
        return 1;
    }
    do_resume(L, co, 0, "D7 resume1");  /* yields inside F7 */
    do_resume(L, co, 0, "D7 resume2");  /* error recovered into k; TBC closes */
    /* PUC: close_calls=1 events=[k-status=2; name=n7 err=none] */
    case_verdict(L, "D7");
    return 0;
}

/*
** D8: yield -> resume -> error -> close. The callee yields, then errors;
** lua_callk is NOT a protected call, so the error kills the coroutine
** with the C function's TBC still pending in the per-thread tbclist
** (PUC: the tbclist is independent of CallInfo). lua_closethread must
** then close it, passing the coroutine's error object to __close, and
** report the error itself.
*/
static int t_d8(void) {
    lua_State *L = case_begin("D8");
    if (!L) return 1;
    if (need(L,
        "Q8 = mkobj('n8')\n"
        "F8 = function() coroutine.yield('y8'); error('boom8', 0) end\n",
        "D8"))
        return 1;
    lua_State *co = lua_newthread(L);
    if (luaL_loadstring(co, "return c_tbc_callk(Q8, F8)") != 0) {
        printf("D8 FAIL: loadstring\n");
        lua_close(L);
        return 1;
    }
    do_resume(L, co, 0, "D8 resume1");  /* yields inside F8 */
    do_resume(L, co, 0, "D8 resume2");  /* error kills the coroutine */
    do_closethread(L, co, "D8 closethread");  /* closes the pending TBC */
    /* PUC: close_calls=1 events=[name=n8 err=boom8] */
    case_verdict(L, "D8");
    return 0;
}

/* D9: nested C frames — outer marks its arg, calls an inner C function
** that marks its own arg; both close LIFO across the two frames. */
static int t_d9(void) {
    lua_State *L = case_begin("D9");
    if (!L) return 1;
    if (need(L, "A9 = mkobj('n9outer')\nB9 = mkobj('n9inner')\n", "D9"))
        return 1;
    lua_getglobal(L, "c_outer");
    lua_getglobal(L, "A9");
    lua_getglobal(L, "B9");
    finish_pcall(L, 2, "D9 pcall");
    /* PUC: events=[name=n9inner err=none; name=n9outer err=none] */
    case_verdict(L, "D9");
    return 0;
}

/*
** D10: nested coroutines. co1 resumes co2; co2 suspends with a C-frame
** TBC (the Group 1 crash shape, nested one level deeper); co1 then
** yields. Closing co2 must run its __close; closing co1 must succeed.
*/
static int t_d10(void) {
    lua_State *L = case_begin("D10");
    if (!L) return 1;
    if (need(L,
        "local f10 = function() coroutine.yield('n10-y') end\n"
        "CO2 = coroutine.create(function() return c_tbc_pcallk(mkobj('n10'), f10) end)\n"
        "CO1 = coroutine.create(function()\n"
        "  local ok, v = coroutine.resume(CO2)\n"
        "  C1R = tostring(ok) .. '|' .. tostring(v)\n"
        "  coroutine.yield('co1-y')\n"
        "end)\n",
        "D10"))
        return 1;
    lua_getglobal(L, "CO1");
    lua_State *co1 = lua_tothread(L, -1);
    if (!co1) {
        printf("D10 FAIL: CO1 is not a thread\n");
        lua_close(L);
        return 1;
    }
    do_resume(L, co1, 0, "D10 resume CO1");  /* CO1 resumes CO2, then yields */
    lua_pop(L, 1);
    lua_getglobal(L, "C1R");
    printf("D10 CO1 saw: %s\n",
           lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
    lua_pop(L, 1);
    lua_getglobal(L, "CO2");
    lua_State *co2 = lua_tothread(L, -1);
    if (!co2) {
        printf("D10 FAIL: CO2 is not a thread\n");
        lua_close(L);
        return 1;
    }
    do_closethread(L, co2, "D10 closethread CO2");  /* closes n10 */
    lua_pop(L, 1);
    lua_getglobal(L, "CO1");
    co1 = lua_tothread(L, -1);
    do_closethread(L, co1, "D10 closethread CO1");
    lua_pop(L, 1);
    /* PUC: close_calls=1 events=[name=n10 err=none] */
    case_verdict(L, "D10");
    return 0;
}

/*
** D11: GC between mark and close. After the coroutine suspends, every
** reference to the TBC object is dropped except the marked slot on the
** suspended coroutine's stack; a full collection must NOT free it (the
** stack slot anchors it), and the later close must run __close on the
** LIVE object (the closer reads the object's `name` field).
*/
static int t_d11(void) {
    lua_State *L = case_begin("D11");
    if (!L) return 1;
    if (need(L,
        "OBJG = mkobj('n11')\n"
        "local f11 = function() coroutine.yield('g-y') end\n"
        "COG = coroutine.create(function() return c_tbc_pcallk(OBJG, f11) end)\n"
        "local ok, v = coroutine.resume(COG)\n"
        "G11R = tostring(ok) .. '|' .. tostring(v)\n",
        "D11"))
        return 1;
    lua_getglobal(L, "G11R");
    printf("D11 resume1: %s\n",
           lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
    lua_pop(L, 1);
    /* Drop the only non-coroutine reference, then collect. */
    lua_pushnil(L);
    lua_setglobal(L, "OBJG");
    lua_gc(L, LUA_GCCOLLECT, 0);
    printf("D11 gc: collected\n");
    lua_getglobal(L, "COG");
    lua_State *co = lua_tothread(L, -1);
    if (!co) {
        printf("D11 FAIL: COG is not a thread\n");
        lua_close(L);
        return 1;
    }
    do_closethread(L, co, "D11 closethread");
    lua_pop(L, 1);
    /* PUC: close_calls=1 events=[name=n11 err=none] — closer ran on the
    ** live object, reading its field after the collection. */
    case_verdict(L, "D11");
    return 0;
}

/* ------------------------------------------------------------------ */

int main(void) {
    /* Unbuffered stdout: if a runtime dies on a signal mid-suite, every
    ** line printed before the crash is still visible in the lane logs. */
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== 22_tbc_lifecycle: P16.30 T1 C-frame TBC ownership ===\n");
    /* Group 1 FIRST: the known crash case must be hit before anything
    ** else, so a signal death fails the lane immediately. */
    if (t_g1a()) return 1;
    if (t_g1b()) return 1;
    if (t_g2())  return 1;
    if (t_g3a()) return 1;
    if (t_g3b()) return 1;
    if (t_d1())  return 1;
    if (t_d2())  return 1;
    if (t_d3())  return 1;
    if (t_d4())  return 1;
    if (t_d5())  return 1;
    if (t_d6())  return 1;
    if (t_d7())  return 1;
    if (t_d8())  return 1;
    if (t_d9())  return 1;
    if (t_d10()) return 1;
    if (t_d11()) return 1;
    printf("=== 22_tbc_lifecycle DONE ===\n");
    return 0;
}
