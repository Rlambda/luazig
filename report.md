# Отчёт: P16.4g (correctness closure) + P16.2d (frame path) + инфраструктура LLM-прокси

Период: 28 августа 2026. 9 коммитов в luazig (`a3eb382..d966b48`), 3 коммита
в новом репозитории `llm-guard-proxy`. Входное состояние: `020fd02` (P16.4f),
matrix zig_fail=1 (nextvar.lua — блокер корректности), geomean 2.39x.
Выходное состояние: `d966b48`, полный гейт зелёный, geomean **2.33x**
(лучший прогон 2.29x), lua_calls суммарно ≈ −26% за период.

Задание поступило от верификатора («P16.4g correctness closure before
further performance work»): 7 задач — от репродукции nextvar до аудита
catch{}, с жёстким запретом перф-работы до зелёного гейта.

---

## Часть 1. P16.4g — закрытие корректности генерационного GC

### Task 1 — nextvar.lua: репродукция и root cause

**Симптом**: `nextvar.lua --testc` — «invalid key to 'next'» (nextvar.lua:30,
countentries), детерминированно 3/3–5/5.

**Расследование** (сабагент, изоляция усечением файла до <20 строк):
контрольный ключ-строка **жив** (не собрана GC), её узел **присутствует** в
таблице — но `nodeLookup` не находит узел: цепочка коллизий от main-position
оборвана. 23 354 зафиксированных случая порчи цепочек за прогон.

**Root cause** — `nodeInsert` (src/lua/ltable.zig), две ошибки против PUC
`insertkey` (ltable.c:863):
1. Доступность main-position проверялась по тегу ключа (`isEmpty()`), а не по
   значению (PUC: `isempty(gval(mp))`). Удалённый узел (ключ жив, value=Nil)
   ошибочно уходил в Brent-эвикцию.
2. При перезаписи затирался `next_offset` (PUC никогда не трогает `gnext`) —
   все узлы цепочки после перезаписанного сиротели.
3. Бонус: у `.dead`-узлов `rawHash` = 0 → Brent ходил по чужой цепочке.

Не виноваты: GC-освобождение ключа, TFOR-liveness, корутины, deadkey-логика.

### Task 2 — PUC-faithful DEADKEY

Реализована архитектура PUC `setdeadkey`/`equalkey(deadok)`:
- `NodeKeyPayload.gc_ptr` — все collectable-варианты алиасят один указатель;
  `markDeadKey` сохраняет сырой указатель (раньше затирался нулём).
- `keyMatchesDeadok`/`nodeLookupDeadok` — deadok-поиск по указателю, доступен
  ТОЛЬКО из `rawNext` (обычные lookup'и `.dead => false` на первом месте —
  горячий путь не утяжелён).
- `clearKey` (был string-only `deadenStringKey`) + `gcClearDeadKeys` — деден
  ЛЮБОГО collectable-ключа с Nil-значением; weak-key-таблицы сохранены.
- Аудит 15 путей чтения `key_val` (rehash/nextLiveIndex/GC-traversal/ephemerons/
  weak-prune/resize) — ни один не разыменовывает мёртвый указатель; 8 unit-тестов.

### Task 3 — корутин-liveness

Инструментально подтверждено отсутствие бага (ключ жив и маркирован).
Постоянные дифференциальные тесты (оба рантайма):
`tests/smoke/55_table_chain_integrity.lua` (churn 2^11 ключей + pairs-подсчёт +
саспенсion итератора + delete-key-during-iteration + GC + resume) и
`tests/smoke/56_deadkey_semantics.lua` (next() с удалёнными ключами классов
short/long string, table, closure).

### Task 4 — восстановление grayagain-drain в минорах

Disabled-PUC-блок («causes use-after-free») убран: drain работает во ВСЕХ
режимах. Две реальные причины исторического UAF:
1. **genlink**: TOUCHED1→TOUCHED2→OLD за один цикл вместо двух (PUC lgc.c:470
   держит TOUCHED1 в grayagain два цикла) → молодые дети не перемечались на
   втором цикле → преждевременный сбор → SIGSEGV в files.lua:757.
2. **Отсутствие remarkupvals**: значения открытых upvalue меняются после
   propagate (возобновление корутины) → добавлен `gcRemarkUpvals` (lgc.c:406):
   перемечание значений открытых Cells поверх gc_objects (Cells переживают
   фриз замыканий — обходит UAF через frameUpvalues).

### Task 5 — per-VM энтропийный hash seed

