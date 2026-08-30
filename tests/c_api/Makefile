LUA_DIR = ../../src/lua
LIB_DIR = ../../zig-out/lib
PUC_DIR = ../../lua-5.5.0/src

CC = gcc
CFLAGS = -I$(LUA_DIR) -Wall -Wextra
LDFLAGS = -L$(LIB_DIR) -llua -lm -ldl -Wl,-rpath,$(abspath $(LIB_DIR))
PUC_LDFLAGS = -L$(PUC_DIR) -llua -lm -ldl -Wl,-rpath,$(abspath $(PUC_DIR))

TESTS = 00_smoke 01_core 02_tables 03_arith 04_misc 05_auxlib 06_buffer 07_libs 08_debug 09_upvalues 10_continuations 11_closethread 12_chook 13_p15_completion 15_stress_leak 14_state_handles 16_apicheck 17_gccontrol 18_dump

all: $(TESTS)

%: %.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

# Dual-runtime differential test: compile against PUC Lua
%-puc: %.c
	$(CC) -I$(PUC_DIR) -Wall -Wextra -o $@ $< $(PUC_LDFLAGS)

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
    18_dump

# 16_apicheck is intentionally ZIG-ONLY (runs in `make test`, excluded from
# DIFF_TESTS): its invalid-call tests assert the api_check violations raise
# LUA_ERRRUN — release PUC compiles api_check out, so the same programs run
# without errors there. No byte-identical differential is possible; see the
# suite header and STATUS.md P15.83m.

test-diff: $(DIFF_TESTS) $(DIFF_TESTS:%=%-puc)
	@set -e; \
	for t in $(DIFF_TESTS); do \
		echo "=== $$t ==="; \
		./$$t-puc > /tmp/$$t-puc.txt 2>&1; \
		./$$t > /tmp/$$t-luazig.txt 2>&1; \
		diff -u /tmp/$$t-puc.txt /tmp/$$t-luazig.txt; \
	done; \
	echo "DIFF: PASS"

clean:
	rm -f $(TESTS) $(TESTS:%=%-puc)

.PHONY: all test test-diff clean
