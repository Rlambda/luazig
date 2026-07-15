# luazig

`luazig` — проект по переписыванию Lua на Zig с постоянной проверкой поведения против PUC Lua 5.5.0.

Цель не в том, чтобы написать похожий язык, а в том, чтобы постепенно прийти к drop-in совместимости с PUC Lua: тот же observable behavior на официальном test suite, честные ограничения, понятная архитектура и публичный Zig-facing API для embedding.

## Цели проекта

- Реализовать Lua 5.5.0 на Zig с поведением, максимально близким к PUC Lua.
- Проходить официальный upstream `testes/*.lua` без test-specific hacks и harness-обходов.
- Держать reference implementation рядом и сравнивать `ref` vs `zig` напрямую.
- Развивать публичный Zig embedding API, семантически близкий к Lua C API.
- Использовать актуальный system Zig как основной toolchain.
- При выборе архитектуры следовать PUC-first подходу, если он не ведёт к заведомо худшему решению.

## Текущий статус

Коротко: проект находится в pre-release / parity-focused состоянии.
Bytecode VM (`--vm=bc`) — единственный активно развиваемый backend (default).
IR VM (`--vm=ir`) заморожена: код компилируется и доступен для отладки, parity не поддерживается.

bc_vm проходит **29/29 test suites**: api, attrib, bitwise, bwcoercion, calls, closure, code, constructs, coroutine, cstack, db, errors, events, files, gc, gengc, goto, literals, locals, math, memerr, nextvar, pm, sort, strings, tpack, tracegc, utf8, vararg. Матрица запускается с upstream portable/soft prelude `_port=true; _soft=true`; тяжёлые ветки `constructs.lua` и `verybig.lua` дополнительно проверяются напрямую без `_soft`.

IR VM (frozen snapshot) проходила 32/33 suites. Результаты сохранены как reference.

Ограничения:

- bc_vm достиг функциональной parity (29/29 suites). Производительность всё ещё заметно ниже PUC Lua и не считается production-ready; отдельные Debug suites, например `math.lua`, близки к 60-секундному verification budget.
- IR VM доступна через `--vm=ir` для отладки, но не гарантируется от регрессий.
- C ABI shim остаётся smoke/compat слоем поверх Zig API.
- Production/drop-in статус пока не заявляется.

### Выполнено: итеративный bytecode dispatch loop (P15.13–P15.25)

Первоначальный host-recursive путь полностью устранён для активного bytecode
backend. Как и `luaV_execute`/`CallInfo` в PUC Lua, один dispatch driver
переключает heap-resident активации Lua, не сохраняя по Zig stack frame на
каждый Lua-вызов.

Что закрыто:

1. `Thread.bytecode_frames` хранит authoritative `BytecodeExecFrame`, а
   register/boxed stack, runtime frames и TBC list принадлежат тому же
   `Thread`. Переключение coroutine move'ит ownership этих буферов без копии.
2. `BytecodePendingCompletion` описывает post-call действия для обычных
   результатов, одиночных значений, сравнений, `__concat`, `string.gsub`
   replacement callbacks, debug hooks, `__close` и coroutine resume. Поэтому
   opcode или C-library bridge не требует вложенного `runBytecode` и не
   переигрывается после yield.
3. Через общий explicit stack выполняются обычные `CALL`/`TAILCALL`,
   `TFORCALL`, `pcall`/`xpcall`, Lua metamethods (`__index`, `__newindex`,
   арифметика, сравнения, `__len`, `__concat`, `__pairs`), Lua debug hooks,
   `string.gsub` replacement/`__index` callbacks и yielding `__close`.
4. Error unwind хранится как `BytecodeUnwindState` на coroutine. Yield или
   новая ошибка внутри `__close` продолжает тот же LIFO scan. Уникальный
   `activation_id` отличает заменённый child frame от нового frame с повторно
   использованным stack base.
5. Вложенный `coroutine.resume` использует один trampoline и приватный
   execution-layer сигнал `ThreadSwitch`: caller остаётся припаркованным в
   собственном explicit stack, а глубина цепочки coroutine больше не равна
   глубине Zig вызовов. Сигнал поглощается внутри trampoline и не входит в
   публичный `Vm.Error`/Zig API. Попытка resume предка остаётся обычной
   Lua-ошибкой, а не циклом trampoline.
6. Bytecode-активации при yield/resume больше не сериализуются и не
   replay'ятся: authoritative `BytecodeExecFrame` остаётся на `Thread`.
   `IrSuspendedFrame` сохранён только для замороженного IR compatibility-кода
   (включая `testC` closures/hooks, вызванные из bc VM); такой IR child связан с
   bytecode caller через pending continuation, но сам bytecode frame snapshot
   не создаёт.
7. Обёртка `std.Thread.spawn(.{ .stack_size = 256MB })` удалена. CLI работает
   на обычном process stack. Bytecode ограничивается собственными Lua-side
   лимитами frame/stack storage, а не native stack depth.

Постоянные регрессии:

- `tests/smoke/27_iterative_bytecode_calls.lua`;
- `tests/smoke/38_iterative_protected_dispatch.lua`;
- `tests/smoke/39_complete_iterative_dispatch.lua`;
- `tests/smoke/40_large_setlist_extraarg.lua`;
- `tests/smoke/41_strict_globals_env.lua`;
- `tests/smoke/42_gc_debt_and_generational_step.lua`;
- `tests/smoke/43_generational_minor.lua`;
- `tests/stress/iterative_dispatch.lua` через
  `tools/iterative_dispatch_stress.sh`.

Проверенный stress lane под `ulimit -s 1024`: 5000 обычных Lua-вызовов, 3000
вложенных `coroutine.resume` с yield/resume, 2000 рекурсивных metamethod
вызовов, 1000 вложенных `string.gsub` callbacks и mixed bytecode↔`testC` yield
для `CALL`/`TAILCALL`/`TFORCALL`. Полный `cstack.lua` также проходит при
1-МБ host stack. Zig unit tests и 44/44 differential smoke проходят. Все
заявленные 29 upstream suites завершаются успешно на bc VM; точные глубины
`C stack overflow` остаются implementation-defined, но semantic assertions
совпадают.

### Выполнено: tail-call policy с живыми `<close>` переменными (P15.25)

Предыдущий TODO исходил из неверного предположения, что PUC Lua всегда эммитит
`OP_TAILCALL` для `return f()` с живым TBC slot. В Lua 5.5 `retstat` делает
tail-call только при `!fs->bl->insidetbc`; при активной `<close>` переменной
остаётся обычный `CALL + RETURN`, чтобы caller пережил callee и затем закрыл
TBC chain. Бит `k` у `OP_TAILCALL` в `luaK_finish` относится к закрытию open
upvalues (`needclose`), а не разрешает уничтожить frame с живым TBC slot.

`codegen_bc.zig:hasActiveClose()` теперь учитывает и именованные `<close>`
locals, и скрытый четвёртый TBC slot generic-for. Поэтому `return f()` внутри
обоих видов scope сохраняет caller до завершения `f`, а затем выполняет close
ровно один раз. `39_complete_iterative_dispatch.lua` проверяет порядок для
обычного `<close>` local и generic-for iterator close value. Runtime
`BytecodeClosePost.retry_tailcall` остаётся для tailcall, где закрываются open
upvalues/остаточное runtime close-state, включая yield-safe продолжение.

### Выполнено: hardening после dispatch review (P15.26)

Повторно проверен blocker-кейс с ранним `return` из generic `for`: hidden TBC
iterator close value закрывается **после** вычисления return-expression. PUC Lua
и bc VM печатают `false  true`, а differential smoke
`39_complete_iterative_dispatch.lua` проходит без расхождений.

