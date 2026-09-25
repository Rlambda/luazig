/* 29_finalizer_oom_queue — nested emergency GC inside __gc + pending-queue
** preservation.
**
** Semantic class (PUC lgc.c singlestep GCScallfin arm + lmem.c tryagain):
** a real allocation failure inside a __gc body may run a NESTED emergency
** collection (singlestep clears gcstopem before GCTM, so cantryagain holds
** and the allocator retry runs luaC_fullgc(L, 1)). That nested collection
** never runs finalizers (GCScallfin guard !g->gcemergency) and may finish
** the OUTER cycle's state machine at pause while tobefnz still holds
** pending finalizers. What happens to the rest of the queue depends on the
** drain site, and every site is a separate contract:
**
**   - paced incremental pass (fullinc's runtilstate(GCSpause)): the outer
**     pass re-reads gcstate, sees pause, and STOPS — the remaining pending
**     finalizers run in a LATER cycle (or at close), not prematurely here;
**   - direct drain loops (callallpendingfinalizers at gen-mode
**     finishgencycle and at luaC_freeallobjects/close): `while (tobefnz)
**     GCTM(L)` re-reads the head and CONTINUES — the rest of the queue runs
**     in the SAME drain even though the body failed on real OOM.
**
** So "the finalizer failed on out-of-memory" alone determines nothing: the
** phase (which drain site owns the queue) does. A retry that SUCCEEDS after
** the emergency collection leaves the body error-free, and an emergency
** collection outside any __gc runs no finalizer at all.
**
** Every case is differential: PUC 5.5 and luazig must print byte-identical
** lines (lua_gc return codes, finalizer call counts and payload order,
** warning counts/pieces, allocator denials). Payloads prove object
** identity: each finalizer records the payload byte of the object it saw,
** so a preserved pending object is shown to be finalized exactly once, in
** its own cycle, with no double or late close. The drain order is PUC's
** tobefnz order — same-batch finalizable objects run NEWEST first (the
** list is fed from the creation-ordered allgc chain head-first), so a
** two-object batch drains as payload "2" then "1".
**
** Determinism: fixed labels/values only; the strict-frozen window denies
** every request and covers exactly one warning emission (warnf unfreezes
** on the closing piece); the deny-once window refuses a single request so
** the emergency retry succeeds and the body completes without any error.
**
** q8-q11 add the generational OLD-finalizable class: an object made OLD
** by GCGEN + a full collect (PUC fullgen → atomic2gen sweep2old), its
** root dropped, plus a young finalizable batch. The young minor's direct
** drain hosts the nested emergency collection, which in PUC is ALWAYS a
** full cycle (luaC_fullgc → fullgen → minor2inc clears the finobjold1/
** finobjsur/finobjrold cutoffs, lgc.c:1306-1314): it separates the OLD
** finalizable too (appending at the tobefnz tail, after the young batch)
** and applies full weak/ephemeron semantics — no minor age filter. The
** outer direct drain re-reads the head and runs the whole queue in the
** same window: young newest-first, then the OLD object.
*/
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* Strict freeze: every request denied while set (the warning's closing
** piece clears it). Deny-once: the next single request is denied, everything
** after it succeeds (the emergency retry path). */
static int frozen = 0;
static int deny_once = 0;
static int freeze_hits = 0;

static void *lalloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    (void)ud;
    (void)osize;
    if (nsize == 0) { free(ptr); return NULL; }
    if (deny_once) { deny_once = 0; freeze_hits++; return NULL; }
    if (frozen) { freeze_hits++; return NULL; }
    return realloc(ptr, nsize);
}

/* Non-allocating warning capture: piece count + closing-piece count. The
** closing piece (tocont==0) ends a strict-frozen window. */
static char warn_buf[1024];
static int  warn_pieces;
static int  warn_ends;

static void warnf(void *ud, const char *msg, int tocont) {
    (void)ud;
    warn_pieces++;
    if (!tocont) { warn_ends++; frozen = 0; }
    size_t used = strlen(warn_buf);
    size_t avail = sizeof(warn_buf) - used - 1;
    strncat(warn_buf, msg, avail);
}

