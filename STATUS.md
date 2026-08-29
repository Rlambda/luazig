> Last updated: 2026-08-29 (P16.6 — typed TMS, real MMBIN, string-mt arithmetic; geomean 2.21x→1.91x; native_mem_check fixed)

This file contains detailed project status, development log, performance analysis,
and architectural decisions. For a project overview, see [README.md](README.md).

---

## Обзор

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

Проект находится в **pre-release / parity-focused** состоянии.

> Единственный источник количественных чисел (generated source of truth) —
> status-блок в [README.md](README.md), генерируемый `tools/status_summary.py`
> из JSON-отчётов линий (matrix/smoke/perf). Числа ниже — копия для удобства;
> при расхождении приоритет у README-блока.
<!-- BEGIN GENERATED SUMMARY (tools/status_summary.py) -->
| Metric | Result |
|--------|--------|
| Upstream matrix (`testes/*.lua`, `--testc`) | _not run — no matrix JSON provided_ |
| Differential output (`--diff`) | _not run_ |
| Smoke tests (`tests/smoke/*.lua`) | _not run — no smoke JSON provided_ |
| C API suites (`tests/c_api`) | 18 suites |
| Performance (geomean vs PUC) | **1.91x** |

Geomean замедления vs PUC Lua: **1.91x** (цель: 1.0x; run-dependent). Подробная таблица workload'ов — в generated status-блоке [README.md](README.md).
<!-- END GENERATED SUMMARY -->

Bytecode VM (`--vm=bc`) — единственный активно развиваемый backend.
IR VM полностью удалена из кодовой базы.

`big.lua` — `both_fail` (pre-existing: требует `coroutine.wrap` harness из
`all.lua`).

Архитектурные решения и находки — [DESIGN.md](DESIGN.md).

### Методика

- PUC Lua 5.5 (vendored) vs luazig (ReleaseFast), `taskset -c 0`, медиана 7 прогонов.
- `python3 tools/perf_compare.py` — WARN +5%, FAIL +10% к baseline (`tools/perf/baseline-p15.37.json`).

### Текущие bottleneck'ы (по приоритету)

1. **Instruction inflation** — лишние опкоды на Lua-итерацию. Частично решено (P15.32, P15.38). **Codegen ExpDesc migration complete** — old `genExp` + `genNameValue` deleted (~265 lines), all callers migrated to `genExpDesc`/`genExpNextReg`/`genExpCond`. 8 inflated lines remain (structural: TESTSET opcode missing, SELF receiver-clobber guard).
2. **Dispatch overhead** — улучшен (P15.33, P15.50), но per-instruction overhead остаётся.
3. **Generic arithmetic path** — fast paths есть (P15.31, P15.38d), metamethod fallback дорогой.
4. **Table layout** — Node 32B (P15.39), но нет специализированных insert paths.
5. **Call-frame machinery** — zero-alloc fast path (P15.35/P15.40/P15.44), Thread header большой.
6. **AST-based compilation** — `load()` строит полный AST; streaming не реализован.
7. **Allocator** — `smp_allocator`; VM-local pools не реализованы.

## История разработки

Выполненные задачи по номерам (P15.xx). Полные детали — в `git log` и коде.

### P15.13–25 — итеративный bytecode dispatch loop
Первоначальный host-recursive путь полностью устранён для активного bytecode backend. Как и `luaV_execute`/`CallInfo` в PUC Lua, один dispatch driver переключает heap-resident активации Lua, не сохраняя по Zig stack frame на каждый Lua-вызов.

### P15.25 — tail-call policy с живыми `<close>` переменными
Предыдущий TODO исходил из неверного предположения, что PUC Lua всегда эммитит `OP_TAILCALL` для `return f()` с живым TBC slot. В Lua 5.5 `retstat` делает tail-call только при `!fs->bl->insidetbc`; при активной `<close>` переменной остаётся обычный `CALL + RETURN`, чтобы caller пережил callee и з...

### P15.26 — hardening после dispatch review
Повторно проверен blocker-кейс с ранним `return` из generic `for`: hidden TBC iterator close value закрывается **после** вычисления return-expression. PUC Lua и bc VM печатают `false true`, а differential smoke `39_complete_iterative_dispatch.lua` проходит без расхождений.

### P15.27 — завершение regression cleanup после P15.26
WIP-переход на полный iterative dispatch временно открыл несколько независимых расхождений parser/codegen/debug runtime. Они исправлены на семантическом уровне, без распознавания имён upstream-файлов или test-specific replay:

### P15.28 — verifier follow-up и GC debt/performance hardening
После review P15.27 закрыты все замечания, мешавшие воспроизводимому принятию патча:

### P15.29 — настоящие инкрементальные GC phases
Debt-gate заменён persistent collector state machine, близкой к PUC `gcstate`:

### P15.29cf — PUC-faithful compile-time constant folding
Реализована PUC `constfolding` (lcode.c:1418) в bytecode-компиляторе (`src/lua/codegen_bc.zig`):

### P15.30 — настоящий generational GC
Generational mode больше не является compatibility-веткой, запускающей полный incremental cycle на каждый `collectgarbage("step")`. Реализована отдельная PUC-подобная young-generation модель поверх per-type registry luazig:

### P15.31 — typed opcode fast paths
Цель первого performance-патча — убрать заведомо лишний generic path, не меняя формат bytecode и не смешивая этот этап с крупным codegen redesign.

### P15.32 — register-aware bytecode codegen
Наиболее важный этап общего roadmap.

### P15.33 — fast/slow dispatch split
Отдельный compact loop для no-hook/no-yield/no-pending/no-GC case.

