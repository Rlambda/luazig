# testC Cleanup: Real LightUserdata + Sub-VM checkpanic

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace table-based `T.pushuserdata` emulation with real `LightUserdata`, then replace hardcoded `T.checkpanic` string-matching with a PUC-faithful sub-VM that runs testC scripts in isolation.

**Architecture:** Phase 1 migrates `T.pushuserdata` to return `.{ .LightUserdata = @ptrFromInt(n) }` (exactly as PUC `lua_pushlightuserdata` does), collapses the `isTestc*` detection trio to simple tag checks, and deletes ~200 lines of dead table-ud workaround code. Phase 2 creates a real second `Vm` instance for `T.checkpanic`, runs the test script on the sub-VM via `runTestcScript`, catches `RuntimeError` as the "panic" (no setjmp/longjmp needed — Zig error returns replace C longjmp), runs the optional panic script on the same sub-VM, then tears it down.

**Tech Stack:** Zig (master), PUC Lua 5.5.0 (`ltests.c:1267-1271` for pushuserdata, `ltests.c:1406-1432` for checkpanic, `ltm.h:63-68` for fasttm).

---

## Background: Why Two Phases?

### The Table-Based Userdata Workaround

`T.pushuserdata(n)` currently creates a Lua **table** with fields `{__testud=true, __ptr=n, __val=n, __light=true, __isnull=(n==0), __size=0}` and metatable `__name="__TESTUD"`. This table masquerades as light userdata throughout the VM. An entire detection apparatus — `isTestcUserdata`, `isTestcLightUserdata`, `isTestcNullPointer`, `makeTestcPointerValue`, `debugLightUserdataForId` — exists only to handle these tables.

Meanwhile, luazig already has a real `Value.LightUserdata: *anyopaque` variant, fully supported as table keys (compared by pointer identity, `ltable.zig:210`), with its own metatable (`light_userdata_metatable`). The table-based workaround is completely unnecessary.

### The checkpanic String-Matching Hack

`T.checkpanic` currently uses `string.find` to pattern-match the script text and returns hardcoded results for 3 of 8 test cases (`vm.zig:10906-10916`). This violates AGENTS.md's prohibition on matching by script/chunk content.

PUC's `checkpanic` (`ltests.c:1406-1432`) creates a real second `lua_State` via `lua_newstate`, sets a panic handler via `lua_atpanic` + `setjmp`, and runs the test script unprotected. luazig's `Vm.init()` already supports creating independent VM instances, and Zig's error-return mechanism replaces longjmp — `RuntimeError` caught by pcall is the "panic."

---

## File Structure

### Files to Modify

- **`src/lua/vm.zig`** — Primary file (~30.2k lines). All changes are here:
  - testC bootstrap Lua code (`enableTestcModuleInternal` ~line 10837)
  - testC command handlers (`execTestcCommand` ~line 26740)
  - `isTestc*` detection helpers (~line 28447)
  - `makeTestcPointerValue` (~line 28481)
  - `debugLightUserdataForId` (~line 17691)
  - `builtinTestcUdataval` (~line 26458)
  - `builtinDebugSetmetatable` / `Setuservalue` / `Getuservalue` (table-ud fallbacks)
  - `testcFinalizeRankObj` (~line 15352)
  - `builtinType` / `valueTypeName` (~line 11425, 24932)
  - testC `objsize` handler (~line 27201)
  - `isUserdataLike` / `checkTabArg` (~line 28416, 28429)
  - `Vm.deinit` (~line 2509 — fix gaps)
  - New: `builtinTestcCheckpanic` (~add near line 26053)

### Files to Create

None — all changes are in existing files.

---

## Part A: Real LightUserdata for T.pushuserdata

### Task A1: Add `testc_pushuserdata` builtin

**Files:**
- Modify: `src/lua/vm.zig` — `BuiltinId` enum (~line 179), `name()` function, `callBuiltin` dispatch, `enableTestcModuleInternal` (~line 10840)

  - [x] **Step 1: Add `testc_pushuserdata` to `BuiltinId` enum**

At `vm.zig:179` (the `BuiltinId` enum), add after `testc_udataval`:

```zig
    testc_pushuserdata,
```

  - [x] **Step 2: Add name string**

In the `name()` function for `BuiltinId` (search for `.testc_udataval =>`), add after it:

