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

### Текущий срез

- `nextvar.lua`, `coroutine.lua`, `calls.lua`, `locals.lua`, `db.lua`, `gc.lua`, `files.lua`: parity pass.
- `next` переключен на PUC-style линейные примитивы (`findIndex/nextFromIndex`) как primary-path.
- Legacy `next_cache` структуры/ветки удалены из runtime.
- Основной технический долг: добить cleanup legacy-названий/хелперов в continuation runtime и закрыть финальный P0-gate.
- Matrix (`tools/testes_matrix.py --no-build --timeout 120`, 2026-03-03): `30/33 pass parity`, `zig_fail=0`, `both_fail=2` + `both_fail_infra=1` (`files.lua` в sandbox `/dev/full`).

### Приоритет P0: убрать replay-зависимость coroutine

- [ ] P0.1. Зафиксировать границы legacy replay-кода, который реально участвует в coroutine-path (`resume/yield/wrap/close`).
  - [x] P0.1a. Вычистить replay-state-machine в `coroutine.resume` и VM hot-path (bootstrap/re-exec skip логика удалена).
- [ ] P0.2. Перевести `coroutine.resume/yield` полностью на continuation runtime без re-exec/replay.
  - [x] P0.2a. Убрать replay-bootstrap в `builtinCoroutineResume` для `.Closure` и `.Builtin` callee: `resume` всегда исполняет через обычный call + snapshot-resume, без установки `replay_mode/replay_target_yield`.
  - [x] P0.2b. Удалить replay-skip семантику записи/GC в VM hot-path: убраны `currentReplaySkippingWrite`, `shouldSuppressReplayTableWrite`, replay-ветки в `collectgarbage` и replay-restore upvalue-path.
  - [x] P0.2c. Удалить оставшееся replay-состояние потока (`replay_mode/replay_target_yield/replay_start_args/...`) и ветки suppress-hook/replay-epoch; генерация `frame_id` для continuation-снимков теперь всегда идет напрямую, без replay-режима.
- [x] P0.3. Перевести `coroutine.wrap/close` на тот же runtime без replay-веток.
  - [x] P0.3a. Убрать зависимость resumed builtin-coroutine от replay-аргументов: `coroutine.create(pcall/xpcall)` теперь сохраняет `entry_args` потока и продолжает suspended execution через continuation runtime.
  - [x] P0.3b. Нормализовать lifecycle continuation scratch-state: единая очистка `entry_args/frame_local_overrides/frame_capture_cells` в `resume/close/freeThreadWrapBuffers`.
- [x] P0.4. Удалить `replay_*` поля/ветки, которые остаются только для coroutine-корректности.
  - [x] P0.4a. Переименовать оставшиеся `replay_*` continuation-поля/хелперы в нейтральные `frame_*` (`frame_id`, `frame_local_overrides`, `frame_capture_cells`) и убрать replay-терминологию из coroutine runtime.
  - [x] P0.4b. Убрать replay-терминологию из debug-hook bridge (`line_hook_preseeded`, `debugPreseedLineHookFromUpvalue`) без изменения поведения.
- Matrix после cleanup (`tools/testes_matrix.py --no-build --timeout 120`): `30/33 pass parity`, `zig_fail=0`, `both_fail=3` (`all.lua`, `heavy.lua`, `files.lua` в sandbox).
- [x] P0.5. Подтвердить parity gate после удаления replay: `coroutine.lua`, `nextvar.lua`, `calls.lua`, `files.lua`, `locals.lua`, `db.lua`, `gc.lua`.

### Приоритет P1: официальный matrix

- [ ] P1.1. Держать `zig_fail = 0` в `tools/testes_matrix.py`.
- [ ] P1.2. Сократить `both_fail` (сейчас это инфраструктурные/таймаутные кейсы: `all.lua`, `files.lua` в sandbox, `heavy.lua`).
- [ ] P1.3. Зафиксировать отдельный режим прогона вне sandbox для корректной оценки `files.lua`.

### Приоритет P2: оптимизация VM (IR -> bytecode)

- [ ] P2.0. Зафиксировать baseline производительности и добавить perf-guard.
  - [x] P2.0a. Добавить `tools/perf_baseline.py` для съема baseline по suite + microbench.
  - [x] P2.0b. Добавить `tools/perf_guard.py` для автоматической проверки регрессий относительно baseline.
  - [x] P2.0c. Снять и зафиксировать baseline в `tools/perf/baseline.json` (Debug + ReleaseFast) и занести срез в README.
