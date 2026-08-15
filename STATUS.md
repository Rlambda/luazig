# luazig — Project Status & Development History

This file contains detailed project status, development log, performance analysis,
and architectural decisions. For a project overview, see [README.md](README.md).

> Last updated: 2026-08-15 (P15.78: C continuations — OPEN, Phase 3 deferred)

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

| Metric | Result |
|--------|--------|
| Upstream matrix (`testes/*.lua`) | **30/31** pass (exit code parity) |
| Differential output (`--diff`) | **0 output_diff** |
| Smoke tests | **49/49** pass |
| Performance (geomean vs PUC) | **2.67x** |

Bytecode VM (`--vm=bc`) — единственный активно развиваемый backend.
IR VM полностью удалена из кодовой базы.

`big.lua` — `both_fail` (pre-existing: требует `coroutine.wrap` harness из `all.lua`).

## Производительность

Geomean замедления vs PUC Lua: **2.67x** (цель: 1.0x).
Подробная таблица workload'ов — в [README.md](README.md).

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
- [ ] Специализированные integer и interned-string lookup/insert paths.
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
- [ ] wall time, process CPU, max RSS и opcode count (только wall time);
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

### P15.78 — STATUS: OPEN (Phase 3 deferred)

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

**Deferred (Phase 3):**
- testC `callk`/`pcallk`/`yieldk` migration to real C continuations
- `TestcPendingContinuation` removal (~200 lines)
- **Reason:** testC uses a separate `std.ArrayListUnmanaged(Value)` stack (303
  references). PUC's `Cfunck` reads the continuation script via
  `lua_tostring(L, ctx)` where `ctx` is a Lua stack index — this works because
  PUC's testC stack IS the Lua stack. In luazig, `ctx` cannot index into the
  testC stack from a C `k` callback. Migration requires making testC use
  `c_stack` as its stack — a multi-day refactor of 300+ references.

**Gate results:**
- Debug build: clean
- Unit tests (Debug): 148/148 pass
- Matrix: 31/32 pass (big.lua both_fail — pre-existing)
- Smoke: 49/49 identical to PUC Lua
- C API: 11/11 pass, dual-runtime differential PASS (identical output)
- pcallk error/TBC/status tests: t5 pcallk_error PASS (both PUC and luazig)
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

## Открытые задачи

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
- [ ] Добавить process CPU, max RSS, opcode count (сейчас только wall time).
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
