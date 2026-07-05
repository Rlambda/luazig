# luazig

Цель репозитория: по шагам переписать Lua на Zig, сохраняя поведение через постоянное сравнение с эталонной сборкой `lua-5.5.0/`.

## Требования

- C toolchain для эталонного Lua: `make`, `gcc` (или совместимый).
- Zig для новой реализации.

На Arch Linux проще всего поставить Zig так:

```sh
sudo pacman -S --needed zig
```

Если не хочется ставить через `sudo`, можно скачать локальный toolchain в репозиторий:

```sh
./tools/fetch-zig.sh 0.15.2
```

Проверка:

```sh
./tools/zig version
```

## Команды (Быстрый Старт)

Проверить окружение:

```sh
./tools/bootstrap.sh
```

Эталонная сборка Lua (C):

```sh
make lua-c
./build/lua-c/lua -v
```

Сборка Zig-части (пока заглушка):

```sh
make zig ZIG_BUILD_FLAGS='-Dtarget=x86_64-linux-gnu.2.39'
./zig-out/bin/luazig --help
```

## Запуск бинарников

- `./build/lua-c/lua` и `./build/lua-c/luac` — эталонная C-реализация (ref).
- `./zig-out/bin/luazig` и `./zig-out/bin/luazigc` — текущая Zig-реализация.

`--engine=ref` больше не поддерживается в `luazig*`.
Для сравнения с эталоном запускайте `lua/luac` напрямую.
`--engine=zig` оставлен как совместимый no-op для старых скриптов.

## Тесты (дифференциально)

Мы используем официальный test suite из upstream Lua как `git submodule`:

```sh
git submodule update --init --recursive
```

Прогон тестов сравнивает поведение эталонного `build/lua-c/lua` и `zig-out/bin/luazig`:

```sh
make test-suite
```

Примечание: в differential-инструментах `ref` всегда запускается напрямую как
`build/lua-c/lua` или `build/lua-c/luac`, а `zig` — через `luazig`/`luazigc`.

Для сборки на Arch/GCC 16 с локальным `tools/zig` используйте Zig-provided glibc target:

```sh
./tools/zig build -Dtarget=x86_64-linux-gnu.2.39 -Doptimize=Debug
```

Это не musl-target: итоговые бинарники остаются Linux/glibc, но сборка не зависит от
system `crt1.o`, который на GCC 16/binutils 2.46 содержит `.sframe` relocation,
не поддерживаемый bundled Zig `0.15.2`.

## Компиляция (сравнение с luac -p)

Можно сравнивать “компилируется/не компилируется” между `luac -p` и `luazigc -p`:

```sh
make test-compile
```

Чтобы прогнать сравнение сразу по всем `.lua` из upstream test suite:

```sh
make test-compile-upstream
```

Полезные команды для отладки лексера:

```sh
make tokens FILE=third_party/lua-upstream/testes/all.lua
make parse  FILE=third_party/lua-upstream/testes/all.lua
```

Пофайловый статус по официальному `testes/*.lua` (паритет `ref` vs `zig`):

```sh
python3 tools/testes_matrix.py --json-out /tmp/testes-matrix.json
```

## Структура

- `lua-5.5.0/`: исходники эталонного Lua (как база для сравнения).
- `src/`: новая реализация на Zig.
- `tools/zig`: обертка, чтобы использовать либо локальный Zig (`tools/zig-bin/zig`), либо системный `zig`.
- `third_party/lua-upstream/`: upstream Lua (submodule) для `testes/`.

## TODO (Статус миграции ref -> zig)

Цель: довести `luazig` до drop-in совместимости с PUC Lua 5.5.0 на официальном `testes`, затем расширять публичный Zig/C-like embedding API.

### Статус

