/*
** lua.h — minimal C API header for luazig extension libraries.
**
** This header mirrors the subset of PUC Lua 5.5's lua.h that luazig
** implements. It is used to compile C extension libraries (.so) against
** luazig's C API shim (src/lua/c_api.zig), which exports the corresponding
** `lua_*` / `luaL_*` symbols.
**
** The macro definitions (lua_call, lua_pushcfunction, lua_tointeger, ...)
** match PUC Lua 5.5 (lua.h:394-425) exactly so that the SAME source file
** (e.g. lua-5.5.0/testes/libs/lib1.c) compiles unchanged against either PUC's
** lua.h or this header, producing a .so that links against the matching
** runtime.
**
** `lua_State` is an opaque handle — in luazig it is a `Vm` struct, but C
** code only passes the pointer around, never dereferencing it directly.
*/
#ifndef lua_h
#define lua_h

#include <stddef.h>
#include <stdint.h>

/* "Public" API entry points are extern (visible across .so boundary). */
#define LUA_API extern
#define LUALIB_API extern

/* ----------------------------------------------------------------------- */
/* Core types                                                              */
/* ----------------------------------------------------------------------- */

/* `lua_State` is opaque to C code. In luazig it is `Vm`; the C shim
** (c_api.zig) casts the pointer to `*Vm` on every entry point. */
struct Vm;
typedef struct Vm lua_State;

/* PUC `lua_CFunction` (lua.h:101): int (*)(lua_State *). */
typedef int (*lua_CFunction)(lua_State *L);

/* PUC `lua_Alloc` (lua.h:126): the allocator signature. */
typedef void *(*lua_Alloc)(void *ud, void *ptr, size_t osize, size_t nsize);

/* PUC `lua_Integer` / `lua_Number` (lua.h:80, lua.h:87). */
typedef int64_t lua_Integer;
typedef double lua_Number;

/* PUC continuation context/function (lua.h:297-299). Continuations are not
** supported by luazig's C-call model, but the types must exist so headers
** parse and `lua_callk` has a matching prototype. */
typedef ptrdiff_t lua_KContext;
typedef int (*lua_KFunction)(lua_State *L, int status, lua_KContext ctx);

/* ----------------------------------------------------------------------- */
/* Status codes (lua.h:71)                                                 */
/* ----------------------------------------------------------------------- */

#define LUA_OK 0
#define LUA_YIELD 1
#define LUA_ERRRUN 2
#define LUA_ERRSYNTAX 3
#define LUA_ERRMEM 4
#define LUA_ERRERR 5

/* ----------------------------------------------------------------------- */
/* Pseudo-indices (lua.h:43)                                               */
/* ----------------------------------------------------------------------- */

#define LUAI_MAXSTACK 1000000
#define LUA_REGISTRYINDEX (-LUAI_MAXSTACK - 1000)

/* ----------------------------------------------------------------------- */
/* Type codes (lua.h:83)                                                   */
/* ----------------------------------------------------------------------- */

#define LUA_TNONE (-1)
#define LUA_TNIL 0
#define LUA_TBOOLEAN 1
#define LUA_TLIGHTUSERDATA 2
#define LUA_TNUMBER 3
#define LUA_TSTRING 4
#define LUA_TTABLE 5
#define LUA_TFUNCTION 6
#define LUA_TUSERDATA 7
#define LUA_TTHREAD 8

/* ----------------------------------------------------------------------- */
/* Option constants                                                        */
/* ----------------------------------------------------------------------- */

#define LUA_MULTRET (-1)
#define LUA_REFNIL (-1)
#define LUA_NOREF (-2)

/* ----------------------------------------------------------------------- */
/* Version                                                                 */
/* ----------------------------------------------------------------------- */

#define LUA_VERSION_MAJOR "5"
#define LUA_VERSION_MINOR "5"
#define LUA_VERSION_NUM 505
#define LUA_VERSION_RELEASE "0"
#define LUA_VERSION "Lua " LUA_VERSION_MAJOR "." LUA_VERSION_MINOR

/* ----------------------------------------------------------------------- */
/* Stack manipulation (PUC lapi.c)                                         */
/* ----------------------------------------------------------------------- */

LUA_API int   (lua_gettop)(lua_State *L);
LUA_API void  (lua_settop)(lua_State *L, int idx);
LUA_API void  (lua_rotate)(lua_State *L, int idx, int n);
LUA_API void  (lua_copy)(lua_State *L, int fromidx, int toidx);

/* ----------------------------------------------------------------------- */
/* Push functions (PUC lapi.c)                                             */
/* ----------------------------------------------------------------------- */

