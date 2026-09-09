/*
** 23_tbc_semantics.c — P16.31 Cut 5: to-be-closed (TBC) semantics —
** hook-lane marks and close thread-context. PERMANENT differential suite
** (luazig vs PUC 5.5).
**
** Group H — hook-lane TBC: a line hook marks a slot with lua_toclose
** (PUC: the mark goes on the interrupted Lua frame F — L->ci == F while
** the hook runs — via luaF_newtbcval + CIST_TBC) and optionally yields
** from the hook. The mark must survive the hook-yield suspension and
** close at the semantically right point, ON the coroutine:
**
**   H-A  mark + hook-yield; body returns normally. The main chunk is a
**        vararg function, so PUC luaK_finish rewrites its RETURN0/1 into
**        OP_RETURN (PF_VAHID); OP_RETURN's luaD_poscall runs moveresults,
**        which closes TBC (CIST_TBC) with err=nil. The closer must run
**        ON the coroutine (on=CO) at the chunk's return; a later
**        lua_closethread on the dead coroutine must be a no-op (st=0, no
**        second close).
**
**   H-C  mark + hook-yield; body yields mid (coroutine.yield). The
**        coroutine suspends with the mark pending; lua_closethread must
**        transport the closer onto the closed coroutine (on=CO, err=nil)
**        and return st=0.
**
**   H-D  mark + hook-yield; body hits a runtime error (nil index — no C
**        builtin in the throw path). The error path must NOT close the
**        mark (PUC lua_resume's unrecoverable branch only sets the
**        status and the error object; the mark stays pending). Only st
**        and the error message are asserted: PUC's nres counts the raw
**        leftover stack (including the error-message-building pushes),
**        which diverges. lua_closethread after the error is NOT asserted
**        because PUC's shared stack lets those same message-building
**        pushes CLOBBER the marked slot (the close then fails with
**        "attempt to call a nil value"), while luazig's detached mark
**        keeps the original value and runs the closer with the thread's
**        error — a documented, justified divergence (split-stack
**        architecture; see STATUS.md P16.31 Cut 5).
**
**   H-E  mark only (no yield); the hook disables itself; body returns.
**        Same VAHID->OP_RETURN->poscall close as H-A, during the FIRST
**        resume. The result is then popped off the coroutine's stack
**        (like coroutine.resume's xmove) so the second resume hits the
**        clean dead-coroutine path: st=2, nres=0 (PUC's resume_error
**        returns before setting *nresults).
**
**   H-B2 mark + hook-yield; body yields mid; the closer ERRORS. Closing
**        the suspended coroutine must run the closer (it sees err=nil —
**        the coroutine is suspended, not erroneous) and the closer's
**        error must win: lua_closethread returns st=2 with "closer-boom"
**        (last-error-wins).
**
** Group C — c_api-lane close thread-context (which thread runs __close
** when a coroutine with parked C-frame TBC marks is closed) plus
** chunk-name quoting in the error objects:
**
**   C-S1  suspended co (C body: lua_toclose + lua_pcallk into a yielding
**         Lua function), closed via lua_closethread from the main
**         thread: the closer must run ON the closed coroutine (on=CO)
**         with err=nil; st=0.
**
**   C-S2  same shape, closed via Lua coroutine.close from the main
**         thread: same result.
**
**   C-S3  dead-with-error co (lua_callk continuation raises "cont-err"):
**         lua_closethread must run the closer ON the closed coroutine
**         with the coroutine's error object visible (err carries the
**         [string "..."]:1: position prefix — chunk-name quoting parity)
**         and return st=2.
**
**   C-S4  C-S3 with an erroring closer: last-error-wins — the closer
**         still sees the original error, and lua_closethread returns the
**         closer's error ("closer-boom").
**
**   C-S0  lua_toclose + lua_pcallk with k==NULL (non-yieldable): the
**         yield inside becomes "attempt to yield across a C-call
**         boundary", caught by the pcall; the C function returns
**         normally; the closer runs at its return (on=CO, err=nil) and
**         the coroutine completes OK during the first resume.
**
** Determinism rules (same as 22_tbc_lifecycle): only fixed labels,
** statuses and controlled strings are printed. The H-group closers are
** C functions comparing their lua_State against the recorded
** main/coroutine states; the C-group closers are Lua functions comparing
** coroutine.running() against a global holding the coroutine under test.
** All error objects are fixed strings (lua_error from C, error() from
** fixed Lua sources, or the fixed runtime-error message of H-D).
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* ------------------------------------------------------------------ */
/* Deterministic event log (Group H): the C closers append events.    */
/* ------------------------------------------------------------------ */

