/*
** 40_maindestined_transport.c — PERMANENT differential suite (luazig vs
** PUC 5.5) for the typed main-destined error transport: a closer error
** raised by a CROSS-THREAD stack operation (lua_settop/lua_pop/
** lua_closeslot on a foreign suspended coroutine with to-be-closed marks)
** is destined for the MAIN thread's armed protected boundary (PUC ldo.c
** luaD_throw: the raising thread has no errorJmp of its own ->
** luaE_resetthread(raiser) + re-throw on mainthread's errorJmp), bypassing
** every intermediate frame: the driving C activations and coroutine
** callers are abandoned mid-frame (zombie: status OK, frames intact, a
** later resume rejected as non-suspended), and the catching boundary on
** main consumes the error (frame-level restore, TBC region close with the
** in-flight error, publication of the transported object).
**
** Every case below is a PUC-verified observable differential: the outputs
** must be byte-identical on both runtimes (stderr included — the GC case
** exercises the "Lua warning: error in __gc (...)" channel). stdout is
** switched to unbuffered so C printf and Lua print interleave in program
** order on both runtimes.
**
** Cases:
**   P1   foreign-thread path, main armed via lua_pcall: the drive C
**        activation is abandoned (no drive-return line), main-pcall
**        catches st=2 with the closer error, target dead, caller zombie.
**   P2   the caller coroutine's OWN C-API pcall between its body and the
**        cross settop is bypassed (its printf never runs).
**   P3   nested resumes: co1 (driven from main) resumes co2 whose C body
**        does the cross settop — BOTH coroutines are left zombie.
**   C1   nested protected boundaries on main with TBC marks: the throw
**        lands on the INNERMOST armed pcall; the mark above it closes
**        WITH the error, the mark below survives; the caller coroutine
**        (resumed via coroutine.resume) is a zombie reporting "normal".
**   C2   last-error-wins across two erroring closers (LIFO close order).
**   C3   ERRMEM transport: a REAL allocation failure inside the closer
**        carries status 4 with the fixed "not enough memory" object; a
**        LITERAL "not enough memory" string error stays ERRRUN (2) —
**        classification is by object identity, never by text.
**   C4   denied yield inside the cross-thread closer: the yield error
**        takes the same transport (st=2, "attempt to yield across a
**        C-call boundary").
**   C5   the raise triggered by lua_pop (truncation pop) and
**        lua_closeslot (explicit mark close) on the foreign thread.
**   C8   after main's boundary catches: the VM stays usable, the zombie
**        caller rejects resume (non-suspended), the finalized target
**        rejects resume as dead.
**   PM   boundary-owner: the truncation targets MAIN ITSELF while main
**        is inside its own armed boundary (a marked C function on main
**        resumes the attacking coroutine). Main is NOT reset: the
**        innermost pcall catches, the mark below the boundary survives,
**        main keeps a coroutine-visible status "normal", the driver
**        coroutine is a zombie.
**   GC   finalizer re-entry: a __gc metamethod performs the cross-thread
**        truncation; the closer error re-throws on main lands on the
**        finalizer's own protection (PUC GCTM's luaD_pcall) and degrades
**        to the "error in __gc" warning; the GC cycle and the chunk
**        continue, the target is dead.
**
** The testC-pad lane of the same transport (the raise crossing testC
** C-activations) and the checkpanic panic lane are pinned by the Zig
** unit test "main-destined transport: testC lane pads, GC finalizer
** re-entry, checkpanic panic lane" (they need the test-only T module,
** which a plain C host cannot register).
*/

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* shared shape: a suspended C-body target with a to-be-closed mark    */
/* whose __close errors.                                               */
/* ------------------------------------------------------------------ */

static int kdone(lua_State *L, int status, lua_KContext ctx) {
    (void)L; (void)status; (void)ctx;
    return 0;
}

static int target_body(lua_State *L) {
    lua_toclose(L, 1);
    return lua_yieldk(L, 0, 0, kdone);
}

static const char *OBJ_SETUP =
    "OBJ = setmetatable({}, {__close = function() error('closer-boom') end})";

