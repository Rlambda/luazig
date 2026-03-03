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
- `next` переведен на PUC-ближайшую модель (`findindex`-style): `key -> index` + переход к следующему live-ключу.
- Основной технический долг: добить cleanup legacy-названий/хелперов в continuation runtime и закрыть финальный P0-gate.
- Matrix (`tools/testes_matrix.py --no-build --timeout 120`, 2026-03-03): `29/33 pass parity`, `zig_fail=1` (`math.lua`), `both_fail=3` (`all.lua`, `heavy.lua`, `files.lua` в sandbox).

### Приоритет P0: убрать replay-зависимость coroutine

- [ ] P0.1. Зафиксировать границы legacy replay-кода, который реально участвует в coroutine-path (`resume/yield/wrap/close`).
  - [x] P0.1a. Вычистить replay-state-machine в `coroutine.resume` и VM hot-path (bootstrap/re-exec skip логика удалена).
- [ ] P0.2. Перевести `coroutine.resume/yield` полностью на continuation runtime без re-exec/replay.
  - [x] P0.2a. Убрать replay-bootstrap в `builtinCoroutineResume` для `.Closure` и `.Builtin` callee: `resume` всегда исполняет через обычный call + snapshot-resume, без установки `replay_mode/replay_target_yield`.
  - [x] P0.2b. Удалить replay-skip семантику записи/GC в VM hot-path: убраны `currentReplaySkippingWrite`, `shouldSuppressReplayTableWrite`, replay-ветки в `collectgarbage` и replay-restore upvalue-path.
  - [x] P0.2c. Удалить оставшееся replay-состояние потока (`replay_mode/replay_target_yield/replay_start_args/...`) и ветки suppress-hook/replay-epoch; генерация `frame_id` для continuation-снимков теперь всегда идет напрямую, без replay-режима.
- [ ] P0.3. Перевести `coroutine.wrap/close` на тот же runtime без replay-веток.
- [ ] P0.4. Удалить `replay_*` поля/ветки, которые остаются только для coroutine-корректности.
  - [x] P0.4a. Переименовать оставшиеся `replay_*` continuation-поля/хелперы в нейтральные `frame_*` (`frame_id`, `frame_local_overrides`, `frame_capture_cells`) и убрать replay-терминологию из coroutine runtime.
  - [x] P0.4b. Убрать replay-терминологию из debug-hook bridge (`line_hook_preseeded`, `debugPreseedLineHookFromUpvalue`) без изменения поведения.
- [ ] P0.5. Подтвердить parity gate после удаления replay: `coroutine.lua`, `nextvar.lua`, `calls.lua`, `files.lua`, `locals.lua`, `db.lua`, `gc.lua`.

### Приоритет P1: официальный matrix

- [ ] P1.1. Держать `zig_fail = 0` в `tools/testes_matrix.py`.
- [ ] P1.2. Сократить `both_fail` (сейчас это инфраструктурные/таймаутные кейсы: `all.lua`, `files.lua` в sandbox, `heavy.lua`).
- [ ] P1.3. Зафиксировать отдельный режим прогона вне sandbox для корректной оценки `files.lua`.

### Ограничения на изменения

- Не добавлять test-specific ветки (`source_name`, `line ranges`, `*_probe`, synthetic-режимы).
- По умолчанию выбирать PUC-first решения; отступления — только с явной технической причиной.
- Каждый шаг: реальный кодовый прогресс + обновление этого TODO.

### Быстрые команды

```sh
zig build -Doptimize=Debug
python3 tools/run_tests.py --suite nextvar.lua --suite coroutine.lua --suite calls.lua --suite locals.lua --suite db.lua --suite gc.lua --suite files.lua
python3 tools/testes_matrix.py --no-build --timeout 120
```

### Примечание

Детальный исторический журнал шагов сохранен в Git истории (`git log`) и отдельных коммитах; в README оставлен только актуальный рабочий план.
