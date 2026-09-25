/*
** 27_finalizer_owners.c — GC finalizer ownership lifetime:
** intrusive finobj/tobefnz, persistent pending queue, post-sweep callfin.
** PERMANENT differential suite (luazig vs PUC 5.5), pure C API.
**
** Forms under test (PUC lgc.c semantics):
**   (a) emergency collection separates a finalizable victim, SUPPRESSES
**       its __gc (GCScallfin guard), the pending entry persists, the
**       weak-keyed reference stays alive (markbeingfnz), a later ordinary
**       cycle finalizes EXACTLY ONCE with identity preserved; table AND
**       userdata owners.
**   (b) generational mode: an emergency leaves pending; the FIRST gen
**       step drains it (PUC youngcollection → finishgencycle →
**       callallpendingfinalizers).
**   (c) an OOM raised INSIDE a __gc body becomes a warning and the rest
**       of the pending queue still runs (PUC GCTM warn+continue; 5/5).
**   (d) retrying the collection after (c) never double-finalizes.
**   (e) GCSTOP/GCRESTART window: pending survives the stop, restart
**       finalizes once.
**   (f) REVERSE-registration order: create a,b, register b then a →
**       "a,b"; control (register c then d) → "d,c".
**   (g) ordinary two-cycle finalization control (no emergency).
**   (h) state close drains PENDING first (emergency window), then the
**       still-registered survivors, each batch in reverse-registration
**       order (recorded through a C close-safe log).
**   (i) re-registration after a completed finalizer runs __gc a second
**       time; a metatable WITHOUT __gc at dequeue time means a quiet
**       skip (dequeue already happened — exactly-once per registration).
**   (j) a finalizable object CREATED inside a __gc body survives to its
**       own lawful finalization cycle (no corruption, no lost metatable).
**   (k) weak-table visibility: a pending object as a weak KEY keeps its
**       entry (markbeingfnz precedes key pruning); as a weak VALUE the
**       entry is cleared BEFORE separation (clearbyvalues first).
**
** Determinism rules: fixed labels, integers and booleans only; no
** pointers, no tostring() of tables/threads; unbuffered stdout; error
** objects are plain strings (no position prefix matters — only counts,
** the warn stream and fixed labels are printed).
**
** The emergency shapes rely on PUC CORE behavior (not ltests): a failing
** lua_Alloc triggers luaM_realloc_'s tryagain — one emergency full GC
** (finalizers suppressed) and a retry. The suite's allocator provides a
** one-shot countdown (fail the next nsize>0 call, then disarm) and a
** max-block policy (fail any nsize>0 call above LIMIT bytes; the GC
** machinery itself never needs such blocks — a __gc body asking for one
** does).
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* ------------------------------------------------------------------ */
/* Deterministic helpers                                              */
/* ------------------------------------------------------------------ */

/* C-side finalizer log: survives lua_close (the (h)/(j) recorders). */
static char clog[256];

static void clog_reset(void) { clog[0] = '\0'; }

static void clog_add(const char *tag) {
    size_t len = strlen(clog);
    snprintf(clog + len, sizeof(clog) - len, "%s%s",
             len ? "," : "", tag);
}

static int rec_tag(lua_State *L) {
    const char *tag = "?";
    lua_getfield(L, 1, "tag");
    if (lua_isstring(L, -1)) tag = lua_tostring(L, -1);
    lua_pop(L, 1);
    clog_add(tag);
    return 0;
}

/* Warning capture: concatenate the piece stream; an entry closes when
** tocont == 0 (PUC luaE_warnerror emits 5 pieces per finalizer error). */
static char warlog[1024];
static int warn_entries;

static void warn_reset(void) {
    warlog[0] = '\0';
    warn_entries = 0;
}

static void warnf(void *ud, const char *msg, int tocont) {
    (void)ud;
    size_t len = strlen(warlog);
    snprintf(warlog + len, sizeof(warlog) - len, "%s", msg);
    if (!tocont) warn_entries++;
}

