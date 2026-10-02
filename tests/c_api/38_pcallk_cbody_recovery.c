/*
** 38_pcallk_cbody_recovery — permanent differential suite for the C/YPCALL
** recovery owner when the coroutine body is a C closure resumed DIRECTLY
** through lua_resume (no Lua wrapper frame). Suite 37 drives its C bodies
** from a Lua wrapper closure, so the recovery runs through the Lua-body
** trampoline; this suite covers the fresh-C-body lane where the body error
** itself reaches the lua_resume boundary.
**
** PUC model under test (lapi.c lua_pcallk yieldable branch, ldo.c resume /
** precover / unroll / finishCcall / finishpcallk):
**
**   lua_pcallk with a continuation on a yieldable thread does NOT install
**   its own protection ("call is already protected by 'resume'"): it arms
**   the CALLER's CallInfo with CIST_YPCALL and does an unprotected
**   luaD_call. An immediate error (no yield) therefore longjmps straight
**   to lua_resume's rawrunprotected, and precover routes it back into the
**   armed frame: finishpcallk runs luaF_close over the recovery region
**   (yieldable: a __close may suspend the resume) and hands the error
**   status/object to the continuation k, which finishes the C body frame
**   (the code below the lua_pcallk call never runs). A k that itself
**   errors finds no recover point (finishpcallk cleared CIST_YPCALL
**   before k ran) and the resume fails uncaught. A closer that errors
**   re-enters precover with the closer's error (last-error-wins) and k
**   sees the REPLACED object. Nested pcallk recover through the innermost
**   armed frame first; the outer frame's k then runs with the YIELD
**   status (its callee "completed" via the inner recovery).
**
** Cases (one fresh lua_State + one fresh coroutine per case; the body is
** pushed as a C closure onto the coroutine's own stack):
**
**   NR    normal result: the body's pcallk on a succeeding callee returns
**         LUA_OK synchronously (k does not run); the body returns results.
**   BY    baseline yield: the body's pcallk on a yielding callee suspends
**         the resume; resume#2 re-drives the continuation (k status=1)
**         and the body completes with the callee's results.
**   BE    direct error recovery (the P-1 shape): the callee errors, the
**         recovery close runs the marked arg's __close with the ORIGINAL
**         error object, k finishes the body with status=2, and the resume
**         completes LUA_OK (thread not dead).
**   YC    yielding closer: the recovery close suspends the resume (yield
**         inside __close), a FULL GC runs between the resumes, resume#2
**         finishes the close and k sees status=2 with the SAME error
**         object (rawequal against the registry-ref'd original).
**   CE    closer error: the closer errors inside the recovery close; the
**         recovery re-runs (repeated precover) and k sees the REPLACED
**         error object.
**   KE    continuation error: k itself errors after the recovery consumed
**         the YPCALL frame; no recover point remains and the resume fails
**         uncaught with the k error.
**   OM    ERRMEM recovery: the callee allocates 1 TiB; k runs with
**         status=4 and the FIXED "not enough memory" object (the pcallk
**         defer covers ERRMEM too).
**   NESTK nested pcallk: the body pcallk's a C function that itself
**         pcallk's the erroring callee; the inner k recovers the error
**         and the outer k finishes the body (each k sees its own window).
**   GR    recovery + full GC + VM reuse: after a completed recovery the
**         same state survives a full GC, drives a second direct-body
**         coroutine, and keeps executing chunks.
**
** Callees that receive the marked slot as an argument are VARARG
** ("local a = ..."): a vararg callee's frame base sits above the extra
** args, so its registers never alias the marked slot (the staging-slot
** identity divergence is a separate open item, not this suite's contract).
**
** Chronological event stream: every observable event prints at the moment
** it happens (k continuations run inside the lua_resume window that
** finishes the protected call; __close bodies log through the registered
** logc()), so the interleaving of closer/k activity relative to the
** lua_resume / lua_gc calls is part of the compared contract.
*/
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* ------------------------------------------------------------------ */
/* immediate chronological event output                                */
/* ------------------------------------------------------------------ */