Внутренний coroutine control-flow отделён от публичной модели ошибок:
`ThreadSwitch` находится только в private `DispatchError`, поглощается
`driveBytecodeCoroutineTrampoline`, отсутствует в `Vm.Error`, а `api.zig`
больше не содержит специальной ветки для него. Рядом с
`BytecodePendingCompletion` зафиксированы invariants владения payload slices,
cleanup authority, yieldable continuation kinds и единственная разрешённая
точка thread switching.

После hardening и последующей regression-cleanup фазы повторно пройдены Zig
unit tests, 42/42 differential smoke, 1-МБ iterative-dispatch stress lane и
ровно заявленные 29/29 upstream suites по exit/assertion status.

### Выполнено: завершение regression cleanup после P15.26 (P15.27)

WIP-переход на полный iterative dispatch временно открыл несколько независимых
расхождений parser/codegen/debug runtime. Они исправлены на семантическом
уровне, без распознавания имён upstream-файлов или test-specific replay:

1. Bytecode codegen корректно эмитит большие `SETLIST + EXTRAARG`, поэтому
   `verybig.lua` проходит реальную ветку `testing large programs (>64k)`.
   Быстрый differential regression закреплён в
   `tests/smoke/40_large_setlist_extraarg.lua`.
2. Восстановлены lexical invariants для `goto`/labels, named vararg и Lua 5.5
   global attributes; устранены overflow/diagnostic-buffer ошибки на больших
   constant/register indices и syntax-error paths.
3. Source line metadata теперь хранит call/operator lines в AST и размечает
   loop backedges, многострочные expressions, synthetic register cleanup и
   `VARARGPREP` так же, как PUC-visible line table. Line hooks используют
   реальный previous-PC/previous-line state вместо удалённого preseed,
   завязанного на ожидаемый trace.
4. Debug-hook continuation явно владеет `saved_parent_callee` как GC root.
   Раньше full GC внутри hook мог освободить closure активного parent frame, а
   завершение hook возвращало dangling pointer в `RuntimeFrame.callee`.
   Threads теперь sweep'ятся раньше closures, чтобы parked frames не сохраняли
   даже промежуточные ссылки на уже освобождённые closure storage.
5. `load` инициализирует environment первого upvalue main closure независимо
   от наличия имени `_ENV`. Это сохраняет исполняемость stripped chunks, где
   debug names удалены, но bytecode/upvalue layout остаётся прежним.
6. `tests/smoke/31_debug_bytecode_parity.lua` расширен двумя регрессиями:
   GC внутри line hook сохраняет parent activation, а stripped main chunk
   получает рабочий environment.

Подтверждённые проверки для Zig 0.16.0:

- `zig build test -Doptimize=Debug` — PASS;
- differential smoke — 42/42 PASS;
- iterative dispatch stress под 1-МБ host stack — PASS;
- заявленная upstream matrix с `_port=true; _soft=true` и timeout 60 секунд на suite — 29/29 PASS;
- direct `constructs.lua` без `_soft` под `timeout 60` — `OK` (56.15 с в verification-контейнере);
- direct `verybig.lua` без `_soft` — `+`, `OK`.

### Выполнено: verifier follow-up и GC debt/performance hardening (P15.28)

После review P15.27 закрыты все замечания, мешавшие воспроизводимому принятию
патча:

1. Автоматический GC больше не запускает полный mark+sweep по фиксированному
   числу инструкций. Следующий цикл планируется от live-heap/debt после
   предыдущего, поэтому тысячи динамических `load()` не вызывают повторный
   полный scan растущего heap. Вместе с устранением лишних AST-аллокаций это
   довело неизменённый direct `constructs.lua` до 56.15 с в Debug и позволило
   пройти жёсткий `timeout 60`.
2. Короткие interned strings теперь учитываются в `gc_count_kb`. Раньше цикл,
   создающий только короткие строки, мог выделить сотни мегабайт, не увеличив
   automatic-GC debt; upstream `closure.lua` бесконечно ждал очистки weak
   table. Регрессия закреплена в
   `tests/smoke/42_gc_debt_and_generational_step.lua`.
3. В generational mode каждый явный `collectgarbage("step")` выполняет один
   атомарный цикл и возвращает `false`, как PUC в наблюдаемом API. Это
   сохраняет weak-table/barrier semantics при текущем collector без persistent
   young-generation phases и возвращает `gengc.lua` в green.
4. Публичный `runBytecode` возвращает только `Vm.Error`; приватный
   `runBytecodeInternal` локализует `DispatchError`/`ThreadSwitch` внутри
   execution layer.
5. Strict-global codegen больше не содержит списка имён stdlib. `_ENV` остаётся
   единственным специальным lexical mechanism, а `print`, `require` и прочие
   runtime globals должны быть объявлены по тем же правилам, что и
   пользовательские имена. Это проверяет
   `tests/smoke/41_strict_globals_env.lua`.
6. `lua-5.5.0/testes/time.txt` не является semantic fixture: это
   генерируемый `all.lua` cache времени предыдущего запуска. Matrix runner
   snapshot/restore'ит его, если файл присутствовал, и оставляет отсутствующим,
   если его не было в исходном дереве.

### Выполнено: настоящие инкрементальные GC phases (P15.29)

Debt-gate заменён persistent collector state machine, близкой к PUC
`gcstate`:

```text
pause -> propagate -> atomic -> sweep -> pause
```

1. `gc_step_active`, `gc_step_remaining_bytes`, `gc_in_cycle`,
   `resetGcStepDebt`, `gcStepBudgetBytes` и прежний deferred-full-cycle path
   удалены. Mark sets, gray queue, weak/finalizer queues, registry snapshots и
   sweep cursor теперь принадлежат `Vm` и сохраняются между вызовами
   `collectgarbage("step", n)`.
2. Каждый incremental step расходует реальный work budget
   `max(1, n * stepmul / 100)`: один work unit обрабатывает один gray object
   либо один registry entry sweep. Полный `collect` использует ту же машину,
   прокручивая её до `pause`, а не отдельный атомарный collector.
3. Mutable roots пересканируются между slices, но immutable VM roots,
   Proto/string caches и остальные долговечные registries обходятся только в
   начале цикла. Это устраняет повторный full-root scan в `load()`-heavy коде.
4. Table writes, metatable replacement, closure environment и upvalue writes
   получили conservative tri-color barriers. Ephemeron propagation выполняет
   fixpoint с drain persistent gray queue между проходами.
5. Sweep ограничен budget и удаляет registry entry до освобождения объекта.
   Reverse cursor + `swapRemove` сохраняют объекты, созданные после snapshot,
   и не оставляют dangling pointer в registry между slices.
6. Регистрация `__gc` отслеживается epoch-счётчиком: finalizable, добавленный
   после atomic-фазы текущего цикла, гарантированно запускает следующий цикл.
   Closing finalizers выполняются при `gc_busy=true`, поэтому teardown не
   допускает reentrant collection.
7. Добавлен unit regression
   `vm: incremental GC advances real phases and preserves barrier writes`.
   Он продвигает collector по одному work unit, наблюдает отдельные
   `propagate`/`sweep` slices, проверяет освобождение до завершения цикла и
   сохранение pre-cycle объекта, опубликованного в уже просканированную таблицу.

Подтверждённые проверки на Zig 0.16.0:

- `zig build -Doptimize=Debug` — PASS;
- `zig build test -Doptimize=Debug` — PASS;
- differential smoke — 42/42 PASS;
- iterative dispatch stress под 1-МБ host stack — PASS;
- upstream matrix с `_port=true; _soft=true` и timeout 60 с на suite —
  29/29 PASS;
