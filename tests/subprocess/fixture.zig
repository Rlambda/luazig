const std = @import("std");

const Panic = struct {
    // P16.50-review-3 R5 subprocess: atpanic hook on an unprotected OOM throw.
    // Scenario comes from argv[2] ("A" or "B"); all diagnostics go to stderr.
    const lua = @import("lua");

    /// One-shot failing allocator: the FIRST allocation after `armed` is set
    /// fails exactly once, everything else (before and after) passes through.
    const OneShot = struct {
        inner: std.mem.Allocator,
        armed: bool = false,
        failed: bool = false,

        fn allocator(self: *OneShot) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = allocFn,
                    .resize = resizeFn,
                    .remap = remapFn,
                    .free = freeFn,
                },
            };
        }

        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *OneShot = @ptrCast(@alignCast(ctx));
            if (self.armed and !self.failed) {
                self.failed = true;
                return null;
            }
            return self.inner.rawAlloc(len, alignment, ret_addr);
        }

        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *OneShot = @ptrCast(@alignCast(ctx));
            return self.inner.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *OneShot = @ptrCast(@alignCast(ctx));
            return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *OneShot = @ptrCast(@alignCast(ctx));
            self.inner.rawFree(memory, alignment, ret_addr);
        }
    };

    fn dummyCfunc(L: ?*lua.c_api.lua_State) callconv(.c) c_int {
        _ = L;
        return 0;
    }

    fn panicHook(L: ?*lua.c_api.lua_State) callconv(.c) c_int {
        var len: usize = 0;
        const msg = lua.c_api.lua_tolstring(L, -1, &len);
        std.debug.print("PANIC-SEEN L={x} msg={s}\n", .{ @intFromPtr(L), if (msg) |m| m[0..len] else "(null)" });
        return 0;
    }

    pub fn run(scenario: []const u8) u8 {
        // argv[0] = program name, argv[2] = scenario ("A" default).

        var one_shot = OneShot{ .inner = std.heap.c_allocator };
        var state = lua.api.State.init(.{ .allocator = one_shot.allocator() });
        defer state.deinit();
        const vm = state.vm;
        const L = vm.main_handle.?;
        const c = lua.c_api;

        _ = c.lua_atpanic(L, panicHook);

        if (std.mem.eql(u8, scenario, "B")) {
            // Non-current coroutine handle: L2 exists, cur_handle stays main L.
            const L2 = c.lua_newthread(L);
            std.debug.print("EXPECT-L2 {x}\n", .{@intFromPtr(L2)});
            _ = c.lua_pushinteger(L2, 7);
            one_shot.armed = true;
            c.lua_pushcclosure(L2, dummyCfunc, 1);
        } else {
            std.debug.print("MAIN-L {x}\n", .{@intFromPtr(L)});
            _ = c.lua_pushinteger(L, 7);
            one_shot.armed = true;
            c.lua_pushcclosure(L, dummyCfunc, 1);
        }
        // Unreachable on both paths: the OOM either longjmps to a boundary
        // (none is active) or runs the panic hook and aborts.
        std.debug.print("NO-PANIC (unexpected)\n", .{});
        return 0;
    }
};

