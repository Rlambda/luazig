LUA_DIR = ../../src/lua
LIB_DIR = ../../zig-out/lib
PUC_DIR = ../../lua-5.5.0/src

CC = gcc
CFLAGS = -I$(LUA_DIR) -Wall -Wextra
LDFLAGS = -L$(LIB_DIR) -llua -lm -ldl -Wl,-rpath,$(abspath $(LIB_DIR))
PUC_LDFLAGS = -L$(PUC_DIR) -llua -lm -ldl -Wl,-rpath,$(abspath $(PUC_DIR))

TESTS = 00_smoke 01_core 02_tables 03_arith 04_misc 05_auxlib 06_buffer 07_libs 08_debug 09_upvalues 10_continuations

all: $(TESTS)

%: %.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

# Dual-runtime differential test: compile against PUC Lua
%-puc: %.c
	$(CC) -I$(PUC_DIR) -Wall -Wextra -o $@ $< $(PUC_LDFLAGS)

test: $(TESTS)
	@for t in $(TESTS); do ./$$t || exit 1; done

# Differential test: run against both PUC Lua and luazig, compare output
test-diff: 10_continuations 10_continuations-puc
	@echo "=== PUC Lua ===" && ./10_continuations-puc > /tmp/puc_out.txt 2>&1; \
	 echo "=== luazig ===" && ./10_continuations > /tmp/zig_out.txt 2>&1; \
	 diff /tmp/puc_out.txt /tmp/zig_out.txt && echo "DIFF: PASS (identical output)" || echo "DIFF: FAIL (output differs)"

clean:
	rm -f $(TESTS) $(TESTS:%=%-puc)

.PHONY: all test test-diff clean
