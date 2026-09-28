/*
** 31_env_capture.c — differential tests for the _ENV capture moment around
** a registry[LUA_RIDX_GLOBALS] replacement. PUC lua_load (lapi.c:1121-1141)
** sets the closure's first upvalue to registry[LUA_RIDX_GLOBALS] read ONCE
** AT LOAD TIME; Lua-level load keeps that default (lbaselib.c luaB_load
** passes envidx=0) and an explicit env argument overrides it afterwards
** via lua_setupvalue (load_aux, lbaselib.c:325-338).
**
** This suite is in DIFF_TESTS: output must be byte-identical when linked
** against PUC Lua 5.5 (31_env_capture-puc) and against luazig
** (31_env_capture).
**
** Layout: the original globals table (slot 1), a closure loaded BEFORE the
** replacement (slot 2) and a Lua-level load driver (slot 3) stay at fixed
** stack indices for the whole run, so no registry refs are needed and the
** stack discipline holds regardless of registry state.
**
** Cases:
**   S: setup — old globals envmark=7; save _G at slot 1; load the
**      before-closure and the driver (both capture the OLD _ENV)
**   H: four C entry points BEFORE the replacement → old env (7):
**      lua_load(reader), luaL_loadbufferx, luaL_loadstring, luaL_loadfilex
**   J1: Lua-level load with default env BEFORE → old globals; explicit env
**      argument wins regardless of RIDX[2]
**   M: RIDX[2] replaced with a fresh table (envmark=73): getglobal reads it,
**      setglobal writes it, the saved old table receives nothing
**   I: the same four C entry points AFTER the replacement → new env (73)
**   J2: Lua-level load with default env AFTER → new table (73); the
**      explicit env argument is still primary (55)
**   K: a real GC cycle (collect + steps + collect) with both environments
**      reachable: both closures keep working, getglobal still reads the
**      replacement, the old table is intact
**   L: restore the old RIDX[2]: getglobal and NEW loads (string and file)
**      are back to the old globals; EXISTING closures keep their captured
**      _ENV (the after-closure still reads 73, also across another GC);
**      Lua-level default load follows the restored RIDX[2], explicit env
**      stays primary
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#define CHUNK_FILE "31_env_capture_chunk.lua"

/* Fixed stack slots kept for the whole run. */
#define SLOT_ORIG   1  /* original globals table */
#define SLOT_BEFORE 2  /* closure loaded before the replacement */
#define SLOT_DRIVER 3  /* Lua-level load driver (old _ENV) */
#define SLOT_AFTER  4  /* closure loaded after the replacement */

static int fail(const char *what) {
    fprintf(stderr, "FAIL: %s\n", what);
    return 1;
}

/* lua_Reader serving the whole source string in one block. */
struct src_str {
    const char *s;
    size_t n;
    int done;
};

static const char *str_reader(lua_State *L, void *ud, size_t *sz) {
    struct src_str *r = (struct src_str *)ud;
    (void)L;
    if (r->done) return NULL;
    r->done = 1;
    *sz = r->n;
    return r->s;
}

/* Load "return envmark" through entry point ep (0=lua_load reader,
** 1=luaL_loadbufferx, 2=luaL_loadstring, 3=luaL_loadfilex). */
static int load_ep(lua_State *L, int ep) {
    static const char *src = "return envmark";
    switch (ep) {
    case 0: {
        struct src_str r = { src, strlen(src), 0 };
        return lua_load(L, str_reader, &r, "=direct", "t");
    }
    case 1:
        return luaL_loadbufferx(L, src, strlen(src), "=buffer", "t");
    case 2:
        return luaL_loadstring(L, src);
    case 3:
        return luaL_loadfilex(L, CHUNK_FILE, "t");
    }
    return -1;
}

