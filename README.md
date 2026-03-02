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
  - [x] C2.1. Ввести depth-aware выбор snapshot-кадра внутри yield-группы (приоритет более глубокого кадра вместо "последнего добавленного").
  - [x] C2.1b. Сделать direction-aware выбор snapshot-кадра: обычный resume восстанавливает внешние кадры первыми (shallowest), self-recursive режим сохраняет deep-first.
  - [ ] C2.2. Добить финальный проход continuation до корректного terminal-return без повторного `z`.
  - [x] C2.2.1. Ужесточить match suspended snapshot по identity closure/upvalues (не только по `func`), чтобы исключить снятие "чужого" кадра.
  - [x] C2.2.1b. Добавить гибридный match: приоритет exact-closure identity, fallback на эквивалентные upvalues для пере-созданных closure-инстансов.
  - [ ] C2.2.2. Восстановить корректный unwind-order (`z2/y2/x2`) и terminal-return `true,10,20,30`.
  - [x] C2.2.2a. Сделать `CloseLocal` resumable-safe: деактивировать local только после успешного возврата из `__close` (и отдельно закрывать на RuntimeError).
  - [ ] C2.2.2b. Убрать финальный re-entry в начало close-chain после yield `x` (получить `x2` и финальный `true,10,20,30`).
  - [x] C2.2.2b.1. Снимать suspended snapshot без зависимости от `resume_inbox` (resume по кадрам должен работать и после частичного потребления inbox в верхних кадрах).
  - [x] C2.2.2b.1a. Ограничить snapshot-resume только активным `coroutine.resume` циклом (`in_resume`), чтобы исключить ложный pop snapshot в обычных вызовах.
  - [x] C2.2.2b.2. Дожать финальный шаг `x -> x2 -> return(true,10,20,30)` без повторного `z1`.
  - [x] C2.2.2b.3. Добавить close-unwind runtime-флаг и сдвиг snapshot pc для non-direct кадров (`pc+1`) во время pending-close sweep, чтобы не переисполнять тот же IR call-site при resume.
  - [x] C2.2.2b.4. Привязать `tail-return inbox` к функции кадра (не только к `pc`), чтобы исключить межкадровое совпадение `pc` и ложную доставку tail-результатов.
  - [x] C2.2.2b.5. Ужесточить capture suspended-frame до активного yield-unwind (`capture_yield_id != 0`), чтобы исключить ложные snapshot'ы на RuntimeError после предыдущего yield.
  - [x] C2.2.2b.6. Зафиксировать и переносить pending-close ошибку через yield внутри close-sweep, чтобы ошибка из `__close` не терялась при последующих yield в той же unwind-цепочке.
  - [x] C2.2.2b.7. В protected-call путях (`pcall`/`xpcall`) продвигать RuntimeError в `Yield`, когда ошибка пришла из error-unwind с уже сформированным coroutine-yield snapshot/payload.
  - [x] C2.2.2b.R1. Добавить отдельный фокусный репро для `coroutine.lua:96` (recursive `coroutine.wrap`) и зафиксировать текущий mismatch-паттерн.
  - [x] C2.2.2b.R2. Починить recursive `coroutine.wrap` до parity с ref (последовательность `1,1,2,6,24,...` без дубликатов).
- [ ] C3. Убрать re-exec replay для coroutine closure-resume path.
  Критерий: при `resume` не создаются новые replay-prefix кадры для уже-yielded coroutine.
- [ ] C4. Перевести `coroutine.wrap` полностью на тот же continuation runtime (без eager/replay поведения).
  Критерий: `locals_coroutine_close_repro` дает `z -> y -> x -> true,10,20,30`.
