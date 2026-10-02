/*
** 39_resume_error_window.c — C-S3: the lua_resume error publication must
** preserve the live C window (PUC luaD_seterrorobj appends the error at
** the coroutine's CURRENT top; it never collapses the window). PERMANENT
** differential suite (luazig vs PUC 5.5).
**
** PUC model under test (ldo.c lua_resume error arm + luaD_seterrorobj +
** lstate.c luaE_resetthread): when a resumed coroutine dies with an
** unrecoverable error, PUC keeps the raising frame's CallInfo in place
** (luaD_throw never pops it), so the publication duplicates the top-1
** error object at the live top and *nresults counts the WHOLE frozen
** window [ci->func+1, top). The window — TBC-marked slots included —
** stays observable to the host until lua_closethread, whose
** luaE_resetthread closes the marks on the ORIGINAL objects with the
** original error (a closer error is last-error-wins). A reconstruction
** that collapses the window onto its base clobbers marked slots and
** detaches the marked objects from that contract (the C-S3/C-S4 bug).
**
** Cases (one fresh lua_State + coroutine per case; the C body is a C
** closure registered as the global CBODY and called from a fixed body
** closure loaded from the SAME chunk source as suite 23, so every
** position prefix embedded in error objects stays in the proven
** chunk-name-quoting regime):
**
**   W-KEPT  toclose + lua_callk continuation error (the C-S3 core):
**           resume2 reports st=2 with the FULL window
**           [COOBJ, YFN, err, err] (nres=4, slot types, marked-object
**           identity via rawequal against the global's value moved onto
**           the coroutine, duplicate-pair identity); lua_closethread
**           runs the closer ON the coroutine with the ORIGINAL error;
**           a repeated closethread is a no-op (st=0, no second close).
**
**   W-LAST  same shape with an erroring closer (C-S4): the closer still
**           sees the ORIGINAL error; last-error-wins makes closethread
**           return the closer's error; repeated closethread st=0.
**
**   W-KE    pcallk recovery error + continuation error (the P2 shape):
**           the recovery leaves the callee's error ("boom") in the
**           window below the k error; the publication keeps
**           [COOBJ, YFN, boom, kerr, kerr] (nres=5); the mark closes
**           with the k error.
**
**   W-COIN  coincidence edge: a RAW C body (no callk) whose frame the
**           error return pops; after the pop the window's top-1 equals
**           the error object BY VALUE ("xerr"), but the frozen window is
**           already lost — the eligibility must follow the geometry and
**           choose the reconstruction: nres=2 [str, str] (a value-based
**           eligibility would expose nres=3 [table, str, str]).
**
**   W-RBC   reject-before-call control: resuming the dead coroutine
**           reports st=2 "cannot resume dead coroutine" (PUC
**           resume_error pops the args and appends the message once).
**
**   W-PCALLK recovery control: a pcallk recovery consumes the error
**           (the coroutine keeps running), the C body returns, the mark
**           closes at the body's return with err=nil, and the coroutine
**           completes normally.
**
**   W-OOM   ERRMEM control: a continuation that hits a denied
**           allocation (custom allocator frozen from inside the
**           continuation) reports st=4 with the FIXED "not enough
**           memory" object. Only st + the top value are asserted: PUC
**           keeps the window and appends one memerrmsg while the zig
**           OOM publication reconstructs (a documented, kept-divergent
**           OOM semantics pair; the status and the error object are the
**           parity contract).
**
**   W-TBL   non-string error object: the continuation raises a TABLE;
**           the window keeps [COOBJ, YFN, tbl, tbl] (types + rawequal
**           only — no addresses); the closer logs type(e)="table";
**           closethread reports st=2 with a non-string top (err=none).
**
**   W-SETTOP lua_settop(co, 0) between resume and closethread: the
**           truncation closes the mark EARLY with err=nil (PUC
**           luaF_close(newtop, CLOSEKTOP, yy=0)); the subsequent
**           closethread reports st=2 (status only: PUC's error object
**           there is the stale func-slot closure, a non-string, while
**           zig reports the latched original error — a documented
**           split-stack divergence; the close LOG is the contract).
**           The closer's running-thread identity is NOT asserted: the
**           cross-thread settop close runs it on the caller's identity
**           in zig vs the coroutine in PUC — a documented divergence
**           newly reachable through the preserved window (finding F1
**           in the cut report; this case's setup logs the error
**           argument only).
**
**   W-GC    full GC between resume and closethread: the dead thread's
**           window keeps the marked object and the error objects alive
**           (they are GC roots through the frozen window); the closer
**           still runs on the ORIGINAL object with the original error.
**
** Determinism rules (same as 22/23): only fixed labels, statuses and
** controlled strings are printed; error objects carry only fixed
** position prefixes from short, fixed chunk sources; no addresses, no
** table stringifications.
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* ------------------------------------------------------------------ */
/* The fixed setup (byte-identical to suite 23's C_SETUP_LUA, so the    */
/* ERRCLOSER position prefix stays in the proven quoting regime).       */
/* COOBJ/ERRCLOSER: __close logs the running thread ("CO" = the         */
/* coroutine under test, held in the global COTEST) and the error       */
/* argument (type name for non-string errors) into the global LOG;      */
/* ERRCLOSER then raises "closer-boom". YFN: the yielding callee.       */
/* ------------------------------------------------------------------ */
#define C_SETUP_LUA                                                     \
    "COOBJ = setmetatable({}, {__close = function(_, e)\n"              \
    "  local c, ismain = coroutine.running()\n"                         \
    "  local where = (c == _G.COTEST) and 'CO' or (ismain and 'MAIN' or 'OTHER')\n" \
    "  local es = (type(e) == 'string') and e or type(e)\n"             \
    "  _G.LOG = _G.LOG .. '|' .. where .. '/' .. es\n"                  \
    "end})\n"                                                           \
    "ERRCLOSER = setmetatable({}, {__close = function(_, e)\n"          \
    "  local c, ismain = coroutine.running()\n"                         \
    "  local where = (c == _G.COTEST) and 'CO' or (ismain and 'MAIN' or 'OTHER')\n" \
    "  local es = (type(e) == 'string') and e or type(e)\n"             \
    "  _G.LOG = _G.LOG .. '|' .. where .. '/' .. es\n"                  \
    "  error('closer-boom')\n"                                          \
    "end})\n"                                                           \
    "YFN = function() coroutine.yield('from-fn') end\n"

