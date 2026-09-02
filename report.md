# Отчёт: P16.10a→P16.10b — callable-метаметоды, dispatch-floor, Proto lifetime (4b6d6af..f2dc7d1)

Период: 29–30 августа 2026. 19 коммитов. Вход: `4b6d6af` (P16.10a final,
geomean 1.84x). Выход: `f2dc7d1` (P16.10b final) — **geomean 1.79x**, полный
гейт зелёный, закрыты три блока корректности (callable-семантика,
dispatch-floor модель, Proto lifetime + цепочка GC-багов).

Задания поступали от верификатора тремя порциями: P16.10 (dispatch-floor
analysis), P16.10a (callable-metamethod parity), P16.10b (Proto lifetime /
ownership closure). Часть работы потеряна/восстановлена после трёх OOM-обрывов
хоста (включая один инцидент с бинарным мусором в vm.zig) — отмечено в
хронологии.

---

## Часть 1. P16.10 — dispatch floor (measurement-first)

Верификатор запретил computed-goto «потому что PUC использует» — сначала
доказать, что генерирует ReleaseFast.

### T0 — зачистка P16.9 (`796de88`)
- Комментарий `gcTableBarrierBackSlow` приведён к факту (inline — измеренное
  решение; noinline давал layout-регрессию).
- rawSet rehash-барьер: доказано по цепочке file:line, что tableResize
  collector-free (сырой alloc + чистый учёт) → единственный pre-барьер
  корректен; комментарий исправлен, код не тронут.
- STATUS «Last updated» автоматизирован (tools/status/phase.txt, пишет
  status_snapshot --phase).
- Числа P16.9 приведены к артефакту: медианы 339.1±38 / 190.1±18 (было
  скопировано «377» из одного прогона).

### T1-T3 — измерение пола (`03422b1`)
Versioned-артефакт `tools/perf/current-dispatch-floor.json` +
`tools/perf_dispatch_floor.py`:
- **forloop_only steady-state**: zig 75.0 instr/iter vs PUC 28.0 (cycles
  13.9 vs 10.3; wall 3.58 vs 2.72 ns/iter).
- **Lowering switch(op)**: ПЛОТНАЯ JUMP-TABLE (128 записей, 32-бит offsets),
  2 dispatch-сайта, горячий путь использует ОДИН → «computed goto» не
  диагноз: преимущество (единый BTB-сайт) уже реализовано.
- **Компонентные дельты** (stash-dance, всё откачено): SIGINT +7, stack-poll
  +3, vmstats +2, hooks +2, dispatch_pc +1; all-removed floor +14 из 47
  лишних инструкций.

### T4-T8 — аудиты и чистые выиграши (`f943e3b`, `5b26e58`, `220eaf0`)
- **P15.33-аудит**: «отдельный compact loop» НИКОГДА не существовал —
  документационный миф; зафиксировано.
- **Stack-poll удалён** (75→72): полная классификация realloc-путей — все
  refresh-or-exit; инвариант записан у цикла.
- **SIGINT передизайн** (72→70): root cause — давление регистров от любой
  пер-инструкционной переменной; boundary-only чек без переменной;
  embedding-пользователи платят 0 (const false → dead-code).
- dispatch_pc (+1) и hooks (+2) — оставлены с обоснованием (PUC сам платит
  ≥ столько; fail() на 954 сайтах).
- Итог: **75→70 instr/iter**; fresh profile → frame-push отложен по данным
  (SETTABUP-барьер и dispatch-инфляция выше).

---

## Часть 2. P16.10a — callable-metamethod parity (BLOCKER)

Воспроизведён и подтверждён лично: metamethod-ПОЛЕ с callable-значением
(`__add = mm` где `getmetatable(mm).__call`) — PUC печатает 42, zig падал
«attempt to call a table value (metamethod 'add')». Старый smoke-кейс
«__call-valued metamethod» тестировал лишь обычный callable-table — ложное
покрытие.