- Базовая differential-инфраструктура работает: ref запускается напрямую через `build/lua-c/lua`, zig — через `zig-out/bin/luazig`.
- Official `testC` lane зелёный: `api.lua`, `coroutine.lua`, `errors.lua`, `strings.lua`, `locals.lua`, `memerr.lua`.
- Публичный API smoke/regression lane зафиксирован: `python3 tools/api_regression_lane.py`.
- Bytecode backend остаётся hybrid: поддержанные инструкции исполняются в `bc_vm`, неподдержанные безопасно откатываются в IR.
- Свежий matrix-срез P8.4: `33/34 pass parity` (`zig_fail=0`, `both_fail=1`, `both_fail_infra=0`, `zig_only_pass=0`). JSON: `tools/reports/testes_matrix_p8_4.json`.
- Core perf baseline обновлён после semantic-fix этапа: `tools/perf/core_baseline.json` (`nextvar.lua`, `coroutine.lua`, `gc.lua`), guard: `tools/perf_guard_core.py`.
- P10 readiness phase закрыт: есть release gate, supported non-musl build path и честный readiness report. Следующий фокус: закрыть оставшиеся blockers до настоящего drop-in статуса (`heavy.lua` OOM/error-object semantics, perf gap, Zig 0.16 port).

### P10: довести проект до release/drop-in readiness

P8/P9 закрыли базовую parity-картину и публичный Zig API. Следующий этап — убрать последние причины, по которым проект нельзя честно назвать готовым drop-in Lua.

- [x] P10.1. Разобрать `heavy.lua` без bounded-time маскировки: определить, это runtime memory boundary, performance issue или некорректная OOM-семантика.
  - Добавлен диагностический probe: `tools/heavy_vmem_probe.sh`.
  - Resource profile: при `LZ_HEAVY_VMEM_KB=131072` ref ловит Lua-level `not enough memory` и завершает `OK` на размере `8388608`; zig завершается `OK`, но печатает `expected error: <no error object>` и размер около `810315`.
  - Вывод: это не просто bounded-time issue. Точный blocker — некорректная OOM/error-object семантика при table growth под memory pressure; дополнительно виден perf gap, потому что при 512M zig за 120s не доходит до OOM там, где ref доходит до `not enough memory`.
  - Следующий фикс должен идти PUC-first через runtime memory boundary/error propagation: allocation failure в `tableSetValue`/array growth должен становиться Lua catchable `not enough memory`, не терять error object.
- [x] P10.2. Вернуть performance focus: `nextvar.lua` должен получить план оптимизации от текущих ~85s к разумному target, с профилем узких мест и PUC-first решением.
  - Профиль: первый hot block из `nextvar.lua` (`2^11-1` строковых ключей + `1e5` alternating insert/delete + `countentries`) занимал около `29.7s` в zig против `0.022s` в ref; string concat-only часть занимала около `0.97s`, значит главный blocker — table set/delete path.
  - PUC-first perf шаг: deferred hash tombstone compaction. Вместо частого full-scan compact после небольших delete bursts, `compactTableHashTombstones` теперь откладывает физическую очистку tombstones до крупного накопления, ближе к PUC Lua rehash/dead-key модели.
  - Результат микробенча: hot block улучшен примерно `29.7s -> 3.8s`; full `nextvar.lua` улучшился умеренно (`~84.6s -> ~82.8s`), значит следующие perf bottlenecks находятся дальше по suite и требуют отдельного профиля.
  - Проверки: `nextvar.lua` parity сохраняется; `tools/perf_guard_core.py` проходит.
- [x] P10.3. Починить host build/toolchain проблему без обязательного `-Dtarget=x86_64-linux-musl`.
  - Критерий: `./tools/zig build -Doptimize=Debug` и `zig build -Doptimize=Debug` имеют понятный supported path или документированное ограничение toolchain/libc.
  - Поддержанный non-musl path для bundled Zig `0.15.2`: `./tools/zig build -Dtarget=x86_64-linux-gnu.2.39 -Doptimize=Debug`.
  - Причина: native `./tools/zig build -Doptimize=Debug` на Arch/GCC 16 падает в linker на `crt1.o:.sframe` (`R_X86_64_PC64`); explicit `x86_64-linux-gnu.2.39` использует Zig-provided glibc и обходит system crt.
  - `zig build -Doptimize=Debug` с system Zig `0.16.0` пока не является supported path: после удаления deprecated `Compile.linkLibC()` остаётся upstream API break (`std.process.argsAlloc` removed). Это отдельная porting-задача, а не libc/toolchain blocker.
  - `Makefile` теперь принимает `ZIG_BUILD_FLAGS`, поэтому быстрый путь: `make zig ZIG_BUILD_FLAGS='-Dtarget=x86_64-linux-gnu.2.39'`.
