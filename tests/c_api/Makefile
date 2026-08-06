LUA_DIR = ../../src/lua
LIB_DIR = ../../zig-out/lib

CC = gcc
CFLAGS = -I$(LUA_DIR) -Wall -Wextra
LDFLAGS = -L$(LIB_DIR) -llua -lm -ldl -Wl,-rpath,$(abspath $(LIB_DIR))

TESTS = 00_smoke 01_core

all: $(TESTS)

%: %.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

test: $(TESTS)
	@for t in $(TESTS); do ./$$t || exit 1; done

clean:
	rm -f $(TESTS)

.PHONY: all test clean
