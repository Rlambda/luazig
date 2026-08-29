# Instruction Format: Add k-bit (PUC-faithful 7-bit op + 1-bit k)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Use model `glm-5.2`.

**Goal:** Add a 1-bit `k` flag to the instruction format, matching PUC Lua 5.5's layout: `op:u7, a:u8, k:u1, b:u8, c:u8`. The k-bit carries per-opcode semantics: **flip flag** for commutative arith (currently hacked as C-field 0x80 in MMBINK), **isfloat** for comparison I-variants (currently hacked in C-field bits), and **close-on-return** for RETURN/TAILCALL (currently handled via the luaK_finish RETURN0→RETURN rewrite). Optionally extends LOADI/LOADF to 17-bit sBx.

**Architecture:** Change `Instruction` from `{ op:u8, a:u8, b:u8, c:u8 }` to `{ op:u7, a:u8, k:u1, b:u8, c:u8 }`. This is a PUC binary-compatible layout. All 84 current opcodes fit in 7 bits (max 128). No opcodes are deleted — PUC 5.5 also has ADDK/MULK/etc. The k-bit eliminates existing hacks (C-field 0x80 flip, isfloat encoding) and enables PUC-faithful RETURN k-bit for close.

**Tech Stack:** Zig (bytecode.zig, vm.zig, codegen_bc.zig).

---

## PUC Reference

PUC 5.5 bit layout: `C(8) | B(8) | k(1) | A(8) | Op(7)` [bit 31→0]
Zig packed struct (LSB-first): `op:u7, a:u8, k:u1, b:u8, c:u8`

PUC uses k-bit for:
- Arith ops (ADD/ADDK/ADDI/etc.): `GETARG_k(i)` = flip flag for commutative swap metamethod order
- Comparison I-variants (EQI/LTI/LEI/GTI/GEI): k = isfloat (operand was originally a float)
- RETURN/TAILCALL: k = 1 signals close upvalues before returning

PUC `finishbinexpval` (lcode.c:1497): `luaK_codeABCk(fs, op, v1, v2, 0, flip)` — arith op gets k=flip.
PUC `op_arith` macro: `luaT_trybinassocTM(L, ..., GETARG_k(i), ...)` — reads flip from instruction's own k-bit.

---

## Task 1: Change Instruction Struct + Constructors + Op Enum

**Files:** `src/lua/bytecode.zig`

- [ ] **Step 1: Change Instruction packed struct (line 26)**

```zig
pub const Instruction = packed struct(u32) {
    op: u7,
    a: u8,
    k: u1,
    b: u8,
    c: u8,
```

- [ ] **Step 2: Change Op enum to enum(u7) (line 86)**

```zig
pub const Op = enum(u7) {
```

84 variants fit in 7 bits (max 128). No opcodes deleted.

- [ ] **Step 3: Update constructors (lines 33-74)**

Add `.k = 0` to all existing constructors (`make`, `simple`, `jump`, `extra`). Add `makeK`:

```zig
pub fn makeK(op: Op, a: u8, b: u8, c: u8, k: bool) Instruction {
    return .{ .op = @intFromEnum(op), .a = a, .k = if (k) 1 else 0, .b = b, .c = c };
}
```

- [ ] **Step 4: Verify jumpOffset/extraArg unaffected**

`jumpOffset` reads `a | (b << 8) | (c << 16)` — k bit (at position 15) is between a and b but NOT included in the 24-bit offset assembly. Correct.

- [ ] **Step 5: Build (expect errors in vm.zig and codegen_bc.zig — fixed in Tasks 2-3)**

---

## Task 2: Update VM Dispatch — Read k-bit for Flip

**Files:** `src/lua/vm.zig`

- [ ] **Step 1: Replace mmbinFlip with inst.k**

Currently `mmbinFlip` peeks the NEXT instruction to read flip from C-field 0x80. After the format change, flip is in the CURRENT instruction's k-bit. Delete `mmbinFlip` and use `inst.k` directly.

In all K-variant handlers (ADDK, SUBK, MULK, MODK, POWK, DIVK, IDIVK, BANDK, BORK, BXORK) and I-variant handlers (ADDI, SHLI, SHRI):

```zig
// Before:
const flip = mmbinFlip(ctx, ctx.pc);

// After:
const flip = inst.k;
```

