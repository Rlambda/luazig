/*
** ltests.h — user header activating the ltests machinery (LUA_DEBUG).
** Reconstructed from ltests.c usage: Memcontrol drives debug_realloc
** (numblocks/total/maxmem/memlimit/countlimit/failnext/objcount).
*/
#ifndef ltests_h
#define ltests_h

#define LUAI_MAXCCALLS		200

typedef struct Memcontrol {
  int failnext;                /* 1: fake a single alloc error */
  unsigned long numblocks;
  unsigned long total;
  unsigned long maxmem;
  unsigned long memlimit;
  unsigned long countlimit;    /* ~0UL: unlimited (ltests.c initializer) */
  unsigned long objcount[LUA_NUMTYPES];
} Memcontrol;

extern Memcontrol l_memcontrol;
int luaB_opentests (lua_State *L);

#endif
