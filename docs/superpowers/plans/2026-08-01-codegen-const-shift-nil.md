# Codegen: Const Local Initializer Skip + SHLI + LOADNIL Coalescing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Use model `glm-5.2`.

**Goal:** Close ~7 of the remaining 18 code.lua mismatches by skipping codegen for `<const>` local constant initializers, implementing SHLI, and adding LOADNIL cross-statement coalescing for nil-to-local assignments.

**Architecture:** Three independent fixes. Const local skip intercepts the value-evaluation loop in `genLocalDecl` before code is emitted. SHLI mirrors the existing SHRI path for `Shr` with a constant LHS swap. LOADNIL coalescing uses PUC's `luaK_nil` previous-instruction merge pattern — safe because it only fires when the previous instruction is LOADNIL with adjacent range.

---

## Task 1: Skip Codegen for `<const>` Local Constant Initializers (5 mismatches)

**Files:** `src/lua/codegen_bc.zig` — `genLocalDecl` (search `fn genLocalDecl`)

**Problem:** `local k255 <const> = 255` emits LOADI even though the value is never read from the register (all references fold to the constant). PUC emits no code for `<const>` locals with compile-time constant initializers.

- [ ] **Step 1: Read genLocalDecl value-evaluation section**

Search `fn genLocalDecl`. Read the section that evaluates initializer values (around lines 4867-4900). The current code evaluates ALL values first via `genExpNextReg`, then matches them to names.

- [ ] **Step 2: Skip codegen for const-local constant values**

In the value-evaluation loop, before calling `genExpNextReg(val)`, check if the corresponding name has `<const>` attribute and the value is a compile-time constant:

For the main loop (values[0..len-1]):
```zig
for (values[0..@max(values.len, 1) -| 1]) |val, i| {
    // PUC RDKCTC: <const> local with constant initializer emits no code.
    if (i < n.names.len) {
        const dn = n.names[i];
        const attr = dn.prefix_attr orelse dn.suffix_attr;
        if (attr != null and attr.?.kind == .Const) {
            if (self.genConstExpDesc(val) != null) {
                _ = try self.allocReg(); // allocate register slot only
                continue;
            }
        }
    }
    _ = try self.genExpNextReg(val);
}
```

For the last value (around the `else =>` branch):
```zig
else => {
    // Check if last value is for a <const> local with constant initializer
    if (values.len > 0 and values.len <= n.names.len) {
        const dn = n.names[values.len - 1];
        const attr = dn.prefix_attr orelse dn.suffix_attr;
        if (attr != null and attr.?.kind == .Const) {
            if (self.genConstExpDesc(last) != null) {
                _ = try self.allocReg();
                break; // skip to declaration
            }
        }
    }
    _ = try self.genExpNextReg(last);
},
```

IMPORTANT: 
- `self.allocReg()` still allocates the register slot (PUC does this — const locals have register numbers)
- `self.captureConstLocalValue` at line 4927 will still capture the value correctly because it calls `genConstExpDesc` itself
- The register is allocated but no LOADI/LOADK/LOADNIL is emitted for it

- [ ] **Step 3: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && cat > /tmp/test_const_init.lua << 'EOF'
local k255 <const> = 255
local kNil <const> = nil
local function f(a) a[k255] = 1 end
local c = T.listcode(f)
for i = 1, #c do print(i, c[i]) end
EOF
timeout 10 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_const_init.lua 2>&1
```
Expected: No LOADI for k255 — it's a const local.

```bash
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
cd lua-5.5.0/testes && timeout 30 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_code_final.lua 2>&1 | grep -c MISMATCH
```
Matrix MUST be ≥27/31. Mismatch count should drop by ~5.

```bash
git add src/lua/codegen_bc.zig
git commit -m "codegen: skip codegen for <const> local constant initializers

