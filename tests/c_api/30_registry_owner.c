/*
** 30_registry_owner.c — differential tests for the unified registry/globals
** owner: the registry lives in a single Value slot (PUC G->l_registry,
** lstate.h) populated eagerly at state creation (PUC init_registry,
** lstate.c:186-204: registry[1]=false, [2]=globals, [3]=mainthread), and the
** current globals table is registry[LUA_RIDX_GLOBALS] read once per call
** (PUC getGlobalTable, lapi.c:691-696).
**
** This suite is in DIFF_TESTS: output must be byte-identical when linked
** against PUC Lua 5.5 (30_registry_owner-puc) and against luazig
** (30_registry_owner).
**
** Cases:
**   A: RIDX population — rawgeti(REG,1)=false, (REG,2)=table, (REG,3)=thread
**   B: lua_pushglobaltable (macro = rawgeti(REG, LUA_RIDX_GLOBALS))
**   C: RIDX[2] replacement — getglobal/setglobal read/write the CURRENT
**      registry[2] table (review_cidx2_globals 73/91 class)
**   D: chunk env — a chunk loaded BEFORE the replacement keeps its captured
**      _ENV; a chunk loaded AFTER the replacement gets the new table
**      (PUC lua_load: env = registry[2] at load time)
**   E: metamethods — getglobal/setglobal consult __index/__newindex on the
**      globals metatable (PUC auxgetstr/auxsetstr run the full
**      luaV_finishget/luaV_finishset path)
**   F: registry slot overwrite table/nil/number via lua_copy(x, REGISTRY)
**      (PUC lapi.c:262-263 plain setobj without a barrier): lua_type
**      reflects the slot value; getglobal/getfield after a non-table slot
**      raises "attempt to index a nil/number value"; a table in the slot
**      survives LUA_GCCOLLECT and stays usable; restoring the original
**      registry returns getglobal to working order
**   G: GC-proof — a fresh table stored into the slot between GC steps
**      survives the cycle and stays usable (start-of-cycle root mark +
**      atomic re-mark, PUC lgc.c:1553)
**
** Forms deliberately NOT exercised (PUC release UB / api_check class):
** raw access (rawgeti/rawget/rawset*) on the registry after a non-table
** overwrite of the slot, lua_close with a non-table in the slot,
** lua_getglobal after a non-table in the SLOT (getGlobalTable's
** unconditional hvalue of G->l_registry), and rawseti(REGISTRY,
** LUA_RIDX_GLOBALS, nil) followed by getglobal — PUC 5.5's nil store
** empties the array slot and luaH_getint then leaves getGlobalTable's
** out-value UNINITIALIZED (ltable.c:959-969), a layout-dependent UB
** (reproduced: ~1/7 runs SIGSEGV on PUC). luazig is a safe superset for
** all of these (deterministic "attempt to index a nil value").
*/
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"

static int fail(const char *what) {
    fprintf(stderr, "FAIL: %s\n", what);
    return 1;
}

/* __index metamethod for section E: returns 42 for every absent key. */
static int index_meta(lua_State *L) {
    (void)L;
    lua_pushinteger(L, 42);
    return 1;
}

/* Protected probes for section F: the operation inside must raise the
** standard index error instead of crashing (the C function runs under
** lua_pcall, so the raise unwinds to the pcall boundary). Only getfield
** on the registry slot is a valid raising form after a non-table slot —
** lua_getglobal dereferences the slot unconditionally (PUC getGlobalTable
** hvalue, release UB) and is deliberately not probed here. */
static int getfield_probe(lua_State *L) {
    (void)lua_getfield(L, LUA_REGISTRYINDEX, "x");
    return 0;
}

/* Protected getglobal probe for a non-table registry[LUA_RIDX_GLOBALS]:
** the slot itself still holds the registry table, so PUC's getGlobalTable
** reads a non-table gt and auxgetstr raises the standard index error. */
static int getglobal_probe(lua_State *L) {
    (void)lua_getglobal(L, "x");
    return 0;
}

static void probe(lua_State *L, const char *tag, lua_CFunction f) {
    lua_pushcfunction(L, f);
    int st = lua_pcall(L, 0, 0, 0);
    if (st == 0) {
        printf("%s status=0 msg=OK\n", tag);
    } else {
        printf("%s status=%d msg=%s\n", tag, st, lua_tostring(L, -1));
        lua_pop(L, 1);
    }
}

