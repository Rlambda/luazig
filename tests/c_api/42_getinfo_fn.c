/*
 * 42_getinfo_fn.c — permanent differential suite: lua_getinfo('>') as a
 * C API observation function (PUC ldebug.c lua_getinfo '>' prefix form).
 *
 * Covers:
 *   - direct function arguments of all three classes: light C function,
 *     C closure (nup>0), Lua closure (main chunk + nested function);
 *     builtin globals as observed through the C API (print = VLCF shape,
 *     require = CClosure(n=1) shape in both engines);
 *   - every what-flag's field semantics for the function form: 'S' (what/
 *     source/srclen/short_src/linedefined/lastlinedefined), 'l' (-1),
 *     'u' (nups/nparams/isvararg), 't' (0/0), 'n' (""/NULL), 'r' (0/0),
 *     'f' (function pushed back), 'L' (activelines table or nil);
 *   - the exact stack effect of the '>' form: the function is popped
 *     first; 'f' pushes it back (net 0); 'L' pushes one more value;
 *   - invalid options return 0 (options before the invalid one still
 *     filled); the bare ">" pops and returns 1;
 *   - erroneous inputs: non-function, non-closure values on top are
 *     reported through the C shape (release PUC semantics: the closure
 *     unwrap yields NULL), the value is popped/pushed back exactly;
 *   - the same queries inside a C function running on a resumed
 *     coroutine (the window lives on the coroutine's state);
 *   - the frame form still works after '>' calls, and ar->i_ci is left
 *     untouched by the '>' form;
 *   - GC pressure: sole-reference functions queried with the collector
 *     due at the next allocation (generational mode + LUA_GCRESTART,
 *     which sets the GC debt to zero — PUC lapi.c:1184). PUC never runs
 *     a collector step inside lua_getinfo (no luaC_checkGC point between
 *     the pop and the 'f'/'L' pushes), so a due collector is invisible
 *     to its output; luazig steps its collector at allocation time, so
 *     the same sequence exercises the popped function's lifetime across
 *     the 'L' table construction and the 'f' push.
 *
 * Every printed line must be byte-identical between PUC Lua 5.5 and
 * luazig: no addresses. Exit code is non-zero on any failed check.
 */

#include <stdio.h>
#include <stdlib.h>
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

/* ---------------- helper: run one '>' query on a pushed value ---------- */

/* The value to inspect MUST be freshly pushed on top of L's stack: the
 * '>' form consumes it (and re-pushes it only for 'f'). Prints the filled
 * fields per `what` plus the top delta — exactly what PUC's function
 * form does. */
static void qi(lua_State *L, const char *what) {
    lua_Debug ar;
    memset(&ar, 0, sizeof ar);
    int before = lua_gettop(L);
    int rc = lua_getinfo(L, what, &ar);
    int after = lua_gettop(L);
    printf("qi[%s] rc=%d dtop=%d", what, rc, after - before);
    const char *p;
    for (p = what; *p; p++) {
        switch (*p) {
            case 'S':
                printf(" what=%s src=%s srclen=%zu ss=%s ld=%ld lld=%ld",
                       ar.what ? ar.what : "(null)",
                       ar.source ? ar.source : "(null)",
                       (size_t)ar.srclen,
                       ar.short_src,
                       (long)ar.linedefined, (long)ar.lastlinedefined);
                break;
            case 'l': printf(" line=%ld", (long)ar.currentline); break;
            case 'u':
                printf(" nups=%d nparams=%d isva=%d",
                       (int)ar.nups, (int)ar.nparams, (int)ar.isvararg);
                break;
            case 't':
                printf(" tail=%d xa=%d", (int)ar.istailcall, (int)ar.extraargs);
                break;
            case 'n':
                printf(" nw=%s name=%s",
                       ar.namewhat ? ar.namewhat : "(null)",
                       ar.name ? ar.name : "(null)");
                break;
            case 'r':
                printf(" ft=%d nt=%d", (int)ar.ftransfer, (int)ar.ntransfer);
                break;
            default: break;
        }
    }
    printf("\n");
}

