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

<!-- BEGIN GENERATED STATUS (tools/status_summary.py) -->
### Parity

| Metric | Result |
|--------|--------|
| Upstream matrix (`testes/*.lua`, `--testc`) | **30/32** pass (exit code parity) |
| Matrix non-pass | both_fail: big.lua; zig_fail: api.lua |
| Smoke tests (`tests/smoke/*.lua`) | **67/67** match (byte-identical stdout+stderr+exit) |
| C API suites (`tests/c_api`) | 20 suites (gate: `make -C tests/c_api test`) |

Regression lane: `python3 tools/testes_matrix.py --testc` (no `_port`/`_soft` prelude overrides).

### Performance

Geomean slowdown vs PUC Lua: **1.79x** (lower is better; 1.0x = parity).
Method: median-of-5 per workload, pinned CPU core (`tools/perf_compare.py`).

| Workload | Zig/PUC |
|----------|--------:|
| metamethod_call_noalloc | 2.74x |
| metamethod_add | 2.59x |
| coroutine_yield | 2.17x |
| lua_calls | 2.16x |
| hash_access | 2.11x |
| table_alloc_setmetatable | 2.10x |
| field_access | 1.99x |
| array_access | 1.94x |
| branch_loop | 1.92x |
| temp_table_alloc | 1.69x |
| mixed_arith | 1.63x |
| dynamic_load | 1.58x |
| comparisons | 1.57x |
| float_arith | 1.53x |
| global_arith | 1.50x |
| int_arith | 1.49x |
| string_loop | 1.31x |
| string_concat | 1.08x |
<!-- END GENERATED STATUS -->

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

Run the regression matrix lane (the gate used in STATUS/commits; no prelude overrides):

```sh
python3 tools/testes_matrix.py --testc
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

The regression lane (`tools/testes_matrix.py --testc`) runs each upstream test
without any prelude. The `_port`/`_soft` prelude is an opt-in mode (`--port`,
`--soft` flags) used by timing-oriented lanes such as `tools/perf_core_snapshot.py`:

- `_port=true` disables non-portable OS/shell/locale/filesystem checks.
- `_soft=true` disables or shortens resource-heavy branches.
- `big.lua` under `_soft` returns early (`if _soft then return 'a' end`); standalone execution without `_soft` requires a `coroutine.wrap` harness (as in `all.lua`).

The quantitative Parity/Performance block at the top of this README is
generated from lane JSON reports by `tools/status_summary.py --write-readme`
(single source of truth — do not edit those numbers by hand).

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
