/*
 * 41_light_pub.c — permanent differential suite: light C function
 * publication through the public C API.
 *
 * Covers the observable contract of lua_pushcfunction /
 * lua_pushcclosure(f, 0) / luaL_setfuncs(nup==0) / luaL_requiref:
 *   - relational identity (rawequal across pushes), never raw addresses;
 *   - type / iscfunction / tocfunction / topointer predicates (booleans
 *     and equality results only);
 *   - table-key round trips and GC survival + VM reuse after the
 *     allocator control;
 *   - upvalue API on light functions (NULL results);
 *   - luaL_setfuncs placeholder and nup>0 per-closure-copy controls;
 *   - luaL_requiref module publication (_LOADED + globals);
 *   - protective package contract: debug.getupvalue(require, 1) and every
 *     searcher's upvalue point at the package table (CClosure(n=1) in
 *     BOTH engines — require/searchers never become light);
 *   - allocator control (pre-reserve, then freeze): pushcclosure(f, 0)
 *     performs ZERO allocations (separated from stack growth by the
 *     pre-reserve and by the 0-result driver), pushcclosure(f, 1) still
 *     raises LUA_ERRMEM, and the VM stays usable (push, call, GC, call)
 *     after both the fail and the success.
 *
 * Every line printed must be byte-identical between PUC Lua 5.5 and
 * luazig: no addresses, no engine-specific allocation counts. Exit code
 * is non-zero on any failed check.
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

/* ---------------- test C functions ---------------- */

static int cf_pub(lua_State *L) {
    lua_pushinteger(L, 42);
    return 1;
}

static int cf_err(lua_State *L) {
    lua_pushliteral(L, "light-pub-err");
    return lua_error(L);
}

static int cf_yield(lua_State *L) {
    lua_pushinteger(L, 11);
    return lua_yieldk(L, 1, 0, NULL);
}

/* freeze-control driver: pre-verified headroom, then the operation under
 * test; returns 0 results so the C-call result transport cannot introduce
 * engine-specific allocations after the callback returns. */
static int drv_push0(lua_State *L) {
    if (!lua_checkstack(L, 50)) return 0;
    lua_pushcfunction(L, cf_pub);
    lua_pop(L, 1); /* publication is the operation under test */
    return 0;
}

static int drv_ccl1(lua_State *L) {
    if (!lua_checkstack(L, 50)) return 0;
    lua_pushinteger(L, 5);
    lua_pushcclosure(L, cf_pub, 1); /* real closure: allocates */
    return 0;
}

/* ---------------- freezing allocator ---------------- */

static int frozen = 0;

static void *falloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    (void)ud; (void)osize;
    if (nsize == 0) { free(ptr); return NULL; }
    if (frozen) return NULL; /* fail every growth/allocation, allow frees */
    if (ptr) return realloc(ptr, nsize);
    return malloc(nsize);
}

/* ---------------- part 1: identity & predicates ---------------- */

