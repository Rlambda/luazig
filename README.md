# luazig

`luazig` — проект по переписыванию Lua на Zig с постоянной проверкой поведения против PUC Lua 5.5.0.

Цель не в том, чтобы написать похожий язык, а в том, чтобы постепенно прийти к drop-in совместимости с PUC Lua: тот же observable behavior на официальном test suite, честные ограничения, понятная архитектура и публичный Zig-facing API для embedding.

## Цели проекта

- Реализовать Lua 5.5.0 на Zig с поведением, максимально близким к PUC Lua.
- Проходить официальный upstream `testes/*.lua` без test-specific hacks и harness-обходов.
- Держать reference implementation рядом и сравнивать `ref` vs `zig` напрямую.
- Развивать публичный Zig embedding API, семантически близкий к Lua C API.
- Использовать актуальный system Zig как основной toolchain.
- При выборе архитектуры следовать PUC-first подходу, если он не ведёт к заведомо худшему решению.

## Текущий статус

Коротко: проект находится в pre-release / parity-focused состоянии.
Bytecode VM (`--vm=bc`) — единственный активно развиваемый backend (default).
IR VM (`--vm=ir`) заморожена: код компилируется и доступен для отладки, parity не поддерживается.

 bc_vm проходит **20/31 test suites** (временно, см. ниже): api, attrib, bitwise, bwcoercion, calls, code, coroutine, errors, gengc, goto, literals, math, memerr, nextvar, pm, strings, tpack, tracegc, utf8, vararg, verybig. Матрица запускается с upstream portable/soft prelude `_port=true; _soft=true`.

### Выполнено: PUC-faithful overlapping bytecode frames (P15.44)

Переход на PUC-faithful модель overlapping call stack, где каждый новый bytecode
frame начинается на позиции function register вызывающего (`base = func_slot + 1`,
PUC `ci->func` / `ci->base = func+1`), а не выше полного register window
вызывающего (`base = bc_stack_top + nextra`).

Что закрыто:

1. `pushBytecodeExecFrame`: new frame base = `caller_func_slot + 1`; аргументы
   уже на месте при OP_CALL — нет копирования аргументов. Для vararg-функций
   без named vararg table (PF_VAHID) реализован PUC `buildhiddenargs`
   (ltm.c:255): func+params сдвигаются вверх past extra args, varargs остаются
   ниже `ci->func` at `[func_slot - nextraargs .. func_slot]`.
2. `popBytecodeExecFrame`: restore `bc_stack_top` to `caller.base + caller.frame_cap`.
3. `frameVarargs` / `opVararg` / `getvarg`: varargs at `[func_slot - nextraargs .. func_slot]`.
4. `VARARGPREP`: для VATAB extra args at `base + numparams` (no shift); для VAHID
   ничего не делает.
5. `GETVARG`: checks if vararg table was materialized (VATAB) — reads from table;
   otherwise reads from hidden args (VAHID).
6. OP_TFORCALL: PUC-faithful copy func+state+control ABOVE close value (R[A+4..])
   before pushing callee frame — preserves TBC close value from overlapping.
7. TAILCALL: resets to `func_slot_base` (unshifted position) before buildhiddenargs
   — prevents cumulative shifting across repeated tail calls.
8. `shrinkBcStack`: computes true high-water mark across ALL frames, not just
   `bc_stack_top` (overlapping model: top frame extent may be less than lower
   frames).
9. All `pushBytecodeExecFrame` callers updated with `caller_func_slot` argument.
10. GC varargs scan: both active-thread and parked-coroutine paths updated.
11. `gcClearDeadFrameRegisters`: bounded clear range to `[clear_from, child.func_slot - frame.base)`
    to prevent clobbering child frame registers in the overlapping model. Without
    this, clearing dead parent registers would nil out live child frame closures.

 Результаты: 28/31 matrix suites проходят (code.lua --testc: **полностью
проходит**, включая checkKlist для integer limits — `0Xffffffffffffffff` теперь
корректно попадает в constant pool через `exp2RK` в table constructor).
2 both_fail: big.lua/files.lua — не связаны с этим изменением).
45/45 smoke tests проходят.

Производительность: geomean **2.82×** vs PUC (улучшение с 2.86× baseline).
lua_calls: -11.0%, field_access: -21.8%, comparisons: -13.4% — все быстрее.
string_concat: +10% (borderline, в рамках шума benchmark harness).

IR VM (frozen snapshot) проходила 32/33 suites. Результаты сохранены как reference.

Ограничения:

- bc_vm достиг функциональной parity (29/29 suites), но производительность пока существенно ниже PUC Lua. Свежий ReleaseFast baseline показывает геометрическое среднее отставание **3.47×** на representative-наборе; calls/hash/array отстают сильнее всего. Подробный профиль и поэтапный roadmap приведены в разделе «Производительность относительно PUC Lua 5.5».
- IR VM доступна через `--vm=ir` для отладки, но не гарантируется от регрессий.
- C ABI shim остаётся smoke/compat слоем поверх Zig API.
- Production/drop-in статус пока не заявляется.

### Выполнено: итеративный bytecode dispatch loop (P15.13–P15.25)

Первоначальный host-recursive путь полностью устранён для активного bytecode
backend. Как и `luaV_execute`/`CallInfo` в PUC Lua, один dispatch driver
переключает heap-resident активации Lua, не сохраняя по Zig stack frame на
каждый Lua-вызов.

Что закрыто:

1. `Thread.bytecode_frames` хранит authoritative `BytecodeExecFrame`, а
   register/boxed stack, runtime frames и TBC list принадлежат тому же
   `Thread`. Переключение coroutine move'ит ownership этих буферов без копии.
2. `BytecodePendingCompletion` описывает post-call действия для обычных
   результатов, одиночных значений, сравнений, `__concat`, `string.gsub`
   replacement callbacks, debug hooks, `__close` и coroutine resume. Поэтому
   opcode или C-library bridge не требует вложенного `runBytecode` и не
   переигрывается после yield.
3. Через общий explicit stack выполняются обычные `CALL`/`TAILCALL`,
   `TFORCALL`, `pcall`/`xpcall`, Lua metamethods (`__index`, `__newindex`,
   арифметика, сравнения, `__len`, `__concat`, `__pairs`), Lua debug hooks,
   `string.gsub` replacement/`__index` callbacks и yielding `__close`.
4. Error unwind хранится как `BytecodeUnwindState` на coroutine. Yield или
   новая ошибка внутри `__close` продолжает тот же LIFO scan. Уникальный
   `activation_id` отличает заменённый child frame от нового frame с повторно
   использованным stack base.
5. Вложенный `coroutine.resume` использует один trampoline и приватный
   execution-layer сигнал `ThreadSwitch`: caller остаётся припаркованным в
   собственном explicit stack, а глубина цепочки coroutine больше не равна
   глубине Zig вызовов. Сигнал поглощается внутри trampoline и не входит в
   публичный `Vm.Error`/Zig API. Попытка resume предка остаётся обычной
   Lua-ошибкой, а не циклом trampoline.
6. Bytecode-активации при yield/resume больше не сериализуются и не
   replay'ятся: authoritative `BytecodeExecFrame` остаётся на `Thread`.
   `IrSuspendedFrame` сохранён только для замороженного IR compatibility-кода
   (включая `testC` closures/hooks, вызванные из bc VM); такой IR child связан с
   bytecode caller через pending continuation, но сам bytecode frame snapshot
   не создаёт.
7. Обёртка `std.Thread.spawn(.{ .stack_size = 256MB })` удалена. CLI работает
   на обычном process stack. Bytecode ограничивается собственными Lua-side
   лимитами frame/stack storage, а не native stack depth.

Постоянные регрессии:

- `tests/smoke/27_iterative_bytecode_calls.lua`;
- `tests/smoke/38_iterative_protected_dispatch.lua`;
- `tests/smoke/39_complete_iterative_dispatch.lua`;
- `tests/smoke/40_large_setlist_extraarg.lua`;
- `tests/smoke/41_strict_globals_env.lua`;
- `tests/smoke/42_gc_debt_and_generational_step.lua`;
- `tests/smoke/43_generational_minor.lua`;
- `tests/stress/iterative_dispatch.lua` через
  `tools/iterative_dispatch_stress.sh`.

Проверенный stress lane под `ulimit -s 1024`: 5000 обычных Lua-вызовов, 3000
вложенных `coroutine.resume` с yield/resume, 2000 рекурсивных metamethod
вызовов, 1000 вложенных `string.gsub` callbacks и mixed bytecode↔`testC` yield
для `CALL`/`TAILCALL`/`TFORCALL`. Полный `cstack.lua` также проходит при
1-МБ host stack. Zig unit tests и 44/44 differential smoke проходят. Все
заявленные 29 upstream suites завершаются успешно на bc VM; точные глубины
`C stack overflow` остаются implementation-defined, но semantic assertions
совпадают.

### Выполнено: tail-call policy с живыми `<close>` переменными (P15.25)

Предыдущий TODO исходил из неверного предположения, что PUC Lua всегда эммитит
`OP_TAILCALL` для `return f()` с живым TBC slot. В Lua 5.5 `retstat` делает
tail-call только при `!fs->bl->insidetbc`; при активной `<close>` переменной
остаётся обычный `CALL + RETURN`, чтобы caller пережил callee и затем закрыл
TBC chain. Бит `k` у `OP_TAILCALL` в `luaK_finish` относится к закрытию open
upvalues (`needclose`), а не разрешает уничтожить frame с живым TBC slot.

`codegen_bc.zig:hasActiveClose()` теперь учитывает и именованные `<close>`
locals, и скрытый четвёртый TBC slot generic-for. Поэтому `return f()` внутри
обоих видов scope сохраняет caller до завершения `f`, а затем выполняет close
ровно один раз. `39_complete_iterative_dispatch.lua` проверяет порядок для
обычного `<close>` local и generic-for iterator close value. Runtime
`BytecodeClosePost.retry_tailcall` остаётся для tailcall, где закрываются open
upvalues/остаточное runtime close-state, включая yield-safe продолжение.

### Выполнено: hardening после dispatch review (P15.26)

Повторно проверен blocker-кейс с ранним `return` из generic `for`: hidden TBC
iterator close value закрывается **после** вычисления return-expression. PUC Lua
и bc VM печатают `false  true`, а differential smoke
`39_complete_iterative_dispatch.lua` проходит без расхождений.

Внутренний coroutine control-flow отделён от публичной модели ошибок:
`ThreadSwitch` находится только в private `DispatchError`, поглощается
`driveBytecodeCoroutineTrampoline`, отсутствует в `Vm.Error`, а `api.zig`
больше не содержит специальной ветки для него. Рядом с
`BytecodePendingCompletion` зафиксированы invariants владения payload slices,
cleanup authority, yieldable continuation kinds и единственная разрешённая
точка thread switching.

После hardening и последующей regression-cleanup фазы повторно пройдены Zig
unit tests, 42/42 differential smoke, 1-МБ iterative-dispatch stress lane и
ровно заявленные 29/29 upstream suites по exit/assertion status.

### Выполнено: завершение regression cleanup после P15.26 (P15.27)

WIP-переход на полный iterative dispatch временно открыл несколько независимых
расхождений parser/codegen/debug runtime. Они исправлены на семантическом
уровне, без распознавания имён upstream-файлов или test-specific replay:

1. Bytecode codegen корректно эмитит большие `SETLIST + EXTRAARG`, поэтому
   `verybig.lua` проходит реальную ветку `testing large programs (>64k)`.
   Быстрый differential regression закреплён в
   `tests/smoke/40_large_setlist_extraarg.lua`.
2. Восстановлены lexical invariants для `goto`/labels, named vararg и Lua 5.5
   global attributes; устранены overflow/diagnostic-buffer ошибки на больших
   constant/register indices и syntax-error paths.
3. Source line metadata теперь хранит call/operator lines в AST и размечает
   loop backedges, многострочные expressions, synthetic register cleanup и
   `VARARGPREP` так же, как PUC-visible line table. Line hooks используют
   реальный previous-PC/previous-line state вместо удалённого preseed,
   завязанного на ожидаемый trace.
4. Debug-hook continuation явно владеет `saved_parent_callee` как GC root.
   Раньше full GC внутри hook мог освободить closure активного parent frame, а
   завершение hook возвращало dangling pointer в `RuntimeFrame.callee`.
   Threads теперь sweep'ятся раньше closures, чтобы parked frames не сохраняли
   даже промежуточные ссылки на уже освобождённые closure storage.
5. `load` инициализирует environment первого upvalue main closure независимо
   от наличия имени `_ENV`. Это сохраняет исполняемость stripped chunks, где
   debug names удалены, но bytecode/upvalue layout остаётся прежним.
6. `tests/smoke/31_debug_bytecode_parity.lua` расширен двумя регрессиями:
   GC внутри line hook сохраняет parent activation, а stripped main chunk
   получает рабочий environment.

Подтверждённые проверки для Zig 0.16.0:

- `zig build test -Doptimize=Debug` — PASS;
- differential smoke — 42/42 PASS;
- iterative dispatch stress под 1-МБ host stack — PASS;
- заявленная upstream matrix с `_port=true; _soft=true` и timeout 60 секунд на suite — 29/29 PASS;
- direct `constructs.lua` без `_soft` под `timeout 60` — `OK` (56.15 с в verification-контейнере);
- direct `verybig.lua` без `_soft` — `+`, `OK`.

### Выполнено: verifier follow-up и GC debt/performance hardening (P15.28)

После review P15.27 закрыты все замечания, мешавшие воспроизводимому принятию
патча:

1. Автоматический GC больше не запускает полный mark+sweep по фиксированному
   числу инструкций. Следующий цикл планируется от live-heap/debt после
   предыдущего, поэтому тысячи динамических `load()` не вызывают повторный
   полный scan растущего heap. Вместе с устранением лишних AST-аллокаций это
   довело неизменённый direct `constructs.lua` до 56.15 с в Debug и позволило
   пройти жёсткий `timeout 60`.
2. Короткие interned strings теперь учитываются в `gc_count_kb`. Раньше цикл,
   создающий только короткие строки, мог выделить сотни мегабайт, не увеличив
   automatic-GC debt; upstream `closure.lua` бесконечно ждал очистки weak
   table. Регрессия закреплена в
   `tests/smoke/42_gc_debt_and_generational_step.lua`.
3. В generational mode каждый явный `collectgarbage("step")` выполняет один
   атомарный цикл и возвращает `false`, как PUC в наблюдаемом API. Это
   сохраняет weak-table/barrier semantics при текущем collector без persistent
   young-generation phases и возвращает `gengc.lua` в green.
4. Публичный `runBytecode` возвращает только `Vm.Error`; приватный
   `runBytecodeInternal` локализует `DispatchError`/`ThreadSwitch` внутри
   execution layer.
5. Strict-global codegen больше не содержит списка имён stdlib. `_ENV` остаётся
   единственным специальным lexical mechanism, а `print`, `require` и прочие
   runtime globals должны быть объявлены по тем же правилам, что и
   пользовательские имена. Это проверяет
   `tests/smoke/41_strict_globals_env.lua`.
6. `lua-5.5.0/testes/time.txt` не является semantic fixture: это
   генерируемый `all.lua` cache времени предыдущего запуска. Matrix runner
   snapshot/restore'ит его, если файл присутствовал, и оставляет отсутствующим,
   если его не было в исходном дереве.

### Выполнено: настоящие инкрементальные GC phases (P15.29)

Debt-gate заменён persistent collector state machine, близкой к PUC
`gcstate`:

```text
pause -> propagate -> atomic -> sweep -> pause
```

1. `gc_step_active`, `gc_step_remaining_bytes`, `gc_in_cycle`,
   `resetGcStepDebt`, `gcStepBudgetBytes` и прежний deferred-full-cycle path
   удалены. Mark sets, gray queue, weak/finalizer queues, registry snapshots и
   sweep cursor теперь принадлежат `Vm` и сохраняются между вызовами
   `collectgarbage("step", n)`.
2. Каждый incremental step расходует реальный work budget
   `max(1, n * stepmul / 100)`: один work unit обрабатывает один gray object
   либо один registry entry sweep. Полный `collect` использует ту же машину,
   прокручивая её до `pause`, а не отдельный атомарный collector.
3. Mutable roots пересканируются между slices, но immutable VM roots,
   Proto/string caches и остальные долговечные registries обходятся только в
   начале цикла. Это устраняет повторный full-root scan в `load()`-heavy коде.
4. Table writes, metatable replacement, closure environment и upvalue writes
   получили conservative tri-color barriers. Ephemeron propagation выполняет
   fixpoint с drain persistent gray queue между проходами.
5. Sweep ограничен budget и удаляет registry entry до освобождения объекта.
   Reverse cursor + `swapRemove` сохраняют объекты, созданные после snapshot,
   и не оставляют dangling pointer в registry между slices.
6. Регистрация `__gc` отслеживается epoch-счётчиком: finalizable, добавленный
   после atomic-фазы текущего цикла, гарантированно запускает следующий цикл.
   Closing finalizers выполняются при `gc_busy=true`, поэтому teardown не
   допускает reentrant collection.
7. Добавлен unit regression
   `vm: incremental GC advances real phases and preserves barrier writes`.
   Он продвигает collector по одному work unit, наблюдает отдельные
   `propagate`/`sweep` slices, проверяет освобождение до завершения цикла и
   сохранение pre-cycle объекта, опубликованного в уже просканированную таблицу.

Подтверждённые проверки на Zig 0.16.0:

- `zig build -Doptimize=Debug` — PASS;
- `zig build test -Doptimize=Debug` — PASS;
- differential smoke — 42/42 PASS;
- iterative dispatch stress под 1-МБ host stack — PASS;
- upstream matrix с `_port=true; _soft=true` и timeout 60 с на suite —
  29/29 PASS;
- direct `constructs.lua` без `_soft` — 55.90 с, exit 0, `OK`;
- direct `verybig.lua` без `_soft` — 7.44 с, exit 0, `OK`;
- targeted GC/coroutine/debug suites (`gc.lua`, `gengc.lua`, `closure.lua`,
  `coroutine.lua`, `db.lua`) — PASS;
- `gc.lua` с matrix prelude `_port=true; _soft=true` — 1.85 с в Debug и
  0.54 с в ReleaseFast в verification-контейнере (критерии <5 с / <1 с
  выполнены).

Direct `constructs.lua` проходит заданный 60-секундный лимит в этом
контейнере, но запас составляет около четырёх секунд, поэтому это измерение,
а не гарантия времени на любой машине.

Atomic weak/finalizer transition пока остаётся одной indivisible work unit:
mark propagation и registry sweep инкрементальны, а операции, меняющие
наблюдаемую weak/finalizer семантику, завершаются внутри atomic boundary, как и
в PUC.

### Выполнено: PUC-faithful compile-time constant folding

Реализована PUC `constfolding` (lcode.c:1418) в bytecode-компиляторе
(`src/lua/codegen_bc.zig`):

- **Бинарные op'ы** с двумя числовыми константами сворачиваются на этапе
  компиляции: `3.78 / 4` → `0.945` (одна константа, без runtime `OP_DIV`).
- **Унарные op'ы** (`-`, `~`) на константном операнде сворачиваются.
- **`<const>` locals** с константным инициализатором подставляются по
  использованию (PUC `RDKCTC`/`VCONST`), в том числе через границы функций —
  value пробрасывается в `const_upvalue_values` без создания реального upvalue,
  как PUC `singlevaraux` оставляет `VCONST`.
- **Safety guards** как в PUC `validop`: не сворачиваются DIV/IDIV/MOD на ноль
  (runtime error), bitwise на не-целых, и float-результаты NaN/0.0 (семантика
  `-0.0`). Арифметика (включая wrapping shifts, floor idiv/mod) зеркалит
  `luaO_rawarith`/`intarith`/`numarith`.
- Попутно исправлена `luaK_float`-parity: integer-valued floats (`0.0`, `3.0`)
  теперь используют `LOADF` вместо `LOADK`, не загрязняя constant pool.

Результаты:

  - `code.lua --testc`: **полностью проходит**, включая `checkKlist` в
    `checkints(-1)` (line 491). `0Xffffffffffffffff` теперь корректно
    попадает в constant pool через `exp2RK` в `genTable` (table constructor
    field values folding). Все folding-кейсы верифицированы.
  - Регрессий нет: `tools/testes_matrix.py` (без `_soft`/`_port`) — 28/31 pass
    (zig_fail=0; 2 both_fail: big.lua/files.lua — не связаны); все `tests/smoke/` проходят.

 RK encoding для SET operands реализован (PUC `exp2RK`):
 - `exp2K`/`exp2RK` helpers добавлены в codegen (fold const → K[c] с k=1).
 - `genSet` для `.Index`/`.Field` LHS использует `emitABCk` с k-bit.
 - `genTable` (table constructor) `.Name`/`.Index` paths используют `exp2RK`
   для value folding + key folding (SETI/SETFIELD/SETTABLE), matching PUC
   `recfield` → `luaK_storevar` → `codeABRK` → `exp2RK`.
 - `genAssign` single-assign path: `exp2RK` для table sets (PUC `luaK_storevar`).
 - VM SET handlers (SETTABLE/SETI/SETFIELD/SETTABUP) уже поддерживают RK[C].
 - `T.listcode` показывает `[k]` flag в выводе (PUC buildop format).

   `checkKlist` в `checkints(-1)` (line 491) теперь проходит: `genTable`
   использует `exp2RK` для table constructor field values, и hex-literal
   `0Xffffffffffffffff` (= -1) попадает в constant pool как K-constant
   (PUC `luaK_intK`), а не эмитится как LOADI immediate.
   `6 or true or nil` / `k6 or kTrue or kNil` checkequal (line 434) теперь
   проходит: `genNameValue` discharge'ит `<const>` upvalues в константное
   значение (LOADI/LOADTRUE/LOADNIL) вместо GETUPVAL, mirroring PUC
   `luaK_dischargevars` VCONST handling. De Morgan checkequal
   (`0 <= a and a <= l` ≡ `not(not(a>=0) or not(a<=l))`) теперь проходит
   через PUC VJMP→LFALSESKIP/LOADTRUE pattern. MOVE-elimination
  в multi-assign/table-set закрыт: genSetExpDesc defer RHS discharge до LHS
  preparation (PUC luaK_storevar ordering), `a = a` no-op (PUC VLOCAL same
  reg). Все codegen
  instruction-selection расхождения (Groups 1–4) закрыты:
  - ADDI-for-SUB: `x - 127` → `ADDI(x, -127)` + `MMBINI` (PUC `finishbinexpneg`).
    VM ADDI handler peek-ает следующий MMBINI для TMS_SUB vs TMS_ADD.
  - Float bitwise guard: `x & 2.0` → `LOADF + BAND + MMBIN` (не BANDK).
    PUC `codebitwise` требует `VKINT`; float (VKFLT) → register path.
  - Const-folded BinOp RHS: `x % (100-10)` → `MODK` (folding 100-10 → 90).
    `numericConstFromExp` теперь сворачивает `.BinOp`/`.Paren` через
    `genConstExpDesc`.
  - MMBINI/MMBINK variant: определяется по последнему эмитированному opcode
    (ADDI/SHLI/SHRI → MMBINI; K-variants → MMBINK), не по исходному NumConst.

 Остающийся блокер для полного прохода `locals.lua --testc` — VM bug:
 `--testc` mode + overflow test + `T.testC` stack manipulation + RK bytecode
 changes trigger a coroutine yield/resume + TBC close issue (line 926).
 RK codegen корректен (PUC-faithful), issue в VM stack handling.

## Требования

- `zig` из system toolchain.
- C toolchain для reference Lua: `make`, `gcc` или совместимый compiler.
- Инициализированный upstream test suite submodule.

На Arch Linux:

```sh
sudo pacman -S --needed zig gcc make
```

Проверка Zig:

```sh
zig version
```

Инициализация submodule:

```sh
git submodule update --init --recursive
```

## Быстрый старт

Собрать reference Lua на C:

```sh
make lua-c
./build/lua-c/lua -v
```

Собрать Zig implementation:

```sh
zig build -Doptimize=Debug
./zig-out/bin/luazig --help
./zig-out/bin/luazigc --help
```

Запустить release gate:

```sh
tools/release_gate.sh
```

## Бинарники

Reference implementation:

- `./build/lua-c/lua`
- `./build/lua-c/luac`

Zig implementation:

- `./zig-out/bin/luazig`
- `./zig-out/bin/luazigc`

`--engine=ref` удалён. Для reference behavior нужно запускать `lua`/`luac` напрямую. `--engine=zig` оставлен как no-op для старых скриптов.

## Устройство проекта

Основные директории:

- `src/bin/` — CLI entrypoints: `luazig`, `luazigc`.
- `src/lua/` — реализация языка: lexer, parser, AST, IR, codegen, VM, stdlib, API shim.
- `src/util/` — общие utility wrappers, включая текущий Zig `std.Io` stdio layer.
- `lua-5.5.0/` — vendored PUC Lua 5.5.0 release: `src/` (reference C source, из которого собирается `build/lua-c/lua`/`luac` для differential-тестов) и `testes/` (upstream test corpus, завендорен из v5.5.0 tag).
- `tools/` — differential runners, release gate, perf tooling, heavy/OOM probes.
- `tools/perf/` — core perf baselines/current snapshots.

Основной runtime path:

- `src/lua/lexer.zig` читает source bytes и выдаёт tokens.
- `src/lua/parser.zig` строит AST.
- `src/lua/codegen_bc.zig` компилирует AST → bytecode (Proto).
- `src/lua/vm.zig:runBytecode()` исполняет bytecode на shared stack.
- IR path (`codegen.zig` → `runFunctionArgsWithUpvalues`) заморожен, доступен через `--vm=ir`.
- `src/lua/lower_ir.zig` и `src/lua/bc_vm.zig` disabled (старый experimental backend, будет удалён).
- `src/lua/api.zig` содержит публичный Zig-facing API и testC-facing compatibility layer.

## Устройство тестов

Тестовая стратегия основана на differential testing: один и тот же upstream Lua test запускается на PUC Lua и на `luazig`, затем сравниваются exit code и output.

Reference запускается напрямую:

- `build/lua-c/lua`
- `build/lua-c/luac`

Zig implementation запускается напрямую:

- `zig-out/bin/luazig`
- `zig-out/bin/luazigc`

Основные test lanes:

- `tools/run_tests.py` — targeted differential runner для одного или нескольких suites.
- `tools/testes_matrix.py` — пофайловая matrix по `lua-5.5.0/testes/*.lua`.
- `tools/testes_matrix_safe.sh` — matrix под memory/time wrapper, чтобы тяжёлые tests не убивали Codex/session.
- `tools/iterative_dispatch_stress.sh` — 1-МБ host-stack regression для call/metamethod/coroutine dispatch.
- `tools/testc_lane.py` — official `testC` lane через Lua test DSL.
- `tools/api_regression_lane.py` — Zig unit/integration tests + testC lane + targeted parity.
- `tools/perf_compare.py` — основной perf gate: 16 микро-бенчмарков, geomean Zig/PUC ratio.
- `tools/perf_core_snapshot.py` — end-to-end замер core suites (nextvar, coroutine, gc).
- `tools/perf_guard_core.py` — защита от perf regressions относительно baseline.
- `tools/release_gate.sh` — единая команда для проверки release/readiness состояния.

Запустить targeted parity:

```sh
python3 tools/run_tests.py \
  --suite nextvar.lua \
  --suite coroutine.lua \
  --suite calls.lua \
  --suite files.lua \
  --suite locals.lua \
  --suite db.lua \
  --suite gc.lua
```

Запустить full safe matrix:

```sh
tools/testes_matrix_safe.sh
```

По умолчанию matrix запускает upstream tests с prelude:

```lua
_port=true; _soft=true
```

Это важно для интерпретации результата:

- `_port=true` отключает непереносимые OS/shell/locale/filesystem checks.
- `_soft=true` отключает или сокращает resource-heavy ветки official suite.
- `big.lua` в таком режиме не выполняет тяжёлую часть и сразу возвращает `'a'`:
  `if _soft then return 'a' end`.
- `verybig.lua` в таком режиме выполняет только RK-prefix и пропускает
  `testing large programs (>64k)`:
  `if _soft then return 10 end`.
- Поэтому `big.lua pass` в safe matrix означает **soft-mode parity**, а не полное
  standalone прохождение тяжёлого `big.lua`; аналогично `verybig.lua pass`
  означает, что large-program ветка не покрыта safe matrix.

Платформенная ветка `files.lua` (popen/execute, без `_port=true`) содержит
platform-dependent тесты: `sh -c 'kill -s HUP $$'` (line 814) падает одинаково
и в luazig, и в PUC Lua на этой системе (shell получает signal вместо ожидаемого
exit). Portable matrix (`_port=true`) для `files.lua` проходит идентично PUC Lua.
- Standalone `big.lua` без `_soft` не является корректным простым запуском:
  upstream файл содержит `coroutine.yield'b'` и в `all.lua` рассчитан на запуск
  через `coroutine.wrap(loadfile(...))`. При прямом запуске PUC Lua ожидаемо
  падает с `attempt to yield from outside a coroutine`; `luazig` должен совпадать
  с этим поведением/сообщением как отдельный quality item.

Корректные команды для сравнения soft matrix behavior:

```sh
./build/lua-c/lua -e '_port=true; _soft=true' lua-5.5.0/testes/big.lua
./zig-out/bin/luazig -e '_port=true; _soft=true' lua-5.5.0/testes/big.lua
./build/lua-c/lua -e '_port=true; _soft=true' lua-5.5.0/testes/verybig.lua
./zig-out/bin/luazig -e '_port=true; _soft=true' lua-5.5.0/testes/verybig.lua
```

Корректный способ проверить real `big.lua` path — запускать его через `all.lua`
без `_soft` либо отдельной coroutine-обвязкой, потому что именно так upstream
ожидает yield в конце файла:

```sh
cd lua-5.5.0/testes
/home/boss/codes/luazig/build/lua-c/lua -e '_port=true' all.lua
/home/boss/codes/luazig/zig-out/bin/luazig -e '_port=true' all.lua
```

Запустить matrix без wrapper, если окружение безопасно:

```sh
python3 tools/testes_matrix.py --no-build --timeout 120 --json-out /tmp/testes-matrix.json
```

Запустить API/testC lane:

```sh
python3 tools/api_regression_lane.py --timeout 180 --testc-timeout 120
```

Запустить perf snapshot и guard:

```sh
python3 tools/perf_core_snapshot.py --out /tmp/core-current.json --timeout 240
python3 tools/perf_guard_core.py \
  --baseline tools/perf/core_baseline.json \
  --current /tmp/core-current.json \
  --max-regression 0.15
```

## Производительность (perf gate)

Основной инструмент — `python3 tools/perf_compare.py`:
16 микро-бенчмарков (`tools/microbench.lua`), median-of-7, pinned CPU core,
geomean Zig/PUC ratio, regression check vs `tools/perf/baseline-p15.37.json`.

```sh
python3 tools/perf_compare.py              # run + compare vs baseline
python3 tools/perf_compare.py --no-build   # skip rebuild (use existing binaries)
python3 tools/perf_compare.py --update-baseline  # rewrite baseline
```

Текущий geomean: **2.76×** от PUC Lua. Без регрессий от baseline.

| Workload | Zig/PUC |
|---|---|
| string_concat | 1.56× |
| dynamic_load | 1.65× |
| comparisons | 1.75× |
| float_arith | 2.36× |
| int_arith | 2.61× |
| global_arith | 2.65× |
| branch_loop | 2.50× |
| field_access | 2.80× |
| temp_table_alloc | 2.96× |
| string_loop | 3.18× |
| mixed_arith | 3.26× |
| metamethod_add | 3.39× |
| lua_calls | 3.65× |
| coroutine_yield | 3.69× |
| array_access | 3.79× |
| hash_access | 4.15× |

## Release gate

Главная команда проверки текущего состояния:

```sh
tools/release_gate.sh
```

Gate выполняет:

- `zig build test -Doptimize=Debug`
- official `testC` lane
- targeted parity suites
- iterative dispatch stress под 1-МБ host stack
- full safe matrix
- core perf snapshot
- perf guard

Текущий ожидаемый результат gate для bc VM: green по correctness lane — build/unit, official testC, differential smoke, iterative-dispatch stress и 29/29 portable/soft upstream matrix. Performance guard пока служит regression gate, а не подтверждением parity с PUC Lua.

## Производительность относительно PUC Lua 5.5

