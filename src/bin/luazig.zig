const std = @import("std");
const lua = @import("lua");
const stdio = @import("util").stdio;
const tracking_alloc = lua.internal.tracking_alloc;

fn usage(out: anytype) !void {
    try out.writeAll(
        \\luazig
        \\usage: luazig [lua options] [script [args]]
        \\
        \\Zig engine options (subset):
        \\  -e chunk      execute string 'chunk'
        \\  --vm=ir|bc    select VM backend (default: bc)
        \\  --dump-bytecode  print bytecode disassembly (like luac -l) and exit
        \\  --bc-coverage-out <file.json>   write BC lowering/fallback coverage stats
        \\  --testc       enable test-only module `T` (ltests compatibility path)
        \\
        \\Compatibility:
        \\  --engine=zig  accepted (no-op)
        \\  --engine=ref  removed; run build/lua-c/lua directly for reference behavior
        \\
    );
}

const VmBackend = enum { bc };

const BcCoverageStats = struct {
    total_functions: usize = 0,
    lowered_functions: usize = 0,
    fallback_functions: usize = 0,
    total_insts: usize = 0,
    lowered_insts: usize = 0,
    fallback_insts: usize = 0,
};

fn parseVmBackend(s: []const u8) ?VmBackend {
    if (std.mem.eql(u8, s, "bc")) return .bc;
    if (std.mem.eql(u8, s, "ir")) return .bc; // IR executor removed; redirect to bc
    return null;
}

fn parseEngineCompat(s: []const u8) enum { zig, ref, invalid } {
    if (std.mem.eql(u8, s, "zig")) return .zig;
    if (std.mem.eql(u8, s, "ref")) return .ref;
    return .invalid;
}

fn compileDynamicBytecode(
    alloc: std.mem.Allocator,
    source: lua.internal.Source,
    chunk: *const lua.internal.ast.Chunk,
) std.mem.Allocator.Error!lua.internal.vm.DynamicBytecodeCompileResult {
    var codegen = lua.internal.codegen_bc.Codegen.init(alloc, source.name, source.bytes);
    defer codegen.deinit();
    const proto = codegen.compileChunk(chunk) catch {
        if (codegen.diag) |diag| {
            return .{ .diagnostic = try std.fmt.allocPrint(alloc, ":{d}: {s}", .{ diag.line, diag.msg }) };
        }
        return .{ .diagnostic = try alloc.dupe(u8, codegen.diagString()) };
    };
    return .{ .proto = proto };
}

fn runZigSource(aalloc: std.mem.Allocator, vm: *lua.internal.vm.Vm, source: lua.internal.Source, backend: VmBackend, bc_stats: ?*BcCoverageStats, dump_bytecode: bool, progname: []const u8) !void {
    return runZigSourceArgs(aalloc, vm, source, backend, bc_stats, dump_bytecode, &.{}, progname);
}

/// PUC `l_message` (lua.c:111-114): print `progname: msg\n` to stderr.
/// If `progname` is null, no prefix is printed (matching PUC's `l_message`
/// which skips the `"%s: "` when `pname` is NULL).
fn lMessage(progname: ?[]const u8, msg: []const u8) void {
    var errw = stdio.stderr();
    if (progname) |pname| {
        errw.print("{s}: {s}\n", .{ pname, msg }) catch {};
    } else {
        errw.print("{s}\n", .{msg}) catch {};
    }
}

/// PUC `report` (lua.c:121-130): on error, print the error message via
/// `l_message(progname, msg)`. With the `errfunc` mechanism, the error
/// object is already formatted (string/__tostring/traceback) by
/// `builtinCliMsghandler` BEFORE call stack unwinding. So we just print
/// the error string directly.
fn reportError(aalloc: std.mem.Allocator, vm: *lua.internal.vm.Vm, progname: ?[]const u8) void {
    _ = aalloc;
    // PUC l_message(progname, msg): print "progname: msg" to stderr.
    // The errfunc (cli_msghandler) has already formatted the error with
    // source location + traceback. The formatted message is in err/err_obj.
    lMessage(progname, vm.errorString());
}

