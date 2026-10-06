/* 52_io_lines_iter: io.lines/file:lines iterators as per-call CClosures
 * with upvalues [file, n, toclose, formats...] (PUC 5.5 liolib.c
 * aux_lines/io_readline: the iterator is a C closure over the file handle,
 * the remaining-format counter and the toclose flag; at most
 * LR_MAXFORMATS=200... 250 here per the zig window) formats).
 *
 * Differential suite (zig vs PUC, byte-exact): the producer contract
 * (io.lines is a plain C function with no upvalues), the by-name
 * construction's exact 4 results [iterator, nil, nil, file] (the 4th is
 * the generic-for to-be-closed value) vs the default-input form's 1, the
 * iterator's C-API contract (iscfunction, tocfunction non-null and the
 * SAME symbol for every iterator, the upvalue list and where it ends,
 * GC-stable upvalueids), per-iterator statefulness (interleaved C calls,
 * exhaustion with 0 results and the auto-close that follows — the next
 * call is the "file is already closed" error with NO position prefix, the
 * luaL_where(1) rule: the immediate caller here is a C function), exact
 * result counts per format ('l' + 'n' interplay: a failed number read
 * unreads its look-ahead, so the line survives for the next call; pure
 * number files; 0 on exhaustion), the 252-format "too many arguments"
 * argerror for both io.lines and file:lines ('?' — the method name is not
 * resolvable), the FILE*-handle argerror, the number-coerced open
 * failure, lua_setupvalue on upvalue 1 (swapping the file handle changes
 * what the iterator reads), and the construction OOM matrix (countdown
 * allocator: every trial either succeeds with a usable iterator or fails
 * LUA_ERRMEM with a string object, survives a real GC, and the retry
 * succeeds; the per-runtime k-matrix is not a parity contract, so both
 * outcomes print the same normalized verdict). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static const char *PATH = "/tmp/luazig_c52_lines.txt";
static const char *NUMS = "/tmp/luazig_c52_nums.txt";

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
 * upvalue list (name/type), and where the list ends. */
static void iter_contract(lua_State *L, const char *tag) {
    printf("%s: type=%s iscfunction=%d\n", tag,
           luaL_typename(L, -1), lua_iscfunction(L, -1));
    lua_CFunction f = lua_tocfunction(L, -1);
    printf("%s: tocfunction %s\n", tag, f ? "non-null" : "null");
    for (int i = 1; i <= 6; i++) {
        const char *name = lua_getupvalue(L, -1, i);
        if (name == NULL) { printf("%s: upvalue[%d] none\n", tag, i); break; }
        printf("%s: upvalue[%d] name='%s' type=%s\n", tag, i, name,
               luaL_typename(L, -1));
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
        lua_pop(L, 1);
        return;
    }
    int n = lua_gettop(L) - base + 1;
    printf("%s: n=%d", label, n);
    for (int i = 0; i < n; i++) {
        const char *s = lua_tostring(L, base + i);
        printf(" [%s/%s]", luaL_typename(L, base + i), s ? s : "(non-string)");
    }
    printf("\n");
    lua_pop(L, n);
}

