/*
** 10_continuations.c — C API test for lua_yieldk / lua_pcallk / lua_callk
** with real C continuation callbacks (the `k` argument).
**
** This exercises the C continuation mechanism (P15.78):
**   - lua_yieldk saves k/ctx in the current C-frame; on the next resume,
**     finishCcall invokes k(L, LUA_OK, ctx).
**   - lua_pcallk with a non-NULL k sets up a yieldable pcall frame so that
**     a yield inside the callee suspends the pcall and runs k on resume.
**   - lua_callk with a non-NULL k marks the call boundary yieldable so a
**     yield inside the callee suspends and runs k on resume.
**
** Strategy: register C functions that use lua_yieldk/pcallk/callk as
** globals, then drive them from Lua coroutines via coroutine.resume.
** lua_pushcfunction is available, so we push the C function directly
** and set it as a global. The Lua script creates the coroutine and
** drives it with coroutine.resume, which exercises the C continuation
** mechanism (callCFunction pushes a C-frame, lua_yieldk longjmps,
** finishCcall invokes k on the next resume).
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* ------------------------------------------------------------------ */
/* Test 1: basic lua_yieldk with a C continuation                     */
/* ------------------------------------------------------------------ */

/*
** Continuation invoked by finishCcall on the second resume. `ctx` was saved
** by lua_yieldk; `status` is LUA_OK (the API-mapped status of LUA_YIELD).
** We push ctx + 100 and return 1 result.
*/
static int k_yield_basic(lua_State *L, int status, lua_KContext ctx) {
    (void)status;
    lua_pushinteger(L, (lua_Integer)ctx + 100);
    return 1;
}

/*
** C function running inside a coroutine. Pushes 1 and yields with
** continuation k_yield_basic and ctx=42. On the next resume, k_yield_basic
** runs and returns 142.
*/
static int cfn_yield_basic(lua_State *L) {
    lua_pushinteger(L, 1);
    return lua_yieldk(L, 1, (lua_KContext)42, k_yield_basic);
}

