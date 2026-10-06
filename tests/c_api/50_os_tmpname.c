/* 50_os_tmpname: os.tmpname as a stateless exclusive-create producer
 * (PUC POSIX loslib.c: mkstemp("/tmp/lua_XXXXXX") — the file is created
 * atomically with mode 0600, the fd is closed, and no Lua- or VM-owned
 * RNG state participates).
 *
 * Differential suite compiled against the POSIX-configured PUC oracle
 * (%-pucposix): the default in-tree liblua.so may be built without
 * LUA_USE_POSIX, where os.tmpname maps to tmpnam() and creates no file —
 * not the contract under test.
 *
 * The suite never enumerates /tmp and never removes a name it did not
 * obtain from its own os.tmpname() call, so parallel runs of any number
 * of suites (zig or PUC) cannot interfere through shared /tmp state.
 * Files whose name is lost before an error surfaces (the ERRMEM edge:
 * the create succeeded, the failing allocation dropped the name) are
 * left behind exactly like PUC leaves them.
 *
 * Checked properties: name shape (/tmp/lua_ + 6 alphanumerics), file
 * created with mode 0600 and removable, distinct names within a state,
 * across two states in one process, after VM reuse and after full GC;
 * the create side effect survives result discarding (nresults=0) —
 * proven WITHOUT /tmp inventory: under a deterministically exhausted
 * descriptor table a result-discarding call must still attempt the
 * exclusive create and raise the same catchable create failure (an
 * implementation that skips the create when no result is wanted would
 * return LUA_OK); math.random's sequence and RanState upvalue are
 * untouched; descriptor count is stable across every call variant (the
 * fd is closed on all paths); a forced create failure (exhausted
 * descriptor table) raises a catchable error carrying the PUC message
 * and the state recovers; allocation-failure edges (frozen countdown
 * allocator) fail with LUA_ERRMEM + string error object, recover,
 * retry, and leave no descriptors behind. The per-runtime allocation
 * structure is not a parity contract, so OOM trials print a normalized
 * verdict, not the raw k-matrix. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int fails = 0;
__attribute__((constructor)) static void unbuf(void) { setbuf(stdout, NULL); }
static void check(long cond, const char *label) {
    printf("%s:%ld\n", label, cond);
    if (!cond) fails++;
}

/* ---- own-process descriptor inventory (no /tmp access) ---- */

static int count_fds(void) {
    DIR *d = opendir("/proc/self/fd");
    if (!d) return -1;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) n++;
    closedir(d);
    return n - 1;   /* exclude the directory's own fd */
}

static int max_fd(void) {
    DIR *d = opendir("/proc/self/fd");
    if (!d) return -1;
    int mx = -1;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        int fd = atoi(e->d_name);
        if (fd > mx) mx = fd;
    }
    closedir(d);
    return mx;
}

static int file_exists_mode(const char *p, mode_t *mode_out) {
    struct stat st;
    if (stat(p, &st) != 0) return 0;
    if (mode_out) *mode_out = st.st_mode & 0777;
    return 1;
}

/* ---- deterministic descriptor exhaustion ----
 * Lower the NOFILE soft limit to just above the current maximum
 * descriptor number and fill every hole below it with /dev/null
 * descriptors, so the next file create deterministically hits EMFILE.
 * Returns the filler count, or -1 if a probe create still succeeded
 * (exhaustion failed — the caller's checks then fail loudly). */
static int fillers[1200];
static void restore_fds(const struct rlimit *rl_old, int n);
static int exhaust_fds(struct rlimit *rl_old) {
    if (getrlimit(RLIMIT_NOFILE, rl_old) != 0) return -1;
    struct rlimit rl = *rl_old;
    int mx = max_fd();
    if (mx < 0) return -1;
    rl.rlim_cur = (rlim_t)(mx + 1);
    if (setrlimit(RLIMIT_NOFILE, &rl) != 0) return -1;
    int n = 0;
    while (n < 1200) {
        int fd = open("/dev/null", O_RDONLY);
        if (fd < 0) break;
        fillers[n++] = fd;
    }
    int probe = open("/dev/null", O_RDONLY);
    if (probe >= 0) {
        /* exhaustion failed: undo everything before reporting */
        close(probe);
        restore_fds(rl_old, n);
        return -1;
    }
    return n;
}

