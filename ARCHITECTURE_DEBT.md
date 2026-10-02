# Архитектурный радар

Этот файл сохраняет долгоживущие архитектурные расхождения с
PUC Lua между фазами. Это не finding-ledger: severity, судьбу,
acceptance и open-count задаёт `STATUS.md`. Запись из радара не
удаляется без основания: после research она помечается
`подтверждено`, `отклонено`, `разбито` или `закрыто` со ссылкой
на `STATUS.md`, commit или decisive evidence.

Последняя сверка: review research `89f92bb`; решение владельца —
объединить persistent finalizers и intrusive `allgc` в один milestone.

## Утверждённый GC roadmap

1. **Stale-slot safety — закрыто A1.1 (`ac3e2b7`), сверено review
   `9b1bad7`.** Wholesale marking по `Thread.stack[0..top)` заменило
   precise `live_reg_top`; stale-`gc_index` skip удалён. A1.1s1 C10
   poison/unmap oracle проверяет ordinary→emergency переход. Старый
   открытый Safety-пункт `STATUS.md` закрыт по этому evidence.
2. **Единый intrusive GC lifetime/finalizer owner — утверждённый следующий
   архитектурный milestone.** Persistent-finalizer gap подтверждён
   differential-эвиденцией (research A1.next). Корень: `gc_to_finalize`
   не персистентен (`gcResetCycleState` чистит на старте цикла) +
   ре-сепарация white-only/age-filtered + abort списка на не-RuntimeError.
   Подтверждённые расхождения (PUC 5.5 oracle + ltests vs luazig, Debug+RF):
   rescue-after-emergency теряет `__gc` (table/userdata; сильнейшая форма —
   real ulimit на stock-бинарях, без адаптера); GCSTOP-окно теряет pending;
   OOM в теле `__gc` обрывает остаток списка (PUC: warn+continue); обрыв +
   retry даёт двойной `__gc`; gen minor-цикл теряет leftover pending.
   Контроли без rescue/ordinary — байт-идентичное согласие (разрыв изолирован
   в carry-over). Reviewer подтвердил дополнительный order-gap: PUC
   упорядочивает внутри партии по регистрации `__gc`, luazig — по созданию.
   Решение владельца: НЕ вводить dense FIFO как промежуточную production-модель.
   Целевой PUC-подобный owner — эксклюзивные intrusive `allgc` → `finobj` →
   персистентный `tobefnz` → `allgc`; registration и separation сохраняют
   PUC-порядок без fallible append. `gc_objects`/`gc_index` не остаются вторым
   lifetime authority; secondary dense-списки допустимы только как lossless
   accelerators с доказанной синхронизацией. `RootScope` и unified
   `Thread.stack/top` уже выполненные prerequisites. Перед implementation
   нужен bounded research всех constructor/rollback, sweep cursor,
   incremental/generational age и shutdown переходов; stage не закрывается
   одним исправлением finalizer-очереди. Research выполнен (A1.next-2,
   4 параллельных исследования): кандидат layout — extern
   `GcHeader{next,marked,age,tag}` 16B (поле пяти типов + прямой префикс
   LuaString 48B с hash u64→u32; оценка api580 368→384 <400);
   порядок `__gc` — PUC REVERSE-registration (finobj-LIFO), не FIFO;
   финализаторы переносятся за sweep (PUC-фаза) — заодно закрывает
   finalizable-внутри-__gc corruption BLOCKER; инвентарь 30+ структур
   классифицирован (intrusive/accelerator/delete); 11 конструктор-семейств
   уже в reserve→alloc→init→commit форме (intrusive link = commit-сайт);
   migration = 4 атомарных cut'а без публичного dense-FIFO промежутка
   (подробности — report.md A1.next-2). Открытый Parity-пункт в `STATUS.md`;
   полный finalizer research-handoff — report.md фазы A1.next research.
   Reviewer correction к layout: предложенный строковый префикс
   `next,hash,srkind,marked,age,tag` НЕ байт-совместим с GcHeader —
   `marked/age/tag` надо разместить по тем же смещениям, например
   `next@0,marked@8,age@9,tag@10,srkind@11,hash@12`; это условие
   implementation, не доказанный в research размер. Кроме того, все
   бывшие full-scan `gc_objects` должны охватывать эксклюзивные списки
   `allgc/finobj/tobefnz`, а `long_literals` сейчас отдельно владеет
   GC-строками и не может остаться вторым lifetime owner. Отдельный
   Safety-BLOCKER потери callee при emergency локализован в atomic
   Step 15 nil-fill живого operand-слота; он не предпосылка миграции
   (открытый пункт `STATUS.md`).

   ВЫПОЛНЕН (4 cut'а: c1febb8 layout+shadow; e3d98d8 chain=authority;
   19faf56 finobj/tobefnz+post-sweep callfin; 4ca07d2 удаление временного
   слоя и мёртвых полей): все расхождения закрыты canonical differential
   (tests/c_api/27_finalizer_owners — побайтово оба режима; мутации
   l1/l2/l3 RED); вторых lifetime-authority нет; long_literals включены в
   цепочку; applyLoadEnv-гипотеза опровергнута decisive-экспериментом.
   Perf A/B (9b1bad7↔4ca07d2, cpu_core/instructions): table-alloc −2.9%,
   string −1.8%, GC-core без finalizers −19.6%, 10%-finalizable −14.1%;
   finalizer-saturated форма +75.5% при остающемся 24%-преимуществе vs
   PUC (3.28B vs 4.33B insn) — цена принятия PUC-семантики
   (markbeingfnz pending-графа каждый цикл + post-sweep callfin);
   speed-preservation gate не действовал.