/// Like `runZigSource` but passes `script_args` as vararg arguments to the
/// chunk, matching PUC `handle_script` → `pushargs` (lua.c:245-269).
fn runZigSourceArgs(aalloc: std.mem.Allocator, vm: *lua.internal.vm.Vm, source: lua.internal.Source, backend: VmBackend, bc_stats: ?*BcCoverageStats, dump_bytecode: bool, script_args: []const lua.internal.vm.Value, progname: []const u8) !void {
    _ = bc_stats;

    // PUC luaL_loadfilex (lauxlib.c:808-848): detect binary chunks by
    // checking for LUA_SIGNATURE[0] (0x1b) after BOM/shebang stripping.
    // If found, route to undump instead of the source parser.
    const bytes = source.bytes;
    var bin_start: usize = 0;
    // Skip BOM (0xEF 0xBB 0xBF)
    if (bytes.len >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF) bin_start = 3;
    // Skip shebang (# ... \n)
    if (bin_start < bytes.len and bytes[bin_start] == '#') {
        while (bin_start < bytes.len and bytes[bin_start] != '\n') bin_start += 1;
        if (bin_start < bytes.len) bin_start += 1; // skip \n
    }
    if (bin_start < bytes.len and bytes[bin_start] == 0x1b) {
        // Binary chunk — use undump path.
        const undump_mod = lua.internal.undump;
        var reader = undump_mod.UndumpReader.init(aalloc, bytes[bin_start..]);
        reader.internFn = lua.internal.vm.Vm.undumpInternCallback;
        reader.internCtx = @ptrCast(vm);
        defer reader.deinit();
        const loaded_proto = reader.undumpChunk() catch |err| {
            const msg: []const u8 = switch (err) {
                error.TruncatedChunk => "truncated precompiled chunk",
                error.BadHeader => "bad binary format (corrupted header)",
                error.BadConstant => "bad binary format (corrupted constant)",
                error.OutOfMemory => return error.OutOfMemory,
            };
            lMessage(progname, msg);
            return error.RuntimeError;
        };
        // Pre-resolve constants (strings already interned via callback).
        vm.preResolveUndumpedConstants(loaded_proto) catch return error.OutOfMemory;
        // Execute directly with _ENV = global_env.
        const env_cell = aalloc.create(lua.internal.vm.Cell) catch return error.OutOfMemory;
        env_cell.* = .{ .value = .{ .Table = vm.global_env } };
        const upvals = [_]*lua.internal.vm.Cell{env_cell};
        const saved_errfunc = vm.errfunc;
        vm.errfunc = .{ .Builtin = .cli_msghandler };
        defer vm.errfunc = saved_errfunc;
        // PUC docall (lua.c:161): setsignal(SIGINT, laction) — install
        // SIGINT handler so pcall can catch interrupts.
        lua.internal.vm.installSigintHandler();
        defer lua.internal.vm.restoreSigintHandler();
        const ret = vm.runBytecode(loaded_proto, &upvals, script_args, null) catch {
            reportError(aalloc, vm, progname);
            return error.RuntimeError;
        };
        aalloc.free(ret);
        return;
    }

    // Source chunk — use parser.
    var lex = lua.internal.Lexer.init(source);
    var p = lua.internal.Parser.init(&lex) catch {
        lMessage(progname, lex.diagString());
        return error.SyntaxError;
    };

    var ast_arena = lua.internal.ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = p.parseChunkAst(&ast_arena) catch {
        lMessage(progname, p.diagString());
        return error.SyntaxError;
    };

    switch (backend) {
        .bc => {
            // Bytecode VM: codegen_bc emits Proto, vm.runBytecode executes it.
            var cg_bc = lua.internal.codegen_bc.Codegen.init(aalloc, source.name, source.bytes);
            defer cg_bc.deinit();
            const proto = cg_bc.compileChunk(chunk) catch {
                lMessage(progname, cg_bc.diagString());
                return error.CodegenError;
            };
            // If --dump-bytecode was requested, print disassembly and exit.
            if (dump_bytecode) {
                var out = stdio.stdout();
                try lua.internal.bytecode.dumpProto(&out, proto, 0);
                return;
            }
            // Set up _ENV upvalue (upvalue 0 = global_env table).
            // Heap-allocate the cell: closures created during execution
            // capture this cell as an upvalue, and finalizers may run
            // during vm.deinit() — long after this function has returned.
            // A stack-local cell would be a use-after-free at that point.
            const env_cell = aalloc.create(lua.internal.vm.Cell) catch return error.OutOfMemory;
            env_cell.* = .{ .value = .{ .Table = vm.global_env } };
            const upvals = [_]*lua.internal.vm.Cell{env_cell};
            // PUC docall (lua.c:155-166): push msghandler as errfunc before
            // calling lua_pcall. The handler runs BEFORE call stack unwinding,
            // so __tostring metamethods can access debug.getinfo(N).
            const saved_errfunc = vm.errfunc;
            vm.errfunc = .{ .Builtin = .cli_msghandler };
            defer vm.errfunc = saved_errfunc;
            // PUC docall (lua.c:161): setsignal(SIGINT, laction).
            lua.internal.vm.installSigintHandler();
            defer lua.internal.vm.restoreSigintHandler();
            const ret = vm.runBytecode(proto, &upvals, script_args, null) catch {
                reportError(aalloc, vm, progname);
                return error.RuntimeError;
            };
            aalloc.free(ret);
        },
    }
}

fn collectArgs(alloc: std.mem.Allocator, init: std.process.Init) ![][]const u8 {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer it.deinit();

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| alloc.free(arg);
        args.deinit(alloc);
    }

    while (it.next()) |arg| {
        try args.append(alloc, try alloc.dupe(u8, arg));
    }
    return args.toOwnedSlice(alloc);
}

fn freeArgs(alloc: std.mem.Allocator, args: [][]const u8) void {
    for (args) |arg| alloc.free(arg);
    alloc.free(args);
}

/// PUC `handle_luainit` (lua.c:377): read LUA_INIT_5_5 (or LUA_INIT) env var.
/// If the value starts with '@', load and run the file; otherwise execute
/// as Lua code. Does nothing if neither env var is set.
fn handleLuaInit(
    alloc: std.mem.Allocator,
    init: std.process.Init,
    vm: *lua.internal.vm.Vm,
    backend: VmBackend,
    bc_stats_ptr: ?*BcCoverageStats,
    dump_bytecode: bool,
    progname: []const u8,
) !void {
    const env = stdio.activeEnviron();
    var init_val: ?[]u8 = null;
    defer if (init_val) |v| alloc.free(v);
    var init_name: []const u8 = "LUA_INIT_5_5";

    // Try versioned name first, then unversioned
    init_val = env.getAlloc(alloc, "LUA_INIT_5_5") catch null;
    if (init_val == null) {
        init_val = env.getAlloc(alloc, "LUA_INIT") catch null;
        if (init_val != null) init_name = "LUA_INIT";
    }

    if (init_val) |val| {
        if (val.len > 0 and val[0] == '@') {
            // Load and run file. PUC `dofile` (lua.c:335) reports
            //   "lua: cannot open file '<path>'"
            // via `report` on a load failure. We mirror that format so
            // missing LUA_INIT=@file is not a silent non-zero exit.
            const path = val[1..];
            const source = lua.internal.Source.loadFile(alloc, init.io, path) catch |err| {
                var errw = stdio.stderr();
                // `OutOfMemory` should propagate (matches the rest of the
                // CLI's error handling); any other load failure is reported
                // to the user and exits non-zero. PUC's `dofile` (lua.c:335)
                // reports via `report` with the OS error message, e.g.
                //   "lua: cannot open /path: No such file or directory".
                if (err == error.OutOfMemory) return err;
                try errw.print("{s}: cannot open {s}: {s}\n", .{ progname, path, @errorName(err) });
                std.process.exit(1);
            };
            runZigSource(alloc, vm, source, backend, bc_stats_ptr, dump_bytecode, progname) catch |err| switch (err) {
                error.SyntaxError, error.CodegenError, error.RuntimeError => std.process.exit(1),
                else => return err,
            };
        } else {
            // Execute as Lua code
            const name_buf = try std.fmt.allocPrint(alloc, "={s}", .{init_name});
            defer alloc.free(name_buf);
            const source = lua.internal.Source{ .name = name_buf, .bytes = val };
            runZigSource(alloc, vm, source, backend, bc_stats_ptr, dump_bytecode, progname) catch |err| switch (err) {
                error.SyntaxError, error.CodegenError, error.RuntimeError => std.process.exit(1),
                else => return err,
            };
        }
    }
}

