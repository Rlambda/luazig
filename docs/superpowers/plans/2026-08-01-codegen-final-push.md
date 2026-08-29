# Codegen Parity: Final code.lua Push Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax. Use model `glm-5.2` for all subagent dispatches.

**Goal:** Close the remaining ~95 code.lua bytecode mismatches across 38 failing checks.

**Architecture:** Tasks ordered by ROI (impact/effort). Category B (MMBINI→MMBINK, 17 mismatches) is the single largest easy win. Category D (SHLI/SHRI/MODK, 12 mismatches) is the next target. Extra MOVE elimination (35 mismatches) is the hardest and deferred.

**Tech Stack:** Zig (codegen_bc.zig, vm.zig), PUC Lua 5.5.

---

## Build/Test Commands

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
# Mismatch count:
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
```

---

## Task 1: Fix MMBINI→MMBINK After Intern Fallback (17 mismatches)

**Impact:** 17 mismatches across checks #59-63, #70-72, #80-82.
**Risk:** Low — purely affects which MMBIN variant name is emitted.

**Problem:** When `tryEmitConstBinOp` interns a small integer (e.g. `x * -127`), it returns with `nc.kid != null` (K-variant). The MMBIN emission code checks `nc.kid == null` to decide MMBINI vs MMBINK. But after interning, `nc.kid` is non-null, so MMBINK should be emitted. The current code emits MMBINI because it checks the ORIGINAL `nc.kid` (before interning).

**File:** `src/lua/codegen_bc.zig` — MMBIN emission in genBinOp (search `if (nc.kid == null)`)

- [ ] **Step 1: Read the MMBIN emission code**

Search for `if (nc.kid == null)` in genBinOp. The code currently checks:
```zig
if (nc.kid == null) {
    _ = try self.builder.emitABC(.mmbini, ...);
} else {
    _ = try self.builder.emitABC(.mmbink, ...);
}
```

But `nc` is the NumConst from `rhs_const`. After `tryEmitConstBinOp` succeeds with a K-variant, `nc` still has the ORIGINAL kid status. When interning happened INSIDE `tryEmitConstBinOp`, the kid was set there but `nc` (the local copy) wasn't updated.

- [ ] **Step 2: Determine K vs I from the emitted opcode, not from nc**

The fix: instead of checking `nc.kid`, check which opcode was emitted. If `tryEmitConstBinOp` emitted an I-variant (ADDI/SHLI/SHRI), use MMBINI. If it emitted a K-variant (ADDK/MULK/etc), use MMBINK.

The simplest approach: `tryEmitConstBinOp` already called `constBinOpInfo` which returns the opcode. Check if the last emitted instruction is an I-variant:

```zig
                    // Determine MMBIN variant from the emitted opcode:
                    // I-variants (ADDI/SHLI/SHRI) → MMBINI
                    // K-variants (ADDK/SUBK/MULK/etc) → MMBINK
                    const last_inst = self.builder.code.items[self.builder.code.items.len - 1];
                    const last_op: bc.Op = @enumFromInt(last_inst.op);
                    const is_ivariant = switch (last_op) {
                        .addi, .shli, .shri => true,
                        else => false,
                    };
                    if (is_ivariant) {
                        _ = try self.builder.emitABC(.mmbini, lhs_reg, last_inst.c, encodeTms(event, flip), line);
                    } else {
                        _ = try self.builder.emitABC(.mmbink, lhs_reg, last_inst.b, encodeTms(event, flip), line);
                    }
```

NOTE: For MMBINI, B should carry the immediate value from the arith opcode's C field (`last_inst.c`). For MMBINK, B should carry the K index from the arith opcode's C field (`last_inst.c` for most K-variants). Wait — check: for ADDK, the C field is the K index. For ADDI, the C field is sC-encoded immediate. So:

```zig
                    if (is_ivariant) {
                        _ = try self.builder.emitABC(.mmbini, lhs_reg, last_inst.c, encodeTms(event, flip), line);
                    } else {
                        _ = try self.builder.emitABC(.mmbink, lhs_reg, last_inst.c, encodeTms(event, flip), line);
                    }
```

Both use `last_inst.c` as the B field (the operand encoding).

- [ ] **Step 3: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && timeout 30 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_code_stats.lua 2>&1 | grep -c MISMATCH
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
```

```bash
git add src/lua/codegen_bc.zig
git commit -m "codegen: fix MMBINI/MMBINK variant selection after intern fallback

When tryEmitConstBinOp interns a constant (K-variant), the MMBIN
emission should use MMBINK not MMBINI. Determine variant from the
emitted opcode (ADDI/SHLI/SHRI → MMBINI, everything else → MMBINK)."
```