```zig
            .testc_pushuserdata => "T._pushuserdata",
```

  - [x] **Step 3: Add dispatch in `callBuiltin`**

Search for `.testc_udataval =>` in `callBuiltin`. Add after it:

```zig
            .testc_pushuserdata => try self.builtinTestcPushuserdata(args, outs),
```

  - [x] **Step 4: Implement `builtinTestcPushuserdata`**

Add near `builtinTestcUdataval` (~line 26458). This is the PUC `pushuserdata` (`ltests.c:1267-1271`): encode the integer directly as a light userdata pointer.

```zig
    /// PUC ltests pushuserdata (ltests.c:1267-1271): creates a light userdata
    /// whose pointer IS the integer value. Identity: pushuserdata(i) ==
    /// pushuserdata(i) because @ptrFromInt(i) is deterministic.
    fn builtinTestcPushuserdata(self: *Vm, args: []const Value, outs: []Value) DispatchError!void {
        if (args.len < 1) return self.fail("T._pushuserdata expects 1 arg", .{});
        const n: u64 = switch (args[0]) {
            .Int => |i| if (i < 0) 0 else @intCast(i),
            .Num => |n_val| if (n_val < 0) 0 else @intFromFloat(n_val),
            else => return self.fail("T._pushuserdata: number expected", .{}),
        };
        if (outs.len > 0) outs[0] = .{ .LightUserdata = @ptrFromInt(n) };
        self.last_builtin_out_count = @min(outs.len, 1);
    }
```

  - [x] **Step 5: Register in T table**

In `enableTestcModuleInternal` (~line 10840-10853), add after the `_udataval` registration:

```zig
        try self.setField(t, "_pushuserdata", .{ .Builtin = .testc_pushuserdata });
```

  - [x] **Step 6: Build**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: BUILD SUCCESS

  - [x] **Step 7: Commit**

```bash
git add src/lua/vm.zig
git commit -m "testC A1: add testc_pushuserdata builtin returning real LightUserdata"
```

---

### Task A2: Update bootstrap `T.pushuserdata` and `makeTestcPointerValue`

**Files:**
- Modify: `src/lua/vm.zig` — bootstrap Lua code (~line 10867), `makeTestcPointerValue` (~line 28481)

  - [x] **Step 1: Replace bootstrap `T.pushuserdata`**

In `enableTestcModuleInternal`, find the bootstrap Lua code for `T.pushuserdata` (~line 10867-10879). Replace the entire block (the `do ... end` with `ud_mt`, `cache`, `live`, `next_ptr`) with:

```lua
function T.pushuserdata(n)
    return T._pushuserdata(tonumber(n) or 0)
end
```

This removes: `ud_mt`, `cache`, `live`, `next_ptr`, and all fields (`__testud`, `__ptr`, `__size`, `__isnull`, `__val`, `__light`).

  - [x] **Step 2: Replace `makeTestcPointerValue`**

Find `makeTestcPointerValue` (~line 28481-28500). Replace the entire function body:

```zig
    /// Create a testC pointer value from a raw integer id. PUC encodes the
    /// integer directly as a light userdata pointer (ltests.c:1267-1271).
    /// We do the same: @ptrFromInt(id) is deterministic, so identity holds
    /// and table-key lookup works via pointer hashing (ltable.zig:295).
    fn makeTestcPointerValue(ptr_id: u64) Value {
        return .{ .LightUserdata = @ptrFromInt(ptr_id) };
    }
```

This removes the Lua `T.pushuserdata` callback call. The function no longer takes `self` or returns `DispatchError!Value` — it's a pure function returning `Value`.

  - [x] **Step 3: Update all `makeTestcPointerValue` call sites**

Search for `makeTestcPointerValue` in `vm.zig`. Each call site changes from `try self.makeTestcPointerValue(id)` to `makeTestcPointerValue(id)` (no `self`, no `try`). Sites:

1. `topointer` handler (~line 27332): `try self.makeTestcPointerValue(id)` → `makeTestcPointerValue(id)`
2. `topointer` for strings (~line 27338): same
3. `topointer` for table/closure/etc (~line 27340-27345): same
4. `topointer` default (~line 27347): same
5. `rawsetp` key (~line 27641): same
6. `rawgetp` key (~line 27653): same

  - [x] **Step 4: Build and fix errors**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -20`
Expected: BUILD SUCCESS (may have errors from call sites that need updating)

  - [x] **Step 5: Quick smoke test**

```bash
cat > /tmp/test_pushud.lua << 'EOF'
local a = T.pushuserdata(42)
local b = T.pushuserdata(42)
local c = T.pushuserdata(99)
assert(a == b, "same int must produce same light userdata")
assert(a ~= c, "different int must produce different light userdata")
assert(T.udataval(a) == 42, "udataval must recover the integer")
assert(T.udataval(c) == 99)
print("ALL PASS")
EOF
cd /home/boss/codes/luazig && timeout 5 zig-out/bin/luazig --testc /tmp/test_pushud.lua 2>&1
```

Expected: `ALL PASS`

NOTE: `udataval` won't work yet — needs A3. But `a == b` and `a ~= c` should pass.

  - [x] **Step 6: Commit**

```bash
git add src/lua/vm.zig
git commit -m "testC A2: T.pushuserdata returns real LightUserdata, makeTestcPointerValue simplified"
```

---

### Task A3: Add `.LightUserdata` branch to `builtinTestcUdataval`

**Files:**
- Modify: `src/lua/vm.zig` — `builtinTestcUdataval` (~line 26458)

  - [x] **Step 1: Add `.LightUserdata` case to `builtinTestcUdataval`**

In `builtinTestcUdataval` (~line 26458), the switch currently has `.Userdata` and `.Table` branches. Add a `.LightUserdata` branch that returns the pointer as an integer (PUC `lua_touserdata` returns `pvalue()` for light userdata, and `udataval` reinterprets it as integer):

```zig
        .LightUserdata => |p| {
            // PUC udataval (ltests.c:1274-1277) returns lua_touserdata, which
            // for light userdata is pvalue() — the raw pointer. We return it
            // as an integer so tests can recover the original n from
            // T.pushuserdata(n).
            if (outs.len > 0) outs[0] = .{ .Int = @intCast(@intFromPtr(p)) };
        },
```

  - [x] **Step 2: Build**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: BUILD SUCCESS

  - [x] **Step 3: Test udataval**

```bash
cd /home/boss/codes/luazig && timeout 5 zig-out/bin/luazig --testc /tmp/test_pushud.lua 2>&1
```

Expected: `ALL PASS` (now including `udataval` assertions)

  - [x] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "testC A3: udataval returns pointer as integer for LightUserdata"
```

---

### Task A4: Migrate `debugLightUserdataForId` to real LightUserdata

**Files:**
- Modify: `src/lua/vm.zig` — `debugLightUserdataForId` (~line 17691), `debug_upvalue_ids` field (~line 1818), GC mark (~line 14484), deinit (~line 2534)

  - [x] **Step 1: Replace `debugLightUserdataForId` implementation**

At `vm.zig:17691-17699`, replace the function body. Instead of creating a proxy table, return a real `.LightUserdata`:

```zig
    /// Return a unique light userdata value for `debug.upvalueid`.
    /// PUC uses lua_upvalueid which returns a raw pointer. We encode the
    /// id directly as a light userdata pointer — deterministic, no GC root
    /// needed (light userdata is not GC-managed).
    fn debugLightUserdataForId(self: *Vm, id: u64) DispatchError!Value {
        _ = self;
        return .{ .LightUserdata = @ptrFromInt(id) };
    }
```

  - [x] **Step 2: Remove `debug_upvalue_ids` field**

At `vm.zig:1818`, remove:
```zig
    debug_upvalue_ids: std.AutoHashMapUnmanaged(u64, *Table) = .{},
```

  - [x] **Step 3: Remove `debug_upvalue_ids` from GC mark**

At `vm.zig:14484-14488`, remove the `debug_upvalue_ids` iteration block:
```zig
        // debug_upvalue_ids: proxy tables for debug.upvalueid.
        var duit = self.debug_upvalue_ids.iterator();
        while (duit.next()) |entry| {
            try self.gcMarkValue(.{ .Table = entry.value_ptr.* });
        }
```

  - [x] **Step 4: Remove `debug_upvalue_ids` from `deinit`**

At `vm.zig:2534`, remove:
```zig
        self.debug_upvalue_ids.deinit(self.alloc);
```

  - [x] **Step 5: Build and fix errors**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -20`
Expected: BUILD SUCCESS

  - [x] **Step 6: Test debug.upvalueid**

```bash
cat > /tmp/test_upvid.lua << 'EOF'
local function outer()
    local x = 10
    local function inner() return x end
    return inner