// ==========================================================================
// PUC-faithful argument parsing (lua.c: collectargs / runargs / dolibrary)
// ==========================================================================

/// Bits of various argument indicators, matching PUC lua.c:273-277.
const has_error: u8 = 1; // bad option
const has_i: u8 = 2; // -i
const has_v: u8 = 4; // -v
const has_e: u8 = 8; // -e
const has_E: u8 = 16; // -E

/// PUC `print_usage` (lua.c:84-104): print error message for a bad option,
/// followed by the usage text. The `badoption` string determines the message:
///   - if badoption[1] == 'e' or 'l': "'<badoption>' needs argument"
///   - otherwise: "unrecognized option '<badoption>'"
fn printUsage(progname: []const u8, badoption: []const u8) void {
    var errw = stdio.stderr();
    errw.print("{s}: ", .{progname}) catch {};
    if (badoption.len >= 2 and (badoption[1] == 'e' or badoption[1] == 'l')) {
        errw.print("'{s}' needs argument\n", .{badoption}) catch {};
    } else {
        errw.print("unrecognized option '{s}'\n", .{badoption}) catch {};
    }
    errw.print(
        \\usage: {s} [options] [script [args]]
        \\Available options are:
        \\  -e stat   execute string 'stat'
        \\  -i        enter interactive mode after executing 'script'
        \\  -l mod    require library 'mod' into global 'mod'
        \\  -l g=mod  require library 'mod' into global 'g'
        \\  -v        show version information
        \\  -E        ignore environment variables
        \\  -W        turn warnings on
        \\  --        stop handling options
        \\  -         stop handling options and execute stdin
        \\
    , .{progname}) catch {};
}

/// Result of PUC `collectargs` (lua.c:287-342).
const CollectResult = struct {
    /// Bitmask of has_i, has_v, has_e, has_E. If has_error is set, parsing
    /// failed and `script` is the index of the bad option.
    args: u8,
    /// 1-based index into argv of the script name. 0 = no script. -1 = no
    /// program name. If has_error, this is the index of the bad option.
    script: i32,
};

/// PUC `collectargs` (lua.c:287-342): traverses all arguments, returning a
/// mask with indicators. Single-pass, faithful to PUC semantics.
///
/// `argv` is 0-based: argv[0] = program name, argv[1..] = options/script/args.
fn collectargs(argv: []const []const u8) CollectResult {
    var args: u8 = 0;
    if (argv.len == 0 or argv[0].len == 0) {
        // No program name (PUC: *first = -1, return 0).
        return .{ .args = 0, .script = -1 };
    }
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (a.len == 0 or a[0] != '-') {
            // Not an option → this is the script name.
            return .{ .args = args, .script = @intCast(i) };
        }
        // a[0] == '-'
        if (a.len == 1) {
            // "-" alone → script name is "-" (stdin).
            return .{ .args = args, .script = @intCast(i) };
        }
        // a has at least 2 chars, a[0]=='-'
        switch (a[1]) {
            '-' => {
                // "--": stop handling options.
                if (a.len > 2) {
                    // Extra characters after "--" → error.
                    return .{ .args = has_error, .script = @intCast(i) };
                }
                // If there is a script name, it comes after "--".
                const next: i32 = if (i + 1 < argv.len) @intCast(i + 1) else 0;
                return .{ .args = args, .script = next };
            },
            'E' => {
                if (a.len > 2) return .{ .args = has_error, .script = @intCast(i) };
                args |= has_E;
            },
            'W' => {
                if (a.len > 2) return .{ .args = has_error, .script = @intCast(i) };
                // -W: warnings on (processed in runargs)
            },
            'i' => {
                args |= has_i;
                // -i implies -v, FALLTHROUGH to -v
                if (a.len > 2) return .{ .args = has_error, .script = @intCast(i) };
                args |= has_v;
            },
            'v' => {
                if (a.len > 2) return .{ .args = has_error, .script = @intCast(i) };
                args |= has_v;
            },
            'e' => {
                args |= has_e;
                // FALLTHROUGH to 'l': both need an argument.
                if (a.len == 2) {
                    // No concatenated argument → try next argv.
                    // PUC: *first was already set to current i at loop top.
                    // We must report the CURRENT option on error, not the next.
                    const opt_idx = i;
                    i += 1;
                    if (i >= argv.len or argv[i].len == 0 or argv[i][0] == '-') {
                        return .{ .args = has_error, .script = @intCast(opt_idx) };
                    }
                }
            },
            'l' => {
                // Same as 'e': needs an argument (concatenated or next argv).
                if (a.len == 2) {
                    const opt_idx = i;
                    i += 1;
                    if (i >= argv.len or argv[i].len == 0 or argv[i][0] == '-') {
                        return .{ .args = has_error, .script = @intCast(opt_idx) };
                    }
                }
            },
            else => {
                // Invalid option.
                return .{ .args = has_error, .script = @intCast(i) };
            },
        }
    }
    // No script name found.
    return .{ .args = args, .script = 0 };
}

