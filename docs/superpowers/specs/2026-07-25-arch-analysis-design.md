# luazig Architectural Analysis — Design Spec

**Дата**: 2026-07-25
**Статус**: approved
**Тип**: архитектурный анализ-сравнение PUC Lua 5.5.0 vs luazig

## Цель и аудитория

Гибридный документ: внутренний roadmap + внешний технический обзор.

- **Roadmap-цель**: дать обоснованную базу для решений по фазам P15.40+ — где
  отклонения от PUC оправданы, где маскируют parity-блокеры, что менять.
- **Обзор-цель**: зафиксировать ключевые инженерные trade-offs между C-реализацией
  PUC Lua и Zig-реализацией luazig, lessons learned, что Zig даёт лучше/хуже.

Аудитория: контрибьюторы luazig, автор roadmap-решений, внешние читатели
с интересом к Lua internals и Zig.

## Скоуп

Четыре подсистемы, каждая вглубь:

1. **Runtime core**: Value representation, Table layout, hash function,
   string interning, GC (mark/sweep/generational), global_State/Vm,
   metatable registry.
2. **Bytecode VM и call machinery**: dispatch loop, CallInfo/FrameStack,
   call protocol, coroutine yield/resume, error unwind, TBC `<close>`,
   C stack overflow policy.
3. **Parser и codegen**: AST, freereg model, jump backpatching, Proto layout,
   constant pool, opcode set parity.
4. **Zig-facing API и C ABI shim**: state handle, lua_*/Lua API, testC,
   embedding API, C ABI совместимость.

## Формат сравнения

Гибрид: каждое ключевое решение — отдельная секция внутри главы-подсистемы.

### Шаблон решения

```markdown
### Решение N: <название>

**PUC way**: <как в l*.c, с file:line ссылками на lua-5.5.0/src/>
**luazig way**: <как в src/lua/*.zig, с file:line ссылками>
**Почему так**: <обоснование отклонения или сохранения parity>
**Trade-off**: <что выиграли / что потеряли>

| Критерий              | Оценка | Обоснование |
|-----------------------|--------|-------------|
| Correctness parity    | 1-5    | ...         |
| Performance           | 1-5    | ...         |
| Maintainability       | 1-5    | ...         |
| Zig-idiomaticity      | 1-5    | ...         |

**Категория**: parity | better | worse | intentional-divergence
**Roadmap impact**: <влияние на фазы P15.40+ и далее>
```

### Шкала оценок (многомерная, 1-5)

| Критерий | 1 | 3 | 5 |
|----------|---|---|---|
| Correctness parity | грубое расхождение семантики | частичная parity | полная parity с PUC |
| Performance | кратно хуже PUC | сопоставимо, но медленнее | на уровне или лучше PUC |
| Maintainability | запутано, хрупко | читаемо, но с шероховатостями | образцово, самодокументирующееся |
| Zig-idiomaticity | C-in-Zig (ручные union/ptr) | смешанный стиль | идиоматичный Zig (tagged union, allocators, slices) |

Категория — отдельное текстовое поле, не сводится к среднему оценок.

## Структура файлов

```
docs/arch-analysis/
├── README.md                      # индекс + executive summary
├── 01-runtime-core.md             # решения 1-7
├── 02-vm-call-machinery.md        # решения 8-14
├── 03-parser-codegen.md           # решения 15-20
├── 04-api-abi.md                  # решения 21-25
└── 05-roadmap-synthesis.md        # сводка вердиктов → рекомендации
```

### README.md (индекс + executive summary)

- Текущий статус parity (29/29 suites, 3.47× perf gap, ReleaseFast baseline)
- Сводная таблица всех 25 решений с категорией и 4 оценками
- Топ-3 архитектурных преимущества luazig над PUC
- Топ-3 архитектурных риска / расхождения
- Навигация по главам с якорями

### 01-runtime-core.md — решения 1-7