end
local f = outer()
local id1 = debug.upvalueid(f, 1)
local id2 = debug.upvalueid(f, 1)
assert(id1 == id2, "same upvalue must have same id")
print("type:", type(id1))
print("tostring:", tostring(id1))
print("ALL PASS")
EOF
cd /home/boss/codes/luazig && timeout 5 zig-out/bin/luazig /tmp/test_upvid.lua 2>&1
```

Expected: `ALL PASS`

  - [x] **Step 7: Commit**

```bash
git add src/lua/vm.zig
git commit -m "testC A4: debug.upvalueid returns real LightUserdata, remove proxy tables"
```

---

### Task A5: Collapse `isTestc*` detection helpers

**Files:**
- Modify: `src/lua/vm.zig` — `isTestcUserdata` (~line 28447), `isTestcLightUserdata` (~line 28461), `isTestcNullPointer` (~line 28471)

  - [x] **Step 1: Replace `isTestcUserdata`**

At `vm.zig:28447-28459`, replace the function:

```zig
    fn isTestcUserdata(self: *Vm, v: Value) bool {
        _ = self;
        // After migration: real Userdata and LightUserdata are the only
        // "userdata" values. No more table-based detection.
        return v == .Userdata or v == .LightUserdata;
    }
```

  - [x] **Step 2: Replace `isTestcLightUserdata`**

At `vm.zig:28461-28469`, replace:

```zig
    fn isTestcLightUserdata(self: *Vm, v: Value) bool {
        _ = self;
        return v == .LightUserdata;
    }
```

  - [x] **Step 3: Replace `isTestcNullPointer`**

At `vm.zig:28471-28479`, replace:

```zig
    fn isTestcNullPointer(v: Value) bool {
        // Null light userdata: pointer value is 0.
        return v == .LightUserdata and @intFromPtr(v.LightUserdata) == 0;
    }
```

  - [x] **Step 4: Build**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: BUILD SUCCESS

  - [x] **Step 5: Commit**

```bash
git add src/lua/vm.zig
git commit -m "testC A5: collapse isTestc* helpers to simple tag checks"
```

---

### Task A6: Remove dead table-ud code

**Files:**
- Modify: `src/lua/vm.zig` — multiple sites (see steps)

  - [x] **Step 1: Remove `__val` rank logic from `testcFinalizeRankObj`**

At `vm.zig:15352-15370`, find `testcFinalizeRankObj`. The function ranks objects for finalization order. It has a branch reading `__val` from table-ud. Since pushuserdata now returns LightUserdata (not GC-managed, never finalized), this branch is dead. Remove the `isTestcUserdata` / `__val` branch, keeping only the real Userdata/GcObject cases.

Read the function and remove any branches referencing `isTestcUserdata`, `__val`, or `getFieldOpt(... "__val")`.

  - [x] **Step 2: Remove table-ud GC block from `builtinDebugSetmetatable`**

At `vm.zig:17878-17896` (the `isTestcUserdata && !isTestcLightUserdata` block with `__size`/`__gc_tracked`), remove the table-ud-specific tracking. Keep the `.Userdata` and `.Table` cases (real Userdata metatable setting, real Table metatable setting).

  - [x] **Step 3: Remove `__uservals` fallback from `builtinDebugSetuservalue`**

At `vm.zig:18354-18377`, the table-ud fallback with `__uservals`. Since pushuserdata no longer produces tables, this branch is dead. Remove it. Keep the `.Userdata` case and the `.LightUserdata` error case.

  - [x] **Step 4: Remove `__uservals` fallback from `builtinDebugGetuservalue`**

At `vm.zig:18400`, the table-ud fallback. Remove it. Keep `.Userdata` case and `.LightUserdata` case.

  - [x] **Step 5: Remove `__size` branch from testC `objsize`**

At `vm.zig:27208-27218`, the `isTestcUserdata` branch that reads `__size`. Remove it. Keep the `.Userdata` branch (reads `ud.payload.len`).

  - [x] **Step 6: Simplify `isUserdataLike` and `checkTabArg`**

At `vm.zig:28416-28419` (`isUserdataLike`): remove the `isTestcUserdata(self, v)` call. The function should only check `v == .Userdata or v == .LightUserdata or (file-table check)`.

At `vm.zig:28429` (`checkTabArg`): same simplification — remove `isTestcUserdata` reference.

  - [x] **Step 7: Remove `isTestcUserdata` branch from `builtinType` and `valueTypeName`**

At `vm.zig:11425` (`builtinType`): the `isTestcUserdata` branch returns `"userdata"` for table-ud. Since `.Userdata` and `.LightUserdata` are already handled by switch arms, remove the `isTestcUserdata` call.

At `vm.zig:24932` (`valueTypeName`): same removal.

  - [x] **Step 8: Build and fix compilation errors**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -20`