static void restore_fds(const struct rlimit *rl_old, int n) {
    for (int i = 0; i < n; i++) close(fillers[i]);
    setrlimit(RLIMIT_NOFILE, rl_old);
}

/* one os.tmpname call under pcall; leaves the result (or error) on top */
static int call_tmpname(lua_State *L) {
    lua_getglobal(L, "os");
    lua_getfield(L, -1, "tmpname");
    lua_replace(L, -2);              /* [tmpname] */
    return lua_pcall(L, 0, 1, 0);    /* [result|err] */
}

/* PUC POSIX name shape: /tmp/lua_ + exactly 6 alphanumerics */
static int name_shape(const char *s) {
    if (strlen(s) != 15) return 0;
    if (strncmp(s, "/tmp/lua_", 9) != 0) return 0;
    for (int i = 9; i < 15; i++) {
        char c = s[i];
        int alnum = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
                    (c >= 'a' && c <= 'z');
        if (!alnum) return 0;
    }
    return 1;
}

/* ---- frozen-countdown allocator for the OOM lane ---- */

static int countdown = -1;
static int frozen = 0;
static void *falloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    (void)ud; (void)osize;
    if (nsize == 0) { free(ptr); return NULL; }
    if (frozen) return NULL;
    if (countdown > 0) {
        countdown--;
        if (countdown == 0) { frozen = 1; return NULL; }
    }
    if (ptr) return realloc(ptr, nsize);
    return malloc(nsize);
}

static void oom_trial(int k) {
    lua_State *L = lua_newstate(falloc, NULL, 0);
    if (!L) { printf("oom.k=%d: newstate-failed\n", k); fails++; return; }
    luaL_openlibs(L);
    int fds_before = count_fds();
    countdown = k; frozen = 0;
    int st = call_tmpname(L);
    countdown = -1; frozen = 0;
    const char *verdict = "clean";
    if (st == LUA_OK) {
        const char *n = lua_tostring(L, -1);
        if (!name_shape(n)) verdict = "VIOLATION(shape)";
        else {
            mode_t m;
            if (!file_exists_mode(n, &m)) verdict = "VIOLATION(file)";
            else if (m != 0600) verdict = "VIOLATION(mode)";
            else remove(n);
        }
        lua_pop(L, 1);
    } else if (st == LUA_ERRMEM) {
        if (lua_type(L, -1) != LUA_TSTRING) verdict = "VIOLATION(errtype)";
        lua_pop(L, 1);
        lua_gc(L, LUA_GCCOLLECT, 0);
        /* VM reuse after the failure: retry must succeed with a valid,
         * created, removable file. A file created by the failed attempt
         * before its allocation failed is unknowable (the name was lost
         * with the error) and is left behind, exactly like PUC. */
        int st2 = call_tmpname(L);
        if (st2 != LUA_OK) { verdict = "VIOLATION(retry)"; lua_pop(L, 1); }
        else {
            const char *n = lua_tostring(L, -1);
            mode_t m;
            if (!name_shape(n) || !file_exists_mode(n, &m) || m != 0600)
                verdict = "VIOLATION(retry-file)";
            else remove(n);
            lua_pop(L, 1);
        }
    } else {
        verdict = "VIOLATION(status)";
        lua_pop(L, 1);
    }
    /* the descriptor must be closed on every path (incl. the failed
     * attempt's exclusive create before the failing allocation) */
    if (count_fds() != fds_before) verdict = "VIOLATION(fd-leak)";
    printf("oom.k=%d: %s\n", k, verdict);
    if (verdict[0] == 'V') fails++;
    lua_close(L);
}

