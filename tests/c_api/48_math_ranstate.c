/* 48_math_ranstate: math.random/randomseed as CClosure(1) pairs over a
 * per-opening RanState userdata (PUC lmathlib.c setrandfunc shape).
 *
 * Differential suite (zig vs PUC, byte-exact): owner/identity (the pair
 * shares ONE userdata upvalue value, distinct upvalue ids, distinct C
 * functions), fresh table/state per luaopen_math, fixed-seed sequence
 * parity, cross-pair independence (the decisive anti-alias check),
 * lua_setupvalue as the sole ownership transfer, GC survival of
 * registry-rooted closures, calls on a coroutine handle (both openings),
 * and the argument-error texts.
 *
 * The debug.setupvalue lanes only ever install a RanState userdata VALUE
 * (cross-pair); installing any other class into the slot is PUC UB
 * (lua_touserdata -> NULL -> deref) and is deliberately not reproduced. */
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int fails = 0;
__attribute__((constructor)) static void unbuf(void) { setbuf(stdout, NULL); }
static void check(long cond, const char *label) {
    printf("%s:%ld\n", label, cond);
    if (!cond) fails++;
}

static int ref_r1, ref_s1, ref_r2, ref_s2;

static void seed_and_draw(lua_State *L, int ref_r, int ref_s, long long *out, int n) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_s);
    lua_pushinteger(L, 42);
    lua_call(L, 1, 2);
    lua_pop(L, 2);
    for (int i = 0; i < n; i++) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r);
        lua_pushinteger(L, 10);
        lua_pushinteger(L, 99);
        lua_call(L, 2, 1);
        out[i] = lua_tointeger(L, -1);
        lua_pop(L, 1);
    }
}

/* push fn(ref); push its upvalue-1 value; return abs index of the value */
static int push_upval(lua_State *L, int ref) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
    int f = lua_gettop(L);
    const char *un = lua_getupvalue(L, f, 1);
    if (un == NULL) { lua_pop(L, 1); return 0; }
    return lua_gettop(L);   /* value on top; fn below it */
}

