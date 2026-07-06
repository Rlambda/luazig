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

Коротко: проект находится в pre-release / parity-focused состоянии. Это уже рабочая реализация, которая проходит большую часть official suite, но ещё не production-ready drop-in Lua.

Сейчас проходит:

- `zig build -Doptimize=Debug`
- `tools/release_gate.sh`
- targeted parity gate: `nextvar.lua`, `coroutine.lua`, `calls.lua`, `files.lua`, `locals.lua`, `db.lua`, `gc.lua`
- official `testC` lane: `api.lua`, `coroutine.lua`, `errors.lua`, `strings.lua`, `locals.lua`, `memerr.lua`
- safe matrix: `33/34 pass parity`, `zig_fail=0`, `both_fail=1`

Оставшийся known blocker:

- `heavy.lua` остаётся единственным `both_fail` в bounded safe matrix: это resource-heavy timeout / memory-perf gap.
- Lua-level OOM object уже сохраняется, но table size до OOM и performance profile всё ещё заметно отличаются от PUC Lua.

Ограничения:

- Производительность всё ещё существенно ниже PUC Lua на известных hot suites (`nextvar.lua`, `coroutine.lua`, `gc.lua`).
- Bytecode backend пока hybrid: поддержанные инструкции исполняются через `bc_vm`, неподдержанные безопасно откатываются в IR.
- C ABI shim остаётся smoke/compat слоем поверх Zig API, а не полной бинарной заменой Lua C API.
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

Основной runtime path сейчас:

- `src/lua/lexer.zig` читает source bytes и выдаёт tokens.
- `src/lua/parser.zig` строит AST.
- `src/lua/codegen.zig` lowering AST -> high-level IR.
- `src/lua/vm.zig` исполняет IR и содержит stdlib/runtime semantics.
- `src/lua/lower_ir.zig` и `src/lua/bc_vm.zig` обеспечивают experimental bytecode backend для части инструкций.
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

Текущий ожидаемый результат gate: `release gate: OK`.

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

- [ ] **Perf: IR-VM interpreter speed** — реальный bottleneck для `nextvar`
  (RF 1.48s ~23× от ref; Debug 29.5s — почти полностью debug-overhead). Table
  structure более не причина. Нужен профиль dispatch-loop'а и/или расширение
  `bc_vm` с cache-test'ом.
- [ ] **GC sweep-pass:** реализовать настоящий mark+sweep для всех объектов
  (tables/closures/threads/strings). Сейчас `gcCycleFull` только вычищает
  weak-таблицы и запускает `__gc`-финализаторы — mid-run освобождения нет ни для
  одного типа (vm.zig:5857). Без этого string-only sweep некорректен
  (use-after-free от строк, на которые ссылаются несвипаемые таблицы).

  **GC Phase (в разработке):** per-type `ArrayList(*T)`-реестры на Vm
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
  - [ ] **Closure/Thread/Cell sweep** — аналогично; main_thread всегда alive;
    Cell shared (реестр-put идемпотентен по указателю).
  - [ ] **Real memory accounting** — заменить фейк `gc_count_kb=0` на реальный
    charge/discount; tuning alloc-trigger.
  - [ ] **String sweep** — traverse `Value.String` в mark-фазе; координация с
    `string_intern`/`long_literals`.
- [ ] **Убрать `const_strings`/`internConstString`** — вынести в Phase B: ещё ~20
  живых call site'ов (ключи 4-map `Table`, status/diag-строки); удаление связано
  с унификацией Table под `*LuaString`-ключи.
- [ ] Закрыть `heavy.lua` memory/perf gap PUC-first способом.
- [ ] Продолжить оптимизацию table/string/VM hot paths без потери parity.
- [ ] Уменьшать hybrid IR/bytecode gap и двигаться к более плотной VM architecture.
- [ ] Развивать публичный Zig embedding API после стабилизации runtime blockers.
- [ ] Держать README, release gate и perf baselines актуальными после каждой фазы.

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

Детальная история оптимизаций, промежуточных замеров и закрытых подпунктов сохранена в Git (`git log`).
