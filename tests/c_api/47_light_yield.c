/*
 * 47_light_yield.c — permanent differential suite: yield and error
 * transport through light (nup=0) stdlib callees (A-full P2 cut P2b).
 *
 * PUC ground truth: the yieldable stdlib lanes (pcall, xpcall, pairs,
 * coroutine.resume/wrap driving light bodies) suspend and resume with
 * exact continuation semantics — the yielded values cross the light C
 * frames untouched, the resumed arguments arrive as the yield's
 * results, and errors raised inside keep their object through the
 * light boundary.
 *
 * Covers:
 *   - yield through light pcall: suspension mid-body, resume values
 *     delivered as the yield's results, pcall's final (ok, ...) tuple;
 *   - yield through light xpcall (with a message handler);
 *   - yield inside a pairs loop (light pairs, iterator product);
 *   - yield inside a gsub replacement function;
 *   - a light function as the coroutine body (resume VLCF lane):
 *     results, MULTRET counts, error status/type, dead status;
 *   - error object preservation through light pcall/xpcall inside a
 *     coroutine (table error objects survive identity-intact);
 *   - nested light funnels: pcall(pcall(...)) both yielding;
 *   - coroutine.wrap driving a light body (error re-raise on main);
 *   - the crash-class GC regression: light table keys + a generational
 *     GC drain while a coroutine with a light-keyed table resumes.
 *
 * Every printed line must be byte-identical between PUC Lua 5.5 and
 * luazig. Exit code is non-zero on any failed check.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int fails = 0;

static void check(long cond, const char *label) {
    printf("%s:%ld\n", label, cond);
    if (!cond) fails++;
}

static void dostr(lua_State *L, const char *code, const char *tag) {
    int st = luaL_dostring(L, code);
    if (st != LUA_OK) {
        printf("%s.ERROR:%s\n", tag, lua_tostring(L, -1));
        fails++;
        lua_pop(L, 1);
    }
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    check(L != NULL, "Y0.state");

    /* ---- yield through light pcall ---- */
    dostr(L,
        "local co = coroutine.create(function()\n"
        "  local ok, a, b = pcall(function()\n"
        "    local y1, y2 = coroutine.yield(7, 8)\n"
        "    return y1, y2, 'inner-done'\n"
        "  end)\n"
        "  return ok, a, b\n"
        "end)\n"
        "print('Y1.suspend', coroutine.resume(co))\n"
        "print('Y1.resume', coroutine.resume(co, 'r1', 'r2'))\n"
        "print('Y1.status', coroutine.status(co))\n",
        "Y1");

    /* ---- yield through light xpcall with a message handler ---- */
    dostr(L,
        "local co = coroutine.create(function()\n"
        "  local ok, v = xpcall(function()\n"
        "    coroutine.yield('xp')\n"
        "    error('boom')\n"
        "  end, function(m) return 'handled:' .. m end)\n"
        "  return ok, v\n"
        "end)\n"
        "print('Y2.suspend', coroutine.resume(co))\n"
        "print('Y2.resume', coroutine.resume(co))\n"
        "print('Y2.status', coroutine.status(co))\n",
        "Y2");

    /* ---- yield inside a pairs loop (light pairs) ---- */
    dostr(L,
        "local co = coroutine.create(function()\n"
        "  local acc = {}\n"
        "  for k, v in pairs({10, 20, 30}) do\n"
        "    acc[#acc + 1] = tostring(k) .. '=' .. tostring(v)\n"
        "    coroutine.yield(k)\n"
        "  end\n"
        "  return table.concat(acc, ',')\n"
        "end)\n"
        "print('Y3.first', coroutine.resume(co))\n"
        "print('Y3.second', coroutine.resume(co))\n"
        "print('Y3.third', coroutine.resume(co))\n"
        "print('Y3.done', coroutine.resume(co))\n",
        "Y3");

    /* ---- yield inside a gsub replacement function ---- */
    dostr(L,
        "local co = coroutine.create(function()\n"
        "  return ('aXbXc'):gsub('X', function(m)\n"
        "    coroutine.yield('rep:' .. m)\n"
        "    return 'Y'\n"
        "  end)\n"
        "end)\n"
        "print('Y4.suspend1', coroutine.resume(co))\n"
        "print('Y4.suspend2', coroutine.resume(co))\n"
        "print('Y4.done', coroutine.resume(co))\n",
        "Y4");

    /* ---- light function as the coroutine body (VLCF lane) ---- */
    dostr(L,
        "local co = coroutine.create(math.max)\n"
        "print('Y5.body-max', coroutine.resume(co, 3, 9, 4))\n"
        "print('Y5.body-status', coroutine.status(co))\n"
        "local co2 = coroutine.create(string.byte)\n"
        "print('Y5.body-byte', coroutine.resume(co2, 'AB'))\n"
        "local co3 = coroutine.create(select)\n"
        "print('Y5.body-select', coroutine.resume(co3, '#', 'a', 'b'))\n"
        "local co4 = coroutine.create(string.rep)\n"
        "print('Y5.body-err-status', (select(1, coroutine.resume(co4, 'x', -1))))\n"
        "print('Y5.body-err-type', type((select(2, coroutine.resume(co4, 'x', -1)))))\n"
        "print('Y5.body-dead', coroutine.status(co4))\n",
        "Y5");

    /* ---- error object preservation through light pcall/xpcall ---- */
    dostr(L,
        "local obj = {code = 42}\n"
        "local ok, e = pcall(function() error(obj) end)\n"
        "print('Y6.pcall-obj', ok, e == obj, e.code)\n"
        "local ok2, e2 = xpcall(function() error(obj) end, function(m)\n"
        "  return m\n"
        "end)\n"
        "print('Y6.xpcall-obj', ok2, e2 == obj, e2.code)\n"
        "local co = coroutine.create(function()\n"
        "  local o2 = {inner = true}\n"
        "  local ok3, e3 = pcall(function() error(o2) end)\n"
        "  coroutine.yield(e3 == o2, e3.inner)\n"
        "  local ok4, e4 = pcall(error, o2)\n"
        "  return ok4, e4 == o2\n"
        "end)\n"
        "print('Y6.co-obj-yield', coroutine.resume(co))\n"
        "print('Y6.co-obj-return', coroutine.resume(co))\n",
        "Y6");

    /* ---- nested light funnels both yielding ---- */
    dostr(L,
        "local co = coroutine.create(function()\n"
        "  local ok = pcall(function()\n"
        "    pcall(function()\n"
        "      coroutine.yield('deep')\n"
        "    end)\n"
        "    return 'outer-inner-ok'\n"
        "  end)\n"
        "  return ok\n"
        "end)\n"
        "print('Y7.suspend', coroutine.resume(co))\n"
        "print('Y7.done', coroutine.resume(co))\n",
        "Y7");

    /* ---- coroutine.wrap driving a light body ---- */
    dostr(L,
        "local w = coroutine.wrap(math.abs)\n"
        "print('Y8.wrap-body', w(-5))\n"
        "local w2 = coroutine.wrap(string.reverse)\n"
        "print('Y8.wrap-body-str', w2('ab'))\n"
        "local w3 = coroutine.wrap(string.rep)\n"
        "print('Y8.wrap-err-status', (select(1, pcall(w3, 'x', -1))))\n"
        "print('Y8.wrap-err-type', type((select(2, pcall(w3, 'x', -1)))))\n",
        "Y8");

    /* ---- crash-class GC regression: light table keys + generational
     * drain while a coroutine with a light-keyed table resumes ---- */
    dostr(L,
        "local t = {}\n"
        "t[math.floor] = 'floor'\n"
        "t[string.rep] = 'rep'\n"
        "print('Y9.prelude', t[math.floor])\n"
        "local co = coroutine.create(function(...)\n"
        "  return select('#', ...), t[math.floor]\n"
        "end)\n"
        "print('Y9.resume', coroutine.resume(co, 1, 2))\n"
        "collectgarbage()\n"
        "print('Y9.after-gc', t[math.floor], t[string.rep])\n"
        "local co2 = coroutine.create(function(...)\n"
        "  return select('#', ...)\n"
        "end)\n"
        "print('Y9.resume2', coroutine.resume(co2, 1, 2))\n"
        "print('Y9.done', 'ok')\n",
        "Y9");

    /* ---- the C lane: a light call on a coroutine handle while the
     * same coroutine's stack holds light-keyed tables (window staging
     * across a GC step) ---- */
    dostr(L,
        "local kt = setmetatable({}, {__mode = 'k'})\n"
        "kt[coroutine.resume] = 1\n"
        "kt[math.floor] = 2\n"
        "local co = coroutine.create(function()\n"
        "  local x = {}\n"
        "  x[tostring] = 'ts'\n"
        "  coroutine.yield(x[tostring], kt[math.floor])\n"
        "  return 'body-end'\n"
        "end)\n"
        "print('Y10.suspend', coroutine.resume(co))\n"
        "collectgarbage('collect')\n"
        "print('Y10.after-gc', coroutine.resume(co))\n"
        "print('Y10.weak-keys', kt[coroutine.resume], kt[math.floor])\n",
        "Y10");

    lua_close(L);
    printf("LIGHT_YIELD: %d failures\n", fails);
    return fails ? 1 : 0;
}