int main(void) {
    FILE *f = fopen(PATH, "w");
    fputs("B1 42\nB2 84\n", f);
    fclose(f);
    f = fopen(NUMS, "w");
    fputs("10\n20\n", f);
    fclose(f);

    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* --- P1: the producer is a plain C function (0 upvalues) --- */
    lua_getglobal(L, "io");
    lua_getfield(L, -1, "lines");
    printf("P1.producer: type=%s iscfunction=%d\n",
           luaL_typename(L, -1), lua_iscfunction(L, -1));
    check(lua_getupvalue(L, -1, 1) == NULL, "P1.producer.up1.none");
    lua_pop(L, 2);

    /* --- P2: by-name construction: exactly 4 results [it, nil, nil,
     * file]; default-input form: exactly 1 (never called) --- */
    char chunk[128];
    snprintf(chunk, sizeof(chunk), "return io.lines('%s', 'l', 'n')", PATH);
    if (luaL_dostring(L, chunk)) {
        printf("P2: dostring error: %s\n", lua_tostring(L, -1));
        return 1;
    }
    printf("P2.results: n=%d\n", lua_gettop(L));
    for (int i = 1; i <= lua_gettop(L); i++)
        printf("P2.r[%d]: type=%s\n", i, luaL_typename(L, i));
    lua_pop(L, 3);  /* keep the iterator (the by-name 4th is the toclose fh) */
    iter_contract(L, "P2.it1");
    lua_CFunction f1 = lua_tocfunction(L, -1);
    const void *id1 = lua_upvalueid(L, -1, 1);
    int it = lua_gettop(L);

    snprintf(chunk, sizeof(chunk), "return io.lines('%s')", PATH);
    if (luaL_dostring(L, chunk)) return 1;
    lua_pop(L, 3);
    iter_contract(L, "P2.it2");
    lua_CFunction f2 = lua_tocfunction(L, -1);
    const void *id1b = lua_upvalueid(L, -1, 1);
    int it2 = lua_gettop(L);
    check(f1 != NULL && f2 != NULL && f1 == f2, "P2.same.cfunction");
    check(id1 != NULL && id1b != NULL && id1 != id1b, "P2.uvid1.distinct");

    if (luaL_dostring(L, "return io.lines()")) return 1;
    printf("P2.default-input: n=%d type=%s\n", lua_gettop(L),
           luaL_typename(L, -1));
    lua_pop(L, 1);

    /* --- P3: interleaved C calls; exhaustion (0 results) auto-closes;
     * the post-exhaustion call is the closed-file error (no position:
     * the immediate caller is a C function) --- */
    call_show(L, it, "P3.it1.c1");
    call_show(L, it2, "P3.it2.c1");
    call_show(L, it, "P3.it1.c2");
    call_show(L, it2, "P3.it2.c2");
    call_show(L, it, "P3.it1.eof");
    call_show(L, it, "P3.it1.closed");
    call_show(L, it2, "P3.it2.eof");
    call_show(L, it2, "P3.it2.closed");
    lua_pop(L, 2);

    /* --- P4: exact result counts per format --- */
    /* 'l' + 'n': a failed number read unreads its look-ahead, so the
     * line survives for the next call (PUC read_number state machine) */
    if (luaL_dostring(L, "return io.lines('/tmp/luazig_c52_lines.txt', 'l', 'n')")) return 1;
    lua_pop(L, 3);
    call_show(L, -1, "P4.ln.c1");
    call_show(L, -1, "P4.ln.c2");
    call_show(L, -1, "P4.ln.eof");
    lua_pop(L, 1);

    /* pure number file through 'n' */
    snprintf(chunk, sizeof(chunk), "return io.lines('%s', 'n')", NUMS);
    if (luaL_dostring(L, chunk)) return 1;
    lua_pop(L, 3);
    call_show(L, -1, "P4.n.c1");
    call_show(L, -1, "P4.n.c2");
    call_show(L, -1, "P4.n.eof");
    lua_pop(L, 1);

    /* --- P5: a saved iterator survives a full GC mid-iteration --- */
    snprintf(chunk, sizeof(chunk), "return io.lines('%s')", PATH);
    if (luaL_dostring(L, chunk)) return 1;
    lua_pop(L, 3);
    int sv = lua_gettop(L);
    call_show(L, sv, "P5.first");
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    call_show(L, sv, "P5.after.gc");
    call_show(L, sv, "P5.eof");
    check(lua_upvalueid(L, sv, 1) != NULL, "P5.uvid.visible");
    lua_pop(L, 1);

    /* --- P6: 252 formats -> "too many arguments" (io.lines) --- */
    lua_getglobal(L, "io");
    lua_getfield(L, -1, "lines");
    lua_remove(L, -2);
    if (!lua_checkstack(L, 300)) { printf("P6: checkstack failed\n"); return 1; }
    lua_pushstring(L, PATH);
    for (int i = 0; i < 251; i++) lua_pushliteral(L, "l");
    int st = lua_pcall(L, 252, 0, 0);
    printf("P6.toomany: st=%d err=%s\n", st, st ? lua_tostring(L, -1) : "-");
    if (st) lua_pop(L, 1);

    /* --- P7: io.lines(FILE*) -> the handle argerror --- */
    lua_getglobal(L, "io");
    lua_getfield(L, -1, "lines");
    lua_remove(L, -2);
    lua_getglobal(L, "io");
    lua_getfield(L, -1, "stdout");
    lua_remove(L, -2);
    st = lua_pcall(L, 1, 0, 0);
    printf("P7.fh-arg: st=%d err=%s\n", st, st ? lua_tostring(L, -1) : "-");
    if (st) lua_pop(L, 1);

    /* --- P8: io.lines(42) coerces the name; the open failure has NO
     * position prefix (pcall, a C function, is the immediate caller) --- */
    if (luaL_dostring(L, "return pcall(io.lines, 42)")) return 1;
    printf("P8.num-arg: %s %s\n", lua_typename(L, lua_type(L, -2)),
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "(non-string)");
    lua_pop(L, 2);

    /* --- P9: file:lines with 252 formats -> '?' (method name
     * unresolvable through the C boundary) --- */
    snprintf(chunk, sizeof(chunk), "return io.open('%s')", PATH);
    if (luaL_dostring(L, chunk)) return 1;
    lua_getfield(L, -1, "lines");
    if (!lua_checkstack(L, 300)) { printf("P9: checkstack failed\n"); return 1; }
    lua_pushvalue(L, -2);
    for (int i = 0; i < 251; i++) lua_pushliteral(L, "l");
    st = lua_pcall(L, 252, 0, 0);
    printf("P9.f-toomany: st=%d err=%s\n", st, st ? lua_tostring(L, -1) : "-");
    if (st) lua_pop(L, 1);
    lua_pop(L, 1);

    /* --- P10: setupvalue on upvalue 1 swaps the file handle --- */
    if (luaL_dostring(L, chunk)) return 1;
    int fh = lua_gettop(L);
    printf("P10.fh: type=%s\n", luaL_typename(L, fh));
    snprintf(chunk, sizeof(chunk), "return io.lines('%s')", PATH);
    if (luaL_dostring(L, chunk)) return 1;
    lua_pop(L, 3);
    int sw = lua_gettop(L);
    call_show(L, sw, "P10.before");
    lua_pushvalue(L, fh);
    const char *swname = lua_setupvalue(L, sw, 1);
    printf("P10.setupvalue.u1: %s\n", swname ? swname : "NULL");
    call_show(L, sw, "P10.after.swap");
    lua_getupvalue(L, sw, 1);
    check(lua_type(L, -1) == LUA_TUSERDATA, "P10.u1.swapped.readback");
    lua_pop(L, 1);
    lua_pop(L, 2);

    /* --- P11: construction OOM matrix (normalized verdicts) --- */
    for (int k = 1; k <= 24; k++) {
        lua_State *Lk = lua_newstate(falloc, NULL, 0);
        if (!Lk) { printf("P11.k=%d: newstate-failed\n", k); fails++; continue; }
        luaL_openlibs(Lk);
        /* Load the producer-call chunk BEFORE arming: the loader's
         * allocations are not construction edges. */
        char ck[128];
        snprintf(ck, sizeof(ck), "return io.lines('%s', 'l')", PATH);
        if (luaL_loadstring(Lk, ck)) {
            printf("P11.k=%d: load-failed\n", k);
            fails++;
            lua_close(Lk);
            continue;
        }
        countdown = k; frozen = 0;
        st = lua_pcall(Lk, 0, 1, 0);
        countdown = -1; frozen = 0;
        const char *verdict = "clean";
        if (st == LUA_OK) {
            /* the freeze never hit a fallible step: the iterator works */
            lua_pushvalue(Lk, -1);
            if (lua_pcall(Lk, 0, 1, 0) != LUA_OK ||
                !lua_isstring(Lk, -1) || strcmp(lua_tostring(Lk, -1), "B1 42") != 0)
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
             * iterator (no dangling handle/closure from the rolled-back
             * construction) */
            luaL_loadstring(Lk, ck);
            if (lua_pcall(Lk, 0, 1, 0) != LUA_OK) {
                verdict = "VIOLATION(retry)";
                lua_pop(Lk, 1);
            } else {
                lua_pushvalue(Lk, -1);
                if (lua_pcall(Lk, 0, 1, 0) != LUA_OK ||
                    !lua_isstring(Lk, -1) || strcmp(lua_tostring(Lk, -1), "B1 42") != 0)
                    verdict = "VIOLATION(retry-unusable)";
                else
                    lua_pop(Lk, 1);
                lua_pop(Lk, 1);
            }
        } else {
            verdict = "VIOLATION(status)";
            lua_pop(Lk, 1);
        }
        printf("P11.k=%d: %s\n", k, verdict);
        if (verdict[0] == 'V') fails++;
        lua_close(Lk);
    }
    /* control: no countdown -> a usable iterator */
    {
        lua_State *Lc = lua_newstate(falloc, NULL, 0);
        luaL_openlibs(Lc);
        char ck[128];
        snprintf(ck, sizeof(ck), "return io.lines('%s', 'l')", PATH);
        luaL_loadstring(Lc, ck);
        st = lua_pcall(Lc, 0, 1, 0);
        printf("P11.control: st=%d\n", st);
        if (st == LUA_OK) {
            lua_pushvalue(Lc, -1);
            if (lua_pcall(Lc, 0, 1, 0) != LUA_OK ||
                !lua_isstring(Lc, -1) || strcmp(lua_tostring(Lc, -1), "B1 42") != 0) {
                printf("P11.control: VIOLATION(unusable)\n");
                fails++;
            } else {
                printf("P11.control: first=B1 42\n");
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