Expected: Possible errors from removed branches that had `self` parameter now unused, etc. Fix each.

  - [x] **Step 9: Run targeted tests**

```bash
cd /home/boss/codes/luazig && python3 tools/testes_matrix.py --testc --timeout 30 --no-ref 2>&1 | head -5
```

Expected: 26/31 (no regression — same 5 pre-existing failures: attrib, big, code, cstack, files)

```bash
cd /home/boss/codes/luazig && python3 tools/testes_matrix.py --timeout 30 2>&1 | head -3
```

Expected: 28/31 (no regression)

```bash
cd /home/boss/codes/luazig && for f in tests/smoke/*.lua; do timeout 5 zig-out/bin/luazig "$f" 2>&1 | tail -1; done | grep -c "."
```

Expected: 42 (baseline)

  - [x] **Step 10: Commit**

```bash
git add src/lua/vm.zig
git commit -m "testC A6: remove dead table-ud workaround code (~200 lines)"
```

---

### Task A7: Full regression and api.lua deep check

  - [ ] **Step 1: Run api.lua specifically (testC mode)**

```bash
cd /home/boss/codes/luazig && timeout 30 zig-out/bin/luazig --testc lua-5.5.0/testes/api.lua 2>&1 | tail -5
```

Expected: exit 0 (api.lua passes)

  - [ ] **Step 2: Run events.lua**

```bash
cd /home/boss/codes/luazig && timeout 30 zig-out/bin/luazig --testc lua-5.5.0/testes/events.lua 2>&1 | tail -3
```

Expected: exit 0

  - [ ] **Step 3: Run closure.lua (uses debug.upvalueid)**

```bash
cd /home/boss/codes/luazig && timeout 30 zig-out/bin/luazig lua-5.5.0/testes/closure.lua 2>&1 | tail -3
```

Expected: exit 0

  - [ ] **Step 4: Run goto.lua (uses debug.upvalueid)**

```bash
cd /home/boss/codes/luazig && timeout 30 zig-out/bin/luazig lua-5.5.0/testes/goto.lua 2>&1 | tail -3
```

Expected: exit 0

  - [ ] **Step 5: Run testc_lane**

```bash
cd /home/boss/codes/luazig && python3 tools/testc_lane.py --timeout 30 2>&1 | grep -c "ok"
```

Expected: 9

  - [ ] **Step 6: Update README**

Update the testC section in README.md to reflect:
- `T.pushuserdata` now returns real LightUserdata
- Table-ud workaround removed
- `debug.upvalueid` returns real LightUserdata

  - [ ] **Step 7: Commit**

```bash
git add README.md
git commit -m "testC A7: Phase 1 complete — real LightUserdata, full regression pass"
```

---

## Part B: Sub-VM checkpanic

### Task B1: Fix `Vm.deinit` gaps

**Files:**
- Modify: `src/lua/vm.zig` — `Vm.deinit` (~line 2509)

  - [ ] **Step 1: Add missing deinit calls**

In `Vm.deinit` (~line 2509), add before `self.drainGcRegistries()`:

```zig
        // Fix: long_string_cache and testc_warn_buff were not deinit'd,
        // causing leaks when sub-VMs are created/destroyed (checkpanic).
        self.long_string_cache.deinit(self.alloc);
        self.testc_warn_buff.deinit(self.alloc);
```

  - [ ] **Step 2: Build**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: BUILD SUCCESS

  - [ ] **Step 3: Verify no regression**

```bash
cd /home/boss/codes/luazig && python3 tools/testes_matrix.py --testc --timeout 30 --no-ref 2>&1 | head -3
```

Expected: 26/31 (no regression)

  - [ ] **Step 4: Commit**