## TBC, calls и protected boundaries

1. **F1: yieldable `finishpcallk` recovery — подтверждено,
   REDESIGN constraint.** Recovery-close должен допустить yield и после
   resume продолжить recovery/continuation. Открытый HIGH-пункт
   в `STATUS.md`.
   RESEARCH UPDATE (pkres, 2026-10-01, к `60a9ee9`): PUC объединяет
   publication/recovery-close/window-survival в CIST_YPCALL-кадре и
   `finishpcallk`; F1, F9b, N, GY, P и DGC наблюдаемо расходятся.
   Вариант A и пять cuts из `/tmp/opencode/pkres_report.md` §5-6 пока
   НЕ утверждены: bytecode-fast-path `pcall` не создаёт C-кадр, а
   `closeTbcRegion` при yield требует `clsret_frame` (текущий F1-site
   передаёт null). Кроме того, N-acceptance зависит от сохранения
   prefix/window, поставленного в исходном плане лишь четвёртым cut.
   Следующий шаг — bounded verification общего frame/continuation owner,
   GC-root/window контракта и самостоятельно зелёного порядка cuts.
   Thread-global replay field не вводить без отдельного обоснования.
   VERIFICATION UPDATE (pkres-v, 2026-10-01, к `917339a`, product не
   менялся): verification выполнена — карта owners для обоих lane,
   сравнение Д1 (PUC-подобный YPCALL-кадр и для bytecode lane) vs Д2
   (типизированный recovery-контракт с lane-specific frame-backed
   носителями, без второго mutable authority/replay-field;
   CLSRET-yield/re-entry через S4-proven machinery, zero hot-path
   cost) в `/tmp/opencode/pkresv_report.md` §4; рекомендация — Д2,
   финальный выбор за owner. F1-семейство = 3 product-сайта +
   OOM-arm (finishBytecodeProtectedFailure + builtinPcall +
   builtinXpcall; E4-дифференциал). Consumer-less precover-сайтов
   четыре (4-й — direct-resume unroll 29398). Cut-порядок переработан
   (pkresv §6): N+window объединены, каждый cut независимо зелёный.
   IMPLEMENTED, ACCEPTED after correction (milestone Д1, owner-решение;
   cuts `27624b0` W+N, `996d2ec`
   F1+route, `9274967` GY+P+delete): pcall/xpcall/lua_pcallk/generic
   builtins — один C/YPCALL recovery owner; bytecode fast path
   (BytecodeProtectedCall-семейство, −1052 строки) удалён полностью
   (rg-proof 0 ссылок); yy по предикату `k != NULL && yieldable(L)`
   при входе (E1 остаётся conventional); level-based precover region
   (GY); OOM в k через kind-bit RECST=4 (P); persisted window end на
   C-кадре (W/DGC). Второго mutable owner нет; Thread-global replay
   field не вводился. Предположение о k-ordering опровергнуто ревью:
   разница порядка строк — буферизация C `printf` относительно Lua `print`
   (со `stdbuf -o0` финальный Debug/RF и PUC совпадают). Остаётся
   where-attribution текст-класс (F4n17/F8n18, backlog). Perf trade-off
   раскрыт: pcall_ok ускорился на 16%, xpcall_yield замедлился на
   14–16%; скорость не gate. Отчёты:
   /tmp/opencode/{prw1,prf1,prfin}_report.md. Ревью обнаружило
   внесённую Д1 регрессию: `builtinPcall` восстанавливает внешний errfunc
   при `error.Yield`, пока вложенный YPCALL-кадр ещё жив; PUC и baseline
   внешний `xpcall` handler при последующей ошибке не вызывают. Также
   обязательные канонические C API/smoke differential-тесты milestone
   не добавлены. Correction `4d468e0` исправила errfunc-lifetime,
   добавила suite 37 и smoke 91; nested-репродюсер и основные C API
   формы независимо совпали с PUC. Correction `e6b58d9` устранила
   нормализацию хронологии `k` в suite 37: статически линкованный
   Debug/ReleaseFast differential независимо совпал с PUC, а gate
   чувствителен к перестановке continuation. **Д1 принят после
   correction.** testC `edge_a4` классифицирован как валидный,
   pre-existing Safety-BLOCKER (`f74a1ea`); он остаётся отдельным
   открытым пунктом `STATUS.md`, а не регрессией Д1.
   REVIEW UPDATE (2026-10-01): Д2 — не существующий общий
   close-workhorse: `continueBytecodeClose` и `closeTbcRegion` имеют
   отдельные циклы/носители; новая bytecode recovery-phase потребует
   отдельного proof порядка C-chain, roots, cancel и re-entry. Заявленная
   «zero hot-path cost» пока структурная оценка, не измерение. Ревьювер
   рекомендует Д1 как один PUC-подобный YPCALL owner и удаление
   `BytecodeProtectedCall` fast path (perf trade-off измерить, но
   сохранение скорости не gate для архитектурного cut). Владелец
   **утвердил Д1** (2026-10-01): correctness-модель PUC приоритетнее
   отдельного shortcut; legacy bytecode protection удаляется целиком
   в этом milestone, а не остаётся альтернативным recovery-owner. Также
   `precover` вызывается в шести, а не четырёх местах
   (vm.zig:16375/16473/16562/29128/29349/29398); два дополнительных
   direct-resume сайта требуют focused reachability proof.
