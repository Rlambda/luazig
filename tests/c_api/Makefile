LUA_DIR = ../../src/lua
LIB_DIR = ../../zig-out/lib
PUC_DIR = ../../lua-5.5.0/src

CC = gcc
CFLAGS = -I$(LUA_DIR) -Wall -Wextra
LDFLAGS = -L$(LIB_DIR) -llua -lm -ldl -Wl,-rpath,$(abspath $(LIB_DIR))
PUC_LDFLAGS = -L$(PUC_DIR) -llua -lm -ldl -Wl,-rpath,$(abspath $(PUC_DIR))

TESTS = 00_smoke 01_core 02_tables 03_arith 04_misc 05_auxlib 06_buffer 07_libs 08_debug 09_upvalues 10_continuations 11_closethread 12_chook 13_p15_completion 15_stress_leak 14_state_handles 16_apicheck 17_gccontrol 18_dump 19_load 20_ccall_depth 22_tbc_lifecycle 23_tbc_semantics 24_tbc_alias 25_tbc_closer_escape 26_tbc_forced_close_cbody 27_finalizer_owners 28_finalizer_warn_oom 29_finalizer_oom_queue 30_registry_owner 31_env_capture 32_index_resolver 33_getset_resolver 34_writable_resolver 35_lauxlib_argerror 36_ccmt_abi 37_pcallk_recovery 38_pcallk_cbody_recovery 39_resume_error_window 40_maindestined_transport 40_package_openf 41_light_pub 42_getinfo_fn 43_yield_park_window 44_raw_yield_boundary 45_utf8_light 46_light_sweep 47_light_yield 48_math_ranstate 49_math_open_oom 50_os_tmpname

all: $(TESTS)

%: %.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

# Dual-runtime differential test: compile against PUC Lua
%-puc: %.c
	$(CC) -I$(PUC_DIR) -Wall -Wextra -o $@ $< $(PUC_LDFLAGS)

# Cross-read ABI lane: compile the client against the PUC header but link
# the luazig library — the published lua_Debug layout must let a
# PUC-header client read every public field from the luazig runtime.
%-xread: %.c
	$(CC) -I$(PUC_DIR) -Wall -Wextra -o $@ $< $(LDFLAGS)

# POSIX-configured PUC oracle: os.tmpname's PUC contract (mkstemp: the file
# is created atomically, mode 0600, fd closed) is only compiled in under
# LUA_USE_POSIX. The in-tree liblua.so may be built without it (tmpnam, no
# file), so POSIX-dependent suites link this private build instead.
PUCPOSIX_DIR = ../../build/pucposix
PUC_CORE_O = lapi.o lcode.o lctype.o ldebug.o ldo.o ldump.o lfunc.o lgc.o llex.o lmem.o lobject.o lopcodes.o lparser.o lstate.o lstring.o ltable.o ltm.o lundump.o lvm.o lzio.o
PUC_LIB_O = lauxlib.o lbaselib.o lcorolib.o ldblib.o liolib.o lmathlib.o loadlib.o loslib.o lstrlib.o ltablib.o lutf8lib.o linit.o

$(PUCPOSIX_DIR)/liblua.so: $(addprefix $(PUCPOSIX_DIR)/,$(PUC_CORE_O) $(PUC_LIB_O))
	$(CC) -shared -o $@ $^ -lm

$(PUCPOSIX_DIR)/%.o: $(PUC_DIR)/%.c
	@mkdir -p $(PUCPOSIX_DIR)
	$(CC) -O2 -Wall -fPIC -DLUA_USE_POSIX -I$(PUC_DIR) -c -o $@ $<

%-pucposix: %.c $(PUCPOSIX_DIR)/liblua.so
	$(CC) -I$(PUC_DIR) -Wall -Wextra -o $@ $< -L$(PUCPOSIX_DIR) -llua -lm -ldl -Wl,-rpath,$(abspath $(PUCPOSIX_DIR))

test: $(TESTS)
	@for t in $(TESTS); do ./$$t || exit 1; done

# Differential gate: suites that must behave identically on both runtimes.
# A mismatch FAILS the target (diff non-zero exit aborts under set -e).
DIFF_TESTS = \
    10_continuations \
    11_closethread \
    12_chook \
    13_p15_completion \
    14_state_handles \
    15_stress_leak \
    17_gccontrol \
    18_dump \
    19_load \
    22_tbc_lifecycle \
    23_tbc_semantics \
    24_tbc_alias \
    25_tbc_closer_escape \
    26_tbc_forced_close_cbody \
    27_finalizer_owners \
    28_finalizer_warn_oom \
    29_finalizer_oom_queue \
    30_registry_owner \
    31_env_capture \
    32_index_resolver \
    33_getset_resolver \
    34_writable_resolver \
    35_lauxlib_argerror \
    36_ccmt_abi \
    37_pcallk_recovery \
    38_pcallk_cbody_recovery \
    39_resume_error_window \
    40_maindestined_transport \
    40_package_openf \
    41_light_pub \
    42_getinfo_fn \
    43_yield_park_window \
    44_raw_yield_boundary \
    45_utf8_light \
    46_light_sweep \
    47_light_yield \
    48_math_ranstate \
    49_math_open_oom

# 16_apicheck is intentionally ZIG-ONLY (runs in `make test`, excluded from
# DIFF_TESTS): its invalid-call tests assert the api_check violations raise
# LUA_ERRRUN — release PUC compiles api_check out, so the same programs run
# without errors there. No byte-identical differential is possible; see the
# suite header and STATUS.md P15.83m.

# 50_os_tmpname is differential against the POSIX-configured PUC oracle
# (see the %-pucposix rule), not the default in-tree liblua.so.
POSIX_DIFF_TESTS = 50_os_tmpname

XREAD_TESTS = 36_ccmt_abi

test-diff: $(DIFF_TESTS) $(DIFF_TESTS:%=%-puc) $(XREAD_TESTS:%=%-xread) $(POSIX_DIFF_TESTS) $(POSIX_DIFF_TESTS:%=%-pucposix)
	@set -e; \
	for t in $(DIFF_TESTS); do \
		echo "=== $$t ==="; \
		./$$t-puc > /tmp/$$t-puc.txt 2>&1; \
		./$$t > /tmp/$$t-luazig.txt 2>&1; \
		diff -u /tmp/$$t-puc.txt /tmp/$$t-luazig.txt; \
	done; \
	for t in $(XREAD_TESTS); do \
		echo "=== $$t-xread ==="; \
		./$$t-xread > /tmp/$$t-xread.txt 2>&1; \
		diff -u /tmp/$$t-puc.txt /tmp/$$t-xread.txt; \
	done; \
	for t in $(POSIX_DIFF_TESTS); do \
		echo "=== $$t (posix puc) ==="; \
		./$$t-pucposix > /tmp/$$t-pucposix.txt 2>&1; \
		./$$t > /tmp/$$t-luazig.txt 2>&1; \
		diff -u /tmp/$$t-pucposix.txt /tmp/$$t-luazig.txt; \
	done; \
	echo "DIFF: PASS"

clean:
	rm -f $(TESTS) $(TESTS:%=%-puc) $(XREAD_TESTS:%=%-xread) $(POSIX_DIFF_TESTS:%=%-pucposix)

.PHONY: all test test-diff clean