```bash
git add src/lua/vm.zig
git commit -m "testC B1: fix Vm.deinit gaps (long_string_cache, testc_warn_buff)"
```

---

### Task B2: Implement `builtinTestcCheckpanic` with real sub-VM

**Files:**
- Modify: `src/lua/vm.zig` — new builtin `testc_checkpanic`, `BuiltinId` enum, dispatch, `enableTestcModuleInternal` bootstrap

  - [ ] **Step 1: Add `testc_checkpanic` to `BuiltinId` enum**

At `vm.zig:179` (the `BuiltinId` enum), add after `testc_pushuserdata`:

```zig
    testc_checkpanic,
```

  - [ ] **Step 2: Add name and dispatch**

In `name()`: `.testc_checkpanic => "T._checkpanic"`

In `callBuiltin`: `.testc_checkpanic => try self.builtinTestcCheckpanic(args, outs)`

  - [ ] **Step 3: Implement `builtinTestcCheckpanic`**

Add near the other testc builtins (~line 26458). This is the PUC-faithful implementation using a real sub-VM:

```zig
    /// PUC ltests checkpanic (ltests.c:1406-1432): create a fresh sub-VM,
    /// run the test script unprotected, catch the error as the "panic"
    /// message, optionally run the panic script on the sub-VM, then close it.
    /// No setjmp/longjmp — Zig error returns replace C longjmp.
    fn builtinTestcCheckpanic(
        self: *Vm,
        args: []const Value,
        outs: []Value,
    ) DispatchError!void {
        if (args.len < 1 or args[0] != .String)
            return self.fail("T._checkpanic expects script string", .{});
        const script = args[0].String.bytes();
        const panic_script: ?[]const u8 = if (args.len >= 2 and args[1] == .String)
            args[1].String.bytes()
        else
            null;

        // Create sub-VM sharing allocator with parent (PUC shares allocf).
        var sub_vm = Vm.init(self.alloc);
        defer sub_vm.deinit();

        // Enable testC module on sub-VM (registers T table + builtins).
        sub_vm.enableTestcModuleInternal() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.fail("checkpanic: sub-VM init failed", .{}),
        };

        // Set up testC stack: start with the script string on top
        // (matching how T.testC is normally called).
        var st: std.ArrayListUnmanaged(Value) = .empty;
        defer st.deinit(sub_vm.alloc);
        st.append(sub_vm.alloc, args[0]) catch return error.OutOfMemory;

        const ctx: TestcContext = .{};

        // Run main script unprotected. RuntimeError = "panic".
        // If the script errors, we capture sub_vm.errorString() as the panic
        // message. If panic_script is provided, we run it on the sub-VM
        // (optionally with the error message pushed onto the testC stack),
        // and return its result. Otherwise we return the error message.
        sub_vm.runTestcScript(script, &st, ctx) catch |err| switch (err) {
            error.RuntimeError => {
                const error_msg = sub_vm.errorString();
                if (panic_script) |ps| {
                    // Run panic script on sub-VM.
                    // Reset error state for clean execution.
                    sub_vm.err = null;
                    // Push error message onto testC stack for panic script
                    // to access (e.g. "concat" in panic scripts).
                    const err_str = sub_vm.internStr(error_msg) catch return error.OutOfMemory;
                    st.append(sub_vm.alloc, .{ .String = err_str }) catch return error.OutOfMemory;
                    const panic_result = sub_vm.runTestcScript(ps, &st, ctx) catch |pe| switch (pe) {
                        error.RuntimeError => {
                            // Panic script also errored — return its message.
                            if (outs.len > 0) {
                                const s = self.internStr(sub_vm.errorString()) catch return error.OutOfMemory;
                                outs[0] = .{ .String = s };
                            }
                            self.last_builtin_out_count = @min(outs.len, 1);
                            return;
                        },
                        else => return error.OutOfMemory,
                    };
                    // Panic script succeeded — extract return value from
                    // testC stack using return_spec.
                    const spec = panic_result.return_spec orelse testc.ReturnSpec{ .fixed = 0 };
                    const top_val: []const u8 = blk: {
                        if (st.items.len == 0) break :blk error_msg;
                        const top = st.items[st.items.len - 1];
                        if (top == .String) break :blk top.String.bytes();
                        break :blk error_msg;
                    };
                    if (outs.len > 0) {
                        const s = self.internStr(top_val) catch return error.OutOfMemory;
                        outs[0] = .{ .String = s };
                    }
                    self.last_builtin_out_count = @min(outs.len, 1);
                    return;
                }
                // No panic script — return error message directly.
                if (outs.len > 0) {
                    const s = self.internStr(error_msg) catch return error.OutOfMemory;
                    outs[0] = .{ .String = s };
                }
                self.last_builtin_out_count = @min(outs.len, 1);
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.Yield => return self.fail("checkpanic: unexpected yield", .{}),
            error.ThreadSwitch => return self.fail("checkpanic: unexpected thread switch", .{}),
        };

        // No error occurred — return "no errors" (PUC behavior).
        if (outs.len > 0) {
            const s = self.internStr("no errors") catch return error.OutOfMemory;
            outs[0] = .{ .String = s };
        }
        self.last_builtin_out_count = @min(outs.len, 1);
    }
```