### Архитектурный фикс (`f9eeec4`)
PUC-двухстадийная модель: (1) TMS/metafield-резолюция — БЕЗ `__call`-логики
внутри; (2) вызов резолвнутого Value через **обычную** callable-семантику —
`resolveCallable` ровно один раз: direct Builtin/Closure → zero-alloc;
иначе `__call`-цепочка со стандартной трансформацией аргументов (self
 prepended). Покрыто: MMBIN/UNM/BNOT/LEN/EQ/LT/LE/CONCAT/__tostring/__gc.
**__index/__newindex НЕ через generic-callable** — их non-function значения
следуют table-index chaining (граница зафиксирована комментарием).
Ошибки: `namewhat="metamethod"` → точные PUC-тексты трёх вариантов.

### Тесты (`bf4df90`) + resolve-once (`1f35e70`)
- `64_callable_metamethods.lua` (A–H: precedence, anti-cache мутации, 12
  событий, flips, unary, yield, hooks) — byte-identical.
- `pushResolvedBytecodeClosure` — общий примитив «push ЗАВЕДОМО
  резолвнутого bytecode-Closure с готовыми args»; direct-Closure-путь
  больше НЕ вызывает resolveCallable: **noalloc −8.5%, resolveCallable 0% в
  профиле**, geomean 1.84x.

### T4-T11 — остальное фазы
- simple_result **транзакционность** (`3858a5c`): errdefer-rollback между
  set и активацией; FailingAllocator-тест (5 отказов → родитель byte-exact
  нетронут; тест красный при отключённом errdefer).
- dispatch-floor артефакт когерентен (Option A: head 1f35e70, sha256
  бинарей; исторические эксперименты — отдельная секция с source-head).
- **Frame-push классификация** (44 операции / 9 категорий): найден
  provably-redundant `activeErrorHandlerDepth()` (11.3% функции).
- **Proto-ownership аудит**: вердикт «NOT CLEAN» — k мутируется
  VM-указателями, resolved_values VM-аллоцирован, resolve не рекурсивен —
  5 обязательных изменений до переноса резолюции.
- Lazy handler-limit + «stack overflow» паритет текста (`86de1f9`).
- Финал: noalloc 2.93→2.71x; resolveCallable=0%; frame-push остаётся
  легитимной целью (теперь над ним нет мёртвых generic-вызовов).

---

## Часть 3. P16.10b — Proto lifetime / ownership (3 блокера)

### Блокер 2 → strip как свойство сериализации (`5e23caf`, `3d4cbde`, `c455b9c`)
- `string.dump(f,true)` в цикле: **611 MB/decade LINEAR** (control flat).
  Root: `cloneStrippedProto()` — shallow-borrow клон, никогда не
  освобождался, generic deinit для него был бы неверен.
- Фикс: `DumpOptions{strip}` в dump.zig — strip = опция СЕРИАЛИЗАЦИИ
  (PUC DumpState.strip), клон удалён полностью (grep=0). Что опускается:
  source/name→пусто, lineinfo 0, locvars 0, имена upvalue'ов — с
  undump-совместимостью по чтению. Бонус-паритет: getinfo `=?`/`?`,
  ошибки `?:?:`, traceback `?:` (нашли и предсуществующее `?:0:`
  расхождение).
- Lane'ы: repeated_stripped_dump/plain_dump/dynamic_load постоянные; тесты:
  smoke 65 (roundtrips обоих режимов, вложенные деревья) + c_api 18_dump
  (lua_dump strip=0/1). Результат: **611→0.16 MB/decade**.

### Блокер 1+3 → ProtoTreeOwner (`94bf0a2`, `3b524f4`)
- `load()` в цикле: **2333 MB/decade**; `collectgarbage("count")≈0` —
  native-утечка вне GC-учёта. Root: `gcFreeObject(.closure)` никогда не
  освобождал Proto (комментарий «Closure owns the Proto» был ложью);
  `pinned_source_strings` держал источники до VM-deinit.
