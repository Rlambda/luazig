# Spec: Eliminate `@memset` via "before" live_reg_top semantics

**Date:** 2026-07-18
**Status:** Approved
**Goal:** Remove `@memset(regs, .Nil)` and `@memset(boxed, null)` from `pushBytecodeExecFrame` by making `live_reg_top[pc]` track the "before" boundary (registers actually written by previous instructions).

## Background

### Problem
`pushBytecodeExecFrame` zeroes the entire register window on every Lua function call:
```zig
@memset(regs, .Nil);   // maxstacksize * 16 bytes
@memset(boxed, null);  // maxstacksize * 8 bytes
```
PUC Lua does NOT do this — it only nil-fills missing parameters. This memset is O(maxstacksize) per call, the largest remaining per-call overhead.

### Root cause
`live_reg_top[pc]` records the **"after"** boundary — the high-water mark INCLUDING the current instruction's destination register. When GC fires at a safepoint BEFORE the instruction executes, it scans registers that haven't been written yet. Without `@memset`, those slots contain stale pointers from a previous frame → crash.

### Crash scenario
1. Frame A creates Table T in R5
2. Frame A returns. R5 still points to T
3. GC sweep between pop and re-push frees T (no live reference)
4. Frame B pushes at same base. Without memset, R5 = dangling T*
5. GC at safepoint scans R5 (via live_reg_top "after") → SIGSEGV

### PUC Lua comparison
PUC uses runtime `L->top` (not per-PC table), set explicitly at allocation points via `checkGC(L, c)`. PUC's `traversethread` scans `[stack .. L->top)`. Dead slots are cleared during atomic phase. PUC has NO memset on frame entry.

**Known deviation:** luazig uses per-instruction `gc_tick` (every N instructions) instead of PUC's allocation-only triggers. This is orthogonal to the memset fix but documented as technical debt.

## Design

### Part 1: Codegen — "before" semantics

**Files:** `src/lua/bytecode.zig`, `src/lua/codegen_bc.zig`

Add two fields to `ProtoBuilder`:
```zig
live_top_before: u8 = 0,
has_live_top_before: bool = false,
```

**`reserveRegs`** (codegen_bc.zig:252): Snapshot BEFORE bump:
```zig
fn reserveRegs(self: *Codegen, n: u8) Error!void {
    if (!self.builder.has_live_top_before) {
        self.builder.live_top_before = self.builder.current_live_top;
        self.builder.has_live_top_before = true;
    }
    // ... existing bump logic unchanged ...
    self.freereg = new_top;
    if (new_top > self.peak_freereg) self.peak_freereg = new_top;
    self.builder.current_live_top = self.peak_freereg;
    self.builder.checkStack(self.freereg);
}
```

**`syncLiveTop`** (codegen_bc.zig:318): Same guard:
```zig
fn syncLiveTop(self: *Codegen) void {
    if (!self.builder.has_live_top_before) {
        self.builder.live_top_before = self.builder.current_live_top;
        self.builder.has_live_top_before = true;
    }
    self.builder.current_live_top = self.peak_freereg;
}
```

**`emit`** (bytecode.zig:512): Record "before", reset flag:
```zig
pub fn emit(self: *ProtoBuilder, inst: Instruction, line: u32) !u32 {
    const result_pc: u32 = @intCast(self.code.items.len);
    try self.code.append(self.alloc, inst);
    try self.lineinfo.append(self.alloc, line);
    try self.live_reg_top.append(self.alloc, self.live_top_before);
    self.has_live_top_before = false;
    self.live_top_before = self.current_live_top;
    return result_pc;
}
```

**`resetRegs`** (codegen_bc.zig:305): Reset both:
```zig
fn resetRegs(self: *Codegen) void {
    self.freereg = self.nvarstack;
    self.peak_freereg = self.nvarstack;
    self.builder.current_live_top = self.nvarstack;
    self.builder.live_top_before = self.nvarstack;
    self.builder.has_live_top_before = false;
}
```

**Invariant:** `live_reg_top[pc]` = peak_freereg at the point of the FIRST register allocation for the instruction at pc. Multiple `reserveRegs` calls within one instruction do NOT overwrite the snapshot (flag prevents it).

### Part 2: Runtime — remove `@memset`

**File:** `src/lua/vm.zig`, function `pushBytecodeExecFrame`

Remove:
```zig
@memset(regs, .Nil);   // REMOVE
@memset(boxed, null);  // REMOVE
```

Keep (PUC-faithful nil-fill of missing params):
```zig
const ncopy = @min(nparams, args.len);
for (0..ncopy) |i| regs[i] = args[i];
for (ncopy..nparams) |i| regs[i] = .Nil;
```

### Part 3: Consumer sites — no changes needed

| Site | File:Line | Current code | Works with "before"? |
|------|-----------|-------------|---------------------|
| `gcMarkMutableRoots` | vm.zig:13421 | `live_reg_top[frame.pc]` | ✓ Scans only previously-written regs |
| `gcClearDeadFrameRegisters` | vm.zig:13636 | `live_reg_top[frame.pc]` | ✓ Clears stale/unwritten slots |
| `gcMarkThread` (parked) | vm.zig:14545 | `live_reg_top[fr.pc]` | ✓ |
| `debug.getlocal` | vm.zig:17172 | `live_reg_top[fr.pc]` | ✓ No phantom temp variables |
| `debug.setlocal` | vm.zig:17258 | `live_reg_top[fr.pc]` | ✓ |

With "before" semantics, `live_reg_top[pc]` is the boundary of registers written by PREVIOUS instructions. Everything above is either Nil (cleared by previous GC) or stale (but not scanned). `gcClearDeadFrameRegisters` clears `[live_reg_top[pc]..maxstacksize)` to maintain the invariant.

### Part 4: README documentation

Document two known deviations from PUC Lua:
1. **`gc_tick` vs allocation-only GC triggers** — luazig fires GC every N instructions (currently 20000), while PUC fires only at allocation points. This adds per-instruction overhead but ensures consistent GC pacing for compute-heavy workloads. Future task: switch to allocation-only triggers (like PUC's `luaC_checkGC`).
2. **Per-PC `live_reg_top` table vs runtime `L->top`** — luazig uses a compile-time per-PC boundary table because GC can fire at any instruction (gc_tick). PUC uses a runtime `L->top` maintained by the VM loop. Future task: if gc_tick is removed, `live_reg_top` can also be removed.

## Testing

1. **All 44 smoke tests** must pass
2. **testes_matrix.py** — 28/31 parity (no regressions)
3. **Microbench** — lua_calls should improve (less memset overhead per call)
4. **GC stress tests** — smoke tests 34-44 (GC-related) are critical

## Risk assessment

- **Medium risk:** Changes codegen output for ALL functions
- **Mitigation:** The logic is straightforward (snapshot flag), and the 5 consumer sites work correctly with "before" semantics without code changes
- **Bootstrap:** First GC in a new frame scans `[0..nparams)` — only parameters, which are written during frame setup. Stale slots are not scanned.
