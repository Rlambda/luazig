# Codegen MOVE Elimination + SET Field Fusion Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax. Use model `glm-5.2`.

**Goal:** Close ~26 remaining code.lua mismatches by eliminating extra MOVE instructions in table assignment paths, adding SETFIELD for string keys, skipping codegen for const local initializers, and fixing GETTABUP error messages.

**Architecture:** Five independent fixes, ordered by ROI. P0 (17 mismatches) changes `genSet`/`prepareAssignLhs` to use `genExpDesc`+`exp2anyreg` instead of `genExp`. P1 (4 mismatches) adds SETFIELD for const-string keys. P2 (3 mismatches) skips codegen for `<const>` local initializers. P3 (2 mismatches) adds LOADNIL peephole merge. P4 enables GETTABUP by fixing SETTABUP error messages in the VM.

---

## Build/Test Commands

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
cd lua-5.5.0/testes && cat > /tmp/test_code_stats.lua << 'SCRIPT'
local f = io.open("code.lua", "r")
local src = f:read("*a")
f:close()
src = src:gsub("assert%(arg%[i%] == opcode%)", 
  "if arg[i] ~= opcode then io.stderr:write('MISMATCH exp='..tostring(arg[i])..' got='..tostring(string.match(c[i] or '', '%%u%%w+'))..' idx='..i..'\\n') end")
src = src:gsub("assert%(c%[#arg%+2%] == undef%)", "")
local out = io.open("/tmp/code_patched.lua", "w")
out:write(src)
out:close()
dofile("/tmp/code_patched.lua")
SCRIPT
timeout 30 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_code_stats.lua 2>&1 | grep -c MISMATCH
```

---

## Task 1: Eliminate Extra MOVE in genSet/prepareAssignLhs (17 mismatches)

**Files:** `src/lua/codegen_bc.zig` — `genSet` and `prepareAssignLhs`

**Problem:** `genSet` calls `genExp(n.object)` for the table object, which always allocates a temp register and emits MOVE for locals. Should use `genExpDesc`+`exp2anyreg` which returns the local's register directly (no MOVE).

- [ ] **Step 1: Read genSet and prepareAssignLhs**

Search `fn genSet` and `fn prepareAssignLhs` in codegen_bc.zig. Find all `genExp(n.object)` calls. These should be replaced with `genExpDesc` + `exp2anyreg`.

- [ ] **Step 2: Replace genExp with genExpDesc+exp2anyreg for table objects**

In `genSet` `.Field` case (search `.Field =>` in genSet), replace:
```zig
const obj_reg = try self.genExp(n.object);
```
with:
```zig
var obj_ed = try self.genExpDesc(n.object);
const obj_reg = try self.exp2anyreg(&obj_ed);
```

Do the same in `genSet` `.Index` case and in `prepareAssignLhs` for `.Field` and `.Index`.

IMPORTANT: Check that `obj_ed` is properly freed or consumed. `exp2anyreg` for a `.local` returns the register directly without allocating a new one — no MOVE. For non-local expressions, it falls through to `exp2nextreg` which allocates.

- [ ] **Step 3: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && timeout 30 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_code_stats.lua 2>&1 | grep -c MISMATCH
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
```

```bash
git add src/lua/codegen_bc.zig
git commit -m "codegen: eliminate extra MOVE in genSet via genExpDesc+exp2anyreg

Table assignment paths (genSet .Field/.Index, prepareAssignLhs) now use
genExpDesc+exp2anyreg instead of genExp. For locals, exp2anyreg returns
the register directly without MOVE. Closes ~17 code.lua mismatches."
```

---

## Task 2: SETFIELD for Const-String Keys in genSet(.Index) (4 mismatches)

**Files:** `src/lua/codegen_bc.zig` — `genSet` `.Index` case

**Problem:** `genSet` for `.Index` only handles integer keys (SETI). When the key is a `<const>` string local (like `kx = "x"`), it falls through to SETTABLE instead of using SETFIELD.

- [ ] **Step 1: Read genSet .Index case**

Search `.Index =>` in genSet. After the integer key check (SETI), add a check for const-string keys.

- [ ] **Step 2: Add k_str → SETFIELD**

After the SETI check, before the SETTABLE fallback:

```zig
// Check for string constant key → SETFIELD
if (n.index.node == .String or n.index.node == .Name) {
    // Try to resolve as a string constant
    if (self.genConstExpDesc(n.index)) |key_ed| {
        if (key_ed.val == .k_str) {
            const kid = try self.builder.internString(key_ed.val.k_str);
            if (kid <= 255) {
                const obj_reg = ... (already obtained above);
                const val_reg = ... ;
                _ = try self.builder.emitABC(.setfield, obj_reg, @intCast(kid), val_reg, line);
                return;
            }
        }
    }
}
```

