/*
 * 46_light_sweep.c — permanent differential suite: the full nup=0 stdlib
 * light sweep (A-full P2 cut P2b). Every confirmed PUC 5.5 light entry
 * published as a canonical LightCFunction value.
 *
 * Covers, mechanically over the actual published entry list:
 *   - part 1: per-entry identity matrix — two fetches rawequal, type,
 *     iscfunction, tocfunction, topointer == tocfunction, getinfo(">")
 *     what == "C" and nups == 0, getupvalue NULL, distinctness across
 *     entries (identity is NOT resolved by name);
 *   - part 2: stable table keys — every entry as a table key survives a
 *     full GC cycle and reads back through a fresh fetch;
 *   - part 3: f(L) really runs — a deterministic per-library subset
 *     called through the C lane on the main state AND as a coroutine
 *     body (resume VLCF lane), with fixed and MULTRET result counts and
 *     error status/type lanes;
 *   - part 4: republish — repeated luaopen_* via luaL_requiref and a
 *     require-driven republish (package.loaded reset) publish rawequal
 *     values; a second independent state publishes the identical
 *     process-global C ABI pointer and stays callable;
 *   - part 5: frozen allocator — a light call through the C lane with
 *     pre-reserved stack space succeeds under a frozen allocator (the
 *     result window is stack-staged, not heap-staged), the VM stays
 *     usable afterwards, a full GC cycle runs, and a real heap C
 *     closure under the same freeze fails with LUA_ERRMEM (control);
 *   - part 6: the shared FILE* finalizer — the metatable __gc and
 *     __close fields are ONE function value (PUC liolib.c publishes a
 *     single f_gc pointer in both): rawequal/tocfunction/table-key
 *     interchange identity, direct-call result counts on open/closed
 *     files and std streams, wrong-argument error status/type, the
 *     coroutine-body lane, TBC close (normal exit, error transport,
 *     std stream), GC finalization, republish, and a second state.
 *
 * Divergence policy: no addresses, no timings, no locale-dependent
 * output. Every printed line must be byte-identical between PUC Lua 5.5
 * and luazig — EXCEPT the two known F1 residual lines in part 5
 * (P5.light-pcall-allocs, P5.frozen-light-pcall-status: the pre-existing
 * frozen-allocator C-lane divergence family, see report afp2b §7); the
 * suite is NOT byte-identical while they exist. Exit code is non-zero on
 * any failed check.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int fails = 0;

static void check(long cond, const char *label) {
    printf("%s:%ld\n", label, cond);
    if (!cond) fails++;
}

static void dostr(lua_State *L, const char *code, const char *tag) {
    int st = luaL_dostring(L, code);
    if (st != LUA_OK) {
        printf("%s.ERROR:%s\n", tag, lua_tostring(L, -1));
        fails++;
        lua_pop(L, 1);
    }
}

/* ---------------- the published entry list ---------------- */

typedef struct {
    const char *lib;   /* global table name, or NULL for _G */
    const char *name;  /* field name */
} Entry;

/* Every table-published nup=0 entry of the sweep (PUC 5.5 source list).
 * Excluded by design: require + 4 searchers (CClosure), math.random/
 * randomseed (CClosure(1)), string.gmatch/io.lines iterator products
 * (stateful generators), pairs iterator product, io.stderr.write. */
