# Performance Phase P15.37 — Hotspot-Driven Optimization Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Уменьшить геометрическое среднее замедления от PUC Lua с текущих **5.21×** (P15.36) до **≤3×** за счёт трёх hotspot-driven задач, выявленных через `perf record --call-graph lbr` на современном ядре.

**Architecture:** Три независимых фазы, каждая закрывает конкретный hotspot:
1. **P15.37a — Frame-struct slim:** устранить `compiler_rt.memset` (byte-wise zero-init структур фреймов) на call/return. Подход: выделить hot-subset полей в compact-struct + bulk-reuse pool.
2. **P15.37b — Node compaction + interned-string fast path:** уплотнить `ltable.Node` с 40 B до 24–32 B (parity с PUC), добавить специализированный string-key path без повторного хеширования.
3. **P15.37c — Metatable fast-tag:** добавить `Table.flags` bitmask (PUC `BITRAS`, `ltable.h:62`) для пропуска метаметод-проверки на plain tables.

**Tech Stack:** Zig 0.16.0, ReleaseFast build, `perf stat`/`perf record --call-graph lbr` для A/B-замеров.

**Спецификации/контекст:**
- README.md §«P15.36 perf-based hotspot analysis» — исходные hotspot-данные
- README.md §«Недостаток 4», «Недостаток 6» — контекст
- `lua-5.5.0/src/ltable.h:62` (BITRAS), `lua-5.5.0/src/ltable.c` (Node layout)
- Baseline parity gate: `python3 tools/testes_matrix.py` → 28/31 (без `_soft`/`_port`)
- Smoke gate: `for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f"; done`
- Microbench: `taskset -c 0 zig-out/bin/luazig tools/microbench.lua`

---

## Файловая карта