/* err text at main's boundary: "-" on success, the top value's string
 * form otherwise (numbers convert like PUC lua_tolstring). */
static const char *err_or_dash(lua_State *L, int st) {
    if (st == 0) return "-";
    return lua_isstring(L, -1) ? lua_tostring(L, -1) : "?";
}

/* ------------------------------------------------------------------ */
/* P1: foreign-thread path, main armed via lua_pcall                   */
/* ------------------------------------------------------------------ */

static lua_State *p1_target;
static lua_State *p1_caller;

static int p1_caller_body(lua_State *L) {
    (void)L;
    lua_settop(p1_target, 0);
    printf("P1 caller-after\n"); /* PUC: never runs (abandoned mid-frame) */
    return 0;
}

static int p1_drive(lua_State *L) {
    int nres = 0;
    p1_caller = lua_newthread(L);
    lua_pushcfunction(p1_caller, p1_caller_body);
    int st = lua_resume(p1_caller, L, 0, &nres);
    printf("P1 drive-return st=%d nres=%d caller-status=%d\n", st, nres,
           lua_status(p1_caller)); /* PUC: never runs */
    return 0;
}

static void case_p1(void) {
    lua_State *L = luaL_newstate();
    int nres = 0, st;
    luaL_openlibs(L);
    st = luaL_dostring(L, OBJ_SETUP);
    if (st) { printf("P1 setup-error: %s\n", lua_tostring(L, -1)); return; }
    p1_target = lua_newthread(L);
    lua_pushcfunction(p1_target, target_body);
    lua_getglobal(L, "OBJ");
    lua_xmove(L, p1_target, 1);
    st = lua_resume(p1_target, L, 1, &nres);
    printf("P1 target-first st=%d nres=%d\n", st, nres);
    lua_pushcfunction(L, p1_drive);
    st = lua_pcall(L, 0, 0, 0);
    printf("P1 main-pcall st=%d err=%s target-status=%d caller-status=%d\n",
           st, err_or_dash(L, st), lua_status(p1_target),
           lua_status(p1_caller));
    lua_close(L);
}

/* ------------------------------------------------------------------ */
/* P2: the caller coroutine's own C-API pcall is bypassed              */
/* ------------------------------------------------------------------ */

static lua_State *p2_target;

static int p2_settop_fn(lua_State *L) {
    (void)L;
    lua_settop(p2_target, 0);
    return 0;
}

static int p2_caller_body(lua_State *L) {
    lua_pushcfunction(L, p2_settop_fn);
    int st = lua_pcall(L, 0, 0, 0);
    printf("P2 caller-pcall st=%d err=%s\n", st, err_or_dash(L, st));
    lua_pushliteral(L, "after");
    return 1;
}

static int p2_drive(lua_State *L) {
    int nres = 0;
    lua_State *caller = lua_newthread(L);
    lua_pushcfunction(caller, p2_caller_body);
    int st = lua_resume(caller, L, 0, &nres);
    printf("P2 drive-return st=%d nres=%d caller-status=%d\n", st, nres,
           lua_status(caller));
    return 0;
}

static void case_p2(void) {
    lua_State *L = luaL_newstate();
    int nres = 0, st;
    luaL_openlibs(L);
    st = luaL_dostring(L, OBJ_SETUP);
    if (st) { printf("P2 setup-error: %s\n", lua_tostring(L, -1)); return; }
    p2_target = lua_newthread(L);
    lua_pushcfunction(p2_target, target_body);
    lua_getglobal(L, "OBJ");
    lua_xmove(L, p2_target, 1);
    st = lua_resume(p2_target, L, 1, &nres);
    printf("P2 target-first st=%d nres=%d\n", st, nres);
    lua_pushcfunction(L, p2_drive);
    st = lua_pcall(L, 0, 0, 0);
    printf("P2 main-pcall st=%d err=%s target-status=%d\n", st,
           err_or_dash(L, st), lua_status(p2_target));
    lua_close(L);
}

