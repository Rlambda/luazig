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

- bc_vm достиг функциональной parity (29/29 suites), но производительность пока существенно ниже PUC Lua. Свежий ReleaseFast baseline показывает геометрическое среднее отставание **3.47×** на representative-наборе; calls/hash/array отстают сильнее всего. Подробный профиль и поэтапный roadmap приведены в разделе «Производительность относительно PUC Lua 5.5».
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

Текущий ожидаемый результат gate для bc VM: green по correctness lane — build/unit, official testC, differential smoke, iterative-dispatch stress и 29/29 portable/soft upstream matrix. Performance guard пока служит regression gate, а не подтверждением parity с PUC Lua.

## Производительность относительно PUC Lua 5.5

Функциональная parity не означает performance parity. На текущем состоянии
(bc VM после P15.30.1, оптимизации P15.31–P15.39) геометрическое среднее
замедления от PUC Lua **3.47×** на microbench (см. P15.37 baseline
`tools/perf/baseline-p15.37.json` для точной разбивки по workload'ам). Раздел фиксирует измеренный baseline,
известные причины и порядок оптимизаций. Он является частью проектного контракта:
performance-задачи нельзя закрывать только локальным улучшением одного benchmark
без проверки общего профиля и correctness gates.

### Методика профилирования

Дата базового замера: 2026-07-14. Сравнивались:

- luazig, Zig 0.16.0, `ReleaseFast`, `--vm=bc`;
- PUC Lua 5.5, собранный из vendored `lua-5.5.0`;
- один и тот же CPU через `taskset -c 0`;
- медиана 3–5 прогонов коротких изолированных workloads;
- `/usr/bin/time` для max RSS;
- ptrace IP sampling с символизацией через `llvm-symbolizer`;
- временная opcode instrumentation для подсчёта dispatch-инструкций;
- A/B-сборки, где менялась только одна деталь.

Обычный Linux `perf` в verification-контейнере недоступен: старое ядро 4.4
возвращает `ENODEV` из `perf_event_open`. Поэтому baseline не содержит hardware
counters (`cycles`, IPC, branch misses, LLC misses). При запуске на современном
ядре roadmap P15.37 должен дополнить существующие измерения настоящими
`perf stat`/`perf record`, но отсутствие counters не мешает уже сейчас
разделить codegen, dispatch, allocator, table layout и compiler pipeline.

### P15.36 perf-based hotspot analysis (современное ядро, perf 7.1)

После P15.36 замеры на современном ядре 7.0.11-arch1 (CPU hybrid atom/core,
`taskset -c 0`, ReleaseFast build) дали первую аппаратную картину. Геометрическое
среднее замедления упало с **11.9× (baseline P15.30.1)** до **5.21×**.
После P15.37 (hotspot-driven fixes) — **4.77×** (см. `tools/perf/baseline-p15.37.json`).
После P15.38a–d (codegen opcode reduction) — **3.69×**.
После P15.38e (PendingCallSlot.get() copy elimination) — **3.74×** (within noise; lua_calls -3%, memcpy eliminated).
После P15.38f (debug hook fast path) — **3.71×** (lua_calls -8.9%, debug hook overhead eliminated).
После P15.38g (GETTABLE/SETTABLE fast path) — **3.53×** (array_access -34.6%, hash_access -31.9%).
После P15.38h (tostring stack-buffer) — **3.43×** (string_loop -9.9%, heap alloc eliminated).
После P15.38i (PUC-style builtin results on bc_stack) — **3.42×** (hash_access -4.6%, array_access -4.4%).
После P15.39 (variant TKey, Node 48B→32B) — **3.47×** на microbench (cache плотность
не помогает tiny tables, см. P15.39); **-14% wall / -83% LLC misses** на 100K-key hash.

Сводная таблица по hotspot-функциям на worst-абсолютных/множительных workloads
(`perf record --call-graph lbr`, percent-limit 1). Колонка «P15.37 fix» показывает,
какая задача закрыла hotspot:

| Workload | Worst hot symbol | Доля до P15.37 | P15.37 fix | Доля после |
|---|---|---:|---|---:|
| `lua_calls` (18.6×→6.6×) | `compiler_rt.memset` | **57%** | P15.37a (frame slim + pending_call split) | **<1%** |
| `global_arith` (6.9×→6.3×) | `ltable.nodeLookup` | 28% | P15.37b (Node 56B→48B) | ~28% (marginal) |
| `global_arith` (6.9×→6.3×) | metamethod-check (`indexValueDepth`+`tryPushBytecodeNewIndexMetamethod`) | 11% | P15.37c (Table.flags BITRAS) | ~9% |
| `branch_loop` (6.0×→6.1×) | `runBytecodeDispatch` (весь loop) | **98%** | — (instruction-count bound) | ~98% |
| `comparisons` (7.6×→7.8×) | `runBytecodeDispatch` | **98%** | — (instruction-count bound) | ~98% |
| `metamethod_add` (7.7×→4.9×) | `compiler_rt.memset` | 36% | P15.37a (frame slim + pending_call split) | **<1%** |
| `hash_access` (7.3×→7.7×) | `ltable.nodeLookup` | 14% | P15.37b (Node 56B→48B) | ~14% (marginal) |

**Главные выводы из hotspots:**

1. **`memset` доминирует везде, где есть call/return (Недостаток 6, P15.35
   недоработан).** Это НЕ `@memset(regs)` — его удалили в P15.36. Источник —
   инициализация больших структур фреймов при `frames.append`: компилятор
   эмитит `compiler_rt.memset` (byte-wise, не векторизованный!) для
   zero-init `RuntimeFrame` (~280 B) и `BytecodeExecFrame` (~936 B, с
   большим `pending_call` union 760 B) на каждом call/return.
   - 29% от lua_calls — `pushBytecodeExecFrame → append`
   - 28.5% от lua_calls — `completeBytecodeExecFrame → applyBytecodePendingResults`
   - 36% от metamethod_add — тот же call machinery
   **P15.37a закрыл:** reuse-pool pattern (`addOne` + field-by-field writes) вместо
   struct-literal `append`, плюс `PendingCallSlot` wrapper (`active: bool` +
   `payload: BytecodePendingCall = undefined`) вместо `?BytecodePendingCall = null`.
   `compiler_rt.memset` доля упала с 57% до <1%.

2. **Dispatch loop "branch-heavy" workloads (`branch_loop`, `comparisons`)
   упираются не в branch misses, а в instruction count (Недостаток 1, 3).**
   IPC=4.24 и IPC=3.88 — высокие, branch misses ≤0.02%. Это значит, что
   CPU выполняет инструкции быстро, но их **слишком много**: per-Lua-iteration
   dispatch overhead + codegen производит лишние опкоды (MOVE/LOADNIL/CLOSE).
   **P15.37 не закрывал** — требует codegen-level работы (P15.38+).

3. **Table lookup — главная доля `global_arith`/`hash_access` (Недостаток 4,
   P15.34 недоработан).** 28% nodeLookup + ~14% keyHash/wyhash на global_arith.
   Текущий `Node` был 56 B (key 16 + value 16 + hash 8 + dead_key 1 + next* 8 +
   padding), PUC Node = 24 B (TKey 8 + TValue 16, chain packed в TKey TValue).
   **P15.37b закрыл частично:** Node уплотнён до 48 B через `next_offset: i32`
   (PUC `gnext`-faithful) + `dead_key` packed в старший бит `hash`.
   Cache line (64 B) вмещает 1.33 наших Node vs 2.67 PUC Node — всё ещё хуже,
   но ближе. Полная parity требует variant TKey (P15.38+).

4. **Metamethod-check overhead (Недостаток 2, частично).** 11% от global_arith
   тратится в `indexValueDepth` + `tryPushBytecodeNewIndexMetamethod` — каждая
   global get/set проверяет metatable даже для plain tables без метаметодов.
   **P15.37c закрыл:** `Table.flags` bitmask (PUC BITRAS, `ltm.h:54`) —
   bit set = "metatable не имеет этого метаметода", skip `getFieldOpt`.
   Доля упала с 11% до ~9% (меньше ожидаемого, т.к. `global_arith` работает
   с `_ENV` без metatable — null-check уже short-circuit'ит).

5. **Perf работает на современном ядре.** README baseline писал "perf недоступен
   в verification-контейнере". При локальной разработке нужно использовать
   `perf stat`/`perf record --call-graph lbr` — даёт точную hotspot-карту.
   `taskset -c 0` обязателен для шумящей hybrid-архитектуры (atom/core).

План P15.37 (см. `docs/superpowers/plans/2026-07-18-performance-phase-p15.37.md`)
перевёл эти findings в конкретные задачи. Все 4 задачи (a/b/c/d) выполнены.

### Сводный ReleaseFast baseline

| Нагрузка | PUC Lua, медиана | luazig, медиана | Замедление |
|---|---:|---:|---:|
| integer arithmetic | 0.058 с | 1.240 с | 21.4× |
| global access + arithmetic | 0.054 с | 0.965 с | 17.8× |
| branch loop | 0.060 с | 1.016 с | 16.9× |
| Lua calls | 0.047 с | 0.736 с | 15.7× |
| array table access | 0.041 с | 0.372 с | 9.1× |
| integer hash table access | 0.065 с | 0.633 с | 9.7× |
| temporary table allocation | 0.058 с | 1.022 с | 17.5× |
| string-heavy loop | 0.050 с | 0.633 с | 12.6× |
| coroutine resume/yield | 0.023 с | 0.144 с | 6.1× |
| dynamic `load()` | 0.043 с | 0.207 с | 4.8× |

Геометрическое среднее на этой выборке — **примерно 11.9×**. Абсолютные числа
зависят от CPU и allocator, но относительный профиль устойчив: сильнее всего
отстают arithmetic/global/branch/calls и массовые table allocations.

### Недостаток 1: codegen исполняет слишком много bytecode

Для простого цикла:

```lua
local s = 0
for i = 1, n do
    s = s + i
end
```

luazig выполняет примерно семь opcode на итерацию:

- `MOVE` × 3;
- `LOADNIL`;
- `ADD`;
- `CLOSE`;
- `FORLOOP`.

В PUC Lua подготовительные операции находятся вне горячего тела; на итерацию
остаются в основном arithmetic opcode и `FORLOOP`.

Причины:

1. Выражения преждевременно материализуются во временные регистры, после чего
   копируются через `MOVE`.
2. `resetRegs()` консервативно эмитит `LOADNIL` на границе statement, чтобы
   убрать stale GC references, вместо точного register liveness.
3. Numeric `for` получает `CLOSE`, даже когда ни одна local переменная scope не
   захвачена closure и закрывать нечего.
4. Нет PUC-подобных immediate/constant forms (`ADDI`, `ADDK`, RK operands и
   аналогов для comparisons/table operations).

Это главный общий bottleneck: даже идеально оптимизированный `ADD` не устранит
несколько лишних dispatch cycles на каждую Lua-операцию.

**Способ устранения:** P15.32 должен ввести PUC-подобный descriptor выражений,
сохранять значения как register/constant/immediate до фактической
materialization, писать результат прямо в destination и генерировать
`LOADNIL`/`CLOSE` только по точному liveness/upvalue анализу.

### Недостаток 2: generic operation path используется даже для обычных чисел

Sampling integer arithmetic loop:

| Hot path | Доля samples |
|---|---:|
| общий `runBytecodeDispatch` | ~42% |
| `coerceArithmeticValue` | ~23% |
| bytecode close continuation | ~12% |
| `evalBinOp` + `binAdd` | ~10% |
| frame/upvalue/прочее | остаток |

Обычный numeric `ADD` проверяет и преобразует операнды дважды: сначала перед
решением о metamethod, затем повторно внутри generic arithmetic helper.

A/B-сборка только с прямым Int/Num fast path для `ADD`, без изменения bytecode,
ускорила benchmark примерно с **1.44 до 0.95 с** — около **1.5×**.

**Способ устранения:** P15.31 вводит typed fast paths для arithmetic, bitwise,
comparisons, `GETI/SETI` и interned-string `GETFIELD/SETFIELD`. Generic
coercion/metamethod path должен вызываться только после провала дешёвых tag
checks. При этом обязателен точный PUC-порядок conversions, ошибок и выбора
metamethod.

### Недостаток 3: слишком много bookkeeping на каждом opcode

Общий dispatch path даже в простом no-hook/no-yield случае обновляет или
проверяет:

- `RuntimeFrame.pc`, `top`, `current_line`, varstack state;
- line/count hooks;
- GC debt/tick;
- pending completion и result state;
- coroutine/thread-switch boundaries;
- boxed/register state;
- debug metadata.

PUC Lua хранит hot state в локальных переменных `luaV_execute` и публикует его
в `lua_State`/`CallInfo` на safepoints. В luazig значительная часть cold-path
машинерии остаётся внутри общего interpreter loop.

**Способ устранения:** P15.33 разделяет fast и slow dispatch. В fast loop `pc`,
base, top и current closure живут в локальных Zig-переменных. Runtime structures
синхронизируются только на call/return, allocation/GC safepoint, hook,
error/metamethod, yield/resume и debug API boundary. Continuation/debug/error
код выносится из hot function для уменьшения instruction-cache footprint.

### Недостаток 4: таблицы и GC-объекты слишком велики

Текущие размеры:

| Тип | luazig | PUC Lua |
|---|---:|---:|
| `Value` / `TValue` | 16 B | 16 B |
| `Table` | 72 B | 48 B |
| hash `Node` | 56 B | 24 B |
| `Closure` / `LClosure` | 72 B | 40 B |
| `Cell` / `UpVal` | 48 B | 40 B |
| `Thread` / `lua_State` header | 840 B | 208 B |

На integer hash benchmark sampling показывает примерно 31% в `nodeLookup`,
14% в очистке hash storage, 13% в dispatch и 11% в `nodeInsert`. `Node` в 2.3
раза больше PUC-варианта, поэтому на cache line помещается меньше entries,
растут RSS, cache misses и стоимость rehash/memset.

**Способ устранения:** P15.34 должен уплотнить `Node` до 24–32 байт, добавить
специализированные integer/interned-string paths, убрать generic `Value`
hashing для array index и не обнулять большие 56-byte nodes целиком при каждом
росте. Изменение layout принимается только вместе с weak/dead-key/Brent-chain
регрессиями.

### Недостаток 5: allocator рассчитан не на эту модель VM

CLI использует `std.heap.smp_allocator`, хотя Lua VM однопоточная. Sampling
показывает mutex/slab paths, а allocation-heavy benchmark — большой разрыв RSS.

A/B для 400 000 временных таблиц:

| Allocator | Время | Max RSS |
|---|---:|---:|
| `smp_allocator` | ~0.81 с | ~160 МБ |
| libc allocator | ~0.54 с | ~134 МБ |
| PUC Lua | ~0.04 с | ~4 МБ |

Libc allocator даёт около 1.5× на массовых аллокациях, но почти не влияет на
lookup-heavy workload. Следовательно, простая замена allocator полезна как
промежуточный шаг, но не решает раздутый layout и слишком большое число
allocation units.

**Способ устранения:** после безопасного временного перехода на libc allocator
P15.34 должен добавить однопоточный VM allocator: page/slab pools для
`Table`/`Node`/`Closure`/`Cell`, отсутствие mutex и bulk release страниц после
major sweep. Compile-temporary allocations должны жить в отдельной arena.

### Недостаток 6: дорогая call-frame machinery

Lua calls отстают примерно в 15–16 раз, coroutine resume/yield — примерно в 6
раз. На обычном вызове участвуют generic `resolveCallable`, growable arrays
frames/exec-frames, публикация runtime state, pending completion, debug/hook
transfer и close/upvalue machinery.

**Способ устранения:** P15.35 вводит предвыделенный PUC-подобный CallInfo stack,
компактный frame header и отдельный прямой path для обычного Lua closure call.
`resolveCallable`, `__call`, hooks, yields и error continuations остаются slow
path. Debug names реконструируются лениво только при error/debug API.

### Недостаток 7: `load()` всегда строит полный AST

Dynamic `load()` отстаёт меньше — около 4.8× — но профиль показывает отдельный
compiler bottleneck:

- allocator/system paths — около 39%;
- создание bytecode closure — около 15%;
- рост AST/name arrays — около 12%;
- memcpy — около 8%.

PUC компилирует parser-to-bytecode почти напрямую, тогда как luazig строит
полный AST, повторно обходит его и использует множество независимых growable
arrays.

**Способ устранения:** P15.36 сначала добавляет reuse arena, capacity hints,
small-vector storage и сокращение копирований identifier/string data. После
стабилизации нужен streaming parser-to-bytecode path; AST остаётся optional
режимом для tooling/debug, а не обязательной runtime стадией.

Пункт необходимо подробно обсудить, так как AST было подмечено как одно из улучшений
luazig по сравнению с PUC Lua

### Что не является главным общим bottleneck

После P15.30.1 GC correctness и pacing остаются критичными, но сам collector не
объясняет основной performance gap. Arithmetic/global/branch loops почти не
аллоцируют и всё равно отстают в 17–21 раз. Поэтому следующая крупная
оптимизация должна начинаться с typed operations, codegen и dispatch, а не с
ещё одного переписывания GC.

### Ранжирование по ожидаемому эффекту

1. Instruction inflation из codegen.
2. Тяжёлый общий dispatch path.
3. Generic arithmetic/comparison/metamethod path.
4. Table representation и allocator.
5. Call-frame machinery.
6. AST-based dynamic compilation.
7. Дополнительный GC tuning только после измеренного доказательства, что он
   ограничивает конкретный workload.

## План работ

Каждая итерация закрывает минимум один чекбокс ниже (см. `AGENTS.md`).
Дизайн фиксируется здесь же; отступления от PUC отмечаются явно.

### Активный шаг: P15.34 — compact tables и VM allocator

P15.31 полностью завершён (8/8 чекбоксов). P15.32b/c завершены.
P15.33 (fast/slow dispatch split) частично завершён (4/6 чекбоксов закрыты):
hooks_active_cached, RuntimeFrame sync только на safepoints, GC fast check,
benchmark. Оставшиеся 2 чекбокса P15.33 (полный вынос state в locals, cold path
separation) требуют более глубокой реструктуризации. Следующий приоритет — P15.34
(compact tables), которая даст больший выигрыш на table-heavy workloads.

### P15.31 — typed opcode fast paths (завершён)

Цель первого performance-патча — убрать заведомо лишний generic path, не меняя
формат bytecode и не смешивая этот этап с крупным codegen redesign.

- [x] Прямой integer/integer и number/number path для `ADD`, `SUB`, `MUL`,
  `MOD`, `POW`, `DIV`, `IDIV` и unary minus.
- [x] Прямые paths для bitwise операций и shifts.
- [x] Прямые numeric comparison paths.
- [x] Fast `GETI/SETI` для array/integer keys.
- [x] Fast `GETFIELD/SETFIELD` для interned short strings.
- [x] Generic coercion и metamethod lookup вызываются только после провала tag
  checks.
- [x] Debug operand names и дорогая error context не вычисляются без активного
  hook/error path. **P15.31:** CALL/TAILCALL передают `null` в `resolveCallable`;
  `debugBytecodeOperandName` (обратный проход по bytecode) вызывается только в
  catch-блоке при ошибке "attempt to call a X value". Error messages сохраняют
  имена (`local 'foo'`, `field 'baz'`). 31/31 parity проходит.
- [x] Добавить opcode-level microbench и differential tests для смешанных
  integer/float/string/metamethod случаев. **P15.31:** Добавлены 6 workloads:
  `mixed_arith` (int+float ADD), `float_arith` (float+float ADDK),
  `string_concat` (CONCAT), `metamethod_add` (`__add`), `field_access`
  (GETFIELD/SETFIELD), `comparisons` (LT/LE/EQ chain).

Критерии приёмки:

- arithmetic slowdown снижен примерно с 21× до **≤12×**;
- ни один fast path не меняет PUC-порядок conversion/metamethod/error;
- build/unit, smoke, 29/29 matrix, direct `gc.lua`, `gengc.lua --testc`,
  `constructs.lua`, `verybig.lua` и 1-МБ stress остаются зелёными.

### P15.32 — register-aware bytecode codegen

Наиболее важный этап общего roadmap.

- [x] Ввести PUC-подобный operand/`expdesc`: register, constant, immediate,
  relocatable jump и materialized temporary являются разными состояниями.
  **P15.32 expdesc:** `ExpDesc` struct с Zig tagged union (19 вариантов:
  `local`, `upval`, `k`, `k_int`, `k_float`, `k_str`, `index_up`, `index_str`,
  `index_i`, `indexed`, `reloc`, `non_reloc`, `call`, `vararg`, `nil`, `true`,
  `false`, `const_local`, `non_reloc`). Discharge primitives: `dischargeVars`
  (PUC `luaK_dischargevars`), `discharge2reg` (PUC `luaK_discharge2reg`),
  `exp2nextreg` (PUC `luaK_exp2nextreg`), `exp2anyreg` (PUC `luaK_exp2anyreg`),
  `exp2val` (PUC `luaK_exp2val`), `freeExp`/`freeExps`. `genExpDesc` — аналог
  PUC `luaK_exp2val` для AST→ExpDesc. `genNameExpDesc` — PUC `singlevar`:
  local→`.local`, upvalue→`.upval`, global→`.index_str` (если `_ENV` local)
  или `.index_up` (если `_ENV` upvalue). `genGlobalExpDesc` — mirrors
  `emitGlobalGet` at ExpDesc level. Large constant index (>255 interned
  strings) handled via LOADK+GETTABLE fallback in `discharge2reg` for
  `.index_up`/`.index_str`.
  **P15.32a (откат):** `genNameValue` возвращал регистр local напрямую (PUC
  VLOCAL), но это ломало `repeat`/`while` с замыканиями — `genExpNextReg`
  неправильно определял "уже в нужной позиции" для local registers. Добавлен
  `genExpNextReg` (аналог `luaK_exp2nextreg`) с проверкой `r >= nvarstack`.
  Требует полноценный expdesc с relocate-семантикой как в PUC.
- [x] Не материализовать local/constant до инструкции, которой действительно
  нужен регистр.
  **P15.32 expdesc:** `genBinOp`, `genReturn`, `genCall` migrated to ExpDesc.
  `exp2anyreg` для non-captured locals возвращает регистр локала напрямую
  (no MOVE). `dischargeVars` для captured locals эмитит MOVE (cell.value sync).
  RHS `line_hint` save/restore в `genBinOp` — инструкции RHS несут правильную
  строку (не строку statement). Улучшения: int_arith -19%, float_arith -28%,
  comparisons -19%, branch_loop -17%, mixed_arith -14%.
- [x] Писать результат выражения сразу в destination assignment/return slot.
  **P15.32 expdesc:** `genReturn` single-value path использует `exp2anyreg` —
  для non-captured locals `return1` читает регистр локала напрямую (no MOVE).
  `genCall` arguments используют `genExpNextReg` (ExpDesc path) — аргументы
  discharge напрямую в call frame slots (no MOVE for non-captured locals).
- [x] Добавить `ADDI`, `ADDK` и аналогичные immediate/constant variants.
  **P15.32c:** Добавлены opcodes `addi`, `addk`, `subk`, `mulk`, `modk`, `powk`,
  `divk`, `idivk`, `bandk`, `bork`, `bxork`, `shli`, `shri` (PUC 5.5 style).
  `genBinOp` проверяет RHS на numeric constant через `numericConstFromExp`
  (аналог PUC `tonumeral`) и эмитит K/I-variant вместо LOADK + register op.
  `constBinOpInfo` определяет opcode/C-field без модификации регистров (clean
  fallback). SUB с small int использует SUBK (не ADDI), т.к. наш bytecode не
  имеет MMBINI для передачи правильного metamethod event. 31/31 parity matrix
  проходит. Улучшения: branch_loop -6.4%, array_access -11.5%, hash_access
  -6.7%.
- [x] Добавить RK-подобные operands для arithmetic и table instructions.
  **P15.32c:** 13 новых опкодов (addi, addk, subk, mulk, modk, powk, divk,
  idivk, bandk, bork, bxork, shli, shri) в `bytecode.zig`. Codegen:
  `numericConstFromExp` извлекает числовые константы из AST без материализации
  в регистр, `constBinOpInfo` определяет опкод и C-поле, `tryEmitConstBinOp`
  эмитит K/I-вариант с чистым fallback. VM: fast/slow path handlers с
  metamethod fallback. `evalBytecodeBinOpValues` для аннотирования ошибок.
  Улучшения: branch_loop -6.4%, array_access -11.5%, hash_access -6.7%.
  **Bug fix:** `env_cell` в `runZigSource` перемещён с стека в heap
  (`aalloc.create(Cell)`) — closures захватывают cell как upvalue, а
  finalizers (`__gc`) могут выполняться во время `vm.deinit()`, долго после
  возврата `runZigSource`. Stack-local cell приводил к use-after-free.
- [x] Эмитировать `CLOSE` только для scopes с реально открытыми upvalues/TBC.
  **P15.32b:** `anyCapturedInRange(start, end)` проверяет `captured_regs` перед
  эмитом CLOSE в `genForNumeric`, `genWhile`, `genRepeat`, `genForGeneric`.
  `popScope` уже имел эту проверку. TBC-переменные в generic-for сохраняют
  безусловный CLOSE (semantics `__close`).
- [x] Заменить statement-wide `LOADNIL` точным register liveness и очисткой на
  safepoints. **P15.32 LOADNIL elimination:** Добавлено per-PC `live_reg_top`
  поле в `Proto` ([]const u8, один байт на инструкцию). Codegen синхронизирует
  `builder.current_live_top` с `peak_freereg` при каждом `reserveRegs`/`resetRegs`/
  `popScope`. GC (`gcMarkMutableRoots`) маркирует только `frame.regs[0..live_reg_top[pc]]`
  вместо полного `maxstacksize` окна — PUC `traversestack` подход. Atomic phase
  (`gcClearDeadFrameRegisters`) очищает GC pointers из dead slots выше
  `live_reg_top[pc]` — PUC `setnilvalue` эквивалент. `resetRegs` и `popScope`
  больше не эмитят LOADNIL. Улучшения: int_arith -23%, float_arith -27%,
  mixed_arith -21%, comparisons -10%. 30/31 parity (cstack pre-existing).
- [x] Добавить bytecode dump regression, фиксирующий размер hot loops.
  **P15.32c:** `--dump-bytecode` CLI flag вызывает `dumpProto()` из
  `bytecode.zig` (luac-style disassembly с прото, константами, локалами,
  upvalues). Регрессионные тесты в `codegen_bc.zig`: проверка ≤7 опкодов
  между FORPREP/FORLOOP и проверка эмитирования ADDI для `x + 5`.

Результаты microbench (медиана из 3 прогонов, `taskset -c 0`, ReleaseFast):

| Benchmark | PUC Lua | До P15.31 | P15.31 | P15.32b | P15.32c | P15.33 | P15.32nil | P15.32exp | P15.33b | P15.34 | P15.36 | P15.37 | PUC→P15.37 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| int_arith | 0.173 | 9.605 | 8.715 | 1.735 | 1.779 | 1.358 | 1.050 | 0.848 | 0.832 | 0.853 | 0.844 | 0.841 | 4.9× |
| global_arith | 0.504 | 15.863 | 14.879 | 7.716 | 8.099 | 7.220 | 6.881 | 6.599 | 6.599 | 3.059 | 3.568 | 3.187 | 6.3× |
| branch_loop | 0.422 | 12.913 | 11.344 | 4.164 | 3.963 | 3.453 | 3.216 | 2.634 | 2.607 | 2.611 | 2.550 | 2.576 | 6.1× |
| lua_calls | 0.093 | 3.523 | 3.427 | 2.719 | 2.642 | 2.553 | 2.520 | 2.503 | 2.443 | 2.527 | 1.747 | 0.617 | 6.6× |
| array_access | 0.044 | 1.315 | 1.155 | 0.426 | 0.368 | 0.338 | 0.309 | 0.293 | 0.293 | 0.291 | 0.285 | 0.289 | 6.6× |
| hash_access | 0.063 | 1.655 | 1.395 | 0.644 | 0.595 | 0.556 | 0.507 | 0.491 | 0.491 | 0.489 | 0.469 | 0.481 | 7.7× |
| temp_table_alloc | 0.029 | 0.224 | 0.223 | 0.154 | 0.147 | 0.147 | 0.137 | 0.137 | 0.137 | 0.141 | 0.133 | 0.134 | 4.7× |
| string_loop | 0.097 | 0.528 | 0.533 | 0.448 | 0.451 | 0.448 | 0.447 | 0.436 | 0.436 | 0.411 | 0.428 | 0.409 | 4.2× |
| coroutine_yield | 0.042 | 0.429 | 0.411 | 0.329 | 0.320 | 0.314 | 0.298 | 0.306 | 0.306 | 0.237 | 0.220 | 0.222 | 5.3× |
| dynamic_load | 0.129 | 1.224 | 1.122 | 0.409 | 0.408 | 0.370 | 0.350 | 0.319 | 0.319 | 0.314 | 0.337 | 0.267 | 2.1× |
| mixed_arith | 0.176 | — | — | — | 1.834 | 1.514 | 1.193 | 1.000 | 1.000 | 0.993 | 0.977 | 0.982 | 5.6× |
| float_arith | 0.177 | — | — | — | 1.812 | 1.384 | 1.017 | 0.740 | 0.656 | 0.729 | 0.648 | 0.661 | 3.7× |
| string_concat | 0.081 | — | — | — | 0.150 | 0.150 | 0.148 | 0.139 | 0.139 | 0.132 | 0.128 | 0.128 | 1.6× |
| metamethod_add | 0.058 | — | — | — | 0.556 | 0.544 | 0.549 | 0.545 | 0.545 | 0.475 | 0.456 | 0.282 | 4.9× |
| field_access | 0.054 | — | — | — | 0.732 | 0.658 | 0.583 | 0.587 | 0.587 | 0.242 | 0.230 | 0.228 | 4.2× |
| comparisons | 0.530 | — | — | — | 7.070 | 5.705 | 5.132 | 4.233 | 4.090 | 4.250 | 4.122 | 4.112 | 7.8× |

Геометрическое среднее: **2.12×** ускорения (до P15.31 → P15.32c, 10 исходных workloads);
**8.7×** отставания от PUC Lua (PUC → P15.32c, 10 исходных). Новые workloads (P15.31):
mixed_arith 10.1×, float_arith 10.0×, string_concat 1.8×, metamethod_add 9.4×,
field_access 13.1×, comparisons 13.1×. P15.32exp (ExpDesc migration): int_arith -19%,
float_arith -28%, comparisons -19%, branch_loop -17%, mixed_arith -14%.
P15.33b (stack ptr tracking + branch hints): float_arith -11%, comparisons -3%,
lua_calls -2%.
P15.34 (pre-intern string constants): global_arith -54%, field_access -59%,
metamethod_add -13%, string_loop -6%, coroutine_yield -23%.
P15.36 (eliminate per-call @memset via before-semantics + upvalue closing): lua_calls -31%
(2.527→1.747s). Parity: 28/31 (no regressions).
P15.35 (zero-allocation call/return fast path): lua_calls -27% (7.27→5.32s, Debug build).
P15.37a (frame-struct slim + pending_call split): lua_calls -65% (1.760→0.617s),
metamethod_add -38% (0.456→0.282s), `compiler_rt.memset` share 53%→<1%.
P15.37b (Node compaction 56B→48B via i32 chain offset): PUC `gnext`-faithful,
`nodeLookup` perf share unchanged (~28%).
P15.37c (Table.flags BITRAS): PUC-faithful metamethod cache, skips `getFieldOpt`
when metatable has no `__index`/`__newindex`.
P15.37 geomean: **4.77×** (16 workloads, median of 7, `tools/perf_compare.py`).

P15.32a (устранение MOVE для local reads) был отменён — ломал `repeat`/`while`
с замыканиями. P15.32b (условный CLOSE) даёт основной вклад: int_arith
8.7→1.7s, branch_loop 11.3→4.2s, dynamic_load 1.1→0.4s. P15.32c (K/I-variant
opcodes) устраняет LOADK для constant-operand arithmetic: branch_loop -6.4%,
array_access -11.5%, hash_access -6.7%. P15.32exp (ExpDesc migration) устраняет
MOVE для non-captured locals в genBinOp/genReturn/genCall: int_arith 1.05→0.85s,
float_arith 1.02→0.74s, comparisons 5.13→4.23s.

Критерии:

- `s=s+i` выполняет не более 2–3 hot opcode на итерацию вместо примерно 7;
- arithmetic/global/branch slowdown — **≤5× PUC**;
- generated code остаётся корректным при hooks, GC между инструкциями,
  captured locals, `goto` и `<close>`.

### P15.33 — fast/slow dispatch split

- [x] Отдельный compact loop для no-hook/no-yield/no-pending/no-GC case.
  **P15.33:** Когда `hooks_active_cached == false`, dispatch loop пропускает
  per-instruction RuntimeFrame sync, line/count hook checks и debug corruption
  assertion. `hooks_active_cached` — Vm-level bool, обновляемый через
  `refreshHooksCached()` после каждого `debug.sethook` и при каждом coroutine
  `switchRuntime`. `current_thread` устанавливается перед `switchRuntime`, чтобы
  cached flag читал hook state правильного thread.
- [x] `pc`, base, top и closure живут в локальных переменных interpreter loop.
  **P15.33:** `pc`, `regs`, `boxed`, `frame_current_line`, `frame_cap`,
  `nvarstack`, `reg_top` — все локальные в dispatch loop. Stack ptr tracking:
  `stack_ptr`/`stack_boxed_ptr`/`cached_frame_cap` проверяются каждый iteration,
  re-derive `regs`/`boxed` только когда stack был realloc'd (после CALL/RETURN/
  builtin). На fast path — один pointer comparison вместо двух slice ops.
  `@branchHint(.unlikely)` на hooks_active slow path.
- [x] RuntimeFrame синхронизируется только на safepoints.
  **P15.33:** RuntimeFrame sync только на: defer (frame exit), GC tick, error
  paths (`fail()`, `error()`, `setOutOfMemoryError()`), builtin entry
  (`callBuiltin`). `bc_dispatch_pc` обновляется на fast path (один store),
  `frame_current_line` обновляется из `lineinfo[pc]`.
- [x] Cold continuation/debug/error paths вынесены из hot function.
  **P15.33:** `@branchHint(.unlikely)` на hooks_active slow path — compiler
  move cold debug hook code out of hot path. Arithmetic metamethod slow paths
  оставлены inline (compiler уже хорошо справляется с branch prediction для
  `if/else if` chains). Microbench: float_arith -10% от stack ptr tracking.
- [x] GC fast check сводится к дешёвому debt comparison; реальное продвижение
  collector выполняется на allocation/safepoint path.
  **P15.33:** Fast path: `gc_tick += 1; if (gc_tick >= threshold) { sync+step }`.
  Только counter increment + comparison, без вызова функций.
- [x] Добавить benchmark и assertion, что выключенные hooks не ведут через hook
  machinery.
  **P15.33:** `hooks_active_cached` — single bool read per instruction.
  Microbench подтверждает: int_arith -24%, float_arith -24%, comparisons -19%.

Критерии:

- arithmetic после P15.32 приближается к **2–3× PUC**;
- Lua calls — **≤5× PUC** до отдельного CallInfo redesign;
- debug hooks, coroutine switch и error unwinding сохраняют текущую parity.

### P15.34 — compact tables и однопоточный VM allocator

- [x] Уменьшить hash `Node` с 56 до 48 байт. **P15.37b:** `next: ?*Node` (8 B +
  padding) → `next_offset: i32` (4 B) PUC `gnext`-style, `dead_key` packed в
  старший бит `hash`. Полная parity (24 B) требует variant TKey (P15.38+).
- [x] Уплотнить chain metadata и исключить дублирующие key/tag fields. **P15.39:**
  variant TKey — `key: Value` (16 B tagged union) → `key_tt: u8` + `key_val: extern union` (8 B),
  кэшированный `hash: u64` удалён (хеш пересчитывается на каждом use site как в PUC).
  `Node` сжат с 48 B до 32 B → две полные nodes на 64-byte cache line.
- [ ] Специализированные integer и interned-string lookup/insert paths.
- [x] Не memset’ить полный большой Node при каждом resize. **P15.37a:** struct
  literal zero-init заменён на reuse-pool pattern (`addOne` + field writes).
- [ ] Сначала проверить libc allocator как безопасный промежуточный default для
  CLI.
- [ ] Затем добавить VM-local pools/pages для `Table`, `Node`, `Closure`,
  `Cell`; без mutex.
- [ ] Освобождать пустые pages после major sweep.
- [ ] Compile/parser temporary data вынести в переиспользуемую arena.
- [x] **Pre-intern string constants at first Proto execution.** `bcConstToValue`
  previously called `internStrAll(s.bytes())` on every GETTABUP/GETFIELD/SETFIELD
  execution — re-hashing already-interned strings (~12.4% of cycles on microbench).
  Now `resolveProtoConstants` runs once per Proto (in `pushBytecodeExecFrame` and
  TAILCALL frame-reuse path), replacing compile-time `*LuaString` (hash seed 0)
  with VM-interned pointers. `bcConstToValue` returns the pointer directly.
  Ownership: after resolution, string constants are owned by the VM's intern
  table, not by the Proto (matching PUC's `TString` ownership model).
  **Results:** global_arith -54%, field_access -59%, metamethod_add -13%.
- [x] **Nil-fill missing parameters (PUC `luaD_precall` parity).**
  `pushBytecodeExecFrame` now explicitly nil-fills `regs[args.len..numparams]`
  instead of relying on the full-window memset. Matches PUC's
  `for (; narg < nfixparams; narg++) setnilvalue(s2v(L->top.p++))`.
- [x] **Bound debug.getlocal/setlocal temp-scan by `live_reg_top[pc]`.**
  Previously scanned the entire register window (`fr.regs[0..fr.regs.len]`),
  exposing stale values as phantom "(temporary)" locals. Now bounded by
  `live_reg_top[pc]` (our equivalent of PUC's `L->top`), with fallback to full
  window for stripped/external protos without `live_reg_top`. Fixes latent
  db.lua assertion failure. `cloneStrippedProto` now copies `live_reg_top`.
- [x] **Fix parked-coroutine GC scan to use per-frame `live_reg_top`.**
  Previously scanned the entire `bytecode_stack[0..parked_top]` as a flat array
  with NO per-frame `live_reg_top` filtering — stale values in uninitialized
  register windows caused SIGSEGV on coroutine.lua/cstack.lua. Now walks
  `th.runtime_frames` with per-frame `live_reg_top[fr.pc]`, matching the
  active-thread GC scan at `gcMarkMutableRoots`.

  **Note on `@memset(regs, .Nil)`:** The full-window memset is still kept as a
  safety net. It cannot be removed until `live_reg_top` tracks the "after"
  boundary (registers actually written by the completed instruction) rather
  than the per-statement high-water mark. PUC's `L->top` is updated after each
  instruction; our `live_reg_top[pc]` is set before emission. When GC runs at
  a safepoint (`fr.pc = pc` before instruction execution), `live_reg_top[pc]`
  may include registers that will be written by this instruction but haven't
  been yet. This is a P15.35 prerequisite.

Критерии:

- array/hash operations — **≤3× PUC**;
- temporary table allocation — **≤3× PUC**;
- max RSS allocation workload — **≤2× PUC**;
- weak tables, dead keys, finalizers, Brent chaining и generational barriers не
  получают регрессий.

### P15.35 — CallInfo stack и обычный call fast path

- [ ] Предвыделенный массив frame/CallInfo records.
- [x] **Обычный Lua call/return не делает heap allocation на fast path.**
  P15.35a: OP_RETURN0/OP_RETURN1 fast path — when no pending TBC closers and
  no debug hooks, skip `beginBytecodeClose` entirely and go straight to
  `completeBytecodeExecFrame`. Single-value returns use a `bc_return_scratch`
  VM-state slot (stable across frame pop, detected by pointer identity, never
  freed). Zero-value returns use `bc_return_scratch[0..0]`. This eliminates
  the `alloc(Value, 0)`/`alloc(Value, 1)` + `free` pair on every return —
  matching PUC Lua's zero-allocation return semantics.
  P15.35b: Non-vararg functions use a static `empty_varargs` slice instead of
  `alloc.dupe(Value, &.{})` — eliminates the malloc(0)/free(0) pair on every
  OP_CALL for functions without `...`.
  P15.35c: Fixed `refreshHooksCached` to include `has_call`/`has_return` —
  the P15.33 cached flag previously only tracked line/count hooks, causing
  the OP_RETURN fast path to skip return hooks. Now correctly detects all
  hook types.
  P15.35d: Eliminated `rargs = alloc.dupe(...)` on OP_CALL fast path. When
  `resolved.owned_args == null` (no `__call`), pre-grow `bc_stack` for the
  child frame before the dupe check. If no realloc (common), pass
  `resolved.args` directly. If realloc (rare), re-derive from offset.
  Matches PUC's `luaD_precall` — args addressed by stack offset, no
  intermediate buffer.
  P15.35e: Fixed `long_string_cache` key use-after-free in `internStrAll`.
  The cache stored the caller's borrowed `raw` slice as the key, but
  `resolveProtoConstants` freed the source `LuaString` immediately after.
  On next grow/rehash, the map compared keys through freed memory →
  corruption. Fixed: store `ls.bytes()` (interned string's inline body,
  stable for the string's lifetime).
  P15.35f: Eliminated `dup_args = alloc.dupe(...)` on OP_TAILCALL fast path.
  Pass `orig_args` (regs[a+1..]) directly to `resolveCallable`. In the
  frame-reuse path, copy params BEFORE nil-fill using `copyForwards`
  (overlap-safe, matches PUC's memmove). Compute varargs BEFORE nil-fill.
  Matches PUC's tail-call path — args moved in-place, no intermediate buffer.
  **Results:** lua_calls -27% (7.27→5.32s, Debug build). Parity: 28/31
  (up from 26/31; api.lua and literals.lua fixed).
- [ ] Прямой known-Lua-closure path без повторного `resolveCallable`.
- [x] **`__call`, hooks, protected calls, yields и thread switches остаются в slow
  path.** The OP_RETURN0/1 fast path checks `has_pending_tbc` and
  `hooks_active` before taking the shortcut. When TBC closers or any debug
  hook is active, the full `beginBytecodeClose` path runs unchanged.
- [ ] Debug name reconstruction выполняется лениво.
- [ ] Уплотнить `Thread` header и parked-frame storage после измерения lifetime
  требований.

Критерии:

- Lua calls — **≤2–3× PUC**;
- coroutine resume/yield — **≤3× PUC**;
- iterative-dispatch invariants и 1-МБ stack stress сохраняются.

### P15.36 — compiler/`load()` pipeline

- [ ] Reuse parser/codegen arena между вызовами `load()`.
- [ ] Capacity hints для AST, bytecode, constants и names.
- [ ] Small-vector storage для типичных маленьких функций.
- [ ] Уменьшить копирование identifier/source/string data.
- [ ] После стабилизации добавить streaming parser-to-bytecode backend.
- [ ] Полный AST оставить optional tooling/debug path.

Критерий: dynamic `load()` — **≤2–3× PUC**, без ухудшения diagnostics,
lineinfo, stripped chunks и large-program codegen.

### P15.36b — eliminate per-call `@memset` via "before" live_reg_top semantics

- [x] **Part 1: Codegen infrastructure for "before" semantics.** Added
  `live_top_before`/`has_live_top_before` fields to `ProtoBuilder`.
  `reserveRegs`/`syncLiveTop` snapshot the live top BEFORE bumping
  `peak_freereg`. `emit()` records `live_top_before` (the "before" boundary)
  instead of `current_live_top` (the "after" boundary). This ensures GC
  safepoints only scan registers written by PREVIOUS instructions, not
  registers that will be written by the current instruction but haven't
  been yet.
- [x] **Part 2: Fix `.reloc` expression pattern.** The `.reloc` pattern
  (used by GETTABUP, GETTABLE, etc.) emits the instruction BEFORE allocating
  the destination register, then patches the A field. This caused
  `live_top_before` to be snapshotted before the bump, and the stale
  snapshot persisted to the next instruction (due to `has_live_top_before`
  flag). Fixed in `discharge2reg`'s `.reloc` case: after patching, clear
  the flag and update `live_top_before = current_live_top` so the next
  instruction sees the correct boundary.
- [x] **Part 3: Upvalue closing on return path.** `completeBytecodeExecFrame`
  now calls `closeBytecodeUpvaluesFrom(frame, 0)` BEFORE `popBytecodeExecFrame`.
  Previously, open upvalue cells in `boxed[]` were never closed on normal
  returns — masked by `@memset(boxed, null)` on frame entry. Double-close
  is safe: `closeBytecodeUpvaluesFrom` checks `boxed[i]` for non-null and
  clears it after closing.
- [x] **Part 4: Remove both `@memset` calls.** Removed `@memset(regs, .Nil)`
  and `@memset(boxed, null)` from `pushBytecodeExecFrame`. PUC Lua
  (`luaD_precall`) does NOT zero the register window — it only nil-fills
  missing parameters. We now match this behavior.
- [x] **Document known deviations from PUC Lua.** (1) `gc_tick` fires GC
  every N instructions instead of PUC's allocation-only triggers. (2)
  Per-PC `live_reg_top` table instead of runtime `L->top` — needed because
  `gc_tick` can fire at any instruction. Both deviations are orthogonal to
  the memset fix but documented as technical debt.

**Results:** lua_calls -31% (2.527→1.747s, ReleaseFast). Parity: 28/31
(no regressions). All 44 smoke tests pass.
Spec: `docs/superpowers/specs/2026-07-18-memset-elimination-design.md`

### P15.37 — воспроизводимый performance gate + hotspot-driven perf-фазы

Добавить `tools/perf_compare.py` и versioned baseline + закрыть 3 hotspot'а,
выявленных через `perf record --call-graph lbr`:

- [x] ReleaseFast build на Zig 0.16.0;
- [x] CPU affinity и warmup (`taskset -c 0`);
- [x] медиана минимум семи прогонов;
- [x] arithmetic/global/branch/call/table/allocation/string/coroutine/load
  workloads (16 в `tools/microbench.lua`);
- [ ] wall time, process CPU, max RSS и opcode count (только wall time);
- [x] при доступном современном ядре — `perf stat` counters (`--perf` flag);
- [x] JSON output с toolchain/CPU metadata (`tools/perf/baseline-p15.37.json`);
- [x] warning при регрессии >5%, failure >10% для стабильных benchmarks;
- [ ] отдельная маркировка noisy/long suites вроде direct `constructs.lua`.

**Hotspot-driven задачи:**

- [x] **P15.37a — Frame-struct slim.** `BytecodeExecFrame` (936 B) и
  `RuntimeFrame` (280 B) инициализировались через struct literal `append`,
  что эмитит byte-wise `compiler_rt.memset` (57% от lua_calls). Заменено на
  reuse-pool pattern: `addOne(alloc)` + field-by-field writes (без struct
  literal → нет memset). Дополнительно: `?BytecodePendingCall` (768 B optional)
  заменён на `PendingCallSlot` wrapper (`active: bool` + `payload = undefined`),
  где `clear()` — single-byte write вместо 768-byte memset.
  **Результат:** lua_calls 1.760→0.617s (-65%), metamethod_add 0.456→0.282s
  (-38%), `compiler_rt.memset` share 53%→<1%.
- [x] **P15.37b — Node compaction.** `ltable.Node` уплотнён с 56 B до 48 B:
  `next: ?*Node` (8 B + padding) заменён на `next_offset: i32` (4 B) PUC
  `gnext`-style signed index offset, `dead_key: bool` упакован в старший бит
  `hash` (`DEAD_KEY_FLAG`). Hash маскируется (`HASH_MASK`) при записи, чтобы
  live-key хеши с установленным bit 63 не ложно определялись как dead.
  `nextNode` использует direct pointer arithmetic для chain walk.
  **Результат:** PUC-faithful layout, `nodeLookup` perf share ~28% (без
  регрессии). Полная parity (24 B) требует variant TKey (P15.38+).
- [x] **P15.37c — Table.flags bitmask (BITRAS).** Добавлен `flags: u8` в
  `Table` (PUC `ltm.h:54`): bit set = "metatable не имеет метаметод".
  Проверяется перед `getFieldOpt(mt, "__index"/"__newindex")` в 5 точках.
  Сбрасывается при new-key insertion (`rawSet`, PUC `ltable.c:1112`).
  **Результат:** PUC-faithful metamethod cache. Доля metamethod-check упала
  с 11% до ~9% (меньше ожидаемого — `global_arith` работает с `_ENV` без
  metatable, null-check уже short-circuit'ит).
- [x] **P15.37d — `tools/perf_compare.py` + baseline.** Скрипт собирает
  ReleaseFast-бинарь и PUC Lua reference, pinned на одно ядро через
  `taskset -c 0`, берёт медиану 7 прогонов на 16 workloads, печатает таблицу
  `PUC | Zig | Zig/PUC` с geomean, сравнивает с versioned baseline
  (`tools/perf/baseline-p15.37.json`, WARN >5%, FAIL >10%), опционально
  запускает `perf stat`. Флаги: `--update-baseline`, `--perf`, `--runs`,
  `--core`, `--no-build`.

**Итог P15.37:** geomean **5.21× → 4.77×** (8.5% improvement). Цель ≤3× не
достигнута — основные оставшиеся hotspot'ы: instruction-count bound dispatch
(`branch_loop`/`comparisons` ~98% в `runBytecodeDispatch`) и `nodeLookup`
(~28% на `global_arith`). Оба требуют codegen-level работы (P15.38+):
variant TKey для полной Node parity, fewer opcodes per Lua iteration.

Performance patch принимается только вместе с correctness gates:

- `zig build test -Doptimize=Debug`;
- differential smoke;
- 29/29 portable/soft matrix;
- direct `gc.lua`;
- `gengc.lua --testc`;
- direct `constructs.lua` и `verybig.lua`;
- iterative-dispatch stress под 1-МБ host stack.

### Реалистичные performance milestones

PUC Lua оптимизировался десятилетиями, поэтому обещать 1.0× без изменения
codegen, layout и dispatch неправильно. Текущие milestones:

1. После P15.31: геометрическое среднее **<8×**. ✅ (достигнуто)
2. После P15.32–P15.33: геометрическое среднее **<3×**. ❌ (достигнуто 5.21×)
3. После P15.34–P15.35: геометрическое среднее **<2×**. ❌ (не достигнуто)
4. После P15.37: геометрическое среднее **≤3×**. ❌ (достигнуто 4.77×)
5. После P15.38a–h: геометрическое среднее **≤3×**. ❌ (достигнуто 3.43×)
6. Затем отдельные workloads доводятся до parity или небольшого выигрыша.

Оставшиеся hotspot'ы после P15.37 (требуют codegen-level работы, P15.38+):
- **Instruction-count bound dispatch** (`branch_loop`/`comparisons` ~98% в
  `runBytecodeDispatch`, IPC=4.24, branch-misses ≤0.02%) — CPU выполняет
  инструкции быстро, но их слишком много. Нужно: fewer opcodes per Lua
  iteration (codegen improvements), compact dispatch table.
- **`nodeLookup` ~28% на `global_arith`** — Node 48 B vs PUC 24 B. Полная
  parity требует variant TKey (int/str/etc packed в 8 байт).

Общий уровень PUC требует одновременно трёх архитектурных изменений:

- меньше bytecode-инструкций;
- компактный common-case dispatch;
- PUC-подобная плотность tables, GC objects и call frames.

### P15.38 — codegen-level opcode reduction (PUC 5.5 fast paths)

Цель: уменьшить число bytecode-инструкций на Lua-итерацию через PUC 5.5
codegen fast paths. Каждая подзадача устраняет 1–3 инструкции в common-case
паттернах (`s = s + 1`, `if a < b then`, `x = x + 1.0`).

- [x] **P15.38a — GETTABUP/SETTABUP metatable fast path.** Глобальные
  чтения/запись через `_ENV` upvalue проверяют `flags` bitmask перед
  `getFieldOpt(__index/__newindex)`. Устраняет 2 из 3 `nodeLookup` вызовов
  на каждый global access. **Результат:** global_arith 3.187→1.552s (-51.3%).
- [x] **P15.38b — VJMP conditional expressions.** `genComparisonExp`
  возвращает VJMP ExpDesc (CMP+JMP, 2 инструкции) вместо материализации
  boolean (5 инструкций). `genIf`/`genWhile`/`genRepeat` используют VJMP
  напрямую через `goIfTrue`/`goIfFalse`. `and`/`or` используют jump-list
  concatenation. **Результат:** branch_loop 2.576→1.442s (-44.0%),
  comparisons 4.112→1.566s (-61.9%).
- [x] **P15.38c — Direct-store to locals.** `genBinOp` принимает
  `dst_hint: ?u8`; `genAssign` для `local s; s = s + i` передаёт регистр
  `s` как hint, эмитя `ADD s, s, i` (1 instr) вместо `ADD tmp, s, i;
  MOVE s, tmp` (2 instr). **Результат:** int_arith 0.841→0.515s (-38.7%).
- [x] **P15.38d — Immediate comparison opcodes (EQI/LTI/LEI/GTI/GEI/EQK).**
  6 новых опкодов сравнивают R[A] с signed immediate (sB) или constant
  pool entry (K[B]), устраняя предшествующий LOADI/LOADK. Codegen:
  `genComparisonExp` принимает `rhs_const: ?NumConst`; когда RHS — малая
  целая константа, эмиттится immediate variant. VM: Int/Num fast path +
  metamethod fallback (materialized imm). **Результат:** comparisons
  1.928→1.566s (cumulative -61.9% vs P15.37), geomean 4.77×→3.69×.
- [x] **P15.38e — Eliminate PendingCallSlot.get() 760-byte copy.**
  `PendingCallSlot.get()` returned `BytecodePendingCall` by value, copying
  the 760-byte payload on every call — the source of `compiler_rt.memcpy`
  hotspot (10% of cycles on `lua_calls`). Changed `get()` to return
  `?*const BytecodePendingCall` (pointer). The `set()` copy remains (changing
  it caused code-layout regressions on `field_access`/`global_arith`).
  **Результат:** lua_calls 0.615→0.596s (-3%), memcpy 10%→<1% of cycles.
- [x] **P15.38f — Debug hook fast path (PUC `allowhook`/`hookmask` model).**
  Eliminated 8.4% debug hook overhead on `lua_calls` when no hooks are
  active. Two changes mirroring PUC Lua's debug hook architecture:
  (1) `hooks_active_cached` early-return at the top of
  `debugDispatchHookTransfer`, `debugDispatchHookWithCalleeTransfer`,
  `tryPushBytecodeDebugHook`, and `hasActiveHookEvent` — one bool read
  instead of linear frame search + `std.mem.eql` string compare (PUC's
  `hookmask` check);
  (2) moved `in_debug_hook` from Vm (global) to `DebugHookState` (per-thread,
  like PUC's `L->allowhook` on `lua_State`), with both sync and async hook
  paths setting/clearing it. `isInDebugHook()` simplified from O(n) linear
  search (`activeAsyncDebugHookFrame`) to O(1) per-thread flag read.
  Per-thread storage means coroutine yield/resume automatically switches to
  the correct thread's flag — no recompute on thread switch.
  **Результат:** lua_calls 6.53×→5.95× (-8.9%), geomean 3.74×→3.71×.
- [x] **P15.38g — GETTABLE/SETTABLE metatable fast path.**
  GETTABLE/SETTABLE were missing the `metatable == null` fast path that
  GETI/GETFIELD and SETI/SETFIELD already have. Without it, GETTABLE always
  called `tryPushBytecodeIndexMetamethod` (does a `rawGet` to check key
  existence) + `bytecodeIndexValue` (does another `rawGet`) — a double
  lookup. Now checks `obj.Table.metatable == null` first and does a single
  `rawGet`/`rawSet`, matching PUC's `luaV_gettable` fast path.
  **Результат:** array_access 6.62×→4.33× (-34.6%), hash_access 7.71×→5.25×
  (-31.9%), geomean 3.74×→3.53×.
- [x] **P15.38h — tostring() stack-buffer fast path.**
  Added `valueToInternedStr()` which writes Int/Num directly to a stack
  buffer and interns it, bypassing the heap allocation in
  `valueToStringAlloc` + `internStr`. Mirrors PUC's `luaO_tostring`
  (lobject.c:464): `char buff[LUA_N2SBUFFSZ]; luaO_tostringbuff(obj, buff);
  luaS_newlstr(L, buff, len)`. Falls back to heap alloc for non-numeric types.
  **Результат:** string_loop 3.91×→3.52× (-9.9%), geomean 3.53×→3.43×.
- [x] **P15.38i — PUC-style builtin results on bc_stack (eliminate dupe).**
  Architectural change: OP_CALL handler now writes builtin results directly
  to bc_stack (value stack) above the arguments, matching PUC Lua's model
  where C functions write results to `L->top.p`. Eliminates the `outs_small`
  local buffer, the `alloc.dupe` + `alloc.free` for debug hook transfer
  values on every builtin call (~14% of hash_access cycles), and the
  separate copy from outs to regs. `callBuiltin` tracks whether outs points
  into bc_stack (for future `refreshBuiltinOuts` re-derive in builtins with
  re-entry — PUC's savestack/restorestack equivalent). Debug hook only
  dupes when `hooks_active_cached` (slow path). OP_TAILCALL and OP_TFORCALL
  still use local buffers (their dupe is for return-value ownership, not
  debug hooks).
  **Результат:** dupe/free eliminated from perf profile. hash_access -4.6%,
  array_access -4.4%, geomean 3.43×→3.42×.

**Итог P15.38 (a–i):** geomean **4.77× → 3.49×** (-26.8% slowdown).
Цель ≤3× почти достигнута — оставшиеся hotspot'ы: `lua_calls` (6.0×,
call frame overhead), `hash_access` (5.2×, Node 48B vs 24B),
`field_access` (4.7×, table lookup). Дальнейший прогресс требует
variant TKey (P15.39+) и call frame compaction.

### P15.39 — variant TKey: Node 48B → 32B

Архитектурная PUC-faithful компрессия `ltable.Node` с 48 B до 32 B через
разделение `key: Value` (16 B tagged union) на 1 B type tag (`key_tt`) +
8 B raw payload (`key_val`), и удаление кэшированного `hash: u64` поля
(хеш пересчитывается на каждом use site, как в PUC `ltable.c`).

Field layout (32 B total):
- `value: Value` (16 B) — full tagged value
- `key_val: NodeKeyPayload` (8 B) — bare extern union
- `next_offset: i32` (4 B) — Brent chain link
- `key_tt: NodeKeyTag` (1 B) + 3 B padding

Cache-line density: 64 B line × 32 B node = **2 full nodes per line**
(было 1 при 48 B). Это качественный порог — дальнейшее сжатие до 24 B
(полная PUC parity) дало бы только partial третьего node и требует
изменения самого типа `Value` (отдельная задача P15.40+).

Architectural changes:
1. `NodeKeyTag = enum(u8)` с 9 вариантами (`empty`, `dead`, `int`, `num`,
   `string`, `table`, `closure`, `thread`, `bool_`). `empty` маркирует
   свободный slot, `dead` — dead key (PUC `LUA_TDEADKEY`).
2. `NodeKeyPayload = extern union` — tagless 8-byte union mirroring PUC
   `union Value` (lobject.h:49).
3. `Node.getKey()`/`setKey()` bridge methods reconstruct/store a full
   `Value` from/to the split tag+payload representation. Используются
   только в холодных путях (GC, итерация) — горячий путь lookup'а
   использует `Node.keyMatches()` (см. пункт 7).
4. `Node.rawHash(seed)` recomputes the hash from `key_tt`+`key_val` at each
   use site — PUC `ltable.c` does the same via inline `hashint`/`hashstr`/
   `hashpointer`/`hashboolean` calls.
5. Dead keys marked by `key_tt = .dead` instead of a high bit in `hash`
   (PUC `LUA_TDEADKEY` model). Payload cleared to sever stale pointers.
6. `keyHash(.Num)` теперь вызывает `hashNum` (раньше возвращал 0 для float
   keys — нарушение Brent invariant после swap, исправлено отдельно).
7. `Node.keyMatches(Value)` (добавлен в рамках Task 6 regression fix) —
   PUC-faithful inline `keyeq` без reconstruction полного `Value`. Раньше
   `nodeLookup` звал `keyEq(n.getKey(), key)`: switch по `key_tt` для
   сборки 16-байтного `Value` + switch по тегу в `keyEq`. Теперь один
   switch сравнивает tag и payload на месте, как макрос `keyeq` в PUC.

Migration strategy (6 tasks):
- Task 1: Add new types + accessor methods (no layout change)
- Tasks 2-4: Migrate ltable.zig / vm.zig / api.zig callers to accessors
  (transitional bridge writes keep both representations in sync)
- Task 5: Physical layout swap (drop `key`/`hash` fields, drop bridge writes)
- Task 6: Full regression + perf measurement + README update + Node.keyMatches
  fix для восстановления PUC-faithful горячего пути lookup'а

**Результат (median of 7, microbench, vs `tools/perf/baseline-p15.37.json`):**

| Workload | До P15.39 | После P15.39 | Изменение |
|---|---:|---:|---:|
| hash_access | 5.22× | 5.04× | -3.8% |
| field_access | 4.71× | 5.08× | +6.4% (WARN) |
| global_arith | 3.32× | 3.48× | +2.9% |
| array_access | 4.28× | 4.19× | -1.6% |
| lua_calls | 6.01× | 6.02× | +0.3% |
| geomean | 3.49× | 3.47× | -0.6% |

Microbench geomean нейтрален: cache плотность 32 B node не помогает
tiny tables (поля table `field_access`/`global_arith` — 2-3 ключа, полностью
в L1). Regression на `field_access` — архитектурная цена switch dispatch
в `keyMatches` против прямого чтения `Value` (однако +10.6% → +6.4% после
добавления inline `keyMatches`).

Cache плотность раскрывается на big tables (>L2):

| Workload (100K-key hash, 20M lookups) | До P15.39 | После P15.39 | Изменение |
|---|---:|---:|---:|
| Wall time | 1.87 s | 1.60 s | **-14.4%** |
| LLC cache-misses | 10.1 M | 1.7 M | **-83.2%** |
| L1-dcache-load-misses | 45.9 M | 27.1 M | **-41.0%** |
| Cycles (core) | 7.16 B | 6.06 B | **-15.3%** |

Parity preserved: 26/31 matrix pass без `_soft`/`_port` (без новых failures
сверх известных `attrib`/`db`/`nextvar`/`files`); 27/31 с `_soft`/`_port`.
44/44 smoke tests pass. Stress test pass.

### Выполнено: PUC-faithful Table + string interning (P13–P14)

Цель: закрыть главный parity/perf-блокер — `nextvar.lua` (~511× медленнее ref).
Дизайн (PUC-first): единый `Table` (array-part + hash-part с Brent's variation
chaining, см. `lua-5.5.0/src/ltable.c:13-24`) вместо текущих 4 карт, плюс
интернирование строк (аналог `lstring.c`). Строковые ключи сравниваются по
указателю на интернированную `LuaString`.

Зафиксированные отступления от PUC (Zig-идиомы):
- `Value` — tagged `union(enum)` вместо `TValue` (tag + union).
- `Node.next_offset` — `i32` signed index offset (PUC `gnext`), `dead_key` упакован в
  старший бит `hash` (P15.37b). Node = 48 B (было 56 B при `?*Node` + `bool`).
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

### Прочие открытые приоритеты

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
- [ ] Закрыть `heavy.lua` memory/perf gap в рамках P15.34/P15.37, не отдельным benchmark-specific хаком.
- [x] Профилировать bc_vm после достижения parity — выполнен свежий ReleaseFast профиль P15.30.1; baseline и bottlenecks зафиксированы выше.
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
- P15.37a: frame-struct slim — `BytecodeExecFrame` (936 B) и `BytecodePendingCall` (768 B optional) переведены на reuse-pool pattern (`addOne` + field-by-field writes) + `PendingCallSlot` wrapper (`active: bool` + `payload = undefined`, `clear()` = single-byte write), устраняя `compiler_rt.memset` (byte-wise zero-init структур фреймов, 57% от lua_calls) на каждом call/return. lua_calls 1.760→0.617s (-65%), metamethod_add 0.456→0.282s (-38%), memset share 53%→<1%.
- P15.37b: Node compaction — `ltable.Node` уплотнён с 56 B до 48 B: `next: ?*Node` (8 B + padding) заменён на `next_offset: i32` (4 B) PUC `gnext`-style signed index offset, а `dead_key: bool` упакован в старший бит `hash` (`DEAD_KEY_FLAG`). Hash маскируется (`HASH_MASK`) при записи, чтобы live-key хеши с установленным bit 63 не ложно определялись как dead. `nextNode` использует direct pointer arithmetic (`self + off * @sizeOf(Node)`) для chain walk без восстановления индекса. Паритет 28/31 сохранён, 44/44 smoke проходят, `nodeLookup` perf share ~28% (без регрессии).
- P15.37c: Table.flags bitmask (BITRAS) — добавлен `flags: u8` в `Table` (PUC `ltm.h:54`): bit set = "metatable не имеет метаметода". Проверяется перед `getFieldOpt(mt, "__index"/"__newindex")` в 5 точках. Сбрасывается при new-key insertion в `rawSet` (PUC `ltable.c:1112`). PUC-faithful metamethod cache. Доля metamethod-check упала с 11% до ~9% на global_arith (меньше ожидаемого — benchmark работает с `_ENV` без metatable).
- P15.37d: `tools/perf_compare.py` + `tools/perf/baseline-p15.37.json` — reproducible perf gate. Скрипт собирает ReleaseFast + PUC Lua, pinned `taskset -c 0`, медиана 7 прогонов на 16 workloads, таблица с geomean, regression check (WARN >5%, FAIL >10%), `--update-baseline`/`--perf`/`--runs`/`--core`/`--no-build`. Geomean P15.37: **4.77×** (было 5.21× после P15.36).

Детальная история оптимизаций, промежуточных замеров и закрытых подпунктов сохранена в Git (`git log`).