/// PUC `dolibrary` (lua.c:218-239): receives `globname[=modname]` and runs
/// `globname = require(modname)`. If there is no explicit modname and globname
/// contains a `-` (LUA_IGMARK), cut the suffix after `-` to make the global
/// name. Returns true on success, false on error.
fn dolibrary(vm: *lua.internal.vm.Vm, spec: []const u8) bool {
    var globname: []const u8 = undefined;
    var modname: []const u8 = undefined;
    var suffix_pos: ?usize = null;

    if (std.mem.indexOfScalar(u8, spec, '=')) |eq| {
        // Explicit: global=modname
        globname = spec[0..eq];
        modname = spec[eq + 1 ..];
    } else {
        // No explicit name: module name = global name.
        globname = spec;
        modname = spec;
        // Look for suffix mark '-' (LUA_IGMARK) to cut from global name.
        suffix_pos = std.mem.indexOfScalar(u8, spec, '-');
    }

    // Call require(modname)
    const require_fn = vm.apiGetGlobal("require");
    const modname_str = vm.internStr(modname) catch return false;
    var call_args = [_]lua.internal.vm.Value{.{ .String = modname_str }};
    const ret = vm.apiCall(require_fn, call_args[0..]) catch return false;
    defer vm.alloc.free(ret);
    if (ret.len == 0) return false;

    // Cut suffix from global name if present.
    const gname = if (suffix_pos) |p| globname[0..p] else globname;
    vm.apiSetGlobal(gname, ret[0]) catch return false;
    return true;
}

/// PUC `runargs` (lua.c:350-374): process -e, -l, and -W options in order.
/// Returns true if all succeeded, false if any code raised an error.
fn runargs(
    vm: *lua.internal.vm.Vm,
    aalloc: std.mem.Allocator,
    puc_argv: []const []const u8,
    optlim: usize,
    backend: VmBackend,
    bc_stats_ptr: ?*BcCoverageStats,
    dump_bytecode: bool,
    progname: []const u8,
) bool {
    // PUC: lua_warning(L, "@off", 0) — warnings off by default in stand-alone.
    vmWarnControl(vm, "@off");

    var i: usize = 1;
    while (i < optlim) : (i += 1) {
        const a = puc_argv[i];
        if (a.len < 2 or a[0] != '-') continue;
        switch (a[1]) {
            'e', 'l' => {
                // Both options need an argument.
                var extra: []const u8 = a[2..];
                if (extra.len == 0) {
                    // No concatenated argument → use next argv.
                    i += 1;
                    extra = puc_argv[i];
                }
                if (a[1] == 'e') {
                    // dostring(L, extra, "=(command line)")
                    // PUC `runargs` calls `dostring` which uses `docall` →
                    // `report`. `runZigSource` already reports the error via
                    // `reportError` (matching PUC's `report`), so we just
                    // return false here.
                    const source = lua.internal.Source{
                        .name = "=(command line)",
                        .bytes = extra,
                    };
                    runZigSource(aalloc, vm, source, backend, bc_stats_ptr, dump_bytecode, progname) catch return false;
                } else {
                    // dolibrary(L, extra)
                    // `dolibrary` returns false on error; the error has
                    // already been set in the VM. Report it via `reportError`
                    // (matching PUC's `report` call in `runargs`).
                    if (!dolibrary(vm, extra)) {
                        reportError(aalloc, vm, progname);
                        return false;
                    }
                }
            },
            'W' => {
                // lua_warning(L, "@on", 0) — warnings on.
                vmWarnControl(vm, "@on");
            },
            else => {}, // Other options (-i, -v, -E) are not processed here.
        }
    }
    return true;
}

/// Send a warning control message (@on/@off) to the VM's warn builtin.
/// This mirrors PUC's `lua_warning(L, msg, 0)` for control messages.
fn vmWarnControl(vm: *lua.internal.vm.Vm, msg: []const u8) void {
    const warn_fn = vm.apiGetGlobal("warn");
    const str = vm.internStr(msg) catch return;
    var args = [_]lua.internal.vm.Value{.{ .String = str }};
    const ret = vm.apiCall(warn_fn, args[0..]) catch return;
    vm.alloc.free(ret);
}

/// PUC `print_version` (lua.c:169-172): print version string to stdout.
fn printVersion() void {
    var out = stdio.stdout();
    out.print("Lua 5.5.0  Copyright (C) 1994-2024 Lua.org, PUC-Rio\n", .{}) catch {};
}

// ==========================================================================
// PUC-faithful REPL (lua.c: doREPL / loadline / multiline / addreturn)
// ==========================================================================

/// Mark used in error messages for incomplete statements (PUC EOFMARK).
const eof_mark = "<eof>";

/// PUC `incomplete` (lua.c:553-561): check whether a syntax error message
/// ends with the EOF mark, indicating the input is incomplete and more lines
/// should be read.
fn isIncompleteError(errmsg: []const u8) bool {
    if (errmsg.len >= eof_mark.len) {
        return std.mem.eql(u8, errmsg[errmsg.len - eof_mark.len ..], eof_mark);
    }
    return false;
}

/// Try to compile `source` as a Lua chunk. Returns the compiled proto on
/// success, an allocated error message string on failure (must be freed by
/// the caller), or `.oom` if the allocator itself failed (nothing to free).
fn tryCompile(
    aalloc: std.mem.Allocator,
    vm: *lua.internal.vm.Vm,
    source: lua.internal.Source,
) union(enum) { proto: *const lua.internal.bytecode.Proto, err_msg: []const u8, oom: void } {
    _ = vm;
    var lex = lua.internal.Lexer.init(source);
    var p = lua.internal.Parser.init(&lex) catch {
        return .{ .err_msg = std.fmt.allocPrint(aalloc, "{s}", .{lex.diagString()}) catch return .oom };
    };
    var ast_arena = lua.internal.ast.AstArena.init(aalloc);
    defer ast_arena.deinit();
    const chunk = p.parseChunkAst(&ast_arena) catch {
        return .{ .err_msg = std.fmt.allocPrint(aalloc, "{s}", .{p.diagString()}) catch return .oom };
    };
    var cg_bc = lua.internal.codegen_bc.Codegen.init(aalloc, source.name, source.bytes);
    defer cg_bc.deinit();
    const proto = cg_bc.compileChunk(chunk) catch {
        return .{ .err_msg = std.fmt.allocPrint(aalloc, "{s}", .{cg_bc.diagString()}) catch return .oom };
    };
    return .{ .proto = proto };
}

