LUA_DIR = ../../src/lua
LIB_DIR = ../../zig-out/lib

CC = gcc
CFLAGS = -I$(LUA_DIR) -Wall -Wextra
LDFLAGS = -L$(LIB_DIR) -llua -lm -ldl -Wl,-rpath,$(abspath $(LIB_DIR))

TESTS = 00_smoke 01_core 02_tables 03_arith 04_misc 05_auxlib 06_buffer 07_libs 08_debug 09_upvalues

all: $(TESTS)

%: %.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

test: $(TESTS)
	@for t in $(TESTS); do ./$$t || exit 1; done

clean:
	rm -f $(TESTS)

.PHONY: all test clean
