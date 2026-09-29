/*
** 34_writable_resolver.c — canonical differential for the writable /
** read-modifying C API paths through the unified index resolver
** (PUC lapi.c index2value targets):
**
**   A  lua_copy — stack->stack, ->upvalue (plain), ->upvalue with the
**      generational-mode write barrier (a young table stored into an old
**      closure's cell must survive minor collections), ->registry slot
**      (table / nil / number, a mid-cycle store kept alive by the atomic
**      re-mark, full-cycle GC, restore), copy FROM the registry, and an
**      invalid source (PUC release resolves it to the nilvalue and really
**      copies nil).
**   B  lua_tolstring in-place number->string conversion on EVERY target
**      kind: stack slot, upvalue cell (mutates the upvalue itself),
**      registry slot (PUC replaces the number in the slot with the
**      string), with before/after lua_type; non-convertible and .none
**      targets return NULL.
**   C  lua_absindex — PUC pure arithmetic: pseudo passthrough, positive
**      passthrough (even beyond top), negative window arithmetic, and the
**      idx==0 form (PUC returns count+1; no validation anywhere).
**   D  the upvalue family through a PSEUDO funcindex (PUC 5.5
**      aux_upvalue(index2value(L, funcindex), ...)): getupvalue /
**      setupvalue / upvalueid / upvaluejoin operating on a Lua closure
**      held in an upvalue of the running C closure, plus the non-closure,
**      C-closure ("" name), light-C-function and out-of-range forms.
**   E  lauxlib through pseudo arguments: luaL_getmetafield / luaL_callmeta
**      (including the relative-index absindex discipline), luaL_checkinteger,
**      luaL_optinteger, luaL_optlstring, luaL_checklstring (numbers convert
**      in place, PUC lua_tolstring basis), luaL_testudata, luaL_len,
**      luaL_tolstring (PUC 5.5 shape: absindex, __tostring metamethod,
**      always pushes), luaL_checkoption.
**   F  the realloc window under GC pressure: lua_tolstring conversions with
**      pending finalizers whose Lua bodies grow this thread's stack (PUC
**      runs luaC_checkGC inside lua_tolstring and re-resolves the target
**      after it — lapi.c:427); the conversion target sits at the top and at
**      a bottom slot under filler values.
**
** Excluded PUC-release-UB forms (documented class, see the cut reports):
** raw registry access while the slot holds a non-table, lua_copy INTO a
** .none target (PUC setobj into the nilvalue), wrong-type luaL_check*
** arguments (PUC argerror messages), and luaL_tolstring default-branch
** output (pointer text — not byte-comparable).
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* ------------------------------------------------------------------ */
/* Section A/B/D/E helpers                                             */
/* ------------------------------------------------------------------ */

/* A2: plain lua_copy into the C closure's own upvalue cell. */
static int cb_copy_upv(lua_State *L) {
    printf("A2a before_type=%d\n", lua_type(L, lua_upvalueindex(1)));
    lua_pushstring(L, "newval");
    lua_copy(L, -1, lua_upvalueindex(1));
    lua_pop(L, 1);
    printf("A2b after_type=%d\n", lua_type(L, lua_upvalueindex(1)));
    lua_pushvalue(L, lua_upvalueindex(1));
    printf("A2c val=%s\n", lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 1);
    return 0;
}

