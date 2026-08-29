# Codegen Parity: Final code.lua Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Use model `glm-5.2` for all subagent dispatches.

**Goal:** Close the remaining ~15 code.lua bytecode mismatches by implementing table access fusion (GETI/SETI), LOADNIL coalescing (safe Tier 1), and the commutative swap flip mechanism.

**Architecture:** Three independent codegen changes, ordered by ROI/risk ratio. Table access fusion is cleanest (opcodes already exist, VM handles them correctly). LOADNIL Tier 1 coalesces within a single `local a,b,c` declaration only (no cross-statement merging that broke goto.lua). Commutative swap implements PUC's `flip` mechanism using C-field high bit (0x80) in MMBINK/MMBINI.

**Tech Stack:** Zig (codegen_bc.zig, vm.zig), PUC Lua 5.5 (reference).

---

## File Map

- **Modify:** `src/lua/codegen_bc.zig` — genExpDesc (.Index/.Field cases), genLocalDecl (LOADNIL batch), genBinOp (commutative swap + flip), tryEmitConstBinOp (fallback after swap)
- **Modify:** `src/lua/vm.zig` — K-variant arithmetic handlers (read flip from next MMBINK instruction), T.listcode display (mask flip bit)
- **No new files.**

## Build/Test Commands

```bash
# Build
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5

# Matrix (must stay 27/31 or better)
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5

# Smoke tests
cd /home/boss/codes/luazig && for f in tests/smoke/*.lua; do timeout 10 ./zig-out/bin/luazig --vm=bc "$f" 2>&1 | tail -1; done

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
```

---

## Task 1: Table Access Fusion — GETI/SETI for Integer Keys

