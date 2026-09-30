/*
** 36_ccmt_abi.c — canonical differential for the PUC-layout lua_Debug ABI
** and the C-side __call-chain (CIST_CCMT) readers:
**
**   - the published lua_Debug layout (field offsets/size/alignment) —
**     printed from offsetof(), so any layout divergence between the
**     compile-time header and the PUC contract shows as a diff;
**   - luaL_argerror behind a __call chain (PUC lauxlib.c:171-194):
**     "bad extra argument #N" when the failing argument is one of the
**     chain-shifted extras, argument renumbering past the chain count,
**     and the method/self interaction with both;
**   - lua_getinfo("t") from inside a C function reached through a chain:
**     ar.extraargs is the frame's committed __call-link count;
**   - lua_getinfo("r") transfer window: zero outside any hook, and the
**     (ftransfer, ntransfer) of the hooked frame from inside a CALL hook
**     (PUC ldebug.c:376-383) — including ntransfer beyond the 16-bit
**     range (70001 actual arguments), which the int-typed fields must
**     carry;
**   - the chain length boundary (15 links commit, the 16th link raises
**     "'__call' chain too long") on the bytecode call path;
**   - a C continuation frame (lua_yieldk) survives suspend/resume with
**     its chain count intact (argerror from the continuation).
**
** Differential lanes (Makefile):
**   36_ccmt_abi        luazig header + luazig library
**   36_ccmt_abi-puc    PUC header    + PUC library
**   36_ccmt_abi-xread  PUC header    + luazig library (cross-read proof:
**                     a PUC-header client must read every public field
**                     byte-identically from the luazig runtime)
**
** i_ci is opaque and never printed. Excluded (pre-existing divergences,
** not part of this contract): where-attribution of chain-overflow errors
** raised on the C-API call path; the pcallk continuation-window payload.
*/
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* --- the C functions under test --- */

static int cb_check1(lua_State *L) {
    size_t len;
    const char *s = luaL_checklstring(L, 1, &len);
    (void)s;
    lua_pushinteger(L, (lua_Integer)len);
    return 1;
}

static int cb_check2(lua_State *L) {
    size_t len;
    const char *s = luaL_checklstring(L, 2, &len);
    (void)s;
    lua_pushinteger(L, (lua_Integer)len);
    return 1;
}

static int cb_check3(lua_State *L) {
    size_t len;
    const char *s = luaL_checklstring(L, 3, &len);
    (void)s;
    lua_pushinteger(L, (lua_Integer)len);
    return 1;
}

/* getinfo("t") on its own (level 0) frame: the C activation's chain count */
static int cb_info(lua_State *L) {
    lua_Debug ar;
    if (lua_getstack(L, 0, &ar) == 0 || !lua_getinfo(L, "t", &ar)) {
        printf("F6 t: getinfo=FAIL\n");
        return 0;
    }
    printf("F6 t: extraargs=%d istailcall=%d\n",
           (int)ar.extraargs, (int)ar.istailcall);
    return 0;
}

/* getinfo("r") outside any hook: both transfer fields are zero */
static int cb_big(lua_State *L) {
    lua_Debug ar;
    (void)L;
    if (lua_getstack(L, 0, &ar) == 0 || !lua_getinfo(L, "r", &ar)) {
        printf("ZR: getinfo=FAIL\n");
        return 0;
    }
    printf("ZR ft=%d nt=%d\n", (int)ar.ftransfer, (int)ar.ntransfer);
    return 0;
}

/* getinfo("St") on the level-1 (Lua caller) frame: short_src of a named
** chunk and the zero chain count of a plain Lua activation */
static int cb_srcinfo(lua_State *L) {
    lua_Debug ar;
    if (lua_getstack(L, 1, &ar) == 0 || !lua_getinfo(L, "St", &ar)) {
        printf("SR: getinfo=FAIL\n");
        return 0;
    }
    printf("SR src=%.24s ea=%d tail=%d\n",
           ar.short_src, (int)ar.extraargs, (int)ar.istailcall);
    lua_pushstring(L, "ok");
    return 1;
}

