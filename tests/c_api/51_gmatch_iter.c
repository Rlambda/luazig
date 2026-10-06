/* 51_gmatch_iter: string.gmatch's iterator as a per-call CClosure(3)
 * over a GMatchState userdata payload (PUC lstrlib.c gmatch/gmatch_aux).
 *
 * Differential suite (zig vs PUC, byte-exact): the iterator's public
 * C-API contract (function type, iscfunction, tocfunction non-null and
 * the SAME symbol for every iterator, 3 upvalues: subject string /
 * pattern string / state userdata, no 4th upvalue, distinct GC-stable
 * upvalueids), per-iterator statefulness (interleaved C calls, a saved
 * iterator across a second iterator + full GC), exact result counts via
 * LUA_MULTRET (capture count, whole match, 0 on exhaustion, 0 on
 * out-of-range init), the caret-literal / dollar-end / empty-match /
 * position-capture semantics, lua_setupvalue on upvalue 1 (iteration
 * unaffected — the state lives in the userdata), calls on a coroutine
 * handle, and the construction OOM matrix (countdown allocator: every
 * trial either succeeds with a usable iterator or fails LUA_ERRMEM with
 * a string object, survives a real GC, and the retry succeeds; the
 * per-runtime k-matrix is not a parity contract, so both outcomes print
 * the same normalized verdict).
 *
 * The UB lane (lua_setupvalue of a non-userdata into upvalue 3) is PUC
 * UB (NULL deref -> crash) and is deliberately not reproduced; the zig
 * runtime keeps that failure a catchable error (asserted by class in
 * the zig unit battery). */
#include <stdio.h>
#include <stdlib.h>
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

/* ---- countdown allocator for the construction-OOM matrix ---- */
static int countdown = -1;   /* -1: never fail; k: fail the k-th allocation */
static int frozen = 0;       /* once the k-th allocation fails, keep failing
                              * (defeats the emergency-GC retry) until cleared */
static void *falloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    (void)ud; (void)osize;
    if (nsize == 0) { free(ptr); return NULL; }
    if (frozen) return NULL;
    if (countdown > 0) {
        countdown--;
        if (countdown == 0) { frozen = 1; return NULL; }
    }
    if (ptr) return realloc(ptr, nsize);
    return malloc(nsize);
}

/* The iterator's C-API surface: type, iscfunction, tocfunction, the
 * upvalue list (name/type/value), and where the list ends. */
static void iter_contract(lua_State *L, const char *tag) {
    printf("%s: type=%s iscfunction=%d\n", tag,
           luaL_typename(L, -1), lua_iscfunction(L, -1));
    lua_CFunction f = lua_tocfunction(L, -1);
    printf("%s: tocfunction %s\n", tag, f ? "non-null" : "null");
    for (int i = 1; i <= 4; i++) {
        const char *name = lua_getupvalue(L, -1, i);
        if (name == NULL) { printf("%s: upvalue[%d] none\n", tag, i); break; }
        printf("%s: upvalue[%d] name='%s' type=%s val=%s\n", tag, i, name,
               luaL_typename(L, -1),
               lua_tostring(L, -1) ? lua_tostring(L, -1) : "(non-string)");
        lua_pop(L, 1);  /* remove the upvalue value */
    }
}

/* Call the function at idx with 0 args, LUA_MULTRET; print `label`, the
 * exact result count, and every result; leave the stack as it was. */
static void call_show(lua_State *L, int idx, const char *label) {
    lua_pushvalue(L, idx);
    int base = lua_gettop(L);
    if (lua_pcall(L, 0, LUA_MULTRET, 0) != LUA_OK) {
        printf("%s: call-error %s\n", label, lua_tostring(L, -1));
        fails++;
        lua_pop(L, 1);
        return;
    }
    int n = lua_gettop(L) - base + 1;
    printf("%s: n=%d", label, n);
    for (int i = 0; i < n; i++) {
        const char *s = lua_tostring(L, base - 1 + 1 + i);
        printf(" %s", s ? s : "(non-string)");
    }
    printf("\n");
    lua_pop(L, n);
}