- direct `constructs.lua` без `_soft` — 55.90 с, exit 0, `OK`;
- direct `verybig.lua` без `_soft` — 7.44 с, exit 0, `OK`;
- targeted GC/coroutine/debug suites (`gc.lua`, `gengc.lua`, `closure.lua`,
  `coroutine.lua`, `db.lua`) — PASS;
- `gc.lua` с matrix prelude `_port=true; _soft=true` — 1.85 с в Debug и
  0.54 с в ReleaseFast в verification-контейнере (критерии <5 с / <1 с
  выполнены).

Direct `constructs.lua` проходит заданный 60-секундный лимит в этом
контейнере, но запас составляет около четырёх секунд, поэтому это измерение,
а не гарантия времени на любой машине.

Atomic weak/finalizer transition пока остаётся одной indivisible work unit:
mark propagation и registry sweep инкрементальны, а операции, меняющие
наблюдаемую weak/finalizer семантику, завершаются внутри atomic boundary, как и
в PUC.

## Требования

- `zig` из system toolchain.
- C toolchain для reference Lua: `make`, `gcc` или совместимый compiler.
- Инициализированный upstream test suite submodule.

На Arch Linux:

```sh
sudo pacman -S --needed zig gcc make
```

Проверка Zig:

```sh
zig version
```

Инициализация submodule:

```sh
git submodule update --init --recursive
```

## Быстрый старт

Собрать reference Lua на C:

```sh
make lua-c
./build/lua-c/lua -v
```

Собрать Zig implementation:

```sh
zig build -Doptimize=Debug
./zig-out/bin/luazig --help
./zig-out/bin/luazigc --help
```

Запустить release gate:

```sh
tools/release_gate.sh
```

## Бинарники

Reference implementation:

- `./build/lua-c/lua`
- `./build/lua-c/luac`

Zig implementation:

- `./zig-out/bin/luazig`
- `./zig-out/bin/luazigc`

`--engine=ref` удалён. Для reference behavior нужно запускать `lua`/`luac` напрямую. `--engine=zig` оставлен как no-op для старых скриптов.

## Устройство проекта

Основные директории:

- `src/bin/` — CLI entrypoints: `luazig`, `luazigc`.
- `src/lua/` — реализация языка: lexer, parser, AST, IR, codegen, VM, stdlib, API shim.
- `src/util/` — общие utility wrappers, включая текущий Zig `std.Io` stdio layer.
- `lua-5.5.0/` — vendored PUC Lua 5.5.0 release: `src/` (reference C source, из которого собирается `build/lua-c/lua`/`luac` для differential-тестов) и `testes/` (upstream test corpus, завендорен из v5.5.0 tag).
- `tools/` — differential runners, release gate, perf tooling, heavy/OOM probes.
- `tools/perf/` — core perf baselines/current snapshots.

Основной runtime path:

- `src/lua/lexer.zig` читает source bytes и выдаёт tokens.
- `src/lua/parser.zig` строит AST.
- `src/lua/codegen_bc.zig` компилирует AST → bytecode (Proto).
- `src/lua/vm.zig:runBytecode()` исполняет bytecode на shared stack.
- IR path (`codegen.zig` → `runFunctionArgsWithUpvalues`) заморожен, доступен через `--vm=ir`.
- `src/lua/lower_ir.zig` и `src/lua/bc_vm.zig` disabled (старый experimental backend, будет удалён).
- `src/lua/api.zig` содержит публичный Zig-facing API и testC-facing compatibility layer.

## Устройство тестов

Тестовая стратегия основана на differential testing: один и тот же upstream Lua test запускается на PUC Lua и на `luazig`, затем сравниваются exit code и output.

Reference запускается напрямую:

- `build/lua-c/lua`
- `build/lua-c/luac`

Zig implementation запускается напрямую:

- `zig-out/bin/luazig`
- `zig-out/bin/luazigc`

Основные test lanes:

- `tools/run_tests.py` — targeted differential runner для одного или нескольких suites.
- `tools/testes_matrix.py` — пофайловая matrix по `lua-5.5.0/testes/*.lua`.
- `tools/testes_matrix_safe.sh` — matrix под memory/time wrapper, чтобы тяжёлые tests не убивали Codex/session.
- `tools/iterative_dispatch_stress.sh` — 1-МБ host-stack regression для call/metamethod/coroutine dispatch.
- `tools/testc_lane.py` — official `testC` lane через Lua test DSL.
- `tools/api_regression_lane.py` — Zig unit/integration tests + testC lane + targeted parity.
- `tools/perf_core_snapshot.py` — замер core perf suites.
- `tools/perf_guard_core.py` — защита от perf regressions относительно baseline.
- `tools/release_gate.sh` — единая команда для проверки release/readiness состояния.

Запустить targeted parity:

```sh
python3 tools/run_tests.py \
  --suite nextvar.lua \
  --suite coroutine.lua \
  --suite calls.lua \
  --suite files.lua \
  --suite locals.lua \
  --suite db.lua \
  --suite gc.lua
```

Запустить full safe matrix:

```sh
tools/testes_matrix_safe.sh
```

По умолчанию matrix запускает upstream tests с prelude:

```lua
_port=true; _soft=true
```

Это важно для интерпретации результата:

- `_port=true` отключает непереносимые OS/shell/locale/filesystem checks.
- `_soft=true` отключает или сокращает resource-heavy ветки official suite.
- `big.lua` в таком режиме не выполняет тяжёлую часть и сразу возвращает `'a'`:
  `if _soft then return 'a' end`.
- `verybig.lua` в таком режиме выполняет только RK-prefix и пропускает
  `testing large programs (>64k)`:
  `if _soft then return 10 end`.
- Поэтому `big.lua pass` в safe matrix означает **soft-mode parity**, а не полное
  standalone прохождение тяжёлого `big.lua`; аналогично `verybig.lua pass`
  означает, что large-program ветка не покрыта safe matrix.

Платформенная ветка `files.lua` (popen/execute, без `_port=true`) содержит
platform-dependent тесты: `sh -c 'kill -s HUP $$'` (line 814) падает одинаково
и в luazig, и в PUC Lua на этой системе (shell получает signal вместо ожидаемого
exit). Portable matrix (`_port=true`) для `files.lua` проходит идентично PUC Lua.
- Standalone `big.lua` без `_soft` не является корректным простым запуском:
  upstream файл содержит `coroutine.yield'b'` и в `all.lua` рассчитан на запуск
  через `coroutine.wrap(loadfile(...))`. При прямом запуске PUC Lua ожидаемо
  падает с `attempt to yield from outside a coroutine`; `luazig` должен совпадать
  с этим поведением/сообщением как отдельный quality item.

Корректные команды для сравнения soft matrix behavior:

```sh
./build/lua-c/lua -e '_port=true; _soft=true' lua-5.5.0/testes/big.lua
./zig-out/bin/luazig -e '_port=true; _soft=true' lua-5.5.0/testes/big.lua
./build/lua-c/lua -e '_port=true; _soft=true' lua-5.5.0/testes/verybig.lua
./zig-out/bin/luazig -e '_port=true; _soft=true' lua-5.5.0/testes/verybig.lua
```

Корректный способ проверить real `big.lua` path — запускать его через `all.lua`
без `_soft` либо отдельной coroutine-обвязкой, потому что именно так upstream
ожидает yield в конце файла:

```sh
cd lua-5.5.0/testes
/home/boss/codes/luazig/build/lua-c/lua -e '_port=true' all.lua
/home/boss/codes/luazig/zig-out/bin/luazig -e '_port=true' all.lua
```

Запустить matrix без wrapper, если окружение безопасно:

```sh
python3 tools/testes_matrix.py --no-build --timeout 120 --json-out /tmp/testes-matrix.json
```