static int close_calls;
static char evlog[1024];

static void log_reset(void) {
    close_calls = 0;
    evlog[0] = '\0';
}

static void log_close(const char *err, const char *where) {
    size_t len = strlen(evlog);
    close_calls++;
    snprintf(evlog + len, sizeof(evlog) - len, "%sclose(err=%s,on=%s)",
             len ? "; " : "", err, where);
}

static void print_log(const char *label) {
    printf("%s: (%s)\n", label, evlog);
}

/* ------------------------------------------------------------------ */
/* Group H: identity + closers + hooks                                */
/* ------------------------------------------------------------------ */

/* The closer's L vs the states under test: the close must run ON the
** coroutine that owns the mark ("CO"), never on main ("MAIN"). */
static lua_State *g_main;
static lua_State *g_co;

static const char *where_am_i(lua_State *L) {
    if (L == g_co) return "CO";
    if (L == g_main) return "MAIN";
    return "OTHER";
}

/* Recording closer: logs the error argument (if any) + the running
** thread's identity, then returns normally. */
static int c_closer(lua_State *L) {
    const char *err = "none";
    if (lua_gettop(L) >= 2 && lua_isstring(L, 2))
        err = lua_tostring(L, 2);
    log_close(err, where_am_i(L));
    return 0;
}

/* Erroring closer: records like c_closer, then raises "closer-boom"
** (last-error-wins must surface it as the close's result). */
static int c_closer_err(lua_State *L) {
    const char *err = "none";
    if (lua_gettop(L) >= 2 && lua_isstring(L, 2))
        err = lua_tostring(L, 2);
    log_close(err, where_am_i(L));
    lua_pushliteral(L, "closer-boom");
    return lua_error(L);
}

/* Line hook: disable itself (so later lines fire no hook events), push
** the closable object, mark it TBC, then yield from the hook. The yield
** suspends the coroutine mid-instruction (PUC CIST_HOOKYIELD); the mark
** must survive the suspension. */
static void hook_mark_yield(lua_State *L, lua_Debug *ar) {
    (void)ar;
    lua_sethook(L, NULL, 0, 0);
    lua_getglobal(L, "HOBJ");
    lua_toclose(L, -1);
    lua_yield(L, 0);
}

/* Line hook: mark only — no yield. The body keeps running in the same
** resume and returns, closing the mark at the chunk's return. */
static void hook_mark_only(lua_State *L, lua_Debug *ar) {
    (void)ar;
    lua_sethook(L, NULL, 0, 0);
    lua_getglobal(L, "HOBJ");
    lua_toclose(L, -1);
}

/* ------------------------------------------------------------------ */
/* Group H: report helpers                                            */
/* ------------------------------------------------------------------ */

/* Resume and report st + nres + top value. Used where nres is at parity
** (yields, normal completions, the clean dead-coroutine error). */
static void do_resume(lua_State *L, lua_State *co, const char *label) {
    int nres = 0;
    int st = lua_resume(co, L, 0, &nres);
    printf("%s: st=%d nres=%d val=%s\n", label, st, nres,
           (nres > 0 && lua_isstring(co, -1)) ? lua_tostring(co, -1) : "-");
}

/* Resume and report st + top value only, WITHOUT nres: for error exits
** where PUC's nres counts the raw leftover stack (message-building
** pushes included) — a shared-stack artifact that diverges. */
static void do_resume_val(lua_State *L, lua_State *co, const char *label) {
    int nres = 0;
    int st = lua_resume(co, L, 0, &nres);
    printf("%s: st=%d val=%s\n", label, st,
           (lua_gettop(co) > 0 && lua_isstring(co, -1))
               ? lua_tostring(co, -1) : "-");
}