static void ev(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
}

/* Lua-side __close bodies log through this registered C function so the
** closer activity joins the same chronological stream at the moment the
** closer runs (inside a resume/recovery window). */
static int logc(lua_State *L) {
    printf("closer: %s\n", luaL_checkstring(L, 1));
    return 0;
}

/* ------------------------------------------------------------------ */
/* shared helpers                                                      */
/* ------------------------------------------------------------------ */

/* Dump the current window into ONE event line: tag, status, top, every
** value (type + controlled payload); rawequal identity against the
** registry-ref'd original when ctx carries a ref. */
static void dump_window(lua_State *L, int status, lua_KContext ctx,
                        const char *tag) {
    int top = lua_gettop(L);
    int i;
    char line[512];
    int n = snprintf(line, sizeof line, "%s: status=%d top=%d", tag,
                     status, top);
    for (i = 1; i <= top && n < (int)sizeof line - 1; i++) {
        int t = lua_type(L, i);
        char piece[96];
        if (t == LUA_TTABLE) {
            lua_getfield(L, i, "id");
            if (lua_isinteger(L, -1))
                snprintf(piece, sizeof piece, " a%d=table(id=%lld)", i,
                         (long long)lua_tointeger(L, -1));
            else
                snprintf(piece, sizeof piece, " a%d=table(id=nil)", i);
            lua_pop(L, 1);
        }
        else if (t == LUA_TSTRING)
            snprintf(piece, sizeof piece, " a%d=string(%s)", i,
                     lua_tostring(L, i));
        else
            snprintf(piece, sizeof piece, " a%d=%s", i, lua_typename(L, t));
        n += snprintf(line + n, sizeof line - (size_t)n, "%s", piece);
    }
    if (ctx != 0 && top >= 1) {
        int ref = (int)ctx;
        char piece[64];
        lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
        snprintf(piece, sizeof piece, " rawequal_a1_orig=%d",
                 lua_rawequal(L, 1, -1));
        n += snprintf(line + n, sizeof line - (size_t)n, "%s", piece);
        lua_pop(L, 1);
    }
    ev("%s", line);
}

static int k_fin(lua_State *L, int status, lua_KContext ctx) {
    dump_window(L, status, ctx, "CONT");
    return 0;
}

static int k_in(lua_State *L, int status, lua_KContext ctx) {
    dump_window(L, status, ctx, "CONT_IN");
    return 0;
}

static int k_out(lua_State *L, int status, lua_KContext ctx) {
    dump_window(L, status, ctx, "CONT_OUT");
    return 0;
}

/* KE's continuation: dumps its window, then raises — after the recovery
** consumed the YPCALL frame there is no recover point left, so the error
** must escape the resume uncaught. */
static int k_err(lua_State *L, int status, lua_KContext ctx) {
    dump_window(L, status, ctx, "CONT_KERR");
    lua_pushstring(L, "kerr");
    return lua_error(L);
}

/* ------------------------------------------------------------------ */
/* case bodies (C closures resumed directly as coroutine bodies)        */
/* ------------------------------------------------------------------ */

/* NR: bret() — pcallk(0) on a succeeding callee: LUA_OK returns to the
** body synchronously (no continuation runs); the body returns the
** callee's results. */
static int bret(lua_State *L) {
    int st = lua_pcallk(L, 0, LUA_MULTRET, 0, 0, k_fin);
    ev("bret: pcallk returned %d top=%d", st, lua_gettop(L));
    if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
    return lua_gettop(L);
}

/* BY: byld(f) — pcallk(0) on a yielding callee: the resume suspends with
** the callee's yield values; resume#2 re-drives the continuation with
** status=1 and the callee's results become the body's results. */
static int byld(lua_State *L) {
    int st = lua_pcallk(L, 0, LUA_MULTRET, 0, 0, k_fin);
    ev("byld: pcallk returned %d top=%d", st, lua_gettop(L));
    if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
    return lua_gettop(L);
}

