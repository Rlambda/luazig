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

Цель: довести `luazig` до drop-in совместимости с PUC Lua 5.5.0 на официальном `testes`, затем расширять публичный Zig/C-like embedding API.

### Статус

- Базовая differential-инфраструктура работает: ref запускается напрямую через `build/lua-c/lua`, zig — через `zig-out/bin/luazig`.
- Official `testC` lane зелёный: `api.lua`, `coroutine.lua`, `errors.lua`, `strings.lua`, `locals.lua`, `memerr.lua`.
- Публичный API smoke/regression lane зафиксирован: `python3 tools/api_regression_lane.py`.
- Bytecode backend остаётся hybrid: поддержанные инструкции исполняются в `bc_vm`, неподдержанные безопасно откатываются в IR.
- Свежий matrix-срез P8.4: `33/34 pass parity` (`zig_fail=0`, `both_fail=1`, `both_fail_infra=0`, `zig_only_pass=0`). JSON: `tools/reports/testes_matrix_p8_4.json`.
- Core perf baseline обновлён после semantic-fix этапа: `tools/perf/core_baseline.json` (`nextvar.lua`, `coroutine.lua`, `gc.lua`), guard: `tools/perf_guard_core.py`.
- Следующий фокус P10: release/drop-in readiness (`heavy.lua`, performance, host build, release gates).

### P10: довести проект до release/drop-in readiness

P8/P9 закрыли базовую parity-картину и публичный Zig API. Следующий этап — убрать последние причины, по которым проект нельзя честно назвать готовым drop-in Lua.

- [ ] P10.1. Разобрать `heavy.lua` без bounded-time маскировки: определить, это runtime memory boundary, performance issue или некорректная OOM-семантика.
  - Критерий: `heavy.lua` либо проходит в документированном resource profile, либо имеет точный semantic/perf blocker с воспроизводимым минимальным сценарием.
- [ ] P10.2. Вернуть performance focus: `nextvar.lua` должен получить план оптимизации от текущих ~85s к разумному target, с профилем узких мест и PUC-first решением.
  - Критерий: есть свежий профиль и хотя бы один архитектурный perf шаг, не ухудшающий parity.
- [ ] P10.3. Починить host build/toolchain проблему без обязательного `-Dtarget=x86_64-linux-musl`.
  - Критерий: `./tools/zig build -Doptimize=Debug` и `zig build -Doptimize=Debug` имеют понятный supported path или документированное ограничение toolchain/libc.
- [ ] P10.4. Ввести release gates: короткий gate, full safe matrix, API lanes, perf guard, known limitations.
  - Критерий: один documented command set отвечает на вопрос “можно ли релизить этот commit?”.
- [ ] P10.5. Подготовить readiness report: что уже совместимо с PUC Lua, что не совместимо, что является perf-only, что является unsupported API surface.
  - Критерий: README содержит честный статус готовности без завышения production/drop-in claims.

### История закрытых этапов

- P3: стабилизация базы до API закрыта; targeted parity suite проходили, `bc_vm` получил coverage gate, perf guard и runtime invariant audit.
- P4: начальный публичный Zig API и базовый C ABI shim добавлены.
- P5: `testC/ltests` compatibility доведена до прохождения `api.lua --testc`.
- P6: official `testC` lane стабилизирован; missing commands сведены к нулю; coroutine/testC path работает через runtime-семантику.
- P7: публичный Zig/C-like API для `testC` расширен до stack/table/thread primitives, generic `T.testC` команды переведены на API-входы, добавлен `tools/api_regression_lane.py`.
- P8: базовая совместимость official suite закрыта до `33/34 pass parity`; `zig_fail=0`, `all.lua` проходит в bounded safe matrix, `heavy.lua` честно классифицирован как общий resource-heavy timeout; core perf baseline обновлён.
- P9: публичный Zig embedding API отделён от internals, добавлен public API integration lane, C ABI shim оставлен smoke-compat слоем поверх Zig API.
- Детальная история оптимизаций, промежуточных замеров и закрытых подпунктов сохранена в Git (`git log`).

### Быстрые команды

```sh
zig build -Doptimize=Debug
python3 tools/run_tests.py --suite nextvar.lua --suite coroutine.lua --suite calls.lua --suite locals.lua --suite db.lua --suite gc.lua --suite files.lua
python3 tools/testes_matrix.py --no-build --timeout 120
tools/run_with_limits.sh --mem-max 8G --mem-high 7G --timeout 1800 -- \
  python3 tools/testes_matrix.py --no-build --timeout 120
# Defaults are safer for Codex session stability:
tools/run_with_limits.sh --timeout 1800 -- \
  python3 tools/testes_matrix.py --no-build --timeout 120
# Recommended safe entrypoint (always uses memory-limited wrapper):
tools/testes_matrix_safe.sh
# Optional: override per-file timeouts, e.g. for long all.lua on low-RAM hosts
LZ_TEST_TIMEOUT_OVERRIDES="all.lua=300,heavy.lua=240" tools/testes_matrix_safe.sh
# Host entrypoint for real files.lua parity (outside sandbox):
tools/testes_matrix_host.sh
# Dedicated long-run lane for heavy.lua:
tools/heavy_safe.sh
```
