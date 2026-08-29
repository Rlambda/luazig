# Отчёт о работе с 1bc3875 по 020fd02 (фаза P16.4: генерационный GC)

Период: 26–27 августа 2026. 10 коммитов, все на ветке master.
Начальное состояние: geomean 2.53x, CLI стартует в инкрементальном GC,
генерационный режим частичен и крашится. Цель фазы: довести ген-GC до
паритета с PUC Lua 5.5 и закрыть дифференциальный тест `17_gccontrol`.

---

## Хронология коммитов

| Коммит | Дата | Суть |
|---|---|---|
| `c008a73` | 26.08 16:07 | docs: записи P16.0a/d, P16.1, P16.2a-c, P16.3 в STATUS.md (закрытиеobservability-TODO) |
| `2d3a54a` | 26.08 19:23 | P16.4a: единый PUC-faithful gcControl + вариадический lua_gc shim + кодированные GC-параметры |
| `1c2f493` | 26.08 19:42 | P16.4a: CLI GCRESTART+GCGEN стартап (пока выключен, ждёт P16.4b) |
| `d742b39` | 26.08 19:46 | STATUS: запись P16.4a |
| `afebb1c` | 26.08 21:32 | P16.4b: фикс краша full-collection в ген-режиме — завершать pending-цикл до gcMakeAllWhite |
| `14e7620` | 27.08 06:38 | P16.4c: grayagain-drain для полных циклов + барьеры метатаблиц |
| `f0b7066` | 27.08 06:39 | STATUS: запись P16.4c |
| `0d53f55` | 27.08 08:37 | P16.4d: цвета sweepgen, checkmajorminor, gcMakeAllOld → BLACK |
| `84559f7` | 27.08 09:47 | P16.4e: закрытие открытых upvalue при сборке треда (luaE_freethread/luaF_closeupval) |
| `020fd02` | 27.08 19:04 | P16.4f: PUC-faithful учёт байтов, цепной stringtable, фиксы утечек буферов — 17_gccontrol green, 2.53x→2.39x |

---

## P16.4a — единый gcControl и кодированные параметры (`2d3a54a`, `1c2f493`)

Перенос API управления GC на модель PUC 5.5:

- **`gcparams: [6]u8`** — кодированные GC-параметры (порты
  `luaO_codeparam`/`applyparam`): minormul, majorminor, minormajor,
  pause, stepmul, stepsize. Параметры квантуются как в PUC.
- **Единый `gcControl(what, param, value)`** — все операции
  LUA_GCSTOP/RESTART/COLLECT/COUNT/STEP/ISRUNNING/GCGEN/GCINC/CPARAM
  в одной точке; `builtinCollectgarbage` делегирует ему.
- **Вариадический `lua_gc`** — C-shim (`lua_gc_shim.c`) поверх
  `luazigGcFixed`/`luazigGcParam` для точной PUC-сигнатуры.
- **Дифференциальный suite `tests/c_api/17_gccontrol.c`** — попарный
  запуск zig/PUC со строгим сравнением вывода (test-diff, без `|| true`).
- CLI-стартап PUC pmain: GCRESTART + GCGEN (включён после P16.4b/e).

Результат: каркас готов; 17_gccontrol выявил дифференциал `reached_1`
(STEP не завершает цикл) — цель последующих шагов.

## P16.4b — краш full-collection в ген-режиме (`afebb1c`)

`collectgarbage()` в ген-режиме крашился: gcMakeAllWhite выполнялся при
незавершённом инкрементальном цикле. Фикс: `gcFullCollectionForUser`
завершает pending-цикл ДО перекраски (зеркало PUC fullgen). Снимок
`snapshot`-механики циклов сохранён консистентным.

## P16.4c — grayagain-drain и барьеры метатаблиц (`14e7620`)

- Drain серого списка grayagain для полных циклов (объекты,
  пере-помеченные барьерами, обязаны быть обойдены повторно).
- `gcStoreMetatable` — чёрный/белый барьер при записи метатаблицы.
- `gcPromoteYoungObject` OLD0-фикс (возрастная модель PUC nextage).
- `gcCorrectGrayAlive` — корректный повторный обход выживших.

Результат: gc.lua, api.lua зелёные; добален smoke
`43_generational_minor.lua` (итого 55 файлов в каталоге, 54 .lua).

## P16.4d — цвета sweepgen и checkmajorminor (`0d53f55`)

- `sweepgen`-цвета: не-NEW выжившие остаются BLACK (PUC sweepgen).
- `gcMakeAllOld` ставит BLACK (паритет sweep2old).
- OLD1→OLD в начале следующего цикла; checkminormajor ПОСЛЕ sweep;
  реализован **checkmajorminor** (возврат major→minor по собранным
  байтам, atomic2gen-путь со sweep-all-to-OLD+BLACK).
- `gcMarkMutableRoots`: фикс pc_live/reg_top.

## P16.4e — открытые upvalue при смерти корутины (`84559f7`)

PUC `luaE_freethread` → `luaF_closeupval`-паритет: перед освобождением
стека мёртвого треда его открытые upvalue-ячейки закрываются
(значение копируется в ячейку, ссылка на стек обнуляется) — иначе
живые замыкания держали висячие указатели. Плюс `gcQueueScanCell`
маркирует открытые ячейки (PUC reallymarkobject LUA_VUPVAL).

Результат: **gengc.lua FULL PASS**, matrix 31/32 zig_fail=0 под
генерационным стартапом CLI.

## P16.4f — учёт байтов, stringtable, утечки (`020fd02`)

Закрытие последнего блокера: `17_gccontrol` STEP-дифференциал
(`reached_1`: PUC=yes, zig=no). Цепочка корней (каждый подтверждён
инструментальными трассами против vendor-PUC):