Read the actual code structure to get the right variable names and control flow.

- [ ] **Step 3: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && timeout 30 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_code_stats.lua 2>&1 | grep -c MISMATCH
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
git add src/lua/codegen_bc.zig
git commit -m "codegen: SETFIELD for const-string keys in genSet(.Index)

t[kx] = val where kx = <const> 'x' now emits SETFIELD instead of
SETTABLE. Mirrors PUC VINDEXSTR for assignment."
```

---

## Task 3: Skip Codegen for `<const>` Local Constant Initializers (3 mismatches)

**Files:** `src/lua/codegen_bc.zig` — `genLocalDecl`

**Problem:** `local k255 <const> = 255` emits LOADI(255) even though the value is never read from the register (all references fold to the constant). PUC doesn't emit code for const local initializers.

- [ ] **Step 1: Read genLocalDecl initializer handling**

Search `fn genLocalDecl` in codegen_bc.zig. Find where the initializer expression is evaluated (probably `genExpNextReg` or similar). 

- [ ] **Step 2: Skip codegen for const locals with constant initializers**

Before evaluating the initializer, check:
1. Is this local declared `<const>`?
2. Is the initializer a compile-time constant? (use `genConstExpDesc`)
3. If both: skip codegen, just capture the const value via `captureConstLocalValue`

```zig
// For <const> locals with constant initializers, skip codegen.
if (is_const_attr) {
    if (self.genConstExpDesc(init_exp)) |const_ed| {
        // The value is known at compile time — don't emit LOADI/LOADK.
        // Still allocate the register (PUC does too — it's the local's slot).
        _ = try self.allocReg();
        // Capture the const value for later folding.
        self.captureConstLocalValue(reg, init_exp);
        // Don't call genExpNextReg.
        continue; // or equivalent control flow
    }
}
```

IMPORTANT: Read how `is_const_attr` is determined and how `captureConstLocalValue` works. Also check that the register is still allocated even though no code is emitted — PUC allocates the register but doesn't initialize it.

- [ ] **Step 3: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
git add src/lua/codegen_bc.zig
git commit -m "codegen: skip codegen for <const> local constant initializers

local k255 <const> = 255 no longer emits LOADI — the value is captured
at compile time and references fold to the constant. Matches PUC RDKCTC."
```

---

## Task 4: GETTABUP — Fix SETTABUP Error Message in VM

**Files:** `src/lua/vm.zig` — SETTABUP handler

**Problem:** When GETTABUP fusion was applied, `a.x = 1` (where `a` is an upvalue) emits SETTABUP. If `a` is nil, the error message lacks the `(upvalue 'a')` suffix that errors.lua expects.

- [ ] **Step 1: Read the SETTABUP handler in vm.zig**

Search `.settabup` in vm.zig dispatch. Find where the error occurs when the table is nil.

- [ ] **Step 2: Add upvalue name to error message**

When SETTABUP's table (upvalue) is nil, produce: `attempt to index a nil value (upvalue 'name')`.

The upvalue name can be resolved from `proto.upvalues[a]` where `a` is the SETTABUP's A field (the upvalue index). Search how other handlers (like GETUPVAL) resolve upvalue names for error messages.

Look for `debugBytecodeOperandName` or similar functions that resolve variable names from bytecode.

- [ ] **Step 3: Re-apply GETTABUP fusion from commit c223119**

```bash
git cherry-pick --no-commit c223119
```

- [ ] **Step 4: Build, test**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && timeout 10 ../../zig-out/bin/luazig --vm=bc --testc errors.lua 2>&1 | tail -3
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
```

errors.lua MUST pass. Matrix MUST be ≥27/31.

- [ ] **Step 5: Commit**

```bash
git add src/lua/vm.zig src/lua/codegen_bc.zig
git commit -m "vm+codegen: GETTABUP/SETTABUP with correct error messages

SETTABUP handler now includes upvalue name in error messages: 'attempt
to index a nil value (upvalue 'a')'. GETTABUP fusion re-enabled.
Mirrors PUC VINDEXUP for both read and write."
```

---

## Task 5: Final Verification + README

- [ ] **Step 1: Matrix + smoke + mismatch count**
- [ ] **Step 2: Update README**
- [ ] **Step 3: Commit**

---

## Self-Review

**Coverage:** P0 (17 mismatches) → Task 1. P1 (4) → Task 2. P2 (3) → Task 3. P4 (enables 2) → Task 4. P3 (2, LOADNIL merge) deferred — previous cross-statement merge broke goto.lua; within-assignment merge is safe but low ROI.

**Risk:** Task 1 changes assignment paths globally — must verify all 45 smoke tests + full matrix. Task 3 changes const local declaration — must verify locals.lua, closure.lua. Task 4 touches VM error handling — must verify errors.lua, events.lua.