/* ------------------------------------------------------------------ */
/* P3: nested resumes — both coroutines zombie                         */
/* ------------------------------------------------------------------ */

static lua_State *p3_target;
static lua_State *p3_co2;

static int p3_co2_body(lua_State *L) {
    (void)L;
    lua_settop(p3_target, 0);
    lua_pushliteral(L, "co2-done");
    return 1;
}

static int p3_co1_body(lua_State *L) {
    int nres = 0;
    int st = lua_resume(p3_co2, L, 0, &nres);
    printf("P3 co1-resume st=%d nres=%d co2-status=%d\n", st, nres,
           lua_status(p3_co2)); /* PUC: never runs */
    lua_pushliteral(L, "co1-after");
    return 1;
}

static int p3_drive(lua_State *L) {
    int nres = 0;
    lua_State *co1 = lua_newthread(L);
    lua_pushcfunction(co1, p3_co1_body);
    int st = lua_resume(co1, L, 0, &nres);
    printf("P3 drive-return st=%d nres=%d co1-status=%d\n", st, nres,
           lua_status(co1)); /* PUC: never runs */
    return 0;
}

static void case_p3(void) {
    lua_State *L = luaL_newstate();
    int nres = 0, st;
    luaL_openlibs(L);
    st = luaL_dostring(L, OBJ_SETUP);
    if (st) { printf("P3 setup-error: %s\n", lua_tostring(L, -1)); return; }
    p3_target = lua_newthread(L);
    lua_pushcfunction(p3_target, target_body);
    lua_getglobal(L, "OBJ");
    lua_xmove(L, p3_target, 1);
    st = lua_resume(p3_target, L, 1, &nres);
    printf("P3 target-first st=%d nres=%d\n", st, nres);
    p3_co2 = lua_newthread(L);
    lua_pushcfunction(p3_co2, p3_co2_body);
    lua_pushcfunction(L, p3_drive);
    st = lua_pcall(L, 0, 0, 0);
    printf("P3 main-pcall st=%d err=%s target-status=%d co2-status=%d\n",
           st, err_or_dash(L, st), lua_status(p3_target),
           lua_status(p3_co2));
    lua_close(L);
}

/* ------------------------------------------------------------------ */
/* C1: nested protected boundaries on main with TBC marks              */
/* ------------------------------------------------------------------ */

static lua_State *c1_target;

static int c1_caller_body(lua_State *L) {
    (void)L;
    lua_settop(c1_target, 0);
    return 0;
}

static void case_c1(void) {
    lua_State *L = luaL_newstate();
    lua_State *caller;
    int nres = 0, st;
    luaL_openlibs(L);
    st = luaL_dostring(L, OBJ_SETUP);
    if (st) { printf("C1 setup-error: %s\n", lua_tostring(L, -1)); return; }
    c1_target = lua_newthread(L);
    lua_pushcfunction(c1_target, target_body);
    lua_getglobal(c1_target, "OBJ");
    st = lua_resume(c1_target, L, 1, &nres);
    printf("C1 target-first st=%d\n", st);
    caller = lua_newthread(L);
    lua_pushcfunction(caller, c1_caller_body);
    /* publish the caller coroutine as a global for the chunk */
    lua_pushthread(caller);
    lua_xmove(caller, L, 1);
    lua_setglobal(L, "COROUTINE");
    st = luaL_dostring(L,
        "local a <close> = setmetatable({}, {__close = function(_, e) print('C1 close-a', e) end})\n"
        "local ok, err = pcall(function()\n"
        "  local b <close> = setmetatable({}, {__close = function(_, e) print('C1 close-b', e) end})\n"
        "  local rok = coroutine.resume(COROUTINE)\n"
        "  print('C1 unreachable-inner', rok)\n"
        "end)\n"
        "print('C1 inner-pcall', ok, err)\n"
        "print('C1 chunk-continues')\n");
    printf("C1 dostring st=%d target-status=%d caller-status=%d\n", st,
           lua_status(c1_target), lua_status(caller));
    lua_close(L);
}