static void warn_reset(void) {
    warn_buf[0] = '\0';
    warn_pieces = 0;
    warn_ends = 0;
}

/* Finalizer observations: call count and the payload byte of each
** finalized object (object identity). */
static int calls = 0;
static char seen[16];
static int seen_n = 0;

static void note_seen(lua_State *L) {
    unsigned char *p = (unsigned char *)lua_touserdata(L, 1);
    seen[seen_n++] = p ? (char)('0' + *p) : '?';
}

/* First call strictly freezes the allocator and requests 1 MiB — a REAL
** allocation failure: the denial, the nested emergency collection, and the
** retry all happen inside the frozen window; the closing warning piece
** unfreezes. Later calls just count. */
static int fin_oom(lua_State *L) {
    calls++;
    note_seen(L);
    if (calls == 1) {
        frozen = 1;
        lua_newuserdatauv(L, 1u << 20, 0);  /* denied, retried, denied */
        return 0;  /* unreachable */
    }
    return 0;
}

/* Deny-once variant: the single denial runs the nested emergency
** collection and the retried request SUCCEEDS — the body completes with
** no error and no warning at all. */
static int fin_oom_retry_ok(lua_State *L) {
    calls++;
    note_seen(L);
    if (calls == 1) {
        deny_once = 1;
        lua_newuserdatauv(L, 1u << 20, 0);  /* denied once, retry succeeds */
        return 0;
    }
    return 0;
}

/* Plain RuntimeError body (string object): no allocation failure, no
** emergency collection — the drain site alone decides continuation. */
static int fin_err(lua_State *L) {
    calls++;
    note_seen(L);
    lua_pushstring(L, "boom");
    return lua_error(L);
}

static int fin_ok(lua_State *L) {
    calls++;
    note_seen(L);
    return 0;
}

/* C function that hits the strictly frozen allocator OUTSIDE any
** finalizer: the emergency retry runs from the plain allocation path. */
static int c_bigalloc(lua_State *L) {
    lua_newuserdatauv(L, 1u << 20, 0);
    return 0;  /* unreachable under the freeze */
}

static void reset_case(void) {
    frozen = 0;
    deny_once = 0;
    freeze_hits = 0;
    calls = 0;
    seen_n = 0;
    warn_reset();
}

static lua_State *case_state(void) {
    lua_State *L = lua_newstate(lalloc, NULL, 0);
    if (!L) { printf("FAIL newstate\n"); exit(2); }
    lua_setwarnf(L, warnf, NULL);
    return L;
}