/* pusher: re-push the probe value stored at window index `keep` */
static void qk(lua_State *L, int keep, const char *what) {
    lua_pushvalue(L, keep);
    qi(L, what);
}

/* ---------------- test C functions ---------------- */

static int cf_two(lua_State *L) {
    (void)L;
    return 0;
}

static int cf_upv(lua_State *L) {
    lua_pushinteger(L, lua_tointeger(L, lua_upvalueindex(1)));
    return 1;
}

/* runs the class queries on a coroutine's own window */
static int co_query(lua_State *L) {
    lua_pushcfunction(L, cf_two);
    qk(L, -1, ">S");
    qk(L, -1, ">u");
    lua_pop(L, 1);
    lua_pushinteger(L, 7);
    lua_pushcclosure(L, cf_upv, 1);
    qk(L, -1, ">u");
    qk(L, -1, ">f");
    checkeq(lua_gettop(L), 2, "CO.ccl-top"); /* kept probe + 'f' push-back */
    lua_pop(L, 2);
    if (luaL_loadstring(L, "local q = 3\nreturn q") != 0) {
        printf("CO.LOADERR %s\n", lua_tostring(L, -1));
        return 0;
    }
    qk(L, -1, ">Slu");
    qk(L, -1, ">n");
    qk(L, -1, ">fL");
    /* func pushed back, then the activelines table */
    check(lua_isfunction(L, -2), "CO.main-fL-f");
    check(lua_istable(L, -1), "CO.main-L-table");
    lua_pop(L, 3); /* table, func, kept probe */
    printf("CO.DONE top=%d\n", lua_gettop(L));
    return 0;
}

/* frame-form interplay check inside a C function */
static int frame_probe(lua_State *L) {
    lua_Debug ar;
    memset(&ar, 0, sizeof ar);
    /* poison i_ci, then verify the '>' form leaves it untouched */
    ar.i_ci = (void *)0x1234;
    lua_pushcfunction(L, cf_two);
    int rc = lua_getinfo(L, ">S", &ar);
    checkeq(rc, 1, "FP.gt-rc");
    check(ar.i_ci == (void *)0x1234, "FP.icci-untouched");
    checkstr(ar.what, "C", "FP.gt-what");
    checkeq(lua_gettop(L), 0, "FP.gt-top");
    /* the frame form still resolves level 0 = this C function */
    memset(&ar, 0, sizeof ar);
    rc = lua_getstack(L, 0, &ar);
    checkeq(rc, 1, "FP.stack-rc");
    int b = lua_gettop(L);
    rc = lua_getinfo(L, "f", &ar);
    checkeq(rc, 1, "FP.frame-f-rc");
    checkeq(lua_gettop(L) - b, 1, "FP.frame-f-push");
    check(lua_iscfunction(L, -1), "FP.frame-f-isc");
    lua_pop(L, 1);
    rc = lua_getstack(L, 0, &ar);
    checkeq(rc, 1, "FP.stack2-rc");
    b = lua_gettop(L);
    rc = lua_getinfo(L, "L", &ar);
    checkeq(rc, 1, "FP.frame-L-rc");
    checkeq(lua_gettop(L) - b, 1, "FP.frame-L-push");
    check(lua_isnil(L, -1), "FP.frame-L-nil"); /* C frame -> nil */
    lua_pop(L, 1);
    return 0;
}

