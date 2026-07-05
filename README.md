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
- `lua-5.5.0/` — vendored PUC Lua reference source.
- `third_party/lua-upstream/` — upstream Lua repository с official `testes/`.
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
- `tools/testes_matrix.py` — пофайловая matrix по `third_party/lua-upstream/testes/*.lua`.
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

- [ ] **Phase A: интернирование строк.** `Value.String` → `*LuaString`
  (header + inline bytes + cached hash). `StringIntern` HashSet на Vm с per-VM
  `random_seed`. Все string-создающие сайты (lexer, `tostring`, `..`,
  `string.*`, `tonumber`, error-сообщения) через `intern()`. Равенство строк —
  pointer-eq. GC sweep intern-таблицы. Существующие 4 карты `Table` адаптируются
  key-context'ом (`bytes()`), структура не меняется. *Чекпоинт:* паритет ≥ 33/34,
  `zig build test` green, `memerr.lua` green.
- [ ] **Phase B1: инкапсулировать `Table` за внутренним API.** Ввести ≤12 методов
  (`get/getInt/getStr/getRaw/set/setInt/delete/next/length/rawIter/insert/remove`).
  Провести все 529 прямых обращений `.array/.fields/.int_keys/.ptr_keys` в
  `vm.zig` и 2 в `api.zig` через эти методы; представление под капотом НЕ менять.
  *Чекпоинт:* паритет ≥ 33/34, прямых обращений к картам вне методов нет.
- [ ] **Phase B2: swap `Table` на PUC array+hash.** `array: []Value` + `hash: []Node`
  + Brent chaining. Реализовать `getgeneric`/`newkey` (Brent's variation),
  `rehash` (`computesizes`), линейный `next()`, boundary-`length`. Удалить
  `next_hint_*` (7 полей), ~10 `nextFrom*/nextFirstLive*` функций, `hash_tombstones`
  и ~10 сайтов его учёта. GC-обход таблицы → линейно по array+hash.
  *Чекпоинт:* паритет ≥ 33/34; `nextvar.lua` ≥ 10× быстрее текущего; perf-guard green.

### Открытые приоритеты

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

Детальная история оптимизаций, промежуточных замеров и закрытых подпунктов сохранена в Git (`git log`).
