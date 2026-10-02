LUA_DIR = ../../src/lua
LIB_DIR = ../../zig-out/lib
PUC_DIR = ../../lua-5.5.0/src

CC = gcc
CFLAGS = -I$(LUA_DIR) -Wall -Wextra
LDFLAGS = -L$(LIB_DIR) -llua -lm -ldl -Wl,-rpath,$(abspath $(LIB_DIR))
PUC_LDFLAGS = -L$(PUC_DIR) -llua -lm -ldl -Wl,-rpath,$(abspath $(PUC_DIR))

TESTS = 00_smoke 01_core 02_tables 03_arith 04_misc 05_auxlib 06_buffer 07_libs 08_debug 09_upvalues 10_continuations 11_closethread 12_chook 13_p15_completion 15_stress_leak 14_state_handles 16_apicheck 17_gccontrol 18_dump 19_load 20_ccall_depth 22_tbc_lifecycle 23_tbc_semantics 24_tbc_alias 25_tbc_closer_escape 26_tbc_forced_close_cbody 27_finalizer_owners 28_finalizer_warn_oom 29_finalizer_oom_queue 30_registry_owner 31_env_capture 32_index_resolver 33_getset_resolver 34_writable_resolver 35_lauxlib_argerror 36_ccmt_abi 37_pcallk_recovery 38_pcallk_cbody_recovery 39_resume_error_window

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
    39_resume_error_window

# 16_apicheck is intentionally ZIG-ONLY (runs in `make test`, excluded from
# DIFF_TESTS): its invalid-call tests assert the api_check violations raise
# LUA_ERRRUN — release PUC compiles api_check out, so the same programs run
# without errors there. No byte-identical differential is possible; see the
# suite header and STATUS.md P15.83m.

XREAD_TESTS = 36_ccmt_abi

test-diff: $(DIFF_TESTS) $(DIFF_TESTS:%=%-puc) $(XREAD_TESTS:%=%-xread)
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
	echo "DIFF: PASS"

clean:
	rm -f $(TESTS) $(TESTS:%=%-puc) $(XREAD_TESTS:%=%-xread)

.PHONY: all test test-diff clean