/// PUC `checklocal` (lua.c:600-609): if the line starts with "local" followed
/// by a space/tab, print a warning that locals do not survive across lines.
fn checklocal(line: []const u8) void {
    // Skip leading spaces.
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const rest = line[i..];
    const kw = "local";
    if (rest.len > kw.len and std.mem.eql(u8, rest[0..kw.len], kw) and
        (rest[kw.len] == ' ' or rest[kw.len] == '\t'))
    {
        var errw = stdio.stderr();
        errw.print("warning: locals do not survive across lines in interactive mode\n", .{}) catch {};
    }
}

/// PUC `get_prompt` (lua.c:533-541): read `_PROMPT` (firstline) or `_PROMPT2`
/// (continuation) from Lua globals. If nil, use the default (`> ` or `>> `).
/// Apply `tostring` (which calls `__tostring` metamethod) to non-nil values.
/// Returns the prompt string (owned by the caller, must be freed).
fn getPrompt(aalloc: std.mem.Allocator, vm: *lua.internal.vm.Vm, firstline: bool) []const u8 {
    const name = if (firstline) "_PROMPT" else "_PROMPT2";
    const val = vm.apiGetGlobal(name);
    switch (val) {
        .Nil => {
            // Use the default prompt (PUC LUA_PROMPT / LUA_PROMPT2).
            return if (firstline) "> " else ">> ";
        },
        .String => |s| {
            // Already a string — return a copy.
            return aalloc.dupe(u8, s.bytes()) catch return if (firstline) "> " else ">> ";
        },
        else => {
            // Non-string, non-nil: apply tostring (calls __tostring).
            // PUC uses luaL_tolstring which calls __tostring metamethod.
            const str = vm.valueToStringAlloc(val) catch {
                return if (firstline) "> " else ">> ";
            };
            return aalloc.dupe(u8, str) catch if (firstline) "> " else ">> ";
        },
    }
}

/// PUC `doREPL` (lua.c:677-691): read-eval-print loop. Reads lines from
/// stdin, compiles them (with `return ` prefix first, then as statement with
/// multi-line continuation), executes, and prints results via Lua's `print`.
fn doREPL(
    aalloc: std.mem.Allocator,
    vm: *lua.internal.vm.Vm,
    backend: VmBackend,
    bc_stats_ptr: ?*BcCoverageStats,
    progname: []const u8,
) void {
    _ = backend;
    _ = bc_stats_ptr;
    // PUC doREPL (lua.c:679-680): `progname = NULL` for the duration of the
    // REPL — errors in interactive mode print without the progname prefix.
    // We keep the original `progname` for restoring (PUC restores it at
    // lua.c:690), but use `null` for all error reporting inside the loop.
    _ = progname;
    const repl_progname: ?[]const u8 = null;
    const io = stdio.activeIo();
    // PUC does NOT check isatty inside doREPL — it always prints the prompt
    // (via fputs or readline). We follow the same approach.

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(aalloc);

    // PUC: the _ENV upvalue is created once and reused for every main chunk
    // executed in the REPL session (PUC lua.c: doREPL reuses the same main
    // closure's upvalue[0] = _ENV). Allocating a new Cell per iteration would
    // leak one Cell per line.
    const env_cell = aalloc.create(lua.internal.vm.Cell) catch {
        var out = stdio.stdout();
        out.writeAll("\n") catch {};
        return;
    };
    env_cell.* = .{ .value = .{ .Table = vm.global_env } };
    defer aalloc.destroy(env_cell);

    while (true) {
        // --- Read first line ---
        line_buf.clearRetainingCapacity();
        // PUC get_prompt (lua.c:533-541): read _PROMPT global, use default if nil.
        const prompt = getPrompt(aalloc, vm, true);
        defer if (!std.mem.eql(u8, prompt, "> ") and !std.mem.eql(u8, prompt, ">> ")) aalloc.free(prompt);
        // PUC pushline (lua.c:570-571): fputs(prompt, stdout) — always print
        // the prompt, regardless of TTY status.
        var out = stdio.stdout();
        out.writeAll(prompt) catch {};
        if (!readLine(aalloc, io, &line_buf)) break;

        // PUC checklocal (lua.c:600-609): warn if the line starts with
        // "local" followed by a space, since locals don't survive across
        // lines in interactive mode.
        checklocal(line_buf.items);

        // --- Try `return <line>;` (PUC addreturn) ---
        var ret_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer ret_buf.deinit(aalloc);
        ret_buf.appendSlice(aalloc, "return ") catch break;
        ret_buf.appendSlice(aalloc, line_buf.items) catch break;
        ret_buf.append(aalloc, ';') catch break;

        const ret_source = lua.internal.Source{ .name = "=stdin", .bytes = ret_buf.items };
        const ret_result = tryCompile(aalloc, vm, ret_source);

        var proto: ?*const lua.internal.bytecode.Proto = null;
        var multiline_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer multiline_buf.deinit(aalloc);

        switch (ret_result) {
            .proto => |p| proto = p,
            .oom => break,
            .err_msg => |msg| {
                aalloc.free(msg);
                // `return <line>;` failed → try as statement (PUC multiline).
                multiline_buf.appendSlice(aalloc, line_buf.items) catch break;

                // Keep reading continuation lines until the input compiles
                // or the error is not "incomplete".
                while (true) {
                    const src = lua.internal.Source{ .name = "=stdin", .bytes = multiline_buf.items };
                    const ml_result = tryCompile(aalloc, vm, src);
                    switch (ml_result) {
                        .proto => |p| {
                            proto = p;
                            break;
                        },
                        .oom => break,
                        .err_msg => |ml_msg| {
                            const incomplete = isIncompleteError(ml_msg);
                            if (!incomplete) {
                                // PUC report(L, status): print the error message
                                // to stderr before freeing, so the user sees
                                // real syntax errors (not just incomplete input).
                                var errw = stdio.stderr();
                                errw.print("{s}\n", .{ml_msg}) catch {};
                                aalloc.free(ml_msg);
                                break;
                            }
                            // Incomplete → read another line.
                            // PUC multiline: if pushline returns 0 (EOF),
                            // return status (the error). doREPL then calls
                            // report(L, status) which prints the error.
                            aalloc.free(ml_msg);
                            // PUC get_prompt (lua.c:533-541): read _PROMPT2
                            // global for continuation prompt.
                            const prompt2 = getPrompt(aalloc, vm, false);
                            defer if (!std.mem.eql(u8, prompt2, "> ") and !std.mem.eql(u8, prompt2, ">> ")) aalloc.free(prompt2);
                            // PUC pushline (lua.c:570-571): fputs(prompt, stdout)
                            var out2 = stdio.stdout();
                            out2.writeAll(prompt2) catch {};
                            line_buf.clearRetainingCapacity();
                            if (!readLine(aalloc, io, &line_buf)) {
                                // EOF while reading continuation.
                                // PUC: multiline returns the incomplete error
                                // status, doREPL calls report(L, status).
                                // Re-compile to get the error message and
                                // print it.
                                const src2 = lua.internal.Source{ .name = "=stdin", .bytes = multiline_buf.items };
                                const eof_result = tryCompile(aalloc, vm, src2);
                                switch (eof_result) {
                                    .proto => {},
                                    .oom => break,
                                    .err_msg => |eof_msg| {
                                        var errw = stdio.stderr();
                                        errw.print("{s}\n", .{eof_msg}) catch {};
                                        aalloc.free(eof_msg);
                                    },
                                }
                                proto = null;
                                break;
                            }
                            multiline_buf.append(aalloc, '\n') catch break;
                            multiline_buf.appendSlice(aalloc, line_buf.items) catch break;
                        },
                    }
                }
            },
        }

        if (proto) |p| {
            // Execute the compiled chunk using the shared _ENV upvalue cell.
            // PUC doREPL calls docall which sets msghandler as errfunc
            // (lua.c:155-166). Without this, errors in REPL show no traceback.
            const upvals = [_]*lua.internal.vm.Cell{env_cell};
            const saved_errfunc = vm.errfunc;
            vm.errfunc = .{ .Builtin = .cli_msghandler };
            defer vm.errfunc = saved_errfunc;
            const rets = vm.runBytecode(p, &upvals, &.{}, null) catch |err| switch (err) {
                error.OutOfMemory => break,
                else => {
                    reportError(aalloc, vm, repl_progname);
                    continue;
                },
            };
            // PUC l_print (lua.c:660-670): if there are results, call
            // print(results...). If the print call errors, format the
            // message as `error calling 'print' (error_message)` — NO
            // traceback is appended (PUC uses lua_pcall with msghandler=0).
            if (rets.len > 0) {
                const print_fn = vm.apiGetGlobal("print");
                const print_rets = vm.apiCall(print_fn, rets) catch |err| switch (err) {
                    error.OutOfMemory => {
                        aalloc.free(rets);
                        break;
                    },
                    else => {
                        // PUC l_print (lua.c:667-668):
                        //   l_message(progname, lua_pushfstring(L,
                        //       "error calling 'print' (%s)",
                        //       lua_tostring(L, -1)));
                        // The error object is the raw error message from
                        // the failed print call — no traceback, no
                        // msghandler formatting.
                        const err_str = vm.errorString();
                        const msg = std.fmt.allocPrint(
                            aalloc,
                            "error calling 'print' ({s})",
                            .{err_str},
                        ) catch {
                            // OOM during formatting — fall back to raw.
                            lMessage(repl_progname, err_str);
                            aalloc.free(rets);
                            continue;
                        };
                        defer aalloc.free(msg);
                        lMessage(repl_progname, msg);
                        aalloc.free(rets);
                        continue;
                    },
                };
                aalloc.free(print_rets);
            }
            aalloc.free(rets);
        }
    }
    // PUC: lua_writeline() at the end.
    var out = stdio.stdout();
    out.writeAll("\n") catch {};
}

