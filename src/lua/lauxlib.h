/*
** lauxlib.h — minimal auxiliary library header for luazig extension libraries.
**
** This header mirrors the subset of PUC Lua 5.5's lauxlib.h that luazig
** implements. Like lua.h, the macro definitions match PUC exactly so source
** files compile unchanged against either header set.
*/
#ifndef lauxlib_h
#define lauxlib_h

#include <stddef.h>

#include "lua.h"

/* ----------------------------------------------------------------------- */
/* PUC `luaL_Reg` (lauxlib.h:44): a {name, func} pair terminated by a       */
/* sentinel entry whose `name` is NULL. Layout matches the Zig `extern     */
/* struct luaL_Reg` in c_api.zig (name: ?[*:0]const u8, func: ?C fn ptr),  */
/* so a pointer returned by a loaded .so's `luaopen_*` is directly         */
/* reinterpret-able by `luaL_setfuncs`.                                    */
/* ----------------------------------------------------------------------- */
typedef struct luaL_Reg {
    const char *name;
    lua_CFunction func;
} luaL_Reg;

/* ----------------------------------------------------------------------- */
/* Auxlib functions (PUC lauxlib.c)                                        */
/* ----------------------------------------------------------------------- */

LUALIB_API void  (luaL_checkversion_)(lua_State *L, lua_Number ver, size_t sz);

/* State creation (PUC lauxlib.h:122). Creates a new lua_State with a
** default allocator. Returns NULL on allocation failure. */
LUALIB_API lua_State *(luaL_newstate)(void);

/* Load a buffer as a Lua chunk (PUC lauxlib.h:108). 'mode' controls
** binary/text loading ("b", "t", "bt", or NULL for both). Returns
** LUA_OK on success or LUA_ERRSYNTAX/LUA_ERRMEM on failure. */
LUALIB_API int (luaL_loadbufferx)(lua_State *L, const char *buff, size_t size,
                                  const char *name, const char *mode);

/* Load a file as a Lua chunk (PUC lauxlib.h:105). 'mode' as above. */
LUALIB_API int (luaL_loadfilex)(lua_State *L, const char *filename,
                                const char *mode);

LUALIB_API const char *(luaL_checklstring)(lua_State *L, int arg, size_t *l);
LUALIB_API void  (luaL_setfuncs)(lua_State *L, const luaL_Reg *l, int nup);
LUALIB_API int   (luaL_ref)(lua_State *L, int t);
LUALIB_API void  (luaL_unref)(lua_State *L, int t, int ref);
LUALIB_API int   (luaL_newmetatable)(lua_State *L, const char *tname);
LUALIB_API void  (luaL_getmetatable)(lua_State *L, const char *tname);
LUALIB_API void  (luaL_setmetatable)(lua_State *L, const char *tname);
LUALIB_API void *(luaL_testudata)(lua_State *L, int ud, const char *tname);
LUALIB_API void *(luaL_checkudata)(lua_State *L, int ud, const char *tname);
LUALIB_API lua_Integer (luaL_checkinteger)(lua_State *L, int arg);
LUALIB_API lua_Integer (luaL_optinteger)(lua_State *L, int arg, lua_Integer def);

/* Phase 5: argument checking, error, utilities */
LUALIB_API void  (luaL_checktype)(lua_State *L, int arg, int t);
LUALIB_API void  (luaL_checkany)(lua_State *L, int arg);
LUALIB_API void  (luaL_checkstack)(lua_State *L, int sz, const char *msg);
LUALIB_API lua_Number (luaL_checknumber)(lua_State *L, int arg);
LUALIB_API lua_Number (luaL_optnumber)(lua_State *L, int arg, lua_Number def);
LUALIB_API const char *(luaL_optlstring)(lua_State *L, int arg, const char *def, size_t *l);
LUALIB_API int   (luaL_checkoption)(lua_State *L, int arg, const char *def, const char *const lst[]);
LUALIB_API int   (luaL_argerror)(lua_State *L, int arg, const char *extramsg);
LUALIB_API int   (luaL_typeerror)(lua_State *L, int arg, const char *tname);
LUALIB_API void  (luaL_where)(lua_State *L, int lvl);
LUALIB_API int   (luaL_error)(lua_State *L, const char *fmt, ...);
LUALIB_API void  (luaL_traceback)(lua_State *L, lua_State *L1, const char *msg, int lvl);
LUALIB_API const char *(luaL_tolstring)(lua_State *L, int idx, size_t *len);
LUALIB_API lua_Integer (luaL_len)(lua_State *L, int idx);
LUALIB_API const char *(luaL_gsub)(lua_State *L, const char *s, const char *p, const char *r);
LUALIB_API int   (luaL_getmetafield)(lua_State *L, int obj, const char *event);
LUALIB_API int   (luaL_callmeta)(lua_State *L, int obj, const char *event);
LUALIB_API void  (luaL_requiref)(lua_State *L, const char *modname, lua_CFunction openf, int glb);
LUALIB_API int   (luaL_loadstring)(lua_State *L, const char *s);
LUALIB_API int   (luaL_fileresult)(lua_State *L, int stat, const char *fname);