/* Close a thread from C and report status + error object (if any). */
static void do_closethread(lua_State *L, lua_State *co, const char *label) {
    int st = lua_closethread(co, L);
    printf("%s: st=%d err=%s\n", label, st,
           (st != LUA_OK && lua_isstring(co, -1)) ? lua_tostring(co, -1)
                                                  : "none");
}

/* ------------------------------------------------------------------ */
/* Group H: per-case setup                                            */
/* ------------------------------------------------------------------ */

/* Fresh state per case for isolation; records g_main for identity. */
static lua_State *h_begin(const char *id) {
    lua_State *L = luaL_newstate();
    if (!L) {
        printf("%s FAIL: newstate\n", id);
        return NULL;
    }
    luaL_openlibs(L);
    g_main = L;
    log_reset();
    return L;
}

/*
** Build the coroutine under test:
**   HOBJ  — a table closed by `cf` (the recording/erroring closer);
**   co    — a new thread whose stack holds `body` loaded with the fixed
**           chunk name "b" (so runtime-error messages are deterministic:
**           [string "b"]:LINE: ...);
**   hook  — the line hook `hk` armed on the coroutine (fires at line 1).
** The coroutine stays anchored on L's stack for the whole case.
*/
static lua_State *h_setup(lua_State *L, const char *body, lua_Hook hk,
                          lua_CFunction cf) {
    lua_newtable(L);                    /* the object */
    lua_newtable(L);                    /* its metatable */
    lua_pushcfunction(L, cf);
    lua_setfield(L, -2, "__close");
    lua_setmetatable(L, -2);
    lua_setglobal(L, "HOBJ");
    lua_State *co = lua_newthread(L);
    if (luaL_loadbufferx(co, body, strlen(body), "b", NULL) != 0) {
        printf("FAIL load: %s\n",
               (lua_gettop(co) > 0 && lua_isstring(co, -1))
                   ? lua_tostring(co, -1) : "?");
        return NULL;
    }
    lua_sethook(co, hk, LUA_MASKLINE, 0);
    g_co = co;  /* the closers compare their L against this */
    return co;
}

/* ------------------------------------------------------------------ */
/* Group H cases                                                      */
/* ------------------------------------------------------------------ */

/* H-A: mark + hook-yield; normal return. The close fires at the chunk's
** return (VAHID -> OP_RETURN -> poscall -> CIST_TBC close), on=CO,
** err=none; closethread afterwards is a no-op. */
static int t_ha(void) {
    lua_State *L = h_begin("H-A");
    if (!L) return 1;
    lua_State *co = h_setup(L, "local x = 1\nreturn 'H-A.done'",
                            hook_mark_yield, c_closer);
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "H-A resume1");         /* hook marks + yields */
    do_resume(L, co, "H-A resume2");         /* body returns; close fires */
    print_log("H-A log1");                   /* close(err=none,on=CO) */
    do_closethread(L, co, "H-A closethread");/* dead-normal: st=0, no close */
    print_log("H-A log2");                   /* unchanged */
    printf("H-A done close_calls=%d\n", close_calls);
    lua_close(L);
    return 0;
}

/* H-C: mark + hook-yield; body yields mid; close while suspended. The
** closethread transport must run the closer on=CO with err=none. */
static int t_hc(void) {
    lua_State *L = h_begin("H-C");
    if (!L) return 1;
    lua_State *co = h_setup(L,
        "local x = 1\ncoroutine.yield('mid')\nreturn 'H-C.done'",
        hook_mark_yield, c_closer);
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "H-C resume1");         /* hook marks + yields */
    do_resume(L, co, "H-C resume2");         /* body yields mid: st=1 val=mid */
    print_log("H-C log1");                   /* empty: mark still pending */
    do_closethread(L, co, "H-C closethread");/* transport close: st=0 */
    print_log("H-C log2");                   /* close(err=none,on=CO) */
    printf("H-C done close_calls=%d\n", close_calls);
    lua_close(L);
    return 0;
}

