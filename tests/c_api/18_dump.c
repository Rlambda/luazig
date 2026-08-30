/*
** 18_dump.c — differential tests for the C API dump path (P16.10b Task 2).
**
** Exercises lua_dump with strip=0 and strip=1 (PUC DumpState.strip
** semantics: strip is a property of the SERIALIZATION — debug fields are
** omitted while writing, no Proto clone is involved).
**
** This suite is in DIFF_TESTS: output must be byte-identical when linked
** against PUC Lua 5.5 (18_dump-puc) and against luazig (18_dump). The two
** runtimes write different (each runtime-native) chunk bodies, so the test
** only asserts behavior observable through the C API — dump status,
** signature, size ordering, header identity — never raw chunk bytes.
**
** Reload-and-execute of the dumped chunks is covered by the Lua-level
** differential smoke tests/smoke/65_strip_dump_semantics.lua (load(dump(f))
** in both modes). The C-side binary loader (luaL_loadbufferx mode "b") is
** not implemented in luazig yet — a load-path gap outside this suite's
** scope; when it lands, extend this suite with reload asserts.
**
** Note: dumping a C function is NOT tested here. PUC 5.5's lua_dump guards
** the value only with api_check(isLfunction) — a no-op in release builds —
** and then dereferences it as a Lua closure, so the call is undefined
** behavior (observed SIGBUS) on release PUC. No byte-identical
** differential is possible for that input.
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"

/* lua_Writer callback: collects bytes into a growable malloc'd buffer. */
struct dump_buf {
    char *data;
    size_t size;
};

static int dump_writer(lua_State *L, const void *p, size_t sz, void *ud) {
    struct dump_buf *db = (struct dump_buf *)ud;
    if (sz == 0) return 0;
    char *nd = (char *)realloc(db->data, db->size + sz);
    if (nd == NULL) return 1;
    memcpy(nd + db->size, p, sz);
    db->data = nd;
    db->size += sz;
    (void)L;
    return 0;
}

/* Dump the function on top of the stack with the given strip flag. */
static int do_dump(lua_State *L, int strip, struct dump_buf *db) {
    db->data = NULL;
    db->size = 0;
    return lua_dump(L, dump_writer, db, strip);
}

static int fail(lua_State *L, const char *what) {
    fprintf(stderr, "FAIL: %s\n", what);
    lua_close(L);
    return 1;
}

int main(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: luaL_newstate\n"); return 1; }

    /* A function with debug info to strip: nested closure + locals. */
    if (luaL_loadstring(L,
            "local function inner(a, b)\n"
            "  local sum = a + b\n"
            "  return function(c) return sum + c end\n"
            "end\n"
            "return inner") != LUA_OK)
        return fail(L, "loadstring");

    /* --- lua_dump strip=0 / strip=1 --- */
    struct dump_buf plain, stripped;
    if (do_dump(L, 0, &plain) != 0)
        return fail(L, "lua_dump(strip=0) status");
    if (do_dump(L, 1, &stripped) != 0)
        return fail(L, "lua_dump(strip=1) status");

    if (plain.size < 4 || memcmp(plain.data, LUA_SIGNATURE, 4) != 0)
        return fail(L, "plain chunk signature");
    if (stripped.size < 4 || memcmp(stripped.data, LUA_SIGNATURE, 4) != 0)
        return fail(L, "stripped chunk signature");
    printf("sig: plain=%d stripped=%d\n",
           memcmp(plain.data, LUA_SIGNATURE, 4) == 0,
           memcmp(stripped.data, LUA_SIGNATURE, 4) == 0);

    /* Stripping debug info must never grow the chunk. (Absolute sizes are
    ** runtime-native and NOT printed — only the ordering is asserted.) */
    printf("size: %d %d\n",
           (int)(stripped.size <= plain.size),
           (int)(stripped.size < plain.size));

    /* The strip flag never changes the 12-byte signature+version+format
    ** prefix of the chunk (identical within one runtime). */
    printf("hdr: %d\n",
           plain.size >= 12 && stripped.size >= 12 &&
           memcmp(plain.data, stripped.data, 12) == 0);

    free(plain.data);
    free(stripped.data);
    lua_close(L);
    printf("PASS: 18_dump\n");
    return 0;
}