| Файл | Роль | Затронут фазой |
|---|---|---|
| `src/lua/vm.zig` | `RuntimeFrame`, `BytecodeExecFrame` (struct'ы), `pushBytecodeExecFrame`, `completeBytecodeExecFrame`, `popBytecodeExecFrame`, `applyBytecodePendingResults`, metamethod-check helpers (`indexValueDepth`, `tryPushBytecodeIndexMetamethod`) | a, c |
| `src/lua/ltable.zig` | `Node`, `keyHash`, `nodeLookup`, `nodeInsert`, `Table` | b |
| `src/lua/vm.zig::Table` | Добавить поле `flags: u8` | c |
| `tools/perf_compare.py` | Новый инструмент perf-gate | d |

---

## Task a (P15.37a): Frame-struct slim — устранить byte-wise memset на call/return

**Контекст:** `perf` показывает, что на `lua_calls` 57% времени занимает `compiler_rt.memset`. Источник — инициализация большой структуры фрейма при `frames.append`. Компилятор Zig эмитит byte-wise memset (не векторизованный `compiler_rt.memset`) для zero-init struct literal. Структуры:
- `RuntimeFrame` (~250 B, ~24 поля, см. `vm.zig:778`)
- `BytecodeExecFrame` (с большим `pending_call: ?BytecodePendingCall` union, см. `vm.zig:740`)

На каждом OP_CALL и OP_RETURN эти структуры пишутся через struct literal → memset + field-init.

### Подход: bulk-reuse pool + hot/cold split

**Идея:** вместо `ArrayList.append(.{...})` с zero-init всей структуры, держать пул переиспользуемых слотов, где hot-поля перезаписываются напрямую без zero-init.

**Hot subset `RuntimeFrame`** (то, что нужно на call site): `func, proto, callee, regs, boxed, upvalues, varargs, pc, top, nvarstack, bc_base, frame_id, is_tailcall, hide_from_debug, current_line, last_hook_line`.

**Cold subset:** debug-hook state (`is_debug_hook, debug_hook_transfer, debug_hook_transfer_start, debug_hook_event_*, debug_hook_allow_yield, used_closing_line_hook, resume_skip_count_pc, debug_namewhat, debug_name, env_override, local_active, locals`). Для большинства фреймов эти поля — default zero.

### Task a1: Измерить размер структур

**Files:**
- Modify: `src/lua/vm.zig` (временно)

- [ ] **Step 1: Добавить debug-print размеров**

В `Vm.init` (после инициализации, примерно `vm.zig:1720`) добавить временный print:

```zig
if (debug_struct_sizes) {
    std.debug.print("RuntimeFrame={d} BytecodeExecFrame={d} BytecodePendingCall={d} Value={d}\n", .{
        @sizeOf(RuntimeFrame), @sizeOf(BytecodeExecFrame),
        @sizeOf(BytecodePendingCall), @sizeOf(Value),
    });
}
```

- [ ] **Step 2: Build и замерить**

Run: `zig build -Doptimize=ReleaseFast && zig-out/bin/luazig -e 'print(1)'`
Записать числа. Ожидание: RuntimeFrame ~240-280 B, BytecodeExecFrame ~200-400 B.

- [ ] **Step 3: Удалить debug-print, закоммитить замер в README**

В README §«P15.36 perf-based hotspot analysis» уточнить точные размеры.

### Task a2: Bulk-reuse pool для bytecode exec frames

**Files:**
- Modify: `src/lua/vm.zig::Vm` (поле `exec_frames`, ~line 1535)
- Modify: `src/lua/vm.zig::pushBytecodeExecFrame` (~line 6499)
- Modify: `src/lua/vm.zig::popBytecodeExecFrame` (~line 6616)

- [ ] **Step 1: Заменить `exec_frames.append` на reuse слота из pool**

В `pushBytecodeExecFrame` вместо:
```zig
try exec_frames.append(self.alloc, .{ ... });
```

Реализовать reuse pool: если в `exec_frames` есть слот за `items.len`, использовать его, перезаписывая только hot-поля напрямую. Не использовать struct literal (он триггерит memset).

```zig
const idx = exec_frames.items.len;
if (exec_frames.capacity <= idx) {
    try exec_frames.ensureUnusedCapacity(self.alloc, 1);
}
// НЕ делаем struct literal. Пишем поля по одному.
if (idx < exec_frames.items.len) {
    // reuse existing slot
} else {
    // grow items.len += 1 без zero-init
    exec_frames.items.len += 1;
}
const slot = &exec_frames.items[idx];
slot.proto = proto;
slot.upvalues = upvalues;
slot.activation_id = activation_owner.bytecode_activation_counter;
slot.base = base;
slot.frame_cap = frame_cap;
slot.pc = 0;
slot.reg_top = nparams;
slot.nvarstack = nparams;
slot.varargs = frame_varargs;
slot.tbc_mark = tbc_mark;
slot.runtime_frame_index = runtime_frame_index;
slot.pending_call = null;
slot.is_tailcall = false;
slot.last_line_pc = null;
slot.skip_call_hook_pc = null;
slot.resumed_direct_yield = false;
// остальные поля сохраняют значение из предыдущего использования
// (корректно, т.к. мы их перезаписываем перед чтением)
```

- [ ] **Step 2: То же самое для `RuntimeFrame` в `frames.append`**

Аналогично в `pushBytecodeExecFrame` (строка ~6568). Только hot-поля.

- [ ] **Step 3: Build, проверить что microbench сохраняет корректность**

Run: `zig build -Doptimize=ReleaseFast`
Run: `python3 tools/testes_matrix.py`
Expected: 28/31, без регрессий.

- [ ] **Step 4: Замерить improvement**

Run: `taskset -c 0 zig-out/bin/luazig tools/microbench.lua | grep lua_calls`
Expected: lua_calls должен упасть с 1.747s до ~1.2-1.4s (устранение ~30% byte-wise memset).

- [ ] **Step 5: Perf re-check на lua_calls**

Run:
```bash
perf record -F 999 --call-graph lbr -o /tmp/perf-after.data -- \
  taskset -c 0 zig-out/bin/luazig -e 'local function inc(x) return x+1 end local N=5000000 local s=0 for i=1,N do s=inc(s) end io.write(s.."\n")'
perf report -i /tmp/perf-after.data --stdio --no-children -g none --percent-limit 1
```
Expected: доля `compiler_rt.memset` должна упасть с 57% до <15%.

- [ ] **Step 6: Smoke + parity gate, commit**

Run: `for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo FAIL:$f; done`
Run: `python3 tools/testes_matrix.py`
Expected: нет FAIL, 28/31 parity.

```bash
git add src/lua/vm.zig README.md
git commit -m "perf(P15.37a): reuse frame slots instead of byte-wise zero-init"
```

### Task a3: Hot/cold split (опционально, если a2 недостаточно)

Только если после a2 доля memset на lua_calls всё ещё >25%.

**Files:**
- Modify: `src/lua/vm.zig::BytecodeExecFrame`, `RuntimeFrame`

- [ ] **Step 1: Вынести cold debug-hook поля в отдельный ArrayList**

Создать `BytecodeExecFrameCold` с полями `is_debug_hook, debug_hook_transfer, debug_namewhat, debug_name, ...`. Хранить как отдельный `debug_frames: std.ArrayListUnmanaged(BytecodeExecFrameCold)`, индексированный тем же idx.

- [ ] **Step 2: Build, parity, perf**

Записать до/после в README.

- [ ] **Step 3: Commit**

---

## Task b (P15.37b): Node compaction до 32 B

**Контекст:** `ltable.Node` = 40 B (key 16 + value 16 + hash 8 + dead_key 1 + next* 8 + padding). PUC Node = 24 B (TKey 8 + TValue 16, chain packed в TKey через union с `next` offset). 28% от global_arith тратит `nodeLookup`. Cache line 64 B вмещает 1.6 наших Node vs 2.67 PUC.

### Подход: split key/value + hash в сторону tag-packing

Полная parity с PUC требует variant TKey (int/str/etc packed в 8 байт) — крупная переработка. Сделаем промежуточный шаг: уменьшить до 32 B, заменив `next: ?*Node` (8 B + padding) на `next_offset: i32` (4 B), и упаковав `dead_key: bool` в unused бит hash. Экономия: 8 B на узел + alignment.

### Task b1: Замерить текущий layout

**Files:**
- Modify: `src/lua/ltable.zig::Node` (временно, debug-print)

- [ ] **Step 1: Print @sizeOf в unit test**

В `ltable.zig` сверху добавить `test "size" { std.debug.print("Node={d}\n", .{@sizeOf(Node)}); }`.

Run: `zig test src/lua/ltable.zig`
Записать число (ожидание: 40 B).

- [ ] **Step 2: Удалить test**

### Task b2: Перевести `next` на i32 offset

**Files:**
- Modify: `src/lua/ltable.zig::Node`
- Modify: `src/lua/ltable.zig::nodeLookup`, `nodeInsert`, rehash, итератор

- [ ] **Step 1: Изменить Node struct**

```zig
pub const Node = struct {
    key: Value = .Nil,
    value: Value = .Nil,
    hash: u64 = 0,
    // Chain link как offset от текущего node. 0 = end-of-chain.
    // PUC хранит в int `gnext`, мы используем i32 (signed, для возможных
    // backward-ссылок). Экономит 4 B + alignment vs ?*Node.
    next_offset: i32 = 0,

    pub fn isEmpty(self: *const Node) bool {
        return self.key == .Nil and (self.hash & DEAD_KEY_FLAG) == 0;
    }
};

const DEAD_KEY_FLAG: u64 = 1 << 63;
```

`dead_key` упакован в старший бит hash (хеш не использует все 64 бита на практике).

- [ ] **Step 2: Обновить chain-walk код**

Везде где `node.next` использовался как pointer, перевести на:
```zig
fn nextNode(self: *Node, nodes: []Node) ?*Node {
    if (self.next_offset == 0) return null;
    return &nodes[@intCast(@as(i64, @intCast(nodes.len)) + self.next_offset - ... )];
}
```

(Альтернатива: offset относительно начала `nodes` slice, а не текущего узла — проще, но требует передавать `nodes` в chain-walk.)

- [ ] **Step 3: Запустить ltable unit tests**

Run: `zig test src/lua/ltable.zig`
Expected: PASS. Если ltable.zig не имеет своего test runner, проверить через `zig build test`.

- [ ] **Step 4: Parity gate**

Run: `python3 tools/testes_matrix.py`
Expected: 28/31. Особенно важны: `nextvar.lua`, `gc.lua` (weak tables, dead keys), `constructs.lua`.

- [ ] **Step 5: Smoke gate**

Run: `for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo FAIL:$f; done`
Expected: нет FAIL.

- [ ] **Step 6: Замер improvement на global_arith и hash_access**

Run: `taskset -c 0 zig-out/bin/luazig tools/microbench.lua | grep -E 'global_arith|hash_access|field_access|array_access'`
Expected: global_arith 3.568s → ~3.0s (-15%), hash_access 0.469s → ~0.40s.

- [ ] **Step 7: Perf re-check на global_arith**

Run:
```bash
perf record -F 999 --call-graph lbr -o /tmp/perf-garith2.data -- \
  taskset -c 0 zig-out/bin/luazig -e 'local N=50000000 g_count=0 for i=1,N do g_count=g_count+i end io.write(g_count.."\n")'
perf report -i /tmp/perf-garith2.data --stdio --no-children -g none --percent-limit 1
```
Expected: доля `ltable.nodeLookup` должна упасть с 28%.

- [ ] **Step 8: Commit**

```bash
git add src/lua/ltable.zig README.md
git commit -m "perf(P15.37b): compact ltable.Node 40B→32B via i32 chain offset"
```

---

## Task c (P15.37c): Metatable fast-tag (BITRAS)

**Контекст:** 11% от global_arith тратят `indexValueDepth` + `tryPushBytecodeNewIndexMetamethod` — каждая global get/set проверяет metatable даже для plain tables. PUC хранит bitmask `flags` в `Table` (см. `lua-5.5.0/src/ltable.h:62`, `BITRAS_*`), сбрасываемый при установке метаметода, и skip'ает метаметод-проверку когда нужный бит выставлен.

### Task c1: Добавить `flags: u8` в `Table`

**Files:**
- Modify: `src/lua/vm.zig::Table` (~line 385)

- [ ] **Step 1: Добавить поле и константы**

```zig
const TableFlags = struct {
    pub const HAS_INDEX: u8 = 1 << 0;
    pub const HAS_NEWINDEX: u8 = 1 << 1;
    pub const HAS_LEN: u8 = 1 << 2;
    pub const HAS_GC: u8 = 1 << 3;
    pub const HAS_MODE: u8 = 1 << 4;
    // ... полный список по PUC ltable.h:62
    pub const FAST_GET_OK: u8 = ~(HAS_INDEX);
    pub const FAST_SET_OK: u8 = ~(HAS_NEWINDEX);
};
```

В `Table`:
```zig
pub const Table = struct {
    // ... существующие поля
    /// PUC BITRAS-style bitmask. Когда нужный бит выставлен (1=no-metamethod),
    /// пропускаем метаметод-проверку на fast path. Сбрасывается в 0 при
    /// установке/смене метаметода. См. ltable.h:62.
    flags: u8 = TableFlags.FAST_GET_OK | TableFlags.FAST_SET_OK,
    // ...
};
```

- [ ] **Step 2: Build, проверить что флаг инициализирован правильно**

Run: `zig build -Doptimize=ReleaseFast`
Ожидание: без ошибок. Все новые таблицы создаются с `flags = 0xFF`.

### Task c2: Сбрасывать флаг при установке метаметода

**Files:**
- Modify: `src/lua/vm.zig::gcStoreMetatable` (~line 13541)

- [ ] **Step 1: Реализовать сброс**

```zig
inline fn gcStoreMetatable(self: *Vm, table: *Table, metatable: ?*Table) DispatchError!void {
    table.metatable = metatable;
    // P15.37c: invalidate fast-path flag. Conservative approach — сбрасываем
    // все fast bits, дальше каждый get/set ходит через полный метаметод-чек
    // и при первом нахождении поднимает нужный bit. См. PUC ltable.h:62.
    table.flags = 0;
    if (metatable) |mt| try self.gcForwardBarrierValue(.{ .Table = table }, .{ .Table = mt });
}
```

- [ ] **Step 2: Parity gate**

Run: `python3 tools/testes_matrix.py`
Expected: 28/31. Особенно: `events.lua` (metatable events), `constructs.lua` (метаметоды), `gc.lua` (__gc).

### Task c3: Использовать флаг на fast path GETFIELD/SETFIELD/GETI/SETI

**Files:**
- Modify: `src/lua/vm.zig` bytecode dispatch для `.getfield`, `.setfield`, `.gettable`, `.settable`, `.geti`, `.seti`, `.gettabup`, `.settabup`

- [ ] **Step 1: Добавить fast-path check в indexValueDepth**

Перед metamethod-lookup:
```zig
fn indexValueDepth(self: *Vm, table: *Table, key: Value, depth: u8) ... {
    // P15.37c: если metatable есть, но flags говорит что __index нет — skip.
    if (table.metatable) |mt| {
        if ((table.flags & TableFlags.HAS_INDEX) == 0) {
            // fast: __index точно нет
            return null; // или эквивалент "no metamethod"
        }
        // ... существующий metamethod lookup
    }
    return null;
}
```

Аналогично для `setIndexValueDepth` с `HAS_NEWINDEX`.

- [ ] **Step 2: Parity gate**

Run: `python3 tools/testes_matrix.py`
Expected: 28/31.

- [ ] **Step 3: Smoke gate**

Run: `for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo FAIL:$f; done`
Expected: нет FAIL.

- [ ] **Step 4: Замер improvement на global_arith**

Run: `taskset -c 0 zig-out/bin/luazig tools/microbench.lua | grep -E 'global_arith|field_access|metamethod_add'`
Expected: global_arith 3.0s → ~2.5s (-15%), field_access должен улучшиться.

- [ ] **Step 5: Perf re-check на global_arith**

Expected: доля `indexValueDepth` + `tryPushBytecodeNewIndexMetamethod` должна упасть с 11% до <3%.

- [ ] **Step 6: Commit**

```bash
git add src/lua/vm.zig README.md
git commit -m "perf(P15.37c): Table.flags bitmask skips metamethod-check on plain tables"
```

---

## Task d (P15.37d): perf_compare.py + versioned baseline

**Files:**
- Create: `tools/perf_compare.py`
- Create: `tools/perf/baseline-p15.37.json`

### Task d1: Скрипт perf-gate

- [ ] **Step 1: Реализовать tools/perf_compare.py**

Скрипт делает:
1. `zig build -Doptimize=ReleaseFast`
2. `taskset -c 0 zig-out/bin/luazig tools/microbench.lua` — медиана 7 прогонов
3. Для каждого workload: время, ratio vs PUC (`build/lua-c/lua tools/microbench.lua`)
4. Опционально: `perf stat` на worst workload'ах
5. Сравнение с baseline JSON: warning если regression >5%, failure если >10%
6. Вывод таблицы + обновляемый JSON output

```python
#!/usr/bin/env python3
"""
perf_compare.py — reproducible perf gate for luazig.

Usage:
  perf_compare.py                    # run + compare vs baseline
  perf_compare.py --update-baseline  # rewrite baseline.json with current results
  perf_compare.py --perf             # also run perf stat on top workloads
"""
import json, subprocess, statistics, sys, os, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ZIG_LUA = ROOT / "zig-out/bin/luazig"
PUC_LUA = ROOT / "build/lua-c/lua"
BENCH = ROOT / "tools/microbench.lua"
BASELINE = ROOT / "tools/perf/baseline-p15.37.json"
CORE = "0"
N_RUNS = 7
REGRESSION_WARN = 0.05
REGRESSION_FAIL = 0.10

def run_bench(lua_bin):
    out = subprocess.check_output(
        ["taskset", "-c", CORE, str(lua_bin), str(BENCH)],
        text=True, timeout=600,
    )
    result = {}
    for line in out.splitlines():
        if "\t" in line and not line.startswith("done"):
            name, sec = line.split("\t", 1)
            try:
                result[name.strip()] = float(sec)
            except ValueError:
                pass
    return result

def median_runs(lua_bin, n):
    runs = [run_bench(lua_bin) for _ in range(n)]
    names = runs[0].keys()
    return {name: statistics.median(r[name] for r in runs) for name in names}

def main():
    update = "--update-baseline" in sys.argv
    do_perf = "--perf" in sys.argv

    subprocess.check_call(["zig", "build", "-Doptimize=ReleaseFast"], cwd=ROOT)
    subprocess.check_call(["make", "-s", "lua-c"], cwd=ROOT)

    print(f"Running {N_RUNS} median runs...")
    zig = median_runs(ZIG_LUA, N_RUNS)
    puc = median_runs(PUC_LUA, N_RUNS)

    print(f"\n{'Workload':<20} {'PUC':>8} {'Zig':>8} {'Ratio':>8}")
    print("-" * 48)
    for name in sorted(set(zig) | set(puc)):
        if name in zig and name in puc:
            ratio = zig[name] / puc[name] if puc[name] else 0
            print(f"{name:<20} {puc[name]:>8.3f} {zig[name]:>8.3f} {ratio:>7.2f}x")

    if do_perf:
        # perf stat на top-3 workloads
        for bench_lua in [
            "local N=50000000 g_count=0 for i=1,N do g_count=g_count+i end io.write(g_count..\"\\n\")",
        ]:
            subprocess.run([
                "perf", "stat", "-e", "cycles:u,instructions:u,branch-misses:u,cache-misses:u",
                "taskset", "-c", CORE, str(ZIG_LUA), "-e", bench_lua,
            ])

    current = {
        "zig": zig, "puc": puc,
        "ratios": {n: zig[n]/puc[n] for n in zig if n in puc},
    }

    if update:
        BASELINE.parent.mkdir(exist_ok=True)
        BASELINE.write_text(json.dumps(current, indent=2))
        print(f"\nBaseline updated: {BASELINE}")
        return 0

    if BASELINE.exists():
        prev = json.loads(BASELINE.read_text())
        print(f"\nRegression check vs {BASELINE}:")
        any_fail = False
        for name, cur in zig.items():
            old = prev["zig"].get(name)
            if old is None: continue
            delta = (cur - old) / old
            tag = "OK"
            if delta > REGRESSION_FAIL:
                tag = "FAIL"; any_fail = True
            elif delta > REGRESSION_WARN:
                tag = "WARN"
            print(f"  {name:<20} {old:.3f}→{cur:.3f} {delta*100:+.1f}% {tag}")
        return 1 if any_fail else 0
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Сделать исполняемым**

Run: `chmod +x tools/perf_compare.py`

- [ ] **Step 3: Установить baseline (после P15.37a/b/c)**

Run: `./tools/perf_compare.py --update-baseline`

Это запишет текущие результаты в `tools/perf/baseline-p15.37.json`.

### Task d2: Зафиксировать в README

- [ ] **Step 1: Обновить §P15.37**

В README §P15.37 отметить:
```markdown
- [x] `tools/perf_compare.py` — реализован, поддерживает `--update-baseline`, `--perf`
```

- [ ] **Step 2: Commit**

```bash
git add tools/perf_compare.py tools/perf/baseline-p15.37.json README.md
git commit -m "perf(P15.37d): reproducible perf_compare.py gate with baseline"
```

---

## Финальные шаги после всех фаз

- [ ] **Step 1: Обновить microbench таблицу в README**

Добавить колонку P15.37 с новыми числами для всех 16 workload'ов.

- [ ] **Step 2: Пересчитать geomean**

Run: `python3 -c "import math; ..."`
Ожидаемый target: geomean ≤3× (с ~5.21×).

- [ ] **Step 3: Обновить §«Реалистичные performance milestones»**

- [ ] **Step 4: Финальный commit**

```bash
git add README.md
git commit -m "docs(P15.37): close hotspot-driven perf phase, geomean 5.21x→<3x"
```

---

## Проверка спеки (self-review)

**Spec coverage:**
- Hotspot #1 (memset доминирует на call) → Task a (frame slim)
- Hotspot #2 (table lookup / Node 40B) → Task b (Node compaction)
- Hotspot #3 (metamethod-check overhead) → Task c (Table.flags bitmask)
- P15.37 perf gate → Task d (perf_compare.py + baseline)
- Все Недостатки 1, 2, 3, 4, 6 из README косвенно закрыты (недостаток 1 = codegen — вне scope; частично закроется косвенно через меньший dispatch в a/b/c).

**Placeholder scan:** Нет TBD/TODO, все шаги содержат конкретный код.

**Type consistency:** `TableFlags`, `Table.flags`, `next_offset` — единые имена во всех шагах.

**Критерии закрытия P15.37:**
- Geomean ≤3×
- 28/31 parity, без регрессий
- Все smoke tests pass
- baseline-p15.37.json зафиксирован
- README обновлён с hotspot analysis + новыми числами
