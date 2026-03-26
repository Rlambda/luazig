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

Цель: довести `luazig` до drop-in совместимости с PUC Lua 5.5.0 на официальном `testes`.

### Статус

- P2 (оптимизация VM и базовый bytecode backend) закрыт.
- `--vm=bc` работает в hybrid-режиме: поддержанный путь исполняется в `bc_vm`, неподдержанный безопасно откатывается в IR.
- Default путь `--vm=ir` остаётся опорным для parity с upstream suite.

### P3: стабилизация базы (до API)

- [x] P3.1. Зафиксировать и пройти baseline gate по официальному suite:
  - `tools/testes_matrix_safe.sh` c `zig_fail=0`;
  - целевые suite: `nextvar.lua`, `coroutine.lua`, `calls.lua`, `files.lua`, `locals.lua`, `db.lua`, `gc.lua`.
- [x] P3.2. Добить parity по оставшимся failing suite из matrix (включая `heavy.lua`), без test-specific обходов.
  - В safe-matrix сохраняется `zig_fail=0`; оставшийся проблемный `heavy.lua` классифицирован как инфраструктурный (resource/time bound), не как semantic zig-only расхождение.
  - Прямой запуск `heavy.lua` в текущем окружении подтверждает infra-ограничение для обеих реализаций (ref/zig не дают стабильный green без специальных ресурсных условий).
- [x] P3.3. Расширить покрытие `bc_vm` для часто встречающихся IR-инструкций (calls/table/index/branches), чтобы уменьшить долю fallback в IR.
  - Добавлена поддержка lowering + исполнения для `UnOp` (`not`, unary `-`) и compare-op (`==`, `~=`, `<`, `<=`, `>`, `>=`) в `lower_ir`/`bc_vm`.
  - Добавлены тесты на lowering (`lower_ir`) и выполнение compare/jump пути (`bc_vm`).
  - Bootstrap coverage на расширенном наборе chunk: `function_ratio=0.667`, `inst_ratio=0.217`.
- [x] P3.4. Добавить измеримый gate для `--vm=bc`: % инструкций/функций, выполненных без fallback, и целевое значение.
  - Добавлен `tools/bc_coverage_gate.py` (bootstrap/suites mode).
  - Текущая зафиксированная цель bootstrap-gate: `function_ratio >= 0.50`, `inst_ratio >= 0.20`.
  - Команда: `python3 tools/bc_coverage_gate.py --mode bootstrap --min-function-ratio 0.50 --min-inst-ratio 0.20`.
- [x] P3.5. Обновить perf baseline (`tools/perf/baseline.json`) и зафиксировать регрессионный guard для `nextvar.lua`/`coroutine.lua`/`gc.lua`.
  - Baseline обновлен: `python3 tools/perf_baseline.py --no-build --profiles ReleaseFast --timeout 240 --out tools/perf/baseline.json`.
  - Добавлены инструменты core-snapshot/guard:
    - `tools/perf_core_snapshot.py` -> `tools/perf/core_baseline.json`, `tools/perf/core_current.json`;
    - `tools/perf_guard_core.py` (gate по core-suite).
  - Текущий gate: `python3 tools/perf_guard_core.py --baseline tools/perf/core_baseline.json --current tools/perf/core_current.json --max-regression 0.15`.
- [x] P3.6. Провести аудит runtime-инвариантов (coroutine/close/error/debug hooks/metatable) и закрыть найденные расхождения с PUC.
  - Добавлен `tools/runtime_invariant_audit.sh`.
  - В аудите исправлено расхождение `errors.lua` (stack-overflow traceback в `xpcall`): `debug.traceback` теперь использует сохраненный traceback из точки ошибки, а не урезанный post-unwind стек.
  - Текущий аудит: `coroutine.lua`, `calls.lua`, `db.lua`, `gc.lua`, `files.lua`, `locals.lua`, `errors.lua`, `closure.lua` — parity pass.

### P4: публичный Zig API (C-like по семантике)