/* sorted activelines key dump via Lua (deterministic, no addresses) */
static void dump_lines(lua_State *L, int idx) {
    int base = lua_gettop(L);
    lua_getglobal(L, "load");
    lua_pushliteral(L,
        "local t, u = ..., {}\n"
        "for k in pairs(t) do u[#u + 1] = k end\n"
        "table.sort(u)\n"
        "return table.concat(u, ',')");
    if (lua_pcall(L, 1, 1, 0) != 0) {
        printf("DUMP_LINES_ERR %s\n", lua_tostring(L, -1));
        lua_settop(L, base);
        return;
    }
    lua_pushvalue(L, idx < 0 ? idx - 1 : idx); /* the lines table (below load) */
    if (lua_pcall(L, 1, 1, 0) != 0) {
        printf("DUMP_LINES_ERR %s\n", lua_tostring(L, -1));
        lua_settop(L, base);
        return;
    }
    printf("lines=%s\n", lua_tostring(L, -1));
    lua_settop(L, base);
}

/* ---------------- parts ---------------- */

static void part_classes(lua_State *L) {
    /* light C function */
    lua_pushcfunction(L, cf_two);
    qk(L, -1, ">S");
    qk(L, -1, ">u");
    qk(L, -1, ">l");
    qk(L, -1, ">t");
    qk(L, -1, ">n");
    qk(L, -1, ">r");
    qk(L, -1, ">Sluntr");
    qk(L, -1, ">");
    qk(L, -1, ">f");
    check(lua_iscfunction(L, -1), "P1.light-f-isc");
    check(lua_tocfunction(L, -1) == &cf_two, "P1.light-f-identity");
    lua_pop(L, 1);
    qk(L, -1, ">L");
    check(lua_isnil(L, -1), "P1.light-L-nil");
    lua_pop(L, 1);
    qk(L, -1, ">fL");
    check(lua_iscfunction(L, -2), "P1.light-fL-f");
    check(lua_isnil(L, -1), "P1.light-fL-L");
    lua_pop(L, 2);
    lua_pop(L, 1); /* the kept probe */
    checkeq(lua_gettop(L), 0, "P1.top-balanced");

    /* C closure with 2 upvalues */
    lua_pushinteger(L, 1);
    lua_pushinteger(L, 2);
    lua_pushcclosure(L, cf_upv, 2);
    qk(L, -1, ">S");
    qk(L, -1, ">u");
    qk(L, -1, ">fL");
    check(lua_iscfunction(L, -2), "P2.ccl-f");
    check(lua_isnil(L, -1), "P2.ccl-L-nil");
    lua_pop(L, 2);
    lua_pop(L, 1);
    checkeq(lua_gettop(L), 0, "P2.top-balanced");

    /* Lua closure: a loaded main chunk */
    check(luaL_loadstring(L, "local x = 1\nreturn x") == 0, "P3.load");
    qk(L, -1, ">S");
    qk(L, -1, ">u");
    qk(L, -1, ">l");
    qk(L, -1, ">n");
    qk(L, -1, ">fL");
    check(lua_isfunction(L, -2), "P3.main-fL-f");
    check(lua_istable(L, -1), "P3.main-L-table");
    dump_lines(L, -1);
    lua_pop(L, 2);
    lua_pop(L, 1);
    checkeq(lua_gettop(L), 0, "P3.top-balanced");

    /* Lua closure: a nested function with parameters and an upvalue */
    check(luaL_loadstring(
              L,
              "local up = 5\n"
              "local function inner(a, b)\n"
              "  local s = a + b\n"
              "  return s + up\n"
              "end\n"
              "return inner") == 0,
          "P4.load");
    check(lua_pcall(L, 0, 1, 0) == 0, "P4.run");
    check(lua_isfunction(L, -1), "P4.isfunc");
    qk(L, -1, ">S");
    qk(L, -1, ">u");
    qk(L, -1, ">L");
    check(lua_istable(L, -1), "P4.L-table");
    dump_lines(L, -1);
    lua_pop(L, 1);
    lua_pop(L, 1);
    checkeq(lua_gettop(L), 0, "P4.top-balanced");

    /* source forms: '=' chunkname */
    check(luaL_loadbufferx(L, "return 2", 8, "=mysrc", NULL) == 0, "P5.loadsrc");
    qk(L, -1, ">S");
    lua_pop(L, 1);
    checkeq(lua_gettop(L), 0, "P5a.top");

    /* stripped binary dump: source "=?", short_src "?" */
    check(luaL_dostring(L,
                        "local f = load('local a = 1\\nlocal b = 2\\nreturn a + b')\n"
                        "stripped = string.dump(f, true)\n") == 0,
          "P5.mkglobal");
    lua_getglobal(L, "stripped");
    check(lua_isstring(L, -1), "P5.stripped-isstr");
    check(luaL_loadbufferx(L, lua_tostring(L, -1), lua_rawlen(L, -1), "=S", "b") == 0,
          "P5.loadstripped");
    qk(L, -1, ">S");
    qk(L, -1, ">u");
    qk(L, -1, ">L");
    check(lua_istable(L, -1), "P5.stripped-L");
    dump_lines(L, -1);
    lua_pop(L, 1);
    lua_pop(L, 2);
    checkeq(lua_gettop(L), 0, "P5b.top");

    /* builtin globals through the C API */
    lua_getglobal(L, "print");
    qk(L, -1, ">S");
    qk(L, -1, ">u");
    lua_pop(L, 1);
    lua_getglobal(L, "require");
    qk(L, -1, ">u");
    lua_pop(L, 1);
    checkeq(lua_gettop(L), 0, "P6.top");
}

