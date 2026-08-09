ZIG ?= ./tools/zig
ZIG_BUILD_FLAGS ?=

LUA_DIR := lua-5.5.0
LUA_SRC := $(LUA_DIR)/src

LUA_C_OUT := build/lua-c
LUA_BIN := $(LUA_C_OUT)/lua
LUAC_BIN := $(LUA_C_OUT)/luac

.PHONY: all lua-c run-lua-c zig run-zig fmt test test-suite test-smoke test-guard test-errors-probe clean
.PHONY: test-suite-zig test-upstream

all: lua-c zig

build:
	@mkdir -p build

lua-c: build
	$(MAKE) -C $(LUA_SRC) linux
	@mkdir -p $(LUA_C_OUT)
	@cp -f $(LUA_SRC)/lua $(LUA_BIN)
	@cp -f $(LUA_SRC)/luac $(LUAC_BIN)

run-lua-c: lua-c
	@$(LUA_BIN)

zig:
	@$(ZIG) build $(ZIG_BUILD_FLAGS)

run-zig:
	@$(ZIG) build $(ZIG_BUILD_FLAGS) run

fmt:
	@$(ZIG) fmt build.zig src

test:
	@$(ZIG) build $(ZIG_BUILD_FLAGS) test

test-suite: lua-c zig
	@python3 tools/run_tests.py

# Run upstream suite under our Zig VM and compare output against reference Lua.
test-suite-zig: lua-c zig
	@python3 tools/run_tests.py --mode compare --prelude ""

# Run a single upstream test file (FILE=errors.lua) under Zig VM and compare.
test-upstream: lua-c zig
	@test -n "$(FILE)"
	@python3 tools/run_tests.py --mode compare --prelude "" --suite "$(FILE)"

test-smoke: lua-c zig
	@python3 tools/smoke_compare.py --no-build

test-guard: zig
	@python3 tools/regression_guard.py --no-build

test-errors-probe: lua-c zig
	@python3 tools/errors_probe.py

clean:
	@rm -rf zig-cache zig-out build