---

## Task 2: SHLI/SHRI — Shift with Immediate Constant (9 mismatches)

**Impact:** 9 mismatches across checks #65-67.
**Risk:** Low — new codegen paths for existing opcodes.

**Problem:** `k1 << x` should emit SHLI (shift left immediate), `x << 127` should emit SHRI (shift right immediate). luazig emits LOADI + SHL + MMBIN.

**File:** `src/lua/codegen_bc.zig` — `constBinOpInfo` (search `fn constBinOpInfo`) and `tryEmitConstBinOp`

- [ ] **Step 1: Add SHLI/SHRI to constBinOpInfo**

In `constBinOpInfo`, add cases for Shl and Shr. PUC's logic:
- `K << r` → SHLI (k is the immediate, r is register): opcode=SHLI, A=dst, B=reg, C=sC(k)
- `r >> K` → SHRI (r is register, K is immediate): opcode=SHRI, A=dst, B=reg, C=sC(k)

Read PUC `lcode.c` `codebinexpval` for the exact SHLI/SHRI selection logic. In `constBinOpInfo`:

```zig
            // SHLI: K << R  (constant on left, register on right)
            // SHRI: R >> K  (register on left, constant on right)
            // These only apply when the constant is on a specific side.
            // For `r << K`, PUC doesn't have SHLI for this — it uses
            // the register form. Wait, check PUC...
```

IMPORTANT: Read PUC `lcode.c` carefully. PUC's `codebitwise` handles SHLI/SHRI:
- `isSCint(e2)` (RHS is small int) and op is `<<`: emit `SHLI A=e1 B=e2 C=sC`
  - Wait, SHLI format: `R[A] = sC << R[B]`. So A=dst, B=register, C=immediate.
  - For `K << r`: SHLI dst, r_reg, sC(K) — constant on left
  - For `r << K`: PUC doesn't have a direct form. It uses the register form `SHL dst, r_reg, K_reg`.
  
Actually, let me re-read. SHLI means "shift left immediate" — the SHIFT AMOUNT is the register, the VALUE is the immediate:
- `SHLI A B C`: R[A] = sC(C) << R[B]
- `SHRI A B C`: R[A] = R[B] >> sC(C)

So:
- `K << r` → SHLI dst, r_reg, sC(K) — VALUE=K, SHIFT=r
- `r >> K` → SHRI dst, r_reg, sC(K) — VALUE=r, SHIFT=K

For `r << K` (register value, constant shift): PUC uses `SHRI`? No, that's for `>>`. For `r << K`, PUC falls back to register form (SHL). Wait, let me check code.lua expectations:

```
CHK#65: k1 << x → SHLI, MMBINI   (constant VALUE << register SHIFT)
CHK#66: x << 127 → SHRI, MMBINI   ??? This seems wrong
CHK#67: x << -127 → SHRI, MMBINI  ??? This also seems wrong
```

Wait — CHK#66 is `x << 127`, and PUC expects SHRI? That doesn't make sense for `<<`. Let me re-read the code.lua test:

```lua
checkR(function (x) return x << 127 end, 10, 0, 'SHRI', 'MMBINI', 'RETURN1')
```

Hmm, `x << 127` expected SHRI. But SHRI is "shift right immediate". Oh wait — PUC may transform `x << K` into `x >> (-K)` for negative shifts? No, that doesn't make sense.

Actually, looking at PUC lopcodes.h more carefully:
- `SHRI A B C`: R[A] = R[B] >> sC(C)
- `SHLI A B C`: R[A] = sC(C) << R[B]

Wait, I misread. Let me check the PUC lopcodes.h comment:
```
OP_SHLI,/* A B C  R[A] := sC(C) << R[B] */
OP_SHRI,/* A B C  R[A] := R[B] >> sC(C) */
```

So SHLI shifts a constant LEFT by a register amount. SHRI shifts a register RIGHT by a constant amount.

For `x << 127`:
- This is "shift x left by 127"
- PUC transforms this... Actually, PUC Lua 5.5's `codebinexpval` for shifts:
  - `r << K` where K is small: emit `SHRI`? No, SHRI is for `>>`.

Hmm, I think I need to read the actual PUC code more carefully. Let me just check what code.lua expects:

```lua
checkR(function (x) return x << 127 end, 10, 0, 'SHRI', 'MMBINI', 'RETURN1')
checkR(function (x) return x << -127 end, 10, 0, 'SHRI', 'MMBINI', 'RETURN1')
checkR(function (x) return x >> 128 end, 8, 0, 'SHRI', 'MMBINI', 'RETURN1')
checkR(function (x) return x >> -127 end, 8, 0, 'SHRI', 'MMBINI', 'RETURN1')
```