static void part_identity(void) {
    lua_State *L = luaL_newstate();
    check(L != NULL, "P1.state");

    /* [A, A'] — two fresh pushes of the same C function */
    lua_pushcfunction(L, cf_pub);
    lua_pushcfunction(L, cf_pub);
    check(lua_rawequal(L, -1, -2), "P1.rawequal-two-pushcfunction");

    /* [A, A', L] — pushcclosure(f, 0) is the SAME value */
    lua_pushcclosure(L, cf_pub, 0);
    check(lua_rawequal(L, -1, -3), "P1.rawequal-pushcclosure0");

    /* topointer: stable across pushes, equals the C function pointer */
    check(lua_topointer(L, -1) == lua_topointer(L, -3),
          "P1.topointer-stable-across-pushes");
    check(lua_topointer(L, -1) == (void *)&cf_pub,
          "P1.topointer-is-cfn-ptr");

    /* [A, A', L, E] — a different C function is a different value */
    lua_pushcfunction(L, cf_err);
    check(lua_topointer(L, -1) == (void *)&cf_err,
          "P1.topointer-differs-per-function");
    check(lua_rawequal(L, -1, -2) == 0, "P1.rawequal-different-functions");
    check(lua_tocfunction(L, -1) != lua_tocfunction(L, -2),
          "P1.tocfunction-differs-per-function");
    lua_pop(L, 1); /* [A, A', L] */

    /* predicates on the light value */
    check(lua_type(L, -1) == LUA_TFUNCTION, "P1.type-function");
    check(lua_iscfunction(L, -1) == 1, "P1.iscfunction");
    check(lua_tocfunction(L, -1) == &cf_pub, "P1.tocfunction-eq");

    /* [A, A', L, 5, C] — heap C closure with one upvalue */
    lua_pushinteger(L, 5);
    lua_pushcclosure(L, cf_pub, 1);
    check(lua_iscfunction(L, -1) == 1, "P1.ccl-iscfunction");
    check(lua_tocfunction(L, -1) == &cf_pub, "P1.ccl-tocfunction");
    check(lua_rawequal(L, -1, -3) == 0, "P1.light-vs-ccl-not-rawequal");
    check(lua_upvalueid(L, -1, 1) != NULL, "P1.ccl-upvalueid-nonnull");
    check(lua_upvalueid(L, -3, 1) == NULL, "P1.light-upvalueid-null");
    lua_pop(L, 2); /* [A, A', L] */

    /* null C pointer storage (calling is UB, never tested) */
    lua_settop(L, 0);
    lua_pushcclosure(L, NULL, 0);
    check(lua_type(L, -1) == LUA_TFUNCTION, "P1.null-type-function");
    check(lua_iscfunction(L, -1) == 1, "P1.null-iscfunction");
    check(lua_tocfunction(L, -1) == NULL, "P1.null-tocfunction");
    check(lua_rawequal(L, -1, -1), "P1.null-self-rawequal");

    lua_close(L);
}

/* ---------------- part 2: table keys, calls, GC ---------------- */

static void dostr(lua_State *L, const char *code, const char *tag) {
    int st = luaL_dostring(L, code);
    if (st != LUA_OK) {
        printf("%s.ERROR:%s\n", tag, lua_tostring(L, -1));
        fails++;
        lua_pop(L, 1);
    }
}

static void part_tables_calls(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* table key round trip via a fresh push */
    lua_newtable(L);                      /* [t] */
    lua_pushcfunction(L, cf_pub);         /* [t, f] */
    lua_pushinteger(L, 1);                /* [t, f, 1] */
    lua_rawset(L, -3);                    /* [t] */
    lua_pushcclosure(L, cf_pub, 0);       /* [t, f'] */
    lua_rawget(L, -2);                    /* [t, f', v] */
    check(lua_type(L, -1) == LUA_TNUMBER && lua_tointeger(L, -1) == 1,
          "P2.table-key-roundtrip");
    lua_settop(L, 0);

    /* Lua-side semantics */
    lua_pushcfunction(L, cf_pub);
    lua_setglobal(L, "cfp");
    lua_pushcfunction(L, cf_err);
    lua_setglobal(L, "cfe");
    lua_pushcfunction(L, cf_yield);
    lua_setglobal(L, "cfy");
    dostr(L,
        "local ok1 = (cfp == cfp)\n"
        "local ok2 = (cfp ~= cfy)\n"
        "local t = {}; t[cfp] = 7\n"
        "local same = (next(t) == cfp)\n"
        "collectgarbage()\n"
        "local i = debug.getinfo(cfp)\n"
        "print('P2.lua-identity', ok1, ok2, same, t[cfp])\n"
        "print('P2.lua-getinfo', i.what, i.source, i.currentline, i.nups)\n"
        "print('P2.lua-tostring-prefix', (tostring(cfp):sub(1, 9)))\n"
        "local ok, e = pcall(string.dump, cfp)\n"
        "print('P2.lua-dump', ok, e)\n"
        "local ok3, e3 = pcall(cfe)\n"
        "print('P2.lua-pcall-err', ok3, e3)\n"
        "local co = coroutine.create(cfy)\n"
        "local a, b = coroutine.resume(co)\n"
        "local c, d = coroutine.resume(co, 99)\n"
        "print('P2.lua-yield', a, b, c, d)\n"
        "local co2 = coroutine.create(cfp)\n"
        "collectgarbage()\n"
        "print('P2.lua-coro-body', select(2, coroutine.resume(co2)))\n",
        "P2");
    lua_settop(L, 0);

    /* upvalue API on a light function: no name, no value */
    lua_pushcfunction(L, cf_pub);
    check(lua_getupvalue(L, -1, 1) == NULL, "P2.getupvalue-null");
    check(lua_gettop(L) == 1, "P2.getupvalue-pushes-nothing");
    lua_pushinteger(L, 9);
    check(lua_setupvalue(L, -2, 1) == NULL, "P2.setupvalue-null");
    check(lua_upvalueid(L, -1, 1) == NULL, "P2.upvalueid-null");
    lua_close(L);
}

