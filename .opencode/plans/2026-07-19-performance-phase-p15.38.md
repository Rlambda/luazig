# Performance Phase P15.38 — Codegen + Dispatch + Table Lookup Optimization

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Уменьшить геометрическое среднее замедления от PUC Lua с текущих **4.77×** (P15.37) до **≤3×** за счёт устранения двух оставшихся hotspot'ов:
1. **Instruction-count bound dispatch** — codegen эмитит 1.6–3.1× больше опкодов, чем PUC
2. **`nodeLookup` ~28% на `global_arith`** — 5 lookups per iteration вместо 2 у PUC

**Architecture:** Пять независимых фаз, каждая закрывает конкретный hotspot:
1. **P15.38a — GETTABUP/SETTABUP fast path:** устранить 3 из 5 `nodeLookup` calls на `global_arith`
2. **P15.38b — VJMP conditional expressions:** устранить boolean materialization в comparisons (28→9 instr/iter на `comparisons`)
3. **P15.38c — Direct-store to locals:** устранить MOVE в assignment to local (2→1 instr на `s = s + i`)
4. **P15.38d — Immediate comparison opcodes:** добавить `eqi`/`lti`/`lei`/`gti`/`gei`/`eqk` (экономия 1 `LOADI` на comparison-with-constant)
5. **P15.38e — MMBIN metamethod hints:** вынести metamethod-check из arithmetic handlers в отдельный opcode (compact fast path, better i-cache)

**Tech Stack:** Zig 0.16.0, ReleaseFast build, `tools/perf_compare.py` для A/B-замеров.

**Спецификации/контекст:**
- README.md §«P15.36 perf-based hotspot analysis» — исходные hotspot-данные
- `docs/superpowers/plans/2026-07-18-performance-phase-p15.37.md` — предыдущая фаза
- `tools/perf/baseline-p15.37.json` — baseline для regression check
- Baseline parity gate: `python3 tools/testes_matrix.py` → 28/31 (без `_soft`/`_port`)
- Smoke gate: `for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f"; done`
- Microbench: `taskset -c 0 zig-out/bin/luazig tools/microbench.lua`
- Perf gate: `./tools/perf_compare.py`

---

## Файловая карта

| Файл | Роль | Затронут фазой |
|---|---|---|
| `src/lua/vm.zig` | GETTABUP/SETTABUP handlers (~line 7531), arithmetic handlers (7658-8427), EQ/LT/LE handlers (8475-8556), `rawGet`/`rawSet` | a, e |
| `src/lua/codegen_bc.zig` | `genComparison` (2021), `genIf` (3750), `genWhile` (3814), `genAndExp`/`genOrExp` (2881), `genAssign` (3340), `genSet` (3456), `genBinOp` (1748), `ExpDesc` (349) | b, c, d |
| `src/lua/bytecode.zig` | `Op` enum (86), `Instruction` packed struct (26) | d, e |
| `src/lua/ltable.zig` | `nodeLookup` (143), `keyHash` (97) | (не затронут — variant TKey отложен на P15.39) |

---

## Task a (P15.38a): GETTABUP/SETTABUP metatable fast path

**Контекст:** `global_arith` делает 5 `nodeLookup` calls per iteration (2 от GETTABUP + 3 от SETTABUP). GETFIELD/SETFIELD уже имеют fast path (`vm.zig:7580`, `7623`): если `obj.Table.metatable == null`, делают single `rawGet`/`rawSet`. GETTABUP/SETTABUP этого fast path **не имеют** — всегда идут через `tryPushBytecodeIndexMetamethod` + `indexValue`/`setIndexValue`.

### Task a1: GETTABUP fast path

**Files:**
- Modify: `src/lua/vm.zig::runBytecodeDispatch` `.gettabup` handler (~line 7531)

- [ ] **Step 1: Добавить metatable null-check fast path в `.gettabup`**

Текущий код (~line 7531):
```zig
.gettabup => {
    const env = cur_upvalues[b].value;
    const key = try self.bcConstToValue(cur_proto.k[c]);
    if (try self.tryPushBytecodeIndexMetamethod(...)) { continue :frame_loop; }
    regs[a] = try self.indexValue(env, key);
},
```

Новый:
```zig
.gettabup => {
    const env = cur_upvalues[b].value;
    const key = try self.bcConstToValue(cur_proto.k[c]);
    // P15.38a: PUC luaV_fastget fast path. Если env — table без metatable,
    // делаем single rawGet вместо двойного lookup (metamethod probe + indexValue).
    // См. GETFIELD handler (vm.zig:7580) — тот же pattern.
    if (env == .Table and env.Table.metatable == null) {
        regs[a] = self.rawGet(env.Table, key);
    } else {
        if (try self.tryPushBytecodeIndexMetamethod(...)) { continue :frame_loop; }
        regs[a] = try self.indexValue(env, key);
    }
},
```