- **Inventory** (`b946c7b`, tools/ownership/proto-inventory.json): все
  production-точки создания Proto (два конструктора: ProtoBuilder.finish и
  UndumpReader.undumpProto); OP_CLOSURE не создаёт (shares); string.dump
  после T1 не создаёт; кросс-VM шаринга в production НЕТ.
- **ProtoTreeOwner** (Option A — refcounted tree): root+allocator+ref_count
  +vm-тег + source_backing; Closure несёт owner-ref; gcFreeObject
  release'ит; ПОСЛЕДНИЙ release деинитит дерево ровно один раз
  (структурно — без boolean-хаков владения). Parent-умер/child-живёт —
  безопасно через общий refcount. OOM-дисциплина: producer-ref +
  errdefer на каждой передаче.
- **Source backing** (`3b524f4`): пины живут на дереве, GC-маркируются
  через closure-traversal (gcMarkBytecodeProto — PUC traverseLClosure);
  `Vm.pinned_source_strings` УДАЛЁН. **load lane → 0.00 MB/decade**.
- **Adoption** (`591f120`, моя ручная доводка после OOM-обрыва):
  резолюция констант на границах (createBytecodeClosure + runBytecode) —
  `resolveProtoConstants` УДАЛЁН из push/tailcall (Debug-tripwire вместо
  него); two-phase resolve (стадирование без мутации → публикация) —
  retry-safe при OOM. Устранён и `constants_resolved`-хак владения.
  Тест: smoke 66_proto_lifetime (child-outlives-root: вложенность>2,
  несколько детей одного дерева, drop root/siblings, GC между вызовами,
  dump после смерти root, getinfo).

### Крэш-сага locals.lua (самая длинная часть фазы)
После adoption матрица продолжала падать -11 на locals.lua, standalone —
зелёный. Инструментарий: gdb-under-matrix, coredumpctl, reproduction-бисект
(свыше 30 прогонов), маркерные сборки locals.lua, поэлементные комбинации
блоков. Найденная цепочка независимых багов:

1. **Три дублированных varargs-слайса** `[func_slot-nextra]` без учёта
   vararg-TABLE-режима (аргументы при base+numparams, НЕ ниже func_slot):
   gcMarkMutableRoots, select-варарг (opReturn), gcPropagateOne parked-walk.
   Для таблиц-режима слайс читал ЧУЖИЕ регистры → маркировал мусор как
   объекты → «висячая метатаблица в fastTm» (первый coredump-backtrace).
   Fix: единый mode-aware `frameVarargs()` (`591f120`, `e33daf6`).
2. **Callable-__close yield при смертельной ошибке**: PUC закрывает TBC
   noyield (luaD_throw→luaE_resetthread→closeprotected(yy=0)→callnoyield) —
   yield из __close = «C-call boundary»; luazig разрешал (минимальный репро
   tbcz/tbcw). Fix: noyield при bottom-propagate unwind; вторая итерация —
   вместо sticky-флага вычисление по факту из списка unwind-состояний
   (sticky тек через interleaved-эпизоды).
3. **`@intFromFloat` без i64-guard** в codegen (rhsConstUsableForCmp /
   normalizeCmpConst): константы вроде 1e308 — Debug integer-overflow,
   ReleaseFast UB (матричные SIGABRT в math/api/strings).
4. **Weak-key clearKey без setempty**: PUC (lgc.c:796-798) сначала
   опустошает value, потом deaden — мы деденили ключ при живом value.
5. **ГЛАВНЫЙ (`8937c9b`)**: прямые GC-барьеры (gcWriteBarrierCell /
   gcStoreClosureEnv / gcStoreMetatable) делали `gcSetBlack` БЕЗ траверса
   детей — PUC luaC_barrier_ кладёт в gray-list (reallymarkobject).
   Дети оставались белыми → sweep освобождал → вся UAF-цепочка. Плюс:
   gcResetCycleState чистил gc_gray в минорах (PUC youngcollection не
   чистит); gcAtomicCommon Step 13 теперь всегда дренирует gray;
   parked-корутины обходятся по live_reg_top[pc] (не stack_top).

