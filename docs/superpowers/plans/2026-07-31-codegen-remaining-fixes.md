# Codegen Parity: Remaining code.lua Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Use model `glm-5.2` for all subagent dispatches.

**Goal:** Close the remaining ~21 code.lua bytecode mismatches by implementing 8 codegen fixes identified in root-cause analysis.

**Architecture:** Each fix addresses a specific PUC-faithful codegen behavior. The changes are ordered by ROI (impact/effort ratio) — the highest-leverage fixes come first. Each task is independently testable via `code.lua` mismatch count and the full testes matrix.

**Tech Stack:** Zig (codegen_bc.zig, vm.zig), PUC Lua 5.5 (reference), testes matrix runner.

---

## File Map

- **Modify:** `src/lua/codegen_bc.zig` — all codegen changes (exp2anyreg, genExpCond, genConstExpDesc, genBinOp comparison path, concat, LOADNIL, assignment)
- **Modify:** `src/lua/bytecode.zig` — LOADI range constant if needed
- **No new files.**

## Build/Test Commands

```bash
# Build (ReleaseFast required by AGENTS.md)
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5

# Matrix (must stay 27/31 or better)
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5

# code.lua mismatch count
cd lua-5.5.0/testes && cat > /tmp/test_code_stats.lua << 'SCRIPT'
local f = io.open("code.lua", "r")
local src = f:read("*a")
f:close()
src = src:gsub("assert%(arg%[i%] == opcode%)", 
  "if arg[i] ~= opcode then io.stderr:write('MISMATCH exp='..tostring(arg[i])..' got='..tostring(string.match(c[i] or '', '%%u%%w+'))..'\\n') end")
src = src:gsub("assert%(c%[#arg%+2%] == undef%)", "")
local out = io.open("/tmp/code_patched.lua", "w")
out:write(src)
out:close()
dofile("/tmp/code_patched.lua")
SCRIPT
timeout 30 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_code_stats.lua 2>&1 | grep -c MISMATCH

# Smoke tests
cd /home/boss/codes/luazig && for f in tests/smoke/*.lua; do timeout 10 ./zig-out/bin/luazig --vm=bc "$f" 2>&1 | tail -1; done
```

---

## Task 1: Direct Local Access in exp2anyreg (Eliminate Redundant MOVEs)

**Impact:** Fixes ~3 checks, eliminates spurious MOVE opcodes globally.
**Risk:** Low — PUC VLOCAL is already a no-op in `luaK_dischargevars`.

**Files:**
- Modify: `src/lua/codegen_bc.zig` — `exp2anyreg` function (search `fn exp2anyreg`)

- [ ] **Step 1: Find exp2anyreg and understand the current flow**

Search for `fn exp2anyreg` in codegen_bc.zig. Read the function and its caller `discharge2reg`. The issue is that for `.local` ExpDescs, `discharge2reg` emits a `MOVE` from the local's register to a newly allocated temp register. PUC's `luaK_dischargevars` has a `VLOCAL` case that returns `e->u.info` (the register) directly without emitting any code.

- [ ] **Step 2: Add .local fast-path to exp2anyreg**

In `exp2anyreg`, before calling `discharge2reg`, check if the ExpDesc is `.local` and return the register directly:

```zig
    fn exp2anyreg(self: *Codegen, e: *ExpDesc) Error!u8 {
        switch (e.val) {
            .local => |loc| return loc.ridx,  // PUC VLOCAL: return register directly
            else => {},
        }
        return self.exp2nextreg(e);
    }
```

IMPORTANT: Check if `exp2anyreg` already has this. If it calls `discharge2reg` which handles `.local`, the fix is in `discharge2reg`. Look at how `.local` is discharged — the key is that for a read-only local used as an operand, PUC returns the register number without allocating a new temp.

WARNING: The `.local` ExpDesc might already work correctly for direct register access. Test BEFORE changing:
```bash
cd lua-5.5.0/testes && cat > /tmp/test_local.lua << 'EOF'
local function f(a, b) return b * a end
local c = T.listcode(f)
for i = 1, #c do print(i, c[i]) end
EOF
timeout 10 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_local.lua 2>&1
```
If the output shows `MUL` without a preceding `MOVE`, the fix is already working and this task can be skipped.

