/*
** 17_gccontrol.c — GC control API parity test (PUC lua_gc vs luazig gcControl).
**
** Tests the unified gcControl implementation (P16.4a):
**   - Fresh-state GC mode transitions (GEN/INC return values)
**   - STOP/ISRUNNING/RESTART cycle
**   - STEP semantics (return 1 on cycle completion)
**   - GCPARAM getter/setter with coded param roundtrip
**   - Lua-level collectgarbage parity
**
** All outputs are byte-identical between PUC Lua and luazig (no absolute
** heap sizes printed — heaps differ between runtimes).
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* Helper: run a Lua chunk and return its string result. */
static const char *dostring_str(lua_State *L, const char *code) {
    if (luaL_dostring(L, code) != LUA_OK) {
        return NULL;
    }
    return lua_tostring(L, -1);
}

int main(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    printf("=== GC Control API Test ===\n");

    /* --- 1. Fresh-state sweep --- */
    printf("1. fresh-state sweep:\n");
    /* ISRUNNING: fresh state should be running (gcstp == 0). */
    printf("   ISRUNNING=%d\n", lua_gc(L, LUA_GCISRUNNING));
    /* COUNT > 0 (heap has objects after openlibs). */
    int count = lua_gc(L, LUA_GCCOUNT);
    printf("   COUNT>0=%s\n", count > 0 ? "yes" : "no");
    /* COUNTB in [0, 1023]. */
    int countb = lua_gc(L, LUA_GCCOUNTB);
    printf("   COUNTB<1024=%s\n", (countb >= 0 && countb < 1024) ? "yes" : "no");

    /* --- 2. Mode transitions (fresh state starts incremental) --- */
    printf("2. mode transitions:\n");
    /* Fresh luaL_newstate starts incremental (KGC_INC). */
    /* GCGEN: ret = previous mode (8=LUA_GCINC if was incremental). */
    int gen_ret = lua_gc(L, LUA_GCGEN);
    printf("   GCGEN->ret=%d (expect 8=INC)\n", gen_ret);
    /* GCINC: ret = previous mode (7=LUA_GCGEN if was generational). */
    int inc_ret = lua_gc(L, LUA_GCINC);
    printf("   GCINC->ret=%d (expect 7=GEN)\n", inc_ret);
    /* GCGEN again: ret = 8 (was incremental). */
    int gen_ret2 = lua_gc(L, LUA_GCGEN);
    printf("   GCGEN->ret=%d (expect 8=INC)\n", gen_ret2);

    /* --- 3. STOP/ISRUNNING/RESTART --- */
    printf("3. stop/isrunning/restart:\n");
    lua_gc(L, LUA_GCSTOP);
    printf("   after STOP: ISRUNNING=%d (expect 0)\n", lua_gc(L, LUA_GCISRUNNING));
    lua_gc(L, LUA_GCRESTART);
    printf("   after RESTART: ISRUNNING=%d (expect 1)\n", lua_gc(L, LUA_GCISRUNNING));

    /* --- 4. STEP semantics --- */
    printf("4. step semantics:\n");
    /* STEP(0) on a fresh-ish heap should complete a cycle (ret 1). */
    int step_ret = lua_gc(L, LUA_GCSTEP, 0);
    printf("   STEP(0)->ret=%d\n", step_ret);
    /* After allocating some garbage, STEP(small) should return 0,
       then bounded loop of STEP(0) should eventually return 1. */
    luaL_dostring(L, "local t = {} for i=1,1000 do t[i] = {i} end");
    int reached_1 = 0;
    for (int i = 0; i < 100; i++) {
        if (lua_gc(L, LUA_GCSTEP, 0) == 1) {
            reached_1 = 1;
            break;
        }
    }
    printf("   reached_1=%s\n", reached_1 ? "yes" : "no");

    /* --- 5. GCPARAM getter/setter --- */
    printf("5. gcparam getter/setter:\n");
    /* Getter (value < 0): returns decoded default value. */
    /* Order: minormul(0), majorminor(1), minormajor(2), pause(3), stepmul(4), stepsize(5) */
    int p_minormul = lua_gc(L, LUA_GCPARAM, LUA_GCPMINORMUL, -1);
    int p_majorminor = lua_gc(L, LUA_GCPARAM, LUA_GCPMAJORMINOR, -1);
    int p_minormajor = lua_gc(L, LUA_GCPARAM, LUA_GCPMINORMAJOR, -1);
    int p_pause = lua_gc(L, LUA_GCPARAM, LUA_GCPPAUSE, -1);
    int p_stepmul = lua_gc(L, LUA_GCPARAM, LUA_GCPSTEPMUL, -1);
    int p_stepsize = lua_gc(L, LUA_GCPARAM, LUA_GCPSTEPSIZE, -1);
    printf("   minormul=%d (expect 20)\n", p_minormul);
    printf("   majorminor=%d (expect 50)\n", p_majorminor);
    printf("   minormajor=%d (expect 68)\n", p_minormajor);
    printf("   pause=%d (expect 250)\n", p_pause);
    printf("   stepmul=%d (expect 200)\n", p_stepmul);
    printf("   stepsize=%d (expect 9600)\n", p_stepsize);

    /* Setter roundtrip: set pause=300, get back 300, restore. */
    int old_pause = lua_gc(L, LUA_GCPARAM, LUA_GCPPAUSE, 300);
    int new_pause = lua_gc(L, LUA_GCPARAM, LUA_GCPPAUSE, -1);
    printf("   set pause=300 -> getter=%d (expect 300)\n", new_pause);
    /* Restore original. */
    lua_gc(L, LUA_GCPARAM, LUA_GCPPAUSE, old_pause);

    /* --- 6. Lua-level collectgarbage parity --- */
    printf("6. lua-level collectgarbage:\n");
    /* "count" returns a fractional number (COUNT + COUNTB/1024). */
    const char *count_str = dostring_str(L, "return tostring(collectgarbage('count'))");
    printf("   count is number: %s\n", count_str ? "yes" : "no");
    lua_pop(L, 1);

    /* "step" returns boolean. */
    const char *step_str = dostring_str(L, "return tostring(collectgarbage('step'))");
    printf("   step is boolean: %s\n",
           (step_str && (strcmp(step_str, "true") == 0 || strcmp(step_str, "false") == 0)) ? "yes" : "no");
    lua_pop(L, 1);

    /* "gen"/"inc" return mode strings. */
    const char *gen_str = dostring_str(L, "return collectgarbage('generational')");
    printf("   gen->'%s' (expect 'incremental')\n", gen_str ? gen_str : "nil");
    lua_pop(L, 1);
    const char *inc_str = dostring_str(L, "return collectgarbage('incremental')");
    printf("   inc->'%s' (expect 'generational')\n", inc_str ? inc_str : "nil");
    lua_pop(L, 1);

    /* "param" getter returns same values as C API. */
    char buf[256];
    snprintf(buf, sizeof(buf), "return collectgarbage('param', 'pause')");
    luaL_dostring(L, buf);
    printf("   lua param pause=%lld (expect 250)\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    snprintf(buf, sizeof(buf), "return collectgarbage('param', 'stepsize')");
    luaL_dostring(L, buf);
    printf("   lua param stepsize=%lld (expect 9600)\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    snprintf(buf, sizeof(buf), "return collectgarbage('param', 'minormajor')");
    luaL_dostring(L, buf);
    printf("   lua param minormajor=%lld (expect 68)\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    /* "param" setter roundtrip. */
    snprintf(buf, sizeof(buf), "local old = collectgarbage('param', 'stepmul', 300); "
             "local new = collectgarbage('param', 'stepmul'); "
             "collectgarbage('param', 'stepmul', old); "
             "return new");
    luaL_dostring(L, buf);
    printf("   lua param set stepmul=300 -> getter=%lld (expect 300)\n", (long long)lua_tointeger(L, -1));
    lua_pop(L, 1);

    lua_close(L);
    printf("=== ALL PASS ===\n");
    return 0;
}
