/*
** 32_index_resolver.c — canonical differential for the unified C API index
** resolver (PUC lapi.c index2value): the read class through every index
** form — registry slot, existing/missing upvalue, acceptable-but-empty
** positive, light C function, Lua-frame hook lane, suspended coroutine,
** and the LUA_TNONE-vs-LUA_TNIL distinction (isvalid rule).
**
** Excluded PUC-release-UB forms (api_check class, nondeterministic or
** self-inconsistent on PUC release — see the cut report): idx == 0 and
** too-negative indices (index2value reads out-of-window slots), raw/next
** on a .none target (hvalue of the nilvalue), tolstring's in-place
** number-to-string mutation of non-stack targets (writable arm), and
** closures with more than MAXUPVAL (255) upvalues (PUC truncates
** nupvalues with cast_byte and crashes in lua_close).
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"

/* ------------------------------------------------------------------ */
/* Section F: hook lane — the C hook runs on an interrupted LUA frame  */
/* ------------------------------------------------------------------ */

static int g_hook_upv_type = -99;
static int g_hook_upv_pushed_type = -99;
static int g_hook_reg_type = -99;
static int g_hook_reg_pushed_type = -99;
static int g_hook_reg_rawequal = -99;
static int g_hook_fired = 0;

static void hook_fn(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (g_hook_fired) return; /* record the first line hook only */
    g_hook_fired = 1;
    /* upvalue arm: L->ci is the interrupted Lua frame (not a C closure)
     * -> PUC resolves to the nilvalue */
    g_hook_upv_type = lua_type(L, lua_upvalueindex(1));
    lua_pushvalue(L, lua_upvalueindex(1));
    g_hook_upv_pushed_type = lua_type(L, -1);
    lua_pop(L, 1);
    /* registry arm works in the hook lane */
    g_hook_reg_type = lua_type(L, LUA_REGISTRYINDEX);
    lua_pushvalue(L, LUA_REGISTRYINDEX);
    g_hook_reg_pushed_type = lua_type(L, -1);
    lua_pop(L, 1);
    g_hook_reg_rawequal = lua_rawequal(L, LUA_REGISTRYINDEX, LUA_REGISTRYINDEX);
}

/* ------------------------------------------------------------------ */
/* Section G: suspended coroutine — C closure yields with a continuation */
/* ------------------------------------------------------------------ */

static int co_cb_k(lua_State *L, int status, lua_KContext ctx) {
    (void)status; (void)ctx;
    /* continuation: the C frame is restored, upvalues resolve again */
    lua_pushvalue(L, lua_upvalueindex(1));
    printf("G4 post_resume: type=%d val=%s\n", lua_type(L, -1),
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 1);
    return 0;
}

static int co_cb(lua_State *L) {
    lua_pushvalue(L, lua_upvalueindex(1));
    printf("G1 pre_yield: type=%d val=%s\n", lua_type(L, -1),
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 1);
    return lua_yieldk(L, 0, 0, co_cb_k);
}

/* ------------------------------------------------------------------ */
/* Section B/C/D: the read class inside a running C closure            */
/* ------------------------------------------------------------------ */

static int cb_light(lua_State *L) { (void)L; return 0; }

static int cb_len_raise(lua_State *L) {
    /* lua_len on a missing upvalue: PUC luaV_objlen raises the standard
     * "attempt to get length" error through the metamethod path */
    lua_len(L, lua_upvalueindex(9));
    printf("UNREACHED len_raise\n");
    return 0;
}