- [ ] **Step 2: Build, parity gate**

Run: `zig build -Doptimize=ReleaseFast`
Run: `python3 tools/testes_matrix.py`
Expected: 28/31, без регрессий.

- [ ] **Step 3: Smoke gate**

Run: `for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo FAIL:$f; done`
Expected: нет FAIL.

### Task a2: SETTABUP fast path

**Files:**
- Modify: `src/lua/vm.zig::runBytecodeDispatch` `.settabup` handler (~line 7540)

- [ ] **Step 1: Добавить metatable null-check fast path в `.settabup`**

Текущий код (~line 7540):
```zig
.settabup => {
    const env = cur_upvalues[b].value;
    const key = try self.bcConstToValue(cur_proto.k[c]);
    const val = regs[a];
    if (try self.tryPushBytecodeNewIndexMetamethod(...)) { continue :frame_loop; }
    try self.setIndexValue(env, key, val);
},
```

Новый:
```zig
.settabup => {
    const env = cur_upvalues[b].value;
    const key = try self.bcConstToValue(cur_proto.k[c]);
    const val = regs[a];
    // P15.38a: PUC luaV_fastset fast path. Если env — table без metatable,
    // делаем single rawSet вместо тройного lookup (metamethod probe +
    // setIndexValue + rawSet). См. SETFIELD handler (vm.zig:7623).
    if (env == .Table and env.Table.metatable == null) {
        try self.rawSet(env.Table, key, val);
    } else {
        if (try self.tryPushBytecodeNewIndexMetamethod(...)) { continue :frame_loop; }
        try self.setIndexValue(env, key, val);
    }
},
```

- [ ] **Step 2: Build, parity gate, smoke gate**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py`
Run: `for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo FAIL:$f; done`
Expected: 28/31, нет FAIL.

- [ ] **Step 3: Замер improvement**

Run: `taskset -c 0 zig-out/bin/luazig tools/microbench.lua | grep global_arith`
Expected: global_arith 3.187s → ~2.5s (5 lookups → 2, ~2.5× reduction in nodeLookup calls).

- [ ] **Step 4: Perf re-check**

Run:
```bash
perf record -F 999 --call-graph lbr -o /tmp/perf-p1538a.data -- \
  taskset -c 0 zig-out/bin/luazig -e 'local N=50000000 g_count=0 for i=1,N do g_count=g_count+i end io.write(g_count.."\n")'
perf report -i /tmp/perf-p1538a.data --stdio --no-children -g none --percent-limit 1
```
Expected: `nodeLookup` share drops from 28% to ~12%.

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "perf(P15.38a): GETTABUP/SETTABUP metatable fast path (5→2 nodeLookup calls)"
```

---

## Task b (P15.38b): VJMP conditional expressions

**Контекст:** `genComparison` всегда материализует boolean (5 инструкций: `CMP + JMP + LOADTRUE + JMP + LOADFALSE`). PUC возвращает `VJMP` expdesc (2 инструкции: `CMP + JMP`). `ExpDesc` уже имеет `t_list`/`f_list` поля, но они **dead code** — не используются. `genIf`/`genWhile` вызывают `genExp(cond)` + `TEST` + `JMP` (7 инструкций для `if a < b`), PUC — 2 инструкции.

### Task b1: Добавить VJMP variant в ExpDesc

**Files:**
- Modify: `src/lua/codegen_bc.zig::ExpDesc` (~line 349)

- [ ] **Step 1: Добавить `jump` variant в `ExpDesc.Val`**

```zig
const ExpDesc = struct {
    val: Val = .{ .void = {} },
    t_list: i32 = 0,   // jump list for "true" targets (will be used now)
    f_list: i32 = 0,   // jump list for "false" targets (will be used now)
    const Val = union(enum) {
        void, nil, true, false,
        k: i32, k_int: i64, k_float: f64, k_str: []const u8,
        non_reloc: u8,
        local: struct { ridx: u8, vidx: i16 = 0 },
        upval: i32, const_local: i32,
        indexed: ..., index_i: ..., index_str: ..., index_up: ...,
        reloc: i32, call: i32, vararg: i32,
        /// P15.38b: PUC VJMP — conditional jump producing expression.
        /// `info` = PC of the conditional jump instruction.
        /// `t_list`/`f_list` track pending jumps for short-circuit.
        /// See lua-5.5.0/src/lcode.c:1160-1225 (luaK_goiftrue/goiffalse).
        jump: struct { info: i32 },
    };
};
```

- [ ] **Step 2: Реализовать jump-list helpers**

