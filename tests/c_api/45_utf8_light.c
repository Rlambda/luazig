/*
 * 45_utf8_light.c — permanent differential suite: the utf8 stdlib
 * published as light C functions (canonical LightCFunction values with
 * stable real C ABI pointers).
 *
 * Covers the two dispatch lanes of the pilot:
 *   - the real C ABI lane: host lua_call / lua_pcall on the published
 *     light functions (trampoline), including MULTRET result counts,
 *     error status/type, and GC survival;
 *   - the normalized internal lanes: pcall/xpcall, gsub replacement,
 *     for-in iterator (tforcall), __pairs, tailcall, __index/__newindex
 *     and arithmetic/concat metamethods, table.sort comparator,
 *     coroutine bodies (resume VLCF lane);
 *   - publication identity: rawequal across fetches, tocfunction /
 *     topointer predicates, no upvalues, table keys, republish via
 *     require (package.loaded reset), second-state publication (the
 *     static C ABI pointer is state-independent).
 *
 * Divergence policy (pre-existing, verified before/after the pilot):
 * error TEXTS of utf8 argument errors and the fixed-window MULTRET
 * result count of utf8.len/offset success diverge from PUC — those
 * cases are asserted status/type-only or with fixed nresults. Every
 * other printed line must be byte-identical between PUC Lua 5.5 and
 * luazig: no addresses, no engine-specific counts. Exit code is
 * non-zero on any failed check.
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

static void dostr(lua_State *L, const char *code, const char *tag) {
    int st = luaL_dostring(L, code);
    if (st != LUA_OK) {
        printf("%s.ERROR:%s\n", tag, lua_tostring(L, -1));
        fails++;
        lua_pop(L, 1);
    }
}

/* Push a utf8 library function on top of the stack. */
static void push_utf8(lua_State *L, const char *name) {
    lua_getglobal(L, "utf8");
    lua_getfield(L, -1, name);
    lua_remove(L, -2);
}

/* ---------------- part 1: publication identity & predicates ---------------- */

static void part_identity(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    check(L != NULL, "P1.state");

    /* two fetches of utf8.char are the same value */
    push_utf8(L, "char");                    /* [f] */
    push_utf8(L, "char");                    /* [f, f'] */
    check(lua_rawequal(L, -1, -2), "P1.rawequal-two-fetches");
    check(lua_type(L, -1) == LUA_TFUNCTION, "P1.type-function");
    check(lua_iscfunction(L, -1) == 1, "P1.iscfunction");
    check(lua_tocfunction(L, -1) != NULL, "P1.tocfunction-nonnull");
    check(lua_topointer(L, -1) == lua_tocfunction(L, -1),
          "P1.topointer-eq-tocfunction");
    check(lua_topointer(L, -1) == lua_topointer(L, -2),
          "P1.topointer-stable");

    /* different functions are different values */
    push_utf8(L, "len");                     /* [f, f', len] */
    check(lua_rawequal(L, -1, -3) == 0, "P1.rawequal-different");
    check(lua_tocfunction(L, -1) != lua_tocfunction(L, -3),
          "P1.tocfunction-different");
    check(lua_iscfunction(L, -1) == 1, "P1.len-iscfunction");
    lua_pop(L, 3);

    /* light functions have no upvalues */
    push_utf8(L, "char");                    /* [f] */
    check(lua_upvalueid(L, -1, 1) == NULL, "P1.upvalueid-null");
    check(lua_getupvalue(L, -1, 1) == NULL, "P1.getupvalue-null");
    check(lua_gettop(L) == 1, "P1.getupvalue-no-push");
    lua_pushinteger(L, 9);
    check(lua_setupvalue(L, -2, 1) == NULL, "P1.setupvalue-null");
    lua_pop(L, 2);

    /* the codes iterator published by utf8.codes is a light function */
    push_utf8(L, "codes");                   /* [codes] */
    lua_pushliteral(L, "AB");                /* [codes, s] */
    lua_call(L, 1, 3);                       /* [iter, s, n] */
    check(lua_type(L, -3) == LUA_TFUNCTION, "P1.codes-iter-type");
    check(lua_iscfunction(L, -3) == 1, "P1.codes-iter-iscfunction");
    check(lua_tocfunction(L, -3) != NULL, "P1.codes-iter-tocfunction");
    check(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 0,
          "P1.codes-control-zero");
    /* the strict and lax iterators are distinct functions */
    push_utf8(L, "codes");                   /* [iter, s, n, codes] */
    lua_pushliteral(L, "AB");
    lua_pushboolean(L, 1);                   /* lax */
    lua_call(L, 2, 3);                       /* [iter, s, n, iter2, s2, n2] */
    check(lua_rawequal(L, -3, -6) == 0, "P1.strict-vs-lax-iterator");
    check(lua_iscfunction(L, -3) == 1, "P1.lax-iter-iscfunction");
    lua_pop(L, 6);

    lua_close(L);
}