Запустить API/testC lane:

```sh
python3 tools/api_regression_lane.py --timeout 180 --testc-timeout 120
```

Запустить perf snapshot и guard:

```sh
python3 tools/perf_core_snapshot.py --out /tmp/core-current.json --timeout 240
python3 tools/perf_guard_core.py \
  --baseline tools/perf/core_baseline.json \
  --current /tmp/core-current.json \
  --max-regression 0.15
```

## Release gate

Главная команда проверки текущего состояния:

```sh
tools/release_gate.sh
```

Gate выполняет:

- `zig build test -Doptimize=Debug`
- official `testC` lane
- targeted parity suites
- iterative dispatch stress под 1-МБ host stack
- full safe matrix
- core perf snapshot
- perf guard

Текущий ожидаемый результат gate: partial — bc_vm в разработке, большинство suites failing.

## План работ

Каждая итерация закрывает минимум один чекбокс ниже (см. `AGENTS.md`).
Дизайн фиксируется здесь же; отступления от PUC отмечаются явно.

### Активный шаг: PUC-faithful Table + string interning

Цель: закрыть главный parity/perf-блокер — `nextvar.lua` (~511× медленнее ref).
Дизайн (PUC-first): единый `Table` (array-part + hash-part с Brent's variation
chaining, см. `lua-5.5.0/src/ltable.c:13-24`) вместо текущих 4 карт, плюс
интернирование строк (аналог `lstring.c`). Строковые ключи сравниваются по
указателю на интернированную `LuaString`.

Зафиксированные отступления от PUC (Zig-идиомы):
- `Value` — tagged `union(enum)` вместо `TValue` (tag + union).
- `Node.next` — `?*Node` (читаемость); если perf-замер покажет, переключимся на
  `i32` offset как в PUC (cache-плотнее).
- `lastfree` — обычное поле на `Table`, а не C-хак `Limbox` перед массивом Node.

- [x] **Phase A: интернирование строк.** `Value.String` → `*LuaString`
  (header + inline bytes + cached hash). `StringIntern` HashSet на Vm с per-VM
  seed. Полная PUC string-lifecycle модель (вскрыта при отладке, изначальный
  план «интернировать всё» был неполным): short (≤ `LUAI_MAXSHORTLEN`=40) →
  глобальный intern, pointer-eq; long runtime (`rep`/`concat`/`format`) → свежая
  аллокация, content-eq; long литералы → compile-time dedup (отдельная
  `long_literals` таблица); `string.gsub` возвращает входной объект при отсутствии
  замен. Равенство — `luaStringEq` (lvm.c:600-624 + lstring.c:44-50). *Чекпоинт:*
  паритет 33/34, `zig_fail=0`, `zig build test` green, `memerr.lua` green.
  *Отставания:* GC sweep intern-таблиц и удаление `const_strings` вынесены в
  отдельные чекбоксы ниже (причины зафиксированы в
  `docs/superpowers/plans/2026-07-05-phase-a-string-interning.md`).
- [x] **Phase B1: инкапсулировать `Table` за внутренним API.** Выполнено в рамках B2
  (swap сделан напрямую через новый API, отдельная B1-стадия не потребовалась).
- [x] **Phase B2: swap `Table` на PUC array+hash.** `array: []Value` + `hash: []Node`
  + Brent chaining (`src/lua/ltable.zig`). Линейный `next()`, `luaS_eqstr`-стиль
  равенства, `value:=Nil` delete (без tombstones). Удалены `next_hint_*` (7 полей),
  `nextFrom*`/`nextFirstLive*` (~10 функций), `hash_tombstones`, `PtrKey`, 4 карты.
  *Паритет:* все 10 canary suite green (nextvar/sort/tpack/locals/calls/strings/
  db/gc/pm/literals); net −293 строк машинерии.
  *Perf (честно):* на Debug `nextvar` почти не сдвинулся (33s→29.5s) — bottleneck
  не таблицы, а debug-overhead + IR-VM interpreter. На ReleaseFast `nextvar`=1.48s
  (~23× от ref) — реальный оставшийся gap = скорость IR-VM (отдельная работа).
  `computesizes` (оптимальный array-sizing) не портирован — future optimization.

### Выполнено: настоящий generational GC (P15.30)

Generational mode больше не является compatibility-веткой, запускающей полный
incremental cycle на каждый `collectgarbage("step")`. Реализована отдельная
PUC-подобная young-generation модель поверх per-type registry luazig:

1. Все управляемые GC-типы (`Table`, `Closure`, `Thread`, `Cell`, managed
   `LuaString`) хранят возраст `NEW/SURVIVAL/OLD0/OLD1/OLD/TOUCHED1/TOUCHED2`
   и стабильный registry index. Удаление из registry использует swap-remove с
   обновлением индекса перемещённого объекта.
2. Nursery хранится в отдельных per-type списках; `OLD1`, remembered
   `grayagain`, remembered cells и old threads имеют собственные очереди.
   Minor collection обходит young snapshots и эти очереди, а не весь old heap.
3. Forward barrier продвигает young child старого closure/metatable/upvalue в
   `OLD0`; backward barrier переводит изменённый old owner в
   `TOUCHED1 → TOUCHED2 → OLD`. Barrier paths покрывают table writes, cells,
   closure environment, upvalue join/close и смену metatable.
4. Пережившие minor cycles переходят `NEW → SURVIVAL → OLD1 → OLD`. Weak
   tables, ephemerons, finalizable objects и threads обрабатываются с учётом
   поколения; старый weak container не удерживает недостижимый young value.
5. Накопленные bytes, ставшие old, переключают collector из minor mode в
   persistent incremental major cycle по `minormajor`; после major он
   возвращается в minor mode по `majorminor` либо продолжает incremental
   major cycles. Автоматический minor pacing использует `minormul`; все три
   параметра доступны через Lua 5.5 `collectgarbage("param", ...)`.
6. TestC `T.gcage` читает реальные возраста объектов, а `T.codeparam`/
   `T.applyparam` используют Lua 5.5 floating-byte encoding. Поэтому полный
   `gengc.lua --testc` проверяет upstream age/barrier transitions, а не
   подставленные ожидаемые строки.

Постоянный differential regression
`tests/smoke/43_generational_minor.lua` проверяет old→young barrier, вложенный
young graph, очистку young value из old weak table и параметры режима. Zig
unit tests дополнительно проверяют, что minor collection не сканирует
512-объектный old graph, и принудительный переход minor → major → minor.

Подтверждённые проверки на Zig 0.16.0:

- `zig build -Doptimize=Debug` и `zig build test -Doptimize=Debug` — PASS;
- differential smoke — 44/44 PASS;
- iterative dispatch stress под 1-МБ host stack — PASS;
- заявленная portable/soft upstream matrix — 29/29 PASS;
- `gengc.lua --testc` — `OK`;
- portable/soft `gc.lua` — 2.08 с Debug / 0.51 с ReleaseFast;
- direct `constructs.lua` без `_soft` — 53.94 с, `OK`;
- direct `verybig.lua` без `_soft` — 6.93 с, `OK`.

Архитектура не копирует intrusive `GCObject.next` списки PUC побайтово:
luazig сохраняет отдельные массивы указателей. Но поколения, remembered-set
инварианты, minor/major transitions и наблюдаемая Lua/TestC-семантика
соответствуют модели Lua 5.5.

#### Hotfix P15.30.1: automatic GC pace после `restart`