/// Read one line from stdin into `buf` (without the trailing newline).
/// Returns false on EOF.
fn readLine(aalloc: std.mem.Allocator, io: std.Io, buf: *std.ArrayListUnmanaged(u8)) bool {
    var byte: [1]u8 = undefined;
    while (true) {
        const n = std.Io.File.stdin().readStreaming(io, &.{byte[0..]}) catch {
            // readStreaming returns error.EndOfStream at EOF. If we have
            // buffered data, treat it as the last line (no trailing newline).
            if (buf.items.len == 0) return false;
            return true;
        };
        if (n == 0) {
            // EOF (shouldn't happen with readStreaming, but handle defensively)
            if (buf.items.len == 0) return false;
            return true;
        }
        if (byte[0] == '\n') return true;
        buf.append(aalloc, byte[0]) catch return false;
    }
}

// ==========================================================================
// Luazig-specific option pre-pass
// ==========================================================================

const LuazigOptions = struct {
    backend: VmBackend = .bc,
    bc_coverage_out: ?[]const u8 = null,
    enable_testc: bool = false,
    dump_bytecode: bool = false,
    show_help: bool = false,
    /// PUC argv: original argv with luazig-specific options stripped.
    /// This is what collectargs and createargtable operate on.
    puc_argv: []const []const u8,
};