const RootScope = struct {
    // A1.0c §4 subprocess: leaked RootScope through the production
    // C-API boundary path. Scenario from argv[2]: "leak" (default) or
    // "control". All diagnostics go to stderr.
    const lua = @import("lua");

    fn leakCf(L: ?*lua.c_api.lua_State) callconv(.c) c_int {
        const vm = L.?.vm;
        var scope = vm.openRootScope(1, 1) catch return 0;
        lua.c_api.lua_createtable(L, 0, 0);
        // The created table lands on the thread's WINDOW.
        const th = L.?.thread.?;
        const t = th.stack[th.top - 1].Table;
        const cell = vm.alloc.create(lua.internal.vm.Cell) catch {
            scope.close();
            return 0;
        };
        cell.* = .{ .value = .Nil };
        vm.gcRegisterCell(cell);
        _ = scope.protectValueAssumeCapacity(.{ .Table = t });
        _ = scope.protectCellAssumeCapacity(cell);
        _ = lua.c_api.lua_pushinteger(L, 7);
        return 1; // LEAK: the scope is never closed — finish() must catch it
    }

    fn controlCf(L: ?*lua.c_api.lua_State) callconv(.c) c_int {
        const vm = L.?.vm;
        var scope = vm.openRootScope(1, 1) catch return 0;
        lua.c_api.lua_createtable(L, 0, 0);
        // Window read (see leakCf).
        const th = L.?.thread.?;
        const t = th.stack[th.top - 1].Table;
        const cell = vm.alloc.create(lua.internal.vm.Cell) catch {
            scope.close();
            return 0;
        };
        cell.* = .{ .value = .Nil };
        vm.gcRegisterCell(cell);
        _ = scope.protectValueAssumeCapacity(.{ .Table = t });
        _ = scope.protectCellAssumeCapacity(cell);
        scope.close(); // well-behaved: the checkpoint must pass
        _ = lua.c_api.lua_pushinteger(L, 5);
        return 1;
    }

    pub fn run(scenario: []const u8) u8 {
        const leak = std.mem.eql(u8, scenario, "leak");

        var state = lua.api.State.init(.{ .allocator = std.heap.c_allocator });
        defer state.deinit();
        const vm = state.vm;
        const L = vm.main_handle.?;

        const roots_v0 = vm.gc_root_values.items.len;
        const roots_c0 = vm.gc_root_cells.items.len;
        const depth0 = vm.gc_root_depth;

        // Drive the callback through the REAL production C-API boundary
        // path: lua_pushcfunction + lua_pcallk → apiCall → runClosure →
        // callCFunction → callCFunctionWithBoundary (the finish()
        // checkpoint at the normal C return).
        lua.c_api.lua_pushcfunction(L, if (leak) leakCf else controlCf);
        std.debug.print("A10C-CHILD-ARMED {s}\n", .{scenario});
        const st = lua.c_api.lua_pcallk(L, 0, 1, 0, 0, null);
        if (st != 0) {
            std.debug.print("A10C-CHILD-PCALL-FAIL {d}\n", .{st});
            return 3;
        }
        // Reached only when finish() accepted the return: in Debug the
        // leak scenario aborts AT the checkpoint, so this "survived"
        // marker's absence narrows the abort to the assert; in
        // ReleaseFast the defensive restore must have brought the root
        // state back exactly (restored=1).
        const restored = vm.gc_root_values.items.len == roots_v0 and
            vm.gc_root_cells.items.len == roots_c0 and
            vm.gc_root_depth == depth0;
        std.debug.print("A10C-CHILD-AFTER restored={d}\n", .{@intFromBool(restored)});
        if (!restored) return 4;
        // The pcall result is the main thread's WINDOW top.
        const mth = L.thread.?;
        const n = mth.stack[mth.top - 1].Int;
        std.debug.print("A10C-CHILD-OK n={d}\n", .{n});
        return 0;
    }
};

const Poison = struct {
    // A1.1s1 oracle 2 child: poison-trap fault proof. Scenario from
    // argv[2]: "fault" (default) or "control". Diagnostics to stderr.
    const lua = @import("lua");

    pub fn run(scenario: []const u8) u8 {
        var state = lua.api.State.init(.{ .allocator = std.heap.c_allocator });
        defer state.deinit();
        const vm = state.vm;

        // Arm the oracle: every charged block from here on lives in a
        // private mapping; its free traps the region (PROT_NONE).
        vm.testcArmPoisonUnmap();
        const block = vm.alloc.alloc(u8, 64) catch {
            std.debug.print("A11S1-OR2-ALLOC-FAIL\n", .{});
            return 3;
        };

        if (std.mem.eql(u8, scenario, "control")) {
            // Live read (mapped, rw): must succeed; the free then traps
            // and the deferred teardown releases the region cleanly.
            const v = block[0];
            std.debug.print("A11S1-OR2-CONTROL-OK {d}\n", .{v});
            vm.alloc.free(block);
            return 0;
        }

        // Fault arm: free traps the region, then the read must SIGSEGV.
        vm.alloc.free(block);
        std.debug.print("A11S1-OR2-ARMED\n", .{});
        const v = block[0]; // freed-header read: deterministic fault
        std.debug.print("A11S1-OR2-NO-FAULT {d}\n", .{v});
        return 0;
    }
};