1. **STEP debt-семантика** (PUC lapi.c:1200+): `n<=0 → debt:=0`,
   `n>0 → debt-=n`; после ручного минора — setminordebt-эквивалент;
   после полных/инкрементальных шагов — setpause/setdebt(stepsize)
   (lgc.c:1724).
2. **GCGEN/GCINC** возвращают предыдущий режим с учётом GENMAJOR.
3. **setminordebt-pacing**: порог = count + base×MINORMUL%
   (было count×1.2 c полом в +64KB, откладывавшим миноры на целые
   ворклоуды).
4. **Учёт частей таблиц**: tableResize заряжает новые array/hash и
   кредитует освобождаемые; иначе счётчик схлопывался в 0.
5. **Заряд Cell на горячем пути OP_CLOSURE** — без него каждый фриз
   ячейки пере-кредитовал счётчик → AutoCycleDue навечно true →
   GC-лайвлок (cstack-таймаут).
6. **Цепной interned-stringtable** (PUC stringtable, lstring.c):
   `StringTable` с бакет-цепочками через новое поле
   `LuaString.next`, O(1) removeString, рост ×2 при заполнении,
   сжатие при nuse<size/4 в atomic (checkSizes), старт 128.
   Причина замены: tombstone-деградация Zig HashMap до O(N) проб
   под строкенным churn ген-GC.
7. **Фиксированный string-hash seed** (`hash_seed`, аналог
   неизменяемого PUC g->seed) вместо живого `rng_state[0]^rng_state[2]`,
   который мутирует math.random — латентный баг канонизации.
8. **Resurrect** мёртвых-несобранных строк при intern-хите
   (internshrstr lstring.c:223).
9. **Утечки временных буферов**: `result` в concatValuesDirect,
   `buf` в string.rep, два `tb_result` в error-форматировании —
   никогда не освобождались после интерна. На аккумуляторных
   `s = s .. x` циклах это квадратичный взрыв памяти.

### Расследование OOM (побочная линия)

systemd-oomd убивал сессии (4 убийства за 27.08) — сначала выглядело как
«падают сабагенты». Реальная цепочка: (а) предсуществующая утечка
временных буферов конката + (б) тестовые файлы /tmp/sl*.lua оказались
накопительным `s = s .. tostring(i)` (200K итераций → десятки GB).
Инструмент: TrackingAllocator с картой «указатель → callsite» выдал
гистограммы утечек по сайтам; финальный дифференциал по размерам
показал растущие буферы с содержимым «123456789101112…». После фиксов
30K/200K ворклоуды проходят под 2–3GB ulimit, длины совпадают с PUC
(138894 / 1088895).

### Побочный фикс теста

`smoke/34_gc_stop_and_step.lua`: нагрузка 100→300 таблиц — порог
minor→major относителен к footprint (minormajor% от базы), структуры
Zig крупнее C-структур PUC, 100 таблиц сидели на границе (63% против
порога ~67% у zig, 72% у PUC). Семантика неизменна, файл проходит в
обоих рантаймах.

### Верификация P16.4f

- 17_gccontrol test-diff: **PASS** (reached_1=yes в обоих; sp3-репро
  завершает на итерации 69 против PUC 0 — тест проверяет только факт
  завершения через major-цикл)
- c_api 17/17 + DIFF PASS; smoke 54/54; gengc FULL; coroutine.lua
  --testc 0; zig build test 0; leak_bench PASS
- matrix --testc: zig_fail=1 — **nextvar.lua падает 5/5 и на чистом
  HEAD 84559f7** («invalid key to 'next'»): предсуществующий баг
  ген-GC (подозрение на сканирование стека в минорах), НЕ регрессия
  шага; зафиксирован в STATUS.md как открытый пункт
- Perf: geomean **2.53x→2.39x**; string_concat −25.3%, string_loop
  −34.4%, temp_table_alloc −29.5%. field_access/global_arith
  флапнули в полных прогонах, но изолированный instructions-vs-cycles
  A/B (200M итераций): инструкции идентичны (89.8G), циклы лучше
  (21.5–23.2G против HEAD 23.5–23.7G) — шум нагруженной машины.
  Baseline обновлён на прогон 2.39x, README перегенерирован.

---

## Методологические заметки

- **Дифференциальный подход**: vendor-PUC как оракул; при сомнениях —
  временная инструментация lgc.c/lapi.c (обязательно откатываемая,
  liblua.a пересобирается).
- **Recipe инструкции-vs-циклы** для перф-аномалий: изолированный A/B
  с perf stat отличает реальную регрессию (растут инструкции) от
  layout/шума (инструкции равны, циклы гуляют).
- **Утечки памяти**: TrackingAllocator + карта живых аллокаций по
  return-address + гистограммы по сайтам и длинам; чтение содержимого
  утёкших буферов на выходе даёт семантическую подсказку.
- **Гигиена тестов**: стресс-файлы в /tmp были перезаписаны чужим
  скриптом и месяц водили расследование в сторону — проверяй содержимое
  репро-файлов перед выводами; ulimit -v на всех прогонах сalloc-тяжёлыми
  путями обязателен (иначе systemd-oomd убивает сессию целиком).

## Открытые пункты (на следующий шаг)

1. **nextvar.lua** «invalid key to 'next'» — падает и на HEAD; копать
   сканирование стека/регистров в ген-минорах (живая строка-ключ
   собирается, узел таблицы остаётся с висячим указателем).
2. global_arith — следить против нового baseline (2.39x); при повторном
   появлении >10% в полных прогонах — изолировать по recipe.
3. Оставшиеся идеи P16.2d (frame-init slimming) — после re-profil­ing
   lua_calls против нового baseline.
