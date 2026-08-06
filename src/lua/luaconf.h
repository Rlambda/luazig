/*
** luaconf.h — build configuration header for luazig.
**
** This header mirrors the subset of PUC Lua 5.5's luaconf.h that luazig
** needs. It is included by lua.h and provides build-time configuration
** macros (stack limits, buffer sizes, path defaults, numeric type
** configuration, etc.) that must be visible to both the Lua runtime and
** C extension libraries compiled against the luazig headers.
**
** Values match PUC Lua 5.5's default 64-bit Linux configuration
** (LUA_INT_LONGLONG + LUA_FLOAT_DOUBLE). luazig always uses this
** configuration — the conditional compilation blocks from PUC's
** luaconf.h (for 32-bit, C89, Windows, etc.) are omitted because
** luazig targets 64-bit Linux with a C99-capable compiler.
*/
#ifndef luaconf_h
#define luaconf_h

#include <limits.h>
#include <stddef.h>


/* ===================================================================
** System Configuration
** ===================================================================
**
** luazig targets 64-bit Linux. LUA_USE_DLOPEN enables dynamic loading
** of C extension libraries (.so) via dlopen, matching PUC Lua's
** LUA_USE_LINUX configuration.
*/

#define LUA_USE_DLOPEN


/* ===================================================================
** Numeric Type Configuration
**
** luazig always uses 64-bit integers (long long) and double-precision
** floats, matching PUC Lua 5.5's default (LUA_INT_LONGLONG +
** LUA_FLOAT_DOUBLE). The conditional compilation blocks from PUC's
** luaconf.h are omitted because luazig does not support alternative
** numeric configurations.
** ===================================================================
*/

/* LUA_NUMBER is the floating-point type used by Lua. */
#define LUA_NUMBER	double

/* LUAI_UACNUMBER is the result of default argument promotion over a
** floating-point value. For double, the promoted type is still double. */
#define LUAI_UACNUMBER	double

/* l_mathop(op) passes through the math operation unchanged for double
** (no 'f' or 'l' suffix needed). l_floor takes the floor of a float. */
#define l_mathop(op)		op
#define l_floor(x)		(l_mathop(floor)(x))

/* lua_str2number converts a decimal numeral string to a number. */
#define lua_str2number(s,p)	strtod((s), (p))


/* LUA_INTEGER is the integer type used by Lua. */
#define LUA_INTEGER	long long

/* LUAI_UACINT is the result of default argument promotion over a
** LUA_INTEGER value. For long long, the promoted type is still
** long long. */
#define LUAI_UACINT		LUA_INTEGER

/* LUA_UNSIGNED is the unsigned counterpart of LUA_INTEGER. */
#define LUA_UNSIGNED		unsigned LUAI_UACINT

/* Integer format string and limits. */
#define LUA_INTEGER_FRMLEN	"ll"
#define LUA_INTEGER_FMT		"%" LUA_INTEGER_FRMLEN "d"
#define LUA_MAXINTEGER		LLONG_MAX
#define LUA_MININTEGER		LLONG_MIN
#define LUA_MAXUNSIGNED		ULLONG_MAX

/* lua_integer2str converts an integer to a string. */
#define lua_integer2str(s,sz,n)  \
	l_sprintf((s), sz, LUA_INTEGER_FMT, (LUAI_UACINT)(n))


/* ===================================================================
** C99 Dependencies
**
** luazig requires a C99-capable compiler, so we always use the C99
** code paths (snprintf, strtod hex conversion, etc.).
** ===================================================================
*/

/* l_sprintf is equivalent to snprintf (C99). */
#define l_sprintf(s,sz,f,i)	snprintf(s,sz,f,i)

/* lua_strx2number converts a hexadecimal numeral to a number (C99
** strtod handles this). */
#define lua_strx2number(s,p)	lua_str2number(s,p)

/* lua_pointer2str converts a pointer to a readable string. */
#define lua_pointer2str(buff,sz,p)	l_sprintf(buff,sz,"%p",p)

/* lua_number2strx converts a float to a hexadecimal numeral (C99
** '%a'/'%A' format specifiers). */
#define lua_number2strx(L,b,sz,f,n)  \
	((void)L, l_sprintf(b,sz,f,(LUAI_UACNUMBER)(n)))


/* ===================================================================
** Non-return type
**
** l_noret marks functions that never return (like luaL_error). On
** GCC/Clang it uses __attribute__((noreturn)); on MSVC __declspec.
** ===================================================================
*/

#if !defined(l_noret)

#if defined(__GNUC__)
#define l_noret		void __attribute__((noreturn))
#elif defined(_MSC_VER) && _MSC_VER >= 1200
#define l_noret		void __declspec(noreturn)
#else
#define l_noret		void
#endif