- [x] P10.4. Ввести release gates: короткий gate, full safe matrix, API lanes, perf guard, known limitations.
  - Критерий: один documented command set отвечает на вопрос “можно ли релизить этот commit?”.
  - Добавлен единый gate: `tools/release_gate.sh`.
  - Gate выполняет: public/API regression lane, targeted parity (`nextvar.lua`, `coroutine.lua`, `calls.lua`, `files.lua`, `locals.lua`, `db.lua`, `gc.lua`), full safe matrix через memory-limited wrapper, core perf snapshot и perf guard.
  - По умолчанию gate использует supported non-musl build target `-Dtarget=x86_64-linux-gnu.2.39`; переопределение: `LUAZIG_ZIG_BUILD_FLAGS='...' tools/release_gate.sh`.
  - Known limitations для интерпретации результата остаются явными: `heavy.lua` OOM/error-object blocker, большой perf gap против PUC Lua, отсутствие support для system Zig `0.16`.
- [x] P10.5. Подготовить readiness report: что уже совместимо с PUC Lua, что не совместимо, что является perf-only, что является unsupported API surface.
  - Критерий: README содержит честный статус готовности без завышения production/drop-in claims.
  - Readiness report добавлен ниже: текущий статус — pre-release / parity-focused, но ещё не production-ready drop-in.

### Readiness Report

Текущий статус: `luazig` находится в pre-release состоянии. Это уже полезная parity-focused реализация Lua 5.5.0 на Zig, но проект ещё нельзя честно назвать production-ready drop-in заменой PUC Lua.

Что уже совместимо или стабилизировано:

- Official safe matrix: `33/34 pass parity`; `zig_fail=0`, единственный ожидаемый `both_fail` — `heavy.lua` timeout в bounded safe lane.
- Targeted parity gate зелёный: `nextvar.lua`, `coroutine.lua`, `calls.lua`, `files.lua`, `locals.lua`, `db.lua`, `gc.lua`.
- Official `testC` lane зелёный: `api.lua`, `coroutine.lua`, `errors.lua`, `strings.lua`, `locals.lua`, `memerr.lua`.
- Coroutine path работает без replay-зависимости для текущих official/testC gates.
- Публичный Zig API отделён от VM internals и имеет regression lane: `python3 tools/api_regression_lane.py`.
- `--engine=ref` удалён из пользовательского workflow; ref запускается напрямую через `build/lua-c/lua`/`luac`.
- Supported build path зафиксирован для bundled Zig `0.15.2`: `./tools/zig build -Dtarget=x86_64-linux-gnu.2.39 -Doptimize=Debug`.
- Release gate зафиксирован одной командой: `tools/release_gate.sh`.

Что пока не совместимо с production/drop-in статусом:

- `heavy.lua` остаётся blocker: под memory pressure zig теряет корректный Lua-level error object (`expected error: <no error object>`) и имеет большой perf gap до момента OOM.
- System Zig `0.16.0` пока unsupported: требуется отдельный porting pass по std/build API (`std.process.argsAlloc` и связанные изменения).
- Bytecode backend остаётся hybrid: часть инструкций исполняется в `bc_vm`, неподдержанные пути безопасно уходят в IR; это корректно для gates, но не финальная VM-архитектура.
- Производительность существенно ниже PUC Lua на известных hot suites: `nextvar.lua`, `coroutine.lua`, `gc.lua`; perf guard сейчас защищает от регрессий, а не доказывает приемлемый production perf.
- C ABI shim остаётся smoke/compat слоем поверх Zig API, а не полной заменой оригинального Lua C API.

Что является perf-only проблемой, если parity не ломается:

- `nextvar.lua`: parity проходит, но время выполнения всё ещё на порядки хуже PUC Lua. Последний PUC-first шаг ускорил hot block через deferred tombstone compaction, но full-suite bottlenecks остаются.
- `coroutine.lua` и `gc.lua`: parity проходит, но timings фиксируют значимый runtime overhead.

Unsupported API surface:

- Полная бинарная совместимость с Lua C API не заявляется. Цель текущего этапа — семантически близкий Zig embedding API и ограниченный C-like shim для тестов.
- System Zig `0.16` теперь является целевым compiler; текущий blocker — незавершённая миграция на новые `std.process`/`std.Io`/`std.fs` API.
- Native `./tools/zig build -Doptimize=Debug` на Arch/GCC 16 не supported из-за system `crt1.o:.sframe`; используйте documented glibc target.

Следующие реальные blockers после P10:

- Исправить PUC-like OOM/error-object propagation в table growth/allocation paths, чтобы `heavy.lua` ловил `not enough memory` как ref.
- Продолжить PUC-first оптимизацию table/string/VM hot paths до приемлемого perf target.
- Завершить porting на актуальный system Zig без libc fallbacks для Zig-facing API.
- Расширить Zig/C-like embedding API после закрытия базовых runtime blockers.

### P11: закрыть blockers до настоящего drop-in статуса

P10 зафиксировал readiness status и release gate. Следующий этап — убрать причины, по которым проект всё ещё pre-release.

- [x] P11.1. Исправить первую часть `heavy.lua` OOM/error-object blocker: allocator OOM внутри `pcall` должен становиться Lua-level `not enough memory`, а не `<no error object>`.
  - Изменение: общий `pcall` path теперь преобразует `error.OutOfMemory` из resolve/call/builtin/closure execution в protected Lua error object через `setOutOfMemoryError()`.
  - Проверка: `LZ_HEAVY_VMEM_KB=131072 LZ_HEAVY_VMEM_TIMEOUT=120 tools/heavy_vmem_probe.sh` проходит для ref и zig; zig выводит `expected error: heavy.lua:151: not enough memory` и `OK`.
  - Это не закрывает весь `heavy.lua`: размер до OOM и perf всё ещё отличаются от PUC Lua.
- [x] P11.2. Сделать первый PUC-first шаг по `heavy.lua` memory/perf behavior: dense table array growth не должен realloc-иться на каждый sequential append.
  - Изменение: CLI runtime использует libc allocator, а dense table array append получил явный amortized growth helper `appendTableArrayValue()` вместо pathological exact-capacity append.
  - Диагностика: добавлен отключённый по умолчанию `LUAZIG_TRACE_OOM=1`, который печатает OOM context без влияния на semantics.
  - Проверка: `LZ_HEAVY_VMEM_KB=131072 LZ_HEAVY_VMEM_TIMEOUT=120 tools/heavy_vmem_probe.sh` проходит; zig size улучшен примерно `810315 -> 1048576`, error object остаётся `not enough memory`.
- [x] P11.3. Классифицировать оставшийся `heavy.lua` memory/perf gap после amortized growth.
  - Добавлен профильный инструмент: `python3 tools/heavy_array_profile.py --limits 131072,196608 --timeout 180`.
  - Результат: при `131072K` ref доходит до `size=8388608`, zig — до `size=1048576`; при `196608K` zig всё ещё останавливается на `1048576`.
  - Вывод: оставшийся blocker не лечится локальным grow-tuning. Текущий `Value` занимает 24 bytes, table array хранит `Value[]`, а grow path требует крупный contiguous allocation. Для дальнейшего сближения нужен архитектурный PUC-like шаг: более компактное TValue/table-array representation и/или allocator strategy, уменьшающая peak contiguous allocation.