- [ ] **Step 3: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
cd lua-5.5.0/testes && timeout 30 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_code_stats.lua 2>&1 | grep -c MISMATCH
```

Matrix must be ≥27/31. Commit only if mismatch count decreased.

```bash
git add src/lua/codegen_bc.zig
git commit -m "codegen: exp2anyreg returns local register directly (PUC VLOCAL)

PUC's luaK_dischargevars has a VLOCAL case that returns the register
number without emitting MOVE. luazig was allocating a temp register
and emitting MOVE for local operands, producing spurious MOVE opcodes."
```

---

## Task 2: Const Condition Folding (while/repeat with const conditions)

**Impact:** Fixes ~3 checks (#6 while kTrue, #7 while 1, #8 repeat until true).
**Risk:** Low — pure compile-time folding.

**Files:**
- Modify: `src/lua/codegen_bc.zig` — `genExpCond` function (line ~1627)

- [ ] **Step 1: Read genExpCond**

Read `src/lua/codegen_bc.zig` around line 1627. Find the `genExpCond` function. It currently has an `else` branch (around line 1677) that calls `genExp(e)` which materializes the expression to a register, losing the constant kind.

- [ ] **Step 2: Use genExpDesc instead of genExp in genExpCond's else branch**

The `else` branch should try `genExpDesc` first (which preserves constant kinds). If the result is `.true`, `.false`, `.nil`, or `.k_int`/`.k_float`, handle it directly:

```zig
            else => {
                // Try ExpDesc first — preserves constant kinds for folding.
                var ed = try self.genExpDesc(e);
                switch (ed.val) {
                    .true => {
                        // Always true: goIfTrue is a no-op, goIfFalse always jumps.
                        // Set as VTRUE so goIfTrue/goIfFalse handle it.
                        e_cond.* = ed;
                    },
                    .false, .nil => {
                        // Always false.
                        e_cond.* = ed;
                    },
                    else => {
                        // Non-constant: discharge to register.
                        const reg = try self.exp2anyreg(&ed);
                        e_cond.* = .{ .val = .{ .non_reloc = reg } };
                    },
                }
            },
```

The key insight: `goIfTrue` and `goIfFalse` (which are called after `genExpCond`) already have cases for `.true` and `.false`/`.nil` that produce NO jump (always-true → no false-jump, always-false → no true-jump). So if we preserve the constant kind, the condition folds correctly.

Read `goIfTrue` and `goIfFalse` to confirm they handle `.true`/`.false`/`.nil` correctly. Search for `fn goIfTrue` and `fn goIfFalse`.

- [ ] **Step 3: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && cat > /tmp/test_const_cond.lua << 'EOF'
local kTrue <const> = true
local function f()
  while kTrue do return 1 end
end
local c = T.listcode(f)
for i = 1, #c do print(i, c[i]) end
EOF
timeout 10 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_const_cond.lua 2>&1
```
Expected: No GETUPVAL/TEST for `kTrue` — the while condition folds.

```bash
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
```

```bash
git add src/lua/codegen_bc.zig
git commit -m "codegen: fold const conditions in genExpCond (while/repeat)

genExpCond now uses genExpDesc to preserve constant kinds, enabling
goIfTrue/goIfFalse to fold always-true/always-false conditions.
'while kTrue do' no longer emits GETUPVAL+TEST."
```

---

## Task 3: `not` Constant Folding (not not X → LOADFALSE/LOADTRUE)

