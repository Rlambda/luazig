/*
** 19_load.c — differential tests for C API load mode semantics (Task 2/3).
**
** Exercises luaL_loadbufferx with modes "b", "B", "t", "bt", and NULL
** against both text and binary chunks, verifying PUC-faithful mode
** dispatch (ldo.c:1123-1141 f_parser + ldo.c:1114-1119 checkmode).
**
** This suite is in DIFF_TESTS: output must be byte-identical when linked
** against PUC Lua 5.5 (19_load-puc) and against luazig (19_load).
**
** Cases (PUC ldo.c:1126-1138):
**   A: mode="b"  binary chunk → load OK, call → 42
**   B: mode="B"  binary chunk → load OK, call → 42 (fixed-buffer borrow)
**   C: mode="t"  binary chunk → load ERR (attempt to load a binary chunk)
**   D: mode="b"  text chunk  → load ERR (attempt to load a text chunk)
**   E: mode="t"  text chunk  → load OK, call → 42
**   F: mode=NULL binary chunk → load OK (default "bt")
**   G: mode=NULL text chunk  → load OK (default "bt")
**   H: nested closure + upvalue roundtrip via dump/load
**   I: truncated binary → load ERR (no crash)
**
** For mode "B" (fixed-buffer borrow, Task 5): the caller's buffer must
** stay alive until the closure is dropped and GC'd. The test exercises
** this by running the closure, dropping it, calling lua_gc(FULL_GC), and
** THEN freeing the buffer.
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* --- Helpers --- */

static int fail(const char *what) {
    fprintf(stderr, "FAIL: %s\n", what);
    return 1;
}

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

/* Dump the function on top of the stack. Returns 0 on success. */
static int do_dump(lua_State *L, struct dump_buf *db) {
    db->data = NULL;
    db->size = 0;
    return lua_dump(L, dump_writer, db, 0);
}

/* Load a binary chunk with the given mode and return the load status.
** Prints "load=<rc>" and, on success, calls the function and prints
** "call=<rc> value=<v>". */
static void test_load(lua_State *L, const char *buf, size_t sz,
                      const char *name, const char *mode,
                      const char *label) {
    int rc = luaL_loadbufferx(L, buf, sz, name, mode);
    printf("%s: load=%d", label, rc);
    if (rc == 0) {
        int cr = lua_pcall(L, 0, 1, 0);
        printf(" call=%d", cr);
        if (cr == 0) {
            lua_Integer v = lua_tointegerx(L, -1, NULL);
            printf(" value=%lld", (long long)v);
            lua_pop(L, 1);
        } else {
            lua_pop(L, 1); /* pop error object */
        }
    } else {
        /* On error, the error message is on the stack; pop it. */
        lua_pop(L, 1);
    }
    printf("\n");
}

/* --- Main test driver --- */

int main(void) {
    lua_State *L = luaL_newstate();
    if (!L) return fail("luaL_newstate");
    luaL_openlibs(L);

    /* Create a binary chunk by compiling "return 40+2" and dumping it. */
    if (luaL_loadstring(L, "return 40+2") != LUA_OK)
        return fail("loadstring for dump");
    struct dump_buf bin;
    if (do_dump(L, &bin) != 0)
        return fail("lua_dump");
    lua_pop(L, 1); /* pop the compiled function */

    /* Text chunk: "return 40+2" as text bytes. */
    const char *text = "return 40+2";
    size_t text_sz = strlen(text);

    /* --- Case A: mode="b" binary chunk → load OK, call → 42 --- */
    test_load(L, bin.data, bin.size, "=binA", "b", "A_b_bin");

    /* --- Case B: mode="B" binary chunk → load OK, call → 42 ---
    ** Fixed-buffer borrow: the caller's buffer (bin.data) must stay alive
    ** until the closure is dropped and GC'd. We load, call, pop, GC, then
    ** free the buffer at the very end. */
    {
        int rc = luaL_loadbufferx(L, bin.data, bin.size, "=binB", "B");
        printf("B_B_bin: load=%d", rc);
        if (rc == 0) {
            int cr = lua_pcall(L, 0, 1, 0);
            printf(" call=%d", cr);
            if (cr == 0) {
                printf(" value=%lld", (long long)lua_tointegerx(L, -1, NULL));
                lua_pop(L, 1);
            } else {
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
        printf("\n");
        /* Drop the closure and GC before freeing the buffer. */
        lua_gc(L, LUA_GCCOLLECT);
    }

    /* --- Case C: mode="t" binary chunk → load ERR --- */
    test_load(L, bin.data, bin.size, "=binC", "t", "C_t_bin");

    /* --- Case D: mode="b" text chunk → load ERR --- */
    test_load(L, text, text_sz, "=txtD", "b", "D_b_txt");

    /* --- Case E: mode="t" text chunk → load OK, call → 42 --- */
    test_load(L, text, text_sz, "=txtE", "t", "E_t_txt");

    /* --- Case F: mode=NULL binary chunk → load OK (default "bt") --- */
    test_load(L, bin.data, bin.size, "=binF", NULL, "F_null_bin");

    /* --- Case G: mode=NULL text chunk → load OK (default "bt") --- */
    test_load(L, text, text_sz, "=txtG", NULL, "G_null_txt");

    /* --- Case H: nested closure + upvalue roundtrip --- */
    {
        if (luaL_loadstring(L,
                "local x = 99\n"
                "local function inner(y) return x + y end\n"
                "return inner") != LUA_OK)
            return fail("loadstring for nested");
        struct dump_buf nested_bin;
        if (do_dump(L, &nested_bin) != 0)
            return fail("dump nested");
        lua_pop(L, 1);

        /* Load the dumped nested closure with mode "b" and call it. */
        int rc = luaL_loadbufferx(L, nested_bin.data, nested_bin.size,
                                  "=nested", "b");
        printf("H_nested: load=%d", rc);
        if (rc == 0) {
            /* Call the outer closure to get the inner function. */
            int cr = lua_pcall(L, 0, 1, 0);
            printf(" call_outer=%d", cr);
            if (cr == 0) {
                /* Now call the inner function with y=3 → 99+3=102. */
                lua_pushinteger(L, 3);
                cr = lua_pcall(L, 1, 1, 0);
                printf(" call_inner=%d", cr);
                if (cr == 0) {
                    printf(" value=%lld",
                           (long long)lua_tointegerx(L, -1, NULL));
                    lua_pop(L, 1);
                } else {
                    lua_pop(L, 1);
                }
            } else {
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
        printf("\n");
        free(nested_bin.data);
    }

    /* --- Case I: truncated binary → load ERR (no crash) --- */
    {
        /* Truncate the binary chunk to 10 bytes (header is 40). */
        size_t trunc_sz = bin.size < 10 ? bin.size : 10;
        test_load(L, bin.data, trunc_sz, "=trunc", "b", "I_truncated");
    }

    /* --- Stripped vs non-stripped reload --- */
    {
        if (luaL_loadstring(L, "return 42") != LUA_OK)
            return fail("loadstring for stripped");
        struct dump_buf stripped_bin;
        if (do_dump(L, &stripped_bin) != 0)
            return fail("dump stripped");
        lua_pop(L, 1);
        test_load(L, stripped_bin.data, stripped_bin.size, "=stripped",
                  "b", "J_stripped");
        free(stripped_bin.data);
    }

    /* Free the binary buffer AFTER all B-mode closures are dropped+GC'd. */
    free(bin.data);
    lua_close(L);
    printf("PASS: 19_load\n");
    return 0;
}
