/*
** 35_lauxlib_argerror.c — canonical differential for the lauxlib argument
** error object: every luaL_checklstring / luaL_optlstring non-string raise,
** luaL_checkoption invalid-option raise, and a direct luaL_typeerror /
** luaL_argerror goes through the one common PUC path
** (luaL_typeerror -> luaL_argerror -> luaL_error):
**
**   msg = [where "src:line: "] "bad argument #N to 'NAME' (EXTRA)"
**
** with NAME from getinfo "n" (the caller's call-site name), the
** pushglobalfuncname fallback (registry _LOADED search; '_G' globals print
** unqualified) or '?', the method/self correction ("calling 'NAME' on bad
** self"), argument type names from __name / "light userdata" /
** luaL_typename ("no value" for a missing argument), and the argument
** renumbering behind the implicit method self.
**
** Contexts:
**   A  host lua_pcall into an ANONYMOUS C function (no Lua caller, not in
**      _LOADED): the '?' form, no where-prefix — the reviewer-oracle shape.
**   B  a Lua string chunk calling REGISTERED functions: call-site names
**      (global / local / field / method), where-prefix, pcall'd C caller
**      (no call-site name -> _LOADED name or '?').
**
** Excluded (documented boundary, see the correction report): C functions
** reached through __call chains — PUC 5.5 renumbers those arguments via
** ar.extraargs (the __call-chain count in callstatus CIST_CCMT), which
** luazig does not persist per frame.
*/
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int marker;

/* --- the C functions under test --- */

static int cb_check1(lua_State *L) {
    size_t len;
    const char *s = luaL_checklstring(L, 1, &len);
    (void)s;
    lua_pushinteger(L, (lua_Integer)len);
    return 1;
}

/* checks argument 2: the method-call renumbering arm */
static int cb_check2(lua_State *L) {
    size_t len;
    const char *s = luaL_checklstring(L, 2, &len);
    (void)s;
    lua_pushinteger(L, (lua_Integer)len);
    return 1;
}

static int cb_opt(lua_State *L) {
    size_t len;
    const char *s = luaL_optlstring(L, 1, "dflt", &len);
    (void)s;
    lua_pushinteger(L, (lua_Integer)len);
    return 1;
}

static const char *const opts[] = {"alpha", "beta", NULL};

static int cb_optn(lua_State *L) {
    lua_pushinteger(L, luaL_checkoption(L, 1, NULL, opts));
    return 1;
}

static int cb_optd(lua_State *L) {
    lua_pushinteger(L, luaL_checkoption(L, 1, "beta", opts));
    return 1;
}

static int cb_typeerr(lua_State *L) {
    return luaL_typeerror(L, 1, "widget");
}

static int cb_argerr(lua_State *L) {
    return luaL_argerror(L, 1, "custom problem");
}

/* --- harness --- */

static void try_call(lua_State *L, int nargs, int nres, const char *tag) {
    int st = lua_pcall(L, nargs, nres, 0);
    if (st != LUA_OK) {
        const char *msg = lua_tostring(L, -1);
        printf("%s status=%d msg=%s\n", tag, st, msg ? msg : "<nonstring>");
        lua_pop(L, 1);
    }
    else if (nres > 0) {
        printf("%s result=%lld\n", tag, (long long)lua_tointeger(L, -1));
        lua_pop(L, 1);
    }
    else {
        printf("%s status=0\n", tag);
    }
}

static void run_chunk(lua_State *L, const char *tag, const char *code) {
    int st = luaL_dostring(L, code);
    if (st != LUA_OK) {
        const char *msg = lua_tostring(L, -1);
        printf("%s status=%d msg=%s\n", tag, st, msg ? msg : "<nonstring>");
        lua_pop(L, 1);
    }
    else {
        printf("%s status=0\n", tag);
    }
}

/* Chunk harness for chunks that must SUCCEED while capturing a value:
** the chunk stores it in the global RES; all output goes through printf
** (a Lua-side print would interleave with C stdout buffering). */
static void run_chunk_res(lua_State *L, const char *tag, const char *code) {
    int st;
    lua_pushnil(L);
    lua_setglobal(L, "RES");
    st = luaL_dostring(L, code);
    if (st != LUA_OK) {
        const char *msg = lua_tostring(L, -1);
        printf("%s status=%d msg=%s\n", tag, st, msg ? msg : "<nonstring>");
        lua_pop(L, 1);
    }
    else {
        lua_getglobal(L, "RES");
        printf("%s status=0 res=%lld\n", tag, (long long)lua_tointeger(L, -1));
        lua_pop(L, 1);
    }
}

/* Chunk harness for the pcall'd-caller contexts: the chunk catches the
** error itself and stores the message string in the global MSG (printed
** here, through printf, keeping the output stream single-sourced). */
static void run_chunk_msg(lua_State *L, const char *tag, const char *code) {
    int st;
    lua_pushnil(L);
    lua_setglobal(L, "MSG");
    st = luaL_dostring(L, code);
    if (st != LUA_OK) {
        const char *msg = lua_tostring(L, -1);
        printf("%s status=%d msg=%s\n", tag, st, msg ? msg : "<nonstring>");
        lua_pop(L, 1);
    }
    else {
        const char *m;
        lua_getglobal(L, "MSG");
        m = lua_tostring(L, -1);
        printf("%s status=0 msg=%s\n", tag, m ? m : "<nonstring>");
        lua_pop(L, 1);
    }
}

