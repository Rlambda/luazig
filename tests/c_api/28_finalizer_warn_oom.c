/* 28_finalizer_warn_oom — finalizer warning under exhausted memory.
**
** Semantic class (PUC lgc.c GCTM + lstate.c luaE_warnerror): when a __gc
** body raises ANY error, the VM emits the warning "error in __gc (<msg>)"
** as FIVE tocont pieces straight to the warning channel and CONTINUES with
** the rest of the pending finalizers. PUC runs this path with zero core
** allocations (luaE_warnerror passes the pieces without formatting; the
** message is a literal or the error object's own C string), so a finalizer
** that exhausted memory still produces its warning with the ORIGINAL error
** object, and the queue keeps draining.
**
** The allocator is frozen from INSIDE the __gc body (after everything the
** body needs has been pushed/created), so every allocation between "body
** raised" and "warning delivered" is exactly the error-transport/warning
** path under test. The warnf callback is non-allocating and unfreezes the
** allocator on the closing piece (tocont==0), so the frozen window covers
** precisely one warning emission; the rest of the queue and the state
** close run unfrozen.
**
** Every case is differential: PUC 5.5 and luazig must print byte-identical
** lines (warning text, piece counts, queue continuation, post-GC protected
** action, and — for the pure C-path cases — the count of allocations the
** frozen allocator denied).
**
** Determinism: fixed labels/values only; warning pieces are copied into
** preallocated buffers by the non-allocating callback.
*/
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int frozen = 0;
static int freeze_hits = 0;

static void *lalloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    (void)ud;
    (void)osize;
    if (nsize == 0) { free(ptr); return NULL; }
    if (frozen) { freeze_hits++; return NULL; }
    return realloc(ptr, nsize);
}

/* Non-allocating warning capture: pieces + tocont flags. The closing piece
** (tocont==0) ends the frozen window. */
static char warn_buf[1024];
static int  warn_calls;
static int  warn_ends;
static int  first_warn_frozen = -1;

static void warnf(void *ud, const char *msg, int tocont) {
    (void)ud;
    if (warn_calls == 0) first_warn_frozen = frozen;
    warn_calls++;
    if (!tocont) { warn_ends++; frozen = 0; }
    size_t used = strlen(warn_buf);
    size_t avail = sizeof(warn_buf) - used - 1;
    strncat(warn_buf, msg, avail);
}

static void warn_reset(void) {
    warn_buf[0] = '\0';
    warn_calls = 0;
    warn_ends = 0;
}

/* Finalizer bodies. Every value they hand to lua_error is pushed/created
** BEFORE the freeze: the frozen window must contain only the raise and the
** warning emission, never the body's own construction work. */
static int closes = 0;
static int goods = 0;
static int err_type = -1;
static char err_text[64];

static int fin_boom(lua_State *L) {
    closes++;
    lua_pushstring(L, "boom");
    frozen = 1;
    err_type = lua_type(L, -1);
    snprintf(err_text, sizeof(err_text), "%s", lua_tostring(L, -1));
    return lua_error(L);
}

/* Real OOM inside the body: the userdata allocation itself is denied. */
static int fin_alloc(lua_State *L) {
    closes++;
    if (closes == 1) {
        frozen = 1;
        lua_newuserdatauv(L, 1u << 20, 0);  /* denied -> LUA_ERRMEM */
        return 0;  /* unreachable */
    }
    goods++;
    return 0;
}

/* Non-string error object: the table is created before the freeze. */
static int fin_table(lua_State *L) {
    closes++;
    lua_newtable(L);
    frozen = 1;
    return lua_error(L);
}

static char long_buf[301];  /* 300 'x' + NUL, filled in main */

static int fin_long(lua_State *L) {
    closes++;
    lua_pushlstring(L, long_buf, 300);
    frozen = 1;
    return lua_error(L);
}

static int fin_nul(lua_State *L) {
    closes++;
    lua_pushlstring(L, "a\0b", 3);
    frozen = 1;
    return lua_error(L);
}

/* External string error object: fixed (static, no dealloc) content that
** satisfies the lua_pushexternalstring NUL-at-s[len] contract. */
static char ext_buf[] = "ext-boom";

static int fin_ext(lua_State *L) {
    closes++;
    lua_pushexternalstring(L, ext_buf, strlen(ext_buf), NULL, NULL);
    frozen = 1;
    return lua_error(L);
}

static int ok_fn(lua_State *L) {
    lua_pushstring(L, "ok");
    return 1;
}

/* Post-unfreeze protected action: proves the transient error state was
** cleared and the state is usable again. */
static const char *protected_action(lua_State *L) {
    lua_pushcfunction(L, ok_fn);
    if (lua_pcall(L, 0, 1, 0) != LUA_OK) return "(pcall failed)";
    const char *r = lua_tostring(L, -1);
    lua_pop(L, 1);
    return r ? r : "(no result)";
}