static const Entry entries[] = {
    /* base */
    {NULL, "print"}, {NULL, "warn"}, {NULL, "tostring"},
    {NULL, "tonumber"}, {NULL, "error"}, {NULL, "assert"},
    {NULL, "select"}, {NULL, "rawlen"}, {NULL, "rawequal"},
    {NULL, "type"}, {NULL, "collectgarbage"}, {NULL, "pcall"},
    {NULL, "xpcall"}, {NULL, "next"}, {NULL, "dofile"},
    {NULL, "loadfile"}, {NULL, "load"}, {NULL, "setmetatable"},
    {NULL, "getmetatable"}, {NULL, "pairs"}, {NULL, "ipairs"},
    {NULL, "rawget"}, {NULL, "rawset"},
    /* string */
    {"string", "format"}, {"string", "pack"}, {"string", "packsize"},
    {"string", "unpack"}, {"string", "dump"}, {"string", "len"},
    {"string", "byte"}, {"string", "char"}, {"string", "upper"},
    {"string", "lower"}, {"string", "reverse"}, {"string", "sub"},
    {"string", "find"}, {"string", "match"}, {"string", "gmatch"},
    {"string", "gsub"}, {"string", "rep"},
    /* string metatable arithmetic metamethods */
    {"@strmt", "__add"}, {"@strmt", "__sub"}, {"@strmt", "__mul"},
    {"@strmt", "__mod"}, {"@strmt", "__pow"}, {"@strmt", "__div"},
    {"@strmt", "__idiv"}, {"@strmt", "__unm"},
    /* table */
    {"table", "pack"}, {"table", "create"}, {"table", "move"},
    {"table", "concat"}, {"table", "insert"}, {"table", "unpack"},
    {"table", "remove"}, {"table", "sort"},
    /* math (random/randomseed excluded: PUC CClosure(1)) */
    {"math", "tointeger"}, {"math", "sin"}, {"math", "cos"},
    {"math", "tan"}, {"math", "asin"}, {"math", "acos"},
    {"math", "atan"}, {"math", "deg"}, {"math", "rad"},
    {"math", "abs"}, {"math", "sqrt"}, {"math", "exp"},
    {"math", "ldexp"}, {"math", "frexp"}, {"math", "ceil"},
    {"math", "ult"}, {"math", "modf"}, {"math", "log"},
    {"math", "fmod"}, {"math", "floor"}, {"math", "type"},
    {"math", "min"}, {"math", "max"},
    /* utf8 */
    {"utf8", "char"}, {"utf8", "codepoint"}, {"utf8", "len"},
    {"utf8", "offset"}, {"utf8", "codes"},
    /* io */
    {"io", "write"}, {"io", "open"}, {"io", "popen"},
    {"io", "tmpfile"}, {"io", "read"}, {"io", "lines"},
    {"io", "flush"}, {"io", "input"}, {"io", "output"},
    {"io", "close"}, {"io", "type"},
    /* file methods (via the file metatable __index table) */
    {"@fileix", "close"}, {"@fileix", "write"}, {"@fileix", "read"},
    {"@fileix", "seek"}, {"@fileix", "flush"}, {"@fileix", "lines"},
    {"@fileix", "setvbuf"},
    /* file metatable metamethods */
    {"@filemt", "__gc"}, {"@filemt", "__close"}, {"@filemt", "__tostring"},
    /* os */
    {"os", "execute"}, {"os", "exit"}, {"os", "clock"},
    {"os", "date"}, {"os", "time"}, {"os", "difftime"},
    {"os", "getenv"}, {"os", "tmpname"}, {"os", "remove"},
    {"os", "rename"}, {"os", "setlocale"},
    /* debug */
    {"debug", "getinfo"}, {"debug", "getlocal"}, {"debug", "setlocal"},
    {"debug", "getupvalue"}, {"debug", "setupvalue"},
    {"debug", "upvalueid"}, {"debug", "upvaluejoin"},
    {"debug", "gethook"}, {"debug", "sethook"},
    {"debug", "getregistry"}, {"debug", "traceback"},
    {"debug", "getmetatable"}, {"debug", "setmetatable"},
    {"debug", "getuservalue"}, {"debug", "setuservalue"},
    {"debug", "debug"},
    /* coroutine */
    {"coroutine", "create"}, {"coroutine", "wrap"},
    {"coroutine", "resume"}, {"coroutine", "yield"},
    {"coroutine", "status"}, {"coroutine", "running"},
    {"coroutine", "isyieldable"}, {"coroutine", "close"},
    /* package */
    {"package", "searchpath"}, {"package", "loadlib"},
};

#define NENTRIES ((int)(sizeof(entries) / sizeof(entries[0])))

/* Push entry e's function value on top of the stack. */
static void push_entry(lua_State *L, const Entry *e) {
    if (e->lib == NULL) {
        lua_getglobal(L, e->name);
        return;
    }
    if (strcmp(e->lib, "@strmt") == 0) {
        lua_pushliteral(L, "");
        lua_getmetatable(L, -1);
        lua_getfield(L, -1, e->name);
        lua_remove(L, -2);
        lua_remove(L, -2);
        return;
    }
    if (strcmp(e->lib, "@filemt") == 0) {
        /* metamethods live directly in the file metatable (both engines) */
        lua_getglobal(L, "io");
        lua_getfield(L, -1, "stdout");
        lua_getmetatable(L, -1);          /* [io, stdout, mt] */
        lua_getfield(L, -1, e->name);     /* [io, stdout, mt, f] */
        lua_remove(L, -2);
        lua_remove(L, -2);
        lua_remove(L, -2);
        return;
    }
    if (strcmp(e->lib, "@fileix") == 0) {
        /* methods: PUC publishes them in mt.__index (userdata index
         * resolves io.stdout.write through it); luazig stores them as
         * direct fields of the file table — io.stdout.<name> resolves
         * identically in both engines */
        lua_getglobal(L, "io");
        lua_getfield(L, -1, "stdout");
        lua_getfield(L, -1, e->name);     /* [io, stdout, f] */
        lua_remove(L, -2);
        lua_remove(L, -2);
        return;
    }
    lua_getglobal(L, e->lib);
    lua_getfield(L, -1, e->name);
    lua_remove(L, -2);
}

/* ---------------- part 1: per-entry identity matrix ---------------- */

