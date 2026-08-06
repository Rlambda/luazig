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

#include "luaconf.h"

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

/* LUAI_MAXSTACK is defined in luaconf.h. */
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

/* Total number of Lua types (PUC lua.h:74). */
#define LUA_NUMTYPES 9

/* Minimum Lua stack available to a C function (PUC lua.h:79). */
#define LUA_MINSTACK 20

/* ----------------------------------------------------------------------- */
/* Registry indices (PUC lua.h:82-86)                                      */
/*                                                                         */
/* Index 1 is reserved for the reference mechanism (luaL_ref/luaL_unref).  */
/* Index 2 is the globals table. Index 3 is the main thread.               */
/* ----------------------------------------------------------------------- */

#define LUA_RIDX_GLOBALS 2
#define LUA_RIDX_MAINTHREAD 3
#define LUA_RIDX_LAST 3

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
#define LUA_RELEASE LUA_VERSION "." LUA_VERSION_RELEASE

/* Mark for precompiled code (PUC lua.h:32). */
#define LUA_SIGNATURE "\x1bLua"

/* Version release number as integer: 50500 for 5.5.0 (PUC lua.h:25). */
#define LUA_VERSION_RELEASE_NUM (LUA_VERSION_NUM * 100 + 0)

#define LUA_COPYRIGHT LUA_RELEASE "  Copyright (C) 1994-2025 Lua.org, PUC-Rio"
#define LUA_AUTHORS "R. Ierusalimschy, L. H. de Figueiredo, W. Celes"

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
/* Arithmetic operators (PUC lua.h:215-228)                                */
/*                                                                         */
/* Used by lua_arith(). ORDER TM must match the tag method order.          */
/* ----------------------------------------------------------------------- */

#define LUA_OPADD 0
#define LUA_OPSUB 1
#define LUA_OPMUL 2
#define LUA_OPMOD 3
#define LUA_OPPOW 4
#define LUA_OPDIV 5
#define LUA_OPIDIV 6
#define LUA_OPBAND 7
#define LUA_OPBOR 8
#define LUA_OPBXOR 9
#define LUA_OPSHL 10
#define LUA_OPSHR 11
#define LUA_OPUNM 12
#define LUA_OPBNOT 13

/* ----------------------------------------------------------------------- */
/* Comparison operators (PUC lua.h:232-234)                                */
/*                                                                         */
/* Used by lua_compare().                                                   */
/* ----------------------------------------------------------------------- */

#define LUA_OPEQ 0
#define LUA_OPLT 1
#define LUA_OPLE 2

/* ----------------------------------------------------------------------- */
/* Garbage-collection options (PUC lua.h:331-340)                          */
/*                                                                         */
/* Used by lua_gc(). luazig does not yet export lua_gc, but the            */
/* constants are defined for header completeness.                          */
/* ----------------------------------------------------------------------- */

#define LUA_GCSTOP 0
#define LUA_GCRESTART 1
#define LUA_GCCOLLECT 2
#define LUA_GCCOUNT 3
#define LUA_GCCOUNTB 4
#define LUA_GCSTEP 5
#define LUA_GCISRUNNING 6
#define LUA_GCGEN 7
#define LUA_GCINC 8
#define LUA_GCPARAM 9

/* GC parameters for generational mode (PUC lua.h:347-349). */
#define LUA_GCPMINORMUL 0
#define LUA_GCPMAJORMINOR 1
#define LUA_GCPMINORMAJOR 2

/* GC parameters for incremental mode (PUC lua.h:352-354). */
#define LUA_GCPPAUSE 3
#define LUA_GCPSTEPMUL 4
#define LUA_GCPSTEPSIZE 5

/* Number of GC parameters (PUC lua.h:357). */
#define LUA_GCPN 6

/* ----------------------------------------------------------------------- */
/* Debug API: hook events and masks (PUC lua.h:454-467)                    */
/*                                                                         */
/* Used by lua_sethook/lua_gethookmask. luazig does not yet export the     */
/* debug API, but the constants are defined for header completeness.       */
/* ----------------------------------------------------------------------- */