/* Load through an entry point, call the closure, print its result. */
static void call_ep(lua_State *L, int ep, const char *label) {
    int rc = load_ep(L, ep);
    if (rc != 0) {
        printf("%s load=%d msg=%s\n", label, rc, lua_tostring(L, -1));
        lua_pop(L, 1);
        return;
    }
    int cr = lua_pcall(L, 0, 1, 0);
    if (cr != 0) {
        printf("%s call=%d msg=%s\n", label, cr, lua_tostring(L, -1));
        lua_pop(L, 1);
        return;
    }
    printf("%s=%lld\n", label, (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
}

/* Call the Lua-level load driver at SLOT_DRIVER: it runs
**   local env = {envmark = 55}
**   local f1 = load("return envmark")            -- default env
**   local f2 = load("return envmark", "n", "t", env)  -- explicit env
**   return (f1() or "nil") .. " " .. (f2() or "nil")
** and we print "<default> <explicit>". The driver's own _ENV is the old
** globals (loaded before the replacement), so `load` itself stays
** reachable no matter what RIDX[2] holds. */
static void call_driver(lua_State *L, const char *label) {
    lua_pushvalue(L, SLOT_DRIVER);
    int cr = lua_pcall(L, 0, 1, 0);
    if (cr != 0) {
        printf("%s call=%d msg=%s\n", label, cr, lua_tostring(L, -1));
        lua_pop(L, 1);
        return;
    }
    printf("%s=%s\n", label, lua_tostring(L, -1));
    lua_pop(L, 1);
}

/* Call the closure at a fixed slot and print its result. */
static void call_slot(lua_State *L, int slot, const char *label) {
    lua_pushvalue(L, slot);
    int cr = lua_pcall(L, 0, 1, 0);
    if (cr != 0) {
        printf("%s call=%d msg=%s\n", label, cr, lua_tostring(L, -1));
        lua_pop(L, 1);
        return;
    }
    printf("%s=%lld\n", label, (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
}

int main(void) {
    lua_State *L = luaL_newstate();
    if (!L) return 2;
    luaL_openlibs(L);

    /* ── S: setup ── */
    FILE *f = fopen(CHUNK_FILE, "w");
    if (!f) return fail("fopen chunk file");
    fputs("return envmark\n", f);
    fclose(f);

    lua_pushinteger(L, 7);
    lua_setglobal(L, "envmark");
    if (luaL_dostring(L, "return _G")) return fail("dostring _G");
    if (lua_type(L, SLOT_ORIG) != LUA_TTABLE) return fail("_G type");
    printf("S1 orig_globals_type=%d\n", lua_type(L, SLOT_ORIG));

    if (luaL_loadstring(L, "return envmark")) return fail("load before-closure");
    if (luaL_loadstring(L,
            "local env = {envmark = 55}\n"
            "local f1 = load(\"return envmark\")\n"
            "local f2 = load(\"return envmark\", \"n\", \"t\", env)\n"
            "return (f1() or \"nil\") .. \" \" .. (f2() or \"nil\")\n"))
        return fail("load driver");

    /* ── H: four C entry points BEFORE the replacement ── */
    call_ep(L, 0, "H1 direct_before");
    call_ep(L, 1, "H2 buffer_before");
    call_ep(L, 2, "H3 string_before");
    call_ep(L, 3, "H4 file_before");

    /* ── J1: Lua-level load, default vs explicit env, BEFORE ── */
    call_driver(L, "J1 lua_default_before");

    /* ── replacement: registry[2] = fresh table with envmark=73 ── */
    lua_newtable(L);
    lua_pushinteger(L, 73);
    lua_setfield(L, -2, "envmark");
    lua_rawseti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);

    /* ── M: get/setglobal go to the replacement, not the old table ── */
    lua_getglobal(L, "envmark");
    printf("M1 getglobal_after=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
    lua_pushinteger(L, 91);
    lua_setglobal(L, "wmark");
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
    lua_getfield(L, -1, "wmark");
    printf("M2 reg2_wmark=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 2);
    printf("M3 old_wmark_type=%d\n", lua_getfield(L, SLOT_ORIG, "wmark"));
    lua_pop(L, 1);

    /* ── I: the same four entry points AFTER the replacement ── */
    call_ep(L, 0, "I1 direct_after");
    call_ep(L, 1, "I2 buffer_after");
    call_ep(L, 2, "I3 string_after");
    call_ep(L, 3, "I4 file_after");

    /* ── J2: Lua-level load, default vs explicit env, AFTER ── */
    call_driver(L, "J2 lua_default_after");

    /* Keep an after-closure at a fixed slot for the GC/restore sections. */
    if (luaL_loadstring(L, "return envmark")) return fail("load after-closure");

    /* ── K: real GC cycle with both environments reachable ── */
    lua_gc(L, LUA_GCCOLLECT);
    for (int i = 0; i < 3; i++) (void)lua_gc(L, LUA_GCSTEP, 1);
    lua_gc(L, LUA_GCCOLLECT);
    call_slot(L, SLOT_BEFORE, "K1 before_closure_after_gc");
    call_slot(L, SLOT_AFTER, "K2 after_closure_after_gc");
    lua_getglobal(L, "envmark");
    printf("K3 getglobal_after_gc=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, SLOT_ORIG, "envmark");
    printf("K4 old_envmark_after_gc=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    /* ── L: restore the old RIDX[2] ── */
    lua_pushvalue(L, SLOT_ORIG);
    lua_rawseti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
    lua_getglobal(L, "envmark");
    printf("L1 getglobal_restored=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
    call_ep(L, 2, "L2 newload_string_restored");
    call_ep(L, 3, "L3 newload_file_restored");
    call_slot(L, SLOT_AFTER, "L4 existing_after_closure");
    call_slot(L, SLOT_BEFORE, "L5 existing_before_closure");
    call_driver(L, "L6 lua_default_restored");
    lua_gc(L, LUA_GCCOLLECT);
    call_slot(L, SLOT_AFTER, "L7 existing_after_closure_after_gc");

    remove(CHUNK_FILE);
    lua_close(L);
    printf("done\n");
    return 0;
}