Прямой upstream `gc.lua` без `_port/_soft` выявил ошибку pacing, которую не
покрывала portable matrix. `collectgarbage("restart")` только включал флаг
collector, сохраняя старый post-cycle threshold; после достижения threshold
automatic GC выполнял лишь 64 object-work units раз на 20 000 table
allocations. В table-heavy цикле mutator поэтому создавал мусор быстрее sweep и
проверка pace после `long strings` не завершалась.

Исправление следует модели PUC Lua:

- `restart` сбрасывает allocation debt: следующая аллокация сразу получает
  возможность продвинуть GC;
- automatic incremental slice вычисляется из `stepsize × stepmul`; коэффициент
  20 компенсирует различие work units — PUC sweep обрабатывает до 20 объектов
  за один sweep step, тогда как `gcAdvance` luazig считает каждый объект
  отдельно;
- smoke `44_gc_restart_pace.lua` останавливает collector, накапливает garbage,
  включает его обратно и проверяет, что heap возвращается к live baseline, а
  не растёт без ограничения.

После hotfix: Debug build/unit tests, 44/44 differential smoke, 1-МБ dispatch
stress и `gengc.lua --testc` проходят; direct `gc.lua` завершается с `OK`
примерно за 5.4 с в текущем Debug-окружении.

### Открытые приоритеты

- [x] **IR VM заморожена, bc=default.** Default backend переведён на `--vm=bc`.
  IR VM (`--vm=ir`) сохранена как debug fallback, parity не поддерживается.
  `run_tests.py` и `testes_matrix.py` явно используют `--vm=bc`.
  `release_gate.sh` гоняет bc (большинство suites failing — прогресс-трекер).
  `zig build test` продолжает гонять IR unit-тесты (они тестируют shared runtime).
- [x] **Perf: IR-VM interpreter speed — закрыто как устаревшая цель.** IR VM
  заморожена и не является parity/perf target; профилирование bc_vm остаётся
  отдельным открытым пунктом после достижения parity.
- [x] **GC sweep-pass:** реализовать настоящий mark+sweep для всех объектов
  (tables/closures/threads/strings/cells). `gcCycleFull` теперь выполняет
  полный mark+sweep на всех точках: explicit `collectgarbage()`, tick-trigger
  (каждые 20000 инструкций), и allocation-trigger (через Handle API / temp
  roots). Все типы объектов sweep'ятся (P15.0–P15.7).

  **GC Phase (завершена):** per-type `ArrayList(*T)`-реестры на Vm
  заменяют PUC's intrusive `GCObject.next`-list (нулевая модификация layout
  типов, overhead идентичен — 1 указатель/объект). План:
  - [x] **GC registry infrastructure** — `gc_tables`/`gc_closures`/
    `gc_threads`/`gc_cells`/`gc_strings`; hook'нуты все 18 сайтов аллокаций
    (4 Table + 6 Closure + 4 Thread + 3 Cell + 1 runtime-long-string).
    `Vm.deinit`_drain'ит реестры как единственная точка владения для
    уничтожения объектов. Поведение неизменно; gc/gengc/tracegc + 8 canaries
    green.
  - [x] **Root-set completion + Table sweep** — `gcMarkVmRoots` добавляет
    VM-level metatables/threads/registries в корни; frame marking расширен
    (all locals, boxed cells, callee, env_override). `gcSweepTables` с
    in-place compaction + snapshot boundary. Sweep активен только на
    safe points (explicit `collectgarbage()`) и вне debug hooks.
    Ограничение: regs не mark'ятся (нет register-top tracking → нельзя sweep
    mid-expression); register-top planned для следующей итерации.
  - [x] **Closure/Thread/Cell sweep** — `gcSweepClosures`/`gcSweepThreads`
    с той же compaction+snapshot pattern. Closure: destroy struct только
    (upvalues ownership ambiguous). Thread: `freeThreadWrapBuffers` + aux
    free + destroy. Cell sweep отложен (требует `marked_cells` tracking).
    gc/gengc/tracegc/api/coroutine/db/nextvar + 8 canaries green.
  - [x] **Register-top tracking (live_regs)** — backward liveness analysis
    в codegen (`ir.computeLiveRegs`): per-PC bitset живых регистров
    (fixpoint iteration для loops). GC mark'ит только live регистры через
    `live_regs[pc * num_values + reg]`. Включает tick-trigger sweep
    (между инструкциями builtins уже вернулись, регистры точно track'ятся).
    Allocation-trigger sweep остаётся `do_sweep=false` (Zig locals внутри
    builtins невидимы GC). Cell sweep и string sweep отложены.
  - [x] **Real memory accounting** — `gc_count_kb` charge на alloc
    (`@sizeOf(Type)` для Table/Closure/Thread/Cell/String), discharge на sweep
    (actual bytes freed). Удалён фейк `gc_count_kb = 0.0` reset.
    `collectgarbage("count")` возвращает реальный размер.
  - [x] **String sweep** — `gcSweepStrings` для runtime long strings
    (`gc_strings` registry). Mark phase traverse'ит `Value.String` через
    worklist (`.String` case в `gcMarkValue`). String keys in hash nodes
    coordinated with dead-key handling (PUC-like `DEADKEY` model). Source
    strings from `load(string)` pinned как GC roots (`pinned_source_strings`).
    Long literals sweep'ятся через `long_literals.sweep()`. Short strings
    (`string_intern`) сейчас снова НЕ sweep'ятся — см. ограничение ниже.
  - [x] **Cell sweep** — `gc_marked_cells` set (Vm-level, как
    `gc_marked_strings`). Mark'ится при traversal closures' upvalues и
    frames' boxed/upvalues. `gcSweepCells` frees unmarked cells.
  - [x] **Long literal sweep** — `StringIntern.sweep` для `long_literals`:
    удаляет unreachable entries из intern table. Short strings
    (`string_intern`) остаются pinned/eternal до появления Proto-owned
    constant roots.

  **Оставшиеся ограничения:**
  - **Short string intern sweep временно отключён.** `string_intern.sweep()`
    был включён в P15.8, но `all.lua` показал UAF после последовательности
    `gc.lua -> db.lua`: debug hook вызывает `collectgarbage()`, затем
    `string.gsub` получает pattern как `Value.String`, указывающий на уже
    освобождённую short string. Это не проблема `gsub` как такового, а
    отсутствие PUC-инварианта: в PUC Lua строковые константы являются частью
    `Proto->k` и mark'ятся как GC roots. У нас IR пока хранит string lexemes
    как slices/source references и материализует `ConstString` лениво через
    `internStr`/`internLiteral`; не все такие materialized constants имеют
    стабильного владельца, который GC гарантированно mark'ит через
    debug-hook/continuation edges. Поэтому short strings пока pinned как
    глобальный intern table.
  - Чтобы честно включить `string_intern.sweep()` снова, нужно перейти к
    PUC-like ownership для строковых констант: при load/codegen создать
    decoded constant pool (`*LuaString`) внутри IR/Proto/function object,
    mark'ить этот pool в GC traversal для Closure/Function/Proto roots,
    убрать ленивое decode/intern из hot execution path, и только после этого
    разрешить sweep short-string intern table. Критерий включения: `all.lua`,
    `gc.lua`, `db.lua`, `strings.lua`, `coroutine.lua`, `calls.lua` и full
    matrix проходят с `string_intern.sweep()` включённым.
  - ~~Allocation-trigger sweep disabled~~ — **закрыто в P15.7**: Handle API (temp
    roots) защищает Zig-local temporaries в builtins; `allocTable` self-protect'ит
    return value; 4 CRITICAL multi-alloc site'а защищены (ensureDebugRegistry,
    builtinTestcMakeCfunc, pushcclosure, builtinDebugGetinfo); dead registers
    очищаются перед sweep (предотвращает dangling pointers в debug.getlocal).
  - ~~`in_debug_hook` guard~~ — **закрыто в P15.7**: sweep больше не подавляется
    внутри debug hooks; `debug_transfer_values` явно mark'ятся в `gcMarkVmRoots`.
  - **Short strings eternal / pinned** — **снова открыто после P15.8 audit**:
    `err_obj` + `gmatch_state` mark'ятся корректно, но этого недостаточно.
    Не хватает Proto-owned decoded string constant roots; поэтому
    `string_intern.sweep()` отключён до архитектурного шага с constant pool.
  - [x] **Real memory accounting** — закрыто в P15.4: `gc_count_kb` charge/discharge
    на alloc/sweep.
  - [x] **String sweep** — закрыто в P15.5: `gcSweepStrings` + `gcMarkValue`
    traverse `Value.String`; координация с `string_intern`/`long_literals`.
