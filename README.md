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

## Движки (ref/zig)

`luazig` и `luazigc` поддерживают выбор движка:

- `--engine=ref` (по умолчанию): делегирует эталонному C Lua / C luac
- `--engine=zig`: использует Zig-реализацию (пока только лексер/parse-only в `luazigc`)

Также можно задать `LUAZIG_ENGINE=ref|zig`.

Для прозрачности делегирования в `ref`-режиме:

- `--trace-ref`: печатает точную команду делегирования перед запуском.
- `LUAZIG_TRACE_REF=1`: включает тот же режим через env.

Пример:

```sh
./zig-out/bin/luazig --engine=ref --trace-ref -v
./zig-out/bin/luazigc --engine=ref --trace-ref -p tests/smoke/01_min.lua
```

## Тесты (дифференциально)

Мы используем официальный test suite из upstream Lua как `git submodule`:

```sh
git submodule update --init --recursive
```

Прогон тестов сравнивает поведение эталонного `build/lua-c/lua` и `zig-out/bin/luazig`:

```sh
make test-suite
```

Примечание: в текущий момент `luazig`/`luazigc` остаются bootstrap-обертками.
В differential-инструментах `ref` запускается напрямую как `build/lua-c/lua` (без промежуточной обертки), а `zig` — через `luazig --engine=zig`.
Это уменьшает непрозрачность и сохраняет совместимый harness.

## Компиляция (сравнение с luac -p)

Пока у нас нет VM, но уже можно сравнивать “компилируется/не компилируется” между `luac -p` и `luazigc --engine=zig -p`:

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

Цель: довести `zig`-движок до прохождения официального набора тестов
`third_party/lua-upstream/testes/all.lua`.

### Сделано

- [x] Базовая инфраструктура проекта: сборка, запуск, тестовый harness.
- [x] Движок `--engine=zig` для `luazig`.
- [x] Существенная часть VM/IR/кодогенерации, достаточная для запуска крупных
  участков upstream-тестов.
- [x] Базовая стандартная библиотека (`base`, части `string`, `table`, `io`,
  `math`, `os`, `debug` в виде рабочего подмножества).
- [x] Поддержка weak-таблиц и улучшенный GC-cycle (включая эпемероны и порядок
  weak/finalizer-прохождений в упрощенной модели).
- [x] Минимальная библиотека `coroutine`:
  `create`, `resume`, `yield`, `status`, `running`.
- [x] Убраны deprecated Zig API в stdio-слое (`deprecatedWriter` не используется;
  используем streaming writer API).
- [x] Добавлена IR-инструкция `ClearLocal`, чтобы чистить stack-slot локала при
  выходе из scope без порчи boxed upvalue.
- [x] Добавлен `tools/testes_matrix.py` для пофайлового статуса
  (`pass`/`zig_fail`/`both_fail`) и выгрузки JSON-отчета.

### В работе сейчас (приоритет 0)

- [ ] Довести `debug`-семантику до уровня `db.lua`:
  `getinfo/getlocal/setlocal/gethook/sethook/getregistry`, корректные line/call/return
  hook-сценарии, работа с temporary-слотами и vararg.
- [ ] Закрыть оставшиеся расхождения в `string`/`table` для `db.lua` и соседних тестов:
  `string.match`, дополнительные паттерн-кейсы, поведение `gsub/find` в edge cases.
- [ ] Уточнить и стабилизировать отображение active lines:
  `debug.getinfo(..., "L")` должен отдавать ожидаемый набор строк без лишних.

### Ядро языка (приоритет 1)

- [ ] Полный vararg semantics:
  хранение, доступ, передача через вызовы, корректное поведение для отрицательных
  индексов в debug API.
- [ ] Полный multi-return semantics:
  return/call expansion во всех позициях (присваивания, аргументы вызова, table constructors).
- [ ] Семантическая совместимость вызовов и присваиваний с Lua в крайних случаях
  (включая временные значения и промежуточные слоты).

### GC и coroutine (приоритет 1)

- [ ] Полноценная coroutine-модель:
  сохранение/восстановление continuation, корректные переходы состояний thread.
- [ ] Корректное удержание GC roots для suspended coroutine и их внутренних ссылок.
- [ ] Расширение GC-модели для thread/finalizer кейсов из upstream-тестов.

### Stdlib-паритет (приоритет 2)

- [ ] Последовательно закрывать пробелы stdlib по фактическим падениям test suite:
  `debug`, `string`, `table`, `math`, `os`, `io`, `coroutine`.
- [ ] Для каждого нового builtin фиксировать минимальный контракт совместимости
  (какие аргументы/результаты/ошибки поддержаны сейчас).

### Управление прогрессом

- [ ] Поддерживать актуальный matrix-отчет по `testes/*.lua`:
  какие файлы проходят, какие нет, и первая причина расхождения.
- [ ] Вести короткий changelog по этапам миграции `ref -> zig` в README
  (какие блоки test suite были разблокированы).
- [ ] Держать минимальный набор быстрых локальных проверок перед `test-suite`:
  `./tools/zig build`, `tools/run_tests.py --suite <target>`, `tools/testes_matrix.py`.

### Критерии готовности этапов

- [ ] Этап A: `debug`/`gc`-критичные тесты (`db.lua`, `gc.lua`) проходят в режиме
  `--engine=zig -e "_port=true; _soft=true"`.
- [ ] Этап B: большинство файлов `testes/*.lua` имеют статус `pass parity` в matrix.
- [ ] Этап C: `third_party/lua-upstream/testes/all.lua` проходит без расхождений
  по поведению относительно `ref`.