- [x] P4.1. Зафиксировать спецификацию `src/lua/api.zig`: `State`, stack model, lifetime/ownership, error model.
  - Добавлен `src/lua/api.zig` с зафиксированными типами/контрактами:
    - `State`, `Type`, `Status`, `ApiError`, `Options`;
    - контракт нормализации индексов API-стека (`normalizeIndex`);
    - lifecycle `State.init/deinit`.
- [x] P4.2. Реализовать минимальный API-слой:
  - push/pop/inspect (`push*`, `to*`, `type`, `settop/gettop`);
  - globals/tables (`getglobal/setglobal`, `gettable/settable`, raw-варианты);
  - loading/execution (`loadbuffer/loadfile`, `pcall`).
  - Реализован `State.stack` и базовые C-like операции стека/инспекции.
  - Добавлены VM-entry points для table access через обычную семантику (`__index`/`__newindex`) и raw-варианты.
  - Добавлены `loadbuffer/loadfile/pcall` поверх parser+codegen+VM.
  - Добавлены unit-тесты API: lifecycle/index/stack/load+pcall.
- [x] P4.3. Реализовать функции для userdata/метатаблиц/registry/upvalues на уровне публичного API.
  - Добавлены API-операции:
    - метатаблицы: `getmetatable`, `setmetatable`;
    - registry: `getregistry` (через `debug.getregistry`);
    - upvalues: `getupvalue`, `setupvalue` (через `debug.getupvalue/setupvalue`).
  - Для userdata на уровне type-инспекции добавлен корректный тег `userdata` для `FILE*`-объектов (`io` handles), плюс `isuserdata`.
- [x] P4.4. Подготовить тестовый пакет для API:
  - Zig unit/integration tests;
  - сценарии, эквивалентные ключевым кейсам `api.lua` из upstream (семантически).
  - Расширены тесты `src/lua/api.zig`:
    - lifecycle/index/stack/load+pcall;
    - globals roundtrip (`setglobal/getglobal`);
    - table semantics: `gettable/settable` с `__index/__newindex` + `rawget`.
- [x] P4.5. Опционально: thin C-ABI shim поверх `api.zig` для частичной совместимости с Lua C API.
  - Добавлен `src/lua/c_api.zig` с базовым C-ABI слоем:
    - lifecycle: `luaL_newstate`, `lua_close`;
    - stack: `lua_gettop`, `lua_settop`, `lua_pop`, `lua_push*`;
    - inspect/conversion: `lua_type`, `lua_toboolean`, `lua_tointegerx`, `lua_tonumberx`;
    - globals/load/call: `lua_getglobal`, `lua_setglobal`, `luaL_loadbufferx`, `luaL_loadfilex`, `lua_pcallk`.

### P5: testC/ltests compatibility (активация API-тестов)

- [x] P5.1. Зафиксировать инвентарь команд `T.*` из upstream `testes` и приоритет реализации.
  - Добавлен генератор `tools/testc_inventory.py`.
  - Сформирован инвентарь `docs/testc_inventory.md` по `third_party/lua-upstream/testes/*.lua`.
  - По частоте top-команды: `T.testC`, `T.newuserdata`, `T.alloccount`, `T.gcage`, `T.makeCfunc`, `T.doremote`.
- [ ] P5.2. Реализовать ядро `T.testC`: интерпретация подмножества команд через публичный `src/lua/api.zig`.
- [ ] P5.3. Интегрировать тестовый модуль `T` в runtime (только test-mode), без влияния на обычный запуск `luazig`.
- [ ] P5.4. Закрыть `api.lua` в режиме активного `testC` (без skip-path), зафиксировать parity с ref.

### История этапов

- Детальная история оптимизаций и промежуточных замеров сохранена в Git (`git log`).
- В README оставлен только актуальный план и критерии приемки.
- P3.1: целевые suite проходят (`run_tests.py --suite nextvar/coroutine/calls/files/locals/db/gc`), matrix gate использует последний стабильный safe-срез (`32/33`, `zig_fail=0`).

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
