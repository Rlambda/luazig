/*
** 37_pcallk_recovery — permanent differential suite for the C/YPCALL
** recovery owner on the EXPORTED lua_pcallk + continuation, driven from
** C through lua_resume (one fresh lua_State + coroutine per case).
**
** PUC model under test (lapi.c lua_pcallk yieldable path, ldo.c recover /
** finishCcall / finishpcallk, lfunc.c luaF_close):
**
**   N     the pcallk'd CALLEE (a C function) marks its own value with
**         lua_toclose and errors: the mark sits INSIDE the recovery
**         chain region; a YIELDING closer suspends the recovery close at
**         resume#1 (thread suspended, not dead), resume#2 finishes the
**         close and k runs with status=2 and the ORIGINAL error object.
**   GY    an ARG-mark (lua_toclose on the callee's argument, ABOVE the
**         func index) whose closer YIELDS: same suspension/re-drive
**         shape; k sees the original error object (the marked table is
**         the error object itself, identity via registry ref).
**   H     control for GY: a mark BELOW the callee func index is NOT
**         closed by the recovery (closes after k, at the client frame's
**         return close).
**   HX    an errfunc (client handler slot BELOW the callee) + an arg-mark
**         whose closer yields and then ERRORS on the resumed drive: the
**         armed handler runs at BOTH throw sites (PUC finishpcallk runs
**         luaF_close BEFORE restoring L->errfunc), so k receives the
**         HANDLER-TRANSFORMED closer error.
**   P     ERRMEM inside the callee (1 TiB userdata): the yieldable branch
**         has no local catch — k runs with status=4 and the FIXED
**         "not enough memory" object.
**   W     prefix + results identity: a C-window prefix slot below the
**         pcallk'd callee, a yielding callee, and a REAL full GC between
**         resume#1 (yield) and resume#2 (completion): k's window keeps
**         [prefix, results...] with the original objects (rawequal).
**   NEST  nested pcallk: the outer pcallk callee itself pcallk's an
**         erroring inner callee; each k sees its own error window.
**   XL    k itself yields (lua_yieldk inside k) and the coroutine is then
**         force-closed (lua_closethread): the pcallk frame is discarded
**         (PUC resetCI) — no continuation runs after the close, the
**         client's own below-func mark closes exactly once.
**
** Baseline controls: A (plain error window + identity), D (yield +
** results), E (errfunc transform), M (handler errors -> errerr), K
** (nresults nil-fill), J (full GC after a completed recovery + VM reuse
** in the same state).
**
** Chronological event stream: EVERY observable event is printed at the
** moment it happens, into one stream — the k continuations and the C
** bodies' post-pcallk code (they run inside the lua_resume window that
** finishes the protected call), the __close bodies (they call the
** registered logc(), which prints immediately from inside the drive),
** and the driver's own resume/gc/closethread reports (printed after the
** corresponding call returns). Stdout is unbuffered; nothing is grouped
** by source or reordered: the interleaving of k and closer activity
** relative to the lua_resume / lua_closethread calls is part of the
** compared contract, because that interleaving is exactly what the C
** client observes.
*/
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* ------------------------------------------------------------------ */
/* immediate chronological event output                                  */
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
** closer runs (inside a resume/recovery/closethread window). */
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
        if (top >= 2) {
            snprintf(piece, sizeof piece, " rawequal_a2_orig=%d",
                     lua_rawequal(L, 2, -1));
            snprintf(line + n, sizeof line - (size_t)n, "%s", piece);
        }
        lua_pop(L, 1);
    }
    ev("%s", line);
}

static int k_fin(lua_State *L, int status, lua_KContext ctx) {
    dump_window(L, status, ctx, "CONT");
    return 0;
}

static int k_fin_in(lua_State *L, int status, lua_KContext ctx) {
    dump_window(L, status, ctx, "CONT_IN");
    return 0;
}

static int k_fin_out(lua_State *L, int status, lua_KContext ctx) {
    dump_window(L, status, ctx, "CONT_OUT");
    return 0;
}

/* push a fresh error table with the given id */
static void push_errtable(lua_State *L, long long id) {
    lua_newtable(L);
    lua_pushinteger(L, id);
    lua_setfield(L, -2, "id");
}

/* ------------------------------------------------------------------ */
/* case bodies (window layouts in 0-based slots relative to the frame)  */
/* ------------------------------------------------------------------ */