- [x] P11.4. Продолжить PUC-first perf оптимизацию `nextvar.lua`: найти следующий hot block после tombstone compaction и снизить full-suite runtime без потери parity.
  - Профиль: real stdout timestamps показали, что основной ранний hotspot остаётся до первого `testC not active` marker; isolated alternate insert/delete block около `3.7s`, а full-suite runtime около `59s`, что указывает на overhead от full-frame runtime/GC root scanning.
  - Изменение: GC root scan теперь маркирует только active frame locals вместо всего preallocated `locals[]`, ближе к PUC Lua active-stack marking.
  - Результат: full `nextvar.lua` улучшился умеренно, примерно `59s -> 58s`; parity сохраняется; `tools/perf_guard_core.py` проходит.
- [x] P11.5. Выполнить Zig `0.16` porting pass: либо добиться build, либо точно классифицировать remaining blockers.
  - Решение по toolchain: дальше таргетим актуальный system Zig (`zig`, сейчас `0.16.0`); совместимость со старым bundled Zig `0.15.2` больше не является обязательной целью.
  - Правило закреплено в `AGENTS.md`: для Zig-facing интерфейсов запрещены libc fallbacks (`fopen`/`fread`/`argv` hacks); нужно использовать штатные Zig API (`std.process.Init`, `std.Io`, `std.Io.Dir`, etc.).
  - Классификация blockers: после `argsAlloc` вскрывается крупный stdlib migration pass — entrypoint на `std.process.Init`, stdout/stderr на `std.Io.File.Writer`, file loading/io на `std.Io.Dir`/`std.Io.File`, `ArrayListUnmanaged = .empty`, новые time/env/fs APIs.
  - Кодовый partial port не закоммичен, чтобы не оставить runtime в несобираемом состоянии; следующий этап должен быть отдельной фазой full Zig 0.16 migration.

### P12: full migration на актуальный system Zig

Цель этапа — сделать `zig build -Doptimize=Debug` на установленном system Zig основным build path. Совместимость со старым bundled Zig больше не является ограничением. Libc fallbacks для Zig-facing API запрещены; миграция должна идти через штатные Zig `std.process.Init`, `std.Io`, `std.Io.Dir`, `std.Io.File` и актуальные collection/time/env APIs.

- [x] P12.1. Убрать первый Zig `0.16` blocker в CLI: заменить `std.process.argsAlloc/argsFree` на `std.process.Init` + `std.process.Args.Iterator` без libc/procfs fallback.
  - Изменение: `luazig` и `luazigc` теперь принимают `std.process.Init`, берут allocator из `init.gpa` и собирают argv через `std.process.Args.Iterator.initAllocator(init.minimal.args, alloc)`.
  - Проверка: latest Zig build проходит дальше прежнего `argsAlloc` blocker и останавливается на следующем настоящем blocker: `src/util/stdio.zig` всё ещё использует удалённый `std.fs.File.Writer`.
- [x] P12.2. Перевести `src/util/stdio.zig` и все stdout/stderr call sites на `std.Io.File.Writer`/`std.process.Init.io` без глобального `std.io` compatibility shim.
  - Изменение: `stdio.Writer` теперь обёрнут вокруг `std.Io.File.Writer`, stdout/stderr создаются через `std.Io.File.stdout/stderr`, а process `Io` передаётся из CLI entrypoints через `stdio.init(init.io)`.
  - Проверка: latest Zig build проходит дальше прежнего `std.fs.File.Writer` blocker. Следующие blockers уже относятся к file runtime: `Source.loadFile` использует удалённый `std.fs.cwd()`, а VM хранит `std.fs.File`.
- [x] P12.3. Перевести file loading/writing (`Source.loadFile`, `bc_coverage_out`, stdlib file paths) с legacy `std.fs.cwd()`/`std.fs.File` на `std.Io.Dir`/`std.Io.File`.
  - Изменение: `Source.loadFile` теперь принимает `std.Io` и читает через `std.Io.Dir.cwd().readFileAlloc`; `bc_coverage_out` пишет через `std.Io.Dir.cwd().writeFile`.
  - Изменение: VM file handles переведены с `std.fs.File` на `std.Io.File`; close/write/remove/rename/access paths начали использовать `std.Io`/`std.Io.Dir`.
  - Проверка: latest Zig build проходит дальше `Source.loadFile`/`std.fs.File` type blockers. Следующий основной blocker — collection migration (`ArrayListUnmanaged = .empty`) и доработка remaining file seek/read helpers на `std.Io.File.Reader/Writer`.