/* H-D: mark + hook-yield; runtime error in the body. The error path must
** close NOTHING (log stays empty). No closethread is attempted and nres
** is not printed: both are documented shared-stack divergences (see the
** file header). The pending mark is released with the state. */
static int t_hd(void) {
    lua_State *L = h_begin("H-D");
    if (!L) return 1;
    lua_State *co = h_setup(L,
        "local x = 1\nlocal t = nil\nreturn t.boom",
        hook_mark_yield, c_closer);
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "H-D resume1");         /* hook marks + yields */
    do_resume_val(L, co, "H-D resume2");     /* st=2 + the nil-index error */
    print_log("H-D log1");                   /* empty: error path closes nothing */
    printf("H-D done close_calls=%d\n", close_calls);
    lua_close(L);
    return 0;
}

/* H-E: mark only (no yield); the body returns in the same resume. Pop
** the result off the coroutine's stack (like coroutine.resume's xmove)
** so the second resume hits the clean dead-coroutine path (st=2, nres=0
** — PUC's resume_error returns before setting *nresults). */
static int t_he(void) {
    lua_State *L = h_begin("H-E");
    if (!L) return 1;
    lua_State *co = h_setup(L, "local x = 1\nreturn 'H-E.done'",
                            hook_mark_only, c_closer);
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "H-E resume1");         /* completes; close fires */
    print_log("H-E log1");                   /* close(err=none,on=CO) */
    lua_pop(co, 1);                          /* drop the result */
    do_resume(L, co, "H-E resume2");         /* st=2 nres=0: dead coroutine */
    print_log("H-E log2");                   /* unchanged */
    printf("H-E done close_calls=%d\n", close_calls);
    lua_close(L);
    return 0;
}

/* H-B2: mark + hook-yield; body yields mid; ERRORING closer. The
** closethread transport runs the closer (it sees err=none — the
** coroutine is suspended), the closer raises "closer-boom", and
** last-error-wins makes closethread return st=2 with that error. */
static int t_hb2(void) {
    lua_State *L = h_begin("H-B2");
    if (!L) return 1;
    lua_State *co = h_setup(L,
        "local x = 1\ncoroutine.yield('mid')\nreturn 'H-B2.done'",
        hook_mark_yield, c_closer_err);
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "H-B2 resume1");        /* hook marks + yields */
    do_resume(L, co, "H-B2 resume2");        /* body yields mid */
    do_closethread(L, co, "H-B2 closethread");/* st=2 err=closer-boom */
    print_log("H-B2 log");                   /* close(err=none,on=CO) */
    printf("H-B2 done close_calls=%d\n", close_calls);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Group C: C bodies that mark TBC and park their C frame             */
/* ------------------------------------------------------------------ */

/* No-op continuation for lua_pcallk. */
static int k_noop(lua_State *L, int status, lua_KContext ctx) {
    (void)L; (void)status; (void)ctx;
    return 0;
}

/* C-S1/S2 body: mark arg 1 TBC, call arg 2 (a yielding Lua function)
** through yieldable lua_pcallk. The yield parks the C frame with the
** mark still pending (the per-thread tbclist is independent of any
** CallInfo). */
static int c_tbc_pcallk(lua_State *L) {
    lua_toclose(L, 1);
    lua_pushvalue(L, 2);
    lua_pcallk(L, 0, 0, 0, (lua_KContext)0, k_noop);
    return 0;
}

/* C-S0 body: same but k==NULL — lua_pcallk takes the conventional
** (non-yieldable) pcall path, so the yield inside becomes "attempt to
** yield across a C-call boundary", caught by the pcall; the C function
** then returns normally and its mark closes at its return. */
static int c_tbc_pcallk_nullk(lua_State *L) {
    lua_toclose(L, 1);
    lua_pushvalue(L, 2);
    lua_pcallk(L, 0, 0, 0, (lua_KContext)0, NULL);
    return 0;
}

/* Erroring continuation for lua_callk: kills the coroutine, leaving the
** parked C frame and its mark pending on the dead thread. */
static int k_cont_error(lua_State *L, int status, lua_KContext ctx) {
    (void)status; (void)ctx;
    return luaL_error(L, "cont-err");
}

