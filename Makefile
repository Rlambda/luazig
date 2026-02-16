ZIG ?= ./tools/zig

LUA_DIR := lua-5.5.0
LUA_SRC := $(LUA_DIR)/src

LUA_C_OUT := build/lua-c
LUA_BIN := $(LUA_C_OUT)/lua
LUAC_BIN := $(LUA_C_OUT)/luac

.PHONY: all lua-c run-lua-c zig run-zig run-zigc fmt test test-suite test-smoke test-compile test-compile-upstream test-guard test-errors-probe tokens parse ast ir clean
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
	@$(ZIG) build

run-zig:
	@$(ZIG) build run

run-zigc:
	@$(ZIG) build -Doptimize=Debug && ./zig-out/bin/luazigc

fmt:
	@$(ZIG) fmt build.zig src

test:
	@$(ZIG) build test

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

test-compile: lua-c zig
	@python3 tools/compile_compare.py --list tests/compile_list.txt

test-compile-upstream: lua-c zig
	@python3 tools/compile_compare.py --dir third_party/lua-upstream/testes --glob '*.lua'

test-guard: zig
	@python3 tools/regression_guard.py --no-build

test-errors-probe: lua-c zig
	@python3 tools/errors_probe.py

tokens: zig
	@test -n "$(FILE)"
	@./zig-out/bin/luazigc --engine=zig --tokens "$(FILE)"

parse: zig
	@test -n "$(FILE)"
	@./zig-out/bin/luazigc --engine=zig -p "$(FILE)"

ast: zig
	@test -n "$(FILE)"
	@./zig-out/bin/luazigc --engine=zig --ast "$(FILE)"

ir: zig
	@test -n "$(FILE)"
	@./zig-out/bin/luazigc --engine=zig --ir "$(FILE)"

clean:
	@rm -rf zig-cache zig-out build