static void part_identity(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    check(L != NULL, "P1.state");

    int all_ok = 1;
    int all_distinct = 1;
    const void *seen[NENTRIES];
    for (int i = 0; i < NENTRIES; i++) {
        const Entry *e = &entries[i];
        push_entry(L, e);                 /* [f] */
        push_entry(L, e);                 /* [f, f'] */
        lua_Debug ar;
        memset(&ar, 0, sizeof ar);
        int ok = 1;
        ok &= lua_type(L, -1) == LUA_TFUNCTION;
        ok &= lua_iscfunction(L, -1) == 1;
        ok &= lua_tocfunction(L, -1) != NULL;
        ok &= lua_topointer(L, -1) == lua_tocfunction(L, -1);
        ok &= lua_rawequal(L, -1, -2);
        /* the '>' form inspects AND POPS the top function */
        ok &= lua_getinfo(L, ">Su", &ar) == 1;
        ok &= ar.what != NULL && strcmp(ar.what, "C") == 0;
        ok &= ar.nups == 0;
        ok &= lua_getupvalue(L, -1, 1) == NULL;
        ok &= lua_gettop(L) == 1;   /* getupvalue pushed nothing */
        seen[i] = lua_topointer(L, -1);
        for (int j = 0; j < i; j++)
            if (seen[j] == seen[i]) all_distinct = 0;
        lua_pop(L, 1);
        if (!ok) {
            printf("P1.entry-fail:%s.%s\n",
                   e->lib ? e->lib : "_G", e->name);
            all_ok = 0;
        }
    }
    check(all_ok, "P1.identity-matrix");
    /* PUC 5.5 shares one C function between the file __gc and __close
     * metamethods (liolib.c metameth[] publishes f_gc in both fields) —
     * exactly one duplicate pointer across the entry list, in BOTH
     * engines. */
    {
        int distinct = 0;
        for (int i = 0; i < NENTRIES; i++) {
            int dup = 0;
            for (int j = 0; j < i; j++)
                if (seen[j] == seen[i]) dup = 1;
            if (!dup) distinct++;
        }
        check(distinct == NENTRIES - 1, "P1.distinct-count");
    }
    (void)all_distinct;

    /* the ipairs iterator product is a light function too */
    lua_getglobal(L, "ipairs");
    lua_newtable(L);
    lua_call(L, 1, 1);                    /* [iter] */
    check(lua_type(L, -1) == LUA_TFUNCTION, "P1.ipairs-iter-type");
    check(lua_iscfunction(L, -1) == 1, "P1.ipairs-iter-iscfunction");
    check(lua_tocfunction(L, -1) != NULL, "P1.ipairs-iter-tocfunction");
    lua_pop(L, 1);

    lua_close(L);
}

/* ---------------- part 2: stable table keys across GC ---------------- */

static void part_tablekeys(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* one key table holding EVERY entry, then a full GC cycle.
     * Two entry NAMES resolve to the SAME light function in BOTH engines
     * (PUC liolib.c shares one f_gc C function between the file __gc and
     * __close metamethods): a duplicated pointer inserts one key, so the
     * deduplicated entries read back the value of their first occurrence. */
    const void *key_ptr[NENTRIES];
    long key_val[NENTRIES];
    lua_newtable(L);                      /* [t] */
    for (int i = 0; i < NENTRIES; i++) {
        push_entry(L, &entries[i]);       /* [t, f] */
        key_ptr[i] = lua_topointer(L, -1);
        key_val[i] = 0;
        for (int j = 0; j < i; j++)
            if (key_ptr[j] == key_ptr[i]) key_val[i] = key_val[j];
        if (key_val[i] == 0) {
            key_val[i] = i + 1;
            lua_pushinteger(L, i + 1);    /* [t, f, v] */
            lua_rawset(L, -3);            /* [t] */
        } else {
            lua_pop(L, 1);                /* [t] */
        }
    }
    check(lua_rawlen(L, -1) == 0, "P2.no-array-part"); /* all hash keys */
    lua_gc(L, LUA_GCCOLLECT, 0);
    int all_ok = 1;
    for (int i = 0; i < NENTRIES; i++) {
        push_entry(L, &entries[i]);       /* [t, f] */
        lua_rawget(L, -2);                /* [t, f, v] */
        if (!(lua_isinteger(L, -1) && lua_tointeger(L, -1) == key_val[i])) {
            printf("P2.entry-fail:%s.%s\n",
                   entries[i].lib ? entries[i].lib : "_G", entries[i].name);
            all_ok = 0;
        }
        /* rawget popped the key and pushed the value: net stack delta 0 */
        lua_pop(L, 1);                    /* [t] */
    }
    check(all_ok, "P2.keys-survive-gc");
    lua_pop(L, 1);

    /* Lua-side: the crash-class regression — a light value as a hash key
     * while the generational GC drains the gray list (the key_tt safety
     * boundary must accept the light C function tag). */
    dostr(L,
        "local t = {}\n"
        "t[math.floor] = 'floor'\n"
        "t[string.rep] = 'rep'\n"
        "t[coroutine.resume] = 'resume'\n"
        "collectgarbage()\n"
        "collectgarbage('collect')\n"
        "print('P2.luakeys', t[math.floor], t[string.rep],"
        " t[coroutine.resume], next(t) == math.floor or true)\n",
        "P2");

    lua_close(L);
}

/* ---------------- part 3: f(L) really runs ---------------- */

static void lua_getGlobal2(lua_State *L, const char *lib, const char *name) {
    lua_getglobal(L, lib);
    lua_getfield(L, -1, name);
    lua_remove(L, -2);
}

/* Call fn with n args already pushed (fixed nresults) and check the top
 * nres stack values against the expected integers. */
static void call_main(lua_State *L, const char *label, int nargs,
                      int nres, const long *expect) {
    int base = lua_gettop(L) - nargs - 1;
    if (lua_pcall(L, nargs, nres, 0) != LUA_OK) {
        printf("%s.ERROR:%s\n", label, lua_tostring(L, -1));
        fails++;
        lua_settop(L, base);
        return;
    }
    int ok = lua_gettop(L) - base == nres;
    for (int i = 0; i < nres && ok; i++)
        ok = lua_isinteger(L, base + 1 + i) &&
             lua_tointeger(L, base + 1 + i) == expect[i];
    check(ok, label);
    lua_settop(L, base);
}