1. **Value representation**: PUC `TValue` (16B, `ttis_` macros via `Value`+`tt`) vs luazig `Value = union(enum)` (Zig native tagged union).
2. **Table layout**: PUC `Table` (`alimit`+`node[]`+`lastfree`+`sizearray`) vs luazig `Table` (variant TKey/Node, array part).
3. **Hash function**: PUC `luaS_hash` (Lua hash with random seed) vs luazig multiply-based hash для int/num/ptr, wyhash убран.
4. **String interning**: PUC `stringtable` (array of `TString*` buckets) vs luazig `StringIntern` (AutoHashMap).
5. **GC core**: PUC incremental+generational (`g->gcstate`, `GCSpropagate` etc.) vs luazig `GcState` phases (incremental+generational).
6. **global_State**: PUC `global_State` + `lua_State` main thread vs luazig `Vm` struct.
7. **Metatable registry**: PUC basic type metatables on `G->mt[]` vs luazig `*_metatable` fields на `Vm`.

### 02-vm-call-machinery.md — решения 8-14

8. **Dispatch loop**: PUC `luaV_execute` switch-in-loop vs luazig dispatch loop (`vm.zig`).
9. **CallInfo stack**: PUC `CallInfo` array on `lua_State` vs luazig `FrameStack`/`CallFrame`/`BytecodeExecFrame`.
10. **Call protocol**: PUC `luaD_precall`+`tryfuncTM` vs luazig `BytecodePendingCall`/`PendingCallSlot`.
11. **Coroutine yield/resume**: PUC `lua_resume`+`luaD_throw` longjmp vs luazig `BytecodeCoroutineContinuation`+`ThreadSwitch` signal.
12. **Error unwind**: PUC `longjmp`-based `luaD_throw` vs luazig `BytecodeUnwindState`+`activation_id`.
13. **TBC `<close>`**: PUC `luaF_close` LIFO scan vs luazig `BytecodeCloseContinuation`.
14. **C stack overflow policy**: PUC `LUAI_MAXCCALLS`+native stack vs luazig Lua-side frame/stack limits.

### 03-parser-codegen.md — решения 15-20

15. **AST**: PUC single-pass (parser→lcode.c, без AST) vs luazig explicit `ast.zig`.
16. **Freereg model**: PUC `freereg` на `FuncState` vs luazig LIFO register allocation.
17. **Jump backpatching**: PUC `jpc`/`jpt` patch lists vs luazig backpatching.
18. **Proto layout**: PUC `Proto` struct vs luazig `bc.Proto`.
19. **Constant pool**: PUC `k` array vs luazig dedup pool.
20. **Opcode set parity**: PUC `lopcodes.h` vs luazig `bytecode.zig`.

### 04-api-abi.md — решения 21-25

21. **State handle**: PUC `lua_State*` vs luazig `*Thread`/`*Vm`.
22. **C API**: PUC `lua_push*`/`lua_to*` vs luazig `api.zig` Zig-facing API.
23. **testC**: PUC `ltests.c` testC vs luazig `testc.zig`.
24. **Embedding API**: PUC `luaL_*` auxlib vs luazig embedding API.
25. **C ABI shim**: luazig `c_api.zig` — насколько близко к PUC ABI, что отсутствует.

### 05-roadmap-synthesis.md

- Сводная таблица вердиктов по всем 25 решениям (категория + 4 оценки + magnitude).
- Что менять в P15.40+ на основе анализа.
- Архитектурные риски: где divergences могут ломать parity при future work.
- Рекомендации по приоритизации следующих фаз.
- Явные TODO с критериями удаления для intentional-divergences (по AGENTS.md).

## Источники для анализа

- **PUC**: `lua-5.5.0/src/*.c` и `*.h` (32k LOC).
- **luazig**: `src/lua/*.zig` (43k LOC; `vm.zig` доминирует — 27.9k).
- **Существующий README** (167k) — переиспользуем уже зафиксированный анализ.
- **`docs/superpowers/specs/*.md`** — 5 существующих дизайн-доков (memset, expdesc, callinfo, host-recursion, opcode-extraction).
- **`docs/REGRESSION_*.md`** — зафиксированные регрессии (xpcall traceback).

## Code references policy