static void part_errors(lua_State *L) {
    /* non-function, non-closure values: release PUC unwraps them as
     * no-closure -> C shape; popped and (with 'f') pushed back */
    lua_pushinteger(L, 42);
    qk(L, -1, ">S");
    qk(L, -1, ">u");
    qk(L, -1, ">f");
    checkeq(lua_tointeger(L, -1), 42, "E1.int-f-back");
    lua_pop(L, 1);
    lua_pop(L, 1);
    checkeq(lua_gettop(L), 0, "E1.top");

    lua_pushliteral(L, "str");
    qk(L, -1, ">S");
    qk(L, -1, ">f");
    checkstr(lua_tostring(L, -1), "str", "E2.str-f-back");
    lua_pop(L, 1);
    lua_pop(L, 1);
    checkeq(lua_gettop(L), 0, "E2.top");

    lua_pushnil(L);
    qk(L, -1, ">S");
    qk(L, -1, ">L");
    check(lua_isnil(L, -1), "E3.nil-L");
    lua_pop(L, 1);
    lua_pop(L, 1);
    checkeq(lua_gettop(L), 0, "E3.top");

    lua_newtable(L);
    qk(L, -1, ">S");
    qk(L, -1, ">u");
    lua_pop(L, 1);
    checkeq(lua_gettop(L), 0, "E4.top");

    lua_pushboolean(L, 1);
    qk(L, -1, ">Sl");
    lua_pop(L, 1);
    checkeq(lua_gettop(L), 0, "E5.top");

    /* invalid options: 0 return, preceding options still filled */
    lua_pushcfunction(L, cf_two);
    qk(L, -1, ">X");
    qk(L, -1, ">SX");
    qk(L, -1, ">SxS");
    {
        lua_Debug ar;
        memset(&ar, 0, sizeof ar);
        /* consumes the probe, 'f' pushes it back */
        int rc = lua_getinfo(L, ">fX", &ar);
        checkeq(rc, 0, "E6.fX-rc");
        checkeq(lua_gettop(L), 1, "E6.fX-top"); /* 'f' still pushed */
        check(ar.what == NULL, "E6.fX-what-null"); /* 'S' never ran */
        lua_pop(L, 1);
    }
    checkeq(lua_gettop(L), 0, "E6.top");
}