int main(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* --- P1: save pair 1 (the bootstrap math) --- */
    lua_getglobal(L, "math");
    lua_getfield(L, -1, "random");
    ref_r1 = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_getfield(L, -1, "randomseed");
    ref_s1 = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_pop(L, 1);

    int v_r1 = push_upval(L, ref_r1);
    check(v_r1 != 0, "P1.r1.hasupvalue");
    check(lua_type(L, v_r1) == LUA_TUSERDATA, "P1.r1.up1.userdata");
    int v_s1 = push_upval(L, ref_s1);
    check(v_s1 != 0, "P1.s1.hasupvalue");
    check(lua_type(L, v_s1) == LUA_TUSERDATA, "P1.s1.up1.userdata");
    check(lua_rawequal(L, v_r1, v_s1) == 1, "P1.pair.sharesuserdata");
    lua_pop(L, 4);   /* fn, val, fn, val */

    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r1);
    const void *idr = lua_upvalueid(L, -1, 1);
    lua_pop(L, 1);
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_s1);
    const void *ids = lua_upvalueid(L, -1, 1);
    lua_pop(L, 1);
    check(idr != NULL && ids != NULL && idr != ids, "P1.pair.upvalueid.distinct");
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r1);
    check(lua_upvalueid(L, -1, 1) == idr, "P1.upvalueid.gc.stable");
    lua_pop(L, 1);

    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r1);
    lua_CFunction cfr = lua_tocfunction(L, -1);
    lua_pop(L, 1);
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_s1);
    lua_CFunction cfs = lua_tocfunction(L, -1);
    lua_pop(L, 1);
    check(cfr != NULL && cfs != NULL && cfr != cfs, "P1.pair.cfunc.distinct");

    /* --- P1b: second luaopen_math: fresh table, closures, userdata --- */
    int rc = luaopen_math(L);
    check(rc == 1, "P1b.open.ret1");
    check(lua_type(L, -1) == LUA_TTABLE, "P1b.open.table");
    int t2 = lua_gettop(L);
    lua_getglobal(L, "math");
    check(lua_rawequal(L, -1, t2) == 0, "P1b.newtable.distinct.global");
    lua_pop(L, 1);
    lua_getfield(L, t2, "random");
    check(lua_type(L, -1) == LUA_TFUNCTION, "P1b.newrandom.isfunc");
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r1);
    check(lua_rawequal(L, -1, -2) == 0, "P1b.newrandom.distinct.old");
    lua_pop(L, 1);   /* old r1 */
    int nr = lua_gettop(L);   /* new random */
    const char *un = lua_getupvalue(L, nr, 1);
    check(un != NULL, "P1b.newrandom.hasupvalue");
    int nv = lua_gettop(L);
    check(lua_type(L, nv) == LUA_TUSERDATA, "P1b.newrandom.up1.userdata");
    const void *idr2 = lua_upvalueid(L, nr, 1);
    check(idr2 != NULL && idr2 != idr, "P1b.newrandom.upvalueid.distinct");
    /* new randomseed shares the new userdata */
    lua_getfield(L, t2, "randomseed");
    un = lua_getupvalue(L, -1, 1);
    check(un != NULL, "P1b.newseed.hasupvalue");
    check(lua_rawequal(L, -1, nv) == 1, "P1b.newpair.sharesuserdata");
    /* new userdata differs from the old pair's */
    int v_r1b = push_upval(L, ref_r1);
    check(lua_rawequal(L, v_r1b, nv) == 0, "P1b.newuserdata.distinct.old");
    lua_settop(L, 0);

    /* --- P1b2: third open; save pair 2 cleanly --- */
    rc = luaopen_math(L);
    check(rc == 1, "P1b2.open.ret1");
    lua_getfield(L, -1, "random");
    ref_r2 = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_getfield(L, -1, "randomseed");
    ref_s2 = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_pop(L, 1);
    int v_r2 = push_upval(L, ref_r2);
    int v_s2 = push_upval(L, ref_s2);
    check(lua_rawequal(L, v_r2, v_s2) == 1, "P1b2.newpair.sharesuserdata");
    int v_r1c = push_upval(L, ref_r1);
    check(lua_rawequal(L, v_r1c, v_r2) == 0, "P1b2.newuserdata.distinct.old");
    lua_pop(L, 6);

    /* --- P1c: fixed-seed sequence equality + cross-pair independence --- */
    long long seq1[5], seq2[5];
    seed_and_draw(L, ref_r1, ref_s1, seq1, 5);
    seed_and_draw(L, ref_r2, ref_s2, seq2, 5);
    int same = 1;
    for (int i = 0; i < 5; i++) if (seq1[i] != seq2[i]) same = 0;
    check(same, "P1c.fixedseed.seq.equal");
    seed_and_draw(L, ref_r2, ref_s2, seq2, 1);
    check(seq2[0] == seq1[0], "P1c.pair2.reseed.restart");
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r1);
    lua_pushinteger(L, 10); lua_pushinteger(L, 99);
    lua_call(L, 2, 1);
    check(lua_tointeger(L, -1) != seq1[0], "P1c.pair1.independent");
    lua_pop(L, 1);
    /* DECISIVE aliasing check: reseed s2(42), then draw r1 IMMEDIATELY.
     * PUC: r1 owns ud1 -> gives seq1's continuation (!= seq2[0]).
     * A single shared state: r1 gives seq2[0] exactly. */
    seed_and_draw(L, ref_s2, ref_s2, seq2, 0);
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r1);
    lua_pushinteger(L, 10); lua_pushinteger(L, 99);
    lua_call(L, 2, 1);
    check(lua_tointeger(L, -1) != seq2[0], "P1c.alias.decisive");
    lua_pop(L, 1);

    /* --- P2: upvalue swap via C API: the upvalue IS the owner --- */
    seed_and_draw(L, ref_r1, ref_s1, seq1, 5);
    seed_and_draw(L, ref_r2, ref_s2, seq2, 5);
    /* stack: fn_r1, ud1, fn_r2, ud2 */
    push_upval(L, ref_r1);            /* [fn_r1, ud1] */
    push_upval(L, ref_r2);            /* [fn_r1, ud1, fn_r2, ud2] */
    int base = lua_gettop(L) - 3;
    int fn_r1 = base;
    int ud1 = base + 1;
    int fn_r2 = base + 2;
    int ud2 = base + 3;
    /* r1 := ud2 */
    lua_pushvalue(L, ud2);
    check(lua_setupvalue(L, fn_r1, 1) != NULL, "P2.setupvalue.r1.ok");
    /* r2 := ud1 */
    lua_pushvalue(L, ud1);
    check(lua_setupvalue(L, fn_r2, 1) != NULL, "P2.setupvalue.r2.ok");
    lua_pop(L, 4);
    /* reseed each pair's STATE via its own seed fn (seed fns keep their
     * upvalues: s1->ud1, s2->ud2); after swap r1 draws from ud2, r2 from ud1 */
    seed_and_draw(L, ref_s2, ref_s2, seq2, 0);   /* reseed ud2 via s2 */
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r1);
    lua_pushinteger(L, 10); lua_pushinteger(L, 99);
    lua_call(L, 2, 1);
    check(lua_tointeger(L, -1) == seq2[0], "P2.swap.r1.follows.ud2");
    lua_pop(L, 1);
    seed_and_draw(L, ref_s1, ref_s1, seq1, 0);   /* reseed ud1 via s1 */
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r2);
    lua_pushinteger(L, 10); lua_pushinteger(L, 99);
    lua_call(L, 2, 1);
    check(lua_tointeger(L, -1) == seq1[0], "P2.swap.r2.follows.ud1");
    lua_pop(L, 1);
    /* swap back so later lanes observe the natural pairing: the current
     * upvalue values on the stack are [fn_r1, ud2, fn_r2, ud1] */
    push_upval(L, ref_r1);
    push_upval(L, ref_r2);
    int t = lua_gettop(L);   /* fn_r1 at t-3, ud2 at t-2, fn_r2 at t-1, ud1 at t */
    lua_pushvalue(L, t);            /* ud1 */
    lua_setupvalue(L, t - 3, 1);    /* r1 := ud1 */
    lua_pushvalue(L, t - 2);        /* ud2 */
    lua_setupvalue(L, t - 1, 1);    /* r2 := ud2 */
    lua_settop(L, 0);

    /* --- P3: GC after dropping the math table; closures alive via refs --- */
    lua_pushnil(L);
    lua_setglobal(L, "math");
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    seed_and_draw(L, ref_s1, ref_s1, seq1, 0);
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r1);
    lua_pushinteger(L, 10); lua_pushinteger(L, 99);
    lua_call(L, 2, 1);
    check(lua_isinteger(L, -1) == 1, "P3.gc.closure.survives");
    lua_pop(L, 1);
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r1);
    lua_pushinteger(L, 10); lua_pushinteger(L, 99);
    lua_call(L, 2, 1);
    check(lua_isinteger(L, -1) == 1, "P3.gc.second.call");
    lua_pop(L, 1);

    /* --- P4: pair-1 closures on a coroutine handle --- */
    lua_State *co = lua_newthread(L);
    lua_rawgeti(co, LUA_REGISTRYINDEX, ref_s1);
    lua_pushinteger(co, 42);
    check(lua_pcall(co, 1, 2, 0) == LUA_OK, "P4.coro.seedcall");
    lua_pop(co, 2);
    lua_rawgeti(co, LUA_REGISTRYINDEX, ref_r1);
    lua_pushinteger(co, 10); lua_pushinteger(co, 99);
    check(lua_pcall(co, 2, 1, 0) == LUA_OK, "P4.coro.randcall");
    check(lua_isinteger(co, -1) == 1, "P4.coro.value");
    lua_pop(co, 1);

    /* --- P4b: pair-2 (2nd opening) closures on the coroutine handle:
     * deterministic draws, upvalue id visible from the coroutine and
     * GC-stable, cross-pair independence on the coroutine path --- */
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r2);
    const void *id2_main = lua_upvalueid(L, -1, 1);
    lua_pop(L, 1);
    lua_rawgeti(co, LUA_REGISTRYINDEX, ref_s2);
    lua_pushinteger(co, 42); lua_pushinteger(co, 7);
    check(lua_pcall(co, 2, 0, 0) == LUA_OK, "P4b.co.seed2.ok");
    lua_rawgeti(co, LUA_REGISTRYINDEX, ref_r2);
    lua_pushinteger(co, 100);
    check(lua_pcall(co, 1, 1, 0) == LUA_OK, "P4b.co.random2.ok");
    check(lua_tointeger(co, -1) == 49, "P4b.co.random2.49");
    lua_pop(co, 1);
    lua_rawgeti(co, LUA_REGISTRYINDEX, ref_r2);
    check(lua_upvalueid(co, -1, 1) == id2_main, "P4b.upid.same.on.coro");
    lua_pop(co, 1);
    lua_gc(L, LUA_GCCOLLECT); lua_gc(L, LUA_GCCOLLECT);
    lua_rawgeti(co, LUA_REGISTRYINDEX, ref_r2);
    lua_pushinteger(co, 100);
    check(lua_pcall(co, 1, 1, 0) == LUA_OK, "P4b.co.random2.postgc.ok");
    check(lua_tointeger(co, -1) == 68, "P4b.co.random2.postgc.68");
    lua_pop(co, 1);
    lua_rawgeti(co, LUA_REGISTRYINDEX, ref_r2);
    check(lua_upvalueid(co, -1, 1) == id2_main, "P4b.upid.stable.across.gc");
    lua_pop(co, 1);
    /* pair 1 was NOT restarted by pair 2's reseeds: seed(42,7) via s1
     * (still owning ud1), then r1 gives 49 */
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_s1);
    lua_pushinteger(L, 42); lua_pushinteger(L, 7);
    check(lua_pcall(L, 2, 0, 0) == LUA_OK, "P4b.main.seed1.ok");
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r1);
    lua_pushinteger(L, 100);
    check(lua_pcall(L, 1, 1, 0) == LUA_OK, "P4b.main.random1.ok");
    check(lua_tointeger(L, -1) == 49, "P4b.main.random1.49");
    lua_pop(L, 1);

    /* --- P5: argument errors (status + message text) --- */
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r1);
    lua_pushinteger(L, 1); lua_pushinteger(L, 2); lua_pushinteger(L, 3);
    int st = lua_pcall(L, 3, 0, 0);
    printf("P5.err.3args: st=%d type=%s msg=%s\n", st,
           lua_typename(L, lua_type(L, -1)),
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "(null)");
    if (st != LUA_ERRRUN) fails++;
    lua_pop(L, 1);
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r1);
    lua_pushinteger(L, 5); lua_pushinteger(L, 1);
    st = lua_pcall(L, 2, 0, 0);
    printf("P5.err.empty: st=%d type=%s msg=%s\n", st,
           lua_typename(L, lua_type(L, -1)),
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "(null)");
    if (st != LUA_ERRRUN) fails++;
    lua_pop(L, 1);
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_r1);
    lua_pushliteral(L, "x");
    st = lua_pcall(L, 1, 0, 0);
    printf("P5.err.strarg: st=%d type=%s msg=%s\n", st,
           lua_typename(L, lua_type(L, -1)),
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "(null)");
    if (st != LUA_ERRRUN) fails++;
    lua_pop(L, 1);

    /* --- P5b: luaL_checkinteger conversion parity (numeric strings incl.
     * boundary forms, integral floats, PUC rejection classes) --- */
    /* call the registry-ref'd fn with nargs args already on the stack;
     * print a uniform verdict: ok + integer results, or the error line */
    void lane(int ref, int nargs, int nres, const char *label) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
        lua_insert(L, -(nargs + 1));
        int lst = lua_pcall(L, nargs, nres, 0);
        if (lst == LUA_OK) {
            printf("%s: ok", label);
            for (int i = 0; i < nres; i++)
                printf(" %lld", (long long)lua_tointeger(L, i - nres));
            printf("\n");
            lua_pop(L, nres);
        } else {
            printf("%s: st=%d type=%s msg=%s\n", label, lst,
                   lua_typename(L, lua_type(L, -1)),
                   lua_tostring(L, -1) ? lua_tostring(L, -1) : "(null)");
            lua_pop(L, 1);
            if (lst != LUA_ERRRUN) fails++;
        }
    }
    /* deterministic value lanes: reseed, then convert */
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_s1);
    lua_pushinteger(L, 42); lua_pushinteger(L, 7);
    lua_call(L, 2, 0);
    lua_pushliteral(L, "10"); lane(ref_r1, 1, 1, "P5b.str.decimal");
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_s1);
    lua_pushinteger(L, 42); lua_pushinteger(L, 7);
    lua_call(L, 2, 0);
    lua_pushliteral(L, " 0x10 "); lane(ref_r1, 1, 1, "P5b.str.hexspace");
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_s1);
    lua_pushinteger(L, 42); lua_pushinteger(L, 7);
    lua_call(L, 2, 0);
    lua_pushliteral(L, "1e2"); lane(ref_r1, 1, 1, "P5b.str.exp");
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_s1);
    lua_pushinteger(L, 42); lua_pushinteger(L, 7);
    lua_call(L, 2, 0);
    lua_pushliteral(L, " +10 "); lane(ref_r1, 1, 1, "P5b.str.signspace");
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_s1);
    lua_pushinteger(L, 42); lua_pushinteger(L, 7);
    lua_call(L, 2, 0);
    lua_pushnumber(L, 2.0); lua_pushliteral(L, "5");
    lane(ref_r1, 2, 1, "P5b.mixed.floatstr");
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_s1);
    lua_pushinteger(L, 42); lua_pushinteger(L, 7);
    lua_call(L, 2, 0);
    lua_pushnumber(L, 1.0); lua_pushnumber(L, 5.0);
    lane(ref_r1, 2, 1, "P5b.floats.integral");
    /* rejection lanes: fractional / non-numeric / out-of-range / Zig-only
     * numeral forms PUC's luaO_str2num rejects */
    lua_pushnumber(L, 2.5); lane(ref_r1, 1, 1, "P5b.float.frac");
    lua_pushliteral(L, "3.5"); lane(ref_r1, 1, 1, "P5b.str.frac");
    lua_pushliteral(L, "1e999"); lane(ref_r1, 1, 1, "P5b.str.overflow");
    lua_pushliteral(L, "9223372036854775808"); lane(ref_r1, 1, 1, "P5b.str.maxp1");
    lua_pushliteral(L, "-9223372036854775808"); lane(ref_r1, 1, 1, "P5b.str.minint");
    lua_pushliteral(L, "abc"); lane(ref_r1, 1, 1, "P5b.str.nonnum");
    lua_pushliteral(L, "inf"); lane(ref_r1, 1, 1, "P5b.str.inf");
    lua_pushliteral(L, "nan"); lane(ref_r1, 1, 1, "P5b.str.nan");
    lua_pushlstring(L, "10\0", 3); lane(ref_r1, 1, 1, "P5b.str.embeddednul");
    lua_pushliteral(L, "0b101"); lane(ref_r1, 1, 1, "P5b.str.zigbinary");
    lua_pushliteral(L, "1_000"); lane(ref_r1, 1, 1, "P5b.str.underscore");
    lua_pushliteral(L, "2^62"); lane(ref_r1, 1, 1, "P5b.str.trailing");
    lua_pushboolean(L, 1); lane(ref_r1, 1, 1, "P5b.bool");
    lua_pushnil(L); lane(ref_r1, 1, 1, "P5b.nil");
    /* __name-aware tag_error type name */
    lua_newtable(L);
    lua_newtable(L);
    lua_pushliteral(L, "mytype");
    lua_setfield(L, -2, "__name");
    lua_setmetatable(L, -2);
    lane(ref_r1, 1, 1, "P5b.name.meta");
    /* randomseed string forms + luaL_optinteger nil default */
    lua_pushliteral(L, "42"); lua_pushliteral(L, "7");
    lane(ref_s1, 2, 2, "P5b.seed.strpair");
    lua_pushliteral(L, "42"); lane(ref_s1, 1, 2, "P5b.seed.stronly");
    lua_pushinteger(L, 42); lua_pushnil(L);
    lane(ref_s1, 2, 2, "P5b.seed.optnil");
    lua_pushliteral(L, " 42 "); lane(ref_s1, 1, 2, "P5b.seed.strspace");
    lua_pushliteral(L, "0x2A"); lane(ref_s1, 1, 2, "P5b.seed.strhex");
    lua_pushliteral(L, "42.5"); lane(ref_s1, 1, 2, "P5b.seed.frac");
    lua_pushliteral(L, "abc"); lane(ref_s1, 1, 2, "P5b.seed.nonnum");
    lua_pushliteral(L, "42"); lua_pushliteral(L, "abc");
    lane(ref_s1, 2, 2, "P5b.seed.arg2nonnum");
    lua_pushliteral(L, "42"); lua_pushliteral(L, "7.5");
    lane(ref_s1, 2, 2, "P5b.seed.arg2frac");
    /* sequence after a failed call: the draw happens before the arg check
     * on both runtimes, so the next value must agree */
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref_s1);
    lua_pushinteger(L, 42); lua_pushinteger(L, 7);
    lua_call(L, 2, 0);
    lua_pushliteral(L, "abc"); lane(ref_r1, 1, 1, "P5b.seq.errcall");
    lua_pushinteger(L, 100); lane(ref_r1, 1, 1, "P5b.seq.aftererr");
    lua_pushinteger(L, 100); lane(ref_r1, 1, 1, "P5b.seq.next");

    printf("fails:%d\n", fails);
    lua_close(L);
    return fails ? 1 : 0;
}