/* A: cbox(f) — window [cbox, f]; push e: [cbox, f, e]; pcallk(nargs=1):
** callee f at 0-based 1, arg e. Plain error: k window = [original err]. */
static int cbox(lua_State *L) {
    int ref;
    push_errtable(L, 42);
    lua_pushvalue(L, -1);
    ref = luaL_ref(L, LUA_REGISTRYINDEX);
    {
        int st = lua_pcallk(L, 1, LUA_MULTRET, 0, (lua_KContext)ref, k_fin);
        ev("cbox: pcallk returned %d top=%d", st, lua_gettop(L));
        luaL_unref(L, LUA_REGISTRYINDEX, ref);
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L);
    }
}

/* D: cyield(f) — plain yield then return: k(status=1) with results. */
static int cyield(lua_State *L) {
    int st = lua_pcallk(L, 0, LUA_MULTRET, 0, 0, k_fin);
    ev("cyield: pcallk returned %d top=%d", st, lua_gettop(L));
    if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
    return lua_gettop(L);
}

/* E: cerrf(eh, f) — window [cerrf, eh, f]; push e; pcallk(nargs=1,
** errfunc=1): handler at client idx 1 (BELOW the callee at idx 2)
** transforms the error object; k sees the transformed object. */
static int cerrf(lua_State *L) {
    push_errtable(L, 44);
    {
        int st = lua_pcallk(L, 1, LUA_MULTRET, 1, 0, k_fin);
        ev("cerrf: pcallk returned %d top=%d", st, lua_gettop(L));
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L) - 1;
    }
}

/* M: cerrerr(eh_bad, f) — the handler itself errors: errerr status. */
static int cerrerr(lua_State *L) {
    push_errtable(L, 49);
    {
        int st = lua_pcallk(L, 1, LUA_MULTRET, 1, 0, k_fin);
        ev("cerrerr: pcallk returned %d top=%d", st, lua_gettop(L));
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L) - 1;
    }
}

/* K: cnres(f) — pcallk(nresults=2), callee returns 1 value: nil-fill. */
static int cnres(lua_State *L) {
    int st = lua_pcallk(L, 0, 2, 0, 0, k_fin);
    ev("cnres: pcallk returned %d top=%d", st, lua_gettop(L));
    if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
    return 2;
}

/* N: cmark(v) — push ci (closure over v): [cmark, v, ci]; pcallk(0) on
** ci. ci marks v (inside the recovery region) then errors "boom2".
** v's __close YIELDS: recovery suspends at resume#1; resume#2 finishes;
** k(status=2, "boom2"). */
static int cmark_inner(lua_State *L) {
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_toclose(L, 1);
    lua_pushstring(L, "boom2");
    lua_error(L);
    return 0;
}

static int cmark(lua_State *L) {
    lua_pushvalue(L, 1);
    lua_pushcclosure(L, cmark_inner, 1);
    {
        int st = lua_pcallk(L, 0, LUA_MULTRET, 0, 0, k_fin);
        ev("cmark: pcallk returned %d top=%d", st, lua_gettop(L));
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L) - 1;
    }
}

/* GY: cgy(f, v) — window [cgy, f, v]; toclose(v) (ABOVE the callee);
** ref v; pcallk(nargs=1): callee f at idx 1, arg v. f errors with v
** itself; v's __close YIELDS during the recovery close. k sees the
** ORIGINAL error object (== v, rawequal via ref). */
static int cgy(lua_State *L) {
    int ref;
    lua_toclose(L, 2);
    lua_pushvalue(L, 2);
    ref = luaL_ref(L, LUA_REGISTRYINDEX);
    {
        int st = lua_pcallk(L, 1, LUA_MULTRET, 0, (lua_KContext)ref, k_fin);
        ev("cgy: pcallk returned %d top=%d", st, lua_gettop(L));
        luaL_unref(L, LUA_REGISTRYINDEX, ref);
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L) - 1;
    }
}

/* H: cbelow(v, f) — window [cbelow, v, f]; toclose(v) (BELOW the callee
** at idx 2); push e; pcallk(nargs=1). The mark is NOT in the recovery
** region: it closes after k, at cbelow's own return close. */
static int cbelow(lua_State *L) {
    int ref;
    lua_toclose(L, 1);
    push_errtable(L, 47);
    lua_pushvalue(L, -1);
    ref = luaL_ref(L, LUA_REGISTRYINDEX);
    {
        int st = lua_pcallk(L, 1, LUA_MULTRET, 0, (lua_KContext)ref, k_fin);
        ev("cbelow: pcallk returned %d top=%d", st, lua_gettop(L));
        luaL_unref(L, LUA_REGISTRYINDEX, ref);
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L) - 1;
    }
}

