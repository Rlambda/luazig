# luazig

`luazig` is a reimplementation of [Lua 5.5.0](https://www.lua.org/versions.html#5.5) in [Zig](https://ziglang.org/), continuously validated against the PUC Lua reference implementation.

The goal is not to write a similar language, but to gradually achieve drop-in compatibility with PUC Lua: the same observable behavior on the official test suite, honest limitations, clean architecture, and a public Zig-facing embedding API.

## Project Goals

- Implement Lua 5.5.0 in Zig with behavior as close as possible to PUC Lua.
- Pass the official upstream `testes/*.lua` suite without test-specific hacks or harness workarounds.
- Keep the reference implementation close at hand and compare `ref` vs `zig` directly.
- Develop a public Zig embedding API semantically close to the Lua C API.
- Use the current system Zig as the primary toolchain.
- Follow a PUC-first architectural approach when it does not lead to a clearly worse solution.

## Current Status

The project is in a **pre-release / parity-focused** state.

### Parity

| Metric | Result |
|--------|--------|
| Upstream matrix (`testes/*.lua`) | **30/31** pass (exit code parity) |
| Differential output (`--diff` mode) | **0 output_diff** — all behavioral differences resolved |
| Smoke tests (`tests/smoke/*.lua`) | **49/49** pass |
| `big.lua` | `both_fail` — pre-existing (expects `coroutine.wrap` harness in `all.lua`) |

Matrix is run with `_port=true; _soft=true` prelude (disables non-portable OS/shell/locale checks and resource-heavy branches).

### Performance

Geomean slowdown vs PUC Lua: **2.76x** (lower is better; 1.0x = parity).

| Workload | Zig/PUC |
|----------|--------:|
| string_concat | 1.56x |
| dynamic_load | 1.65x |
| comparisons | 1.75x |
| float_arith | 2.36x |
| int_arith | 2.61x |
| global_arith | 2.65x |
| branch_loop | 2.50x |
| field_access | 2.80x |
| temp_table_alloc | 2.96x |
| string_loop | 3.18x |
| mixed_arith | 3.26x |
| metamethod_add | 3.39x |
| lua_calls | 3.65x |
| coroutine_yield | 3.69x |
| array_access | 3.79x |
| hash_access | 4.15x |

See [STATUS.md](STATUS.md) for detailed profiling methodology, hotspot analysis, and optimization history.

### Backend

The **bytecode VM** (`--vm=bc`, default) is the only actively developed backend. The IR VM has been fully removed from the codebase.

## Requirements

- `zig` from system toolchain.
- C toolchain for reference Lua: `make`, `gcc` or compatible compiler.
- Initialized upstream test suite submodule.

On Arch Linux:

```sh
sudo pacman -S --needed zig gcc make
```

Verify Zig:

```sh
zig version
```

Initialize submodule:

```sh
git submodule update --init --recursive
```

## Quick Start

Build the reference Lua in C:

```sh
make lua-c
./build/lua-c/lua -v
```

Build the Zig implementation:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/luazig --help
./zig-out/bin/luazigc --help
```

Run the full release gate:

```sh
tools/release_gate.sh
```

## Binaries

Reference implementation:

- `./build/lua-c/lua`
- `./build/lua-c/luac`

Zig implementation:

- `./zig-out/bin/luazig`
- `./zig-out/bin/luazigc`

## Project Structure

```
src/bin/       CLI entrypoints: luazig, luazigc
src/lua/       Language implementation: lexer, parser, AST, codegen, VM, stdlib, API
src/util/      Utility wrappers, including Zig std.Io stdio layer
lua-5.5.0/     Vendored PUC Lua 5.5.0: src/ (reference C) and testes/ (upstream test corpus)
tools/         Differential runners, release gate, perf tooling
tools/perf/    Core perf baselines and current snapshots
```

Runtime path:

- `src/lua/lexer.zig` — reads source bytes, produces tokens.
- `src/lua/parser.zig` — builds AST.
- `src/lua/codegen_bc.zig` — compiles AST to bytecode (`Proto`).
- `src/lua/vm.zig:runBytecode()` — executes bytecode on a shared stack.
- `src/lua/api.zig` — public Zig-facing API and testC compatibility layer.
- `src/lua/c_api.zig` — C ABI (`lua_*` functions) for dlopen-based C extension loading.
- `src/lua/dump.zig` / `src/lua/undump.zig` — binary chunk serialization (`string.dump` / load).

## Testing

The test strategy is based on **differential testing**: the same upstream Lua test is run on both PUC Lua and luazig, then exit code and output are compared.

### Main test lanes

| Tool | Purpose |
|------|---------|
| `tools/run_tests.py` | Targeted differential runner for specific suites |
| `tools/testes_matrix.py` | Per-file matrix over `lua-5.5.0/testes/*.lua` |
| `tools/testes_matrix.py --diff` | Adds normalized stdout comparison (detects behavioral differences even when exit codes match) |
| `tools/smoke_compare.py` | Runs `tests/smoke/*.lua` with both engines, compares stdout+stderr+exit byte-for-byte |
| `tools/api_regression_lane.py` | Zig unit/integration tests + testC lane |
| `tools/perf_compare.py` | Main perf gate: 16 micro-benchmarks, geomean Zig/PUC ratio, regression check |
| `tools/release_gate.sh` | Unified command for checking release readiness |

### Common commands

Run the full safe matrix:

```sh
python3 tools/testes_matrix.py --no-build --timeout 120
```

Run the matrix with differential output comparison:

```sh
python3 tools/testes_matrix.py --diff
```

Run smoke tests:

```sh
python3 tools/smoke_compare.py
```

Run the perf gate:

```sh
python3 tools/perf_compare.py              # run + compare vs baseline
python3 tools/perf_compare.py --no-build   # skip rebuild
python3 tools/perf_compare.py --update-baseline  # rewrite baseline
```

### Interpreting results

The matrix runs upstream tests with the prelude `_port=true; _soft=true`:

- `_port=true` disables non-portable OS/shell/locale/filesystem checks.
- `_soft=true` disables or shortens resource-heavy branches.
- `big.lua` in this mode returns early (`if _soft then return 'a' end`); standalone execution without `_soft` requires a `coroutine.wrap` harness (as in `all.lua`).

## Release Gate

The main command for checking the current state:

```sh
tools/release_gate.sh
```

It runs:

- `zig build test -Doptimize=Debug`
- Official `testC` lane
- Targeted parity suites
- Iterative dispatch stress under 1-MB host stack
- Full safe matrix
- Core perf snapshot + perf guard

Expected result: green on all correctness lanes (build/unit, testC, differential smoke, iterative-dispatch stress, and upstream matrix).

## Detailed Status

For development history, architectural decisions, detailed performance analysis, GC design, and the full work log, see [STATUS.md](STATUS.md).

## License

Same license as PUC Lua (MIT).