2. **Единое ordered TBC representation — подтверждённый архитектурный
   долг.** PUC имеет один `tbclist`; luazig делит obligations на
   `bytecode_tbc_regs` и `c_tbc_chain`. Decisive differential найден при
   review `12d69fb`: forced close формы `C1 mark → Lua <close> → C2 mark →
   yield` обязан дать `C2,Lua,C1`, но whole-`c_tbc_chain` drain дал
   `C2,C1,Lua`. Correction `9b1bad7` восстановила глобальный порядок
   через frame-ordered сегменты без расширения split model. Перед полной
   migration нужен inventory всех writers/readers и дизайн одного ordered
   owner для Lua/C/hook obligations. Валидный `edge_a4` (`f74a1ea`,
   `STATUS.md`) доказывает C-slot aliasing/crash на recovery; является ли
   он следствием split representation или отдельной publication/resume
   ошибки, должен установить следующий research, а не предполагать.
   RESEARCH UPDATE (tbcres, 2026-10-02, к `f74a1ea`): research выполнен
   — edge_a4 ≠ split representation. Три независимых корня (stale
   resume flag / slot identity через staging-копию / yy+error transport
   в testC-кадрах), ни один не требует миграции к единому owner для
   исправления; декомпозиция подтверждена /tmp-клоном (сброс флага:
   rc=0, сюиты IDENTICAL, production-расхождения не изменились).
   Обоснование варианта B (единый ordered owner) сужено до
   interleaving + level-семантики (suite 26 FC-10/11 стабильно
   IDENTICAL на split-модели) — owner-decision, не предпосылка
   edge_a4-fix. Ось slot identity (staging) выделена в отдельный
   milestone «staging identity» (C→Lua вызовы стейджат копию на
   th.top — регистры callee не алиасят слоты окна; pa_min-оракул в
   /tmp/opencode/tbcres/). Полный inventory writers/readers обеих
   структур — `/tmp/opencode/tbcres_report.md` §6.1.