int main(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* --- P1: the producer is a plain C function (0 upvalues) --- */
    lua_getglobal(L, "string");
    lua_getfield(L, -1, "gmatch");
    printf("P1.producer: type=%s iscfunction=%d\n",
           luaL_typename(L, -1), lua_iscfunction(L, -1));
    check(lua_getupvalue(L, -1, 1) == NULL, "P1.producer.up1.none");
    lua_pop(L, 2);

    /* --- P2: iterator contract, identity, GC-stable upvalueids --- */
    if (luaL_dostring(L, "return string.gmatch('a1b2', '%a%d')")) {
        printf("P2: dostring error: %s\n", lua_tostring(L, -1));
        return 1;
    }
    iter_contract(L, "P2.it1");
    lua_CFunction f1 = lua_tocfunction(L, -1);
    const void *id1 = lua_upvalueid(L, -1, 1);
    const void *id3 = lua_upvalueid(L, -1, 3);
    int it1 = lua_gettop(L);

    if (luaL_dostring(L, "return string.gmatch('x9y8', '%a%d')")) return 1;
    iter_contract(L, "P2.it2");
    lua_CFunction f2 = lua_tocfunction(L, -1);
    const void *id1b = lua_upvalueid(L, -1, 1);
    const void *id3b = lua_upvalueid(L, -1, 3);
    int it2 = lua_gettop(L);

    check(f1 != NULL && f2 != NULL && f1 == f2, "P2.same.cfunction");
    check(id1 != NULL && id1b != NULL && id1 != id1b, "P2.uvid1.distinct");
    check(id3 != NULL && id3b != NULL && id3 != id3b, "P2.uvid3.distinct");
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    check(lua_upvalueid(L, it1, 1) == id1, "P2.uvid1.gc.stable");
    check(lua_upvalueid(L, it1, 3) == id3, "P2.uvid3.gc.stable");
    check(lua_upvalueid(L, it2, 1) == id1b, "P2.uvid1b.gc.stable");

    /* --- P3: interleaved C calls (decisive per-iterator state) --- */
    call_show(L, it1, "P3.r0.it1");
    call_show(L, it2, "P3.r0.it2");
    call_show(L, it1, "P3.r1.it1");
    call_show(L, it2, "P3.r1.it2");
    call_show(L, it1, "P3.exhausted.it1");
    call_show(L, it2, "P3.exhausted.it2");
    lua_pop(L, 2);

    /* --- P4: exact result counts (LUA_MULTRET) --- */
    if (luaL_dostring(L, "return string.gmatch('key=val', '(%a+)=(%a+)')")) return 1;
    call_show(L, -1, "P4.captures.1");
    call_show(L, -1, "P4.captures.exhausted");
    lua_pop(L, 1);

    if (luaL_dostring(L, "return string.gmatch('abc', '%a')")) return 1;
    call_show(L, -1, "P4.whole.1");
    call_show(L, -1, "P4.whole.2");
    call_show(L, -1, "P4.whole.3");
    call_show(L, -1, "P4.whole.4");
    lua_pop(L, 1);

    if (luaL_dostring(L, "return string.gmatch('abcdef', '%a', 3)")) return 1;
    call_show(L, -1, "P4.init3.1");
    call_show(L, -1, "P4.init3.2");
    lua_pop(L, 1);

    if (luaL_dostring(L, "return string.gmatch('abcdef', '%a', -2)")) return 1;
    call_show(L, -1, "P4.initneg2.1");
    call_show(L, -1, "P4.initneg2.2");
    lua_pop(L, 1);

    if (luaL_dostring(L, "return string.gmatch('abcdef', '%a', 100)")) return 1;
    call_show(L, -1, "P4.init100.1");
    call_show(L, -1, "P4.init100.2");
    lua_pop(L, 1);

    if (luaL_dostring(L, "return string.gmatch('a b  c', '()(%a+)()')")) return 1;
    call_show(L, -1, "P4.poscaps.1");
    call_show(L, -1, "P4.poscaps.2");
    lua_pop(L, 1);

    if (luaL_dostring(L, "return string.gmatch('abc', 'b*')")) return 1;
    call_show(L, -1, "P4.empty.1");
    call_show(L, -1, "P4.empty.2");
    call_show(L, -1, "P4.empty.3");
    call_show(L, -1, "P4.empty.4");
    lua_pop(L, 1);

    if (luaL_dostring(L, "return string.gmatch('', 'x*')")) return 1;
    call_show(L, -1, "P4.emptysubject.1");
    call_show(L, -1, "P4.emptysubject.2");
    lua_pop(L, 1);

    /* --- P5: caret is a literal in gmatch; dollar anchors the end --- */
    if (luaL_dostring(L, "return string.gmatch('a^b', '^%a')")) return 1;
    call_show(L, -1, "P5.caretliteral.1");
    call_show(L, -1, "P5.caretliteral.2");
    lua_pop(L, 1);

    if (luaL_dostring(L, "return string.gmatch('abc', '^%a')")) return 1;
    call_show(L, -1, "P5.caretnomatch.1");
    lua_pop(L, 1);

    if (luaL_dostring(L, "return string.gmatch('ab', 'a$')")) return 1;
    call_show(L, -1, "P5.dollarnomatch.1");
    lua_pop(L, 1);

    if (luaL_dostring(L, "return string.gmatch('ab', 'b$')")) return 1;
    call_show(L, -1, "P5.dollarmatch.1");
    call_show(L, -1, "P5.dollarmatch.2");
    lua_pop(L, 1);

    /* --- P6: setupvalue on upvalue 1 does not touch the cursor --- */
    if (luaL_dostring(L, "return string.gmatch('aaa', 'a')")) return 1;
    int sw = lua_gettop(L);
    lua_pushliteral(L, "zzz");
    check(lua_setupvalue(L, sw, 1) != NULL, "P6.setupvalue.u1.ok");
    /* lua_setupvalue already popped the value; the iterator stays at sw */
    call_show(L, sw, "P6.after.1");
    call_show(L, sw, "P6.after.2");
    call_show(L, sw, "P6.after.3");
    call_show(L, sw, "P6.after.4");
    /* the swapped-in value is readable back through getupvalue */
    lua_getupvalue(L, sw, 1);
    check(lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "zzz") == 0,
          "P6.u1.swapped.readback");
    lua_pop(L, 1);
    lua_pop(L, 1);

    /* --- P7: a saved iterator survives a second iterator + full GC --- */
    if (luaL_dostring(L, "return string.gmatch('hello world', '%a+')")) return 1;
    int hw = lua_gettop(L);
    call_show(L, hw, "P7.first");
    if (luaL_dostring(L, "return string.gmatch('other string', '%a+')")) return 1;
    call_show(L, -1, "P7.second.first");
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    call_show(L, -1, "P7.second.exhausted");
    lua_pop(L, 1);
    call_show(L, hw, "P7.saved.after.gc");
    lua_pop(L, 1);

    /* --- P8: the iterator on a coroutine handle + Lua re-entry --- */
    lua_State *co = lua_newthread(L);
    if (luaL_dostring(co, "return string.gmatch('p1q2', '%a%d')")) return 1;
    call_show(co, -1, "P8.coro.1");
    call_show(co, -1, "P8.coro.2");
    call_show(co, -1, "P8.coro.3");
    check(lua_upvalueid(co, -1, 1) != NULL, "P8.coro.uvid.visible");
    lua_pop(co, 1);

    if (luaL_dostring(L,
        "local co = coroutine.wrap(function()"
        "  local g = string.gmatch('p1q2', '%a%d')"
        "  coroutine.yield(g())"
        "  coroutine.yield(g())"
        "  return select('#', g()), (g())"
        "end)"
        "local a, b = co()"
        "local c, d = co()"
        "local e, f = co()"
        "print('P8.reentry:', a, b, c, d, e, f)")) {
        printf("P8.reentry: dostring error: %s\n", lua_tostring(L, -1));
        return 1;
    }

    /* --- P9: construction OOM matrix (normalized verdicts) --- */
    for (int k = 1; k <= 16; k++) {
        lua_State *Lk = lua_newstate(falloc, NULL, 0);
        if (!Lk) { printf("P9.k=%d: newstate-failed\n", k); fails++; continue; }
        luaL_openlibs(Lk);
        /* Load the producer-call chunk BEFORE arming: the loader's
         * allocations are not construction edges. */
        if (luaL_loadstring(Lk, "return string.gmatch('a1b2c3', '%a%d')")) {
            printf("P9.k=%d: load-failed\n", k);
            fails++;
            lua_close(Lk);
            continue;
        }
        countdown = k; frozen = 0;
        int st = lua_pcall(Lk, 0, 1, 0);
        countdown = -1; frozen = 0;
        const char *verdict = "clean";
        if (st == LUA_OK) {
            /* the freeze never hit a fallible step: the iterator works */
            lua_pushvalue(Lk, -1);
            if (lua_pcall(Lk, 0, 1, 0) != LUA_OK ||
                !lua_isstring(Lk, -1) || strcmp(lua_tostring(Lk, -1), "a1") != 0)
                verdict = "VIOLATION(unusable)";
            else
                lua_pop(Lk, 1);
            lua_pop(Lk, 1);
        } else if (st == LUA_ERRMEM) {
            if (lua_type(Lk, -1) != LUA_TSTRING) verdict = "VIOLATION(errtype)";
            lua_pop(Lk, 1);
            /* recovery: the failed state must survive a real GC cycle */
            lua_gc(Lk, LUA_GCCOLLECT, 0);
            /* VM reuse: the retry must succeed and produce a usable
             * iterator (no dangling cell/closure/userdata from the
             * rolled-back construction) */
            luaL_loadstring(Lk, "return string.gmatch('a1b2c3', '%a%d')");
            if (lua_pcall(Lk, 0, 1, 0) != LUA_OK) {
                verdict = "VIOLATION(retry)";
                lua_pop(Lk, 1);
            } else {
                lua_pushvalue(Lk, -1);
                if (lua_pcall(Lk, 0, 1, 0) != LUA_OK ||
                    !lua_isstring(Lk, -1) || strcmp(lua_tostring(Lk, -1), "a1") != 0)
                    verdict = "VIOLATION(retry-unusable)";
                else
                    lua_pop(Lk, 1);
                lua_pop(Lk, 1);
            }
        } else {
            verdict = "VIOLATION(status)";
            lua_pop(Lk, 1);
        }
        printf("P9.k=%d: %s\n", k, verdict);
        if (verdict[0] == 'V') fails++;
        lua_close(Lk);
    }
    /* control: no countdown -> a usable iterator */
    {
        lua_State *Lc = lua_newstate(falloc, NULL, 0);
        luaL_openlibs(Lc);
        luaL_loadstring(Lc, "return string.gmatch('a1b2c3', '%a%d')");
        int st = lua_pcall(Lc, 0, 1, 0);
        printf("P9.control: st=%d\n", st);
        if (st == LUA_OK) {
            lua_pushvalue(Lc, -1);
            if (lua_pcall(Lc, 0, 1, 0) != LUA_OK ||
                !lua_isstring(Lc, -1) || strcmp(lua_tostring(Lc, -1), "a1") != 0) {
                printf("P9.control: VIOLATION(unusable)\n");
                fails++;
            } else {
                printf("P9.control: first=a1\n");
                lua_pop(Lc, 1);
            }
            lua_pop(Lc, 1);
        } else {
            fails++;
            lua_pop(Lc, 1);
        }
        lua_close(Lc);
    }

    printf("fails:%d\n", fails);
    lua_close(L);
    return fails ? 1 : 0;
}
