/*
** 03_arith.c — tests for Phase 3 arithmetic, comparison, concat, len, GC.
**
** Exercises the functions added in Phase 3:
**   lua_arith, lua_rawequal, lua_compare, lua_concat, lua_len, lua_gc,
**   lua_version (already present, verified here).
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

int main(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: luaL_newstate\n"); return 1; }

    /* --- lua_arith: integer addition --- */
    lua_pushinteger(L, 10);
    lua_pushinteger(L, 20);
    lua_arith(L, LUA_OPADD);
    if (lua_tointegerx(L, -1, NULL) != 30) {
        fprintf(stderr, "FAIL: 10+20 = %lld\n", (long long)lua_tointegerx(L, -1, NULL));
        lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_arith: integer subtraction --- */
    lua_pushinteger(L, 50);
    lua_pushinteger(L, 15);
    lua_arith(L, LUA_OPSUB);
    if (lua_tointegerx(L, -1, NULL) != 35) {
        fprintf(stderr, "FAIL: 50-15\n"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_arith: integer multiplication --- */
    lua_pushinteger(L, 6);
    lua_pushinteger(L, 7);
    lua_arith(L, LUA_OPMUL);
    if (lua_tointegerx(L, -1, NULL) != 42) {
        fprintf(stderr, "FAIL: 6*7\n"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_arith: float division --- */
    lua_pushnumber(L, 100.0);
    lua_pushnumber(L, 4.0);
    lua_arith(L, LUA_OPDIV);
    if (lua_tonumberx(L, -1, NULL) != 25.0) {
        fprintf(stderr, "FAIL: 100.0/4.0\n"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_arith: integer division --- */
    lua_pushinteger(L, 17);
    lua_pushinteger(L, 5);
    lua_arith(L, LUA_OPIDIV);
    if (lua_tointegerx(L, -1, NULL) != 3) {
        fprintf(stderr, "FAIL: 17//5\n"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_arith: modulo --- */
    lua_pushinteger(L, 17);
    lua_pushinteger(L, 5);
    lua_arith(L, LUA_OPMOD);
    if (lua_tointegerx(L, -1, NULL) != 2) {
        fprintf(stderr, "FAIL: 17%%5\n"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_arith: unary minus --- */
    lua_pushinteger(L, 42);
    lua_arith(L, LUA_OPUNM);
    if (lua_tointegerx(L, -1, NULL) != -42) {
        fprintf(stderr, "FAIL: -42\n"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_arith: bitwise AND --- */
    lua_pushinteger(L, 0xFF);
    lua_pushinteger(L, 0x0F);
    lua_arith(L, LUA_OPBAND);
    if (lua_tointegerx(L, -1, NULL) != 0x0F) {
        fprintf(stderr, "FAIL: 0xFF & 0x0F\n"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_arith: bitwise OR --- */
    lua_pushinteger(L, 0xF0);
    lua_pushinteger(L, 0x0F);
    lua_arith(L, LUA_OPBOR);
    if (lua_tointegerx(L, -1, NULL) != 0xFF) {
        fprintf(stderr, "FAIL: 0xF0 | 0x0F\n"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_arith: bitwise NOT --- */
    lua_pushinteger(L, 0);
    lua_arith(L, LUA_OPBNOT);
    if (lua_tointegerx(L, -1, NULL) != -1) {
        fprintf(stderr, "FAIL: ~0\n"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_arith: left shift --- */
    lua_pushinteger(L, 1);
    lua_pushinteger(L, 8);
    lua_arith(L, LUA_OPSHL);
    if (lua_tointegerx(L, -1, NULL) != 256) {
        fprintf(stderr, "FAIL: 1 << 8\n"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_arith: right shift --- */
    lua_pushinteger(L, 256);
    lua_pushinteger(L, 4);
    lua_arith(L, LUA_OPSHR);
    if (lua_tointegerx(L, -1, NULL) != 16) {
        fprintf(stderr, "FAIL: 256 >> 4\n"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_arith: power --- */
    lua_pushnumber(L, 2.0);
    lua_pushnumber(L, 10.0);
    lua_arith(L, LUA_OPPOW);
    if (lua_tonumberx(L, -1, NULL) != 1024.0) {
        fprintf(stderr, "FAIL: 2^10\n"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_rawequal: equal integers --- */
    lua_pushinteger(L, 5);
    lua_pushinteger(L, 5);
    if (!lua_rawequal(L, -1, -2)) {
        fprintf(stderr, "FAIL: rawequal(5,5)\n"); lua_close(L); return 1;
    }
    lua_pop(L, 2);

    /* --- lua_rawequal: unequal integers --- */
    lua_pushinteger(L, 5);
    lua_pushinteger(L, 6);
    if (lua_rawequal(L, -1, -2)) {
        fprintf(stderr, "FAIL: rawequal(5,6) should be false\n"); lua_close(L); return 1;
    }
    lua_pop(L, 2);

    /* --- lua_rawequal: equal strings --- */
    lua_pushstring(L, "hello");
    lua_pushstring(L, "hello");
    if (!lua_rawequal(L, -1, -2)) {
        fprintf(stderr, "FAIL: rawequal('hello','hello')\n"); lua_close(L); return 1;
    }
    lua_pop(L, 2);

    /* --- lua_rawequal: nil vs nil --- */
    lua_pushnil(L);
    lua_pushnil(L);
    if (!lua_rawequal(L, -1, -2)) {
        fprintf(stderr, "FAIL: rawequal(nil,nil)\n"); lua_close(L); return 1;
    }
    lua_pop(L, 2);

    /* --- lua_compare: LT --- */
    lua_pushinteger(L, 3);
    lua_pushinteger(L, 7);
    if (!lua_compare(L, -2, -1, LUA_OPLT)) {
        fprintf(stderr, "FAIL: 3 < 7\n"); lua_close(L); return 1;
    }
    lua_pop(L, 2);

    /* --- lua_compare: LE --- */
    lua_pushinteger(L, 5);
    lua_pushinteger(L, 5);
    if (!lua_compare(L, -2, -1, LUA_OPLE)) {
        fprintf(stderr, "FAIL: 5 <= 5\n"); lua_close(L); return 1;
    }
    lua_pop(L, 2);

    /* --- lua_compare: EQ --- */
    lua_pushinteger(L, 42);
    lua_pushinteger(L, 42);
    if (!lua_compare(L, -2, -1, LUA_OPEQ)) {
        fprintf(stderr, "FAIL: 42 == 42\n"); lua_close(L); return 1;
    }
    lua_pop(L, 2);

    /* --- lua_compare: string LT --- */
    lua_pushstring(L, "abc");
    lua_pushstring(L, "abd");
    if (!lua_compare(L, -2, -1, LUA_OPLT)) {
        fprintf(stderr, "FAIL: 'abc' < 'abd'\n"); lua_close(L); return 1;
    }
    lua_pop(L, 2);

    /* --- lua_concat: "a" .. "b" = "ab" --- */
    lua_pushstring(L, "a");
    lua_pushstring(L, "b");
    lua_concat(L, 2);
    size_t len;
    const char *s = lua_tolstring(L, -1, &len);
    if (!s || strcmp(s, "ab") != 0) {
        fprintf(stderr, "FAIL: concat = '%s'\n", s ? s : "(null)"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_concat: number .. string --- */
    lua_pushinteger(L, 42);
    lua_pushstring(L, "x");
    lua_concat(L, 2);
    s = lua_tolstring(L, -1, &len);
    if (!s || strcmp(s, "42x") != 0) {
        fprintf(stderr, "FAIL: concat(42,'x') = '%s'\n", s ? s : "(null)"); lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_len: string length --- */
    lua_pushstring(L, "hello");
    lua_len(L, -1);
    if (lua_tointegerx(L, -1, NULL) != 5) {
        fprintf(stderr, "FAIL: len('hello')\n"); lua_close(L); return 1;
    }
    lua_pop(L, 2);

    /* --- lua_len: table length --- */
    lua_newtable(L);
    lua_pushinteger(L, 10);
    lua_seti(L, -2, 1);
    lua_pushinteger(L, 20);
    lua_seti(L, -2, 2);
    lua_pushinteger(L, 30);
    lua_seti(L, -2, 3);
    lua_len(L, -1);
    if (lua_tointegerx(L, -1, NULL) != 3) {
        fprintf(stderr, "FAIL: len(table) = %lld\n", (long long)lua_tointegerx(L, -1, NULL));
        lua_close(L); return 1;
    }
    lua_pop(L, 2);

    /* --- lua_gc: GCISRUNNING --- */
    int running = lua_gc(L, LUA_GCISRUNNING, 0);
    if (running != 0 && running != 1) {
        fprintf(stderr, "FAIL: GCISRUNNING = %d\n", running); lua_close(L); return 1;
    }

    /* --- lua_gc: stop then check --- */
    lua_gc(L, LUA_GCSTOP, 0);
    if (lua_gc(L, LUA_GCISRUNNING, 0) != 0) {
        fprintf(stderr, "FAIL: GC should be stopped\n"); lua_close(L); return 1;
    }

    /* --- lua_gc: restart then check --- */
    lua_gc(L, LUA_GCRESTART, 0);
    if (lua_gc(L, LUA_GCISRUNNING, 0) != 1) {
        fprintf(stderr, "FAIL: GC should be running\n"); lua_close(L); return 1;
    }

    /* --- lua_gc: GCCOUNT returns non-negative --- */
    int kb = lua_gc(L, LUA_GCCOUNT, 0);
    if (kb < 0) {
        fprintf(stderr, "FAIL: GCCOUNT = %d\n", kb); lua_close(L); return 1;
    }

    /* --- lua_gc: GCCOLLECT --- */
    lua_gc(L, LUA_GCCOLLECT, 0);

    /* --- lua_version --- */
    lua_Number ver = lua_version(L);
    if ((int)ver != 505) {
        fprintf(stderr, "FAIL: version = %g\n", ver); lua_close(L); return 1;
    }

    /* --- lua_status on main thread --- */
    if (lua_status(L) != LUA_OK) {
        fprintf(stderr, "FAIL: status = %d\n", lua_status(L)); lua_close(L); return 1;
    }

    /* --- lua_pushthread --- */
    int is_main = lua_pushthread(L);
    if (is_main != 1) {
        fprintf(stderr, "FAIL: pushthread returned %d (expected 1 for main)\n", is_main);
        lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* Verify stack is empty */
    if (lua_gettop(L) != 0) {
        fprintf(stderr, "FAIL: stack not empty: %d\n", lua_gettop(L));
        lua_close(L); return 1;
    }

    lua_close(L);
    printf("PASS: 03_arith\n");
    return 0;
}