/* ---------------- part 3: setfuncs / requiref / package ---------------- */

static int mod_func(lua_State *L) {
    lua_pushinteger(L, lua_tointeger(L, 1) + 1);
    return 1;
}

static int open_vmod(lua_State *L) {
    luaL_Reg regs[] = {
        { "inc", mod_func },
        { "ph", NULL }, /* placeholder -> false */
        { NULL, NULL }
    };
    lua_newtable(L);
    luaL_setfuncs(L, regs, 0);
    return 1;
}

static void part_lauxlib(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    luaL_Reg regs[] = {
        { "inc", mod_func },
        { "ph", NULL },
        { NULL, NULL }
    };

    /* luaL_setfuncs(nup == 0): every entry is the light function itself */
    lua_newtable(L);                         /* [t] */
    luaL_setfuncs(L, regs, 0);               /* [t] */
    lua_getfield(L, -1, "inc");              /* [t, f] */
    check(lua_type(L, -1) == LUA_TFUNCTION, "P3.setfuncs0-type");
    check(lua_iscfunction(L, -1) == 1, "P3.setfuncs0-iscfunction");
    check(lua_tocfunction(L, -1) == &mod_func, "P3.setfuncs0-tocfunction");
    check(lua_upvalueid(L, -1, 1) == NULL, "P3.setfuncs0-upvalueid-null");
    check(lua_getupvalue(L, -1, 1) == NULL, "P3.setfuncs0-getupvalue-null");
    check(lua_gettop(L) == 2, "P3.setfuncs0-getupvalue-no-push");
    lua_pushcfunction(L, mod_func);          /* [t, f, f'] */
    check(lua_rawequal(L, -1, -2), "P3.setfuncs0-rawequal-fresh-push");
    lua_pop(L, 2);                           /* [t] */
    lua_getfield(L, -1, "ph");               /* [t, ph] */
    check(lua_type(L, -1) == LUA_TBOOLEAN && lua_toboolean(L, -1) == 0,
          "P3.setfuncs-placeholder-false");
    lua_pop(L, 2);                           /* [] */

    /* luaL_setfuncs(nup == 1): per-closure COPIES (setupvalue on one does
     * not leak into the other) */
    {
        luaL_Reg two[] = {
            { "f1", mod_func },
            { "f2", mod_func },
            { NULL, NULL }
        };
        lua_newtable(L);                     /* [t] */
        lua_pushinteger(L, 42);              /* [t, 42] */
        luaL_setfuncs(L, two, 1);            /* [t] */
        lua_getfield(L, -1, "f1");           /* [t, f1] */
        lua_pushinteger(L, 77);              /* [t, f1, 77] */
        check(lua_setupvalue(L, -2, 1) != NULL, "P3.setfuncs1-setupvalue-name");
        /* [t, f1] */
        lua_getfield(L, -2, "f2");           /* [t, f1, f2] */
        {
            lua_Integer v = -1;
            const char *n = lua_getupvalue(L, -1, 1);
            if (n != NULL && lua_isinteger(L, -1)) v = lua_tointeger(L, -1);
            check(v == 42, "P3.setfuncs1-per-closure-copy");
        }
        lua_pop(L, 3);                       /* [] */
    }

    /* luaL_requiref: module table published in globals and _LOADED */
    luaL_requiref(L, "vmod41", open_vmod, 1);  /* [m] */
    check(lua_type(L, -1) == LUA_TTABLE, "P3.requiref-table");
    lua_getfield(L, -1, "inc");                /* [m, inc] */
    lua_pushinteger(L, 41);                    /* [m, inc, 41] */
    lua_call(L, 1, 1);                         /* [m, r] */
    check(lua_tointeger(L, -1) == 42, "P3.requiref-openf-callable");
    lua_pop(L, 1);                             /* [m] */
    lua_getglobal(L, "vmod41");                /* [m, g] */
    check(lua_rawequal(L, -1, -2), "P3.requiref-global-same");
    lua_pop(L, 1);                             /* [m] */
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED"); /* [m, loaded] */
    lua_getfield(L, -1, "vmod41");             /* [m, loaded, m2] */
    check(lua_rawequal(L, -1, -3), "P3.requiref-loaded-same");
    lua_pop(L, 3);                             /* [] */

    /* protective package contract: require and every searcher keep the
     * package table as upvalue 1 (CClosure(n=1) in BOTH engines) */
    dostr(L,
        "local pkg = require('package')\n"
        "local _, uv = debug.getupvalue(require, 1)\n"
        "print('P3.require-upvalue', uv == pkg)\n"
        "local all = true\n"
        "for i = 1, #pkg.searchers do\n"
        "  local _, v = debug.getupvalue(pkg.searchers[i], 1)\n"
        "  if v ~= pkg then all = false end\n"
        "end\n"
        "print('P3.searchers-upvalues', all, #pkg.searchers)\n"
        "package.preload['pre41'] = function() return { marker = 41 } end\n"
        "print('P3.require-works', require('pre41').marker)\n",
        "P3");

    lua_close(L);
}