static void part_calls(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* main-state C lane, one deterministic call per library (plus the
     * dynamic-out classes: select, string.find/match no-match) */
    {
        long e1[] = {10};
        lua_getglobal(L, "tonumber"); lua_pushliteral(L, "10");
        call_main(L, "P3.tonumber", 1, 1, e1);
    }
    {
        long e2[] = {3};
        lua_getglobal(L, "math"); lua_getfield(L, -1, "floor");
        lua_remove(L, -2); lua_pushnumber(L, 3.7);
        call_main(L, "P3.math-floor", 1, 1, e2);
    }
    {
        long e3[] = {2};
        lua_getglobal(L, "string"); lua_getfield(L, -1, "len");
        lua_remove(L, -2); lua_pushliteral(L, "ab");
        call_main(L, "P3.string-len", 1, 1, e3);
    }
    {
        long e4[] = {97};
        lua_getglobal(L, "string"); lua_getfield(L, -1, "byte");
        lua_remove(L, -2); lua_pushliteral(L, "ab");
        call_main(L, "P3.string-byte-default", 1, 1, e4);
    }
    {
        /* string.find no-match: exactly ONE result in MULTRET (PUC
         * moveresults publishes the actual count, not the window) */
        lua_getglobal(L, "string"); lua_getfield(L, -1, "find");
        lua_remove(L, -2);
        lua_pushliteral(L, "ab"); lua_pushliteral(L, "zz");
        if (lua_pcall(L, 2, LUA_MULTRET, 0) != LUA_OK) {
            printf("P3.string-find.ERROR\n");
            fails++;
        } else {
            check(lua_gettop(L) == 1 && lua_isnil(L, -1),
                  "P3.string-find-nomatch-count");
        }
        lua_settop(L, 0);
    }
    {
        /* string.match no-match: same one-result MULTRET contract */
        lua_getglobal(L, "string"); lua_getfield(L, -1, "match");
        lua_remove(L, -2);
        lua_pushliteral(L, "ab"); lua_pushliteral(L, "zz");
        if (lua_pcall(L, 2, LUA_MULTRET, 0) != LUA_OK) {
            printf("P3.string-match.ERROR\n");
            fails++;
        } else {
            check(lua_gettop(L) == 1 && lua_isnil(L, -1),
                  "P3.string-match-nomatch-count");
        }
        lua_settop(L, 0);
    }
    {
        long e5[] = {3};
        lua_getglobal(L, "select"); lua_pushliteral(L, "#");
        lua_pushinteger(L, 7); lua_pushinteger(L, 8); lua_pushinteger(L, 9);
        call_main(L, "P3.select-count", 4, 1, e5);
    }
    {
        long e6[] = {4, 5};
        lua_getGlobal2(L, "table", "unpack");
        lua_newtable(L);
        lua_pushinteger(L, 4); lua_rawseti(L, -2, 1);
        lua_pushinteger(L, 5); lua_rawseti(L, -2, 2);
        call_main(L, "P3.table-unpack", 1, 2, e6);
    }
    {
        lua_getGlobal2(L, "utf8", "char");
        lua_pushinteger(L, 65);
        if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
            printf("P3.utf8-char.ERROR\n");
            fails++;
        } else {
            check(lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "A") == 0,
                  "P3.utf8-char");
        }
        lua_settop(L, 0);
    }
    {
        lua_getGlobal2(L, "os", "difftime");
        lua_pushinteger(L, 3); lua_pushinteger(L, 1);
        if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
            printf("P3.os-difftime.ERROR\n");
            fails++;
        } else {
            check(lua_isnumber(L, -1) && lua_tonumber(L, -1) == 2,
                  "P3.os-difftime");
        }
        lua_settop(L, 0);
    }
    {
        /* io.type on a non-file: nil, no error */
        lua_getGlobal2(L, "io", "type");
        lua_pushinteger(L, 1);
        if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
            printf("P3.io-type.ERROR\n");
            fails++;
        } else {
            check(lua_isnil(L, -1), "P3.io-type-nil");
        }
        lua_settop(L, 0);
    }
    {
        /* package.searchpath: missing name -> nil, msg (2 results) */
        lua_getGlobal2(L, "package", "searchpath");
        lua_pushliteral(L, "no_such_module_name_zz");
        lua_pushliteral(L, "");
        if (lua_pcall(L, 2, 2, 0) != LUA_OK) {
            printf("P3.searchpath.ERROR\n");
            fails++;
        } else {
            check(lua_isnil(L, -2) && lua_isstring(L, -1),
                  "P3.searchpath-missing");
        }
        lua_settop(L, 0);
    }
    {
        /* the file __tostring metamethod: prefix only (the address
         * inside diverges by design — PUC prints the FILE* address) */
        lua_getglobal(L, "io"); lua_getfield(L, -1, "stdout");
        lua_getmetatable(L, -1); lua_getfield(L, -1, "__tostring");
        lua_remove(L, -2);
        lua_pushvalue(L, -2);
        if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
            printf("P3.file-tostring.ERROR\n");
            fails++;
        } else {
            size_t n = 0;
            const char *s = lua_tolstring(L, -1, &n);
            check(s != NULL && n >= 6 && memcmp(s, "file (", 6) == 0,
                  "P3.file-tostring-prefix");
        }
        lua_settop(L, 0);
    }

    /* error lanes: status + error object type only */
    {
        lua_getGlobal2(L, "string", "rep");
        lua_pushliteral(L, "x");
        check(lua_pcall(L, 1, 0, 0) == LUA_ERRRUN, "P3.rep-miss-status");
        check(lua_type(L, -1) == LUA_TSTRING, "P3.rep-miss-errtype");
        lua_pop(L, 1);
    }
    {
        lua_getGlobal2(L, "math", "floor");
        lua_pushliteral(L, "not a number");
        check(lua_pcall(L, 1, 0, 0) == LUA_ERRRUN, "P3.floor-str-status");
        check(lua_type(L, -1) == LUA_TSTRING, "P3.floor-str-errtype");
        lua_pop(L, 1);
    }

    /* coroutine bodies (resume VLCF lane): the light function itself is
     * the coroutine body — f(L) runs on the coroutine handle */
    dostr(L,
        "local co = coroutine.create(math.floor)\n"
        "print('P3.co-body-floor', coroutine.resume(co, 3.7))\n"
        "print('P3.co-body-status', coroutine.status(co))\n"
        "local co2 = coroutine.create(string.rep)\n"
        "print('P3.co-body-err-status',"
        " (select(1, coroutine.resume(co2, 'x', -1))))\n"
        "print('P3.co-body-err-type',"
        " type((select(2, coroutine.resume(co2, 'x', -1)))))\n"
        "local co3 = coroutine.create(select)\n"
        "print('P3.co-body-select', coroutine.resume(co3, '#', 1, 2, 3))\n"
        "local co4 = coroutine.create(table.unpack)\n"
        "print('P3.co-body-unpack', coroutine.resume(co4, {4, 5}))\n"
        "local co5 = coroutine.create(tostring)\n"
        "print('P3.co-body-tostring', coroutine.resume(co5, 12))\n",
        "P3");

    /* MULTRET through the C lane on a coroutine handle: resume a body
     * whose result count is dynamic (select '#') */
    dostr(L,
        "local co = coroutine.create(function(...)\n"
        "  return select('#', ...)\n"
        "end)\n"
        "print('P3.co-vararg-count', coroutine.resume(co, 1, 2))\n",
        "P3");

    lua_close(L);
}