Добавить функции (PUC `luaK_concat`, `luaK_patchlist`, `luaK_patchtohere` analogs):

```zig
/// Concatenate jump list l2 into l1. PUC luaK_concat (lcode.c:182-193).
fn concatJumps(self: *Codegen, l1: *i32, l2: i32) void {
    if (l2 == NO_JUMP) return;
    if (l1.* == NO_JUMP) {
        l1.* = l2;
    } else {
        var list = l1.*;
        while (self.builder.getJumpTarget(list)) |next| {
            list = next;
        }
        self.builder.patchJumpTarget(list, l2);
    }
}

/// Patch all jumps in list to target current PC. PUC luaK_patchtohere.
fn patchListToHere(self: *Codegen, list: i32) void {
    if (list == NO_JUMP) return;
    const target = self.builder.pc();
    var l = list;
    while (l != NO_JUMP) {
        const next = self.builder.getJumpTarget(l) orelse NO_JUMP;
        self.builder.patchJumpTarget(l, target);
        l = next;
    }
}
```

(Точные имена методов `builder` зависят от `bytecode.zig::ProtoBuilder` — нужно проверить.)

- [ ] **Step 3: Реализовать `goiftrue` / `goiffalse`**

PUC `luaK_goiftrue` (lcode.c:1178-1199) и `luaK_goiffalse` (lcode.c:1205-1225):

```zig
/// Convert expdesc to "jump to here if FALSE" (i.e., produce false-list).
/// PUC luaK_goiftrue. For VJMP: negate condition, use as false-list.
/// For constants: no jump needed (always true). For others: TESTSET+JMP.
fn goIfTrue(self: *Codegen, e: *ExpDesc) Error!void {
    try self.dischargeVars(e);
    switch (e.val) {
        .jump => |j| {
            // Already a conditional jump — negate it.
            try self.negateCondition(j.info);
            concatJumps(self, &e.f_list, j.info);
        },
        .true, .k, .k_int, .k_float, .k_str => {
            // Always true — no false jump.
        },
        else => {
            // Materialize + TESTSET + JMP.
            const reg = try self.exp2anyreg(e);
            const jmp = try self.emitTestSetJump(reg, 0); // jump if false
            concatJumps(self, &e.f_list, jmp);
        },
    }
    patchListToHere(self, e.t_list);
    e.t_list = NO_JUMP;
}

/// Convert expdesc to "jump to here if TRUE" (i.e., produce true-list).
/// PUC luaK_goiffalse.
fn goIfFalse(self: *Codegen, e: *ExpDesc) Error!void {
    try self.dischargeVars(e);
    switch (e.val) {
        .jump => |j| {
            // Already a conditional jump — use as-is for true-list.
            concatJumps(self, &e.t_list, j.info);
        },
        .nil, .false => {
            // Always false — no true jump.
        },
        else => {
            const reg = try self.exp2anyreg(e);
            const jmp = try self.emitTestSetJump(reg, 1); // jump if true
            concatJumps(self, &e.t_list, jmp);
        },
    }
    patchListToHere(self, e.f_list);
    e.f_list = NO_JUMP;
}
```

### Task b2: genComparison возвращает VJMP

**Files:**
- Modify: `src/lua/codegen_bc.zig::genComparison` (~line 2021)

- [ ] **Step 1: Изменить genComparison для возврата ExpDesc с VJMP**

Текущий `genComparison` возвращает `u8` (register) и эмитит 5 инструкций. Новый — возвращает `ExpDesc` с `.jump` variant и эмитит 2 инструкции (`CMP + JMP`):

```zig
fn genComparisonExp(self: *Codegen, op: TokenKind, lhs: u8, rhs: u8, line: u32) Error!ExpDesc {
    // ... determine bc_op and operand order (existing logic) ...
    const invert: u8 = if (op == .NotEq) 1 else 0;
    self.freeReg2(rhs, lhs);
    // Emit CMP instruction (conditional jump to PC+1 if condition matches).
    _ = try self.builder.emitABC(bc_op, op_lhs, op_rhs, invert, line);
    // Emit JMP — this is the "false" jump (condition not met → skip).
    const jmp_pc = try self.emitJump(line);
    var ed = ExpDesc{};
    ed.val = .{ .jump = .{ .info = jmp_pc } };
    // The jump goes to "false" branch. t_list is empty (no "true" jump yet).
    ed.f_list = jmp_pc;
    return ed;
}
```

**IMPORTANT:** Это меняет сигнатуру. Нужно обновить все callers `genComparison` — но callers сейчас ожидают `u8`. Поэтому:
- Добавить `genComparisonExp` (возвращает ExpDesc) — для использования в condition context
- Оставить `genComparison` (возвращает `u8`) — для boolean materialization context (когда boolean реально нужен, e.g. `local x = a < b`)
- `genComparison` вызывает `genComparisonExp`, потом materializes: `exp2anyreg(&ed)`