/* The W-SETTOP setup: the closer logs the error argument ONLY (no
** running-thread identity). The cross-thread lua_settop(co, 0)
** truncation close runs the closer with the CALLER's thread identity in
** zig (current_thread is not switched for the settop close) while PUC
** runs it on the coroutine — a documented divergence newly reachable
** through the preserved window (at HEAD the same operation hit the
** clobbered-mark nil-metamethod error instead); the identity axis is
** excluded here pending its own cut (see the cut report, finding F1).
** The case's contract is the EARLY close itself: err=nil, yy=0. */
#define C_SETUP_SETTOP_LUA                                              \
    "COOBJ = setmetatable({}, {__close = function(_, e)\n"              \
    "  local es = (type(e) == 'string') and e or type(e)\n"             \
    "  _G.LOG = _G.LOG .. '|' .. es\n"                                  \
    "end})\n"                                                           \
    "YFN = function() coroutine.yield('from-fn') end\n"

/* The body closure source (built per case with the marked object's
** global name; the chunk sources are short and fixed — the same quoting
** regime suite 23 proven byte-identical between the runtimes). */
static const char *body_src(const char *objname) {
    static char buf[96];
    snprintf(buf, sizeof buf, "return function() CBODY(%s, YFN) end",
             objname);
    return buf;
}

/* The W-COIN body source: a table and the value-equal local below the
** raw C call, so the popped frame's top-1 ("xerr") equals the error
** object by value (the chunk name never enters a printed error object;
** only slot types and the pair identity are asserted). */
#define C_COIN_BODY_LUA "return function() local t={} local x=\"xerr\" CBODY() end"

/* The W-PCALLK body source: the coroutine's result IS the protected
** call's result, so the continuation's observation of the recovery
** (status + the recovered error object) is observable as the
** completion's result. */
#define C_RECOVER_BODY_LUA "return function() return CBODY(COOBJ, YFN) end"

/* ------------------------------------------------------------------ */
/* C bodies and continuations                                          */
/* ------------------------------------------------------------------ */