/* ---------------- part 4: allocator control ---------------- */

static void part_allocator(void) {
    lua_State *L = lua_newstate(falloc, NULL, 0);
    check(L != NULL, "P4.state");

    /* pre-reserve stack slots so the frozen push cannot be a stack growth */
    check(lua_checkstack(L, 500) == 1, "P4.prereserve");

    /* prewarm the pcall machinery with the same driver shape (unfrozen),
     * then stage the control callee BEFORE the freeze */
    lua_pushcfunction(L, drv_push0);
    lua_pcall(L, 0, 0, 0); /* warm */
    lua_pushcfunction(L, drv_push0); /* staged */
    frozen = 1;
    check(lua_pcall(L, 0, 0, 0) == LUA_OK, "P4.freeze-push0-ok");
    frozen = 0;

    /* control: a REAL closure must still allocate -> LUA_ERRMEM */
    lua_pushcfunction(L, drv_ccl1);
    lua_pcall(L, 0, 0, 0); /* warm */
    lua_pushcfunction(L, drv_ccl1); /* staged */
    frozen = 1;
    check(lua_pcall(L, 0, 0, 0) == LUA_ERRMEM, "P4.freeze-ccl1-errmem");
    frozen = 0;
    lua_settop(L, 0);

    /* VM reuse after fail and success: push, call, GC, call again */
    lua_pushcfunction(L, cf_pub);
    check(lua_iscfunction(L, -1) == 1, "P4.reuse-push");
    lua_pushinteger(L, 0);
    check(lua_pcall(L, 1, 1, 0) == LUA_OK && lua_tointeger(L, -1) == 42,
          "P4.reuse-call");
    lua_pop(L, 1);
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_pushcfunction(L, cf_pub);
    lua_pushinteger(L, 0);
    check(lua_pcall(L, 1, 1, 0) == LUA_OK && lua_tointeger(L, -1) == 42,
          "P4.reuse-after-gc");
    lua_pop(L, 1);

    lua_close(L);
}

int main(void) {
    /* C-level printf and the io library's stdout must interleave
     * identically on both engines regardless of block buffering. */
    setvbuf(stdout, NULL, _IONBF, 0);
    part_identity();
    part_tables_calls();
    part_lauxlib();
    part_allocator();
    printf("LIGHT_PUB: %d failures\n", fails);
    return fails ? 1 : 0;
}