static int cb(lua_State *L) {
    int isnum;
    lua_Integer i;
    size_t len;
    const char *s;
    char buff[LUA_N2SBUFFSZ];
    unsigned n;
    lua_Number d;

    /* --- B: existing upvalues (1="strval", 2=3.5, 3=42, 4=true, 5=nil,
     *        6=table{skey=7}, 7=cb_light, 8=userdata) --- */
    printf("B1 type_upv1=%d\n", lua_type(L, lua_upvalueindex(1)));
    s = lua_tolstring(L, lua_upvalueindex(1), &len);
    printf("B2 tolstring_upv1=%s len=%zu\n", s ? s : "<null>", len);

    d = lua_tonumberx(L, lua_upvalueindex(2), &isnum);
    printf("B3 type_upv2=%d tonumber=%.14g isnum=%d\n",
           lua_type(L, lua_upvalueindex(2)), (double)d, isnum);
    i = lua_tointegerx(L, lua_upvalueindex(2), &isnum);
    printf("B4 tointeger_upv2=%lld isnum=%d\n", (long long)i, isnum);
    printf("B5 isnumber_upv2=%d isstring_upv2=%d isinteger_upv2=%d\n",
           lua_isnumber(L, lua_upvalueindex(2)),
           lua_isstring(L, lua_upvalueindex(2)),
           lua_isinteger(L, lua_upvalueindex(2)));

    i = lua_tointegerx(L, lua_upvalueindex(3), &isnum);
    printf("B6 tointeger_upv3=%lld isnum=%d isinteger=%d\n", (long long)i,
           isnum, lua_isinteger(L, lua_upvalueindex(3)));
    n = lua_numbertocstring(L, lua_upvalueindex(3), buff);
    printf("B7 n2s_upv3=%u str=%s\n", n, buff);
    n = lua_numbertocstring(L, lua_upvalueindex(2), buff);
    printf("B8 n2s_upv2=%u str=%s\n", n, buff);

    printf("B9 type_upv4=%d toboolean_upv4=%d\n",
           lua_type(L, lua_upvalueindex(4)),
           lua_toboolean(L, lua_upvalueindex(4)));
    printf("B10 type_upv5=%d toboolean_upv5=%d\n",
           lua_type(L, lua_upvalueindex(5)),
           lua_toboolean(L, lua_upvalueindex(5)));

    printf("B11 type_upv6=%d rawlen_upv6=%u\n",
           lua_type(L, lua_upvalueindex(6)),
           (unsigned)lua_rawlen(L, lua_upvalueindex(6)));
    /* lua_len pushes the border length of the upvalue table */
    lua_len(L, lua_upvalueindex(6));
    printf("B12 len_upv6_type=%d val=%lld\n", lua_type(L, -1),
           (long long)lua_tointegerx(L, -1, NULL));
    lua_pop(L, 1);
    /* next through the upvalue table: single entry "skey"=7 (iteration
     * order is deterministic with one key); the second call ends the
     * traversal and consumes the key itself */
    lua_pushnil(L);
    n = (unsigned)lua_next(L, lua_upvalueindex(6));
    printf("B13 next1=%u k=%s v=%lld\n", n,
           lua_tostring(L, -2) ? lua_tostring(L, -2) : "<null>",
           (long long)lua_tointegerx(L, -1, NULL));
    lua_pop(L, 1);
    printf("B14 next_end=%d\n", lua_next(L, lua_upvalueindex(6)));

    printf("B16 type_upv7=%d iscfunction_upv7=%d tocfunction_upv7=%d\n",
           lua_type(L, lua_upvalueindex(7)),
           lua_iscfunction(L, lua_upvalueindex(7)),
           lua_tocfunction(L, lua_upvalueindex(7)) == &cb_light);
    printf("B17 type_upv8=%d isuserdata_upv8=%d touserdata_upv8=%d\n",
           lua_type(L, lua_upvalueindex(8)),
           lua_isuserdata(L, lua_upvalueindex(8)),
           lua_touserdata(L, lua_upvalueindex(8)) != NULL);
    printf("B18 topointer_upv6_nonnull=%d\n",
           lua_topointer(L, lua_upvalueindex(6)) != NULL);
    printf("B19 tothread_upv6=%d\n",
           lua_tothread(L, lua_upvalueindex(6)) != NULL);

    /* pushvalue through every upvalue class */
    lua_pushvalue(L, lua_upvalueindex(1));
    printf("B20 push_upv1: type=%d val=%s\n", lua_type(L, -1),
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 1);
    lua_pushvalue(L, lua_upvalueindex(5));
    printf("B21 push_upv5_nil: type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);
    lua_pushvalue(L, lua_upvalueindex(6));
    printf("B22 push_upv6_table: type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);

    /* get/setmetatable read arm through the upvalue table */
    printf("B23 getmetatable_upv6=%d\n", lua_getmetatable(L, lua_upvalueindex(6)));
    lua_newtable(L);
    printf("B24 setmetatable_upv6=%d\n", lua_setmetatable(L, lua_upvalueindex(6)));
    isnum = lua_getmetatable(L, lua_upvalueindex(6));
    printf("B25 getmetatable_upv6_after=%d type=%d\n", isnum, lua_type(L, -1));
    lua_pop(L, 1);
    /* getmetatable on a missing upvalue: type-level mt of nil (NULL) */
    printf("B26 getmetatable_upv9=%d\n", lua_getmetatable(L, lua_upvalueindex(9)));

    /* getiuservalue read arm through the userdata upvalue (returns the
     * type of the pushed user value) */
    lua_pushinteger(L, 5);
    printf("B27 setiuservalue_upv8=%d\n", lua_setiuservalue(L, lua_upvalueindex(8), 1));
    isnum = lua_getiuservalue(L, lua_upvalueindex(8), 1);
    printf("B28 getiuservalue_upv8=%d val=%lld\n", isnum,
           (long long)lua_tointegerx(L, -1, NULL));
    lua_pop(L, 1);

    /* rawequal/compare through pseudo-indices (isvalid rule) */
    printf("B29 rawequal_upv1_self=%d\n",
           lua_rawequal(L, lua_upvalueindex(1), lua_upvalueindex(1)));
    lua_pushstring(L, "strval");
    printf("B30 rawequal_upv1_vs_stack=%d\n",
           lua_rawequal(L, lua_upvalueindex(1), -1));
    lua_pop(L, 1);
    printf("B31 compare_upv6_eq=%d\n",
           lua_compare(L, lua_upvalueindex(6), lua_upvalueindex(6), LUA_OPEQ));
    printf("B32 compare_upv3_lt=%d\n",
           lua_compare(L, lua_upvalueindex(3), lua_upvalueindex(2), LUA_OPLT));

    /* --- C: missing upvalue (n=9 > nupvalues=8) --- */
    printf("C1 type_upv9=%d\n", lua_type(L, lua_upvalueindex(9)));
    printf("C2 toboolean_upv9=%d isnumber_upv9=%d\n",
           lua_toboolean(L, lua_upvalueindex(9)),
           lua_isnumber(L, lua_upvalueindex(9)));
    s = lua_tolstring(L, lua_upvalueindex(9), &len);
    printf("C3 tolstring_upv9=%s len=%zu\n", s ? s : "<null>", len);
    i = lua_tointegerx(L, lua_upvalueindex(9), &isnum);
    printf("C4 tointeger_upv9=%lld isnum=%d\n", (long long)i, isnum);
    n = lua_numbertocstring(L, lua_upvalueindex(9), buff);
    printf("C5 n2s_upv9=%u\n", n);
    /* T_NONE vs TNIL: pushvalue of a missing upvalue pushes a REAL nil */
    lua_pushvalue(L, lua_upvalueindex(9));
    printf("C6 push_upv9: type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);
    /* isvalid rule: a .none operand forces 0 — even none-vs-none and
     * none-vs-real-nil; real-nil-vs-real-nil (upv5) is 1 */
    printf("C7 rawequal_upv9_self=%d\n",
           lua_rawequal(L, lua_upvalueindex(9), lua_upvalueindex(9)));
    printf("C8 rawequal_upv9_vs_upv5nil=%d\n",
           lua_rawequal(L, lua_upvalueindex(9), lua_upvalueindex(5)));
    printf("C9 rawequal_upv5nil_self=%d\n",
           lua_rawequal(L, lua_upvalueindex(5), lua_upvalueindex(5)));
    printf("C10 compare_upv9_eq=%d\n",
           lua_compare(L, lua_upvalueindex(9), lua_upvalueindex(9), LUA_OPEQ));

    /* --- D: acceptable-but-empty positive index --- */
    printf("D1 type_above_top=%d\n", lua_type(L, lua_gettop(L) + 3));
    lua_pushvalue(L, lua_gettop(L) + 3);
    printf("D2 push_above_top: type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);
    printf("D3 toboolean_above_top=%d\n",
           lua_toboolean(L, lua_gettop(L) + 5));

    /* registry read class from inside the C closure */
    printf("R1 type_reg=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    lua_pushvalue(L, LUA_REGISTRYINDEX);
    printf("R2 push_reg: type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);
    printf("R3 toboolean_reg=%d isnumber_reg=%d isstring_reg=%d\n",
           lua_toboolean(L, LUA_REGISTRYINDEX),
           lua_isnumber(L, LUA_REGISTRYINDEX),
           lua_isstring(L, LUA_REGISTRYINDEX));
    s = lua_tolstring(L, LUA_REGISTRYINDEX, &len);
    printf("R4 tolstring_reg=%s len=%zu\n", s ? s : "<null>", len);
    (void)lua_tonumberx(L, LUA_REGISTRYINDEX, &isnum);
    printf("R5 tonumber_reg_isnum=%d\n", isnum);
    printf("R6 rawequal_reg_self=%d\n",
           lua_rawequal(L, LUA_REGISTRYINDEX, LUA_REGISTRYINDEX));
    printf("R7 compare_reg_eq=%d\n",
           lua_compare(L, LUA_REGISTRYINDEX, LUA_REGISTRYINDEX, LUA_OPEQ));
    n = lua_numbertocstring(L, LUA_REGISTRYINDEX, buff);
    printf("R8 n2s_reg=%u\n", n);
    return 0;
}

int main(void) {
    lua_State *L;
    lua_State *co;
    int rc;

    L = luaL_newstate();
    if (!L) return 2;

    /* --- A: host/base-frame lane (caller not a C function) --- */
    printf("A1 type_reg=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    lua_pushvalue(L, LUA_REGISTRYINDEX);
    printf("A2 push_reg: type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);
    printf("A3 type_host_upv1=%d toboolean_host_upv1=%d\n",
           lua_type(L, lua_upvalueindex(1)),
           lua_toboolean(L, lua_upvalueindex(1)));

    /* --- B/C/D/R: inside the 8-upvalue C closure --- */
    lua_pushstring(L, "strval");      /* upvalue 1 */
    lua_pushnumber(L, 3.5);           /* upvalue 2 */
    lua_pushinteger(L, 42);           /* upvalue 3 */
    lua_pushboolean(L, 1);            /* upvalue 4 */
    lua_pushnil(L);                   /* upvalue 5 */
    lua_newtable(L);                  /* upvalue 6 */
    lua_pushinteger(L, 7);
    lua_setfield(L, -2, "skey");
    lua_pushcfunction(L, cb_light);   /* upvalue 7 */
    lua_newuserdatauv(L, 16, 1);      /* upvalue 8 */
    lua_pushcclosure(L, cb, 8);
    printf("call_cb=%d\n", lua_pcall(L, 0, 0, 0));
    /* --- E: light C function (no upvalues) --- */
    lua_pushcfunction(L, cb_light);
    printf("call_light=%d\n", lua_pcall(L, 0, 0, 0));

    /* lua_len raising through a missing upvalue (protected) */
    lua_pushcfunction(L, cb_len_raise);
    rc = lua_pcall(L, 0, 1, 0);
    printf("call_len_raise=%d msg=%s\n", rc,
           lua_tostring(L, -1) ? lua_tostring(L, -1) : "<null>");
    lua_pop(L, 1);

    /* --- F: hook lane on a Lua frame --- */
    lua_sethook(L, hook_fn, LUA_MASKLINE, 1);
    if (luaL_loadstring(L, "local x = 0\nx = x + 1\nx = x + 2\nreturn x") != LUA_OK)
        return 3;
    printf("F1 call=%d\n", lua_pcall(L, 0, 0, 0));
    printf("F2 hook_upv_type=%d hook_upv_pushed_type=%d\n",
           g_hook_upv_type, g_hook_upv_pushed_type);
    printf("F3 hook_reg_type=%d hook_reg_pushed_type=%d hook_reg_rawequal=%d\n",
           g_hook_reg_type, g_hook_reg_pushed_type, g_hook_reg_rawequal);
    lua_sethook(L, NULL, 0, 0);

    /* --- G: suspended coroutine --- */
    co = lua_newthread(L);
    lua_pushstring(co, "coup");
    lua_pushcclosure(co, co_cb, 1);
    {
        int st, nres = -1;
        st = lua_resume(co, L, 0, &nres);
        printf("G2 resume1=%d nres1=%d\n", st, nres);
        /* host reads while co is suspended inside its C frame */
        printf("G3 host_suspended: upv1_type=%d reg_type=%d\n",
               lua_type(co, lua_upvalueindex(1)), lua_type(co, LUA_REGISTRYINDEX));
        lua_pushvalue(co, LUA_REGISTRYINDEX);
        printf("G3a host_push_reg_type=%d\n", lua_type(co, -1));
        lua_pop(co, 1);
        printf("G3b host_rawequal_upv1=%d\n",
               lua_rawequal(co, lua_upvalueindex(1), lua_upvalueindex(1)));
        st = lua_resume(co, L, 0, &nres);
        printf("G5 resume2=%d nres2=%d\n", st, nres);
    }

    /* --- H: T_NONE vs TNIL through the registry slot --- */
    lua_pushvalue(L, LUA_REGISTRYINDEX);   /* save the original table */
    lua_pushnil(L);
    lua_copy(L, -1, LUA_REGISTRYINDEX);    /* slot := real nil */
    printf("H1 reg_nil_type=%d\n", lua_type(L, LUA_REGISTRYINDEX));
    lua_pushvalue(L, LUA_REGISTRYINDEX);
    printf("H2 push_reg_nil_type=%d\n", lua_type(L, -1));
    lua_pop(L, 1);
    printf("H3 rawequal_regnil_self=%d\n",
           lua_rawequal(L, LUA_REGISTRYINDEX, LUA_REGISTRYINDEX));
    printf("H4 rawequal_regnil_vs_missing=%d\n",
           lua_rawequal(L, LUA_REGISTRYINDEX, lua_upvalueindex(1)));
    lua_pop(L, 1);                          /* pop the staged nil */
    lua_copy(L, -1, LUA_REGISTRYINDEX);    /* restore the original table */
    lua_pop(L, 1);
    printf("H5 restored_type=%d\n", lua_type(L, LUA_REGISTRYINDEX));

    lua_close(L);
    printf("done\n");
    return 0;
}
