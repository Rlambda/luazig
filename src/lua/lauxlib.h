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

#endif /* lauxlib_h */