static void part_coroutine(lua_State *L) {
    lua_State *co = lua_newthread(L);
    lua_pushcfunction(co, co_query);
    int nres = 0;
    int rst = lua_resume(co, L, 0, &nres);
    checkeq(rst, LUA_OK, "CO.rst");
    checkeq(nres, 0, "CO.nres");
    lua_pop(L, 1); /* the finished coroutine thread */

    lua_pushcfunction(L, frame_probe);
    int prc = lua_pcall(L, 0, 0, 0);
    checkeq(prc, 0, "FP.pcall");
}

/* ---------------- GC pressure part ---------------- */

/* Multi-line chunk source: lines 1..102 all carry instructions, so the
 * activelines table content is a dense, deterministic key set. */
static char gsrc[4096];
static size_t gsrc_len;

static void build_gsrc(void) {
    size_t n = 0;
    n += (size_t)sprintf(gsrc + n, "local a = 0\n");
    for (int i = 0; i < 100; i++) n += (size_t)sprintf(gsrc + n, "a = a + 1\n");
    n += (size_t)sprintf(gsrc + n, "return a\n");
    gsrc_len = n;
}

/* One pressure round: a FRESH sole-reference closure (nothing else
 * references it), the collector forced due at the next allocation, then
 * the '>' query — inside luazig the 'L' table construction, its inserts
 * and the 'f' push all allocate with the function already popped. */
static void gp_query(lua_State *L, const char *what, int want_rc, int want_dtop) {
    lua_Debug ar;
    memset(&ar, 0, sizeof ar);
    int before = lua_gettop(L);
    check(luaL_loadbufferx(L, gsrc, gsrc_len, "=gcp", NULL) == 0, "GP.load");
    lua_gc(L, LUA_GCRESTART); /* debt := 0: the next allocation runs a step */
    int rc = lua_getinfo(L, what, &ar);
    int dtop = lua_gettop(L) - before;
    printf("GP[%s] rc=%d dtop=%d\n", what, rc, dtop);
    checkeq(rc, want_rc, "GP.rc");
    checkeq(dtop, want_dtop, "GP.dtop");
    if (strchr(what, 'f') != NULL) {
        /* 'f' is pushed back BEFORE 'L' regardless of the flag order */
        check(lua_isfunction(L, strchr(what, 'L') != NULL ? -2 : -1),
              "GP.f-isfunc");
    }
    if (strchr(what, 'L') != NULL) {
        check(lua_istable(L, -1), "GP.L-istable");
        dump_lines(L, -1);
    }
    lua_settop(L, before);
}

/* pressure queries on a coroutine's own window */
static int co_gp_query(lua_State *L) {
    gp_query(L, ">L", 1, 1);
    gp_query(L, ">fL", 1, 2);
    printf("CO.GP.DONE top=%d\n", lua_gettop(L));
    return 0;
}