- [ ] **Step 2: Update comparison I-variant handlers for isfloat**

Currently isfloat is encoded in C-field bits. With the k-bit, move isfloat to `inst.k`. In EQI/LTI/LEI/GTI/GEI handlers:

```zig
// Before: read isfloat from C field bits
// After: isfloat = inst.k == 1
```

Read the current comparison handler code to understand the existing isfloat encoding before changing it.

- [ ] **Step 3: Update RETURN0→RETURN rewrite for k=close**

Currently the codegen rewrites RETURN0 to RETURN with B=1 for needclose functions (luaK_finish in codegen_bc.zig). With the k-bit, RETURN can carry k=1 for close, and RETURN0 can stay RETURN0 with k=1. Check if this simplifies the existing rewrite.

Actually, PUC's RETURN0 never has k=1 (it means "return 0 values, no close"). Only RETURN and TAILCALL get k=1 for close. The existing luaK_finish rewrite (RETURN0→RETURN+B=1) can be replaced with RETURN0+k=1 (no opcode change, just set k). But this requires the VM's RETURN0 handler to check k for close.

Read the VM's RETURN0 handler. If k=1, it should close upvalues before returning. This may already be handled by `completeBytecodeExecFrame` which always closes upvalues.

- [ ] **Step 4: Update op-property table, opcodeDisplayName, listcode dump**

Search for switches that map opcodes to properties. No opcodes changed — just ensure the switch is exhaustive with the same opcode set.

For listcode dump: add `(k)` suffix when `inst.k == 1` to match PUC's `buildop` format which appends `" (k)"` when the k bit is set.

- [ ] **Step 5: Build (expect codegen errors — fixed in Task 3)**

---

## Task 3: Update Codegen — Encode Flip in k-bit

**Files:** `src/lua/codegen_bc.zig`

- [ ] **Step 1: Add emitABCk to ProtoBuilder**

In `bytecode.zig`, `ProtoBuilder`:

```zig
pub fn emitABCk(self: *ProtoBuilder, op: Op, a: u8, b: u8, c: u8, k: bool, line: u32) !u32 {
    return self.emit(Instruction.makeK(op, a, b, c, k), line);
}
```

- [ ] **Step 2: Change K/I-variant arith emission to use k-bit for flip**

In `genBinOp`, the MMBINI/MMBINK emission currently encodes flip via `encodeTms(event, flip)` (C-field 0x80 hack). Change to emit the arith op WITH the flip in the k-bit, and MMBIN with plain event (no 0x80 hack).

For K-variant path (after `tryEmitConstBinOp`):
```zig
// Before:
_ = try self.builder.emitABC(emit_info.opcode, dst, lhs_reg, emit_info.c_field, line);
_ = try self.builder.emitABC(.mmbink, lhs_reg, ..., encodeTms(event, flip), line);

// After:
_ = try self.builder.emitABCk(emit_info.opcode, dst, lhs_reg, emit_info.c_field, flip, line);
_ = try self.builder.emitABCk(.mmbink, lhs_reg, ..., event, flip, line);
```

For I-variant path (ADDI/SHLI/SHRI):
```zig
// Before:
_ = try self.builder.emitABC(.addi, dst, lhs_reg, int2sC(nc.ival), line);
_ = try self.builder.emitABC(.mmbini, lhs_reg, int2sC(nc.ival), encodeTms(event, flip), line);

// After:
_ = try self.builder.emitABCk(.addi, dst, lhs_reg, int2sC(nc.ival), flip, line);
_ = try self.builder.emitABCk(.mmbini, lhs_reg, int2sC(nc.ival), event, flip, line);
```

For register-variant path (ADD/SUB/MUL/etc.):
```zig
// Before: no flip (register ops don't swap)
// After: register ops can also have flip from commutative swap
_ = try self.builder.emitABCk(op, dst, lhs_reg, rhs_reg, flip, line);
_ = try self.builder.emitABCk(.mmbin, lhs_reg, rhs_reg, event, flip, line);
```

- [ ] **Step 3: Delete encodeTms helper**

The `encodeTms` function is no longer needed — flip goes in the k-bit, not the C-field. Delete it and replace all `encodeTms(event, flip)` calls with plain `event`.