/* HX: chx(eh, f, v) — window [chx, eh, f, v]; toclose(v) (the callee's
** arg, ABOVE func idx 2); pcallk(nargs=1, errfunc=1): handler BELOW the
** callee. f errors with v; the handler transforms it; v's __close yields
** then errors "CERR" on the resumed drive — the handler is STILL armed
** (PUC finishpcallk closes before restoring errfunc) and transforms the
** closer error too; k gets handler(CERR). */
static int chx(lua_State *L) {
    lua_toclose(L, 3);
    {
        int st = lua_pcallk(L, 1, LUA_MULTRET, 1, 0, k_fin);
        ev("chx: pcallk returned %d top=%d", st, lua_gettop(L));
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L) - 1;
    }
}

/* P: coom() — the pcallk'd callee allocates 1 TiB: ERRMEM; k(status=4)
** with the FIXED "not enough memory" object. */
static int coom_inner(lua_State *L) {
    (void)lua_newuserdatauv(L, (size_t)1 << 40, 0);
    return 0;
}

static int coom(lua_State *L) {
    lua_pushcfunction(L, coom_inner);
    {
        int st = lua_pcallk(L, 0, LUA_MULTRET, 0, 0, k_fin);
        ev("coom: pcallk returned %d top=%d", st, lua_gettop(L));
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L);
    }
}

/* W: cdgc(p, f) — window [cdgc, p, f]; pcallk(nargs=0) on f (idx 2),
** prefix p BELOW. f yields, driver GCs, resume#2 completes: k window =
** [prefix..., 'fret', 'r2'] with original identity (rawequal vs the
** registry ref of p). */
static int cdgc(lua_State *L) {
    int ref;
    lua_pushvalue(L, 1);
    ref = luaL_ref(L, LUA_REGISTRYINDEX);
    {
        int st = lua_pcallk(L, 0, LUA_MULTRET, 0, (lua_KContext)ref, k_fin);
        ev("cdgc: pcallk returned %d top=%d", st, lua_gettop(L));
        luaL_unref(L, LUA_REGISTRYINDEX, ref);
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L) - 1;
    }
}

/* NEST: cnest_outer() — pcallk(0) on the C function cnest; cnest pushes
** an errtable + a closure that errors with it, pcallk(0) on that. Both
** k's see their own error windows (distinct tags). */
static int cnest_inner(lua_State *L) {
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_error(L);
    return 0;
}

static int cnest(lua_State *L) {
    push_errtable(L, 45);
    lua_pushcclosure(L, cnest_inner, 1);
    {
        int st = lua_pcallk(L, 0, LUA_MULTRET, 0, 0, k_fin_in);
        ev("cnest_inner: pcallk returned %d top=%d", st, lua_gettop(L));
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L);
    }
}

static int cnest_outer(lua_State *L) {
    lua_pushcfunction(L, cnest);
    {
        int st = lua_pcallk(L, 0, LUA_MULTRET, 0, 0, k_fin_out);
        ev("cnest_outer: pcallk returned %d top=%d", st, lua_gettop(L));
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L);
    }
}

/* XL: ckyield(v, f) — window [ckyield, v, f]; toclose(v) (BELOW the
** callee); pcallk(0) on f with k_yielder as k. f errors; k dumps and
** YIELDS (lua_yieldk inside k); the driver force-closes the coroutine:
** the pcallk frame is discarded (resetCI), no k runs again, v closes at
** the forced close exactly once. */
static int k_yielder(lua_State *L, int status, lua_KContext ctx) {
    dump_window(L, status, ctx, "CONT_KY");
    return lua_yieldk(L, 0, ctx, k_yielder);
}