/* BE/YC/CE: berr(f, v) — window [berr, f, v]; toclose(v) (the callee's
** argument, INSIDE the recovery region); ref v for k's rawequal identity
** check; pcallk(1) with v as the arg. On a direct error the recovery
** close runs v's __close (which may yield or error) and k finishes the
** body frame — the code below the pcallk never runs on that path. */
static int berr(lua_State *L) {
    int ref;
    lua_toclose(L, 2);
    lua_pushvalue(L, 2);
    ref = luaL_ref(L, LUA_REGISTRYINDEX);
    {
        int st = lua_pcallk(L, 1, LUA_MULTRET, 0, (lua_KContext)ref, k_fin);
        ev("berr: pcallk returned %d top=%d", st, lua_gettop(L));
        luaL_unref(L, LUA_REGISTRYINDEX, ref);
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L) - 1;
    }
}

/* KE: bkerr(f) — pcallk(0) on an erroring callee with k_err as the
** continuation: the recovery hands the error to k_err, whose own error
** finds no recover point and must escape the resume uncaught. */
static int bkerr(lua_State *L) {
    int st = lua_pcallk(L, 0, LUA_MULTRET, 0, 0, k_err);
    ev("bkerr: pcallk returned %d top=%d", st, lua_gettop(L));
    if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
    return lua_gettop(L);
}

/* OM: bom() — the pcallk'd callee allocates 1 TiB: ERRMEM; the pcallk
** defer covers ERRMEM, so k runs with status=4 and the FIXED "not enough
** memory" object. */
static int oom_inner(lua_State *L) {
    (void)lua_newuserdatauv(L, (size_t)1 << 40, 0);
    return 0;
}

static int bom(lua_State *L) {
    lua_pushcfunction(L, oom_inner);
    {
        int st = lua_pcallk(L, 0, LUA_MULTRET, 0, 0, k_fin);
        ev("bom: pcallk returned %d top=%d", st, lua_gettop(L));
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L);
    }
}

/* NESTK: bnest() — the body pcallk's the C function cmid; cmid itself
** pcallk's the erroring callee. The inner error recovers at cmid's armed
** frame (k_in, status=2); the body's armed frame is then finished by
** k_out. Neither body's nor cmid's post-pcallk code runs. */
static int cmid(lua_State *L) {
    lua_getglobal(L, "F_BOOMV");
    {
        int st = lua_pcallk(L, 0, LUA_MULTRET, 0, 0, k_in);
        ev("cmid: pcallk returned %d top=%d", st, lua_gettop(L));
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L);
    }
}

static int bnest(lua_State *L) {
    lua_pushcfunction(L, cmid);
    {
        int st = lua_pcallk(L, 0, LUA_MULTRET, 0, 0, k_out);
        ev("bnest: pcallk returned %d top=%d", st, lua_gettop(L));
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L);
    }
}

/* ------------------------------------------------------------------ */
/* driver                                                              */
/* ------------------------------------------------------------------ */

static void report(const char *tag, int st, int nres, lua_State *co) {
    int i;
    printf("%s: st=%d nres=%d status=%s", tag, st, nres,
           st == 0 ? "ok" : st == 1 ? "yield" :
           st == 2 ? "run" : st == 4 ? "mem" : st == 5 ? "err" : "?");
    for (i = 0; i < nres && i < 4; i++) {
        int idx = -(nres - i);
        if (lua_isstring(co, idx))
            printf(" r%d=string(%s)", i, lua_tostring(co, idx));
        else if (lua_isboolean(co, idx))
            printf(" r%d=bool(%d)", i, lua_toboolean(co, idx));
        else
            printf(" r%d=%s", i, lua_typename(co, lua_type(co, idx)));
    }
    printf("\n");
}