/* ------------------------------------------------------------------ */
/* C2: last-error-wins across two erroring closers                     */
/* ------------------------------------------------------------------ */

static lua_State *c2_target;

static int c2_target_body(lua_State *L) {
    lua_toclose(L, 1);
    lua_toclose(L, 2);
    return lua_yieldk(L, 0, 0, kdone);
}

static int c2_caller_body(lua_State *L) {
    (void)L;
    lua_settop(c2_target, 0);
    return 0;
}

static int c2_drive(lua_State *L) {
    int nres = 0;
    lua_State *caller = lua_newthread(L);
    lua_pushcfunction(caller, c2_caller_body);
    int st = lua_resume(caller, L, 0, &nres);
    printf("C2 caller-resume st=%d caller-status=%d\n", st,
           lua_status(caller)); /* PUC: never runs */
    return 0;
}

static void case_c2(void) {
    lua_State *L = luaL_newstate();
    int nres = 0, st;
    luaL_openlibs(L);
    st = luaL_dostring(L,
        "OBJ1 = setmetatable({}, {__close = function() print('C2 closing-1') error('boom-one') end})\n"
        "OBJ2 = setmetatable({}, {__close = function() print('C2 closing-2') error('boom-two') end})");
    if (st) { printf("C2 setup-error: %s\n", lua_tostring(L, -1)); return; }
    c2_target = lua_newthread(L);
    lua_pushcfunction(c2_target, c2_target_body);
    lua_getglobal(c2_target, "OBJ1");
    lua_getglobal(c2_target, "OBJ2");
    st = lua_resume(c2_target, L, 2, &nres);
    printf("C2 target-first st=%d\n", st);
    lua_pushcfunction(L, c2_drive);
    st = lua_pcall(L, 0, 0, 0);
    printf("C2 main-pcall st=%d err=%s target-status=%d\n", st,
           err_or_dash(L, st), lua_status(c2_target));
    lua_close(L);
}

/* ------------------------------------------------------------------ */
/* C3: ERRMEM transport (real OOM) vs literal-text classification      */
/* ------------------------------------------------------------------ */

static int c3_fail_alloc = 0;

static void *c3_failing_alloc(void *ud, void *ptr, size_t osize,
                              size_t nsize) {
    (void)ud; (void)osize;
    if (nsize == 0) { free(ptr); return NULL; }
    if (c3_fail_alloc) return NULL; /* fail every allocation while armed */
    if (ptr == NULL) return malloc(nsize);
    return realloc(ptr, nsize);
}

static lua_State *c3_target;
static int c3_literal_mode = 0;

static int c3_oom_closer(lua_State *L) {
    if (c3_literal_mode) {
        /* a fresh lookalike that is NOT the interned OOM object: PUC's
         * lua_error raises real ERRMEM only for the interned memerrmsg
         * (short-string identity); any other object stays ERRRUN through
         * the transport — classification is by object identity, never
         * by text. */
        lua_pushliteral(L, "nomem-literal");
        return lua_error(L);
    }
    c3_fail_alloc = 1;
    lua_newtable(L); /* allocation fails -> LUA_ERRMEM throw */
    c3_fail_alloc = 0; /* not reached when the throw happens */
    return 0;
}

static int c3_caller_body(lua_State *L) {
    (void)L;
    lua_settop(c3_target, 0);
    return 0;
}

static int c3_drive(lua_State *L) {
    int nres = 0;
    lua_State *caller = lua_newthread(L);
    lua_pushcfunction(caller, c3_caller_body);
    int st = lua_resume(caller, L, 0, &nres);
    printf("C3 caller-resume st=%d caller-status=%d\n", st,
           lua_status(caller)); /* PUC: never runs */
    return 0;
}