/* Arm `n` userdata objects with __gc = fin, payloads `first`..
** `first+n-1`, then drop them all as garbage. */
static void arm_garbage_at(lua_State *L, lua_CFunction fin, int first, int n) {
    lua_newtable(L);
    lua_pushcfunction(L, fin);
    lua_setfield(L, -2, "__gc");
    int mt = lua_gettop(L);
    for (int i = 0; i < n; ++i) {
        lua_newuserdatauv(L, 1, 0);
        *(unsigned char *)lua_touserdata(L, -1) = (unsigned char)(first + i);
        lua_pushvalue(L, mt);
        lua_setmetatable(L, -2);
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
}

static void arm_garbage(lua_State *L, lua_CFunction fin, int n) {
    arm_garbage_at(L, fin, 1, n);
}

/* One finalizable userdata with the given payload, left on the stack. */
static void arm_one(lua_State *L, lua_CFunction fin, int payload) {
    lua_newuserdatauv(L, 1, 0);
    *(unsigned char *)lua_touserdata(L, -1) = (unsigned char)payload;
    lua_newtable(L);
    lua_pushcfunction(L, fin);
    lua_setfield(L, -2, "__gc");
    lua_setmetatable(L, -2);
}

/* The q8 shape: an OLD finalizable (payload 9) aged by GCGEN + a full
** collect with its root dropped, plus a young finalizable batch (1..n).
** Runs one LUA_GCSTEP (the generational minor) and returns its rc. */
static int gen_old_plus_young_step(lua_State *L, lua_CFunction fin, int n) {
    arm_one(L, fin, 9);
    lua_setglobal(L, "old");
    lua_gc(L, LUA_GCGEN, 0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_pushnil(L);
    lua_setglobal(L, "old");
    arm_garbage(L, fin, n);
    if (!lua_checkstack(L, 100)) exit(3);
    return lua_gc(L, LUA_GCSTEP, 0);
}

static void drain_seen(void) {
    seen[seen_n] = '\0';
}

static int fail(const char *what) {
    printf("FAIL %s\n", what);
    return 1;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== 29_finalizer_oom_queue ===\n");

    /* q1: the paced incremental pass. Two pending finalizers; the first
    ** body hits a real OOM, the nested emergency collection finishes the
    ** outer cycle at pause with the second object still pending — the
    ** first collect stops at ONE call, and the preserved object runs in
    ** the SECOND collect, exactly once, with no late close. */
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_oom, 2);
        if (!lua_checkstack(L, 100)) return 3;
        int rc1 = lua_gc(L, LUA_GCCOLLECT, 0);
        drain_seen();
        printf("q1 first: rc=%d calls=%d seen=%s pieces=%d ends=%d denied=%d frozen=%d\n",
               rc1, calls, seen, warn_pieces, warn_ends, freeze_hits, frozen);
        if (rc1 != 0) return fail("q1 rc1");
        if (calls != 1 || seen_n != 1 || seen[0] != '2') return fail("q1 first drain");
        if (warn_pieces != 5 || warn_ends != 1) return fail("q1 warning pieces");
        if (freeze_hits != 2) return fail("q1 denials");
        if (frozen != 0) return fail("q1 unfreeze");
        warn_reset();
        int rc2 = lua_gc(L, LUA_GCCOLLECT, 0);
        drain_seen();
        printf("q1 second: rc=%d calls=%d seen=%s pieces=%d ends=%d denied=%d\n",
               rc2, calls, seen, warn_pieces, warn_ends, freeze_hits);
        if (rc2 != 0 || calls != 2 || strcmp(seen, "21") != 0)
            return fail("q1 second drain");
        if (warn_pieces != 0 || warn_ends != 0) return fail("q1 second warning");
        lua_close(L);
        printf("q1 close: calls=%d seen=%s pieces=%d ends=%d denied=%d\n",
               calls, seen, warn_pieces, warn_ends, freeze_hits);
        if (calls != 2 || strcmp(seen, "21") != 0) return fail("q1 close drain");
    }

    /* q2: RuntimeError control (no emergency involved). Two erroring
    ** bodies in the paced pass: both warnings fire and the SAME cycle
    ** drains both — an error object alone never defers the queue. */
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_err, 2);
        if (!lua_checkstack(L, 100)) return 3;
        int rc1 = lua_gc(L, LUA_GCCOLLECT, 0);
        drain_seen();
        printf("q2 first: rc=%d calls=%d seen=%s pieces=%d ends=%d denied=%d\n",
               rc1, calls, seen, warn_pieces, warn_ends, freeze_hits);
        if (rc1 != 0 || calls != 2 || strcmp(seen, "21") != 0)
            return fail("q2 first drain");
        if (warn_pieces != 10 || warn_ends != 2) return fail("q2 warnings");
        warn_reset();
        int rc2 = lua_gc(L, LUA_GCCOLLECT, 0);
        lua_close(L);
        drain_seen();
        printf("q2 second+close: rc=%d calls=%d seen=%s pieces=%d ends=%d\n",
               rc2, calls, seen, warn_pieces, warn_ends);
        if (rc2 != 0 || calls != 2 || strcmp(seen, "21") != 0)
            return fail("q2 second drain");
    }

    /* q3: emergency collection with NO finalizers. One finalizable object
    ** is pending as garbage; the strictly frozen 1 MiB request OUTSIDE any
    ** __gc runs the emergency retry; the emergency collection separates
    ** the pending object into tobefnz but runs NO finalizer (gcemergency
    ** guard) — it runs in the next full collect, exactly once. The
    ** cfunction is pushed BEFORE the freeze: the frozen window must
    ** contain only the failing request, its emergency retry, and the
    ** error transport. Denial COUNTS are deliberately not printed here:
    ** under a total freeze the first failing allocation differs by
    ** construction (PUC's userdata is one header+payload block; luazig
    ** allocates the header first), and the outside-__gc error transport
    ** adds luazig's documented small denied attempts — a separate
    ** allocation-shape class, not the queue contract tested here. */
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_ok, 1);
        lua_pushcfunction(L, c_bigalloc);
        frozen = 1;
        int rc = lua_pcall(L, 0, 0, 0);
        frozen = 0;
        printf("q3 bigalloc: rc=%d calls=%d pieces=%d ends=%d\n",
               rc, calls, warn_pieces, warn_ends);
        if (rc != LUA_ERRMEM) return fail("q3 bigalloc rc");
        if (calls != 0) return fail("q3 finalizer ran during emergency");
        int rc2 = lua_gc(L, LUA_GCCOLLECT, 0);
        lua_close(L);
        drain_seen();
        printf("q3 collect+close: rc=%d calls=%d seen=%s pieces=%d ends=%d\n",
               rc2, calls, seen, warn_pieces, warn_ends);
        if (rc2 != 0 || calls != 1 || seen[0] != '1') return fail("q3 post drain");
    }

    /* q4: GCSTOP/GCSTEP windows around the preserved queue. After the OOM
    ** collect leaves the second object pending, a user stop must not run
    ** it; a single forced step advances the state machine without reaching
    ** the pending finalizer; after restart the next collect drains it. */
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_oom, 2);
        if (!lua_checkstack(L, 100)) return 3;
        int rc1 = lua_gc(L, LUA_GCCOLLECT, 0);
        if (rc1 != 0 || calls != 1) return fail("q4 first drain");
        warn_reset();
        lua_gc(L, LUA_GCSTOP, 0);
        int rs = lua_gc(L, LUA_GCSTEP, 0);
        drain_seen();
        printf("q4 stop+step: steprc=%d calls=%d seen=%s pieces=%d ends=%d\n",
               rs, calls, seen, warn_pieces, warn_ends);
        if (calls != 1) return fail("q4 step ran pending finalizer");
        lua_gc(L, LUA_GCRESTART, 0);
        int rc2 = lua_gc(L, LUA_GCCOLLECT, 0);
        lua_close(L);
        drain_seen();
        printf("q4 restart+collect+close: rc=%d calls=%d seen=%s pieces=%d ends=%d denied=%d\n",
               rc2, calls, seen, warn_pieces, warn_ends, freeze_hits);
        if (rc2 != 0 || calls != 2 || strcmp(seen, "21") != 0)
            return fail("q4 post-restart drain");
    }

    /* q5: generational mode. The young-collection drain
    ** (callallpendingfinalizers) is a direct while-loop over tobefnz: the
    ** first body's real OOM runs its nested emergency collection, and the
    ** drain CONTINUES in the same window — the second finalizer runs in
    ** the SAME minor cycle, unlike the paced incremental pass of q1. */
    {
        reset_case();
        lua_State *L = case_state();
        lua_gc(L, LUA_GCGEN, 0);
        arm_garbage(L, fin_oom, 2);
        if (!lua_checkstack(L, 100)) return 3;
        int r1 = lua_gc(L, LUA_GCSTEP, 0);
        drain_seen();
        printf("q5 step1: rc=%d calls=%d seen=%s pieces=%d ends=%d denied=%d\n",
               r1, calls, seen, warn_pieces, warn_ends, freeze_hits);
        int r2 = lua_gc(L, LUA_GCSTEP, 0);
        int r3 = lua_gc(L, LUA_GCSTEP, 0);
        drain_seen();
        printf("q5 step2+3: rc=%d/%d calls=%d seen=%s pieces=%d ends=%d denied=%d\n",
               r2, r3, calls, seen, warn_pieces, warn_ends, freeze_hits);
        if (calls != 2 || strcmp(seen, "21") != 0) return fail("q5 gen drain");
        if (warn_pieces != 5 || warn_ends != 1) return fail("q5 warning pieces");
        if (freeze_hits != 2) return fail("q5 denials");
        warn_reset();
        int rc = lua_gc(L, LUA_GCCOLLECT, 0);
        lua_close(L);
        drain_seen();
        printf("q5 collect+close: rc=%d calls=%d seen=%s pieces=%d ends=%d\n",
               rc, calls, seen, warn_pieces, warn_ends);
        if (rc != 0 || calls != 2 || strcmp(seen, "21") != 0)
            return fail("q5 post drain");
    }

    /* q6: the shutdown drain. Finalizers still pending at lua_close run
    ** through callallpendingfinalizers under luaC_freeallobjects — the
    ** same direct while-loop contract as q5: the first body's real OOM
    ** runs its nested emergency collection (roots still intact at this
    ** point of the close sequence) and the drain continues — both
    ** finalizers run during the close, exactly once each. No checkstack
    ** pre-growth and no denial counts here: a pre-grown stack makes PUC's
    ** GCTM pcall error path shrink the emptied stack (an extra denied
    ** realloc of the stack-management class), and luazig's close-path
    ** emergency cycle grows an auxiliary gray list through the state
    ** allocator (PUC cycles are allocation-free intrusive lists) — both
    ** are separate allocation-shape classes, not the queue contract. */
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_oom, 2);
        lua_close(L);
        drain_seen();
        printf("q6 close: calls=%d seen=%s pieces=%d ends=%d\n",
               calls, seen, warn_pieces, warn_ends);
        if (calls != 2 || strcmp(seen, "21") != 0) return fail("q6 close drain");
        if (warn_pieces != 5 || warn_ends != 1) return fail("q6 warning pieces");
        if (frozen != 0) return fail("q6 unfreeze");
    }

    /* q7: the emergency retry SUCCEEDS. The deny-once allocator refuses
    ** the 1 MiB request exactly once; the nested emergency collection runs
    ** inside the body, the retried request succeeds, and the body completes
    ** with NO error and NO warning. The rest of the queue still defers to
    ** the next cycle: the nested emergency collection finished the outer
    ** cycle's state machine at pause, and the outer pass honors the
    ** changed state — deferral is driven by the nested CYCLE, not by the
    ** body's error class (the sharpest contrast with q2, where errors
    ** without a nested cycle drain in-place). */
    {
        reset_case();
        lua_State *L = case_state();
        arm_garbage(L, fin_oom_retry_ok, 2);
        if (!lua_checkstack(L, 100)) return 3;
        int rc1 = lua_gc(L, LUA_GCCOLLECT, 0);
        drain_seen();
        printf("q7 first: rc=%d calls=%d seen=%s pieces=%d ends=%d denied=%d\n",
               rc1, calls, seen, warn_pieces, warn_ends, freeze_hits);
        if (rc1 != 0 || calls != 1 || seen_n != 1 || seen[0] != '2')
            return fail("q7 first drain");
        if (warn_pieces != 0 || warn_ends != 0) return fail("q7 no warning expected");
        if (freeze_hits != 1) return fail("q7 single denial");
        int rc2 = lua_gc(L, LUA_GCCOLLECT, 0);
        lua_close(L);
        drain_seen();
        printf("q7 second+close: rc=%d calls=%d seen=%s pieces=%d ends=%d\n",
               rc2, calls, seen, warn_pieces, warn_ends);
        if (rc2 != 0 || calls != 2 || strcmp(seen, "21") != 0)
            return fail("q7 second drain");
    }

    /* q8: the OLD finalizable in the generational minor drain. The old
    ** object (9) is aged by GCGEN + a full collect, its root dropped;
    ** the young pair (1, 2) is garbage. The step's minor separates only
    ** the young pair (PUC finobjold1 cutoff); the drain runs 2 first,
    ** whose body hits a real OOM — the nested emergency collection is a
    ** FULL cycle (fullgen → minor2inc clears the cutoffs), so it
    ** separates the OLD finalizable too and appends it at the tobefnz
    ** tail; the outer direct drain re-reads the head and finishes the
    ** whole queue in the same window: 2, 1, then 9. Later steps and the
    ** close change nothing — exactly once, no late close. */
    {
        reset_case();
        lua_State *L = case_state();
        int rc1 = gen_old_plus_young_step(L, fin_oom, 2);
        drain_seen();
        printf("q8 step1: rc=%d calls=%d seen=%s pieces=%d ends=%d denied=%d frozen=%d\n",
               rc1, calls, seen, warn_pieces, warn_ends, freeze_hits, frozen);
        if (rc1 != 0) return fail("q8 step1 rc");
        if (calls != 3 || strcmp(seen, "219") != 0) return fail("q8 step1 drain");
        if (warn_pieces != 5 || warn_ends != 1) return fail("q8 warning pieces");
        if (freeze_hits != 2) return fail("q8 denials");
        if (frozen != 0) return fail("q8 unfreeze");
        warn_reset();
        for (int i = 2; i <= 4; ++i) {
            int rc = lua_gc(L, LUA_GCSTEP, 0);
            drain_seen();
            printf("q8 step%d: rc=%d calls=%d seen=%s pieces=%d ends=%d\n",
                   i, rc, calls, seen, warn_pieces, warn_ends);
            if (rc != 0 || calls != 3 || strcmp(seen, "219") != 0)
                return fail("q8 later step changed state");
        }
        lua_close(L);
        drain_seen();
        printf("q8 close: calls=%d seen=%s pieces=%d ends=%d\n",
               calls, seen, warn_pieces, warn_ends);
        if (calls != 3 || strcmp(seen, "219") != 0) return fail("q8 close drain");
    }

    /* q9: the OLD finalizable in a weak-VALUE graph. The old object is
    ** dead (root dropped; only a weak table references it); a strongly
    ** rooted control table sits in the same weak table. The outer minor
    ** keeps both (the old object is black, and its weak table is old —
    ** not re-traversed by a minor). The nested emergency FULL cycle
    ** applies full weak semantics with no age filter: the dead old
    ** value is cleared from the weak table, the live control survives,
    ** and the old object is separated and finalized exactly once, after
    ** the young pair. */
    {
        reset_case();
        lua_State *L = case_state();
        lua_newtable(L);                       /* w */
        lua_newtable(L);                       /* w's mt: __mode="v" */
        lua_pushstring(L, "v");
        lua_setfield(L, -2, "__mode");
        lua_setmetatable(L, -2);
        lua_newtable(L);                       /* live control */
        lua_setglobal(L, "live");
        lua_getglobal(L, "live");
        lua_setfield(L, -2, "live");           /* w.live = live */
        lua_setglobal(L, "w");
        arm_one(L, fin_oom, 9);
        lua_setglobal(L, "old");
        lua_gc(L, LUA_GCGEN, 0);
        lua_gc(L, LUA_GCCOLLECT, 0);
        lua_getglobal(L, "w");
        lua_getglobal(L, "old");
        lua_setfield(L, -2, "old");            /* w.old = old (weak value) */
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_setglobal(L, "old");               /* root dropped */
        arm_garbage(L, fin_oom, 2);
        if (!lua_checkstack(L, 100)) return 3;
        int rc = lua_gc(L, LUA_GCSTEP, 0);
        drain_seen();
        printf("q9 step1: rc=%d calls=%d seen=%s pieces=%d ends=%d denied=%d\n",
               rc, calls, seen, warn_pieces, warn_ends, freeze_hits);
        if (rc != 0) return fail("q9 step1 rc");
        if (calls != 3 || strcmp(seen, "219") != 0) return fail("q9 step1 drain");
        lua_getglobal(L, "w");
        lua_getfield(L, -1, "old");
        int old_cleared = lua_isnil(L, -1);
        lua_getfield(L, -2, "live");
        int live_alive = !lua_isnil(L, -1);
        lua_pop(L, 3);
        printf("q9 weak: old_cleared=%d live_alive=%d\n", old_cleared, live_alive);
        if (!old_cleared) return fail("q9 dead old weak value not cleared");
        if (!live_alive) return fail("q9 live control lost");
        lua_close(L);
        drain_seen();
        printf("q9 close: calls=%d seen=%s\n", calls, seen);
        if (calls != 3 || strcmp(seen, "219") != 0) return fail("q9 close drain");
    }

    /* q10: the nested retry SUCCEEDS (deny-once). The single denial
    ** runs the same nested emergency FULL collection — the OLD
    ** finalizable is separated regardless of the body's eventual error
    ** class — and the retried request succeeds, so the body completes
    ** with NO error and NO warning. The whole queue still drains in
    ** the same window. */
    {
        reset_case();
        lua_State *L = case_state();
        int rc1 = gen_old_plus_young_step(L, fin_oom_retry_ok, 2);
        drain_seen();
        printf("q10 step1: rc=%d calls=%d seen=%s pieces=%d ends=%d denied=%d\n",
               rc1, calls, seen, warn_pieces, warn_ends, freeze_hits);
        if (rc1 != 0) return fail("q10 step1 rc");
        if (calls != 3 || strcmp(seen, "219") != 0) return fail("q10 step1 drain");
        if (warn_pieces != 0 || warn_ends != 0) return fail("q10 no warning expected");
        if (freeze_hits != 1) return fail("q10 single denial");
        lua_close(L);
        drain_seen();
        printf("q10 close: calls=%d seen=%s pieces=%d ends=%d\n",
               calls, seen, warn_pieces, warn_ends);
        if (calls != 3 || strcmp(seen, "219") != 0) return fail("q10 close drain");
    }

    /* q11: after the nested emergency returns, the collector keeps
    ** working. A rooted table survives the following minors AND a full
    ** collect; new young finalizable garbage is separated and drained
    ** by the next minor (exactly once, newest first); close adds
    ** nothing. */
    {
        reset_case();
        lua_State *L = case_state();
        int rc1 = gen_old_plus_young_step(L, fin_oom, 2);
        drain_seen();
        printf("q11 step1: rc=%d calls=%d seen=%s pieces=%d ends=%d\n",
               rc1, calls, seen, warn_pieces, warn_ends);
        if (rc1 != 0 || calls != 3 || strcmp(seen, "219") != 0)
            return fail("q11 step1 drain");
        warn_reset();
        lua_newtable(L);
        lua_pushinteger(L, 42);
        lua_setfield(L, -2, "x");
        lua_setglobal(L, "keep");
        arm_garbage_at(L, fin_ok, 3, 2);       /* young 3, 4 */
        int rc2 = lua_gc(L, LUA_GCSTEP, 0);
        drain_seen();
        printf("q11 step2: rc=%d calls=%d seen=%s pieces=%d ends=%d\n",
               rc2, calls, seen, warn_pieces, warn_ends);
        if (rc2 != 0 || calls != 5 || strcmp(seen, "21943") != 0)
            return fail("q11 next minor drain");
        int rc3 = lua_gc(L, LUA_GCCOLLECT, 0);
        lua_getglobal(L, "keep");
        lua_getfield(L, -1, "x");
        int keep_ok = (lua_isinteger(L, -1) && lua_tointeger(L, -1) == 42);
        lua_pop(L, 2);
        drain_seen();
        printf("q11 collect: rc=%d calls=%d seen=%s keep_ok=%d\n",
               rc3, calls, seen, keep_ok);
        if (rc3 != 0 || calls != 5 || strcmp(seen, "21943") != 0)
            return fail("q11 full collect drain");
        if (!keep_ok) return fail("q11 rooted table lost");
        lua_close(L);
        drain_seen();
        printf("q11 close: calls=%d seen=%s\n", calls, seen);
        if (calls != 5 || strcmp(seen, "21943") != 0) return fail("q11 close drain");
    }

    printf("=== 29_finalizer_oom_queue DONE ===\n");
    return 0;
}
