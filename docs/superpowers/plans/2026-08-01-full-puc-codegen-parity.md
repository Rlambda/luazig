# Full PUC-faithful Codegen Parity Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Use model `glm-5.2`.

**Goal:** Close ALL remaining ~10 code.lua mismatches and achieve PUC-faithful instruction format + codegen by adding the k-bit, enabling RK encoding, LOADI/LOADF range extension, LOADNIL cross-statement merge, and shift normalization.

**Architecture:** The k-bit instruction format change (`op:u7, k:u1, a:u8, b:u8, c:u8`) is the foundation. Tasks 2-7 build on it. Task 1 (k-bit) must complete before Tasks 2-5. Tasks 6-7 are independent.

**Current state:** Matrix 27/31, code.lua ~10 mismatches, smoke 45/45.

**COMPLETED:**
- [x] Task 1: k-bit instruction format (commit 3bab903)
- [x] Task 2: LOADI/LOADF 17-bit sBx (commit bd6d22e)
- [x] Task 3: RK encoding for SET operands (commit b07bd5d) — PUC-faithful exp2RK
- [x] Task 4: LOADNIL cross-stmt merge (commit 904de17)
- [x] SHLI for `K << R` (commit 904de17)
- [x] VM SET handlers read RK[C] (commit bd6d22e)

**REMAINING:**

---

## Task 3b: Fix pre-existing GC bug in coroutine yield/resume + TBC

**File:** `src/lua/vm.zig`

**Problem:** When a coroutine yields from `__close` metamethod during RETURN, return values (especially GC objects like tables) in registers are corrupted during yield/resume. This is a pre-existing bug exposed by RK encoding's different GC heap layout.

**Root cause:** Return values in registers are not properly GC-protected when `__close` metamethod yields. The CLOSE opcode handler and coroutine resume path need to protect return values from GC during the yield/resume window.

**Reproduction:**
```lua
local function func2close(f) return setmetatable({}, {__close = f}) end
collectgarbage("stop"); collectgarbage("restart")
local function foo()
    local x <close> = func2close(coroutine.yield)
    local a, b, c = 10, x, 30
    return a, b, c  -- b becomes nil after close-yield + resume
end
local co = coroutine.wrap(foo)
co()  -- yield from __close
local a, b, c = co()  -- b is nil! Should be the table x
```

**Fix area:** `src/lua/vm.zig` — CLOSE opcode handler + coroutine resume path. Return values need GC protection during __close yield. PUC's `luaF_close` + `luaD_poscall` explicitly protects return values.

---

## Task 5: SHRI for `x << K` via finishbinexpneg

**File:** `src/lua/codegen_bc.zig`, `src/lua/vm.zig`

**Problem:** `x << 127` should emit SHRI with sC=-127 (PUC transforms `x << K` to `x >> (-K)`). Currently emits LOADI+SHL.

**KNOWN REGRESSION:** math.lua:66 fails when SHRI is activated. Error: `math.huge << 1` produces wrong error message annotation.

**ROOT CAUSE (from previous analysis):** NOT the SHRI transform itself — it's the error message annotation. `math.huge` is a float without integer representation. The SHRI handler's slow path calls `evalBytecodeBinOpValues` which uses `isNumberLikeForArithmetic` (returns true for math.huge) instead of checking integer representability.

**FIX:** In the SHRI handler's error path, use `isNumWithoutInteger` (checks float can't be converted to i64) instead of `isNumberLikeForArithmetic` for annotation. This matches PUC's `luaG_tointerror` which uses `luaV_tointegerns`.

---

## Execution Order

1. Task 3 (RK encoding) — root-cause locals.lua:926, fix, test
2. Task 5 (SHRI) — apply annotation fix, test math.lua
3. Task 6 (RETURN k=close) — PUC-faithful cleanup
4. Task 8 (delete bc_vm.zig + final verify)

---

## Task 1: k-bit Instruction Format (Foundation)