Механика ловли: Debug-бинар в матрице → чистые panic-трейсы; coredumpctl
для RF; комбинации t*/s*/pfx*-файлов локализовали накопительный характер;
последний шаг (агент) доказал барьерный root-cause инструментальными
принтами и закрыл всё пачкой фиксов.

### Отложено (TODO в коде)
`traverseupvalue`-эквивалент для cell-arm в gcPropagateOne — PUC-faithful
путь экспонирует предсуществующий бф (cell values освобождаются sweep'ом);
отдельная задача.

---

## Хронология коммитов

| Хэш | Суть |
|---|---|
| 796de88 | T0: stale-комментарии/STATUS/числа P16.9 |
| 03422b1 | T1-T3: dispatch-floor артефакт + jump-table + компоненты |
| f943e3b | T6: stack-poll удалён (75→72) |
| 5b26e58 | T8: SIGINT boundary-only (72→70) |
| 220eaf0 | T4-T10: STATUS-аудиты фазы |
| 6127c9d | P16.10 final: снапшот 1.82x |
| f9eeec4 | callable-метаметоды: PUC two-stage |
| bf4df90 | smoke 64 (A-H) |
| 1f35e70 | pushResolvedBytecodeClosure (noalloc −8.5%) |
| e4e384b/7e6241c/c4e641e | артефакты T13-T16 |
| 86de1f9 | lazy handler-limit + stack overflow паритет |
| 4b6d6af | P16.10a final (1.84x) |
| 3d4cbde | native-mem lane'ы (load/dump) |
| 5e23caf | DumpOptions.strip; cloneStrippedProto удалён |
| c455b9c | smoke 65 + c_api 18_dump |
| b946c7b | proto-inventory.json |
| 94bf0a2 | ProtoTreeOwner (refcounted tree) |
| 3b524f4 | source backing на дереве; load BOUNDED |
| 591f120 | adoption на границах + первый varargs-фикс |
| e33daf6 | третий varargs-слайс (gcPropagateOne) |
| 29ae846 | STATUS: root-cause запись + репро |
| 8937c9b | GC forward-barriers + gray-lifecycle + noyield + weak-key |
| f2dc7d1 | P16.10b final: полный гейт, 1.79x |

---

## Методологические заметки

- **Матрица vs standalone**: несколько багов воспроизводились ТОЛЬКО внутри
  матричного процесса (иерархия fork/env/timing). Рецепт: точная эмуляция
  инвокации → gdb-обёртка в матричном контексте → coredumpctl + addr2line.
- **Кумулятивные комбо-тесты**: поэлементная сборка блоков сьюта (t*/s*/pfx*)
  быстро локализует состояние-зависимые крэши, недетектируемые блоками
  по-отдельности.
- **OOM-обрывы** (3 шт.): дважды работа восстановлена из коммитов + dirty
  tree; один раз агент оставил бинарный мусор в vm.zig — восстановление
  git checkout; вывод: коммитить малыми шагами, эксперименты только в /tmp.
- **Perf-дисциплина**: все изолированные A/B — interleaved perf stat
  instr/cycles (stash-dance); «стало медленнее» без инстр-countа — не
  принимается (layout-лотерея отделялась от реальной регрессии).

## Открытые пункты (на следующую фазу)

1. traverseupvalue cell-arm (TODO в gcPropagateOne) — предсуществующий бф.
2. Frame-push field-classification готова (44 операции) — следующий
   perf-этап после свежего профиля: один общий инициализатор + cold-outlined
   подготовка, CallFrame ≤104.
3. Проверка: рамка fresh-профиля P16.10b (geomean 1.79x) — metamethod_add
   2.69x / noalloc 2.65x / lua_calls 2.15x — выбор следующего таргета
   строго по новым данным.
