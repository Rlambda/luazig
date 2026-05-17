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
- Свежий matrix-срез P8.3: `32/34 pass parity` (`zig_fail=2`, `both_fail=0`, `both_fail_infra=0`, `zig_only_pass=0`). JSON: `tools/reports/testes_matrix_p8_3.json`.

### P8: закрыть базовую совместимость official suite

Перед расширением embedding API нужно стабилизировать базу: официальный suite должен быть понятен, измерим и максимально зелёный без test-specific обходов.

- [x] P8.1. Снять свежий полный `testes_matrix` с JSON-отчётом и обновить README фактическими числами pass/fail.
  - Команда: `tools/testes_matrix_safe.sh --json-out /tmp/luazig-testes-matrix-p8.1.json`.
  - Результат: `31/34 pass parity`; `zig_fail=3`, `both_fail=0`, `both_fail_infra=0`, `zig_only_pass=0`.
  - Failing suite: `all.lua` (`assertion failed`), `db.lua` (`assertion failed`), `heavy.lua` (`timeout`).
  - JSON-отчёт сохранён в `tools/reports/testes_matrix_p8_1.json`.
- [x] P8.2. Разобрать каждый оставшийся failing suite на категории: semantic zig-only, infra/resource, unsupported optional platform feature.
  - `db.lua`: semantic zig-only blocker. Конкретика: line hook после `debug.sethook(f, "l")` срабатывает 2 раза вместо PUC-ожидаемых 4; падает `db.lua:323` (`assert(count == 4)`). Следующий фикс: привести scheduling line hooks к PUC Lua, включая первое событие после установки hook и событие на строке `debug.sethook()` перед отключением.
  - `all.lua`: aggregate blocker. В текущем full-run он не является отдельным новым semantic case: suite проходит через общий runner и упирается в уже найденные блокеры `db.lua`/resource-heavy участков. Следующий фикс для semantic части: сначала закрыть `db.lua`, затем переснять `all.lua`.
  - `heavy.lua`: zig-only resource/performance blocker. Тест `toomanyidx()` заполняет таблицу до memory error; ref завершает путь, `luazig` не доходит до результата в текущем timeout. Следующий фикс: P8.4 должен честно определить ресурсный режим или runtime memory/error boundary, не маскируя timeout как parity.
- [x] P8.3. Закрыть все semantic zig-only failures из matrix без harness-нормализации и test-specific веток.
  - Исправлен PUC-like scheduling line hooks: первое событие после `debug.sethook` больше не пропускается, а строка отключающего `debug.sethook()` получает line event до снятия hook.
  - Count hooks переведены с low-level IR tick на bytecode-like hook points, чтобы tight numeric loops соответствовали PUC Lua ожиданиям (`db.lua` count-hook диапазоны).
  - Для suspended coroutine debug API разведены уровни `0` и `1`: обычный yield доступен через `debug.getinfo/getlocal(co, 1, ...)`, yield из debug hook остаётся на уровне `0`, как ожидает upstream `coroutine.lua --testc`.
  - `db.lua`: pass parity; `coroutine.lua --testc`: pass.
  - Fresh safe matrix: `32/34 pass parity`; оставшиеся `zig_fail` — `all.lua` и `heavy.lua`, оба перенесены в P8.4 как resource/long-run режим.
- [ ] P8.4. Зафиксировать честный режим для resource-heavy suite (`heavy.lua`, `all.lua`): либо parity при заданных ресурсах, либо документированный infra-only статус для обеих реализаций.
  - Критерий: нет suite, где zig-only failure маскируется как infra.
- [ ] P8.5. Обновить performance baseline после semantic-fix этапа.
  - Критерий: `nextvar.lua`, `coroutine.lua`, `gc.lua` имеют актуальный baseline и guard без ухудшения parity.

### P9: развить публичный Zig/C-like API после стабилизации базы

Этот этап начинается после P8, чтобы API не закреплял нестабильную внутреннюю семантику VM.

- [ ] P9.1. Описать целевой embedding API: lifecycle, stack, tables, calls, coroutine, debug, allocator/lifetime, error model.
- [ ] P9.2. Разделить API на публичный стабильный слой и VM-private internals; `T.testC` должен использовать только публичные входы там, где это применимо.
- [ ] P9.3. Расширить `src/lua/api.zig` до покрытия ключевых сценариев Lua C API, но с Zig-friendly ownership/error semantics.
- [ ] P9.4. Добавить интеграционные Zig API tests, эквивалентные upstream `api.lua` сценариям без зависимости от `T.testC` DSL.
- [ ] P9.5. Решить, нужен ли C ABI shim как поддерживаемый продукт или только smoke-compat слой поверх Zig API.

### История закрытых этапов

- P3: стабилизация базы до API закрыта; targeted parity suite проходили, `bc_vm` получил coverage gate, perf guard и runtime invariant audit.
- P4: начальный публичный Zig API и базовый C ABI shim добавлены.
- P5: `testC/ltests` compatibility доведена до прохождения `api.lua --testc`.
- P6: official `testC` lane стабилизирован; missing commands сведены к нулю; coroutine/testC path работает через runtime-семантику.
- P7: публичный Zig/C-like API для `testC` расширен до stack/table/thread primitives, generic `T.testC` команды переведены на API-входы, добавлен `tools/api_regression_lane.py`.
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
