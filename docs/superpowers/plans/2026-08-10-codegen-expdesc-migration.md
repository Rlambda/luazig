# Codegen ExpDesc Migration: Eliminate Instruction Inflation

> **STATUS: COMPLETE** — All 7 tasks done (2026-08-10). Old `genExp` + `genNameValue`
> deleted (~265 lines). 8 inflated lines remain (structural: TESTSET opcode
> missing, SELF receiver-clobber guard). Geomean 2.67x (stable). Matrix 30/31,
> smoke 49/49, leakbench 25/25.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Problem

The codegen has **two parallel** expression compilation paths:

| | NEW (`genExpDesc`) | OLD (`genExp`) |
|---|---|---|
| Names | `.local = {ridx}` — lazy, no MOVE | `genNameValue` → always MOVE to fresh reg |
| `t[k]` | `.indexed` → GETTABLE, A patched | genExp(t) + genExp(k) + GETTABLE in temp |
| `t[1]` | `.index_i` → GETI | genExp(t) + LOADI + GETTABLE (never GETI!) |
| `t.f` | `.index_str` → GETFIELD | genExp(t) + GETFIELD in temp |
| Result | relocatable: A patched → 0 MOVE | always temp + MOVE |

The migration was started but never finished. 29 `genExp` call sites remain.

### Measured Impact

```
s = arr[key]    PUC: 1 instr     luazig: 4 instrs   (4x inflation)
s = arr[1]      PUC: 1 (GETI)    luazig: 4 (no GETI, GETTABLE+LOADI)
s = arr.foo     PUC: 1           luazig: 3
t.f()           PUC: 2           luazig: 3 (extra MOVE of table)
```

## Goal

1. Migrate ALL `genExp` callers to `genExpDesc` / `genExpNextReg`.
2. Make `genExpDesc` self-sufficient (no `genExp` fallback).
3. Delete the old `genExp` function and `genNameValue`.
4. Verify: codegen parity with PUC, no test regressions, perf improvement.

---

## Task 1: Build `tools/codegen_compare.py`

### What

Python script that compares bytecode instruction counts between PUC `luac -l -l`
and `luazig --dump-bytecode` for canonical Lua patterns.

### Spec

**Input:** Directory of `.lua` files (default: `tests/codegen/`) or a single file.

**For each file:**
1. Compile with `lua-5.5.0/src/luac -l -l <file>` (PUC)
2. Compile with `zig-out/bin/luazig --dump-bytecode <file>` (luazig)
3. Parse both listings into `[(pc, source_line, opcode, operands)]`
4. Group by `source_line`
5. Compare instruction count per source line

**Output format:**
```
=== tests/codegen/assign_index.lua ===
  L3  PUC: 1 (GETTABLE)         zig: 4 (MOVE,MOVE,GETTABLE,MOVE)  ❌ 4x
  L4  PUC: 1 (GETI)             zig: 4 (MOVE,LOADI,GETTABLE,MOVE) ❌ 4x
  L5  PUC: 1 (GETFIELD)         zig: 3 (MOVE,GETFIELD,MOVE)       ❌ 3x

Summary: PUC 3, zig 11 (3.7x) — 3 inflated lines
```

**Flags:**
- `--fail-on-inflation`: exit 1 if any line has zig_count > puc_count
- `--quiet`: only show inflated lines

**Parsing regex:** Both PUC and luazig use tab-separated format:
```
<pc>\t[<line>]\t<OPCODE>\t<operands>
```
Regex: `r'\s*(\d+)\s*\[(\d+)\]\s*(\w+)\s*(.*)'`

### Test patterns

Create `tests/codegen/` with these files:

**`assign_index.lua`** — assignment to existing local (currently INFLATED):
```lua
local arr, key = {}, 1
local s
s = arr[key]
s = arr[1]
s = arr.foo
```

**`local_index.lua`** — local declaration (currently OK, parity):
```lua
local arr, key = {}, 1
local a = arr[key]
local b = arr[1]
local c = arr.foo
```