int main(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* Section A: anonymous C function called straight from the host —
    ** no Lua caller frame, function not in _LOADED: '?' name, no
    ** where-prefix. */

    lua_pushcfunction(L, cb_check1);
    lua_pushboolean(L, 1);
    try_call(L, 1, 0, "A1");                 /* the reviewer-oracle form */

    lua_pushcfunction(L, cb_check1);
    try_call(L, 0, 0, "A2");                 /* missing argument: no value */

    lua_pushcfunction(L, cb_check1);
    lua_pushlightuserdata(L, &marker);
    try_call(L, 1, 0, "A3");                 /* light userdata type name */

    lua_pushcfunction(L, cb_check1);         /* table with string __name */
    lua_newtable(L);
    lua_newtable(L);
    lua_pushstring(L, "Buffer");
    lua_setfield(L, -2, "__name");
    lua_setmetatable(L, -2);
    try_call(L, 1, 0, "A4");

    lua_pushcfunction(L, cb_check1);         /* non-string __name ignored */
    lua_newtable(L);
    lua_newtable(L);
    lua_pushinteger(L, 42);
    lua_setfield(L, -2, "__name");
    lua_setmetatable(L, -2);
    try_call(L, 1, 0, "A5");

    lua_pushcfunction(L, cb_check1);         /* userdata with string __name */
    lua_newuserdata(L, sizeof(void *));
    lua_newtable(L);
    lua_pushstring(L, "UData");
    lua_setfield(L, -2, "__name");
    lua_setmetatable(L, -2);
    try_call(L, 1, 0, "A6");

    lua_pushcfunction(L, cb_opt);            /* optlstring non-string */
    lua_pushboolean(L, 1);
    try_call(L, 1, 0, "A7");

    lua_pushcfunction(L, cb_optn);           /* checkoption invalid */
    lua_pushstring(L, "bogus");
    try_call(L, 1, 0, "A8");

    lua_pushcfunction(L, cb_optn);           /* checkoption missing */
    try_call(L, 0, 0, "A9");

    lua_pushcfunction(L, cb_check2);         /* argument 2 numbering */
    lua_pushstring(L, "ok");
    lua_pushboolean(L, 1);
    try_call(L, 2, 0, "A10");

    lua_pushcfunction(L, cb_typeerr);        /* direct luaL_typeerror */
    lua_pushboolean(L, 1);
    try_call(L, 1, 0, "A11");

    lua_pushcfunction(L, cb_argerr);         /* direct luaL_argerror */
    lua_pushboolean(L, 1);
    try_call(L, 1, 0, "A12");

    lua_pushcfunction(L, cb_check1);         /* number converts, no error */
    lua_pushinteger(L, 123);
    try_call(L, 1, 1, "A13");

    lua_pushcfunction(L, cb_opt);            /* absent -> default, no error */
    try_call(L, 0, 1, "A14");

    /* Section B: registered functions called from a Lua string chunk —
    ** call-site names, where-prefix, method/self, pcall'd C caller. */

    lua_register(L, "chk", cb_check1);
    lua_register(L, "chk2", cb_check2);
    lua_register(L, "opt", cb_opt);
    lua_register(L, "optn", cb_optn);
    lua_register(L, "optd", cb_optd);
    lua_newtable(L);                         /* T.anon: anonymous for Lua */
    lua_pushcfunction(L, cb_check1);
    lua_setfield(L, -2, "anon");
    lua_setglobal(L, "T");

    run_chunk(L, "B1", "chk(true)");         /* global call-site name */
    run_chunk(L, "B2", "chk()");             /* missing: no value */
    run_chunk(L, "B3", "local g = chk g(true)");       /* local name */
    run_chunk(L, "B4", "local t = {} t.fn = chk t.fn(true)"); /* field */
    run_chunk(L, "B5", "local o = {} o.m = chk o:m()"); /* bad self */
    run_chunk(L, "B6", "local o = {} o.m = chk2 o:m(true)"); /* renumber */
    run_chunk_msg(L, "B7", "local ok, err = pcall(chk, true) MSG = err");
    run_chunk_msg(L, "B8", "local ok, err = pcall(T.anon, true) MSG = err");
    run_chunk(L, "B9", "chk(setmetatable({}, {__name = 'Buffer'}))");
    run_chunk(L, "B10", "opt(true)");        /* optlstring via Lua */
    run_chunk(L, "B11", "optn('zzz')");      /* invalid option via Lua */
    run_chunk(L, "B12", "optd('bogus')");    /* def path, string arg */
    run_chunk_res(L, "B13", "RES = chk(12)");   /* number converts */
    run_chunk_res(L, "B14", "RES = opt(nil)");  /* nil -> default */
    run_chunk_res(L, "B15", "RES = optn('alpha')");     /* valid option */
    run_chunk_res(L, "B16", "RES = optd(nil)");         /* default option */

    lua_close(L);
    return 0;
}