`Vm.init` → делегирует в `initWithSeed(alloc, noenv, seed)`; прод-путь берёт
`makeRandomSeed()` (PUC luai_makeseed: время+адрес), `lua_newstate` передаёт
C-API seed (lstate.c:354), тесты инъектируют фиксированный. Seed не мутирует,
от rng_state (math.random) не зависит. Coherence-тест intern↔table-key.

### Task 6 — честность документации + бисект

`git bisect 1bc3875..020fd02`: **first-bad = `0d53f55` (P16.4d)** — не P16.4a,
как предполагалось. История: баг `nodeInsert` старый, но ген-GC-режим
(P16.4d: sweepgen-цвета, gcMakeAllOld→BLACK) сделал деден/удаление ключей
настолько частым, что порча цепочек стала воспроизводимой. STATUS.md:
аппенд «P16.4g — correctness closure» с бисект-фактом, свежими числами и
списком оставшихся приближений (FINALIZEDBIT-очистка O(n) как транзит,
defensive stale-entry скипы); «Last updated» синхронизирован. Претензии
«pre-existing» заменены доказанным бисектом.

### Task 7 — аудит catch{} в GC-контроле

8 сайтов классифицированы с цитатами PUC: StringTable insert/shrink —
легитимная OOM-толерантность (luaS_resize/checkSizes); gcControl catch —
C-ABI граница (PUC бросает luaD_throw, мы возвращаем i32); барьеры —
архитектурная разница (PUC intrusive gclist инфаллибелен). Наблюдаемых
PUC-расхождений возвращаемых значений нет; STEP-гранулярность задокументирована.

### Верификация P16.4g (полный гейт, проверен лично)

Debug+RF builds/tests 0; c_api 18/18 + DIFF PASS; matrix **zig_fail=0**
(big.lua both_fail — предсуществующий, честно); **nextvar 10/10**; smoke
56/56; leak_bench PASS; 15_stress_leak 0/0; gc/gengc/closure/coroutine/
events/errors/files --testc — все 0. Perf-baseline обновлён (`c8fee6c`,
geomean 2.42x; comparisons/field_access изолированно чисты — лотерея полного
прогона на горячей машине, задокументировано).

---

## Часть 2. P16.2d — frame path (после зелёного гейта, по профилю)

Профиль lua_calls (perf annotate): dispatch 65%, **push 14.3% + complete
12.4% = 26.7%** — выше порога 20–25%, транша одобрена верификатором.
Агент-аналитик классифицировал каждое поле кадра (hot/warm/cold/dead) и
выдал ранжированный план с annotate-доказательствами.

### `8134f90` — frame-init slimming (lua_calls −7.4%)

- Удалены доказанно мёртвые записи: 4×callstatus-очистки бит (после
  encodeNresults с маской 0xff все флаговые биты уже нулевые) и мёртвый
  isDebugHook-блок; запись `proto` в syncFrame (ctx.cur_proto загружается ИЗ
  кадра и пишется в кадр только в push/opTailcall — доказано полным grep).
- `ensureBcStackCap` → inline (быстрая ветка = одно сравнение; рост вынесен в
  cold `growBcStackCapSlow`).
- Активация union `undefined` вместо `.{}` (−56B memset) с аудитом всех 12
  полей LuaFrameState: каждое пишется явно; Debug 0xaa-филл ловит пропуски.
- comptime-ассерт `@sizeOf(CallFrame) <= 104`.

### `9f30da3` — guard bcGrowFrame на возврате

`applyBytecodeResultsDirect` вызывает bcGrowFrame даже когда роста нет —
только чтобы пересчитать слайсы. Guard `dst + nstore > frame_cap` (семантически
идентичен внутренней проверке). Нейтрален на single-value микро, корректен по
построению.

### `a6a5d9f` — inline return hot path (lua_calls −18.8%)

Быстрые ветки в opReturn1/opReturn0, минующие completeBytecodeExecFrame +
applyBytecodeResultsDirect. Guard-условия (все обязательны, иначе fallback):
нет открытых upvalue; нет TBC-регистров; родитель Lua и в границах; не внешняя
граница; нет pending-call; хуки не активны; nresults ∈ {1, 0, <0×1значение}.
Pop-последовательность зеркалит popBytecodeExecFrame построчно. Главная
экономия: **одинарная копия результата** вместо двойной (устранён
bc_return_scratch) — доказательство безопасности для одного значения
(RHS читается до записи; мультизначный форвард-копи мог затирать источник,
потому multret-ветка ограничена ровно одним значением).

Изолированный A/B: инструкции −11.8%, циклы −10.9%. multret-ворклоуд
неизменен (ожидаемо).

### Числа транша