#define LUA_HOOKCALL 0
#define LUA_HOOKRET 1
#define LUA_HOOKLINE 2
#define LUA_HOOKCOUNT 3
#define LUA_HOOKTAILCALL 4

#define LUA_MASKCALL (1 << LUA_HOOKCALL)
#define LUA_MASKRET (1 << LUA_HOOKRET)
#define LUA_MASKLINE (1 << LUA_HOOKLINE)
#define LUA_MASKCOUNT (1 << LUA_HOOKCOUNT)

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
LUA_API int   (lua_rawgeti)(lua_State *L, int idx, lua_Integer n);
LUA_API int   (lua_next)(lua_State *L, int idx);

/* ----------------------------------------------------------------------- */
/* Call / error (PUC lapi.c / ldo.c)                                       */
/* ----------------------------------------------------------------------- */

LUA_API void  (lua_callk)(lua_State *L, int nargs, int nresults,
                          lua_KContext ctx, lua_KFunction k);
LUA_API int   (lua_pcallk)(lua_State *L, int nargs, int nresults, int errfunc,
                           lua_KContext ctx, lua_KFunction k);
LUA_API int   (lua_error)(lua_State *L);

/* Close a thread, releasing its resources (PUC lua.h:166). */
LUA_API int   (lua_closethread)(lua_State *L, lua_State *from);

/* Destroy a Lua state and release all resources (PUC lua.h:163).
** In PUC Lua 5.5 lua_close(L) is a macro expanding to lua_closethread(L, NULL);
** luazig exports it as a real symbol for ABI compatibility with C code that
** takes its address. */
LUA_API int   (lua_close)(lua_State *L);

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

/* ----------------------------------------------------------------------- */
/* Type predicate convenience macros (PUC lua.h:404-411).                  */
/* ----------------------------------------------------------------------- */

#define lua_isnil(L,n)           (lua_type(L, (n)) == LUA_TNIL)
#define lua_isboolean(L,n)       (lua_type(L, (n)) == LUA_TBOOLEAN)
#define lua_isfunction(L,n)      (lua_type(L, (n)) == LUA_TFUNCTION)
#define lua_istable(L,n)         (lua_type(L, (n)) == LUA_TTABLE)
#define lua_isthread(L,n)        (lua_type(L, (n)) == LUA_TTHREAD)
#define lua_isnone(L,n)          (lua_type(L, (n)) == LUA_TNONE)
#define lua_isnoneornil(L, n)    (lua_type(L, (n)) <= 0)
#define lua_islightuserdata(L,n) (lua_type(L, (n)) == LUA_TLIGHTUSERDATA)

/* ----------------------------------------------------------------------- */
/* Other convenience macros (PUC lua.h:44, 415-416).                       */
/* ----------------------------------------------------------------------- */

/* Upvalue pseudo-index: LUA_REGISTRYINDEX - i (PUC lua.h:44). */
#define lua_upvalueindex(i)      (LUA_REGISTRYINDEX - (i))

/* Push the globals table onto the stack (PUC lua.h:415-416). */
#define lua_pushglobaltable(L)   \
    ((void)lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS))

/* ----------------------------------------------------------------------- */
/* Compatibility macros (PUC lua.h:436-440).                               */
/* ----------------------------------------------------------------------- */

#define lua_newuserdata(L,s)     lua_newuserdatauv(L, s, 1)
#define lua_getuservalue(L,idx)  lua_getiuservalue(L, idx, 1)
#define lua_setuservalue(L,idx)  lua_setiuservalue(L, idx, 1)
#define lua_resetthread(L)       lua_closethread(L, NULL)

/* LUAMOD_API: prefix for `luaopen_*` entry points. Empty/extern everywhere. */
#define LUAMOD_API extern

#endif /* lua_h */