/* ---------------- part 2: trampoline lane (host C calls) ---------------- */

static void part_trampoline(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* utf8.char: fixed and MULTRET results (window 1 == actual 1) */
    push_utf8(L, "char");
    lua_pushinteger(L, 65);
    lua_pushinteger(L, 0x7F);
    lua_pushinteger(L, 0x80);
    lua_call(L, 3, 1);                       /* [s] */
    {
        size_t n = 0;
        const char *s = lua_tolstring(L, -1, &n);
        check(n == 4 && s != NULL && (unsigned char)s[0] == 65 &&
                  (unsigned char)s[1] == 0x7F && (unsigned char)s[2] == 0xC2 &&
                  (unsigned char)s[3] == 0x80,
              "P2.char-bytes");
    }
    lua_pop(L, 1);
    push_utf8(L, "char");
    lua_call(L, 0, 1);                       /* [""] */
    {
        size_t n = 42;
        const char *s = lua_tolstring(L, -1, &n);
        check(s != NULL && n == 0, "P2.char-empty");
    }
    lua_pop(L, 1);
    push_utf8(L, "char");
    lua_pushinteger(L, 66);
    lua_call(L, 1, LUA_MULTRET);             /* ["B"] */
    check(lua_gettop(L) == 1, "P2.char-multret-count");
    check(lua_isstring(L, -1) && *lua_tostring(L, -1) == 'B',
          "P2.char-multret-value");
    lua_pop(L, 1);

    /* utf8.len: fixed nresults (MULTRET count diverges pre-existing) */
    push_utf8(L, "len");
    lua_pushliteral(L, "AB");
    lua_call(L, 1, 1);
    check(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 2, "P2.len-value");
    lua_pop(L, 1);
    push_utf8(L, "len");
    lua_pushliteral(L, "A\xFF" "B");
    lua_call(L, 1, 2);                       /* [fail, pos] */
    check(lua_isnil(L, -2), "P2.len-fail-first");
    check(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 2,
          "P2.len-fail-pos");
    lua_pop(L, 2);

    /* utf8.codepoint: dynamic result counts */
    push_utf8(L, "codepoint");
    lua_pushliteral(L, "AB");
    lua_pushinteger(L, 1);
    lua_pushinteger(L, 2);
    lua_call(L, 3, 2);
    check(lua_tointeger(L, -2) == 65 && lua_tointeger(L, -1) == 66,
          "P2.cp-two");
    lua_pop(L, 2);
    push_utf8(L, "codepoint");
    lua_pushliteral(L, "AB");
    lua_call(L, 1, LUA_MULTRET);
    check(lua_gettop(L) == 1 && lua_tointeger(L, -1) == 65,
          "P2.cp-multret-one");
    lua_pop(L, 1);
    push_utf8(L, "codepoint");
    lua_pushliteral(L, "AB");
    lua_pushinteger(L, 2);
    lua_pushinteger(L, 1);
    lua_call(L, 3, LUA_MULTRET);
    check(lua_gettop(L) == 0, "P2.cp-empty-interval");

    /* utf8.offset: (initial, final) pair on valid strings */
    push_utf8(L, "offset");
    lua_pushliteral(L, "A\xE0\xA0\x80" "B");  /* A U+0800 B */
    lua_pushinteger(L, 2);
    lua_call(L, 2, 2);
    check(lua_tointeger(L, -2) == 2 && lua_tointeger(L, -1) == 4,
          "P2.offset-pair");
    lua_pop(L, 2);
    push_utf8(L, "offset");
    lua_pushliteral(L, "AB");
    lua_pushinteger(L, -1);
    lua_call(L, 2, 2);
    check(lua_tointeger(L, -2) == 2 && lua_tointeger(L, -1) == 2,
          "P2.offset-back");
    lua_pop(L, 2);
    push_utf8(L, "offset");
    lua_pushliteral(L, "AB");
    lua_pushinteger(L, 5);
    lua_call(L, 2, 1);                       /* fixed: fail is nil */
    check(lua_isnil(L, -1), "P2.offset-fail-nil");
    lua_pop(L, 1);

    /* utf8.codes iterator through the C lane */
    push_utf8(L, "codes");
    lua_pushliteral(L, "AB");
    lua_call(L, 1, 3);                       /* [iter, s, n] */
    lua_pushvalue(L, -3);                    /* iter */
    lua_pushvalue(L, -3);                    /* s */
    lua_pushinteger(L, 0);
    lua_call(L, 2, 2);                       /* [iter, s, n, p, c] */
    check(lua_tointeger(L, -2) == 1 && lua_tointeger(L, -1) == 65,
          "P2.iter-first");
    lua_pop(L, 2);                           /* [iter, s, n] */
    lua_pushvalue(L, -3);
    lua_pushvalue(L, -3);
    lua_pushinteger(L, 2);
    lua_call(L, 2, 0);                       /* end: no results, no error */
    check(lua_gettop(L) == 3, "P2.iter-end");
    lua_pop(L, 3);

    /* error paths: status + error type only (texts diverge pre-existing) */
    push_utf8(L, "len");
    lua_pushliteral(L, "AB");
    lua_pushinteger(L, 99);
    check(lua_pcall(L, 2, 0, 0) == LUA_ERRRUN, "P2.len-oob-status");
    check(lua_type(L, -1) == LUA_TSTRING, "P2.len-oob-errtype");
    lua_pop(L, 1);
    push_utf8(L, "char");
    lua_pushinteger(L, -1);
    check(lua_pcall(L, 1, 0, 0) == LUA_ERRRUN, "P2.char-range-status");
    check(lua_type(L, -1) == LUA_TSTRING, "P2.char-range-errtype");
    lua_pop(L, 1);

    /* GC survival: collect, then call again through the trampoline */
    lua_gc(L, LUA_GCCOLLECT, 0);
    push_utf8(L, "len");
    lua_pushliteral(L, "hello");
    lua_call(L, 1, 1);
    check(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 5,
          "P2.after-gc-call");
    lua_pop(L, 1);

    lua_close(L);
}