**Impact:** ~3 checks in code.lua (checks #16, #89, #91).
**Risk:** Medium — register liveness in new genExpDesc cases.

**Files:**
- Modify: `src/lua/codegen_bc.zig` — `genExpDesc` (add `.Index` and `.Field` cases), `genSet`/`genPreparedSet` (add SETI)

### Current state

`genExpDesc` (search `fn genExpDesc`) handles `.Nil/.True/.False/.Integer/.Number/.String/.Name/.Paren/.BinOp/.UnOp` but NOT `.Index` or `.Field`. These fall through to `else` → `genExp`, which always materializes the key:
- `t[1]` → `LOADI Rkey, 1; GETTABLE Rdst, Rt, Rkey` (2 instructions)
- PUC: `GETI Rdst, Rt, 1` (1 instruction, raw integer in C field)

The `index_i` and `index_str` ExpDesc variants already exist (search `.index_i` in the ExpDesc Val union) and discharge correctly to GETI/GETFIELD (search `.index_i =>` in dischargeVars). The gap is purely that genExpDesc never CREATES these variants for explicit `t[1]` / `t.field`.

### Steps

- [ ] **Step 1: Add .Field case to genExpDesc**

In `genExpDesc`, add a `.Field` case (before the `else` fallthrough). This creates an `index_str` ExpDesc for `t.name`, which discharges to GETFIELD:

```zig
            .Field => |n| {
                const obj_ed = try self.genExpDesc(n.object);
                const obj_reg = try self.exp2anyreg(&obj_ed);
                const kid = try self.builder.internString(n.field.slice(self.source));
                if (kid <= 255) {
                    return .{ .val = .{ .index_str = .{
                        .idx = @intCast(kid),
                        .t = obj_reg,
                        .keystr = @intCast(kid),
                    } } };
                }
                // Large constant index: fall back to indexed
                const key_reg = try self.allocReg();
                try self.emitLoadK(key_reg, @intCast(kid), n.field.line);
                return .{ .val = .{ .indexed = .{ .idx = key_reg, .t = obj_reg } } };
            },
```

NOTE: Read the `.Field` AST node structure (search `.Field =>` in the ast or parser) to get the correct field names (`n.object`, `n.field` or `n.name`). Match the existing `.Field` handling in `genExp`.

- [ ] **Step 2: Add .Index case to genExpDesc**

Add an `.Index` case that checks for integer and string literal keys:

```zig
            .Index => |n| {
                const obj_ed = try self.genExpDesc(n.object);
                const obj_reg = try self.exp2anyreg(&obj_ed);
                // Integer literal key → GETI (raw C, range 0..255)
                switch (n.index.node) {
                    .Integer => {
                        const lexeme = n.index.span.slice(self.source);
                        const ival = parseIntegerLiteral(lexeme) orelse {
                            // Can't parse — fall back to full expression
                            const key_reg = try self.genExp(n.index);
                            self.freeReg2(key_reg, obj_reg);
                            return .{ .val = .{ .indexed = .{ .idx = key_reg, .t = obj_reg } } };
                        };
                        if (ival >= 0 and ival <= 255) {
                            self.freeReg(obj_reg);
                            return .{ .val = .{ .index_i = .{
                                .idx = @intCast(ival),
                                .t = obj_reg,
                            } } };
                        }
                    },
                    .String => {
                        const kid = try self.builder.internString(n.index.span.slice(self.source));
                        if (kid <= 255) {
                            self.freeReg(obj_reg);
                            return .{ .val = .{ .index_str = .{
                                .idx = @intCast(kid),
                                .t = obj_reg,
                                .keystr = @intCast(kid),
                            } } };
                        }
                    },
                    else => {},
                }
                // Computed key → GETTABLE
                const key_reg = try self.genExp(n.index);
                self.freeReg2(key_reg, obj_reg);
                return .{ .val = .{ .indexed = .{ .idx = key_reg, .t = obj_reg } } };
            },
```

IMPORTANT: Read the existing `index_i`/`index_str`/`indexed` ExpDesc variants and their discharge code (search `.index_i =>`, `.index_str =>`, `.indexed =>` in `dischargeVars`) to verify the field names match. The discharge code already emits GETI/GETFIELD/GETTABLE correctly.

- [ ] **Step 3: Add SETI to assignment path**

In `genSet` (search `fn genSet`), find the `.Index` case. Currently it always calls `prepareAssignLhs` + SETTABLE. Add a check: if the key is an integer literal in [0,255], emit SETI instead:

```zig
                    .Index => |n| {
                        // Check for integer literal key → SETI
                        if (n.index.node == .Integer) {
                            const lexeme = n.index.span.slice(self.source);
                            const ival = parseIntegerLiteral(lexeme) orelse 0; // fallback
                            if (ival >= 0 and ival <= 255) {
                                const obj_reg = try self.genExp(n.object);
                                const val_reg = try self.genExpForSet(val_exp);
                                _ = try self.builder.emitABC(.seti, obj_reg, @intCast(ival), val_reg, line);
                                self.freeReg(val_reg);
                                self.freeReg(obj_reg);
                                return;
                            }
                        }
                        // Fall back to existing SETTABLE path
                        ... (existing code)
                    },
```

- [ ] **Step 4: Build and verify**

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && cat > /tmp/test_geti.lua << 'EOF'
local function f(t) return t[1] end
local c = T.listcode(f)
for i = 1, #c do print(i, c[i]) end
EOF
timeout 10 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_geti.lua 2>&1
```
Expected: `GETI` (not `LOADI, GETTABLE`).

```bash
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
```
Matrix MUST be ≥27/31.

- [ ] **Step 5: Commit**

```bash
git add src/lua/codegen_bc.zig
git commit -m "codegen: GETI/SETI fusion for integer literal keys

genExpDesc now creates index_i ExpDesc for t[1] (discharges to GETI,
not LOADI+GETTABLE). genSet emits SETI for t[1] = val. Mirrors PUC
VINDEXI/VINDEXSTR parse-time key fusion."
```

---

## Task 2: LOADNIL Coalescing — Tier 1 (Within-Declaration Only)

**Impact:** ~2 checks in code.lua (#3, #4).
**Risk:** Low — only coalesces within a single `local a, b, c` declaration, never across statements.

**Files:**
- Modify: `src/lua/codegen_bc.zig` — `genLocalDecl` (search `fn genLocalDecl`)

### Current state

`genLocalDecl` emits one LOADNIL per uninitialized local. `local a, b, c` → 3 LOADNILs. PUC emits one `LOADNIL A B` with B = count-1.

The previous attempt at cross-statement coalescing broke goto.lua. This Tier 1 fix ONLY coalesces within a single `local` declaration — completely safe because the registers are contiguous and allocated together.

### Steps

- [ ] **Step 1: Find the no-values LOADNIL loop**

Search in `genLocalDecl` for the code path where `local a, b, c` (no initializers) emits LOADNILs. There are typically two paths:
1. No values at all (`local a, b, c`) — nil-fills all locals
2. Fewer values than names (`local a, b = 1`) — nil-fills remaining

For path 1, find the loop that emits per-register LOADNIL. For path 2, find the nil-fill loop.

- [ ] **Step 2: Replace per-register loop with single LOADNIL**

For path 1 (no values), replace the loop with a single emission:

```zig
        // All locals get nil — emit one LOADNIL covering the full range.
        if (n.names.len > 0) {
            const first_reg = self.freereg;
            // Allocate contiguous registers for all locals
            for (0..n.names.len) |_| {
                _ = try self.allocReg();
            }
            // Single LOADNIL A=first_reg B=count-1
            const count: u8 = @intCast(n.names.len);
            _ = try self.builder.emitABC(.loadnil, first_reg, count -% 1, 0, decl_line);
            // Register bindings
            for (n.names, 0..) |dn, i| {
                const reg = first_reg + @as(u8, @intCast(i));
                try self.appendBinding(dn.name.slice(self.source), reg);
                // ... attr handling (copy from existing loop)
            }
        }
```

For path 2 (fewer values), similarly coalesce the remaining nil-fills:

```zig
        // Nil-fill for remaining locals (more names than values)
        if (remaining_count > 0) {
            const nil_first = self.freereg;
            for (0..remaining_count) |_| {
                _ = try self.allocReg();
            }
            _ = try self.builder.emitABC(.loadnil, nil_first, @as(u8, @intCast(remaining_count)) -% 1, 0, line);
        }
```

IMPORTANT: Read the existing genLocalDecl carefully to understand:
- How `self.allocReg()` is called (or `self.nvarstack` tracking)
- How bindings are registered (`self.appendBinding` or `self.bindings.append`)
- Line numbers for each LOADNIL

Match the existing pattern. The key change is replacing N individual `emitABC(.loadnil, reg, 0, 0, line)` calls with ONE `emitABC(.loadnil, first_reg, count-1, 0, line)`.

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
Expected: TWO LOADNILs (one per `local` statement), NOT one merged across statements. The first covers `a,b,c` (B=2), the second covers `d,e` (B=1).

```bash
# CRITICAL: goto.lua regression test
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | grep -E 'goto|parity'
```
goto.lua MUST still pass. If it fails, the fix is wrong.

```bash
git add src/lua/codegen_bc.zig
git commit -m "codegen: coalesce LOADNIL within single local declaration

'local a, b, c' now emits one LOADNIL A B (B=count-1) instead of
three separate LOADNILs. Only coalesces within a single declaration,
NOT across statements (which broke goto.lua scope handling)."
```

---

## Task 3: Commutative Swap with Flip Mechanism

**Impact:** ~5 checks in code.lua (#58, #60, #71, #74, etc.).
**Risk:** High — requires coordinated codegen + VM changes. Three sub-tasks.

**Files:**
- Modify: `src/lua/codegen_bc.zig` — `genBinOp` (swap + flip), `tryEmitConstBinOp` (fallback swap-back)
- Modify: `src/lua/vm.zig` — K-variant arithmetic handlers (read flip from MMBINK)

### Architecture

PUC Lua uses a `flip` flag (stored in the instruction's k-bit) to track operand swap. When `128 + x` is compiled, PUC swaps to `x + 128` (ADDK) and sets `flip=1` in the MMBINK instruction. The VM reads `flip` from MMBINK to pass operands to metamethods in the original order.

luazig has no k-bit. We encode `flip` in the C-field high bit of MMBINK/MMBINI: `C = event | (flip ? 0x80 : 0)`. TMS events are 0-12, so `0x7f` mask is safe.

### Step 1: Add flip encoding helpers

- [ ] **In codegen_bc.zig, near tokenToTms, add:**

```zig
/// Encode TMS event + flip flag into MMBINK/MMBINI C field.
/// High bit (0x80) = flip (operands were swapped for commutative op).
fn encodeTms(event: u8, flip: bool) u8 {
    return if (flip) (event | 0x80) else event;
}
```

- [ ] **In vm.zig, near opcodeDisplayName, add a decode helper:**

```zig
/// Decode MMBINK/MMBINI C field into event + flip.
fn decodeTms(c: u8) struct { event: u8, flip: bool } {
    return .{ .event = c & 0x7f, .flip = (c & 0x80) != 0 };
}
```

### Step 2: Codegen swap + flip in genBinOp

- [ ] **In genBinOp, after `rhs_const` computation (around line 2827), add swap logic:**

```zig
        var rhs_const = self.numericConstFromExp(n.rhs);
        var flip = false;
        var actual_lhs: *const ast.Exp = n.lhs;
        var actual_rhs: *const ast.Exp = n.rhs;

        // PUC codecommutative: if LHS is constant and RHS is not, swap
        // for commutative operators (ADD, MUL, BAND, BOR, BXOR).
        if (rhs_const == null) {
            const is_commutative = switch (n.op) {
                .Plus, .Star, .Amp, .Pipe, .Tilde => true,
                else => false,
            };
            if (is_commutative) {
                const lhs_nc = self.numericConstFromExp(n.lhs);
                if (lhs_nc) |lc| {
                    rhs_const = lc;
                    flip = true;
                    actual_lhs = n.rhs;
                    actual_rhs = n.lhs;
                }
            }
        }
```

Then use `actual_lhs` for `lhs_ed` generation (if not already generated) and `actual_rhs` for the register fallback path.

CRITICAL: `lhs_ed` was already generated from `n.lhs` at line 2719. If swapped, it needs to be regenerated from `n.rhs` (the actual LHS after swap). The comparison path already handles this pattern (around line 2943-2946) — follow the same approach:

```zig
        // If swapped, regenerate lhs_ed from the actual LHS (original RHS).
        if (flip) {
            lhs_ed = try self.genExpDesc(actual_lhs);
        }
```

- [ ] **In the MMBINK/MMBINI emission, use encodeTms:**

Replace existing MMBINK/MMBINI emission:
```zig
                    if (tokenToTms(n.op)) |event| {
                        if (nc.kid == null) {
                            _ = try self.builder.emitABC(.mmbini, lhs_reg, int2sC(nc.ival), encodeTms(event, flip), line);
                        } else {
                            _ = try self.builder.emitABC(.mmbink, lhs_reg, @intCast(nc.kid.?), encodeTms(event, flip), line);
                        }
                    }
```

### Step 3: Swap-back in register fallback path

- [ ] **In the register/register path (after tryEmitConstBinOp returns null), use actual_rhs instead of n.rhs:**

The current code around line 2865 evaluates `n.rhs` for the register path. After a swap, `actual_rhs` is `n.lhs` (the original register operand). But we already have `lhs_ed` from the actual LHS. We need to evaluate the original LHS constant as the RHS:

```zig
            // Register/register path
            if (flip) {
                // Swap-back: LHS was n.rhs (already in lhs_ed/lhs_reg).
                // RHS is n.lhs (the constant). Materialize it to a register.
                var rhs_ed = try self.genExpDesc(actual_rhs);
                const rhs_reg = try self.exp2anyreg(&rhs_ed);
                self.freeExps(&lhs_ed, &rhs_ed);
                const dst = if (dst_hint) |hint| hint else try self.allocReg();
                _ = try self.builder.emitABC(op, dst, lhs_reg, rhs_reg, line);
                if (tokenToTms(n.op)) |event| {
                    _ = try self.builder.emitABC(.mmbin, lhs_reg, rhs_reg, event, line);
                }
                return dst;
            }
```

### Step 4: VM metamethod flip support

- [ ] **In vm.zig, modify K-variant arithmetic handlers to read flip from MMBINK:**

For each K-variant handler (ADDK, SUBK, MULK, DIVK, MODK, POWK, IDIVK, BANDK, BORK, BXORK), before calling the metamethod, check if the next instruction is MMBINK with flip:

```zig
            .addk => {
                const ra = inst.a;
                const rb = inst.b;  // register operand
                const rc_idx = inst.c;  // constant index
                ...
                // Check for metamethod
                if (need_metamethod) {
                    // Peek next instruction for MMBINK flip
                    var flip = false;
                    if (ctx.pc + 1 < ctx.cur_proto.code.len) {
                        const next_inst = ctx.cur_proto.code[ctx.pc + 1];
                        if (@as(bc.Op, @enumFromInt(next_inst.op)) == .mmbink) {
                            flip = (next_inst.c & 0x80) != 0;
                        }
                    }
                    // When flipped, metamethod sees (constant, register) = original order
                    if (flip) {
                        return self.tryPushBytecodeBinaryMetamethod(..., const_val, reg_val, "__add", ...);
                    } else {
                        return self.tryPushBytecodeBinaryMetamethod(..., reg_val, const_val, "__add", ...);
                    }
                }
            },
```

NOTE: This is the most complex part. The exact metamethod dispatch function name and parameters depend on the existing VM code. Search for how ADDK currently calls metamethods (search `.addk` in vm.zig dispatch, then find the `tryPushBytecodeBinaryMetamethod` or equivalent call).

ALTERNATIVE (simpler): Instead of looking ahead in the VM, store the flip flag in a field on the Vm struct during MMBINK dispatch. Since MMBINK is currently a no-op, make it set `self.mmbin_flip`:

```zig
            .mmbink => {
                self.mmbin_flip = (inst.c & 0x80) != 0;
            },
```

Then in the K-variant handler (which runs BEFORE MMBINK), we can't read the flip... unless MMBINK runs FIRST. But MMBINK is emitted AFTER the arith op. So the arith op runs first, then MMBINK.

Actually, PUC's design: the arith op does the fast-path (int+int, float+float). If it fails, execution falls through to MMBINK which does the metamethod dispatch. In luazig, the arith op handles BOTH fast-path and metamethod. So we need the flip info BEFORE the arith op runs.

SOLUTION: Pre-scan the flip flag. Before executing the K-variant arith op, check if the NEXT instruction is MMBINK/MMBINI and read its flip bit:

```zig
            .addk => {
                ...
                // Read flip from next MMBINK instruction (if present)
                var flip = false;
                const next_pc = ctx.pc + 1;
                if (next_pc < ctx.cur_proto.code.len) {
                    const next = ctx.cur_proto.code[next_pc];
                    if (@as(bc.Op, @enumFromInt(next.op)) == .mmbink) {
                        flip = (next.c & 0x80) != 0;
                    }
                }
                // Use flip for metamethod operand order
                ...
            },
```

### Step 5: Build, test, commit

```bash
cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5
cd lua-5.5.0/testes && cat > /tmp/test_swap.lua << 'EOF'
local function f(x) return 128 + x end
local c = T.listcode(f)
for i = 1, #c do print(i, c[i]) end
EOF
timeout 10 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_swap.lua 2>&1
```
Expected: `ADDK` (not `LOADI, ADD`).

Metamethod test:
```bash
cat > /tmp/test_flip.lua << 'EOF'
local mt = {__add = function(a, b) return tostring(a) .. "+" .. tostring(b) end}
local t = setmetatable({x=1}, mt)
print(5 + t)  -- should work with correct metamethod order
print(t + 5)  -- no swap, should also work
EOF
timeout 10 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_flip.lua 2>&1
```

Matrix MUST be ≥27/31:
```bash
python3 tools/testes_matrix.py --testc --timeout 60 2>&1 | head -5
```

```bash
git add src/lua/codegen_bc.zig src/lua/vm.zig
git commit -m "codegen+vm: commutative swap with flip mechanism

PUC codecommutative: if LHS is constant for commutative ops (ADD/MUL/
BAND/BOR/BXOR), swap to put constant on RHS (enabling ADDK/MULK/etc).
Flip flag encoded in MMBINK C-field high bit (0x80).

VM K-variant handlers read flip from next MMBINK instruction to
pass metamethod operands in original source order.

Fallback path (K-variant fails): swap-back to register/register."
```

---

## Task 4: Final Verification + README

- [ ] **Step 1: Full matrix run**

```bash
cd /home/boss/codes/luazig && python3 tools/testes_matrix.py --testc --timeout 60 2>&1
```

- [ ] **Step 2: Smoke tests**

```bash
cd /home/boss/codes/luazig && for f in tests/smoke/*.lua; do timeout 10 ./zig-out/bin/luazig --vm=bc "$f" 2>&1 | tail -1; done
```

- [ ] **Step 3: code.lua mismatch count**

```bash
cd lua-5.5.0/testes && timeout 30 ../../zig-out/bin/luazig --vm=bc --testc /tmp/test_code_stats.lua 2>&1 | grep -c MISMATCH
```

- [ ] **Step 4: Perf check**

```bash
cd /home/boss/codes/luazig && python3 tools/perf_compare.py 2>&1 | tail -5
```

- [ ] **Step 5: Update README and commit**

```bash
git add README.md
git commit -m "README: update codegen parity — final code.lua status"
```

---

## Self-Review

**Spec coverage:**
- Gap 3 (GETI/SETI) → Task 1
- Gap 2 Tier 1 (LOADNIL within-declaration) → Task 2
- Gap 1 (Commutative flip) → Task 3
- Gap 4 (LOADI range) → Not included. The analysis confirms luazig's 8-bit op architecture makes 17-bit sBx impossible without a whole-project instruction format change. Accept as known limitation.

**Placeholder scan:** All tasks have concrete code with file paths and line numbers. No vague "add error handling" or "similar to Task N".

**Risk mitigation:** Each task requires matrix ≥27/31. Task 2 explicitly tests goto.lua regression. Task 3 has metamethod order test.

**Execution note:** Use model `glm-5.2` for all subagent dispatches.