int main(void) {
    lua_State *L = luaL_newstate();
    if (!L) return 2;

    /* ── A: RIDX population (PUC init_registry) ── */
    lua_rawgeti(L, LUA_REGISTRYINDEX, 1);
    printf("A1 ridx1_type=%d\n", lua_type(L, -1));
    printf("A2 ridx1_false=%d\n", lua_toboolean(L, -1));
    lua_pop(L, 1);
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
    printf("A3 ridx2_type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
    printf("A4 ridx3_type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);

    /* ── B: lua_pushglobaltable = rawgeti(REG, RIDX_GLOBALS) ── */
    lua_pushglobaltable(L);
    printf("B1 pushglobaltable_type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);

    /* ── C+D setup: save the original globals, mark it, load a chunk that
    ** captures the CURRENT _ENV, then replace registry[2]. ── */
    lua_pushglobaltable(L);
    int orig_globals = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_pushinteger(L, 7);
    lua_setglobal(L, "oldmarker");
    if (luaL_loadstring(L, "return oldmarker, written")) return fail("load chunk_before");
    int chunk_before = luaL_ref(L, LUA_REGISTRYINDEX);

    /* ── C: RIDX[2] replacement ── */
    lua_newtable(L);
    lua_pushinteger(L, 73);
    lua_setfield(L, -2, "probe");
    lua_rawseti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
    lua_getglobal(L, "probe");
    printf("C1 getglobal_probe=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
    lua_pushinteger(L, 91);
    lua_setglobal(L, "written");
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
    lua_getfield(L, -1, "written");
    printf("C2 reg2_written=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 2);
    /* The write went to the replacement, not to the saved original. */
    lua_rawgeti(L, LUA_REGISTRYINDEX, orig_globals);
    lua_getfield(L, -1, "written");
    printf("C3 oldglobals_written_type=%d\n", lua_type(L, -1));
    lua_pop(L, 2);

    /* ── D: chunk env before/after the replacement ── */
    if (luaL_loadstring(L, "return oldmarker, written")) return fail("load chunk_after");
    if (lua_pcall(L, 0, 2, 0)) return fail("pcall chunk_after");
    printf("D1 chunk_after=%lld,%lld\n",
        (long long)lua_tointeger(L, -2), (long long)lua_tointeger(L, -1));
    lua_pop(L, 2);
    lua_rawgeti(L, LUA_REGISTRYINDEX, chunk_before);
    if (lua_pcall(L, 0, 2, 0)) return fail("pcall chunk_before");
    printf("D2 chunk_before=%lld,%lld\n",
        (long long)lua_tointeger(L, -2), (long long)lua_tointeger(L, -1));
    lua_pop(L, 2);

    /* A non-table in registry[2] surfaces as the standard index error from
    ** getglobal (PUC auxgetstr on the non-table gt). Only the NUMBER form
    ** is differential-safe: a nil store empties PUC 5.5's array slot and
    ** luaH_getint then leaves getGlobalTable's out-value uninitialized
    ** (ltable.c:959-969) — release UB, excluded (see the header). */
    lua_pushnumber(L, 3.5);
    lua_rawseti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
    probe(L, "C6 getglobal_number_ridx2", getglobal_probe);

    /* Restore the original globals and drop the refs. */
    lua_rawgeti(L, LUA_REGISTRYINDEX, orig_globals);
    lua_rawseti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
    luaL_unref(L, LUA_REGISTRYINDEX, chunk_before);
    luaL_unref(L, LUA_REGISTRYINDEX, orig_globals);
    lua_getglobal(L, "oldmarker");
    printf("C4 restored_oldmarker=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
    lua_getglobal(L, "probe");
    printf("C5 restored_probe_type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);

    /* ── E: metamethods on the globals table ── */
    lua_pushglobaltable(L);                  /* globals below the metatable */
    lua_newtable(L);                         /* mt */
    lua_pushcfunction(L, index_meta);
    lua_setfield(L, -2, "__index");
    lua_newtable(L);                         /* redirect target */
    lua_setfield(L, -2, "__newindex");
    if (lua_setmetatable(L, -2) != 1) return fail("setmetatable globals");
    lua_pop(L, 1);
    lua_getglobal(L, "zzz_absent");
    printf("E1 meta_getglobal=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
    /* Absent-key setglobal goes through __newindex (table redirect). */
    lua_pushinteger(L, 5);
    lua_setglobal(L, "qqq_redirect");
    lua_pushglobaltable(L);
    lua_pushstring(L, "qqq_redirect");
    lua_rawget(L, -2);
    printf("E2 globals_raw_qqq_type=%d\n", lua_type(L, -1));
    lua_pop(L, 2);
    lua_pushglobaltable(L);
    lua_getmetatable(L, -1);
    lua_getfield(L, -1, "__newindex");
    lua_pushstring(L, "qqq_redirect");
    if (lua_rawget(L, -2) != LUA_TNUMBER) return fail("rawget redirect");
    printf("E3 redir_qqq=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 4);
    /* Present-key setglobal takes the fastset path (no __newindex). */
    lua_pushinteger(L, 77);
    lua_setglobal(L, "oldmarker");
    lua_pushglobaltable(L);
    lua_pushstring(L, "oldmarker");
    if (lua_rawget(L, -2) != LUA_TNUMBER) return fail("rawget oldmarker");
    printf("E4 existing_fastset=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 2);
    /* Drop the metatable: absent keys read nil again. */
    lua_pushglobaltable(L);
    lua_pushnil(L);
    if (lua_setmetatable(L, -2) != 1) return fail("clear metatable");
    lua_pop(L, 1);
    lua_getglobal(L, "zzz_absent");
    printf("E5 no_meta_absent_type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);

    /* ── F: registry slot overwrite (lua_copy to/from REGISTRY) ── */
    /* Keep the original registry table on the stack for the restore. */
    lua_pushnil(L);
    lua_copy(L, LUA_REGISTRYINDEX, -1);
    printf("F0 slot_type=%d\n", lua_type(L, -1));
    int orig_reg = lua_gettop(L);

    lua_newtable(L);
    lua_pushinteger(L, 99);
    lua_setfield(L, -2, "keep");
    lua_copy(L, -1, LUA_REGISTRYINDEX);
    lua_pop(L, 1);
    printf("F1 slot_table_type=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    lua_gc(L, LUA_GCCOLLECT);
    printf("F2 after_gc_type=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    lua_pushnil(L);
    lua_copy(L, LUA_REGISTRYINDEX, -1);
    lua_getfield(L, -1, "keep");
    printf("F3 slot_keep=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 2);
    printf("F4 loaded_after_table=%d\n",
        lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED"));
    lua_pop(L, 1);

    lua_pushnil(L);
    lua_copy(L, -1, LUA_REGISTRYINDEX);
    lua_pop(L, 1);
    printf("F5 slot_nil_type=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    probe(L, "F6 getfield_after_nil", getfield_probe);

    lua_pushnumber(L, 3.5);
    lua_copy(L, -1, LUA_REGISTRYINDEX);
    lua_pop(L, 1);
    printf("F8 slot_number_type=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    probe(L, "F9 getfield_after_number", getfield_probe);

    lua_copy(L, orig_reg, LUA_REGISTRYINDEX);
    lua_pop(L, 1);
    lua_getglobal(L, "oldmarker");
    printf("F11 restored_oldmarker=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    /* ── G: GC-proof of a mid-cycle slot store ── */
    lua_gc(L, LUA_GCCOLLECT);
    for (int i = 0; i < 3; i++) (void)lua_gc(L, LUA_GCSTEP, 1);
    lua_pushnil(L);
    lua_copy(L, LUA_REGISTRYINDEX, -1);
    int orig_reg2 = lua_gettop(L);
    lua_newtable(L);
    lua_pushinteger(L, 1234);
    lua_setfield(L, -2, "marker");
    lua_copy(L, -1, LUA_REGISTRYINDEX);
    lua_pop(L, 1);
    lua_gc(L, LUA_GCCOLLECT);
    printf("G1 slot_type_after=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    lua_pushnil(L);
    lua_copy(L, LUA_REGISTRYINDEX, -1);
    lua_getfield(L, -1, "marker");
    printf("G2 slot_marker=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 2);
    lua_copy(L, orig_reg2, LUA_REGISTRYINDEX);
    lua_pop(L, 1);
    lua_getglobal(L, "oldmarker");
    printf("G3 restored_oldmarker=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    lua_close(L);
    printf("done\n");
    return 0;
}