static int cont_chk(lua_State *L, int status, lua_KContext ctx) {
    size_t len;
    (void)status; (void)ctx;
    printf("F9 CONT: running continuation, status=%d\n", status);
    const char *s = luaL_checklstring(L, 1, &len);
    (void)s;
    lua_pushinteger(L, (lua_Integer)len);
    return 1;
}

static int cb_yieldchk(lua_State *L) {
    return lua_yieldk(L, 0, 0, cont_chk);
}

/* CALL hook: print the hooked frame's chain count whenever nonzero —
** proves the chained builtin activation is a real C frame whose callstatus
** carries CIST_CCMT (read through the ar handed to the hook) */
static void thook(lua_State *L, lua_Debug *ar) {
    if (ar->event != LUA_HOOKCALL) return;
    if (!lua_getinfo(L, "t", ar)) return;
    if (ar->extraargs > 0)
        printf("F7f ea=%d\n", (int)ar->extraargs);
}

/* --- harness --- */

/* A chain table of `links` __call links ending at f: calling t(...) shifts
** the arguments up once per link and finally calls f. */
static void push_chain(lua_State *L, lua_CFunction f, int links) {
    int i;
    lua_pushcfunction(L, f);              /* v = f */
    for (i = 0; i < links; i++) {
        int vidx = lua_gettop(L);         /* v is at vidx */
        lua_getglobal(L, "setmetatable");
        lua_newtable(L);                  /* {} */
        lua_createtable(L, 0, 1);         /* mt */
        lua_pushvalue(L, vidx);
        lua_setfield(L, -2, "__call");    /* mt.__call = v */
        lua_call(L, 2, 1);                /* v = setmetatable({}, mt) */
        lua_replace(L, vidx);             /* drop the previous v */
    }
}

static void try_call(lua_State *L, int nargs, const char *tag) {
    int st = lua_pcall(L, nargs, 0, 0);
    if (st != LUA_OK) {
        const char *msg = lua_tostring(L, -1);
        printf("%s msg=%s\n", tag, msg ? msg : "<nonstring>");
        lua_pop(L, 1);
    }
    else {
        printf("%s status=0\n", tag);
    }
}

/* All chunks run under the fixed name "ccmt36": the where-prefix then is
** "ccmt36:LINE:" in every lane (byte-comparable), independent of the
** source-truncation formatting of long inline chunk sources. */

static void run_chunk(lua_State *L, const char *tag, const char *code) {
    int st = luaL_loadbuffer(L, code, strlen(code), "ccmt36");
    if (st == LUA_OK) st = lua_pcall(L, 0, 0, 0);
    if (st != LUA_OK) {
        const char *msg = lua_tostring(L, -1);
        printf("%s msg=%s\n", tag, msg ? msg : "<nonstring>");
        lua_pop(L, 1);
    }
    else {
        printf("%s status=0\n", tag);
    }
}

static void run_chunk_msg(lua_State *L, const char *tag, const char *code) {
    int st;
    lua_pushnil(L);
    lua_setglobal(L, "MSG");
    st = luaL_loadbuffer(L, code, strlen(code), "ccmt36");
    if (st == LUA_OK) st = lua_pcall(L, 0, 0, 0);
    if (st != LUA_OK) {
        const char *msg = lua_tostring(L, -1);
        printf("%s msg=%s\n", tag, msg ? msg : "<nonstring>");
        lua_pop(L, 1);
    }
    else {
        const char *m;
        lua_getglobal(L, "MSG");
        m = lua_tostring(L, -1);
        printf("%s msg=%s\n", tag, m ? m : "<nonstring>");
        lua_pop(L, 1);
    }
}

/* CALL hook: on the C target "big" print the transfer window of the
** hooked frame (ar handed to the hook) and of an unhoked deeper frame. */
static void rhook(lua_State *L, lua_Debug *ar) {
    lua_Debug other;
    if (ar->event != LUA_HOOKCALL) return;
    if (!lua_getinfo(L, "nr", ar)) return;
    if (ar->name == NULL || strcmp(ar->name, "big") != 0) return;
    printf("RH name=%s ft=%d nt=%d\n",
           ar->name, (int)ar->ftransfer, (int)ar->ntransfer);
    if (lua_getstack(L, 1, &other) && lua_getinfo(L, "r", &other)) {
        printf("RH1 ft=%d nt=%d\n", (int)other.ftransfer, (int)other.ntransfer);
    }
}

