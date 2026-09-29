/*
** 33_getset_resolver.c — canonical differential for the unified C API
** index resolver (PUC lapi.c index2value): the get/set class through
** every valid target form — the registry slot (a full cycle with GC), a
** table upvalue of a running C closure, stack-effect exactness (result
** push / operand pop), the standard index error on .none targets
** (missing upvalue, acceptable-but-empty positive, non-table upvalue,
** non-table registry slot) with PUC-exact messages and the pcall-boundary
** stack shape (no operand leak), raw get/set through registry and upvalue
** targets, next through the registry, and the PUC 5.5 luaL_ref/luaL_unref
** free-list system through an upvalue table (with GC).
**
** Excluded PUC-release-UB forms (api_check class, see the cut report):
** the raw functions and next on a .none or non-table TARGET (PUC release
** dereferences the resolved value as a Table — SIGSEGV) and raw access to
** the registry after a non-table store into the registry slot. luazig's
** documented graceful shape for the raw class (the PUC success stack
** effect with a nil result) is a defined deviation, not a differential
** form.
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"

static int g_pkey; /* light userdata key for rawsetp/rawgetp */

/* ------------------------------------------------------------------ */
/* Section B/C helpers: closures running with upvalues                 */
/* ------------------------------------------------------------------ */

/* __index metamethod as a C closure with its own hidden-table upvalue:
** exercises the metamethod call (nested execution) through a pseudo-
** resolved target. Args (t, k) -> hidden[k]. */
static int cb_index(lua_State *L) {
    lua_pushvalue(L, lua_upvalueindex(1)); /* [t, k, hidden] */
    lua_pushvalue(L, 2);                   /* [t, k, hidden, k] */
    lua_rawget(L, -2);                     /* table=hidden, key at top */
    return 1;
}