/* luaL_Buffer subsystem */
/* The struct must be fully defined so C callers can allocate it on the stack.
** Layout matches the Zig extern struct in c_api.zig. */
struct luaL_Buffer {
    char *b;
    size_t size;
    size_t n;
    lua_State *L;
    char init[1024]; /* LUAL_BUFFERSIZE on 64-bit */
};
typedef struct luaL_Buffer luaL_Buffer;

LUALIB_API void  (luaL_buffinit)(lua_State *L, luaL_Buffer *B);
LUALIB_API char *(luaL_prepbuffsize)(luaL_Buffer *B, size_t sz);
LUALIB_API void  (luaL_addlstring)(luaL_Buffer *B, const char *s, size_t l);
LUALIB_API void  (luaL_addstring)(luaL_Buffer *B, const char *s);
LUALIB_API void  (luaL_addvalue)(luaL_Buffer *B);
LUALIB_API void  (luaL_pushresult)(luaL_Buffer *B);
LUALIB_API void  (luaL_pushresultsize)(luaL_Buffer *B, size_t sz);
LUALIB_API char *(luaL_buffinitsize)(lua_State *L, luaL_Buffer *B, size_t sz);
LUALIB_API void  (luaL_addgsub)(luaL_Buffer *B, const char *s, const char *p, const char *r);

#define luaL_bufflen(bf)     ((bf)->n)
#define luaL_buffaddr(bf)    ((bf)->b)
#define luaL_addchar(B,c) \
    ((void)((B)->n < (B)->size || luaL_prepbuffsize((B), 1)), \
     ((B)->b[(B)->n++] = (c)))
#define luaL_addsize(B,s)    ((B)->n += (s))
#define luaL_buffsub(B,s)    ((B)->n -= (s))
#define luaL_prepbuffer(B)   luaL_prepbuffsize(B, LUAL_BUFFERSIZE)

/* luaL_Stream (PUC lauxlib.h:154) */
typedef struct luaL_Stream {
    FILE *f;
    lua_CFunction closef;
} luaL_Stream;

#define LUA_FILEHANDLE "FILE*"

/* ----------------------------------------------------------------------- */
/* Convenience macros — match PUC Lua 5.5 (lauxlib.h:47-136) exactly.       */
/* ----------------------------------------------------------------------- */

/* PUC `LUAL_NUMSIZES` (lauxlib.h:44): checksum encoding the sizes of
** lua_Integer and lua_Number in a single value. Matches PUC exactly
** so that .so files compiled against luazig headers are binary-compatible
** with PUC Lua (LUAL_NUMSIZES = sizeof(lua_Integer)*16 + sizeof(lua_Number)). */
#define LUAL_NUMSIZES	(sizeof(lua_Integer)*16 + sizeof(lua_Number))

#define luaL_checkversion(L) \
    luaL_checkversion_(L, LUA_VERSION_NUM, LUAL_NUMSIZES)

#define luaL_newlibtable(L,l) \
    lua_createtable(L, 0, sizeof(l)/sizeof((l)[0]) - 1)

#define luaL_newlib(L,l) \
    (luaL_checkversion(L), luaL_newlibtable(L,l), luaL_setfuncs(L,l,0))

/* Convenience macros (PUC lauxlib.h:124-136) */
#define luaL_checkstring(L, a) (luaL_checklstring(L, (a), NULL))
#define luaL_optstring(L, a, d) (luaL_optlstring(L, (a), NULL, (d)))
#define luaL_typename(L, i) lua_typename(L, lua_type(L, (i)))
#define luaL_pushfail(L) lua_pushnil(L)

#define luaL_dostring(L, s) \
    (luaL_loadstring(L, s) || lua_pcall(L, 0, LUA_MULTRET, 0))

#define luaL_loadbuffer(L, buff, sz, name) \
    luaL_loadbufferx(L, buff, sz, name, NULL)

#define luaL_loadfile(L, fn) \
    luaL_loadfilex(L, fn, NULL)

#define luaL_dofile(L, fn) \
    (luaL_loadfile(L, fn) || lua_pcall(L, 0, LUA_MULTRET, 0))

#endif /* lauxlib_h */