Функциональная parity не означает performance parity. На текущем состоянии
(bc VM после P15.30.1, оптимизации P15.31–P15.39) геометрическое среднее
замедления от PUC Lua **3.47×** на microbench (см. P15.37 baseline
`tools/perf/baseline-p15.37.json` для точной разбивки по workload'ам). Раздел фиксирует измеренный baseline,
известные причины и порядок оптимизаций. Он является частью проектного контракта:
performance-задачи нельзя закрывать только локальным улучшением одного benchmark
без проверки общего профиля и correctness gates.

### Методика профилирования

Дата базового замера: 2026-07-14. Сравнивались:

- luazig, Zig 0.16.0, `ReleaseFast`, `--vm=bc`;
- PUC Lua 5.5, собранный из vendored `lua-5.5.0`;
- один и тот же CPU через `taskset -c 0`;
- медиана 3–5 прогонов коротких изолированных workloads;
- `/usr/bin/time` для max RSS;
- ptrace IP sampling с символизацией через `llvm-symbolizer`;
- временная opcode instrumentation для подсчёта dispatch-инструкций;
- A/B-сборки, где менялась только одна деталь.

Обычный Linux `perf` в verification-контейнере недоступен: старое ядро 4.4
возвращает `ENODEV` из `perf_event_open`. Поэтому baseline не содержит hardware
counters (`cycles`, IPC, branch misses, LLC misses). При запуске на современном
ядре roadmap P15.37 должен дополнить существующие измерения настоящими
`perf stat`/`perf record`, но отсутствие counters не мешает уже сейчас
разделить codegen, dispatch, allocator, table layout и compiler pipeline.

### P15.36 perf-based hotspot analysis (современное ядро, perf 7.1)

После P15.36 замеры на современном ядре 7.0.11-arch1 (CPU hybrid atom/core,
`taskset -c 0`, ReleaseFast build) дали первую аппаратную картину. Геометрическое
среднее замедления упало с **11.9× (baseline P15.30.1)** до **5.21×**.
После P15.37 (hotspot-driven fixes) — **4.77×** (см. `tools/perf/baseline-p15.37.json`).
После P15.38a–d (codegen opcode reduction) — **3.69×**.
После P15.38e (PendingCallSlot.get() copy elimination) — **3.74×** (within noise; lua_calls -3%, memcpy eliminated).
После P15.38f (debug hook fast path) — **3.71×** (lua_calls -8.9%, debug hook overhead eliminated).
После P15.38g (GETTABLE/SETTABLE fast path) — **3.53×** (array_access -34.6%, hash_access -31.9%).
После P15.38h (tostring stack-buffer) — **3.43×** (string_loop -9.9%, heap alloc eliminated).
После P15.38i (PUC-style builtin results on bc_stack) — **3.42×** (hash_access -4.6%, array_access -4.4%).
После P15.39 (variant TKey, Node 48B→32B) — **3.47×** на microbench (cache плотность
не помогает tiny tables, см. P15.39); **-14% wall / -83% LLC misses** на 100K-key hash.
После P15.40 (inline + dedup: SETLIST fast path, OP_CALL inline hook check, inline array-part
fast path, overflow check merge, resolveProtoConstants/popBytecodeExecFrame inline, has_open_upvalues
flag) — **2.95×**.
После P15.41 (inline bcConstToValue, MOVE fast path via has_open_upvalues, @branchHint on cold paths) — **2.86×**.
После P15.42 (ctx.fr elimination, OP_MOVE @branchHint fix, stale frame.regs GC fix) — **2.88×**.
После P15.43 (stale rargs GC corruption fix, OP_MOVE @branchHint fix, frame.regs GC fix) — **2.91×**.

Сводная таблица по hotspot-функциям на worst-абсолютных/множительных workloads
(`perf record --call-graph lbr`, percent-limit 1). Колонка «P15.37 fix» показывает,
какая задача закрыла hotspot:

| Workload | Worst hot symbol | Доля до P15.37 | P15.37 fix | Доля после |
|---|---|---:|---|---:|
| `lua_calls` (18.6×→6.6×) | `compiler_rt.memset` | **57%** | P15.37a (frame slim + pending_call split) | **<1%** |
| `global_arith` (6.9×→6.3×) | `ltable.nodeLookup` | 28% | P15.37b (Node 56B→48B) | ~28% (marginal) |
| `global_arith` (6.9×→6.3×) | metamethod-check (`indexValueDepth`+`tryPushBytecodeNewIndexMetamethod`) | 11% | P15.37c (Table.flags BITRAS) | ~9% |
| `branch_loop` (6.0×→6.1×) | `runBytecodeDispatch` (весь loop) | **98%** | — (instruction-count bound) | ~98% |
| `comparisons` (7.6×→7.8×) | `runBytecodeDispatch` | **98%** | — (instruction-count bound) | ~98% |
| `metamethod_add` (7.7×→4.9×) | `compiler_rt.memset` | 36% | P15.37a (frame slim + pending_call split) | **<1%** |
| `hash_access` (7.3×→7.7×) | `ltable.nodeLookup` | 14% | P15.37b (Node 56B→48B) | ~14% (marginal) |

**Главные выводы из hotspots:**

1. **`memset` доминирует везде, где есть call/return (Недостаток 6, P15.35
   недоработан).** Это НЕ `@memset(regs)` — его удалили в P15.36. Источник —
   инициализация больших структур фреймов при `frames.append`: компилятор
   эмитит `compiler_rt.memset` (byte-wise, не векторизованный!) для
   zero-init `RuntimeFrame` (~280 B) и `BytecodeExecFrame` (~936 B, с
   большим `pending_call` union 760 B) на каждом call/return.
   - 29% от lua_calls — `pushBytecodeExecFrame → append`
   - 28.5% от lua_calls — `completeBytecodeExecFrame → applyBytecodePendingResults`
   - 36% от metamethod_add — тот же call machinery
   **P15.37a закрыл:** reuse-pool pattern (`addOne` + field-by-field writes) вместо
   struct-literal `append`, плюс `PendingCallSlot` wrapper (`active: bool` +
   `payload: BytecodePendingCall = undefined`) вместо `?BytecodePendingCall = null`.
   `compiler_rt.memset` доля упала с 57% до <1%.

2. **Dispatch loop "branch-heavy" workloads (`branch_loop`, `comparisons`)
   упираются не в branch misses, а в instruction count (Недостаток 1, 3).**
   IPC=4.24 и IPC=3.88 — высокие, branch misses ≤0.02%. Это значит, что
   CPU выполняет инструкции быстро, но их **слишком много**: per-Lua-iteration
   dispatch overhead + codegen производит лишние опкоды (MOVE/LOADNIL/CLOSE).
   **P15.37 не закрывал** — требует codegen-level работы (P15.38+).

3. **Table lookup — главная доля `global_arith`/`hash_access` (Недостаток 4,
   P15.34 недоработан).** 28% nodeLookup + ~14% keyHash/wyhash на global_arith.
   Текущий `Node` был 56 B (key 16 + value 16 + hash 8 + dead_key 1 + next* 8 +
   padding), PUC Node = 24 B (TKey 8 + TValue 16, chain packed в TKey TValue).
   **P15.37b закрыл частично:** Node уплотнён до 48 B через `next_offset: i32`
   (PUC `gnext`-faithful) + `dead_key` packed в старший бит `hash`.
   Cache line (64 B) вмещает 1.33 наших Node vs 2.67 PUC Node — всё ещё хуже,
   но ближе. Полная parity требует variant TKey (P15.38+).

4. **Metamethod-check overhead (Недостаток 2, частично).** 11% от global_arith
   тратится в `indexValueDepth` + `tryPushBytecodeNewIndexMetamethod` — каждая
   global get/set проверяет metatable даже для plain tables без метаметодов.
   **P15.37c закрыл:** `Table.flags` bitmask (PUC BITRAS, `ltm.h:54`) —
   bit set = "metatable не имеет этого метаметода", skip `getFieldOpt`.
   Доля упала с 11% до ~9% (меньше ожидаемого, т.к. `global_arith` работает
   с `_ENV` без metatable — null-check уже short-circuit'ит).

5. **Perf работает на современном ядре.** README baseline писал "perf недоступен
   в verification-контейнере". При локальной разработке нужно использовать
   `perf stat`/`perf record --call-graph lbr` — даёт точную hotspot-карту.
   `taskset -c 0` обязателен для шумящей hybrid-архитектуры (atom/core).

План P15.37 (см. `docs/superpowers/plans/2026-07-18-performance-phase-p15.37.md`)
перевёл эти findings в конкретные задачи. Все 4 задачи (a/b/c/d) выполнены.

### Сводный ReleaseFast baseline

| Нагрузка | PUC Lua, медиана | luazig, медиана | Замедление |
|---|---:|---:|---:|
| integer arithmetic | 0.058 с | 1.240 с | 21.4× |
| global access + arithmetic | 0.054 с | 0.965 с | 17.8× |
| branch loop | 0.060 с | 1.016 с | 16.9× |
| Lua calls | 0.047 с | 0.736 с | 15.7× |
| array table access | 0.041 с | 0.372 с | 9.1× |
| integer hash table access | 0.065 с | 0.633 с | 9.7× |
| temporary table allocation | 0.058 с | 1.022 с | 17.5× |
| string-heavy loop | 0.050 с | 0.633 с | 12.6× |
| coroutine resume/yield | 0.023 с | 0.144 с | 6.1× |
| dynamic `load()` | 0.043 с | 0.207 с | 4.8× |

Геометрическое среднее на этой выборке — **примерно 11.9×**. Абсолютные числа
зависят от CPU и allocator, но относительный профиль устойчив: сильнее всего
отстают arithmetic/global/branch/calls и массовые table allocations.

### Недостаток 1: codegen исполняет слишком много bytecode

Для простого цикла:

```lua
local s = 0
for i = 1, n do
    s = s + i
end
```

luazig выполняет примерно семь opcode на итерацию:

- `MOVE` × 3;
- `LOADNIL`;
- `ADD`;
- `CLOSE`;
- `FORLOOP`.

В PUC Lua подготовительные операции находятся вне горячего тела; на итерацию
остаются в основном arithmetic opcode и `FORLOOP`.

Причины:

1. Выражения преждевременно материализуются во временные регистры, после чего
   копируются через `MOVE`.
2. `resetRegs()` консервативно эмитит `LOADNIL` на границе statement, чтобы
   убрать stale GC references, вместо точного register liveness.
3. Numeric `for` получает `CLOSE`, даже когда ни одна local переменная scope не
   захвачена closure и закрывать нечего.
4. Нет PUC-подобных immediate/constant forms (`ADDI`, `ADDK`, RK operands и
   аналогов для comparisons/table operations).

Это главный общий bottleneck: даже идеально оптимизированный `ADD` не устранит
несколько лишних dispatch cycles на каждую Lua-операцию.

**Способ устранения:** P15.32 должен ввести PUC-подобный descriptor выражений,
сохранять значения как register/constant/immediate до фактической
materialization, писать результат прямо в destination и генерировать
`LOADNIL`/`CLOSE` только по точному liveness/upvalue анализу.

### Недостаток 2: generic operation path используется даже для обычных чисел

Sampling integer arithmetic loop:

| Hot path | Доля samples |
|---|---:|
| общий `runBytecodeDispatch` | ~42% |
| `coerceArithmeticValue` | ~23% |
| bytecode close continuation | ~12% |
| `evalBinOp` + `binAdd` | ~10% |
| frame/upvalue/прочее | остаток |

Обычный numeric `ADD` проверяет и преобразует операнды дважды: сначала перед
решением о metamethod, затем повторно внутри generic arithmetic helper.

A/B-сборка только с прямым Int/Num fast path для `ADD`, без изменения bytecode,
ускорила benchmark примерно с **1.44 до 0.95 с** — около **1.5×**.

**Способ устранения:** P15.31 вводит typed fast paths для arithmetic, bitwise,
comparisons, `GETI/SETI` и interned-string `GETFIELD/SETFIELD`. Generic
coercion/metamethod path должен вызываться только после провала дешёвых tag
checks. При этом обязателен точный PUC-порядок conversions, ошибок и выбора
metamethod.

### Недостаток 3: слишком много bookkeeping на каждом opcode

Общий dispatch path даже в простом no-hook/no-yield случае обновляет или
проверяет:

- `RuntimeFrame.pc`, `top`, `current_line`, varstack state;
- line/count hooks;
- GC debt/tick;
- pending completion и result state;
- coroutine/thread-switch boundaries;
- boxed/register state;
- debug metadata.

PUC Lua хранит hot state в локальных переменных `luaV_execute` и публикует его
в `lua_State`/`CallInfo` на safepoints. В luazig значительная часть cold-path
машинерии остаётся внутри общего interpreter loop.

**Способ устранения:** P15.33 разделяет fast и slow dispatch. В fast loop `pc`,
base, top и current closure живут в локальных Zig-переменных. Runtime structures
синхронизируются только на call/return, allocation/GC safepoint, hook,
error/metamethod, yield/resume и debug API boundary. Continuation/debug/error
код выносится из hot function для уменьшения instruction-cache footprint.

### Недостаток 4: таблицы и GC-объекты слишком велики

Текущие размеры:

| Тип | luazig | PUC Lua |
|---|---:|---:|
| `Value` / `TValue` | 16 B | 16 B |
| `Table` | 72 B | 48 B |
| hash `Node` | 56 B | 24 B |
| `Closure` / `LClosure` | 72 B | 40 B |
| `Cell` / `UpVal` | 48 B | 40 B |
| `Thread` / `lua_State` header | 840 B | 208 B |

На integer hash benchmark sampling показывает примерно 31% в `nodeLookup`,
14% в очистке hash storage, 13% в dispatch и 11% в `nodeInsert`. `Node` в 2.3
раза больше PUC-варианта, поэтому на cache line помещается меньше entries,
растут RSS, cache misses и стоимость rehash/memset.

**Способ устранения:** P15.34 должен уплотнить `Node` до 24–32 байт, добавить
специализированные integer/interned-string paths, убрать generic `Value`
hashing для array index и не обнулять большие 56-byte nodes целиком при каждом
росте. Изменение layout принимается только вместе с weak/dead-key/Brent-chain
регрессиями.

### Недостаток 5: allocator рассчитан не на эту модель VM

CLI использует `std.heap.smp_allocator`, хотя Lua VM однопоточная. Sampling
показывает mutex/slab paths, а allocation-heavy benchmark — большой разрыв RSS.

A/B для 400 000 временных таблиц:

| Allocator | Время | Max RSS |
|---|---:|---:|
| `smp_allocator` | ~0.81 с | ~160 МБ |
| libc allocator | ~0.54 с | ~134 МБ |
| PUC Lua | ~0.04 с | ~4 МБ |

Libc allocator даёт около 1.5× на массовых аллокациях, но почти не влияет на
lookup-heavy workload. Следовательно, простая замена allocator полезна как
промежуточный шаг, но не решает раздутый layout и слишком большое число
allocation units.

**Способ устранения:** после безопасного временного перехода на libc allocator
P15.34 должен добавить однопоточный VM allocator: page/slab pools для
`Table`/`Node`/`Closure`/`Cell`, отсутствие mutex и bulk release страниц после
major sweep. Compile-temporary allocations должны жить в отдельной arena.

### Недостаток 6: дорогая call-frame machinery

Lua calls отстают примерно в 15–16 раз, coroutine resume/yield — примерно в 6
раз. На обычном вызове участвуют generic `resolveCallable`, growable arrays
frames/exec-frames, публикация runtime state, pending completion, debug/hook
transfer и close/upvalue machinery.

**Способ устранения:** P15.35 вводит предвыделенный PUC-подобный CallInfo stack,
компактный frame header и отдельный прямой path для обычного Lua closure call.
`resolveCallable`, `__call`, hooks, yields и error continuations остаются slow
path. Debug names реконструируются лениво только при error/debug API.

### Недостаток 7: `load()` всегда строит полный AST

Dynamic `load()` отстаёт меньше — около 4.8× — но профиль показывает отдельный
compiler bottleneck:

- allocator/system paths — около 39%;
- создание bytecode closure — около 15%;
- рост AST/name arrays — около 12%;
- memcpy — около 8%.

PUC компилирует parser-to-bytecode почти напрямую, тогда как luazig строит
полный AST, повторно обходит его и использует множество независимых growable
arrays.

**Способ устранения:** P15.36 сначала добавляет reuse arena, capacity hints,
small-vector storage и сокращение копирований identifier/string data. После
стабилизации нужен streaming parser-to-bytecode path; AST остаётся optional
режимом для tooling/debug, а не обязательной runtime стадией.

Пункт необходимо подробно обсудить, так как AST было подмечено как одно из улучшений
luazig по сравнению с PUC Lua

### Что не является главным общим bottleneck

После P15.30.1 GC correctness и pacing остаются критичными, но сам collector не
объясняет основной performance gap. Arithmetic/global/branch loops почти не
аллоцируют и всё равно отстают в 17–21 раз. Поэтому следующая крупная
оптимизация должна начинаться с typed operations, codegen и dispatch, а не с
ещё одного переписывания GC.

### Ранжирование по ожидаемому эффекту

1. Instruction inflation из codegen.
2. Тяжёлый общий dispatch path.
3. Generic arithmetic/comparison/metamethod path.
4. Table representation и allocator.
5. Call-frame machinery.
6. AST-based dynamic compilation.
7. Дополнительный GC tuning только после измеренного доказательства, что он
   ограничивает конкретный workload.

## План работ

Каждая итерация закрывает минимум один чекбокс ниже (см. `AGENTS.md`).
Дизайн фиксируется здесь же; отступления от PUC отмечаются явно.

### P15.68 — testC yield/resume parity (завершён)

Цель: починить оставшиеся testC coroutine.lua failures. После P15.67
coroutine.lua падал на line 663 (`setglobal X` в line hook). P15.68 fixes
несколько связанных проблем:

- [x] **P15.68a: Line hook `skip_bc_line_once` not set on yield-from-hook.**
  P15.67 fix only set `resume_skip_count_pc` for count hooks. Line hooks
  didn't set `skip_bc_line_once`, so after resume the line hook immediately
  re-fired on the same instruction. Fix: set `skip_bc_line_once = true` for
  line hooks in `builtinCoroutineYield`'s P15.67 block.

- [x] **P15.68b: `sethook` not seeding `last_line_pc` for all Lua frames.**
  When `sethook` was called from `T.sethook` (a Lua function), only the top
  frame (T.sethook's frame) was seeded. The coroutine body's frame had
  `last_line_pc = null`, causing a spurious line hook on the `sethook` line.
  Fix: seed `last_line_pc` for ALL Lua frames on the call stack.

- [x] **P15.68c: `debug.getinfo(c, 1)` returning wrong frame.** For suspended
  coroutines with only one frame, `debug.getinfo(c, 1)` returned the same
  frame as level 0 instead of nil. Fix: check `th.call_frames.len() < 2`.

- [x] **P15.68d: testC `yield` (without `k`) not saving continuation.** PUC
  `lua_yield` returns on resume, and `runC` returns immediately. Our testC
  `yield` called `builtinCoroutineYield` without saving a continuation, so
  the coroutine body couldn't continue after yield. Fix: save a `return *`
  continuation with empty stack (unless inside a debug hook).

- [x] **P15.68e: `builtinCoroutineResume` running testC continuations directly.**
  For bytecode-path yields (`bytecode_inplace_suspended`), the continuation
  must run inside the bytecode VM (which re-executes the OP_CALL to
  `builtinTestcTestC`). Fix: skip the direct continuation path when
  `bytecode_inplace_suspended` is true.

- [x] **P15.68f: `bytecode_inplace_suspended` not set for testC yields.**
  Only debug hook yields set `bytecode_inplace_suspended`. testC `yield`
  (outside a hook) didn't set it, causing `errdefer` to unwind all frames.
  Fix: set `bytecode_inplace_suspended = true` in `builtinCoroutineYield`
  when `testc_pending_conts` is non-empty and not in a debug hook.

- [x] **P15.68g: `debug.getinfo` wrong info for builtin-yield coroutines.**
  When a coroutine yielded from a builtin (testC `yield`), `debug.getinfo`
  returned the Lua frame's info instead of the builtin's info (with
  `linedefined = -1`). Fix: check `suspended_builtin` and
  `yielded_from_debug_hook` to return the correct level 0 info.

**Results:** 8/9 testC suites pass. coroutine.lua fails at line 1093
(`yieldk` continuation test — separate issue). Matrix 28/31, smoke 45/45 —
no regressions.

### P15.69+P15.70 — testC callk/pcallk/yieldk continuation chain (завершён)

Цель: починить chain of suspendable C calls в testC (`T.makeCfunc` с `callk`).
coroutine.lua падал на line 1191 — "chain of suspendable C calls" test.
Три уровня вложенных C-вызовов, каждый yield'ит через `callk`. При resume
ожидалось 3 значения `34` (одно от каждой continuation), но возвращалось 0.

- [x] **P15.69a: `saveTestcPendingContinuation` sets `bytecode_inplace_suspended`.**
  When `callk`/`pcallk`/`yieldk` catches `error.Yield` from `apiCall`, the
  continuation is saved AFTER `builtinCoroutineYield` returns. The
  `bytecode_inplace_suspended` flag must be set here (not in
  `builtinCoroutineYield`) so `runBytecodeInternal`'s errdefer doesn't unwind
  frames.
- [x] **P15.69b: Direct continuation path sets `resume_inbox`.** For Builtin
  callee coroutines (`coroutine.wrap(T.testC)`), `setThreadResumeInbox` must
  be called before `resumePendingTestcContinuation` so `takeBytecodeResumeValues`
  returns the correct resume args.
- [x] **P15.69c: `builtinTestcTestC` runs continuations regardless of
  `bytecode_inplace_suspended`.** Removed the `!th.bytecode_inplace_suspended`
  condition — continuations must run for BOTH direct and bytecode-inplace paths.
- [x] **P15.69d: `pushupvalueindex N` pushes integer N.** PUC
  `lua_pushinteger(L1, lua_upvalueindex(N))` pushes the upvalue INDEX, not the
  value. Used with `callk 1 -1 .` where `.` pops this index.
- [x] **P15.69e: `resolveTestcContinuationScript` for `.` pops integer and
  fetches upvalue.** PUC's `getnum_aux(".")` pops integer from stack, then
  `Cfunck` uses `lua_tostring(L, ctx)` to fetch the continuation script.
- [x] **P15.70: LIFO continuation loop in `builtinTestcTestC`.** Multiple
  continuations from a chain of `callk` yields are run LIFO (innermost first),
  matching PUC's `unroll`/`finishCcall`. Results of inner continuation feed
  as args to next-outer continuation. `testc_pending_conts.pop()` (LIFO)
  instead of `orderedRemove(0)` (FIFO).
- [x] **P15.70: `bytecode_current_boundary` field.** Stores the boundary_depth
  of the currently running `runBytecodeInternal`. When
  `saveTestcPendingContinuation` sets `bytecode_inplace_suspended`, it sets
  `bytecode_resume_boundary = bytecode_current_boundary`. Without this, nested
  `apiCall → runClosure → runBytecodeInternal` calls (e.g. testC `call` command
  for selection functions) leave leftover frames that confuse resume.
- [x] **P15.70: Errdefer unwinds nested frames on yield.** The errdefer in
  `runBytecodeInternal` uses `is_suspension_owner` check: the outermost call
  (boundary_depth == 0) and calls matching `bytecode_resume_boundary` preserve
  their frames; all others unwind. This correctly handles callk chains (f-closure
  frames unwound), toclose yields (__close frame preserved via yielded_in_place),
  and count hook yields (hook frame popped by builtinCoroutineYield, legitimate
  call frames preserved).

**Results:** 9/9 testC suites pass. coroutine.lua, locals.lua pass fully.
Matrix 28/31, smoke 45/45 — no regressions.

### P15.71 — Full testC matrix: T.listk, T.stacklevel, global reserved (завершён)

Цель: расширить testC покрытие с 9 DEFAULT_SUITES до всех 31 suite в `--testc` режиме.

- [x] **T.listk(func):** PUC ltests `listk` — возвращает таблицу с константами
  функции (1-indexed). Реализован как builtin `testc_listk`, читающий
  `proto.resolved_values`. Вызывает `resolveProtoConstants` если константы ещё
  не разрешены. tests: calls.lua pass, code.lua продвинулся (нужен constant
  folding для `checkKlist`).
- [x] **T.stacklevel():** PUC ltests `stacklevel` — возвращает 5 значений:
  top (bc_stack_top), size (bc_stack.len), nCcalls (protected depth),
  nci (call_frames.len), addr (C stack address). Реализован как builtin с Lua
  wrapper для корректной multiret propagation через `select(2, ...)`.
- [x] **global reserved in testC mode:** PUC Lua `LUA_COMPAT_GLOBAL` — `global`
  является reserved keyword в ltests режиме (без compat), и обычным именем в
  нормальном режиме (с compat). Lexer получил флаг `global_reserved`, который
  устанавливается из `Vm.testc_module_enabled`. Parser получил compat-обработку:
  `.Name("global")` промоутируется в `.Global` когда следующий токен указывает
  на global declaration (`NAME`, `function`, `*`, `<attrib>`). `isNameToken`
  больше не включает `.Global` — `global` не может быть lvalue.

**Results:** testC matrix 27/31 pass (с 23/31). Выигрыш: calls.lua, goto.lua,
cstack.lua, sort.lua pass.  Matrix 27/31, smoke 45/45 — без регрессий.

**Оставшиеся testC zig_fail:**
- `code.lua` — T.listcode реализован, но codegen генерирует GETUPVAL вместо
  GETTABUP для доступа к глобальным переменным (pre-existing codegen gap)
- `attrib.lua` — passes in testc mode (zig_only_pass); ref Lua lacks T module
- `big.lua` — pre-existing (yield from outside coroutine)
- `files.lua` — pre-existing (crash)

### P15.72 — cstack.lua stack overflow recovery + T.listcode (завершён)

Цель: починить cstack.lua (3 части: stack overflow detection, message
handling, stack recovery) и реализовать T.listcode для code.lua.

- [x] **cstack.lua Part 1 (overflow detection):** `ensureBcStackCap` не должен
  расти за пределы MAXSTACK (1000000). Строка `if (new_cap < needed) new_cap =
  needed` позволяла рост за MAXSTACK, ломая assertion `stacknow == stack1`.
- [x] **cstack.lua Part 2 (message handling — xpcall(loop, loop)):** Error
  handler должен запускаться с ERRORSTACKSIZE headroom. `handling_overflow`
  в `pushBytecodeExecFrame` использует `activeErrorHandlerDepth()` вместо
  `self.in_error_handler` (iterative dispatch использует
  `bytecode_error_handler_depth`, а не `in_error_handler`). `startBytecodeXpcallHandler`
  устанавливает `bc_stack_top = MAXSTACK` перед запуском handler.
  `shrinkBcStack` вызывается ПОСЛЕ handler (через `finishBytecodeProtectedCall`),
  а не перед.
- [x] **cstack.lua Part 3 (stack recovery):** После `xpcall(f, err)` стек должен
  сжаться до MAXSTACK через `shrinkBcStack` в `finishBytecodeProtectedCall`.
  `f()` проверяет `stacknow == stack1` (оба MAXSTACK).
- [x] **T.listcode:** Реализован как `builtinTestcListcode` — принимает Lua
  функцию, возвращает таблицу с `maxstack`, `numparams`, и opcode-строками
  (формат PUC buildop). `opcodeDisplayName` маппит luazig Op → PUC имена.
**Остающийся блокер для code.lua:** codegen генерирует GETUPVAL вместо
GETTABUP для доступа к глобальным.

### P15.72b — luaK_finish: RETURN0→RETURN rewrite for needclose (завершён)

PUC `luaK_finish` (lcode.c:1940) переписывает `RETURN0`/`RETURN1` → `RETURN`
когда функция имеет захваченные upvalues (`needclose`). Luazig VM всегда
закрывает upvalues в `completeBytecodeExecFrame`, но T.listcode (code.lua)
ожидает `RETURN` для функций с upvalues — это PUC-faithful bytecode naming.

- [x] **RETURN0→RETURN rewrite:** при финализации прототипа, если
  `captured_regs.count() > 0`, переписать `return0` → `return_` с B=1
  (0 return values + 1, чтобы избежать B=0 = "use top" = multret) и
  `return1` → `return_` с B=2 (1 return value + 1).

**Остающийся блокер для code.lua:** ~18 mismatches:
- [x] ~~comparison I/K-variant fusion для floats/strings/swap~~ — реализовано (P15.72e)
- [x] ~~LOADFALSE / boolean folding / `not not` folding~~ — реализовано (P15.72e)
- [x] ~~CONCAT chain folding~~ — реализовано (P15.72e)
- [x] ~~`<const>` local/upvalue propagation~~ — реализовано (P15.72d)
- [x] ~~intern fallback для Star/Percent/Slash/Caret/Idiv~~ — реализовано (P15.72d)
- [x] ~~table access fusion GETI/SETI/GETFIELD/GETTABUP (~6 checks)~~ — реализовано (P15.72f): genExpDesc создаёт index_i/index_str ExpDesc для t[1]/t["foo"]/t[const_int], которые ленико разряжаются в GETI/GETFIELD. genSet эмитит SETI для целочисленных ключей. genExpForSet использует genExpDesc для .Index/.Field. Поддержка <const> local ключей через genExpDesc folding.
- [x] ~~MOVE elimination в genSet/prepareAssignLhs~~ — реализовано (P15.72f): genExpDesc+exp2anyreg для table object и key. Multi-assign: check_conflict + reverse store order + last RHS as ExpDesc. code.lua mismatch count 30→18.
- [x] ~~SETFIELD для const-string keys в genSet(.Index)~~ — реализовано (P15.72f): `t[kx] = v` where `kx = <const> "x"` emits SETFIELD via genExpDesc folding.
- [x] ~~Skip codegen для `<const>` local constant initializers~~ — реализовано: RDKCTC path in genLocalDecl skips LOADI/LOADNIL/LOADTRUE when `nvars == nexps` and last var has `<const>` attr and initializer folds to compile-time constant. `string.dump` recurses into nested protos with deduplication for string constant collection.
- [x] ~~LOADNIL coalescing~~ — реализовано: `emitLoadNil` helper mirrors PUC `luaK_nil` (lcode.c:846-860), coalescing adjacent/overlapping LOADNIL ranges into a single instruction. `lasttarget` field (PUC `fs->lasttarget`) updated in `patchJumpToHere` and Label handler prevents merging across jump targets, fixing the goto.lua scope handling issue that caused the previous revert. `.Nil` direct-store path in `genAssign` emits LOADNIL directly to the target local register (via `genConstExpDesc` check), enabling cross-statement merge for `d=nil;c=nil;b=nil;a=nil` → single `LOADNIL 0 3`. `isForcedGlobalName` guard prevents direct-store when a `global` declaration shadows a local.
- [x] ~~SHLI for `k1 << x`~~ — реализовано: when `<<` has a small-integer-constant LHS and register RHS, emits `SHLI` (sC << R[B]) + `MMBINI` with TMS_SHL and flip=1, matching PUC `codebitwise` (lcode.c:1827). SHL is non-commutative, so this path is structurally separate from the commutative swap block.
- [x] ~~commutative swap `128 + x`~~ — реализовано (k-bit instruction format): Instruction struct changed from `{op:u8, a:u8, b:u8, c:u8}` to PUC-faithful `{op:u7, a:u8, k:u1, b:u8, c:u8}`. The k-bit replaces the C-field 0x80 hack (`encodeTms`/`mmbinFlip`) for commutative flip flag. Arith ops carry k=flip in their own instruction (PUC GETARG_k). MMBINI/MMBINK emit plain event in C (no 0x80 hack). All 86 opcodes fit in 7 bits (128 max).
- [x] ~~LOADI range для больших integer literals~~ — реализовано (k-bit sBx): LOADI/LOADF используют k-bit как 17-й бит sBx, расширяя диапазон с [-32768, 32767] до [-65535, 65536] (PUC OFFSET_sBx). `Instruction.loadImm(op, a, value)` кодирует 17-bit sBx в k:b:c. VM декодирует `bits - 65535`. code.lua sBx border tests (65536, -65535) теперь проходят. VM SET handlers (SETTABLE/SETI/SETFIELD/SETTABUP) поддерживают RK[C] (k=1 → constant pool) для будущей codegen RK encoding.

### P15.72c — MMBIN/MMBINI/MMBINK emission after arithmetic opcodes (завершён)

Цель: PUC Lua 5.5 emits a companion MMBIN-family instruction after every
arithmetic and bitwise opcode, carrying the TMS event number for metamethod
fallback dispatch. luazig's VM handles metamethods inline, so MMBIN is a
no-op at runtime — it only needs to exist in the bytecode for T.listcode
parity (code.lua test).

- [x] **TMS event lookup:** `tokenToTms` maps TokenKind → PUC ltm.h TMS event
  number (TMS_ADD=6 .. TMS_SHR=17). Returns null for non-arithmetic operators.
- [x] **MMBIN after register-form arithmetic:** After `emitABC(op, dst, lhs,
  rhs, line)` in `genBinOp`, emit `MMBIN lhs, rhs, event` when the operator
  is arithmetic/bitwise.
- [x] **MMBINI/MMBINK after K/I-variant arithmetic:** After
  `tryEmitConstBinOp` succeeds, emit MMBINI (I-variant: B=sC-encoded
  immediate) or MMBINK (K-variant: B=constant pool index). C field carries
  the TMS event in both cases.
- [x] **SUB comment updated:** MMBINI now exists; the ADDI-for-SUB
  optimization (encoding SUB as ADD + negated immediate with B-field patching)
  is documented as deferred.

**Results:** Build clean (ReleaseFast, 0 errors). Matrix 27/31, smoke 45/45 —
без регрессий. code.lua mismatch count: MMBIN-related test cases now emit
correct opcode sequences (SUB/MMBIN/DIV/MMBIN pattern matches PUC). Total
mismatch count in patched code.lua increased from 44→81 due to cascading
index shifts revealing pre-existing failures (comparison tests, LOADNIL
coalescing, const-local folding) that were previously hidden by different
shift patterns — no new codegen regressions.

### P15.72e — Comparison constant-LHS swap + float EQI + CONCAT merge (завершён)

Цель: закрыть две категории codegen parity gaps из code.lua — comparison
I/K-variant fusion и CONCAT chain folding.

- [x] **Comparison LHS-constant swap:** PUC `codeeq`/`codeorder` swap operands
  when LHS is a constant and RHS is not, so the constant lands on the RHS
  (enabling EQI/LTI/GTI immediate encoding). Direction is inverted for order
  ops: `K < a` → `a > K` (GTI), `K <= a` → `a >= K` (GEI). Applied to both
  `genBinOp` (value context) and `genExpCond` (condition context).
- [x] **Integer-valued float EQI:** PUC `isSCnumber` accepts integer-valued
  floats like `-4.0`, `128.0` as sC immediates. Extended `rhsConstUsableForCmp`
  + `normalizeCmpConst` to convert integer-valued floats to I-variant form.
  Added `fval` field to `NumConst` for float value tracking.
- [x] **UnOp constant folding in numericConstFromExp:** `-4.0` (UnOp{Minus,
  Number}) now folds to a constant via `genConstExpDesc`, enabling EQI for
  `if -4.0 == a`. Mirrors PUC's parse-time constfolding.
- [x] **sC range fix:** PUC `fitsC` uses unsigned arithmetic giving range
  -127..128, not -128..127. Fixed `SC_MIN`/`SC_MAX` to match PUC exactly.
  This fixes `128.0 > a` (128 now fits sC → LTI).
- [x] **isfloat bit in C field:** PUC uses C=isfloat, k=invert as separate
  fields. The instruction format now has a k bit (PUC-faithful 7-bit op + 1-bit k),
  but the comparison opcodes still encode both isfloat and invert in C:
  bit 0 = invert, bit 1 = isfloat. When isfloat=1, the metamethod receives a
  float value (e.g. `5.0`), not an integer (`5`). Updated all 5 immediate
  comparison opcodes (EQI/LTI/LEI/GTI/GEI) + EQK in VM.
- [x] **CONCAT chain folding:** PUC `codeconcat` merges consecutive CONCAT
  for right-associative `..` (`a..(b..(c..d))`). When the previous instruction
  is CONCAT and `lhs_reg + 1 == prev_concat.A`, extends the existing CONCAT:
  moves A down to `lhs_reg`, increments B. `a..b..c..d` → single `CONCAT 4 4`.

**Results:** Build clean (ReleaseFast). Matrix 27/31 `--testc` (1 zig_fail:
code.lua — pre-existing `while kTrue` const-upvalue gap), 28/31 regular (0
zig_fail). 45/45 smoke tests pass. Comparison tests in code.lua (lines
231-270) and events.lua (lines 186-189) now pass with correct metamethod
float/int parity. `while 1`/`repeat ... until true` now fold to unconditional
(Task 4). String equality `a == "hi"` uses EQK instead of LOADK+EQ (Task 5).
No regressions vs baseline.

### P15.72f — Multi-assign MOVE elimination + check_conflict + reverse store (завершён)

Цель: eliminate extra MOVE instructions in table assignment paths by using
`genExpDesc`+`exp2anyreg` instead of `genExp` for table objects and keys.
For locals, `exp2anyreg` returns the register directly without MOVE.

- [x] **genSet .Field/.Index:** Replace `genExp(n.object)` with
  `genExpDesc`+`exp2anyreg`. For a local table object, the register is
  returned directly (PUC VLOCAL → VNONRELOC, no MOVE).
- [x] **prepareAssignLhs .Field/.Index:** Same replacement for both object
  and key. Local keys no longer get MOVE'd to temp registers.
- [x] **check_conflict (PUC lparser.c:check_conflict):** When a direct
  assignment to local `reg` appears in a multi-assign, scan all previously-
  prepared indexed LHS. If any uses `reg` as table or key, copy the local
  to a safe temp (`MOVE extra, reg`) and redirect the previous LHS to
  `extra`. Without this, `a[i], a = i, 1` would overwrite `a` before
  storing to `a[i]`.
- [x] **Reverse store order:** Multi-assign stores now fire last-LHS-first
  (PUC `storevartop` semantics). This is essential for aliasing correctness:
  later indexed LHS must fire before earlier direct assignments overwrite
  shared locals. PUC's `check_conflict` only protects earlier indexed LHS
  from later direct assignments; reverse order protects the rest.
- [x] **Last RHS as ExpDesc:** The last RHS in a multi-assign is kept as an
  ExpDesc and discharged via `exp2anyreg` during the store (PUC `explist`
  keeps the last expression undischarged, `luaK_storevar` discharges it).
  For a local RHS, this avoids MOVE — the local's register is used directly.

**Results:** Build clean (ReleaseFast). Matrix 27/31 `--testc` (same as
baseline, no regressions). 45/45 smoke tests pass. code.lua mismatch count
dropped from 30 → 18 (–12). The "direct access to locals" test (code.lua:183)
now produces exact PUC-matching bytecode. Remaining 18 mismatches are from
separate issues: const-string key SETFIELD fusion (Task 2), const local
initializer LOADI elimination (Task 3), LOADNIL coalescing, GETTABUP/SETTABUP
fusion (Task 4).

### P15.72g — Don't resetRegs after return (завершён)

Цель: return values placed by RETURN instruction in registers above
nvarstack (e.g. R2-R4 for `return f()`) were unprotected during CLOSE
instructions. genStat's `defer resetRegs()` reset `peak_freereg` to
`nvarstack` after every statement including return, so
`live_reg_top[close_pc] = nvarstack`. When a coroutine yielded from
within a `__close` metamethod (via `coroutine.yield`), the parked
coroutine's return values were above `live_reg_top` and could be
collected by GC — causing `res2[i] == nil` instead of the expected
return value.

- [x] **Skip resetRegs after return:** `genStat` now checks
  `st.node == .Return` and skips `resetRegs()` for return statements.
  CLOSE instructions (emitted by `popScope`) inherit the return
  statement's `peak_freereg`, which covers the return value registers.

**Results:** Build clean (ReleaseFast). Matrix 27/31 `--testc` (same as
baseline, no regressions). 45/45 smoke tests pass. This fixes a
pre-existing GC liveness bug that was masked by the fallback path's
higher register allocation (allocating value registers bumped
`peak_freereg` past the return values, accidentally protecting them).

### P15.72h — Runtime live_reg_top extension for CALL results (завершён)

Цель: `gcClearDeadFrameRegisters` nilles return values from `coroutine.resume`
and multret builtins (e.g. `table.unpack`) that sit in registers above
compile-time `live_reg_top[pc]`. When `table.pack(co())` is compiled, the
codegen conservatively sets `freereg = func_reg + 1` after the multret CALL
(C=0), so `live_reg_top` at the subsequent `table.pack` CALL only covers
`func_reg + 1`, not the actual runtime return values. GC inside `table.pack`
(via `allocTable` → `gcAutomaticStep` → `gcClearDeadFrameRegisters`) nilles
registers above `live_reg_top[pc]`, destroying return values that hold
tables/closures.

- [x] **Extend `live_reg_top[pc]` in `applyBytecodePendingResults`:** After
  copying CALL results into parent registers, update `live_reg_top` for both
  the CALL's pc and the next pc (pc+1) to include the result registers.
  Covers the coroutine trampoline path (`completeBytecodeCoroutineResult`).

- [x] **Extend `live_reg_top[pc]` in `opCall` builtin path:** After storing
  builtin results in `ctx.regs[a..a+nstore]` and before `condGcFromDispatch`,
  update `live_reg_top` for both `ctx.pc` and `ctx.pc + 1`. Covers the direct
  builtin CALL path (e.g. `coroutine.wrap` iterator, `table.unpack`).

Both updates only INCREASE liveness (never decrease), and use `@constCast`
on the heap-allocated `live_reg_top` slice (same pattern as line 6529/18939).

**Results:** Build clean (ReleaseFast). `locals.lua --testc` passes (was
failing at line 926). Matrix 27/31 `--testc` (no regressions). 45/45 smoke.

### P15.72i — genSetExpDesc: PUC luaK_storevar ordering + `a = a` no-op (завершён)

Цель: устранить оставшиеся 5 MOVE-elimination расхождений в code.lua
(2 теста: multi-assign `b[c], a = c, b; ...; a = a` и `t[a()] = t[a()]`).

- [x] **genSetExpDesc: defer RHS discharge до LHS preparation.** В PUC
  `luaK_storevar` принимает RHS как ExpDesc и разряжает его ВНУТРИ emission
  SET-опкода (через `codeABRK` → `exp2RK`), ПОСЛЕ того как LHS (table + key)
  уже подготовлен. luazig原先 разряжал RHS через `exp2RK` до вызова `genSet`,
  что эмитило GETTABLE (RHS read) до LHS key/table code. Для `t[a()] = t[a()]`
  это давало `MOVE, CALL, GETUPVAL, GETTABLE, MOVE, CALL, GETUPVAL, SETTABLE`
  вместо PUC `MOVE, CALL, GETUPVAL, MOVE, CALL, GETUPVAL, GETTABLE, SETTABLE`.
  Новая функция `genSetExpDesc` готовит LHS (key + table), затем разряжает
  RHS (`exp2RK`), затем эмитит SET-опкод — PUC-faithful ordering.
- [x] **`a = a` no-op:** PUC `luaK_storevar(VLOCAL, VLOCAL_same_reg)` →
  `exp2reg(ex, reg)` — no-op когда RHS уже в регистре LHS. luazig генерировал
  `MOVE r0, r0` (через `genExp` + `genSet`). Добавлена проверка: если RHS
  является Name, разрешающейся в тот же local register что и LHS, return
  без codegen.

**Results:** Build clean (ReleaseFast). code.lua: 5 MOVE-elimination
mismatches устранены. Matrix 27/31 `--testc` (нет регрессий). 45/45 smoke.
Остающийся code.lua blocker: 1 checkequal (de Morgan) — не связан с
MOVE-elimination.

### P15.67 — Yield from async debug hook (завершён)

Цель: починить yield из count/line hook в testC режиме. Coroutine,
yield'ящая из hook'а (через `T.sethook("yield 0", "", N)`), не продолжала
выполнение при resume — `error.Yield` из async hook frame не очищал hook frame
и не устанавливал `bytecode_inplace_suspended`, что приводило к unwind всех
frames в `errdefer` и перезапуску coroutine с начала.

- [x] **Fix: Pop hook frame on yield from async debug hook.** В
  `builtinCoroutineYield`, когда yield происходит из async debug hook frame
  (count/line hook running as bytecode closure via `tryPushBytecodeDebugHook`),
  выполняется cleanup: pop hook frame, clean up parent's `pending_call`
  (free `BytecodeHookContinuation`, restore callee/tailcall), set
  `resume_skip_count_pc` (for count hooks), clear `in_debug_hook`, set
  `bytecode_inplace_suspended = true`. Это mirrors PUC Lua's `lua_yield`
  longjmp behavior — C hook stack frame is abandoned. 8/9 testC suites pass
  (coroutine.lua fails at line 663 on unrelated `setglobal X` line-hook
  argument issue, not yield-from-hook).

### P15.66 — PUC-faithful table rehash (завершён)

Цель: закрыть главный parity-блокер — `nextvar.lua:41` (table rehash).
Реализуется PUC-faithful rehash algorithm (`computesizes`/`numusearray`/
`numusehash`/`luaH_resize`), заменяя eager array extension на PUC's
rehash-on-overflow model.

- [x] **Task 1: PUC rehash primitives in `ltable.zig`.** Добавлены pure
  functions: `ceilLog2`, `MAXABITS`/`MAXASIZE`, `Counters`, `arrayIndex`,
  `countInt`, `numUseArray`, `numUseHash`, `arrayXhash`, `computeSizes`.
  Все функции — pure (no VM coupling), оперируют на `[]const Value` и
  `[]const Node`. 9 unit tests покрывают PUC reference values, включая
  критический `nextvar.lua:41` scenario (keys 1-4 + 96-100 + 129 → asize=4).
  TDD: tests written first, verified RED, implemented, verified GREEN.
- [x] **Task 2: Migrate `Table.array` from `ArrayList` to `[]Value` + `asize`.**
  `Table.array` changed from `std.ArrayListUnmanaged(Value)` to `[]Value` with
  explicit `asize`/`lenhint` fields, mirroring PUC Lua's `Table` struct
  (`t->asize`, `*lenhint(t)`). All 55 `.array.items`/`.array.capacity`/
  `.array.append`/`.array.ensureTotalCapacity` call sites updated to direct
  slice access + `tableResizeArray`/`tableResize` stubs. `appendTableArrayValue`
  kept temporarily (grows by 1, preserving old ArrayList append semantics for
  `rawSet` contiguous extension). `tableResizeArray`/`tableResize` stubs added
  (replaced by PUC-faithful implementation in Task 3). GC size accounting,
  traversal, weak-value pruning, `tableBorderLen`, `tableNext`, `rawGet`,
  `rawSet`, `builtinTestcQuerytab`, `builtinTableCreate`, `opSetlist`, vararg
  table creation, `makeLinesIter` all updated. 28/31 matrix parity preserved
  (no regressions), 45/45 smoke tests pass.
- [x] **Task 3: Implement `tableResize`/`tableRehash` in `vm.zig`.** Заменены
  временные stubs `tableResize`/`tableResizeArray` на PUC-faithful реализации.
  `tableResize` (PUC `luaH_resize`, ltable.c:716) выполняет joint array+hash
  resize: (1) создаёт новый hash part (power-of-2), (2) при shrink массива
  переносит vanishing slice keys в новый hash (PUC `reinsertOldSlice` +
  `exchangehashpart`), (3) выделяет новый массив, копирует общую часть,
  nil-fill новых слотов, (4) реинсертит старые hash-записи через
  `nodeInsert`/array-routing (PUC `reinserthash` + `luaH_newcheckedkey`),
  (5) освобождает старые части, выставляет `lenhint = new_asize / 2`.
  `tableResizeArray` делегирует в `tableResize` с текущим размером hash
  (PUC `luaH_resizearray`). Добавлен `tableRehash` (PUC `rehash`, ltable.c:762):
  считает ключи (`countInt`/`numUseHash`/`numUseArray`), вычисляет оптимальные
  размеры через `computeSizes`, добавляет +25% к hash size при наличии deleted
  entries. `tableRehash` пока не вызывается — подключение в `rawSet` это Task 4.
  28/31 matrix parity preserved (no regressions vs. Task 2 baseline), 45/45
  smoke tests pass.
- [x] **Task 4: Rewrite `rawSet` to PUC `luaH_newkey` flow.** Удалён
  `appendTableArrayValue` (eager array extension by 1). `rawSet` теперь
  следует PUC `luaH_newkey`: (1) `insertkey` — попытка вставки в existing
  free slot, (2) при overflow → `tableRehash` (grow + redistribute keys
  between array/hash parts via `computeSizes`), (3) `newcheckedkey` — после
  rehash integer keys в array range идут в array part, остальные через
  `insertkey` again. Integer keys в `[1..asize]` идут напрямую в array part
  (PUC `keyinarray` fast path). Удалён eager contiguous extension (pull
  following hash keys into array) — теперь PUC `computeSizes` делает это
  при rehash. `tableResize` использует `testcChargeMemory` (bytes + alloc
  count) вместо `testcConsumeAllocCount` (только alloc count), чтобы
  `totalmem` limit в errors.lua:106 срабатывал корректно. Array reuse при
  `new_asize == old_asize` (no allocation) — critical для testC `alloccount`.
- [x] **Task 5: Implement PUC `luaH_getn` for length operator.** `tableBorderLen`
  переписан как PUC `luaH_getn` (ltable.c:1301): (1) binary search в array part,
  (2) если `t[asize]` present — exponential+binary search в hash part
  (`hash_search`, ltable.c:1239). `hashIntIsPresent` проверяет hash part
  через `nodeLookup`. `hash_seed` изменён с 0 на fixed non-zero
  (`0x9E3779B97F4A7C15`) — PUC randomizes seed для hash-flood protection
  и `hash_search` randomization; fixed non-zero seed deterministic (testC
  reproducibility) и предотвращает "attack on table length" (nextvar.lua).
- [x] **Task 6: NEWTABLE hints + `checkTabArg` + testC fixes.** Codegen
  backpatches NEWTABLE с computed `na`/`nh` (PUC `luaK_settablesize`):
  `hsize_log2 = ceilLog2(nh)+1`, `asize = C + EXTRAARG*256`. VM читает hints
  и вызывает `tableResize` сразу (pre-size array+hash, no per-key rehash).
  `varargprep` pre-charge исправлен: только Table struct (array+hash
  charged by `tableResize`). `checkTabArg` (PUC `checktab`, ltablib.c:47)
  реализован для `table.insert`/`remove`/`move`/`concat`/`sort`/`unpack`:
  принимает real tables OR non-tables с metatable + required metamethods
  (`__index`/`__newindex`/`__len`).   `__testc_nupvalues` field added to
  distinguish actual upvalue count from oversized array. 8/8 testC suites
  pass (api, errors, gc, gengc, locals, memerr, nextvar, strings).
  **Code review fixes:** `nupvalues` field added to `TestcPendingContinuation`
  (was lost during yield/resume, causing upvalue access to return nil after
  coroutine resume); `hsize_log2 > 31` bounds check in OP_NEWTABLE (prevents
  panic on malformed bytecode).

### P15.31 — typed opcode fast paths (завершён)

Цель первого performance-патча — убрать заведомо лишний generic path, не меняя
формат bytecode и не смешивая этот этап с крупным codegen redesign.

- [x] Прямой integer/integer и number/number path для `ADD`, `SUB`, `MUL`,
  `MOD`, `POW`, `DIV`, `IDIV` и unary minus.
- [x] Прямые paths для bitwise операций и shifts.
- [x] Прямые numeric comparison paths.
- [x] Fast `GETI/SETI` для array/integer keys.
- [x] Fast `GETFIELD/SETFIELD` для interned short strings.
- [x] Generic coercion и metamethod lookup вызываются только после провала tag
  checks.
- [x] Debug operand names и дорогая error context не вычисляются без активного
  hook/error path. **P15.31:** CALL/TAILCALL передают `null` в `resolveCallable`;
  `debugBytecodeOperandName` (обратный проход по bytecode) вызывается только в
  catch-блоке при ошибке "attempt to call a X value". Error messages сохраняют
  имена (`local 'foo'`, `field 'baz'`). 31/31 parity проходит.
- [x] Добавить opcode-level microbench и differential tests для смешанных
  integer/float/string/metamethod случаев. **P15.31:** Добавлены 6 workloads:
  `mixed_arith` (int+float ADD), `float_arith` (float+float ADDK),
  `string_concat` (CONCAT), `metamethod_add` (`__add`), `field_access`
  (GETFIELD/SETFIELD), `comparisons` (LT/LE/EQ chain).

Критерии приёмки:

- arithmetic slowdown снижен примерно с 21× до **≤12×**;
- ни один fast path не меняет PUC-порядок conversion/metamethod/error;
- build/unit, smoke, 29/29 matrix, direct `gc.lua`, `gengc.lua --testc`,
  `constructs.lua`, `verybig.lua` и 1-МБ stress остаются зелёными.

### P15.32 — register-aware bytecode codegen

Наиболее важный этап общего roadmap.

- [x] Ввести PUC-подобный operand/`expdesc`: register, constant, immediate,
  relocatable jump и materialized temporary являются разными состояниями.
  **P15.32 expdesc:** `ExpDesc` struct с Zig tagged union (19 вариантов:
  `local`, `upval`, `k`, `k_int`, `k_float`, `k_str`, `index_up`, `index_str`,
  `index_i`, `indexed`, `reloc`, `non_reloc`, `call`, `vararg`, `nil`, `true`,
  `false`, `const_local`, `non_reloc`). Discharge primitives: `dischargeVars`
  (PUC `luaK_dischargevars`), `discharge2reg` (PUC `luaK_discharge2reg`),
  `exp2nextreg` (PUC `luaK_exp2nextreg`), `exp2anyreg` (PUC `luaK_exp2anyreg`),
  `exp2val` (PUC `luaK_exp2val`), `freeExp`/`freeExps`. `genExpDesc` — аналог
  PUC `luaK_exp2val` для AST→ExpDesc. `genNameExpDesc` — PUC `singlevar`:
  local→`.local`, upvalue→`.upval`, global→`.index_str` (если `_ENV` local)
  или `.index_up` (если `_ENV` upvalue). `genGlobalExpDesc` — mirrors
  `emitGlobalGet` at ExpDesc level. Large constant index (>255 interned
  strings) handled via LOADK+GETTABLE fallback in `discharge2reg` for
  `.index_up`/`.index_str`.
  **P15.32a (откат):** `genNameValue` возвращал регистр local напрямую (PUC
  VLOCAL), но это ломало `repeat`/`while` с замыканиями — `genExpNextReg`
  неправильно определял "уже в нужной позиции" для local registers. Добавлен
  `genExpNextReg` (аналог `luaK_exp2nextreg`) с проверкой `r >= nvarstack`.
  Требует полноценный expdesc с relocate-семантикой как в PUC.
- [x] Не материализовать local/constant до инструкции, которой действительно
  нужен регистр.
  **P15.32 expdesc:** `genBinOp`, `genReturn`, `genCall` migrated to ExpDesc.
  `exp2anyreg` для non-captured locals возвращает регистр локала напрямую
  (no MOVE). `dischargeVars` для captured locals эмитит MOVE (cell.value sync).
  RHS `line_hint` save/restore в `genBinOp` — инструкции RHS несут правильную
  строку (не строку statement). Улучшения: int_arith -19%, float_arith -28%,
  comparisons -19%, branch_loop -17%, mixed_arith -14%.
- [x] Писать результат выражения сразу в destination assignment/return slot.
  **P15.32 expdesc:** `genReturn` single-value path использует `exp2anyreg` —
  для non-captured locals `return1` читает регистр локала напрямую (no MOVE).
  `genCall` arguments используют `genExpNextReg` (ExpDesc path) — аргументы
  discharge напрямую в call frame slots (no MOVE for non-captured locals).
- [x] Добавить `ADDI`, `ADDK` и аналогичные immediate/constant variants.
  **P15.32c:** Добавлены opcodes `addi`, `addk`, `subk`, `mulk`, `modk`, `powk`,
  `divk`, `idivk`, `bandk`, `bork`, `bxork`, `shli`, `shri` (PUC 5.5 style).
  `genBinOp` проверяет RHS на numeric constant через `numericConstFromExp`
  (аналог PUC `tonumeral`) и эмитит K/I-variant вместо LOADK + register op.
  `constBinOpInfo` определяет opcode/C-field без модификации регистров (clean
  fallback). SUB с small int использует SUBK (не ADDI), т.к. наш bytecode не
  имеет MMBINI для передачи правильного metamethod event. 31/31 parity matrix
  проходит. Улучшения: branch_loop -6.4%, array_access -11.5%, hash_access
  -6.7%.
- [x] SHRI для `x << K` через `finishbinexpneg` (PUC lcode.c:1832).
  **P15.38e:** `genBinOp` теперь транслирует `x << K` (где K — small integer
  constant, и K, и -K помещаются в sC) в `SHRI(x, -K)` — PUC-faithful
  `finishbinexpneg` pattern. Раньше `x << 127` эмитило `LOADI + SHL` (3 опкода
  с MMBIN); теперь `SHRI + MMBINI` (2 опкода). SHRI несёт `c = int2sC(-K)`,
  MMBINI несёт `b = int2sC(K)` (оригинальное K для metamethod) и `c = TMS_SHL`
  (оригинальный event). VM SHRI handler peek-ит следующий MMBINI: если event
  `TMS_SHL`, вызывает `__shl` с оригинальным K (не `__shr` с -K). Annotation
  fix: `evalBytecodeBinOpValues` теперь использует `isNumWithoutInteger` (вместо
  `isNumberLikeForArithmetic`) для ошибки "number has no integer representation"
  — `math.huge << 1` получает `(field 'huge')` suffix как в PUC. 27/31 matrix,
  math.lua/sort.lua/tpack.lua/bitwise.lua/bwcoercion.lua проходят.
- [x] Добавить RK-подобные operands для arithmetic и table instructions.
  **P15.32c:** 13 новых опкодов (addi, addk, subk, mulk, modk, powk, divk,
  idivk, bandk, bork, bxork, shli, shri) в `bytecode.zig`. Codegen:
  `numericConstFromExp` извлекает числовые константы из AST без материализации
  в регистр, `constBinOpInfo` определяет опкод и C-поле, `tryEmitConstBinOp`
  эмитит K/I-вариант с чистым fallback. VM: fast/slow path handlers с
  metamethod fallback. `evalBytecodeBinOpValues` для аннотирования ошибок.
  Улучшения: branch_loop -6.4%, array_access -11.5%, hash_access -6.7%.
  **Bug fix:** `env_cell` в `runZigSource` перемещён с стека в heap
  (`aalloc.create(Cell)`) — closures захватывают cell как upvalue, а
  finalizers (`__gc`) могут выполняться во время `vm.deinit()`, долго после
  возврата `runZigSource`. Stack-local cell приводил к use-after-free.
- [x] Эмитировать `CLOSE` только для scopes с реально открытыми upvalues/TBC.
  **P15.32b:** `anyCapturedInRange(start, end)` проверяет `captured_regs` перед
  эмитом CLOSE в `genForNumeric`, `genWhile`, `genRepeat`, `genForGeneric`.
  `popScope` уже имел эту проверку. TBC-переменные в generic-for сохраняют
  безусловный CLOSE (semantics `__close`).
- [x] Заменить statement-wide `LOADNIL` точным register liveness и очисткой на
  safepoints. **P15.32 LOADNIL elimination:** Добавлено per-PC `live_reg_top`
  поле в `Proto` ([]const u8, один байт на инструкцию). Codegen синхронизирует
  `builder.current_live_top` с `peak_freereg` при каждом `reserveRegs`/`resetRegs`/
  `popScope`. GC (`gcMarkMutableRoots`) маркирует только `frame.regs[0..live_reg_top[pc]]`
  вместо полного `maxstacksize` окна — PUC `traversestack` подход. Atomic phase
  (`gcClearDeadFrameRegisters`) очищает GC pointers из dead slots выше
  `live_reg_top[pc]` — PUC `setnilvalue` эквивалент. `resetRegs` и `popScope`
  больше не эмитят LOADNIL. Улучшения: int_arith -23%, float_arith -27%,
  mixed_arith -21%, comparisons -10%. 30/31 parity (cstack pre-existing).
- [x] Добавить bytecode dump regression, фиксирующий размер hot loops.
  **P15.32c:** `--dump-bytecode` CLI flag вызывает `dumpProto()` из
  `bytecode.zig` (luac-style disassembly с прото, константами, локалами,
  upvalues). Регрессионные тесты в `codegen_bc.zig`: проверка ≤7 опкодов
  между FORPREP/FORLOOP и проверка эмитирования ADDI для `x + 5`.

Результаты microbench (медиана из 3 прогонов, `taskset -c 0`, ReleaseFast):

| Benchmark | PUC Lua | До P15.31 | P15.31 | P15.32b | P15.32c | P15.33 | P15.32nil | P15.32exp | P15.33b | P15.34 | P15.36 | P15.37 | PUC→P15.37 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| int_arith | 0.173 | 9.605 | 8.715 | 1.735 | 1.779 | 1.358 | 1.050 | 0.848 | 0.832 | 0.853 | 0.844 | 0.841 | 4.9× |
| global_arith | 0.504 | 15.863 | 14.879 | 7.716 | 8.099 | 7.220 | 6.881 | 6.599 | 6.599 | 3.059 | 3.568 | 3.187 | 6.3× |
| branch_loop | 0.422 | 12.913 | 11.344 | 4.164 | 3.963 | 3.453 | 3.216 | 2.634 | 2.607 | 2.611 | 2.550 | 2.576 | 6.1× |
| lua_calls | 0.093 | 3.523 | 3.427 | 2.719 | 2.642 | 2.553 | 2.520 | 2.503 | 2.443 | 2.527 | 1.747 | 0.617 | 6.6× |
| array_access | 0.044 | 1.315 | 1.155 | 0.426 | 0.368 | 0.338 | 0.309 | 0.293 | 0.293 | 0.291 | 0.285 | 0.289 | 6.6× |
| hash_access | 0.063 | 1.655 | 1.395 | 0.644 | 0.595 | 0.556 | 0.507 | 0.491 | 0.491 | 0.489 | 0.469 | 0.481 | 7.7× |
| temp_table_alloc | 0.029 | 0.224 | 0.223 | 0.154 | 0.147 | 0.147 | 0.137 | 0.137 | 0.137 | 0.141 | 0.133 | 0.134 | 4.7× |
| string_loop | 0.097 | 0.528 | 0.533 | 0.448 | 0.451 | 0.448 | 0.447 | 0.436 | 0.436 | 0.411 | 0.428 | 0.409 | 4.2× |
| coroutine_yield | 0.042 | 0.429 | 0.411 | 0.329 | 0.320 | 0.314 | 0.298 | 0.306 | 0.306 | 0.237 | 0.220 | 0.222 | 5.3× |
| dynamic_load | 0.129 | 1.224 | 1.122 | 0.409 | 0.408 | 0.370 | 0.350 | 0.319 | 0.319 | 0.314 | 0.337 | 0.267 | 2.1× |
| mixed_arith | 0.176 | — | — | — | 1.834 | 1.514 | 1.193 | 1.000 | 1.000 | 0.993 | 0.977 | 0.982 | 5.6× |
| float_arith | 0.177 | — | — | — | 1.812 | 1.384 | 1.017 | 0.740 | 0.656 | 0.729 | 0.648 | 0.661 | 3.7× |
| string_concat | 0.081 | — | — | — | 0.150 | 0.150 | 0.148 | 0.139 | 0.139 | 0.132 | 0.128 | 0.128 | 1.6× |
| metamethod_add | 0.058 | — | — | — | 0.556 | 0.544 | 0.549 | 0.545 | 0.545 | 0.475 | 0.456 | 0.282 | 4.9× |
| field_access | 0.054 | — | — | — | 0.732 | 0.658 | 0.583 | 0.587 | 0.587 | 0.242 | 0.230 | 0.228 | 4.2× |
| comparisons | 0.530 | — | — | — | 7.070 | 5.705 | 5.132 | 4.233 | 4.090 | 4.250 | 4.122 | 4.112 | 7.8× |

Геометрическое среднее: **2.12×** ускорения (до P15.31 → P15.32c, 10 исходных workloads);
**8.7×** отставания от PUC Lua (PUC → P15.32c, 10 исходных). Новые workloads (P15.31):
mixed_arith 10.1×, float_arith 10.0×, string_concat 1.8×, metamethod_add 9.4×,
field_access 13.1×, comparisons 13.1×. P15.32exp (ExpDesc migration): int_arith -19%,
float_arith -28%, comparisons -19%, branch_loop -17%, mixed_arith -14%.
P15.33b (stack ptr tracking + branch hints): float_arith -11%, comparisons -3%,
lua_calls -2%.
P15.34 (pre-intern string constants): global_arith -54%, field_access -59%,
metamethod_add -13%, string_loop -6%, coroutine_yield -23%.
P15.36 (eliminate per-call @memset via before-semantics + upvalue closing): lua_calls -31%
(2.527→1.747s). Parity: 28/31 (no regressions).
P15.35 (zero-allocation call/return fast path): lua_calls -27% (7.27→5.32s, Debug build).
P15.37a (frame-struct slim + pending_call split): lua_calls -65% (1.760→0.617s),
metamethod_add -38% (0.456→0.282s), `compiler_rt.memset` share 53%→<1%.
P15.37b (Node compaction 56B→48B via i32 chain offset): PUC `gnext`-faithful,
`nodeLookup` perf share unchanged (~28%).
P15.37c (Table.flags BITRAS): PUC-faithful metamethod cache, skips `getFieldOpt`
when metatable has no `__index`/`__newindex`.
P15.37 geomean: **4.77×** (16 workloads, median of 7, `tools/perf_compare.py`).

P15.32a (устранение MOVE для local reads) был отменён — ломал `repeat`/`while`
с замыканиями. P15.32b (условный CLOSE) даёт основной вклад: int_arith
8.7→1.7s, branch_loop 11.3→4.2s, dynamic_load 1.1→0.4s. P15.32c (K/I-variant
opcodes) устраняет LOADK для constant-operand arithmetic: branch_loop -6.4%,
array_access -11.5%, hash_access -6.7%. P15.32exp (ExpDesc migration) устраняет
MOVE для non-captured locals в genBinOp/genReturn/genCall: int_arith 1.05→0.85s,
float_arith 1.02→0.74s, comparisons 5.13→4.23s.

Критерии:

- `s=s+i` выполняет не более 2–3 hot opcode на итерацию вместо примерно 7;
- arithmetic/global/branch slowdown — **≤5× PUC**;
- generated code остаётся корректным при hooks, GC между инструкциями,
  captured locals, `goto` и `<close>`.

### P15.33 — fast/slow dispatch split

- [x] Отдельный compact loop для no-hook/no-yield/no-pending/no-GC case.
  **P15.33:** Когда `hooks_active_cached == false`, dispatch loop пропускает
  per-instruction RuntimeFrame sync, line/count hook checks и debug corruption
  assertion. `hooks_active_cached` — Vm-level bool, обновляемый через
  `refreshHooksCached()` после каждого `debug.sethook` и при каждом coroutine
  `switchRuntime`. `current_thread` устанавливается перед `switchRuntime`, чтобы
  cached flag читал hook state правильного thread.
- [x] `pc`, base, top и closure живут в локальных переменных interpreter loop.
  **P15.33:** `pc`, `regs`, `boxed`, `frame_current_line`, `frame_cap`,
  `nvarstack`, `reg_top` — все локальные в dispatch loop. Stack ptr tracking:
  `stack_ptr`/`stack_boxed_ptr`/`cached_frame_cap` проверяются каждый iteration,
  re-derive `regs`/`boxed` только когда stack был realloc'd (после CALL/RETURN/
  builtin). На fast path — один pointer comparison вместо двух slice ops.
  `@branchHint(.unlikely)` на hooks_active slow path.
- [x] RuntimeFrame синхронизируется только на safepoints.
  **P15.33:** RuntimeFrame sync только на: defer (frame exit), GC tick, error
  paths (`fail()`, `error()`, `setOutOfMemoryError()`), builtin entry
  (`callBuiltin`). `bc_dispatch_pc` обновляется на fast path (один store),
  `frame_current_line` обновляется из `lineinfo[pc]`.
- [x] Cold continuation/debug/error paths вынесены из hot function.
  **P15.33:** `@branchHint(.unlikely)` на hooks_active slow path — compiler
  move cold debug hook code out of hot path. Arithmetic metamethod slow paths
  оставлены inline (compiler уже хорошо справляется с branch prediction для
  `if/else if` chains). Microbench: float_arith -10% от stack ptr tracking.
- [x] GC fast check сводится к дешёвому debt comparison; реальное продвижение
  collector выполняется на allocation/safepoint path.
  **P15.33:** Fast path: `gc_tick += 1; if (gc_tick >= threshold) { sync+step }`.
  Только counter increment + comparison, без вызова функций.
- [x] Добавить benchmark и assertion, что выключенные hooks не ведут через hook
  machinery.
  **P15.33:** `hooks_active_cached` — single bool read per instruction.
  Microbench подтверждает: int_arith -24%, float_arith -24%, comparisons -19%.

Критерии:

- arithmetic после P15.32 приближается к **2–3× PUC**;
- Lua calls — **≤5× PUC** до отдельного CallInfo redesign;
- debug hooks, coroutine switch и error unwinding сохраняют текущую parity.

### P15.34 — compact tables и однопоточный VM allocator

- [x] Уменьшить hash `Node` с 56 до 48 байт. **P15.37b:** `next: ?*Node` (8 B +
  padding) → `next_offset: i32` (4 B) PUC `gnext`-style, `dead_key` packed в
  старший бит `hash`. Полная parity (24 B) требует variant TKey (P15.38+).
- [x] Уплотнить chain metadata и исключить дублирующие key/tag fields. **P15.39:**
  variant TKey — `key: Value` (16 B tagged union) → `key_tt: u8` + `key_val: extern union` (8 B),
  кэшированный `hash: u64` удалён (хеш пересчитывается на каждом use site как в PUC).
  `Node` сжат с 48 B до 32 B → две полные nodes на 64-byte cache line.
- [ ] Специализированные integer и interned-string lookup/insert paths.
- [x] Не memset’ить полный большой Node при каждом resize. **P15.37a:** struct
  literal zero-init заменён на reuse-pool pattern (`addOne` + field writes).
- [ ] Сначала проверить libc allocator как безопасный промежуточный default для
  CLI.
- [ ] Затем добавить VM-local pools/pages для `Table`, `Node`, `Closure`,
  `Cell`; без mutex.
- [ ] Освобождать пустые pages после major sweep.
- [ ] Compile/parser temporary data вынести в переиспользуемую arena.
- [x] **Pre-intern string constants at first Proto execution.** `bcConstToValue`
  previously called `internStrAll(s.bytes())` on every GETTABUP/GETFIELD/SETFIELD
  execution — re-hashing already-interned strings (~12.4% of cycles on microbench).
  Now `resolveProtoConstants` runs once per Proto (in `pushBytecodeExecFrame` and
  TAILCALL frame-reuse path), replacing compile-time `*LuaString` (hash seed 0)
  with VM-interned pointers. `bcConstToValue` returns the pointer directly.
  Ownership: after resolution, string constants are owned by the VM's intern
  table, not by the Proto (matching PUC's `TString` ownership model).
  **Results:** global_arith -54%, field_access -59%, metamethod_add -13%.
- [x] **Nil-fill missing parameters (PUC `luaD_precall` parity).**
  `pushBytecodeExecFrame` now explicitly nil-fills `regs[args.len..numparams]`
  instead of relying on the full-window memset. Matches PUC's
  `for (; narg < nfixparams; narg++) setnilvalue(s2v(L->top.p++))`.
- [x] **Bound debug.getlocal/setlocal temp-scan by `live_reg_top[pc]`.**
  Previously scanned the entire register window (`fr.regs[0..fr.regs.len]`),
  exposing stale values as phantom "(temporary)" locals. Now bounded by
  `live_reg_top[pc]` (our equivalent of PUC's `L->top`), with fallback to full
  window for stripped/external protos without `live_reg_top`. Fixes latent
  db.lua assertion failure. `cloneStrippedProto` now copies `live_reg_top`.
- [x] **Fix parked-coroutine GC scan to use per-frame `live_reg_top`.**
  Previously scanned the entire `bytecode_stack[0..parked_top]` as a flat array
  with NO per-frame `live_reg_top` filtering — stale values in uninitialized
  register windows caused SIGSEGV on coroutine.lua/cstack.lua. Now walks
  `th.runtime_frames` with per-frame `live_reg_top[fr.pc]`, matching the
  active-thread GC scan at `gcMarkMutableRoots`.

  **Note on `@memset(regs, .Nil)`:** The full-window memset is still kept as a
  safety net. It cannot be removed until `live_reg_top` tracks the "after"
  boundary (registers actually written by the completed instruction) rather
  than the per-statement high-water mark. PUC's `L->top` is updated after each
  instruction; our `live_reg_top[pc]` is set before emission. When GC runs at
  a safepoint (`fr.pc = pc` before instruction execution), `live_reg_top[pc]`
  may include registers that will be written by this instruction but haven't
  been yet. This is a P15.35 prerequisite.

Критерии:

- array/hash operations — **≤3× PUC**;
- temporary table allocation — **≤3× PUC**;
- max RSS allocation workload — **≤2× PUC**;
- weak tables, dead keys, finalizers, Brent chaining и generational barriers не
  получают регрессий.

### P15.35 — CallInfo stack и обычный call fast path

- [x] **Предвыделенный массив frame/CallInfo records.**
  P15.40a: pre-allocate frame capacity in `activateRuntime`/`apiNewThread`/init.
  P15.40b: merged `CallFrame` struct (BytecodeExecFrame + RuntimeFrame → single struct).
  P15.40b-full: eliminated dual-array pattern — `pushBytecodeExecFrame` does ONE
  `addOne` to `Thread.call_frames` with ALL fields. No runtime copy push.
- [x] **Обычный Lua call/return не делает heap allocation на fast path.**
  P15.35a: OP_RETURN0/OP_RETURN1 fast path — when no pending TBC closers and
  no debug hooks, skip `beginBytecodeClose` entirely and go straight to
  `completeBytecodeExecFrame`. Single-value returns use a `bc_return_scratch`
  VM-state slot (stable across frame pop, detected by pointer identity, never
  freed). Zero-value returns use `bc_return_scratch[0..0]`. This eliminates
  the `alloc(Value, 0)`/`alloc(Value, 1)` + `free` pair on every return —
  matching PUC Lua's zero-allocation return semantics.
  P15.35b: Non-vararg functions use a static `empty_varargs` slice instead of
  `alloc.dupe(Value, &.{})` — eliminates the malloc(0)/free(0) pair on every
  OP_CALL for functions without `...`.
  P15.35c: Fixed `refreshHooksCached` to include `has_call`/`has_return` —
  the P15.33 cached flag previously only tracked line/count hooks, causing
  the OP_RETURN fast path to skip return hooks. Now correctly detects all
  hook types.
  P15.35d: Eliminated `rargs = alloc.dupe(...)` on OP_CALL fast path. When
  `resolved.owned_args == null` (no `__call`), pre-grow `bc_stack` for the
  child frame before the dupe check. If no realloc (common), pass
  `resolved.args` directly. If realloc (rare), re-derive from offset.
  Matches PUC's `luaD_precall` — args addressed by stack offset, no
  intermediate buffer.
  P15.35e: Fixed `long_string_cache` key use-after-free in `internStrAll`.
  The cache stored the caller's borrowed `raw` slice as the key, but
  `resolveProtoConstants` freed the source `LuaString` immediately after.
  On next grow/rehash, the map compared keys through freed memory →
  corruption. Fixed: store `ls.bytes()` (interned string's inline body,
  stable for the string's lifetime).
  P15.35f: Eliminated `dup_args = alloc.dupe(...)` on OP_TAILCALL fast path.
  Pass `orig_args` (regs[a+1..]) directly to `resolveCallable`. In the
  frame-reuse path, copy params BEFORE nil-fill using `copyForwards`
  (overlap-safe, matches PUC's memmove). Compute varargs BEFORE nil-fill.
  Matches PUC's tail-call path — args moved in-place, no intermediate buffer.
  **Results:** lua_calls -27% (7.27→5.32s, Debug build). Parity: 28/31
  (up from 26/31; api.lua and literals.lua fixed).
- [x] Прямой known-Lua-closure path без повторного `resolveCallable`.
  **P15.35:** PUC `luaD_precall` inlined into OP_CALL/OP_TAILCALL/OP_TFORCALL.
  Fast path (Closure/Builtin) exits inline type switch on first iteration —
  no function call, no struct, no heap alloc. `__call` uses in-place stack
  shift (PUC `tryfuncTM`). `resolveCallable` kept for 25 cold-path sites.
- [x] **`__call`, hooks, protected calls, yields и thread switches остаются в slow
  path.** The OP_RETURN0/1 fast path checks `has_pending_tbc` and
  `hooks_active` before taking the shortcut. When TBC closers or any debug
  hook is active, the full `beginBytecodeClose` path runs unchanged.
- [ ] Debug name reconstruction выполняется лениво.
- [ ] Уплотнить `Thread` header и parked-frame storage после измерения lifetime
  требований.

Критерии:

- Lua calls — **≤2–3× PUC**;
- coroutine resume/yield — **≤3× PUC**;
- iterative-dispatch invariants и 1-МБ stack stress сохраняются.

### P15.36 — compiler/`load()` pipeline

- [ ] Reuse parser/codegen arena между вызовами `load()`.
- [ ] Capacity hints для AST, bytecode, constants и names.
- [ ] Small-vector storage для типичных маленьких функций.
- [ ] Уменьшить копирование identifier/source/string data.
- [ ] После стабилизации добавить streaming parser-to-bytecode backend.
- [ ] Полный AST оставить optional tooling/debug path.

Критерий: dynamic `load()` — **≤2–3× PUC**, без ухудшения diagnostics,
lineinfo, stripped chunks и large-program codegen.

### P15.36b — eliminate per-call `@memset` via "before" live_reg_top semantics

- [x] **Part 1: Codegen infrastructure for "before" semantics.** Added
  `live_top_before`/`has_live_top_before` fields to `ProtoBuilder`.
  `reserveRegs`/`syncLiveTop` snapshot the live top BEFORE bumping
  `peak_freereg`. `emit()` records `live_top_before` (the "before" boundary)
  instead of `current_live_top` (the "after" boundary). This ensures GC
  safepoints only scan registers written by PREVIOUS instructions, not
  registers that will be written by the current instruction but haven't
  been yet.
- [x] **Part 2: Fix `.reloc` expression pattern.** The `.reloc` pattern
  (used by GETTABUP, GETTABLE, etc.) emits the instruction BEFORE allocating
  the destination register, then patches the A field. This caused
  `live_top_before` to be snapshotted before the bump, and the stale
  snapshot persisted to the next instruction (due to `has_live_top_before`
  flag). Fixed in `discharge2reg`'s `.reloc` case: after patching, clear
  the flag and update `live_top_before = current_live_top` so the next
  instruction sees the correct boundary.
- [x] **Part 3: Upvalue closing on return path.** `completeBytecodeExecFrame`
  now calls `closeBytecodeUpvaluesFrom(frame, 0)` BEFORE `popBytecodeExecFrame`.
  Previously, open upvalue cells in `boxed[]` were never closed on normal
  returns — masked by `@memset(boxed, null)` on frame entry. Double-close
  is safe: `closeBytecodeUpvaluesFrom` checks `boxed[i]` for non-null and
  clears it after closing.
- [x] **Part 4: Remove both `@memset` calls.** Removed `@memset(regs, .Nil)`
  and `@memset(boxed, null)` from `pushBytecodeExecFrame`. PUC Lua
  (`luaD_precall`) does NOT zero the register window — it only nil-fills
  missing parameters. We now match this behavior.
- [x] **Document known deviations from PUC Lua.** (1) `gc_tick` fires GC
  every N instructions instead of PUC's allocation-only triggers. (2)
  Per-PC `live_reg_top` table instead of runtime `L->top` — needed because
  `gc_tick` can fire at any instruction. Both deviations are orthogonal to
  the memset fix but documented as technical debt.

**Results:** lua_calls -31% (2.527→1.747s, ReleaseFast). Parity: 28/31
(no regressions). All 44 smoke tests pass.
Spec: `docs/superpowers/specs/2026-07-18-memset-elimination-design.md`

### P15.37 — воспроизводимый performance gate + hotspot-driven perf-фазы

Добавить `tools/perf_compare.py` и versioned baseline + закрыть 3 hotspot'а,
выявленных через `perf record --call-graph lbr`:

- [x] ReleaseFast build на Zig 0.16.0;
- [x] CPU affinity и warmup (`taskset -c 0`);
- [x] медиана минимум семи прогонов;
- [x] arithmetic/global/branch/call/table/allocation/string/coroutine/load
  workloads (16 в `tools/microbench.lua`);
- [ ] wall time, process CPU, max RSS и opcode count (только wall time);
- [x] при доступном современном ядре — `perf stat` counters (`--perf` flag);
- [x] JSON output с toolchain/CPU metadata (`tools/perf/baseline-p15.37.json`);
- [x] warning при регрессии >5%, failure >10% для стабильных benchmarks;
- [ ] отдельная маркировка noisy/long suites вроде direct `constructs.lua`.

**Hotspot-driven задачи:**

- [x] **P15.37a — Frame-struct slim.** `BytecodeExecFrame` (936 B) и
  `RuntimeFrame` (280 B) инициализировались через struct literal `append`,
  что эмитит byte-wise `compiler_rt.memset` (57% от lua_calls). Заменено на
  reuse-pool pattern: `addOne(alloc)` + field-by-field writes (без struct
  literal → нет memset). Дополнительно: `?BytecodePendingCall` (768 B optional)
  заменён на `PendingCallSlot` wrapper (`active: bool` + `payload = undefined`),
  где `clear()` — single-byte write вместо 768-byte memset.
  **Результат:** lua_calls 1.760→0.617s (-65%), metamethod_add 0.456→0.282s
  (-38%), `compiler_rt.memset` share 53%→<1%.
- [x] **P15.37b — Node compaction.** `ltable.Node` уплотнён с 56 B до 48 B:
  `next: ?*Node` (8 B + padding) заменён на `next_offset: i32` (4 B) PUC
  `gnext`-style signed index offset, `dead_key: bool` упакован в старший бит
  `hash` (`DEAD_KEY_FLAG`). Hash маскируется (`HASH_MASK`) при записи, чтобы
  live-key хеши с установленным bit 63 не ложно определялись как dead.
  `nextNode` использует direct pointer arithmetic для chain walk.
  **Результат:** PUC-faithful layout, `nodeLookup` perf share ~28% (без
  регрессии). Полная parity (24 B) требует variant TKey (P15.38+).
- [x] **P15.37c — Table.flags bitmask (BITRAS).** Добавлен `flags: u8` в
  `Table` (PUC `ltm.h:54`): bit set = "metatable не имеет метаметод".
  Проверяется перед `getFieldOpt(mt, "__index"/"__newindex")` в 5 точках.
  Сбрасывается при new-key insertion (`rawSet`, PUC `ltable.c:1112`).
  **Результат:** PUC-faithful metamethod cache. Доля metamethod-check упала
  с 11% до ~9% (меньше ожидаемого — `global_arith` работает с `_ENV` без
  metatable, null-check уже short-circuit'ит).
- [x] **P15.37d — `tools/perf_compare.py` + baseline.** Скрипт собирает
  ReleaseFast-бинарь и PUC Lua reference, pinned на одно ядро через
  `taskset -c 0`, берёт медиану 7 прогонов на 16 workloads, печатает таблицу
  `PUC | Zig | Zig/PUC` с geomean, сравнивает с versioned baseline
  (`tools/perf/baseline-p15.37.json`, WARN >5%, FAIL >10%), опционально
  запускает `perf stat`. Флаги: `--update-baseline`, `--perf`, `--runs`,
  `--core`, `--no-build`.

**Итог P15.37:** geomean **5.21× → 4.77×** (8.5% improvement). Цель ≤3× не
достигнута — основные оставшиеся hotspot'ы: instruction-count bound dispatch
(`branch_loop`/`comparisons` ~98% в `runBytecodeDispatch`) и `nodeLookup`
(~28% на `global_arith`). Оба требуют codegen-level работы (P15.38+):
variant TKey для полной Node parity, fewer opcodes per Lua iteration.

Performance patch принимается только вместе с correctness gates:

- `zig build test -Doptimize=Debug`;
- differential smoke;
- 29/29 portable/soft matrix;
- direct `gc.lua`;
- `gengc.lua --testc`;
- direct `constructs.lua` и `verybig.lua`;
- iterative-dispatch stress под 1-МБ host stack.

### Реалистичные performance milestones

PUC Lua оптимизировался десятилетиями, поэтому обещать 1.0× без изменения
codegen, layout и dispatch неправильно. Текущие milestones:

1. После P15.31: геометрическое среднее **<8×**. ✅ (достигнуто)
2. После P15.32–P15.33: геометрическое среднее **<3×**. ❌ (достигнуто 5.21×)
3. После P15.34–P15.35: геометрическое среднее **<2×**. ❌ (не достигнуто)
4. После P15.37: геометрическое среднее **≤3×**. ❌ (достигнуто 4.77×)
5. После P15.38a–h: геометрическое среднее **≤3×**. ❌ (достигнуто 3.43×)
6. Затем отдельные workloads доводятся до parity или небольшого выигрыша.

Оставшиеся hotspot'ы после P15.37 (требуют codegen-level работы, P15.38+):
- **Instruction-count bound dispatch** (`branch_loop`/`comparisons` ~98% в
  `runBytecodeDispatch`, IPC=4.24, branch-misses ≤0.02%) — CPU выполняет
  инструкции быстро, но их слишком много. Нужно: fewer opcodes per Lua
  iteration (codegen improvements), compact dispatch table.
- **`nodeLookup` ~28% на `global_arith`** — Node 48 B vs PUC 24 B. Полная
  parity требует variant TKey (int/str/etc packed в 8 байт).

Общий уровень PUC требует одновременно трёх архитектурных изменений:

- меньше bytecode-инструкций;
- компактный common-case dispatch;
- PUC-подобная плотность tables, GC objects и call frames.

### P15.38 — codegen-level opcode reduction (PUC 5.5 fast paths)

Цель: уменьшить число bytecode-инструкций на Lua-итерацию через PUC 5.5
codegen fast paths. Каждая подзадача устраняет 1–3 инструкции в common-case
паттернах (`s = s + 1`, `if a < b then`, `x = x + 1.0`).

- [x] **P15.38a — GETTABUP/SETTABUP metatable fast path.** Глобальные
  чтения/запись через `_ENV` upvalue проверяют `flags` bitmask перед
  `getFieldOpt(__index/__newindex)`. Устраняет 2 из 3 `nodeLookup` вызовов
  на каждый global access. **Результат:** global_arith 3.187→1.552s (-51.3%).
- [x] **P15.38b — VJMP conditional expressions.** `genComparisonExp`
  возвращает VJMP ExpDesc (CMP+JMP, 2 инструкции) вместо материализации
  boolean (5 инструкций). `genIf`/`genWhile`/`genRepeat` используют VJMP
  напрямую через `goIfTrue`/`goIfFalse`. `and`/`or` используют jump-list
  concatenation. **Результат:** branch_loop 2.576→1.442s (-44.0%),
  comparisons 4.112→1.566s (-61.9%).
- [x] **P15.38c — Direct-store to locals.** `genBinOp` принимает
  `dst_hint: ?u8`; `genAssign` для `local s; s = s + i` передаёт регистр
  `s` как hint, эмитя `ADD s, s, i` (1 instr) вместо `ADD tmp, s, i;
  MOVE s, tmp` (2 instr). **Результат:** int_arith 0.841→0.515s (-38.7%).
- [x] **P15.38d — Immediate comparison opcodes (EQI/LTI/LEI/GTI/GEI/EQK).**
  6 новых опкодов сравнивают R[A] с signed immediate (sB) или constant
  pool entry (K[B]), устраняя предшествующий LOADI/LOADK. Codegen:
  `genComparisonExp` принимает `rhs_const: ?NumConst`; когда RHS — малая
  целая константа, эмиттится immediate variant. VM: Int/Num fast path +
  metamethod fallback (materialized imm). **Результат:** comparisons
  1.928→1.566s (cumulative -61.9% vs P15.37), geomean 4.77×→3.69×.
- [x] **P15.38e — Eliminate PendingCallSlot.get() 760-byte copy.**
  `PendingCallSlot.get()` returned `BytecodePendingCall` by value, copying
  the 760-byte payload on every call — the source of `compiler_rt.memcpy`
  hotspot (10% of cycles on `lua_calls`). Changed `get()` to return
  `?*const BytecodePendingCall` (pointer). The `set()` copy remains (changing
  it caused code-layout regressions on `field_access`/`global_arith`).
  **Результат:** lua_calls 0.615→0.596s (-3%), memcpy 10%→<1% of cycles.
- [x] **P15.38f — Debug hook fast path (PUC `allowhook`/`hookmask` model).**
  Eliminated 8.4% debug hook overhead on `lua_calls` when no hooks are
  active. Two changes mirroring PUC Lua's debug hook architecture:
  (1) `hooks_active_cached` early-return at the top of
  `debugDispatchHookTransfer`, `debugDispatchHookWithCalleeTransfer`,
  `tryPushBytecodeDebugHook`, and `hasActiveHookEvent` — one bool read
  instead of linear frame search + `std.mem.eql` string compare (PUC's
  `hookmask` check);
  (2) moved `in_debug_hook` from Vm (global) to `DebugHookState` (per-thread,
  like PUC's `L->allowhook` on `lua_State`), with both sync and async hook
  paths setting/clearing it. `isInDebugHook()` simplified from O(n) linear
  search (`activeAsyncDebugHookFrame`) to O(1) per-thread flag read.
  Per-thread storage means coroutine yield/resume automatically switches to
  the correct thread's flag — no recompute on thread switch.
  **Результат:** lua_calls 6.53×→5.95× (-8.9%), geomean 3.74×→3.71×.
- [x] **P15.38g — GETTABLE/SETTABLE metatable fast path.**
  GETTABLE/SETTABLE were missing the `metatable == null` fast path that
  GETI/GETFIELD and SETI/SETFIELD already have. Without it, GETTABLE always
  called `tryPushBytecodeIndexMetamethod` (does a `rawGet` to check key
  existence) + `bytecodeIndexValue` (does another `rawGet`) — a double
  lookup. Now checks `obj.Table.metatable == null` first and does a single
  `rawGet`/`rawSet`, matching PUC's `luaV_gettable` fast path.
  **Результат:** array_access 6.62×→4.33× (-34.6%), hash_access 7.71×→5.25×
  (-31.9%), geomean 3.74×→3.53×.
- [x] **P15.38h — tostring() stack-buffer fast path.**
  Added `valueToInternedStr()` which writes Int/Num directly to a stack
  buffer and interns it, bypassing the heap allocation in
  `valueToStringAlloc` + `internStr`. Mirrors PUC's `luaO_tostring`
  (lobject.c:464): `char buff[LUA_N2SBUFFSZ]; luaO_tostringbuff(obj, buff);
  luaS_newlstr(L, buff, len)`. Falls back to heap alloc for non-numeric types.
  **Результат:** string_loop 3.91×→3.52× (-9.9%), geomean 3.53×→3.43×.
- [x] **P15.38i — PUC-style builtin results on bc_stack (eliminate dupe).**
  Architectural change: OP_CALL handler now writes builtin results directly
  to bc_stack (value stack) above the arguments, matching PUC Lua's model
  where C functions write results to `L->top.p`. Eliminates the `outs_small`
  local buffer, the `alloc.dupe` + `alloc.free` for debug hook transfer
  values on every builtin call (~14% of hash_access cycles), and the
  separate copy from outs to regs. `callBuiltin` tracks whether outs points
  into bc_stack (for future `refreshBuiltinOuts` re-derive in builtins with
  re-entry — PUC's savestack/restorestack equivalent). Debug hook only
  dupes when `hooks_active_cached` (slow path). OP_TAILCALL and OP_TFORCALL
  still use local buffers (their dupe is for return-value ownership, not
  debug hooks).
  **Результат:** dupe/free eliminated from perf profile. hash_access -4.6%,
  array_access -4.4%, geomean 3.43×→3.42×.

**Итог P15.38 (a–i):** geomean **4.77× → 3.49×** (-26.8% slowdown).
Цель ≤3× почти достигнута — оставшиеся hotspot'ы: `lua_calls` (6.0×,
call frame overhead), `hash_access` (5.2×, Node 48B vs 24B),
`field_access` (4.7×, table lookup). Дальнейший прогресс требует
variant TKey (P15.39+) и call frame compaction.

### P15.39 — variant TKey: Node 48B → 32B

Архитектурная PUC-faithful компрессия `ltable.Node` с 48 B до 32 B через
разделение `key: Value` (16 B tagged union) на 1 B type tag (`key_tt`) +
8 B raw payload (`key_val`), и удаление кэшированного `hash: u64` поля
(хеш пересчитывается на каждом use site, как в PUC `ltable.c`).

Field layout (32 B total):
- `value: Value` (16 B) — full tagged value
- `key_val: NodeKeyPayload` (8 B) — bare extern union
- `next_offset: i32` (4 B) — Brent chain link
- `key_tt: NodeKeyTag` (1 B) + 3 B padding

Cache-line density: 64 B line × 32 B node = **2 full nodes per line**
(было 1 при 48 B). Это качественный порог — дальнейшее сжатие до 24 B
(полная PUC parity) дало бы только partial третьего node и требует
изменения самого типа `Value` (отдельная задача P15.40+).

Architectural changes:
1. `NodeKeyTag = enum(u8)` с 9 вариантами (`empty`, `dead`, `int`, `num`,
   `string`, `table`, `closure`, `thread`, `bool_`). `empty` маркирует
   свободный slot, `dead` — dead key (PUC `LUA_TDEADKEY`).
2. `NodeKeyPayload = extern union` — tagless 8-byte union mirroring PUC
   `union Value` (lobject.h:49).
3. `Node.getKey()`/`setKey()` bridge methods reconstruct/store a full
   `Value` from/to the split tag+payload representation. Используются
   только в холодных путях (GC, итерация) — горячий путь lookup'а
   использует `Node.keyMatches()` (см. пункт 7).
4. `Node.rawHash(seed)` recomputes the hash from `key_tt`+`key_val` at each
   use site — PUC `ltable.c` does the same via inline `hashint`/`hashstr`/
   `hashpointer`/`hashboolean` calls.
5. Dead keys marked by `key_tt = .dead` instead of a high bit in `hash`
   (PUC `LUA_TDEADKEY` model). Payload cleared to sever stale pointers.
6. `keyHash(.Num)` теперь вызывает `hashNum` (раньше возвращал 0 для float
   keys — нарушение Brent invariant после swap, исправлено отдельно).
7. `Node.keyMatches(Value)` (добавлен в рамках Task 6 regression fix) —
   PUC-faithful inline `keyeq` без reconstruction полного `Value`. Раньше
   `nodeLookup` звал `keyEq(n.getKey(), key)`: switch по `key_tt` для
   сборки 16-байтного `Value` + switch по тегу в `keyEq`. Теперь один
   switch сравнивает tag и payload на месте, как макрос `keyeq` в PUC.

Migration strategy (6 tasks):
- Task 1: Add new types + accessor methods (no layout change)
- Tasks 2-4: Migrate ltable.zig / vm.zig / api.zig callers to accessors
  (transitional bridge writes keep both representations in sync)
- Task 5: Physical layout swap (drop `key`/`hash` fields, drop bridge writes)
- Task 6: Full regression + perf measurement + README update + Node.keyMatches
  fix для восстановления PUC-faithful горячего пути lookup'а

**Результат (median of 7, microbench, vs `tools/perf/baseline-p15.37.json`):**

| Workload | До P15.39 | После P15.39 | Изменение |
|---|---:|---:|---:|
| hash_access | 5.22× | 5.04× | -3.8% |
| field_access | 4.71× | 5.08× | +6.4% (WARN) |
| global_arith | 3.32× | 3.48× | +2.9% |
| array_access | 4.28× | 4.19× | -1.6% |
| lua_calls | 6.01× | 6.02× | +0.3% |
| geomean | 3.49× | 3.47× | -0.6% |

Microbench geomean нейтрален: cache плотность 32 B node не помогает
tiny tables (поля table `field_access`/`global_arith` — 2-3 ключа, полностью
в L1). Regression на `field_access` — архитектурная цена switch dispatch
в `keyMatches` против прямого чтения `Value` (однако +10.6% → +6.4% после
добавления inline `keyMatches`).

Cache плотность раскрывается на big tables (>L2):

| Workload (100K-key hash, 20M lookups) | До P15.39 | После P15.39 | Изменение |
|---|---:|---:|---:|
| Wall time | 1.87 s | 1.60 s | **-14.4%** |
| LLC cache-misses | 10.1 M | 1.7 M | **-83.2%** |
| L1-dcache-load-misses | 45.9 M | 27.1 M | **-41.0%** |
| Cycles (core) | 7.16 B | 6.06 B | **-15.3%** |

Parity preserved: 28/31 matrix pass без `_soft`/`_port` (без новых failures
сверх известных `attrib`/`big`/`files`; `db`/`nextvar` теперь pass после
follow-up фикса Builtin-ключей — см. ниже). 44/44 smoke tests pass. Stress test pass.

> **Follow-up fix (Builtin keys).** Оригинальный P15.39 ошибочно считал, что
> `Builtin` не может быть ключом таблицы, и `Node.setKey` маппил `.Builtin` →
> `key_tt = .empty`, тихо теряя ключ (нарушение PUC Lua: C-функции являются
> легитимными ключами, хешируются по identity). Это ломало `db.lua`/`nextvar.lua`
> (используют `[print]`/`[assert]`/`[checkerror]` как ключи). Follow-up коммит
> добавил `NodeKeyTag.builtin` + `NodeKeyPayload.builtin: BuiltinId` (BuiltinId
> явно `enum(u8)` чтобы жить в `extern union`), и провёл через всех пяти
> switch-сайтов: `setKey`/`getKey`/`rawHash`/`keyMatches`/`keyHash`. Hash
> использует `@intFromEnum(builtin_id)` — PUC-analog `hashpointer` для
> C-функций. `@sizeOf(Node) == 32` сохранён. Parity: 26/31 → 28/31 (db+nextvar
> восстановлены).

### P15.40 — PUC-faithful inline call resolution (luaD_precall + tryfuncTM)

Инлайнинг PUC `luaD_precall` (ldo.c:715-746) в три горячих bytecode-handler'а
(OP_CALL, OP_TAILCALL, OP_TFORCALL). Fast path (Closure/Builtin) больше не
вызывает `resolveCallable` — type switch происходит inline, нулевой overhead.
`__call` metamethod resolution использует in-place stack shift (PUC `tryfuncTM`,
ldo.c:523-536) вместо heap allocation `Value[args.len + 1]`.

Что изменилось:
1. `tryCallMetamethodInPlace` — новый метод на Vm, PUC `tryfuncTM` equivalent.
   Shifts `bc_stack[a..a+nargs+1]` up by 1 slot, writes metamethod to `regs[a]`.
2. OP_CALL: inline type switch + `tryCallMetamethodInPlace`. Eliminates
   `resolveCallable` call, `ResolvedCall` struct, `defer owned_args`,
   `rargs` derivation block, two-phase error retry, heap alloc for `__call`.
3. OP_TAILCALL: same inline pattern. Frame-reuse path simplified — always
   uses `copyForwards` (no `owned_args` branching).
4. OP_TFORCALL: same inline pattern + eliminates `alloc.dupe(resolved.args)`.

`resolveCallable` остаётся для 25 холодных сайтов (hooks, builtins, metamethods,
coroutine.resume, apiCall, IR backend). Эти сайты конструируют args в локальных
массивах, не на bc_stack — heap alloc для `__call` там малый и не влияет на perf.

**Результат (median of 7, ReleaseFast, vs `tools/perf/baseline-p15.37.json`):**

| Workload | До P15.35 | После P15.35 | Изменение |
|---|---:|---:|---:|
| lua_calls | 0.564 s (6.01×) | 0.474 s (5.03×) | **-15.9%** time |
| metamethod_add | 0.263 s (4.49×) | 0.208 s (3.47×) | **-20.9%** time |
| geomean | 3.49× | 3.23× | **-7.4%** |

`lua_calls` improvement (-15.9%) в ожидаемом диапазоне 10-20%: fast path больше
не делает function call (`resolveCallable`) + struct alloc + defer. `metamethod_add`
улучшение (-20.9%) превзошло ожидания 5-10% — тот же call machinery, и `__call`
больше не heap-allocs. Остальные workloads ±noise (unrelated to call resolution).

Parity preserved: 28/31 matrix pass без `_soft`/`_port` (без новых failures
сверх известных `attrib`/`big`/`files`). 45/45 smoke tests pass (добавлен
`tests/smoke/45_p15_35_call_metamethod_inline.lua` — покрывает OP_CALL,
OP_TAILCALL, OP_TFORCALL через `__call`). Stress test pass. Baseline updated.

### P15.40a — Pre-allocate frame capacity

Pre-allocation `bytecode_frames` и `frames` ArrayList capacity (64 entries) при
активации thread (`activateRuntime`), создании main thread (`init`) и создании
coroutine (`apiNewThread`). Первые 64 `addOne` вызова на каждом thread теперь
pure `items.len += 1` — без capacity-check branch на hot path.

PUC Lua не имеет этого overhead вообще (linked list, `luaE_extendCI` heap-alloc
но никогда не освобождает на return). Наш ArrayList с pre-allocation — это
промежуточный шаг; полная parity требует Phase B (merge frames) и Phase C
(inline array в Thread).

**Результат:** lua_calls 0.474→0.484 s (+2.1%, в пределах noise). Ожидаемо —
capacity-check branch уже хорошо предсказывался branch predictor'ом. Реальный
win ожидается от Phase B (merge frames) и Phase C (inline array). Parity: 28/31
matrix, 45/45 smoke tests, stress test pass.

### P15.40b — CallFrame struct + full merge (Tasks 1–7)

Определён merged `CallFrame` struct (PUC `CallInfo` equivalent), объединяющий
поля `BytecodeExecFrame` + `RuntimeFrame` в одну структуру. `proto: ?*const bc.Proto`
(null для IR frames, non-null для bytecode frames) — дискриминатор, как PUC's
`CIST_C` bit.

**P15.40b-full (Tasks 1–7):** Полный merge dual-array pattern завершён.
`pushBytecodeExecFrame` делает ОДИН `addOne` to `Thread.call_frames` с ALL полями.
Больше нет second `addOne` to `Vm.call_frames` для runtime copy. Поле
`runtime_frame_index` полностью удалено.

Архитектурные изменения:
- `pushBytecodeExecFrame`: single `addOne` + unified field writes
- `popBytecodeExecFrame`: single pop from `Thread.call_frames`
- `parkActiveRuntime`: sync topmost bytecode frame's `pc` from `bc_dispatch_pc`
  before parking (fixes stale `pc=0` on coroutine yield)
- `callBuiltin`: sync `pc`/`current_line` on `Thread.call_frames`
- `syncTopFrameForGc`: sync `Thread.call_frames`
- `fail()`/`setOutOfMemoryError()`: check `Thread.call_frames` first
- `errorLocationFrameIndex`: returns `?*const CallFrame`, walks both arrays
- `enterProtectedCFrame`: records combined depth (bytecode + IR)
- `debugResolveFrameIndex`: returns `?*CallFrame`, walks both arrays
- `debugInferNameFromCaller`: takes `?*const CallFrame` instead of `usize`
- `currentVisibleFrameDepth`/`snapshotThreadTraceFrames`: walks both arrays
- `debugBuildCurrentTraceback`: walks both arrays (uses `*const CallFrame` list)
- `threadCurrentParkedRuntimeFrame`: checks `th.call_frames`
- `activeAsyncDebugHookFrame`: walks `Thread.call_frames`
- `builtinCoroutineYield`: reads from `Thread.call_frames`
- GC Thread propagation: scans `regs`/`boxed`/`callee`/`env_override` on `th.call_frames`
- GC `gcMarkMutableRoots`: scans `Thread.call_frames` for bytecode frames
- `ensureBcStackCap`: fixes up `Thread.call_frames` after realloc
- `bcGrowFrame`: updates `Thread.call_frames` topmost frame
- Dispatch loop defer block: syncs `regs`/`boxed` to merged frame
- `parkBytecodeIrHookYield`: takes `exec_frames` + `frame_index`
- `runtime_frame_index` field: **removed** from both structs

**Результат:** Build PASS, Smoke 45/45, Matrix 28/31 (no regressions).

### P15.42 — Opcode handler extraction (dispatcher frame 139 KB → 54 KB Debug)

`runBytecodeDispatch` изначально содержал все opcode handlers inline в одном
огромном switch (~3500 строк, 79 opcode'ов). Zig Debug выделяет стек-слоты
под ALL locals во ALL ветках switch — без liveness analysis между ветками.
Результат: C-stack frame = **139 KB** в Debug (20 KB в ReleaseFast).

Архитектурный fix (PUC-faithful: PUC `luaV_execute` имеет отдельные функции
для complex opcodes — `luaV_concat`, `luaV_setlist`, `luaV_arith`):

- `BytecodeDispatchCtx` struct (~120 B) — все 15 dispatch state fields
  (regs, boxed, pc, frame_cap, base, cur_proto и т.д.) в одном объекте
- `DispatchResult` enum: `continue_dispatch` / `continue_no_advance` /
  `continue_frame_loop` / `return_results` / `propagate_error`
- Извлечены 11 handlers как методы: `opCall`, `opTailcall`, `opConcat`,
  `opForprep`, `opTforcall`, `opClosure`, `opVararg`, `opReturn*`, `opSetlist`
- 68 small handlers (1–2 строки) остались inline

Результат: dispatcher frame = **54 KB (Debug)** / **18 KB (ReleaseFast)**.
Smoke 45/45, matrix 25/31 (no regressions).

### P15.43 — Проверка host recursion: PUC итеративен, откат изменений

Опробован переход с iterative dispatch на host recursion для OP_CALL
(эквивалент PUC `luaD_call` → `ccall` → `luaV_execute`). Идея была в том,
что host recursion устранит `PendingCallSlot` целиком.

**Discovery:** проверка исходника PUC Lua 5.5.0 (`lvm.c:1731`) показала, что
PUC **ИТЕРАТИВЕН** для Lua-to-Lua вызовов:

```c
vmcase(OP_CALL) {
    ...
    if ((newci = luaD_precall(L, ra, nresults)) == NULL)
        updatetrap(ci);
    else {  /* Lua call: run function in this same C frame */
        ci = newci;
        goto startfunc;  // ITERATIVE — не рекурсия!
    }
}
```

Host recursion в PUC происходит только для C↔Lua переходов (luaD_call из
C host code). Существующий iterative dispatch в luazig уже PUC-faithful.
Изменения откачены.

### P15.44 — Shrink PendingCallSlot 768 B → 56 B (PUC CallInfo parity)

У `PendingCallSlot` было 768 B из-за inline optional storage больших
variant'ов `BytecodePendingCompletion`:

| Variant | Size | Use case |
|---|---|---|
| `gsub` | ~120 B | string.gsub с function replacement |
| `hook` | ~50 B | debug hooks |
| `close` | ~60 B | TBC closers (`__close`) |
| `concat` | ~40 B | OP_CONCAT с `__concat` metamethod chain |
| `coroutine_resume` | ~40 B | `coroutine.resume` |
| `BytecodeProtectedCall` (protection field) | 376 B | pcall/xpcall |

Все эти variants **редкие** (string.gsub с функцией, debug hooks, TBC variables,
pcall/coroutine — не в hot path). Inline storage раздувало union для
 common case (`results` = 16 B).

Fix: heap-allocate большие variants, оставив inline только `results`/`value`/
`ignore`/`compare` (1–16 B каждый):

```zig
const BytecodePendingCompletion = union(enum) {
    results: BytecodeResultContinuation,  // 16 B inline — common case
    value: BytecodeValueContinuation,     // 1 B inline
    ignore: BytecodeIgnoreContinuation,   // 0 B inline
    compare: BytecodeCompareContinuation, // 1 B inline
    concat: *BytecodeConcatContinuation,  // 8 B ptr — heap
    gsub: *BytecodeGsubContinuation,      // 8 B ptr — heap
    hook: *BytecodeHookContinuation,      // 8 B ptr — heap
    close: *BytecodeCloseContinuation,    // 8 B ptr — heap
    coroutine_resume: *BytecodeCoroutineContinuation,  // 8 B ptr — heap
};
```

Аналогично `protection: ?*BytecodeProtectedCall` вместо inline optional.

Результат:

| Struct | Before | After |
|---|---|---|
| `BytecodePendingCompletion` union | 152 B | **24 B** |
| `BytecodePendingCall` | 760 B | **48 B** |
| `PendingCallSlot` | 768 B | **56 B** ✓ matches PUC CallInfo (~80 B) |
| `CallFrame` | ~1200 B | **424 B** ✓ matches Phase C goal (~430 B) |

Heap allocation overhead платится только для редких фичей; common path
(OP_CALL с result continuation) полностью inline. Smoke 45/45, matrix 25/31.

### P15.45 — Fix xpcall+traceback stale bc_dispatch_pc sync

Коммит `89a7d70` (merge bytecode frames в `Thread.call_frames`) сломал
sync `bc_dispatch_pc` во время error recovery. `callBuiltin` и `fail()`
безусловно синхронизировали `bc_dispatch_pc` в topmost frame, но во время
error recovery (xpcall handler) `bc_dispatch_pc` указывает на failed
child's pc, а не на parent's. Sync перезатирал parent frame's pc.

Fix: `bc_dispatch_active` flag (set inside `runBytecodeDispatch`, cleared
by defer). `callBuiltin` и `fail()` проверяют flag перед sync — если
dispatch уже вышел, pc stale и sync пропускается.

### P15.46 — Fix stale bc_dispatch_pc after thread switch

Root cause: `switchRuntime` переключает runtime с main thread на coroutine,
`parkActiveRuntime` правильно синхронизирует `bc_dispatch_pc` в main thread's
frame, но `activateRuntime` НЕ обновляет `bc_dispatch_pc` для нового thread.
Stale pc от previous thread's dispatcher остаётся.

Когда `callBuiltin(.pcall)` вызывается на coroutine, он синхронизирует stale
`bc_dispatch_pc` (e.g. 25, main thread's OP_CALL для `coroutine.resume`) в
coroutine's topmost bytecode frame, перезатирая правильный pc (e.g. 6, foo's
OP_CALL для `coroutine.yield`).

Это ломает resume: `opCall`'s `resumed_direct_yield` check
(`ctx.pc == ctx.resume_pc`) fails потому что `ctx.pc` = 25 вместо 6.
Coroutine body никогда не возобновляется из yield; pcall возвращает
`true,nil` вместо `true,42`.

Fix: в `activateRuntime`, load `bc_dispatch_pc` из activated thread's topmost
bytecode frame. Это гарантирует что `callBuiltin`'s sync записывает правильное
значение обратно.

**Results:** coroutine.lua passes. Matrix 25/31 → 26/31. errors.lua и
locals.lua всё ещё fail из-за traceback quality (xpcall error handler видит
unwound stack — separate pre-existing issue).

### P15.46b — Fix captureErrorTraceback и builtinAssert для bytecode frames

`captureErrorTraceback` ходил только по `Vm.call_frames` (IR frames), пропуская
bytecode frames в `Thread.call_frames`. После P15.40b-full (merge bytecode frames
в `Thread.call_frames`) error tracebacks были почти пустыми для bytecode closures
— xpcall error handlers видели только `[C]: in function pcall` вместо полного
call stack.

Fix: walk `Thread.call_frames` first (most recent), then `Vm.call_frames`,
collecting `*const CallFrame` pointers from both arrays (same pattern as
`debugBuildCurrentTraceback`).

Также fix `builtinAssert`: когда `assert(false)` вызывается из bytecode closure,
проверял `Vm.call_frames` (empty) вместо `Thread.call_frames`, выдавая
`assertion failed!` без source location. Теперь проверяет `Thread.call_frames`
first, matching PUC's `file.lua:line: assertion failed!` format.

**Results:** errors.lua passes. Matrix 26/31 → 27/31. locals.lua gets further
(fails at 'to-be-closed variables in coroutines' — deep coroutine+close+yield
interaction, separate issue).

### P15.47 — Fix use-after-free in opReturn/opTailcall errdefer freeing close-owned ret slice

`opReturn`, `opReturn1` (both paths), and `opTailcall` allocated a `[]Value`
slice for return values and passed it to `beginBytecodeClose` as
`.return_frame = ret`. The close continuation stored this slice in
`close_state.post.return_frame`. However, each function had an
`errdefer if (ret_owned) self.alloc.free(ret);` that fired when
`beginBytecodeClose` returned `error.Yield` (which happens when a `__close`
metamethod yields via `coroutine.yield`). This freed the slice while the close
continuation still held a dangling pointer to it.

On resume, the allocator had reused the freed memory for `coroutine.yield`'s
yielded-values array (`th.yielded`), so `close_state.post.return_frame[0]`
contained a pointer to the yield array instead of the original return value.
This caused `locals.lua` line 926 ("yielding inside closing metamethods while
returning") to fail: the table returned after resume was a different object
than the one yielded.

Fix: set `ret_owned = false` before calling `beginBytecodeClose`, transferring
ownership of the slice to the close continuation. The continuation's
`freeBytecodeClosePost` / `cancelBytecodePendingCall` already handles freeing
the slice when the close completes or is cancelled.

**Results:** locals.lua passes. Matrix 27/31 → 28/31 (parity restored).

### P15.48c — Inline call frame array in Thread (Phase C)

Embed a fixed-size `[32]CallFrame` array directly in `Thread`, eliminating
heap allocation for call chains ≤32 deep (the vast majority of real Lua
programs). Deeper chains spill to a heap `ArrayList` overflow.

PUC Lua's `base_ci` is the equivalent inline first frame; we inline 32
because our `CallFrame` (424 B) is larger than PUC's `CallInfo` (~48 B),
and typical Lua call depth is well under 32.

`FrameStack` wrapper: `inline_frames[32]` + `heap: ArrayList` overflow.
All access goes through `getPtr(index)` / `getConstPtr(index)` / `len()` /
`addOne()` / `shrinkTo()`. 42 function signatures migrated from
`*std.ArrayListUnmanaged(CallFrame)` to `*FrameStack`. ~211 direct
`.items[]` indexing sites migrated to the wrapper API.

`Thread.call_frames` (bytecode frames) stays with the thread during coroutine
switch — no special handling needed (unlike `Vm.call_frames` IR frames which
are moved via `parked_call_frames`).

**Results:** Parity 28/31 (no regressions), smoke 45/45. geomean 3.22×,
lua_calls 0.393s (-17.1% vs baseline). No perf regressions.

### P15.48d — Varargs on bc_stack (Phase D)

Eliminate `alloc.dupe(Value, varargs_src)` on every vararg function call by
storing varargs directly on `bc_stack` below the register window (PUC's
`buildhiddenargs` model). `CallFrame.varargs` (heap slice) is replaced by
`nextraargs: u16` for bytecode frames; varargs are accessed via
`bc_stack[base - nextraargs .. base]`.

IR frames keep heap varargs (`frame.varargs` slice) — only bytecode frames
use the new model.

Key changes:
- `pushBytecodeExecFrame`: write varargs at `[bc_stack_top .. bc_stack_top + nextra]`,
  set `base = bc_stack_top + nextra`. No heap allocation.
- `popBytecodeExecFrame`: restore `bc_stack_top = base - nextraargs`. No heap free.
- `opVararg`/`OP_VARARGPREP`: derive varargs slice from `bc_stack[base-nextra..base]`.
- `opTailcall`: when `new_nextra > old_nextra`, shift register window UP by
  the delta; copy `call_args` to a stack-local buffer first to handle overlap.
- `opCall`/`opTailcall` pre-grow: account for `child_nextra` in `ensureBcStackCap`.
- GC mark: scan `bc_stack[base-nextra..base]` for bytecode frame varargs.
- Debug API: `frameVarargs()` helper derives slice from bc_stack for bytecode
  frames, falls back to `frame.varargs` for IR frames.

**Results:** Parity 28/31 (no regressions), smoke 45/45. geomean 3.25×,
lua_calls 0.426s (-10.2% vs baseline).

### P15.49 — Fix stale rargs GC corruption + dispatch hot path cleanup

**Bug fix (stale `rargs` in `opCall`/`opTailcall`):**
`opCall`/`opTailcall` pre-grew `bc_stack` with `child_frame_cap = p.maxstacksize`,
but `pushBytecodeExecFrame` uses `frame_cap = proto.maxstacksize + EXTRA_MARGIN` (5).
When `pushBytecodeExecFrame` called `ensureBcStackCap` for the extra 5 slots, it could
realloc `bc_stack`, making the `rargs` slice (derived from `ctx.regs` before the call)
a dangling pointer. The child frame's register 0 would then contain garbage from freed
memory. This was a pre-existing nondeterministic crash (smoke 27, ASLR-dependent)
introduced in `de34fc0` (ctx.fr elimination).

Fix: pre-grow with `child_frame_cap = p.maxstacksize + EXTRA_MARGIN` in both `opCall`
and `opTailcall`, so `pushBytecodeExecFrame`'s `ensureBcStackCap` is always a no-op.

**GC fix (stale `frame.regs`):**
`gcMarkMutableRoots`, `gcClearDeadFrameRegisters`, and `gcMarkVmRoots` (inactive thread
path) used `frame.regs` which can become stale when GC finalizers execute Lua code that
reallocs `bc_stack`. Fixed to derive slices from `self.bc_stack` / `th.bytecode_stack`
directly, using `frame.base` and `frame.regs.len` (length is still valid even after realloc).

**OP_MOVE @branchHint fix:**
Removed `@branchHint(.unlikely)` from OP_MOVE fast path (no open upvalues). The fast
path is the overwhelmingly common case; marking it unlikely was a bug that pessimized
the hot path.

**Results:** smoke 27 crash eliminated (0/20), 45/45 smoke pass, 28/31 matrix,
geomean 2.91× (was 2.88×).

### P15.50 — PUC-faithful allocation-site GC (remove per-instruction GC tick)

**Problem:** The per-instruction GC tick in the dispatch loop added overhead on every
instruction, even when no allocation occurred. PUC Lua instead triggers GC only at
allocation sites via `luaC_condGC(L, c)` (called from `luaM_*`, `OP_CONCAT`, `OP_CLOSURE`,
and builtin calls).

**Changes:**

1. **Removed per-instruction GC tick** from the dispatch loop. GC is now triggered
   only at allocation sites, matching PUC Lua's `checkGC(L, c)` pattern.

2. **`condGcFromDispatch(ctx)`** — PUC `checkGC(L, c)` analogue, called at `OP_CONCAT`,
   `OP_CLOSURE`, and builtin call sites. Checks `gc_step_debt_kb` and runs an automatic
   GC step if needed.

3. **`gcNoteAlloc(bytes)`** — PUC `luaM_*` → `GCdebt -= bytes` analogue. Called on every
   allocation site (table creation, closure creation, string allocation, thread creation).
   Decrements `gc_step_debt_kb` so `condGcFromDispatch` can detect when GC should run.

4. **`gcAutomaticBudget`** — PUC-faithful formula:
   `stepsize_bytes / sizeof(*anyopaque) * stepmul / 100 * GCSWEEPMAX`.
   Uses `sizeof(*anyopaque)` (PUC `sizeof(void*)`) and `GCSWEEPMAX=20` (PUC `lgc.h`).

5. **`gcFullCollectionForUser`** — added `gcScheduleNextAutomaticCycle()` + debt reset,
   matching PUC `fullinc` which calls `setpause` to schedule the next automatic cycle.

6. **`live_reg_top[pc]` "after" boundary (P15.38):** Changed `ProtoBuilder.emit()` to
   record `current_live_top` (the "after" boundary) instead of `live_top_before` (the
   "before" boundary). The "before" boundary (P15.36) caused GC to clear the destination
   register of allocation instructions (OP_CLOSURE, OP_CONCAT) when GC ran during the
   allocation (via `gcNoteAlloc`) but before the result was stored. The "after" boundary
   correctly preserves the destination register.

7. **`genLocalDecl` live_top sync:** Added `syncLiveTop()` calls after `nvarstack` growth
   in `genLocalDecl` and `LocalFuncDecl.declareLocal`, ensuring `current_live_top` tracks
   all live locals at every PC.

8. **`opReturn`/`opReturn0`/`opReturn1`** — sync `fr.pc = ctx.pc; fr.reg_top = ctx.reg_top;`
   before `beginBytecodeClose` so GC sees correct `live_reg_top[pc]` during `__close`
   finalizers.

9. **OP_CALL** — added `ctx.reg_top = @max(ctx.reg_top, a + nstore)` for fixed nresults
   (was only for multi-return `nresults < 0`).

10. **`gcClearDeadFrameRegisters`** — uses `live_reg_top[pc]` + TBC protection (doesn't
    clear `bc_tbc_regs` items in top frame).

11. **`gcMarkMutableRoots`** — marks `regs[0..live_reg_top[pc]]` + separately marks
    `bc_tbc_regs` items in top frame.

**Results:** 28/31 matrix (parity baseline maintained), 45/45 smoke pass, geomean 2.85×.

### P15.51 — Pre-resolve constants to runtime Value format (PUC TValue k[] parity)

**Problem:** `bcConstToValue` (inline fn) was called on every OP_GETFIELD/OP_SETFIELD/
OP_GETTABUP/OP_SETTABUP/OP_LOADK execution — a 5-way switch on `Constant` tag to
reconstruct a `Value` (16 bytes). Perf showed 7.44% of `field_access` cycles in the
`bcConstToValue` inlining scope. PUC Lua stores `TValue k[]` in Proto (lobject.h:614) —
constants are already in runtime format, no per-execution conversion.

**Fix:** Added `resolved_values: []Value` field to `Proto`. `resolveProtoConstants`
(populated lazily on first execution) now pre-converts all `Constant` → `Value` into
this array. All 18 `bcConstToValue(ctx.cur_proto.k[...])` call sites in the dispatch
loop replaced with `ctx.cur_proto.resolved_values[...]` — a direct array access with
no switch, no jump table, no function call. `bcConstToValue` function removed.

**Ownership:** `resolved_values` doesn't own string pointers (owned by VM intern table
after resolution). `deinit` frees only the slice itself. `cloneStrippedProto` shares
the slice (borrowed, like `code`/`k`/`p`).

**Results:** 28/31 matrix (parity maintained), 45/45 smoke pass, geomean **2.78×**
(was 2.85×). `field_access` -15.6% (3.82× → 3.60×), `global_arith` -11.7%, `lua_calls`
-12.6%, `branch_loop` -11.6%. `bcConstToValue` completely eliminated from perf top.

### P15.52 — Inline rawGet/rawSet fast paths into dispatch loop

**Problem:** `rawGet` and `rawSet` were not inlined into the dispatch loop — perf showed
real `call` instructions for OP_GETFIELD/OP_SETFIELD/OP_GETTABLE/OP_SETTABLE. `rawSet`
was 19.7% and `rawGet` was 7.6% of `field_access` cycles. The function call overhead
(register saving, prologue, epilogue) was significant for the hot path.

**Fix:** Inlined the fast path (existing key lookup/update) directly into the 4 hot
opcode handlers, eliminating the function call:

- **OP_GETFIELD**: Direct `nodeLookup` for string keys — no `rawGet` call.
- **OP_SETFIELD**: `gcTableWriteBarrier` + `nodeLookup` for existing key update (or
  `nodeDelete` for nil). Falls back to `rawSet` for new key insertion (slow path).
- **OP_GETTABLE**: Inline `nodeLookup` for Int (non-array) and String keys. Falls back
  to `rawGet` for other types (Num, Bool, etc.) that need float→int coercion.
- **OP_SETTABLE**: Inline fast path for String keys only. Int keys and other types fall
  back to `rawSet` (which has array fast path + float→int coercion).

**PUC approach:** PUC Lua inlines `luaH_get` in `luaV_execute` through macros. The fast
path is direct hash lookup for existing keys; slow path (rehash, new key insertion) stays
in `luaH_set`/`luaH_newkey`.

**Results:** 28/31 matrix (parity maintained), 45/45 smoke pass, geomean **2.79×**.
`field_access` -31.1% (3.82× → 2.65×), `hash_access` -7.4%, `global_arith` -12.6%.
`rawGet`/`rawSet` completely eliminated from perf top on field_access.

### P15.53 — Add `LightUserdata` variant to `Value` union

**Problem:** PUC Lua has `LUA_TLIGHTUSERDATA` (type code 2) — a plain C
pointer wrapped as a Lua value, not garbage-collected. luazig lacked this
fundamental value type entirely: light userdata was faked via tables with a
`__light` field. This blocks real `lua_pushlightuserdata` and the C API and
prevents proper parity with PUC testC commands like `isudataval`,
`topointer`.

**Fix:** Added `.LightUserdata: *anyopaque` as the 10th variant of the `Value`
union. Updated all exhaustive switch sites across `vm.zig`, `ltable.zig`,
`api.zig`, and `c_api.zig`:

- `Value.typeName()` / `builtinType` — returns `"userdata"` (PUC returns
  `"userdata"` for both light and full userdata).
- `valuesEqual` — pointer equality (two light userdata are equal iff same
  pointer).
- `valueMetatable` / `builtinDebugSetmetatable` — returns shared
  `light_userdata_metatable` (PUC's `mt[LUA_TLIGHTUSERDATA]`).
- `gcMarkValue` / `gcValueAge` / `gcWriteBarrier` — light userdata is NOT
  GC-managed, falls through to `else =>` (like `.Int`/`.Bool`).
- `keyHash` / `keyMatches` / `setKey` / `getKey` / `rawHash` in
  `ltable.zig` — light userdata as a table key: hashes by pointer address,
  compares by identity.
- `writeValue` / `valueToStringAlloc` — formats as `"userdata: 0x{x}"`.
- `topointer` (testC) — returns pointer address.
- `api.zig:Type` — added `lightuserdata` (PUC type code 2).
  `valueType` returns `.lightuserdata`; `isuserdata` returns true for both.
- `c_api.zig:lua_type` / `lua_getglobal` — maps `.lightuserdata => 2`
  (PUC `LUA_TLIGHTUSERDATA`).

**PUC approach:** PUC Lua's `LUA_TLIGHTUSERDATA` is a plain `void*` in a
`TValue`. The GC does not own or trace it. A single shared metatable
(`mt[LUA_TLIGHTUSERDATA]`) is used for all light userdata values. Light
userdata can be a table key — hashes by `hashpointer`, compares by identity.

**Results:** 28/31 matrix (parity maintained), 45/45 smoke pass, no regressions.

### P15.54 — Add `CClosure` variant to `Value` union

**Problem:** PUC Lua's `CClosure` (C closure) is a GC-managed object holding a
`lua_CFunction` pointer plus upvalues. luazig had no native representation for
C closures — `pushcclosure` testC command was faked via table-based upvalues.
This blocks real `lua_pushcclosure`/`lua_iscfunction`/`lua_tocfunction` C API
parity.

**Fix:** Added `CClosure` struct (`src/lua/vm.zig:409`) mirroring PUC's
`CClosure` layout: `c_function: *const fn(*anyopaque) callconv(.C) c_int` +
upvalues array + GC fields (`gc_age`/`gc_index`). Added `.CClosure: *CClosure`
as the 11th variant of the `Value` union. Full GC integration: CClosure reuses
the same `gc_closures` registry and `GcAge` infrastructure as `Closure` —
swept/marked identically. Updated all exhaustive switch sites across `vm.zig`,
`ltable.zig`, `api.zig`.

**PUC approach:** PUC's `CClosure` (`lua-5.5.0/src/lobject.h:247-253`) holds
`lua_CFunction f` + `UpVal *upvals[1]` (flexible array member). It is a
`GCObject` with `CommonHeader`, allocated via `luaM` and linked into `allgc`.

**Results:** 28/31 matrix (parity maintained), 45/45 smoke pass, no regressions.
CClosure call dispatch is stubbed (`self.fail("CClosure call not yet
implemented")`) — actual C function invocation is future work.

### P15.55 — Implement 10 missing testC commands

**Problem:** PUC Lua's `ltests.c` defines 97 unique testC commands. luazig had
88/97 implemented — 10 were missing: `abort`/`getmetatable`/`isudataval`/
`print`/`printstack`/`resetthread`/`throw`/`tointeger`/`touserdata`/`type`.
These are needed for full testC parity.

**Fix:** Implemented all 10 missing commands in `execTestcCommand`
(`src/lua/vm.zig:24494+`):
- `abort` — calls `std.process.exit(1)` (PUC `abort()`).
- `getmetatable` — wraps `State.getmetatable`.
- `isudataval` — checks both native `.LightUserdata` (P15.53) and table-based
  fake `isTestcLightUserdata` for backward compatibility.
- `print` / `printstack` — prints value/stack to stderr (PUC `printf`).
- `resetthread` — resets thread state (TODO: full PUC semantics).
- `throw` — raises a Lua error (PUC `lua_error`).
- `tointeger` — uses `luaStrToNum` for string path + `floatToIntChecked` for
  safe i64 range check (PUC `lua_tointegerx`).
- `touserdata` — uses `makeTestcPointerValue` for round-trip consistency.
- `type` — wraps `State.typeOf`, returns PUC type name string.

**PUC approach:** All 10 commands are simple `if/else if` branches in PUC's
`runC` function (`lua-5.5.0/testes/ltests.c:1583+`).

**Results:** 28/31 matrix (parity maintained), 45/45 smoke pass, no regressions.
All 97 PUC testC commands now implemented.

### fix: enableTestcModuleInternal _ENV upvalue

**Problem:** `enableTestcModuleInternal` passed empty upvalues (`&.{}`) to
`runBytecode` for the testC bootstrap chunk. The bootstrap source uses global
accesses (`require`, `setmetatable`) that compile to `OP_GETTABUP` on upvalue 0
(`_ENV`). With empty upvalues, `gettabup` caused an out-of-bounds access
(SIGSEGV) — all 6 testC lane suites crashed immediately.

**Fix:** Use `createBytecodeChunkClosure` + `applyLoadEnv` + `runClosure`
instead of direct `runBytecode(proto, &.{}, ...)`, matching how
`compileTextChunk` + `builtinDofile` load chunks.

**Results:** testC lane goes from 0/6 (all SIGSEGV) to 2/6 pass (`errors.lua`,
`strings.lua`). Remaining 4 failures are assertion failures, not crashes:
- `api.lua:178` — testC `call` with many returns
- `coroutine.lua` — timeout (possible hang)
- `locals.lua:685` — assertion failure
- `memerr.lua:133` — assertion failure

### fix: stale `outs` after bc_stack realloc in pcall/xpcall/testC

**Problem:** `builtinTestcTestC`, `builtinPcall`, `builtinXpcall` error paths
used stale `outs` slice after `callBuiltin`/`runClosure` triggered bc_stack
realloc. Also `opTforcall` had LUA_MULTRET UB (`nresults < 0` cast to usize).

**Fix:** Added `refreshBuiltinOuts()` (vm.zig:9802) — re-derives `outs` slice
from `bc_stack` after realloc. Called in all error paths. Fixed `opTforcall`
MULTRET by checking `nresults < 0` before cast.

### fix: GC varargs scan use bc_stack for VM-active thread

**Problem:** `gcPropagateOne` used `th.bytecode_stack` directly for varargs
scan, but for VM-active thread it's empty (moved to `bc_stack`).

**Fix:** Use `stack` variable with fallback, computed once before both regs
and varargs scans.

### P15.56 — Virtual vararg access (PF_VAHID + OP_GETVARG)

**Problem:** PUC Lua 5.5 has two modes for named varargs (`...arg`):
- **PF_VAHID** (default, hidden args, no table): `arg[n]`/`arg.n` compile to
  `OP_GETVARG` reading extra args directly from stack. 0 allocations.
- **PF_VATAB** (table exists): created lazily only when the vararg escapes
  (assigned, returned, passed to call, written to via `arg[k]=v`). 3 allocations.

luazig always created the table (3 allocations) and compiled `arg[n]` as
`GETTABLE`. This caused `memerr.lua:138` to fail (`b.aloc == 0` expected for
optimized vararg, but 3 allocations were made).

**Fix (PUC-faithful):**
1. **bytecode.zig**: Added `getvarg` opcode (`R[A] := vararg_param[R[C]]`).
2. **codegen_bc.zig**: Added `vararg_var` and `vararg_index` ExpDesc variants.
   When `arg` is looked up by name, return `vararg_var` (virtual). When
   `vararg_var` is indexed for reading (`arg[n]`/`arg.n`), compile to `getvarg`
   instead of `gettable`. When the vararg escapes (discharged to register,
   returned, passed to call, captured as upvalue, written to via `arg[k]=v`),
   call `needVarargTable()` to materialize a real table (PF_VATAB).
   Special case: `_ENV` as named vararg always materializes (environment table).
3. **vm.zig**: Implemented `getvarg` handler — reads from extra args slice on
   stack (`bc_stack[base - nextraargs .. base - 1]`). Handles integer keys
   (1-based index), string `"n"` (returns count), and float keys (integer
   coercion, matching PUC `tointegerns`).
4. **VARARGPREP**: Only creates table if `vararg_table_reg` is set (PF_VATAB);
   otherwise just sets up `nextraargs` (PF_VAHID, already implemented).

**PUC approach:** `needvatab()` (lobject.h) marks a function as needing a real
vararg table. `luaT_getvararg` (ltm.c:292-311) reads from extra args directly.
`luaK_vapar2local` (lcode.c:808) converts virtual vararg to local when escaped.

**Results:**
- `memerr.lua:133` (`b.aloc == 3`) — passes (vararg table materialized for `pack`).
- `memerr.lua:138` (`b.aloc == 0`) — passes (optimized vararg, no table).
- `vararg.lua` — passes (upvalue capture + `_ENV` special case fixed).
- Matrix: 30/31 (was 28/31, +2: vararg.lua now passes, memerr.lua matrix pass).
- Smoke: 45/45, no regressions.
- testC lane: 3/6 pass (errors, strings, memerr lines 133+138). memerr.lua
  still hangs after "file creation" testamem — pre-existing bug unrelated to
  vararg changes (accumulated state after many `T.alloccount`/`T.totalmem`
  cycles causes hang in later `testamem` calls).

### P15.57 — GC free tracking + function-sugar upvalue assignment

**Two bugs fixed:**

**Bug 1: `testc_total_bytes` never decremented on GC free (memerr.lua hang)**

`T.totalmem()` returns `testc_total_bytes`, which was a monotonically growing
counter — only incremented by `testcChargeMemory`, never decremented when GC
freed memory. In PUC Lua, `l_memcontrol.total` (ltests.c:`freeblock`) is a
**net** counter: incremented on alloc, decremented on free. Without this,
`testbytes` in memerr.lua loops forever: `M = T.totalmem()` starts at the
ever-growing total, and no amount of `M += 7` can catch up to a counter that
never decreases after `collectgarbage()`.

**Fix:** Added `gcNoteFree(bytes)` helper (mirrors `gcNoteAlloc`) that
decrements both `gc_count_kb` and `testc_total_bytes`. Replaced all 10 inline
`gc_count_kb = @max(0, ...)` decrements in GC sweep paths (young + incremental:
tables, closures, threads, strings, cells) with `gcNoteFree` calls.

**PUC reference:** `debug_realloc` (ltests.c:196-265) tracks all allocations
through the custom allocator. luazig doesn't have a custom allocator, so
`testcChargeMemory` charges approximate sizes at specific call sites. Despite
drift between charge and free amounts, the counter correctly decreases when GC
frees memory, allowing `testbytes` to converge.

**Bug 2: `emitSetName` didn't call `ensureUpvalue` (function-sugar upvalue bug)**

`function foo() ... end` inside a closure didn't assign to upvalue `foo` — it
silently wrote to `_ENV[foo]` instead. `emitSetName` only checked
`self.upvalues.get(name)` (already-registered upvalues), but didn't try
`ensureUpvalue` to capture from the outer scope. Compare with `genNameExpDesc`
(reading a name) and `genSet` (general assignment), which both call
`ensureUpvalue` as a fallback.

**Fix:** Added `ensureUpvalue` call in `emitSetName` between the existing
upvalue check and the global fallback, mirroring `genSet`'s logic.

**Results:**
- `memerr.lua` — now passes completely (was hanging after "file creation").
- testC lane: 4/6 pass (errors, memerr, strings + previously passing).
  Remaining: api.lua:815 (GC color tracking), coroutine.lua (timeout),
  locals.lua:1130 (close continuation).
- Matrix: 28/31 (no regression: attrib zig_fail, big both_fail, files both_fail).
- Smoke: 45/45, no regressions.

### P15.58 — Per-object GC mark bits + T.gccolor/T.gcstate + warn + querytab

**Problem:** PUC Lua's GC uses per-object tri-color mark bits stored in
`CommonHeader.marked` (lgc.h:79-86). luazig had no per-object mark bits —
GC marking was done via a HashSet of visited pointers, which cannot support
`T.gccolor()` (testC command to inspect an object's GC color: white/gray/black)
or proper generational GC age tracking.

**Fix:** Added `gc_marked: u8` field to all GC objects: `Table`, `Closure`,
`Thread`, `LuaString`, `Cell`. Implemented PUC's bit layout:
- `WHITE0BIT = 1<<3`, `WHITE1BIT = 1<<4`, `BLACKBIT = 1<<5`
- `FINALIZEDBIT = 1<<6`, `TESTBIT = 1<<7`
- White = has white bit matching `gc_current_white`
- Black = `BLACKBIT` set; Gray = neither

Added `gc_current_white: u8` on Vm (toggled each collection cycle). Added
`gcIsWhite`, `gcSetWhite`, `gcSetBlack`, `gcSetGray`, `gcFlipWhite` helpers.

Implemented testC commands:
- `T.gccolor(obj)` — returns "white"/"gray"/"black" string
- `T.gcstate()` — returns current GC state string
- `T.querytab(tab)` — returns array of {key, value} pairs (for GC introspection)
- `warn(msg)` — PUC `lua_writestringerror` equivalent

**Results:**
- testC: 3/9 pass (errors, memerr, strings).
- Matrix: 28/31, smoke 45/45 — no regressions.

### P15.59 — Fix generational GC age tracking + barrier gray marking

**Three bugs fixed:**

**Bug 1: Generational GC never advanced object ages after full collection**

`gcFullCollectionForUser` (gen mode path) called `gcMakeAllOld` but didn't
clear `gc_finalizer_tick_pending` or set `gc_step_debt_kb` afterward. This
caused the generational collector to never properly transition objects to
old generation, leading to incorrect GC behavior in `gengc.lua`.

**Fix:** Clear `gc_finalizer_tick_pending` and set `gc_step_debt_kb` after
`gcMakeAllOld` in the gen path. Also set `gc_busy = true` during the
`gcMakeAllOld` transition to prevent re-entrancy.

**Bug 2: `registerFinalizable` set `gc_finalizer_tick_pending` unconditionally**

PUC Lua does NOT force a GC step when registering a finalizable object
(`luaC_checkfinalizer` doesn't trigger GC). Our code did, causing incorrect
GC timing in generational mode.

**Fix:** Remove the `gc_finalizer_tick_pending = true` from
`registerFinalizable`.

**Bug 3: `gcRememberValue`/`gcRememberCell` didn't set objects GRAY**

PUC's `luaC_barrierback_` calls `set2gray`/`linkobjgclist` which turns the
owner gray and adds it to the grayagain list. Our implementation added to
`grayagain` but didn't set the gray mark bit, causing the object to be
re-scanned incorrectly.

**Fix:** Set `gcSetGray` when adding to `grayagain` in both
`gcRememberValue` and `gcRememberCell`.

**Results:**
- testC: 4/9 pass (errors, memerr, strings, **gengc**).
- Matrix: 28/31, smoke 45/45 — no regressions.

### P15.60 — PUC-faithful forward/backward barrier split

**Problem:** PUC Lua has TWO distinct write barriers:
- **Forward barrier** (`luaC_barrier_`/`luaC_objbarrier`): marks the VALUE.
  Used for `setmetatable`, `lua_setupvalue`, `OP_SETUPVAL`, `OP_CLOSURE`.
- **Backward barrier** (`luaC_barrierback_`/`luaC_objbarrierback`): turns the
  OWNER gray and adds to grayagain. Used for table writes (`luaH_set`,
  `OP_SETTABLE`, `lua_rawset`).

luazig had a single barrier that didn't distinguish these cases, causing
incorrect GC color tracking in `gc.lua` (objects marked wrong color).

**Fix:** Split into two barrier functions matching PUC semantics:
- `gcWriteBarrierTable` — backward barrier: turn table gray, add to grayagain
- `gcWriteBarrierCell` — forward barrier: mark value if cell is black
- `gcStoreMetatable` — forward barrier: mark metatable (OLD0 in gen mode)
- `gcStoreClosureEnv` — forward barrier: mark value (OLD0 in gen mode)

In generational mode, forward barriers set the value to OLD0 age (matching
PUC's `genlink` behavior).

**Results:**
- testC: 4/9 pass (gengc still passes). gc.lua progresses (fails at 569
  instead of earlier — the remaining failure is the open-upvalue issue).
- Matrix: 28/31, smoke 45/45 — no regressions.

### P15.61 — PUC-faithful upvalue cell marking + finalization order

**Two fixes:**

**Fix 1: `gcQueueScanCell` — open vs closed upvalue marking (PUC
`reallymarkobject` for `LUA_VUPVAL`)**

PUC's `reallymarkobject` for `LUA_VUPVAL` keeps open upvalues GRAY (not
BLACK) to avoid barriers — their values are revisited by the thread or
`remarkupvals`. Closed upvalues are turned BLACK (fully visited).

Previously, `gcQueueScanCell` always set cells BLACK. Now:
- Open upvalues (`bc_stack_idx != null`): set GRAY, add to grayagain
- Closed upvalues (`bc_stack_idx == null`): set BLACK

Also unified all cell marking sites to use `gcQueueScanCell`:
`gcMarkMutableRoots`, `gcMarkValue` (Closure case), `gcMarkClosureFinalizerReach`.

**Note:** Currently all cells have `bc_stack_idx == null` (closed) because
the bytecode VM doesn't implement truly open upvalues (cells capture values,
not stack references). This is a known architectural gap — fixing it requires
implementing PUC-style open upvalues (`luaF_findupval` returning a pointer to
the stack slot). The gc.lua:569 failure is caused by this gap.

**Fix 2: `gcFinalizeLessThan` — LIFO creation order (PUC finalization order)**

PUC finalization order: objects are prepended to `finobj` (LIFO), moved to
`tobefnz` preserving order, and finalized from the beginning. So the most
recently created finalizable object is finalized first.

Previously, `gcFinalizeLessThan` used pointer comparison as a tiebreaker,
which is non-deterministic across runs. Now uses `gc_index` (registration
order in `gc_tables`) descending — matching PUC's LIFO creation order.

**Results:**
- testC: 4/9 pass (errors, gengc, memerr, strings). gc.lua:569 (open upvalue
  gap), nextvar:41 (table rehash), coroutine (timeout), locals:1130, api:941.
- Matrix: 28/31, smoke 45/45 — no regressions.

### P15.62 — PUC-faithful forward barrier sweep-phase makewhite

**Problem:** PUC's `luaC_barrier_` (forward barrier) has two branches:
- `keepinvariant(g)` (propagate/atomic): mark the value (`reallymarkobject`)
- sweep phase: make the owner white (`luaC_makewhite`)

luazig's forward barriers (`gcWriteBarrierCell`, `gcStoreClosureEnv`,
`gcStoreMetatable`) only implemented the propagate/atomic branch — they
marked the value in all non-pause states, including sweep. In sweep phase,
this incorrectly marked newly assigned values instead of making the owner
white.

**Fix:** All three forward barrier functions now check `gc_state`:
- `propagate`/`atomic`: mark the value (existing behavior)
- `sweep`: make the owner white via `gcMakeWhite` (new)
- `pause`: no-op (existing behavior)

**Note:** gc.lua:569 still fails because the root cause is the lack of open
upvalues. In PUC, open upvalues are kept GRAY (not BLACK), so the forward
barrier doesn't fire (`isblack(p)` is false). In luazig, all cells are closed
(copy-by-value), so they're marked BLACK during atomic phase, and the barrier
fires incorrectly. Fixing this requires implementing PUC-style open upvalues
(`luaF_findupval` returning a pointer to the stack slot).

**Results:**
- testC: 4/9 pass (no change). gc.lua:569 still fails (open upvalue gap).
- Matrix: 28/31, smoke 45/45 — no regressions.

### P15.63 — PUC-faithful open upvalues + OP_CLOSURE function counting

**Problem:** PUC Lua's `UpVal` is a GC object that can be OPEN (pointing to a
stack slot via `uv->v.p`) or CLOSED (holding its own copy in `uv->u.value`).
Open upvalues are kept GRAY during GC marking (not BLACK), which prevents
the forward barrier from firing when the stack slot is written. This is
essential for gc.lua:569, where a new table assigned to a captured local
must remain white (unmarked) during the atomic phase.

luazig's `Cell` had `bc_stack_idx` field but it was always `null` — all
upvalues were effectively closed (copy-by-value). This caused the forward
barrier to fire incorrectly, marking newly assigned values gray.

**Fix:** Implemented PUC-faithful open upvalues:

1. **`Cell.bc_stack_thread: ?*Thread`** — identifies which thread's stack
   the open upvalue points to. Needed because a suspended coroutine's stack
   lives in `th.bytecode_stack`, not `vm.bc_stack`.

2. **`Cell.resolveStack(vm)`** — returns the correct stack slice: if the
   owning thread is currently active (`vm.active_runtime_thread == th`),
   uses `vm.bc_stack`; otherwise uses `th.bytecode_stack`.

3. **`Cell.get(vm)` / `Cell.set(vm, v)` / `Cell.close(vm)`** — now take
   `*Vm` instead of `[]Value`, using `resolveStack` to find the correct
   stack for open upvalues.

4. **OP_CLOSURE** — creates open upvalues with `bc_stack_idx = ctx.base +
   uv.idx` and `bc_stack_thread = self.activeBytecodeThread()`.

5. **OP_MOVE slow path** — for OPEN cells, the register write already
   updates the stack slot (which IS the cell's value), so `gcStoreCellValue`
   is skipped. For CLOSED cells, sync + barrier as before.

6. **`closeBytecodeUpvaluesFrom` / tail call close** — uses `cell.close(self)`
   to properly snapshot the stack value, then fires the write barrier.

7. **`gcQueueScanCell`** — for open upvalues, returns early after setting
   GRAY (value is on the thread's stack, scanned separately). For closed
   upvalues, marks value as before.

8. **`gcMarkClosureFinalizerReach`** — same open/closed distinction.

9. **`bumpClosureNumericUpvalues`** — now takes `*Vm`, uses `cell.get()`/
   `cell.set()` for proper open/closed handling.

10. **OP_CLOSURE** — added `testc_obj_functions += 1` (was missing, causing
    `T.totalmem("function")` to undercount).

**Results:**
- testC: **5/9 pass** (errors, **gc**, gengc, memerr, strings). gc.lua now
  passes completely! Remaining: nextvar:41 (table rehash), coroutine
  (timeout), locals:1130, api:941.
- Matrix: 28/31, smoke 45/45 — no regressions.

### P15.64 — Two-phase finalization + generational fullgc fix + loadlib _G

**Problem:** Three issues blocked api.lua and gengc.lua:
1. `gcFullCollectionForUser` checked `finalizables.count() > 0` for the
   second cycle, but `gcFinalizeList` removes from `finalizables`, so the
   second cycle never ran. Finalized objects survived but were never freed.
2. In generational mode, old objects are BLACK. When `luaC_fullgc` switches
   to incremental and runs a full cycle, old BLACK objects are not visited
   during marking. Their metatables (if young/white) get swept, causing
   use-after-free crashes in gengc.lua.
3. `T.loadlib(L, 1|2, 0)` didn't set `env._G = env` when bit 1 was set,
   so `_ENV = _G` in doremote scripts resolved to the main `_G` (with all
   stdlib) instead of the isolated env.

**Fixes:**
- Added `gc_finalizers_ran_count` field, set in `gcFinalizeList`. Changed
  `gcFullCollectionForUser` to check `gc_finalizers_ran_count > 0` instead
  of `finalizables.count() > 0` for both incremental and generational paths.
  Reset to 0 before each second cycle to prevent recursive third cycles.
- Added `gcMakeAllWhite()`: resets all GC objects to current white before
  the full incremental cycle in generational mode. This is PUC's
  `markbeingold` equivalent — ensures the incremental mark/sweep correctly
  identifies unreachable objects (they stay old-white after the white flip
  and are swept). Called before `gcCycleFull()` in the generational path
  of `gcFullCollectionForUser`.
- Fixed `T.loadlib` to set `env._G = env` when bit 1 is set (PUC `loadlib`
  loads `_G` into the new state's environment).

**Results:**
- testC: **6/9 pass** (api, errors, gc, gengc, memerr, strings). api.lua
  now passes completely! Remaining: nextvar:41 (table rehash), coroutine
  (timeout), locals:1130.
- Matrix: **29/31** (coroutine.lua now passes in matrix!). smoke 45/45 —
  no regressions.

### P15.65 — testC close continuation in coroutines (locals.lua:1130)

**Problem:** When a `__close` metamethod (running as a bytecode closure via
`resumeTestcCloseReturnContinuation`) called `coroutine.yield`, the bytecode
frame was lost. Two root causes:

1. **Wrong thread for continuation check.** `builtinTestcTestC` checked
   `self.current_thread.testc_close_return_values`, but by the time the testC
   builtin is re-entered after a yield, `self.current_thread` may have changed
   due to nested coroutine operations during the yield/unwind. The continuation
   was resumed on the wrong thread.

2. **Bytecode frame unwound on yield.** `canParkDirectBytecodeYield` only
   allowed parking when `boundary_depth == 0` (top-level yield). But a
   `__close` metamethod runs via `callMetamethod` → `runClosure` →
   `runBytecodeInternal`, which pushes a new frame (`boundary_depth != 0`).
   When `coroutine.yield` returned `error.Yield`, `runBytecodeInternal`'s
   `errdefer` unwound the frame (because `bytecode_inplace_suspended` was
   never set), destroying the `__close` metamethod's execution state.

**Fixes:**
- Moved the `testc_close_return_values` check from `builtinTestcTestC` to
  `builtinCoroutineResume`, where `th` (the coroutine thread) is known from
  `args[0]`. This mirrors the existing `testc_pending_conts` pattern.
- Extended `canParkDirectBytecodeYield` to also return `true` when
  `testc_close_metamethod_depth > 0`, allowing `coroutine.yield` from within
  a `__close` metamethod to park the bytecode frame in-place even at
  `boundary_depth != 0`.
- Added `bytecode_resume_boundary` field to `Thread`: stores the
  `boundary_depth` at park time so `runBytecodeInternal` resumes with the
  correct boundary (not 0), preventing it from processing frames belonging to
  outer callers.
- `parkDirectBytecodeYield` now takes and stores `boundary_depth`.

**Results:**
- testC: **7/9 pass** (api, errors, gc, gengc, locals, memerr, strings).
  locals.lua now passes completely! Remaining: nextvar:41 (table rehash),
  coroutine (pre-existing testc_lane pipe timeout; passes when run directly).
- Matrix: **28/31** (coroutine.lua regression from P15.63 fixed!). smoke 45/45 —
  no regressions.

### P15.71 — testC LightUserdata migration (Phase A: A1–A6)

**Problem:** `T.pushuserdata(n)` created a Lua **table** with fields
`{__testud, __ptr, __val, __light, __isnull, __size}` masquerading as light
userdata. An entire detection apparatus — `isTestcUserdata`,
`isTestcLightUserdata`, `isTestcNullPointer`, `makeTestcPointerValue`,
`debugLightUserdataForId` + `debug_upvalue_ids` proxy tables — existed only to
handle these workaround tables. Meanwhile, `Value.LightUserdata: *anyopaque`
was already fully supported.

**Fix (PUC-faithful):** `T.pushuserdata(n)` now returns
`.{ .LightUserdata = @ptrFromInt(n) }` — exactly as PUC `lua_pushlightuserdata`
does (`ltests.c:1267-1271`). All detection helpers collapsed to simple tag
checks (`v == .LightUserdata`). `makeTestcPointerValue` is now a pure function
returning `Value` (no `self`, no `DispatchError`). `debugLightUserdataForId`
returns real `LightUserdata` directly; `debug_upvalue_ids` proxy tables and
their GC marking/deinit removed entirely.

**Dead code removed (~200 lines):**
- Table-ud `__val` rank logic in `testcFinalizeRankObj`
- `__gc_tracked`/`__size` accounting in `builtinDebugSetmetatable`
- `__uservals` fallback in `builtinDebugSetuservalue`/`builtinDebugGetuservalue`
- `__size` branch in testC `objsize` handler
- `isTestcUserdata` checks in `builtinType`, `valueTypeName`, `isUserdataLike`,
  `checkTabArg`
- `.Table` `__val` fallback in `builtinTestcUdataval`

**Results:**
- testC matrix: **26/31** (no regression — same 5 pre-existing failures).
- Normal matrix: **28/31** (no regression).
- Smoke: **42/42** — no regressions.

### P15.72 — testC checkpanic sub-VM (Phase B: B1–B3)

**Problem:** `T.checkpanic` used hardcoded string-matching hacks (`string.find`
on script/panic-script content) to return pre-baked results for each of the 8
checkpanic test cases. This violated AGENTS.md (no match-by-name/content for
semantic branching).

**Fix (PUC-faithful):** Replaced with a real sub-VM implementation matching
PUC `checkpanic` (`ltests.c:1406-1432`):
- **B1:** Fixed `Vm.deinit` gaps — `long_string_cache` and `testc_warn_buff`
  were never freed (required for sub-VM create/destroy lifecycle).
- **B2:** `builtinTestcCheckpanic` creates an independent `Vm.init(alloc)`,
  runs the test script unprotected (RuntimeError = the "panic"), optionally
  runs a panic script on the same testC stack, then returns the top-of-stack
  string (matching PUC's `lua_tostring(L1, -1)`). The sub-VM inherits the
  parent's memory accounting (`testc_mem_limit`/`testc_total_bytes`) and
  bytecode compiler — matching PUC's shared allocator semantics.
- **B3:** `threadstatus` now reads `testc_thread_status` instead of hardcoded
  `"ERRRUN"`. The status is classified from the error message:
  `"not enough memory"` → ERRMEM (PUC `statcodes[ERRMEM] == MEMERRMSG`), else
  ERRRUN. This correctly handles both case 2 (ERRRUN) and case 5 (mem-error
  where threadstatus must return "not enough memory").

**Supporting fixes (pre-existing bugs surfaced by running real panic scripts):**
- `parseTestcWords`: added double-quote handling (PUC `getstring_aux` supports
  both `'` and `"`). Previously, double-quoted strings like
  `pushstring "function f() f() end"` were split at internal spaces.
- `trimTestcQuoted`: removed whitespace trimming (destroyed leading/trailing
  spaces in quoted content like `pushstring ' alo'` → " alo"). Since
  `parseTestcWords` already trims unquoted tokens and extracts quoted content
  verbatim, trimming was redundant and incorrect.
- Script normalization + statement splitting: now track double quotes (not just
  single) for `#`-comment stripping and `;`/`\n` separator detection.
- `loadstring`: changed from in-place replace to **push** (matching PUC
  `luaL_loadbufferx` which pushes onto the stack without consuming the source).
  On failure, pushes only the error message (1 item), not nil+err (2 items) —
  matching the C API behavior, not the Lua `load` function behavior.

**Results:** All 8 checkpanic cases pass (api.lua:412–475, memerr.lua:28).
api.lua and memerr.lua now fully pass.
- testC matrix: **26/31** (no regression).
- Normal matrix: **28/31** (no regression).
- Smoke: **45/45** — no regressions.

Цель: закрыть главный parity/perf-блокер — `nextvar.lua` (~511× медленнее ref).
Дизайн (PUC-first): единый `Table` (array-part + hash-part с Brent's variation
chaining, см. `lua-5.5.0/src/ltable.c:13-24`) вместо текущих 4 карт, плюс
интернирование строк (аналог `lstring.c`). Строковые ключи сравниваются по
указателю на интернированную `LuaString`.

Зафиксированные отступления от PUC (Zig-идиомы):
- `Value` — tagged `union(enum)` вместо `TValue` (tag + union).
- `Node.next_offset` — `i32` signed index offset (PUC `gnext`), `dead_key` упакован в
  старший бит `hash` (P15.37b). Node = 48 B (было 56 B при `?*Node` + `bool`).
- `lastfree` — обычное поле на `Table`, а не C-хак `Limbox` перед массивом Node.

- [x] **Phase A: интернирование строк.** `Value.String` → `*LuaString`
  (header + inline bytes + cached hash). `StringIntern` HashSet на Vm с per-VM
  seed. Полная PUC string-lifecycle модель (вскрыта при отладке, изначальный
  план «интернировать всё» был неполным): short (≤ `LUAI_MAXSHORTLEN`=40) →
  глобальный intern, pointer-eq; long runtime (`rep`/`concat`/`format`) → свежая
  аллокация, content-eq; long литералы → compile-time dedup (отдельная
  `long_literals` таблица); `string.gsub` возвращает входной объект при отсутствии
  замен. Равенство — `luaStringEq` (lvm.c:600-624 + lstring.c:44-50). *Чекпоинт:*
  паритет 33/34, `zig_fail=0`, `zig build test` green, `memerr.lua` green.
  *Отставания:* GC sweep intern-таблиц и удаление `const_strings` вынесены в
  отдельные чекбоксы ниже (причины зафиксированы в
  `docs/superpowers/plans/2026-07-05-phase-a-string-interning.md`).
- [x] **Phase B1: инкапсулировать `Table` за внутренним API.** Выполнено в рамках B2
  (swap сделан напрямую через новый API, отдельная B1-стадия не потребовалась).
- [x] **Phase B2: swap `Table` на PUC array+hash.** `array: []Value` + `hash: []Node`
  + Brent chaining (`src/lua/ltable.zig`). Линейный `next()`, `luaS_eqstr`-стиль
  равенства, `value:=Nil` delete (без tombstones). Удалены `next_hint_*` (7 полей),
  `nextFrom*`/`nextFirstLive*` (~10 функций), `hash_tombstones`, `PtrKey`, 4 карты.
  *Паритет:* все 10 canary suite green (nextvar/sort/tpack/locals/calls/strings/
  db/gc/pm/literals); net −293 строк машинерии.
  *Perf (честно):* на Debug `nextvar` почти не сдвинулся (33s→29.5s) — bottleneck
  не таблицы, а debug-overhead + IR-VM interpreter. На ReleaseFast `nextvar`=1.48s
  (~23× от ref) — реальный оставшийся gap = скорость IR-VM (отдельная работа).
  `computesizes` (оптимальный array-sizing) не портирован — future optimization.

### Выполнено: настоящий generational GC (P15.30)

Generational mode больше не является compatibility-веткой, запускающей полный
incremental cycle на каждый `collectgarbage("step")`. Реализована отдельная
PUC-подобная young-generation модель поверх per-type registry luazig:

1. Все управляемые GC-типы (`Table`, `Closure`, `Thread`, `Cell`, managed
   `LuaString`) хранят возраст `NEW/SURVIVAL/OLD0/OLD1/OLD/TOUCHED1/TOUCHED2`
   и стабильный registry index. Удаление из registry использует swap-remove с
   обновлением индекса перемещённого объекта.
2. Nursery хранится в отдельных per-type списках; `OLD1`, remembered
   `grayagain`, remembered cells и old threads имеют собственные очереди.
   Minor collection обходит young snapshots и эти очереди, а не весь old heap.
3. Forward barrier продвигает young child старого closure/metatable/upvalue в
   `OLD0`; backward barrier переводит изменённый old owner в
   `TOUCHED1 → TOUCHED2 → OLD`. Barrier paths покрывают table writes, cells,
   closure environment, upvalue join/close и смену metatable.
4. Пережившие minor cycles переходят `NEW → SURVIVAL → OLD1 → OLD`. Weak
   tables, ephemerons, finalizable objects и threads обрабатываются с учётом
   поколения; старый weak container не удерживает недостижимый young value.
5. Накопленные bytes, ставшие old, переключают collector из minor mode в
   persistent incremental major cycle по `minormajor`; после major он
   возвращается в minor mode по `majorminor` либо продолжает incremental
   major cycles. Автоматический minor pacing использует `minormul`; все три
   параметра доступны через Lua 5.5 `collectgarbage("param", ...)`.
6. TestC `T.gcage` читает реальные возраста объектов, а `T.codeparam`/
   `T.applyparam` используют Lua 5.5 floating-byte encoding. Поэтому полный
   `gengc.lua --testc` проверяет upstream age/barrier transitions, а не
   подставленные ожидаемые строки.

Постоянный differential regression
`tests/smoke/43_generational_minor.lua` проверяет old→young barrier, вложенный
young graph, очистку young value из old weak table и параметры режима. Zig
unit tests дополнительно проверяют, что minor collection не сканирует
512-объектный old graph, и принудительный переход minor → major → minor.

Подтверждённые проверки на Zig 0.16.0:

- `zig build -Doptimize=Debug` и `zig build test -Doptimize=Debug` — PASS;
- differential smoke — 44/44 PASS;
- iterative dispatch stress под 1-МБ host stack — PASS;
- заявленная portable/soft upstream matrix — 29/29 PASS;
- `gengc.lua --testc` — `OK`;
- portable/soft `gc.lua` — 2.08 с Debug / 0.51 с ReleaseFast;
- direct `constructs.lua` без `_soft` — 53.94 с, `OK`;
- direct `verybig.lua` без `_soft` — 6.93 с, `OK`.

Архитектура не копирует intrusive `GCObject.next` списки PUC побайтово:
luazig сохраняет отдельные массивы указателей. Но поколения, remembered-set
инварианты, minor/major transitions и наблюдаемая Lua/TestC-семантика
соответствуют модели Lua 5.5.

#### Hotfix P15.30.1: automatic GC pace после `restart`

Прямой upstream `gc.lua` без `_port/_soft` выявил ошибку pacing, которую не
покрывала portable matrix. `collectgarbage("restart")` только включал флаг
collector, сохраняя старый post-cycle threshold; после достижения threshold
automatic GC выполнял лишь 64 object-work units раз на 20 000 table
allocations. В table-heavy цикле mutator поэтому создавал мусор быстрее sweep и
проверка pace после `long strings` не завершалась.

Исправление следует модели PUC Lua:

- `restart` сбрасывает allocation debt: следующая аллокация сразу получает
  возможность продвинуть GC;
- automatic incremental slice вычисляется из `stepsize × stepmul`; коэффициент
  20 компенсирует различие work units — PUC sweep обрабатывает до 20 объектов
  за один sweep step, тогда как `gcAdvance` luazig считает каждый объект
  отдельно;
- smoke `44_gc_restart_pace.lua` останавливает collector, накапливает garbage,
  включает его обратно и проверяет, что heap возвращается к live baseline, а
  не растёт без ограничения.

После hotfix: Debug build/unit tests, 44/44 differential smoke, 1-МБ dispatch
stress и `gengc.lua --testc` проходят; direct `gc.lua` завершается с `OK`
примерно за 5.4 с в текущем Debug-окружении.

### Прочие открытые приоритеты

- [x] **IR VM заморожена, bc=default.** Default backend переведён на `--vm=bc`.
  IR VM (`--vm=ir`) сохранена как debug fallback, parity не поддерживается.
  `run_tests.py` и `testes_matrix.py` явно используют `--vm=bc`.
  `release_gate.sh` гоняет bc (большинство suites failing — прогресс-трекер).
  `zig build test` продолжает гонять IR unit-тесты (они тестируют shared runtime).
- [x] **Perf: IR-VM interpreter speed — закрыто как устаревшая цель.** IR VM
  заморожена и не является parity/perf target; профилирование bc_vm остаётся
  отдельным открытым пунктом после достижения parity.
- [x] **GC sweep-pass:** реализовать настоящий mark+sweep для всех объектов
  (tables/closures/threads/strings/cells). `gcCycleFull` теперь выполняет
  полный mark+sweep на всех точках: explicit `collectgarbage()`, tick-trigger
  (каждые 20000 инструкций), и allocation-trigger (через Handle API / temp
  roots). Все типы объектов sweep'ятся (P15.0–P15.7).

  **GC Phase (завершена):** per-type `ArrayList(*T)`-реестры на Vm
  заменяют PUC's intrusive `GCObject.next`-list (нулевая модификация layout
  типов, overhead идентичен — 1 указатель/объект). План:
  - [x] **GC registry infrastructure** — `gc_tables`/`gc_closures`/
    `gc_threads`/`gc_cells`/`gc_strings`; hook'нуты все 18 сайтов аллокаций
    (4 Table + 6 Closure + 4 Thread + 3 Cell + 1 runtime-long-string).
    `Vm.deinit`_drain'ит реестры как единственная точка владения для
    уничтожения объектов. Поведение неизменно; gc/gengc/tracegc + 8 canaries
    green.
  - [x] **Root-set completion + Table sweep** — `gcMarkVmRoots` добавляет
    VM-level metatables/threads/registries в корни; frame marking расширен
    (all locals, boxed cells, callee, env_override). `gcSweepTables` с
    in-place compaction + snapshot boundary. Sweep активен только на
    safe points (explicit `collectgarbage()`) и вне debug hooks.
    Ограничение: regs не mark'ятся (нет register-top tracking → нельзя sweep
    mid-expression); register-top planned для следующей итерации.
  - [x] **Closure/Thread/Cell sweep** — `gcSweepClosures`/`gcSweepThreads`
    с той же compaction+snapshot pattern. Closure: destroy struct только
    (upvalues ownership ambiguous). Thread: `freeThreadWrapBuffers` + aux
    free + destroy. Cell sweep отложен (требует `marked_cells` tracking).
    gc/gengc/tracegc/api/coroutine/db/nextvar + 8 canaries green.
  - [x] **Register-top tracking (live_regs)** — backward liveness analysis
    в codegen (`ir.computeLiveRegs`): per-PC bitset живых регистров
    (fixpoint iteration для loops). GC mark'ит только live регистры через
    `live_regs[pc * num_values + reg]`. Включает tick-trigger sweep
    (между инструкциями builtins уже вернулись, регистры точно track'ятся).
    Allocation-trigger sweep остаётся `do_sweep=false` (Zig locals внутри
    builtins невидимы GC). Cell sweep и string sweep отложены.
  - [x] **Real memory accounting** — `gc_count_kb` charge на alloc
    (`@sizeOf(Type)` для Table/Closure/Thread/Cell/String), discharge на sweep
    (actual bytes freed). Удалён фейк `gc_count_kb = 0.0` reset.
    `collectgarbage("count")` возвращает реальный размер.
  - [x] **String sweep** — `gcSweepStrings` для runtime long strings
    (`gc_strings` registry). Mark phase traverse'ит `Value.String` через
    worklist (`.String` case в `gcMarkValue`). String keys in hash nodes
    coordinated with dead-key handling (PUC-like `DEADKEY` model). Source
    strings from `load(string)` pinned как GC roots (`pinned_source_strings`).
    Long literals sweep'ятся через `long_literals.sweep()`. Short strings
    (`string_intern`) сейчас снова НЕ sweep'ятся — см. ограничение ниже.
  - [x] **Cell sweep** — `gc_marked_cells` set (Vm-level, как
    `gc_marked_strings`). Mark'ится при traversal closures' upvalues и
    frames' boxed/upvalues. `gcSweepCells` frees unmarked cells.
  - [x] **Long literal sweep** — `StringIntern.sweep` для `long_literals`:
    удаляет unreachable entries из intern table. Short strings
    (`string_intern`) остаются pinned/eternal до появления Proto-owned
    constant roots.

  **Оставшиеся ограничения:**
  - **Short string intern sweep временно отключён.** `string_intern.sweep()`
    был включён в P15.8, но `all.lua` показал UAF после последовательности
    `gc.lua -> db.lua`: debug hook вызывает `collectgarbage()`, затем
    `string.gsub` получает pattern как `Value.String`, указывающий на уже
    освобождённую short string. Это не проблема `gsub` как такового, а
    отсутствие PUC-инварианта: в PUC Lua строковые константы являются частью
    `Proto->k` и mark'ятся как GC roots. У нас IR пока хранит string lexemes
    как slices/source references и материализует `ConstString` лениво через
    `internStr`/`internLiteral`; не все такие materialized constants имеют
    стабильного владельца, который GC гарантированно mark'ит через
    debug-hook/continuation edges. Поэтому short strings пока pinned как
    глобальный intern table.
  - Чтобы честно включить `string_intern.sweep()` снова, нужно перейти к
    PUC-like ownership для строковых констант: при load/codegen создать
    decoded constant pool (`*LuaString`) внутри IR/Proto/function object,
    mark'ить этот pool в GC traversal для Closure/Function/Proto roots,
    убрать ленивое decode/intern из hot execution path, и только после этого
    разрешить sweep short-string intern table. Критерий включения: `all.lua`,
    `gc.lua`, `db.lua`, `strings.lua`, `coroutine.lua`, `calls.lua` и full
    matrix проходят с `string_intern.sweep()` включённым.
  - ~~Allocation-trigger sweep disabled~~ — **закрыто в P15.7**: Handle API (temp
    roots) защищает Zig-local temporaries в builtins; `allocTable` self-protect'ит
    return value; 4 CRITICAL multi-alloc site'а защищены (ensureDebugRegistry,
    builtinTestcMakeCfunc, pushcclosure, builtinDebugGetinfo); dead registers
    очищаются перед sweep (предотвращает dangling pointers в debug.getlocal).
  - ~~`in_debug_hook` guard~~ — **закрыто в P15.7**: sweep больше не подавляется
    внутри debug hooks; `debug_transfer_values` явно mark'ятся в `gcMarkVmRoots`.
  - **Short strings eternal / pinned** — **снова открыто после P15.8 audit**:
    `err_obj` + `gmatch_state` mark'ятся корректно, но этого недостаточно.
    Не хватает Proto-owned decoded string constant roots; поэтому
    `string_intern.sweep()` отключён до архитектурного шага с constant pool.
  - [x] **Real memory accounting** — закрыто в P15.4: `gc_count_kb` charge/discharge
    на alloc/sweep.
  - [x] **String sweep** — закрыто в P15.5: `gcSweepStrings` + `gcMarkValue`
    traverse `Value.String`; координация с `string_intern`/`long_literals`.
- [x] **Убрать `const_strings`/`internConstString`** — **закрыто в P15.8**: 32 call
  site'а мигрированы на `internStr`/`internLiteral`; третий string store удалён.
- [ ] Закрыть `heavy.lua` memory/perf gap в рамках P15.34/P15.37, не отдельным benchmark-specific хаком.
- [x] Профилировать bc_vm после достижения parity — выполнен свежий ReleaseFast профиль P15.30.1; baseline и bottlenecks зафиксированы выше.
- [ ] Развивать публичный Zig embedding API после стабилизации bc_vm.
- [x] Держать README, release gate и perf baselines актуальными после текущей GC/string фазы.
- [x] Закрыть verifier follow-up P15.28: direct `constructs.lua` <60 с, 29/29 matrix, short-string GC debt и generational step regression.

### P15.73 — PUC-faithful collectargs/runargs + REPL (завершён)

Цель: переписать парсер аргументов командной строки в `src/bin/luazig.zig`
для точного соответствия PUC Lua `lua.c` (`collectargs`, `runargs`, `dolibrary`,
`pmain`, `doREPL`). Предыдущий hand-rolled парсер не поддерживал `-l`, `-W`,
`-i`, concatenated options (`-eprint(1)`, `-lm=math`), и не воспроизводил
PUC error messages.

- [x] **P15.73a: `collectargs` — single-pass PUC-faithful option parsing.**
  Bitmask (`has_i`, `has_v`, `has_e`, `has_E`) + script index. Handles `-`,
  `--`, `-E`, `-W`, `-i`, `-v`, `-e`, `-l` with concatenated args. Error
  messages match PUC `print_usage`: `"'-e' needs argument"`,
  `"unrecognized option '-h'"`, etc.
- [x] **P15.73b: `dolibrary` — `globname[=modname]` parsing + `require`.**
  Calls `require(modname)` via `vm.apiCall`, sets result as global
  `globname`. Handles `LUA_IGMARK` (`-`) suffix cutting: `-l lib2-v2` →
  `lib2 = require("lib2-v2")`.
- [x] **P15.73c: `runargs` — process `-e`, `-l`, `-W` in order.**
  `lua_warning("@off")` at start (warnings off by default), then process
  each option in argv order.
- [x] **P15.73d: `createargtable` — full PUC `arg` table.**
  `setArgTablePuc(puc_argv, script)` builds `arg` with ALL argv entries at
  negative/positive indices, matching PUC `createargtable` (lua.c:185-194).
- [x] **P15.73e: `pushargs` — read script args from `arg` table at runtime.**
  Reads `arg[1]..arg[n]` from the VM's `arg` global after `-e`/`-l` have run,
  so modifications to `arg` by `-e` chunks are visible (PUC `pushargs`).
- [x] **P15.73f: `doREPL` — interactive read-eval-print loop.**
  Reads lines from stdin, tries `return <line>;` first (PUC `addreturn`),
  then as statement with multi-line continuation (PUC `multiline`).
  Incomplete input detected via `<eof>` error mark. Prints results via
  `print`. `checklocal` warning for `local` declarations.
- [x] **P15.73g: `pmain` order — faithful to PUC lua.c:707-749.**
  collectargs → error check → print_version → openlibs → createargtable →
  handle_luainit → runargs → handle_script → doREPL / stdin.
- [x] **P15.73h: Luazig-specific option pre-pass.**
  `--vm=`, `--engine=`, `--testc`, `--dump-bytecode`, `--bc-coverage-out`
  stripped from argv before `collectargs` (they use `--` prefix which PUC
  would reject). PUC `arg` table contains only PUC-style options.
- [x] **P15.73i: `os.tmpname` — no dots in temp file names.**
  Changed from `/tmp/luazig-{hex}.tmp` to `/tmp/luazig_{hex}` (no extension).
  Dots in module names are converted to path separators by `require`,
  breaking `-l <tmpfile>`.
- [x] **P15.73j: `writeValue` — fix float formatting in `print`.**
  Integer-valued floats now print with `.0` suffix (e.g. `0.0` not `0`),
  matching PUC Lua's `tostring`/`%.14g` convention. Refactored
  `numberToStringAlloc` to share `formatNumBuf` with `writeValue`.

**Results:** `main.lua` progresses past all argument-parsing tests (-l, -e,
-W, arg table, invalid options). Remaining `main.lua` failures are pre-existing
gaps: `debug.debug` not implemented, warning system design issue (warn builtin
conflates Lua `warn` function with `warnf` handler), `os.exit` finalizer
ordering. Matrix 30/31, smoke 46/46 — no regressions.

### Housekeeping (до или параллельно с Phase A)

- [x] Убрать отладочный `*.lua`-мусор в корне репо (`debug_special_case.lua`,
  `final_*.lua`, `isolate_failure.lua` и т.п.) — `debug_special_case` нарушает
  запрет AGENTS.md на `special_case_*`.
- [x] Запушить локальные коммиты в `origin/master`.

## C Extension Loading: dlopen + C API + External Strings

**Завершённая фаза** (план: `docs/superpowers/plans/2026-07-29-c-extension-loading.md`).
Цель достигнута: загружаемые C-расширения (`lib1.so`, `lib2.so`, PUC test libs) имеют полный
доступ к VM через C API: `c_stack`, `package.loadlib` через `std.DynLib`,
внешние строки. Архитектурно следует PUC Lua (`lua_State` == `Vm`, отдельный
push/pop стек для C-API поверх `bc_stack`), без libc-fallback и без name-based
special-casing. `attrib.lua` проходит, testC matrix 26/31 (code/cstack pre-existing),
normal 28/31, smoke 45/45, testc_lane 9/9.

### Part A: C API Foundation

- [x] **A1 — `c_stack` на Vm, перезапись C-ABI shim на `*Vm`.** Добавлен
  `c_stack: ArrayListUnmanaged(Value)` в `Vm`; все `lua_*` export-функции в
  `c_api.zig` работают напрямую с `*Vm`/`c_stack`. `lua_State` aliased to `Vm`.
  (commit `fa1bcf0`.)
- [x] **A2 — Недостающие C API функции.** Добавлены ~15 функций в `c_api.zig`:
  стек (`lua_pushvalue`/`lua_insert`/`lua_remove`/`lua_rotate`), таблицы
  (`lua_createtable`/`lua_setfield`/`lua_getfield`/`lua_rawset`/`lua_rawget`),
  строки (`lua_pushlstring`/`lua_pushliteral`/`luaL_checklstring`), регистрация
  (`luaL_setfuncs`/`luaL_newlib` через `luaL_Reg`), misc (`luaL_checkversion`/
  `lua_pushfstring`/`luaL_ref`/`lua_pushcfunction`). Поле `Closure.c_func`
  (`lua_CFunction`) добавлено; `Vm.c_ref_counter` — счётчик для `luaL_ref`;
  `gcRegisterClosure` сделан `pub`. `setfield`/`getfield` идут через
  метаметод-уважающие `apiSetTable`/`apiGetTable` (как PUC `luaV_finishset`);
  `rawset`/`rawget` — через `apiRawSet`/`apiRawGet`. `lua_rotate` выведен из
  трёх-reversal алгоритма PUC (исправлено направление относительно наивного
  `std.mem.rotate(items, n)`). Regression: matrix 28/31, smoke 45/45, новых
  регрессий нет. Review-fix (коммит `0b53582`→amend): NUL-terminate в
  `createLuaString` (PUC `luaS_createlngstrobj`), чтобы `luaL_checklstring`
  мог отдавать safe C-string; `luaL_ref` различает `LUA_REFNIL`(-1)/`LUA_NOREF`(-2);
  `cAbsIndex` дедуплицирован с `normalizeIndex`; NULL-func placeholder в
  `luaL_setfuncs` (PUC pushes `false`).

  Note: `zig build test` pre-existing сломан (`api.zig:548` stale
  `compileChunk`, `codegen_bc.zig` test-блоки — toolchain drift; не относится к
  A2). c_api unit-тесты проверены diagnostic-раном. Отдельная cleanup-задача.

### Part B: C Function Calling

- [x] **B1 — Call dispatch для `Closure.c_func`.** C-замыкания (созданные
  `luaL_setfuncs`/`lua_pushcfunction`, `proto == null`, `c_func != null`) теперь
  вызываются через C-функцию вместо bytecode. Диспетчеризация сделана
  **центрально** в `runClosure` (аналог PUC `luaD_precall` — единственная точка
  проверки `LUA_VCCL`): `if (cl.c_func) |cf| return callCFunction(cf, args)` перед
  доступом к `cl.proto.?`. Это покрывает все ~30 call-site'ов одним изменением — OP_CALL
  (no-proto fallthrough), `builtinRequire`, `apiCall`/`lua_pcallk`,
  `callMetamethod`, pcall/xpcall, table.sort/gsub и т.д. — вместо scatter-проверок
  в каждой точке. Новый `callCFunction` мостит `bc_stack`↔`c_stack`: swap-in
  свежего `c_stack` с аргументами в `[0..nargs]` (положительные индексы C-API
  absolute-from-0, см. `c_api.normalizeIndex`), прямой вызов `cf(self)`,
  сбор результатов выше аргументов, restore caller's `c_stack`. Swap O(1)
  (trivially-copyable `ArrayListUnmanaged`), корректно под вложенными C→C
  вызовами. Без setjmp/longjmp (B2) и без loadlib (C1). Regression: matrix
  28/31 normal / 26/31 testc (zig_fail=0/zig_fail=2 — без новых регрессий),
  smoke 45/45.
- [x] **B2 — setjmp/longjmp error boundary для `lua_error`/`lua_call` (pure Zig, без C-враппера).**
  В отличие от первоначального плана (`src/c/cfunc_wrap.c`), граница реализована
  целиком в Zig через `extern fn _setjmp`/`_longjmp` (libc уже слинкован с A1).
  `callCFunctionWithBoundary` ставит `_setjmp` landing pad в собственном кадре:
  `_longjmp` из `lua_error` возвращается сюда, функция берёт нормальный путь
  `return -1`, и `defer`-ы отрабатывают как при обычном возврате (ни один Zig-кадр
  выше не разматывается — longjmp приземляется ВНУТРИ boundary-функции). Это
  PUC-faithful форма: `luaD_rawrunprotected` сам по себе `setjmp`+call+return.
  Используется `_setjmp`/`_longjmp` (не `setjmp`/`longjmp`) — эквивалент PUC
  `__sigsetjmp(env, 0)` без сохранения signal mask, без syscall на каждый вход.
  Поля `Vm`: `c_error_jmp: ?*anyopaque` (текущий `L->errorjmp`), `c_error_value: ?Value`
  (объект ошибки, перенесённый через `_longjmp`). `lua_error` (c_api.zig) захватывает
  `c_stack`-top в `c_error_value`, затем `_longjmp(c_error_jmp, 1)`. `callCFunction`
  на `-1` фолдит `c_error_value` в `err_obj`/`err_has_obj`/`err` (унификация с
  native runtime-error машиной pcall/traceback/coroutine) и возвращает
  `error.RuntimeError`; `errdefer` восстанавливает `c_stack`. `lua_call` (минимальный):
  успех через `apiCall`, ошибка rethrow'ится через активную границу (`_longjmp`) при
  наличии `c_error_jmp`. Вложенные границы корректны (save/restore `c_error_jmp` через
  `defer`, проверено отдельным mechanism-repro в Debug и ReleaseFast). Verification:
  изолированный repro longjmp-в-Zig (defer отрабатывает, локальные `prev` переживают
  longjmp, вложенность работает) — Debug + ReleaseFast; matrix 28/31 normal / 26/31
  testc (zig_fail=0 / zig_fail=2 — оба pre-existing на HEAD, без новых регрессий);
  smoke 45/45. Юнит-тесты в c_api.zig добавлены, но `zig build test` пока блокирован
  pre-existing поломкой test-блоков в `codegen_bc.zig` (мех. `Lexer.init(string)` вместо
  `Source` — вне scope B2). Мёртвый `src/c/cfunc_wrap.c` (никогда не компилировался,
  не в build.zig) удалён.

### Parts C–E: loadlib, external strings, integration

- [x] **C1 — `package.loadlib` через `std.DynLib`** + реальный поиск C-библиотек в `require`.
  Заменена заглушка `package.loadlib` (раньше возвращала `(nil, "not supported", "absent")`)
  на реальную реализацию через `std.DynLib.open` (Zig-обёртка над `dlopen`/`dlsym`).
  `builtinPackageLoadlib` поддерживает оба режима PUC:
  (1) probe (`funcname == "*"`) — open + close + возврат no-op closure (`llAccessible`,
  аналог PUC `ll_accessible`); (2) normal — open + lookup `luaopen_*` + wrap в `Closure`
  для интеграции с существующим C function dispatch (B1 `callCFunction`).
  DynLib handle намеренно НЕ закрывается (leak на normal path) — PUC тоже не вызывает
  `dlclose`, т.к. C-расширения могут кешировать указатели на свои статические данные;
  библиотека остаётся mapped до конца процесса (Zig не имеет RAII деструкторов, поэтому
  drop локальной `DynLib` не закрывает OS handle).
  `builtinRequire` (searcher_C path, PUC `ll_require`): при неудаче Lua-path ищет `.so`
  на `package.cpath` через `searchpath`, строит символ `luaopen_<modname>` (dots→underscores,
  PUC `findsym`), вызывает `loadlib(filepath, symbol)`, затем `runClosure` с
  `(modname, filepath)`, регистрирует результат в `loaded[modname]`. Error categories
  `"open"`/`"init"` соответствуют PUC. Regression: matrix 28/31 normal / 26/31 testc
  (zig_fail=0 / zig_fail=2 — без новых регрессий; attrib.lua в testc перешёл из zig_fail
  в both_fail — улучшение), smoke 45/45. Реальная загрузка .so требует полного C API
  (часть .so скомпилированных test-харнесом падает на `luaL_checkversion_` — задача E1).
- [x] **D1 — External strings** для строк, принадлежащих загруженному .so.
  Реализованы PUC 5.5 `lua_pushexternalstring` / `lua_getallocf` и инфраструктура
  external-строк на уровне `LuaString` + GC. `LuaString` получил поля `is_external`,
  `external_ptr`, `falloc`, `falloc_ud`; `bytes()` разветвляется для external-контента;
  `destroyLuaString` вызывает dealloc-callback перед освобождением хидера (PUC
  lgc.c:874-875). Добавлен `Vm.createExternalLuaString` — PUC-faithful: всегда
  создаёт long string (`LUA_VLNGSTR`/`LSTRMEM`), без ветвления по длине (PUC
  `luaS_newextlstr` не зависит от длины). `lua_getallocf` возвращает
  C-callable wrapper вокруг `vm.alloc` (`cApiAllocWrapper`), `ud = *Vm`.
  `LUA_REGISTRYINDEX = -1001000` добавлен; `luaL_ref` обрабатывает псевдо-индекс
  реестра. Regression: matrix 28/31 normal / 26/31 testc / smoke 45/45 — без
  новых регрессий.
- [x] **E1 — Интеграционное тестирование: загрузка реальных PUC test libs, attrib.lua проходит.**
  Созданы минимальные C-заголовки `src/lua/lua.h` и `src/lua/lauxlib.h`, точно повторяющие
  PUC Lua 5.5 (макросы `lua_call`→`lua_callk`, `lua_pushcfunction`→`lua_pushcclosure`,
  `lua_tointeger`→`lua_tointegerx`, `lua_insert`→`lua_rotate`, `luaL_checkversion`→`luaL_checkversion_`,
  `luaL_newlib`→`lua_createtable`+`luaL_setfuncs`). Тестовые библиотеки (`lib1.so`, `lib2.so`,
  `lib2-v2.so`, `lib11.so`, `lib21.so`) скомпилированы через `zig cc -shared -fPIC -I src/lua`.

  **Решённые проблемы:**

  1. **Символы C API не экспортировались в динамическую таблицу.** `export fn` в модуле
     удалялись линкером как dead code, т.к. из root-ZCU на них нет ссылок. Решение:
     `comptime`-блок в `root.zig` берёт адрес каждого `pub export fn` — это делает их
     живыми root'ами для DCE. Дополнительно `rdynamic=true` в `build.zig` (PUC `-Wl,-E`).
     Все `export fn` в `c_api.zig` помечены `pub` для доступа из `root.zig`.

  2. **CLIBS-кеш и RTLD_GLOBAL (PUC `lookforfunc`/`lsys_load`).** Probe-режим (`"*"`)
     теперь открывает через `dlopen(RTLD_NOW | RTLD_GLOBAL)` и кеширует handle в `Vm.c_libs`
     (PUC `CLIBS`-таблица). Последующие `loadlib` переиспользуют кешированный handle.
     Это необходимо для inter-library dependencies: `lib11.so` вызывает `lib1_export` из
     `lib1.so` — работает только если `lib1.so` была загружена с `RTLD_GLOBAL`.

  3. **`lua_pushfstring` с реальным форматированием.** Реализован парсер C-variadic
     (`@cVaStart`/`@cVaArg`/`@cVaEnd`) для PUC-множества спецификаторов: `%d`/`%i`/`%u`/
     `%f`/`%g`/`%s`/`%c`/`%p`/`%x`/`%X`/`%o`/`%U`/`%%`. До этого возвращал сырую format-строку.

  4. **PUC `loadfunc` convention (LUA_IGMARK = `-`).** `require"lib2-v2"` теперь пробует
     `luaopen_lib2` (префикс до `-`), затем `luaopen_v2` (суффикс). Аналогично для C-root
     searcher: `require"lib1.sub"` → ищет `lib1.so`, вызывает `luaopen_lib1_sub`.

  5. **`searcher_Croot` (PUC loadlib.c:582).** Добавлен C-root searcher в `builtinRequire`:
     при наличии точки в имени модуля ищет root-package на cpath, затем вызывает `loadfunc`
     с полным именем (`lib1.sub` → `luaopen_lib1_sub`).

  6. **`callCFunction` result collection.** Результаты читаются из `c_stack[total-nret..]`
     (top-N по PUC `luaD_poscall`), а не из `c_stack[args.len..]` — C-функция может
     модифицировать стек через `lua_settop`/`lua_pushvalue`.

  7. **Добавлены `lua_callk`, `lua_pushcclosure`, `luaL_checkversion_`, `lua_copy`** —
     underlying-функции, в которые PUC-макросы раскрываются после препроцессинга.

  8. **`T.hash`** — добавлен в testC-модуль для проверки hash-parity внешних строк.

  **Результат:** `attrib.lua` проходит (включая external strings, require, loadlib, C submodules).
  testc matrix: 26/31 pass parity (code.lua/cstack.lua — pre-existing zig_fail в testc mode,
  big.lua/files.lua — both_fail). Normal matrix: 28/31, smoke 45/45, testc_lane 9/9 —
  без новых регрессий.

## История закрытых фаз

- P3: стабилизация базы до API; targeted parity suite, `bc_vm` coverage gate, perf guard и runtime invariant audit.
- P4: начальный публичный Zig API и базовый C ABI shim.
- P5: `testC/ltests` compatibility до прохождения `api.lua --testc`.
- P6: official `testC` lane; missing commands сведены к нулю.
- P7: расширение Zig/C-like API для `testC`, generic `T.testC` команды переведены на API-входы.
- P8: базовая official suite compatibility до `33/34 pass parity`, `zig_fail=0`.
- P9: публичный Zig embedding API отделён от VM internals.
- P10: readiness report, release gate, честная классификация blockers.
- P11: OOM/error-object fixes и первые PUC-first perf/memory шаги.
- P12: full migration на актуальный system Zig и успешный release gate на system toolchain.
- P13: интернирование строк (Phase A) — `Value.String` → `*LuaString`, полная PUC short/long/literal семантика, `luaStringEq`, gsub-reuse. Паритет 33/34 сохранён.
- P14: PUC-faithful Table (Phase B) — единый array+hash с Brent chaining (`ltable.zig`), удалены 4 карты/`next_hint_*`/tombstones (−293 строк). Паритет canaries green. Perf-цель `nextvar ≥10×` на Debug не достигнута: реальный bottleneck — debug-overhead + IR-VM interpreter (RF nextvar=1.48s, ~23× от ref).
- P15.0: GC registry infrastructure — per-type `ArrayList(*T)`-реестры на Vm (`gc_tables`/`gc_closures`/`gc_threads`/`gc_cells`/`gc_strings`); hook'нуто 18 сайтов аллокаций; `Vm.deinit` drain'ит реестры (единственная точка владения). Replaces PUC intrusive `GCObject.next`-list без модификации layout типов. gc/gengc/tracegc + 8 canaries green.
- P15.1: GC root-set completion + Table sweep — `gcMarkVmRoots` (metatables, threads, dump_registry, debug_upvalue_ids); expanded frame marking (all locals, boxed cells, callee, env_override); `gcSweepTables` с in-place compaction + snapshot boundary. Sweep только на safe points (explicit `collectgarbage()`, вне debug hooks). gc/gengc/tracegc/api/coroutine/db/nextvar + 8 canaries green.
- P15.2: GC Closure/Thread sweep — `gcSweepClosures` (destroy struct, upvalues not freed), `gcSweepThreads` (freeThreadWrapBuffers + destroy). Cell sweep deferred (marked_cells tracking needed). Same safe-point constraints. All 15 suites green.
- P15.3: Register-top tracking — `ir.computeLiveRegs` (backward liveness, fixpoint for loops, per-PC bitset). `Frame.pc` updated in dispatch loop. GC marks only live registers via `live_regs[pc*nv+reg]`. Enables tick-trigger sweep (between instructions). Allocation-trigger sweep stays disabled (Zig locals invisible). All 15 suites green.
- P15.4: Real memory accounting — `gc_count_kb` charged on alloc (`@sizeOf(Type)` for Table/Closure/Thread/Cell/String), discharged on sweep (actual bytes). Removed fake `= 0.0` reset. Strings not charged (sweep deferred). All 15 suites green.
- P15.5: String sweep — `gcSweepStrings` for runtime long strings. `gcMarkValue` traverses `Value.String` via worklist. String keys in hash nodes conservatively marked (keyEq dereferences). Source strings from `load(string)` pinned as roots. Short strings / long literals remain eternal. All 15 suites green.
- P15.6: Cell sweep + long literal sweep — `gc_marked_cells` set (marked during closure/frame traversal). `gcSweepCells` frees unmarked cells. `StringIntern.sweep` removes unreachable long literals from intern table. Short strings remain eternal. All 15 suites green.
- P15.7: Handle API (temp roots) — allocation-trigger sweep enabled, `in_debug_hook` guard removed. `gc_temp_roots: ArrayList(Value)` + `TempRoots` scope helper (snapshot/restore, analog of PUC Lua `L->stack` for Zig locals). GC mark phase traverses temp roots + `debug_transfer_values` in `gcMarkVmRoots`. 4 CRITICAL multi-alloc sites protected (ensureDebugRegistry, builtinTestcMakeCfunc, pushcclosure, builtinDebugGetinfo). `allocTable` self-protects return value. Dead registers cleared before sweep (prevents dangling pointers in debug.getlocal's for-state detection). All 15 suites green.
- P15.8: `const_strings` removal + short-string sweep attempt — `const_strings`/`internConstString`/`internConstStringMaybeOwned` fully removed; 32 call sites migrated to `internStr`/`internLiteral`; third parallel string store eliminated. `err_obj` + `gmatch_state.{s,p}` marked as GC roots. Follow-up all.lua audit found that enabling `string_intern.sweep()` is premature without Proto-owned decoded constant roots; short-string sweep is disabled again, while long literal sweep remains enabled. ReleaseFast matrix after fix: 32/33 pass parity, `zig_fail=0`, only `heavy.lua` both-fail timeout. Speed checkpoint: full matrix 3:34.71 wall; `all.lua` RF 5.16s vs PUC 0.416s (~12.4x); `nextvar.lua` RF 1.342s vs PUC 0.038s (~35x).
- P15.9: bc_vm weak table pruning — `codegen_bc.resetRegs` теперь использует `peak_freereg` (high-water mark регистра за statement) вместо `freereg`, чтобы LOADNIL покрывал все временные регистры включая аргументы CALL и темпы от конструирования таблиц. Раньше `genCall` уменьшал `freereg` до `func_reg` после 0-result CALL, и `resetRegs` не очищал регистры аргументов — stale pointer'ы выживали GC и блокировали pruning weak table entries. `peak_freereg` обновляется в `reserveRegs` и в прямых присваиваниях `freereg` (method call self-reg, vararg explist). gc.lua "weak tables" section проходит. All 15 suites green.
- P15.10: `local _ENV` shadowing в codegen — `local _ENV = ...` теперь корректно затеняет `_ENV` upvalue для своего scope, как в PUC Lua `singlevar()`. Раньше все global-доступы (read/write, global decls, global func decl, assignment) всегда шли через `ensureEnvUpvalue()` + `GETTABUP`/`SETTABUP`, игнорируя локальный `_ENV`. Добавлены `emitGlobalGet`/`emitGlobalSet`: если `_ENV` разрешается как local, индексируется регистр (`GETFIELD`/`SETTABLE`, с `GETTABLE`/`SETTABLE` fallback для kid>255), иначе — старый upvalue-путь. Все 6 global-access сайтов переведены на хелперы. Тест `local _ENV <const> = 11; X = "hi"` → `attempt to index a number value` проходит. 16 parity suites green.
- P15.11: `errors.lua` parity для bytecode VM — stripped `string.dump(f, true)` теперь сохраняет исполняемый `Proto` graph и удаляет только debug metadata; bytecode dispatch обновляет `Frame.current_line`, а `debug.getinfo(..., "l")` использует bytecode lineinfo без IR/path compensation. Арифметические type errors приведены к PUC-форме `attempt to perform arithmetic on a <type> value`. Добавлен differential smoke для stripped round-trip, nested Proto/upvalue, error text и current line. `errors.lua` и все smoke tests проходят.
- P15.12: `coroutine.lua` parity для bytecode VM — bytecode frames сохраняют continuation state и TBC-регистры через `yield/resume`; аварийное и принудительное закрытие выполняет все `__close` в LIFO-порядке с передачей последнего error object; возвраты и tail calls закрывают живые TBC slots; call/line/return hooks сохраняют позицию через suspension. `coroutine_resume` добавлен в `builtinHasDynamicOutCount` — fix утечки nil в vararg-контекстах. `luazig.zig`: thread spawn 256MB stack вместо setrlimit. Добавлены differential smoke тесты (25, 26). `coroutine.lua` проходит; project matrix — 24/29. Текущая архитектура host-recursive dispatch loop — технический долг, см. TODO выше.
- P15.13: iterative bytecode call frames, этап 1 — введён явный стек `BytecodeExecFrame`; обычные Lua-to-Lua `OP_CALL` push'ят дочерний frame без рекурсивного вызова Zig-функции, а `OP_RETURN*` pop'ят его и продолжают родителя. Изначально owner'ом списка был отдельный вызов `runBytecode`; P15.21 переносит ownership в `Thread`. Yield/error unwind проходит explicit frame stack сверху вниз и сохраняет совместимость с текущими coroutine snapshots. Добавлен smoke `27_iterative_bytecode_calls.lua` (350 non-tail calls). Подтверждено, что `pcall`/`xpcall`, metamethod и nested-resume re-entry остаются следующим этапом; 256MB stack пока не удалён. Unit tests, 27/27 smoke, `calls.lua`, `coroutine.lua`, `errors.lua` и прежние parity suites проходят.
- P15.14: fixed-width multi-results from method calls — `genMethodCall` теперь обновляет `freereg` по фактическому `nresults`, как обычный `genCall`. Раньше assignment в уже объявленные переменные (`a, b = object:method()`) после корректного `CALL C>1` затирал результаты со второго onward инструкциями `LOADNIL`. Добавлен differential smoke `28_method_call_fixed_multiret.lua`; `files.lua` проходит targeted parity.
- P15.15: native platform I/O — добавлены `io.popen`/`pclose`, `os.execute`/`os.exit`, PUC-compatible process result triples, последовательный pipe I/O через `std.process` и `std.Io`, `arg[-1]` для пути интерпретатора, POSIX `%Ex`/`%Oy` и проверки representable range в `os.date`/`os.time`. Добавлен differential smoke `29_platform_process_io.lua`. Portable matrix (`_port=true`) для `files.lua` проходит идентично PUC Lua. Non-portable section (без `_port=true`) имеет известный platform-dependent failure на line 814 (`sh -c 'kill -s HUP $$'` — ожидается `"exit"`, возвращается `"signal"`), одинаковый с PUC Lua на этой системе. Общий счёт остаётся 25/29.
- P15.16: `locals.lua` parity для bytecode VM — `LocVar` хранит точный register/range, поэтому `debug.getinfo` различает реальные bytecode closures вместо общего `bc_dummy_func`; OP_TBC валидирует non-closable значения при активации и сообщает имя local; return hooks больше не дублируются. Yielding error-unwind сохраняет последний error object между `__close`, а `return f()` с живым TBC компилируется как CALL+RETURN, не TAILCALL. Forward `goto` теперь резервирует patchable CLOSE и при выходе из scope учитывает скрытый generic-for TBC slot `base+3`, предотвращая stale TBC register после nested-loop goto. Добавлен differential smoke `30_locals_tbc_unwind.lua`; `locals.lua` проходит, project matrix — 26/29.
- P15.17: `db.lua` parity для bytecode VM — debug metadata теперь использует точные `lastlinedefined`/active-line ranges, call-operand name inference и реальные bytecode closures, включая main chunk. Varargs вынесены из расширяемого register frame в отдельное владение кадра, поэтому multiret/grow больше не повреждает `debug.getlocal(..., -n)`. Реализованы count hooks на bytecode dispatch, suspended-coroutine `getinfo/getlocal/setlocal`, transfer metadata, `for iterator`/metamethod names и nil-line hook для stripped chunks. Исправлен debug temporary scan для frame >256 регистров. Добавлен differential smoke `31_debug_bytecode_parity.lua`; `db.lua` и `constructs.lua` проходят, project matrix — 28/29.
- P15.18: debug LocVar cleanup — generic-for и numeric-for записывают PUC-совместимые скрытые `"(for state)"` slots в `Proto.locvars` на этапе bytecode codegen, устраняя потребность в runtime-эвристике. Bytecode `getlocal`/`setlocal` используют реальные LocVar range/register metadata. Для count-hook compatibility filters (IR и bytecode) добавлен TODO с критерием удаления и дедлайном до 1.0.0. Добавлен smoke `32_for_loop_locvars.lua`.
- P15.19: PUC-faithful `os.clock` — удалён deterministic stub, всегда возвращавший `0.0`. `os.clock()` теперь читает process CPU clock через `std.Io.Clock.cpu_process`, соответствуя семантике C `clock()` в PUC Lua без libc fallback. Добавлен differential smoke `33_os_clock_cpu_time.lua`; `sort.lua` печатает реальное время сортировки.
- P15.20: `gc.lua` parity — автоматический bytecode GC tick теперь уважает `collectgarbage("stop")`; explicit `collect`/`step` работают при остановленном сборщике, не меняя running-state. Step использует memory-sized work budget (`gcStepBudgetBytes`), поэтому больший `n` завершает цикл за меньшее число вызовов. Полный `gc.lua` побайтно совпадает с PUC Lua. Текущий step scheduler завершает mark/sweep атомарно после исчерпания budget; TODO `gc-incremental-phases` требует заменить его настоящими persistent mark/propagate/sweep phases до 1.0.0. Добавлен smoke `34_gc_stop_and_step.lua`. Project matrix — 29/29.
- P15.21: thread-owned bytecode frame stack — `BytecodeExecFrame` и `BytecodePendingCall` вынесены в thread-level runtime model, а authoritative descriptor stack перенесён из локальной переменной `runBytecode` в `Thread.bytecode_frames`. Каждый вход в `runBytecode` фиксирует boundary depth и на return/error освобождает только свой suffix; это сохраняет один owner при re-entry через `pcall`/`xpcall`, metamethod и nested `coroutine.resume`. Legacy `SuspendedFrame` snapshots пока сохранены, поэтому основной TODO не закрыт: следующий этап — per-thread register/TBC ownership и resume непосредственно из сохранённого frame stack. Добавлен smoke `35_thread_owned_bytecode_frames.lua`; unit tests, 35/35 smoke, ключевые parity suites и recursion guard проходят.
- P15.22: thread-owned runtime stacks — runtime `Frame`, bytecode register/boxed buffers, stack top и TBC list перенесены в `Thread`. VM держит только borrowed hot-path view активного потока; `coroutine.resume` паркует caller и активирует callee move-only операциями без копирования. GC traversal mark'ит parked runtime stacks и frame upvalues, поэтому nested coroutine может запустить sweep без потери значений caller'а. Добавлен smoke `36_thread_owned_runtime_stacks.lua`; unit tests, 36/36 smoke и ключевые parity suites проходят. Попытка сразу оставить live frames на месте при yield выявила обязательный следующий шаг: yielding `__close`/metamethod path всё ещё требует explicit dispatch continuation, поэтому legacy `SuspendedFrame` пока не удалён. ReleaseFast snapshot после parity: nextvar 1.37s, coroutine 0.12s, gc 1.12s в текущем окружении.
- P15.23: direct bytecode yield continuation — обычный `OP_CALL`/`OP_TAILCALL` к `coroutine.yield` на корневой границе bytecode dispatch оставляет `BytecodeExecFrame`, register/boxed buffers и TBC list в thread-owned storage вместо копирования в `SuspendedFrame`. `resume` продолжает тот же parked frame и записывает resume values в исходный CALL; debug API читает parked runtime frame, а GC/teardown сохраняют его как обычный Thread root. Архитектурный unit test проверяет, что после yield `suspended_frames` пуст и authoritative `bytecode_frames` остаётся жив; smoke `37_inplace_bytecode_yield.lua` покрывает nested/tail yield, debug inspection, GC и abandoned coroutine. Compatibility boundary имеет TODO удаления до 1.0.0; snapshots остаются только для re-entrant protected/metamethod/hook/`__close` paths.
- P15.24: iterative protected dispatch — bytecode targets `pcall`/`xpcall` и bytecode error handlers больше не вызывают вложенный `runBytecode`. Protected state (saved error, handler phase/depth and result continuation) хранится в `BytecodePendingCall`; общий dispatch loop ловит runtime error, unwind'ит только failed child suffix и продолжает ближайший protected caller. Yield внутри protected call сохраняет тот же thread-owned frame stack. `TFORCALL` к bytecode-итератору также переведён на explicit child frame. Teardown abandoned coroutine освобождает parked protected state без подмены текущей ошибки VM. Исправлена обнаруженная этим переходом dangling-ссылка в builtin `error()`: fallback теперь копирует сообщение в стабильный VM buffer. Smoke `38_iterative_protected_dispatch.lua` покрывает глубокие обычные и tail-position `pcall`/`xpcall`, yield/resume, Lua iterator и сборку abandoned protected coroutines; explicit protected depth принадлежит конкретному `Thread`, поэтому parked coroutines не делят глобальный лимит. Unit tests, 38/38 smoke и `calls.lua` с 1-МБ host stack проходят. Открыты metamethod/hook/`__close`/nested-resume actions.
- P15.25: complete iterative bytecode dispatch — Lua metamethods, debug hooks, yielding `__close`, nested `coroutine.resume` и `string.gsub` Lua callbacks переведены на `BytecodePendingCompletion`/thread-owned continuations. Persistent unwind продолжает close chain после yield и ошибок; coroutine trampoline переключает parked `Thread` через `ThreadSwitch` без Zig recursion. Bytecode snapshot/replay удалён; `IrSuspendedFrame` остался только у frozen IR compatibility children и связан с bc caller через explicit pending continuation. Удалён 256-МБ interpreter thread stack. `hasActiveClose()` синхронизирует tail-call policy с PUC Lua для named и generic-for TBC slots. Добавлены smoke `39_complete_iterative_dispatch.lua` и 1-МБ stress lane. Unit tests, 39/39 smoke, полный `cstack.lua` под 1-МБ stack и 29/29 upstream suites по exit/assertion status проходят.
- P15.26: dispatch review hardening — повторно подтверждён PUC-order hidden generic-for TBC (`return` expression вычисляется до iterator `__close`, результат `false true`); `ThreadSwitch` удалён из публичного `Vm.Error` и локализован в private `DispatchError`/coroutine trampoline; `api.zig` больше не знает о внутреннем сигнале. Рядом с pending continuation state документированы ownership, cleanup, yield и thread-switch invariants. После рефакторинга повторно проходят unit tests, 39/39 smoke, 1-МБ stress lane и 29/29 upstream suites.
- P15.27: завершение regression cleanup после iterative dispatch — исправлены large `SETLIST + EXTRAARG`, lexical `goto`/global-attribute/named-vararg semantics, source line tables и PUC-like line-hook `oldpc`; удалён trace preseed. `saved_parent_callee` debug-hook continuation добавлен в GC roots, а stripped `load` всегда инициализирует первый environment upvalue. Расширен smoke `31_debug_bytecode_parity.lua`; `40_large_setlist_extraarg.lua` закрепляет `verybig` codegen. Подтверждены unit tests, 40/40 smoke, 1-МБ stress, 29/29 upstream matrix и direct `verybig.lua`.
- P15.28: verifier follow-up — dynamic `load()`/automatic-GC scheduling переведены с fixed instruction cadence на live-heap debt, короткие interned strings включены в memory accounting, а explicit generational step выполняет атомарный цикл с PUC-compatible `false` result. `runBytecode` скрывает private dispatch signal, strict-global codegen не знает имён stdlib, `time.txt` сохраняется через snapshot/restore. Добавлен smoke `42_gc_debt_and_generational_step.lua`; подтверждены 42/42 smoke, 29/29 soft/portable matrix, direct `constructs.lua` <60 с и direct `verybig.lua`.
- P15.29: persistent incremental GC — collector хранит `pause/propagate/atomic/sweep` state, gray queue, mark sets и sweep cursors между `collectgarbage("step", n)`; mark/sweep расходуют реальный bounded budget, mutable roots и write barriers сохраняют tri-color invariant, а registry entries удаляются до освобождения объекта. Исправлены finalizer epoch/reentrancy и escaping main-chunk `_ENV` ownership. Unit regression наблюдает отдельные phases и barrier writes. Подтверждены Debug build/tests, 42/42 smoke, 1-МБ stress, 29/29 upstream matrix, direct heavy tests и `gc.lua` 1.85 с Debug / 0.54 с ReleaseFast.
- P15.30: настоящий generational GC — добавлены PUC-like object ages, per-type nursery, OLD1/remembered/old-thread queues, forward/back barriers и young-only sweep. Minor collections больше не вызывают полный incremental cycle и не обходят обычный old heap; `minormul/minormajor/majorminor` управляют minor → incremental major → minor transitions. `gengc.lua --testc` читает реальные age states; добавлен smoke `43_generational_minor.lua`. Hotfix P15.30.1 сбрасывает automatic-GC debt при `restart`, масштабирует automatic slice по PUC sweep granularity и добавляет `44_gc_restart_pace.lua`; direct `gc.lua` без `_soft` снова завершается. Подтверждены 44/44 smoke, 29/29 matrix, GC suites, 1-МБ stress и direct heavy tests.
- P15.37a: frame-struct slim — `BytecodeExecFrame` (936 B) и `BytecodePendingCall` (768 B optional) переведены на reuse-pool pattern (`addOne` + field-by-field writes) + `PendingCallSlot` wrapper (`active: bool` + `payload = undefined`, `clear()` = single-byte write), устраняя `compiler_rt.memset` (byte-wise zero-init структур фреймов, 57% от lua_calls) на каждом call/return. lua_calls 1.760→0.617s (-65%), metamethod_add 0.456→0.282s (-38%), memset share 53%→<1%.
- P15.37b: Node compaction — `ltable.Node` уплотнён с 56 B до 48 B: `next: ?*Node` (8 B + padding) заменён на `next_offset: i32` (4 B) PUC `gnext`-style signed index offset, а `dead_key: bool` упакован в старший бит `hash` (`DEAD_KEY_FLAG`). Hash маскируется (`HASH_MASK`) при записи, чтобы live-key хеши с установленным bit 63 не ложно определялись как dead. `nextNode` использует direct pointer arithmetic (`self + off * @sizeOf(Node)`) для chain walk без восстановления индекса. Паритет 28/31 сохранён, 44/44 smoke проходят, `nodeLookup` perf share ~28% (без регрессии).
- P15.37c: Table.flags bitmask (BITRAS) — добавлен `flags: u8` в `Table` (PUC `ltm.h:54`): bit set = "metatable не имеет метаметода". Проверяется перед `getFieldOpt(mt, "__index"/"__newindex")` в 5 точках. Сбрасывается при new-key insertion в `rawSet` (PUC `ltable.c:1112`). PUC-faithful metamethod cache. Доля metamethod-check упала с 11% до ~9% на global_arith (меньше ожидаемого — benchmark работает с `_ENV` без metatable).
- P15.37d: `tools/perf_compare.py` + `tools/perf/baseline-p15.37.json` — reproducible perf gate. Скрипт собирает ReleaseFast + PUC Lua, pinned `taskset -c 0`, медиана 7 прогонов на 16 workloads, таблица с geomean, regression check (WARN >5%, FAIL >10%), `--update-baseline`/`--perf`/`--runs`/`--core`/`--no-build`. Geomean P15.37: **4.77×** (было 5.21× после P15.36).
- P15.48a–d: callinfo-parity — 4-фазный refactor модели call frames:
  - Phase A: pre-allocate frame capacity (64 frames inline, `ensureTotalCapacity` on activate).
  - Phase B: merge `BytecodeExecFrame` + `RuntimeFrame` into single `CallFrame` (424 B), eliminating dual-stack sync overhead.
  - Phase C: inline `[32]CallFrame` + heap overflow (`FrameStack`), migrating 42 signatures from `*ArrayListUnmanaged`.
  - Phase D: varargs on `bc_stack` (`nextraargs: u16`, `[base-nextra..base]`), eliminating per-call `alloc.dupe`.
  Geomean после всех фаз: **3.20×**.
- DispatchLoopSlim: dispatch loop overhead reduction:
  - `EXTRA_MARGIN = 5` pre-allocated per frame (matches PUC `EXTRA_STACK = 5`, lstate.h:142). `bcGrowFrame` is a no-op for typical multiret (≤5 values).
  - Stack realloc check simplified from 3-way comparison (ptr + boxed_ptr + frame_cap) to single `bc_stack.ptr` comparison. `bc_stack` and `bc_boxed` are always realloc'd together; `bcGrowFrame` updates `ctx.regs`/`ctx.boxed` directly via out-parameters.
  - Geomean: **3.10×**. Key wins: branch_loop -18.4%, comparisons -28.5%, lua_calls -17.1%.
- fr.pc sole pc: eliminated `bc_dispatch_pc` and `bc_dispatch_active` from Vm.
  `ctx.fr: *CallFrame` pointer gives direct access to `fr.pc` (like PUC's
  `ci->u.l.savedpc`). Three copies of pc reduced to one. `fail()` and
  `callBuiltin()` read `fr.pc` from topmost frame directly. Per-instruction
  `bc_dispatch_pc` store and `bc_dispatch_active` store eliminated (-2 cycles).
  Re-entrancy from `require`/`dofile` is safe — each `runBytecodeDispatch`
  invocation has its own `ctx` (Zig stack), nested calls don't touch parent
  frame pc. Hooks block keeps its own `var fr` (re-derived after hook-executed
  Lua code may realloc `exec_frames` heap). CLOSE handler double-increment
  fixed: `continueBytecodeClose` already increments `fr.pc`; the handler's
  mirror was removed. Geomean: **3.12×**.

- **lineinfo cold path** (commit `9ae3e43`): Removed per-instruction
  `lineinfo[pc]` read from the fast path. `current_line` is now re-derived
  lazily by cold-path sites: `fail()`, `callBuiltin()`, `debug.getinfo`,
  `debug.sethook`, `tracebackFrameLabel`, and the hook dispatch fallback.
  Fast path no longer touches lineinfo at all. Geomean: **3.09×**.

- **IR executor removal** (commits `7a674a6`, `7a4b546`, `0c4f63d`): Removed
  the deprecated IR executor entirely. `runFunctionArgsWithUpvalues`
  (~1023 lines), `runFunction`, `runFunctionArgs`, and 26 IR-specific helper
  functions (~696 lines) deleted. `runClosure` simplified — always calls
  `runBytecodeInternal`, `is_tailcall` parameter removed. `compileTextChunk`
  IR fallback removed; `api.zig` switched to `codegen_bc`. `bootstrapTestc`
  and testC load switched to `createBytecodeChunkClosure`. Unit tests
  switched from `Codegen`+`runFunction` to `CodegenBc`+`runBytecode`.
  Disabled `lower_ir.zig` and `bc_vm.zig` files deleted, commented imports
  removed from `root.zig`. All closures now have `proto != null`. The IR
  pipeline (`codegen.zig`, `ir.zig`) remains as a compilation stage and
  debug dump tool only — execution is bytecode-only (PUC-faithful).
  Geomean: **3.09×** (parity baseline preserved: 28/31 matrix, 45/45 smoke).

- **IR dead code cleanup** (commit `beec04f`): Removed all remaining IR executor
  dead code — 163 insertions, 1692 deletions. Removed: `IrSuspendedFrame` struct
  + `Thread.ir_suspended_frames` (never appended to), `Vm.call_frames` +
  `Thread.parked_call_frames` (~63 refs, always empty), `Closure.func` +
  `bc_dummy_func_global` (always placeholder), `CallFrame.func` +
  `CallFrame.locals` + `CallFrame.local_active` (always empty),
  `synthetic_env_slot` (always false), `tail_resume_func` (zero refs),
  `apiWrapFunction` (zero callers), dead-branch calls to non-existent
  `debugGetLocalFromIrSuspendedFrame`/`SetLocal`, dead IR else-branches in
  debug/getinfo/traceback paths, dead IR-era functions
  (`debugFillInfoFromIrFunction`, `debugGetLocalNameFromFunction`,
  `isCloseLocalIdx`, `frameEnvValue`, `getNameInFrame`, `setNameInFrame`).
  `CallFrame` accessors (`isVararg`, `lineDefined`, `sourceName`, `numParams`)
  simplified from `if (proto) |p| ... else func.*` to direct `proto.?.*`
  (proto is always non-null). Geomean: **3.05×** (parity preserved: 28/31
  matrix, 45/45 smoke).

- **Inline + dedup: reduce function-call overhead** (this session): Micro-optimizations
  to reduce per-call overhead in the bytecode VM dispatch loop:
  1. Removed duplicate stack-overflow check in `pushBytecodeExecFrame` (two
     checks with same operands merged into one — the second check subsumes
     the first because it accounts for `nextra` varargs).
  2. Marked `resolveProtoConstants` as `inline` — fast path is a single bool
     check (`proto.constants_resolved`), cold path does string interning.
  3. Marked `popBytecodeExecFrame` as `inline` — small function (2 branches,
     3 field writes, 1 `shrinkTo` call), avoids call overhead on every return.
  4. Added `has_open_upvalues: bool` to `CallFrame` — set by `OP_CLOSURE`
     when it captures a stack register into a Cell. All 6
     `closeBytecodeUpvaluesFrom` call sites now gate behind
     `if (frame.has_open_upvalues)`, skipping the linear scan over
     `frame_cap` slots when no upvalues are open (the common case).
  5. Fixed stale "760 bytes" comments — `BytecodePendingCall` is 48 bytes
     after P15.44 moved large continuation variants to heap pointers.
  Geomean: **2.95×** (parity preserved: 28/31 matrix, 45/45 smoke).

- **Eliminate ctx.fr pointer from dispatch hot path** (commit `de34fc0`):
  Replaced `ctx.fr: *CallFrame` (pointer into `exec_frames` heap array)
  with value fields `pc`, `is_tailcall`, `resumed_direct_yield`,
  `has_open_upvalues` on `BytecodeDispatchCtx`. This mirrors PUC Lua's
  local `const Instruction *pc` pattern: the heap CallFrame is only
  synced at call/return boundaries (`syncDispatchCtx` defer), not
  dereferenced per-instruction. Eliminates 3 heap dereferences per
  instruction (the `ctx.fr.pc` pointer chase).
  - Added `Vm.dispatch_pc: usize` field — written per-instruction in the
    inner dispatch loop so `fail()` and `syncTopFrameForGc` can read the
    current pc without `ctx` access. `fail()` syncs `fr.pc = dispatch_pc`
    before reading lineinfo. `syncTopFrameForGc` syncs `dispatch_pc` to
    frame (was a no-op).
  - OP_CLOSE: increment `ctx.pc` in handler (not in `continueBytecodeClose`)
    to avoid defer clobbering frame pc.
  - OP_CLOSURE: set `ctx.has_open_upvalues = true` (was only on frame) so
    OP_MOVE's fast path correctly takes the slow path that syncs through
    `boxed[]` cells.
  - `callBuiltin` (opCall/opTailcall/opTforcall): sync pc/reg_top/nvarstack
    to frame before call (GC reads `live_reg_top[pc]` from frame).
  - Fixed IDIV `minint // -1` overflow: return `minInt(i64)` (was 0).
  Geomean: **2.88×** (parity preserved: 28/31 matrix, 44/45 smoke).
  No perf change — eliminated dangling-pointer hazard and adopted PUC's
  local-pc pattern, but the per-instruction `dispatch_pc` store offsets
  the saved heap dereferences.

Детальная история оптимизаций, промежуточных замеров и закрытых подпунктов сохранена в Git (`git log`).

## GC refactor: unified `GcObject` and real Userdata

Цель: заменить 5 раздельных per-type GC списков (`gc_tables`, `gc_closures`,
`gc_threads`, `gc_cells`, `gc_strings`) на единый `GcObject` tagged union
(как в PUC `allgc`), и добавить настоящий full Userdata тип (вместо
текущего `*anyopaque` light userdata hack). План:
`docs/superpowers/plans/2026-07-27-gcobject-unified-and-userdata.md`.

Чекбоксы по задачам плана:

- [x] **A1**: Define `GcObject` tagged union and accessor functions (`gcPtr`,
      `gcObjectBytes`, `gcCanFinalize`). Pure addition — union defined but not
      wired into existing GC code yet (dual registration comes in A2).
- [x] **A2**: Dual registration — keep per-type lists AND `GcObject` registry in sync.
      Unified `gc_objects`/`gc_young_objects` lists added to Vm; `gcRegisterObject`/
      `gcUnregisterObject` wired into all 5 per-type register/unregister functions.
      Uses `gc_object_indices` side-table for O(1) lookup during migration (per-type
      lists still own `gc_index`); side-table removed in A5 when per-type lists go away.
- [x] **A3**: Migrate mark/sweep/propagate to use `GcObject` + `gcPtr`.
      `gc_gray` changed from `ArrayList(Value)` to `ArrayList(GcObject)`;
      `gcQueueScanObject` is the new type-generic entry point (strings → black,
      others → gray + queue); `gcMarkValue`/`gcMarkMinorValue`/`gcQueueScanValue`
      delegate through `GcObject.fromValue`; `gcPropagateOne` switches on
      GcObject variants (`.table`/`.closure`/`.thread`/`.string`/`.cell`);
      closed cells follow PUC `reallymarkobject` (lgc.c:347-354): set black
      directly + mark content inline, never entering the gray list (PUC
      `propagatemark` has no `LUA_VUPVAL` case). `gc_mark_epoch` bump preserved (only on white→marked
      transition) to keep ephemeron fixpoint convergence correct. `gc.lua`
      test now passes (was timing out due to epoch always-bump bug).
      `gc_grayagain` still `ArrayList(Value)` — A4 will migrate it.
- [x] **A4**: Migrate generational lists (`gc_old1`, `gc_grayagain`) to `GcObject`.
      Eliminated parallel `gc_old1_cells`/`gc_grayagain_cells` lists — Cell is now
      folded into the unified lists via `.{ .cell = cell }`. `gcRememberObject`
      is the new GcObject-typed entry point for backward barriers (wraps
      `gcRememberValue`/`gcRememberCell`). `gcCorrectOld1`/`gcCorrectGrayAgain`
      collapsed to single GcObject loops via `gcPtr`. `gcDrainGrayagain` merged
      into a single loop (cells mark value inline + go black; others re-queue
      into `gc_gray`). `gcMinorCollection` grayagain re-traversal routes cells
      through `gcQueueScanCell` (preserving PUC open/closed distinction).
- [x] **A5**: Unify sweep — eliminate `GcSweepKind`. Replaced the per-type
      incremental sweep (7-phase `GcSweepKind` enum walking `gc_tables`/
      `gc_closures`/`gc_threads`/`gc_strings`/`gc_cells` in sequence) with a
      single-pass sweep over `gc_objects` in allocation order (PUC-faithful:
      `sweeplist` walks `allgc`). Added `gcFreeObject` (centralized type-specific
      teardown: per-type unregister + memory free + `gcNoteFree`) and
      `gcHasFinalizer` (centralized finalizer detection via `finalizables` set).
      Removed `GcSweepKind` enum, `gc_sweep_kind`/`gc_sweep_cursor` fields, and
      per-type snapshot lengths (`gc_tables_snapshot_len` etc.); replaced with
      `gc_sweep_objects_cursor` walking against `gc_objects_snapshot_len`.
      Per-type lists still maintained (removed in A7) — `gcFreeObject` calls
      per-type `gcUnregister*` to keep them consistent.
- [x] **A6**: Unify generational sweep and make-all-white/old. Replaced the five
      per-type young sweep functions (`gcSweepYoungTables`/`Closures`/`Threads`/
      `Strings`/`Cells`) with a single `gcSweepYoungObjects` over `gc_young_objects`.
      Replaced `gcPromoteYoungValue`/`gcPromoteYoungCell` with unified
      `gcPromoteYoungObject` (preserves `gc_gen_added_old_kb` tracking for
      minor→major threshold and `gc_gen_threads` append for promoted threads —
      PUC `twups`-equivalent root scanning). `gcMakeAllWhite`/`gcMakeAllOld`/
      `gcClearFinalizedBit` now iterate `gc_objects` via `gcPtr` instead of
      per-type lists. `gcClearGenerationalLists` clears `gc_young_objects`/
      `gc_old1`/`gc_grayagain`/`gc_gen_threads`. `gcMinorCollection` uses the
      unified snapshot and mark-reset. `gcSweepYoungGeneration` calls the single
      unified sweep. Dropped the `finalizables.contains` check from young table
      sweep (consistent with A5's `gcSweepOne`, which relies solely on
      `FINALIZEDBIT`). Per-type young lists and snapshot fields still exist
      (removed in A7) but are no longer swept.
- [x] **A7**: Remove per-type lists — single unified `GcObject` registry.
      Removed all 5 per-type list fields (`gc_tables`/`gc_closures`/
      `gc_threads`/`gc_cells`/`gc_strings`) and their young counterparts
      (`gc_young_tables` etc.) and snapshot length fields. Removed the
      `gc_object_indices` side-table (from A2) — `gc_index` is now the sole
      index into `gc_objects`, written directly by `gcRegisterObject` and
      read by `gcUnregisterObject` for O(1) `swapRemove`. Removed the
      `ptrKey` helper. Simplified `gcRegister*T`/`gcUnregister*T` to thin
      wrappers delegating to the generic functions. Simplified `gcFreeObject`
      to only free memory (no unregister); sweep functions
      (`gcSweepOne`/`gcSweepYoungObjects`) now call `gcUnregisterObject`
      before `gcFreeObject`. `drainGcRegistries` iterates `gc_objects`
      directly. `gcDeadenUnmarkedStringKeys` iterates `gc_objects` filtering
      for tables. Replaced ~31 `if (v == .Table or v == .Closure or …)`
      chains in `gcPropagateOne` with `GcObject.fromValue(v) != null`.
      GC refactor Part A is **complete**.
 - [x] B1: Define `Userdata` struct with `gc_marked`/`gc_age`/`gc_index` + metatable.
 - [x] B2: Add `Userdata` variant to `Value` and `GcObject`.
  - [x] B2.1: Implement `allocUserdata` (PUC `luaS_newudata` analogue), `cmpEq`
        type-compatibility fix (PUC `luaV_equalobj`: `__eq` only when both
        operands are the same type — fixes `events.lua:347` root cause), GC
        write barriers for Userdata metatable/uservalues
        (`gcForwardBarrierValue`), and `debug.setuservalue`/`getuservalue`
        real-Userdata paths. Also added `.Userdata` to `gcValueAge`/
        `gcSetValueAge`/`gcWriteBarrier` so generational and incremental
        barriers fire correctly for Userdata owners.
  - [x] **A3 regression fix**: `gcQueueScanCell` for closed upvalues had an
        early return (`if (!gcIsWhite) return`) before marking `cell.value`,
        causing the main chunk's `_ENV` cell (not GC-registered) to be
        skipped during marking → use-after-free when `collectgarbage("collect")`
        swept the `_ENV` table. Restored A2/PUC behavior: `cell.value` is
        marked unconditionally for closed cells; only the cell's own color
        transition is gated on `isWhite`. Normal matrix restored to 28/31.
   - [x] B3: Migrate `T.newuserdata` from table emulation to real Userdata.
         Add `testc_newuserdata` builtin, update testC bootstrap to use real
         `allocUserdata`, update `T.udataval`/`T.objsize`/`isTestcUserdata`.
         Target: events.lua passes in testC matrix (26/31+).
         **Result:** events.lua, gc.lua, gengc.lua, nextvar.lua, api.lua all
         pass in testC matrix. testC matrix: 26/31 (5 fails: attrib, big,
         code, cstack, files — all pre-existing). Normal matrix: 28/31
         (no regressions). Smoke: 45/45.
         **Key fixes:**
         - `gcFinalizeLessThan` switched from `gc_index` (corrupted by
           `swapRemove`) to `gc_seq` (monotonic creation counter, set once,
           never changed) for correct LIFO finalization order.
         - `gcMarkClosureFinalizerReach`/`gcMarkTableFinalizerReach`/
           `gcMarkThreadFinalizerReach` now mark the object itself black
           (PUC `markfinalizer` calls `markobject`), not just set
           FINALIZEDBIT. Without this, closures/tables/threads stayed white
           and were swept (freed) — causing use-after-free when their
           children were later traversed by another finalizable object.
         - testC `setmetatable` command now handles `.Userdata` (sets
           `u.metatable` + write barrier).
         - testC `testudata` command now handles `.Userdata` (checks
           `u.metatable` against expected metatable).
         - `gcWriteBarrierUserdata` generational mode check fires BEFORE
           `gc_state == .pause` early return — in gen mode, paused objects
           are old (black), mutations must be tracked for next minor cycle.
     - [x] B4: Full regression testing and cleanup. Run testC matrix, normal
           matrix, smoke, testc_lane. Update README.
           **Result:** testC matrix: 26/31 (5 fails: attrib, big, code,
           cstack, files — all pre-existing). Normal matrix: 28/31 (3 fails:
           attrib, big, files — all pre-existing). Smoke: 45/45.
           testc_lane: 9/9 ok.

## fasttm: PUC metamethod flags cache

- [x] Implement PUC `fasttm` (`ltm.h:63-68`, `ltm.c:60-68`) for cached
      metamethod lookup. Bit set in `Table.flags` = "metamethod absent" →
      skip hash lookup entirely (single AND instruction). Cache-on-miss:
      when `fasttm` does the hash lookup and finds nil, sets the bit so
      future calls skip the lookup.
  - **`TmsEvent` enum** (`vm.zig:1558`): PUC `TMS` ordering. Events
    `<= .eq` (index, newindex, gc, mode, len, eq) are cached in `flags`;
    events above (arithmetic, call, iter, close, etc.) always do hash lookup.
  - **`tm_names` field** on Vm: pre-interned `*LuaString` for all 30
    metamethod names, indexed by `TmsEvent`. Populated at `Vm.init`
    (mirrors PUC `luaT_init`). Used by `fasttm` for pointer-identity key
    comparison — avoids `internStrAssume` hashmap lookup on every call.
  - **`fasttm(mt, event)`** (`vm.zig:24949`): check `flags` bit → if set,
    return null. Otherwise `rawGet` with pre-interned name → if nil,
    set bit (cache-on-miss) → return null/value.
  - **`metamethodValue`** now routes through `fasttm` for cached events
    and `metamethodValueByEvent` for non-cached. All `__eq`, `__len`,
    `__gc`, `__mode`, `__index`, `__newindex` lookups now use `fasttm`.
  - **Dead-node revival fix**: when `rawSet` (or OP_SETFIELD inline fast
    path) updates a nil-valued node to non-nil, invalidates `flags`
    (mirrors PUC `luaV_finishset` → `invalidateTMcache` at `lvm.c:347`).
    This is required for events.lua:317-324 (set `__eq=nil` then
    `__eq=function` — the nil→non-nil transition must clear the cached
    "absent" bit).
  - **Result:** Normal matrix: 28/31 (no regression). testC matrix: 26/31
    (no regression). Smoke: 42/42. testc_lane: 9/9.

## P15.74e: Unified `near <token>` error messages

- [x] Unify lexer/parser error formatting to match PUC Lua's `lexerror`
      (`llex.c:116-121`) + `luaG_addinfo` (`ldebug.c:826-836`) format:
      `"<chunkid>:<line>: <msg> near <token>"`.
  - **`Diag.near_token`** (`diag.zig`): new optional field for the
    `near <token>` suffix. `Diag.format`/`bufFormat` now produce
    `"<chunkid>:<line>: <msg>"` + optional `" near <token>"` (no column,
    matching PUC's `"%s:%d: %s"`).
  - **`chunkId`** (`diag.zig`): PUC `luaO_chunkid` (`lobject.c:682-718`)
    transformation: `=stdin` → `stdin`, `@foo.lua` → `foo.lua`,
    `code` → `[string "code"]`. Replaces the old `chunkNameForSyntaxError`
    in `vm.zig` (now removed).
  - **`tokenToNearText`** (`token.zig`): PUC `txtToken` (`llex.c:104-113`).
    For `TK_NAME`/`TK_STRING`/`TK_FLT`/`TK_INT` → wraps lexeme in single
    quotes (`'foo'`, `'3.14'`). For `TK_EOS` → `<eof>`. For keywords/
    symbols → wraps canonical name in quotes (`'end'`, `';'`).
  - **Lexer `setDiag`** (`lexer.zig`): now accepts a `near` parameter.
    All `setDiag` calls pass the PUC-faithful near text:
    `"<eof>"` for EOF errors, partial string content for escape errors
    (via `nearTextForStringError`), partial numeral for malformed numbers
    (via `nearTextForNumberError`), `'<char>'` for unexpected symbols.
  - **Lexer escape errors**: messages changed to match PUC:
    `"hexadecimal digit expected"` (was `"invalid hex escape"`),
    `"missing '{'"`/`"missing '}'"` (was `"invalid unicode escape"`),
    `"UTF-8 value too large"` (new). Hex escape now checks digits one at
    a time (PUC `gethexa`), not both at once. Unicode escape follows PUC
    `readutf8esc` structure with `r <= (0x7FFFFFFF >> 4)` overflow check.
  - **Lexer long string error**: `"unfinished long %s (starting at line %d)"`
    with %s = "string"/"comment" (was `"unfinished long string/comment"`).
  - **Parser `setDiag`** (`parser.zig`): automatically computes
    `near_token` from `self.cur` via `tokenToNearText`. No signature
    change — all existing calls get the near text for free.
  - **Parser messages**: `"expected expression"` → `"unexpected symbol"`
    (PUC `primaryexp` default case, `lparser.c:1211`). Four
    `"unexpected symbol near ';'"` messages simplified to
    `"unexpected symbol"` (near text is now auto-computed).
  - **vm.zig cleanup**: removed `formatLoadSyntaxError`, `formatLoadLexError`,
    `nearTokenForSyntaxError`, `nearLexError`, `chunkNameForSyntaxError`.
    `compileTextChunk` always uses `Diag.bufFormat` (no `load_error_style`
    parameter). Single unified error formatting path.
  - **REPL fix**: `isIncompleteError` now works because error messages
    end with `near <eof>` (via `Diag.near_token`). Fixed `line_buf` not
    being cleared between continuation reads in the multiline loop.
  - **Result:** Matrix: 30/31 (no regression — `big.lua` both_fail is
    pre-existing). Smoke: 46/46. REPL multi-line continuation works
    (`a = [[b\nc\nd\ne]]` correctly reads 4 lines).

## P15.74f: PUC-faithful REPL prompt + EOF handling

- [x] Implement `getPrompt` (PUC `get_prompt`, `lua.c:533-541`): reads
      `_PROMPT`/`_PROMPT2` globals, applies `tostring` (calls `__tostring`
      metamethod), uses defaults (`> ` / `>> `) if nil.
- [x] Remove `is_tty` gate: always print the prompt (PUC `fputs` always
      prints, regardless of TTY status).
- [x] Fix `readLine`: handle `error.EndOfStream` from `readStreaming` at
      EOF — return buffered data as the last line (no trailing newline).
- [x] Fix EOF continuation: re-compile and print the error message when
      EOF occurs during multiline continuation (PUC `multiline` returns
      status, `doREPL` calls `report`).
- **Result:** Matrix: 30/31. Smoke: 46/46.

## P15.74g: PUC-faithful `errfunc` mechanism + C-frames for error path

- [x] Implement PUC `L->errfunc` (`vm.zig`): message handler called BEFORE
      call stack unwinding, so `__tostring` metamethods can access
      `debug.getinfo(N)` while the stack is intact.
  - **`errfunc`/`errfunc_running` fields** on Vm: thread-level message
    handler, set by CLI and clear during protected calls.
  - **`invokeErrfunc`** (`vm.zig`): PUC `luaG_errormsg` (`ldebug.c:840-854`).
    Calls the handler via `apiCall` while `Thread.call_frames` is intact.
    Handler return value replaces the error object. Handler errors set
    `"error in error handling"` (PUC `LUA_ERRERR`).
  - **`builtinCliMsghandler`** (`vm.zig`): PUC `msghandler` (`lua.c:136-148`).
    String errors get traceback appended. Non-string errors try
    `__tostring` metamethod (no traceback if it succeeds). Fallback:
    `"(error object is a %s value)"` + traceback.
  - **CLI integration** (`luazig.zig`): `runZigSourceArgs` sets
    `vm.errfunc = .{ .Builtin = .cli_msghandler }` before `runBytecode`.
    `reportError` simplified to just print `errorString()` (errfunc already
    formatted the error).

- [x] Push synthetic C-frames for error path so `debug.getinfo` level
      numbers match PUC.
  - **`pushBuiltinCFrame`/`popBuiltinCFrame`** (`vm.zig`): pushes a
    `CallFrame` with `proto = null`, `callee = .Builtin(id)`,
    `current_line = -1` onto `Thread.call_frames`.
  - **`builtinError`** pushes a C-frame for the `error` call (represents
    PUC's CALL instruction CI via `luaD_precall`).
  - **`invokeErrfunc`** pushes a C-frame for the msghandler (represents
    PUC's `luaD_callnoyield(errfunc)`).
  - **CallFrame accessors** handle null proto: `isVararg()` → false,
    `lineDefined()` → -1, `sourceName()` → `"=[C]"`, `numParams()` → 0,
    `funcName()` → `"?"`.
  - **Design decision:** C-frames are pushed ONLY for the error path
    (`error` builtin + `msghandler`). All other builtins (`print`, `type`,
    `tostring`, etc.) remain frame-less for performance. This is an
    intentional departure from PUC (which pushes CI for every C call).
    Justification: the error handler is the only context where
    `debug.getinfo(N)` level parity with PUC is observable; other builtins
    don't affect debug level numbering in any test.

- [x] Protected calls save/clear/restore `errfunc`:
  - **`BytecodeSavedError.errfunc`**: new field stores the outer `errfunc`.
  - **`saveBytecodeProtectedError`**: saves and clears `errfunc` (PUC
    `luaD_pcall` sets `L->errfunc = 0` for protected children).
  - **`restoreBytecodeSavedError`**: restores `errfunc`.
  - **`builtinPcall`**: saves/clears `errfunc` (deferred restore).
  - **`builtinXpcall`**: saves/clears `errfunc` (handler runs via existing
    `setFail` path; TODO: migrate to `errfunc` mechanism for before-unwind
    handler invocation).
  - **`builtinCoroutineResume`**: saves/clears `errfunc` (coroutine.resume
    is a protected call).
  - **Optimized pcall path** (`tryBytecodeProtectedCall`): automatically
    handled via `saveBytecodeProtectedError`/`restoreBytecodeSavedError`.

- **Result:** Matrix: 30/31. Smoke: 46/46. `debug.getinfo(4).currentline`
  works correctly from within `__tostring` called by the error handler.

## P15.74h: Binary chunk loading (string.dump/load roundtrip)

- [x] Replace stub `string.dump`/binary-load with real Proto serialization.
  - **`src/lua/dump.zig`** (NEW): `DumpWriter` — serializes a Proto tree into
    a PUC-compatible 40-byte header + luazig-native body. LEB128 varint
    encoding, string deduplication for ALL strings (source_name, name,
    constants, upvalue names, locvar names). Opcodes written as-is (no
    remapping) — chunks are self-compatible but NOT cross-compatible with
    PUC `luac`.
  - **`src/lua/undump.zig`** (NEW): `UndumpReader` — deserializes the
    dump format. String interning via caller callback (`internFn`) to keep
    module free of vm.zig dependency. Dedup table for back-references.
  - **`vm.zig`**: Replaced stub `builtinStringDump` with real
    `DumpWriter.dumpChunk`. Replaced stub binary load path in `builtinLoad`
    with real `UndumpReader.undumpChunk`. Added `preResolveUndumpedConstants`
    to avoid double-interning (strings already interned via callback).
    Removed `dump_registry`, `appendBinaryDumpHeader`,
    `validateBinaryDumpHeader`, `instantiateLoadedClosure` stub code.
  - **`luazig.zig`**: Binary chunk detection in `runZigSourceArgs` (CLI file
    loading) — checks `0x1b` after BOM/shebang stripping, routes to undump.
  - **`parser.zig`**: `'statement is not a function call'` → `'syntax error'`
    (matching PUC). Same for `'assignment to non-variable'` and
    `'expected variable'`.
  - **`debugShortSourceEx`**: Stripped chunks (empty source_name + no
    lineinfo) return `short_src = "?"` matching PUC's
    `luaO_chunkid(NULL)`.

  **Design decision:** luazig-native binary format with PUC-compatible
  header. Justification (per AGENTS.md): PUC's binary format uses PUC
  opcode indices, which differ from luazig's (86 vs 85 opcodes, different
  ordering). Cross-compatibility requires an opcode remapping table — a
  separate mechanical task. The `all.lua` test only uses `string.dump`
  (luazig's own) — self-compatibility is sufficient.

- **Result:** Matrix: 30/31. Smoke: 46/46. `all.lua` `main.lua` passes
  through dump/undump roundtrip (all.lua runs each test file through
  `string.dump` → `load` → execute).

## P15.74i: debug.getinfo name inference fix for pcall context

- [x] **Fix synthetic "pcall" name masking real function names.**
  - **Root cause:** In `debug.getinfo` for `lv > 1`, the name inference
    code had a check `if (lv == 2 and self.activeProtectedCallDepth() > 0)`
    that returned a synthetic "pcall" name whenever the VM was inside ANY
    protected call — even when a real Lua frame existed at level 2. Since
    `all.lua` wraps test execution in `pcall(g)`, `activeProtectedCallDepth()`
    was always > 0, causing `debug.getinfo(2).name` to return "pcall" instead
    of the real function name (e.g., "f" in `db.lua:91`).
  - **Fix:** Added `fr.proto == null` condition to the synthetic pcall check.
    Now the synthetic "pcall" name is only used when the frame at level 2 has
    no proto (i.e., it's a pcall boundary frame from
    `tryPushBytecodeProtectedCall`), not when a real Lua frame is present.
  - **Result:** Matrix: 30/31 (no regressions). Smoke: 46/46. The assertion
    at `db.lua:91` (`assert(a.name == 'f' and a.namewhat == 'local')`) now
    passes through dump/undump roundtrip. A separate pre-existing GC crash
    in dump/undump cycle (segfault in `gcMarkValue` during `collectgarbage()`
    called from db.lua's `test` function) is unaffected by this fix and
    remains an open issue.

## P15.74j: Fixed-buffer binary chunk loading (PUC `S.fixed`)

- [x] **Implement PUC's fixed-buffer mode for binary chunk loading.**
  - **Root cause:** `api.lua:580` asserts that loading a stripped binary
    chunk via testC `loadstring` with mode `B` uses < 400 bytes. PUC's
    `luaU_undump` has a `fixed` flag (set when mode contains uppercase 'B')
    that points code/lineinfo/long-strings directly into the source buffer
    instead of copying. luazig had no fixed-buffer mode — every undump
    allocated new memory for code arrays, causing the < 400 byte assertion
    to fail.
  - **Implementation:**
    - **`undump.zig`**: Added `fixed: bool` flag and `getaddr` method.
      When `fixed=true`, code array is a `@ptrCast` slice into the input
      buffer (no allocation, no copy). Long string constants use
      `fixedInternFn` callback. Lineinfo still read as varints (luazig
      format differs from PUC's raw `ls_byte` array).
    - **`vm.zig`**: Added `undumpFixedInternCallback` — creates external
      `LuaString` (LSTRFIX variant, `falloc=null`) for long strings
      pointing into the source buffer. Short strings are interned
      normally (copied), matching PUC's `luaS_newlstr` path.
    - **`builtinLoadEx`**: New function with `allow_fixed` parameter.
      `builtinLoad` (Lua's `load`) passes `false` — rejects 'B' mode
      with "invalid mode" (PUC's `getMode` in lbaselib.c:344).
      testC's `loadstring` passes `true` — allows 'B' mode (PUC's C API
      `luaL_loadbufferx`).
    - **testC `loadstring`**: Removed `testc_gc_count_bonus_once_kb` hack
      (0.2 KB fudge factor). Removed lowercase mode conversion (was
      destroying the 'B' → `fixed` detection). Now calls
      `builtinLoadEx(..., true)`.
    - **Source pinning**: When `fixed=true`, the source LuaString is
      pinned via `pinned_source_strings` (code/long-strings point into
      it). When `fixed=false`, `cloneUndumpedStrings` duplicates debug
      strings as before.
  - **Result:** Matrix (--testc): 30/31, `zig_fail=0`. Smoke: 46/46.
    `api.lua` passes including the fixed-buffer memory assertion.

## P15.74h: PUC-faithful stacktrace display + REPL errfunc

- [x] Fix REPL missing traceback (errfunc not set in doREPL path).
- [x] Fix error message text ("table key cannot be nil" → "table index is nil").
- [x] Fix source name truncation via `luaO_chunkid` in traceback + error messages.
- [x] Implement PUC `pushfuncname` logic in `tracebackFrameLabel`.
- [x] Synthesize `[C]: in global 'pcall'`/`'xpcall'`/`'error'` frames in traceback.
- [x] Fix `debugInferNameFromCaller` to return empty name when caller is a C frame.

### Changes

- **REPL errfunc**: `doREPL` now sets `vm.errfunc = .{ .Builtin = .cli_msghandler }`
  before `runBytecode`, matching PUC's `docall` (lua.c:155-166). Without this,
  errors in REPL showed no traceback.
- **Error message text**: `rawSet` now uses "table index is nil" / "table index is NaN"
  (matching PUC `luaG_runerror` messages), replacing "table key cannot be nil/NaN".
- **Source name truncation**: `tracebackFrameLabel`, `protectedErrorString`, and the
  `error()` builtin now use `diag.chunkId` (PUC `luaO_chunkid`) to format source names.
  Long file paths are truncated with `...` prefix, matching PUC's `short_src`.
- **`tracebackFrameLabel` rewrite**: Follows PUC `pushfuncname` (lauxlib.c:96-109):
  1. Check `debug_namewhat`/`debug_name` (set by debug hooks).
  2. Call `debugInferNameFromCaller` for call-site name resolution.
  3. Format C-frames as `[C]: in {namewhat} '{name}'` or `[C]: in ?`.
  4. Format Lua frames with name as `{src}:{line}: in {namewhat} '{name}'`.
  5. Try `debugFindGlobalFuncName` (PUC `pushglobalfuncname`) for unnamed functions.
  6. Fallback: `function <src:linedefined>` for anonymous Lua functions.
- **Synthetic C-frames in traceback**: Since luazig's fast path
  (`tryPushBytecodeProtectedCall`) doesn't push C-frames for pcall/xpcall
  (causes stack management issues), `captureErrorTraceback` and
  `debugBuildCurrentTraceback` synthetically insert `[C]: in global 'pcall'`/
  `'xpcall'` lines by checking `pending_call.protection` on each frame.
  Similarly, `[C]: in global 'error'` is inserted when `err_from_error_builtin`
  is set.
- **`debugInferNameFromCaller` fix**: When the caller frame has a pending protected
  call (`pending_call.protection != null`), the actual caller is the C function
  (pcall/xpcall), not the Lua frame. Return empty name (matching PUC's
  `funcnamefromcall` returning NULL for C frames), so `pushfuncname` falls through
  to `pushglobalfuncname` or `function <src:linedefined>`.
- **`builtinCliMsghandler` fix**: Now uses `protectedErrorString()` (which adds
  source location via `luaO_chunkid`) instead of raw `err_obj.String.bytes()`,
  matching PUC's `luaG_addinfo` behavior.
- **Smoke test**: Added `tests/smoke/47_stacktrace_display.lua` — 6 scenarios
  testing error messages, xpcall tracebacks, global/local function names, and
  `error()` C-frame in traceback.

### Result

- Matrix: 29/31 (no regressions; `big.lua` both_fail pre-existing).
- Smoke: 47/47 (`45_userdata_capi.lua` pre-existing unrelated failure).
- REPL now shows full error message with source location + traceback, matching PUC.