/* B: the get/set class through a table upvalue (upv1 = table, upv2 =
** userdata with one uservalue). Every op prints its stack delta. */
static int cb_tbl(lua_State *L) {
    int top0, r;

    top0 = lua_gettop(L);
    r = lua_getfield(L, lua_upvalueindex(1), "fkey");
    printf("B1 getfield_upv type=%d val=%lld top_d=%d\n", r,
           (long long)lua_tointeger(L, -1), lua_gettop(L) - top0);
    lua_pop(L, 1);

    top0 = lua_gettop(L);
    lua_pushinteger(L, 6);
    lua_setfield(L, lua_upvalueindex(1), "gkey");
    printf("B2 setfield_upv top_d=%d\n", lua_gettop(L) - top0);
    r = lua_getfield(L, lua_upvalueindex(1), "gkey");
    printf("B3 getfield_upv_gkey type=%d val=%lld\n", r,
           (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    top0 = lua_gettop(L);
    lua_pushstring(L, "akey");
    lua_pushinteger(L, 7);
    lua_settable(L, lua_upvalueindex(1));
    printf("B4 settable_upv top_d=%d\n", lua_gettop(L) - top0);
    top0 = lua_gettop(L);
    lua_pushstring(L, "akey");
    r = lua_gettable(L, lua_upvalueindex(1));
    printf("B5 gettable_upv type=%d val=%lld top_d=%d\n", r,
           (long long)lua_tointeger(L, -1), lua_gettop(L) - top0);
    lua_pop(L, 1);

    top0 = lua_gettop(L);
    lua_pushinteger(L, 8);
    lua_seti(L, lua_upvalueindex(1), 3);
    printf("B6 seti_upv top_d=%d\n", lua_gettop(L) - top0);
    r = lua_geti(L, lua_upvalueindex(1), 3);
    printf("B7 geti_upv type=%d val=%lld\n", r, (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    top0 = lua_gettop(L);
    lua_pushstring(L, "rkey");
    lua_pushinteger(L, 10);
    lua_rawset(L, lua_upvalueindex(1));
    printf("B8 rawset_upv top_d=%d\n", lua_gettop(L) - top0);
    top0 = lua_gettop(L);
    lua_pushstring(L, "rkey");
    r = lua_rawget(L, lua_upvalueindex(1));
    printf("B9 rawget_upv type=%d val=%lld top_d=%d\n", r,
           (long long)lua_tointeger(L, -1), lua_gettop(L) - top0);
    lua_pop(L, 1);

    top0 = lua_gettop(L);
    lua_pushinteger(L, 11);
    lua_rawseti(L, lua_upvalueindex(1), 4);
    printf("B10 rawseti_upv top_d=%d\n", lua_gettop(L) - top0);
    r = lua_rawgeti(L, lua_upvalueindex(1), 4);
    printf("B11 rawgeti_upv type=%d val=%lld\n", r,
           (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    top0 = lua_gettop(L);
    lua_pushinteger(L, 12);
    lua_rawsetp(L, lua_upvalueindex(1), (void *)&g_pkey);
    printf("B12 rawsetp_upv top_d=%d\n", lua_gettop(L) - top0);
    r = lua_rawgetp(L, lua_upvalueindex(1), (void *)&g_pkey);
    printf("B13 rawgetp_upv type=%d val=%lld\n", r,
           (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    /* setmetatable through the upvalue table, then a get through the
    ** metatable's __index TABLE chain */
    top0 = lua_gettop(L);
    lua_newtable(L); /* mt */
    lua_newtable(L); /* mt.__index */
    lua_pushinteger(L, 55);
    lua_setfield(L, -2, "mkey");
    lua_setfield(L, -2, "__index");
    r = lua_setmetatable(L, lua_upvalueindex(1));
    printf("B14 setmetatable_upv=%d top_d=%d\n", r, lua_gettop(L) - top0);
    r = lua_getfield(L, lua_upvalueindex(1), "mkey");
    printf("B15 getfield_meta type=%d val=%lld\n", r,
           (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
    r = lua_getmetatable(L, lua_upvalueindex(1));
    printf("B16 getmetatable_upv=%d type=%d\n", r, lua_type(L, -1));
    lua_pop(L, 1);

    /* __index as a C closure: the metamethod CALL path (nested execution
    ** and stack growth) through the pseudo-resolved target */
    lua_newtable(L); /* hidden */
    lua_pushinteger(L, 66);
    lua_setfield(L, -2, "hkey");
    lua_pushcclosure(L, cb_index, 1); /* [.., idxfn] (hidden is the upvalue) */
    lua_getmetatable(L, lua_upvalueindex(1)); /* [.., idxfn, mt] */
    lua_pushvalue(L, -2); /* [.., idxfn, mt, idxfn2] */
    lua_setfield(L, -2, "__index"); /* mt.__index = idxfn */
    lua_pop(L, 2);
    r = lua_getfield(L, lua_upvalueindex(1), "hkey");
    printf("B17 getfield_indexcall type=%d val=%lld\n", r,
           (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    /* setiuservalue/getiuservalue through the userdata upvalue */
    top0 = lua_gettop(L);
    lua_pushinteger(L, 9);
    r = lua_setiuservalue(L, lua_upvalueindex(2), 1);
    printf("B18 setiuv_upv=%d top_d=%d\n", r, lua_gettop(L) - top0);
    r = lua_getiuservalue(L, lua_upvalueindex(2), 1);
    printf("B19 getiuv_upv=%d val=%lld\n", r, (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    /* out-of-range n: PUC pushes nil and returns LUA_TNONE; the value
    ** stays untouched; setiuservalue returns 0 and still pops */
    r = lua_getiuservalue(L, lua_upvalueindex(2), 0);
    printf("B20 getiuv_n0=%d pushed_type=%d\n", r, lua_type(L, -1));
    lua_pop(L, 1);
    r = lua_getiuservalue(L, lua_upvalueindex(2), 2);
    printf("B21 getiuv_n2=%d pushed_type=%d\n", r, lua_type(L, -1));
    lua_pop(L, 1);
    top0 = lua_gettop(L);
    lua_pushinteger(L, 10);
    r = lua_setiuservalue(L, lua_upvalueindex(2), 0);
    printf("B22 setiuv_n0=%d top_d=%d\n", r, lua_gettop(L) - top0);
    lua_pushinteger(L, 11);
    r = lua_setiuservalue(L, lua_upvalueindex(2), 2);
    printf("B23 setiuv_n2=%d\n", r);
    r = lua_getiuservalue(L, lua_upvalueindex(2), 1);
    printf("B24 getiuv_still type=%d val=%lld\n", r,
           (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
    return 0;
}

/* C: every raising form. The single upvalue is the form id (an integer —
** also the non-table target for the number-variant forms). */
static int cb_raise(lua_State *L) {
    switch ((int)lua_tointeger(L, lua_upvalueindex(1))) {
    case 1:
        lua_getfield(L, lua_upvalueindex(9), "k");
        break;
    case 2:
        lua_pushinteger(L, 9);
        lua_setfield(L, lua_upvalueindex(9), "k");
        break;
    case 3:
        lua_pushstring(L, "k");
        lua_gettable(L, lua_upvalueindex(9));
        break;
    case 4:
        lua_pushstring(L, "k");
        lua_pushinteger(L, 9);
        lua_settable(L, lua_upvalueindex(9));
        break;
    case 5:
        lua_geti(L, lua_upvalueindex(9), 1);
        break;
    case 6:
        lua_pushinteger(L, 9);
        lua_seti(L, lua_upvalueindex(9), 1);
        break;
    case 7: /* acceptable-but-empty positive index */
        lua_getfield(L, lua_gettop(L) + 5, "k");
        break;
    case 8:
        lua_pushinteger(L, 9);
        lua_setfield(L, lua_gettop(L) + 5, "k");
        break;
    case 9: /* the form-id upvalue itself is a number */
        lua_getfield(L, lua_upvalueindex(1), "k");
        break;
    case 10:
        lua_pushinteger(L, 9);
        lua_setfield(L, lua_upvalueindex(1), "k");
        break;
    case 11: /* the registry slot holds a number (section D) */
        lua_getfield(L, LUA_REGISTRYINDEX, "x");
        break;
    case 12:
        lua_pushinteger(L, 9);
        lua_setfield(L, LUA_REGISTRYINDEX, "x");
        break;
    }
    printf("UNREACHED raise form completed\n");
    return 0;
}

static void run_raise(lua_State *L, int form) {
    int top_before, rc;
    lua_pushinteger(L, form);
    lua_pushcclosure(L, cb_raise, 1);
    top_before = lua_gettop(L);
    rc = lua_pcall(L, 0, 1, 0);
    printf("C%d rc=%d top_d=%d msg=%s\n", form, rc,
           lua_gettop(L) - top_before,
           rc == LUA_OK
               ? "<ok>"
               : (lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>"));
    lua_pop(L, 1);
}

/* F: the PUC 5.5 reference system through an upvalue table (freelist at
** t[1], new refs rawlen+1, recycling, negative refs are no-ops). */
static int cb_refs(lua_State *L) {
    int top0, r1, r2, r3;

    top0 = lua_gettop(L);
    lua_pushnil(L);
    r1 = luaL_ref(L, lua_upvalueindex(1));
    printf("F1 ref_nil=%d top_d=%d\n", r1, lua_gettop(L) - top0);

    lua_newtable(L);
    r1 = luaL_ref(L, lua_upvalueindex(1));
    printf("F2 ref_first=%d\n", r1);

    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_rawgeti(L, lua_upvalueindex(1), r1);
    printf("F3 ref_survives_gc type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);

    lua_pushinteger(L, 42);
    r2 = luaL_ref(L, lua_upvalueindex(1));
    printf("F4 ref_second=%d\n", r2);

    luaL_unref(L, lua_upvalueindex(1), r1);
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_rawgeti(L, lua_upvalueindex(1), r1);
    printf("F5 unref_slot type=%d val=%lld\n", lua_type(L, -1),
           (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    luaL_unref(L, lua_upvalueindex(1), LUA_REFNIL);
    luaL_unref(L, lua_upvalueindex(1), LUA_NOREF);

    lua_pushliteral(L, "recycled");
    r3 = luaL_ref(L, lua_upvalueindex(1));
    printf("F6 ref_recycled=%d\n", r3);
    lua_rawgeti(L, lua_upvalueindex(1), r3);
    printf("F7 recycled_val=%s\n", lua_tostring(L, -1));
    lua_pop(L, 1);
    printf("F8 top=%d\n", lua_gettop(L));
    return 0;
}

int main(void) {
    lua_State *L;
    int top0, r;

    L = luaL_newstate();
    if (!L) return 2;

    /* --- A0: registry-lane luaL_ref (freelist on registry[1]=false) --- */
    lua_pushinteger(L, 5);
    r = luaL_ref(L, LUA_REGISTRYINDEX);
    printf("A0 reg_ref_first=%d\n", r);
    lua_rawgeti(L, LUA_REGISTRYINDEX, r);
    printf("A0 reg_ref_val=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
    luaL_unref(L, LUA_REGISTRYINDEX, r);
    lua_rawgeti(L, LUA_REGISTRYINDEX, r);
    printf("A0 reg_unref_slot type=%d val=%lld\n", lua_type(L, -1),
           (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    /* --- A: registry get/set full cycle with GC --- */
    lua_newtable(L);
    lua_pushinteger(L, 73);
    lua_setfield(L, -2, "probe");
    top0 = lua_gettop(L);
    lua_setfield(L, LUA_REGISTRYINDEX, "gtest");
    printf("A1 setfield_reg top_d=%d\n", lua_gettop(L) - top0);

    lua_gc(L, LUA_GCCOLLECT, 0);
    r = lua_getfield(L, LUA_REGISTRYINDEX, "gtest");
    printf("A2 getfield_reg_gc type=%d\n", r);
    r = lua_getfield(L, -1, "probe");
    printf("A2 probe=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 2);

    top0 = lua_gettop(L);
    lua_pushinteger(L, 77);
    lua_seti(L, LUA_REGISTRYINDEX, 10);
    printf("A3 seti_reg top_d=%d\n", lua_gettop(L) - top0);
    r = lua_geti(L, LUA_REGISTRYINDEX, 10);
    printf("A3 geti_reg type=%d val=%lld\n", r, (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    top0 = lua_gettop(L);
    lua_pushinteger(L, 88);
    lua_rawseti(L, LUA_REGISTRYINDEX, 11);
    printf("A4 rawseti_reg top_d=%d\n", lua_gettop(L) - top0);
    r = lua_rawgeti(L, LUA_REGISTRYINDEX, 11);
    printf("A4 rawgeti_reg type=%d val=%lld\n", r,
           (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    top0 = lua_gettop(L);
    lua_pushstring(L, "rkey");
    lua_pushinteger(L, 99);
    lua_rawset(L, LUA_REGISTRYINDEX);
    printf("A5 rawset_reg top_d=%d\n", lua_gettop(L) - top0);
    top0 = lua_gettop(L);
    lua_pushstring(L, "rkey");
    r = lua_rawget(L, LUA_REGISTRYINDEX);
    printf("A5 rawget_reg type=%d val=%lld top_d=%d\n", r,
           (long long)lua_tointeger(L, -1), lua_gettop(L) - top0);
    lua_pop(L, 1);

    top0 = lua_gettop(L);
    lua_pushinteger(L, 111);
    lua_rawsetp(L, LUA_REGISTRYINDEX, (void *)&g_pkey);
    printf("A6 rawsetp_reg top_d=%d\n", lua_gettop(L) - top0);
    r = lua_rawgetp(L, LUA_REGISTRYINDEX, (void *)&g_pkey);
    printf("A6 rawgetp_reg type=%d val=%lld\n", r,
           (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    top0 = lua_gettop(L);
    lua_pushstring(L, "tkey");
    lua_pushinteger(L, 123);
    lua_settable(L, LUA_REGISTRYINDEX);
    printf("A7 settable_reg top_d=%d\n", lua_gettop(L) - top0);
    top0 = lua_gettop(L);
    lua_pushstring(L, "tkey");
    r = lua_gettable(L, LUA_REGISTRYINDEX);
    printf("A7 gettable_reg type=%d val=%lld top_d=%d\n", r,
           (long long)lua_tointeger(L, -1), lua_gettop(L) - top0);
    lua_pop(L, 1);

    lua_gc(L, LUA_GCCOLLECT, 0);
    r = lua_getfield(L, LUA_REGISTRYINDEX, "gtest");
    printf("A8 getfield_reg_gc2 type=%d\n", r);
    r = lua_getfield(L, -1, "probe");
    printf("A8 probe=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 2);

    /* --- B: the get/set class through a table upvalue --- */
    lua_newtable(L);
    lua_pushinteger(L, 5);
    lua_setfield(L, -2, "fkey");
    lua_newuserdatauv(L, 0, 1);
    lua_pushcclosure(L, cb_tbl, 2);
    printf("B_call=%d\n", lua_pcall(L, 0, 0, 0));

    /* --- C: raising forms on .none / non-table targets --- */
    run_raise(L, 1);
    run_raise(L, 2);
    run_raise(L, 3);
    run_raise(L, 4);
    run_raise(L, 5);
    run_raise(L, 6);
    run_raise(L, 7);
    run_raise(L, 8);
    run_raise(L, 9);
    run_raise(L, 10);

    /* --- D: non-table in the registry slot: the standard index error
    ** through the common path; then restore --- */
    lua_pushvalue(L, LUA_REGISTRYINDEX); /* save the original table */
    lua_pushnumber(L, 3.5);
    lua_copy(L, -1, LUA_REGISTRYINDEX);
    lua_pop(L, 1);
    run_raise(L, 11);
    run_raise(L, 12);
    lua_copy(L, -1, LUA_REGISTRYINDEX); /* restore */
    lua_pop(L, 1);
    printf("D1 restored_type=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    r = lua_getfield(L, LUA_REGISTRYINDEX, "gtest");
    printf("D2 getfield_restored type=%d\n", r);
    lua_pop(L, 1);

    /* --- E: next through the registry (order-independent RIDX probe) --- */
    {
        int acc = 0, n_int = 0;
        lua_pushnil(L);
        while (lua_next(L, LUA_REGISTRYINDEX)) {
            if (lua_type(L, -2) == LUA_TNUMBER && lua_isinteger(L, -2)) {
                lua_Integer k = lua_tointeger(L, -2);
                if (k >= 1 && k <= 3) {
                    acc += (int)(k * 10 + lua_type(L, -1));
                    n_int++;
                }
            }
            lua_pop(L, 1);
        }
        printf("E1 next_reg ridx_count=%d acc=%d\n", n_int, acc);
    }

    /* --- F: luaL_ref/luaL_unref through an upvalue table (with GC) --- */
    lua_newtable(L);
    lua_pushcclosure(L, cb_refs, 1);
    printf("F_call=%d\n", lua_pcall(L, 0, 0, 0));

    lua_close(L);
    printf("done\n");
    return 0;
}
