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

## Движки (ref/zig)

`luazig` и `luazigc` поддерживают выбор движка:

- `--engine=ref` (по умолчанию): делегирует эталонному C Lua / C luac
- `--engine=zig`: использует Zig-реализацию (пока только лексер/parse-only в `luazigc`)

Также можно задать `LUAZIG_ENGINE=ref|zig`.

## Тесты (дифференциально)

Мы используем официальный test suite из upstream Lua как `git submodule`:

```sh
git submodule update --init --recursive
```

Прогон тестов сравнивает поведение эталонного `build/lua-c/lua` и `zig-out/bin/luazig`:

```sh
make test-suite
```

Примечание: в текущий момент `luazig` и `luazigc` это bootstrap бинарники, которые делегируют выполнение эталонному C Lua через переменные окружения `LUAZIG_C_LUA`/`LUAZIG_C_LUAC`. Это дает нам работающий harness и базовую инфраструктуру, после чего будем постепенно заменять компоненты на Zig.

## Компиляция (сравнение с luac -p)

Пока у нас нет VM, но уже можно сравнивать “компилируется/не компилируется” между `luac -p` и `luazigc --engine=zig -p`:

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

## Структура

- `lua-5.5.0/`: исходники эталонного Lua (как база для сравнения).
- `src/`: новая реализация на Zig.
- `tools/zig`: обертка, чтобы использовать либо локальный Zig (`tools/zig-bin/zig`), либо системный `zig`.
- `third_party/lua-upstream/`: upstream Lua (submodule) для `testes/`.
