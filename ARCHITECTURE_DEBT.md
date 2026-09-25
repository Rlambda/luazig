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
2. **Единое ordered TBC representation — подтверждённый архитектурный
   долг.** PUC имеет один `tbclist`; luazig делит obligations на
   `bytecode_tbc_regs` и `c_tbc_chain`. Decisive differential найден при
   review `12d69fb`: forced close формы `C1 mark → Lua <close> → C2 mark →
   yield` обязан дать `C2,Lua,C1`, но whole-`c_tbc_chain` drain дал
   `C2,C1,Lua`. Correction `9b1bad7` восстановила глобальный порядок
   через frame-ordered сегменты без расширения split model. Перед полной
   migration нужен inventory всех writers/readers и дизайн одного ordered
   owner для Lua/C/hook obligations.
3. **Цепочка C error boundaries — research candidate.** PUC `errorJmp` и
   `luaD_throwbaselevel` могут пройти мимо вложенных protected calls;
   luazig хранит один `c_error_jmp`. Известный риск —
   `lua_closethread(L, L)` внутри C/Lua `pcall` может попасть не на
   base boundary. Решающий C differential должен предшествовать
   дизайну.

F2 (`lua_settop`/`lua_closeslot` error transport) остаётся открытым bounded
parity-дефектом; F3 (forced-close region ownership) закрыт `9b1bad7`.

## Embedding и stdlib ownership

1. **Настоящий `lua_Alloc` bridge — confirmed design divergence, research
   before migration.** `lua_newstate`/`lua_setallocf` сохраняют callback и `ud`,
   но реальные `vm.alloc` allocations продолжают идти через
   `c_allocator`. PUC маршрутизирует все state allocations через текущий
   `lua_Alloc`. Нужен inventory allocator identity, live-block migration
   semantics `lua_setallocf`, OOM/status и accounting до implementation.
2. **`string.gmatch` per-iterator state — UNCONFIRMED M18.** Сейчас
   `Vm.gmatch_state` — один mutable slot на VM, тогда как PUC возвращает
   closure с независимым state. Decisive experiment: два чередующихся
   iterator, nested iterator и iterator across coroutine yield/GC. При
   подтверждении — per-closure/upvalue owner, не VM-global replay slot.

## Не-parity архитектурный backlog

Эти пункты не являются correctness-расхождениями с PUC и не
обгоняют parity/safety work без решения владельца:

- streaming parser-to-bytecode вместо обязательного full AST;
- VM-local pools/pages и allocator architecture;
- уплотнение `Thread` header/parked state;
- оставшиеся dispatch/call-frame overhead и table insert specialization.