static void reset_case(void) {
    frozen = 0;
    freeze_hits = 0;
    closes = 0;
    goods = 0;
    err_type = -1;
    err_text[0] = '\0';
    first_warn_frozen = -1;
    warn_reset();
}

static lua_State *case_state(void) {
    lua_State *L = lua_newstate(lalloc, NULL, 0);
    if (!L) { printf("FAIL newstate\n"); exit(2); }
    lua_setwarnf(L, warnf, NULL);
    return L;
}

static int ok_gc(lua_State *L) { (void)L; goods++; return 0; }

/* Arm `n_err` userdata whose __gc errors through `fin` and `n_good` whose
** __gc completes, then drop them all as garbage. */
static void arm_garbage(lua_State *L, lua_CFunction fin, int n_err, int n_good) {
    lua_newtable(L);
    lua_pushcfunction(L, fin);
    lua_setfield(L, -2, "__gc");
    int mt = lua_gettop(L);
    for (int i = 0; i < n_err; ++i) {
        lua_newuserdatauv(L, 1, 0);
        lua_pushvalue(L, mt);
        lua_setmetatable(L, -2);
        lua_pop(L, 1);
    }
    if (n_good > 0) {
        lua_newtable(L);
        lua_pushcfunction(L, ok_gc);
        lua_setfield(L, -2, "__gc");
        int mtg = lua_gettop(L);
        for (int i = 0; i < n_good; ++i) {
            lua_newuserdatauv(L, 1, 0);
            lua_pushvalue(L, mtg);
            lua_setmetatable(L, -2);
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
}

static int c_freeze(lua_State *L) { (void)L; frozen = 1; return 0; }

static void need(lua_State *L, const char *code) {
    if (luaL_dostring(L, code) != 0) {
        printf("FAIL setup: %s\n", lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        exit(2);
    }
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    memset(long_buf, 'x', 300);
    long_buf[300] = '\0';
    printf("=== 28_finalizer_warn_oom ===\n");

    /* w1: RuntimeError with a string object — the strict-freeze core case.
    ** Two erroring finalizers: the warning must fire twice, the queue must
    ** drain both, and the frozen allocator must deny NOTHING (the whole
    ** raise->warning path is allocation-free, PUC parity). */
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_boom, 2, 0);
        if (!lua_checkstack(L, 100)) return 3;
        int rc = lua_gc(L, LUA_GCCOLLECT, 0);
        printf("w1 gc=%d closes=%d type=%d text=%s denied=%d first_frozen=%d calls=%d ends=%d warn=[%s] after=%s\n",
               rc, closes, err_type, err_text, freeze_hits, first_warn_frozen,
               warn_calls, warn_ends, warn_buf, protected_action(L));
        lua_close(L);
    }

    /* w2: real OOM inside the body — the denied userdata allocation raises
    ** LUA_ERRMEM and the warning carries the fixed message. Single erroring
    ** finalizer: after a real-OOM finalizer error PUC's emergency GC leaves
    ** the cycle at pause, so the REST of the pending queue runs in a later
    ** cycle or at close, not in this one (see the report's OOM-QUEUE
    ** finding for the luazig divergence on that continuation). */
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_alloc, 1, 0);
        if (!lua_checkstack(L, 100)) return 3;
        int rc = lua_gc(L, LUA_GCCOLLECT, 0);
        printf("w2 gc=%d closes=%d denied=%d calls=%d ends=%d warn=[%s] after=%s\n",
               rc, closes, freeze_hits, warn_calls, warn_ends,
               warn_buf, protected_action(L));
        lua_close(L);
    }

    /* w3: non-string error object — the warning reports the class, the
    ** object rides the transport as-is. */
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_table, 1, 1);
        if (!lua_checkstack(L, 100)) return 3;
        int rc = lua_gc(L, LUA_GCCOLLECT, 0);
        printf("w3 gc=%d closes=%d goods=%d denied=%d calls=%d ends=%d warn=[%s] after=%s\n",
               rc, closes, goods, freeze_hits, warn_calls, warn_ends,
               warn_buf, protected_action(L));
        lua_close(L);
    }

    /* w4a/w4b/w4c: string-object transport across representations — a long
    ** (never-interned) string, an embedded-NUL string (the C warning stops
    ** at the first NUL), and an external string. */
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_long, 1, 0);
        if (!lua_checkstack(L, 100)) return 3;
        lua_gc(L, LUA_GCCOLLECT, 0);
        printf("w4a closes=%d denied=%d calls=%d ends=%d warnlen=%zu after=%s\n",
               closes, freeze_hits, warn_calls, warn_ends, strlen(warn_buf),
               protected_action(L));
        lua_close(L);
    }
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_nul, 1, 0);
        if (!lua_checkstack(L, 100)) return 3;
        lua_gc(L, LUA_GCCOLLECT, 0);
        printf("w4b closes=%d denied=%d calls=%d ends=%d warn=[%s] after=%s\n",
               closes, freeze_hits, warn_calls, warn_ends, warn_buf,
               protected_action(L));
        lua_close(L);
    }
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_ext, 1, 0);
        if (!lua_checkstack(L, 100)) return 3;
        lua_gc(L, LUA_GCCOLLECT, 0);
        printf("w4c closes=%d denied=%d calls=%d ends=%d warn=[%s] after=%s\n",
               closes, freeze_hits, warn_calls, warn_ends, warn_buf,
               protected_action(L));
        lua_close(L);
    }

    /* w5: the generational drain call site — a young collection finishes
    ** through callallpendingfinalizers; the warning is identical. */
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_boom, 1, 1);
        if (!lua_checkstack(L, 100)) return 3;
        lua_gc(L, LUA_GCGEN);
        lua_gc(L, LUA_GCSTEP);
        lua_gc(L, LUA_GCSTEP);
        lua_gc(L, LUA_GCSTEP);
        frozen = 0;
        printf("w5 closes=%d goods=%d denied=%d calls=%d ends=%d warn=[%s] after=%s\n",
               closes, goods, freeze_hits, warn_calls, warn_ends,
               warn_buf, protected_action(L));
        lua_close(L);
    }

    /* w6: the shutdown drain call site — finalizers still pending at
    ** lua_close run during the close; the warning is identical. */
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_boom, 1, 0);
        if (!lua_checkstack(L, 100)) return 3;
        lua_gc(L, LUA_GCCOLLECT, 0);  /* first warning, unfrozen by its end */
        arm_garbage(L, fin_boom, 1, 0);
        lua_close(L);
        printf("w6 closes=%d calls=%d ends=%d warn=[%s]\n",
               closes, warn_calls, warn_ends, warn_buf);
    }

    /* l1..l4: the same classes raised from a LUA finalizer body — the
    ** bytecode error-unwind transport must carry the original object to
    ** the warning without any mandatory allocation. */
    {
        reset_case();
        lua_State *L = case_state();
        luaL_openlibs(L);
        lua_pushcfunction(L, c_freeze);
        lua_setglobal(L, "FREEZE");
        need(L,
            "local o = setmetatable({}, {__gc = function() FREEZE() error('boom-in-gc', 0) end})\n");
        warn_reset();
        frozen = 0; freeze_hits = 0;
        need(L, "collectgarbage('collect')");
        printf("l1 calls=%d ends=%d warn=[%s] after=%s\n",
               warn_calls, warn_ends, warn_buf, protected_action(L));
        lua_close(L);
    }
    {
        /* error(nil): PUC replaces nil with the "<no error object>" literal
        ** via a FALLIBLE luaS_newliteral at the throw — under the freeze
        ** that construction itself fails and the OOM message wins. */
        reset_case();
        lua_State *L = case_state();
        luaL_openlibs(L);
        lua_pushcfunction(L, c_freeze);
        lua_setglobal(L, "FREEZE");
        need(L,
            "local o = setmetatable({}, {__gc = function() FREEZE() error(nil) end})\n");
        warn_reset();
        frozen = 0; freeze_hits = 0;
        need(L, "collectgarbage('collect')");
        printf("l2 calls=%d ends=%d warn=[%s] after=%s\n",
               warn_calls, warn_ends, warn_buf, protected_action(L));
        lua_close(L);
    }
    {
        reset_case();
        lua_State *L = case_state();
        luaL_openlibs(L);
        lua_pushcfunction(L, c_freeze);
        lua_setglobal(L, "FREEZE");
        need(L,
            "local o = setmetatable({}, {__gc = function()\n"
            "  local t = {} FREEZE() error(t)\n"
            "end})\n");
        warn_reset();
        frozen = 0; freeze_hits = 0;
        need(L, "collectgarbage('collect')");
        printf("l3 calls=%d ends=%d warn=[%s] after=%s\n",
               warn_calls, warn_ends, warn_buf, protected_action(L));
        lua_close(L);
    }
    {
        reset_case();
        lua_State *L = case_state();
        luaL_openlibs(L);
        lua_pushcfunction(L, c_freeze);
        lua_setglobal(L, "FREEZE");
        need(L,
            "local o = setmetatable({}, {__gc = function() FREEZE() error('a\\0b', 0) end})\n");
        warn_reset();
        frozen = 0; freeze_hits = 0;
        need(L, "collectgarbage('collect')");
        printf("l4 calls=%d ends=%d warn=[%s] after=%s\n",
               warn_calls, warn_ends, warn_buf, protected_action(L));
        lua_close(L);
    }

    printf("=== 28_finalizer_warn_oom DONE ===\n");
    return 0;
}