static void case_c3(void) {
    int nres = 0, st;
    lua_State *L;
    for (int mode = 0; mode < 2; mode++) {
        c3_literal_mode = mode;
        c3_fail_alloc = 0;
        L = lua_newstate(c3_failing_alloc, NULL, 0);
        if (L == NULL) { printf("C3 newstate-failed\n"); return; }
        luaL_openlibs(L);
        /* the OBJ table with the C closer (the metatable owns __close) */
        lua_newtable(L);                    /* OBJ */
        lua_newtable(L);                    /* OBJ's metatable */
        lua_pushcfunction(L, c3_oom_closer);
        lua_setfield(L, -2, "__close");     /* mt.__close = oom_closer */
        lua_setmetatable(L, -2);            /* OBJ metatable = mt */
        lua_setglobal(L, "OBJ");
        c3_target = lua_newthread(L);
        lua_pushcfunction(c3_target, target_body);
        lua_getglobal(c3_target, "OBJ");
        st = lua_resume(c3_target, L, 1, &nres);
        printf("C3[%d] target-first st=%d\n", mode, st);
        lua_pushcfunction(L, c3_drive);
        st = lua_pcall(L, 0, 0, 0);
        printf("C3[%d] main-pcall st=%d err=%s target-status=%d\n", mode, st,
               err_or_dash(L, st), lua_status(c3_target));
        /* the failing flag may still be armed (real-OOM arm); only
         * Lua-free C API calls from here on, no lua_close. */
        printf("C3[%d] done literal=%d\n", mode, c3_literal_mode);
    }
}

/* ------------------------------------------------------------------ */
/* C4: denied yield inside the cross-thread closer                     */
/* ------------------------------------------------------------------ */

static lua_State *c4_target;

static int c4_caller_body(lua_State *L) {
    (void)L;
    lua_settop(c4_target, 0);
    return 0;
}

static int c4_drive(lua_State *L) {
    int nres = 0;
    lua_State *caller = lua_newthread(L);
    lua_pushcfunction(caller, c4_caller_body);
    int st = lua_resume(caller, L, 0, &nres);
    printf("C4 caller-resume st=%d caller-status=%d\n", st,
           lua_status(caller)); /* PUC: never runs */
    return 0;
}

static void case_c4(void) {
    lua_State *L = luaL_newstate();
    int nres = 0, st;
    luaL_openlibs(L);
    st = luaL_dostring(L,
        "OBJ = setmetatable({}, {__close = function() coroutine.yield() end})");
    if (st) { printf("C4 setup-error: %s\n", lua_tostring(L, -1)); return; }
    c4_target = lua_newthread(L);
    lua_pushcfunction(c4_target, target_body);
    lua_getglobal(c4_target, "OBJ");
    st = lua_resume(c4_target, L, 1, &nres);
    printf("C4 target-first st=%d\n", st);
    lua_pushcfunction(L, c4_drive);
    st = lua_pcall(L, 0, 0, 0);
    printf("C4 main-pcall st=%d err=%s target-status=%d\n", st,
           err_or_dash(L, st), lua_status(c4_target));
    lua_close(L);
}

/* ------------------------------------------------------------------ */
/* C5: the raise via lua_pop and lua_closeslot on the foreign thread   */
/* ------------------------------------------------------------------ */

static lua_State *c5_target;
static int c5_variant = 0; /* 0 = lua_pop, 1 = lua_closeslot */

static int c5_target_body(lua_State *L) {
    lua_toclose(L, 1);
    if (c5_variant == 1) {
        /* an extra plain value above the mark so closeslot(2) keeps the
         * mark as the most recently marked level while the pop variant
         * truncates across it */
        lua_pushinteger(L, 77);
    }
    return lua_yieldk(L, 0, 0, kdone);
}

static int c5_caller_body(lua_State *L) {
    (void)L;
    if (c5_variant == 0)
        lua_pop(c5_target, 1);        /* truncation close of the marked slot */
    else
        lua_closeslot(c5_target, 1);  /* explicit close of the marked slot */
    return 0;
}

static int c5_drive(lua_State *L) {
    int nres = 0;
    lua_State *caller = lua_newthread(L);
    lua_pushcfunction(caller, c5_caller_body);
    int st = lua_resume(caller, L, 0, &nres);
    printf("C5 caller-resume st=%d caller-status=%d\n", st,
           lua_status(caller)); /* PUC: never runs */
    return 0;
}