NOTE: The exact behavior of `threadstatus` on the sub-VM after RuntimeError (test case 2) may need adjustment — check what `threadstatus` returns after an error on the sub-VM's main thread. The testC `threadstatus` command reads `coroutine.status(th)` which should return `"running"` or a similar status string depending on error recovery state. The panic script for test case 2 does `threadstatus; return 2` — it expects the status to be `ERRRUN` (PUC thread status after unprotected error). Verify the sub-VM's thread status after RuntimeError and adjust if needed.

  - [ ] **Step 4: Replace bootstrap `T.checkpanic`**

In `enableTestcModuleInternal` bootstrap Lua code, replace the entire `T.checkpanic` function (~line 10905-10931) with:

```lua
function T.checkpanic(script, panic_script)
    if panic_script then
        return T._checkpanic(script, panic_script)
    end
    return T._checkpanic(script)
end
```

  - [ ] **Step 5: Build**

Run: `cd /home/boss/codes/luazig && zig build -Doptimize=ReleaseFast 2>&1 | tail -20`
Expected: Possible compilation errors from the sub-VM approach. Fix as needed — the key challenge is that `runTestcScript` is private to `Vm`, but since `builtinTestcCheckpanic` is defined in the same file, Zig allows calling private methods on other instances of the same type.

  - [ ] **Step 6: Test individual checkpanic cases**

```bash
cat > /tmp/test_checkpanic.lua << 'EOF'
-- Test 1: trivial error
local r1 = T.checkpanic("pushstring hi; error")
print("test1:", r1)
assert(r1 == "hi", "expected 'hi', got '" .. tostring(r1) .. "'")

-- Test 4: argerror without frames
local r4 = T.checkpanic("loadstring 4 name bt")
print("test4:", r4)

print("PARTIAL PASS")
EOF
cd /home/boss/codes/luazig && timeout 10 zig-out/bin/luazig --testc /tmp/test_checkpanic.lua 2>&1
```

Expected: `PARTIAL PASS` (or partial — some tests may need refinement)

  - [ ] **Step 7: Commit**

```bash
git add src/lua/vm.zig
git commit -m "testC B2: implement checkpanic with real sub-VM (replaces string matching)"
```

---

### Task B3: Run all 8 checkpanic test cases

  - [ ] **Step 1: Run api.lua checkpanic section**

```bash
cd /home/boss/codes/luazig && timeout 30 zig-out/bin/luazig --testc lua-5.5.0/testes/api.lua 2>&1 | grep -A5 "panic"
```

Expected: All 7 checkpanic assertions pass.

  - [ ] **Step 2: Run memerr.lua checkpanic**

```bash
cd /home/boss/codes/luazig && timeout 30 zig-out/bin/luazig --testc lua-5.5.0/testes/memerr.lua 2>&1 | tail -5
```

Expected: memerr.lua passes (1 checkpanic call).

  - [ ] **Step 3: Debug failing cases**

If any of the 8 checkpanic cases fail, investigate:

| Case | Script | Expected | Likely issue |
|---|---|---|---|
| 1 | `pushstring hi; error` | `"hi"` | Error message format |
| 2 | + `threadstatus; return 2` | `"ERRRUN"` | Thread status after error |
| 3 | + concat panic script | `"hi alo mundo"` | Stack state after error |
| 4 | `loadstring 4 name bt` | `"bad argument #4..."` | Error message format |
| 5 | `alloccount 0; newtable` + panic | `"XXnot enough memory"` | OOM on sub-VM |
| 6 | stack overflow | contains `"stack overflow"` | Stack overflow detection |
| 7 | `__close` + error | `"hiho"` | TBC + error interaction |

