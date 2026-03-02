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

### Фиксированный план: честная coroutine-модель (PUC 5.5 parity)

Цель этого блока: убрать replay-эмуляцию и получить drop-in поведение
`coroutine.resume/yield/wrap/close` как в Lua PUC 5.5, без тестовых обходов.

- [ ] Фаза 0 (заморозка анти-паттернов):
  запретить добавление новых `replay_*`, `*_probe`, `source_name`-веток
  для исправления coroutine/nextvar/db кейсов.
- [ ] Фаза 1 (ядро resumable runtime):
  заменить re-exec/replay-модель на сохранение реального состояния исполнения
  coroutine (кадр/pc/локалы/апвэлью/точка продолжения).
- [ ] Фаза 2 (resume/yield семантика):
  перевести `coroutine.resume` и `coroutine.yield` на новый runtime:
  без повторного выполнения префикса функции, с корректной передачей аргументов
  `resume -> yield`.
- [ ] Фаза 3 (wrap/close семантика):
  перевести `coroutine.wrap` и `coroutine.close` на тот же runtime;
  удалить replay-буферы/skip-режимы и связанные обходы.
- [ ] Фаза 4 (удаление legacy replay):
  удалить/обнулить replay-инфраструктуру в VM (`replay_*` пути в корутинных
  builtin и вспомогательных ветках debug/upvalue/table записи), сохранив
  только код, реально нужный для PUC-совместимого выполнения.
- [ ] Фаза 5 (стабилизация parity):
  закрыть регрессии после удаления replay и довести coroutine-зависимые тесты.

Критерии приемки этого плана:

- [ ] `nextvar.lua` проходит минимум до `line 567` (целевой финал — полный pass).
- [ ] `coroutine.lua` проходит parity без synthetic/test-specific логики.
- [ ] Gate без регрессии:
  `calls.lua`, `files.lua`, `locals.lua`, `db.lua`, `gc.lua` (в сравнении ref vs zig).
- [ ] `tools/testes_matrix.py --timeout 20`: число `pass parity` не ниже baseline
  на старте фазы 1; целевой тренд — рост pass-count.

### Внутренний план агента (исполнение coroutine-рефактора)

Этот блок — рабочий TODO для перехода на полноценные корутины (PUC Lua-style continuation),
где каждый шаг обязан закрывать минимум один пункт.

Текущий статус baseline (до полного coroutine-перехода):

- `coroutine.lua`: pass
- `db.lua`: pass
- `calls.lua`: pass
- `locals.lua`: fail (`locals.lua:625`)
- `nextvar.lua`: fail/timeout
- Репро для главного блокера: `tools/locals_coroutine_close_repro.py`

#### Контракт выполнения (обязательный)

- [ ] Каждый завершенный шаг = один коммит + минимум один пункт TODO переводится в `[x]`.
- [ ] Шаг без закрытого пункта считается незавершенным и не принимается.
- [ ] После каждого шага обновляется этот TODO (статусы + короткий журнал ниже).
- [ ] Запрещено добавлять test-specific обходы: `source_name`, line-range, `*_probe`.

#### TODO: Реальные continuation-корутины

- [x] C0. Зафиксировать baseline и репро для `locals.lua` close/yield chain.
  Критерий: `tools/locals_coroutine_close_repro.py` стабильно показывает `ref` vs `zig`.
- [x] C1. Ввести continuation-id для yield-групп и привязать snapshot'ы к конкретному resume-циклу.
  Критерий: snapshot'ы не смешиваются между разными yield-итерациями.
- [ ] C2. Перевести выбор suspended frame с LIFO на корректный continuation walk (внутренний->внешний кадр одной yield-группы).
  Критерий: на репро исчезает повтор `z` после `x`.
- [ ] C3. Убрать re-exec replay для coroutine closure-resume path.
  Критерий: при `resume` не создаются новые replay-prefix кадры для уже-yielded coroutine.
- [ ] C4. Перевести `coroutine.wrap` полностью на тот же continuation runtime (без eager/replay поведения).
  Критерий: `locals_coroutine_close_repro` дает `z -> y -> x -> true,10,20,30`.
- [ ] C5. Привести `coroutine.close` к тому же runtime с корректным close-unwind порядка `<close>`.
  Критерий: `coroutine.lua` остается pass без synthetic/test-specific логики.
- [ ] C6. Синхронизировать debug/setlocal/getlocal с continuation snapshot-кадрами.
  Критерий: `db.lua` pass и нет регрессии по hook/traceback.
- [ ] C7. Удалить coroutine replay-path (`replay_*` ветки, используемые только для coroutine выполнения).
  Критерий: coroutine runtime не зависит от replay_mode для корректности.
- [ ] C8. Восстановить и зафиксировать gate parity после удаления replay.
  Критерий: `coroutine.lua`, `locals.lua`, `db.lua`, `calls.lua`, `files.lua`, `gc.lua` pass.
- [ ] C9. Пробить `nextvar.lua` до `line >= 567`, целевой финал — полный pass.
  Критерий: отчет `tools/run_tests.py --suite nextvar.lua` фиксирует целевую отметку или полный pass.

#### Журнал выполнения (обновлять каждый шаг)

- `2026-03-02`: C0 закрыт. Добавлен фокусный репро `tools/locals_coroutine_close_repro.py`.
- `2026-03-02`: C1 закрыт. Добавлены `yield_id`-группы snapshot'ов и очистка старых snapshot'ов на новом `yield`.

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
