/*
** lua_gc_shim.c — Variadic C shim for lua_gc.
**
** PUC Lua's `lua_gc` is variadic: `int lua_gc(lua_State *L, int what, ...)`.
** For LUA_GCPARAM, it takes two varargs (int param, int value); for all
** other options, one vararg (int data, or size_t n for LUA_GCSTEP).
**
** Zig cannot export C variadic functions, so we expose two fixed-arg Zig
** functions (`luazigGcFixed` / `luazigGcParam`) and provide this C shim
** that implements the variadic dispatch. The shim is compiled into liblua.so
** / liblua.a alongside the Zig object code.
*/
#include <stdarg.h>
#include "lua.h"

/* Forward declarations of the Zig-exported fixed-arg functions. */
LUA_API int luazigGcFixed(lua_State *L, int what, int data);
LUA_API int luazigGcParam(lua_State *L, int param, int value);

LUA_API int lua_gc(lua_State *L, int what, ...) {
    va_list ap;
    va_start(ap, what);
    int r;
    if (what == LUA_GCPARAM) {
        int param = va_arg(ap, int);
        int value = va_arg(ap, int);
        r = luazigGcParam(L, param, value);
    } else {
        int data = va_arg(ap, int);
        r = luazigGcFixed(L, what, data);
    }
    va_end(ap);
    return r;
}