3. **Цепочка C error boundaries — research candidate.** PUC `errorJmp` и
   `luaD_throwbaselevel` могут пройти мимо вложенных protected calls;
   luazig хранит один `c_error_jmp`. Известный риск —
   `lua_closethread(L, L)` внутри C/Lua `pcall` может попасть не на
   base boundary. Решающий C differential должен предшествовать
   дизайну.
   RESEARCH VERDICT (f1res, 2026-10-02, к `9b004d3`; отчёт
   /tmp/opencode/f1res_report.md, клон /tmp/opencode/f1res/clone):
   решающий прототип выполнен — typed main-destined transport
   (error-set kind `MainDestined`, один longjmp через ровно один
   C-кадр, все промежуточные Zig defer исполняются, owner err-state =
   main) даёт P1-P5b 12/12 IDENTICAL PUC D+RF и доминирует над
   owner-tagged longjmp (A) по всем осям. GO за владельцем; data flow +
   acceptance + cuts 1-4 в отчёте §4.2-4.3. Обязательный gate
   implementation-milestone: F-S4-3 (GC-arm frame/window restore, C7
   зелёный D+RF). Пункт STATUS F1-correction остаётся открытым до
   миграции.

F2 (`lua_settop`/`lua_closeslot` error transport) остаётся открытым bounded
parity-дефектом; F3 (forced-close region ownership) закрыт `9b1bad7`.

4. **t2 call-window top-publication — correction после review `fc42243`.**
   PUC-точная per-opcode публикация Thread.top перед MayGC (operand-end
   для OP_CALL/OP_TAILCALL/OP_CONCAT/OP_TFORCALL; frame-window для
   OP_CLOSURE/fixed-OP_SETLIST; opNewtable PUC-порядок) + класс 2
   (heap-ret RootScope-rooting в apply-путях). Canonical
   tests/stress/t2_gc_bound_publication.lua исправляет исходный t2.
   Однако `pushResolvedBytecodeClosure` публикует `windowTop` с
   `EXTRA_MARGIN`, а не точный PUC `ci->top`; weak-value differential
   показывает наблюдаемое удержание мёртвого объекта. Для класса 2
   RootScope реализован, но decisive emergency-root proof ещё нужен.
   Заявленный perf A/B сделан до финальной product-правки и не является
   измерением `fc42243`. Подробности и открытые пункты — `STATUS.md`.

## Embedding и stdlib ownership