local k255 <const> = 255 no longer emits LOADI — the value is captured
at compile time (PUC RDKCTC). Eliminates 5 code.lua mismatches."
```

---

## Task 2: SHLI Implementation (shift left immediate)

**Files:** `src/lua/codegen_bc.zig` — `constBinOpInfo` (search `fn constBinOpInfo`)

**Problem:** `k1 << x` should emit SHLI (shift left immediate) but currently emits LOADI + SHL. PUC swaps operands: `K << R` → SHLI.

- [ ] **Step 1: Read the existing SHRI implementation**

Search for `.Shr` in `constBinOpInfo`. SHRI is already implemented for `R >> K`. Use it as a template for SHLI.

- [ ] **Step 2: Add SHLI case for Shl with constant LHS**

PUC's logic: when op is `Shl` and LHS is a small integer constant:
1. Swap operands (constant becomes sC, register becomes B)
2. Emit SHLI: `R[A] = sC(C) << R[B]`

In `constBinOpInfo`, the function receives `op` (TokenKind) and `nc` (NumConst for RHS). For SHLI, the constant must be on the LEFT. The commutative swap mechanism won't help because SHL is NOT commutative.

Instead, handle this in `genBinOp` before the K/I-variant path. When `n.op == .Shl` and LHS is a numeric constant and RHS is not:

```zig
// In genBinOp, after rhs_const computation, before the arithmetic path:
if (n.op == .Shl and rhs_const == null) {
    const lhs_nc = self.numericConstFromExp(n.lhs);
    if (lhs_nc) |lc| {
        if (lc.kid == null and fitsSC(lc.ival)) {
            // SHLI: R[dst] = sC << R[rhs]
            rhs_const = lc;
            flip = true;
            actual_rhs = n.lhs;
            lhs_ed = try self.genExpDesc(n.rhs);
            lhs_start_pc = @intCast(self.builder.pc());
            // Mark that SHLI should be used instead of SHL
            use_shli = true;
        }
    }
}
```

Then in the K/I-variant emission, check `use_shli` and emit SHLI:

Actually, this is complex because the current K/I-variant path goes through `constBinOpInfo` which maps op→opcode. A simpler approach: add `.Shl` to `constBinOpInfo` when the constant is the LHS (detected by a flag).

SIMPLEST approach: handle SHLI as a special case in `genBinOp`, similar to how the commutative swap handles ADD/MUL:

```zig
// Before the arithmetic path, after rhs_const:
if (n.op == .Shl and rhs_const == null) {
    const lhs_nc = self.numericConstFromExp(n.lhs);
    if (lhs_nc) |lc| {
        if (lc.kid == null) {
            // Emit SHLI directly: R[dst] = sC(lc.ival) << R[rhs_reg]
            lhs_ed = try self.genExpDesc(n.rhs);
            const lhs_reg = try self.exp2anyreg(&lhs_ed);
            // Reset line fixup range
            lhs_start_pc = @intCast(self.builder.pc());
            const dst = if (dst_hint) |h| h else try self.allocReg();
            _ = try self.builder.emitABC(.shli, dst, lhs_reg, int2sC(lc.ival), line);
            _ = try self.builder.emitABC(.mmbini, lhs_reg, int2sC(lc.ival), encodeTms(TMS_SHL, true), line);
            return dst;
        }
    }
}
```

- [ ] **Step 3: Build, test, commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && cat > /tmp/test_shli.lua << 'EOF'
local k1 <const> = 1
local function f(x) return k1 << x end
local c = T.listcode(f)
for i = 1, #c do print(i, c[i]) end
EOF
timeout 10 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_shli.lua 2>&1
```
Expected: `SHLI` not `LOADI, SHL`.

```bash
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
git add src/lua/codegen_bc.zig
git commit -m "codegen: SHLI for shift-left with constant LHS

k1 << x now emits SHLI (R[A] = sC << R[B]) instead of LOADI+SHL.
Mirrors PUC codebitwise with isSCint(e1) swap."
```

---

## Task 3: Nil-to-Local Direct Store + LOADNIL Merge (2 mismatches)

**Files:** `src/lua/codegen_bc.zig` — `genAssign` nil-to-local path, `genLocalDecl`

**Problem:** `d = nil; c = nil; b = nil; a = nil` emits separate LOADNIL+MOVE pairs instead of coalescing into a single LOADNIL.

- [ ] **Step 1: Add emitLoadNil helper with previous-instruction merge**

Add a helper function near the top of the Codegen struct:

```zig
/// PUC luaK_nil: emit LOADNIL for R[from..from+n-1], merging with the
/// previous instruction if it's also LOADNIL with adjacent range.
fn emitLoadNil(self: *Codegen, from: u8, n: u8, line: u32) Error!void {
    const l: u8 = from + n - 1;
    if (self.builder.code.items.len > 0) {
        const prev_idx = self.builder.code.items.len - 1;
        const prev = self.builder.code.items[prev_idx];
        if (@as(bc.Op, @enumFromInt(prev.op)) == .loadnil) {
            const pfrom: u8 = prev.a;
            const pl: u8 = pfrom + prev.b;
            // PUC adjacency: ranges touch or overlap
            if ((pfrom <= from and from <= pl + 1) or
                (from <= pfrom and pfrom <= l + 1))
            {
                const new_from: u8 = @min(pfrom, from);
                const new_l: u8 = @max(pl, l);
                self.builder.code.items[prev_idx] =
                    bc.Instruction.make(.loadnil, new_from, new_l - new_from, 0);
                return;
            }
        }
    }
    _ = try self.builder.emitABC(.loadnil, from, l - from, 0, line);
}
```

- [ ] **Step 2: Use emitLoadNil for nil-to-local assignments**

In `genAssign`, find where `nil` is assigned to a local variable. Instead of LOADNIL+MOVE, call `emitLoadNil` directly with the local's register.

Search for how nil assignment to a local is currently handled. It likely goes through `discharge2reg` which emits LOADNIL to a temp, then the local store does MOVE. Replace with direct `emitLoadNil(local_reg, 1, line)`.

- [ ] **Step 3: Replace genLocalDecl LOADNIL calls with emitLoadNil**

In `genLocalDecl`, replace all `emitABC(.loadnil, ...)` calls with `emitLoadNil(...)`.

- [ ] **Step 4: Build, test (including goto.lua regression), commit**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | grep -E 'goto|locals|parity'
```

goto.lua AND locals.lua MUST pass. If either fails, the merge is too aggressive — revert.

```bash
git add src/lua/codegen_bc.zig
git commit -m "codegen: luaK_nil-style LOADNIL merge with previous instruction

Nil-to-local assignments now call emitLoadNil which checks if the
previous instruction is LOADNIL with adjacent range, merging instead
of emitting new. Mirrors PUC luaK_nil."
```

---

## Self-Review

**Coverage:** Task 1 fixes mismatches #3,#7+cascading (5 mismatches). Task 2 enables SHLI (not currently in mismatch list but needed for code.lua SHL checks). Task 3 fixes #1,#2 (2 mismatches).

**Deferred:** 6 mismatches need instruction format `k` bit (RK encoding + LOADI range). This is an architecture-level change affecting all instruction encode/decode. Separate plan needed.