For each failing case:
1. Check what `sub_vm.errorString()` returns
2. Check if the panic script can access the error message
3. Fix the control flow in `builtinTestcCheckpanic`

  - [ ] **Step 4: Commit fixes**

```bash
git add src/lua/vm.zig
git commit -m "testC B3: fix checkpanic cases for all 8 test scenarios"
```

---

### Task B4: Full regression testing

  - [ ] **Step 1: Run testC matrix**

```bash
cd /home/boss/codes/luazig && python3 tools/testes_matrix.py --testc --timeout 30 --no-ref 2>&1 | head -5
```

Expected: 26/31 or better (no regressions from Phase A baseline)

  - [ ] **Step 2: Run normal matrix**

```bash
cd /home/boss/codes/luazig && python3 tools/testes_matrix.py --timeout 30 2>&1 | head -3
```

Expected: 28/31 (no regression)

  - [ ] **Step 3: Run smoke tests**

```bash
cd /home/boss/codes/luazig && for f in tests/smoke/*.lua; do timeout 5 zig-out/bin/luazig "$f" 2>&1 | tail -1; done | grep -c "."
```

Expected: 42 (baseline)

  - [ ] **Step 4: Run testc_lane**

```bash
cd /home/boss/codes/luazig && python3 tools/testc_lane.py --timeout 30 2>&1 | grep -c "ok"
```

Expected: 9

  - [ ] **Step 5: Update README**

Add a section documenting:
- `T.checkpanic` now uses real sub-VM (no string matching)
- `T.pushuserdata` returns real LightUserdata
- All table-ud workarounds removed
- Remaining testC stubs (checkmemory, newstate, etc.)

  - [ ] **Step 6: Commit**

```bash
git add README.md src/lua/vm.zig
git commit -m "testC B4: Phase 2 complete — checkpanic via sub-VM, full regression pass"
```

---

## Risk Assessment

| Risk | Mitigation |
|---|---|
| LightUserdata `@ptrFromInt(0)` — null pointer | Zig allows this for `*anyopaque`; GC doesn't trace LightUserdata; pointer 0 is a valid sentinel |
| `debug.upvalueid` returns different type after migration | api.lua doesn't use upvalueid; closure.lua/goto.lua use it for identity comparison which works with LightUserdata |
| Sub-VM `runTestcScript` errors before error state is set | Check `sub_vm.err` is set after RuntimeError; if not, capture from the error return |
| Sub-VM stack overflow test (case 6) may not trigger | Sub-VM has its own stack; overflow detection should work the same as parent |
| Sub-VM `alloccount` uses T._alloccount (Lua global) | Sub-VM has its own T table (set up by `enableTestcModuleInternal`); alloccount is per-VM |
| Sub-VM cleanup (deinit) may miss resources | B1 fixes known gaps; drainGcRegistries frees all GC objects; monitor for leaks |

## Expected Final State

| Metric | Before | After |
|---|---|---|
| testC matrix | 26/31 | 26/31 (no regression) |
| Normal matrix | 28/31 | 28/31 (no regression) |
| Smoke | 42 | 42 |
| testc_lane | 9/9 | 9/9 |
| Table-ud workaround code | ~200 lines | 0 (deleted) |
| `T.checkpanic` string matching | 3 hardcoded cases | 0 (real sub-VM) |
| `isTestcUserdata` detection | 13-line dual-path | 1-line tag check |
| AGENTS.md violations | 1 (checkpanic string matching) | 0 |

---

## Remaining testC Stubs (NOT in this plan)

These are lower-priority stubs that remain after this plan:

| Stub | PUC behavior | Effort |
|---|---|---|
| `T.checkmemory` | Walks GC lists, asserts invariants | Medium — needs GC list iteration |
| `T.newstate`/`T.closestate` | Creates real second lua_State | Medium — same sub-VM infrastructure as checkpanic |
| `T.querystr` | Returns string table stats | Low — return real interning stats |
| `T.allocfailnext` | Sets allocation fail flag | Low — wire to testc_mem_limit |
| makeCfunc (table-based) | Real pushcclosure/CClosure | Large — needs Closure redesign |
