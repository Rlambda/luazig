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

Цель: довести `zig`-движок до прохождения официального набора тестов
`third_party/lua-upstream/testes/all.lua`.

### Сделано

- [x] Базовая инфраструктура проекта: сборка, запуск, тестовый harness.
- [x] `luazig`/`luazigc` работают как самостоятельные zig-бинарники без ref-делегации.
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
- [x] Восстановлен parity для критичных regression-свитов:
  `db.lua`, `errors.lua`, `calls.lua`.
- [x] Восстановлен parity для `gc.lua` в режиме
  `-e "_port=true; _soft=true"`, включая финальный close-state `__gc` вывод.
- [x] Закрыты ранние parser/codegen блокеры (undeclared-global leakage, duplicate-label
  leakage между sibling-block, часть `goto` scope-check):
  `coroutine.lua`/`goto.lua`/`math.lua`/`locals.lua` больше не падают на первых
  compile-time ошибках.

### В работе сейчас (приоритет 0)

- [ ] Закрыть раннее падение `vararg.lua` (`assertion failed` на начальных кейсах):
  зафиксировать разницу `ref` vs `zig` и довести базовую vararg-совместимость.
- [ ] Разблокировать coroutine-зависимые файлы:
  `coroutine.lua`, `nextvar.lua`, `sort.lua` (ошибки вокруг `coroutine.create` и окружения).
- [ ] Закрыть parser/codegen-расхождения в метках и `<close>`:
  довести до полного parity edge-cases jump-scope и upvalue/debug-сценариев в `goto.lua`.
- [ ] Закрыть ближайшие stdlib-расхождения:
  `strings.lua` (`string.char`), `tpack.lua` (`string.packsize`), `events.lua` (`_G`).

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

### Блокеры для удаления synthetic-probes в `coroutine.lua`

- [x] `coroutine_wrap_tail_probe`:
  line-based synthetic удален; replay-движок подает последние resume-аргументы на skip-yield шагах, что закрывает tail-yield кейс из `coroutine.lua`.
- [x] `coroutine_wrap_xpcall_probe`:
  удален; replay получил два режима skip-yield (`latest`/`indexed`) и выбирает их по стартовым аргументам coroutine (нулевые стартовые аргументы -> `indexed` для iterator/xpcall сценариев).
- [x] `coroutine_wrap_xpcall_error_probe`:
  удален; `pcall/xpcall` больше не интерпретируют `error.Yield` как обычную ошибку и корректно пропускают yield.
- [ ] `coroutine_wrap_gc_probe`:
  нужна точная модель lifetime/GC для closure/thread ссылок при `coroutine.wrap` + weak-table сценариях.
- [ ] `coroutine_close_*` probes:
  нужен честный close/unwind path для `<close>` в suspended/dead thread без line-based подмен.

### Stdlib-паритет (приоритет 2)

- [ ] Последовательно закрывать пробелы stdlib по фактическим падениям test suite:
  `debug`, `string`, `table`, `math`, `os`, `io`, `coroutine`.
- [ ] Для каждого нового builtin фиксировать минимальный контракт совместимости
  (какие аргументы/результаты/ошибки поддержаны сейчас).

### Управление прогрессом

- [x] Поддерживать актуальный matrix-отчет по `testes/*.lua`:
  какие файлы проходят, какие нет, и первая причина расхождения.
  Текущий срез (`tools/testes_matrix.py --timeout 20`): `18/33 pass parity`,
  `zig_fail=12`, `both_fail=3`, `zig_only_pass=0`.
- [ ] Вести короткий changelog по этапам миграции `ref -> zig` в README
  (какие блоки test suite были разблокированы).
- [ ] Держать минимальный набор быстрых локальных проверок перед `test-suite`:
  `./tools/zig build`, `tools/run_tests.py --suite <target>`, `tools/testes_matrix.py`.

### Критерии готовности этапов

- [x] Этап A: `debug`/`gc`-критичные тесты (`db.lua`, `gc.lua`) проходят в режиме
  `-e "_port=true; _soft=true"`.
- [ ] Этап B: большинство файлов `testes/*.lua` имеют статус `pass parity` в matrix.
- [ ] Этап C: `third_party/lua-upstream/testes/all.lua` проходит без расхождений
  по поведению относительно `ref`.