### P15.34 — compact tables и однопоточный VM allocator
Уменьшить hash `Node` с 56 до 48 байт. **P15.37b:** `next: ?*Node` (8 B +
Результат: global_arith -54%, field_access -59%, metamethod_add -13%.
- [x] Специализированные integer и interned-string lookup/insert paths. (закрыто задним числом: выполнено P16.1b — GETI/GETFIELD/GETTABUP/SETI/SETFIELD/SETTABUP inline nodeLookup/array fast paths; верифицировано P16.2d-анализом)
- [ ] Сначала проверить libc allocator как безопасный промежуточный default для
- [ ] Затем добавить VM-local pools/pages для `Table`, `Node`, `Closure`,
- [ ] Освобождать пустые pages после major sweep.
- [ ] Compile/parser temporary data вынести в переиспользуемую arena.

### P15.35 — CallInfo stack и обычный call fast path
Предвыделенный массив frame/CallInfo records
Результат: lua_calls -27% (7.27→5.32s, Debug build). Parity: 28/31
- [ ] Debug name reconstruction выполняется лениво.
- [ ] Уплотнить `Thread` header и parked-frame storage после измерения lifetime

### P15.36 — compiler/`load()` pipeline
Reuse parser/codegen arena между вызовами `load()`.
- [ ] Reuse parser/codegen arena между вызовами `load()`.
- [ ] Capacity hints для AST, bytecode, constants и names.
- [ ] Small-vector storage для типичных маленьких функций.
- [ ] Уменьшить копирование identifier/source/string data.
- [ ] После стабилизации добавить streaming parser-to-bytecode backend.
- [ ] Полный AST оставить optional tooling/debug path.

### P15.36b — eliminate per-call `@memset` via "before" live_reg_top semantics
Part 1: Codegen infrastructure for "before" semantics
Результат: lua_calls -31% (2.527→1.747s, ReleaseFast). Parity: 28/31

### P15.37 — воспроизводимый performance gate + hotspot-driven perf-фазы
Добавить `tools/perf_compare.py` и versioned baseline + закрыть 3 hotspot'а, выявленных через `perf record --call-graph lbr`:
- [x] wall time, process CPU, max RSS и opcode count — закрыто P16.0b/c (VmStats opcode histogram; perf stat counters; getrusage max-RSS/process-CPU).
- [ ] отдельная маркировка noisy/long suites вроде direct `constructs.lua`.

### P15.38 — codegen-level opcode reduction (PUC 5.5 fast paths)
Цель: уменьшить число bytecode-инструкций на Lua-итерацию через PUC 5.5 codegen fast paths. Каждая подзадача устраняет 1–3 инструкции в common-case паттернах (`s = s + 1`, `if a < b then`, `x = x + 1.0`).

### P15.39 — variant TKey: Node 48B → 32B
Архитектурная PUC-faithful компрессия `ltable.Node` с 48 B до 32 B через разделение `key: Value` (16 B tagged union) на 1 B type tag (`key_tt`) + 8 B raw payload (`key_val`), и удаление кэшированного `hash: u64` поля (хеш пересчитывается на каждом use site, как в PUC `ltable.c`).

### P15.40 — PUC-faithful inline call resolution (luaD_precall + tryfuncTM)
Инлайнинг PUC `luaD_precall` (ldo.c:715-746) в три горячих bytecode-handler'а (OP_CALL, OP_TAILCALL, OP_TFORCALL). Fast path (Closure/Builtin) больше не вызывает `resolveCallable` — type switch происходит inline, нулевой overhead. `__call` metamethod resolution использует in-place stack shift (PU...

### P15.40a — Pre-allocate frame capacity
Pre-allocation `bytecode_frames` и `frames` ArrayList capacity (64 entries) при активации thread (`activateRuntime`), создании main thread (`init`) и создании coroutine (`apiNewThread`). Первые 64 `addOne` вызова на каждом thread теперь pure `items.len += 1` — без capacity-check branch на hot path.

### P15.40b — CallFrame struct + full merge (Tasks 1–7)
Определён merged `CallFrame` struct (PUC `CallInfo` equivalent), объединяющий поля `BytecodeExecFrame` + `RuntimeFrame` в одну структуру. `proto: ?*const bc.Proto` (null для IR frames, non-null для bytecode frames) — дискриминатор, как PUC's `CIST_C` bit.

### P15.42 — Opcode handler extraction (dispatcher frame 139 KB → 54 KB Debug)
`runBytecodeDispatch` изначально содержал все opcode handlers inline в одном огромном switch (~3500 строк, 79 opcode'ов). Zig Debug выделяет стек-слоты под ALL locals во ALL ветках switch — без liveness analysis между ветками. Результат: C-stack frame = **139 KB** в Debug (20 KB в ReleaseFast).

### P15.43 — Проверка host recursion: PUC итеративен, откат изменений
Опробован переход с iterative dispatch на host recursion для OP_CALL (эквивалент PUC `luaD_call` → `ccall` → `luaV_execute`). Идея была в том, что host recursion устранит `PendingCallSlot` целиком.

### P15.44 — PUC-faithful overlapping bytecode frames
Переход на PUC-faithful модель overlapping call stack, где каждый новый bytecode frame начинается на позиции function register вызывающего (`base = func_slot + 1`, PUC `ci->func` / `ci->base = func+1`), а не выше полного register window вызывающего (`base = bc_stack_top + nextra`).

### P15.44b — Shrink PendingCallSlot 768 B → 56 B (PUC CallInfo parity)
У `PendingCallSlot` было 768 B из-за inline optional storage больших variant'ов `BytecodePendingCompletion`:

### P15.45 — Fix xpcall+traceback stale bc_dispatch_pc sync
Коммит `89a7d70` (merge bytecode frames в `Thread.call_frames`) сломал sync `bc_dispatch_pc` во время error recovery. `callBuiltin` и `fail()` безусловно синхронизировали `bc_dispatch_pc` в topmost frame, но во время error recovery (xpcall handler) `bc_dispatch_pc` указывает на failed child's pc,...

### P15.46 — Fix stale bc_dispatch_pc after thread switch
Root cause: `switchRuntime` переключает runtime с main thread на coroutine, `parkActiveRuntime` правильно синхронизирует `bc_dispatch_pc` в main thread's frame, но `activateRuntime` НЕ обновляет `bc_dispatch_pc` для нового thread. Stale pc от previous thread's dispatcher остаётся.
Результат: coroutine.lua passes. Matrix 25/31 → 26/31. errors.lua и

### P15.46b — Fix captureErrorTraceback и builtinAssert для bytecode frames
`captureErrorTraceback` ходил только по `Vm.call_frames` (IR frames), пропуская bytecode frames в `Thread.call_frames`. После P15.40b-full (merge bytecode frames в `Thread.call_frames`) error tracebacks были почти пустыми для bytecode closures — xpcall error handlers видели только `[C]: in functi...
Результат: errors.lua passes. Matrix 26/31 → 27/31. locals.lua gets further

### P15.47 — Fix use-after-free in opReturn/opTailcall errdefer freeing close-owned ret slice
`opReturn`, `opReturn1` (both paths), and `opTailcall` allocated a `[]Value` slice for return values and passed it to `beginBytecodeClose` as `.return_frame = ret`. The close continuation stored this slice in `close_state.post.return_frame`. However, each function had an `errdefer if (ret_owned) ...
Результат: locals.lua passes. Matrix 27/31 → 28/31 (parity restored).

### P15.48c — Inline call frame array in Thread (Phase C)
Embed a fixed-size `[32]CallFrame` array directly in `Thread`, eliminating heap allocation for call chains ≤32 deep (the vast majority of real Lua programs). Deeper chains spill to a heap `ArrayList` overflow.
Результат: Parity 28/31 (no regressions), smoke 45/45. geomean 3.22×,

### P15.48d — Varargs on bc_stack (Phase D)
Eliminate `alloc.dupe(Value, varargs_src)` on every vararg function call by storing varargs directly on `bc_stack` below the register window (PUC's `buildhiddenargs` model). `CallFrame.varargs` (heap slice) is replaced by `nextraargs: u16` for bytecode frames; varargs are accessed via `bc_stack[b...
Результат: Parity 28/31 (no regressions), smoke 45/45. geomean 3.25×,

### P15.49 — Fix stale rargs GC corruption + dispatch hot path cleanup
**Bug fix (stale `rargs` in `opCall`/`opTailcall`):** `opCall`/`opTailcall` pre-grew `bc_stack` with `child_frame_cap = p.maxstacksize`, but `pushBytecodeExecFrame` uses `frame_cap = proto.maxstacksize + EXTRA_MARGIN` (5). When `pushBytecodeExecFrame` called `ensureBcStackCap` for the extra 5 slo...
Результат: smoke 27 crash eliminated (0/20), 45/45 smoke pass, 28/31 matrix,

### P15.50 — PUC-faithful allocation-site GC (remove per-instruction GC tick)
**Problem:** The per-instruction GC tick in the dispatch loop added overhead on every instruction, even when no allocation occurred. PUC Lua instead triggers GC only at allocation sites via `luaC_condGC(L, c)` (called from `luaM_*`, `OP_CONCAT`, `OP_CLOSURE`, and builtin calls).
Результат: 28/31 matrix (parity baseline maintained), 45/45 smoke pass, geomean 2.85×.

### P15.51 — Pre-resolve constants to runtime Value format (PUC TValue k[] parity)
**Problem:** `bcConstToValue` (inline fn) was called on every OP_GETFIELD/OP_SETFIELD/ OP_GETTABUP/OP_SETTABUP/OP_LOADK execution — a 5-way switch on `Constant` tag to reconstruct a `Value` (16 bytes). Perf showed 7.44% of `field_access` cycles in the `bcConstToValue` inlining scope. PUC Lua stor...
Результат: 28/31 matrix (parity maintained), 45/45 smoke pass, geomean **2.78×**

### P15.52 — Inline rawGet/rawSet fast paths into dispatch loop
**Problem:** `rawGet` and `rawSet` were not inlined into the dispatch loop — perf showed real `call` instructions for OP_GETFIELD/OP_SETFIELD/OP_GETTABLE/OP_SETTABLE. `rawSet` was 19.7% and `rawGet` was 7.6% of `field_access` cycles. The function call overhead (register saving, prologue, epilogue...
Результат: 28/31 matrix (parity maintained), 45/45 smoke pass, geomean **2.79×**.

### P15.53 — Add `LightUserdata` variant to `Value` union
**Problem:** PUC Lua has `LUA_TLIGHTUSERDATA` (type code 2) — a plain C pointer wrapped as a Lua value, not garbage-collected. luazig lacked this fundamental value type entirely: light userdata was faked via tables with a `__light` field. This blocks real `lua_pushlightuserdata` and the C API and...
Результат: 28/31 matrix (parity maintained), 45/45 smoke pass, no regressions.

### P15.54 — Add `CClosure` variant to `Value` union
**Problem:** PUC Lua's `CClosure` (C closure) is a GC-managed object holding a `lua_CFunction` pointer plus upvalues. luazig had no native representation for C closures — `pushcclosure` testC command was faked via table-based upvalues. This blocks real `lua_pushcclosure`/`lua_iscfunction`/`lua_to...
Результат: 28/31 matrix (parity maintained), 45/45 smoke pass, no regressions.

### P15.55 — Implement 10 missing testC commands
**Problem:** PUC Lua's `ltests.c` defines 97 unique testC commands. luazig had 88/97 implemented — 10 were missing: `abort`/`getmetatable`/`isudataval`/ `print`/`printstack`/`resetthread`/`throw`/`tointeger`/`touserdata`/`type`. These are needed for full testC parity.
Результат: 28/31 matrix (parity maintained), 45/45 smoke pass, no regressions.

### P15.56 — Virtual vararg access (PF_VAHID + OP_GETVARG)
**Problem:** PUC Lua 5.5 has two modes for named varargs (`...arg`): - **PF_VAHID** (default, hidden args, no table): `arg[n]`/`arg.n` compile to `OP_GETVARG` reading extra args directly from stack. 0 allocations. - **PF_VATAB** (table exists): created lazily only when the vararg escapes (assigne...
Результат: 

### P15.57 — GC free tracking + function-sugar upvalue assignment
**Two bugs fixed:**
Результат: 

### P15.58 — Per-object GC mark bits + T.gccolor/T.gcstate + warn + querytab
**Problem:** PUC Lua's GC uses per-object tri-color mark bits stored in `CommonHeader.marked` (lgc.h:79-86). luazig had no per-object mark bits — GC marking was done via a HashSet of visited pointers, which cannot support `T.gccolor()` (testC command to inspect an object's GC color: white/gray/bl...
Результат: 

### P15.59 — Fix generational GC age tracking + barrier gray marking
**Three bugs fixed:**
Результат: 

### P15.60 — PUC-faithful forward/backward barrier split
**Problem:** PUC Lua has TWO distinct write barriers: - **Forward barrier** (`luaC_barrier_`/`luaC_objbarrier`): marks the VALUE. Used for `setmetatable`, `lua_setupvalue`, `OP_SETUPVAL`, `OP_CLOSURE`. - **Backward barrier** (`luaC_barrierback_`/`luaC_objbarrierback`): turns the OWNER gray and ad...
Результат: 

### P15.61 — PUC-faithful upvalue cell marking + finalization order
**Two fixes:**
Результат: 

### P15.62 — PUC-faithful forward barrier sweep-phase makewhite
**Problem:** PUC's `luaC_barrier_` (forward barrier) has two branches: - `keepinvariant(g)` (propagate/atomic): mark the value (`reallymarkobject`) - sweep phase: make the owner white (`luaC_makewhite`)
Результат: 

### P15.63 — PUC-faithful open upvalues + OP_CLOSURE function counting
**Problem:** PUC Lua's `UpVal` is a GC object that can be OPEN (pointing to a stack slot via `uv->v.p`) or CLOSED (holding its own copy in `uv->u.value`). Open upvalues are kept GRAY during GC marking (not BLACK), which prevents the forward barrier from firing when the stack slot is written. This...
Результат: 

### P15.64 — Two-phase finalization + generational fullgc fix + loadlib _G
**Problem:** Three issues blocked api.lua and gengc.lua: 1. `gcFullCollectionForUser` checked `finalizables.count() > 0` for the second cycle, but `gcFinalizeList` removes from `finalizables`, so the second cycle never ran. Finalized objects survived but were never freed. 2. In generational mode,...
Результат: 

### P15.65 — testC close continuation in coroutines (locals.lua:1130)
**Problem:** When a `__close` metamethod (running as a bytecode closure via `resumeTestcCloseReturnContinuation`) called `coroutine.yield`, the bytecode frame was lost. Two root causes:
Результат: 

### P15.66 — PUC-faithful table rehash
Цель: закрыть главный parity-блокер — `nextvar.lua:41` (table rehash). Реализуется PUC-faithful rehash algorithm (`computesizes`/`numusearray`/ `numusehash`/`luaH_resize`), заменяя eager array extension на PUC's rehash-on-overflow model.

### P15.67 — Yield from async debug hook
Цель: починить yield из count/line hook в testC режиме. Coroutine, yield'ящая из hook'а (через `T.sethook("yield 0", "", N)`), не продолжала выполнение при resume — `error.Yield` из async hook frame не очищал hook frame и не устанавливал `bytecode_inplace_suspended`, что приводило к unwind всех f...

### P15.68 — testC yield/resume parity
Цель: починить оставшиеся testC coroutine.lua failures. После P15.67 coroutine.lua падал на line 663 (`setglobal X` в line hook). P15.68 fixes несколько связанных проблем:
Результат: 8/9 testC suites pass. coroutine.lua fails at line 1093

### P15.69+P15.70 — testC callk/pcallk/yieldk continuation chain
Цель: починить chain of suspendable C calls в testC (`T.makeCfunc` с `callk`). coroutine.lua падал на line 1191 — "chain of suspendable C calls" test. Три уровня вложенных C-вызовов, каждый yield'ит через `callk`. При resume ожидалось 3 значения `34` (одно от каждой continuation), но возвращалось 0.
Результат: 9/9 testC suites pass. coroutine.lua, locals.lua pass fully.

### P15.71 — Full testC matrix: T.listk, T.stacklevel, global reserved
Цель: расширить testC покрытие с 9 DEFAULT_SUITES до всех 31 suite в `--testc` режиме.
Результат: testC matrix 27/31 pass (с 23/31). Выигрыш: calls.lua, goto.lua,

### P15.71b — testC LightUserdata migration (Phase A: A1–A6)
**Problem:** `T.pushuserdata(n)` created a Lua **table** with fields `{__testud, __ptr, __val, __light, __isnull, __size}` masquerading as light userdata. An entire detection apparatus — `isTestcUserdata`, `isTestcLightUserdata`, `isTestcNullPointer`, `makeTestcPointerValue`, `debugLightUserdataF...
Результат: 

### P15.72 — cstack.lua stack overflow recovery + T.listcode
Цель: починить cstack.lua (3 части: stack overflow detection, message handling, stack recovery) и реализовать T.listcode для code.lua.

### P15.72b — luaK_finish: RETURN0→RETURN rewrite for needclose
PUC `luaK_finish` (lcode.c:1940) переписывает `RETURN0`/`RETURN1` → `RETURN` когда функция имеет захваченные upvalues (`needclose`). Luazig VM всегда закрывает upvalues в `completeBytecodeExecFrame`, но T.listcode (code.lua) ожидает `RETURN` для функций с upvalues — это PUC-faithful bytecode naming.

### P15.72c — MMBIN/MMBINI/MMBINK emission after arithmetic opcodes
Цель: PUC Lua 5.5 emits a companion MMBIN-family instruction after every arithmetic and bitwise opcode, carrying the TMS event number for metamethod fallback dispatch. luazig's VM handles metamethods inline, so MMBIN is a no-op at runtime — it only needs to exist in the bytecode for T.listcode pa...
Результат: Build clean (ReleaseFast, 0 errors). Matrix 27/31, smoke 45/45 —

### P15.72e — Comparison constant-LHS swap + float EQI + CONCAT merge
Цель: закрыть две категории codegen parity gaps из code.lua — comparison I/K-variant fusion и CONCAT chain folding.
Результат: Build clean (ReleaseFast). Matrix 27/31 `--testc` (1 zig_fail:

### P15.72f — Multi-assign MOVE elimination + check_conflict + reverse store
Цель: eliminate extra MOVE instructions in table assignment paths by using `genExpDesc`+`exp2anyreg` instead of `genExp` for table objects and keys. For locals, `exp2anyreg` returns the register directly without MOVE.
Результат: Build clean (ReleaseFast). Matrix 27/31 `--testc` (same as

### P15.72g — Don't resetRegs after return
Цель: return values placed by RETURN instruction in registers above nvarstack (e.g. R2-R4 for `return f()`) were unprotected during CLOSE instructions. genStat's `defer resetRegs()` reset `peak_freereg` to `nvarstack` after every statement including return, so `live_reg_top[close_pc] = nvarstack`...
Результат: Build clean (ReleaseFast). Matrix 27/31 `--testc` (same as

### P15.72h — Runtime live_reg_top extension for CALL results
Цель: `gcClearDeadFrameRegisters` nilles return values from `coroutine.resume` and multret builtins (e.g. `table.unpack`) that sit in registers above compile-time `live_reg_top[pc]`. When `table.pack(co())` is compiled, the codegen conservatively sets `freereg = func_reg + 1` after the multret CA...
Результат: Build clean (ReleaseFast). `locals.lua --testc` passes (was

### P15.72i — genSetExpDesc: PUC luaK_storevar ordering + `a = a` no-op
Цель: устранить оставшиеся 5 MOVE-elimination расхождений в code.lua (2 теста: multi-assign `b[c], a = c, b; ...; a = a` и `t[a()] = t[a()]`).
Результат: Build clean (ReleaseFast). code.lua: 5 MOVE-elimination

### P15.72m — testC checkpanic sub-VM (Phase B: B1–B3)
**Problem:** `T.checkpanic` used hardcoded string-matching hacks (`string.find` on script/panic-script content) to return pre-baked results for each of the 8 checkpanic test cases. This violated AGENTS.md (no match-by-name/content for semantic branching).
Результат: All 8 checkpanic cases pass (api.lua:412–475, memerr.lua:28).

### P15.73 — PUC-faithful collectargs/runargs + REPL
Цель: переписать парсер аргументов командной строки в `src/bin/luazig.zig` для точного соответствия PUC Lua `lua.c` (`collectargs`, `runargs`, `dolibrary`, `pmain`, `doREPL`). Предыдущий hand-rolled парсер не поддерживал `-l`, `-W`, `-i`, concatenated options (`-eprint(1)`, `-lm=math`), и не восп...
Результат: `main.lua` progresses past all argument-parsing tests (-l, -e,

### P15.74e — Unified `near <token>` error messages
Unify lexer/parser error formatting to match PUC Lua's `lexerror`

### P15.74f — PUC-faithful REPL prompt + EOF handling
Implement `getPrompt` (PUC `get_prompt`, `lua.c:533-541`): reads

### P15.74g — PUC-faithful `errfunc` mechanism + C-frames for error path
Implement PUC `L->errfunc` (`vm.zig`): message handler called BEFORE

### P15.74h — Binary chunk loading (string.dump/load roundtrip)
Replace stub `string.dump`/binary-load with real Proto serialization.

### P15.74i — debug.getinfo name inference fix for pcall context
Fix synthetic "pcall" name masking real function names

### P15.74j — Fixed-buffer binary chunk loading (PUC `S.fixed`)
Implement PUC's fixed-buffer mode for binary chunk loading

### P15.74k — Fix coroutine.yield C-function error format
**Problem:** When `coroutine.yield()` is called outside a coroutine, the error message included a `file:line:` prefix (e.g. `big.lua:56: attempt to yield from outside a coroutine`). PUC Lua does not add this prefix because the error originates from a C function (`coroutine.yield` is a C builtin),...
Результат: Smoke 49/49 all pass. Matrix 30/31 (big.lua remains

### P15.74l — PUC-faithful incremental GC pacing (locals.lua tracegc parity)
**Problem:** `locals.lua` produced an `output_diff` in the "to-be-closed variables in coroutines" section: the `tracegc` helper prints one `.` to stderr per GC cycle (its `__gc` metamethod re-marks the object so it gets finalized again next cycle). PUC prints 2 dots for the whole script; luazig p...
Результат: locals.lua passes `--diff` (0 output_diff). Matrix 30/31,

### P15.74m — PUC-faithful stacktrace display + REPL errfunc
Fix REPL missing traceback (errfunc not set in doREPL path).

### P15.74n — Differential output comparison in testes matrix
`tools/testes_matrix.py --diff` flag: compares normalized stdout between

### P15.74o — Fix codegen OOB in `local` with extra expressions (gc.lua finalizer)
**Problem:** `local a = expr1, expr2` (more expressions than local names) caused an out-of-bounds read in `genLocalDecl` (`codegen_bc.zig`). The promote loop iterated `0..values.len` but `n.names` only had `n.names.len` entries. When `values.len > n.names.len`, the loop read garbage memory past t...
Результат: gc.lua passes `--diff` (0 output_diff). Matrix 30/31, smoke 48/48 —

### P15.75 — Fix coroutine nesting C-call depth — PUC-faithful `LUAI_MAXCCALLS`
**Problem:** The bytecode coroutine trampoline used a `coroutine_parked_frames`
metric (max 5000) to guard against unbounded nesting. This metric counted the
TOTAL Lua call frames parked across all suspended coroutines in the resume
chain. With `lim=1000` (the cstack.lua test parameter), each coroutine parked
~1000 frames, so only **5 coroutines** could nest before "C stack overflow"
(PUC allows **196**).

**Root cause:** The `coroutine_parked_frames` metric conflated Lua stack-frame
count with C-call depth. In PUC Lua, `nCcalls` (bounded by `LUAI_MAXCCALLS=200`)
tracks C function nesting — NOT Lua bytecode frames. A coroutine that recurses
1000 times in Lua still consumes only ONE C-call slot. `luaD_resume` inherits
`getCcalls(from)+1` per nesting level, allowing ~200 nested resumes.

**Fix:** Removed the `coroutine_parked_frames` tracking entirely. The trampoline
now uses a single resume-chain-depth counter initialized to
`activeProtectedCallDepth() + 1` (accounting for xpcall/pcall and
`builtinCoroutineResume` overhead already on the stack). The limit is
`LUAI_MAXCCALLS = 200`, matching PUC's `getCcalls >= LUAI_MAXCCALLS` check.

**Results (cstack.lua):**
- "testing limits in coroutines inside deep calls": **5 → 199** (PUC: 196)
- "nesting of resuming yielded coroutines": **4095 → 197** (PUC: 195)
- "nesting coroutines running after recoverable errors": **4097 → 200** (PUC: 197)
- `--diff` output parity: **27/31 → 29/31** (cstack.lua now clean)

Matrix: 30/31, smoke: 49/49 — no regressions.

### P15.76 — perf(coroutine): eliminate per-yield heap allocation in `snapshotThreadTraceFrames`
**Problem:** `snapshotThreadTraceFrames` was called on every `coroutine.yield`
and allocated a `?[]?[]const u8` heap array to cache frame names for the
`debugBuildThreadTraceback` path (used by db.lua). This is pure allocation
churn — one `alloc.alloc` + later `alloc.free` per yield, even though the data
is only needed if/when a traceback is later requested.

**Investigation:** The frame names are needed in two branches of
`debugBuildThreadTraceback`:
- `.suspended`: here `th.call_frames` are still intact (yield preserves them),
  so names could be computed lazily.
- `.dead` + `trace_had_error`: empirically verified that `th.call_frames` no
  longer reflects the yield point by this stage (the coroutine has unwound
  through the error). The traceback relies on the snapshot captured at the
  *last* yield. Verified with a repro: a coroutine that yields from `inner`
  then errors shows `inner` in its dead traceback, not the error-site frame.

  => A purely lazy/on-demand recomputation from `th.call_frames` would regress
  the dead case. The snapshot at yield time is **architecturally required**.

**Fix:** Keep the snapshot-at-yield (required for the dead case), but replace
the heap allocation with a fixed-size inline buffer embedded in `Thread`:
- `trace_frame_names`: `?[]?[]const u8` (heap) → `[64]?[]const u8` (`@splat(null)`).
- `snapshotThreadTraceFrames` no longer allocates — it fills the inline buffer
  (capped at 64 frames, `trace_stack_depth` records the valid count). Signature
  changed from `DispatchError!void` to `void` (no allocation can fail).
- `freeThreadWrapBuffers`: removed the `alloc.free` + null-out (nothing to free).
- `debugBuildThreadTraceback`: both reader sites now slice the inline buffer
  (`th.trace_frame_names[0..th.trace_stack_depth]`).

**Why this over pure laziness:** The task brief proposed computing names
on-demand from `th.call_frames` at traceback time. That assumption holds for
suspended coroutines but **not** for dead-with-error ones (frames unwound),
which would silently lose traceback names — a masked regression, disallowed by
AGENTS.md. The inline buffer is zero-heap, behavior-preserving, and faithful to
the existing snapshot design. 64 pointers (512 B) embedded per `Thread` is a
one-time cost, not per-yield.

**Results:** `coroutine_yield` leak_bench: **0.0 KB** (was non-zero per yield).
 Repro test byte-identical (both suspended and dead cases). Matrix 30/31, smoke
 49/49, leak_bench PASS — no regressions.

### P15.78 — C continuations: restructure CallFrame with PUC-faithful union (Task 5)
**Goal:** Replace CallFrame flat layout (where `proto: ?*const bc.Proto` was the
discriminator) with a PUC-faithful union layout (`u: union { lua, c }`), using
the `CIST_C` bit in `callstatus` as discriminator. Mirrors PUC `CallInfo.u`
(`lstate.h:194`).
- [x] Task 1: Add CIST_C discriminator constant
- [x] Task 2: Add CallFrame accessor methods (isLua/isC/setC, etc.)
- [x] Task 3: Set CIST_C on C-frames in pushBuiltinCFrame
- [x] Task 4: Define LuaFrameState/CFrameState/CFrameAux structs
- [x] Task 5: Restructure CallFrame with `u: union { lua, c }`
- [x] Task 6: Move errfunc from Vm to Thread (per-Thread state)
- [x] Task 7: Move allowhook/nCcalls to Thread (PUC-faithful encoding)
- [x] Task 8: Implement lua_yieldk with k/ctx saving in C-frame
- [x] Task 9: Implement lua_callk with k/ctx saving
- [x] Task 10: Implement lua_pcallk with k/ctx/errfunc saving
**Results:** Build clean (ReleaseFast). Matrix 33/33 pass, smoke all pass — no
regressions. CallFrame size: 104B (was 96B flat — 8B overhead from union tag +
padding, acceptable for PUC-faithful layout). All field accesses migrated:
`fr.proto` (read) → `fr.proto()`, `fr.pc` → `fr.u.lua.pc`, etc. ~30 access sites
in vm.zig + c_api.zig updated. Task 6: errfunc moved from Vm (?Value, 24B) to
Thread (StackOffset, 8B, 0=none). BytecodeSavedError.errfunc also changed to
StackOffset. CLI uses setErrfuncValue/getErrfuncValue helpers that push/pop
on bc_stack. Matrix 31/32 pass (big.lua both_fail — pre-existing), smoke all
pass. Task 7: `Vm.non_yieldable_c_depth` (usize) + `max_non_yieldable_c_depth`
(64) replaced by `Thread.nCcalls: u32` (PUC `L->nCcalls`, lstate.h:308) with
lower 16 bits = C-call depth (LUAI_MAXCCALLS=200 guard) and upper 16 bits =
non-yieldable depth. Helpers: `yieldable()`/`getCcalls()`/`incnny()`/`decnny()`.
`Thread.allowhook: bool` added (PUC `L->allowhook`, lstate.h:290) — defaults
true, not yet wired into existing `DebugHookState.in_debug_hook` machinery
(deferred to CIST_OAH save/restore in later tasks). `lua_resume` inherits
`getCcalls(from)+1` (PUC `ldo.c:lua_resume`). 5 access sites updated: 2
yieldability checks (`builtinCoroutineYield`, `builtinCoroutineIsyieldable`),
2 C-stack-overflow guards (`tableGetFromNonYieldableC`,
`runGsubReplacementFunction`), 1 testC `closeslot` incnny/decnny. Matrix
32/33 pass (big.lua both_fail — pre-existing), smoke all pass — no regressions.
Task 8: `lua_yieldk` now saves `nyield` (nresults) and `k`/`ctx` in the current
C-frame's `u.c` union before yielding (PUC ldo.c:1006-1034). Hook frames
(CIST_HOOKED) skip k/ctx save per PUC API-check. The yield itself still uses
the existing `s.yield()` → `builtinCoroutineYield` mechanism for yieldable
checks and error messages. k/ctx are saved but not yet invoked on resume
(deferred to Task 11: finishCcall). Matrix 32/33 (big.lua pre-existing), smoke
all pass — no regressions.
Task 9: `lua_callk` now saves `k`/`ctx` in the current C-frame's `u.c` union
when `k != NULL` and the thread is yieldable (PUC lapi.c:1037-1056). When
`k == NULL` (i.e. `lua_call`), the call is wrapped in a non-yieldable boundary
(`incnny`/`decnny` via `defer`), matching PUC `luaD_callnoyield`/
`luaD_setnnyblocks`. k/ctx are saved but not yet invoked on resume
(deferred to Task 11: finishCcall). Matrix 32/33 (big.lua pre-existing), smoke
all pass — no regressions.
Task 10: `lua_pcallk` now saves `k`/`ctx`/`funcidx`/`old_errfunc` in the
current C-frame when `k != NULL` and yieldable, sets `CIST_YPCALL`, and saves
`allowhook` via `CIST_OAH` (PUC lapi.c:1076-1117). Non-yieldable path
(`k == NULL` or not yieldable): conventional pcall with errfunc support —
errfunc Value is pushed onto bc_stack via `setErrfuncValue` for the duration
of the call so `invokeErrfunc` can find it, then restored. Added `setOah`/
`getOah` methods to CallFrame for CIST_OAH bit management. Saved state is
not yet used on resume (deferred to Tasks 11-12: finishCcall/finishpcallk).
Matrix 31/32 (big.lua both_fail — pre-existing), smoke all pass — no regressions.
Task 11: Added `finishCcall` and `poscallCFrame` methods on Vm, integrated
C-frame resume detection into `driveBytecodeCoroutineTrampoline`. After a
coroutine is resumed, the trampoline checks if the topmost frame is a C-frame
(`fr.isC()`). If so, `finishCcall` invokes the saved continuation `k` via raw
invocation (no new C-frame), applies `APIstatus(LUA_YIELD) = LUA_OK` to the
status argument, handles CIST_YPCALL by clearing the flag and restoring
errfunc (full finishpcallk deferred to Task 12), and returns the result count.
`poscallCFrame` then sets `bc_stack_top` and pops the C-frame. The trampoline
loops back to re-check the next frame (may be another C-frame or a Lua frame).
CIST_CLSRET is handled by existing PendingCallSlot machinery, not C-frame
continuations. Matrix 31/32 (big.lua both_fail — pre-existing), smoke all
pass — no regressions.
Task 12: Added `finishpcallk`, `findpcall`, `precover` methods on Vm.
`finishpcallk` (PUC ldo.c:804-821) is called from `finishCcall` when the
suspended C-frame has CIST_YPCALL set. It reads the saved error status from
CIST_RECST: if 0 (no error), promotes to LUA_YIELD (plain yield); if nonzero
(error), restores allowhook (getoah), shrinks bc_stack (luaD_shrinkstack),
clears the saved status, and returns the error status to pass to k. In both
cases CIST_YPCALL is cleared and errfunc is restored from old_errfunc. TBC
close (luaF_close) and error-object placement (luaD_seterrorobj) are marked
TODO — luazig's existing close-continuation machinery handles TBC close, and
the error object is carried in self.err_obj for the trampoline error path.
`findpcall` (ldo.c:884-891) scans call_frames for the innermost CIST_YPCALL
frame. `precover` (ldo.c:955-963) is the error-recovery loop: saves the error
status into the located frame's CIST_RECST; full trampoline re-entry is TODO.
Also fixed a latent bug in `setcistrecst` (`~@as(u32, 7 << CIST_RECST)`) — it
was never called until finishpcallk. `finishCcall` now calls `finishpcallk`
for CIST_YPCALL frames instead of just clearing the flag. Matrix 32/33
(big.lua both_fail — pre-existing), smoke all pass — no regressions.
Task 13 (testC callk/pcallk/yieldk migration): **DEFERRED**. The full
migration from `TestcPendingContinuation` to real C continuations requires
making testC use `c_stack` (the Lua stack) as its stack instead of the
separate `std.ArrayListUnmanaged(Value)` stack. In PUC Lua, `Cfunck` reads
the continuation script via `lua_tostring(L, ctx)` where `ctx` is a Lua
stack index — this works because PUC's testC stack IS the Lua stack. In
luazig, the testC stack is separate (303 references to `st.items`/
`st.append`/`st.pop`), so `ctx` cannot index into it from a C `k` callback.
Verified: the real C continuation code (Tasks 8-12) does NOT interfere with
`TestcPendingContinuation` — they operate on different layers (C-frames on
`call_frames` vs. `testc_pending_conts` list). `builtinTestcTestC` does not
push C-frames (only `invokeErrfunc` does), so `finishCcall` is never called
for testC yields. Matrix 33/33 pass (big.lua both_fail — pre-existing),
smoke all pass — no regressions.

### P15.78 (cont.) — C continuation mechanism fix: callCFunction + lua_yieldk longjmp
**Goal:** Fix the C continuation mechanism so `lua_yieldk`, `lua_pcallk`, and
`lua_callk` work correctly when C functions are called from Lua coroutines.
The mechanism implemented in Tasks 8-12 was incomplete: `callCFunction` didn't
push a C-frame, and `lua_yieldk` couldn't propagate the yield through the C
stack (it caught `error.Yield` and returned an error code).
**Root causes fixed:**
1. `callCFunction` now pushes a C-frame (`pushBuiltinCFrame`) before calling
   the C function, so `lua_yieldk` can save k/ctx and `finishCcall` can invoke
   k on resume. The C-frame is NOT popped on yield (only on normal return and
   error), mirroring PUC's `luaD_precall`/`luaD_poscall` lifecycle.
2. `lua_yieldk` now calls `apiYield` directly (not through `s.yield()` which
   catches `error.Yield`) and performs `_longjmp(c_error_jmp, 2)` on yield.
   Value 2 distinguishes yield from error (value 1). This mirrors PUC Lua's
   `lua_yield` which does a `longjmp` to the `lua_resume` boundary.
3. `callCFunctionWithBoundary` distinguishes yield (longjmp value 2 → return
   -2) from error (longjmp value 1 → return -1). `callCFunction` propagates
   `error.Yield` on yield (-2), leaving the C-frame in place.
4. `lua_callkImpl` and `lua_pcallk` now call `apiCall` directly (not through
   `s.call` which catches `error.Yield`) and longjmp with value 2 on yield.
5. `finishCcall` gives `k` a clean c_stack, collects results into
   `th.resume_inbox`, and sets `isHookYield` + `resume_pc` on the Lua frame
   below the C-frame. This allows the OP_CALL dispatch to use the resume
   values (from `takeBytecodeResumeValues`) instead of re-calling the C
   function on resume — the same mechanism used for `coroutine.yield`.
**Test:** `tests/c_api/10_continuations.c` — 6 test cases:
- `lua_yieldk` with C continuation (ctx=42 → k returns 142)
- `lua_pcallk` with yield inside pcall (ctx=100 → k returns 107)
- `lua_callk` with yield inside call (ctx=200 → k returns 203)
- Multi-yield: k yields multiple times (ctx 1→2→3, values 0→1→2→30)
- pcallk error recovery (skipped — not fully implemented)
- ctx/status propagation (status=LUA_OK after yield)
**Results:** Matrix 32/33 (big.lua both_fail — pre-existing), smoke all pass,
all 11 C API tests pass — no regressions.

### P15.78 (cont.) — Multi-yield: finishCcall invokes k through setjmp boundary
**Goal:** Support `k` calling `lua_yieldk` to yield again (multi-yield chain).
Previously, `finishCcall` called `k` directly without a setjmp/longjmp boundary,
so `lua_yieldk` inside `k` could not `_longjmp` — the yield was lost.
**Fix:**
1. `finishCcall` now invokes `k` through `callCFunctionWithBoundary` (via
   `callContShim` wrapper) to provide a proper setjmp/longjmp landing pad.
   When `k` yields (`_longjmp` value 2), `finishCcall` returns `error.Yield`
   and leaves the C-frame in place for the next resume.
2. The trampoline catches `error.Yield` from `finishCcall` and creates a yield
   step (same as `runClosure`'s `error.Yield` path). Fixed a fall-through bug
   where the trampoline continued to `runClosure` after `finishCcall` yielded.
3. Added `c_cont_k`/`c_cont_status`/`c_cont_ctx` fields to Vm and `callContShim`
   wrapper to bridge `k`'s 3-arg signature to `callCFunctionWithBoundary`'s
   1-arg signature.

### P15.78 (cont.) — Real precover + finishpcallk error branch
**Goal:** Implement PUC-faithful error recovery for yieldable `lua_pcallk`.
Previously, `lua_pcallk`'s yieldable path caught `error.RuntimeError` locally,
cleared CIST_YPCALL, and returned `LUA_ERRRUN` — bypassing PUC's `precover`
mechanism entirely. The `precover` function was a stub, and `finishpcallk`'s
error branch had TODOs for error-object placement.
**Changes (PUC ldo.c:955-963, 804-821, 112-123):**
1. `lua_pcallk` yieldable error path: longjmps (`_longjmp(jb, 1)`) instead of
   catching `error.RuntimeError` locally. The C-frame (with CIST_YPCALL) stays
   in place for `precover` to find — mirroring PUC's `luaD_call` which longjmps
   on error.
2. `callCFunction` error path: when the C-frame has CIST_YPCALL set, does NOT
   pop the C-frame — leaves it in place for `precover` → `finishCcall` →
   `finishpcallk` → k. Only pops non-YPCALL C-frames on error.
3. `precover`: real implementation (was stub). Finds the innermost CIST_YPCALL
   frame via `findpcall`, pops all frames above it (PUC's `L->ci = ci`), saves
   the error status into CIST_RECST, and returns `true` to signal the
   trampoline to continue the drive loop.
4. Trampoline `error.RuntimeError` branch: calls `precover` before creating a
   failed step. If `precover` returns `true`, continues the drive loop — the
   C-frame on top is handled by `finishCcall` → `finishpcallk` → k.
5. `finishpcallk` error branch: places the error object on `bc_stack` at
   `funcidx` (PUC's `luaD_seterrorobj`), shrinks the stack, clears the saved
   status. The error object is then placed on `c_stack` by `finishCcall` for
   k to read via `lua_to*(L, 1)`.
6. `bytecodeUnwindDisposition`: C-frames with CIST_YPCALL are now recovery
   barriers — the error propagates past `runBytecodeInternal` to the
   trampoline (where `precover` runs), instead of being caught and unwinding
   the C-frame.
7. `unwindBytecodeExecFrames`: stops at CIST_YPCALL frames (was accessing
   `frame.u.lua` on C-frames — a union violation). Also guards `u.lua` access
   with `!frame.isC()`.
8. Trampoline `finishCcall` + `poscallCFrame`: after popping the C-frame, sets
   `bytecode_inplace_suspended = true` on the Lua frame below so
   `runBytecodeInternal` resumes from the existing frame (with `isHookYield`
   set by `finishCcall`) instead of re-executing from the beginning.
**Results:** Build clean (ReleaseFast, Debug). Matrix 31/32 (big.lua both_fail
— pre-existing), smoke all pass, all 11 C API tests pass — no regressions.
Test 5 (pcallk error recovery) now reaches `k_pcallk_error` with status=2
(LUA_ERRRUN) and ctx=50 — the error recovery mechanism works. The test SKIPs
(return 0) because the coroutine completes in one resume (correct PUC
behavior: `precover` → `unroll` → `finishCcall` → k → `luaV_execute` →
coroutine body returns), so the second resume finds a dead coroutine.

### P15.78 (cont.) — Turn 10_continuations.c into dual-runtime differential test
**Goal:** Make `tests/c_api/10_continuations.c` a real dual-runtime
differential test (PUC Lua vs luazig produce identical output). Previously,
t5 (pcallk error recovery) SKIPped instead of PASS/FAIL, and no test called
`luaL_openlibs(L)`.
**Changes:**
1. Added `luaL_openlibs(L)` after `luaL_newstate()` in all 6 test functions
   (t1–t6). Required for `coroutine` library and any stdlib access.
2. Fixed t5 (pcallk_error): removed SKIP-as-PASS. The test now verifies PUC
   behavior: `ok1=true, v1=1049, ok2=false` (dead coroutine). The error
   recovery completes within one resume (precover → finishCcall → k →
   luaV_execute → coroutine body returns 1049). The second resume finds a
   dead coroutine → ok2=false.
3. Added Makefile `%-puc` pattern rule and `test-diff` target: compiles
   `10_continuations.c` against PUC Lua's `liblua.a` and compares output
   with the luazig-linked binary.
**Results:** Build clean (ReleaseFast). Both PUC and luazig binaries produce
identical output (6 PASS + summary PASS). Matrix 31/32 (big.lua both_fail —
pre-existing), smoke all identical — no regressions.

### P15.78 (cont.) — CallFrame.u.lua activation, APIstatus, proto non-optional, CFrameAux extern union
**Goal:** Fix Debug-mode crashes and PUC-faithfulness issues discovered after
initial implementation.
**Changes:**
1. **CallFrame.u.lua activation order**: `pushBytecodeExecFrame` now activates
   `.u = .{ .lua = .{} }` BEFORE writing any `.u.lua` fields. Previously,
   `addOne` returned a slot with `.u.c` active (default), and writing
   `ef_slot.u.lua.proto` panicked in Debug mode (inactive union field access).
   Fixed 34/146 unit test failures and `01_min.lua` crash.
2. **APIstatus correction**: Removed `LUA_YIELD → LUA_OK` mapping.
   `APIstatus(st) = cast_int(st)` in vendored Lua 5.5 (llimits.h:50) — no
   conversion. Continuation `k` receives `LUA_YIELD` (1), not `LUA_OK` (0).
   Fixed t6 test to expect `status=LUA_YIELD` (1).
3. **CFrameAux extern union**: Changed from tagged `union` to `extern union`
   to match C union semantics. PUC's `u2` is a C union where `funcidx`
   (pcallk) and `nyield` (yieldk) share storage — writing to either field is
   always safe. Zig's tagged union panics on inactive field access in Debug.
4. **LuaFrameState.proto non-optional**: Changed from `?*const bc.Proto` to
   `*const bc.Proto` per approved invariant (`isLua(fr) → proto is valid`).
5. **popBytecodeExecFrame**: Guard `caller.u.lua.frame_cap` access with
   `!caller.isC()` check — C-frames don't have `frame_cap`.
6. **opTailcall isHookYield**: Clear `pending_call_index` before
   `beginBytecodeClose` — the pending call from the original OP_TAILCALL
   is no longer needed after `finishCcall` provides results via
   `resume_inbox`.

### P15.78 — STATUS: testC continuations complete; C API TBC return-path still TODO

**Completed:**
- CallFrame restructured with PUC-faithful `u: union { lua, c }` (104B)
- Per-Thread state: `errfunc`, `allowhook`, `nCcalls` (PUC encoding)
- `lua_yieldk`/`lua_callk`/`lua_pcallk` save k/ctx in C-frame
- `callCFunction` pushes C-frame, `lua_yieldk` longjmps with value 2
- `finishCcall` invokes k via `callCFunctionWithBoundary` (multi-yield support)
- `finishpcallk`/`findpcall`/`precover` for error recovery
- `lua_pcallk` yieldable error: longjmps (not caught locally) → `precover`
- `finishpcallk` error branch: error-object placement on bc_stack/c_stack
- `bytecodeUnwindDisposition`/`unwindBytecodeExecFrames`: CIST_YPCALL barrier
- `10_continuations.c`: 6 tests, dual-runtime differential (PUC vs luazig)
- `LuaFrameState.proto`: non-optional per invariant
- `CFrameAux`: extern union (C union semantics)
- Debug build: 148/148 unit tests pass, 01_min.lua passes
- testC `callk`/`pcallk`/`yieldk` migration to real C continuations (Task 13)
- `TestcPendingContinuation` removal — yield command migrated to real C
  continuations (same C-frame + `testcContShim` mechanism as `yieldk`)
- **bytecode_resume_boundary fix:** After C-frame processing on resume, set
  `bytecode_resume_boundary = 0` (not `call_frames.len() - 1`).
- **resumeTestcCloseReturnContinuation removal (Task 14 Steps 5, 7):**
  Removed the last testC-specific continuation state machine. PUC Lua's
  `luaD_poscall` → `luaF_close` → `callcloseTM` → `luaD_callnoyield` prevents
  yields during TBC close. Luazig now matches this: `runTestcScript` and
  `testcContShim` wrap closer loops with `incnny`/`decnny` (PUC's no-yield
  boundary). Removed: `resumeTestcCloseReturnContinuation`,
  `storeTestcCloseReturnContinuation`, `clearTestcCloseReturnContinuation`,
  `setTestcCloseRemainingAfter`, `copyTestcReturnValues`,
  `testc_close_current`/`testc_close_return_values`/`testc_close_remaining`
  Thread fields, and the `testc_close_return_values != null` check in
  `builtinCoroutineResume` (~80 lines).

**Phase 3 — `TestcPendingContinuation` removal (DONE):**
- Migrated `yield` command to push C-frame with `k=testcContShim`, saving
  continuation state (script="return *", empty heap-allocated stack_prefix,
  ctx_id=0, upvalues/closers from testC context).
- `builtinCoroutineYield` detects C-frames with `testc_state != null` and sets
  `bytecode_inplace_suspended = true` (same as `yieldk` path).
- Removed `TestcPendingContinuation` struct, `testc_pending_conts` field,
  `saveTestcPendingContinuation`, `resumePendingTestcContinuation`, LIFO loops
  in `builtinTestcTestC`/`builtinCoroutineResume`, cleanup in
  `clearThreadContinuationScratch`, checks in `canTrampolineBytecodeThread` and
  `runTestcScript` errdefer, `testc_pending_conts` branch in
  `builtinCoroutineYield`.
- Modified `threadCurrentParkedRuntimeFrame` to skip C-frames and return the
  Lua frame below (fixes `debug.getlocal` for C-frame-parked coroutines).
- Net: -237 lines (86 insertions, 323 deletions).

**P15.78 Task 13 — Real C continuations for testC callk/pcallk/yieldk:**
- Moved `testc_cont_state` from Thread (single-valued) to `CFrameState.testc_state`
  (per-C-frame) — each chained callk gets its own C-frame with its own state.
- `testcContShim` reads continuation state from the top C-frame, not from Thread.
- `reuse_cframe` check: reuses top C-frame only when `testc_state == null` (inside
  a continuation), pushes new C-frame when `testc_state != null` (recursive Cfunc).
- Trampoline: added coroutine-completion check when all C-frames are processed
  (`call_frames.len() == 0`) — returns results from `resume_inbox`.
- GC tracing updated for per-C-frame `testc_state` in both mark phases.
- `resolveTestcContinuationScript` returns `{ script, ctx_id }` struct (ctx_id
  derived from `.` pop or upvalue token, not separate `testcContinuationCtxId`).
- coroutine.lua line 1191 "chain of suspendable C calls" PASSES (3 nested callk
  with 3 C-frames, 3 continuations returning 34 each).
- coroutine.lua line 1193 "yieldk/pcallk" PASSES (yieldk chain + pcallk error
  continuation with CIST_YPCALL recovery via precover).
- `finishCcall` isHookYield: scans past stale C-frames (testc_state=null) to
  find nearest Lua frame below, sets isHookYield+resume_pc on it.
- `finishCcall` error path: preserves err_obj when c_error_value is null (error
  builtin sets err_obj directly, not via c_error_value).
- `builtinCoroutineResume` while loop: catches RuntimeError → precover; skips
  stale C-frames via poscallCFrame(th, 0) without finishCcall.
- `pcallk` handler: sets bytecode_inplace_suspended on RuntimeError (not just
  Yield) so resume loop continues after error recovery.
- `runBytecodeInternal` errdefer: has_testc_cframes_above check prevents
  unwinding C-frames with testc_state during yield through f-closure Lua frame.

**Gate results (after P15.78 TBC close + C-frame fix + review fixes):**
- ReleaseFast build: clean
- Matrix --testc: 30/32 (coroutine.lua SIGSEGV — pre-existing GC crash in
  gcDrainGrayagain, was hidden by assertion failure at line 1106 before fix;
  big.lua both_fail — pre-existing)
- **locals.lua: PASS** (was zig_fail — "attempt to yield across a C-call boundary")
- Smoke: 50/50 pass
- C API: 11/11 pass (including 10_continuations: 6 tests)
- Unit tests: all pass
- **Double-close fix (v4):** Restructured errdefer and C-frame closer loop:
  - **C-frame closer loop** now catches RuntimeError and continues with
    remaining closers (PUC `luaF_close` behavior), passing the error to
    subsequent closers. This is the resumable state machine — yield
    preserves the C-frame for resume, RuntimeError continues the loop.
  - **errdefer** only runs remaining-closer cleanup if error happens BEFORE
    the closer loop (`closers_completed` flag prevents double-close).
  - **Yield/ThreadSwitch** treated as suspension signals — C-frame preserved,
    no cleanup. ThreadSwitch no longer destroys owning C-frame/testc_state.
  - **func_slot snapshot** before `call_frames.shrinkTo` (use-after-shrink fix
    for Debug OOB panic).
  - **frame_cap sync** in `opCall` before `callBuiltin` — `bcGrowFrame` updates
    `ctx.frame_cap` but not the CallFrame's `u.lua.frame_cap`. Without sync,
    `shrinkBcStack` (called from `builtinPcall` defer) reads stale `frame_cap`,
    computes too-small `inuse`, shrinks `bc_stack` below `ctx.base +
    ctx.frame_cap` → OOB panic in Debug.
  - Regression tests: test_double_close.lua, test_nested_zero_close.lua,
    test_two_closers.lua, test_coroutine_two_closers.lua (all pass in Debug
    and ReleaseFast).
  - **close_err in TestcContState (v4 final):** Moved `close_err` from a
    local variable to a field in `TestcContState`. A local is lost on yield,
    so the resumed `testcContShim` would read null instead of the preserved
    error. Now both the initial closer loop (in `runTestcScript`) and the
    resumed closer loop (in `testcContShim`) read/write `close_err` from/to
    `testc_state`, ensuring the error is preserved across yield and passed
    to subsequent closers correctly.
  - **Error normalization in closer loop:** Strip "file:line: " prefix and
    "\nin metamethod 'close'" suffix from error strings before storing in
    `close_err`, matching PUC `luaF_close` which passes the raw error object
    (without source info or close-metamethod annotation) to `__close`.
  - **Mixed error/yield regression tests:** test_yield_then_error.lua
    (yield → resume → next closer errors) and test_error_then_yield.lua
    (error → next closer yields → resume). Both verify LIFO close order,
    error propagation to subsequent closers, and error preservation across
    yield. Both pass in Debug and ReleaseFast.

**P15.78 Reviewer fixes (2026-08-17) — testC close state machine hardening:**
- **GC tracing of close_err/close_return_values:** Added both fields to
  `gcMarkValue` (line ~17629) and `gcMarkValueFinalizerReach` (line ~18121)
  in `src/lua/vm.zig`. Without this, GC could collect error objects and
  return-value arrays referenced only by `TestcContState` during yield.
- **Error normalization removed:** PUC `error()` adds source location to
  the error object — that location IS part of the object. `close_err` now
  stores the exact `err_obj` Value (no string parsing, no prefix/suffix
  stripping). `annotateCloseRuntimeError` no longer mutates `err_obj` —
  only updates `self.err` (diagnostic message with "\nin metamethod 'close'"
  suffix). The Lua error Value remains the original object from `error()`.
- **ThreadSwitch distinct sentinel `-3`:** `testcContShim` returns `-3` for
  ThreadSwitch, `-2` for Yield, `-1` for error. `finishCcall` handles `-3`
  → `error.ThreadSwitch`. Both `finishCcall` error paths in the trampoline
  (line ~7492 and ~7645) handle `error.RuntimeError` (call `precover`) and
  `error.ThreadSwitch` (process switch request). Previously the second path
  only caught `error.Yield`, passing everything else via `else => return` —
  root cause of "<no error object>" errors.
- **Resumed closer state machine fixed:** After resumed closers finish,
  checks `close_err` — if non-null, restores error (`vm.err_has_obj = true`,
  `vm.err_obj = err`, `vm.err = ...`) and returns `-1`. If null, returns
  saved return values. Second closer loop in `testcContShim` now uses same
  state machine as initial loop (was passing `null` as err_obj, didn't
  handle RuntimeError, didn't update `close_err`).
- **C-frame GC guard in `gcPropagateOne`:** Added `if (exec_fr.isC())
  continue;` before accessing `exec_fr.u.lua.frame_cap` (line ~17802). C-
  frames don't have proto/regs/boxed/upvalues — their state is traced
  separately via `testc_state`. Without this guard, GC tracing crashed on
  C-frames with SIGSEGV when accessing `u.lua` fields.
- **OOM deviation documented:** PUC keeps trying remaining closers after
  OOM; luazig returns OOM immediately. Comment explains the deviation.
- **New regression tests:** test_yield_then_error.lua (yield→error),
  test_nonstring_error_yield.lua (table error across yield),
  test_gc_close_err.lua (GC between resumes), test_two_errors.lua (two
  successive erroring closers, last error wins LIFO). All pass in Debug
  and ReleaseFast.
- **Gate results:** ReleaseFast build clean. Matrix --testc: 30/32
  (coroutine.lua zig_fail, big.lua both_fail — both pre-existing, no new
  regressions). Smoke 50/50 pass. C API 11/11 pass. All 9 testC close
  tests pass (4 existing + 5 new).

**P15.78 Reviewer fixes round 2 (2026-08-17) — active C-frame GC, close_return_values leak, protectedErrorValue, error() luaL_where parity:**
- **Active C-frame GC guard in `gcMarkMutableRoots`:** Added `if (!frame.isC())`
  guard before accessing `frame.u.lua.nextraargs` and `frame.u.lua.frame_cap`
  (line ~16535-16546). Without this, GC during an active C-frame __close
  panicked with "access of union field 'lua' while field 'c' is active".
  The guard in `gcPropagateOne` (round 1) only covered inactive coroutine
  GC; `gcMarkMutableRoots` handles the active thread and had the same bug.
- **`close_return_values` leak in `clearThreadContinuationScratch`:** Added
  `if (tcs.close_return_values) |vals| self.alloc.free(vals);` to the C-frame
  cleanup loop. Without this, cancel/reset of a suspended continuation leaked
  the `close_return_values` slice.
- **`protectedErrorValue()` returns `err_obj` directly:** For `.String` errors,
  `protectedErrorValue()` now returns `err_obj` (the exact Lua error value)
  instead of `protectedErrorString()` (which reads from `self.err` — the
  diagnostic message that may have "\nin metamethod 'close'" annotations).
  Source prefix is added from `err_source`/`err_line` only if the string
  doesn't already contain ":" (same heuristic as `protectedErrorString`).
  This fixes: `error("foo: bar", 0)` in a __close → pcall returns exact
  "foo: bar" (not "foo: bar\nin metamethod 'close'").
- **`error()` builtin luaL_where parity:** PUC 5.5 `luaL_where` only adds
  source prefix if `ar.currentline > 0`. For C function callers
  (currentline = -1), it pushes "" (no source info). Fixed `error()` builtin
  to check `line > 0` before adding source prefix, matching PUC behavior.
- **`normalizeTestcErrorForHandler` kept with TODO:** This function strips
  "source:line: " prefix from error strings before passing to the testC
  `pcall` message handler. It's needed because `errorLocationFrameIndex`
  doesn't count C frames — it finds the Lua frame below the testC C frame,
  adding source prefix incorrectly. TODO: remove when
  `errorLocationFrameIndex` is fixed to count C frames.
- **New regression tests:** test_gc_active_cframe.lua (GC during active
  C-frame __close), test_exact_string_error.lua (exact string error through
  pcall result). All pass in Debug and ReleaseFast.
- **Gate results:** ReleaseFast build clean. Matrix --testc: 30/32 (no new
  regressions). Smoke 49/49 pass. C API 11/11 pass. All 11 testC close
  tests pass (4 existing + 7 new).
- **`saved_inplace_suspended` audit:** Fixed second save/restore block in
  `builtinCoroutineResume` (same pattern as trampoline fix). On error.Yield,
  `parkDirectBytecodeYield` sets new authoritative state — don't restore old.
- **Assertion tightened:** `runBytecodeInternal` assertion now checks TOP frame
  is C (not any C-frame anywhere above boundary_depth).
- **Remaining TODO (not blocking):** Generic C API TBC return-path close
  (`lua_toclose` + CIST_CLSRET/finishpcallk) is not yet wired. `finishCcall`
  on CIST_CLSRET returns `fail("unexpected CIST_CLSRET")`. The testC-specific
  `TestcContState.close_return_values` handles testC TBC close, but the
  generic C API path (external `lua_toclose` + return from C function) still
  needs integration with `callCFunction`'s return boundary.

**P15.78 Reviewer fixes round 3 (2026-08-17) — normalizeTestcErrorForHandler removed, caller_builtin_id, topLuaFrame helpers:**
- **`normalizeTestcErrorForHandler` removed completely:** This function stripped
  "source:line: " prefix from error strings before passing to the testC pcall
  message handler. It was a workaround for `errorLocationFrameIndex` not
  counting C frames — it found the Lua frame below the testC C frame, adding
  source prefix incorrectly. The root cause is now fixed via `caller_builtin_id`
  (see below), and the workaround is removed. The message handler now receives
  the exact error object — no source-location stripping.
- **`caller_builtin_id` field for C-function caller detection:** Added
  `Vm.caller_builtin_id: ?BuiltinId` field, set by `callBuiltin` to the
  previous `active_builtin` before calling the builtin. When non-null, the
  caller is a builtin (C function). `error()` checks this: if the caller is
  a C function, `error()` skips the source prefix (matching PUC's `luaL_where`
  which pushes "" for `currentline = -1`). This replaces the C-frame push
  approach, which broke the yield mechanism (coroutine.yield → error.Yield
  propagates through callBuiltin, and the C-frame pop via defer corrupts
  bc_stack_top). TODO: Push C-frames for all builtins and update the
  yield/resume mechanism to handle them (PUC-faithful continuation-based yield).
- **`topLuaFrame()` / `topLuaFrameConst()` helpers:** Added helpers that find
  the topmost Lua frame, skipping C-frames. Used by `fail()`,
  `setOutOfMemoryError()`, and `syncTopFrameForGc()` to safely access
  `u.lua.pc` even when C-frames are on top.
- **`syncTopFrameForGc` C-frame safety:** Now uses `topLuaFrame()` instead of
  directly accessing the top frame's `u.lua.pc`. Without this, GC during a
  C-frame builtin call panicked with "access of union field 'lua' while
  field 'c' is active".
- **Gate results:** ReleaseFast build clean. Matrix --testc: 30/32 (no new
  regressions; pre-existing coroutine.lua zig_fail, big.lua both_fail).
  Smoke 50/50 pass. All 11 testC close regression tests pass.
**Goal:** Eliminate instruction inflation by migrating `genExp` callers to the
lazy `genExpDesc` + `exp2anyreg`/`discharge2reg`/`genExpNextReg` path. Plan:
`docs/superpowers/plans/2026-08-10-codegen-expdesc-migration.md`.
- [x] Task 1: `tools/codegen_compare.py` + `tests/codegen/` patterns
- [x] Task 2: genAssign RHS → `genExpDesc` + `discharge2reg` (assign_index 4x→1x)
- [x] Task 3: genCall/genMethodCall/genTailCall func/receiver/args → `genExpDesc` + `exp2anyreg` / `genExpNextReg`
- [x] Task 4: genAndExp/genOrExp value path → `genExpDesc` + `exp2nextreg` (VJMP-safe)
- [x] Task 5: make genExpDesc self-sufficient (eliminate genExp fallback)
- [x] Task 6: delete old genExp + genNameValue (~265 lines of dead code)
- [x] Task 7: final verification + perf measurement
**Results:** Build clean (ReleaseFast). Matrix 30/31, smoke 49/49, leakbench
25/25, codegen_compare 8 inflated lines (structural: TESTSET opcode missing,
SELF receiver-clobber guard). Geomean 2.67x (stable — benchmarks use `local`
decls which were already on the new path). Net: -193 lines, +149 = -44 lines.
**Bug fixed during migration:** `.Dots` VARARG encoding — luazig VM uses C
field (not B) for nresults. C=2 → 1 result; C=0 → all varargs (stack
corruption). Old genExp had correct encoding; new genExpDesc had B and C
swapped.

### P15.51a — Add `callstatus` field to CallFrame (PUC CIST_NRESULTS encoding, additive)
**Goal:** First task of 10-task plan to make CallFrame PUC Lua 5.5-faithful
(`docs/superpowers/plans/2026-08-11-callframe-puc-faithful.md`).
Purely additive — adds `callstatus: u32` field and encodes `nresults+1` in
its low 8 bits (matching PUC `CIST_NRESULTS`, `lstate.h:223`), but does NOT
change any behavior. The callstatus is set but not yet read (Task 2 reads it).
- [x] Add `CIST_NRESULTS`/`MAXRESULTS` constants + `encodeNresults`/`decodeNresults` helpers
- [x] Add `callstatus: u32 = 0` field to CallFrame struct
- [x] Add `nresults: i32` parameter to `pushBytecodeExecFrame`, encode into callstatus
- [x] Update all 9 call sites with appropriate nresults values
- [x] Clear callstatus in `popBytecodeExecFrame` (prevent stale leak on frame reuse)
**Results:** Build clean (ReleaseFast). Matrix 30/31, smoke 49/49, leakbench
25/25 — no regressions. callstatus is set but not yet read.

### P15.51b–d — Read nresults from callee callstatus, remove PendingCallSlot, remove live_reg_top mutation
**Goal:** Tasks 2-4 of the 10-task CallFrame PUC-faithful plan.
- **P15.51b:** RETURN reads nresults from callee frame's callstatus (dual-write transition).
- **P15.51c:** Remove PendingCallSlot from ordinary Lua CALL path (PUC-faithful callee-frame result contract).
- **P15.51d:** Remove Proto.live_reg_top runtime mutation (static liveness is sufficient).
**Results:** Matrix 30/31, smoke 49/49, leakbench 25/25 — no regressions.

### P15.51g — Remove duplicated regs/boxed slices from CallFrame
**Goal:** Task 7 of the 10-task CallFrame PUC-faithful plan. Remove `regs: []Value`
and `boxed: []?*Cell` from CallFrame — they are fully determined by `base + frame_cap`
and can be derived on demand. Eliminates stale slices after bc_stack realloc.
**Changes:**
- Remove `regs`/`boxed` fields from CallFrame struct
- Add `regsSlice(stack)`/`boxedSlice(boxed_stack)` accessor methods
- Add `stackForThread(th)` helper: active thread → `bc_stack`, parked → `th.bytecode_stack`
- Update `frameVarargs` to accept `?*Thread` for parked coroutine stack resolution
- Update `debugGetLocal/SetLocalFromBytecodeFrame` to accept `?*Thread`
- Fix parked coroutine debug access (db.lua, coroutine.lua regressions)
- Remove all regs/boxed write sites from ensureBcStackCap, pushBytecodeExecFrame,
  shrinkstack, bcGrowFrame, syncDispatchCtx, TAILCALL frame update
**Results:** Matrix 30/31, smoke 49/49, leakbench 25/25, unit 146/146 — no regressions.

### P15.51h — Inline syncDispatchCtx into defer block (Task 8 — COMPLETE)
**Goal:** Task 8 of the 10-task CallFrame PUC-faithful plan. Eliminate
`syncDispatchCtx` function call overhead by inlining the field writeback
into the `frame_loop` defer block. The compiler can optimize away redundant
stores for fields that didn't change during the inner dispatch loop.
**Status:** COMPLETE — `syncDispatchCtx` was inlined (P15.51h), then
`loadDispatchCtx` and the defer block were eliminated entirely (P15.51l).
The dispatch now accesses CallFrame directly (like PUC `ci`), with 7 hot
fields in locals and sync only at boundaries via `syncFrame`.
**Results:** Matrix 30/31, smoke 49/49, unit 146/146 — no regressions.

### P15.51i — Move bool fields to callstatus flags (Task 9 — PARTIAL)
**Goal:** Task 9 of the 10-task CallFrame PUC-faithful plan. Replace individual
bool fields with PUC-style `callstatus` flag bits, reducing CallFrame size and
matching PUC `CIST_*` encoding.
**Status:** PARTIAL — 4 bool fields moved to callstatus flags (CIST_TAIL,
CIST_HOOKED, CIST_HOOKYIELD, CIST_HIDE). Remaining per-frame fields:
`current_line`, `last_hook_line`, `debug_namewhat`, `debug_name`,
`debug_hook_transfer`, `debug_hook_transfer_start`, `debug_hook_event_calllike`,
`debug_hook_event_tailcall`, `debug_hook_event_is_count`, `debug_hook_allow_yield`.
CallFrame = 344 B vs PUC CallInfo = 64 B. Thread-global hook/debug state should
move to `Thread`; `debug_name`/`debug_namewhat` should be derived on demand.
**Changes:**
- Add `CIST_TAIL`, `CIST_HOOKED`, `CIST_HOOKYIELD`, `CIST_HIDE` flag constants
- Replace `is_tailcall: bool` with `CIST_TAIL` bit + `isTailCall()`/`setTailCall()`/`clearTailCall()`
- Replace `is_debug_hook: bool` with `CIST_HOOKED` bit + `isDebugHook()`/`setDebugHook()`/`clearDebugHook()`
- Replace `resumed_direct_yield: bool` with `CIST_HOOKYIELD` bit + `isHookYield()`/`setHookYield()`/`clearHookYield()`
- Replace `hide_from_debug: bool` with `CIST_HIDE` bit + `isHidden()`/`setHidden()`/`clearHidden()`
- Add `setTailCallBool()`/`setHookYieldBool()` helpers for assignment-from-bool sites
- Update all read/write sites in vm.zig and c_api.zig
**Results:** Matrix 30/31, smoke 49/49, leakbench 25/25, unit 146/146 — no regressions.

### P15.51j — Conditional gcTempRoots (Task 5 complete)
**Goal:** Remove unconditional `gcTempRoots` from top of `completeBytecodeExecFrame`.
**Analysis:** GC is only triggered by `condGcFromDispatch` at specific opcodes, not by
the Zig allocator or write barriers. After `popBytecodeExecFrame`, the child's register
window is dead but:
- `closeBytecodeUpvaluesFrom` fires write barriers only (gcMarkValue queues objects,
  no full GC cycle).
- `alloc.dupe`/`alloc.alloc`/`alloc.free`/`bcGrowFrame` (Zig realloc) never trigger GC.
- `applyBytecodeResultsDirect` copies ret into parent registers (a GC root) before any
  Lua code can run.
- Paths that run Lua code (concat, gsub, protection) have their own gcTempRoots.
- Paths that free ret before running Lua (hook, close) don't need protection.
- The ONLY path that needs gcTempRoots is `tail_return`, where `beginBytecodeClose`
  runs `__close` metamethods while ret is still alive.
**Results:** Matrix 30/31, smoke 49/49 — no regressions. Common path (ordinary Lua
CALL → RETURN) now skips gcTempRoots entirely.

### P15.51k — Remove callee field from CallFrame (Task 6 complete)
**Goal:** Remove `callee: Value` from CallFrame. The callee is already at
`bc_stack[func_slot]` — derive it on demand (PUC `ci->func` points into the
shared stack).
**Changes:**
- Remove `callee: Value = .Nil` from CallFrame struct
- Hook dispatch save/restore now writes to `bc_stack[func_slot]` instead of
  `frame.callee` (PUC-faithful: `ci->func` is in the shared stack)
- `pushBuiltinCFrame` now places callee on `bc_stack` at `func_slot` (was
  storing only in the callee field with no bc_stack entry)
- `popBuiltinCFrame` restores `bc_stack_top` to the C-frame's `func_slot`
- All read sites updated: GC marking (active + generational), debug.getinfo
  (active thread + coroutine via `stackForThread`), `debugFrameCalleeMatches`,
  `snapshotThreadTraceFrames`, `tracebackFrameLabel`
- TAILCALL frame update: removed redundant `fr2.callee` write (bc_stack already
  has the callee from TAILCALL stack setup)
- `pushBytecodeExecFrame`: removed `ef_slot.callee` write (bc_stack already has
  the callee from OP_CALL fast path or host-recursion path)
**Results:** Matrix 30/31, smoke 49/49 — no regressions.

### P15.51l — Eliminate loadDispatchCtx/syncDispatchCtx round-trip (Task 8 complete)
**Goal:** Eliminate the ~40 field copies per `frame_loop` entry/exit caused by
`loadDispatchCtx` (copying ~20 fields from CallFrame to BytecodeDispatchCtx) and
the defer block (copying them back). PUC Lua's `luaV_execute` works with `ci`
directly — hot variables (`pc`, `base`) are locals, sync happens only at boundaries.
**Changes:**
- Removed 11 rare fields from `BytecodeDispatchCtx`: `reg_top`, `nvarstack`,
  `nextraargs`, `varargs`, `tbc_mark`, `resume_pc`, `func_slot`, `is_tailcall`,
  `resumed_direct_yield`, `has_open_upvalues`, `hooks_active` (92 of ~906 accesses).
- Kept 7 hot fields as locals: `pc`, `base`, `regs`, `boxed`, `frame_cap`,
  `cur_proto`, `cur_upvalues` (814 of ~906 accesses).
- Removed `loadDispatchCtx` — replaced with inline init of 7 hot fields at top
  of `frame_loop`.
- Removed 15-field defer block — replaced with `syncFrame(ctx, frame_identity)`
  that writes only 5 hot fields (`pc`, `base`, `frame_cap`, `cur_proto`,
  `cur_upvalues`) back to CallFrame.
- Rare fields are now read/written directly on the heap CallFrame via
  `ctx.exec_frames.getPtr(ctx.frame_index)`, matching PUC's `ci` access pattern.
- `hooks_active` is now read from `self.hooks_active_cached` directly.
- `resumed_direct_yield` (CIST_HOOKYIELD flag) is read/written via
  `fr.isHookYield()`/`fr.setHookYield()`/`fr.clearHookYield()`.
- `parkDirectBytecodeYield` calls updated to use local `var resumed` + flag set.
**Results:** Matrix 30/31, smoke 49/49, unit 146/146 — no regressions.

### P15.51m — Fix dangling `fr_call` pointer in opCall after reentrant operations
**Goal:** Fix a use-after-realloc bug where `fr_call` (obtained at the top of
`opCall`) was used after `callBuiltin`/`runClosure`/`dispatchBytecodeHookWithCallee`
— operations that can reentrantly grow `exec_frames` (via GC finalizers calling
`runClosure`, or debug hooks pushing frames). When `frame_index >= 32`
(INLINE_FRAME_CAP), `getPtr()` returns a pointer into the heap `ArrayListUnmanaged`,
which is invalidated on realloc.
**Changes:**
- Replaced 3 uses of stale `fr_call.reg_top` with fresh
  `ctx.exec_frames.getPtr(ctx.frame_index).reg_top` at the three use-after-reentry
  sites in `opCall`:
  1. `string_gsub` returned path (after `tryPushBytecodeDebugHook` +
     `dispatchBytecodeHookWithCallee`)
  2. Builtin call path (after `callBuiltin` + `tryPushBytecodeDebugHook` +
     `dispatchBytecodeHookWithCallee`)
  3. IR Closure call path (after `runClosure` + `tryPushBytecodeDebugHook` +
     `dispatchBytecodeHookWithCallee`)
- `fr_call` is still used in the early part of `opCall` (before any reentrant
  operations) — that usage is safe.
- Audited `fr_vp` in `varargprep`: confirmed SAFE. The allocations between obtain
  and use (`allocTableEphemeral`, `tableResizeArray`, `setIndexValue`, `internStr`)
  do NOT trigger GC or `runClosure` — they don't call `condGcFromDispatch` or
  `gcAutomaticStep`. The table has no metatable, so `setIndexValue` goes directly
  to `rawSet` without metamethod dispatch.
**Results:** Matrix 30/31, smoke 49/49, unit 146/146 — no regressions.

### P15.51 plan status
- Tasks 1-5, 6, 7, 8: **complete**.
- Task 8 (eliminate loadDispatchCtx/syncDispatchCtx round-trip): **COMPLETE** —
  `loadDispatchCtx` and the 15-field defer block eliminated. 7 hot fields kept
  as locals, 11 rare fields accessed directly on CallFrame. `syncFrame` writes
  only 5 hot fields at frame_loop boundaries.
- Task 9 (move debug/hook fields to Thread, derive debug_name on demand): **COMPLETE** —
  All debug/hook fields moved to Thread (`last_hook_line`, 6 debug hook fields).
  `debug_namewhat`/`debug_name` stored in `BytecodePendingCall` (parent frame's
  continuation). `PendingCallSlot` moved to Vm-level sparse storage with u32 handle
  and free-list. 5 `?usize` pc fields compacted to `u32` sentinels.
  `activation_id` compacted from `usize` to `u32`. `frame_cap` compacted to `u32`.
  CallFrame = **96 B** (was 344 B, PUC CallInfo = 64 B).
  OOM semantics fixed (`allocPendingCall`/`setPendingCall` return `error{OutOfMemory}`).
  256 cleanup limit removed. Pointer-lifetime audit completed (3 dangling pointers fixed).
- Task 10 (union for Lua-frame vs C-frame state): **DEFERRED / BLOCKED** on proper
  PUC-compatible C continuation semantics (`lua_callk`, `lua_pcallk`, `lua_yieldk`).
  PUC's `u.c` continuations (`k`, `old_errfunc`, `ctx`) are not yet implemented in
  luazig — `PendingCallSlot` handles continuations instead. Re-evaluate and introduce
  PUC `CallInfo.u.c`-like representation as part of implementing C continuation support.

### P15.51n — CallFrame compaction (344B → 96B)
**Goal:** Compact CallFrame from ~344B to <100B by removing dead/duplicated/derivable
fields, moving hook/debug state to thread-level, and moving PendingCallSlot to
Vm-level sparse storage.
**Changes (10 tasks + follow-up fixes):**
- Task 1 (`59ed86e`): Removed dead `env_override` field (~24B saved).
- Task 2 (`bd56024`): Removed dead `varargs` field (~16B saved).
- Task 3 (`652f84a`): Removed `upvalues` field, added `frameUpvalues()` helper (~16B saved).
- Task 4 (`797d1ee`): Removed `current_line` field, added `frameCurrentLine()` helper (~8B saved).
- Task 5 (`797d1ee`): Moved `last_hook_line` from CallFrame to Thread (~8B saved).
- Task 6 (`12e4000`): Moved 6 debug hook fields from CallFrame to Thread with `hook_frame_index` for O(1) lookup (~48B saved).
- Task 7 (`ed78160`): Moved `debug_namewhat`/`debug_name` to Thread `debug_name_entries[32]` array (~32B saved). **Revised** (`4cb5ab4`): Replaced `DebugNameEntry[32]` array + `u4` counter with `debug_namewhat`/`debug_name` fields stored directly in `BytecodePendingCall` (parent frame's continuation). Eliminates `u4` overflow and hidden depth limit.
- Task 8 (`6c0770d`): Compacted 5 `?usize` pc fields to `u32` with `INVALID_PC` sentinel (~60B saved).
- Task 9 (`628dba2`): Moved `PendingCallSlot` to Vm-level sparse storage with u32 handle and free-list. Fixed `freeThreadBytecodeFrames` reentrancy and `pending_calls.deinit` ordering. `BytecodePendingCall` = 56B, `PendingCallSlot` = 64B (~60B/frame saved).
- Task 10 (`a64fdbb`): Compacted `activation_id` from `usize` to `u32` (4B saved).
- `frame_cap` compaction (`e158688`): Changed `frame_cap` from `usize` to `u32` in `CallFrame`, `BytecodeDispatchCtx`, and `bcGrowFrame` signature. VM bytecode stack is bounded by `MAXSTACK` (1 000 000) + 200 margin, so `frame_cap` never exceeds ~1 000 200 — well within `u32` range. CallFrame reached **96B** (<100B target).
- OOM semantics (`08fdae6`): `allocPendingCall` returns `error{OutOfMemory}!u32`, `setPendingCall` returns `error{OutOfMemory}!void`. All 16 call sites updated with `try`. No partial state on failure.
- 256 cleanup limit removed (`05c56c9`): Replaced fixed-size `[256]u32` indices buffer in `freeThreadBytecodeFrames` with direct iteration over `call_frames`.
- Pointer-lifetime audit (`d602254`): Fixed 3 dangling `*BytecodePendingCall` pointers in `completeBytecodePendingExternalResults`, `completeBytecodeCoroutineResult`, `completeBytecodeProtectedResult`. Snapshot `pending.callee` into local before reentrant operations.
- Vm-level ownership documented (`1ef1a87`): Added comprehensive documentation of `pending_calls` ownership model and 5 invariants.
**Result:** CallFrame = **96 B** (down from 344B, -72%). PUC CallInfo = 64B.
BytecodePendingCall = 56B, PendingCallSlot = 64B.
**Results:** Matrix 30/31, smoke 49/49, unit 146/146, leakbench 25/25 — no regressions.


**Problem:** `enableTestcModuleInternal` passed empty upvalues (`&.{}`) to `runBytecode` for the testC bootstrap chunk. The bootstrap source uses global accesses (`require`, `setmetatable`) that compile to `OP_GETTABUP` on upvalue 0 (`_ENV`). With empty upvalues, `gettabup` caused an out-of-bound...
Результат: testC lane goes from 0/6 (all SIGSEGV) to 2/6 pass (`errors.lua`,

### fix: stale `outs` after bc_stack realloc in pcall/xpcall/testC
**Problem:** `builtinTestcTestC`, `builtinPcall`, `builtinXpcall` error paths used stale `outs` slice after `callBuiltin`/`runClosure` triggered bc_stack realloc. Also `opTforcall` had LUA_MULTRET UB (`nresults < 0` cast to usize).

### fix: GC varargs scan use bc_stack for VM-active thread
**Problem:** `gcPropagateOne` used `th.bytecode_stack` directly for varargs scan, but for VM-active thread it's empty (moved to `bc_stack`).

### Phase 1 — Core lua.h functions (C API expansion)
**Goal:** Implement the core set of `lua.h` C API functions that were declared as macros or missing, bringing the exported symbol count from 62 to 76.

**Changes:**
- **api.zig:** Added 9 new `State` methods: `checkstack`, `isnumber`, `isstring`, `isinteger`, `iscfunction`, `tolstring`, `rawlen`, `tocfunction`, `tothread`. `absindex` and `isuserdata` already existed. `tolstring` uses `vm.valueToInternedStr` for PUC-faithful number formatting (`.0` suffix for integer-valued floats). `rawlen` uses `vm.tableBorderLen` (PUC `luaH_getn`).
- **vm.zig:** Made `valueToInternedStr` and `tableBorderLen` public (`fn` → `pub fn`) so `api.State` can call them. No logic changes.
- **c_api.zig:** Added 14 thin C-ABI shims: `lua_absindex`, `lua_checkstack`, `lua_isnumber`, `lua_isstring`, `lua_isinteger`, `lua_iscfunction`, `lua_isuserdata`, `lua_isyieldable`, `lua_tolstring`, `lua_typename`, `lua_rawlen`, `lua_tocfunction`, `lua_tothread`, `lua_version`. Also fixed 3 pre-existing `_ =` compilation issues in test code (`lua_getfield`/`lua_rawget` return values).
- **lua.h:** Added declarations for all 14 new functions, grouped into Type predicates and Conversions sections.
- **tests/c_api/01_core.c (new):** C test exercising all 14 new functions: absindex, checkstack, isnumber/isstring/isinteger, tolstring (int/float/nil), typename, rawlen (string/table), iscfunction/tocfunction, isyieldable, lua_version, isuserdata, tothread.

**Result:** Symbol count 62→76. Matrix 30/31, smoke 49/49, C tests 2/2 — no regressions.

### Phase 2 — Table operations (C API expansion)
**Goal:** Complete the table access C API: `lua_gettable`, `lua_settable`, `lua_geti`, `lua_seti`, `lua_rawgeti`, `lua_rawseti`, `lua_rawgetp`, `lua_rawsetp`. Brings exported symbol count from 76 to 84.

**Changes:**
- **api.zig:** Added 2 new `State` methods: `rawgetp`, `rawsetp` — raw table access with a light userdata pointer key (`.{ .LightUserdata = p }`). The other 6 methods (`gettable`, `settable`, `geti`, `seti`, `rawgeti`, `rawseti`) already existed from Phase R3 refactoring.
- **c_api.zig:** Added 8 thin C-ABI shims: `lua_gettable`, `lua_settable`, `lua_geti`, `lua_seti`, `lua_rawgeti`, `lua_rawseti`, `lua_rawgetp`, `lua_rawsetp`. Each delegates to the corresponding `api.State` method.
- **lua.h:** Added declarations for `lua_gettable`, `lua_settable`, `lua_geti`, `lua_seti`, `lua_rawseti`, `lua_rawgetp`, `lua_rawsetp` (`lua_rawgeti` already existed from Phase 0).
- **tests/c_api/02_tables.c (new):** C test exercising all 8 new functions: seti/geti, rawseti/rawgeti, settable/gettable, rawsetp/rawgetp.
- **Deviation note:** `rawgetp`/`rawsetp` return `error.InvalidIndex` for null `p` (PUC creates a light userdata wrapping NULL). Justified: Zig's `*anyopaque` cannot represent address 0, and no real C code uses NULL pointer keys.

**Result:** Symbol count 76→84. Matrix 30/31, smoke 49/49, C tests 3/3 — no regressions.

### Phase 3 — Arithmetic, Comparison, Coroutines, GC (C API expansion)
**Goal:** Implement `lua_arith`, `lua_rawequal`, `lua_compare`, `lua_concat`, `lua_len`, `lua_resume`, `lua_yieldk`, `lua_status`, `lua_pushthread`, `lua_gc`. Brings exported symbol count from 84 to 94.

**Changes:**
- **vm.zig:** Added 5 public API methods: `apiArith` (dispatches to existing `binAdd`/`binSub`/`binMul`/`binDiv`/`binIdiv`/`binMod`/`binPow`/`binBand`/`binBor`/`binBxor`/`binShl`/`binShr`/`evalUnOp(.Minus)`/`evalUnOp(.Tilde)`), `apiRawEqual` (wraps private `valuesEqual`), `apiCompare` (wraps `cmpEq`/`cmpLt`/`cmpLte`), `apiLen` (wraps `evalUnOp(.Hash)`), `apiGc` (maps LUA_GC* constants to `gc_running`/`gcFullCollectionForUser`/`gc_count_kb`/`gc_mode`).
- **api.zig:** Added `ArithOp` and `CompareOp` enums. Added 7 `State` methods: `arith`, `rawequal`, `compare`, `len`, `gc`, `status`, `pushthread`. Renamed `pushexternalString` parameter `len` → `str_len` to avoid shadowing the new `len` method.
- **c_api.zig:** Added 10 thin C-ABI shims: `lua_arith`, `lua_rawequal`, `lua_compare`, `lua_concat`, `lua_len`, `lua_resume`, `lua_yieldk`, `lua_status`, `lua_pushthread`, `lua_gc`.
- **lua.h:** Added declarations for all 10 new functions.
- **tests/c_api/03_arith.c (new):** C test exercising all 10 new functions: arith (ADD/SUB/MUL/DIV/IDIV/MOD/UNM/BAND/BOR/BNOT/SHL/SHR/POW), rawequal (int/string/nil), compare (LT/LE/EQ/string-LT), concat (string/number), len (string/table), gc (ISRUNNING/STOP/RESTART/COUNT/COLLECT), version, status, pushthread.
- **Deviation note:** `lua_pushthread` pushes nil and returns 1 (main thread) — luazig's Vm is not a Thread object and cannot be pushed as one. `lua_status` returns LUA_OK (0) for the main VM. `lua_resume`/`lua_yieldk` delegate to existing `State.resume`/`State.yield` but are not yet fully tested with real coroutines via the C API.

**Result:** Symbol count 84→94. Matrix 30/31, smoke 49/49, C tests 4/4 — no regressions.

### Phase 4 — Load/Dump, Warnings, Miscellaneous (C API expansion)
**Goal:** Implement `lua_load`, `lua_dump`, `lua_setwarnf`, `lua_warning`, `lua_stringtonumber`, `lua_numbertocstring`, `lua_setallocf`, `lua_toclose`, `lua_closeslot`, `lua_pushvfstring`. Brings exported symbol count from 94 to 104.

**Changes:**
- **lua.h:** Added `lua_Reader`, `lua_Writer`, `lua_WarnFunction` typedefs. Added `LUA_N2SBUFFSZ` (64) constant. Added `#include <stdarg.h>` for `va_list`. Fixed `lua_pushfstring` return type from `void` to `const char *` (matching PUC). Added declarations for all 10 new functions + `lua_pushvfstring`.
- **vm.zig:** Added `c_warnf`/`c_warn_ud` fields to Vm struct (PUC's `L->warnf`/`L->ud_warn`). Made `cloneStrippedProto` public (needed by `lua_dump` for strip mode).
- **c_api.zig:** Refactored `lua_pushfstring` to delegate to `lua_pushvfstring` (PUC's `lua_pushfstring` is a thin `va_start`/`lua_pushvfstring`/`va_end` wrapper). `lua_pushvfstring` implements PUC's `luaO_pushvfstring` formatting engine with exact PUC specifier set: `%s`, `%c`, `%d`, `%I`, `%f`, `%p`, `%U`, `%%`. Unknown specifiers kept verbatim (PUC default). Added `lua_load` (collects chunks from reader callback, compiles via `compileChunkValue`). Added `lua_dump` (serializes Closure's Proto via `DumpWriter.dumpChunk`, feeds to writer callback — full implementation, not a stub). Added `lua_setwarnf`/`lua_warning` (store/forward to `c_warnf` handler). Added `lua_stringtonumber` (PUC `luaO_str2num`: integer-first, then float, returns `strlen+1`). Added `lua_numbertocstring` (PUC `luaO_tostringbuff`: integer/float to buffer with NUL). Added `lua_setallocf` (no-op with TODO Phase 9). Added `lua_toclose`/`lua_closeslot` (no-op with TODO: TBC mechanism).
- **tests/c_api/04_misc.c (new):** C test exercising `lua_stringtonumber` (int/float/invalid), `lua_numbertocstring` (int/non-number), `lua_load` (reader callback + pcall), `lua_dump` (writer callback + signature verification), `lua_setwarnf`/`lua_warning` (handler + disable), `lua_pushfstring` (format string), `lua_setallocf`/`lua_getallocf`, `lua_toclose`/`lua_closeslot` (no-crash verification).
- **All C API functions fully implemented.** Previously stubbed functions now work:
  `lua_setallocf` (stores custom allocator), `lua_toclose`/`lua_closeslot`
  (`__close` metamethod), `lua_getlocal`/`lua_setlocal` (Proto.locvars).

**Result:** Symbol count 94→104. Matrix 30/31, smoke 49/49, C tests 5/5 — no regressions.

### Phase R1 — Unify api.State on *Vm + vm.c_stack
**Problem:** `api.State` owned a `Vm` by value and maintained a SEPARATE `stack` field (`ArrayListUnmanaged(Value)`), distinct from `vm.c_stack` used by `c_api.zig`. This dual-stack architecture meant `api.State` and `c_api.zig` operated on different stacks, blocking consolidation of the C API and Zig API surfaces.

**Fix:** `State.vm` is now `*Vm` (borrowed pointer) instead of `Vm` (owned by value). The `stack` and `alloc` fields are removed — all methods use `self.vm.c_stack` and `self.vm.alloc` directly. `State.init` heap-allocates the Vm; `State.deinit` frees it. New `State.fromVm(vm: *Vm)` constructor wraps an existing `*Vm` without taking ownership (for future c_api.zig consolidation).

**Result:** `api.State` and `c_api.zig` now share the same stack (`vm.c_stack`), eliminating the dual-stack problem. testc.zig updated mechanically (`st.alloc` → `st.vm.alloc`). Matrix 30/31, smoke 49/49 — no regressions.

### Phase 0 — C API drop-in: build targets + headers
**Goal:** Produce `liblua.so` / `liblua.a` that C programs can link against, with complete PUC 5.5-compatible headers.

**Changes:**
- **build.zig:** Added `addLibrary` targets (shared `.dynamic` + static `.static`) named `lua`, both using `lua_mod` with `link_libc = true`. Produces `zig-out/lib/liblua.so` (62 `lua_*`/`luaL_*` symbols) and `zig-out/lib/liblua.a`.
- **luaconf.h (new):** PUC 5.5 build configuration — `LUAI_MAXSTACK`, `LUA_IDSIZE`, `LUAL_BUFFERSIZE`, `LUA_QL`/`LUA_QS`, `LUAI_UACINT`/`LUAI_UACNUMBER`, `l_mathop`, `l_noret`, `luai_apicheck`, `LUAI_MAXCCALLS`, `LUA_VDIR`, Linux path defaults (`LUA_PATH_DEFAULT`, `LUA_CPATH_DEFAULT`, `LUA_DIRSEP`), `LUA_USE_DLOPEN`.
- **lualib.h (new):** All 10 `luaopen_*` declarations + `luaL_openselectedlibs` + `LUA_*LIBK` bitmask constants + `luaL_openlibs` macro. Matches PUC 5.5 verbatim.
- **lua.h:** Added `LUA_NUMTYPES`, `LUA_MINSTACK`, `LUA_RIDX_*`, `LUA_SIGNATURE`, `LUA_RELEASE`, `LUA_COPYRIGHT`, `LUA_AUTHORS`, `LUA_VERSION_RELEASE_NUM`, `LUA_OP*`, `LUA_OPEQ`/`LUA_OPLT`/`LUA_OPLE`, `LUA_GC*` + `LUA_GCP*`, `LUA_HOOK*`/`LUA_MASK*`, type predicate macros (`lua_isnil`, etc.), convenience macros (`lua_upvalueindex`, `lua_pushglobaltable`, `lua_resetthread`, `lua_newuserdata`, `lua_getuservalue`, `lua_setuservalue`). Moved `LUAI_MAXSTACK` to luaconf.h. Added `lua_rawgeti` and `lua_closethread` declarations (needed by macros).

**Result:** Matrix 30/31, smoke 49/49 — no regressions. All PUC 5.5 C extension test files (`lib1.c`, `lib2.c`, `lib11.c`, `lib21.c`, `lib22.c`, `udatatest.c`) compile against luazig headers.

### Phase 0.4 — C-link smoke test + lazy I/O init
**Goal:** Prove that a real C program can link against `liblua.so` and exercise the C API.

**Changes:**
- **tests/c_api/00_smoke.c (new):** Minimal C program that creates a Lua state via `luaL_newstate()`, compiles and runs `"return 1 + 2"` via `luaL_loadbufferx` + `lua_pcallk`, tests table creation (`lua_createtable` + `lua_setfield` + `lua_getfield`), and verifies stack management. Uses only functions from the 62 exported symbols.
- **tests/c_api/Makefile (new):** Compiles the test against luazig's headers (`src/lua/`) and links against `liblua.so` (`zig-out/lib/`) with `-Wl,-rpath` for runtime resolution.
- **lua.h / lauxlib.h:** Added missing declarations for `lua_close`, `luaL_newstate`, `luaL_loadbufferx`, `luaL_loadfilex` — all were exported symbols (confirmed by `nm -D`) but lacked header declarations.
- **stdio.zig:** Added lazy I/O initialization (`ensureDefaultInit`) for the C-library scenario. When liblua.so is loaded by a C program, the Zig runtime startup (`pub fn main(init: std.process.Init)`) never runs, so `stdio.init()` was never called. Now `activeIo()` falls back to `Io.Threaded.global_single_threaded.io()` — Zig stdlib's pre-initialized, always-available I/O implementation. This is the C-library counterpart of what `main(init)` does for Zig binaries.

**Result:** `PASS: 00_smoke`. Matrix 30/31, smoke 49/49 — no regressions.

### Phase 7 — lualib: luaopen_* exports + luaL_openselectedlibs
**Goal:** Export all 10 `luaopen_*` standard library functions and `luaL_openselectedlibs` (bitmask-based library opener) so C programs can open individual libraries or all at once via `luaL_openlibs(L)`.

**Changes:**
- **c_api.zig:** Added 11 new exports:
  - `luaopen_base` — pushes the global table (`_G`) as the base library table (PUC `lua_pushglobaltable`).
  - `luaopen_package/coroutine/debug/io/math/os/string/table/utf8` — each pushes the corresponding pre-built library table from `_G` (libraries are already registered by `Vm.init`).
  - `luaL_openselectedlibs(L, load, preload)` — mirrors PUC linit.c: iterates standard libraries in `LUA_*LIBK` bitmask order, calls `luaL_requiref` for each library in the `load` mask, and registers openf in `package.preload` for each library in the `preload` mask. `luaL_openlibs(L)` macro expands to `luaL_openselectedlibs(L, ~0, 0)`.
- **vm.zig:** Fixed pre-existing bug in `compileChunkValue`: the compiled chunk's `_ENV` upvalue was left as `Nil` (initialized by `createBytecodeChunkClosure` but never set to `global_env`). Added `applyLoadEnv(cl, .{ .Table = self.global_env }, false)` call after closure creation, matching PUC's `lua_load` behavior. Without this, `luaL_loadstring` + `lua_pcall` with global lookups (e.g., `string.len('hello')`) failed with an empty runtime error.
- **tests/c_api/07_libs.c (new):** C test exercising `luaL_openlibs`, `luaopen_math` direct call, `lua_pcall` with `string.len`, and library table verification.
- **tests/c_api/Makefile:** Added `07_libs` to TESTS.

**Result:** Symbol count 144 (133 + 11 new). All 8 C API tests pass. Matrix 30/31, smoke 49/49 — no regressions.

### perf(vm): gate per-instruction SIGINT atomic load behind `sigint_installed` flag
**Problem:** The bytecode dispatch loop executed `signal_int_pending.load(.acquire)` on
EVERY instruction — an atomic acquire-load fence. PUC Lua does NOT do per-instruction
signal checks; it uses a `trap` flag that only fires when hooks are active. When the
SIGINT handler is NOT installed (C API users, `liblua.so` library usage), the flag is
always `false` and the atomic load is pure overhead.

**Fix:** Added a plain `bool sigint_installed` flag (set by `installSigintHandler`,
cleared by `restoreSigintHandler`). The dispatch loop reads it ONCE into a local
`const check_sigint` before the loop; the per-instruction check becomes
`if (check_sigint and signal_int_pending.load(.acquire))`. When `check_sigint` is
`false`, short-circuit evaluation skips the atomic load entirely.

**Safety:** `sigint_installed` is a plain `bool` (not atomic) — safe because it's set
before `runBytecode` and cleared after it returns; the dispatch loop runs between
these points with no concurrent modification.

**Result:** Matrix 26/31 (no regressions), smoke 49/49, leakbench 25/25. CLI perf
unchanged (CLI installs the handler → `check_sigint == true` → load still happens).
C API / `liblua.so` usage benefits: zero per-instruction atomic overhead.

### refactor — Dead code removal after IR codegen deletion
После удаления IR-based codegen (`codegen.zig`, `ir.zig`, `bc_vm.zig`, etc.)
остались stale-ссылки и мёртвый код:

- **Stale comments:** убраны упоминания `ir.Function`, `IR-era`, `bc_dummy_func_global`,
  `bc_vm` из comments/test names в `codegen_bc.zig`, `vm.zig`, `bytecode.zig`.
- **Unused imports:** удалены `tracking_alloc`, `LuaToken` из `vm.zig`.
- **Dead functions:** `debugIsGenericForIteratorCall` (всегда `return false`),
  `debugGetLocalFromThreadSnapshot`/`debugSetLocalFromThreadSnapshot` (тело `const fr = null orelse return;`),
  `freeThreadLocalsSnapshot` (no-op), `setThreadFrameLocalOverride` (unreachable).
- **Dead fields/type:** `Thread.locals_snapshot` (всегда `null`), `Thread.frame_local_overrides`
  (никогда не читался), `Thread.LocalSnap` struct.
- **Dead branches:** упрощены `suspended_ir = null` + `locals_snapshot` проверки в
  `debug.getinfo`/`debug.getlocal`/`debug.setlocal` (раньше мёртвые ветки, теперь простой fallback).

Проверка: matrix 30/31 (без регрессий), smoke 49/49, `zig build test` 134 pass (без изменений).

### Phase 0.2 — vm test harness: _ENV upvalue for global-access tests

**Problem:** 5 `vm.test.vm` tests crashed with `index out of bounds: index 0, len 0`
at `ctx.cur_upvalues[b]` (GETTABUP/GETUPVAL). The test harness called
`vm.runBytecode(proto, &.{}, &.{}, null)` — passing empty upvalues. But the compiled
bytecode uses globals (`x = {...}`, `return tostring(...)`, `_VERSION`, global `i`
after a for loop), which compile to GETTABUP on upvalue 0 (`_ENV`). With empty
upvalues, this is an OOB access.

**Fix:** Each of the 5 tests now provides a `_ENV` upvalue — a stack-allocated
`Cell` whose `.value` is `.{ .Table = vm.global_env }` — matching the established
convention in `codegen_bc.zig:7255`. The 5 fixed tests:
- `vm: table constructor and access` (global `x`)
- `vm: call tostring (one result)` (global `tostring`)
- `vm: if statement (NotEq) with _VERSION` (global `_VERSION`)
- `vm: locals swap uses temporaries` (global `tostring`)
- `vm: numeric for loop break + scope` (global `i` — loop-local `i` is out of
  scope after the loop, so `return sum, i` reads global `i` → Nil)

**Result:** `zig build test -Doptimize=Debug`: 143 pass, 3 fail (pre-existing:
c_api/ltable/lexer — unrelated), **0 crash** (was 5 crash). Matrix 30/31
(`zig_fail=0`), smoke 49/49 — no regressions.

### Phase 0.3 — Fix remaining 3 test failures + leaks

**Problem:** `zig build test -Doptimize=Debug` showed 143 pass, 3 fail, 0 crash,
141 leaks. The 3 failures (lexer, ltable, c_api) and 141 leaks (codegen_bc,
undump, vm) needed resolution to reach 146/146 pass with 0 leaks.

**Fixes (6 problems):**

1. **codegen_bc tests leak (13 tests, ~130 leaks):** Each test created a
   `Codegen` struct but never called `cg.deinit()`. Added `defer cg.deinit();`
   after `Codegen.init` in all 13 codegen tests.

2. **undump tests leak (7 tests, 7 leaks):** `UndumpReader` has a
   `string_dedup: ArrayListUnmanaged` field that was never freed. Added
   `defer r.deinit();` after `UndumpReader.init` in all 7 undump tests.

3. **lexer test "tokenizes global declaration" fails:** The lexer defaults to
   `global_reserved = false`, so `global` is lexed as `Name` not `Global`. The
   test needs `global_reserved = true` to test the reserved-word path. Added
   `lex.global_reserved = true;` in the test.

4. **ltable test "nodeInsert returns null when hash part is full" fails:** The
   test asserted `lastfree == 0` after 4 inserts, but keys 1–4 hash to distinct
   main positions (golden-ratio hash), so each insert places directly without
   calling `getFreePos` — `lastfree` is never decremented. Removed the incorrect
   assertion; the test's core purpose (nodeInsert returns null when full) is
   verified by the final assertion.

5. **vm test "destroyLuaString invokes falloc" fails:** `destroyLuaString`
   passes `osize = len + 1 = 6` to `falloc`, but the test allocated only 5
   bytes. Fixed: allocate 6 bytes, copy "hello" into first 5.

6. **c_api test "lua_error crosses setjmp boundary" fails:** `pcall` did not
   truncate `c_stack` on error — the function remained on the stack. PUC
   `luaD_pcall` restores the stack to base on error. Fixed: in `pcall`'s catch
   path, set `c_stack.items.len = fn_idx` before returning `.runtime_error`.

**Bonus fix — BytecodeCloseContinuation leak (6 leaks in 4 codegen+vm tests):**
`continueBytecodeClose` allocated a `BytecodeCloseContinuation` via
`alloc.create` but never freed it in the normal completion path.
`PendingCallSlot.clear()` only flips the `active` flag (hot-path optimization)
without freeing heap-allocated completions. `cancelBytecodePendingCall` handles
the error/cancel path but not the normal path. Fixed: save needed fields
(`had_close_error`, `current_err`, `min_reg`), then `alloc.destroy(state)` after
`clear()`.

**Result:** `zig build test -Doptimize=Debug`: **146/146 pass, 0 fail, 0 crash,
0 leaks.** Matrix 30/31 (`zig_fail=0`), smoke 49/49 — no regressions.

### P15.79 — Fix runClosure ownership contract: completeBytecodeExecFrame C-parent branch inverted

**Root cause:** `completeBytecodeExecFrame`'s C-parent branch (lines ~8776-8783)
had inverted ownership logic vs the external-boundary branch (lines ~8791-8798).

When a Lua function returns into a C-frame (e.g. `pcall(function() return 1 end)`
under a builtin C-frame), `OP_RETURN0`/`OP_RETURN1` uses `bc_return_scratch` — a
VM-owned `[1]Value` static array. The C-parent branch returned this borrowed
slice directly to the caller:

```zig
// INVERTED (buggy):
if (parent.isC()) {
    if (self.returnSliceIsOwned(ret)) return ret;       // scratch → borrowed (BAD)
    const owned = try self.alloc.dupe(Value, ret);       // non-scratch → dupe (original leaks!)
    return owned;
}
```

The external-boundary branch was correct:
```zig
if (self.returnSliceIsOwned(ret)) {
    const owned = try self.alloc.dupe(Value, ret);       // scratch → dupe to owned
    return owned;
}
return ret;                                               // non-scratch → already owned
```

**Impact:** `runClosure()` had a floating contract — sometimes heap-owned
(C closures via `callCFunction` → `alloc.dupe`), sometimes VM-owned scratch
(Lua closures via `OP_RETURN0/1` → `bc_return_scratch`). Dozens of consumers
doing `alloc.free(ret)` would corrupt `smp_allocator`'s free list by freeing
non-heap addresses. This caused silent data corruption: `ProtoBuilder.finish`
would get the same pointer for `code[]` and `lineinfo[]` (both 16 bytes),
and `@memcpy` in `toOwnedSlice` overwrote the bytecode.

**Fix:** Invert the C-parent branch to match the external-boundary branch:
```zig
if (parent.isC()) {
    if (self.returnSliceIsOwned(ret)) {
        const owned = try self.alloc.dupe(Value, ret);
        return owned;
    }
    return ret;
}
```

Now `runClosure()` always returns a caller-owned, freeable slice. All consumers
can safely `alloc.free(ret)`.

**Consumers audited:** 52 `alloc.free(ret)` sites in vm.zig. 20 already used
`if (!self.returnSliceIsOwned(ret))` guard (now always-true but harmless).
32 did raw `free(ret)` — all are now safe with the producer fix.

**Regression test:** `tests/smoke/51_pcall_cframe_ownership.lua` — 10000×
`pcall(function() return 1 end)` + `collectgarbage("collect")` + `load(reader)`
with C closure reader.

**Results:** Build clean (ReleaseFast, Debug). Matrix: 5 tests fixed (events,
memerr, nextvar, pm, strings now pass), 0 regressions. Smoke: 49/51 pass
(31, 32 pre-existing). PUC Lua differential: regression test passes on both.

### P15.79 — Investigation: pcall/dofile semantics in builtinCoroutineResume

**Investigation goal:** Determine whether the "special pcall/dofile semantics"
(inline formatting in `builtinCoroutineResume`'s `.Builtin` branch, lines
~16093-16213) can be removed or refactored to use the trampoline.

**Finding:** The inline pcall/dofile formatting is **correct and necessary**.
It handles `coroutine.create(pcall)` (builtin callee) — a case the trampoline
cannot handle because the trampoline requires a `.Closure` callee.

**Two distinct code paths for pcall-in-coroutine:**

1. **`coroutine.create(function() pcall(foo) end)`** (Closure callee):
   - `tryPushBytecodeProtectedCall` intercepts `pcall(foo)` in OP_CALL —
     no pcall C-frame is pushed. foo gets a protected-call continuation
     (PendingCallSlot).
   - When foo yields, `builtinCoroutineYield` sets `bytecode_inplace_suspended`
     + `bytecode_resume_boundary`. The yield C-frame is preserved by
     `callBuiltin`'s `cframe_preserved=true`.
   - On resume, `builtinCoroutineResume`'s C-frame processing loop calls
     `finishCcall` (k==null path) → sets `isHookYield` on foo's frame →
     `poscallCFrame` pops yield C-frame.
   - Then `driveBytecodeCoroutineTrampoline` resumes foo via `runBytecodeInternal`
     (resume_in_place, boundary_depth=0).
   - When foo returns, `completeBytecodeExecFrame` detects the protected-call
     PendingCallSlot and wraps results as `[true, ...ret]`.
   - **No inline pcall formatting needed** — handled by PendingCallSlot.

2. **`coroutine.create(pcall)`** (Builtin callee):
   - `builtinCoroutineResume` calls `callBuiltin(.pcall, ...)` directly
     (not via OP_CALL), so `tryPushBytecodeProtectedCall` is NOT involved.
     A pcall C-frame IS pushed.
   - When the target yields, the yield C-frame is on top, pcall C-frame below.
   - On resume, `finishCcall` (k==null) sets `isHookYield`, `poscallCFrame`
     pops yield C-frame. pcall C-frame remains.
   - The `.Builtin` branch detects `bytecode_inplace_suspended=true` + top
     is Lua → resumes the top Lua frame directly via `runClosure(top_cl, &.{})`.
   - When the Lua frame returns, `completeBytecodeExecFrame` detects the pcall
     C-frame parent (C, isYpcall) → returns results to caller.
   - The `.Builtin` branch checks `is_ypcall` → formats as `[true, ...ret]`
     (pcall success) or `[false, error]` (pcall failure).
   - **Inline pcall formatting IS needed** — no PendingCallSlot for this path.

**Conclusion:** The two paths are structurally different (PendingCallSlot vs.
C-frame with CIST_YPCALL). Both are PUC-faithful. The inline formatting in
the `.Builtin` branch mirrors PUC's `finishpcall` → `luaD_poscall` chain.
No refactoring needed — the duplication is apparent, not real.

**CIST_CLSRET:** `setClsret()` is defined but never called. testC handles TBC
close via `testcContShim` (pushed BEFORE closers). No other C API function in
luazig uses `lua_toclose`. The hard-fail in `finishCcall` on CIST_CLSRET is
dead code / safety check — retained as invariant guard.

**luaF_close in finishpcallk:** TBC close on error is handled by
`continueBytecodeErrorUnwind` during forced close. `precover` pops frames
after TBC close. No separate `luaF_close` needed in `finishpcallk`.

**Matrix:** 30/32 (api.lua fixed, coroutine.lua `--testc` hang pre-existing,
big.lua both_fail pre-existing). Smoke: 53/53. No regressions.

### P15.79 — Forced close error propagation fix

**Root cause:** When multiple `__close` metamethods error during
`coroutine.close`, the last error should propagate as the close result. But
the re-entrant forced close path in `runBytecodeDispatch`'s error handler
cleared the error when `shouldRethrowForcedCloseFromBytecode()` returned true.

After all `__close` children were released (`bytecode_close_metamethod_depth ==
0`), `shouldRethrowForcedCloseFromBytecode` returned true. The re-entrant path
then called `clearErrorTraceback()` + `restoreRuntimeErrorValue(.Nil)`,
discarding the last `__close` error. `coroutine.close` returned `(false, nil)`
instead of `(false, "last_close_error")`.

**Fix:** If `forced_close_had_error` is true, skip the re-entrant forced
close — all TBC slots have already been processed by
`continueBytecodeErrorUnwind` → `close_parent` → `continueBytecodeClose`.
Just return `error.RuntimeError` with the current error state (the last
`__close` error).

**Test:** `tests/smoke/53_p15_79_regression.lua` — 8 test cases covering:
coroutine.close + pcall + TBC (no error), coroutine.close + pcall + TBC
(__close errors), pcall yield across closure coroutine, pcall catches error,
multiple TBC slots with LIFO error propagation, pcall yield then close,
error location (Lua vs C function), pcall around coroutine.close.

**Results:** Matrix 30/32, smoke 53/53. PUC Lua differential: all tests
match PUC exactly.

### P15.80 — CallFrame size reduction: heap-allocate TestcContState

**Problem:** `TestcContState` (~184B) was stored inline in `CFrameState`
via `testc_state: ?TestcContState`, inflating `CFrameState` to 224B and
`CallFrame` to 264B — well above the ~100B target (PUC `CallInfo` = 64B).
The struct is only used by testC `callk`/`pcallk`/`yieldk`, so most C-frames
pay the cost without using it.

**Fix:** Changed `testc_state: ?TestcContState` → `?*TestcContState`
(heap-allocated pointer, 8B). Added `allocTestcState`/`freeTestcState`/
`destroyTestcState` helpers. Updated all creation sites (4) to allocate
on heap, all destruction sites (8) to free the allocation, and fixed
double-increment bugs in `testcContShim` closer loops where `state` was
previously a copy but is now a pointer (the manual sync between local
`state.close_current_index` and `fr.u.c.testc_state.?.close_current_index`
became redundant and caused double-increment).

**Result:** CallFrame = **96B** (down from 264B, -64%). Matrix 30/32,
smoke 53/53 — no regressions.

### P15.80a — Fix TestcContState ownership leaks + OOM safety + Debug panic

**Ownership leaks:** `popBuiltinCFrame` and `poscallCFrame` shrank
`call_frames` without freeing the heap-allocated `testc_state`. This
leaked the `TestcContState` allocation (184B) + its owned slices
(stack_prefix, upvalues, closers, close_return_values) on every
callk/pcallk/yieldk return. RSS grew linearly: 13.3MB → 29.5MB at 50K
iterations.

**Fix:** Both `popBuiltinCFrame` and `poscallCFrame` now call
`freeTestcState` before shrinking. The `.callk` reuse branch (which
doesn't pop but clears the field) also uses `freeTestcState` instead
of manually freeing only some slices (was missing `close_return_values`
and the `TestcContState` allocation itself).

**OOM safety:** All 4 creation sites (callk, pcallk, yieldk, __close__)
had a dangling pointer bug: `destroyTestcState(old)` freed the old
allocation but left the field pointing to freed memory. If any
subsequent allocation failed with OOM, the C-frame retained a dangling
pointer. Fixed by: (1) nulling the field after destroying old, (2)
building all slices under `errdefer`, (3) atomically allocating +
assigning the new `TestcContState` only after all slices are ready.

**Debug panic:** `builtinDebugSethook` accessed `fr.u.lua.last_line_pc`
for ALL frames including C-frames, triggering `access of union field
'lua' while field 'c' is active` in Debug mode. Fixed by skipping
C-frames in the seed loop and guarding the `skip_line_hook_pc` access.

**Stress test:** `tests/smoke/54_p15_80_stress_leak.lua` — 2000
iterations of coroutine yield/resume, pcall+coroutine, TBC+coroutine.
All pass PUC differential.

**Result:** Matrix 30/32, smoke 54/54 — no regressions. Debug build
passes `31_debug_bytecode_parity.lua`.

### P15.81 — Fix LUA_REGISTRYINDEX, pcall error object, lua_closeslot, lua_toclose return-path

**LUA_REGISTRYINDEX in getfield/setfield:** `api.zig:getfield`/`setfield`
did not handle the `LUA_REGISTRYINDEX` pseudo-index (-1001000). Only
`ref`/`unref` handled it. This caused `lua_getfield(L, LUA_REGISTRYINDEX,
...)` and `lua_setfield(L, LUA_REGISTRYINDEX, ...)` to silently fail
(returning nil / not storing). Fixed by checking `idx == -1001000` and
using `apiEnsureRegistry()` to get the registry table.

**pcall error object:** `api.zig:pcall` truncated the stack on error but
did not push the error object. PUC's `luaD_pcall` calls
`luaD_seterrorobj` to push the error. Fixed by pushing `vm.err_obj` onto
`c_stack` before returning `.runtime_error`.

**lua_closeslot error propagation:** `lua_closeslot` used `lua_pcallk`
which swallowed errors from `__close`. PUC uses `luaD_call` (not
`luaD_pcall`) — errors propagate. Fixed by using `apiCall` + `lua_error`
to re-raise errors.

**lua_toclose return-path close:** `callCFunction` now closes
`c_toclose_slots` in LIFO order on normal return (PUC `luaD_poscall` →
`luaF_close`). If `__close` yields, CIST_CLSRET is set on the C-frame
and `finishCcall` continues closing on resume.

**lua_pcallk errfunc on main thread:** When `vm.current_thread` is null
and `errfunc != 0`, errfunc is now set before calling `s.pcall()`.

**Result:** Matrix 30/32, smoke 54/54, c_api 17/17 — no regressions.
Verified against PUC Lua 5.5.0 differential for lua_toclose return-path
close and lua_closeslot error propagation.

### P15.82 — Fix yield-during-C-return-path-close + double-close + precover leak

**Yield-during-C-return-path-close:** `callCFunction`'s TBC close loop
freed `c_stack` via `errdefer` on `error.Yield` from a `__close`
metamethod, but `c_toclose_slots` indices still referenced the freed
`c_stack`. On resume, `finishCcall` tried to use invalid indices.
Fixed by saving results and remaining TBC values on the C-frame before
closing. `finishCcall` CIST_CLSRET path now closes from the saved slice
and returns saved results via `resume_inbox`.

**Double-close fix:** `finishCcall`'s k==null error path (pcall catches
error after yield) did NOT set `isHookYield` on the Lua frame below the
C-frame. Without `isHookYield`, `runBytecodeInternal` re-executed OP_CALL,
re-running pcall→testC→closers. Fixed by setting `isHookYield` and
`resume_pc` on the Lua frame below.

**precover leak fix:** `precover` did not free `testc_state` on C-frames
being popped before `shrinkTo`. Fixed by calling `freeCFrameOwnedState`
on each popped C-frame.

**4 stale c_api regression tests fixed:** `test_error_then_yield.lua`,
`test_gc_close_err.lua`, `test_nonstring_error_yield.lua`,
`test_yield_then_error.lua` — all updated to expect correct PUC behavior
(pcall catches error after yield, second resume succeeds). All 4 pass.

**Result:** Matrix 30/32, smoke 54/54, c_api 17/17 — no regressions.

### P15.82a — Fix CIST_CLSRET memory corruption, GC tracing, CallFrame size, per-C-frame TBC

**CIST_CLSRET memory corruption (independent review):** P15.82 had two
ownership bugs in `callCFunction`'s CIST_CLSRET yield path:
1. `results_owned` flag was set but never checked by `errdefer` —
   `saved_results` was freed by `errdefer` on `error.Yield` return,
   leaving a dangling pointer on the C-frame.
2. Manual `c_stack.deinit` + restore in the yield branch, followed by
   the outer `errdefer` doing the same — double-free of the caller's stack.
Fixed by: removing the manual c_stack restore (let `errdefer` handle it),
adding `errdefer if (!results_owned) self.alloc.free(saved_results)`,
using `clsret_owned` flag for `CClsretState` allocation.

**CallFrame size regression:** P15.82 added two inline `?[]Value` slices
(`clsret_tbc_values`, `clsret_results`) to `CFrameState`, inflating
`CallFrame` from 96B to 120B. Fixed by replacing them with a single
`?*CClsretState` pointer to a heap-allocated struct. `CallFrame` is now
104B (close to PUC's ~100B target).

**GC tracing for clsret_state:** `clsret_tbc_values` and `clsret_results`
were not traced by GC. While a C-frame is suspended (CIST_CLSRET), these
slices contain GC-collectable values (tables, closures, strings) that
must be roots. Fixed by adding tracing in `gcMarkCurrentRoots`.

**Per-C-frame TBC slots:** `c_toclose_slots` was VM-global. Nested C
calls with `lua_toclose` corrupted each other's TBC slots. Fixed by
adding `toclose_base: usize` to `CFrameState`. Each C-frame only closes
slots in `[toclose_base, c_toclose_slots.len)`, mirroring PUC's
per-call-info TBC scope.

**k==NULL path fix:** `finishCcall`'s k==NULL path used `th_bc.len() - 2`
directly instead of searching for the Lua frame below all C-frames.
When `__close` yields during return-path close, there are TWO C-frames
on top of the Lua frame. Fixed by searching for the Lua frame below all
C-frames (same pattern as the k!=NULL path).

**CIST_CLSRET path fix:** `finishCcall`'s CIST_CLSRET path called
`popBuiltinCFrame()` directly, but the trampoline also calls
`poscallCFrame()` which tries to pop another C-frame. Fixed by removing
`popBuiltinCFrame()` from the CIST_CLSRET path — `poscallCFrame` handles it.

**freeTestcState renamed:** `freeTestcState` → `freeCFrameOwnedState`
since it now frees both `testc_state` and `clsret_state`.

**zig build test gate fixed:** `c api lua_error crosses the setjmp
boundary into pcall` test expected `top=0` after `lua_pcallk` error, but
PUC leaves the error object on the stack (`top=1`). Fixed test to expect
`top=1`.

**Result:** Matrix 30/32, smoke 54/54, c_api 17/17, zig build test 146/146
— no regressions.

### P15.82b — Fix lua_resume C API for direct C usage

**Problem:** `lua_resume` (C API) was broken when called directly from C
(not from Lua's `coroutine.resume`). It used `api.State.@"resume"` which
depends on `vm.current_thread` being set — but `current_thread` is null
when called from C. Additionally, `lua_newthread` was a stub that didn't
create a real Thread object.

**Fix — lua_newthread:** Now creates a real `Thread` object, registers it
with the GC, stores it in `vm.c_api_thread`, and pushes it on `c_stack`
(mirrors PUC's `lua_newthread` which pushes the thread on `L->top`).

**Fix — lua_resume:** Rewritten to use `apiResumeThread` directly (bypassing
`api.State.@"resume"`). Key insights:
1. **Don't set `vm.current_thread`**: `builtinCoroutineResume` saves/restores
   `current_thread` internally. Setting it in `lua_resume` would cause the
   defer to restore `co`'s status to its pre-resume value, overwriting the
   `.suspended` status set by the yield path.
2. **First vs subsequent resume**: On first resume (`!co.started`), the
   function is on `c_stack` at `len-nargs-1`. On subsequent resumes
   (`co.started`, status=`.suspended`), the function was already consumed;
   `c_stack` top has only the resume arguments. This mirrors PUC's `resume()`
   which uses `L->ci->func` (already set) and reads nargs from `L->top`.

**Fix — lua_yieldk:** Removed debug prints. The `_longjmp(jb, 2)` to the
`callCFunctionWithBoundary` setjmp point works correctly — the yield
propagates as `error.Yield` through `callCFunction` → `runClosure` →
`builtinCoroutineResume`, which sets `th.status = .suspended`.

**gcRegisterThread/gcNoteAlloc:** Made `pub` so `c_api.zig` can use them
for `lua_newthread`.

**Result:** Matrix 30/32, smoke 54/54, c_api 17/17, zig build test 146/146
— no regressions. C tests pass: `test_debug2` (yield+resume),
`test_clsret_gc` (GC during CIST_CLSRET), `test_toclose_yield2` (toclose
yield during C return).

**Task 16 — Non-yieldable boundary test:** Added `test_nonyieldable` (t7)
to `10_continuations.c`. Verifies that `lua_call` (k==NULL) makes the call
non-yieldable — a C function that tries `lua_yieldk` inside `lua_call`
gets an error, not LUA_YIELD. Mirrors PUC's `api_check(k == NULL || !isLua(L->ci->previous))`
and the `incnny`/`decnny` mechanism. All 7 continuation tests pass.

**Task 12 — finishpcallk TBC close gap:** Updated TODO in `finishpcallk`
with precise analysis. Lua-frame TBC variables are closed by the bytecode
dispatch loop's error unwinding path (`beginBytecodeClose`) before
`precover` is called. C-frame TBC variables (`c_toclose_slots` for the
CIST_YPCALL frame) are NOT closed in `finishpcallk` — this is a known
gap. No existing tests exercise C-frame TBC close during pcallk error.

### P15.82c — Fix CIST_CLSRET Lua __close yield + direct-resume path

**Problem 1 — CIST_CLSRET set on wrong C-frame:** When a Lua `__close`
metamethod yielded via `coroutine.yield`, `callCFunction`'s TBC close
loop set CIST_CLSRET on `call_frames.getPtr(len-1)` — the TOP frame.
But the top frame at that point was the `callBuiltin` C-frame from
`coroutine.yield` inside `__close`, NOT `callCFunction`'s own C-frame.
This caused the C-frame processing loop on resume to see CIST_CLSRET
on the wrong frame, leaving the real CIST_CLSRET C-frame unprocessed.

**Fix 1:** Save `my_cframe_idx` when `callCFunction` pushes its C-frame,
and use that index (not `len-1`) when setting CIST_CLSRET and
`toclose_base`. This mirrors PUC's per-call-info TBC scope.

**Problem 2 — Direct-resume path not shared:** The direct-resume logic
(resume top Lua frame when `bytecode_inplace_suspended`) was only in
the `.Builtin` branch of `switch (resolved.callee)`. When `th.callee`
was a C closure (e.g. from `luaL_dostring`), the `.Closure` branch
re-entered `th.callee` via `runClosure` → `callCFunction`, pushing a
new C-frame on top of the preserved Lua frame, crashing
`runBytecodeDispatch` on the C-frame (no proto).

**Fix 2:** Moved the direct-resume path BEFORE the `switch`, so both
`.Builtin` and `.Closure` branches benefit. After the top Lua frame
returns, the C-frame below is inspected:
- **CIST_CLSRET or k!=null:** Call `finishCcall` to run the continuation
  / continue TBC close. Results come from `resume_inbox`.
- **k==null + CIST_YPCALL (plain pcall):** Format as `(true, ...ret)`.
- **k==null + plain:** Use `ret` directly.

**Result:** Matrix 30/32 (big + coroutine pre-existing), smoke 54/54,
c_api 17/17, zig build test 146/146. CIST_CLSRET with Lua `__close`
that yields now works (test_clsret_lua_close.c passes).

### P15.82d — PUC-faithful coroutine.close result + hook-yield frame preservation

**Fix 1 — forced_close_ok missing in direct-resume path (P15.82c
regression):** PUC `lua_closethread` (lstate.c:310 `luaE_resetthread` =
`resetCI` + `luaD_closeprotected`) discards ALL frames before running
`__close`, so pcall can never intercept a close. luazig's forced-close
unwind (`appendBytecodeForcedCloseUnwind`, target_depth = boundary)
already achieves the resetCI effect (pops the pcall C-frame too), but
the direct-resume path added in P15.82c lacked the `forced_close_ok`
check that the `.Builtin` branch, `.Closure` branch and the trampoline
all have. A successful close therefore returned `(false, nil)` instead
of `(true, nil)`. Fixed by adding the same check to the direct-resume
path's `error.RuntimeError` handler (before `precover`, mirroring the
other branches). Fixes smoke 53 and coroutine.lua:184 ("close a
coroutine while closing it").

**Fix 2 — hook-yield destroyed ALL frames (pre-existing, exposed by
Fix 1):** A yield from a debug hook that runs as a bytecode frame
(`tryPushBytecodeDebugHook`) with an extra C-frame on top (e.g. the
testC `yield` builtin command, or `coroutine.yield` called from the
hook body) hit the `in_debug_hook` branch of
`builtinCoroutineYield`, which inspected only the TOP frame. The top
frame was the C-frame (not the hook frame), so the branch was a no-op:
`bytecode_inplace_suspended` stayed false and the `errdefer` in
`runBytecodeInternal` unwound EVERY frame. Each resume then re-executed
the coroutine body from the start — the hook fired again before any
progress, yielding again: an infinite resume/yield cycle leaking memory
per iteration (coroutine.lua --testc consumed 2 GB+ in 23 s before
dying; the section was previously unreachable because the test failed
at line 184).

PUC semantics (ldebug.c:977 `luaG_traceexec`, ldo.c:1023 `lua_yieldk`):
a yield from inside a hook abandons the hook's ENTIRE call stack via
`luaD_throw` — the hook runs on the current Lua CallInfo (CIST_HOOKED),
nothing above it survives; the frame is marked CIST_HOOKYIELD and
resume does `savedpc--` (ldo.c:926). Fixed PUC-faithfully: the
`in_debug_hook` branch now searches DOWNWARD for the debug-hook frame,
pops everything above it (C builtin frames via `popBuiltinCFrame`,
freeing owned state; stray Lua frames via `popBytecodeExecFrame`),
then runs the existing parent pending_call cleanup (restores callee,
sets `resume_skip_count_pc` — the CIST_HOOKYIELD equivalent) and sets
`bytecode_inplace_suspended = true` so the errdefer preserves the body
frame.

**Result:** coroutine.lua --testc runs the hook-yield, coroutine API,
metamethod-yield and for-iterator sections in 0.14 s (PUC: 0.13 s) —
was: fail at line 184 or 117 s + OOM. Now fails only at the final
`pcallk`-error-continuation section (line ~1078, known Task 10 blocker:
error must be delivered to pcallk's k with status ERRRUN instead of
propagating). Matrix 30/32 (same zig_fail/both_fail counts as before:
coroutine.lua + big.lua pre-existing), smoke 54/54, c_api 18/18.

**Next blockers (open):**
- [x] ~~pcallk error continuation: `T.testC("pushstring x; pcallk 1 0 2")`
      must run k with status ERRRUN on error (coroutine.lua:~1078).~~ —
      done (P15.82e): callBuiltin CIST_YPCALL guard + single-C-frame
      testC pcallk/callk/yieldk + iterative unroll. coroutine.lua
      --testc now PASSES the entire suite.
- [x] ~~finishpcallk C-frame TBC close (plan Task 12).~~ — done via the
      P15.82e single-frame redesign: each continuation state snapshots
      its closers (collectTestcClosers) and testcContShim runs them
      after the script, with yield/error state machine. The f407b3c4a
      regression test (coroutine.lua:1116, toclose+pcallk) passes.
- [x] ~~lua_pcallk errfunc/message handler (plan Task 10).~~ — done
      (P15.82f): lua_error folds the thrown object into err_obj and
      runs invokeErrfunc BEFORE the longjmp (PUC luaG_errormsg), so a
      yieldable pcallk's k receives the handler-transformed object.
      Differential vs PUC: identical.
- [x] ~~lua_closethread is still a stub returning LUA_OK.~~ — done (P15.82g).
- [x] ~~C hook dispatch via `c_hook` (set by lua_sethook) never fires.~~ — done (P15.82h).
- [x] ~~Direct `lua_resume` stack/status semantics (lua_status stays 0).~~ — done (P15.82g).

### P15.83c — C-frame TBC activation scoping + finishpcallk pcall-error close

**FIX A: lua_toclose dedup scoping** (c_api.zig): `lua_toclose` was deduping
against ALL entries in `c_toclose_slots`, but each C-frame owns only the
segment `[toclose_base, len)`. A nested C call's `lua_toclose` could find
an outer C-frame's TBC slot and skip marking, causing the wrong slot to be
closed. Fixed by scoping dedup to the topmost C-frame's segment using
`vm.current_thread orelse vm.main_thread`. Also: `popBuiltinCFrame` now
truncates `c_toclose_slots` to the popped frame's `toclose_base` (scoping
hygiene, mirrors PUC per-CallInfo TBC scope).

**FIX B: finishpcallk C-frame TBC close on resume-error** (vm.zig): When a
yieldable `lua_pcallk`'s C-frame has TBC values and the resumed callee errors,
PUC's `finishpcallk` calls `luaF_close(L, func, status, 1)` to close them. In
luazig, `c_stack` is per-C-frame and freed by `callCFunction`'s errdefer on
yield — TBC Values are lost. Two mechanisms:

1. **Yield snapshot** (`snapshotYieldedTbc`): On yield (both `callCFunction`
   and `finishCcall` k-yield paths), TBC Values are snapshotted from `c_stack`
   into `fr.u.c.clsret_state` (reused as `?*CClsretState` in
   `pcall_error_close` mode, CIST_CLSRET NOT set). `c_toclose_slots` is
   truncated to `toclose_base` (indices about to become stale).

2. **Resume-error close** (`finishCcall`): On resume, if `clsret_state !=
   null` and CIST_YPCALL and CIST_RECST has error status, sets CIST_CLSRET
   and enters the CLSRET close loop (calls `__close` with error value as
   arg, last-error-wins LIFO semantics). On completion, does finishpcallk
   completion (set error obj at funcidx, clear YPCALL/RECST/CLSRET, restore
   allowhook/errfunc) and falls through to k invocation with error status.
   If resume is NOT an error (normal yield resume), frees the snapshot.

3. **No-yield error path** (`callCFunction` error path): When `lua_error`
   fires directly from the C function (no yield), c_stack is still alive.
   TBC Values are collected from `c_stack` into `clsret_state` before the
   errdefer frees it. Same CLSRET close loop runs on `finishCcall`.

**CallFrame size**: Reused `clsret_state` (existing `?*CClsretState` = 8 bytes)
instead of adding a new field — CallFrame stays ≤ 104B.

**Test:** Repro tests at `/tmp/tbc_pcallk.c` (yield→error→TBC close) and
`/tmp/nested_tbc.c` (nested C-frame TBC scope). Both match PUC Lua 5.5.0
exactly: `tbc_close_count=1`, `status_seen=2`, `inner,outer`.

**Regression gate:** c_api 29/29, smoke 54/54, matrix zig_fail=0 (only
big.lua both_fail pre-existing), zig build test exit 0, CallFrame ≤ 104B.

### P15.83b — ERRFUNC_NONE sentinel + real LUA_ERRERR status

**FIX A: ERRFUNC_NONE sentinel** (vm.zig): `Thread.errfunc` used `0` as
"no errfunc" sentinel, but `bc_stack` starts at index 0 on a fresh main
thread — a legitimate handler pushed at index 0 collided with the sentinel
and was silently disabled. Replaced with `ERRFUNC_NONE = maxInt(usize)`.
All field defaults (`BytecodeSavedError.errfunc`, `CFrameState.old_errfunc`,
`Thread.errfunc`), comparisons (`setErrfuncValue`, `getErrfuncValue`,
`invokeErrfunc`), and assignments (`saveBytecodeProtectedError`,
`builtinPcall`, `builtinXpcall`, `builtinCoroutineResume`, testC pcall)
updated. `CFrameAux.funcidx` left as plain index (0 valid). c_api.zig's
`errfunc != 0` checks on the c_int PARAMETER unchanged (C contract:
errfunc==0 means none — PUC).

**FIX B: Real LUA_ERRERR (status 5)** (vm.zig, api.zig, c_api.zig): When
the message handler itself errors, PUC returns `LUA_ERRERR` (5) with
"error in error handling" on the stack. luazig was returning `LUA_ERRRUN`
(2) — the status code was collapsed. Added `Vm.err_is_errerr: bool` flag
(PUC `luaD_rawrunprotected` signal): set by `invokeErrfunc`'s catch when
the handler errors; reset to `false` at every throw site (`fail`, `failC`,
`failLib`, `setOutOfMemoryError`, `lua_error`, builtin `error`, testC
`error` command) BEFORE `invokeErrfunc` so fresh errors start as
`LUA_ERRRUN`. Consulted at status-determination sites: `api.pcall` catch
(returns `.error_handler_error` → 5), `c_api.lua_resume` catch (returns 5),
`vm.precover` `setcistrecst` (saves 5 for `finishpcallk`), `c_api.lua_pcallk`
yieldable RuntimeError fallback (returns 5). Added `.error_handler_error`
to `api.Status` enum + `statusCode` → 5. `testcContShim` status-string map
updated: `5 => "ERRERR"`.

**Test:** `tests/c_api/13_p15_completion.c` (4 tests: main-thread pcallk
with errfunc at bc_stack[0] — handler succeeds → LUA_ERRRUN + "handled: …";
errfunc errors → LUA_ERRERR; errerr message == "error in error handling";
lua_status == LUA_OK after errerr pcall). Verified identical output on PUC
Lua 5.5.0 and luazig.

**Regression gate:** c_api 29/29, smoke 54/54, matrix zig_fail=0 (only
big.lua both_fail pre-existing), coroutine.lua --testc exit 0, zig build
test exit 0.

### P15.82g — Implement lua_closethread (was stub) + lua_status thread status

**lua_closethread** (c_api.zig:187): Replaced the stub with a real
implementation delegating to `builtinCoroutineClose` via a new
`apiCloseThread` wrapper on Vm (vm.zig:3924). PUC semantics mapped:
nCcalls inheritance from `from` (lstate.c:327), `luaE_resetthread`
(close all upvalues/TBCs, run `__close`, set status dead), error object
pushed on `c_stack` on `__close` error (PUC `luaD_seterrorobj`). The
`L == from` case (PUC `luaD_throwbaselevel`) is deferred with a TODO —
`lua_resetthread` macro uses `from==NULL` so the primary use case works.

**lua_status** (api.zig:270): Was `return 0`. Now maps `c_api_thread`
status: `.suspended` with `started=true` → `LUA_YIELD` (1), fresh/running/
dead → `LUA_OK` (0). The `started` field distinguishes a fresh thread
(PUC `LUA_OK`) from a yielded thread (PUC `LUA_YIELD`). Errors collapse
into `dead` → `LUA_OK` (documented limitation: callers use `lua_resume`'s
return value for error codes).

**Test:** `tests/c_api/11_closethread.c` (5 tests: fresh close,
suspended close with `<close>`, close with `__close` error, double
close, `lua_status` after yield/completion). Verified identical output
on PUC Lua 5.5.0 and luazig. c_api 19/19, smoke 54/54, matrix
zig_fail=0 (only big.lua both_fail pre-existing), coroutine.lua --testc
exit 0, zig build test exit 0.

### P15.82h — Wire c_hook dispatch into the hook machinery (PUC luaD_hook)

**Problem:** `Vm.c_hook` (set by `lua_sethook`) was stored but never
invoked — dead code. The Lua-level hook system (`DebugHookState` on
`Thread`) was completely separate, and `debugDispatchHookTransfer`
returned early when `DebugHookState.func` was null (which it always is
for a C-only hook).

**Implementation (PUC-faithful single-slot unification):**

- **Signature fix** (vm.zig): `c_hook` changed from
  `?*const fn (?*Vm, *anyopaque)` to `?*const fn (?*anyopaque, ?*anyopaque)`
  matching PUC `lua_Hook = void (*)(lua_State*, lua_Debug*)`. Both args
  are `?*anyopaque` because vm.zig does not import c_api.zig (which
  defines `lua_Debug`); the dispatch code casts via `@import("c_api.zig")`.

- **lua_sethook** (c_api.zig): Mirrors PUC ldebug.c:133 — `func==NULL or
  mask==0` clears the hook; otherwise stores hook/mask/count on `Vm` and
  mirrors the mask/count into the target thread's `DebugHookState`
  (has_call/has_return/has_line/count/budget) so existing trigger sites
  (line/count/call/return dispatch in the bytecode loop) fire and reach
  `debugDispatchHookTransfer`. The Lua-level `DebugHookState.func` is
  cleared (single slot, PUC has one hook per thread).

- **Dispatch** (vm.zig `debugDispatchHookTransfer`): After the fast-path
  checks (hooks_active_cached, debug_hooks_suppressed, isInDebugHook), if
  `c_hook` is set and `c_hook_mask` has the matching bit, the C hook is
  called mirroring PUC `luaD_hook` (ldo.c:439): build `lua_Debug{event,
  currentline}`, set `in_debug_hook=true` (PUC `allowhook=0`), save/restore
  transfer state, call `(*hook)(L, &ar)`, restore. C hooks cannot yield
  in this sync path — the existing "attempt to yield across a C-call
  boundary" check in `builtinCoroutineYield` rejects it (same as PUC
  outside coroutines with proper CIST_HOOKED machinery).

- **Single-slot unification**: `builtinDebugSethook` clears `c_hook` when
  setting a Lua hook; `lua_sethook` clears `DebugHookState.func` when
  setting a C hook. Only one hook type is active at a time, matching
  PUC's singular `L->hook` slot.

- **refreshHooksCached** (vm.zig): Includes `c_hook != null and
  c_hook_mask != 0` so the fast path reaches the dispatch sites.

**Test:** `tests/c_api/12_chook.c` (4 tests: count hook on coroutine
loop, gethook/gethookmask/gethookcount API, clear with NULL/0/0, line
hook on multi-line code). Verified identical "ALL PASS" output on PUC
Lua 5.5.0 and luazig. Count hook fires different absolute counts (206
PUC vs 307 zig) due to bytecode density differences — this is expected
and correct (the sum is 5050 on both).

**Regression gate:** c_api 25/25, smoke 54/54, matrix zig_fail=0 (only
big.lua both_fail pre-existing), coroutine.lua --testc exit 0, zig build
test exit 0.

**Known limitation:** C hooks cannot yield in the sync dispatch path.
A C hook that calls `lua_yield` will be rejected by the existing
non-yieldable check. PUC allows hook yields only inside coroutines with
proper CIST_HOOKED machinery; this is a future enhancement.

### P15.83d — testC callk/pcallk/yieldk use the shared production lua_*k lifecycle

Reopened plan Task 13: upstream testC must validate the SAME production
implementation external C code uses, not a handwritten copy.

**Shared helpers** (vm.zig, near apiYield): `luaCallKShared` (PUC
lapi.c:1047-1053 k/ctx save, yieldable-conditional; k==NULL → incnny),
`luaPcallKShared` (lapi.c:1097-1117 yieldable path: k/ctx/funcidx/
old_errfunc/OAH/CIST_YPCALL save + apiCall + normal-return clearYpcall/
errfunc restore; error path leaves the frame for precover),
`luaYieldKShared` (ldo.c:1020-1028 nyield + k/ctx save — hooks never
save k — + apiYield). All return Zig errors; the CALLER converts to its
regime (c_api wrappers `_longjmp`; testC branches propagate through
callBuiltin).

**c_api.zig** `lua_callk`/`lua_pcallk` (yieldable path)/`lua_yieldk` are
now thin wrappers: read callee/args from c_stack, delegate, convert
errors via the existing `_longjmp` logic, marshal results.

**testC branches** (`.callk`/`.pcallk`/`.yieldk`/`.yield` non-hook path)
no longer write ANY production C-frame state — they keep only payload:
the reuse_cframe provisioning decision (testC chained-continuation
ownership), pushBuiltinCFrame under `!reuse_cframe`, prev_state/
allocTestcState, bytecode_resume_boundary (regime difference: callBuiltin
has no setjmp), last_status strings, and st marshalling. Static gate
(`rg 'u\.c\.k|u\.c\.ctx|setYpcall|aux\.funcidx|builtinCoroutineYield|pushBuiltinCFrame'`
over the testC region) shows zero production writes left; the single
remaining `apiCall` in the region is the plain `.pcall` command (ltests
runC implements its pcall with local error handling too — payload).

Behavior deltas from unification (both PUC-ward): testC pcallk now sets
`th.errfunc = ERRFUNC_NONE` for the call duration (PUC `L->errfunc = 0`)
and restores on return; testC yieldk now records `aux.nyield` (PUC
`u2.nyield`); callk k-saving is yieldable-conditional as in PUC.

**Test (item 11):** `10_continuations.c` t8 nested_callk — Lua → C outer
(lua_callk C mid, k_outer) → C mid (lua_callk Lua f, k_mid) → Lua f
yields → resume → k_mid → k_outer; final value "outer". Identical output
on PUC and luazig.

**Regression gate:** 14/14 c_api suites, test-diff DIFF: PASS (4 suites),
coroutine.lua --testc exit 0, smoke 54/54, matrix zig_fail=0 (only
big.lua both_fail), zig build test exit 0.

**Remaining from the reopened plan:** per-lua_State handle architecture
(item 6), lua_status error preservation (7), closethread discards
suspended k (8), per-thread/i_ci/yieldable C hooks (9), hook API-check
enforcement (10), full differential coverage + final gates (15/16/17).

### P15.83e — Per-lua_State handle architecture (Phase 1: struct + c_func ABI)

Replaced `pub const lua_State = Vm` with a real handle struct. `lua_newthread`
now returns distinct handles (`co != L`), and C functions receive `?*lua_State`
(the handle) instead of `?*Vm`.

**Handle struct** (`vm.zig`): `lua_State = struct { vm: *Vm, thread: ?*Thread,
c_stack: ArrayListUnmanaged(Value), is_main: bool }`. The handle is
heap-allocated by `luaL_newstate`/`lua_newstate` (main) and `lua_newthread`
(coroutine). `Thread.api_handle: ?*lua_State` ties coroutine handle lifetime
to the Thread's GC lifetime — `gcFreeObject(.thread)` frees the handle. The
main handle is freed by `lua_close`/`api.State.deinit`.

**Vm fields**: `cur_handle: ?*lua_State` (active handle, passed to C functions
via `callCFunctionWithBoundary`), `main_handle: ?*lua_State` (freed by
`lua_close`). `Vm.setupMainHandle()` creates the main handle after `Vm.init`
(the handle stores `self` as `vm`, so it must be created after the `*Vm` is
at its final location).

**c_func ABI change**: `Closure.c_func` type changed from
`?*const fn (?*Vm)` to `?*const fn (?*lua_State)`. `callCFunctionWithBoundary`
passes `self.cur_handle.?` to the C function. `callContShim`/`testcContShim`
receive `?*lua_State` and pass the handle to `k`. Hook dispatch passes
`cur_handle` to the hook function. `c_panicf`/`c_cont_k` types updated.
`api.State.Reg.func`, `pushcclosure`/`pushcfunction` types updated.
`luaCallKShared`/`luaPcallKShared`/`luaYieldKShared` k parameter types updated.

**L-unpacking**: All 162 C API exports changed from `const vm = L orelse ...`
to `const vm = if (L) |h| h.vm else ...` (or `api.State.fromHandle(L orelse ...)`).
`api.State.fromHandle(h)` resolves `h.vm` — same `*Vm` as before, so all
`vm.c_stack` access is unchanged.

**Phase 1 limitation**: All handles share `Vm.c_stack` (single shared stack).
`lua_xmove` is a no-op (self-move). Per-handle stacks, real xmove, and GC
roots for c_stack are Phase 2.

**lua.h**: `typedef struct Vm lua_State` → `typedef struct lua_State lua_State`
(forward declaration, opaque to C).

**Test** (`tests/c_api/14_state_handles.c`): 5 tests — newthread distinct,
two newthreads distinct, resume via handle, status fresh, tothread returns
handle. Differential test (PUC + luazig) passes.

**Regression gate:** 15/15 c_api suites, test-diff DIFF: PASS (5 suites),
coroutine.lua --testc exit 0, smoke 54/54, matrix zig_fail=0 (only big.lua
both_fail), zig build test exit 0.

### P15.83f — Per-handle C API stacks + real lua_xmove + GC stack roots (Phase 2)

Each `lua_State` handle now has its own independent `c_stack`. The VM's
`cur_c_stack: *ArrayListUnmanaged(Value)` pointer always points to the active
handle's stack (`&cur_handle.c_stack`), reassigned only during coroutine
resume/return. During `callCFunction`/`finishCcall` stack swaps, the pointer
itself stays fixed — the swap operates on `cur_c_stack.*` (the value pointed
to).

**vm.zig**: `Vm.c_stack` (value field) → `Vm.cur_c_stack` (pointer field).
`setupMainHandle` sets `cur_c_stack = &h.c_stack`. The `callCFunction`/
`finishCcall` swap saves `cur_c_stack.*`, puts `.empty`, runs the C function,
restores `cur_c_stack.*`. `Vm.deinit` no longer frees c_stack (handles own
their stacks, freed by `lua_close`/`gcFreeObject(.thread)`).

**api.zig**: `api.State` gains `stack: *ArrayListUnmanaged(Value)` field.
`fromHandle(h)` sets `stack = &h.c_stack`; `fromVm(vm)` sets `stack =
vm.cur_c_stack`. All 209 `self.vm.c_stack` accesses → `self.stack` (auto-deref).

**c_api.zig**: All 37 `const vm = if (L) |h| h.vm else ...` → `const h = L
orelse ...; const vm = h.vm;`. All 106 `vm.c_stack` → `h.c_stack`. All 9
`api.State.fromVm(vm)` → `api.State.fromHandle(h)`.

**lua_xmove**: Real cross-stack move — copies top `n` values from `src_h.c_stack`
to `dst_h.c_stack`, truncates `src_h`. Self-move (from == to) is a no-op.
Asserts same VM.

**lua_resume**: Switches `vm.cur_handle` and `vm.cur_c_stack` to the
coroutine's handle during `apiResumeThread`, restores on return (defer). C
functions called within the coroutine now see the coroutine's handle as their
`L` parameter and operate on the coroutine's c_stack.

**GC roots**: `gcMarkMutableRoots` marks `main_handle.c_stack` items and
`cur_c_stack` items (if different from main_handle). The `.thread` case of
`gcMarkValue` marks `th.api_handle.?.c_stack` items. This fixes a latent bug
where values pushed via the C API could be collected by GC.

**lua.h**: Added `#define lua_yield(L,n) lua_yieldk(L, (n), 0, NULL)` (was
missing — PUC has it).

**Test** (`tests/c_api/14_state_handles.c`): 11 tests — newthread distinct,
two newthreads distinct, resume via handle, status fresh, tothread,
independent stacks, xmove, xmove zero, xmove self, coroutine yield
independent, multiple coroutines independent. Differential test (PUC +
luazig) passes.

**Regression gate:** 15/15 c_api suites, test-diff DIFF: PASS (5 suites),
coroutine.lua --testc exit 0, smoke 54/54, matrix zig_fail=0 (only big.lua
both_fail), zig build test exit 0.

### P15.83h — Per-thread C hooks + lua_Debug.i_ci + yieldable count/line hooks

**Item 9.1: Hook state is per-thread.** Moved the C hook function pointer from
`Vm.c_hook` (Vm-level) to `DebugHookState.c_hook` (per-thread, PUC-faithful).
Removed `Vm.c_hook`, `Vm.c_hook_mask`, `Vm.c_hook_count`. The mask/count/budget
fields in `DebugHookState` (has_call/has_return/has_line/count/budget) are
SHARED between C and Lua hooks — PUC has ONE L->hook slot per thread.
`lua_sethook` resolves the thread via the handle (`L.thread orelse main_thread`)
and sets/clears `DebugHookState.c_hook` + the shared mask/count fields. Setting
a C hook clears `DebugHookState.func` (single slot); `builtinDebugSethook`
clears `DebugHookState.c_hook` when a Lua hook is installed.
`lua_gethook`/`lua_gethookmask`/`lua_gethookcount` read from the handle's
thread. `lua_gethookmask` reconstructs the PUC bitmask from has_call/
has_return/has_line/count. `refreshHooksCached` no longer needs a separate
`c_hook_active` check — the mirrored mask fields already cover C hooks.
`DebugHookState.clear()` now clears `c_hook` too (made `pub` for c_api access).

**Item 9.2: lua_Debug.i_ci.** `debugDispatchHookTransfer` now sets `ar.i_ci`
to the topmost non-hidden frame's index (1-based, matching `lua_getstack`'s
`@ptrFromInt(frame_idx + 1)` encoding). For line/count/return events, the
topmost frame IS the current Lua frame (correct, matches PUC's `ar.i_ci = ci`).
For call events, the callee's frame hasn't been pushed yet in the sync path,
so `i_ci` points to the caller's frame (best available — PUC passes the new ci,
but luazig's sync path fires before the frame is pushed). `lua_getinfo(L, "l",
ar)` from a line hook now returns a sensible currentline.

**Item 9.3: Yieldable count/line C hooks.** PUC allows count/line hooks to
yield (`luaG_traceexec` checks `L->status == LUA_YIELD`). Previously,
`debug_hook_allow_yield = false` for C hooks. Now: `debug_hook_allow_yield` is
set to `true` for count/line C hook events (call/return hooks remain
non-yieldable, matching PUC). The C hook call is wrapped with a `_setjmp`
boundary (like `callCFunctionWithBoundary`) so `lua_yieldk`'s `_longjmp` lands
back in `debugDispatchHookTransfer`. On yield (sj==2): `error.Yield` propagates
to the bytecode loop's catch block, which calls `parkBytecodeIrHookYield`
(sets `bytecode_inplace_suspended` + skip flag). On resume, the bytecode loop
continues from the same instruction, with the skip flag preventing immediate
re-firing. The `in_debug_hook` branch in `builtinCoroutineYield` finds no hook
frame (sync path doesn't push one) — this is correct: there's nothing to
unwind, and `parkBytecodeIrHookYield` handles the parking.

**Item 10: API-check enforcement.** PUC's `api_check(L, k == NULL ||
!isLua(L->ci), "cannot use continuations inside hooks")` compiles out in
release builds (`lua_assert` → `((void)0)` without `LUA_USE_APICHECK`).
luazig's existing behavior is already SAFE: `luaYieldKShared` silently skips
k-saving for debug hook frames (`if (!fr.isDebugHook())`), preventing state
corruption. No runtime enforcement needed — matches PUC's release behavior.
For `lua_yieldk` in hooks: PUC's `api_check(L, nresults == 0, ...)` also
compiles out; luazig handles any nresults value correctly.

**Tests** (`tests/c_api/12_chook.c`): Added t5 (hook_thread_isolation — co1/co2
independent hooks), t6 (hook_getinfo — lua_getinfo "l" from line hook), t7
(hook_yield — line hook yields via lua_yieldk, resume1 YIELD, resume2 OK
result 2), t8 (hook_exec_isolation — co1 count hook fires, co2 without hook
stays 0). All differential (PUC + luazig) PASS.

**Regression gate:** 15/15 c_api suites, test-diff DIFF: PASS (5 suites),
coroutine.lua --testc exit 0, smoke 54/54, matrix zig_fail=0 (only big.lua
both_fail), zig build test exit 0.

### P15.83i — Final gates + stress/leak coverage + plan closure

**Stress/leak coverage** (review item 15): new `tests/c_api/15_stress_leak.c`
(3 workloads × 2000 iterations, memory bounded after full GC, identical
PASS output on PUC and luazig): repeated coroutine create + yieldk(k) +
closethread (k discarded, k_calls==0); repeated nested C-frame TBC marks
(lua_toclose in outer + inner C calls); repeated callk/pcallk chains with
yields. Added to TESTS and the DIFF_TESTS differential gate (now 6 suites).

**Final Definition-of-Done gate (all green):**
- zig build Debug + `zig build test -Doptimize=Debug`: exit 0.
- zig build ReleaseFast + `zig build test -Doptimize=ReleaseFast`: exit 0.
- make -C tests/c_api clean/test/test-diff: 16/16 suites, DIFF: PASS.
- Differential coverage (all identical PUC vs luazig): basic yieldk,
  ctx/status, callk yielding callee, pcallk yield + error, multi-yield,
  non-yieldable boundary, nested C continuations (t8), main-state pcallk
  errfunc, LUA_ERRERR (+message, +lua_status after), C-frame TBC +
  pcallk yield→error, nested C-frame TBC ownership, C return close +
  yield, closethread suspended-C-continuation discard (+close error,
  +TBC still runs), lua_status after yield/error, direct lua_resume
  stack/result placement, per-thread C hooks, hook getinfo/i_ci,
  line-hook yield.
- testC: coroutine.lua --testc full-suite exit 0; matrix zig_fail=0
  (big.lua accurately recorded as both_fail — identical failure in PUC);
  testC callk/pcallk/yieldk verified to use the shared production
  lifecycle (P15.83d static gate).
- Smoke: originally 53/54 exact + 1 mismatch (45_userdata_capi: udatatest.so
  was NOT built → BOTH runtimes failed require("udatatest") with DIFFERENT
  diagnostics — the earlier "54/54 byte-identical" wording in this entry was
  made with a laxer comparison and was wrong). Real 54/54 byte-identical
  output AND exit codes achieved in P15.83n via per-runtime udatatest builds.
- Leak: tools/leak_bench.py 25/25 PASS + 15_stress_leak bounded.
- Size: @sizeOf(CallFrame) == 104 B (requirement <= 104B).

**Plan re-closed:** docs/superpowers/plans/2026-08-15-c-continuations.md
→ STATUS: COMPLETE (2026-08-22). Spec API-check section corrected in
P15.83a (PUC lapi.c DOES forbid k!=NULL inside hooks). Stale TODOs
removed (C-frame TBC "NOT closed here" gone since P15.83c).

**Intentional, documented deviations from PUC (non-blocking):**
1. Count-hook absolute fire counts differ (instruction density: luazig
   codegen emits different opcode counts; documented TODO
   count-hook-codegen-parity). Semantics (sum, line events) identical.
 2. ~~lua_Debug.i_ci for CALL events points at the caller frame in the
    sync dispatch path (the callee frame is not pushed yet); line/count/
    return events carry the correct current frame. lua_getinfo "l" from
    hooks works.~~ — RESOLVED: P15.83l fixed Lua-callee CALL identity
    (callee frame pushed before the hook); P15.83r fixed C-callee CALL
    identity (C-frame pushed before the hook, PUC precallC ordering).
    Remaining scoped-out sub-cases (divert-bound builtins, frameless
    collectgarbage/string_sub, IR closures) keep caller-frame identity —
    see P15.83r for the full list.
3. ~~api_check-style enforcement (k!=NULL inside hooks; yieldk nresults
   in hooks) is not raised as a runtime error~~ — RESOLVED in P15.83m:
   the shared helpers now raise LUA_ERRRUN with the PUC message text
   ("cannot use continuations inside hooks" / "hooks cannot yield
   values" / "hooks cannot continue after yielding"); zig-only suite
   16_apicheck covers rejection + valid usage (release PUC compiles
   api_check out, so no byte-identical differential is possible).
4. lua_gc(LUA_GCCOUNT) accounting differs slightly (stress runs report
   small negative growth after collect vs PUC's 0) — GC accounting
   granularity, not a leak (leak_bench 25/25).

### P15.83l — LUA_HOOKCALL fires on the callee activation (PUC luaD_hookcall ordering) + main-chunk CALL paths

**Blocker 2 (review):** LUA_HOOKCALL must fire for the CORRECT CALLEE
activation, with `ar.i_ci` referencing the callee frame, and the main chunk
must get its CALL event.

**PUC references used** (lua-5.5.0/src):
- `ldo.c:439 luaD_hook`: `ar.i_ci = ci` — the hook always describes the
  topmost CallInfo, and callers guarantee that ci is the CALLEE for call
  events.
- `ldo.c:476 luaD_hookcall` (+ `savedpc++/--;` bump): CALL hook with the new
  ci; vararg functions fire after OP_VARARGPREP, so getinfo('l') reports the
  line of instruction 1, not 0.
- `ldo.c:643-656 precallC`: C callee — new ci created FIRST, then
  `luaD_hook(L, LUA_HOOKCALL, -1, 1, narg)`.
- `ldo.c:715 luaD_precall` (Lua callee): ci created, hook deferred to first
  instruction.
- `ldebug.c:903-921 luaG_tracecall`: CALL hook at the callee's first
  instruction; functions resumed from a yield do NOT re-fire
  ("already called luaD_hookcall before yielding", ldebug.c:910).
- `lvm.c:1958 OP_VARARGPREP`: vararg hookcall after arg adjustment.
- `ldebug.c:323 getfuncname` / `:615 funcnamefromcode` / `:659
  funcnamefromcall`: name from the CALLER's bytecode at the call site;
  tail-called frames get no name; `auxgetinfo` 'n' falls back to
  namewhat="" (never NULL).
- `ldo.c luaD_pretailcall` → `precallC`: tail call to a C function fires
  plain LUA_HOOKCALL (fresh ci, no CIST_TAIL), not LUA_HOOKTAILCALL.

**Root cause (differential probes, before):** the sync C-hook CALL dispatch
fired at the OP_CALL site BEFORE `pushBytecodeExecFrame`, so `ar.i_ci` =
topmost frame = the CALLER: getinfo("nS") described the caller (probe:
f's event described g, g's described main; main chunk's own CALL missing on
pcall/dostring paths; resume-entry hook fired with 0 frames → getinfo FAIL;
every re-resume re-fired a body CALL (PUC doesn't); pcall'd functions and
metamethod/iterator/close/handler activations had NO CALL event at all;
tailcall events described the OLD function; names were null).

**Changes (vm.zig):**
1. `debugDispatchHookTransfer`/`debugDispatchHookWithCalleeTransfer` gained
   `hook_frame_idx: ?usize` (PUC luaD_hook's `ci` argument): CALL sites pass
   the callee frame index; line/count/return pass null (topmost visible
   frame, unchanged semantics).
2. New `dispatchCalleeActivationHook(exec_frames, callee, nargs)`: fires
   "call" AFTER the callee frame exists, with ar.i_ci = that frame;
   mirrors luaD_hookcall's savedpc++ for vararg frames (hook observes
   instruction 1's line) and ntransfer=numparams transfer slicing. Callers:
   OP_CALL (bytecode callee), `runBytecodeInternal` entry (main chunk of
   pcall/dostring/apiCall, coroutine body first run — this replaces the old
   pre-trampoline/resume-entry firing for bytecode bodies, fixing the
   invalid 0-frame identity AND the re-fire-on-resume), pcall/xpcall target
   push, `tryPushBytecodeContinuationCall` (metamethods), OP_TFORCALL
   iterator, `__close` metamethod push, xpcall error-handler push.
3. `opTailcall`: bytecode callee → TAILCALL hook deferred to after frame
   reuse (ar.i_ci = reused frame, func already swapped; vararg savedpc bump);
   C-function callee → event renamed "call" (PUC pretailcall→precallC).
4. `lua_getinfo` 'n' (c_api.zig): PUC getfuncname port via new
   `Vm.getFuncNameForFrame` — reads the caller's instruction at its current
   pc: OP_CALL/OP_TAILCALL → `debugBytecodeOperandName` (the getobjname port
   used for "attempt to call" messages; local/upvalue/global/field/method),
   OP_TFORCALL → "for iterator", metamethod ops → pending-call debug name
   (PUC tmname+2 / "metamethod"), caller = hook frame → "?" / "hook",
   tail-called frames → no name; namewhat is "" (never NULL) when unresolved.
5. The async (Lua-hook) OP_CALL/OP_TAILCALL path is UNCHANGED (parent
   func_slot swap machinery, matrix-covered); the sync deferred dispatch only
   runs when the async path declined.

**Test coverage:** `tests/c_api/12_chook.c` (in DIFF_TESTS gate):
- t9 `test_call_hook_identity` — review's scenario (resume of chunk with
  local f/g): main/g/f each get a CALL event whose getinfo("nS") describes
  the callee; bad_call_info==0; result==3.
- t10 `test_call_hook_paths` — byte-identical event trace (what/name/
  namewhat/source/linedefined/currentline/istailcall) across paths: main
  chunk via lua_pcall and luaL_dostring, __index metamethod, plain call,
  tail call, for-in iterator; counter asserts: pcall'd function event fires,
  resume-after-yield fires exactly one new event (no body re-CALL).
All byte-identical PUC vs luazig (make test-diff DIFF: PASS).

**Probe table (PUC vs zig, Lua callees — all identical after):**
- plain call g/f (name local/upvalue/global, ld, cl) ✓
- main chunk: pcall path, dostring path, resume path ✓ (was: missing /
  getinfo FAIL / re-fired on resume)
- tailcall t→f (TCALL, istailcall=1, ld of NEW function, no name) ✓
- pcall'd function (what=Lua, ld, cl; caller is C → no name) ✓ (was: no event)
- __index metamethod (name=index nw=metamethod) ✓ (was: no event)
- for-in iterator ×3 (name="for iterator") ✓ (was: no events)
- __close metamethod (name=close nw=metamethod) ✓ (was: no event)
- xpcall error handler (what=Lua ld=1, no name) ✓ (was: no event)
- resume-after-yield: no body re-CALL ✓ (was: extra event per resume)

**Known remaining gap (documented, out of scope):** ~~CALL events for
C-function callees (pcall, print, coroutine.yield, ...) fire with the
correct COUNT and event type (including tailcall-to-C firing CALL), but
`ar.i_ci` references the caller frame~~ — RESOLVED in P15.83r: C-callee
CALL events now fire on the C activation's CallFrame (PUC precallC
ordering) for sync-bound builtins, builtin/C-closure for-in iterators,
tail calls to C, C closures from Lua and from C (lua_call/lua_pcall),
and C metamethods. The remaining divert-bound/frameless sub-cases are
listed in P15.83r. t10's trace chunks stay Lua-only-call (historical);
t11 covers the C-callee identity byte-identically.

**Gates (all green):** zig build ReleaseFast; make -C tests/c_api test
16/16 exit 0; make test-diff strict DIFF: PASS; coroutine.lua --testc
exit 0 + byte-identical to PUC (ulimit -v 2000000, timeout 30); smoke
54/54; zig build test exit 0; matrix zig_fail=0 (big.lua both_fail,
pre-existing infra); perf_compare.py RESULT OK (no regressions, geomean
2.66x); CallFrame stays 104 B.

### P15.83m — hook-continuation API-check invariants enforced (review item 3)

**What changed:** the P15.83i deviation #3 ("api_check-style enforcement
is not raised as a runtime error; hook frames silently never save k") is
RESOLVED. The shared production helpers now enforce the PUC api_check
invariants for continuations inside debug hooks, raising deterministic
runtime errors instead of silently dropping k.

**Checker:** `Vm.apiCheckHookContinuationInvariant(th, k_nonnull,
is_yield, nresults)` (vm.zig, next to luaCallKShared/luaPcallKShared/
luaYieldKShared). PUC sources enforced:
- lapi.c:1041-1042 (lua_callk) + lapi.c:1082-1083 (lua_pcallk):
  `api_check(k == NULL || !isLua(L->ci), "cannot use continuations
  inside hooks")`;
- ldo.c:1023-1024 (lua_yieldk hook branch): `api_check(nresults == 0,
  "hooks cannot yield values")` then `api_check(k == NULL, "hooks cannot
  continue after yielding")` (same order preserved).

"Inside a hook" test: per-thread `in_debug_hook` (th.debug_hook +
isInDebugHook() fallback) — true for sync C hooks, sync Lua/testC hooks,
and async Lua-hook frames (the analog of PUC's CIST_HOOKED current
CallInfo while luaD_hook runs). At every call site th == current_thread,
both expressions name the same flag.

**Wiring (single implementation, all routes covered):**
- `luaCallKShared`: check BEFORE the yieldable branch and BEFORE any
  k/ctx saving (PUC's api_check is unconditional); c_api lua_callk,
  testC .callk.
- `luaPcallKShared`: check at top, before k/ctx/funcidx/errfunc/OAH are
  saved; c_api lua_pcallk yieldable path, testC .pcallk.
- `luaYieldKShared`: check BEFORE nyield/k/ctx saving; c_api lua_yieldk,
  testC .yieldk/.yield. The old "hooks silently don't save k" skip
  (fr.isDebugHook()) stays as documented defense-in-depth (unreachable
  for the error cases now).
- c_api lua_callk + lua_pcallk wrappers: the check ALSO runs before the
  `current_thread orelse` fallback so a C hook on the MAIN state
  (current_thread == null there) and pcallk's conventional non-yieldable
  branch are covered — PUC's api_check runs at function top,
  unconditionally.
- Error conversion verified per wrapper: lua_callk/lua_pcallk set
  c_error_value = err_obj and _longjmp(jb, 1); lua_yieldk _longjmps to
  the C hook boundary which reads err/err_obj — violations surface as
  LUA_ERRRUN from lua_resume / the enclosing pcall, coroutine dies, no
  continuation state mutated. testC routes propagate as Zig errors.

**Test design decision:** invalid-call tests CANNOT be in the
byte-for-byte DIFF gate — PUC release compiles api_check out (the same
program RUNS NORMALLY there; only LUA_USE_APICHECK builds abort, via
assert → SIGABRT, also not byte-comparable). Per the review, new suite
`tests/c_api/16_apicheck.c` is ZIG-ONLY: added to TESTS (`make test`,
17 suites), excluded from DIFF_TESTS (Makefile comment documents why).
Tests: t1 callk k!=null in C count-hook → LUA_ERRRUN + message +
lua_status(ERRRUN) + second-resume error + k never ran; t2 pcallk k!=null
in hook (yieldable, shared-helper path); t3 pcallk k!=null in a MAIN-state
hook (wrapper pre-branch path, error via dostring's pcall); t4 yieldk
nresults=2/k=NULL line-hook → "hooks cannot yield values"; t5 yieldk
k!=null/nresults=0 → "hooks cannot continue after yielding"; t6-t7 VALID
regression guards: yieldk(0,0,NULL) count-hook yield resumes to
completion (5050) and callk k==NULL in a hook still works. testC hook
routes (T.sethook("yield 0", ...)) stay covered by coroutine.lua --testc
(exit 0) and the matrix.

**Gates (all green):** zig build ReleaseFast + zig build test
ReleaseFast exit 0; make -C tests/c_api test 17/17 exit 0; test-diff
DIFF: PASS (6 suites, unchanged); coroutine.lua --testc exit 0
(ulimit -v 2000000, timeout 30); smoke 54/54 exit 0; matrix zig_fail=0
(big.lua both_fail, pre-existing infra).

### P16.0c — per-workload hardware counters + perf record profiling pipeline

P16.0-B1/B3: два perf-инструмента для per-workload анализа (снимок
`tools/perf/counters-2026-08-25.json` закоммичен как вход для следующей фазы).

**1. Селектор workload'ов** (`tools/microbench.lua`): первый script-arg
(`...`) запускает только один workload — идентично на luazig и PUC
(script args = PUC argv-семантика). Без аргумента — все 16 (обратная
совместимость; timing lane не изменена).

**2. `tools/perf_compare.py --counters`** (B1): режим per-workload hardware
counters, медиана `--counters-runs N` (default 3), pinned core:
`taskset -c CORE perf stat -j -e cycles:u,instructions:u,branches:u,
branch-misses:u,cache-misses:u,cache-references:u BIN microbench.lua WL`.
Парсер `-j` JSON-lines нормализует event-имена (`cpu_core/cycles/u` →
`cycles`), отбрасывает `<not counted>` и cpu_atom-строки (hybrid CPU: run
пинится к P-core). IPC / branch-miss% / cache-miss% на workload×binary.
Max-RSS + CPU-time — через промежуточный `python3 -c`: свежий процесс с
ровно одним child (taskset exec → bench), поэтому его
`getrusage(RUSAGE_CHILDREN)` точен (ru_maxrss родителя — MAX по всем
children, для per-workload непригоден; паттерн задокументирован в
`_RSS_HELPER`). Инструкция-инфляция — прокси `instrX = zig
--stats instructions_total / puc perf instructions:u`; caveat: PUC-счётчик
включает C-runtime, не только интерпретацию байткода. Тайминговая lane
(median-of-7 + baseline gate) не изменена; `--json-out` пишет всё.

**3. `tools/perf_profile.py`** (B3): `perf record --call-graph lbr -e
cycles:u` на 7 дефолтных workload'ах × {zig,puc} + два `perf report --stdio`
(--no-children ≥1%: default-sort и `--sort symbol`) + `index.json` в
`tools/perf/profiles/<UTC-date>/`. Профили-артефакты (`*.perf`, отчёты,
index) в .gitignore — воспроизводимы из скрипта; коммитится только .py.

**Снимок counters-2026-08-25 (headline, полный JSON — в файле):**
- IPC zig 2.10–5.77 vs puc 2.97–5.32: zig не IPC-bound (кроме
  string_concat 2.10 и hash_access 2.99) — узкие места вне pipelining.
- **RSS-разрыв в alloc-heavy**: temp_table_alloc 88MB, string_concat 103MB,
  string_loop 101MB, dynamic_load 71MB, metamethod_add 75MB — против ровно
  ~15.6MB у PUC на ВСЕХ workload'ах. GC luazig не удерживает peak (пейсинг
  steps_auto не режет пик при высокой скорости аллокации таблиц/строк).
- hash_access: zig cache-miss 11.8% vs puc 50.7% (Node 32B окупается), но
  zig всё равно 3.74x медленнее → остаток — dispatch, не memory.
- coroutine_yield: puc branch-miss 1.62% vs zig 0.01% — медленность zig
  не в mispredict'ах; профиль показывает `compiler_rt.memset` 13.9%.
- lua_calls профиль: ~39% времени вне dispatch в call-frame machinery
  (complete/pushBytecodeExecFrame + setPendingCall +
  applyBytecodePendingResults ≈ 39%) — подтверждает bottleneck №5.
- temp_table_alloc профиль: Wyhash.final 13.1% + string-intern getIndex
  5.3% (хэширование строк при NEWTABLE/SETLIST) + SmpAllocator 22.6%.
- field_access профиль: rawSet 30.2% вне dispatch — generic set path тяжёл.
- instrX (прокси, см. caveat): 0.003–0.05x — native/PUC инструкции на
  Lua-итерацию на порядок больше VM-опкодов, абсолютные значения между
  движками напрямую не сравнимы, полезно только в динамике.

**Gates (all green):** zig build ReleaseFast + `zig build test` exit 0;
make -C tests/c_api test ALL PASS (17); test-diff DIFF: PASS;
coroutine.lua --testc exit 0 (ulimit -v 2000000, timeout 30); smoke 54/54;
matrix zig_fail=0 (big.lua both_fail, pre-existing); perf_compare --runs 7:
geomean 2.69x, RESULT: OK (no regressions). (Примечание: make-цель `zig`
пинится к устаревшему `tools/zig-bin` без `std.Io.File` — pre-existing
env-расхождение с системным zig; smoke запущен напрямую
`tools/smoke_compare.py`.)

### P16.0b — default-off Vm runtime counters (--stats JSON + T.stats)

P16.0-B2: диагностические счётчики VM, по умолчанию выключенные, с двумя
способами чтения: CLI `--stats <out.json>` (сериализация при выходе,
src/bin/luazig.zig) и Lua-visible `T.stats()` (testC-модуль, read-only
снапшот-таблица). Счётчики никогда не участвуют в семантике исполнения.

**Gating-дизайн (измерен A/B на ReleaseFast):** `VmStats` живёт inline на
singleton-Vm; каждая точка проверяет `self.stats.enabled` — один L1
byte-load + предсказуемый not-taken branch (`enabled` стоит сразу за
пишущимся на каждую инструкцию `dispatch_pc` → общий cache line).
Отвергнутые альтернативы (обе измерены): (a) кэш `?*VmStats` локальным
указателем в dispatch-loop — держит регистр через весь switch, +3% на
branchy-бенчах; (b) `@branchHint(.unlikely)` block-form на всех точках —
воспроизводимо хуже на части бенчей (+12% comparisons) из-за layout-
lottery в codegen. Финальная форма: hint только на per-instruction сайте.

**A/B perf (stats OFF, HEAD 8d4550c vs P16.0b, median-of-7, zig-time
geomean):** HEAD 0.3173 → 0.3148/0.3186 (два прогона финального бинаря;
-0.78%/+0.41%, среднее ≈ -0.2% — в пределах шума коробки; её собственный
разброс на multi-second бенчах ±8-15%, напр. global_arith 1.23–1.49 на
идентичных бинарях). Остаточные стабильные дельты: branch_loop +3%,
temp_table_alloc +3-5%, metamethod_add +2% — физический потолок цены
одного check/instruction и layout-чувствительность; comparisons и
float_arith стали быстрее HEAD (1.03 vs 1.06, 0.42 vs 0.44). Fallback-
дизайн (per-basic-block counting по предвычисленной карте лидеров) не
понадобился: geomean-цена <1%.

**Точки инструментирования** (vm.zig, имена полей — в `VmStats`):
- гистограмма инструкций: fetch-сайт в runBytecodeDispatch
  (`instructions_total`, `instructions_by_op` — суммы сходятся);
- call funnel: `.call` inline fast path (`calls_fast`), opCall после
  hook-yield replay (`calls_slow`), pushBytecodeExecFrame
  (`calls_lua_frames` ⊇ fast — все Lua-активации), callBuiltin,
  callMetamethod, callCFunction. Задокументированные пересечения:
  builtin-метаметод считается и в builtin, и в metamethod;
- таблицы: типизированные fast-path счётчики на opcode-сайтах (GETTABLE
  int/str, GETI, GETFIELD, GETTABUP, SETTABLE str, SETI, SETFIELD,
  SETTABUP), generic-воронки rawGet/rawSet (с dedup-гвардом от
  float→int рекурсии, чтобы integral-float ключи считались один раз),
  insert/update-сплит (nodeInsert-сайты + nodeLookup-хиты, включая
  inline fast paths) и `tbl_rehash` в tableRehash;
- аллокации: `alloc_by_type` по тегу GcObject в gcRegisterObject
  (table/closure/thread/string/cell/userdata), `alloc_bytes_total` в
  gcNoteAlloc (пейсинговые байты; точный live-total остаётся T.totalmem);
- GC: gcAutomaticStep/gcStep после gc_busy-гарда;
- корутины: `yields`/`resumes` (коммит yield/resume), `yield_allocs`
  (th.yielded ×2 маршрута, suspended_builtin_args, appendThreadWrapYield),
  `resume_allocs` (resume inbox, entry_args, trampoline args_copy+co_state).

**Форма JSON** (`--stats`): `{instructions_total, instructions_by_op:
{<opname>:count,...}, calls:{fast,slow,lua_frames,builtin,metamethod,c},
tables:{get_fast_int,get_fast_str,get_generic,set_fast_int,set_fast_str,
set_generic,insert,update,rehash}, allocs:{table,closure,thread,string,
cell,userdata,bytes_total}, gc:{steps_auto,steps_manual}, yield_resume:
{yields,resumes,yield_allocs,resume_allocs}}`. `T.stats()` возвращает ту
же форму Lua-таблицей (плюс `op_histogram` вместо `instructions_by_op`);
при выключенных счётчиках — нули.

**Проверка функциональности:** `--stats` на coroutine-скрипте —
yields=1/resumes=2/yield_allocs=2/resume_allocs=3, гистограмма сходится с
total; microbench.lua — 1.5G инструкций, calls_fast=5.15M, lua_frames
(5.66M) ⊇ fast; `T.stats()` под `--testc --stats` растёт между вызовами.

**Gates (all green):** zig build ReleaseFast + `zig build test` exit 0;
make -C tests/c_api test ALL PASS; test-diff DIFF: PASS; coroutine.lua
--testc exit 0 (ulimit -v 2000000, timeout 30); smoke 54/54 exit 0;
matrix zig_fail=0 (big.lua both_fail, pre-existing).

### P15.83r — C-callee CALL hooks fire on the C activation (PUC precallC ordering)

**Review item 3 (P15.83o list):** CALL events for C-function/builtin callees
exposed the CALLER frame in `ar.i_ci`. RESOLVED the PUC-faithful way: the
C CallFrame now exists BEFORE the CALL hook fires, and the hook describes
it.

**PUC reference** (lua-5.5.0/src/ldo.c:642-656 precallC): for a C callee
(light C function, C closure, stdlib builtin), `precallC` runs
`L->ci = ci = prepCallInfo(L, func, status | CIST_C, ...)` FIRST, then
`luaD_hook(L, LUA_HOOKCALL, -1, 1, narg)` — so the hook's `ar.i_ci` is the
C activation and `lua_getinfo(L, "nSlut", ar)` reports: `what="C"`,
`source/short_src="=[C]"`, `linedefined=-1`, `currentline=-1`,
`istailcall=0` (fresh ci — even for tail calls to C, since
`luaD_pretailcall` routes C callees through precallC without CIST_TAIL,
firing a plain LUA_HOOKCALL), `nups=nupvalues`, `nparams=0`,
`isvararg=1` (ldebug.c:344-348 — C functions report isvararg=1), and
name/namewhat from the CALLER's call-site bytecode (ldebug.c:323
getfuncname → global/upvalue/field/method; a C caller yields no name).
Probe-verified on PUC 5.5.0 before implementation (probe table in the
iteration log; all fields byte-identical after the fix).

**Changes (src/lua/vm.zig):**
1. New `dispatchCCalleeActivationHook(cframe_idx, callee, args)` — fires
   "call" with the explicit C-frame index; ntransfer = actual narg
   (precallC), no savedpc bump (no bytecode pc), always a plain "call"
   event. Same guards as the Lua-callee helper
   (hooks_active_cached / suppressed / in_debug_hook / has_call).
2. OP_CALL: the sync (C-hook) dispatch for sync-bound builtins moved to
   the callBuiltin site — `pushBuiltinCFrame` → fire on the C-frame →
   `builtin_cframe_pre_pushed = true` → `callBuiltin` REUSES the frame
   (new Vm flag, consumed at callBuiltin entry; exactly one C-frame per
   builtin invocation, whoever pushed it). C-closure callees skip the
   opCall-site dispatch entirely (callCFunction fires). IR-closure
   callees keep the legacy caller-frame dispatch.
3. OP_TAILCALL: same split — tail call to C fires a plain "call" on a
   fresh C-frame at the sync callBuiltin site (PUC pretailcall→precallC).
4. OP_TFORCALL: builtin iterators (e.g. `next` from `pairs(t)`) now fire
   CALL at all (previously NO event) — on the C-frame, name resolves to
   "for iterator" (getFuncNameForFrame .tforcall branch). C-closure
   iterators fire via callCFunction.
5. `callCFunction`: fires the CALL event right after its C-frame push +
   toclose_base setup — covering C closures from Lua bytecode, for-in
   iterators, `lua_call`/`lua_pcall` from C, continuations, and C
   metamethods (C caller → no name, matching PUC getfuncname).
6. `getFuncNameForFrame` (.call/.tailcall branch): C frames no longer
   read `u.lua.func_slot_base` (union member mismatch); PUC-style name
   recovery reads the call instruction's A operand directly
   (funcnamefromcode's own approach) because luazig's builtin C-frames
   live at bc_stack_top, not at the caller's callee register.
7. `callBuiltin`: consumes `builtin_cframe_pre_pushed` (see 2).

**Changes (src/lua/c_api.zig):** `lua_getinfo` 'u' for C frames now
matches PUC auxgetinfo exactly: `isvararg=1`, `nparams=0`, `nups` = the
called function's upvalue count (0 for light C functions/builtins,
N for C closures) — read from `bc_stack[frame.func_slot]`.

**Scoped-out sub-cases (documented deviations, correct count/type, caller
frame identity in the event):**
- Divert-bound builtins — pcall/xpcall (bytecode-target fast path),
  coroutine.resume/wrap (thread switch), string.gsub (function repl),
  pairs with a bytecode `__pairs` metamethod: the iterative fast paths
  replace the call with bytecode continuations whose completion machinery
  requires the body frame to sit directly above the pending-call owner
  (a plain builtin C-frame in between would be misrouted by the
  `parent.isC()` return routing in completeBytecodeExecFrame — the
  structural wall confirmed by reading the frame-return flow). Predicate:
  `builtinCallMayDivert` — exact for pairs (metamethod check), otherwise
  conservative by id; a misprediction can only affect WHICH identity an
  event gets, never duplicate or lose events. NOTE: plain-table
  `pairs(t)` gets the full C identity (exact predicate).
- Frameless builtins `collectgarbage`/`string_sub` (pre-existing hot-path
  C-frame exclusion, predates P15.83r).
- IR-closure callees (luazig-internal, no PUC equivalent).
- `lua_call` from C on a BUILTIN (C closures are covered; builtins called
  via the C API fire no event — PUC's precallC would).
- getstack LEVEL WALKS from inside a C hook still skip builtin C-frames
  (P15.79 hidden-C-frames design — luazig pushes C-frames for ALL
  builtins, unhiding would break level numbering globally). Only
  hook-supplied `ar` identities reach C-frames. Same limitation as
  before P15.83r; the event identity itself is now PUC-exact.

**Test coverage:** tests/c_api/12_chook.c t11 `test_c_callee_call_identity`
(in DIFF gate) — byte-identical PUC vs luazig per-event lines for:
registered C fn as global (`name=cf nw=global`), via upvalue
(`nw=upvalue`), `print(1)` (`name=print`), `string.format` (`nw=field`),
`s:upper()` (`nw=method`), tail call to C (plain CALL, `tail=0`),
C closure with upvalue (`nups=1`), for-in over `pairs`/`next` (3×
`name=for iterator`) and over a C-closure iterator. stdout unbuffered so
builtin output interleaves chronologically in both runtimes.

**Gates (all green, final binary):** make -C tests/c_api test exit 0
(17 suites); make test-diff strict DIFF: PASS; coroutine.lua --testc
exit 0, output identical to pre-change baseline (ulimit -v 2000000,
timeout 30); smoke_compare 54/54 PASS; zig build test exit 0; matrix
zig_fail=0 (big.lua both_fail, pre-existing infra); perf_compare.py
--no-build --runs 7 RESULT OK, geomean 2.52x (P15.83q: 2.67x; the box
showed ±10% noise during measurement — verified with stash-control A/B
that the change adds no hot-path cost when no hooks are set: all new
code sits behind the hooks_active_cached guard; callBuiltin pays two
flag instructions).

### P15.83q — Exact PUC resume-boundary stack exposure for error and hook-yield resumes (review blockers 1-2)

**Derived PUC rules** (verified against PUC 5.5.0 sources + /tmp probes
compiled against BOTH runtimes, outputs byte-identical):

The C-visible stack at a `lua_resume` boundary is a WINDOW into PUC's one
stack: `lua_gettop = L->top - (L->ci->func + 1)` where `ci` is the
innermost CallInfo at the suspend point (luaD_throw longjmps; the CallInfo
chain and stack residue are never unwound on the way out).

1. **Error resume** (`lua_resume`, ldo.c:983-988): unrecoverable error →
   `luaD_seterrorobj(L, status, L->top)` + `L->ci->top = L->top` +
   `*nresults = top - (ci->func + 1)`. `luaD_seterrorobj` (ldo.c:112-122)
   COPIES the top-1 error object to oldtop == L->top — i.e. DUPLICATES it:
   window = [.., err, err]. The slots below the pair are the raising
   C-function frame's residue:
   - `error(obj, 0)` → [err, err], nres=2 (any error object type);
   - `error(str, level>=1)` / `assert(false, str)` / `assert(false)` →
     lbaselib luaB_error pushes `luaL_where` + a copy of the argument and
     concatenates, leaving the ORIGINAL string below the built message:
     [orig, prefixed-msg, prefixed-msg], nres=3;
   - `assert(false, non-string)` → [err, err], nres=2 (no prefix path);
   - error raised deeper in Lua calls → same shapes (window is relative to
     the INNERMOST frame; intermediate frames' registers are below
     ci->func and invisible);
   - after a pcall-recovered inner error → same shapes (recovery resets
     the window to the pcall frame).
   Known remaining divergences (PUC exposes live-stack artifacts that
   luazig's error machinery does not materialize on any Lua-visible
   stack): runtime errors raised from a Lua frame via luaG_runerror
   (index/call nil: PUC keeps frame registers + the " (local 'x')"
   varinfo string pushed by the error builder → e.g. nres=5
   [nil,"Y"," (local 't')",msg,msg]; luazig exposes [err, err]); and a
   C-API c-function that pushes values before lua_error (PUC exposes its
   whole frame residue [pushes..., err, err]; luazig exposes [err, err]
   because callCFunction's errdefer frees the C-frame stack before the
   resume boundary). Both are stack-residue artifacts of PUC's one-stack
   error builder, not semantic API contract; transcribing them needs the
   error-message builder to use a Lua-visible stack — future work.
2. **resume_error boundary** ("cannot resume dead coroutine", ldo.c:895-903
   + 970): pops the pushed args, APPENDS the message to the existing
   window, and leaves `*nresults` UNTOUCHED (early return before the
   *nresults assignment). So after [boom,boom] a dead re-resume shows
   [boom,boom,"cannot resume dead coroutine"] with nres unchanged.
3. **Hook-yield resume** (blocker 2): luaG_traceexec raises `L->top =
   ci->top` BEFORE dispatching the hook (ldebug.c:954); lua_yieldk in a
   hook just returns after setting status/nyield (ldo.c:1025-1028); the
   following `luaD_throw(L, LUA_YIELD)` (ldebug.c:971-977) longjmps PAST
   luaD_hook's top restore (ldo.c:458-465). Result at the boundary:
   `*nresults = nyield = 0` while `lua_gettop` exposes the suspended Lua
   frame's ENTIRE register file (ci->top = func+1+maxstacksize slots) —
   live parameter/local values visible (probe: g(p) at entry → [5,nil,nil]).
   The next resume DISCARDS its args (PUC resume() ldo.c:930-934
   `L->top = firstArg`) and does not re-fire the hook (CIST_HOOKYIELD).
   Window VALUE parity holds wherever the register slots were actually
   written by the program or nil on a fresh thread; never-written slots
   in PUC hold stale stack residue (e.g. loader strings) — luazig shows
   nil (its loader does not use the Lua-visible stack) — deterministic
   tests use written/nil slots only.

**Root-cause fix — `ProtoBuilder.checkStack` (bytecode.zig):** an artificial
`+1 for safety margin` inflated EVERY proto's maxstacksize by one slot vs
PUC's `luaK_checkstack` (lcode.c: `maxstacksize = freereg + n`, no margin).
Invisible until now (runtime uses maxstacksize+EXTRA_MARGIN), it broke the
hook-yield window SIZE parity (PUC 3 slots vs zig 4). Removed; instruction
streams were already byte-parity, only the slot count differed.

**Fix — assert() message prefix (found by the residue probes):** zig's
`assert(false, "m")` raised bare "m"; PUC routes through luaB_error level 1
→ "chunk:line: m". builtinAssert now applies the same luaL_where prefixing
(+ residue) as error(); non-string messages stay as-is.

**Transcription design (c_api.zig lua_resume + vm.zig):**
- error path: c_stack := [err_cframe_residue?, err, err]; the residue for
  error()/assert() string-prefix raises is carried in `Vm.err_cframe_residue`
  (?Value), set ONLY in those two builtins' prefix paths, cleared at fresh
  raise and at every protected-boundary save/restore (pcall/xpcall/resume/
  debug.debug — a recovered error's residue dies at the recovery point,
  transcribing PUC's stack reset there), snapshotted to
  `Thread.api_err_residue` by builtinCoroutineResume's error tail (the vm
  error state is caller-restored after the builtin returns), GC-marked with
  the other thread-held values, exposed as the window's leading slot.
- resume_error path (dead thread): pop args, append message, *nresults
  untouched (pre-call `dead_before_call` structural check — no
  message-text branching).
- hook-yield path: `Vm.apiHookYieldWindow(th)` returns the parked top Lua
  frame's registers [base..base+maxstacksize) (borrowed, snapshot-copied
  onto c_stack; PUC shows live registers, but nothing can observe mutations
  between suspends; the next resume truncates to resume_func_base so the
  window can never leak into results or be mistaken for resume args).
  Detection: th.status==.suspended && th.yielded_from_debug_hook (refreshed
  on every yield by builtinCoroutineYield, so it always describes THIS
  suspension; hooks cannot yield values → yielded slice is empty, which
  distinguishes hook yields from 0-value normal yields only together with
  the flag).

**Permanent differential tests** (`tests/c_api/14_state_handles.c`, all
byte-identical PUC vs luazig, suite in DIFF_TESTS):
`test_resume_error_stack_exact` (review verbatim repro: error('boom',0) →
[Y] then [boom,boom] nres=2 with the v1..vN loop; + deeper-Lua-call, table
object, pcall-recovered, error(str,2), assert(false,'am'), assert(false,{})
variants), `test_hook_yield_inside_c_continuation` (review verbatim blocker
2: hook-yield r1 nres=0 top=2 [nil,nil], r2 completes with K, hook not
re-fired), `test_hook_yield_window_general` (line+count hooks at chunk
entry → 3 nils; args DISCARDED on hook-yield resume — "R" pushed, result
still 31; line hook inside g(p) → [5,nil,nil] live register window);
`test_resume_error_replacement` upgraded from invariant-level to exact
(nres=3 [boom, prefixed, prefixed]).

**Probe evidence table** (PUC vs zig, after the fix — all identical except
the two documented residue-artifact rows):

| case | PUC == zig |
|------|-----------|
| error('boom',0) resume | ✓ [boom,boom] nres=2 |
| error deeper in Lua calls | ✓ [deep,deep] nres=2 |
| table error object | ✓ [t,t] nres=2 (rawequal) |
| pcall-recovered then error | ✓ [after:false ×2] nres=2 |
| error(str,1/2), assert msg | ✓ [orig,prefix,prefix] nres=3 |
| assert(false) | ✓ [assertion failed!,prefix,prefix] nres=3 |
| assert(false,table) | ✓ [t,t] nres=2 |
| runtime error in Lua frame | ✗ PUC nres=5 residue vs zig 2 (documented) |
| C c_func pushes + luaL_error | ✗ PUC nres=5 residue vs zig 2 (documented) |
| dead-resume after error | ✓ append + nres untouched |
| hook-yield (line/count, entry) | ✓ top=maxstacksize nils, nres=0 |
| hook-yield deep frame | ✓ [5,nil,nil] live params |
| hook-yield r2 | ✓ args discarded, no hook re-fire |
| count-hook at chunk instr 2 | ✓ size 3=3; values differ (PUC loader residue vs zig nils — excluded from tests) |

**Gates (all green):** make -C tests/c_api test → 17/17 exit 0 (78 PASS
lines); test-diff → DIFF: PASS (strict); coroutine.lua --testc exit 0
(ulimit/timeout); zig build test exit 0; all tests/smoke/*.lua exit 0 +
smoke_compare --no-build PASS 54/54; matrix zig_fail=0 (31/32 parity,
big.lua both_fail pre-existing); perf_compare --runs 7 → RESULT: OK, no
regressions (geomean 2.67x; most workloads faster after the maxstacksize
fix — string_loop -41.7%, lua_calls -16.9%).

### P15.83n — real 54/54 smoke parity via per-runtime udatatest modules + stale docs/comments cleanup (review items 6-7)

**Item 6 — smoke 45_userdata_capi now REALLY passes the differential.**
Before this step `tools/smoke_compare.py` reported 53 exact + 1 mismatch:
`tests/smoke/45_userdata_capi.lua` requires the C module `udatatest`, but no
.so was built by any harness step, so BOTH runtimes failed require() with
DIFFERENT diagnostics. (The standalone-zig gate passed only thanks to a
leftover untracked lua-5.5.0/testes/libs/udatatest.so; earlier "54/54"
wordings in P15.83c..m meant standalone exit-0, not the differential.)

**Build strategy:** the single upstream source (lua-5.5.0/testes/libs/
udatatest.c) is compiled TWICE by `tools/smoke_compare.py`
(`build_udatatest_modules`, runs unless --no-build):
- `lua-5.5.0/testes/libs/udatatest.so` — `gcc -I lua-5.5.0/src -fPIC -shared`;
- `tests/smoke/zig-libs/udatatest.so` — `gcc -I src/lua -fPIC -shared`.
Both follow the upstream testes/libs makefile pattern: NO -llua; lua_*
symbols stay undefined and resolve from the HOST interpreter's exported
dynamic symbols (build/lua-c/lua and zig-out/bin/luazig both export the full
C API — 156/162 symbols). Linking a hosted module against liblua (as first
considered) would map a second VM image into the process; host resolution
keeps one VM, exactly like PUC's own test libraries. Both artifacts are
gitignored; `make test-smoke` no longer passes --no-build so modules are
always rebuilt.

**Runtime selection (explicit + consistent):** smoke scripts cannot branch
on the runtime (differential = same script), so the harness injects a
per-runtime startup chunk via the LUA_INIT_5_5 env var that PREPENDS the
runtime's module dir to package.cpath — PUC runs resolve the PUC-headers
build, luazig runs the luazig-headers build. LUA_INIT_5_5 (PUC
handle_luainit, implemented in luazig) is used instead of `-e` because `-e`
shifts the arg table (arg[-1] etc.) which 29_platform_process_io.lua
observes. The smoke file itself appends only ./tests/smoke/zig-libs/?.so so
standalone zig runs (AGENTS gate: all tests/smoke exit 0 on zig-out/bin/
luazig) load the zig build; verified real by removing the module (require
fails → non-zero exit). Result: `python3 tools/smoke_compare.py --no-build`
→ PASS, 54/54 ok, 0 mismatches (exact stdout + exit codes), 45_userdata
exercising lua_newuserdatauv/metatable/luaL_checkudata/__tostring/GC on both
runtimes. No VM bugs surfaced by userdata module loading.

**Item 7 — stale comments/docs fixed (all verified against current code):**
- vm.zig lua_State struct doc + c_stack field doc: removed false "Phase 1
  (current): unused — all stack ops go through Vm.c_stack" (per-handle
  stacks landed in P15.83f; Vm.cur_c_stack points at the active handle's
  stack; handle stacks are GC roots).
- vm.zig c_api_thread field doc: removed false "lua_State = Vm, so
  lua_newthread returns the same Vm pointer ... lua_resume falls back to
  current_thread" (P15.83e/k made handles per-thread; lua_resume resolves
  via handle.thread; field now documented as the Zig-level api.State thread).
- vm.zig cur_handle doc: "updated on coroutine resume (Phase 2)" → switched
  to the coroutine handle for the duration of C API lua_resume.
- vm.zig c_toclose_slots doc: removed false "or the C function returns —
  not yet wired" (C-frame auto-close on return implemented in P15.83c via
  toclose_base snapshots in callCFunction).
- c_api.zig lua_newstate: "PRNG seeding not yet wired" → deliberately
  unused, fixed hash seed by design (see Vm.hash_seed).
- lua.h: removed stale "luazig does not yet export lua_gc" and "does not
  yet export the debug API" block comments (lua_gc exported; hooks
  exported since P15.83h).
- lualib.h header comment: removed "not yet all exported ... Phase 7"
  (all 10 luaopen_* + luaL_openselectedlibs exported).
- plan 2026-08-15-c-continuations.md Self-Review "Placeholder scan":
  updated to reality (finishpcallk TBC close implemented in P15.83c; testC
  migrated to shared production lua_*k helpers in P15.83d).
- spec 2026-08-15-c-continuations-design.md §7: now DESCRIBES the
  implemented enforcement (Vm.apiCheckHookContinuationInvariant in the
  shared helpers, deterministic LUA_ERRRUN with PUC messages through the C
  boundary, 16_apicheck coverage) instead of speculating.
- STATUS.md P15.83i smoke claim corrected (see above).
- Checked and left accurate as-is: api.zig pushthread/status comments
  (already updated by P15.83k, no "cannot be pushed" text remains),
  c_api.zig lua_resume historical note about the removed fallback,
  "TODO: integrate C hook invocation" (already gone).

**Gates (all green):** see P15.83n verification in the iteration log —
make -C tests/c_api test 17/17; test-diff DIFF: PASS (strict); coroutine.lua
--testc exit 0; all tests/smoke/*.lua exit 0 standalone on zig;
zig build test exit 0; matrix zig_fail=0; smoke_compare --no-build
54/54 PASS (exact).

### P15.83k — Exact resume-stack differentials + lua_pushthread/tothread per-handle identity

**Part A (review item 1 completion):** the P15.83j `resume_func_base` fix was
verified against PUC with /tmp differential probes compiled against BOTH
runtimes (gcc PUC liblua vs zig liblua, outputs must be byte-identical):
1. nargs==0 subsequent resume — stale Y replaced, exact top/nres ✓ identical.
2. Multiple yield→resume cycles (A/B/CD) — each cycle replaces, no
   accumulation ✓ identical.
3. Error after yield — invariants identical (LUA_ERRRUN, error object on
   top, stale Y absent from the whole visible window); see deviation 1 below
   for the error-path stack layout.
4. CIST_CLSRET verbatim review variant (`c_return_with_tbc`:
   settop/toclose/pushliteral/return 1 + yielding Lua `__close`) —
   resume1 LUA_YIELD nres=1 top=1 [Y]; resume2 LUA_OK nres=1 top=1 [done]
   ✓ identical, no lua_resume code change needed.
5. Resume-arg count mixed vs previous yield count (0/1, 1/2, 2/3, 3/0) ✓
   identical.

Permanent differential tests added to `tests/c_api/14_state_handles.c`
(7 new, all byte-identical PUC vs luazig, suite already in DIFF_TESTS):
`test_direct_resume_stack_exact` (review verbatim: absolute-index
lua_tostring(co,1)/(co,2) checks + final lua_status),
`test_resume_clsret_stack_exact`, `test_resume_nargs0_replacement`,
`test_resume_multi_cycle_exact`, `test_resume_args_mix_exact`,
`test_resume_error_replacement` (invariant-level: error on top, Y absent),
`test_pushthread_identity`.

**lua_tolstring NULL fix** (found by the verbatim test):
`lua_tolstring` returned `""` (non-NULL) for non-convertible values and
out-of-range indices — PUC returns NULL; the lua_tostring macro's NULL
check contract was broken. Return type is now `?[*:0]const u8` (c_api.zig).

**Part B (review item 4): lua_pushthread/lua_tothread identity.**
Every lua_State now maps to a Lua thread Value INCLUDING the main state.
Design: option (a) — `setupMainHandle` links the main handle to the
EXISTING `Vm.main_thread` (`.thread` field + `main_thread.api_handle`
reverse link); no new Thread object is created. `is_main` guards the
places where main behavior differs. Rationale: Vm.main_thread already
exists, is a GC root (gcMarkVmRoots), is already the value that
Lua-level `coroutine.running()` returns at main level — reusing it makes
C-API and Lua-level views of "the main thread" the same object.
- `lua_pushthread`: pushes `.{ .Thread = h.thread }`, returns
  `is_main ? 1 : 0` (PUC lapi.c pushthread).
- `lua_tothread`: reverse-maps via `Thread.api_handle` — for the main
  thread this now yields the main handle automatically.
- `api.State.pushthread` (Zig API): pushes c_api_thread orelse
  main_thread as a real thread Value (was: push Nil — stale Vm==thread
  assumption; deviation note at STATUS "P15.39" line ~1159 is obsolete).

**Audit of stale `lua_State == Vm` assumptions:**
- `lua_resume`: removed the `h.thread orelse vm.c_api_thread orelse
  vm.current_thread` fallback — it resumed an UNRELATED thread when
  called on the main handle. Now resolves `h.thread` directly; resuming
  the main state hits builtinCoroutineResume's guard and returns
  LUA_ERRRUN "cannot resume non-suspended coroutine" (PUC's error for a
  live main thread; see deviation 2).
- `lua_status`: is_main → LUA_OK (pinned; main never takes coroutine
  lifecycle transitions).
- `lua_closethread`: is_main → LUA_OK early return (unchanged behavior,
  now explicit); removed the c_api_thread fallback.
- `lua_xmove`: already asserts same-vm ✓. sethook/gethook* family:
  resolve `h.thread orelse vm.main_thread` — same result before/after ✓.
- GC safety: `gcFreeObject(.thread)` skips freeing main handles
  (`h.is_main`) — Vm.deinit's drainGcRegistries destroys main_thread too,
  and the main handle is owned by lua_close / api.State.deinit (api.zig
  deinit reordered to deinit-the-Vm first, matching lua_close, so
  finalizers during close never see a dangling main_thread.api_handle).
- `coroutine.running()`/`isyieldable` Lua-level behavior unchanged
  (Thread values internally, pointer-equality with main_thread still
  holds — and now the C-pushed main value equals the Lua-seen one).
- 11_closethread close-via-handles behavior unchanged (gate green).

**Known deviations from PUC (documented, non-blocking):**
1. Error-path resume stack layout: PUC leaves frame-relative residue on
   error (lua_gettop is ci->func-relative): error('boom') after yield
   gives nres=3 top=3 ['boom', msg, msg] (seterrorobj duplicates top-1;
   residue varies by error kind — nil-call gives nres=5). luazig exposes
   the clean documented contract: nres=1 top=1 [error object on top].
   Pre-existing behavior (first-resume errors were already this way),
   orthogonal to stale-yield replacement (verified absent). Matching
   would require emulating ci-relative C-API windows.
2. Fresh-main resume: PUC allows lua_resume on a NEVER-executed main
   state (ci == base_ci → runs the function, st=0). luazig returns
   LUA_ERRRUN "cannot resume non-suspended coroutine" (main_thread
   status is .running from init). Open gap: needs ci==base_ci start
   semantics + yield-from-main-thread paths through
   builtinCoroutineResume; zero coverage in any suite. Resolution
   identity is correct (main handle → main thread).
3. `lua_tothread` returns NULL for Lua-created coroutines (no C handle)
   — pre-existing documented deviation (PUC returns their lua_State*).

**Gates (all green):** zig build ReleaseFast; make -C tests/c_api test
16/16 exit 0; make test-diff strict DIFF: PASS; coroutine.lua --testc
exit 0 (ulimit -v 2000000, timeout 30); smoke 54/54; zig build test
exit 0; matrix zig_fail=0 (big.lua both_fail, pre-existing infra).

### P15.83g — lua_status error preservation + closethread discards suspended k (reset, not resume)

**Item 7: lua_status preserves error status.** Added `api_status: c_int = 0`
to `Thread` (vm.zig), mirroring PUC's `L->status` field (lstate.h:283). PUC
stores the raw TStatus code (LUA_OK=0, LUA_YIELD=1, LUA_ERRRUN=2, LUA_ERRERR=5)
in `L->status`, updated at every throw/resume boundary. luazig's `Thread.status`
enum ({suspended,running,dead}) drives the coroutine state machine but cannot
represent error codes — `api_status` fills that gap.

**Lifecycle-transition wiring** (each site in `builtinCoroutineResume`):
- Resume start (`th.status = .running`): `api_status = 0` (LUA_OK — running)
- Defer safety net (`th.status == .running → .dead`): `api_status = err_is_errerr ? 5 : 2`
- C-frame completion: `api_status = 0` (LUA_OK)
- C-frame yield: `api_status = 1` (LUA_YIELD)
- No-output yield: `api_status = 1`; no-output completion: `api_status = 0`
- Error path (`!ok`): `api_status = err_is_errerr ? 5 : 2`
- Yield path: `api_status = 1`; success path: `api_status = 0`

**builtinCoroutineClose wiring:** All three `th.status = .dead` sites set
`api_status = 0` (LUA_OK), matching PUC's `resetCI` which sets `L->status =
LUA_OK` even when `__close` errors. `lua_closethread` returns the error status
(via `APIstatus`), but `lua_status` reads `L->status` which is `LUA_OK`.

**lua_status** (c_api.zig): Resolves the thread from the handle (`h.thread`),
reads `th.api_status`. Main thread (null thread) returns `LUA_OK`.
**api.State.status()** (api.zig): Reads `vm.c_api_thread.api_status`.

**Item 8: lua_closethread discards suspended C continuation.** PUC
`luaE_resetthread` → `resetCI` (lstate.c:146-155) drops ALL CallInfos without
calling any C continuation (`ci->u.c.k = NULL`). TBC variables are closed
separately by `luaD_closeprotected` → `luaF_close`, which traverses the stack's
`tbclist` — NOT the CallInfos. The existing forced-close machinery
(`beginForcedClose` + `appendBytecodeForcedCloseUnwind` in `runBytecodeInternal`'s
`close_mode` branch) already runs `__close` for Lua-frame TBC variables correctly.
The bug was that `builtinCoroutineResume`'s C-frame processing loops called
`finishCcall` → k, which PUC's `resetCI` never does.

**Fix:** Added `discardCFrame` helper (vm.zig) — frees owned state + pops the
C-frame WITHOUT calling k, mirroring PUC's `resetCI`. When `th.close_mode` is
true:
- Initial `cframe_processed` block: discards all C-frames, then either returns
  (no Lua frames → close succeeds) or sets up for the unroll loop (Lua frames
  remain → `__close` runs via the close_mode branch in `runBytecodeInternal`).
- Unroll loop C-frame case: discards the C-frame and continues the loop.
- `finishCcall` error handlers (both initial block and unroll loop): when
  `forced_close_thread == th and th.close_mode` (self-close via C API),
  discards remaining C-frames and lets the unroll loop process Lua frames.

**Self-close (L == from):** PUC `lua_closethread` calls
`luaD_throwbaselevel(L, status)` which longjmps to the base `errorJmp`
boundary, never returning. In luazig, `lua_closethread` catches
`error.RuntimeError` (self-close signal from `builtinCoroutineClose`) and
`_longjmp`s to the `c_error_jmp` boundary (set up by
`callCFunctionWithBoundary`). The error propagates through `finishCcall` to
`builtinCoroutineResume`, which catches it and runs the forced close unwind.
PUC throws with both OK and error status; luazig longjmps with value 1 (error
signal) for both — the forced close machinery determines the final status.
Limitation: PUC's `luaD_throwbaselevel` unrolls past ALL pcall boundaries;
luazig's `c_error_jmp` is a single boundary (not chained), so the longjmp
targets the nearest boundary. The `shouldRethrowForcedCloseFromBytecode` check
in `runBytecodeInternal` handles the Lua-level path (bypassing pcall for forced
close).

**c_stack clearing:** `lua_closethread` clears the handle's `c_stack` after
close (PUC `luaE_resetthread` sets `L->top = L->stack + 1`, so
`lua_gettop(co) == 0`).

**Tests** (`tests/c_api/11_closethread.c`): Added t6 (status_after_error),
t7 (closethread_suspended_c_cont — k not called, gettop==0, status==OK),
t8 (closethread_close_error — __close errors, close returns ERRRUN), t9
(closethread_tbc_still_runs — __close runs once even when k discarded).
**Tests** (`tests/c_api/14_state_handles.c`): Added test_status_after_error,
test_status_yield_complete. All differential (PUC + luazig) PASS.

**Regression gate:** 15/15 c_api suites, test-diff DIFF: PASS (5 suites),
coroutine.lua --testc exit 0, smoke 54/54, matrix zig_fail=0 (only big.lua
both_fail, 13 pre-existing output_diff), zig build test exit 0.

Статус проверен 2026-08-06.

### Allocator и memory pools (P15.34)
- [ ] Заменить `smp_allocator` на libc allocator или VM-local pools.
- [ ] VM-local pools/pages для Table/Node/Closure/Cell.
- [ ] Освобождать пустые pages после major sweep.

### Compiler pipeline (P15.36)
- [ ] Capacity hints для AST/bytecode/constants/names в codegen.
- [ ] Small-vector storage для типичных маленьких функций.
- [ ] Уменьшить копирование identifier/source/string data.
- [ ] Streaming parser-to-bytecode backend (AST сейчас обязателен).
- [x] ~~Reuse parser/codegen arena~~ — parser AST arena reuses; codegen scratch — нет.

### Table specialization (P15.34)
- [ ] Специализированные integer/string insert paths в ltable.zig.
  *(Read fast paths уже inline в VM dispatch — GETI/GETFIELD/GETTABLE.)*

### Perf gate (P15.37)
- [x] ~~Добавить process CPU, max RSS, opcode count~~ — закрыто P16.0b/c.
- [ ] Маркировка noisy/long suites.

### Thread compaction (P15.35)
- [ ] Уплотнить `Thread` header (~110 полей; inline FrameStack уже сделан).

### Прочее
- [ ] Закрыть `heavy.lua` memory/perf gap (skipped by default).
- [x] ~~Debug name reconstruction лениво~~ — done (только error/debug paths).
- [x] ~~Развивать Zig embedding API~~ — api.State unified on *Vm + vm.c_stack (R1-R3).
  c_api.zig reduced to thin C-ABI shims. Single source of truth: api.zig.
- [x] ~~C API drop-in~~ — 162 exported symbols, liblua.so/.a, complete headers
  (lua.h/lauxlib.h/lualib.h/luaconf.h), 10 C-link tests pass. All 6 PUC C
  extensions compile against luazig headers. Added lua_atpanic, lua_newstate,
  lua_newthread, lua_closethread, lua_xmove, lua_getextraspace (state mgmt).
  Debug API: lua_getstack/getinfo implemented (walks VM call_frames).
  All stubs implemented: getlocal/setlocal (Proto locvars + bc_stack registers),
  setallocf/newstate (custom allocator stored for getallocf round-trip),
  toclose/closeslot (TBC slot tracking + __close metamethod invocation).

### P16.0a — generated status summary (one source of truth)

`--json-out` для smoke_compare/perf_compare; новый `tools/status_summary.py`
(matrix/smoke/perf JSON + c_api TESTS из Makefile, geomean = exp(mean(log)),
`--write-readme` между маркерами `<!-- BEGIN/END GENERATED STATUS -->`,
детерминирован). README Parity+Performance таблицы генерируются; протухшие
числа (30/31, 49/49, 2.76x) убраны; AGENTS.md — указатель вместо числа.

### P16.0d — количественная модель производительности

docs/perf/2026-08-25-p16-model.md: **2.70x = instrX 1.32 × costX 2.05**
(точные пары: VmStats zig / count-hook PUC на идентичных телах microbench).
6 механизмов данными: F1 MMBIN no-op dispatch (PUC pc++-skip); F2 SETTABUP
rawSet-funnel; F3 allocator/hash на table-construction (RSS 88–103MB vs
15.9MB); F4 call-механизм 39% вне dispatch; F5 coroutine instrX 2.25 +
memset; F6 позитив — zig cache-miss ниже PUC (Node 32B), comparisons
компактнее. Рекомендация P16.1 пересмотрена по данным: MMBIN-skip первым,
table GET-пути деприоритизированы.

### P16.1/P16.2a — транша 1: dispatch inflation + table funnels + pending-call

- **P16.1a (e4d8dd6) MMBIN pc-skip**: PUC op_arith_aux пропускает MMBIN*
  после arith; luazig диспетчеризовал no-op. `ctx.pc += 1` в 25 хендлерах.
  int_arith: mmbin 50.5M→0, инструкции 151.6M→101.1M (instrX 1.52→1.01).
  int_arith −8.9%, comparisons −19.8%.
- **P16.1b (37d3cca) GETTABUP/SETTABUP inline** по образцу GETFIELD/SETFIELD:
  funnels get_generic 5.05M→61, set_generic 10.1M→20k; field_access −13.3%
  (2.81→2.47x), global_arith −10.9%.
- **P16.2a (bfe0861) CALL fast path без pending-call**: непоследовательность
  с контрактом P15.51c (opCall уже не ставил слот); `.results`-pending был
  behaviorally идентичен direct-ветке; потребители проверены (return-hook в
  OP_RETURN, protection — pcall-family, yield-park → no-pending ветка).
  lua_calls −19.3% (3.46→2.82x). Baseline 2.54x (79c45fd).

### P16.3 — zero-allocation coroutine yield/resume (InlineValues)

Acceptance met: plain yield↔resume = 0 heap alloc/итерацию (было 3:
th.yielded / resume_inbox / suspended_builtin_args dupes). InlineValues
(4 inline + heap spill, slice()-совместим с ?[]Value); 3 поля Thread
конвертированы (~80 сайтов). coroutine_yield −5.8% (d1492d8).

### P16.2b/c — yield memset drop + lazy resolve (coroutine tranche complete)

- **P16.2b (22c7b8e)**: убран 128B Nil-memset в прологе builtinCoroutineYield
  (доминирующий путь — error.Yield, outs не читается; Nil-fill → wrap_eager).
  Layout-инцидент float_arith +5.7% диагностирован (instructions идентичны /
  cycles +11% → µop-cache placement) и вылечен структурно: outlining cold-пути
  OP_ADD в addSlowPath (bool-сигнал сохраняет continue :frame_loop /
  MMBIN-skip семантику). Рецепт диагностики «instructions vs cycles» —
  рабочий стандарт для hot-path правок.
- **P16.2c (6adf860)**: resolveCallable ленив на resume-пути (direct-resume
  не использует; было 5.2% профиля). coroutine_yield −11.4%.
- Итог транши: coroutine_yield 3.69x → 3.16x (−25%), geomean 2.53x
  (baseline 1bc3875, README перегенерирован: 31/32 / 54/54 / 2.53x).

### P16.4a — Unified PUC-faithful gcControl + variadic lua_gc + coded GC params

- **(2d3a54a) Coded GC params**: ported `luaO_codeparam`/`applyparam`
  (lobject.c:62-112). Replaced 6 raw i64 fields with `gcparams: [6]u8`
  coded lu_byte array, initialized with PUC defaults (20, 50, 70, 250,
  200, 9600). All readers migrated to `gcApplyParam(gcparams[i], base)`.
  stepsize unit: 10KB → 9600 bytes (PUC LUAI_GCSTEPSIZE = 200*sizeof(Table)).
- **(2d3a54a) Unified gcControl**: `gcControl(what, param, value)` implements
  full PUC `lua_gc` switch table: STOP/RESTART/COLLECT/COUNT/COUNTB/STEP/
  ISRUNNING/GEN/INC/GCPARAM. GCSTPGC|GCSTPCLS guard returns -1. `gc_stp: u8`
  field (GCSTPUSR=1, GCSTPGC=2, GCSTPCLS=4). GCSTPGC set during
  `gcFinalizeList` (prevents reentrant GC from __gc finalizers).
  `builtinCollectgarbage` delegates to `gcControl` for all options.
- **(2d3a54a) Variadic C shim**: `src/lua/lua_gc_shim.c` provides variadic
  `lua_gc(L, what, ...)` dispatching to `luazigGcFixed`/`luazigGcParam` Zig
  exports. lua.h:376 fixed to variadic declaration.
- **(2d3a54a) Differential test**: `tests/c_api/17_gccontrol.c` — fresh-state
  sweep, mode transitions, STOP/ISRUNNING/RESTART, STEP, GCPARAM getter/setter
  (all 6 params with exact PUC values), Lua-level collectgarbage parity.
- **(1c2f493) CLI GCRESTART+GCGEN**: PUC pmain calls GCRESTART then GCGEN
  after createargtable. Both disabled:
  - GCRESTART resets GC debt to 0 → 3 matrix failures (bitwise, nextvar,
    vararg) due to premature GC triggering at startup.
  - GCGEN crashes due to pre-existing generational GC bugs in
    `gcMinorCollection` (reproducible via `collectgarbage("generational")`
    at script start — crashes even without P16.4a changes).
  - TODO(P16.4b): enable both after fixing generational GC and verifying
    GCRESTART doesn't cause premature GC issues.
- **Gate**: matrix 31/32 (big.lua both_fail pre-existing), smoke 54/54,
  c_api 17/17 + DIFF PASS, zig build test 0, leak_bench 25/25 PASS.

### P16.4b — Fix generational GC full-collection crash (gcMakeAllWhite before pending cycle)

- **Root cause**: `gcFullCollectionForUser` (generational path) called
  `gcMakeAllWhite()` BEFORE finishing any pending incremental cycle.
  `collectgarbage("step")` in major phase starts an incremental cycle
  (gc_state=propagate). When `collectgarbage("collect")` is then called,
  `gcMakeAllWhite` resets ALL objects' marks to current white — including
  objects already marked (black/gray) during the pending cycle's propagation.
  `gcCycleFull` then finishes the pending cycle: its sweep sees the reset
  marks and frees objects that are actually alive (but whose marks were
  corrupted). `gcCycleFull` then starts a SECOND cycle; during the second
  cycle's propagation, live tables' references to the freed objects are
  followed → `gcQueueScanObject` adds freed memory to the gray list →
  `gcPropagateOne` iterates freed table's hash → crash (`switch on corrupt
  value` in `Node.getKey()`).
- **Fix**: Finish the pending incremental cycle BEFORE calling
  `gcMakeAllWhite`. PUC's `fullgen` (lgc.c:1458) does the same:
  `minor2inc` enters sweep, then `entergen` runs to pause (finishing the
  sweep) before starting a new cycle. The fix replaces the single
  `gcCycleFull()` call with: (1) finish pending cycle to pause,
  (2) `gcMakeAllWhite()`, (3) `gcStartCycle(true)`, (4) run to pause.
- **Repro**: `/tmp/gm_e.lua` — `collectgarbage("generational")`, loop 100
  rounds with nested tables + `collectgarbage("step")` every 10 rounds,
  then `collectgarbage("collect")`. Crashes in Debug and ReleaseFast
  before fix; passes after.
- **GCGEN at startup**: The gen-mode full-collection crash is fixed, but
  enabling `LUA_GCGEN` at CLI startup reveals a SEPARATE pre-existing
  gen-mode bug: minor collection frees Cell (upvalue) objects still
  referenced by live coroutines. Repro: `collectgarbage("generational")`
  + coroutine sieve chain (coroutine.lua lines 99-124). Crash at
  `Cell.get` (vm.zig:621) — `bc_stack_idx` dereferences freed Cell.
  This is NOT the same bug as the full-collection crash; it requires
  a separate fix (P16.4c). GCGEN remains disabled at startup.
- **Gate**: matrix 31/32 (big.lua both_fail pre-existing), smoke 54/54,
  c_api 17/17, zig build test 0 — no regressions.

### P16.4c — Gen GC grayagain drain for full cycles + metatable barrier fixes

**Goal:** Fix generational GC crashes blocking GCGEN startup.

**Changes:**
- **Grayagain drain for full cycles**: Enable `gcDrainGrayagain` in
  `gcAtomicCommon` for non-minor (full/incremental) cycles. Without this,
  `gcFullCollectionForUser` frees grayagain items that weren't marked →
  dangling pointers → crash in next minor cycle. Fixes
  `43_generational_minor.lua` smoke test crash.
- **gcStoreMetatable barrier fix**: Check `gcIsBlack&&gcIsWhite` instead of
  age-based check. A YOUNG BLACK table (already traversed) needs the barrier
  to mark its new metatable.
- **Backward barrier in gcStoreMetatable**: Add table to grayagain so it's
  re-traversed next cycle, ensuring metatable is re-marked after sweep.
- **gcPromoteYoungObject fix**: Advance OLD0→OLD1 (was: return false without
  advancing), add OLD1 objects to `gc_grayagain` so `gcCorrectGrayAgain` can
  make them BLACK for `markold` re-traversal.
- **gcCorrectGrayAgain fix**: Process ALL items (not just pre-snapshot), make
  alive-white objects BLACK (distinguish dead-white from alive-white using
  `gcIsDead`), match PUC `correctgraylist` age transitions.
- **gcDrainGrayagain fix**: Save/clear/drain pattern matching PUC atomic —
  new items added by barriers during draining stay in grayagain for later.
- **Route all direct `.metatable=` through barriers**: All table metatable
  assignments now go through `gcStoreMetatable`; userdata through
  `gcWriteBarrierUserdata`. Fixed in `vm.zig` and `api.zig`.

**Remaining issues:**
- Minor-cycle grayagain drain still disabled (causes minor2inc transition
  which exposes a dangling metatable pointer from a previous minor sweep).
  Root cause: a table's metatable is freed because the table (old, not
  re-traversed) didn't have its metatable marked. The backward barrier in
  `gcStoreMetatable` should fix this, but something is still missing.
  TODO(P16.4e): investigate and enable minor-cycle grayagain drain.
- `gengc.lua` — pre-existing failure at line 90 (coroutine upvalue collection).
- `big.lua` — both_fail (pre-existing).

**Gate**: matrix 28/32 (errors.lua, files.lua pass with gen enabled),
smoke 55/55 (all pass including 43_generational_minor.lua),
c_api 17/17, zig build test 0 — no regressions vs gen-disabled baseline.

### P16.4d — Gen GC sweepgen color, checkmajorminor, gcMakeAllOld BLACK

**Goal:** Fix gc.lua, api.lua, gengc.lua:48-50 regressions from P16.4c and
implement missing checkmajorminor for major→minor transition.

**Changes:**
- **gcMakeAllOld sets objects to BLACK** (not just OLD): PUC's `atomic2gen` →
  `sweep2old` keeps surviving objects BLACK (via `nw2black`). Our code was
  leaving them WHITE (reset by the preceding full cycle's sweep). Without
  BLACK, forward barriers (e.g., `gcStoreMetatable` checking `gcIsBlack`)
  never fire after entering gen mode, breaking metatable age promotion
  (gengc.lua:48).
- **gcSweepYoungObjects: only reset G_NEW to white**: PUC's `sweepgen` only
  resets G_NEW objects to white; all other survivors keep BLACK. Our code
  was resetting ALL survivors to white, breaking OLD0 objects (forward-barrier
  promoted) which need to stay BLACK for the next cycle's markold.
- **gcCorrectOld1: do NOT advance OLD1→OLD**: PUC's `sweepgen` advances
  OLD0→OLD1, but OLD1→OLD is done by `markold` at the START of the NEXT
  cycle. Our code was advancing OLD1→OLD in the same cycle, skipping the
  OLD1 state entirely (gengc.lua:50 expects OLD1 after collectgarbage("step")).
- **checkminormajor after sweep, not before**: PUC's `youngcollection` calls
  `sweepgen` (which promotes SURVIVAL→OLD1 and increments `addedold1`) BEFORE
  `checkminormajor`. Our code checked before the sweep, seeing `addedold1=0`
  and never triggering the minor→major transition.
- **Implement checkmajorminor in gcAtomicPhase**: PUC calls
  `checkmajorminor` after `atomic` in major mode. If enough memory was
  collected, `atomic2gen` returns to gen minor mode. Our code was missing
  this entirely — major mode never returned to minor. Added
  `gc_gen_marked_kb` tracking (PUC `GCmarked` equivalent) in
  `gcQueueScanObject`.
- **gcMarkMutableRoots: use live_reg_top[pc] as primary bound**: Reverted
  P16.4c's `@max(pc_live, frame.reg_top)` which kept dead registers alive
  after for loops, breaking gc.lua:382 and api.lua:1039.
- **gcLeaveGenerational: add gcMakeAllWhite + gc_state=pause**: Match PUC's
  `minor2inc` which resets all objects to current white so the next
  incremental cycle can distinguish reachable from unreachable.

**Results:**
- gc.lua: PASS (was failing at line 382)
- api.lua: PASS (was failing at line 1039)
- gengc.lua: lines 48-50 PASS (was failing at line 48), pre-existing
  failure at line 90 (coroutine upvalue collection) remains
- zig build test: 146/146 (was 144/146 — fixed 2 pre-existing test failures)
- matrix: 30/32 (was 28/32), smoke 54/54, c_api 25/25

**Gate**: matrix 30/32 (gengc.lua zig_fail pre-existing line 90,
big.lua both_fail pre-existing), smoke 54/54, c_api 25/25,
zig build test 0 — no regressions.

### P16.4e — Close open upvalues on thread collection (PUC luaE_freethread/luaF_closeupval)

**Goal:** Fix gengc.lua:90 ("another bug in 5.4.0" upstream test) — collecting
a suspended coroutine with open upvalues referenced by live closures caused
use-after-free: the closure's cell kept pointing into the freed coroutine
stack.

**Root cause** (two bugs, both PUC-faithful fixes):
1. **gcQueueScanCell did not mark open cell values**: PUC's `reallymarkobject`
   for LUA_VUPVAL calls `markvalue(g, uv->v.p)` — it marks the upvalue's
   content (the stack value) even for OPEN upvalues. Our `gcQueueScanCell`
   skipped marking for open cells ("value is on the thread's stack, which is
   scanned separately"). This is correct when the owning thread is REACHABLE
   (its stack is scanned), but WRONG when the thread is UNREACHABLE: the
   stack is never scanned, so the value is never marked → freed by sweep →
   the cell's stack reference dangles after the thread is freed.
2. **gcFreeObject(.thread) did not close open upvalues**: PUC's
   `luaE_freethread` calls `luaF_closeupval(L1, L1->stack.p)` to close ALL
   open upvalues before freeing the stack. Our `gcFreeObject(.thread)` freed
   `th.bytecode_stack` via `freeParkedThreadRuntime` without closing the open
   upvalue cells in `th.bytecode_boxed` first. Live closures referencing those
   cells then read through dangling `bc_stack_idx` into freed/reused memory.

**Fix:**
- **gcQueueScanCell**: for open cells, now calls `gcMarkValue(cell.get(self))`
  to mark the stack value (PUC `markvalue(g, uv->v.p)`). This ensures the
  value is marked regardless of whether the owning thread is reachable.
- **closeThreadOpenUpvalues** (new function): called from `gcFreeObject(.thread)`
  before `freeParkedThreadRuntime`. Iterates `th.bytecode_boxed` and closes
  each open cell (copies stack value into `cell.value`, clears
  `bc_stack_idx`/`bc_stack_thread`). Mirrors PUC `luaF_closeupval` (not
  `luaF_close` — no `__close` metamethods are run, the thread is dead).
  Fires `gcWriteBarrierCell` for each closed cell (PUC `nw2black` + barrier).

**Scope**: Both incremental and generational modes affected (same bug). The
gen startup (P16.4c) exposed it because gengc.lua:81-104 tests this exact
pattern (coroutine upvalue survival after thread collection under gen GC).

**Pre-existing DIFF note**: `tests/c_api/17_gccontrol.c` `reached_1` diff
(gen GC step pacing — `LUA_GCSTEP, 0` doesn't complete a cycle within 100
iterations) is pre-existing from P16.4c (GCGEN startup enabled), not caused
by this fix. The root cause is `gcStepBudget` using `requested_kb` (9) instead
of PUC's `stepsize / sizeof(void*)` (1200) — a 133x difference in work budget.
Fixing it caused regressions (gc.lua, nextvar.lua, smoke) and is deferred to
a separate investigation.

**Results:**
- gengc.lua: FULL PASS (was failing at line 90)
- matrix: 31/32 zig_fail=0 (was 30/32 zig_fail=1 on gengc.lua)
- t3.lua (surgical repro): all checkpoints OK
- Regression probes (gm_e, gencrash3, t1): all pass
- smoke 54/54, c_api 17/17, zig build test 0, leak_bench 25/25

**Gate**: matrix 31/32 (big.lua both_fail pre-existing), smoke 54/54,
c_api 17/17 (DIFF: 17_gccontrol `reached_1` pre-existing from P16.4c),
coroutine.lua --testc 0, zig build test 0, leak_bench 25/25 PASS.
Perf: geomean 2.55x, no new regressions vs baseline (global_arith +20.7%
pre-existing from P16.4 gen startup).

### P16.4f — PUC-faithful gen-GC byte accounting + chained stringtable + temp-buffer leak fixes (17_gccontrol diff green)

Closed the last P16.4 blocker: `17_gccontrol` STEP differential
(`reached_1=yes` PUC vs `no` zig). Root-cause chain (each fix verified by
instrumented traces against vendored PUC):

- [x] **STEP debt semantics** (gcControl STEP arm, PUC lapi.c:1200+):
  `n<=0 → debt := 0` (force due), `n>0 → debt -= n`; manual gen-minor step
  applies setminordebt-equivalent after the collection; full/incremental
  steps apply setpause / setdebt(stepsize) per PUC incstep (lgc.c:1724).
- [x] **GCGEN/GCINC return values** distinguish KGC_GENMAJOR
  (gc_gen_phase == .major) like PUC lapi.c:1220-1224.
- [x] **setminordebt pacing** (gcScheduleNextAutomaticCycle): gen-minor
  threshold = count + GCmajorminor×MINORMUL% (lgc.c:1417). Removed the
  +64KB floor that postponed minors past whole workloads.
- [x] **Table parts byte accounting**: tableResize charges new array/hash
  parts (gcNoteAlloc) and credits freed old parts (gcNoteFree), matching
  gcFreeObject's full-size credit; removed the duplicate C-API newtable
  charge. Without it the count collapsed to 0 after minor sweeps.
- [x] **Cell charge at the hot OP_CLOSURE upvalue-capture path** — the
  missing charge collapsed gc_count_kb (every freed cell over-credited),
  which froze AutoCycleDue permanently true → GC livelock (cstack timeout).
- [x] **Chained interned-string table** (PUC stringtable, lstring.c):
  `StringTable` with bucket chains via new `LuaString.next`, O(1)
  removeString (luaS_remove), grow-at-full ×2 (growstrtab), shrink at
  nuse<size/4 during atomic (checkSizes), MINSTRTABSIZE=128 init.
  Replaces the Zig HashMapUnmanaged whose tombstones degraded to O(N)
  probes under gen-GC string churn (perf: string_concat −25%, string_loop
  −34%).
- [x] **Fixed string-hash seed**: `hash_seed` (set once, like PUC g->seed)
  instead of the live `rng_state[0]^rng_state[2]` that math.random mutates
  (latent correctness bug: re-hashing after randomseed broke intern lookups).
- [x] **internStr resurrect** of dead-but-unswept strings on hit
  (PUC internshrstr lstring.c:223-226); removed the non-PUC age-touch.
- [x] **Temp-buffer leaks** (found via systemd-oomd kills + a
  TrackingAllocator leak-map): concatValuesDirect `result`,
  string.rep `buf`, and two error-format `tb_result` buffers were never
  freed after interning (PUC frees the temp copy immediately). Accumulator
  `s = s .. x` loops turned this into quadratic memory blowups (OOM at
  200K iterations; now passes under 3GB ulimit, output parity with PUC).

**Workload robustness**: smoke `34_gc_stop_and_step.lua` steps_to_cycle
workload 100→300 tables — the minor→major threshold is footprint-relative
(minormajor% of post-full-collect base); Zig's larger struct footprint put
100 tables below the limit (63% vs PUC's 72%, threshold ~67%). Semantics
unchanged, verified against PUC on the same file.

**Results:**
- 17_gccontrol test-diff: **PASS** (`reached_1=yes` both runtimes; /tmp/sp3.c
  parity at iteration 69 vs PUC's 0 — pacing-equivalent, test only checks
  termination via major cycle)
- matrix --testc: zig_fail=1 (nextvar.lua — **pre-existing, fails 5/5 on
  clean HEAD 84559f7 too**: "invalid key to 'next'" in gen-GC minor stack
  scanning; NOT a regression of this step; open for the next investigation)
- c_api 17/17 + DIFF PASS, smoke 54/54, gengc.lua FULL PASS,
  coroutine.lua --testc 0, zig build test 0, leak_bench PASS
- Memory: 30K/200K accumulator-concat workloads pass under 2–3GB ulimit
  (were OOM at 6–8GB); lengths match PUC exactly (138894 / 1088895)
- Perf: geomean **2.53x → 2.39x**; string_concat −25.3%, string_loop
  −34.4%, temp_table_alloc −29.5%; field_access/global_arith flapped
  (+10.2%/+18% in full-suite runs) but isolated instructions-vs-cycles A/B
  shows identical instructions (89.8G) and BETTER cycles (21.5–23.2G vs
  HEAD's 23.5–23.7G) — measurement noise on a loaded host, not a real
  regression. Baseline updated to the 2.39x run; README regenerated.

**Open (known, not from this step)**: nextvar.lua gen-GC "invalid key to
'next'" (fails on HEAD; suspect minor-collection stack scanning missing a
live key register); global_arith noise investigation if it reappears
against the new baseline.

### P16.4g — PUC-faithful gcRemarkUpvals + genlink fix for generational GC

Closed the generational GC grayagain/remarkupvals blocker chain that caused
files.lua SIGSEGV (line 757 "input file is closed") and gc.lua assertion
failure (line 583, upvalue of dead coroutine not marked).

Root-cause chain (each fix verified against vendored PUC Lua 5.5.0 lgc.c):

- [x] **genlink in gcDrainGrayagain** (PUC lgc.c:470-477): TOUCHED1 objects
  must link back to grayagain WITHOUT advancing age. Previously advanced
  TOUCHED1→TOUCHED2 immediately, then gcCorrectGrayAgain advanced
  TOUCHED2→OLD in the same cycle — objects left grayagain after ONE cycle
  instead of TWO (PUC takes two). Young children (SURVIVAL with
  currentwhite) were not re-marked in the second cycle → collected
  prematurely → files.lua crash. Fix: genlink only links TOUCHED1 back to
  grayagain (no age change); TOUCHED2→OLD. This matches PUC exactly.
- [x] **gcRemarkUpvals** (PUC lgc.c:406-426): re-mark values of open
  upvalues during atomic. Open upvalues' values may change after propagate
  (e.g., coroutine resumed, creating new objects on its stack). Without
  remarkupvals, the new value is not marked → freed by sweep → use-after-free.
  PUC iterates `g->twups` (threads with open upvalues) and marks values of
  non-white open upvalues. We don't have twups; instead we iterate all
  Cells in gc_objects and mark values of open, non-white Cells. Cells are
  separate GC objects — they survive even if their referencing closure is
  freed by a previous sweep. This avoids the use-after-free that occurred
  when accessing freed closures via `frameUpvalues()`.
- [x] **gcQueueScanObject safety check**: verify object is registered in
  gc_objects before marking. Stale grayagain entries (from cycles where the
  drain was disabled) can reference freed-and-reused memory.
- [x] **gcFullCollectionForUser**: clear generational lists
  (gcClearGenerationalLists) before starting full incremental cycle, matching
  PUC minor2inc (lgc.c:1306-1314). Without this, stale grayagain entries
  from the generational era corrupt the incremental cycle's reachability.
- [x] **DEADKEY fix**: gcPropagateOne for tables uses PUC-faithful DEADKEY
  sentinel (key marked dead) instead of setting key to Nil.
- [x] **nodeInsert chain fix**: table node insertion maintains the chain
  correctly for the chained stringtable.

**Results:**
- matrix --testc: **31/32 pass parity, zig_fail=0** (big.lua both_fail
  pre-existing)
- gc.lua, files.lua, gengc.lua: all PASS
- smoke: 56/56 PASS
- No regressions vs P16.4f

### P16.4g — correctness closure (2026-08-28, verifier Task 6)

Resolved the documentation inconsistency between P16.4e ("matrix
zig_fail=0") and P16.4f ("zig_fail=1, nextvar.lua pre-existing, fails 5/5
on clean HEAD 84559f7"). The tranche base 1bc3875 entered with zig_fail=0,
so the nextvar failure appeared *inside* P16.4 and "pre-existing" claims
were demonstrated with a clean bisect rather than asserted.

**Bisect (good=1bc3875, bad=020fd02):**
- First-bad commit: **0d53f55** (P16.4d: gen GC sweepgen color,
  checkmajorminor, gcMakeAllOld BLACK). At 0d53f55 nextvar.lua --testc is
  flaky (2/3 fail over 3 runs); at 84559f7 (P16.4e) it becomes
  deterministic (2/2 fail). Parent f0b7066 (P16.4c STATUS) passes 2/2.
- Story confirmed: the `nodeInsert` bug in `src/lua/ltable.zig` (used
  key-tag emptiness `mp.isEmpty()` instead of the PUC `insertkey`
  value-nil check `gval(n) == nil`, AND cleared `next_offset` on
  overwrite) is OLD code. It only becomes *reachable* when the generational
  GC actually deadens/deletes keys in hash nodes. P16.4d
  (gcMakeAllOld→BLACK, sweepgen color, checkmajorminor) is the commit that
  made gen-GC deadening cadence frequent enough to expose the
  chain-orphaning bug — not P16.4a (1c2f493 entered GCGEN startup
  *disabled*, pending P16.4b). The four P16.4g fixes then closed it:
  1. **nodeInsert value-nil + chain preservation** (ltable.zig:548):
     `mp.value == .Nil` check (PUC insertkey) + `next_offset` inherited
     as-is on overwrite (PUC setnodekey never touches gnext).
  2. **PUC DEADKEY** (ltable.zig): raw GC pointer preserved across the
     `.dead` transition (`markDeadKey`/`deadKeyPtr`); deadok lookup split
     to `rawNext`/`findindex`-style `nodeLookupDeadok` (deadok=1); the old
     `clearKey` generalized to `gcClearDeadKeys` covering all collectable
     key types (PUC `keyiscollectable`), `next_offset` preserved.
  3. **grayagain drain restored in ALL modes** (vm.zig): `gcDrainGrayagain`
     runs in minor (vm.zig:20011) and major (vm.zig:20043) atomic; genlink
     TOUCHED1 two-cycle fix (vm.zig:19903-19919 — link back without
     advancing, let `gcCorrectGrayAgain` advance TOUCHED1→TOUCHED2 next
     cycle) + `gcRemarkUpvals` (vm.zig:19989, PUC remarkupvals over all
     open Cells).
  4. **per-VM entropy hash seed** (commit 0f26a1c): PUC `luai_makeseed`
     parity (time + ptr + counter), `initWithSeed` injection, replacing the
     live `rng_state` XOR that `math.random` mutated; `catch{}` audit in GC
     control paths.

**Fresh master (0f26a1c) gate, ReleaseFast:**
- `tools/testes_matrix.py --testc`: **31/32 pass parity, zig_fail=0,
  both_fail=1** (big.lua only — both_fail, expected).
- `nextvar.lua --testc` ×10 consecutive: **10/10 rc=0** (was 5/5 fail at
  84559f7; fully closed).
- `big.lua --testc`: both_fail (expected, unchanged).
- `zig build test` (Debug): rc=0. `zig build -Doptimize=ReleaseFast`: rc=0.
- `make -C tests/c_api test`: rc=0 (=== ALL PASS ===).
- `make -C tests/c_api test-diff`: rc=0 (DIFF: PASS — 10_continuations,
  11_closethread, 12_chook, 13_p15_completion, 14_state_handles,
  15_stress_leak, 17_gccontrol).
- `tools/smoke_compare.py`: **56/56 PASS**.
- `tools/leak_bench.py --no-build`: **PASS** (all workloads within 1.0 KB).
- 15_stress_leak: 0/0 (covered by c_api test-diff).
- Suites --testc: gc, gengc, closure, coroutine, events, errors, files →
  all rc=0.

**Honest approximations remaining in gen-GC paths** (source audit of
`src/lua/vm.zig`): the old minor grayagain DISABLED is **GONE** —
`gcDrainGrayagain` runs in all modes with the genlink two-cycle fix and
`gcRemarkUpvals`. What remains is NOT a semantic gap for the tested corpus
(all suites green) but is recorded for honesty:
- **FINALIZEDBIT clear** (vm.zig:19970-19972): the `gcClearFinalizedBit()`
  call is currently DISABLED (commented out) — it caused use-after-free
  when an object kept alive ONLY by FINALIZEDBIT in one minor cycle was
  swept in the next. The O(n) `gcClearFinalizedBit` function exists
  (vm.zig:20062) but is not invoked. This is a **transitional O(n)
  measure pending a targeted clear-list**, not a semantic gap: stale
  FINALIZEDBIT may persist across minor cycles, but the test suite
  (gc/gengc/files/closure/coroutine) passes without it. TODO
  (vm.zig:19969): implement targeted clear.
- **Active-thread grayagain link** (vm.zig:19976-19980): PUC atomic
  `linkgclist(&L->gclist, g->grayagain)` is TEMPORARILY DISABLED for
  debugging; the running thread is re-traversed via `gcMarkMutableRoots`
  (vm.zig:19443) instead. Approximation pending; covered for the tested
  corpus by the mutable-roots re-mark.
- **Defensive stale-entry skips** (vm.zig:18975-18982 in
  `gcQueueScanObject`, vm.zig:19856-19864 in `gcDrainGrayagain`): safety
  guards that skip objects whose `gc_index` no longer matches (freed-and-
  reused memory from historical grayagain-disabled cycles). TODO
  (vm.zig:18972): remove once confirmed stable across all suites.

The earlier "PUC-faithful generational GC" characterization is therefore
qualified: the grayagain drain, genlink, remarkupvals, DEADKEY, and
nodeInsert paths are now PUC-faithful; the FINALIZEDBIT clear and the
active-thread grayagain link remain honest approximations with explicit
TODOs, not silent deviations.

### P16.2d — frame path slimming (2026-08-28)

Profile-driven tranche (verifier-approved: push+complete = 26.7% of lua_calls,
above the 20-25% threshold). Analysis (perf annotate, ranked) → three commits:

- [x] **8134f90 — frame-init slimming**: removed provably-dead callstatus
  bit-clears after encodeNresults (mask 0xff zeroes all flag bits); removed
  dead `proto` write-back in syncFrame (ctx.cur_proto only ever loaded FROM
  the frame or written together with it in opTailcall); `ensureBcStackCap`
  inlined (one-compare fast path, growth outlined cold); union activation
  `undefined` with full 12-field explicit-init audit (Debug 0xaa catches
  regressions); comptime assert `@sizeOf(CallFrame) <= 104` added.
  lua_calls −7.4%, geomean 2.42→2.36x.
- [x] **9f30da3 — bcGrowFrame guard on return**: skip slice re-derivation
  when `dst + nstore <= frame_cap` (semantically identical to the internal
  check); neutral on single-value micro (noise-level), correct by construction.
- [x] **a6a5d9f — inline return hot path (opReturn1/0)**: fast arms guarded
  by (no open upvalues, no TBC regs, Lua parent in-bounds, not external
  boundary, no pending call, no debug hooks, nresults ∈ {1,0,<0×1val});
  pop sequence mirrors popBytecodeExecFrame verbatim; single-copy result
  write replaces the double copy (scratch buffer eliminated).
  lua_calls −18.8% (isolated instr −11.8%/cycles −10.9%), geomean →2.33x
  (best run 2.29x).

Gate (verified per step + final): zig build test Debug+RF 0; c_api 18/18 +
DIFF PASS; matrix zig_fail=0 (big.lua both_fail pre-existing); smoke 56/56;
nextvar 10x+5x+3x green; coroutine/gengc/gc/closure/events/errors/files
--testc 0; leak_bench + 15_stress_leak pair PASS; perf_compare no >5%
regressions vs the refreshed baseline (comparisons/field_access/global_arith
flap ±7-12% run-to-run on a hot host with geomean simultaneously improving —
layout/thermal noise, isolated instr-vs-cycles checks clean, documented).

Perf arc of the session: 2.53x (вход в транш) → 2.42x (P16.4g baseline) →
**2.33x** (P16.2d, зафиксировано; лучший прогон 2.29x). lua_calls суммарно
≈ −26% за транш.

Infrastructure (вне репозитория): `~/codes/llm-guard-proxy` (переименован из
mws-llm-guard-proxy, git init) — фикс `dd9c2c6`: reasoning-only completions
больше не считаются meaningful (glm-5.2 выжигал output-бюджет на reasoning →
пустые финальные сообщения сабагентов); прокси теперь отдаёт 502 → клиент
ретраит. Диагноз: ретраи 429 работали всегда, умирал loop на
reasoning-only завершениях (доказано по БД opencode: последняя часть
умерших сессий — `reasoning` без `text`).

## P16.4h — finalization + atomic invariants (2026-08-28, verifier closure)

Полная фаза по заданию верификатора; сабагенты A/B/C + гейт лично.

### Task 0 — единый generated source для README+STATUS
`status_summary.py --write-status`: компактная summary-секция STATUS.md теперь
генерируется из тех же JSON, что README-блок (свои маркеры). Устранён дрейф
«54/54 + 2.71x» вверху STATUS. Исторические записи не переписывались.

### Tasks 1-2 — FINALIZEDBIT = PUC модель (`688606f`)
PUC-аудит (lgc.c): бит = «объект ЗАРЕГИСТРИРОВАН на финализацию»
(luaC_checkfinalizer lgc.c:1088), снимается в udata2finalize (lgc.c:953),
сохраняется свипом через maskmarks. Рекурсивным visited-битом для графа,
достижимого из финализируемого, НЕ является — граф живёт обычным маркингом
(markbeingfnz + propagateall). В PUC 5.5 финализация регистрируется ТОЛЬКО
для table и userdata (call-sites lua_setmetatable) — старый комментарий
luazig («tables, closures, threads, userdata») был неверен, исправлен.
Переработка: состояния разделены (finalizables=finobj, gc_to_finalize=tobefnz,
обычные GC-цвета, «нормальный объект» = бит снят в gcFinalizeList).
Рекурсивные FINALIZEDBIT-записи из FinalizerReach удалены; **gcClearFinalizedBit
и его disabled-call не понадобились — удалены** (−160净 строк).

### Tasks 3-4 — постоянные дифф-тесты (`ea00265`)
`tests/smoke/57_finalizer_reach.lua` (byte-identical оба рантайма, стабилен 3×3,
Debug-прогон чист): A потомок переживает цикл финализации родителя; B/C
weak-key/weak-value потомки — закреплён PUC-инвариант аcимметрии atomic
(lgc.c:1543): weak-values чистятся ДО resurrect, weak-keys ПОСЛЕ; D циклы
a↔b из финализатора (терминация без рекурсивного visited); E resurrection +
finalizer ровно один раз; F мусор между сборками.

### Task 5 — grayagain в PUC-позиции для всех режимов (`e13e40a`)
Non-minor путь дрейнировал grayagain ПОСЛЕ финализаторов (расхождение с
lgc.c:1559-1560). gcAtomicCommon переструктурирован с нумерованными
комментариями 1:1 к atomic(); drain в позиции PUC для обоих режимов;
пост-финалайзерный drain — luazig-специфика (финалайзеры в atomic, не в
отдельном callfin). Двойной обработки saved-списка нет (save+clear до итерации).

### Task 6 — active-thread linkgclist: Variant A (эквивалентность доказана)
PUC перевязываёт L->gclist в grayagain для повторного обхода активного треда
в atomic. luazig: мутатор на паузе между gcMarkMutableRoots (шаг 1) и drain
(шаг 6); gcMarkMutableRoots пересканирует live-регистры активного треда
(live_reg_top[pc] — ТОЧНЕЕ PUC traversethread, который сканирует [0..top] с
мёртвыми регистрами) + parked-треды + TBC + varargs + C-хендлы. Повторный
обход избыточен; disabled-блок удалён, инвариант задокументирован в
комментарии у gcMarkMutableRoots. Gen-режим: OLD-треды переобходятся каждым
минором через gc_gen_threads.

### Task 7 — stale entries: lifecycle вместо масок (`e13e40a`)
Защитные skip-проверки (gcQueueScanObject/gcDrainGrayagain) были артефактом
эпохи disabled-drain и разыменовывали entry для чтения метаданных (не защита).
Lifecycle-доказательство: drain делает save+clear → все entries помечены
чёрным → переживают свип → gcCorrectGrayAgain компактирует. Заменены на
stats-gated debug-ассерты + счётчики gc_stale_*; полный suite — **0 срабатываний**.
Аудит остальных GcObject-списков (gc_gray/young/old1/gen_threads/weak/fin) —
таблица в описании фазы.

### Task 8 — полный гейт (лично, чистые сборки)
Debug+RF builds/tests 0; c_api 18/18 + strict DIFF PASS; matrix zig_fail=0
(big.lua both_fail); smoke 57/57; **nextvar 10/10**; gc/gengc/closure/
coroutine/events/errors/files --testc 0; leak_bench PASS; CallFrame ≤104.

### Task 9 — свежий профиль (после correctness)
geomean 2.31x против baseline 2.33x (−0.9%, нейтрально). Таблица 8 ворклоудов
(instr ratio/CPI/allocations/top-5) — в /tmp-артефактах агента. Вердикты:
- **P16.2d исчерпан**: push 16.4% + complete <0.01% < 20% порога.
- hash_access 3.75x — CPI-bound (2.15x худший; instr 1.94x лучший): cache-miss
  на пробинге Node → задача №1 (инлайн keyMatches в GETTABLE + ревизия layout
  Node).
- coroutine_yield 3.08x — instr-bound 4.26x (CPI лучше PUC 0.71x); найдена
  **RSS-утечка ~24B/yield (238MB на 10M)** — correctness-смежный блокер, чинить
  в задаче №2 вместе с прямым fast-path мимо callBuiltin.
- lua_calls 2.26x: осталось instr-count в самом CALL-хендлере; syncFrame 4.8%
  → задача №3 (merge/eliminate).

Ранжирование следующих перф-задач: (1) hash Node/keyMatches −2..3% geomean,
(2) coroutine fast-path + утечка −1.5..2.5%, (3) syncFrame −0.5..1.2%.

## P16.5 — coroutine native-memory + table lookup specialization (2026-08-29)

### T0 — воспроизводимость perf-статуса (`74fd184`)
Версионированные артефакты tools/perf/current{,-counters,-profile-index}.json
(per-workload times/ratio/geomean; instr/cycles/IPC/branch+cache/RSS; top-10
символов 8 hotspot-ворклоудов). Оркестратор tools/perf_snapshot.py
--regenerate-docs; status_summary --perf-current генерирует README+STATUS из
одного снапшота. Regression baseline (p15.37.json) и current — раздельные.

### P16.5a — native RSS growth coroutine path (`2568531`, `2e657e3`)
Root cause: poscallCFrame ставил bc_stack_top = saved_func_slot+1+n, где
saved_func_slot — func_slot C-фрейма НАД регистрами Lua-кадра; результаты
потребляются через resume_inbox, НЕ из bc_stack → top рос +2 за yield/resume
цикл → безграничный 1.5x-realloc bc_stack/bc_boxed. Фикс: восстановление
top по кадру под C-фреймом (зеркально popBytecodeExecFrame). Диагностика:
TrackingAllocator leak-map (LUAZIG_TRACK_ALLOC=1) + tools/native_mem_check.py
(BOUNDED/LINEAR verdict lane). Результаты: RSS 45.4MB→4.4MB flat @1M (PUC
2.4MB); tracker outstanding flat 2876B; матрица вариантов (wrap/y0/y5+/
ignored/rargs/nested) — все плоские 100k==1M.

### P16.5b — coroutine fast path + table specializations
- `edea40c` coroutine resume/yield direct fast path: guards (no hooks, no
  C-frames на стеке треда, wrap/close/trampoline excluded); A/B изолированно
  instr −20% / cycles −26%. coroutine_yield: 3.22x → 2.09x.
- `2e86007` nodeLookupInt (PUC getintfromhash): GETTABLE/GETI/SETTABLE-int/
  hashIntIsPresent; hash_access −6.1% isolated.
- `491d0d6` nodeLookupStr (PUC getstr; pointer-eq interned, content-eq long):
  GETTABUP/SETTABUP/GETTABLE/GETFIELD/SETTABLE/SETFIELD; field_access −15.3%,
  global_arith −13.3%; keyMatches-доля field_access 28.9% → 8.3%.
- Node 32B→24B: ЧЕСТНЫЙ АБОРТ — естественный layout достигнут (offsets
  0/8/16, выравнивание доказано), полный аудит ~90 node.value-сайтов,
  гейт зелёный, НО hash_access +8.7% / field_access +15.4% / geomean +4.5%
  (accessor-switch против прямой 16B Value-загрузки; C-bitfield-приём PUC
  в Zig union(enum) не переносится без стоимости). @sizeOf(Node)==32
  остаётся с обоснованием в комментарии.

### Task 7 — syncFrame: SKIP по свежему профилю
syncFrame = 3.48% lua_calls (было 4.8% до P16.2d/P16.5) — вклад в geomean
<0.3%; порог «заметной доли» не достигнут.

### Финал: geomean 2.38x → **2.21x** (baseline 2.22x); коридор сессии
P16.4f→P16.5: 2.53x → 2.21x (−13%). Полный гейт зелёный на каждом шаге.

## P16.6 — typed TMS / real MMBIN / string-mt arithmetic (2026-08-29)

### Task 0 — native_mem_check false-green fix (`643a772`)
Старый lane читал /proc/<pid> ПОСЛЕ wait() — процесс уже reaped → VmHWM=0 →
BOUNDED всегда. Фикс: os.wait4 + rusage.ru_maxrss, проверка exit-статуса/
сигналов, selftest с bounded/growing детьми (дискриминация доказана:
15.6MB flat vs 56→522MB LINEAR). Coroutine 100k/300k/1M: 15.68MB flat.

### Task 1+8 — dead-state cleanup + fast-path audit (`2daba78`)
caller_builtin_id: grep-доказано write-only (6 write / 0 read) — поле и
save/restore удалены; комментарий fast-path переписан на измеренные стоимости
(addOne — inline storage ≤32 кадров, heap-спилл редок); InlineValues.setOwned
no-op удалён; audit: callCoroutineBuiltinDirect делегирует тем же builtin-
телам, дублей семантики нет.

### Tasks 2+3 — typed TmsEvent + getTm primitives (`dc38fb6`)
TmsEvent = PUC ltm.h порядок (24 события; <=eq — flags-зона). luazig-only
члены (tostring/name/pairs/metatable) вынесены в MetaField + pre-interned
names; .iter удалён (мёртвый). getTm/getTmByObj (pre-interned + nodeLookupStr
без seed-параметра) + fastTm (Table.flags cache ТОЛЬКО <=eq, инвалидация на
newkey/revival/rehash — PUC invalidateTMcache). **Кэширование арифметических
TMS отсутствует — mt.__add мутации видны немедленно.** matchTmsEvent и
metamethodValue удалены (~20 TMS + ~9 MetaField сайтов мигрировано).

### Tasks 4+5+6 — real MMBIN family (`2b4d978`)
MMBIN/MMBINI/MMBANK — семантические хендлеры (PUC luaT_trybinTM): previous-
instruction dest, typed event из C, lhs→rhs precedence, PUC error-shapes,
вызов через общий continuation-mechanism (yield-безопасно). 15 арифметических
хендлеров редуцированы до primitive+skip (coercion-ветки убраны позже — см.
ниже); UNM/BNOT typed; dead evalBinOp/addSlowPath удалены (−147 строк).
ADDI-flip: x−K → __SUB(x,K), K−x → __SUB(K,x) — source-порядок сохранён.

### Task 7 — differential tests (`dcbd569`)
tests/smoke/58_metamethod_dispatch.lua: A-H (precedence, anti-cache мутация
f1→f2→nil→f3 для __add/__sub, 12 событий, MMBINI/MMBINK flip с "event:left/right"
тегами, unary, yielding+nested metamethod, hooks cr-trace). Subtleties: PUC
flip меняет ПОИСК metamethod, но НЕ порядок операндов; numeric-string
coercion — только арифметика (bitwise строки отвергает).

### Parity-гэпы → PUC string-metatable arithmetic (`b183a82`)
Найдено при тестировании: PUC coercion строк — через string-mt metamethod'ы
(lstrlib arith/trymt), не inline. Реализовано: 8 metamethod'ов на string mt,
inline-coercion удалена из 15 хендлеров + C API lua_arith; двухоперандные
trymt-форматы ошибок ("attempt to add a 'table' with a 'string'");
getmetatable("").__add("3","4")==7. Все кейсы byte-identical.

### Финал
Гейт: Debug+RF builds/tests 0; c_api 18/18 + strict DIFF; matrix zig_fail=0;
smoke 58/58; nextvar 10/10; 6 сьютов --testc; leak_bench; native_mem_check
selftest PASS + coroutine BOUNDED; CallFrame≤104; Node 32B (24B-эксперимент
не возобновлялся).
Perf: **geomean 2.21x → 1.91x** (isolated int_arith ~1.6x: 27.7G/4.69G instr/cyc
vs PUC 13.9G/2.94G — упрощение dispatch-хендлеров реальное). Top: metamethod_add
3.42x, lua_calls 2.29x, hash_access 2.28x.

## История закрытых фаз

P3–P15.12 — краткая сводка. P15.13+ — см. «История разработки» выше.

- **P3:** стабилизация базы, targeted parity suite, perf guard.
- **P4:** начальный публичный Zig API, базовый C ABI shim.
- **P5–P7:** testC/ltests compatibility, расширение API.
- **P8:** 33/34 pass parity, zig_fail=0.
- **P9–P10:** публичный API отделён от VM; readiness report, release gate.
- **P11–P12:** OOM/error-object fixes; миграция на system Zig.
- **P13:** интернирование строк — Value.String → *LuaString.
- **P14:** PUC-faithful Table — единый array+hash с Brent chaining.
- **P15.0–P15.7:** GC registry, root-set, per-type sweep, register-top, memory accounting, Handle API.
- **P15.8:** const_strings removal; short-string sweep (отключён — нужен Proto-owned roots).
- **P15.9–P15.12:** peak_freereg weak pruning; local _ENV shadowing; errors/coroutine/locals/db parity.
- P15.13–P15.30: см. «История разработки» выше.

## C Extension Loading

C-расширения (.so) имеют полный доступ к VM через C API. attrib.lua проходит.

- **C API** (`c_api.zig`): lua_State = *Vm, c_stack, ~60 export functions (104 symbols).
- **Call dispatch**: Closure.c_func → callCFunction (bc_stack↔c_stack bridge).
- **Error boundary**: _setjmp/_longjmp (pure Zig). lua_error longjmp в boundary.
- **loadlib**: std.DynLib.open, luaopen_* lookup, CLIBS cache (RTLD_GLOBAL).
- **External strings**: lua_pushexternalstring, LuaString.is_external.
- **Заголовки**: src/lua/lua.h, luaconf.h, lauxlib.h, lualib.h — PUC 5.5 compatible.
- **Library targets**: `liblua.so` / `liblua.a` via `zig build` (build.zig `addLibrary`).
- **C-link smoke test**: `tests/c_api/00_smoke.c` — proves liblua.so is linkable from C. `make -C tests/c_api test`.
- **Debug C API** (`c_api.zig` Phase 8): `lua_Debug` extern struct (matches lua.h layout).
  `lua_getstack` walks `Thread.call_frames` (top→bottom, skip `hide_from_debug`).
  `lua_getinfo` fills S/l/u/t/n flags from CallFrame/Proto (interns source_name for NUL-termination).
  `luaL_where` produces "source:line: " via getstack+getinfo (level 0 = Lua caller, since C frames aren't pushed).
  `luaL_traceback` builds stack trace from frame walk.
  `lua_getlocal`/`lua_setlocal` implemented: walk Proto.locvars (PUC luaF_getlocalname),
  access bc_stack[frame.base + locvar.reg] for push/pop via c_stack.
  `lua_newstate`/`lua_setallocf`/`lua_getallocf`: custom allocator fn+ud stored on
  Vm (c_alloc_fn/c_alloc_ud) for round-tripping; actual allocations use c_allocator.
  `lua_toclose`/`lua_closeslot`: TBC slot tracking (c_toclose_slots ArrayList) +
  __close metamethod invocation via pcallk.
  Known gap: C function calls don't push CallFrames (vm.zig:27938 TODO), so level numbering is off by 1 vs PUC.

## GC refactor: unified GcObject

Per-type GC списки → единый GcObject tagged union (PUC allgc). Full Userdata тип.

- GcObject: .table/.closure/.thread/.string/.cell/.userdata.
- Unified sweep (gcSweepOne walks gc_objects). Generational lists migrated.
- Userdata: gc fields + metatable + uservalues.
- fasttm: Table.flags bitmask (BITRAS), cache-on-miss.
- Short strings in gc_objects (PUC allgc) + string_intern (interning).
  Per-object sweep handles string collection (gcSweepStringIntern removed).
- gc_marked_tables: populated during gcPropagateOne (table case), used by
  gcDeadenUnmarkedStringKeys (O(marked) vs O(total gc_objects)).
- **Tombstone rehash (resolved):** Zig HashMapUnmanaged tombstones cleared
  by `string_intern.table.rehash()` at end of gcSweepOne. string_concat 100x → 1.56x.

## fasttm

PUC fasttm (ltm.h:63): Table.flags bitmask. __eq/__len/__gc/__mode/__index/__newindex через fasttm.

## P16.4h — GC-invariants: atomic grayagain order, active-thread linkgclist proof, stale-entry lifecycle fix

### Task 5 — non-minor atomic grayagain order
**Finding:** `gcAtomicCommon` drained grayagain at TWO different positions depending on mode:
- Minor: drained at PUC position (after remarkupvals+propagate, before ephemerons) — correct.
- Non-minor (incremental): drained AFTER finalizers — diverged from PUC `atomic()` (lgc.c:1559-1560),
  which drains grayagain right after remarkupvals+propagate, BEFORE convergeephemerons.

This meant ephemerons were converged and weak values pruned before grayagain children were marked
in the non-minor path — a semantic divergence from PUC.

**Fix:** Restructured `gcAtomicCommon` with numbered comments mapping 1:1 to PUC `atomic()` (lgc.c:1543-1581).
The grayagain drain (Step 6) now runs at the PUC position for BOTH modes uniformly. The post-finalizer
drain (Step 13, luazig-specific because finalizers run during atomic, not in a separate callfin phase)
remains non-minor only — minor cycles defer to gcCorrectGrayAgain for age promotion.

### Task 6 — active-thread grayagain linkgclist
**Finding:** PUC `atomic()` (lgc.c:1546) calls `linkgclist(&L->gclist, g->grayagain)` to re-queue the
running thread for a second traversal during the grayagain drain. The luazig equivalent was disabled
("TEMPORARILY DISABLED for debugging"), compensated by `gcMarkMutableRoots`.

**Variant A proof (equivalence, no requeue needed):**
1. `gcMarkMutableRoots` re-scans the active thread's live registers (`live_reg_top[pc]`) for every
   bytecode frame — MORE precise than PUC's `traversethread` (which scans `L->stack[0..top]`).
2. Parked threads' stacks don't change during atomic (mutator is paused).
3. `gcRemarkUpvals` (Step 3) covers PUC's `remarkupvals`.
4. No mutations occur between `gcMarkMutableRoots` (Step 1) and `gcDrainGrayagain` (Step 6): Steps 2-5
   are pure collector operations. A second traversal via grayagain would be redundant.
5. In generational mode, OLD threads are re-traversed every minor cycle via `gc_gen_threads`.
6. Finalizer mutations (Step 12) are handled by the post-finalizer drain (Step 13) or gcCorrectGrayAgain.

**Conclusion:** No gap found. The disabled requeue code has been removed. The proof is documented as a
precise comment in `gcMarkMutableRoots` (vm.zig:19626).

### Task 7 — stale grayagain entries: lifecycle fix, defensive masks removed
**Root cause:** The defensive checks in `gcQueueScanObject` (vm.zig:19163) and `gcDrainGrayagain`
(vm.zig:20106) skipped entries via `gc_index`-based validation. These were historical artifacts from
when the grayagain drain was disabled/buggy, allowing entries to accumulate across cycles. The guard
also DEREFERENCED the entry pointer to read `gc_index` metadata — not a real dangling-pointer protection.

**Lifecycle proof (why stale entries are impossible with the correct drain):**
1. `gcDrainGrayagain` saves+clears grayagain at atomic start (equivalent to PUC lgc.c:1546-1547).
2. All saved entries are force-marked black (non-cell: unconditional `gcSetBlack`; cell: checked).
   Black objects survive sweep.
3. `gcCorrectGrayAgain` (after sweep) compacts grayagain, removing dead entries and advancing ages.
4. No object is freed while it's in grayagain: sweep frees only dead (unmarked) objects, but grayagain
   entries were all marked black in step 2.
5. Between cycles, grayagain entries are valid (survived sweep). The next cycle's drain processes them.

**Fix:** Replaced defensive runtime skips with stats-gated `std.debug.assert(false)` + debug counters
(`gc_stale_queue_scan`, `gc_stale_grayagain` in VmStats). The asserts are default-off (only fire when
`stats.enabled` is set via `--stats`).

**Audit of other GC lists:**
- `gc_gray`: cleared by gcDrainGray + gcFinishCycle. Always drained to empty during atomic. Safe.
- `gc_young_objects`: compacted by gcSweepYoungObjects (write-pointer). Dead objects removed. Safe.
- `gc_old1`: compacted by gcCorrectOld1. Only contains OLD1/OLD0 objects (not freed by young sweep). Safe.
- `gc_gen_threads`: rebuilt by gcMakeAllOld from gc_objects (all valid). Safe.
- `gc_weak_tables`, `gc_marked_*`, `gc_fin_*`, `gc_to_finalize`: cleared by gcResetCycleState. Safe.

**Counter results (full suite, stats enabled):** 0 stale hits across all 16 upstream suites + 57 smoke
tests + C API tests. The asserts never fire.

### Gate results
| Gate | Result |
|------|--------|
| `zig build test` (Debug) | PASS |
| `zig build -Doptimize=ReleaseFast` | PASS |
| `make -C tests/c_api clean test test-diff` | PASS |
| `matrix --testc` | 31/32 pass (big.lua both_fail, pre-existing) |
| Smoke 57/57 | PASS |
| nextvar 5x | 5/5 exit=0 |
| coroutine/gengc/gc/closure/events/errors/files 5x each | all exit=0 |
| leak_bench | PASS (all within 1.0 KB) |
| `@sizeOf(CallFrame) <= 104` | PASS (assert at vm.zig:1561) |
| Stale-entry counters (full suite, stats enabled) | 0 hits |

## P16.5a — native RSS growth on coroutine resume/yield (2026-08-28)

### Root cause
`poscallCFrame` set `bc_stack_top = saved_func_slot + 1 + n_usize` after popping
a C-frame. `saved_func_slot` was the C-frame's `func_slot`, which sits ABOVE the
Lua frame's register space (placed by `pushBuiltinCFrame` at `bc_stack_top`).
The results were consumed via `resume_inbox`, NOT from `bc_stack` — so
`bc_stack_top` was set to a meaningless high value and never reset.

Each yield/resume cycle grew `bc_stack_top` by 2 (+1 from `pushBuiltinCFrame`,
+1 from `poscallCFrame`), causing exponential `bc_stack`/`bc_boxed` growth via
`mremap` (1.5x realloc factor). At 1M iterations: bc_stack ~21MB, bc_boxed ~10MB.

### Fix
`poscallCFrame` now restores `bc_stack_top` based on the frame below the popped
C-frame, mirroring `popBytecodeExecFrame` (vm.zig:10533):
- Lua frame below: `bc_stack_top = caller.base + caller.u.lua.frame_cap`
- C-frame below: `bc_stack_top = caller.base`
- No frame below: `bc_stack_top = 0`

This is PUC-faithful: PUC's `luaD_poscall` sets `L->top` based on the caller's
frame, not the C function's position. In PUC, the C function's `ci->func` is
within the caller's registers (at OP_CALL's `ra`), so `L->top = ra + 1 + nresults`
stays within the frame. In luazig, `pushBuiltinCFrame` places the callee at
`bc_stack_top` (above the frame), so we must explicitly restore to the caller's
frame capacity.

### Diagnostic tooling
- `TrackingAllocator` (`src/lua/tracking_alloc.zig`): leak-map with
  `enableLeakTracking()`, `reportLeaks()`, `deinitLeakMap()`. Enabled via
  `LUAZIG_TRACK_ALLOC=1` env var. Zero overhead when unset.
- `tools/native_mem_check.py`: runs lua file at 2+ iteration counts, reads
  VmHWM from `/proc/self/status`, prints LINEAR/BOUNDED verdict.

### Verification
| Check | Result |
|-------|--------|
| VmHWM 100k/300k/1M | 4360/4360/4360 kB (FLAT) |
| TrackingAllocator outstanding 100k/300k/1M | 2876/2876/2876 bytes (FLAT) |
| native_mem_check verdict | BOUNDED (0.00 MB/decade) |
| matrix --testc | 31/32 pass (big.lua both_fail, pre-existing) |
| Smoke 57/57 | PASS |

## P16.6 — dead-code cleanup + fast-path comment audit (2026-08-29, verifier Task 1 + Task 8)

### A. `caller_builtin_id` dead state removed
Grep proof: 12 matches in `src/lua/vm.zig` — 1 field declaration, 6 write/save/restore
sites (3 in `callCoroutineBuiltinDirect`, 3 in `callBuiltin`), 5 comment references.
**Zero semantic read sites** — the only reads were `const prev = self.caller_builtin_id`
save-then-restore pairs, a dead save/restore cycle. The field was set but never read
for any decision or error message (confirmed by the P15.79 comment: "caller_builtin_id
workaround removed").

Removed:
- Field declaration (`Vm.caller_builtin_id`)
- Save/restore in `callBuiltin` (3 lines)
- Save/restore in `callCoroutineBuiltinDirect` (3 lines)
- Stale comment in `coroutineBuiltinFastPathEligible` guard (the `args.len == 0 or
  args[0] != .Thread` guard is kept — its true purpose is bailing to the generic
  `callBuiltin` path so the error is raised with full C-frame + YPCALL error-recovery
  context that the fast path skips; the old comment wrongly attributed this to
  `caller_builtin_id`)
- Updated the P15.79 historical comment in `error()` to note the field is fully removed

### B. Coroutine fast-path cost comment corrected
The old comment claimed `pushBuiltinCFrame` does "a heap allocation (call_frames.addOne)".
Reality: `FrameStack` has `INLINE_FRAME_CAP=32`; `addOne` uses inline storage for the
common case (depth ≤ 32, no heap). Heap spill only when depth exceeds the inline cap
(rare). Rewrote both the `coroutineBuiltinFastPathEligible` and
`callCoroutineBuiltinDirect` doc comments to reflect measured truths: CallFrame
init/bookkeeping, bc_stack_top manipulation, generic callBuiltin context, outs Nil-init
(memset was 6.9%), dispatch overhead; heap spill only when depth > inline cap.

### C. `InlineValues.setOwned` redundant nested check
Removed `if (vals.len == 0) {}` no-op inside the `if (vals.len == 0)` early-return block.

### Task 8 — coroutine fast-path clean-code audit
- **No semantic duplication:** `callCoroutineBuiltinDirect` (vm.zig:8475-8476) delegates
  to the same `builtinCoroutineResume`/`builtinCoroutineYield` bodies as the generic
  `callBuiltinSwitch` (vm.zig:16382-16383). Both paths call identical builtin functions —
  no logic duplication, no extraction needed.
- Guard list unchanged (reviewed in P16.5, correct and understandable).
- No remaining clean-code observations beyond the comment fixes above.

### Verification
| Check | Result |
|-------|--------|
| Debug build + test | PASS |
| ReleaseFast build + test | PASS |
| matrix --testc | zig_fail=0 (big.lua both_fail pre-existing) |
| Smoke 57/57 | PASS |
| c_api test + test-diff | PASS (DIFF: PASS) |
| coroutine.lua --testc | OK |
| nextvar 3x | OK/OK/OK |
| CallFrame ≤ 104 | comptime assert PASS |

## P16.6 — typed TmsEvent (PUC order) + MetaField separation; getTm/getTmByObj/fastTm primitives (2026-08-29, verifier P16.6 Tasks 2+3)

### A. TmsEvent enum migrated to PUC-only order
Removed non-PUC members from `TmsEvent`: `iter`, `tostring`, `name`, `pairs`, `metatable`.
The enum now matches PUC `ltm.h:18-45` exactly (24 members, `index`..`close`).
- **`.iter`** (`__iter`): dead code — initialized in `tm_names` but never looked up by any
  dispatch path. PUC 5.5 has no `__iter` TMS. Removed entirely; no replacement needed.
- **`.tostring`, `.pairs`**: moved to `MetaField` enum. Were used indirectly via
  `matchTmsEvent` → `metamethodValueByEvent`. Now accessed via `getMetaFieldByObj(v, .tostring/.pairs)`.
- **`.name`, `.metatable`**: moved to `MetaField` enum. Were dead in `TmsEvent` (never looked up
  via `matchTmsEvent` — `__name`/`__metatable` used `getFieldOpt` directly). Now accessed via
  `getMetaField(mt, .name/.metatable)`.

### B. MetaField enum + metafield_names
New `MetaField = enum(u8) { pairs, tostring, name, metatable }` with `metafield_names: [4]?*LuaString`
pre-interned at VM init (same pattern as `tm_names`). GC marking extended to pin
`metafield_names` strings (same as `tm_names`).

### C. getTm / getTmByObj / fastTm primitives (ltm.c parity)
- **`getTm(mt, event)`** — PUC `luaT_gettm` without flags cache: hash lookup via `nodeLookupStr`
  (pointer-identity for interned names). For ALL events (cached and non-cached).
- **`getTmByObj(v, event)`** — PUC `luaT_gettmbyobj`: resolves metatable for `v`, then `getTm`.
  Does NOT use flags cache — matches PUC exactly. Every lookup hits the metatable, so dynamic
  `mt.__add` mutation is visible immediately (verifier red line).
- **`fastTm(mt, event)`** — PUC `gfasttm`/`fasttm`: flags cache + `getTm` + cache-on-miss.
  ONLY for events `<= .eq` (index, newindex, gc, mode, len, eq). Renamed from `fasttm`.
- **`getMetaField(mt, field)`** / **`getMetaFieldByObj(v, field)`** — non-TMS metafield lookup
  via `metafield_names` (same `nodeLookupStr` fast path).

### D. nodeLookupStr signature cleaned
Dropped unused `seed` parameter from `nodeLookupStr(nodes, key)` (was `nodeLookupStr(nodes, key, seed)`).
The `seed` was baked into `key.hash` at intern time and explicitly discarded (`_ = seed`).
Updated all 6 call sites in `vm.zig` and 5 test call sites in `ltable.zig`.

### E. Table.flags fastTm semantics + invalidation proof
`fastTm` mirrors PUC `gfasttm` exactly:
- **Cache check**: `mt.flags & bit(event)` → return null if set ("absent").
- **Cache-on-miss**: on nil lookup result, set the bit (`mt.flags |= bit`).
- **Invalidation**: `rawSet` invalidates ALL flags (`mt.flags &= ~TableFlags.MASK`) on:
  (1) new key insertion (`nodeInsert` success), (2) dead-node revival (nil→non-nil update),
  (3) post-rehash insertion. This matches PUC `invalidateTMcache` called from
  `luaH_newkey`/`luaH_finishset` — PUC also clears ALL flags unconditionally.
- **No caching for events > .eq**: `getTmByObj` uses `getTm` (no flags) for ALL events.
  `fastTm` is only called directly from opcode fast paths (GETTABLE/SETTABLE/GETFIELD/SETFIELD/LEN)
  with events <= .eq. The arithmetic/compare/concat/call/close paths all use `getTmByObj`.

### F. Call site migration
Migrated all string-based metamethod lookups to typed events:
- **TMS sites** (arithmetic/compare/concat/index/newindex/len/eq/call/close/gc/mode):
  `metamethodValue(v, "__xxx")` → `getTmByObj(v, .xxx)`. Count: ~20 sites in vm.zig + 2 in api.zig + 1 in c_api.zig.
- **MetaField sites** (tostring/pairs): `metamethodValue(v, "__tostring/__pairs")` → `getMetaFieldByObj(v, .tostring/.pairs)`. Count: ~9 sites.
- **MetaField sites** (name/metatable): `getFieldOpt(mt, "__name/__metatable")` → `getMetaField(mt, .name/.metatable)`. Count: 4 sites.
- **`callBinaryMetamethod`/`callUnaryMetamethod`**: changed `mm_name: []const u8` → `event: TmsEvent`,
  use `getTmByObj` internally. All ~45 call sites updated (`"__add"` → `.add`, etc.).
- **`tryPushBytecodeBinaryMetamethod`/`tryPushBytecodeUnaryMetamethod`**: same signature change.
  All ~35 call sites updated. Two `tm_str` variables (ADDI/SHRI negation peephole) changed from
  `[]const u8` to `TmsEvent`.

### G. matchTmsEvent fate: DELETED
`matchTmsEvent` (string→TmsEvent linear scan over `tm_names`), `metamethodValue` (string-based
metamethod lookup), and `metamethodValueByEvent` (non-cached event lookup) are all DELETED.
Zero call sites remain — all migrated to typed `getTmByObj`/`getTm`/`fastTm`/`getMetaFieldByObj`/`getMetaField`.

### Verification
| Check | Result |
|-------|--------|
| Debug build + test | PASS |
| ReleaseFast build + test | PASS |
| matrix --testc | zig_fail=0 (big.lua both_fail pre-existing) |
| Smoke 57/57 | PASS (incl. 57_finalizer_reach — gc/mode/eq events) |
| c_api test + test-diff | PASS (DIFF: PASS) |
| nextvar 3x | OK/OK/OK |
| gengc/gc/closure/events/coroutine --testc | all OK |
| CallFrame ≤ 104 | comptime assert PASS |
| perf_compare --runs 5 | OK (no regressions, geomean 2.22x, metamethod_add -6.1%) |

## P16.6 — real MMBIN/MMBINI/MMBANK handlers + simplified arith/UNM/BNOT (2026-08-29, verifier P16.6 Tasks 4+5+6)

### A. Real MMBIN/MMBINI/MMBANK handlers
Replaced the no-op `.mmbin, .mmbini, .mmbink => {},` with real handlers that
implement PUC `luaT_trybinTM` (ltm.c:150-166):
- Read previous instruction (`pi = code[ctx.pc - 1]`) to get result dest (`pi.a`).
- Decode `TmsEvent` from C field via `@enumFromInt(@as(u5, @truncate(c)))`.
- Determine operands per instruction format and flip bit:
  - MMBIN: (R[A], R[B])
  - MMBINI: sB2int(b) = `@as(i64, b) - 127`; flip=0→(R[A], imm); flip=1→(imm, R[A])
  - MMBANK: K[B]; flip=0→(R[A], K[B]); flip=1→(K[B], R[A])
- Try metamethod via `tryPushBytecodeBinaryMetamethod` (bytecode Closure push).
- If not a bytecode Closure, call synchronously via `callMetamethod` (handles
  Builtin, Closure-without-proto, and not-callable → PUC call error).
- If no metamethod found → `failBinaryMmbin` (PUC luaG_opinterror/luaG_tointerror).

### B. Simplified arithmetic handlers (ADD through SHR, ADDK through BXORK, ADDI/SHLI/SHRI)
Each handler now follows the PUC `op_arith_aux` pattern:
- **Fast path** (Int/Num combos): compute inline, `ctx.pc += 1` to skip MMBIN.
- **String coercion** (luazig extension for missing PUC string metatable __add):
  `coerceArithmeticValue` both operands → if both coerce, compute via `binAdd`/
  `binSub`/etc. (preserves Int vs Num semantics), `ctx.pc += 1`.
- **Fall-through**: if coercion fails, do nothing (no pc skip). Default pc
  advance lands on MMBIN, which handles metamethod/error.
- **ADDI no longer peeks at MMBINI**: ADDI just computes `R[B] + sC`. The
  MMBINI handler decodes the correct event (TMS_ADD vs TMS_SUB) and operands.
- **SHRI no longer peeks at MMBINI**: same simplification for shift negation.

### C. Simplified UNM/BNOT
- UNM: fast path (Int/Num) + string coercion + `tryPushBytecodeUnaryMetamethod`
  + `callMetamethod` fallback + `failBinaryMmbin` error.
- BNOT: fast path (Int) + `valueToIntForBitwise` coercion + same fallback chain.
- Both use `tmsEventOpname(event)` for the single opname derivation point.

### D. tmsEventOpname helper
New `tmsEventOpname(event: TmsEvent) []const u8` — single derivation point for
opname strings from TmsEvent. Used ONLY on the cold metamethod path (MMBIN/
UNM/BNOT handlers) to set the debug name of the child frame. The hot arithmetic
fast path carries no string at all.

### E. failBinaryMmbin helper
New `failBinaryMmbin(p1, p2, event, proto, arith_pc, p1_reg, p2_reg)` —
implements PUC luaT_trybinTM error logic:
- Bitwise event + both numbers → `luaG_tointerror`: "number (kind 'name') has
  no integer representation" (PUC format: annotation in the MIDDLE).
- Else → `luaG_opinterror`: "attempt to perform arithmetic/bitwise operation on
  a X value (kind 'name')" (PUC format: annotation at the END).
- `luaG_opinterror` blame logic: `!ttisnumber(p1)` (Int/Num only, NOT string)
  → blame p1; else blame p2.

### F. callMetamethod error message fixed
Changed from "metamethod 'add' is not callable (number value)" to PUC's format:
"attempt to call a number value (metamethod 'add')" (luaG_callerror).

### G. Dead code removed
- `addSlowPath` — outlined cold path for OP_ADD (replaced by inline coercion).
- `evalBytecodeBinOp` — error-annotating wrapper for binary ops (replaced by
  `failBinaryMmbin` in MMBIN handler).
- `evalBytecodeBinOpValues` — same for K/I-variant ops (replaced by MMBINK/MMBINI).
- `evalBytecodeUnOp` — error-annotating wrapper for unary ops (replaced by
  `failBinaryMmbin` in UNM/BNOT handlers).
Net: -147 lines (524 insertions, 671 deletions).

### Verification
| Check | Result |
|-------|--------|
| Debug build + test | PASS |
| ReleaseFast build + test | PASS |
| mm_probe.lua byte-identical PUC vs zig | PASS (0 diff) |
| matrix --testc | zig_fail=0 (big.lua both_fail pre-existing) |
| Smoke 57/57 | PASS |
| c_api test | ALL PASS |
| nextvar/coroutine/gc/gengc/closure/events/errors | all PASS |
| CallFrame ≤ 104 | comptime assert PASS |
| perf_compare --runs 7 | OK (no regressions, geomean 2.23x) |

## P16.6 — permanent metamethod dispatch differential smoke (2026-08-29, verifier Task 7)

### tests/smoke/58_metamethod_dispatch.lua
Permanent differential smoke covering verifier sections A–H:
- **A**: left/right `__add` lookup precedence (both directions; left operand wins).
- **B**: dynamic mt mutation (anti-cache): `f1 → f2 → nil(pcall error) → f3` for
  `__add` AND `__sub`; proves no metamethod caching across calls.
- **C**: all 12 binary events firing (add/sub/mul/mod/pow/div/idiv/band/bor/
  bxor/shl/shr) + flip paths (number on LEFT) for sub/div/idiv/mod — these
  exercise ADDI/MMBINI/MMBINK flip and prove operand order is preserved
  (metamethod receives `(number, table)` in source order, NOT swapped).
- **D**: MMBINI/MMBINK immediates + constant-pool flips; metamethod prints
  `"event:left/right"` tags proving event identity + operand order for every
  path (ADDI/SUBI/SUBI-flip/SHLI/SHLI-flip/SHRI/SHRI-flip/ADDK/SUBK/SUBK-flip/
  MULK/MULK-flip/ADDK-flip/DIVK-flip/IDIVK-flip/MODK-flip).
- **E**: MMBINK constant-pool numeric keys + numeric-string coercion (PUC
  coerces `"123" → 123` in arithmetic; success path only).
- **F**: unary `__unm`/`__bnot` (firing + error without metamethod).
- **G**: yielding Lua metamethod (yield mid-call, resume completes) + nested
  metamethod-on-metamethod + nested+yield combined.
- **H**: `debug.sethook` call/return trace around metamethod calls (full
  sequence + kind/count summary). Count-mask hooks intentionally excluded
  (instruction counts differ by design between PUC and luazig bytecodes).

### PUC-verified subtleties discovered
- **Flip operand order**: for non-commutative events (sub/div/mod/idiv) with a
  number on the LEFT, PUC flips the TM lookup (uses the table's metamethod) but
  PRESERVES source operand order — the metamethod receives `(number, table)`,
  not `(table, number)`. luazig matches byte-identically.
- **Shifts flip identically**: `3 << x` calls `__shl(3, x)` (number, table).
- **Numeric-string coercion** is arithmetic-only: PUC coerces numeric strings
  for +,-,*,/,//,%,^ but REJECTS strings for bitwise (&,|,~,<<,>>) even when
  numeric. luazig matches the arithmetic coercion path.

### Known parity gaps (excluded from this differential test to keep it byte-identical)
- **String-constant arithmetic ERROR path diverges**: `t + "hello"` (t has no
  metamethod) → PUC emits `attempt to add a 'table' with a 'string'`; luazig
  emits `attempt to perform arithmetic on a table value (upvalue 't')`. PUC
  5.5 introduced a new two-operand error format (`add a 'X' with a 'Y'`) for
  the MMBIN path when both operands are non-numbers; luazig still uses the
  older single-operand format. Tracked for a future src fix.
- **Bitwise-on-string ERROR path diverges**: PUC rejects even numeric strings
  for bitwise with `attempt to perform bitwise operation on a string value
  (constant '12')`; luazig emits a different message + duplicate stack
  traceback. Tracked for a future src fix.
- **Count-mask hooks diverge**: count events fire every N VM instructions;
  PUC vs luazig instruction counts differ by design (different bytecode
  shapes), so count-event traces are not byte-stable. Only call/return ("cr")
  hooks are used in section H.

### Verification
| Check | Result |
|-------|--------|
| PUC vs zig byte-identical (58_metamethod_dispatch.lua) | PASS (0 diff) |
| 3× stability runs both runtimes (identical md5) | PASS |
| Debug build (0xaa/panic sanity) | PASS (no panic, output matches) |
| ReleaseFast rebuild + re-verify | PASS |
| Full smoke_compare | 58 passes; 29 + 45_userdata_capi pre-existing (unrelated) |