/* Uncaught-error report for the KE shape: the failed resume's STATUS and
** the TOP error object (the escaping continuation error). The full
** leftover window below the error object (PUC keeps the raising C
** frame's whole window: the consumed recovery's error object and the
** raiser's pushes; nres counts them) is a documented open divergence of
** the general C-raise error-window publication — it reproduces on a
** plain C body with arguments and no pcallk at all, so it is not this
** suite's contract; this case pins the recovery control flow: the
** continuation RUNS (CONT_KERR below), ITS error escapes uncaught, and
** the thread dies with the continuation's error on top. */
static void report_uncaught(const char *tag, int st, lua_State *co) {
    printf("%s: st=%d", tag, st);
    if (lua_isstring(co, -1))
        printf(" top_err=string(%s)", lua_tostring(co, -1));
    else
        printf(" top_err=%s", lua_typename(co, lua_type(co, -1)));
    printf("\n");
}

static const char *setup_common =
    "local function mkclose(name, err, id, yld)\n"
    "  local t = {id=id}\n"
    "  return setmetatable(t, {__close = function(o, e)\n"
    "    logc(name..':'..tostring(type(e)=='table' and e.id or e))\n"
    "    if yld then local y = coroutine.yield('inclose'); logc(name..'_after:'..tostring(y)) end\n"
    "    if err then error(err, 0) end\n"
    "  end})\n"
    "end\n"
    "MKCLOSE = mkclose\n"
    "local function f_ret() return 'r1' end\n"
    "F_RET = f_ret\n"
    "local function f_boomv(...) local a = ... error('boom', 0) end\n"
    "F_BOOMV = f_boomv\n"
    "local function f_errv(...) local v = ... error(v) end\n"
    "F_ERRV = f_errv\n"
    "local function f_yield() local y = coroutine.yield('y1'); return 'fret', y end\n"
    "F_YIELD = f_yield\n"
    "RES2 = 'res2'\n";