**`call_expr.lua`** — function call expressions:
```lua
local t = {}
local f = t.f
local x = f()
local y = t.m()
local z = t[x]
```

**`method_call.lua`** — method calls with args:
```lua
local o, a, b = {}, 1, 2
o:m()
o:m(a)
o:m(a, b)
o:m(o.k)
```

**`and_or.lua`** — logical operators in value context:
```lua
local a, b = 1, 2
local x = a and b
local y = a or b
local z = a.k and b.k
```

### Acceptance

- Tool runs and produces output for all pattern files
- `--fail-on-inflation` exits non-zero on current master (before fixes)
- After migration, `--fail-on-inflation` exits zero (or minimal remaining)

---

## Task 2: Migrate genAssign to genExpDesc

### What

Replace `genExp` + `genSet` with `genExpDesc` + `discharge2reg(local_reg)` for
non-arithmetic RHS in `genAssign`.

### Location

`src/lua/codegen_bc.zig`, function `genAssign` (L5685).

### Change 1: L5769 — local assignment RHS (non-arithmetic)

**Before:**
```zig
                        // Other RHS: genExp + MOVE (via genSet).
                        // ... (comments about same-local check)
                        if (n.rhs[0].node == .Name) {
                            const rhs_name = n.rhs[0].node.Name.slice(self.source);
                            if (self.lookupLocal(rhs_name)) |rhs_reg| {
                                if (rhs_reg == local_reg) return false;
                            }
                        }
                        const rhs_reg = try self.genExp(n.rhs[0]);
                        try self.genSet(n.lhs[0], rhs_reg, false, store_line);
                        self.freeReg(rhs_reg);
                        return false;
```

**After:**
```zig
                        // Other RHS: discharge ExpDesc directly into the
                        // local's register. For relocatable instructions
                        // (GETTABLE, GETI, GETFIELD), this patches A to
                        // local_reg — no MOVE needed. For non-relocatable
                        // (call results, other locals), a single MOVE is
                        // emitted by discharge2reg. Mirrors PUC's
                        // luaK_storevar VLOCAL → exp2reg(fs, ex, var->u.var.ridx).
                        if (n.rhs[0].node == .Name) {
                            const rhs_name = n.rhs[0].node.Name.slice(self.source);
                            if (self.lookupLocal(rhs_name)) |rhs_reg| {
                                if (rhs_reg == local_reg) return false;
                            }
                        }
                        var rhs_ed = try self.genExpDesc(n.rhs[0]);
                        try self.discharge2reg(&rhs_ed, local_reg);
                        return false;
```

### Change 2: L5798 — non-local simple assignment RHS

**Before:**
```zig
            } else {
                const rhs_reg = try self.genExp(n.rhs[0]);
                try self.genSet(n.lhs[0], rhs_reg, false, store_line);
                self.freeReg(rhs_reg);
            }
```

This is the non-table, non-local RHS path (e.g. global assignment or upvalue
assignment). After migration, this path should use `genExpNextReg`:

**After:**
```zig
            } else {
                // For non-table, non-simple-local LHS (global/upvalue),
                // compile RHS into a register via the NEW path.
                var rhs_ed = try self.genExpDesc(n.rhs[0]);
                const rhs_reg = try self.exp2nextreg(&rhs_ed);
                try self.genSet(n.lhs[0], rhs_reg, false, store_line);
                self.freeReg(rhs_reg);
            }
```

### Acceptance

- `codegen_compare.py tests/codegen/assign_index.lua` shows parity (1:1)
- `testes_matrix.py --testc` — no regressions
- `smoke_compare.py --no-build` — no regressions

---

## Task 3: Migrate genCall + genMethodCall + genTailCall

### What

Migrate function expression, receiver, and arguments from `genExp` to
`genExpDesc` / `genExpNextReg`.

### Change 1: genCall func expression (L4464)