/* ---------------- part 3: normalized internal lanes (Lua side) ---------------- */

static void part_lua_lanes(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    dostr(L,
        "local u = utf8\n"
        "print('P3.identity', u.char == u.char, u.char ~= u.len,"
        " rawequal(u.char, u.char))\n"
        "local t = {}; t[u.char] = 7\n"
        "collectgarbage()\n"
        "print('P3.tablekey', t[u.char], next(t) == u.char)\n"
        "local i = debug.getinfo(u.char)\n"
        "print('P3.getinfo', i.what, i.source, i.nups, i.currentline,"
        " i.linedefined)\n"
        "print('P3.tostring-prefix', (tostring(u.char):sub(1, 9)))\n"
        "print('P3.dump', pcall(string.dump, u.char))\n"
        "print('P3.call-thread', (select(1, pcall(coroutine.create(u.len), 1))))\n"
        /* pcall / xpcall funnels (fixed assignments: MULTRET window of
         * len success diverges pre-existing) */
        "local ok, v = pcall(u.len, 'AB')\n"
        "print('P3.pcall', ok, v)\n"
        "local ok2, v2 = xpcall(u.codepoint, debug.traceback, 'AB', 1, 2)\n"
        "print('P3.xpcall', ok2, v2)\n"
        "local ok3 = pcall(u.char, -1)\n"
        "print('P3.pcall-err-status', ok3, type(select(2, pcall(u.char, -1))))\n"
        /* gsub replacement-function funnel */
        "print('P3.gsub', ('hello'):gsub('l+', u.len))\n"
        /* tforcall funnel */
        "local acc = {}\n"
        "for p, c in u.codes('AB') do acc[#acc+1] = p .. ':' .. c end\n"
        "print('P3.tforcall', table.concat(acc, ','))\n"
        /* __pairs funnel */
        "local pt = setmetatable({x = 'AB'},"
        " {__pairs = function(tt) return u.codes(tt.x) end})\n"
        "local acc2 = {}\n"
        "for p, c in pairs(pt) do acc2[#acc2+1] = p .. ':' .. c end\n"
        "print('P3.pairs', table.concat(acc2, ','))\n"
        /* tailcall funnel */
        "local function tf() return u.offset('AB', 2) end\n"
        "print('P3.tailcall', tf())\n"
        /* metamethod funnels: table-arg calls fail (status/type only) */
        "print('P3.index-status', (select(1, pcall(function()"
        " return setmetatable({}, {__index = u.len})[1] end))))\n"
        "print('P3.newindex-status', (select(1, pcall(function()"
        " setmetatable({}, {__newindex = u.len})[1] = 5 end))))\n"
        "print('P3.add-status', (select(1, pcall(function()"
        " return setmetatable({}, {__add = u.char}) + 1 end))))\n"
        "print('P3.concat-status', (select(1, pcall(function()"
        " return setmetatable({}, {__concat = u.char}) .. 'x' end))))\n"
        /* generic (non-table) __index success via the number metatable */
        "debug.setmetatable(1, {__index = u.char})\n"
        "print('P3.index-generic', pcall(function() return (1)[65] end))\n"
        "debug.setmetatable(1, nil)\n"
        /* sort comparator funnel: no utf8 function is a valid 2-arg
         * comparator; both engines fail (status only) */
        "print('P3.sort-status', (select(1, pcall(table.sort,"
        " {'aaa', 'a', 'aa'}, u.len))))\n"
        /* coroutine lanes: resume VLCF body through the trampoline */
        "print('P3.resume-cp', coroutine.resume("
        "coroutine.create(u.codepoint), 'AB', 1, 2))\n"
        "print('P3.resume-char', coroutine.resume("
        "coroutine.create(u.char), 65))\n"
        "local co = coroutine.create(u.char)\n"
        "coroutine.resume(co)\n"
        "print('P3.coro-dead', coroutine.status(co))\n"
        "local co2 = coroutine.create(u.len)\n"
        "print('P3.resume-err-status',"
        " (select(1, coroutine.resume(co2, 'AB', 99))))\n"
        "print('P3.wrap-type', type(coroutine.wrap(u.char)))\n"
        "print('P3.wrap-err-status', (select(1, pcall("
        "coroutine.wrap(u.len), 'AB', 99))))\n",
        "P3");

    lua_close(L);
}