1. **Полный `lua_Alloc` owner — confirmed design divergence, research
   before migration.** `lua_newstate(f, ud)` уже устанавливает
   `CAllocBridge` как `std.mem.Allocator` для post-init `vm.alloc` и
   emergency-GC retry; прежняя запись об отсутствии моста была устаревшей.
   Но `Vm` и ранний `Vm.initWithSeed` создаются через `c_allocator` до
   установки callback (PUC вызывает `f` уже для `global_State`), а
   `lua_setallocf` меняет только `c_alloc_fn`/`c_alloc_ud`: действующий
   bridge и `vm.alloc` остаются прежними. `lua_getallocf` после setter
   возвращает новый callback, хотя дальнейшие аллокации идут через
   прежний. `CAllocBridge.allocFn` передаёт `osize=0` при новом
   выделении, тогда как PUC `luaM_malloc_` передаёт type tag;
   `resize/remap` отклоняются, поэтому рост идёт через alloc+copy+free.
   Комментарии на этих sites также устарели. Нужен inventory
   allocator identity с bootstrap/teardown, live-block semantics setter,
   OOM/status и accounting до implementation; PUC маршрутизирует state
   allocations через текущий `lua_Alloc`.
2. **`string.gmatch` per-iterator state — подтверждено
   differential-эвиденцией.** `Vm.gmatch_state` — один mutable slot,
   iterator — общий `.Builtin`; PUC `lstrlib.c:gmatch` создаёт closure
   с отдельным `GMatchState` userdata и держит строки в upvalues.
   Два чередующихся iterator: PUC `a,1,b,2`, Zig `1,2,nil,nil`
   (`/tmp/reviewer_langfull2.lua`, `STATUS.md`). Нужен per-iterator
   owner/roots с проверкой nested use, coroutine yield и GC; не
   расширять VM-global replay slot.
3. **`package.searchers`/`require` owner — подтверждённый stdlib
   completeness gap.** PUC `loadlib.c:createsearcherstable` публикует
   изменяемую ordered таблицу searchers и `findloader` вызывает её
   текущее содержимое. Zig не создаёт поле `package.searchers`,
   `builtinRequire` жёстко выбирает preload/Lua/C пути. Custom searcher
   differential: PUC возвращает 73, Zig module-not-found
   (`/tmp/reviewer_langfull.lua`, `STATUS.md`); preload-control
   совпадает. Для миграции нужны единый owner loader chain, loader data,
   порядок сообщений, re-entry и GC-root lifetime.
4. **C API pseudo-index + registry/globals ownership — research подтверждён,
   PUC-подобное направление утверждено владельцем.** Cidx/cidx2/cidx3
   (`STATUS.md`, `/tmp/opencode/cidx{,2,3}_report.md`) доказали:
   `LUA_REGISTRYINDEX` и upvalue-индексы требуют общего typed resolver;
   PUC registry — writable `Value`-слот, который маркируется повторно в
   atomic; `registry[LUA_RIDX_GLOBALS]` — источник C API get/setglobal и
   `_ENV` новых chunks. Текущие `debug_registry: ?*Table` и
   `global_env: *Table` не выражают этот owner, а `-1001000` не совпадает
   с PUC 5.5 ABI. Рекомендация ревьювера: единая PUC-подобная миграция
   registry + globals до открытия C API write-доступа к RIDX[2], затем
   resolver/get-set/write классы. Implementation-задание — `prompt.md`:
   α+ε как одна owner-миграция до β→γ→δ. Исходный α→β→γ→δ→ε
   небезопасен как публикуемые зелёные cut'ы, поскольку γ делает
   split-owner наблюдаемым до ε.

## Не-parity архитектурный backlog

Эти пункты не являются correctness-расхождениями с PUC и не
обгоняют parity/safety work без решения владельца:

- streaming parser-to-bytecode вместо обязательного full AST;
- VM-local pools/pages и allocator architecture;
- уплотнение `Thread` header/parked state;
- оставшиеся dispatch/call-frame overhead и table insert specialization.