/* C-S3/S4 body: mark arg 1 TBC, call arg 2 through lua_callk whose
** continuation errors (lua_callk sets no recover point, so the error is
** unrecoverable and the coroutine dies with the parked frame + mark). */
static int c_tbc_callk_conterr(lua_State *L) {
    lua_toclose(L, 1);
    lua_pushvalue(L, 2);
    lua_callk(L, 0, 0, (lua_KContext)0, k_cont_error);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Group C: Lua-side closers (identity via coroutine.running)         */
/* ------------------------------------------------------------------ */

/*
** COOBJ/ERRCLOSER: objects whose __close records the running thread
** ("CO" = the coroutine under test, held in the global COTEST) and the
** error argument into the global LOG; ERRCLOSER then raises
** "closer-boom" (with the fixed position prefix of this setup chunk).
** YFN: the yielding callee. The setup source is fixed, so every string
** embedded in error objects (position prefixes included) is
** deterministic — this is also the chunk-name quoting parity check
** ([string "..."]:LINE: prefixes must match PUC byte for byte).
*/
#define C_SETUP_LUA                                                     \
    "COOBJ = setmetatable({}, {__close = function(_, e)\n"              \
    "  local c, ismain = coroutine.running()\n"                         \
    "  local where = (c == _G.COTEST) and 'CO' or (ismain and 'MAIN' or 'OTHER')\n" \
    "  _G.LOG = _G.LOG .. '|' .. where .. '/' .. tostring(e)\n"         \
    "end})\n"                                                           \
    "ERRCLOSER = setmetatable({}, {__close = function(_, e)\n"          \
    "  local c, ismain = coroutine.running()\n"                         \
    "  local where = (c == _G.COTEST) and 'CO' or (ismain and 'MAIN' or 'OTHER')\n" \
    "  _G.LOG = _G.LOG .. '|' .. where .. '/' .. tostring(e)\n"         \
    "  error('closer-boom')\n"                                          \
    "end})\n"                                                           \
    "YFN = function() coroutine.yield('from-fn') end\n"

/* ------------------------------------------------------------------ */
/* Group C: the case driver                                           */
/* ------------------------------------------------------------------ */

/*
** Run one C-group case:
**   - reset LOG, (re)define the closers and YFN, register `body` as the
**     global CBODY;
**   - co = coroutine.create(function() CBODY(<objname>, YFN) end) — the
**     body closure is loadstring'd from a fixed source, so its chunk
**     name is embedded verbatim in the error objects;
**   - resume once (the C body marks TBC and parks inside the call);
**   - if dead_with_error: resume again (the continuation kills the co);
**   - close via lua_closethread (use_lua_close == 0) or via Lua
**     coroutine.close from the main thread (use_lua_close == 1);
**   - report the close status/error and the LOG.
*/
static void c_run_case(lua_State *L, const char *label, const char *objname,
                       lua_CFunction body, int dead_with_error,
                       int use_lua_close) {
    char buf[128];
    lua_pushliteral(L, "");
    lua_setglobal(L, "LOG");
    if (luaL_dostring(L, C_SETUP_LUA) != 0) {
        printf("%s FAIL: setup: %s\n", label,
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_pop(L, 1);
        return;
    }
    lua_pushcfunction(L, body);
    lua_setglobal(L, "CBODY");

    /* co = coroutine.create(function() CBODY(<objname>, YFN) end) */
    lua_getglobal(L, "coroutine");
    lua_getfield(L, -1, "create");
    lua_remove(L, -2);
    snprintf(buf, sizeof buf,
             "return function() CBODY(%s, YFN) end", objname);
    if (luaL_loadstring(L, buf) != 0 || lua_pcall(L, 0, 1, 0) != 0 ||
        lua_pcall(L, 1, 1, 0) != 0) {
        printf("%s FAIL: create: %s\n", label,
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_pop(L, 1);
        return;
    }
    lua_State *co = lua_tothread(L, -1);
    if (!co) {
        printf("%s FAIL: not a thread\n", label);
        lua_pop(L, 1);
        return;
    }
    lua_pushvalue(L, -1);
    lua_setglobal(L, "COTEST");  /* the Lua closers compare against this */

    /* resume1: the C body marks TBC and calls YFN, which yields */
    {
        char lbuf[64];
        int nres = 0;
        int st = lua_resume(co, L, 0, &nres);
        snprintf(lbuf, sizeof lbuf, "%s resume1", label);
        printf("%s: st=%d nres=%d val=%s\n", lbuf, st, nres,
               (nres > 0 && lua_isstring(co, -1)) ? lua_tostring(co, -1)
                                                  : "-");
    }
    /* resume2 (only for dead-with-error shapes): the continuation kills
    ** the coroutine. nres is not printed (leftover-stack semantics). */
    if (dead_with_error) {
        char lbuf[64];
        int nres = 0;
        int st = lua_resume(co, L, 0, &nres);
        snprintf(lbuf, sizeof lbuf, "%s resume2", label);
        printf("%s: st=%d val=%s\n", lbuf, st,
               (lua_gettop(co) > 0 && lua_isstring(co, -1))
                   ? lua_tostring(co, -1) : "-");
    }

    /* close the coroutine and report status + error object */
    {
        char lbuf[64];
        int st;
        const char *err = NULL;
        if (use_lua_close) {
            /* coroutine.close(co) from the main thread, via a pcall */
            lua_getglobal(L, "coroutine");
            lua_getfield(L, -1, "close");
            lua_remove(L, -2);
            lua_pushvalue(L, -2);  /* co */
            if (lua_pcall(L, 1, 2, 0) != 0 || !lua_toboolean(L, -2)) {
                st = LUA_ERRRUN;
                err = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;
            }
            else {
                st = LUA_OK;
            }
            lua_pop(L, 2);  /* ok, err — co remains */
        }
        else {
            st = lua_closethread(co, L);
            if (st != LUA_OK)
                err = (lua_gettop(co) > 0 && lua_isstring(co, -1))
                          ? lua_tostring(co, -1) : NULL;
        }
        snprintf(lbuf, sizeof lbuf, "%s close", label);
        printf("%s: st=%d err=%s\n", lbuf, st, err ? err : "none");
    }

    /* the closers' LOG: identity + error visibility, in close order */
    lua_getglobal(L, "LOG");
    printf("%s log: %s\n", label,
           (lua_isstring(L, -1) && lua_tostring(L, -1)[0])
               ? lua_tostring(L, -1) : "(empty)");
    lua_pop(L, 2);  /* LOG + co */
}

/* Fresh state per case; run one shape. */
static int c_case(const char *label, const char *objname,
                  lua_CFunction body, int dead_with_error,
                  int use_lua_close) {
    lua_State *L = luaL_newstate();
    if (!L) {
        printf("%s FAIL: newstate\n", label);
        return 1;
    }
    luaL_openlibs(L);
    c_run_case(L, label, objname, body, dead_with_error, use_lua_close);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */

int main(void) {
    /* Unbuffered stdout: if a runtime dies on a signal mid-suite, every
    ** line printed before the crash is still visible in the lane logs. */
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== 23_tbc_semantics: P16.31 TBC hook-lane + close context ===\n");
    /* Group H first: the hook-lane shapes exercise the Cut 5 fixes
    ** (lua_toclose on a Lua frame + the closethread transport). */
    if (t_ha())  return 1;
    if (t_hc())  return 1;
    if (t_hd())  return 1;
    if (t_he())  return 1;
    if (t_hb2()) return 1;
    /* Group C: the c_api-lane close thread-context + quoting shapes. */
    if (c_case("C-S1", "COOBJ", c_tbc_pcallk, 0, 0)) return 1;
    if (c_case("C-S2", "COOBJ", c_tbc_pcallk, 0, 1)) return 1;
    if (c_case("C-S3", "COOBJ", c_tbc_callk_conterr, 1, 0)) return 1;
    if (c_case("C-S4", "ERRCLOSER", c_tbc_callk_conterr, 1, 0)) return 1;
    if (c_case("C-S0", "COOBJ", c_tbc_pcallk_nullk, 0, 0)) return 1;
    printf("=== 23_tbc_semantics DONE ===\n");
    return 0;
}