- **Глубина**: средняя — 2-5 `file:line` ссылок на каждое решение (PUC + luazig).
- **Без длинных цитат**: читатель открывает исходники по ссылке.
- **Формат ссылок**: `lua-5.5.0/src/ltable.c:142` и `src/lua/ltable.zig:87`.
- **Валидация**: все ссылки проверяются grep'ом по указанным строкам перед
  завершением (verification-before-completion skill).

## Процесс написания

### Шаг 1: Worktree setup

- Добавить `.worktrees/` в `.gitignore` (если ещё не там).
- Закоммитить изменение `.gitignore`.
- Создать worktree: `git worktree add .worktrees/analysis-arch -b analysis-arch`.
- Worktree изолирует аналитическую работу от активной разработки на master.

### Шаг 2: Параллельный сбор фактов (4 explore-агента)

Распараллелить 4 explore-агента — по одному на подсистему. Каждый агент:

- Читает соответствующие PUC `.c`/`.h` файлы и luazig `.zig` файлы.
- Для каждого решения из спеки собирает: PUC way (с file:line), luazig way
  (с file:line), первичное обоснование trade-off.
- Возвращает структурированный набор фактов, не финальный текст.

Точность explore: `very thorough` — нужны конкретные file:line ссылки.

### Шаг 3: Синтез глав (последовательно)

Из собранных фактов пишутся 4 главы-подсистемы. Каждая глава:

- Сначала получает раздел «Краткое описание подсистемы» (1-2 абзаца).
- Затем решения по шаблону выше.
- После написания — inline-проверка: все ссылки валидны, все вердикты
  подкреплены фактами.

### Шаг 4: Executive summary + roadmap synthesis

- `README.md` (индекс + executive summary) пишется последним, когда все 4 главы
  готовы — сводная таблица вердиктов требует финальных оценок.
- `05-roadmap-synthesis.md` пишется после executive summary, синтезирует
  выводы в roadmap-рекомендации.

### Шаг 5: Self-review

- Placeholder scan: нет ли TBD/TODO/неполных секций.
- Internal consistency: оценки в таблицах совпадают с текстом.
- Scope check: 25 решений — адекватный скоуп, не раздуто.
- Ambiguity check: каждое обоснование trade-off конкретно.

### Шаг 6: User review gate

Пользователь ревьюит spec и финальные документы перед переходом к
implementation plan (если нужен отдельный план для follow-up работ).

### Шаг 7: README update (по AGENTS.md)

После завершения фазы — обновить корневой `README.md` ссылкой на новый
`docs/arch-analysis/`. AGENTS.md требует обновления README после каждой фазы.

## Верификация

- Все `file:line` ссылки валидны (grep по указанным строкам в обоих кодовых базах).
- Все 25 решений имеют полный шаблон (PUC way / luazig way / почему / trade-off / 4 оценки / категория / roadmap impact).
- Сводная таблица в README содержит все 25 решений.
- `python3 tools/testes_matrix.py` регрессий не вносит (документация-only).
- Все smoke-тесты в `tests/smoke/` проходят (документация-only, но проверяем
  что ничего не сломали в worktree setup).

## Out of scope

- Performance benchmarking (используем существующий baseline 3.47× из README).
- IR VM (заморожена, не анализируется).
- Сравнение с другими Lua implementation (LuaJIT, LuaVela, etc.) — только PUC.
- Изменения кода — это analysis-only документ, не implementation plan.
- Конкретный implementation plan для P15.40+ — это следующий шаг после
  roadmap synthesis, отдельный документ через writing-plans skill.

## Риски и митигации

- **Объём**: 25 решений × 4 подсистемы могут дать 3000+ строк.
  Митигация: шаблон жёсткий, ссылки вместо цитат, параллельная работа.
- **Качество оценок**: субъективные оценки могут быть оспорены.
  Митигация: каждое обоснование подкреплено code reference, вердикт
  выводится из фактов, не наоборот.
- **Устаревание**: код меняется активно, документ может устареть.
  Митигация: worktree фиксирует snapshot на момент анализа; в README
  указать commit hash, на котором делался анализ.
- **PUC-first bias**: AGENTS.md требует PUC-first, но документ должен
  фиксировать и случаи, где Zig-путь лучше. Митигация: явная категория
  `better` для таких случаев, без автоматического предпочтения PUC.
