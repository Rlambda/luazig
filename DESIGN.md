# luazig — Design Decisions

Краткая запись архитектурных решений. Что и почему — без дат и лишних слов.

---

## Dispatch model: iterative `frame_loop`

**Что:** `runBytecodeDispatch` использует `frame_loop` для переключения фреймов, не рекурсию.

**Почему:** PUC Lua использует `goto startfunc` для Lua-to-Lua вызовов — итеративный переход в том же C frame (lvm.c OP_CALL). `LUAI_MAXCCALLS=200` лимитирует только C functions, не Lua recursion. Host recursion для OP_CALL — анти-паттерн: stack frame `runBytecodeDispatch` ~4-8KB, overflow при depth ~2000.

**Не пытаться:** заменить iterative dispatch на host recursion (design doc `2026-07-21-host-recursion-design.md` основан на неверной предпосылке).

---

## Short string GC: HashMap tombstone rehash

**Что:** `string_intern.table.rehash()` вызывается в конце `gcSweepOne`.

**Почему:** Zig `HashMapUnmanaged` использует tombstones для deletions. GC sweep удаляет мёртвые строки → tombstones накапливаются → probe chains деградируют до O(N).

---

## SIGINT: periodic check

**Что:** `signal_int_pending.load(.acquire)` проверяется каждые `SIGINT_CHECK_INTERVAL=1024` инструкций, не на каждой.

**Почему:** Atomic acquire-load на каждой инструкции — unnecessary fence. Latency 1024 инструкций ≈ 1µs — незаметно для Ctrl-C.

---

## OP_CALL: inline fast path

**Что:** Fast path (Lua Closure, no hooks, no coroutine resume) inline в dispatch switch, не вызывает `opCall`.

**Почему:** `opCall` — 200+ строк, вызов функции + 5-way `DispatchResult` enum switch на каждый CALL. Inline fast path избегает overhead для большинства вызовов.

---

## Coroutine yield allocations

**Что:** Каждое `coroutine.yield` делало 5-7 heap allocations (PUC — zero). После оптимизаций осталось 2-3.

**Что сделано:**
- `yielded` + `last_yield_payload` слиты в одно поле (было 2 копии)
- `trace_frame_names` → inline `[64]` buffer (zero alloc)
- 3 no-op функции удалены из yield path
- `bytecodeCoroutineYieldStep` dupe убран для common case

**Что осталось:** `resume_inbox` (copy resume args), `suspended_builtin_args` (copy builtin args), nested-coroutine dupe.

---

## TrackingAllocator

**Что:** Tracker отключён в основном бинарнике (`runtime_alloc = std.heap.smp_allocator`).

**Почему:** Non-deterministic SIGABRT в 4 matrix тестах под нагрузкой GC. Хорош для `leak_bench.py` side-by-side, но не для production binary.