- [ ] **Step 4: Update comparison I-variant emission**

For EQI/LTI/LEI/GTI/GEI with float operands, encode isfloat in the k-bit instead of C-field bits:

```zig
// Before: C-field bit encoding for isfloat
// After: emitABCk(.eqi, lhs_reg, imm, isfloat, line)
```

Read the current comparison emission code to understand the existing encoding.

- [ ] **Step 5: Build and full regression test**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
cd lua-5.5.0/testes && timeout 30 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_code_final.lua 2>&1 | grep -c MISMATCH
```

Matrix MUST be ≥27/31. Mismatch count should stay at 10 or decrease.

- [ ] **Step 6: Commit**

```bash
git add src/lua/bytecode.zig src/lua/vm.zig src/lua/codegen_bc.zig
git commit -m "instruction format: add k-bit (7-bit op + 1-bit k, PUC-faithful)

Instruction: op:u7, a:u8, k:u1, b:u8, c:u8 (PUC binary-compatible).
k-bit replaces C-field 0x80 hack for commutative flip flag.
Arith ops: k=flip (metamethod operand order).
Comparison I-variants: k=isfloat.
All 84 opcodes fit in 7 bits (128 max). No opcodes changed."
```

---

## Task 4: Delete Dead Code

**Files:** Delete `src/lua/bc_vm.zig`

- [ ] **Step 1: Verify bc_vm.zig is dead (not imported anywhere)**

```bash
grep -r 'bc_vm' src/ build.zig 2>/dev/null
```

- [ ] **Step 2: Delete and build**

```bash
rm src/lua/bc_vm.zig
zig build -Doptimize=ReleaseFast 2>&1 | tail -5
```

---

## Task 5: Optional — Extend LOADI/LOADF to 17-bit sBx

**Files:** `src/lua/bytecode.zig`, `src/lua/vm.zig`, `src/lua/codegen_bc.zig`

- [ ] **Step 1: Encode sBx across b:c:k (17 bits)**

LOADI/LOADF use B:C as a 16-bit signed immediate. With the k-bit available, extend to 17-bit by including k as the sign extension or MSB:

```zig
// Encode: offset = value + OFFSET_sBx (65535)
// Bits: k=bit16, b=bits0-7, c=bits8-15
pub fn loadImm(op: Op, a: u8, value: i32) Instruction {
    const off: u32 = @bitCast(value +% 65535);
    return .{ .op = @intFromEnum(op), .a = a, .k = @truncate(off >> 16), .b = @truncate(off), .c = @truncate(off >> 8) };
}
```

- [ ] **Step 2: Update VM decode**

```zig
.loadi => {
    const bits: u17 = @as(u17, b) | (@as(u17, c) << 8) | (@as(u17, inst.k) << 16);
    const signed: i32 = @as(i32, @intCast(bits)) - 65535;
    ctx.regs[a] = .{ .Int = signed };
},
```

- [ ] **Step 3: Update codegen range check**

```zig
if (parsed >= -65535 and parsed <= 65535) {
    // Use LOADI with 17-bit sBx
```

- [ ] **Step 4: Build, test, commit**

---

## Task 6: Final Verification + README

- [ ] **Step 1: Matrix + smoke + mismatch count + perf**
- [ ] **Step 2: Update README**
- [ ] **Step 3: Commit**

---

## Self-Review

**Coverage:** k-bit for flip (Task 2-3), k-bit for isfloat (Task 2-3), k-bit for RETURN close (Task 2), LOADI/LOADF range (Task 5). Dead code cleanup (Task 4).

**Key insight from analysis:** PUC 5.5 HAS K-variant opcodes (ADDK etc.) — luazig's existing K-variant opcodes are PUC-faithful and should NOT be deleted. The k-bit is for flip/isfloat/close flags, NOT for RK encoding.

**Risk areas:**
- Task 2 Step 1: changing `mmbinFlip(ctx, ctx.pc)` to `inst.k` — must verify all 15+ K/I-variant handlers
- Task 3 Step 4: comparison isfloat encoding change — must understand current C-field bit layout
- Task 5: LOADI/LOADF 17-bit changes the encoding of ALL existing LOADI/LOADF instructions

**Execution note:** Use model `glm-5.2` for all subagent dispatches.