/* W-PCALLK continuation: after the yield, the callee errors inside the
** pcallk protection and the recovery hands the error to the
** continuation (status + the error object on top of the stack).
** Observe both and return the observation as the protected call's
** result — the recovery consumed the error, so the coroutine completes
** normally with this value. */
static int k_recover(lua_State *L, int status, lua_KContext ctx) {
    (void)ctx;
    if (status == LUA_OK) {
        lua_pushliteral(L, "k:ok");
        return 1;
    }
    lua_pushfstring(L, "k:%d:%s", status,
                    lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
    return 1;
}

/* Erroring continuation for lua_callk: kills the coroutine, leaving the
** parked C frame and its mark pending on the dead thread (suite 23's
** k_cont_error, verbatim). */
static int k_cont_error(lua_State *L, int status, lua_KContext ctx) {
    (void)status; (void)ctx;
    return luaL_error(L, "cont-err");
}

/* W-KEPT/W-LAST/W-TBL/W-SETTOP/W-GC body: mark arg 1 TBC, call arg 2
** through lua_callk whose continuation errors (suite 23's
** c_tbc_callk_conterr, verbatim). */
static int c_tbc_callk_conterr(lua_State *L) {
    lua_toclose(L, 1);
    lua_pushvalue(L, 2);
    lua_callk(L, 0, 0, (lua_KContext)0, k_cont_error);
    return 0;
}

/* W-TBL continuation: raise a TABLE as the error object. */
static int k_cont_tblerr(lua_State *L, int status, lua_KContext ctx) {
    (void)status; (void)ctx;
    lua_newtable(L);
    return lua_error(L);
}

static int c_tbc_callk_tblerr(lua_State *L) {
    lua_toclose(L, 1);
    lua_pushvalue(L, 2);
    lua_callk(L, 0, 0, (lua_KContext)0, k_cont_tblerr);
    return 0;
}

/* W-KE continuation: itself errors after a pcallk recovery consumed the
** YPCALL frame (no recover point remains — the resume fails uncaught
** with the k error on top of the recovery's error). */
static int k_after_recovery_err(lua_State *L, int status, lua_KContext ctx) {
    (void)status; (void)ctx;
    return luaL_error(L, "kerr");
}

static int c_tbc_pcallk_kerr(lua_State *L) {
    lua_toclose(L, 1);
    lua_pushvalue(L, 2);
    lua_pcallk(L, 0, 0, 0, (lua_KContext)0, k_after_recovery_err);
    return 0;
}

/* W-PCALLK body: mark arg 1 TBC, call arg 2 through lua_pcallk; after
** the yield the recovery hands the callee's error to k_recover (the
** code below the pcallk never runs on the resume path). */
static int c_tbc_pcallk_recover(lua_State *L) {
    lua_toclose(L, 1);
    lua_pushvalue(L, 2);
    lua_pcallk(L, 0, 0, 0, (lua_KContext)0, k_recover);
    return 0;  /* not reached after the yield: k_recover resumes */
}

/* W-COIN body: a RAW C function (no callk, no pcallk) that raises
** "xerr". Its frame is popped by the error return, so the publication
** must reconstruct even though the popped frame's top-1 ("xerr", the
** body's local) equals the error object by value. */
static int c_raw_xerr(lua_State *L) {
    (void)L;
    lua_pushliteral(L, "xerr");
    return lua_error(L);
}

/* ------------------------------------------------------------------ */
/* W-OOM: custom allocator frozen from inside the continuation          */
/* ------------------------------------------------------------------ */

static int g_deny;

static void *lalloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    (void)ud;
    if (g_deny && nsize > osize) return NULL;  /* deny growth/fresh */
    if (nsize == 0) { free(ptr); return NULL; }
    return realloc(ptr, nsize);
}

static int g_oom_ctr;

/* W-OOM continuation: freeze the allocator, then force a FRESH string
** allocation (lua_pushfstring of an uninterned value) — the denied
** allocation raises ERRMEM with the fixed MEMERRMSG on both runtimes. */
static int k_cont_oom(lua_State *L, int status, lua_KContext ctx) {
    (void)status; (void)ctx;
    g_deny = 1;
    lua_pushfstring(L, "oom-%d", ++g_oom_ctr);
    return lua_error(L);  /* not reached when the push throws */
}