- [ ] C5. Привести `coroutine.close` к тому же runtime с корректным close-unwind порядка `<close>`.
  Критерий: `coroutine.lua` остается pass без synthetic/test-specific логики.
  - [x] C5.1. Перевести `coroutine.close` (для suspended/yielded потоков) с replay-прогона на forced-close через реальный `coroutine.resume` runtime.
  - [x] C5.2a. Убрать повторный возврат одной и той же close-ошибки на повторном `coroutine.close` (ошибка возвращается один раз, затем `true,nil`).
  - [x] C5.2. Добить self-close/close-itself сценарии из `coroutine.lua` до полного pass без повторного входа в close-цепочку.
- [x] C6. Синхронизировать debug/setlocal/getlocal с continuation snapshot-кадрами.
  Критерий: `db.lua` pass и нет регрессии по hook/traceback.
- [ ] C7. Удалить coroutine replay-path (`replay_*` ветки, используемые только для coroutine выполнения).
  Критерий: coroutine runtime не зависит от replay_mode для корректности.
- [ ] C8. Восстановить и зафиксировать gate parity после удаления replay.
  Критерий: `coroutine.lua`, `locals.lua`, `db.lua`, `calls.lua`, `files.lua`, `gc.lua` pass.
- [x] C9. Пробить `nextvar.lua` до `line >= 567`, целевой финал — полный pass.
  Критерий: отчет `tools/run_tests.py --suite nextvar.lua` фиксирует целевую отметку или полный pass.
  - [x] C9.a. Перевести `table.insert/remove/sort/concat/unpack` на metamethod-aware path (`__len/__index/__newindex`) для proxy-таблиц из `nextvar.lua`.
  - [x] C9.b. Исправить edge-semantics numeric `for`: const-assign check для loop var, wrap-overflow termination для explicit-step кейсов, float/integer режим для loop var в совместимых кейсах.
  - [x] C9.b.1. Убрать name-based hack в `SetLocal` для numeric-for: добавить явную IR-метадату `for_numeric_controls` и переключить float/int режим loop var по runtime-данным шага.
  - [x] C9.c. Убрать оставшийся tail timeout в `nextvar.lua` (после блока `testing floats in numeric for`) и довести до полного pass.

#### Журнал выполнения (обновлять каждый шаг)