/// Pre-pass: extract luazig-specific options (--vm=, --engine=, --testc, etc.)
/// from argv, returning a cleaned "PUC argv" that only contains PUC-style
/// options + script + script args. This is necessary because PUC's collectargs
/// treats `--` as "stop option parsing" and would reject `--vm=bc` as an error.
fn extractLuazigOptions(alloc: std.mem.Allocator, args: []const []const u8) !LuazigOptions {
    var opts = LuazigOptions{ .puc_argv = &.{} };

    var puc_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer puc_list.deinit(alloc);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];

        // --help: luazig extension (not a PUC option)
        if (std.mem.eql(u8, a, "--help")) {
            opts.show_help = true;
            continue;
        }
        // --vm=value
        if (std.mem.startsWith(u8, a, "--vm=")) {
            const v = a["--vm=".len..];
            opts.backend = parseVmBackend(v) orelse {
                var errw = stdio.stderr();
                try errw.print("{s}: unknown vm backend '{s}' (expected ir|bc)\n", .{ args[0], v });
                return error.InvalidArgument;
            };
            continue;
        }
        // --vm value
        if (std.mem.eql(u8, a, "--vm")) {
            if (i + 1 >= args.len) {
                var errw = stdio.stderr();
                try errw.print("{s}: --vm requires a value\n", .{args[0]});
                return error.InvalidArgument;
            }
            i += 1;
            const v = args[i];
            opts.backend = parseVmBackend(v) orelse {
                var errw = stdio.stderr();
                try errw.print("{s}: unknown vm backend '{s}' (expected ir|bc)\n", .{ args[0], v });
                return error.InvalidArgument;
            };
            continue;
        }
        // --engine=value
        if (std.mem.startsWith(u8, a, "--engine=")) {
            const v = a["--engine=".len..];
            switch (parseEngineCompat(v)) {
                .zig => {},
                .ref => {
                    var errw = stdio.stderr();
                    try errw.print("{s}: --engine=ref was removed; run ./build/lua-c/lua directly\n", .{args[0]});
                    return error.InvalidArgument;
                },
                .invalid => {
                    var errw = stdio.stderr();
                    try errw.print("{s}: unknown engine '{s}'\n", .{ args[0], v });
                    return error.InvalidArgument;
                },
            }
            continue;
        }
        // --engine value
        if (std.mem.eql(u8, a, "--engine")) {
            if (i + 1 >= args.len) {
                var errw = stdio.stderr();
                try errw.print("{s}: --engine requires a value\n", .{args[0]});
                return error.InvalidArgument;
            }
            i += 1;
            const v = args[i];
            switch (parseEngineCompat(v)) {
                .zig => {},
                .ref => {
                    var errw = stdio.stderr();
                    try errw.print("{s}: --engine ref was removed; run ./build/lua-c/lua directly\n", .{args[0]});
                    return error.InvalidArgument;
                },
                .invalid => {
                    var errw = stdio.stderr();
                    try errw.print("{s}: unknown engine '{s}'\n", .{ args[0], v });
                    return error.InvalidArgument;
                },
            }
            continue;
        }
        // --trace-ref: removed
        if (std.mem.eql(u8, a, "--trace-ref")) {
            var errw = stdio.stderr();
            try errw.print("{s}: --trace-ref is no longer supported (no ref delegation)\n", .{args[0]});
            return error.InvalidArgument;
        }
        // --bc-coverage-out <path>
        if (std.mem.eql(u8, a, "--bc-coverage-out")) {
            if (i + 1 >= args.len) {
                var errw = stdio.stderr();
                try errw.print("{s}: --bc-coverage-out requires a path\n", .{args[0]});
                return error.InvalidArgument;
            }
            i += 1;
            opts.bc_coverage_out = args[i];
            continue;
        }
        // --testc
        if (std.mem.eql(u8, a, "--testc")) {
            opts.enable_testc = true;
            continue;
        }
        // --dump-bytecode
        if (std.mem.eql(u8, a, "--dump-bytecode")) {
            opts.dump_bytecode = true;
            continue;
        }

        // Not a luazig-specific option → pass through to PUC argv.
        try puc_list.append(alloc, a);
    }

    opts.puc_argv = try puc_list.toOwnedSlice(alloc);
    return opts;
}

/// PUC `pushargs` (lua.c:245-255): read `arg[1]..arg[n]` from the VM's
/// `arg` global table and return them as a slice of Values. This is called
/// at script-execution time (after -e/-l have run), so modifications to `arg`
/// by -e chunks are visible. If `arg` is not a table, prints the PUC error
/// message and exits.
fn pushArgsFromTable(alloc: std.mem.Allocator, vm: *lua.internal.vm.Vm) ![]lua.internal.vm.Value {
    const arg_val = vm.apiGetGlobal("arg");
    if (arg_val != .Table) {
        var errw = stdio.stderr();
        errw.print("luazig: 'arg' is not a table\n", .{}) catch {};
        std.process.exit(1);
    }
    const arg_tbl = arg_val.Table;
    // Read arg[1], arg[2], ... until nil.
    var list: std.ArrayListUnmanaged(lua.internal.vm.Value) = .empty;
    errdefer list.deinit(alloc);
    var i: i64 = 1;
    while (true) : (i += 1) {
        const v = vm.apiRawGet(arg_tbl, .{ .Int = i }) catch return error.RuntimeError;
        if (v == .Nil) break;
        try list.append(alloc, v);
    }
    return try list.toOwnedSlice(alloc);
}

