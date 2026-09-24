# Архитектурный радар

Этот файл сохраняет долгоживущие архитектурные расхождения с
PUC Lua между фазами. Это не finding-ledger: severity, судьбу,
acceptance и open-count задаёт `STATUS.md`. Запись из радара не
удаляется без основания: после research она помечается
`подтверждено`, `отклонено`, `разбито` или `закрыто` со ссылкой
на `STATUS.md`, commit или decisive evidence.

Последняя сверка: review research `091afe2`.

## Утверждённый GC roadmap

1. **Stale-slot safety — закрыто A1.1 (`ac3e2b7`), сверено review
   `9b1bad7`.** Wholesale marking по `Thread.stack[0..top)` заменило
   precise `live_reg_top`; stale-`gc_index` skip удалён. A1.1s1 C10
   poison/unmap oracle проверяет ordinary→emergency переход. Старый
   открытый Safety-пункт `STATUS.md` закрыт по этому evidence.
2. **Persistent finalizer ownership — подтверждено differential-эвиденцией
   (research A1.next), следующий GC milestone.** Корень: `gc_to_finalize`
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
   Целевой дизайн: эксклюзивный перенос `finalizables` → персистентная FIFO
   `gc_to_finalize` с reserve-before-commit и порядком регистрации; объект
   не может одновременно оставаться в обоих pending-источниках. Очередь —
   bounded intermediate; критерий удаления — intrusive finalizer link при
   миграции `allgc` (п.3). Открытый Parity-пункт в `STATUS.md`; полный
   research-handoff — report.md фазы A1.next research.
   Отдельный подтверждённый Safety-BLOCKER: emergency-путь теряет callee
   value при вычислении аргументов `pcall`; первая неверная запись пока
   не локализована (открытый пункт `STATUS.md`).
3. **Intrusive `allgc` lifetime authority — утверждённый end-state.**
   `gc_objects`/`gc_index` пока остаются dense lifetime registry. После
   persistent-finalizer milestone перейти к PUC-подобному intrusive `allgc` как
   единственному lifetime owner; dense structures допустимы только
   как lossless accelerators. `RootScope` и unified `Thread.stack/top` уже
   выполненные prerequisites.

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