**File:** `src/lua/bytecode.zig`, `src/lua/vm.zig`, `src/lua/codegen_bc.zig`

Change `Instruction` from `{ op:u8, a:u8, b:u8, c:u8 }` to `{ op:u7, a:u8, k:u1, b:u8, c:u8 }`. 84 opcodes fit in 7 bits (128 max). No opcodes deleted — PUC 5.5 also has ADDK/MULK/etc.

Replace C-field 0x80 flip hack with `inst.k`:
- Delete `encodeTms` helper and `mmbinFlip` peek function
- All K/I-variant arith handlers read `inst.k` for flip
- Arith ops emit via `emitABCk(op, a, b, c, flip, line)` 
- MMBINI/MMBINK emit plain event in C (no 0x80 hack)

Move comparison isfloat from C-field bits to `inst.k`:
- EQI/LTI/LEI/GTI/GEI emit `emitABCk(op, a, imm, _, isfloat, line)`
- VM reads `inst.k` as isfloat

**Verify:** matrix ≥27/31, all smoke pass, mismatch count ≤10.

---

## Task 2: LOADI/LOADF 17-bit sBx (+1 mismatch)

**File:** `src/lua/bytecode.zig`, `src/lua/vm.zig`, `src/lua/codegen_bc.zig`

Depends on: Task 1 (k-bit available for 17th bit of sBx).

Encode sBx across `k:b:c` (17-bit unsigned Bx = k(1) + b(8) + c(8)):
- Range extends from [-32768, 32767] to [-65535, 65535]
- Codegen: change range check to `parsed >= -65535 and parsed <= 65535`
- VM: decode as `bits: u17 = b | (c << 8) | (k << 16); signed = bits - 65535`
- Constructor: `loadImm(op, a, value)` encodes offset across k:b:c

**Verify:** `local border <const> = 65535; return border` emits LOADI not LOADK.

---

## Task 3: RK Encoding for SET Operands (+3 mismatches)

**File:** `src/lua/codegen_bc.zig`, `src/lua/vm.zig`

Depends on: Task 1 (k-bit available for RK selection).

PUC uses k-bit on SETTABLE/SETFIELD/SETI to select R[C] (k=0) vs K[C] (k=1) for the VALUE operand. This folds constants directly:
- `a[kx] = 3.2` → SETFIELD with K[3.2] (no LOADK)
- `a[256] = 5` → SETTABLE with K[5] (no LOADI)  
- `a[kTrue] = false` → SETTABLE with K[false] (no LOADFALSE)

Implement `canRKEncode(exp)` returning `?u8` (constant pool index or null):
- Integer/Float literal with kid ≤255 → kid
- String literal interned with kid ≤255 → kid
- Boolean: PUC encodes true as MAXARG_C (255), false as MAXARG_C-1 (254)

In genSet, when value is RK-encodable: `emitABCk(.setfield, obj, key, kid, true, line)` instead of LOADK+SETFIELD.

VM SETTABLE/SETFIELD/SETI handlers: `const val = if (inst.k == 1) K[c] else R[c]`.

**Verify:** `a[kx] = 3.2` emits SETFIELD only (no LOADK).

---

## Task 4: Cross-Statement LOADNIL Merge (+2 mismatches)

**File:** `src/lua/codegen_bc.zig`

Independent of Task 1. Previous attempts broke goto.lua/math/sort/tpack.

Root cause of previous breaks:
1. goto.lua: merging across jump targets (fixed with `lasttarget` guard — already implemented but reverted with SHLI commit)
2. math/sort/tpack: SHLI register leak (fixed — separate issue)

The `emitLoadNil` helper with `lasttarget` guard is SAFE (verified before SHLI broke it). Re-apply just the LOADNIL merge without SHLI:

```zig
fn emitLoadNil(self: *Codegen, from: u8, n: u8, line: u32) Error!void {
    // PUC luaK_nil: merge with previous LOADNIL if adjacent and
    // no jump target between them.
    const l: u8 = from + n - 1;
    if (self.builder.code.items.len > 0 and 
        self.builder.pc() > self.builder.lasttarget) {
        const prev = self.builder.code.items[self.builder.code.items.len - 1];
        if (@as(bc.Op, @enumFromInt(prev.op)) == .loadnil) {
            // adjacency check + merge
        }
    }
    // fall through to new LOADNIL emission
}
```

CRITICAL: `lasttarget` must be checked — it prevents merging across jump targets which broke goto.lua.

Also: nil-to-local direct store (skip LOADNIL+MOVE → direct LOADNIL to local register).

**Verify:** goto.lua, locals.lua, math.lua, sort.lua, tpack.lua ALL pass.

---

## Task 5: SHLI/SHRI Shift Normalization (enables more code.lua checks)

**File:** `src/lua/codegen_bc.zig`

Independent of Task 1. Was reverted due to register leak (now fixed in root-cause analysis).

SHLI already implemented (with freeReg fix). SHRI partially implemented (for `r >> K`).

Remaining: `finishbinexpneg` for `x << K`:
- PUC transforms `x << K` to `x >> (-K)` and emits SHRI
- `x << 127` → SHRI with sC=-127
- `x << -127` → SHRI with sC=127

Implementation in genBinOp Shl path, after SHLI check:
```zig
// finishbinexpneg: x << K → SHRI(x, -K)
if (n.op == .Shl and rhs_const != null) {
    if (rhs_const.?.kid == null and fitsSC(rhs_const.?.ival)) {
        const negated = -rhs_const.?.ival;
        // Emit SHRI with negated value
    }
}
```

**Verify:** `x << 127` emits SHRI not SHL.

---

## Task 6: RETURN k=close (PUC-faithful, cleanup)

**File:** `src/lua/codegen_bc.zig`, `src/lua/vm.zig`

Depends on: Task 1.

Currently: luaK_finish rewrites RETURN0→RETURN with B=1 for needclose functions. With k-bit: RETURN0 can stay RETURN0 with k=1 (close upvalues before returning).

- Codegen: emit RETURN0/RETURN1 with k=1 when needclose, instead of rewriting to RETURN
- VM RETURN0/RETURN1 handlers: if `inst.k == 1`, close upvalues before completing return
- Delete the luaK_finish RETURN0→RETURN rewrite in genFunctionBody

**Verify:** code.lua check #93 (goto+close) passes, all existing tests pass.

---

## Task 7: isfloat in k-bit for Comparisons (PUC-faithful, cleanup)

**File:** `src/lua/codegen_bc.zig`, `src/lua/vm.zig`

Depends on: Task 1. Partially covered by Task 1.

Move comparison I-variant isfloat flag from C-field bit encoding to k-bit:
- EQI/LTI/LEI/GTI/GEI: `emitABCk(op, a, imm, 0, isfloat, line)` 
- VM: `isfloat = inst.k == 1`
- C field holds only the immediate value (no bit hacks)

This is a cleanup of the existing C-field bit hack. May already be done in Task 1.

---

## Task 8: Delete Dead bc_vm.zig + Final Verification

**File:** Delete `src/lua/bc_vm.zig` (318 lines, dead code)

- Verify no imports reference it
- Delete file
- Full matrix + smoke + perf + mismatch count
- Update README

---

## Execution Order

```
Task 1 (k-bit) ──┬── Task 2 (LOADI range)
                 ├── Task 3 (RK encoding)  
                 ├── Task 6 (RETURN k=close)
                 └── Task 7 (isfloat k-bit)
                 
Task 4 (LOADNIL merge) ── independent
Task 5 (SHLI/SHRI) ── independent
Task 8 (cleanup + verify) ── last
```

Tasks 4+5 can be done in parallel with Task 1 (they don't depend on k-bit). But to minimize regression risk, do sequentially: Task 1 → Task 4 → Task 5 → Tasks 2,3,6,7 → Task 8.