static int c_tbc_callk_oom(lua_State *L) {
    lua_toclose(L, 1);
    lua_pushvalue(L, 2);
    lua_callk(L, 0, 0, (lua_KContext)0, k_cont_oom);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Report helpers                                                      */
/* ------------------------------------------------------------------ */

/* Resume and report st + nres + top value (parity shapes). */
static void do_resume(lua_State *L, lua_State *co, const char *label) {
    int nres = 0;
    int st = lua_resume(co, L, 0, &nres);
    printf("%s: st=%d nres=%d val=%s\n", label, st, nres,
           (nres > 0 && lua_isstring(co, -1)) ? lua_tostring(co, -1) : "-");
}

/* Resume and report st + the FULL published window: nres, per-slot type
** names, the marked-object identity (slot 1 vs the global COOBJ's value
** moved onto the coroutine), and the duplicate-pair identity (the top
** two slots). The moved reference is popped before returning. */
static void do_resume_win(lua_State *L, lua_State *co, const char *label,
                          const char *ident_global) {
    int nres = 0;
    int st = lua_resume(co, L, 0, &nres);
    printf("%s: st=%d nres=%d types=[", label, st, nres);
    for (int i = 1; i <= nres; i++)
        printf("%s%s", (i > 1 ? "," : ""),
               lua_typename(co, lua_type(co, i)));
    printf("]");
    if (ident_global) {
        lua_getglobal(L, ident_global);
        lua_xmove(L, co, 1);  /* the identity reference, above the window */
        printf(" mark_is_obj=%d", lua_rawequal(co, 1, -1));
        lua_pop(co, 1);
    }
    if (nres >= 2)
        printf(" pair_equal=%d", lua_rawequal(co, nres - 1, nres));
    printf("\n");
}

/* Resume and report st + top value only (no nres: PUC's resume_error
** returns before setting *nresults). */
static void do_resume_val(lua_State *L, lua_State *co, const char *label) {
    int nres = 0;
    int st = lua_resume(co, L, 0, &nres);
    printf("%s: st=%d val=%s\n", label, st,
           (lua_gettop(co) > 0 && lua_isstring(co, -1))
               ? lua_tostring(co, -1) : "-");
}

/* Close a thread from C and report status + error object (if a string). */
static void do_closethread(lua_State *L, lua_State *co, const char *label) {
    int st = lua_closethread(co, L);
    printf("%s: st=%d err=%s\n", label, st,
           (st != LUA_OK && lua_isstring(co, -1)) ? lua_tostring(co, -1)
                                                  : "none");
}

/* Close a thread and report the STATUS only (for shapes where the error
** object itself is a documented divergence — W-SETTOP). */
static void do_closethread_st(lua_State *L, lua_State *co, const char *label) {
    int st = lua_closethread(co, L);
    printf("%s: st=%d\n", label, st);
}

/* Print the closers' LOG. */
static void print_log(lua_State *L, const char *label) {
    lua_getglobal(L, "LOG");
    printf("%s: %s\n", label,
           (lua_isstring(L, -1) && lua_tostring(L, -1)[0])
               ? lua_tostring(L, -1) : "(empty)");
    lua_pop(L, 1);
}

/* ------------------------------------------------------------------ */
/* The case driver                                                     */
/* ------------------------------------------------------------------ */

/*
** Build the coroutine under test: reset LOG, run the fixed setup,
** register `body` as the global CBODY, optionally override YFN with a
** yielding-then-erroring variant (a short load chunk — no long chunk
** names enter error objects), load the body closure from `src`, and
** create co = coroutine.create(<body closure>) with the marked object
** `objname`, anchored in COTEST for the Lua closers' identity check.
*/
static lua_State *w_setup2(lua_State *L, lua_CFunction body,
                           const char *yfn_override, const char *src,
                           const char *setup) {
    lua_State *co;
    lua_pushliteral(L, "");
    lua_setglobal(L, "LOG");
    if (luaL_dostring(L, setup) != 0) {
        printf("FAIL setup: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_pop(L, 1);
        return NULL;
    }
    if (yfn_override) {
        if (luaL_dostring(L, yfn_override) != 0) {
            printf("FAIL yfn: %s\n",
                   lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
            lua_pop(L, 1);
            return NULL;
        }
    }
    lua_pushcfunction(L, body);
    lua_setglobal(L, "CBODY");
    if (luaL_loadstring(L, src) != 0 || lua_pcall(L, 0, 1, 0) != 0) {
        printf("FAIL body: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_pop(L, 1);
        return NULL;
    }
    lua_getglobal(L, "coroutine");
    lua_getfield(L, -1, "create");
    lua_remove(L, -2);
    lua_pushvalue(L, -2);  /* the body closure */
    if (lua_pcall(L, 1, 1, 0) != 0) {
        printf("FAIL create: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_pop(L, 2);
        return NULL;
    }
    co = lua_tothread(L, -1);
    if (!co) {
        printf("FAIL: not a thread\n");
        lua_pop(L, 1);
        return NULL;
    }
    lua_pushvalue(L, -1);
    lua_setglobal(L, "COTEST");
    return co;  /* anchored on L's stack */
}

/* Common setup (the identity-logging closers). */
static lua_State *w_setup(lua_State *L, lua_CFunction body,
                          const char *yfn_override, const char *src) {
    return w_setup2(L, body, yfn_override, src, C_SETUP_LUA);
}

/* Fresh state per case. */
static lua_State *w_begin(void) {
    lua_State *L = luaL_newstate();
    if (L) luaL_openlibs(L);
    return L;
}

/* ------------------------------------------------------------------ */
/* Cases                                                               */
/* ------------------------------------------------------------------ */

/* W-KEPT: the C-S3 core — full window + identity + close + reclose. */
static int t_w_kept(void) {
    lua_State *L = w_begin();
    lua_State *co;
    if (!L) return 1;
    co = w_setup(L, c_tbc_callk_conterr, NULL, body_src("COOBJ"));
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "W-KEPT resume1");      /* yield: st=1 val=from-fn */
    do_resume_win(L, co, "W-KEPT resume2", "COOBJ"); /* st=2 nres=4 full window */
    do_closethread(L, co, "W-KEPT closethread"); /* closer + orig err */
    print_log(L, "W-KEPT log1");             /* |CO/<orig err> */
    do_closethread(L, co, "W-KEPT reclose"); /* st=0, no second close */
    print_log(L, "W-KEPT log2");
    lua_close(L);
    return 0;
}

/* W-LAST: C-S4 — erroring closer, last-error-wins. */
static int t_w_last(void) {
    lua_State *L = w_begin();
    lua_State *co;
    if (!L) return 1;
    co = w_setup(L, c_tbc_callk_conterr, NULL, body_src("ERRCLOSER"));
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "W-LAST resume1");
    do_resume_win(L, co, "W-LAST resume2", "ERRCLOSER");
    do_closethread(L, co, "W-LAST closethread"); /* st=2 err=closer-boom */
    print_log(L, "W-LAST log1");             /* |CO/<orig err> */
    do_closethread(L, co, "W-LAST reclose"); /* st=0 */
    print_log(L, "W-LAST log2");
    lua_close(L);
    return 0;
}

/* W-KE: pcallk recovery error + k error — the P2 window shape. */
static int t_w_ke(void) {
    lua_State *L = w_begin();
    lua_State *co;
    if (!L) return 1;
    co = w_setup(L, c_tbc_pcallk_kerr,
                 "YFN = load('coroutine.yield(\"y\") error(\"boom\")')",
                 body_src("COOBJ"));
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "W-KE resume1");        /* yield: st=1 val=y */
    do_resume_win(L, co, "W-KE resume2", "COOBJ"); /* st=2 nres=5 */
    do_closethread(L, co, "W-KE closethread"); /* closer + kerr */
    print_log(L, "W-KE log1");               /* |CO/<kerr> */
    do_closethread(L, co, "W-KE reclose");   /* st=0 */
    print_log(L, "W-KE log2");
    lua_close(L);
    return 0;
}

/* W-COIN: coincidence edge — the raw C body's popped frame leaves a
** value-equal top-1, but the window is lost: reconstruction (nres=2). */
static int t_w_coin(void) {
    lua_State *L = w_begin();
    lua_State *co;
    if (!L) return 1;
    co = w_setup(L, c_raw_xerr, NULL, C_COIN_BODY_LUA);
    if (!co) { lua_close(L); return 1; }
    do_resume_win(L, co, "W-COIN resume1", NULL); /* st=2 nres=2 [str,str] */
    lua_close(L);
    return 0;
}

/* W-RBC: reject-before-call control on the dead coroutine. */
static int t_w_rbc(void) {
    lua_State *L = w_begin();
    lua_State *co;
    if (!L) return 1;
    co = w_setup(L, c_tbc_callk_conterr, NULL, body_src("COOBJ"));
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "W-RBC resume1");
    do_resume_val(L, co, "W-RBC resume2");   /* st=2 val=cont-err */
    do_resume_val(L, co, "W-RBC resume3");   /* st=2 cannot resume dead */
    lua_close(L);
    return 0;
}

/* W-PCALLK: recovery control — the coroutine survives the error. */
static int t_w_pcallk(void) {
    lua_State *L = w_begin();
    lua_State *co;
    if (!L) return 1;
    co = w_setup(L, c_tbc_pcallk_recover,
                 "YFN = load('coroutine.yield(\"y\") error(\"boom\")')",
                 C_RECOVER_BODY_LUA);
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "W-PCALLK resume1");    /* yield: st=1 val=y */
    do_resume(L, co, "W-PCALLK resume2");    /* completes: st=0 k:2:boom */
    print_log(L, "W-PCALLK log1");           /* |CO/nil (mark at return) */
    do_closethread(L, co, "W-PCALLK closethread"); /* st=0, no close */
    print_log(L, "W-PCALLK log2");
    lua_close(L);
    return 0;
}

