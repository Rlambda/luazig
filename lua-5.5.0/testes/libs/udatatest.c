#include "lua.h"
#include "lauxlib.h"

typedef struct {
    int x;
    int y;
} Point;

static int new_point(lua_State *L) {
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    Point *p = (Point *)lua_newuserdatauv(L, sizeof(Point), 0);
    p->x = x;
    p->y = y;
    luaL_setmetatable(L, "Point");
    return 1;
}

static int point_getx(lua_State *L) {
    Point *p = (Point *)luaL_checkudata(L, 1, "Point");
    lua_pushinteger(L, p->x);
    return 1;
}

static int point_gety(lua_State *L) {
    Point *p = (Point *)luaL_checkudata(L, 1, "Point");
    lua_pushinteger(L, p->y);
    return 1;
}

static int point_tostring(lua_State *L) {
    Point *p = (Point *)luaL_checkudata(L, 1, "Point");
    lua_pushfstring(L, "Point(%d, %d)", (int)p->x, (int)p->y);
    return 1;
}

static const struct luaL_Reg point_methods[] = {
    {"getx", point_getx},
    {"gety", point_gety},
    {"__tostring", point_tostring},
    {NULL, NULL}
};

LUAMOD_API int luaopen_udatatest(lua_State *L) {
    luaL_checkversion(L);
    luaL_newmetatable(L, "Point");
    luaL_setfuncs(L, point_methods, 0);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, new_point);
    lua_setglobal(L, "newpoint");
    return 0;
}
