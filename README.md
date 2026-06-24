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
make zig
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

Для отладки synthetic fallback-путей можно включить трассировку:

```sh
LUAZIG_TRACE_SYNTH=1 ./zig-out/bin/luazig third_party/lua-upstream/testes/coroutine.lua
```

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

### P9: развить публичный Zig/C-like API после стабилизации базы

Этот этап начинается после P8, чтобы API не закреплял нестабильную внутреннюю семантику VM.

- [x] P9.1. Описать целевой embedding API: lifecycle, stack, tables, calls, coroutine, debug, allocator/lifetime, error model.
  - Цель публичного слоя: дать Zig-пользователю семантический аналог Lua C API без копирования C ABI один-в-один. Базовый тип входа — `lua.api.State`; VM-private структуры (`Vm`, `Value`, `Table`, `Thread`, raw `Frame`) не должны быть основным пользовательским интерфейсом.
  - Lifecycle: `State.init(.{ .allocator = ... })` создаёт изолированное Lua state; `State.deinit()` закрывает state, запускает pending finalizers через runtime и освобождает API stacks. Дальше нужен явный `openLibs/openBaseLibs` слой, чтобы embedding мог выбирать stdlib.
  - Stack: публичный API сохраняет C API модель относительных индексов (`1..top`, `-1..-top`, `absindex`) и операции `gettop/settop/push*/pop/copy/rotate/insert/remove/replace/concat`. Ошибки индексации возвращаются как `ApiError.InvalidIndex`, а не приводят к undefined behavior.
  - Values/lifetime: строки, userdata, tables, closures и threads должны принадлежать `State`/allocator. Публичный API не должен возвращать dangling slices или raw VM pointers без lifetime-правила; если нужен handle, он должен быть typed handle с документированным временем жизни.
  - Tables/metatables: `newtable`, `gettable/settable`, `getfield/setfield`, `geti/seti`, `rawget/rawset/rawgeti/rawseti`, `getmetatable/setmetatable`, registry access. Семантика metamethod/raw должна следовать PUC Lua; оптимизации не должны менять порядок observable effects.
  - Calls/errors: `loadString/loadFile/loadBuffer`, `call`, `pcall`, `pcallk`, `error`, `traceback`. Zig API должен возвращать `Status`/`ApiError` и сохранять Lua error object доступным через stack/result API, вместо смешивания Zig panic/runtime error.
  - Coroutine: `newthread`, `resume`, `yield`, `yieldk`, `isyieldable`, `status`, `xmove`. Эти операции обязаны использовать тот же continuation runtime, что и `coroutine.lua`, без replay-веток и без test-specific режимов.
  - Debug: публичные entrypoints для hook/getinfo/getlocal/setlocal/upvalue/traceback должны отражать PUC Lua observable semantics, но API должен явно отделять debug-only возможности от стабильного embedding core.
  - Allocator/resource model: все allocation failures мапятся в `ApiError.Memory`/`Status.memory_error`; долгие suites запускаются через bounded lanes, но API не должен скрывать OOM/timeout как parity.
  - C ABI shim: если будет нужен, он строится поверх Zig API как совместимый слой, а не как второй путь к VM internals. Это решение остаётся в P9.5.
- [x] P9.2. Разделить API на публичный стабильный слой и VM-private internals; `T.testC` должен использовать только публичные входы там, где это применимо.
  - `src/lua/root.zig` теперь публикует стабильный embedding surface отдельно: `api`, `c_api`, `State`, `ApiError`, `Status`, `Type`.
  - Parser/IR/VM/compiler/test-only modules перенесены под явный namespace `lua.internal.*`; CLI (`luazig`, `luazigc`) обновлён на internal imports, чтобы top-level API не выглядел поддерживаемым VM-private контрактом.
  - `src/lua/testc.zig` остаётся поверх `api.State`; оставшийся large legacy `T.testC` path внутри VM считается областью P9.3/P9.4, где команды нужно постепенно переводить на публичный слой и покрывать API integration tests.
- [ ] P9.3. Расширить `src/lua/api.zig` до покрытия ключевых сценариев Lua C API, но с Zig-friendly ownership/error semantics.
- [ ] P9.4. Добавить интеграционные Zig API tests, эквивалентные upstream `api.lua` сценариям без зависимости от `T.testC` DSL.
- [ ] P9.5. Решить, нужен ли C ABI shim как поддерживаемый продукт или только smoke-compat слой поверх Zig API.

### История закрытых этапов

- P3: стабилизация базы до API закрыта; targeted parity suite проходили, `bc_vm` получил coverage gate, perf guard и runtime invariant audit.
- P4: начальный публичный Zig API и базовый C ABI shim добавлены.
- P5: `testC/ltests` compatibility доведена до прохождения `api.lua --testc`.
- P6: official `testC` lane стабилизирован; missing commands сведены к нулю; coroutine/testC path работает через runtime-семантику.
- P7: публичный Zig/C-like API для `testC` расширен до stack/table/thread primitives, generic `T.testC` команды переведены на API-входы, добавлен `tools/api_regression_lane.py`.
- P8: базовая совместимость official suite закрыта до `33/34 pass parity`; `zig_fail=0`, `all.lua` проходит в bounded safe matrix, `heavy.lua` честно классифицирован как общий resource-heavy timeout; core perf baseline обновлён.
- Детальная история оптимизаций, промежуточных замеров и закрытых подпунктов сохранена в Git (`git log`).

### Быстрые команды

```sh
zig build -Doptimize=Debug
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