int main(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* --- ABI layout (compile-time constants; identical in every lane) --- */
    printf("ABI sizeof=%d align=%d\n",
           (int)sizeof(lua_Debug), (int)_Alignof(lua_Debug));
    printf("ABI off:event=%d name=%d namewhat=%d what=%d source=%d "
           "srclen=%d currentline=%d linedefined=%d lastlinedefined=%d "
           "nups=%d nparams=%d isvararg=%d extraargs=%d istailcall=%d "
           "ftransfer=%d ntransfer=%d short_src=%d i_ci=%d\n",
           (int)offsetof(lua_Debug, event),
           (int)offsetof(lua_Debug, name),
           (int)offsetof(lua_Debug, namewhat),
           (int)offsetof(lua_Debug, what),
           (int)offsetof(lua_Debug, source),
           (int)offsetof(lua_Debug, srclen),
           (int)offsetof(lua_Debug, currentline),
           (int)offsetof(lua_Debug, linedefined),
           (int)offsetof(lua_Debug, lastlinedefined),
           (int)offsetof(lua_Debug, nups),
           (int)offsetof(lua_Debug, nparams),
           (int)offsetof(lua_Debug, isvararg),
           (int)offsetof(lua_Debug, extraargs),
           (int)offsetof(lua_Debug, istailcall),
           (int)offsetof(lua_Debug, ftransfer),
           (int)offsetof(lua_Debug, ntransfer),
           (int)offsetof(lua_Debug, short_src),
           (int)offsetof(lua_Debug, i_ci));

    lua_register(L, "chk", cb_check1);
    lua_register(L, "chk2", cb_check2);
    lua_register(L, "chk3", cb_check3);
    lua_register(L, "info", cb_info);
    lua_register(L, "big", cb_big);
    lua_register(L, "yieldchk", cb_yieldchk);

    /* --- argerror behind chains, host context (no Lua caller: '?') --- */

    push_chain(L, cb_check1, 1);      /* F1: arg1 is a chain extra */
    lua_pushboolean(L, 1);
    try_call(L, 1, "F1");

    push_chain(L, cb_check3, 2);      /* F2a: arg3 renumbers to 1 */
    lua_pushboolean(L, 1);
    lua_pushboolean(L, 0);
    try_call(L, 2, "F2a");

    push_chain(L, cb_check1, 2);      /* F2b: arg2 is still extra */
    lua_pushboolean(L, 1);
    lua_pushboolean(L, 0);
    try_call(L, 2, "F2b");

    /* --- method syntax interacting with the chain count (Lua caller) --- */

    run_chunk_msg(L, "F3a",
        "local c = setmetatable({}, {__call = chk})\n"
        "local o = {} o.probe = c\n"
        "local ok, err = pcall(function() return o:probe(true) end)\n"
        "MSG = err");

    run_chunk_msg(L, "F3b",
        "local c = setmetatable({}, {__call = chk2})\n"
        "local o = {} o.probe = c\n"
        "local ok, err = pcall(function() return o:probe(true) end)\n"
        "MSG = err");

    /* --- getinfo("t") from a chained C function --- */

    push_chain(L, cb_info, 1);
    try_call(L, 0, "F6d");

    push_chain(L, cb_info, 2);
    try_call(L, 0, "F6e");

    /* --- getinfo("r"): the transfer window --- */

    lua_sethook(L, rhook, LUA_MASKCALL, 0);
    run_chunk(L, "R1", "big(42)");
    run_chunk(L, "R2",
        "local t = {} for i = 1, 70001 do t[i] = i end\n"
        "big(table.unpack(t))");
    lua_sethook(L, NULL, 0, 0);

    /* --- tailcall into a chain reaching a C function (fresh frame) --- */

    run_chunk_msg(L, "F7c",
        "local t7 = setmetatable({}, {__call = chk2})\n"
        "local function f7() return t7(true) end\n"
        "local ok, err = pcall(f7)\n"
        "MSG = err");

    /* --- non-tailcall chain reaching a C function (OP_CALL arm) --- */

    push_chain(L, cb_check1, 15);
    lua_setglobal(L, "c15chk");
    run_chunk_msg(L, "F7d",
        "local function f7d() local x = c15chk() return x end\n"
        "local ok, err = pcall(f7d)\n"
        "MSG = err");

    /* --- a chain table as a direct for-iterator (TFORCALL arm) --- */

    run_chunk_msg(L, "F7e",
        "local ok, err = pcall(function() for x in c15chk do end end)\n"
        "MSG = err");

    /* --- C call-hook on chained builtin activations (sync lane): the
    ** event's frame reports the chain count — host resolution (pcall) and
    ** the bytecode OP_CALL path alike --- */

    lua_sethook(L, thook, LUA_MASKCALL, 0);
    run_chunk(L, "F7f",
        "local cg = setmetatable({}, {__call = collectgarbage})\n"
        "local sub = setmetatable({}, {__call = string.sub})\n"
        "pcall(cg, 'count')\n"
        "pcall(sub, 1, 2)\n"
        "local t15 = setmetatable({}, {__call =\n"
        "  setmetatable({}, {__call = collectgarbage})})\n"
        "pcall(t15, 'count')");
    lua_sethook(L, NULL, 0, 0);

    /* --- chain length boundary on the bytecode call path --- */

    run_chunk_msg(L, "N15",
        "local function build(n)\n"
        "  local v = chk\n"
        "  for i = 1, n do v = setmetatable({}, {__call = v}) end\n"
        "  return v\n"
        "end\n"
        "local c15 = build(15)\n"
        "local ok, err = pcall(function() return c15() end)\n"
        "MSG = err");

    run_chunk_msg(L, "N16",
        "local function build(n)\n"
        "  local v = chk\n"
        "  for i = 1, n do v = setmetatable({}, {__call = v}) end\n"
        "  return v\n"
        "end\n"
        "local c16 = build(16)\n"
        "local ok, err = pcall(function() return c16() end)\n"
        "MSG = err");

    /* --- yieldk continuation keeps the frame (and its chain count) --- */

    {
        static const char *f9 =
            "local co = coroutine.create(function()\n"
            "  local t = setmetatable({}, {__call = yieldchk})\n"
            "  local v = t(true)\n"
            "  return v\n"
            "end)\n"
            "local a, b = coroutine.resume(co)\n"
            "local c, d = coroutine.resume(co)\n"
            "MSG = tostring(a)..','..tostring(b)..' | '..tostring(c)..','..tostring(d)";
        lua_pushnil(L);
        lua_setglobal(L, "MSG");
        if (luaL_loadbuffer(L, f9, strlen(f9), "f9chunk") != LUA_OK ||
            lua_pcall(L, 0, 0, 0) != LUA_OK) {
            const char *msg = lua_tostring(L, -1);
            printf("F9 msg=%s\n", msg ? msg : "<nonstring>");
            lua_pop(L, 1);
        }
        else {
            const char *m;
            lua_getglobal(L, "MSG");
            m = lua_tostring(L, -1);
            printf("F9 result=%s\n", m ? m : "<nonstring>");
            lua_pop(L, 1);
        }
    }

    /* --- short_src through a named chunk (cross-read lane) --- */

    {
        static const char *sr = "local x = info2()\n";
        int st;
        lua_register(L, "info2", cb_srcinfo);
        st = luaL_loadbuffer(L, sr, strlen(sr), "PROBECHUNK");
        if (st == LUA_OK) st = lua_pcall(L, 0, 0, 0);
        if (st != LUA_OK) {
            const char *msg = lua_tostring(L, -1);
            printf("SR msg=%s\n", msg ? msg : "<nonstring>");
            lua_pop(L, 1);
        }
    }

    lua_close(L);
    return 0;
}