static int test_yieldk_basic(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: newstate\n"); return 1; }

    /* Register the C function as global "cyield". */
    lua_pushcfunction(L, cfn_yield_basic);
    lua_setglobal(L, "cyield");

    /*
    ** Create a coroutine that calls cyield, then drive it with
    ** coroutine.resume. The first resume yields 1 (from cfn_yield_basic).
    ** The second resume invokes k_yield_basic(ctx=42) which returns 142.
    */
    const char *code =
        "local co = coroutine.create(function()\n"
        "  return cyield()\n"
        "end)\n"
        "local ok1, v1 = coroutine.resume(co)\n"
        "local ok2, v2 = coroutine.resume(co)\n"
        "return ok1, v1, ok2, v2\n";
    if (luaL_loadbufferx(L, code, strlen(code), "=t1", NULL) != LUA_OK) {
        fprintf(stderr, "FAIL t1: load: %s\n", lua_tolstring(L, -1, NULL));
        lua_close(L);
        return 1;
    }
    if (lua_pcallk(L, 0, 4, 0, 0, NULL) != LUA_OK) {
        fprintf(stderr, "FAIL t1: pcall: %s\n", lua_tolstring(L, -1, NULL));
        lua_close(L);
        return 1;
    }

    int ok1 = lua_toboolean(L, -4);
    lua_Integer v1 = lua_tointegerx(L, -3, NULL);
    int ok2 = lua_toboolean(L, -2);
    lua_Integer v2 = lua_tointegerx(L, -1, NULL);

    if (!ok1 || v1 != 1) {
        fprintf(stderr, "FAIL t1: first resume ok=%d v=%lld, expected ok=1 v=1\n", ok1, (long long)v1);
        lua_close(L);
        return 1;
    }
    if (!ok2 || v2 != 142) {
        fprintf(stderr, "FAIL t1: second resume ok=%d v=%lld, expected ok=1 v=142\n", ok2, (long long)v2);
        lua_close(L);
        return 1;
    }

    lua_close(L);
    printf("PASS: t1 yieldk_basic\n");
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 2: lua_pcallk with a continuation (yield inside pcall)        */
/* ------------------------------------------------------------------ */

/*
** Continuation for the pcallk. Called when the resumed coroutine returns
** from the yield. ctx=100; we push ctx + 7 = 107 to prove k ran with the
** saved ctx.
*/
static int k_pcallk(lua_State *L, int status, lua_KContext ctx) {
    (void)status;
    lua_pushinteger(L, (lua_Integer)ctx + 7);
    return 1;
}

/*
** C function that uses lua_pcallk to call a Lua function which yields.
** The callee function is argument 1. We push a copy and pcallk it.
** If the callee yields, the pcall suspends; on resume, k_pcallk(ctx=100)
** runs and returns 107.
*/
static int cfn_pcallk_yielder(lua_State *L) {
    lua_pushvalue(L, 1);            /* push copy of the function */
    return lua_pcallk(L, 0, 1, 0, (lua_KContext)100, k_pcallk);
}

static int test_pcallk(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: newstate\n"); return 1; }

    lua_pushcfunction(L, cfn_pcallk_yielder);
    lua_setglobal(L, "cpcall");

    /*
    ** Coroutine calls cpcall with a Lua function that yields 5.
    ** The pcallk suspends at the yield; on the next resume, k_pcallk
    ** (ctx=100) runs and returns 107.
    */
    const char *code =
        "local co = coroutine.create(function()\n"
        "  local f = function() coroutine.yield(5); return 9 end\n"
        "  return cpcall(f)\n"
        "end)\n"
        "local ok1, v1 = coroutine.resume(co)\n"
        "local ok2, v2 = coroutine.resume(co)\n"
        "return ok1, v1, ok2, v2\n";
    if (luaL_loadbufferx(L, code, strlen(code), "=t2", NULL) != LUA_OK) {
        fprintf(stderr, "FAIL t2: load: %s\n", lua_tolstring(L, -1, NULL));
        lua_close(L);
        return 1;
    }
    if (lua_pcallk(L, 0, 4, 0, 0, NULL) != LUA_OK) {
        fprintf(stderr, "FAIL t2: pcall: %s\n", lua_tolstring(L, -1, NULL));
        lua_close(L);
        return 1;
    }

    int ok1 = lua_toboolean(L, -4);
    lua_Integer v1 = lua_tointegerx(L, -3, NULL);
    int ok2 = lua_toboolean(L, -2);
    lua_Integer v2 = lua_tointegerx(L, -1, NULL);

    if (!ok1 || v1 != 5) {
        fprintf(stderr, "FAIL t2: first resume ok=%d v=%lld, expected ok=1 v=5\n", ok1, (long long)v1);
        lua_close(L);
        return 1;
    }
    if (!ok2 || v2 != 107) {
        fprintf(stderr, "FAIL t2: second resume ok=%d v=%lld, expected ok=1 v=107\n", ok2, (long long)v2);
        lua_close(L);
        return 1;
    }

    lua_close(L);
    printf("PASS: t2 pcallk\n");
    return 0;
}

/* ------------------------------------------------------------------ */
/* Test 3: lua_callk with a continuation (yield inside callk)         */
/* ------------------------------------------------------------------ */

static int k_callk(lua_State *L, int status, lua_KContext ctx) {
    (void)status;
    lua_pushinteger(L, (lua_Integer)ctx + 3);
    return 1;
}

/*
** C function that uses lua_callk to call a Lua function which yields.
** The callee is argument 1. We push a copy and callk it.
** If the callee yields, the callk suspends; on resume, k_callk(ctx=200)
** runs and returns 203.
*/
static int cfn_callk_yielder(lua_State *L) {
    lua_pushvalue(L, 1);
    lua_callk(L, 0, 1, (lua_KContext)200, k_callk);
    /* If the callee returns normally (no yield), callk returns and we
    ** fall through with 1 result on the stack. */
    return 1;
}

static int test_callk(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: newstate\n"); return 1; }

    lua_pushcfunction(L, cfn_callk_yielder);
    lua_setglobal(L, "ccall");

    const char *code =
        "local co = coroutine.create(function()\n"
        "  local f = function() coroutine.yield(8); return 9 end\n"
        "  return ccall(f)\n"
        "end)\n"
        "local ok1, v1 = coroutine.resume(co)\n"
        "local ok2, v2 = coroutine.resume(co)\n"
        "return ok1, v1, ok2, v2\n";
    if (luaL_loadbufferx(L, code, strlen(code), "=t3", NULL) != LUA_OK) {
        fprintf(stderr, "FAIL t3: load: %s\n", lua_tolstring(L, -1, NULL));
        lua_close(L);
        return 1;
    }
    if (lua_pcallk(L, 0, 4, 0, 0, NULL) != LUA_OK) {
        fprintf(stderr, "FAIL t3: pcall: %s\n", lua_tolstring(L, -1, NULL));
        lua_close(L);
        return 1;
    }

    int ok1 = lua_toboolean(L, -4);
    lua_Integer v1 = lua_tointegerx(L, -3, NULL);
    int ok2 = lua_toboolean(L, -2);
    lua_Integer v2 = lua_tointegerx(L, -1, NULL);

    if (!ok1 || v1 != 8) {
        fprintf(stderr, "FAIL t3: first resume ok=%d v=%lld, expected ok=1 v=8\n", ok1, (long long)v1);
        lua_close(L);
        return 1;
    }
    if (!ok2 || v2 != 203) {
        fprintf(stderr, "FAIL t3: second resume ok=%d v=%lld, expected ok=1 v=203\n", ok2, (long long)v2);
        lua_close(L);
        return 1;
    }

    lua_close(L);
    printf("PASS: t3 callk\n");
    return 0;
}

/* ------------------------------------------------------------------ */

int main(void) {
    if (test_yieldk_basic()) return 1;
    if (test_pcallk())       return 1;
    if (test_callk())        return 1;
    printf("PASS: 10_continuations\n");
    return 0;
}