/* A3: copy -> upvalue under generational GC. The closure (and its upvalue
** cell) are OLD — created before the LUA_GCGEN full collection below — so
** the fresh table stored by lua_copy is YOUNG and reachable only through
** the old cell: the copy upvalue arm's write barrier is what keeps it
** alive across the minor collections (PUC luaC_barrier, lapi.c:261). */
static int cb_barrier(lua_State *L) {
    int i;
    lua_newtable(L);                          /* young table */
    lua_pushinteger(L, 123);
    lua_setfield(L, -2, "bk");
    lua_copy(L, -1, lua_upvalueindex(1));     /* young table -> old cell */
    lua_pop(L, 1);
    for (i = 0; i < 4; i++)                   /* minor collections */
        lua_gc(L, LUA_GCSTEP, 0);
    printf("A3a upv_type=%d\n", lua_type(L, lua_upvalueindex(1)));
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_getfield(L, -1, "bk");
    printf("A3b bk=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 2);
    return 0;
}

/* B light lane: tolstring on an upvalue pseudo-index of a light C function
** (PUC resolves it to the nilvalue -> NULL). */
static int cb_light(lua_State *L) {
    size_t len = 99;
    const char *s = lua_tolstring(L, lua_upvalueindex(1), &len);
    printf("BL light_tolstring=%s len=%zu\n", s ? s : "<null>", len);
    return 0;
}

static int cb_quiet(lua_State *L) { (void)L; return 0; }

/* D/E: the 16-upvalue closure (layout in main). */
static int cb_main(lua_State *L) {
    const char *nm;
    const char *s;
    size_t len;
    int r, top0;

    /* --- D: upvalue family through a pseudo funcindex --- */

    nm = lua_getupvalue(L, lua_upvalueindex(1), 1);   /* inner: u = 42 */
    printf("D1 name=%s val=%lld\n", nm ? nm : "<null>",
           (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
    nm = lua_getupvalue(L, lua_upvalueindex(1), 2);   /* inner: v = 's' */
    printf("D2 name=%s val=%s\n", nm ? nm : "<null>",
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 1);
    printf("D3 oob=%d noncl=%d\n",
           lua_getupvalue(L, lua_upvalueindex(1), 3) == NULL,
           lua_getupvalue(L, lua_upvalueindex(2), 1) == NULL);
    nm = lua_getupvalue(L, lua_upvalueindex(3), 1);   /* C closure: "" */
    printf("D5 name=%s empty=%d val=%s\n", nm ? nm : "<null>",
           nm != NULL && nm[0] == 0,
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 1);
    printf("D6 light=%d\n",
           lua_getupvalue(L, lua_upvalueindex(4), 1) == NULL);

    /* D7: setupvalue through the pseudo funcindex writes the INNER
    ** closure's upvalue (verified by calling the inner closure). */
    lua_pushinteger(L, 99);
    nm = lua_setupvalue(L, lua_upvalueindex(1), 1);
    printf("D7a name=%s\n", nm ? nm : "<null>");
    nm = lua_getupvalue(L, lua_upvalueindex(1), 1);
    printf("D7b val=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
    lua_pushvalue(L, lua_upvalueindex(1));
    r = lua_pcall(L, 0, 2, 0);
    printf("D7c rc=%d u=%lld v=%s\n", r,
           (long long)lua_tointeger(L, -2),
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 2);

    /* D8: upvalueid — same identity through the pseudo funcindex and
    ** through a stack copy of the closure; NULL forms. */
    {
        const void *id1 = lua_upvalueid(L, lua_upvalueindex(1), 1);
        lua_pushvalue(L, lua_upvalueindex(1));
        {
            const void *id2 = lua_upvalueid(L, -1, 1);
            printf("D8a id_eq=%d\n", id1 != NULL && id2 != NULL && id1 == id2);
        }
        lua_pop(L, 1);
        printf("D8b oob=%d num=%d light=%d\n",
               lua_upvalueid(L, lua_upvalueindex(1), 3) == NULL,
               lua_upvalueid(L, lua_upvalueindex(2), 1) == NULL,
               lua_upvalueid(L, lua_upvalueindex(4), 1) == NULL);
    }

    /* D9: upvaluejoin through pseudo fidx1/fidx2 — the inner closure's
    ** upvalue 2 (v) is re-pointed to the second closure's upvalue (w);
    ** writes through either are visible through both. */
    lua_upvaluejoin(L, lua_upvalueindex(1), 2, lua_upvalueindex(5), 1);
    nm = lua_getupvalue(L, lua_upvalueindex(1), 2);
    printf("D9a name=%s val=%s\n", nm ? nm : "<null>",
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 1);
    printf("D9b join_id=%d\n",
           lua_upvalueid(L, lua_upvalueindex(1), 2) ==
           lua_upvalueid(L, lua_upvalueindex(5), 1));
    lua_pushstring(L, "zz");
    nm = lua_setupvalue(L, lua_upvalueindex(5), 1);
    printf("D9c name=%s\n", nm ? nm : "<null>");
    nm = lua_getupvalue(L, lua_upvalueindex(1), 2);
    printf("D9d val=%s\n",
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 1);
    printf("D10 missing=%d\n",
           lua_getupvalue(L, lua_upvalueindex(30), 1) == NULL);

    /* --- B: lua_tolstring in-place on every target kind --- */

    lua_pushnumber(L, 3.5);
    printf("B1 before=%d\n", lua_type(L, -1));
    s = lua_tolstring(L, -1, &len);
    printf("B1 s=%s len=%zu after=%d isstr=%d\n", s ? s : "<null>", len,
           lua_type(L, -1), lua_isstring(L, -1));
    lua_pop(L, 1);
    lua_pushinteger(L, 42);
    s = lua_tolstring(L, -1, &len);
    printf("B2 s=%s len=%zu after=%d isint=%d\n", s ? s : "<null>", len,
           lua_type(L, -1), lua_isinteger(L, -1));
    lua_pop(L, 1);

    printf("B3 before=%d\n", lua_type(L, lua_upvalueindex(12)));
    s = lua_tolstring(L, lua_upvalueindex(12), &len);
    printf("B3 s=%s len=%zu after=%d\n", s ? s : "<null>", len,
           lua_type(L, lua_upvalueindex(12)));
    lua_pushvalue(L, lua_upvalueindex(12));
    printf("B3b pushed=%s\n",
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 1);
    s = lua_tolstring(L, lua_upvalueindex(11), &len);
    printf("B4 s=%s len=%zu after=%d\n", s ? s : "<null>", len,
           lua_type(L, lua_upvalueindex(11)));
    s = lua_tolstring(L, lua_upvalueindex(13), &len);
    printf("B5 s=%s len=%zu after=%d\n", s ? s : "<null>", len,
           lua_type(L, lua_upvalueindex(13)));
    s = lua_tolstring(L, lua_upvalueindex(14), &len);
    printf("B6 s=%s len=%zu after=%d\n", s ? s : "<null>", len,
           lua_type(L, lua_upvalueindex(14)));
    s = lua_tolstring(L, lua_upvalueindex(30), &len);
    printf("B7 s=%s len=%zu\n", s ? s : "<null>", len);
    s = lua_tolstring(L, lua_gettop(L) + 2, &len);
    printf("B10 s=%s len=%zu\n", s ? s : "<null>", len);

    /* --- E: lauxlib through pseudo arguments --- */

    top0 = lua_gettop(L);
    r = luaL_getmetafield(L, lua_upvalueindex(6), "__index");
    printf("E1a tt=%d top_d=%d\n", r, lua_gettop(L) - top0);
    r = lua_getfield(L, -1, "ek");
    printf("E1b ek=%lld\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 2);
    top0 = lua_gettop(L);
    r = luaL_getmetafield(L, lua_upvalueindex(6), "absent");
    printf("E1c tt=%d top_d=%d\n", r, lua_gettop(L) - top0);

    r = luaL_callmeta(L, lua_upvalueindex(6), "__add");
    printf("E2 rc=%d res=%s\n", r,
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 1);

    /* E3: relative obj index — luaL_callmeta must absindex it BEFORE the
    ** getmetafield push (PUC lauxlib.c:901); pushvalue(obj) after the push
    ** must push the OBJECT, not the metafield. */
    lua_pushvalue(L, lua_upvalueindex(6));
    r = luaL_callmeta(L, -1, "__add");
    printf("E3 rc=%d res=%s\n", r,
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 2);

    printf("E5 ci=%lld\n",
           (long long)luaL_checkinteger(L, lua_upvalueindex(2)));
    printf("E6 miss=%lld nil=%lld\n",
           (long long)luaL_optinteger(L, lua_upvalueindex(30), 777),
           (long long)luaL_optinteger(L, lua_upvalueindex(8), 778));
    {
        const char *o = luaL_optlstring(L, lua_upvalueindex(8), "dflt", &len);
        printf("E7a nil=%s len=%zu\n", o, len);
        o = luaL_optlstring(L, lua_upvalueindex(7), "dflt", &len);
        printf("E7b str=%s len=%zu\n", o, len);
    }
    {
        const char *c = luaL_checklstring(L, lua_upvalueindex(7), &len);
        printf("E4a str=%s len=%zu\n", c, len);
        /* numbers convert (PUC luaL_checklstring = lua_tolstring) and the
        ** conversion mutates the upvalue in place */
        c = luaL_checklstring(L, lua_upvalueindex(15), &len);
        printf("E4b num=%s len=%zu after=%d\n", c, len,
               lua_type(L, lua_upvalueindex(15)));
    }
    printf("E8 utm=%d nope=%d num=%d\n",
           luaL_testudata(L, lua_upvalueindex(9), "UTM") != NULL,
           luaL_testudata(L, lua_upvalueindex(9), "NOPE") != NULL,
           luaL_testudata(L, lua_upvalueindex(2), "UTM") != NULL);
    printf("E9 len=%lld\n", (long long)luaL_len(L, lua_upvalueindex(6)));

    /* E10: luaL_tolstring — PUC 5.5 shape: every branch PUSHES the result
    ** and the return value is the pushed string's bytes. */
    top0 = lua_gettop(L);
    s = luaL_tolstring(L, lua_upvalueindex(2), &len);
    printf("E10a num=%s len=%zu top_d=%d ptype=%d\n", s ? s : "<null>", len,
           lua_gettop(L) - top0, lua_type(L, -1));
    lua_pop(L, 1);
    s = luaL_tolstring(L, lua_upvalueindex(7), &len);
    printf("E10b str=%s top_d=%d\n", s ? s : "<null>", lua_gettop(L) - top0);
    lua_pop(L, 1);
    s = luaL_tolstring(L, lua_upvalueindex(8), &len);
    printf("E10c nil=%s\n", s ? s : "<null>");
    lua_pop(L, 1);
    s = luaL_tolstring(L, lua_upvalueindex(10), &len);
    printf("E10d bool=%s\n", s ? s : "<null>");
    lua_pop(L, 1);
    s = luaL_tolstring(L, lua_upvalueindex(16), &len);
    printf("E10e tostr=%s\n", s ? s : "<null>");
    lua_pop(L, 1);
    {
        const char *lst[] = {"x", "hello", NULL};
        printf("E11 opt=%d\n",
               luaL_checkoption(L, lua_upvalueindex(7), NULL, lst));
    }
    {
        /* E12: checkoption through a NUMBER — PUC's optstring/checkstring
        ** basis is lua_tolstring, so the argument converts IN PLACE
        ** through the resolver (the upvalue cell mutates). pre=3 also
        ** proves E10a (luaL_tolstring number branch) did NOT mutate. */
        const char *lst2[] = {"42", "other", NULL};
        /* Sequence explicitly: C argument evaluation order is unspecified
        ** (gcc evaluates right-to-left — the mutation must be observed in
        ** source order). */
        const int pre = lua_type(L, lua_upvalueindex(2));
        const int opt = luaL_checkoption(L, lua_upvalueindex(2), NULL, lst2);
        const int after = lua_type(L, lua_upvalueindex(2));
        printf("E12 pre=%d opt=%d after=%d\n", pre, opt, after);
    }
    return 0;
}

int main(void) {
    lua_State *L;
    const char *s;
    size_t len;
    int r, i, j;

    L = luaL_newstate();
    if (!L) return 2;
    luaL_openlibs(L);

    /* --- A1: copy stack -> stack --- */
    lua_pushstring(L, "aa");
    lua_pushstring(L, "bb");
    lua_copy(L, -2, -1);
    printf("A1 val=%s\n", lua_tostring(L, -1));
    lua_pop(L, 2);

    /* --- A2: copy -> upvalue (plain) --- */
    lua_pushstring(L, "oldval");
    lua_pushcclosure(L, cb_copy_upv, 1);
    printf("A2 rc=%d\n", lua_pcall(L, 0, 0, 0));

    /* --- A3: copy -> upvalue, generational barrier --- */
    lua_pushnil(L);
    lua_pushcclosure(L, cb_barrier, 1);
    printf("A3 gen_ret=%d\n", lua_gc(L, LUA_GCGEN));  /* prev mode = 8 (INC) */
    printf("A3 rc=%d\n", lua_pcall(L, 0, 0, 0));
    printf("A3 inc_ret=%d\n", lua_gc(L, LUA_GCINC));  /* prev mode = 7 (GEN) */

    /* --- A4: copy -> registry slot (table / nil / number; GC; restore) --- */
    lua_pushvalue(L, LUA_REGISTRYINDEX);          /* saved original */
    lua_newtable(L);                              /* t2 */
    lua_pushinteger(L, 91);
    lua_setfield(L, -2, "rmark");
    lua_copy(L, -1, LUA_REGISTRYINDEX);           /* slot := t2 */
    lua_pop(L, 1);
    printf("A4a type=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    r = lua_getfield(L, LUA_REGISTRYINDEX, "rmark");
    printf("A4a2 rmark=%d val=%lld\n", r, (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);
    lua_gc(L, LUA_GCCOLLECT);                     /* full cycle: slot survives */
    printf("A4a3 after_gc=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    r = lua_getfield(L, LUA_REGISTRYINDEX, "rmark");
    printf("A4a4 rmark=%d val=%lld\n", r, (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    lua_pushnil(L);
    lua_copy(L, -1, LUA_REGISTRYINDEX);           /* slot := nil */
    lua_pop(L, 1);
    printf("A4b type=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    lua_pushvalue(L, LUA_REGISTRYINDEX);
    printf("A4b2 pushed=%d\n", lua_type(L, -1));
    lua_pop(L, 1);

    lua_pushnumber(L, 3.5);
    lua_copy(L, -1, LUA_REGISTRYINDEX);           /* slot := 3.5 */
    lua_pop(L, 1);
    printf("A4c type=%d\n", lua_type(L, LUA_REGISTRYINDEX));

    /* A4d: mid-cycle slot store — the fresh white table is reachable only
    ** through the slot until the atomic re-mark paints it (PUC
    ** lgc.c:1553). */
    lua_gc(L, LUA_GCSTEP, 0);
    lua_gc(L, LUA_GCSTEP, 0);
    lua_newtable(L);
    lua_pushinteger(L, 55);
    lua_setfield(L, -2, "mid");
    lua_copy(L, -1, LUA_REGISTRYINDEX);
    lua_pop(L, 1);
    for (i = 0; i < 30; i++)
        lua_gc(L, LUA_GCSTEP, 0);
    printf("A4d type=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    r = lua_getfield(L, LUA_REGISTRYINDEX, "mid");
    printf("A4d2 mid=%d val=%lld\n", r, (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    lua_copy(L, -1, LUA_REGISTRYINDEX);           /* restore the original */
    lua_pop(L, 1);
    printf("A4e restored=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    r = lua_rawgeti(L, LUA_REGISTRYINDEX, 2);     /* globals back in place */
    printf("A4e2 globals=%d\n", r);
    lua_pop(L, 1);

    /* A4f: copy FROM the registry slot */
    lua_pushnil(L);
    lua_copy(L, LUA_REGISTRYINDEX, -1);
    printf("A4f type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);

    /* --- A5: invalid source resolves to the nilvalue (PUC release) --- */
    lua_pushstring(L, "x");
    lua_copy(L, lua_gettop(L) + 5, -1);
    printf("A5a type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);
    lua_pushstring(L, "y");
    lua_copy(L, lua_upvalueindex(1), -1);         /* host lane: no C closure */
    printf("A5b type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);

    /* --- C: lua_absindex (PUC pure arithmetic, no validation) --- */
    lua_pushinteger(L, 1);
    lua_pushinteger(L, 2);
    lua_pushinteger(L, 3);                        /* top = 3 */
    printf("C1 reg=%d\n", lua_absindex(L, LUA_REGISTRYINDEX));
    printf("C2 upv1=%d upv300=%d\n",
           lua_absindex(L, lua_upvalueindex(1)),
           lua_absindex(L, lua_upvalueindex(300)));
    printf("C4 pos=%d %d %d neg=%d %d %d\n",
           lua_absindex(L, 1), lua_absindex(L, 3), lua_absindex(L, 10),
           lua_absindex(L, -1), lua_absindex(L, -3), lua_absindex(L, -10));
    printf("C5 zero=%d\n", lua_absindex(L, 0));
    lua_pop(L, 3);

    /* --- B light lane --- */
    lua_pushcfunction(L, cb_light);
    printf("BL rc=%d\n", lua_pcall(L, 0, 0, 0));

    /* --- D/B/E: the 16-upvalue closure --- */
    luaL_dostring(L, "local u, v = 42, 's'; return function() return u, v end");
    lua_pushinteger(L, 42);                       /* upv 2 */
    lua_pushstring(L, "cuv");
    lua_pushcclosure(L, cb_quiet, 1);             /* upv 3 */
    lua_pushcfunction(L, cb_quiet);               /* upv 4: light (0 upvals) */
    luaL_dostring(L, "local w = 'joined'; return function() return w end");
    /* upv 5 */
    lua_newtable(L);                              /* upv 6: table with mt */
    for (i = 1; i <= 3; i++) {
        lua_pushinteger(L, i * 10);
        lua_rawseti(L, -2, i);
    }
    lua_newtable(L);                              /* mt */
    lua_newtable(L);                              /* mt.__index */
    lua_pushinteger(L, 77);
    lua_setfield(L, -2, "ek");
    lua_setfield(L, -2, "__index");
    luaL_dostring(L, "return function(x) return type(x) end");
    lua_setfield(L, -2, "__add");
    lua_setmetatable(L, -2);
    lua_pushstring(L, "hello");                   /* upv 7 */
    lua_pushnil(L);                               /* upv 8 */
    lua_newuserdatauv(L, 8, 0);                   /* upv 9 */
    luaL_newmetatable(L, "UTM");
    lua_setmetatable(L, -2);
    lua_pushboolean(L, 1);                        /* upv 10 */
    lua_pushnumber(L, 7.25);                      /* upv 11 */
    lua_pushinteger(L, 42);                       /* upv 12 */
    lua_pushstring(L, "strval");                  /* upv 13 */
    lua_newtable(L);                              /* upv 14 */
    lua_pushinteger(L, 99);                       /* upv 15 */
    lua_newtable(L);                              /* upv 16: __tostring table */
    lua_newtable(L);
    luaL_dostring(L, "return function(self) return 'TS' end");
    lua_setfield(L, -2, "__tostring");
    lua_setmetatable(L, -2);
    lua_pushcclosure(L, cb_main, 16);
    printf("call_cb_main=%d\n", lua_pcall(L, 0, 0, 0));

    /* --- B8/B9: tolstring in-place on the registry slot --- */
    lua_pushvalue(L, LUA_REGISTRYINDEX);          /* saved */
    lua_pushnumber(L, 3.5);
    lua_copy(L, -1, LUA_REGISTRYINDEX);
    lua_pop(L, 1);
    printf("B8 before=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    s = lua_tolstring(L, LUA_REGISTRYINDEX, &len);
    printf("B8 s=%s len=%zu after=%d\n", s ? s : "<null>", len,
           lua_type(L, LUA_REGISTRYINDEX));
    lua_pushvalue(L, LUA_REGISTRYINDEX);
    printf("B8b pushed=%s\n",
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 1);
    lua_copy(L, -1, LUA_REGISTRYINDEX);           /* restore */
    lua_pop(L, 1);
    printf("B9 restored=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    s = lua_tolstring(L, LUA_REGISTRYINDEX, &len);
    printf("B9b tbl=%s len=%zu\n", s ? s : "<null>", len);

    /* --- F: the realloc window under GC pressure --- */
    lua_settop(L, 0);   /* isolate: earlier-section error objects must not
                        ** shift this section's absolute indices */
    luaL_dostring(L,
        "return function() local function d(n)"
        " if n == 0 then return 0 end return 1 + d(n - 1) end"
        " return d(300) end");                    /* stack-growing __gc body */
    lua_newtable(L);                              /* mt with __gc */
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, "__gc");                  /* [gcfn, mt] at 1, 2 */
    for (i = 0; i < 48; i++) {
        lua_pushnumber(L, 9.5);                   /* conversion target */
        lua_newuserdatauv(L, 0, 0);               /* dead finalizable */
        lua_pushvalue(L, 2);
        lua_setmetatable(L, -2);
        lua_pop(L, 1);
        for (j = 0; j < 4; j++) {                 /* garbage + checkGC steps */
            lua_newtable(L);
            lua_pop(L, 1);
        }
        s = lua_tolstring(L, -1, &len);           /* PUC: checkGC inside */
        printf("F%02d s=%s len=%zu type=%d\n", i, s ? s : "<null>", len,
               lua_type(L, -1));
        lua_pop(L, 1);
    }
    /* F2: the conversion target at a bottom slot under filler values —
    ** the re-resolve class (the slot index survives, a held raw pointer
    ** would not). Host lane: reserve the stack explicitly (no C-closure
    ** MINSTACK guarantee from main). */
    if (lua_checkstack(L, 128) != 1) return 2;
    for (i = 0; i < 4; i++) {
        int k;
        lua_pushnumber(L, 8.5);                   /* slot 3 */
        for (k = 0; k < 40; k++)
            lua_pushinteger(L, k);
        lua_newuserdatauv(L, 0, 0);
        lua_pushvalue(L, 2);
        lua_setmetatable(L, -2);
        lua_pop(L, 1);
        for (j = 0; j < 4; j++) {
            lua_newtable(L);
            lua_pop(L, 1);
        }
        s = lua_tolstring(L, 3, &len);
        printf("F2_%d s=%s len=%zu type=%d\n", i, s ? s : "<null>", len,
               lua_type(L, 3));
        lua_pop(L, 41);
    }
    lua_pop(L, 2);                                /* gcfn, mt */
    lua_gc(L, LUA_GCCOLLECT);                     /* drain finalizers */
    printf("Fdone\n");

    lua_close(L);
    printf("done\n");
    return 0;
}
