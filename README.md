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

bc_vm проходит **14/29 test suites**: api, bitwise, bwcoercion, calls, closure, code, events, math, memerr, pm, sort, strings, tracegc, utf8.

IR VM (frozen snapshot) проходила 32/33 suites. Результаты сохранены как reference.

Ограничения:

- bc_vm активно дорабатывается: 15/29 suites ещё падают.
- Производительность bc_vm не профилировалась (в разработке).
- IR VM доступна через `--vm=ir` для отладки, но не гарантируется от регрессий.
- C ABI shim остаётся smoke/compat слоем поверх Zig API.
- Production/drop-in статус пока не заявляется.

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

### Открытые приоритеты

- [x] **IR VM заморожена, bc=default.** Default backend переведён на `--vm=bc`.
  IR VM (`--vm=ir`) сохранена как debug fallback, parity не поддерживается.
  `run_tests.py` и `testes_matrix.py` явно используют `--vm=bc`.
  `release_gate.sh` гоняет bc (большинство suites failing — прогресс-трекер).
  `zig build test` продолжает гонять IR unit-тесты (они тестируют shared runtime).
- [ ] **Perf: IR-VM interpreter speed** — заморожено вместе с IR VM. Профилирование
  bc_vm — после достижения parity.
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
- [ ] Профилировать bc_vm после достижения parity.
- [ ] Развивать публичный Zig embedding API после стабилизации bc_vm.
- [x] Держать README, release gate и perf baselines актуальными после текущей GC/string фазы.

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

Детальная история оптимизаций, промежуточных замеров и закрытых подпунктов сохранена в Git (`git log`).