ALL shift-with-constant tests expect SHRI. This is because PUC Lua 5.5 normalizes ALL shift-with-immediate to SHRI form. For `x << K`, PUC transforms it to... let me think... In Lua, `x << n` for large n is 0 (all bits shifted out). PUC may just use SHRI for all shift-with-constant cases, converting `<<` to `>>` mathematically.

Actually, reading PUC lcode.c more carefully, `codebinexpval` for shifts:
```c
case OPR_SHL: case OPR_SHR:
  if (isSCint(e2)) {
    op = (opr == OPR_SHL) ? OP_SHRI : OP_SHRI;  // ???
  }
```

Wait no, I should just read the code. But I don't have the exact PUC source. Let me skip this for now and focus on the simpler tasks. SHLI/SHRI requires understanding PUC's shift normalization, which is complex.

- [ ] **Skip this task for now — defer to a dedicated shift-codegen task**

---

## Task 3: ADDI for Subtraction (1 mismatch)

**Impact:** 1 mismatch (#57). Low ROI but simple fix.
**Risk:** Medium — SUB metamethod must use __sub not __add.

**Problem:** `x - 127` should emit ADDI(x, -127) + MMBINI with __sub event. luazig emits SUBK.

**PUC approach:** PUC's `codecommutative` handles ADD, but SUB is handled by `codearith` → `codebinexpval`. For `x - K` where K is small int, PUC converts to `ADDI(x, -K)` and sets the metamethod event to TM_SUB (not TM_ADD).

This requires:
1. In `constBinOpInfo`, add a `.Minus` case that produces ADDI with negated value
2. In the MMBINI emission, use TMS_SUB (7) not TMS_ADD (6)
3. In the VM, ADDI handler must check the next MMBINI's event to decide which metamethod to call

This is complex because the VM's ADDI handler currently always uses __add. With this change, it would need to read the MMBINI event to decide __add vs __sub. Defer.

- [ ] **Skip this task — requires VM ADDI handler changes**

---

## Task 4: Constant `while 1` / `repeat until true` Folding (3 mismatches)

**Impact:** 3 mismatches (#7, #8).
**Risk:** Low.

**Problem:** `while 1` (integer literal) doesn't fold to always-true. `while kTrue` (const local) already works.

**File:** `src/lua/codegen_bc.zig` — `genExpCond` (search `fn genExpCond`)

- [ ] **Step 1: Check why `while 1` doesn't fold**

`while 1` uses an integer literal `1`. `genExpCond` calls `genExpDesc` which returns `.k_int` for `1`. The `.k_int` case is NOT handled in the condition folding switch (only `.true`, `.false`, `.nil` are handled).

- [ ] **Step 2: Add .k_int and .k_float to the condition folding**

In `genExpCond`'s constant handling (after the recent fix that added `.true`/`.false`/`.nil`), also treat non-zero integers/floats as truthy:

```zig
                    .k_int => |ival| {
                        if (ival != 0) {
                            // Always true
                            return .{ .val = .true };
                        } else {
                            return .{ .val = .false };
                        }
                    },
                    .k_float => |fval| {
                        if (fval != 0.0) {
                            return .{ .val = .true };
                        } else {
                            return .{ .val = .false };
                        }
                    },
                    .k_str => return .{ .val = .true }, // non-empty string is truthy
```

- [ ] **Step 3: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && cat > /tmp/test_while1.lua << 'EOF'
local function f() while 1 do return 1 end end
local c = T.listcode(f)
for i = 1, #c do print(i, c[i]) end
EOF
timeout 10 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_while1.lua 2>&1
```
Expected: No TEST for `1` — unconditional JMP.

```bash
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
git add src/lua/codegen_bc.zig
git commit -m "codegen: fold integer/float constants in conditions

while 1 (integer literal) now folds to always-true, same as while kTrue.
k_int != 0 → true, k_int == 0 → false, k_float != 0.0 → true, etc."
```

---

## Task 5: EQK for String Equality Comparison (4 mismatches)

**Impact:** 4 mismatches (#21).
**Risk:** Low-medium.

**Problem:** `if a == "hi"` uses LOADK + EQ instead of EQK. PUC uses EQK when comparing with a string constant.

**File:** `src/lua/codegen_bc.zig` — comparison path in genBinOp

- [ ] **Step 1: Extend comparison constant detection to strings**

In the comparison path of genBinOp, `numericConstFromExp` only detects numeric constants. For `==` and `~=` comparisons, string constants should also be detected for EQK.

Add a separate check for string constants in comparisons:

```zig
        // For equality comparisons, also check for string constants (EQK)
        var string_kid: ?u16 = null;
        if (n.op == .EqEq or n.op == .NotEq) {
            if (rhs_const == null) {
                if (n.rhs.node == .String) {
                    const str = ... decode string ...;
                    const kid = try self.builder.internString(str);
                    if (kid <= 255) string_kid = @intCast(kid);
                }
            }
        }
```

Then in `genComparison`, add an EQK path when `string_kid != null`.

Read how `genComparison` currently handles EQI vs EQ to understand where to add the EQK path.

- [ ] **Step 2: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && cat > /tmp/test_eqk.lua << 'EOF'
local function f(a) if a == "hi" then return 2 end end
local c = T.listcode(f)
for i = 1, #c do print(i, c[i]) end
EOF
timeout 10 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_eqk.lua 2>&1
```
Expected: `EQK` (not `LOADK, EQ`).

```bash
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
git add src/lua/codegen_bc.zig
git commit -m "codegen: EQK for string constant equality comparison

if a == 'hi' now uses EQK (1 opcode) instead of LOADK+EQ (2 opcodes).
Mirrors PUC codeeq which internss string constants and uses EQK."
```

---

## Task 6: GETTABUP/SETTABUP for Upvalue Table Access (2 mismatches)

**Impact:** 2 mismatches (#90).
**Risk:** Low-medium.

**Problem:** When accessing `t.field` or `t[kx]` where `t` is an upvalue (not a register), luazig emits GETUPVAL + GETFIELD instead of GETTABUP.

**File:** `src/lua/codegen_bc.zig` — `genExpDesc` `.Field`/`.Index` cases

- [ ] **Step 1: Detect _ENV upvalue access**

When the table object is the `_ENV` upvalue, PUC uses GETTABUP/SETTABUP. More generally, when the table is ANY upvalue (not just _ENV), PUC uses GETTABUP.

In `genExpDesc`, the `.Field` and `.Index` cases currently discharge the table object to a register. When the table is an upvalue, they should create an `index_up` ExpDesc instead:

```zig
            .Field => |n| {
                // Check if object is an upvalue → use GETTABUP
                if (n.object.node == .Name) {
                    const name = n.object.node.Name.slice(self.source);
                    if (self.upvalues.get(name)) |upval_idx| {
                        const kid = try self.builder.internString(n.field.slice(self.source));
                        if (kid <= 255) {
                            return .{ .val = .{ .index_up = .{
                                .idx = @intCast(kid),
                                .t = upval_idx,
                                .keystr = @intCast(kid),
                            } } };
                        }
                    }
                }
                // Existing register-based path...
            },
```

The `index_up` ExpDesc variant already exists and discharges to GETTABUP (search `.index_up =>` in dischargeVars).

- [ ] **Step 2: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
git add src/lua/codegen_bc.zig
git commit -m "codegen: GETTABUP/SETTABUP for upvalue table access

When t is an upvalue, t.field uses GETTABUP (1 opcode) instead of
GETUPVAL+GETFIELD (2 opcodes). Mirrors PUC VINDEXUP."
```

---

## Task 7: Final Verification + README

- [ ] **Step 1: Full matrix + smoke + mismatch count**

- [ ] **Step 2: Update README**

- [ ] **Step 3: Commit**

---

## Self-Review

**Coverage:**
- Task 1 (MMBINI→MMBINK, 17 mismatches) — highest ROI
- Task 2 (SHLI/SHRI, 9 mismatches) — deferred, needs PUC shift normalization study
- Task 3 (ADDI for SUB, 1 mismatch) — deferred, needs VM changes
- Task 4 (constant while/repeat, 3 mismatches) — easy
- Task 5 (EQK strings, 4 mismatches) — moderate
- Task 6 (GETTABUP, 2 mismatches) — moderate

**Deferred (35 mismatches):** Extra MOVE elimination — register allocation is deeply architectural. Each extra MOVE corresponds to a case where PUC's `exp2anyreg` returns a register directly but luazig allocates a temp. This requires a comprehensive audit of `discharge2reg` and `exp2anyreg`.

**Deferred (6 mismatches):** LOADI/LOADF range for values >32767 — luazig's 8-bit opcode field gives 16-bit Bx (max 32767) vs PUC's 7-bit opcode giving 17-bit Bx (max 65535). Requires instruction format change.