const EmergencyGc = struct {
    // A1.1s1 class-10 child: emergency-GC stale register mark reads a
    // freed object header. Scenario from argv[2]: "poison" (default),
    // "nopoison", or "nosweep". Diagnostics to stderr.
    const lua = @import("lua");

    fn armfailCf(L: ?*lua.c_api.lua_State) callconv(.c) c_int {
        // Arm the countdown INSIDE the chunk: arming before loadbuffer
        // would fail the compile allocations. 0 = fail while armed.
        L.?.vm.testcArmAllocCount(0);
        std.debug.print("A11S1-C10-ARMED\n", .{});
        return 0;
    }

    pub fn run(scenario: []const u8) u8 {
        var state = lua.api.State.init(.{ .allocator = std.heap.c_allocator });
        // NOT `defer state.deinit()`: under poison, State.deinit ->
        // vm.deinit -> releasePoisonedRegions munmaps ALL poisoned
        // regions including still-live charged ones (the main handle
        // c_stack), and the later freeStateHandle frees that c_stack
        // through the restored base allocator into the trapped region —
        // a teardown fault indistinguishable from the in-chunk emergency
        // fault this child exists to prove. Non-poison scenarios deinit
        // normally below; the process exit reclaims the rest.
        const vm = state.vm;
        vm.setDynamicBytecodeCompiler(lua.internal.vm.defaultBytecodeCompiler);

        if (std.mem.eql(u8, scenario, "poison")) vm.testcArmPoisonUnmap();

        // Register armfail as a Lua global (the production C-API path).
        const L = vm.main_handle.?;
        lua.c_api.lua_pushcfunction(L, armfailCf);
        lua.c_api.lua_setglobal(L, "armfail");

        // Block-scoped locals die inside the frame register window (the
        // compiler does not nil them): after the `end`, slots 0-3 still
        // hold the four table pointers as DEAD slots. Wholesale marking
        // keeps them marked — the collectgarbage() cycle
        // RETAINS them (one-cycle dead-slot retention, PUC's own
        // below-top conservatism shape), so the emergency scan below
        // reads live registered pointers whether or not the sweep ran.
        // armfail() arms fail-all; `local q = {}` reuses slot 0 but
        // OP_NEWTABLE's allocation fails BEFORE the store, so the
        // emergency GC scan (full frame window) reads slots 0-3.
        const sweep = !std.mem.eql(u8, scenario, "nosweep");
        const chunk = if (sweep)
            "do local a, b, c, d = {}, {}, {}, {} end collectgarbage() armfail() local q = {} return q"
        else
            "do local a, b, c, d = {}, {}, {}, {} end armfail() local q = {} return q";

        const lst = state.loadbuffer(chunk, "=a11s1c10");
        if (lst != .ok) {
            std.debug.print("A11S1-C10-LOAD-FAIL {d}\n", .{@intFromEnum(lst)});
            return 3;
        }
        const pst = state.pcall(0, 0) catch |perr| {
            std.debug.print("A11S1-C10-PCALL-ERR {s}\n", .{@errorName(perr)});
            return 5;
        };
        std.debug.print("A11S1-C10-DONE status={d}\n", .{@intFromEnum(pst)});
        if (!std.mem.eql(u8, scenario, "poison")) state.deinit();
        return 0;
    }
};

const StaleRoot = struct {
    // A1.1s1 class-14 child: stale ValueRoot/CellRoot read/replace
    // probe. Scenario from argv[2]: vr-read | vr-replace | cr-read |
    // cr-replace. Contract (A1.1 brief class 14, M25-fixed): every
    // stale handle op deterministically PANICS in Debug AND
    // ReleaseFast — no silent .Nil, no silent no-op. Markers to
    // stderr only on the (forbidden) survival path.
    const lua = @import("lua");

    pub fn run(scenario: []const u8) u8 {
        var state = lua.api.State.init(.{ .allocator = std.heap.c_allocator });
        defer state.deinit();
        const vm = state.vm;

        // A raw closed cell. The probe never collects and CellRoot only
        // stores/returns the pointer, so an unregistered cell suffices.
        const cell = std.heap.c_allocator.create(lua.internal.vm.Cell) catch return 1;
        cell.* = .{
            .value = .Nil,
            .stack_idx = lua.internal.vm.Cell.stack_closed,
            .stack_thread = null,
        };
        defer std.heap.c_allocator.destroy(cell);

        var scope = vm.openRootScope(1, 1) catch return 1;
        const vroot = scope.protectValueAssumeCapacity(.{ .Int = 42 });
        const croot = scope.protectCellAssumeCapacity(cell);
        scope.close(); // both handles are stale now

        if (std.mem.eql(u8, scenario, "vr-read")) {
            const v = vroot.read();
            // Unreachable on the contract: read panics before returning.
            std.debug.print("A11S1-C14 VR-READ-SURVIVED {any}\n", .{v});
        } else if (std.mem.eql(u8, scenario, "vr-replace")) {
            vroot.replace(.{ .Int = 7 });
            // Unreachable on the contract: replace panics.
            std.debug.print("A11S1-C14 VR-REPLACE-SURVIVED\n", .{});
        } else if (std.mem.eql(u8, scenario, "cr-read")) {
            const c = croot.read();
            // Unreachable on the contract: read panics.
            std.debug.print("A11S1-C14 CR-READ-SURVIVED {any}\n", .{c});
        } else {
            croot.replace(cell);
            // Unreachable on the contract: replace panics.
            std.debug.print("A11S1-C14 CR-REPLACE-SURVIVED\n", .{});
        }
        return 0;
    }
};

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.vector;
    if (argv.len != 3) return 2;
    const kind = std.mem.span(argv[1]);
    const scenario = std.mem.span(argv[2]);
    if (std.mem.eql(u8, kind, "panic")) return Panic.run(scenario);
    if (std.mem.eql(u8, kind, "root-scope")) return RootScope.run(scenario);
    if (std.mem.eql(u8, kind, "poison")) return Poison.run(scenario);
    if (std.mem.eql(u8, kind, "emergency-gc")) return EmergencyGc.run(scenario);
    if (std.mem.eql(u8, kind, "stale-root")) return StaleRoot.run(scenario);
    return 2;
}