/* dostring that must succeed */
static int need(lua_State *L, const char *code, const char *id) {
    if (luaL_dostring(L, code) != 0) {
        printf("%s FAIL: dostring: %s\n", id,
               lua_isstring(L, -1) ? lua_tostring(L, -1) : "?");
        lua_pop(L, 1);
        return 1;
    }
    return 0;
}

static long numglobal(lua_State *L, const char *name) {
    long v = 0;
    lua_getglobal(L, name);
    if (lua_isnumber(L, -1)) v = (long)lua_tointeger(L, -1);
    lua_pop(L, 1);
    return v;
}

/* Read a global string into `out` ("" when absent/non-string); pops. */
static void strglobal(lua_State *L, const char *name, char *out, size_t cap) {
    out[0] = '\0';
    lua_getglobal(L, name);
    if (lua_isstring(L, -1))
        snprintf(out, cap, "%s", lua_tostring(L, -1));
    lua_pop(L, 1);
}

/* Count entries of the table at `idx` (next()-based, skips holes). */
static int tbl_count(lua_State *L, int idx) {
    int n = 0;
    lua_pushvalue(L, idx);
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
        n++;
        lua_pop(L, 1);  /* pop value; keep key for the next iteration */
    }
    lua_pop(L, 1);  /* pop the table copy */
    return n;
}

/* ------------------------------------------------------------------ */
/* Controlled allocator                                               */
/* ------------------------------------------------------------------ */

typedef struct {
    long countdown;   /* one-shot: fail the next nsize>0 call, disarm */
    long fails;       /* total countdown failures (diagnostics) */
    size_t maxblock;  /* 0 = off; fail any nsize>0 above this size */
    long bigfails;
} AllocCtrl;

static void *ctrl_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    AllocCtrl *c = ud;
    (void)osize;
    if (nsize == 0) { free(ptr); return NULL; }
    if (c->countdown > 0) {
        c->countdown = 0;  /* one-shot */
        c->fails++;
        return NULL;
    }
    if (c->maxblock && nsize > c->maxblock) {
        c->bigfails++;
        return NULL;
    }
    return realloc(ptr, nsize);
}

/* ------------------------------------------------------------------ */
/* Shared Lua-side setup                                              */
/* ------------------------------------------------------------------ */

/* FIN counts __gc calls; MT is the recording metatable; WK is the
** weak-keyed channel to the victim. */
#define FIN_SETUP \
    "FIN = 0\n" \
    "MT = {__gc = function(o) FIN = FIN + 1; LASTO = o end}\n" \
    "NOMT = {x = 1}\n" \
    "WK = setmetatable({}, {__mode='k'})\n"

/* Common state factory: custom-allocator state + libs + warn capture. */
static lua_State *case_state(AllocCtrl *ctrl) {
    lua_State *L = lua_newstate(ctrl_alloc, ctrl, 0);
    if (!L) return NULL;
    luaL_openlibs(L);
    lua_setwarnf(L, warnf, NULL);
    warn_reset();
    return L;
}

/* Arm the one-shot countdown and run a small table-constructor chunk
** through pcall: the first allocation inside the body fails once → the
** runtime's tryagain runs one emergency full GC (finalizers suppressed)
** → the retry succeeds. Prints the trigger line. */
static int fire_emergency(lua_State *L, AllocCtrl *ctrl, const char *id) {
    ctrl->countdown = 1;
    if (luaL_loadstring(L, "local t = {1}; return t") != 0) {
        printf("%s FAIL: loadstring\n", id);
        return -1;
    }
    int st = lua_pcallk(L, 0, 0, 0, 0, NULL);
    printf("%s trigger: st=%d fails=%ld\n", id, st, ctrl->fails);
    return st;
}

/* ------------------------------------------------------------------ */
/* (a) emergency -> rescue (table + userdata owners)                  */
/* ------------------------------------------------------------------ */