#endif


/* ===================================================================
** API consistency check
**
** luai_apicheck is a no-op by default. Define LUA_USE_APICHECK to
** enable consistency checks on the C API (useful for debugging).
** ===================================================================
*/

#if defined(LUA_USE_APICHECK)
#include <assert.h>
#define luai_apicheck(L,op)	assert(op)
#else
#define luai_apicheck(L,op)	((void)0)
#endif


/* ===================================================================
** Configuration for Paths
**
** These macros define how Lua searches for Lua libraries (.lua) and
** C libraries (.so). Values match PUC Lua 5.5's Linux defaults.
** ===================================================================
*/

/* LUA_PATH_SEP separates templates in a path. */
/* LUA_PATH_MARK marks substitution points in a template. */
/* LUA_EXEC_DIR is replaced by the executable's directory (Windows). */
#define LUA_PATH_SEP		";"
#define LUA_PATH_MARK		"?"
#define LUA_EXEC_DIR		"!"

/* LUA_VDIR is the version-specific subdirectory name. */
#define LUA_VDIR	LUA_VERSION_MAJOR "." LUA_VERSION_MINOR

/* Linux path defaults (PUC Lua 5.5 luaconf.h:242-256). */
#define LUA_ROOT	"/usr/local/"
#define LUA_LDIR	LUA_ROOT "share/lua/" LUA_VDIR "/"
#define LUA_CDIR	LUA_ROOT "lib/lua/" LUA_VDIR "/"

#if !defined(LUA_PATH_DEFAULT)
#define LUA_PATH_DEFAULT  \
		LUA_LDIR"?.lua;"  LUA_LDIR"?/init.lua;" \
		LUA_CDIR"?.lua;"  LUA_CDIR"?/init.lua;" \
		"./?.lua;" "./?/init.lua"
#endif

#if !defined(LUA_CPATH_DEFAULT)
#define LUA_CPATH_DEFAULT \
		LUA_CDIR"?.so;" LUA_CDIR"loadall.so;" "./?.so"
#endif

/* LUA_DIRSEP is the directory separator for submodules. */
#if !defined(LUA_DIRSEP)
#define LUA_DIRSEP	"/"
#endif


/* ===================================================================
** Error message helpers
**
** LUA_QL(x) wraps a string in single quotes for error messages.
** LUA_QS is a shorthand for quoting a %s argument.
** ===================================================================
*/

#define LUA_QL(x)	"'" x "'"
#define LUA_QS		LUA_QL("%s")


/* ===================================================================
** Stack and call limits
** ===================================================================
*/

/* LUAI_MAXSTACK limits the size of the Lua stack. PUC Lua 5.5 uses
** 1000000 for 64-bit systems (ldo.c:192). This is also referenced by
** LUA_REGISTRYINDEX in lua.h. */
#define LUAI_MAXSTACK		1000000

/* LUAI_MAXCCALLS limits the number of nested C calls (PUC ldo.h:63).
** Prevents stack overflow from infinite C recursion. */
#define LUAI_MAXCCALLS		200


/* ===================================================================
** Macros that affect the API and must be stable
**
** These macros must be the same when compiling Lua and when compiling
** code that links to Lua (C extensions).
** ===================================================================
*/

/* LUA_EXTRASPACE defines a raw memory area associated with a Lua state
** for very fast access (lua_getextraspace). */
#define LUA_EXTRASPACE		(sizeof(void *))

/* LUA_IDSIZE gives the maximum size for source descriptions in debug
** information (lua_Debug.short_src). */
#define LUA_IDSIZE	60

/* LUAL_BUFFERSIZE is the initial buffer size used by the lauxlib
** buffer system (luaL_Buffer). Computed as in PUC Lua 5.5. */
#define LUAL_BUFFERSIZE   ((int)(16 * sizeof(void*) * sizeof(lua_Number)))

/* LUAI_MAXALIGN ensures maximum alignment for union fields. */
#define LUAI_MAXALIGN  lua_Number n; double u; void *s; lua_Integer i; long l


/* ===================================================================
** Locale decimal point
** ===================================================================
*/

#define lua_getlocaledecpoint()		(localeconv()->decimal_point[0])


/* ===================================================================
** Jump prediction macros (used for error handling and debug)
** ===================================================================
*/

#if !defined(luai_likely)

#if defined(__GNUC__) && !defined(LUA_NOBUILTIN)
#define luai_likely(x)		(__builtin_expect(((x) != 0), 1))
#define luai_unlikely(x)	(__builtin_expect(((x) != 0), 0))
#else
#define luai_likely(x)		(x)
#define luai_unlikely(x)	(x)
#endif

#endif


#endif /* luaconf_h */