- [x] **Убрать `const_strings`/`internConstString`** — **закрыто в P15.8**: 32 call
  site'а мигрированы на `internStr`/`internLiteral`; третий string store удалён.
- [ ] Закрыть `heavy.lua` memory/perf gap PUC-first способом (после bc_vm parity).
- [x] Профилировать bc_vm после достижения parity — ReleaseFast snapshot обновлён в P15.22 (`tools/perf/core_current.json`).
- [ ] Развивать публичный Zig embedding API после стабилизации bc_vm.
- [x] Держать README, release gate и perf baselines актуальными после текущей GC/string фазы.
- [x] Закрыть verifier follow-up P15.28: direct `constructs.lua` <60 с, 29/29 matrix, short-string GC debt и generational step regression.

### Housekeeping (до или параллельно с Phase A)

- [x] Убрать отладочный `*.lua`-мусор в корне репо (`debug_special_case.lua`,
  `final_*.lua`, `isolate_failure.lua` и т.п.) — `debug_special_case` нарушает
  запрет AGENTS.md на `special_case_*`.
- [x] Запушить локальные коммиты в `origin/master`.

## История закрытых фаз

- P3: стабилизация базы до API; targeted parity suite, `bc_vm` coverage gate, perf guard и runtime invariant audit.
- P4: начальный публичный Zig API и базовый C ABI shim.
- P5: `testC/ltests` compatibility до прохождения `api.lua --testc`.
- P6: official `testC` lane; missing commands сведены к нулю.
- P7: расширение Zig/C-like API для `testC`, generic `T.testC` команды переведены на API-входы.
- P8: базовая official suite compatibility до `33/34 pass parity`, `zig_fail=0`.
- P9: публичный Zig embedding API отделён от VM internals.
- P10: readiness report, release gate, честная классификация blockers.
- P11: OOM/error-object fixes и первые PUC-first perf/memory шаги.
- P12: full migration на актуальный system Zig и успешный release gate на system toolchain.
- P13: интернирование строк (Phase A) — `Value.String` → `*LuaString`, полная PUC short/long/literal семантика, `luaStringEq`, gsub-reuse. Паритет 33/34 сохранён.
- P14: PUC-faithful Table (Phase B) — единый array+hash с Brent chaining (`ltable.zig`), удалены 4 карты/`next_hint_*`/tombstones (−293 строк). Паритет canaries green. Perf-цель `nextvar ≥10×` на Debug не достигнута: реальный bottleneck — debug-overhead + IR-VM interpreter (RF nextvar=1.48s, ~23× от ref).
- P15.0: GC registry infrastructure — per-type `ArrayList(*T)`-реестры на Vm (`gc_tables`/`gc_closures`/`gc_threads`/`gc_cells`/`gc_strings`); hook'нуто 18 сайтов аллокаций; `Vm.deinit` drain'ит реестры (единственная точка владения). Replaces PUC intrusive `GCObject.next`-list без модификации layout типов. gc/gengc/tracegc + 8 canaries green.
- P15.1: GC root-set completion + Table sweep — `gcMarkVmRoots` (metatables, threads, dump_registry, debug_upvalue_ids); expanded frame marking (all locals, boxed cells, callee, env_override); `gcSweepTables` с in-place compaction + snapshot boundary. Sweep только на safe points (explicit `collectgarbage()`, вне debug hooks). gc/gengc/tracegc/api/coroutine/db/nextvar + 8 canaries green.
- P15.2: GC Closure/Thread sweep — `gcSweepClosures` (destroy struct, upvalues not freed), `gcSweepThreads` (freeThreadWrapBuffers + destroy). Cell sweep deferred (marked_cells tracking needed). Same safe-point constraints. All 15 suites green.
- P15.3: Register-top tracking — `ir.computeLiveRegs` (backward liveness, fixpoint for loops, per-PC bitset). `Frame.pc` updated in dispatch loop. GC marks only live registers via `live_regs[pc*nv+reg]`. Enables tick-trigger sweep (between instructions). Allocation-trigger sweep stays disabled (Zig locals invisible). All 15 suites green.
- P15.4: Real memory accounting — `gc_count_kb` charged on alloc (`@sizeOf(Type)` for Table/Closure/Thread/Cell/String), discharged on sweep (actual bytes). Removed fake `= 0.0` reset. Strings not charged (sweep deferred). All 15 suites green.
- P15.5: String sweep — `gcSweepStrings` for runtime long strings. `gcMarkValue` traverses `Value.String` via worklist. String keys in hash nodes conservatively marked (keyEq dereferences). Source strings from `load(string)` pinned as roots. Short strings / long literals remain eternal. All 15 suites green.
- P15.6: Cell sweep + long literal sweep — `gc_marked_cells` set (marked during closure/frame traversal). `gcSweepCells` frees unmarked cells. `StringIntern.sweep` removes unreachable long literals from intern table. Short strings remain eternal. All 15 suites green.
- P15.7: Handle API (temp roots) — allocation-trigger sweep enabled, `in_debug_hook` guard removed. `gc_temp_roots: ArrayList(Value)` + `TempRoots` scope helper (snapshot/restore, analog of PUC Lua `L->stack` for Zig locals). GC mark phase traverses temp roots + `debug_transfer_values` in `gcMarkVmRoots`. 4 CRITICAL multi-alloc sites protected (ensureDebugRegistry, builtinTestcMakeCfunc, pushcclosure, builtinDebugGetinfo). `allocTable` self-protects return value. Dead registers cleared before sweep (prevents dangling pointers in debug.getlocal's for-state detection). All 15 suites green.
- P15.8: `const_strings` removal + short-string sweep attempt — `const_strings`/`internConstString`/`internConstStringMaybeOwned` fully removed; 32 call sites migrated to `internStr`/`internLiteral`; third parallel string store eliminated. `err_obj` + `gmatch_state.{s,p}` marked as GC roots. Follow-up all.lua audit found that enabling `string_intern.sweep()` is premature without Proto-owned decoded constant roots; short-string sweep is disabled again, while long literal sweep remains enabled. ReleaseFast matrix after fix: 32/33 pass parity, `zig_fail=0`, only `heavy.lua` both-fail timeout. Speed checkpoint: full matrix 3:34.71 wall; `all.lua` RF 5.16s vs PUC 0.416s (~12.4x); `nextvar.lua` RF 1.342s vs PUC 0.038s (~35x).
- P15.9: bc_vm weak table pruning — `codegen_bc.resetRegs` теперь использует `peak_freereg` (high-water mark регистра за statement) вместо `freereg`, чтобы LOADNIL покрывал все временные регистры включая аргументы CALL и темпы от конструирования таблиц. Раньше `genCall` уменьшал `freereg` до `func_reg` после 0-result CALL, и `resetRegs` не очищал регистры аргументов — stale pointer'ы выживали GC и блокировали pruning weak table entries. `peak_freereg` обновляется в `reserveRegs` и в прямых присваиваниях `freereg` (method call self-reg, vararg explist). gc.lua "weak tables" section проходит. All 15 suites green.
- P15.10: `local _ENV` shadowing в codegen — `local _ENV = ...` теперь корректно затеняет `_ENV` upvalue для своего scope, как в PUC Lua `singlevar()`. Раньше все global-доступы (read/write, global decls, global func decl, assignment) всегда шли через `ensureEnvUpvalue()` + `GETTABUP`/`SETTABUP`, игнорируя локальный `_ENV`. Добавлены `emitGlobalGet`/`emitGlobalSet`: если `_ENV` разрешается как local, индексируется регистр (`GETFIELD`/`SETTABLE`, с `GETTABLE`/`SETTABLE` fallback для kid>255), иначе — старый upvalue-путь. Все 6 global-access сайтов переведены на хелперы. Тест `local _ENV <const> = 11; X = "hi"` → `attempt to index a number value` проходит. 16 parity suites green.
- P15.11: `errors.lua` parity для bytecode VM — stripped `string.dump(f, true)` теперь сохраняет исполняемый `Proto` graph и удаляет только debug metadata; bytecode dispatch обновляет `Frame.current_line`, а `debug.getinfo(..., "l")` использует bytecode lineinfo без IR/path compensation. Арифметические type errors приведены к PUC-форме `attempt to perform arithmetic on a <type> value`. Добавлен differential smoke для stripped round-trip, nested Proto/upvalue, error text и current line. `errors.lua` и все smoke tests проходят.
- P15.12: `coroutine.lua` parity для bytecode VM — bytecode frames сохраняют continuation state и TBC-регистры через `yield/resume`; аварийное и принудительное закрытие выполняет все `__close` в LIFO-порядке с передачей последнего error object; возвраты и tail calls закрывают живые TBC slots; call/line/return hooks сохраняют позицию через suspension. `coroutine_resume` добавлен в `builtinHasDynamicOutCount` — fix утечки nil в vararg-контекстах. `luazig.zig`: thread spawn 256MB stack вместо setrlimit. Добавлены differential smoke тесты (25, 26). `coroutine.lua` проходит; project matrix — 24/29. Текущая архитектура host-recursive dispatch loop — технический долг, см. TODO выше.
- P15.13: iterative bytecode call frames, этап 1 — введён явный стек `BytecodeExecFrame`; обычные Lua-to-Lua `OP_CALL` push'ят дочерний frame без рекурсивного вызова Zig-функции, а `OP_RETURN*` pop'ят его и продолжают родителя. Изначально owner'ом списка был отдельный вызов `runBytecode`; P15.21 переносит ownership в `Thread`. Yield/error unwind проходит explicit frame stack сверху вниз и сохраняет совместимость с текущими coroutine snapshots. Добавлен smoke `27_iterative_bytecode_calls.lua` (350 non-tail calls). Подтверждено, что `pcall`/`xpcall`, metamethod и nested-resume re-entry остаются следующим этапом; 256MB stack пока не удалён. Unit tests, 27/27 smoke, `calls.lua`, `coroutine.lua`, `errors.lua` и прежние parity suites проходят.
- P15.14: fixed-width multi-results from method calls — `genMethodCall` теперь обновляет `freereg` по фактическому `nresults`, как обычный `genCall`. Раньше assignment в уже объявленные переменные (`a, b = object:method()`) после корректного `CALL C>1` затирал результаты со второго onward инструкциями `LOADNIL`. Добавлен differential smoke `28_method_call_fixed_multiret.lua`; `files.lua` проходит targeted parity.
- P15.15: native platform I/O — добавлены `io.popen`/`pclose`, `os.execute`/`os.exit`, PUC-compatible process result triples, последовательный pipe I/O через `std.process` и `std.Io`, `arg[-1]` для пути интерпретатора, POSIX `%Ex`/`%Oy` и проверки representable range в `os.date`/`os.time`. Добавлен differential smoke `29_platform_process_io.lua`. Portable matrix (`_port=true`) для `files.lua` проходит идентично PUC Lua. Non-portable section (без `_port=true`) имеет известный platform-dependent failure на line 814 (`sh -c 'kill -s HUP $$'` — ожидается `"exit"`, возвращается `"signal"`), одинаковый с PUC Lua на этой системе. Общий счёт остаётся 25/29.
- P15.16: `locals.lua` parity для bytecode VM — `LocVar` хранит точный register/range, поэтому `debug.getinfo` различает реальные bytecode closures вместо общего `bc_dummy_func`; OP_TBC валидирует non-closable значения при активации и сообщает имя local; return hooks больше не дублируются. Yielding error-unwind сохраняет последний error object между `__close`, а `return f()` с живым TBC компилируется как CALL+RETURN, не TAILCALL. Forward `goto` теперь резервирует patchable CLOSE и при выходе из scope учитывает скрытый generic-for TBC slot `base+3`, предотвращая stale TBC register после nested-loop goto. Добавлен differential smoke `30_locals_tbc_unwind.lua`; `locals.lua` проходит, project matrix — 26/29.
- P15.17: `db.lua` parity для bytecode VM — debug metadata теперь использует точные `lastlinedefined`/active-line ranges, call-operand name inference и реальные bytecode closures, включая main chunk. Varargs вынесены из расширяемого register frame в отдельное владение кадра, поэтому multiret/grow больше не повреждает `debug.getlocal(..., -n)`. Реализованы count hooks на bytecode dispatch, suspended-coroutine `getinfo/getlocal/setlocal`, transfer metadata, `for iterator`/metamethod names и nil-line hook для stripped chunks. Исправлен debug temporary scan для frame >256 регистров. Добавлен differential smoke `31_debug_bytecode_parity.lua`; `db.lua` и `constructs.lua` проходят, project matrix — 28/29.
- P15.18: debug LocVar cleanup — generic-for и numeric-for записывают PUC-совместимые скрытые `"(for state)"` slots в `Proto.locvars` на этапе bytecode codegen, устраняя потребность в runtime-эвристике. Bytecode `getlocal`/`setlocal` используют реальные LocVar range/register metadata. Для count-hook compatibility filters (IR и bytecode) добавлен TODO с критерием удаления и дедлайном до 1.0.0. Добавлен smoke `32_for_loop_locvars.lua`.
- P15.19: PUC-faithful `os.clock` — удалён deterministic stub, всегда возвращавший `0.0`. `os.clock()` теперь читает process CPU clock через `std.Io.Clock.cpu_process`, соответствуя семантике C `clock()` в PUC Lua без libc fallback. Добавлен differential smoke `33_os_clock_cpu_time.lua`; `sort.lua` печатает реальное время сортировки.
- P15.20: `gc.lua` parity — автоматический bytecode GC tick теперь уважает `collectgarbage("stop")`; explicit `collect`/`step` работают при остановленном сборщике, не меняя running-state. Step использует memory-sized work budget (`gcStepBudgetBytes`), поэтому больший `n` завершает цикл за меньшее число вызовов. Полный `gc.lua` побайтно совпадает с PUC Lua. Текущий step scheduler завершает mark/sweep атомарно после исчерпания budget; TODO `gc-incremental-phases` требует заменить его настоящими persistent mark/propagate/sweep phases до 1.0.0. Добавлен smoke `34_gc_stop_and_step.lua`. Project matrix — 29/29.
- P15.21: thread-owned bytecode frame stack — `BytecodeExecFrame` и `BytecodePendingCall` вынесены в thread-level runtime model, а authoritative descriptor stack перенесён из локальной переменной `runBytecode` в `Thread.bytecode_frames`. Каждый вход в `runBytecode` фиксирует boundary depth и на return/error освобождает только свой suffix; это сохраняет один owner при re-entry через `pcall`/`xpcall`, metamethod и nested `coroutine.resume`. Legacy `SuspendedFrame` snapshots пока сохранены, поэтому основной TODO не закрыт: следующий этап — per-thread register/TBC ownership и resume непосредственно из сохранённого frame stack. Добавлен smoke `35_thread_owned_bytecode_frames.lua`; unit tests, 35/35 smoke, ключевые parity suites и recursion guard проходят.
- P15.22: thread-owned runtime stacks — runtime `Frame`, bytecode register/boxed buffers, stack top и TBC list перенесены в `Thread`. VM держит только borrowed hot-path view активного потока; `coroutine.resume` паркует caller и активирует callee move-only операциями без копирования. GC traversal mark'ит parked runtime stacks и frame upvalues, поэтому nested coroutine может запустить sweep без потери значений caller'а. Добавлен smoke `36_thread_owned_runtime_stacks.lua`; unit tests, 36/36 smoke и ключевые parity suites проходят. Попытка сразу оставить live frames на месте при yield выявила обязательный следующий шаг: yielding `__close`/metamethod path всё ещё требует explicit dispatch continuation, поэтому legacy `SuspendedFrame` пока не удалён. ReleaseFast snapshot после parity: nextvar 1.37s, coroutine 0.12s, gc 1.12s в текущем окружении.
- P15.23: direct bytecode yield continuation — обычный `OP_CALL`/`OP_TAILCALL` к `coroutine.yield` на корневой границе bytecode dispatch оставляет `BytecodeExecFrame`, register/boxed buffers и TBC list в thread-owned storage вместо копирования в `SuspendedFrame`. `resume` продолжает тот же parked frame и записывает resume values в исходный CALL; debug API читает parked runtime frame, а GC/teardown сохраняют его как обычный Thread root. Архитектурный unit test проверяет, что после yield `suspended_frames` пуст и authoritative `bytecode_frames` остаётся жив; smoke `37_inplace_bytecode_yield.lua` покрывает nested/tail yield, debug inspection, GC и abandoned coroutine. Compatibility boundary имеет TODO удаления до 1.0.0; snapshots остаются только для re-entrant protected/metamethod/hook/`__close` paths.
- P15.24: iterative protected dispatch — bytecode targets `pcall`/`xpcall` и bytecode error handlers больше не вызывают вложенный `runBytecode`. Protected state (saved error, handler phase/depth and result continuation) хранится в `BytecodePendingCall`; общий dispatch loop ловит runtime error, unwind'ит только failed child suffix и продолжает ближайший protected caller. Yield внутри protected call сохраняет тот же thread-owned frame stack. `TFORCALL` к bytecode-итератору также переведён на explicit child frame. Teardown abandoned coroutine освобождает parked protected state без подмены текущей ошибки VM. Исправлена обнаруженная этим переходом dangling-ссылка в builtin `error()`: fallback теперь копирует сообщение в стабильный VM buffer. Smoke `38_iterative_protected_dispatch.lua` покрывает глубокие обычные и tail-position `pcall`/`xpcall`, yield/resume, Lua iterator и сборку abandoned protected coroutines; explicit protected depth принадлежит конкретному `Thread`, поэтому parked coroutines не делят глобальный лимит. Unit tests, 38/38 smoke и `calls.lua` с 1-МБ host stack проходят. Открыты metamethod/hook/`__close`/nested-resume actions.
- P15.25: complete iterative bytecode dispatch — Lua metamethods, debug hooks, yielding `__close`, nested `coroutine.resume` и `string.gsub` Lua callbacks переведены на `BytecodePendingCompletion`/thread-owned continuations. Persistent unwind продолжает close chain после yield и ошибок; coroutine trampoline переключает parked `Thread` через `ThreadSwitch` без Zig recursion. Bytecode snapshot/replay удалён; `IrSuspendedFrame` остался только у frozen IR compatibility children и связан с bc caller через explicit pending continuation. Удалён 256-МБ interpreter thread stack. `hasActiveClose()` синхронизирует tail-call policy с PUC Lua для named и generic-for TBC slots. Добавлены smoke `39_complete_iterative_dispatch.lua` и 1-МБ stress lane. Unit tests, 39/39 smoke, полный `cstack.lua` под 1-МБ stack и 29/29 upstream suites по exit/assertion status проходят.
- P15.26: dispatch review hardening — повторно подтверждён PUC-order hidden generic-for TBC (`return` expression вычисляется до iterator `__close`, результат `false true`); `ThreadSwitch` удалён из публичного `Vm.Error` и локализован в private `DispatchError`/coroutine trampoline; `api.zig` больше не знает о внутреннем сигнале. Рядом с pending continuation state документированы ownership, cleanup, yield и thread-switch invariants. После рефакторинга повторно проходят unit tests, 39/39 smoke, 1-МБ stress lane и 29/29 upstream suites.
- P15.27: завершение regression cleanup после iterative dispatch — исправлены large `SETLIST + EXTRAARG`, lexical `goto`/global-attribute/named-vararg semantics, source line tables и PUC-like line-hook `oldpc`; удалён trace preseed. `saved_parent_callee` debug-hook continuation добавлен в GC roots, а stripped `load` всегда инициализирует первый environment upvalue. Расширен smoke `31_debug_bytecode_parity.lua`; `40_large_setlist_extraarg.lua` закрепляет `verybig` codegen. Подтверждены unit tests, 40/40 smoke, 1-МБ stress, 29/29 upstream matrix и direct `verybig.lua`.
- P15.28: verifier follow-up — dynamic `load()`/automatic-GC scheduling переведены с fixed instruction cadence на live-heap debt, короткие interned strings включены в memory accounting, а explicit generational step выполняет атомарный цикл с PUC-compatible `false` result. `runBytecode` скрывает private dispatch signal, strict-global codegen не знает имён stdlib, `time.txt` сохраняется через snapshot/restore. Добавлен smoke `42_gc_debt_and_generational_step.lua`; подтверждены 42/42 smoke, 29/29 soft/portable matrix, direct `constructs.lua` <60 с и direct `verybig.lua`.
- P15.29: persistent incremental GC — collector хранит `pause/propagate/atomic/sweep` state, gray queue, mark sets и sweep cursors между `collectgarbage("step", n)`; mark/sweep расходуют реальный bounded budget, mutable roots и write barriers сохраняют tri-color invariant, а registry entries удаляются до освобождения объекта. Исправлены finalizer epoch/reentrancy и escaping main-chunk `_ENV` ownership. Unit regression наблюдает отдельные phases и barrier writes. Подтверждены Debug build/tests, 42/42 smoke, 1-МБ stress, 29/29 upstream matrix, direct heavy tests и `gc.lua` 1.85 с Debug / 0.54 с ReleaseFast.
- P15.30: настоящий generational GC — добавлены PUC-like object ages, per-type nursery, OLD1/remembered/old-thread queues, forward/back barriers и young-only sweep. Minor collections больше не вызывают полный incremental cycle и не обходят обычный old heap; `minormul/minormajor/majorminor` управляют minor → incremental major → minor transitions. `gengc.lua --testc` читает реальные age states; добавлен smoke `43_generational_minor.lua`. Hotfix P15.30.1 сбрасывает automatic-GC debt при `restart`, масштабирует automatic slice по PUC sweep granularity и добавляет `44_gc_restart_pace.lua`; direct `gc.lua` без `_soft` снова завершается. Подтверждены 44/44 smoke, 29/29 matrix, GC suites, 1-МБ stress и direct heavy tests.

Детальная история оптимизаций, промежуточных замеров и закрытых подпунктов сохранена в Git (`git log`).