static void part_gc_pressure(lua_State *L) {
    build_gsrc();
    /* generational mode: a due step sweeps young objects at once */
    printf("GP.gen-ret=%d\n", lua_gc(L, LUA_GCGEN)); /* 8: was incremental */

    /* sole-reference Lua closures, every push shape, repeated rounds
     * (VM reuse across collector steps inside the call) */
    gp_query(L, ">L", 1, 1);
    gp_query(L, ">fL", 1, 2);
    gp_query(L, ">Lf", 1, 2); /* push order is f-then-L regardless */
    gp_query(L, ">SufL", 1, 2); /* full flag walk under pressure */
    gp_query(L, ">L", 1, 1);

    /* invalid option with the collector due: rc 0, 'L' still pushed */
    {
        lua_Debug ar;
        memset(&ar, 0, sizeof ar);
        int b = lua_gettop(L);
        check(luaL_loadbufferx(L, gsrc, gsrc_len, "=gcp", NULL) == 0, "GP.X-load");
        lua_gc(L, LUA_GCRESTART);
        int rc = lua_getinfo(L, ">XL", &ar);
        printf("GP[>XL] rc=%d dtop=%d\n", rc, lua_gettop(L) - b);
        checkeq(rc, 0, "GP.X-rc");
        checkeq(lua_gettop(L) - b, 1, "GP.X-dtop");
        check(lua_istable(L, -1), "GP.X-L-table");
        lua_settop(L, b);
    }

    /* light C function control under the same pressure: 'L' pushes nil */
    lua_pushcfunction(L, cf_two);
    lua_gc(L, LUA_GCRESTART);
    {
        lua_Debug ar;
        memset(&ar, 0, sizeof ar);
        int b = lua_gettop(L);
        int rc = lua_getinfo(L, ">fL", &ar);
        printf("GP[light>fL] rc=%d dtop=%d\n", rc, lua_gettop(L) - b);
        checkeq(rc, 1, "GP.light-rc");
        checkeq(lua_gettop(L) - b, 1, "GP.light-dtop");
        check(lua_iscfunction(L, -2), "GP.light-f");
        check(lua_isnil(L, -1), "GP.light-L-nil");
    }
    lua_pop(L, 2); /* pushed-back function + nil */

    /* C closure control under pressure */
    lua_pushinteger(L, 9);
    lua_pushcclosure(L, cf_upv, 1);
    lua_gc(L, LUA_GCRESTART);
    {
        lua_Debug ar;
        memset(&ar, 0, sizeof ar);
        int b = lua_gettop(L);
        int rc = lua_getinfo(L, ">fL", &ar);
        printf("GP[ccl>fL] rc=%d dtop=%d\n", rc, lua_gettop(L) - b);
        checkeq(rc, 1, "GP.ccl-rc");
        checkeq(lua_gettop(L) - b, 1, "GP.ccl-dtop");
        check(lua_iscfunction(L, -2), "GP.ccl-f");
        check(lua_isnil(L, -1), "GP.ccl-L-nil");
    }
    lua_pop(L, 2); /* pushed-back function + nil */

    /* stripped-proto control under pressure: empty activelines table */
    lua_getglobal(L, "stripped");
    check(lua_isstring(L, -1), "GP.stripped-isstr");
    check(luaL_loadbufferx(L, lua_tostring(L, -1), lua_rawlen(L, -1), "=S", "b") == 0,
          "GP.loadstripped");
    lua_gc(L, LUA_GCRESTART);
    {
        lua_Debug ar;
        memset(&ar, 0, sizeof ar);
        int b = lua_gettop(L);
        int rc = lua_getinfo(L, ">L", &ar);
        printf("GP[stripped>L] rc=%d dtop=%d\n", rc, lua_gettop(L) - b);
        checkeq(rc, 1, "GP.stripped-rc");
        checkeq(lua_gettop(L) - b, 0, "GP.stripped-dtop");
        check(lua_istable(L, -1), "GP.stripped-L-table");
        dump_lines(L, -1); /* no lineinfo: empty key set */
    }
    lua_pop(L, 2); /* table + the stripped dump string */

    /* the same pressure on a coroutine's own window */
    lua_State *co = lua_newthread(L);
    lua_pushcfunction(co, co_gp_query);
    int nres = 0;
    int rst = lua_resume(co, L, 0, &nres);
    checkeq(rst, LUA_OK, "GP.co-rst");
    checkeq(nres, 0, "GP.co-nres");
    lua_pop(L, 1); /* the coroutine */

    /* VM reuse after the pressure loop */
    check(luaL_dostring(L, "return 7") == 0, "GP.reuse");
    checkeq(lua_tointeger(L, -1), 7, "GP.reuse-val");
    lua_pop(L, 1);
    checkeq(lua_gettop(L), 0, "GP.top-balanced");
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    part_classes(L);
    part_errors(L);
    part_coroutine(L);
    part_gc_pressure(L);

    lua_close(L);
    printf("FAILS=%d\n", fails);
    return fails != 0;
}