/* W-OOM: ERRMEM control — st + the fixed message only. */
static int t_w_oom(void) {
    lua_State *L = lua_newstate(lalloc, NULL, 0);
    lua_State *co;
    if (!L) return 1;
    luaL_openlibs(L);
    g_deny = 0;
    co = w_setup(L, c_tbc_callk_oom, NULL, body_src("COOBJ"));
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "W-OOM resume1");       /* yield: st=1 */
    do_resume_val(L, co, "W-OOM resume2");   /* st=4 not enough memory */
    g_deny = 0;  /* unfreeze before teardown */
    /* The VM stays usable after the failure (the frozen-allocator error
    ** left no corrupt state): run a chunk and read its result back. */
    if (luaL_dostring(L, "return 'alive'") != 0) {
        printf("W-OOM reuse: FAILED\n");
        lua_close(L);
        return 1;
    }
    printf("W-OOM reuse: %s\n", lua_tostring(L, -1));
    lua_pop(L, 1);
    lua_close(L);
    return 0;
}

/* W-TBL: non-string error object — types + rawequal only. */
static int t_w_tbl(void) {
    lua_State *L = w_begin();
    lua_State *co;
    if (!L) return 1;
    co = w_setup(L, c_tbc_callk_tblerr, NULL, body_src("COOBJ"));
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "W-TBL resume1");
    do_resume_win(L, co, "W-TBL resume2", "COOBJ"); /* st=2 nres=4 [tbl,fn,tbl,tbl] */
    do_closethread(L, co, "W-TBL closethread"); /* st=2 err=none */
    print_log(L, "W-TBL log1");               /* |CO/table */
    do_closethread(L, co, "W-TBL reclose");   /* st=0 */
    print_log(L, "W-TBL log2");
    lua_close(L);
    return 0;
}