int main(void) {
    lua_State *L = luaL_newstate(); luaL_openlibs(L);
    lua_State *L2 = luaL_newstate(); luaL_openlibs(L2);

    /* distinct across two states in one process; files created */
    char n1[64] = "", n2[64] = "", n3[64] = "";
    if (call_tmpname(L) == LUA_OK) { snprintf(n1, sizeof(n1), "%s", lua_tostring(L, -1)); lua_pop(L, 1); }
    if (call_tmpname(L2) == LUA_OK) { snprintf(n2, sizeof(n2), "%s", lua_tostring(L2, -1)); lua_pop(L2, 1); }
    check(n1[0] && n2[0], "two_states_names");
    check(strcmp(n1, n2) != 0, "two_states_distinct");
    mode_t m1;
    check(file_exists_mode(n1, &m1), "state1_file");
    check(m1 == 0600, "state1_mode0600");
    mode_t m2;
    check(file_exists_mode(n2, &m2), "state2_file");
    check(m2 == 0600, "state2_mode0600");
    check(name_shape(n1) && name_shape(n2), "names_shape");
    check(remove(n1) == 0, "state1_removed");
    check(remove(n2) == 0, "state2_removed");

    /* serial uniqueness in one state + fd stability across the storm */
    int fds_before = count_fds();
    int distinct = 1, files = 1, shapes = 1, removed = 1;
    char prev[64] = "";
    for (int i = 0; i < 50; i++) {
        if (call_tmpname(L) != LUA_OK) { distinct = files = shapes = removed = 0; break; }
        const char *n = lua_tostring(L, -1);
        if (strcmp(n, prev) == 0) distinct = 0;
        snprintf(prev, sizeof(prev), "%s", n);
        if (!name_shape(n)) shapes = 0;
        mode_t m;
        if (!file_exists_mode(n, &m) || m != 0600) files = 0;
        if (remove(n) != 0) removed = 0;
        lua_pop(L, 1);
    }
    check(distinct, "serial_distinct");
    check(shapes, "serial_shape");
    check(files, "serial_files_mode0600");
    check(removed, "serial_removed");
    check(count_fds() == fds_before, "serial_fd_stable");

    /* post-GC: still distinct, file still created */
    lua_gc(L, LUA_GCCOLLECT); lua_gc(L, LUA_GCCOLLECT);
    if (call_tmpname(L) == LUA_OK) { snprintf(n3, sizeof(n3), "%s", lua_tostring(L, -1)); lua_pop(L, 1); }
    check(n3[0] && strcmp(n3, n1) != 0, "post_gc_distinct");
    mode_t m3;
    check(file_exists_mode(n3, &m3) && m3 == 0600, "post_gc_file_mode0600");
    check(remove(n3) == 0, "post_gc_removed");

    /* the create side effect survives result discarding (nresults=0),
     * proven without any /tmp inventory: under a deterministically
     * exhausted descriptor table the result-discarding call must still
     * attempt the exclusive create and raise the same catchable create
     * failure — an implementation that skips the create when no result
     * is wanted would return LUA_OK here. */
    int fds_before_nr = count_fds();
    struct rlimit rl_nr;
    int nfill_nr = exhaust_fds(&rl_nr);
    check(nfill_nr >= 0, "noresult_fds_exhausted");
    lua_getglobal(L, "os");
    lua_getfield(L, -1, "tmpname");
    lua_replace(L, -2);
    int st_nr = lua_pcall(L, 0, 0, 0);          /* nresults = 0 */
    int raised = (st_nr != LUA_OK);
    const char *body_nr = NULL;
    if (st_nr != LUA_OK) {
        body_nr = lua_tostring(L, -1);
        lua_pop(L, 1);
    }
    restore_fds(&rl_nr, nfill_nr);
    check(raised, "noresult_create_error_raised");
    check(body_nr != NULL && strstr(body_nr, "unable to generate a unique filename") != NULL,
          "noresult_error_body");
    check(count_fds() == fds_before_nr, "noresult_fd_stable");
    /* recovery: with the descriptors restored the call works again and
     * returns its own removable name */
    int st_nr2 = call_tmpname(L);
    check(st_nr2 == LUA_OK, "noresult_recovered");
    if (st_nr2 == LUA_OK) {
        check(remove(lua_tostring(L, -1)) == 0, "noresult_own_name_removed");
        lua_pop(L, 1);
    }
    /* the same side effect through the BYTECODE path: a chunk whose
     * statement discards the result (OP_CALL nresults=0) must still
     * attempt the create — under the exhausted descriptor table the
     * chunk raises the same catchable error instead of succeeding. */
    int fds_before_nc = count_fds();
    struct rlimit rl_nc;
    int nfill_nc = exhaust_fds(&rl_nc);
    check(nfill_nc >= 0, "noresult_chunk_fds_exhausted");
    int st_nc = luaL_dostring(L, "os.tmpname()");
    int raised_c = (st_nc != LUA_OK);
    const char *body_c = NULL;
    if (st_nc != LUA_OK) {
        body_c = lua_tostring(L, -1);
        lua_pop(L, 1);
    }
    restore_fds(&rl_nc, nfill_nc);
    check(raised_c, "noresult_chunk_error_raised");
    check(body_c != NULL && strstr(body_c, "unable to generate a unique filename") != NULL,
          "noresult_chunk_error_body");
    check(count_fds() == fds_before_nc, "noresult_chunk_fd_stable");

    /* math isolation: the sequence is not disturbed, the RanState upvalue
     * of math.random stays a userdata */
    lua_getglobal(L, "math");
    lua_getfield(L, -1, "randomseed");
    lua_pushinteger(L, 42); lua_pushinteger(L, 7);
    lua_call(L, 2, 0);
    if (call_tmpname(L) == LUA_OK) { remove(lua_tostring(L, -1)); lua_pop(L, 1); }
    lua_getfield(L, -1, "random");
    lua_pushinteger(L, 100);
    lua_call(L, 1, 1);
    check(lua_tointeger(L, -1) == 49, "math_seq_isolated");
    lua_pop(L, 1);
    lua_getfield(L, -1, "random");
    const char *un = lua_getupvalue(L, -1, 1);
    check(un != NULL && lua_type(L, -1) == LUA_TUSERDATA, "math_ranstate_intact");
    lua_settop(L, 0);

    /* forced create failure with the result wanted: the call must raise
     * a catchable error carrying the PUC message body, leak no
     * descriptor, and the state must recover once the limit is restored. */
    int fds_before_hf = count_fds();
    struct rlimit rl_hf;
    int nfill_hf = exhaust_fds(&rl_hf);
    check(nfill_hf >= 0, "hardfail_fds_exhausted");
    int st = call_tmpname(L);
    int catchable = (st == LUA_ERRRUN);
    const char *body = NULL;
    if (st != LUA_OK) {
        body = lua_tostring(L, -1);
        lua_pop(L, 1);
    }
    restore_fds(&rl_hf, nfill_hf);
    check(catchable, "hardfail_catchable");
    check(body != NULL && strstr(body, "unable to generate a unique filename") != NULL,
          "hardfail_msg_body");
    check(count_fds() == fds_before_hf, "hardfail_fd_stable");
    int st2 = call_tmpname(L);
    check(st2 == LUA_OK, "hardfail_recovered");
    if (st2 == LUA_OK) { remove(lua_tostring(L, -1)); lua_pop(L, 1); }

    lua_close(L);
    lua_close(L2);

    /* allocation-failure edges (fresh state per trial) */
    for (int k = 1; k <= 6; k++) oom_trial(k);

    printf("fails:%d\n", fails);
    return fails ? 1 : 0;
}