static void case_c5(void) {
    lua_State *L = luaL_newstate();
    int nres = 0, st;
    luaL_openlibs(L);
    st = luaL_dostring(L, OBJ_SETUP);
    if (st) { printf("C5 setup-error: %s\n", lua_tostring(L, -1)); return; }
    for (int variant = 0; variant < 2; variant++) {
        c5_variant = variant;
        c5_target = lua_newthread(L);
        lua_pushcfunction(c5_target, c5_target_body);
        lua_getglobal(c5_target, "OBJ");
        st = lua_resume(c5_target, L, 1, &nres);
        printf("C5[%d] target-first st=%d target-top=%d\n", variant, st,
               lua_gettop(c5_target));
        lua_pushcfunction(L, c5_drive);
        st = lua_pcall(L, 0, 0, 0);
        printf("C5[%d] main-pcall st=%d err=%s target-status=%d\n", variant,
               st, err_or_dash(L, st), lua_status(c5_target));
    }
    lua_close(L);
}

/* ------------------------------------------------------------------ */
/* C8: VM reuse after the catch; zombie/dead resume rejection          */
/* ------------------------------------------------------------------ */

static lua_State *c8_target;
static lua_State *c8_caller;

static int c8_caller_body(lua_State *L) {
    (void)L;
    lua_settop(c8_target, 0);
    return 0;
}

static int c8_drive(lua_State *L) {
    int nres = 0;
    int st = lua_resume(c8_caller, L, 0, &nres);
    printf("C8 caller-resume st=%d caller-status=%d\n", st,
           lua_status(c8_caller)); /* PUC: never runs */
    return 0;
}

static void case_c8(void) {
    lua_State *L = luaL_newstate();
    int nres = 0, st;
    luaL_openlibs(L);
    st = luaL_dostring(L, OBJ_SETUP);
    if (st) { printf("C8 setup-error: %s\n", lua_tostring(L, -1)); return; }
    c8_target = lua_newthread(L);
    lua_pushcfunction(c8_target, target_body);
    lua_getglobal(c8_target, "OBJ");
    st = lua_resume(c8_target, L, 1, &nres);
    printf("C8 target-first st=%d\n", st);
    c8_caller = lua_newthread(L);
    lua_pushcfunction(c8_caller, c8_caller_body);
    lua_pushcfunction(L, c8_drive);
    st = lua_pcall(L, 0, 0, 0);
    printf("C8 main-pcall st=%d err=%s\n", st, err_or_dash(L, st));
    /* the VM is usable after the catch */
    st = luaL_dostring(L, "return 2 + 2");
    printf("C8 after-catch dostring st=%d val=%d\n", st,
           st == 0 ? (int)lua_tointeger(L, -1) : -1);
    /* the zombie caller rejects resume */
    st = lua_resume(c8_caller, L, 0, &nres);
    printf("C8 zombie-resume st=%d err=%s caller-status=%d\n", st,
           err_or_dash(L, st), lua_status(c8_caller));
    /* the finalized target rejects resume as dead */
    st = lua_resume(c8_target, L, 0, &nres);
    printf("C8 dead-resume st=%d err=%s target-status=%d\n", st,
           err_or_dash(L, st), lua_status(c8_target));
    lua_close(L);
}

/* ------------------------------------------------------------------ */
/* PM: boundary-owner — the truncation targets MAIN itself             */
/* ------------------------------------------------------------------ */

static lua_State *pm_main;
static lua_State *pm_co;

static int pm_caller_body(lua_State *L) {
    (void)L;
    lua_settop(pm_main, 0);
    printf("PM caller-after\n"); /* PUC: never runs */
    return 0;
}

static int pm_marked_driver(lua_State *L) {
    lua_toclose(L, 1);
    int nres = 0;
    pm_co = lua_newthread(L);
    lua_pushcfunction(pm_co, pm_caller_body);
    int st = lua_resume(pm_co, L, 0, &nres);
    printf("PM driver-return st=%d co-status=%d\n", st,
           lua_status(pm_co)); /* PUC: never runs */
    return 0;
}