- [ ] **Step 2: Build, проверить что существующие tests проходят**

Run: `zig build -Doptimize=ReleaseFast`
Run: `python3 tools/testes_matrix.py`
Expected: 28/31 (без регрессий — genComparison всё ещё materializes через wrapper).

### Task b3: genIf/genWhile используют VJMP

**Files:**
- Modify: `src/lua/codegen_bc.zig::genIf` (~line 3750)
- Modify: `src/lua/codegen_bc.zig::genWhile` (~line 3814)

- [ ] **Step 1: genIf использует goIfFalse вместо genExp+TEST**

Текущий (line 3750):
```zig
const cond = try self.genExp(n.cond);
_ = try self.builder.emitABC(.test_, cond, 0, 0, cond_line);
self.freeReg(cond);
const jmp_to_else = try self.emitJump(cond_line);
```

Новый:
```zig
var cond_ed = try self.genExpCond(n.cond); // returns ExpDesc (VJMP for comparisons)
try self.goIfFalse(&cond_ed); // produce "jump to else if false"
// cond_ed.f_list now has the jump to else-branch
// No TEST instruction needed!
try self.genBlock(n.then_block);
self.patchListToHere(cond_ed.f_list);
```

- [ ] **Step 2: genWhile использует goIfFalse**

Аналогично для `genWhile` (line 3814).

- [ ] **Step 3: Добавить `genExpCond` — condition-context expression generator**

```zig
/// Generate expression in condition context (for if/while/repeat).
/// Returns ExpDesc that may be VJMP (for comparisons) or materialized.
/// PUC luaK_infix/luaK_posfix pattern.
fn genExpCond(self: *Codegen, n: anytype) Error!ExpDesc {
    // For comparisons: return VJMP directly
    // For and/or: use jump-list concatenation
    // For other expressions: materialize and return non_reloc
}
```

- [ ] **Step 4: Build, parity gate**

Run: `zig build -Doptimize=ReleaseFast`
Run: `python3 tools/testes_matrix.py`
Expected: 28/31. Особенно важны: `constructs.lua` (условия), `locals.lua` (scoping), `calls.lua`.

- [ ] **Step 5: Smoke gate**

Run: `for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo FAIL:$f; done`
Expected: нет FAIL.

- [ ] **Step 6: Замер improvement**

Run: `taskset -c 0 zig-out/bin/luazig tools/microbench.lua | grep -E 'branch_loop|comparisons'`
Expected: branch_loop 2.576s → ~1.8s, comparisons 4.112s → ~1.5s.

- [ ] **Step 7: Dump bytecode для верификации**

Run: `zig-out/bin/luazig --dump-bytecode -e 'for i=1,n do if i<n then s=s+1 end end'`
Expected: нет `LOADTRUE`/`LOADFALSE` в condition context.

- [ ] **Step 8: Commit**

```bash
git add src/lua/codegen_bc.zig
git commit -m "perf(P15.38b): VJMP conditional expressions (comparisons 28→9 instr/iter)"
```

### Task b4: genAndExp/genOrExp используют jump-lists

**Files:**
- Modify: `src/lua/codegen_bc.zig::genAndExp` (~line 2881)
- Modify: `src/lua/codegen_bc.zig::genOrExp` (~line 2902)

- [ ] **Step 1: genAndExp использует goIfTrue + concatJumps**

Текущий (line 2881): `MOVE dst, lhs; TEST dst; JMP; <gen rhs>; MOVE dst, rhs`

Новый (PUC `luaK_posfix` OPR_AND pattern):
```zig
fn genAndExpExp(self: *Codegen, lhs_ed: *ExpDesc, rhs_ed: ExpDesc) Error!ExpDesc {
    // PUC: luaK_infix(OPR_AND) calls goIfTrue(lhs) — jump if false to end.
    // luaK_posfix: concat lhs.f_list into rhs.f_list.
    try self.goIfTrue(lhs_ed);
    concatJumps(self, &rhs_ed.f_list, lhs_ed.f_list);
    return rhs_ed;
}
```

- [ ] **Step 2: genOrExp использует goIfFalse + concatJumps**

Аналогично для OR (PUC `luaK_posfix` OPR_OR pattern).