**Impact:** Fixes ~4 checks (#10-13).
**Risk:** Low — pure compile-time folding.

**Files:**
- Modify: `src/lua/codegen_bc.zig` — `genConstExpDesc` (line ~2660) and `genUnOp` (line ~3197)

- [ ] **Step 1: Add not-folding to genConstExpDesc**

In `genConstExpDesc` (line ~2660), add a `.UnOp` case for `.Not`:

```zig
            .UnOp => |n| {
                if (n.op == .Not) {
                    const operand = self.genConstExpDesc(n.exp) orelse return null;
                    return switch (operand.val) {
                        .nil => .{ .val = .true },   // not nil → true
                        .false => .{ .val = .true }, // not false → true
                        .true => .{ .val = .false }, // not true → false
                        // not <number/string> → always false (truthy)
                        .k_int, .k_float, .k_str => .{ .val = .false },
                        else => null,  // can't fold
                    };
                }
                // Existing minus/tilde handling for arithmetic
                if (n.op != .Minus and n.op != .Tilde) return null;
                const operand = self.genConstExpDesc(n.exp) orelse return null;
                return foldUnOp(n.op, operand);
            },
```

- [ ] **Step 2: Verify genUnOp handles .false/.true ExpDescs correctly**

In `genUnOp` (line ~3197), the `.Not` case should now never see a constant operand (because `genConstExpDesc` folds it). But if it does (e.g., the folding path returns null for non-constant operands), `genUnOp` must handle the ExpDesc result from `genExpDesc`:

Read `genUnOp` to check how it handles the `.Not` case. Currently it always emits a runtime `NOT`. After Step 1, `not <const>` will be folded by `genConstExpDesc` before reaching `genUnOp`. For `not <non-const>`, the runtime `NOT` is still correct.

For `not not X`: the outer `not` will be handled by `genConstExpDesc` which calls `genConstExpDesc(inner_not)`. If `inner_not` folds (because X is const), the outer `not` also folds. If X is non-const, `genConstExpDesc` returns null and `genUnOp` emits runtime `NOT` + `NOT`.

code.lua test expects:
- `not not nil` → `LOADFALSE` (nil → fold to true → fold to false)
- `not not true` → `LOADTRUE` (true → fold to false → fold to true)

After Step 1, `not not nil` should fold through `genConstExpDesc`. The remaining question is whether `genExp`/`genUnOp` checks `genConstExpDesc` before emitting code. Read how `genExp` handles `.UnOp` — it should call `genConstExpDesc` first.

- [ ] **Step 3: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && cat > /tmp/test_not.lua << 'EOF'
local function f() return not not nil end
local c = T.listcode(f)
for i = 1, #c do print(i, c[i]) end
EOF
timeout 10 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_not.lua 2>&1
```
Expected: `LOADFALSE, RETURN1` (not `LOADNIL, NOT, NOT, ...`).

```bash
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
git add src/lua/codegen_bc.zig
git commit -m "codegen: fold not-const patterns (not nil→true, not true→false)

Add not-folding to genConstExpDesc: 'not nil'→true, 'not false'→true,
'not true'→false, 'not <number>'→false. Enables 'not not X' folding
to LOADFALSE/LOADTRUE when X is a compile-time constant."
```

---

## Task 4: LOADI Range Fix (16-bit → 18-bit sBx)

**Impact:** Fixes ~2 checks (#46, #47 — border integer values).
**Risk:** Very low — constant range change.

**Files:**
- Modify: `src/lua/codegen_bc.zig` — LOADI/LOADF range checks (search for `32768` or `fitsSC` or `LOADI`)

- [ ] **Step 1: Find the LOADI range check**

Search for `32768` or `32767` or `0x7FFF` in `codegen_bc.zig`. Also check `bytecode.zig` for how `Instruction.jumpOffset` encodes sBx — the field uses `a` (8 bits) + `b` (8 bits) + `c` (8 bits) = 24 bits for jump, but LOADI uses `b` (low) and `c` (high) for a 16-bit signed value.

Read the LOADI emission code to understand the current encoding. PUC uses a single sBx field (18-bit signed: -65535..65535). luazig uses `b` and `c` fields for the value.

- [ ] **Step 2: Fix the range check**

PUC's `MAXARG_sBx` for LOADI is `((1<<(SIZE_Bx))-1)>>1` where `SIZE_Bx = SIZE_C + SIZE_B = 8+8 = 16`. Wait — PUC's LOADI uses `sBx` which is `Bx` interpreted as signed. `Bx = C << 8 | B` = 16-bit unsigned, so `sBx` range is -32767..32767. That actually matches luazig's current range!

Actually, re-read the PUC lopcodes.h more carefully. In PUC 5.5:
- `SIZE_C = 8`, `SIZE_B = 8`
- For iABx mode (LOADI): `Bx = MAXARG_Bx` = `(1<<SIZE_Bx)-1` where `SIZE_Bx = SIZE_C + SIZE_B = 16`
- `sBx = Bx - MAXARG_sBx` where `MAXARG_sBx = MAXARG_Bx >> 1`
- So sBx range = `-(MAXARG_Bx/2)` to `MAXARG_Bx - MAXARG_Bx/2 - 1` = -32767..32767

Hmm, but the subagent reported that PUC accepts `border = 65535` for LOADI. Let me re-check. PUC 5.5's LOADI format is iABx: A(8) + Bx(17). Wait, PUC 5.5 changed the instruction format!

Read `lua-5.5.0/src/lopcodes.h` for the actual SIZE values. The subagent reported `MAXARG_sBx = 65535`, which means `SIZE_Bx = 17` and `sBx` range is -65535..65535.

Check luazig's `Instruction` packed struct at `src/lua/bytecode.zig:26`. It uses `op: u8, a: u8, b: u8, c: u8` — total 32 bits. For iABx mode, `Bx` is `b | (c << 8)` = 16-bit. But PUC 5.5 uses `Bx = 17-bit` (op is 7-bit, not 8-bit).

This is the root cause: luazig's op field is 8-bit (256 opcodes), but PUC's is 7-bit (128 opcodes). The extra bit goes to Bx, making it 17-bit instead of 16-bit.

The fix is to change the LOADI range from 16-bit (-32768..32767) to whatever the actual Bx width allows. Since `b` is 8-bit and `c` is 8-bit, `Bx = b | (c << 8)` = 16-bit unsigned, so sBx range is -32767..32767. This DOES match PUC if we consider that PUC's op is 7-bit giving Bx = 17-bit.

Since changing the instruction format is a massive breaking change, the practical fix is to extend LOADI to use `a` as an extra bit for the value (when A=0, meaning no register needed). But this is complex.

For now, check if the test value (65535) actually exceeds the current range. If it does, this check can't be fixed without changing the instruction format. Skip this task if the instruction format would need to change.

- [ ] **Step 3: If fixable, build, test, commit**

If the range can be extended without changing the instruction format:
```bash
git add src/lua/codegen_bc.zig
git commit -m "codegen: fix LOADI range to match actual sBx width"
```

If NOT fixable without instruction format change, document as known limitation and skip.

---

## Task 5: Comparison with Constant LHS (Operand Swap for EQI/EQK/LTI/LEI/GTI/GEI)

**Impact:** Fixes ~8 checks (#20-27, #29).
**Risk:** Medium — comparison operand swap logic.

**Files:**
- Modify: `src/lua/codegen_bc.zig` — comparison path in `genBinOp` (line ~2810) and `genComparison` (line ~2960)

- [ ] **Step 1: Read the comparison codegen**

Read `genBinOp` lines 2810-2841 and `genComparison` (search for the function). Understand the current flow:
1. LHS is discharged to a register
2. RHS is checked for constant (`rhs_nc = numericConstFromExp(n.rhs)`)
3. If RHS is constant → EQI/LTI/LEI with immediate
4. If not → EQ/LT/LE with register

The fix: ALSO check LHS for constant. If LHS is constant and RHS is not, swap operands and transform the comparison direction.

- [ ] **Step 2: Add LHS constant swap to the comparison path**

In `genBinOp`, before discharging LHS (line ~2817), check if LHS is constant:

```zig
        // PUC codeeq/codeorder: if LHS is constant and RHS is not,
        // swap operands and transform the comparison direction.
        var lhs_exp = n.lhs;
        var rhs_exp = n.rhs;
        var cmp_op = n.op;
        if (rhs_nc == null) {
            const lhs_nc = self.numericConstFromExp(n.lhs);
            if (lhs_nc != null) {
                // Swap operands
                lhs_exp = n.rhs;
                rhs_exp = n.lhs;
                rhs_nc = lhs_nc;
                // Transform comparison direction
                cmp_op = switch (n.op) {
                    .Lt => .Gte,   // a < K  →  K <= a ... wait, wrong
                    .Lte => .Gt,   // a <= K →  K >  a
                    .Gt => .Lte,   // a > K  →  K <= a
                    .Gte => .Lt,   // a >= K →  K <  a
                    .EqEq => .EqEq, // == is symmetric
                    .NotEq => .NotEq, // ~= is symmetric
                    else => n.op,
                };
                // Actually, PUC transforms differently:
                // `K < a` → `a > K` (GTI), `K <= a` → `a >= K` (GEI)
                // `K > a` → `a < K` (LTI), `K >= a` → `a <= K` (LEI)
                // For EQ: just swap, no direction change
                cmp_op = switch (n.op) {
                    .Lt => .Gt,    // K < a  →  a > K  (use GTI)
                    .Lte => .Gte,  // K <= a →  a >= K (use GEI)
                    .Gt => .Lt,    // K > a  →  a < K  (use LTI)
                    .Gte => .Lte,  // K >= a →  a <= K (use LEI)
                    else => n.op,
                };
            }
        }
```

Then use `lhs_exp`, `rhs_exp`, `cmp_op` in place of `n.lhs`, `n.rhs`, `n.op` in the comparison path.

IMPORTANT: The swap must ONLY affect the comparison emission, NOT the LHS/RHS evaluation order. LHS is always evaluated first (PUC infix discharge order).

Also: after the swap, `genComparison` must receive the TRANSFORMED operator so it emits GTI instead of LTI etc.

- [ ] **Step 3: Extend rhsConstUsableForCmp for floats**

Find `rhsConstUsableForCmp` (search for it). PUC's `isSCnumber` accepts integer-valued floats (like `-4.0`, `128.0`). luazig currently only accepts integers. Add float support:

```zig
fn rhsConstUsableForCmp(op: TokenKind, nc: NumConst) bool {
    // PUC isSCnumber accepts integer-valued floats.
    // EQI/LTI/LEI/GTI/GEI use the C field's bit 7 as an isfloat flag.
    _ = op;
    if (nc.kid != null) return false; // K-encodable, not immediate
    if (nc.is_float) {
        // Check if the float is integer-valued and fits sC range
        const as_int: i64 = @intFromFloat(nc.fval);
        if (@as(f64, @floatFromInt(as_int)) != nc.fval) return false;
        return fitsSC(as_int);
    }
    return fitsSC(nc.ival);
}
```

- [ ] **Step 4: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && cat > /tmp/test_cmp.lua << 'EOF'
local function f(a) if -4.0 == a then return 1 end end
local c = T.listcode(f)
for i = 1, #c do print(i, c[i]) end
EOF
timeout 10 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_cmp.lua 2>&1
```
Expected: `EQI` (not `LOADF, EQ`).

```bash
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
git add src/lua/codegen_bc.zig
git commit -m "codegen: comparison constant-LHS swap + float EQI support

PUC codeeq/codeorder: if LHS is constant and RHS is not, swap operands
and transform comparison direction (K<a → a>K=GTI, K<=a → a>=K=GEI).
Also accept integer-valued floats (128.0, -4.0) for EQI/LTI/LEI."
```

---

## Task 6: CONCAT Chain Folding

**Impact:** Fixes ~1 check (#9).
**Risk:** Low — localized to concat path.

**Files:**
- Modify: `src/lua/codegen_bc.zig` — Concat path in `genBinOp` (line ~2846)

- [ ] **Step 1: Read the current concat path**

In `genBinOp`, the `.Concat` case at line ~2846. Currently emits `CONCAT lhs_reg 2 0` for each binary `..`. PUC merges consecutive CONCAT instructions by incrementing the B field.

- [ ] **Step 2: Implement concat-merge**

Replace the concat emission with merge logic:

```zig
        if (n.op == .Concat) {
            const lhs_reg = try self.exp2nextreg(&lhs_ed);
            // Fix LHS line numbers
            const lhs_end_pc: usize = @intCast(self.builder.pc());
            for (self.builder.lineinfo.items[lhs_start_pc..lhs_end_pc]) |*inst_line| {
                inst_line.* = line;
            }
            const saved_hint = self.line_hint;
            self.line_hint = n.rhs.span.line;
            var rhs_ed = try self.genExpDesc(n.rhs);
            const rhs_reg = try self.exp2nextreg(&rhs_ed);
            self.line_hint = saved_hint;

            // PUC codeconcat: if the previous instruction is CONCAT and
            // its result register is immediately below our RHS register,
            // merge by extending its B field (operand count).
            const prev_pc = self.builder.code.items.len - 1;
            const prev_op: bc.Op = @enumFromInt(self.builder.code.items[prev_pc].op);
            if (prev_op == .concat and self.builder.code.items[prev_pc].a == lhs_reg) {
                // Merge: increment B field (operand count)
                self.builder.code.items[prev_pc].b += 1;
            } else {
                _ = try self.builder.emitABC(.concat, lhs_reg, 2, 0, line);
            }
            self.freeReg(rhs_reg);
            return lhs_reg;
        }
```

Wait, this logic is wrong. The concat chain `a..b..c..d` has AST `((a..b)..c)..d`. Each `genBinOp` call handles one `..`. The first call (`a..b`) emits `CONCAT a 2`. The second call (`(a..b)..c`) should merge: check if previous instruction is CONCAT with A=a, and extend B from 2 to 3.

But the previous CONCAT has `A=lhs_reg` from the FIRST call. In the second call, `lhs_ed` is the result of the first concat (register `lhs_reg`). If `exp2nextreg` returns the same register, we can merge.

Actually, PUC's merge works differently. Read `lua-5.5.0/src/lcode.c` `codeconcat` (line ~1767):

```c
static void codeconcat (FuncState *fs, expdesc *e1, expdesc *e2, int line) {
  ...
  if (GET_OPCODE(fs->f->code[pc-1]) == OP_CONCAT &&  /* prev is CONCAT? */
      GETARG_A(fs->f->code[pc-1]) == e1->u.info + GETARG_B(fs->f->code[pc-1]) - 1)
    /* adjust B to include the new operand */
    SETARG_B(fs->f->code[pc-1], GETARG_B(fs->f->code[pc-1]) + 1);
  else
    luaK_codeABC(fs, OP_CONCAT, e1->u.info, 2, 0);
}
```

PUC checks: is the previous instruction CONCAT, and does its result register (A) immediately follow the LHS register sequence? If so, extend B.

Implement this faithfully:

```zig
            // PUC codeconcat merge: if prev instruction is CONCAT and
            // A == lhs_reg + B - 1 (prev concat's result follows LHS),
            // increment B instead of emitting new CONCAT.
            if (self.builder.code.items.len > 0) {
                const prev_idx = self.builder.code.items.len - 1;
                const prev_op: bc.Op = @enumFromInt(self.builder.code.items[prev_idx].op);
                if (prev_op == .concat) {
                    const prev_a = self.builder.code.items[prev_idx].a;
                    const prev_b = self.builder.code.items[prev_idx].b;
                    // prev_a == lhs_reg + prev_b - 1 means the prev CONCAT's
                    // last operand register is immediately before rhs_reg.
                    if (prev_a == lhs_reg and rhs_reg == lhs_reg + prev_b) {
                        self.builder.code.items[prev_idx].b += 1;
                        self.freeReg(rhs_reg);
                        return lhs_reg;
                    }
                }
            }
            _ = try self.builder.emitABC(.concat, lhs_reg, 2, 0, line);
            self.freeReg(rhs_reg);
            return lhs_reg;
```

- [ ] **Step 3: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && cat > /tmp/test_concat.lua << 'EOF'
local function f(a,b,c,d) return a..b..c..d end
local cc = T.listcode(f)
for i = 1, #cc do print(i, cc[i]) end
EOF
timeout 10 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_concat.lua 2>&1
```
Expected: Single `CONCAT` with B=4 (not 3 CONCATs with B=2).

```bash
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
git add src/lua/codegen_bc.zig
git commit -m "codegen: merge concat chains into single CONCAT (PUC codeconcat)

'a..b..c..d' now emits one CONCAT A 4 instead of three CONCAT A 2.
Mirrors PUC lcode.c codeconcat which patches the previous CONCAT's
B field when operands are contiguous."
```

---

## Task 7: LOADNIL Coalescing

**Impact:** Fixes ~2 checks (#3, #4).
**Risk:** Medium — changes local declaration emission.

**Files:**
- Modify: `src/lua/codegen_bc.zig` — `genLocalDecl` function (search `fn genLocalDecl`)

- [ ] **Step 1: Read genLocalDecl**

Read the local declaration function. Find where `LOADNIL` is emitted for uninitialized locals. Currently it emits one `LOADNIL` per local. PUC emits a single `LOADNIL A B` where B = count-1.

- [ ] **Step 2: Coalesce adjacent nil locals**

Find the loop that emits LOADNIL per local. Replace with a coalesced emission:

```zig
        // PUC luaK_nil: coalesce adjacent nil-locals into one LOADNIL A B.
        // Count consecutive locals with no initializer (or nil initializer).
        var nil_start: ?u8 = null;
        var nil_count: u8 = 0;
        for (locals_to_nil) |local_reg| {
            if (nil_start == null) {
                nil_start = local_reg;
                nil_count = 1;
            } else if (local_reg == nil_start.? + nil_count) {
                nil_count += 1;
            } else {
                // Emit accumulated nils
                _ = try self.builder.emitABC(.loadnil, nil_start.?, nil_count -% 1, 0, line);
                nil_start = local_reg;
                nil_count = 1;
            }
        }
        if (nil_start != null) {
            _ = try self.builder.emitABC(.loadnil, nil_start.?, nil_count -% 1, 0, line);
        }
```

IMPORTANT: The exact logic depends on how `genLocalDecl` currently works. Read the function carefully. The key change is to batch adjacent nil-initializations instead of emitting one LOADNIL per local.

Also check: PUC's LOADNIL format is `LOADNIL A B` where B = count-1 (range is R[A..A+B]). So `local a,b,c` → `LOADNIL 0 2` (R0..R2). The B field is the count minus 1, not the count.

- [ ] **Step 3: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && cat > /tmp/test_nil.lua << 'EOF'
local function f()
  local a,b,c
  local d; local e
end
local cc = T.listcode(f)
for i = 1, #cc do print(i, cc[i]) end
EOF
timeout 10 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_nil.lua 2>&1
```
Expected: ONE `LOADNIL 0 4` (B=4, covering 5 locals R0..R4).

```bash
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
git add src/lua/codegen_bc.zig
git commit -m "codegen: coalesce adjacent LOADNIL into range form

PUC luaK_nil emits a single LOADNIL A B covering all consecutive nil
locals (B = count-1). luazig was emitting one LOADNIL per local."
```

---

## Task 8: Final Matrix Run + README Update

- [ ] **Step 1: Run full matrix + smoke + perf**

```bash
cd /home/boss/codes/luazig
python3 tools/testes_matrix.py --testc --timeout 60 2>&1
for f in tests/smoke/*.lua; do timeout 10 ./zig-out/bin/luazig --vm=bc "$f" 2>&1 | tail -1; done
python3 tools/perf_compare.py 2>&1 | tail -5
```

- [ ] **Step 2: Run code.lua mismatch count**

```bash
cd lua-5.5.0/testes && timeout 30 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_code_stats.lua 2>&1 | grep -c MISMATCH
```

- [ ] **Step 3: Update README**

Update the code.lua section with the new mismatch count and completed tasks.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "README: update codegen parity status"
```

---

## Self-Review

**Spec coverage:** All 8 categories from the mismatch analysis (A-H) have corresponding tasks. Category F (SETFIELD/SETI RK encoding) is the most complex and is deferred — it requires changes to how SET opcodes encode operands. Category H (LOADI range) may not be fixable without changing the instruction format (8-bit op vs PUC's 7-bit).

**Task dependencies:** Tasks 1-7 are mostly independent. Task 1 (exp2anyreg) is a prerequisite for correct register allocation in all subsequent tasks. Task 5 (comparison swap) depends on `numericConstFromExp` from the already-completed `<const>` propagation task. Task 7 (LOADNIL) is independent.

**Risk areas:** Task 5 (comparison swap) has the highest risk — operand swap logic for 6 comparison operators. Task 7 (LOADNIL) changes local declaration emission which affects all code. Each task must be validated with the full matrix (27/31 minimum).

**Execution note:** Use model `glm-5.2` for all subagent dispatches.