**Before:**
```zig
        var func_reg = try self.genExp(call_node.func);
```

**After:**
```zig
        var func_ed = try self.genExpDesc(call_node.func);
        var func_reg = try self.exp2anyreg(&func_ed);
```

This makes `t.f()` compile GETFIELD directly from t's register (no MOVE of t).

### Change 2: genMethodCall receiver (L4556)

**Before:**
```zig
        var obj_reg = try self.genExp(mc.receiver);
```

**After:**
```zig
        var obj_ed = try self.genExpDesc(mc.receiver);
        var obj_reg = try self.exp2anyreg(&obj_ed);
```

### Change 3: genMethodCall args (L4584-4610)

Replace the `genExp(arg)` + conditional MOVE loop with `genExpNextReg(arg)`,
matching the pattern `genCall` already uses for its args (L4476-4511).

**Before (L4584-4610):**
```zig
        for (mc.args, 0..) |arg, i| {
            const expected: u8 = @intCast(@as(usize, obj_reg) + 2 + i);
            self.freereg = expected;
            const is_last = (i + 1 == mc.args.len);
            if (is_last) {
                switch (arg.node) {
                    .Call, .MethodCall => _ = try self.genCallMulti(arg, line),
                    .Dots => { ... },
                    else => {
                        const r = try self.genExp(arg);
                        if (r != expected) {
                            try self.ensureFreeregAtLeast(expected + 1);
                            _ = try self.builder.emitABC(.move, expected, r, 0, arg.span.line);
                        }
                    },
                }
            } else {
                const r = try self.genExp(arg);
                if (r != expected) {
                    try self.ensureFreeregAtLeast(expected + 1);
                    _ = try self.builder.emitABC(.move, expected, r, 0, arg.span.line);
                }
            }
        }
```