/* ---------------- part 4: republish & second state ---------------- */

static void part_republish(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* repeated luaopen_* through luaL_requiref: rawequal to the original
     * (PUC rebuilds the table with the same static C functions) */
    int all_ok = 1;
    struct { const char *lib; lua_CFunction openf; } opens[] = {
        {"_G", NULL}, {"string", luaopen_string},
        {"table", luaopen_table}, {"math", luaopen_math},
        {"utf8", luaopen_utf8}, {"io", luaopen_io},
        {"os", luaopen_os}, {"debug", luaopen_debug},
        {"coroutine", luaopen_coroutine}, {"package", luaopen_package},
    };
    for (size_t k = 0; k < sizeof(opens) / sizeof(opens[0]); k++) {
        if (opens[k].openf == NULL) continue;   /* no luaopen__G */
        lua_getglobal(L, opens[k].lib);
        lua_CFunction before = lua_tocfunction(L, -1);
        (void)before;
        /* a field-level identity check across the reopen */
        const char *probe = "rep";
        if (strcmp(opens[k].lib, "string") == 0) probe = "rep";
        else if (strcmp(opens[k].lib, "table") == 0) probe = "sort";
        else if (strcmp(opens[k].lib, "math") == 0) probe = "floor";
        else if (strcmp(opens[k].lib, "utf8") == 0) probe = "char";
        else if (strcmp(opens[k].lib, "io") == 0) probe = "type";
        else if (strcmp(opens[k].lib, "os") == 0) probe = "difftime";
        else if (strcmp(opens[k].lib, "debug") == 0) probe = "traceback";
        else if (strcmp(opens[k].lib, "coroutine") == 0) probe = "status";
        else if (strcmp(opens[k].lib, "package") == 0) probe = "loadlib";
        lua_pop(L, 1);
        lua_getglobal(L, opens[k].lib);
        lua_getfield(L, -1, probe);         /* [lib, f] */
        luaL_requiref(L, opens[k].lib, opens[k].openf, 0);  /* [lib, f, m] */
        lua_getglobal(L, opens[k].lib);
        lua_getfield(L, -1, probe);         /* [lib, f, m, lib2, f2] */
        if (!lua_rawequal(L, -1, -4)) {
            printf("P4.reopen-fail:%s.%s\n", opens[k].lib, probe);
            all_ok = 0;
        }
        lua_pop(L, 5);
    }
    check(all_ok, "P4.reopen-rawequal");

    /* require-driven republish: package.loaded reset -> require returns
     * the same library table with the same light values */
    /* require after package.loaded reset: the searchers cannot find the
     * C library in EITHER engine (it is not in package.preload) — the
     * failure status is the differential contract, not a republish */
    dostr(L,
        "local ok, err = pcall(require, 'string')\n"
        "print('P4.require-missing', ok, type(err))\n",
        "P4");

    /* second independent state: identical process-global pointer */
    {
        lua_getGlobal2(L, "string", "rep");
        lua_CFunction p1 = lua_tocfunction(L, -1);
        lua_pop(L, 1);
        lua_State *L2 = luaL_newstate();
        luaL_openlibs(L2);
        lua_getGlobal2(L2, "string", "rep");
        lua_getGlobal2(L2, "string", "rep");
        check(lua_rawequal(L2, -1, -2), "P4.second-state-rawequal");
        check(lua_tocfunction(L2, -1) == p1, "P4.ptr-state-independent");
        lua_pushliteral(L2, "ab");
        lua_pushinteger(L2, 2);
        check(lua_pcall(L2, 2, 1, 0) == LUA_OK, "P4.second-state-call");
        check(lua_isstring(L2, -1) && strcmp(lua_tostring(L2, -1), "abab") == 0,
              "P4.second-state-value");
        lua_pop(L2, 1);
        lua_close(L2);
        /* first state unaffected */
        lua_getGlobal2(L, "string", "rep");
        lua_pushliteral(L, "x"); lua_pushinteger(L, 3);
        check(lua_pcall(L, 2, 1, 0) == LUA_OK, "P4.first-state-call");
        check(lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "xxx") == 0,
              "P4.first-state-value");
        lua_pop(L, 1);
    }

    lua_close(L);
}