- [ ] P2-next. Миграция `next` на PUC-first архитектуру (`luaH_next`-подобный путь) с целью parity + ускорения.
  - [x] P2-next.1. Зафиксировать parity-контракт `next` (PUC-инварианты) и критерии приемки.
    - Контракт: `next(t, nil)` возвращает первый live-ключ; `next(t, k)` возвращает следующий live-ключ после `k` в табличном обходе.
    - Контракт: `invalid key to 'next'` только при ключе, который не может быть продолжением текущего обхода.
    - Контракт: удаленные/dead ключи не ломают продолжение обхода; weak/GC случаи не должны требовать test-specific веток.
    - Контракт: `1` и `1.0` канонизируются в один ключ для итерации, как в PUC.
  - [x] P2-next.2. Ввести внутренние примитивы обхода таблицы в PUC-стиле:
    - `findIndex(table, key) -> internal index | invalid`
    - `nextFromIndex(table, idx) -> next key | nil`
    - Реализовано в VM как `nextFindIndexLinear` + `nextFromIndexLinear`; `builtinNext` использует их как fallback-path для cache miss/удаленных ключей без test-specific логики.
  - [x] P2-next.3. Переключить `builtinNext` на новый path по умолчанию (без snapshot-cache как primary).
    - `builtinNext` теперь всегда идет через `nextFindIndexLinear` + `nextFromIndexLinear`; cache-path больше не primary.
  - [x] P2-next.4. Удалить legacy `next_cache` структуры/ветки/invalidation, ставшие не нужны.
    - Удалены `Table.NextCache`, `next_cache/next_version`, `ensureNextCache`, `invalidateNextCache` и связанная логика.
  - [ ] P2-next.5. Подтвердить parity/perf gate после миграции:
    - parity: `nextvar.lua`, `coroutine.lua`, `calls.lua`, `files.lua`, `locals.lua`, `db.lua`, `gc.lua`;
    - matrix: pass-count не ниже baseline, `zig_fail = 0`;
    - perf target (`ReleaseFast`, `nextvar.lua`): Stage A `<= 0.80s`, Stage B `<= 0.40s`, Stage C `<= 0.20s` (stretch).
    - Текущий статус после P2-next.4 + оптимизаций PUC-path (`nextFromControlLinear` + next-hint resume): `nextvar.lua` ~`1.26s`-`1.27s` (parity сохранен, perf target пока не достигнут).
    - Generic-for hot path выделен в отдельный IR op `ForIterCall`; parity сохранен, текущий perf остается около `1.26s`-`1.27s`.
    - Убран лишний call/return debug-hook dispatch для builtin-call path, когда hooks не активны: официальный `nextvar.lua` пока не ускорился заметно (~`1.27s`), но dense-array `next` microbench снизился примерно с `2.20s` до `1.97s`.
    - Hint-match в `builtinNext` переведен с общего `valuesEqual` на специализированное сравнение по типу ключа: официальный `nextvar.lua` вернулся к ~`1.26s`, dense-array microbench стабилизировался около `1.96s`.
- [ ] P2.1. Ускорить hot-path текущей IR VM без смены backend.
  - [ ] P2.1a. Arithmetic/table/call fast-path cleanup.
    - [x] P2.1a.1. Выравнять `%` с PUC Lua (`luaV_mod`/`luaV_modf`) для стабильного ReleaseFast parity.
    - [x] P2.1a.2. Убрать лишнюю инвалидацию `next`-cache при `tableSetValue` (инвалидировать только при изменении множества ключей).
  - [ ] P2.1b. Снижение overhead dispatch/Value в горячих инструкциях.
- [ ] P2.2. Добавить compact bytecode backend.
  - [ ] P2.2a. `src/lua/bytecode.zig` (формат + const pool + line table).
  - [ ] P2.2b. `src/lua/lower_ir.zig` (IR -> bytecode lowering).
  - [ ] P2.2c. `src/lua/bc_vm.zig` (исполнение bytecode) + dual mode `--vm=ir|bc`.
- [ ] P2.3. Перенести runtime-оптимизации на bytecode backend и стабилизировать parity/perf.

Baseline (2026-03-06, `tools/perf/baseline.json`):
- Matrix (`Debug`): `30/33 pass parity`, `zig_fail=0`, `both_fail=2`, `both_fail_infra=1`.
- Suite timing (`Debug`, zig):
  `nextvar.lua=56.45s`, `math.lua=99.04s`, `coroutine.lua=4.49s`, `gc.lua=6.94s`.
- Suite timing (`ReleaseFast`, zig):
  `nextvar.lua=1.37s`, `coroutine.lua=0.115s`, `gc.lua=0.177s`.
  Отдельный regression-issue с `math.lua` (assert в ReleaseFast) закрыт:
  сейчас `python3 tools/run_tests.py --suite math.lua --no-build` совпадает с ref в Debug и ReleaseFast.
  После P2.1a.2: `nextvar.lua` ускорен до ~`1.27s` (локальный замер, ref ~`0.03s`).
  После P2-next.3/4 (PUC-style primary-path + удаление legacy cache): `nextvar.lua` ~`2.70s` (временная регрессия скорости на шаге архитектурной миграции).
  После дооптимизации array-fastpath в `nextFromIndexLinear`: `nextvar.lua` ~`2.54s`.
  После перехода на one-pass поиск/переход (`nextFromControlLinear`): `nextvar.lua` ~`2.09s`.
  После тип-специализированного ускорения control-path в `nextFromControlLinear`: `nextvar.lua` ~`2.00s`.
  После добавления next-hint resume (без возврата к snapshot-cache): `nextvar.lua` ~`1.26s`.
  После отключения пустого debug-hook dispatch в builtin-call path: `nextvar.lua` ~`1.27s`, dense-array `next` microbench ~`1.97s` (было ~`2.20s`).
  После type-specialized hint-match в `builtinNext`: `nextvar.lua` ~`1.26s`, dense-array `next` microbench ~`1.96s`.

Matrix update (после оптимизаций, `tools/testes_matrix.py --no-build --timeout 120`):
- `30/33 pass parity`, `zig_fail=0`, `both_fail=2`, `both_fail_infra=1` (на уровне baseline).

### Ограничения на изменения

- Не добавлять test-specific ветки (`source_name`, `line ranges`, `*_probe`, synthetic-режимы).
- По умолчанию выбирать PUC-first решения; отступления — только с явной технической причиной.
- Каждый шаг: реальный кодовый прогресс + обновление этого TODO.
- Для `next` приоритет у PUC-path даже ценой глубокой переработки VM/table internals.

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
```

### Примечание

Детальный исторический журнал шагов сохранен в Git истории (`git log`) и отдельных коммитах; в README оставлен только актуальный рабочий план.
