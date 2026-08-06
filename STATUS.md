# luazig — Project Status & Development History

This file contains detailed project status, development log, performance analysis,
and architectural decisions. For a project overview, see [README.md](README.md).

> Last updated: 2026-08-06

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
| Performance (geomean vs PUC) | **2.76x** |

Bytecode VM (`--vm=bc`) — единственный активно развиваемый backend.
IR VM полностью удалена из кодовой базы.

`big.lua` — `both_fail` (pre-existing: требует `coroutine.wrap` harness из `all.lua`).

## Производительность

Geomean замедления vs PUC Lua: **2.76x** (цель: 1.0x).
Подробная таблица workload'ов — в [README.md](README.md).

### Методика

- PUC Lua 5.5 (vendored) vs luazig (ReleaseFast), `taskset -c 0`, медиана 7 прогонов.
- `python3 tools/perf_compare.py` — WARN +5%, FAIL +10% к baseline (`tools/perf/baseline-p15.37.json`).

### Текущие bottleneck'ы (по приоритету)

1. **Instruction inflation** — лишние опкоды на Lua-итерацию. Частично решено (P15.32, P15.38).
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

### fix: enableTestcModuleInternal _ENV upvalue
**Problem:** `enableTestcModuleInternal` passed empty upvalues (`&.{}`) to `runBytecode` for the testC bootstrap chunk. The bootstrap source uses global accesses (`require`, `setmetatable`) that compile to `OP_GETTABUP` on upvalue 0 (`_ENV`). With empty upvalues, `gettabup` caused an out-of-bound...
Результат: testC lane goes from 0/6 (all SIGSEGV) to 2/6 pass (`errors.lua`,

### fix: stale `outs` after bc_stack realloc in pcall/xpcall/testC
**Problem:** `builtinTestcTestC`, `builtinPcall`, `builtinXpcall` error paths used stale `outs` slice after `callBuiltin`/`runClosure` triggered bc_stack realloc. Also `opTforcall` had LUA_MULTRET UB (`nresults < 0` cast to usize).

### fix: GC varargs scan use bc_stack for VM-active thread
**Problem:** `gcPropagateOne` used `th.bytecode_stack` directly for varargs scan, but for VM-active thread it's empty (moved to `bc_stack`).

### Phase R1 — Unify api.State on *Vm + vm.c_stack
**Problem:** `api.State` owned a `Vm` by value and maintained a SEPARATE `stack` field (`ArrayListUnmanaged(Value)`), distinct from `vm.c_stack` used by `c_api.zig`. This dual-stack architecture meant `api.State` and `c_api.zig` operated on different stacks, blocking consolidation of the C API and Zig API surfaces.

**Fix:** `State.vm` is now `*Vm` (borrowed pointer) instead of `Vm` (owned by value). The `stack` and `alloc` fields are removed — all methods use `self.vm.c_stack` and `self.vm.alloc` directly. `State.init` heap-allocates the Vm; `State.deinit` frees it. New `State.fromVm(vm: *Vm)` constructor wraps an existing `*Vm` without taking ownership (for future c_api.zig consolidation).

**Result:** `api.State` and `c_api.zig` now share the same stack (`vm.c_stack`), eliminating the dual-stack problem. testc.zig updated mechanically (`st.alloc` → `st.vm.alloc`). Matrix 30/31, smoke 49/49 — no regressions.

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
- [ ] Развивать Zig embedding API (`api.zig` — ~40 методов; `c_api.zig` — gaps).

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

- **C API** (`c_api.zig`): lua_State = *Vm, c_stack, ~40 export functions.
- **Call dispatch**: Closure.c_func → callCFunction (bc_stack↔c_stack bridge).
- **Error boundary**: _setjmp/_longjmp (pure Zig). lua_error longjmp в boundary.
- **loadlib**: std.DynLib.open, luaopen_* lookup, CLIBS cache (RTLD_GLOBAL).
- **External strings**: lua_pushexternalstring, LuaString.is_external.
- **Заголовки**: src/lua/lua.h, lauxlib.h — PUC 5.5 compatible.

## GC refactor: unified GcObject

Per-type GC списки → единый GcObject tagged union (PUC allgc). Full Userdata тип.

- GcObject: .table/.closure/.thread/.string/.cell/.userdata.
- Unified sweep (gcSweepOne walks gc_objects). Generational lists migrated.
- Userdata: gc fields + metatable + uservalues.
- fasttm: Table.flags bitmask (BITRAS), cache-on-miss.

## fasttm

PUC fasttm (ltm.h:63): Table.flags bitmask. __eq/__len/__gc/__mode/__index/__newindex через fasttm.