- [x] P12.4. Пройти collection API migration: заменить legacy `ArrayListUnmanaged{}`/writer usage на актуальные `.empty` и новые writer/buffer APIs.
  - Изменение: legacy `ArrayListUnmanaged` empty initializers заменены на `.empty`; runtime buffer formatting переведён с удалённого `array.writer(alloc)` на `std.Io.Writer.Allocating` или explicit `appendFmt`.
  - Проверка: latest Zig build проходит дальше collection/writer blockers; оставшиеся ошибки относятся к P12.5 (`env`, `time`, `std.Io.File` read/seek helpers).
- [x] P12.5. Пройти env/time/fs остатки (`hasEnvVarConstant`, `getEnvVarOwned`, `timestamp`, rename/delete/read APIs) и добиться успешного `zig build -Doptimize=Debug`.
  - Изменение: env lookup переведён на `std.process.Environ`, clock на `std.Io.Timestamp.now(..., .real)`, managed file read/seek paths переведены на `std.Io.File` positional IO с явным `FileBuffer.pos`.
  - Проверка: `zig build -Doptimize=Debug` на system Zig проходит; `luazig -e 'print(1+2)'` печатает `3`; `files.lua` проходит дальше IO/flush/large-files секций и теперь останавливается на уже следующем runtime blocker: отсутствует Lua global `arg`.
- [ ] P12.6. После successful latest-Zig build прогнать release gate и parity matrix, затем удалить из README устаревшие оговорки про bundled Zig.

### История закрытых этапов

- P3: стабилизация базы до API закрыта; targeted parity suite проходили, `bc_vm` получил coverage gate, perf guard и runtime invariant audit.
- P4: начальный публичный Zig API и базовый C ABI shim добавлены.
- P5: `testC/ltests` compatibility доведена до прохождения `api.lua --testc`.
- P6: official `testC` lane стабилизирован; missing commands сведены к нулю; coroutine/testC path работает через runtime-семантику.
- P7: публичный Zig/C-like API для `testC` расширен до stack/table/thread primitives, generic `T.testC` команды переведены на API-входы, добавлен `tools/api_regression_lane.py`.
- P8: базовая совместимость official suite закрыта до `33/34 pass parity`; `zig_fail=0`, `all.lua` проходит в bounded safe matrix, `heavy.lua` честно классифицирован как общий resource-heavy timeout; core perf baseline обновлён.
- P9: публичный Zig embedding API отделён от internals, добавлен public API integration lane, C ABI shim оставлен smoke-compat слоем поверх Zig API.
- Детальная история оптимизаций, промежуточных замеров и закрытых подпунктов сохранена в Git (`git log`).

### Быстрые команды

```sh
./tools/zig build -Dtarget=x86_64-linux-gnu.2.39 -Doptimize=Debug
tools/release_gate.sh
python3 tools/run_tests.py --suite nextvar.lua --suite coroutine.lua --suite calls.lua --suite locals.lua --suite db.lua --suite gc.lua --suite files.lua
python3 tools/testes_matrix.py --no-build --timeout 120
tools/run_with_limits.sh --mem-max 8G --mem-high 7G --timeout 1800 -- \
  python3 tools/testes_matrix.py --no-build --timeout 120
# Defaults are safer for Codex session stability:
tools/run_with_limits.sh --timeout 1800 -- \
  python3 tools/testes_matrix.py --no-build --timeout 120
# Recommended safe entrypoint (always uses memory-limited wrapper):
tools/testes_matrix_safe.sh
# Optional: override per-file timeouts, e.g. for long all.lua on low-RAM hosts
LZ_TEST_TIMEOUT_OVERRIDES="all.lua=300,heavy.lua=240" tools/testes_matrix_safe.sh
# Host entrypoint for real files.lua parity (outside sandbox):
tools/testes_matrix_host.sh
# Dedicated long-run lane for heavy.lua:
tools/heavy_safe.sh
```