| Коммит | lua_calls | geomean |
|---|---|---|
| вход (020fd02) | — | 2.39x (после P16.4f; вход транша P16.4 — 2.53x) |
| `c8fee6c` baseline | — | 2.42x |
| `8134f90` | −7.4% | 2.36x |
| `a6a5d9f` | −18.8% | **2.33x** (лучший прогон 2.29x) |

Гейт после каждого шага + финально: полный набор зелёный (matrix zig_fail=0,
smoke 56/56, c_api+DIFF, nextvar 10x+5x+3x, 8 сьютов --testc, leak_bench,
stress-пара, perf_compare без >5% регрессий). Итерационное требование закрыто:
чекбокс P15.34 (специализированные integer/interned-string lookup пути —
выполнены ещё P16.1b, закрыт задним числом с верификацией анализом).

---

## Часть 3. Инфраструктура: llm-guard-proxy (диагностическая сага)

### Эпизод 1 — «упало по OOM»

Во время P16.4f systemd-oomd убивал пользовательские сессии (4 убийства за
день). Изначально отвергнуто (dmesg чист — а зря: systemd-oomd пишет в
system journal, а не в kernel log). Итог двух пересмотров: ООМ-убийства были
реальными и вызванными рабочими прогонами luazig с утечкой (найденной и
исправленной в P16.4f), но к падениям САБАГЕНТОВ отношения не имели.

### Эпизод 2 — пустые результаты сабагентов

Два агента подряд (Change 6) вернули пустые результаты. Диагностика по
opencode.log + БД (таблица part):
- **429-ретраи работали всегда**: лог показывает циклы
  «429 → ожидание Retry-After (42s/7s/8s) → повтор → успех».
- Убийца: последняя часть умерших сессий — тип **`reasoning` без `text`**.
  glm-5.2 (mws, output limit 10k) на длинных промптах выжигает бюджет вывода
  на reasoning → сообщение без content и без tool_call → opencode завершает
  loop → «результат» пуст.
- Guard-прокси это пропускал: `event_is_meaningful`/`json_response_is_empty`
  считали `reasoning_content` «meaningful».

### Фиксы (репозиторий `~/codes/llm-guard-proxy`)

Каталог переименован из `mws-llm-guard-proxy`, git init, юнит обновлён:

- `dd9c2c6`: reasoning больше не meaningful (обе проверки).
- `e5f22db` (починка регрессии от dd9c2c6): немедленный форвард SSE вместо
  буферизации до первого content — буферизация задерживала первый байт на
  всю фазу reasoning; плюс подняты ZAI-таймауты (60→300s chunk, 300→1800s
  request) — 4×504 «MWS upstream timed out» на /v4 возникли из-за легитимных
  минутных пауз reasoning-модели между чанками. Финальная архитектура:
  форвардить всё сразу; если стрим кончился без content/tool_call —
  force_close (клиент видит ретраебельный обрыв) или 502, если ничего не
  отправлено.

Проверка делом: сабагент Change 6, дважды умиравший, после фикса отработал
полностью (−18.8% lua_calls).

---

## Методологические заметки

- **Бисект вместо «pre-existing»**: любой вывод о происхождении фейла
  доказывается чистыми сборками, иначе не заявляется.
- **Recipe инструкции-vs-циклы** дважды отделил реальную регрессию от
  layout-лотереи на горячей машине (comparisons/field_access/global_arith
  флапают ±7–12% при УЛУЧШАЮЩЕМСЯ geomean — противоречие исключает
  реальную деградацию; изолированные замеры инструкций стабильны).
- **Debug 0xaa-филл** как бесплатный аудит «undefined-активации»: пропущенная
  инициализация поля ловится мгновенно.
- **Дифференциальные smoke-тесты** как постоянные регрессионники: каждый
  корневой баг получает минимальный тест, проходящий на обоих рантаймах.
- **Дихотомия OOM**: kernel OOM-killer (dmesg) ≠ systemd-oomd (system journal)
  — проверять оба журнала.

## Открытые пункты (следующие итерации)

1. FINALIZEDBIT-очистка — переходная O(n)-мера, заменить targeted clear-list.
2. Defensive stale-entry скипы в grayagain-путях — убрать после стабилизации.
3. Активная ссылка треда в grayagain (PUC linkgclist(&L->gclist,...)) —
   покрыто gcMarkMutableRoots, честно задокументировано как приближение.
4. big.lua both_fail — предсуществующий, вне транша.
5. Свежий профиль после P16.2d: push+complete могли перестать быть доминантой
   lua_calls — следующий перф-этап выбирать по новому профилю.