static int form_a(const char *kind) {
    AllocCtrl ctrl = {0, 0, 0, 0};
    lua_State *L = case_state(&ctrl);
    if (!L) { printf("a[%s] FAIL: newstate\n", kind); return 1; }
    if (need(L, FIN_SETUP, "a")) { lua_close(L); return 1; }
    (void)lua_gc(L, LUA_GCSTOP, 0);

    /* The victim: registered, unreachable, visible ONLY through WK.
    ** Some garbage exists so the emergency can actually free memory. */
    if (strcmp(kind, "table") == 0) {
        if (need(L,
            "do local v = setmetatable({}, MT); WK[v] = 'p' end\n"
            "for i = 1, 100 do local x = {} end\n", "a")) { lua_close(L); return 1; }
    } else {
        if (need(L, "for i = 1, 100 do local x = {} end\n", "a")) {
            lua_close(L);
            return 1;
        }
        /* stack discipline: WK | ud | MT(setmetatable pops) | 'p' */
        lua_getglobal(L, "WK");                       /* WK */
        lua_newuserdatauv(L, 0, 0);                   /* WK ud */
        lua_getglobal(L, "MT");                       /* WK ud MT */
        lua_setmetatable(L, -2);                      /* WK ud */
        lua_pushliteral(L, "p");                      /* WK ud 'p' */
        lua_settable(L, -3);                          /* WK */
        lua_pop(L, 1);                                /* - */
    }

    if (fire_emergency(L, &ctrl, "a") != 0) { lua_close(L); return 1; }

    /* Pending persists: the weak entry stays alive (markbeingfnz marked
    ** the pending object), no __gc ran. */
    lua_getglobal(L, "WK");
    int alive = tbl_count(L, -1);
    lua_pop(L, 1);
    printf("a[%s] pending: weakentries=%d fin=%ld\n", kind, alive,
           numglobal(L, "FIN"));

    /* Rescue: keep the weak key as a strong C-stack reference. */
    lua_getglobal(L, "WK");   /* WK */
    lua_pushnil(L);           /* WK nil */
    if (lua_next(L, -2) == 0) {
        printf("a[%s] FAIL: no weak key to rescue\n", kind);
        lua_close(L);
        return 1;
    }
    lua_pop(L, 1);            /* WK key  (pop value) */

    (void)lua_gc(L, LUA_GCRESTART, 0);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    long fin1 = numglobal(L, "FIN");
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    long fin2 = numglobal(L, "FIN");
    /* Identity: the finalized object IS the rescued reference.
    ** stack: WK(-2) key(-1) → LASTO on top. */
    lua_getglobal(L, "LASTO");   /* WK key LASTO */
    int ident = !lua_isnil(L, -1) && lua_rawequal(L, -2, -1);
    lua_pop(L, 3);
    printf("a[%s] rescue: fin1=%ld fin2=%ld identity=%d\n", kind, fin1,
           fin2, ident);

    /* Unanchor: drop BOTH the stack reference and the __gc-side anchor;
    ** the object may die now; no second __gc may run. */
    (void)need(L, "LASTO = nil\n", "a");
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    lua_getglobal(L, "WK");
    int gone = tbl_count(L, -1);
    lua_pop(L, 1);
    printf("a[%s] unanchor: fin=%ld weakentries=%d\n", kind,
           numglobal(L, "FIN"), gone);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* (b) generational: emergency leaves pending, first step drains      */
/* ------------------------------------------------------------------ */

static int form_b(void) {
    AllocCtrl ctrl = {0, 0, 0, 0};
    lua_State *L = case_state(&ctrl);
    if (!L) { printf("b FAIL: newstate\n"); return 1; }
    if (need(L, FIN_SETUP, "b")) { lua_close(L); return 1; }

    /* Registered victim, anchored across the gen transition so it is OLD
    ** when condemned; then dropped under GCSTOP. */
    if (need(L, "HOLD = setmetatable({}, MT)\n", "b")) { lua_close(L); return 1; }
    (void)lua_gc(L, LUA_GCGEN, 0);
    (void)lua_gc(L, LUA_GCSTOP, 0);
    if (need(L, "HOLD = nil\nfor i = 1, 100 do local x = {} end\n", "b")) {
        lua_close(L);
        return 1;
    }

    if (fire_emergency(L, &ctrl, "b") != 0) { lua_close(L); return 1; }
    printf("b pending: fin=%ld\n", numglobal(L, "FIN"));

    /* First gen step drains the persistent pending queue; more steps and
    ** a full collect change nothing (exactly-once). */
    (void)lua_gc(L, LUA_GCSTEP, 0);
    long fin_s1 = numglobal(L, "FIN");
    (void)lua_gc(L, LUA_GCSTEP, 0);
    (void)lua_gc(L, LUA_GCSTEP, 0);
    (void)lua_gc(L, LUA_GCSTEP, 0);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    printf("b steps: fin_step1=%ld fin_after=%ld\n", fin_s1,
           numglobal(L, "FIN"));
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* (c) OOM inside __gc body: warn + continue (5/5)                    */
/* ------------------------------------------------------------------ */

static int form_c(void) {
    AllocCtrl ctrl = {0, 0, 64 * 1024, 0};
    lua_State *L = case_state(&ctrl);
    if (!L) { printf("c FAIL: newstate\n"); return 1; }
    /* __gc asks for a block above the limit (fails under maxblock); the
    ** counter itself allocates nothing. */
    if (need(L,
        "FIN = 0\n"
        "MT = {__gc = function(o)\n"
        "  FIN = FIN + 1\n"
        "  EVT = (EVT or '') .. o.tag .. ','\n"
        "  local s = string.rep('x', 100000)\n"
        "end}\n"
        "keep = {}\n"
        "for i = 1, 5 do keep[i] = setmetatable({tag = 48 + i}, MT) end\n"
        "keep = nil\n"
        "EVT = ''\n", "c")) { lua_close(L); return 1; }

    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    char evt[64];
    strglobal(L, "EVT", evt, sizeof(evt));
    printf("c frozen: fin=%ld evt=[%s] warns=%d bigfails=%ld\n",
           numglobal(L, "FIN"), evt, warn_entries, ctrl.bigfails);
    printf("c warn: [%s]\n", warlog);

    ctrl.maxblock = 0;
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    printf("c lifted: fin=%ld\n", numglobal(L, "FIN"));
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* (d) retry after (c): no double finalization                        */
/* ------------------------------------------------------------------ */

static int form_d(void) {
    AllocCtrl ctrl = {0, 0, 64 * 1024, 0};
    lua_State *L = case_state(&ctrl);
    if (!L) { printf("d FAIL: newstate\n"); return 1; }
    if (need(L,
        "FIN = 0\n"
        "MT = {__gc = function(o) FIN = FIN + 1; local s = string.rep('x', 100000) end}\n"
        "keep = {}\n"
        "for i = 1, 3 do keep[i] = setmetatable({tag = i}, MT) end\n"
        "keep = nil\n", "d")) { lua_close(L); return 1; }

    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    long frozen = numglobal(L, "FIN");
    ctrl.maxblock = 0;
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    printf("d retry: frozen=%ld after=%ld\n", frozen, numglobal(L, "FIN"));
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* (e) GCSTOP/GCRESTART window                                        */
/* ------------------------------------------------------------------ */

static int form_e(void) {
    AllocCtrl ctrl = {0, 0, 0, 0};
    lua_State *L = case_state(&ctrl);
    if (!L) { printf("e FAIL: newstate\n"); return 1; }
    if (need(L, FIN_SETUP
        "do local v = setmetatable({}, MT); WK[v] = 'p' end\n"
        "for i = 1, 100 do local x = {} end\n", "e")) { lua_close(L); return 1; }
    (void)lua_gc(L, LUA_GCSTOP, 0);
    if (fire_emergency(L, &ctrl, "e") != 0) { lua_close(L); return 1; }
    lua_getglobal(L, "WK");
    int alive = tbl_count(L, -1);
    lua_pop(L, 1);
    printf("e window: fin=%ld weakentries=%d\n", numglobal(L, "FIN"), alive);

    /* Rescue under STOP, then restart + collect. */
    lua_getglobal(L, "WK");
    lua_pushnil(L);
    if (lua_next(L, -2) == 0) {
        printf("e FAIL: no weak key to rescue\n");
        lua_close(L);
        return 1;
    }
    lua_pop(L, 1);            /* WK key */
    (void)lua_gc(L, LUA_GCRESTART, 0);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    long fin1 = numglobal(L, "FIN");
    lua_getglobal(L, "LASTO");   /* WK key LASTO */
    int ident = !lua_isnil(L, -1) && lua_rawequal(L, -2, -1);
    lua_pop(L, 3);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    printf("e restart: fin=%ld fin_again=%ld identity=%d\n", fin1,
           numglobal(L, "FIN"), ident);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* (f) REVERSE-registration order                                     */
/* ------------------------------------------------------------------ */

static int form_f(void) {
    lua_State *L = luaL_newstate();
    if (!L) { printf("f FAIL: newstate\n"); return 1; }
    luaL_openlibs(L);
    lua_setwarnf(L, warnf, NULL);
    warn_reset();
    if (need(L,
        "LOG = ''\n"
        "local function MK(tag)\n"
        "  return {__gc = function() LOG = LOG .. tag .. ',' end}\n"
        "end\n"
        "local a, b = {}, {}                 -- creation: a, then b\n"
        "setmetatable(b, MK('b'))            -- registration: b first\n"
        "setmetatable(a, MK('a'))            -- registration: a last\n"
        "a, b = nil, nil\n"
        "collectgarbage()\n"
        "collectgarbage()\n"
        "local c, d = {}, {}                 -- creation: c, then d\n"
        "setmetatable(c, MK('c'))            -- registration: c first\n"
        "setmetatable(d, MK('d'))            -- registration: d last\n"
        "c, d = nil, nil\n"
        "collectgarbage()\n"
        "collectgarbage()\n", "f")) { lua_close(L); return 1; }
    char log[64];
    strglobal(L, "LOG", log, sizeof(log));
    printf("f order: [%s]\n", log);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* (g) ordinary two-cycle control                                     */
/* ------------------------------------------------------------------ */

static int form_g(const char *kind) {
    lua_State *L = luaL_newstate();
    if (!L) { printf("g[%s] FAIL: newstate\n", kind); return 1; }
    luaL_openlibs(L);
    lua_setwarnf(L, warnf, NULL);
    warn_reset();
    if (need(L, FIN_SETUP, "g")) { lua_close(L); return 1; }
    if (strcmp(kind, "table") == 0) {
        if (need(L, "do local v = setmetatable({}, MT); WK[v] = 'p' end\n", "g")) {
            lua_close(L);
            return 1;
        }
    } else {
        lua_getglobal(L, "WK");
        lua_newuserdatauv(L, 0, 0);
        lua_getglobal(L, "MT");
        lua_setmetatable(L, -2);
        lua_pushliteral(L, "p");
        lua_settable(L, -3);
        lua_pop(L, 1);
    }
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    long fin1 = numglobal(L, "FIN");
    lua_getglobal(L, "LASTO");
    int has_last = !lua_isnil(L, -1);
    lua_pop(L, 1);
    lua_getglobal(L, "WK");
    int entries = tbl_count(L, -1);   /* rescued: still one entry */
    lua_pop(L, 1);
    /* Drop the __gc-side anchor too, then let the freed-check see the
    ** object really die (weak key must disappear). */
    (void)need(L, "LASTO = nil\n", "g");
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    lua_getglobal(L, "WK");
    int entries2 = tbl_count(L, -1);  /* freed: the key is gone */
    lua_pop(L, 1);
    printf("g[%s] cycle1: fin=%ld last=%d weakentries=%d\n", kind, fin1,
           has_last, entries);
    printf("g[%s] freed: fin=%ld weakentries=%d\n", kind,
           numglobal(L, "FIN"), entries2);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* (h) close: pending first, then registered survivors                */
/* ------------------------------------------------------------------ */

static int form_h(void) {
    AllocCtrl ctrl = {0, 0, 0, 0};
    lua_State *L = case_state(&ctrl);
    if (!L) { printf("h FAIL: newstate\n"); return 1; }
    clog_reset();
    lua_pushcfunction(L, rec_tag);
    lua_setglobal(L, "REC");
    if (need(L,
        "local function MK(tag)\n"
        "  return {__gc = function(o) REC(o) end}\n"
        "end\n"
        "local function reg(tag)\n"
        "  return setmetatable({tag = tag}, MK(tag))\n"
        "end\n"
        "REG = reg\n", "h")) { lua_close(L); return 1; }
    (void)lua_gc(L, LUA_GCSTOP, 0);
    /* Two pending victims (registered p1 then p2), condemned; the
    ** emergency separates them but suppresses their __gc. */
    if (need(L,
        "do\n"
        "  local v1 = REG('p1')\n"
        "  local v2 = REG('p2')\n"
        "end\n"
        "for i = 1, 100 do local x = {} end\n", "h")) { lua_close(L); return 1; }
    if (fire_emergency(L, &ctrl, "h") != 0) { lua_close(L); return 1; }
    /* Two MORE registered survivors stay reachable until close. */
    if (need(L,
        "K1 = REG('k1')\n"
        "K2 = REG('k2')\n", "h")) { lua_close(L); return 1; }
    printf("h window: pendinglog=[%s]\n", clog);
    /* lua_close drains: pending (p2,p1 — reverse registration) first,
    ** then the registered survivors (k2,k1). */
    lua_close(L);
    printf("h close: log=[%s]\n", clog);
    return 0;
}

/* ------------------------------------------------------------------ */
/* (i) re-registration + current-metatable lookup                     */
/* ------------------------------------------------------------------ */

static int form_i(void) {
    lua_State *L = luaL_newstate();
    if (!L) { printf("i FAIL: newstate\n"); return 1; }
    luaL_openlibs(L);
    lua_setwarnf(L, warnf, NULL);
    warn_reset();
    /* Part 1 — re-registration: the __gc body resurrects its object
    ** (LASTO anchor); after the completed finalizer, a fresh explicit
    ** registration followed by re-condemnation runs __gc a SECOND time. */
    if (need(L,
        "FIN = 0\n"
        "MT = {__gc = function(o) FIN = FIN + 1; LASTO = o end}\n"
        "NOMT = {x = 1}\n"
        "do local v = setmetatable({}, MT) end\n", "i")) { lua_close(L); return 1; }
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    long fin1 = numglobal(L, "FIN");
    /* Re-register the RESURRECTED object, then condemn it again. */
    if (need(L,
        "setmetatable(LASTO, MT)\n"
        "LASTO = nil\n", "i")) { lua_close(L); return 1; }
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    long fin2 = numglobal(L, "FIN");
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    long fin3 = numglobal(L, "FIN");
    printf("i rereg: first=%ld second=%ld stable=%ld\n", fin1, fin2, fin3);

    /* Part 2 — current-metatable lookup: leave a PENDING object whose
    ** metatable is swapped (no __gc) before its finalizer is dequeued;
    ** the dequeue is quiet (no call, exactly-once per registration). */
    AllocCtrl ctrl = {0, 0, 0, 0};
    lua_close(L);
    L = case_state(&ctrl);
    if (!L) { printf("i FAIL: newstate2\n"); return 1; }
    if (need(L, FIN_SETUP, "i2")) { lua_close(L); return 1; }
    (void)lua_gc(L, LUA_GCSTOP, 0);
    if (need(L,
        "do local v = setmetatable({}, MT); WK[v] = 'p' end\n"
        "for i = 1, 100 do local x = {} end\n", "i2")) { lua_close(L); return 1; }
    if (fire_emergency(L, &ctrl, "i2") != 0) { lua_close(L); return 1; }
    /* Pending exists (no __gc ran). Swap the CURRENT metatable of the
    ** rescued reference to one WITHOUT __gc, then let the cycle drain:
    ** the dequeue happens, the lookup finds no __gc → quiet skip. */
    lua_getglobal(L, "WK");
    lua_pushnil(L);
    if (lua_next(L, -2) == 0) {
        printf("i2 FAIL: no weak key\n");
        lua_close(L);
        return 1;
    }
    lua_pop(L, 1);                         /* WK key */
    lua_pushvalue(L, -1);                  /* WK key key */
    lua_getglobal(L, "NOMT");              /* WK key key NOMT */
    lua_setmetatable(L, -2);               /* WK key (mt swapped) */
    lua_pop(L, 2);
    (void)lua_gc(L, LUA_GCRESTART, 0);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    long fin4 = numglobal(L, "FIN");
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    long fin5 = numglobal(L, "FIN");
    printf("i2 mtswap: fin=%ld again=%ld\n", fin4, fin5);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* (j) finalizable created inside __gc                                */
/* ------------------------------------------------------------------ */

static int form_j(void) {
    lua_State *L = luaL_newstate();
    if (!L) { printf("j FAIL: newstate\n"); return 1; }
    luaL_openlibs(L);
    lua_setwarnf(L, warnf, NULL);
    warn_reset();
    clog_reset();
    lua_pushcfunction(L, rec_tag);
    lua_setglobal(L, "REC");
    /* Outer's __gc creates an INNER finalizable whose metatable is a
    ** fresh table — the old corruption shape: the inner's metatable
    ** used to die in the very cycle that ran the outer's finalizer. */
    if (need(L,
        "do\n"
        "  local outer = setmetatable({}, {__gc = function()\n"
        "    local inner = setmetatable({tag = 'inner'},\n"
        "        {__gc = function(o) REC(o) end})\n"
        "  end})\n"
        "end\n", "j")) { lua_close(L); return 1; }
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    char c1[64];
    snprintf(c1, sizeof(c1), "%s", clog);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    printf("j inner: cycle1=[%s] settled=[%s]\n", c1, clog);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */
/* (k) weak-table visibility of pending objects                       */
/* ------------------------------------------------------------------ */

static int form_k(void) {
    AllocCtrl ctrl = {0, 0, 0, 0};
    lua_State *L = case_state(&ctrl);
    if (!L) { printf("k FAIL: newstate\n"); return 1; }
    if (need(L, FIN_SETUP
        "WV = setmetatable({}, {__mode='v'})\n"
        "do\n"
        "  local v = setmetatable({}, MT)\n"
        "  WK[v] = 'kept'\n"
        "  WV['x'] = v\n"
        "end\n"
        "for i = 1, 100 do local x = {} end\n", "k")) { lua_close(L); return 1; }
    (void)lua_gc(L, LUA_GCSTOP, 0);
    if (fire_emergency(L, &ctrl, "k") != 0) { lua_close(L); return 1; }
    lua_getglobal(L, "WK");
    int wk = tbl_count(L, -1);
    lua_pop(L, 1);
    lua_getglobal(L, "WV");
    int wv = tbl_count(L, -1);
    lua_pop(L, 1);
    printf("k pending: weakkeys=%d weakvalues=%d fin=%ld\n", wk, wv,
           numglobal(L, "FIN"));
    (void)lua_gc(L, LUA_GCRESTART, 0);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    long fin1 = numglobal(L, "FIN");
    lua_getglobal(L, "WK");
    int wk2 = tbl_count(L, -1);   /* still marked: pending resurrection */
    lua_pop(L, 1);
    /* Drop the __gc-side anchor (LASTO), then the freed-check must see
    ** the weak key disappear after the lawful finalization. */
    (void)need(L, "LASTO = nil\n", "k");
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    (void)lua_gc(L, LUA_GCCOLLECT, 0);
    lua_getglobal(L, "WK");
    int wk3 = tbl_count(L, -1);   /* freed after lawful finalization */
    lua_pop(L, 1);
    printf("k final: fin=%ld fin_again=%ld weakkeys_finalized=%d weakkeys_freed=%d\n",
           fin1, numglobal(L, "FIN"), wk2, wk3);
    lua_close(L);
    return 0;
}

/* ------------------------------------------------------------------ */

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== 27_finalizer_owners: intrusive finobj/tobefnz lifetime ===\n");
    if (form_a("table")) return 1;
    if (form_a("userdata")) return 1;
    if (form_b()) return 1;
    if (form_c()) return 1;
    if (form_d()) return 1;
    if (form_e()) return 1;
    if (form_f()) return 1;
    if (form_g("table")) return 1;
    if (form_g("userdata")) return 1;
    if (form_h()) return 1;
    if (form_i()) return 1;
    if (form_j()) return 1;
    if (form_k()) return 1;
    printf("=== 27_finalizer_owners DONE ===\n");
    return 0;
}