LUA_API void  (lua_pushnil)(lua_State *L);
LUA_API void  (lua_pushboolean)(lua_State *L, int b);
LUA_API void  (lua_pushinteger)(lua_State *L, lua_Integer n);
LUA_API void  (lua_pushnumber)(lua_State *L, lua_Number n);
LUA_API void  (lua_pushlstring)(lua_State *L, const char *s, size_t len);
LUA_API void  (lua_pushstring)(lua_State *L, const char *s);
LUA_API void  (lua_pushvalue)(lua_State *L, int idx);
LUA_API void  (lua_pushcclosure)(lua_State *L, lua_CFunction fn, int n);
LUA_API void  (lua_pushfstring)(lua_State *L, const char *fmt, ...);
LUA_API void  (lua_pushexternalstring)(lua_State *L, char *s, size_t len,
                                       lua_Alloc falloc, void *ud);

/* ----------------------------------------------------------------------- */
/* Userdata functions (PUC lapi.c)                                         */
/* ----------------------------------------------------------------------- */

LUA_API void *(lua_newuserdatauv)(lua_State *L, size_t sz, int nuvalue);
LUA_API void *(lua_touserdata)(lua_State *L, int idx);
LUA_API void *(lua_topointer)(lua_State *L, int idx);
LUA_API void  (lua_pushlightuserdata)(lua_State *L, void *p);
LUA_API int   (lua_setmetatable)(lua_State *L, int objindex);
LUA_API int   (lua_getmetatable)(lua_State *L, int objindex);
LUA_API int   (lua_setiuservalue)(lua_State *L, int idx, int n);
LUA_API int   (lua_getiuservalue)(lua_State *L, int idx, int n);

/* ----------------------------------------------------------------------- */
/* Get functions (PUC lapi.c)                                              */
/* ----------------------------------------------------------------------- */

LUA_API int   (lua_type)(lua_State *L, int idx);
LUA_API int   (lua_toboolean)(lua_State *L, int idx);
LUA_API lua_Integer (lua_tointegerx)(lua_State *L, int idx, int *isnum);
LUA_API lua_Number  (lua_tonumberx)(lua_State *L, int idx, int *isnum);

/* ----------------------------------------------------------------------- */
/* Table functions (PUC lapi.c)                                            */
/* ----------------------------------------------------------------------- */

LUA_API void  (lua_createtable)(lua_State *L, int narr, int nrec);
LUA_API void  (lua_setglobal)(lua_State *L, const char *name);
LUA_API int   (lua_getglobal)(lua_State *L, const char *name);
LUA_API void  (lua_setfield)(lua_State *L, int idx, const char *k);
LUA_API int   (lua_getfield)(lua_State *L, int idx, const char *k);
LUA_API void  (lua_rawset)(lua_State *L, int idx);
LUA_API int   (lua_rawget)(lua_State *L, int idx);
LUA_API int   (lua_next)(lua_State *L, int idx);

/* ----------------------------------------------------------------------- */
/* Call / error (PUC lapi.c / ldo.c)                                       */
/* ----------------------------------------------------------------------- */

LUA_API void  (lua_callk)(lua_State *L, int nargs, int nresults,
                          lua_KContext ctx, lua_KFunction k);
LUA_API int   (lua_pcallk)(lua_State *L, int nargs, int nresults, int errfunc,
                           lua_KContext ctx, lua_KFunction k);
LUA_API int   (lua_error)(lua_State *L);

/* ----------------------------------------------------------------------- */
/* Allocator (PUC lstate.c)                                                */
/* ----------------------------------------------------------------------- */

LUA_API lua_Alloc (lua_getallocf)(lua_State *L, void **ud);

/* ----------------------------------------------------------------------- */
/* Convenience macros — match PUC Lua 5.5 (lua.h:394-425) exactly.          */
/* These expand to the underlying functions declared above, so a .so built  */
/* against this header resolves the SAME symbols as a .so built against     */
/* PUC's lua.h.                                                            */
/* ----------------------------------------------------------------------- */

#define lua_pop(L,n)             lua_settop(L, -(n)-1)
#define lua_newtable(L)          lua_createtable(L, 0, 0)
#define lua_tointeger(L,i)       lua_tointegerx(L,(i),NULL)
#define lua_tonumber(L,i)        lua_tonumberx(L,(i),NULL)
#define lua_pushcfunction(L,f)   lua_pushcclosure(L, (f), 0)
#define lua_insert(L,idx)        lua_rotate(L, (idx), 1)
#define lua_remove(L,idx)        (lua_rotate(L, (idx), -1), lua_pop(L, 1))
#define lua_replace(L,idx)       (lua_copy(L, -1, (idx)), lua_pop(L, 1))
#define lua_pushliteral(L, s)    lua_pushstring(L, "" s)
#define lua_register(L,n,f)      (lua_pushcfunction(L, (f)), lua_setglobal(L, (n)))
#define lua_call(L,n,r)          lua_callk(L, (n), (r), 0, NULL)
#define lua_pcall(L,n,r,f)       lua_pcallk(L, (n), (r), (f), 0, NULL)

/* LUAMOD_API: prefix for `luaopen_*` entry points. Empty/extern everywhere. */
#define LUAMOD_API extern

#endif /* lua_h */