static void case_pm(void) {
    lua_State *L = luaL_newstate();
    int st;
    pm_main = L;
    luaL_openlibs(L);
    st = luaL_dostring(L,
        "OBJ = setmetatable({}, {__close = function(_, e) print('PM close-obj', e); error('closer-boom') end})");
    if (st) { printf("PM setup-error: %s\n", lua_tostring(L, -1)); return; }
    lua_pushcfunction(L, pm_marked_driver);
    lua_setglobal(L, "marked_driver");
    st = luaL_dostring(L,
        "local main_co = coroutine.running()\n"
        "local a <close> = setmetatable({}, {__close = function(_, e) print('PM close-a', e) end})\n"
        "local ok, err = pcall(function()\n"
        "  local b <close> = setmetatable({}, {__close = function(_, e) print('PM close-b', e) end})\n"
        "  local rok, rerr = pcall(marked_driver, OBJ)\n"
        "  print('PM unreachable-inner', rok, rerr)\n"
        "end)\n"
        "print('PM inner-pcall', ok, err)\n"
        "local co2 = coroutine.create(function() print('PM main-status-from-co', coroutine.status(main_co)) end)\n"
        "print('PM co2-resume', coroutine.resume(co2))\n"
        "print('PM chunk-continues')\n");
    printf("PM dostring st=%d main-status=%d co-status=%d\n", st,
           lua_status(L), pm_co ? lua_status(pm_co) : -1);
    lua_close(L);
}

/* ------------------------------------------------------------------ */
/* GC: finalizer re-entry — the __gc does the cross-thread truncation   */
/* ------------------------------------------------------------------ */

static lua_State *gc_target;

static int gc_cross(lua_State *L) {
    (void)L;
    lua_settop(gc_target, 0);
    return 0;
}

static void case_gc(void) {
    lua_State *L = luaL_newstate();
    int nres = 0, st;
    luaL_openlibs(L);
    st = luaL_dostring(L, OBJ_SETUP);
    if (st) { printf("GC setup-error: %s\n", lua_tostring(L, -1)); return; }
    gc_target = lua_newthread(L);
    /* keep the target rooted for the whole case (the full collection
     * below must not collect the suspended coroutine itself) */
    lua_pushthread(gc_target);
    lua_xmove(gc_target, L, 1);
    lua_setglobal(L, "GCTARGET");
    lua_pushcfunction(gc_target, target_body);
    lua_getglobal(gc_target, "OBJ");
    st = lua_resume(gc_target, L, 1, &nres);
    printf("GC target-first st=%d\n", st);
    /* a finalizable userdata whose __gc performs the cross-thread
     * truncation; dropped so the full collection below finalizes it */
    lua_newuserdata(L, 0);
    lua_newtable(L);
    lua_pushcfunction(L, gc_cross);
    lua_setfield(L, -2, "__gc");
    lua_setmetatable(L, -2);
    lua_pop(L, 1);
    lua_gc(L, LUA_GCCOLLECT, 0);
    /* the closer error degraded to the "error in __gc" warning (stderr,
     * printed by luaL_newstate's warnfon on both runtimes); the cycle
     * completed: the target is dead and the VM stays usable */
    printf("GC after-gc target-status=%d\n", lua_status(gc_target));
    st = luaL_dostring(L, "return 2 + 2");
    printf("GC post-gc dostring st=%d val=%d\n", st,
           st == 0 ? (int)lua_tointeger(L, -1) : -1);
    lua_close(L);
}

/* ------------------------------------------------------------------ */

int main(void) {
    /* C printf and Lua print must interleave in program order on both
     * runtimes: unbuffered stdout (the zig print builtin writes each
     * line straight to the fd; PUC's print shares this FILE*). */
    setvbuf(stdout, NULL, _IONBF, 0);
    case_p1();
    case_p2();
    case_p3();
    case_c1();
    case_c2();
    case_c3();
    case_c4();
    case_c5();
    case_c8();
    case_pm();
    case_gc();
    printf("40_maindestined_transport: ALL DONE\n");
    return 0;
}