fn interpreterMain(init: std.process.Init) !void {
    stdio.init(init.io, init.minimal.environ);

    const alloc = init.gpa;
    // The VM performs real frees during GC and after each dynamic compilation.
    // Do not layer it on the CLI's lifetime arena; use a normal process
    // allocator so load-heavy programs do not retain every temporary AST.
    var tracker = tracking_alloc.TrackingAllocator.init(std.heap.smp_allocator);
    const runtime_alloc = std.heap.smp_allocator;

    const args = try collectArgs(alloc, init);
    defer freeArgs(alloc, args);

    // --- Pre-pass: extract luazig-specific options ---
    var opts = try extractLuazigOptions(alloc, args);
    _ = &opts;
    defer alloc.free(opts.puc_argv);

    if (opts.show_help) {
        var out = stdio.stdout();
        try usage(&out);
        return;
    }

    const puc_argv = opts.puc_argv;
    const argv0 = if (puc_argv.len > 0) puc_argv[0] else "luazig";

    // --- PUC collectargs (lua.c:287-342) ---
    const cr = collectargs(puc_argv);

    // PUC pmain: if has_error, print_usage and exit.
    if (cr.args & has_error != 0) {
        // cr.script is the 1-based index of the bad option.
        const bad_idx: usize = if (cr.script > 0) @intCast(cr.script) else 0;
        const bad_option = if (bad_idx < puc_argv.len) puc_argv[bad_idx] else "?";
        printUsage(argv0, bad_option);
        std.process.exit(1);
    }

    // PUC pmain: optlim = (script > 0) ? script : argc
    const optlim: usize = if (cr.script > 0) @intCast(cr.script) else puc_argv.len;

    // PUC pmain: if has_v, print version.
    if (cr.args & has_v != 0) {
        printVersion();
    }

    // PUC pmain: if has_E, set LUA_NOENV (handled via Vm.init noenv flag).
    const disable_env = (cr.args & has_E) != 0;

    // --- Create VM and open libraries ---
    var vm = lua.internal.vm.Vm.init(runtime_alloc, disable_env);
    //vm.tracker_total = &tracker.total_bytes;
    vm.tracker_alloc_count = &tracker.alloc_count;
    vm.tracker_free_count = &tracker.free_count;
    defer vm.deinit();
    if (opts.backend == .bc) vm.setDynamicBytecodeCompiler(compileDynamicBytecode);
    if (opts.enable_testc) try vm.enableTestcModule();

    // --- PUC createargtable (lua.c:185-194) ---
    // Build the `arg` table from the full PUC argv, aligned so that
    // arg[0] = argv[script], positive indices = script args, negative
    // indices = options/program name.
    try vm.setArgTablePuc(puc_argv, cr.script);

    var bc_stats: BcCoverageStats = .{};
    const bc_stats_ptr: ?*BcCoverageStats = if (opts.backend == .bc) &bc_stats else null;

    // --- PUC handle_luainit (lua.c:377-389) ---
    // Run LUA_INIT_5_5 / LUA_INIT before the script. Skipped when -E is set.
    if (!disable_env) {
        try handleLuaInit(runtime_alloc, init, &vm, opts.backend, bc_stats_ptr, opts.dump_bytecode, argv0);
    }

    // --- PUC runargs (lua.c:350-374): execute -e, -l, -W ---
    if (!runargs(&vm, runtime_alloc, puc_argv, optlim, opts.backend, bc_stats_ptr, opts.dump_bytecode, argv0)) {
        std.process.exit(1);
    }

    // --- PUC handle_script (lua.c:258-269) ---
    if (cr.script > 0) {
        const script_idx: usize = @intCast(cr.script);
        const script_path = puc_argv[script_idx];
        // PUC: if fname == "-" and previous arg != "--", read from stdin.
        const is_stdin = std.mem.eql(u8, script_path, "-");
        const prev_is_dashes = script_idx > 0 and std.mem.eql(u8, puc_argv[script_idx - 1], "--");

        // PUC pushargs (lua.c:245-255): push arg[1]..arg[n] as arguments
        // to the script chunk. Read from the VM's `arg` table at runtime
        // (after -e/-l have run, so they can modify arg).
        const script_arg_vals = pushArgsFromTable(runtime_alloc, &vm) catch return error.OutOfMemory;
        defer runtime_alloc.free(script_arg_vals);

        if (is_stdin and !prev_is_dashes) {
            // Read script from stdin.
            const source = try lua.internal.Source.loadStdin(runtime_alloc, init.io);
            runZigSourceArgs(runtime_alloc, &vm, source, opts.backend, bc_stats_ptr, opts.dump_bytecode, script_arg_vals, argv0) catch |err| switch (err) {
                error.SyntaxError, error.CodegenError, error.RuntimeError => std.process.exit(1),
                else => return err,
            };
        } else {
            // PUC: luaL_loadfile fails with "cannot open '<path>': <error>"
            // when the file doesn't exist. Match that format.
            const source = lua.internal.Source.loadFile(runtime_alloc, init.io, script_path) catch |err| {
                var errw = stdio.stderr();
                if (err == error.OutOfMemory) return err;
                try errw.print("{s}: cannot open {s}: {s}\n", .{ argv0, script_path, @errorName(err) });
                std.process.exit(1);
            };
            runZigSourceArgs(runtime_alloc, &vm, source, opts.backend, bc_stats_ptr, opts.dump_bytecode, script_arg_vals, argv0) catch |err| switch (err) {
                error.SyntaxError, error.CodegenError, error.RuntimeError => std.process.exit(1),
                else => return err,
            };
        }
    } else if (cr.args & (has_e | has_v) == 0) {
        // PUC pmain: no script, no -e, no -v → if stdin is tty, print version
        // and enter REPL; else execute stdin as a file.
        const stdin_file = std.Io.File.stdin();
        const is_tty = stdin_file.isTty(stdio.activeIo()) catch false;
        if (is_tty) {
            printVersion();
            doREPL(runtime_alloc, &vm, opts.backend, bc_stats_ptr, argv0);
        } else {
            // Execute stdin as a file (PUC dofile(L, NULL)).
            const source = try lua.internal.Source.loadStdin(runtime_alloc, init.io);
            runZigSource(runtime_alloc, &vm, source, opts.backend, bc_stats_ptr, opts.dump_bytecode, argv0) catch |err| switch (err) {
                error.SyntaxError, error.CodegenError, error.RuntimeError => std.process.exit(1),
                else => return err,
            };
        }
    }

    // --- PUC pmain: if has_i, doREPL ---
    if (cr.args & has_i != 0) {
        doREPL(runtime_alloc, &vm, opts.backend, bc_stats_ptr, argv0);
    }

    if (opts.bc_coverage_out) |out_path| {
        const payload = try std.fmt.allocPrint(
            alloc,
            "{{\"total_functions\":{d},\"lowered_functions\":{d},\"fallback_functions\":{d},\"total_insts\":{d},\"lowered_insts\":{d},\"fallback_insts\":{d}}}\n",
            .{
                bc_stats.total_functions,
                bc_stats.lowered_functions,
                bc_stats.fallback_functions,
                bc_stats.total_insts,
                bc_stats.lowered_insts,
                bc_stats.fallback_insts,
            },
        );
        defer alloc.free(payload);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = payload });
    }
    return;
}

pub fn main(init: std.process.Init) !void {
    // Bytecode execution owns Lua activations in Thread.bytecode_frames. The
    // interpreter no longer needs a giant host stack to survive Lua-controlled
    // recursion, so run directly on the process' normal stack.
    try interpreterMain(init);
}