**After (matching genCall's pattern at L4476-4511):**
```zig
        for (mc.args, 0..) |arg, i| {
            const expected: u8 = @intCast(@as(usize, obj_reg) + 2 + i);
            self.freereg = expected;
            const is_last = (i + 1 == mc.args.len);
            if (is_last) {
                switch (arg.node) {
                    .Call, .MethodCall => _ = try self.genCallMulti(arg, line),
                    .Dots => { ... },  // keep existing
                    else => {
                        const saved_hint = self.line_hint;
                        self.line_hint = arg.span.line;
                        _ = try self.genExpNextReg(arg);
                        self.line_hint = saved_hint;
                    },
                }
            } else {
                const saved_hint = self.line_hint;
                self.line_hint = arg.span.line;
                _ = try self.genExpNextReg(arg);
                self.line_hint = saved_hint;
            }
        }
```

### Change 4: genTailCall (L6420-6539)

Apply the SAME three changes to genTailCall:
- L6427: receiver → `genExpDesc` + `exp2anyreg` (MethodCall path)
- L6461/6469: MethodCall args → `genExpNextReg` pattern
- L6494: func expression → `genExpDesc` + `exp2anyreg` (Call path)
- L6517/6525: Call args → `genExpNextReg` pattern

### Acceptance

- `codegen_compare.py tests/codegen/call_expr.lua` shows parity or improvement
- `codegen_compare.py tests/codegen/method_call.lua` shows parity or improvement
- `testes_matrix.py --testc` — no regressions
- `smoke_compare.py --no-build` — no regressions

---

## Task 4: Migrate genAndExp + genOrExp

### What

Replace `genExp` + MOVE with `genExpDesc` + `discharge2reg(dst)` in the
value-preserving path of `genAndExp` and `genOrExp`.

### Change 1: genAndExp value path (L5131-5141)

**Before:**
```zig
        const dst = try self.allocReg();
        const lhs = try self.genExp(lhs_exp);
        _ = try self.builder.emitABC(.move, dst, lhs, 0, line);
        self.freeReg(lhs);
        _ = try self.builder.emitABC(.test_, dst, 0, 0, line);
        const jmp_pc = try self.emitJump(line);
        const rhs = try self.genExp(rhs_exp);
        _ = try self.builder.emitABC(.move, dst, rhs, 0, line);
        self.freeReg(rhs);
        self.patchJumpToHere(jmp_pc);
        return dst;
```

**After:**
```zig
        const dst = try self.allocReg();
        var lhs_ed = try self.genExpDesc(lhs_exp);
        try self.discharge2reg(&lhs_ed, dst);
        _ = try self.builder.emitABC(.test_, dst, 0, 0, line);
        const jmp_pc = try self.emitJump(line);
        var rhs_ed = try self.genExpDesc(rhs_exp);
        try self.discharge2reg(&rhs_ed, dst);
        self.patchJumpToHere(jmp_pc);
        return dst;
```

### Change 2: genOrExp value path (L5152-5161)

Same pattern: replace `genExp` + MOVE with `genExpDesc` + `discharge2reg(dst)`.

### Acceptance

- `codegen_compare.py tests/codegen/and_or.lua` shows improvement
- `testes_matrix.py --testc` — no regressions
- `smoke_compare.py --no-build` — no regressions

---

## Task 5: Make genExpDesc self-sufficient (eliminate genExp fallback)

### What

Currently `genExpDesc` falls to `genExp` for Call/MethodCall/Table/FuncDef/Dots
and for non-foldable UnOp/BinOp. Make it handle these directly.

### Change 1: genExpDesc `.Call` and `.MethodCall` (inside the `else` at L1999)

**Before (L1999-2003):**
```zig
            else => {
                // Fallback: use old genExp, wrap result as non_reloc.
                const reg = try self.genExp(e);
                return .{ .val = .{ .non_reloc = reg } };
            },
```

**After:**
```zig
            .Call => {
                const reg = try self.genCall(e, 1, e.span.line);
                return .{ .val = .{ .non_reloc = reg } };
            },
            .MethodCall => {
                const reg = try self.genMethodCall(e, 1, e.span.line);
                return .{ .val = .{ .non_reloc = reg } };
            },
            .Table => |t| {
                const reg = try self.genTable(t, e.span.line);
                return .{ .val = .{ .non_reloc = reg } };
            },
            .FuncDef => |fd| {
                const reg = try self.genFuncDef(fd, e.span.line);
                return .{ .val = .{ .non_reloc = reg } };
            },
            .Dots => {
                if (!self.is_vararg) {
                    self.setDiag(e.span, "vararg used in non-vararg function");
                    return error.CodegenError;
                }
                const va_reg = try self.allocReg();
                _ = try self.builder.emitABC(.vararg, va_reg, 2, 0, e.span.line);
                return .{ .val = .{ .non_reloc = va_reg } };
            },
```

Note: Check the actual function names for Table and FuncDef codegen — they may
be named differently (e.g., `genTableConstructor`, `genClosure`). Search for
the existing genExp `.Table` and `.FuncDef` cases to find the right function names.

### Change 2: genExpDesc `.BinOp` non-foldable (L1827)

**Before:**
```zig
                // Other binary ops (including and/or): materialize to a
                // register via genExp.
                const reg = try self.genExp(e);
                return .{ .val = .{ .non_reloc = reg } };
```

**After:**
```zig
                // Other binary ops (including and/or): materialize to a
                // register via genBinOp/genAndExp/genOrExp.
                const reg = if (n.op == .And)
                    try self.genAndExp(n.lhs, n.rhs, op_line)
                else if (n.op == .Or)
                    try self.genOrExp(n.lhs, n.rhs, op_line)
                else
                    try self.genBinOp(n, op_line, null);
                return .{ .val = .{ .non_reloc = reg } };
```

### Change 3: genExpDesc `.UnOp` non-foldable (L1841)

**Before:**
```zig
                // Other unary ops (-, ~, #): materialize to a register.
                const reg = try self.genExp(e);
                return .{ .val = .{ .non_reloc = reg } };
```

**After:**
```zig
                // Other unary ops (-, ~, #): materialize to a register.
                const reg = try self.genUnOp(n, op_line);
                return .{ .val = .{ .non_reloc = reg } };
```

Note: `genUnOp` still calls `genExp` internally for its operand. That will be
fixed in Task 6 when we delete genExp. For now, genUnOp needs to be migrated
to use genExpDesc for its operand.

### Change 4: Migrate genUnOp operand (L4155, L4175)

In `genUnOp`, replace `genExp(n.exp)` with `genExpDesc(n.exp)` + `exp2anyreg`:

**Before (L4155 and L4175):**
```zig
            const src = try self.genExp(n.exp);
```

**After:**
```zig
            var operand_ed = try self.genExpDesc(n.exp);
            const src = try self.exp2anyreg(&operand_ed);
```

### Change 5: genExpDesc .Index vararg key (L1906)

**Before:**
```zig
                        const key = try self.genExp(n.index);
```

**After:**
```zig
                        var key_ed = try self.genExpDesc(n.index);
                        const key = try self.exp2anyreg(&key_ed);
```

### Change 6: genExpCond fallbacks (L2087, L2100)

These are condition-context compilation for BinOp/UnOp. They call genExp for
complex sub-expressions. Replace with genExpDesc + exp2anyreg:

**Before:**
```zig
                const reg = try self.genExp(e);
```

**After:**
```zig
                var ed = try self.genExpDesc(e);
                const reg = try self.exp2anyreg(&ed);
```

### Acceptance

- `grep -n 'self\.genExp(' src/lua/codegen_bc.zig` returns ZERO matches
  outside of `genExp` itself (i.e., all callers migrated)
- `testes_matrix.py --testc` — no regressions
- `smoke_compare.py --no-build` — no regressions

---

## Task 6: Delete old genExp + genNameValue

### What

Remove the old `genExp` function and `genNameValue` function entirely.
They should have ZERO callers after Task 5.

### Steps

1. Verify: `grep -n 'self\.genExp(' src/lua/codegen_bc.zig` returns 0 matches
2. Verify: `grep -n 'genNameValue(' src/lua/codegen_bc.zig` returns 0 matches
3. Delete `fn genExp` (starts at L2356)
4. Delete `fn genNameValue` (starts at L2554)
5. Build: `zig build -Doptimize=ReleaseFast`
6. Run all tests

### What to delete

The old `genExp` function handles: Nil, True, False, Number, String, Name,
Paren, BinOp, UnOp, Field, Index, Call, MethodCall, Table, FuncDef, Dots.

After migration, ALL of these are handled by `genExpDesc`. The old function
is dead code.

`genNameValue` is only called by old `genExp`'s `.Name` case. Dead code.

### Acceptance

- `grep -n 'fn genExp(' src/lua/codegen_bc.zig` — only `genExpDesc`, 
  `genExpNextReg`, `genExpCond` remain
- `zig build -Doptimize=ReleaseFast` succeeds
- All tests pass

---

## Task 7: Final verification + perf measurement

### Steps

1. Build ReleaseFast: `zig build -Doptimize=ReleaseFast`
2. Run codegen_compare: `python3 tools/codegen_compare.py` — verify parity
3. Run matrix: `python3 tools/testes_matrix.py --testc` — 30/31 no regressions
4. Run smoke: `python3 tools/smoke_compare.py --no-build` — 49/49
5. Run perf: `python3 tools/perf_compare.py` — measure improvement
6. Run leakbench: `python3 tools/leak_bench.py --no-build` — 25/25
7. Update STATUS.md with results
8. Commit

### Expected perf improvement

- `string_loop`: should improve (array/hash access in loops)
- `array_access`: should improve significantly
- `hash_access`: should improve
- `field_access`: should improve
- `lua_calls`: should improve slightly (fewer MOVEs in call setup)
- `coroutine_yield`: may improve slightly
- geomean: expect -3% to -8% improvement