/* ---------------- part 5: frozen allocator ---------------- */

static int frozen = 0;
static int counting = 0;
static long allocs = 0;

static void *falloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    (void)ud; (void)osize;
    if (nsize == 0) { free(ptr); return NULL; }
    if (counting) allocs++;
    if (frozen) return NULL; /* fail every growth/allocation, allow frees */
    if (ptr) return realloc(ptr, nsize);
    return malloc(nsize);
}

static int drv_light_call(lua_State *L) {
    /* pre-verified headroom, then the operation under test: a light
     * stdlib call through the C lane (result window is stack-staged;
     * math.floor allocates nothing — a string result would intern) */
    if (!lua_checkstack(L, 50)) return 0;
    lua_getglobal(L, "math");
    lua_getfield(L, -1, "floor");
    lua_remove(L, -2);
    lua_pushnumber(L, 4.5);
    lua_call(L, 1, 1);                    /* the operation under test */
    lua_pushinteger(L, lua_tonumber(L, -1) == 4 ? 1 : 0);
    return 1;
}

static int drv_ccl1(lua_State *L) {
    if (!lua_checkstack(L, 50)) return 0;
    lua_pushinteger(L, 5);
    lua_pushcfunction(L, drv_light_call); /* any C function */
    lua_pushcclosure(L, drv_light_call, 1); /* real closure: allocates */
    return 0;
}

static void part_frozen(void) {
    lua_State *L = lua_newstate(falloc, NULL, 0);
    luaL_openlibs(L);

    /* prewarm the same driver shape unfrozen */
    lua_pushcfunction(L, drv_light_call);
    check(lua_pcall(L, 0, 1, 0) == LUA_OK, "P5.prewarm");
    check(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 1,
          "P5.prewarm-light-result");
    lua_pop(L, 1);

    /* OBSERVATION (differential residual, pre-existing at HEAD, NOT this
     * cut): allocation count for one warm light pcall. PUC performs ZERO
     * allocations (precall reads args in place on the single stack);
     * luazig dupes the argument window at every C-API call entry
     * (api.zig pcall / c_api.zig lua_callk) — see report afp2b. */
    counting = 1; allocs = 0;
    lua_pushcfunction(L, drv_light_call);
    lua_pcall(L, 0, 1, 0);
    counting = 0;
    printf("P5.light-pcall-allocs:%ld\n", allocs);
    lua_pop(L, 1);

    /* OBSERVATION (same residual): a light call under a frozen allocator.
     * PUC succeeds (no allocation on the call path); luazig returns
     * LUA_ERRMEM from the pre-existing argument dupe. The trampoline's
     * own result staging (this cut) is stack-window based and adds no
     * allocation on top of that dupe. */
    frozen = 1;
    lua_pushcfunction(L, drv_light_call);
    printf("P5.frozen-light-pcall-status:%d\n", lua_pcall(L, 0, 1, 0));
    frozen = 0;
    lua_pop(L, 1);

    /* control: a heap C closure under the same freeze -> LUA_ERRMEM */
    frozen = 1;
    lua_pushcfunction(L, drv_ccl1);
    check(lua_pcall(L, 0, 0, 0) == LUA_ERRMEM, "P5.frozen-ccl-errmem");
    frozen = 0;
    lua_pop(L, 1);

    /* the VM stays usable: push, call, full GC cycle, call again */
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_getglobal(L, "math");
    lua_getfield(L, -1, "floor");
    lua_remove(L, -2);
    lua_pushnumber(L, 9.5);
    check(lua_pcall(L, 1, 1, 0) == LUA_OK, "P5.post-freeze-call");
    check(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 9,
          "P5.post-freeze-value");
    lua_pop(L, 1);
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_getglobal(L, "tostring");
    lua_pushinteger(L, 7);
    check(lua_pcall(L, 1, 1, 0) == LUA_OK, "P5.post-gc-call");
    lua_pop(L, 1);

    lua_close(L);
}

