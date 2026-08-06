/*
** 04_misc.c — tests for Phase 4: load/dump, warnings, string/number
** conversions, and miscellaneous functions.
**
** Exercises:
**   lua_stringtonumber, lua_numbertocstring,
**   lua_load (with lua_Reader callback),
**   lua_dump (with lua_Writer callback),
**   lua_setwarnf / lua_warning,
**   lua_pushvfstring (indirectly via lua_pushfstring),
**   lua_setallocf / lua_getallocf,
**   lua_toclose / lua_closeslot (no-op stubs, verify they don't crash).
*/
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* ------------------------------------------------------------------ */
/* lua_Reader callback for lua_load: reads a whole string in one chunk */
/* ------------------------------------------------------------------ */
static const char *string_reader(lua_State *L, void *data, size_t *sz) {
    const char **p = (const char **)data;
    if (*p == NULL) { *sz = 0; return NULL; }
    const char *s = *p;
    *sz = strlen(s);
    *p = NULL;
    (void)L;
    return s;
}

/* ------------------------------------------------------------------ */
/* lua_Writer callback for lua_dump: collects bytes into a malloc'd buffer */
/* ------------------------------------------------------------------ */
struct dump_buf {
    char *data;
    size_t size;
    size_t cap;
};

static int dump_writer(lua_State *L, const void *p, size_t sz, void *ud) {
    struct dump_buf *db = (struct dump_buf *)ud;
    if (db->size + sz > db->cap) {
        size_t newcap = db->cap * 2;
        if (newcap < db->size + sz) newcap = db->size + sz;
        char *nd = (char *)realloc(db->data, newcap);
        if (nd == NULL) return 1;
        db->data = nd;
        db->cap = newcap;
    }
    memcpy(db->data + db->size, p, sz);
    db->size += sz;
    (void)L;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Warning handler for lua_setwarnf / lua_warning tests */
/* ------------------------------------------------------------------ */
static int warn_count = 0;
static char last_warn[256] = {0};

static void test_warnf(void *ud, const char *msg, int tocont) {
    (void)ud;
    (void)tocont;
    if (msg) {
        strncpy(last_warn, msg, sizeof(last_warn) - 1);
        last_warn[sizeof(last_warn) - 1] = '\0';
    }
    warn_count++;
}

/* ------------------------------------------------------------------ */
/* Main test driver */
/* ------------------------------------------------------------------ */
int main(void) {
    lua_State *L = luaL_newstate();
    if (!L) { fprintf(stderr, "FAIL: luaL_newstate\n"); return 1; }

    /* --- lua_stringtonumber: integer --- */
    lua_settop(L, 0);
    size_t consumed = lua_stringtonumber(L, "42");
    if (consumed == 0) {
        fprintf(stderr, "FAIL: stringtonumber('42') returned 0\n");
        lua_close(L); return 1;
    }
    if (lua_tointegerx(L, -1, NULL) != 42) {
        fprintf(stderr, "FAIL: stringtonumber('42') value = %lld\n",
                (long long)lua_tointegerx(L, -1, NULL));
        lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_stringtonumber: float --- */
    consumed = lua_stringtonumber(L, "3.14");
    if (consumed == 0) {
        fprintf(stderr, "FAIL: stringtonumber('3.14') returned 0\n");
        lua_close(L); return 1;
    }
    lua_Number d = lua_tonumberx(L, -1, NULL);
    if (d < 3.13 || d > 3.15) {
        fprintf(stderr, "FAIL: stringtonumber('3.14') = %g\n", d);
        lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_stringtonumber: not a number --- */
    consumed = lua_stringtonumber(L, "hello");
    if (consumed != 0) {
        fprintf(stderr, "FAIL: stringtonumber('hello') should return 0\n");
        lua_close(L); return 1;
    }

    /* --- lua_numbertocstring: integer --- */
    lua_pushinteger(L, 12345);
    char nbuf[LUA_N2SBUFFSZ];
    unsigned nlen = lua_numbertocstring(L, -1, nbuf);
    if (nlen == 0) {
        fprintf(stderr, "FAIL: numbertocstring(12345) returned 0\n");
        lua_close(L); return 1;
    }
    if (strcmp(nbuf, "12345") != 0) {
        fprintf(stderr, "FAIL: numbertocstring(12345) = '%s'\n", nbuf);
        lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_numbertocstring: not a number --- */
    lua_pushnil(L);
    nlen = lua_numbertocstring(L, -1, nbuf);
    if (nlen != 0) {
        fprintf(stderr, "FAIL: numbertocstring(nil) should return 0\n");
        lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_load with reader callback --- */
    const char *code = "return 7";
    const char *ptr = code;
    if (lua_load(L, string_reader, &ptr, "=reader-test", NULL) != LUA_OK) {
        fprintf(stderr, "FAIL: lua_load returned %d\n",
                lua_load(L, string_reader, &ptr, "=reader-test", NULL));
        lua_close(L); return 1;
    }
    if (lua_pcallk(L, 0, 1, 0, 0, NULL) != LUA_OK) {
        fprintf(stderr, "FAIL: pcall after load\n");
        lua_close(L); return 1;
    }
    if (lua_tointegerx(L, -1, NULL) != 7) {
        fprintf(stderr, "FAIL: load result = %lld\n",
                (long long)lua_tointegerx(L, -1, NULL));
        lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_dump with writer callback --- */
    /* Load a function, then dump it */
    const char *dump_code = "return 42";
    const char *dump_ptr = dump_code;
    if (lua_load(L, string_reader, &dump_ptr, "=dump-test", NULL) != LUA_OK) {
        fprintf(stderr, "FAIL: lua_load for dump\n");
        lua_close(L); return 1;
    }
    struct dump_buf db = {0};
    db.cap = 4096;
    db.data = (char *)malloc(db.cap);
    if (!db.data) { fprintf(stderr, "FAIL: malloc\n"); lua_close(L); return 1; }
    int dump_status = lua_dump(L, dump_writer, &db, 0);
    if (dump_status != 0) {
        fprintf(stderr, "FAIL: lua_dump returned %d\n", dump_status);
        free(db.data);
        lua_close(L); return 1;
    }
    if (db.size == 0) {
        fprintf(stderr, "FAIL: lua_dump wrote 0 bytes\n");
        free(db.data);
        lua_close(L); return 1;
    }
    /* Verify the dumped chunk starts with the Lua signature */
    if (db.size < 4 || memcmp(db.data, LUA_SIGNATURE, 4) != 0) {
        fprintf(stderr, "FAIL: dumped chunk has wrong signature\n");
        free(db.data);
        lua_close(L); return 1;
    }
    free(db.data);
    lua_pop(L, 1);

    /* --- lua_setwarnf / lua_warning --- */
    warn_count = 0;
    last_warn[0] = '\0';
    lua_setwarnf(L, test_warnf, NULL);
    lua_warning(L, "test warning", 0);
    if (warn_count != 1) {
        fprintf(stderr, "FAIL: warn_count = %d, expected 1\n", warn_count);
        lua_close(L); return 1;
    }
    if (strcmp(last_warn, "test warning") != 0) {
        fprintf(stderr, "FAIL: last_warn = '%s'\n", last_warn);
        lua_close(L); return 1;
    }

    /* Disable warnings */
    lua_setwarnf(L, NULL, NULL);
    warn_count = 0;
    lua_warning(L, "should be ignored", 0);
    if (warn_count != 0) {
        fprintf(stderr, "FAIL: warnings not disabled\n");
        lua_close(L); return 1;
    }

    /* --- lua_pushfstring (uses pushvfstring internally) --- */
    lua_settop(L, 0);
    lua_pushfstring(L, "value=%d", 99);
    if (lua_type(L, -1) != LUA_TSTRING) {
        fprintf(stderr, "FAIL: pushfstring didn't push string\n");
        lua_close(L); return 1;
    }
    const char *fs = lua_tolstring(L, -1, NULL);
    if (strcmp(fs, "value=99") != 0) {
        fprintf(stderr, "FAIL: pushfstring result = '%s'\n", fs);
        lua_close(L); return 1;
    }
    lua_pop(L, 1);

    /* --- lua_setallocf / lua_getallocf (no-op stub, verify no crash) --- */
    lua_setallocf(L, NULL, NULL);
    void *alloc_ud = NULL;
    lua_Alloc af = lua_getallocf(L, &alloc_ud);
    if (af == NULL) {
        fprintf(stderr, "FAIL: getallocf returned NULL after setallocf\n");
        lua_close(L); return 1;
    }

    /* --- lua_toclose / lua_closeslot (no-op stubs, verify no crash) --- */
    lua_pushinteger(L, 1);
    lua_toclose(L, -1);
    lua_closeslot(L, -1);
    lua_pop(L, 1);

    lua_close(L);
    printf("PASS: 04_misc\n");
    return 0;
}