static lua_State *case_setup(const char *name) {
    lua_State *L = luaL_newstate();
    printf("=== %s ===\n", name);
    if (!L) { printf("FAIL: newstate\n"); return NULL; }
    luaL_openlibs(L);
    lua_register(L, "logc", logc);
    if (luaL_dostring(L, setup_common) != 0) {
        printf("FAIL: setup: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return NULL;
    }
    return L;
}

/* Create a fresh coroutine whose body is the C closure `body` pushed
** DIRECTLY onto the coroutine's stack (no Lua wrapper), followed by
** `nargs` values pulled from named globals. The coroutine is rooted in
** the registry for the whole case (a full GC between resumes would
** otherwise free it and dangle the C-local pointer); luaL_ref consumes
** the thread value from L's stack. */
static lua_State *case_coro(lua_State *L, lua_CFunction body,
                            const char **argnames, int nargs, int *ref) {
    lua_State *co = lua_newthread(L);
    int i;
    if (!co) { printf("FAIL: newthread\n"); return NULL; }
    lua_pushcfunction(co, body);
    for (i = 0; i < nargs; i++) lua_getglobal(co, argnames[i]);
    *ref = luaL_ref(L, LUA_REGISTRYINDEX);
    return co;
}

static int run_direct(const char *name, lua_CFunction body,
                      const char **argnames, int nargs,
                      const char *setup_extra,
                      int gc_between, const char *resume2_arg,
                      int uncaught_style) {
    lua_State *L = case_setup(name);
    lua_State *co;
    int co_ref, nres = 0, st;
    if (!L) return 1;
    if (setup_extra && luaL_dostring(L, setup_extra) != 0) {
        printf("FAIL: setup_extra: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return 1;
    }
    co = case_coro(L, body, argnames, nargs, &co_ref);
    if (!co) { lua_close(L); return 1; }
    st = lua_resume(co, L, nargs, &nres);
    if (uncaught_style)
        report_uncaught("resume1", st, co);
    else {
        report("resume1", st, nres, co);
        if (nres > 0) lua_xmove(co, L, nres);
    }
    if (gc_between) {
        lua_gc(L, LUA_GCCOLLECT);
        printf("gc_done\n");
    }
    if (resume2_arg != NULL && st == LUA_YIELD) {
        lua_getglobal(co, resume2_arg);
        st = lua_resume(co, L, 1, &nres);
        report("resume2", st, nres, co);
        if (nres > 0) lua_xmove(co, L, nres);
    }
    printf("co_status=%d\n", lua_status(co));
    luaL_unref(L, LUA_REGISTRYINDEX, co_ref);
    lua_close(L);
    return 0;
}

/* GR: recovery + full GC + VM reuse — same state, second direct-body
** coroutine created and driven after the GC, then a plain chunk. */
static int run_gr(void) {
    static const char *be_args[] = {"F_BOOMV", "GRV"};
    static const char *nr_args[] = {"F_RET"};
    lua_State *L = case_setup("GR_recover_gc_reuse");
    lua_State *co1, *co2;
    int co1_ref, co2_ref, nres = 0, st;
    if (!L) return 1;
    luaL_dostring(L, "GRV = MKCLOSE('gv', nil, 63, false)");
    co1 = case_coro(L, berr, be_args, 2, &co1_ref);
    if (!co1) { lua_close(L); return 1; }
    st = lua_resume(co1, L, 2, &nres);
    report("gr_resume1", st, nres, co1);
    if (nres > 0) lua_xmove(co1, L, nres);
    lua_gc(L, LUA_GCCOLLECT);
    printf("gr_gc_done\n");
    co2 = case_coro(L, bret, nr_args, 1, &co2_ref);
    if (!co2) { lua_close(L); return 1; }
    st = lua_resume(co2, L, 1, &nres);
    report("gr2_resume1", st, nres, co2);
    if (nres > 0) lua_xmove(co2, L, nres);
    luaL_unref(L, LUA_REGISTRYINDEX, co1_ref);
    luaL_unref(L, LUA_REGISTRYINDEX, co2_ref);
    {
        int rc = luaL_dostring(L, "print('VM-alive:', 1 + 1)");
        printf("chunk rc=%d\n", rc);
    }
    lua_close(L);
    return 0;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);

    {   /* NR: normal result */
        static const char *a[] = {"F_RET"};
        if (run_direct("NR_bret", bret, a, 1, NULL, 0, NULL, 0)) return 1;
    }
    {   /* BY: baseline yield across the body's pcallk */
        static const char *a[] = {"F_YIELD"};
        if (run_direct("BY_byld", byld, a, 1, NULL, 0, "RES2", 0)) return 1;
    }
    {   /* BE: direct error recovery (the P-1 shape) */
        static const char *a[] = {"F_BOOMV", "BEV"};
        if (run_direct("BE_berr", berr, a, 2,
                       "BEV = MKCLOSE('bev', nil, 61, false)", 0, NULL, 0))
            return 1;
    }
    {   /* YC: yielding closer + full GC + identity across resumes */
        static const char *a[] = {"F_ERRV", "YCV"};
        if (run_direct("YC_berr", berr, a, 2,
                       "YCV = MKCLOSE('yv', nil, 62, true)", 1, "RES2", 0))
            return 1;
    }
    {   /* CE: closer error inside the recovery close */
        static const char *a[] = {"F_BOOMV", "CEV"};
        if (run_direct("CE_berr", berr, a, 2,
                       "CEV = MKCLOSE('cv', 'cerr', 64, false)", 0, NULL, 0))
            return 1;
    }
    {   /* KE: continuation error — uncaught at the resume boundary */
        static const char *a[] = {"F_BOOMV"};
        if (run_direct("KE_bkerr", bkerr, a, 1, NULL, 0, NULL, 1)) return 1;
    }
    {   /* OM: ERRMEM recovery through the pcallk defer */
        static const char *a[] = {NULL};
        if (run_direct("OM_bom", bom, a, 0, NULL, 0, NULL, 0)) return 1;
    }
    {   /* NESTK: nested pcallk — inner recovery, outer continuation */
        static const char *a[] = {NULL};
        if (run_direct("NESTK_bnest", bnest, a, 0, NULL, 0, NULL, 0)) return 1;
    }
    if (run_gr()) return 1;
    printf("=== 38_pcallk_cbody_recovery DONE ===\n");
    return 0;
}