static int ckyield(lua_State *L) {
    lua_toclose(L, 1);
    {
        int st = lua_pcallk(L, 0, LUA_MULTRET, 0, 0, k_yielder);
        ev("ckyield: pcallk returned %d top=%d", st, lua_gettop(L));
        if (st != LUA_OK) { lua_pushboolean(L, 0); return 1; }
        return lua_gettop(L) - 1;
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

typedef struct {
    const char *name;   /* case tag */
    const char *setup;  /* per-case Lua setup (ARGS table) */
    const char *cfn;    /* registered C body name */
    int resumes;        /* max resumes to attempt */
    int gc_between;     /* full GC between resume1 and resume2 */
    int close_after;    /* lua_closethread after the last resume */
} Case;

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
    "local function f_err(x) error(x) end\n"
    "F_ERR = f_err\n"
    "local function f_ret() return 'r1' end\n"
    "F_RET = f_ret\n"
    "local function f_boom() error('boom', 0) end\n"
    "F_BOOM = f_boom\n"
    "local function f_yield() local y = coroutine.yield('y1'); return 'fret', y end\n"
    "F_YIELD = f_yield\n";

static void register_cfuncs(lua_State *L) {
    lua_register(L, "logc", logc);
    lua_register(L, "cbox", cbox);
    lua_register(L, "cyield", cyield);
    lua_register(L, "cerrf", cerrf);
    lua_register(L, "cerrerr", cerrerr);
    lua_register(L, "cnres", cnres);
    lua_register(L, "cmark", cmark);
    lua_register(L, "cgy", cgy);
    lua_register(L, "cbelow", cbelow);
    lua_register(L, "chx", chx);
    lua_register(L, "coom", coom);
    lua_register(L, "cdgc", cdgc);
    lua_register(L, "cnest_outer", cnest_outer);
    lua_register(L, "ckyield", ckyield);
}

static lua_State *case_setup(const char *name, const char *setup) {
    lua_State *L = luaL_newstate();
    printf("=== %s ===\n", name);
    if (!L) { printf("FAIL: newstate\n"); return NULL; }
    luaL_openlibs(L);
    register_cfuncs(L);
    if (luaL_dostring(L, setup_common) != 0 ||
        (setup && luaL_dostring(L, setup) != 0)) {
        printf("FAIL: setup: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_close(L);
        return NULL;
    }
    return L;
}

/* create co = coroutine.create(function() return CFN(table.unpack(ARGS))
** end) rooted in the registry; the body reads its call args itself
** (pushing them onto the fresh coroutine via lua_xmove is unchecked in
** release PUC: lua_xmove does not grow the destination stack,
** api_check only). */
static lua_State *case_coro(lua_State *L, const char *cfn, int *ref) {
    lua_State *co;
    char buf[512];
    snprintf(buf, sizeof buf,
             "return function() return %s(table.unpack(ARGS)) end", cfn);
    if (luaL_loadstring(L, buf) != 0 || lua_pcall(L, 0, 1, 0) != 0) {
        printf("FAIL: body factory\n");
        return NULL;
    }
    lua_getglobal(L, "coroutine");
    lua_getfield(L, -1, "create");
    lua_remove(L, -2);
    lua_pushvalue(L, -2);
    if (lua_pcall(L, 1, 1, 0) != 0) {
        printf("FAIL: create: %s\n",
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        return NULL;
    }
    co = lua_tothread(L, -1);
    if (!co) { printf("FAIL: not a thread\n"); return NULL; }
    /* root the coroutine for the whole case: a thread is a collectable
    ** value, and a full GC between resumes would free an unrooted one
    ** (the C-local pointer would dangle). */
    *ref = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_pop(L, 1);   /* factory closure */
    return co;
}

static int run_case(const Case *c) {
    lua_State *L = case_setup(c->name, c->setup);
    lua_State *co;
    int co_ref;
    int nres = 0, st;
    if (!L) return 1;
    co = case_coro(L, c->cfn, &co_ref);
    if (!co) { lua_close(L); return 1; }

    st = lua_resume(co, L, 0, &nres);
    report("resume1", st, nres, co);
    if (nres > 0) lua_xmove(co, L, nres);
    if (c->gc_between) {
        lua_gc(L, LUA_GCCOLLECT);
        printf("gc_done\n");
    }
    if (c->resumes >= 2 && st == LUA_YIELD) {
        st = lua_resume(co, L, 0, &nres);
        report("resume2", st, nres, co);
        if (nres > 0) lua_xmove(co, L, nres);
    }
    if (c->close_after) {
        st = lua_closethread(co, L);
        printf("closethread: st=%d\n", st);
    }
    luaL_unref(L, LUA_REGISTRYINDEX, co_ref);
    lua_close(L);
    return 0;
}

/* J: error recovery + full GC + VM reuse — same state, second coroutine
** created and driven after the GC. */
static int run_j(void) {
    lua_State *L = case_setup("J_recover_gc_reuse", "ARGS = {F_ERR}");
    lua_State *co1, *co2;
    int co1_ref, co2_ref;
    int nres = 0, st;
    if (!L) return 1;
    co1 = case_coro(L, "cbox", &co1_ref);
    if (!co1) { lua_close(L); return 1; }
    st = lua_resume(co1, L, 0, &nres);
    report("j_resume1", st, nres, co1);
    if (nres > 0) lua_xmove(co1, L, nres);
    lua_gc(L, LUA_GCCOLLECT);
    printf("j_gc_done\n");
    /* second coroutine in the same state */
    co2 = case_coro(L, "cyield", &co2_ref);
    if (!co2) { lua_close(L); return 1; }
    st = lua_resume(co2, L, 0, &nres);
    report("j2_resume1", st, nres, co2);
    if (nres > 0) lua_xmove(co2, L, nres);
    st = lua_resume(co2, L, 0, &nres);
    report("j2_resume2", st, nres, co2);
    if (nres > 0) lua_xmove(co2, L, nres);
    luaL_unref(L, LUA_REGISTRYINDEX, co1_ref);
    luaL_unref(L, LUA_REGISTRYINDEX, co2_ref);
    lua_close(L);
    return 0;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);

    {
        static const char s[] = "ARGS = {F_ERR}\n";
        Case c = {"A_cbox", s, "cbox", 1, 0, 0};
        if (run_case(&c)) return 1;
    }
    {
        static const char s[] = "ARGS = {F_YIELD}\n";
        Case c = {"D_cyield", s, "cyield", 2, 0, 0};
        if (run_case(&c)) return 1;
    }
    {
        static const char s[] =
            "ARGS = {function(m) return 'HANDLED:'..tostring(type(m)=='table'"
            " and m.id or m) end, F_ERR}\n";
        Case c = {"E_cerrf", s, "cerrf", 1, 0, 0};
        if (run_case(&c)) return 1;
    }
    {
        static const char s[] =
            "ARGS = {function() error('EH', 0) end, F_ERR}\n";
        Case c = {"M_cerrerr", s, "cerrerr", 1, 0, 0};
        if (run_case(&c)) return 1;
    }
    {
        static const char s[] = "ARGS = {F_RET}\n";
        Case c = {"K_cnres", s, "cnres", 1, 0, 0};
        if (run_case(&c)) return 1;
    }
    {
        static const char s[] = "ARGS = {MKCLOSE('nv', nil, 53, true)}\n";
        Case c = {"N_cmark", s, "cmark", 2, 0, 0};
        if (run_case(&c)) return 1;
    }
    {
        static const char s[] = "ARGS = {F_ERR, MKCLOSE('gyv', nil, 52, true)}\n";
        Case c = {"GY_cgy", s, "cgy", 2, 0, 0};
        if (run_case(&c)) return 1;
    }
    {
        static const char s[] = "ARGS = {MKCLOSE('hv'), F_ERR}\n";
        Case c = {"H_cbelow", s, "cbelow", 1, 0, 0};
        if (run_case(&c)) return 1;
    }
    {
        static const char s[] =
            "ARGS = {function(m) return 'HX:'..tostring(type(m)=='table'"
            " and m.id or m) end, F_ERR, MKCLOSE('hxv', 'CERR', 55, true)}\n";
        Case c = {"HX_chx", s, "chx", 2, 0, 0};
        if (run_case(&c)) return 1;
    }
    {
        static const char s[] = "ARGS = {}\n";
        Case c = {"P_coom", s, "coom", 1, 0, 0};
        if (run_case(&c)) return 1;
    }
    {
        static const char s[] =
            "local p = {id=60}\nARGS = {p, F_YIELD}\n";
        Case c = {"W_cdgc", s, "cdgc", 2, 1, 0};
        if (run_case(&c)) return 1;
    }
    {
        static const char s[] = "ARGS = {}\n";
        Case c = {"NEST_cnest", s, "cnest_outer", 1, 0, 0};
        if (run_case(&c)) return 1;
    }
    {
        static const char s[] = "ARGS = {MKCLOSE('lv'), F_BOOM}\n";
        Case c = {"XL_ckyield", s, "ckyield", 1, 0, 1};
        if (run_case(&c)) return 1;
    }
    if (run_j()) return 1;
    printf("=== 37_pcallk_recovery DONE ===\n");
    return 0;
}