- [ ] **Step 3: Build, parity, smoke, commit**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py`
Run: `for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo FAIL:$f; done`
Expected: 28/31, нет FAIL.

```bash
git add src/lua/codegen_bc.zig
git commit -m "perf(P15.38b): and/or via jump-list concatenation (eliminates MOVE+TEST)"
```

---

## Task c (P15.38c): Direct-store to locals

**Контекст:** `genAssign` вызывает `genExp(rhs)` который выделяет temp register, потом `genSet` эмитит `MOVE local_reg, temp_reg`. `s = s + i` → `ADD tmp, s, i; MOVE s, tmp` (2 instr). PUC пишет напрямую: `ADD s, s, i` (1 instr) через `luaK_storevar` → `exp2reg(fs, ex, var->u.var.ridx)`.

### Task c1: Добавить destination hint в genBinOp

**Files:**
- Modify: `src/lua/codegen_bc.zig::genBinOp` (~line 1748)

- [ ] **Step 1: Добавить optional destination parameter**

Текущий (line 1800): `const dst = try self.allocReg();`

Новый:
```zig
fn genBinOp(self: *Codegen, n: anytype, line: u32, dst_hint: ?u8) Error!u8 {
    // ... existing logic ...
    const dst = if (dst_hint) |hint| hint else try self.allocReg();
    _ = try self.builder.emitABC(op, dst, lhs_reg, rhs_reg, line);
    return dst;
}
```

- [ ] **Step 2: Добавить `exp2reg` — discharge ExpDesc directly to target register**

PUC `exp2reg` (lcode.c:1080-1090):
```zig
/// Discharge expression directly into target register.
/// PUC luaK_exp2nextreg / exp2reg. Avoids MOVE when expression
/// can write directly to target.
fn exp2reg(self: *Codegen, e: *ExpDesc, reg: u8) Error!void {
    try self.dischargeVars(e);
    switch (e.val) {
        .non_reloc => |r| {
            if (r != reg) {
                _ = try self.builder.emitABC(.move, reg, r, 0, 0, ...);
            }
        },
        .reloc => |pc| {
            // Patch the instruction's A field to write to `reg` directly.
            self.builder.patchInstA(pc, reg);
        },
        .local => |l| {
            if (l.ridx != reg) {
                _ = try self.builder.emitABC(.move, reg, l.ridx, 0, 0, ...);
            }
        },
        // ... other cases: materialize into reg ...
    }
    e.val = .{ .non_reloc = reg };
}
```

### Task c2: genAssign передаёт local's register как hint

**Files:**
- Modify: `src/lua/codegen_bc.zig::genAssign` (~line 3340)
- Modify: `src/lua/codegen_bc.zig::genSet` (~line 3456)

- [ ] **Step 1: genSet для VLOCAL вызывает exp2reg напрямую**

Текущий genSet (line 3475): `_ = try self.builder.emitABC(.move, reg, val_reg, 0, line);`

Новый (PUC `luaK_storevar` VLOCAL case):
```zig
.Name => |n| {
    if (self.lookupLocal(name)) |reg| {
        // P15.38c: PUC luaK_storevar VLOCAL — discharge directly to local's register.
        // Avoids the MOVE that genExp+genSet would emit.
        try self.exp2reg(&rhs_ed, reg);
        return;
    }
    // ... upvalue/global cases ...
},
```

- [ ] **Step 2: genAssign передаёт destination hint**

Изменить `genAssign` чтобы для single-assignment to local он передавал local's register как hint в `genExp`/`genBinOp`:

```zig
fn genAssign(self: *Codegen, n: anytype, line: u32) Error!bool {
    if (n.lhs.len == 1 and n.rhs.len == 1) {
        // P15.38c: If LHS is a local, pass its register as destination hint.
        const dst_hint: ?u8 = switch (n.lhs[0].node) {
            .Name => |nn| if (self.lookupLocal(nn.name)) |r| r else null,
            else => null,
        };
        var rhs_ed = try self.genExpDesc(n.rhs[0]);
        try self.genSet(n.lhs[0], &rhs_ed, store_line);
        return false;
    }
    // ... multi-assign ...
}
```

- [ ] **Step 3: Build, parity gate**

Run: `zig build -Doptimize=ReleaseFast`
Run: `python3 tools/testes_matrix.py`
Expected: 28/31. Особенно: `locals.lua`, `closure.lua` (captured locals), `calls.lua`.

- [ ] **Step 4: Smoke gate**

Run: `for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo FAIL:$f; done`
Expected: нет FAIL.

- [ ] **Step 5: Замер improvement**

Run: `taskset -c 0 zig-out/bin/luazig tools/microbench.lua | grep -E 'int_arith|branch_loop|comparisons'`
Expected: int_arith 0.841s → ~0.7s (3→2 instr/iter), branch_loop экономия 2 MOVE/iter.

- [ ] **Step 6: Dump bytecode для верификации**

Run: `zig-out/bin/luazig --dump-bytecode -e 'local s=0 for i=1,n do s=s+i end'`
Expected: `ADD s, s, i` напрямую (нет `MOVE s, tmp`).

- [ ] **Step 7: Commit**

```bash
git add src/lua/codegen_bc.zig
git commit -m "perf(P15.38c): direct-store to locals (eliminates MOVE in assignment)"
```

---

## Task d (P15.38d): Immediate comparison opcodes

**Контекст:** Для `i % 2 == 0` эмитится `LOADI 7 0` + `EQ 6 7 0` (2 instr). PUC имеет `EQI 5 0 0` (1 instr). Аналогично `LTI`/`LEI`/`GTI`/`GEI` для `<`/`<=`/`>`/`>=` с константой.

### Task d1: Добавить opcodes в Op enum

**Files:**
- Modify: `src/lua/bytecode.zig::Op` (~line 86)

- [ ] **Step 1: Добавить immediate comparison opcodes**

```zig
pub const Op = enum(u8) {
    // ... existing opcodes ...
    /// P15.38d: PUC EQI/LTI/LEI/GTI/GEI — compare R[A] vs signed immediate sB.
    /// if ((R[A] == sB) != (C!=0)) then pc++  (skip next JMP)
    eqi,   // R[A] == sB
    lti,   // R[A] <  sB
    lei,   // R[A] <= sB
    gti,   // R[A] >  sB
    gei,   // R[A] >= sB
    /// P15.38d: PUC EQK — compare R[A] vs K[B] (constant).
    eqk,   // R[A] == K[B]
    // ...
};
```

- [ ] **Step 2: Build, проверить что enum compiles**

Run: `zig build`
Expected: без ошибок.

### Task d2: Codegen — использовать immediate comparisons

**Files:**
- Modify: `src/lua/codegen_bc.zig::genComparisonExp` (from Task b2)

- [ ] **Step 1: Расширить constBinOpInfo для comparisons**

В `genComparisonExp`, если RHS — small integer constant, использовать `eqi`/`lti`/`lei`/`gti`/`gei` вместо `LOADI` + `EQ`/`LT`/`LE`:

```zig
fn genComparisonExp(self: *Codegen, op: TokenKind, lhs: u8, rhs_ed: ExpDesc, line: u32) Error!ExpDesc {
    // P15.38d: If RHS is a small integer constant, use immediate comparison.
    if (rhs_ed.val == .k_int) {
        const imm: i8 = @intCast(rhs_ed.val.k_int); // must fit in sB
        const bc_op: bc.Op = switch (op) {
            .Eq => .eqi,
            .Lt => .lti,
            .Le => .lei,
            .Gt => .gti,
            .Ge => .gei,
            else => unreachable,
        };
        _ = try self.builder.emitABC(bc_op, lhs, @bitCast(imm), invert, line);
        // ... emit JMP ...
    } else if (rhs_ed.val == .k) {
        // Use EQK for constant comparison
        _ = try self.builder.emitABC(.eqk, lhs, rhs_ed.val.k, invert, line);
    } else {
        // Existing register-register comparison
        _ = try self.builder.emitABC(bc_op, lhs, rhs_reg, invert, line);
    }
}
```

- [ ] **Step 2: Build, parity gate**

Run: `zig build -Doptimize=ReleaseFast`
Run: `python3 tools/testes_matrix.py`
Expected: 28/31.

### Task d3: VM handlers для immediate comparisons

**Files:**
- Modify: `src/lua/vm.zig::runBytecodeDispatch` (~line 8475, near EQ/LT/LE handlers)

- [ ] **Step 1: Реализовать `.eqi`/`.lti`/`.lei`/`.gti`/`.gei` handlers**

```zig
.eqi => {
    const ra = regs[a];
    const sb: i64 = @as(i64, @bitCast(@as(i8, @bitCast(b))));
    const match = if (ra == .Int) ra.Int == sb
                  else if (ra == .Num) ra.Num == @as(f64, @floatFromInt(sb))
                  else false;
    if (match != (c != 0)) pc += 1; // skip next JMP
},
.lti => {
    const ra = regs[a];
    const sb: i64 = @as(i64, @bitCast(@as(i8, @bitCast(b))));
    const match = if (ra == .Int) ra.Int < sb
                  else if (ra == .Num) ra.Num < @as(f64, @floatFromInt(sb))
                  else false; // metamethod slow path
    if (match != (c != 0)) pc += 1;
},
// ... lei, gti, gei similarly ...
```

- [ ] **Step 2: Реализовать `.eqk` handler**

```zig
.eqk => {
    const ra = regs[a];
    const kb = try self.bcConstToValue(cur_proto.k[b]);
    const match = luaValueEq(ra, kb); // needs proper equality check
    if (match != (c != 0)) pc += 1;
},
```

- [ ] **Step 3: Build, parity, smoke**

Run: `zig build -Doptimize=ReleaseFast && python3 tools/testes_matrix.py`
Run: `for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo FAIL:$f; done`
Expected: 28/31, нет FAIL.

- [ ] **Step 4: Замер improvement**

Run: `taskset -c 0 zig-out/bin/luazig tools/microbench.lua | grep -E 'branch_loop|comparisons'`
Expected: branch_loop экономия 1 LOADI per `== 0`, comparisons экономия several LOADIs.

- [ ] **Step 5: Commit**

```bash
git add src/lua/bytecode.zig src/lua/codegen_bc.zig src/lua/vm.zig
git commit -m "perf(P15.38d): immediate comparison opcodes (eqi/lti/lei/gti/gei/eqk)"
```

---

## Task e (P15.38e): MMBIN metamethod hints

**Контекст:** Каждый arithmetic opcode инлайнит metamethod-check через `tryPushBytecodeBinaryMetamethod`. PUC выносит это в отдельный `MMBIN` opcode, который skip'ается на fast path через `pc++`.

### Task e1: Добавить MMBIN opcodes

**Files:**
- Modify: `src/lua/bytecode.zig::Op` (~line 86)

- [ ] **Step 1: Добавить `mmbin`/`mmbini`/`mmbink`**

```zig
pub const Op = enum(u8) {
    // ... existing ...
    /// P15.38e: PUC MMBIN — metamethod hint after arith/bitwise op.
    /// A = first operand register, B = second operand register, C = TMS event.
    /// Skipped on fast path (pc++ in arith handler). Executed on type failure.
    mmbin,
    /// P15.38e: PUC MMBINI — A = R[A], sB = signed immediate, C = TMS event.
    mmbini,
    /// P15.38e: PUC MMBINK — A = R[A], B = K[B] constant, C = TMS event.
    mmbink,
};
```

### Task e2: Codegen — эмитить MMBIN после arith ops

**Files:**
- Modify: `src/lua/codegen_bc.zig::genBinOp` (~line 1748)

- [ ] **Step 1: Эмитить MMBIN после каждого arithmetic/bitwise op**

```zig
fn genBinOp(self: *Codegen, n: anytype, line: u32, dst_hint: ?u8) Error!u8 {
    // ... emit ADD/SUB/MUL/etc. ...
    _ = try self.builder.emitABC(op, dst, lhs_reg, rhs_reg, line);
    // P15.38e: Emit MMBIN hint for metamethod fallback.
    const tms_event: u8 = binOpToTms(n.op); // TM_ADD=0, TM_SUB=1, etc.
    _ = try self.builder.emitABC(.mmbin, dst, lhs_reg, tms_event, line);
    return dst;
}
```

Аналогично для K/I variants — `mmbink`/`mmbini`.

### Task e3: VM — arithmetic handlers делают pc++ на success

**Files:**
- Modify: `src/lua/vm.zig::runBytecodeDispatch` arithmetic handlers (7658-8427)

- [ ] **Step 1: ADD handler — pc++ на fast path, fall through to MMBIN на failure**

Текущий (7658):
```zig
.add => {
    if (lb == .Int and rc == .Int) {
        regs[a] = .{ .Int = lb.Int +% rc.Int };
    } else if (...) {
        // ... numeric fast paths ...
    } else {
        // Slow path: inlined metamethod check
        if (try self.tryPushBytecodeBinaryMetamethod(...)) { continue :frame_loop; }
        // ...
    }
},
```

Новый:
```zig
.add => {
    if (lb == .Int and rc == .Int) {
        regs[a] = .{ .Int = lb.Int +% rc.Int };
        pc += 1; // P15.38e: skip MMBIN on fast path
    } else if (lb == .Num and rc == .Num) {
        regs[a] = .{ .Num = lb.Num + rc.Num };
        pc += 1;
    } else if (...) {
        // ... numeric coercion fast paths ...
        pc += 1;
    } else {
        // Slow path: fall through to MMBIN (next instruction)
        // Do NOT pc++ — MMBIN will handle metamethod
    }
},
```

- [ ] **Step 2: Реализовать `.mmbin`/`.mmbini`/`.mmbink` handlers**

```zig
.mmbin => {
    // P15.38e: Metamethod hint. Reached only when arith op failed (non-numeric operands).
    // C = TMS event (TM_ADD, TM_SUB, etc.)
    const event: TmsEvent = @enumFromInt(c);
    const lhs = regs[a];
    const rhs = regs[b];
    // Look up metamethod and call it
    if (try self.tryPushBytecodeBinaryMetamethod(exec_frames, parent_index, lhs, rhs, event)) {
        continue :frame_loop;
    }
    // No metamethod — raise type error
    return self.fail("attempt to perform arithmetic on a {s} value", .{lhs.typeName()});
},
```

- [ ] **Step 3: Обновить ВСЕ 14 arithmetic/bitwise handlers**

Применить тот же pattern (`pc++` на fast path, fall through на slow) к: `.sub`, `.mul`, `.div`, `.mod`, `.pow`, `.idiv`, `.band`, `.bor`, `.bxor`, `.shl`, `.shr`, `.unm`, `.bnot`.

- [ ] **Step 4: Build, parity gate**

Run: `zig build -Doptimize=ReleaseFast`
Run: `python3 tools/testes_matrix.py`
Expected: 28/31. Особенно: `constructs.lua` (metamethods), `events.lua`, `calls.lua`.

- [ ] **Step 5: Smoke gate**

Run: `for f in tests/smoke/*.lua; do zig-out/bin/luazig "$f" >/dev/null 2>&1 || echo FAIL:$f; done`
Expected: нет FAIL.

- [ ] **Step 6: Замер improvement**

Run: `taskset -c 0 zig-out/bin/luazig tools/microbench.lua | grep -E 'int_arith|mixed_arith|float_arith|metamethod_add'`
Expected: modest improvement на arithmetic workloads (compact handlers, better i-cache).

- [ ] **Step 7: Perf re-check**

Run:
```bash
perf record -F 999 --call-graph lbr -o /tmp/perf-p1538e.data -- \
  taskset -c 0 zig-out/bin/luazig -e 'local N=50000000 local s=0 for i=1,N do s=s+i end io.write(s.."\n")'
perf report -i /tmp/perf-p1538e.data --stdio --no-children -g none --percent-limit 1
```
Expected: arithmetic handlers smaller, better i-cache utilization.

- [ ] **Step 8: Commit**

```bash
git add src/lua/bytecode.zig src/lua/codegen_bc.zig src/lua/vm.zig
git commit -m "perf(P15.38e): MMBIN metamethod hints (pc++ skip on fast path)"
```

---

## Финальные шаги после всех фаз

- [ ] **Step 1: Обновить baseline**

Run: `./tools/perf_compare.py --update-baseline`
Это запишет новые результаты в `tools/perf/baseline-p15.37.json` (или новый `baseline-p15.38.json`).

- [ ] **Step 2: Обновить microbench таблицу в README**

Добавить колонку P15.38 с новыми числами для всех 16 workloads.

- [ ] **Step 3: Пересчитать geomean**

Run: `python3 -c "import math, json; d=json.load(open('tools/perf/baseline-p15.37.json')); r=d['ratios']; print(f'Geomean: {math.exp(sum(math.log(v) for v in r.values())/len(r)):.2f}x')"`
Ожидаемый target: geomean ≤3× (с 4.77×).

- [ ] **Step 4: Обновить §«P15.36 perf-based hotspot analysis»**

Добавить колонку «P15.38 fix» с новыми perf share numbers.

- [ ] **Step 5: Обновить §P15.38 в README**

Отметить все задачи (a/b/c/d/e) как выполненные с результатами.

- [ ] **Step 6: Финальный commit**

```bash
git add README.md tools/perf/
git commit -m "docs(P15.38): close codegen+dispatch+table perf phase, geomean 4.77x→<3x"
```

---

## Проверка спеки (self-review)

**Spec coverage:**
- Hotspot #1 (instruction-count bound dispatch) → Tasks b, c, d, e
  - VJMP conditional expressions (b) — устраняет boolean materialization
  - Direct-store to locals (c) — устраняет MOVE в assignment
  - Immediate comparison opcodes (d) — устраняет LOADI перед comparison
  - MMBIN metamethod hints (e) — compact arithmetic handlers
- Hotspot #2 (nodeLookup ~28% на global_arith) → Task a
  - GETTABUP/SETTABUP fast path (a) — 5→2 lookups per iteration
- variant TKey (48B→32B Node) — ОТЛОЖЕНО на P15.39+ (user decision)

**Placeholder scan:** Все шаги содержат конкретный код или ссылки на PUC source.

**Критерии закрытия P15.38:**
- Geomean ≤3×
- 28/31 parity, без регрессий
- Все smoke tests pass
- baseline обновлен
- README обновлён с новыми числами

**Риски:**
- Task b (VJMP) — самый сложный, меняет codegen architecture. Может потребовать несколько итераций.
- Task e (MMBIN) — затрагивает 14 handlers, много механических изменений. Высокий риск regression в metamethod paths.
- Если geomean не достигнет ≤3× после всех задач, variant TKey (P15.39) — следующий шаг.