/* ---------------- part 4: second-state publication ---------------- */

static void part_second_state(void) {
    lua_State *L1 = luaL_newstate();
    luaL_openlibs(L1);
    push_utf8(L1, "char");
    {
        lua_CFunction ptr1 = lua_tocfunction(L1, -1);
        check(ptr1 != NULL, "P4.ptr1");

        lua_State *L2 = luaL_newstate();
        luaL_openlibs(L2);
        push_utf8(L2, "char");
        push_utf8(L2, "char");
        check(lua_rawequal(L2, -1, -2), "P4.rawequal-second-state");
        /* the static C ABI pointer is state-independent */
        check(lua_tocfunction(L2, -1) == ptr1, "P4.ptr-state-independent");
        lua_pushinteger(L2, 67);
        lua_pcall(L2, 1, 1, 0);
        check(lua_isstring(L2, -1) && *lua_tostring(L2, -1) == 'C',
              "P4.call-second-state");
        lua_pop(L2, 2);
        lua_close(L2);

        /* the first state is unaffected */
        lua_pushinteger(L1, 68);
        lua_pcall(L1, 1, 1, 0);
        check(lua_isstring(L1, -1) && *lua_tostring(L1, -1) == 'D',
              "P4.call-first-state");
        lua_pop(L1, 1);

        /* republish through luaopen_utf8 (C lane): the published values
         * are rawequal to the originals — PUC builds a fresh table with
         * the same static C functions, luazig returns the global table;
         * both hold the identical light values */
        luaL_requiref(L1, "utf8", luaopen_utf8, 0);   /* [m] */
        push_utf8(L1, "char");                        /* [m, charG] */
        lua_getfield(L1, -2, "char");                 /* [m, charG, char2] */
        check(lua_rawequal(L1, -1, -2), "P4.republish-rawequal");
        lua_pop(L1, 3);
    }
    lua_close(L1);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    part_identity();
    part_trampoline();
    part_lua_lanes();
    part_second_state();
    printf("UTF8_LIGHT: %d failures\n", fails);
    return fails ? 1 : 0;
}