- `2026-03-02`: C0 закрыт. Добавлен фокусный репро `tools/locals_coroutine_close_repro.py`.
- `2026-03-02`: C1 закрыт. Добавлены `yield_id`-группы snapshot'ов и очистка старых snapshot'ов на новом `yield`.
- `2026-03-02`: C6 закрыт. `db.lua` стабильно проходит parity; `debug.setlocal/getlocal` изменения применяются к suspended snapshot-кадрам.
- `2026-03-02`: Закрыт C2.1. Выбор suspended frame переведен на depth-aware приоритет в пределах `yield_id`. Репро сдвинулся с `z,z,z,z` к `z,y,x,z`; остался финальный блокер terminal-return (C2.2). Текущие регрессии после шага: `locals.lua:625`, `coroutine.lua:459`, `db.lua:750`; `calls.lua` без регрессии (pass).
- `2026-03-02`: Закрыт C2.2.1. Snapshot-resume теперь требует identity-match по closure/upvalues, а не только `func`. Это архитектурно убирает класс неправильных pop при повторных инстансах одной функции. Текущий статус репро все еще `z,y,x,z`; требуемый фикс остается в C2.2.2. Актуальные регрессии: `locals.lua:625`, `coroutine.lua:459`, `db.lua:750`; `calls.lua` pass.
- `2026-03-02`: Закрыт C2.2.2a. `CloseLocal` перестал преждевременно обнулять local перед `__close`, что восстановило resumable-unwind шаг `z2`. Текущий репро: `z,y,x,z` (трейс `... z2, nowY, y2, x1, z1`), финальный блокер остается C2.2.2b. Регрессии без изменения: `locals.lua:625`, `coroutine.lua:459`, `db.lua:750`; `calls.lua` pass.
- `2026-03-02`: Закрыт C2.2.1b. Для suspended-frame match введен приоритет exact closure identity с fallback на эквивалентные upvalues, чтобы поддержать resume при пересоздании closure-инстансов в outer frame. На текущем репро поведение пока без видимого сдвига (`z,y,x,z`), следующий шаг остается C2.2.2b. Регрессии: `locals.lua:625`, `coroutine.lua:459`, `db.lua:750`; `calls.lua` pass.
- `2026-03-02`: Закрыт C2.2.2b.1. Resume snapshot больше не привязан к факту наличия `resume_inbox`: кадры возобновляются по continuation-снимкам независимо от того, был ли inbox уже потреблен внешним кадром. Это сняло регрессию `db.lua` (снова pass) и вернуло `calls.lua` в pass; корневой coroutine-блокер (`locals.lua:625`, `coroutine.lua`) остается для C2.2.2b.2.
- `2026-03-02`: Закрыт C2.2.2b.1a. Введен флаг `in_resume`: suspended snapshot'ы подхватываются только внутри активного `coroutine.resume`, без влияния на обычные вызовы в выполняющемся потоке. Статус gate: `db.lua` pass, `calls.lua` pass; открытые блокеры без сдвига — `locals.lua:625`, `coroutine.lua:96` (и репро `z,y,x,z`).
- `2026-03-02`: Закрыт C2.2.2b.R1. Добавлен `tools/coroutine_recursive_repro.py` для точного воспроизведения блока `coroutine.lua:96` (recursive wrap). Зафиксированный mismatch zig: `1,1,1,2,2,6,6,24,...` вместо ref `1,1,2,6,24,...`. Это выделяет отдельный continuation-блокер, который нужно закрыть до полноценной parity по coroutine.
- `2026-03-02`: Закрыт C2.2.2b.R2. Введен селективный режим recursive-resume для snapshot-цепочек (один direct frame + единый caller callsite), что убрало дубли в recursive `coroutine.wrap`: `tools/coroutine_recursive_repro.py` теперь parity с ref. Gate после шага: `db.lua` pass, `calls.lua` pass, `locals.lua` все еще `625`; `coroutine.lua` продвинулся с `96` до `185`.
- `2026-03-02`: Закрыт C5.1. `coroutine.close` для suspended/yielded coroutine переведен с replay-прогона на forced-close через существующий `coroutine.resume` runtime. Это продвинуло `coroutine.lua` дальше (с `185` до `233`) без регрессий в `db.lua`/`calls.lua`; `locals.lua:625` и close-itself ветка в `coroutine.lua` остаются открытыми.
- `2026-03-02`: Закрыт C5.2a. Исправлено латчинг-поведение close-ошибки: повторный `coroutine.close` больше не возвращает ту же ошибку второй раз. Дополнительно сужен recursive-resume триггер до двухкадровой self-recursive цепочки (`direct + caller`), чтобы не расширять special-mode на общую рекурсию. Gate: `db.lua` pass, `calls.lua` pass, `locals.lua:625` fail; `coroutine.lua` продвинулся с `233` до `459`.
- `2026-03-02`: Закрыт C2.1b. Выбор suspended frame стал direction-aware: для общего continuation-walk используется shallow-first восстановление внешних кадров, а для self-recursive режима сохранен deep-first. Это восстановило генераторную рекурсию (`coroutine.lua` блок `all({},5,4)`), сохранив parity `tools/coroutine_recursive_repro.py`. Gate после шага: `coroutine.lua` продвинулся с `459` до `574`; `db.lua`/`calls.lua` pass; `locals.lua:625` пока открыт.
- `2026-03-02`: Закрыт C5.2. Для forced-close после yield внутри `pcall/xpcall/dofile` добавлен корректный close-resume RuntimeError на точке продолжения (`attempt to yield across a C-call boundary`), что восстановило unwind до ошибки из `__close`. Итог: `coroutine.lua` снова pass; `db.lua`/`calls.lua` pass; открытый блокер остается `locals.lua:625`, `nextvar.lua` по-прежнему уходит в timeout.
- `2026-03-02`: Закрыт C2.2.2b.2. Для `ReturnCall*` добавлен отдельный tail-return continuation inbox (не смешивается с resume-args inbox), что устранило повторный вход в close-chain после yield в `__close` и восстановило финальный переход `x -> x2 -> return(true,10,20,30)` в `tools/locals_coroutine_close_repro.py`. Дополнительно вынесена общая логика close-unwind continuation в helper, чтобы убрать регрессию по C-stack в `calls.lua`. Gate после шага: `coroutine.lua` pass, `db.lua` pass, `calls.lua` pass; `locals.lua` продвинулся с `625` до `1018`; `nextvar.lua` всё ещё timeout.
- `2026-03-02`: Закрыт C2.2.2b.3. В coroutine runtime добавлен флаг `in_close_pending_unwind`: при yield во время pending-close sweep non-direct snapshot-кадры сохраняются с `pc+1`, чтобы не повторять тот же call-site на resume; тот же флаг включен и для error-path close sweep (`errdefer`). Это архитектурный шаг для `locals.lua:1018` (цикл `case1/case2`), без регрессий в `coroutine.lua`/`calls.lua`/`db.lua`; целевой фикс `locals.lua:1018` остается открытым.
- `2026-03-02`: Закрыт C2.2.2b.4. `tail-return inbox` теперь матчится по паре `(func, pc)` вместо одного `pc`, чтобы исключить ложные попадания между разными кадрами с одинаковым номером инструкции. Gate без регрессий: `coroutine.lua` pass, `calls.lua` pass, `db.lua` pass; целевой блокер `locals.lua:1018` остается открытым (повтор `case1/case2` цикл), `nextvar.lua` всё ещё timeout.
- `2026-03-02`: Закрыт C2.2.2b.5. Capture suspended-frame переведен на строгое условие активного yield-unwind (`capture_yield_id != 0`) вместо косвенных признаков (`last_yield_payload`), чтобы не порождать snapshot'ы на обычных RuntimeError после старого yield. Дополнительно в `coroutine.resume` добавлена безопасная трактовка `RuntimeError + yielded-state` как resumable yield-path. Gate: `coroutine.lua`/`calls.lua`/`db.lua` pass без регрессий; `locals.lua` всё ещё упирается в `1018`.
- `2026-03-02`: Закрыт C2.2.2b.6. В `closePendingFunctionLocals` добавлен runtime-latch pending-close ошибки (`pending_close_err_*`) с восстановлением error-object на финальном выходе из close-sweep. Это убрало потерю обновленного error при yield между close-метаметодами (например, isolated repro третьего кейса теперь выдает `ret3,false,30` вместо `ret3,false,10`). Открытый блокер: `locals.lua:1018` (в полном сценарии остается неправильный переход после `x` в третьем кейсе).
- `2026-03-02`: Закрыт C2.2.2b.7. Для closure-вызовов внутри `pcall`/`xpcall` добавлен перевод `RuntimeError -> Yield`, если в текущем thread уже есть валидный yield snapshot/payload (`capture_yield_id`, `suspended_frames`, `yielded`). Это убрало проглатывание yield в error-unwind path (errdefer close-sweep) и закрыло `locals.lua` блокер (`1023`). Gate: `locals.lua` pass, `coroutine.lua` pass, `calls.lua` pass, `db.lua` pass.
- `2026-03-02`: Закрыты C9.a/C9.b (часть nextvar). `table.*` для proxy-таблиц переведен на metamethod-aware path, исправлены кейсы `table.remove` вокруг позиции `0`, и numeric-for edge cases (const assignment в loop var, overflow-stop для explicit step, корректный float/int режим в ряде сценариев). Gate без регрессий: `coroutine.lua`/`calls.lua`/`db.lua`/`locals.lua` pass. `nextvar.lua` существенно продвинут (ранние блокеры сняты, включая участки до и после `line 843`), но остается tail-timeout после блока `testing floats in numeric for` (C9.c).
- `2026-03-02`: Закрыт C9.b.1. Удален name-based coercion hack для numeric-for (`SetLocal` больше не смотрит на имена `initial value/limit/step`), вместо него добавлена IR-метадата `for_numeric_controls` и runtime-логика выбора float/int для loop var по фактическому типу шага. Это убрало ложные конфликты с пользовательской переменной `step` и продвинуло `nextvar.lua` до нового блокера `line 920` (assert в `__pairs` close-path). Gate после шага: `coroutine.lua` pass, `calls.lua` pass, `db.lua` pass, `locals.lua` pass; открытые: `nextvar.lua:920`, `files.lua:208`, `gc.lua` timeout на текущем лимите.
- `2026-03-02`: Закрыт C9.c и весь C9. Реализован `pairs` с поддержкой `__pairs`-метаметода и корректной передачей 4-го return (tbc-значение) в generic-for; в `runResolvedCallInto` для builtin-вызовов расширен буфер результатов до `max(builtinOutLen, dsts.len)`, чтобы не терять дополнительные возвращаемые значения в многоприсваивании. Итог: `nextvar.lua` теперь full pass (`OK`). Gate после шага: `coroutine.lua`/`calls.lua`/`db.lua`/`locals.lua`/`nextvar.lua` pass; открытый крупный блокер остаётся `files.lua:208` (и `gc.lua` на текущем таймауте).
- `2026-03-02`: Закрыт блокер `files.lua:208`. Для `coroutine.wrap(dofile)` убран повторный запуск скрипта при каждом resume: в thread runtime добавлен stateful entry-closure для `dofile`, а builtin-resume для `dofile` больше не идет через replay-path. Дополнительно в GC-marking thread добавлены ссылки на `wrap_repeat_closure` и `dofile_entry_closure`, чтобы cached-closure не терялась при сборке мусора. Gate после шага: `files.lua` pass, `coroutine.lua`/`calls.lua`/`db.lua`/`locals.lua`/`nextvar.lua` pass; открытый крупный блокер — `gc.lua` (timeout на текущем лимите).
- `2026-03-02`: Закрыт `gc.lua` timeout. Причина: tick-based GC был полностью выключен при наличии finalizable-объектов (`self.finalizables.count() != 0`), из-за чего циклы с аллокацией строк/замыканий в ожидании `__gc` могли зависать. Исправление: вернуть tick-based GC как fallback и не отключать его при finalizers. Итог: `gc.lua` проходит (`OK`) на текущем runtime, без регрессий в `coroutine.lua`/`calls.lua`/`db.lua`/`locals.lua`/`nextvar.lua`; `files.lua` сохраняет parity с ref (в sandbox может печатать `cannot open file '/dev/full'`).
- `2026-03-02`: Закрыты `events.lua` и `strings.lua` блокеры с ошибками вида `metamethod '...' is not callable (nil value)`. Корень: метаметод, явно установленный в `nil`, трактовался как "найденный и вызываемый". Исправление: `metamethodValue` теперь считает `nil`-значение отсутствием метаметода (как в PUC Lua). Gate после шага: `events.lua` pass, `strings.lua` pass; открытые крупные блокеры: `errors.lua:30`, `math.lua:1123`, `cstack.lua:109`.
- `2026-03-02`: Закрыт `errors.lua` блокер (`line 30`) без костылей: убрана ранняя coercion через `BinOp(+0)` в codegen numeric-for setup, чтобы ошибки типов в `for i = {}, ...` формировались в корректном контексте control-local (`initial value/limit/step`), как ожидает suite. При этом numeric-for parity сохранён за счёт runtime-coercion в `SetLocal` по `for_numeric_controls`. Gate после шага: `errors.lua` pass; сохранены pass по `nextvar.lua`, `coroutine.lua`, `calls.lua`, `db.lua`, `locals.lua`, `gc.lua`, `events.lua`, `strings.lua`. Открытые крупные блокеры: `math.lua:1123`, `cstack.lua:109`.

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