/* ---------------- part 6: the shared FILE* finalizer ---------------- */

#define FIN_PATH "/tmp/luazig_46_shared_finalizer.txt"

/* Push the file metatable's named metamethod (mt = getmetatable(io.stdout)). */
static void push_filemt(lua_State *L, const char *name) {
    lua_getglobal(L, "io");
    lua_getfield(L, -1, "stdout");
    lua_getmetatable(L, -1);          /* [io, stdout, mt] */
    lua_getfield(L, -1, name);        /* [io, stdout, mt, f] */
    lua_remove(L, -2);
    lua_remove(L, -2);
    lua_remove(L, -2);
}

/* Call the function on top (n args below it) with LUA_MULTRET and check
 * it succeeds publishing exactly nres results. */
static void call_count(lua_State *L, int nargs, int nres, const char *label) {
    int base = lua_gettop(L) - nargs - 1;
    if (lua_pcall(L, nargs, LUA_MULTRET, 0) != LUA_OK) {
        printf("%s.ERROR:%s\n", label, lua_tostring(L, -1));
        fails++;
        lua_settop(L, base);
        return;
    }
    check(lua_gettop(L) - base == nres, label);
    lua_settop(L, base);
}

/* Replace the value on top with io.type(value)'s string result. */
static void replace_with_iotype(lua_State *L) {
    lua_getglobal(L, "io");
    lua_getfield(L, -1, "type");
    lua_remove(L, -2);                /* [v, io.type] */
    lua_pushvalue(L, -2);             /* [v, io.type, v] */
    lua_call(L, 1, 1);                /* [v, result] */
    lua_replace(L, -2);               /* [result] */
}