/* W-SETTOP: early close via lua_settop(co, 0) between resume and close. */
static int t_w_settop(void) {
    lua_State *L = w_begin();
    lua_State *co;
    if (!L) return 1;
    co = w_setup2(L, c_tbc_callk_conterr, NULL, body_src("COOBJ"),
                  C_SETUP_SETTOP_LUA);
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "W-SETTOP resume1");
    do_resume_win(L, co, "W-SETTOP resume2", "COOBJ"); /* the published window */
    lua_settop(co, 0);                        /* truncation closes the mark */
    print_log(L, "W-SETTOP log1");            /* |CO/nil (err=nil close) */
    do_closethread_st(L, co, "W-SETTOP closethread"); /* st=2 (status only) */
    print_log(L, "W-SETTOP log2");            /* unchanged: one close */
    do_closethread_st(L, co, "W-SETTOP reclose");     /* st=0 */
    lua_close(L);
    return 0;
}

/* W-GC: full GC between resume and closethread. */
static int t_w_gc(void) {
    lua_State *L = w_begin();
    lua_State *co;
    if (!L) return 1;
    co = w_setup(L, c_tbc_callk_conterr, NULL, body_src("COOBJ"));
    if (!co) { lua_close(L); return 1; }
    do_resume(L, co, "W-GC resume1");
    do_resume_win(L, co, "W-GC resume2", "COOBJ");
    lua_gc(L, LUA_GCCOLLECT);                 /* full GC across the VM */
    printf("W-GC gc done\n");
    do_closethread(L, co, "W-GC closethread"); /* closer + orig err */
    print_log(L, "W-GC log1");                /* |CO/<orig err> */
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */

int main(void) {
    /* Unbuffered stdout: if a runtime dies on a signal mid-suite, every
    ** line printed before the crash is still visible in the lane logs. */
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== 39_resume_error_window: C-S3 live C-window at the resume error publication ===\n");
    if (t_w_kept())   return 1;
    if (t_w_last())   return 1;
    if (t_w_ke())     return 1;
    if (t_w_coin())   return 1;
    if (t_w_rbc())    return 1;
    if (t_w_pcallk()) return 1;
    if (t_w_oom())    return 1;
    if (t_w_tbl())    return 1;
    if (t_w_settop()) return 1;
    if (t_w_gc())     return 1;
    printf("=== 39_resume_error_window DONE ===\n");
    return 0;
}
