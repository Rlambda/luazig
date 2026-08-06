/*
** lualib.h — standard library header for luazig.
**
** This header mirrors PUC Lua 5.5's lualib.h. It declares the
** `luaopen_*` entry points for each standard library and the
** `luaL_openselectedlibs` function for selective library loading.
**
** The `luaopen_*` functions are declared here but not yet all exported
** by luazig's C API shim (c_api.zig). They will be implemented in
** Phase 7 of the C API drop-in plan. Until then, the declarations
** exist so that C code including lualib.h compiles correctly.
*/
#ifndef lualib_h
#define lualib_h

#include "lua.h"


/* version suffix for environment variable names */
#define LUA_VERSUFFIX		"_" LUA_VERSION_MAJOR "_" LUA_VERSION_MINOR


/* Library name constants and luaopen_* declarations.
** Each LUA_*LIBK is a bitmask constant used by luaL_openselectedlibs.
** The bitmask values match PUC Lua 5.5 exactly. */

#define LUA_GLIBK		1
LUAMOD_API int (luaopen_base) (lua_State *L);

#define LUA_LOADLIBNAME	"package"
#define LUA_LOADLIBK	(LUA_GLIBK << 1)
LUAMOD_API int (luaopen_package) (lua_State *L);


#define LUA_COLIBNAME	"coroutine"
#define LUA_COLIBK	(LUA_LOADLIBK << 1)
LUAMOD_API int (luaopen_coroutine) (lua_State *L);

#define LUA_DBLIBNAME	"debug"
#define LUA_DBLIBK	(LUA_COLIBK << 1)
LUAMOD_API int (luaopen_debug) (lua_State *L);

#define LUA_IOLIBNAME	"io"
#define LUA_IOLIBK	(LUA_DBLIBK << 1)
LUAMOD_API int (luaopen_io) (lua_State *L);

#define LUA_MATHLIBNAME	"math"
#define LUA_MATHLIBK	(LUA_IOLIBK << 1)
LUAMOD_API int (luaopen_math) (lua_State *L);

#define LUA_OSLIBNAME	"os"
#define LUA_OSLIBK	(LUA_MATHLIBK << 1)
LUAMOD_API int (luaopen_os) (lua_State *L);

#define LUA_STRLIBNAME	"string"
#define LUA_STRLIBK	(LUA_OSLIBK << 1)
LUAMOD_API int (luaopen_string) (lua_State *L);

#define LUA_TABLIBNAME	"table"
#define LUA_TABLIBK	(LUA_STRLIBK << 1)
LUAMOD_API int (luaopen_table) (lua_State *L);

#define LUA_UTF8LIBNAME	"utf8"
#define LUA_UTF8LIBK	(LUA_TABLIBK << 1)
LUAMOD_API int (luaopen_utf8) (lua_State *L);


/* open selected libraries.
** 'load' is a bitmask of libraries to open (LUA_*LIBK constants).
** 'preload' is a bitmask of libraries to preload (registered but not
** opened). luaL_openlibs(L) opens all libraries. */
LUALIB_API void (luaL_openselectedlibs) (lua_State *L, int load, int preload);

/* open all libraries */
#define luaL_openlibs(L)	luaL_openselectedlibs(L, ~0, 0)


#endif