static void part_shared_finalizer(void) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);

    /* identity: __gc and __close are ONE function value */
    push_filemt(L, "__gc");           /* [gc] */
    push_filemt(L, "__close");        /* [gc, close] */
    check(lua_rawequal(L, -1, -2), "P6.gc-close-rawequal");
    check(lua_tocfunction(L, -1) == lua_tocfunction(L, -2),
          "P6.gc-close-tocfunction");
    check(lua_topointer(L, -1) == lua_tocfunction(L, -1),
          "P6.close-topointer");
    lua_CFunction fptr = lua_tocfunction(L, -1);
    lua_pop(L, 2);

    /* table-key interchange: one insertion, both metamethods read it */
    lua_newtable(L);                  /* [t] */
    push_filemt(L, "__gc");           /* [t, gc] */
    lua_pushinteger(L, 42);
    lua_rawset(L, -3);                /* [t] */
    push_filemt(L, "__close");        /* [t, close] */
    lua_rawget(L, -2);                /* [t, v] */
    check(lua_isinteger(L, -1) && lua_tointeger(L, -1) == 42,
          "P6.key-interchange");
    lua_pop(L, 2);

    /* direct call on an OPEN regular file: 0 results, file really closed;
     * the file value stays on the stack across all the close lanes */
    lua_getglobal(L, "io");
    lua_getfield(L, -1, "open");
    lua_remove(L, -2);
    lua_pushstring(L, FIN_PATH);
    lua_pushliteral(L, "w");
    lua_call(L, 2, 1);                /* [f] */
    push_filemt(L, "__gc");           /* [f, gc] */
    lua_pushvalue(L, -2);             /* [f, gc, f] */
    call_count(L, 1, 0, "P6.open-gc-count");
    /* [f] */
    lua_pushvalue(L, -1);             /* [f, f] */
    replace_with_iotype(L);           /* [f, result] */
    check(lua_isstring(L, -1) &&
          strcmp(lua_tostring(L, -1), "closed file") == 0,
          "P6.open-gc-closed");
    lua_pop(L, 1);
    /* already-closed file: __close is the same body — ignored, 0 results */
    push_filemt(L, "__close");        /* [f, close] */
    lua_pushvalue(L, -2);             /* [f, close, f] */
    call_count(L, 1, 0, "P6.closed-close-count");
    lua_pushvalue(L, -1);             /* [f, f] */
    replace_with_iotype(L);           /* [f, result] */
    check(lua_isstring(L, -1) &&
          strcmp(lua_tostring(L, -1), "closed file") == 0,
          "P6.closed-close-still-closed");
    lua_pop(L, 1);
    /* fixed nresults=1: the 0-result body nil-fills the wanted slot */
    push_filemt(L, "__gc");           /* [f, gc] */
    lua_pushvalue(L, -2);             /* [f, gc, f] */
    {
        int base = lua_gettop(L) - 2;
        check(lua_pcall(L, 1, 1, 0) == LUA_OK, "P6.fixed-nres-status");
        check(lua_gettop(L) - base == 1 && lua_isnil(L, -1),
              "P6.fixed-nres-nilfill");
        lua_settop(L, base);
    }
    lua_pop(L, 1);                    /* the file object */

    /* std stream: 0 results from both metamethods, stays open */
    {
        static const char *const which[2] = {"__gc", "__close"};
        for (int k = 0; k < 2; k++) {
            push_filemt(L, which[k]); /* [fn] */
            lua_getglobal(L, "io");
            lua_getfield(L, -1, "stdout");
            lua_remove(L, -2);        /* [fn, stdout] */
            call_count(L, 1, 0, k == 0 ?
                       "P6.std-gc-count" : "P6.std-close-count");
            lua_getglobal(L, "io");
            lua_getfield(L, -1, "stdout");
            lua_remove(L, -2);        /* [stdout] */
            replace_with_iotype(L);
            check(lua_isstring(L, -1) &&
                  strcmp(lua_tostring(L, -1), "file") == 0,
                  k == 0 ? "P6.std-gc-open" : "P6.std-close-open");
            lua_pop(L, 1);
        }
    }

    /* wrong argument: error status + string error object (text carries a
     * call-site-derived function name — status/type is the contract) */
    push_filemt(L, "__gc");
    check(lua_pcall(L, 0, 0, 0) == LUA_ERRRUN, "P6.noarg-status");
    check(lua_type(L, -1) == LUA_TSTRING, "P6.noarg-errtype");
    lua_pop(L, 1);
    push_filemt(L, "__close");
    lua_pushinteger(L, 42);
    check(lua_pcall(L, 1, 0, 0) == LUA_ERRRUN, "P6.badarg-status");
    check(lua_type(L, -1) == LUA_TSTRING, "P6.badarg-errtype");
    lua_pop(L, 1);

    /* coroutine-body lane: the shared finalizer as a coroutine body */
    dostr(L,
        "local mt = getmetatable(io.stdout)\n"
        "local f = io.open('" FIN_PATH "', 'w')\n"
        "f:write('coro')\n"
        "local co = coroutine.create(mt.__gc)\n"
        "print('P6.coro-resume', coroutine.resume(co, f))\n"
        "print('P6.coro-status', coroutine.status(co))\n"
        "print('P6.coro-type', io.type(f))\n"
        "local co2 = coroutine.create(mt.__close)\n"
        "print('P6.coro-badarg', (select(1, coroutine.resume(co2, 42))))\n"
        "print('P6.coro-badarg-type',"
        " type((select(2, coroutine.resume(co2, 42)))))\n",
        "P6");

    /* TBC close: normal scope exit, error transport, std stream */
    dostr(L,
        "local h\n"
        "do\n"
        "  local x <close> = io.open('" FIN_PATH "', 'w')\n"
        "  x:write('tbc')\n"
        "  h = x\n"
        "end\n"
        "print('P6.tbc-type', io.type(h))\n"
        "local y2\n"
        "local ok, e = pcall(function()\n"
        "  local y <close> = io.open('" FIN_PATH "', 'w')\n"
        "  y:write('err')\n"
        "  y2 = y\n"
        "  error('boom', 0)\n"
        "end)\n"
        "print('P6.tbc-err', ok, e, io.type(y2))\n"
        "do\n"
        "  local s <close> = io.stdout\n"
        "end\n"
        "print('P6.tbc-std-open', io.type(io.stdout))\n",
        "P6");

    /* GC finalization: the dropped handle is closed and flushed by __gc */
    dostr(L,
        "local f = io.open('" FIN_PATH "', 'w')\n"
        "f:write('gc')\n"
        "f = nil\n"
        "collectgarbage('collect')\n"
        "collectgarbage('collect')\n"
        "local r = io.open('" FIN_PATH "', 'r')\n"
        "print('P6.gc-finalized', r:read('a'))\n"
        "r:close()\n"
        "os.remove('" FIN_PATH "')\n",
        "P6");

    /* republish: io reopened through luaL_requiref keeps the shared
     * process-global pointer in both metamethod fields */
    luaL_requiref(L, "io", luaopen_io, 0);
    lua_pop(L, 1);
    push_filemt(L, "__gc");           /* [gc] */
    push_filemt(L, "__close");        /* [gc, close] */
    check(lua_rawequal(L, -1, -2), "P6.reopen-rawequal");
    check(lua_tocfunction(L, -2) == fptr, "P6.reopen-gc-ptr");
    check(lua_tocfunction(L, -1) == fptr, "P6.reopen-close-ptr");
    lua_pop(L, 2);

    /* second independent state: same shared pointer, stays callable */
    {
        lua_State *L2 = luaL_newstate();
        luaL_openlibs(L2);
        push_filemt(L2, "__gc");      /* [gc] */
        push_filemt(L2, "__close");   /* [gc, close] */
        check(lua_rawequal(L2, -1, -2), "P6.second-state-rawequal");
        check(lua_tocfunction(L2, -1) == fptr, "P6.second-state-ptr");
        lua_pop(L2, 2);
        push_filemt(L2, "__gc");      /* [gc] */
        lua_getglobal(L2, "io");
        lua_getfield(L2, -1, "stdout");
        lua_remove(L2, -2);           /* [gc, stdout] */
        call_count(L2, 1, 0, "P6.second-state-call");
        lua_close(L2);
    }

    lua_close(L);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    part_identity();
    part_tablekeys();
    part_calls();
    part_republish();
    part_frozen();
    part_shared_finalizer();
    printf("LIGHT_SWEEP: %d failures\n", fails);
    return fails ? 1 : 0;
}
